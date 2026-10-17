package keeper

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// errNeedsMacOS is what the keeper's entry points return off macOS.
var errNeedsMacOS = errors.New("terminals need macOS")

// ExitKeeperRunning is the exit status of `terminals serve` when another
// keeper already holds the lock. Start relaunches only on this status.
const ExitKeeperRunning = 75

// ErrKeeperDidNotStart means no keeper answered within StartOptions.Wait.
var ErrKeeperDidNotStart = errors.New("the terminal keeper did not start")

// StartOptions configures Start.
type StartOptions struct {
	// Executable is the agentland-host binary to run as the keeper.
	Executable string
	// StatePath is the host's state file; the keeper's socket sits beside it.
	StatePath string
	// LogPath is the keeper's lifecycle log. Empty means DefaultLogPath().
	LogPath string
	// Version is this build's version, told to the keeper in the hello.
	Version string
	// Wait is how long Start waits for the socket to answer. Zero means 3 s.
	Wait time.Duration
}

const defaultStartWait = 3 * time.Second

// keeperEnvironment keeps the variables a keeper (and so every terminal's
// shell) may inherit: no tokens, passwords or API keys from the host.
func keeperEnvironment(environ []string) []string {
	kept := []string{} // never nil: a nil Env would inherit everything
	for _, entry := range environ {
		name, _, _ := strings.Cut(entry, "=")
		switch name {
		case "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PATH":
			kept = append(kept, entry)
		default:
			if strings.HasPrefix(name, "LC_") {
				kept = append(kept, entry)
			}
		}
	}
	return kept
}

// DefaultLogPath is where the keeper writes its log:
// ~/Library/Logs/AgentLand/terminals.log.
func DefaultLogPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "agentland-terminals.log")
	}
	return filepath.Join(home, "Library", "Logs", "AgentLand", "terminals.log")
}

// SupportError is nil where terminals run (macOS) and says so elsewhere.
func SupportError(goos string) error {
	if goos == "darwin" {
		return nil
	}
	return errNeedsMacOS
}
