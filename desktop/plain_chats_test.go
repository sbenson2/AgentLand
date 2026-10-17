package host

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

// Plain chats (docs/HOST-API.md "Plain chats"): the Chats space, its folder
// and OpenCode configuration, the check of the chat agent, and the chat agent
// on every path a prompt takes. OpenCode is the fake of chat_fixture_test.go,
// which serves the workspace and the Chats space.

// plainStateFolder is a private state folder with a short path, so the
// memory socket beside the state file fits a Unix socket's path.
func plainStateFolder(t *testing.T) string {
	t.Helper()
	base := ""
	if len(os.TempDir()) > 60 {
		base = "/tmp"
	}
	folder, err := os.MkdirTemp(base, "al-pc")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(folder, 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	return folder
}

// servePlainChatRoutes answers what the host asks OpenCode about the Chats
// space: its agents, its MCP servers, its tools and settings.
func (f *fakeOpenCode) servePlainChatRoutes(w http.ResponseWriter, r *http.Request, directory string) bool {
	if r.Method == "POST" && r.URL.Path == "/instance/dispose" {
		// A held disposal counts as asked for and does nothing.
		f.mu.Lock()
		gate := f.disposeGate
		if gate != nil {
			f.disposals++
		}
		f.mu.Unlock()
		if gate != nil {
			select {
			case <-gate:
			case <-r.Context().Done():
			}
			return true
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.Method == "GET" && r.URL.Path == "/agent":
		agents := f.agentLists[directory]
		if agents == nil {
			agents = []map[string]any{{"name": "build", "mode": "primary"}}
		}
		json.NewEncoder(w).Encode(agents)
	case r.Method == "GET" && r.URL.Path == "/mcp":
		servers := map[string]any{}
		for name, status := range f.mcpStatus {
			servers[name] = map[string]string{"status": status}
		}
		json.NewEncoder(w).Encode(servers)
	case r.Method == "GET" && r.URL.Path == "/experimental/tool":
		f.toolQueries = append(f.toolQueries, r.URL.RawQuery)
		tools := []map[string]any{}
		for _, id := range f.toolIDs {
			tools = append(tools, map[string]any{"id": id, "description": id, "parameters": map[string]any{"type": "object"}})
		}
		json.NewEncoder(w).Encode(tools)
	case r.Method == "GET" && r.URL.Path == "/config":
		json.NewEncoder(w).Encode(map[string]any{"model": f.configModel})
	case r.Method == "GET" && r.URL.Path == "/path":
		json.NewEncoder(w).Encode(map[string]string{"home": f.pathHome, "state": "/state", "config": f.pathConfig, "worktree": "/", "directory": directory})
	case r.Method == "POST" && r.URL.Path == "/instance/dispose":
		f.disposals++
		f.disposeDirs = append(f.disposeDirs, r.URL.Query().Get("directory"))
		if f.disposeCode != 0 {
			http.Error(w, "dispose failed", f.disposeCode)
			return true
		}
		if agents, ok := f.reloadedAgents[directory]; ok {
			f.agentLists[directory] = agents
		}
		w.Write([]byte("true"))
	case r.Method == "POST" && strings.HasPrefix(r.URL.Path, "/mcp/") && strings.HasSuffix(r.URL.Path, "/connect"):
		name := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/mcp/"), "/connect")
		f.mcpConnects = append(f.mcpConnects, name+" "+r.URL.Query().Get("directory"))
		if f.connectCode != 0 {
			http.Error(w, "connect failed", f.connectCode)
			return true
		}
		status := f.connectStatus
		if status == "" {
			status = "connected"
		}
		f.mcpStatus[name] = status
		w.Write([]byte("true"))
	case r.Method == "GET" && r.URL.Path == "/provider":
		json.NewEncoder(w).Encode(map[string]any{"all": []any{map[string]any{"id": "fake", "name": "Fake", "models": map[string]any{"fast": map[string]any{"id": "fast", "name": "Fast", "limit": map[string]int{"context": 1000}}}}}, "connected": []string{"fake"}})
	default:
		return false
	}
	return true
}

// plainChatAgents is GET /agent for the Chats space with AgentLand's agent.
func plainChatAgents() []map[string]any {
	return []map[string]any{{"name": "build", "mode": "primary"}, {"name": plainChatAgent, "mode": "primary", "prompt": plainChatPersona}}
}

// newPlainChatFixture is a chat fixture with plain chats, in a short state
// folder, whose fake OpenCode serves the Chats space with AgentLand's chat
// agent, its tool server connected and web search on. Nothing is confirmed
// until a test checks the chat agent (confirmPlainChats).
func newPlainChatFixture(t *testing.T, options HostOptions) *chatFixture {
	t.Helper()
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	folder := plainStateFolder(t)
	store := NewStore(filepath.Join(folder, "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Fixture", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	f := &chatFixture{store: store, oc: oc, runner: &fakeCLIChatRunner{}, clock: &testClock{now: time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)}}
	var err error
	if f.attachments, err = NewAttachmentStore(store.Path + ".attachments"); err != nil {
		t.Fatal(err)
	}
	f.queuePath = store.Path + ".queue.json"
	if f.queue, err = NewPromptQueue(f.queuePath); err != nil {
		t.Fatal(err)
	}
	f.chatsPath = store.Path + ".chats.json"
	if f.chats, err = NewCLIChats(f.chatsPath, f.runner); err != nil {
		t.Fatal(err)
	}
	f.attachments.now, f.queue.now = f.clock.Now, f.clock.Now
	options.CLIChats, options.Attachments, options.Queue = f.chats, f.attachments, f.queue
	if options.PlainChats == nil {
		options.PlainChats = &PlainChatOptions{Executable: "/Applications/AgentLand.app/Contents/MacOS/agentland-host", Home: folder, OpenCode: true}
	}
	f.host = newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), options)
	t.Cleanup(func() { f.host.Close() })
	home := f.host.plainChats.home
	oc.set(func(o *fakeOpenCode) {
		o.homes[home] = true
		o.agentLists[home] = plainChatAgents()
		o.mcpStatus[plainChatServer] = "connected"
		o.toolIDs = []string{"invalid", "bash", "read", "webfetch", "websearch"}
	})
	f.token = paired(t, f.host, store)
	return f
}

func (f *chatFixture) confirmPlainChats(t *testing.T) {
	t.Helper()
	if !f.host.plainChats.refresh(t.Context()) {
		t.Fatal("the chat agent was not confirmed")
	}
}

// plainChat creates a plain chat and returns its ID.
func (f *chatFixture) plainChat(t *testing.T) string {
	t.Helper()
	w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": plainChatsProjectID, "title": "Plain"})
	if w.Code != 201 {
		t.Fatalf("create a plain chat: %d %s", w.Code, w.Body.String())
	}
	var session Session
	json.Unmarshal(w.Body.Bytes(), &session)
	if session.ProjectID != plainChatsProjectID {
		t.Fatalf("a plain chat in %q", session.ProjectID)
	}
	return session.ID
}

// lastPrompt is the newest prompt OpenCode received.
func (f *chatFixture) lastPrompt(t *testing.T) map[string]any {
	t.Helper()
	bodies := f.oc.promptBodies()
	if len(bodies) == 0 {
		t.Fatal("OpenCode received no prompt")
	}
	var body map[string]any
	if err := json.Unmarshal(bodies[len(bodies)-1], &body); err != nil {
		t.Fatal(err)
	}
	return body
}

func TestPlainChatFolderHoldsItsOwnOpenCodeConfiguration(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	home := f.host.plainChats.home
	if home != f.store.Path+".chat-home" {
		t.Fatalf("the Chats space's folder is %s", home)
	}
	info, err := os.Stat(home)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		t.Fatalf("folder %v %v", info.Mode(), err)
	}
	path := filepath.Join(home, "opencode.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0600 {
		t.Fatalf("opencode.json is %v", info.Mode())
	}
	persona, _ := json.Marshal(plainChatPersona)
	executable, _ := json.Marshal("/Applications/AgentLand.app/Contents/MacOS/agentland-host")
	state, _ := json.Marshal(f.store.Path)
	want := fmt.Sprintf(`{
  "$schema": "https://opencode.ai/config.json",
  "default_agent": "chat",
  "permission": {
    "*": "deny"
  },
  "agent": {
    "chat": {
      "mode": "primary",
      "steps": 12,
      "prompt": %s,
      "permission": {
        "*": "deny",
        "invalid": "allow",
        "websearch": "allow",
        "agentland_fetch": "allow",
        "agentland_memory_save": "allow",
        "agentland_memory_forget": "allow"
      }
    }
  },
  "mcp": {
    "agentland": {
      "type": "local",
      "command": [
        %s,
        "chat-tools",
        "--state",
        %s
      ],
      "environment": {
        "OPENCODE_SERVER_PASSWORD": ""
      },
      "timeout": 120000
    }
  }
}
`, persona, executable, state)
	if string(data) != want {
		t.Fatalf("opencode.json\n%s\nwant\n%s", data, want)
	}
	// A checked configuration is left alone.
	f.confirmPlainChats(t)
	f.oc.mu.Lock()
	unchanged := f.oc.disposals
	f.oc.mu.Unlock()
	if unchanged != 0 {
		t.Fatal("OpenCode was told to reload an unchanged configuration")
	}
	// One that differs is written again, atomically and 0600, and OpenCode
	// reloads the folder.
	if err := os.WriteFile(path, []byte(`{"permission":"allow"}`), 0644); err != nil {
		t.Fatal(err)
	}
	f.confirmPlainChats(t)
	if again, _ := os.ReadFile(path); string(again) != want {
		t.Fatalf("not rewritten:\n%s", again)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0600 {
		t.Fatalf("rewritten as %v", info.Mode())
	}
	f.oc.mu.Lock()
	disposals, named := f.oc.disposals, slices.Clone(f.oc.disposeDirs)
	f.oc.mu.Unlock()
	// The disposal names the folder in its query too.
	if disposals != 1 || !reflect.DeepEqual(named, []string{f.host.plainChats.home}) {
		t.Fatalf("%d disposals, for %v", disposals, named)
	}
}

// OpenCode 1.18.31 writes "$schema" into a configuration file without one
// as it loads it. The host found that file changed at every check, wrote its
// own again and had OpenCode dispose of the folder's instance, which stopped
// every plain-chat turn running then, once a minute (B-15: a message sent
// after Stop seemed stopped too). A file that says what the host wants, in any
// layout, with or without "$schema", is left alone; a setting that differs,
// rule order included, is still replaced and reloaded.
func TestPlainChatConfigurationOpenCodeRewroteIsLeftAlone(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.confirmPlainChats(t)
	path := filepath.Join(f.host.plainChats.home, plainChatConfigName)
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	const schemaLine = "  \"$schema\": \"https://opencode.ai/config.json\",\n"
	if !strings.HasPrefix(string(want), "{\n"+schemaLine) {
		t.Fatalf("the host's configuration does not name OpenCode's schema first:\n%s", want)
	}
	var settings map[string]json.RawMessage
	if err := json.Unmarshal(want, &settings); err != nil {
		t.Fatal(err)
	}
	withoutSchema := strings.Replace(string(want), schemaLine, "", 1)
	var compact strings.Builder
	compact.WriteString("{")
	for index, key := range []string{"mcp", "agent", "permission", "default_agent"} {
		if index > 0 {
			compact.WriteString(",")
		}
		name, _ := json.Marshal(key)
		compact.Write(name)
		compact.WriteString(":")
		// Marshalling raw JSON compacts it.
		value, err := json.Marshal(settings[key])
		if err != nil {
			t.Fatal(err)
		}
		compact.Write(value)
	}
	compact.WriteString("}")
	cases := []struct{ name, written string }{
		// What OpenCode left of the configuration of a host from before this fix.
		{"no $schema", withoutSchema},
		{"OpenCode's $schema added", "{\n" + schemaLine + strings.TrimPrefix(withoutSchema, "{\n")},
		{"another layout and order of settings", compact.String()},
	}
	for _, c := range cases {
		if err := os.WriteFile(path, []byte(c.written), 0600); err != nil {
			t.Fatal(err)
		}
		f.confirmPlainChats(t)
		if got, _ := os.ReadFile(path); string(got) != c.written {
			t.Fatalf("%s: rewritten:\n%s", c.name, got)
		}
		if n := f.disposals(); n != 0 {
			t.Fatalf("%s: OpenCode was told %d times to dispose of the folder's instance for the same configuration", c.name, n)
		}
	}
	// The chat agent's rules in another order are another configuration.
	reordered := strings.Replace(string(want), "\"agentland_memory_save\": \"allow\",\n        \"agentland_memory_forget\": \"allow\"",
		"\"agentland_memory_forget\": \"allow\",\n        \"agentland_memory_save\": \"allow\"", 1)
	if reordered == string(want) {
		t.Fatal("the rules to reorder were not found")
	}
	if err := os.WriteFile(path, []byte(reordered), 0600); err != nil {
		t.Fatal(err)
	}
	f.confirmPlainChats(t)
	if got, _ := os.ReadFile(path); string(got) != string(want) {
		t.Fatalf("rules in another order were not replaced:\n%s", got)
	}
	if n := f.disposals(); n != 1 {
		t.Fatalf("%d disposals after a configuration that differs", n)
	}
}

// A configuration replaced at start (a host update, while OpenCode keeps its
// instance for the folder) reaches OpenCode at the first check.
func TestPlainChatConfigReplacedAtStartIsReloaded(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.confirmPlainChats(t)
	path := filepath.Join(f.host.plainChats.home, plainChatConfigName)
	f.host.Close()
	if err := os.WriteFile(path, []byte(`{"agent":{"chat":{"prompt":"old persona"}}}`), 0600); err != nil {
		t.Fatal(err)
	}
	second := newHost(f.store, NewOpenCodeAdapter(f.oc.server.URL, "opencode", "fixture", f.oc.server.Client()),
		HostOptions{PlainChats: &PlainChatOptions{Executable: "/Applications/AgentLand.app/Contents/MacOS/agentland-host", Home: filepath.Dir(f.store.Path), OpenCode: true}})
	defer second.Close()
	if data, _ := os.ReadFile(path); string(data) == `{"agent":{"chat":{"prompt":"old persona"}}}` {
		t.Fatal("the configuration was not replaced at start")
	}
	if !second.plainChats.refresh(t.Context()) {
		t.Fatal("not confirmed")
	}
	second.plainChats.refresh(t.Context())
	f.oc.mu.Lock()
	defer f.oc.mu.Unlock()
	if f.oc.disposals != 1 || !reflect.DeepEqual(f.oc.disposeDirs, []string{second.plainChats.home}) {
		t.Fatalf("%d disposals, for %v", f.oc.disposals, f.oc.disposeDirs)
	}
}

// An instance that lists the chat agent without AgentLand's prompt (made
// from an older configuration) is made again, at most every 10 minutes.
func (f *chatFixture) disposals() int {
	f.oc.mu.Lock()
	defer f.oc.mu.Unlock()
	return f.oc.disposals
}

func (f *chatFixture) mcpConnects() []string {
	f.oc.mu.Lock()
	defer f.oc.mu.Unlock()
	return slices.Clone(f.oc.mcpConnects)
}

// pacedByTheClock makes the Chats space's checks read the fixture's clock.
func (f *chatFixture) pacedByTheClock() {
	f.host.plainChats.mu.Lock()
	f.host.plainChats.now = f.clock.Now
	f.host.plainChats.mu.Unlock()
}

func TestPlainChatStaleInstanceIsReloadedAtMostEveryTenMinutes(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.pacedByTheClock()
	home := f.host.plainChats.home
	stale := []map[string]any{{"name": plainChatAgent, "mode": "primary", "prompt": "old persona"}}
	f.oc.set(func(o *fakeOpenCode) {
		o.agentLists[home] = stale
		o.reloadedAgents = map[string][]map[string]any{home: plainChatAgents()}
	})
	f.confirmPlainChats(t) // reloaded, then listed
	if f.disposals() != 1 {
		t.Fatalf("%d disposals", f.disposals())
	}
	// Stale again within 10 minutes: no reload, and no plain chats.
	f.oc.set(func(o *fakeOpenCode) { o.agentLists[home] = stale })
	f.clock.Advance(plainChatReloadEvery - time.Second)
	if f.host.plainChats.refresh(t.Context()) || f.disposals() != 1 {
		t.Fatalf("confirmed with a stale agent, or reloaded again: %d disposals", f.disposals())
	}
	f.clock.Advance(time.Second)
	if !f.host.plainChats.refresh(t.Context()) || f.disposals() != 2 {
		t.Fatalf("after 10 minutes: %d disposals", f.disposals())
	}
}

// A reload OpenCode did not answer (an error status, or no answer before the
// check's deadline) is tried again after plainChatFailedWait, not after the
// 10 minutes an answered one waits; a refusal (4xx) is an answer.
func TestPlainChatReloadThatFailedIsTriedAgainSoon(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.pacedByTheClock()
	home := f.host.plainChats.home
	stale := []map[string]any{{"name": plainChatAgent, "mode": "primary", "prompt": "old persona"}}
	f.oc.set(func(o *fakeOpenCode) {
		o.agentLists[home] = stale
		o.reloadedAgents = map[string][]map[string]any{home: plainChatAgents()}
		o.disposeCode = 503
	})
	if f.host.plainChats.refresh(t.Context()) || f.disposals() != 1 {
		t.Fatalf("with a failing reload: %d disposals", f.disposals())
	}
	f.clock.Advance(plainChatFailedWait - time.Second)
	if f.host.plainChats.refresh(t.Context()) || f.disposals() != 1 {
		t.Fatalf("tried again at once: %d disposals", f.disposals())
	}
	// No answer before the check's deadline is a failure too.
	f.clock.Advance(time.Second)
	gate := make(chan struct{})
	f.oc.set(func(o *fakeOpenCode) {
		o.disposeCode = 0
		o.disposeGate = gate
	})
	short, cancel := context.WithTimeout(t.Context(), 200*time.Millisecond)
	defer cancel()
	if f.host.plainChats.refresh(short) {
		t.Fatal("confirmed without an answer")
	}
	waitFor(t, "the held disposal", func() bool { return f.disposals() == 2 })
	close(gate)
	f.oc.set(func(o *fakeOpenCode) { o.disposeGate = nil })
	f.clock.Advance(plainChatFailedWait)
	if !f.host.plainChats.refresh(t.Context()) || f.disposals() != 3 {
		t.Fatalf("after a reload that got no answer: %d disposals", f.disposals())
	}
	// A refusal is an answer: the next reload waits the 10 minutes.
	f.oc.set(func(o *fakeOpenCode) {
		o.agentLists[home] = stale
		o.disposeCode = 400
	})
	f.clock.Advance(plainChatReloadEvery)
	if f.host.plainChats.refresh(t.Context()) || f.disposals() != 4 {
		t.Fatalf("a refused reload: %d disposals", f.disposals())
	}
	f.clock.Advance(plainChatFailedWait)
	if f.host.plainChats.refresh(t.Context()) || f.disposals() != 4 {
		t.Fatalf("a refused reload was tried again soon: %d disposals", f.disposals())
	}
}

// A configuration the host replaced is loaded at the next check whatever the
// last reload was; one whose reload failed is tried again after
// plainChatFailedWait, and then no more once OpenCode answered.
func TestPlainChatReplacedConfigurationIsReloadedUntilOpenCodeAnswers(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.pacedByTheClock()
	f.confirmPlainChats(t)
	path := filepath.Join(f.host.plainChats.home, plainChatConfigName)
	f.oc.set(func(o *fakeOpenCode) { o.disposeCode = 500 })
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	f.confirmPlainChats(t)
	if f.disposals() != 1 {
		t.Fatalf("%d disposals", f.disposals())
	}
	f.clock.Advance(plainChatFailedWait - time.Second)
	f.confirmPlainChats(t)
	if f.disposals() != 1 {
		t.Fatalf("tried again at once: %d disposals", f.disposals())
	}
	f.clock.Advance(time.Second)
	f.oc.set(func(o *fakeOpenCode) { o.disposeCode = 0 })
	f.confirmPlainChats(t)
	f.clock.Advance(plainChatFailedWait)
	f.confirmPlainChats(t)
	if f.disposals() != 2 {
		t.Fatalf("%d disposals once OpenCode answered", f.disposals())
	}
	// Replaced again right after that reload: loaded again at once.
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	f.confirmPlainChats(t)
	if f.disposals() != 3 {
		t.Fatalf("%d disposals after the second replacement", f.disposals())
	}
}

// OpenCode does not start a failed tool server again by itself: the host asks
// it to, at most once a minute once OpenCode answered, and after
// plainChatFailedWait when it did not.
func TestPlainChatToolServerIsConnectedAgain(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.pacedByTheClock()
	home := f.host.plainChats.home
	f.oc.set(func(o *fakeOpenCode) { o.mcpStatus[plainChatServer] = "failed" })
	f.confirmPlainChats(t)
	if got := capabilityOf(t, f); got == nil || !reflect.DeepEqual(got.Tools, []string{"websearch", "fetch", "memory"}) ||
		!reflect.DeepEqual(f.mcpConnects(), []string{plainChatServer + " " + home}) {
		t.Fatalf("capability %+v after connecting %v", got, f.mcpConnects())
	}
	// Closed again within a minute: not asked again, and its tools go.
	f.oc.set(func(o *fakeOpenCode) {
		o.mcpStatus[plainChatServer] = "failed"
		o.connectStatus = "failed"
	})
	f.clock.Advance(plainChatReconnectEvery - time.Second)
	f.confirmPlainChats(t)
	if got := capabilityOf(t, f); got == nil || !reflect.DeepEqual(got.Tools, []string{"websearch"}) || len(f.mcpConnects()) != 1 {
		t.Fatalf("capability %+v after connecting %v", got, f.mcpConnects())
	}
	f.clock.Advance(time.Second)
	f.oc.set(func(o *fakeOpenCode) { o.connectStatus = "" })
	f.confirmPlainChats(t)
	if got := capabilityOf(t, f); got == nil || len(got.Tools) != 3 || len(f.mcpConnects()) != 2 {
		t.Fatalf("capability %+v after connecting %v", got, f.mcpConnects())
	}
	// A connection OpenCode failed to make (5xx) is asked for again soon.
	f.oc.set(func(o *fakeOpenCode) {
		o.mcpStatus[plainChatServer] = "failed"
		o.connectCode = 500
	})
	f.clock.Advance(plainChatReconnectEvery)
	f.confirmPlainChats(t)
	f.clock.Advance(plainChatFailedWait - time.Second)
	f.confirmPlainChats(t)
	if len(f.mcpConnects()) != 3 {
		t.Fatalf("connections %v", f.mcpConnects())
	}
	f.clock.Advance(time.Second)
	f.oc.set(func(o *fakeOpenCode) { o.connectCode = 0 })
	f.confirmPlainChats(t)
	if got := capabilityOf(t, f); got == nil || len(got.Tools) != 3 || len(f.mcpConnects()) != 4 {
		t.Fatalf("capability %+v after connecting %v", got, f.mcpConnects())
	}
}

// The pulse names the revision of capabilities.generalChats and
// workspaceChats (its plainChats line) right after ready and
// again whenever it changes, so connected devices read capabilities again.
func TestPulseAnnouncesPlainChatsChanges(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.host.pulseEvery = time.Hour
	server := httptest.NewServer(f.host.Handler())
	defer server.Close()
	lines, done := openPulse(t, server.URL, f.token)
	defer done()
	if line := nextPulse(t, lines, time.Second); line.Type != "ready" {
		t.Fatalf("first pulse line %+v", line)
	}
	absent := nextPulse(t, lines, time.Second)
	if absent.Type != "plainChats" || absent.Revision != chatsRevisionOf(t, f) {
		t.Fatalf("second pulse line %+v", absent)
	}
	f.confirmPlainChats(t)
	listed := nextPulse(t, lines, time.Second)
	if listed.Type != "plainChats" || listed.Revision == absent.Revision || listed.Revision != chatsRevisionOf(t, f) {
		t.Fatalf("after the chat agent was confirmed: %+v", listed)
	}
	// A check that changes nothing says nothing; the next change is the next
	// line.
	f.confirmPlainChats(t)
	f.oc.set(func(o *fakeOpenCode) { o.toolIDs = []string{"invalid"} })
	f.confirmPlainChats(t)
	fewer := nextPulse(t, lines, time.Second)
	if fewer.Type != "plainChats" || fewer.Revision == listed.Revision || fewer.Revision != chatsRevisionOf(t, f) {
		t.Fatalf("after web search went: %+v", fewer)
	}
}

func TestPlainChatFolderMustBeAFolder(t *testing.T) {
	folder := plainStateFolder(t)
	state := filepath.Join(folder, "host.json")
	if err := os.Symlink(t.TempDir(), state+".chat-home"); err != nil {
		t.Fatal(err)
	}
	c := &plainChats{home: state + ".chat-home", statePath: state, executable: "/bin/agentland-host"}
	if _, err := c.ensureHome(); err == nil {
		t.Fatal("a symlink was taken for the Chats space's folder")
	}
}

// capabilityOf reads capabilities.plainChats.
// chatsRevisionOf is the pulse's plainChats revision of what
// /v1/capabilities says of generalChats and workspaceChats now.
func chatsRevisionOf(t *testing.T, f *chatFixture) string {
	t.Helper()
	var body struct {
		General   *plainChatsCapability     `json:"generalChats"`
		Workspace *workspaceChatsCapability `json:"workspaceChats"`
	}
	if err := json.Unmarshal(f.call(t, "GET", "/v1/capabilities", nil).Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return plainChatsRevision(body.General, body.Workspace)
}

func capabilityOf(t *testing.T, f *chatFixture) *plainChatsCapability {
	t.Helper()
	w := f.call(t, "GET", "/v1/capabilities", nil)
	var body struct {
		PlainChats *plainChatsCapability `json:"plainChats"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body.PlainChats
}

func TestPlainChatsCapabilityFollowsTheChatAgent(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	home := f.host.plainChats.home
	// Instruction files: one in the state folder above the Chats space, the
	// owner's Claude Code file and OpenCode's global one.
	folder := filepath.Dir(f.store.Path)
	claude, config := filepath.Join(folder, "claude-home"), filepath.Join(folder, "opencode-config")
	for _, path := range []string{filepath.Join(folder, "AGENTS.md"), filepath.Join(claude, ".claude", "CLAUDE.md"), filepath.Join(config, "AGENTS.md")} {
		os.MkdirAll(filepath.Dir(path), 0700)
		if err := os.WriteFile(path, []byte("Be brief."), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// OpenCode without AgentLand's agent, or with another agent named chat:
	// no plain chats, and nothing is sent.
	for _, agents := range [][]map[string]any{{{"name": "build"}}, {{"name": plainChatAgent, "prompt": "You are a coding agent."}}} {
		f.oc.set(func(o *fakeOpenCode) { o.agentLists[home] = agents })
		if f.host.plainChats.refresh(t.Context()) || capabilityOf(t, f) != nil {
			t.Fatalf("plain chats listed with agents %v", agents)
		}
		w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": plainChatsProjectID})
		if w.Code != 503 || errorCode(t, w) != "agent_unavailable" {
			t.Fatalf("create without the chat agent: %d %s", w.Code, w.Body.String())
		}
	}
	f.oc.set(func(o *fakeOpenCode) {
		o.agentLists[home] = plainChatAgents()
		o.pathHome, o.pathConfig = claude, config
	})
	f.confirmPlainChats(t)
	// The search service only when the host knows it (serve
	// --websearch-provider, which the Mac app passes).
	want := &plainChatsCapability{ProjectID: "chats", Tools: []string{"websearch", "fetch", "memory"},
		InstructionFiles: []string{"~/AGENTS.md", "~/claude-home/.claude/CLAUDE.md", "~/opencode-config/AGENTS.md"}}
	want.Providers = []plainChatProvider{{ID: "opencode", Name: "OpenCode", Tools: append([]string{}, want.Tools...), Features: []string{"events", "parts", "stop", "clientMessageId", "title", "attachments", "rewind", "regenerate", "queue"},
		Auth: &plainChatAuth{Kind: plainAuthAPIKey, Label: "API keys"}}}
	if got := capabilityOf(t, f); !reflect.DeepEqual(got, want) {
		t.Fatalf("capability %+v\nwant %+v", got, want)
	}
	f.host.plainChats.mu.Lock()
	f.host.plainChats.searchProvider = "exa"
	f.host.plainChats.mu.Unlock()
	want.SearchProvider = "exa"
	if got := capabilityOf(t, f); !reflect.DeepEqual(got, want) {
		t.Fatalf("capability %+v\nwant %+v", got, want)
	}
	// Web search is asked of OpenCode for a model of no provider without a
	// default model, and for the Chats space's default model with one.
	f.oc.set(func(o *fakeOpenCode) { o.configModel = "fake/fast" })
	f.confirmPlainChats(t)
	f.oc.mu.Lock()
	queries := slices.Clone(f.oc.toolQueries)
	f.oc.mu.Unlock()
	if queries[0] != "model=probe&provider=agentland" || queries[len(queries)-1] != "model=fast&provider=fake" {
		t.Fatalf("tool queries %v", queries)
	}
	// Each tool only while it works; instruction files as found at the
	// first check.
	f.oc.set(func(o *fakeOpenCode) {
		o.toolIDs = []string{"invalid", "bash"}
		o.mcpStatus[plainChatServer] = "failed"
		o.connectStatus = "failed"
	})
	f.confirmPlainChats(t)
	if got := capabilityOf(t, f); got == nil || len(got.Tools) != 0 || got.SearchProvider != "" || len(got.InstructionFiles) != 3 {
		t.Fatalf("capability without working tools %+v", got)
	}
	encoded := f.call(t, "GET", "/v1/capabilities", nil).Body.String()
	var encodedCapability struct {
		PlainChats *plainChatsCapability `json:"plainChats"`
	}
	if err := json.Unmarshal([]byte(encoded), &encodedCapability); err != nil || encodedCapability.PlainChats == nil || encodedCapability.PlainChats.ProjectID != "chats" || encodedCapability.PlainChats.Tools == nil || len(encodedCapability.PlainChats.Tools) != 0 || len(encodedCapability.PlainChats.InstructionFiles) == 0 || encodedCapability.PlainChats.InstructionFiles[0] != "~/AGENTS.md" {
		t.Fatalf("capabilities %s", encoded)
	}
	// Memory needs the store and its socket.
	f.oc.set(func(o *fakeOpenCode) { o.mcpStatus[plainChatServer] = "connected" })
	socket := f.host.plainChats.socket
	f.host.plainChats.socket = nil
	f.confirmPlainChats(t)
	f.host.plainChats.socket = socket
	if got := capabilityOf(t, f); !reflect.DeepEqual(got.Tools, []string{"fetch"}) {
		t.Fatalf("tools without the memory socket %v", got.Tools)
	}
	// A host without plain chats, or whose agent is not OpenCode, lists none.
	plain, _, _ := testHost(t)
	if plain.advertisedCapabilities().PlainChats != nil {
		t.Fatal("a host without plain chats lists them")
	}
}

// plainRouteHost has plain chats beside a workspace with terminals (or not)
// and an archive, and a fake agent that is not OpenCode.
func plainRouteHost(t *testing.T, terminals bool) (*Host, string) {
	t.Helper()
	folder := plainStateFolder(t)
	store := NewStore(filepath.Join(folder, "state.json"))
	project := t.TempDir()
	if err := os.WriteFile(filepath.Join(project, "notes.txt"), []byte("routes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: project}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	agent := &fakeAgent{sessions: map[string]Session{"s1": {ID: "s1", Title: "One", ProjectID: "p1", Directory: project}}}
	fixture := newTerminalFixture(agent)
	host := newHost(store, fixture, HostOptions{TerminalEnabled: terminals, Terminals: fixture.fakeTerminals, Archive: testArchive(t, ArchiveOptions{}),
		PlainChats: &PlainChatOptions{Executable: "/bin/agentland-host", Home: folder, OpenCode: true}})
	if host.terminals != nil {
		fakeTerminalPrograms(host, false)
	}
	t.Cleanup(func() { host.Close() })
	return host, paired(t, host, store)
}

func TestEveryOtherRouteRefusesTheChatsSpace(t *testing.T) {
	host, token := plainRouteHost(t, true)
	refusals := []struct {
		method, target string
		body           any
		field          string
	}{
		// Files and file search.
		{"GET", "/v1/files?projectId=chats", nil, ""},
		{"GET", "/v1/file?projectId=chats&path=opencode.json", nil, ""},
		{"POST", "/v1/file", map[string]string{"projectId": "chats", "path": "opencode.json", "content": "{}", "revision": ""}, ""},
		{"POST", "/v1/files/move", map[string]string{"projectId": "chats", "from": "opencode.json", "to": "moved.json"}, ""},
		{"POST", "/v1/files/mkdir", map[string]string{"projectId": "chats", "path": "made"}, ""},
		{"POST", "/v1/files/upload?projectId=chats&path=uploaded.txt", nil, ""},
		{"POST", "/v1/files/delete", map[string]any{"projectId": "chats", "path": "opencode.json"}, ""},
		{"GET", "/v1/files/search?projectId=chats&q=deny", nil, ""},
		// Git.
		{"GET", "/v1/git/repositories?projectId=chats", nil, ""},
		{"GET", "/v1/git/status?projectId=chats", nil, ""},
		{"GET", "/v1/git/diff?projectId=chats&file=opencode.json", nil, ""},
		{"GET", "/v1/git/identity?projectId=chats", nil, ""},
		{"POST", "/v1/git/stage", map[string]any{"projectId": "chats", "files": []string{"opencode.json"}}, ""},
		{"POST", "/v1/git/unstage", map[string]any{"projectId": "chats", "files": []string{"opencode.json"}}, ""},
		{"POST", "/v1/git/commit", map[string]string{"projectId": "chats", "message": "m"}, ""},
		// Terminals and their logs.
		{"GET", "/v1/terminals?projectId=chats", nil, ""},
		{"POST", "/v1/terminals", map[string]any{"projectId": "chats", "rows": 24, "cols": 80}, ""},
		{"GET", "/v1/terminal/output?projectId=chats&terminalId=t1&cursor=0", nil, ""},
		{"POST", "/v1/terminal/input", map[string]any{"projectId": "chats", "terminalId": "t1", "data": []byte("ls\n")}, ""},
		{"POST", "/v1/terminal/resize", map[string]any{"projectId": "chats", "terminalId": "t1", "rows": 24, "cols": 80}, ""},
		{"POST", "/v1/terminal/close", map[string]string{"projectId": "chats", "terminalId": "t1"}, ""},
		{"GET", "/v1/archive/terminal-logs?projectId=chats", nil, ""},
	}
	for _, check := range refusals {
		w := request(t, host.Handler(), check.method, check.target, token, check.body)
		if w.Code != 404 || errorCode(t, w) != "not_found" || errorField(t, w) != check.field {
			t.Errorf("%s %s: %d %s", check.method, check.target, w.Code, w.Body.String())
		}
	}
	// The Chats space's folder is left as it was.
	if entries, _ := os.ReadDir(host.plainChats.home); len(entries) != 1 || entries[0].Name() != "opencode.json" {
		t.Fatalf("the Chats space's folder holds %v", entries)
	}
	// The workspace list never shows it; the chat routes take it.
	if w := request(t, host.Handler(), "GET", "/v1/projects", token, nil); strings.Contains(w.Body.String(), `"chats"`) {
		t.Fatalf("projects %s", w.Body.String())
	}
	if w := request(t, host.Handler(), "GET", "/v1/sessions?projectId=chats", token, nil); w.Code != 200 || w.Body.String() != "{\"sessions\":[]}\n" {
		t.Fatalf("plain chats: %d %s", w.Code, w.Body.String())
	}
	// A host without terminals refuses them first.
	quiet, quietToken := plainRouteHost(t, false)
	if w := request(t, quiet.Handler(), "GET", "/v1/terminals?projectId=chats", quietToken, nil); w.Code != 403 || errorCode(t, w) != "terminal_disabled" {
		t.Fatalf("terminals without terminals: %d %s", w.Code, w.Body.String())
	}
}

func TestProjectIDChatsIsReserved(t *testing.T) {
	err := ValidateConfig(Config{OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "P", Projects: []Project{{ID: "chats", Name: "Chats", Directory: t.TempDir()}}})
	if err == nil || !strings.Contains(err.Error(), "reserved") {
		t.Fatalf("ValidateConfig: %v", err)
	}
}

func TestPlainChatsRunTheChatAgentOnEveryPath(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{Archive: testArchive(t, ArchiveOptions{})})
	f.confirmPlainChats(t)
	if _, err := f.host.plainChats.memory.save("Prefers metric units"); err != nil {
		t.Fatal(err)
	}
	// Only OpenCode, created with the plain chat's rules: Claude Code and
	// Codex run Chat in the workspaces.
	for provider, status := range map[string]int{"claude": 503, "codex": 503, "gemini": 400} {
		w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "chats", "provider": provider})
		if code := map[int]string{503: "agent_unavailable", 400: "plain_chat_provider"}[status]; w.Code != status || errorCode(t, w) != code {
			t.Fatalf("create with %s: %d %s", provider, w.Code, w.Body.String())
		}
	}
	if w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "chats", "model": "fake/fast"}); w.Code != 400 || errorCode(t, w) != "unsupported_options" {
		t.Fatalf("create with a model: %d %s", w.Code, w.Body.String())
	}
	chat := f.plainChat(t)
	var created struct {
		Title      string
		Permission []ocPermissionRule
	}
	f.oc.mu.Lock()
	json.Unmarshal(f.oc.createBodies[len(f.oc.createBodies)-1], &created)
	f.oc.mu.Unlock()
	if !reflect.DeepEqual(created.Permission, []ocPermissionRule{{"*", "*", "deny"}, {"invalid", "*", "allow"}, {"websearch", "*", "allow"},
		{"agentland_fetch", "*", "allow"}, {"agentland_memory_save", "*", "allow"}, {"agentland_memory_forget", "*", "allow"}}) {
		t.Fatalf("a plain chat was created with %+v", created.Permission)
	}
	checkPrompt := func(label string) map[string]any {
		t.Helper()
		body := f.lastPrompt(t)
		system, _ := body["system"].(string)
		if body["agent"] != plainChatAgent || !strings.HasPrefix(system, memorySystemHeader+"\n[\n{\"id\":\"mem_") || !strings.HasSuffix(system, "\",\"text\":\"Prefers metric units\"}\n]") {
			t.Fatalf("%s: prompt %v", label, body)
		}
		return body
	}
	// A send, with a model or none.
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "hello"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	checkPrompt("send")
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "again", "model": "fake/fast"}); w.Code != 202 {
		t.Fatalf("send with a model: %d %s", w.Code, w.Body.String())
	}
	if model := checkPrompt("send with a model")["model"]; !reflect.DeepEqual(model, map[string]any{"providerID": "fake", "modelID": "fast"}) {
		t.Fatalf("model %v", model)
	}
	// No mode, effort or agent.
	for _, refused := range []map[string]string{{"agent": "build"}, {"agent": "chat"}, {"mode": "plan"}, {"effort": "high"}} {
		body := map[string]string{"projectId": "chats", "sessionId": chat, "text": "x"}
		for key, value := range refused {
			body[key] = value
		}
		if w := f.call(t, "POST", "/v1/messages", body); w.Code != 400 || errorCode(t, w) != "unsupported_options" {
			t.Fatalf("send with %v: %d %s", refused, w.Code, w.Body.String())
		}
		if w := f.call(t, "POST", "/v1/chat/regenerate", map[string]string{"projectId": "chats", "sessionId": chat, "mode": "plan"}); w.Code != 400 || errorCode(t, w) != "unsupported_options" {
			t.Fatalf("regenerate with a mode: %d %s", w.Code, w.Body.String())
		}
	}
	if w := f.call(t, "POST", "/v1/queue", map[string]string{"projectId": "chats", "sessionId": chat, "text": "x", "agent": "plan"}); w.Code != 400 || errorCode(t, w) != "unsupported_options" {
		t.Fatalf("queue with an agent: %d %s", w.Code, w.Body.String())
	}
	// A queued message waits while the chat agent is not confirmed, then runs it.
	if w := f.call(t, "POST", "/v1/queue", map[string]string{"projectId": "chats", "sessionId": chat, "text": "queued"}); w.Code != 201 {
		t.Fatalf("queue: %d %s", w.Code, w.Body.String())
	}
	f.host.plainChats.mu.Lock()
	f.host.plainChats.confirmed = false
	f.host.plainChats.mu.Unlock()
	sent := len(f.oc.promptBodies())
	f.clock.Advance(queueSettleTimeout)
	f.host.dispatchNext(sessionKey{"chats", chat})
	if items := f.queue.Items("chats", chat); len(items) != 1 || items[0].Status != "queued" || len(f.oc.promptBodies()) != sent {
		t.Fatalf("a queued message went while the chat agent was not confirmed: %+v", items)
	}
	f.confirmPlainChats(t)
	f.host.dispatchNext(sessionKey{"chats", chat})
	if items := f.queue.Items("chats", chat); len(items) != 0 {
		t.Fatalf("queue %+v", items)
	}
	checkPrompt("queue")
	// An edit after a rewind, and regenerate.
	f.oc.addMessages(chat, ocMessageFixture("msg_u1", "user", "hello"), ocMessageFixture("msg_a1", "assistant", "hi"))
	if w := f.call(t, "POST", "/v1/messages/rewind", map[string]string{"projectId": "chats", "sessionId": chat, "messageId": "msg_u1"}); w.Code != 200 {
		t.Fatalf("rewind: %d %s", w.Code, w.Body.String())
	}
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "edited"}); w.Code != 202 {
		t.Fatalf("edit: %d %s", w.Code, w.Body.String())
	}
	checkPrompt("edit")
	if w := f.call(t, "POST", "/v1/chat/regenerate", map[string]string{"projectId": "chats", "sessionId": chat}); w.Code != 202 {
		t.Fatalf("regenerate: %d %s", w.Code, w.Body.String())
	}
	checkPrompt("regenerate")
	// Continue: a plain chat into a plain chat only, with OpenCode.
	archive := f.host.archive
	for _, chat := range []ArchiveChat{{ID: "ses_source", ProjectID: "chats", Provider: "opencode", Title: "Tides", CreatedAt: f.clock.Now()},
		{ID: "ses_workspace", ProjectID: "p1", Provider: "opencode", Title: "Code", CreatedAt: f.clock.Now()}} {
		if err := archive.UpsertChat(chat); err != nil {
			t.Fatal(err)
		}
		mustArchiveMessage(t, archive, textMessage(chat.ID, "m1", "user", 1, "When is high tide in Lisbon?"))
	}
	flushArchive(t, archive)
	// Claude Code continues the Chats space's chats only in a workspace.
	if w := f.call(t, "POST", "/v1/chat/continue", map[string]string{"projectId": "chats", "sourceSessionId": "ses_source", "provider": "claude"}); w.Code != 503 || errorCode(t, w) != "agent_unavailable" {
		t.Fatalf("continue with Claude Code in the Chats space: %d %s", w.Code, w.Body.String())
	}
	for _, refused := range []struct {
		body map[string]string
		code string
	}{
		{map[string]string{"projectId": "chats", "sourceSessionId": "ses_source", "provider": "opencode", "mode": "build"}, "unsupported_options"},
		{map[string]string{"projectId": "chats", "sourceSessionId": "ses_workspace", "provider": "opencode"}, "plain_chat_scope"},
		{map[string]string{"projectId": "p1", "sourceSessionId": "ses_source", "provider": "opencode"}, "plain_chat_scope"},
	} {
		if w := f.call(t, "POST", "/v1/chat/continue", refused.body); w.Code != 400 || errorCode(t, w) != refused.code {
			t.Fatalf("continue %v: %d %s", refused.body, w.Code, w.Body.String())
		}
	}
	w := f.call(t, "POST", "/v1/chat/continue", map[string]string{"projectId": "chats", "sourceSessionId": "ses_source", "provider": "opencode"})
	if w.Code != 201 {
		t.Fatalf("continue: %d %s", w.Code, w.Body.String())
	}
	var continued Session
	json.Unmarshal(w.Body.Bytes(), &continued)
	if continued.ProjectID != "chats" || continued.Provider != "" && continued.Provider != "opencode" {
		t.Fatalf("continued %+v", continued)
	}
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": continued.ID, "text": "And tomorrow?"}); w.Code != 202 {
		t.Fatalf("continued send: %d %s", w.Code, w.Body.String())
	}
	parts := checkPrompt("continued chat's first message")["parts"].([]any)
	if text := parts[0].(map[string]any)["text"].(string); !strings.HasPrefix(text, "Context from an earlier chat") || !strings.HasSuffix(text, "And tomorrow?") {
		t.Fatalf("first message %q", text)
	}
	// Every prompt the Chats space sent ran the chat agent.
	for _, raw := range f.oc.promptBodies() {
		var body struct{ Agent string }
		json.Unmarshal(raw, &body)
		if body.Agent != plainChatAgent {
			t.Fatalf("a prompt ran %q: %s", body.Agent, raw)
		}
	}
	// With memory off no system text is sent.
	if w := f.call(t, "POST", "/v1/memory/settings", map[string]bool{"enabled": false}); w.Code != 200 {
		t.Fatalf("memory off: %d %s", w.Code, w.Body.String())
	}
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "private"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	if body := f.lastPrompt(t); body["agent"] != plainChatAgent || body["system"] != nil {
		t.Fatalf("a prompt with memory off %v", body)
	}
	// A workspace chat never gets the chat agent or the memory.
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "code", "agent": "build"}); w.Code != 202 {
		t.Fatalf("workspace send: %d %s", w.Code, w.Body.String())
	}
	if body := f.lastPrompt(t); body["agent"] != "build" || body["system"] != nil {
		t.Fatalf("a workspace prompt %v", body)
	}
	// And a plain chat is not a workspace's chat.
	if w := f.call(t, "GET", "/v1/messages?projectId=p1&sessionId="+chat, nil); w.Code != 404 {
		t.Fatalf("a plain chat read as a workspace's: %d", w.Code)
	}
	if w := f.call(t, "GET", "/v1/messages?projectId=chats&sessionId=s1", nil); w.Code != 404 {
		t.Fatalf("a workspace's chat read as a plain chat: %d", w.Code)
	}
}

func TestPlainChatsRefuseSendsUntilTheChatAgentIsConfirmed(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{Archive: testArchive(t, ArchiveOptions{})})
	f.confirmPlainChats(t)
	chat := f.plainChat(t)
	f.oc.addMessages(chat, ocMessageFixture("msg_u1", "user", "hello"))
	f.oc.set(func(o *fakeOpenCode) { o.agentLists[f.host.plainChats.home] = nil })
	if f.host.plainChats.refresh(t.Context()) {
		t.Fatal("still confirmed")
	}
	sent := len(f.oc.promptBodies())
	for _, send := range []struct {
		path string
		body map[string]string
	}{
		{"/v1/sessions", map[string]string{"projectId": "chats"}},
		{"/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "hello"}},
		{"/v1/chat/regenerate", map[string]string{"projectId": "chats", "sessionId": chat}},
	} {
		if w := f.call(t, "POST", send.path, send.body); w.Code != 503 || errorCode(t, w) != "agent_unavailable" {
			t.Fatalf("%s: %d %s", send.path, w.Code, w.Body.String())
		}
	}
	if len(f.oc.promptBodies()) != sent {
		t.Fatal("a prompt was sent without the chat agent")
	}
	// Reading still works.
	if w := f.call(t, "GET", "/v1/chat/messages?projectId=chats&sessionId="+chat, nil); w.Code != 200 {
		t.Fatalf("read: %d %s", w.Code, w.Body.String())
	}
	// A send checks again first, so a chat agent that just appeared is used.
	f.oc.set(func(o *fakeOpenCode) { o.agentLists[f.host.plainChats.home] = plainChatAgents() })
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "now"}); w.Code != 202 {
		t.Fatalf("send once confirmed: %d %s", w.Code, w.Body.String())
	}
}

// A queued message whose send finds the chat agent unconfirmed (a check
// failed after the dispatcher's) waits, queued, instead of failing.
func TestQueuedPlainChatWaitsWhenItsSendFindsNoChatAgent(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.confirmPlainChats(t)
	chat := f.plainChat(t)
	if w := f.call(t, "POST", "/v1/queue", map[string]string{"projectId": "chats", "sessionId": chat, "text": "queued"}); w.Code != 201 {
		t.Fatalf("queue: %d %s", w.Code, w.Body.String())
	}
	key := sessionKey{"chats", chat}
	item, _, _, waiting := f.queue.next(key)
	if !waiting || !f.queue.begin(key, item.ID) {
		t.Fatal("not begun")
	}
	project := f.host.plainChats.project()
	session, err := f.host.session(project, chat)
	if err != nil {
		t.Fatal(err)
	}
	f.host.plainChats.mu.Lock()
	f.host.plainChats.confirmed = false
	f.host.plainChats.mu.Unlock()
	sent := len(f.oc.promptBodies())
	f.host.sendQueued(key, item, project, session, 0)
	if items := f.queue.Items("chats", chat); len(items) != 1 || items[0].Status != "queued" || items[0].Error != "" || len(f.oc.promptBodies()) != sent {
		t.Fatalf("the queued message after an unconfirmed send: %+v", items)
	}
}

// A Chats space OpenCode cannot serve runs nothing: it keeps the host
// neither busy nor running. A turn OpenCode reports there does.
func TestBrokenChatsSpaceKeepsNothingBusy(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	home := f.host.plainChats.home
	if f.host.anythingRuns() || f.host.openCodeBusy() {
		t.Fatal("an idle host counts as busy")
	}
	f.oc.set(func(o *fakeOpenCode) { delete(o.homes, home) })
	if f.host.anythingRuns() || f.host.openCodeBusy() {
		t.Fatal("a Chats space OpenCode cannot serve counts as busy")
	}
	f.oc.set(func(o *fakeOpenCode) {
		o.homes[home] = true
		o.status["ses_plain"] = "busy"
	})
	if !f.host.anythingRuns() || !f.host.openCodeBusy() {
		t.Fatal("a turn does not count")
	}
}

// The Chats space's import comes after the workspaces' and waits until the
// chat agent was confirmed once, so a Chats space OpenCode cannot serve holds
// up no workspace's import.
func TestPlainChatBackfillComesLastAndWaitsForTheChatAgent(t *testing.T) {
	older := func(f *chatFixture) {
		home := f.host.plainChats.home
		f.oc.set(func(o *fakeOpenCode) {
			o.reverts["ses_older"] = ""
			o.sessionDirs["ses_older"] = home
			o.messages["ses_older"] = []any{map[string]any{"info": map[string]any{"id": "msg_old", "role": "user", "time": map[string]int64{"created": fixtureEpochMs}},
				"parts": []any{map[string]string{"type": "text", "text": "an older plain chat"}}}}
			delete(o.homes, home) // OpenCode cannot serve the Chats space
		})
		f.host.backfill.gap = 0
	}
	cliDone := func(t *testing.T, archive *Archive) {
		t.Helper()
		if row, err := archive.backfillRow(t.Context(), "cli", "p1"); err != nil || !row.done {
			t.Fatalf("the workspace's Claude Code and Codex import: %+v %v", row, err)
		}
	}
	// Never confirmed: the pass leaves the Chats space out and succeeds.
	archive := testArchive(t, ArchiveOptions{})
	f := newPlainChatFixture(t, HostOptions{Archive: archive})
	older(f)
	if err := f.host.backfill.run(t.Context()); err != nil {
		t.Fatal(err)
	}
	cliDone(t, archive)
	if _, err := archive.ArchivedChat(t.Context(), "ses_older"); err == nil {
		t.Fatal("the Chats space was imported before the chat agent was confirmed")
	}
	// Confirmed once, then broken: the workspaces' import ran before the
	// Chats space failed the pass; once OpenCode serves it again, it is
	// imported.
	archive = testArchive(t, ArchiveOptions{})
	f = newPlainChatFixture(t, HostOptions{Archive: archive})
	f.confirmPlainChats(t)
	older(f)
	if err := f.host.backfill.run(t.Context()); err == nil {
		t.Fatal("a Chats space OpenCode cannot serve passed")
	}
	cliDone(t, archive)
	f.oc.set(func(o *fakeOpenCode) { o.homes[f.host.plainChats.home] = true })
	if err := f.host.backfill.run(t.Context()); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	if imported, err := archive.ArchivedChat(t.Context(), "ses_older"); err != nil || imported.ProjectID != "chats" {
		t.Fatalf("backfill %+v %v", imported, err)
	}
}

// The memory reaches prompts only while the capability lists it, so the model
// can always forget what it is shown.
func TestPlainChatMemoryReachesPromptsOnlyWithTheMemoryTools(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.confirmPlainChats(t)
	if _, err := f.host.plainChats.memory.save("Prefers metric units"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.host.plainChats.memorySystem(), `"text":"Prefers metric units"`) {
		t.Fatalf("system text %q", f.host.plainChats.memorySystem())
	}
	f.oc.set(func(o *fakeOpenCode) {
		o.mcpStatus[plainChatServer] = "failed"
		o.connectStatus = "failed"
	})
	f.confirmPlainChats(t)
	if capability := capabilityOf(t, f); slices.Contains(capability.Tools, plainChatToolMemory) || f.host.plainChats.memorySystem() != "" {
		t.Fatalf("memory without its tools: %+v %q", capability, f.host.plainChats.memorySystem())
	}
	chat := f.plainChat(t)
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "hello"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	if system, _ := f.lastPrompt(t)["system"].(string); system != "" {
		t.Fatalf("a prompt without the memory tools carries %q", system)
	}
}

func TestPlainChatOptions(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	f.confirmPlainChats(t)
	w := f.call(t, "GET", "/v1/chat/options?projectId=chats", nil)
	if w.Code != 200 || w.Body.String() != `{"models":[{"id":"fake/fast","name":"Fast","provider":"Fake","contextWindow":1000}],"defaultModel":"fake/fast","agents":[]}`+"\n" {
		t.Fatalf("options: %d %s", w.Code, w.Body.String())
	}
	chat := f.plainChat(t)
	if w := f.call(t, "GET", "/v1/chat/options?projectId=chats&sessionId="+chat, nil); w.Code != 200 || !strings.Contains(w.Body.String(), `"agents":[]`) {
		t.Fatalf("a plain chat's options: %d %s", w.Code, w.Body.String())
	}
	// Claude Code runs Chat in the workspaces, not here; another provider is
	// not one of the Chats space's.
	if w := f.call(t, "GET", "/v1/chat/options?projectId=chats&provider=claude", nil); w.Code != 503 || errorCode(t, w) != "agent_unavailable" {
		t.Fatalf("options for Claude Code: %d %s", w.Code, w.Body.String())
	}
	if w := f.call(t, "GET", "/v1/chat/options?projectId=chats&provider=gemini", nil); w.Code != 400 || errorCode(t, w) != "plain_chat_provider" {
		t.Fatalf("options for another provider: %d %s", w.Code, w.Body.String())
	}
	if w := f.call(t, "GET", "/v1/chat/options?projectId=chats&sessionId=s1", nil); w.Code != 404 {
		t.Fatalf("a workspace chat's options in the Chats space: %d %s", w.Code, w.Body.String())
	}
	// A plain chat's snapshot names no mode.
	f.oc.addMessages(chat, map[string]any{"info": map[string]any{"id": "msg_u1", "role": "user", "agent": "chat", "model": map[string]string{"providerID": "fake", "modelID": "fast"}}, "parts": []any{}})
	loaded, err := f.host.chatProviderFor(Session{ID: chat}).load(f.host.plainChats.project(), chat, 10)
	if err != nil || loaded.info.Mode != "" || loaded.info.Model != "fake/fast" {
		t.Fatalf("snapshot %+v %v", loaded.info, err)
	}
}

func TestPlainChatsInTheArchiveFeedBackfillAndSearch(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	f := newPlainChatFixture(t, HostOptions{Archive: archive})
	f.confirmPlainChats(t)
	if ids, err := f.host.configuredProjectIDs(); err != nil || !reflect.DeepEqual(ids, []string{"p1", "chats"}) {
		t.Fatalf("projects %v %v", ids, err)
	}
	chat := f.plainChat(t)
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "chats", "sessionId": chat, "text": "tide times lisbon"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	flushArchive(t, archive)
	w := f.call(t, "GET", "/v1/archive/changes", nil)
	var page ArchiveChanges
	json.Unmarshal(w.Body.Bytes(), &page)
	if !strings.Contains(w.Body.String(), `"projectId":"chats"`) || page.Epoch == archive.feedEpoch([]string{"p1"}) {
		t.Fatalf("changes %s", w.Body.String())
	}
	for _, query := range []string{"", "&projectId=chats"} {
		if w := f.call(t, "GET", "/v1/archive/search?q=lisbon"+query, nil); w.Code != 200 || !strings.Contains(w.Body.String(), chat) {
			t.Fatalf("search%s: %d %s", query, w.Code, w.Body.String())
		}
	}
	if w := f.call(t, "GET", "/v1/archive/chat?chatId="+chat, nil); w.Code != 200 {
		t.Fatalf("archived plain chat: %d %s", w.Code, w.Body.String())
	}
	// The backfill imports the Chats space's chats too.
	home := f.host.plainChats.home
	f.oc.set(func(o *fakeOpenCode) {
		o.reverts["ses_older"] = ""
		o.sessionDirs["ses_older"] = home
		o.messages["ses_older"] = []any{map[string]any{"info": map[string]any{"id": "msg_old", "role": "user", "time": map[string]int64{"created": fixtureEpochMs}}, "parts": []any{map[string]string{"type": "text", "text": "an older plain chat"}}}}
	})
	f.host.backfill.gap = 0
	if err := f.host.backfill.run(t.Context()); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	imported, err := archive.ArchivedChat(t.Context(), "ses_older")
	if err != nil || imported.ProjectID != "chats" {
		t.Fatalf("backfill %+v %v", imported, err)
	}
	if w := f.call(t, "GET", "/v1/archive/search?q=older&projectId=chats", nil); !strings.Contains(w.Body.String(), "ses_older") {
		t.Fatalf("search after the backfill %s", w.Body.String())
	}
}

func TestPlainChatNoticesNameTheChatsSpace(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{LocalSessionToken: testLocalSession})
	f.host.chat.mu.Lock()
	f.host.chatObserved(hubEvent{key: sessionKey{"chats", "ses_plain"}, title: "Tides", turn: "msg_1", outcome: "completed"})
	f.host.chat.mu.Unlock()
	var notices struct{ Notices []Notice }
	waitFor(t, "the notice", func() bool {
		w := localRequest(t, f.host.Handler(), "GET", "/v1/notices", testLocalSession, nil)
		json.Unmarshal(w.Body.Bytes(), &notices)
		return len(notices.Notices) == 1
	})
	if notice := notices.Notices[0]; notice.ProjectID != "chats" || notice.ProjectName != "Chats" || notice.SessionID != "ses_plain" || notice.Kind != noticeTurnFinished {
		t.Fatalf("notice %+v", notice)
	}
}

// Instruction files are listed as OpenCode would add them.
func TestPlainChatInstructionFiles(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "Users", "owner")
	chatHome := filepath.Join(home, "Library", "AgentLand", "host.json.chat-home")
	os.MkdirAll(chatHome, 0700)
	for _, path := range []string{filepath.Join(home, "CLAUDE.md"), filepath.Join(root, "CONTEXT.md"), filepath.Join(chatHome, "AGENTS.md")} {
		os.WriteFile(path, []byte("x"), 0600)
	}
	os.Mkdir(filepath.Join(home, "Library", "AGENTS.md"), 0700) // a folder is not an instruction file
	got := scanPlainChatInstructions(chatHome, root, home, "", home)
	want := []string{"~/Library/AgentLand/host.json.chat-home/AGENTS.md", "~/CLAUDE.md", filepath.Join(root, "CONTEXT.md")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("instruction files %v\nwant %v", got, want)
	}
	if got := scanPlainChatInstructions(t.TempDir(), "", "", "", ""); got != nil {
		t.Fatalf("none: %v", got)
	}
}

// The persona says what the owner asked for, in plain words.
func TestPlainChatPersona(t *testing.T) {
	for _, words := range []string{"AgentLand's assistant", "websearch", "agentland_fetch", "memory", "cite"} {
		if !strings.Contains(plainChatPersona, words) {
			t.Errorf("the persona does not mention %q", words)
		}
	}
}

// errorField is the member a refusal names in error.field, or "".
func errorField(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct{ Error struct{ Field string } }
	json.Unmarshal(w.Body.Bytes(), &body)
	return body.Error.Field
}
