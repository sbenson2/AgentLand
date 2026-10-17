package host

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"agentland/host/internal/localsock"
	"agentland/host/keeper"
)

// restoreFixture is a store with one paired device and a fake keeper, before
// a host restores from them.
func restoreFixture(t *testing.T) (*Store, *terminalFixture, string, Device) {
	t.Helper()
	pairing, store, agent := testHost(t)
	token := paired(t, pairing, store)
	return store, newTerminalFixture(agent), token, pairedDevice(t, store, token)
}

// restoreHost is a host made over the fixture's keeper, which restores as it
// is made.
func restoreHost(t *testing.T, store *Store, agent Agent, fixture *terminalFixture, archive *Archive) *Host {
	t.Helper()
	host := NewWithOptions(store, agent, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, Archive: archive})
	fakeTerminalPrograms(host, true)
	t.Cleanup(func() { host.Close() })
	return host
}

func shellRecord(device Device) terminalMeta {
	return terminalMeta{Owner: device.ID, Project: "p1", Program: "shell", Title: "Shell", Created: time.Now().UTC()}
}

func keptTerminal(id string, meta terminalMeta, start uint64) keeper.Info {
	return keeper.Info{ID: id, PID: 4242, Started: time.Now().Add(-time.Hour), Start: start, Meta: encodedMeta(meta)}
}

// encodedMeta is meta's record; a fixture whose record cannot be written is a
// test's mistake.
func encodedMeta(meta terminalMeta) []byte {
	record, err := meta.encode()
	if err != nil {
		panic(err)
	}
	return record
}

func listedTerminals(t *testing.T, host *Host, token string) []TerminalInfo {
	t.Helper()
	response := request(t, host.Handler(), "GET", "/v1/terminals?projectId=p1", token, nil)
	var listed struct {
		Terminals []TerminalInfo `json:"terminals"`
	}
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &listed) != nil {
		t.Fatalf("list: %d %s", response.Code, response.Body)
	}
	return listed.Terminals
}

func terminalLogsOf(t *testing.T, archive *Archive, terminalID string) []archiveTerminalLogJSON {
	t.Helper()
	archive.flushTerminalLogs()
	flushArchive(t, archive)
	logs, err := archiveScanTerminalLogs(archive.readDB.QueryContext(t.Context(), archiveTerminalLogSelect+`WHERE terminal_id = ?`, terminalID))
	if err != nil {
		t.Fatal(err)
	}
	return logs
}

// shortKeeperRetry looks at an unusable keeper every 50 ms for the hosts made
// after it.
func shortKeeperRetry(t *testing.T) {
	saved := keeperRetryEvery
	keeperRetryEvery = 50 * time.Millisecond
	t.Cleanup(func() { keeperRetryEvery = saved })
}

func TestRestoreRebuildsTerminalsBeforeServing(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	fixture.addRunning(keptTerminal("term_a", shellRecord(device), 0), "hello\r\n\x1b]0;Build\x07$ ")
	logs := shellRecord(device)
	logs.Title, logs.ContextTitle = "Logs", "Tailing the logs"
	fixture.addRunning(keptTerminal("term_b", logs, 4096), "tail")
	host := restoreHost(t, store, fixture, fixture, nil)

	listed := listedTerminals(t, host, token)
	if len(listed) != 2 || listed[0].ID != "term_a" || listed[1].ID != "term_b" {
		t.Fatalf("listed %+v", listed)
	}
	if listed[0].Status != "running" || listed[0].ProgramTitle != "Build" || listed[0].Title != "Shell" {
		t.Fatalf("first %+v", listed[0])
	}
	if listed[1].Title != "Logs" || listed[1].ContextTitle != "Tailing the logs" {
		t.Fatalf("second %+v", listed[1])
	}
	if output := readTerminal(t, host, token, "term_a", 0); string(output.Data) != "hello\r\n\x1b]0;Build\x07$ " || output.Reset || output.End != 19 {
		t.Fatalf("first ring %+v", output)
	}
	if output := readTerminal(t, host, token, "term_b", 4096); string(output.Data) != "tail" || output.Reset || output.Cursor != 4100 {
		t.Fatalf("second ring %+v", output)
	}
	fixture.emit("term_a", "ls\r\n")
	waitFor(t, "later output", func() bool { return readTerminal(t, host, token, "term_a", 0).End == 23 })
	if calls := fixture.attachCalls(); len(calls) != 2 || calls[0] != (attachCall{"term_a", 0}) || calls[1] != (attachCall{"term_b", 4096}) {
		t.Fatalf("attach calls %+v", calls)
	}
}

func TestRestoreEndsTerminalsWhoseWorkspaceIsGone(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	record := shellRecord(device)
	record.Project = "removed"
	fixture.addRunning(keptTerminal("term_gone", record, 0), "bye")
	host := restoreHost(t, store, fixture, fixture, archive)
	if !slices.Equal(fixture.endedIDs(), []string{"term_gone"}) || !slices.Equal(fixture.forgottenIDs(), []string{"term_gone"}) {
		t.Fatalf("ended %v forgot %v", fixture.endedIDs(), fixture.forgottenIDs())
	}
	if listed := listedTerminals(t, host, token); len(listed) != 0 {
		t.Fatalf("listed %+v", listed)
	}
	stored := archivedEnd(t, archive, "term_gone")
	if stored.EndReason != terminalEndWorkspaceRemoved || stored.Bytes != 3 {
		t.Fatalf("archived %+v", stored)
	}
}

func TestTerminalsThatFinishedWhileAwayComeBackEnded(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	fixture.addRunning(keptTerminal("term_done", shellRecord(device), 0), "build ok\r\n")
	fixture.exit("term_done", 3)
	// Relative to now, so the host's one-day clear never ages it out.
	exitedAt := time.Now().Add(-time.Hour).UTC().Truncate(time.Millisecond)
	fixture.mu.Lock()
	fixture.terminals["term_done"].info.Exit.At = exitedAt
	fixture.mu.Unlock()
	host := restoreHost(t, store, fixture, fixture, archive)

	output := readTerminal(t, host, token, "term_done", 0)
	if output.Status != "exited" || output.ExitCode == nil || *output.ExitCode != 3 || string(output.Data) != "build ok\r\n" ||
		output.Ended == nil || output.Ended.Reason != terminalEndProgramExited || output.Ended.At != exitedAt.Format(archiveTimeLayout) {
		t.Fatalf("output %+v (ended %+v)", output, output.Ended)
	}
	stored := archivedEnd(t, archive, "term_done")
	if stored.Status != "exited" || stored.EndReason != terminalEndProgramExited || stored.ExitCode == nil || *stored.ExitCode != 3 ||
		stored.EndedAt != exitedAt.Format(archiveTimeLayout) || stored.Bytes != 10 {
		t.Fatalf("archived %+v", stored)
	}
	if response := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]string{"projectId": "p1", "terminalId": "term_done"}); response.Code != 200 {
		t.Fatalf("close: %d %s", response.Code, response.Body)
	}
	if !slices.Equal(fixture.forgottenIDs(), []string{"term_done"}) || len(fixture.endedIDs()) != 0 {
		t.Fatalf("forgot %v ended %v", fixture.forgottenIDs(), fixture.endedIDs())
	}
}

// Review focus 4: the host died after the keeper spawned the terminal but
// before its log or record was written.
func TestATerminalSpawnedWithoutALogGetsOne(t *testing.T) {
	store, fixture, _, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	fixture.addRunning(keptTerminal("term_new", shellRecord(device), 4096), "after the ring")
	restoreHost(t, store, fixture, fixture, archive)
	logs := terminalLogsOf(t, archive, "term_new")
	if len(logs) != 1 || logs[0].Status != "running" || logs[0].GapBytes != 4096 || logs[0].Bytes != 14 {
		t.Fatalf("logs %+v", logs)
	}
	if meta := fixture.meta(t, "term_new"); meta.LogID != logs[0].ID {
		t.Fatalf("record names log %q, want %q", meta.LogID, logs[0].ID)
	}
}

// A record whose log was never written to the keeper (SetMeta failed) goes on
// in the terminal's running log instead of opening a second one.
func TestRestoreResumesTheRunningLogARecordLost(t *testing.T) {
	store, fixture, _, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_lost", ProjectID: "p1", OwnerDeviceID: device.ID})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("abc"))
	log.Detach()
	fixture.addRunning(keptTerminal("term_lost", shellRecord(device), 0), "abcdef")
	restoreHost(t, store, fixture, fixture, archive)
	logs := terminalLogsOf(t, archive, "term_lost")
	if len(logs) != 1 || logs[0].ID != log.ID() || logs[0].Bytes != 6 {
		t.Fatalf("logs %+v", logs)
	}
	if contents := terminalLogContents(t, archive, log.ID()); contents != "abcdef" {
		t.Fatalf("log file %q", contents)
	}
	if meta := fixture.meta(t, "term_lost"); meta.LogID != log.ID() {
		t.Fatalf("record names log %q", meta.LogID)
	}
}

// legacyPTYAgent is a chat agent that records the older host's OpenCode
// terminals it was asked to end.
type legacyPTYAgent struct {
	*terminalFixture
	mu    sync.Mutex
	ended []string
}

func (a *legacyPTYAgent) endLegacyPTY(_ context.Context, project Project, id string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.ended = append(a.ended, project.ID+"/"+id)
	return nil
}

func TestNoKeeperMarksRunningRowsKeeperStopped(t *testing.T) {
	store, fixture, _, _ := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	for _, terminal := range []string{"term_1", "pty_old"} {
		log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: terminal, ProjectID: "p1", OwnerDeviceID: "d1"})
		if err != nil {
			t.Fatal(err)
		}
		log.Append([]byte("output"))
		log.Detach()
	}
	fixture.setStatus(KeeperNone)
	agent := &legacyPTYAgent{terminalFixture: fixture}
	restoreHost(t, store, agent, fixture, archive)
	flushArchive(t, archive)
	for terminal, want := range map[string]string{"term_1": terminalEndKeeperStopped, "pty_old": terminalEndHostStopped} {
		record, err := archive.TerminalEnding(t.Context(), terminal, "p1")
		if err != nil || record.end.Reason != want {
			t.Errorf("%s: %+v %v, want %s", terminal, record, err, want)
		}
	}
	// Ended in the background, after the restore.
	waitFor(t, "the older host's terminal to be ended", func() bool {
		agent.mu.Lock()
		defer agent.mu.Unlock()
		return slices.Equal(agent.ended, []string{"p1/pty_old"})
	})
}

func TestEndLegacyPTYDeletesTheOpenCodeTerminal(t *testing.T) {
	var method, path, directory string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method, path, directory = r.Method, r.URL.Path, r.Header.Get("X-OpenCode-Directory")
		fmt.Fprint(w, "true")
	}))
	defer server.Close()
	adapter := NewOpenCodeAdapter(server.URL, "opencode", "secret", nil)
	if err := adapter.endLegacyPTY(t.Context(), Project{ID: "p1", Directory: "/work/app"}, "pty_1"); err != nil {
		t.Fatal(err)
	}
	if method != "DELETE" || path != "/pty/pty_1" || directory != "/work/app" {
		t.Fatalf("%s %s in %q", method, path, directory)
	}
}

// Review focus 5's routes: a keeper that cannot be used is left alone; its
// terminals' logs stay running, and the host takes them back once it can.
func TestAnUnusableKeeperAnswers503AndLeavesRowsRunning(t *testing.T) {
	shortKeeperRetry(t)
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_kept", ProjectID: "p1", OwnerDeviceID: device.ID})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("kept"))
	log.Detach()
	record := shellRecord(device)
	record.LogID = log.ID()
	fixture.addRunning(keptTerminal("term_kept", record, 0), "kept output")
	fixture.setStatus(KeeperUnusable)
	host := restoreHost(t, store, fixture, fixture, archive)

	if !host.terminals.isUnusable() {
		t.Fatal("an unusable keeper was not noticed")
	}
	const message = "AgentLand's terminal service isn't answering; your terminals are still running."
	wantRouteError(t, "output", outputFixture(t, host, token, "term_kept", 0), 503, "terminals_unavailable", message)
	wantRouteError(t, "input", request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": "term_kept", "data": []byte("ls\n")}),
		503, "terminals_unavailable", message)
	wantRouteError(t, "close", request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]string{"projectId": "p1", "terminalId": "term_kept"}),
		503, "terminals_unavailable", message)
	wantRouteError(t, "create", request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80}),
		503, "terminals_unavailable", message)
	if fixture.spawnCount() != 0 || len(fixture.endedIDs()) != 0 || len(fixture.attachCalls()) != 0 {
		t.Fatal("an unusable keeper was asked to spawn, end or attach")
	}
	if stored := storedTerminalLog(t, archive, log.ID()); stored.Status != "running" {
		t.Fatalf("log %+v", stored)
	}

	fixture.setStatus(KeeperRunning)
	deadline := time.Now().Add(time.Second)
	for len(listedTerminals(t, host, token)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the terminals were not listed within 1 s of the keeper being usable")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if output := readTerminal(t, host, token, "term_kept", 0); string(output.Data) != "kept output" || output.Status != "running" {
		t.Fatalf("output %+v", output)
	}
	archive.flushTerminalLogs()
	if contents := terminalLogContents(t, archive, log.ID()); contents != "kept output" {
		t.Fatalf("log file %q", contents)
	}
	if host.terminals.isUnusable() {
		t.Fatal("still unusable")
	}
}

// Carry: a keeper that could not be used and can be again has its terminals
// followed again from their cursors.
func TestAKeeperUsableAgainIsFollowedAgain(t *testing.T) {
	shortKeeperRetry(t)
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.setStatus(KeeperUnusable)
	fixture.dropAttachments()
	waitFor(t, "the keeper to be unusable", host.terminals.isUnusable)
	fixture.emit(info.ID, "while away")
	fixture.setStatus(KeeperRunning)
	waitFor(t, "output after the keeper came back", func() bool {
		return !host.terminals.isUnusable() && readTerminal(t, host, token, info.ID, 0).End == 10
	})
	if output := readTerminal(t, host, token, info.ID, 0); string(output.Data) != "while away" || output.Status != "running" {
		t.Fatalf("output %+v", output)
	}
}

// Carry: a keeper that could not be used and is then gone ended its
// terminals.
func TestAKeeperGoneAfterBeingUnusableEndsItsTerminals(t *testing.T) {
	shortKeeperRetry(t)
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	fixture.setStatus(KeeperUnusable)
	fixture.dropAttachments()
	waitFor(t, "the keeper to be unusable", host.terminals.isUnusable)
	fixture.setStatus(KeeperNone)
	waitFor(t, "the end", func() bool { return terminalStatus(t, host, token, info.ID) != "running" })
	if output := readTerminal(t, host, token, info.ID, 0); output.Status != "disconnected" || output.Ended == nil || output.Ended.Reason != terminalEndKeeperStopped {
		t.Fatalf("output %+v", output)
	}
	if stored := archivedEnd(t, archive, info.ID); stored.EndReason != terminalEndKeeperStopped || stored.Status != "disconnected" {
		t.Fatalf("archived %+v", stored)
	}
}

// Carry: a Spawn that finds a keeper this build cannot use answers 503 and
// starts looking for a usable one; other failures stay upstream errors.
func TestASpawnThatFindsAnUnusableKeeperAnswers503(t *testing.T) {
	const message = "AgentLand's terminal service isn't answering; your terminals are still running."
	create := func(host *Host, token string) *httptest.ResponseRecorder {
		return request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	}
	didNotStart := fmt.Errorf("%w within 3s: no answer", keeper.ErrKeeperDidNotStart)
	for _, test := range []struct {
		name   string
		err    error
		status KeeperStatus
		want   int
	}{
		{"mismatched keeper", errKeeperUnusable, KeeperRunning, 503},
		{"no common protocol", fmt.Errorf("start: %w", keeper.ErrNoCommonProtocol), KeeperRunning, 503},
		{"hung keeper holding the lock", didNotStart, KeeperUnusable, 503},
		{"keeper that failed to start", didNotStart, KeeperNone, 502},
		{"socket path too long", fmt.Errorf("terminals: the keeper's socket: %w (150 bytes, at most 103)", localsock.ErrTooLong), KeeperNone, 500},
	} {
		host, _, token, fixture := terminalTestHost(t, true)
		fixture.setSpawnErr(test.err)
		fixture.setStatus(test.status)
		response := create(host, token)
		if test.want == 503 {
			wantRouteError(t, test.name, response, 503, "terminals_unavailable", message)
		} else if test.want == 500 {
			wantRouteError(t, test.name, response, 500, "terminal_path_too_long", terminalPathTooLongMessage)
		} else if response.Code != test.want {
			t.Errorf("%s: %d %s", test.name, response.Code, response.Body)
		}
		if unusable := host.terminals.isUnusable(); unusable != (test.want == 503) {
			t.Errorf("%s: unusable %v", test.name, unusable)
		}
	}
}

// Carry: the keeper's own end of every terminal as it stops is keeperStopped.
func TestAKeeperThatEndsItsTerminalsAsItStopsRecordsKeeperStopped(t *testing.T) {
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	fixture.exitByKeeper(info.ID)
	waitFor(t, "the end", func() bool { return terminalStatus(t, host, token, info.ID) != "running" })
	if output := readTerminal(t, host, token, info.ID, 0); output.Status != "disconnected" || output.Ended == nil || output.Ended.Reason != terminalEndKeeperStopped {
		t.Fatalf("output %+v", output)
	}
	if stored := archivedEnd(t, archive, info.ID); stored.EndReason != terminalEndKeeperStopped || stored.Status != "disconnected" {
		t.Fatalf("archived %+v", stored)
	}
}

// Carry: an idle stream that drops long after it was attached is not a
// failed try, however often that happens.
func TestAnIdleStreamThatDropsLaterResetsTheTries(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	host.terminals.reattachQuick = 20 * time.Millisecond
	info := createTerminalFixture(t, host, token)
	for range 2 * terminalReattachTries {
		time.Sleep(50 * time.Millisecond)
		before := len(fixture.attachCalls())
		fixture.dropAttachments()
		waitFor(t, "a new attachment", func() bool { return len(fixture.attachCalls()) == before+1 && fixture.openAttachments() == 1 })
	}
	if host.terminals.isUnusable() || terminalStatus(t, host, token, info.ID) != "running" {
		t.Fatal("idle streams that dropped made the keeper unusable")
	}
}

// Carry: removing the workspace of a terminal whose follower stopped records
// its log's end, once.
func TestEndingATerminalWhoseFollowerStoppedRecordsItsLog(t *testing.T) {
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, "abc")
	waitFor(t, "output", func() bool { return readTerminal(t, host, token, info.ID, 0).End == 3 })
	fixture.setStatus(KeeperUnusable)
	fixture.dropAttachments()
	waitFor(t, "the keeper to be unusable", host.terminals.isUnusable)
	host.terminals.mu.Lock()
	entry := host.terminals.entries[info.ID]
	host.terminals.mu.Unlock()
	waitFor(t, "the follower to stop", func() bool {
		entry.mu.Lock()
		defer entry.mu.Unlock()
		return !entry.following
	})
	if err := host.endTerminals("p1"); err != nil {
		t.Fatal(err)
	}
	if stored := archivedEnd(t, archive, info.ID); stored.EndReason != terminalEndWorkspaceRemoved || stored.Bytes != 3 {
		t.Fatalf("archived %+v", stored)
	}
}

// Carry: descriptions reach the keeper's record, so a restore finds them.
func TestContextTitlesReachTheKeepersRecord(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, "\x1b]0;Deploying\x07")
	waitFor(t, "the program's title in the record", func() bool {
		meta := fixture.meta(t, info.ID)
		return meta.ContextTitle == "Deploying" && meta.ContextTitleSource == "program"
	})
	response := request(t, host.Handler(), "POST", "/v1/terminal/title", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "title": "Fix the login bug", "basedOn": 14})
	if response.Code != 200 {
		t.Fatalf("title: %d %s", response.Code, response.Body)
	}
	waitFor(t, "the description in the record", func() bool {
		meta := fixture.meta(t, info.ID)
		return meta.ContextTitle == "Fix the login bug" && meta.ContextTitleSource == "device"
	})
	if meta := fixture.meta(t, info.ID); meta.Title != "Shell" || meta.Owner == "" || meta.Program != "shell" {
		t.Fatalf("record %+v", meta)
	}
}

// Review (Important 1): a terminal that finished while no host followed it,
// and that no device has closed yet, keeps its one ended log however often
// the host starts again.
func TestAFinishedTerminalKeepsOneLogAcrossRestarts(t *testing.T) {
	store, fixture, _, device := restoreFixture(t)
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	fixture.addRunning(keptTerminal("term_done", shellRecord(device), 0), "build ok\r\n")
	fixture.exit("term_done", 3)
	for start := 1; start <= 2; start++ {
		archive := openTestArchive(t, directory, ArchiveOptions{})
		host := restoreHost(t, store, fixture, fixture, archive)
		logs := terminalLogsOf(t, archive, "term_done")
		if len(logs) != 1 || logs[0].Status != "exited" || logs[0].Bytes != 10 {
			t.Fatalf("start %d: logs %+v", start, logs)
		}
		if failures := archive.failures.Load(); failures != 0 {
			archive.mu.Lock()
			last := archive.lastErr
			archive.mu.Unlock()
			t.Fatalf("start %d: %d archive failures, the last %q", start, failures, last)
		}
		if meta := fixture.meta(t, "term_done"); meta.LogID != logs[0].ID {
			t.Fatalf("start %d: the record names log %q, want %q", start, meta.LogID, logs[0].ID)
		}
		if err := host.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

// Review (Important 2): the titles a restore replays are older than the
// description the record holds. The description stays, in the entry, the
// record and the log; the program's title is the replay's newest. A device's
// name stays a device's across the restart: live output after the replay
// changes only the program's title.
func TestRestoreKeepsTheDevicesTitle(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_named", ProjectID: "p1", OwnerDeviceID: device.ID, Title: "Shell"})
	if err != nil {
		t.Fatal(err)
	}
	log.Rename("Fix the login bug")
	log.Detach()
	record := shellRecord(device)
	record.ContextTitle, record.ContextTitleSource, record.LogID = "Fix the login bug", "device", log.ID()
	fixture.addRunning(keptTerminal("term_named", record, 0), "\x1b]0;Deploying\x07")
	host := restoreHost(t, store, fixture, fixture, archive)

	listed := listedTerminals(t, host, token)
	if len(listed) != 1 || listed[0].ContextTitle != "Fix the login bug" || listed[0].ContextTitleSource != "device" || listed[0].ProgramTitle != "Deploying" {
		t.Fatalf("listed %+v", listed)
	}
	// The record is written in the background: a write that must not happen
	// has time to.
	for range 20 {
		if meta := fixture.meta(t, "term_named"); meta.ContextTitle != "Fix the login bug" {
			t.Fatalf("the record's description became %q", meta.ContextTitle)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if stored := storedTerminalLog(t, archive, log.ID()); stored.Title != "Fix the login bug" {
		t.Fatalf("the log is titled %q", stored.Title)
	}

	fixture.emit("term_named", "\x1b]0;Testing\x07")
	waitFor(t, "the program's new title", func() bool {
		listed := listedTerminals(t, host, token)
		return len(listed) == 1 && listed[0].ProgramTitle == "Testing"
	})
	if listed := listedTerminals(t, host, token); listed[0].ContextTitle != "Fix the login bug" || listed[0].ContextTitleSource != "device" {
		t.Fatalf("the program's title replaced the device's name: %+v", listed[0])
	}
	if meta := fixture.meta(t, "term_named"); meta.ContextTitle != "Fix the login bug" || meta.ContextTitleSource != "device" {
		t.Fatalf("record %+v", meta)
	}
}

// An older build's record names no source: its description counts as the
// program's, which the program's next title replaces as before.
func TestRestoreCountsAnOlderRecordsDescriptionAsTheProgramsTitle(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	record := shellRecord(device)
	record.ContextTitle = "Fix the login bug"
	fixture.addRunning(keptTerminal("term_old", record, 0), "\x1b]0;Deploying\x07")
	host := restoreHost(t, store, fixture, fixture, archive)
	listed := listedTerminals(t, host, token)
	if len(listed) != 1 || listed[0].ContextTitle != "Fix the login bug" || listed[0].ContextTitleSource != "program" {
		t.Fatalf("listed %+v", listed)
	}
	fixture.emit("term_old", "\x1b]0;Testing\x07")
	waitFor(t, "the program's new title", func() bool {
		listed := listedTerminals(t, host, token)
		return len(listed) == 1 && listed[0].ContextTitle == "Testing" && listed[0].ProgramTitle == "Testing"
	})
	waitFor(t, "the new title in the record", func() bool {
		meta := fixture.meta(t, "term_old")
		return meta.ContextTitle == "Testing" && meta.ContextTitleSource == "program"
	})
}

// slowLegacyPTYAgent is an OpenCode that answers no request to end an older
// host's terminal until the request ends.
type slowLegacyPTYAgent struct {
	*terminalFixture
	mu    sync.Mutex
	asked []string
	ended chan error
}

func (a *slowLegacyPTYAgent) endLegacyPTY(ctx context.Context, project Project, id string) error {
	a.mu.Lock()
	a.asked = append(a.asked, project.ID+"/"+id)
	a.mu.Unlock()
	<-ctx.Done()
	a.ended <- ctx.Err()
	return ctx.Err()
}

// Controller ruling 21: ending an older host's OpenCode terminals never
// delays restoring the keeper's. It goes on in the background after the host
// serves, and Host.Close stops it.
func TestLegacyPTYsEndAfterTheKeepersTerminalsAreRestored(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	for _, terminal := range []string{"pty_1", "pty_2"} {
		log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: terminal, ProjectID: "p1", OwnerDeviceID: device.ID})
		if err != nil {
			t.Fatal(err)
		}
		log.Detach()
	}
	fixture.addRunning(keptTerminal("term_a", shellRecord(device), 0), "hello")
	agent := &slowLegacyPTYAgent{terminalFixture: fixture, ended: make(chan error, 2)}
	began := time.Now()
	host := restoreHost(t, store, agent, fixture, archive)
	if took := time.Since(began); took > time.Second {
		t.Fatalf("the host took %v to restore", took)
	}
	if output := readTerminal(t, host, token, "term_a", 0); string(output.Data) != "hello" || output.Reset || output.Status != "running" {
		t.Fatalf("output %+v", output)
	}
	if stored := archivedEnd(t, archive, "pty_1"); stored.EndReason != terminalEndHostStopped {
		t.Fatalf("archived %+v", stored)
	}
	// One request at a time: the first waits until Close.
	waitFor(t, "an older host's terminal to be asked to end", func() bool {
		agent.mu.Lock()
		defer agent.mu.Unlock()
		return len(agent.asked) == 1 && (agent.asked[0] == "p1/pty_1" || agent.asked[0] == "p1/pty_2")
	})
	closing := time.Now()
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(closing); took > time.Second {
		t.Fatalf("Close took %v", took)
	}
	select {
	case err := <-agent.ended:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("the request ended with %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Close did not stop the request")
	}
	agent.mu.Lock()
	defer agent.mu.Unlock()
	if len(agent.asked) != 1 {
		t.Fatalf("asked %v after Close", agent.asked)
	}
}

// The Mac app reads /v1/terminals/running for its terminal-access switch. While
// the keeper is unusable the host cannot say how many run, so it answers 503
// terminals_unavailable (never a count of 0); once usable it answers the count.
func TestTheRunningCountSaysWhenTheTerminalServiceCannotBeUsed(t *testing.T) {
	shortKeeperRetry(t)
	store, fixture, _, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_kept", ProjectID: "p1", OwnerDeviceID: device.ID})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("kept"))
	log.Detach()
	record := shellRecord(device)
	record.LogID = log.ID()
	fixture.addRunning(keptTerminal("term_kept", record, 0), "kept")
	fixture.setStatus(KeeperUnusable)
	host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, Archive: archive, LocalSessionToken: routeLocalToken})
	fakeTerminalPrograms(host, true)
	t.Cleanup(func() { host.Close() })
	if !host.terminals.isUnusable() {
		t.Fatal("an unusable keeper was not noticed")
	}
	wantRouteError(t, "running", localRequest(t, host.Handler(), "GET", "/v1/terminals/running", routeLocalToken, nil),
		503, "terminals_unavailable", terminalsUnavailableMessage)
	if list := macAll(t, host); list.Keeper.State != "unavailable" {
		t.Fatalf("all while unusable: %+v", list)
	}

	fixture.setStatus(KeeperRunning)
	deadline := time.Now().Add(2 * time.Second)
	for {
		w := localRequest(t, host.Handler(), "GET", "/v1/terminals/running", routeLocalToken, nil)
		if w.Code == 200 {
			if strings.TrimSpace(w.Body.String()) != `{"running":1,"routed":0}` {
				t.Fatalf("running after recovery: %s", w.Body)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("running did not recover: %d %s", w.Code, w.Body)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// A keeper that takes the connection but never answers holds the host's start
// up for at most terminalProbeWait: it reads as unusable, its terminals are
// left as they are, and the host serves (503 terminals_unavailable).
func TestAKeeperThatNeverAnswersDoesNotHoldUpTheStart(t *testing.T) {
	for _, hung := range []string{"status", "list"} {
		t.Run(hung, func(t *testing.T) {
			store, fixture, token, device := restoreFixture(t)
			fixture.addRunning(keptTerminal("term_kept", shellRecord(device), 0), "kept")
			fixture.mu.Lock()
			fixture.hangStatus, fixture.hangList = hung == "status", hung == "list"
			fixture.mu.Unlock()
			began := time.Now()
			host := restoreHost(t, store, fixture, fixture, nil)
			if took := time.Since(began); took > 2*time.Second {
				t.Fatalf("the host took %v to start", took)
			}
			if !host.terminals.isUnusable() {
				t.Fatal("a keeper that never answers was not found unusable")
			}
			wantRouteError(t, "create", request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80}),
				503, "terminals_unavailable", terminalsUnavailableMessage)
			if fixture.spawnCount() != 0 || len(fixture.endedIDs()) != 0 || len(fixture.forgottenIDs()) != 0 {
				t.Fatal("a keeper that never answers was asked to spawn, end or forget")
			}
		})
	}
}

// A record a newer build wrote (meta version above this build's) is that
// build's: restore leaves it running in the keeper, its log running, and
// lists it to no one. A record that does not parse is still ended.
func TestARecordFromANewerBuildIsLeftAlone(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_newer", ProjectID: "p1", OwnerDeviceID: device.ID})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("newer"))
	log.Detach()
	record := shellRecord(device)
	record.LogID = log.ID()
	newer := keptTerminal("term_newer", record, 0)
	newer.Meta = bytes.Replace(newer.Meta, []byte(`"v":1`), []byte(`"v":3`), 1)
	fixture.addRunning(newer, "newer output")
	fixture.addRunning(keeper.Info{ID: "term_garbage", PID: 4243, Started: time.Now(), Meta: []byte("not a record")}, "")
	host := restoreHost(t, store, fixture, fixture, archive)

	if !slices.Equal(fixture.endedIDs(), []string{"term_garbage"}) || !slices.Equal(fixture.forgottenIDs(), []string{"term_garbage"}) {
		t.Fatalf("ended %v forgot %v", fixture.endedIDs(), fixture.forgottenIDs())
	}
	if listed := listedTerminals(t, host, token); len(listed) != 0 {
		t.Fatalf("listed %+v", listed)
	}
	flushArchive(t, archive)
	if stored := storedTerminalLog(t, archive, log.ID()); stored.Status != "running" {
		t.Fatalf("log %+v", stored)
	}
	if host.terminals.isUnusable() {
		t.Fatal("a newer record made the keeper unusable")
	}
}

// Verification: a keeper whose stream stalls mid-replay holds the host's
// start no longer than the restore's bound. The terminal is listed, and its
// follower takes over once the stream moves.
func TestARestoreWhoseReplayStallsStillServesInTime(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	fixture.addRunning(keptTerminal("term_slow", shellRecord(device), 0), "first half, second half")
	fixture.holdBack("term_slow", len("second half"))
	began := time.Now()
	host := restoreHost(t, store, fixture, fixture, nil)
	if took := time.Since(began); took > terminalRestoreWait+500*time.Millisecond {
		t.Fatalf("the host took %v to restore", took)
	}
	listed := listedTerminals(t, host, token)
	if len(listed) != 1 || listed[0].ID != "term_slow" || listed[0].Status != "running" {
		t.Fatalf("listed %+v", listed)
	}
	fixture.unhold("term_slow")
	waitFor(t, "the follower to take over", func() bool { return readTerminal(t, host, token, "term_slow", 0).End == 23 })
	if output := readTerminal(t, host, token, "term_slow", 0); string(output.Data) != "first half, second half" || output.Status != "running" {
		t.Fatalf("output %+v", output)
	}
}
