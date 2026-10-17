package host

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestChatOptionsOnlyExposeConnectedModelsAndPublicMetadata(t *testing.T) {
	a := NewOpenCodeAdapter("http://127.0.0.1:4096", "opencode", "private", &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"model":"deepseek/chat","private":"must-not-leak"}`
		if r.URL.Path == "/provider" {
			body = `{"all":[{"id":"deepseek","name":"DeepSeek","options":{"apiKey":"must-not-leak"},"models":{"chat":{"id":"chat","name":"Chat","limit":{"context":128000}}}},{"id":"other","name":"Other","models":{"private":{"id":"private","name":"Unavailable"}}}],"connected":["deepseek"]}`
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	})})
	options, err := a.ChatOptions(Project{Directory: "/repo"})
	if err != nil {
		t.Fatal(err)
	}
	if len(options.Models) != 1 || options.Models[0].ID != "deepseek/chat" || options.DefaultModel != "deepseek/chat" {
		t.Fatalf("unexpected options: %#v", options)
	}
	data, _ := json.Marshal(options)
	if strings.Contains(string(data), "must-not-leak") {
		t.Fatal("provider configuration escaped into mobile protocol")
	}
}

func TestConfiguredPromptCarriesModelAndPlanWithoutChangingPermissions(t *testing.T) {
	called := false
	a := NewOpenCodeAdapter("http://127.0.0.1:4096", "opencode", "private", &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		called = true
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["agent"] != "plan" || body["model"].(map[string]any)["providerID"] != "deepseek" {
			t.Fatalf("wrong prompt options: %v", body)
		}
		if _, exists := body["tools"]; exists {
			t.Fatal("prompt must not silently override tool permissions")
		}
		return &http.Response{StatusCode: 204, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})})
	if err := a.PromptConfigured(Project{Directory: "/repo"}, "s1", "review", PromptOptions{Model: "deepseek/chat", Agent: "plan"}); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Fatal("prompt not delivered")
	}
	called = false
	if err := a.PromptConfigured(Project{Directory: "/repo"}, "s1", "review", PromptOptions{Model: "bad", Agent: "arbitrary"}); err == nil || called {
		t.Fatal("invalid options must fail before network")
	}
}

func TestChatOptionsRoutesStillRequireAuthentication(t *testing.T) {
	h, _, _ := testHost(t)
	for _, path := range []string{"/v1/chat/options?projectId=p1", "/v1/chat/status?projectId=p1&sessionId=s1"} {
		if w := request(t, h.Handler(), "GET", path, "", nil); w.Code != 401 {
			t.Fatalf("%s was not protected", path)
		}
	}
}

func TestChatOptionsPreserveProjectAndSessionBoundariesAndLegacyAgents(t *testing.T) {
	h, store, agent := testHost(t)
	token := paired(t, h, store)
	for _, path := range []string{"/v1/chat/options?projectId=missing", "/v1/chat/status?projectId=p1&sessionId=missing"} {
		if w := request(t, h.Handler(), "GET", path, token, nil); w.Code != 404 {
			t.Fatalf("scope %s: %d", path, w.Code)
		}
	}
	agent.sessions["foreign"] = Session{ID: "foreign", Directory: t.TempDir()}
	if w := request(t, h.Handler(), "GET", "/v1/chat/status?projectId=p1&sessionId=foreign", token, nil); w.Code != 404 {
		t.Fatalf("foreign session status: %d", w.Code)
	}
	// An adapter without model selection still accepts the original prompt body.
	if w := request(t, h.Handler(), "POST", "/v1/messages", token, map[string]string{"projectId": "p1", "sessionId": "s1", "text": "hello"}); w.Code != 202 {
		t.Fatalf("legacy prompt: %d %s", w.Code, w.Body.String())
	}
	if w := request(t, h.Handler(), "GET", "/v1/chat/options?projectId=p1", token, nil); w.Code != 200 || !strings.Contains(w.Body.String(), `"agents":[]`) {
		t.Fatalf("legacy capability: %d %s", w.Code, w.Body.String())
	}
	if w := request(t, h.Handler(), "POST", "/v1/messages", token, map[string]string{"projectId": "p1", "sessionId": "s1", "text": "hello", "agent": "plan"}); w.Code != 400 {
		t.Fatalf("unsupported agent must be explicit: %d", w.Code)
	}
	state, _ := store.Read()
	if err := store.RevokeDevice(state.Devices[0].ID); err != nil {
		t.Fatal(err)
	}
	if w := request(t, h.Handler(), "GET", "/v1/chat/options?projectId=p1", token, nil); w.Code != 401 {
		t.Fatalf("revoked device accessed provider catalog: %d", w.Code)
	}
}
