// Package termrun is `agentland-host terminals run` and `terminals attach`
// (docs/HOST-API.md, "Terminals started in Terminal on the Mac").
//
// Run starts a coding agent typed in Terminal.app as an AgentLand terminal:
// it registers with the host on its private local socket, starts the agent
// on a new PTY under a job-control leader of its own (Lead, which keeps
// Ctrl-Z working), hands the PTY's master to the terminal keeper, and drives
// the window straight from the keeper. The agent stays a
// process of the Terminal.app window, so macOS keeps treating it as
// Terminal's for privacy permissions, and it runs with the shell's own
// environment. Whatever fails before the agent starts, Run starts the real
// command as the shell would have, within about a second. Once it has
// started, the window keeps working whatever happens to the host or keeper.
//
// Attach opens a terminal the keeper already runs in a window, with no
// fallback: it prints one line and returns when the keeper goes away.
package termrun

import (
	"os"
	"syscall"
)

// Status is how the command RunStatus ran ended: Code is the status a shell
// gives it (128 plus the signal that ended it, if one did), and Signal is
// the signal that ended the agent, which the CLI ends by too (Exit), or 0.
type Status struct {
	Code   int
	Signal syscall.Signal
}

// Run is RunStatus's code alone.
func Run(o Options) int { return RunStatus(o).Code }

// Options is one `terminals run`: the command as the person typed it, and
// the terminal, environment and folder of the shell that ran it.
type Options struct {
	// StatePath is the host's state file; the sockets sit beside it.
	StatePath string
	// Version is this build's version, which must be the host's.
	Version string
	// Name is the command as typed and Args its arguments, unchanged.
	Name string
	Args []string
	// Stdin, Stdout and Stderr are the caller's terminal.
	Stdin, Stdout, Stderr *os.File
	// Env is the caller's environment and Dir its folder.
	Env []string
	Dir string
	// Exec replaces this process with the real command. Nil means
	// syscall.Exec.
	Exec func(path string, argv, env []string) error
	// Signals delivers the signals Run handles. Nil means Run asks for
	// SIGWINCH, SIGHUP, SIGTERM, SIGINT, SIGQUIT and SIGCONT itself.
	Signals <-chan os.Signal

	// suspend stops this process for the shell's job control and returns
	// once it is continued. Nil means SIGTSTP to itself; tests that run Run
	// in their own process replace it.
	suspend func()
}

// AttachOptions is one `terminals attach`: the terminal ID, and the window
// to open it in.
type AttachOptions struct {
	StatePath, Version, ID string
	Stdin, Stdout, Stderr  *os.File
	// Signals is as for Options.
	Signals <-chan os.Signal
}

// LeadCommand is the hidden `terminals` subcommand that runs the job-control
// leader (Lead): `agentland-host terminals _lead -- <path> <argv0> [args…]`.
// It is AgentLand's own and is never listed in the usage.
const LeadCommand = "_lead"

// terminalVariable is set to the terminal's ID in every AgentLand terminal.
// A command started where it is set is not routed again.
const terminalVariable = "AGENTLAND_TERMINAL"

// say writes text to f, when there is one. A window that is gone takes
// nothing, and that is not an error.
func say(f *os.File, text string) {
	if f != nil {
		_, _ = f.WriteString(text)
	}
}
