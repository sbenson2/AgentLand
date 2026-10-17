//go:build darwin

package termrun

import (
	"bytes"
	"crypto/rand"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"agentland/host/internal/localterm"
	"agentland/host/keeper"
)

// routedRun starts claude, the script body, in a new window against a test
// keeper and a registrar that answers testID.
func routedRun(t *testing.T, body string, extraEnv ...string) (*testWindow, *registrar, string, *cli) {
	t.Helper()
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	c := startRun(t, routedOptions(t, state, w, body, extraEnv...))
	return w, reg, state, c
}

// adopted waits until the CLI has told the host the keeper took its PTY.
func adopted(t *testing.T, reg *registrar) {
	t.Helper()
	if got := reg.second(t); got != localterm.OpAdopted {
		t.Fatalf("the CLI said %q, want adopted", got)
	}
}

func TestRunPassesOutputThroughByteExact(t *testing.T) {
	want := make([]byte, 1<<20)
	if _, err := rand.Read(want); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "out.bin")
	if err := os.WriteFile(file, want, 0o600); err != nil {
		t.Fatal(err)
	}
	w, reg, state, c := routedRun(t, `stty raw -echo; cat "$F"`, "F="+file)
	second := attachWhenAdopted(t, dialKeeper(t, state), testID)
	got, exit := readStream(t, second, "")
	if !bytes.Equal(got, want) {
		t.Fatalf("a second client read %d bytes, want the file's %d", len(got), len(want))
	}
	if exit == nil || exit.Code == nil || *exit.Code != 0 {
		t.Fatalf("the second client's exit %+v", exit)
	}
	if code := c.wait(t, 30*time.Second); code != 0 {
		t.Fatalf("Run returned %d", code)
	}
	adopted(t, reg)
	shown := []byte(focusOn + string(want) + focusOff)
	deadline := time.Now().Add(5 * time.Second)
	for len(w.output()) < len(shown) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if out := []byte(w.output()); !bytes.Equal(out, shown) {
		t.Fatalf("the window read %d bytes, want %d (focus on, the file, focus off)", len(out), len(shown))
	}
}

func TestRunPassesTheExitCode(t *testing.T) {
	w, reg, _, c := routedRun(t, `read -r l; exit 7`)
	adopted(t, reg)
	w.typeText(t, "\r")
	if code := c.wait(t, 10*time.Second); code != 7 {
		t.Fatalf("Run returned %d, want 7", code)
	}
}

func TestRunRestoresTheTTY(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	before := w.termios(t)
	c := startRun(t, routedOptions(t, state, w, `stty -echo; echo ready; read -r l; exit 0`))
	adopted(t, reg)
	w.waitFor(t, "ready")
	if during := w.termios(t); during.Lflag&syscall.ICANON != 0 || during.Lflag&syscall.ECHO != 0 {
		t.Fatalf("the window is not raw while the program runs: lflag %#x", during.Lflag)
	}
	w.typeText(t, "\r")
	if code := c.wait(t, 10*time.Second); code != 0 {
		t.Fatalf("Run returned %d", code)
	}
	if after := w.termios(t); after != before {
		t.Fatalf("termios after %+v, before %+v", after, before)
	}
}

func TestSigwinchResizesTheTerminal(t *testing.T) {
	w, reg, _, c := routedRun(t, `stty -echo; while IFS= read -r l; do stty size; done`)
	adopted(t, reg)
	if err := keeper.SetSize(w.slave, 30, 90); err != nil {
		t.Fatal(err)
	}
	c.signals <- syscall.SIGWINCH
	w.typeText(t, "\r")
	w.waitFor(t, "30 90")
}

func TestFocusInResizesAfterAnotherViewerResized(t *testing.T) {
	w, reg, state, _ := routedRun(t, `stty -echo; echo ready; while IFS= read -r l; do echo "got:$l size:$(stty size)"; done`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	if err := dialKeeper(t, state).Resize(testContext(t), testID, 10, 40); err != nil {
		t.Fatal(err)
	}
	w.typeText(t, "\x1b[I\r")
	w.waitFor(t, "got: size:24 80")
	if strings.Contains(w.output(), "\x1b[I") {
		t.Fatalf("the focus event reached the program: %q", w.output())
	}
}

func TestTypingReachesTheProgramAndASecondClientSeesIt(t *testing.T) {
	w, reg, state, _ := routedRun(t, `stty -echo; while IFS= read -r l; do echo "got:$l"; done`)
	adopted(t, reg)
	second := attachWhenAdopted(t, dialKeeper(t, state), testID)
	w.typeText(t, "hello\r")
	w.waitFor(t, "got:hello")
	readStream(t, second, "got:hello")
}

func TestSecondClientInputReachesTheWindow(t *testing.T) {
	w, reg, state, _ := routedRun(t, `stty -echo; while IFS= read -r l; do echo "got:$l"; done`)
	adopted(t, reg)
	if err := dialKeeper(t, state).Input(testContext(t), testID, []byte("x\n")); err != nil {
		t.Fatal(err)
	}
	w.waitFor(t, "got:x")
}

// execCall is what a fake Exec was called with.
type execCall struct {
	path      string
	argv, env []string
}

func firstPathFolder(t *testing.T, env []string) string {
	t.Helper()
	for _, kv := range env {
		if value, ok := strings.CutPrefix(kv, "PATH="); ok {
			return strings.SplitN(value, ":", 2)[0]
		}
	}
	t.Fatal("no PATH")
	return ""
}

type fakeExec struct {
	mu    sync.Mutex
	calls []execCall
}

func (f *fakeExec) exec(path string, argv, env []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, execCall{path: path, argv: argv, env: env})
	return nil
}

func (f *fakeExec) only(t *testing.T) execCall {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) != 1 {
		t.Fatalf("Exec called %d times", len(f.calls))
	}
	return f.calls[0]
}

func refusing(code string) func(localterm.Request) localterm.Reply {
	return func(localterm.Request) localterm.Reply {
		return localterm.Reply{Error: &localterm.Error{Code: code, Message: "no"}}
	}
}

func TestEveryFallbackRunsTheRealCommand(t *testing.T) {
	for _, tc := range []struct {
		name       string
		host       func(localterm.Request) localterm.Reply
		noHost     bool
		keeper     bool
		line       string
		wantCancel bool
	}{
		{name: "no socket", noHost: true, line: "AgentLand isn't running"},
		// A host that is running but slow is not reported as absent.
		{name: "no answer", host: nil, line: "AgentLand didn't answer in time"},
		{name: "terminal_disabled", host: refusing("terminal_disabled"), keeper: true, line: "AgentLand's terminal access is off"},
		{name: "terminal_limit", host: refusing("terminal_limit"), keeper: true, line: "AgentLand has 16 terminals open"},
		{name: "terminals_unavailable", host: refusing("terminals_unavailable"), keeper: true, line: "AgentLand's terminal service isn't available"},
		{name: "version_mismatch", host: refusing("version_mismatch"), keeper: true, line: "AgentLand's terminal service isn't available"},
		{name: "no keeper", host: adopting, line: "AgentLand's terminal service isn't available", wantCancel: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := stateFolder(t)
			if tc.keeper {
				state = testKeeper(t)
			}
			var reg *registrar
			if !tc.noHost {
				reg = fakeRegistrar(t, state, tc.host)
			}
			w := window(t)
			o := routedOptions(t, state, w, `echo started`)
			o.Args = []string{"a"}
			fake := &fakeExec{}
			o.Exec = fake.exec
			began := time.Now()
			code := Run(o)
			if took := time.Since(began); took > 1500*time.Millisecond {
				t.Fatalf("the real command started after %v", took)
			}
			if code != 0 {
				t.Fatalf("Run returned %d", code)
			}
			call := fake.only(t)
			path := filepath.Join(firstPathFolder(t, o.Env), "claude")
			if call.path != path || !slices.Equal(call.argv, []string{"claude", "a"}) || !slices.Equal(call.env, o.Env) {
				t.Fatalf("Exec(%q, %q, …) with the caller's environment %v; want %q", call.path, call.argv, slices.Equal(call.env, o.Env), path)
			}
			w.waitFor(t, "\x1b[2m"+tc.line+" — started claude normally.\x1b[0m")
			if tc.wantCancel {
				if got := reg.second(t); got != localterm.OpCancel {
					t.Fatalf("the CLI said %q, want cancel", got)
				}
			}
		})
	}
}

func TestNotATerminalRunsTheRealCommandSilently(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	o := routedOptions(t, state, w, `echo started`)
	o.Stdin = reader
	fake := &fakeExec{}
	o.Exec = fake.exec
	if code := Run(o); code != 0 {
		t.Fatalf("Run returned %d", code)
	}
	if call := fake.only(t); !slices.Equal(call.argv, []string{"claude"}) {
		t.Fatalf("argv %q", call.argv)
	}
	time.Sleep(100 * time.Millisecond)
	if out := w.output(); out != "" {
		t.Fatalf("stderr %q", out)
	}
	if got := reg.registered(); len(got) != 0 {
		t.Fatalf("registered %+v", got)
	}
}

func TestNestedRunIsNotRouted(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `echo started`, "AGENTLAND_TERMINAL=term_x")
	fake := &fakeExec{}
	o.Exec = fake.exec
	if code := Run(o); code != 0 {
		t.Fatalf("Run returned %d", code)
	}
	if call := fake.only(t); !slices.Equal(call.env, o.Env) {
		t.Fatalf("env changed: %q", call.env)
	}
	if got := reg.registered(); len(got) != 0 {
		t.Fatalf("registered %+v", got)
	}
}

func TestACommandThatIsNotFoundSaysSo(t *testing.T) {
	w := window(t)
	o := routedOptions(t, stateFolder(t), w, `echo started`)
	o.Name = "no-such-agent"
	fake := &fakeExec{}
	o.Exec = fake.exec
	if code := Run(o); code != 127 {
		t.Fatalf("Run returned %d", code)
	}
	w.waitFor(t, "no-such-agent: command not found")
}

func TestTheProgramKeepsTheCallersEnvironment(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `env; echo "cwd:$(pwd -P)"; read -r l`,
		"FOO=bar", "CLAUDECODE=1", "TERM=xterm-ghostty", "ODD=a=b c")
	startRun(t, o)
	adopted(t, reg)
	w.waitFor(t, "cwd:"+o.Dir+"\r\n")
	for _, want := range []string{"FOO=bar\r\n", "CLAUDECODE=1\r\n", "TERM=xterm-ghostty\r\n", "ODD=a=b c\r\n", "AGENTLAND_TERMINAL=" + testID + "\r\n"} {
		if !strings.Contains(w.output(), want) {
			t.Errorf("no %q in %q", want, w.output())
		}
	}
	got := reg.registered()
	if len(got) != 1 || got[0].Folder != o.Dir || got[0].Command != "claude" || got[0].Version != testVersion || got[0].Rows != 24 || got[0].Cols != 80 {
		t.Fatalf("registered %+v", got)
	}
}

// A folder named through a symbolic link registers as its true path.
func TestTheRegisteredFolderIsCanonical(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `read -r l`)
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(o.Dir, link); err != nil {
		t.Fatal(err)
	}
	o.Dir = link
	startRun(t, o)
	adopted(t, reg)
	want, err := filepath.EvalSymlinks(link)
	if err != nil {
		t.Fatal(err)
	}
	if got := reg.registered(); len(got) != 1 || got[0].Folder != want {
		t.Fatalf("registered %+v, want folder %q", got, want)
	}
}

func TestKillingTheKeeperKeepsTheWindowWorking(t *testing.T) {
	k := startKeeper(t)
	reg := fakeRegistrar(t, k.state, adopting)
	w := window(t)
	c := startRun(t, routedOptions(t, k.state, w, `stty -echo; while IFS= read -r l; do [ "$l" = bye ] && exit 3; echo "got:$l"; done`))
	adopted(t, reg)
	w.typeText(t, "before\r")
	w.waitFor(t, "got:before")
	k.cancel()
	if !k.stopped(15 * time.Second) {
		t.Fatal("the keeper still runs")
	}
	w.typeText(t, "after\r")
	w.waitFor(t, "got:after")
	w.typeText(t, "bye\r")
	if code := c.wait(t, 10*time.Second); code != 3 {
		t.Fatalf("Run returned %d, want 3", code)
	}
}

func TestSighupEndsTheAgent(t *testing.T) {
	w, reg, state, c := routedRun(t, `echo ready; sleep 300`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	c.signals <- syscall.SIGHUP
	if code := c.wait(t, 10*time.Second); code != 129 {
		t.Fatalf("Run returned %d, want 129", code)
	}
	info, ok := listed(t, dialKeeper(t, state), testID)
	if !ok || info.Running || info.Exit == nil || info.Exit.Signal != "SIGHUP" {
		t.Fatalf("the keeper has %+v (exit %+v)", info, info.Exit)
	}
}

// Without a keeper the CLI hangs the agent up itself.
func TestSighupEndsTheAgentWithoutAKeeper(t *testing.T) {
	k := startKeeper(t)
	reg := fakeRegistrar(t, k.state, adopting)
	w := window(t)
	c := startRun(t, routedOptions(t, k.state, w, `trap '' HUP; echo ready; while :; do sleep 0.1; done`))
	adopted(t, reg)
	w.waitFor(t, "ready")
	k.cancel()
	if !k.stopped(15 * time.Second) {
		t.Fatal("the keeper still runs")
	}
	began := time.Now()
	c.signals <- syscall.SIGHUP
	code := c.wait(t, 10*time.Second)
	if code != 128+int(syscall.SIGTERM) {
		t.Fatalf("Run returned %d, want SIGTERM's %d", code, 128+int(syscall.SIGTERM))
	}
	if took := time.Since(began); took < 1900*time.Millisecond || took > 4*time.Second {
		t.Fatalf("the hang-up took %v, want SIGTERM at 2 s", took)
	}
}

func TestCtrlCReachesTheProgramAndTheCLISurvives(t *testing.T) {
	w, reg, _, c := routedRun(t, `trap 'echo got-int' INT; echo ready; while :; do sleep 0.1; done`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	w.typeText(t, "\x03")
	w.waitFor(t, "got-int")
	time.Sleep(500 * time.Millisecond)
	if !c.running() {
		t.Fatalf("Run returned %d after Ctrl-C", c.code)
	}
	c.signals <- syscall.SIGHUP
	if code := c.wait(t, 10*time.Second); code != 129 {
		t.Fatalf("Run returned %d, want 129", code)
	}
}

func TestArgumentsPassThroughUnchanged(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `stty raw -echo; printf '[%s]' "$@"; echo; read -r l`)
	o.Args = []string{"a b", "it's", "x\ny", "ünï", `"quoted"`}
	startRun(t, o)
	adopted(t, reg)
	got := reg.registered()
	if len(got) != 1 || got[0].ConversationID == "" {
		t.Fatalf("registered %+v", got)
	}
	w.waitFor(t, "[--session-id]["+got[0].ConversationID+"][a b][it's][x\ny][ünï][\"quoted\"]\n")
}

// SIGWINCH alone, with nothing typed, resizes the program's terminal.
func TestSigwinchAloneResizesTheTerminal(t *testing.T) {
	w, reg, _, c := routedRun(t, `trap 'echo "size:$(stty size)"' WINCH; echo ready; while :; do sleep 0.05; done`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	if err := keeper.SetSize(w.slave, 31, 91); err != nil {
		t.Fatal(err)
	}
	c.signals <- syscall.SIGWINCH
	w.waitFor(t, "size:31 91")
}

// A focus-in alone, with nothing else typed, takes the size back from
// another viewer.
func TestFocusInAloneTakesTheSizeBack(t *testing.T) {
	w, reg, state, _ := routedRun(t, `trap 'echo "size:$(stty size)"' WINCH; echo ready; while :; do sleep 0.05; done`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	if err := dialKeeper(t, state).Resize(testContext(t), testID, 10, 40); err != nil {
		t.Fatal(err)
	}
	w.waitFor(t, "size:10 40")
	w.typeText(t, "\x1b[I")
	w.waitFor(t, "size:24 80")
}

// A program that asks for focus events gets them; when it stops asking, the
// CLI turns the window's reporting on again and keeps them from it.
func TestFocusEventsReachAProgramThatAsked(t *testing.T) {
	w, reg, _, _ := routedRun(t, `stty -echo
hex() { printf %s "$1" | od -An -tx1 | tr -d ' \n'; }
printf '\033[?1004h'; echo ready
IFS= read -r l; echo "got:$(hex "$l")."
printf '\033[?1004l'; echo off
IFS= read -r l; echo "then:$(hex "$l")."
read -r l`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	w.typeText(t, "\x1b[Ix\r")
	w.waitFor(t, "got:1b5b4978.")
	w.waitFor(t, "off")
	out := w.output()
	off := strings.LastIndex(out, focusOff)
	if off < 0 || !strings.Contains(out[off:], focusOn) {
		t.Fatalf("focus reporting was not turned on again after the program's %q: %q", focusOff, out)
	}
	w.typeText(t, "\x1b[Iy\r")
	w.waitFor(t, "then:79.")
}

// countingAgent reads, in raw mode after a pause, everything typed, and says
// how many bytes reached it.
const countingAgent = `stty raw -echo min 0 time 20; echo ready; sleep 2; n=$(cat | wc -c | tr -d ' '); printf 'count:%s.\n' "$n"; sleep 300`

func typedCount(t *testing.T, w *testWindow) int {
	t.Helper()
	w.waitFor(t, ".\n")
	match := regexp.MustCompile(`count:(\d+)\.`).FindStringSubmatch(w.output())
	if match == nil {
		t.Fatalf("no count in %q", w.output())
	}
	n, _ := strconv.Atoi(match[1])
	return n
}

// The CLI waits for the keeper's own verdict on a chunk (it gives up on a
// program that does not read after 10 s, keeper/terminal.go inputWait).
func TestInputWaitOutlastsTheKeepersStall(t *testing.T) {
	if inputWait <= 10*time.Second {
		t.Fatalf("inputWait %v gives up before the keeper does", inputWait)
	}
}

// A chunk the keeper did not answer in time may still reach the program: it
// is never written again.
func TestATimedOutChunkIsNeverSentTwice(t *testing.T) {
	saved := inputWait
	inputWait = 300 * time.Millisecond
	t.Cleanup(func() { inputWait = saved })
	w, reg, _, _ := routedRun(t, countingAgent)
	adopted(t, reg)
	w.waitFor(t, "ready")
	typed := strings.Repeat("a", 4096)
	go w.master.Write([]byte(typed)) // blocks while the program does not read
	if n := typedCount(t, w); n != len(typed) {
		t.Fatalf("%d bytes reached the program, want each of the %d once", n, len(typed))
	}
}

// A chunk under way when the keeper goes may have reached the program in
// part: it is never written again.
func TestAChunkInFlightWhenTheKeeperGoesIsNeverSentTwice(t *testing.T) {
	k := startKeeper(t)
	reg := fakeRegistrar(t, k.state, adopting)
	w := window(t)
	startRun(t, routedOptions(t, k.state, w, countingAgent))
	adopted(t, reg)
	w.waitFor(t, "ready")
	// Another client fills the program's input queue (1022 bytes) to 1000,
	// so that the window's first chunk only partly fits and stays under way.
	before := strings.Repeat("b", 1000)
	if err := dialKeeper(t, k.state).Input(testContext(t), testID, []byte(before)); err != nil {
		t.Fatal(err)
	}
	typed := strings.Repeat("a", 4096)
	go w.master.Write([]byte(typed))
	time.Sleep(300 * time.Millisecond)
	k.cancel()
	if !k.stopped(15 * time.Second) {
		t.Fatal("the keeper still runs")
	}
	n := typedCount(t, w)
	t.Logf("%d bytes reached the program", n)
	if n > len(before)+len(typed) || n <= len(before) {
		t.Fatalf("%d bytes reached the program, want at most the %d sent, each once", n, len(before)+len(typed))
	}
}

// A window that hangs up without a SIGHUP ends the agent all the same.
func TestAWindowThatHangsUpEndsTheAgent(t *testing.T) {
	w, reg, state, c := routedRun(t, `echo ready; sleep 300`)
	adopted(t, reg)
	w.waitFor(t, "ready")
	w.hangUp()
	if code := c.wait(t, 10*time.Second); code != 129 {
		t.Fatalf("Run returned %d, want 129", code)
	}
	if info, ok := listed(t, dialKeeper(t, state), testID); !ok || info.Exit == nil || info.Exit.Signal != "SIGHUP" {
		t.Fatalf("the keeper has %+v (exit %+v)", info, info.Exit)
	}
}

// Resizes against a keeper that does not answer never hold up a SIGHUP.
func TestASighupIsNeverLostBehindSlowResizes(t *testing.T) {
	state, k := startKeeperProcess(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	c := startRun(t, routedOptions(t, state, w, `echo ready; sleep 300`))
	adopted(t, reg)
	w.waitFor(t, "ready")
	if err := syscall.Kill(k.pid, syscall.SIGSTOP); err != nil {
		t.Fatal(err)
	}
	began := time.Now()
	for i := range 10 {
		if err := keeper.SetSize(w.slave, 20+i, 80); err != nil {
			t.Fatal(err)
		}
		c.signals <- syscall.SIGWINCH
	}
	c.signals <- syscall.SIGHUP
	took := time.Since(began)
	if err := syscall.Kill(k.pid, syscall.SIGCONT); err != nil {
		t.Fatal(err)
	}
	if took > 1500*time.Millisecond {
		t.Fatalf("the signals took %v to be taken", took)
	}
	if code := c.wait(t, 15*time.Second); code != 129 {
		t.Fatalf("Run returned %d, want 129", code)
	}
}
