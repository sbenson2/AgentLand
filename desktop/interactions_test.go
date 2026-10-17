package host

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"
)

const pendingPermissions = `[{"id":"per_one","sessionID":"s1","permission":"bash","patterns":["git status"],"metadata":{"description":"Inspect the working tree"},"always":["git status"]},{"id":"per_other","sessionID":"s2","permission":"edit","patterns":["private.txt"],"metadata":{},"always":[]}]`
const pendingQuestions = `[{"id":"que_one","sessionID":"s1","questions":[{"header":"Target","question":"Which platform?","options":[{"label":"iOS","description":"Phone and tablet"}],"multiple":false,"custom":false},{"header":"Notes","question":"What else?","options":[],"multiple":false}],"tool":{"messageID":"msg_one","callID":"call_one"}},{"id":"que_other","sessionID":"s2","questions":[]}]`

type interactionProbe struct {
	mu       sync.Mutex
	replies  []map[string]any
	paths    []string
	failList bool
}

func (p *interactionProbe) replyCount() int { p.mu.Lock(); defer p.mu.Unlock(); return len(p.replies) }

func interactionTestHost(t *testing.T) (*Host, string, *interactionProbe) {
	t.Helper()
	directory := t.TempDir()
	probe := &interactionProbe{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		if !ok || user != "opencode" || password != "fixture-password" || r.Header.Get("X-OpenCode-Directory") != directory {
			t.Error("adapter lost loopback authentication or project routing")
			http.Error(w, "unauthorized", 401)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == "GET" && (r.URL.Path == "/session/s1" || r.URL.Path == "/session/s2"):
			json.NewEncoder(w).Encode(map[string]string{"id": strings.TrimPrefix(r.URL.Path, "/session/"), "title": "Fixture", "directory": directory})
		case r.Method == "GET" && r.URL.Path == "/permission":
			if probe.failList {
				http.Error(w, "unavailable", 503)
				return
			}
			w.Write([]byte(pendingPermissions))
		case r.Method == "GET" && r.URL.Path == "/question":
			w.Write([]byte(pendingQuestions))
		case r.Method == "GET" && r.URL.Path == "/session/s1/message":
			w.Write([]byte(`[{"info":{"id":"msg_one","role":"assistant"},"parts":[{"type":"text","text":"Checking the project."},{"id":"prt_one","type":"tool","tool":"bash","callID":"call_one","state":{"status":"completed","title":"Inspect files","input":{"command":"pwd"},"output":"sample-project\n","metadata":{},"time":{"start":1,"end":2}}},{"id":"prt_two","type":"tool","tool":"read","callID":"call_two","state":{"status":"error","input":{"filePath":"missing.txt"},"error":"File does not exist","time":{"start":2,"end":3}}}]}]`))
		case r.Method == "POST":
			var body map[string]any
			if r.ContentLength != 0 {
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
			}
			probe.mu.Lock()
			probe.paths = append(probe.paths, r.URL.Path)
			probe.replies = append(probe.replies, body)
			probe.mu.Unlock()
			w.Write([]byte("true"))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(upstream.Close)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "state.json"))
	if err := store.Initialize(Config{OpenCodeURL: upstream.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Fixture", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	host := New(store, NewOpenCodeAdapter(upstream.URL, "opencode", "fixture-password", upstream.Client()))
	return host, paired(t, host, store), probe
}

func TestMessagesKeepToolResultsAndErrors(t *testing.T) {
	host, token, _ := interactionTestHost(t)
	response := request(t, host.Handler(), "GET", "/v1/messages?projectId=p1&sessionId=s1", token, nil)
	if response.Code != 200 {
		t.Fatalf("messages: %d %s", response.Code, response.Body.String())
	}
	var body struct {
		Messages []struct {
			Text  string
			Tools []struct{ Name, Status, Input, Output, Error string }
		}
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Messages) != 1 || len(body.Messages[0].Tools) != 2 {
		t.Fatalf("tool results were lost: %s", response.Body.String())
	}
	message := body.Messages[0]
	if message.Text != "Checking the project." || message.Tools[0].Name != "bash" || message.Tools[0].Status != "completed" || message.Tools[0].Output != "sample-project\n" || !strings.Contains(message.Tools[0].Input, "pwd") || message.Tools[1].Error != "File does not exist" {
		t.Fatalf("tool data changed: %+v", message)
	}
}

func TestOversizedToolOutputIsClippedAtAUTF8Boundary(t *testing.T) {
	original := strings.Repeat("x", (64<<10)-1) + strings.Repeat("é", 20)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, []any{map[string]any{"info": map[string]string{"id": "msg", "role": "assistant"}, "parts": []any{map[string]any{"id": "part", "type": "tool", "tool": "bash", "state": map[string]any{"status": "completed", "input": map[string]string{"command": "fixture"}, "output": original}}}}})
	}))
	defer upstream.Close()
	adapter := NewOpenCodeAdapter(upstream.URL, "opencode", "fixture", upstream.Client())
	messages, err := adapter.Messages(Project{Directory: t.TempDir()}, "session")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || len(messages[0].Tools) != 1 {
		t.Fatal("tool result lost")
	}
	tool := messages[0].Tools[0]
	if !tool.Truncated || !utf8.ValidString(tool.Output) || len(tool.Output) != (64<<10)-1 || !strings.HasPrefix(original, tool.Output) {
		t.Fatal("oversized tool result was corrupted or clipping not disclosed")
	}
}

func TestInteractionsOnlyExposeTheSelectedSession(t *testing.T) {
	host, token, _ := interactionTestHost(t)
	response := request(t, host.Handler(), "GET", "/v1/interactions?projectId=p1&sessionId=s1", token, nil)
	if response.Code != 200 {
		t.Fatalf("interactions: %d %s", response.Code, response.Body.String())
	}
	var body struct {
		Permissions []struct{ ID, SessionID, Details string }
		Questions   []struct {
			ID, SessionID string
			Questions     []struct{ Multiple, Custom bool }
		}
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Permissions) != 1 || body.Permissions[0].ID != "per_one" || body.Permissions[0].SessionID != "s1" || !strings.Contains(body.Permissions[0].Details, "working tree") {
		t.Fatalf("wrong permission scope: %s", response.Body.String())
	}
	if len(body.Questions) != 1 || body.Questions[0].ID != "que_one" || body.Questions[0].Questions[0].Custom || !body.Questions[0].Questions[1].Custom {
		t.Fatalf("wrong question scope or defaults: %s", response.Body.String())
	}
}

func TestPermissionReplyChecksPendingOwnershipAndDoesNotGrantAlways(t *testing.T) {
	host, token, probe := interactionTestHost(t)
	for _, test := range []struct {
		name, id, reply string
		want            int
	}{{"wrong session", "per_other", "once", 404}, {"gone", "per_missing", "once", 404}, {"persistent permission", "per_one", "always", 400}, {"unknown choice", "per_one", "yes", 400}} {
		t.Run(test.name, func(t *testing.T) {
			response := request(t, host.Handler(), "POST", "/v1/permissions/reply", token, map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": test.id, "reply": test.reply})
			if response.Code != test.want {
				t.Fatalf("status=%d want=%d", response.Code, test.want)
			}
		})
	}
	if probe.replyCount() != 0 {
		t.Fatal("invalid reply reached upstream")
	}
	response := request(t, host.Handler(), "POST", "/v1/permissions/reply", token, map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": "per_one", "reply": "once"})
	if response.Code != 200 || probe.replyCount() != 1 {
		t.Fatalf("allow once: %d %s", response.Code, response.Body.String())
	}
	probe.mu.Lock()
	defer probe.mu.Unlock()
	if probe.paths[0] != "/permission/per_one/reply" || probe.replies[0]["reply"] != "once" {
		t.Fatalf("incorrect upstream mutation: %v %v", probe.paths, probe.replies)
	}
}

func TestQuestionReplyValidatesChoicesAndOrderedAnswers(t *testing.T) {
	host, token, probe := interactionTestHost(t)
	for _, answers := range []any{[][]string{{"iOS"}}, [][]string{{"Android"}, {"Keep tabs"}}, [][]string{{"iOS", "Android"}, {"Keep tabs"}}, [][]string{{"iOS"}, {""}}} {
		response := request(t, host.Handler(), "POST", "/v1/questions/reply", token, map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": "que_one", "answers": answers})
		if response.Code != 400 {
			t.Fatalf("invalid answers accepted: %d %s", response.Code, response.Body.String())
		}
	}
	if probe.replyCount() != 0 {
		t.Fatal("invalid answers reached upstream")
	}
	response := request(t, host.Handler(), "POST", "/v1/questions/reply", token, map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": "que_one", "answers": [][]string{{"iOS"}, {"Keep tabs"}}})
	if response.Code != 200 || probe.replyCount() != 1 {
		t.Fatalf("reply: %d %s", response.Code, response.Body.String())
	}
	probe.mu.Lock()
	defer probe.mu.Unlock()
	encoded, _ := json.Marshal(probe.replies[0])
	if string(encoded) != `{"answers":[["iOS"],["Keep tabs"]]}` || probe.paths[0] != "/question/que_one/reply" {
		t.Fatalf("answers reordered or changed: %s", encoded)
	}
}

func TestQuestionRejectCannotActOnAnotherSession(t *testing.T) {
	host, token, probe := interactionTestHost(t)
	for _, test := range []struct {
		id   string
		want int
	}{{"que_other", 404}, {"que_one", 200}} {
		response := request(t, host.Handler(), "POST", "/v1/questions/reject", token, map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": test.id})
		if response.Code != test.want {
			t.Fatalf("reject %s: %d", test.id, response.Code)
		}
	}
	if probe.replyCount() != 1 {
		t.Fatalf("unexpected upstream mutation count: %d", probe.replyCount())
	}
}

func TestInteractionRepliesFailClosedWhenPendingRequestsCannotBeRead(t *testing.T) {
	host, token, probe := interactionTestHost(t)
	probe.failList = true
	response := request(t, host.Handler(), "POST", "/v1/permissions/reply", token, map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": "per_one", "reply": "once"})
	if response.Code != 502 || probe.replyCount() != 0 {
		t.Fatalf("upstream lookup failure not contained: %d replies=%d", response.Code, probe.replyCount())
	}
}
