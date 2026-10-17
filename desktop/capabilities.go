package host

import (
	"bytes"
	"encoding/json"
	"net/http"
	"slices"
	"sort"
)

// hostCapabilities is the body of GET /v1/capabilities. Clients enable
// features from it, so it lists only what this host was configured with.
// These keys are always present. Give a key added later omitempty, so a host
// without that feature leaves it out and clients treat the feature as absent.
// The fields follow the key order of the map this struct replaced, which keeps
// the encoded bytes unchanged; clients do not depend on key order.
type hostCapabilities struct {
	ChatFeatures     []string `json:"chatFeatures"`
	ChatProviders    []string `json:"chatProviders"`
	Interactions     bool     `json:"interactions"`
	Terminal         bool     `json:"terminal"`
	TerminalPrograms []string `json:"terminalPrograms"`
	TerminalFeatures []string `json:"terminalFeatures,omitempty"`

	// Archive (M1 chunk B1) is present only when the host keeps an archive.
	Archive *archiveCapabilities `json:"archive,omitempty"`

	// Project file changes and Git changes (files_mutate.go, files_search.go,
	// git_mutate.go). Every host serves them; "trash" is listed only where
	// the host can move items to a Trash (macOS).
	Files []string `json:"files,omitempty"`
	Git   []string `json:"git,omitempty"`

	// Workspaces (workspaces.go): every host lists them with details and
	// browses, adds, creates, renames and removes them.
	Projects *projectCapabilities `json:"projects,omitempty"`

	// Chat hub (M1 chunk A1): how each provider's chats reach the event
	// stream and what they support. Present only when the host streams chats.
	ChatProviderInfo *chatProviderInfo `json:"chatProviderInfo,omitempty"`

	// Presence views (notices.go): POST /v1/device/presence takes view.
	// Notices (notices.go): only for this Mac's own session, when kept.
	Presence []string `json:"presence,omitempty"`
	Notices  bool     `json:"notices,omitempty"`

	// Web previews (preview.go): the preview listener's port and scheme,
	// present only when serve runs with --enable-preview.
	Preview *previewCapabilities `json:"preview,omitempty"`

	// Routes (network_routes.go): the local name and, while Tailscale runs,
	// the Tailscale name and addresses, and what the last reading said of
	// Tailscale (running, notListening, off, notFound or unknown). Present
	// only when serve runs with --advertised-host.
	Routes    []hostRoute    `json:"routes,omitempty"`
	Tailscale tailscaleState `json:"tailscale,omitempty"`

	// Remote access (remote_access.go): present only when serve runs with
	// --tunnel-socket. deviceNodeId is the caller's own registered node ID.
	RemoteAccess *remoteAccessCapabilities `json:"remoteAccess,omitempty"`

	// Agents (agents_catalog.go): present with the agent catalog. agents
	// lists catalog, install and acp; agentCatalog the usable agents.
	Agents       []string             `json:"agents,omitempty"`
	AgentCatalog *[]agentCatalogEntry `json:"agentCatalog,omitempty"`

	// Plain chats (plain_chats.go): generalChats is present on a host with
	// the Chats space, its providers [] unless OpenCode runs Chat there;
	// plainChats, the key older clients read, only while OpenCode has
	// AgentLand's chat agent for the space.
	GeneralChats *generalChatsCapability `json:"generalChats,omitempty"`
	PlainChats   *plainChatsCapability   `json:"plainChats,omitempty"`
	// Chat in workspaces (owner, 2026-10-12): Claude Code and Codex by their
	// sign-ins, independent of OpenCode (plain_chats.go).
	WorkspaceChats *workspaceChatsCapability `json:"workspaceChats,omitempty"`

	// Vault (vault_routes.go): only for this Mac's own session, on a host
	// that offers it.
	Vault *vaultCapability `json:"vault,omitempty"`
}

// archiveCapabilities lists the archive features that work on this host.
// "continue" means POST /v1/chat/continue seeds new chats from the archive;
// "continueThrough" that it takes throughMessageId; "changesWait" that
// GET /v1/archive/changes takes wait (a long-poll); "blobs" that
// GET /v1/archive/blob serves attachment bytes.
type archiveCapabilities struct {
	Version  int      `json:"version"`
	Features []string `json:"features"`
}

type chatProviderInfo struct {
	OpenCode *chatProviderEntry `json:"opencode,omitempty"`
	Claude   *chatProviderEntry `json:"claude,omitempty"`
	Codex    *chatProviderEntry `json:"codex,omitempty"`
	// ACP chats (acp_provider.go): each ACP agent's entry under its id,
	// encoded after the others.
	ACP map[string]*chatProviderEntry `json:"-"`
}

// MarshalJSON writes opencode, claude and codex first, as before, then the
// ACP agents sorted by id.
func (info chatProviderInfo) MarshalJSON() ([]byte, error) {
	var buffer bytes.Buffer
	buffer.WriteByte('{')
	first := true
	write := func(key string, entry *chatProviderEntry) error {
		if entry == nil {
			return nil
		}
		value, err := json.Marshal(entry)
		if err != nil {
			return err
		}
		if !first {
			buffer.WriteByte(',')
		}
		first = false
		name, _ := json.Marshal(key)
		buffer.Write(name)
		buffer.WriteByte(':')
		buffer.Write(value)
		return nil
	}
	for _, pair := range []struct {
		key   string
		entry *chatProviderEntry
	}{{"opencode", info.OpenCode}, {"claude", info.Claude}, {"codex", info.Codex}} {
		if err := write(pair.key, pair.entry); err != nil {
			return nil, err
		}
	}
	ids := make([]string, 0, len(info.ACP))
	for id := range info.ACP {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if err := write(id, info.ACP[id]); err != nil {
			return nil, err
		}
	}
	buffer.WriteByte('}')
	return buffer.Bytes(), nil
}

// chatProviderEntry describes one provider. Features is the truth for what
// its chats support; version appears once the host has read it.
type chatProviderEntry struct {
	Version   string   `json:"version,omitempty"`
	Transport string   `json:"transport"`
	Features  []string `json:"features"`
}

func (h *Host) capabilities(w http.ResponseWriter, r *http.Request) {
	result := h.advertisedCapabilities()
	// Routes: the first answer waits for the first reading of Tailscale.
	result.Routes, result.Tailscale = h.routes.routes(r.Context())
	device, _ := h.authenticate(r)
	// Notices: only this Mac's own session reads them.
	if h.notices != nil && device.ID == "local-mac" {
		result.Notices = true
	}
	// Vault: only this Mac's own session changes it.
	if h.vault != nil && device.ID == "local-mac" {
		result.Vault = &vaultCapability{Version: 1}
	}
	// Remote access: the Mac endpoint as last reported, and the caller's own
	// node ID. The preview listener is not bridged, so answers through the
	// tunnel leave previews out.
	if h.remote != nil {
		result.RemoteAccess = h.remote.capability(device.IrohNodeID)
	}
	if _, tunnel := tunnelPeerFrom(r.Context()); tunnel {
		result.Preview = nil
	}
	writeJSON(w, 200, result)
}

// advertisedCapabilities reports only the features this host was configured
// with. Lists are never nil, so they encode as [] rather than null.
func (h *Host) advertisedCapabilities() hostCapabilities {
	_, interactions := h.agent.(InteractiveAgent)
	result := hostCapabilities{
		ChatFeatures:     []string{"reasoning"},
		ChatProviders:    []string{"opencode"},
		Interactions:     interactions,
		Terminal:         h.terminals != nil,
		TerminalPrograms: []string{},
	}
	if h.terminals != nil {
		result.TerminalPrograms = h.terminalPrograms()
		result.TerminalFeatures = []string{"title"}
		// Terminal ends (terminal_end.go): Claude Code terminals run a
		// conversation the host names, which POST /v1/terminals can resume.
		if _, resumes := h.terminals.launcher.resolveProgram("claude"); resumes {
			result.TerminalFeatures = append(result.TerminalFeatures, "resume")
		}
		// The keeper (terminal_backend.go) keeps terminals running while
		// AgentLand is closed, for the apps' wording.
		result.TerminalFeatures = append(result.TerminalFeatures, "keep")
		// Terminals from other devices (terminal_shared.go): every paired
		// device reaches every terminal, and GET /v1/terminals/others lists
		// the other devices' and the Mac's.
		result.TerminalFeatures = append(result.TerminalFeatures, "shared")
	}
	if h.cliChats != nil {
		result.ChatProviders = append(result.ChatProviders, h.cliChats.Available()...)
	}
	// Agents (agents_catalog.go): the usable agents, and the ACP chat agents
	// after AgentLand's own.
	var acpVersions map[string]string
	if h.agents != nil {
		catalog, chats, _, versions := h.agents.capabilityLists()
		result.Agents = []string{"catalog", "install", "updateSettings"}
		result.AgentCatalog = &catalog
		if h.cliChats != nil {
			result.Agents = append(result.Agents, "acp")
			acpVersions = versions
			for _, id := range chats {
				if !slices.Contains(result.ChatProviders, id) {
					result.ChatProviders = append(result.ChatProviders, id)
				}
			}
		}
	}
	if h.attachments != nil {
		result.ChatFeatures = append(result.ChatFeatures, "attachments")
	}
	if h.queue != nil {
		result.ChatFeatures = append(result.ChatFeatures, "queue")
	}
	// Claude Code streaming: Claude chats rewind as well.
	claude := h.cliChats != nil && h.cliChats.claude != nil && slices.Contains(result.ChatProviders, "claude")
	if _, rewind := h.agent.(RewindableAgent); rewind || claude {
		result.ChatFeatures = append(result.ChatFeatures, "rewind")
	}
	// Archive (M1 chunk B1); "continue" (M1 chunk B2) seeds new chats from
	// it, "continueThrough" up to a chosen message; "changesWait" long-polls
	// the change feed; "blobs" serves attachment bytes.
	if h.archive != nil {
		result.Archive = &archiveCapabilities{Version: 1, Features: []string{"sync", "search", "export", "terminalLogs", "continue", "continueThrough", "changesWait", "blobs"}}
	}
	// Project file changes and Git changes.
	result.Files = fileCapabilities()
	result.Git = []string{"stage", "unstage", "commit", "stagedDiff", "unstagedDiff", "identity", "branches", "history", "remotes", "stashes", "discard", "untrackedFiles"}
	// Workspaces.
	result.Projects = &projectCapabilities{Version: 1, Features: slices.Clone(projectFeatures)}
	// Streaming needs OpenCode's event stream; parts, stop (POST /v1/abort
	// for every provider) and clientMessageId work on any host.
	if h.chat.streams() {
		result.ChatFeatures = append(result.ChatFeatures, "events")
	}
	result.ChatFeatures = append(result.ChatFeatures, "parts", "stop")
	// Continue with another model (M1 chunk B2) works from the archive.
	if h.archive != nil {
		result.ChatFeatures = append(result.ChatFeatures, "continue", "continueThrough")
	}
	result.ChatFeatures = append(result.ChatFeatures, "clientMessageId")
	// Regenerate, fork, modes and effort (chat_regenerate.go, chat_fork.go):
	// listed when at least one provider supports them.
	supported := map[string]bool{}
	if _, rewind := h.agent.(RewindableAgent); rewind {
		supported["regenerate"] = true
	}
	if claude {
		for _, feature := range []string{"regenerate", "fork", "modes", "effort"} {
			supported[feature] = true
		}
	}
	if h.cliChats != nil && h.cliChats.codex != nil && slices.Contains(result.ChatProviders, "codex") {
		for _, feature := range h.cliChats.codex.capability().Features {
			supported[feature] = true
		}
	}
	// ACP chats take modes their agents list.
	if len(acpVersions) > 0 {
		supported["modes"] = true
	}
	for _, feature := range []string{"regenerate", "fork", "modes", "effort"} {
		if supported[feature] {
			result.ChatFeatures = append(result.ChatFeatures, feature)
		}
	}
	// Chat names (chat_title.go): titleSource and titleBasis on every chat,
	// free naming and POST /v1/chat/title, on every host.
	result.ChatFeatures = append(result.ChatFeatures, "title")
	if h.chat.streams() {
		opencode := openCodeProvider{agent: h.agent}
		info := &chatProviderInfo{OpenCode: &chatProviderEntry{Version: h.chat.openCodeVersion(), Transport: opencode.transport(), Features: opencode.features()}}
		for _, name := range result.ChatProviders[1:] {
			// ACP chats: the installed version, transport acp.
			if version, acp := acpVersions[name]; acp {
				if info.ACP == nil {
					info.ACP = map[string]*chatProviderEntry{}
				}
				info.ACP[name] = &chatProviderEntry{Version: version, Transport: acpProvider{}.transport(), Features: acpProvider{}.features()}
				continue
			}
			entry := &chatProviderEntry{Transport: "coarse", Features: cliProvider{provider: name}.features()}
			// Codex streaming: the Codex engine's transport ("app-server" or
			// "exec"), version and the features that work there.
			if name == "codex" && h.cliChats.codex != nil {
				entry = h.cliChats.codex.capability()
			}
			// Claude Code streaming: stream-json, the version read from the
			// installed CLI's path, and the features that work.
			if name == "claude" && h.cliChats.claude != nil {
				entry = &chatProviderEntry{Version: h.cliChats.claude.version(), Transport: claudeProvider{}.transport(), Features: claudeProvider{}.features()}
			}
			switch name {
			case "claude":
				info.Claude = entry
			case "codex":
				info.Codex = entry
			}
		}
		result.ChatProviderInfo = info
	}
	// Web previews.
	if h.preview != nil {
		result.Preview = previewCapabilitiesFor(h.preview.port)
	}
	// Presence views.
	result.Presence = []string{"views"}
	// Plain chats: the Chats space and the tools that work now.
	if general := h.plainChats.capability(); general != nil {
		result.GeneralChats = (*generalChatsCapability)(general)
	}
	result.PlainChats = h.plainChats.legacyCapability()
	// Chat in workspaces: Claude Code and Codex, whatever OpenCode does.
	result.WorkspaceChats = h.plainChats.workspaceCapability()
	return result
}
