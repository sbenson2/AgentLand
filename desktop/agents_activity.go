package host

import (
	"slices"
	"time"
)

// What runs on the host, for the agent catalog (docs/HOST-API.md "Agents"):
// whether one agent is busy (its updates wait, its uninstall is refused) and
// whether anything runs at all (idleForSeconds).

// agentBusy reports one of the agent's terminals running or one of its chat
// turns running or waiting for an answer; for OpenCode also any OpenCode
// chat turn.
func (h *Host) agentBusy(id string) bool {
	if len(h.runningTerminalVersions(id)) > 0 {
		return true
	}
	return h.agentBusyBesidesTerminals(id)
}

// agentBusyForUpdate is agentBusy for an update: an agent that installs each
// version beside the old one (updatesBesideRunning) does not wait for its
// terminals.
func (h *Host) agentBusyForUpdate(id string) bool {
	// With the keeper unreadable the host cannot see which terminals run, so
	// every agent that has a terminal waits.
	if h.terminalsUnreadable() && h.terminalCapable(id) {
		return true
	}
	if h.agents != nil && h.agents.updatesBesideRunning(id) {
		return h.agentBusyBesidesTerminals(id)
	}
	return h.agentBusy(id)
}

// terminalsUnreadable reports a keeper the host cannot read: its terminals
// run, but the host does not know which.
func (h *Host) terminalsUnreadable() bool {
	return h != nil && h.terminals != nil && h.terminals.isUnusable()
}

// terminalCapable reports that a terminal of program id can exist.
func (h *Host) terminalCapable(id string) bool {
	if h.terminals == nil || h.terminals.launcher == nil {
		return false
	}
	return slices.Contains(h.terminals.launcher.programs(), id)
}

// pruneHold is what pruning must leave alone for agent id: the versions its
// running terminals use, or all of them (all) when some running terminal's
// version is unknown or the keeper cannot be read.
func (h *Host) pruneHold(id string) (versions []string, all bool) {
	if h == nil {
		return nil, false
	}
	if h.terminalsUnreadable() {
		return nil, true
	}
	for _, version := range h.runningTerminalVersions(id) {
		if version == "" {
			return nil, true
		}
		versions = append(versions, version)
	}
	return versions, false
}

// runningTerminalVersions has one item (the terminal's meta.Version, possibly
// empty) for each running terminal of program id.
func (h *Host) runningTerminalVersions(id string) []string {
	if h.terminals == nil {
		return nil
	}
	h.terminals.mu.Lock()
	entries := make([]*terminalEntry, 0, len(h.terminals.entries))
	for _, entry := range h.terminals.entries {
		entries = append(entries, entry)
	}
	h.terminals.mu.Unlock()
	var versions []string
	for _, entry := range entries {
		entry.mu.Lock()
		if entry.program == id && entry.info.Status == "running" {
			versions = append(versions, entry.meta.Version)
		}
		entry.mu.Unlock()
	}
	return versions
}

// agentBusyBesidesTerminals is agentBusy without the terminal check.
func (h *Host) agentBusyBesidesTerminals(id string) bool {
	if h.cliChats != nil && h.cliChats.acp.agentBusy(id) {
		return true
	}
	if h.cliChats != nil && (id == "claude" || id == "codex") && h.cliChats.nativeAgentBusy(id) {
		return true
	}
	if id == "opencode" {
		return h.openCodeBusy()
	}
	return false
}

// openCodeBusy reports an OpenCode chat turn running in any workspace or the
// Chats space.
func (h *Host) openCodeBusy() bool {
	state, err := h.store.Read()
	if err != nil {
		return false
	}
	return h.openCodeMayWork(append(state.Config.Projects, h.plainChatProjects()...))
}

// openCodeMayWork reports an OpenCode session busy or retrying in projects,
// or a workspace OpenCode did not answer for: a status query that failed or
// took longer than workspaceActivityWait may hide a turn in progress (a stuck
// OpenCode mid-turn), so it counts as busy. The Chats space counts only when
// OpenCode reports a turn there: one OpenCode cannot serve (its folder or
// configuration broken) runs nothing.
func (h *Host) openCodeMayWork(projects []Project) bool {
	counts, answered := h.openCodeActivity(projects)
	for index, project := range projects {
		if counts[index] > 0 || (!answered[index] && !h.isPlainChat(project)) {
			return true
		}
	}
	return false
}

// anythingRuns reports a running OpenCode terminal, a chat turn running or waiting
// (OpenCode, Claude Code, Codex, ACP), or a device viewing a chat. An
// OpenCode status query that fails or is late counts as a turn running.
func (h *Host) anythingRuns() bool {
	if h.terminals != nil {
		h.terminals.mu.Lock()
		entries := make([]*terminalEntry, 0, len(h.terminals.entries))
		for _, entry := range h.terminals.entries {
			entries = append(entries, entry)
		}
		h.terminals.mu.Unlock()
		for _, entry := range entries {
			entry.mu.Lock()
			// Only OpenCode's own terminals share its process and storage; a
			// shell or another agent's terminal never delays its restart.
			running := entry.info.Status == "running" && entry.program == "opencode"
			entry.mu.Unlock()
			if running {
				return true
			}
		}
	}
	if h.views.any(h.now(), presenceTTL) {
		return true
	}
	state, err := h.store.Read()
	if err != nil {
		return false
	}
	// Plain chats' turns count as running too.
	if h.openCodeMayWork(append(state.Config.Projects, h.plainChatProjects()...)) {
		return true
	}
	if h.cliChats != nil {
		for _, project := range state.Config.Projects {
			if h.cliChats.busyIn(project) > 0 {
				return true
			}
		}
	}
	return false
}

// any reports a view reported within window.
func (v *presenceViews) any(now time.Time, window time.Duration) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	for _, view := range v.views {
		if now.Sub(view.at) < window {
			return true
		}
	}
	return false
}
