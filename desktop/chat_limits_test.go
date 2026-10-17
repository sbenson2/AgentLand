package host

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestLargePartsStayWithinTheLineLimit(t *testing.T) {
	f, server := streamFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	client := newClientChat(t)
	for _, event := range stream.until(t, "snapshot", 5*time.Second) {
		client.apply(event)
	}
	reply := fixtureID("msg", 2)
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(2, 1, false)})
	// About 450 KiB of text whose quotes and newlines grow when encoded, and a
	// tool output of control characters that encodes six times larger.
	text := strings.Repeat("line \"quoted\" é\n", 28000)
	output := strings.Repeat("\x01", 60<<10)
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(2, 1, text, true)})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": map[string]any{"id": fixtureID("prt", 202), "sessionID": "s1", "messageID": reply, "type": "tool", "tool": "bash", "callID": "c1", "state": map[string]any{"status": "completed", "title": "Dump", "input": map[string]string{"command": "cat"}, "output": output, "metadata": map[string]any{}, "time": map[string]any{"start": 1, "end": 2}}}})
	// Streamed text continues where the large part ends.
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(2, 3, "", false)})
	big := strings.Repeat("ü", 150<<10)
	f.oc.emit("message.part.delta", map[string]any{"sessionID": "s1", "messageID": reply, "partID": fixtureID("prt", 203), "field": "text", "delta": big})
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	for _, event := range stream.until(t, "status", 10*time.Second) {
		client.apply(event)
	}
	messages := client.ordered()
	if len(messages) != 2 || len(messages[1].Parts) != 3 {
		t.Fatalf("client state: %d messages", len(messages))
	}
	parts := messages[1].Parts
	if parts[0].Text != text || parts[1].Tool.Output != output || parts[2].Text != big {
		t.Fatalf("large parts were not rebuilt: %d %d %d bytes", len(parts[0].Text), len(parts[1].Tool.Output), len(parts[2].Text))
	}
	sameMessages(t, messages, hubMessages(f.host, sessionKey{"p1", "s1"}))
}

func TestOversizedToolFieldsAreShortenedOnlyInTheStream(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	chat := hubChatFor(t, f, "s1")
	reply := fixtureID("msg", 2)
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(2, 1, false)})
	control := strings.Repeat("\x02", 60<<10)
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": map[string]any{"id": fixtureID("prt", 201), "sessionID": "s1", "messageID": reply, "type": "tool", "tool": "bash", "callID": "c1", "state": map[string]any{"status": "error", "input": map[string]string{"command": control}, "error": control, "time": map[string]any{"start": 1, "end": 2}}}})
	for _, line := range ringLines(f, chat, 0) {
		if len(line) > 256<<10 {
			t.Fatalf("line of %d bytes", len(line))
		}
		if strings.Contains(line, `"part.created"`) && !strings.Contains(line, `"truncated":true`) {
			t.Fatalf("a shortened tool did not say so: %s", clipForLog(line))
		}
	}
	// The hub keeps the full, contract-bounded fields for snapshots and pages.
	if messages := hubMessages(f.host, sessionKey{"p1", "s1"}); len(messages[1].Parts[0].Tool.Error) != len(control) {
		t.Fatal("the hub shortened its own copy")
	}
}

func TestSnapshotOfAHugeNewestMessageIsCompletedByEvents(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chatBeatEvery = 150 * time.Millisecond
	reply := fixtureID("msg", 2)
	var parts []any
	for index := 1; index <= 6; index++ {
		parts = append(parts, map[string]any{"id": fixtureID("prt", 200+index), "sessionID": "s1", "messageID": reply, "type": "tool", "tool": "read", "callID": "c", "state": map[string]any{"status": "completed", "title": "Read", "input": map[string]string{"filePath": "a.go"}, "output": strings.Repeat(string(rune('a'+index)), 60<<10), "metadata": map[string]any{}, "time": map[string]any{"start": 1, "end": 2}}})
	}
	parts = append(parts, ocTextPartFixture(2, 50, "Summary", true))
	f.oc.addMessages("s1", ocUserFixture(1, "Read everything"), map[string]any{"info": ocAssistantInfo(2, 1, true), "parts": parts})
	first, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	watcher := newClientChat(t)
	for _, event := range first.until(t, "beat", 5*time.Second) {
		watcher.apply(event)
	}
	// A second subscriber gets a snapshot that cannot hold the whole message;
	// its remaining parts follow as events, which the first one applies too.
	second, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	fresh := newClientChat(t)
	events := second.until(t, "beat", 5*time.Second)
	for _, event := range events {
		fresh.apply(event)
	}
	snapshot := events[1]
	if snapshot.Type != "snapshot" || len(snapshot.Messages) != 1 || len(snapshot.Messages[0].Parts) >= 7 || !snapshot.HasMore {
		t.Fatalf("snapshot of a huge message: %s", eventTypes(events))
	}
	if !strings.Contains(eventTypes(events), "snapshot,part.updated") {
		t.Fatalf("the snapshot was not completed: %s", eventTypes(events))
	}
	for _, event := range first.until(t, "beat", 5*time.Second) {
		watcher.apply(event)
	}
	want := hubMessages(f.host, sessionKey{"p1", "s1"})
	sameMessages(t, fresh.ordered(), want[1:])
	sameMessages(t, watcher.ordered(), want[1:])
}

// pipeResponse is a ResponseWriter whose writes block until the test reads,
// like a client that stops reading.
type pipeResponse struct {
	header http.Header
	writer *io.PipeWriter
}

func (p *pipeResponse) Header() http.Header              { return p.header }
func (p *pipeResponse) WriteHeader(int)                  {}
func (p *pipeResponse) Write(data []byte) (int, error)   { return p.writer.Write(data) }
func (p *pipeResponse) Flush()                           {}
func (p *pipeResponse) SetWriteDeadline(time.Time) error { return nil }
func (p *pipeResponse) SetReadDeadline(time.Time) error  { return nil }
func (p *pipeResponse) EnableFullDuplex() error          { return nil }
func (p *pipeResponse) readLine(t *testing.T, lines *bufio.Reader) streamEvent {
	t.Helper()
	line, err := lines.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var event streamEvent
	if err := json.Unmarshal([]byte(line), &event); err != nil {
		t.Fatalf("%q: %v", line, err)
	}
	event.raw = strings.TrimSpace(line)
	return event
}

func TestASlowReaderThatFallsBehindTheRingGetsASnapshot(t *testing.T) {
	f := newChatFixture(t)
	f.host.chatPace = time.Millisecond
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	reader, writer := io.Pipe()
	response := &pipeResponse{header: http.Header{}, writer: writer}
	ctx, cancel := context.WithCancel(context.Background())
	request := httptest.NewRequest("GET", "/v1/chat/events?projectId=p1&sessionId=s1", nil).WithContext(ctx)
	request.Header.Set("Authorization", "Bearer "+f.token)
	done := make(chan struct{})
	go func() {
		defer close(done)
		f.host.Handler().ServeHTTP(response, request)
	}()
	defer func() {
		cancel()
		reader.Close()
		<-done
	}()
	lines := bufio.NewReader(reader)
	if ready := response.readLine(t, lines); ready.Type != "ready" {
		t.Fatalf("ready: %s", ready.raw)
	}
	if snapshot := response.readLine(t, lines); snapshot.Type != "snapshot" {
		t.Fatalf("snapshot: %s", snapshot.raw)
	}
	f.host.chat.mu.Lock()
	chat := f.host.chat.chats[sessionKey{"p1", "s1"}]
	chat.ring.maxEvents = 4
	f.host.chat.mu.Unlock()
	// The stream picks up the first event and blocks writing it; everything
	// after it scrolls out of the four-event ring meanwhile.
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	time.Sleep(50 * time.Millisecond)
	for index := 0; index < 10; index++ {
		for _, state := range []string{"idle", "busy"} {
			feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": state}})
		}
	}
	var events []streamEvent
	for len(events) == 0 || events[len(events)-1].Type != "snapshot" {
		events = append(events, response.readLine(t, lines))
		if len(events) > 10 {
			t.Fatalf("no snapshot after falling behind: %s", eventTypes(events))
		}
	}
	last := events[len(events)-1]
	if string(last.Status) != `{"state":"running"}` || last.Seq < 20 {
		t.Fatalf("resync snapshot: %s", last.raw)
	}
}

func TestRewindAndRestoreRebuildTheChatForSubscribers(t *testing.T) {
	f, server := streamFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"), ocUserFixture(3, "Second"), ocAssistantFixture(4, 3, "Two"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	events := stream.until(t, "snapshot", 5*time.Second)
	if len(events[1].Messages) != 4 {
		t.Fatalf("snapshot: %s", events[1].raw)
	}
	if w := f.call(t, "POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": "s1", "messageId": fixtureID("msg", 3)}); w.Code != 200 {
		t.Fatalf("rewind: %d %s", w.Code, w.Body.String())
	}
	session := map[string]any{"id": "s1", "title": "Fixture", "directory": f.oc.directory, "revert": map[string]string{"messageID": fixtureID("msg", 3)}}
	f.oc.emit("session.updated", map[string]any{"sessionID": "s1", "info": session})
	rewound := stream.until(t, "snapshot", 5*time.Second)
	snapshot := rewound[len(rewound)-1]
	if len(snapshot.Messages) != 2 || snapshot.Rewind == nil || snapshot.Rewind.MessageID != fixtureID("msg", 3) {
		t.Fatalf("after rewind: %s", snapshot.raw)
	}
	if w := f.call(t, "POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": "s1"}); w.Code != 200 {
		t.Fatalf("restore: %d", w.Code)
	}
	delete(session, "revert")
	f.oc.emit("session.updated", map[string]any{"sessionID": "s1", "info": session})
	restored := stream.until(t, "snapshot", 5*time.Second)
	if snapshot := restored[len(restored)-1]; len(snapshot.Messages) != 4 || snapshot.Rewind != nil {
		t.Fatalf("after restore: %s", snapshot.raw)
	}
}

// OpenCode reports a restore while the rewind's rebuild is still reading:
// the second change must not be mistaken for no change.
func TestARestoreDuringTheRewindRebuildIsNotLost(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"), ocUserFixture(3, "Second"), ocAssistantFixture(4, 3, "Two"))
	chat := hubChatFor(t, f, "s1")
	gate, waiting := make(chan struct{}), make(chan struct{}, 1)
	f.oc.set(func(oc *fakeOpenCode) {
		oc.messageGate, oc.messageWaiting, oc.reverts["s1"] = gate, waiting, fixtureID("msg", 3)
	})
	session := map[string]any{"id": "s1", "title": "Fixture", "directory": f.oc.directory, "revert": map[string]string{"messageID": fixtureID("msg", 3)}}
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": session})
	// The rebuild has read the rewound session and waits on the transcript.
	<-waiting
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s1"] = "" })
	delete(session, "revert")
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": session})
	f.oc.set(func(oc *fakeOpenCode) { oc.messageGate = nil })
	close(gate)
	waitFor(t, "the restored chat", func() bool {
		f.host.chat.mu.Lock()
		defer f.host.chat.mu.Unlock()
		return !chat.reconciling && chat.rewind == "" && len(chat.messages) == 4
	})
}

func TestCLIChatsStreamCoarseEvents(t *testing.T) {
	f, server := streamFixture(t)
	id := f.cliSession(t, "claude")
	f.runner.mu.Lock()
	f.runner.release = make(chan struct{})
	release := f.runner.release
	f.runner.mu.Unlock()
	stream, status, body := openStream(t, server, f.token, "projectId=p1&sessionId="+id)
	if status != 200 {
		t.Fatalf("open: %d %s", status, body)
	}
	events := stream.until(t, "snapshot", 5*time.Second)
	snapshot := events[1]
	if snapshot.Chat.Provider != "claude" || snapshot.Chat.Model != "claude/default" || len(snapshot.Messages) != 0 || string(snapshot.Status) != `{"state":"idle"}` {
		t.Fatalf("snapshot: %s", snapshot.raw)
	}
	w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": id, "text": "Fix it", "clientMessageId": strings.Repeat("c", 32)})
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	if w.Code != 202 || !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(receipt.MessageID) || receipt.TurnID != receipt.MessageID {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	client := newClientChat(t)
	client.apply(snapshot)
	started := stream.until(t, "status", 5*time.Second)
	for _, event := range started {
		client.apply(event)
	}
	if eventTypes(started) != "message.created,turn.started,status" || started[0].Message.ID != receipt.MessageID || started[0].Message.Parts[0].Text != "Fix it" || client.status != "running" {
		t.Fatalf("after sending: %s", eventTypes(started))
	}
	close(release)
	finished := stream.until(t, "turn.finished", 5*time.Second)
	for _, event := range finished {
		client.apply(event)
	}
	if eventTypes(finished) != "message.created,status,turn.finished" || finished[0].Message.Parts[0].Text != "Reply to Fix it" || finished[2].Outcome != "completed" {
		t.Fatalf("after the run: %s", eventTypes(finished))
	}
	// Stopping a run shows its reply as aborted, not failed.
	f.runner.mu.Lock()
	f.runner.release = make(chan struct{})
	f.runner.mu.Unlock()
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": id, "text": "Second"}); w.Code != 202 {
		t.Fatalf("second send: %d", w.Code)
	}
	for _, event := range stream.until(t, "status", 5*time.Second) {
		client.apply(event)
	}
	if w := f.call(t, "POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("abort: %d", w.Code)
	}
	stopped := stream.until(t, "turn.finished", 5*time.Second)
	for _, event := range stopped {
		client.apply(event)
	}
	if last := stopped[len(stopped)-1]; last.Outcome != "aborted" || stopped[0].Message.Status != "aborted" || stopped[0].Message.Error != nil {
		t.Fatalf("aborted run: %s / %s", stopped[0].raw, last.raw)
	}
	sameMessages(t, client.ordered(), hubMessages(f.host, sessionKey{"p1", id}))
}
