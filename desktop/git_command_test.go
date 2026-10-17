package host

import (
	"context"
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testGit prepares repositories with the host's own isolated Git
// environment, so the owner's configuration never affects a test.
func testGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=Setup", "-c", "user.email=setup@example.com", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", "-c", "core.hooksPath=/dev/null"}, args...)...)
	command.Env = gitEnvironment(false, "", nil)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, output)
	}
	return string(output)
}

func TestGitOutputBuffers(t *testing.T) {
	tail := &tailOutput{limit: 8}
	tail.Write([]byte("abcdef"))
	tail.Write([]byte("ghij"))
	if string(tail.data) != "cdefghij" {
		t.Fatalf("tail %q", tail.data)
	}
	tail.Write([]byte("0123456789"))
	if string(tail.data) != "23456789" {
		t.Fatalf("tail %q", tail.data)
	}
	full := false
	head := &boundedOutput{limit: 4, onFull: func() { full = true }}
	if n, err := head.Write([]byte("abcdef")); n != 6 || err != nil || string(head.data) != "abcd" || !head.overflow || !full {
		t.Fatalf("head %q %v %v", head.data, head.overflow, full)
	}
}

func TestGitRunnerEnvironmentAndLimits(t *testing.T) {
	repo := t.TempDir()
	testGit(t, repo, "init", "-q")
	top, err := filepath.EvalSymlinks(repo)
	if err != nil {
		t.Fatal(err)
	}
	// Inherited GIT_* variables would point Git elsewhere or add configuration.
	t.Setenv("GIT_DIR", filepath.Join(t.TempDir(), "elsewhere"))
	t.Setenv("GIT_CONFIG_COUNT", "1")
	t.Setenv("GIT_CONFIG_KEY_0", "core.hooksPath")
	t.Setenv("GIT_CONFIG_VALUE_0", "hooks")
	if out, err := runGit(repo, 4096, "rev-parse", "--show-toplevel"); err != nil || strings.TrimSpace(string(out)) != top {
		t.Fatalf("top level %q %v", out, err)
	}
	if out, err := runGit(repo, 4096, "config", "--get", "core.hooksPath"); err != nil || strings.TrimSpace(string(out)) != "/dev/null" {
		t.Fatalf("hooks path %q %v", out, err)
	}
	if _, err := runGit(repo, 4, "rev-parse", "--show-toplevel"); !errors.Is(err, errGitOutputLimit) {
		t.Fatalf("output limit: %v", err)
	}
	timed := runGitCall(context.Background(), gitCall{directory: repo, args: []string{"status"}, timeout: time.Nanosecond, stdoutLimit: 4096})
	if !timed.timedOut || !errors.Is(timed.err, errGitTimeout) {
		t.Fatalf("timeout: %+v", timed)
	}
	failed := runGitCall(context.Background(), gitCall{directory: repo, args: []string{"rev-parse", "--verify", "missing-ref"}, stdoutLimit: 4096})
	if failed.err == nil || failed.exitCode != 128 || !strings.Contains(string(failed.stderr), "Needed a single revision") {
		t.Fatalf("failure: %+v %q", failed, failed.stderr)
	}
}
