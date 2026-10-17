package host

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// createTerminalFor starts a terminal of program through the route and returns
// its keeper id.
func createTerminalFor(t *testing.T, f *catalogFixture, program string) string {
	t.Helper()
	state, _ := f.store.Read()
	w := f.call("POST", "/v1/terminals", map[string]any{"projectId": state.Config.Projects[0].ID, "program": program, "rows": 24, "cols": 80})
	if w.Code != 201 {
		t.Fatalf("create %s: %d %s", program, w.Code, w.Body)
	}
	return f.terminals.latest()
}

func runningTerminalsOf(f *catalogFixture, program string) int {
	return len(f.host.runningTerminalVersions(program))
}

func TestClaudeNativeUpdatesWhileItsTerminalRuns(t *testing.T) {
	root := t.TempDir()
	versions := filepath.Join(root, "share", "claude", "versions")
	log := filepath.Join(root, "log")
	link := filepath.Join(root, "bin", "claude")
	body := "case \"$1:$2\" in\n" +
		"  update:--help) echo 'Usage: claude update|upgrade [options]';;\n" +
		"  update:) echo update >> '" + log + "'; cp '" + versions + "/1.0.0' '" + versions + "/1.0.1'; ln -s ../share/claude/versions/1.0.1 '" + link + ".new'; mv -f '" + link + ".new' '" + link + "';;\n" +
		"  *) exit 91;;\nesac\n"
	writeScript(t, filepath.Join(versions, "1.0.0"), body)
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../share/claude/versions/1.0.0", link); err != nil {
		t.Fatal(err)
	}
	f := newCatalogFixture(t, map[string]string{"claude": link}, nil)
	nativeTerminalFor(f)
	first := createTerminalFor(t, f, "claude")
	enableAutomaticFor(t, f)
	if !f.host.agents.updatesBesideRunning("claude") {
		t.Fatal("the versions layout was not recognized")
	}
	createTerminalFor(t, f, "claude")
	if data, _ := os.ReadFile(log); strings.Count(string(data), "update") != 1 {
		t.Fatalf("the update did not run once: %q", data)
	}
	if target, _ := os.Readlink(link); !strings.HasSuffix(target, "1.0.1") {
		t.Fatalf("link still points at %q", target)
	}
	if _, err := os.Stat(filepath.Join(versions, "1.0.0")); err != nil {
		t.Fatalf("the running version's folder is gone: %v", err)
	}
	f.terminals.mu.Lock()
	running := f.terminals.terminals[first].info.Running
	f.terminals.mu.Unlock()
	if !running || runningTerminalsOf(f, "claude") < 1 {
		t.Fatal("the first terminal stopped")
	}
	if agent := f.agent("claude"); agent.UpdateWaitingTerminals != 0 {
		t.Fatalf("waiting shown for an update that ran: %+v", agent)
	}
}

func TestUpdatesBesideRunningRules(t *testing.T) {
	root := t.TempDir()
	versionDir := filepath.Join(root, "versions")
	plain := writeScript(t, filepath.Join(root, "plain", "codex"), "exit 0")
	real := writeScript(t, filepath.Join(versionDir, "2.0.0"), "exit 0")
	absolute := filepath.Join(root, "bin", "claude")
	os.MkdirAll(filepath.Dir(absolute), 0o700)
	if err := os.Symlink(real, absolute); err != nil {
		t.Fatal(err)
	}
	elsewhere := filepath.Join(root, "bin", "codex")
	if err := os.Symlink(plain, elsewhere); err != nil {
		t.Fatal(err)
	}
	f := newCatalogFixture(t, map[string]string{"claude": absolute, "codex": elsewhere}, nil)
	catalog := f.host.agents
	if !catalog.updatesBesideRunning("claude") {
		t.Error("absolute link into a versions folder")
	}
	if catalog.updatesBesideRunning("codex") {
		t.Error("link to a plain folder")
	}
	catalog.lookup = func(string) (string, bool) { return plain, true }
	if catalog.updatesBesideRunning("codex") {
		t.Error("plain file")
	}
	catalog.lookup = func(string) (string, bool) { return filepath.Join(root, "missing"), true }
	if catalog.updatesBesideRunning("claude") {
		t.Error("missing path")
	}
	catalog.lookup = func(string) (string, bool) { return "", false }
	if catalog.updatesBesideRunning("claude") || catalog.updatesBesideRunning("goose") {
		t.Error("unknown command or agent")
	}
}

func TestInPlaceUpdaterWaitsAndSaysSo(t *testing.T) {
	command, log := localUpdaterFixture(t, "touch \"$0\"")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	nativeTerminalFor(f)
	f.host.agents.idlePoll, f.host.agents.every = 5*time.Millisecond, 50*time.Millisecond
	id := createTerminalFor(t, f, "codex")
	enableAutomaticFor(t, f)
	if f.host.agents.updatesBesideRunning("codex") {
		t.Fatal("a plain file updates beside nothing")
	}
	f.host.agents.updateRun()
	if data, _ := os.ReadFile(log); strings.Contains(string(data), "update\n") {
		t.Fatalf("updated under a running terminal: %q", data)
	}
	if agent := f.agent("codex"); agent.UpdateWaitingTerminals != 1 {
		t.Fatalf("waiting count: %+v", agent)
	}
	f.terminals.exit(id, 0)
	waitFor(t, "the terminal to end", func() bool { return runningTerminalsOf(f, "codex") == 0 })
	if agent := f.agent("codex"); agent.UpdateWaitingTerminals != 0 {
		t.Fatalf("waiting stuck after the terminal ended: %+v", agent)
	}
	f.host.agents.mu.Lock()
	stuck := f.host.agents.deferred["codex"]
	f.host.agents.mu.Unlock()
	if stuck {
		t.Fatal("deferred flag stuck")
	}
}

func installFakeGoose(t *testing.T, f *catalogFixture, version string) {
	t.Helper()
	archive := f.fakeAgentArchive()
	f.registry.setFile("/goose.tar.gz", archive)
	f.registry.setAgents(f.fakeAgentEntry("goose", version, "/goose.tar.gz", sha256Hex(archive)))
}

func TestRegistryUpdateKeepsVersionsRunningTerminalsUse(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	enableAutomaticFor(t, f)
	installFakeGoose(t, f, "1.0.0")
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 202 {
		t.Fatalf("install: %d", w.Code)
	}
	f.waitSettled("goose")
	id := createTerminalFor(t, f, "goose")
	store := f.host.agents.store
	for _, version := range []string{"2.0.0", "3.0.0"} {
		installFakeGoose(t, f, version)
		f.host.agents.updateRun()
		if current, _ := store.readCurrent("goose"); current == nil || current.Version != version {
			t.Fatalf("update to %s did not run beside the terminal: %+v", version, current)
		}
	}
	if _, err := os.Stat(store.versionDir("goose", "1.0.0")); err != nil {
		t.Fatalf("the running terminal's version was pruned: %v", err)
	}
	f.terminals.exit(id, 0)
	waitFor(t, "the terminal to end", func() bool { return runningTerminalsOf(f, "goose") == 0 })
	installFakeGoose(t, f, "4.0.0")
	f.host.agents.updateRun()
	if _, err := os.Stat(store.versionDir("goose", "1.0.0")); !os.IsNotExist(err) {
		t.Fatalf("the unused version was kept: %v", err)
	}
}

func TestUninstallStillWaitsForTerminals(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	installFakeGoose(t, f, "1.0.0")
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 202 {
		t.Fatalf("install: %d", w.Code)
	}
	f.waitSettled("goose")
	createTerminalFor(t, f, "goose")
	w := f.call("POST", "/v1/agents/uninstall", map[string]any{"id": "goose"})
	if w.Code != 409 {
		t.Fatalf("uninstall under a terminal: %d %s", w.Code, w.Body)
	}
	if current, _ := f.host.agents.store.readCurrent("goose"); current == nil {
		t.Fatal("the agent was removed")
	}
}

// putVersions makes the agent's version folders and records current (with
// previous) as installed.
func putVersions(t *testing.T, f *catalogFixture, id string, versions ...string) {
	t.Helper()
	for _, version := range versions {
		if err := os.MkdirAll(f.host.agents.store.versionDir(id, version), 0o700); err != nil {
			t.Fatal(err)
		}
	}
}

// installedAs is an agentCurrent whose command is a real file in the version's folder.
func installedAs(t *testing.T, f *catalogFixture, id, version string) agentCurrent {
	t.Helper()
	putVersions(t, f, id, version)
	command := writeScript(t, filepath.Join(f.host.agents.store.versionDir(id, version), "agent"), "exit 0")
	return agentCurrent{Version: version, Command: command, Args: []string{"acp"}, Kind: "binary"}
}

func switchTo(t *testing.T, f *catalogFixture, id, version string, previous string) {
	t.Helper()
	current := installedAs(t, f, id, version)
	if previous != "" {
		kept := installedAs(t, f, id, previous)
		current.Previous = &kept
	}
	if err := f.host.agents.makeCurrent(f.host.agents.ctx, id, current); err != nil {
		t.Fatal(err)
	}
}

func hasVersion(f *catalogFixture, id, version string) bool {
	_, err := os.Stat(f.host.agents.store.versionDir(id, version))
	return err == nil
}

func TestOpenCodeTerminalRecordsItsVersionAndKeepsItsFolder(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	if err := f.host.agents.store.writeCurrent("opencode", installedAs(t, f, "opencode", "1.0.0")); err != nil {
		t.Fatal(err)
	}
	f.host.agents.runningOpenCode = func() string { return "" }
	f.host.terminals.launcher.resolve = func(name string) (string, bool) { return "/bin/" + name, true }
	id := createTerminalFor(t, f, "opencode")
	f.host.terminals.mu.Lock()
	entry := f.host.terminals.entries[id]
	f.host.terminals.mu.Unlock()
	entry.mu.Lock()
	version := entry.meta.Version
	entry.mu.Unlock()
	if version != "1.0.0" {
		t.Fatalf("terminal version %q", version)
	}
	switchTo(t, f, "opencode", "2.0.0", "1.0.0")
	switchTo(t, f, "opencode", "3.0.0", "2.0.0")
	if !hasVersion(f, "opencode", "1.0.0") {
		t.Fatal("the running terminal's version was pruned")
	}
	f.terminals.exit(id, 0)
	waitFor(t, "the terminal to end", func() bool { return runningTerminalsOf(f, "opencode") == 0 })
	switchTo(t, f, "opencode", "4.0.0", "3.0.0")
	if hasVersion(f, "opencode", "1.0.0") || hasVersion(f, "opencode", "2.0.0") {
		t.Fatal("unused versions were kept")
	}
}

func TestRunningTerminalWithoutAVersionKeepsEveryVersion(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	installFakeGoose(t, f, "1.0.0")
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 202 {
		t.Fatalf("install: %d", w.Code)
	}
	f.waitSettled("goose")
	id := createTerminalFor(t, f, "goose")
	f.host.terminals.mu.Lock()
	entry := f.host.terminals.entries[id]
	f.host.terminals.mu.Unlock()
	entry.mu.Lock()
	entry.meta.Version = ""
	entry.mu.Unlock()
	switchTo(t, f, "goose", "2.0.0", "1.0.0")
	switchTo(t, f, "goose", "3.0.0", "2.0.0")
	switchTo(t, f, "goose", "4.0.0", "3.0.0")
	if !hasVersion(f, "goose", "1.0.0") || !hasVersion(f, "goose", "2.0.0") {
		t.Fatal("a terminal of unknown version lost its folder")
	}
}

func TestAnUnreadableKeeperBlocksUpdatesAndPruning(t *testing.T) {
	command, log := localUpdaterFixture(t, "touch \"$0\"")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	f.answerInitialize()
	nativeTerminalFor(f)
	f.host.agents.idlePoll, f.host.agents.every = 5*time.Millisecond, 30*time.Millisecond
	createTerminalFor(t, f, "codex")
	switchTo(t, f, "goose", "1.0.0", "")
	enableAutomaticFor(t, f)
	// A host that starts with an unusable keeper has no terminal entries.
	f.terminals.setStatus(KeeperUnusable)
	f.host.terminals.mu.Lock()
	f.host.terminals.entries = map[string]*terminalEntry{}
	f.host.terminals.mu.Unlock()
	f.host.restoreTerminals(context.Background())
	if !f.host.terminals.isUnusable() {
		t.Fatal("keeper not unusable")
	}
	f.host.agents.updateRun()
	if data, _ := os.ReadFile(log); strings.Contains(string(data), "update\n") {
		t.Fatalf("updated under the keeper's terminals: %q", data)
	}
	switchTo(t, f, "goose", "2.0.0", "1.0.0")
	switchTo(t, f, "goose", "3.0.0", "2.0.0")
	if !hasVersion(f, "goose", "1.0.0") {
		t.Fatal("pruned while the keeper was unreadable")
	}
	f.terminals.setStatus(KeeperNone)
	f.host.restoreTerminals(context.Background())
	if f.host.terminals.isUnusable() || f.host.agentBusyForUpdate("codex") {
		t.Fatal("still blocked after recovery")
	}
	switchTo(t, f, "goose", "4.0.0", "3.0.0")
	if hasVersion(f, "goose", "1.0.0") {
		t.Fatal("pruning did not resume")
	}
}

func TestUnsupportedUpdaterNeverShowsAWait(t *testing.T) {
	dir := t.TempDir()
	command := writeScript(t, filepath.Join(dir, "codex"), "case \"$1:$2\" in\n  --version:) echo 0.1.0;;\n  update:--help) exit 2;;\n  *) exit 91;;\nesac\n")
	f := newCatalogFixture(t, map[string]string{"codex": command}, map[string]string{command: "0.1.0"})
	nativeTerminalFor(f)
	createTerminalFor(t, f, "codex")
	enableAutomaticFor(t, f)
	_, notice, err := f.host.agents.prepareTerminal(context.Background(), "codex")
	if err != nil || !strings.Contains(notice, "deferred") {
		t.Fatalf("prepare: %q %v", notice, err)
	}
	f.host.agents.mu.Lock()
	marked := f.host.agents.deferred["codex"]
	f.host.agents.mu.Unlock()
	if marked || f.agent("codex").UpdateWaitingTerminals != 0 {
		t.Fatal("a wait is shown for an update that will never run")
	}
}
