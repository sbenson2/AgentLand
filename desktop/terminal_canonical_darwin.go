package host

import (
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/unix"
)

// canonicalFolder is the folder's own path as the file system names it: its
// symbolic links resolved and each name in its true case (fcntl F_GETPATH on
// the open folder, so /tmp is /private/tmp and ~/developer is ~/Developer). A
// path that is not a folder, or is gone, is an error. The host reads only its
// workspaces' folders this way, never a registration's (terminalFolderJoiner).
func canonicalFolder(path string) (string, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	defer unix.Close(fd)
	var buffer [unix.PathMax]byte
	// The pointer is converted in the call's argument list, so the buffer
	// stays put until the call returns (unsafe.Pointer rule 4).
	if _, _, errno := unix.Syscall(unix.SYS_FCNTL, uintptr(fd), unix.F_GETPATH, uintptr(unsafe.Pointer(&buffer[0]))); errno != 0 {
		return "", errno
	}
	return filepath.Clean(unix.ByteSliceToString(buffer[:])), nil
}
