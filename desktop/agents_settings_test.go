package host

import (
	"agentland/host/keeper"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// updatingTerminalFixture finds Codex and Claude Code where the catalog
// does, and shows beforeStart each spawn's command.
type updatingTerminalFixture struct {
	*terminalFixture
	beforeStart func(string)
}

func nativeTerminalFor(f *catalogFixture) *updatingTerminalFixture {
	backend := &updatingTerminalFixture{terminalFixture: f.terminals}
	f.host.terminals.launcher.resolve = func(name string) (string, bool) {
		if name != "codex" && name != "claude" {
			return "", false
		}
		return f.host.agents.lookup(name)
	}
	f.terminals.mu.Lock()
	f.terminals.beforeSpawn = func(request keeper.SpawnRequest) {
		if backend.beforeStart != nil {
			backend.beforeStart(request.Path)
		}
	}
	f.terminals.mu.Unlock()
	return backend
}
func enableAutomaticFor(t *testing.T, f *catalogFixture) {
	t.Helper()
	if err := f.store.update(func(s *State) error { s.AutomaticUpdates = true; return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestAutomaticAgentSettingsPersistAndPreserveConfiguration(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	before, _ := f.store.Read()
	w := f.call("GET", "/v1/agents", nil)
	var answer map[string]any
	json.Unmarshal(w.Body.Bytes(), &answer)
	if answer["automaticUpdates"] != false {
		t.Fatalf("default: %s", w.Body)
	}
	for _, body := range []any{map[string]any{}, map[string]any{"automaticUpdates": "yes"}, map[string]any{"automaticUpdates": nil}} {
		if w := f.call("POST", "/v1/agents/settings", body); w.Code != 400 {
			t.Fatalf("invalid: %d %s", w.Code, w.Body)
		}
	}
	if w := request(t, f.host.Handler(), "POST", "/v1/agents/settings", "", map[string]any{"automaticUpdates": true}); w.Code != 401 {
		t.Fatalf("auth: %d", w.Code)
	}
	if w := f.call("POST", "/v1/agents/settings", map[string]any{"automaticUpdates": true}); w.Code != 200 {
		t.Fatalf("set: %d %s", w.Code, w.Body)
	}
	after, _ := NewStore(f.store.Path).Read()
	if !after.AutomaticUpdates || after.Config.OpenCodeURL != before.Config.OpenCodeURL || len(after.Devices) != len(before.Devices) || after.Devices[0].TokenHash != before.Devices[0].TokenHash {
		t.Fatalf("state not preserved: %+v", after)
	}
	if err := f.store.UpdateConfig(before.Config); err != nil {
		t.Fatal(err)
	}
	after, _ = f.store.Read()
	if !after.AutomaticUpdates {
		t.Fatal("configuration replacement lost policy")
	}
}

// An update before a launch never keeps the terminal from starting (owner,
// 2026-10-17): a failed one starts the installed version with a notice, and a
// slow one in place (a plain Codex file) is stopped, its process group
// ended, before the installed version starts. Nothing of the updater's
// output reaches the answer or the log.
func TestTerminalPreLaunchUpdateNeverRefusesALaunch(t *testing.T) {
	for _, tc := range []struct {
		name, body, notice, logged string
		enabled                    bool
		wait                       time.Duration
	}{
		{"off", "exit 7", "", "", false, 0},
		{"success", "echo ready > READY", "", "agents: codex update (pre-launch): 1.0.0 → 1.0.0, already current", true, 0},
		{"failure", "echo token=secret >&2; exit 7", "Couldn't update Codex; started the installed version.",
			"agents: codex update (pre-launch): 1.0.0 → 1.0.0, failed: the updater failed (exit 7)", true, 0},
		{"slow", "echo $$ > PID; sleep 30", "Couldn't update Codex in time; started the installed version.",
			"agents: codex update (pre-launch): 1.0.0 → 1.0.0, failed: it took too long and was stopped so a terminal could start", true, time.Second},
	} {
		t.Run(tc.name, func(t *testing.T) {
			folder := t.TempDir()
			body := strings.ReplaceAll(strings.ReplaceAll(tc.body, "READY", "'"+filepath.Join(folder, "ready")+"'"), "PID", "'"+filepath.Join(folder, "pid")+"'")
			command, log := localUpdaterFixture(t, body)
			f := newCatalogFixture(t, map[string]string{"codex": command}, map[string]string{command: "1.0.0"})
			logged := captureUpdateLog(f.host.agents)
			nativeTerminalFor(f)
			if tc.enabled {
				if w := f.call("POST", "/v1/agents/settings", map[string]any{"automaticUpdates": true}); w.Code != 200 {
					t.Fatalf("settings: %d", w.Code)
				}
			}
			if tc.wait > 0 {
				f.host.agents.terminalUpdateWait = tc.wait
			}
			state, _ := f.store.Read()
			started := time.Now()
			w := f.call("POST", "/v1/terminals", map[string]any{"projectId": state.Config.Projects[0].ID, "program": "codex", "rows": 24, "cols": 80})
			if w.Code != 201 || f.terminals.spawnCount() != 1 || f.terminals.lastSpawn().Path != command {
				t.Fatalf("create: %d %s, starts=%d", w.Code, w.Body, f.terminals.spawnCount())
			}
			if time.Since(started) > 10*time.Second {
				t.Fatal("the launch waited out a slow update")
			}
			var created TerminalInfo
			if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.UpdateNotice != tc.notice {
				t.Fatalf("notice: %q, want %q (%v)", created.UpdateNotice, tc.notice, err)
			}
			data, _ := os.ReadFile(log)
			if tc.enabled && strings.Count(string(data), "update\n") != 1 {
				t.Fatalf("the updater did not run once: %q", data)
			}
			if !tc.enabled && strings.Contains(string(data), "update") {
				t.Fatalf("off invoked updater: %s", data)
			}
			if tc.logged != "" {
				logged.waitFor(t, tc.logged)
			}
			if lines := logged.text(); strings.Contains(w.Body.String()+lines, "secret") || strings.Contains(lines, folder) || (!tc.enabled && lines != "") {
				t.Fatalf("answer or log: %s\n%s", w.Body, lines)
			}
		})
	}
}

func TestTerminalPreparationJoinsUpdateResolvesReplacementAndDefersBusy(t *testing.T) {
	releaseFile := filepath.Join(t.TempDir(), "release")
	command, log := localUpdaterFixture(t, "while test ! -e '"+releaseFile+"'; do sleep 0.01; done")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	backend := nativeTerminalFor(f)
	replacement := writeScript(t, filepath.Join(t.TempDir(), "codex"), "exit 0")
	var replaced atomic.Bool
	f.host.agents.lookup = func(id string) (string, bool) {
		if id != "codex" {
			return "", false
		}
		if replaced.Load() {
			return replacement, true
		}
		return command, true
	}
	backend.beforeStart = func(path string) {
		if path != replacement {
			t.Errorf("launch resolved old executable: %s", path)
		}
	}
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"}); w.Code != 202 {
		t.Fatalf("update: %d", w.Code)
	}
	waitFor(t, "updater began", func() bool { b, _ := os.ReadFile(log); return strings.Contains(string(b), "update") })
	state, _ := f.store.Read()
	done := make(chan int, 1)
	go func() {
		w := f.call("POST", "/v1/terminals", map[string]any{"projectId": state.Config.Projects[0].ID, "program": "codex", "rows": 24, "cols": 80})
		done <- w.Code
	}()
	replaced.Store(true)
	os.WriteFile(releaseFile, nil, 0600)
	select {
	case code := <-done:
		if code != 201 {
			t.Fatalf("create: %d", code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("launch did not finish")
	}
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "update") != 1 {
		t.Fatalf("duplicate update: %s", data)
	}
	backend.beforeStart = nil
	w := f.call("POST", "/v1/terminals", map[string]any{"projectId": state.Config.Projects[0].ID, "program": "codex", "rows": 24, "cols": 80})
	if w.Code != 201 || !strings.Contains(w.Body.String(), "deferred") {
		t.Fatalf("busy: %d %s", w.Code, w.Body)
	}
	if len(f.host.terminals.entries) != 2 {
		t.Fatal("existing terminal changed")
	}
}

func TestTerminalPreparationCancellationAndShellDoNotUpdate(t *testing.T) {
	command, log := localUpdaterFixture(t, "sleep 30")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := f.host.agents.prepareTerminal(ctx, "codex"); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel: %v", err)
	}
	release, _, err := f.host.agents.prepareTerminal(ctx, "shell")
	if err != nil {
		t.Fatal(err)
	}
	release()
	data, _ := os.ReadFile(log)
	if strings.Contains(string(data), "update") {
		t.Fatalf("unexpected updater: %s", data)
	}
}

func TestTerminalPreparationCancelsWhileProbeBusy(t *testing.T) {
	command, _ := localUpdaterFixture(t, "exit 0")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	f.host.agents.updaterGate <- struct{}{}
	defer func() { <-f.host.agents.updaterGate }()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, _, err := f.host.agents.prepareTerminal(ctx, "codex"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("probe wait: %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("probe wait ignored cancellation")
	}
}

func TestManagedTerminalFetchesFreshRegistryAndOffLeavesVersions(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	archive := f.fakeAgentArchive()
	f.registry.setFile("/goose.tar.gz", archive)
	f.registry.setAgents(f.fakeAgentEntry("goose", "1.0.0", "/goose.tar.gz", sha256Hex(archive)))
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 202 {
		t.Fatalf("install: %d", w.Code)
	}
	f.waitSettled("goose")
	f.registry.setAgents(f.fakeAgentEntry("goose", "2.0.0", "/goose.tar.gz", sha256Hex(archive)))
	f.host.agents.updateRun()
	current, _ := f.host.agents.store.readCurrent("goose")
	if current.Version != "1.0.0" {
		t.Fatalf("off updated: %s", current.Version)
	}
	enableAutomaticFor(t, f)
	clock := &testClock{now: time.Now()}
	f.host.agents.now = clock.Now
	installed, _ := f.host.agents.store.readCurrent("goose")
	// A failed update starts the installed version, with a notice.
	f.registry.setAgents(f.fakeAgentEntry("goose", "2.0.0", "/goose.tar.gz", strings.Repeat("0", 64)))
	notice := launchNotice(t, f, "goose")
	current, _ = f.host.agents.store.readCurrent("goose")
	if notice != "Couldn't update Fake goose; started the installed version." || current.Version != "1.0.0" || f.terminals.spawnCount() != 1 || f.terminals.lastSpawn().Path != installed.Command {
		t.Fatalf("failed update changed current or started nothing: %q %+v starts=%d", notice, current, f.terminals.spawnCount())
	}
	// An hour later the next launch updates first and starts the new version.
	clock.Advance(time.Hour)
	f.registry.setAgents(f.fakeAgentEntry("goose", "2.0.0", "/goose.tar.gz", sha256Hex(archive)))
	if notice := launchNotice(t, f, "goose"); notice != "" {
		t.Fatalf("notice: %q", notice)
	}
	current, _ = f.host.agents.store.readCurrent("goose")
	if current.Version != "2.0.0" || f.terminals.spawnCount() != 2 || f.terminals.lastSpawn().Path != current.Command {
		t.Fatalf("launch did not use new install: %+v %d", current, f.terminals.spawnCount())
	}
}

func TestNativeBackgroundUpdateIsOffByDefault(t *testing.T) {
	command, log := localUpdaterFixture(t, "exit 7")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	f.host.agents.updateRun()
	if b, _ := os.ReadFile(log); strings.Contains(string(b), "update") {
		t.Fatalf("background updated by default: %s", b)
	}
	agent := f.agent("codex")
	if !agent.SupportsUpdates || agent.AutoUpdates {
		t.Fatalf("capability versus policy: %+v", agent)
	}
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"}); w.Code != 202 {
		t.Fatalf("manual off: %d", w.Code)
	}
	f.waitSettled("codex")
	if b, _ := os.ReadFile(log); strings.Count(string(b), "update") != 1 {
		t.Fatalf("manual did not update: %s", b)
	}
}

func TestJoinedRegistryRefreshPropagatesFailureAndCancellation(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	unblock := f.registry.holdPath("/registry.json")
	f.registry.mu.Lock()
	f.registry.status["/registry.json"] = 503
	f.registry.mu.Unlock()
	first := make(chan error, 1)
	go func() { first <- f.host.agents.refresh(context.Background()) }()
	waitFor(t, "registry request", func() bool { return f.registry.hitsOf("/registry.json") > 0 })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := f.host.agents.refresh(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("joined canceled refresh: %v", err)
	}
	joined := make(chan error, 1)
	go func() { joined <- f.host.agents.refresh(context.Background()) }()
	// Both requests share the in-progress fetch; failure must never be success.
	unblock()
	if err := <-first; err == nil {
		t.Fatal("first refresh unexpectedly succeeded")
	}
	if err := <-joined; err == nil {
		t.Fatal("joined failed refresh reported success")
	}
}

func TestAgentPreparationHTTPSOutlivesListenerWriteTimeout(t *testing.T) {
	command, _ := localUpdaterFixture(t, "sleep 0.2")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	nativeTerminalFor(f)
	state, _ := f.store.Read()
	server := httptest.NewUnstartedServer(f.host.Handler())
	server.Config.WriteTimeout = 40 * time.Millisecond
	server.Config.ReadTimeout = 40 * time.Millisecond
	server.StartTLS()
	defer server.Close()
	body, _ := json.Marshal(map[string]any{"projectId": state.Config.Projects[0].ID, "program": "codex", "rows": 24, "cols": 80})
	req, _ := http.NewRequest("POST", server.URL+"/v1/terminals", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+f.token)
	req.Header.Set("Content-Type", "application/json")
	client := server.Client()
	client.Timeout = 5 * time.Second
	response, err := client.Do(req)
	if err != nil {
		t.Fatalf("lost terminal creation response during preparation: %v", err)
	}
	defer response.Body.Close()
	data, _ := io.ReadAll(response.Body)
	if response.StatusCode != 201 {
		t.Fatalf("response: %d %s", response.StatusCode, data)
	}
}

func TestAgentPreparationRequestCancelAndShutdownCreateNoPTY(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(fmt.Sprint(shutdown), func(t *testing.T) {
			command, log := localUpdaterFixture(t, "sleep 30")
			f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
			enableAutomaticFor(t, f)
			nativeTerminalFor(f)
			state, _ := f.store.Read()
			body, _ := json.Marshal(map[string]any{"projectId": state.Config.Projects[0].ID, "program": "codex", "rows": 24, "cols": 80})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			req := httptest.NewRequest("POST", "/v1/terminals", bytes.NewReader(body)).WithContext(ctx)
			req.Header.Set("Authorization", "Bearer "+f.token)
			response := httptest.NewRecorder()
			done := make(chan struct{})
			go func() { defer close(done); f.host.Handler().ServeHTTP(response, req) }()
			waitFor(t, "running updater", func() bool { b, _ := os.ReadFile(log); return strings.Contains(string(b), "update") })
			if shutdown {
				f.host.BeginShutdown()
			} else {
				cancel()
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("preparation did not cancel")
			}
			// The host stopping says so; a request that ended gets no answer.
			if f.terminals.spawnCount() != 0 || (shutdown && response.Code != 503) || (!shutdown && response.Code == 201) {
				t.Fatalf("canceled preparation: starts=%d status=%d", f.terminals.spawnCount(), response.Code)
			}
		})
	}
}
