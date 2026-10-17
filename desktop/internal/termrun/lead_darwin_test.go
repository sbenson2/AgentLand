//go:build darwin

package termrun

import (
	"fmt"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Job control through the leader: Ctrl-Z typed in the window suspends the
// window's job, as it would with the switch off, and fg brings both back. A
// stop nobody at the window asked for is undone at once.

func TestCtrlZInTheWindowSuspendsAndFgResumes(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	// The agent reads ^Z as a key and suspends itself, as Claude Code does.
	o := routedOptions(t, state, w, `trap 'echo got-cont' CONT
stty -echo -isig
echo "ready:$$."
z=$(printf '\032')
while IFS= read -r l; do
	if [ "$l" = "$z" ]; then kill -TSTP $$; else echo "got:$l"; fi
done`)
	cli := startCLIProcess(t, o, w)
	adopted(t, reg)
	agentPID := w.readyPID(t)
	w.typeText(t, "\x1a\r")
	cli.waitStopped(t, 10*time.Second)
	if !stoppedProcess(agentPID) {
		t.Fatal("the agent runs on while its window's job is suspended")
	}
	if tio := w.termios(t); tio.Lflag&unix.ICANON == 0 || tio.Lflag&unix.ECHO == 0 {
		t.Fatalf("the window is still raw while suspended: lflag %#x", tio.Lflag)
	}
	suspendedAt := len(w.output())
	if out := w.output(); !strings.Contains(out[strings.Index(out, "ready:"):], focusOff) {
		t.Fatalf("focus reporting still on while suspended: %q", out)
	}
	if err := syscall.Kill(cli.pid, syscall.SIGCONT); err != nil { // the shell's fg
		t.Fatal(err)
	}
	w.waitFor(t, "got-cont")
	if stoppedProcess(agentPID) {
		t.Fatal("the agent is still stopped after fg")
	}
	if tio := w.termios(t); tio.Lflag&unix.ICANON != 0 {
		t.Fatal("the window is not raw after fg")
	}
	if !strings.Contains(w.output()[suspendedAt:], focusOn) {
		t.Fatalf("focus reporting not turned on again after fg: %q", w.output()[suspendedAt:])
	}
	w.typeText(t, "hello\r")
	w.waitFor(t, "got:hello")
	cli.neverStops(t, 200*time.Millisecond)
}

func TestAStopTheWindowDidNotAskForIsUndoneAtOnce(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `trap 'echo got-cont' CONT
echo "ready:$$."
while :; do sleep 0.05; done`)
	cli := startCLIProcess(t, o, w)
	adopted(t, reg)
	agentPID := w.readyPID(t)
	// Ctrl-Z typed on the phone: the line discipline stops the agent's group.
	if err := dialKeeper(t, state).Input(testContext(t), testID, []byte{0x1a}); err != nil {
		t.Fatal(err)
	}
	w.waitFor(t, "got-cont")
	if stoppedProcess(agentPID) {
		t.Fatal("the agent is still stopped")
	}
	cli.neverStops(t, time.Second)
}

// A suspend that the shell never carries out (the window's job cannot stop)
// leaves nothing stranded: the CLI continues the agent itself.
func TestASuspendThatNeverStopsResumesTheAgent(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `trap 'echo got-cont' CONT
stty -echo -isig
echo "ready:$$."
z=$(printf '\032')
while IFS= read -r l; do
	if [ "$l" = "$z" ]; then kill -TSTP $$; else echo "got:$l"; fi
done`)
	suspended := make(chan struct{}, 1)
	o.suspend = func() { suspended <- struct{}{} } // returns at once, as a discarded SIGTSTP does
	startRun(t, o)
	adopted(t, reg)
	w.readyPID(t)
	w.typeText(t, "\x1a\r")
	select {
	case <-suspended:
	case <-time.After(10 * time.Second):
		t.Fatal("the CLI never tried to suspend")
	}
	w.waitFor(t, "got-cont")
	w.typeText(t, "after\r")
	w.waitFor(t, "got:after")
}

// Run returns 128 plus the signal that ended the agent, and the keeper
// records the signal, even one Go itself would ignore (SIGUSR1) or turn into
// a traceback. (A signal that dumps core would leave crash reports behind on
// each run.)
func TestAnAgentKilledBySignalIsMirrored(t *testing.T) {
	w, reg, state, c := routedRun(t, `read -r l; kill -USR1 $$`)
	adopted(t, reg)
	w.typeText(t, "\r")
	if code := c.wait(t, 10*time.Second); code != 128+int(syscall.SIGUSR1) {
		t.Fatalf("Run returned %d, want SIGUSR1's %d", code, 128+int(syscall.SIGUSR1))
	}
	info, ok := listed(t, dialKeeper(t, state), testID)
	if !ok || info.Exit == nil || info.Exit.Signal != "SIGUSR1" {
		t.Fatalf("the keeper has %+v (exit %+v)", info, info.Exit)
	}
	if strings.Contains(w.output(), "goroutine") {
		t.Fatalf("a traceback reached the window: %q", w.output())
	}
}

// The CLI process ends by the agent's signal itself, once it has restored
// the window, so the shell reports the agent's death as it would with the
// switch off ("zsh: user-defined signal 1 claude"), with no core and no
// traceback (Ruling 49).
func TestTheCLIEndsByTheAgentsSignal(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	cli := startCLIProcess(t, routedOptions(t, state, w, `read -r l; kill -USR1 $$`), w)
	adopted(t, reg)
	w.typeText(t, "\r")
	status := cli.wait(t, 10*time.Second)
	if !status.Signaled() || status.Signal() != syscall.SIGUSR1 || status.CoreDump() {
		t.Fatalf("the CLI ended with status %#x (exited %v with %d), want a death by SIGUSR1 without a core", uint32(status), status.Exited(), status.ExitStatus())
	}
	if tio := w.termios(t); tio.Lflag&unix.ICANON == 0 || tio.Lflag&unix.ECHO == 0 {
		t.Fatalf("the window is still raw: lflag %#x", tio.Lflag)
	}
	info, ok := listed(t, dialKeeper(t, state), testID)
	if !ok || info.Exit == nil || info.Exit.Signal != "SIGUSR1" {
		t.Fatalf("the keeper has %+v (exit %+v)", info, info.Exit)
	}
	if strings.Contains(w.output(), "goroutine") {
		t.Fatalf("a traceback reached the window: %q", w.output())
	}
}

// An agent that exits with a signal's status by itself is not taken for one
// the signal ended: the CLI exits with the code.
func TestAnAgentExitingWithASignalsCodeIsNotRaised(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	code := 128 + int(syscall.SIGUSR1)
	cli := startCLIProcess(t, routedOptions(t, state, w, fmt.Sprintf(`read -r l; exit %d`, code)), w)
	adopted(t, reg)
	w.typeText(t, "\r")
	if status := cli.wait(t, 10*time.Second); !status.Exited() || status.ExitStatus() != code {
		t.Fatalf("the CLI ended with status %#x, want an exit with %d", uint32(status), code)
	}
}

// The agent runs as its own process group in the terminal's foreground,
// under a leader that leads the session.
func TestTheAgentLeadsTheForegroundUnderTheLeader(t *testing.T) {
	w, reg, _, _ := routedRun(t, `echo "ready:$$."; sleep 300`)
	adopted(t, reg)
	agentPID := w.readyPID(t)
	agentGroup, err := syscall.Getpgid(agentPID)
	if err != nil {
		t.Fatal(err)
	}
	session, err := unix.Getsid(agentPID)
	if err != nil {
		t.Fatal(err)
	}
	if agentGroup != agentPID || session == agentPID {
		t.Fatalf("agent %d: group %d, session %d", agentPID, agentGroup, session)
	}
	if leaderSession, err := unix.Getsid(session); err != nil || leaderSession != session {
		t.Fatalf("the leader %d does not lead its session: %d, %v", session, leaderSession, err)
	}
}

// Without a keeper, an agent that ignores the hang-up and SIGTERM is killed
// at 5 s with its whole group, never left running past its leader.
func TestAnAgentThatIgnoresTheHangUpIsKilledWithItsGroup(t *testing.T) {
	k := startKeeper(t)
	reg := fakeRegistrar(t, k.state, adopting)
	w := window(t)
	c := startRun(t, routedOptions(t, k.state, w, `trap '' HUP TERM; echo "ready:$$."; while :; do sleep 0.1; done`))
	adopted(t, reg)
	agentPID := w.readyPID(t)
	k.cancel()
	if !k.stopped(15 * time.Second) {
		t.Fatal("the keeper still runs")
	}
	c.signals <- syscall.SIGHUP
	if code := c.wait(t, 10*time.Second); code != 128+int(syscall.SIGKILL) {
		t.Fatalf("Run returned %d, want SIGKILL's %d", code, 128+int(syscall.SIGKILL))
	}
	deadline := time.Now().Add(3 * time.Second)
	for syscall.Kill(agentPID, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("the agent %d still runs", agentPID)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A device's End reaches what the agent left in its group: a child that
// ignores the hang-up gets SIGTERM, after the agent and its leader are gone.
func TestEndReachesAChildThatIgnoresTheHangUp(t *testing.T) {
	w, reg, state, c := routedRun(t, `(trap '' HUP; exec sleep 300) & echo "ready:$!."; wait`)
	adopted(t, reg)
	child := w.readyPID(t)
	t.Cleanup(func() { _ = syscall.Kill(child, syscall.SIGKILL) })
	if _, err := dialKeeper(t, state).End(testContext(t), testID); err != nil {
		t.Fatal(err)
	}
	if code := c.wait(t, 10*time.Second); code != 129 {
		t.Fatalf("Run returned %d, want 129", code)
	}
	deadline := time.Now().Add(time.Second)
	for syscall.Kill(child, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("the agent's child %d outlived End", child)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Under a wrapper script that runs the CLI without exec, Ctrl-Z suspends
// the whole job, wrapper included, as it does with the switch off; the
// agent's leader, in a session of its own, is never stopped by it.
func TestCtrlZUnderAWrapperSuspendsTheWholeJob(t *testing.T) {
	state := testKeeper(t)
	reg := fakeRegistrar(t, state, adopting)
	w := window(t)
	o := routedOptions(t, state, w, `trap 'echo got-cont' CONT
stty -echo -isig
echo "ready:$$."
z=$(printf '\032')
while IFS= read -r l; do
	if [ "$l" = "$z" ]; then kill -TSTP $$; else echo "got:$l"; fi
done`)
	// "; true" keeps sh from running the CLI with exec.
	wrapper := startCLIProcessWith(t, o, w, func(exe string) []string { return []string{"/bin/sh", "-c", "'" + exe + "'; true"} })
	adopted(t, reg)
	agentPID := w.readyPID(t)
	leader, err := unix.Getsid(agentPID)
	if err != nil {
		t.Fatal(err)
	}
	w.typeText(t, "\x1a\r")
	wrapper.waitStopped(t, 10*time.Second)
	if stoppedProcess(leader) {
		t.Fatal("the CLI's suspend stopped the agent's leader")
	}
	if err := syscall.Kill(-wrapper.pid, syscall.SIGCONT); err != nil { // the shell's fg
		t.Fatal(err)
	}
	w.waitFor(t, "got-cont")
	w.typeText(t, "hello\r")
	w.waitFor(t, "got:hello")
}
