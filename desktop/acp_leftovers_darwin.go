//go:build darwin

package host

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// acpProcessStart is the kernel's start time of process pid, in microseconds
// since 1970.
func acpProcessStart(pid int) (int64, bool) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(info.Proc.P_pid) != pid || info.Proc.P_stat == processZombie {
		return 0, false
	}
	return acpStartMicros(info), true
}

func acpStartMicros(info *unix.KinfoProc) int64 {
	sec, nsec := info.Proc.P_starttime.Unix()
	return sec*1_000_000 + nsec/1_000
}

// acpEndLeftover ends the process group of record's process when it is an
// agent a lost host left (acpLeftover), and reports whether it did.
func acpEndLeftover(record acpProcessRecord, agents string) bool {
	if !acpLeftover(record, agents) {
		return false
	}
	return syscall.Kill(-record.Pid, syscall.SIGKILL) == nil
}

// acpLeftover reports whether record's pid is still the process the record
// names (the same start time), leads its own process group, was adopted by
// launchd (the host that started it is gone), is this user's and runs what
// the host ran: for Claude Code and Codex exactly the recorded executable;
// for an ACP agent an executable inside agents, or node running a script
// inside it (the recorded command, when the record has one).
func acpLeftover(record acpProcessRecord, agents string) bool {
	if record.Pid <= 1 {
		return false
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", record.Pid)
	if err != nil || int(info.Proc.P_pid) != record.Pid || info.Proc.P_stat == processZombie {
		return false
	}
	if acpStartMicros(info) != record.Start || int(info.Eproc.Pgid) != record.Pid || info.Eproc.Ppid != 1 || int(info.Eproc.Pcred.P_ruid) != os.Getuid() {
		return false
	}
	data, err := unix.SysctlRaw("kern.procargs2", record.Pid)
	if err != nil {
		return false
	}
	executable, argv := acpProcessArguments(data)
	if record.Executable != "" {
		return filepath.IsAbs(record.Executable) && executable == record.Executable
	}
	if agents == "" {
		return false
	}
	if acpInsideFolder(executable, agents) {
		return true
	}
	// npm installs run as node, with their script as its first argument.
	if filepath.Base(executable) != "node" {
		return false
	}
	script := acpNodeScript(argv)
	return acpInsideFolder(script, agents) && (record.Command == "" || script == record.Command)
}

// acpProcessArguments reads kern.procargs2: argc as a 32-bit integer, the
// executable's path as the process was started with it (links not
// followed), padding, then argc arguments, each ended by a zero byte.
func acpProcessArguments(data []byte) (string, []string) {
	if len(data) < 4 {
		return "", nil
	}
	argc := int(binary.NativeEndian.Uint32(data[:4]))
	rest := data[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return "", nil
	}
	executable := string(rest[:end])
	rest = bytes.TrimLeft(rest[end:], "\x00")
	var argv []string
	for len(argv) < argc && len(argv) < 4096 {
		end := bytes.IndexByte(rest, 0)
		if end < 0 {
			break
		}
		argv = append(argv, string(rest[:end]))
		rest = rest[end+1:]
	}
	return executable, argv
}

// acpNodeScript is the script node runs: its first argument that is not an
// option.
func acpNodeScript(argv []string) string {
	for index, argument := range argv {
		if index == 0 || strings.HasPrefix(argument, "-") {
			continue
		}
		return argument
	}
	return ""
}

// acpInsideFolder reports whether path lies inside folder, as given or with
// folder's links resolved.
func acpInsideFolder(path, folder string) bool {
	if !filepath.IsAbs(path) || !filepath.IsAbs(folder) {
		return false
	}
	folders := []string{folder}
	if resolved, err := filepath.EvalSymlinks(folder); err == nil {
		folders = append(folders, resolved)
	}
	for _, candidate := range folders {
		relative, err := filepath.Rel(candidate, path)
		if err == nil && relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}
