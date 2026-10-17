//go:build !darwin

package keeper

import (
	"context"
)

// Serve needs macOS PTYs. Elsewhere it fails at once.
func Serve(context.Context, ServeOptions) error { return errNeedsMacOS }
