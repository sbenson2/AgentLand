package host

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// The unified form of legacyTranscriptFixture: ordered parts with their
// timestamps, synthetic prompt text and steps left out, a patch listed with
// project-relative paths, the retry and output-limit notices, model, usage
// and a provider error with a stable code and no private fields.
const unifiedTranscriptGolden = `[{"id":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","chatId":"ses_1","turnId":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","role":"user","status":"complete","ord":7331840000001237,"createdAt":"2026-09-21T14:13:20.000Z","provider":"opencode","model":"anthropic/claude-sonnet","parts":[{"id":"prt_0001a2b3c4d6AAAAAAAAAAAAAA","kind":"text","ord":7024657622,"text":"Please review <main.go> & tests"},{"id":"prt_0001a2b3c4d8AAAAAAAAAAAAAA","kind":"attachment","ord":7024657624,"attachment":{"name":"notes.txt","mime":"text/plain"}},{"id":"prt_0001a2b3c4d9AAAAAAAAAAAAAA","kind":"attachment","ord":7024657625,"attachment":{"name":"attachment","mime":"image/png"}},{"id":"prt_0001a2b3c4daAAAAAAAAAAAAAA","kind":"notice","ord":7024657626,"text":"Agent: explore"}]},{"id":"msg_0001a2b3c4e0AAAAAAAAAAAAAA","chatId":"ses_1","turnId":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","role":"assistant","status":"complete","ord":7331840004097248,"createdAt":"2026-09-21T14:13:21.000Z","completedAt":"2026-09-21T14:13:29.000Z","provider":"opencode","model":"anthropic/claude-sonnet","usage":{"input":1200,"output":340,"reasoning":80,"cacheRead":1000,"cacheWrite":20,"costMicros":12300},"parts":[{"id":"prt_0001a2b3c4e2AAAAAAAAAAAAAA","kind":"reasoning","ord":7024657634,"text":"Comparing the files","start":"2026-09-21T14:13:21.100Z","end":"2026-09-21T14:13:23.600Z"},{"id":"prt_0001a2b3c4e4AAAAAAAAAAAAAA","kind":"reasoning","ord":7024657636,"text":"Still thinking","start":"2026-09-21T14:13:23.900Z"},{"id":"prt_0001a2b3c4e5AAAAAAAAAAAAAA","kind":"text","ord":7024657637,"text":"Checking the project.","start":"2026-09-21T14:13:24.000Z","end":"2026-09-21T14:13:24.500Z"},{"id":"prt_0001a2b3c4e6AAAAAAAAAAAAAA","kind":"tool","ord":7024657638,"tool":{"name":"bash","callId":"call_one","status":"completed","title":"Inspect files","input":"{\"command\":\"pwd\"}","output":"sample-project\n","truncated":false},"start":"2026-09-21T14:13:25.000Z","end":"2026-09-21T14:13:25.200Z"},{"id":"prt_0001a2b3c4e7AAAAAAAAAAAAAA","kind":"tool","ord":7024657639,"tool":{"name":"read","callId":"call_two","status":"error","input":"{\"filePath\":\"missing.txt\"}","error":"File does not exist","truncated":false},"start":"2026-09-21T14:13:25.300Z","end":"2026-09-21T14:13:25.400Z"},{"id":"prt_0001a2b3c4e8AAAAAAAAAAAAAA","kind":"tool","ord":7024657640,"tool":{"name":"edit","callId":"call_three","status":"running","title":"Editing","input":"{\"filePath\":\"main.go\"}","truncated":false},"start":"2026-09-21T14:13:25.500Z"},{"id":"prt_0001a2b3c4e9AAAAAAAAAAAAAA","kind":"notice","ord":7024657641,"text":"Retrying after a provider error (attempt 1): Overloaded","start":"2026-09-21T14:13:26.000Z"},{"id":"prt_0001a2b3c4eaAAAAAAAAAAAAAA","kind":"text","ord":7024657642,"text":"Looks good"},{"id":"prt_0001a2b3c4ebAAAAAAAAAAAAAA","kind":"patch","ord":7024657643,"text":"main.go\ndocs/notes.md"}]},{"id":"msg_0001a2b3c4f0AAAAAAAAAAAAAA","chatId":"ses_1","turnId":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","role":"assistant","status":"error","ord":7331840040961264,"createdAt":"2026-09-21T14:13:30.000Z","completedAt":"2026-09-21T14:13:31.000Z","provider":"opencode","model":"anthropic/claude-sonnet","error":{"code":"provider_error","message":"Provider rejected the API key"},"parts":[]}]`

func TestOpenCodeMessagesMapToOrderedUnifiedParts(t *testing.T) {
	messages, err := decodeOCMessages(strings.NewReader(legacyTranscriptFixture))
	if err != nil {
		t.Fatal(err)
	}
	var unified []ChatMessage
	for _, message := range messages {
		if message.Info.Role == "user" || message.Info.Role == "assistant" {
			unified = append(unified, *messageFromOC(message, "/repo").Unified)
		}
	}
	encoded := string(marshalJSONLine(unified))
	if os.Getenv("AGENTLAND_PRINT_GOLDEN") != "" {
		t.Logf("unified:\n%s", encoded)
	}
	if encoded != unifiedTranscriptGolden {
		t.Fatalf("unified mapping changed:\n got: %s\nwant: %s", encoded, unifiedTranscriptGolden)
	}
	for _, leaked := range []string{"PRIVATE", "data:", "base64", "do-not-forward", "Called the Read tool", "snapshot"} {
		if strings.Contains(encoded, leaked) {
			t.Fatalf("unified messages exposed %q", leaked)
		}
	}
}

func TestOpenCodeStepFinishReasonsBecomeNotices(t *testing.T) {
	for reason, want := range map[string]string{"length": "The reply reached the model's output limit.", "content-filter": "The provider's content filter stopped the reply.", "stop": "", "tool-calls": ""} {
		part, ok := chatPartFromOC(ocPart{ID: "prt_000000000001x", Type: "step-finish", Reason: reason}, 0, "")
		if (want == "") == ok || (ok && (part.Kind != "notice" || part.Text != want)) {
			t.Errorf("%s: %+v %v", reason, part, ok)
		}
	}
	// A live reasoning part is kept even while empty so deltas can land.
	if part, ok := chatPartFromOC(ocPart{ID: "prt_1", Type: "reasoning", Time: struct{ Start, End, Created float64 }{Start: 5}}, 0, ""); !ok || part.Kind != "reasoning" {
		t.Fatalf("live reasoning dropped: %+v", part)
	}
}

func TestOpenCodeMessageIDsMatchTheAscendingFormat(t *testing.T) {
	format := regexp.MustCompile(`^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$`)
	at := time.UnixMilli(1790000000000)
	first, second := newOpenCodeMessageID(at), newOpenCodeMessageID(at)
	if !format.MatchString(first) || !format.MatchString(second) {
		t.Fatalf("IDs %q %q", first, second)
	}
	// Two IDs in one millisecond still sort in creation order.
	if first[:16] >= second[:16] {
		t.Fatalf("IDs not ascending: %q %q", first, second)
	}
	value, ok := openCodeIDValue(first)
	if !ok || value>>12 != uint64(1790000000000)&(1<<36-1) {
		t.Fatalf("time bits %x", value)
	}
	later := newOpenCodeMessageID(at.Add(time.Millisecond))
	if later[:16] <= second[:16] {
		t.Fatalf("later ID sorts first: %q %q", second, later)
	}
}

func TestOpenCodePageCursorMatchesTheServerFormat(t *testing.T) {
	cursor := openCodePageCursor("msg_0001a2b3c4d5AAAAAAAAAAAAAA", 1790000000000)
	data, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil || string(data) != `{"id":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","time":1790000000000}` || strings.ContainsAny(cursor, "=+/") {
		t.Fatalf("cursor %q decodes to %s (%v)", cursor, data, err)
	}
}

func TestJSONClippingCountsEscapedBytes(t *testing.T) {
	value := "a\"b\\c\n\x01é\u2028" + string([]byte{0xff}) + "<>&"
	if got, want := jsonStringSize(value), len(string(marshalJSONLine(value)))-2; got != want {
		t.Fatalf("size %d, encoder wrote %d", got, want)
	}
	for limit := 0; limit < 40; limit++ {
		clipped := clipJSON(value, limit)
		if !strings.HasPrefix(value, clipped) || jsonStringSize(clipped) > limit {
			t.Fatalf("limit %d: %q", limit, clipped)
		}
		if len(clipped) < len(value) && !utf8.RuneStart(value[len(clipped)]) {
			t.Fatalf("limit %d cut a character: %q", limit, clipped)
		}
	}
}

func TestLegacyMessagesGetDerivedParts(t *testing.T) {
	created := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)
	unified := chatMessageFromLegacy(Message{ID: "m1", Role: "assistant", Text: "done", Reasoning: []ReasoningPart{{Text: "why"}}, Tools: []ToolCall{{ID: "t1", Name: "bash", Status: "completed", Output: "ok"}}, Attachments: []AttachmentInfo{{Name: "a.png", MIME: "image/png"}}, Error: "failed"}, "claude", "claude:1", "u1", 7, created)
	encoded := string(marshalJSONLine(unified))
	want := `{"id":"m1","chatId":"claude:1","turnId":"u1","role":"assistant","status":"error","ord":7,"createdAt":"2026-09-23T12:00:00.000Z","provider":"claude","error":{"code":"agent_error","message":"failed"},"parts":[{"id":"m1:0","kind":"reasoning","ord":1,"text":"why"},{"id":"t1","kind":"tool","ord":2,"tool":{"name":"bash","callId":"","status":"completed","output":"ok","truncated":false}},{"id":"m1:2","kind":"text","ord":3,"text":"done"},{"id":"m1:3","kind":"attachment","ord":4,"attachment":{"name":"a.png","mime":"image/png"}}]}`
	if encoded != want {
		t.Fatalf("derived message:\n got: %s\nwant: %s", encoded, want)
	}
	var decoded map[string]any
	if json.Unmarshal([]byte(encoded), &decoded) != nil {
		t.Fatal("derived message is not JSON")
	}
}
