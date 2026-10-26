package host

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"agentland/host/internal/localsock"
	"agentland/host/keeper"
)

const terminalOutputLimit = 2 << 20
const terminalOutputChunk = 64 << 10
const terminalInputLimit = 32 << 10
const terminalCapacity = 16

// Clients may hold an output request open until new bytes arrive. Older
// clients omit wait and keep the original short poll.
const terminalDefaultWait = 300 * time.Millisecond
const terminalMaximumWait = 20 * time.Second

// terminalAccess admits a terminal route for a device and a workspace: list
// and create, which always name one.
func (h *Host) terminalAccess(w http.ResponseWriter, r *http.Request, projectID string) (Project, Device, bool) {
	device, ok := h.terminalDevice(w, r)
	if !ok {
		return Project{}, Device{}, false
	}
	project, err := h.project(projectID)
	if err != nil {
		notFound(w)
		return Project{}, Device{}, false
	}
	return project, device, true
}

// terminalRequest is terminalAccess for the routes that address one terminal
// by its ID (output, input, resize, title and close): with no projectID it
// names no workspace (Project{}), so a terminal outside any is reached too.
func (h *Host) terminalRequest(w http.ResponseWriter, r *http.Request, projectID string) (Project, Device, bool) {
	if projectID != "" {
		return h.terminalAccess(w, r, projectID)
	}
	device, ok := h.terminalDevice(w, r)
	return Project{}, device, ok
}

// terminalDevice is the device a terminal route answers, when terminals are
// on.
func (h *Host) terminalDevice(w http.ResponseWriter, r *http.Request) (Device, bool) {
	if h.terminals == nil {
		writeError(w, 403, "terminal_disabled", "Enable terminal access explicitly on your AgentLand host")
		return Device{}, false
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return Device{}, false
	}
	return device, true
}

// terminalEntry is the terminal a request names. Every paired device reaches
// every terminal on this host (terminal_shared.go), whichever device or
// Terminal.app window opened it; only the workspace a request names must be
// the terminal's.
func (h *Host) terminalEntry(w http.ResponseWriter, project Project, id string) *terminalEntry {
	h.terminals.mu.Lock()
	entry := h.terminals.entries[id]
	h.terminals.mu.Unlock()
	if entry == nil && h.terminalsUnavailable(w) {
		// The keeper that cannot be used may hold it.
		return nil
	}
	if entry == nil || !entry.addressedBy(project) {
		writeError(w, 404, "terminal_not_found", "Terminal not found")
		return nil
	}
	return entry
}

// addressedBy is whether a request in project reaches the terminal: it is in
// that workspace when one is named (Project{} names none).
func (entry *terminalEntry) addressedBy(project Project) bool {
	return project.ID == "" || entry.projectID() == project.ID
}

// projectID is the terminal's workspace ID, "" outside any.
func (entry *terminalEntry) projectID() string {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return entry.project.ID
}

// routed is whether the terminal is a routed agent's (terminalMeta.Routed).
func (entry *terminalEntry) routed() bool {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return entry.meta.Routed
}
func validTerminalSize(rows, cols int) bool {
	return rows >= 1 && rows <= 300 && cols >= 1 && cols <= 500
}

func (h *Host) listTerminals(w http.ResponseWriter, r *http.Request) {
	project, device, ok := h.terminalAccess(w, r, r.URL.Query().Get("projectId"))
	if !ok {
		return
	}
	var entries []*terminalEntry
	h.terminals.mu.Lock()
	for _, entry := range h.terminals.entries {
		if entry.owner == device.ID && entry.project.ID == project.ID {
			entries = append(entries, entry)
		}
	}
	h.terminals.mu.Unlock()
	result := make([]TerminalInfo, 0, len(entries))
	now := h.now()
	for _, entry := range entries {
		result = append(result, entry.listed(now, h.terminals.command))
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	writeJSON(w, 200, map[string]any{"terminals": result})
}

// terminalCommandEvery bounds how often a terminal's foreground command is
// read; lists in between answer the last reading.
const terminalCommandEvery = 2 * time.Second

// listed is the terminal as GET /v1/terminals answers it. While the program
// has set no title, a running terminal on macOS adds its foreground command,
// read with read at most every terminalCommandEvery; nothing else computes
// it.
func (entry *terminalEntry) listed(now time.Time, read func(int, time.Time, bool) string) TerminalInfo {
	entry.mu.Lock()
	info := entry.info
	routed := entry.meta.Routed
	wanted := info.Status == "running" && info.ProgramTitle == "" && entry.pid > 0
	due := wanted && (entry.commandAt.IsZero() || now.Sub(entry.commandAt) >= terminalCommandEvery || now.Before(entry.commandAt))
	if due {
		// Claimed before reading, so lists at the same moment read it once.
		entry.commandAt = now
	}
	command := entry.command
	entry.mu.Unlock()
	if due {
		command = read(entry.pid, entry.started, routed)
		entry.mu.Lock()
		entry.command = command
		entry.mu.Unlock()
	}
	if wanted {
		info.Command = command
	}
	return info
}
func (h *Host) createTerminal(w http.ResponseWriter, r *http.Request) {
	var input struct {
		ProjectID string `json:"projectId"`
		Title     string `json:"title"`
		Rows      int    `json:"rows"`
		Cols      int    `json:"cols"`
		Program   string `json:"program"`
		// Resume (Claude Code only): a conversation's UUID, or "pick" for
		// Claude Code's own picker; the host builds the arguments.
		Resume string `json:"resume"`
	}
	if !decode(w, r, &input) {
		return
	}
	project, device, ok := h.terminalAccess(w, r, input.ProjectID)
	if !ok {
		return
	}
	if !validTerminalSize(input.Rows, input.Cols) || len(input.Title) > 200 {
		writeError(w, 400, "invalid_request", "Terminal dimensions or title are invalid")
		return
	}
	title := strings.TrimSpace(input.Title)
	if title == "" {
		title = "Terminal"
	}
	program := strings.TrimSpace(input.Program)
	if program == "" {
		program = "shell"
	}
	// The availability check looks at the filesystem, so it runs before the
	// manager lock is taken; an early return here must never hold that lock.
	if !h.hasTerminalProgram(program) {
		writeError(w, 400, "terminal_program_unavailable", "That terminal program is not available on this host")
		return
	}
	// Claude Code terminals start in a conversation the host names, so a
	// device can resume exactly that one once the terminal ends.
	var conversation *terminalConversation
	if program == "claude" {
		chosen, valid := terminalResumeConversation(input.Resume)
		if !valid {
			writeError(w, 400, "invalid_request", "Resume takes a conversation ID or \"pick\"")
			return
		}
		conversation = &chosen
	} else if strings.TrimSpace(input.Resume) != "" {
		writeError(w, 400, "invalid_request", "Only Claude Code terminals can resume a conversation on this host")
		return
	}
	if h.terminalsUnavailable(w) {
		return
	}
	// Extend only authenticated, decoded agent creation requests. The normal listener
	// write deadline is shorter than the bounded update preparation, which may also
	// stop an update in place and wait for another launch's registration.
	var preparationController *http.ResponseController
	if h.agents != nil && program != "shell" {
		preparationController = http.NewResponseController(w)
		deadline := time.Now().Add(h.agents.terminalUpdateWait + 30*time.Second)
		_ = preparationController.SetReadDeadline(deadline)
		_ = preparationController.SetWriteDeadline(deadline)
	}
	// Preparation cannot create a PTY. An update that fails or is slow never refuses
	// (agents_terminal.go: the installed version starts, with updateNotice); since
	// 2026-10-17 agent_update_failed and agent_update_timeout are no longer sent.
	release, updateNotice, prepareErr := h.agents.prepareTerminal(r.Context(), program)
	if preparationController != nil {
		deadline := time.Now().Add(listenerTimeouts.write)
		_ = preparationController.SetReadDeadline(deadline)
		_ = preparationController.SetWriteDeadline(deadline)
	}
	if prepareErr != nil {
		stopping := false
		select {
		case <-h.stopping:
			stopping = true
		default:
		}
		switch {
		case errors.Is(prepareErr, errAgentChangeBusy):
			writeError(w, 409, "agent_busy", "This agent is being installed, removed or restored; try again when that ends.")
		case stopping || (r.Context().Err() == nil && errors.Is(prepareErr, context.Canceled)):
			// The host stops, or the catalog closed with it.
			writeError(w, 503, "host_stopping", "The host is stopping. No terminal was created.")
		case r.Context().Err() != nil:
			// The request ended: nobody reads an answer, and nothing was created.
		default:
			// The host's state could not be read.
			log.Printf("terminals: could not prepare a terminal in workspace=%s program=%s", project.ID, program)
			internal(w)
		}
		return
	}
	defer release()
	if r.Context().Err() != nil {
		return
	}
	info, err := h.startTerminal(terminalStart{owner: device.ID, project: project, title: title, program: program, conversation: conversation,
		rows: input.Rows, cols: input.Cols, updateNotice: updateNotice})
	switch {
	case errors.Is(err, errTerminalStartStopping):
		writeError(w, 503, "host_stopping", "The host is stopping. No terminal was created.")
	case errors.Is(err, errHostStopping):
		// The device hears that no terminal was created, so none is left.
		writeError(w, 503, "host_stopping", "The host is stopping")
	case errors.Is(err, errTerminalLimit):
		writeError(w, 429, "terminal_limit", fmt.Sprintf("%d terminals are open on this Mac across all your devices and Terminal windows, including finished ones that haven't been closed. Close one, or end or clear one in AgentLand on the Mac (Settings → Terminals).", terminalCapacity))
	case errors.Is(err, errTerminalProgramUnavailable):
		writeError(w, 400, "terminal_program_unavailable", "That terminal program is not available on this host")
	case errors.Is(err, errTerminalPathTooLong):
		// No keeper can run there: a clear error, and nothing to retry.
		writeError(w, 500, "terminal_path_too_long", terminalPathTooLongMessage)
	case errors.Is(err, errTerminalsUnusable):
		writeError(w, 503, "terminals_unavailable", terminalsUnavailableMessage)
	case errors.Is(err, errTerminalNotListed):
		notFound(w)
	case err != nil:
		internal(w)
	default:
		logTerminalCreated(info, project, program, device)
		writeJSON(w, 201, info)
	}
}

// terminalStart is a terminal the host starts (startTerminal): its owner (a
// device's ID, or local-mac), workspace and title, the program and, for
// Claude Code, its conversation, its size, and the agent's update notice.
// after are arguments the host itself puts after the program's own: only a
// continue's prompt (terminal_continue.go), which comes from this user's
// local socket. Devices never send arguments.
type terminalStart struct {
	owner        string
	project      Project
	title        string
	program      string
	conversation *terminalConversation
	after        []string
	rows, cols   int
	updateNotice string
}

// Why startTerminal started no terminal; createTerminal and a continue each
// answer them their own way.
var (
	// errTerminalStartStopping: the host began stopping before the command
	// was built.
	errTerminalStartStopping = errors.New("the host is stopping; no terminal was created")
	// errTerminalLimit: terminalCapacity terminals are open or starting.
	errTerminalLimit = errors.New("the terminal limit is reached")
	// errTerminalProgramUnavailable: the program's command could not be built.
	errTerminalProgramUnavailable = errors.New("the terminal program is unavailable")
	// errTerminalPathTooLong: no keeper can run at the state's path.
	errTerminalPathTooLong = errors.New("the terminal service's path is too long")
	// errTerminalsUnusable: a keeper runs that cannot be used.
	errTerminalsUnusable = errors.New("the terminal service cannot be used")
	// errTerminalNotStarted: the record could not be written, or the keeper
	// did not start the terminal.
	errTerminalNotStarted = errors.New("the terminal did not start")
	// errTerminalNotListed: the terminal started but was not listed (its
	// workspace was removed as it started).
	errTerminalNotListed = errors.New("the terminal was not listed")
)

// startTerminal starts what program runs (terminal_launch.go) in the keeper,
// under the 16-terminal cap, and lists and follows it (installEntry): the
// shared part of createTerminal and of a continue (terminal_continue.go),
// after the agent's update preparation. It answers the terminal as
// createTerminal does, or one of the errors above, or errHostStopping when the
// terminals closed as it started.
func (h *Host) startTerminal(start terminalStart) (TerminalInfo, error) {
	manager := h.terminals
	project, program := start.project, start.program
	select {
	case <-h.stopping:
		return TerminalInfo{}, errTerminalStartStopping
	default:
	}
	// What the terminal runs (terminal_launch.go): the program the device
	// named, never a command of its own.
	command, err := manager.launcher.command(project, program, start.conversation)
	if err != nil {
		return TerminalInfo{}, errTerminalProgramUnavailable
	}
	command.Args = append(command.Args, start.after...)
	names := terminalGenericNames(program, start.title)
	switch program {
	case "shell", "opencode", "claude", "codex":
	default:
		// Agents (agents_catalog.go): an agent's terminal also goes by the
		// agent's name and its command's.
		names = append(names, h.agents.agentName(program), filepath.Base(command.Path))
	}
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		return TerminalInfo{}, errHostStopping
	}
	if len(manager.entries)+manager.starting >= terminalCapacity {
		manager.mu.Unlock()
		return TerminalInfo{}, errTerminalLimit
	}
	manager.starting++
	manager.creating.Add(1)
	manager.mu.Unlock()
	defer func() {
		manager.mu.Lock()
		manager.starting--
		manager.mu.Unlock()
		manager.creating.Done()
	}()
	info := TerminalInfo{ID: newTerminalID(), Title: start.title, ProjectID: project.ID, Status: "running", UpdateNotice: start.updateNotice, Directory: project.Directory}
	if start.conversation != nil && !start.conversation.Pick {
		info.ConversationID = start.conversation.ID
	}
	meta := terminalMeta{Owner: start.owner, Project: project.ID, Program: program, ConversationID: info.ConversationID, Title: start.title, Version: command.Version, Created: h.now().UTC()}
	record, err := meta.encode()
	if err != nil {
		log.Printf("terminals: could not record a terminal in workspace=%s program=%s: %v", project.ID, program, err)
		return TerminalInfo{}, errTerminalNotStarted
	}
	spawnContext, cancelSpawn := context.WithTimeout(context.Background(), terminalRequestWait)
	spawned, err := manager.backend.Spawn(spawnContext, keeper.SpawnRequest{ID: info.ID, Dir: project.Directory, Path: command.Path, Args: command.Args,
		Env: terminalEnvironmentWithID(command.Env, info.ID, manager.launcher.hostExecutable, manager.launcher.statePath), Rows: start.rows, Cols: start.cols, Meta: record})
	cancelSpawn()
	if err != nil {
		log.Printf("terminals: could not start a terminal in workspace=%s program=%s: %v", project.ID, program, err)
		if errors.Is(err, localsock.ErrTooLong) {
			return TerminalInfo{}, errTerminalPathTooLong
		}
		if manager.spawnFoundUnusable(err) {
			manager.setUnusable()
			return TerminalInfo{}, errTerminalsUnusable
		}
		return TerminalInfo{}, errTerminalNotStarted
	}
	info.PID = spawned.PID
	started := spawned.Started
	if started.IsZero() {
		started = time.Now()
	}
	// Terminal titles: the tracker compares titles with this terminal's own
	// names.
	entry := &terminalEntry{owner: start.owner, project: project, info: info, meta: meta, output: []byte{}, changed: make(chan struct{}), pid: spawned.PID, started: started, program: program,
		following: true, done: make(chan struct{}), clock: h.now, rows: start.rows, cols: start.cols}
	entry.titles.names = names
	switch err := h.installEntry(entry); {
	case errors.Is(err, errHostStopping):
		return TerminalInfo{}, errHostStopping
	case err != nil:
		return TerminalInfo{}, errTerminalNotListed
	}
	return info, nil
}

// errHostStopping: the host closed before a terminal was listed.
var errHostStopping = errors.New("the host is stopping")

// errWorkspaceRemovedAtStart: the workspace a terminal names was removed as
// it started, and the terminal went with it.
var errWorkspaceRemovedAtStart = errors.New("the terminal's workspace was removed as it started")

// installEntry lists a terminal the keeper runs and follows it: the tail of
// createTerminal, and of a local registration once the keeper adopted the
// agent's PTY (terminal_local.go). Its log opens, and the keeper's record
// names it, before it is listed, so whatever finds the entry finds its log
// (joinWorkspace moves it) and no other writer of the record runs yet. Then it
// is attached to from the first byte and followed.
//
// A routed agent's workspace is the deepest one holding its folder as it is
// listed (placeRouted): workspace changes write the store under workspaceMu,
// and adding one has joinWorkspace take the terminals outside any only after
// that write, so with workspaceMu held from reading the store until the entry
// is listed, a workspace added meanwhile either holds the agent from the start
// or finds it listed, log and all.
//
// A terminal already listed by then (a restore took it) is left to that
// entry, and this one's log is detached.
//
// errHostStopping: the host closed first (dropUnlisted). errWorkspaceRemovedAtStart:
// the workspace it names was removed as it started; removal ends what it finds
// after its change, so this ends the terminal (endTerminals). Only a terminal
// in a workspace checks that, so one outside any never ends another.
func (h *Host) installEntry(entry *terminalEntry) error {
	manager := h.terminals
	id := entry.info.ID
	entry.following = true
	placed := func() {}
	if entry.meta.Routed {
		h.workspaceMu.Lock()
		var once sync.Once
		placed = func() { once.Do(h.workspaceMu.Unlock) }
		defer placed()
		h.placeRouted(entry)
	}
	if manager.isClosed() {
		placed()
		h.dropUnlisted(entry)
		return errHostStopping
	}
	// Archive (M1 chunk B1): attaching from 0 records output from the first
	// byte.
	entry.log = h.openTerminalLog(entry, entry.program, h.now())
	h.recordTerminalMeta(entry)
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		placed()
		h.dropUnlisted(entry)
		return errHostStopping
	}
	if existing := manager.entries[id]; existing != nil {
		// A restore took it while its log opened (the keeper was unusable
		// for a moment, and the retry restored it): that entry follows it.
		// This log stops, and the keeper's record names that entry's again.
		manager.mu.Unlock()
		placed()
		entry.log.Detach()
		manager.saveMeta(existing)
		log.Printf("terminals: id=%s was already followed", id)
		return nil
	}
	manager.entries[id] = entry
	manager.mu.Unlock()
	placed()
	// Workspaces (workspaces.go): a workspace removed while this terminal
	// started takes it along; removal ends the terminals it finds after that.
	// The follower runs all the same: listed, the terminal may already have
	// been ended by the removal, and its follower records its log's end.
	var result error
	if project := entry.projectID(); project != "" {
		if _, err := h.project(project); errors.Is(err, ErrNotFound) {
			_ = h.endTerminals(project)
			result = errWorkspaceRemovedAtStart
		}
	}
	if result == nil {
		attachContext, cancelAttach := context.WithTimeout(context.Background(), terminalAttachWait)
		attachment, err := manager.backend.Attach(attachContext, id, 0)
		cancelAttach()
		if err == nil && !manager.install(entry, attachment) {
			err = errHostStopping
		}
		if err != nil {
			// follow attaches again, or says why it cannot.
			log.Printf("terminals: could not attach to id=%s: %v", id, err)
		}
	}
	manager.readers.Add(1)
	go func() {
		defer manager.readers.Done()
		entry.follow(manager)
	}()
	return result
}

// recordTerminalMeta writes the entry's record to the keeper before it is
// listed: with its log, and for a routed agent with the workspace placeRouted
// gave it, which may not be the one the CLI handed the keeper.
func (h *Host) recordTerminalMeta(entry *terminalEntry) {
	logID := entry.log.ID()
	if logID == "" && !entry.meta.Routed {
		return
	}
	entry.mu.Lock()
	entry.meta.LogID = logID
	record, err := entry.meta.encode()
	entry.mu.Unlock()
	metaContext, cancelMeta := context.WithTimeout(context.Background(), terminalRequestWait)
	defer cancelMeta()
	if err == nil {
		err = h.terminals.backend.SetMeta(metaContext, entry.info.ID, record)
	}
	if err != nil {
		log.Printf("terminals: could not record id=%s's log in the terminal service: %v", entry.info.ID, err)
	}
}

// dropUnlisted is installEntry's answer to a host that closed before the
// terminal was listed. A routed agent stays in the keeper, its log left
// running for the next host, which takes it back (one with terminal access
// off releases it to its window). Any other terminal is ended and forgotten
// there, with its log, since its device hears that none was created.
func (h *Host) dropUnlisted(entry *terminalEntry) {
	manager := h.terminals
	id := entry.info.ID
	if entry.meta.Routed {
		entry.log.Detach()
		log.Printf("terminals: id=%s arrived as the host stopped; the terminal service keeps it", id)
		return
	}
	entry.mu.Lock()
	entry.endLocked("exited", terminalEndHostStopped, nil, nil)
	entry.following = false
	entry.mu.Unlock()
	log.Printf("terminals: ended id=%s workspace=%s program=%s reason=%s before it opened", id, entry.project.ID, entry.program, terminalEndHostStopped)
	entry.finishLog()
	if err := manager.discard(context.Background(), id); err != nil {
		manager.mu.Lock()
		manager.cleanupErrors = append(manager.cleanupErrors, err)
		manager.mu.Unlock()
	}
}

// terminalEnvironmentWithID is env with AGENTLAND_TERMINAL=<id> last, then
// AGENTLAND_HOST=<executable> and AGENTLAND_HOST_STATE=<state> (each only
// when known), in place of any it had: every AgentLand terminal says which it
// is, so a coding agent typed in it is never routed into AgentLand again, and
// which host runs it, so `agentland-host terminals continue` typed in it
// reaches that host (terminal_continue.go). terminalEnvironment already drops
// every inherited AGENTLAND_ variable, so a nested host's never leak.
func terminalEnvironmentWithID(env []string, id, executable, state string) []string {
	result := make([]string, 0, len(env)+3)
	for _, item := range env {
		name, _, _ := strings.Cut(item, "=")
		switch name {
		case "AGENTLAND_TERMINAL", "AGENTLAND_HOST", "AGENTLAND_HOST_STATE":
			continue
		}
		result = append(result, item)
	}
	result = append(result, "AGENTLAND_TERMINAL="+id)
	if executable != "" {
		result = append(result, "AGENTLAND_HOST="+executable)
	}
	if state != "" {
		result = append(result, "AGENTLAND_HOST_STATE="+state)
	}
	return result
}

// discard ends and forgets a terminal no device was told about, within ctx
// and terminalRequestWait.
func (manager *terminalManager) discard(ctx context.Context, id string) error {
	ctx, cancel := context.WithTimeout(ctx, terminalRequestWait)
	defer cancel()
	if _, err := manager.backend.End(ctx, id); err != nil && !keeper.IsNotFound(err) {
		return err
	}
	if err := manager.backend.Forget(ctx, id); err != nil && !keeper.IsNotFound(err) {
		return err
	}
	return nil
}

// discardAdopted is discard for a terminal the keeper adopted: its program is
// the user's own, in the Terminal.app window that started it, so it is
// released there, never ended. The keeper drops it as it releases it.
func (manager *terminalManager) discardAdopted(ctx context.Context, id string) error {
	ctx, cancel := context.WithTimeout(ctx, terminalRequestWait)
	defer cancel()
	if err := manager.backend.Release(ctx, id); err != nil && !keeper.IsNotFound(err) {
		return err
	}
	if err := manager.backend.Forget(ctx, id); err != nil && !keeper.IsNotFound(err) {
		return err
	}
	return nil
}

// spawnFoundUnusable is whether a Spawn failed because a keeper runs that
// cannot be used: one this build cannot talk to, or one that holds the lock
// but never answered while a new one was started.
func (manager *terminalManager) spawnFoundUnusable(err error) bool {
	switch {
	case errors.Is(err, errKeeperUnusable), errors.Is(err, keeper.ErrNoCommonProtocol):
		return true
	case errors.Is(err, keeper.ErrKeeperDidNotStart):
		// A keeper that failed to start leaves none running; one that holds
		// the lock and does not answer is unusable.
		ctx, cancel := manager.requestContext(terminalAttachWait)
		defer cancel()
		return manager.backend.Status(ctx) == KeeperUnusable
	}
	return false
}

// keeperCode is the code of a request the keeper refused, or "".
func keeperCode(err error) string {
	var remote *keeper.RemoteError
	if errors.As(err, &remote) {
		return remote.Code
	}
	return ""
}

// terminalsUnavailable answers terminals_unavailable while the keeper cannot
// be used.
func (h *Host) terminalsUnavailable(w http.ResponseWriter) bool {
	if !h.terminals.isUnusable() {
		return false
	}
	writeError(w, 503, "terminals_unavailable", terminalsUnavailableMessage)
	return true
}

// terminalPrograms is capabilities.terminalPrograms (terminal_launch.go).
func (h *Host) terminalPrograms() []string { return h.terminals.launcher.programs() }

func (h *Host) hasTerminalProgram(requested string) bool {
	return slices.Contains(h.terminalPrograms(), requested)
}

func (entry *terminalEntry) notifyLocked() { close(entry.changed); entry.changed = make(chan struct{}) }

// follow reads the terminal's output from the keeper into the host's ring,
// its titles and its log until the program exits, the host closes, or the
// keeper stops. A routed agent that ended is cleared once its log records the
// end: no device tab closes it, and it must not hold a place under the cap.
func (entry *terminalEntry) follow(manager *terminalManager) {
	defer func() {
		entry.stopFollowing()
		if entry.routed() && !entry.running() {
			manager.clearRouted(entry)
		}
	}()
	// tries counts re-attaches since an attachment last delivered an event.
	// An attachment that fails within reattachQuick of being taken up,
	// without an event, counts as a failed try; one that lasted longer (an
	// idle stream that dropped) starts the count again.
	tries := 0
	var current TerminalAttachment
	var since time.Time
	for {
		entry.mu.Lock()
		attachment := entry.attachment
		entry.mu.Unlock()
		if attachment != current {
			current, since = attachment, time.Now()
		}
		var event keeper.Event
		err := errors.New("no attachment")
		if attachment != nil {
			event, err = attachment.Next()
		}
		if err != nil {
			if attachment != nil {
				attachment.Close()
				if time.Since(since) >= manager.reattachQuick {
					tries = 0
				}
			}
			if manager.attachmentLost(entry, &tries) {
				continue
			}
			return
		}
		tries = 0
		switch event.Kind {
		case keeper.EventData:
			entry.receive(manager, event.Offset, event.Data, false)
		case keeper.EventSkipped:
			entry.skip(event.SkippedTo)
		case keeper.EventExited:
			entry.exited(event.Exit)
			attachment.Close()
			return
		}
	}
}

// skip moves the ring past output the keeper no longer holds; the log counts
// it as a gap when output after it arrives (AppendAt).
func (entry *terminalEntry) skip(to uint64) {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	if to > entry.cursor {
		entry.output = entry.output[:0]
		entry.start, entry.cursor = to, to
		entry.notifyLocked()
	}
}

// exited records the exit the keeper reported: a release as keptInTerminal,
// otherwise as the end a host action asked for, as keeperStopped when the
// keeper ended it as it stopped, and otherwise as programExited.
func (entry *terminalEntry) exited(exit *keeper.Exit) {
	status, reason, code := keeperExitEnd(exit)
	entry.mu.Lock()
	defer entry.mu.Unlock()
	if entry.ending != nil && (exit == nil || !exit.Released) {
		entry.endLocked(entry.ending.status(), entry.ending.reason, entry.ending.device, code)
		return
	}
	entry.endLocked(status, reason, nil, code)
}

// keeperExitEnd is how a keeper's exit ends a terminal: one the keeper
// released to its Terminal.app window is keptInTerminal, and one it ended as
// it stopped keeperStopped (both status disconnected); any other is the
// program's own exit.
func keeperExitEnd(exit *keeper.Exit) (status, reason string, code *int) {
	if exit == nil {
		return "exited", terminalEndProgramExited, nil
	}
	if exit.Released {
		return "disconnected", terminalEndKeptInTerminal, exit.Code
	}
	if exit.ByKeeper {
		return "disconnected", terminalEndKeeperStopped, exit.Code
	}
	return "exited", terminalEndProgramExited, exit.Code
}

// receive adds output that starts at the keeper's offset: a part the host
// already holds is dropped, and output past the host's cursor moves the ring
// there. replayed is output a restore replays (terminal_restore.go): it is
// older than the description the terminal's record restored, so its titles
// change only the program's title.
func (entry *terminalEntry) receive(manager *terminalManager, offset uint64, data []byte, replayed bool) {
	entry.mu.Lock()
	switch {
	case offset > entry.cursor:
		entry.output = entry.output[:0]
		entry.start, entry.cursor = offset, offset
	case offset < entry.cursor:
		held := entry.cursor - offset
		if held >= uint64(len(data)) {
			entry.mu.Unlock()
			return
		}
		data = data[held:]
	}
	if len(data) == 0 {
		entry.mu.Unlock()
		return
	}
	at := entry.cursor
	entry.output = append(entry.output, data...)
	entry.cursor += uint64(len(data))
	if len(entry.output) > terminalOutputLimit {
		drop := len(entry.output) - terminalOutputLimit
		entry.output = entry.output[drop:]
		entry.start += uint64(drop)
	}
	// Activity (terminal_activity.go): only new output says what the program
	// does now. A restore's replay only brings the scanner to where the live
	// output goes on, so a sequence it cut in two is read whole.
	if replayed {
		entry.activity.scan.feed(data)
	} else {
		entry.activity.output(data, entry.now())
	}
	entry.notifyLocked()
	entry.mu.Unlock()
	// Terminal titles: read outside entry.mu, where the archive reads the
	// output too; only output that completes a title takes the lock again.
	// The program's title names the terminal until a device does; a device's
	// name stays until a device names it again (terminalContextTitle), and
	// only a title that replaces the description moves nameCursor.
	if title, changed := entry.titles.feed(data); changed {
		entry.mu.Lock()
		programChanged := entry.info.ProgramTitle != title
		entry.info.ProgramTitle = title
		renamed := title != "" && programChanged && !replayed && entry.info.ContextTitleSource != contextFromDevice
		if renamed {
			entry.info.ContextTitle = title
			entry.info.ContextTitleSource = contextFromProgram
			entry.nameCursor = entry.cursor
		}
		entry.mu.Unlock()
		if renamed {
			entry.archiveTitle()
			manager.saveContextTitle(entry)
		}
	}
	// Archive (M1 chunk B1): logged after entry.mu is released, so disk work
	// never delays this terminal's readers. Input is never logged. The log
	// takes only what lies past its position, and counts what it missed.
	entry.log.AppendAt(at, data)
}

// stopFollowing is follow's end: an ended terminal's log records how it
// ended; a running one's (the host closed, or the keeper cannot be used) is
// flushed and stays running, and keeperStopped records its end later.
func (entry *terminalEntry) stopFollowing() {
	entry.mu.Lock()
	entry.following = false
	running := entry.info.Status == "running"
	// Taken with following: a restore may follow it again at once
	// (followAgain), with a done of its own.
	done := entry.done
	entry.mu.Unlock()
	if running {
		if entry.log != nil {
			entry.log.flush()
		}
	} else {
		entry.logEnded()
		entry.finishLog()
	}
	close(done)
}

type terminalOutput struct {
	Data   []byte `json:"data"`
	Cursor uint64 `json:"cursor"`
	// End is the cursor after the newest byte the host holds when it answers. A device that attaches to
	// a terminal another run of it already drew knows which bytes are history: their queries were
	// answered then and must not be answered again (docs/HOST-API.md "Terminals").
	End      uint64 `json:"end"`
	Reset    bool   `json:"reset"`
	Status   string `json:"status"`
	ExitCode *int   `json:"exitCode,omitempty"`
	// Ended says how the terminal ended once it is no longer running.
	Ended *TerminalEnd `json:"ended,omitempty"`
}

func (entry *terminalEntry) read(ctx context.Context, cursor uint64, wait time.Duration, stopping <-chan struct{}) terminalOutput {
	entry.mu.Lock()
	if cursor == entry.cursor && entry.info.Status == "running" && wait > 0 {
		changed := entry.changed
		entry.mu.Unlock()
		timer := time.NewTimer(wait)
		select {
		case <-changed:
		case <-ctx.Done():
		case <-stopping:
		case <-timer.C:
		}
		timer.Stop()
		entry.mu.Lock()
	}
	defer entry.mu.Unlock()
	reset := cursor < entry.start || cursor > entry.cursor
	if reset {
		cursor = entry.start
	}
	begin := int(cursor - entry.start)
	end := begin + terminalOutputChunk
	if end > len(entry.output) {
		end = len(entry.output)
	}
	data := append([]byte{}, entry.output[begin:end]...)
	return terminalOutput{Data: data, Cursor: cursor + uint64(len(data)), End: entry.cursor, Reset: reset, Status: entry.info.Status, ExitCode: entry.info.ExitCode, Ended: entry.info.Ended}
}
func (h *Host) terminalOutput(w http.ResponseWriter, r *http.Request) {
	project, _, ok := h.terminalRequest(w, r, r.URL.Query().Get("projectId"))
	if !ok {
		return
	}
	cursor, err := strconv.ParseUint(r.URL.Query().Get("cursor"), 10, 64)
	if err != nil {
		writeError(w, 400, "invalid_request", "A nonnegative terminal cursor is required")
		return
	}
	wait := terminalDefaultWait
	if raw := r.URL.Query().Get("wait"); raw != "" {
		milliseconds, err := strconv.ParseUint(raw, 10, 32)
		if err != nil {
			writeError(w, 400, "invalid_request", "Terminal wait must be a nonnegative number of milliseconds")
			return
		}
		wait = min(time.Duration(milliseconds)*time.Millisecond, terminalMaximumWait)
	}
	terminalID := r.URL.Query().Get("terminalId")
	h.terminals.mu.Lock()
	entry := h.terminals.entries[terminalID]
	h.terminals.mu.Unlock()
	if entry == nil && h.terminalsUnavailable(w) {
		// The keeper that cannot be used may hold it.
		return
	}
	if entry == nil || !entry.addressedBy(project) {
		// Terminal ends: a terminal the host forgot says how it ended, to
		// every paired device, when it remembers or the archive recorded it.
		var extra map[string]any
		ended := h.terminals.clearedEnd(terminalID, project.ID)
		if ended == nil {
			ended = h.endedTerminal(r.Context(), project, terminalID)
		}
		if ended != nil {
			extra = map[string]any{"ended": ended}
		}
		writeErrorWith(w, 404, "terminal_not_found", "Terminal not found", extra)
		return
	}
	output := entry.read(r.Context(), cursor, wait, h.stopping)
	if r.Context().Err() != nil {
		return
	}
	writeJSON(w, 200, output)
}
func (h *Host) terminalInput(w http.ResponseWriter, r *http.Request) {
	var input struct {
		ProjectID  string `json:"projectId"`
		TerminalID string `json:"terminalId"`
		Data       []byte `json:"data"`
	}
	if !decode(w, r, &input) {
		return
	}
	project, _, ok := h.terminalRequest(w, r, input.ProjectID)
	if !ok {
		return
	}
	// The keeper has no input cap of its own: oversized input stops here.
	if len(input.Data) == 0 || len(input.Data) > terminalInputLimit || !utf8.Valid(input.Data) {
		writeError(w, 400, "invalid_request", "Terminal input must contain between 1 and 32768 UTF-8 bytes")
		return
	}
	entry := h.terminalEntry(w, project, input.TerminalID)
	if entry == nil {
		return
	}
	entry.writeMu.Lock()
	defer entry.writeMu.Unlock()
	if !entry.running() {
		writeError(w, 409, "terminal_not_running", "This terminal is not connected; inspect its state before sending more input")
		return
	}
	if h.terminalsUnavailable(w) {
		return
	}
	// On an error part of the input may have arrived, so it is never resent.
	err := h.terminals.backend.Input(r.Context(), input.TerminalID, input.Data)
	switch {
	case err == nil:
		entry.mu.Lock()
		entry.activity.input(h.now())
		entry.mu.Unlock()
		writeJSON(w, 200, map[string]bool{"accepted": true})
	case keeper.IsInputStalled(err):
		writeError(w, 409, "terminal_input_stalled", terminalInputStalledMessage)
	case keeperCode(err) == keeper.CodeNotRunning:
		// The program exited as the input arrived; follow records the end.
		writeError(w, 409, "terminal_not_running", "This terminal is not connected; inspect its state before sending more input")
	default:
		internal(w)
	}
}
func (h *Host) resizeTerminal(w http.ResponseWriter, r *http.Request) {
	var input struct {
		ProjectID  string `json:"projectId"`
		TerminalID string `json:"terminalId"`
		Rows       int    `json:"rows"`
		Cols       int    `json:"cols"`
	}
	if !decode(w, r, &input) {
		return
	}
	project, _, ok := h.terminalRequest(w, r, input.ProjectID)
	if !ok {
		return
	}
	if !validTerminalSize(input.Rows, input.Cols) {
		writeError(w, 400, "invalid_request", "Terminal dimensions are invalid")
		return
	}
	entry := h.terminalEntry(w, project, input.TerminalID)
	if entry == nil {
		return
	}
	entry.writeMu.Lock()
	defer entry.writeMu.Unlock()
	if h.terminalsUnavailable(w) {
		return
	}
	if err := h.terminals.backend.Resize(r.Context(), input.TerminalID, input.Rows, input.Cols); err != nil {
		internal(w)
		return
	}
	entry.mu.Lock()
	entry.rows, entry.cols = input.Rows, input.Cols
	entry.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"accepted": true})
}
func (h *Host) closeTerminal(w http.ResponseWriter, r *http.Request) {
	var input struct {
		ProjectID  string `json:"projectId"`
		TerminalID string `json:"terminalId"`
	}
	if !decode(w, r, &input) {
		return
	}
	project, device, ok := h.terminalRequest(w, r, input.ProjectID)
	if !ok {
		return
	}
	entry := h.terminalEntry(w, project, input.TerminalID)
	if entry == nil {
		return
	}
	entry.writeMu.Lock()
	defer entry.writeMu.Unlock()
	if h.terminalsUnavailable(w) {
		return
	}
	// A running terminal ends as the device's; then, in every case, the
	// keeper forgets it and the host drops it.
	if err := h.terminals.endAndForget(context.Background(), entry, terminalEndDevice, &device); err != nil {
		log.Printf("terminals: could not close id=%s workspace=%s: %v", input.TerminalID, project.ID, err)
		internal(w)
		return
	}
	writeJSON(w, 200, map[string]bool{"accepted": true})
}

// Close stops the queue dispatcher and CLI runs, detaches from the terminal
// keeper without ending a terminal, and closes the archive last. HTTP
// disconnects and closing a local app tab never call it. The CLI drains HTTP
// before shutdown.
func (h *Host) Close() error {
	// The agents' processes end first and in parallel with the rest; the
	// CLI chats' Close waits for them (BeginShutdown began this already).
	if h.cliChats != nil {
		go h.cliChats.stopAgents()
	}
	// Web previews (preview.go): end sessions and their WebSockets.
	h.StopPreviews()
	// Routes: no more readings of Tailscale's status.
	h.routes.close()
	// Remote access: no more readings of the state file; tunnel connections end.
	h.remote.close()
	// Agents: installs, checks and automatic updates are cancelled and waited
	// for; their unfinished folders go.
	h.agents.close()
	// Plain chats: no more checks of the chat agent; the memory socket closes.
	h.plainChats.close()
	h.closeOnce.Do(func() {
		if h.stopMaintenance != nil {
			close(h.stopMaintenance)
			<-h.maintenanceDone
		}
	})
	// Archive backfill (M1 chunk B2): stop a running pass; its place is kept.
	if h.backfill != nil {
		h.backfill.stop()
	}
	// Vault: the writer stops between notes; the next start goes on from
	// its saved place.
	h.vault.close()
	// The chat hub stops its OpenCode event stream, reads and janitor and
	// ends open chat streams.
	if h.chat != nil {
		h.chat.close()
	}
	if h.cliChats != nil {
		h.cliChats.Close()
	}
	if h.terminals == nil {
		return h.closeArchive()
	}
	manager := h.terminals
	manager.mu.Lock()
	first := !manager.closed
	if first {
		// Re-attaching stops now.
		close(manager.closing)
	}
	manager.closed = true
	entries := make([]*terminalEntry, 0, len(manager.entries))
	for _, entry := range manager.entries {
		entries = append(entries, entry)
	}
	manager.mu.Unlock()
	// The terminals keep running in the keeper: closing their attachments
	// only stops the followers, which flush their logs.
	for _, entry := range entries {
		entry.mu.Lock()
		attachment := entry.attachment
		entry.mu.Unlock()
		if attachment != nil {
			attachment.Close()
		}
	}
	// The keeper keep-alive (terminal_keepalive.go) ends with closing; a
	// start it has under way is cancelled.
	if manager.keepAliveDone != nil {
		select {
		case <-manager.keepAliveDone:
		case <-time.After(terminalReaderWait):
		}
	}
	// A create that was already sent may still succeed after HTTP has
	// drained. Keep this process alive until its closed-manager path has
	// discarded that terminal. Add and the closed check share mu, so no new
	// Add can race with this Wait.
	manager.creating.Wait()
	// Archive (M1 chunk B1): the followers flush each log before the archive
	// closes.
	waitWithin(&manager.readers, terminalReaderWait)
	var all []error
	if first {
		all = append(all, manager.backend.Close())
	}
	manager.mu.Lock()
	all = append(all, manager.cleanupErrors...)
	manager.cleanupErrors = nil
	manager.mu.Unlock()
	return errors.Join(append(all, h.closeArchive())...)
}

// terminalReaderWait bounds how long Close waits for followers whose
// attachment did not end when closed, inside the Mac app's 2 s grace.
const terminalReaderWait = time.Second

func waitWithin(group *sync.WaitGroup, limit time.Duration) {
	done := make(chan struct{})
	go func() {
		group.Wait()
		close(done)
	}()
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	}
}

// closeArchive runs last in Close, after the terminal readers are done.
func (h *Host) closeArchive() error {
	// Notices (notices.go): what is queued is recorded before the archive
	// closes.
	h.notices.close()
	if h.archive == nil {
		return nil
	}
	return h.archive.Close()
}
