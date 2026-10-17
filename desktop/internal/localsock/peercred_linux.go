//go:build linux

package localsock

import "golang.org/x/sys/unix"

// peerUID is the user of the process at the other end of a Unix socket
// (SO_PEERCRED).
func peerUID(fd int) (int, error) {
	credentials, err := unix.GetsockoptUcred(fd, unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil {
		return -1, err
	}
	return int(credentials.Uid), nil
}
