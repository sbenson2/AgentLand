//go:build darwin || linux

package main

import (
	"bufio"
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentland/host/internal/localterm"
	"agentland/host/internal/termrun"
)

// answerContinues serves the state's local socket, answering each continue
// with a new terminal's ID, and hands over the requests it read.
func answerContinues(t *testing.T, state string) <-chan localterm.Request {
	t.Helper()
	listener, err := net.Listen("unix", localterm.SocketPath(state))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	requests := make(chan localterm.Request, 4)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			var request localterm.Request
			if localterm.ReadLine(bufio.NewReader(conn), &request) == nil {
				requests <- request
				_ = localterm.WriteLine(conn, localterm.Reply{ID: "term_new"})
			}
			conn.Close()
		}
	}()
	return requests
}

func TestTerminalsContinueCommand(t *testing.T) {
	folder, err := os.MkdirTemp("", "al-cli-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	state := filepath.Join(folder, "host.json")
	requests := answerContinues(t, state)
	run := func(args ...string) (int, string, string) {
		var stdout, stderr bytes.Buffer
		code := continueCommand(args, &stdout, &stderr)
		return code, stdout.String(), stderr.String()
	}

	// The host's terminal names the state and the terminal.
	t.Setenv("AGENTLAND_HOST_STATE", state)
	t.Setenv("AGENTLAND_TERMINAL", "term_old")
	if code, stdout, stderr := run("--", "go on"); code != 0 || stdout != "term_new\n" || stderr != "" {
		t.Fatalf("continue: %d %q %q", code, stdout, stderr)
	}
	if request := <-requests; request.Op != localterm.OpContinue || request.From != "term_old" || request.Prompt != "go on" || request.Version != version {
		t.Fatalf("request %+v", request)
	}
	// --state names another host; this one has no socket.
	if code, stdout, _ := run("--state", filepath.Join(folder, "other", "host.json"), "--", "go on"); code != termrun.ContinueNotHere || stdout != "" {
		t.Fatalf("other state: %d %q", code, stdout)
	}
	// Usage.
	for _, args := range [][]string{{}, {"--"}, {"--", "a", "b"}, {"--nope", "--", "go on"}} {
		if code, stdout, _ := run(args...); code != termrun.ContinueUsage || stdout != "" {
			t.Errorf("%q: %d %q", args, code, stdout)
		}
	}
	if code, _, stderr := run(); code != termrun.ContinueUsage || !strings.Contains(stderr, terminalsContinueUsage) {
		t.Fatalf("usage: %q", stderr)
	}
	// Outside an AgentLand terminal.
	t.Setenv("AGENTLAND_TERMINAL", "")
	if code, stdout, stderr := run("--", "go on"); code != termrun.ContinueNotHere || stdout != "" || stderr == "" {
		t.Fatalf("outside: %d %q %q", code, stdout, stderr)
	}
	if !strings.Contains(terminalsUsage, "|continue|") {
		t.Errorf("the usage does not name continue: %q", terminalsUsage)
	}
}
