package host

import (
	"context"
	"errors"
	"os"
	"runtime"
	"sync"
	"time"
)

// One-shot runs: `claude -p` (HostCLIChatRunner) and the `codex exec`
// fallback (codex_exec.go) run one prompt per process. Each runs in a
// process group of its own, so the tools it starts end with it. A stopped
// run's group gets SIGTERM at once and SIGKILL after a grace: agentShutdownKill
// when the host shuts down, oneShotStopGrace on Stop or at a time limit.

// oneShotStopGrace is how long a one-shot run has between SIGTERM and
// SIGKILL when it is stopped (Stop, or its time limit): the time codex exec
// already gave its output after it ended.
const oneShotStopGrace = 2 * time.Second

// errHostShutdown is the cause a one-shot run's context ends with when the
// host shuts down (CLIChats.stopAgents).
var errHostShutdown = errors.New("the host is shutting down")

// oneShotGraceFor is a stopped run's grace: agentShutdownKill when its
// context ended with the host's shutdown, else oneShotStopGrace.
func oneShotGraceFor(ctx context.Context) time.Duration {
	if errors.Is(context.Cause(ctx), errHostShutdown) {
		return agentShutdownKill
	}
	return oneShotStopGrace
}

// oneShotGroup ends a one-shot run's process group, never another: it
// signals only until the run was reaped.
type oneShotGroup struct {
	process *os.Process
	mu      sync.Mutex
	reaped  bool
}

func newOneShotGroup(process *os.Process) *oneShotGroup {
	return &oneShotGroup{process: process}
}

// stop sends the group SIGTERM now and SIGKILL after grace, unless the run
// was reaped by then. A later stop with a shorter grace kills sooner.
// Windows has no SIGTERM to send, so the run ends at once there, as Codex's
// app-server does (codexTerminateGroup).
func (g *oneShotGroup) stop(grace time.Duration) {
	if runtime.GOOS == "windows" {
		g.signal(true)
		return
	}
	g.signal(false)
	time.AfterFunc(grace, func() { g.signal(true) })
}

func (g *oneShotGroup) signal(kill bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.reaped {
		claudeSignalGroup(g.process, kill)
	}
}

// ended records that Wait reaped the run and ends what is left of its
// group: the tools it started.
func (g *oneShotGroup) ended() {
	g.mu.Lock()
	g.reaped = true
	g.mu.Unlock()
	claudeReapGroup(g.process.Pid)
}
