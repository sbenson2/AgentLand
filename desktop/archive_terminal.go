package host

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	// terminalLogBuffer is how much output Append holds before writing it
	// without waiting for the maintenance loop.
	terminalLogBuffer = 256 << 10
	// terminalLogRangeLimit bounds one read of a log.
	terminalLogRangeLimit = 1 << 20
)

var errArchiveRange = errors.New("the offset is past the end of the terminal log")

// TerminalLogInfo describes the terminal whose output a log records.
type TerminalLogInfo struct {
	TerminalID, ProjectID, OwnerDeviceID string
	Title, Program                       string
	StartedAt                            time.Time
	// ConversationID is a Claude Code terminal's conversation (v7).
	ConversationID string
	// Folder is where a terminal outside any workspace runs (v8).
	Folder string
}

// TerminalLog records one terminal's raw output in
// terminals/YYYY/MM/<id>.log. Append buffers in memory; the host's
// maintenance loop writes the buffer every second, and Append writes it
// sooner once 256 KiB are waiting. Terminal input never passes through here.
// While capture is paused, or after a write error, output is counted as gap
// bytes instead of being written. A nil *TerminalLog ignores every call.
//
// Its changes name the workspace its row names as each write applies
// (recordTerminalLogChange), never one the log kept: a terminal outside any
// workspace may join one meanwhile (MoveToProject).
type TerminalLog struct {
	archive *Archive
	id      string

	mu       sync.Mutex
	file     *os.File
	pending  []byte
	bytes    int64
	gap      int64
	status   string
	exitCode *int
	// How it ended (v7, terminal_end.go).
	endReason string
	endedBy   string
	ended     time.Time
	dirty     bool
	closed    bool
	failed    bool
	title     string
}

type terminalLogRow struct {
	id, status         string
	bytes, gap         int64
	ended              time.Time
	exitCode           *int
	endReason, endedBy string
}

// OpenTerminalLog creates the log file and its row. It waits for the row to
// be committed so later updates always find it.
func (a *Archive) OpenTerminalLog(info TerminalLogInfo) (*TerminalLog, error) {
	if err := archiveCheckID("project id", info.ProjectID); err != nil {
		return nil, err
	}
	for _, field := range []struct{ name, value string }{{"terminal id", info.TerminalID}, {"owner device id", info.OwnerDeviceID}, {"conversation id", info.ConversationID}} {
		if field.value != "" {
			if err := archiveCheckID(field.name, field.value); err != nil {
				return nil, err
			}
		}
	}
	started := info.StartedAt
	if started.IsZero() {
		started = a.now()
	}
	started = archiveTime(started)
	id := "tl_" + archiveRandomID(16)
	year, month := started.Format("2006"), started.Format("01")
	directory, err := a.ensureTree("terminals", year, month)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(directory, id+".log")
	file, err := createArchiveFile(path, os.O_WRONLY|os.O_APPEND)
	if err != nil {
		return nil, err
	}
	relative := "terminals/" + year + "/" + month + "/" + id + ".log"
	err = a.do(func(t *archiveTx) error {
		if _, err := t.exec(`INSERT INTO terminal_logs (id, terminal_id, project_id, owner_device_id, title, program, started_at, status, file, conversation_id, folder)
			VALUES (?, ?, ?, ?, ?, ?, ?, 'running', ?, ?, ?)`,
			id, info.TerminalID, info.ProjectID, info.OwnerDeviceID, archiveLabel(info.Title, archiveTitleLimit),
			archiveLabel(info.Program, archiveLabelLimit), started.UnixMilli(), relative, info.ConversationID, strings.ToValidUTF8(info.Folder, "�")); err != nil {
			return err
		}
		return t.recordChange("terminalLog", id, "", info.ProjectID, "upsert")
	})
	if err != nil {
		file.Close()
		os.Remove(path)
		return nil, err
	}
	log := &TerminalLog{archive: a, id: id, file: file, status: "running", title: info.Title}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		// The row stays "running"; the next host resumes or settles it.
		file.Close()
		return nil, ErrArchiveClosed
	}
	a.logs[id] = log
	return log, nil
}

// ID is the log's archive identifier.
func (l *TerminalLog) ID() string {
	if l == nil {
		return ""
	}
	return l.id
}

// Append records output bytes. It never blocks on the database.
func (l *TerminalLog) Append(data []byte) {
	if l == nil || len(data) == 0 {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	l.appendLocked(data)
}

// Position is how far into the terminal's output the log reaches: the bytes
// it holds (written or buffered) plus the bytes it counted as a gap.
func (l *TerminalLog) Position() uint64 {
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.positionLocked()
}

func (l *TerminalLog) positionLocked() uint64 {
	return uint64(l.bytes + int64(len(l.pending)) + l.gap)
}

// AppendAt records output that starts at offset in the terminal's output (the
// keeper's cursor). Only the part past Position is recorded; output the log
// never saw, between Position and offset, is counted as a gap first. It never
// blocks on the database.
func (l *TerminalLog) AppendAt(offset uint64, data []byte) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	position := l.positionLocked()
	if offset > position {
		l.gap += int64(offset - position)
		l.dirty = true
		position = offset
	}
	if offset+uint64(len(data)) <= position {
		return
	}
	l.appendLocked(data[position-offset:])
}

func (l *TerminalLog) appendLocked(data []byte) {
	if l.failed || l.archive.paused.Load() {
		l.gap += int64(len(data))
		l.dirty = true
		return
	}
	l.pending = append(l.pending, data...)
	if len(l.pending) >= terminalLogBuffer {
		l.writeLocked()
	}
}

// Rename updates history and its change feed independently of output flushes.
// It also accepts a final description after EOF; the output file stays closed.
// It waits for room in the archive's queue without l.mu, so Append (the
// terminal's output) never waits for it. Callers rename a log one at a time.
func (l *TerminalLog) Rename(title string) {
	if l == nil || title == "" {
		return
	}
	title = archiveLabel(title, archiveTitleLimit)
	l.mu.Lock()
	unchanged := title == l.title
	l.mu.Unlock()
	if unchanged {
		return
	}
	err := l.archive.submit(&archiveOp{key: "terminalTitle\x00" + l.id, apply: func(t *archiveTx) error {
		if _, err := t.exec(`UPDATE terminal_logs SET title = ? WHERE id = ?`, title, l.id); err != nil {
			return err
		}
		return t.recordTerminalLogChange(l.id)
	}})
	if err == nil {
		l.mu.Lock()
		l.title = title
		l.mu.Unlock()
	} else if !errors.Is(err, ErrArchiveClosed) {
		l.archive.recordFailure(err)
	}
}

// MoveToProject files the log under another workspace (Archive.MoveTerminalLog),
// as a terminal outside any joins one; its later changes name it, whenever
// they were queued. A log someone deleted has nothing to move.
func (l *TerminalLog) MoveToProject(projectID string) {
	if l == nil {
		return
	}
	if err := l.archive.MoveTerminalLog(l.id, projectID); err != nil && !errors.Is(err, ErrArchiveClosed) && !errors.Is(err, ErrNotFound) {
		l.archive.recordFailure(fmt.Errorf("move terminal log %s: %w", l.id, err))
	}
}

// recordTerminalLogChange records an upsert of a terminal log in the change
// feed, under the workspace its row names as this write applies: a write
// queued before a move (MoveTerminalLog) and applied after it names the new
// workspace, so no change after the move's names the old one. A deleted log
// records nothing, so its tombstone stays.
func (t *archiveTx) recordTerminalLogChange(id string) error {
	var project string
	err := t.queryRow(`SELECT project_id FROM terminal_logs WHERE id = ?`, id).Scan(&project)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	return t.recordChange("terminalLog", id, "", project, "upsert")
}

// MoveTerminalLog files a log under another workspace: its row's project_id,
// and an upsert in the change feed, so the vault and devices' feeds follow.
func (a *Archive) MoveTerminalLog(id, projectID string) error {
	if err := archiveCheckID("project id", projectID); err != nil {
		return err
	}
	return a.do(func(t *archiveTx) error {
		result, err := t.exec(`UPDATE terminal_logs SET project_id = ? WHERE id = ?`, projectID, id)
		if err != nil {
			return err
		}
		if changed, err := result.RowsAffected(); err != nil || changed == 0 {
			if err == nil {
				err = ErrNotFound
			}
			return err
		}
		return t.recordChange("terminalLog", id, "", projectID, "upsert")
	})
}

// MoveProjectlessTerminalLogs files under projectID the logs of terminals
// outside any workspace whose folder joins it, as the workspace is added:
// ended ones, and running rows whose terminal is no longer listed (a device
// closed it before its follower recorded the end). A listed terminal's log
// moved with it already (TerminalLog.MoveToProject). Changes name the row's
// workspace as they apply (recordTerminalLogChange), so a row moved while
// its terminal's end is still queued records that end under projectID. It
// returns how many moved.
func (a *Archive) MoveProjectlessTerminalLogs(projectID string, joins func(folder string) bool) (int, error) {
	if err := archiveCheckID("project id", projectID); err != nil {
		return 0, err
	}
	moved := 0
	err := a.do(func(t *archiveTx) error {
		moved = 0
		rows, err := t.tx.Query(`SELECT id, folder FROM terminal_logs WHERE project_id = ? AND folder != ''`, terminalNoWorkspaceArchiveID)
		if err != nil {
			return err
		}
		var ids []string
		for rows.Next() {
			var id, folder string
			if err := rows.Scan(&id, &folder); err != nil {
				rows.Close()
				return err
			}
			if joins(folder) {
				ids = append(ids, id)
			}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, id := range ids {
			if _, err := t.exec(`UPDATE terminal_logs SET project_id = ? WHERE id = ?`, projectID, id); err != nil {
				return err
			}
			if err := t.recordChange("terminalLog", id, "", projectID, "upsert"); err != nil {
				return err
			}
		}
		moved = len(ids)
		return nil
	})
	return moved, err
}

func (l *TerminalLog) writeLocked() {
	if len(l.pending) == 0 {
		return
	}
	written, err := l.file.Write(l.pending)
	l.bytes += int64(written)
	if err != nil {
		// Stop writing this log; the rest of its output is counted as a gap.
		l.gap += int64(len(l.pending) - written)
		l.failed = true
		l.archive.recordFailure(fmt.Errorf("terminal log %s: %w", l.id, err))
	}
	l.pending = l.pending[:0]
	if cap(l.pending) > 2*terminalLogBuffer {
		l.pending = nil
	}
	l.dirty = true
}

func (l *TerminalLog) rowLocked() terminalLogRow {
	return terminalLogRow{id: l.id, status: l.status, bytes: l.bytes, gap: l.gap, ended: l.ended, exitCode: l.exitCode,
		endReason: l.endReason, endedBy: l.endedBy}
}

// flush writes buffered output and queues the new sizes. The row is queued
// after l.mu is released, so a CloseEnded may queue the final row first;
// submitTerminalLogRow keeps that final row (a running row never replaces or
// undoes it).
func (l *TerminalLog) flush() {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.writeLocked()
	dirty := l.dirty
	l.dirty = false
	row := l.rowLocked()
	l.mu.Unlock()
	if dirty {
		l.archive.submitTerminalLogRow(row, false)
	}
}

// Detach stops recording without ending the log, for a terminal that keeps
// running after the host stops: it writes what is buffered, syncs and closes
// the file, queues the sizes, leaves the row running for the next host
// (ResumeTerminalLog) and drops the log from the archive's open logs. Later
// calls, and every call after it, do nothing.
func (l *TerminalLog) Detach() {
	if l == nil {
		return
	}
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.writeLocked()
	_ = l.file.Sync()
	_ = l.file.Close()
	l.closed = true
	dirty := l.dirty
	l.dirty = false
	row := l.rowLocked()
	l.mu.Unlock()
	l.archive.mu.Lock()
	delete(l.archive.logs, l.id)
	l.archive.mu.Unlock()
	if dirty {
		l.archive.submitTerminalLogRow(row, false)
	}
}

// Close writes the remaining output, closes the file and records how the
// terminal ended: exited, disconnected or interrupted. Later calls do nothing.
func (l *TerminalLog) Close(status string, exitCode *int) {
	l.CloseEnded(status, exitCode, "", "")
}

// CloseEnded is Close with why the terminal ended and the device that ended
// it (terminal_end.go); either may be empty.
func (l *TerminalLog) CloseEnded(status string, exitCode *int, reason, endedBy string) {
	l.closeEndedAt(status, exitCode, reason, endedBy, time.Time{})
}

// closeEndedAt is CloseEnded with when the terminal ended; zero means now.
func (l *TerminalLog) closeEndedAt(status string, exitCode *int, reason, endedBy string, at time.Time) {
	if l == nil {
		return
	}
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.writeLocked()
	_ = l.file.Sync()
	_ = l.file.Close()
	l.closed = true
	switch status {
	case "exited", "disconnected", "interrupted":
		l.status = status
	default:
		l.status = "exited"
	}
	if exitCode != nil {
		code := *exitCode
		l.exitCode = &code
	}
	l.endReason = archiveLabel(reason, archiveLabelLimit)
	if endedBy != "" && archiveCheckID("device id", endedBy) == nil {
		l.endedBy = endedBy
	}
	l.ended = at
	if at.IsZero() {
		l.ended = l.archive.now()
	}
	row := l.rowLocked()
	l.mu.Unlock()
	l.archive.mu.Lock()
	delete(l.archive.logs, l.id)
	l.archive.mu.Unlock()
	l.archive.submitTerminalLogRow(row, true)
}

// submitTerminalLogRow queues the log's sizes and state. Only the final
// update enters the change feed, so a running terminal does not churn it.
// The final row wins: it is queued under its own key, so a running row queued
// after it never replaces it, and a running row only updates a row that is
// still running.
func (a *Archive) submitTerminalLogRow(row terminalLogRow, final bool) {
	var exitCode any
	if row.exitCode != nil {
		exitCode = *row.exitCode
	}
	key, query := "terminalLog\x00"+row.id, `UPDATE terminal_logs SET bytes = ?, gap_bytes = ?, status = ?, ended_at = ?, exit_code = ?, end_reason = ?, ended_by_device_id = ? WHERE id = ? AND status = 'running'`
	if final {
		key, query = "terminalLogEnd\x00"+row.id, `UPDATE terminal_logs SET bytes = ?, gap_bytes = ?, status = ?, ended_at = ?, exit_code = ?, end_reason = ?, ended_by_device_id = ? WHERE id = ?`
	}
	err := a.submit(&archiveOp{key: key, apply: func(t *archiveTx) error {
		if _, err := t.exec(query, row.bytes, row.gap, row.status, archiveMillis(row.ended), exitCode, row.endReason, row.endedBy, row.id); err != nil || !final {
			return err
		}
		return t.recordTerminalLogChange(row.id)
	}})
	if err != nil && !errors.Is(err, ErrArchiveClosed) {
		a.recordFailure(err)
	}
}

func (a *Archive) openLogs() []*TerminalLog {
	a.mu.Lock()
	defer a.mu.Unlock()
	logs := make([]*TerminalLog, 0, len(a.logs))
	for _, log := range a.logs {
		logs = append(logs, log)
	}
	return logs
}

func (a *Archive) openLog(id string) *TerminalLog {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.logs[id]
}

func (a *Archive) flushTerminalLogs() {
	for _, log := range a.openLogs() {
		log.flush()
	}
}

// errTerminalLogEnded answers ResumeTerminalLog for a log that already
// recorded its terminal's end.
var errTerminalLogEnded = errors.New("the terminal log has ended")

// ResumeTerminalLog reopens a running log for a terminal the keeper still
// holds, so its output goes on in the same row and file. The file is the
// truth: Position is the file's size plus the row's gap, so output a host that
// died never wrote is taken again from the keeper (AppendAt). A missing file
// is created again empty. A log that ended is not reopened
// (errTerminalLogEnded).
func (a *Archive) ResumeTerminalLog(id string) (*TerminalLog, error) {
	if err := archiveCheckID("terminal log id", id); err != nil {
		return nil, ErrNotFound
	}
	if a.openLog(id) != nil {
		return nil, errArchiveLogActive
	}
	var relative, status, title string
	var gap int64
	err := a.readDB.QueryRow(`SELECT file, status, gap_bytes, title FROM terminal_logs WHERE id = ?`, id).Scan(&relative, &status, &gap, &title)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if status != "running" {
		return nil, fmt.Errorf("terminal log %s is %s: %w", id, status, errTerminalLogEnded)
	}
	path, ok := a.terminalLogPath(relative)
	parts := strings.Split(relative, "/")
	if !ok || len(parts) != 4 {
		return nil, ErrNotFound
	}
	if _, err := a.ensureTree(parts[:3]...); err != nil {
		return nil, err
	}
	file, err := openTerminalLogFile(path)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	log := &TerminalLog{archive: a, id: id, file: file, status: "running", title: title, bytes: info.Size(), gap: gap, dirty: true}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		file.Close()
		return nil, ErrArchiveClosed
	}
	if a.logs[id] != nil {
		file.Close()
		return nil, errArchiveLogActive
	}
	a.logs[id] = log
	return log, nil
}

// openTerminalLogFile opens an existing log for appending, refusing anything
// but a regular file (no link), or creates it again when it is missing.
func openTerminalLogFile(path string) (*os.File, error) {
	before, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return createArchiveFile(path, os.O_WRONLY|os.O_APPEND)
	}
	if err != nil {
		return nil, err
	}
	if !before.Mode().IsRegular() {
		return nil, fmt.Errorf("terminal log %s is not a regular file", filepath.Base(path))
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return nil, err
	}
	if after, err := file.Stat(); err != nil || !os.SameFile(before, after) {
		file.Close()
		return nil, fmt.Errorf("terminal log %s changed while it was opened", filepath.Base(path))
	}
	return file, nil
}

// runningTerminalLog is a log the archive still records as running.
type runningTerminalLog struct {
	id, terminalID, projectID string
}

// runningTerminalLogs lists the logs still running, newest first.
func (a *Archive) runningTerminalLogs(ctx context.Context) ([]runningTerminalLog, error) {
	rows, err := a.readDB.QueryContext(ctx, `SELECT id, terminal_id, project_id FROM terminal_logs WHERE status = 'running' ORDER BY started_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var logs []runningTerminalLog
	for rows.Next() {
		var log runningTerminalLog
		if err := rows.Scan(&log.id, &log.terminalID, &log.projectID); err != nil {
			return nil, err
		}
		logs = append(logs, log)
	}
	return logs, rows.Err()
}

// ReconcileTerminalLogs ends the running logs of terminals no keeper holds:
// every running row whose terminal is not in held, and whose log this process
// does not have open, becomes interrupted with reasonFor(its terminal ID),
// the size of its file, and the file's last write as its end. It runs as one
// transaction that also records each change, and returns how many rows it
// ended.
func (a *Archive) ReconcileTerminalLogs(held map[string]bool, reasonFor func(terminalID string) string) (int, error) {
	ended := 0
	err := a.do(func(t *archiveTx) error {
		ended = 0
		type running struct{ id, terminal, project, file string }
		rows, err := t.tx.Query(`SELECT id, terminal_id, project_id, file FROM terminal_logs WHERE status = 'running'`)
		if err != nil {
			return err
		}
		var logs []running
		for rows.Next() {
			var log running
			if err := rows.Scan(&log.id, &log.terminal, &log.project, &log.file); err != nil {
				rows.Close()
				return err
			}
			logs = append(logs, log)
		}
		if err := rows.Close(); err != nil {
			return err
		}
		for _, log := range logs {
			if held[log.terminal] || a.openLog(log.id) != nil {
				continue
			}
			size, at := int64(0), t.now
			if path, ok := a.terminalLogPath(log.file); ok {
				if info, err := os.Lstat(path); err == nil && info.Mode().IsRegular() {
					size, at = info.Size(), info.ModTime().UnixMilli()
				}
			}
			reason := archiveLabel(reasonFor(log.terminal), archiveLabelLimit)
			if _, err := t.exec(`UPDATE terminal_logs SET status = 'interrupted', end_reason = ?, ended_at = ?, bytes = ? WHERE id = ?`, reason, at, size, log.id); err != nil {
				return err
			}
			if err := t.recordChange("terminalLog", log.id, "", log.project, "upsert"); err != nil {
				return err
			}
			ended++
		}
		return nil
	})
	return ended, err
}

// terminalLogPath resolves a stored relative name, which must stay under
// terminals/.
func (a *Archive) terminalLogPath(relative string) (string, bool) {
	local := filepath.FromSlash(relative)
	if !strings.HasPrefix(relative, "terminals/") || !filepath.IsLocal(local) {
		return "", false
	}
	return filepath.Join(a.directory, local), true
}

// ArchiveTerminalRange is one read of a terminal log. EOF is set once the
// terminal has ended and Next reached the end of the log.
type ArchiveTerminalRange struct {
	Data   []byte
	Offset int64
	Next   int64
	Size   int64
	EOF    bool
	Status string
}

// ReadTerminalLog reads up to length bytes at offset. Buffered output of a
// running terminal is written first, so the read is current.
func (a *Archive) ReadTerminalLog(log archiveTerminalLogJSON, offset int64, length int) (ArchiveTerminalRange, error) {
	result := ArchiveTerminalRange{Offset: offset, Next: offset, Status: log.Status}
	open := a.openLog(log.ID)
	if open != nil {
		open.flush()
		result.Status = "running"
	}
	path, ok := a.terminalLogPath(log.file)
	if !ok {
		return result, ErrNotFound
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return result, ErrNotFound
	}
	result.Size = info.Size()
	if offset > result.Size {
		return result, errArchiveRange
	}
	file, err := os.Open(path)
	if err != nil {
		return result, err
	}
	defer file.Close()
	result.Data = make([]byte, min(int64(length), result.Size-offset))
	read, err := file.ReadAt(result.Data, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return result, err
	}
	result.Data = result.Data[:read]
	result.Next = offset + int64(read)
	result.EOF = open == nil && result.Next >= result.Size
	return result, nil
}

// DeleteTerminalLog removes a finished log and its file and leaves a
// tombstone. A running terminal's log cannot be deleted.
func (a *Archive) DeleteTerminalLog(id string) error {
	if err := archiveCheckID("terminal log id", id); err != nil {
		return ErrNotFound
	}
	return a.do(func(t *archiveTx) error {
		if a.openLog(id) != nil {
			return errArchiveLogActive
		}
		var project, file string
		err := t.queryRow(`SELECT project_id, file FROM terminal_logs WHERE id = ?`, id).Scan(&project, &file)
		if errors.Is(err, sql.ErrNoRows) {
			var count int
			if err := t.queryRow(`SELECT count(*) FROM changes WHERE entity = 'terminalLog' AND chat_id = '' AND entity_id = ? AND op = 'delete'`, id).Scan(&count); err != nil {
				return err
			}
			if count > 0 {
				return nil
			}
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if _, err := t.exec(`DELETE FROM terminal_logs WHERE id = ?`, id); err != nil {
			return err
		}
		if path, ok := a.terminalLogPath(file); ok {
			t.after = append(t.after, func() { _ = os.Remove(path) })
		}
		return t.recordChange("terminalLog", id, "", project, "delete")
	})
}

// terminalText strips a range of terminal output for reading as text. At the
// end of a finished log everything is consumed; otherwise an escape sequence,
// CR or UTF-8 character cut off at the end is left for the next range, unless
// that would make no progress.
func terminalText(data []byte, atEnd bool) ([]byte, int) {
	text, consumed := stripTerminalText(data, atEnd)
	if consumed == 0 && len(data) > 0 {
		text, consumed = stripTerminalText(data, true)
	}
	return text, consumed
}

// stripTerminalText returns the printable text of raw terminal output. It
// drops escape sequences (CSI, OSC, DCS, SOS, PM, APC, charset designations
// and two-byte sequences), C0 controls other than tab and newline, DEL and
// C1 code points. CR LF becomes LF and a lone CR becomes LF. Invalid UTF-8
// becomes U+FFFD. consumed is the number of input bytes processed: unless
// final is set, it stops before a sequence that data cuts off.
func stripTerminalText(data []byte, final bool) (text []byte, consumed int) {
	out := make([]byte, 0, len(data))
	i := 0
	for i < len(data) {
		b := data[i]
		switch {
		case b == 0x1b:
			end, complete := terminalEscapeEnd(data, i)
			if !complete {
				if !final {
					return out, i
				}
				return out, len(data)
			}
			i = end
		case b == '\r':
			j := i
			for j < len(data) && data[j] == '\r' {
				j++
			}
			if j == len(data) && !final {
				return out, i
			}
			if j == len(data) || data[j] != '\n' {
				out = append(out, '\n')
			}
			i = j
		case b == '\n' || b == '\t':
			out = append(out, b)
			i++
		case b < 0x20 || b == 0x7f:
			i++
		case b < 0x80:
			out = append(out, b)
			i++
		default:
			if !utf8.FullRune(data[i:]) {
				if !final {
					return out, i
				}
				return append(out, "�"...), len(data)
			}
			r, size := utf8.DecodeRune(data[i:])
			switch {
			case r == utf8.RuneError && size == 1:
				out = append(out, "�"...)
			case r >= 0x80 && r <= 0x9f:
			default:
				out = append(out, data[i:i+size]...)
			}
			i += size
		}
	}
	return out, i
}

// terminalEscapeEnd returns the index after the escape sequence that starts
// at data[start] (ESC), or complete=false when data ends inside it. A
// malformed sequence ends before the byte that breaks it.
func terminalEscapeEnd(data []byte, start int) (end int, complete bool) {
	i := start + 1
	if i >= len(data) {
		return 0, false
	}
	switch b := data[i]; {
	case b == '[':
		for i++; i < len(data); i++ {
			switch c := data[i]; {
			case c >= 0x40 && c <= 0x7e:
				return i + 1, true
			case c >= 0x20 && c <= 0x3f:
			default:
				return i, true
			}
		}
		return 0, false
	case b == ']' || b == 'P' || b == 'X' || b == '^' || b == '_':
		for i++; i < len(data); i++ {
			switch data[i] {
			case 0x07:
				return i + 1, true
			case 0x1b:
				if i+1 >= len(data) {
					return 0, false
				}
				if data[i+1] == '\\' {
					return i + 2, true
				}
				return i, true
			}
		}
		return 0, false
	case b >= 0x20 && b <= 0x2f:
		for i++; i < len(data); i++ {
			switch c := data[i]; {
			case c >= 0x20 && c <= 0x2f:
			case c >= 0x30 && c <= 0x7e:
				return i + 1, true
			default:
				return i, true
			}
		}
		return 0, false
	case b >= 0x30 && b <= 0x7e:
		return i + 1, true
	default:
		return i, true
	}
}
