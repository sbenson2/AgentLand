package host

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestClaudeContract runs the installed claude through the host against a
// local fake of the Anthropic Messages API: no model credits, a throwaway
// HOME and CLAUDE_CONFIG_DIR, a fake API key, and an environment that holds
// nothing of the owner's. Opt in with AGENTLAND_TEST_CLAUDE=1.
func TestClaudeContract(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_CLAUDE") != "1" {
		t.Skip("set AGENTLAND_TEST_CLAUDE=1 to run the installed claude against a local fake model API (no credits)")
	}
	binary, ok := executableForProgram("claude")
	if !ok {
		t.Fatal("claude is not installed")
	}
	root := t.TempDir()
	home, config, tmp, project := filepath.Join(root, "home"), filepath.Join(root, "config"), filepath.Join(root, "tmp"), filepath.Join(root, "project")
	for _, directory := range []string{home, config, tmp, project} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	api := newFakeAnthropic(t, project)
	var traceMu sync.Mutex
	var spawns [][]string
	var lines []string
	engine := claudeConfig{
		executable: func() (string, bool) { return binary, true },
		baseEnv:    []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + home, "TMPDIR=" + tmp, "LANG=en_US.UTF-8"},
		env:        []string{"CLAUDE_CONFIG_DIR=" + config, "ANTHROPIC_BASE_URL=" + api.server.URL, "ANTHROPIC_API_KEY=fake-key", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "DISABLE_TELEMETRY=1", "DISABLE_AUTOUPDATER=1", "DISABLE_ERROR_REPORTING=1"},
		// The fake key is an API key: chats would end on it otherwise.
		apiKeyAllowed: true,
		onSpawn: func(args []string) {
			traceMu.Lock()
			spawns = append(spawns, append([]string(nil), args...))
			traceMu.Unlock()
		},
		trace: func(direction string, line []byte) {
			traceMu.Lock()
			lines = append(lines, direction+" "+string(line))
			traceMu.Unlock()
		},
	}
	f := newClaudeHost(t, engine, project)
	t.Logf("claude %s (%s)", f.chats.claude.version(), binary)
	lastSpawn := func() []string {
		traceMu.Lock()
		defer traceMu.Unlock()
		return spawns[len(spawns)-1]
	}
	evidence := func(match string) string {
		traceMu.Lock()
		defer traceMu.Unlock()
		for index := len(lines) - 1; index >= 0; index-- {
			if strings.Contains(lines[index], match) {
				if len(lines[index]) > 600 {
					return lines[index][:600] + "…"
				}
				return lines[index]
			}
		}
		return ""
	}
	id := f.newChat()
	stream := f.stream(id)
	client := newClientChat(t)
	applyAll(client, stream.until(t, "snapshot", 10*time.Second))

	// 1. Streamed thinking, text and a tool that waits for an approval.
	first := f.mustSend(id, "TOOL: create a file", map[string]any{"mode": "default"})
	t.Logf("spawn: claude %s", strings.Join(lastSpawn(), " "))
	t.Logf("initialize: %s", evidence(`"models"`))
	events := stream.until(t, "interaction.requested", 60*time.Second)
	asked := events[len(events)-1].Interaction
	if asked.Kind != "permission" || asked.Permission.Tool != "Bash" {
		t.Fatalf("approval: %s", events[len(events)-1].raw)
	}
	t.Logf("can_use_tool: %s", evidence(`"can_use_tool"`))
	t.Logf("interaction: %s", events[len(events)-1].raw)
	if strings.Join(asked.Choices, ",") != "once,always,reject" {
		t.Fatalf("choices: %v", asked.Choices)
	}
	// What always grants, from the suggestions Claude Code sent.
	if !strings.HasPrefix(asked.AlwaysLabel, "Allow Bash(touch made-by-contract.txt) in this project") || !strings.HasPrefix(asked.AlwaysDetail, "Saved in this project's .claude/settings.local.json.") {
		t.Fatalf("always label: %q / %q", asked.AlwaysLabel, asked.AlwaysDetail)
	}
	t.Logf("alwaysLabel: %q; alwaysDetail: %q", asked.AlwaysLabel, asked.AlwaysDetail)
	// Always passes Claude's suggestions back; one of them switches the
	// session to acceptEdits, which the chat then shows.
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": asked.ID, "reply": "always"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	rest := stream.until(t, "turn.finished", 60*time.Second)
	applyAll(client, append(events, rest...))
	labels := trace(append(events, rest...))
	claudeInOrder(t, labels, "message.created:user", "turn.started", "message.created:assistant", "part.created:reasoning", "part.created:text", "part.created:tool:pending", "interaction.requested", "interaction.resolved:always", "part.updated:tool:completed", "turn.finished:completed")
	mode := ""
	for _, event := range rest {
		if event.Type == "chat.updated" {
			var update struct{ Mode string }
			json.Unmarshal([]byte(event.raw), &update)
			if update.Mode != "" {
				mode = update.Mode
			}
		}
	}
	if mode != "acceptEdits" {
		t.Fatalf("mode after always: %q", mode)
	}
	t.Logf("always: %s; chat mode now %s", evidence(`"updatedPermissions"`), mode)
	t.Logf("stream (turn 1): %s", strings.Join(labels, " "))
	if _, err := os.Stat(filepath.Join(project, "made-by-contract.txt")); err != nil {
		t.Fatalf("the approved tool did not run: %v", err)
	}
	messages := client.ordered()
	if last := messages[len(messages)-1]; !strings.Contains(last.Parts[len(last.Parts)-1].Text, "Tool finished") || messages[0].ID != first.MessageID {
		t.Fatalf("turn 1: %s", marshalJSONLine(messages))
	}
	t.Logf("delivery: user frame uuid %s replayed as %s", first.MessageID, evidence(`"isReplay":true`))
	t.Logf("result: %s", evidence(`"type":"result"`))

	// 2. AskUserQuestion answered through the host.
	f.mustSend(id, "ASK: pick for me", nil)
	events = stream.until(t, "interaction.requested", 60*time.Second)
	asked = events[len(events)-1].Interaction
	if asked.Kind != "question" || len(asked.Questions) != 2 || !asked.Questions[1].Multiple {
		t.Fatalf("question: %s", events[len(events)-1].raw)
	}
	if w := f.call("POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": id, "requestId": asked.ID, "answers": [][]string{{"Blue"}, {"S", "L"}}}); w.Code != 200 {
		t.Fatalf("answer: %d %s", w.Code, w.Body)
	}
	stream.until(t, "turn.finished", 60*time.Second)
	if result := api.lastResult(); !strings.Contains(result, `"Which color?"="Blue"`) || !strings.Contains(result, `"Which sizes?"="S, L"`) {
		t.Fatalf("the CLI did not take the answers: %q", result)
	}
	t.Logf("AskUserQuestion answer reached the model as: %s", api.lastResult())

	// 3. Stop.
	f.mustSend(id, "SLOW: count", nil)
	stream.until(t, "part.delta", 60*time.Second)
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("abort: %d %s", w.Code, w.Body)
	}
	rest = stream.until(t, "turn.finished", 60*time.Second)
	if outcome := rest[len(rest)-1].Outcome; outcome != "aborted" {
		t.Fatalf("interrupt outcome: %s", rest[len(rest)-1].raw)
	}
	t.Logf("interrupt: %s / %s", evidence(`"subtype":"interrupt"`), rest[len(rest)-1].raw)

	// 4. set_model on the running process.
	plain := f.mustSend(id, "plain after a model switch", map[string]any{"model": "claude/sonnet"})
	stream.until(t, "turn.finished", 60*time.Second)
	if model := api.lastMainModel(); !strings.Contains(model, "sonnet") {
		t.Fatalf("model after set_model: %q", model)
	}
	t.Logf("set_model: %s; next request model %s", evidence(`"subtype":"set_model"`), api.lastMainModel())
	// A plain turn is one model request with the fake's fixed usage, so every
	// plain turn below costs the same. total_cost_usd is the session's, and a
	// resumed process reports what the session spent before; the first turn
	// after each restart must still cost one plain turn (claude_cost.go).
	f.waitIdle(id)
	plainCost := f.turnCost(id, plain.MessageID)
	if plainCost <= 0 {
		t.Fatalf("plain turn cost %d", plainCost)
	}
	sameAsPlain := func(label, chat, turn string) {
		t.Helper()
		f.waitIdle(chat)
		cost := f.turnCost(chat, turn)
		_, _, total := f.costRecord(chat)
		if cost != plainCost {
			t.Fatalf("%s: turn cost %d µ$, want one plain turn's %d (the session's total is now $%v)", label, cost, plainCost, total)
		}
		t.Logf("cost: %s %d µ$ (one plain turn), while total_cost_usd reports $%v", label, cost, total)
	}

	// 4a. Bypass permissions on the running process: the start's
	// --allow-dangerously-skip-permissions lets set_permission_mode enter it.
	if !strings.Contains(strings.Join(lastSpawn(), " "), "--allow-dangerously-skip-permissions --permission-mode default") {
		t.Fatalf("start: %v", lastSpawn())
	}
	f.mustSend(id, "plain in bypass", map[string]any{"mode": "bypassPermissions"})
	stream.until(t, "turn.finished", 60*time.Second)
	f.waitIdle(id)
	if mode := f.chatMode(id); mode != "bypassPermissions" {
		t.Fatalf("mode after set_permission_mode bypassPermissions: %q (%s)", mode, evidence(`"subtype":"set_permission_mode"`))
	}
	t.Logf("bypass: %s; then %s", evidence(`"mode":"bypassPermissions"`), evidence(`"permissionMode":"bypassPermissions"`))

	// 4b. Plan mode: ExitPlanMode asks with the plan; approving it leaves plan
	// mode.
	f.mustSend(id, "PLAN: outline it", map[string]any{"mode": "plan"})
	events = stream.until(t, "interaction.requested", 60*time.Second)
	asked = events[len(events)-1].Interaction
	if asked.Permission == nil || asked.Permission.Tool != "ExitPlanMode" || !strings.Contains(asked.Permission.Detail, "1. Outline") {
		t.Fatalf("plan approval: %s (asked: %s)", events[len(events)-1].raw, evidence(`"tool_name":"ExitPlanMode"`))
	}
	t.Logf("set_permission_mode: %s", evidence(`"subtype":"set_permission_mode"`))
	t.Logf("ExitPlanMode: %s", events[len(events)-1].raw)
	f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": asked.ID, "reply": "once"})
	stream.until(t, "turn.finished", 60*time.Second)
	f.waitIdle(id)
	if chat := f.chatState(id); chat.activity() != "idle" || f.chatMode(id) == "plan" {
		t.Fatalf("mode after leaving plan mode: %s", f.chatMode(id))
	}
	t.Logf("mode after the plan was approved: %s (%s)", f.chatMode(id), evidence(`"permissionMode"`))

	// 4c. A new effort restarts the process with --effort and resumes.
	lessEffort := f.mustSend(id, "plain with less effort", map[string]any{"effort": "low"})
	stream.until(t, "turn.finished", 60*time.Second)
	if argValue(lastSpawn(), "--effort") != "low" || argValue(lastSpawn(), "--resume") == "" {
		t.Fatalf("effort restart: %v", lastSpawn())
	}
	t.Logf("spawn: claude %s", strings.Join(lastSpawn(), " "))
	sameAsPlain("first turn after the effort restart", id, lessEffort.MessageID)

	// 5. A write, a rewind and the next send: files come back, the turn is
	// dropped from Claude's transcript.
	written := filepath.Join(project, "written-by-contract.txt")
	f.mustSend(id, "WRITE: "+written, map[string]any{"mode": "default"})
	events = stream.until(t, "interaction.requested", 60*time.Second)
	f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": events[len(events)-1].Interaction.ID, "reply": "once"})
	stream.until(t, "turn.finished", 60*time.Second)
	if _, err := os.Stat(written); err != nil {
		t.Fatalf("the write did not happen: %v", err)
	}
	f.waitIdle(id)
	chat := f.chatState(id)
	chat.mu.Lock()
	latest, _ := chat.latestUserLocked()
	chat.mu.Unlock()
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": latest.ID}); w.Code != 200 {
		t.Fatalf("rewind: %d %s", w.Code, w.Body)
	}
	afterRewind := f.mustSend(id, "after the rewind", nil)
	stream.until(t, "turn.finished", 60*time.Second)
	sameAsPlain("first turn after the truncating resume", id, afterRewind.MessageID)
	t.Logf("rewind_files dry run: %s", evidence(`"canRewind"`))
	t.Logf("spawn: claude %s", strings.Join(lastSpawn(), " "))
	if argValue(lastSpawn(), "--resume-drops-turn") != latest.ID || argValue(lastSpawn(), "--resume-session-at") == "" {
		t.Fatalf("truncating resume: %v", lastSpawn())
	}
	if _, err := os.Stat(written); err == nil {
		t.Fatal("rewind_files left the written file")
	}
	if prompts := api.lastMainPrompts(); strings.Contains(strings.Join(prompts, "|"), "WRITE:") || !strings.Contains(strings.Join(prompts, "|"), "TOOL: create a file") {
		t.Fatalf("history after the truncating resume: %q", prompts)
	}
	t.Logf("history the model saw after the rewind: %q", api.lastMainPrompts())

	// 6. Fork at the first turn.
	var page struct{ Messages []ChatMessage }
	json.Unmarshal(f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=50", nil).Body.Bytes(), &page)
	var firstReply string
	for index := len(page.Messages) - 1; index >= 0 && firstReply == ""; index-- {
		if page.Messages[index].Role == "assistant" {
			firstReply = page.Messages[index].ID
		}
	}
	w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "messageId": firstReply, "title": "Fork"})
	var forked Session
	json.Unmarshal(w.Body.Bytes(), &forked)
	if w.Code != 201 || forked.ParentSessionID != id {
		t.Fatalf("fork: %d %s", w.Code, w.Body)
	}
	inFork := f.mustSend(forked.ID, "in the fork", nil)
	f.waitIdle(forked.ID)
	t.Logf("spawn: claude %s", strings.Join(lastSpawn(), " "))
	sameAsPlain("first turn of the fork", forked.ID, inFork.MessageID)
	if prompts := strings.Join(api.lastMainPrompts(), "|"); prompts != "TOOL: create a file|in the fork" {
		t.Fatalf("history in the fork: %q", prompts)
	}
	source, _ := f.chats.claudeEntry(f.project, id)
	fork, _ := f.chats.claudeEntry(f.project, forked.ID)
	if fork.native == "" || fork.native == source.native {
		t.Fatalf("fork session %q from %q", fork.native, source.native)
	}
	t.Logf("fork: new session %s from system/init (source %s)", fork.native, source.native)

	// 6b. Regenerate drops the latest turn and sends its prompt again.
	w = f.call("POST", "/v1/chat/regenerate", map[string]any{"projectId": "p1", "sessionId": id})
	if w.Code != 202 {
		t.Fatalf("regenerate: %d %s", w.Code, w.Body)
	}
	f.waitIdle(id)
	if prompts := strings.Join(api.lastMainPrompts(), "|"); strings.Count(prompts, "after the rewind") != 1 || argValue(lastSpawn(), "--resume-drops-turn") == "" {
		t.Fatalf("regenerate: %q %v", prompts, lastSpawn())
	}
	t.Logf("regenerate spawn: claude %s", strings.Join(lastSpawn(), " "))

	// 7. Claude Code refuses a truncation that would drop another turn's
	// entries; nothing is sent and the host says so.
	chat.mu.Lock()
	chat.rec.Turns[len(chat.rec.Turns)-1].Before = chat.rec.Turns[0].Prompt
	target := chat.rec.Turns[len(chat.rec.Turns)-1].Prompt
	chat.mu.Unlock()
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": target}); w.Code != 200 {
		t.Fatalf("rewind: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(id, "refused", nil); w.Code != 409 || errorCode(t, w) != "rewind_refused" {
		t.Fatalf("refused truncation: %d %s", w.Code, w.Body)
	}
	t.Logf("refused truncation: %s", evidence("Resume rejected"))

	// 8. Models for a new chat, from initialize.
	options := f.call("GET", "/v1/chat/options?projectId=p1&provider=claude", nil).Body.String()
	if !strings.Contains(options, `"id":"claude/default"`) || !strings.Contains(options, `"efforts":[`) {
		t.Fatalf("options: %s", options)
	}
	t.Logf("options: %s", options)

	t.Logf("fake API saw %d requests; other paths: %v", api.count(), api.otherPaths())
}

// fakeAnthropic answers the Messages API the way the contract check needs:
// words in the newest prompt pick the reply.
type fakeAnthropic struct {
	t       *testing.T
	project string
	server  *httptest.Server
	mu      sync.Mutex
	counter int
	wire    []map[string]any
	main    []fakeAnthropicRequest
	others  []string
}

type fakeAnthropicRequest struct {
	model   string
	prompts []string
	result  string
}

func newFakeAnthropic(t *testing.T, project string) *fakeAnthropic {
	f := &fakeAnthropic{t: t, project: project}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeAnthropic) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.counter
}

func (f *fakeAnthropic) otherPaths() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.others...)
}

func (f *fakeAnthropic) lastMain() fakeAnthropicRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.main) == 0 {
		return fakeAnthropicRequest{}
	}
	return f.main[len(f.main)-1]
}

func (f *fakeAnthropic) lastMainModel() string     { return f.lastMain().model }
func (f *fakeAnthropic) lastMainPrompts() []string { return f.lastMain().prompts }

func (f *fakeAnthropic) lastResult() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	for index := len(f.main) - 1; index >= 0; index-- {
		if f.main[index].result != "" {
			return f.main[index].result
		}
	}
	return ""
}

type fakeAnthropicMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

func fakeTexts(message fakeAnthropicMessage) ([]string, []string) {
	var text string
	if json.Unmarshal(message.Content, &text) == nil {
		return []string{text}, nil
	}
	var blocks []struct {
		Type    string          `json:"type"`
		Text    string          `json:"text"`
		Content json.RawMessage `json:"content"`
	}
	json.Unmarshal(message.Content, &blocks)
	texts, results := []string{}, []string{}
	for _, block := range blocks {
		switch block.Type {
		case "text":
			texts = append(texts, block.Text)
		case "tool_result":
			var result string
			if json.Unmarshal(block.Content, &result) != nil {
				var parts []struct{ Text string }
				json.Unmarshal(block.Content, &parts)
				for _, part := range parts {
					result += part.Text
				}
			}
			results = append(results, result)
		}
	}
	return texts, results
}

func (f *fakeAnthropic) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	f.mu.Lock()
	f.counter++
	number := f.counter
	f.mu.Unlock()
	switch {
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/messages/count_tokens"):
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"input_tokens":12}`))
		return
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/messages"):
	default:
		f.mu.Lock()
		f.others = append(f.others, r.Method+" "+r.URL.Path)
		f.mu.Unlock()
		if r.Method == "HEAD" {
			w.WriteHeader(200)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(404)
		w.Write([]byte(`{"type":"error","error":{"type":"not_found_error","message":"not found"}}`))
		return
	}
	var request struct {
		Model    string                 `json:"model"`
		Stream   bool                   `json:"stream"`
		Messages []fakeAnthropicMessage `json:"messages"`
		Tools    []json.RawMessage      `json:"tools"`
	}
	json.Unmarshal(body, &request)
	var wire map[string]any
	json.Unmarshal(body, &wire)
	f.mu.Lock()
	f.wire = append(f.wire, wire)
	f.mu.Unlock()
	main := len(request.Tools) > 5
	prompts, prompt, results := []string{}, "", []string{}
	for index, message := range request.Messages {
		if message.Role != "user" {
			continue
		}
		texts, toolResults := fakeTexts(message)
		for _, text := range texts {
			if !strings.HasPrefix(strings.TrimSpace(text), "<") && strings.TrimSpace(text) != "" && !strings.HasPrefix(text, "[Request interrupted") {
				prompts = append(prompts, text)
				if len(toolResults) == 0 {
					prompt = text
				}
			}
		}
		if index == len(request.Messages)-1 || f.lastUserIndex(request.Messages) == index {
			results = toolResults
		}
	}
	if main {
		f.mu.Lock()
		f.main = append(f.main, fakeAnthropicRequest{model: request.Model, prompts: prompts, result: strings.Join(results, "\n")})
		f.mu.Unlock()
	}
	if !request.Stream {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":"msg_side_%d","type":"message","role":"assistant","model":%q,"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":2}}`, number, request.Model)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(200)
	flusher, _ := w.(http.Flusher)
	send := func(event, data string) bool {
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	send("message_start", fmt.Sprintf(`{"type":"message_start","message":{"id":"msg_contract_%d","type":"message","role":"assistant","model":%q,"content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":7,"cache_creation_input_tokens":3}}}`, number, request.Model))
	index := 0
	text := func(pieces ...string) {
		send("content_block_start", fmt.Sprintf(`{"type":"content_block_start","index":%d,"content_block":{"type":"text","text":""}}`, index))
		for _, piece := range pieces {
			data, _ := json.Marshal(piece)
			if !send("content_block_delta", fmt.Sprintf(`{"type":"content_block_delta","index":%d,"delta":{"type":"text_delta","text":%s}}`, index, data)) {
				return
			}
			if strings.Contains(prompt, "SLOW") {
				time.Sleep(100 * time.Millisecond)
			}
		}
		send("content_block_stop", fmt.Sprintf(`{"type":"content_block_stop","index":%d}`, index))
		index++
	}
	tool := func(name string, input any) {
		send("content_block_start", fmt.Sprintf(`{"type":"content_block_start","index":%d,"content_block":{"type":"tool_use","id":"toolu_contract_%d_%d","name":%q,"input":{}}}`, index, number, index, name))
		data, _ := json.Marshal(input)
		half := len(data) / 2
		first, _ := json.Marshal(string(data[:half]))
		second, _ := json.Marshal(string(data[half:]))
		send("content_block_delta", fmt.Sprintf(`{"type":"content_block_delta","index":%d,"delta":{"type":"input_json_delta","partial_json":%s}}`, index, first))
		send("content_block_delta", fmt.Sprintf(`{"type":"content_block_delta","index":%d,"delta":{"type":"input_json_delta","partial_json":%s}}`, index, second))
		send("content_block_stop", fmt.Sprintf(`{"type":"content_block_stop","index":%d}`, index))
		index++
	}
	stop := "end_turn"
	switch {
	case strings.Contains(prompt, "MEMORY:") && len(results) == 0:
		tool("mcp__agentland__memory_save", map[string]string{"text": "Prefers metric units"})
		stop = "tool_use"
	case !main:
		text("Side reply")
	case len(results) > 0:
		text("Tool finished: ", strings.Join(results, " "))
	case strings.Contains(prompt, "TOOL"):
		send("content_block_start", `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`)
		send("content_block_delta", `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Planning the tool call."}}`)
		send("content_block_delta", `{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2ln"}}`)
		send("content_block_stop", `{"type":"content_block_stop","index":0}`)
		index++
		text("Running a tool.")
		tool("Bash", map[string]string{"command": "touch made-by-contract.txt", "description": "Create a file"})
		stop = "tool_use"
	case strings.Contains(prompt, "ASK"):
		text("I have a question.")
		tool("AskUserQuestion", map[string]any{"questions": []any{
			map[string]any{"question": "Which color?", "header": "Color", "options": []any{map[string]string{"label": "Red", "description": "Warm"}, map[string]string{"label": "Blue", "description": "Cool"}}, "multiSelect": false},
			map[string]any{"question": "Which sizes?", "header": "Sizes", "options": []any{map[string]string{"label": "S", "description": "small"}, map[string]string{"label": "L", "description": "large"}}, "multiSelect": true},
		}})
		stop = "tool_use"
	case strings.Contains(prompt, "PLAN"):
		text("Here is the plan.")
		tool("ExitPlanMode", map[string]string{"plan": "1. Outline the change\n2. Make it"})
		stop = "tool_use"
	case strings.Contains(prompt, "WRITE: "):
		text("Writing a file.")
		tool("Write", map[string]string{"file_path": strings.TrimSpace(strings.TrimPrefix(prompt, "WRITE: ")), "content": "written by the fake model\n"})
		stop = "tool_use"
	case strings.Contains(prompt, "SLOW"):
		pieces := make([]string, 60)
		for index := range pieces {
			pieces[index] = "tick "
		}
		text(pieces...)
	default:
		text("Echo: ", prompt)
	}
	send("message_delta", fmt.Sprintf(`{"type":"message_delta","delta":{"stop_reason":%q,"stop_sequence":null},"usage":{"output_tokens":42}}`, stop))
	send("message_stop", `{"type":"message_stop"}`)
}

func (f *fakeAnthropic) lastUserIndex(messages []fakeAnthropicMessage) int {
	for index := len(messages) - 1; index >= 0; index-- {
		if messages[index].Role == "user" || messages[index].Role == "assistant" {
			if messages[index].Role == "user" {
				return index
			}
			return -1
		}
	}
	return -1
}
