package termrun

import (
	"context"
	"errors"
	"net"
	"path/filepath"

	"agentland/host/internal/localterm"
)

// Why the CLI started the real command, beside the host's refusal codes.
const (
	codeNoHost   = "no_host"   // no socket, or no one answers on it
	codeSlowHost = "slow_host" // the host took the connection but did not answer in time
	codeNoKeeper = "no_keeper" // the keeper does not answer, or cannot adopt
)

// hostCode is why a register that failed with err, talking to the host,
// started the real command: a host too slow to answer is running, and says
// so (codeSlowHost); any other failure is a host that isn't (codeNoHost).
func hostCode(err error) string {
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return codeSlowHost
	}
	return codeNoHost
}

// fallbackLine is the one line saying why AgentLand did not take the
// command name and started it as usual.
func fallbackLine(code, name string) string {
	var why string
	switch code {
	case codeNoHost:
		why = "AgentLand isn't running"
	case codeSlowHost:
		why = "AgentLand didn't answer in time"
	case localterm.CodeDisabled:
		why = "AgentLand's terminal access is off"
	case localterm.CodeLimit:
		why = "AgentLand has 16 terminals open"
	case localterm.CodeUnavailable, localterm.CodeVersion, codeNoKeeper:
		why = "AgentLand's terminal service isn't available"
	default:
		why = "AgentLand couldn't take this terminal"
	}
	return why + " — started " + filepath.Base(name) + " normally."
}
