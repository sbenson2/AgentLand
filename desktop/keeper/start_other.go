//go:build !darwin

package keeper

import "context"

// Start needs macOS. Elsewhere it fails at once.
func Start(context.Context, StartOptions) error { return errNeedsMacOS }
