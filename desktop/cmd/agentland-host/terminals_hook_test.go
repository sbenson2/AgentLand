package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	host "agentland/host"
	"agentland/host/internal/shellhook"
)

func hookStatus(t *testing.T, state string) shellhook.Status {
	t.Helper()
	var out bytes.Buffer
	if err := hookCommand([]string{"status", "--state", state}, &out); err != nil {
		t.Fatal(err)
	}
	var status shellhook.Status
	if err := json.Unmarshal(out.Bytes(), &status); err != nil || !strings.HasSuffix(out.String(), "}\n") {
		t.Fatalf("status printed %q: %v", out.String(), err)
	}
	return status
}

func TestTerminalsHookOnStatusPauseOff(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	zshrc := filepath.Join(home, ".zshrc")
	if err := os.WriteFile(zshrc, []byte("export A=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(t.TempDir(), "host.json")
	executable := "/Applications/Agent Land.app/Contents/MacOS/agentland-host"
	if err := hookCommand([]string{"on", "--state", state, "--executable", executable}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	_, hook, switchFile := shellhook.Paths(state)
	script, err := os.ReadFile(hook)
	if err != nil || string(script) != shellhook.Script(executable, state, switchFile, host.RoutedAgentPrograms()) {
		t.Fatalf("hook %q, %v", script, err)
	}
	if !strings.Contains(string(script), "for _agentland_name in "+strings.Join(host.RoutedAgentPrograms(), " ")+"; do") {
		t.Fatalf("the hook does not route the host's agents:\n%s", script)
	}
	if got := hookStatus(t, state); got != (shellhook.Status{On: true, Block: "present", Zshrc: zshrc}) {
		t.Fatalf("after on: %+v", got)
	}
	if err := hookCommand([]string{"pause", "--state", state}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if got := hookStatus(t, state); got != (shellhook.Status{On: false, Block: "present", Zshrc: zshrc}) {
		t.Fatalf("after pause: %+v", got)
	}
	if err := hookCommand([]string{"off", "--state", state}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if got := hookStatus(t, state); got != (shellhook.Status{On: false, Block: "absent", Zshrc: zshrc}) {
		t.Fatalf("after off: %+v", got)
	}
	if data, err := os.ReadFile(zshrc); err != nil || string(data) != "export A=1\n" {
		t.Fatalf(".zshrc %q, %v", data, err)
	}
}

// Without --executable the hook runs this program, its links resolved.
func TestTerminalsHookRunsThisProgramByDefault(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(t.TempDir(), "host.json")
	if err := hookCommand([]string{"on", "--state", state}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		t.Fatal(err)
	}
	_, hook, _ := shellhook.Paths(state)
	if script, err := os.ReadFile(hook); err != nil || !strings.Contains(string(script), "_agentland_bin='"+self+"'") {
		t.Fatalf("hook %q, %v; want %s", script, err, self)
	}
}

func TestTerminalsHookDamagedBlockSaysWhatToDo(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	zshrc := filepath.Join(home, ".zshrc")
	if err := os.WriteFile(zshrc, []byte(shellhook.StartMarker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := hookCommand([]string{"on", "--state", filepath.Join(t.TempDir(), "host.json")}, &bytes.Buffer{})
	var damaged *shellhook.DamagedBlockError
	if !errors.As(err, &damaged) || !strings.HasPrefix(err.Error(), "AgentLand's block in "+zshrc+" is damaged.") {
		t.Fatalf("%v", err)
	}
}

func TestTerminalsHookUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"nope"}, {"on", "extra"}, {"--state", "x"}} {
		if err := hookCommand(args, &bytes.Buffer{}); err == nil || err.Error() != terminalsHookUsage {
			t.Errorf("%q: %v", args, err)
		}
	}
	if !strings.Contains(terminalsUsage, "|hook>") || !strings.Contains(usage().Error(), "terminals hook") {
		t.Errorf("the usage does not name hook: %q, %q", terminalsUsage, usage())
	}
}

// A bad flag puts one message on stderr and exits 1: the Mac app shows
// stderr as it is.
func TestTerminalsHookBadFlagSaysItOnce(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_HOOK_BAD_FLAG") == "1" {
		os.Args = []string{"agentland-host", "terminals", "hook", "on", "--bogus"}
		main()
		os.Exit(0)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestTerminalsHookBadFlagSaysItOnce$")
	command.Env = append(os.Environ(), "AGENTLAND_TEST_HOOK_BAD_FLAG=1", "HOME="+t.TempDir())
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err := command.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		t.Fatalf("exit: %v; stdout %q, stderr %q", err, stdout.String(), stderr.String())
	}
	if got, want := stderr.String(), "flag provided but not defined: -bogus\n"; got != want || stdout.Len() != 0 {
		t.Fatalf("stderr %q, want %q; stdout %q", got, want, stdout.String())
	}
}
