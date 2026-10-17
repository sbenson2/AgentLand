package host

import (
	"context"
	"errors"
	"log"
	"strings"
	"time"

	"agentland/host/keeper"
)

// Restore at start (design: "Host: backend and restore"). Before the host
// serves, it takes back the terminals a running keeper still holds, with the
// same IDs and byte cursors, so devices find them where they left them, and
// each goes on in the archive log it had. Logs of terminals no keeper holds
// are settled; a keeper this build cannot use leaves everything as it is
// and is looked at again every keeperRetryEvery.

// terminalRestoreWait bounds one restore, and terminalProbeWait its first
// questions to the keeper (Status, List): a keeper that takes the connection
// but never answers reads as unusable that soon, so the host still serves.
const (
	terminalRestoreWait = 5 * time.Second
	terminalProbeWait   = 1500 * time.Millisecond
)

// keeperRetryEvery is how often an unusable keeper is looked at again. A
// host reads it once, when it is made (tests shorten it).
var keeperRetryEvery = 30 * time.Second

// terminalReattachQuick is how soon an attachment must fail, without an
// event, for its re-attach to count as a failed try (follow).
const terminalReattachQuick = time.Second

// legacyPTYEnder is a chat agent that can end an older host's terminal, run
// as one of OpenCode's PTYs (OpenCodeAdapter.endLegacyPTY).
type legacyPTYEnder interface {
	endLegacyPTY(ctx context.Context, project Project, id string) error
}

// restoreTerminals settles the terminals by what the keeper says, within
// terminalRestoreWait and until the host closes:
//   - none runs: every terminal ended with it. Running logs end as
//     keeperStopped (an older host's OpenCode terminals, "pty_", as
//     hostStopped), and so do terminals this host still followed;
//   - one runs: each of its terminals is rebuilt (restoreTerminal), and the
//     running logs of terminals it does not hold end as above;
//   - one runs that cannot be used: nothing changes, the routes answer
//     terminals_unavailable, and the retry loop runs this again.
//
// Once the logs are settled, an older host's OpenCode PTYs are ended in the
// background (endLegacyPTYs), so a slow OpenCode never delays the keeper's
// terminals. The host runs this in NewWithOptions, before it serves, and the
// retry loop runs it while the keeper is unusable.
func (h *Host) restoreTerminals(ctx context.Context) {
	manager := h.terminals
	if manager == nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, terminalRestoreWait)
	defer cancel()
	go func() {
		select {
		case <-manager.closing:
			cancel()
		case <-ctx.Done():
		}
	}()
	running := h.runningTerminalLogs(ctx)
	probe, cancelProbe := context.WithTimeout(ctx, terminalProbeWait)
	defer cancelProbe()
	switch manager.backend.Status(probe) {
	case KeeperUnusable:
		manager.setUnusable()
		return
	case KeeperNone:
		manager.keeperStopped()
		h.reconcileTerminalLogs(nil)
		manager.setUsable()
		h.endLegacyPTYs(running)
		return
	}
	infos, err := manager.backend.List(probe)
	cancelProbe()
	if err != nil {
		log.Printf("terminals: could not list the terminal service's terminals: %v", err)
		manager.setUnusable()
		return
	}
	// The newest running log of each terminal, for records that lost theirs.
	logs := map[string]string{}
	for index := len(running) - 1; index >= 0; index-- {
		logs[running[index].terminalID] = running[index].id
	}
	held, listed, again := map[string]bool{}, map[string]bool{}, false
	for _, info := range infos {
		listed[info.ID] = true
		keeps, retry := h.restoreTerminal(ctx, info, logs)
		held[info.ID] = keeps
		again = again || retry
	}
	// Terminals this host followed that this keeper does not hold ended with
	// the keeper that held them.
	manager.mu.Lock()
	var gone []*terminalEntry
	for id, entry := range manager.entries {
		if !listed[id] {
			gone = append(gone, entry)
		}
	}
	manager.mu.Unlock()
	for _, entry := range gone {
		manager.endKeeperStopped(entry)
	}
	h.reconcileTerminalLogs(held)
	h.endLegacyPTYs(running)
	if again {
		manager.setUnusable()
		return
	}
	manager.setUsable()
	// A terminal that finished more than a day ago, while no host followed it,
	// is cleared now.
	manager.clearFinishedWithin(ctx, manager.now())
}

// terminalLeftoverWait bounds ending a keeper's terminals when the host
// starts with terminal access off (endLeftoverTerminals).
const terminalLeftoverWait = 10 * time.Second

// leftoverTerminalEnder is a backend that can end what a keeper runs without
// starting one (keeperBackend.endLeftovers).
type leftoverTerminalEnder interface {
	endLeftovers(ctx context.Context) (running int, found bool, err error)
}

// endLeftoverTerminals is for a host whose terminal access is off (controller
// ruling 32): a keeper still running for its state is asked, in the
// background and within terminalLeftoverWait, to end every terminal and exit,
// so no terminal outlives the switch however it went off (the host was down,
// or crashed mid-restart). It never starts a keeper, and a keeper it cannot
// use is left alone. The host serves meanwhile; it has no terminal routes.
func (h *Host) endLeftoverTerminals(options HostOptions) {
	if options.TerminalEnabled || options.Terminals == nil {
		return
	}
	backend := options.Terminals
	ender, ok := backend.(leftoverTerminalEnder)
	if !ok {
		backend.Close()
		return
	}
	go func() {
		defer backend.Close()
		ctx, cancel := context.WithTimeout(context.Background(), terminalLeftoverWait)
		defer cancel()
		running, found, err := ender.endLeftovers(ctx)
		switch {
		case err != nil:
			log.Printf("terminals: could not end the terminals left running while terminal access was off: %v", err)
		case found:
			log.Printf("terminals: ended %d left running while terminal access was off", running)
		}
	}()
}

// restoreTerminal takes back one terminal the keeper holds. keeps says the
// keeper still holds it for this host, so its log stays running; again says
// restore must run again (the state could not be read).
//   - A record a newer build wrote (terminalMeta.V above this build's): it
//     is that build's, so it is left running, its log too, and listed to no
//     one.
//   - A record that does not decode: the terminal is ended and forgotten; one
//     the keeper adopted is released to its Terminal.app window instead,
//     where the user's program goes on.
//   - A removed workspace: the terminal is ended as workspaceRemoved, its
//     log records that, and it is forgotten. A record with no workspace (V2)
//     is a terminal outside any, never one whose workspace was removed.
//   - Otherwise its entry is rebuilt from the record and the keeper's pid and
//     start time, and its output replayed from the ring's start (replay). One
//     that finished while the host was away comes back ended, with its exit
//     code, until its device closes it; a routed agent's is cleared at once
//     (clearRouted). A running one is followed.
//
// A terminal this host already has is followed again when its follower
// stopped (the keeper could not be used for it).
func (h *Host) restoreTerminal(ctx context.Context, info keeper.Info, logs map[string]string) (keeps, again bool) {
	manager := h.terminals
	manager.mu.Lock()
	existing := manager.entries[info.ID]
	manager.mu.Unlock()
	if existing != nil {
		manager.followAgain(existing)
		return true, false
	}
	meta, err := decodeTerminalMeta(info.Meta)
	var newer *newerTerminalMetaError
	if errors.As(err, &newer) {
		log.Printf("terminals: restore skipped id=%s meta-version=%d", info.ID, newer.version)
		return true, false
	}
	if err != nil {
		drop, verb := manager.discard, "end"
		if info.Adopted {
			drop, verb = manager.discardAdopted, "release"
		}
		if err := drop(ctx, info.ID); err != nil {
			log.Printf("terminals: could not %s id=%s, whose record does not decode: %v", verb, info.ID, err)
		}
		log.Printf("terminals: restore dropped id=%s", info.ID)
		return false, false
	}
	var project Project
	removed := false
	if meta.Project != "" {
		project, err = h.project(meta.Project)
		removed = errors.Is(err, ErrNotFound)
		if err != nil && !removed {
			log.Printf("terminals: could not restore id=%s: %v", info.ID, err)
			return true, true
		}
		if removed {
			project = Project{ID: meta.Project}
		}
	}
	entry := h.restoredEntry(info, meta, project)
	entry.log = h.restoredLog(ctx, entry, info, logs)
	attachment, exit, exited := manager.replay(ctx, entry, info)
	if exited || !info.Running {
		if attachment != nil {
			attachment.Close()
			attachment = nil
		}
		if !exited {
			exit = info.Exit
		}
		entry.endFinished(exit)
	}
	if removed {
		if attachment != nil {
			attachment.Close()
		}
		if err := manager.endAndForget(ctx, entry, terminalEndWorkspaceRemoved, nil); err != nil {
			log.Printf("terminals: could not end id=%s, whose workspace=%s was removed: %v", info.ID, meta.Project, err)
			// The next restore tries again, in the same log.
			entry.log.Detach()
			return true, false
		}
		return false, false
	}
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		if attachment != nil {
			attachment.Close()
		}
		return true, false
	}
	if existing := manager.entries[info.ID]; existing != nil {
		// A local registration (terminal_local.go) listed it meanwhile: that
		// entry follows it. This one's log stops, and the keeper's record
		// names that entry's again.
		manager.mu.Unlock()
		if attachment != nil {
			attachment.Close()
		}
		entry.log.Detach()
		manager.saveMeta(existing)
		return true, false
	}
	entry.mu.Lock()
	follow := entry.info.Status == "running"
	entry.following = follow
	entry.attachment = attachment
	status := entry.info.Status
	entry.mu.Unlock()
	if !follow {
		close(entry.done)
	}
	manager.entries[info.ID] = entry
	if follow {
		manager.readers.Add(1)
	}
	manager.mu.Unlock()
	log.Printf("terminals: restored id=%s workspace=%s program=%s status=%s", info.ID, meta.Project, meta.Program, status)
	if follow {
		go func() {
			defer manager.readers.Done()
			entry.follow(manager)
		}()
	} else if meta.Routed {
		manager.clearRouted(entry)
	}
	return true, false
}

// restoredEntry is a terminal the keeper holds, as its record describes it;
// its ring starts where the keeper's does, so devices' cursors stay valid.
// Its folder is the record's, else its workspace's.
func (h *Host) restoredEntry(info keeper.Info, meta terminalMeta, project Project) *terminalEntry {
	started := info.Started
	if started.IsZero() {
		started = time.Now()
	}
	directory := meta.Folder
	if directory == "" {
		directory = project.Directory
	}
	// A device's name stays a device's across the restart, so the replay and
	// the program's later titles leave it; an older build's record named no
	// source, and its description counts as the program's.
	source := meta.ContextTitleSource
	if source == "" && meta.ContextTitle != "" {
		source = contextFromProgram
	}
	entry := &terminalEntry{owner: meta.Owner, project: project, meta: meta, output: []byte{}, start: info.Start, cursor: info.Start,
		changed: make(chan struct{}), pid: info.PID, started: started, program: meta.Program, done: make(chan struct{}), clock: h.now,
		info: TerminalInfo{ID: info.ID, Title: meta.Title, ProjectID: meta.Project, Status: "running", ContextTitle: meta.ContextTitle,
			ContextTitleSource: source, ConversationID: meta.ConversationID, PID: info.PID, Directory: directory}}
	names := terminalGenericNames(meta.Program, meta.Title)
	switch meta.Program {
	case "shell", "opencode", "claude", "codex":
	default:
		names = append(names, h.agents.agentName(meta.Program))
	}
	entry.titles.names = names
	return entry
}

// restoredLog is the log a restored terminal goes on in: the one its record
// names or, when the record lost it, the newest running log of that terminal
// (logs). Only when the archive has no such log is a new one opened, from
// the terminal's start, so what the ring no longer holds counts as a gap; a
// log that already recorded the terminal's end (it finished while no host
// followed it, and no device has closed it yet) is complete, and the
// terminal goes on without one. The keeper's record learns a log it did not
// name.
func (h *Host) restoredLog(ctx context.Context, entry *terminalEntry, info keeper.Info, logs map[string]string) *TerminalLog {
	if h.archive == nil {
		return nil
	}
	named := entry.meta.LogID
	if named == "" {
		named = logs[info.ID]
	}
	terminalLog, exists := h.resumeTerminalLog(info.ID, named)
	if !exists {
		terminalLog = h.openTerminalLog(entry, entry.program, entry.started)
	}
	if terminalLog == nil || terminalLog.ID() == entry.meta.LogID {
		return terminalLog
	}
	entry.meta.LogID = terminalLog.ID()
	record, err := entry.meta.encode()
	if err == nil {
		err = h.terminals.backend.SetMeta(ctx, info.ID, record)
	}
	if err != nil {
		log.Printf("terminals: could not record id=%s's log in the terminal service: %v", info.ID, err)
	}
	return terminalLog
}

// replay feeds the output the keeper holds of a terminal, from the ring's
// start, through the entry's ring, program title and log (receive, which
// leaves the restored description alone), until it reaches the
// cursor the keeper listed or the terminal's exit, within ctx. It returns the
// attachment follow goes on with (nil when attaching failed or ctx ended)
// and the exit, when it reached one.
func (manager *terminalManager) replay(ctx context.Context, entry *terminalEntry, info keeper.Info) (TerminalAttachment, *keeper.Exit, bool) {
	attachment, err := manager.backend.Attach(ctx, info.ID, info.Start)
	if err != nil {
		// follow attaches again, from the entry's cursor.
		log.Printf("terminals: could not attach to id=%s to restore it: %v", info.ID, err)
		return nil, nil, false
	}
	stop := context.AfterFunc(ctx, func() { attachment.Close() })
	for {
		entry.mu.Lock()
		caughtUp := entry.cursor >= info.Cursor
		entry.mu.Unlock()
		if info.Running && caughtUp {
			break
		}
		event, err := attachment.Next()
		if err != nil {
			stop()
			attachment.Close()
			return nil, nil, false
		}
		switch event.Kind {
		case keeper.EventData:
			entry.receive(manager, event.Offset, event.Data, true)
		case keeper.EventSkipped:
			entry.skip(event.SkippedTo)
		case keeper.EventExited:
			stop()
			return attachment, event.Exit, true
		}
	}
	if !stop() {
		// ctx ended as the replay caught up: the attachment is closed.
		return nil, nil, false
	}
	return attachment, nil, false
}

// endFinished records the end of a terminal that finished while no host
// followed it: as its exit says, when it exited.
func (entry *terminalEntry) endFinished(exit *keeper.Exit) {
	status, reason, code := keeperExitEnd(exit)
	var at time.Time
	if exit != nil {
		at = exit.At
	}
	entry.mu.Lock()
	ended := entry.endLocked(status, reason, nil, code)
	if ended && !at.IsZero() {
		entry.info.Ended.At = at.UTC().Format(archiveTimeLayout)
		entry.endedAt = at
	}
	entry.mu.Unlock()
	if ended {
		entry.logEnded()
		entry.finishLogAt(at)
	}
}

// followAgain follows a running terminal whose follower stopped (the keeper
// could not be used); follow attaches from the entry's cursor.
func (manager *terminalManager) followAgain(entry *terminalEntry) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.closed {
		return
	}
	entry.mu.Lock()
	again := entry.info.Status == "running" && !entry.following
	if again {
		entry.following = true
		entry.done = make(chan struct{})
		entry.attachment = nil
	}
	entry.mu.Unlock()
	if !again {
		return
	}
	manager.readers.Add(1)
	go func() {
		defer manager.readers.Done()
		entry.follow(manager)
	}()
}

// retryUnusable runs restore every retryEvery while the keeper is unusable,
// until it can be used again (or none runs) or the host closes. setUnusable
// starts it.
func (manager *terminalManager) retryUnusable() {
	for {
		if !manager.pause(manager.retryEvery) {
			return
		}
		manager.restore(context.Background())
		manager.mu.Lock()
		if !manager.unusable || manager.closed {
			manager.retrying = false
			manager.mu.Unlock()
			return
		}
		manager.mu.Unlock()
	}
}

// runningTerminalLogs is the archive's running logs, or none.
func (h *Host) runningTerminalLogs(ctx context.Context) []runningTerminalLog {
	if h.archive == nil {
		return nil
	}
	logs, err := h.archive.runningTerminalLogs(ctx)
	if err != nil {
		log.Printf("terminals: could not read the running terminal logs: %v", err)
	}
	return logs
}

// endLegacyPTYs ends, best effort and in the background, the OpenCode PTYs
// an older host ran as terminals, whose logs (read before restore settled
// them as hostStopped) were still running. It may go on after the host
// serves: each request is bounded by legacyPTYWait, and Host.Close stops
// the rest and waits for it, as it does for the followers.
func (h *Host) endLegacyPTYs(logs []runningTerminalLog) {
	ender, ok := h.agent.(legacyPTYEnder)
	if !ok {
		return
	}
	var legacy []runningTerminalLog
	for _, running := range logs {
		if strings.HasPrefix(running.terminalID, "pty_") {
			legacy = append(legacy, running)
		}
	}
	manager := h.terminals
	manager.mu.Lock()
	if len(legacy) == 0 || manager.closed {
		manager.mu.Unlock()
		return
	}
	manager.readers.Add(1)
	manager.mu.Unlock()
	go func() {
		defer manager.readers.Done()
		for _, running := range legacy {
			if manager.isClosed() {
				return
			}
			project, err := h.project(running.projectID)
			if err != nil {
				continue
			}
			ctx, cancel := manager.requestContext(legacyPTYWait)
			err = ender.endLegacyPTY(ctx, project, running.terminalID)
			cancel()
			if err != nil && !errors.Is(err, ErrNotFound) && !manager.isClosed() {
				log.Printf("terminals: could not end the older host's terminal id=%s: %v", running.terminalID, err)
			}
		}
	}()
}

// reconcileTerminalLogs ends the running logs of terminals not in held
// (Archive.ReconcileTerminalLogs).
func (h *Host) reconcileTerminalLogs(held map[string]bool) {
	if h.archive == nil {
		return
	}
	ended, err := h.archive.ReconcileTerminalLogs(held, unheldTerminalEnd)
	if err != nil {
		if !errors.Is(err, ErrArchiveClosed) {
			log.Printf("terminals: could not record how terminals ended while the host was away: %v", err)
		}
		return
	}
	if ended > 0 {
		log.Printf("terminals: recorded the end of %d terminals that ended while the host was away", ended)
	}
}

// unheldTerminalEnd is how a terminal whose log was left running ended when
// no keeper holds it: an older host's OpenCode terminal ("pty_") with that
// host, any other with its keeper.
func unheldTerminalEnd(terminalID string) string {
	if strings.HasPrefix(terminalID, "pty_") {
		return terminalEndHostStopped
	}
	return terminalEndKeeperStopped
}
