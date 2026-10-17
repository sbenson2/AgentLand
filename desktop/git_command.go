package host

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Every Git process the host starts gets a fixed environment: inherited GIT_*
// variables are dropped, system and global configuration are hidden (except
// for the one read of the user's commit identity and signing setting), hooks,
// fsmonitor and automatic maintenance are off, pathspecs are literal, and no
// editor or prompt can open. Output is bounded and Git's own messages are
// kept only to choose a safe error code.

const (
	gitReadTimeout = 8 * time.Second
	gitStderrLimit = 16 << 10
)

var (
	errGitTimeout     = errors.New("git did not finish in time")
	errGitOutputLimit = errors.New("git output limit exceeded")
)

type gitCall struct {
	directory   string
	args        []string
	timeout     time.Duration
	stdoutLimit int
	stdin       io.Reader
	env         []string
	// userConfig lets this call read the user's global configuration; only
	// read-only "git config --global" queries set it.
	userConfig     bool
	userConfigPath string
	// strictOutput stops Git and fails the call when stdout exceeds its limit.
	strictOutput bool
}

type gitOutcome struct {
	stdout   []byte
	stderr   []byte // the last 16 KiB; never returned to clients
	exitCode int    // -1 when Git did not exit normally
	timedOut bool
	overflow bool
	err      error // nil only when Git exited 0 within its limits
}

// boundedOutput keeps the first limit bytes and drains the rest.
type boundedOutput struct {
	data     []byte
	limit    int
	overflow bool
	onFull   func()
}

func (b *boundedOutput) Write(p []byte) (int, error) {
	room := b.limit - len(b.data)
	if len(p) <= room {
		b.data = append(b.data, p...)
		return len(p), nil
	}
	b.data = append(b.data, p[:max(room, 0)]...)
	if !b.overflow {
		b.overflow = true
		if b.onFull != nil {
			b.onFull()
		}
	}
	return len(p), nil
}

// tailOutput keeps the last limit bytes.
type tailOutput struct {
	data  []byte
	limit int
}

func (t *tailOutput) Write(p []byte) (int, error) {
	n := len(p)
	if len(p) >= t.limit {
		t.data = append(t.data[:0], p[len(p)-t.limit:]...)
		return n, nil
	}
	if excess := len(t.data) + len(p) - t.limit; excess > 0 {
		t.data = append(t.data[:0], t.data[excess:]...)
	}
	t.data = append(t.data, p...)
	return n, nil
}

func gitCommandArgs(directory string, args []string) []string {
	return append([]string{"-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-C", directory}, args...)
}

// gitEnvironment is the host environment without GIT_* variables (such as a
// GIT_DIR, GIT_INDEX_FILE or GIT_AUTHOR_NAME the host was started with) plus
// the fixed settings.
func gitEnvironment(userConfig bool, userConfigPath string, extra []string) []string {
	inherited := os.Environ()
	env := make([]string, 0, len(inherited)+len(extra)+8)
	for _, variable := range inherited {
		key, _, _ := strings.Cut(variable, "=")
		if strings.HasPrefix(strings.ToUpper(key), "GIT_") {
			continue
		}
		env = append(env, variable)
	}
	env = append(env, "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_NOSYSTEM=1", "GIT_LITERAL_PATHSPECS=1", "GIT_EDITOR=:", "LC_ALL=C")
	switch {
	case !userConfig:
		env = append(env, "GIT_CONFIG_GLOBAL=/dev/null")
	case userConfigPath != "":
		env = append(env, "GIT_CONFIG_GLOBAL="+userConfigPath)
	}
	return append(env, extra...)
}

// runGitCall runs one Git command within its timeout. A timeout is reported as
// such, because the command may or may not have taken effect.
func runGitCall(parent context.Context, call gitCall) gitOutcome {
	if call.timeout <= 0 {
		call.timeout = gitReadTimeout
	}
	ctx, cancelTimeout := context.WithTimeout(parent, call.timeout)
	defer cancelTimeout()
	running, stop := context.WithCancel(ctx)
	defer stop()
	command := exec.CommandContext(running, "git", gitCommandArgs(call.directory, call.args)...)
	command.Env = gitEnvironment(call.userConfig, call.userConfigPath, call.env)
	command.Stdin = call.stdin
	command.WaitDelay = 2 * time.Second
	stdout := &boundedOutput{limit: call.stdoutLimit}
	if call.strictOutput {
		stdout.onFull = stop
	}
	stderr := &tailOutput{limit: gitStderrLimit}
	command.Stdout, command.Stderr = stdout, stderr
	runErr := command.Run()
	out := gitOutcome{stdout: stdout.data, stderr: stderr.data, exitCode: -1, overflow: stdout.overflow}
	if command.ProcessState != nil {
		out.exitCode = command.ProcessState.ExitCode()
	}
	switch {
	case runErr == nil && !(out.overflow && call.strictOutput):
		// Git finished within its limits, even if the context ends right after.
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		out.timedOut, out.err = true, errGitTimeout
	case out.overflow && call.strictOutput:
		out.err = errGitOutputLimit
	default:
		out.err = runErr
	}
	return out
}
