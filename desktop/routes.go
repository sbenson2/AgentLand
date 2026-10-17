package host

import "net/http"

// route maps one exact method and path to its handler.
type route struct {
	method string
	path   string
	handle func(*Host, http.ResponseWriter, *http.Request)
	// public routes answer without bearer authentication. Only health and
	// pairing are public; the Origin rejection applies to them as well.
	public bool
	// localOnly marks a route for this Mac's own companion (the local session
	// token over loopback), never a paired device. serveHTTP answers every
	// other authenticated caller 403 local_only.
	localOnly bool
	// notTunnel marks a route refused through the remote-access tunnel
	// socket (pairing and registering a node ID): 403 tunnel_refused.
	notTunnel bool
}

// routes lists every endpoint, one entry each, grouped by area. Methods and
// paths match exactly: a known path with another method is answered like an
// unknown path, 401 without valid authentication and 404 with it.
var routes = []route{
	{method: "POST", path: "/v1/local-web/launch", handle: (*Host).localWebLaunch, localOnly: true, notTunnel: true},
	{method: "POST", path: "/v1/local-web/import", handle: (*Host).localWebImport, localOnly: true, notTunnel: true},
	// Reachability and pairing.
	{method: "GET", path: "/v1/health", handle: (*Host).health, public: true},
	{method: "POST", path: "/v1/pair", handle: (*Host).pair, public: true, notTunnel: true},

	// Host features and connection.
	{method: "GET", path: "/v1/capabilities", handle: (*Host).capabilities},
	{method: "GET", path: "/v1/pulse", handle: (*Host).pulse},
	{method: "POST", path: "/v1/device/presence", handle: (*Host).devicePresence},

	// Workspaces (workspaces.go): details, browsing the workspace home, and
	// adding, creating, renaming and removing workspaces.
	{method: "GET", path: "/v1/projects", handle: (*Host).projects},
	{method: "GET", path: "/v1/folders", handle: (*Host).browseFolders},
	{method: "POST", path: "/v1/projects", handle: (*Host).addProject},
	{method: "POST", path: "/v1/projects/create", handle: (*Host).createProject},
	{method: "POST", path: "/v1/projects/rename", handle: (*Host).renameProject},
	{method: "POST", path: "/v1/projects/remove", handle: (*Host).removeProject},

	// Chats.
	{method: "GET", path: "/v1/sessions", handle: (*Host).sessions},
	{method: "POST", path: "/v1/sessions", handle: (*Host).createSession},
	{method: "GET", path: "/v1/chat/options", handle: (*Host).chatOptions},
	{method: "GET", path: "/v1/chat/status", handle: (*Host).chatStatus},
	{method: "GET", path: "/v1/messages", handle: (*Host).messages},
	{method: "POST", path: "/v1/messages", handle: (*Host).prompt},
	{method: "POST", path: "/v1/messages/rewind", handle: (*Host).rewindChat},
	{method: "POST", path: "/v1/messages/restore", handle: (*Host).restoreChat},
	{method: "POST", path: "/v1/attachments", handle: (*Host).uploadAttachment},
	{method: "POST", path: "/v1/abort", handle: (*Host).abort},
	{method: "GET", path: "/v1/chat/events", handle: (*Host).chatEvents},
	{method: "GET", path: "/v1/chat/messages", handle: (*Host).chatMessages},
	// Chat fork (chat_fork.go): Codex chats through thread/fork.
	{method: "POST", path: "/v1/chat/fork", handle: (*Host).forkChat},
	// Regenerate (chat_regenerate.go): Claude Code and OpenCode chats.
	{method: "POST", path: "/v1/chat/regenerate", handle: (*Host).regenerateChat},
	// Chat names (chat_title.go): a name a device wrote.
	{method: "POST", path: "/v1/chat/title", handle: (*Host).chatTitle},
	// Chat's sign-ins (plain_chat_providers.go): a check now, for this Mac's
	// app while the person signs Claude Code or Codex in.
	{method: "POST", path: "/v1/chat/providers/check", handle: (*Host).chatProvidersCheck, localOnly: true},

	// Plain chats' memory (memory.go).
	{method: "GET", path: "/v1/memory", handle: (*Host).listMemory},
	{method: "PATCH", path: "/v1/memory", handle: (*Host).updateMemory},
	{method: "DELETE", path: "/v1/memory", handle: (*Host).deleteMemory},
	{method: "POST", path: "/v1/memory/settings", handle: (*Host).memorySettingsRoute},

	// Prompt queue.
	{method: "GET", path: "/v1/queue", handle: (*Host).listQueue},
	{method: "POST", path: "/v1/queue", handle: (*Host).addQueue},
	{method: "POST", path: "/v1/queue/remove", handle: (*Host).removeQueue},

	// Agent permission and question requests.
	{method: "GET", path: "/v1/interactions", handle: (*Host).interactions},
	{method: "POST", path: "/v1/permissions/reply", handle: (*Host).replyPermission},
	{method: "POST", path: "/v1/questions/reply", handle: (*Host).answerQuestion},
	{method: "POST", path: "/v1/questions/reject", handle: (*Host).rejectQuestion},

	// Project files.
	{method: "GET", path: "/v1/files", handle: (*Host).listFiles},
	{method: "GET", path: "/v1/file", handle: (*Host).readFile},
	{method: "POST", path: "/v1/file", handle: (*Host).saveFile},

	// Git.
	{method: "GET", path: "/v1/git/repositories", handle: (*Host).gitRepositories},
	{method: "GET", path: "/v1/git/status", handle: (*Host).gitStatus},
	{method: "GET", path: "/v1/git/diff", handle: (*Host).gitDiff},

	// Project file changes, file search and Git changes (files_mutate.go,
	// files_search.go, git_mutate.go).
	{method: "POST", path: "/v1/files/move", handle: (*Host).moveFile},
	{method: "POST", path: "/v1/files/mkdir", handle: (*Host).makeDirectory},
	{method: "POST", path: "/v1/files/upload", handle: (*Host).uploadFile},
	{method: "POST", path: "/v1/files/delete", handle: (*Host).deleteFile},
	{method: "GET", path: "/v1/files/search", handle: (*Host).searchFiles},
	{method: "GET", path: "/v1/git/identity", handle: (*Host).gitIdentityRoute},
	{method: "POST", path: "/v1/git/stage", handle: (*Host).gitStage},
	{method: "POST", path: "/v1/git/unstage", handle: (*Host).gitUnstage},
	{method: "POST", path: "/v1/git/commit", handle: (*Host).gitCommit},
	{method: "GET", path: "/v1/git/branches", handle: (*Host).gitBranches},
	{method: "POST", path: "/v1/git/branch", handle: (*Host).gitBranch},
	{method: "GET", path: "/v1/git/history", handle: (*Host).gitHistory},
	{method: "GET", path: "/v1/git/commit", handle: (*Host).gitCommitFiles},
	{method: "GET", path: "/v1/git/commit/diff", handle: (*Host).gitCommitDiff},
	{method: "GET", path: "/v1/git/remotes", handle: (*Host).gitRemotes},
	{method: "POST", path: "/v1/git/remote", handle: (*Host).gitRemote},
	{method: "GET", path: "/v1/git/stashes", handle: (*Host).gitStashes},
	{method: "POST", path: "/v1/git/stash", handle: (*Host).gitStash},
	{method: "POST", path: "/v1/git/discard", handle: (*Host).gitDiscard},

	// Terminals.
	{method: "POST", path: "/v1/terminal/title", handle: (*Host).terminalContextTitle},
	{method: "GET", path: "/v1/terminals", handle: (*Host).listTerminals},
	// Terminals from other devices (terminal_shared.go): every device sees them.
	{method: "GET", path: "/v1/terminals/others", handle: (*Host).otherTerminals},
	{method: "POST", path: "/v1/terminals", handle: (*Host).createTerminal},
	{method: "GET", path: "/v1/terminal/output", handle: (*Host).terminalOutput},
	{method: "POST", path: "/v1/terminal/input", handle: (*Host).terminalInput},
	{method: "POST", path: "/v1/terminal/resize", handle: (*Host).resizeTerminal},
	{method: "POST", path: "/v1/terminal/close", handle: (*Host).closeTerminal},
	// Mac-only (terminal_mac_routes.go): every device's terminals, for the
	// Mac app's Quit question, Terminals settings and device removal.
	{method: "GET", path: "/v1/terminals/running", handle: (*Host).macTerminalsRunning, localOnly: true, notTunnel: true},
	{method: "POST", path: "/v1/terminals/end-all", handle: (*Host).macTerminalsEndAll, localOnly: true, notTunnel: true},
	{method: "GET", path: "/v1/terminals/all", handle: (*Host).macTerminalsAll, localOnly: true, notTunnel: true},
	{method: "POST", path: "/v1/terminals/end", handle: (*Host).macTerminalsEnd, localOnly: true, notTunnel: true},
	{method: "POST", path: "/v1/terminals/clear", handle: (*Host).macTerminalsClear, localOnly: true, notTunnel: true},
	{method: "POST", path: "/v1/terminals/end-device", handle: (*Host).macTerminalsEndDevice, localOnly: true, notTunnel: true},

	// Archive (M1 chunk B1): the host's local copy of chats and terminal output.
	{method: "GET", path: "/v1/archive/changes", handle: (*Host).archiveChanges},
	{method: "GET", path: "/v1/archive/chat", handle: (*Host).archiveChat},
	{method: "GET", path: "/v1/archive/search", handle: (*Host).archiveSearch},
	{method: "GET", path: "/v1/archive/export", handle: (*Host).archiveExport},
	{method: "GET", path: "/v1/archive/terminal-logs", handle: (*Host).archiveTerminalLogs},
	{method: "GET", path: "/v1/archive/terminal-log", handle: (*Host).archiveTerminalLog},
	{method: "POST", path: "/v1/archive/delete", handle: (*Host).archiveDelete},
	{method: "GET", path: "/v1/archive/stats", handle: (*Host).archiveStats, localOnly: true},
	// Attachment bytes on demand (archive_blob.go).
	{method: "GET", path: "/v1/archive/blob", handle: (*Host).archiveBlob},
	// Vault (vault_routes.go): the Markdown copy of the archive, for this
	// Mac's app.
	{method: "GET", path: "/v1/vault", handle: (*Host).vaultStatusRoute, localOnly: true},
	{method: "POST", path: "/v1/vault/settings", handle: (*Host).vaultSettingsRoute, localOnly: true},
	{method: "POST", path: "/v1/vault/rebuild", handle: (*Host).vaultRebuildRoute, localOnly: true},
	// Continue with another model (M1 chunk B2, archive_continue.go): a new
	// chat seeded from an archived one.
	{method: "POST", path: "/v1/chat/continue", handle: (*Host).continueChat},

	// Web previews (preview.go): ports and sessions. The proxy itself runs
	// on the preview listener, which never serves /v1.
	{method: "GET", path: "/v1/preview/ports", handle: (*Host).previewPorts},
	{method: "POST", path: "/v1/preview/sessions", handle: (*Host).createPreviewSession},
	{method: "GET", path: "/v1/preview/sessions", handle: (*Host).listPreviewSessions},
	{method: "POST", path: "/v1/preview/sessions/revoke", handle: (*Host).revokePreviewSession},

	// Notices (notices.go): for this Mac's app, which relays them.
	{method: "GET", path: "/v1/notices", handle: (*Host).listNotices, localOnly: true},
	{method: "POST", path: "/v1/notices/ack", handle: (*Host).ackNotices, localOnly: true},

	// Agents (agents_routes.go, providers.go): the agent catalog, its icons,
	// installs, updates and uninstalls, and OpenCode's providers.
	{method: "GET", path: "/v1/agents", handle: (*Host).listAgents},
	{method: "GET", path: "/v1/agents/icon", handle: (*Host).agentIcon},
	{method: "POST", path: "/v1/agents/install", handle: (*Host).installAgent},
	{method: "POST", path: "/v1/agents/uninstall", handle: (*Host).uninstallAgent},
	{method: "POST", path: "/v1/agents/settings", handle: (*Host).agentSettings},
	{method: "POST", path: "/v1/agents/update", handle: (*Host).updateAgent},
	{method: "GET", path: "/v1/providers", handle: (*Host).listProviders},
	// The Mac app's word that the managed OpenCode did not start.
	{method: "POST", path: "/v1/agents/opencode/failed", handle: (*Host).openCodeFailed, localOnly: true},

	// Remote access (remote_access.go): the node IDs the Mac app's gate
	// admits and the Mac endpoint's report, for this Mac's app; a paired
	// device registers its node ID over the TCP listener only.
	{method: "GET", path: "/v1/remote-access/peers", handle: (*Host).remoteAccessPeers, localOnly: true},
	{method: "POST", path: "/v1/remote-access/endpoint", handle: (*Host).reportRemoteEndpoint, localOnly: true},
	{method: "POST", path: "/v1/remote-access/device", handle: (*Host).registerDeviceNode, notTunnel: true},
}

type routeKey struct{ method, path string }

// routeIndex is built once at startup. A repeated method and path panics there
// instead of one entry silently hiding the other.
var routeIndex = indexRoutes(routes)

func indexRoutes(table []route) map[routeKey]route {
	index := make(map[routeKey]route, len(table))
	for _, entry := range table {
		key := routeKey{entry.method, entry.path}
		if _, exists := index[key]; exists {
			panic("host: duplicate route " + entry.method + " " + entry.path)
		}
		index[key] = entry
	}
	return index
}

func (h *Host) Handler() http.Handler { return http.HandlerFunc(h.serveHTTP) }

// serveHTTP answers JSON with no-store caching, rejects every request that
// carries a browser Origin, refuses pairing and registering through the
// remote-access tunnel and tokens of another device than the tunnel's,
// authenticates every route that is not public, admits only this Mac's own
// session to local-only routes, and then runs the route that matches the
// exact method and path.
func (h *Host) serveHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if r.Header.Get("Origin") != "" {
		writeError(w, 403, "origin_rejected", "Browser origins are not allowed")
		return
	}
	// An unknown method and path is the zero route, which is not public, so it
	// is authenticated before it is answered 404.
	entry, found := routeIndex[routeKey{r.Method, r.URL.Path}]
	// Remote access: checked before anything else, so a pairing request
	// through the tunnel never counts toward the pairing limits.
	if peer, tunnel := tunnelPeerFrom(r.Context()); tunnel {
		if entry.notTunnel {
			writeError(w, 403, "tunnel_refused", "Pair and register this device on the Mac's own network, not through remote access")
			return
		}
		if h.tunnelDeviceMismatch(r, peer) {
			writeError(w, 403, "tunnel_device_mismatch", "This device's connection carries another device's credentials")
			return
		}
	}
	if !entry.public && !h.authorized(r) {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	if !found {
		writeError(w, 404, "not_found", "Route not found")
		return
	}
	if entry.localOnly && !h.localSession(r) {
		writeError(w, 403, "local_only", "Only this Mac's AgentLand app can use this route")
		return
	}
	entry.handle(h, w, r)
}

// The two question routes share replyQuestion; rejecting cancels the question.
func (h *Host) answerQuestion(w http.ResponseWriter, r *http.Request) {
	h.replyQuestion(w, r, false)
}
func (h *Host) rejectQuestion(w http.ResponseWriter, r *http.Request) {
	h.replyQuestion(w, r, true)
}
