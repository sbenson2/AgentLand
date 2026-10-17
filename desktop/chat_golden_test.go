package host

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// hubChatFor subscribes to a fixture chat through the hub, as a stream does.
func hubChatFor(t *testing.T, f *chatFixture, sessionID string) *hubChat {
	t.Helper()
	p := mustProject(t, f.store)
	s, err := f.host.session(p, sessionID)
	if err != nil {
		t.Fatal(err)
	}
	chat, err := f.host.chat.subscribe(context.Background(), p, s, f.host.chatProviderFor(s))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.host.chat.unsubscribe(chat) })
	return chat
}

// feed hands one OpenCode bus event to the hub as the event stream would.
func feed(t *testing.T, f *chatFixture, kind string, properties any) {
	t.Helper()
	data, err := json.Marshal(properties)
	if err != nil {
		t.Fatal(err)
	}
	var session struct {
		SessionID string `json:"sessionID"`
	}
	json.Unmarshal(data, &session)
	f.host.chat.mu.Lock()
	pump := f.host.chat.pump
	f.host.chat.mu.Unlock()
	f.host.chat.openCodeEvent(pump, openCodeEvent{directory: f.oc.directory, kind: kind, sessionID: session.SessionID, properties: data})
}

// ringLines renders a chat's ring after seq as a stream would send it.
func ringLines(f *chatFixture, chat *hubChat, after uint64) []string {
	f.host.chat.mu.Lock()
	events, _ := chat.ring.after(after, 1<<20)
	f.host.chat.mu.Unlock()
	stream := chatStream{}
	stream.events(events)
	return strings.Split(strings.TrimSuffix(string(stream.buffer), "\n"), "\n")
}

const openCodeEventsGolden = `{"seq":1,"type":"message.created","message":{"id":"msg_0001a2b3c003Fixture0000000","chatId":"s1","turnId":"msg_0001a2b3c003Fixture0000000","role":"user","status":"complete","ord":7331840012288003,"createdAt":"2026-09-21T14:13:23.000Z","provider":"opencode","model":"anthropic/claude","parts":[]}}
{"seq":2,"type":"part.created","messageId":"msg_0001a2b3c003Fixture0000000","part":{"id":"prt_0001a2b3c12cFixture0000000","kind":"text","ord":7024656684,"text":"Second"}}
{"seq":3,"type":"turn.started","turnId":"msg_0001a2b3c003Fixture0000000"}
{"seq":4,"type":"status","state":"running"}
{"seq":5,"type":"message.created","message":{"id":"msg_0001a2b3c004Fixture0000000","chatId":"s1","turnId":"msg_0001a2b3c003Fixture0000000","role":"assistant","status":"streaming","ord":7331840016384004,"createdAt":"2026-09-21T14:13:24.000Z","provider":"opencode","model":"anthropic/claude","parts":[]}}
{"seq":6,"type":"part.created","messageId":"msg_0001a2b3c004Fixture0000000","part":{"id":"prt_0001a2b3c191Fixture0000000","kind":"reasoning","ord":7024656785,"start":"2026-09-21T14:13:24.001Z"}}
{"seq":8,"type":"part.delta","messageId":"msg_0001a2b3c004Fixture0000000","partId":"prt_0001a2b3c191Fixture0000000","field":"text","offset":0,"delta":"Looking"}
{"seq":9,"type":"part.updated","messageId":"msg_0001a2b3c004Fixture0000000","part":{"id":"prt_0001a2b3c191Fixture0000000","kind":"reasoning","ord":7024656785,"text":"Looking","start":"2026-09-21T14:13:24.001Z","end":"2026-09-21T14:13:24.050Z"}}
{"seq":10,"type":"part.created","messageId":"msg_0001a2b3c004Fixture0000000","part":{"id":"prt_0001a2b3c192Fixture0000000","kind":"tool","ord":7024656786,"tool":{"name":"bash","callId":"call_1","status":"running","input":"{\"command\":\"ls\"}","truncated":false},"start":"2026-09-21T14:13:24.100Z"}}
{"seq":11,"type":"interaction.requested","interaction":{"id":"per_1","chatId":"s1","kind":"permission","createdAt":"2026-09-23T12:00:00.000Z","choices":["once","reject"],"permission":{"tool":"bash","title":"ls","detail":""}}}
{"seq":12,"type":"status","state":"waiting"}
{"seq":13,"type":"interaction.resolved","id":"per_1","outcome":"once"}
{"seq":14,"type":"status","state":"running"}
{"seq":15,"type":"part.updated","messageId":"msg_0001a2b3c004Fixture0000000","part":{"id":"prt_0001a2b3c192Fixture0000000","kind":"tool","ord":7024656786,"tool":{"name":"bash","callId":"call_1","status":"completed","title":"List","input":"{\"command\":\"ls\"}","output":"a.go\n","truncated":false},"start":"2026-09-21T14:13:24.100Z","end":"2026-09-21T14:13:24.200Z"}}
{"seq":16,"type":"part.created","messageId":"msg_0001a2b3c004Fixture0000000","part":{"id":"prt_0001a2b3c193Fixture0000000","kind":"text","ord":7024656787,"start":"2026-09-21T14:13:24.003Z"}}
{"seq":17,"type":"part.delta","messageId":"msg_0001a2b3c004Fixture0000000","partId":"prt_0001a2b3c193Fixture0000000","field":"text","offset":0,"delta":"Done."}
{"seq":18,"type":"chat.updated","title":"Renamed","titleSource":"provider"}
{"seq":19,"type":"message.updated","messageId":"msg_0001a2b3c004Fixture0000000","status":"complete","completedAt":"2026-09-21T14:13:24.500Z","usage":{"input":100,"output":20,"reasoning":5,"cacheRead":50,"cacheWrite":0,"costMicros":2000}}
{"seq":20,"type":"status","state":"idle"}
{"seq":21,"type":"turn.finished","turnId":"msg_0001a2b3c003Fixture0000000","outcome":"completed","usage":{"input":100,"output":20,"reasoning":5,"cacheRead":50,"cacheWrite":0,"costMicros":2000}}`

func TestOpenCodeEventsMapToStreamLines(t *testing.T) {
	f := newChatFixture(t)
	f.host.chat.now = func() time.Time { return time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC) }
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	chat := hubChatFor(t, f, "s1")
	user := ocUserFixture(3, "Second")
	reply := fixtureID("msg", 4)
	reasoning := map[string]any{"id": fixtureID("prt", 401), "sessionID": "s1", "messageID": reply, "type": "reasoning", "text": "", "time": map[string]any{"start": fixtureEpochMs + 4001}}
	tool := map[string]any{"id": fixtureID("prt", 402), "sessionID": "s1", "messageID": reply, "type": "tool", "tool": "bash", "callID": "call_1", "state": map[string]any{"status": "running", "input": map[string]string{"command": "ls"}, "time": map[string]any{"start": fixtureEpochMs + 4100}}}
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": user["info"]})
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": user["parts"].([]any)[0], "time": 1})
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(4, 3, false)})
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": reasoning, "time": 2})
	for _, piece := range []string{"Look", "ing"} {
		feed(t, f, "message.part.delta", map[string]any{"sessionID": "s1", "messageID": reply, "partID": fixtureID("prt", 401), "field": "text", "delta": piece})
	}
	reasoning["text"], reasoning["time"] = "Looking", map[string]any{"start": fixtureEpochMs + 4001, "end": fixtureEpochMs + 4050}
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": reasoning, "time": 3})
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": tool, "time": 4})
	feed(t, f, "permission.asked", map[string]any{"id": "per_1", "sessionID": "s1", "permission": "bash", "patterns": []string{"ls"}, "metadata": map[string]any{}, "always": []string{}})
	feed(t, f, "permission.replied", map[string]any{"sessionID": "s1", "requestID": "per_1", "reply": "once"})
	tool["state"] = map[string]any{"status": "completed", "title": "List", "input": map[string]string{"command": "ls"}, "output": "a.go\n", "metadata": map[string]any{}, "time": map[string]any{"start": fixtureEpochMs + 4100, "end": fixtureEpochMs + 4200}}
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": tool, "time": 5})
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(4, 3, "", false), "time": 6})
	feed(t, f, "message.part.delta", map[string]any{"sessionID": "s1", "messageID": reply, "partID": fixtureID("prt", 403), "field": "text", "delta": "Done."})
	// A delta for a part the hub does not know, and one for another field,
	// are ignored rather than guessed at.
	feed(t, f, "message.part.delta", map[string]any{"sessionID": "s1", "messageID": reply, "partID": fixtureID("prt", 499), "field": "text", "delta": "lost"})
	feed(t, f, "message.part.delta", map[string]any{"sessionID": "s1", "messageID": reply, "partID": fixtureID("prt", 403), "field": "metadata", "delta": "x"})
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Renamed", "directory": f.oc.directory}})
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(4, 3, true)})
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
	feed(t, f, "session.idle", map[string]any{"sessionID": "s1"})
	lines := strings.Join(ringLines(f, chat, 0), "\n")
	if os.Getenv("AGENTLAND_PRINT_GOLDEN") != "" {
		t.Logf("events:\n%s", lines)
	}
	if lines != openCodeEventsGolden {
		t.Fatalf("stream lines changed:\n got:\n%s\nwant:\n%s", lines, openCodeEventsGolden)
	}
}
