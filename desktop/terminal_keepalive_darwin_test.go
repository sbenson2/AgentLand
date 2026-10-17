//go:build darwin

package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"agentland/host/keeper"
)

// While terminal access is on and the routing switch reads "on", the host
// keeps a keeper running, so `terminals run` never waits for one to start
// (terminal_keepalive.go).

// keepAliveState is a short state folder with a host binary to start keepers
// from; the cleanup stops any keeper left for it.
func keepAliveState(t *testing.T) (statePath, binary string) {
	t.Helper()
	saved := keeperKeepAliveEvery
	keeperKeepAliveEvery = 100 * time.Millisecond
	t.Cleanup(func() { keeperKeepAliveEvery = saved })
	statePath = filepath.Join(shortTempDir(t), "state.json")
	store := NewStore(statePath)
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: t.TempDir()}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	binary = hostBinary(t)
	t.Setenv("SHELL", "/bin/sh")
	t.Cleanup(func() {
		exec.Command(binary, "terminals", "stop", "--state", statePath).Run()
	})
	return statePath, binary
}

// keepAliveHost is a host on statePath whose terminals run in a real keeper.
func keepAliveHost(t *testing.T, statePath, binary string, terminalAccess bool) (*Host, TerminalBackend) {
	t.Helper()
	backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: statePath + ".terminals.log", Executable: binary, Version: "test"})
	host := NewWithOptions(NewStore(statePath), &fakeAgent{}, HostOptions{TerminalEnabled: terminalAccess, Terminals: backend})
	t.Cleanup(func() { host.Close() })
	return host, backend
}

// keeperPID is the process of the keeper serving statePath, or 0.
func keeperPID(t *testing.T, statePath string) int {
	t.Helper()
	out, err := exec.Command("/bin/ps", "-axo", "pid=,command=").Output()
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		pid, command, _ := strings.Cut(strings.TrimSpace(line), " ")
		if strings.Contains(command, " terminals serve --state "+statePath+" ") {
			n, _ := strconv.Atoi(pid)
			return n
		}
	}
	return 0
}

// waitForKeeper waits until a keeper other than not serves statePath and
// returns its process.
func waitForKeeper(t *testing.T, statePath string, not int) int {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for {
		if pid := keeperPID(t, statePath); pid != 0 && pid != not {
			return pid
		}
		if time.Now().After(deadline) {
			t.Fatal("no keeper started")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// noKeeperFor says no keeper served statePath for the whole of d.
func noKeeperFor(t *testing.T, statePath string, d time.Duration) {
	t.Helper()
	for deadline := time.Now().Add(d); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if pid := keeperPID(t, statePath); pid != 0 {
			t.Fatalf("a keeper started: pid %d", pid)
		}
	}
	if _, err := os.Lstat(keeper.SocketPath(statePath)); err == nil {
		t.Fatal("a keeper's socket is there")
	}
}

func TestTheRoutingSwitchKeepsAKeeperWithoutTerminals(t *testing.T) {
	statePath, binary := keepAliveState(t)
	setRoutingSwitch(t, statePath, true)
	_, backend := keepAliveHost(t, statePath, binary, true)
	waitForKeeper(t, statePath, 0)
	if infos, err := backend.List(t.Context()); err != nil || len(infos) != 0 {
		t.Fatalf("terminals %v, %v", infos, err)
	}
}

func TestTheRoutingSwitchOffStartsNoKeeper(t *testing.T) {
	statePath, binary := keepAliveState(t)
	host, _ := keepAliveHost(t, statePath, binary, true)
	noKeeperFor(t, statePath, time.Second)
	host.Close()
	// Terminal access off: the switch alone starts nothing.
	setRoutingSwitch(t, statePath, true)
	host, _ = keepAliveHost(t, statePath, binary, false)
	noKeeperFor(t, statePath, time.Second)
	host.Close()
	// Turning the switch on while a host with terminal access runs takes
	// effect at its next check.
	setRoutingSwitch(t, statePath, false)
	keepAliveHost(t, statePath, binary, true)
	noKeeperFor(t, statePath, 500*time.Millisecond)
	setRoutingSwitch(t, statePath, true)
	waitForKeeper(t, statePath, 0)
}

func TestAKilledKeeperIsStartedAgainWhileRoutingIsOn(t *testing.T) {
	statePath, binary := keepAliveState(t)
	setRoutingSwitch(t, statePath, true)
	keepAliveHost(t, statePath, binary, true)
	first := waitForKeeper(t, statePath, 0)
	if err := syscall.Kill(first, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	waitForKeeper(t, statePath, first)
}

// The real keeper's stopIdleKeeper (the replacement of a keeper from before
// adopt, Ruling 51): a keeper that holds a terminal is left as it is with
// the terminal running; once it holds none it is stopped, and the next
// start is a new keeper.
func TestStopIdleKeeperStopsOnlyAKeeperThatHoldsNothing(t *testing.T) {
	statePath, binary := keepAliveState(t)
	backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: statePath + ".terminals.log", Executable: binary, Version: "test"})
	t.Cleanup(func() { backend.Close() })
	stopper := backend.(oldKeeperBackend)
	ctx := t.Context()
	if _, err := backend.Features(ctx); err != nil {
		t.Fatal(err)
	}
	first := waitForKeeper(t, statePath, 0)
	if _, err := backend.Spawn(ctx, keeper.SpawnRequest{ID: "term_busy", Dir: t.TempDir(), Path: "/bin/sleep", Args: []string{"300"}, Rows: 24, Cols: 80}); err != nil {
		t.Fatal(err)
	}
	if stopped, err := stopper.stopIdleKeeper(ctx); stopped || err != nil {
		t.Fatalf("a keeper with a terminal: stopped %v, %v", stopped, err)
	}
	if infos, err := backend.List(ctx); err != nil || len(infos) != 1 || !infos[0].Running || keeperPID(t, statePath) != first {
		t.Fatalf("after: %+v, %v (keeper %d, was %d)", infos, err, keeperPID(t, statePath), first)
	}
	if _, err := backend.End(ctx, "term_busy"); err != nil {
		t.Fatal(err)
	}
	if err := backend.Forget(ctx, "term_busy"); err != nil {
		t.Fatal(err)
	}
	if stopped, err := stopper.stopIdleKeeper(ctx); !stopped || err != nil {
		t.Fatalf("an idle keeper: stopped %v, %v", stopped, err)
	}
	if _, err := backend.Features(ctx); err != nil {
		t.Fatal(err)
	}
	waitForKeeper(t, statePath, first)
}
