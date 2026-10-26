package host

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// chatProviderNames are what Chat calls its providers: Claude Code and Codex
// themselves (owner, 2026-10-12, "Claude Code & Codex", replacing the
// "Claude" and "ChatGPT" of earlier that day). Chats titled with any of the
// old names keep them as placeholders (chatPlaceholderTitles).
var chatProviderNames = map[string]string{"claude": "Claude Code", "codex": "Codex"}

type plainChatProvider struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Tools           []string `json:"tools"`
	Features        []string `json:"features"`
	AttachmentTypes []string `json:"attachmentTypes,omitempty"`
	// Auth is how the provider is signed in for Chat (chat_subscription.go).
	Auth *plainChatAuth `json:"auth,omitempty"`
}

func plainRuntimeVersion(ctx context.Context, executable string) string {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, executable, "--version").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(output))
	for _, field := range fields {
		if len(field) > 0 && field[0] >= '0' && field[0] <= '9' {
			return field
		}
	}
	return ""
}

// plainVersionCheck is the last answered version check of a runtime's
// executable, kept while the file is unchanged.
type plainVersionCheck struct {
	path      string
	modified  time.Time
	size      int64
	version   string
	supported bool
}

// runtimeSupported reports whether executable runs a version Chat supports
// (plainVersionSupported), and the version the answer is about ("" while no
// check has answered). It runs `--version` only when the file differs from
// the last answered check (an install or update). A check that does not
// answer (a cold start, a timeout, an update in progress) keeps the last
// answer and is tried again next time. Callers hold providersMu.
func (c *plainChats) runtimeSupported(ctx context.Context, id, executable string) (supported bool, version string) {
	check := plainVersionCheck{path: executable}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		check.path = resolved
	}
	if info, err := os.Stat(check.path); err == nil {
		check.modified, check.size = info.ModTime(), info.Size()
	}
	previous, known := c.versions[id]
	if known && !check.modified.IsZero() && previous.path == check.path && previous.modified.Equal(check.modified) && previous.size == check.size {
		return previous.supported, previous.version
	}
	version = plainRuntimeVersion(ctx, executable)
	if version == "" {
		if !known {
			return false, ""
		}
		return previous.supported, previous.version
	}
	check.version, check.supported = version, plainVersionSupported(id, version)
	if c.versions == nil {
		c.versions = map[string]plainVersionCheck{}
	}
	c.versions[id] = check
	return check.supported, check.version
}

// plainVersionSupported: the versions Chat's subscription-only checks
// (chat_subscription.go: the sign-in report, the account and API-key source
// Claude Code's initialize and init report, Codex's forced ChatGPT login)
// hold for: Claude Code 2.1.295 and every later 2.x release
// (claudeVersionFrom295), and Codex 0.162.0 and every later 0.x release
// (codexVersionFrom162). They were verified with Claude Code 2.1.296 and
// Codex 0.162.1 and, on 2026-10-16, 0.163.0 (the same sign-in report;
// forced_login_method a known setting that refuses an API-key login; an
// app-server protocol that only gained methods and fields). Later releases
// within the same major version are accepted without a new check (owner,
// 2026-10-16: "allow 0.162 and every later 0.x version, like Claude Code's
// rule"; 2026-10-17: "Accept Claude Code 2.1.295 and every later 2.x, the
// same rule you chose for Codex"); Claude Code 3.x, Codex 1.x and later,
// older versions and anything that does not parse are not. The gate came
// with the Chats space's conversation profile, retired on 2026-10-12, but
// now keeps untested CLIs out of "Subscriptions only"; an installed CLI it
// refuses is listed as unavailable with why (plainVersionAuth).
func plainVersionSupported(provider, version string) bool {
	if provider == "codex" {
		return codexVersionFrom162(version)
	}
	if provider == "claude" {
		return claudeVersionFrom295(version)
	}
	return false
}

// claudeVersionFrom295 reports whether version is Claude Code 2.1.295 or a
// later 2.x release: "2.<minor>.<patch>" in decimal digits, minor 1 with
// patch 295 or more, or minor 2 or more.
func claudeVersionFrom295(version string) bool {
	rest, ok := strings.CutPrefix(version, "2.")
	if !ok {
		return false
	}
	minor, patch, ok := strings.Cut(rest, ".")
	if !ok || !plainDecimal(minor) || !plainDecimal(patch) {
		return false
	}
	minorNumber, minorErr := strconv.Atoi(minor)
	patchNumber, patchErr := strconv.Atoi(patch)
	return minorErr == nil && patchErr == nil && (minorNumber > 1 || minorNumber == 1 && patchNumber >= 295)
}

// codexVersionFrom162 reports whether version is Codex 0.162.0 or a later
// 0.x release: "0.<minor>.<patch>" in decimal digits, minor 162 or more.
func codexVersionFrom162(version string) bool {
	rest, ok := strings.CutPrefix(version, "0.")
	if !ok {
		return false
	}
	minor, patch, ok := strings.Cut(rest, ".")
	if !ok || !plainDecimal(minor) || !plainDecimal(patch) {
		return false
	}
	number, err := strconv.Atoi(minor)
	return err == nil && number >= 162
}

// plainDecimal: text is one or more ASCII digits, nothing else.
func plainDecimal(text string) bool {
	return text != "" && len(text) <= 9 && !strings.ContainsFunc(text, func(r rune) bool { return r < '0' || r > '9' })
}

// chatProvidersCheck is POST /v1/chat/providers/check, for this Mac's app
// alone (setup's Claude Code and Codex step and Settings → Agents, while the
// person signs a CLI in): it checks Claude Code's and Codex's sign-ins now
// (checkProvidersNow, within plainChatProbeWait) and answers 204; the app
// then reads capabilities.workspaceChats, and the pulse's plainChats line
// tells devices when the lists changed. A host without Chat's providers
// answers 404 not_found, as an older host without the route does.
func (h *Host) chatProvidersCheck(w http.ResponseWriter, r *http.Request) {
	if h.plainChats == nil || h.cliChats == nil {
		writeError(w, 404, "not_found", "This host checks no Chat sign-ins")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), plainChatProbeWait)
	defer cancel()
	h.plainChats.checkProvidersNow(ctx)
	w.WriteHeader(http.StatusNoContent)
}

// plainCLIProviders checks the Claude Code and Codex runtimes: those that
// can run Chat in the workspaces now, and those installed but in a version
// Chat does not support (plainVersionAuth; their sign-in is not asked) or
// signed in otherwise than with a subscription (chat_subscription.go). An
// installed runtime whose version no check has read is left out. Their
// entries are capabilities.workspaceChats' (workspaceChatProvider);
// AgentLand gives these chats no tools of its own.
func (h *Host) plainCLIProviders(ctx context.Context) (result, unavailable []plainChatProvider) {
	result, unavailable = []plainChatProvider{}, []plainChatProvider{}
	if h.cliChats == nil {
		return result, unavailable
	}
	for _, id := range []string{"claude", "codex"} {
		if !h.cliChats.available(id) {
			continue
		}
		var executable string
		var ok bool
		if id == "claude" && h.cliChats.claude != nil {
			executable, ok = h.cliChats.claude.executable()
		}
		if id == "codex" && h.cliChats.codex != nil && !h.cliChats.codex.config.execOnly {
			executable, ok = h.cliChats.codex.config.resolve()
		}
		if !ok {
			continue
		}
		name := chatProviderNames[id]
		if supported, version := h.plainChats.runtimeSupported(ctx, id, executable); !supported {
			if version != "" {
				auth := plainVersionAuth(id, version)
				unavailable = append(unavailable, plainChatProvider{ID: id, Name: name, Tools: []string{}, Features: []string{}, Auth: &auth})
			}
			continue
		}
		auth := h.plainChats.runtimeAuth(ctx, id, executable, h.plainAuthCheck(id, executable))
		if auth.Kind != plainAuthSubscription {
			unavailable = append(unavailable, plainChatProvider{ID: id, Name: name, Tools: []string{}, Features: []string{}, Auth: &auth})
			continue
		}
		entry := plainChatProvider{ID: id, Name: name, Tools: []string{}, Auth: &auth,
			Features:        []string{"events", "parts", "stop", "clientMessageId", "title", "attachments", "queue", "effort", "rewind", "fork"},
			AttachmentTypes: plainAttachmentTypes(id)}
		if id == "claude" {
			entry.Features = append(entry.Features, "regenerate")
		}
		result = append(result, entry)
	}
	return result, unavailable
}

// plainAuthCheck asks provider id's executable how it is signed in, with the
// environment its chats get: `claude auth status --json` in the Chats
// space's folder, which no workspace's settings reach (a process that a
// workspace's settings move to an API key ends at its start,
// chat_subscription.go), `codex login status` in the app-server's.
func (h *Host) plainAuthCheck(id, executable string) func(context.Context) (string, bool) {
	if id == "claude" {
		environment, dir := h.cliChats.claude.environment(), h.plainChats.home
		return func(ctx context.Context) (string, bool) {
			return cliAuthStatus(ctx, executable, []string{"auth", "status", "--json"}, environment, dir, false, claudeAuthKind)
		}
	}
	config := h.cliChats.codex.config
	args := append(append([]string{}, config.prefixArgs...), "login", "status")
	return func(ctx context.Context) (string, bool) {
		return cliAuthStatus(ctx, executable, args, codexEnvironment(config.env), config.processDir(), true, codexAuthKind)
	}
}

// workspaceChatProvider is a provider's entry in capabilities.workspaceChats,
// made from its entry of the last sign-in check; usable is false for one
// signed in otherwise, which lists no features. Workspace chats run with the
// agent's own tools, settings and instructions, so AgentLand adds no tools
// and discloses no instruction files; they ask for approvals and questions
// in the chat, switch modes, take every attachment type the host does, and
// Claude Code restores files on a rewind.
func workspaceChatProvider(entry plainChatProvider, usable bool) plainChatProvider {
	result := plainChatProvider{ID: entry.ID, Name: chatProviderNames[entry.ID], Tools: []string{}, Features: []string{}}
	if entry.Auth != nil {
		auth := *entry.Auth
		result.Auth = &auth
	}
	if !usable {
		return result
	}
	result.Features = append(slices.Clone(entry.Features), "approvals", "questions", "modes")
	if entry.ID == "claude" {
		result.Features = append(result.Features, "restoreFiles")
	}
	result.AttachmentTypes = plainAttachmentTypes("claude") // every type the host takes
	return result
}

// chatProviderReady refuses a chat request whose provider cannot run Chat
// now. Chat runs Claude Code and Codex only on the Mac's subscriptions, in
// the workspaces (owner, 2026-10-12): a provider signed in otherwise answers
// 400 agent_auth_required with what to do, one that cannot run Chat at all
// 503 agent_unavailable (with why, for a version Chat does not support). The Chats space keeps its own rules
// (plainProviderReady: its Claude Code and Codex chats are read-only);
// OpenCode and ACP chats in workspaces are not checked here. A host without Chat's provider checks (no PlainChatOptions:
// tests and embedders; serve always has them) leaves Claude Code and Codex
// to their processes' own guards: no API key variables, Codex's forced
// ChatGPT login and the end of a Claude Code process that reports an API key.
func (h *Host) chatProviderReady(w http.ResponseWriter, r *http.Request, p Project, provider string) bool {
	if h.isPlainChat(p) {
		return h.plainProviderReady(w, r, provider)
	}
	if (provider != "claude" && provider != "codex") || h.plainChats == nil {
		return true
	}
	return h.cliProviderReady(w, r, provider, func() {
		writeError(w, 503, "agent_unavailable", chatProviderNames[provider]+" cannot run Chat now. Check its installation and sign-in on the Mac.")
	})
}

// cliChatProvider is the provider a Claude Code or Codex chat's ID names, or
// "" for another chat.
func cliChatProvider(id string) string {
	switch {
	case isClaudeSessionID(id):
		return "claude"
	case strings.HasPrefix(id, "codex:"):
		return "codex"
	}
	return ""
}

// sessionProvider is chat s's provider: its own, else the one a Claude Code
// or Codex chat's ID names.
func sessionProvider(s Session) string {
	if s.Provider != "" {
		return s.Provider
	}
	return cliChatProvider(s.ID)
}

// plainProviderReady is chatProviderReady in the Chats space, where only
// OpenCode's chat agent still runs (with --opencode-chat): its Claude Code
// and Codex chats stay readable but take nothing new, so creating, reading
// options for, sending to, regenerating and continuing into them answer 503
// agent_unavailable (writeChatsSpaceRetired), and another provider 400
// plain_chat_provider.
func (h *Host) plainProviderReady(w http.ResponseWriter, r *http.Request, provider string) bool {
	switch provider {
	case "", "opencode":
		return h.plainChatReady(w, r)
	case "claude", "codex":
		writeChatsSpaceRetired(w)
		return false
	}
	writeError(w, 400, plainChatProviderCode, "Choose an available Chat provider")
	return false
}

// chatsSpaceRetiredMessage is why a Claude Code or Codex chat of the Chats
// space takes nothing new: Chat runs Claude Code and Codex themselves in the
// selected workspace since 2026-10-12, and the Chats space's conversation
// profile is gone. Such a chat continues in a workspace (POST
// /v1/chat/continue, with the conversation as context).
const chatsSpaceRetiredMessage = "Chat now runs in your workspaces; this chat stays readable."

// errChatsSpaceRetired: a Claude Code or Codex process was asked to run in
// the Chats space. Nothing started and nothing was sent.
var errChatsSpaceRetired = fmt.Errorf("%w: %w: Claude Code and Codex chats run only in workspaces", ErrCLIChatUnavailable, errPromptNotSent)

// writeChatsSpaceRetired answers 503 agent_unavailable for a request a
// Chats-space Claude Code or Codex chat no longer takes.
func writeChatsSpaceRetired(w http.ResponseWriter) {
	writeError(w, 503, "agent_unavailable", chatsSpaceRetiredMessage)
}

// chatsSpaceReadOnly refuses (writeChatsSpaceRetired) a change to chat s of
// project p that would start its agent again, when s is a Claude Code or
// Codex chat of the Chats space: a fork, a rewind, a queued message or an
// upload. Reading, listing, the archive, search, export, renaming and
// deleting such a chat still work.
func (h *Host) chatsSpaceReadOnly(w http.ResponseWriter, p Project, s Session) bool {
	if provider := sessionProvider(s); !h.isPlainChat(p) || (provider != "claude" && provider != "codex") {
		return false
	}
	writeChatsSpaceRetired(w)
	return true
}

// cliProviderReady reports whether provider is listed for Chat by the last
// check of the sign-ins, or by one made now. Otherwise it answers: 503
// agent_unavailable with why for a provider installed in a version Chat does
// not support (plainVersionAuth), the agents' sign-in code for one installed
// but not signed in with a subscription (clients show their sign-in notice,
// chat_subscription.go), else refuse's answer. The Chats space must exist
// (h.plainChats).
func (h *Host) cliProviderReady(w http.ResponseWriter, r *http.Request, provider string, refuse func()) bool {
	ready, auth := h.cliProviderCheck(r.Context(), provider)
	switch {
	case ready:
		return true
	// Installed in a version Chat does not support: 503 agent_unavailable
	// with why, never the sign-in code, whose notice would say to sign in.
	case auth != nil && auth.Reason == plainVersionUnsupported:
		writeError(w, 503, "agent_unavailable", auth.Message)
	// Installed, but not signed in with a subscription: the agents' sign-in
	// code, so clients show their sign-in notice (chat_subscription.go).
	case auth != nil:
		writeSubscriptionRequired(w, auth.Message)
	default:
		refuse()
	}
	return false
}

// cliProviderCheck reports whether provider is listed for Chat by the last
// check of the sign-ins, or by one made now within ctx; when it is not, why,
// as its entry among the unavailable providers says (nil when it says
// nothing). cliProviderReady answers with it; a chat's continue on the local
// socket refuses with it (chat_continue.go). The Chats space must exist
// (h.plainChats).
func (h *Host) cliProviderCheck(ctx context.Context, provider string) (bool, *plainChatAuth) {
	listed := func(providers []plainChatProvider) bool {
		return slices.ContainsFunc(providers, func(entry plainChatProvider) bool { return entry.ID == provider })
	}
	h.plainChats.mu.Lock()
	ready := listed(h.plainChats.cliProviders)
	h.plainChats.mu.Unlock()
	// The list is the last periodic check's; check again before refusing.
	if ready || ((provider == "claude" || provider == "codex") && listed(h.plainChats.refreshProviders(ctx))) {
		return true, nil
	}
	if entry, ok := h.plainChats.unavailableProvider(provider); ok && entry.Auth != nil {
		return false, entry.Auth
	}
	return false, nil
}
