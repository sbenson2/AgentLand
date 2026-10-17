package host

import (
	"errors"
	"os"
	"testing"
	"time"

	"agentland/host/internal/shellhook"
)

// The keeper's start attempts are at most one per keeperKeepAliveEvery,
// however often a keeper stops.
func TestKeeperKeepAliveTriesAtMostOncePerInterval(t *testing.T) {
	saved := keeperKeepAliveEvery
	keeperKeepAliveEvery = 200 * time.Millisecond
	t.Cleanup(func() { keeperKeepAliveEvery = saved })
	_, store, base := testHost(t)
	setRoutingSwitch(t, store.Path, true)
	fixture := newTerminalFixture(base)
	fixture.setStatus(KeeperNone)
	fixture.setFeaturesErr(errors.New("no keeper can start"))
	created := time.Now()
	host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals})
	t.Cleanup(func() { host.Close() })
	// A keeper stops every 5 ms: without the limit that is a start each time.
	for time.Since(created) < 500*time.Millisecond {
		host.terminals.keeperStopped()
		time.Sleep(5 * time.Millisecond)
	}
	calls, elapsed := fixture.featuresCalls(), time.Since(created)
	if limit := int(elapsed/keeperKeepAliveEvery) + 1; calls < 2 || calls > limit {
		t.Fatalf("%d start attempts in %v, want 2 to %d", calls, elapsed, limit)
	}
	// Closing stops the attempts.
	host.Close()
	calls = fixture.featuresCalls()
	time.Sleep(3 * keeperKeepAliveEvery)
	if after := fixture.featuresCalls(); after != calls {
		t.Fatalf("%d start attempts after Close", after-calls)
	}
}

// A keeper that runs, or one that cannot be used, is left alone.
func TestKeeperKeepAliveStartsNothingWhileAKeeperAnswers(t *testing.T) {
	saved := keeperKeepAliveEvery
	keeperKeepAliveEvery = 20 * time.Millisecond
	t.Cleanup(func() { keeperKeepAliveEvery = saved })
	for _, status := range []KeeperStatus{KeeperRunning, KeeperUnusable} {
		_, store, base := testHost(t)
		setRoutingSwitch(t, store.Path, true)
		fixture := newTerminalFixture(base)
		fixture.setStatus(status)
		host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals})
		time.Sleep(200 * time.Millisecond)
		host.Close()
		if calls := fixture.featuresCalls(); calls != 0 {
			t.Fatalf("status %v: %d start attempts", status, calls)
		}
	}
}

// A keeper from an AgentLand before adopt, which can't take routed agents,
// is stopped while it holds nothing, so a keeper of this build takes its
// place (Ruling 51).
func TestAnIdleKeeperFromBeforeAdoptIsReplaced(t *testing.T) {
	saved := keeperKeepAliveEvery
	keeperKeepAliveEvery = 20 * time.Millisecond
	t.Cleanup(func() { keeperKeepAliveEvery = saved })
	_, store, base := testHost(t)
	setRoutingSwitch(t, store.Path, true)
	fixture := newTerminalFixture(base)
	fixture.setFeatures(nil)
	host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals})
	t.Cleanup(func() { host.Close() })
	deadline := time.Now().Add(5 * time.Second)
	for fixture.idleStopCalls() == 0 || fixture.featuresCalls() == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("%d stops and %d starts", fixture.idleStopCalls(), fixture.featuresCalls())
		}
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(10 * keeperKeepAliveEvery)
	if stops := fixture.idleStopCalls(); stops != 1 {
		t.Fatalf("%d stops", stops)
	}
}

// One that holds terminals is left as it is, and never ends them; so is one
// the switch doesn't ask for, and one of this build's.
func TestAKeeperFromBeforeAdoptWithTerminalsIsKept(t *testing.T) {
	saved := keeperKeepAliveEvery
	keeperKeepAliveEvery = 20 * time.Millisecond
	t.Cleanup(func() { keeperKeepAliveEvery = saved })
	host, store, token, fixture := terminalTestHost(t, true)
	fixture.setFeatures(nil)
	time.Sleep(10 * keeperKeepAliveEvery) // the switch is off
	info := createTerminalFixture(t, host, token)
	setRoutingSwitch(t, store.Path, true)
	time.Sleep(10 * keeperKeepAliveEvery)
	if stops, starts := fixture.idleStopCalls(), fixture.featuresCalls(); stops != 0 || starts != 0 {
		t.Fatalf("%d stops and %d starts", stops, starts)
	}
	if len(fixture.endedIDs()) != 0 || !macEntry(host, info.ID).running() {
		t.Fatalf("a terminal ended: %v", fixture.endedIDs())
	}
	_, store, base := testHost(t)
	setRoutingSwitch(t, store.Path, true)
	current := newTerminalFixture(base)
	other := NewWithOptions(store, current, HostOptions{TerminalEnabled: true, Terminals: current.fakeTerminals})
	t.Cleanup(func() { other.Close() })
	time.Sleep(10 * keeperKeepAliveEvery)
	if stops := current.idleStopCalls(); stops != 0 {
		t.Fatalf("this build's keeper was stopped %d times", stops)
	}
}

// A terminal on its way into the keeper (counted in starting, not yet
// listed) keeps an older keeper from being stopped under it.
func TestAKeeperFromBeforeAdoptIsNotStoppedUnderAStartingTerminal(t *testing.T) {
	saved := keeperKeepAliveEvery
	keeperKeepAliveEvery = 10 * time.Millisecond
	t.Cleanup(func() { keeperKeepAliveEvery = saved })
	host, store, token, fixture := terminalTestHost(t, true)
	fixture.setFeatures(nil)
	fixture.mu.Lock()
	fixture.spawnEntered, fixture.spawnRelease = make(chan struct{}), make(chan struct{})
	entered, release := fixture.spawnEntered, fixture.spawnRelease
	fixture.mu.Unlock()
	created := make(chan int, 1)
	go func() {
		response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80})
		created <- response.Code
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("creation did not start")
	}
	setRoutingSwitch(t, store.Path, true)
	time.Sleep(20 * keeperKeepAliveEvery)
	close(release)
	if code := <-created; code != 201 {
		t.Fatalf("create: %d", code)
	}
	time.Sleep(20 * keeperKeepAliveEvery)
	if stops := fixture.idleStopCalls(); stops != 0 {
		t.Fatalf("the keeper was stopped %d times under a starting terminal", stops)
	}
}

// setRoutingSwitch writes or removes the routing switch for statePath.
func setRoutingSwitch(t *testing.T, statePath string, on bool) {
	t.Helper()
	dir, _, state := shellhook.Paths(statePath)
	if !on {
		if err := os.Remove(state); err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
		return
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(state, []byte("on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}
