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

	"agentland/host/keeper"
)

func createTerminalFixture(t *testing.T, host *Host, token string) TerminalInfo {
	t.Helper()
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if response.Code != 201 {
		t.Fatalf("create terminal: %d %s", response.Code, response.Body.String())
	}
	var info TerminalInfo
	if err := json.Unmarshal(response.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	return info
}
func outputFixture(t *testing.T, host *Host, token, id string, cursor uint64) *httptest.ResponseRecorder {
	t.Helper()
	return request(t, host.Handler(), "GET", fmt.Sprintf("/v1/terminal/output?projectId=p1&terminalId=%s&cursor=%d", id, cursor), token, nil)
}

func TestTerminalRequiresExplicitHostOptIn(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, false)
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if response.Code != 403 || fixture.spawnCount() != 0 {
		t.Fatalf("disabled terminal: %d spawns=%d", response.Code, fixture.spawnCount())
	}
	response = request(t, host.Handler(), "GET", "/v1/capabilities", token, nil)
	if response.Code != 200 {
		t.Fatalf("capabilities: %d", response.Code)
	}
	var caps struct{ Terminal bool }
	json.Unmarshal(response.Body.Bytes(), &caps)
	if caps.Terminal {
		t.Fatal("disabled terminal advertised as available")
	}
}

func TestTerminalProgramsAreAdvertisedAndServerSelected(t *testing.T) {
	host, store, token, fixture := terminalTestHost(t, true)
	response := request(t, host.Handler(), "GET", "/v1/capabilities", token, nil)
	var caps struct {
		TerminalPrograms []string `json:"terminalPrograms"`
		TerminalFeatures []string `json:"terminalFeatures"`
	}
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &caps) != nil || !slices.Equal(caps.TerminalPrograms, []string{"shell", "opencode", "claude", "codex"}) ||
		!slices.Equal(caps.TerminalFeatures, []string{"title", "resume", "keep", "shared"}) {
		t.Fatalf("unexpected capability programs: %d %s", response.Code, response.Body.String())
	}
	response = request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{
		"projectId": "p1", "title": "OpenCode", "rows": 24, "cols": 80, "program": "opencode",
		"command": "/bin/sh", "args": []string{"-c", "untrusted"}, "env": map[string]string{"LEAK": "no"},
	})
	if response.Code != 400 || fixture.spawnCount() != 0 {
		t.Fatalf("client command reached a terminal: %d spawns=%d", response.Code, fixture.spawnCount())
	}
	response = request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{
		"projectId": "p1", "title": "OpenCode", "rows": 24, "cols": 80, "program": "opencode",
	})
	if response.Code != 201 {
		t.Fatalf("named terminal: %d %s", response.Code, response.Body.String())
	}
	directory := mustProject(t, store).Directory
	spawn := fixture.lastSpawn()
	if spawn.Path != "/bin/opencode" || !slices.Equal(spawn.Args, []string{"attach", "http://127.0.0.1:4096", "--dir", directory}) || spawn.Dir != directory ||
		!slices.Contains(spawn.Env, "OPENCODE_SERVER_PASSWORD=fixture-password") || slices.ContainsFunc(spawn.Env, func(item string) bool { return strings.HasPrefix(item, "LEAK=") }) {
		t.Fatalf("client command bypassed server program selection: %+v", spawn)
	}
	response = request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80, "program": "vim"})
	if response.Code != 400 || fixture.spawnCount() != 1 {
		t.Fatalf("unavailable program created terminal: %d spawns=%d", response.Code, fixture.spawnCount())
	}
}

// A request for a program the host lacks used to return while holding the
// terminal manager's lock, which then blocked every terminal route and shutdown.
func TestTerminalUnavailableProgramReleasesTheManager(t *testing.T) {
	host, _, token, _ := terminalTestHost(t, true)
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80, "program": "vim"})
	if response.Code != 400 {
		t.Fatalf("unavailable program: %d %s", response.Code, response.Body.String())
	}
	created := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		created <- request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	}()
	select {
	case response := <-created:
		if response.Code != 201 {
			t.Fatalf("terminal after unavailable program: %d %s", response.Code, response.Body.String())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("creating a terminal blocked after an unavailable-program request")
	}
	stopped := make(chan error, 1)
	go func() { stopped <- host.Close() }()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("host shutdown blocked after an unavailable-program request")
	}
}

// Every paired device reaches every terminal (terminal_shared.go), but only in
// the terminal's own workspace, and its own list stays its own; a revoked
// device reaches none.
func TestTerminalAccessRejectsOtherProjectsAndRevocation(t *testing.T) {
	host, store, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	other := paired(t, host, store)
	if response := request(t, host.Handler(), "GET", "/v1/terminal/output?projectId=p1&terminalId="+info.ID+"&cursor=0", other, nil); response.Code != 200 {
		t.Fatalf("other-device output: %d", response.Code)
	}
	if response := request(t, host.Handler(), "GET", "/v1/terminals?projectId=p1", other, nil); response.Code != 200 || bytes.Contains(response.Body.Bytes(), []byte(info.ID)) {
		t.Fatalf("other-device list leaked terminal: %d %s", response.Code, response.Body.String())
	}
	if response := request(t, host.Handler(), "POST", "/v1/terminal/input", other, map[string]any{"projectId": "unknown", "terminalId": info.ID, "data": []byte("pwd\n")}); response.Code != 404 {
		t.Fatalf("an unknown workspace accepted: %d", response.Code)
	}
	if _, err := store.addProject(t.TempDir(), "Second"); err != nil {
		t.Fatal(err)
	}
	projects, _ := store.Read()
	for _, project := range projects.Config.Projects {
		if project.ID == "p1" {
			continue
		}
		if response := request(t, host.Handler(), "POST", "/v1/terminal/input", other, map[string]any{"projectId": project.ID, "terminalId": info.ID, "data": []byte("pwd\n")}); response.Code != 404 {
			t.Fatalf("another workspace accepted: %d", response.Code)
		}
	}
	if fixture.input(info.ID) != "" {
		t.Fatal("input in the wrong workspace reached the shell")
	}
	if response := request(t, host.Handler(), "POST", "/v1/terminal/input", other, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("pwd\n")}); response.Code != 200 || fixture.input(info.ID) != "pwd\n" {
		t.Fatalf("other-device input: %d", response.Code)
	}
	if err := store.RevokeDevice(pairedDevice(t, store, token).ID); err != nil {
		t.Fatal(err)
	}
	response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("ls\n")})
	if response.Code != 401 {
		t.Fatalf("revoked terminal input: %d", response.Code)
	}
	if fixture.input(info.ID) != "pwd\n" {
		t.Fatal("unauthorized input reached the shell")
	}
}

func TestTerminalPreservesBytesAndCursorAcrossForegroundReconnect(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	first := []byte("\x1b[32mready\x1b[0m\r\n")
	fixture.emit(info.ID, string(first))
	response := outputFixture(t, host, token, info.ID, 0)
	var out struct {
		Data   []byte
		Cursor uint64
		Reset  bool
		Status string
	}
	if response.Code != 200 {
		t.Fatalf("output: %d", response.Code)
	}
	if err := json.Unmarshal(response.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.Data, first) || out.Cursor != uint64(len(first)) || out.Reset {
		t.Fatalf("first output lost: %s", response.Body.String())
	}
	fixture.emit(info.ID, "next\r\n")
	response = outputFixture(t, host, token, info.ID, out.Cursor)
	if err := json.Unmarshal(response.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if string(out.Data) != "next\r\n" || out.Cursor != uint64(len(first)+6) {
		t.Fatalf("cursor duplicated or dropped output: %s", response.Body.String())
	}
	response = outputFixture(t, host, token, info.ID, 0)
	json.Unmarshal(response.Body.Bytes(), &out)
	if string(out.Data) != string(first)+"next\r\n" {
		t.Fatal("new foreground view cannot replay retained output")
	}
	input := []byte("printf 'one'\n\x03")
	response = request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": input})
	if response.Code != 200 {
		t.Fatalf("input: %d", response.Code)
	}
	if fixture.input(info.ID) != string(input) {
		t.Fatal("terminal input bytes changed or replayed")
	}
}

func TestTerminalBoundsInputDimensionsAndCursor(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	for _, size := range [][2]int{{0, 80}, {24, 0}, {301, 80}, {24, 501}} {
		response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": size[0], "cols": size[1]})
		if response.Code != 400 {
			t.Fatalf("unsafe size: %d", response.Code)
		}
	}
	if fixture.spawnCount() != 0 {
		t.Fatal("invalid terminal allocated a process")
	}
	info := createTerminalFixture(t, host, token)
	response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": bytes.Repeat([]byte("x"), 32769)})
	if response.Code != 400 {
		t.Fatalf("oversized input: %d", response.Code)
	}
	response = request(t, host.Handler(), "GET", "/v1/terminal/output?projectId=p1&terminalId="+info.ID+"&cursor=-1", token, nil)
	if response.Code != 400 {
		t.Fatalf("negative cursor: %d", response.Code)
	}
	response = request(t, host.Handler(), "POST", "/v1/terminal/resize", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "rows": 40, "cols": 100})
	if response.Code != 200 || fixture.size() != [2]int{40, 100} {
		t.Fatalf("resize not applied: %d %v", response.Code, fixture.size())
	}
}

func TestTerminalOutputCancellationDoesNotEndTheRemoteProcess(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest("GET", "/v1/terminal/output?projectId=p1&terminalId="+info.ID+"&cursor=0", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+token)
	start := time.Now()
	host.Handler().ServeHTTP(httptest.NewRecorder(), req)
	if time.Since(start) > time.Second {
		t.Fatal("cancelled poll waited for output")
	}
	if len(fixture.endedIDs()) != 0 {
		t.Fatal("backgrounding ended the remote terminal")
	}
	response := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]any{"projectId": "p1", "terminalId": info.ID})
	if response.Code != 200 || len(fixture.endedIDs()) != 1 {
		t.Fatalf("explicit end did not close terminal: %d ends=%v", response.Code, fixture.endedIDs())
	}
	response = outputFixture(t, host, token, info.ID, 0)
	if response.Code != 404 {
		t.Fatalf("closed terminal accessible: %d", response.Code)
	}
}

func TestTerminalWriteFailureIsReportedWithoutReplay(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.setInputErr(errors.New("disconnected"))
	response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("run-once\n")})
	if response.Code != http.StatusBadGateway {
		t.Fatalf("uncertain write: %d", response.Code)
	}
	if fixture.input(info.ID) != "" || terminalStatus(t, host, token, info.ID) != "running" {
		t.Fatal("failed write was replayed or ended the terminal")
	}
}

func TestTerminalOutputWindowSignalsAVisibleReset(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, strings.Repeat("x", (2<<20)+10))
	var output terminalOutput
	deadline := time.Now().Add(time.Second)
	for {
		response := outputFixture(t, host, token, info.ID, 0)
		if err := json.Unmarshal(response.Body.Bytes(), &output); err != nil {
			t.Fatal(err)
		}
		if output.Reset || time.Now().After(deadline) {
			break
		}
	}
	if !output.Reset || len(output.Data) != 64<<10 || output.Cursor != 10+(64<<10) {
		t.Fatalf("retained output boundary not reported: %+v", output)
	}
}

// Each read says where the host's output ends, so a device that attaches with history to catch up on knows
// which bytes were already drawn (and answered) before it came.
func TestTerminalOutputReportsTheNewestCursor(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, strings.Repeat("y", (64<<10)+5))
	var output terminalOutput
	deadline := time.Now().Add(time.Second)
	for {
		if err := json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &output); err != nil {
			t.Fatal(err)
		}
		if output.End == (64<<10)+5 || time.Now().After(deadline) {
			break
		}
	}
	if output.Cursor != 64<<10 || output.End != (64<<10)+5 {
		t.Fatalf("a first chunk reports cursor %d and end %d, not %d and %d", output.Cursor, output.End, 64<<10, (64<<10)+5)
	}
	if err := json.Unmarshal(outputFixture(t, host, token, info.ID, output.Cursor).Body.Bytes(), &output); err != nil {
		t.Fatal(err)
	}
	if output.Cursor != output.End || output.End != (64<<10)+5 {
		t.Fatalf("the caught-up read reports cursor %d and end %d", output.Cursor, output.End)
	}
}

func TestTerminalShutdownWaitsForPendingCreateCleanup(t *testing.T) {
	checkPendingCreateCleanup(t, nil)
}

func TestTerminalShutdownReportsPendingCreateCleanupFailure(t *testing.T) {
	checkPendingCreateCleanup(t, errors.New("fixture upstream cleanup unavailable"))
}

func checkPendingCreateCleanup(t *testing.T, cleanupError error) {
	t.Helper()
	host, _, token, fixture := terminalTestHost(t, true)
	fixture.endErr = cleanupError
	fixture.spawnEntered = make(chan struct{})
	fixture.spawnRelease = make(chan struct{})
	entered := fixture.spawnEntered
	var release sync.Once
	unblock := func() { release.Do(func() { close(fixture.spawnRelease) }) }
	defer unblock()
	created := make(chan int, 1)
	go func() {
		response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80})
		created <- response.Code
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("creation did not start")
	}
	stopped := make(chan error, 1)
	go func() { stopped <- host.Close() }()
	deadline := time.Now().Add(time.Second)
	for {
		host.terminals.mu.Lock()
		closed := host.terminals.closed
		host.terminals.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("shutdown did not start")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case <-stopped:
		t.Fatal("host exited before pending PTY could be cleaned up")
	default:
	}
	unblock()
	select {
	case status := <-created:
		if status != 503 {
			t.Fatalf("pending creation returned %d", status)
		}
	case <-time.After(time.Second):
		t.Fatal("pending create did not finish")
	}
	select {
	case err := <-stopped:
		if !errors.Is(err, cleanupError) {
			t.Fatalf("shutdown cleanup result was lost: got %v, want %v", err, cleanupError)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown did not finish")
	}
	if len(fixture.endedIDs()) != 1 {
		t.Fatal("pending remote process was orphaned")
	}
}

// readTerminal is GET /v1/terminal/output from cursor, without waiting.
func readTerminal(t *testing.T, host *Host, token, id string, cursor uint64) terminalOutput {
	t.Helper()
	response := request(t, host.Handler(), "GET", fmt.Sprintf("/v1/terminal/output?projectId=p1&terminalId=%s&cursor=%d&wait=0", id, cursor), token, nil)
	var output terminalOutput
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &output) != nil {
		t.Fatalf("output: %d %s", response.Code, response.Body)
	}
	return output
}

func terminalStatus(t *testing.T, host *Host, token, id string) string {
	t.Helper()
	return readTerminal(t, host, token, id, 0).Status
}

// pairedDevice is the device token was paired as.
func pairedDevice(t *testing.T, store *Store, token string) Device {
	t.Helper()
	state, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	for _, device := range state.Devices {
		if device.TokenHash == hash(token) {
			return device
		}
	}
	t.Fatal("no device for the token")
	return Device{}
}

func TestCreateSpawnsInTheKeeperWithItsOwnerRecord(t *testing.T) {
	host, _, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	spawn := fixture.lastSpawn()
	if !strings.HasPrefix(info.ID, "term_") || len(info.ID) != len("term_")+16 || spawn.ID != info.ID || spawn.Dir != mustProject(t, host.store).Directory {
		t.Fatalf("spawned %+v for %+v", spawn, info)
	}
	meta := fixture.meta(t, info.ID)
	if meta.Owner != pairedDevice(t, host.store, token).ID || meta.Project != "p1" || meta.Program != "shell" || meta.LogID == "" || meta.Title != "Shell" {
		t.Fatalf("owner record %+v", meta)
	}
	// The record the keeper got first names the owner too; the log joins it.
	if first, err := decodeTerminalMeta(spawn.Meta); err != nil || first.Owner != meta.Owner || first.LogID != "" {
		t.Fatalf("spawn record %+v %v", first, err)
	}
}

func TestOutputKeepsTheKeepersCursor(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, "abc")
	waitFor(t, "abc", func() bool { return readTerminal(t, host, token, info.ID, 0).End == 3 })
	fixture.emit(info.ID, "def")
	waitFor(t, "def", func() bool { return readTerminal(t, host, token, info.ID, 0).End == 6 })
	if output := readTerminal(t, host, token, info.ID, 0); string(output.Data) != "abcdef" || output.End != 6 || output.Cursor != 6 || output.Reset {
		t.Fatalf("output %+v", output)
	}
}

func TestSkippedOutputResetsOldCursors(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.skip(info.ID, 2097152)
	waitFor(t, "the skip", func() bool { return readTerminal(t, host, token, info.ID, 2097152).End == 2097152 })
	if output := readTerminal(t, host, token, info.ID, 0); !output.Reset || output.Cursor != 2097152 || len(output.Data) != 0 {
		t.Fatalf("output after a skip %+v", output)
	}
}

func TestProgramExitEndsWithItsCode(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.exit(info.ID, 3)
	waitFor(t, "the exit", func() bool { return terminalStatus(t, host, token, info.ID) != "running" })
	output := readTerminal(t, host, token, info.ID, 0)
	if output.Status != "exited" || output.Ended == nil || output.Ended.Reason != "programExited" || output.Ended.ExitCode == nil || *output.Ended.ExitCode != 3 ||
		output.ExitCode == nil || *output.ExitCode != 3 {
		t.Fatalf("ended %+v", output)
	}
}

func TestStalledInputIsRefusedButTheTerminalRuns(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.setInputErr(fakeKeeperError(keeper.CodeInputStalled))
	response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("paste")})
	wantRouteError(t, "stalled input", response, 409, "terminal_input_stalled", "The program in this terminal isn't reading input; nothing was sent.")
	if status := terminalStatus(t, host, token, info.ID); status != "running" {
		t.Fatalf("status %s after stalled input", status)
	}
	// Input that meets the program's exit is refused as such.
	fixture.setInputErr(fakeKeeperError(keeper.CodeNotRunning))
	response = request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("late")})
	if response.Code != 409 || !strings.Contains(response.Body.String(), "terminal_not_running") {
		t.Fatalf("input after the exit: %d %s", response.Code, response.Body)
	}
}

func TestCloseEndsAndForgets(t *testing.T) {
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	log := archive.openLogs()[0]
	if response := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]any{"projectId": "p1", "terminalId": info.ID}); response.Code != 200 {
		t.Fatalf("close: %d %s", response.Code, response.Body)
	}
	if ends, forgets := fixture.endedIDs(), fixture.forgottenIDs(); !slices.Equal(ends, []string{info.ID}) || !slices.Equal(forgets, []string{info.ID}) {
		t.Fatalf("ends %v forgets %v", ends, forgets)
	}
	archiveEventually(t, "the log to close", func() bool { return archive.openLog(log.ID()) == nil })
	flushArchive(t, archive)
	device := pairedDevice(t, host.store, token)
	record, err := archive.TerminalEnding(t.Context(), info.ID, "p1")
	if err != nil || record.end.Reason != "endedByDevice" || record.endedBy != device.ID {
		t.Fatalf("archived end %+v %v", record, err)
	}
}

func TestRemovingAWorkspaceEndsAndForgetsItsTerminals(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	zeta := f.add(t, filepath.Join(f.home, "Zeta"))
	response := f.call(t, "POST", "/v1/terminals", map[string]any{"projectId": zeta.ID, "title": "Shell", "rows": 24, "cols": 80})
	if response.Code != 201 {
		t.Fatalf("terminal: %d %s", response.Code, response.Body)
	}
	var info TerminalInfo
	json.Unmarshal(response.Body.Bytes(), &info)
	if response := f.call(t, "POST", "/v1/projects/remove", map[string]any{"id": zeta.ID, "endTerminals": true}); response.Code != 200 {
		t.Fatalf("remove: %d %s", response.Code, response.Body)
	}
	if ends, forgets := f.terminal.endedIDs(), f.terminal.forgottenIDs(); !slices.Equal(ends, []string{info.ID}) || !slices.Equal(forgets, []string{info.ID}) {
		t.Fatalf("ends %v forgets %v", ends, forgets)
	}
	f.host.terminals.mu.Lock()
	left := len(f.host.terminals.entries)
	f.host.terminals.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d terminals left", left)
	}
}

func TestHostCloseNeverEndsTerminals(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, "running")
	waitFor(t, "output", func() bool { return readTerminal(t, host, token, info.ID, 0).End == 7 })
	closed := make(chan error, 1)
	go func() { closed <- host.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close took longer than the app's grace")
	}
	if len(fixture.endedIDs()) != 0 || len(fixture.forgottenIDs()) != 0 || fixture.openAttachments() != 0 {
		t.Fatalf("Close ended %v, forgot %v, left %d attachments", fixture.endedIDs(), fixture.forgottenIDs(), fixture.openAttachments())
	}
	fixture.mu.Lock()
	backendClosed := fixture.closed
	fixture.mu.Unlock()
	if backendClosed != 1 {
		t.Fatalf("backend closed %d times", backendClosed)
	}
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80})
	if response.Code != 503 || fixture.spawnCount() != 1 {
		t.Fatal("a closed host created another terminal")
	}
}

func TestALostAttachmentReattachesFromTheCursor(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.emit(info.ID, "abcdef")
	waitFor(t, "six bytes", func() bool { return readTerminal(t, host, token, info.ID, 0).End == 6 })
	fixture.dropAttachments()
	waitFor(t, "a second attach", func() bool { return len(fixture.attachCalls()) == 2 })
	if calls := fixture.attachCalls(); calls[0] != (attachCall{info.ID, 0}) || calls[1] != (attachCall{info.ID, 6}) {
		t.Fatalf("attach calls %+v", calls)
	}
	fixture.emit(info.ID, "gh")
	waitFor(t, "later output", func() bool { return readTerminal(t, host, token, info.ID, 0).End == 8 })
	if output := readTerminal(t, host, token, info.ID, 6); string(output.Data) != "gh" || output.Status != "running" {
		t.Fatalf("output after re-attaching %+v", output)
	}
}

// A keeper that accepts every attach and drops each stream at once is tried
// at most 3 more times, 200 ms apart; then it counts as unusable, and the
// terminal stays running.
func TestAStreamThatFailsAtOnceIsReattachedAtMostThreeTimes(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	broke := time.Now()
	fixture.breakStreams()
	waitFor(t, "the keeper to be unusable", host.terminals.isUnusable)
	if waited := time.Since(broke); waited < 2*terminalReattachPause {
		t.Fatalf("gave up after %v; tries are %v apart", waited, terminalReattachPause)
	}
	time.Sleep(4 * terminalReattachPause)
	if calls := fixture.attachCalls(); len(calls) > 1+terminalReattachTries {
		t.Fatalf("%d attach calls, want at most %d", len(calls), 1+terminalReattachTries)
	}
	if status := terminalStatus(t, host, token, info.ID); status != "running" {
		t.Fatalf("status %s after its stream kept failing", status)
	}
}

func TestAKeeperThatIsGoneEndsTerminalsAsKeeperStopped(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.setStatus(KeeperNone)
	fixture.dropAttachments()
	waitFor(t, "the end", func() bool { return terminalStatus(t, host, token, info.ID) != "running" })
	if output := readTerminal(t, host, token, info.ID, 0); output.Status != "disconnected" || output.Ended == nil || output.Ended.Reason != "keeperStopped" {
		t.Fatalf("ended %+v", output)
	}
	if len(fixture.endedIDs()) != 0 || len(fixture.attachCalls()) != 1 {
		t.Fatalf("a gone keeper was asked to end %v or attach %v", fixture.endedIDs(), fixture.attachCalls())
	}
}

func TestAnUnusableKeeperLeavesTerminalsRunning(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	fixture.setStatus(KeeperUnusable)
	fixture.dropAttachments()
	waitFor(t, "the keeper to be unusable", host.terminals.isUnusable)
	if status := terminalStatus(t, host, token, info.ID); status != "running" {
		t.Fatalf("status %s with an unusable keeper", status)
	}
	response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("ls\n")})
	wantRouteError(t, "input to an unusable keeper", response, 503, "terminals_unavailable", "AgentLand's terminal service isn't answering; your terminals are still running.")
	if len(fixture.endedIDs()) != 0 || fixture.input(info.ID) != "" {
		t.Fatal("an unusable keeper was asked to end or write")
	}
}
