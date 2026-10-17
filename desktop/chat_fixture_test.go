package host

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// fakeOpenCode keeps sessions, transcripts and status in memory and records
// every mutation the adapter sends. It also serves OpenCode 1.18.31's
// /global/event stream, which tests drive with emit, emitRaw and dropStreams.
type fakeOpenCode struct {
	mu         sync.Mutex
	directory  string
	server     *httptest.Server
	reverts    map[string]string
	messages   map[string][]any
	status     map[string]string
	prompts    [][]byte
	promptCode int
	dropPrompt bool
	promptGate chan struct{}
	received   chan struct{}
	revertCode int
	revertLog  []string
	unreverts  int
	// Event stream state.
	streams       map[chan string]bool
	eventConnects int
	eventCode     int
	eventLocation string
	closed        chan struct{}
	permissions   []any
	questions     []any
	messageReads  int
	// messageGate, when set, holds transcript reads until it is closed;
	// messageWaiting learns each read it holds.
	messageGate    chan struct{}
	messageWaiting chan struct{}
	// createGate, when set, holds session creation until it is closed.
	createGate chan struct{}
	// Archive backfill and continue (M1 chunk B2): session update times
	// (fixtureEpochMs when unset), created sessions, and each message page
	// read as "session before-cursor".
	updated   map[string]int64
	created   int
	pageReads []string
	listReads int
	// Chat names: session titles ("Fixture" when unset), the titles
	// PATCH /session/{id} set, and a status that refuses them.
	titles    map[string]string
	renames   []string
	renameErr int
	// Plain chats: other folders requests may name (the Chats space's), each
	// session's folder (directory when unset), the bodies of POST /session,
	// and what GET /agent (per folder), GET /mcp, GET /experimental/tool,
	// GET /config and GET /path answer; disposals of an instance (the
	// directory each named, and what GET /agent answers for a folder after
	// one), and the tool server connections asked for (name and directory)
	// with the status each leaves. disposeCode and connectCode, when set,
	// fail those requests with that status; disposeGate, when set, holds a
	// disposal until it is closed or the request ends.
	homes          map[string]bool
	sessionDirs    map[string]string
	createBodies   [][]byte
	agentLists     map[string][]map[string]any
	mcpStatus      map[string]string
	toolIDs        []string
	configModel    string
	pathHome       string
	pathConfig     string
	toolQueries    []string
	disposals      int
	disposeDirs    []string
	reloadedAgents map[string][]map[string]any
	mcpConnects    []string
	connectStatus  string
	disposeCode    int
	connectCode    int
	disposeGate    chan struct{}
}

func (f *fakeOpenCode) reads() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.messageReads
}

func newFakeOpenCode(t *testing.T, directory string) *fakeOpenCode {
	f := &fakeOpenCode{directory: directory, reverts: map[string]string{"s1": ""}, messages: map[string][]any{}, status: map[string]string{}, promptCode: 204, streams: map[chan string]bool{}, closed: make(chan struct{}), updated: map[string]int64{}, titles: map[string]string{},
		homes: map[string]bool{}, sessionDirs: map[string]string{}, agentLists: map[string][]map[string]any{}, mcpStatus: map[string]string{}}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	// Runs before the server closes, so open event streams end first.
	t.Cleanup(func() { close(f.closed) })
	return f
}

// emit sends one bus event to every open event stream, wrapped like
// OpenCode's global stream: {"directory", "payload": {"type", "properties"}}.
func (f *fakeOpenCode) emit(kind string, properties any) {
	f.emitIn(f.directory, kind, properties)
}

func (f *fakeOpenCode) emitIn(directory, kind string, properties any) {
	data, err := json.Marshal(map[string]any{"directory": directory, "payload": map[string]any{"id": "evt_fixture", "type": kind, "properties": properties}})
	if err != nil {
		panic(err)
	}
	f.emitRaw("event: message\ndata: " + string(data) + "\n\n")
}

// emitRaw writes an exact server-sent-events frame to every open stream.
func (f *fakeOpenCode) emitRaw(frame string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for stream := range f.streams {
		stream <- frame
	}
}

// dropStreams ends every open event stream, as when OpenCode restarts.
func (f *fakeOpenCode) dropStreams() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for stream := range f.streams {
		close(stream)
		delete(f.streams, stream)
	}
}

func (f *fakeOpenCode) connects() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.eventConnects
}

func (f *fakeOpenCode) openStreams() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.streams)
}

func (f *fakeOpenCode) serveEvents(w http.ResponseWriter, r *http.Request) {
	if user, password, ok := r.BasicAuth(); !ok || user != "opencode" || password != "fixture" {
		http.Error(w, "unauthorized", 401)
		return
	}
	f.mu.Lock()
	code, location := f.eventCode, f.eventLocation
	f.eventConnects++
	f.mu.Unlock()
	if location != "" {
		http.Redirect(w, r, location, http.StatusFound)
		return
	}
	if code != 0 {
		http.Error(w, "unavailable", code)
		return
	}
	stream := make(chan string, 4096)
	f.mu.Lock()
	f.streams[stream] = true
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		delete(f.streams, stream)
		f.mu.Unlock()
	}()
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(200)
	io.WriteString(w, "event: message\ndata: {\"payload\":{\"id\":\"evt_connected\",\"type\":\"server.connected\",\"properties\":{}}}\n\n")
	w.(http.Flusher).Flush()
	for {
		select {
		case frame, open := <-stream:
			if !open {
				return
			}
			if _, err := io.WriteString(w, frame); err != nil {
				return
			}
			w.(http.Flusher).Flush()
		case <-r.Context().Done():
			return
		case <-f.closed:
			return
		}
	}
}

func ocMessageFixture(id, role, text string) map[string]any {
	return map[string]any{"info": map[string]string{"id": id, "role": role}, "parts": []any{map[string]string{"type": "text", "text": text}}}
}

func fixtureMessageID(message any) string {
	data, _ := json.Marshal(message)
	var decoded struct{ Info struct{ ID string } }
	json.Unmarshal(data, &decoded)
	return decoded.Info.ID
}

func fixtureMessageCreated(message any) int64 {
	data, _ := json.Marshal(message)
	var decoded struct {
		Info struct{ Time struct{ Created int64 } }
	}
	json.Unmarshal(data, &decoded)
	return decoded.Info.Time.Created
}

func (f *fakeOpenCode) addMessages(session string, messages ...map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, message := range messages {
		f.messages[session] = append(f.messages[session], message)
	}
}

func (f *fakeOpenCode) set(update func(*fakeOpenCode)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	update(f)
}

func (f *fakeOpenCode) promptBodies() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]byte{}, f.prompts...)
}

func (f *fakeOpenCode) promptTexts(t *testing.T) []string {
	t.Helper()
	var texts []string
	for _, body := range f.promptBodies() {
		var prompt struct{ Parts []struct{ Type, Text string } }
		if err := json.Unmarshal(body, &prompt); err != nil {
			t.Fatal(err)
		}
		for _, part := range prompt.Parts {
			if part.Type == "text" {
				texts = append(texts, part.Text)
			}
		}
	}
	return texts
}

func (f *fakeOpenCode) serve(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/global/event":
		f.serveEvents(w, r)
		return
	case "/global/health":
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"healthy":true,"version":"1.18.31"}`))
		return
	}
	requestDirectory := r.Header.Get("X-OpenCode-Directory")
	f.mu.Lock()
	known := requestDirectory == f.directory || f.homes[requestDirectory]
	f.mu.Unlock()
	if !known {
		http.Error(w, "wrong project", 400)
		return
	}
	if f.servePlainChatRoutes(w, r, requestDirectory) {
		return
	}
	segments := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(segments) == 3 && segments[2] == "prompt_async" {
		f.prompt(w, r)
		return
	}
	if r.Method == "GET" && len(segments) == 3 && segments[2] == "message" {
		f.mu.Lock()
		gate, waiting := f.messageGate, f.messageWaiting
		f.mu.Unlock()
		if gate != nil {
			if waiting != nil {
				waiting <- struct{}{}
			}
			<-gate
		}
	}
	if r.Method == "POST" && r.URL.Path == "/session" {
		f.mu.Lock()
		gate := f.createGate
		f.mu.Unlock()
		if gate != nil {
			<-gate
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	if r.Method == "GET" && (r.URL.Path == "/permission" || r.URL.Path == "/question") {
		pending := f.permissions
		if r.URL.Path == "/question" {
			pending = f.questions
		}
		if pending == nil {
			pending = []any{}
		}
		json.NewEncoder(w).Encode(pending)
		return
	}
	// Archive backfill and continue: GET /session lists every session and
	// POST /session creates one.
	if r.URL.Path == "/session" && r.Method == "GET" {
		f.listReads++
		list := []any{}
		for id := range f.reverts {
			list = append(list, f.sessionBody(id))
		}
		json.NewEncoder(w).Encode(list)
		return
	}
	if r.URL.Path == "/session" && r.Method == "POST" {
		raw, _ := io.ReadAll(r.Body)
		f.createBodies = append(f.createBodies, raw)
		var in struct{ Title string }
		json.Unmarshal(raw, &in)
		f.created++
		id := fmt.Sprintf("ses_created%d", f.created)
		f.reverts[id] = ""
		// Plain chats: a session lives in the folder it was created for.
		if requestDirectory != f.directory {
			f.sessionDirs[id] = requestDirectory
		}
		body := f.sessionBody(id)
		body["title"] = in.Title
		json.NewEncoder(w).Encode(body)
		return
	}
	if len(segments) < 2 || segments[0] != "session" {
		http.NotFound(w, r)
		return
	}
	if r.Method == "GET" && segments[1] == "status" {
		statuses := map[string]any{}
		for id, state := range f.status {
			statuses[id] = map[string]string{"type": state}
		}
		json.NewEncoder(w).Encode(statuses)
		return
	}
	id := segments[1]
	if _, exists := f.reverts[id]; !exists {
		http.NotFound(w, r)
		return
	}
	session := func() { json.NewEncoder(w).Encode(f.sessionBody(id)) }
	switch {
	case r.Method == "GET" && len(segments) == 2:
		session()
	case r.Method == "PATCH" && len(segments) == 2:
		// OpenCode 1.18.31's session.update: {title?, ...}.
		var in struct {
			Title *string `json:"title"`
		}
		json.NewDecoder(r.Body).Decode(&in)
		if f.renameErr != 0 {
			w.WriteHeader(f.renameErr)
			return
		}
		if in.Title != nil {
			f.titles[id] = *in.Title
			f.renames = append(f.renames, *in.Title)
		}
		session()
	case r.Method == "GET" && segments[2] == "message" && len(segments) == 4:
		for _, message := range f.messages[id] {
			if fixtureMessageID(message) == segments[3] {
				json.NewEncoder(w).Encode(message)
				return
			}
		}
		http.NotFound(w, r)
	case r.Method == "GET" && segments[2] == "message":
		f.messageReads++
		f.pageReads = append(f.pageReads, id+" "+r.URL.Query().Get("before"))
		messages := f.messages[id]
		if messages == nil {
			messages = []any{}
		}
		// Paging like OpenCode 1.18.31: the newest limit messages older than
		// the before cursor, oldest first, and X-Next-Cursor when more exist.
		if limit, _ := strconv.Atoi(r.URL.Query().Get("limit")); limit > 0 {
			end := len(messages)
			if before := r.URL.Query().Get("before"); before != "" {
				var cursor struct {
					ID   string
					Time int64
				}
				data, err := base64.RawURLEncoding.DecodeString(before)
				if err != nil || json.Unmarshal(data, &cursor) != nil {
					http.Error(w, "bad cursor", 400)
					return
				}
				end = -1
				for index, message := range messages {
					if fixtureMessageID(message) == cursor.ID {
						end = index
					}
				}
				if end < 0 || fixtureMessageCreated(messages[end]) != cursor.Time {
					http.Error(w, "bad cursor", 400)
					return
				}
			}
			start := max(0, end-limit)
			if start > 0 {
				w.Header().Set("X-Next-Cursor", openCodePageCursor(fixtureMessageID(messages[start]), fixtureMessageCreated(messages[start])))
			}
			messages = messages[start:end]
		}
		json.NewEncoder(w).Encode(messages)
	case r.Method == "POST" && segments[2] == "revert":
		var in struct {
			MessageID string `json:"messageID"`
		}
		json.NewDecoder(r.Body).Decode(&in)
		if f.revertCode != 0 {
			w.WriteHeader(f.revertCode)
			return
		}
		f.revertLog = append(f.revertLog, in.MessageID)
		f.reverts[id] = in.MessageID
		session()
	case r.Method == "POST" && segments[2] == "unrevert":
		f.unreverts++
		f.reverts[id] = ""
		session()
	default:
		http.NotFound(w, r)
	}
}

// sessionBody is a session as OpenCode returns it; the caller holds f.mu.
func (f *fakeOpenCode) sessionBody(id string) map[string]any {
	updated := f.updated[id]
	if updated == 0 {
		updated = fixtureEpochMs
	}
	title := "Fixture"
	if named, ok := f.titles[id]; ok {
		title = named
	}
	directory := f.directory
	if other := f.sessionDirs[id]; other != "" {
		directory = other
	}
	body := map[string]any{"id": id, "title": title, "directory": directory, "time": map[string]any{"created": fixtureEpochMs - 1000, "updated": updated}}
	if f.reverts[id] != "" {
		body["revert"] = map[string]string{"messageID": f.reverts[id], "snapshot": "private-snapshot"}
	}
	return body
}

func (f *fakeOpenCode) prompt(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.prompts = append(f.prompts, body)
	code, drop, gate, received := f.promptCode, f.dropPrompt, f.promptGate, f.received
	f.mu.Unlock()
	if received != nil {
		received <- struct{}{}
	}
	if gate != nil {
		<-gate
	}
	if drop {
		connection, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			connection.Close()
		}
		return
	}
	w.WriteHeader(code)
}

type chatFixture struct {
	host        *Host
	store       *Store
	token       string
	oc          *fakeOpenCode
	attachments *AttachmentStore
	queue       *PromptQueue
	queuePath   string
	chats       *CLIChats
	chatsPath   string
	runner      *fakeCLIChatRunner
	clock       *testClock
}

// newChatFixture builds a host whose queue dispatcher only runs when a test
// calls maintain, with one injected clock for queue and attachment timing.
func newChatFixture(t *testing.T) *chatFixture {
	t.Helper()
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	stateDirectory := filepath.Join(t.TempDir(), "private-state")
	store := NewStore(filepath.Join(stateDirectory, "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Fixture", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	f := &chatFixture{store: store, oc: oc, runner: &fakeCLIChatRunner{}, clock: &testClock{now: time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)}}
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
	f.attachments.now = f.clock.Now
	f.queue.now = f.clock.Now
	f.host = newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: f.chats, Attachments: f.attachments, Queue: f.queue})
	t.Cleanup(func() { f.host.Close() })
	f.token = paired(t, f.host, store)
	return f
}

func (f *chatFixture) call(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return request(t, f.host.Handler(), method, path, f.token, body)
}

func (f *chatFixture) upload(t *testing.T, token, sessionID, name, contentType string, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest("POST", "/v1/attachments?projectId=p1&sessionId="+url.QueryEscape(sessionID)+"&name="+url.QueryEscape(name), bytes.NewReader(data))
	r.Header.Set("Content-Type", contentType)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	f.host.Handler().ServeHTTP(w, r)
	return w
}

func (f *chatFixture) uploadID(t *testing.T, token, sessionID, name, contentType string, data []byte) string {
	t.Helper()
	w := f.upload(t, token, sessionID, name, contentType, data)
	if w.Code != 201 {
		t.Fatalf("upload %s: %d %s", name, w.Code, w.Body.String())
	}
	var stored struct{ ID string }
	if err := json.Unmarshal(w.Body.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	return stored.ID
}

func (f *chatFixture) cliSession(t *testing.T, provider string) string {
	t.Helper()
	w := f.call(t, "POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": provider, "provider": provider})
	if w.Code != 201 {
		t.Fatalf("create %s chat: %d %s", provider, w.Code, w.Body.String())
	}
	var session Session
	json.Unmarshal(w.Body.Bytes(), &session)
	return session.ID
}

func errorCode(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct{ Error struct{ Code string } }
	json.Unmarshal(w.Body.Bytes(), &body)
	return body.Error.Code
}

func waitFor(t *testing.T, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
