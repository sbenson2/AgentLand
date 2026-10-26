//go:build darwin || linux

package termrun

import (
	"bufio"
	"bytes"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"agentland/host/internal/localterm"
)

// continueState is a state path in a short folder (a Unix socket's path fits
// 103 bytes), with no socket beside it yet.
func continueState(t *testing.T) string {
	t.Helper()
	folder, err := os.MkdirTemp("", "al-cont-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	return filepath.Join(folder, "host.json")
}

// fakeContinueHost answers each continue on the state's socket with answer
// (none at all when nil) and hands over the request it read.
func fakeContinueHost(t *testing.T, state string, answer *localterm.Reply) <-chan localterm.Request {
	t.Helper()
	listener, err := net.Listen("unix", localterm.SocketPath(state))
	if err != nil {
		t.Fatal(err)
	}
	requests := make(chan localterm.Request, 4)
	done := make(chan struct{})
	t.Cleanup(func() { close(done); listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var request localterm.Request
				if localterm.ReadLine(bufio.NewReader(conn), &request) != nil {
					return
				}
				requests <- request
				if answer == nil {
					<-done
					return
				}
				_ = localterm.WriteLine(conn, *answer)
			}()
		}
	}()
	return requests
}

func runContinue(o ContinueOptions) (int, string, string) {
	var stdout, stderr bytes.Buffer
	o.Stdout, o.Stderr = &stdout, &stderr
	code := Continue(o)
	return code, stdout.String(), stderr.String()
}

func TestContinuePrintsTheNewTerminal(t *testing.T) {
	state := continueState(t)
	requests := fakeContinueHost(t, state, &localterm.Reply{ID: "term_new"})
	code, stdout, stderr := runContinue(ContinueOptions{StatePath: state, Version: "1.2.3", From: "term_old", Prompt: "go on", Rows: 40, Cols: 120})
	if code != 0 || stdout != "term_new\n" || stderr != "" {
		t.Fatalf("%d %q %q", code, stdout, stderr)
	}
	want := localterm.Request{Op: localterm.OpContinue, From: "term_old", Prompt: "go on", Rows: 40, Cols: 120, Version: "1.2.3"}
	if got := <-requests; got != want {
		t.Fatalf("request %+v", got)
	}
}

func TestContinueExitCodes(t *testing.T) {
	notHere := &localterm.Reply{Error: &localterm.Error{Code: localterm.CodeNotContinuable, Message: "This terminal has ended."}}
	other := &localterm.Reply{Error: &localterm.Error{Code: localterm.CodeVersion, Message: "This command and the AgentLand host running now are different versions."}}
	cases := []struct {
		name    string
		prepare func(t *testing.T, state string)
		from    string
		code    int
		stderr  string
	}{
		{name: "outside AgentLand", from: "", code: ContinueNotHere, stderr: "This isn't an AgentLand terminal.\n"},
		{name: "no socket", from: "term_old", code: ContinueNotHere, stderr: "AgentLand isn't running.\n"},
		{name: "refused connection", prepare: func(t *testing.T, state string) {
			listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: localterm.SocketPath(state), Net: "unix"})
			if err != nil {
				t.Fatal(err)
			}
			// A host that went away and left its socket.
			listener.SetUnlinkOnClose(false)
			listener.Close()
		}, from: "term_old", code: ContinueNotHere, stderr: "AgentLand isn't running.\n"},
		{name: "not continuable", prepare: func(t *testing.T, state string) { fakeContinueHost(t, state, notHere) }, from: "term_old", code: ContinueNotHere, stderr: "This terminal has ended.\n"},
		{name: "other refusal", prepare: func(t *testing.T, state string) { fakeContinueHost(t, state, other) }, from: "term_old", code: ContinueFailed, stderr: other.Error.Message + "\n"},
		{name: "no id", prepare: func(t *testing.T, state string) { fakeContinueHost(t, state, &localterm.Reply{}) }, from: "term_old", code: ContinueFailed},
		{name: "silent host", prepare: func(t *testing.T, state string) { fakeContinueHost(t, state, nil) }, from: "term_old", code: ContinueFailed, stderr: "AgentLand didn't answer in time.\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			state := continueState(t)
			if c.prepare != nil {
				c.prepare(t, state)
			}
			code, stdout, stderr := runContinue(ContinueOptions{StatePath: state, From: c.from, Prompt: "go on", Wait: 300 * time.Millisecond})
			if code != c.code || stdout != "" || stderr == "" || (c.stderr != "" && stderr != c.stderr) {
				t.Fatalf("%d %q %q", code, stdout, stderr)
			}
		})
	}
}
