//go:build darwin || linux

package host

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// The opt-in real check of plain chats (AGENTLAND_TEST_PLAIN_CHAT_OPENCODE=
// <the pinned opencode>): OpenCode runs `serve --pure` in throwaway folders
// with a throwaway HOME and a fake model provider that fails the test if it is
// ever called. The host writes the Chats space's opencode.json, OpenCode
// starts this package's agentland-host as the tool server, and the chat
// agent's rules (GET /agent) and a plain chat's (GET /session/:id), applied as
// OpenCode applies them, leave only the plain chats' tools. No prompt is sent.
func TestInstalledOpenCodeGivesThePlainChatAgentOnlyItsTools(t *testing.T) {
	binary := os.Getenv("AGENTLAND_TEST_PLAIN_CHAT_OPENCODE")
	if binary == "" {
		t.Skip("set AGENTLAND_TEST_PLAIN_CHAT_OPENCODE to the pinned OpenCode binary")
	}
	root := plainStateFolder(t)
	folder := func(parts ...string) string {
		path := filepath.Join(append([]string{root}, parts...)...)
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
		return path
	}
	home, project, state := folder("home"), folder("project"), folder("state")
	// The model provider: any request fails the test.
	var modelCalls atomic.Int64
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		modelCalls.Add(1)
		http.Error(w, "this check makes no model call", http.StatusTeapot)
	}))
	defer model.Close()
	config := map[string]any{"model": "fake/fake-model", "autoupdate": false, "share": "disabled",
		"provider": map[string]any{"fake": map[string]any{"npm": "@ai-sdk/openai-compatible", "name": "Fake",
			"options": map[string]any{"baseURL": model.URL + "/v1", "apiKey": "not-a-key"}, "models": map[string]any{"fake-model": map[string]any{"name": "Fake model"}}}}}
	data, _ := json.Marshal(config)
	if err := os.WriteFile(filepath.Join(folder("config", "opencode"), "opencode.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	// This package's agentland-host, which OpenCode starts as chat-tools.
	executable := filepath.Join(folder("bin"), "agentland-host")
	build := exec.Command("go", "build", "-o", executable, "./cmd/agentland-host")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build agentland-host: %v\n%s", err, output)
	}
	secret := make([]byte, 16)
	rand.Read(secret)
	password := hex.EncodeToString(secret)
	environment := []string{"HOME=" + home, "OPENCODE_TEST_HOME=" + home, "XDG_CONFIG_HOME=" + filepath.Join(root, "config"), "XDG_DATA_HOME=" + folder("data"),
		"XDG_STATE_HOME=" + folder("xdg-state"), "XDG_CACHE_HOME=" + folder("cache"), "TMPDIR=" + folder("tmp"), "SHELL=/bin/sh",
		"OPENCODE_SERVER_PASSWORD=" + password, "OPENCODE_DISABLE_AUTOUPDATE=true", "OPENCODE_DISABLE_MODELS_FETCH=true",
		"OPENCODE_ENABLE_EXA=1", "OPENCODE_WEBSEARCH_PROVIDER=exa"}
	for _, key := range []string{"PATH", "USER", "LANG"} {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	logFile, err := os.OpenFile(filepath.Join(root, "opencode.log"), os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer logFile.Close()
	serve := exec.Command(binary, "serve", "--pure", "--hostname", "127.0.0.1", "--port", strconv.Itoa(port))
	serve.Env, serve.Dir, serve.Stdout, serve.Stderr = environment, project, logFile, logFile
	serve.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := serve.Start(); err != nil {
		t.Fatal(err)
	}
	stopped := false
	stop := func() {
		if stopped {
			return
		}
		stopped = true
		syscall.Kill(-serve.Process.Pid, syscall.SIGTERM)
		done := make(chan struct{})
		go func() { serve.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			syscall.Kill(-serve.Process.Pid, syscall.SIGKILL)
			<-done
		}
	}
	defer stop()
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	waitForOpenCode(t, base, password)

	store := NewStore(filepath.Join(state, "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: base, PasswordEnv: "UNUSED_TEST_PASSWORD", Projects: []Project{{ID: "workspace", Name: "Workspace", Directory: project}}}); err != nil {
		t.Fatal(err)
	}
	adapter := NewOpenCodeAdapter(base, "opencode", password, nil)
	// OpenCode runs with Exa's search, as the Mac app runs it and says so.
	h := newHost(store, adapter, HostOptions{PlainChats: &PlainChatOptions{Executable: executable, Home: home, SearchProvider: "exa", OpenCode: true}})
	defer h.Close()
	token := paired(t, h, store)
	// OpenCode connects the tool server when it first reads the folder.
	deadline := time.Now().Add(60 * time.Second)
	var capability *plainChatsCapability
	for time.Now().Before(deadline) {
		h.plainChats.refresh(t.Context())
		if capability = h.plainChats.capability(); capability != nil && len(capability.Tools) == 3 {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	want := &plainChatsCapability{ProjectID: "chats", Tools: []string{"websearch", "fetch", "memory"}, SearchProvider: "exa"}
	if !reflect.DeepEqual(capability, want) {
		logData, _ := os.ReadFile(filepath.Join(root, "opencode.log"))
		t.Fatalf("capability %+v, want %+v\nOpenCode's log:\n%s", capability, want, logData)
	}
	p := h.plainChats.project()
	var agents []struct {
		Name       string             `json:"name"`
		Mode       string             `json:"mode"`
		Prompt     string             `json:"prompt"`
		Steps      float64            `json:"steps"`
		Permission []ocPermissionRule `json:"permission"`
	}
	if err := adapter.getContext(t.Context(), "GET", "/agent", p, &agents, 8<<20); err != nil {
		t.Fatal(err)
	}
	chat := slices.IndexFunc(agents, func(agent struct {
		Name       string             `json:"name"`
		Mode       string             `json:"mode"`
		Prompt     string             `json:"prompt"`
		Steps      float64            `json:"steps"`
		Permission []ocPermissionRule `json:"permission"`
	}) bool {
		return agent.Name == plainChatAgent
	})
	if chat < 0 || agents[chat].Mode != "primary" || agents[chat].Steps != plainChatSteps || agents[chat].Prompt != plainChatPersona {
		t.Fatalf("the chat agent %+v", agents)
	}
	var servers map[string]struct{ Status string }
	if err := adapter.getContext(t.Context(), "GET", "/mcp", p, &servers, 1<<20); err != nil || servers["agentland"].Status != "connected" {
		t.Fatalf("MCP servers %+v %v", servers, err)
	}
	var builtin []struct{ ID string }
	if err := adapter.getContext(t.Context(), "GET", "/experimental/tool?provider=fake&model=fake-model", p, &builtin, 8<<20); err != nil {
		t.Fatal(err)
	}
	tools := []string{"agentland_fetch", "agentland_memory_save", "agentland_memory_forget"}
	for _, tool := range builtin {
		tools = append(tools, tool.ID)
	}
	for _, expected := range []string{"bash", "read", "edit", "webfetch", "websearch", "task", "invalid"} {
		if !slices.Contains(tools, expected) {
			t.Fatalf("OpenCode's tools %v lack %s", tools, expected)
		}
	}
	// A plain chat, created through the host, carries its own rules.
	w := request(t, h.Handler(), "POST", "/v1/sessions", token, map[string]string{"projectId": "chats", "title": "Live"})
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var created Session
	json.Unmarshal(w.Body.Bytes(), &created)
	var session struct{ Permission []ocPermissionRule }
	if err := adapter.getContext(t.Context(), "GET", "/session/"+created.ID, p, &session, 1<<20); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(session.Permission, plainChatRules()) {
		t.Fatalf("the plain chat's rules %+v", session.Permission)
	}
	allowed := []string{"agentland_fetch", "agentland_memory_forget", "agentland_memory_save", "invalid", "websearch"}
	for label, rules := range map[string][]ocPermissionRule{"the chat agent": agents[chat].Permission, "a plain chat": append(slices.Clone(agents[chat].Permission), session.Permission...)} {
		var enabled []string
		for _, tool := range tools {
			if !openCodeDisabled(tool, rules) {
				enabled = append(enabled, tool)
			}
		}
		slices.Sort(enabled)
		if !reflect.DeepEqual(enabled, allowed) {
			t.Errorf("%s may use %v, want %v", label, enabled, allowed)
		}
	}
	if calls := modelCalls.Load(); calls != 0 {
		t.Fatalf("the model provider was called %d times", calls)
	}
	// Nothing this check started stays running.
	h.Close()
	stop()
	out, _ := exec.Command("ps", "-Ao", "command").Output()
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, executable) || strings.Contains(line, binary+" serve --pure --hostname 127.0.0.1 --port "+strconv.Itoa(port)) {
			t.Fatalf("still running: %s", line)
		}
	}
	t.Logf("OpenCode listed the chat agent with %d rules; of the tools %v a plain chat may use only %v", len(agents[chat].Permission), tools, allowed)
}

func waitForOpenCode(t *testing.T, base, password string) {
	t.Helper()
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		request, _ := http.NewRequest("GET", base+"/global/health", nil)
		request.SetBasicAuth("opencode", password)
		if response, err := client.Do(request); err == nil {
			var health struct{ Healthy bool }
			json.NewDecoder(response.Body).Decode(&health)
			response.Body.Close()
			if health.Healthy {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("OpenCode did not start")
}

// openCodeDisabled is OpenCode 1.18.31's Permission.disabled for one tool: the
// last rule whose permission matches it decides, and it is disabled when that
// rule denies every pattern (packages/opencode/src/permission/index.ts).
func openCodeDisabled(tool string, rules []ocPermissionRule) bool {
	permission := tool
	switch tool {
	case "edit", "write", "apply_patch":
		permission = "edit"
	case "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource":
		permission = "read"
	}
	for index := len(rules) - 1; index >= 0; index-- {
		if openCodeWildcard(permission, rules[index].Permission) {
			return rules[index].Pattern == "*" && rules[index].Action == "deny"
		}
	}
	return false
}

// openCodeWildcard is OpenCode's Wildcard.match: "*" any characters, "?" one.
func openCodeWildcard(input, pattern string) bool {
	escaped := regexp.QuoteMeta(strings.ReplaceAll(pattern, "\\", "/"))
	escaped = strings.ReplaceAll(strings.ReplaceAll(escaped, `\*`, ".*"), `\?`, ".")
	if strings.HasSuffix(escaped, " .*") {
		escaped = strings.TrimSuffix(escaped, " .*") + "( .*)?"
	}
	return regexp.MustCompile("(?s)^" + escaped + "$").MatchString(strings.ReplaceAll(input, "\\", "/"))
}

func TestOpenCodeDisabledFollowsOpenCode(t *testing.T) {
	rules := append([]ocPermissionRule{{"*", "*", "allow"}, {"read", "*.env", "ask"}, {"*", "*", "deny"}}, plainChatRules()[1:]...)
	for tool, disabled := range map[string]bool{"bash": true, "read": true, "edit": true, "write": true, "websearch": false, "agentland_fetch": false, "agentland": true, "invalid": false} {
		if openCodeDisabled(tool, rules) != disabled {
			t.Errorf("%s disabled %v", tool, !disabled)
		}
	}
	if openCodeDisabled("bash", []ocPermissionRule{{"bash", "rm *", "deny"}}) {
		t.Error("a rule for some patterns disabled the tool")
	}
}
