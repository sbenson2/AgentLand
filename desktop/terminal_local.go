package host

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"agentland/host/internal/localsock"
	"agentland/host/internal/localterm"
	"agentland/host/keeper"
)

// Terminals from Terminal.app (docs/HOST-API.md, "Terminals started in Terminal
// on the Mac"). `agentland-host
// terminals run -- claude …`, typed in Terminal.app, registers the agent here
// before it starts it: the host answers the terminal's id and the record the
// keeper is to hold, the CLI has the keeper adopt the agent's PTY, and the
// host follows that terminal as this Mac's (owner local-mac), in the deepest
// workspace holding its folder or in none. The CLI starts the program
// itself; the host never builds a command for it, and devices still start
// only what the host chooses (terminal_launch.go).
//
// The socket (localterm.SocketPath) is bound 0600 by localsock and each
// connection is checked with SameUserPeer, so only this user's own processes
// reach it. It is never bound to TCP or carried through the tunnel, and no
// HTTP route registers a terminal.

// localRegisterWait bounds the registration's first line; localAdoptWait how
// long the host waits for "adopted" after it answered.
const (
	localRegisterWait = 2 * time.Second
	localAdoptWait    = 10 * time.Second
)

// localFeaturesWait bounds asking the keeper whether it adopts PTYs, within
// the CLI's 1 s budget for setting up.
const localFeaturesWait = time.Second

// localTerminals is the registration socket and the connections it serves.
type localTerminals struct {
	host   *Host
	socket *localsock.Socket
	done   chan struct{}
	once   sync.Once
	mu     sync.Mutex
	conns  map[net.Conn]struct{}
	// work counts the accept loop and each connection; Close waits for them.
	work sync.WaitGroup
}

// ListenLocalTerminals serves Terminal.app's registrations at path (beside
// the keeper's socket, localterm.SocketPath) until the closer closes. It
// serves even with terminal access off, to say so at once. Close stops
// taking connections, removes the socket, hangs up the open ones (a
// terminal the keeper adopted meanwhile stays there, for the next host) and
// waits for them.
func (h *Host) ListenLocalTerminals(path string) (io.Closer, error) {
	socket, err := localsock.Listen(path)
	switch {
	case errors.Is(err, localsock.ErrInUse):
		return nil, fmt.Errorf("another host serves the local terminal socket %s", path)
	case errors.Is(err, localsock.ErrNotSocket):
		return nil, fmt.Errorf("%s exists and is not a socket; remove it", path)
	case err != nil:
		return nil, err
	}
	l := &localTerminals{host: h, socket: socket, done: make(chan struct{}), conns: map[net.Conn]struct{}{}}
	l.work.Add(1)
	go l.accept()
	return l, nil
}

func (l *localTerminals) Close() error {
	var err error
	l.once.Do(func() {
		close(l.done)
		err = l.socket.Close()
		l.mu.Lock()
		for conn := range l.conns {
			conn.Close()
		}
		l.mu.Unlock()
	})
	l.work.Wait()
	return err
}

func (l *localTerminals) closing() bool {
	select {
	case <-l.done:
		return true
	default:
		return false
	}
}

func (l *localTerminals) accept() {
	defer l.work.Done()
	backoff := 5 * time.Millisecond
	for {
		conn, err := l.socket.Listener.Accept()
		if err != nil {
			if l.closing() || errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(backoff)
			backoff = min(2*backoff, time.Second)
			continue
		}
		backoff = 5 * time.Millisecond
		// The accept loop's own count keeps work above zero, so this Add
		// never races Close's Wait.
		l.work.Add(1)
		go func() {
			defer l.work.Done()
			if !l.track(conn) {
				conn.Close()
				return
			}
			defer l.untrack(conn)
			l.serve(conn)
		}()
	}
}

func (l *localTerminals) track(conn net.Conn) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closing() {
		return false
	}
	l.conns[conn] = struct{}{}
	return true
}

func (l *localTerminals) untrack(conn net.Conn) {
	l.mu.Lock()
	delete(l.conns, conn)
	l.mu.Unlock()
}

// serve is one registration (the package localterm's flow). A connection from
// another user's process is closed without a word.
func (l *localTerminals) serve(conn net.Conn) {
	defer conn.Close()
	if err := localsock.SameUserPeer(conn); err != nil {
		log.Printf("terminals: refused a local terminal connection: %v", err)
		return
	}
	h := l.host
	reader := bufio.NewReaderSize(conn, 4<<10)
	_ = conn.SetReadDeadline(time.Now().Add(localRegisterWait))
	var request localterm.Request
	err := localterm.ReadLine(reader, &request)
	if errors.Is(err, io.EOF) {
		return
	}
	if err != nil || request.Op != localterm.OpRegister {
		localReply(conn, localterm.Reply{Error: &localterm.Error{Code: localterm.CodeBadRequest, Message: "AgentLand expected a terminal to register."}})
		return
	}
	registration, refusal := h.registerLocalTerminal(request)
	if refusal != nil {
		log.Printf("terminals: refused a terminal from Terminal.app: %s", refusal.Code)
		localReply(conn, localterm.Reply{Error: refusal})
		return
	}
	defer registration.release()
	err = localReply(conn, localterm.Reply{ID: registration.id, Meta: registration.record})
	var next localterm.Request
	if err == nil {
		_ = conn.SetReadDeadline(time.Now().Add(localAdoptWait))
		err = localterm.ReadLine(reader, &next)
	}
	if err == nil && next.Op == localterm.OpCancel {
		log.Printf("terminals: id=%s cancelled in Terminal.app", registration.id)
		return
	}
	// "adopted", or the CLI went quiet or away: the keeper says whether it
	// has the terminal. As the host stops it is left there, for the next host.
	if l.closing() {
		return
	}
	var answer localterm.Reply
	switch err := h.adoptLocalTerminal(registration); {
	case err == nil:
		answer.OK = true
	case errors.Is(err, errLocalNotAdopted):
		answer.Error = &localterm.Error{Code: localterm.CodeBadRequest, Message: "AgentLand's terminal service doesn't have this terminal."}
	case errors.Is(err, errHostStopping):
		answer.Error = &localterm.Error{Code: localterm.CodeStopping, Message: "AgentLand's host is stopping."}
	default:
		log.Printf("terminals: could not take id=%s from the terminal service: %v", registration.id, err)
		answer.Error = &localterm.Error{Code: localterm.CodeUnavailable, Message: terminalsUnavailableMessage}
	}
	// The CLI may have hung up already; then nothing reads this.
	localReply(conn, answer)
}

// localReply writes one line within localRegisterWait.
func localReply(conn net.Conn, reply localterm.Reply) error {
	_ = conn.SetWriteDeadline(time.Now().Add(localRegisterWait))
	return localterm.WriteLine(conn, reply)
}

// localRegistration is a registration the host answered: the terminal's id
// and record, holding a place under the cap until release.
type localRegistration struct {
	manager *terminalManager
	id      string
	meta    terminalMeta
	record  []byte
	once    sync.Once
}

func (r *localRegistration) release() {
	r.once.Do(func() {
		r.manager.mu.Lock()
		r.manager.starting--
		r.manager.mu.Unlock()
	})
}

func localRefusal(code, message string) *localterm.Error {
	return &localterm.Error{Code: code, Message: message}
}

// registerLocalTerminal checks a registration and holds a place for it. The
// refusals come in this order: terminal access off, another version, a
// program AgentLand does not route, a folder that is not a clean absolute
// path, a keeper that cannot adopt PTYs (unusable, not answering
// within localFeaturesWait, or without the adopt feature), a host that is
// stopping, and the 16-terminal cap. The record names this Mac, the
// deepest workspace holding the folder (or none), the folder as sent, the
// program and its label, the Claude Code conversation when the CLI named a
// valid one, and Routed.
func (h *Host) registerLocalTerminal(request localterm.Request) (*localRegistration, *localterm.Error) {
	if h.terminals == nil {
		return nil, localRefusal(localterm.CodeDisabled, "AgentLand's terminal access is off.")
	}
	if request.Version != h.version {
		return nil, localRefusal(localterm.CodeVersion, "This command and the AgentLand host running now are different versions.")
	}
	program, ok := routedProgram(request.Command)
	if !ok {
		return nil, localRefusal(localterm.CodeUnknownProgram, "AgentLand doesn't open this program in its terminals.")
	}
	folder, err := localTerminalFolder(request.Folder)
	if err != nil {
		return nil, localRefusal(localterm.CodeBadRequest, "The terminal's folder must be named by a clean absolute path.")
	}
	manager := h.terminals
	if !h.terminalsAdopt() {
		return nil, localRefusal(localterm.CodeUnavailable, terminalsUnavailableMessage)
	}
	project := h.deepestWorkspaceNow(folder)
	meta := terminalMeta{Owner: localMacDeviceID, Project: project.ID, Folder: folder, Program: program, Title: routedProgramLabel(program), Routed: true, Created: h.now().UTC()}
	if conversationIDPattern.MatchString(request.ConversationID) {
		meta.ConversationID = request.ConversationID
	}
	record, err := meta.encode()
	if err != nil {
		return nil, localRefusal(localterm.CodeBadRequest, "AgentLand could not describe this terminal.")
	}
	manager.mu.Lock()
	stopping := manager.closed
	select {
	case <-h.stopping:
		stopping = true
	default:
	}
	if stopping {
		manager.mu.Unlock()
		return nil, localRefusal(localterm.CodeStopping, "AgentLand's host is stopping.")
	}
	if len(manager.entries)+manager.starting >= terminalCapacity {
		manager.mu.Unlock()
		return nil, localRefusal(localterm.CodeLimit, fmt.Sprintf("AgentLand has %d terminals open.", terminalCapacity))
	}
	manager.starting++
	manager.mu.Unlock()
	registration := &localRegistration{manager: manager, id: newTerminalID(), meta: meta, record: record}
	log.Printf("terminals: registered id=%s workspace=%s program=%s from Terminal.app", registration.id, project.ID, program)
	return registration, nil
}

// terminalsAdopt is whether the keeper can take a PTY it did not start: it
// is usable and says it adopts (keeper.FeatureAdopt) within
// localFeaturesWait. Asking starts a keeper when none runs, as a spawn does.
func (h *Host) terminalsAdopt() bool {
	manager := h.terminals
	if manager.isUnusable() {
		return false
	}
	ctx, cancel := manager.requestContext(localFeaturesWait)
	defer cancel()
	features, err := manager.backend.Features(ctx)
	return err == nil && slices.Contains(features, keeper.FeatureAdopt)
}

// localTerminalFolder is a registration's folder when it is an absolute,
// clean path without NUL: the CLI's cwd, which it sends canonical
// (localterm.Request.Folder). The host only reads the string. It never
// opens, stats or lists the folder, since on macOS that could ask the person
// to let AgentLand into it (terminalFolderJoiner); a folder that is not there
// simply lies in no workspace.
func localTerminalFolder(raw string) (string, error) {
	if raw == "" || len(raw) > localterm.MaxLine || strings.ContainsRune(raw, 0) || !filepath.IsAbs(raw) || filepath.Clean(raw) != raw {
		return "", errFolderPath
	}
	return raw, nil
}

// errLocalNotAdopted: the keeper holds no terminal it adopted with the
// registration's id, so the CLI never handed it over.
var errLocalNotAdopted = errors.New("the terminal service holds no adopted terminal with this id")

// adoptLocalTerminal follows the registered terminal once the keeper holds
// it: its entry is built from the keeper's information and the host's record
// (restoredEntry: its pid, start time, title names and conversation) and
// installed (installEntry), which places it in the deepest workspace holding
// its folder at that moment. A terminal whose agent already exited is
// followed all the same, so its output is archived and it is cleared. As the
// host closes it is left in the keeper, for the next host.
func (h *Host) adoptLocalTerminal(registration *localRegistration) error {
	manager := h.terminals
	ctx, cancel := manager.requestContext(terminalAttachWait)
	infos, err := manager.backend.List(ctx)
	cancel()
	if err != nil {
		return err
	}
	index := slices.IndexFunc(infos, func(info keeper.Info) bool { return info.ID == registration.id })
	if index < 0 || !infos[index].Adopted {
		log.Printf("terminals: id=%s never reached the terminal service", registration.id)
		return errLocalNotAdopted
	}
	info := infos[index]
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		return errHostStopping
	}
	if manager.entries[registration.id] != nil {
		// A restore (the keeper was unusable for a moment) took it first.
		manager.mu.Unlock()
		return nil
	}
	// Host.Close waits for it, as for a device's create.
	manager.creating.Add(1)
	manager.mu.Unlock()
	defer manager.creating.Done()
	entry := h.restoredEntry(info, registration.meta, Project{})
	entry.info.Directory = registration.meta.Folder
	switch err := h.installEntry(entry); {
	case errors.Is(err, errWorkspaceRemovedAtStart):
		// It was listed and is followed; the removal ended it, as it ends
		// every terminal of that workspace.
		log.Printf("terminals: id=%s went with its workspace=%s, removed as it started", registration.id, entry.projectID())
		return nil
	case err != nil:
		return err
	}
	log.Printf("terminals: following id=%s workspace=%s program=%s from Terminal.app", registration.id, entry.projectID(), registration.meta.Program)
	return nil
}

// placeRouted puts a routed agent in the deepest workspace holding its
// folder now (installEntry holds h.workspaceMu).
func (h *Host) placeRouted(entry *terminalEntry) {
	project := h.deepestWorkspaceNow(entry.info.Directory)
	entry.mu.Lock()
	entry.project = project
	entry.info.ProjectID = project.ID
	entry.meta.Project = project.ID
	entry.mu.Unlock()
}

// deepestWorkspaceNow is the deepest configured workspace holding folder, or
// Project{}.
func (h *Host) deepestWorkspaceNow(folder string) Project {
	st, err := h.store.Read()
	if err != nil {
		log.Printf("terminals: could not read the workspaces: %v", err)
		return Project{}
	}
	project, _ := deepestWorkspace(st.Config.Projects, folder)
	return project
}

// deepestWorkspace is the workspace whose folder is folder or holds it,
// the deepest of them, compared as terminalFolderJoiner does: each
// workspace's directory read once, canonical, and folder only as a string.
func deepestWorkspace(projects []Project, folder string) (Project, bool) {
	if folder == "" {
		return Project{}, false
	}
	var best Project
	length := -1
	for _, project := range projects {
		if project.Directory == "" {
			continue
		}
		directory := newWorkspaceDirectory(project.Directory)
		if directory.holds(folder) && len(directory.canonical) > length {
			best, length = project, len(directory.canonical)
		}
	}
	return best, length >= 0
}

// routedProgram is the program id a command typed in Terminal.app runs: its
// name (the command's last element) is a known agent CLI's
// (localAgentSpecs), or opencode.
func routedProgram(command string) (string, bool) {
	name := filepath.Base(command)
	if name == "opencode" {
		return "opencode", true
	}
	for _, spec := range localAgentSpecs {
		if spec.program == name {
			return spec.id, true
		}
	}
	return "", false
}

// routedProgramLabel is the name the apps give a routed program: its terminal
// label (terminalProgramLabels), else its agent's name.
func routedProgramLabel(id string) string {
	if label := terminalProgramLabels[id]; label != "" {
		return label
	}
	if spec, ok := localAgentSpecFor(id); ok {
		return spec.name
	}
	return id
}
