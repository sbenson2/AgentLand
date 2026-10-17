//go:build darwin

package keeper

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestKeeperEnvironmentKeepsOnlyTheBasics(t *testing.T) {
	got := keeperEnvironment([]string{
		"AGENTLAND_LOCAL_SESSION_TOKEN=secret",
		"OPENCODE_SERVER_PASSWORD=secret",
		"ANTHROPIC_API_KEY=secret",
		"HOME=/Users/x",
		"PATH=/usr/bin",
		"LC_ALL=en_US.UTF-8",
	})
	sort.Strings(got)
	want := []string{"HOME=/Users/x", "LC_ALL=en_US.UTF-8", "PATH=/usr/bin"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestSupportErrorOffMacOS(t *testing.T) {
	for _, goos := range []string{"linux", "windows"} {
		if err := SupportError(goos); err == nil || err.Error() != "terminals need macOS" {
			t.Errorf("%s: %v", goos, err)
		}
	}
	if err := SupportError("darwin"); err != nil {
		t.Errorf("darwin: %v", err)
	}
}

func TestStartLaunchesADetachedKeeper(t *testing.T) {
	bin := hostBinary(t)
	dir := shortTempDir(t)
	state := filepath.Join(dir, "host.json")
	log := filepath.Join(dir, "terminals.log")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := Start(ctx, StartOptions{Executable: bin, StatePath: state, LogPath: log, Version: "test", Wait: 10 * time.Second}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(LockPath(state))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	// Read the pid and probe it only; the lock file's pid is never a kill target.
	t.Cleanup(func() {
		if c, err := Dial(context.Background(), SocketPath(state), "test"); err == nil {
			_ = c.StopAll(context.Background())
			c.Close()
		}
	})
	sid, err := getsid(pid)
	if err != nil {
		t.Fatal(err)
	}
	own, _ := getsid(os.Getpid())
	if sid != pid || sid == own {
		t.Fatalf("keeper session %d, pid %d, test session %d", sid, pid, own)
	}
	c, err := Dial(ctx, SocketPath(state), "test")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.StopAll(ctx); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for processAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("keeper %d still running", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestTerminalsStopWithNoKeeperSaysSo(t *testing.T) {
	bin := hostBinary(t)
	state := filepath.Join(shortTempDir(t), "host.json")
	out, err := exec.Command(bin, "terminals", "stop", "--state", state).CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if !strings.Contains(string(out), "no terminal keeper is running") {
		t.Fatalf("output: %s", out)
	}
}

func TestKeeperEnvironmentWithOnlySecretsIsEmptyNotNil(t *testing.T) {
	got := keeperEnvironment([]string{"AGENTLAND_LOCAL_SESSION_TOKEN=x", "ANTHROPIC_API_KEY=y"})
	if got == nil || len(got) != 0 {
		t.Fatalf("got %#v, want non-nil empty", got)
	}
}

func TestStartRefusesATooLongSocketPathWithoutLaunching(t *testing.T) {
	dir := filepath.Join(shortTempDir(t), strings.Repeat("d", 100))
	marker := filepath.Join(shortTempDir(t), "launched")
	script := filepath.Join(shortTempDir(t), "fake")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	err := Start(context.Background(), StartOptions{Executable: script, StatePath: filepath.Join(dir, "host.json"), Wait: time.Second})
	if err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("got %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	if _, statErr := os.Stat(marker); statErr == nil {
		t.Fatal("a child was launched")
	}
}

func TestStopWaitsForALockedKeeperWithNoSocket(t *testing.T) {
	bin := hostBinary(t)
	state := filepath.Join(shortTempDir(t), "host.json")
	release, err := TryLock(state)
	if err != nil {
		t.Fatal(err)
	}
	go func() { time.Sleep(700 * time.Millisecond); release() }()
	began := time.Now()
	out, err := exec.Command(bin, "terminals", "stop", "--state", state).CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if strings.Contains(string(out), "no terminal keeper is running") || time.Since(began) < 600*time.Millisecond {
		t.Fatalf("stop did not wait for the lock: %s", out)
	}
}
