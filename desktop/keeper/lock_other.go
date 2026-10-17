//go:build !unix

package keeper

// TryLock needs flock, and the keeper runs only on macOS.
func TryLock(string) (func(), error) { return nil, errNeedsMacOS }
