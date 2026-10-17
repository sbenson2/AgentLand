package host

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"
)

type chatPage struct {
	Messages []ChatMessage `json:"messages"`
	HasMore  bool          `json:"hasMore"`
	OldestID string        `json:"oldestId"`
}

func (f *chatFixture) page(t *testing.T, query string) (chatPage, *httptest.ResponseRecorder) {
	t.Helper()
	w := f.call(t, "GET", "/v1/chat/messages?"+query, nil)
	var page chatPage
	json.Unmarshal(w.Body.Bytes(), &page)
	return page, w
}

func pageIDs(page chatPage) string {
	ids := make([]string, len(page.Messages))
	for index, message := range page.Messages {
		ids[index] = strings.TrimSuffix(strings.TrimPrefix(message.ID, "msg_0001a2b3c"), "Fixture0000000")
	}
	return strings.Join(ids, ",")
}

func TestChatMessagesPageNewestFirst(t *testing.T) {
	f := newChatFixture(t)
	for n := 1; n <= 7; n++ {
		if n%2 == 1 {
			f.oc.addMessages("s1", ocUserFixture(n, fmt.Sprintf("question %d", n)))
		} else {
			f.oc.addMessages("s1", ocAssistantFixture(n, n-1, fmt.Sprintf("answer %d", n)))
		}
	}
	first, w := f.page(t, "projectId=p1&sessionId=s1&limit=3")
	if w.Code != 200 || pageIDs(first) != "007,006,005" || !first.HasMore || first.OldestID != fixtureID("msg", 5) {
		t.Fatalf("first page: %d %s %+v", w.Code, pageIDs(first), first.HasMore)
	}
	if message := first.Messages[1]; message.Role != "assistant" || message.TurnID != fixtureID("msg", 5) || message.Parts[0].Text != "answer 6" || message.Usage == nil || message.Status != "complete" {
		t.Fatalf("page message: %+v", message)
	}
	second, _ := f.page(t, "projectId=p1&sessionId=s1&limit=3&before="+first.OldestID)
	third, _ := f.page(t, "projectId=p1&sessionId=s1&limit=3&before="+second.OldestID)
	if pageIDs(second) != "004,003,002" || !second.HasMore || pageIDs(third) != "001" || third.HasMore || third.OldestID != fixtureID("msg", 1) {
		t.Fatalf("later pages: %s %v / %s %v", pageIDs(second), second.HasMore, pageIDs(third), third.HasMore)
	}
	if all, _ := f.page(t, "projectId=p1&sessionId=s1"); len(all.Messages) != 7 || all.HasMore {
		t.Fatalf("default limit: %s", pageIDs(all))
	}
	// Messages from a rewind point on stay hidden, even when asked for by ID.
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s1"] = fixtureID("msg", 5) })
	for _, query := range []string{"", "&before=" + fixtureID("msg", 6)} {
		if page, _ := f.page(t, "projectId=p1&sessionId=s1&limit=3"+query); pageIDs(page) != "004,003,002" || !page.HasMore {
			t.Fatalf("rewound page %q: %s", query, pageIDs(page))
		}
	}
	for query, want := range map[string]int{"limit=0": 400, "limit=51": 400, "limit=x": 400, "before=msg_missing": 404, "before=" + strings.Repeat("m", 257): 400} {
		if _, w := f.page(t, "projectId=p1&sessionId=s1&"+query); w.Code != want {
			t.Errorf("%s: %d %s", query, w.Code, w.Body.String())
		}
	}
	if _, w := f.page(t, "projectId=p1&sessionId=missing"); w.Code != 404 {
		t.Fatalf("unknown chat: %d", w.Code)
	}
	if w := request(t, f.host.Handler(), "GET", "/v1/chat/messages?projectId=p1&sessionId=s1", "", nil); w.Code != 401 {
		t.Fatalf("without a token: %d", w.Code)
	}
}

func TestChatMessagesPageCLIChats(t *testing.T) {
	f := newChatFixture(t)
	id := f.cliSession(t, "codex")
	for _, text := range []string{"one", "two"} {
		if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": id, "text": text}); w.Code != 202 {
			t.Fatalf("send: %d", w.Code)
		}
		waitFor(t, "reply", func() bool {
			messages, _ := f.chats.Messages(mustProject(t, f.store), id)
			return len(messages)%2 == 0
		})
	}
	page, w := f.page(t, "projectId=p1&sessionId="+id+"&limit=3")
	if w.Code != 200 || len(page.Messages) != 3 || !page.HasMore || page.Messages[0].Parts[0].Text != "Reply to two" || page.Messages[0].Model != "codex/default" || page.Messages[0].Provider != "codex" || page.Messages[0].CreatedAt == "" {
		t.Fatalf("CLI page: %d %s", w.Code, w.Body.String())
	}
	rest, _ := f.page(t, "projectId=p1&sessionId="+id+"&limit=3&before="+page.OldestID)
	if len(rest.Messages) != 1 || rest.HasMore || rest.Messages[0].Parts[0].Text != "one" || rest.Messages[0].Ord != 1 {
		t.Fatalf("CLI rest: %+v", rest)
	}
}

func TestLegacyMessagesWithPartsAddOnlyTheNewFields(t *testing.T) {
	host, token := legacyTranscriptHost(t, "")
	w := request(t, host.Handler(), "GET", "/v1/messages?projectId=p1&sessionId=ses_1&parts=1", token, nil)
	var body struct{ Messages []map[string]json.RawMessage }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || len(body.Messages) != 3 {
		t.Fatalf("parts=1: %d %s", w.Code, w.Body.String())
	}
	var legacy struct{ Messages []map[string]json.RawMessage }
	json.Unmarshal([]byte(legacyTranscriptGolden), &legacy)
	for index, message := range body.Messages {
		for key, value := range legacy.Messages[index] {
			if string(message[key]) != string(value) {
				t.Fatalf("message %d changed legacy field %s: %s", index, key, message[key])
			}
		}
		for key := range message {
			if _, old := legacy.Messages[index][key]; !old && key != "parts" && key != "createdAt" && key != "model" && key != "usage" {
				t.Fatalf("unexpected field %s", key)
			}
		}
	}
	reply := body.Messages[1]
	// The fixture's patch paths lie outside this project, so only their names show.
	if string(reply["createdAt"]) != `"2026-09-21T14:13:21.000Z"` || string(reply["model"]) != `"anthropic/claude-sonnet"` || !strings.HasPrefix(string(reply["usage"]), `{"input":1200`) || !strings.Contains(string(reply["parts"]), `"kind":"patch","ord":7024657643,"text":"main.go\nnotes.md"`) {
		t.Fatalf("new fields: %s", w.Body.String())
	}
	// Anything but parts=1 keeps the legacy bytes.
	if w := request(t, host.Handler(), "GET", "/v1/messages?projectId=p1&sessionId=ses_1&parts=0", token, nil); w.Body.String() != legacyTranscriptGolden {
		t.Fatalf("parts=0 changed the response: %s", w.Body.String())
	}
	f := newChatFixture(t)
	id := f.cliSession(t, "claude")
	f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": id, "text": "hi"})
	waitFor(t, "reply", func() bool {
		messages, _ := f.chats.Messages(mustProject(t, f.store), id)
		return len(messages) == 2
	})
	w = f.call(t, "GET", "/v1/messages?projectId=p1&sessionId="+id+"&parts=1", nil)
	if !regexp.MustCompile(`"role":"assistant","text":"Reply to hi","parts":\[\{"id":"[0-9a-f]{32}:0","kind":"text","ord":1,"text":"Reply to hi"\}\],"createdAt":"[0-9T:.-]+Z","model":"claude/default"`).MatchString(w.Body.String()) {
		t.Fatalf("CLI parts=1: %s", w.Body.String())
	}
}

func sendWithID(t *testing.T, f *chatFixture, token, text, id string) *httptest.ResponseRecorder {
	t.Helper()
	return request(t, f.host.Handler(), "POST", "/v1/messages", token, map[string]string{"projectId": "p1", "sessionId": "s1", "text": text, "clientMessageId": id})
}

func TestSendsWithAClientMessageIDAreNeverRepeated(t *testing.T) {
	f := newChatFixture(t)
	id := strings.Repeat("a", 32)
	w := sendWithID(t, f, f.token, "hello", id)
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	if w.Code != 202 || !receipt.Accepted || receipt.Duplicate || !regexp.MustCompile(`^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$`).MatchString(receipt.MessageID) || receipt.TurnID != receipt.MessageID {
		t.Fatalf("first send: %d %s", w.Code, w.Body.String())
	}
	if bodies := f.oc.promptBodies(); len(bodies) != 1 || !strings.Contains(string(bodies[0]), `"messageID":"`+receipt.MessageID+`"`) {
		t.Fatalf("OpenCode did not get the message ID: %q", bodies)
	}
	repeat := sendWithID(t, f, f.token, "hello", id)
	if repeat.Code != 202 || strings.TrimSpace(repeat.Body.String()) != `{"accepted":true,"messageId":"`+receipt.MessageID+`","turnId":"`+receipt.MessageID+`","duplicate":true}` || len(f.oc.promptBodies()) != 1 {
		t.Fatalf("repeat: %d %s, %d sends", repeat.Code, repeat.Body.String(), len(f.oc.promptBodies()))
	}
	// Another device's ID space is separate.
	if other := sendWithID(t, f, paired(t, f.host, f.store), "hello", id); other.Code != 202 || strings.Contains(other.Body.String(), "duplicate") || len(f.oc.promptBodies()) != 2 {
		t.Fatalf("other device: %d %s", other.Code, other.Body.String())
	}
	for _, bad := range []string{strings.Repeat("a", 31), strings.Repeat("a", 65), strings.Repeat("a", 31) + "!", strings.Repeat("é", 16)} {
		if w := sendWithID(t, f, f.token, "hello", bad); w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Fatalf("clientMessageId %q: %d", bad, w.Code)
		}
	}
	// Old clients without the field keep working and learn the message ID.
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "plain"}); w.Code != 202 || !strings.HasPrefix(w.Body.String(), `{"accepted":true,"messageId":"msg_`) {
		t.Fatalf("legacy send: %d %s", w.Code, w.Body.String())
	}
}

func TestAFailedSendDecidesWhetherARepeatMaySend(t *testing.T) {
	f := newChatFixture(t)
	// OpenCode refused the prompt: it was not delivered, so the same ID may
	// be sent again.
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 500 })
	refused := strings.Repeat("r", 40)
	if w := sendWithID(t, f, f.token, "one", refused); w.Code != 502 {
		t.Fatalf("refused: %d", w.Code)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 204 })
	if w := sendWithID(t, f, f.token, "one", refused); w.Code != 202 || strings.Contains(w.Body.String(), "duplicate") || len(f.oc.promptBodies()) != 2 {
		t.Fatalf("repeat after a refusal: %d %s", w.Code, w.Body.String())
	}
	// The connection dropped: OpenCode may have it, so a repeat never sends.
	f.oc.set(func(oc *fakeOpenCode) { oc.dropPrompt = true })
	uncertain := strings.Repeat("u", 40)
	if w := sendWithID(t, f, f.token, "two", uncertain); w.Code != 502 {
		t.Fatalf("dropped: %d", w.Code)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.dropPrompt = false })
	if w := sendWithID(t, f, f.token, "two", uncertain); w.Code != 409 || errorCode(t, w) != "delivery_uncertain" || len(f.oc.promptBodies()) != 3 {
		t.Fatalf("repeat after an uncertain send: %d %s, %d sends", w.Code, w.Body.String(), len(f.oc.promptBodies()))
	}
	// A repeat that arrives while the first send is in flight waits for it.
	gate, received := make(chan struct{}), make(chan struct{}, 2)
	f.oc.set(func(oc *fakeOpenCode) { oc.promptGate, oc.received = gate, received })
	pending := strings.Repeat("p", 40)
	results := make(chan *httptest.ResponseRecorder, 2)
	go func() { results <- sendWithID(t, f, f.token, "three", pending) }()
	<-received
	go func() { results <- sendWithID(t, f, f.token, "three", pending) }()
	waitFor(t, "the repeat to wait", func() bool {
		f.host.receipts.mu.Lock()
		defer f.host.receipts.mu.Unlock()
		return len(f.host.receipts.entries) > 0
	})
	close(gate)
	first, second := <-results, <-results
	bodies := []string{first.Body.String(), second.Body.String()}
	if first.Code != 202 || second.Code != 202 || strings.Count(strings.Join(bodies, ""), `"duplicate":true`) != 1 || len(f.oc.promptBodies()) != 4 {
		t.Fatalf("concurrent repeat: %d %d %v, %d sends", first.Code, second.Code, bodies, len(f.oc.promptBodies()))
	}
}

func TestSendReceiptsStayBounded(t *testing.T) {
	receipts := newSendReceipts()
	chat := func(n int) receiptKey { return receiptKey{"device", "p1", "s1", fmt.Sprintf("%040d", n)} }
	for n := 0; n < 100; n++ {
		entry, repeat := receipts.reserve(chat(n))
		if repeat {
			t.Fatalf("receipt %d existed", n)
		}
		receipts.settle(chat(n), entry, receiptAccepted, sendReceipt{Accepted: true})
	}
	if len(receipts.entries) != receiptsPerChat || len(receipts.order) != receiptsPerChat {
		t.Fatalf("per chat: %d entries", len(receipts.entries))
	}
	if _, repeat := receipts.reserve(chat(99)); !repeat {
		t.Fatal("the newest receipt was dropped")
	}
	var mu sync.Mutex
	for n := 0; n < 2000; n++ {
		mu.Lock()
		key := receiptKey{fmt.Sprintf("device-%d", n), "p1", "s1", fmt.Sprintf("%040d", n)}
		entry, _ := receipts.reserve(key)
		receipts.settle(key, entry, receiptAccepted, sendReceipt{Accepted: true})
		mu.Unlock()
	}
	if len(receipts.entries) > receiptsTotal {
		t.Fatalf("total: %d entries", len(receipts.entries))
	}
}
