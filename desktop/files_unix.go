//go:build !windows

package host

import (
	"golang.org/x/sys/unix"
	"os"
)

// Nonblocking open prevents a named pipe in a project from occupying a request
// indefinitely before the regular-file check. os.Root still contains traversal.
func openProjectFile(root *os.Root, name string) (*os.File, error) {
	return root.OpenFile(name, os.O_RDONLY|unix.O_NONBLOCK, 0)
}
