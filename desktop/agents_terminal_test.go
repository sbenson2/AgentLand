package host

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// updateLog keeps the update log's lines (agentCatalog.logf).
type updateLog struct {
	mu    sync.Mutex
	lines []string
}

func captureUpdateLog(c *agentCatalog) *updateLog {
	l := &updateLog{}
	c.logf = func(format string, args ...any) {
		l.mu.Lock()
		l.lines = append(l.lines, fmt.Sprintf(format, args...))
		l.mu.Unlock()
	}
	return l
}

func (l *updateLog) text() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Join(l.lines, "\n")
}

func (l *updateLog) count(part string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for _, line := range l.lines {
		if strings.Contains(line, part) {
			n++
		}
	}
	return n
}

// waitFor waits for a line that holds line (logged after an update has let
// the agent go).
func (l *updateLog) waitFor(t *testing.T, line string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for l.count(line) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("no log line %q in:\n%s", line, l.text())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// launchNotice starts a terminal of program and returns its updateNotice.
func launchNotice(t *testing.T, f *catalogFixture, program string) string {
	t.Helper()
	state, _ := f.store.Read()
	w := f.call("POST", "/v1/terminals", map[string]any{"projectId": state.Config.Projects[0].ID, "program": program, "rows": 24, "cols": 80})
	if w.Code != 201 {
		t.Fatalf("create %s: %d %s", program, w.Code, w.Body)
	}
	var created TerminalInfo
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	return created.UpdateNotice
}

func updaterRuns(t *testing.T, log string) int {
	t.Helper()
	data, _ := os.ReadFile(log)
	return strings.Count(string(data), "update\n")
}

// Before a launch, an agent updates at most once an hour (owner, 2026-10-17):
// any automatic attempt within the hour, failed or not, before a launch or in
// the background run, skips it, and says so in the log; a launch after the
// hour updates again.
func TestPreLaunchUpdateRunsAtMostHourly(t *testing.T) {
	failing := filepath.Join(t.TempDir(), "failing")
	if err := os.WriteFile(failing, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	command, log := localUpdaterFixture(t, "test ! -e '"+failing+"' || exit 7")
	f := newCatalogFixture(t, map[string]string{"codex": command}, map[string]string{command: "1.0.0"})
	clock := &testClock{now: time.Date(2026, 10, 17, 9, 0, 0, 0, time.UTC)}
	f.host.agents.now = clock.Now
	logged := captureUpdateLog(f.host.agents)
	enableAutomaticFor(t, f)
	nativeTerminalFor(f)
	end := func() {
		t.Helper()
		f.terminals.exit(f.terminals.latest(), 0)
		waitFor(t, "the terminal to end", func() bool { return runningTerminalsOf(f, "codex") == 0 })
	}

	if notice := launchNotice(t, f, "codex"); notice != "Couldn't update Codex; started the installed version." || updaterRuns(t, log) != 1 {
		t.Fatalf("failed update: %q, %d runs", notice, updaterRuns(t, log))
	}
	logged.waitFor(t, "agents: codex update (pre-launch): 1.0.0 → 1.0.0, failed: the updater failed (exit 7)")
	end()
	clock.Advance(59 * time.Minute)
	if notice := launchNotice(t, f, "codex"); notice != "" || updaterRuns(t, log) != 1 {
		t.Fatalf("within the hour: %q, %d runs", notice, updaterRuns(t, log))
	}
	logged.waitFor(t, "agents: codex update (pre-launch): 1.0.0 → 1.0.0, skipped: an update was attempted 59 min ago")
	end()

	os.Remove(failing)
	clock.Advance(61 * time.Minute)
	if notice := launchNotice(t, f, "codex"); notice != "" || updaterRuns(t, log) != 2 {
		t.Fatalf("after the hour: %q, %d runs", notice, updaterRuns(t, log))
	}
	logged.waitFor(t, "agents: codex update (pre-launch): 1.0.0 → 1.0.0, already current")
	end()

	// The background run's attempt counts too.
	clock.Advance(2 * time.Hour)
	f.host.agents.updateRun()
	if updaterRuns(t, log) != 3 || logged.count("agents: codex update (background): 1.0.0 → 1.0.0, already current") != 1 {
		t.Fatalf("background run: %d runs\n%s", updaterRuns(t, log), logged.text())
	}
	clock.Advance(10 * time.Minute)
	if notice := launchNotice(t, f, "codex"); notice != "" || updaterRuns(t, log) != 3 {
		t.Fatalf("after the background run: %q, %d runs", notice, updaterRuns(t, log))
	}
	logged.waitFor(t, "skipped: an update was attempted 10 min ago")
}

// A version the update changes is logged old → new, with the trigger.
func TestPreLaunchUpdateLogsOldAndNewVersions(t *testing.T) {
	command, _ := localUpdaterFixture(t, "exit 0")
	version := filepath.Join(filepath.Dir(command), "version")
	// The updater writes 2.0.0 and replaces its own file, as a self-updater does.
	writeScript(t, command, "case \"$1:$2\" in\n  --version:) cat '"+version+"';;\n  update:--help) echo 'Usage: codex update';;\n"+
		"  update:) echo token=secret; echo 2.0.0 > '"+version+"'; touch \"$0\";;\n  *) exit 91;;\nesac\n")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	f.host.agents.versionOf = func(path string) string { return runAgentVersion(path, f.host.agents.baseEnv) }
	logged := captureUpdateLog(f.host.agents)
	enableAutomaticFor(t, f)
	nativeTerminalFor(f)
	if notice := launchNotice(t, f, "codex"); notice != "" {
		t.Fatalf("notice: %q", notice)
	}
	logged.waitFor(t, "agents: codex update (pre-launch): 1.0.0 → 2.0.0, updated")
	if text := logged.text(); strings.Contains(text, "secret") || strings.Contains(text, command) || strings.Count(text, "\n") != 0 {
		t.Fatalf("log: %s", text)
	}
}

// A slow update of Claude Code's native installer, which puts each version in
// its own file of a versions folder, goes on in the background: the terminal
// starts the installed version at once with a notice, and the update finishes.
func TestSlowBesideUpdateGoesOnWhileTheInstalledVersionStarts(t *testing.T) {
	root := t.TempDir()
	versions := filepath.Join(root, "share", "claude", "versions")
	log, release := filepath.Join(root, "log"), filepath.Join(root, "release")
	link := filepath.Join(root, "bin", "claude")
	body := "case \"$1:$2\" in\n" +
		"  update:--help) echo 'Usage: claude update|upgrade [options]';;\n" +
		"  update:) echo update >> '" + log + "'; while test ! -e '" + release + "'; do sleep 0.01; done; cp '" + versions + "/1.0.0' '" + versions + "/1.0.1'; ln -s ../share/claude/versions/1.0.1 '" + link + ".new'; mv -f '" + link + ".new' '" + link + "';;\n" +
		"  *) exit 91;;\nesac\n"
	writeScript(t, filepath.Join(versions, "1.0.0"), body)
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../share/claude/versions/1.0.0", link); err != nil {
		t.Fatal(err)
	}
	f := newCatalogFixture(t, map[string]string{"claude": link}, nil)
	logged := captureUpdateLog(f.host.agents)
	backend := nativeTerminalFor(f)
	enableAutomaticFor(t, f)
	// Long enough for the updater to start under the race detector.
	f.host.agents.terminalUpdateWait = time.Second
	var launched string
	backend.beforeStart = func(path string) {
		if target, err := filepath.EvalSymlinks(path); err == nil {
			launched = filepath.Base(target)
		}
	}
	if notice := launchNotice(t, f, "claude"); notice != "Claude Code is still updating; started the installed version." || launched != "1.0.0" {
		t.Fatalf("slow update: %q, launched %q", notice, launched)
	}
	if agent := f.agent("claude"); agent.State != "updating" {
		t.Fatalf("the update was not left running: %+v", agent)
	}
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	logged.waitFor(t, "agents: claude update (pre-launch): 1.0.0 → 1.0.1, updated")
	if target, _ := os.Readlink(link); !strings.HasSuffix(target, "1.0.1") {
		t.Fatalf("link still points at %q", target)
	}
	if data, _ := os.ReadFile(log); strings.Count(string(data), "update\n") != 1 {
		t.Fatalf("updater runs: %q", data)
	}
	latest := f.terminals.latest()
	f.terminals.mu.Lock()
	running := f.terminals.terminals[latest].info.Running
	f.terminals.mu.Unlock()
	if !running {
		t.Fatal("the terminal that started during the update stopped")
	}
}

// A registry agent's refresh before a launch follows the same hourly rule.
func TestRegistryPreLaunchRefreshRunsAtMostHourly(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	clock := &testClock{now: time.Date(2026, 10, 17, 9, 0, 0, 0, time.UTC)}
	f.host.agents.now = clock.Now
	logged := captureUpdateLog(f.host.agents)
	installFakeGoose(t, f, "1.0.0")
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 202 {
		t.Fatalf("install: %d", w.Code)
	}
	f.waitSettled("goose")
	enableAutomaticFor(t, f)
	before := f.registry.hitsOf("/registry.json")
	if notice := launchNotice(t, f, "goose"); notice != "" || f.registry.hitsOf("/registry.json") != before+1 {
		t.Fatalf("first launch: %q, %d reads", notice, f.registry.hitsOf("/registry.json")-before)
	}
	logged.waitFor(t, "agents: goose update (pre-launch): 1.0.0 → 1.0.0, already current")
	clock.Advance(30 * time.Minute)
	if notice := launchNotice(t, f, "goose"); notice != "" || f.registry.hitsOf("/registry.json") != before+1 {
		t.Fatalf("within the hour: %q, %d reads", notice, f.registry.hitsOf("/registry.json")-before)
	}
	logged.waitFor(t, "agents: goose update (pre-launch): 1.0.0 → 1.0.0, skipped: an update was attempted 30 min ago")
}
