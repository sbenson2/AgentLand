package host

import (
	"context"
	"errors"
	"log"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"agentland/host/keeper"
)

// Mac-only terminal routes (docs/HOST-API.md "Mac-only terminal routes"): the
// Mac app's Quit question, its Terminals settings pane and device removal.
// They see every device's terminals, so they answer only this Mac's own
// session, never a device or the tunnel, and the web app never gets them.

// terminalFinishedKeep is how long a finished terminal stays listed, for its
// device to read how it ended, before the host clears it.
const terminalFinishedKeep = 24 * time.Hour

// terminalEndAllWait bounds POST /v1/terminals/end-all, which ends terminals
// in parallel and answers with those it has ended by then.
var terminalEndAllWait = 10 * time.Second

// terminalClearEvery is how often maintenance looks for finished terminals to
// clear.
const terminalClearEvery = time.Minute

// terminalClearWait is the deadline of one clearing pass from maintenance.
const terminalClearWait = 5 * time.Second

// localMacDeviceID owns the terminals opened from this Mac's own local web
// app (authenticate): no stored device.
const localMacDeviceID = "local-mac"

// macTerminal is one terminal as the Mac app lists it.
type macTerminal struct {
	ID            string `json:"id"`
	DeviceID      string `json:"deviceId"`
	DeviceName    string `json:"deviceName"`
	DeviceRemoved bool   `json:"deviceRemoved"`
	ProjectID     string `json:"projectId"`
	Workspace     string `json:"workspace"`
	Program       string `json:"program"`
	Title         string `json:"title"`
	Status        string `json:"status"`
	StartedAt     string `json:"startedAt"`
	EndedAt       string `json:"endedAt,omitempty"`
	Reason        string `json:"reason,omitempty"`
	// Routed says it is a coding agent typed in Terminal.app that the keeper
	// adopted (terminalMeta.Routed).
	Routed bool `json:"routed"`
	// For the Mac app's naming of every terminal (HostTerminalNaming): the
	// size a device last gave it (omitted while the host knows none), the
	// cursor after its newest output, and where its contextTitle came from
	// ("program" or "device", as TerminalInfo says).
	Rows               int    `json:"rows,omitempty"`
	Cols               int    `json:"cols,omitempty"`
	Cursor             uint64 `json:"cursor"`
	ContextTitleSource string `json:"contextTitleSource,omitempty"`
}

// clearedTerminal is what the host remembers, for a day, of a terminal it
// forgot (closed, cleared or ended with its device or workspace,
// forgetEntry): its workspace and how it ended.
type clearedTerminal struct {
	project string
	end     *TerminalEnd
	at      time.Time
}

// clearedEnd is how a terminal this host forgot ended (forgetEntry), for any
// paired device (terminal_shared.go) asking in the workspace it belonged to
// (an empty project names none, as terminalEntry reads it); nil in another
// workspace.
func (manager *terminalManager) clearedEnd(id, project string) *TerminalEnd {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	cleared, ok := manager.cleared[id]
	if !ok || (project != "" && cleared.project != project) || cleared.end == nil {
		return nil
	}
	end := *cleared.end
	return &end
}

// rememberLocked keeps how a forgotten terminal ended, and drops what was kept
// for another day; manager.mu is held. forgetEntry calls it as it drops the
// terminal, so a request that no longer finds the terminal finds its end.
func (manager *terminalManager) rememberLocked(entry *terminalEntry, now time.Time) {
	entry.mu.Lock()
	var end *TerminalEnd
	if entry.info.Ended != nil {
		copied := *entry.info.Ended
		end = &copied
	}
	project := entry.project.ID
	entry.mu.Unlock()
	for id, cleared := range manager.cleared {
		if now.Sub(cleared.at) >= terminalFinishedKeep {
			delete(manager.cleared, id)
		}
	}
	manager.cleared[entry.info.ID] = clearedTerminal{project: project, end: end, at: now}
}

// clearFinished clears every terminal that finished terminalFinishedKeep
// before now: the keeper forgets it (its log in the archive is already
// final) and the host drops it. A running terminal is never cleared; one the
// keeper could not forget stays for the next try. It returns how many it
// cleared.
func (manager *terminalManager) clearFinished(now time.Time) int {
	ctx, cancel := manager.requestContext(terminalClearWait)
	defer cancel()
	return manager.clearFinishedWithin(ctx, now)
}

// clearFinishedWithin is clearFinished for one pass bounded by ctx: it stops
// at the first terminal ctx no longer allows.
func (manager *terminalManager) clearFinishedWithin(ctx context.Context, now time.Time) int {
	if manager.isUnusable() {
		return 0
	}
	manager.mu.Lock()
	var due []*terminalEntry
	for _, entry := range manager.entries {
		entry.mu.Lock()
		old := entry.info.Status != "running" && !entry.endedAt.IsZero() && !entry.endedAt.After(now.Add(-terminalFinishedKeep))
		entry.mu.Unlock()
		if old {
			due = append(due, entry)
		}
	}
	manager.mu.Unlock()
	cleared := 0
	for _, entry := range due {
		if ctx.Err() != nil {
			break
		}
		if manager.clearEntry(ctx, entry, now) == nil {
			cleared++
		}
	}
	return cleared
}

// clearFinishedEveryMinute is maintenance's call: clearFinished at most once
// a minute.
func (manager *terminalManager) clearFinishedEveryMinute(stop <-chan struct{}) {
	if manager == nil {
		return
	}
	now := manager.now()
	manager.mu.Lock()
	due := now.Sub(manager.lastClear) >= terminalClearEvery || now.Before(manager.lastClear)
	if due {
		manager.lastClear = now
	}
	manager.mu.Unlock()
	if due {
		// One deadline for the pass, cancelled when maintenance is told to
		// stop, so a hung keeper never holds up the loop or Host.Close.
		ctx, cancel := manager.requestContext(terminalClearWait)
		defer cancel()
		go func() {
			select {
			case <-stop:
				cancel()
			case <-ctx.Done():
			}
		}()
		manager.clearFinishedWithin(ctx, now)
	}
}

// clearEntry forgets and drops a terminal that is not running, once no
// request is working on it, and remembers how it ended in the same step
// (forgetEntry), so no device reads it as gone without an end. A terminal
// that started running again or was already dropped is left alone.
func (manager *terminalManager) clearEntry(ctx context.Context, entry *terminalEntry, now time.Time) error {
	entry.writeMu.Lock()
	defer entry.writeMu.Unlock()
	if entry.running() {
		return errTerminalRunning
	}
	if err := manager.forgetEntry(ctx, entry, now); err != nil {
		log.Printf("terminals: could not clear id=%s workspace=%s: %v", entry.info.ID, entry.projectID(), err)
		return err
	}
	return nil
}

var errTerminalRunning = errors.New("the terminal is running")

// macAccess answers a Mac route when terminals are off; true when they are on.
func (h *Host) macAccess(w http.ResponseWriter) bool {
	if h.terminals == nil {
		writeError(w, 403, "terminal_disabled", "Enable terminal access explicitly on your AgentLand host")
		return false
	}
	return true
}

func (h *Host) macEntries() []*terminalEntry {
	manager := h.terminals
	manager.mu.Lock()
	defer manager.mu.Unlock()
	entries := make([]*terminalEntry, 0, len(manager.entries))
	for _, entry := range manager.entries {
		entries = append(entries, entry)
	}
	return entries
}

func (h *Host) macTerminalsRunning(w http.ResponseWriter, r *http.Request) {
	if !h.macAccess(w) {
		return
	}
	// While the keeper is unusable the host cannot say how many run; a count
	// of 0 would read as none, so the Mac app gets the same 503 as the device
	// routes and asks instead.
	if h.terminalsUnavailable(w) {
		return
	}
	// Routed agents are counted on their own too: ending all keeps them
	// running in Terminal.app (macEnd).
	var count struct {
		Running int `json:"running"`
		Routed  int `json:"routed"`
	}
	for _, entry := range h.macEntries() {
		if entry.running() {
			count.Running++
			if entry.routed() {
				count.Routed++
			}
		}
	}
	writeJSON(w, 200, count)
}

func (h *Host) macTerminalsAll(w http.ResponseWriter, r *http.Request) {
	if !h.macAccess(w) {
		return
	}
	// A running keeper says whether it takes routed agents (adopts): one
	// from an AgentLand before adopt that holds terminals doesn't, until
	// they end (terminal_keepalive.go).
	keeperState := map[string]any{"state": "running"}
	if h.terminals.isUnusable() {
		keeperState = map[string]any{"state": "unavailable", "reason": terminalsUnavailableMessage}
	} else {
		ctx, cancel := h.terminals.requestContext(terminalAttachWait)
		status := h.terminals.backend.Status(ctx)
		switch status {
		case KeeperNone:
			keeperState = map[string]any{"state": "none"}
		case KeeperUnusable:
			keeperState = map[string]any{"state": "unavailable", "reason": terminalsUnavailableMessage}
		default:
			if adopts, known := h.terminals.keeperAdopts(ctx); known {
				keeperState["adopts"] = adopts
			}
		}
		cancel()
	}
	names, revoked := map[string]string{}, map[string]bool{}
	if devices, err := h.store.ListDevices(); err == nil {
		for _, device := range devices {
			names[device.ID] = device.Name
			revoked[device.ID] = device.RevokedAt != nil
		}
	}
	type listed struct {
		macTerminal
		started time.Time
	}
	var all []listed
	for _, entry := range h.macEntries() {
		entry.mu.Lock()
		info := entry.info
		title := info.ContextTitle
		if title == "" {
			title = info.ProgramTitle
		}
		if title == "" {
			title = info.Title
		}
		started := entry.meta.Created
		if started.IsZero() {
			started = entry.started
		}
		terminal := macTerminal{ID: info.ID, DeviceID: entry.owner, DeviceName: names[entry.owner], ProjectID: entry.project.ID, Workspace: entry.project.Name,
			Program: entry.program, Title: title, Status: info.Status, StartedAt: started.UTC().Format(archiveTimeLayout), Routed: entry.meta.Routed,
			Rows: entry.rows, Cols: entry.cols, Cursor: entry.cursor, ContextTitleSource: info.ContextTitleSource}
		_, known := names[entry.owner]
		terminal.DeviceRemoved = !known || revoked[entry.owner]
		if entry.owner == localMacDeviceID {
			terminal.DeviceName, terminal.DeviceRemoved = "This Mac", false
		}
		if info.Status != "running" && !entry.endedAt.IsZero() {
			terminal.EndedAt = entry.endedAt.UTC().Format(archiveTimeLayout)
		}
		if info.Ended != nil {
			terminal.Reason = info.Ended.Reason
		}
		entry.mu.Unlock()
		all = append(all, listed{terminal, started})
	}
	sort.Slice(all, func(i, j int) bool {
		if !all[i].started.Equal(all[j].started) {
			return all[i].started.Before(all[j].started)
		}
		return all[i].ID < all[j].ID
	})
	terminals := make([]macTerminal, len(all))
	for index, item := range all {
		terminals[index] = item.macTerminal
	}
	writeJSON(w, 200, map[string]any{"keeper": keeperState, "terminals": terminals})
}

// macEnd ends the running terminals among entries as reason, in parallel,
// and waits at most limit for them. A running routed agent is released to its
// Terminal.app window instead (releaseEntry), where it goes on. It returns
// how many it ended and released by then and whether every request finished;
// entries.writeMu is taken per terminal.
func (h *Host) macEnd(entries []*terminalEntry, reason string, forget bool, limit time.Duration) (ended, released int, complete, failed bool) {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	var count, releases atomic.Int64
	var failures atomic.Int64
	var group sync.WaitGroup
	for _, entry := range entries {
		group.Add(1)
		go func() {
			defer group.Done()
			entry.writeMu.Lock()
			defer entry.writeMu.Unlock()
			wasRunning := entry.running()
			release := wasRunning && entry.routed()
			var err error
			switch {
			case release:
				err = h.terminals.releaseEntry(ctx, entry)
				if err == nil && forget {
					err = h.terminals.forgetEntry(ctx, entry, h.terminals.now())
				}
			case forget:
				err = h.terminals.endAndForget(ctx, entry, reason, nil)
			default:
				err = h.terminals.endEntry(ctx, entry, reason, nil)
			}
			if err != nil {
				failures.Add(1)
				log.Printf("terminals: could not end id=%s workspace=%s: %v", entry.info.ID, entry.projectID(), err)
				return
			}
			switch {
			case release:
				releases.Add(1)
			case wasRunning:
				count.Add(1)
			}
		}()
	}
	done := make(chan struct{})
	go func() { group.Wait(); close(done) }()
	select {
	case <-done:
		complete = true
	case <-ctx.Done():
	}
	return int(count.Load()), int(releases.Load()), complete, failures.Load() > 0
}

func (h *Host) macTerminalsEndAll(w http.ResponseWriter, r *http.Request) {
	if !h.macAccess(w) || h.terminalsUnavailable(w) {
		return
	}
	var running []*terminalEntry
	for _, entry := range h.macEntries() {
		if entry.running() {
			running = append(running, entry)
		}
	}
	ended, released, _, _ := h.macEnd(running, terminalEndHostStopped, false, terminalEndAllWait)
	writeJSON(w, 200, struct {
		Ended    int `json:"ended"`
		Released int `json:"released"`
	}{ended, released})
}

// macTerminalNamed finds the terminal a Mac route names, answering 404.
func (h *Host) macTerminalNamed(w http.ResponseWriter, r *http.Request) *terminalEntry {
	var input struct {
		TerminalID string `json:"terminalId"`
	}
	if !decode(w, r, &input) || h.terminalsUnavailable(w) {
		return nil
	}
	h.terminals.mu.Lock()
	entry := h.terminals.entries[input.TerminalID]
	h.terminals.mu.Unlock()
	if entry == nil {
		writeError(w, 404, "terminal_not_found", "Terminal not found")
		return nil
	}
	return entry
}

func (h *Host) macTerminalsEnd(w http.ResponseWriter, r *http.Request) {
	if !h.macAccess(w) {
		return
	}
	entry := h.macTerminalNamed(w, r)
	if entry == nil {
		return
	}
	entry.writeMu.Lock()
	defer entry.writeMu.Unlock()
	if !entry.running() {
		writeError(w, 409, "terminal_not_running", "The terminal has already ended")
		return
	}
	// The entry stays, ended, so its device learns how it ended.
	if err := h.terminals.endEntry(context.Background(), entry, terminalEndOnMac, nil); err != nil {
		log.Printf("terminals: could not end id=%s workspace=%s: %v", entry.info.ID, entry.projectID(), err)
		internal(w)
		return
	}
	writeJSON(w, 200, map[string]bool{"ended": true})
}

func (h *Host) macTerminalsClear(w http.ResponseWriter, r *http.Request) {
	if !h.macAccess(w) {
		return
	}
	entry := h.macTerminalNamed(w, r)
	if entry == nil {
		return
	}
	err := h.terminals.clearEntry(r.Context(), entry, h.terminals.now())
	switch {
	case errors.Is(err, errTerminalRunning):
		writeError(w, 409, "terminal_running", "End the terminal before clearing it")
	case err != nil && !keeper.IsNotFound(err):
		internal(w)
	default:
		writeJSON(w, 200, map[string]bool{"cleared": true})
	}
}

func (h *Host) macTerminalsEndDevice(w http.ResponseWriter, r *http.Request) {
	if !h.macAccess(w) {
		return
	}
	var input struct {
		DeviceID string `json:"deviceId"`
	}
	if !decode(w, r, &input) {
		return
	}
	// This Mac's terminals (routed agents, the browser's) are its own and
	// are never ended as a removed device's.
	if input.DeviceID == localMacDeviceID {
		writeError(w, 400, "invalid_request", "This Mac's terminals are never ended with a device's")
		return
	}
	if h.terminalsUnavailable(w) {
		return
	}
	var owned []*terminalEntry
	for _, entry := range h.macEntries() {
		if entry.owner == input.DeviceID {
			owned = append(owned, entry)
		}
	}
	// Running or finished, they all go; a terminal the keeper could not end
	// or forget stays for another try.
	ended, _, complete, failed := h.macEnd(owned, terminalEndDeviceRemoved, true, terminalRequestWait+terminalRequestWait)
	if !complete || failed {
		internal(w)
		return
	}
	writeJSON(w, 200, map[string]int{"ended": ended})
}
