//go:build !windows

package host

import (
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// archiveFreeSpace reports the bytes this user may still write on the file
// system that holds directory.
func archiveFreeSpace(directory string) (uint64, error) {
	var stat unix.Statfs_t
	if err := unix.Statfs(directory, &stat); err != nil {
		return 0, err
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}

// requireArchiveOwner refuses an archive path that another account owns.
func requireArchiveOwner(path string, info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int64(stat.Uid) != int64(os.Geteuid()) {
		return fmt.Errorf("archive path %q must be owned by the current user", path)
	}
	return nil
}

// validateArchiveFile accepts only a regular file (never a symlink) that this
// user owns and nobody else can read or write.
func validateArchiveFile(path string, info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("archive file %q must be a regular private file (mode 0600)", path)
	}
	return requireArchiveOwner(path, info)
}

// validateArchiveSidecar checks SQLite's own -wal and -shm files, which it
// creates with the database file's mode.
func validateArchiveSidecar(path string, info os.FileInfo) error {
	return validateArchiveFile(path, info)
}

// createArchiveFile creates a new 0600 file. O_EXCL refuses any existing name,
// including a planted symlink.
func createArchiveFile(path string, flag int) (*os.File, error) {
	file, err := os.OpenFile(path, flag|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	if err := file.Chmod(0600); err != nil {
		file.Close()
		os.Remove(path)
		return nil, err
	}
	return file, nil
}
