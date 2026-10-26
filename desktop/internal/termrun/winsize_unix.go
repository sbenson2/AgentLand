//go:build darwin || linux

package termrun

import (
	"os"

	"golang.org/x/sys/unix"
)

// WindowSize is the size of the first of files that is a terminal
// (TIOCGWINSZ), or 0, 0 when none is.
func WindowSize(files ...*os.File) (rows, cols int) {
	for _, f := range files {
		if f == nil {
			continue
		}
		size, err := unix.IoctlGetWinsize(int(f.Fd()), unix.TIOCGWINSZ)
		if err == nil && size.Row > 0 && size.Col > 0 {
			return int(size.Row), int(size.Col)
		}
	}
	return 0, 0
}
