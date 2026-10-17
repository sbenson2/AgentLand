package keeper

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
)

// shortTempDir makes a folder under /private/tmp. Its short path leaves room
// for a socket inside: t.TempDir's is often too long for one.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/private/tmp", "akt-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

var (
	hostBinaryOnce sync.Once
	hostBinaryPath string
	hostBinaryErr  error
)

// hostBinary builds cmd/agentland-host once per test run and returns its path.
func hostBinary(t *testing.T) string {
	t.Helper()
	hostBinaryOnce.Do(func() {
		dir, err := os.MkdirTemp("/private/tmp", "akb-")
		if err != nil {
			hostBinaryErr = err
			return
		}
		hostBinaryPath = filepath.Join(dir, "agentland-host")
		cmd := exec.Command("go", "build", "-o", hostBinaryPath, "./cmd/agentland-host")
		cmd.Dir = ".."
		if out, err := cmd.CombinedOutput(); err != nil {
			hostBinaryErr = fmt.Errorf("go build: %v\n%s", err, out)
		}
	})
	if hostBinaryErr != nil {
		t.Fatal(hostBinaryErr)
	}
	return hostBinaryPath
}

// TestMain removes the host binary's build folder after the tests.
func TestMain(m *testing.M) {
	code := m.Run()
	if hostBinaryPath != "" {
		os.RemoveAll(filepath.Dir(hostBinaryPath))
	}
	os.Exit(code)
}
