//go:build darwin

package host

import (
	"os"
	"syscall"
)

// sfDataless is SF_DATALESS (sys/stat.h): the file's data is not on this Mac,
// such as an iCloud Drive file the system evicted. Reading it would wait for
// a download.
const sfDataless = 0x40000000

// vaultDataless says the file's data lives in the cloud for now.
func vaultDataless(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Flags&sfDataless != 0
}
