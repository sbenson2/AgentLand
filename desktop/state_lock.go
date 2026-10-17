package host

import "errors"

// ErrStateBusy is LockState's answer when another process holds the lock.
var ErrStateBusy = errors.New("another AgentLand host or install-opencode is using this state")

// LockState takes the state's lock, <state>.serve.lock (a private 0600
// file), for as long as a process runs on the state: `serve` holds it while
// it runs and `install-opencode` while it installs, so the two never change
// <state>.agents at once. It fails at once with ErrStateBusy when another
// process holds it; the system lets go of it when the process ends. The
// short lock of each state change (<state>.lock) is another.
func LockState(statePath string) (release func(), err error) {
	return lockStateFile(statePath + ".serve.lock")
}
