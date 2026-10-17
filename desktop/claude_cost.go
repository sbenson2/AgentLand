package host

import "math"

// A turn's cost from Claude Code's total_cost_usd, which each result reports
// for the whole session, not for the turn. As observed with Claude Code
// 2.1.280 (zero-credit probes):
//
//   - A process writes its total into the session's transcript (a
//     "cost-state" entry) when it exits: on end of input, or a signal it
//     handles. A process killed by SIGKILL writes nothing.
//   - --resume S restores the total S last wrote, with or without
//     --resume-session-at and --resume-drops-turn; the first result reports
//     it plus the turn. Another session in the same folder changes nothing.
//   - --resume S --fork-session restores S's saved total into the new
//     session (not the running total of a process of S that has not exited),
//     and the new session has saved nothing until its own process exits.
//   - --session-id starts at 0.
//
// So the chat carries, per Claude session, the total Claude Code saved
// (claudeRecord.CostSaved) and the newest one reported (CostTotal), and a
// turn costs the rise over the total its process started from. When the
// first total of a process is below what it should have restored, or that
// is unknown (a chat from before the host carried totals), the turn counts
// nothing: a restart never counts earlier spending twice, at the price of
// leaving out that one turn's cost.

// claudeForkCost is what a fork's first process restores: its source
// session's saved total, when the source chat knows it.
type claudeForkCost struct {
	source *claudeChat
	saved  float64
	known  bool
}

// forkCost looks up the source chat of a fork whose first process has not
// delivered a prompt yet. It takes the source's lock, never this chat's.
func (c *claudeChat) forkCost() claudeForkCost {
	c.mu.Lock()
	parent, from := c.rec.Parent, c.rec.ForkFrom
	c.mu.Unlock()
	if parent == "" || from == "" {
		return claudeForkCost{}
	}
	source, err := c.engine.chat(c.project, parent)
	if err != nil || source == c {
		return claudeForkCost{}
	}
	saved, known := source.savedCost(from)
	return claudeForkCost{source: source, saved: saved, known: known}
}

// savedCost is the total Claude Code saved for session, which a process that
// resumes or forks it starts from.
func (c *claudeChat) savedCost(session string) (float64, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if session == "" || c.rec.CostSession != session {
		return 0, false
	}
	return c.rec.CostSaved, true
}

// costStartLocked sets what a new process's total_cost_usd starts from.
func (c *claudeChat) costStartLocked(launch claudeLaunch, fork claudeForkCost) {
	c.costFirst, c.costSource, c.costFrom = true, nil, ""
	switch {
	case launch.session != "":
		c.costKnown, c.costBase = true, 0
		c.rec.CostSession, c.rec.CostSaved = launch.session, 0
	case launch.fork:
		// The new session's ID comes with system/init; it has saved nothing.
		c.costKnown, c.costBase = fork.known, fork.saved
		c.costSource, c.costFrom = fork.source, launch.resume
		c.rec.CostSession, c.rec.CostSaved = "", 0
	case c.rec.CostSession != "" && c.rec.CostSession == launch.resume:
		c.costKnown, c.costBase = true, c.rec.CostSaved
	default:
		// A chat from before the host carried totals: unknown until a
		// process of it exits.
		c.costKnown, c.costBase = false, 0
		c.rec.CostSession, c.rec.CostSaved = "", 0
	}
	c.costSeen = c.costBase
	c.rec.CostTotal = c.costBase
}

// costRiseLocked turns a result's total_cost_usd into what the turn added, in
// millionths of a dollar.
func (c *claudeChat) costRiseLocked(total float64) int64 {
	if math.IsNaN(total) || math.IsInf(total, 0) || total < 0 {
		return 0
	}
	var rise float64
	switch {
	case c.costFirst && c.costKnown:
		base := c.costBase
		if c.costSource != nil {
			// The source may have saved a larger total after this process
			// started; when it fits under this total, it is what was restored.
			if saved, ok := c.costSource.savedCost(c.costFrom); ok && saved > base && saved <= total {
				base = saved
			}
		}
		if total >= base {
			rise = total - base
		}
	case c.costFirst:
		// What Claude Code restored is unknown: count nothing.
	case total >= c.costSeen:
		rise = total - c.costSeen
	default:
		// The total started over within the process (a cleared conversation).
		rise = total
	}
	c.costFirst = false
	c.costSeen = total
	c.rec.CostTotal = total
	if c.costKnown && c.native != "" {
		c.rec.CostSession = c.native
	}
	return int64(rise*1e6 + 0.5)
}

// costEndedLocked records what Claude Code saved when the process ended: its
// total when it exited (it writes the total then), nothing when a signal
// killed it. It reports whether the record changed.
func (c *claudeChat) costEndedLocked(exited bool) bool {
	switch {
	case exited && (c.costKnown || !c.costFirst) && c.native != "":
		changed := c.rec.CostSession != c.native || c.rec.CostSaved != c.costSeen || c.rec.CostTotal != c.costSeen
		c.rec.CostSession, c.rec.CostSaved, c.rec.CostTotal = c.native, c.costSeen, c.costSeen
		return changed
	case !exited && c.costKnown:
		changed := c.rec.CostTotal != c.rec.CostSaved
		c.rec.CostTotal = c.rec.CostSaved
		return changed
	}
	return false
}

// costLoadedLocked settles a record read from the registry: a process whose
// end the host did not see (it stopped or crashed with it) most likely saved
// its total, since Claude Code does when its input closes. Assuming so can
// only leave a turn's cost out, never count one twice.
func (c *claudeChat) costLoadedLocked() {
	if c.rec.CostSession != "" {
		c.rec.CostSaved = c.rec.CostTotal
	}
}
