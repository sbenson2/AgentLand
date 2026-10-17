//go:build darwin

package termrun

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"agentland/host/internal/localterm"
	"agentland/host/keeper"

	"golang.org/x/sys/unix"
)

const (
	testVersion = "test"
	testID      = "term_test"
)

// testWindow stands in for a Terminal.app window: the CLI gets its slave as
// its terminal, and the test reads and types on the master.
type testWindow struct {
	master, slave *os.File
	mu            sync.Mutex
	out           []byte
	done          chan struct{}
}

func window(t *testing.T) *testWindow {
	t.Helper()
	master, slave, err := keeper.OpenPTY()
	if err != nil {
		t.Fatal(err)
	}
	if err := keeper.SetSize(slave, 24, 80); err != nil {
		t.Fatal(err)
	}
	w := &testWindow{master: master, slave: slave, done: make(chan struct{})}
	go func() {
		defer close(w.done)
		buf := make([]byte, 64<<10)
		for {
			n, err := master.Read(buf)
			w.mu.Lock()
			w.out = append(w.out, buf[:n]...)
			w.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() {
		master.Close()
		<-w.done
		slave.Close()
	})
	return w
}

func (w *testWindow) output() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return string(w.out)
}

// waitFor waits until the window has shown want.
func (w *testWindow) waitFor(t *testing.T, want string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !strings.Contains(w.output(), want) {
		if time.Now().After(deadline) {
			t.Fatalf("the window never showed %q; it shows %q", want, w.output())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (w *testWindow) typeText(t *testing.T, text string) {
	t.Helper()
	if _, err := w.master.Write([]byte(text)); err != nil {
		t.Fatal(err)
	}
}

// termios is the window's settings. PENDIN is left out: the kernel sets it
// itself whenever a terminal goes back to canonical mode, to reprocess
// pending input, and clears it at the next read.
func (w *testWindow) termios(t *testing.T) unix.Termios {
	t.Helper()
	got, err := termiosOf(w.slave)
	if err != nil {
		t.Fatal(err)
	}
	got.Lflag &^= unix.PENDIN
	return *got
}

// stateFolder is a host state path in a short folder under /private/tmp: a
// Unix socket's path fits 103 bytes, and a test's own folder is longer.
func stateFolder(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/private/tmp", "tr-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "host.json")
}

// runningKeeper is a keeper served in this process.
type runningKeeper struct {
	state  string
	cancel context.CancelFunc
	done   chan struct{}
}

func startKeeper(t *testing.T) *runningKeeper {
	t.Helper()
	state := stateFolder(t)
	ctx, cancel := context.WithCancel(context.Background())
	k := &runningKeeper{state: state, cancel: cancel, done: make(chan struct{})}
	go func() {
		defer close(k.done)
		if err := keeper.Serve(ctx, keeper.ServeOptions{StatePath: state, Version: testVersion}); err != nil {
			t.Errorf("keeper: %v", err)
		}
	}()
	t.Cleanup(func() {
		cancel()
		if !k.stopped(15 * time.Second) {
			t.Error("the keeper still runs after its context ended")
		}
	})
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Lstat(keeper.SocketPath(state)); err == nil {
			return k
		}
		if time.Now().After(deadline) {
			t.Fatal("the keeper's socket never appeared")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (k *runningKeeper) stopped(within time.Duration) bool {
	select {
	case <-k.done:
		return true
	case <-time.After(within):
		return false
	}
}

func testKeeper(t *testing.T) (state string) { return startKeeper(t).state }

func dialKeeper(t *testing.T, state string) *keeper.Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, err := keeper.Dial(ctx, keeper.SocketPath(state), testVersion)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func testContext(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// attachWhenAdopted is a second client's stream of the terminal, from its
// start, once the keeper has it.
func attachWhenAdopted(t *testing.T, c *keeper.Client, id string) *keeper.Attachment {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		a, err := c.Attach(testContext(t), id, 0)
		if err == nil {
			t.Cleanup(func() { a.Close() })
			return a
		}
		if !keeper.IsNotFound(err) || time.Now().After(deadline) {
			t.Fatalf("attach %s: %v", id, err)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// readStream reads a stream until its exit or until it has shown want.
func readStream(t *testing.T, a *keeper.Attachment, want string) (data []byte, exit *keeper.Exit) {
	t.Helper()
	for {
		ev, err := a.Next()
		if err != nil {
			t.Fatalf("the stream ended (%v) after %q", err, data)
		}
		switch ev.Kind {
		case keeper.EventData:
			data = append(data, ev.Data...)
			if want != "" && strings.Contains(string(data), want) {
				return data, nil
			}
		case keeper.EventExited:
			return data, ev.Exit
		}
	}
}

// registrar stands in for the host's local registration socket.
type registrar struct {
	mu       sync.Mutex
	requests []localterm.Request
	seconds  []string // the op of each registration's second line
}

// fakeRegistrar answers each registration with reply, or never when reply is
// nil, and records the requests and the second line.
func fakeRegistrar(t *testing.T, state string, reply func(localterm.Request) localterm.Reply) *registrar {
	t.Helper()
	listener, err := net.Listen("unix", localterm.SocketPath(state))
	if err != nil {
		t.Fatal(err)
	}
	r := &registrar{}
	var conns sync.WaitGroup
	t.Cleanup(func() {
		listener.Close()
		conns.Wait()
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conns.Add(1)
			go func() {
				defer conns.Done()
				defer conn.Close()
				r.serve(conn, reply)
			}()
		}
	}()
	return r
}

func (r *registrar) serve(conn net.Conn, reply func(localterm.Request) localterm.Reply) {
	reader := bufio.NewReader(conn)
	var request localterm.Request
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := localterm.ReadLine(reader, &request); err != nil {
		return
	}
	r.mu.Lock()
	r.requests = append(r.requests, request)
	r.mu.Unlock()
	if reply == nil {
		_, _ = reader.ReadByte() // never answers; the CLI hangs up
		return
	}
	answer := reply(request)
	if err := localterm.WriteLine(conn, answer); err != nil || answer.Error != nil {
		return
	}
	var second localterm.Request
	if err := localterm.ReadLine(reader, &second); err != nil {
		second.Op = "EOF"
	}
	r.mu.Lock()
	r.seconds = append(r.seconds, second.Op)
	r.mu.Unlock()
}

func (r *registrar) registered() []localterm.Request {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]localterm.Request(nil), r.requests...)
}

// second waits for the first registration's second line.
func (r *registrar) second(t *testing.T) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		r.mu.Lock()
		seconds := append([]string(nil), r.seconds...)
		r.mu.Unlock()
		if len(seconds) > 0 {
			return seconds[0]
		}
		if time.Now().After(deadline) {
			t.Fatal("no second line from the CLI")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func adopting(localterm.Request) localterm.Reply {
	return localterm.Reply{ID: testID, Meta: []byte(`{"v":1}`)}
}

// agent writes a /bin/sh script named claude into a new PATH folder and
// returns the folder.
func agent(t *testing.T, body string) (bin string) {
	t.Helper()
	bin = t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// testEnv is this process's environment with PATH starting at bin, extra
// set, and no AGENTLAND_TERMINAL: these tests may themselves run inside an
// AgentLand terminal.
func testEnv(bin string, extra ...string) []string {
	drop := map[string]bool{"PATH": true, "AGENTLAND_TERMINAL": true}
	for _, kv := range extra {
		drop[strings.SplitN(kv, "=", 2)[0]] = true
	}
	var env []string
	for _, kv := range os.Environ() {
		if !drop[strings.SplitN(kv, "=", 2)[0]] {
			env = append(env, kv)
		}
	}
	return append(append(env, "PATH="+bin+":/usr/bin:/bin"), extra...)
}

// folder is a new folder named canonically.
func folder(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// routedOptions runs claude, the script body, in w against state.
func routedOptions(t *testing.T, state string, w *testWindow, body string, extraEnv ...string) Options {
	t.Helper()
	return Options{
		StatePath: state, Version: testVersion, Name: "claude",
		Stdin: w.slave, Stdout: w.slave, Stderr: w.slave,
		Env: testEnv(agent(t, body), extraEnv...), Dir: folder(t),
		// Run in this process must never stop the test binary itself.
		suspend: func() { t.Error("the CLI suspended itself") },
	}
}

// cli is Run or Attach running in the background. Cleanup hangs it up if
// the test left it running, which ends a program Run started.
type cli struct {
	signals  chan os.Signal
	finished chan struct{}
	code     int
}

func startCLI(t *testing.T, run func(signals <-chan os.Signal) int) *cli {
	t.Helper()
	c := &cli{signals: make(chan os.Signal, 4), finished: make(chan struct{})}
	go func() {
		defer close(c.finished)
		c.code = run(c.signals)
	}()
	t.Cleanup(func() {
		select {
		case <-c.finished:
			return
		default:
		}
		c.signals <- syscall.SIGHUP
		select {
		case <-c.finished:
		case <-time.After(15 * time.Second):
			t.Error("the CLI never returned after a hang-up")
		}
	})
	return c
}

func startRun(t *testing.T, o Options) *cli {
	t.Helper()
	return startCLI(t, func(signals <-chan os.Signal) int {
		o.Signals = signals
		return Run(o)
	})
}

func startAttach(t *testing.T, o AttachOptions) *cli {
	t.Helper()
	return startCLI(t, func(signals <-chan os.Signal) int {
		o.Signals = signals
		return Attach(o)
	})
}

// wait returns the CLI's exit code.
func (c *cli) wait(t *testing.T, within time.Duration) int {
	t.Helper()
	select {
	case <-c.finished:
		return c.code
	case <-time.After(within):
		t.Fatalf("the CLI still runs after %v", within)
		return 0
	}
}

func (c *cli) running() bool {
	select {
	case <-c.finished:
		return false
	default:
		return true
	}
}

// spawn starts /bin/sh -c script in the keeper as terminal id.
func spawn(t *testing.T, c *keeper.Client, id, script string) keeper.Info {
	t.Helper()
	info, err := c.Spawn(testContext(t), keeper.SpawnRequest{
		ID: id, Dir: t.TempDir(), Path: "/bin/sh", Args: []string{"-c", script},
		Env: []string{"PATH=/usr/bin:/bin", "TERM=dumb", "LANG=C"}, Rows: 24, Cols: 80,
	})
	if err != nil {
		t.Fatal(err)
	}
	return info
}

// adoptee starts /bin/sh -c script on a PTY of its own, as `terminals run`
// does, and has the keeper adopt it as id. Cleanup kills its session.
func adoptee(t *testing.T, c *keeper.Client, id, script string) {
	t.Helper()
	master, slave, err := keeper.OpenPTY()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	err = cmd.Start()
	slave.Close()
	if err != nil {
		master.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = unix.Kill(-cmd.Process.Pid, unix.SIGKILL)
		_ = cmd.Wait()
		master.Close()
	})
	if _, err := c.Adopt(testContext(t), keeper.AdoptRequest{ID: id, PID: cmd.Process.Pid, Rows: 24, Cols: 80}, master); err != nil {
		t.Fatal(err)
	}
}

func listed(t *testing.T, c *keeper.Client, id string) (keeper.Info, bool) {
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
	return keeper.Info{}, false
}

// hangUp closes the window, as Terminal.app does: the CLI's terminal hangs
// up under it.
func (w *testWindow) hangUp() { w.master.Close() }

// readyPID waits for the agent's "ready:<pid>." and returns the pid.
func (w *testWindow) readyPID(t *testing.T) int {
	t.Helper()
	w.waitFor(t, "ready:")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if match := regexp.MustCompile(`ready:(\d+)\.`).FindStringSubmatch(w.output()); match != nil {
			pid, _ := strconv.Atoi(match[1])
			return pid
		}
		if time.Now().After(deadline) {
			t.Fatalf("no pid in %q", w.output())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestMain is also every process the tests start: the job-control leader
// Run starts (`<this binary> terminals _lead -- …`), a CLI in a process of
// its own, and a keeper in a process of its own.
func TestMain(m *testing.M) {
	if len(os.Args) > 2 && os.Args[1] == "terminals" && os.Args[2] == LeadCommand {
		os.Exit(Lead(os.Args[3:]))
	}
	if spec := os.Getenv(cliProcessVariable); spec != "" {
		runCLIProcess(spec)
	}
	if state := os.Getenv(keeperProcessVariable); state != "" {
		os.Exit(serveKeeperProcess(state))
	}
	os.Exit(m.Run())
}

const (
	cliProcessVariable    = "TERMRUN_TEST_CLI"
	keeperProcessVariable = "TERMRUN_TEST_KEEPER"
)

// cliSpec is a Run for a CLI process, on its own stdio.
type cliSpec struct {
	StatePath, Version, Name, Dir string
	Args, Env                     []string
}

// runCLIProcess runs and ends as `terminals run` does.
func runCLIProcess(spec string) {
	var s cliSpec
	if err := json.Unmarshal([]byte(spec), &s); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	Exit(RunStatus(Options{StatePath: s.StatePath, Version: s.Version, Name: s.Name, Args: s.Args,
		Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr, Env: s.Env, Dir: s.Dir}))
}

func serveKeeperProcess(state string) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer stop()
	if err := keeper.Serve(ctx, keeper.ServeOptions{StatePath: state, Version: testVersion}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

// process is a process the test started, in a process group of its own
// within the test's session, watched with wait4 so that its stops show too.
// Cleanup continues its group, sends the group stop and waits; past 15 s it
// kills the group.
type process struct {
	pid    int
	stops  chan struct{}
	exited chan struct{}
	status syscall.WaitStatus
}

func startProcess(t *testing.T, argv, env []string, files []*os.File, stop syscall.Signal) *process {
	t.Helper()
	proc, err := os.StartProcess(argv[0], argv, &os.ProcAttr{Env: env, Files: files, Sys: &syscall.SysProcAttr{Setpgid: true}})
	if err != nil {
		t.Fatal(err)
	}
	p := &process{pid: proc.Pid, stops: make(chan struct{}, 16), exited: make(chan struct{})}
	go func() {
		defer close(p.exited)
		for {
			var status syscall.WaitStatus
			_, err := syscall.Wait4(p.pid, &status, syscall.WUNTRACED, nil)
			if err == syscall.EINTR {
				continue
			}
			if err != nil || status.Exited() || status.Signaled() {
				p.status = status
				return
			}
			if status.Stopped() {
				p.stops <- struct{}{}
			}
		}
	}()
	t.Cleanup(func() {
		select {
		case <-p.exited:
			return
		default:
		}
		_ = syscall.Kill(-p.pid, syscall.SIGCONT)
		_ = syscall.Kill(-p.pid, stop)
		select {
		case <-p.exited:
		case <-time.After(15 * time.Second):
			t.Errorf("process %d still runs after %v", p.pid, stop)
			_ = syscall.Kill(-p.pid, syscall.SIGKILL)
			<-p.exited
		}
	})
	return p
}

// startCLIProcess runs Run with o in a process of its own on w, so that it
// can really stop for job control. Its Signals and suspend are its own.
func startCLIProcess(t *testing.T, o Options, w *testWindow) *process {
	t.Helper()
	return startCLIProcessWith(t, o, w, func(exe string) []string { return []string{exe} })
}

// startCLIProcessWith is startCLIProcess with the command line argv gives
// for this binary: a wrapper script around it, say.
func startCLIProcessWith(t *testing.T, o Options, w *testWindow, argv func(exe string) []string) *process {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	spec, err := json.Marshal(cliSpec{StatePath: o.StatePath, Version: o.Version, Name: o.Name, Dir: o.Dir, Args: o.Args, Env: o.Env})
	if err != nil {
		t.Fatal(err)
	}
	return startProcess(t, argv(exe), append(os.Environ(), cliProcessVariable+"="+string(spec)), []*os.File{w.slave, w.slave, w.slave}, syscall.SIGHUP)
}

// startKeeperProcess serves a keeper in a process of its own, which the
// test can stop.
func startKeeperProcess(t *testing.T) (state string, p *process) {
	t.Helper()
	state = stateFolder(t)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	p = startProcess(t, []string{exe}, append(os.Environ(), keeperProcessVariable+"="+state), []*os.File{nil, os.Stderr, os.Stderr}, syscall.SIGTERM)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Lstat(keeper.SocketPath(state)); err == nil {
			return state, p
		}
		if time.Now().After(deadline) {
			t.Fatal("the keeper process's socket never appeared")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (p *process) waitStopped(t *testing.T, within time.Duration) {
	t.Helper()
	select {
	case <-p.stops:
	case <-p.exited:
		t.Fatalf("process %d ended (%v) instead of stopping", p.pid, p.status)
	case <-time.After(within):
		t.Fatalf("process %d did not stop within %v", p.pid, within)
	}
}

func (p *process) neverStops(t *testing.T, within time.Duration) {
	t.Helper()
	select {
	case <-p.stops:
		t.Fatalf("process %d stopped", p.pid)
	case <-time.After(within):
	}
}

func (p *process) wait(t *testing.T, within time.Duration) syscall.WaitStatus {
	t.Helper()
	select {
	case <-p.exited:
		return p.status
	case <-time.After(within):
		t.Fatalf("process %d still runs after %v", p.pid, within)
		return 0
	}
}

// stoppedProcess reports whether pid is stopped (SSTOP, sys/proc.h).
func stoppedProcess(pid int) bool {
	const sstop = 4
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	return err == nil && int(info.Proc.P_pid) == pid && info.Proc.P_stat == sstop
}
