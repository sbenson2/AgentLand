//go:build !windows

package shellhook

import (
	"io/fs"
	"syscall"
)

// linkCount is how many hard links the file info describes has.
func linkCount(info fs.FileInfo) uint64 {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(stat.Nlink)
	}
	return 1
}
