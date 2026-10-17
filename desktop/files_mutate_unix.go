//go:build !windows

package host

import (
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

// openDirectory opens a directory through the root. A special file swapped in
// for it fails at once instead of blocking the request.
func openDirectory(root *os.Root, name string) (*os.File, error) {
	return root.OpenFile(name, os.O_RDONLY|unix.O_DIRECTORY|unix.O_NONBLOCK, 0)
}

// renameNoReplace renames between two open directories. Both names are single
// path elements resolved by the kernel against those directories, so a symlink
// swapped into either path cannot redirect the rename.
func renameNoReplace(fromDir *os.File, fromName string, toDir *os.File, toName string) error {
	err := withDirectoryDescriptors(fromDir, toDir, func(from, to int) error {
		return renameatNoReplace(from, fromName, to, toName)
	})
	if err != nil {
		return &os.LinkError{Op: "rename", Old: fromName, New: toName, Err: err}
	}
	return nil
}

func withDirectoryDescriptors(first, second *os.File, operation func(int, int) error) error {
	firstConn, err := first.SyscallConn()
	if err != nil {
		return err
	}
	secondConn, err := second.SyscallConn()
	if err != nil {
		return err
	}
	var result error
	err = firstConn.Control(func(a uintptr) {
		if controlErr := secondConn.Control(func(b uintptr) { result = operation(int(a), int(b)) }); controlErr != nil {
			result = controlErr
		}
	})
	if err != nil {
		return err
	}
	return result
}

// renameatChecked is the fallback where the kernel or file system cannot
// refuse replacement itself: it checks the destination, then renames. The
// caller holds filesMu, so other AgentLand changes cannot slip in between.
func renameatChecked(from int, fromName string, to int, toName string) error {
	var stat unix.Stat_t
	if err := unix.Fstatat(to, toName, &stat, unix.AT_SYMLINK_NOFOLLOW); err == nil {
		return unix.EEXIST
	} else if err != unix.ENOENT {
		return err
	}
	return unix.Renameat(from, fromName, to, toName)
}

// renameInRoot moves from to to inside root without replacing anything.
func (h *Host) renameInRoot(root *os.Root, from, to string) error {
	fromDir, err := openDirectory(root, filepath.Dir(from))
	if err != nil {
		return err
	}
	defer fromDir.Close()
	toDir, err := openDirectory(root, filepath.Dir(to))
	if err != nil {
		return err
	}
	defer toDir.Close()
	return h.mutations.renameNoReplace(fromDir, filepath.Base(from), toDir, filepath.Base(to))
}

// freeSpace reports the bytes available to this user on the directory's volume.
func freeSpace(directory *os.File) (uint64, error) {
	conn, err := directory.SyscallConn()
	if err != nil {
		return 0, err
	}
	var stat unix.Statfs_t
	var statErr error
	if err := conn.Control(func(fd uintptr) { statErr = unix.Fstatfs(int(fd), &stat) }); err != nil {
		return 0, err
	}
	if statErr != nil {
		return 0, statErr
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}

// openTrash opens the Trash only when it is a real directory (not a symlink)
// owned by this user, and the directory opened is the one that was checked.
func openTrash(location string) (*os.File, error) {
	checked, err := os.Lstat(location)
	if err != nil {
		return nil, err
	}
	if !checked.IsDir() || !ownedByCurrentUser(checked) {
		return nil, errTrashUnavailable
	}
	trash, err := os.OpenFile(location, os.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	opened, err := trash.Stat()
	if err != nil || !os.SameFile(checked, opened) || !ownedByCurrentUser(opened) {
		trash.Close()
		return nil, errTrashUnavailable
	}
	return trash, nil
}

func ownedByCurrentUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid()
}
