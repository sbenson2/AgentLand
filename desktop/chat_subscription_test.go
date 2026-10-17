package host

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeSignedInCLI is a fake claude or codex that reports version and a
// subscription sign-in.
func fakeSignedInCLI(name, version string) string {
	return fakeAuthCLI(name, version, "", "")
}

// fakeAuthCLI is a fake claude or codex: --version prints version, and the
// sign-in status prints the file status names (a subscription when it is
// empty). Each status check appends a line to the file runs names, saying
// whether an API key variable reached it; it never prints the environment.
func fakeAuthCLI(name, version, status, runs string) string {
	record := ""
	if runs != "" {
		record = `if [ -n "$ANTHROPIC_API_KEY$OPENAI_API_KEY$CODEX_API_KEY$CLAUDE_CODE_USE_BEDROCK" ]; then echo key >> '` + runs + `'; else echo clean >> '` + runs + `'; fi
`
	}
	answer := `echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'`
	command := `"$1 $2" = "auth status"`
	if name == "codex" {
		answer, command = `echo 'Logged in using ChatGPT' >&2`, `"$1 $2" = "login status"`
	}
	if status != "" {
		answer = `cat '` + status + `'`
		if name == "codex" {
			answer += " >&2"
		}
	}
	return "#!/bin/sh\nif [ " + command + " ]; then\n" + record + answer + "\nexit 0\nfi\necho '" + version + "'\n"
}

// Chat processes get no API key or other-cloud variables; everything else,
// and a test's own additions, still reach them.
func TestChatEnvironmentsLeaveOutAPIKeys(t *testing.T) {
	for name := range chatAPIKeyVariables {
		t.Setenv(name, "must-not-reach-chat")
	}
	t.Setenv("AGENTLAND_SUBSCRIPTION_KEEP", "kept")
	t.Setenv("LANG", "en_US.UTF-8")
	check := func(label string, environment []string, kept ...string) {
		t.Helper()
		names := map[string]bool{}
		for _, item := range environment {
			name, _, _ := strings.Cut(item, "=")
			names[name] = true
		}
		for name := range chatAPIKeyVariables {
			if names[name] {
				t.Errorf("%s: %s reached a chat process", label, name)
			}
		}
		for _, name := range kept {
			if !names[name] {
				t.Errorf("%s: %s was dropped", label, name)
			}
		}
	}
	check("codex", codexEnvironment([]string{"CODEX_HOME=/tmp/codex"}), "LANG", "CODEX_HOME")
	check("one-shot", oneShotEnvironment(), "LANG")
	engine := &claudeEngine{options: claudeConfig{env: []string{"CLAUDE_CONFIG_DIR=/tmp/claude"}}}
	check("claude", engine.environment(), "LANG", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_STARTUP_FAILURE_RESULTS")
	engine.options.baseEnv = []string{"PATH=/usr/bin", "ANTHROPIC_API_KEY=base", "CLAUDE_CODE_USE_VERTEX=1", "OPENAI_BASE_URL=http://elsewhere"}
	check("claude base", engine.environment(), "PATH")
	// AgentLand's own variables stay out as before.
	for _, item := range append(codexEnvironment(nil), oneShotEnvironment()...) {
		if strings.HasPrefix(item, "AGENTLAND_") {
			t.Fatalf("AgentLand variable reached a chat process: %s", item)
		}
	}
}

// Codex chats start with the ChatGPT sign-in forced, app-server and exec
// alike.
func TestCodexChatsForceTheChatGPTSignIn(t *testing.T) {
	args, _ := codexExecArgs("/repo", "", nil, codexSettings{mode: "read-only"}, []string{"-c", "x=1"})
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, `-c forced_login_method="chatgpt" -c x=1 -`) {
		t.Fatalf("exec: %s", joined)
	}
	fake := newCodexFake(t)
	f := newCodexFixture(t, fake)
	id := f.newChat()
	f.send(id, "Hello", nil)
	f.idle(id)
	data, err := os.ReadFile(filepath.Join(fake.state, "log.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `forced_login_method=\"chatgpt\"`) {
		t.Fatalf("app-server started without the ChatGPT sign-in: %s", data)
	}
}

func TestClaudeAuthStatusKinds(t *testing.T) {
	for _, test := range []struct {
		output string
		kind   string
	}{
		{`{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"owner@example.com","subscriptionType":"max"}`, plainAuthSubscription},
		{`{"loggedIn":true,"authMethod":"claude.ai"}`, plainAuthSubscription},
		{`{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"ANTHROPIC_API_KEY"}`, plainAuthAPIKey},
		{`{"loggedIn":true,"authMethod":"api_key_helper","apiProvider":"firstParty"}`, plainAuthAPIKey},
		{`{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}`, plainAuthOther},
		{`{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"vertex"}`, plainAuthOther},
		{`{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}`, plainAuthOther},
		{`{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}`, plainAuthSignedOut},
	} {
		if kind, ok := claudeAuthKind([]byte(test.output)); !ok || kind != test.kind {
			t.Errorf("%s: %q %t, want %q", test.output, kind, ok, test.kind)
		}
	}
	if _, ok := claudeAuthKind([]byte("2.1.300 (Claude Code)")); ok {
		t.Fatal("read an answer from output that is not one")
	}
}

func TestCodexLoginStatusKinds(t *testing.T) {
	for _, test := range []struct {
		output string
		kind   string
	}{
		{"Logged in using ChatGPT\n", plainAuthSubscription},
		{"WARNING: something\nLogged in using ChatGPT\n", plainAuthSubscription},
		{"Logged in using an API key - sk-proj-***ABCDE\n", plainAuthAPIKey},
		{"Logged in using access token\n", plainAuthOther},
		{"Logged in using Amazon Bedrock API key\n", plainAuthOther},
		{"Not logged in\n", plainAuthSignedOut},
	} {
		if kind, ok := codexAuthKind([]byte(test.output)); !ok || kind != test.kind {
			t.Errorf("%q: %q %t, want %q", test.output, kind, ok, test.kind)
		}
	}
	if _, ok := codexAuthKind([]byte("Error checking login status: boom\n")); ok {
		t.Fatal("read an answer from an error")
	}
	// Nothing of a key's line is kept in what the host lists.
	if auth := plainAuthOf("codex", plainAuthAPIKey); strings.Contains(auth.Message+auth.Label, "sk-") {
		t.Fatalf("auth names the key: %+v", auth)
	}
}

// A provider is listed for Chat only while its CLI reports a subscription
// sign-in; another sign-in is listed as unavailable with what to do, and a
// request for it is refused with the agents' sign-in code.
func TestPlainChatProvidersNeedASubscription(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "must-not-reach-the-check")
	f := newPlainChatFixture(t, HostOptions{PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)}})
	tools := t.TempDir()
	runs := filepath.Join(tools, "runs")
	claudeStatus, codexStatus := filepath.Join(tools, "claude-status"), filepath.Join(tools, "codex-status")
	write := func(path, text string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(claudeStatus, `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}`)
	write(codexStatus, "Not logged in\n")
	write(filepath.Join(tools, "claude"), fakeAuthCLI("claude", "2.1.300 (Claude Code)", claudeStatus, runs))
	write(filepath.Join(tools, "codex"), fakeAuthCLI("codex", "codex-cli 0.162.1", codexStatus, runs))
	os.Chmod(filepath.Join(tools, "claude"), 0o700)
	os.Chmod(filepath.Join(tools, "codex"), 0o700)
	f.chats.claude = newClaudeEngine(f.chats, claudeConfig{executable: func() (string, bool) { return filepath.Join(tools, "claude"), true }})
	f.chats.codex = newCodexEngine(f.chats, codexEngineConfig{executable: func() (string, bool) { return filepath.Join(tools, "codex"), true }})
	clock := &testClock{now: time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)}
	f.host.plainChats.now = clock.Now

	// Chat lists Claude Code and Codex in capabilities.workspaceChats
	// (2026-10-12), and their chats in the workspaces follow the sign-ins.
	advertised := func() (general *workspaceChatsCapability, legacy *plainChatsCapability) {
		t.Helper()
		f.host.plainChats.refreshProviders(t.Context())
		var body struct {
			General *workspaceChatsCapability `json:"workspaceChats"`
			Legacy  *plainChatsCapability     `json:"plainChats"`
		}
		if w := f.call(t, "GET", "/v1/capabilities", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil {
			t.Fatalf("capabilities: %d %s", w.Code, w.Body)
		}
		return body.General, body.Legacy
	}
	ids := func(providers []plainChatProvider) []string {
		result := []string{}
		for _, provider := range providers {
			result = append(result, provider.ID)
		}
		return result
	}

	general, legacy := advertised()
	if legacy != nil || general == nil || !slices.Equal(ids(general.Providers), []string{"claude"}) || !slices.Equal(ids(general.UnavailableProviders), []string{"codex"}) {
		t.Fatalf("listed: general %+v, legacy %+v", general, legacy)
	}
	if auth := general.Providers[0].Auth; auth == nil || *auth != (plainChatAuth{Kind: plainAuthSubscription, Label: "Claude subscription"}) {
		t.Fatalf("claude auth: %+v", auth)
	}
	codex := general.UnavailableProviders[0]
	if codex.Auth == nil || codex.Auth.Kind != plainAuthSignedOut || codex.Auth.Reason != plainSubscriptionRequired || !strings.Contains(codex.Auth.Message, "codex login") || len(codex.Features) != 0 {
		t.Fatalf("codex entry: %+v %+v", codex, codex.Auth)
	}
	w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "codex"})
	if w.Code != 400 || errorCode(t, w) != "agent_auth_required" || !strings.Contains(w.Body.String(), "ChatGPT subscription") {
		t.Fatalf("codex create: %d %s", w.Code, w.Body)
	}
	if w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude"}); w.Code != 201 {
		t.Fatalf("claude create: %d %s", w.Code, w.Body)
	}

	// A subscription answer is reused for a while, then asked again; the
	// check never gets an API key variable.
	before := strings.Count(readFile(t, runs), "\n")
	clock.Advance(plainAuthRetry + time.Second)
	advertised()
	if after := strings.Count(readFile(t, runs), "\n"); after != before+1 {
		t.Fatalf("checks: %d then %d (claude's answer was not kept, or codex's was)", before, after)
	}
	if strings.Contains(readFile(t, runs), "key") {
		t.Fatal("an API key variable reached the sign-in check")
	}

	// Claude switched to an API key: once the answer is stale it moves to
	// unavailable, and the sign-in notice says why.
	write(claudeStatus, `{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"/login managed key"}`)
	clock.Advance(plainAuthFresh + time.Second)
	general, _ = advertised()
	if general == nil || len(general.Providers) != 0 || !slices.Equal(ids(general.UnavailableProviders), []string{"claude", "codex"}) {
		t.Fatalf("after an API key sign-in: %+v", general)
	}
	if auth := general.UnavailableProviders[0].Auth; auth.Kind != plainAuthAPIKey || auth.Label != "API key" || !strings.Contains(auth.Message, "claude auth login") {
		t.Fatalf("claude auth: %+v", auth)
	}
	w = f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude"})
	if w.Code != 400 || errorCode(t, w) != "agent_auth_required" || !strings.Contains(w.Body.String(), "API key") {
		t.Fatalf("claude create with an API key: %d %s", w.Code, w.Body)
	}

	// Signing in with ChatGPT shows within the retry interval.
	write(codexStatus, "Logged in using ChatGPT\n")
	clock.Advance(plainAuthRetry + time.Second)
	if general, _ = advertised(); !slices.Equal(ids(general.Providers), []string{"codex"}) || general.Providers[0].Auth.Label != "ChatGPT subscription" {
		t.Fatalf("after a ChatGPT sign-in: %+v", general)
	}
}

// A sign-in check that does not answer keeps the last answer for the same
// executable, and is unknown without one.
func TestPlainChatSignInCheckThatDoesNotAnswer(t *testing.T) {
	executable := filepath.Join(t.TempDir(), "claude")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)}
	c := &plainChats{now: clock.Now}
	answer, asked := "", 0
	check := func() plainChatAuth {
		return c.runtimeAuth(t.Context(), "claude", executable, func(context.Context) (string, bool) { asked++; return answer, answer != "" })
	}
	if auth := check(); auth.Kind != plainAuthUnknown || auth.Reason != plainSubscriptionRequired {
		t.Fatalf("no answer yet: %+v", auth)
	}
	answer = plainAuthSubscription
	if auth := check(); auth.Kind != plainAuthSubscription {
		t.Fatalf("answered: %+v", auth)
	}
	answer = ""
	clock.Advance(plainAuthFresh + time.Second)
	if auth := check(); auth.Kind != plainAuthSubscription || asked != 3 {
		t.Fatalf("a check that did not answer dropped the last answer: %+v (%d checks)", auth, asked)
	}
}

// OpenCode leaves Chat unless the host is told otherwise: it is never asked
// about the Chats space, never listed, and an OpenCode plain chat saved
// earlier stays readable but takes no new message.
func TestOpenCodeLeavesChatByDefault(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)}})
	if f.host.plainChats.refresh(t.Context()) || f.host.plainChats.ready(t.Context()) {
		t.Fatal("OpenCode confirmed for Chat while it is off")
	}
	f.oc.mu.Lock()
	asked := f.oc.disposals + len(f.oc.toolQueries) + len(f.oc.mcpConnects)
	f.oc.mu.Unlock()
	if asked != 0 {
		t.Fatal("OpenCode was asked about the Chats space")
	}
	var body struct {
		General *plainChatsCapability `json:"generalChats"`
		Legacy  *plainChatsCapability `json:"plainChats"`
	}
	// General Chat stays listed with no provider (its saved chats stay
	// readable); the key older clients read is absent.
	if w := f.call(t, "GET", "/v1/capabilities", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || body.General == nil || len(body.General.Providers) != 0 || body.Legacy != nil {
		t.Fatalf("capabilities without a provider: %d %s", w.Code, w.Body)
	}
	for _, provider := range []string{"", "opencode"} {
		w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "chats", "provider": provider})
		if w.Code != 503 || errorCode(t, w) != "agent_unavailable" || !strings.Contains(w.Body.String(), "subscriptions") {
			t.Fatalf("create with %q: %d %s", provider, w.Code, w.Body)
		}
	}

	// A chat made while OpenCode ran Chat (the flag on earlier).
	on := newPlainChatFixture(t, HostOptions{})
	on.confirmPlainChats(t)
	id := on.plainChat(t)
	on.host.plainChats.openCode.Store(false)
	on.host.plainChats.mu.Lock()
	on.host.plainChats.confirmed = false
	on.host.plainChats.mu.Unlock()
	if w := on.call(t, "GET", "/v1/messages?projectId=chats&sessionId="+id, nil); w.Code != http.StatusOK {
		t.Fatalf("read a saved OpenCode chat: %d %s", w.Code, w.Body)
	}
	w := on.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": id, "text": "Hello"})
	if w.Code != 503 || errorCode(t, w) != "agent_unavailable" || !strings.Contains(w.Body.String(), "OpenCode chats stay readable") {
		t.Fatalf("send to a saved OpenCode chat: %d %s", w.Code, w.Body)
	}
	if general := on.host.plainChats.capability(); general != nil && slices.ContainsFunc(general.Providers, func(p plainChatProvider) bool { return p.ID == "opencode" }) {
		t.Fatalf("OpenCode listed: %+v", general)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, _ := os.ReadFile(path)
	return string(data)
}

// workspaceClaudeChat is a Claude Code chat of the fixture's engine in a
// workspace of its own.
func workspaceClaudeChat(t *testing.T, f *claudeFixture) *claudeChat {
	t.Helper()
	p := Project{ID: "conversation", Directory: t.TempDir()}
	session, err := f.chats.CreateSession(p, "Conversation", "claude")
	if err != nil {
		t.Fatal(err)
	}
	chat, err := f.chats.claude.chat(p, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	return chat
}

// A Claude Code chat's process that names an API key in its initialize
// answer ends before any prompt reaches it; a subscription account goes on.
func TestClaudeChatProcessRefusesAnAPIKeyAccount(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "control", "subtype": "initialize",
		"respond": json.RawMessage(`{"commands":[],"models":[],"account":{"apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"}}`)}))
	chat := workspaceClaudeChat(t, f)
	if _, err := chat.send(chatPrompt{text: "Hello"}); !errors.Is(err, errClaudeSubscription) || !errors.Is(err, errPromptNotSent) {
		t.Fatalf("send with an API key account: %v", err)
	}
	for _, frame := range f.frames(1) {
		if frame["type"] == "user" {
			t.Fatal("the prompt reached a process that uses an API key")
		}
	}
	w := httptest.NewRecorder()
	promptFailure(w, errClaudeSubscription)
	if w.Code != 400 || !strings.Contains(w.Body.String(), `"agent_auth_required"`) || !strings.Contains(w.Body.String(), "claude auth login") {
		t.Fatalf("refusal: %d %s", w.Code, w.Body)
	}

	f.script(2, step(map[string]any{"do": "control", "subtype": "initialize",
		"respond": json.RawMessage(`{"commands":[],"models":[],"account":{"subscriptionType":"max","apiProvider":"firstParty"}}`)}),
		step(map[string]any{"do": "user", "echo": true}))
	if _, err := chat.send(chatPrompt{text: "Hello"}); err != nil {
		t.Fatalf("send with a subscription account: %v", err)
	}
}

// A Claude Code chat whose init line reports an API key is ended at once,
// and its turn says to sign in with the subscription.
func TestClaudeChatTurnEndsWhenInitReportsAnAPIKey(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), step(map[string]any{"do": "user", "echo": true}),
		emit(`{"type":"system","subtype":"init","session_id":"$session","model":"claude-opus-5-5","permissionMode":"$mode","apiKeySource":"ANTHROPIC_API_KEY","uuid":"`+newClaudeUUID()+`"}`),
		step(map[string]any{"do": "hang"}))
	chat := workspaceClaudeChat(t, f)
	done := make(chan struct{})
	if _, err := chat.send(chatPrompt{text: "Hello", finished: func() { close(done) }}); err != nil && !errors.Is(err, errClaudeSubscriptionStopped) {
		t.Fatalf("send: %v", err)
	}
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the turn did not end")
	}
	chat.mu.Lock()
	loaded := chat.loadLocked(100)
	chat.mu.Unlock()
	last := loaded.messages[len(loaded.messages)-1]
	if last.Role != "assistant" || last.Status != "error" || last.Error == nil || last.Error.Code != "agent_auth_required" || !strings.Contains(last.Error.Message, "Claude subscription") {
		t.Fatalf("reply: %+v %+v", last, last.Error)
	}
	// A prompt written before the init line stays uncertain.
	if !errors.Is(errClaudeSubscriptionStopped, errDeliveryUncertain) {
		t.Fatal("errClaudeSubscriptionStopped is not uncertain")
	}
}
