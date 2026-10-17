package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestPlainChatProviderRouting(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.chats.claude = newClaudeEngine(f.chats, claudeConfig{executable: func() (string, bool) { return "", false }})
	f.host.plainChats.cliProviders = []plainChatProvider{{ID: "claude", Name: "Claude", Tools: []string{}, Features: []string{"events"}}}
	capability := f.host.plainChats.workspaceCapability()
	if capability == nil || len(capability.Providers) != 1 || capability.Providers[0].ID != "claude" {
		t.Fatalf("independent capability: %+v", capability)
	}
	// Clients from before the provider list read plainChats as "OpenCode
	// runs plain chats": without OpenCode they must not see it. General Chat
	// lists no provider; Claude Code is Chat in the workspaces.
	var advertised struct {
		General   *plainChatsCapability     `json:"generalChats"`
		Legacy    *plainChatsCapability     `json:"plainChats"`
		Workspace *workspaceChatsCapability `json:"workspaceChats"`
	}
	if w := f.call(t, "GET", "/v1/capabilities", nil); w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &advertised) != nil {
		t.Fatalf("capabilities: %d %s", w.Code, w.Body)
	}
	if advertised.Legacy != nil || advertised.General == nil || len(advertised.General.Providers) != 0 || advertised.Workspace == nil || len(advertised.Workspace.Providers) != 1 || advertised.Workspace.Providers[0].ID != "claude" {
		t.Fatalf("advertised without OpenCode: general %+v, legacy %+v, workspace %+v", advertised.General, advertised.Legacy, advertised.Workspace)
	}
	// The Chats space makes no Claude Code or Codex chats any more; the
	// ones an older host made there are still listed without OpenCode.
	legacy := legacyChatsSpaceChat(t, f, "claude")
	f.oc.server.Close()
	w := f.call(t, "GET", "/v1/sessions?projectId=chats", nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), legacy.ID) {
		t.Fatalf("list without OpenCode: %d %s", w.Code, w.Body)
	}
	for _, provider := range []string{"shell", "unknown", "codex", "claude"} {
		w = f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "chats", "provider": provider})
		if w.Code == 201 {
			t.Fatalf("accepted unsupported %s", provider)
		}
	}
}

// A runtime's version is checked once per installed file, and a check that
// does not answer keeps the last answer instead of dropping the provider.
func TestPlainChatRuntimeVersionCheck(t *testing.T) {
	folder := t.TempDir()
	runs, executable := filepath.Join(folder, "runs"), filepath.Join(folder, "claude")
	install := func(version string) {
		t.Helper()
		answer := `echo "` + version + ` (Claude Code)"`
		if version == "" {
			answer = "exit 1"
		}
		script := "#!/bin/sh\necho run >> '" + runs + "'\n" + answer + "\n"
		if err := os.WriteFile(executable, []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	count := func() int {
		data, _ := os.ReadFile(runs)
		return strings.Count(string(data), "run")
	}
	c := &plainChats{}
	ctx := t.Context()
	supported := func(path string) bool {
		ok, _ := c.runtimeSupported(ctx, "claude", path)
		return ok
	}
	install("2.1.300")
	if !supported(executable) || !supported(executable) || count() != 1 {
		t.Fatalf("unchanged runtime: %d checks", count())
	}
	install("") // an update in progress, or a check that times out
	if ok, version := c.runtimeSupported(ctx, "claude", executable); !ok || version != "2.1.300" || !supported(executable) || count() != 3 {
		t.Fatalf("failed check dropped the provider or was not retried: %d checks", count())
	}
	install("2.0.1-older")
	if ok, version := c.runtimeSupported(ctx, "claude", executable); ok || version != "2.0.1-older" || supported(executable) || count() != 4 {
		t.Fatalf("unsupported update: %v %q, %d checks", ok, version, count())
	}
	if ok, version := (&plainChats{}).runtimeSupported(ctx, "claude", filepath.Join(folder, "missing")); ok || version != "" {
		t.Fatal("missing runtime supported, or a version named for it")
	}
}

// Chat takes Codex 0.162.0 and every later 0.x release (owner, 2026-10-16,
// after 0.163.0 was checked), and Claude Code 2.1.295 and every later 2.x
// release (owner, 2026-10-17).
func TestPlainVersionSupported(t *testing.T) {
	for _, test := range []struct {
		provider, version string
		supported         bool
	}{
		{"codex", "0.161.9", false}, {"codex", "0.162.0", true}, {"codex", "0.162.1", true}, {"codex", "0.163.0", true},
		{"codex", "0.170.2", true}, {"codex", "0.999.0", true}, {"codex", "1.0.0", false}, {"codex", "2.163.0", false},
		{"codex", "0.156.1", false}, {"codex", "0.163", false}, {"codex", "0.163.0-alpha.1", false}, {"codex", "0.+163.0", false},
		{"codex", "0.163.x", false}, {"codex", "codex-cli", false}, {"codex", "", false},
		{"claude", "2.1.294", false}, {"claude", "2.1.295", true}, {"claude", "2.1.300", true}, {"claude", "2.1.302", true},
		{"claude", "2.2.0", true}, {"claude", "2.10.3", true}, {"claude", "2.0.999", false}, {"claude", "1.9.400", false},
		{"claude", "3.0.0", false}, {"claude", "3.1.295", false}, {"claude", "2.1", false}, {"claude", "2.1.296-beta.1", false},
		{"claude", "2.+2.0", false}, {"claude", "v2.2.0", false}, {"claude", "2.1.302 (Claude Code)", false}, {"claude", "junk", false},
		{"claude", "", false}, {"claude", "0.163.0", false},
		{"opencode", "0.163.0", false},
	} {
		if got := plainVersionSupported(test.provider, test.version); got != test.supported {
			t.Errorf("%s %q: %v", test.provider, test.version, got)
		}
	}
}

// An installed Claude Code or Codex in a version Chat does not support is
// listed as unavailable with why, instead of vanishing, and its sign-in is
// not asked; requests for it are refused as unavailable, never with the
// sign-in notice. Back on a supported version it is offered again.
func TestUnsupportedCLIVersionIsListedWithWhy(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)}})
	tools := installWorkspaceChatTools(t, f)
	folder := t.TempDir()
	codex, runs := filepath.Join(folder, "codex"), filepath.Join(folder, "runs")
	install := func(version string) {
		t.Helper()
		// A new file each time, so the version check runs again.
		os.Remove(codex)
		tools.set(t, codex, fakeAuthCLI("codex", "codex-cli "+version, tools.codexStatus, runs))
		if err := os.Chmod(codex, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	install("1.0.0")
	f.chats.codex = newCodexEngine(f.chats, codexEngineConfig{executable: func() (string, bool) { return codex, true }})
	clock := &testClock{now: time.Date(2026, 10, 16, 9, 0, 0, 0, time.UTC)}
	f.host.plainChats.now = clock.Now

	advertised := advertisedChats(t, f)
	codexOut := `{"id":"codex","name":"Codex","tools":[],"features":[],"auth":{"kind":"unknown","label":"Version not supported","reason":"version_unsupported","message":"AgentLand’s Chat doesn’t support Codex 1.0.0 yet. Use Codex in Terminal."}}`
	var workspace workspaceChatsCapability
	if json.Unmarshal(advertised["workspaceChats"], &workspace) != nil || len(workspace.Providers) != 1 || workspace.Providers[0].ID != "claude" ||
		!strings.Contains(string(advertised["workspaceChats"]), `"unavailableProviders":[`+codexOut+`]`) {
		t.Fatalf("workspaceChats with Codex 1.0.0: %s", advertised["workspaceChats"])
	}
	if data, _ := os.ReadFile(runs); len(data) != 0 {
		t.Fatalf("the sign-in of an unsupported version was asked: %q", data)
	}
	for _, request := range []struct {
		method, path string
		body         any
	}{
		{"POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "codex"}},
		{"GET", "/v1/chat/options?projectId=p1&provider=codex", nil},
	} {
		w := f.call(t, request.method, request.path, request.body)
		if w.Code != 503 || errorCode(t, w) != "agent_unavailable" || !strings.Contains(w.Body.String(), "Codex 1.0.0") || strings.Contains(w.Body.String(), "Sign in") {
			t.Fatalf("%s %s with Codex 1.0.0: %d %s", request.method, request.path, w.Code, w.Body)
		}
	}

	// A version whose output does not look like one is not repeated.
	install("0.163.0\x1b[0m")
	advertised = advertisedChats(t, f)
	if !strings.Contains(string(advertised["workspaceChats"]), "doesn’t support this version of Codex yet.") {
		t.Fatalf("workspaceChats with an odd version: %s", advertised["workspaceChats"])
	}

	// Codex 0.163.0 runs Chat: its sign-in is asked, and it is offered.
	install("0.163.0")
	advertised = advertisedChats(t, f)
	if json.Unmarshal(advertised["workspaceChats"], &workspace) != nil || len(workspace.Providers) != 2 || workspace.Providers[1].ID != "codex" || len(workspace.UnavailableProviders) != 0 {
		t.Fatalf("workspaceChats with Codex 0.163.0: %s", advertised["workspaceChats"])
	}
	if data, _ := os.ReadFile(runs); strings.Count(string(data), "\n") != 1 {
		t.Fatalf("sign-in checks: %q", data)
	}
	if w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "codex"}); w.Code != 201 {
		t.Fatalf("codex create on 0.163.0: %d %s", w.Code, w.Body)
	}

	// Without a version a check could read, an installed runtime stays left
	// out, as before.
	f.chats.codex = newCodexEngine(f.chats, codexEngineConfig{executable: func() (string, bool) { return "/bin/false", true }})
	f.host.plainChats.providersMu.Lock()
	delete(f.host.plainChats.versions, "codex")
	f.host.plainChats.providersMu.Unlock()
	advertised = advertisedChats(t, f)
	if json.Unmarshal(advertised["workspaceChats"], &workspace) != nil || len(workspace.Providers) != 1 || len(workspace.UnavailableProviders) != 0 {
		t.Fatalf("workspaceChats without a readable version: %s", advertised["workspaceChats"])
	}
}

// Claude Code takes the same rule as Codex (owner, 2026-10-17): a later 2.x
// release runs Chat, and 3.x is listed as unavailable with why, in Claude
// Code's name, without its sign-in being asked.
func TestClaudeCodeLater2xRunsChatAnd3xSaysWhy(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: plainStateFolder(t)}})
	tools := installWorkspaceChatTools(t, f)
	folder := t.TempDir()
	claude, runs := filepath.Join(folder, "claude"), filepath.Join(folder, "runs")
	install := func(version string) {
		t.Helper()
		os.Remove(claude)
		tools.set(t, claude, fakeAuthCLI("claude", version+" (Claude Code)", tools.claudeStatus, runs))
		if err := os.Chmod(claude, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	f.chats.claude = newClaudeEngine(f.chats, claudeConfig{executable: func() (string, bool) { return claude, true }})
	f.host.plainChats.now = (&testClock{now: time.Date(2026, 10, 17, 9, 0, 0, 0, time.UTC)}).Now

	install("3.0.0")
	advertised := advertisedChats(t, f)
	claudeOut := `{"id":"claude","name":"Claude Code","tools":[],"features":[],"auth":{"kind":"unknown","label":"Version not supported","reason":"version_unsupported","message":"AgentLand’s Chat doesn’t support Claude Code 3.0.0 yet. Use Claude Code in Terminal."}}`
	var workspace workspaceChatsCapability
	if json.Unmarshal(advertised["workspaceChats"], &workspace) != nil || len(workspace.Providers) != 1 || workspace.Providers[0].ID != "codex" ||
		!strings.Contains(string(advertised["workspaceChats"]), `"unavailableProviders":[`+claudeOut+`]`) {
		t.Fatalf("workspaceChats with Claude Code 3.0.0: %s", advertised["workspaceChats"])
	}
	if data, _ := os.ReadFile(runs); len(data) != 0 {
		t.Fatalf("the sign-in of an unsupported version was asked: %q", data)
	}

	install("2.2.0")
	advertised = advertisedChats(t, f)
	if json.Unmarshal(advertised["workspaceChats"], &workspace) != nil || len(workspace.Providers) != 2 || workspace.Providers[0].ID != "claude" || len(workspace.UnavailableProviders) != 0 {
		t.Fatalf("workspaceChats with Claude Code 2.2.0: %s", advertised["workspaceChats"])
	}
}

// A provider the last check left out is checked again before a request is
// refused.
func TestPlainChatProviderRecheckedOnDemand(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	executable := filepath.Join(t.TempDir(), "claude")
	if err := os.WriteFile(executable, []byte(fakeSignedInCLI("claude", "2.1.300 (Claude Code)")), 0700); err != nil {
		t.Fatal(err)
	}
	f.chats.claude = newClaudeEngine(f.chats, claudeConfig{executable: func() (string, bool) { return executable, true }})
	f.host.plainChats.mu.Lock()
	f.host.plainChats.cliProviders = nil
	f.host.plainChats.mu.Unlock()
	if w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude"}); w.Code != 201 {
		t.Fatalf("workspace create after a missed check: %d %s", w.Code, w.Body)
	}
	if capability := f.host.plainChats.workspaceCapability(); capability == nil || !slices.ContainsFunc(capability.Providers, func(p plainChatProvider) bool { return p.ID == "claude" }) {
		t.Fatalf("recheck not published: %+v", capability)
	}
}

// Explicitly opt in: sends two tiny real prompts through the installed
// sign-ins, in a disposable workspace (Chat runs in the workspaces).
func TestPlainChatExistingSignIns(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_CHAT_SIGN_INS") != "1" {
		t.Skip("set AGENTLAND_TEST_CHAT_SIGN_INS=1; uses installed accounts")
	}
	cli, err := NewCLIChats(filepath.Join(t.TempDir(), "chats.json"), HostCLIChatRunner{})
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	p := Project{ID: "verification", Directory: t.TempDir()}
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			session, err := cli.CreateSession(p, "AgentLand Chat verification", provider)
			if err != nil {
				t.Fatal(err)
			}
			prompt := "Reply with exactly: AgentLand chat connected."
			done := make(chan struct{})
			if provider == "claude" {
				chat, err := cli.claude.chat(p, session.ID)
				if err != nil {
					t.Fatal(err)
				}
				_, err = chat.send(chatPrompt{text: prompt, finished: func() { close(done) }})
				if err != nil {
					t.Fatal(err)
				}
			} else {
				if err := cli.codex.prompt(p, session.ID, cliMessageID(), prompt, PromptOptions{}, nil, func() { close(done) }); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case <-done:
			case <-time.After(50 * time.Second):
				t.Fatal("reply timed out")
			}
			messages, err := cli.Messages(p, session.ID)
			if err != nil {
				t.Fatal(err)
			}
			if len(messages) < 2 {
				t.Fatal("no assistant response")
			}
			last := messages[len(messages)-1]
			if last.Error != "" {
				t.Fatal(last.Error)
			}
			if !strings.Contains(last.Text, "AgentLand chat connected") {
				t.Fatalf("unexpected reply: %q", last.Text)
			}
		})
	}
}
