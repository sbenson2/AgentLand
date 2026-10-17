//go:build !darwin && !linux

package host

// The tunnel socket needs Unix sockets with peer credentials (macOS, Linux);
// elsewhere, Windows included, --tunnel-socket fails the start.

func tunnelSocketSupported() bool { return false }

func listenTunnelSocket(string) (*tunnelSocket, error) { return nil, errTunnelUnsupported }
