package host

import (
	"errors"
	"fmt"
	"time"
)

// Terminal capture hooks used by createTerminal and follow.

// terminalNoWorkspaceArchiveID is the archive's project ID for a terminal
// outside any workspace. No workspace has it, so no workspace's search lists
// such a log; the log also keeps the terminal's folder, so it moves to the
// workspace that folder becomes (Host.terminalsJoinWorkspace).
const terminalNoWorkspaceArchiveID = "_none"

// openTerminalLog starts recording a new terminal's output. Capture is best
// effort: a terminal never fails because its log could not be opened.
func (h *Host) openTerminalLog(entry *terminalEntry, program string, started time.Time) *TerminalLog {
	if h.archive == nil {
		return nil
	}
	entry.mu.Lock()
	projectID, folder := entry.project.ID, ""
	if projectID == "" {
		projectID, folder = terminalNoWorkspaceArchiveID, entry.info.Directory
	}
	entry.mu.Unlock()
	log, err := h.archive.OpenTerminalLog(TerminalLogInfo{
		TerminalID:     entry.info.ID,
		ProjectID:      projectID,
		Folder:         folder,
		OwnerDeviceID:  entry.owner,
		Title:          entry.info.Title,
		Program:        program,
		StartedAt:      started,
		ConversationID: entry.info.ConversationID,
	})
	if err != nil {
		if !errors.Is(err, ErrArchiveClosed) {
			h.archive.recordFailure(fmt.Errorf("open terminal log: %w", err))
		}
		return nil
	}
	return log
}

// resumeTerminalLog goes on with a restored terminal's log (terminal_restore.go),
// so it keeps one log across host restarts. exists says the archive has that
// log, so the terminal must not get another: nil with exists is a log that
// already recorded the terminal's end (its transcript is complete, so nothing
// is recorded as failed) or one that could not be reopened.
func (h *Host) resumeTerminalLog(terminalID, logID string) (log *TerminalLog, exists bool) {
	if h.archive == nil || logID == "" {
		return nil, false
	}
	log, err := h.archive.ResumeTerminalLog(logID)
	switch {
	case err == nil:
		return log, true
	case errors.Is(err, errTerminalLogEnded), errors.Is(err, ErrArchiveClosed):
		return nil, true
	}
	h.archive.recordFailure(fmt.Errorf("resume terminal log of %s: %w", terminalID, err))
	return nil, !errors.Is(err, ErrNotFound)
}

// finishLog records how the terminal ended once its output reader stops.
func (entry *terminalEntry) finishLog() {
	entry.finishLogAt(time.Time{})
}

// finishLogAt is finishLog with when the terminal ended; zero means now.
func (entry *terminalEntry) finishLogAt(at time.Time) {
	if entry.log == nil {
		return
	}
	entry.mu.Lock()
	status, reason, endedBy := entry.info.Status, "", entry.endedBy
	var exitCode *int
	if entry.info.ExitCode != nil {
		code := *entry.info.ExitCode
		exitCode = &code
	}
	if entry.info.Ended != nil {
		reason = entry.info.Ended.Reason
	}
	entry.mu.Unlock()
	entry.log.closeEndedAt(status, exitCode, reason, endedBy, at)
}
