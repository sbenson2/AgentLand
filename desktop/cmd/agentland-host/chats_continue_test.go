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

// answerChatContinues serves the state's local socket, answering each chat
// continue with answer, and hands over the requests it read.
func answerChatContinues(t *testing.T, state string, answer localterm.Reply) <-chan localterm.Request {
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
				_ = localterm.WriteLine(conn, answer)
			}
			conn.Close()
		}
	}()
	return requests
}

func TestChatsContinueCommand(t *testing.T) {
	folder, err := os.MkdirTemp("", "al-cli-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	state := filepath.Join(folder, "host.json")
	requests := answerChatContinues(t, state, localterm.Reply{ID: "claude:new"})
	run := func(args ...string) (int, string, string) {
		var stdout, stderr bytes.Buffer
		code := chatsContinueCommand(args, &stdout, &stderr)
		return code, stdout.String(), stderr.String()
	}

	// The host's chat process names the state and the chat.
	t.Setenv("AGENTLAND_HOST_STATE", state)
	t.Setenv("AGENTLAND_CHAT", "claude:old")
	t.Setenv("AGENTLAND_TERMINAL", "term_other")
	if code, stdout, stderr := run("--", "go on"); code != 0 || stdout != "claude:new\n" || stderr != "" {
		t.Fatalf("continue: %d %q %q", code, stdout, stderr)
	}
	if request := <-requests; request.Op != localterm.OpContinueChat || request.Chat != "claude:old" || request.From != "" || request.Prompt != "go on" || request.Version != version {
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
	if code, _, stderr := run(); code != termrun.ContinueUsage || !strings.Contains(stderr, chatsContinueUsage) {
		t.Fatalf("usage: %q", stderr)
	}
	// Outside an AgentLand chat (an AgentLand terminal is not one).
	t.Setenv("AGENTLAND_CHAT", "")
	if code, stdout, stderr := run("--", "go on"); code != termrun.ContinueNotHere || stdout != "" || stderr != "This isn't an AgentLand chat.\n" {
		t.Fatalf("outside: %d %q %q", code, stdout, stderr)
	}
}

// The host's refusals: 5 for a chat it can't continue, 1 for any other, with
// the host's message.
func TestChatsContinueCommandRefusals(t *testing.T) {
	for _, c := range []struct {
		reply localterm.Reply
		code  int
	}{
		{localterm.Reply{Error: &localterm.Error{Code: localterm.CodeChatNotContinuable, Message: "Only a Claude Code chat can be continued."}}, termrun.ContinueNotHere},
		{localterm.Reply{Error: &localterm.Error{Code: localterm.CodeVersion, Message: "This command and the AgentLand host running now are different versions."}}, termrun.ContinueFailed},
		{localterm.Reply{Error: &localterm.Error{Code: localterm.CodeLimit, Message: "Six Claude Code chats are working in AgentLand; try again when one finishes."}}, termrun.ContinueFailed},
	} {
		folder, err := os.MkdirTemp("", "al-cli-")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.RemoveAll(folder) })
		state := filepath.Join(folder, "host.json")
		answerChatContinues(t, state, c.reply)
		t.Setenv("AGENTLAND_CHAT", "claude:old")
		var stdout, stderr bytes.Buffer
		if code := chatsContinueCommand([]string{"--state", state, "--", "go on"}, &stdout, &stderr); code != c.code || stdout.Len() != 0 || stderr.String() != c.reply.Error.Message+"\n" {
			t.Errorf("%s: %d %q %q", c.reply.Error.Code, code, stdout.String(), stderr.String())
		}
	}
}
