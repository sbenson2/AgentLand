//go:build !windows

package host

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func ensurePrivateStateDirectory(path string) error {
	directory := filepath.Clean(filepath.Dir(path))
	if info, err := os.Lstat(directory); err == nil {
		return validatePrivateStateDirectory(info)
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return err
	}
	if err := validatePrivateStateDirectory(info); err != nil {
		return err
	}
	return os.Chmod(directory, 0700)
}

func validatePrivateStateDirectory(info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || info.Mode().Perm()&0022 != 0 {
		return fmt.Errorf("state directory must not be group- or world-writable and must not be a symlink (mode %o); use a dedicated AgentLand directory", info.Mode().Perm())
	}
	return nil
}

func readPrivateState(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("state file must be a regular private file (mode 0600)")
	}
	return os.ReadFile(path)
}

func writePrivateState(path string, data []byte) error {
	if err := ensurePrivateStateDirectory(path); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err = tmp.Chmod(0600); err == nil {
		_, err = tmp.Write(data)
	}
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(name, path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

// lockStateFile takes an exclusive lock on the private file at path without
// waiting (LockState).
func lockStateFile(path string) (func(), error) {
	if err := ensurePrivateStateDirectory(path); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
		return nil, errors.New("state lock must be a regular private file (mode 0600)")
	} else if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrStateBusy
		}
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}, nil
}

func withPrivateStateLock(path string, fn func() error) error {
	if err := ensurePrivateStateDirectory(path); err != nil {
		return err
	}
	lockPath := path + ".lock"
	if info, err := os.Lstat(lockPath); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
		return errors.New("state lock must be a regular private file (mode 0600)")
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err = f.Chmod(0600); err != nil {
		return err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}
