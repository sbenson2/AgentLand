//go:build darwin

package termrun

import (
	"errors"
	"io"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// The caller's terminal is reached through SyscallConn, never Fd: Fd puts a
// file Go made non-blocking back into blocking mode, and that mode is shared
// with the shell.

func control(f *os.File, fn func(fd int)) error {
	raw, err := f.SyscallConn()
	if err != nil {
		return err
	}
	return raw.Control(func(fd uintptr) { fn(int(fd)) })
}

func termiosOf(f *os.File) (*unix.Termios, error) {
	var t *unix.Termios
	var ioctlErr error
	if err := control(f, func(fd int) { t, ioctlErr = unix.IoctlGetTermios(fd, unix.TIOCGETA) }); err != nil {
		return nil, err
	}
	return t, ioctlErr
}

// setTermios sets f's settings. A process continued in the background stops
// here (SIGTTOU) until the shell's fg; an interrupted call is made again.
func setTermios(f *os.File, t *unix.Termios) error {
	var ioctlErr error
	if err := control(f, func(fd int) {
		for {
			if ioctlErr = unix.IoctlSetTermios(fd, unix.TIOCSETA, t); ioctlErr != unix.EINTR {
				return
			}
		}
	}); err != nil {
		return err
	}
	return ioctlErr
}

// isTerminal reports whether f is a terminal.
func isTerminal(f *os.File) bool {
	if f == nil {
		return false
	}
	_, err := termiosOf(f)
	return err == nil
}

// makeRaw puts the terminal f in raw mode, as cfmakeraw does: every key,
// Ctrl-C and Ctrl-Z among them, reaches the program as a byte, and output
// passes unchanged. restore puts back the settings f had.
func makeRaw(f *os.File) (restore func(), err error) {
	saved, err := termiosOf(f)
	if err != nil {
		return nil, err
	}
	raw := *saved
	raw.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	raw.Oflag &^= unix.OPOST
	raw.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	raw.Cflag &^= unix.CSIZE | unix.PARENB
	raw.Cflag |= unix.CS8
	raw.Cc[unix.VMIN] = 1
	raw.Cc[unix.VTIME] = 0
	if err := setTermios(f, &raw); err != nil {
		return nil, err
	}
	return func() { _ = setTermios(f, saved) }, nil
}

var (
	errReadTimeout = errors.New("termrun: no input in time")
	errReadStopped = errors.New("termrun: input stopped")
)

// ttyInput reads the caller's terminal so that the reading can stop: Run and
// Attach return without leaving a read behind that would take the shell's
// next keystrokes. It waits with select, which macOS supports for terminals,
// and leaves the terminal's blocking mode alone.
type ttyInput struct {
	f            *os.File
	stopR, stopW *os.File
	once         sync.Once
}

func newTTYInput(f *os.File) (*ttyInput, error) {
	stopR, stopW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	return &ttyInput{f: f, stopR: stopR, stopW: stopW}, nil
}

// stop wakes a read waiting now and fails every read after it.
func (in *ttyInput) stop() {
	in.once.Do(func() { in.stopW.Close() })
}

// close releases the stop pipe once no read runs.
func (in *ttyInput) close() {
	in.stop()
	in.stopR.Close()
}

// read reads what is waiting, up to len(p). It waits at most timeout, or
// without limit when timeout is negative, then fails with errReadTimeout. It
// answers io.EOF when the terminal hung up, and errReadStopped after stop.
func (in *ttyInput) read(p []byte, timeout time.Duration) (n int, err error) {
	var readErr error
	ctlErr := control(in.f, func(fd int) {
		ctlErr := control(in.stopR, func(stop int) { n, readErr = selectRead(fd, stop, p, timeout) })
		if ctlErr != nil {
			readErr = ctlErr
		}
	})
	if ctlErr != nil {
		return 0, ctlErr
	}
	return n, readErr
}

func selectRead(fd, stop int, p []byte, timeout time.Duration) (int, error) {
	if fd >= unix.FD_SETSIZE || stop >= unix.FD_SETSIZE {
		return readOnce(fd, p) // select cannot watch it; a plain read still works
	}
	var deadline time.Time
	if timeout >= 0 {
		deadline = time.Now().Add(timeout)
	}
	for {
		var set unix.FdSet
		set.Set(fd)
		set.Set(stop)
		var wait *unix.Timeval
		if timeout >= 0 {
			tv := unix.NsecToTimeval(max(time.Until(deadline), 0).Nanoseconds())
			wait = &tv
		}
		ready, err := unix.Select(max(fd, stop)+1, &set, nil, nil, wait)
		switch {
		case err == unix.EINTR:
			continue
		case err != nil:
			return 0, err
		case set.IsSet(stop):
			return 0, errReadStopped
		case ready == 0:
			return 0, errReadTimeout
		case set.IsSet(fd):
			n, err := readOnce(fd, p)
			if err == unix.EAGAIN {
				continue // another reader took it
			}
			return n, err
		}
	}
}

func readOnce(fd int, p []byte) (int, error) {
	for {
		n, err := unix.Read(fd, p)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return 0, err
		}
		if n == 0 {
			return 0, io.EOF
		}
		return n, nil
	}
}
