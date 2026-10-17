package host

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func (f *chatFixture) enqueue(t *testing.T, sessionID, text string, extra map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	body := map[string]string{"projectId": "p1", "sessionId": sessionID, "text": text}
	for key, value := range extra {
		body[key] = value
	}
	return f.call(t, "POST", "/v1/queue", body)
}

func (f *chatFixture) queued(t *testing.T, sessionID string) []QueueItem {
	t.Helper()
	w := f.call(t, "GET", "/v1/queue?projectId=p1&sessionId="+sessionID, nil)
	if w.Code != 200 {
		t.Fatalf("list queue: %d %s", w.Code, w.Body.String())
	}
	var body struct{ Items []QueueItem }
	json.Unmarshal(w.Body.Bytes(), &body)
	return body.Items
}

func TestQueueRoutesValidateLimitAndKeepChatsSeparate(t *testing.T) {
	f := newChatFixture(t)
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s2"] = "" })
	w := f.enqueue(t, "s1", "first", nil)
	if w.Code != 201 {
		t.Fatalf("enqueue: %d %s", w.Code, w.Body.String())
	}
	var raw map[string]any
	json.Unmarshal(w.Body.Bytes(), &raw)
	created, err := time.Parse(time.RFC3339, raw["createdAt"].(string))
	if len(raw) != 4 || !strings.HasPrefix(raw["id"].(string), "q_") || raw["text"] != "first" || raw["status"] != "queued" || err != nil || !created.Equal(f.clock.Now()) || strings.Contains(raw["createdAt"].(string), ".") {
		t.Fatalf("queue item: %s", w.Body.String())
	}
	configured := f.enqueue(t, "s1", "second", map[string]string{"model": "deepseek/chat", "agent": "plan"})
	if configured.Code != 201 || !strings.Contains(configured.Body.String(), `"model":"deepseek/chat","agent":"plan"`) {
		t.Fatalf("configured item: %d %s", configured.Code, configured.Body.String())
	}
	for name, test := range map[string]struct {
		text  string
		extra map[string]string
	}{"empty": {"", nil}, "too long": {strings.Repeat("x", 32769), nil}, "model": {"x", map[string]string{"model": "bad"}}, "agent": {"x", map[string]string{"agent": "arbitrary"}}} {
		if w := f.enqueue(t, "s1", test.text, test.extra); w.Code != 400 {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
	if w := f.enqueue(t, "missing", "x", nil); w.Code != 404 {
		t.Fatalf("unknown chat: %d", w.Code)
	}
	if w := f.enqueue(t, "s2", "other chat", nil); w.Code != 201 {
		t.Fatalf("second chat: %d", w.Code)
	}
	for index := 2; index < 20; index++ {
		if w := f.enqueue(t, "s1", "more", nil); w.Code != 201 {
			t.Fatalf("item %d: %d", index, w.Code)
		}
	}
	if w := f.enqueue(t, "s1", "one too many", nil); w.Code != 409 || errorCode(t, w) != "queue_full" {
		t.Fatalf("21st item: %d %s", w.Code, w.Body.String())
	}
	items := f.queued(t, "s1")
	if len(items) != 20 || items[0].Text != "first" || items[1].Text != "second" {
		t.Fatalf("queue order: %+v", items[:2])
	}
	remove := func(session, id string) *httptest.ResponseRecorder {
		return f.call(t, "POST", "/v1/queue/remove", map[string]string{"projectId": "p1", "sessionId": session, "itemId": id})
	}
	if w := remove("s1", items[0].ID); w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"removed":true}` {
		t.Fatalf("remove: %d %s", w.Code, w.Body.String())
	}
	if w := remove("s1", items[0].ID); w.Code != 404 {
		t.Fatalf("remove twice: %d", w.Code)
	}
	if w := remove("s2", items[1].ID); w.Code != 404 {
		t.Fatalf("removed another chat's item: %d", w.Code)
	}
	if w := remove("s1", ""); w.Code != 400 {
		t.Fatalf("missing item: %d", w.Code)
	}
	restored, err := NewPromptQueue(f.queuePath)
	if err != nil {
		t.Fatal(err)
	}
	if first, second := restored.Items("p1", "s1"), restored.Items("p1", "s2"); len(first) != 19 || first[0].Text != "second" || len(second) != 1 || second[0].Text != "other chat" {
		t.Fatalf("persisted queues: %d %d", len(first), len(second))
	}
	if info, err := os.Stat(f.queuePath); err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
		t.Fatalf("queue file: %v %v", info, err)
	}
	cli := f.cliSession(t, "codex")
	if w := f.enqueue(t, cli, "codex task", map[string]string{"model": "codex/default", "agent": "build"}); w.Code != 201 {
		t.Fatalf("CLI item: %d %s", w.Code, w.Body.String())
	}
	if w := f.enqueue(t, cli, "wrong model", map[string]string{"model": "claude/default"}); w.Code != 400 || errorCode(t, w) != "invalid_agent_options" {
		t.Fatalf("CLI model: %d %s", w.Code, w.Body.String())
	}
	plain, store, _ := testHost(t)
	if w := request(t, plain.Handler(), "GET", "/v1/queue?projectId=p1&sessionId=s1", paired(t, plain, store), nil); w.Code != 501 {
		t.Fatalf("host without a queue: %d", w.Code)
	}
}

func TestQueueDispatchesOnlyTheHeadAfterTheChatSettles(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocMessageFixture("msg_u1", "user", "hello"), ocMessageFixture("msg_a1", "assistant", "hi"))
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "busy" })
	f.enqueue(t, "s1", "one", map[string]string{"model": "deepseek/chat"})
	f.enqueue(t, "s1", "two", nil)
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); len(texts) != 0 {
		t.Fatalf("sent while busy: %v", texts)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "idle" })
	f.host.maintain(nil)
	bodies := f.oc.promptBodies()
	if len(bodies) != 1 || !strings.Contains(string(bodies[0]), `"text":"one"`) || !strings.Contains(string(bodies[0]), `"providerID":"deepseek"`) {
		t.Fatalf("first dispatch: %q", bodies)
	}
	if items := f.queued(t, "s1"); len(items) != 1 || items[0].Text != "two" || items[0].Status != "queued" {
		t.Fatalf("queue after dispatch: %+v", items)
	}
	// OpenCode reports idle before it has recorded the prompt; wait for both messages.
	f.host.maintain(nil)
	f.oc.addMessages("s1", ocMessageFixture("msg_u2", "user", "one"))
	f.host.maintain(nil)
	f.oc.addMessages("s1", ocMessageFixture("msg_a2", "assistant", "done"))
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "busy" })
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); len(texts) != 1 {
		t.Fatalf("next item sent before the previous turn settled: %v", texts)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "idle" })
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); strings.Join(texts, ",") != "one,two" {
		t.Fatalf("dispatch order: %v", texts)
	}
	// A turn that never appears in the transcript holds the queue for at most 90 seconds.
	f.enqueue(t, "s1", "three", nil)
	f.host.maintain(nil)
	f.clock.Advance(89 * time.Second)
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); len(texts) != 2 {
		t.Fatalf("settle timeout ignored: %v", texts)
	}
	f.clock.Advance(time.Second)
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); strings.Join(texts, ",") != "one,two,three" {
		t.Fatalf("after timeout: %v", texts)
	}
	if items := f.queued(t, "s1"); len(items) != 0 {
		t.Fatalf("queue not emptied: %+v", items)
	}
}

func TestQueueWaitsForADirectPromptToSettle(t *testing.T) {
	f := newChatFixture(t)
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "busy" })
	f.enqueue(t, "s1", "queued", nil)
	f.host.maintain(nil)
	// The chat becomes idle and a direct prompt arrives before the next tick.
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "idle" })
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "direct"}); w.Code != 202 {
		t.Fatalf("direct prompt: %d", w.Code)
	}
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); strings.Join(texts, ",") != "direct" {
		t.Fatalf("queued item raced a direct prompt: %v", texts)
	}
	f.oc.addMessages("s1", ocMessageFixture("msg_u1", "user", "direct"), ocMessageFixture("msg_a1", "assistant", "ok"))
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); strings.Join(texts, ",") != "direct,queued" {
		t.Fatalf("after the direct turn: %v", texts)
	}
}

func TestQueueFailureBlocksTheChatWithoutRetrying(t *testing.T) {
	f := newChatFixture(t)
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 500 })
	f.enqueue(t, "s1", "one", nil)
	f.enqueue(t, "s1", "two", nil)
	for range 3 {
		f.host.maintain(nil)
	}
	items := f.queued(t, "s1")
	if len(f.oc.promptBodies()) != 1 || items[0].Status != "failed" || items[0].Error != "The agent did not accept this message." || items[1].Status != "queued" {
		t.Fatalf("after a rejected prompt: %d attempts, %+v", len(f.oc.promptBodies()), items)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 204; oc.dropPrompt = true })
	if w := f.call(t, "POST", "/v1/queue/remove", map[string]string{"projectId": "p1", "sessionId": "s1", "itemId": items[0].ID}); w.Code != 200 {
		t.Fatalf("remove failed item: %d", w.Code)
	}
	f.host.maintain(nil)
	f.host.maintain(nil)
	items = f.queued(t, "s1")
	if len(f.oc.promptBodies()) != 2 || len(items) != 1 || items[0].Status != "failed" || !strings.Contains(items[0].Error, "Check the chat") {
		t.Fatalf("after an uncertain delivery: %d attempts, %+v", len(f.oc.promptBodies()), items)
	}
	restored, err := NewPromptQueue(f.queuePath)
	if err != nil || restored.Items("p1", "s1")[0].Status != "failed" {
		t.Fatal("failure was not persisted", err)
	}
}

func TestQueueSkipsARewoundChatUntilRestored(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocMessageFixture("msg_u1", "user", "hello"), ocMessageFixture("msg_a1", "assistant", "hi"))
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s1"] = "msg_u1" })
	f.enqueue(t, "s1", "after", nil)
	f.host.maintain(nil)
	if len(f.oc.promptBodies()) != 0 {
		t.Fatal("queued message sent into a rewound chat")
	}
	if w := f.call(t, "POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": "s1"}); w.Code != 200 {
		t.Fatalf("restore: %d", w.Code)
	}
	f.host.maintain(nil)
	if texts := f.oc.promptTexts(t); strings.Join(texts, ",") != "after" {
		t.Fatalf("after restore: %v", texts)
	}
}

func TestQueueItemCannotBeRemovedWhileSending(t *testing.T) {
	f := newChatFixture(t)
	gate, received := make(chan struct{}), make(chan struct{}, 1)
	f.oc.set(func(oc *fakeOpenCode) { oc.promptGate, oc.received = gate, received })
	w := f.enqueue(t, "s1", "one", nil)
	var item QueueItem
	json.Unmarshal(w.Body.Bytes(), &item)
	done := make(chan struct{})
	go func() { f.host.maintain(nil); close(done) }()
	<-received
	if items := f.queued(t, "s1"); len(items) != 1 || items[0].Status != "sending" {
		t.Fatalf("while sending: %+v", items)
	}
	if w := f.call(t, "POST", "/v1/queue/remove", map[string]string{"projectId": "p1", "sessionId": "s1", "itemId": item.ID}); w.Code != 409 || errorCode(t, w) != "queue_item_sending" {
		t.Fatalf("remove while sending: %d %s", w.Code, w.Body.String())
	}
	close(gate)
	<-done
	if items := f.queued(t, "s1"); len(items) != 0 {
		t.Fatalf("delivered item remains: %+v", items)
	}
}

// A queued message caught mid-dispatch as shutdown begins, which the agent
// then refuses unsent, stays queued, not failed: the queue is kept on disk,
// so the next start sends it, once. Nothing new is sent while the host
// stops. One whose delivery may have happened is still not confirmed.
func TestQueueKeepsAMessageRefusedAsShutdownBegins(t *testing.T) {
	f := newChatFixture(t)
	gate, received := make(chan struct{}), make(chan struct{}, 1)
	f.oc.set(func(oc *fakeOpenCode) { oc.promptGate, oc.received, oc.promptCode = gate, received, 500 })
	f.enqueue(t, "s1", "one", nil)
	f.enqueue(t, "s1", "two", nil)
	done := make(chan struct{})
	go func() { f.host.maintain(nil); close(done) }()
	<-received
	// Shutdown begins while the head is being sent; then OpenCode refuses it
	// (500: certainly not delivered).
	f.host.BeginShutdown()
	close(gate)
	<-done
	items := f.queued(t, "s1")
	if len(items) != 2 || items[0].Text != "one" || items[0].Status != "queued" || items[0].Error != "" || items[1].Status != "queued" {
		t.Fatalf("after the refusal at shutdown: %+v", items)
	}
	f.host.maintain(nil)
	if attempts := len(f.oc.promptBodies()); attempts != 1 {
		t.Fatalf("%d sends while the host stops", attempts)
	}
	// The next start sends it.
	restored, err := NewPromptQueue(f.queuePath)
	if err != nil {
		t.Fatal(err)
	}
	if items := restored.Items("p1", "s1"); len(items) != 2 || items[0].Status != "queued" || items[1].Status != "queued" {
		t.Fatalf("kept on disk: %+v", items)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.promptGate, oc.received, oc.promptCode = nil, nil, 204 })
	next := newHost(f.store, NewOpenCodeAdapter(f.oc.server.URL, "opencode", "fixture", f.oc.server.Client()), HostOptions{Queue: restored})
	t.Cleanup(func() { next.Close() })
	next.maintain(nil)
	if texts := f.oc.promptTexts(t); strings.Join(texts, ",") != "one,one" {
		t.Fatalf("sends: %v (the refused one, then the next start's)", texts)
	}
	if items := restored.Items("p1", "s1"); len(items) != 1 || items[0].Text != "two" || items[0].Status != "queued" {
		t.Fatalf("after the next start: %+v", items)
	}
	// A delivery that may have happened (the connection dropped) is not
	// confirmed, shutdown or not: it is never sent again by itself.
	g := newChatFixture(t)
	gate, received = make(chan struct{}), make(chan struct{}, 1)
	g.oc.set(func(oc *fakeOpenCode) { oc.promptGate, oc.received, oc.dropPrompt = gate, received, true })
	g.enqueue(t, "s1", "maybe", nil)
	done = make(chan struct{})
	go func() { g.host.maintain(nil); close(done) }()
	<-received
	g.host.BeginShutdown()
	close(gate)
	<-done
	if items := g.queued(t, "s1"); len(items) != 1 || items[0].Status != "failed" || !strings.Contains(items[0].Error, "Check the chat") {
		t.Fatalf("an uncertain delivery at shutdown: %+v", items)
	}
}

// ACP agents' processes end when shutdown begins, so a queued message sent
// to one then is refused before anything is recorded: it goes back to
// queued, on disk too, and the chat has no trace of it.
func TestQueueKeepsAnACPMessageRefusedAsShutdownBegins(t *testing.T) {
	f := newACPFixture(t, nil)
	session := f.newChat("fake", "")
	key := sessionKey{"p1", session.ID}
	item, err := f.host.queue.add(key, "later", PromptOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !f.host.queue.begin(key, item.ID) {
		t.Fatal("the head was not marked sending")
	}
	f.host.BeginShutdown()
	waitFor(t, "the ACP engine to close", func() bool {
		f.chats.acp.mu.Lock()
		defer f.chats.acp.mu.Unlock()
		return f.chats.acp.closed
	})
	f.host.sendQueued(key, item, f.project, session, 0)
	if items := f.host.queue.Items("p1", session.ID); len(items) != 1 || items[0].Status != "queued" || items[0].Error != "" {
		t.Fatalf("after the refusal: %+v", items)
	}
	restored, err := NewPromptQueue(f.store.Path + ".queue.json")
	if err != nil {
		t.Fatal(err)
	}
	if items := restored.Items("p1", session.ID); len(items) != 1 || items[0].Status != "queued" {
		t.Fatalf("kept on disk: %+v", items)
	}
	registry, err := os.ReadFile(f.store.Path + ".chats.json")
	if err != nil || !strings.Contains(string(registry), session.ID) || strings.Contains(string(registry), "later") {
		t.Fatalf("the chat's record: %v %s", err, registry)
	}
}

func TestQueueRecoversAnUnconfirmedSendAsFailed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "host.json.queue.json")
	saved := []queueFileEntry{
		{ProjectID: "p1", SessionID: "s1", Items: []QueueItem{{ID: "q_a", Text: "in flight", CreatedAt: "2026-09-23T12:00:00Z", Status: "sending"}, {ID: "q_b", Text: "next", CreatedAt: "2026-09-23T12:00:01Z", Status: "queued"}}},
		{ProjectID: "p1", SessionID: "s2", Items: []QueueItem{{ID: "q_c", Text: "other", CreatedAt: "2026-09-23T12:00:02Z", Status: "queued"}}},
	}
	data, _ := json.Marshal(saved)
	if err := writePrivateState(path, data); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		queue, err := NewPromptQueue(path)
		if err != nil {
			t.Fatal(err)
		}
		items := queue.Items("p1", "s1")
		if len(items) != 2 || items[0].Status != "failed" || items[0].Error != queueRestartError || items[1].Status != "queued" {
			t.Fatalf("restart %d: %+v", attempt, items)
		}
	}
	queue, _ := NewPromptQueue(path)
	if err := queue.remove(sessionKey{"p1", "s1"}, "q_a"); err != nil {
		t.Fatal(err)
	}
	restored, _ := NewPromptQueue(path)
	if first, second := restored.Items("p1", "s1"), restored.Items("p1", "s2"); len(first) != 1 || first[0].ID != "q_b" || len(second) != 1 || second[0].ID != "q_c" {
		t.Fatalf("removal disturbed other chats: %+v %+v", first, second)
	}
}

func TestQueueDispatchesToCLIChats(t *testing.T) {
	f := newChatFixture(t)
	id := f.cliSession(t, "claude")
	f.enqueue(t, id, "first", nil)
	f.enqueue(t, id, "second", nil)
	f.host.maintain(nil)
	waitFor(t, "first reply", func() bool {
		messages, _ := f.chats.Messages(mustProject(t, f.store), id)
		return len(messages) == 2 && messages[1].Text == "Reply to first"
	})
	f.host.maintain(nil)
	waitFor(t, "second reply", func() bool {
		messages, _ := f.chats.Messages(mustProject(t, f.store), id)
		return len(messages) == 4
	})
	if items := f.queued(t, id); len(items) != 0 {
		t.Fatalf("CLI queue: %+v", items)
	}
}

func TestHostCloseStopsTheQueueDispatcher(t *testing.T) {
	_, store, agent := testHost(t)
	queue, err := NewPromptQueue(filepath.Join(t.TempDir(), "queue.json"))
	if err != nil {
		t.Fatal(err)
	}
	h := NewWithOptions(store, agent, HostOptions{Queue: queue})
	closed := make(chan error, 1)
	go func() { closed <- h.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not stop the dispatcher")
	}
	if err := h.Close(); err != nil {
		t.Fatal(err)
	}
}
