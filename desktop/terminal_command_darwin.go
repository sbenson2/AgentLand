//go:build darwin

package host

import (
	"bytes"
	"encoding/binary"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

// The foreground command of a terminal (docs/HOST-API.md "Terminals"), read
// from the kernel: never by running a program.

const (
	// terminalCommandCharacters bounds a command, "…" included.
	terminalCommandCharacters = 60
	// processZombie is SZOMB in <sys/proc.h>: a process that ended and has
	// not been reaped.
	processZombie = 5
	// processStartSlack allows for the clock's granularity when a process's
	// start is compared with when the host learned its ID.
	processStartSlack = time.Second
)

// foregroundCommand returns the command line of the process group in the
// foreground of the terminal whose own process is pid, when that is not the
// terminal's own process: the group leader's arguments joined with spaces,
// at most 60 characters. started is when the host learned pid; a process that
// began after that took a reused ID. It returns "" when the terminal's own
// process is in the foreground and whenever anything fails.
//
// routed says pid is a routed agent's job-control leader (internal/termrun):
// the agent runs as the leader's only child, in a process group of its own,
// and is the terminal's own program. Its group in front gives "", and only
// what the agent itself puts in front counts.
func foregroundCommand(pid int, started time.Time, routed bool) string {
	if pid <= 0 {
		return ""
	}
	own, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(own.Proc.P_pid) != pid || own.Proc.P_stat == processZombie {
		return ""
	}
	if processStart(own).After(started.Add(processStartSlack)) {
		return ""
	}
	group := int(own.Eproc.Tpgid)
	if group <= 0 || group == int(own.Eproc.Pgid) || own.Eproc.Tdev == -1 {
		return ""
	}
	leader, err := unix.SysctlKinfoProc("kern.proc.pid", group)
	// The leader must still run and share the terminal.
	if err != nil || int(leader.Proc.P_pid) != group || leader.Proc.P_stat == processZombie || leader.Eproc.Tdev != own.Eproc.Tdev {
		return ""
	}
	if routed && int(leader.Eproc.Ppid) == pid {
		return ""
	}
	data, err := unix.SysctlRaw("kern.procargs2", group)
	if err != nil {
		return ""
	}
	return commandFromProcargs(data)
}

func processStart(info *unix.KinfoProc) time.Time {
	sec, nsec := info.Proc.P_starttime.Unix()
	return time.Unix(sec, nsec)
}

// commandFromProcargs reads kern.procargs2: argc as a 32-bit integer, the
// executable's path, NUL padding, then argc NUL-terminated arguments (and
// the environment, which is never read). The arguments are joined with
// spaces, white space and control characters cleaned as for titles, and
// the result cut to 60 characters with "…".
func commandFromProcargs(data []byte) string {
	if len(data) < 4 {
		return ""
	}
	argc := int(binary.NativeEndian.Uint32(data[:4]))
	rest := data[4:]
	path := bytes.IndexByte(rest, 0)
	if path < 0 {
		return ""
	}
	rest = rest[path:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	var line strings.Builder
	for count := 0; count < argc && len(rest) > 0; count++ {
		end := bytes.IndexByte(rest, 0)
		if end < 0 {
			end = len(rest)
		}
		if line.Len() > 0 {
			line.WriteByte(' ')
		}
		line.Write(rest[:end])
		rest = rest[min(end+1, len(rest)):]
		// Enough for 60 characters; later arguments cannot show.
		if utf8.RuneCountInString(line.String()) > terminalCommandCharacters*4 {
			break
		}
	}
	return capCharacters(collapseTitleSpace(line.String()), terminalCommandCharacters)
}
