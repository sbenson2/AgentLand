package host

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// legacyTranscriptFixture is an OpenCode 1.18.31 transcript that uses every
// part type the host maps: synthetic text, files, steps, timed and blank
// reasoning, completed, failed and running tools, retries, patches and an
// assistant error with private response headers.
const legacyTranscriptFixture = `[
{"info":{"id":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","sessionID":"ses_1","role":"user","time":{"created":1790000000000},"agent":"build","model":{"providerID":"anthropic","modelID":"claude-sonnet","variant":"high"}},
 "parts":[
  {"id":"prt_0001a2b3c4d6AAAAAAAAAAAAAA","sessionID":"ses_1","messageID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","type":"text","text":"Please review <main.go> & tests"},
  {"id":"prt_0001a2b3c4d7AAAAAAAAAAAAAA","sessionID":"ses_1","messageID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","type":"text","synthetic":true,"text":"Called the Read tool with the following input: {\"filePath\":\"notes.txt\"}"},
  {"id":"prt_0001a2b3c4d8AAAAAAAAAAAAAA","sessionID":"ses_1","messageID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","type":"file","mime":"text/plain","filename":"notes.txt","url":"data:text/plain;base64,UFJJVkFURQ=="},
  {"id":"prt_0001a2b3c4d9AAAAAAAAAAAAAA","sessionID":"ses_1","messageID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","type":"file","mime":"image/png","url":"data:image/png;base64,iVBORw0KGgo="},
  {"id":"prt_0001a2b3c4daAAAAAAAAAAAAAA","sessionID":"ses_1","messageID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","type":"agent","name":"explore"}
 ]},
{"info":{"id":"msg_0001a2b3c4e0AAAAAAAAAAAAAA","sessionID":"ses_1","role":"assistant","time":{"created":1790000001000,"completed":1790000009000},"parentID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","modelID":"claude-sonnet","providerID":"anthropic","mode":"build","agent":"build","path":{"cwd":"/repo","root":"/repo"},"cost":0.0123,"tokens":{"input":1200,"output":340,"reasoning":80,"cache":{"read":1000,"write":20}},"variant":"high","finish":"stop"},
 "parts":[
  {"id":"prt_0001a2b3c4e1AAAAAAAAAAAAAA","type":"step-start","snapshot":"abc"},
  {"id":"prt_0001a2b3c4e2AAAAAAAAAAAAAA","type":"reasoning","text":"Comparing the files","time":{"start":1790000001100,"end":1790000003600}},
  {"id":"prt_0001a2b3c4e3AAAAAAAAAAAAAA","type":"reasoning","text":" \n ","time":{"start":1790000003700,"end":1790000003800}},
  {"id":"prt_0001a2b3c4e4AAAAAAAAAAAAAA","type":"reasoning","text":"Still thinking","time":{"start":1790000003900}},
  {"id":"prt_0001a2b3c4e5AAAAAAAAAAAAAA","type":"text","text":"Checking the project.","time":{"start":1790000004000,"end":1790000004500}},
  {"id":"prt_0001a2b3c4e6AAAAAAAAAAAAAA","type":"tool","tool":"bash","callID":"call_one","state":{"status":"completed","title":"Inspect files","input":{"command":"pwd"},"output":"sample-project\n","metadata":{},"time":{"start":1790000005000,"end":1790000005200}}},
  {"id":"prt_0001a2b3c4e7AAAAAAAAAAAAAA","type":"tool","tool":"read","callID":"call_two","state":{"status":"error","input":{"filePath":"missing.txt"},"error":"File does not exist","time":{"start":1790000005300,"end":1790000005400}}},
  {"id":"prt_0001a2b3c4e8AAAAAAAAAAAAAA","type":"tool","tool":"edit","callID":"call_three","state":{"status":"running","input":{"filePath":"main.go"},"title":"Editing","time":{"start":1790000005500}}},
  {"id":"prt_0001a2b3c4e9AAAAAAAAAAAAAA","type":"retry","attempt":1,"error":{"name":"APIError","data":{"message":"Overloaded","isRetryable":true}},"time":{"created":1790000006000}},
  {"id":"prt_0001a2b3c4eaAAAAAAAAAAAAAA","type":"text","text":"Looks good"},
  {"id":"prt_0001a2b3c4ebAAAAAAAAAAAAAA","type":"patch","hash":"deadbeef","files":["/repo/main.go","/repo/docs/notes.md"]},
  {"id":"prt_0001a2b3c4ecAAAAAAAAAAAAAA","type":"step-finish","reason":"stop","cost":0.0123,"tokens":{"input":1200,"output":340,"reasoning":80,"cache":{"read":1000,"write":20}}}
 ]},
{"info":{"id":"msg_0001a2b3c4f0AAAAAAAAAAAAAA","sessionID":"ses_1","role":"assistant","time":{"created":1790000010000,"completed":1790000011000},"parentID":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","modelID":"claude-sonnet","providerID":"anthropic","mode":"build","agent":"build","path":{"cwd":"/repo","root":"/repo"},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},
  "error":{"name":"APIError","data":{"message":"Provider rejected the API key","statusCode":401,"responseHeaders":{"sensitive":"do-not-forward"}}}},
 "parts":[]},
{"info":{"id":"msg_0001a2b3c500AAAAAAAAAAAAAA","sessionID":"ses_1","role":"system"},"parts":[{"type":"text","text":"not shown"}]}
]`

// The legacy GET /v1/messages body, captured from the host before the unified
// chat model existed. It must not change by a single byte for old clients.
const legacyTranscriptGolden = `{"messages":[{"id":"msg_0001a2b3c4d5AAAAAAAAAAAAAA","role":"user","text":"Please review \u003cmain.go\u003e \u0026 tests","attachments":[{"name":"notes.txt","mime":"text/plain"},{"name":"attachment","mime":"image/png"}]},{"id":"msg_0001a2b3c4e0AAAAAAAAAAAAAA","role":"assistant","text":"Checking the project.\nLooks good","tools":[{"id":"prt_0001a2b3c4e6AAAAAAAAAAAAAA","callId":"call_one","name":"bash","status":"completed","title":"Inspect files","input":"{\"command\":\"pwd\"}","output":"sample-project\n","error":"","truncated":false},{"id":"prt_0001a2b3c4e7AAAAAAAAAAAAAA","callId":"call_two","name":"read","status":"error","title":"","input":"{\"filePath\":\"missing.txt\"}","output":"","error":"File does not exist","truncated":false},{"id":"prt_0001a2b3c4e8AAAAAAAAAAAAAA","callId":"call_three","name":"edit","status":"running","title":"Editing","input":"{\"filePath\":\"main.go\"}","output":"","error":"","truncated":false}],"reasoning":[{"text":"Comparing the files","durationMs":2500},{"text":"Still thinking"}]},{"id":"msg_0001a2b3c4f0AAAAAAAAAAAAAA","role":"assistant","text":"","error":"Provider rejected the API key"}]}` + "\n"

const legacyCLIGolden = `{"messages":[{"id":"USER_ID","role":"user","text":"Summarize \u003cb\u003e \u0026 c"},{"id":"REPLY_ID","role":"assistant","text":"Reply to Summarize \u003cb\u003e \u0026 c"}]}` + "\n"

func legacyTranscriptHost(t *testing.T, revert string) (*Host, string) {
	t.Helper()
	directory := t.TempDir()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/session/ses_1":
			session := map[string]any{"id": "ses_1", "title": "Fixture", "directory": directory}
			if revert != "" {
				session["revert"] = map[string]string{"messageID": revert, "snapshot": "private"}
			}
			json.NewEncoder(w).Encode(session)
		case "/session/ses_1/message":
			w.Write([]byte(legacyTranscriptFixture))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(upstream.Close)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: upstream.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Fixture", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	host := newHost(store, NewOpenCodeAdapter(upstream.URL, "opencode", "fixture", upstream.Client()), HostOptions{})
	t.Cleanup(func() { host.Close() })
	return host, paired(t, host, store)
}

func TestLegacyMessagesResponseKeepsItsExactShape(t *testing.T) {
	host, token := legacyTranscriptHost(t, "")
	w := request(t, host.Handler(), "GET", "/v1/messages?projectId=p1&sessionId=ses_1", token, nil)
	if os.Getenv("AGENTLAND_PRINT_GOLDEN") != "" {
		t.Logf("legacy body:\n%s", w.Body.String())
	}
	if w.Code != 200 || w.Body.String() != legacyTranscriptGolden {
		t.Fatalf("legacy /v1/messages changed: %d\n got: %s\nwant: %s", w.Code, w.Body.String(), legacyTranscriptGolden)
	}
	rewound, token := legacyTranscriptHost(t, "msg_0001a2b3c4e0AAAAAAAAAAAAAA")
	w = request(t, rewound.Handler(), "GET", "/v1/messages?projectId=p1&sessionId=ses_1", token, nil)
	want := `{"messages":[` + strings.SplitN(strings.TrimPrefix(legacyTranscriptGolden, `{"messages":[`), `,{"id":"msg_0001a2b3c4e0`, 2)[0] + `],"rewind":{"messageId":"msg_0001a2b3c4e0AAAAAAAAAAAAAA"}}` + "\n"
	if w.Code != 200 || w.Body.String() != want {
		t.Fatalf("legacy rewound /v1/messages changed: %d\n got: %s\nwant: %s", w.Code, w.Body.String(), want)
	}
}

func TestLegacyMessagesResponseKeepsItsExactShapeForCLIChats(t *testing.T) {
	f := newChatFixture(t)
	id := f.cliSession(t, "claude")
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": id, "text": "Summarize <b> & c"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body.String())
	}
	waitFor(t, "CLI reply", func() bool {
		messages, _ := f.chats.Messages(mustProject(t, f.store), id)
		return len(messages) == 2
	})
	w := f.call(t, "GET", "/v1/messages?projectId=p1&sessionId="+id, nil)
	// Message IDs are random; compare the shape with them replaced.
	var body struct{ Messages []Message }
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || len(body.Messages) != 2 {
		t.Fatalf("CLI transcript: %v %s", err, w.Body.String())
	}
	got := strings.ReplaceAll(strings.ReplaceAll(w.Body.String(), body.Messages[0].ID, "USER_ID"), body.Messages[1].ID, "REPLY_ID")
	if os.Getenv("AGENTLAND_PRINT_GOLDEN") != "" {
		t.Logf("legacy CLI body:\n%s", got)
	}
	if w.Code != 200 || got != legacyCLIGolden {
		t.Fatalf("legacy CLI /v1/messages changed:\n got: %s\nwant: %s", got, legacyCLIGolden)
	}
}
