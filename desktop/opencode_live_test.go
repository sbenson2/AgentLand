// Adapted from the owner's independent prototype integration test.
package host_test

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	host "agentland/host"
)

// This opt-in compatibility check starts only a disposable OpenCode instance.
// It inherits no provider credentials and makes no model calls: its one prompt
// is recorded with noReply, which OpenCode stores without running the agent.
func TestInstalledOpenCodeCompatibility(t *testing.T) {
	binary := os.Getenv("AGENTLAND_TEST_OPENCODE")
	if binary == "" {
		t.Skip("set AGENTLAND_TEST_OPENCODE to an installed OpenCode binary")
	}
	root := t.TempDir()
	var environment []string
	for _, key := range []string{"HOME", "PATH", "USER", "LANG", "SYSTEMROOT"} {
		if value, ok := os.LookupEnv(key); ok {
			environment = append(environment, key+"="+value)
		}
	}
	// HOME is deliberately preserved. OpenCode provides a supported test-home
	// override; isolate every XDG path and verify them before starting a server.
	for key, name := range map[string]string{"OPENCODE_TEST_HOME": "home", "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_STATE_HOME": "state", "XDG_CACHE_HOME": "cache", "TMPDIR": "tmp"} {
		location := filepath.Join(root, name)
		if err := os.Mkdir(location, 0700); err != nil {
			t.Fatal(err)
		}
		environment = append(environment, key+"="+location)
	}
	project := filepath.Join(root, "project")
	if err := os.Mkdir(project, 0700); err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	password := hex.EncodeToString(secret)
	environment = append(environment, "OPENCODE_SERVER_PASSWORD="+password, "OPENCODE_DISABLE_AUTOUPDATE=true", "SHELL=/bin/sh", "HISTFILE="+filepath.Join(root, "shell-history"))
	paths := exec.Command(binary, "debug", "paths")
	paths.Env = environment
	paths.Dir = project
	output, err := paths.Output()
	if err != nil {
		t.Fatal("OpenCode path inspection failed")
	}
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) < 6 {
		t.Fatal("OpenCode path inspection format changed")
	}
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			t.Fatal("OpenCode path inspection format changed")
		}
		name, location := fields[0], strings.TrimSpace(strings.TrimPrefix(line, fields[0]))
		relative, err := filepath.Rel(root, location)
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			t.Fatalf("OpenCode %s path escaped isolated directory", name)
		}
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	log, err := os.OpenFile(filepath.Join(root, "opencode.log"), os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	command := exec.Command(binary, "serve", "--pure", "--hostname", "127.0.0.1", "--port", strconv.Itoa(port))
	command.Env = environment
	command.Dir = project
	command.Stdout = log
	command.Stderr = log
	if err := command.Start(); err != nil {
		t.Fatal("isolated OpenCode did not start")
	}
	defer func() { _ = command.Process.Kill(); _ = command.Wait() }()
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(30 * time.Second)
	var version string
	for time.Now().Before(deadline) {
		request, _ := http.NewRequest("GET", base+"/global/health", nil)
		request.SetBasicAuth("opencode", password)
		response, err := client.Do(request)
		if err == nil {
			var health struct {
				Healthy bool
				Version string
			}
			decodeErr := json.NewDecoder(response.Body).Decode(&health)
			response.Body.Close()
			if decodeErr == nil && health.Healthy {
				version = health.Version
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if version == "" {
		t.Fatal("isolated OpenCode startup timed out")
	}
	store := host.NewStore(filepath.Join(root, "agentland", "host.json"))
	if err := store.Initialize(host.Config{OpenCodeURL: base, PasswordEnv: "UNUSED_TEST_PASSWORD", Projects: []host.Project{{ID: "fixture", Name: "Fixture", Directory: project}}}); err != nil {
		t.Fatal(err)
	}
	adapter := host.NewOpenCodeAdapter(base, "opencode", password, nil)
	attachments, err := host.NewAttachmentStore(store.Path + ".attachments")
	if err != nil {
		t.Fatal(err)
	}
	app := host.NewWithOptions(store, adapter, host.HostOptions{TerminalEnabled: true, Attachments: attachments, WorkspaceHome: root})
	defer app.Close()
	server := httptest.NewTLSServer(app.Handler())
	defer server.Close()
	apiClient := server.Client()
	apiClient.Timeout = 10 * time.Second
	var token string
	call := func(method, route string, payload any, want int, destination any) {
		t.Helper()
		body, _ := json.Marshal(payload)
		request, _ := http.NewRequest(method, server.URL+route, bytes.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := apiClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != want {
			t.Fatalf("%s %s returned %d, want %d", method, route, response.StatusCode, want)
		}
		if destination != nil {
			if err := json.NewDecoder(io.LimitReader(response.Body, 2<<20)).Decode(destination); err != nil {
				t.Fatal(err)
			}
		}
	}
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	var paired struct{ Token string }
	call("POST", "/v1/pair", map[string]string{"code": code, "deviceName": "Disposable compatibility fixture"}, 200, &paired)
	token = paired.Token
	var session host.Session
	call("POST", "/v1/sessions", map[string]string{"projectId": "fixture", "title": "No-provider compatibility check"}, 201, &session)
	call("GET", "/v1/messages?projectId=fixture&sessionId="+session.ID, nil, 200, nil)
	call("GET", "/v1/chat/options?projectId=fixture", nil, 200, nil)
	var activity host.ChatStatus
	call("GET", "/v1/chat/status?projectId=fixture&sessionId="+session.ID, nil, 200, &activity)
	if activity.State != "idle" {
		t.Fatalf("new session status: %q", activity.State)
	}
	var pending struct {
		Permissions []host.PermissionRequest
		Questions   []host.QuestionRequest
	}
	call("GET", "/v1/interactions?projectId=fixture&sessionId="+session.ID, nil, 200, &pending)
	if len(pending.Permissions) != 0 || len(pending.Questions) != 0 {
		t.Fatal("unexpected imported interactions")
	}
	// The chat event stream stays open while the history checks change the chat.
	stream := openLiveStream(t, server, token, session.ID)
	defer stream.close()
	if ready := stream.next(t, 15*time.Second); ready.Type != "ready" || ready.Resumed {
		t.Fatalf("stream ready: %s", ready.raw)
	}
	if snapshot := stream.next(t, 15*time.Second); snapshot.Type != "snapshot" || len(snapshot.Messages) != 0 || snapshot.Chat.Provider != "opencode" {
		t.Fatalf("stream snapshot: %s", snapshot.raw)
	}
	checkLiveChatHistory(t, base, password, project, session.ID, call, func(route, contentType string, body []byte) []byte {
		t.Helper()
		request, _ := http.NewRequest("POST", server.URL+route, bytes.NewReader(body))
		request.Header.Set("Content-Type", contentType)
		request.Header.Set("Authorization", "Bearer "+token)
		response, err := apiClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if response.StatusCode != 201 {
			t.Fatalf("upload returned %d: %s", response.StatusCode, data)
		}
		return data
	}, func(route string) []byte {
		t.Helper()
		request, _ := http.NewRequest("GET", server.URL+route, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response, err := apiClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if response.StatusCode != 200 {
			t.Fatalf("GET %s returned %d", route, response.StatusCode)
		}
		return data
	})
	checkLiveChatStream(t, stream, call, version, session.ID)
	checkLiveChatTitle(t, stream, call, base, password, project, session.ID)
	var terminal host.TerminalInfo
	call("POST", "/v1/terminals", map[string]any{"projectId": "fixture", "title": "Compatibility shell", "rows": 24, "cols": 80}, 201, &terminal)
	call("POST", "/v1/terminal/resize", map[string]any{"projectId": "fixture", "terminalId": terminal.ID, "rows": 40, "cols": 100}, 200, nil)
	// Assemble the marker in the shell so echoed input cannot satisfy the check.
	input := []byte("printf '\\033[32m%s%s\\033[0m\\n' AGENTLAND_ LIVE_OK\n")
	call("POST", "/v1/terminal/input", map[string]any{"projectId": "fixture", "terminalId": terminal.ID, "data": input}, 200, nil)
	var rendered []byte
	var cursor uint64
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var chunk struct {
			Data   []byte
			Cursor uint64
			Reset  bool
		}
		call("GET", fmt.Sprintf("/v1/terminal/output?projectId=fixture&terminalId=%s&cursor=%d", terminal.ID, cursor), nil, 200, &chunk)
		if chunk.Reset {
			t.Fatal("unexpected terminal replay reset")
		}
		cursor = chunk.Cursor
		rendered = append(rendered, chunk.Data...)
		if bytes.Contains(rendered, []byte("\x1b[32mAGENTLAND_LIVE_OK\x1b[0m")) {
			break
		}
	}
	if !bytes.Contains(rendered, []byte("\x1b[32mAGENTLAND_LIVE_OK\x1b[0m")) {
		t.Fatal("real shell output did not reach the phone API")
	}
	if bytes.Contains(rendered, []byte("\x00{\"cursor\":")) {
		t.Fatal("socket cursor metadata leaked to renderer")
	}
	// Terminal titles: on macOS the list names the job in the shell's
	// foreground, read through the PTY's pid; the shell itself sets no title.
	listedTerminal := func(id string) host.TerminalInfo {
		t.Helper()
		var listed struct{ Terminals []host.TerminalInfo }
		call("GET", "/v1/terminals?projectId=fixture", nil, 200, &listed)
		for _, item := range listed.Terminals {
			if item.ID == id {
				return item
			}
		}
		t.Fatalf("terminal %s is not listed", id)
		return host.TerminalInfo{}
	}
	if shell := listedTerminal(terminal.ID); shell.ProgramTitle != "" || shell.Command != "" {
		t.Fatalf("an idle shell: %+v", shell)
	}
	foreground := ""
	if runtime.GOOS == "darwin" {
		call("POST", "/v1/terminal/input", map[string]any{"projectId": "fixture", "terminalId": terminal.ID, "data": []byte("sleep 5\n")}, 200, nil)
		deadline = time.Now().Add(8 * time.Second)
		for foreground == "" && time.Now().Before(deadline) {
			foreground = listedTerminal(terminal.ID).Command
			time.Sleep(250 * time.Millisecond)
		}
		if foreground != "sleep 5" {
			t.Fatalf("foreground command %q", foreground)
		}
	}
	call("POST", "/v1/terminal/close", map[string]string{"projectId": "fixture", "terminalId": terminal.ID}, 200, nil)
	call("GET", "/v1/terminal/output?projectId=fixture&terminalId="+terminal.ID+"&cursor=0", nil, 404, nil)
	// The named shortcut attaches the actual terminal UI to this same isolated
	// service. No prompt is sent and no provider credential is configured.
	t.Setenv("PATH", filepath.Dir(binary)+string(os.PathListSeparator)+os.Getenv("PATH"))
	var named host.TerminalInfo
	call("POST", "/v1/terminals", map[string]any{"projectId": "fixture", "title": "OpenCode attach check", "rows": 32, "cols": 90, "program": "opencode"}, 201, &named)
	var ui []byte
	cursor = 0
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var chunk struct {
			Data   []byte
			Cursor uint64
			Status string
		}
		call("GET", fmt.Sprintf("/v1/terminal/output?projectId=fixture&terminalId=%s&cursor=%d", named.ID, cursor), nil, 200, &chunk)
		cursor = chunk.Cursor
		ui = append(ui, chunk.Data...)
		if chunk.Status != "running" {
			t.Fatalf("OpenCode terminal exited during startup: %s", chunk.Status)
		}
	}
	if len(ui) < 100 {
		t.Fatalf("OpenCode attach did not render a terminal UI (%d bytes)", len(ui))
	}
	// The TUI names its home screen "OpenCode" with OSC 0 or 2, which says
	// nothing about the work: the host lists no title for it.
	titles := regexp.MustCompile("\x1b\\][02];([^\x07\x1b]*)(?:\x07|\x1b\\\\)").FindAllSubmatch(ui, -1)
	var seen []string
	for _, title := range titles {
		seen = append(seen, string(title[0][2:3])+":"+string(title[1]))
	}
	if len(seen) == 0 || !strings.HasSuffix(seen[len(seen)-1], ":OpenCode") {
		t.Fatalf("OpenCode's TUI titles: %q", seen)
	}
	if listed := listedTerminal(named.ID); listed.ProgramTitle != "" {
		t.Fatalf("the TUI's home title became a program title: %+v", listed)
	}
	call("POST", "/v1/terminal/close", map[string]string{"projectId": "fixture", "terminalId": named.ID}, 200, nil)
	t.Logf("OpenCode %s: isolated paths, pairing, sessions, pending interactions, attachment history, rewind/restore, real PTY input/output/resize/end verified; shell foreground command %q; TUI titles (OSC code:text) %q; no model calls", version, foreground, seen)
}

// checkLiveChatTitle names the chat through the host as a device would: the
// real OpenCode takes the name with PATCH /session/{id}, the stream and the
// sessions list say "device", and a name from an older message is stale.
func checkLiveChatTitle(t *testing.T, stream *liveStream, call func(string, string, any, int, any), base, password, project, sessionID string) {
	t.Helper()
	var page struct{ Messages []struct{ ID string } }
	call("GET", "/v1/chat/messages?projectId=fixture&sessionId="+sessionID, nil, 200, &page)
	if len(page.Messages) < 2 {
		t.Fatalf("messages to name the chat from: %+v", page)
	}
	newest, oldest := page.Messages[0].ID, page.Messages[len(page.Messages)-1].ID
	var named struct{ Title, TitleSource, TitleBasis string }
	call("POST", "/v1/chat/title", map[string]string{"projectId": "fixture", "sessionId": sessionID, "title": "“Compatibility rename.”", "basedOn": newest}, 200, &named)
	if named.Title != "Compatibility rename" || named.TitleSource != "device" || named.TitleBasis != newest {
		t.Fatalf("named: %+v", named)
	}
	request, _ := http.NewRequest("GET", base+"/session/"+sessionID, nil)
	request.SetBasicAuth("opencode", password)
	request.Header.Set("X-OpenCode-Directory", project)
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	var session struct{ Title string }
	json.NewDecoder(response.Body).Decode(&session)
	response.Body.Close()
	if session.Title != "Compatibility rename" {
		t.Fatalf("OpenCode's title after the rename: %q", session.Title)
	}
	updated := stream.until(t, 30*time.Second, func(event liveEvent) bool {
		return event.Type == "chat.updated" && strings.Contains(event.raw, `"titleSource":"device"`)
	})
	if last := updated[len(updated)-1].raw; !strings.Contains(last, `"title":"Compatibility rename","titleSource":"device","titleBasis":"`+newest+`"`) {
		t.Fatalf("chat.updated: %s", last)
	}
	var sessions struct{ Sessions []host.Session }
	call("GET", "/v1/sessions?projectId=fixture", nil, 200, &sessions)
	found := false
	for _, item := range sessions.Sessions {
		if item.ID == sessionID {
			found = item.Title == "Compatibility rename" && item.TitleSource == "device" && item.TitleBasis == newest
		}
	}
	if !found {
		t.Fatalf("sessions after the rename: %+v", sessions.Sessions)
	}
	call("POST", "/v1/chat/title", map[string]string{"projectId": "fixture", "sessionId": sessionID, "title": "Older", "basedOn": oldest}, 409, nil)
	t.Logf("chat title: OpenCode renamed to %q through the host, stream and list say device, an older basis is stale", session.Title)
}

// checkLiveChatHistory records a user message with an image and a large text
// file directly in the disposable OpenCode (noReply, explicit placeholder
// model, so no provider is selected), then checks the host's history mapping
// and a rewind/restore round trip.
func checkLiveChatHistory(t *testing.T, base, password, project, sessionID string, call func(string, string, any, int, any), upload func(string, string, []byte) []byte, get func(string) []byte) {
	t.Helper()
	pixel := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
	// Stored twice (inline text and data URL) this exceeds the old 2 MiB transcript bound.
	notes := strings.Repeat("AGENTLAND_SYNTHETIC_TEXT ", 100000)
	payload, _ := json.Marshal(map[string]any{
		"noReply": true,
		"model":   map[string]string{"providerID": "agentland-fixture", "modelID": "none"},
		"parts": []any{
			map[string]string{"type": "text", "text": "Live attachment check"},
			map[string]string{"type": "file", "mime": "image/png", "filename": "pixel.png", "url": "data:image/png;base64," + pixel},
			map[string]string{"type": "file", "mime": "text/plain", "filename": "notes.txt", "url": "data:text/plain;base64," + base64.StdEncoding.EncodeToString([]byte(notes))},
		},
	})
	request, _ := http.NewRequest("POST", base+"/session/"+sessionID+"/prompt_async", bytes.NewReader(payload))
	request.SetBasicAuth("opencode", password)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-OpenCode-Directory", project)
	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 204 {
		t.Fatalf("noReply prompt returned %d", response.StatusCode)
	}
	route := "/v1/messages?projectId=fixture&sessionId=" + sessionID
	type transcript struct {
		Messages []host.Message
		Rewind   *struct {
			MessageID string `json:"messageId"`
		}
	}
	var history transcript
	var raw []byte
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		raw = get(route)
		history = transcript{}
		if err := json.Unmarshal(raw, &history); err != nil {
			t.Fatal(err)
		}
		if len(history.Messages) > 0 && len(history.Messages[0].Attachments) == 2 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if len(history.Messages) != 1 || history.Rewind != nil {
		t.Fatalf("recorded prompt did not reach the host transcript: %d messages", len(history.Messages))
	}
	message := history.Messages[0]
	names := map[string]string{}
	for _, attachment := range message.Attachments {
		names[attachment.Name] = attachment.MIME
	}
	if message.Role != "user" || message.Text != "Live attachment check" || !strings.HasPrefix(names["pixel.png"], "image/") || names["notes.txt"] != "text/plain" {
		t.Fatalf("history mapping: %+v", message)
	}
	for _, leaked := range []string{"AGENTLAND_SYNTHETIC_TEXT", "base64", "data:"} {
		if bytes.Contains(raw, []byte(leaked)) {
			t.Fatalf("host transcript exposed %q", leaked)
		}
	}
	var stored struct{ ID, Name, MIME string }
	if err := json.Unmarshal(upload("/v1/attachments?projectId=fixture&sessionId="+sessionID+"&name=pixel.png", "image/png", []byte("\x89PNG fixture")), &stored); err != nil || !strings.HasPrefix(stored.ID, "att_") {
		t.Fatalf("upload over TLS: %+v %v", stored, err)
	}
	var rewound struct{ Rewound bool }
	call("POST", "/v1/messages/rewind", map[string]string{"projectId": "fixture", "sessionId": sessionID, "messageId": message.ID}, 200, &rewound)
	history = transcript{}
	json.Unmarshal(get(route), &history)
	if !rewound.Rewound || len(history.Messages) != 0 || history.Rewind == nil || history.Rewind.MessageID != message.ID {
		t.Fatalf("rewind did not hide the message: %+v", history)
	}
	var restored struct{ Restored bool }
	call("POST", "/v1/messages/restore", map[string]string{"projectId": "fixture", "sessionId": sessionID}, 200, &restored)
	history = transcript{}
	json.Unmarshal(get(route), &history)
	if !restored.Restored || len(history.Messages) != 1 || history.Messages[0].ID != message.ID || history.Rewind != nil {
		t.Fatalf("restore did not return the message: %+v", history)
	}
	var capabilities struct{ ChatFeatures []string }
	call("GET", "/v1/capabilities", nil, 200, &capabilities)
	if strings.Join(capabilities.ChatFeatures, ",") != "reasoning,attachments,rewind,events,parts,stop,clientMessageId,regenerate,title" {
		t.Fatalf("chat features: %v", capabilities.ChatFeatures)
	}
}

type liveEvent struct {
	raw      string
	Type     string
	Seq      uint64
	Resumed  bool
	Chat     struct{ Provider string }
	Messages []struct {
		ID    string
		Parts []struct{ Kind string }
	}
	Rewind *struct {
		MessageID string `json:"messageId"`
	}
	Message *struct {
		ID, Role string
		Parts    []struct{ Kind string }
	}
	State, Outcome, TurnID string
}

type liveStream struct {
	lines chan string
	body  io.ReadCloser
}

// openLiveStream opens GET /v1/chat/events over the fixture's TLS listener
// with a client that has no overall timeout.
func openLiveStream(t *testing.T, server *httptest.Server, token, sessionID string) *liveStream {
	t.Helper()
	request, _ := http.NewRequest("GET", server.URL+"/v1/chat/events?projectId=fixture&sessionId="+sessionID, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := (&http.Client{Transport: server.Client().Transport}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 {
		response.Body.Close()
		t.Fatalf("chat events returned %d", response.StatusCode)
	}
	stream := &liveStream{lines: make(chan string, 4096), body: response.Body}
	go func() {
		defer close(stream.lines)
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 64<<10), 256<<10)
		for scanner.Scan() {
			stream.lines <- scanner.Text()
		}
	}()
	return stream
}

func (s *liveStream) close() { s.body.Close() }

func (s *liveStream) next(t *testing.T, within time.Duration) liveEvent {
	t.Helper()
	select {
	case line, open := <-s.lines:
		if !open {
			t.Fatal("chat event stream closed")
		}
		var event liveEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("chat event %q: %v", line, err)
		}
		event.raw = line
		return event
	case <-time.After(within):
		t.Fatalf("no chat event within %v", within)
		return liveEvent{}
	}
}

func (s *liveStream) until(t *testing.T, within time.Duration, match func(liveEvent) bool) []liveEvent {
	t.Helper()
	deadline := time.NewTimer(within)
	defer deadline.Stop()
	var events []liveEvent
	for {
		select {
		case line, open := <-s.lines:
			if !open {
				t.Fatalf("chat event stream closed after %s", liveTypes(events))
			}
			var event liveEvent
			if err := json.Unmarshal([]byte(line), &event); err != nil {
				t.Fatalf("chat event %q: %v", line, err)
			}
			event.raw = line
			events = append(events, event)
			if match(event) {
				return events
			}
		case <-deadline.C:
			var shown []string
			for _, event := range events {
				shown = append(shown, event.raw[:min(len(event.raw), 300)])
			}
			t.Fatalf("no matching chat event within %v; saw:\n%s", within, strings.Join(shown, "\n"))
		}
	}
}

func liveTypes(events []liveEvent) string {
	var types []string
	for _, event := range events {
		types = append(types, event.Type)
	}
	return strings.Join(types, ",")
}

// checkLiveChatStream verifies the event stream against the disposable
// OpenCode: the prompt recorded in checkLiveChatHistory arrived live, the
// rewind and restore rebuilt the chat, and a send through the host used a
// host-made message ID. Its placeholder model is not configured, so OpenCode
// rejects it before any provider is contacted.
func checkLiveChatStream(t *testing.T, stream *liveStream, call func(string, string, any, int, any), version, sessionID string) {
	t.Helper()
	events := stream.until(t, 30*time.Second, func(event liveEvent) bool { return event.Type == "snapshot" && event.Rewind != nil })
	recorded := ""
	for _, event := range events {
		if event.Type == "message.created" && event.Message.Role == "user" {
			recorded = event.Message.ID
		}
	}
	rewound := events[len(events)-1]
	if recorded == "" || len(rewound.Messages) != 0 || rewound.Rewind.MessageID != recorded {
		t.Fatalf("stream during history checks: %s / %s", liveTypes(events), rewound.raw)
	}
	restored := stream.until(t, 30*time.Second, func(event liveEvent) bool { return event.Type == "snapshot" })
	snapshot := restored[len(restored)-1]
	if snapshot.Rewind != nil || len(snapshot.Messages) != 1 || snapshot.Messages[0].ID != recorded || len(snapshot.Messages[0].Parts) != 3 {
		t.Fatalf("snapshot after restore: %s", snapshot.raw)
	}
	clientMessageID := strings.Repeat("L", 40)
	body := map[string]string{"projectId": "fixture", "sessionId": sessionID, "text": "Live stream check", "model": "agentland-fixture/none", "clientMessageId": clientMessageID}
	var receipt struct {
		Accepted          bool
		MessageID, TurnID string
		Duplicate         bool
	}
	call("POST", "/v1/messages", body, 202, &receipt)
	if !receipt.Accepted || receipt.Duplicate || !regexp.MustCompile(`^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$`).MatchString(receipt.MessageID) || receipt.TurnID != receipt.MessageID {
		t.Fatalf("send receipt: %+v", receipt)
	}
	sent := stream.until(t, 30*time.Second, func(event liveEvent) bool {
		return event.Type == "message.created" && event.Message.ID == receipt.MessageID
	})
	finished := stream.until(t, 30*time.Second, func(event liveEvent) bool { return event.Type == "turn.finished" })
	last := finished[len(finished)-1]
	if last.TurnID != receipt.MessageID || last.Outcome != "error" {
		t.Fatalf("turn with an unconfigured model: %s", liveTypes(append(sent, finished...)))
	}
	var repeat struct {
		MessageID string
		Duplicate bool
	}
	call("POST", "/v1/messages", body, 202, &repeat)
	if !repeat.Duplicate || repeat.MessageID != receipt.MessageID {
		t.Fatalf("repeated send: %+v", repeat)
	}
	// Paging from a message uses a cursor the host builds; OpenCode accepts it.
	type page struct {
		Messages []struct{ ID string }
		HasMore  bool
		OldestID string
	}
	var newest, older page
	call("GET", "/v1/chat/messages?projectId=fixture&sessionId="+sessionID+"&limit=1", nil, 200, &newest)
	if len(newest.Messages) != 1 || newest.Messages[0].ID != receipt.MessageID || !newest.HasMore {
		t.Fatalf("newest page: %+v", newest)
	}
	call("GET", "/v1/chat/messages?projectId=fixture&sessionId="+sessionID+"&limit=1&before="+newest.OldestID, nil, 200, &older)
	if len(older.Messages) != 1 || older.Messages[0].ID != recorded || older.HasMore {
		t.Fatalf("older page: %+v", older)
	}
	var withParts struct {
		Messages []struct {
			ID, CreatedAt string
			Parts         []struct{ Kind string }
		}
	}
	call("GET", "/v1/messages?projectId=fixture&sessionId="+sessionID+"&parts=1", nil, 200, &withParts)
	if len(withParts.Messages) < 2 || withParts.Messages[0].ID != recorded || len(withParts.Messages[0].Parts) != 3 || withParts.Messages[0].CreatedAt == "" {
		t.Fatalf("messages with parts: %+v", withParts)
	}
	var capabilities struct {
		ChatProviderInfo struct {
			OpenCode struct{ Version, Transport string } `json:"opencode"`
		}
	}
	call("GET", "/v1/capabilities", nil, 200, &capabilities)
	if capabilities.ChatProviderInfo.OpenCode.Version != version || capabilities.ChatProviderInfo.OpenCode.Transport != "sse" {
		t.Fatalf("provider info: %+v", capabilities.ChatProviderInfo)
	}
	t.Logf("chat stream: live prompt, rewind and restore snapshots, host message ID %s, turn %s (%s)", receipt.MessageID, last.Outcome, liveTypes(append(sent, finished...)))
}
