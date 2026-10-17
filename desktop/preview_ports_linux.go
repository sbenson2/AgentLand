//go:build linux

package host

import (
	"context"
	"os"
)

// platformListeners lists this user's listening TCP sockets from
// /proc/net/tcp and tcp6; process names are best effort.
func platformListeners(ctx context.Context) ([]portListener, error) {
	return procListeners(ctx, "/proc", os.Getuid())
}
