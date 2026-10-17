//go:build windows

package host

import (
	"os/exec"
	"syscall"
)

// codexProcessGroup starts the command in a new process group. Windows has no
// group signal, so stopping it ends the Codex process itself.
func codexProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

func codexTerminateGroup(command *exec.Cmd) { codexKillGroup(command) }

func codexKillGroup(command *exec.Cmd) {
	if command.Process != nil {
		_ = command.Process.Kill()
	}
}
