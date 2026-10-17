package host

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Chat runs only on the subscriptions the owner is signed into on the Mac
// (owner's decision, 2026-10-12: "i dont want the chat featuro to use the api
// pricing, it needs to connect via the subscription logged into wit heth mac
// app for providers, api can come later"): Claude Code's claude.ai sign-in
// and Codex's ChatGPT sign-in, never API-key billing.
//
//   - Chat processes (Claude Code and Codex chats, the one-shot runs) get no
//     API key or other-cloud variables (chatAPIKeyVariables); Terminal
//     programs keep the owner's own environment.
//   - A provider is listed for Chat only while its CLI says it is signed in
//     with a subscription: `claude auth status --json` reports authMethod
//     claude.ai, `codex login status` "Logged in using ChatGPT". The host asks
//     with the exact executable, the environment its chats get and a bounded
//     wait, and never reads the CLIs' credentials itself. Any other sign-in
//     is listed in unavailableProviders with why (plainChatAuth).
//   - Requests for a Claude Code or Codex chat, in a workspace as in the
//     Chats space, are refused while its provider is not listed
//     (chatProviderReady).
//   - Codex chats start with forced_login_method="chatgpt". A Claude Code
//     chat whose process reports an API key anyway (its initialize answer's
//     account, its init line's apiKeySource; a project's apiKeyHelper, say)
//     is ended before it answers.

// chatAPIKeyVariables are left out of every Chat process's environment: with
// one set, Claude Code or Codex bills an API account or another cloud
// instead of the subscription.
var chatAPIKeyVariables = map[string]bool{
	"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true, "ANTHROPIC_BASE_URL": true,
	"CLAUDE_CODE_USE_BEDROCK": true, "CLAUDE_CODE_USE_VERTEX": true, "CLAUDE_CODE_USE_FOUNDRY": true,
	"CLAUDE_CODE_USE_ANTHROPIC_AWS": true, "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD": true,
	"CLAUDE_CODE_USE_MANTLE": true, "CLAUDE_CODE_USE_GATEWAY": true,
	"OPENAI_API_KEY": true, "CODEX_API_KEY": true, "OPENAI_BASE_URL": true,
}

// codexChatLoginArgs keep every Codex chat (app-server and exec) on the
// ChatGPT sign-in: Codex refuses an API key login with them.
var codexChatLoginArgs = []string{"-c", `forced_login_method="chatgpt"`}

// plainChatAuth is how a provider is signed in for Chat, its entry's auth in
// capabilities.workspaceChats (and generalChats). Providers lists only kind
// subscription (and, in generalChats, OpenCode's apiKey while the host runs
// OpenCode in Chat); unavailableProviders lists the others, with reason and
// message.
type plainChatAuth struct {
	// Kind is subscription, apiKey, other (a cloud provider or a token
	// AgentLand does not take), signedOut or unknown (the CLI's answer could
	// not be read).
	Kind string `json:"kind"`
	// Label names the sign-in: "Claude subscription", "ChatGPT
	// subscription", "API key", "Not signed in".
	Label string `json:"label"`
	// Reason is subscription_required for a provider whose sign-in Chat
	// cannot use, version_unsupported for one installed in a version Chat
	// does not support (its sign-in not asked, so its kind is unknown);
	// Message says what to do.
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message,omitempty"`
}

const (
	plainAuthSubscription = "subscription"
	plainAuthAPIKey       = "apiKey"
	plainAuthOther        = "other"
	plainAuthSignedOut    = "signedOut"
	plainAuthUnknown      = "unknown"
	// plainSubscriptionRequired is the reason of every sign-in Chat does not
	// use.
	plainSubscriptionRequired = "subscription_required"
	// plainVersionUnsupported is the reason of a Claude Code or Codex
	// installed in a version Chat does not support (plainVersionSupported).
	plainVersionUnsupported = "version_unsupported"
	// plainAuthWait bounds one status check; a subscription answer is kept
	// plainAuthFresh and any other plainAuthRetry, while the executable is
	// unchanged.
	plainAuthWait  = 5 * time.Second
	plainAuthFresh = 5 * time.Minute
	plainAuthRetry = 10 * time.Second
	// plainAuthCheckEvery spaces the explicit checks of the Mac app
	// (POST /v1/chat/providers/check), which ask the CLIs whatever their
	// last answers' age.
	plainAuthCheckEvery = 2 * time.Second
)

// claudeSubscriptionMessage and codexSubscriptionMessage say how to sign in
// for Chat.
const (
	claudeSubscriptionMessage = "Sign in to Claude Code with your Claude subscription (claude auth login)."
	codexSubscriptionMessage  = "Sign in to Codex with your ChatGPT subscription (codex login)."
)

var (
	// errClaudeSubscription: a general Claude chat's new process reported an
	// API key or another cloud before any prompt reached it.
	errClaudeSubscription = fmt.Errorf("Claude Code is not using a Claude subscription: %w", errPromptNotSent)
	// errClaudeSubscriptionStopped: it reported one after the prompt was
	// written, and was ended before it answered; the prompt's fate is
	// uncertain.
	errClaudeSubscriptionStopped = fmt.Errorf("Claude Code reported an API key and was stopped: %w", errDeliveryUncertain)
)

// withoutChatAPIKeys is environment without chatAPIKeyVariables.
func withoutChatAPIKeys(environment []string) []string {
	result := make([]string, 0, len(environment))
	for _, item := range environment {
		name, _, _ := strings.Cut(item, "=")
		if chatAPIKeyVariables[name] {
			continue
		}
		result = append(result, item)
	}
	return result
}

// plainAuthOf is the auth entry for provider's kind of sign-in.
func plainAuthOf(provider, kind string) plainChatAuth {
	cli, subscription, message := "Claude Code", "Claude subscription", claudeSubscriptionMessage
	if provider == "codex" {
		cli, subscription, message = "Codex", "ChatGPT subscription", codexSubscriptionMessage
	}
	switch kind {
	case plainAuthSubscription:
		return plainChatAuth{Kind: kind, Label: subscription}
	case plainAuthAPIKey:
		return plainChatAuth{Kind: kind, Label: "API key", Reason: plainSubscriptionRequired,
			Message: cli + " is signed in with an API key, which Chat doesn’t use. " + message}
	case plainAuthOther:
		return plainChatAuth{Kind: kind, Label: "Not a subscription", Reason: plainSubscriptionRequired,
			Message: cli + " isn’t signed in with a subscription. " + message}
	case plainAuthSignedOut:
		return plainChatAuth{Kind: kind, Label: "Not signed in", Reason: plainSubscriptionRequired,
			Message: cli + " isn’t signed in. " + message}
	default:
		return plainChatAuth{Kind: plainAuthUnknown, Label: "Sign-in not confirmed", Reason: plainSubscriptionRequired,
			Message: "AgentLand couldn’t confirm how " + cli + " is signed in. " + message}
	}
}

// plainVersionAuth is the auth entry of provider installed in a version
// Chat does not support. Its sign-in was not asked, so its kind is unknown;
// the message names the version when it is a plain version string.
func plainVersionAuth(provider, version string) plainChatAuth {
	cli := chatProviderNames[provider]
	named := cli + " " + version
	if len(version) > 32 || strings.ContainsFunc(version, func(r rune) bool {
		return !(r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r == '.' || r == '-' || r == '+' || r == '_')
	}) {
		named = "this version of " + cli
	}
	return plainChatAuth{Kind: plainAuthUnknown, Label: "Version not supported", Reason: plainVersionUnsupported,
		Message: "AgentLand’s Chat doesn’t support " + named + " yet. Use " + cli + " in Terminal."}
}

// claudeAuthKind maps `claude auth status --json`: only a claude.ai sign-in
// on Anthropic's own API is a subscription (Claude Code 2.1's authMethod is
// claude.ai, oauth_token, api_key, api_key_helper, third_party or none).
func claudeAuthKind(output []byte) (string, bool) {
	var status struct {
		LoggedIn    bool   `json:"loggedIn"`
		AuthMethod  string `json:"authMethod"`
		APIProvider string `json:"apiProvider"`
	}
	if json.Unmarshal(output, &status) != nil {
		return "", false
	}
	switch {
	case !status.LoggedIn || status.AuthMethod == "none" || status.AuthMethod == "":
		return plainAuthSignedOut, true
	case status.AuthMethod == "claude.ai" && (status.APIProvider == "" || status.APIProvider == "firstParty"):
		return plainAuthSubscription, true
	case status.AuthMethod == "api_key" || status.AuthMethod == "api_key_helper":
		return plainAuthAPIKey, true
	default:
		return plainAuthOther, true
	}
}

// codexAuthKind maps `codex login status`, which Codex 0.162 and 0.163 print
// on stderr. Only the line's start is read: an API key's line names part of the
// key, and nothing of it is kept.
func codexAuthKind(output []byte) (string, bool) {
	for _, line := range strings.Split(string(output), "\n") {
		switch line = strings.TrimSpace(line); {
		case line == "Logged in using ChatGPT":
			return plainAuthSubscription, true
		case strings.HasPrefix(line, "Logged in using an API key"):
			return plainAuthAPIKey, true
		case strings.HasPrefix(line, "Logged in using"):
			return plainAuthOther, true
		case line == "Not logged in":
			return plainAuthSignedOut, true
		}
	}
	return "", false
}

// cliAuthStatus runs a CLI's status command with environment in dir, within
// plainAuthWait, and reads its answer with read. It reports false when the
// CLI did not answer readably. The output is never logged.
func cliAuthStatus(ctx context.Context, executable string, args, environment []string, dir string, stderr bool, read func([]byte) (string, bool)) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, plainAuthWait)
	defer cancel()
	command := exec.CommandContext(ctx, executable, args...)
	command.Env = environment
	command.Dir = dir
	output := &cappedGitOutput{limit: 64 << 10}
	command.Stdout = output
	if stderr {
		command.Stderr = output
	}
	command.WaitDelay = time.Second
	// Signed out exits 1 and still says so.
	_ = command.Run()
	if ctx.Err() != nil {
		return "", false
	}
	return read(output.Bytes())
}

// plainAuthCheck is the last answered sign-in check of a runtime's
// executable.
type plainAuthCheck struct {
	path     string
	modified time.Time
	size     int64
	at       time.Time
	auth     plainChatAuth
}

// runtimeAuth is how provider id's executable is signed in. It asks the CLI
// (ask) again once the last answer is older than plainAuthFresh for a
// subscription or plainAuthRetry otherwise, or the file changed, and at
// once during an explicit check (forceAuth, checkProvidersNow); a check
// that does not answer keeps the last answer for the same file, and is
// unknown without one. Callers hold providersMu.
func (c *plainChats) runtimeAuth(ctx context.Context, id, executable string, ask func(context.Context) (string, bool)) plainChatAuth {
	check := plainAuthCheck{path: executable}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		check.path = resolved
	}
	if info, err := os.Stat(check.path); err == nil {
		check.modified, check.size = info.ModTime(), info.Size()
	}
	now := c.clock()
	previous, known := c.auths[id]
	same := known && !check.modified.IsZero() && previous.path == check.path && previous.modified.Equal(check.modified) && previous.size == check.size
	if same && !c.forceAuth {
		fresh := plainAuthRetry
		if previous.auth.Kind == plainAuthSubscription {
			fresh = plainAuthFresh
		}
		if now.Sub(previous.at) < fresh {
			return previous.auth
		}
	}
	kind, answered := ask(ctx)
	if !answered {
		if same {
			return previous.auth
		}
		return plainAuthOf(id, plainAuthUnknown)
	}
	check.at, check.auth = now, plainAuthOf(id, kind)
	if c.auths == nil {
		c.auths = map[string]plainAuthCheck{}
	}
	c.auths[id] = check
	return check.auth
}

// clock is the plain chats' clock, the wall clock when none is set.
func (c *plainChats) clock() time.Time {
	if c.now != nil {
		return c.now()
	}
	return time.Now()
}

// claudeAccountSubscription reports whether a Claude Code initialize
// answer's account allows Chat: no API key in use and Anthropic's own API.
// An answer without an account (older CLIs) leaves it to the sign-in check
// and the init line.
func claudeAccountSubscription(response json.RawMessage) bool {
	var answer struct {
		Account *struct {
			APIKeySource string `json:"apiKeySource"`
			APIProvider  string `json:"apiProvider"`
		} `json:"account"`
	}
	if json.Unmarshal(response, &answer) != nil || answer.Account == nil {
		return true
	}
	return claudeKeySourceAllowed(answer.Account.APIKeySource) && (answer.Account.APIProvider == "" || answer.Account.APIProvider == "firstParty")
}

// claudeKeySourceAllowed: Claude Code names no API key, or says none.
func claudeKeySourceAllowed(source string) bool {
	return source == "" || source == "none"
}

// writeSubscriptionRequired refuses a Chat request for a provider that is not
// signed in with a subscription. The code is the agents' sign-in code, so
// clients show their sign-in notice with the message.
func writeSubscriptionRequired(w http.ResponseWriter, message string) {
	writeError(w, 400, "agent_auth_required", message)
}
