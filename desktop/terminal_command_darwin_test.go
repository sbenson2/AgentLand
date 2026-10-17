//go:build darwin

package host

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

func procargs(path string, args []string, environment ...string) []byte {
	var data bytes.Buffer
	count := make([]byte, 4)
	binary.NativeEndian.PutUint32(count, uint32(len(args)))
	data.Write(count)
	data.WriteString(path)
	data.Write(make([]byte, 7)) // the terminating NUL and padding
	for _, value := range append(append([]string{}, args...), environment...) {
		data.WriteString(value)
		data.WriteByte(0)
	}
	return data.Bytes()
}

func TestCommandFromProcargs(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"arguments joined", procargs("/usr/bin/vim", []string{"vim", "notes.md"}, "SECRET=value"), "vim notes.md"},
		{"environment never read", procargs("/bin/sleep", []string{"sleep", "30"}, "TOKEN=abc", "HOME=/Users/s"), "sleep 30"},
		{"white space cleaned", procargs("/bin/sh", []string{"sh", "-c", "echo one\n\techo two"}), "sh -c echo one echo two"},
		{"cut at 60", procargs("/usr/bin/python3", []string{"python3", strings.Repeat("x", 80)}), "python3 " + strings.Repeat("x", 51) + "…"},
		{"no arguments", procargs("/bin/true", nil), ""},
		{"argc larger than the data", append([]byte{3, 0, 0, 0}, "/bin/ls\x00\x00ls\x00"...), "ls"},
		{"last argument without its NUL", append([]byte{2, 0, 0, 0}, "/bin/ls\x00ls\x00-la"...), "ls -la"},
		{"too short", []byte{1, 0}, ""},
		{"no path end", []byte{1, 0, 0, 0, '/', 'b'}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := commandFromProcargs(c.data); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// openTestPTY opens a pseudo-terminal pair; the test skips where the
// sandbox gives none.
func openTestPTY(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	fd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		t.Skipf("no pseudo-terminal here: %v", err)
	}
	master := os.NewFile(uintptr(fd), "/dev/ptmx")
	t.Cleanup(func() { master.Close() })
	if err := unix.IoctlSetInt(fd, unix.TIOCPTYGRANT, 0); err != nil {
		t.Skipf("grant: %v", err)
	}
	if err := unix.IoctlSetInt(fd, unix.TIOCPTYUNLK, 0); err != nil {
		t.Skipf("unlock: %v", err)
	}
	var name [128]byte
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(unix.TIOCPTYGNAME), uintptr(unsafe.Pointer(&name[0]))); errno != 0 {
		t.Skipf("name: %v", errno)
	}
	path := string(name[:bytes.IndexByte(name[:], 0)])
	slave, err := os.OpenFile(path, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("open %s: %v", path, err)
	}
	return master, slave
}

// A shell with job control on a real pseudo-terminal: while it reads, it is
// in front and there is no command; once it runs sleep as a job, the
// command is sleep's. A process that began after the host learned its ID
// (a reused ID) gives nothing.
func TestForegroundCommandFollowsTheTerminalsForegroundJob(t *testing.T) {
	master, slave := openTestPTY(t)
	shell := exec.Command("/bin/sh", "-c", "set -m; read line; sleep 30; true")
	shell.Stdin, shell.Stdout, shell.Stderr = slave, slave, slave
	shell.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	shell.Env = []string{"PATH=/usr/bin:/bin"}
	if err := shell.Start(); err != nil {
		t.Skipf("start a shell on the pseudo-terminal: %v", err)
	}
	learned := time.Now()
	slave.Close()
	pid := shell.Process.Pid
	t.Cleanup(func() {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = shell.Wait()
	})
	go io.Copy(io.Discard, master)
	for range 5 {
		if command := foregroundCommand(pid, learned, false); command != "" {
			t.Fatalf("the shell reads in front, yet the command is %q", command)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := master.Write([]byte("go\n")); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "sleep in the foreground", func() bool { return foregroundCommand(pid, learned, false) == "sleep 30" })
	if command := foregroundCommand(pid, learned.Add(-time.Minute), false); command != "" {
		t.Fatalf("a process newer than the terminal counted: %q", command)
	}
	if command := foregroundCommand(0, learned, false); command != "" {
		t.Fatalf("no process ID gave %q", command)
	}
	if command := foregroundCommand(1<<30, learned, false); command != "" {
		t.Fatalf("an unknown process gave %q", command)
	}
}

// A routed agent runs under its job-control leader (internal/termrun), the
// pid the keeper adopted: the agent's own group in front is the terminal's
// own program, so there is no command; what the agent puts in front is.
func TestARoutedAgentInFrontIsNoForegroundCommand(t *testing.T) {
	master, slave := openTestPTY(t)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// This test binary is also the leader (terminal_local_e2e_darwin_test.go).
	leader, err := os.StartProcess(self, []string{self, "terminals", "_lead", "--", "/bin/sh", "sh", "-c", "set -m; read line; sleep 30; true"}, &os.ProcAttr{
		Env:   []string{"PATH=/usr/bin:/bin"},
		Files: []*os.File{slave, slave, slave},
		Sys:   &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0},
	})
	if err != nil {
		t.Fatal(err)
	}
	learned := time.Now()
	slave.Close()
	pid := leader.Pid
	t.Cleanup(func() {
		// The leader passes the hang-up on to the agent's group and ends
		// as it does.
		_ = syscall.Kill(-pid, syscall.SIGHUP)
		done := make(chan struct{})
		go func() { leader.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			if group, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPGRP); err == nil && group > 1 {
				_ = syscall.Kill(-group, syscall.SIGKILL)
			}
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			<-done
		}
	})
	go io.Copy(io.Discard, master)
	waitFor(t, "the agent in front", func() bool { return foregroundCommand(pid, learned, false) != "" })
	if command := foregroundCommand(pid, learned, true); command != "" {
		t.Fatalf("the agent itself reads in front, yet the routed terminal's command is %q", command)
	}
	if _, err := master.Write([]byte("go\n")); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the agent's sleep in the foreground", func() bool { return foregroundCommand(pid, learned, true) == "sleep 30" })
}

// A routed terminal asks for its command as a routed one; another as not.
func TestListedTerminalsSayWhetherTheyAreRouted(t *testing.T) {
	for _, routed := range []bool{false, true} {
		entry := &terminalEntry{pid: 42, started: time.Now(), meta: terminalMeta{Routed: routed}, info: TerminalInfo{Status: "running"}}
		var asked []bool
		info := entry.listed(time.Now(), func(pid int, _ time.Time, routedRead bool) string {
			asked = append(asked, routedRead)
			return "vim"
		})
		if len(asked) != 1 || asked[0] != routed || info.Command != "vim" {
			t.Fatalf("routed %v: asked %v, command %q", routed, asked, info.Command)
		}
	}
}
