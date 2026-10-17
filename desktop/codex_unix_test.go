//go:build !windows

package host

import (
	"syscall"
	"testing"
	"time"
)

// The host's shutdown ends Codex's app-server within about a second, as it
// ends Claude Code's and the ACP agents' processes
// (TestClaudeShutdownEndsTheProcessGroupWithinASecond): its input closes and
// its group gets SIGTERM at once, SIGKILL a second later. The Mac app kills
// the host 2 s after asking it to stop.
func TestCodexShutdownEndsTheAppServerWithinASecond(t *testing.T) {
	// An app-server that outlives its input's end and ignores SIGTERM.
	fake := newCodexFake(t, "AGENTLAND_CODEX_FAKE_STUBBORN=1")
	f := newCodexFixture(t, fake)
	id := f.newChat()
	f.send(id, "hello", nil)
	f.idle(id)
	pid := 0
	for _, entry := range fake.log() {
		if entry.Start != 0 {
			pid = entry.Start
		}
	}
	if pid == 0 {
		t.Fatal("the fake app-server did not start")
	}
	started := time.Now()
	f.host.BeginShutdown()
	deadline := started.Add(3 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("the app-server %d is still running %v after shutdown began", pid, time.Since(started))
		}
		time.Sleep(5 * time.Millisecond)
	}
	if elapsed := time.Since(started); elapsed > 1500*time.Millisecond {
		t.Fatalf("the app-server ended %v after shutdown began, want about a second", elapsed)
	}
}
