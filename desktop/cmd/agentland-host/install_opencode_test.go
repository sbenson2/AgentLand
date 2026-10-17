package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	host "agentland/host"
)

// captureStdout runs fn and returns what it wrote on stdout.
func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	runErr := fn()
	writer.Close()
	os.Stdout = original
	data, err := io.ReadAll(reader)
	reader.Close()
	if err != nil {
		t.Fatal(err)
	}
	return string(data), runErr
}

// A command line install-opencode cannot run still gets one failed event on
// stdout, and a non-zero exit (an error).
func TestInstallOpenCodeRefusesItsArguments(t *testing.T) {
	state := filepath.Join(t.TempDir(), "host.json")
	for _, args := range [][]string{{"install-opencode", "--state", state, "extra"}, {"install-opencode", "--unknown"}} {
		output, err := captureStdout(t, func() error { return run(args) })
		if err == nil || !strings.HasPrefix(output, `{"event":"failed","code":"invalid_arguments","error":`) || strings.Count(output, "\n") != 1 {
			t.Errorf("%v: %q %v", args, output, err)
		}
	}
	if _, err := os.Stat(state + ".agents"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused command made the agents folder: %v", err)
	}
}

// serve holds the state's lock while it runs, the lock install-opencode
// takes: it does not start while another process holds it.
func TestServeRefusesAStateInUse(t *testing.T) {
	t.Setenv("AGENTLAND_OPENCODE_PASSWORD", "")
	state := filepath.Join(t.TempDir(), "host.json")
	if err := run([]string{"init", "--state", state, "--project", "p=Project=" + t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	release, err := host.LockState(state)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	err = run([]string{"serve", "--state", state, "--listen", "127.0.0.1:0", "--dev-http", "--no-agents"})
	if !errors.Is(err, host.ErrStateBusy) || !strings.Contains(err.Error(), state) {
		t.Fatalf("serve while the state is in use: %v", err)
	}
}
