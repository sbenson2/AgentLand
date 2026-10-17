package host

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"
)

// Updates before a terminal starts an agent (docs/HOST-API.md "Agent terminal
// preparation"; owner, 2026-10-17: "Update at most once an hour when a
// terminal starts the agent. If the update fails or takes too long, start the
// version already installed and show a short notice."). While automatic
// updates are on, a new terminal of an agent updates it first unless an
// automatic attempt (one made here or by the background run, whatever its
// result) started within launchUpdateEvery, and waits for that update, or one
// already running, at most terminalUpdateWait. An update never keeps the
// terminal from starting: when it fails, or has not finished by then, the
// terminal starts with the version already installed and updateNotice says
// so. A slow update of an agent that installs each version beside the one
// that runs (updatesBesideRunning: registry installs, Claude Code's native
// "versions" folder) goes on in the background, since the terminal's version
// stays; any other (Codex's own updater, Claude Code installed elsewhere)
// rewrites the agent in place, so it is stopped first, its process group
// ended, and nothing changes the agent while the terminal starts.

// errStoppedForLaunch is why a launch stopped an update in place that had
// not finished within terminalUpdateWait.
var errStoppedForLaunch = errors.New("it took too long and was stopped so a terminal could start")

// updateOutcome is how one update attempt went, for its log line and the
// notice of a launch that waited for it.
type updateOutcome struct {
	before string // the version before, "" when unknown
	after  string // the version after, when known without reading it
	// afterOf reads the version after; it runs once the agent is released.
	afterOf func() string
	// skipped says why nothing was attempted after all.
	skipped string
	err     error
}

// prepareTerminal holds the agent's operation through PTY registration. It
// refuses only when the request ends, the host stops, the state cannot be read
// or the agent is being installed, uninstalled or rolled back
// (errAgentChangeBusy); an update that fails or is slow never refuses.
func (c *agentCatalog) prepareTerminal(parent context.Context, id string) (release func(), notice string, err error) {
	if c == nil || id == "shell" {
		return func() {}, "", nil
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	stop := context.AfterFunc(c.ctx, cancel)
	defer stop()
	shutdownDone := make(chan struct{})
	defer close(shutdownDone)
	go func() {
		select {
		case <-c.host.stopping:
			cancel()
		case <-shutdownDone:
		case <-ctx.Done():
		}
	}()
	// The launch waits this long for an update, its own or one it joins.
	wait, stopWaiting := context.WithTimeout(ctx, c.terminalUpdateWait)
	defer stopWaiting()
	planned := false
	for {
		if err := ctx.Err(); err != nil {
			return nil, "", err
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return nil, "", context.Canceled
		}
		previous := c.ops[id]
		if previous == nil && planned {
			op := &agentOp{kind: "launch", done: make(chan struct{})}
			c.ops[id] = op
			c.mu.Unlock()
			return func() { c.endOp(id, op) }, notice, nil
		}
		c.mu.Unlock()
		if previous == nil {
			planned = true
			var run func(context.Context) updateOutcome
			if run, notice, err = c.preLaunchPlan(ctx, wait, id); err != nil {
				return nil, "", err
			}
			if run != nil {
				// Another change may take the agent first: the next look joins
				// it, waits for it or refuses.
				c.startPreLaunchUpdate(id, run)
			}
			continue
		}
		switch previous.kind {
		case "launch":
			// Another terminal of the agent is starting, holding it until its
			// PTY is registered.
			select {
			case <-previous.done:
			case <-ctx.Done():
				return nil, "", ctx.Err()
			}
		case "update":
			planned = true
			select {
			case <-previous.done:
				notice = c.updateNotice(id, previous.err)
			case <-ctx.Done():
				return nil, "", ctx.Err()
			case <-wait.Done():
				if ctx.Err() != nil {
					return nil, "", ctx.Err()
				}
				if c.updatesBesideRunning(id) {
					// It goes on in the background. The terminal runs the
					// version installed now, which the update leaves in place
					// (Claude Code's versions folder; makeCurrent keeps the
					// version it replaces as the previous one).
					return func() {}, c.updateName(id) + " is still updating; started the installed version.", nil
				}
				// An update in place is stopped before the terminal starts:
				// its process group ends (runLocalUpdaterCommand), within a
				// second of the stop.
				if previous.stop != nil {
					previous.stop(errStoppedForLaunch)
				}
				select {
				case <-previous.done:
				case <-ctx.Done():
					return nil, "", ctx.Err()
				}
				notice = c.updateNotice(id, errStoppedForLaunch)
			}
		default:
			return nil, "", errAgentChangeBusy
		}
	}
}

// preLaunchPlan decides what a new terminal of id does before it starts: the
// update to run (run), or none, with the notice the terminal gets. A skip for
// a recent attempt, a deferral and a missing updater are logged; the update
// logs itself once it has let the agent go.
func (c *agentCatalog) preLaunchPlan(ctx, wait context.Context, id string) (run func(context.Context) updateOutcome, notice string, err error) {
	state, err := c.host.store.Read()
	if err != nil {
		return nil, "", err
	}
	if !state.AutomaticUpdates {
		return nil, "", nil
	}
	local := id == "claude" || id == "codex"
	var path string
	if local {
		spec, _ := localAgentSpecFor(id)
		var found bool
		if path, found = c.lookup(spec.program); !found {
			// The launcher says it is not there.
			return nil, "", nil
		}
	}
	if since, recent := c.recentAutomaticAttempt(id); recent {
		version := c.knownVersion(id, path)
		c.logUpdate(id, "pre-launch", updateOutcome{before: version, after: version,
			skipped: "an update was attempted " + agoText(since) + " ago"})
		return nil, "", nil
	}
	if c.busyForUpdate(id) {
		if c.updateDue(wait, id) {
			c.markDeferred(id)
			version := c.knownVersion(id, path)
			c.logUpdate(id, "pre-launch", updateOutcome{before: version, after: version, skipped: "deferred, the agent is busy"})
		}
		return nil, "Automatic update deferred because this agent is running.", nil
	}
	if local {
		supported, probeErr := c.localUpdaterSupportedContext(wait, id, path)
		if probeErr != nil {
			if ctx.Err() != nil {
				return nil, "", ctx.Err()
			}
			// Another check of the updater kept it waiting too long.
			return nil, c.updateNotice(id, errStoppedForLaunch), nil
		}
		if !supported {
			version := c.knownVersion(id, path)
			c.logUpdate(id, "pre-launch", updateOutcome{before: version, after: version, skipped: "no supported updater"})
			return nil, "This agent has no supported automatic updater.", nil
		}
		if !c.automaticUpdates() {
			return nil, "", nil
		}
		return func(updateCtx context.Context) updateOutcome { return c.localUpdate(updateCtx, id, path) }, "", nil
	}
	current, err := c.store.readCurrent(id)
	if err != nil {
		// A damaged record: the launcher says what it can run.
		return nil, "", nil
	}
	if current == nil {
		return nil, "This agent has no supported automatic updater.", nil
	}
	return func(updateCtx context.Context) updateOutcome { return c.registryUpdate(updateCtx, id) }, "", nil
}

// startPreLaunchUpdate claims id for run, an automatic update the next look
// of prepareTerminal joins, and runs it in the background. It reports false
// when another change took the agent first or the catalog closes.
func (c *agentCatalog) startPreLaunchUpdate(id string, run func(context.Context) updateOutcome) bool {
	op, updateCtx, err := c.beginUpdate(id)
	if err != nil {
		return false
	}
	c.noteAutomaticAttempt(id)
	if !c.background(func() {
		outcome := run(updateCtx)
		op.err = outcome.err
		c.endOp(id, op)
		c.logUpdate(id, "pre-launch", outcome)
	}) {
		op.err = context.Canceled
		c.endOp(id, op)
		return false
	}
	return true
}

// localUpdate runs the native updater of Claude Code or Codex at path, with
// the versions before and after for its log line.
func (c *agentCatalog) localUpdate(ctx context.Context, id, path string) updateOutcome {
	before := c.localVersion(path, id, true)
	err := c.updateLocal(ctx, id, path)
	if err != nil && ctx.Err() != nil {
		// Why it stopped: a launch's wait (errStoppedForLaunch) or the host.
		err = context.Cause(ctx)
	}
	return updateOutcome{before: before, err: err, afterOf: func() string {
		if err != nil {
			return before
		}
		spec, _ := localAgentSpecFor(id)
		latest, ok := c.lookup(spec.program)
		if !ok {
			return ""
		}
		return c.localVersion(latest, id, true)
	}}
}

// registryUpdate reads the registry and installs its version of id beside the
// current one when it differs, by the automatic update's rules: no download
// without a checksum for a verified agent, no OpenCode version that did not
// start before.
func (c *agentCatalog) registryUpdate(ctx context.Context, id string) updateOutcome {
	current, _ := c.store.readCurrent(id)
	if current == nil {
		return updateOutcome{skipped: "not installed by AgentLand"}
	}
	outcome := updateOutcome{before: current.Version, after: current.Version}
	// The bounded fetch keeps the registry's ETag and size checks.
	fetchCtx, fetchCancel := context.WithTimeout(ctx, c.registryWait)
	err := c.refresh(fetchCtx)
	fetchCancel()
	if err != nil {
		if ctx.Err() != nil {
			outcome.err = context.Cause(ctx)
		} else {
			outcome.err = causedError{agentFetchMessage(err), err}
		}
		return outcome
	}
	registry, ok := c.registryEntry(id)
	switch {
	case !ok:
		outcome.err = errUnknownAgent
		return outcome
	case sameAgentVersion(registry.Version, current.Version):
		return outcome
	case id == "opencode" && c.skipsOpenCode(registry.Version):
		outcome.skipped = "version " + logVersion(registry.Version) + " did not start before"
		return outcome
	}
	dist, ok := registry.choose(c.platform)
	if !ok {
		outcome.err = errUnsupportedPlatform
		return outcome
	}
	if !dist.Verified && !current.Unverified {
		outcome.err = errUnverifiedDownload
		return outcome
	}
	if !c.automaticUpdates() {
		outcome.skipped = "automatic updates were turned off"
		return outcome
	}
	if outcome.err = c.installVersion(ctx, id, registry, dist, !dist.Verified); outcome.err == nil {
		outcome.after = registry.Version
	}
	return outcome
}

// updateNotice is what a terminal that waited for an update says of it: ""
// when it went through, else that the installed version started.
func (c *agentCatalog) updateNotice(id string, err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, errStoppedForLaunch) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled):
		return "Couldn't update " + c.updateName(id) + " in time; started the installed version."
	}
	return "Couldn't update " + c.updateName(id) + "; started the installed version."
}

// updateName names an agent in update notices: Claude Code and Codex by
// their own names, the others by the catalog's.
func (c *agentCatalog) updateName(id string) string {
	if spec, ok := localAgentSpecFor(id); ok && (id == "claude" || id == "codex") {
		return spec.name
	}
	return c.agentName(id)
}

// knownVersion is id's version without running anything: a registry
// install's record, or the version cached for the command at path.
func (c *agentCatalog) knownVersion(id, path string) string {
	if path != "" {
		return c.localVersion(path, id, false)
	}
	if current, _ := c.store.readCurrent(id); current != nil {
		return current.Version
	}
	return ""
}

// noteAutomaticAttempt records that an automatic update of id (before a
// launch, or the background run's) starts now.
func (c *agentCatalog) noteAutomaticAttempt(id string) {
	now := c.now()
	c.mu.Lock()
	c.automaticAttempts[id] = now
	c.mu.Unlock()
}

// recentAutomaticAttempt reports an automatic update of id that started
// within launchUpdateEvery, and how long ago. A clock set back counts as no
// recent attempt.
func (c *agentCatalog) recentAutomaticAttempt(id string) (time.Duration, bool) {
	c.mu.Lock()
	at, ok := c.automaticAttempts[id]
	c.mu.Unlock()
	if !ok {
		return 0, false
	}
	since := c.now().Sub(at)
	return since, since >= 0 && since < c.launchUpdateEvery
}

// logUpdate writes one line to the host's log (its stderr, the Mac app's
// host.log) for an update attempt, or for a launch that made none: the agent,
// what started it, its version before and after, and the result. It never
// names the updater's output, an environment or a path.
func (c *agentCatalog) logUpdate(id, trigger string, outcome updateOutcome) {
	after := outcome.after
	if outcome.afterOf != nil {
		after = outcome.afterOf()
	}
	var result string
	switch {
	case outcome.err != nil:
		result = "failed: " + updateFailureReason(outcome.err)
	case outcome.skipped != "":
		result = "skipped: " + outcome.skipped
	case outcome.before != "" && outcome.before == after:
		result = "already current"
	default:
		result = "updated"
	}
	logf := c.logf
	if logf == nil {
		logf = defaultAgentLog
	}
	logf("agents: %s update (%s): %s → %s, %s", id, trigger, logVersion(outcome.before), logVersion(after), result)
}

// defaultAgentLog is the host's log: its stderr, which the Mac app keeps in
// host.log.
var defaultAgentLog = log.Printf

// logVersion is a version as the log shows it: "unknown" when there is none
// or it is not a plain version word.
func logVersion(version string) string {
	if version == "" || !agentVersionPattern.MatchString(version) {
		return "unknown"
	}
	return version
}

// updateFailureReason says why an update failed in words of the host's own:
// never an updater's output or a path.
func updateFailureReason(err error) string {
	var install *agentInstallError
	var updater localUpdaterError
	var caused causedError
	switch {
	case errors.Is(err, errStoppedForLaunch):
		return err.Error()
	case errors.Is(err, context.DeadlineExceeded):
		return "it took too long and was stopped"
	case errors.Is(err, context.Canceled):
		return "it was stopped"
	case errors.As(err, &install):
		if reason, ok := map[string]string{stepStorage: "its files could not be written", stepDownload: "the download or install failed",
			stepCheck: "the new version's check failed"}[install.step]; ok {
			return reason
		}
		return "the install failed"
	case errors.As(err, &updater):
		return string(updater)
	case errors.As(err, &caused):
		return strings.TrimSuffix(caused.message, ".")
	case errors.Is(err, errUnverifiedDownload), errors.Is(err, errUnsupportedPlatform), errors.Is(err, errUnknownAgent),
		errors.Is(err, errAgentChangeBusy), errors.Is(err, errNotManaged):
		return err.Error()
	}
	return "an unexpected error"
}

// agoText is a duration for a log line: whole minutes, or seconds under one.
func agoText(since time.Duration) string {
	if since < time.Minute {
		return fmt.Sprintf("%d s", int(since/time.Second))
	}
	return fmt.Sprintf("%d min", int(since/time.Minute))
}
