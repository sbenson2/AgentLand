//go:build !windows

package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The test binary also runs as an OpenCode whose serve never answers and
// starts a helper in a session of its own that keeps the serve's output open
// (AGENTLAND_FAKE_AGENT=opencode-escape), and as that helper (escaped-helper),
// which waits a minute at most. The serve writes the helper's process ID to
// FAKE_ESCAPE_DIR/helper.pid.
func init() {
	switch os.Getenv("AGENTLAND_FAKE_AGENT") {
	case "opencode-escape":
		os.Exit(runFakeEscapingOpenCode())
	case "escaped-helper":
		time.Sleep(time.Minute)
		os.Exit(0)
	}
}

func runFakeEscapingOpenCode() int {
	self, err := os.Executable()
	if err != nil {
		return 5
	}
	helper := exec.Command(self)
	helper.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=escaped-helper")
	helper.Stdout, helper.Stderr = os.Stdout, os.Stderr
	helper.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if helper.Start() != nil {
		return 6
	}
	_ = os.WriteFile(filepath.Join(os.Getenv("FAKE_ESCAPE_DIR"), "helper.pid"), []byte(strconv.Itoa(helper.Process.Pid)), 0o600)
	time.Sleep(time.Hour)
	return 0
}

// escapingOpenCode is an opencode command that runs the fake above, and a
// cleanup that ends its helper.
func escapingOpenCode(t *testing.T, self string) (command, records string) {
	t.Helper()
	records = t.TempDir()
	t.Cleanup(func() {
		if data, err := os.ReadFile(filepath.Join(records, "helper.pid")); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil && pid > 1 {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})
	return "#!/bin/sh\nAGENTLAND_FAKE_AGENT=opencode-escape FAKE_ESCAPE_DIR='" + records + "' exec '" + self + "' \"$@\"\n", records
}

// An OpenCode that never answers and leaves a helper holding the check's
// output: the check ends soon after its wait, and a host that stops during a
// check does not wait for the helper either.
func TestOpenCodeCheckDoesNotWaitForEscapedHelpers(t *testing.T) {
	self, _ := os.Executable()
	script, records := escapingOpenCode(t, self)
	command := writeScript(t, filepath.Join(t.TempDir(), "opencode"), strings.TrimPrefix(script, "#!/bin/sh\n"))
	base := []string{"PATH=/usr/bin:/bin", "HOME=/owner/home", "USER=tester"}
	started := time.Now()
	err := checkOpenCode(t.Context(), command, "1.18.32", 300*time.Millisecond, base, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "did not answer") {
		t.Fatalf("check: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(records, "helper.pid")); statErr != nil {
		t.Fatalf("the helper did not start: %v", statErr)
	}
	if elapsed := time.Since(started); elapsed > 8*time.Second {
		t.Fatalf("the check took %v: it waited for the helper", elapsed)
	}

	// An install whose check hangs like this ends when the host stops.
	f := newCatalogFixture(t, nil, nil)
	script, records = escapingOpenCode(t, self)
	archive := zipArchive(t, archiveEntry{name: "opencode", body: script, mode: 0o755})
	f.registry.setFile("/opencode.zip", archive)
	f.registry.setAgents(map[string]any{"id": "opencode", "name": "OpenCode", "version": "1.18.32", "distribution": map[string]any{"binary": map[string]any{agentPlatform(): map[string]any{"archive": f.registry.url("/opencode.zip"), "cmd": "./opencode", "args": []string{"acp"}, "sha256": sha256Hex(archive)}}}})
	f.agents()
	catalog := f.host.agents
	catalog.openCodeWait = time.Minute
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "opencode"}); w.Code != 202 {
		t.Fatalf("install %d %s", w.Code, w.Body)
	}
	waitFor(t, "the check to start", func() bool {
		_, err := os.Stat(filepath.Join(records, "helper.pid"))
		return err == nil
	})
	started = time.Now()
	catalog.close()
	if elapsed := time.Since(started); elapsed > 8*time.Second {
		t.Fatalf("stopping took %v: it waited for the helper", elapsed)
	}
	catalog.mu.Lock()
	ops := len(catalog.ops)
	catalog.mu.Unlock()
	if ops != 0 {
		t.Fatalf("%d changes still run", ops)
	}
	if versions := versionsOf(t, catalog.store, "opencode"); len(versions) != 0 {
		t.Fatalf("an unfinished folder stayed: %v", versions)
	}
	if status := catalog.store.readStatus("opencode"); status.LastError != "" {
		t.Fatalf("a stop is no failure: %+v", status)
	}
}

// A slow update in place that a launch stops ends with its whole process
// group before the terminal starts, and the next launch within the hour does
// not run it again.
func TestSlowInPlaceLaunchUpdateEndsItsProcessGroup(t *testing.T) {
	folder := t.TempDir()
	pidFile := filepath.Join(folder, "pid")
	command, log := localUpdaterFixture(t, "echo $$ > '"+pidFile+"'; sleep 30 & wait")
	f := newCatalogFixture(t, map[string]string{"codex": command}, nil)
	enableAutomaticFor(t, f)
	nativeTerminalFor(f)
	// Long enough for the updater to start under the race detector.
	f.host.agents.terminalUpdateWait = time.Second
	id := createTerminalFor(t, f, "codex")
	recorded, _ := os.ReadFile(pidFile)
	pid, err := strconv.Atoi(strings.TrimSpace(string(recorded)))
	if err != nil || pid <= 1 {
		t.Fatalf("updater pid %q", recorded)
	}
	// The leader was reaped before the answer; its sleeping child, killed
	// with it, is reaped by launchd.
	waitFor(t, "the updater's process group to end", func() bool { return syscall.Kill(-pid, 0) == syscall.ESRCH })
	f.terminals.exit(id, 0)
	waitFor(t, "the terminal to end", func() bool { return runningTerminalsOf(f, "codex") == 0 })
	createTerminalFor(t, f, "codex")
	if data, _ := os.ReadFile(log); strings.Count(string(data), "update\n") != 1 {
		t.Fatalf("a stopped update was not counted as an attempt: %q", data)
	}
}
