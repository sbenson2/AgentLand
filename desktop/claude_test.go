package host

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

var claudeBaseArgs = []string{"-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio", "--allow-dangerously-skip-permissions"}

func claudeArgs(extra ...string) []string {
	return append(append([]string{}, claudeBaseArgs...), extra...)
}

func argValue(args []string, flag string) string {
	for index, arg := range args {
		if arg == flag && index+1 < len(args) {
			return args[index+1]
		}
	}
	return ""
}

func sameArgs(t *testing.T, label string, got, want []string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s argv:\n got: %q\nwant: %q", label, got, want)
	}
}

// trace labels stream events for order checks.
func trace(events []streamEvent) []string {
	labels := []string{}
	for _, event := range events {
		label := event.Type
		switch event.Type {
		case "message.created":
			label += ":" + event.Message.Role
		case "part.created", "part.updated":
			label += ":" + event.Part.Kind
			if event.Part.Tool != nil {
				label += ":" + event.Part.Tool.Status
			}
		case "interaction.resolved":
			label += ":" + event.Outcome
		case "turn.finished":
			label += ":" + event.Outcome
		case "status":
			label += ":" + event.State
		}
		labels = append(labels, label)
	}
	return labels
}

// inOrder checks that want appears in got in order, other labels between.
func claudeInOrder(t *testing.T, got []string, want ...string) {
	t.Helper()
	next := 0
	for _, label := range got {
		if next < len(want) && label == want[next] {
			next++
		}
	}
	if next < len(want) {
		t.Fatalf("missing %q in order;\n got: %v", want[next], got)
	}
}

func applyAll(client *clientChat, events []streamEvent) {
	for _, event := range events {
		client.apply(event)
	}
}

func (f *claudeFixture) chatState(id string) *claudeChat {
	f.t.Helper()
	chat, err := f.chats.claude.chat(f.project, id)
	if err != nil {
		f.t.Fatal(err)
	}
	return chat
}

func (f *claudeFixture) chatMode(id string) string {
	chat := f.chatState(id)
	chat.mu.Lock()
	defer chat.mu.Unlock()
	return chat.rec.Mode
}

func (f *claudeFixture) live(id string) bool {
	chat := f.chatState(id)
	chat.mu.Lock()
	defer chat.mu.Unlock()
	return chat.proc != nil
}

func TestClaudeLaunchArguments(t *testing.T) {
	for _, item := range []struct {
		launch claudeLaunch
		want   []string
	}{
		{claudeLaunch{settings: claudeSettings{mode: "auto"}, session: "S"}, claudeArgs("--permission-mode", "auto", "--session-id", "S")},
		{claudeLaunch{settings: claudeSettings{mode: "plan", model: "sonnet", effort: "high"}, resume: "S"}, claudeArgs("--permission-mode", "plan", "--model", "sonnet", "--effort", "high", "--resume", "S")},
		{claudeLaunch{settings: claudeSettings{mode: "auto"}, resume: "S", at: "U", drops: "P"}, claudeArgs("--permission-mode", "auto", "--resume", "S", "--resume-session-at", "U", "--resume-drops-turn", "P")},
		{claudeLaunch{settings: claudeSettings{mode: "default"}, resume: "S", at: "U", fork: true, addDir: "/tmp/files"}, claudeArgs("--permission-mode", "default", "--resume", "S", "--resume-session-at", "U", "--fork-session", "--add-dir", "/tmp/files")},
		{claudeLaunch{settings: claudeSettings{mode: "dontAsk", effort: "low"}, session: "S"}, claudeArgs("--permission-mode", "dontAsk", "--effort", "low", "--session-id", "S")},
		{claudeLaunch{settings: claudeSettings{mode: "bypassPermissions"}, session: "S"}, claudeArgs("--permission-mode", "bypassPermissions", "--session-id", "S")},
	} {
		sameArgs(t, "launch", item.launch.args(), item.want)
	}
}

// A turn streams thinking, text and a tool in the order Claude emitted them,
// waits for an approval, completes the tool and reports cost and usage.
func TestClaudeStreamsATurnInOrder(t *testing.T) {
	f := newClaudeFixture(t, nil)
	input := `{"command":"touch x","description":"Create x"}`
	suggestions := `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch x"}],"behavior":"allow","destination":"localSettings"}]`
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		systemInit(),
		messageStart("msg_1"),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think."}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2ln"}}`),
		claudeEvent(`{"type":"content_block_stop","index":0}`),
		assistantBlock("msg_1", "", `{"type":"thinking","thinking":"Let me think.","signature":"c2ln"}`, ""),
		claudeEvent(`{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"I will "}}`),
		claudeEvent(`{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"run a tool."}}`),
		claudeEvent(`{"type":"content_block_stop","index":1}`),
		assistantBlock("msg_1", "", `{"type":"text","text":"I will run a tool."}`, ""),
		claudeEvent(`{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}`),
		claudeEvent(`{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"touch x\""}}`),
		claudeEvent(`{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":", \"description\": \"Create x\"}"}}`),
		claudeEvent(`{"type":"content_block_stop","index":2}`),
		assistantBlock("msg_1", "", `{"type":"tool_use","id":"toolu_1","name":"Bash","input":`+input+`}`, ""),
		claudeEvent(`{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}`),
		claudeEvent(`{"type":"message_stop"}`),
		emit(`{"type":"system","subtype":"session_state_changed","state":"requires_action","session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
		step(map[string]any{"do": "ask", "id": "perm-1", "request": json.RawMessage(`{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":` + input + `,"description":"Create x","permission_suggestions":` + suggestions + `,"blocked_path":"/tmp/x","tool_use_id":"toolu_1"}`)}),
		step(map[string]any{"do": "await", "id": "perm-1"}),
		emit(`{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"created","is_error":false}]},"parent_tool_use_id":null,"session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
		textReply("msg_2", "Done.", ""),
		resultLine("success", false, 0.0025, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	client := newClientChat(t)
	applyAll(client, stream.until(t, "snapshot", 5*time.Second))
	receipt := f.mustSend(id, "Please create x", map[string]any{"clientMessageId": strings.Repeat("a", 32)})
	if !claudeUUIDPattern.MatchString(receipt.MessageID) || receipt.TurnID != receipt.MessageID {
		t.Fatalf("receipt: %+v", receipt)
	}
	events := stream.until(t, "interaction.requested", 10*time.Second)
	applyAll(client, events)
	asked := events[len(events)-1].Interaction
	if asked.Kind != "permission" || asked.ID != "perm-1" || strings.Join(asked.Choices, ",") != "once,always,reject" || asked.Permission.Tool != "Bash" || asked.Permission.Title != "Create x" || asked.Permission.Detail != "Path: /tmp/x" || asked.Permission.Input != input {
		t.Fatalf("interaction: %s", events[len(events)-1].raw)
	}
	var listed struct {
		Permissions []PermissionRequest
		Questions   []QuestionRequest
	}
	json.Unmarshal(f.call("GET", "/v1/interactions?projectId=p1&sessionId="+id, nil).Body.Bytes(), &listed)
	if len(listed.Permissions) != 1 || listed.Permissions[0].ID != "perm-1" || listed.Permissions[0].Permission != "Bash" || len(listed.Questions) != 0 {
		t.Fatalf("GET /v1/interactions: %+v", listed)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "perm-1", "reply": "once"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	rest := stream.until(t, "turn.finished", 10*time.Second)
	applyAll(client, rest)
	all := append(events, rest...)
	claudeInOrder(t, trace(all), "message.created:user", "turn.started", "status:running", "message.created:assistant", "part.created:reasoning", "part.created:text", "part.created:tool:pending", "part.updated:tool:running", "interaction.requested", "status:waiting", "interaction.resolved:once", "status:running", "part.updated:tool:completed", "message.created:assistant", "status:idle", "turn.finished:completed")
	finished := rest[len(rest)-1]
	if finished.TurnID != receipt.MessageID || finished.Usage == nil || finished.Usage.Input != 200 || finished.Usage.Output != 84 || finished.Usage.CostMicros == nil || *finished.Usage.CostMicros != 2500 {
		t.Fatalf("turn.finished: %s", finished.raw)
	}
	messages := client.ordered()
	if len(messages) != 3 || messages[0].ID != receipt.MessageID || messages[0].Parts[0].Text != "Please create x" {
		t.Fatalf("messages: %s", marshalJSONLine(messages))
	}
	reply := messages[1]
	kinds := []string{}
	for _, part := range reply.Parts {
		kinds = append(kinds, part.Kind+":"+strconv.FormatInt(part.Ord, 10))
	}
	tool := reply.Parts[2].Tool
	if strings.Join(kinds, ",") != "reasoning:1,text:2,tool:3" || reply.Parts[0].Text != "Let me think." || reply.Parts[1].Text != "I will run a tool." || tool.Status != "completed" || tool.Output != "created" || tool.Input != input || tool.CallID != "toolu_1" || tool.Title != "Create x" {
		t.Fatalf("reply parts: %s", marshalJSONLine(reply))
	}
	if reply.Status != "complete" || reply.Model != "claude/claude-opus-5-5" || reply.Usage.Input != 100 || reply.Usage.Output != 42 || reply.Usage.CacheRead != 7 || reply.Usage.CacheWrite != 3 || messages[2].Parts[0].Text != "Done." {
		t.Fatalf("reply: %s", marshalJSONLine(messages))
	}
	sameMessages(t, client.ordered(), hubMessages(f.host, sessionKey{"p1", id}))
	// The CLI got the original input back, and the prompt carried the
	// receipt's uuid.
	answer := f.response(1, "perm-1")
	body, _ := json.Marshal(answer["response"])
	if answer["subtype"] != "success" || string(body) != `{"behavior":"allow","updatedInput":{"command":"touch x","description":"Create x"}}` {
		t.Fatalf("permission answer: %v", answer)
	}
	users := 0
	for _, frame := range f.frames(1) {
		if frame["type"] == "user" {
			users++
			if frame["uuid"] != receipt.MessageID {
				t.Fatalf("prompt frame: %v", frame)
			}
		}
	}
	if users != 1 {
		t.Fatalf("prompts sent: %d", users)
	}
	// The legacy transcript keeps its shape; ?parts=1 adds the parts.
	w := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil)
	var legacy struct{ Messages []map[string]json.RawMessage }
	json.Unmarshal(w.Body.Bytes(), &legacy)
	if len(legacy.Messages) != 3 || string(legacy.Messages[1]["text"]) != `"I will run a tool."` || string(legacy.Messages[2]["text"]) != `"Done."` {
		t.Fatalf("legacy: %s", w.Body)
	}
	for _, message := range legacy.Messages {
		for key := range message {
			if !strings.Contains(" id role text tools reasoning attachments error ", " "+key+" ") {
				t.Fatalf("legacy field %q: %s", key, w.Body)
			}
		}
	}
	if !strings.Contains(string(legacy.Messages[1]["tools"]), `"name":"Bash","status":"completed","title":"Create x"`) || string(legacy.Messages[1]["reasoning"]) != `[{"text":"Let me think."}]` {
		t.Fatalf("legacy tools and reasoning: %s", w.Body)
	}
	if parts := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id+"&parts=1", nil).Body.String(); !strings.Contains(parts, `"kind":"reasoning","ord":1`) || !strings.Contains(parts, `"model":"claude/claude-opus-5-5"`) {
		t.Fatalf("parts=1: %s", parts)
	}
	page := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=2", nil)
	if !strings.Contains(page.Body.String(), `"hasMore":true`) || !strings.Contains(page.Body.String(), `"Done."`) {
		t.Fatalf("page: %s", page.Body)
	}
	// The process stayed, with the stream-json environment and no secrets.
	var started struct {
		Argv []string
		Cwd  string
		Env  map[string]string
	}
	data, _ := os.ReadFile(filepath.Join(f.dir, "argv-1.json"))
	json.Unmarshal(data, &started)
	sameArgs(t, "first start", started.Argv, claudeArgs("--permission-mode", "default", "--session-id", argValue(started.Argv, "--session-id")))
	if !claudeUUIDPattern.MatchString(argValue(started.Argv, "--session-id")) || !sameDirectory(started.Cwd, f.project.Directory) || started.Env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] != "true" || started.Env["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] != "1" || started.Env["CLAUDE_CODE_STARTUP_FAILURE_RESULTS"] != "1" {
		t.Fatalf("start: %+v", started)
	}
	if !f.live(id) {
		t.Fatal("the process stopped after the turn")
	}
}

// A prompt is delivered once the CLI replays its uuid. A process that ends
// first leaves it uncertain, and a repeat never sends it again; a process
// that never started lets the repeat send.
func TestClaudeDeliveryNeedsTheEcho(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), step(map[string]any{"do": "user"}), step(map[string]any{"do": "crash", "code": 3}))
	id := f.newChat()
	client := map[string]any{"clientMessageId": strings.Repeat("u", 40)}
	w, _ := f.send(id, "lost", client)
	if w.Code != 502 || errorCode(t, w) != "delivery_uncertain" {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(id, "lost", client); w.Code != 409 || errorCode(t, w) != "delivery_uncertain" {
		t.Fatalf("repeat: %d %s", w.Code, w.Body)
	}
	if f.started() != 1 {
		t.Fatalf("starts: %d", f.started())
	}
	if messages := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil).Body.String(); strings.Contains(messages, "lost") {
		t.Fatalf("an unconfirmed prompt is shown: %s", messages)
	}
	// A process that dies before initialize never read the prompt.
	f.script(2, step(map[string]any{"do": "crash", "code": 4}))
	f.script(3, step(map[string]any{"do": "init"}), textTurn("msg_1", "Hello", "", 0.001))
	again := map[string]any{"clientMessageId": strings.Repeat("v", 40)}
	if w, _ := f.send(id, "retry me", again); w.Code != 502 || errorCode(t, w) != "upstream_error" {
		t.Fatalf("not started: %d %s", w.Code, w.Body)
	}
	if receipt := f.mustSend(id, "retry me", again); receipt.Duplicate {
		t.Fatalf("a send that never started was treated as delivered: %+v", receipt)
	}
	for _, frame := range f.frames(2) {
		if frame["type"] == "user" {
			t.Fatal("the prompt reached a process that had not started")
		}
	}
	// The first prompt's session never held a delivered prompt: the next
	// start is a new session.
	if first, third := argValue(f.argv(1), "--session-id"), argValue(f.argv(3), "--session-id"); first == "" || third == "" || first == third {
		t.Fatalf("sessions: %q %q", first, third)
	}
}

func askLine(id, request string) map[string]any {
	return step(map[string]any{"do": "ask", "id": id, "request": json.RawMessage(request)})
}

func awaitLine(id string) map[string]any { return step(map[string]any{"do": "await", "id": id}) }

// Approvals answer allow with the original input, allow always with the
// suggested rules, or deny; always is offered only with suggestions. Plan
// approval shows the plan; a cancelled request goes away; requests AgentLand
// does not handle are refused.
func TestClaudeApprovals(t *testing.T) {
	f := newClaudeFixture(t, nil)
	suggestions := `[{"type":"setMode","mode":"acceptEdits","destination":"session"}]`
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		askLine("perm-always", `{"subtype":"can_use_tool","tool_name":"Edit","input":{"file_path":"/p/a.go","old_string":"a","new_string":"b"},"permission_suggestions":`+suggestions+`,"tool_use_id":"toolu_a"}`),
		awaitLine("perm-always"),
		askLine("perm-deny", `{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"tool_use_id":"toolu_b"}`),
		awaitLine("perm-deny"),
		askLine("plan-1", `{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"1. Add the route\n2. Test it"},"permission_suggestions":[],"tool_use_id":"toolu_c"}`),
		awaitLine("plan-1"),
		askLine("gone-1", `{"subtype":"can_use_tool","tool_name":"Read","input":{"file_path":"/p/b.go"},"tool_use_id":"toolu_d"}`),
		emit(`{"type":"control_cancel_request","request_id":"gone-1"}`),
		askLine("hook-1", `{"subtype":"hook_callback","callback_id":"x","input":{}}`),
		awaitLine("hook-1"),
		emit(`{"type":"system","subtype":"status","permissionMode":"acceptEdits","session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "Edit things", nil)
	first := stream.until(t, "interaction.requested", 10*time.Second)
	if asked := first[len(first)-1].Interaction; strings.Join(asked.Choices, ",") != "once,always,reject" || asked.Permission.Tool != "Edit" || asked.Permission.Title != "/p/a.go" || asked.AlwaysLabel != "Switch this chat to Accept edits" || asked.AlwaysDetail != "" {
		t.Fatalf("edit request: %s", first[len(first)-1].raw)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "perm-always", "reply": "always"}); w.Code != 200 {
		t.Fatalf("always: %d %s", w.Code, w.Body)
	}
	second := stream.until(t, "interaction.requested", 10*time.Second)
	if asked := second[len(second)-1].Interaction; strings.Join(asked.Choices, ",") != "once,reject" || asked.AlwaysLabel != "" {
		t.Fatalf("choices without suggestions: %s", second[len(second)-1].raw)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "perm-deny", "reply": "always"}); w.Code != 400 {
		t.Fatalf("always without suggestions: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "perm-deny", "reply": "reject"}); w.Code != 200 {
		t.Fatalf("reject: %d %s", w.Code, w.Body)
	}
	plan := stream.until(t, "interaction.requested", 10*time.Second)
	if asked := plan[len(plan)-1].Interaction; asked.Permission.Tool != "ExitPlanMode" || asked.Permission.Detail != "1. Add the route\n2. Test it" || asked.Permission.Input != "" || strings.Join(asked.Choices, ",") != "once,reject" {
		t.Fatalf("plan request: %s", plan[len(plan)-1].raw)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "plan-1", "reply": "once"}); w.Code != 200 {
		t.Fatalf("plan: %d %s", w.Code, w.Body)
	}
	rest := stream.until(t, "turn.finished", 10*time.Second)
	claudeInOrder(t, trace(rest), "interaction.requested", "interaction.resolved:gone", "turn.finished:completed")
	answer := func(id string) string {
		response := f.response(1, id)
		data, _ := json.Marshal(response)
		return string(data)
	}
	if got := answer("perm-always"); got != `{"request_id":"perm-always","response":{"behavior":"allow","updatedInput":{"file_path":"/p/a.go","new_string":"b","old_string":"a"},"updatedPermissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]},"subtype":"success"}` {
		t.Fatalf("always answer: %s", got)
	}
	if got := answer("perm-deny"); got != `{"request_id":"perm-deny","response":{"behavior":"deny","message":"The user denied this request."},"subtype":"success"}` {
		t.Fatalf("deny answer: %s", got)
	}
	if got := answer("hook-1"); !strings.Contains(got, `"subtype":"error"`) || !strings.Contains(got, "hook_callback") {
		t.Fatalf("unknown request answer: %s", got)
	}
	// The mode Claude switched to shows as the chat's mode.
	f.waitIdle(id)
	snapshot := f.stream(id).until(t, "snapshot", 5*time.Second)
	if chat := snapshot[len(snapshot)-1].Chat; chat.Mode != "acceptEdits" {
		t.Fatalf("mode: %+v", chat)
	}
}

// AskUserQuestion becomes a question; the answers go back keyed by the
// question text, several choices joined with ", ", and a rejection denies.
func TestClaudeQuestions(t *testing.T) {
	f := newClaudeFixture(t, nil)
	input := `{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}],"multiSelect":false},{"question":"Which sizes?","header":"Sizes","options":[{"label":"S","description":"small"},{"label":"L","description":"large"}],"multiSelect":true}]}`
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		askLine("q-1", `{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":`+input+`,"tool_use_id":"toolu_q","requires_user_interaction":true}`),
		awaitLine("q-1"),
		askLine("q-2", `{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Continue?","header":"Go","options":[{"label":"Yes","description":""},{"label":"No","description":""}],"multiSelect":false}]},"tool_use_id":"toolu_r"}`),
		awaitLine("q-2"),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "Ask me", nil)
	events := stream.until(t, "interaction.requested", 10*time.Second)
	asked := events[len(events)-1].Interaction
	if asked.Kind != "question" || len(asked.Questions) != 2 || asked.Questions[1].Text != "Which sizes?" || !asked.Questions[1].Multiple || !asked.Questions[0].Custom || asked.Questions[0].Options[1].Label != "Blue" || asked.Questions[0].Header != "Color" {
		t.Fatalf("question: %s", events[len(events)-1].raw)
	}
	var listed struct{ Questions []QuestionRequest }
	json.Unmarshal(f.call("GET", "/v1/interactions?projectId=p1&sessionId="+id, nil).Body.Bytes(), &listed)
	if len(listed.Questions) != 1 || listed.Questions[0].ID != "q-1" || len(listed.Questions[0].Questions) != 2 {
		t.Fatalf("GET /v1/interactions: %+v", listed)
	}
	if w := f.call("POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": id, "requestId": "q-1", "answers": [][]string{{"Blue"}}}); w.Code != 400 {
		t.Fatalf("incomplete answers: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": id, "requestId": "q-1", "answers": [][]string{{"Blue"}, {"S", "L"}}}); w.Code != 200 {
		t.Fatalf("answer: %d %s", w.Code, w.Body)
	}
	stream.until(t, "interaction.requested", 10*time.Second)
	if w := f.call("POST", "/v1/questions/reject", map[string]any{"projectId": "p1", "sessionId": id, "requestId": "q-2"}); w.Code != 200 {
		t.Fatalf("reject: %d %s", w.Code, w.Body)
	}
	rest := stream.until(t, "turn.finished", 10*time.Second)
	claudeInOrder(t, trace(rest), "interaction.resolved:rejected", "turn.finished:completed")
	answered, _ := json.Marshal(f.response(1, "q-1")["response"])
	// (The fake's log is re-encoded here, so keys come sorted.)
	if string(answered) != `{"behavior":"allow","updatedInput":{"answers":{"Which color?":"Blue","Which sizes?":"S, L"},"questions":[{"header":"Color","multiSelect":false,"options":[{"description":"Warm","label":"Red"},{"description":"Cool","label":"Blue"}],"question":"Which color?"},{"header":"Sizes","multiSelect":true,"options":[{"description":"small","label":"S"},{"description":"large","label":"L"}],"question":"Which sizes?"}]}}` {
		t.Fatalf("answers: %s", answered)
	}
	rejected, _ := json.Marshal(f.response(1, "q-2")["response"])
	if string(rejected) != `{"behavior":"deny","message":"The user declined to answer."}` {
		t.Fatalf("rejection: %s", rejected)
	}
	// Answers are not kept by the host.
	data, _ := os.ReadFile(f.store.Path + ".chats.json")
	if strings.Contains(string(data), "S, L") {
		t.Fatal("answers were stored")
	}
}

// Stop sends interrupt; the partial reply stays and shows as aborted.
func TestClaudeInterrupt(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		messageStart("msg_1"),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}`),
		step(map[string]any{"do": "control", "subtype": "interrupt", "respond": json.RawMessage(`{"still_queued":[]}`)}),
		assistantBlock("msg_1", "", `{"type":"text","text":"partial"}`, `,"aborted":true`),
		emit(`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
		emit(`{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":["[ede_diagnostic] result_type=user"],"total_cost_usd":0.001,"usage":{},"session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "Go on and on", nil)
	stream.until(t, "part.delta", 10*time.Second)
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("abort: %d %s", w.Code, w.Body)
	}
	rest := stream.until(t, "turn.finished", 10*time.Second)
	if last := rest[len(rest)-1]; last.Outcome != "aborted" {
		t.Fatalf("outcome: %s", last.raw)
	}
	messages := hubMessages(f.host, sessionKey{"p1", id})
	if len(messages) != 2 || messages[1].Status != "aborted" || messages[1].Error != nil || messages[1].Parts[0].Text != "partial" {
		t.Fatalf("messages: %s", marshalJSONLine(messages))
	}
	if strings.Join(f.controls(1), ",") != "initialize,interrupt" {
		t.Fatalf("controls: %v", f.controls(1))
	}
}

// Model and mode switch on the running process; effort restarts it with
// --effort, resuming the session.
func TestClaudeSettingsSwitch(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.001), textTurn("msg_2", "two", "", 0.002))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_3", "three", "", 0.001))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	f.mustSend(id, "second", map[string]any{"model": "claude/sonnet", "mode": "plan"})
	f.waitIdle(id)
	f.mustSend(id, "third", map[string]any{"effort": "high"})
	f.waitIdle(id)
	session := argValue(f.argv(1), "--session-id")
	sameArgs(t, "first start", f.argv(1), claudeArgs("--permission-mode", "default", "--session-id", session))
	sameArgs(t, "effort restart", f.argv(2), claudeArgs("--permission-mode", "plan", "--model", "sonnet", "--effort", "high", "--resume", session))
	frames := f.frames(1)
	order := []string{}
	for _, frame := range frames {
		switch frame["type"] {
		case "user":
			order = append(order, "user")
		case "control_request":
			request := frame["request"].(map[string]any)
			label := request["subtype"].(string)
			if model, ok := request["model"].(string); ok {
				label += "=" + model
			}
			if mode, ok := request["mode"].(string); ok {
				label += "=" + mode
			}
			order = append(order, label)
		}
	}
	if strings.Join(order, ",") != "initialize,user,set_model=sonnet,set_permission_mode=plan,user" {
		t.Fatalf("frames: %v", order)
	}
	snapshot := f.stream(id).until(t, "snapshot", 5*time.Second)
	if chat := snapshot[len(snapshot)-1].Chat; chat.Model != "claude/sonnet" || chat.Mode != "plan" || chat.Effort != "high" {
		t.Fatalf("chat: %+v", chat)
	}
	if w, _ := f.send(id, "bad", map[string]any{"mode": "manual"}); w.Code != 400 {
		t.Fatalf("unknown mode: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(id, "bad", map[string]any{"model": "claude/-x"}); w.Code != 400 {
		t.Fatalf("option-like model: %d %s", w.Code, w.Body)
	}
}

// A rewind hides the latest turn; the next send puts the files back
// (rewind_files, dry run first) and resumes without the turn.
func TestClaudeRewindThenSendResumesWithoutTheTurn(t *testing.T) {
	f := newClaudeFixture(t, nil)
	kept := newClaudeUUID()
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", kept, 0.001), textTurn("msg_2", "two", "", 0.002))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_3", "three", "", 0.001))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	second := f.mustSend(id, "second", nil)
	f.waitIdle(id)
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": "not-latest"}); w.Code != 400 {
		t.Fatalf("rewind of another message: %d %s", w.Code, w.Body)
	}
	w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": second.MessageID})
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"filesRestore":"onSend","rewound":true}` {
		t.Fatalf("rewind: %d %s", w.Code, w.Body)
	}
	rebuilt := stream.until(t, "snapshot", 5*time.Second)
	snapshot := rebuilt[len(rebuilt)-1]
	if snapshot.Rewind == nil || snapshot.Rewind.MessageID != second.MessageID || len(snapshot.Messages) != 2 {
		t.Fatalf("rewound snapshot: %s", snapshot.raw)
	}
	if legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil).Body.String(); !strings.Contains(legacy, `"rewind":{"messageId":"`+second.MessageID+`"}`) || strings.Contains(legacy, `"two"`) {
		t.Fatalf("legacy rewound: %s", legacy)
	}
	third := f.mustSend(id, "third", nil)
	f.waitIdle(id)
	session := argValue(f.argv(1), "--session-id")
	sameArgs(t, "truncating resume", f.argv(2), claudeArgs("--permission-mode", "default", "--resume", session, "--resume-session-at", kept, "--resume-drops-turn", second.MessageID))
	rewinds := []string{}
	for _, frame := range f.frames(1) {
		if request, ok := frame["request"].(map[string]any); ok && request["subtype"] == "rewind_files" {
			data, _ := json.Marshal(request)
			rewinds = append(rewinds, string(data))
		}
	}
	if len(rewinds) != 2 || rewinds[0] != `{"dry_run":true,"subtype":"rewind_files","user_message_id":"`+second.MessageID+`"}` || rewinds[1] != `{"subtype":"rewind_files","user_message_id":"`+second.MessageID+`"}` {
		t.Fatalf("rewind_files: %v", rewinds)
	}
	var page struct{ Messages []ChatMessage }
	json.Unmarshal(f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil).Body.Bytes(), &page)
	texts := []string{}
	for index := len(page.Messages) - 1; index >= 0; index-- {
		texts = append(texts, page.Messages[index].Parts[0].Text)
	}
	if strings.Join(texts, ",") != "first,one,third,three" || page.Messages[1].ID != third.MessageID {
		t.Fatalf("after the send: %v", texts)
	}
	if session, _ := f.chats.GetSession(f.project, id); session.RewindMessageID != "" {
		t.Fatalf("rewind point kept: %+v", session)
	}
}

// Dropping the first turn starts a new session; restore brings the turn back.
func TestClaudeRewindFirstTurnStartsANewSession(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "again", "", 0.001))
	id := f.newChat()
	first := f.mustSend(id, "first", nil)
	f.waitIdle(id)
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": first.MessageID}); w.Code != 200 {
		t.Fatalf("rewind: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 || !strings.Contains(w.Body.String(), `"filesRestore":"onSend"`) {
		t.Fatalf("restore: %d %s", w.Code, w.Body)
	}
	if messages := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil).Body.String(); !strings.Contains(messages, `"one"`) {
		t.Fatalf("restored: %s", messages)
	}
	f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": first.MessageID})
	f.mustSend(id, "first, edited", nil)
	f.waitIdle(id)
	old, fresh := argValue(f.argv(1), "--session-id"), argValue(f.argv(2), "--session-id")
	if fresh == "" || fresh == old {
		t.Fatalf("new session: %q after %q", fresh, old)
	}
	sameArgs(t, "fresh start", f.argv(2), claudeArgs("--permission-mode", "default", "--session-id", fresh))
	if strings.Join(f.controls(1), ",") != "initialize,rewind_files,rewind_files" {
		t.Fatalf("controls: %v", f.controls(1))
	}
}

// Regenerate drops the latest turn and sends its prompt again.
func TestClaudeRegenerate(t *testing.T) {
	f := newClaudeFixture(t, nil)
	kept := newClaudeUUID()
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", kept, 0.001), textTurn("msg_2", "two", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_3", "two again", "", 0.001))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	second := f.mustSend(id, "second", nil)
	f.waitIdle(id)
	w := f.call("POST", "/v1/chat/regenerate", map[string]any{"projectId": "p1", "sessionId": id, "effort": "low"})
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	if w.Code != 202 || receipt.MessageID == "" || receipt.MessageID == second.MessageID {
		t.Fatalf("regenerate: %d %s", w.Code, w.Body)
	}
	f.waitIdle(id)
	session := argValue(f.argv(1), "--session-id")
	sameArgs(t, "regenerate", f.argv(2), claudeArgs("--permission-mode", "default", "--effort", "low", "--resume", session, "--resume-session-at", kept, "--resume-drops-turn", second.MessageID))
	for _, frame := range f.frames(2) {
		if frame["type"] == "user" && !strings.Contains(frame["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string), "second") {
			t.Fatalf("resent prompt: %v", frame)
		}
	}
	legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil).Body.String()
	if strings.Count(legacy, `"second"`) != 1 || !strings.Contains(legacy, `"two again"`) || strings.Contains(legacy, `"two"`) {
		t.Fatalf("after regenerate: %s", legacy)
	}
	f.mustQueue(t, id)
	if w := f.call("POST", "/v1/chat/regenerate", map[string]any{"projectId": "p1", "sessionId": id}); w.Code != 409 || errorCode(t, w) != "queue_not_empty" {
		t.Fatalf("regenerate with a queue: %d %s", w.Code, w.Body)
	}
}

func (f *claudeFixture) mustQueue(t *testing.T, id string) {
	t.Helper()
	if w := f.call("POST", "/v1/queue", map[string]string{"projectId": "p1", "sessionId": id, "text": "later"}); w.Code != 201 {
		t.Fatalf("queue: %d %s", w.Code, w.Body)
	}
}

// A fork copies the chat through a turn and, on its first prompt, forks the
// Claude session there; the new session ID comes from system/init.
func TestClaudeFork(t *testing.T) {
	f := newClaudeFixture(t, nil)
	point := newClaudeUUID()
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", point, 0.001), textTurn("msg_2", "two", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_3", "forked", "", 0.001))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	f.mustSend(id, "second", nil)
	f.waitIdle(id)
	var page struct{ Messages []ChatMessage }
	json.Unmarshal(f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil).Body.Bytes(), &page)
	reply := page.Messages[2] // newest first: two, second, one, first
	w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "messageId": reply.ID, "title": "Branch"})
	var forked Session
	json.Unmarshal(w.Body.Bytes(), &forked)
	if w.Code != 201 || !isClaudeSessionID(forked.ID) || forked.ParentSessionID != id || forked.Title != "Branch" || forked.Provider != "claude" {
		t.Fatalf("fork: %d %s", w.Code, w.Body)
	}
	if legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+forked.ID, nil).Body.String(); !strings.Contains(legacy, `"one"`) || strings.Contains(legacy, `"two"`) {
		t.Fatalf("forked messages: %s", legacy)
	}
	f.mustSend(forked.ID, "in the fork", nil)
	f.waitIdle(forked.ID)
	session := argValue(f.argv(1), "--session-id")
	sameArgs(t, "fork", f.argv(2), claudeArgs("--permission-mode", "default", "--resume", session, "--resume-session-at", point, "--fork-session"))
	entry, err := f.chats.claudeEntry(f.project, forked.ID)
	if err != nil || entry.native == "" || entry.native == session {
		t.Fatalf("fork session: %q %v", entry.native, err)
	}
	if w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "messageId": "missing"}); w.Code != 404 {
		t.Fatalf("unknown fork point: %d %s", w.Code, w.Body)
	}
}

// An idle process stops after the idle time, but never while a request
// waits for the user.
func TestClaudeIdleStopWaitsForPendingRequests(t *testing.T) {
	f := newClaudeFixture(t, func(config *claudeConfig) { config.idleStop = 150 * time.Millisecond })
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		askLine("perm-1", `{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}`),
		awaitLine("perm-1"),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "list", nil)
	stream.until(t, "interaction.requested", 10*time.Second)
	time.Sleep(600 * time.Millisecond)
	if !f.live(id) {
		t.Fatal("the process stopped while a request waited")
	}
	f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "perm-1", "reply": "once"})
	stream.until(t, "turn.finished", 10*time.Second)
	waitFor(t, "the idle stop", func() bool { return !f.live(id) })
	if f.started() != 1 {
		t.Fatalf("starts: %d", f.started())
	}
}

// At the process limit the least recently used idle process stops; when
// every process works, a new chat answers 429.
func TestClaudeCapacity(t *testing.T) {
	f := newClaudeFixture(t, func(config *claudeConfig) { config.maxLive = 1 })
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "a", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), step(map[string]any{"do": "user", "echo": true}), askLine("perm-1", `{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}`), awaitLine("perm-1"))
	a, b, c := f.newChat(), f.newChat(), f.newChat()
	f.mustSend(a, "one", nil)
	f.waitIdle(a)
	f.mustSend(b, "two", nil)
	if f.live(a) || !f.live(b) {
		t.Fatalf("eviction: a=%v b=%v", f.live(a), f.live(b))
	}
	w, _ := f.send(c, "three", nil)
	if w.Code != 429 || errorCode(t, w) != "agent_capacity" {
		t.Fatalf("at capacity: %d %s", w.Code, w.Body)
	}
	if f.started() != 2 {
		t.Fatalf("starts: %d", f.started())
	}
}

// A process that dies mid-turn ends the turn with agent_exited, keeps the
// partial reply, drops pending requests, and the next send resumes.
func TestClaudeCrashMidTurn(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		messageStart("msg_1"),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}`),
		askLine("perm-1", `{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}`),
		step(map[string]any{"do": "sleep", "ms": 200}),
		step(map[string]any{"do": "crash", "code": 3}),
	)
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "back", "", 0.001))
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "work", nil)
	events := stream.until(t, "turn.finished", 10*time.Second)
	claudeInOrder(t, trace(events), "interaction.requested", "interaction.resolved:gone", "turn.finished:error")
	messages := hubMessages(f.host, sessionKey{"p1", id})
	if len(messages) != 2 || messages[1].Status != "error" || messages[1].Error.Code != "agent_exited" || messages[1].Parts[0].Text != "partial" {
		t.Fatalf("messages: %s", marshalJSONLine(messages))
	}
	f.mustSend(id, "again", nil)
	f.waitIdle(id)
	sameArgs(t, "resume after the crash", f.argv(2), claudeArgs("--permission-mode", "default", "--resume", argValue(f.argv(1), "--session-id")))
}

// A stdout line over the limit ends the turn with protocol_error; stderr is
// kept only as a bounded tail.
func TestClaudeOversizedLineAndStderrFlood(t *testing.T) {
	f := newClaudeFixture(t, func(config *claudeConfig) { config.lineLimit = 4096; config.stderrTail = 1024 })
	f.script(1, step(map[string]any{"do": "init"}), step(map[string]any{"do": "stderr", "bytes": 1 << 20}), textTurn("msg_1", "fine", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), step(map[string]any{"do": "user", "echo": true}), messageStart("msg_2"), step(map[string]any{"do": "oversized", "bytes": 10000}), step(map[string]any{"do": "hang"}))
	id := f.newChat()
	f.mustSend(id, "flood", nil)
	f.waitIdle(id)
	chat := f.chatState(id)
	chat.mu.Lock()
	kept, total := chat.proc.stderr.size()
	chat.mu.Unlock()
	if kept > 1024 || total < 1<<20 {
		t.Fatalf("stderr tail: kept %d of %d", kept, total)
	}
	chat.stopIfIdle(false)
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "too much", nil)
	events := stream.until(t, "turn.finished", 10*time.Second)
	if last := events[len(events)-1]; last.Outcome != "error" {
		t.Fatalf("outcome: %s", last.raw)
	}
	messages := hubMessages(f.host, sessionKey{"p1", id})
	if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "protocol_error" {
		t.Fatalf("messages: %s", marshalJSONLine(messages))
	}
}

// Options list the models initialize reported (probed once, then cached),
// the permission modes and efforts; capabilities describe the provider.
func TestClaudeOptionsAndCapabilities(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(0, step(map[string]any{"do": "init"}))
	w := f.call("GET", "/v1/chat/options?projectId=p1&provider=claude", nil)
	want := `{"models":[{"id":"claude/default","name":"Default (recommended)","provider":"Claude Code","efforts":["low","medium","high","xhigh","max"]},{"id":"claude/sonnet","name":"Sonnet","provider":"Claude Code","efforts":["low","medium","high"]},{"id":"claude/haiku","name":"Haiku","provider":"Claude Code"}],"defaultModel":"claude/default","agents":["build"],"modes":[{"id":"default","name":"Ask"},{"id":"acceptEdits","name":"Accept edits"},{"id":"plan","name":"Plan"},{"id":"auto","name":"Auto"},{"id":"bypassPermissions","name":"Bypass permissions"}],"defaultMode":"default"}`
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != want {
		t.Fatalf("options: %d %s", w.Code, w.Body)
	}
	sameArgs(t, "probe", f.argv(1), claudeArgs("--permission-mode", "default"))
	id := f.newChat()
	if again := f.call("GET", "/v1/chat/options?projectId=p1&sessionId="+id, nil); strings.TrimSpace(again.Body.String()) != want || f.started() != 1 {
		t.Fatalf("cached options: %s after %d starts", again.Body, f.started())
	}
	var capabilities struct {
		ChatFeatures     []string
		ChatProviderInfo map[string]chatProviderEntry
	}
	json.Unmarshal(f.call("GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	claude := capabilities.ChatProviderInfo["claude"]
	if claude.Transport != "stream-json" || strings.Join(claude.Features, ",") != "rewind,restoreFiles,fork,approvals,questions,modes,effort" || claude.Version != "" {
		t.Fatalf("claude: %+v", claude)
	}
	if features := strings.Join(capabilities.ChatFeatures, ","); features != "reasoning,attachments,queue,rewind,events,parts,stop,clientMessageId,regenerate,fork,modes,effort,title" {
		t.Fatalf("chat features: %s", features)
	}
}

// Attachments are read from the attachments folder: the process restarts
// with --add-dir when it lacks it, the prompt names the files, and the
// files are removed when the turn ends.
func TestClaudeAttachments(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "plain", "", 0.001))
	f.script(2, step(map[string]any{"do": "init"}), step(map[string]any{"do": "user", "echo": true}), step(map[string]any{"do": "sleep", "ms": 300}), textReply("msg_2", "read it", ""), resultLine("success", false, 0.001, ""))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	upload := httptestUpload(t, f, id, "notes.txt", "text/plain", []byte("hello"))
	f.mustSend(id, "see the notes", map[string]any{"attachments": []string{upload}})
	args := f.argv(2)
	folder := argValue(args, "--add-dir")
	if folder == "" || argValue(args, "--resume") != argValue(f.argv(1), "--session-id") {
		t.Fatalf("restart for attachments: %q", args)
	}
	var prompt string
	for _, frame := range f.frames(2) {
		if frame["type"] == "user" {
			prompt = frame["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
		}
	}
	if !strings.HasPrefix(prompt, "see the notes\n\nAttached files (read them with your tools):\n- "+folder+string(filepath.Separator)) || !strings.HasSuffix(prompt, " (notes.txt)") {
		t.Fatalf("prompt: %q", prompt)
	}
	path := strings.TrimSuffix(strings.TrimPrefix(prompt, "see the notes\n\nAttached files (read them with your tools):\n- "), " (notes.txt)")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the file is gone during the turn: %v", err)
	}
	f.waitIdle(id)
	waitFor(t, "the attachment to be removed", func() bool {
		_, err := os.Stat(path)
		return errors.Is(err, os.ErrNotExist)
	})
	if legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil).Body.String(); !strings.Contains(legacy, `"attachments":[{"name":"notes.txt","mime":"text/plain"}]`) || strings.Contains(legacy, path) {
		t.Fatalf("legacy: %s", legacy)
	}
}

func httptestUpload(t *testing.T, f *claudeFixture, id, name, contentType string, data []byte) string {
	t.Helper()
	chat := &chatFixture{host: f.host, store: f.store, token: f.token}
	return chat.uploadID(t, f.token, id, name, contentType, data)
}

// Queued messages are sent to a Claude chat one turn at a time.
func TestClaudeQueue(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.001), textTurn("msg_2", "two", "", 0.001))
	id := f.newChat()
	for _, text := range []string{"first", "second"} {
		if w := f.call("POST", "/v1/queue", map[string]string{"projectId": "p1", "sessionId": id, "text": text}); w.Code != 201 {
			t.Fatalf("queue: %d %s", w.Code, w.Body)
		}
	}
	f.host.maintain(nil)
	f.waitIdle(id)
	f.host.maintain(nil)
	f.waitIdle(id)
	waitFor(t, "the queue to empty", func() bool { return len(f.queue.Items("p1", id)) == 0 })
	legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil).Body.String()
	if strings.Index(legacy, `"first"`) > strings.Index(legacy, `"second"`) || !strings.Contains(legacy, `"two"`) {
		t.Fatalf("transcript: %s", legacy)
	}
}

// An echo that comes after the send gave up still starts the turn: the send
// was uncertain, never repeated, and the chat shows the prompt when Claude
// takes it.
func TestClaudeLateEcho(t *testing.T) {
	f := newClaudeFixture(t, func(config *claudeConfig) { config.echoWait = 200 * time.Millisecond })
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user"}),
		step(map[string]any{"do": "sleep", "ms": 600}),
		emit(`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"slow start"}]},"session_id":"$session","parent_tool_use_id":null,"uuid":"$user","isReplay":true}`),
		textReply("msg_1", "finally", ""),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	if w, _ := f.send(id, "slow start", nil); w.Code != 502 || errorCode(t, w) != "delivery_uncertain" {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(id, "another", nil); w.Code != 409 {
		t.Fatalf("a send while the first waits: %d %s", w.Code, w.Body)
	}
	events := stream.until(t, "turn.finished", 10*time.Second)
	claudeInOrder(t, trace(events), "message.created:user", "turn.started", "message.created:assistant", "turn.finished:completed")
}

// The CLI gets the stream-json settings but none of AgentLand's or
// OpenCode's variables, nor a parent Claude Code session's markers.
func TestClaudeEnvironment(t *testing.T) {
	t.Setenv("AGENTLAND_SECRET_PROBE", "x")
	t.Setenv("OPENCODE_SERVER_PASSWORD", "y")
	t.Setenv("CLAUDECODE", "1")
	f := newClaudeFixture(t, nil)
	f.script(0, step(map[string]any{"do": "init"}), textTurn("msg_1", "ok", "", 0.001))
	id := f.newChat()
	f.mustSend(id, "hi", nil)
	var started struct{ Env map[string]string }
	data, _ := os.ReadFile(filepath.Join(f.dir, "argv-1.json"))
	json.Unmarshal(data, &started)
	if len(started.Env) != 3 || started.Env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] != "true" {
		t.Fatalf("environment: %v", started.Env)
	}
}

// api_retry shows as status retry until the reply streams again.
func TestClaudeRetryStatus(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		emit(`{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":1500,"error_status":529,"error":"overloaded","session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
		step(map[string]any{"do": "sleep", "ms": 200}),
		textReply("msg_1", "after the retry", ""),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "try", nil)
	events := stream.until(t, "turn.finished", 10*time.Second)
	claudeInOrder(t, trace(events), "status:running", "status:retry", "status:running", "turn.finished:completed")
	for _, event := range events {
		if event.Type == "status" && event.State == "retry" {
			var status struct {
				Retry ChatRetry
			}
			json.Unmarshal([]byte(event.raw), &status)
			if status.Retry.Attempt != 2 || status.Retry.NextAt == "" || !strings.Contains(status.Retry.Message, "529") {
				t.Fatalf("retry: %s", event.raw)
			}
		}
	}
}

// A chat may be created with its model, mode and effort; other agents
// refuse them.
func TestClaudeSessionSettings(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(0, step(map[string]any{"do": "init"}), textTurn("msg_1", "ok", "", 0.001))
	w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude", "model": "claude/haiku", "mode": "acceptEdits", "effort": "medium"})
	var session Session
	json.Unmarshal(w.Body.Bytes(), &session)
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	f.mustSend(session.ID, "hi", nil)
	f.waitIdle(session.ID)
	sameArgs(t, "configured start", f.argv(1), claudeArgs("--permission-mode", "acceptEdits", "--model", "haiku", "--effort", "medium", "--session-id", argValue(f.argv(1), "--session-id")))
	if w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "codex", "mode": "plan"}); w.Code != 400 || errorCode(t, w) != "unsupported_options" {
		t.Fatalf("codex with a mode: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "claude", "effort": "extreme"}); w.Code != 400 || errorCode(t, w) != "invalid_agent_options" {
		t.Fatalf("unknown effort: %d %s", w.Code, w.Body)
	}
}

// A chat from before streaming resumes its session, shows its earlier
// replies as they were, and its first streamed turn cannot be dropped
// (the host never saw the earlier transcript entries).
func TestClaudeContinuesAChatFromBeforeStreaming(t *testing.T) {
	f := newClaudeFixture(t, nil)
	f.script(0, step(map[string]any{"do": "init"}), textTurn("msg_1", "streamed", "", 0.001))
	id := f.newChat()
	native := newClaudeUUID()
	f.chats.mu.Lock()
	record := f.chats.records[id]
	record.NativeID = native
	record.Messages = []Message{{ID: "old-user", Role: "user", Text: "before"}, {ID: "old-reply", Role: "assistant", Text: "from the one-shot run"}}
	f.chats.mu.Unlock()
	turn := f.mustSend(id, "now streaming", nil)
	f.waitIdle(id)
	sameArgs(t, "resume", f.argv(1), claudeArgs("--permission-mode", "default", "--resume", native))
	legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil).Body.String()
	if !strings.HasPrefix(legacy, `{"messages":[{"id":"old-user","role":"user","text":"before"},{"id":"old-reply","role":"assistant","text":"from the one-shot run"},{"id":"`+turn.MessageID+`","role":"user","text":"now streaming"`) {
		t.Fatalf("legacy: %s", legacy)
	}
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": turn.MessageID}); w.Code != 400 {
		t.Fatalf("rewind across unknown entries: %d %s", w.Code, w.Body)
	}
}

// A streamed Claude chat nobody watches is captured once: the archive files
// the user message under the ID the CLI replays, so no second copy appears.
func TestChatCaptureRecordsAStreamedClaudeChat(t *testing.T) {
	f, archive := newClaudeArchiveFixture(t)
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		systemInit(),
		messageStart("msg_1"),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Thinking it over."}}`),
		claudeEvent(`{"type":"content_block_stop","index":0}`),
		claudeEvent(`{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello from the fake claude."}}`),
		claudeEvent(`{"type":"content_block_stop","index":1}`),
		claudeEvent(`{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":42}}`),
		claudeEvent(`{"type":"message_stop"}`),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	receipt := f.mustSend(id, "Say hello", nil)
	f.waitIdle(id)
	page := waitArchived(t, archive, id, "the Claude reply", func(page ArchiveChatPage) bool {
		return len(page.Messages) >= 2 && page.Messages[len(page.Messages)-1].Status == "complete" && len(page.Messages[len(page.Messages)-1].Parts) == 2
	})
	if len(page.Messages) != 2 {
		t.Fatalf("archived %d messages: %+v", len(page.Messages), page.Messages)
	}
	user, reply := page.Messages[0], page.Messages[1]
	if page.Chat.Provider != "claude" || user.ID != receipt.MessageID || user.Parts[0].Text != "Say hello" || reply.TurnID != receipt.MessageID ||
		reply.Parts[0].Kind != "reasoning" || reply.Parts[1].Text != "Hello from the fake claude." || reply.Model != "claude/claude-opus-5-5" || reply.Usage == nil || reply.Usage.Output != 42 {
		t.Fatalf("archived Claude chat %+v", page)
	}
	sameArchived(t, page.Messages, hubMessages(f.host, sessionKey{"p1", id}))
	for _, frame := range f.frames(1) {
		if frame["type"] == "user" && frame["uuid"] != receipt.MessageID {
			t.Fatalf("the CLI got another uuid: %v", frame)
		}
	}
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures %d: %s", archive.failures.Load(), archive.lastErr)
	}
}

// The backfill imports a streamed Claude chat from the registry: the earlier
// one-shot replies, then the streamed messages up to the rewind point, under
// the IDs live capture used, so nothing is doubled.
func TestClaudeBackfillImportsStreamedMessages(t *testing.T) {
	f, archive := newClaudeArchiveFixture(t)
	f.script(0, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.001), textTurn("msg_2", "two", "", 0.001))
	id := f.newChat()
	first := f.mustSend(id, "first", nil)
	f.waitIdle(id)
	second := f.mustSend(id, "second", nil)
	f.waitIdle(id)
	f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": second.MessageID})
	f.chats.mu.Lock()
	f.chats.records[id].Messages = []Message{{ID: "old-user", Role: "user", Text: "before"}}
	f.chats.mu.Unlock()
	record, err := f.chats.recordCopy(f.project, id)
	if err != nil {
		t.Fatal(err)
	}
	unified := record.claudeUnified()
	ids := []string{}
	for _, message := range unified {
		ids = append(ids, message.ID)
	}
	if len(unified) != 3 || ids[0] != "old-user" || ids[1] != first.MessageID || unified[2].Parts[0].Text != "one" || unified[2].ChatID != id {
		t.Fatalf("import: %v", ids)
	}
	waitArchived(t, archive, id, "live capture", func(page ArchiveChatPage) bool { return len(page.Messages) >= 4 })
	if _, err := f.host.importCLIRecord(context.Background(), f.project, record); err != nil {
		t.Fatal(err)
	}
	page := archivedPage(t, archive, id)
	seen := map[string]int{}
	for _, message := range page.Messages {
		seen[message.ID]++
		if seen[message.ID] > 1 {
			t.Fatalf("message %s archived twice", message.ID)
		}
	}
	if seen[first.MessageID] != 1 || seen["old-user"] != 1 {
		t.Fatalf("archived: %v", seen)
	}
}

// Continue to a Claude chat takes a Claude model, mode and effort.
func TestClaudeContinueTakesModeAndEffort(t *testing.T) {
	f, _ := newClaudeArchiveFixture(t)
	f.script(0, step(map[string]any{"do": "init"}), textTurn("msg_1", "source", "", 0.001), textTurn("msg_2", "continued", "", 0.001))
	source := f.newChat()
	f.mustSend(source, "the source chat", nil)
	f.waitIdle(source)
	waitArchived(t, f.host.archive, source, "the source chat", func(page ArchiveChatPage) bool { return len(page.Messages) == 2 })
	w := f.call("POST", "/v1/chat/continue", map[string]any{"projectId": "p1", "sourceSessionId": source, "provider": "claude", "model": "claude/sonnet", "mode": "plan", "effort": "high"})
	if w.Code != 201 {
		t.Fatalf("continue: %d %s", w.Code, w.Body)
	}
	var continued Session
	json.Unmarshal(w.Body.Bytes(), &continued)
	f.mustSend(continued.ID, "go on", nil)
	f.waitIdle(continued.ID)
	args := f.argv(f.started())
	if argValue(args, "--model") != "sonnet" || argValue(args, "--effort") != "high" || argValue(args, "--permission-mode") != "plan" {
		t.Fatalf("continued start: %q", args)
	}
	if w := f.call("POST", "/v1/chat/continue", map[string]any{"projectId": "p1", "sourceSessionId": source, "provider": "claude", "effort": "extreme"}); w.Code != 400 {
		t.Fatalf("unknown effort: %d %s", w.Code, w.Body)
	}
}

func TestClaudeVersionComesFromThePath(t *testing.T) {
	directory := t.TempDir()
	versioned := filepath.Join(directory, "versions", "2.1.280")
	os.MkdirAll(filepath.Dir(versioned), 0o755)
	os.WriteFile(versioned, []byte("#!/bin/sh\n"), 0o755)
	link := filepath.Join(directory, "bin", "claude")
	os.MkdirAll(filepath.Dir(link), 0o755)
	os.Symlink(versioned, link)
	if got := claudeVersionFromPath(link); got != "2.1.280" {
		t.Fatalf("versions layout: %q", got)
	}
	npm := filepath.Join(directory, "node_modules", "@anthropic-ai", "claude-code")
	os.MkdirAll(filepath.Join(npm, "bin"), 0o755)
	os.WriteFile(filepath.Join(npm, "bin", "claude.exe"), []byte("x"), 0o755)
	os.WriteFile(filepath.Join(npm, "package.json"), []byte(`{"name":"@anthropic-ai/claude-code","version":"2.1.280"}`), 0o644)
	if got := claudeVersionFromPath(filepath.Join(npm, "bin", "claude.exe")); got != "2.1.280" {
		t.Fatalf("npm layout: %q", got)
	}
	os.WriteFile(filepath.Join(npm, "package.json"), []byte(`{"name":"something-else","version":"9.9.9"}`), 0o644)
	if got := claudeVersionFromPath(filepath.Join(npm, "bin", "claude.exe")); got != "" {
		t.Fatalf("another package: %q", got)
	}
}

// A chat whose host stopped mid-turn shows that reply as failed after a
// restart, and its next turn cannot be dropped (entries were missed).
func TestClaudeRecoversATurnTheHostStoppedIn(t *testing.T) {
	f := newClaudeFixture(t, nil)
	id := f.newChat()
	state, _ := json.Marshal(claudeRecord{Mode: "auto", Started: true, Running: "p-1", LastEntry: "p-1", Turns: []claudeTurnRecord{{Prompt: "p-1", First: true}}, Messages: []ChatMessage{
		{ID: "p-1", ChatID: id, TurnID: "p-1", Role: "user", Status: "complete", Ord: 1, Provider: "claude", Parts: []ChatPart{{ID: "p-1:0", Kind: "text", Ord: 1, Text: "hi"}}},
		{ID: "a-1", ChatID: id, TurnID: "p-1", Role: "assistant", Status: "streaming", Ord: 2, Provider: "claude", Parts: []ChatPart{{ID: "a-1:0", Kind: "text", Ord: 1, Text: "half"}}},
	}})
	if err := f.chats.claudeSave(f.project, id, newClaudeUUID(), state, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewCLIChats(f.store.Path+".chats.json", claudeTestRunner{config: f.chats.claude.options})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	chat, err := restarted.claude.chat(f.project, id)
	if err != nil {
		t.Fatal(err)
	}
	chat.mu.Lock()
	defer chat.mu.Unlock()
	reply := chat.rec.Messages[1]
	if chat.rec.Running != "" || reply.Status != "error" || reply.Error.Code != "agent_exited" || reply.Parts[0].Text != "half" || !chat.rec.Gap {
		t.Fatalf("recovered: %+v", chat.rec)
	}
}

// A plan approval's detail is the plan. Claude Code 2.1.296 puts the plan
// file it had the model write into ExitPlanMode's input and drops a plan the
// model gave in the call itself, so without a plan file the request carries
// {}: the plan then comes from the model's own call, and failing both the
// card says the plan was not sent.
func TestClaudePlanApprovalDetail(t *testing.T) {
	f := newClaudeFixture(t, nil)
	plan := "1. Read the code\n2. Change it"
	f.script(0,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		messageStart("msg_plan"),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_plan","name":"ExitPlanMode","input":{}}}`),
		assistantBlock("msg_plan", "", `{"type":"tool_use","id":"toolu_plan","name":"ExitPlanMode","input":{"plan":`+jsonString(plan)+`}}`, ""),
		askLine("from-call", `{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{},"tool_use_id":"toolu_plan"}`),
		awaitLine("from-call"),
		askLine("from-file", `{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Plan\nShip it","planFilePath":"/home/me/.claude/plans/quiet-river.md"},"tool_use_id":"toolu_file"}`),
		awaitLine("from-file"),
		askLine("not-sent", `{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{},"tool_use_id":"toolu_missing"}`),
		awaitLine("not-sent"),
		resultLine("success", false, 0.001, ""),
	)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(id, "Plan it", nil)
	for _, want := range []struct{ request, detail string }{{"from-call", plan}, {"from-file", "# Plan\nShip it"}, {"not-sent", claudePlanNotSent}} {
		events := stream.until(t, "interaction.requested", 10*time.Second)
		asked := events[len(events)-1].Interaction
		if asked.ID != want.request || asked.Permission == nil || asked.Permission.Tool != "ExitPlanMode" || asked.Permission.Detail != want.detail || asked.Permission.Title != "Leave plan mode and start on this plan?" {
			t.Fatalf("%s: %s", want.request, events[len(events)-1].raw)
		}
		if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": want.request, "reply": "once"}); w.Code != 200 {
			t.Fatalf("%s reply: %d %s", want.request, w.Code, w.Body)
		}
	}
	stream.until(t, "turn.finished", 10*time.Second)
}
