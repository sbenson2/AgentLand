package host

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// The Claude tests run the test binary as a fake claude: this init hook runs
// before the test framework and turns the process into the fake when
// AGENTLAND_FAKE_AGENT=claude (a TestMain-style re-exec that cannot collide
// with another package TestMain). The fake follows a JSONL script from
// AGENTLAND_FAKE_CLAUDE_DIR, one per start (script-<n>.jsonl, else
// script.jsonl), and records its argv and every frame it reads there.
func init() {
	switch os.Getenv("AGENTLAND_FAKE_AGENT") {
	case "claude":
		os.Exit(runFakeClaude(os.Getenv("AGENTLAND_FAKE_CLAUDE_DIR"), os.Args[1:]))
	case "claude-child":
		// A tool process the fake starts: it records its pid and waits to be
		// ended with the group.
		os.WriteFile(os.Getenv("AGENTLAND_FAKE_CHILD_PID"), []byte(fmt.Sprint(os.Getpid())), 0o600)
		time.Sleep(time.Hour)
		os.Exit(0)
	}
}

// fakeClaudeStep is one line of a fake script.
type fakeClaudeStep struct {
	Do       string          `json:"do"`
	Line     json.RawMessage `json:"line,omitempty"`
	Echo     bool            `json:"echo,omitempty"`
	ID       string          `json:"id,omitempty"`
	Request  json.RawMessage `json:"request,omitempty"`
	Subtype  string          `json:"subtype,omitempty"`
	Respond  json.RawMessage `json:"respond,omitempty"`
	Code     int             `json:"code,omitempty"`
	Bytes    int             `json:"bytes,omitempty"`
	Ms       int             `json:"ms,omitempty"`
	Models   json.RawMessage `json:"models,omitempty"`
	Rewind   json.RawMessage `json:"rewind,omitempty"`
	Response json.RawMessage `json:"response,omitempty"`
}

type fakeClaudeFrame struct {
	raw       string
	Type      string          `json:"type"`
	RequestID string          `json:"request_id"`
	UUID      string          `json:"uuid"`
	Message   json.RawMessage `json:"message"`
	Request   struct {
		Subtype string `json:"subtype"`
	} `json:"request"`
	Response struct {
		RequestID string `json:"request_id"`
	} `json:"response"`
}

var fakeClaudeModels = `[{"value":"default","displayName":"Default (recommended)","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"sonnet","displayName":"Sonnet","supportsEffort":true,"supportedEffortLevels":["low","medium","high"]},{"value":"haiku","displayName":"Haiku"}]`

func runFakeClaude(dir string, args []string) int {
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
	for _, name := range []string{"CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS", "CLAUDE_CODE_STARTUP_FAILURE_RESULTS", "AGENTLAND_SECRET_PROBE", "OPENCODE_SERVER_PASSWORD", "CLAUDECODE", "AGENTLAND_CHAT", "AGENTLAND_HOST", "AGENTLAND_HOST_STATE"} {
		if value, ok := os.LookupEnv(name); ok {
			env[name] = value
		}
	}
	record, _ := json.Marshal(map[string]any{"argv": args, "cwd": cwd, "env": env, "pid": os.Getpid()})
	os.WriteFile(filepath.Join(dir, fmt.Sprintf("argv-%d.json", number)), record, 0o600)
	script, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("script-%d.jsonl", number)))
	if err != nil {
		script, _ = os.ReadFile(filepath.Join(dir, "script.jsonl"))
	}
	session, mode := "", ""
	fork := false
	for index, arg := range args {
		if (arg == "--session-id" || arg == "--resume") && index+1 < len(args) {
			session = args[index+1]
		}
		if arg == "--permission-mode" && index+1 < len(args) {
			mode = args[index+1]
		}
		fork = fork || arg == "--fork-session"
	}
	if fork {
		session = newClaudeUUID()
	}
	log, _ := os.OpenFile(filepath.Join(dir, fmt.Sprintf("frames-%d.jsonl", number)), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	fake := &fakeClaude{dir: dir, number: number, session: session, mode: mode, log: log, frames: make(chan fakeClaudeFrame, 256), responses: map[string]bool{}, out: bufio.NewWriter(os.Stdout), rewind: `{"canRewind":true,"filesChanged":[],"insertions":0,"deletions":0}`}
	go fake.readStdin()
	for _, line := range strings.Split(string(script), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var step fakeClaudeStep
		if json.Unmarshal([]byte(line), &step) != nil {
			return 8
		}
		if code, done := fake.run(step); done {
			return code
		}
	}
	return fake.untilEOF()
}

type fakeClaude struct {
	dir       string
	number    int
	session   string
	mode      string
	user      string
	log       *os.File
	frames    chan fakeClaudeFrame
	mu        sync.Mutex
	responses map[string]bool
	out       *bufio.Writer
	outMu     sync.Mutex
	rewind    string
	eof       bool
}

func (f *fakeClaude) readStdin() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	for scanner.Scan() {
		line := scanner.Text()
		f.log.WriteString(line + "\n")
		var frame fakeClaudeFrame
		if json.Unmarshal([]byte(line), &frame) != nil {
			continue
		}
		frame.raw = line
		f.frames <- frame
	}
	close(f.frames)
}

func (f *fakeClaude) write(line string) {
	f.outMu.Lock()
	defer f.outMu.Unlock()
	line = strings.ReplaceAll(line, "$session", f.session)
	line = strings.ReplaceAll(line, "$user", f.user)
	line = strings.ReplaceAll(line, "$mode", f.mode)
	f.out.WriteString(line + "\n")
	f.out.Flush()
}

func (f *fakeClaude) respond(id string, response string) {
	f.write(fmt.Sprintf(`{"type":"control_response","response":{"subtype":"success","request_id":%q,"response":%s}}`, id, response))
}

// answer handles a control request the script is not waiting for.
func (f *fakeClaude) answer(frame fakeClaudeFrame) {
	switch frame.Request.Subtype {
	case "initialize":
		f.respond(frame.RequestID, `{"commands":[],"models":`+fakeClaudeModels+`}`)
	case "set_model", "interrupt":
		f.respond(frame.RequestID, `{}`)
	case "set_permission_mode":
		var body struct {
			Request struct{ Mode string } `json:"request"`
		}
		json.Unmarshal([]byte(frame.raw), &body)
		f.outMu.Lock()
		f.mode = body.Request.Mode
		f.outMu.Unlock()
		f.respond(frame.RequestID, fmt.Sprintf(`{"mode":%q}`, body.Request.Mode))
	case "rewind_files":
		f.respond(frame.RequestID, f.rewind)
	default:
		f.write(fmt.Sprintf(`{"type":"control_response","response":{"subtype":"error","request_id":%q,"error":"Unsupported control request subtype: %s"}}`, frame.RequestID, frame.Request.Subtype))
	}
}

// next returns the next frame the step waits for, answering control
// requests and noting control responses on the way.
func (f *fakeClaude) next(match func(fakeClaudeFrame) bool) (fakeClaudeFrame, bool) {
	timeout := time.NewTimer(20 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case frame, open := <-f.frames:
			if !open {
				f.eof = true
				return fakeClaudeFrame{}, false
			}
			if match(frame) {
				return frame, true
			}
			switch frame.Type {
			case "control_request":
				f.answer(frame)
			case "control_response":
				f.mu.Lock()
				f.responses[frame.Response.RequestID] = true
				f.mu.Unlock()
			}
		case <-timeout.C:
			return fakeClaudeFrame{}, false
		}
	}
}

func (f *fakeClaude) run(step fakeClaudeStep) (int, bool) {
	switch step.Do {
	case "config":
		if len(step.Rewind) > 0 {
			f.rewind = string(step.Rewind)
		}
	case "init":
		frame, ok := f.next(func(frame fakeClaudeFrame) bool {
			return frame.Type == "control_request" && frame.Request.Subtype == "initialize"
		})
		if !ok {
			return 9, true
		}
		models := fakeClaudeModels
		if len(step.Models) > 0 {
			models = string(step.Models)
		}
		f.respond(frame.RequestID, `{"commands":[],"models":`+models+`}`)
	case "user":
		frame, ok := f.next(func(frame fakeClaudeFrame) bool { return frame.Type == "user" })
		if !ok {
			return 9, true
		}
		f.user = frame.UUID
		if step.Echo {
			f.write(fmt.Sprintf(`{"type":"user","message":%s,"session_id":"$session","parent_tool_use_id":null,"uuid":%q,"timestamp":"2026-09-24T10:00:00.000Z","isReplay":true}`, frame.Message, frame.UUID))
		}
	case "emit":
		f.write(string(step.Line))
	case "ask":
		request := string(step.Request)
		f.write(fmt.Sprintf(`{"type":"control_request","request_id":%q,"request":%s}`, step.ID, request))
	case "await":
		f.mu.Lock()
		seen := f.responses[step.ID]
		f.mu.Unlock()
		if !seen {
			if _, ok := f.next(func(frame fakeClaudeFrame) bool {
				return frame.Type == "control_response" && frame.Response.RequestID == step.ID
			}); !ok {
				return 9, true
			}
		}
	case "control":
		frame, ok := f.next(func(frame fakeClaudeFrame) bool {
			return frame.Type == "control_request" && frame.Request.Subtype == step.Subtype
		})
		if !ok {
			return 9, true
		}
		response := `{}`
		if len(step.Respond) > 0 {
			response = string(step.Respond)
		}
		f.respond(frame.RequestID, response)
	case "crash":
		os.Exit(step.Code)
	case "killself":
		// Dies by SIGKILL (on Unix), as a killed CLI does: no exit handlers.
		f.out.Flush()
		if self, err := os.FindProcess(os.Getpid()); err == nil {
			self.Kill()
		}
		time.Sleep(time.Hour)
	case "stderr":
		os.Stderr.Write([]byte(strings.Repeat("e", step.Bytes)))
	case "ignoreTerm":
		signal.Ignore(syscall.SIGTERM)
	case "child":
		self, _ := os.Executable()
		child := exec.Command(self)
		child.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=claude-child", "AGENTLAND_FAKE_CHILD_PID="+filepath.Join(f.dir, fmt.Sprintf("child-%d.pid", f.number)))
		child.Start()
		for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
			if _, err := os.Stat(filepath.Join(f.dir, fmt.Sprintf("child-%d.pid", f.number))); err == nil {
				break
			}
		}
	case "oversized":
		f.outMu.Lock()
		f.out.WriteString(`{"type":"assistant","filler":"` + strings.Repeat("x", step.Bytes) + "\"}\n")
		f.out.Flush()
		f.outMu.Unlock()
	case "sleep":
		time.Sleep(time.Duration(step.Ms) * time.Millisecond)
	case "hang":
		// A sleeping timer keeps the runtime from calling this a deadlock
		// once stdin has closed.
		time.Sleep(time.Hour)
	case "exit":
		return step.Code, true
	}
	return 0, false
}

// untilEOF answers control requests until stdin closes, then exits.
func (f *fakeClaude) untilEOF() int {
	for !f.eof {
		f.next(func(fakeClaudeFrame) bool { return false })
	}
	return 0
}

// Script lines.

func step(fields map[string]any) map[string]any { return fields }

func emit(line string) map[string]any {
	return map[string]any{"do": "emit", "line": json.RawMessage(line)}
}

func claudeEvent(event string) map[string]any {
	return emit(`{"type":"stream_event","session_id":"$session","parent_tool_use_id":null,"uuid":"` + newClaudeUUID() + `","event":` + event + `}`)
}

func systemInit() map[string]any {
	return emit(`{"type":"system","subtype":"init","session_id":"$session","model":"claude-opus-5-5","permissionMode":"$mode","uuid":"` + newClaudeUUID() + `"}`)
}

// assistantBlock is the assistant message Claude Code writes when a content
// block is complete; uuid is its transcript entry.
func assistantBlock(messageID, uuid, block string, extra string) map[string]any {
	if uuid == "" {
		uuid = newClaudeUUID()
	}
	return emit(`{"type":"assistant","message":{"id":"` + messageID + `","type":"message","role":"assistant","model":"claude-opus-5-5","content":[` + block + `],"usage":{"input_tokens":100,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"$session","uuid":"` + uuid + `"` + extra + `}`)
}

func resultLine(subtype string, isError bool, cost float64, extra string) map[string]any {
	return emit(fmt.Sprintf(`{"type":"result","subtype":%q,"is_error":%t,"result":"done","total_cost_usd":%g,"usage":{"input_tokens":100,"output_tokens":42},"session_id":"$session","uuid":%q,"user_message_uuids":["$user"]%s}`, subtype, isError, cost, newClaudeUUID(), extra))
}

func messageStart(messageID string) map[string]any {
	return claudeEvent(`{"type":"message_start","message":{"id":"` + messageID + `","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":7,"cache_creation_input_tokens":3}}}`)
}

// textReply streams one text block as an Anthropic message whose last
// transcript entry is entry.
func textReply(messageID, text, entry string) []any {
	return []any{
		messageStart(messageID),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":` + jsonString(text) + `}}`),
		claudeEvent(`{"type":"content_block_stop","index":0}`),
		assistantBlock(messageID, entry, `{"type":"text","text":`+jsonString(text)+`}`, ""),
		claudeEvent(`{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":42}}`),
		claudeEvent(`{"type":"message_stop"}`),
	}
}

// textTurn is a turn that streams one text reply; entry is the turn's last
// transcript entry ("" for a random one).
func textTurn(messageID, text, entry string, cost float64) []any {
	steps := []any{step(map[string]any{"do": "user", "echo": true}), systemInit()}
	steps = append(steps, textReply(messageID, text, entry)...)
	return append(steps, resultLine("success", false, cost, ""))
}

func jsonString(value string) string {
	data, _ := json.Marshal(value)
	return string(data)
}

// claudeTestRunner runs Claude chats through the engine with a test config.
type claudeTestRunner struct{ config claudeConfig }

func (r claudeTestRunner) Available() []string { return []string{"claude", "codex"} }
func (r claudeTestRunner) Run(context.Context, string, string, string, string, []ChatAttachment) (CLIChatResult, error) {
	return CLIChatResult{}, fmt.Errorf("claude chats run through the engine")
}
func (r claudeTestRunner) claudeEngineConfig() claudeConfig { return r.config }

type claudeFixture struct {
	t       *testing.T
	dir     string
	host    *Host
	store   *Store
	chats   *CLIChats
	token   string
	server  *httptest.Server
	project Project
	queue   *PromptQueue
	files   *AttachmentStore
}

func newClaudeFixture(t *testing.T, tune func(*claudeConfig)) *claudeFixture {
	t.Helper()
	return newClaudeFixtureWith(t, tune, false)
}

func newClaudeFixtureWith(t *testing.T, tune func(*claudeConfig), archived bool) *claudeFixture {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	config := claudeConfig{
		executable:  func() (string, bool) { return self, true },
		env:         []string{"AGENTLAND_FAKE_AGENT=claude", "AGENTLAND_FAKE_CLAUDE_DIR=" + dir},
		stopGrace:   500 * time.Millisecond,
		initWait:    10 * time.Second,
		echoWait:    10 * time.Second,
		controlWait: 10 * time.Second,
	}
	if tune != nil {
		tune(&config)
	}
	f := newClaudeHostWith(t, config, t.TempDir(), archived)
	f.dir = dir
	return f
}

// newClaudeArchiveFixture is newClaudeFixture with an archive, captured every
// 20 ms.
func newClaudeArchiveFixture(t *testing.T) (*claudeFixture, *Archive) {
	t.Helper()
	f := newClaudeFixtureWith(t, nil, true)
	return f, f.host.archive
}

// newClaudeHost serves a host whose Claude chats run with config in the
// project directory.
func newClaudeHost(t *testing.T, config claudeConfig, directory string) *claudeFixture {
	return newClaudeHostWith(t, config, directory, false)
}

func newClaudeHostWith(t *testing.T, config claudeConfig, directory string, archived bool) *claudeFixture {
	t.Helper()
	oc := newFakeOpenCode(t, directory)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Claude", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(store.Path+".chats.json", claudeTestRunner{config: config})
	if err != nil {
		t.Fatal(err)
	}
	files, err := NewAttachmentStore(store.Path + ".attachments")
	if err != nil {
		t.Fatal(err)
	}
	queue, err := NewPromptQueue(store.Path + ".queue.json")
	if err != nil {
		t.Fatal(err)
	}
	options := HostOptions{CLIChats: chats, Attachments: files, Queue: queue}
	if archived {
		options.Archive = openTestArchive(t, store.Path+".archive", ArchiveOptions{})
	}
	host := newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), options)
	if archived {
		host.chat.capture.every = 20 * time.Millisecond
	}
	host.chatPace = time.Millisecond
	host.chatBeatEvery = time.Hour
	host.chatAuthEvery = time.Hour
	server := httptest.NewServer(host.Handler())
	f := &claudeFixture{t: t, host: host, store: store, chats: chats, server: server, project: mustProject(t, store), queue: queue, files: files}
	t.Cleanup(func() {
		server.Close()
		host.Close()
	})
	f.token = paired(t, host, store)
	return f
}

// script writes the steps the n-th process start follows (0: every start
// without its own script).
func (f *claudeFixture) script(n int, steps ...any) {
	f.t.Helper()
	name := "script.jsonl"
	if n > 0 {
		name = fmt.Sprintf("script-%d.jsonl", n)
	}
	lines := []string{}
	for _, item := range steps {
		switch value := item.(type) {
		case []any:
			for _, nested := range value {
				data, _ := json.Marshal(nested)
				lines = append(lines, string(data))
			}
		default:
			data, _ := json.Marshal(value)
			lines = append(lines, string(data))
		}
	}
	if err := os.WriteFile(filepath.Join(f.dir, name), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *claudeFixture) call(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return request(f.t, f.host.Handler(), method, path, f.token, body)
}

func (f *claudeFixture) newChat() string {
	f.t.Helper()
	w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": "Claude", "provider": "claude"})
	if w.Code != 201 {
		f.t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	var session Session
	json.Unmarshal(w.Body.Bytes(), &session)
	return session.ID
}

func (f *claudeFixture) send(id, text string, extra map[string]any) (*httptest.ResponseRecorder, sendReceipt) {
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

func (f *claudeFixture) mustSend(id, text string, extra map[string]any) sendReceipt {
	f.t.Helper()
	w, receipt := f.send(id, text, extra)
	if w.Code != 202 {
		f.t.Fatalf("send %q: %d %s", text, w.Code, w.Body)
	}
	return receipt
}

func (f *claudeFixture) stream(id string) *streamReader {
	f.t.Helper()
	reader, status, body := openStream(f.t, f.server, f.token, "projectId=p1&sessionId="+id)
	if status != 200 {
		f.t.Fatalf("stream: %d %s", status, body)
	}
	return reader
}

// argv returns the arguments the n-th start ran with.
func (f *claudeFixture) argv(n int) []string {
	f.t.Helper()
	var record struct{ Argv []string }
	data, err := os.ReadFile(filepath.Join(f.dir, fmt.Sprintf("argv-%d.json", n)))
	if err != nil {
		f.t.Fatalf("start %d: %v", n, err)
	}
	json.Unmarshal(data, &record)
	return record.Argv
}

func (f *claudeFixture) started() int {
	count := 0
	for n := 1; ; n++ {
		if _, err := os.Stat(filepath.Join(f.dir, fmt.Sprintf("argv-%d.json", n))); err != nil {
			return count
		}
		count++
	}
}

// frames returns what the n-th start read from stdin.
func (f *claudeFixture) frames(n int) []map[string]any {
	f.t.Helper()
	data, _ := os.ReadFile(filepath.Join(f.dir, fmt.Sprintf("frames-%d.jsonl", n)))
	result := []map[string]any{}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		var frame map[string]any
		if json.Unmarshal([]byte(line), &frame) == nil {
			result = append(result, frame)
		}
	}
	return result
}

// controls lists the subtypes of the control requests the n-th start read.
func (f *claudeFixture) controls(n int) []string {
	result := []string{}
	for _, frame := range f.frames(n) {
		if frame["type"] == "control_request" {
			request, _ := frame["request"].(map[string]any)
			subtype, _ := request["subtype"].(string)
			result = append(result, subtype)
		}
	}
	return result
}

// response returns the host's answer to the CLI's request id.
func (f *claudeFixture) response(n int, id string) map[string]any {
	for _, frame := range f.frames(n) {
		response, _ := frame["response"].(map[string]any)
		if frame["type"] == "control_response" && response["request_id"] == id {
			return response
		}
	}
	return nil
}

func (f *claudeFixture) waitIdle(id string) {
	f.t.Helper()
	waitFor(f.t, "the Claude turn to end", func() bool {
		status, _ := f.chats.Status(f.project, id)
		return status.State == "idle"
	})
}
