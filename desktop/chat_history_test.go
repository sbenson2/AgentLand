package host

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestMessagesMapReasoningAndAttachmentsWithoutSyntheticTextOrURLs(t *testing.T) {
	secret := "PRIVATE-FILE-CONTENT"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, []any{
			map[string]any{"info": map[string]string{"id": "msg_user", "role": "user"}, "parts": []any{
				map[string]any{"type": "text", "text": "Please review"},
				map[string]any{"type": "text", "synthetic": true, "text": `Called the Read tool with the following input: {"filePath":"notes.txt"}`},
				map[string]any{"type": "text", "synthetic": true, "text": secret},
				map[string]any{"type": "file", "mime": "text/plain", "filename": "notes.txt", "url": "data:text/plain;base64," + base64.StdEncoding.EncodeToString([]byte(secret))},
				map[string]any{"type": "file", "mime": "image/png", "url": "data:image/png;base64,iVBORw0KGgo="},
			}},
			map[string]any{"info": map[string]string{"id": "msg_reply", "role": "assistant"}, "parts": []any{
				map[string]any{"type": "step-start"},
				map[string]any{"type": "reasoning", "text": "Comparing the files", "time": map[string]int{"start": 1000, "end": 3500}},
				map[string]any{"type": "reasoning", "text": " \n ", "time": map[string]int{"start": 1, "end": 2}},
				map[string]any{"type": "reasoning", "text": "Still thinking", "time": map[string]int{"start": 5000}},
				map[string]any{"type": "text", "text": "Looks good"},
				map[string]any{"type": "retry", "attempt": 1, "time": map[string]int{"created": 4}},
			}},
		})
	}))
	defer upstream.Close()
	messages, err := NewOpenCodeAdapter(upstream.URL, "opencode", "fixture", upstream.Client()).Messages(Project{Directory: t.TempDir()}, "s1")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("messages=%+v", messages)
	}
	user, reply := messages[0], messages[1]
	if user.Text != "Please review" || len(user.Attachments) != 2 || user.Attachments[0] != (AttachmentInfo{"notes.txt", "text/plain"}) || user.Attachments[1] != (AttachmentInfo{"attachment", "image/png"}) {
		t.Fatalf("user message: %+v", user)
	}
	if reply.Text != "Looks good" || len(reply.Reasoning) != 2 || reply.Reasoning[0] != (ReasoningPart{"Comparing the files", 2500}) || reply.Reasoning[1] != (ReasoningPart{"Still thinking", 0}) {
		t.Fatalf("reasoning: %+v", reply)
	}
	encoded, _ := json.Marshal(messages)
	for _, leaked := range []string{secret, "data:", "base64", "url", "Called the Read tool"} {
		if strings.Contains(string(encoded), leaked) {
			t.Fatalf("history exposed %q: %s", leaked, encoded)
		}
	}
	if !strings.Contains(string(encoded), `{"text":"Comparing the files","durationMs":2500}`) || !strings.Contains(string(encoded), `{"text":"Still thinking"}`) {
		t.Fatalf("reasoning JSON shape: %s", encoded)
	}
	if strings.Contains(string(encoded[strings.Index(string(encoded), "msg_user"):strings.Index(string(encoded), "msg_reply")]), "reasoning") {
		t.Fatal("a message without reasoning must omit the field")
	}
}

func TestReasoningIsClippedAtAUTF8Boundary(t *testing.T) {
	original := strings.Repeat("x", (64<<10)-1) + strings.Repeat("é", 20)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, []any{map[string]any{"info": map[string]string{"id": "msg", "role": "assistant"}, "parts": []any{map[string]any{"type": "reasoning", "text": original, "time": map[string]int{"start": 1}}}}})
	}))
	defer upstream.Close()
	messages, err := NewOpenCodeAdapter(upstream.URL, "opencode", "fixture", upstream.Client()).Messages(Project{Directory: t.TempDir()}, "s1")
	if err != nil || len(messages) != 1 || len(messages[0].Reasoning) != 1 {
		t.Fatalf("messages=%+v err=%v", messages, err)
	}
	clipped := messages[0].Reasoning[0].Text
	if !utf8.ValidString(clipped) || len(clipped) != (64<<10)-1 || !strings.HasPrefix(original, clipped) {
		t.Fatal("reasoning was not clipped on a character boundary")
	}
}

func TestTranscriptWithLargeAttachmentsStillLoads(t *testing.T) {
	// Each stored data URL is larger than the ordinary 2 MiB response bound.
	large := strings.Repeat("A", 3<<20)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var messages []any
		for index := 0; index < 3; index++ {
			messages = append(messages, map[string]any{"info": map[string]string{"id": "msg_" + string(rune('a'+index)), "role": "user"}, "parts": []any{
				map[string]any{"type": "text", "text": "photo"},
				map[string]any{"type": "file", "mime": "image/jpeg", "filename": "photo.jpg", "url": "data:image/jpeg;base64," + large},
			}})
		}
		writeJSON(w, 200, messages)
	}))
	defer upstream.Close()
	messages, err := NewOpenCodeAdapter(upstream.URL, "opencode", "fixture", upstream.Client()).Messages(Project{Directory: t.TempDir()}, "s1")
	if err != nil || len(messages) != 3 || messages[2].Attachments[0].Name != "photo.jpg" {
		t.Fatalf("large transcript: %d messages, %v", len(messages), err)
	}
}

func rewindFixture(t *testing.T) *chatFixture {
	t.Helper()
	f := newChatFixture(t)
	f.oc.addMessages("s1", ocMessageFixture("msg_u1", "user", "first"), ocMessageFixture("msg_a1", "assistant", "one"), ocMessageFixture("msg_u2", "user", "second"), ocMessageFixture("msg_a2", "assistant", "two"))
	return f
}

func messageIDs(t *testing.T, f *chatFixture, sessionID string) ([]string, map[string]json.RawMessage) {
	t.Helper()
	w := f.call(t, "GET", "/v1/messages?projectId=p1&sessionId="+sessionID, nil)
	if w.Code != 200 {
		t.Fatalf("messages: %d %s", w.Code, w.Body.String())
	}
	var body map[string]json.RawMessage
	json.Unmarshal(w.Body.Bytes(), &body)
	var messages []Message
	json.Unmarshal(body["messages"], &messages)
	ids := []string{}
	for _, message := range messages {
		ids = append(ids, message.ID)
	}
	return ids, body
}

func TestRewindChecksStateBeforeRevertingTheLatestUserMessage(t *testing.T) {
	f := rewindFixture(t)
	rewind := func(id string) *httptest.ResponseRecorder {
		return f.call(t, "POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": "s1", "messageId": id})
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "busy" })
	if w := rewind("msg_u2"); w.Code != 409 || errorCode(t, w) != "agent_busy" {
		t.Fatalf("busy chat: %d %s", w.Code, w.Body.String())
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.status["s1"] = "idle" })
	queued := f.call(t, "POST", "/v1/queue", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "later"})
	if queued.Code != 201 {
		t.Fatalf("queue: %d %s", queued.Code, queued.Body.String())
	}
	if w := rewind("msg_u2"); w.Code != 409 || errorCode(t, w) != "queue_not_empty" {
		t.Fatalf("queued chat: %d %s", w.Code, w.Body.String())
	}
	var item QueueItem
	json.Unmarshal(queued.Body.Bytes(), &item)
	if w := f.call(t, "POST", "/v1/queue/remove", map[string]string{"projectId": "p1", "sessionId": "s1", "itemId": item.ID}); w.Code != 200 {
		t.Fatalf("remove: %d", w.Code)
	}
	for _, id := range []string{"msg_u1", "msg_a2", "msg_missing", ""} {
		if w := rewind(id); w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Fatalf("rewind %q: %d %s", id, w.Code, w.Body.String())
		}
	}
	var reverts []string
	var unreverts int
	upstream := func() {
		f.oc.set(func(oc *fakeOpenCode) { reverts, unreverts = append([]string{}, oc.revertLog...), oc.unreverts })
	}
	if upstream(); len(reverts) != 0 {
		t.Fatalf("rejected rewinds reached OpenCode: %v", reverts)
	}
	if w := rewind("msg_u2"); w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"filesRestore":"immediate","rewound":true}` {
		t.Fatalf("rewind: %d %s", w.Code, w.Body.String())
	}
	ids, body := messageIDs(t, f, "s1")
	if strings.Join(ids, ",") != "msg_u1,msg_a1" || string(body["rewind"]) != `{"messageId":"msg_u2"}` {
		t.Fatalf("rewound transcript: %v %s", ids, body["rewind"])
	}
	// The previous turn becomes the latest one and can be edited next.
	if w := rewind("msg_u2"); w.Code != 400 {
		t.Fatalf("hidden message rewound again: %d", w.Code)
	}
	if w := rewind("msg_u1"); w.Code != 200 {
		t.Fatalf("second rewind: %d %s", w.Code, w.Body.String())
	}
	if w := f.call(t, "POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": "s1"}); w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"filesRestore":"immediate","restored":true}` {
		t.Fatalf("restore: %d %s", w.Code, w.Body.String())
	}
	ids, body = messageIDs(t, f, "s1")
	if len(ids) != 4 || body["rewind"] != nil {
		t.Fatalf("restored transcript: %v %s", ids, body["rewind"])
	}
	if upstream(); strings.Join(reverts, ",") != "msg_u2,msg_u1" || unreverts != 1 {
		t.Fatalf("upstream calls: %v %d", reverts, unreverts)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.revertCode = 409 })
	if w := rewind("msg_u2"); w.Code != 409 || errorCode(t, w) != "agent_busy" {
		t.Fatalf("OpenCode busy conflict: %d %s", w.Code, w.Body.String())
	}
}

func TestRewindIsOnlyForOpenCodeChats(t *testing.T) {
	f := newChatFixture(t)
	id := f.cliSession(t, "claude")
	for _, path := range []string{"/v1/messages/rewind", "/v1/messages/restore"} {
		body := map[string]string{"projectId": "p1", "sessionId": id}
		if strings.HasSuffix(path, "rewind") {
			body["messageId"] = "any"
		}
		if w := f.call(t, "POST", path, body); w.Code != 400 || errorCode(t, w) != "unsupported_operation" {
			t.Fatalf("%s on a CLI chat: %d %s", path, w.Code, w.Body.String())
		}
	}
	if w := f.call(t, "POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": "missing", "messageId": "msg"}); w.Code != 404 {
		t.Fatalf("unknown chat: %d", w.Code)
	}
	if w := request(t, f.host.Handler(), "POST", "/v1/messages/restore", "", map[string]string{"projectId": "p1", "sessionId": "s1"}); w.Code != 401 {
		t.Fatalf("unauthenticated restore: %d", w.Code)
	}
}

func TestCapabilitiesAdvertiseConfiguredChatFeatures(t *testing.T) {
	f := newChatFixture(t)
	var capabilities struct{ ChatFeatures []string }
	json.Unmarshal(f.call(t, "GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if strings.Join(capabilities.ChatFeatures, ",") != "reasoning,attachments,queue,rewind,events,parts,stop,clientMessageId,regenerate,title" {
		t.Fatalf("features=%v", capabilities.ChatFeatures)
	}
	plain, store, _ := testHost(t)
	json.Unmarshal(request(t, plain.Handler(), "GET", "/v1/capabilities", paired(t, plain, store), nil).Body.Bytes(), &capabilities)
	if strings.Join(capabilities.ChatFeatures, ",") != "reasoning,parts,stop,clientMessageId,title" {
		t.Fatalf("unconfigured host features=%v", capabilities.ChatFeatures)
	}
}

func TestTranscriptDecodingAcceptsNullsAndRejectsMalformedJSON(t *testing.T) {
	for body, want := range map[string]int{
		`null`: 0,
		`[null, {"info": {"id": "msg", "role": "assistant", "error": null}, "parts": null, "extra": {"large": [1, 2]}}]`: 1,
		`[{"parts": [null, {"type": "text", "text": "hi"}], "info": {"id": "msg", "role": "user"}}]`:                     1,
	} {
		messages, err := decodeOCMessages(strings.NewReader(body))
		if err != nil || len(messages) != want {
			t.Errorf("%s: %d messages, %v", body, len(messages), err)
		}
	}
	for _, body := range []string{`{}`, `[1]`, `[{"parts": {}}]`, `[{"info": {"id": "msg"}`, `[`} {
		if _, err := decodeOCMessages(strings.NewReader(body)); err == nil {
			t.Errorf("%s accepted", body)
		}
	}
}
