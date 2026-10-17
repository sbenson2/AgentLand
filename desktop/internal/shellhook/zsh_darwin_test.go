//go:build darwin

package shellhook

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"agentland/host/keeper"
)

// The hook in a real zsh: HOME is a temp folder with the block in its
// .zshrc, PATH has fake agents first, and the host binary is a fake that
// prints what it was asked to run and exits 7. Every child gets an
// environment made from scratch, so an AGENTLAND_TERMINAL this test runs
// under (an AgentLand terminal) never reaches it.

const fakeAgent = `#!/bin/sh
printf 'REAL %s ' "$(basename "$0")"
for a in "$@"; do printf '[%s]' "$a"; done
printf '\n'
`

// fakeHost prints its arguments; with an argument "wait" it then reads a line
// from its terminal, so it sits in the foreground.
const fakeHost = `#!/bin/sh
printf 'ROUTED '
for a in "$@"; do printf '[%s]' "$a"; done
printf '\n'
for a in "$@"; do
  if [ "$a" = wait ]; then IFS= read -r line; printf 'GOT %s\n' "$line"; fi
done
exit 7
`

type zshFixture struct {
	*fixture
	host string // the fake agentland-host, in a folder whose name needs quoting
	bin  string // the fake agents
}

func newZshFixture(t *testing.T) *zshFixture {
	t.Helper()
	if _, err := os.Stat("/bin/zsh"); err != nil {
		t.Skip("no /bin/zsh")
	}
	f := newFixture(t)
	root := filepath.Dir(f.home)
	f.state = filepath.Join(root, "Application Support", "AgentLand's", "host.json")
	z := &zshFixture{fixture: f, bin: filepath.Join(root, "bin"), host: filepath.Join(root, "AgentLand's app", "agentland-host")}
	for _, dir := range []string{z.bin, filepath.Dir(z.host)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"claude", "codex", "opencode"} {
		if err := os.WriteFile(filepath.Join(z.bin, name), []byte(fakeAgent), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(z.host, []byte(fakeHost), 0o755); err != nil {
		t.Fatal(err)
	}
	return z
}

func (z *zshFixture) options() Options {
	o := z.fixture.options()
	o.Executable = z.host
	return o
}

func (z *zshFixture) on(t *testing.T) {
	t.Helper()
	if err := On(z.options()); err != nil {
		t.Fatal(err)
	}
}

func (z *zshFixture) switchFile() string {
	_, _, state := Paths(z.state)
	return state
}

// routed is what the fake host prints for command and its arguments.
func (z *zshFixture) routed(command ...string) string {
	out := "ROUTED "
	for _, arg := range append([]string{"terminals", "run", "--state", z.state, "--"}, command...) {
		out += "[" + arg + "]"
	}
	return out + "\n"
}

// env is a fresh environment: no ZDOTDIR, no AGENTLAND_TERMINAL.
func (z *zshFixture) env(extra ...string) []string {
	return append([]string{"HOME=" + z.home, "PATH=" + z.bin + ":/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "USER=agentland-test"}, extra...)
}

// tty is a zsh on a terminal, as in a Terminal.app window.
type tty struct {
	cmd    *exec.Cmd
	master *os.File
	mu     sync.Mutex
	out    []byte
	read   chan struct{}
	exited chan struct{}
	err    error
}

func (z *zshFixture) start(t *testing.T, args []string, extra ...string) *tty {
	t.Helper()
	master, slave, err := keeper.OpenPTY()
	if err != nil {
		t.Fatal(err)
	}
	if err := keeper.SetSize(slave, 24, 80); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/zsh", args...)
	cmd.Env, cmd.Dir = z.env(extra...), z.home
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	slave.Close()
	w := &tty{cmd: cmd, master: master, read: make(chan struct{}), exited: make(chan struct{})}
	go func() {
		defer close(w.read)
		buf := make([]byte, 32<<10)
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
	go func() {
		w.err = cmd.Wait()
		close(w.exited)
	}()
	t.Cleanup(func() {
		select {
		case <-w.exited:
		default:
			syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-w.exited
		}
		master.Close()
		<-w.read
	})
	return w
}

// output is what the terminal showed, its line ends as the program wrote them.
func (w *tty) output() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.ReplaceAll(string(w.out), "\r\n", "\n")
}

func (w *tty) waitFor(t *testing.T, want string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !strings.Contains(w.output(), want) {
		if time.Now().After(deadline) {
			t.Fatalf("the terminal never showed %q; it shows %q", want, w.output())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (w *tty) typeText(t *testing.T, text string) {
	t.Helper()
	if _, err := w.master.Write([]byte(text)); err != nil {
		t.Fatal(err)
	}
}

// wait waits for zsh to exit and for the terminal's last output.
func (w *tty) wait(t *testing.T) string {
	t.Helper()
	select {
	case <-w.exited:
	case <-time.After(20 * time.Second):
		t.Fatalf("zsh did not exit; the terminal shows %q", w.output())
	}
	select {
	case <-w.read:
	case <-time.After(2 * time.Second):
	}
	return w.output()
}

// inTerminal runs command in `zsh -i -c` on a terminal and returns what it showed.
func (z *zshFixture) inTerminal(t *testing.T, command string, extra ...string) string {
	t.Helper()
	return z.start(t, []string{"-i", "-c", command}, extra...).wait(t)
}

// withoutTerminal runs command in `zsh -i -c` with pipes for its input and output.
func (z *zshFixture) withoutTerminal(t *testing.T, command string) string {
	t.Helper()
	cmd := exec.Command("/bin/zsh", "-i", "-c", command)
	cmd.Env, cmd.Dir = z.env(), z.home
	cmd.Stdin = strings.NewReader("")
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if err != nil && !errors.As(err, &exit) {
		t.Fatal(err)
	}
	return string(out)
}

func TestAnInteractiveAgentIsRouted(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	if out := z.inTerminal(t, "claude hello"); !strings.Contains(out, z.routed("claude", "hello")) {
		t.Fatalf("%q", out)
	}
	if out := z.inTerminal(t, "opencode"); !strings.Contains(out, z.routed("opencode")) {
		t.Fatalf("%q", out)
	}
}

func TestSwitchOffRoutesNothing(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	if err := os.Remove(z.switchFile()); err != nil {
		t.Fatal(err)
	}
	if out := z.inTerminal(t, "claude hello"); !strings.Contains(out, "REAL claude [hello]\n") || strings.Contains(out, "ROUTED") {
		t.Fatalf("%q", out)
	}
	// A switch file that says anything but on routes nothing either.
	if err := os.WriteFile(z.switchFile(), []byte("off\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out := z.inTerminal(t, "claude hello"); !strings.Contains(out, "REAL claude [hello]\n") || strings.Contains(out, "ROUTED") {
		t.Fatalf("%q", out)
	}
}

func TestPipesPrintAndSubcommandsAreNotRouted(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	for _, c := range []struct{ command, want string }{
		{"claude -p hi", "REAL claude [-p][hi]"},
		{"claude --print=hi", "REAL claude [--print=hi]"},
		{"echo x | claude", "REAL claude \n"},
		{"claude hi | cat", "REAL claude [hi]"},
		{"claude hi > out.txt; cat out.txt", "REAL claude [hi]"},
		{"claude hi 2> err.log", "REAL claude [hi]"},
		{"claude --version", "REAL claude [--version]"},
		{"claude update", "REAL claude [update]"},
		{"claude help", "REAL claude [help]"},
		// Claude Code 2.1.301: a background session returns at once, and
		// its subcommands start no session in this terminal.
		{"claude --bg fix it", "REAL claude [--bg][fix][it]"},
		{"claude --model opus --background", "REAL claude [--model][opus][--background]"},
		{"claude agents", "REAL claude [agents]"},
		{"claude attach x", "REAL claude [attach][x]"},
		{"claude logs x", "REAL claude [logs][x]"},
		{"claude stop x", "REAL claude [stop][x]"},
		{"claude kill x", "REAL claude [kill][x]"},
		{"claude rm x", "REAL claude [rm][x]"},
		{"claude respawn --all", "REAL claude [respawn][--all]"},
		{"claude purge", "REAL claude [purge]"},
		{"claude auth login", "REAL claude [auth][login]"},
		{"claude auto-mode config", "REAL claude [auto-mode][config]"},
		{"claude import codex", "REAL claude [import][codex]"},
		{"claude gateway", "REAL claude [gateway]"},
		{"claude ultrareview", "REAL claude [ultrareview]"},
		{"claude plugins", "REAL claude [plugins]"},
		{"codex exec x", "REAL codex [exec][x]"},
		{"opencode run x", "REAL opencode [run][x]"},
	} {
		if out := z.inTerminal(t, c.command); !strings.Contains(out, c.want) || strings.Contains(out, "ROUTED") {
			t.Errorf("%s: %q", c.command, out)
		}
	}
	// --bg is Claude Code's alone; another agent's --bg routes, and so does a
	// prompt that only mentions it.
	if out := z.inTerminal(t, "codex --bg"); !strings.Contains(out, z.routed("codex", "--bg")) {
		t.Errorf("codex --bg: %q", out)
	}
	if out := z.inTerminal(t, "claude 'what does --bg do'"); !strings.Contains(out, z.routed("claude", "what does --bg do")) {
		t.Errorf("a prompt that mentions --bg: %q", out)
	}
	// "--" ends the flags the hook reads: what follows is the agent's prompt.
	if out := z.inTerminal(t, "claude -- -p"); !strings.Contains(out, z.routed("claude", "--", "-p")) {
		t.Errorf("claude -- -p: %q", out)
	}
	// A shell with no terminal at all routes nothing.
	if out := z.withoutTerminal(t, "claude hi"); !strings.Contains(out, "REAL claude [hi]") || strings.Contains(out, "ROUTED") {
		t.Errorf("without a terminal: %q", out)
	}
}

func TestANestedAgentLandTerminalIsNotRouted(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	if out := z.inTerminal(t, "claude hi", "AGENTLAND_TERMINAL=term_x"); !strings.Contains(out, "REAL claude [hi]") || strings.Contains(out, "ROUTED") {
		t.Fatalf("%q", out)
	}
}

func TestAMissingHostBinaryRunsTheRealCommand(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	if err := os.Remove(z.host); err != nil {
		t.Fatal(err)
	}
	if out := z.inTerminal(t, "claude hi; echo \"code=$?\""); !strings.Contains(out, "REAL claude [hi]\ncode=0") {
		t.Fatalf("%q", out)
	}
}

func TestArgumentsWithSpacesAndQuotesPassThroughUnchanged(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	out := z.inTerminal(t, `claude 'a b' "it's" $'x\ny' ünï 'fix the "login" bug'`)
	if want := z.routed("claude", "a b", "it's", "x\ny", "ünï", `fix the "login" bug`); !strings.Contains(out, want) {
		t.Fatalf("%q\nwant %q", out, want)
	}
}

func TestAUserFunctionOfTheSameNameIsLeftAlone(t *testing.T) {
	z := newZshFixture(t)
	z.write(t, "claude() { echo MINE }\n")
	z.on(t)
	if out := z.inTerminal(t, "claude hi"); !strings.Contains(out, "MINE") || strings.Contains(out, "ROUTED") {
		t.Fatalf("%q", out)
	}
}

func TestAnAliasStillRoutesWithItsWords(t *testing.T) {
	z := newZshFixture(t)
	z.write(t, "alias claude='claude --model opus'\n")
	z.on(t)
	if out := z.inTerminal(t, "claude hi"); !strings.Contains(out, z.routed("claude", "--model", "opus", "hi")) {
		t.Fatalf("%q", out)
	}
}

func TestTurningOffTakesEffectInAnOpenShell(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	out := z.inTerminal(t, "claude a; rm "+quote(z.switchFile())+"; claude b")
	routed := strings.Index(out, z.routed("claude", "a"))
	real := strings.Index(out, "REAL claude [b]\n")
	if routed < 0 || real < routed || strings.Contains(out, "[b]\nROUTED") {
		t.Fatalf("%q", out)
	}
}

func TestTheExitCodeComesBack(t *testing.T) {
	z := newZshFixture(t)
	z.on(t)
	if out := z.inTerminal(t, `claude x; echo "code=$?"`); !strings.Contains(out, "code=7") {
		t.Fatalf("%q", out)
	}
}

// ^Z typed while a routed agent runs suspends it as one of zsh's jobs and
// gives the prompt back; fg brings it back to the foreground, where it reads
// the terminal and finishes; and the shell routes again afterwards.
//
// zsh 5.9 runs a suspended function on in a forked shell, which is not the
// stopped program's parent: after fg, $? is that shell's (0, not the
// program's code), and the job has no name in zsh's messages. Every zsh
// function does that, also one that is not AgentLand's (`f() { prog }`), so
// it is not asserted here.
func TestSuspendAndFgThroughTheHook(t *testing.T) {
	z := newZshFixture(t)
	z.write(t, "PS1='READY%# '\n")
	z.on(t)
	w := z.start(t, []string{"-i"})
	w.waitFor(t, "READY")
	w.typeText(t, "claude wait\r")
	w.waitFor(t, z.routed("claude", "wait"))
	w.typeText(t, "\x1a")
	w.waitFor(t, "zsh: suspended")
	w.typeText(t, "jobs\r")
	w.waitFor(t, "[1]  + suspended")
	w.typeText(t, "fg\r")
	w.waitFor(t, "[1]  + continued")
	w.typeText(t, "hello\r")
	w.waitFor(t, "GOT hello\n")
	w.typeText(t, "claude again; echo \"code=$?\"\r")
	w.waitFor(t, z.routed("claude", "again"))
	w.waitFor(t, "code=7")
	w.typeText(t, "exit\r")
	w.wait(t)
}

// A user's `setopt ignore_close_braces`, under which a closing brace counts
// only where a command can start, still gets every function, and the hook
// prints nothing while it loads.
func TestTheHookLoadsUnderIgnoreCloseBraces(t *testing.T) {
	z := newZshFixture(t)
	z.write(t, "setopt ignore_close_braces\n")
	z.on(t)
	if out := z.inTerminal(t, "claude hi"); out != z.routed("claude", "hi") {
		t.Fatalf("%q\nwant %q", out, z.routed("claude", "hi"))
	}
}

// controlSequence is a terminal control sequence (CSI).
var controlSequence = regexp.MustCompile(`\x1b\[[0-9;?]*[A-Za-z]`)

// A block whose hook folder is gone (the state folder removed) prints
// nothing, and the first prompt's $? is 0, so a prompt theme shows no error.
func TestABlockWithoutItsHookIsQuiet(t *testing.T) {
	z := newZshFixture(t)
	z.write(t, "unsetopt prompt_cr prompt_sp\nPS1='READY[%?] '\n")
	z.on(t)
	dir, _, _ := Paths(z.state)
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	w := z.start(t, []string{"-i"})
	w.waitFor(t, "READY[")
	w.waitFor(t, "] ")
	// zsh's line editor sends its own control sequences around the prompt.
	if out := controlSequence.ReplaceAllString(w.output(), ""); out != "READY[0] " {
		t.Fatalf("a new shell showed %q, want %q", w.output(), "READY[0] ")
	}
	w.typeText(t, "exit\r")
	w.wait(t)
}
