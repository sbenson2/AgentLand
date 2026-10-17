package host

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strconv"
	"unicode/utf8"
)

// The agent routes (docs/HOST-API.md "Agents"): the catalog, its icons, its
// changes and OpenCode's providers. Paired devices and the Mac's own session
// use them, through the tunnel too.

func (h *Host) agentsAvailable(w http.ResponseWriter) bool {
	if h.agents == nil {
		writeError(w, 501, "agents_unavailable", "This host keeps no agent catalog")
		return false
	}
	return true
}

type agentsRegistryJSON struct {
	FetchedAt string `json:"fetchedAt,omitempty"`
	Error     string `json:"error,omitempty"`
}

// listAgents is GET /v1/agents. The opencode entry carries restartWanted and
// idleForSeconds for the Mac's own session only.
func (h *Host) listAgents(w http.ResponseWriter, r *http.Request) {
	if !h.agentsAvailable(w) {
		return
	}
	catalog := h.agents
	catalog.ensureRegistry(r.Context())
	views := catalog.views(true)
	device, _ := h.authenticate(r)
	local := device.ID == "local-mac"
	agents := make([]agentJSON, 0, len(views))
	for _, view := range views {
		entry := view.agentJSON
		if local && view.ID == "opencode" {
			wanted := catalog.restartWanted(r.Context())
			idle := catalog.idleForSeconds()
			entry.RestartWanted, entry.IdleForSeconds = &wanted, &idle
		}
		agents = append(agents, entry)
	}
	catalog.mu.Lock()
	registry := agentsRegistryJSON{Error: catalog.fetchErr}
	if !catalog.fetchedAt.IsZero() {
		registry.FetchedAt = chatTimeOf(catalog.fetchedAt)
	}
	catalog.mu.Unlock()
	writeJSON(w, 200, struct {
		AutomaticUpdates bool               `json:"automaticUpdates"`
		Registry         agentsRegistryJSON `json:"registry"`
		Agents           []agentJSON        `json:"agents"`
	}{catalog.automaticUpdates(), registry, agents})
}

// agentIcon is GET /v1/agents/icon?id=: the icon the host keeps, so devices
// never contact the registry's CDN. 404 means there is none; 503 that it
// could not be read in time, so the device asks again later.
func (h *Host) agentIcon(w http.ResponseWriter, r *http.Request) {
	if !h.agentsAvailable(w) {
		return
	}
	id := r.URL.Query().Get("id")
	if _, known := h.agents.knownAgent(id); !known {
		writeError(w, 404, "not_found", "No icon for this agent")
		return
	}
	data, kind, outcome := h.agents.icon(r.Context(), id)
	switch outcome {
	case iconNone:
		writeError(w, 404, "not_found", "No icon for this agent")
		return
	case iconUnavailable:
		writeError(w, 503, "icon_unavailable", "The icon could not be fetched in time; try again later")
		return
	}
	sum := sha256.Sum256(data)
	etag := `"` + hex.EncodeToString(sum[:]) + `"`
	header := w.Header()
	header.Set("Content-Type", map[string]string{"svg": "image/svg+xml", "png": "image/png"}[kind])
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox")
	header.Set("Cache-Control", "private, max-age=86400")
	header.Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	header.Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// agentChangeFailure answers a refused install, update or uninstall.
func agentChangeFailure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errUnknownAgent):
		writeError(w, 404, "unknown_agent", "No agent has that id")
	case errors.Is(err, errAgentChangeBusy):
		writeError(w, 409, "agent_busy", "The agent is working or being changed; try again when it is idle")
	case errors.Is(err, errNotManaged):
		writeError(w, 409, "not_managed", "This agent is updated by its own updater, not by AgentLand")
	case errors.Is(err, errAgentRequired):
		writeError(w, 409, "agent_required", "AgentLand's chats need OpenCode, so it cannot be uninstalled")
	case errors.Is(err, errUnsupportedPlatform):
		writeError(w, 400, "unsupported_platform", "Nothing the registry offers for this agent runs on this Mac")
	case errors.Is(err, errUnverifiedDownload):
		writeError(w, 400, "unverified_download", "This download has no checksum in the registry; confirm to install it anyway")
	default:
		internal(w)
	}
}

func (h *Host) installAgent(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID              string `json:"id"`
		AllowUnverified bool   `json:"allowUnverified,omitempty"`
	}
	if !decode(w, r, &in) || !h.agentsAvailable(w) {
		return
	}
	// The registry is read first when the host has no copy yet.
	h.agents.ensureRegistry(r.Context())
	view, err := h.agents.requestInstall(in.ID, in.AllowUnverified)
	if err != nil {
		agentChangeFailure(w, err)
		return
	}
	writeJSON(w, 202, view.agentJSON)
}

func (h *Host) updateAgent(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID              string `json:"id"`
		AllowUnverified bool   `json:"allowUnverified,omitempty"`
	}
	if !decode(w, r, &in) || !h.agentsAvailable(w) {
		return
	}
	if in.ID != "claude" && in.ID != "codex" {
		h.agents.ensureRegistry(r.Context())
	}
	view, err := h.agents.requestUpdate(in.ID, in.AllowUnverified)
	if err != nil {
		agentChangeFailure(w, err)
		return
	}
	writeJSON(w, 202, view.agentJSON)
}

// openCodeFailed is POST /v1/agents/opencode/failed, for the Mac's own
// session only: the managed OpenCode at version did not start on this Mac,
// for reason (at most 600 bytes, shown to the owner in lastError). For the
// current version the host goes back to the previous one when it is kept
// and intact, and automatic updates skip the version until the registry
// offers another (openCodeDidNotStart).
func (h *Host) openCodeFailed(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Version string `json:"version"`
		Reason  string `json:"reason"`
	}
	if !decode(w, r, &in) || !h.agentsAvailable(w) {
		return
	}
	if !validAgentVersion(in.Version) {
		writeError(w, 400, "invalid_request", "version must be the version of the OpenCode that did not start")
		return
	}
	if len(in.Reason) > openCodeReasonLimit || !utf8.ValidString(in.Reason) {
		writeError(w, 400, "invalid_request", "reason must be text of at most 600 bytes")
		return
	}
	result, err := h.agents.openCodeDidNotStart(in.Version, in.Reason)
	switch {
	case errors.Is(err, errAgentChangeBusy):
		writeError(w, 409, "agent_busy", "OpenCode is being changed now; report it again when that ends")
	case err != nil:
		writeError(w, 500, "storage_error", "The host could not record the failure")
	default:
		writeJSON(w, 200, result)
	}
}

func (h *Host) uninstallAgent(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID string `json:"id"`
	}
	if !decode(w, r, &in) || !h.agentsAvailable(w) {
		return
	}
	view, err := h.agents.requestUninstall(in.ID)
	if err != nil {
		agentChangeFailure(w, err)
		return
	}
	writeJSON(w, 202, view.agentJSON)
}

func (c *agentCatalog) automaticUpdates() bool {
	if c == nil || c.host == nil {
		return false
	}
	state, err := c.host.store.Read()
	return err == nil && state.AutomaticUpdates
}
func (h *Host) agentSettings(w http.ResponseWriter, r *http.Request) {
	var in struct {
		AutomaticUpdates *bool `json:"automaticUpdates"`
	}
	if !decode(w, r, &in) || !h.agentsAvailable(w) {
		return
	}
	if in.AutomaticUpdates == nil {
		writeError(w, 400, "invalid_request", "automaticUpdates must be a Boolean")
		return
	}
	if err := h.store.update(func(state *State) error { state.AutomaticUpdates = *in.AutomaticUpdates; return nil }); err != nil {
		internal(w)
		return
	}
	writeJSON(w, 200, map[string]bool{"automaticUpdates": *in.AutomaticUpdates})
}
