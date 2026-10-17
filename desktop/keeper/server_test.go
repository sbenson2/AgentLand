//go:build darwin

package keeper

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"agentland/host/internal/localsock"
)

// testVersion is the version test keepers and clients report.
const testVersion = "test"

// runningKeeper is a Serve running in a goroutine.
type runningKeeper struct {
	state  string
	cancel context.CancelFunc
	done   chan struct{}
	err    error
}

// serveForTest runs Serve on <short temp dir>/host.json unless options name a
// state, and waits for its socket. Cleanup cancels it and waits for it.
func serveForTest(t *testing.T, options ServeOptions) *runningKeeper {
	t.Helper()
	if options.StatePath == "" {
		options.StatePath = filepath.Join(shortTempDir(t), "host.json")
	}
	if options.Version == "" {
		options.Version = testVersion
	}
	ctx, cancel := context.WithCancel(context.Background())
	k := &runningKeeper{state: options.StatePath, cancel: cancel, done: make(chan struct{})}
	go func() {
		k.err = Serve(ctx, options)
		close(k.done)
	}()
	t.Cleanup(func() {
		cancel()
		if _, ok := k.returned(15 * time.Second); !ok {
			t.Error("Serve still runs after its context ended")
		}
	})
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Lstat(SocketPath(k.state)); err == nil {
			return k
		}
		if err, ok := k.returned(0); ok {
			t.Fatalf("Serve returned before listening: %v", err)
		}
		if time.Now().After(deadline) {
			t.Fatal("the keeper's socket never appeared")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// returned reports Serve's result once it has returned, waiting up to within.
func (k *runningKeeper) returned(within time.Duration) (error, bool) {
	timer := time.NewTimer(within)
	defer timer.Stop()
	select {
	case <-k.done:
		return k.err, true
	case <-timer.C:
		return nil, false
	}
}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func dialForTest(t *testing.T, k *runningKeeper) *Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, err := Dial(ctx, SocketPath(k.state), testVersion)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func shellRequest(t *testing.T, id, script string) SpawnRequest {
	t.Helper()
	return SpawnRequest{
		ID:   id,
		Dir:  t.TempDir(),
		Path: "/bin/sh",
		Args: []string{"-c", script},
		Env:  []string{"PATH=/usr/bin:/bin", "TERM=dumb", "LANG=C"},
		Rows: 24,
		Cols: 80,
	}
}

func spawnForTest(t *testing.T, c *Client, req SpawnRequest) Info {
	t.Helper()
	info, err := c.Spawn(testContext(t), req)
	if err != nil {
		t.Fatalf("Spawn %s: %v", req.ID, err)
	}
	return info
}

// waitUntilFinished polls List until id has finished.
func waitUntilFinished(t *testing.T, c *Client, id string) Info {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		list, err := c.List(testContext(t))
		if err != nil {
			t.Fatal(err)
		}
		for _, info := range list {
			if info.ID == id && !info.Running {
				return info
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s still runs: %+v", id, list)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func remoteCode(err error) string {
	var remote *RemoteError
	if errors.As(err, &remote) {
		return remote.Code
	}
	return ""
}

func TestServeSpawnsListsAttachesAndForgets(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)

	req := shellRequest(t, "t1", "printf hi; sleep 0.2")
	req.Meta = []byte(`{"a":1}`)
	info := spawnForTest(t, c, req)
	if info.ID != "t1" || !info.Running || info.PID <= 0 || string(info.Meta) != `{"a":1}` {
		t.Fatalf("spawned %+v", info)
	}

	a, err := c.Attach(ctx, "t1", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	ev, err := a.Next()
	if err != nil || ev.Kind != EventData || ev.Offset != 0 || string(ev.Data) != "hi" {
		t.Fatalf("first event = %+v, %v", ev, err)
	}
	ev, err = a.Next()
	if err != nil || ev.Kind != EventExited || ev.Exit == nil || ev.Exit.Code == nil || *ev.Exit.Code != 0 {
		t.Fatalf("second event = %+v, %v", ev, err)
	}
	if ev, err := a.Next(); err != io.EOF {
		t.Fatalf("after exited: %+v, %v", ev, err)
	}

	list, err := c.List(ctx)
	if err != nil || len(list) != 1 {
		t.Fatalf("List = %+v, %v", list, err)
	}
	if got := list[0]; got.ID != "t1" || got.Running || got.Exit == nil || string(got.Meta) != `{"a":1}` || got.Cursor != 2 {
		t.Fatalf("listed %+v", got)
	}

	if err := c.Forget(ctx, "t1"); err != nil {
		t.Fatal(err)
	}
	if list, err := c.List(ctx); err != nil || len(list) != 0 {
		t.Fatalf("List after forget = %+v, %v", list, err)
	}
}

func TestAttachFromACursor(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	spawnForTest(t, c, shellRequest(t, "t1", "printf 0123456789"))
	waitUntilFinished(t, c, "t1")

	a, err := c.Attach(testContext(t), "t1", 4)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	ev, err := a.Next()
	if err != nil || ev.Kind != EventData || ev.Offset != 4 || string(ev.Data) != "456789" {
		t.Fatalf("first event = %+v, %v", ev, err)
	}
	if ev, err := a.Next(); err != nil || ev.Kind != EventExited {
		t.Fatalf("second event = %+v, %v", ev, err)
	}
}

func TestSetMetaReplacesTheBlob(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))
	if err := c.SetMeta(ctx, "t1", []byte(`{"b":2}`)); err != nil {
		t.Fatal(err)
	}
	list, err := c.List(ctx)
	if err != nil || len(list) != 1 || string(list[0].Meta) != `{"b":2}` {
		t.Fatalf("List = %+v, %v", list, err)
	}
	if err := c.Resize(ctx, "t1", 30, 100); err != nil {
		t.Fatal(err)
	}
}

func TestSocketIsPrivateAndOnlyOneKeeperRuns(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	info, err := os.Lstat(SocketPath(k.state))
	if err != nil || info.Mode().Type() != fs.ModeSocket || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket = %v, %v", info.Mode(), err)
	}
	lock, err := os.Lstat(LockPath(k.state))
	if err != nil || !lock.Mode().IsRegular() || lock.Mode().Perm() != 0o600 {
		t.Fatalf("lock = %v, %v", lock.Mode(), err)
	}
	if raw, _ := os.ReadFile(LockPath(k.state)); strings.TrimSpace(string(raw)) != strconv.Itoa(os.Getpid()) {
		t.Fatalf("lock file holds %q, want this process's pid", raw)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := Serve(ctx, ServeOptions{StatePath: k.state, Version: testVersion}); !errors.Is(err, ErrKeeperRunning) {
		t.Fatalf("second Serve = %v", err)
	}
	if release, err := TryLock(k.state); !errors.Is(err, ErrKeeperRunning) {
		if release != nil {
			release()
		}
		t.Fatalf("TryLock while serving = %v", err)
	}
	// The refused keeper left the first one's socket alone.
	if _, err := dialForTest(t, k).List(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestTryLockRefusesALinkedLockFile(t *testing.T) {
	dir := shortTempDir(t)
	state := filepath.Join(dir, "host.json")
	if err := os.Symlink(filepath.Join(dir, "elsewhere"), LockPath(state)); err != nil {
		t.Fatal(err)
	}
	if release, err := TryLock(state); err == nil {
		release()
		t.Fatal("locked through a symlink")
	}
	if _, err := os.Lstat(filepath.Join(dir, "elsewhere")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the link's target was created: %v", err)
	}
}

func TestHelloMismatchKillsNothing(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))

	raw, err := net.Dial("unix", SocketPath(k.state))
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(5 * time.Second))
	hi, _ := json.Marshal(hello{Min: 2, Max: 2, Version: "future", Role: roleControl})
	if err := writeFrame(raw, kindHello, hi); err != nil {
		t.Fatal(err)
	}
	kind, payload, err := readFrame(raw)
	if err != nil || kind != kindReply {
		t.Fatalf("reply = %c %q %v", kind, payload, err)
	}
	var answer helloReply
	if err := json.Unmarshal(payload, &answer); err != nil || answer.Error == "" || answer.Version != testVersion {
		t.Fatalf("hello reply = %+v, %v", answer, err)
	}
	if _, _, err := readFrame(raw); err != io.EOF {
		t.Fatalf("the connection stayed open: %v", err)
	}

	list, err := c.List(testContext(t))
	if err != nil || len(list) != 1 || !list[0].Running {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

func TestNoHelloWithinTheDeadlineIsDropped(t *testing.T) {
	saved := helloWait
	helloWait = 100 * time.Millisecond
	t.Cleanup(func() { helloWait = saved })
	k := serveForTest(t, ServeOptions{})

	raw, err := net.Dial("unix", SocketPath(k.state))
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	began := time.Now()
	_ = raw.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := raw.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("read = %v, want the keeper to close", err)
	}
	if took := time.Since(began); took > 2*time.Second {
		t.Fatalf("dropped after %v", took)
	}
}

func TestKeeperExitsWhenIdle(t *testing.T) {
	quiet := serveForTest(t, ServeOptions{IdleAfter: 200 * time.Millisecond})
	if err, ok := quiet.returned(time.Second); !ok || err != nil {
		t.Fatalf("with no terminals: returned=%v err=%v", ok, err)
	}
	if _, err := os.Lstat(SocketPath(quiet.state)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("socket left behind: %v", err)
	}
	release, err := TryLock(quiet.state)
	if err != nil {
		t.Fatalf("lock still held: %v", err)
	}
	release()

	busy := serveForTest(t, ServeOptions{IdleAfter: 200 * time.Millisecond})
	c := dialForTest(t, busy)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))
	c.Close()
	if err, ok := busy.returned(time.Second); ok {
		t.Fatalf("exited with a running terminal: %v", err)
	}
	c = dialForTest(t, busy)
	ctx := testContext(t)
	if _, err := c.End(ctx, "t1"); err != nil {
		t.Fatal(err)
	}
	if err, ok := busy.returned(time.Second); ok {
		t.Fatalf("exited with a finished terminal not yet forgotten: %v", err)
	}
	if err := c.Forget(ctx, "t1"); err != nil {
		t.Fatal(err)
	}
	c.Close()
	if err, ok := busy.returned(2 * time.Second); !ok || err != nil {
		t.Fatalf("after forget and close: returned=%v err=%v", ok, err)
	}
}

func TestRefusesMoreThanMaxTerminals(t *testing.T) {
	k := serveForTest(t, ServeOptions{MaxTerminals: 2})
	c := dialForTest(t, k)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))
	spawnForTest(t, c, shellRequest(t, "t2", "sleep 30"))
	_, err := c.Spawn(testContext(t), shellRequest(t, "t3", "sleep 30"))
	var remote *RemoteError
	if !errors.As(err, &remote) || remote.Code != "limit" {
		t.Fatalf("third spawn = %v", err)
	}
}

func TestRefusesDuplicatesBadRequestsAndForgettingARunningTerminal(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))

	if _, err := c.Spawn(ctx, shellRequest(t, "t1", "sleep 30")); remoteCode(err) != CodeExists {
		t.Fatalf("duplicate spawn = %v", err)
	}
	big := shellRequest(t, "t2", "sleep 30")
	big.Meta = make([]byte, MaxMeta+1)
	if _, err := c.Spawn(ctx, big); remoteCode(err) != CodeBadRequest {
		t.Fatalf("oversized meta = %v", err)
	}
	if err := c.SetMeta(ctx, "t1", make([]byte, MaxMeta+1)); remoteCode(err) != CodeBadRequest {
		t.Fatalf("oversized setMeta = %v", err)
	}
	for _, id := range []string{"", "a b", "line\nbreak", strings.Repeat("x", 200)} {
		if _, err := c.Spawn(ctx, shellRequest(t, id, "true")); remoteCode(err) != CodeBadRequest {
			t.Fatalf("spawn id %q = %v", id, err)
		}
	}
	if err := c.Resize(ctx, "t1", 0, 80); remoteCode(err) != CodeBadRequest {
		t.Fatalf("resize to 0 rows = %v", err)
	}
	missing := shellRequest(t, "t3", "true")
	missing.Path = "/no/such/program"
	if _, err := c.Spawn(ctx, missing); remoteCode(err) != CodeStartFailed {
		t.Fatalf("missing program = %v", err)
	}
	if err := c.Forget(ctx, "t1"); remoteCode(err) != CodeRunning {
		t.Fatalf("forget running = %v", err)
	}
	// The connection still serves after every refusal.
	if list, err := c.List(ctx); err != nil || len(list) != 1 || !list[0].Running {
		t.Fatalf("List = %+v, %v", list, err)
	}
}

func TestEndedProgramsDieOfTheHangUp(t *testing.T) {
	// The keeper ignores SIGHUP itself; its programs must not inherit that,
	// or the hang-up that ends a terminal does nothing.
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	spawnForTest(t, c, SpawnRequest{ID: "t1", Dir: t.TempDir(), Path: "/bin/sleep", Args: []string{"30"},
		Env: []string{"PATH=/usr/bin:/bin"}, Rows: 24, Cols: 80})
	info, err := c.End(testContext(t), "t1")
	if err != nil || info.Running || info.Exit == nil || info.Exit.Signal != "SIGHUP" {
		t.Fatalf("End = %+v (exit %+v), %v", info, info.Exit, err)
	}
}

func TestStopAllEndsEverythingAndExits(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	first := spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))
	second := spawnForTest(t, c, shellRequest(t, "t2", "sleep 30"))

	if err := c.StopAll(testContext(t)); err != nil {
		t.Fatal(err)
	}
	if err, ok := k.returned(3 * time.Second); !ok || err != nil {
		t.Fatalf("after stopAll: returned=%v err=%v", ok, err)
	}
	waitForGone(t, first.PID)
	waitForGone(t, second.PID)
	select {
	case <-c.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("the client did not see the keeper go")
	}
	if _, err := os.Lstat(SocketPath(k.state)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("socket left behind: %v", err)
	}
}

// A terminal the keeper ends as it stops says so in its exit; one a client
// ended itself does not.
func TestStopAllMarksTheExitsItCauses(t *testing.T) {
	k := serveForTest(t, ServeOptions{})
	c := dialForTest(t, k)
	ctx := testContext(t)
	spawnForTest(t, c, shellRequest(t, "t1", "sleep 30"))
	spawnForTest(t, c, shellRequest(t, "t2", "sleep 30"))
	ended, err := c.End(ctx, "t1")
	if err != nil || ended.Exit == nil || ended.Exit.ByKeeper {
		t.Fatalf("a client's End: %+v, %v", ended.Exit, err)
	}
	attachment, err := c.Attach(ctx, "t2", 0)
	if err != nil {
		t.Fatal(err)
	}
	defer attachment.Close()
	if err := c.StopAll(ctx); err != nil {
		t.Fatal(err)
	}
	for {
		event, err := attachment.Next()
		if err != nil {
			t.Fatalf("no exit before the stream ended: %v", err)
		}
		if event.Kind == EventExited {
			if event.Exit == nil || !event.Exit.ByKeeper {
				t.Fatalf("the keeper's own end: %+v", event.Exit)
			}
			return
		}
	}
}

var logLine = regexp.MustCompile(`^(\S+) [a-z][a-z-]*( id=[A-Za-z0-9._:-]+)? pid=[0-9]+( code=-?[0-9]+| signal=SIG[A-Z0-9]+)?$`)

func TestLogHasNoContentsArgumentsOrEnvironment(t *testing.T) {
	saved := logLimit
	logLimit = 1024
	t.Cleanup(func() { logLimit = saved })
	dir := shortTempDir(t)
	logPath := filepath.Join(dir, "logs", "terminals.log")
	k := serveForTest(t, ServeOptions{StatePath: filepath.Join(dir, "host.json"), LogPath: logPath})
	c := dialForTest(t, k)
	ctx := testContext(t)

	req := shellRequest(t, "secret", "printf SECRET-OUT; exit 3")
	req.Args = append(req.Args, "SECRET-ARG")
	req.Env = append(req.Env, "X=SECRET-ENV")
	spawnForTest(t, c, req)
	a, err := c.Attach(ctx, "secret", 0)
	if err != nil {
		t.Fatal(err)
	}
	for {
		ev, err := a.Next()
		if err != nil {
			t.Fatal(err)
		}
		if ev.Kind == EventExited {
			break
		}
	}
	a.Close()
	if err := c.Forget(ctx, "secret"); err != nil {
		t.Fatal(err)
	}
	// About 220 bytes of lines a terminal: enough to rotate once at 1 KiB,
	// not twice, so the secret terminal's lines are still in the .1 file.
	for i := range 5 {
		id := "fill-" + strconv.Itoa(i)
		spawnForTest(t, c, shellRequest(t, id, "sleep 30"))
		if _, err := c.End(ctx, id); err != nil {
			t.Fatal(err)
		}
		if err := c.Forget(ctx, id); err != nil {
			t.Fatal(err)
		}
	}
	if err := c.StopAll(ctx); err != nil {
		t.Fatal(err)
	}
	if err, ok := k.returned(3 * time.Second); !ok || err != nil {
		t.Fatalf("after stopAll: returned=%v err=%v", ok, err)
	}

	var all string
	for _, path := range []string{logPath + ".1", logPath} {
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
			t.Fatalf("%s = %v, %v", path, info, err)
		}
		if info.Size() > 1024 {
			t.Fatalf("%s holds %d bytes, past the limit", path, info.Size())
		}
		raw, _ := os.ReadFile(path)
		all += string(raw)
	}
	if strings.Contains(all, "SECRET") {
		t.Fatalf("the log leaks:\n%s", all)
	}
	for _, line := range strings.Split(strings.TrimSuffix(all, "\n"), "\n") {
		m := logLine.FindStringSubmatch(line)
		if m == nil {
			t.Fatalf("line %q is not a lifecycle line", line)
		}
		if _, err := time.Parse(time.RFC3339, m[1]); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
	}
	for _, want := range []string{" spawn id=secret pid=", " exit id=secret pid=", " forget id=secret pid="} {
		if !strings.Contains(all, want) {
			t.Fatalf("the log lacks %q:\n%s", want, all)
		}
	}
	if !regexp.MustCompile(` exit id=secret pid=[0-9]+ code=3\n`).MatchString(all) {
		t.Fatalf("the exit line lacks its code:\n%s", all)
	}
}

func TestOpenLogWithNoPathDiscards(t *testing.T) {
	w, err := openLog("")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(w, "line\n"); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestOpenLogRefusesALink(t *testing.T) {
	dir := shortTempDir(t)
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "terminals.log")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if w, err := openLog(link); err == nil {
		w.Close()
		t.Fatal("opened a log through a symlink")
	}
}

func TestLongSocketPathFailsClearly(t *testing.T) {
	base := shortTempDir(t)
	// <dir>/terminals.sock is 110 bytes.
	dir := filepath.Join(base, strings.Repeat("d", 110-len("/terminals.sock")-len(base)-1))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(dir, "host.json")
	if n := len(SocketPath(state)); n != 110 {
		t.Fatalf("socket path is %d bytes", n)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, ServeOptions{StatePath: state, Version: testVersion}) }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "too long") || !errors.Is(err, localsock.ErrTooLong) {
			t.Fatalf("Serve = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Serve still runs with a socket path that cannot work")
	}
	release, err := TryLock(state)
	if err != nil {
		t.Fatalf("the failed keeper kept its lock: %v", err)
	}
	release()
}
