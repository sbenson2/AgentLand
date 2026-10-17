package keeper

import (
	"errors"
	"path/filepath"
)

// SocketPath is where the keeper for the host state at statePath listens:
// terminals.sock in the state's folder.
func SocketPath(statePath string) string {
	return filepath.Join(filepath.Dir(statePath), "terminals.sock")
}

// LockPath is the file the keeper for statePath holds locked for its whole
// life, so that only one runs per state.
func LockPath(statePath string) string {
	return statePath + ".terminals.lock"
}

// ErrKeeperRunning means another keeper holds the lock for this state.
var ErrKeeperRunning = errors.New("a terminal keeper is already running for this state")
