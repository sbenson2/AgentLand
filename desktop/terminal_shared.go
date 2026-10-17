package host

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Terminals from other devices. Every paired device reaches every terminal on
// this host: it reads, types into, resizes, names and ends it, whichever
// device or Terminal.app window opened it (terminalEntry), and learns how it
// ended. A device's own list (GET /v1/terminals) stays its own;
// GET /v1/terminals/others lists the running terminals of the other devices
// and of this Mac, with what each is doing (terminal_activity.go). Removing a
// device still ends only its terminals (macTerminalsEndDevice), never the
// Mac's.

// terminalOthersKeeperWait bounds the keeper's list that the others list
// reads input times from.
const terminalOthersKeeperWait = 500 * time.Millisecond

// sharedTerminal is a terminal as GET /v1/terminals/others lists it.
type sharedTerminal struct {
	ID         string `json:"id"`
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"` // "" for this Mac's, which the apps call by the host's name
	// OnMac says this Mac opened it: a routed agent typed in Terminal.app,
	// or a terminal of the Mac's own web app.
	OnMac        bool   `json:"onMac"`
	Program      string `json:"program"`
	Title        string `json:"title"`
	ProgramTitle string `json:"programTitle"`
	ContextTitle string `json:"contextTitle"`
	// ContextTitleSource is TerminalInfo's: "program" or "device".
	ContextTitleSource string `json:"contextTitleSource,omitempty"`
	Folder             string `json:"folder"`
	DisplayFolder      string `json:"displayFolder"` // Folder with this user's home as ~
	// ProjectID and Workspace are its workspace's ID and name, null for a
	// terminal outside any.
	ProjectID *string `json:"projectId"`
	Workspace *string `json:"workspace"`
	Routed    bool    `json:"routed"`
	Status    string  `json:"status"`
	// Activity is "working", "waiting" (for you) or "quiet"
	// (terminalActivity.status).
	Activity     string `json:"activity"`
	LastOutputAt string `json:"lastOutputAt,omitempty"`
	// LastActiveAt is the latest of its last output, its last input and its
	// start; the list is newest first by it.
	LastActiveAt string `json:"lastActiveAt"`
}

// otherTerminals serves GET /v1/terminals/others: the running terminals the
// asking device did not open, most recently active first, then by ID.
func (h *Host) otherTerminals(w http.ResponseWriter, r *http.Request) {
	device, ok := h.terminalDevice(w, r)
	if !ok {
		return
	}
	manager := h.terminals
	var entries []*terminalEntry
	manager.mu.Lock()
	for _, entry := range manager.entries {
		if entry.owner != device.ID {
			entries = append(entries, entry)
		}
	}
	manager.mu.Unlock()
	// Input typed in a terminal's Terminal.app window reaches its program
	// through the keeper, which alone knows when; a keeper that does not
	// answer in time only leaves that out.
	keeperInput := map[string]time.Time{}
	if len(entries) > 0 {
		ctx, cancel := context.WithTimeout(r.Context(), terminalOthersKeeperWait)
		infos, err := manager.backend.List(ctx)
		cancel()
		if err == nil {
			for _, info := range infos {
				keeperInput[info.ID] = info.LastInput
			}
		}
	}
	names := map[string]string{}
	if devices, err := h.store.ListDevices(); err == nil {
		for _, paired := range devices {
			names[paired.ID] = paired.Name
		}
	}
	home, _ := os.UserHomeDir()
	now := h.now()
	type listed struct {
		sharedTerminal
		active time.Time
	}
	all := make([]listed, 0, len(entries))
	for _, entry := range entries {
		if terminal, active, running := entry.shared(now, keeperInput[entry.info.ID], names, home); running {
			all = append(all, listed{terminal, active})
		}
	}
	sort.Slice(all, func(i, j int) bool {
		if !all[i].active.Equal(all[j].active) {
			return all[i].active.After(all[j].active)
		}
		return all[i].ID < all[j].ID
	})
	terminals := make([]sharedTerminal, len(all))
	for index, item := range all {
		terminals[index] = item.sharedTerminal
	}
	writeJSON(w, 200, map[string]any{"terminals": terminals})
}

// shared is the terminal as the others list shows it, with the time it was
// last active; false once it is no longer running.
func (entry *terminalEntry) shared(now, keeperInput time.Time, names map[string]string, home string) (sharedTerminal, time.Time, bool) {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	info, activity := entry.info, entry.activity
	if info.Status != "running" {
		return sharedTerminal{}, time.Time{}, false
	}
	active := entry.meta.Created
	if active.IsZero() {
		active = entry.started
	}
	for _, at := range []time.Time{activity.lastOutput, activity.lastInput, keeperInput} {
		if at.After(active) {
			active = at
		}
	}
	terminal := sharedTerminal{ID: info.ID, DeviceID: entry.owner, DeviceName: names[entry.owner], OnMac: entry.owner == localMacDeviceID,
		Program: entry.program, Title: info.Title, ProgramTitle: info.ProgramTitle, ContextTitle: info.ContextTitle,
		ContextTitleSource: info.ContextTitleSource, Folder: info.Directory, DisplayFolder: displayFolder(info.Directory, home),
		Routed: entry.meta.Routed, Status: info.Status,
		Activity: activity.status(now, keeperInput), LastActiveAt: active.UTC().Format(archiveTimeLayout)}
	if terminal.OnMac {
		terminal.DeviceName = ""
	}
	if entry.project.ID != "" {
		id, name := entry.project.ID, entry.project.Name
		terminal.ProjectID, terminal.Workspace = &id, &name
	}
	if !activity.lastOutput.IsZero() {
		terminal.LastOutputAt = activity.lastOutput.UTC().Format(archiveTimeLayout)
	}
	return terminal, active, true
}

// displayFolder is folder with the home folder at its start written as ~.
func displayFolder(folder, home string) string {
	home = filepath.Clean(home)
	if home == "." || home == string(filepath.Separator) {
		return folder
	}
	if folder == home {
		return "~"
	}
	if rest, inside := strings.CutPrefix(folder, home+string(filepath.Separator)); inside {
		return "~" + string(filepath.Separator) + rest
	}
	return folder
}
