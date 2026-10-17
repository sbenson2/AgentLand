//go:build !windows

package host

import (
	"os/exec"
	"syscall"
)

// codexProcessGroup starts the command in a process group of its own, so the
// commands Codex runs stop together with it.
func codexProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// codexSignalGroup signals the command's process group, or the process alone
// when the group is already gone.
func codexSignalGroup(command *exec.Cmd, signal syscall.Signal) {
	if command.Process == nil {
		return
	}
	if err := syscall.Kill(-command.Process.Pid, signal); err != nil {
		_ = command.Process.Signal(signal)
	}
}

func codexTerminateGroup(command *exec.Cmd) { codexSignalGroup(command, syscall.SIGTERM) }
func codexKillGroup(command *exec.Cmd)      { codexSignalGroup(command, syscall.SIGKILL) }
