package host

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Plain chats (docs/HOST-API.md "Plain chats"): AI chats outside every
// workspace, in the Chats space, a reserved project whose folder is the host's
// private <state>.chat-home. OpenCode runs them with AgentLand's chat agent,
// which the host writes into that folder's own opencode.json, never into the
// Mac's global OpenCode configuration: every tool is denied for the folder,
// and the agent may use only OpenCode's web search, the host's tool server
// (agentland-host chat-tools: agentland_fetch and the memory tools) and
// OpenCode's invalid tool. Each plain chat is created with the same rules.
//
// The space is a project on the chat routes only. They resolve projects with
// chatProject; every other route uses project, which knows only the
// configured workspaces, so a route that is not changed refuses the space.
//
// plainChatsCapability is listed while OpenCode's GET /agent for the folder
// lists the chat agent with AgentLand's prompt; the host checks it at start,
// every minute while it holds and every 10 seconds while it does not. Nothing
// is sent to a plain chat until then. The pulse names the capability's
// revision, so devices read capabilities again when it changes.
//
// OpenCode reads a folder's configuration when it makes its instance for the
// folder and keeps it: a configuration the host replaced (at start too, after
// an update) takes effect once OpenCode is asked to dispose of the instance,
// and so does one an instance made earlier never read (the chat agent missing
// or with another prompt, asked at most every 10 minutes). A tool server that
// failed or closed is connected again, at most once a minute. Those intervals
// start when OpenCode answered; a request it did not answer (no answer before
// the check's deadline, a lost connection or a server error) is made again
// after 15 seconds.

// PlainChatOptions turns plain chats on (serve always does).
type PlainChatOptions struct {
	// Executable is the agentland-host program OpenCode starts as the plain
	// chats' tool server: <Executable> chat-tools --state <state>.
	Executable string
	// Home is the Mac user's home folder, which instructionFiles shows as
	// "~"; empty means this process's.
	Home string
	// SearchProvider names the service OpenCode's websearch sends queries to
	// ("exa"), when the host knows it: the Mac app runs its managed OpenCode
	// with that provider set and says so (serve --websearch-provider).
	// Capabilities list it only then.
	SearchProvider string
	// OpenCode lets OpenCode's chat agent run general Chat too, on the API
	// keys of the Mac's AI Providers (serve --opencode-chat). Off by default:
	// Chat runs on the Claude and ChatGPT subscriptions alone (owner's
	// decision, 2026-10-12, chat_subscription.go). Off, the host never asks
	// OpenCode about the Chats space, lists no OpenCode provider and sends
	// nothing to an OpenCode plain chat; saved ones stay readable.
	OpenCode bool
}

const (
	// plainChatProbeEvery and plainChatRetryEvery pace the check of the chat
	// agent while it holds and while it does not; plainChatProbeWait bounds
	// one check and plainChatSendWait the check a send makes first.
	plainChatProbeEvery = time.Minute
	plainChatRetryEvery = 10 * time.Second
	plainChatProbeWait  = 15 * time.Second
	plainChatSendWait   = 5 * time.Second
	// plainChatReloadEvery paces the reloads for an instance that lacks the
	// chat agent, plainChatReconnectEvery the reconnections of the tool
	// server, once OpenCode answered one; plainChatFailedWait paces both
	// after one OpenCode did not answer (no answer before the check's
	// deadline, a lost connection or a server error).
	plainChatReloadEvery    = 10 * time.Minute
	plainChatReconnectEvery = time.Minute
	plainChatFailedWait     = 15 * time.Second
	// The chat agent's step limit, and the tool server's request timeout in
	// milliseconds (fetch takes at most 30 s).
	plainChatSteps       = 12
	plainChatToolTimeout = 120000
	// plainChatServer is the tool server's name in OpenCode's mcp settings;
	// OpenCode names its tools agentland_<tool>.
	plainChatServer = "agentland"
	// plainChatConfigName is the folder's own OpenCode configuration.
	plainChatConfigName = "opencode.json"
)

// plainChatPersona is the chat agent's prompt, which takes the place of
// OpenCode's coding prompt.
const plainChatPersona = `You are AgentLand's assistant, a general-purpose AI assistant that people chat with in the AgentLand app. Answer clearly and directly, in the language the user writes in, and say so when you are not sure.

You can search the web with websearch and read a web page with agentland_fetch. When an answer uses what you found, cite each source as a link to the page. You also keep a small memory about the user that lasts across chats: agentland_memory_save adds one short fact and agentland_memory_forget removes one. Save only what the user asks you to remember or clearly wants kept, and never passwords, keys or other secrets.

You cannot run commands, read or change files on this computer, or see anything the user did not share in the chat.`

// plainChatAllowed are the tools the chat agent may use, each by its exact
// key: OpenCode's invalid (it reports a malformed tool call), its web search
// and the tool server's three.
var plainChatAllowed = []string{"invalid", chatToolWebsearch, chatToolFetch, chatToolMemorySave, chatToolMemoryForget}

var errPlainChatUnavailable = fmt.Errorf("plain chats are not available: %w", errPromptNotSent)

// errOpenCodeChatOff: OpenCode does not run general Chat on this host
// (PlainChatOptions.OpenCode).
var errOpenCodeChatOff = fmt.Errorf("OpenCode does not run Chat on this host: %w", errPlainChatUnavailable)

// ocPermissionRule is one rule of OpenCode 1.18.31's permission rule list,
// as a session carries it and GET /agent lists an agent's.
type ocPermissionRule struct {
	Permission string `json:"permission"`
	Pattern    string `json:"pattern"`
	Action     string `json:"action"`
}

// plainChatRules is the rule list every plain chat is created with.
// OpenCode applies the last rule that matches, so "*" is denied first.
func plainChatRules() []ocPermissionRule {
	rules := []ocPermissionRule{{Permission: "*", Pattern: "*", Action: "deny"}}
	for _, tool := range plainChatAllowed {
		rules = append(rules, ocPermissionRule{Permission: tool, Pattern: "*", Action: "allow"})
	}
	return rules
}

// orderedPermission encodes as an OpenCode permission object whose keys keep
// their order: OpenCode keeps a configuration's key order and applies the
// last rule that matches.
type orderedPermission [][2]string

func (p orderedPermission) MarshalJSON() ([]byte, error) {
	var out []byte
	out = append(out, '{')
	for index, rule := range p {
		if index > 0 {
			out = append(out, ',')
		}
		key, _ := json.Marshal(rule[0])
		value, _ := json.Marshal(rule[1])
		out = append(append(append(out, key...), ':'), value...)
	}
	return append(out, '}'), nil
}

// plainChatConfigSchema is the "$schema" OpenCode 1.18.31 writes into a
// configuration file without one when it loads it.
const plainChatConfigSchema = "https://opencode.ai/config.json"

// plainChatConfig is the Chats space's opencode.json, in the shapes of
// OpenCode 1.18.31 (packages/core/src/v1/config: config.ts, agent.ts,
// permission.ts, mcp.ts). The password of this Mac's OpenCode service is
// blanked for the tool server, which OpenCode starts with its own
// environment. It names OpenCode's schema itself: OpenCode adds the
// "$schema" to a file without one as it loads it, and the host then found the
// file changed at every check and had OpenCode dispose of the folder's
// instance, which stopped every plain-chat turn running then (B-15).
func plainChatConfig(executable, statePath string) []byte {
	deny := orderedPermission{{"*", "deny"}}
	agent := slices.Clone(deny)
	for _, tool := range plainChatAllowed {
		agent = append(agent, [2]string{tool, "allow"})
	}
	type mcpServer struct {
		Type        string            `json:"type"`
		Command     []string          `json:"command"`
		Environment map[string]string `json:"environment"`
		Timeout     int               `json:"timeout"`
	}
	type chatAgent struct {
		Mode       string            `json:"mode"`
		Steps      int               `json:"steps"`
		Prompt     string            `json:"prompt"`
		Permission orderedPermission `json:"permission"`
	}
	config := struct {
		Schema       string            `json:"$schema"`
		DefaultAgent string            `json:"default_agent"`
		Permission   orderedPermission `json:"permission"`
		Agent        struct {
			Chat chatAgent `json:"chat"`
		} `json:"agent"`
		MCP struct {
			AgentLand mcpServer `json:"agentland"`
		} `json:"mcp"`
	}{Schema: plainChatConfigSchema, DefaultAgent: plainChatAgent, Permission: deny}
	config.Agent.Chat = chatAgent{Mode: "primary", Steps: plainChatSteps, Prompt: plainChatPersona, Permission: agent}
	config.MCP.AgentLand = mcpServer{Type: "local", Command: []string{executable, "chat-tools", "--state", statePath},
		Environment: map[string]string{"OPENCODE_SERVER_PASSWORD": ""}, Timeout: plainChatToolTimeout}
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		panic(err)
	}
	return append(data, '\n')
}

// plainChats is the Chats space of a host with plain chats.
type plainChats struct {
	// The Claude Code and Codex providers (plain_chat_providers.go): the
	// last check's lists, under mu, of those that can run Chat and those
	// whose sign-in is not a subscription (chat_subscription.go);
	// providersMu serializes the checks and guards versions and auths, each
	// runtime's last answered version and sign-in checks.
	cliProviders         []plainChatProvider
	unavailableProviders []plainChatProvider
	providersMu          sync.Mutex
	versions             map[string]plainVersionCheck
	auths                map[string]plainAuthCheck
	// forceAuth: the check under way is the Mac app's explicit one, which
	// asks every CLI again; lastExplicitCheck is when the last one ended.
	// Both under providersMu.
	forceAuth         bool
	lastExplicitCheck time.Time
	// openCode: OpenCode's chat agent may run general Chat
	// (PlainChatOptions.OpenCode).
	openCode       atomic.Bool
	host           *Host
	home           string // <state>.chat-home
	statePath      string
	executable     string
	userHome       string
	searchProvider string

	// Memory (memory.go): the store, nil when it could not open, and the
	// tool server's socket, nil when it could not be bound.
	memory *memoryStore
	socket *memorySocket

	mu           sync.Mutex
	confirmed    bool
	everSeen     bool // confirmed at least once since the host started
	tools        []string
	instructions []string
	scanned      bool
	probing      chan struct{} // closed when the check in progress ends
	lastProblem  string
	started      bool
	// reloadPending: the configuration was replaced and OpenCode has not
	// disposed of its instance for the folder since. reloads and reconnects
	// pace the disposals of that instance and the tool server's
	// reconnections, by the clock now.
	reloadPending bool
	reloads       plainChatPace
	reconnects    plainChatPace
	now           func() time.Time
	// The capability's revision, and the channel closed when it changes
	// (the pulse).
	revision string
	changed  chan struct{}

	every, retry time.Duration
	stop         chan struct{}
	done         chan struct{}
	stopOnce     sync.Once
}

func newPlainChats(h *Host, statePath string, options PlainChatOptions) *plainChats {
	c := &plainChats{host: h, home: statePath + ".chat-home", statePath: statePath, executable: options.Executable, userHome: options.Home,
		searchProvider: options.SearchProvider, changed: make(chan struct{}), now: time.Now,
		every: plainChatProbeEvery, retry: plainChatRetryEvery, stop: make(chan struct{}), done: make(chan struct{})}
	c.openCode.Store(options.OpenCode)
	c.revision = plainChatsRevision(c.capabilityLocked(), c.workspaceLocked())
	if absolute, err := filepath.Abs(c.home); err == nil {
		c.home = absolute
	}
	if absolute, err := filepath.Abs(c.statePath); err == nil {
		c.statePath = absolute
	}
	if c.userHome == "" {
		c.userHome, _ = os.UserHomeDir()
	}
	// The folder and its configuration are ready before anything asks
	// OpenCode about the space (the archive's backfill included). A
	// configuration replaced now (a host update) reaches OpenCode's instance
	// for the folder at the first check.
	replaced, err := c.ensureHome()
	if err != nil {
		log.Printf("plain chats: the Chats space's folder could not be prepared: %v", err)
	}
	c.reloadPending = replaced
	memory, err := openMemoryStore(statePath + ".memory.json")
	if err != nil {
		log.Printf("plain chats: memory is unavailable: %v", err)
	} else {
		c.memory = memory
		if c.socket, err = listenMemorySocket(memorySocketPath(statePath), memory); err != nil {
			log.Printf("plain chats: the memory tools are unavailable: %v", err)
		}
	}
	return c
}

// project is the Chats space as a project of the chat routes.
func (c *plainChats) project() Project {
	return Project{ID: plainChatsProjectID, Name: plainChatsProjectName, Directory: c.home}
}

// isSpace reports whether p is this host's Chats space. A nil space has none.
func (c *plainChats) isSpace(p Project) bool {
	return c != nil && p.ID == plainChatsProjectID && p.Directory == c.home
}

// start checks the chat agent now and then on its pace, until close.
func (c *plainChats) start() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.started = true
	c.mu.Unlock()
	go func() {
		defer close(c.done)
		wait := time.Duration(0)
		for {
			timer := time.NewTimer(wait)
			select {
			case <-c.stop:
				timer.Stop()
				return
			case <-timer.C:
			}
			ctx, cancel := context.WithTimeout(context.Background(), plainChatProbeWait)
			go func() {
				select {
				case <-c.stop:
					cancel()
				case <-ctx.Done():
				}
			}()
			c.refreshProviders(ctx)
			openCode := c.openCode.Load()
			confirmed := openCode && c.refresh(ctx)
			cancel()
			wait = c.retry
			if confirmed || !openCode {
				wait = c.every
			}
		}
	}()
}

// close stops the checks and the memory socket.
func (c *plainChats) close() {
	if c == nil {
		return
	}
	c.stopOnce.Do(func() {
		c.mu.Lock()
		started := c.started
		c.mu.Unlock()
		close(c.stop)
		if started {
			<-c.done
		}
	})
	c.socket.close()
}

// confirmedNow reports the last check's answer.
func (c *plainChats) confirmedNow() bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.confirmed
}

// ready reports whether plain chats may be sent to: the last check confirmed
// the chat agent or, when it did not, a check made now does.
func (c *plainChats) ready(ctx context.Context) bool {
	if c == nil {
		return false
	}
	if c.confirmedNow() {
		return true
	}
	ctx, cancel := context.WithTimeout(ctx, plainChatSendWait)
	defer cancel()
	return c.refresh(ctx)
}

// capability is capabilities.generalChats. Since Chat runs Claude Code and
// Codex in the workspaces (workspaceCapability, owner 2026-10-12), general
// Chat lists OpenCode alone, while the host runs it in Chat
// (--opencode-chat), and otherwise no provider: providers is then [], which
// clients read as no Chat in the Chats space, never as legacy OpenCode-only
// Chat (a missing list). The space's saved chats stay listed and readable.
func (c *plainChats) capability() *plainChatsCapability {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.capabilityLocked()
}

// legacyCapability is capabilities.plainChats, nil while OpenCode's chat
// agent is not confirmed. Clients from before the provider list read its
// presence alone as "OpenCode runs plain chats" and send every chat there,
// so Claude Code or Codex alone never lists it.
func (c *plainChats) legacyCapability() *plainChatsCapability {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.confirmed {
		return nil
	}
	return c.capabilityLocked()
}

func (c *plainChats) capabilityLocked() *plainChatsCapability {
	result := &plainChatsCapability{ProjectID: plainChatsProjectID, Tools: slices.Clone(c.tools), Providers: []plainChatProvider{}}
	if !c.confirmed || result.Tools == nil {
		result.Tools = []string{}
	}
	if !c.confirmed {
		return result
	}
	// OpenCode in Chat runs on the AI Providers' API keys.
	result.Providers = append(result.Providers, plainChatProvider{ID: "opencode", Name: "OpenCode", Tools: slices.Clone(result.Tools), Features: []string{"events", "parts", "stop", "clientMessageId", "title", "attachments", "rewind", "regenerate", "queue"},
		Auth: &plainChatAuth{Kind: plainAuthAPIKey, Label: "API keys"}})
	if slices.Contains(c.tools, plainChatToolWebsearch) {
		result.SearchProvider = c.searchProvider
	}
	if len(c.instructions) > 0 {
		result.InstructionFiles = slices.Clone(c.instructions)
	}
	return result
}

// workspaceCapability is capabilities.workspaceChats: Claude Code and Codex
// as the last check of the sign-ins found them, independent of OpenCode.
// Nil on a host without Claude Code and Codex chats.
func (c *plainChats) workspaceCapability() *workspaceChatsCapability {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.workspaceLocked()
}

func (c *plainChats) workspaceLocked() *workspaceChatsCapability {
	if c.host == nil || c.host.cliChats == nil {
		return nil
	}
	result := &workspaceChatsCapability{Version: workspaceChatsVersion, Providers: []plainChatProvider{}, UnavailableProviders: []plainChatProvider{}}
	for _, entry := range c.cliProviders {
		result.Providers = append(result.Providers, workspaceChatProvider(entry, true))
	}
	for _, entry := range c.unavailableProviders {
		result.UnavailableProviders = append(result.UnavailableProviders, workspaceChatProvider(entry, false))
	}
	return result
}

// plainChatsRevision names capabilities.generalChats and workspaceChats
// (each nil when absent) for the pulse's plainChats line, so devices read
// capabilities again when either changes.
func plainChatsRevision(general *plainChatsCapability, workspace *workspaceChatsCapability) string {
	data, _ := json.Marshal([]any{general, workspace})
	digest := sha256.Sum256(append([]byte("agentland-plain-chats/2\n"), data...))
	return hex.EncodeToString(digest[:])[:32]
}

// capabilityState is the capability's revision and the channel closed when
// it changes (the pulse).
func (c *plainChats) capabilityState() (string, <-chan struct{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.revision, c.changed
}

// seenOnce reports whether the chat agent was confirmed at least once since
// the host started.
func (c *plainChats) seenOnce() bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.everSeen
}

// memorySystem is the system text a plain-chat prompt carries: the memory's
// entries while it is on and the capability lists memory, so the model can
// forget what it is shown; nothing otherwise.
func (c *plainChats) memorySystem() string {
	if c == nil || c.memory == nil {
		return ""
	}
	c.mu.Lock()
	listed := c.confirmed && slices.Contains(c.tools, plainChatToolMemory)
	c.mu.Unlock()
	if !listed {
		return ""
	}
	return c.memory.systemText()
}

// refresh checks the chat agent once; a check already running is waited for
// instead. It reports whether the agent is confirmed, never while OpenCode
// does not run general Chat.
func (c *plainChats) refresh(ctx context.Context) bool {
	if !c.openCode.Load() {
		return false
	}
	c.mu.Lock()
	if running := c.probing; running != nil {
		c.mu.Unlock()
		select {
		case <-running:
		case <-ctx.Done():
		}
		return c.confirmedNow()
	}
	running := make(chan struct{})
	c.probing = running
	c.mu.Unlock()
	result := c.probe(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.probing = nil
	close(running)
	if result.problem != "" && result.problem != c.lastProblem {
		log.Printf("plain chats: %s", result.problem)
	}
	c.lastProblem = result.problem
	c.confirmed, c.tools = result.confirmed, result.tools
	c.everSeen = c.everSeen || result.confirmed
	if result.scanned && !c.scanned {
		c.scanned, c.instructions = true, result.instructions
		for _, file := range result.instructions {
			log.Printf("plain chats: OpenCode adds the instruction file %s to plain chats", file)
		}
	}
	c.publishLocked()
	return c.confirmed
}

// refreshProviders checks the Claude Code and Codex runtimes and publishes
// the ones that can run Chat in the workspaces now. It is separate from
// refresh, so a send waiting for OpenCode never waits for these checks.
func (c *plainChats) refreshProviders(ctx context.Context) []plainChatProvider {
	c.providersMu.Lock()
	defer c.providersMu.Unlock()
	return c.refreshProvidersLocked(ctx)
}

// checkProvidersNow is the Mac app's explicit check of the sign-ins
// (POST /v1/chat/providers/check): refreshProviders, but asking each CLI
// again whatever its last answer's age, so a sign-in made a moment ago
// shows at once. Explicit checks are spaced plainAuthCheckEvery apart: one
// that comes sooner asks nothing and leaves the last check's lists, at most
// that old. It reports whether it asked. The minute-paced checks are not
// changed.
func (c *plainChats) checkProvidersNow(ctx context.Context) bool {
	c.providersMu.Lock()
	defer c.providersMu.Unlock()
	if since := c.clock().Sub(c.lastExplicitCheck); !c.lastExplicitCheck.IsZero() && since >= 0 && since < plainAuthCheckEvery {
		return false
	}
	c.forceAuth = true
	c.refreshProvidersLocked(ctx)
	c.forceAuth = false
	c.lastExplicitCheck = c.clock()
	return true
}

func (c *plainChats) refreshProvidersLocked(ctx context.Context) []plainChatProvider {
	providers, unavailable := c.host.plainCLIProviders(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cliProviders, c.unavailableProviders = providers, unavailable
	c.publishLocked()
	return slices.Clone(providers)
}

// unavailableProvider is the provider the last check found installed but not
// signed in with a subscription, if it is one.
func (c *plainChats) unavailableProvider(id string) (plainChatProvider, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	index := slices.IndexFunc(c.unavailableProviders, func(entry plainChatProvider) bool { return entry.ID == id })
	if index < 0 {
		return plainChatProvider{}, false
	}
	return c.unavailableProviders[index], true
}

// unavailableErr is why nothing is sent to an OpenCode plain chat now.
func (c *plainChats) unavailableErr() error {
	if c != nil && !c.openCode.Load() {
		return errOpenCodeChatOff
	}
	return errPlainChatUnavailable
}

// publishLocked gives the pulse a new revision when the capability changed.
func (c *plainChats) publishLocked() {
	if revision := plainChatsRevision(c.capabilityLocked(), c.workspaceLocked()); revision != c.revision {
		c.revision = revision
		close(c.changed)
		c.changed = make(chan struct{})
	}
}

type plainChatProbe struct {
	confirmed    bool
	tools        []string
	scanned      bool
	instructions []string
	problem      string
}

// probe writes the folder's configuration when it differs, then asks
// OpenCode for the chat agent, the tool server and web search.
func (c *plainChats) probe(ctx context.Context) plainChatProbe {
	replaced, err := c.ensureHome()
	if err != nil {
		return plainChatProbe{problem: "the Chats space's folder could not be prepared: " + err.Error()}
	}
	adapter, ok := c.host.agent.(*OpenCodeAdapter)
	if !ok {
		return plainChatProbe{problem: "this host's agent is not OpenCode"}
	}
	p := c.project()
	c.mu.Lock()
	c.reloadPending = c.reloadPending || replaced
	pending := c.reloadPending
	c.mu.Unlock()
	// A replaced configuration is loaded whenever the last reload was, and
	// asked for again after a failure until OpenCode answers.
	if pending && c.mayAsk(&c.reloads, 0) {
		if _, answered := c.reload(ctx, adapter, p); answered {
			c.mu.Lock()
			c.reloadPending = false
			c.mu.Unlock()
		}
	}
	listed, err := c.chatAgentListed(ctx, adapter, p)
	if err != nil {
		return plainChatProbe{problem: "OpenCode did not list its agents for the Chats space: " + err.Error()}
	}
	if !listed && c.mayAsk(&c.reloads, plainChatReloadEvery) {
		// An instance made before the host wrote this configuration.
		if done, _ := c.reload(ctx, adapter, p); done {
			if listed, err = c.chatAgentListed(ctx, adapter, p); err != nil {
				return plainChatProbe{problem: "OpenCode did not list its agents for the Chats space: " + err.Error()}
			}
		}
	}
	if !listed {
		return plainChatProbe{problem: "OpenCode does not have AgentLand's chat agent in the Chats space"}
	}
	result := plainChatProbe{confirmed: true, tools: []string{}}
	if c.searchWorks(ctx, adapter, p) {
		result.tools = append(result.tools, plainChatToolWebsearch)
	}
	connected := c.toolServerConnected(ctx, adapter, p)
	if !connected && c.mayAsk(&c.reconnects, plainChatReconnectEvery) {
		// OpenCode does not start a tool server that failed or closed again
		// by itself; it connects it anew from the folder's configuration.
		query := "/mcp/" + plainChatServer + "/connect?" + url.Values{"directory": {p.Directory}}.Encode()
		err := adapter.getContext(ctx, "POST", query, p, nil, 1<<10)
		c.asked(&c.reconnects, openCodeAnswered(err))
		if err == nil {
			connected = c.toolServerConnected(ctx, adapter, p)
		}
	}
	if connected {
		result.tools = append(result.tools, plainChatToolFetch)
		if c.memory != nil && c.socket != nil {
			result.tools = append(result.tools, plainChatToolMemory)
		}
	} else {
		result.problem = "OpenCode has not connected AgentLand's tool server in the Chats space"
	}
	c.mu.Lock()
	scanned := c.scanned
	c.mu.Unlock()
	if !scanned {
		var paths struct {
			Home, Config, Worktree string
		}
		if adapter.getContext(ctx, "GET", "/path", p, &paths, 1<<20) == nil {
			result.scanned = true
			result.instructions = scanPlainChatInstructions(c.home, paths.Worktree, paths.Home, paths.Config, c.userHome)
		}
	}
	return result
}

// reload asks OpenCode to dispose of its instance for the Chats space, so
// the next request makes it again from the folder's configuration. It reports
// whether OpenCode did it, and whether OpenCode answered (reloads' pace).
func (c *plainChats) reload(ctx context.Context, adapter *OpenCodeAdapter, p Project) (done, answered bool) {
	query := "/instance/dispose?" + url.Values{"directory": {p.Directory}}.Encode()
	err := adapter.getContext(ctx, "POST", query, p, nil, 1<<10)
	answered = openCodeAnswered(err)
	c.asked(&c.reloads, answered)
	return err == nil, answered
}

// plainChatPace spaces out one kind of request to OpenCode. Once OpenCode
// answered one, the next waits its interval; after one OpenCode did not
// answer, only plainChatFailedWait, so a request lost to a check's deadline
// or a server error never holds plain chats back for long.
type plainChatPace struct {
	answered, failed time.Time
}

// mayAsk reports whether a request paced by pace may go now: every after
// OpenCode's last answer, plainChatFailedWait after the last failure.
func (c *plainChats) mayAsk(pace *plainChatPace, every time.Duration) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	return (pace.answered.IsZero() || now.Sub(pace.answered) >= every) &&
		(pace.failed.IsZero() || now.Sub(pace.failed) >= plainChatFailedWait)
}

// asked records whether OpenCode answered a paced request.
func (c *plainChats) asked(pace *plainChatPace, answered bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if answered {
		pace.answered = c.now()
	} else {
		pace.failed = c.now()
	}
}

// openCodeAnswered reports whether a request got OpenCode's answer: a
// success, or a refusal (4xx), which asking again soon would not change. No
// answer before the deadline, a lost connection or a server error (5xx) is
// no answer.
func openCodeAnswered(err error) bool {
	var status openCodeStatusError
	switch {
	case err == nil, errors.Is(err, ErrNotFound):
		return true
	case errors.As(err, &status):
		return status.status >= 400 && status.status < 500
	}
	return false
}

// chatAgentListed reports whether OpenCode lists the chat agent with
// AgentLand's prompt for the Chats space.
func (c *plainChats) chatAgentListed(ctx context.Context, adapter *OpenCodeAdapter, p Project) (bool, error) {
	var agents []struct {
		Name   string `json:"name"`
		Prompt string `json:"prompt"`
	}
	if err := adapter.getContext(ctx, "GET", "/agent", p, &agents, 8<<20); err != nil {
		return false, err
	}
	for _, agent := range agents {
		if agent.Name == plainChatAgent && agent.Prompt == plainChatPersona {
			return true, nil
		}
	}
	return false, nil
}

// toolServerConnected reports whether OpenCode has the tool server connected
// for the Chats space.
func (c *plainChats) toolServerConnected(ctx context.Context, adapter *OpenCodeAdapter, p Project) bool {
	var servers map[string]struct {
		Status string `json:"status"`
	}
	return adapter.getContext(ctx, "GET", "/mcp", p, &servers, 1<<20) == nil && servers[plainChatServer].Status == "connected"
}

// searchWorks reports whether OpenCode gives the chat agent websearch: it
// does for every model while Exa's (or Parallel's) search is on, which GET
// /experimental/tool shows for the Chats space's default model, or for a
// model of no provider when there is none.
func (c *plainChats) searchWorks(ctx context.Context, adapter *OpenCodeAdapter, p Project) bool {
	var config struct {
		Model string `json:"model"`
	}
	provider, model := "agentland", "probe"
	if adapter.getContext(ctx, "GET", "/config", p, &config, 2<<20) == nil {
		if prefix, rest, ok := strings.Cut(config.Model, "/"); ok && prefix != "" && rest != "" {
			provider, model = prefix, rest
		}
	}
	var tools []struct {
		ID string `json:"id"`
	}
	query := "/experimental/tool?" + url.Values{"provider": {provider}, "model": {model}}.Encode()
	if adapter.getContext(ctx, "GET", query, p, &tools, 8<<20) != nil {
		return false
	}
	return slices.ContainsFunc(tools, func(tool struct {
		ID string `json:"id"`
	}) bool {
		return tool.ID == plainChatToolWebsearch
	})
}

// ensureHome makes the Chats space's folder (0700) and writes its
// opencode.json when it holds anything else, atomically and 0600. It reports
// whether a configuration that was there was replaced.
func (c *plainChats) ensureHome() (bool, error) {
	info, err := os.Lstat(c.home)
	switch {
	case errors.Is(err, os.ErrNotExist):
		if err := os.Mkdir(c.home, 0700); err != nil {
			return false, err
		}
	case err != nil:
		return false, err
	case info.Mode()&os.ModeSymlink != 0 || !info.IsDir():
		return false, fmt.Errorf("%s is not a folder", c.home)
	}
	if err := os.Chmod(c.home, 0700); err != nil {
		return false, err
	}
	want := plainChatConfig(c.executable, c.statePath)
	path := filepath.Join(c.home, plainChatConfigName)
	current, err := readPrivateState(path)
	if err == nil && samePlainChatConfig(current, want) {
		return false, nil
	}
	existed := !errors.Is(err, os.ErrNotExist)
	if err := writePrivateState(path, want); err != nil {
		return false, err
	}
	return existed, nil
}

// samePlainChatConfig reports whether the folder's opencode.json says what
// the host wants: the same settings, whatever their layout or "$schema",
// which OpenCode may write itself. Within a setting the order counts, as it
// does for OpenCode's permission rules. Replacing a file that says the same
// would have OpenCode dispose of the folder's instance for nothing, stopping
// the plain-chat turns running then.
func samePlainChatConfig(current, want []byte) bool {
	var have, need map[string]json.RawMessage
	if json.Unmarshal(current, &have) != nil || json.Unmarshal(want, &need) != nil {
		return false
	}
	delete(have, "$schema")
	delete(need, "$schema")
	if len(have) != len(need) {
		return false
	}
	for key, value := range need {
		other, ok := have[key]
		if !ok {
			return false
		}
		a, okA := jsonTokens(value)
		b, okB := jsonTokens(other)
		if !okA || !okB || !reflect.DeepEqual(a, b) {
			return false
		}
	}
	return true
}

// jsonTokens is a JSON value's tokens in order, strings decoded, so two
// encodings of one value (spacing, escapes) compare equal.
func jsonTokens(data []byte) ([]any, bool) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var tokens []any
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return tokens, true
		}
		if err != nil {
			return nil, false
		}
		tokens = append(tokens, token)
	}
}

// scanPlainChatInstructions lists the instruction files OpenCode may add to a
// plain chat besides the chat agent's prompt: AGENTS.md, CLAUDE.md and
// CONTEXT.md in the Chats space's folder and every folder above it (up to
// OpenCode's worktree for it, the root for a folder outside Git),
// ~/.claude/CLAUDE.md and OpenCode's global AGENTS.md. Paths under the Mac
// user's home folder read "~/…".
func scanPlainChatInstructions(chatHome, worktree, openCodeHome, openCodeConfig, userHome string) []string {
	var found []string
	add := func(path string) {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			return
		}
		if shown, ok := plainChatInstructionPath(path, userHome); ok && !slices.Contains(found, shown) && len(found) < plainChatInstructionFiles {
			found = append(found, shown)
		}
	}
	stop := filepath.Clean(worktree)
	if worktree == "" || !strings.HasPrefix(chatHome, stop) {
		stop = ""
	}
	for folder := filepath.Clean(chatHome); ; {
		for _, name := range []string{"AGENTS.md", "CLAUDE.md", "CONTEXT.md"} {
			add(filepath.Join(folder, name))
		}
		parent := filepath.Dir(folder)
		if folder == stop || parent == folder {
			break
		}
		folder = parent
	}
	if openCodeHome != "" {
		add(filepath.Join(openCodeHome, ".claude", "CLAUDE.md"))
	}
	if openCodeConfig != "" {
		add(filepath.Join(openCodeConfig, "AGENTS.md"))
	}
	return found
}

// plainChatInstructionPath is path as instructionFiles shows it: "~/…" under
// the Mac user's home folder, absolute elsewhere; false when it is longer
// than the contract allows.
func plainChatInstructionPath(path, userHome string) (string, bool) {
	shown := path
	if userHome != "" {
		if relative, err := filepath.Rel(userHome, path); err == nil && relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			shown = "~/" + filepath.ToSlash(relative)
		}
	}
	return shown, len(shown) <= plainChatInstructionFileBytes
}

// Routes.

// chatProject resolves a project on the chat routes: a configured workspace,
// or the Chats space. Every other route uses project.
func (h *Host) chatProject(id string) (Project, error) {
	if h.plainChats != nil && subtle.ConstantTimeCompare([]byte(id), []byte(plainChatsProjectID)) == 1 {
		return h.plainChats.project(), nil
	}
	return h.project(id)
}

// chatScoped resolves a chat on the chat routes, in a workspace or the Chats
// space, answering 404 for an unknown project or chat.
func (h *Host) chatScoped(w http.ResponseWriter, projectID, sessionID string) (Project, Session, bool) {
	p, err := h.chatProject(projectID)
	if err != nil {
		notFound(w)
		return Project{}, Session{}, false
	}
	s, err := h.session(p, sessionID)
	if err != nil {
		notFound(w)
		return Project{}, Session{}, false
	}
	return p, s, true
}

// isPlainChat reports whether p is this host's Chats space.
func (h *Host) isPlainChat(p Project) bool { return h.plainChats.isSpace(p) }

// plainChatOptionsRefused answers 400 unsupported_options for a mode
// or OpenCode agent in the Chats space, where the chat agent always runs.
func plainChatOptionsRefused(w http.ResponseWriter, values ...string) bool {
	for _, value := range values {
		if value != "" {
			writeError(w, 400, "unsupported_options", "General chats take no coding mode or agent")
			return true
		}
	}
	return false
}

// plainChatReady answers 503 agent_unavailable while the chat agent is not
// confirmed: nothing is sent to a plain chat then.
func (h *Host) plainChatReady(w http.ResponseWriter, r *http.Request) bool {
	if h.plainChats.ready(r.Context()) {
		return true
	}
	writePlainChatUnavailable(w, h.plainChats.unavailableErr())
	return false
}

// writePlainChatUnavailable answers a request an OpenCode plain chat cannot
// take now: err says whether OpenCode runs Chat at all (errOpenCodeChatOff).
func writePlainChatUnavailable(w http.ResponseWriter, err error) {
	if errors.Is(err, errOpenCodeChatOff) {
		writeError(w, 503, "agent_unavailable", "Chat runs Claude Code and Codex on this Mac's Claude and ChatGPT subscriptions. OpenCode chats stay readable but take no new messages.")
		return
	}
	writeError(w, 503, "agent_unavailable", "Plain chats are unavailable: this Mac's OpenCode does not have AgentLand's chat agent now")
}

// plainChatProjects is the Chats space as a list, for the walks that cover
// every project (the archive's feed and backfill, OpenCode's activity); empty
// without plain chats.
func (h *Host) plainChatProjects() []Project {
	if h.plainChats == nil {
		return nil
	}
	return []Project{h.plainChats.project()}
}
