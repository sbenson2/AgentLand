package host

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestCodexContract runs the Codex engine against the real installed codex
// (AGENTLAND_TEST_CODEX=1). It spends no model credits and never touches the
// owner's Codex state: CODEX_HOME and HOME are throwaway folders, the model
// provider is a local fake of the OpenAI Responses API, and outbound HTTP
// goes to a closed local proxy port.
func TestCodexContract(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_CODEX") != "1" {
		t.Skip("set AGENTLAND_TEST_CODEX=1 to run the installed codex against a fake model")
	}
	executable, ok := executableForProgram("codex")
	if !ok {
		t.Skip("codex is not installed")
	}
	model := newFakeResponses(t)
	codexHome, home, project := t.TempDir(), t.TempDir(), t.TempDir()
	config := codexEngineConfig{
		executable: func() (string, bool) { return executable, true },
		configArgs: []string{
			"-c", `model_provider="agentland_fake"`,
			"-c", `model_providers.agentland_fake.name="fake"`,
			"-c", `model_providers.agentland_fake.base_url="` + model.server.URL + `/v1"`,
			"-c", `model_providers.agentland_fake.wire_api="responses"`,
			"-c", `model_providers.agentland_fake.env_key="AGENTLAND_FAKE_KEY"`,
			"-c", `model="fake-model"`,
		},
		env:         []string{"CODEX_HOME=" + codexHome, "HOME=" + home, "AGENTLAND_FAKE_KEY=fake-key", "HTTPS_PROXY=http://127.0.0.1:9", "HTTP_PROXY=http://127.0.0.1:9", "ALL_PROXY=http://127.0.0.1:9", "NO_PROXY=127.0.0.1,localhost"},
		dir:         home,
		callTimeout: 60 * time.Second,
		log:         func(message string) { t.Log("engine: " + message) },
	}
	f := newCodexContractFixture(t, project, config)
	report := func(format string, args ...any) { t.Logf("CONFIRMED "+format, args...) }

	// A turn with reasoning, streamed text and a command that needs approval.
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 30*time.Second)
	first := f.send(id, "Say hello and RUN a command", map[string]any{"mode": "ask"})
	events := stream.until(t, "interaction.requested", 60*time.Second)
	interaction := events[len(events)-1].Interaction
	kinds := map[string]int{}
	for _, event := range events {
		kind := event.Type
		if event.Part != nil {
			kind += ":" + event.Part.Kind
		}
		kinds[kind]++
	}
	if kinds["part.delta"] == 0 || kinds["part.created:reasoning"] == 0 || kinds["part.created:text"] == 0 {
		t.Fatalf("no streamed parts before the approval: %v", kinds)
	}
	report("streaming before approval: %v", kinds)
	if interaction.Kind != "permission" || interaction.Permission.Tool != "Command" || len(interaction.Choices) == 0 {
		t.Fatalf("approval: %s", events[len(events)-1].raw)
	}
	report("approval %q offers %v (from availableDecisions), detail %q", interaction.Permission.Title, interaction.Choices, interaction.Permission.Detail)
	if offersAlways := strings.Contains(strings.Join(interaction.Choices, ","), "always"); offersAlways != (interaction.AlwaysLabel != "") || interaction.AlwaysLabel == codexAlwaysGeneric {
		t.Fatalf("always label: %q for %v", interaction.AlwaysLabel, interaction.Choices)
	}
	report("always reads %q (%q)", interaction.AlwaysLabel, interaction.AlwaysDetail)
	f.chats.mu.Lock()
	if pending := f.chats.codex.requests[interaction.ID]; pending != nil {
		mapping, _ := json.Marshal(pending.decisions)
		report("choices map to Codex decisions %s", mapping)
	}
	f.chats.mu.Unlock()
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": interaction.ID, "reply": "once"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	events = stream.until(t, "turn.finished", 60*time.Second)
	finished := events[len(events)-1]
	if finished.Outcome != "completed" || finished.TurnID != first.MessageID || finished.Usage == nil {
		t.Fatalf("turn.finished: %s", finished.raw)
	}
	report("turn.finished completed with usage %+v", *finished.Usage)
	if _, err := os.Stat(filepath.Join(project, "agentland-contract.txt")); err != nil {
		t.Fatalf("the approved command did not run: %v", err)
	}
	report("the approved command ran in the project")
	f.idle(id)
	page := f.page(id, 1)
	summary := []string{}
	for _, part := range page[0].Parts {
		entry := part.Kind
		if part.Tool != nil {
			entry += ":" + part.Tool.Name + ":" + part.Tool.Status
		} else if len(part.Text) < 60 {
			entry += ":" + part.Text
		}
		summary = append(summary, entry)
	}
	report("reply parts in order: %s", strings.Join(summary, " | "))

	// A second turn, then an edit of it: Codex drops the old turn.
	second := f.send(id, "Second prompt", nil)
	f.idle(id)
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": second.MessageID}); w.Code != 200 || !strings.Contains(w.Body.String(), `"filesRestore":"unavailable"`) {
		t.Fatalf("rewind: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("restore: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": second.MessageID}); w.Code != 200 {
		t.Fatalf("rewind again: %d %s", w.Code, w.Body)
	}
	f.send(id, "Second prompt, edited", nil)
	f.idle(id)
	edited := model.lastWith("Second prompt, edited")
	if edited == nil || strings.Contains(strings.Join(edited.userTexts, "\n"), "Second prompt\n") || containsExactly(edited.userTexts, "Second prompt") {
		t.Fatalf("the edited turn still carries the old message: %+v", edited)
	}
	if !containsExactly(edited.userTexts, "Say hello and RUN a command") {
		t.Fatalf("the edited turn lost the first message: %+v", edited.userTexts)
	}
	report("thread/revert removed the rewound turn from Codex's history; the next request held %q", edited.userTexts)
	if messages := f.messages(id); len(messages) != 4 || messages[2].Text != "Second prompt, edited" {
		t.Fatalf("after the edit: %+v", messages)
	}

	// A fork through the first turn continues on its own thread.
	w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "messageId": first.MessageID})
	if w.Code != 201 {
		t.Fatalf("fork: %d %s", w.Code, w.Body)
	}
	var forked Session
	json.Unmarshal(w.Body.Bytes(), &forked)
	f.send(forked.ID, "In the fork", nil)
	f.idle(forked.ID)
	branch := model.lastWith("In the fork")
	if branch == nil || !containsExactly(branch.userTexts, "Say hello and RUN a command") || containsExactly(branch.userTexts, "Second prompt, edited") {
		t.Fatalf("fork history: %+v", branch)
	}
	report("thread/fork with lastTurnId kept only the first turn: %q", branch.userTexts)

	// Stop interrupts a running turn.
	f.send(id, "STALL for a while", nil)
	waitFor(t, "the stalled model call", func() bool { return model.stalled() })
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("abort: %d %s", w.Code, w.Body)
	}
	f.idle(id)
	if !strings.Contains(f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil).Body.String(), `"status":"aborted"`) {
		t.Fatal("the stopped reply is not aborted")
	}
	report("turn/interrupt ended the turn as aborted")

	// Capabilities and options.
	entry := f.host.advertisedCapabilities().ChatProviderInfo.Codex
	if entry.Transport != "app-server" || !codexTestedVersion(entry.Version) || !reflect.DeepEqual(entry.Features, []string{"rewind", "fork", "approvals", "modes", "effort"}) {
		t.Fatalf("capabilities: %+v", entry)
	}
	capabilities, _ := json.Marshal(entry)
	report("capabilities codex %s", capabilities)
	var options ChatOptions
	json.Unmarshal(f.call("GET", "/v1/chat/options?projectId=p1&sessionId="+id, nil).Body.Bytes(), &options)
	if len(options.Models) < 2 || len(options.Modes) != 4 {
		t.Fatalf("options: %+v", options)
	}
	report("model/list gave %d models; first %s with efforts %v", len(options.Models)-1, options.Models[1].ID, options.Models[1].Efforts)

	// The codex exec fallback, new and resumed, with the fixed resume flags.
	execConfig := config
	execConfig.execOnly = true
	execHost := newCodexContractFixture(t, project, execConfig)
	execID := execHost.newChat()
	execHost.send(execID, "Hello over exec", nil)
	execHost.idle(execID)
	execHost.send(execID, "Resumed over exec", nil)
	execHost.idle(execID)
	messages := execHost.messages(execID)
	if len(messages) != 4 || messages[1].Error != "" || messages[3].Error != "" || messages[3].Text == "" {
		t.Fatalf("exec messages: %+v", messages)
	}
	newRun, resumed := model.lastWith("Hello over exec"), model.lastWith("Resumed over exec")
	if newRun == nil || resumed == nil || !newRun.autoReview || !resumed.autoReview || !resumed.workspaceWrite || !containsExactly(resumed.userTexts, "Hello over exec") {
		t.Fatalf("exec runs: new %+v, resumed %+v", newRun, resumed)
	}
	report("codex exec new and resumed runs both ran with workspace-write and auto-review; the resumed run kept the thread")

	// A chat that ran over codex exec (as every Codex chat did before) goes on
	// through the app-server, which resumes the thread exec created.
	execHost.host.Close()
	upgraded, err := NewCLIChats(execHost.store.Path+".chats.json", codexTestRunner{config: config})
	if err != nil {
		t.Fatal(err)
	}
	defer upgraded.Close()
	done := make(chan struct{})
	if err := upgraded.PromptAs(execHost.project, execID, cliMessageID(), "Back on the app-server", PromptOptions{}, nil, func() { close(done) }); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		t.Fatal("the turn after exec did not end")
	}
	messages, _ = upgraded.Messages(execHost.project, execID)
	back := model.lastWith("Back on the app-server")
	if last := messages[len(messages)-1]; last.Error != "" || last.Text != "Hello from the fake model." || back == nil || !containsExactly(back.userTexts, "Hello over exec") {
		t.Fatalf("after exec: %+v, request %+v", messages[len(messages)-1], back)
	}
	report("the app-server resumed a thread codex exec had created, with its history")
	t.Logf("fake model requests: %d", model.count())
}

func containsExactly(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func newCodexContractFixture(t *testing.T, project string, config codexEngineConfig) *codexFixture {
	t.Helper()
	oc := newFakeOpenCode(t, project)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Contract", Directory: project}}}); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(store.Path+".chats.json", codexTestRunner{config: config})
	if err != nil {
		t.Fatal(err)
	}
	host := newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: chats})
	host.chatPace, host.chatBeatEvery, host.chatAuthEvery = time.Millisecond, time.Hour, time.Hour
	server := httptest.NewServer(host.Handler())
	f := &codexFixture{t: t, host: host, store: store, chats: chats, server: server, project: mustProject(t, store)}
	t.Cleanup(func() {
		server.Close()
		host.Close()
	})
	f.token = paired(t, host, store)
	return f
}

func (f *codexFixture) page(id string, limit int) []ChatMessage {
	f.t.Helper()
	w := f.call("GET", fmt.Sprintf("/v1/chat/messages?projectId=p1&sessionId=%s&limit=%d", id, limit), nil)
	var page struct {
		Messages []ChatMessage `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &page)
	return page.Messages
}

// fakeResponses is a local OpenAI Responses API: streamed replies with
// reasoning, text and, when asked to RUN, an exec_command call that needs
// approval.
type fakeResponses struct {
	server   *httptest.Server
	mu       sync.Mutex
	requests []*fakeResponsesRequest
	stall    bool
}

type fakeResponsesRequest struct {
	tools          []json.RawMessage
	input          string
	model          string
	userTexts      []string
	afterTool      bool
	autoReview     bool
	workspaceWrite bool
}

func newFakeResponses(t *testing.T) *fakeResponses {
	f := &fakeResponses{}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeResponses) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func (f *fakeResponses) stalled() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.stall
}

// lastWith returns the last request whose newest user message is text.
func (f *fakeResponses) lastWith(text string) *fakeResponsesRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	for index := len(f.requests) - 1; index >= 0; index-- {
		request := f.requests[index]
		if len(request.userTexts) > 0 && request.userTexts[len(request.userTexts)-1] == text {
			return request
		}
	}
	return nil
}

func (f *fakeResponses) serve(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"object":"list","data":[]}`))
		return
	}
	var body struct {
		Model string            `json:"model"`
		Tools []json.RawMessage `json:"tools"`
		Input []struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"input"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil {
		http.Error(w, "bad request", 400)
		return
	}
	encodedInput, _ := json.Marshal(body.Input)
	request := &fakeResponsesRequest{model: body.Model, tools: body.Tools, input: string(encodedInput)}
	for _, item := range body.Input {
		for _, content := range item.Content {
			switch {
			case item.Role == "user" && content.Type == "input_text" && !strings.HasPrefix(content.Text, "<"):
				request.userTexts = append(request.userTexts, content.Text)
			case item.Role == "developer" && strings.Contains(content.Text, "<permissions instructions>"):
				// The latest permissions block wins, as for the model.
				request.autoReview = strings.Contains(content.Text, "`approvals_reviewer` is `auto_review`")
				request.workspaceWrite = strings.Contains(content.Text, "`sandbox_mode` is `workspace-write`")
			}
		}
	}
	if len(body.Input) > 0 {
		request.afterTool = body.Input[len(body.Input)-1].Type == "function_call_output"
	}
	f.mu.Lock()
	f.requests = append(f.requests, request)
	f.mu.Unlock()
	prompt := ""
	if len(request.userTexts) > 0 {
		prompt = request.userTexts[len(request.userTexts)-1]
	}
	w.Header().Set("Content-Type", "text/event-stream")
	flusher, _ := w.(http.Flusher)
	send := func(event string, data any) {
		payload, _ := json.Marshal(data)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, payload)
		if flusher != nil {
			flusher.Flush()
		}
	}
	n := f.count()
	response := fmt.Sprintf("resp_%d", n)
	send("response.created", map[string]any{"type": "response.created", "response": map[string]any{"id": response, "status": "in_progress", "output": []any{}}})
	reasoning := fmt.Sprintf("rs_%d", n)
	send("response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"type": "reasoning", "id": reasoning, "summary": []any{}}})
	send("response.reasoning_summary_part.added", map[string]any{"type": "response.reasoning_summary_part.added", "item_id": reasoning, "output_index": 0, "summary_index": 0, "part": map[string]any{"type": "summary_text", "text": ""}})
	for _, delta := range []string{"Thinking ", "it over."} {
		send("response.reasoning_summary_text.delta", map[string]any{"type": "response.reasoning_summary_text.delta", "item_id": reasoning, "output_index": 0, "summary_index": 0, "delta": delta})
	}
	reasoningItem := map[string]any{"type": "reasoning", "id": reasoning, "summary": []any{map[string]any{"type": "summary_text", "text": "Thinking it over."}}}
	send("response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": 0, "item": reasoningItem})
	message := fmt.Sprintf("msg_%d", n)
	chunks := []string{"Hello ", "from the ", "fake model."}
	if request.afterTool {
		chunks = []string{"Done ", "after the tool."}
	}
	send("response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": 1, "item": map[string]any{"type": "message", "id": message, "status": "in_progress", "role": "assistant", "content": []any{}}})
	send("response.content_part.added", map[string]any{"type": "response.content_part.added", "item_id": message, "output_index": 1, "content_index": 0, "part": map[string]any{"type": "output_text", "text": "", "annotations": []any{}}})
	for _, chunk := range chunks {
		send("response.output_text.delta", map[string]any{"type": "response.output_text.delta", "item_id": message, "output_index": 1, "content_index": 0, "delta": chunk})
	}
	if strings.Contains(prompt, "STALL") && !request.afterTool {
		f.mu.Lock()
		f.stall = true
		f.mu.Unlock()
		select {
		case <-r.Context().Done():
		case <-time.After(60 * time.Second):
		}
		return
	}
	text := strings.Join(chunks, "")
	messageItem := map[string]any{"type": "message", "id": message, "status": "completed", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text, "annotations": []any{}}}}
	send("response.output_text.done", map[string]any{"type": "response.output_text.done", "item_id": message, "output_index": 1, "content_index": 0, "text": text})
	send("response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": 1, "item": messageItem})
	output := []any{reasoningItem, messageItem}
	if strings.Contains(prompt, "MEMORY:") && !request.afterTool {
		call := map[string]any{"type": "function_call", "id": fmt.Sprintf("fc_%d", n), "call_id": fmt.Sprintf("call_%d", n), "name": "memory_save", "namespace": "mcp__agentland", "arguments": `{"text":"Prefers metric units"}`, "status": "completed"}
		send("response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": 2, "item": call})
		send("response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": 2, "item": call})
		output = append(output, call)
	}
	if strings.Contains(prompt, "RUN") && !request.afterTool {
		arguments, _ := json.Marshal(map[string]any{"cmd": "touch agentland-contract.txt", "sandbox_permissions": "require_escalated", "justification": "The contract test needs one approval"})
		call := map[string]any{"type": "function_call", "id": fmt.Sprintf("fc_%d", n), "call_id": fmt.Sprintf("call_%d", n), "name": "exec_command", "arguments": string(arguments), "status": "completed"}
		send("response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": 2, "item": call})
		send("response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": 2, "item": call})
		output = append(output, call)
	}
	usage := map[string]any{"input_tokens": 120, "input_tokens_details": map[string]any{"cached_tokens": 20}, "output_tokens": 30, "output_tokens_details": map[string]any{"reasoning_tokens": 5}, "total_tokens": 150}
	send("response.completed", map[string]any{"type": "response.completed", "response": map[string]any{"id": response, "status": "completed", "output": output, "usage": usage}})
}
