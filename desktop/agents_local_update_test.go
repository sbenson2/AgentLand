package host

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// localUpdaterFixture is a fake Codex executable. It has no model behavior:
// only --version, update --help and update are accepted.
func localUpdaterFixture(t *testing.T, updateBody string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	version := filepath.Join(dir, "version")
	log := filepath.Join(dir, "log")
	if err := os.WriteFile(version, []byte("1.0.0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script := "case \"$1:$2\" in\n" +
		"  --version:) cat '" + version + "';;\n" +
		"  update:--help) echo help >> '" + log + "'; echo 'Usage: codex update';;\n" +
		"  update:) echo update >> '" + log + "'; " + updateBody + ";;\n" +
		"  *) exit 91;;\n" +
		"esac\n"
	return writeScript(t, filepath.Join(dir, "codex"), script), log
}

func TestLocalNativeUpdaterCapabilityAndManualUpdate(t *testing.T) {
	command, log := localUpdaterFixture(t, "test -z \"$AGENTLAND_SECRET_PROBE\" || exit 92; echo 2.0.0 > '"+filepath.Join(t.TempDir(), "unused")+"'")
	// Give the fake an update whose version change is tied to its own identity,
	// as a real self-updater's replacement is.
	version := filepath.Join(filepath.Dir(command), "version")
	if err := os.WriteFile(command, []byte("#!/bin/sh\ncase \"$1:$2\" in\n  --version:) cat '"+version+"';;\n  update:--help) echo help >> '"+log+"'; echo 'Usage: codex update';;\n  update:) test -z \"$AGENTLAND_SECRET_PROBE\" || exit 92; echo update >> '"+log+"'; echo 2.0.0 > '"+version+"'; touch \"$0\";;\n  *) exit 91;;\nesac\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	f.host.agents.versionOf = func(path string) string { return runAgentVersion(path, f.host.agents.baseEnv) }

	agent := f.agent("codex")
	if !agent.AutoUpdates || agent.Source != "local" || agent.InstalledVersion != "1.0.0" {
		t.Fatalf("before update: %+v", agent)
	}
	_ = f.agent("codex")
	if data, _ := os.ReadFile(log); strings.Count(string(data), "help") != 1 {
		t.Fatalf("support probe was not cached by executable identity: %q", data)
	}

	w := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"})
	if w.Code != 202 || !strings.Contains(w.Body.String(), `"state":"updating"`) {
		t.Fatalf("update: %d %s", w.Code, w.Body)
	}
	agent = f.waitSettled("codex")
	if agent.State != "installed" || agent.InstalledVersion != "2.0.0" || agent.UpdatedAt == "" || agent.LastError != "" || !agent.AutoUpdates {
		t.Fatalf("after update: %+v", agent)
	}
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "update") != 1 {
		t.Fatalf("updater invocations: %q", data)
	}
	for _, path := range []string{"/v1/agents/install", "/v1/agents/uninstall"} {
		if refused := f.call("POST", path, map[string]any{"id": "codex"}); refused.Code != 409 || !strings.Contains(refused.Body.String(), `"code":"not_managed"`) {
			t.Fatalf("%s: %d %s", path, refused.Code, refused.Body)
		}
	}
}

func TestUnsupportedLocalUpdaterIsNeverInvoked(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "bare-update-ran")
	command := writeScript(t, filepath.Join(dir, "codex"), "case \"$1:$2\" in\n  --version:) echo 0.1.0;;\n  update:--help) exit 2;;\n  update:) touch '"+marker+"';;\n  *) exit 91;;\nesac\n")
	f := newCatalogFixture(t, map[string]string{"codex": command}, map[string]string{command: "0.1.0"})
	enableAutomaticFor(t, f)
	agent := f.agent("codex")
	if agent.AutoUpdates {
		t.Fatalf("unsupported updater advertised: %+v", agent)
	}
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"}); w.Code != 409 || !strings.Contains(w.Body.String(), `"code":"not_managed"`) {
		t.Fatalf("unsupported update: %d %s", w.Code, w.Body)
	}
	f.host.agents.updateRun()
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unsupported updater was invoked: %v", err)
	}
}

func TestGenericHelpDoesNotEnableLocalUpdater(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "bare-update-ran")
	command := writeScript(t, filepath.Join(dir, "codex"), "case \"$1:$2\" in\n  --version:) echo 0.1.0;;\n  update:--help) echo 'Usage: codex [OPTIONS] [PROMPT]' ;;\n  update:) touch '"+marker+"';;\n  *) exit 91;;\nesac\n")
	f := newCatalogFixture(t, map[string]string{"codex": command}, map[string]string{command: "0.1.0"})
	if agent := f.agent("codex"); agent.AutoUpdates {
		t.Fatalf("global help advertised an updater: %+v", agent)
	}
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"}); w.Code != 409 {
		t.Fatalf("generic-help update: %d %s", w.Code, w.Body)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("generic-help command ran bare update: %v", err)
	}
}

func TestClaudeUpdaterOptOutIsHonored(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	command := writeScript(t, filepath.Join(dir, "claude"), "case \"$1:$2\" in\n  update:--help) echo help >> '"+log+"'; echo 'Usage: claude update|upgrade [options]' ;;\n  update:) echo update >> '"+log+"';;\n  *) exit 91;;\nesac\n")
	f := newCatalogFixture(t, map[string]string{"claude": command}, nil)
	enableAutomaticFor(t, f)
	f.host.agents.baseEnv = append(f.host.agents.baseEnv, "DISABLE_AUTOUPDATER=1")
	if agent := f.agent("claude"); agent.AutoUpdates {
		t.Fatalf("opted-out updater advertised: %+v", agent)
	}
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "claude"}); w.Code != 409 {
		t.Fatalf("opted-out update: %d %s", w.Code, w.Body)
	}
	f.host.agents.updateRun()
	if data, _ := os.ReadFile(log); len(data) != 0 {
		t.Fatalf("opted-out updater was probed or run: %q", data)
	}
}

func TestClaudeUpdateAliasHelpEnablesUpdater(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	command := writeScript(t, filepath.Join(dir, "claude"), "case \"$1:$2\" in\n  update:--help) echo help >> '"+log+"'; echo 'Usage: claude update|upgrade [options]' ;;\n  update:) echo update >> '"+log+"';;\n  *) exit 91;;\nesac\n")
	catalog := newAgentCatalog(nil, filepath.Join(t.TempDir(), "state"), AgentOptions{})
	quietAgents(catalog, map[string]string{"claude": command}, nil, nil)
	if !catalog.localUpdaterSupported("claude", command) {
		t.Fatal("Claude's update|upgrade usage was not recognized")
	}
	if err := catalog.runLocalUpdater(context.Background(), "claude", command); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(log); string(data) != "help\nupdate\n" {
		t.Fatalf("Claude updater calls: %q", data)
	}
}

func TestCapabilitiesDoNotProbeNativeUpdaters(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	command := writeScript(t, filepath.Join(dir, "codex"), "echo called >> '"+log+"'; echo 'Usage: codex update'\n")
	catalog := newAgentCatalog(nil, filepath.Join(t.TempDir(), "state"), AgentOptions{})
	quietAgents(catalog, map[string]string{"codex": command}, nil, nil)
	catalog.capabilityLists()
	if data, _ := os.ReadFile(log); len(data) != 0 {
		t.Fatalf("capabilities ran the local CLI: %q", data)
	}
}

func TestLocalVersionCacheFollowsSymlinkRetarget(t *testing.T) {
	dir := t.TempDir()
	first := writeScript(t, filepath.Join(dir, "codex-one"), "echo one\n")
	second := writeScript(t, filepath.Join(dir, "codex-two"), "echo two\n")
	at := time.Unix(1_700_000_000, 0)
	for _, path := range []string{first, second} {
		if err := os.Chtimes(path, at, at); err != nil {
			t.Fatal(err)
		}
	}
	command := filepath.Join(dir, "codex")
	if err := os.Symlink(first, command); err != nil {
		t.Fatal(err)
	}
	catalog := newAgentCatalog(nil, filepath.Join(t.TempDir(), "state"), AgentOptions{})
	catalog.versionOf = func(path string) string {
		resolved, _ := filepath.EvalSymlinks(path)
		if filepath.Base(resolved) == filepath.Base(first) {
			return "1.0.0"
		}
		return "2.0.0"
	}
	if got := catalog.localVersion(command, "codex", true); got != "1.0.0" {
		t.Fatalf("first version %q", got)
	}
	replacement := filepath.Join(dir, "next")
	if err := os.Symlink(second, replacement); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, command); err != nil {
		t.Fatal(err)
	}
	if got := catalog.localVersion(command, "codex", true); got != "2.0.0" {
		t.Fatalf("retargeted version %q", got)
	}
}

func TestScheduledLocalUpdateWaitsForIdleAndIgnoresRegistryFailure(t *testing.T) {
	command, log := localUpdaterFixture(t, "touch \"$0\"")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	var busy atomic.Bool
	busy.Store(true)
	f.host.agents.agentBusyFor = func(id string) bool { return id == "codex" && busy.Load() }
	f.host.agents.idlePoll = 10 * time.Millisecond
	f.host.agents.every = time.Second
	done := make(chan struct{})
	go func() {
		defer close(done)
		f.host.agents.updateRun()
	}()
	time.Sleep(40 * time.Millisecond)
	if data, _ := os.ReadFile(log); strings.Contains(string(data), "update") {
		t.Fatalf("updated while busy: %q", data)
	}
	busy.Store(false)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("scheduled local update did not finish")
	}
	if data, _ := os.ReadFile(log); strings.Count(string(data), "update") != 1 {
		t.Fatalf("scheduled updater invocations: %q", data)
	}
}

func TestLocalUpdaterFailureIsBoundedAndDoesNotExposeOutput(t *testing.T) {
	dir := t.TempDir()
	release := filepath.Join(dir, "release")
	command, log := localUpdaterFixture(t, "while test ! -e '"+release+"'; do sleep 0.01; done; echo 'token=very-secret' >&2; exit 7")
	f := newCatalogFixture(t, map[string]string{"codex": command}, map[string]string{command: "1.0.0"})
	w := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"})
	if w.Code != 202 {
		t.Fatalf("update: %d %s", w.Code, w.Body)
	}
	waitFor(t, "the first updater to start", func() bool {
		data, _ := os.ReadFile(log)
		return strings.Count(string(data), "update") == 1
	})
	// A duplicate request joins the existing operation instead of starting a
	// second updater.
	if again := f.call("POST", "/v1/agents/update", map[string]any{"id": "codex"}); again.Code != 202 {
		t.Fatalf("duplicate update: %d %s", again.Code, again.Body)
	}
	if err := os.WriteFile(release, []byte("go"), 0o600); err != nil {
		t.Fatal(err)
	}
	agent := f.waitSettled("codex")
	if !strings.Contains(agent.LastError, "updater failed") || strings.Contains(agent.LastError, "very-secret") || agent.UpdatedAt != "" {
		t.Fatalf("failure: %+v", agent)
	}
	if data, _ := os.ReadFile(log); strings.Count(string(data), "update") != 1 {
		t.Fatalf("parallel updater invocations: %q", data)
	}
}

func TestLocalUpdaterCancellationEndsItsProcessGroup(t *testing.T) {
	command, _ := localUpdaterFixture(t, "sleep 30")
	catalog := newAgentCatalog(nil, filepath.Join(t.TempDir(), "state"), AgentOptions{})
	quietAgents(catalog, map[string]string{"codex": command}, map[string]string{command: "1.0.0"}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- catalog.runLocalUpdater(ctx, "codex", command) }()
	log := filepath.Join(filepath.Dir(command), "log")
	waitFor(t, "the updater to start before cancellation", func() bool {
		data, _ := os.ReadFile(log)
		return strings.Contains(string(data), "update")
	})
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancel: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not end the updater")
	}
}

func TestAgentJSONAutoUpdatesIsOptional(t *testing.T) {
	data, err := json.Marshal(agentJSON{ID: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "autoUpdates") {
		t.Fatalf("false autoUpdates must be absent: %s", data)
	}
}
