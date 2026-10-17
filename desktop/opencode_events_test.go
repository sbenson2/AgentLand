package host

import (
	"bufio"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestOpenCodeEventStreamReconnectsAndReadsChatsAgain(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chat.pumpBackoff = 20 * time.Millisecond
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	client := newClientChat(t)
	for _, event := range stream.until(t, "snapshot", 5*time.Second) {
		client.apply(event)
	}
	// While the stream is down OpenCode records a reply the host never hears
	// about; nothing is replayed, so the host reads the chat again.
	f.oc.dropStreams()
	f.oc.addMessages("s1", ocAssistantFixture(2, 1, "Missed while offline"))
	waitFor(t, "a reconnect", func() bool { return f.oc.connects() >= 2 })
	events := stream.until(t, "message.created", 5*time.Second)
	for _, event := range events {
		client.apply(event)
	}
	if created := events[len(events)-1]; created.Message.ID != fixtureID("msg", 2) || created.Message.Parts[0].Text != "Missed while offline" {
		t.Fatalf("after reconnecting: %s", created.raw)
	}
	sameMessages(t, client.ordered(), hubMessages(f.host, sessionKey{"p1", "s1"}))
	// Live events flow again on the new connection.
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	if started := stream.until(t, "status", 5*time.Second); started[len(started)-1].State != "running" {
		t.Fatalf("after reconnecting: %s", eventTypes(started))
	}
}

func TestOpenCodeEventStreamReconnectsAfterSilence(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chat.pumpSilence, f.host.chat.pumpBackoff = 150*time.Millisecond, 10*time.Millisecond
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	// The fixture sends no heartbeats, so the watchdog gives up on each
	// connection and opens a new one.
	waitFor(t, "the watchdog", func() bool { return f.oc.connects() >= 3 })
	if f.oc.openStreams() > 1 {
		t.Fatalf("%d event streams open at once", f.oc.openStreams())
	}
	// Heartbeats keep a connection alive.
	connects := f.oc.connects()
	for index := 0; index < 8; index++ {
		f.oc.emitRaw("event: message\ndata: {\"payload\":{\"id\":\"evt\",\"type\":\"server.heartbeat\",\"properties\":{}}}\n\n")
		time.Sleep(50 * time.Millisecond)
	}
	if f.oc.connects() > connects+1 {
		t.Fatalf("reconnected despite heartbeats: %d to %d", connects, f.oc.connects())
	}
}

func TestOversizedOpenCodeEventsAreReadAgainOverREST(t *testing.T) {
	f, server := streamFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	// An attachment arrives inline as a data URL larger than the event bound.
	image := map[string]any{"id": fixtureID("prt", 201), "sessionID": "s1", "messageID": fixtureID("msg", 2), "type": "file", "mime": "image/png", "filename": "big.png", "url": "data:image/png;base64," + strings.Repeat("A", openCodeEventLimit+1024)}
	user := ocUserFixture(2, "See image")
	user["parts"] = append(user["parts"].([]any), image)
	f.oc.addMessages("s1", user)
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": image, "time": 1})
	events := stream.until(t, "message.created", 5*time.Second)
	created := events[len(events)-1].Message
	if created.ID != fixtureID("msg", 2) || len(created.Parts) != 2 || created.Parts[1].Attachment.Name != "big.png" {
		t.Fatalf("after an oversized event: %+v", created)
	}
	for _, event := range events {
		if strings.Contains(event.raw, "base64") {
			t.Fatal("an attachment's data reached the stream")
		}
	}
	// The stream is still usable afterwards.
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	stream.until(t, "status", 5*time.Second)
}

func TestOpenCodeEventsAreFilteredToProjectDirectories(t *testing.T) {
	f, server := streamFixture(t)
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	// The same session ID in another OpenCode instance is a different chat.
	f.oc.emitIn(t.TempDir(), "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.emitIn("", "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.emit("session.status", map[string]any{"sessionID": "s2", "status": map[string]any{"type": "busy"}})
	f.oc.emit("session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Visible", "directory": f.oc.directory}})
	if next := stream.next(t, 5*time.Second); next.Type != "chat.updated" || next.Title != "Visible" {
		t.Fatalf("an event from elsewhere reached the chat: %s", next.raw)
	}
}

func TestOpenCodeEventStreamStaysOnLoopbackWithoutRedirects(t *testing.T) {
	// The event client dials only loopback addresses.
	client := loopbackStreamClient()
	if _, err := client.Get("http://192.0.2.1:9/global/event"); !errors.Is(err, errNotLoopback) {
		t.Fatalf("non-loopback dial: %v", err)
	}
	// A redirect is not followed.
	followed := false
	var mu sync.Mutex
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		mu.Lock()
		followed = true
		mu.Unlock()
	}))
	defer target.Close()
	f, server := streamFixture(t)
	f.host.chat.pumpWait, f.host.chat.pumpBackoff = 50*time.Millisecond, 10*time.Millisecond
	f.oc.set(func(oc *fakeOpenCode) { oc.eventLocation = target.URL + "/global/event" })
	stream, status, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	if status != 200 {
		t.Fatalf("open: %d", status)
	}
	// The chat still loads over REST while the event stream is refused.
	stream.until(t, "snapshot", 5*time.Second)
	waitFor(t, "a retried connection", func() bool { return f.oc.connects() >= 2 })
	mu.Lock()
	defer mu.Unlock()
	if followed {
		t.Fatal("the event client followed a redirect")
	}
}

type recordingHandler struct {
	mu         sync.Mutex
	events     []openCodeEvent
	connected  []bool
	oversized  []string
	versions   []string
	connection chan struct{}
}

func (r *recordingHandler) openCodeEvent(_ *openCodeEventPump, event openCodeEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
}
func (r *recordingHandler) openCodeConnected(_ *openCodeEventPump, up bool, version string) {
	r.mu.Lock()
	r.connected = append(r.connected, up)
	r.versions = append(r.versions, version)
	r.mu.Unlock()
	if up {
		r.connection <- struct{}{}
	}
}
func (r *recordingHandler) openCodeOversized(_ *openCodeEventPump, directory, sessionID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.oversized = append(r.oversized, directory+"|"+sessionID)
}

func TestServerSentEventsAreParsedLikeOpenCodeSendsThem(t *testing.T) {
	frames := strings.Join([]string{
		": comment\r\n",
		"event: message\r\ndata: {\"payload\":{\"type\":\"server.connected\",\"properties\":{}}}\r\n\r\n",
		// OpenCode's shape, a data line without the space, and a split data field.
		"data: {\"directory\":\"/d\",\"payload\":{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"s1\"}}}\n\n",
		"data:{\"directory\":\"/d\",\"payload\":{\"type\":\"message.removed\",\n",
		"data: \"properties\":{\"sessionID\":\"s2\",\"messageID\":\"m\"}}}\n\n",
		"data: {\"payload\":{\"type\":\"server.heartbeat\",\"properties\":{}}}\n\n",
		"data: {\"payload\":{\"type\":\"sync\",\"syncEvent\":{}}}\n\n",
		"data: not json\n\n",
		"id: 7\nretry: 10\n\n",
		"data: {\"directory\":\"/d\",\"payload\":{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"s3\",\"part\":{\"url\":\"" + strings.Repeat("x", 3000) + "\"}}}}\n\n",
		"data: {\"directory\":\"/d\",\"payload\":{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"s4\"}}}\n\n",
	}, "")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/global/health" {
			w.Write([]byte(`{"healthy":true,"version":"1.18.31"}`))
			return
		}
		if user, password, _ := r.BasicAuth(); user != "opencode" || password != "secret" || r.Header.Get("Accept") != "text/event-stream" {
			http.Error(w, "unauthorized", 401)
			return
		}
		w.Write([]byte(frames))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	handler := &recordingHandler{connection: make(chan struct{}, 4)}
	pump := NewOpenCodeAdapter(upstream.URL, "opencode", "secret", nil).eventPump(handler, time.Minute, 10*time.Millisecond, 10*time.Millisecond)
	pump.limit = 2048
	pump.start()
	<-handler.connection
	waitFor(t, "the frames", func() bool {
		handler.mu.Lock()
		defer handler.mu.Unlock()
		return len(handler.events) == 3
	})
	pump.stop()
	handler.mu.Lock()
	defer handler.mu.Unlock()
	var got []string
	for _, event := range handler.events {
		got = append(got, event.directory+"|"+event.kind+"|"+event.sessionID)
	}
	if strings.Join(got, " ") != "/d|session.idle|s1 /d|message.removed|s2 /d|session.idle|s4" {
		t.Fatalf("events: %v", got)
	}
	var removed struct{ MessageID string }
	json.Unmarshal(handler.events[1].properties, &removed)
	if removed.MessageID != "m" || strings.Join(handler.oversized, " ") != "/d|s3" || handler.versions[0] != "1.18.31" || len(handler.connected) != 2 || handler.connected[1] {
		t.Fatalf("oversized %v versions %v connected %v", handler.oversized, handler.versions, handler.connected)
	}
}

func TestEventLinesAreBounded(t *testing.T) {
	reader := bufio.NewReaderSize(strings.NewReader("short\r\n"+strings.Repeat("x", 100)+"\nnext\n"), 16)
	for _, want := range []struct {
		line string
		long bool
	}{{"short", false}, {strings.Repeat("x", 40), true}, {"next", false}} {
		line, long, err := readEventLine(reader, 40)
		if err != nil || string(line) != want.line || long != want.long {
			t.Fatalf("line %q long %v err %v, want %q", line, long, err, want.line)
		}
	}
	if _, _, err := readEventLine(reader, 40); err == nil {
		t.Fatal("no error at the end")
	}
	if got := sniffJSONString([]byte(`{"directory":"/a/b","payload":{"properties":{"sessionID":"ses_1","x":1`), "sessionID"); got != "ses_1" {
		t.Fatalf("sniffed %q", got)
	}
}

func TestCapabilitiesReportTheOpenCodeVersionOnceConnected(t *testing.T) {
	f, server := streamFixture(t)
	var before hostCapabilities
	json.Unmarshal(f.call(t, "GET", "/v1/capabilities", nil).Body.Bytes(), &before)
	if before.ChatProviderInfo.OpenCode.Version != "" {
		t.Fatal("a version before the host read it")
	}
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	var after hostCapabilities
	json.Unmarshal(f.call(t, "GET", "/v1/capabilities", nil).Body.Bytes(), &after)
	if after.ChatProviderInfo.OpenCode.Version != "1.18.31" || after.ChatProviderInfo.OpenCode.Transport != "sse" {
		t.Fatalf("capabilities: %+v", after.ChatProviderInfo.OpenCode)
	}
}
