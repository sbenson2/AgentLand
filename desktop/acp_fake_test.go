package host

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The ACP tests run the test binary as a fake ACP agent: this init hook runs
// before the test framework and turns the process into the fake when
// AGENTLAND_FAKE_AGENT=acp (the Claude fake's re-exec, in its own hook). The
// fake follows a JSONL script from AGENTLAND_FAKE_ACP_DIR, one per start
// (script-<n>.jsonl, else script.jsonl), and records its argv, working
// folder, environment and every line it reads there.
func init() {
	switch os.Getenv("AGENTLAND_FAKE_AGENT") {
	case "acp":
		os.Exit(runFakeACP(os.Getenv("AGENTLAND_FAKE_ACP_DIR"), os.Args[1:]))
	case "acp-child":
		// A tool process the fake starts in its process group: it ignores
		// SIGTERM, records its pid and waits to be ended with the group.
		signal.Ignore(syscall.SIGTERM)
		os.WriteFile(os.Getenv("AGENTLAND_FAKE_CHILD_PID"), []byte(fmt.Sprint(os.Getpid())), 0o600)
		time.Sleep(time.Hour)
		os.Exit(0)
	case "opencode-serve":
		os.Exit(runFakeOpenCodeServe(os.Args[1:]))
	}
}

// runFakeOpenCodeServe is `opencode serve --pure --hostname H --port P` for
// OpenCode's update check: /global/health with FAKE_OPENCODE_VERSION,
// /session and /provider, behind basic auth with OPENCODE_SERVER_PASSWORD. It
// records its arguments and environment in FAKE_OPENCODE_DIR/serve.json;
// FAKE_OPENCODE_FAIL=provider makes /provider fail.
func runFakeOpenCodeServe(args []string) int {
	env := map[string]string{}
	for _, item := range os.Environ() {
		name, value, _ := strings.Cut(item, "=")
		env[name] = value
	}
	cwd, _ := os.Getwd()
	record, _ := json.Marshal(map[string]any{"argv": args, "env": env, "cwd": cwd})
	os.WriteFile(filepath.Join(os.Getenv("FAKE_OPENCODE_DIR"), "serve.json"), record, 0o600)
	port := ""
	for index, arg := range args {
		if arg == "--port" && index+1 < len(args) {
			port = args[index+1]
		}
	}
	password := os.Getenv("OPENCODE_SERVER_PASSWORD")
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if user, pass, ok := r.BasicAuth(); !ok || user != "opencode" || pass != password {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/global/health":
			fmt.Fprintf(w, `{"healthy":true,"version":%q}`, os.Getenv("FAKE_OPENCODE_VERSION"))
		case "/session":
			w.Write([]byte(`[]`))
		case "/provider":
			if os.Getenv("FAKE_OPENCODE_FAIL") == "provider" {
				w.WriteHeader(500)
				return
			}
			w.Write([]byte(`{"all":[],"default":{},"connected":[]}`))
		default:
			w.WriteHeader(404)
		}
	})
	if err := http.ListenAndServe("127.0.0.1:"+port, handler); err != nil {
		return 4
	}
	return 0
}

// fakeACPStep is one line of a fake ACP script:
//
//	await {method}: read until a message with this method; a request becomes
//	    the current one
//	reply {result} / error {code, message}: answer the current request
//	notify {method, params} / request {id, method, params}: send
//	awaitResponse {id}: read until the host answers request id
//	sleep {ms}, exit {code}, hang, oversize {bytes}, raw {raw}, stderr {raw}
//	ignoreTerm: ignore SIGTERM from now on
//	child: start a tool process in the fake's process group that ignores
//	    SIGTERM (its pid in child-<n>.pid)
type fakeACPStep struct {
	Do      string          `json:"do"`
	Method  string          `json:"method,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Code    int             `json:"code,omitempty"`
	Message string          `json:"message,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	ID      string          `json:"id,omitempty"`
	Ms      int             `json:"ms,omitempty"`
	Bytes   int             `json:"bytes,omitempty"`
	Raw     string          `json:"raw,omitempty"`
}

type fakeACPMessage struct {
	raw    string
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
}

func runFakeACP(dir string, args []string) int {
	number := 1
	for ; number < 100; number++ {
		marker, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("spawn-%d", number)), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			marker.Close()
			break
		}
	}
	cwd, _ := os.Getwd()
	env := map[string]string{}
	for _, item := range os.Environ() {
		name, value, _ := strings.Cut(item, "=")
		env[name] = value
	}
	record, _ := json.Marshal(map[string]any{"argv": args, "cwd": cwd, "env": env, "pid": os.Getpid()})
	os.WriteFile(filepath.Join(dir, fmt.Sprintf("argv-%d.json", number)), record, 0o600)
	script, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("script-%d.jsonl", number)))
	if err != nil {
		script, _ = os.ReadFile(filepath.Join(dir, "script.jsonl"))
	}
	log, _ := os.OpenFile(filepath.Join(dir, fmt.Sprintf("frames-%d.jsonl", number)), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	messages := make(chan fakeACPMessage, 256)
	go func() {
		defer close(messages)
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 64<<10), 64<<20)
		for scanner.Scan() {
			line := scanner.Text()
			log.WriteString(line + "\n")
			var message fakeACPMessage
			if json.Unmarshal([]byte(line), &message) == nil {
				message.raw = line
				messages <- message
			}
		}
	}()
	out := bufio.NewWriter(os.Stdout)
	write := func(value any) {
		data, _ := json.Marshal(value)
		out.Write(append(data, '\n'))
		out.Flush()
	}
	var current json.RawMessage
	for _, line := range strings.Split(string(script), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var step fakeACPStep
		if json.Unmarshal([]byte(line), &step) != nil {
			return 8
		}
		switch step.Do {
		case "await":
			for {
				message, open := <-messages
				if !open {
					return 3
				}
				if message.Method == step.Method {
					if len(message.ID) > 0 && string(message.ID) != "null" {
						current = message.ID
					}
					break
				}
			}
		case "awaitResponse":
			for {
				message, open := <-messages
				if !open {
					return 3
				}
				if message.Method == "" && string(message.ID) == `"`+step.ID+`"` {
					break
				}
			}
		case "reply":
			result := step.Result
			if len(result) == 0 {
				result = json.RawMessage("{}")
			}
			write(map[string]any{"jsonrpc": "2.0", "id": current, "result": result})
		case "error":
			write(map[string]any{"jsonrpc": "2.0", "id": current, "error": map[string]any{"code": step.Code, "message": step.Message}})
		case "notify":
			write(map[string]any{"jsonrpc": "2.0", "method": step.Method, "params": step.Params})
		case "request":
			write(map[string]any{"jsonrpc": "2.0", "id": step.ID, "method": step.Method, "params": step.Params})
		case "sleep":
			time.Sleep(time.Duration(step.Ms) * time.Millisecond)
		case "exit":
			return step.Code
		case "hang":
			time.Sleep(time.Hour)
		case "oversize":
			out.WriteString(`{"jsonrpc":"2.0","method":"session/update","params":{"x":"` + strings.Repeat("x", step.Bytes) + "\"}}\n")
			out.Flush()
		case "raw":
			out.WriteString(step.Raw + "\n")
			out.Flush()
		case "stderr":
			os.Stderr.WriteString(step.Raw)
		case "ignoreTerm":
			signal.Ignore(syscall.SIGTERM)
		case "child":
			self, _ := os.Executable()
			marker := filepath.Join(dir, fmt.Sprintf("child-%d.pid", number))
			child := exec.Command(self)
			child.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=acp-child", "AGENTLAND_FAKE_CHILD_PID="+marker)
			if child.Start() != nil {
				return 7
			}
			for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
				if _, err := os.Stat(marker); err == nil {
					break
				}
			}
		}
	}
	// Stay until the host closes stdin, as an agent does.
	for range messages {
	}
	return 0
}

// acpFixture is a host with one ACP agent, "fake", installed in its agents
// folder: its command runs the test binary as the fake ACP agent.
type acpFixture struct {
	t       *testing.T
	host    *Host
	store   *Store
	chats   *CLIChats
	server  *httptest.Server
	token   string
	dir     string // the fake's scripts and records
	project Project
}

func newACPFixture(t *testing.T, tune func(*acpConfig)) *acpFixture {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "ACP", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(store.Path+".chats.json", acpTestRunner{})
	if err != nil {
		t.Fatal(err)
	}
	config := acpConfig{initWait: 5 * time.Second, sessionWait: 5 * time.Second, controlWait: 5 * time.Second, cancelWait: 2 * time.Second, stopGrace: 500 * time.Millisecond, baseEnv: []string{"PATH=/usr/bin:/bin", "HOME=" + t.TempDir(), "USER=tester", "AGENTLAND_SECRET_PROBE=must-not-leak", "OPENCODE_SERVER_PASSWORD=must-not-leak", "ANTHROPIC_API_KEY=must-not-leak", "LC_ALL=C.UTF-8"}}
	if tune != nil {
		tune(&config)
	}
	chats.acp = newACPEngine(chats, config)
	files, err := NewAttachmentStore(store.Path + ".attachments")
	if err != nil {
		t.Fatal(err)
	}
	queue, err := NewPromptQueue(store.Path + ".queue.json")
	if err != nil {
		t.Fatal(err)
	}
	host := newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: chats, Attachments: files, Queue: queue, Agents: &AgentOptions{Version: "test"}})
	quietAgents(host.agents, nil, nil, nil)
	host.chatPace = time.Millisecond
	host.chatBeatEvery = time.Hour
	host.chatAuthEvery = time.Hour
	server := httptest.NewServer(host.Handler())
	f := &acpFixture{t: t, host: host, store: store, chats: chats, server: server, dir: t.TempDir(), project: mustProject(t, store)}
	t.Cleanup(func() {
		server.Close()
		host.Close()
		host.agents.close()
	})
	f.token = paired(t, host, store)
	f.install("fake", "1.0.0", self)
	return f
}

// install makes id a registry install whose command runs the fake.
func (f *acpFixture) install(id, version, self string) {
	f.t.Helper()
	store := f.host.agents.store
	if err := store.ensureAgentDir(id); err != nil {
		f.t.Fatal(err)
	}
	folder := store.versionDir(id, version)
	command := writeScript(f.t, filepath.Join(folder, "agent"), "exec '"+self+"' \"$@\"\n")
	current := agentCurrent{Version: version, Command: command, Args: []string{"--acp"}, Kind: "binary", Name: "Fake Agent", InstalledAt: chatTimeOf(time.Now()),
		Env: map[string]string{"AGENTLAND_FAKE_AGENT": "acp", "AGENTLAND_FAKE_ACP_DIR": f.dir, "FAKE_OWN": "kept"}}
	if err := store.writeCurrent(id, current); err != nil {
		f.t.Fatal(err)
	}
}

func (f *acpFixture) script(n int, steps ...map[string]any) {
	f.t.Helper()
	name := "script.jsonl"
	if n > 0 {
		name = fmt.Sprintf("script-%d.jsonl", n)
	}
	lines := []string{}
	for _, step := range steps {
		data, _ := json.Marshal(step)
		lines = append(lines, string(data))
	}
	if err := os.WriteFile(filepath.Join(f.dir, name), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *acpFixture) call(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return request(f.t, f.host.Handler(), method, path, f.token, body)
}

func (f *acpFixture) newChat(provider, title string) Session {
	f.t.Helper()
	w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": title, "provider": provider})
	if w.Code != 201 {
		f.t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	var session Session
	json.Unmarshal(w.Body.Bytes(), &session)
	return session
}

func (f *acpFixture) send(id, text string, extra map[string]any) (*httptest.ResponseRecorder, sendReceipt) {
	f.t.Helper()
	body := map[string]any{"projectId": "p1", "sessionId": id, "text": text}
	for key, value := range extra {
		body[key] = value
	}
	w := f.call("POST", "/v1/messages", body)
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	return w, receipt
}

func (f *acpFixture) mustSend(id, text string) sendReceipt {
	f.t.Helper()
	w, receipt := f.send(id, text, nil)
	if w.Code != 202 {
		f.t.Fatalf("send %q: %d %s", text, w.Code, w.Body)
	}
	return receipt
}

func (f *acpFixture) stream(id string) *streamReader {
	f.t.Helper()
	reader, status, body := openStream(f.t, f.server, f.token, "projectId=p1&sessionId="+id)
	if status != 200 {
		f.t.Fatalf("stream: %d %s", status, body)
	}
	return reader
}

func (f *acpFixture) chat(id string) *acpChat {
	f.t.Helper()
	chat, err := f.chats.acp.chat(f.project, id)
	if err != nil {
		f.t.Fatal(err)
	}
	return chat
}

// messages is the chat's transcript as the engine holds it.
func (f *acpFixture) messages(id string) []ChatMessage {
	chat := f.chat(id)
	chat.mu.Lock()
	defer chat.mu.Unlock()
	return cloneMessages(chat.rec.Messages)
}

func (f *acpFixture) waitIdle(id string) {
	f.t.Helper()
	waitFor(f.t, "the ACP turn to end", func() bool {
		return !f.chat(id).working()
	})
}

// frames returns what the n-th start read, decoded.
func (f *acpFixture) frames(n int) []map[string]any {
	data, _ := os.ReadFile(filepath.Join(f.dir, fmt.Sprintf("frames-%d.jsonl", n)))
	result := []map[string]any{}
	for _, line := range strings.Split(string(data), "\n") {
		var frame map[string]any
		if line != "" && json.Unmarshal([]byte(line), &frame) == nil {
			result = append(result, frame)
		}
	}
	return result
}

// methods lists the methods of the n-th start's frames, in order.
func (f *acpFixture) methods(n int) []string {
	result := []string{}
	for _, frame := range f.frames(n) {
		if method, _ := frame["method"].(string); method != "" {
			result = append(result, method)
		}
	}
	return result
}

// launched is what the n-th start recorded: argv, cwd and environment.
func (f *acpFixture) launched(n int) (args []string, cwd string, env map[string]string) {
	f.t.Helper()
	var record struct {
		Argv []string
		Cwd  string
		Env  map[string]string
	}
	data, err := os.ReadFile(filepath.Join(f.dir, fmt.Sprintf("argv-%d.json", n)))
	if err != nil {
		f.t.Fatalf("start %d: %v", n, err)
	}
	json.Unmarshal(data, &record)
	return record.Argv, record.Cwd, record.Env
}

func (f *acpFixture) started() int {
	count := 0
	for n := 1; ; n++ {
		if _, err := os.Stat(filepath.Join(f.dir, fmt.Sprintf("argv-%d.json", n))); err != nil {
			return count
		}
		count++
	}
}

// Script steps.

func fakeAwait(method string) map[string]any { return map[string]any{"do": "await", "method": method} }
func fakeReply(result any) map[string]any    { return map[string]any{"do": "reply", "result": result} }
func fakeError(code int, message string) map[string]any {
	return map[string]any{"do": "error", "code": code, "message": message}
}
func fakeUpdate(session string, update map[string]any) map[string]any {
	return map[string]any{"do": "notify", "method": "session/update", "params": map[string]any{"sessionId": session, "update": update}}
}
func fakeText(session, kind, text string) map[string]any {
	return fakeUpdate(session, map[string]any{"sessionUpdate": kind, "content": map[string]any{"type": "text", "text": text}})
}

// acpInit is the handshake: initialize answered with caps.
func fakeInit(caps map[string]any) []map[string]any {
	result := map[string]any{"protocolVersion": 1, "agentCapabilities": caps, "authMethods": []any{map[string]any{"id": "login", "name": "Log in with Fake"}, map[string]any{"id": "key", "name": "Use an API key"}}}
	return []map[string]any{fakeAwait("initialize"), fakeReply(result)}
}

// acpNewSession answers session/new with session and modes.
func fakeNewSession(session string, modes any) []map[string]any {
	result := map[string]any{"sessionId": session}
	if modes != nil {
		result["modes"] = modes
	}
	return []map[string]any{fakeAwait("session/new"), fakeReply(result)}
}

func fakeSteps(groups ...any) []map[string]any {
	var steps []map[string]any
	for _, group := range groups {
		switch value := group.(type) {
		case []map[string]any:
			steps = append(steps, value...)
		case map[string]any:
			steps = append(steps, value)
		}
	}
	return steps
}
