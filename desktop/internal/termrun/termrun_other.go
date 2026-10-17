//go:build !darwin

package termrun

import (
	"errors"
	"os"
	"os/exec"
	"os/signal"
)

// RunStatus runs the command as it is: AgentLand terminals need macOS. With
// no Exec it runs the command as a child and returns its status, since not
// every system can replace a process.
func RunStatus(o Options) Status { return Status{Code: run(o)} }

// Exit ends this process with the status's code.
func Exit(s Status) { os.Exit(s.Code) }

func run(o Options) int {
	argv := append([]string{o.Name}, o.Args...)
	if o.Exec != nil {
		if err := o.Exec(o.Name, argv, o.Env); err != nil {
			say(o.Stderr, o.Name+": "+err.Error()+"\n")
			return 126
		}
		return 0
	}
	cmd := exec.Command(o.Name, o.Args...)
	cmd.Env, cmd.Dir = o.Env, o.Dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = o.Stdin, o.Stdout, o.Stderr
	// An interrupt is the command's to handle; caught here rather than
	// ignored, so the command does not inherit an ignored one.
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	defer signal.Stop(interrupts)
	err := cmd.Run()
	var exitErr *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &exitErr):
		if code := exitErr.ExitCode(); code >= 0 {
			return code
		}
		return 1
	case errors.Is(err, exec.ErrNotFound):
		say(o.Stderr, o.Name+": command not found\n")
		return 127
	default:
		say(o.Stderr, o.Name+": "+err.Error()+"\n")
		return 126
	}
}

// Attach needs macOS.
func Attach(o AttachOptions) int {
	say(o.Stderr, "terminals need macOS\n")
	return 1
}

// Lead needs macOS.
func Lead(args []string) int {
	say(os.Stderr, "terminals need macOS\n")
	return 1
}
