package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	host "agentland/host"
	"agentland/host/keeper"
)

func TestVersionDoesNotRequireHostInitialization(t *testing.T) {
	if err := run([]string{"version"}); err != nil {
		t.Fatalf("version requires configuration: %v", err)
	}
}

func TestUsageNamesAgentLandHost(t *testing.T) {
	err := run(nil)
	if err == nil {
		t.Fatal("missing command returned no usage error")
	}
	if !strings.Contains(err.Error(), "agentland-host") {
		t.Fatalf("usage = %q, want AgentLand host command", err)
	}
}

func TestCommandHelpDoesNotReturnAnError(t *testing.T) {
	for _, command := range []string{"init", "serve", "pair", "devices", "revoke", "install-opencode"} {
		t.Run(command, func(t *testing.T) {
			if err := run([]string{command, "--help"}); err != nil {
				t.Fatalf("%s help error: %v", command, err)
			}
		})
	}
}

func TestDevicesCommandReportsRecentPresenceSeparatelyFromAuthorization(t *testing.T) {
	state := filepath.Join(t.TempDir(), "host.json")
	if err := run([]string{"init", "--state", state, "--project", "p=Project=" + t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	store := host.NewStore(state)
	code, _ := store.CreatePairingCode(time.Minute)
	_, id, err := store.RedeemPairingCode(code, "Phone")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetDevicePresence(id, true); err != nil {
		t.Fatal(err)
	}
	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	commandErr := run([]string{"devices", "--state", state})
	writer.Close()
	os.Stdout = original
	data, readErr := io.ReadAll(reader)
	reader.Close()
	if commandErr != nil || readErr != nil {
		t.Fatal(commandErr, readErr)
	}
	if !strings.Contains(string(data), "\tactive\t") || !strings.Contains(string(data), "\tPhone\tonline\n") {
		t.Fatalf("device output = %q", data)
	}
}

func TestInitUsesAgentLandOpenCodePasswordEnvironment(t *testing.T) {
	project := t.TempDir()
	state := filepath.Join(t.TempDir(), "host.json")
	if err := run([]string{"init", "--state", state, "--project", "project=Project=" + project}); err != nil {
		t.Fatalf("initialize state: %v", err)
	}
	stored, err := host.NewStore(state).Read()
	if err != nil {
		t.Fatalf("read initialized state: %v", err)
	}
	if got, want := stored.Config.PasswordEnv, "AGENTLAND_OPENCODE_PASSWORD"; got != want {
		t.Fatalf("password environment = %q, want %q", got, want)
	}
}

func TestConfigUpdatesPreserveDevicesAndPairing(t *testing.T) {
	state := filepath.Join(t.TempDir(), "host.json")
	directory := t.TempDir()
	if err := run([]string{"init", "--state", state, "--project", "old=Old=" + directory}); err != nil {
		t.Fatal(err)
	}
	store := host.NewStore(state)
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := store.RedeemPairingCode(code, "Phone")
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"config", "set", "--state", state, "--opencode-url", "http://127.0.0.1:4197", "--password-env", "AGENTLAND_OPENCODE_PASSWORD", "--project", "new=New=" + directory}
	if err := run(args); err != nil {
		t.Fatal(err)
	}
	got, _ := store.Read()
	if got.Config.Projects[0].ID != "new" {
		t.Fatal("project not updated")
	}
	if _, ok := store.Authenticate(token); !ok {
		t.Fatal("device lost after configuration")
	}
	if _, _, err := store.RedeemPairingCode(pending, "Tablet"); err != nil {
		t.Fatal("pending code lost", err)
	}
	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	showErr := run([]string{"config", "show", "--state", state})
	writer.Close()
	os.Stdout = original
	data, err := io.ReadAll(reader)
	reader.Close()
	if err != nil || showErr != nil {
		t.Fatal(err, showErr)
	}
	var cfg host.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(string(data), err)
	}
	if cfg.Projects[0].ID != "new" || strings.Contains(string(data), "tokenHash") || strings.Contains(string(data), "pairingCodes") {
		t.Fatal("configuration leaked state or wrong shape")
	}
	args[len(args)-1] = "bad=Bad=" + filepath.Join(directory, "missing")
	if err := run(args); err == nil {
		t.Fatal("invalid configuration accepted")
	}
	got, _ = store.Read()
	if got.Config.Projects[0].ID != "new" {
		t.Fatal("failed edit damaged state")
	}
}

// --workspace-home is checked before any state is read: it must name an
// existing folder, and it is made absolute.
func TestServeChecksTheWorkspaceHome(t *testing.T) {
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{filepath.Join(t.TempDir(), "missing"), file} {
		if err := run([]string{"serve", "--state", filepath.Join(t.TempDir(), "host.json"), "--workspace-home", home}); err == nil || !strings.Contains(err.Error(), "--workspace-home") {
			t.Errorf("%s: %v, want an error about --workspace-home", home, err)
		}
	}
	directory := t.TempDir()
	t.Chdir(directory)
	if home, err := workspaceHomeSetting("."); err != nil || home != directory {
		t.Errorf("relative home: %q %v, want %q", home, err, directory)
	}
	if home, err := workspaceHomeSetting(""); err != nil || home != "" {
		t.Errorf("default home: %q %v", home, err)
	}
}

// Plain chats: chat-tools, the tool server OpenCode starts, takes only
// --state (its stdio is the MCP connection).
func TestChatToolsCommandRejectsPositionalArguments(t *testing.T) {
	if err := run([]string{"chat-tools", "--help"}); err != nil {
		t.Fatalf("help: %v", err)
	}
	if err := run([]string{"chat-tools", "--state", filepath.Join(t.TempDir(), "host.json"), "extra"}); err == nil || !strings.Contains(err.Error(), "takes only --state") {
		t.Fatalf("an extra argument: %v", err)
	}
	if err := run(nil); err == nil || !strings.Contains(err.Error(), "chat-tools") {
		t.Fatalf("usage: %v", err)
	}
}

// Plain chats: the Chats space's ID is reserved, for init and config set.
func TestCLIRefusesTheChatsProjectID(t *testing.T) {
	state := filepath.Join(t.TempDir(), "host.json")
	if err := run([]string{"init", "--state", state, "--project", "chats=Chats=" + t.TempDir()}); err == nil || !strings.Contains(err.Error(), "reserved for plain chats") {
		t.Fatalf("init with chats: %v", err)
	}
	if err := run([]string{"init", "--state", state, "--project", "p=Project=" + t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"config", "set", "--state", state, "--project", "chats=Chats=" + t.TempDir()}); err == nil || !strings.Contains(err.Error(), "reserved for plain chats") {
		t.Fatalf("config set with chats: %v", err)
	}
}

// The host keeps running when its output pipe closes (the Mac app that reads
// it went away): writes to stdout and stderr fail instead of killing it.
func TestServeSurvivesItsOutputPipeClosing(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_CLOSED_OUTPUT") == "1" {
		surviveClosedOutput()
		for i := 0; i < 3; i++ {
			fmt.Println("listening on 127.0.0.1:9841")
			fmt.Fprintln(os.Stderr, "terminals: created")
		}
		os.Exit(0)
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	reader.Close()
	command := exec.Command(os.Args[0], "-test.run=^TestServeSurvivesItsOutputPipeClosing$")
	command.Env = append(os.Environ(), "AGENTLAND_TEST_CLOSED_OUTPUT=1")
	command.Stdout, command.Stderr = writer, writer
	err = command.Run()
	writer.Close()
	if err != nil {
		t.Fatalf("the host did not survive its output closing: %v", err)
	}
}

// A keeper started for a state other than the default (a test's, the
// harness's) logs beside that state, never into the user's terminals log.
func TestKeeperLogSitsBesideANonDefaultState(t *testing.T) {
	if got := keeperLogPath(host.DefaultStatePath()); got != keeper.DefaultLogPath() {
		t.Fatalf("default state logs to %q", got)
	}
	state := filepath.Join(t.TempDir(), "host.json")
	if got := keeperLogPath(state); got != state+".terminals.log" {
		t.Fatalf("a test's state logs to %q", got)
	}
}

func TestTerminalsRunNeedsACommand(t *testing.T) {
	for _, args := range [][]string{
		{"terminals", "run"},
		{"terminals", "run", "--"},
		{"terminals", "run", "--state", filepath.Join(t.TempDir(), "host.json"), "--"},
	} {
		if err := run(args); err == nil || !strings.Contains(err.Error(), "usage: agentland-host terminals run") {
			t.Errorf("%q: %v", args, err)
		}
	}
	if err := run([]string{"terminals", "attach"}); err == nil || !strings.Contains(err.Error(), "usage: agentland-host terminals attach") {
		t.Errorf("attach without an id: %v", err)
	}
	if err := run([]string{"terminals", "nope"}); err == nil || !strings.Contains(err.Error(), "usage: agentland-host terminals <serve|stop|run|attach|continue|hook>") {
		t.Errorf("an unknown subcommand: %v", err)
	}
}

func TestChatsNeedsASubcommand(t *testing.T) {
	for _, args := range [][]string{{"chats"}, {"chats", "nope"}} {
		if err := run(args); err == nil || !strings.Contains(err.Error(), "usage: agentland-host chats <continue>") {
			t.Errorf("%q: %v", args, err)
		}
	}
	if err := run(nil); err == nil || !strings.Contains(err.Error(), "|chats continue|") {
		t.Errorf("the usage does not name chats continue: %v", err)
	}
}

func TestTerminalsRunLeavesArgumentsAfterDashDashAlone(t *testing.T) {
	state, name, args, err := parseRunArgs([]string{"--state", "s", "--", "claude", "--state", "x"})
	if err != nil || state != "s" || name != "claude" || !slices.Equal(args, []string{"--state", "x"}) {
		t.Fatalf("parseRunArgs = %q, %q, %q, %v", state, name, args, err)
	}
	state, name, args, err = parseRunArgs([]string{"--", "claude", "--", "-p"})
	if err != nil || state != host.DefaultStatePath() || name != "claude" || !slices.Equal(args, []string{"--", "-p"}) {
		t.Fatalf("parseRunArgs = %q, %q, %q, %v", state, name, args, err)
	}
}
