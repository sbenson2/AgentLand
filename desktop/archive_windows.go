//go:build windows

package host

import (
	"errors"
	"fmt"
	"os"
)

var errArchiveFreeSpaceUnknown = errors.New("free disk space is not measured on this platform")

// archiveFreeSpace is a stub: Windows builds are CLI development binaries
// only, so capture is never paused for low disk space there.
func archiveFreeSpace(string) (uint64, error) { return 0, errArchiveFreeSpaceUnknown }

// requireArchiveOwner applies the state store's owner-only DACL check.
func requireArchiveOwner(path string, _ os.FileInfo) error {
	if err := rejectWindowsReparsePoint(path); err != nil {
		return err
	}
	return requireWindowsCurrentUserDACL(path)
}

func validateArchiveFile(path string, info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("archive file %q must be a regular private file", path)
	}
	return requireArchiveOwner(path, info)
}

// validateArchiveSidecar checks SQLite's own -wal and -shm files. SQLite
// creates them with inherited permissions, so only their type is checked.
func validateArchiveSidecar(path string, info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("archive file %q must be a regular file", path)
	}
	return rejectWindowsReparsePoint(path)
}

func createArchiveFile(path string, flag int) (*os.File, error) {
	file, err := os.OpenFile(path, flag|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	if err := restrictWindowsPathToCurrentUser(path); err != nil {
		file.Close()
		os.Remove(path)
		return nil, err
	}
	return file, nil
}
