//go:build darwin

package localsock

import "golang.org/x/sys/unix"

// peerUID is the user of the process at the other end of a Unix socket
// (LOCAL_PEERCRED).
func peerUID(fd int) (int, error) {
	credentials, err := unix.GetsockoptXucred(fd, unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	if err != nil {
		return -1, err
	}
	return int(credentials.Uid), nil
}
