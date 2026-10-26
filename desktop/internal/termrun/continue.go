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
	fail := func(code int, format string, args ...any) int {
		fmt.Fprintf(o.Stderr, format+"\n", args...)
		return code
	}
	if o.From == "" {
		return fail(ContinueNotHere, "This isn't an AgentLand terminal.")
	}
	wait := o.Wait
	if wait <= 0 {
		wait = ContinueWait
	}
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", localterm.SocketPath(o.StatePath))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED) {
			return fail(ContinueNotHere, "AgentLand isn't running.")
		}
		return fail(ContinueFailed, "AgentLand's host could not be reached: %v", err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	request := localterm.Request{Op: localterm.OpContinue, From: o.From, Prompt: o.Prompt, Rows: o.Rows, Cols: o.Cols, Version: o.Version}
	var reply localterm.Reply
	err = localterm.WriteLine(conn, request)
	if err == nil {
		err = localterm.ReadLine(bufio.NewReader(conn), &reply)
	}
	var netErr net.Error
	switch {
	case errors.Is(err, localterm.ErrLineTooLong):
		return fail(ContinueFailed, "The prompt is too long.")
	case errors.As(err, &netErr) && netErr.Timeout():
		return fail(ContinueFailed, "AgentLand didn't answer in time.")
	case err != nil:
		return fail(ContinueFailed, "AgentLand's host did not answer.")
	case reply.Error != nil && reply.Error.Code == localterm.CodeNotContinuable:
		return fail(ContinueNotHere, "%s", reply.Error.Message)
	case reply.Error != nil:
		return fail(ContinueFailed, "%s", reply.Error.Message)
	case reply.ID == "":
		return fail(ContinueFailed, "AgentLand's host answered without a terminal.")
	}
	fmt.Fprintln(o.Stdout, reply.ID)
	return 0
}
