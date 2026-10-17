//go:build !windows

package host

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// pidIn reads the pid a fake wrote in path, 0 before it did.
func pidIn(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

// wantGroupEnded checks that the run and its tool were gone about grace
// after the stop: SIGKILL to the group at the grace, not before and not
// never.
func wantGroupEnded(t *testing.T, started time.Time, grace time.Duration, pids ...int) {
	t.Helper()
	gone := untilGone(started.Add(grace+3*time.Second), pids...)
	if gone.IsZero() {
		t.Fatalf("still running %v after the stop (gone: %v)", time.Since(started), pids)
	}
	if elapsed := gone.Sub(started); elapsed < grace-150*time.Millisecond || elapsed > grace+900*time.Millisecond {
		t.Fatalf("gone %v after the stop, want about %v", elapsed, grace)
	}
}

// A one-shot `claude -p` run is its own process group: a stop gives the
// group SIGTERM at once and SIGKILL after oneShotStopGrace, the host's
// shutdown after agentShutdownKill, so a run and a tool of it that ignore
// SIGTERM are gone.
func TestClaudeOneShotEndsItsProcessGroup(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		name, cause, grace := "stop", error(nil), oneShotStopGrace
		if shutdown {
			name, cause, grace = "shutdown", errHostShutdown, agentShutdownKill
		}
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			claude := writeScript(t, filepath.Join(dir, "claude"), fmt.Sprintf(`echo $$ > '%[1]s/run.pid'
trap 'echo term >> "%[1]s/terms"' TERM
(trap '' TERM; exec sleep 60) &
echo $! > '%[1]s/tool.pid'
while :; do sleep 0.05; done
`, dir))
			ctx, stop := context.WithCancelCause(context.Background())
			defer stop(nil)
			done := make(chan error, 1)
			go func() {
				_, err := runCLIOneShot(ctx, claude, "claude", t.TempDir(), "", "hello", nil)
				done <- err
			}()
			var run, tool int
			waitFor(t, "the run and its tool", func() bool {
				run, tool = pidIn(filepath.Join(dir, "run.pid")), pidIn(filepath.Join(dir, "tool.pid"))
				return run > 0 && tool > 0
			})
			endIfLeft(t, run, tool)
			started := time.Now()
			stop(cause)
			wantGroupEnded(t, started, grace, run, tool)
			if terms, _ := os.ReadFile(filepath.Join(dir, "terms")); !strings.Contains(string(terms), "term") {
				t.Fatal("the run got no SIGTERM")
			}
			select {
			case err := <-done:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("the run ended with %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("runCLIOneShot did not return")
			}
		})
	}
}

// The codex exec fallback runs each prompt in its own process group: Stop
// gives the group SIGTERM at once and SIGKILL after oneShotStopGrace, the
// host's shutdown (BeginShutdown) after agentShutdownKill, so a run and a
// tool of it that ignore SIGTERM are gone.
func TestCodexExecEndsItsProcessGroup(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		name, grace := "stop", oneShotStopGrace
		if shutdown {
			name, grace = "shutdown", agentShutdownKill
		}
		t.Run(name, func(t *testing.T) {
			fake := newCodexFake(t)
			config := fake.config()
			config.execOnly = true
			f := newCodexFixtureWith(t, fake, config)
			id := f.newChat()
			f.send(id, "EXECSTUBBORN now", nil)
			var run, tool int
			waitFor(t, "the exec run and its tool", func() bool {
				for _, entry := range fake.log() {
					if entry.ExecPid > 0 {
						run = entry.ExecPid
					}
				}
				tool = pidIn(filepath.Join(fake.state, "exec-tool.pid"))
				return run > 0 && tool > 0
			})
			endIfLeft(t, run, tool)
			started := time.Now()
			if shutdown {
				f.host.BeginShutdown()
			} else if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
				t.Fatalf("abort: %d %s", w.Code, w.Body)
			}
			wantGroupEnded(t, started, grace, run, tool)
			termed := false
			for _, entry := range fake.log() {
				termed = termed || entry.Term == run
			}
			if !termed {
				t.Fatal("the run got no SIGTERM")
			}
			f.idle(id)
		})
	}
}
