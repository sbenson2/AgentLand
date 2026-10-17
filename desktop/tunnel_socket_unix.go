//go:build darwin || linux

package host

import (
	"errors"
	"fmt"
	"net"

	"agentland/host/internal/localsock"
)

func tunnelSocketSupported() bool { return true }

// sameUserPeer refuses a connection unless the kernel reports that the
// connecting process runs as this user.
var sameUserPeer = localsock.SameUserPeer

// listenTunnelSocket binds the tunnel socket at path (docs/HOST-API.md, "The
// tunnel socket") with localsock.Listen, wording its refusals for the tunnel.
func listenTunnelSocket(path string) (*tunnelSocket, error) {
	socket, err := localsock.Listen(path)
	switch {
	case errors.Is(err, localsock.ErrNotSocket):
		return nil, fmt.Errorf("%s exists and is not a socket; remove it", path)
	case errors.Is(err, localsock.ErrInUse):
		return nil, fmt.Errorf("another host serves the tunnel socket %s", path)
	case errors.Is(err, localsock.ErrTooLong):
		return nil, errors.New("the tunnel socket's folder is too long for a Unix socket")
	case err != nil:
		return nil, err
	}
	return &tunnelSocket{listener: socket.Listener, path: socket.Path, info: socket.Info, checkPeer: func(conn net.Conn) error { return sameUserPeer(conn) }}, nil
}
