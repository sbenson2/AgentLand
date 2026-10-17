//go:build !darwin

package host

import "os"

// vaultDataless says the file's data lives in the cloud for now; only macOS
// marks such files.
func vaultDataless(os.FileInfo) bool { return false }
