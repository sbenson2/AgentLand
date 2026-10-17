package host

import (
	"database/sql"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func fileExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func TestStripTerminalText(t *testing.T) {
	for _, check := range []struct {
		name, input, want string
		consumed          int // -1 means everything
	}{
		{"plain", "hello\tworld\n", "hello\tworld\n", -1},
		{"colors", "\x1b[1;31mred\x1b[0m text", "red text", -1},
		{"cursor and erase", "a\x1b[2K\x1b[10;20Hb\x1b[?25l", "ab", -1},
		{"title by BEL", "\x1b]0;window title\x07prompt$ ", "prompt$ ", -1},
		{"hyperlink by ST", "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\", "link", -1},
		{"DCS and APC", "\x1bPq#0;2;0;0;0\x1b\\x\x1b_app\x1b\\y", "xy", -1},
		{"charset and keypad", "\x1b(B\x1b)0\x1b=\x1b>\x1b7\x1b8ok", "ok", -1},
		{"line endings", "one\r\ntwo\rthree\r\r\nfour", "one\ntwo\nthree\nfour", -1},
		{"controls", "bell\x07 back\x08space\x00 del\x7f", "bell backspace del", -1},
		{"C1 code points", "a\u009b31mb\u0085c", "a31mbc", -1},
		{"UTF-8", "naïve café 日本", "naïve café 日本", -1},
		{"invalid UTF-8", "bad \xff byte", "bad � byte", -1},
		{"malformed CSI", "\x1b[12\nnext", "\nnext", -1},
		{"escape then control", "\x1b\nline", "\nline", -1},
		// Cut-off sequences wait for the next range.
		{"cut CSI", "text\x1b[3", "text", 4},
		{"cut OSC", "text\x1b]0;tit", "text", 4},
		{"cut ST", "text\x1b]0;title\x1b", "text", 4},
		{"lone ESC", "text\x1b", "text", 4},
		{"cut CR", "text\r", "text", 4},
		{"cut UTF-8", "caf\xc3", "caf", 3},
	} {
		text, consumed := stripTerminalText([]byte(check.input), false)
		want := check.consumed
		if want < 0 {
			want = len(check.input)
		}
		if string(text) != check.want || consumed != want {
			t.Errorf("%s: %q consumed %d, want %q consumed %d", check.name, text, consumed, check.want, want)
		}
	}
	// At the end of a finished log everything is consumed.
	if text, consumed := stripTerminalText([]byte("text\x1b[3"), true); string(text) != "text" || consumed != 7 {
		t.Errorf("final cut CSI: %q %d", text, consumed)
	}
	if text, consumed := stripTerminalText([]byte("text\r"), true); string(text) != "text\n" || consumed != 5 {
		t.Errorf("final CR: %q %d", text, consumed)
	}
	// A range that is one unfinished sequence still makes progress.
	if text, consumed := terminalText([]byte("\x1b]52;c;"+strings.Repeat("A", 100)), false); string(text) != "" || consumed != 107 {
		t.Errorf("no-progress guard: %q %d", text, consumed)
	}
}

func TestTerminalOutputIsArchivedButInputIsNot(t *testing.T) {
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	logs := archive.openLogs()
	if len(logs) != 1 {
		t.Fatalf("%d open logs", len(logs))
	}
	log := logs[0]
	output := "hello \x1b[31mred\x1b[0m\r\nline two\r\n"
	fixture.emit(info.ID, output)
	if w := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("secret-input\n")}); w.Code != 200 {
		t.Fatalf("input: %d %s", w.Code, w.Body)
	}
	archiveEventually(t, "the output to reach the log", func() bool {
		log.mu.Lock()
		defer log.mu.Unlock()
		return int(log.bytes)+len(log.pending) == len(output)
	})
	host.maintain(nil)
	flushArchive(t, archive)
	listed := decodeBody[ArchiveTerminalLogPage](t, request(t, host.Handler(), "GET", "/v1/archive/terminal-logs?projectId=p1", token, nil))
	if len(listed.Logs) != 1 || listed.Logs[0].ID != log.ID() || listed.Logs[0].Status != "running" || listed.Logs[0].Title != "Shell" ||
		listed.Logs[0].Program != "shell" || listed.Logs[0].Bytes != int64(len(output)) {
		t.Fatalf("running log %+v", listed.Logs)
	}
	raw := decodeBody[archiveTerminalRangeJSON](t, request(t, host.Handler(), "GET", "/v1/archive/terminal-log?id="+log.ID(), token, nil))
	data, _ := base64.StdEncoding.DecodeString(raw.Data.(string))
	if string(data) != output || raw.EOF {
		t.Fatalf("raw log %q eof=%v", data, raw.EOF)
	}
	text := decodeBody[archiveTerminalRangeJSON](t, request(t, host.Handler(), "GET", "/v1/archive/terminal-log?format=text&id="+log.ID(), token, nil))
	if text.Data != "hello red\nline two\n" {
		t.Fatalf("text log %q", text.Data)
	}

	if w := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]string{"projectId": "p1", "terminalId": info.ID}); w.Code != 200 {
		t.Fatalf("close: %d %s", w.Code, w.Body)
	}
	archiveEventually(t, "the log to close", func() bool { return archive.openLog(log.ID()) == nil })
	flushArchive(t, archive)
	stored, err := archive.ArchivedTerminalLog(t.Context(), log.ID())
	if err != nil || stored.Status != "exited" || stored.EndedAt == "" || stored.Bytes != int64(len(output)) || stored.GapBytes != 0 {
		t.Fatalf("closed log %+v %v", stored, err)
	}
	path, _ := archive.terminalLogPath(stored.file)
	contents, err := os.ReadFile(path)
	if err != nil || string(contents) != output || strings.Contains(string(contents), "secret-input") {
		t.Fatalf("log file %q %v", contents, err)
	}
	if !strings.HasPrefix(stored.file, "terminals/"+time.Now().UTC().Format("2006/01")+"/tl_") {
		t.Fatalf("log file name %q", stored.file)
	}
	changes := decodeBody[ArchiveChanges](t, request(t, host.Handler(), "GET", "/v1/archive/changes", token, nil))
	if len(changes.Changes) != 1 || changes.Changes[0].Entity != "terminalLog" || !strings.Contains(string(changes.Changes[0].Payload), `"status":"exited"`) {
		t.Fatalf("changes %+v", changes)
	}
}

func TestTerminalCaptureCountsGapsWhileDiskIsLow(t *testing.T) {
	var free atomic.Uint64
	free.Store(64 << 30)
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return free.Load(), nil }})
	info := createTerminalFixture(t, host, token)
	log := archive.openLogs()[0]
	state := func() (int64, int64) {
		log.mu.Lock()
		defer log.mu.Unlock()
		return log.bytes + int64(len(log.pending)), log.gap
	}
	fixture.emit(info.ID, "kept-1 ")
	archiveEventually(t, "captured output", func() bool { kept, _ := state(); return kept == 7 })

	free.Store(archiveMinimumFree - 1)
	host.maintain(nil)
	fixture.emit(info.ID, "skipped while low")
	archiveEventually(t, "a gap", func() bool { _, gap := state(); return gap == 17 })
	host.maintain(nil)
	flushArchive(t, archive)
	stats := decodeBody[ArchiveStats](t, localRequest(t, host.Handler(), "GET", "/v1/archive/stats", routeLocalToken, nil))
	if !stats.CapturePaused || stats.GapBytes != 17 || stats.FreeBytes == nil || *stats.FreeBytes != archiveMinimumFree-1 || stats.MinimumFreeBytes != archiveMinimumFree {
		t.Fatalf("paused stats %+v", stats)
	}

	free.Store(archiveMinimumFree)
	host.maintain(nil)
	fixture.emit(info.ID, "kept-2")
	archiveEventually(t, "capture to resume", func() bool { kept, _ := state(); return kept == 13 })
	host.maintain(nil)
	flushArchive(t, archive)
	stored, err := archive.ArchivedTerminalLog(t.Context(), log.ID())
	if err != nil || stored.Bytes != 13 || stored.GapBytes != 17 {
		t.Fatalf("log after the gap %+v %v", stored, err)
	}
	path, _ := archive.terminalLogPath(stored.file)
	if contents, _ := os.ReadFile(path); string(contents) != "kept-1 kept-2" {
		t.Fatalf("log file %q", contents)
	}
	if stats := decodeBody[ArchiveStats](t, localRequest(t, host.Handler(), "GET", "/v1/archive/stats", routeLocalToken, nil)); stats.CapturePaused {
		t.Fatal("capture still paused after space returned")
	}
}

func TestTerminalLogBuffersAreWrittenEarlyWhenLarge(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	chunk := strings.Repeat("x", 64<<10)
	for range 5 {
		log.Append([]byte(chunk))
	}
	log.mu.Lock()
	written, pending := log.bytes, len(log.pending)
	log.mu.Unlock()
	if written != 4*int64(len(chunk)) || pending != len(chunk) {
		t.Fatalf("written %d pending %d", written, pending)
	}
	log.Close("exited", nil)
	log.Close("disconnected", nil)
	log.Append([]byte("after close"))
	flushArchive(t, archive)
	stored, _ := archive.ArchivedTerminalLog(t.Context(), log.ID())
	if stored.Bytes != 5*int64(len(chunk)) || stored.Status != "exited" {
		t.Fatalf("stored %+v", stored)
	}
	var nilLog *TerminalLog
	nilLog.Append([]byte("ignored"))
	nilLog.Close("exited", nil)
}

// terminalLogContents is the file of a terminal log.
func terminalLogContents(t *testing.T, archive *Archive, id string) string {
	t.Helper()
	flushArchive(t, archive)
	stored, err := archive.ArchivedTerminalLog(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	path, ok := archive.terminalLogPath(stored.file)
	if !ok {
		t.Fatalf("log path %q", stored.file)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// storedTerminalLog is a log's row once every queued write is in.
func storedTerminalLog(t *testing.T, archive *Archive, id string) archiveTerminalLogJSON {
	t.Helper()
	flushArchive(t, archive)
	stored, err := archive.ArchivedTerminalLog(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	return stored
}

func TestAppendAtSkipsWhatTheLogHasAndCountsGaps(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_1", ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	log.AppendAt(0, []byte("abc"))
	log.AppendAt(1, []byte("bcd"))
	if position := log.Position(); position != 4 {
		t.Fatalf("position %d after overlapping output, want 4", position)
	}
	log.flush()
	if contents := terminalLogContents(t, archive, log.ID()); contents != "abcd" {
		t.Fatalf("log file %q", contents)
	}
	log.AppendAt(10, []byte("xy"))
	log.AppendAt(3, []byte("old"))
	if position := log.Position(); position != 12 {
		t.Fatalf("position %d after a skip, want 12", position)
	}
	log.flush()
	if contents := terminalLogContents(t, archive, log.ID()); contents != "abcdxy" {
		t.Fatalf("log file %q", contents)
	}
	if stored := storedTerminalLog(t, archive, log.ID()); stored.GapBytes != 6 || stored.Bytes != 6 {
		t.Fatalf("gap %d bytes %d, want 6 and 6", stored.GapBytes, stored.Bytes)
	}
}

// The terminal keeps running in the keeper: closing the archive leaves its
// log running, with what was written, for the next host to resume.
func TestArchiveCloseLeavesLiveTerminalLogsRunning(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive, err := OpenArchive(directory, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }})
	if err != nil {
		t.Fatal(err)
	}
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_1", ProjectID: "p1", Title: "Running"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("partial"))
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("after close"))
	db, err := sql.Open("sqlite", filepath.Join(directory, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	var status string
	var bytes int64
	var ended sql.NullInt64
	if err := db.QueryRow(`SELECT status, bytes, ended_at FROM terminal_logs`).Scan(&status, &bytes, &ended); err != nil || status != "running" || bytes != 7 || ended.Valid {
		t.Fatalf("after Close: %q %d %v %v", status, bytes, ended, err)
	}
	db.Close()
	// Opening the archive again changes nothing: the host settles it.
	reopened := openTestArchive(t, directory, ArchiveOptions{})
	if stored := storedTerminalLog(t, reopened, log.ID()); stored.Status != "running" || stored.Bytes != 7 {
		t.Fatalf("reopened %+v", stored)
	}
	if contents := terminalLogContents(t, reopened, log.ID()); contents != "partial" {
		t.Fatalf("log file %q", contents)
	}
}

func TestResumeTerminalLogContinuesTheSameFile(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	first := openTestArchive(t, directory, ArchiveOptions{})
	log, err := first.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_1", ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("abc"))
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second := openTestArchive(t, directory, ArchiveOptions{})
	resumed, err := second.ResumeTerminalLog(log.ID())
	if err != nil {
		t.Fatal(err)
	}
	if position := resumed.Position(); position != 3 {
		t.Fatalf("resumed at %d, want 3", position)
	}
	if _, err := second.ResumeTerminalLog(log.ID()); err == nil {
		t.Fatal("a log open in this process resumed twice")
	}
	resumed.AppendAt(3, []byte("def"))
	resumed.flush()
	if contents := terminalLogContents(t, second, log.ID()); contents != "abcdef" {
		t.Fatalf("log file %q", contents)
	}
	var rows int
	if err := second.readDB.QueryRow(`SELECT count(*) FROM terminal_logs`).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("%d rows, %v", rows, err)
	}
	if stored := storedTerminalLog(t, second, log.ID()); stored.Status != "running" || stored.Bytes != 6 {
		t.Fatalf("resumed row %+v", stored)
	}
	resumed.CloseEnded("exited", nil, terminalEndProgramExited, "")
	flushArchive(t, second)
	if _, err := second.ResumeTerminalLog(log.ID()); err == nil {
		t.Fatal("a finished log resumed")
	}
}

// A host that died before writing its buffer leaves the row ahead of the
// file; the file is the truth, and the keeper's replay fills the rest.
func TestResumeAfterACrashTrustsTheFile(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	first := openTestArchive(t, directory, ArchiveOptions{})
	log, err := first.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_1", ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("abcdef"))
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(directory, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE terminal_logs SET bytes = 10`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	second := openTestArchive(t, directory, ArchiveOptions{})
	resumed, err := second.ResumeTerminalLog(log.ID())
	if err != nil {
		t.Fatal(err)
	}
	if position := resumed.Position(); position != 6 {
		t.Fatalf("resumed at %d, want the file's 6", position)
	}
	resumed.AppendAt(0, []byte("abcdefghij"))
	resumed.flush()
	if contents := terminalLogContents(t, second, log.ID()); contents != "abcdefghij" {
		t.Fatalf("log file %q", contents)
	}
	if stored := storedTerminalLog(t, second, log.ID()); stored.Bytes+stored.GapBytes != 10 || stored.GapBytes != 0 {
		t.Fatalf("bytes %d gap %d", stored.Bytes, stored.GapBytes)
	}
}

// Logs of terminals no keeper holds end as keeperStopped (an older host's
// OpenCode terminals as hostStopped), at their last write; held and open
// logs stay running.
func TestReconcileMarksUnheldRowsKeeperStopped(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	ids := map[string]string{}
	for _, terminal := range []string{"term_held", "term_gone", "pty_old", "term_open"} {
		log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: terminal, ProjectID: "p1", OwnerDeviceID: "d1"})
		if err != nil {
			t.Fatal(err)
		}
		log.Append([]byte(terminal))
		ids[terminal] = log.ID()
		if terminal != "term_open" {
			log.Detach()
		}
	}
	flushArchive(t, archive)
	written := time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)
	gone := storedTerminalLog(t, archive, ids["term_gone"])
	path, _ := archive.terminalLogPath(gone.file)
	if err := os.Chtimes(path, written, written); err != nil {
		t.Fatal(err)
	}
	ended, err := archive.ReconcileTerminalLogs(map[string]bool{"term_held": true}, unheldTerminalEnd)
	if err != nil || ended != 2 {
		t.Fatalf("ended %d, %v; want 2", ended, err)
	}
	for terminal, want := range map[string]string{"term_held": "", "term_open": "", "term_gone": terminalEndKeeperStopped, "pty_old": terminalEndHostStopped} {
		stored := storedTerminalLog(t, archive, ids[terminal])
		if want == "" {
			if stored.Status != "running" {
				t.Errorf("%s: %+v, want running", terminal, stored)
			}
			continue
		}
		if stored.Status != "interrupted" || stored.EndReason != want || stored.Bytes != int64(len(terminal)) {
			t.Errorf("%s: %+v, want interrupted %s", terminal, stored, want)
		}
		record, err := archive.TerminalEnding(t.Context(), terminal, "p1")
		if err != nil || record.end.Reason != want {
			t.Errorf("%s ending %+v %v", terminal, record, err)
		}
	}
	if stored := storedTerminalLog(t, archive, ids["term_gone"]); stored.EndedAt != written.Format(archiveTimeLayout) {
		t.Errorf("ended at %s, want the last write %s", stored.EndedAt, written.Format(archiveTimeLayout))
	}
	page, _ := archive.Changes(t.Context(), "", 10, []string{"p1"})
	interrupted := 0
	for _, change := range page.Changes {
		if strings.Contains(string(change.Payload), `"status":"interrupted"`) {
			interrupted++
		}
	}
	if interrupted != 2 {
		t.Fatalf("%d interrupted changes in %+v", interrupted, page.Changes)
	}
}

// A running row that flush built before the terminal's end was recorded
// never undoes that end, whether it is queued with it or applied after it.
func TestAStaleRunningRowNeverUndoesTheEnd(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{BatchDelay: 50 * time.Millisecond})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_1", ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("abc"))
	log.mu.Lock()
	log.writeLocked()
	stale := log.rowLocked()
	log.mu.Unlock()
	code := 0
	log.CloseEnded("exited", &code, terminalEndProgramExited, "")
	archive.submitTerminalLogRow(stale, false)
	if stored := storedTerminalLog(t, archive, log.ID()); stored.Status != "exited" || stored.EndReason != terminalEndProgramExited {
		t.Fatalf("queued with the end: %+v", stored)
	}
	archive.submitTerminalLogRow(stale, false)
	if stored := storedTerminalLog(t, archive, log.ID()); stored.Status != "exited" || stored.EndReason != terminalEndProgramExited || stored.EndedAt == "" {
		t.Fatalf("applied after the end: %+v", stored)
	}
}

func TestHostCloseRecordsTerminalLogsBeforeClosingTheArchive(t *testing.T) {
	_, store, agent := testHost(t)
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive, err := OpenArchive(directory, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }})
	if err != nil {
		t.Fatal(err)
	}
	fixture := newTerminalFixture(agent)
	host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, Archive: archive})
	fakeTerminalPrograms(host, false)
	token := paired(t, host, store)
	info := createTerminalFixture(t, host, token)
	log := archive.openLogs()[0]
	fixture.emit(info.ID, "bye")
	archiveEventually(t, "output in the log", func() bool {
		log.mu.Lock()
		defer log.mu.Unlock()
		return log.bytes+int64(len(log.pending)) == 3
	})
	closed := make(chan error, 1)
	go func() { closed <- host.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("host Close did not finish")
	}
	select {
	case <-archive.writerDone:
	default:
		t.Fatal("host Close left the archive writer running")
	}
	if err := host.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	// Close detaches: the terminal keeps running in the keeper, so its log
	// stays running for the next host.
	reopened := openTestArchive(t, directory, ArchiveOptions{})
	stored, err := reopened.ArchivedTerminalLog(t.Context(), log.ID())
	if err != nil || stored.Status != "running" || stored.Bytes != 3 || len(fixture.endedIDs()) != 0 {
		t.Fatalf("log after host Close %+v %v", stored, err)
	}
}

func TestMaintenanceRunsForAnArchiveAlone(t *testing.T) {
	_, store, agent := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	host := NewWithOptions(store, agent, HostOptions{Archive: archive})
	if host.stopMaintenance == nil {
		t.Fatal("maintenance did not start for a host with only an archive")
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
}
