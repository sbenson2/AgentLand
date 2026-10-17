//go:build darwin

package termrun

import (
	"syscall"
	"testing"
	"time"

	"agentland/host/keeper"
)

func attachOptions(state, id string, w *testWindow) AttachOptions {
	return AttachOptions{StatePath: state, Version: testVersion, ID: id, Stdin: w.slave, Stdout: w.slave, Stderr: w.slave}
}

func TestAttachShowsTheTerminalAndTypes(t *testing.T) {
	state := testKeeper(t)
	spawn(t, dialKeeper(t, state), "t1", `stty -echo; echo ready; while IFS= read -r l; do [ "$l" = bye ] && exit 5; echo "got:$l"; done`)
	w := window(t)
	before := w.termios(t)
	c := startAttach(t, attachOptions(state, "t1", w))
	w.waitFor(t, "ready")
	w.typeText(t, "hi\r")
	w.waitFor(t, "got:hi")
	w.typeText(t, "bye\r")
	if code := c.wait(t, 10*time.Second); code != 5 {
		t.Fatalf("Attach returned %d, want 5", code)
	}
	if after := w.termios(t); after != before {
		t.Fatalf("termios after %+v, before %+v", after, before)
	}
}

func TestAttachResizesTheTerminalToTheWindow(t *testing.T) {
	state := testKeeper(t)
	spawn(t, dialKeeper(t, state), "t1", `stty -echo; echo ready; while IFS= read -r l; do echo "size:$(stty size)"; done`)
	w := window(t)
	if err := keeper.SetSize(w.slave, 33, 99); err != nil {
		t.Fatal(err)
	}
	startAttach(t, attachOptions(state, "t1", w))
	w.waitFor(t, "ready")
	w.typeText(t, "\r")
	w.waitFor(t, "size:33 99")
}

func TestAttachUnknownID(t *testing.T) {
	state := testKeeper(t)
	w := window(t)
	if code := Attach(attachOptions(state, "term_nope", w)); code != 1 {
		t.Fatalf("Attach returned %d", code)
	}
	w.waitFor(t, "No running terminal term_nope.\r\n")
}

func TestAttachWithoutAKeeper(t *testing.T) {
	w := window(t)
	if code := Attach(attachOptions(stateFolder(t), "t1", w)); code != 1 {
		t.Fatalf("Attach returned %d", code)
	}
	w.waitFor(t, "AgentLand's terminal service isn't running.\r\n")
}

func TestAttachPrintsOneLineWhenTheKeeperGoes(t *testing.T) {
	k := startKeeper(t)
	adoptee(t, dialKeeper(t, k.state), "a1", `stty -echo; echo ready; while IFS= read -r l; do echo "got:$l"; done`)
	w := window(t)
	c := startAttach(t, attachOptions(k.state, "a1", w))
	w.waitFor(t, "ready")
	k.cancel()
	if code := c.wait(t, 15*time.Second); code != 1 {
		t.Fatalf("Attach returned %d, want 1", code)
	}
	w.waitFor(t, "AgentLand's terminal service stopped; this window is no longer connected.\r\n")
}

func TestAttachSighupLeavesTheTerminalRunning(t *testing.T) {
	state := testKeeper(t)
	control := dialKeeper(t, state)
	spawn(t, control, "t1", `echo ready; sleep 300`)
	w := window(t)
	c := startAttach(t, attachOptions(state, "t1", w))
	w.waitFor(t, "ready")
	c.signals <- syscall.SIGHUP
	if code := c.wait(t, 5*time.Second); code != 129 {
		t.Fatalf("Attach returned %d, want 129", code)
	}
	if info, ok := listed(t, control, "t1"); !ok || !info.Running {
		t.Fatalf("the terminal %+v (listed %v) after the window closed", info, ok)
	}
}
