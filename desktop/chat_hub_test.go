package host

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestChatRingEvictsByCountAndBytes(t *testing.T) {
	ring := newChatRing(4, 1000)
	for index := 0; index < 10; index++ {
		ring.push(ringEvent{body: []byte(`"type":"x"}`), size: 100})
	}
	if ring.count() != 4 || ring.first != 7 || ring.last() != 10 || ring.holds(5) || !ring.holds(6) || !ring.holds(10) || ring.holds(11) {
		t.Fatalf("count bound: first %d last %d count %d", ring.first, ring.last(), ring.count())
	}
	events, more := ring.after(6, 2)
	if len(events) != 2 || events[0].seq != 7 || events[1].seq != 8 || !more {
		t.Fatalf("after: %+v %v", events, more)
	}
	ring.push(ringEvent{size: 950})
	if ring.count() != 1 || ring.bytes != 950 || ring.first != 11 {
		t.Fatalf("byte bound: count %d bytes %d first %d", ring.count(), ring.bytes, ring.first)
	}
	// One event larger than the bound is kept rather than lost.
	ring.push(ringEvent{size: 5000})
	if ring.count() != 1 || ring.last() != 12 {
		t.Fatalf("large event: count %d", ring.count())
	}
	// The backing array is compacted instead of growing without bound.
	for index := 0; index < 10000; index++ {
		ring.push(ringEvent{size: 1})
	}
	if cap(ring.events) > 4096 {
		t.Fatalf("ring storage grew to %d", cap(ring.events))
	}
	if epoch, seq, ok := parseChatCursor(ring.cursor(12)); !ok || epoch != ring.epoch || seq != 12 {
		t.Fatalf("cursor round trip: %q", ring.cursor(12))
	}
	for _, bad := range []string{"", "abc.1", ring.epoch, ring.epoch + ".x", "zzzzzzzzzzzzzzzz.1", ring.epoch + ".-1"} {
		if _, _, ok := parseChatCursor(bad); ok {
			t.Fatalf("accepted cursor %q", bad)
		}
	}
	if other := newChatRing(1, 1); other.epoch == ring.epoch {
		t.Fatal("two rings shared an epoch")
	}
}

func TestChatHubKeepsABoundedWindowOfMessagesAndParts(t *testing.T) {
	f := newChatFixture(t)
	chat := hubChatFor(t, f, "s1")
	for n := 1; n <= chatWindowMessages+10; n++ {
		feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": ocUserFixture(n, "")["info"]})
	}
	reply := fixtureID("msg", 1000)
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(1000, 70, false)})
	for n := 1; n <= chatPartsPerMessage+40; n++ {
		feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": map[string]any{"id": fixtureID("prt", 100000+n), "sessionID": "s1", "messageID": reply, "type": "text", "text": strings.Repeat("p", 3000)}})
	}
	f.host.chat.mu.Lock()
	count, parts, hasOlder := len(chat.messages), len(chat.messages[len(chat.messages)-1].parts), chat.hasOlder
	total := 0
	for _, message := range chat.messages {
		total += message.bytes()
	}
	snapshot, _ := f.host.chat.snapshotLocked(chat)
	f.host.chat.mu.Unlock()
	if count > chatWindowMessages || parts != chatPartsPerMessage || !hasOlder {
		t.Fatalf("window: %d messages, %d parts, older %v", count, parts, hasOlder)
	}
	// The window's byte bound applies too; the newest message is always kept.
	if total > chatWindowBytes+(chatPartsPerMessage*3300) {
		t.Fatalf("window holds %d bytes", total)
	}
	if len(snapshot) > chatEventBudget || !strings.Contains(string(snapshot), `"hasMore":true`) {
		t.Fatalf("snapshot of %d bytes", len(snapshot))
	}
}

func TestChatHubBuffersEventsWhileLoading(t *testing.T) {
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocUserFixture(1, "First"))
	gate := make(chan struct{})
	f.oc.set(func(oc *fakeOpenCode) { oc.messageGate = gate })
	loaded := make(chan *hubChat)
	go func() { loaded <- hubChatFor(t, f, "s1") }()
	waitFor(t, "the load to start", func() bool {
		f.host.chat.mu.Lock()
		defer f.host.chat.mu.Unlock()
		c := f.host.chat.chats[sessionKey{"p1", "s1"}]
		return c != nil && !c.awaitingPump
	})
	// Changes during the load are kept and applied after it.
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": ocUserFixture(2, "")["info"]})
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.set(func(oc *fakeOpenCode) { oc.messageGate = nil })
	close(gate)
	chat := <-loaded
	f.host.chat.mu.Lock()
	ids, state := len(chat.messages), chat.status.State
	f.host.chat.mu.Unlock()
	if ids != 2 || state != "running" {
		t.Fatalf("after the load: %d messages, %s", ids, state)
	}
	// Too many events during a load are dropped and the chat is read again.
	f2 := newChatFixture(t)
	f2.oc.addMessages("s1", ocUserFixture(1, "First"))
	gate = make(chan struct{})
	f2.oc.set(func(oc *fakeOpenCode) { oc.messageGate = gate })
	go func() { loaded <- hubChatFor(t, f2, "s1") }()
	waitFor(t, "the second load to start", func() bool {
		f2.host.chat.mu.Lock()
		defer f2.host.chat.mu.Unlock()
		c := f2.host.chat.chats[sessionKey{"p1", "s1"}]
		return c != nil && !c.awaitingPump
	})
	for index := 0; index <= chatPendingEvents; index++ {
		feed(t, f2, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	}
	f2.host.chat.mu.Lock()
	c := f2.host.chat.chats[sessionKey{"p1", "s1"}]
	pending, lost := len(c.pending), c.pendingLost
	f2.host.chat.mu.Unlock()
	if pending != 0 || !lost {
		t.Fatalf("pending buffer: %d events, lost %v", pending, lost)
	}
	reads := f2.oc.reads()
	f2.oc.set(func(oc *fakeOpenCode) { oc.messageGate = nil })
	close(gate)
	<-loaded
	waitFor(t, "a second read", func() bool { return f2.oc.reads() > reads })
}

func TestChatHubEvictsIdleChatsAndStopsTheEventStream(t *testing.T) {
	f := newChatFixture(t)
	f.host.chat.evictIdle, f.host.chat.janitorGap = 40*time.Millisecond, 10*time.Millisecond
	p := mustProject(t, f.store)
	s, _ := f.host.session(p, "s1")
	chat, err := f.host.chat.subscribe(context.Background(), p, s, f.host.chatProviderFor(s))
	if err != nil {
		t.Fatal(err)
	}
	if f.oc.openStreams() != 1 {
		t.Fatalf("event streams: %d", f.oc.openStreams())
	}
	// A watched chat stays however long it is idle.
	time.Sleep(100 * time.Millisecond)
	f.host.chat.mu.Lock()
	tracked := len(f.host.chat.chats)
	f.host.chat.mu.Unlock()
	if tracked != 1 {
		t.Fatal("a watched chat was evicted")
	}
	// A busy chat outlives the idle bound after its last subscriber leaves.
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.host.chat.unsubscribe(chat)
	time.Sleep(100 * time.Millisecond)
	f.host.chat.mu.Lock()
	tracked = len(f.host.chat.chats)
	f.host.chat.mu.Unlock()
	if tracked != 1 {
		t.Fatal("a busy chat was evicted")
	}
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
	waitFor(t, "eviction", func() bool {
		f.host.chat.mu.Lock()
		defer f.host.chat.mu.Unlock()
		return len(f.host.chat.chats) == 0 && f.host.chat.pump == nil && !f.host.chat.janitor
	})
	waitFor(t, "the event stream to close", func() bool { return f.oc.openStreams() == 0 })
	// The next subscriber rebuilds the chat with a new epoch.
	again, err := f.host.chat.subscribe(context.Background(), p, s, f.host.chatProviderFor(s))
	if err != nil {
		t.Fatal(err)
	}
	defer f.host.chat.unsubscribe(again)
	if again == chat || again.ring.epoch == chat.ring.epoch {
		t.Fatal("the rebuilt chat reused the old state")
	}
}

func TestChatHubLimitsTrackedChats(t *testing.T) {
	f := newChatFixture(t)
	p := mustProject(t, f.store)
	var held []*hubChat
	for index := 0; index <= chatMaxChats; index++ {
		id := fmt.Sprintf("s%d", index+10)
		f.oc.set(func(oc *fakeOpenCode) { oc.reverts[id] = "" })
		s, err := f.host.session(p, id)
		if err != nil {
			t.Fatal(err)
		}
		chat, err := f.host.chat.subscribe(context.Background(), p, s, f.host.chatProviderFor(s))
		if index == chatMaxChats {
			if !errors.Is(err, errChatHubFull) {
				t.Fatalf("chat %d: %v", index, err)
			}
			// Leaving one chat makes room: the least recently used goes.
			f.host.chat.unsubscribe(held[3])
			if chat, err = f.host.chat.subscribe(context.Background(), p, s, f.host.chatProviderFor(s)); err != nil {
				t.Fatal(err)
			}
		} else if err != nil {
			t.Fatal(err)
		}
		held = append(held, chat)
	}
	f.host.chat.mu.Lock()
	count, evicted := len(f.host.chat.chats), held[3].removed
	f.host.chat.mu.Unlock()
	if count != chatMaxChats || !evicted {
		t.Fatalf("%d chats, evicted %v", count, evicted)
	}
}

func TestHostCloseEndsStreamsAndTheEventStream(t *testing.T) {
	f, server := streamFixture(t)
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	if f.oc.openStreams() != 1 {
		t.Fatal("no event stream while chatting")
	}
	f.host.Close()
	if line := stream.next(t, 2*time.Second); line.Type != "stopping" {
		t.Fatalf("after close: %s", line.raw)
	}
	waitFor(t, "the event stream to close", func() bool { return f.oc.openStreams() == 0 })
	if _, status, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1"); status != 503 {
		t.Fatalf("stream after close: %d", status)
	}
}
