package host

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"
)

// Automatic updates (docs/HOST-API.md "Installs, updates and uninstalls"):
// 2 minutes after the host starts, then every 24 hours and a random 0–60
// minutes, the registry is read and every registry install whose version
// differs is updated once it is idle: installed beside the current version,
// checked, and made current. A failure keeps the current version. While no
// managed OpenCode is valid (its install at start failed), a run installs
// the registry's at once (agents_opencode.go). Each update it attempts is
// logged and counts for the hourly rule of updates before a launch
// (agents_terminal.go); an agent it defers is logged once a run.

func (c *agentCatalog) runUpdater() {
	defer c.work.Done()
	timer := time.NewTimer(c.firstRun)
	defer timer.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-timer.C:
		}
		c.updateRun()
		timer.Reset(c.every + c.jitter())
	}
}

// outdated lists the registry installs whose version differs from the
// registry's, but for an OpenCode version the Mac app said did not start
// (skipsOpenCode).
func (c *agentCatalog) outdated() []string {
	var ids []string
	for _, id := range c.store.agentIDs() {
		if id == "claude" || id == "codex" {
			continue
		}
		current, _ := c.store.readCurrent(id)
		if current == nil {
			continue
		}
		registry, ok := c.registryEntry(id)
		if !ok || sameAgentVersion(registry.Version, current.Version) || (id == "opencode" && c.skipsOpenCode(registry.Version)) {
			continue
		}
		ids = append(ids, id)
	}
	return ids
}

// updateRun is one run: read the registry, install OpenCode when no managed
// one is valid (at once: nothing of OpenCode's can run), then update each
// outdated agent as soon as it is idle, looking every idlePoll until the
// next run is due.
func (c *agentCatalog) updateRun() {
	readErr := c.refresh(c.ctx)
	if _, err := c.store.managedOpenCode(); err != nil {
		_, _ = c.installOpenCode(c.ctx, readErr)
	}
	if !c.automaticUpdates() {
		return
	}
	local := map[string]bool{}
	for _, id := range []string{"claude", "codex"} {
		spec, _ := localAgentSpecFor(id)
		if path, ok := c.lookup(spec.program); ok && c.localUpdaterSupported(id, path) {
			local[id] = true
		}
	}
	pending := append([]string{}, c.outdated()...)
	for id := range local {
		pending = append(pending, id)
	}
	deadline := c.now().Add(c.every)
	logged := map[string]bool{}
	for len(pending) > 0 {
		var waiting []string
		for _, id := range pending {
			if c.ctx.Err() != nil || !c.automaticUpdates() {
				return
			}
			if c.automaticBusy(id) {
				waiting = append(waiting, id)
				if !logged[id] {
					logged[id] = true
					c.logDeferred(id)
				}
				continue
			}
			if local[id] {
				c.updateLocalOne(id)
			} else {
				c.updateOne(id)
			}
		}
		pending = waiting
		if len(pending) == 0 || !c.now().Before(deadline) {
			return
		}
		timer := time.NewTimer(c.idlePoll)
		select {
		case <-c.ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (c *agentCatalog) updateLocalOne(id string) {
	spec, ok := localAgentSpecFor(id)
	if !ok {
		return
	}
	path, ok := c.lookup(spec.program)
	if !ok || !c.localUpdaterSupported(id, path) {
		return
	}
	op, updateCtx, err := c.beginUpdate(id)
	if err != nil {
		return
	}
	if c.automaticBusy(id) {
		c.endOp(id, op)
		return
	}
	c.noteAutomaticAttempt(id)
	outcome := c.localUpdate(updateCtx, id, path)
	op.err = outcome.err
	c.endOp(id, op)
	c.logUpdate(id, "background", outcome)
}

// logDeferred logs that the background run found id busy.
func (c *agentCatalog) logDeferred(id string) {
	path := ""
	if spec, ok := localAgentSpecFor(id); ok && (id == "claude" || id == "codex") {
		path, _ = c.lookup(spec.program)
	}
	version := c.knownVersion(id, path)
	c.logUpdate(id, "background", updateOutcome{before: version, after: version, skipped: "deferred, the agent is busy"})
}

func (c *agentCatalog) updateLocal(ctx context.Context, id, path string) error {
	err := c.runLocalUpdater(ctx, id, path)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		message := map[string]string{"codex": "Codex", "claude": "Claude Code"}[id] + ": " + err.Error() + "."
		message, _ = clipText(message, 300)
		_ = c.store.setLocalUpdateStatus(id, errors.New(message), c.now())
		return err
	}
	// Force the next catalog read to observe the replaced command and recheck
	// that the new executable still offers its native updater.
	c.mu.Lock()
	delete(c.versions, path)
	c.mu.Unlock()
	c.updaterMu.Lock()
	delete(c.updaters, path)
	c.updaterMu.Unlock()
	_ = c.store.setLocalUpdateStatus(id, nil, c.now())
	c.undefer(id)
	if c.host != nil && c.host.cliChats != nil {
		c.host.cliChats.adoptUpdatedAgent(id)
	}
	return nil
}

// updateOne updates one idle agent now. An update that would switch a
// verified agent to a download without a checksum waits for the owner.
func (c *agentCatalog) updateOne(id string) {
	current, _ := c.store.readCurrent(id)
	registry, ok := c.registryEntry(id)
	if current == nil || !ok || sameAgentVersion(registry.Version, current.Version) || (id == "opencode" && c.skipsOpenCode(registry.Version)) {
		return
	}
	outcome := updateOutcome{before: current.Version, after: current.Version}
	dist, ok := registry.choose(c.platform)
	if !ok {
		_ = c.store.setStatus(id, "Version "+registry.Version+" offers nothing that runs on this Mac.", c.now())
		outcome.err = errUnsupportedPlatform
		c.logUpdate(id, "background", outcome)
		return
	}
	if !dist.Verified && !current.Unverified {
		_ = c.store.setStatus(id, "Version "+registry.Version+" is a download without a checksum; update it by hand to accept it.", c.now())
		outcome.err = errUnverifiedDownload
		c.logUpdate(id, "background", outcome)
		return
	}
	op, err := c.beginOp(id, "update")
	if err != nil {
		return
	}
	if c.automaticBusy(id) {
		c.endOp(id, op)
		return
	}
	c.noteAutomaticAttempt(id)
	op.err = c.installVersion(c.ctx, id, registry, dist, !dist.Verified)
	c.endOp(id, op)
	if outcome.err = op.err; op.err == nil {
		outcome.after = registry.Version
	}
	c.logUpdate(id, "background", outcome)
}

// The activity behind idleForSeconds: sampled every 15 s while the Mac's
// own session is there, and at each request.

func (c *agentCatalog) runSampler() {
	defer c.work.Done()
	ticker := time.NewTicker(c.sampleEvery)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			c.idleForSeconds()
		}
	}
}

// idleForSeconds is how long nothing has run: no running terminal, no chat
// turn running or waiting, no device viewing a chat.
func (c *agentCatalog) idleForSeconds() int64 {
	runs := false
	if c.anythingRunsFor != nil {
		runs = c.anythingRunsFor()
	} else if c.host != nil {
		runs = c.host.anythingRuns()
	}
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	if runs || now.Before(c.lastBusy) {
		c.lastBusy = now
		return 0
	}
	return int64(now.Sub(c.lastBusy) / time.Second)
}

// restartWanted: a managed OpenCode is current and newer than the one the
// host talks to.
func (c *agentCatalog) restartWanted(ctx context.Context) bool {
	current, _ := c.store.readCurrent("opencode")
	if current == nil {
		return false
	}
	running := c.runningOpenCodeVersion(ctx)
	return running != "" && agentVersionNewer(current.Version, running)
}

// runningOpenCodeVersion is the version of the OpenCode the host talks to,
// "" when it is not known.
func (c *agentCatalog) runningOpenCodeVersion(ctx context.Context) string {
	if c.runningOpenCode != nil {
		return c.runningOpenCode()
	}
	if c.host != nil {
		return c.host.runningOpenCodeVersion(ctx)
	}
	return ""
}

// agentVersionNewer compares dotted versions number by number; versions it
// cannot compare count as newer when they differ.
func agentVersionNewer(candidate, running string) bool {
	if candidate == running {
		return false
	}
	left, right := strings.Split(strings.TrimPrefix(candidate, "v"), "."), strings.Split(strings.TrimPrefix(running, "v"), ".")
	for index := 0; index < max(len(left), len(right)); index++ {
		a, b := 0, 0
		var errA, errB error
		if index < len(left) {
			a, errA = strconv.Atoi(strings.SplitN(left[index], "-", 2)[0])
		}
		if index < len(right) {
			b, errB = strconv.Atoi(strings.SplitN(right[index], "-", 2)[0])
		}
		if errA != nil || errB != nil {
			return true
		}
		if a != b {
			return a > b
		}
	}
	return false
}

// runningOpenCodeVersion is the version the host's OpenCode reported last,
// asking its /global/health (2 s) when its event stream has not said.
func (h *Host) runningOpenCodeVersion(ctx context.Context) string {
	if version := h.chat.openCodeVersion(); version != "" {
		return version
	}
	adapter, ok := h.agent.(*OpenCodeAdapter)
	if !ok {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	type result struct{ version string }
	done := make(chan result, 1)
	go func() {
		var health struct {
			Healthy bool   `json:"healthy"`
			Version string `json:"version"`
		}
		if err := adapter.do("GET", "/global/health", Project{}, nil, &health); err != nil || !health.Healthy {
			done <- result{}
			return
		}
		done <- result{health.Version}
	}()
	select {
	case got := <-done:
		version, _ := clipText(got.version, 64)
		return version
	case <-ctx.Done():
		return ""
	}
}
