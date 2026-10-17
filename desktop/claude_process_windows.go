//go:build windows

package host

import (
	"os"
	"syscall"
)

// Windows has no process groups that can be signalled like Unix ones. The
// CLI gets its own console process group and is ended by its handle; tools
// it started are not tracked there.
func claudeProcessAttributes() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

func claudeSignalGroup(process *os.Process, kill bool) {
	if kill {
		_ = process.Kill()
	}
}

func claudeReapGroup(int) {}
