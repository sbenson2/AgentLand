package host

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestOpenCodePathBodyAuthAndDirectoryMapping(t *testing.T) {
	var calls []string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if user, pass, ok := r.BasicAuth(); !ok || user != "opencode" || pass != "secret" {
			t.Errorf("bad auth")
		}
		if r.Header.Get("X-OpenCode-Directory") != "/repo" {
			t.Errorf("directory=%q", r.Header.Get("X-OpenCode-Directory"))
		}
		calls = append(calls, r.Method+" "+r.URL.RequestURI())
		status, response := 200, ""
		switch r.URL.Path {
		case "/session":
			if r.Method == "POST" {
				var b map[string]any
				json.NewDecoder(r.Body).Decode(&b)
				if b["title"] != "New" {
					t.Errorf("body=%v", b)
				}
				response = `{"id":"s2","title":"New","projectID":"native","directory":"/repo"}`
			} else {
				response = `[]`
			}
		case "/session/s1":
			response = `{"id":"s1","title":"One","projectID":"native","directory":"/repo"}`
		case "/session/s1/message":
			response = `[{"info":{"id":"m1","role":"assistant"},"parts":[{"type":"text","text":"hello"}]}]`
		case "/session/s1/prompt_async":
			var b map[string]any
			json.NewDecoder(r.Body).Decode(&b)
			raw, _ := json.Marshal(b)
			if !strings.Contains(string(raw), `"text":"go"`) {
				t.Errorf("body=%s", raw)
			}
			status = 204
		case "/session/s1/abort":
			response = `true`
		}
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(response)), Request: r}, nil
	})}
	a := NewOpenCodeAdapter("http://127.0.0.1:4096", "opencode", "secret", client)
	p := Project{ID: "p1", Name: "P", Directory: "/repo"}
	if _, err := a.CreateSession(p, "New"); err != nil {
		t.Fatal(err)
	}
	if _, err := a.GetSession(p, "s1"); err != nil {
		t.Fatal(err)
	}
	m, err := a.Messages(p, "s1")
	if err != nil || len(m) != 1 || m[0].Text != "hello" {
		t.Fatalf("m=%v err=%v", m, err)
	}
	if err := a.Prompt(p, "s1", "go"); err != nil {
		t.Fatal(err)
	}
	if err := a.Abort(p, "s1"); err != nil {
		t.Fatal(err)
	}
	want := []string{"POST /session", "GET /session/s1", "GET /session/s1/message", "POST /session/s1/prompt_async", "POST /session/s1/abort"}
	if strings.Join(calls, "|") != strings.Join(want, "|") {
		t.Fatalf("calls=%v", calls)
	}
}

func TestOpenCodeAdapterDoesNotFollowRedirects(t *testing.T) {
	calls := 0
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{"http://127.0.0.1:9999/session"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}
	a := NewOpenCodeAdapter("http://127.0.0.1:4096", "opencode", "secret", client)
	if _, err := a.ListSessions(Project{Directory: "/repo"}); err == nil {
		t.Fatal("redirect accepted")
	}
	if calls != 1 {
		t.Fatalf("calls=%d", calls)
	}
}

func TestOpenCodeProviderFailureSurvivesAnEmptyAssistantMessage(t *testing.T) {
	a := NewOpenCodeAdapter("http://127.0.0.1:4096", "opencode", "secret", &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		response := `[{"info":{"id":"m1","role":"assistant","error":{"name":"APIError","data":{"message":"Provider rejected the API key","responseHeaders":{"sensitive":"do-not-forward"}}}},"parts":[]}]`
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(response)), Request: r}, nil
	})})
	messages, err := a.Messages(Project{Directory: "/repo"}, "s1")
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(messages)
	if !strings.Contains(string(encoded), "Provider rejected the API key") {
		t.Fatal("provider failure disappeared from empty assistant message")
	}
	if strings.Contains(string(encoded), "do-not-forward") {
		t.Fatal("private upstream response fields leaked")
	}
}
