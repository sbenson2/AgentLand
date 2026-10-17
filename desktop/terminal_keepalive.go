package host

import (
	"context"
	"log"
	"slices"
	"time"

	"agentland/host/internal/shellhook"
	"agentland/host/keeper"
)

// The routing switch ("Open coding agents from Terminal in AgentLand",
// internal/shellhook): while terminal access is on and the switch reads
// "on", the host keeps a keeper running, so a coding agent typed in
// Terminal.app never waits for one to start inside `terminals run`'s 1 s
// setup. The connection the host keeps to it holds off the keeper's idle
// exit. With the switch off, or terminal access off, nothing here starts a
// keeper.
//
// Keepers outlive app updates, so the one running may be from an AgentLand
// before adopt (keeper.FeatureAdopt), which can't take routed agents, and
// which the connection kept here would keep alive for good. While it holds
// nothing it is stopped and one of this build's started (Ruling 51); while
// it holds terminals it is left as it is, never ending one, and
// /v1/terminals/all says it doesn't adopt.

// keeperKeepAliveEvery is how often the host reads the switch and looks for
// a keeper, and the least time between two keeper starts it attempts.
var keeperKeepAliveEvery = 5 * time.Second

// keeperKeepAliveWait bounds one look, a keeper's start included.
const keeperKeepAliveWait = 10 * time.Second

// oldKeeperStopWait bounds stopping an idle keeper from before adopt, which
// holds manager.mu throughout.
const oldKeeperStopWait = 3 * time.Second

// oldKeeperBackend is what the keep-alive asks of a keeper that may be from
// before adopt (keeperBackend).
type oldKeeperBackend interface {
	// runningFeatures is the running keeper's hello features; it never
	// starts a keeper (errNoKeeper when none runs).
	runningFeatures(ctx context.Context) ([]string, error)
	// stopIdleKeeper stops the running keeper when it lists no terminal,
	// so that StopAll ends nothing, and waits for it to go; stopped says
	// it was stopped.
	stopIdleKeeper(ctx context.Context) (stopped bool, err error)
}

// startKeeperKeepAlive starts the keep-alive for a host with terminals. It
// stops at BeginShutdown or Close.
func (h *Host) startKeeperKeepAlive() {
	manager := h.terminals
	if manager == nil {
		return
	}
	manager.keepAliveDone = make(chan struct{})
	go manager.keepKeeper(h.store.Path, keeperKeepAliveEvery)
}

// keepKeeper looks at once, then every interval, and when a keeper stopped
// (keeperStopped) unless it attempted a start within the interval.
func (manager *terminalManager) keepKeeper(statePath string, every time.Duration) {
	defer close(manager.keepAliveDone)
	timer := time.NewTimer(0)
	defer timer.Stop()
	var started time.Time
	var failed string // the last start error logged, so a lasting one is logged once
	for {
		select {
		case <-manager.closing:
			return
		case <-manager.stopping:
			return
		case <-manager.keeperGone:
			if !started.IsZero() && time.Since(started) < every {
				continue
			}
		case <-timer.C:
		}
		attempted, err := manager.keepKeeperOnce(statePath)
		if attempted {
			started = time.Now()
			switch {
			case err == nil:
				failed = ""
			case err.Error() != failed:
				failed = err.Error()
				log.Printf("terminals: could not start the terminal keeper for coding agents typed in Terminal: %v", err)
			}
		}
		timer.Reset(every)
	}
}

// keepKeeperOnce starts a keeper when the switch is on and none runs, or
// when it stopped an idle one from before adopt. A keeper this build cannot
// use, or one from before adopt that holds terminals, is left as it is.
func (manager *terminalManager) keepKeeperOnce(statePath string) (attempted bool, err error) {
	if !shellhook.SwitchOn(statePath) {
		return false, nil
	}
	ctx, cancel := manager.requestContext(keeperKeepAliveWait)
	defer cancel()
	switch manager.backend.Status(ctx) {
	case KeeperNone:
	case KeeperRunning:
		stopped, err := manager.stopIdleOldKeeper(ctx)
		if !stopped {
			return err != nil, err
		}
	default:
		return false, nil
	}
	if manager.isClosed() {
		return false, nil
	}
	if _, err := manager.backend.Features(ctx); err != nil && !manager.isClosed() {
		return true, err
	}
	return true, nil
}

// stopIdleOldKeeper stops the running keeper when it is from before adopt,
// lists no terminal, and the host has none listed or starting; stopped says
// it did. The host's check and the stop both hold manager.mu, so no
// terminal starts in that keeper meanwhile (a spawn counts in starting
// first). err is the stop's own failure.
func (manager *terminalManager) stopIdleOldKeeper(ctx context.Context) (stopped bool, err error) {
	old, ok := manager.backend.(oldKeeperBackend)
	if !ok {
		return false, nil
	}
	if features, err := old.runningFeatures(ctx); err != nil || slices.Contains(features, keeper.FeatureAdopt) {
		return false, nil
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.closed || len(manager.entries) > 0 || manager.starting > 0 {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, oldKeeperStopWait)
	defer cancel()
	if stopped, err = old.stopIdleKeeper(ctx); stopped {
		log.Printf("terminals: stopped an idle terminal keeper from an older AgentLand, which can't take coding agents typed in Terminal; starting this one's")
	}
	return stopped, err
}

// keeperAdopts says whether the running keeper takes routed agents' PTYs
// (keeper.FeatureAdopt), for /v1/terminals/all; known is false when that
// can't be read without starting a keeper.
func (manager *terminalManager) keeperAdopts(ctx context.Context) (adopts, known bool) {
	old, ok := manager.backend.(oldKeeperBackend)
	if !ok {
		return false, false
	}
	features, err := old.runningFeatures(ctx)
	if err != nil {
		return false, false
	}
	return slices.Contains(features, keeper.FeatureAdopt), true
}

// keeperWentAway tells the keep-alive that the keeper stopped.
func (manager *terminalManager) keeperWentAway() {
	select {
	case manager.keeperGone <- struct{}{}:
	default:
	}
}
