package host

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestProvidersFromOpenCode(t *testing.T) {
	var fail bool
	var mu sync.Mutex
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		failing := fail
		mu.Unlock()
		if r.URL.Path != "/provider" || failing {
			w.WriteHeader(500)
			return
		}
		fmt.Fprint(w, `{"all":[
		 {"id":"openai","name":"OpenAI","source":"custom","env":["OPENAI_API_KEY"],"options":{"apiKey":"sk-secret-value"},"models":{"gpt-a":{"id":"gpt-a"},"gpt-b":{"id":"gpt-b"}},"key":"sk-other-secret"},
		 {"id":"anthropic","name":"Anthropic","env":["ANTHROPIC_API_KEY"],"options":{},"models":{"claude":{}}},
		 {"id":"google","name":"Google","env":["GOOGLE_API_KEY","GEMINI_API_KEY","bad name"],"models":{}},
		 {"id":"","name":"Nameless"}
		],"default":{"openai":"gpt-a"},"connected":["openai"]}`)
	}))
	t.Cleanup(server.Close)
	_, store, _ := testHost(t)
	host := newHost(store, NewOpenCodeAdapter(server.URL, "opencode", "fixture", server.Client()), HostOptions{Agents: &AgentOptions{}})
	quietAgents(host.agents, nil, nil, nil)
	t.Cleanup(func() { host.Close(); host.agents.close() })
	token := paired(t, host, store)
	w := request(t, host.Handler(), "GET", "/v1/providers", token, nil)
	want := `{"providers":[{"id":"anthropic","name":"Anthropic","connected":false,"models":1,"env":["ANTHROPIC_API_KEY"]},{"id":"google","name":"Google","connected":false,"models":0,"env":["GOOGLE_API_KEY","GEMINI_API_KEY"]},{"id":"openai","name":"OpenAI","connected":true,"models":2,"env":["OPENAI_API_KEY"]}]}` + "\n"
	if w.Code != 200 || w.Body.String() != want {
		t.Fatalf("providers %d %s", w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), "secret") {
		t.Fatal("a key left the host")
	}
	mu.Lock()
	fail = true
	mu.Unlock()
	if w := request(t, host.Handler(), "GET", "/v1/providers", token, nil); w.Code != 503 || !strings.Contains(w.Body.String(), "provider_catalog_unavailable") {
		t.Fatalf("OpenCode failing %d %s", w.Code, w.Body)
	}
}
