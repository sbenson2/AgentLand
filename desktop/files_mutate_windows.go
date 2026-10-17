package host

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/windows"
)

func openDirectory(root *os.Root, name string) (*os.File, error) {
	directory, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	info, err := directory.Stat()
	if err == nil && !info.IsDir() {
		err = syscall.ENOTDIR
	}
	if err != nil {
		directory.Close()
		return nil, &os.PathError{Op: "open", Path: name, Err: err}
	}
	return directory, nil
}

// Windows has no Trash for this host, so directory-handle renames are unused.
func renameNoReplace(*os.File, string, *os.File, string) error { return errors.ErrUnsupported }

// renameInRoot is best effort on Windows: os.Root has no no-replace rename, so
// the destination is checked first. The caller holds filesMu.
func (h *Host) renameInRoot(root *os.Root, from, to string) error {
	if _, err := root.Lstat(to); err == nil {
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: os.ErrExist}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return root.Rename(from, to)
}

func freeSpace(directory *os.File) (uint64, error) {
	name, err := windows.UTF16PtrFromString(directory.Name())
	if err != nil {
		return 0, err
	}
	var available uint64
	if err := windows.GetDiskFreeSpaceEx(name, &available, nil, nil); err != nil {
		return 0, err
	}
	return available, nil
}

func openTrash(string) (*os.File, error) { return nil, errTrashUnavailable }
