//go:build darwin

package keeper

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

const floodScript = `head -c 10000000 /dev/zero | tr "\0" a`

// startTestTerminal spawns req in a temporary folder and ends it when the test finishes.
func startTestTerminal(t *testing.T, req SpawnRequest) *terminal {
	t.Helper()
	if req.Dir == "" {
		req.Dir = t.TempDir()
	}
	if req.Env == nil {
		req.Env = []string{"PATH=/usr/bin:/bin", "TERM=dumb", "LANG=C"}
	}
	if req.Rows == 0 {
		req.Rows, req.Cols = 24, 80
	}
	term, err := startTerminal(req, time.Now)
	if err != nil {
		t.Fatalf("startTerminal: %v", err)
	}
	t.Cleanup(func() { term.end() })
	return term
}

func waitForExit(t *testing.T, term *terminal, within time.Duration) Info {
	t.Helper()
	select {
	case <-term.exited:
	case <-time.After(within):
		t.Fatalf("the program still runs after %v", within)
	}
	return term.info()
}

// waitForPIDFile reads a pid that a shell wrote with a trailing newline.
func waitForPIDFile(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		raw, _ := os.ReadFile(path)
		if strings.HasSuffix(string(raw), "\n") {
			pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
			if err != nil || pid <= 0 {
				t.Fatalf("%s = %q", path, raw)
			}
			return pid
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s was never written", path)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func waitForGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for unix.Kill(pid, 0) != unix.ESRCH {
		if time.Now().After(deadline) {
			t.Fatalf("process %d is still there", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestTerminalRunsAProgramAndKeepsItsOutput(t *testing.T) {
	term := startTestTerminal(t, SpawnRequest{ID: "one", Path: "/bin/sh", Args: []string{"-c", "printf hello; exit 3"}})
	info := waitForExit(t, term, 10*time.Second)

	if info.ID != "one" || info.Running || info.Exit == nil || info.Exit.Code == nil || *info.Exit.Code != 3 || info.Exit.Signal != "" {
		t.Fatalf("info = %+v, exit = %+v", info, info.Exit)
	}
	if info.Start != 0 || info.Cursor != 5 {
		t.Fatalf("span = (%d, %d)", info.Start, info.Cursor)
	}
	if data, _, _ := term.ring.readFrom(0, 64); string(data) != "hello" {
		t.Fatalf("ring = %q", data)
	}
	if info.PID <= 0 || info.Started.IsZero() || info.Exit.At.IsZero() {
		t.Fatalf("pid = %d, started = %v, exit at = %v", info.PID, info.Started, info.Exit.At)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r := term.subscribe(0)
	ev, err := r.next(ctx)
	if err != nil || ev.Kind != EventData || ev.Offset != 0 || string(ev.Data) != "hello" {
		t.Fatalf("first event = %+v, %v", ev, err)
	}
	ev, err = r.next(ctx)
	if err != nil || ev.Kind != EventExited || ev.Exit == nil || ev.Exit.Code == nil || *ev.Exit.Code != 3 {
		t.Fatalf("second event = %+v, %v", ev, err)
	}
	if _, err := r.next(ctx); err != io.EOF {
		t.Fatalf("after the exit: %v", err)
	}
}

func TestTerminalInputAndResize(t *testing.T) {
	term := startTestTerminal(t, SpawnRequest{Path: "/bin/sh", Env: []string{"PATH=/usr/bin:/bin", "PS1=", "TERM=dumb", "LANG=C"}})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := term.resize(40, 100); err != nil {
		t.Fatalf("resize: %v", err)
	}
	if err := term.input(ctx, []byte("stty size\n")); err != nil {
		t.Fatalf("input: %v", err)
	}
	r := term.subscribe(0)
	var out []byte
	for !bytes.Contains(out, []byte("40 100")) {
		ev, err := r.next(ctx)
		if err != nil || ev.Kind == EventExited {
			t.Fatalf("output %q, then %+v, %v", out, ev, err)
		}
		out = append(out, ev.Data...)
	}
}

func TestEndKillsBackgroundJobsAndTermIgnoringChildren(t *testing.T) {
	dir := t.TempDir()
	script := `trap '' TERM HUP; sleep 300 & echo $! > bg.pid; exec sh -c "trap '' TERM HUP; sleep 300"`
	term := startTestTerminal(t, SpawnRequest{Dir: dir, Path: "/bin/sh", Args: []string{"-c", script}})

	background := waitForPIDFile(t, filepath.Join(dir, "bg.pid"))

	began := time.Now()
	info := term.end()
	if took := time.Since(began); took > 8*time.Second {
		t.Fatalf("end took %v", took)
	}
	if info.Running || info.Exit == nil {
		t.Fatalf("after end: %+v", info)
	}
	waitForGone(t, info.PID)
	waitForGone(t, background)
}

// A's leader dies on the hang-up, but a job in its process group ignores
// HUP and TERM, so A's end keeps going after A's master is closed. B then
// opens a PTY and may get A's freed slot. A's end must never reach B.
func TestEndNeverSignalsAReusedTTY(t *testing.T) {
	dir := t.TempDir()
	script := `trap '' HUP TERM; sleep 30 & echo $! > bg.pid; trap - HUP TERM; exec sleep 300`
	a := startTestTerminal(t, SpawnRequest{ID: "a", Dir: dir, Path: "/bin/sh", Args: []string{"-c", script}})
	background := waitForPIDFile(t, filepath.Join(dir, "bg.pid"))
	time.Sleep(300 * time.Millisecond) // the shell resets its traps and becomes sleep 300

	ended := make(chan Info, 1)
	go func() { ended <- a.end() }()
	waitForExit(t, a, 3*time.Second)
	b := startTestTerminal(t, SpawnRequest{ID: "b", Path: "/bin/sleep", Args: []string{"60"}})
	select {
	case <-ended:
	case <-time.After(8 * time.Second):
		t.Fatal("end did not return")
	}
	waitForGone(t, background) // the group's job still gets SIGKILL
	if b.dev != a.dev {
		t.Skipf("B got PTY %#x, not A's %#x", b.dev, a.dev)
	}
	if info := b.info(); !info.Running || unix.Kill(b.pid, 0) != nil {
		t.Fatalf("A's end reached B: %+v, exit %+v", info, info.Exit)
	}
}

func TestAFinishedTerminalRefusesInputAndIsLeftAlone(t *testing.T) {
	term := startTestTerminal(t, SpawnRequest{Path: "/bin/sh", Args: []string{"-c", "exit 0"}})
	finished := waitForExit(t, term, 10*time.Second)
	if err := term.input(context.Background(), []byte("x")); !errors.Is(err, errNotRunning) {
		t.Fatalf("input: %v", err)
	}
	if err := term.resize(30, 90); !errors.Is(err, errNotRunning) {
		t.Fatalf("resize: %v", err)
	}
	began := time.Now()
	if info := term.end(); time.Since(began) > 100*time.Millisecond || info.Running || info.Exit == nil || *info.Exit.Code != *finished.Exit.Code {
		t.Fatalf("end of a finished terminal: %+v after %v", info, time.Since(began))
	}
}

func TestExitBySignalIsRecorded(t *testing.T) {
	term := startTestTerminal(t, SpawnRequest{Path: "/bin/sh", Args: []string{"-c", "kill -TERM $$"}})
	info := waitForExit(t, term, 10*time.Second)
	if info.Exit == nil || info.Exit.Signal != "SIGTERM" || info.Exit.Code != nil {
		t.Fatalf("exit = %+v", info.Exit)
	}
}

func TestFloodWithoutReaderStaysBounded(t *testing.T) {
	term := startTestTerminal(t, SpawnRequest{Path: "/bin/sh", Args: []string{"-c", floodScript}})
	info := waitForExit(t, term, 60*time.Second)
	if info.Cursor != 10000000 || info.Cursor-info.Start != RingSize {
		t.Fatalf("span = (%d, %d)", info.Start, info.Cursor)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ev, err := term.subscribe(0).next(ctx)
	if err != nil || ev.Kind != EventSkipped || ev.SkippedTo != info.Start {
		t.Fatalf("first event = %+v, %v", ev, err)
	}
}

func TestInputToAProgramThatNeverReadsIsRefused(t *testing.T) {
	saved := inputWait
	inputWait = 300 * time.Millisecond
	t.Cleanup(func() { inputWait = saved })

	term := startTestTerminal(t, SpawnRequest{Path: "/bin/sleep", Args: []string{"30"}})
	// Whole lines: a terminal in canonical mode drops an unfinished line it
	// has no room for, but it holds complete lines until the program reads.
	chunk := bytes.Repeat([]byte("0123456789abcde\n"), 2048)
	stalled := false
	for i := 0; i < 64 && !stalled; i++ {
		began := time.Now()
		err := term.input(context.Background(), chunk)
		switch {
		case errors.Is(err, errInputStalled):
			stalled = true
			if took := time.Since(began); took > 2*time.Second {
				t.Fatalf("refusing took %v", took)
			}
		case err != nil:
			t.Fatalf("input %d: %v", i, err)
		}
	}
	if !stalled {
		t.Fatal("input was never refused")
	}
	if !term.info().Running {
		t.Fatal("the program stopped")
	}
}

func TestSlowSubscriberSkipsAndNeverBlocksTheProgram(t *testing.T) {
	term := startTestTerminal(t, SpawnRequest{Path: "/bin/sh", Args: []string{"-c", floodScript}})
	r := term.subscribe(0) // never reads while the flood runs
	info := waitForExit(t, term, 10*time.Second)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ev, err := r.next(ctx)
	if err != nil || ev.Kind != EventSkipped || ev.SkippedTo != info.Start {
		t.Fatalf("first event = %+v, %v", ev, err)
	}
}
