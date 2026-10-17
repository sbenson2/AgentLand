package host

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// workspaceChatTools are fake claude and codex executables that answer their
// version and sign-in checks from status files (a subscription while a file
// is empty), installed as the fixture's Claude Code and Codex.
type workspaceChatTools struct {
	claudeStatus, codexStatus string
}

func installWorkspaceChatTools(t *testing.T, f *chatFixture) workspaceChatTools {
	t.Helper()
	folder := t.TempDir()
	tools := workspaceChatTools{claudeStatus: filepath.Join(folder, "claude-status"), codexStatus: filepath.Join(folder, "codex-status")}
	tools.set(t, tools.claudeStatus, `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}`)
	tools.set(t, tools.codexStatus, "Logged in using ChatGPT\n")
	claude, codex := filepath.Join(folder, "claude"), filepath.Join(folder, "codex")
	tools.set(t, claude, fakeAuthCLI("claude", "2.1.300 (Claude Code)", tools.claudeStatus, ""))
	tools.set(t, codex, fakeAuthCLI("codex", "codex-cli 0.162.1", tools.codexStatus, ""))
	for _, path := range []string{claude, codex} {
		if err := os.Chmod(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	f.chats.claude = newClaudeEngine(f.chats, claudeConfig{executable: func() (string, bool) { return claude, true }})
	f.chats.codex = newCodexEngine(f.chats, codexEngineConfig{executable: func() (string, bool) { return codex, true }})
	return tools
}

func (workspaceChatTools) set(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

// advertisedChats reads capabilities.generalChats, workspaceChats and
// plainChats as the host encodes them, after a check of the sign-ins.
func advertisedChats(t *testing.T, f *chatFixture) map[string]json.RawMessage {
	t.Helper()
	f.host.plainChats.refreshProviders(t.Context())
	var body map[string]json.RawMessage
	if w := f.call(t, "GET", "/v1/capabilities", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil {
		t.Fatalf("capabilities: %d %s", w.Code, w.Body)
	}
	return body
}

// Chat is Claude Code and Codex in the workspaces (owner, 2026-10-12):
// capabilities.workspaceChats lists them by their sign-ins, whatever OpenCode
// does, with what their workspace chats support; general Chat lists neither,
// and keeps its providers list, empty, so older clients offer no Chat.
func TestWorkspaceChatsCapability(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)}})
	tools := installWorkspaceChatTools(t, f)
	tools.set(t, tools.codexStatus, "Not logged in\n")
	clock := &testClock{now: time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)}
	f.host.plainChats.now = clock.Now

	advertised := advertisedChats(t, f)
	if general := string(advertised["generalChats"]); general != `{"providers":[],"projectId":"chats","tools":[]}` {
		t.Fatalf("generalChats: %s", general)
	}
	if legacy, listed := advertised["plainChats"]; listed {
		t.Fatalf("plainChats without OpenCode: %s", legacy)
	}
	all := `"attachmentTypes":["image/png","image/jpeg","image/gif","image/webp","text/plain","text/markdown","text/csv","application/json","application/pdf"]`
	claude := `{"id":"claude","name":"Claude Code","tools":[],"features":["events","parts","stop","clientMessageId","title","attachments","queue","effort","rewind","fork","regenerate","approvals","questions","modes","restoreFiles"],` + all + `,"auth":{"kind":"subscription","label":"Claude subscription"}}`
	codexOut := `{"id":"codex","name":"Codex","tools":[],"features":[],"auth":{"kind":"signedOut","label":"Not signed in","reason":"subscription_required","message":"Codex isn’t signed in. Sign in to Codex with your ChatGPT subscription (codex login)."}}`
	if workspace := string(advertised["workspaceChats"]); workspace != `{"version":1,"providers":[`+claude+`],"unavailableProviders":[`+codexOut+`]}` {
		t.Fatalf("workspaceChats: %s", workspace)
	}
	f.oc.mu.Lock()
	asked := f.oc.disposals + len(f.oc.toolQueries) + len(f.oc.mcpConnects)
	f.oc.mu.Unlock()
	if asked != 0 {
		t.Fatal("OpenCode was asked about Chat")
	}

	// Signing Codex in lists it, and the pulse's revision changes so
	// connected devices read capabilities again.
	before, _ := f.host.plainChats.capabilityState()
	tools.set(t, tools.codexStatus, "Logged in using ChatGPT\n")
	clock.Advance(plainAuthRetry + time.Second)
	advertised = advertisedChats(t, f)
	codex := `{"id":"codex","name":"Codex","tools":[],"features":["events","parts","stop","clientMessageId","title","attachments","queue","effort","rewind","fork","approvals","questions","modes"],` + all + `,"auth":{"kind":"subscription","label":"ChatGPT subscription"}}`
	if workspace := string(advertised["workspaceChats"]); workspace != `{"version":1,"providers":[`+claude+`,`+codex+`],"unavailableProviders":[]}` {
		t.Fatalf("workspaceChats after a ChatGPT sign-in: %s", workspace)
	}
	if after, _ := f.host.plainChats.capabilityState(); after == before {
		t.Fatal("the pulse's revision did not change with the sign-in")
	}

	// With OpenCode in Chat (--opencode-chat), general Chat lists OpenCode
	// alone; the workspaces still list Claude Code.
	on := newPlainChatFixture(t, HostOptions{})
	on.confirmPlainChats(t)
	on.host.plainChats.mu.Lock()
	on.host.plainChats.cliProviders = []plainChatProvider{{ID: "claude", Name: "Claude Code", Tools: []string{plainChatToolWebsearch}, Features: []string{"events"}}}
	on.host.plainChats.mu.Unlock()
	var body struct {
		General   *plainChatsCapability     `json:"generalChats"`
		Legacy    *plainChatsCapability     `json:"plainChats"`
		Workspace *workspaceChatsCapability `json:"workspaceChats"`
	}
	if w := on.call(t, "GET", "/v1/capabilities", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil {
		t.Fatalf("capabilities: %d %s", w.Code, w.Body)
	}
	ids := func(capability *plainChatsCapability) []string {
		result := []string{}
		for _, provider := range capability.Providers {
			result = append(result, provider.ID)
		}
		return result
	}
	if body.General == nil || body.Legacy == nil || !slices.Equal(ids(body.General), []string{"opencode"}) || !slices.Equal(ids(body.Legacy), []string{"opencode"}) {
		t.Fatalf("with OpenCode: general %+v, legacy %+v", body.General, body.Legacy)
	}
	if body.Workspace == nil || len(body.Workspace.Providers) != 1 || body.Workspace.Providers[0].ID != "claude" || len(body.Workspace.Providers[0].Tools) != 0 {
		t.Fatalf("workspaces with OpenCode: %+v", body.Workspace)
	}
}

// The Mac app's Sign In… (owner, 2026-10-17): POST /v1/chat/providers/check
// asks the CLIs again at once, so a sign-in made a moment ago shows without
// waiting for plainAuthRetry or the minute's check; it is this Mac's session's
// alone, and explicit checks are spaced plainAuthCheckEvery apart.
func TestChatProvidersCheckNow(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{LocalSessionToken: routeLocalToken, PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)}})
	tools := installWorkspaceChatTools(t, f)
	tools.set(t, tools.codexStatus, "Not logged in\n")
	clock := &testClock{now: time.Date(2026, 10, 17, 3, 0, 0, 0, time.UTC)}
	f.host.plainChats.now = clock.Now
	const path = "/v1/chat/providers/check"
	check := func() {
		t.Helper()
		if w := localRequest(t, f.host.Handler(), "POST", path, routeLocalToken, nil); w.Code != 204 || w.Body.Len() != 0 {
			t.Fatalf("check: %d %s", w.Code, w.Body)
		}
	}
	codexSignedIn := func() bool {
		t.Helper()
		var body struct {
			Workspace *workspaceChatsCapability `json:"workspaceChats"`
		}
		if w := f.call(t, "GET", "/v1/capabilities", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || body.Workspace == nil {
			t.Fatalf("capabilities: %d %s", w.Code, w.Body)
		}
		return slices.ContainsFunc(body.Workspace.Providers, func(entry plainChatProvider) bool { return entry.ID == "codex" })
	}

	f.host.plainChats.refreshProviders(t.Context())
	if codexSignedIn() {
		t.Fatal("Codex signed out was listed")
	}
	// Codex signs in: the paced check keeps its answer for plainAuthRetry,
	// and the explicit one asks again at once.
	tools.set(t, tools.codexStatus, "Logged in using ChatGPT\n")
	f.host.plainChats.refreshProviders(t.Context())
	if codexSignedIn() {
		t.Fatal("the paced check asked again within plainAuthRetry")
	}
	before, _ := f.host.plainChats.capabilityState()
	check()
	if !codexSignedIn() {
		t.Fatal("the explicit check did not show the sign-in")
	}
	if after, _ := f.host.plainChats.capabilityState(); after == before {
		t.Fatal("the pulse's revision did not change with the sign-in")
	}

	// Paired devices are refused, over loopback too.
	for label, w := range map[string]*httptest.ResponseRecorder{
		"a paired device":               f.call(t, "POST", path, nil),
		"a paired device over loopback": localRequest(t, f.host.Handler(), "POST", path, f.token, nil),
	} {
		wantRouteError(t, label, w, 403, "local_only", "Only this Mac's AgentLand app can use this route")
	}

	// Explicit checks are spaced: one within plainAuthCheckEvery of the last
	// asks nothing, the next one after it asks again.
	tools.set(t, tools.codexStatus, "Not logged in\n")
	clock.Advance(plainAuthCheckEvery - time.Millisecond)
	check()
	if !codexSignedIn() {
		t.Fatal("a check within plainAuthCheckEvery asked the CLI again")
	}
	clock.Advance(time.Millisecond)
	check()
	if codexSignedIn() {
		t.Fatal("the check after plainAuthCheckEvery did not ask again")
	}
}

// Every Claude Code and Codex chat runs on a subscription, in a workspace as
// in the Chats space: creating, reading options, sending, regenerating and
// continuing are refused with the sign-in notice while the provider is signed
// in otherwise, and while it cannot run Chat at all. OpenCode's workspace
// chats are not affected.
func TestWorkspaceCLIChatsNeedASubscription(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)},
		Archive: openTestArchive(t, filepath.Join(t.TempDir(), "archive"), ArchiveOptions{})})
	tools := installWorkspaceChatTools(t, f)
	tools.set(t, tools.codexStatus, "Not logged in\n")
	clock := &testClock{now: time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)}
	f.host.plainChats.now = clock.Now
	advertisedChats(t, f)

	signIn := func(label, method, path string, body any, says string) {
		t.Helper()
		w := f.call(t, method, path, body)
		if w.Code != 400 || errorCode(t, w) != "agent_auth_required" || !strings.Contains(w.Body.String(), says) {
			t.Fatalf("%s: %d %s", label, w.Code, w.Body)
		}
	}
	signIn("codex create", "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "codex"}, "ChatGPT subscription")
	signIn("codex options", "GET", "/v1/chat/options?projectId=p1&provider=codex", nil, "ChatGPT subscription")
	signIn("codex continue", "POST", "/v1/chat/continue", map[string]string{"projectId": "p1", "sourceSessionId": "claude:" + strings.Repeat("a", 32), "provider": "codex"}, "ChatGPT subscription")
	w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude"})
	var chat Session
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &chat) != nil || chat.Title != "Claude Code" {
		t.Fatalf("claude create: %d %s", w.Code, w.Body)
	}

	// Claude Code switched to an API key: once the answer is stale, every
	// request for its chats says to sign in with the subscription.
	tools.set(t, tools.claudeStatus, `{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"/login managed key"}`)
	clock.Advance(plainAuthFresh + time.Second)
	advertisedChats(t, f)
	signIn("claude send", "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": chat.ID, "text": "Hello"}, "API key")
	signIn("claude regenerate", "POST", "/v1/chat/regenerate", map[string]string{"projectId": "p1", "sessionId": chat.ID}, "API key")
	signIn("claude options", "GET", "/v1/chat/options?projectId=p1&sessionId="+chat.ID, nil, "API key")
	signIn("claude create", "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude"}, "API key")

	// A provider that cannot run Chat at all (here: no longer installed).
	f.chats.codex = newCodexEngine(f.chats, codexEngineConfig{executable: func() (string, bool) { return "", false }})
	w = f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "codex"})
	if w.Code != 503 || errorCode(t, w) != "agent_unavailable" || !strings.Contains(w.Body.String(), "Codex") {
		t.Fatalf("codex create without codex: %d %s", w.Code, w.Body)
	}

	// OpenCode's workspace chats keep their own path.
	if w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1"}); w.Code != 201 {
		t.Fatalf("OpenCode create: %d %s", w.Code, w.Body)
	}
}

// Claude Code's modes in Chat (owner, 2026-10-12): Ask (default) first and
// the default, then Accept edits, Plan, Auto and Bypass permissions; every
// process may enter bypass (--allow-dangerously-skip-permissions), so a
// running chat switches into it and out again without a restart. Don't ask
// is no longer offered, but a chat that has it keeps it.
func TestClaudeBypassModeSwitches(t *testing.T) {
	f := newClaudeFixture(t, nil)
	// The first start lists the models for the options; the chat's process
	// is the second.
	f.script(1, step(map[string]any{"do": "init"}))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.001), textTurn("msg_2", "two", "", 0.001),
		textTurn("msg_3", "three", "", 0.001), textTurn("msg_4", "four", "", 0.001))
	var options ChatOptions
	if w := f.call("GET", "/v1/chat/options?projectId=p1&provider=claude", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &options) != nil {
		t.Fatalf("options: %d %s", w.Code, w.Body)
	}
	modes := []string{}
	for _, mode := range options.Modes {
		modes = append(modes, mode.ID+"="+mode.Name)
	}
	if strings.Join(modes, ",") != "default=Ask,acceptEdits=Accept edits,plan=Plan,auto=Auto,bypassPermissions=Bypass permissions" || options.DefaultMode != "default" {
		t.Fatalf("modes: %v, default %q", modes, options.DefaultMode)
	}

	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	session := argValue(f.argv(2), "--session-id")
	sameArgs(t, "first start", f.argv(2), claudeArgs("--permission-mode", "default", "--session-id", session))
	for _, mode := range []string{"bypassPermissions", "dontAsk", "default"} {
		f.mustSend(id, "in "+mode, map[string]any{"mode": mode})
		f.waitIdle(id)
		if got := f.chatMode(id); got != mode {
			t.Fatalf("mode after switching to %s: %s", mode, got)
		}
	}
	if f.started() != 2 {
		t.Fatalf("the switches restarted the process: %d starts", f.started())
	}
	switches := []string{}
	for _, frame := range f.frames(2) {
		if request, _ := frame["request"].(map[string]any); frame["type"] == "control_request" && request["subtype"] == "set_permission_mode" {
			switches = append(switches, request["mode"].(string))
		}
	}
	if strings.Join(switches, ",") != "bypassPermissions,dontAsk,default" {
		t.Fatalf("switches: %v", switches)
	}
	if w, _ := f.send(id, "unknown", map[string]any{"mode": "manual"}); w.Code != 400 {
		t.Fatalf("a mode Chat does not know: %d %s", w.Code, w.Body)
	}

	// A chat created in bypass starts in it.
	w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude", "mode": "bypassPermissions"})
	var created Session
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &created) != nil {
		t.Fatalf("create in bypass: %d %s", w.Code, w.Body)
	}
	f.script(3, step(map[string]any{"do": "init"}), textTurn("msg_6", "six", "", 0.001))
	f.mustSend(created.ID, "bypassed", nil)
	f.waitIdle(created.ID)
	if args := f.argv(f.started()); argValue(args, "--permission-mode") != "bypassPermissions" || !slices.Contains(args, "--allow-dangerously-skip-permissions") {
		t.Fatalf("start in bypass: %v", args)
	}
}

// Every Claude Code chat runs on the Claude subscription, in a workspace as
// in the Chats space: a process whose initialize answer names an API key ends
// before any prompt reaches it.
func TestWorkspaceClaudeChatRefusesAnAPIKeyAccount(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "control", "subtype": "initialize",
		"respond": json.RawMessage(`{"commands":[],"models":[],"account":{"apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"}}`)}))
	id := f.newChat()
	w, _ := f.send(id, "Hello", nil)
	if w.Code != 400 || errorCode(t, w) != "agent_auth_required" || !strings.Contains(w.Body.String(), "claude auth login") {
		t.Fatalf("send with an API key account: %d %s", w.Code, w.Body)
	}
	for _, frame := range f.frames(1) {
		if frame["type"] == "user" {
			t.Fatal("the prompt reached a process that uses an API key")
		}
	}
}

// A workspace Claude chat whose init line reports an API key is ended at
// once, and its turn says to sign in with the subscription.
func TestWorkspaceClaudeChatEndsWhenInitReportsAnAPIKey(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), step(map[string]any{"do": "user", "echo": true}),
		emit(`{"type":"system","subtype":"init","session_id":"$session","model":"claude-opus-5-5","permissionMode":"$mode","apiKeySource":"ANTHROPIC_API_KEY","uuid":"`+newClaudeUUID()+`"}`),
		step(map[string]any{"do": "hang"}))
	id := f.newChat()
	f.send(id, "Hello", nil)
	f.waitIdle(id)
	chat := f.chatState(id)
	chat.mu.Lock()
	loaded := chat.loadLocked(100)
	chat.mu.Unlock()
	last := loaded.messages[len(loaded.messages)-1]
	if last.Role != "assistant" || last.Status != "error" || last.Error == nil || last.Error.Code != "agent_auth_required" {
		t.Fatalf("reply: %+v %+v", last, last.Error)
	}
}

// legacyChatsSpaceChat is a Claude Code or Codex chat an older host made in
// the Chats space (before 2026-10-12), with one exchange.
func legacyChatsSpaceChat(t *testing.T, f *chatFixture, provider string) Session {
	t.Helper()
	id := provider + ":" + cliMessageID()
	home := f.host.plainChats.home
	session := Session{ID: id, Title: "Tides", ProjectID: plainChatsProjectID, Directory: home, Provider: provider, TitleSource: titleAuto}
	record := &cliChatRecord{Session: session, Directory: home, NativeID: "native-" + provider, UpdatedAt: time.Now(),
		Messages: []Message{{ID: "u-" + id, Role: "user", Text: "When is high tide in Lisbon?"}, {ID: "a-" + id, Role: "assistant", Text: "Around noon today."}}}
	f.chats.mu.Lock()
	f.chats.records[id] = record
	err := f.chats.saveLocked()
	f.chats.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	return session
}

// Chat runs in the workspaces (owner, 2026-10-12), so the Chats space's
// Claude Code and Codex chats stay readable but take nothing new: sending,
// regenerating, forking, rewinding, queueing, uploading, reading options and
// creating answer 503 agent_unavailable with why; what was queued stays
// queued and unsent; and no Claude Code or Codex process starts there,
// whatever asks.
func TestChatsSpaceCLIChatsAreReadOnly(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	for _, provider := range []string{"claude", "codex"} {
		chat := legacyChatsSpaceChat(t, f, provider)
		key := sessionKey{plainChatsProjectID, chat.ID}
		queued, err := f.queue.add(key, "Queued before the update", PromptOptions{})
		if err != nil {
			t.Fatal(err)
		}

		// Reading and listing keep working.
		if w := f.call(t, "GET", "/v1/sessions?projectId=chats", nil); w.Code != 200 || !strings.Contains(w.Body.String(), chat.ID) {
			t.Fatalf("%s list: %d %s", provider, w.Code, w.Body)
		}
		if w := f.call(t, "GET", "/v1/messages?projectId=chats&sessionId="+chat.ID, nil); w.Code != 200 || !strings.Contains(w.Body.String(), "Around noon today.") {
			t.Fatalf("%s read: %d %s", provider, w.Code, w.Body)
		}

		refused := func(label string, w *httptest.ResponseRecorder) {
			t.Helper()
			if w.Code != 503 || errorCode(t, w) != "agent_unavailable" || !strings.Contains(w.Body.String(), chatsSpaceRetiredMessage) {
				t.Fatalf("%s %s: %d %s", provider, label, w.Code, w.Body)
			}
		}
		refused("send", f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat.ID, "text": "And tomorrow?"}))
		refused("regenerate", f.call(t, "POST", "/v1/chat/regenerate", map[string]string{"projectId": "chats", "sessionId": chat.ID}))
		refused("fork", f.call(t, "POST", "/v1/chat/fork", map[string]string{"projectId": "chats", "sessionId": chat.ID}))
		refused("rewind", f.call(t, "POST", "/v1/messages/rewind", map[string]string{"projectId": "chats", "sessionId": chat.ID, "messageId": "u-" + chat.ID}))
		refused("queue", f.call(t, "POST", "/v1/queue", map[string]string{"projectId": "chats", "sessionId": chat.ID, "text": "Later"}))
		refused("options", f.call(t, "GET", "/v1/chat/options?projectId=chats&sessionId="+chat.ID, nil))
		refused("create", f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "chats", "provider": provider}))
		upload := httptest.NewRequest("POST", "/v1/attachments?projectId=chats&sessionId="+chat.ID+"&name=note.txt", strings.NewReader("hello"))
		upload.Header.Set("Content-Type", "text/plain")
		upload.Header.Set("Authorization", "Bearer "+f.token)
		w := httptest.NewRecorder()
		f.host.Handler().ServeHTTP(w, upload)
		refused("upload", w)

		// What was queued before stays queued, unsent, and can be removed.
		f.clock.Advance(queueSettleTimeout)
		f.host.dispatchNext(key)
		if items := f.queue.Items(plainChatsProjectID, chat.ID); len(items) != 1 || items[0].Status != "queued" {
			t.Fatalf("%s queue after dispatch: %+v", provider, items)
		}
		if w := f.call(t, "POST", "/v1/queue/remove", map[string]string{"projectId": "chats", "sessionId": chat.ID, "itemId": queued.ID}); w.Code != 200 {
			t.Fatalf("%s queue remove: %d %s", provider, w.Code, w.Body)
		}
	}
	f.runner.mu.Lock()
	ran := len(f.runner.calls)
	f.runner.mu.Unlock()
	if ran != 0 {
		t.Fatalf("a Chats-space chat ran %d times", ran)
	}

	// Below the routes: the engines start nothing in the Chats space.
	space := f.host.plainChats.project()
	if _, err := f.chats.CreateSession(space, "", "claude"); !errors.Is(err, errChatsSpaceRetired) {
		t.Fatalf("CreateSession: %v", err)
	}
	installWorkspaceChatTools(t, f)
	claude, codex := legacyChatsSpaceChat(t, f, "claude"), legacyChatsSpaceChat(t, f, "codex")
	chat, err := f.chats.claude.chat(space, claude.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := chat.send(chatPrompt{text: "Hello"}); !errors.Is(err, errChatsSpaceRetired) {
		t.Fatalf("Claude Code send: %v", err)
	}
	if _, err := chat.spawn(claudeSettings{mode: "default"}, ""); !errors.Is(err, errChatsSpaceRetired) {
		t.Fatalf("Claude Code process: %v", err)
	}
	if _, err := f.chats.claude.fork(space, chat, "", "Fork"); !errors.Is(err, errChatsSpaceRetired) {
		t.Fatalf("Claude Code fork: %v", err)
	}
	if err := f.chats.PromptAs(space, codex.ID, cliMessageID(), "Hello", PromptOptions{}, nil, nil); !errors.Is(err, errChatsSpaceRetired) {
		t.Fatalf("Codex send: %v", err)
	}
	if _, err := f.chats.codex.fork(space, codex, "", "Fork"); !errors.Is(err, errChatsSpaceRetired) {
		t.Fatalf("Codex fork: %v", err)
	}
	if len(f.chats.claude.procs) != 0 {
		t.Fatalf("Claude Code processes: %d", len(f.chats.claude.procs))
	}
}

// A Chats-space chat (Claude Code, Codex or OpenCode) continues in a
// workspace's Claude Code or Codex chat, with the conversation as the new
// chat's context: the new chat is made, nothing is sent until the user
// sends, and the first message carries the context. Into the Chats space,
// or with another provider, it is still refused.
func TestContinueChatsSpaceChatIntoWorkspace(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{Archive: openTestArchive(t, filepath.Join(t.TempDir(), "archive"), ArchiveOptions{})})
	f.host.plainChats.mu.Lock()
	f.host.plainChats.cliProviders = []plainChatProvider{{ID: "claude", Name: "Claude Code", Tools: []string{}, Features: []string{}}, {ID: "codex", Name: "Codex", Tools: []string{}, Features: []string{}}}
	f.host.plainChats.mu.Unlock()
	archive := f.host.archive
	sources := map[string]string{}
	for _, provider := range []string{"claude", "codex", "opencode"} {
		id := "ses_tides"
		if provider != "opencode" {
			id = legacyChatsSpaceChat(t, f, provider).ID
		}
		sources[provider] = id
		if err := archive.UpsertChat(ArchiveChat{ID: id, ProjectID: plainChatsProjectID, Provider: provider, Title: "Tides", CreatedAt: f.clock.Now()}); err != nil {
			t.Fatal(err)
		}
		// The CLI chats' messages reach the archive from their records when
		// they are continued (refreshArchivedChat, in the Chats space).
		if provider == "opencode" {
			mustArchiveMessage(t, archive, textMessage(id, "m1", "user", 1, "When is high tide in Lisbon?"))
			mustArchiveMessage(t, archive, textMessage(id, "m2", "assistant", 2, "Around noon today."))
		}
	}
	flushArchive(t, archive)

	for _, refused := range []struct {
		body   map[string]string
		status int
		code   string
	}{
		{map[string]string{"projectId": "p1", "sourceSessionId": sources["claude"], "provider": "opencode"}, 400, plainChatScopeCode},
		{map[string]string{"projectId": "chats", "sourceSessionId": sources["claude"], "provider": "claude"}, 503, "agent_unavailable"},
		{map[string]string{"projectId": "chats", "sourceSessionId": sources["codex"], "provider": "codex"}, 503, "agent_unavailable"},
	} {
		if w := f.call(t, "POST", "/v1/chat/continue", refused.body); w.Code != refused.status || errorCode(t, w) != refused.code {
			t.Fatalf("continue %v: %d %s", refused.body, w.Code, w.Body)
		}
	}

	project, err := f.host.project("p1")
	if err != nil {
		t.Fatal(err)
	}
	runs := func() []fakeCLIChatCall {
		f.runner.mu.Lock()
		defer f.runner.mu.Unlock()
		return slices.Clone(f.runner.calls)
	}
	for _, continued := range []struct{ source, provider string }{{"claude", "claude"}, {"codex", "codex"}, {"opencode", "claude"}} {
		before := len(runs())
		w := f.call(t, "POST", "/v1/chat/continue", map[string]string{"projectId": "p1", "sourceSessionId": sources[continued.source], "provider": continued.provider})
		var response continueResponse
		if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &response) != nil {
			t.Fatalf("continue %s with %s: %d %s", continued.source, continued.provider, w.Code, w.Body)
		}
		chat := response.Session
		if chat.ProjectID != "p1" || chat.Provider != continued.provider || chat.ParentSessionID != sources[continued.source] || response.Seed.Included != 2 {
			t.Fatalf("continued %s: %+v %+v", continued.source, chat, response.Seed)
		}
		// Continuing sends nothing; the user's first message carries the
		// conversation, in the workspace.
		if len(runs()) != before {
			t.Fatalf("continuing %s sent: %+v", continued.source, runs())
		}
		if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": chat.ID, "text": "And tomorrow?"}); w.Code != 202 {
			t.Fatalf("first message: %d %s", w.Code, w.Body)
		}
		waitFor(t, "the first message's run", func() bool { return len(runs()) == before+1 })
		run := runs()[before]
		if run.Provider != continued.provider || !sameDirectory(run.Directory, project.Directory) || !strings.HasPrefix(run.Prompt, "Context from an earlier chat") || !strings.Contains(run.Prompt, "Around noon today.") || !strings.HasSuffix(run.Prompt, "And tomorrow?") {
			t.Fatalf("first message of the continued %s chat: %+v", continued.source, run)
		}
	}
}
