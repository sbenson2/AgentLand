package host

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func emitTurn(f *chatFixture, user, reply int, pieces ...string) {
	userMessage := ocUserFixture(user, "Second")
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": userMessage["info"]})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": userMessage["parts"].([]any)[0], "time": 1})
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(reply, user, false)})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(reply, 1, "", false), "time": 2})
	for _, piece := range pieces {
		f.oc.emit("message.part.delta", map[string]any{"sessionID": "s1", "messageID": fixtureID("msg", reply), "partID": fixtureID("prt", reply*100+1), "field": "text", "delta": piece})
	}
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(reply, 1, strings.Join(pieces, ""), true), "time": 3})
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(reply, user, true)})
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
}

func TestChatEventsStreamALiveOpenCodeTurn(t *testing.T) {
	f, server := streamFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	stream, status, body := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	if status != 200 {
		t.Fatalf("open: %d %s", status, body)
	}
	ready := stream.next(t, 5*time.Second)
	if ready.Type != "ready" || ready.Resumed == nil || *ready.Resumed || !strings.HasSuffix(ready.Cursor, ".0") || ready.Seq != 0 {
		t.Fatalf("ready: %s", ready.raw)
	}
	snapshot := stream.next(t, 5*time.Second)
	if snapshot.Type != "snapshot" || len(snapshot.Messages) != 2 || snapshot.HasMore || string(snapshot.Status) != `{"state":"idle"}` || snapshot.Queue == nil || snapshot.Interactions == nil {
		t.Fatalf("snapshot: %s", snapshot.raw)
	}
	if chat := snapshot.Chat; chat == nil || chat.ID != "s1" || chat.Title != "Fixture" || chat.Provider != "opencode" || chat.Model != "anthropic/claude" || chat.Mode != "build" {
		t.Fatalf("snapshot chat: %s", snapshot.raw)
	}
	client := newClientChat(t)
	client.apply(snapshot)
	emitTurn(f, 3, 4, "Hel", "lo ", "wörld")
	events := stream.until(t, "turn.finished", 5*time.Second)
	for _, event := range events {
		client.apply(event)
	}
	kinds := eventTypes(events)
	for _, want := range []string{"message.created,part.created,turn.started,status,message.created,part.created,part.delta", "part.updated,message.updated,status,turn.finished"} {
		if !strings.Contains(kinds, want) {
			t.Fatalf("event order %s lacks %s", kinds, want)
		}
	}
	last := events[len(events)-1]
	if last.Outcome != "completed" || last.TurnID != fixtureID("msg", 3) || last.Usage == nil || last.Usage.Input != 100 || *last.Usage.CostMicros != 2000 {
		t.Fatalf("turn.finished: %s", last.raw)
	}
	if strings.Join(client.turns, " ") != "started:"+fixtureID("msg", 3)+" finished:"+fixtureID("msg", 3)+":completed" || client.status != "idle" {
		t.Fatalf("client turns %v status %s", client.turns, client.status)
	}
	for index, event := range events {
		if index > 0 && event.Seq <= events[index-1].Seq {
			t.Fatalf("seq does not increase: %s after %s", event.raw, events[index-1].raw)
		}
	}
	// The client, the hub and a fresh REST read all agree.
	sameMessages(t, client.ordered(), hubMessages(f.host, sessionKey{"p1", "s1"}))
	f.oc.addMessages("s1", ocUserFixture(3, "Second"), map[string]any{"info": ocAssistantInfo(4, 3, true), "parts": []any{ocTextPartFixture(4, 1, "Hello wörld", true)}})
	page, _, err := f.host.chatProviderFor(Session{ID: "s1"}).page(mustProject(t, f.store), Session{ID: "s1"}, "", 10)
	if err != nil {
		t.Fatal(err)
	}
	for left, right := 0, len(page)-1; left < right; left, right = left+1, right-1 {
		page[left], page[right] = page[right], page[left]
	}
	sameMessages(t, client.ordered(), page)
}

func TestAnAbandonedReplyInAnIdleChatIsAborted(t *testing.T) {
	f, server := streamFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), map[string]any{"info": ocAssistantInfo(2, 1, false), "parts": []any{ocTextPartFixture(2, 1, "Half a rep", false)}})
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	events := stream.until(t, "snapshot", 5*time.Second)
	if messages := events[1].Messages; len(messages) != 2 || messages[1].Status != "aborted" || messages[1].Parts[0].Text != "Half a rep" {
		t.Fatalf("snapshot: %s", events[1].raw)
	}
	// While the chat runs, the same reply is still streaming.
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "busy" })
	load, err := f.host.chatProviderFor(Session{ID: "s1"}).load(mustProject(t, f.store), "s1", 10)
	if err != nil || load.messages[1].Status != "streaming" || load.state != "busy" {
		t.Fatalf("busy load: %+v %v", load.messages, err)
	}
}

func TestChatEventsResumeFromACursorAndSnapshotOtherwise(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chatStreamFor = 300 * time.Millisecond
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	events := stream.until(t, "end", 5*time.Second)
	end := events[len(events)-1]
	if end.Cursor == "" || end.Seq != 2 || !strings.HasSuffix(end.Cursor, ".2") || eventTypes(events) != "turn.started,status,end" {
		t.Fatalf("first stream: %s", eventTypes(events))
	}
	if !stream.ended(time.Second) {
		t.Fatal("the stream stayed open after end")
	}
	// Reconnecting with the cursor resumes: no snapshot, only newer events.
	f.host.chatStreamFor = time.Minute
	resumed, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1&after="+end.Cursor)
	ready := resumed.next(t, 5*time.Second)
	if ready.Type != "ready" || !*ready.Resumed || ready.Cursor != end.Cursor {
		t.Fatalf("resumed ready: %s", ready.raw)
	}
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
	if next := resumed.next(t, 5*time.Second); next.Type != "status" || next.Seq != 3 || next.State != "idle" {
		t.Fatalf("after resuming: %s", next.raw)
	}
	resumed.close()
	// A cursor from another epoch, an unknown future position or garbage gets
	// a snapshot.
	epoch, _, _ := parseChatCursor(end.Cursor)
	for _, cursor := range []string{"0123456789abcdef.1", epoch + ".999", "not-a-cursor", ""} {
		fresh, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1&after="+cursor)
		ready := fresh.next(t, 5*time.Second)
		if ready.Type != "ready" || *ready.Resumed {
			t.Fatalf("cursor %q: %s", cursor, ready.raw)
		}
		if snapshot := fresh.next(t, 5*time.Second); snapshot.Type != "snapshot" || len(snapshot.Messages) != 1 {
			t.Fatalf("cursor %q snapshot: %s", cursor, snapshot.raw)
		}
		fresh.close()
	}
	// A cursor that fell out of the ring also gets a snapshot.
	f.host.chat.mu.Lock()
	chat := f.host.chat.chats[sessionKey{"p1", "s1"}]
	chat.ring.maxEvents = 2
	f.host.chat.mu.Unlock()
	for index := 0; index < 3; index++ {
		for _, state := range []string{"busy", "idle"} {
			f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": state}})
		}
	}
	waitFor(t, "events to pass the old cursor", func() bool {
		f.host.chat.mu.Lock()
		defer f.host.chat.mu.Unlock()
		return chat.ring.first > 4
	})
	stale, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1&after="+end.Cursor)
	if ready := stale.next(t, 5*time.Second); *ready.Resumed {
		t.Fatalf("a cursor outside the ring resumed: %s", ready.raw)
	}
	if snapshot := stale.next(t, 5*time.Second); snapshot.Type != "snapshot" {
		t.Fatalf("expected a snapshot: %s", snapshot.raw)
	}
}

func TestChatEventsBeatEndAndStopping(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chatBeatEvery = 40 * time.Millisecond
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	for index := 0; index < 3; index++ {
		beat := stream.next(t, 2*time.Second)
		if beat.Type != "beat" || !strings.HasSuffix(beat.Cursor, ".0") {
			t.Fatalf("beat: %s", beat.raw)
		}
	}
	f.host.BeginShutdown()
	events := stream.until(t, "stopping", 2*time.Second)
	if last := events[len(events)-1]; last.raw != `{"seq":0,"type":"stopping"}` {
		t.Fatalf("stopping: %s", last.raw)
	}
	if !stream.ended(time.Second) {
		t.Fatal("stream stayed open after stopping")
	}
	late, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	if line := late.next(t, time.Second); line.raw != `{"seq":0,"type":"stopping"}` {
		t.Fatalf("a stream opened while stopping: %s", line.raw)
	}
}

func TestChatEventsEndWhenTheDeviceIsRevoked(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chatAuthEvery = 30 * time.Millisecond
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	state, _ := f.store.Read()
	if err := f.store.RevokeDevice(state.Devices[0].ID); err != nil {
		t.Fatal(err)
	}
	if line := stream.next(t, 2*time.Second); line.Type != "unauthorized" {
		t.Fatalf("after revocation: %s", line.raw)
	}
	if !stream.ended(time.Second) {
		t.Fatal("stream stayed open for a revoked device")
	}
	if _, status, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1"); status != 401 {
		t.Fatalf("revoked device opened a stream: %d", status)
	}
}

func TestChatEventsAllowEightStreamsPerDevice(t *testing.T) {
	f, server := streamFixture(t)
	var streams []*streamReader
	for index := 0; index < chatStreamsPerDevice; index++ {
		stream, status, body := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
		if status != 200 {
			t.Fatalf("stream %d: %d %s", index, status, body)
		}
		stream.until(t, "snapshot", 5*time.Second)
		streams = append(streams, stream)
	}
	_, status, body := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	if status != 429 || !strings.Contains(body, `"code":"stream_limit"`) {
		t.Fatalf("ninth stream: %d %s", status, body)
	}
	// Another device has its own limit.
	other := paired(t, f.host, f.store)
	if stream, status, _ := openStream(t, server, other, "projectId=p1&sessionId=s1"); status != 200 {
		t.Fatalf("other device: %d", status)
	} else {
		stream.close()
	}
	streams[0].close()
	waitFor(t, "a freed stream slot", func() bool {
		f.host.chatStreamsMu.Lock()
		defer f.host.chatStreamsMu.Unlock()
		return f.host.chatStreams[deviceIDFor(t, f.store, f.token)] < chatStreamsPerDevice
	})
	if _, status, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1"); status != 200 {
		t.Fatalf("after closing one: %d", status)
	}
}

func deviceIDFor(t *testing.T, store *Store, token string) string {
	t.Helper()
	device, ok := store.Authenticate(token)
	if !ok {
		t.Fatal("unknown token")
	}
	return device.ID
}

func TestChatEventsUseTheSameAuthorizationAsMessages(t *testing.T) {
	f, server := streamFixture(t)
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["foreign"] = "" })
	for query, want := range map[string]int{
		"projectId=missing&sessionId=s1":                             404,
		"projectId=p1&sessionId=missing":                             404,
		"projectId=p1&sessionId=s1&after=" + strings.Repeat("x", 65): 400,
	} {
		if _, status, body := openStream(t, server, f.token, query); status != want {
			t.Errorf("%s: %d %s", query, status, body)
		}
	}
	if _, status, _ := openStream(t, server, "", "projectId=p1&sessionId=s1"); status != 401 {
		t.Fatalf("no token: %d", status)
	}
	request, _ := http.NewRequest("GET", server.URL+"/v1/chat/events?projectId=p1&sessionId=s1", nil)
	request.Header.Set("Authorization", "Bearer "+f.token)
	request.Header.Set("Origin", "https://example.com")
	if response, err := server.Client().Do(request); err != nil || response.StatusCode != 403 {
		t.Fatalf("browser origin: %v %v", response, err)
	}
	// A session in another directory is not this project's chat.
	outside := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"id": "s9", "directory": t.TempDir()})
	}))
	defer outside.Close()
	f.host.agent = NewOpenCodeAdapter(outside.URL, "opencode", "fixture", outside.Client())
	if _, status, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s9"); status != 404 {
		t.Fatalf("session from another directory: %d", status)
	}
}

func TestChatEventsFollowInteractionsAndTheQueue(t *testing.T) {
	f, server := streamFixture(t)
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	client := newClientChat(t)
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.emit("permission.asked", map[string]any{"id": "per_1", "sessionID": "s1", "permission": "bash", "patterns": []string{"git status"}, "metadata": map[string]string{"description": "Inspect the tree"}, "always": []string{"git status"}, "tool": map[string]string{"messageID": "msg_x", "callID": "call_1"}})
	events := stream.until(t, "interaction.requested", 5*time.Second)
	events = append(events, stream.next(t, 5*time.Second))
	for _, event := range events {
		client.apply(event)
	}
	requested := events[len(events)-2]
	if requested.raw != `{"seq":3,"type":"interaction.requested","interaction":{"id":"per_1","chatId":"s1","kind":"permission","createdAt":"`+requested.Interaction.CreatedAt+`","choices":["once","reject"],"permission":{"tool":"bash","title":"git status","detail":"Inspect the tree","input":"{\"description\":\"Inspect the tree\"}"}}}` {
		t.Fatalf("interaction: %s", requested.raw)
	}
	if client.status != "waiting" {
		t.Fatalf("status with a pending permission: %s (%s)", client.status, eventTypes(events))
	}
	f.oc.emit("permission.replied", map[string]any{"sessionID": "s1", "requestID": "per_1", "reply": "once"})
	resolved := stream.next(t, 5*time.Second)
	running := stream.next(t, 5*time.Second)
	if resolved.raw != `{"seq":5,"type":"interaction.resolved","id":"per_1","outcome":"once"}` || running.State != "running" {
		t.Fatalf("after the reply: %s %s", resolved.raw, running.raw)
	}
	f.oc.emit("question.asked", map[string]any{"id": "que_1", "sessionID": "s1", "questions": []any{map[string]any{"question": "Which one?", "header": "Pick", "options": []any{map[string]string{"label": "A", "description": "First"}}}}})
	question := stream.next(t, 5*time.Second)
	if question.Interaction == nil || question.Interaction.Kind != "question" || len(question.Interaction.Questions) != 1 || !question.Interaction.Questions[0].Custom || question.Interaction.Questions[0].Options[0].Label != "A" {
		t.Fatalf("question: %s", question.raw)
	}
	stream.next(t, 5*time.Second) // waiting
	f.oc.emit("question.rejected", map[string]any{"sessionID": "s1", "requestID": "que_1"})
	if rejected := stream.next(t, 5*time.Second); rejected.Outcome != "rejected" {
		t.Fatalf("rejected: %s", rejected.raw)
	}
	stream.next(t, 5*time.Second) // running
	// Queue changes made through the host reach the stream.
	if w := f.call(t, "POST", "/v1/queue", map[string]string{"projectId": "p1", "sessionId": "s1", "text": strings.Repeat("q", 6000)}); w.Code != 201 {
		t.Fatalf("queue: %d", w.Code)
	}
	queued := stream.next(t, 5*time.Second)
	if queued.Type != "queue.updated" || len(queued.Items) != 1 || len(queued.Items[0].Text) != chatQueueTextLimit || queued.Items[0].Status != "queued" {
		t.Fatalf("queue.updated: %s", clipForLog(queued.raw))
	}
	if w := f.call(t, "POST", "/v1/queue/remove", map[string]string{"projectId": "p1", "sessionId": "s1", "itemId": queued.Items[0].ID}); w.Code != 200 {
		t.Fatalf("remove: %d", w.Code)
	}
	if emptied := stream.next(t, 5*time.Second); emptied.raw != fmt.Sprintf(`{"seq":%d,"type":"queue.updated","items":[]}`, emptied.Seq) {
		t.Fatalf("queue emptied: %s", emptied.raw)
	}
}
