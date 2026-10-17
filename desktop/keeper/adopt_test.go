//go:build darwin

package keeper

import (
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// startAdoptee starts /bin/sh -c script on a new PTY, in its own session with
// the PTY as its controlling terminal, as `terminals run` does. The test
// keeps the master and no copy of the slave. Cleanup kills the session unless
// the test has waited for it.
func startAdoptee(t *testing.T, script string) (master *os.File, cmd *exec.Cmd) {
	t.Helper()
	master, slave, err := OpenPTY()
	if err != nil {
		t.Fatal(err)
	}
	cmd = exec.Command("/bin/sh", "-c", script)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	err = cmd.Start()
	slave.Close()
	if err != nil {
		master.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = unix.Kill(-cmd.Process.Pid, unix.SIGKILL)
			_ = cmd.Wait()
		}
		master.Close()
	})
	return master, cmd
}

// alive reports whether pid still runs. A program the test started stays a
// zombie until the test waits for it, and kill(pid, 0) still succeeds then.
func alive(pid int) bool {
	const zombie = 5 // SZOMB, sys/proc.h
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	return err == nil && int(info.Proc.P_pid) == pid && info.Proc.P_stat != zombie
}

func adoptForTest(t *testing.T, c *Client, id string, master *os.File, cmd *exec.Cmd) Info {
	t.Helper()
	info, err := c.Adopt(testContext(t), AdoptRequest{ID: id, PID: cmd.Process.Pid, Rows: 24, Cols: 80}, master)
	if err != nil {
		t.Fatalf("Adopt %s: %v", id, err)
	}
	return info
}

// readUntil reads f until what it read contains want.
func readUntil(t *testing.T, f *os.File, want string) {
	t.Helper()
	_ = f.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer f.SetReadDeadline(time.Time{})
	var got []byte
	buf := make([]byte, 1024)
	for !bytes.Contains(got, []byte(want)) {
		n, err := f.Read(buf)
		got = append(got, buf[:n]...)
		if err != nil {
			t.Fatalf("read %q, then %v; want %q", got, err, want)
		}
	}
}

// nextExit reads an attachment until its exit.
func nextExit(t *testing.T, a *Attachment) *Exit {
	t.Helper()
	for {
		ev, err := a.Next()
		if err != nil {
			t.Fatalf("no exit before the stream ended: %v", err)
		}
		if ev.Kind == EventExited {
			return ev.Exit
		}
	}
}

func listed(t *testing.T, c *Client, id string) (Info, bool) {
	t.Helper()
	list, err := c.List(testContext(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, info := range list {
		if info.ID == id {
			return info, true
		}
	}
	return Info{}, false
}

func TestHelloAdvertisesAdopt(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	if !c.HasFeature("adopt") || c.HasFeature("nope") {
		t.Fatalf("features %q", c.Features())
	}
}

func TestAdoptedOutputReachesASecondClientByteExact(t *testing.T) {
	want := make([]byte, 1<<20)
	if _, err := rand.Read(want); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(shortTempDir(t), "out")
	if err := os.WriteFile(file, want, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("F", file)
	saved := exitReportWait
	exitReportWait = 100 * time.Millisecond // nothing reports this exit
	t.Cleanup(func() { exitReportWait = saved })
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)

	master, cmd := startAdoptee(t, `stty raw -echo; cat "$F"`)
	time.Sleep(200 * time.Millisecond) // output waits in the PTY: none of it may be lost
	info, err := c.Adopt(ctx, AdoptRequest{ID: "a1", PID: cmd.Process.Pid, Rows: 30, Cols: 100}, master)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Adopted || !info.Running || info.PID != cmd.Process.Pid {
		t.Fatalf("adopted %+v", info)
	}
	if rows, cols, err := Size(master); err != nil || rows != 30 || cols != 100 {
		t.Fatalf("size %dx%d, %v", rows, cols, err)
	}

	a, err := dialForTest(t, k).Attach(ctx, "a1", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	var got []byte
	for {
		ev, err := a.Next()
		if err != nil {
			t.Fatalf("after %d bytes: %v", len(got), err)
		}
		if ev.Kind == EventSkipped {
			t.Fatalf("skipped to %d", ev.SkippedTo)
		}
		if ev.Kind == EventExited {
			break
		}
		if ev.Offset != uint64(len(got)) {
			t.Fatalf("data at %d after %d bytes", ev.Offset, len(got))
		}
		got = append(got, ev.Data...)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("got %d bytes, want the file's %d exactly", len(got), len(want))
	}
}

func TestAdoptRefusesAPidThatIsNotOnTheTerminal(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	master, _ := startAdoptee(t, "sleep 300")
	_, err := c.Adopt(testContext(t), AdoptRequest{ID: "a1", PID: os.Getpid(), Rows: 24, Cols: 80}, master)
	if remoteCode(err) != CodeBadRequest {
		t.Fatalf("Adopt of a pid on another terminal: %v", err)
	}
	if list, err := c.List(testContext(t)); err != nil || len(list) != 0 {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

// Adopt needs a PTY master, a valid and free ID, and a keeper with room. A
// descriptor it refuses is closed.
func TestAdoptRefusesWhatIsNotAProgramsTerminalAndClosesIt(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	ctx := testContext(t)
	master, cmd := startAdoptee(t, "sleep 300")
	pid := cmd.Process.Pid
	if _, err := c.Adopt(ctx, AdoptRequest{ID: "a1", PID: pid}, nil); remoteCode(err) != CodeBadRequest {
		t.Fatalf("no descriptor: %v", err)
	}
	if _, err := c.Adopt(ctx, AdoptRequest{ID: "bad id", PID: pid}, master); remoteCode(err) != CodeBadRequest {
		t.Fatalf("a bad ID: %v", err)
	}
	spawnForTest(t, c, shellRequest(t, "s1", "sleep 30"))
	if _, err := c.Adopt(ctx, AdoptRequest{ID: "s1", PID: pid}, master); remoteCode(err) != CodeExists {
		t.Fatalf("a taken ID: %v", err)
	}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	_, err = c.Adopt(ctx, AdoptRequest{ID: "a2", PID: pid}, w)
	w.Close()
	if remoteCode(err) != CodeBadRequest {
		t.Fatalf("a pipe: %v", err)
	}
	_ = r.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := r.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the keeper kept a descriptor it refused: %v", err)
	}
	if list, err := c.List(ctx); err != nil || len(list) != 1 {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

func TestReportedExitCodeIsRecorded(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	ctx := testContext(t)
	// It waits for a line, so it is still on the terminal when adopted.
	master, cmd := startAdoptee(t, `read -r line; exit 7`)
	adoptForTest(t, c, "a1", master, cmd)
	a, err := c.Attach(ctx, "a1", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if err := c.Input(ctx, "a1", []byte("\n")); err != nil {
		t.Fatal(err)
	}
	var exitErr *exec.ExitError
	if err := cmd.Wait(); !errors.As(err, &exitErr) || exitErr.ExitCode() != 7 {
		t.Fatalf("the program ended with %v", err)
	}
	seven := 7
	if err := c.ReportExit(ctx, "a1", Exit{Code: &seven, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	info := waitUntilFinished(t, c, "a1")
	if info.Exit == nil || info.Exit.Code == nil || *info.Exit.Code != 7 || info.Exit.Released {
		t.Fatalf("exit %+v", info.Exit)
	}
	if exit := nextExit(t, a); exit.Code == nil || *exit.Code != 7 {
		t.Fatalf("streamed exit %+v", exit)
	}
	if err := c.ReportExit(ctx, "a1", Exit{Code: &seven}); remoteCode(err) != CodeNotRunning {
		t.Fatalf("a report after the end: %v", err)
	}
}

func TestAnUnreportedExitStillEnds(t *testing.T) {
	saved := exitReportWait
	exitReportWait = 100 * time.Millisecond
	t.Cleanup(func() { exitReportWait = saved })
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	master, cmd := startAdoptee(t, `read -r line; exit 0`)
	adoptForTest(t, c, "a1", master, cmd)
	if err := c.Input(testContext(t), "a1", []byte("\n")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		info, ok := listed(t, c, "a1")
		if !ok {
			t.Fatal("the terminal went away")
		}
		if !info.Running {
			if info.Exit == nil || info.Exit.Code != nil {
				t.Fatalf("exit %+v", info.Exit)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("still running 3 s after the program exited")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestEndHangsUpAnAdoptedSession(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	master, cmd := startAdoptee(t, "sleep 300")
	adoptForTest(t, c, "a1", master, cmd)
	began := time.Now()
	info, err := c.End(testContext(t), "a1")
	if err != nil || info.Running {
		t.Fatalf("End = %+v, %v", info, err)
	}
	if took := time.Since(began); took > 8*time.Second {
		t.Fatalf("End took %v", took)
	}
	err = cmd.Wait()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("the program ended with %v", err)
	}
	if status := exitErr.Sys().(syscall.WaitStatus); !status.Signaled() || status.Signal() != syscall.SIGHUP {
		t.Fatalf("the program ended with %v, want SIGHUP", err)
	}
}

func TestReleaseKeepsTheProgramRunning(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	ctx := testContext(t)
	master, cmd := startAdoptee(t, `stty -echo; while IFS= read -r l; do echo "got:$l"; done`)
	adoptForTest(t, c, "a1", master, cmd)
	a, err := c.Attach(ctx, "a1", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if err := c.Release(ctx, "a1"); err != nil {
		t.Fatal(err)
	}
	if exit := nextExit(t, a); !exit.Released {
		t.Fatalf("streamed exit %+v", exit)
	}
	if _, ok := listed(t, c, "a1"); ok {
		t.Fatal("a released terminal is still listed")
	}
	if !alive(cmd.Process.Pid) {
		t.Fatal("the program is gone")
	}
	if _, err := master.Write([]byte("x\n")); err != nil {
		t.Fatal(err)
	}
	readUntil(t, master, "got:x")
}

func TestStopAllReleasesAdoptedAndEndsSpawned(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	spawned := spawnForTest(t, c, shellRequest(t, "s1", "sleep 300"))
	master, cmd := startAdoptee(t, "sleep 300")
	adoptForTest(t, c, "a1", master, cmd)
	if err := c.StopAll(testContext(t)); err != nil {
		t.Fatal(err)
	}
	if _, ok := k.returned(5 * time.Second); !ok {
		t.Fatal("the keeper still runs after stopAll")
	}
	waitForGone(t, spawned.PID)
	if !alive(cmd.Process.Pid) {
		t.Fatal("the adopted program is gone")
	}
}

func TestAKeeperThatShutsDownReleasesAdopted(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	master, cmd := startAdoptee(t, `stty -echo; while IFS= read -r l; do echo "got:$l"; done`)
	adoptForTest(t, c, "a1", master, cmd)
	k.cancel()
	if _, ok := k.returned(15 * time.Second); !ok {
		t.Fatal("the keeper still runs after its context ended")
	}
	if !alive(cmd.Process.Pid) {
		t.Fatal("the program is gone")
	}
	if _, err := master.Write([]byte("x\n")); err != nil {
		t.Fatal(err)
	}
	readUntil(t, master, "got:x")
}

func TestReleaseRefusesASpawnedTerminal(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	ctx := testContext(t)
	spawnForTest(t, c, shellRequest(t, "s1", "sleep 30"))
	if err := c.Release(ctx, "s1"); remoteCode(err) != CodeNotAdopted {
		t.Fatalf("Release: %v", err)
	}
	if err := c.ReportExit(ctx, "s1", Exit{Code: new(int)}); remoteCode(err) != CodeNotAdopted {
		t.Fatalf("ReportExit: %v", err)
	}
	if err := c.Release(ctx, "nope"); remoteCode(err) != CodeNotFound {
		t.Fatalf("Release of no terminal: %v", err)
	}
	if info, ok := listed(t, c, "s1"); !ok || !info.Running {
		t.Fatalf("the spawned terminal: %+v", info)
	}
}

func TestInputRecordsLastInput(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	spawnForTest(t, c, shellRequest(t, "s1", "cat"))
	if info, _ := listed(t, c, "s1"); !info.LastInput.IsZero() {
		t.Fatalf("input before any: %v", info.LastInput)
	}
	if err := c.Input(testContext(t), "s1", []byte("a\n")); err != nil {
		t.Fatal(err)
	}
	list, err := c.List(testContext(t))
	if err != nil || len(list) != 1 || list[0].LastInput.IsZero() {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

// The keeper checks a master's blocking mode and never sets it: the mode
// belongs to the open file it would share with the sender.
func TestAdoptRefusesABlockingMaster(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	master, cmd := startAdoptee(t, "sleep 300")
	raw, err := master.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var setErr error
	if err := raw.Control(func(fd uintptr) { setErr = unix.SetNonblock(int(fd), false) }); err != nil || setErr != nil {
		t.Fatal(err, setErr)
	}
	_, err = c.Adopt(testContext(t), AdoptRequest{ID: "a1", PID: cmd.Process.Pid}, master)
	if remoteCode(err) != CodeBadRequest || !strings.Contains(err.Error(), "blocking") {
		t.Fatalf("Adopt of a blocking master: %v", err)
	}
	if list, err := c.List(testContext(t)); err != nil || len(list) != 0 {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

// End signals the program's process group by its pid, so the pid must lead
// its session, as the program `terminals run` starts does.
func TestAdoptRefusesAProgramThatDoesNotLeadItsSession(t *testing.T) {
	pidFile := filepath.Join(shortTempDir(t), "pid")
	t.Setenv("P", pidFile)
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	master, _ := startAdoptee(t, `sleep 300 & echo $! > "$P"; wait`)
	child := waitForPIDFile(t, pidFile) // on the terminal, in the shell's session
	_, err := c.Adopt(testContext(t), AdoptRequest{ID: "a1", PID: child}, master)
	if remoteCode(err) != CodeBadRequest || !strings.Contains(err.Error(), "session") {
		t.Fatalf("Adopt of a program that leads no session: %v", err)
	}
}

func TestAdoptRefusesAPTYAnotherTerminalHolds(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	ctx := testContext(t)
	master, cmd := startAdoptee(t, "sleep 300")
	adoptForTest(t, c, "a1", master, cmd)
	_, err := c.Adopt(ctx, AdoptRequest{ID: "a2", PID: cmd.Process.Pid}, master)
	if remoteCode(err) != CodeBadRequest || !strings.Contains(err.Error(), "holds") {
		t.Fatalf("a second adopt of one PTY: %v", err)
	}
	list, err := c.List(ctx)
	if err != nil || len(list) != 1 || list[0].ID != "a1" || !list[0].Running {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

// An End still hanging up when the terminal is released stops there: the
// keeper sends nothing more to a program it gave back.
func TestAnEndRacingAReleaseLeavesTheProgramAlone(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	ctx := testContext(t)
	// It survives the hang-up and says so; a TERM would end it.
	master, cmd := startAdoptee(t, `trap 'echo hup' HUP; echo ready; while :; do sleep 1; done`)
	adoptForTest(t, c, "a1", master, cmd)
	a, err := c.Attach(ctx, "a1", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	stop := time.AfterFunc(5*time.Second, func() { a.Close() })
	defer stop.Stop()
	var out []byte
	until := func(want string) {
		t.Helper()
		for !bytes.Contains(out, []byte(want)) {
			ev, err := a.Next()
			if err != nil {
				t.Fatalf("no %q in %q: %v", want, out, err)
			}
			out = append(out, ev.Data...)
		}
	}
	until("ready") // the trap is set
	type result struct {
		info Info
		err  error
	}
	ended := make(chan result, 1)
	go func() {
		info, err := c.End(ctx, "a1")
		ended <- result{info, err}
	}()
	until("hup") // End has hung up and waits for an exit
	if err := c.Release(ctx, "a1"); err != nil {
		t.Fatal(err)
	}
	select {
	case r := <-ended:
		if r.err != nil || r.info.Exit == nil || !r.info.Exit.Released {
			t.Fatalf("End = %+v, %v", r.info.Exit, r.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("End did not return after the release")
	}
	if !alive(cmd.Process.Pid) {
		t.Fatal("the released program is gone")
	}
}

// An adopted program may run what it starts in a process group other than
// its own, as `terminals run`'s job-control leader runs the agent. End
// hangs up every process on the PTY and keeps on, TERM at 2 s and KILL at
// 5 s, until none is left, after the adopted program itself has gone.
func TestEndKeepsOnUntilNoProcessIsLeftOnTheTerminal(t *testing.T) {
	c := dialForTest(t, serveForTest(t, ServeOptions{}))
	master, cmd := startAdoptee(t, `set -m; (trap '' HUP; exec sleep 300) & echo "child:$!."; wait`)
	adoptForTest(t, c, "a1", master, cmd)
	child := readChildPID(t, master)
	t.Cleanup(func() { _ = unix.Kill(child, unix.SIGKILL) })
	// Its parent reaps it, as terminals run does; startAdoptee's cleanup,
	// which runs after this one, then finds it reaped.
	reaped := make(chan struct{})
	go func() { _ = cmd.Wait(); close(reaped) }()
	t.Cleanup(func() {
		select {
		case <-reaped:
		case <-time.After(10 * time.Second):
			_ = unix.Kill(-cmd.Process.Pid, unix.SIGKILL)
			<-reaped
		}
	})
	began := time.Now()
	if _, err := c.End(testContext(t), "a1"); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(began); took > 8*time.Second {
		t.Fatalf("End took %v", took)
	}
	deadline := time.Now().Add(time.Second)
	for alive(child) {
		if time.Now().After(deadline) {
			t.Fatalf("the program's child %d, which ignores the hang-up, outlived End", child)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// readChildPID reads "child:<pid>." from the terminal.
func readChildPID(t *testing.T, master *os.File) int {
	t.Helper()
	_ = master.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer master.SetReadDeadline(time.Time{})
	var got []byte
	buf := make([]byte, 256)
	for {
		if i := bytes.Index(got, []byte("child:")); i >= 0 {
			if j := bytes.IndexByte(got[i:], '.'); j > 0 {
				var pid int
				if _, err := fmt.Sscanf(string(got[i+6:i+j]), "%d", &pid); err == nil {
					return pid
				}
			}
		}
		n, err := master.Read(buf)
		got = append(got, buf[:n]...)
		if err != nil {
			t.Fatalf("read %q, then %v", got, err)
		}
	}
}
