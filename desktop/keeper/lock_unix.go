//go:build unix

package keeper

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

// TryLock takes the keeper lock for statePath without waiting and writes this
// process's pid into it. It returns ErrKeeperRunning while another holder
// has it. A caller that only checks for a keeper releases it at once.
func TryLock(statePath string) (release func(), err error) {
	path := LockPath(statePath)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, fmt.Errorf("terminal keeper lock: %w", err)
	}
	fail := func(err error) (func(), error) {
		f.Close()
		return nil, fmt.Errorf("terminal keeper lock %s: %w", path, err)
	}
	info, err := f.Stat()
	if err != nil {
		return fail(err)
	}
	if err := checkOwnFile(info); err != nil {
		return fail(err)
	}
	if err := f.Chmod(0o600); err != nil {
		return fail(err)
	}
	fd := int(f.Fd())
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrKeeperRunning
		}
		return nil, fmt.Errorf("terminal keeper lock %s: %w", path, err)
	}
	if err := f.Truncate(0); err == nil {
		_, err = f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
	}
	if err != nil {
		_ = unix.Flock(fd, unix.LOCK_UN)
		return fail(err)
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			_ = unix.Flock(fd, unix.LOCK_UN)
			_ = f.Close()
		})
	}, nil
}

// checkOwnFile refuses anything but a regular file of this user.
func checkOwnFile(info os.FileInfo) error {
	if !info.Mode().IsRegular() {
		return errors.New("not a regular file")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Getuid() {
		return errors.New("owned by another user")
	}
	return nil
}
