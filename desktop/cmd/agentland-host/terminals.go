package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	host "agentland/host"
	"agentland/host/internal/shellhook"
	"agentland/host/internal/termrun"
	"agentland/host/keeper"
)

// terminalsUsage names the terminals subcommands.
const terminalsUsage = "usage: agentland-host terminals <serve|stop|run|attach|hook> …"

const (
	terminalsRunUsage    = "usage: agentland-host terminals run [--state <host.json>] -- <command> [args…]"
	terminalsAttachUsage = "usage: agentland-host terminals attach [--state <host.json>] <id>"
	terminalsHookUsage   = "usage: agentland-host terminals hook <on|off|pause|status> [--state <host.json>] [--executable <path>]"
)

// terminalsCommand is `terminals serve|stop --state <host.json>`, the
// terminal keeper's own process and the way to end it; `terminals run`,
// which runs a coding agent typed in Terminal.app as an AgentLand terminal;
// `terminals attach`, which opens a running terminal in a window; and
// `terminals hook`, the Mac app's switch for the zsh hook that routes those
// agents into `terminals run`.
func terminalsCommand(args []string) error {
	if len(args) == 0 {
		return errors.New(terminalsUsage)
	}
	switch args[0] {
	case termrun.LeadCommand:
		// The job-control leader `terminals run` starts; not for people.
		os.Exit(termrun.Lead(args[1:]))
	case "run":
		state, name, rest, err := parseRunArgs(args[1:])
		if errors.Is(err, flag.ErrHelp) {
			return nil
		} else if err != nil {
			return err
		}
		dir, _ := os.Getwd() // gone: the command still runs, and AgentLand declines it
		// It ends as the agent did, by its signal too (termrun.Exit).
		termrun.Exit(termrun.RunStatus(termrun.Options{
			StatePath: state, Version: version, Name: name, Args: rest,
			Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr,
			Env: os.Environ(), Dir: dir,
		}))
	case "attach":
		fs := flag.NewFlagSet("terminals attach", flag.ContinueOnError)
		state := stateFlag(fs)
		if err := fs.Parse(args[1:]); errors.Is(err, flag.ErrHelp) {
			return nil
		} else if err != nil {
			return err
		}
		if fs.NArg() != 1 {
			return errors.New(terminalsAttachUsage)
		}
		os.Exit(termrun.Attach(termrun.AttachOptions{
			StatePath: *state, Version: version, ID: fs.Arg(0),
			Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr,
		}))
	case "hook":
		// The Mac app shows what goes to stderr as it is, so without "error:".
		if err := hookCommand(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return nil
	}
	fs := flag.NewFlagSet("terminals "+args[0], flag.ContinueOnError)
	state := stateFlag(fs)
	switch args[0] {
	case "serve":
		logPath := fs.String("log", keeper.DefaultLogPath(), "keeper log file")
		if err := fs.Parse(args[1:]); errors.Is(err, flag.ErrHelp) {
			return nil
		} else if err != nil {
			return err
		}
		if err := keeper.SupportError(runtime.GOOS); err != nil {
			return err
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		err := keeper.Serve(ctx, keeper.ServeOptions{StatePath: *state, LogPath: *logPath, Version: version})
		if errors.Is(err, keeper.ErrKeeperRunning) {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(keeper.ExitKeeperRunning)
		}
		return err
	case "stop":
		if err := fs.Parse(args[1:]); errors.Is(err, flag.ErrHelp) {
			return nil
		} else if err != nil {
			return err
		}
		return stopKeeper(*state)
	default:
		return errors.New(terminalsUsage)
	}
}

// hookCommand is `terminals hook <on|off|pause|status>`: on writes the hook
// for this program (or --executable) and the host's agents, turns routing on
// and adds the block to ~/.zshrc; off takes all of it away; pause turns
// routing off and keeps the block; status prints the switch and the block as
// JSON (internal/shellhook).
func hookCommand(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New(terminalsHookUsage)
	}
	action := args[0]
	fs := flag.NewFlagSet("terminals hook "+action, flag.ContinueOnError)
	state := stateFlag(fs)
	executable := fs.String("executable", "", "the agentland-host the hook runs; this program by default")
	// A bad flag's message goes to stderr once, from the caller, without the
	// flags' list after it: the Mac app shows stderr as it is. -h still
	// prints the list.
	var flagOutput strings.Builder
	fs.SetOutput(&flagOutput)
	if err := fs.Parse(args[1:]); errors.Is(err, flag.ErrHelp) {
		fmt.Fprint(os.Stderr, flagOutput.String())
		return nil
	} else if err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return errors.New(terminalsHookUsage)
	}
	options := shellhook.Options{StatePath: *state, Executable: *executable, Programs: host.RoutedAgentPrograms()}
	switch action {
	case "on":
		if options.Executable == "" {
			self, err := os.Executable()
			if err != nil {
				return fmt.Errorf("find this program for the hook: %w", err)
			}
			if options.Executable, err = filepath.EvalSymlinks(self); err != nil {
				return fmt.Errorf("find this program for the hook: %w", err)
			}
		}
		return shellhook.On(options)
	case "off":
		return shellhook.Off(options)
	case "pause":
		return shellhook.Pause(options)
	case "status":
		status, err := shellhook.Get(options)
		if err != nil {
			return err
		}
		return json.NewEncoder(stdout).Encode(status)
	}
	return errors.New(terminalsHookUsage)
}

// parseRunArgs reads `terminals run`'s own flags. Everything from the
// command on is the command's, untouched: after "--", or from the first
// argument that is not a flag.
func parseRunArgs(args []string) (state, name string, rest []string, err error) {
	fs := flag.NewFlagSet("terminals run", flag.ContinueOnError)
	statePath := stateFlag(fs)
	if err := fs.Parse(args); err != nil {
		return "", "", nil, err
	}
	if fs.NArg() == 0 || fs.Arg(0) == "" {
		return "", "", nil, errors.New(terminalsRunUsage)
	}
	return *statePath, fs.Arg(0), fs.Args()[1:], nil
}

// stopKeeper ends every terminal and the keeper, then waits for its lock.
func stopKeeper(state string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	c, err := keeper.Dial(ctx, keeper.SocketPath(state), version)
	if err != nil {
		if errors.Is(err, keeper.ErrNoCommonProtocol) {
			return err
		}
		// No socket answers, but a keeper that is stopping may still hold the lock.
		release, lockErr := keeper.TryLock(state)
		if lockErr == nil {
			release()
			fmt.Println("no terminal keeper is running")
			return nil
		}
		if !errors.Is(lockErr, keeper.ErrKeeperRunning) {
			return lockErr
		}
	} else {
		defer c.Close()
		if err := c.StopAll(ctx); err != nil {
			return err
		}
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		release, err := keeper.TryLock(state)
		if err == nil {
			release()
			fmt.Println("terminal keeper stopped")
			return nil
		}
		if !errors.Is(err, keeper.ErrKeeperRunning) {
			return err
		}
		if time.Now().After(deadline) {
			return errors.New("the terminal keeper did not stop within 10 seconds")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
