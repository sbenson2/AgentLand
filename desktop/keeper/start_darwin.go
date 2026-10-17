//go:build darwin

package keeper

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"

	"agentland/host/internal/localsock"
)

// Start makes sure a keeper answers at SocketPath(StatePath), launching
// `<Executable> terminals serve` in its own session when none does. A child
// that exits before the socket answers (for example because a stopping keeper
// still holds the lock) is launched again until Wait runs out.
func Start(ctx context.Context, options StartOptions) error {
	wait := options.Wait
	if wait <= 0 {
		wait = defaultStartWait
	}
	logPath := options.LogPath
	if logPath == "" {
		logPath = DefaultLogPath()
	}
	socket := SocketPath(options.StatePath)
	if len(socket) > localsock.MaxPath {
		return fmt.Errorf("terminal keeper socket %s: %w (%d bytes, at most %d)", socket, localsock.ErrTooLong, len(socket), localsock.MaxPath)
	}
	deadline := time.Now().Add(wait)

	probe := func() error {
		attempt, cancel := context.WithTimeout(ctx, time.Second)
		defer cancel()
		c, err := Dial(attempt, socket, options.Version)
		if err != nil {
			return err
		}
		return c.Close()
	}
	if err := probe(); err == nil || errors.Is(err, ErrNoCommonProtocol) {
		return err
	}

	devNull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer devNull.Close()

	var exited chan struct{}
	var status int // the last child's exit status, set before exited closes
	launch := func() error {
		cmd := exec.Command(options.Executable, "terminals", "serve", "--state", options.StatePath, "--log", logPath)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = devNull, devNull, devNull
		cmd.Env = keeperEnvironment(os.Environ())
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("start the terminal keeper: %w", err)
		}
		done := make(chan struct{})
		exited = done
		go func() {
			_ = cmd.Wait()
			status = cmd.ProcessState.ExitCode()
			close(done)
		}()
		return nil
	}
	if err := launch(); err != nil {
		return err
	}

	var last error
	for {
		select {
		case <-exited:
			if status != ExitKeeperRunning {
				return fmt.Errorf("%w: the keeper process exited with status %d (see the keeper log)", ErrKeeperDidNotStart, status)
			}
			// Another keeper still holds the lock (it may be stopping): try again.
			if err := launch(); err != nil {
				return err
			}
		default:
		}
		err := probe()
		if err == nil || errors.Is(err, ErrNoCommonProtocol) {
			return err
		}
		last = err
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("%w within %s: %v", ErrKeeperDidNotStart, wait, last)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}
