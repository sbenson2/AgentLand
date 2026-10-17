package host

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

// endingTerminalHost is a host with the fake keeper that finds opencode,
// claude and codex, and archive (nil for none).
func endingTerminalHost(t *testing.T, store *Store, archive *Archive) (*Host, *terminalFixture) {
	t.Helper()
	fixture := newTerminalFixture(&fakeAgent{sessions: map[string]Session{}})
	host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, Archive: archive})
	fakeTerminalPrograms(host, true)
	t.Cleanup(func() { host.Close() })
	return host, fixture
}

type terminalNotFoundBody struct {
	Error struct {
		Code  string       `json:"code"`
		Ended *TerminalEnd `json:"ended"`
	} `json:"error"`
}

func waitForTerminalEnd(t *testing.T, host *Host, token, id string) terminalOutput {
	t.Helper()
	var output terminalOutput
	archiveEventually(t, "the terminal to end", func() bool {
		output = decodeBody[terminalOutput](t, outputFixture(t, host, token, id, 0))
		return output.Status != "running"
	})
	return output
}

func archivedEnd(t *testing.T, archive *Archive, terminalID string) archiveTerminalLogJSON {
	t.Helper()
	var stored archiveTerminalLogJSON
	archiveEventually(t, "the terminal's log to record its end", func() bool {
		flushArchive(t, archive)
		logs, err := archiveScanTerminalLogs(archive.readDB.QueryContext(t.Context(), archiveTerminalLogSelect+`WHERE terminal_id = ?`, terminalID))
		if err != nil || len(logs) != 1 || logs[0].Status == "running" {
			return false
		}
		stored = logs[0]
		return true
	})
	return stored
}

// A program that exits says so, with its exit code, live and in the archive.
func TestTerminalProgramExitRecordsTheReasonAndExitCode(t *testing.T) {
	_, store, _ := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	host, fixture := endingTerminalHost(t, store, archive)
	token := paired(t, host, store)
	info := createTerminalFixture(t, host, token)
	fixture.exit(info.ID, 3)
	output := waitForTerminalEnd(t, host, token, info.ID)
	if output.Status != "exited" || output.ExitCode == nil || *output.ExitCode != 3 || output.Ended == nil ||
		output.Ended.Reason != terminalEndProgramExited || output.Ended.At == "" || output.Ended.Program != "shell" ||
		output.Ended.ExitCode == nil || *output.Ended.ExitCode != 3 || output.Ended.Device != "" {
		t.Fatalf("output after exit %+v %+v", output, output.Ended)
	}
	stored := archivedEnd(t, archive, info.ID)
	if stored.Status != "exited" || stored.EndReason != terminalEndProgramExited || stored.ExitCode == nil || *stored.ExitCode != 3 || stored.endedBy != "" {
		t.Fatalf("archived %+v", stored)
	}
}

// When the keeper is gone, every running terminal ends as keeperStopped,
// live and in the archive: one still followed, and one whose follower had
// already stopped because the keeper could not be used for it.
func TestAKeeperThatIsGoneRecordsEveryTerminalsEnd(t *testing.T) {
	_, store, _ := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	host, fixture := endingTerminalHost(t, store, archive)
	token := paired(t, host, store)
	unfollowed := createTerminalFixture(t, host, token)
	followed := createTerminalFixture(t, host, token)
	fixture.setStatus(KeeperUnusable)
	fixture.dropAttachments(unfollowed.ID)
	host.terminals.mu.Lock()
	entry := host.terminals.entries[unfollowed.ID]
	host.terminals.mu.Unlock()
	select {
	case <-entry.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the follower kept following an unusable keeper")
	}
	if status := terminalStatus(t, host, token, unfollowed.ID); status != "running" {
		t.Fatalf("status %s with an unusable keeper", status)
	}
	fixture.setStatus(KeeperNone)
	fixture.dropAttachments(followed.ID)
	for _, id := range []string{unfollowed.ID, followed.ID} {
		output := waitForTerminalEnd(t, host, token, id)
		if output.Status != "disconnected" || output.Ended == nil || output.Ended.Reason != terminalEndKeeperStopped {
			t.Fatalf("%s ended %+v %+v", id, output, output.Ended)
		}
		if stored := archivedEnd(t, archive, id); stored.Status != "disconnected" || stored.EndReason != terminalEndKeeperStopped {
			t.Fatalf("%s archived %+v", id, stored)
		}
	}
}

// A terminal a device ended is forgotten; asking for its output says who
// ended it and when, from the archive.
func TestTerminalEndedByADeviceSaysSoAfterItIsForgotten(t *testing.T) {
	_, store, _ := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	host, _ := endingTerminalHost(t, store, archive)
	token := paired(t, host, store)
	devices, err := store.ListDevices()
	if err != nil || len(devices) != 1 {
		t.Fatalf("devices %v %v", devices, err)
	}
	info := createTerminalFixture(t, host, token)
	if w := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]string{"projectId": "p1", "terminalId": info.ID}); w.Code != 200 {
		t.Fatalf("close: %d %s", w.Code, w.Body)
	}
	stored := archivedEnd(t, archive, info.ID)
	if stored.EndReason != terminalEndDevice || stored.endedBy != devices[0].ID || stored.ExitCode != nil {
		t.Fatalf("archived %+v", stored)
	}
	w := outputFixture(t, host, token, info.ID, 0)
	body := decodeBody[terminalNotFoundBody](t, w)
	if w.Code != 404 || body.Error.Code != "terminal_not_found" || body.Error.Ended == nil || body.Error.Ended.Reason != terminalEndDevice ||
		body.Error.Ended.Device != "Phone" || body.Error.Ended.At == "" || body.Error.Ended.Program != "shell" {
		t.Fatalf("output of an ended terminal: %d %s", w.Code, w.Body)
	}
	// A terminal the archive never saw says nothing; every paired device
	// learns how this one ended (terminal_shared.go).
	if w := outputFixture(t, host, token, "pty_unknown", 0); w.Code != 404 || strings.Contains(w.Body.String(), "ended") {
		t.Fatalf("unknown terminal: %d %s", w.Code, w.Body)
	}
	other := paired(t, host, store)
	if w := outputFixture(t, host, other, info.ID, 0); w.Code != 404 || decodeBody[terminalNotFoundBody](t, w).Error.Ended == nil {
		t.Fatalf("another device's terminal: %d %s", w.Code, w.Body)
	}
}

// Removing a workspace ends its terminals as such.
func TestTerminalEndedWithItsWorkspaceSaysSo(t *testing.T) {
	_, store, _ := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	host, _ := endingTerminalHost(t, store, archive)
	token := paired(t, host, store)
	info := createTerminalFixture(t, host, token)
	if err := host.endTerminals("p1"); err != nil {
		t.Fatal(err)
	}
	if stored := archivedEnd(t, archive, info.ID); stored.EndReason != terminalEndWorkspaceRemoved || stored.endedBy != "" {
		t.Fatalf("archived %+v", stored)
	}
}

// An older host marked the logs it found left running as interrupted with no
// reason; they still read as hostInterrupted.
func TestAnOlderHostsInterruptedLogSaysHostInterrupted(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "pty_1", ProjectID: "p1", OwnerDeviceID: "d1", Program: "claude",
		ConversationID: "0f8fad5b-d9cb-469f-a165-70867728950e"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("partial"))
	log.Detach()
	flushArchive(t, archive)
	if _, err := archive.TerminalEnding(t.Context(), "pty_1", "p1"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("a running log has no end: %v", err)
	}
	if err := archive.do(func(tx *archiveTx) error {
		_, err := tx.exec(`UPDATE terminal_logs SET status = 'interrupted', end_reason = '', ended_at = ? WHERE id = ?`, tx.now, log.ID())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	record, err := archive.TerminalEnding(t.Context(), "pty_1", "p1")
	if err != nil || record.end.Reason != terminalEndHostInterrupted || record.end.Program != "claude" ||
		record.end.ConversationID != "0f8fad5b-d9cb-469f-a165-70867728950e" || record.end.At == "" {
		t.Fatalf("interrupted end %+v %v", record, err)
	}
	// Any device learns it; another workspace does not, and naming none
	// finds it by the terminal alone.
	if _, err := archive.TerminalEnding(t.Context(), "pty_1", "p2"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("another workspace's terminal: %v", err)
	}
	if record, err := archive.TerminalEnding(t.Context(), "pty_1", ""); err != nil || record.end.Reason != terminalEndHostInterrupted {
		t.Fatalf("without a workspace %+v %v", record, err)
	}
}

// Claude Code terminals start in a conversation the host names; a device
// resumes one by its ID or opens Claude Code's picker, never with arguments.
func TestClaudeTerminalsStartAndResumeConversations(t *testing.T) {
	_, store, _ := testHost(t)
	host, fixture := endingTerminalHost(t, store, nil)
	token := paired(t, host, store)
	create := func(body map[string]any) (int, TerminalInfo) {
		t.Helper()
		request := map[string]any{"projectId": "p1", "title": "Claude Code", "rows": 24, "cols": 80, "program": "claude"}
		for key, value := range body {
			request[key] = value
		}
		w := requestJSON(t, host, token, request)
		var info TerminalInfo
		_ = json.Unmarshal(w.Body.Bytes(), &info)
		return w.Code, info
	}
	code, fresh := create(nil)
	if code != 201 || !conversationIDPattern.MatchString(fresh.ConversationID) {
		t.Fatalf("new conversation: %d %+v", code, fresh)
	}
	code, resumed := create(map[string]any{"resume": "0F8FAD5B-D9CB-469F-A165-70867728950E"})
	if code != 201 || resumed.ConversationID != "0f8fad5b-d9cb-469f-a165-70867728950e" {
		t.Fatalf("resumed: %d %+v", code, resumed)
	}
	code, picked := create(map[string]any{"resume": "pick"})
	if code != 201 || picked.ConversationID != "" {
		t.Fatalf("pick: %d %+v", code, picked)
	}
	fixture.mu.Lock()
	spawns := slices.Clone(fixture.spawns)
	fixture.mu.Unlock()
	if len(spawns) != 3 || spawns[0].Path != "/bin/claude" || !slices.Equal(spawns[0].Args, []string{"--session-id", fresh.ConversationID}) ||
		!slices.Equal(spawns[1].Args, []string{"--resume", "0f8fad5b-d9cb-469f-a165-70867728950e"}) || !slices.Equal(spawns[2].Args, []string{"--resume"}) {
		t.Fatalf("spawns %+v", spawns)
	}
	if meta, err := decodeTerminalMeta(spawns[0].Meta); err != nil || meta.ConversationID != fresh.ConversationID || meta.Program != "claude" {
		t.Fatalf("claude record %+v %v", meta, err)
	}
	for _, bad := range []map[string]any{
		{"resume": "--dangerously-skip-permissions"},
		{"resume": "0f8fad5b-d9cb-469f-a165-70867728950e --print"},
		{"resume": "latest"},
		{"resume": "pick", "program": "shell"},
		{"resume": "0f8fad5b-d9cb-469f-a165-70867728950e", "program": "shell"},
	} {
		if code, _ := create(bad); code != 400 {
			t.Fatalf("%v: %d", bad, code)
		}
	}
	capabilities := decodeBody[map[string]any](t, request(t, host.Handler(), "GET", "/v1/capabilities", token, nil))
	if features, _ := json.Marshal(capabilities["terminalFeatures"]); !strings.Contains(string(features), `"resume"`) {
		t.Fatalf("terminalFeatures %s", features)
	}
	// A host that finds no claude offers no resume.
	plain, _, plainToken, _ := terminalTestHost(t, true)
	fakeTerminalPrograms(plain, false)
	plainCapabilities := decodeBody[map[string]any](t, request(t, plain.Handler(), "GET", "/v1/capabilities", plainToken, nil))
	if features, _ := json.Marshal(plainCapabilities["terminalFeatures"]); strings.Contains(string(features), `"resume"`) {
		t.Fatalf("plain terminalFeatures %s", features)
	}
}

func requestJSON(t *testing.T, host *Host, token string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	return request(t, host.Handler(), "POST", "/v1/terminals", token, body)
}

// A keeper that crashed can still look alive to Status for a moment; the
// re-attach then finds none (errNoKeeper). That ends the terminals as
// keeperStopped, not as an unusable keeper.
func TestReattachFindingNoKeeperEndsTerminalsAsKeeperStopped(t *testing.T) {
	_, store, _ := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	host, fixture := endingTerminalHost(t, store, archive)
	token := paired(t, host, store)
	info := createTerminalFixture(t, host, token)
	fixture.setAttachErr(errNoKeeper)
	fixture.dropAttachments(info.ID)
	output := waitForTerminalEnd(t, host, token, info.ID)
	if output.Status != "disconnected" || output.Ended == nil || output.Ended.Reason != terminalEndKeeperStopped {
		t.Fatalf("ended %+v %+v", output, output.Ended)
	}
}
