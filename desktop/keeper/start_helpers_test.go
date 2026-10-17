//go:build darwin

package keeper

import "golang.org/x/sys/unix"

func getsid(pid int) (int, error) { return unix.Getsid(pid) }

func processAlive(pid int) bool { return unix.Kill(pid, 0) != unix.ESRCH }
