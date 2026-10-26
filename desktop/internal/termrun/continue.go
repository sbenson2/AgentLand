package termrun

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"syscall"
	"time"

	"agentland/host/internal/localterm"
)

// Continue is `agentland-host terminals continue -- <prompt>` (docs/HOST-API.md,
// "Continuing a terminal in a new one"). Typed in an AgentLand terminal, it
// asks the host on its private local socket to start Claude Code with the
// prompt in a new terminal of the same workspace, for the same device, and
// prints the new terminal's ID and nothing else on stdout. The caller then
// ends its own program; the host never ends it, and the old terminal's end
// names the new one, so the apps' tab switches to it.

// ContinueWait bounds the whole exchange: the host may first wait for Claude
// Code's update, as it does for a device's new terminal.
const ContinueWait = 60 * time.Second

// Continue's exit codes beside 0.
const (
	// ContinueFailed: the host refused or failed; why is on stderr.
	ContinueFailed = 1
	// ContinueUsage: the command was not used as its usage says (the CLI's).
	ContinueUsage = 2
	// ContinueNotHere: this terminal cannot be continued here (it is not an
	// AgentLand terminal, no host answers on the socket, or the host says it
	// cannot continue it), so the caller goes on its own way.
	ContinueNotHere = 5
)

// ContinueOptions is one `terminals continue`.
type ContinueOptions struct {
	// StatePath is the host's state file; the socket sits beside it.
	StatePath string
	// Version is this build's version, which must be the host's.
	Version string
	// From is the terminal it runs in ($AGENTLAND_TERMINAL), empty outside
	// one.
	From string
	// Prompt is the new Claude Code's first message.
	Prompt string
	// Rows and Cols are its window's size (WindowSize), 0 without one.
	Rows, Cols int
	// Stdout takes the new terminal's ID, Stderr why there is none.
	Stdout, Stderr io.Writer
	// Wait bounds the exchange; 0 means ContinueWait.
	Wait time.Duration
}

// Continue asks the host to continue the terminal and answers the exit code:
// 0 with the new terminal's ID on stdout, or ContinueNotHere or
// ContinueFailed with one line on stderr.
func Continue(o ContinueOptions) int {
	if o.From == "" {
		return continueFail(o.Stderr, ContinueNotHere, "This isn't an AgentLand terminal.")
	}
	request := localterm.Request{Op: localterm.OpContinue, From: o.From, Prompt: o.Prompt, Rows: o.Rows, Cols: o.Cols, Version: o.Version}
	return continueExchange(continueCall{statePath: o.StatePath, request: request, wait: o.Wait, notHere: localterm.CodeNotContinuable,
		noID: "AgentLand's host answered without a terminal.", stdout: o.Stdout, stderr: o.Stderr})
}

// ContinueChat is `agentland-host chats continue -- <prompt>` (docs/HOST-API.md,
// "Continuing a chat in a new one"). Run by a Claude Code chat's tool, it asks
// the host on the same private socket to start a new Claude Code chat in the
// chat's workspace, with its title, model, effort and mode, and the prompt as
// its first message, and prints the new chat's ID and nothing else on stdout.
// The host then stops the old chat's reply and its process; the old chat
// stays in history, usable.

// ContinueChatOptions is one `chats continue`.
type ContinueChatOptions struct {
	// StatePath is the host's state file; the socket sits beside it.
	StatePath string
	// Version is this build's version, which must be the host's.
	Version string
	// Chat is the chat whose tool runs it ($AGENTLAND_CHAT), empty outside
	// one.
	Chat string
	// Prompt is the new chat's first message.
	Prompt string
	// Stdout takes the new chat's ID, Stderr why there is none.
	Stdout, Stderr io.Writer
	// Wait bounds the exchange; 0 means ContinueChatWait.
	Wait time.Duration
}

// ContinueChatWait bounds a chat continue's exchange: the host may check
// Claude Code's sign-in (10 s), start its process (30 s) and wait for the
// prompt's echo (30 s) before it answers, more than ContinueWait.
const ContinueChatWait = 90 * time.Second

// ContinueChat asks the host to continue the chat and answers the exit code
// as Continue does: 0 with the new chat's ID on stdout, or ContinueNotHere or
// ContinueFailed with one line on stderr.
func ContinueChat(o ContinueChatOptions) int {
	if o.Chat == "" {
		return continueFail(o.Stderr, ContinueNotHere, "This isn't an AgentLand chat.")
	}
	wait := o.Wait
	if wait <= 0 {
		wait = ContinueChatWait
	}
	request := localterm.Request{Op: localterm.OpContinueChat, Chat: o.Chat, Prompt: o.Prompt, Version: o.Version}
	return continueExchange(continueCall{statePath: o.StatePath, request: request, wait: wait, notHere: localterm.CodeChatNotContinuable,
		noID: "AgentLand's host answered without a chat.", stdout: o.Stdout, stderr: o.Stderr})
}

// continueCall is one continue's exchange: the request, the refusal code
// that means "not here" (ContinueNotHere), and what to say for an answer
// without an ID.
type continueCall struct {
	statePath      string
	request        localterm.Request
	wait           time.Duration
	notHere, noID  string
	stdout, stderr io.Writer
}

func continueFail(stderr io.Writer, code int, format string, args ...any) int {
	fmt.Fprintf(stderr, format+"\n", args...)
	return code
}

// continueExchange sends the request on the state's local socket and reads
// the one answer within the call's wait (ContinueWait by default).
func continueExchange(c continueCall) int {
	wait := c.wait
	if wait <= 0 {
		wait = ContinueWait
	}
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", localterm.SocketPath(c.statePath))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED) {
			return continueFail(c.stderr, ContinueNotHere, "AgentLand isn't running.")
		}
		return continueFail(c.stderr, ContinueFailed, "AgentLand's host could not be reached: %v", err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	var reply localterm.Reply
	err = localterm.WriteLine(conn, c.request)
	if err == nil {
		err = localterm.ReadLine(bufio.NewReader(conn), &reply)
	}
	var netErr net.Error
	switch {
	case errors.Is(err, localterm.ErrLineTooLong):
		return continueFail(c.stderr, ContinueFailed, "The prompt is too long.")
	case errors.As(err, &netErr) && netErr.Timeout():
		return continueFail(c.stderr, ContinueFailed, "AgentLand didn't answer in time.")
	case err != nil:
		return continueFail(c.stderr, ContinueFailed, "AgentLand's host did not answer.")
	case reply.Error != nil && reply.Error.Code == c.notHere:
		return continueFail(c.stderr, ContinueNotHere, "%s", reply.Error.Message)
	case reply.Error != nil:
		return continueFail(c.stderr, ContinueFailed, "%s", reply.Error.Message)
	case reply.ID == "":
		return continueFail(c.stderr, ContinueFailed, "%s", c.noID)
	}
	fmt.Fprintln(c.stdout, reply.ID)
	return 0
}
