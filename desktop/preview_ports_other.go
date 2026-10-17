//go:build !darwin && !linux

package host

import "context"

// platformListeners finds nothing here: Windows has neither lsof nor /proc,
// and AgentLand does not claim Windows desktop support. With no discovered
// ports, previews list nothing and no preview session can be created.
func platformListeners(context.Context) ([]portListener, error) {
	return nil, nil
}
