//go:build darwin

package host

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"agentland/host/keeper"
)

// keeperHost is a host whose terminals run in a real keeper, state in a
// short folder. The cleanup stops the keeper.
func keeperHost(t *testing.T) (host *Host, backend TerminalBackend, statePath, token string) {
	t.Helper()
	dir := shortTempDir(t)
	statePath = filepath.Join(dir, "state.json")
	store := NewStore(statePath)
	project := t.TempDir()
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: project}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	binary := hostBinary(t)
	t.Setenv("SHELL", "/bin/sh")
	backend = NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: filepath.Join(dir, "terminals.log"), Executable: binary, Version: "test"})
	t.Cleanup(func() {
		exec.Command(binary, "terminals", "stop", "--state", statePath).Run()
	})
	host = NewWithOptions(store, &fakeAgent{}, HostOptions{TerminalEnabled: true, Terminals: backend, TerminalHiddenEnv: []string{"AGENTLAND_LOCAL_SESSION_TOKEN"}})
	t.Cleanup(func() { host.Close() })
	return host, backend, statePath, paired(t, host, store)
}

func waitForShellOutput(t *testing.T, host *Host, token, id, want string) string {
	t.Helper()
	var all []byte
	var cursor uint64
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		output := decodeBody[terminalOutput](t, outputFixture(t, host, token, id, cursor))
		all = append(all, output.Data...)
		cursor = output.Cursor
		if strings.Contains(string(all), want) {
			return string(all)
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("no %q in the terminal's output: %q", want, all)
	return ""
}

func sendShellInput(t *testing.T, host *Host, token, id, text string) {
	t.Helper()
	response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"projectId": "p1", "terminalId": id, "data": []byte(text)})
	if response.Code != 200 && response.Code != 204 {
		t.Fatalf("input: %d %s", response.Code, response.Body.String())
	}
}

func TestKeeperBackendStartsAKeeperOnlyForTheFirstTerminal(t *testing.T) {
	host, backend, _, token := keeperHost(t)
	if status := backend.Status(t.Context()); status != KeeperNone {
		t.Fatalf("before any terminal: status %v, want none", status)
	}
	info := createTerminalFixture(t, host, token)
	if status := backend.Status(t.Context()); status != KeeperRunning {
		t.Fatalf("after a terminal: status %v, want running", status)
	}
	sendShellInput(t, host, token, info.ID, "echo $((40+2))\n")
	waitForShellOutput(t, host, token, info.ID, "42")
}

// Features starts a keeper as Spawn does and answers its hello features;
// Release reaches it, which refuses a terminal it started itself.
func TestKeeperBackendFeaturesStartsAKeeperAndListsAdopt(t *testing.T) {
	host, backend, _, token := keeperHost(t)
	features, err := backend.Features(t.Context())
	if err != nil || !slices.Contains(features, keeper.FeatureAdopt) {
		t.Fatalf("features %v %v", features, err)
	}
	if status := backend.Status(t.Context()); status != KeeperRunning {
		t.Fatalf("after Features: status %v, want running", status)
	}
	info := createTerminalFixture(t, host, token)
	if err := backend.Release(t.Context(), info.ID); keeperCode(err) != keeper.CodeNotAdopted {
		t.Fatalf("release of the keeper's own terminal: %v", err)
	}
}

func TestKeeperShellHasNoHostSecrets(t *testing.T) {
	t.Setenv("AGENTLAND_LOCAL_SESSION_TOKEN", "s3cret")
	host, _, _, token := keeperHost(t)
	info := createTerminalFixture(t, host, token)
	file := filepath.Join(mustProject(t, host.store).Directory, "env.txt")
	sendShellInput(t, host, token, info.ID, "env > env.txt; exit\n")
	deadline := time.Now().Add(15 * time.Second)
	for {
		data, err := os.ReadFile(file)
		if err == nil && strings.Contains(string(data), "TERM=") {
			if strings.Contains(string(data), "s3cret") {
				t.Fatal("the terminal's environment holds the host's token")
			}
			if !strings.Contains(string(data), "TERM=xterm-256color") {
				t.Fatalf("no TERM=xterm-256color in %q", data)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("no environment written: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestTerminalsStopEndsTheKeeper(t *testing.T) {
	host, backend, statePath, token := keeperHost(t)
	createTerminalFixture(t, host, token)
	if status := backend.Status(t.Context()); status != KeeperRunning {
		t.Fatalf("status %v, want running", status)
	}
	if out, err := exec.Command(hostBinary(t), "terminals", "stop", "--state", statePath).CombinedOutput(); err != nil {
		t.Fatalf("terminals stop: %v\n%s", err, out)
	}
	if status := backend.Status(t.Context()); status != KeeperNone {
		t.Fatalf("after stop: status %v, want none", status)
	}
}

// Controller ruling 32: a host started with terminal access off asks a keeper
// still running for its state to end everything, and the keeper exits. With
// no keeper running it starts none.
func TestAHostWithTerminalAccessOffEndsWhatTheKeeperRuns(t *testing.T) {
	host, _, statePath, token := keeperHost(t)
	info := createTerminalFixture(t, host, token)
	sendShellInput(t, host, token, info.ID, "echo $((40+2))\n")
	waitForShellOutput(t, host, token, info.ID, "42")
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	startOff := func() {
		backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, Executable: hostBinary(t), Version: "test"})
		off := NewWithOptions(NewStore(statePath), &fakeAgent{}, HostOptions{Terminals: backend})
		t.Cleanup(func() { off.Close() })
	}
	startOff()
	deadline := time.Now().Add(15 * time.Second)
	for {
		release, err := keeper.TryLock(statePath)
		if err == nil {
			release()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the keeper still runs: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	startOff()
	time.Sleep(300 * time.Millisecond)
	if _, err := os.Stat(keeper.SocketPath(statePath)); !os.IsNotExist(err) {
		t.Fatalf("a host with terminal access off started a keeper: %v", err)
	}
}

func TestKeeperBackendStatusNeverSaysNoneWhenCancelledOrClosed(t *testing.T) {
	_, backend, _, _ := keeperHost(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if status := backend.Status(ctx); status != KeeperUnusable {
		t.Fatalf("cancelled: status %v, want unusable", status)
	}
	backend.Close()
	if status := backend.Status(t.Context()); status != KeeperUnusable {
		t.Fatalf("closed: status %v, want unusable", status)
	}
}

// After the keeper stops under a stored client, Status never says running.
func TestKeeperBackendStatusProvesTheKeeperIsAlive(t *testing.T) {
	host, backend, _, token := keeperHost(t)
	createTerminalFixture(t, host, token)
	if status := backend.Status(t.Context()); status != KeeperRunning {
		t.Fatalf("status %v, want running", status)
	}
	stored := backend.(*keeperBackend).client
	if stored == nil {
		t.Fatal("no stored client")
	}
	if err := stored.StopAll(t.Context()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		status := backend.Status(t.Context())
		if status == KeeperRunning {
			t.Fatal("Status said running after the keeper was told to stop")
		}
		if status == KeeperNone {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("Status never reached none")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A Spawn that arrives while the keeper is stopping waits for it and starts a
// new one through keeper.Start, rather than failing as unusable.
func TestKeeperBackendSpawnDuringAStopStartsAgain(t *testing.T) {
	host, backend, _, token := keeperHost(t)
	createTerminalFixture(t, host, token)
	if err := backend.(*keeperBackend).client.StopAll(t.Context()); err != nil {
		t.Fatal(err)
	}
	createTerminalFixture(t, host, token)
	if status := backend.Status(t.Context()); status != KeeperRunning {
		t.Fatalf("status %v, want running", status)
	}
}

// A host that stops and starts again finds its terminal where it left it:
// the same ID and cursors, the same program, and one continuous log.
func TestATerminalOutlivesTheHost(t *testing.T) {
	dir := shortTempDir(t)
	statePath := filepath.Join(dir, "state.json")
	store := NewStore(statePath)
	project := t.TempDir()
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: project}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	binary := hostBinary(t)
	t.Setenv("SHELL", "/bin/sh")
	t.Cleanup(func() {
		exec.Command(binary, "terminals", "stop", "--state", statePath).Run()
	})
	archiveDirectory := filepath.Join(dir, "state.json.archive")
	start := func() (*Host, *Archive) {
		archive, err := OpenArchive(archiveDirectory, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }, BatchDelay: 2 * time.Millisecond})
		if err != nil {
			t.Fatal(err)
		}
		backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: filepath.Join(dir, "terminals.log"), Executable: binary, Version: "test"})
		host := NewWithOptions(store, &fakeAgent{}, HostOptions{TerminalEnabled: true, Terminals: backend, Archive: archive})
		t.Cleanup(func() { host.Close() })
		return host, archive
	}

	first, _ := start()
	token := paired(t, first, store)
	info := createTerminalFixture(t, first, token)
	sendShellInput(t, first, token, info.ID, "echo $$ > pid-before.txt; for i in $(seq 5); do echo tick-$i; sleep 1; done; echo $$ > pid-after.txt\n")
	waitForShellOutput(t, first, token, info.ID, "tick-1")
	cursor := readTerminal(t, first, token, info.ID, 0).End
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(7 * time.Second)

	second, archive := start()
	listed := listedTerminals(t, second, token)
	if len(listed) != 1 || listed[0].ID != info.ID || listed[0].Status != "running" {
		t.Fatalf("listed %+v", listed)
	}
	output := readTerminal(t, second, token, info.ID, cursor)
	if output.Reset || !strings.Contains(string(output.Data), "tick-5") {
		t.Fatalf("output from the device's cursor %d: reset=%v %q", cursor, output.Reset, output.Data)
	}
	before, errBefore := os.ReadFile(filepath.Join(project, "pid-before.txt"))
	after, errAfter := os.ReadFile(filepath.Join(project, "pid-after.txt"))
	if errBefore != nil || errAfter != nil || len(before) == 0 || string(before) != string(after) {
		t.Fatalf("the shell changed: %q %v, %q %v", before, errBefore, after, errAfter)
	}
	end := readTerminal(t, second, token, info.ID, 0).End
	logs := terminalLogsOf(t, archive, info.ID)
	if len(logs) != 1 || logs[0].GapBytes != 0 || logs[0].Status != "running" || uint64(logs[0].Bytes) != end {
		t.Fatalf("logs %+v, want one of %d bytes", logs, end)
	}
	contents := terminalLogContents(t, archive, logs[0].ID)
	for i := 1; i <= 5; i++ {
		if !strings.Contains(contents, "tick-"+string(rune('0'+i))) {
			t.Fatalf("no tick-%d in the log %q", i, contents)
		}
	}
}

// Review focus 5: a keeper from an incompatible build is left alone. Routes
// answer 503, and nothing is asked of it after its hello.
func TestAKeeperWithNoCommonProtocolIsLeftAlone(t *testing.T) {
	dir := shortTempDir(t)
	statePath := filepath.Join(dir, "state.json")
	store := NewStore(statePath)
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: t.TempDir()}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	release, err := keeper.TryLock(statePath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(release)
	listener, err := net.Listen("unix", keeper.SocketPath(statePath))
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var served sync.WaitGroup
	hellos, afterHello := 0, 0
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			served.Add(1)
			go func() {
				defer served.Done()
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(5 * time.Second))
				var head [4]byte
				if _, err := io.ReadFull(conn, head[:]); err != nil {
					return
				}
				body := make([]byte, binary.BigEndian.Uint32(head[:]))
				if _, err := io.ReadFull(conn, body); err != nil || body[0] != 'H' {
					return
				}
				answer, _ := json.Marshal(map[string]any{"protocol": 0, "version": "future", "features": []string{}, "error": "no common protocol"})
				frame := make([]byte, 5, 5+len(answer))
				binary.BigEndian.PutUint32(frame, uint32(1+len(answer)))
				frame[4] = 'R'
				conn.Write(append(frame, answer...))
				rest, _ := io.ReadAll(conn)
				mu.Lock()
				hellos++
				afterHello += len(rest)
				mu.Unlock()
			}()
		}
	}()
	backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: filepath.Join(dir, "terminals.log"), Executable: "/nonexistent/agentland-host", Version: "test"})
	host := NewWithOptions(store, &fakeAgent{}, HostOptions{TerminalEnabled: true, Terminals: backend})
	t.Cleanup(func() { host.Close() })
	token := paired(t, host, store)
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	wantRouteError(t, "create", response, 503, "terminals_unavailable", terminalsUnavailableMessage)
	listener.Close()
	served.Wait()
	mu.Lock()
	defer mu.Unlock()
	if hellos == 0 || afterHello != 0 {
		t.Fatalf("%d hellos, %d bytes after them", hellos, afterHello)
	}
}

// Review focus 1 (controller ruling 22): a state folder so deep that the
// keeper's socket path is too long answers a clear error at the first
// terminal, and at every one after, within moments. No keeper can run there,
// so none is taken as unusable and nothing retries.
func TestASocketPathTooLongAnswersAClearError(t *testing.T) {
	dir := shortTempDir(t)
	deep := filepath.Join(dir, strings.Repeat("a-deep-folder/", 10))
	if err := os.MkdirAll(deep, 0o700); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(deep, "state.json")
	if socket := keeper.SocketPath(statePath); len(socket) <= 103 {
		t.Fatalf("the socket path is only %d bytes", len(socket))
	}
	store := NewStore(statePath)
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: t.TempDir()}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	binary := hostBinary(t)
	t.Setenv("SHELL", "/bin/sh")
	t.Cleanup(func() {
		exec.Command(binary, "terminals", "stop", "--state", statePath).Run()
	})
	backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: filepath.Join(dir, "terminals.log"), Executable: binary, Version: "test"})
	host := NewWithOptions(store, &fakeAgent{}, HostOptions{TerminalEnabled: true, Terminals: backend})
	t.Cleanup(func() { host.Close() })
	token := paired(t, host, store)
	for _, label := range []string{"first create", "second create"} {
		began := time.Now()
		response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
		if took := time.Since(began); took > 5*time.Second {
			t.Fatalf("%s took %v", label, took)
		}
		wantRouteError(t, label, response, 500, "terminal_path_too_long", "AgentLand's terminal service can't start: its socket path is too long.")
	}
	if host.terminals.isUnusable() {
		t.Fatal("the keeper was taken as unusable")
	}
	if status := backend.Status(t.Context()); status != KeeperNone {
		t.Fatalf("status %v, want none", status)
	}
}
