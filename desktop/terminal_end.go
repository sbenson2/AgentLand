package host

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"regexp"
	"strconv"
	"strings"
	"time"

	"agentland/host/keeper"
)

// How terminals end. The keeper (terminal_backend.go) holds every terminal,
// so a terminal ends only when its program exits, a host action ends it, or
// the keeper itself stops; the host records why (TerminalEnd), for devices
// and the archive. A host that stops or loses its attachment detaches and
// never ends a terminal.

// terminalEnding is how a host action is about to end a terminal.
type terminalEnding struct {
	reason string
	device *Device
}

// status is the status the ending leaves: a release disconnects the terminal
// (its program goes on in Terminal.app), and every other action ends it.
func (ending *terminalEnding) status() string {
	if ending.reason == terminalEndKeptInTerminal {
		return "disconnected"
	}
	return "exited"
}

func (entry *terminalEntry) now() time.Time {
	if entry.clock != nil {
		return entry.clock()
	}
	return time.Now()
}

// endLocked records how the terminal ended, once: a terminal that is no
// longer running keeps its first end. entry.mu is held.
func (entry *terminalEntry) endLocked(status, reason string, device *Device, exitCode *int) bool {
	if entry.info.Status != "running" {
		return false
	}
	entry.info.Status = status
	end := &TerminalEnd{Reason: reason, At: entry.now().UTC().Format(archiveTimeLayout), Program: entry.program, ConversationID: entry.info.ConversationID}
	if exitCode != nil {
		code := *exitCode
		end.ExitCode = &code
		entry.info.ExitCode = &code
	}
	if device != nil {
		end.Device = device.Name
		entry.endedBy = device.ID
	}
	entry.info.Ended = end
	entry.endedAt = entry.now()
	entry.notifyLocked()
	return true
}

// beginEnding marks the end a host action is about to cause; cancelEnding
// takes it back when the keeper did not end the terminal.
func (entry *terminalEntry) beginEnding(reason string, device *Device) {
	entry.mu.Lock()
	if entry.info.Status == "running" {
		entry.ending = &terminalEnding{reason: reason, device: device}
	}
	entry.mu.Unlock()
}

func (entry *terminalEntry) cancelEnding() {
	entry.mu.Lock()
	entry.ending = nil
	entry.mu.Unlock()
}

// finishEnding records the end beginEnding announced, unless the program's
// exit already did. It is true when it recorded the end of a terminal whose
// follower no longer runs, so its log's end is the caller's to record.
func (entry *terminalEntry) finishEnding(reason string, device *Device) bool {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	ending := terminalEnding{reason: reason, device: device}
	return entry.endLocked(ending.status(), reason, device, nil) && !entry.following
}

// running is whether the terminal has not ended.
func (entry *terminalEntry) running() bool {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return entry.info.Status == "running"
}

// endAndForget ends a terminal for a host action (reason, by device, when a
// device asked), then forgets it in the keeper and drops it. entry.writeMu is
// held. A terminal the keeper could not end, or forget, stays listed, and the
// error is returned. Each request to the keeper is bounded by ctx and by
// terminalRequestWait.
func (manager *terminalManager) endAndForget(ctx context.Context, entry *terminalEntry, reason string, device *Device) error {
	if err := manager.endEntry(ctx, entry, reason, device); err != nil {
		return err
	}
	return manager.forgetEntry(ctx, entry, manager.now())
}

// endEntry ends a running terminal for a host action and leaves it listed as
// ended; entry.writeMu is held. A terminal that is no longer running is left
// as it is. The request to the keeper is bounded by ctx and terminalRequestWait.
func (manager *terminalManager) endEntry(ctx context.Context, entry *terminalEntry, reason string, device *Device) error {
	if !entry.running() {
		return nil
	}
	entry.beginEnding(reason, device)
	ctx, cancel := context.WithTimeout(ctx, terminalRequestWait)
	_, err := manager.backend.End(ctx, entry.info.ID)
	cancel()
	if err != nil && !keeper.IsNotFound(err) {
		entry.cancelEnding()
		return err
	}
	if entry.finishEnding(reason, device) {
		// No follower records it (the keeper could not be used for it).
		entry.logEnded()
		entry.finishLog()
		manager.clearRoutedLater(entry)
	}
	return nil
}

// releaseEntry gives a running routed agent back to its Terminal.app window
// instead of ending it, and leaves it listed as ended (keptInTerminal) until
// its follower clears it; entry.writeMu is held. The program keeps running
// there; the keeper only drops its copy. The request to the keeper is bounded
// by ctx and terminalRequestWait.
func (manager *terminalManager) releaseEntry(ctx context.Context, entry *terminalEntry) error {
	if !entry.running() {
		return nil
	}
	entry.beginEnding(terminalEndKeptInTerminal, nil)
	ctx, cancel := context.WithTimeout(ctx, terminalRequestWait)
	err := manager.backend.Release(ctx, entry.info.ID)
	cancel()
	if err != nil && !keeper.IsNotFound(err) {
		entry.cancelEnding()
		return err
	}
	if entry.finishEnding(terminalEndKeptInTerminal, nil) {
		entry.logEnded()
		entry.finishLog()
		manager.clearRoutedLater(entry)
	}
	return nil
}

// clearRouted clears a routed agent that ended (clearEntry), within
// terminalClearWait: follow calls it once the log records the end, and
// restore for one that finished while no host followed it. A failure is
// logged and the entry stays, for the daily clear.
func (manager *terminalManager) clearRouted(entry *terminalEntry) {
	ctx, cancel := manager.requestContext(terminalClearWait)
	defer cancel()
	_ = manager.clearEntry(ctx, entry, manager.now())
}

// clearRoutedLater clears, in the background, a routed agent whose end its
// caller recorded because no follower runs for it (the keeper could not be
// used for it): no follower will. The caller may hold entry.writeMu, which
// clearEntry takes. Host.Close waits for it as for the followers.
func (manager *terminalManager) clearRoutedLater(entry *terminalEntry) {
	if !entry.routed() {
		return
	}
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		return
	}
	manager.readers.Add(1)
	manager.mu.Unlock()
	go func() {
		defer manager.readers.Done()
		manager.clearRouted(entry)
	}()
}

// forgetEntry has the keeper forget a terminal that is no longer running and
// drops it from the host, remembering how it ended (clearedEnd) as of now in
// the same step: every paired device may be reading it (terminal_shared.go),
// and one that no longer finds it learns its end at once, before the archive
// records it. entry.writeMu is held. The entry stays when the keeper could not
// forget it.
func (manager *terminalManager) forgetEntry(ctx context.Context, entry *terminalEntry, now time.Time) error {
	if err := manager.forgetInKeeper(ctx, entry.info.ID); err != nil {
		return err
	}
	manager.mu.Lock()
	manager.rememberLocked(entry, now)
	manager.dropLocked(entry)
	manager.mu.Unlock()
	return nil
}

// forgetInKeeper has the keeper forget a terminal, within ctx and
// terminalRequestWait. A keeper that does not hold it, or does not run, has
// nothing to forget.
func (manager *terminalManager) forgetInKeeper(ctx context.Context, id string) error {
	forgetContext, cancel := context.WithTimeout(ctx, terminalRequestWait)
	err := manager.backend.Forget(forgetContext, id)
	cancel()
	if err != nil && !keeper.IsNotFound(err) && !errors.Is(err, errNoKeeper) {
		return err
	}
	return nil
}

// dropLocked drops the entry from the host, unless another entry took its
// ID; manager.mu is held.
func (manager *terminalManager) dropLocked(entry *terminalEntry) {
	if id := entry.info.ID; manager.entries[id] == entry {
		delete(manager.entries, id)
	}
}

// attachmentLost is follow's answer to an output stream that ended before
// its program did. A keeper that answers is attached to again from the
// entry's cursor, never ended: tries is follow's count of re-attaches since
// an attachment last delivered an event, and after terminalReattachTries,
// terminalReattachPause apart, the keeper counts as unusable. When none
// runs, every terminal ended with it (keeperStopped); a keeper this build
// cannot use keeps its terminals running. True when a new attachment is in
// place.
func (manager *terminalManager) attachmentLost(entry *terminalEntry, tries *int) bool {
	if manager.isClosed() || !entry.running() {
		return false
	}
	ctx, cancel := manager.requestContext(terminalAttachWait)
	status := manager.backend.Status(ctx)
	cancel()
	if manager.isClosed() {
		return false
	}
	switch status {
	case KeeperNone:
		manager.keeperStopped()
		return false
	case KeeperUnusable:
		manager.setUnusable()
		return false
	}
	id := entry.info.ID
	for *tries < terminalReattachTries {
		if *tries > 0 && !manager.pause(terminalReattachPause) {
			return false
		}
		*tries++
		if !entry.running() {
			return false
		}
		entry.mu.Lock()
		cursor := entry.cursor
		entry.mu.Unlock()
		ctx, cancel := manager.requestContext(terminalAttachWait)
		attachment, err := manager.backend.Attach(ctx, id, cursor)
		cancel()
		if err == nil {
			return manager.install(entry, attachment)
		}
		if keeper.IsNotFound(err) {
			// The keeper that held it stopped and another started since.
			entry.mu.Lock()
			if entry.ending != nil {
				entry.endLocked(entry.ending.status(), entry.ending.reason, entry.ending.device, nil)
			} else {
				entry.endLocked("disconnected", terminalEndKeeperStopped, nil, nil)
			}
			entry.mu.Unlock()
			return false
		}
		if manager.isClosed() {
			return false
		}
		if errors.Is(err, errNoKeeper) {
			// Status looked alive, but no keeper answers: it just went.
			ctx, cancel := manager.requestContext(terminalAttachWait)
			status := manager.backend.Status(ctx)
			cancel()
			if manager.isClosed() {
				return false
			}
			if status == KeeperNone {
				manager.keeperStopped()
			} else {
				manager.setUnusable()
			}
			return false
		}
	}
	log.Printf("terminals: could not attach to id=%s workspace=%s again", id, entry.projectID())
	manager.setUnusable()
	return false
}

// install makes attachment the entry's stream, unless the host closed
// meanwhile.
func (manager *terminalManager) install(entry *terminalEntry, attachment TerminalAttachment) bool {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.closed {
		attachment.Close()
		return false
	}
	entry.mu.Lock()
	entry.attachment = attachment
	entry.mu.Unlock()
	return true
}

// keeperStopped ends every running terminal: no keeper runs, so their
// programs ended with it. Closing their attachments lets each follower
// record its log's end; a terminal whose follower already stopped (the
// keeper could not be used for it) has its log's end recorded here.
func (manager *terminalManager) keeperStopped() {
	manager.keeperWentAway()
	manager.mu.Lock()
	entries := make([]*terminalEntry, 0, len(manager.entries))
	for _, entry := range manager.entries {
		entries = append(entries, entry)
	}
	manager.mu.Unlock()
	for _, entry := range entries {
		manager.endKeeperStopped(entry)
	}
}

// endKeeperStopped ends a terminal whose keeper is gone (keeperStopped).
func (manager *terminalManager) endKeeperStopped(entry *terminalEntry) {
	entry.mu.Lock()
	unfollowed := entry.endLocked("disconnected", terminalEndKeeperStopped, nil, nil) && !entry.following
	attachment := entry.attachment
	entry.mu.Unlock()
	if unfollowed {
		entry.logEnded()
		entry.finishLog()
		manager.clearRoutedLater(entry)
	}
	if attachment != nil {
		attachment.Close()
	}
}

// setUnusable marks the keeper as one this build cannot use: its terminals
// stay running, routes that need it answer terminals_unavailable, and the
// retry loop (terminal_restore.go) looks for a usable keeper again.
func (manager *terminalManager) setUnusable() {
	manager.mu.Lock()
	if !manager.unusable {
		log.Printf("terminals: the terminal service cannot be used; its terminals stay running")
	}
	manager.unusable = true
	retry := !manager.retrying && !manager.closed && manager.restore != nil
	if retry {
		manager.retrying = true
	}
	manager.mu.Unlock()
	if retry {
		go manager.retryUnusable()
	}
}

// setUsable is restore's: the keeper can be used again (or none runs).
func (manager *terminalManager) setUsable() {
	manager.mu.Lock()
	if manager.unusable {
		log.Printf("terminals: the terminal service can be used again")
	}
	manager.unusable = false
	manager.mu.Unlock()
}

func (manager *terminalManager) isUnusable() bool {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	return manager.unusable
}

func (manager *terminalManager) isClosed() bool {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	return manager.closed
}

// requestContext bounds a request to the keeper by limit and by Host.Close.
func (manager *terminalManager) requestContext(limit time.Duration) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	go func() {
		select {
		case <-manager.closing:
		case <-ctx.Done():
		}
		cancel()
	}()
	return ctx, cancel
}

// pause waits d; false when the host closes first.
func (manager *terminalManager) pause(d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-manager.closing:
		return false
	}
}

// logCreated and logEnded write one line per terminal lifecycle event,
// never its contents or any credential.
func logTerminalCreated(info TerminalInfo, project Project, program string, device Device) {
	conversation := ""
	if info.ConversationID != "" {
		conversation = " conversation=" + info.ConversationID
	}
	log.Printf("terminals: created id=%s workspace=%s program=%s device=%s (%s)%s", info.ID, project.ID, program, device.ID, strconv.Quote(device.Name), conversation)
}

func (entry *terminalEntry) logEnded() {
	entry.mu.Lock()
	id, project, status, end, endedBy := entry.info.ID, entry.project.ID, entry.info.Status, entry.info.Ended, entry.endedBy
	entry.mu.Unlock()
	reason, exit := "unknown", "unknown"
	if end != nil {
		reason = end.Reason
		if end.ExitCode != nil {
			exit = strconv.Itoa(*end.ExitCode)
		}
	}
	by := ""
	if endedBy != "" {
		by = " device=" + endedBy
	}
	log.Printf("terminals: ended id=%s workspace=%s program=%s status=%s reason=%s exit=%s%s", id, project, entry.program, status, reason, exit, by)
}

// Claude Code conversations (createTerminal's resume).

// terminalConversation is the Claude Code conversation a terminal starts:
// a new one with the host's ID (--session-id), the one named (--resume <id>),
// or the one the person picks in Claude Code's own picker (--resume alone).
type terminalConversation struct {
	ID     string
	Resume bool
	Pick   bool
}

// terminalResumePick opens Claude Code's conversation picker in the new
// terminal, for an ended terminal whose conversation the host never named.
const terminalResumePick = "pick"

var conversationIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// terminalResumeConversation reads createTerminal's resume field: empty for
// a new conversation, a UUID (any case) or "pick".
func terminalResumeConversation(resume string) (terminalConversation, bool) {
	resume = strings.TrimSpace(resume)
	switch {
	case resume == "":
		return terminalConversation{ID: newClaudeUUID()}, true
	case resume == terminalResumePick:
		return terminalConversation{Pick: true}, true
	}
	id := strings.ToLower(resume)
	if !conversationIDPattern.MatchString(id) {
		return terminalConversation{}, false
	}
	return terminalConversation{ID: id, Resume: true}, true
}

// claudeConversationArgs are the arguments a conversation adds to claude.
func claudeConversationArgs(conversation terminalConversation) []string {
	switch {
	case conversation.Pick:
		// Claude Code's --resume without a value opens its session picker.
		return []string{"--resume"}
	case conversation.Resume:
		return []string{"--resume", conversation.ID}
	case conversation.ID != "":
		return []string{"--session-id", conversation.ID}
	}
	return nil
}

// endedTerminal is how the archive says a terminal ended, for any paired
// device (terminal_shared.go) asking in its workspace, or naming none
// (Project{}), about a terminal the host no longer has: it ended and was
// forgotten, or the host started again since. The device that ended it is
// named.
func (h *Host) endedTerminal(ctx context.Context, project Project, terminalID string) *TerminalEnd {
	if h.archive == nil || terminalID == "" {
		return nil
	}
	record, err := h.archive.TerminalEnding(ctx, terminalID, project.ID)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) && !errors.Is(err, ErrArchiveClosed) {
			log.Printf("terminals: could not read how terminal %s ended: %v", terminalID, err)
		}
		return nil
	}
	if record.endedBy != "" {
		if devices, err := h.store.ListDevices(); err == nil {
			for _, device := range devices {
				if device.ID == record.endedBy {
					record.end.Device = device.Name
				}
			}
		}
	}
	return &record.end
}
