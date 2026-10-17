//go:build darwin

package host

import (
	"context"
	"os"
)

// platformListeners lists this user's listening TCP sockets with the
// system's lsof.
func platformListeners(ctx context.Context) ([]portListener, error) {
	return lsofListeners(ctx, "/usr/sbin/lsof", os.Getuid())
}
