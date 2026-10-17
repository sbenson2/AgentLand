package host

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxRequestBody = 64 << 10
const maxPairingClients = 1024

type Host struct {
	filesMu           sync.Mutex
	store             *Store
	agent             Agent
	attempts          sync.Mutex
	pairAttempts      map[string][]time.Time
	allPairAttempts   []time.Time
	now               func() time.Time
	terminals         *terminalManager
	localSessionToken string
	cliChats          *CLIChats
	attachments       *AttachmentStore
	queue             *PromptQueue
	sessionMu         sync.Mutex
	sessionLocks      map[sessionKey]*sessionLock
	closeOnce         sync.Once
	stopping          chan struct{}
	stoppingOnce      sync.Once
	pulseEvery        time.Duration
	pulseFor          time.Duration
	stopMaintenance   chan struct{}
	maintenanceDone   chan struct{}

	// Archive (M1 chunk B1): the local copy of chats and terminal output;
	// nil when serve runs with --no-archive.
	archive *Archive
	// Archive backfill (M1 chunk B2, archive_backfill.go): imports existing
	// chats; nil without an archive. NewWithOptions starts it.
	backfill *archiveBackfill
	// Vault (vault_routes.go): its settings and writer; nil without an
	// archive or HostOptions.Vault. NewWithOptions starts the writer the
	// state file asks for.
	vault *hostVault
	// Project file changes, file search and Git changes: upload and search
	// admission, repository locks and test seams (files_mutate.go,
	// files_search.go, git_mutate.go). File changes also hold filesMu.
	mutations hostMutations
	// Chat hub, event streams and send receipts (M1 chunk A1). Durations are
	// fields so tests can shorten them; chatExtendDeadlines is only turned
	// off by the test that proves deadline extension is needed.
	chat                *chatHub
	receipts            *sendReceipts
	chatStreamsMu       sync.Mutex
	chatStreams         map[string]int
	chatStreamFor       time.Duration
	chatBeatEvery       time.Duration
	chatAuthEvery       time.Duration
	chatWriteWait       time.Duration
	chatPace            time.Duration
	chatExtendDeadlines bool

	// Web previews (preview.go, preview_proxy.go): sessions and the proxy
	// behind the preview listener; nil unless HostOptions.Preview is set.
	preview *previewManager

	// Notices (notices.go): the notices for this Mac's app (nil without its
	// local session) and the chats devices report viewing, held in memory
	// only.
	notices *noticeCenter
	views   presenceViews

	// Workspaces (workspaces.go): the configured workspace home (empty for
	// this user's home folder) and the lock that serializes workspace changes.
	workspaceHomeOption string
	workspaceMu         sync.Mutex

	// Routes (network_routes.go): nil unless HostOptions.Routes is set.
	routes *routeAdvertiser

	// Remote access (remote_access.go, tunnel.go): nil unless
	// HostOptions.RemoteAccess is set with the local session.
	remote *remoteAccess

	// Chat names (chat_title.go, chat_title_store.go): the host's names for
	// chats, kept in memory when HostOptions.ChatTitles is nil, and the
	// locks that serialize naming each chat.
	titles     *ChatTitleStore
	titleMu    sync.Mutex
	titleLocks map[sessionKey]*sessionLock

	// Agents (agents_catalog.go): the agent catalog, installs, automatic
	// updates and the ACP chats' agents; nil unless HostOptions.Agents is set.
	agents *agentCatalog

	// Plain chats (plain_chats.go): the Chats space, its memory and the
	// check of the chat agent; nil unless HostOptions.PlainChats is set.
	plainChats *plainChats
	localWeb   *localWeb

	// version is HostOptions.Version, the build a local registration must
	// name (terminal_local.go).
	version string
}

func (h *Host) configureLocalWeb(w *localWeb) { h.localWeb = w }

func New(store *Store, agent Agent) *Host {
	return NewWithOptions(store, agent, HostOptions{})
}
func NewWithOptions(store *Store, agent Agent, options HostOptions) *Host {
	host := newHost(store, agent, options)
	// Terminals (terminal_restore.go): the terminals the keeper still holds
	// come back before the host serves, and the archive's logs are settled.
	host.restoreTerminals(context.Background())
	// With terminal access off, a keeper's leftover terminals are ended.
	host.endLeftoverTerminals(options)
	// With terminal access on, the routing switch keeps a keeper running.
	host.startKeeperKeepAlive()
	host.startMaintenance(time.Second)
	// Routes: Tailscale's status is read now and every five minutes.
	if host.routes != nil {
		host.routes.start()
	}
	// Archive backfill (M1 chunk B2).
	if host.backfill != nil {
		host.backfill.start()
	}
	// Vault: the writer runs when the state file says it is on.
	host.vault.start()
	// Remote access: the peer list follows the state file.
	host.remote.start()
	// Agents: automatic updates, and the activity behind idleForSeconds.
	host.agents.start()
	// Plain chats: the chat agent is checked now and then on its pace.
	host.plainChats.start()
	return host
}

// newHost does not start the queue dispatcher; tests drive it with maintain.
func newHost(store *Store, agent Agent, options HostOptions) *Host {
	host := &Host{store: store, agent: agent, pairAttempts: map[string][]time.Time{}, now: time.Now, localSessionToken: options.LocalSessionToken, cliChats: options.CLIChats, attachments: options.Attachments, queue: options.Queue, sessionLocks: map[sessionKey]*sessionLock{}, stopping: make(chan struct{}), pulseEvery: pulseInterval, pulseFor: pulseLifetime}
	// Chat names (chat_title.go).
	host.titles, host.titleLocks = options.ChatTitles, map[sessionKey]*sessionLock{}
	if host.titles == nil {
		host.titles = newMemoryChatTitleStore()
	}
	// Terminals (terminal_backend.go): every terminal runs in the keeper.
	if options.TerminalEnabled && options.Terminals != nil {
		host.terminals = &terminalManager{backend: options.Terminals, entries: map[string]*terminalEntry{}, cleared: map[string]clearedTerminal{}, now: time.Now, command: foregroundCommand,
			stopping: host.stopping, closing: make(chan struct{}), keeperGone: make(chan struct{}, 1), launcher: newHostTerminalLauncher(store, agent, options),
			restore: host.restoreTerminals, retryEvery: keeperRetryEvery, reattachQuick: terminalReattachQuick}
	}
	host.version = options.Version
	// Archive (M1 chunk B1).
	host.archive = options.Archive
	host.mutations.configure(options) // file and Git changes
	host.workspaceHomeOption = options.WorkspaceHome
	if options.Routes != nil {
		host.routes = newRouteAdvertiser(*options.Routes)
	}
	if options.RemoteAccess && options.LocalSessionToken != "" {
		host.remote = newRemoteAccess(host)
	}
	host.chat = newChatHub(host)
	// Archive backfill (M1 chunk B2).
	if host.archive != nil {
		host.backfill = newArchiveBackfill(host)
	}
	// Vault (vault_routes.go).
	if host.archive != nil && options.Vault != nil {
		host.vault = newHostVault(host, *options.Vault)
	}
	host.receipts = newSendReceipts()
	host.chatStreamFor, host.chatBeatEvery, host.chatAuthEvery = chatStreamLifetime, chatBeatInterval, chatAuthInterval
	host.chatWriteWait, host.chatPace, host.chatExtendDeadlines = chatWriteTimeout, chatStreamPace, true
	// Agents (agents_catalog.go): the catalog, which also names the managed
	// OpenCode and the agents' commands for terminals (terminal_launch.go).
	if options.Agents != nil {
		host.agents = newAgentCatalog(host, store.Path, *options.Agents)
		if host.terminals != nil {
			host.terminals.launcher.agents = host.agents
		}
	}
	if options.CLIChats != nil {
		options.CLIChats.setObserver(host.chat.cliChanged)
		// Codex streaming: the Codex engine mirrors its chats to the hub.
		options.CLIChats.setHub(host.chat)
		// Claude Code streaming: the Claude engine pushes its chats' changes.
		options.CLIChats.setClaudeHub(host.chat)
		// ACP chats: the engine runs the catalog's agents and pushes to the hub.
		if host.agents != nil {
			options.CLIChats.setACPAgents(host.agents, host.chat)
		} else {
			options.CLIChats.setACPAgents(nil, host.chat)
		}
		// Agents a killed host left running (ACP agents, Claude Code, Codex)
		// end now, and this host's are recorded for the next one
		// (acp_leftovers.go).
		options.CLIChats.processes.keep(store.Path+".acp-processes.json", store.Path+".agents")
	}
	// Web previews (preview.go).
	if options.Preview != nil {
		host.preview = newPreviewManager(store, *options.Preview)
	}
	// Notices (notices.go) are kept for this Mac's app alone; the hub tells
	// them about turns and interactions and follows chats through turns.
	if options.LocalSessionToken != "" {
		host.notices = newNoticeCenter(host)
		host.chat.observer, host.chat.noticeFollow = host.chatObserved, true
	}
	// Plain chats (plain_chats.go): the Chats space, its memory and the
	// memory socket of the tool server.
	if options.PlainChats != nil {
		host.plainChats = newPlainChats(host, store.Path, *options.PlainChats)
	}
	return host
}

// startMaintenance runs maintain every interval while the host has anything
// to maintain: the queue, attachments, the archive or notices.
func (h *Host) startMaintenance(interval time.Duration) {
	if h.queue == nil && h.attachments == nil && h.archive == nil && h.notices == nil && h.terminals == nil {
		return
	}
	h.stopMaintenance = make(chan struct{})
	h.maintenanceDone = make(chan struct{})
	go func() {
		defer close(h.maintenanceDone)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-h.stopMaintenance:
				return
			case <-ticker.C:
				h.maintain(h.stopMaintenance)
			}
		}
	}()
}

func (h *Host) maintain(stop <-chan struct{}) {
	// Notices: retention and viewing presence.
	if h.notices != nil {
		h.notices.maintain()
	}
	if h.attachments != nil {
		h.attachments.sweepIfDue()
	}
	// Archive (M1 chunk B1): free-space check, buffered terminal output and
	// blob collection.
	if h.archive != nil {
		h.archive.maintain()
	}
	// Terminals: finished ones are cleared a day after they finish.
	h.terminals.clearFinishedEveryMinute(stop)
	if h.queue != nil {
		h.dispatchQueue(stop)
	}
}

type sessionKey struct{ projectID, sessionID string }

type sessionLock struct {
	sync.Mutex
	users int
}

// lockSession serializes prompts, rewinds and queue dispatch for one chat so
// a queued message cannot slip between another operation's checks and effect.
func (h *Host) lockSession(projectID, sessionID string) func() {
	key := sessionKey{projectID, sessionID}
	h.sessionMu.Lock()
	lock := h.sessionLocks[key]
	if lock == nil {
		lock = &sessionLock{}
		h.sessionLocks[key] = lock
	}
	lock.users++
	h.sessionMu.Unlock()
	lock.Lock()
	return func() {
		lock.Unlock()
		h.sessionMu.Lock()
		if lock.users--; lock.users == 0 {
			delete(h.sessionLocks, key)
		}
		h.sessionMu.Unlock()
	}
}
func (h *Host) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]any{"status": "ok", "protocolVersion": 1})
}
func (h *Host) devicePresence(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Active *bool `json:"active"`
		// Presence views (notices.go): the chat the device shows, held in
		// memory only (capability presence ["views"]).
		View *presenceViewInput `json:"view,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Active == nil {
		writeError(w, 400, "invalid_request", "Active state is required")
		return
	}
	if in.View != nil && !in.View.valid() {
		writeError(w, 400, "invalid_request", "A view needs a projectId and a sessionId")
		return
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	if device.ID == "local-mac" {
		writeError(w, 403, "presence_unavailable", "Presence is for paired devices")
		return
	}
	if err := h.store.SetDevicePresence(device.ID, *in.Active); err != nil {
		internal(w)
		return
	}
	// Presence views: never written to host state.
	h.views.update(device.ID, *in.Active, in.View, h.now())
	writeJSON(w, 200, map[string]bool{"accepted": true})
}
func (h *Host) authorized(r *http.Request) bool {
	v := r.Header.Get("Authorization")
	if !strings.HasPrefix(v, "Bearer ") {
		return false
	}
	token := strings.TrimPrefix(v, "Bearer ")
	if token == "" {
		return false
	}
	_, ok := h.authenticate(r)
	return ok
}
func (h *Host) authenticate(r *http.Request) (Device, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	// Remote access: a request through the tunnel socket is never this Mac's
	// own, and its token must be the device's whose node ID the preamble named.
	peer, tunnel := tunnelPeerFrom(r.Context())
	if h.localSessionToken != "" && subtle.ConstantTimeCompare([]byte(token), []byte(h.localSessionToken)) == 1 {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err == nil && !tunnel {
			if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
				return Device{ID: "local-mac"}, true
			}
		}
		return Device{}, false
	}
	device, ok := h.store.Authenticate(token)
	if ok && tunnel && device.IrohNodeID != peer.nodeID {
		return Device{}, false
	}
	return device, ok
}

// tunnelDeviceMismatch reports a request through the tunnel whose token is a
// paired device's, but not the device's whose node ID the preamble named.
func (h *Host) tunnelDeviceMismatch(r *http.Request, peer tunnelPeer) bool {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "" {
		return false
	}
	device, ok := h.store.Authenticate(token)
	return ok && device.IrohNodeID != peer.nodeID
}

func (h *Host) pair(w http.ResponseWriter, r *http.Request) {
	if !h.allowPair(r.RemoteAddr) {
		writeError(w, 429, "rate_limited", "Too many pairing attempts")
		return
	}
	var in struct {
		Code       string `json:"code"`
		DeviceName string `json:"deviceName"`
		// Remote access: the device's iroh node ID and the proof that it holds
		// the key (both or neither; QR invitations with remoteAccess).
		IrohNodeID    *string `json:"irohNodeId,omitempty"`
		IrohNodeProof *string `json:"irohNodeProof,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Code == "" {
		writeError(w, 400, "invalid_request", "Pairing code is required")
		return
	}
	// Checked before the code, so a refusal leaves the code unused.
	nodeID, ok := h.pairingNode(w, in.Code, in.IrohNodeID, in.IrohNodeProof)
	if !ok {
		return
	}
	pairing, err := h.store.RedeemPairing(in.Code, in.DeviceName, nodeID, previousPairingToken(r))
	if err != nil {
		writeError(w, 401, "invalid_pairing_code", "Pairing code is invalid or expired")
		return
	}
	// Remote access: the Mac app's gate learns the new node ID at once, and
	// a replaced record's tunnel connections close, as a revocation's do,
	// since the token they carried no longer works.
	if (nodeID != "" || pairing.Replaced) && h.remote != nil {
		h.remote.refresh()
		if pairing.Replaced {
			h.remote.tunnel.closeDevice(pairing.DeviceID)
		}
	}
	writeJSON(w, 200, map[string]string{"token": pairing.Token, "deviceId": pairing.DeviceID})
}

// previousPairingToken is the bearer token a device that pairs again sends
// with POST /v1/pair to show which record is its own (docs/HOST-API.md,
// "Pairing again"); "" for none. The route stays public: a token that
// authenticates no device is ignored, and so is one longer than any token
// this host issues.
func previousPairingToken(r *http.Request) string {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || len(token) > maxPairingTokenBytes {
		return ""
	}
	return token
}

// maxPairingTokenBytes bounds a token offered with POST /v1/pair; the tokens
// this host issues are 52 characters.
const maxPairingTokenBytes = 256

func (h *Host) allowPair(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	now := h.now()
	h.attempts.Lock()
	defer h.attempts.Unlock()
	// A numeric PIN must not become easier to guess by rotating client IPs.
	globalRecent := h.allPairAttempts[:0]
	for _, attemptedAt := range h.allPairAttempts {
		if now.Sub(attemptedAt) < time.Minute {
			globalRecent = append(globalRecent, attemptedAt)
		}
	}
	h.allPairAttempts = globalRecent
	if len(globalRecent) >= 30 {
		return false
	}
	for client, attempts := range h.pairAttempts {
		recent := attempts[:0]
		for _, t := range attempts {
			if now.Sub(t) < time.Minute {
				recent = append(recent, t)
			}
		}
		if len(recent) == 0 {
			delete(h.pairAttempts, client)
		} else {
			h.pairAttempts[client] = recent
		}
	}
	if _, known := h.pairAttempts[host]; !known && len(h.pairAttempts) >= maxPairingClients {
		return false
	}
	recent := h.pairAttempts[host][:0]
	for _, t := range h.pairAttempts[host] {
		if now.Sub(t) < time.Minute {
			recent = append(recent, t)
		}
	}
	if len(recent) >= 10 {
		h.pairAttempts[host] = recent
		return false
	}
	h.pairAttempts[host] = append(recent, now)
	h.allPairAttempts = append(h.allPairAttempts, now)
	return true
}
func (h *Host) project(id string) (Project, error) {
	st, err := h.store.Read()
	if err != nil {
		return Project{}, err
	}
	for _, p := range st.Config.Projects {
		if subtle.ConstantTimeCompare([]byte(p.ID), []byte(id)) == 1 {
			return p, nil
		}
	}
	return Project{}, ErrNotFound
}
func (h *Host) session(project Project, id string) (Session, error) {
	var s Session
	var err error
	if isCLISessionID(id) {
		if h.cliChats == nil {
			return Session{}, ErrNotFound
		}
		s, err = h.cliChats.GetSession(project, id)
	} else {
		s, err = h.agent.GetSession(project, id)
	}
	if err != nil {
		return Session{}, err
	}
	if !sameDirectory(project.Directory, s.Directory) {
		return Session{}, ErrNotFound
	}
	s.ProjectID = project.ID
	s.Directory = ""
	// Chat names (chat_title.go).
	h.nameSession(&s)
	return s, nil
}
func (h *Host) sessions(w http.ResponseWriter, r *http.Request) {
	p, err := h.chatProject(r.URL.Query().Get("projectId"))
	if err != nil {
		notFound(w)
		return
	}
	items, err := h.agent.ListSessions(p)
	if err != nil && !h.isPlainChat(p) {
		internal(w)
		return
	}
	if h.cliChats != nil {
		items = append(items, h.cliChats.ListSessions(p)...)
	}
	out := []Session{}
	for _, s := range items {
		if sameDirectory(p.Directory, s.Directory) {
			s.ProjectID = p.ID
			s.Directory = ""
			// Chat names (chat_title.go).
			h.nameSession(&s)
			out = append(out, s)
		}
	}
	writeJSON(w, 200, map[string]any{"sessions": out})
}
func sameDirectory(a, b string) bool {
	ai, aerr := os.Stat(filepath.Clean(a))
	bi, berr := os.Stat(filepath.Clean(b))
	return aerr == nil && berr == nil && ai.IsDir() && bi.IsDir() && os.SameFile(ai, bi)
}
func (h *Host) createSession(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		Title     string `json:"title"`
		Provider  string `json:"provider,omitempty"`
		// Claude Code streaming: the new chat's model, mode and effort
		// (chatFeatures "modes", "effort").
		Model  string `json:"model,omitempty"`
		Mode   string `json:"mode,omitempty"`
		Effort string `json:"effort,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	p, err := h.chatProject(in.ProjectID)
	if err != nil {
		notFound(w)
		return
	}
	if len(in.Title) > 200 {
		writeError(w, 400, "invalid_request", "Title is too long")
		return
	}
	// Plain chats: the Chats space runs OpenCode's chat agent only.
	plain := h.isPlainChat(p)
	if plain && plainChatOptionsRefused(w, in.Mode) {
		return
	}
	settings := PromptOptions{Model: in.Model, Mode: in.Mode, Effort: in.Effort}
	if settings != (PromptOptions{}) {
		if in.Provider != "claude" || h.cliChats == nil || h.cliChats.claude == nil {
			writeError(w, 400, "unsupported_options", "This agent does not take a model, mode or effort when a chat is created")
			return
		}
		if !claudeValidOptions(settings) {
			writeError(w, 400, "invalid_agent_options", "Choose settings supported by this Mac agent")
			return
		}
	}
	// Chat runs Claude Code and Codex on subscriptions only, in every
	// workspace as in the Chats space.
	if !h.chatProviderReady(w, r, p, in.Provider) {
		return
	}
	var s Session
	if in.Provider == "" || in.Provider == "opencode" {
		// Plain chats are created with the chat agent's rules (provider.go).
		s, err = h.chatProviderFor(Session{}).create(p, in.Title)
		if errors.Is(err, errPlainChatUnavailable) {
			writePlainChatUnavailable(w, err)
			return
		}
	} else if in.Provider == "claude" || in.Provider == "codex" {
		if h.cliChats == nil {
			writeError(w, 503, "agent_unavailable", "This Mac agent is unavailable")
			return
		}
		s, err = h.cliChats.CreateSession(p, in.Title, in.Provider)
	} else if h.agents != nil && h.cliChats != nil && agentIDPattern.MatchString(in.Provider) {
		// ACP chats (acp_engine.go): an agent of the catalog.
		if _, known := h.agents.knownAgent(in.Provider); !known {
			writeError(w, 400, "invalid_provider", "Choose an available Mac agent")
			return
		}
		s, err = h.cliChats.acp.create(p, in.Title, in.Provider)
		if errors.Is(err, errACPUnavailable) {
			writeError(w, 503, "agent_unavailable", "This agent is not installed or cannot run chats now")
			return
		}
	} else {
		writeError(w, 400, "invalid_provider", "Choose an available Mac agent")
		return
	}
	if err != nil {
		if errors.Is(err, ErrCLIChatUnavailable) {
			writeError(w, 503, "agent_unavailable", "This Mac agent is unavailable")
			return
		}
		internal(w)
		return
	}
	if s.Directory == "" {
		s.Directory = p.Directory
	}
	// Claude Code streaming: the settings the first turn starts with.
	if settings != (PromptOptions{}) {
		if err := h.cliChats.claude.configure(p, s.ID, settings); err != nil {
			internal(w)
			return
		}
	}
	if s, err = h.session(p, s.ID); err != nil {
		notFound(w)
		return
	}
	writeJSON(w, 201, s)
}
func (h *Host) messages(w http.ResponseWriter, r *http.Request) {
	p, s, ok := h.chatScoped(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("sessionId"))
	if !ok {
		return
	}
	items, err := h.transcript(p, s)
	if err != nil {
		internal(w)
		return
	}
	body := map[string]any{"messages": items}
	if r.URL.Query().Get("parts") == "1" {
		body["messages"] = h.messagesWithParts(p, s, items)
	}
	if s.RewindMessageID != "" {
		body["rewind"] = map[string]string{"messageId": s.RewindMessageID}
	}
	writeJSON(w, 200, body)
}

// transcript omits messages from an OpenCode revert point onward; OpenCode
// still returns them until the chat is restored or a new prompt removes them.
func (h *Host) transcript(p Project, s Session) ([]Message, error) {
	if isCLISessionID(s.ID) {
		return h.cliChats.Messages(p, s.ID)
	}
	items, err := h.agent.Messages(p, s.ID)
	if err != nil || s.RewindMessageID == "" {
		return items, err
	}
	for index, item := range items {
		if item.ID == s.RewindMessageID {
			return items[:index], nil
		}
	}
	return items, nil
}

// chatState reports "idle", "busy", "retry" or "unknown".
func (h *Host) chatState(p Project, sessionID string) (string, error) {
	if isCLISessionID(sessionID) {
		if h.cliChats == nil {
			return "", ErrNotFound
		}
		status, err := h.cliChats.Status(p, sessionID)
		return status.State, err
	}
	agent, ok := h.agent.(ConfigurableAgent)
	if !ok {
		return "unknown", nil
	}
	status, err := agent.ChatStatus(p, sessionID)
	return status.State, err
}

const maxPromptText = 32768

func (h *Host) prompt(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID       string   `json:"projectId"`
		SessionID       string   `json:"sessionId"`
		Text            string   `json:"text"`
		Model           string   `json:"model,omitempty"`
		Agent           string   `json:"agent,omitempty"`
		Attachments     []string `json:"attachments,omitempty"`
		ClientMessageID string   `json:"clientMessageId,omitempty"`
		// Codex streaming: the chat's mode and reasoning effort for this and
		// later messages (chatProviderInfo.codex features "modes", "effort").
		Mode   string `json:"mode,omitempty"`
		Effort string `json:"effort,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.Text) > maxPromptText || (in.Text == "" && len(in.Attachments) == 0) {
		writeError(w, 400, "invalid_request", "Text or an attachment is required; text must not exceed 32768 bytes")
		return
	}
	if len(in.Attachments) > attachmentsPerMessage {
		writeError(w, 400, "invalid_attachment", "Attach at most five files to one message")
		return
	}
	if in.ClientMessageID != "" && !validClientMessageID(in.ClientMessageID) {
		writeError(w, 400, "invalid_request", "clientMessageId must be 32 to 64 letters, digits, hyphens or underscores")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	// Plain chats: the chat agent runs every prompt, and nothing is sent
	// while it is not confirmed.
	if h.isPlainChat(p) && plainChatOptionsRefused(w, in.Agent, in.Mode) {
		return
	}
	// Subscriptions only, for every Claude Code and Codex chat.
	if !h.chatProviderReady(w, r, p, sessionProvider(s)) {
		return
	}
	options := PromptOptions{Model: in.Model, Agent: in.Agent}
	if !validPromptOptions(options) {
		writeError(w, 400, "invalid_request", "Choose a valid model and agent mode")
		return
	}
	// Codex streaming: only Codex chats take a mode and effort so far.
	// Claude Code streaming: so do Claude chats the Claude engine runs.
	if in.Mode != "" || in.Effort != "" {
		claude := isClaudeSessionID(s.ID) && h.cliChats != nil && h.cliChats.claude != nil
		// ACP chats take a mode their agent lists (acp_chat.go checks it).
		acp := isACPSessionID(s.ID) && h.cliChats != nil
		if (!strings.HasPrefix(s.ID, "codex:") && !claude && !acp) || len(in.Mode) > 64 || len(in.Effort) > 64 {
			writeError(w, 400, "unsupported_options", "This agent does not take this mode or effort")
			return
		}
		options.Mode, options.Effort = in.Mode, in.Effort
	}
	// Claude Code streaming: starting a process and waiting for the prompt's
	// echo may outlast the listener's write timeout.
	if isClaudeSessionID(s.ID) {
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(claudeSendWait))
	}
	device, authenticated := h.authenticate(r)
	// A repeated clientMessageId gets the first receipt and is never sent
	// again. Only an attempt that definitely did not deliver lets a repeat send.
	var reservation *receiptEntry
	key := receiptKey{device.ID, p.ID, s.ID, in.ClientMessageID}
	for in.ClientMessageID != "" && reservation == nil {
		entry, repeat := h.receipts.reserve(key)
		if !repeat {
			reservation = entry
		} else if !h.awaitReceipt(r.Context(), w, entry) {
			return
		}
	}
	var files []ChatAttachment
	if len(in.Attachments) > 0 {
		var err error
		if !authenticated || h.attachments == nil {
			err = errAttachmentInvalid
		} else {
			files, err = h.attachments.claim(in.Attachments, p.ID, s.ID, device.ID)
		}
		if err != nil {
			if reservation != nil {
				h.receipts.settle(key, reservation, receiptForgotten, sendReceipt{})
			}
			writeError(w, 400, "invalid_attachment", "Upload each attachment to this chat from this device, then send it within 24 hours")
			return
		}
	}
	unlock := h.lockSession(p.ID, s.ID)
	// Messages already queued for this chat must also wait until the agent
	// has recorded this prompt and replied (for example after an edit).
	baseline := -1
	if h.queue != nil && h.queue.count(sessionKey{p.ID, s.ID}) > 0 {
		if items, err := h.transcript(p, s); err == nil {
			baseline = len(items)
		}
	}
	messageID, err := h.deliverPrompt(p, s, in.Text, options, files)
	if err == nil && baseline >= 0 {
		h.queue.settle(sessionKey{p.ID, s.ID}, baseline)
	}
	unlock()
	if err != nil {
		if reservation != nil {
			state := receiptUncertain
			if deliveryDefinitelyFailed(s, err) {
				state = receiptForgotten
			}
			h.receipts.settle(key, reservation, state, sendReceipt{})
		}
		promptFailure(w, err)
		return
	}
	receipt := sendReceipt{Accepted: true, MessageID: messageID, TurnID: messageID}
	if reservation != nil {
		h.receipts.settle(key, reservation, receiptAccepted, receipt)
	}
	writeJSON(w, 202, receipt)
}

// deliverPrompt is the single send path for direct and queued prompts. It
// returns the user message's ID when the provider knows it. Claimed
// attachments return to the sender only when the agent cannot have received
// the prompt; after an uncertain failure they are discarded, never resent.
func (h *Host) deliverPrompt(p Project, s Session, text string, options PromptOptions, files []ChatAttachment) (string, error) {
	provider := h.chatProviderFor(s)
	if provider == nil {
		return "", ErrCLIChatUnavailable
	}
	prompt := chatPrompt{text: text, options: options, files: files}
	// Archive (M1 chunk B2, archive_chat_capture.go): the user message and its
	// attachments are archived and flushed before the provider sees them,
	// and a continued chat's first prompt carries its seed.
	delivery := h.prepareDelivery(p, s, provider, &prompt)
	if isCLISessionID(s.ID) {
		if len(files) > 0 {
			prompt.finished = func() { h.attachments.remove(files) }
		}
		id, err := provider.send(p, s, prompt)
		if len(files) > 0 {
			// Claude Code streaming: after an uncertain send the run may still
			// read the files; finished removes them, and they are never resent.
			if err != nil && !errors.Is(err, errDeliveryUncertain) {
				h.attachments.release(files)
			} else {
				h.attachments.retain(files)
			}
		}
		h.finishDelivery(delivery, id, err, deliveryDefinitelyFailed(s, err))
		// Chat names (chat_title.go): a delivered message may name the chat.
		if err == nil {
			h.autoName(p, s.ID, text, id)
		}
		return id, err
	}
	id, err := provider.send(p, s, prompt)
	if len(files) > 0 {
		if err != nil && promptNotDelivered(err) {
			h.attachments.release(files)
		} else {
			h.attachments.remove(files)
		}
	}
	h.finishDelivery(delivery, id, err, deliveryDefinitelyFailed(s, err))
	if err == nil {
		h.autoName(p, s.ID, text, id)
	}
	return id, err
}

// promptNotDelivered reports failures after which OpenCode cannot have
// accepted the prompt: it answered with an error, or it was never contacted.
func promptNotDelivered(err error) bool {
	var status openCodeStatusError
	var network *net.OpError
	return errors.Is(err, errPromptNotSent) || errors.Is(err, ErrNotFound) || errors.As(err, &status) || (errors.As(err, &network) && network.Op == "dial")
}

func promptFailure(w http.ResponseWriter, err error) {
	switch {
	// Plain chats (plain_chats.go): the chat agent is not confirmed.
	case errors.Is(err, errPlainChatUnavailable):
		writePlainChatUnavailable(w, err)
	// The Chats space's Claude Code and Codex chats are read-only.
	case errors.Is(err, errChatsSpaceRetired):
		writeChatsSpaceRetired(w)
	// Chat runs on the Claude subscription (chat_subscription.go).
	case errors.Is(err, errClaudeSubscription):
		writeSubscriptionRequired(w, "Claude Code reported an API key, so nothing was sent: Chat uses only your Claude subscription. "+claudeSubscriptionMessage)
	case errors.Is(err, errClaudeSubscriptionStopped):
		writeErrorWith(w, 502, "agent_auth_required", "Claude Code reported an API key, so AgentLand stopped it before it replied: Chat uses only your Claude subscription. "+claudeSubscriptionMessage, nil)
	// Claude Code streaming (claude_engine.go).
	case errors.Is(err, errClaudeCapacity):
		writeError(w, 429, "agent_capacity", "Too many Claude Code chats are working; try again when one finishes")
	case errors.Is(err, errClaudeRewindRefused):
		writeError(w, 409, "rewind_refused", "Claude Code could not drop the hidden messages; restore them and send again")
	case errors.Is(err, errClaudeFilesNotRewound):
		writeError(w, 502, "files_not_restored", "Claude Code could not put the files back; nothing was sent")
	case errors.Is(err, errDeliveryUncertain):
		writeError(w, 502, "delivery_uncertain", "The agent may have received this message; check the chat before sending it again")
	// ACP chats (acp_chat.go): the chat's agent is not installed or usable.
	case errors.Is(err, errACPUnavailable):
		writeError(w, 503, "agent_unavailable", "This agent is not installed or cannot run chats now")
	case errors.Is(err, ErrCLIChatBusy):
		writeError(w, 409, "agent_busy", "The Mac agent is still working")
	case errors.Is(err, ErrCLIChatUnavailable):
		writeError(w, 400, "invalid_agent_options", "Choose settings supported by this Mac agent")
	case errors.Is(err, errOptionsUnsupported):
		writeError(w, 400, "unsupported_options", "This host does not support model overrides")
	case errors.Is(err, errAttachmentsUnsupported):
		writeError(w, 400, "unsupported_operation", "This agent does not accept attachments")
	case errors.Is(err, errAttachmentUnreadable):
		writeError(w, 400, "invalid_attachment", "An attachment is no longer readable on the host; attach it again")
	default:
		internal(w)
	}
}
func (h *Host) abort(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
	}
	if !decode(w, r, &in) {
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	provider := h.chatProviderFor(s)
	if provider == nil {
		notFound(w)
		return
	}
	h.chat.interrupted(sessionKey{p.ID, s.ID})
	if err := provider.interrupt(p, s.ID); err != nil {
		internal(w)
		return
	}
	writeJSON(w, 200, map[string]bool{"aborted": true})
}
func decode(w http.ResponseWriter, r *http.Request, out any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBody)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(out); err != nil {
		writeError(w, 400, "invalid_request", "Invalid JSON request")
		return false
	}
	var extra any
	if err := d.Decode(&extra); !errors.Is(err, io.EOF) {
		writeError(w, 400, "invalid_request", "Only one JSON value is allowed")
		return false
	}
	return true
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}
func notFound(w http.ResponseWriter) { writeError(w, 404, "not_found", "Project or session not found") }
func internal(w http.ResponseWriter) {
	writeError(w, 502, "upstream_error", "The local agent did not complete the request")
}
