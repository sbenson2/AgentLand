//go:build !windows

package host

import (
	"os"
	"syscall"
)

// claudeProcessAttributes starts Claude Code as the leader of its own process
// group, so the tools it runs can be ended with it.
func claudeProcessAttributes() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}

// claudeSignalGroup signals the group led by process, never anything else.
func claudeSignalGroup(process *os.Process, kill bool) {
	signal := syscall.SIGTERM
	if kill {
		signal = syscall.SIGKILL
	}
	_ = syscall.Kill(-process.Pid, signal)
}

// claudeReapGroup ends what is left of the group right after its leader
// exited.
func claudeReapGroup(pid int) {
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}
