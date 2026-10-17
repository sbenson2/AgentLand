package host

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

// acpTestRunner runs no Claude Code or Codex chats: the ACP tests find none
// of the owner's commands.
type acpTestRunner struct{}

func (acpTestRunner) Available() []string { return nil }
func (acpTestRunner) Run(context.Context, string, string, string, string, []ChatAttachment) (CLIChatResult, error) {
	return CLIChatResult{}, ErrCLIChatUnavailable
}

var acpTimePattern = regexp.MustCompile(`\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z`)

// acpNormal renders messages with stable IDs and times, for goldens.
func acpNormal(t *testing.T, chatID string, messages []ChatMessage) string {
	t.Helper()
	data, err := json.MarshalIndent(messages, "", " ")
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(data), chatID, "CHAT")
	for index, message := range messages {
		text = strings.ReplaceAll(text, message.ID, fmt.Sprintf("M%d", index+1))
	}
	return acpTimePattern.ReplaceAllString(text, "TIME")
}

// acpTurnScript is one whole turn: every session/update kind the host maps,
// in the order an agent sends them.
func acpTurnScript(project string) []map[string]any {
	return fakeSteps(
		fakeInit(map[string]any{"loadSession": true, "promptCapabilities": map[string]any{"image": true}}),
		fakeNewSession("s-1", map[string]any{"currentModeId": "ask", "availableModes": []any{map[string]any{"id": "ask", "name": "Ask"}, map[string]any{"id": "code", "name": "Code", "description": "Writes code"}}}),
		fakeAwait("session/prompt"),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "available_commands_update", "availableCommands": []any{}}),
		fakeText("s-1", "agent_thought_chunk", "Looking at "),
		fakeText("s-1", "agent_thought_chunk", "the files."),
		fakeText("s-1", "agent_message_chunk", "Hello"),
		fakeText("s-1", "agent_message_chunk", ", world."),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read main.go", "kind": "read", "status": "pending", "locations": []any{map[string]any{"path": filepath.Join(project, "src", "main.go"), "line": 3}, map[string]any{"path": "/etc/hosts"}}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "package main"}}}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t2", "title": "Edit notes", "kind": "edit", "status": "in_progress", "rawInput": map[string]any{"path": "notes.txt"}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "t2", "status": "completed", "content": []any{map[string]any{"type": "diff", "path": filepath.Join(project, "notes.txt"), "oldText": "a\nb\nc\nd\ne", "newText": "a\nb\nC\nd\ne"}}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t3", "title": "Run tests", "kind": "execute", "status": "in_progress"}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "t3", "status": "failed", "rawOutput": map[string]any{"exitCode": 1}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "plan", "entries": []any{map[string]any{"content": "Read", "priority": "high", "status": "completed"}, map[string]any{"content": "Edit", "priority": "medium", "status": "in_progress"}, map[string]any{"content": "Test", "priority": "low", "status": "pending"}}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": "code"}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "resource_link", "uri": "file:///tmp/report.md", "name": "report.md"}}),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "some_future_update", "anything": true}),
		// An update for another session is not this chat's.
		fakeText("s-2", "agent_message_chunk", "not mine"),
		fakeReply(map[string]any{"stopReason": "end_turn"}),
	)
}

const acpTurnGolden = `[
 {
  "id": "M1",
  "chatId": "CHAT",
  "turnId": "M1",
  "role": "user",
  "status": "complete",
  "ord": 1,
  "createdAt": "TIME",
  "provider": "fake",
  "model": "fake/default",
  "parts": [
   {
    "id": "M1:0",
    "kind": "text",
    "ord": 1,
    "text": "Look at the project"
   }
  ]
 },
 {
  "id": "M2",
  "chatId": "CHAT",
  "turnId": "M1",
  "role": "assistant",
  "status": "complete",
  "ord": 2,
  "createdAt": "TIME",
  "completedAt": "TIME",
  "provider": "fake",
  "model": "fake/default",
  "parts": [
   {
    "id": "M2:0",
    "kind": "reasoning",
    "ord": 1,
    "text": "Looking at the files.",
    "start": "TIME"
   },
   {
    "id": "M2:1",
    "kind": "text",
    "ord": 2,
    "text": "Hello, world.",
    "start": "TIME"
   },
   {
    "id": "M2:2",
    "kind": "tool",
    "ord": 3,
    "tool": {
     "name": "read",
     "callId": "t1",
     "status": "completed",
     "title": "Read main.go",
     "input": "{\"locations\":[{\"path\":\"src/main.go\",\"line\":3},{\"path\":\"hosts\"}]}",
     "output": "package main",
     "truncated": false
    },
    "start": "TIME",
    "end": "TIME"
   },
   {
    "id": "M2:3",
    "kind": "tool",
    "ord": 4,
    "tool": {
     "name": "edit",
     "callId": "t2",
     "status": "completed",
     "title": "Edit notes",
     "input": "{\"path\":\"notes.txt\"}",
     "output": "--- notes.txt\n+++ notes.txt\n@@\n a\n b\n-c\n+C\n d\n e",
     "truncated": false
    },
    "start": "TIME",
    "end": "TIME"
   },
   {
    "id": "M2:4",
    "kind": "tool",
    "ord": 5,
    "tool": {
     "name": "execute",
     "callId": "t3",
     "status": "error",
     "title": "Run tests",
     "error": "{\"exitCode\":1}",
     "truncated": false
    },
    "start": "TIME",
    "end": "TIME"
   },
   {
    "id": "M2:5",
    "kind": "tool",
    "ord": 6,
    "tool": {
     "name": "Plan",
     "callId": "plan",
     "status": "completed",
     "title": "Plan",
     "output": "[x] Read\n[~] Edit\n[ ] Test",
     "truncated": false
    },
    "start": "TIME",
    "end": "TIME"
   },
   {
    "id": "M2:6",
    "kind": "text",
    "ord": 7,
    "text": "[resource file:///tmp/report.md]",
    "start": "TIME"
   }
  ]
 }
]`

func TestACPTurnMapping(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, acpTurnScript(f.project.Directory)...)
	session := f.newChat("fake", "")
	if !strings.HasPrefix(session.ID, "fake:") || !isACPSessionID(session.ID) || session.Provider != "fake" || session.Title != "Fake Agent" || session.TitleSource != "default" {
		t.Fatalf("session %+v", session)
	}
	stream := f.stream(session.ID)
	stream.until(t, "snapshot", 5*time.Second)
	receipt := f.mustSend(session.ID, "Look at the project")
	if receipt.MessageID == "" || receipt.TurnID != receipt.MessageID {
		t.Fatalf("receipt %+v", receipt)
	}
	events := stream.until(t, "turn.finished", 10*time.Second)
	f.waitIdle(session.ID)
	if got := acpNormal(t, session.ID, f.messages(session.ID)); got != acpTurnGolden {
		t.Fatalf("messages:\n%s", got)
	}
	var kinds []string
	deltas, modeUpdated := "", false
	for _, event := range events {
		kinds = append(kinds, event.Type)
		if event.Type == "part.delta" {
			deltas += event.Delta
		}
		if event.Type == "chat.updated" && strings.Contains(event.raw, `"mode":"code"`) {
			modeUpdated = true
		}
		if strings.Contains(event.raw, "not mine") {
			t.Fatal("another session's update reached the chat")
		}
	}
	if deltas != "the files., world." || !modeUpdated {
		t.Fatalf("deltas %q, mode %v, events %v", deltas, modeUpdated, kinds)
	}
	finished := events[len(events)-1]
	if !strings.Contains(finished.raw, `"outcome":"completed"`) {
		t.Fatalf("finished %s", finished.raw)
	}
	// The chat's settings: the mode the agent switched to, the modes it
	// listed, remembered for new chats of the agent.
	w := f.call("GET", "/v1/chat/options?projectId=p1&sessionId="+session.ID, nil)
	var options ChatOptions
	json.Unmarshal(w.Body.Bytes(), &options)
	if w.Code != 200 || options.DefaultModel != "fake/default" || options.DefaultMode != "code" || len(options.Modes) != 2 || options.Modes[1] != (ChatMode{ID: "code", Name: "Code"}) {
		t.Fatalf("options %d %s", w.Code, w.Body)
	}
	w = f.call("GET", "/v1/chat/options?projectId=p1&provider=fake", nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"modes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]`) {
		t.Fatalf("new chat options %d %s", w.Code, w.Body)
	}
	// The legacy shape and the pages read the same transcript.
	w = f.call("GET", "/v1/messages?projectId=p1&sessionId="+session.ID, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"text":"Hello, world.\n\n[resource file:///tmp/report.md]"`) || !strings.Contains(w.Body.String(), `"reasoning":[{"text":"Looking at the files."}]`) {
		t.Fatalf("legacy %d %s", w.Code, w.Body)
	}
	w = f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+session.ID, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"hasMore":false`) {
		t.Fatalf("page %d %s", w.Code, w.Body)
	}
	// The host named the chat from the message.
	listed := f.call("GET", "/v1/sessions?projectId=p1", nil).Body.String()
	if !strings.Contains(listed, `"title":"Look at the project","projectId":"p1","provider":"fake","titleSource":"auto"`) {
		t.Fatalf("sessions %s", listed)
	}
}

func TestACPProcessAndHandshake(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	session := f.newChat("fake", "Fake Agent chat")
	if session.TitleSource != "default" {
		t.Fatalf("the agent's name with chat is a placeholder: %+v", session)
	}
	f.mustSend(session.ID, "hi")
	f.waitIdle(session.ID)
	args, cwd, env := f.launched(1)
	if !reflect.DeepEqual(args, []string{"--acp"}) {
		t.Fatalf("argv %v", args)
	}
	if resolved, _ := filepath.EvalSymlinks(f.project.Directory); cwd != resolved && cwd != f.project.Directory {
		t.Fatalf("cwd %q, want the workspace %q", cwd, f.project.Directory)
	}
	for _, secret := range []string{"AGENTLAND_SECRET_PROBE", "OPENCODE_SERVER_PASSWORD", "ANTHROPIC_API_KEY"} {
		if _, leaked := env[secret]; leaked {
			t.Errorf("%s reached the agent", secret)
		}
	}
	if env["FAKE_OWN"] != "kept" || env["PATH"] != "/usr/bin:/bin" || env["HOME"] == "" || env["USER"] != "tester" || env["LC_ALL"] != "C.UTF-8" {
		t.Fatalf("environment %v", env)
	}
	frames := f.frames(1)
	if len(frames) < 3 {
		t.Fatalf("frames %v", frames)
	}
	for _, frame := range frames {
		if frame["jsonrpc"] != "2.0" {
			t.Fatalf("frame without jsonrpc 2.0: %v", frame)
		}
	}
	initialize, _ := json.Marshal(frames[0]["params"])
	if frames[0]["method"] != "initialize" || string(initialize) != `{"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"protocolVersion":1}` {
		t.Fatalf("initialize %s", initialize)
	}
	created, _ := json.Marshal(frames[1]["params"])
	if frames[1]["method"] != "session/new" || string(created) != fmt.Sprintf(`{"cwd":%q,"mcpServers":[]}`, f.project.Directory) {
		t.Fatalf("session/new %s", created)
	}
	prompt, _ := json.Marshal(frames[2]["params"])
	if frames[2]["method"] != "session/prompt" || string(prompt) != `{"prompt":[{"text":"hi","type":"text"}],"sessionId":"s-1"}` {
		t.Fatalf("session/prompt %s", prompt)
	}
}

func TestACPApprovals(t *testing.T) {
	f := newACPFixture(t, nil)
	options := []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}, map[string]any{"optionId": "always-ls", "name": "Always allow ls", "kind": "allow_always"}, map[string]any{"optionId": "deny", "name": "Reject", "kind": "reject_once"}}
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"),
		fakeUpdate("s-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run ls", "kind": "execute", "status": "pending"}),
		map[string]any{"do": "request", "id": "p1", "method": "session/request_permission", "params": map[string]any{"sessionId": "s-1", "toolCall": map[string]any{"toolCallId": "t1", "rawInput": map[string]any{"command": "ls"}, "locations": []any{map[string]any{"path": filepath.Join(f.project.Directory, "src")}}}, "options": options}},
		map[string]any{"do": "awaitResponse", "id": "p1"},
		map[string]any{"do": "request", "id": "p2", "method": "session/request_permission", "params": map[string]any{"sessionId": "s-1", "toolCall": map[string]any{"toolCallId": "t2", "title": "Write"}, "options": []any{map[string]any{"optionId": "ok", "name": "OK", "kind": "allow_once"}}}},
		map[string]any{"do": "awaitResponse", "id": "p2"},
		fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	session := f.newChat("fake", "")
	stream := f.stream(session.ID)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(session.ID, "list the files")
	events := stream.until(t, "interaction.requested", 10*time.Second)
	requested := events[len(events)-1].Interaction
	if requested == nil || requested.Kind != "permission" || !reflect.DeepEqual(requested.Choices, []string{"once", "always", "reject"}) || requested.AlwaysLabel != "Always allow ls" || requested.AlwaysDetail != "Fake Agent decides what this allows and for how long." {
		t.Fatalf("interaction %s", events[len(events)-1].raw)
	}
	if permission := requested.Permission; permission.Tool != "execute" || permission.Title != "Run ls" || permission.Detail != "src" || permission.Input != `{"command":"ls"}` {
		t.Fatalf("permission %+v", permission)
	}
	// Waiting shows in the status and the legacy list.
	w := f.call("GET", "/v1/interactions?projectId=p1&sessionId="+session.ID, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"id":"`+requested.ID+`"`) {
		t.Fatalf("interactions %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": session.ID, "requestId": requested.ID, "answers": [][]string{{"a"}}}); w.Code != 404 {
		t.Fatalf("an approval is no question: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]any{"projectId": "p1", "sessionId": session.ID, "requestId": requested.ID, "reply": "always"}); w.Code != 200 {
		t.Fatalf("reply %d %s", w.Code, w.Body)
	}
	events = stream.until(t, "interaction.requested", 10*time.Second)
	second := events[len(events)-1].Interaction
	resolved := false
	for _, event := range events {
		resolved = resolved || (event.Type == "interaction.resolved" && strings.Contains(event.raw, `"outcome":"always"`))
	}
	if !resolved || !reflect.DeepEqual(second.Choices, []string{"once", "reject"}) || second.AlwaysLabel != "" {
		t.Fatalf("second %s, resolved %v", events[len(events)-1].raw, resolved)
	}
	// A choice the request does not offer is refused; reject without a
	// reject option answers cancelled.
	if w := f.call("POST", "/v1/permissions/reply", map[string]any{"projectId": "p1", "sessionId": session.ID, "requestId": second.ID, "reply": "always"}); w.Code != 400 {
		t.Fatalf("always not offered: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]any{"projectId": "p1", "sessionId": session.ID, "requestId": second.ID, "reply": "reject"}); w.Code != 200 {
		t.Fatalf("reject %d %s", w.Code, w.Body)
	}
	stream.until(t, "turn.finished", 10*time.Second)
	answers := map[string]string{}
	for _, frame := range f.frames(1) {
		if id, _ := frame["id"].(string); id == "p1" || id == "p2" {
			data, _ := json.Marshal(frame["result"])
			answers[id] = string(data)
		}
	}
	if answers["p1"] != `{"outcome":{"optionId":"always-ls","outcome":"selected"}}` || answers["p2"] != `{"outcome":{"outcome":"cancelled"}}` {
		t.Fatalf("answers %v", answers)
	}
}

func TestACPStopCancels(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"),
		fakeText("s-1", "agent_message_chunk", "Working"),
		map[string]any{"do": "request", "id": "p1", "method": "session/request_permission", "params": map[string]any{"sessionId": "s-1", "toolCall": map[string]any{"toolCallId": "t1", "title": "Delete"}, "options": []any{map[string]any{"optionId": "yes", "name": "Yes", "kind": "allow_once"}}}},
		map[string]any{"do": "awaitResponse", "id": "p1"},
		fakeAwait("session/cancel"),
		fakeReply(map[string]any{"stopReason": "cancelled"}))...)
	session := f.newChat("fake", "")
	stream := f.stream(session.ID)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(session.ID, "delete it")
	stream.until(t, "interaction.requested", 10*time.Second)
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": session.ID}); w.Code != 200 {
		t.Fatalf("abort %d %s", w.Code, w.Body)
	}
	events := stream.until(t, "turn.finished", 10*time.Second)
	gone := false
	for _, event := range events {
		gone = gone || (event.Type == "interaction.resolved" && strings.Contains(event.raw, `"outcome":"gone"`))
	}
	if !gone || !strings.Contains(events[len(events)-1].raw, `"outcome":"aborted"`) {
		t.Fatalf("events %v", events)
	}
	messages := f.messages(session.ID)
	if reply := messages[len(messages)-1]; reply.Status != "aborted" || reply.Parts[0].Text != "Working" || reply.Parts[1].Tool.Status != "error" {
		t.Fatalf("reply %+v", reply)
	}
	methods := f.methods(1)
	if methods[len(methods)-1] != "session/cancel" {
		t.Fatalf("methods %v", methods)
	}
	for _, frame := range f.frames(1) {
		if frame["id"] == "p1" {
			if data, _ := json.Marshal(frame["result"]); string(data) != `{"outcome":{"outcome":"cancelled"}}` {
				t.Fatalf("the approval's answer %s", data)
			}
		}
	}
	// A process that does not answer the cancel is ended.
	f2 := newACPFixture(t, func(config *acpConfig) { config.cancelWait = 300 * time.Millisecond })
	f2.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), map[string]any{"do": "hang"})...)
	stuck := f2.newChat("fake", "")
	f2.mustSend(stuck.ID, "hang")
	waitFor(t, "the prompt", func() bool { return len(f2.methods(1)) >= 3 })
	f2.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": stuck.ID})
	f2.waitIdle(stuck.ID)
	if messages := f2.messages(stuck.ID); messages[len(messages)-1].Status != "aborted" {
		t.Fatalf("the stuck turn %+v", messages[len(messages)-1])
	}
}

// A permission request that crosses Stop on the wire is answered cancelled
// at once and shows no approval, so nothing can allow the tool after Stop.
func TestACPApprovalAfterStopIsCancelled(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"),
		fakeText("s-1", "agent_message_chunk", "Working"),
		fakeAwait("session/cancel"),
		// The agent sent this before it read the cancel.
		map[string]any{"do": "request", "id": "late", "method": "session/request_permission", "params": map[string]any{"sessionId": "s-1", "toolCall": map[string]any{"toolCallId": "t9", "title": "rm -rf build", "kind": "execute"}, "options": []any{map[string]any{"optionId": "yes", "name": "Yes", "kind": "allow_once"}, map[string]any{"optionId": "no", "name": "No", "kind": "reject_once"}}}},
		map[string]any{"do": "awaitResponse", "id": "late"},
		fakeReply(map[string]any{"stopReason": "cancelled"}))...)
	session := f.newChat("fake", "")
	stream := f.stream(session.ID)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(session.ID, "clean up")
	stream.until(t, "part.created", 5*time.Second)
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": session.ID}); w.Code != 200 {
		t.Fatalf("abort %d %s", w.Code, w.Body)
	}
	events := stream.until(t, "turn.finished", 5*time.Second)
	for _, event := range events {
		if event.Type == "interaction.requested" {
			t.Fatalf("an approval showed after Stop: %s", event.raw)
		}
	}
	if finished := events[len(events)-1]; !strings.Contains(finished.raw, `"outcome":"aborted"`) {
		t.Fatalf("finished %s", finished.raw)
	}
	answer := ""
	for _, frame := range f.frames(1) {
		if frame["id"] == "late" {
			data, _ := json.Marshal(frame["result"])
			answer = string(data)
		}
	}
	if answer != `{"outcome":{"outcome":"cancelled"}}` {
		t.Fatalf("the request after Stop was answered %q", answer)
	}
	if permissions, _ := f.chat(session.ID).pendingRequests(); len(permissions) != 0 {
		t.Fatalf("pending %+v", permissions)
	}
}

// A session/set_mode the agent never answers ends the turn and the process,
// as an unanswered initialize, session/new or session/load does: the next
// send starts a new process instead of waiting on the hung one.
func TestACPSetModeTimeoutEndsTheProcess(t *testing.T) {
	f := newACPFixture(t, func(config *acpConfig) { config.controlWait = 300 * time.Millisecond })
	modes := map[string]any{"currentModeId": "ask", "availableModes": []any{map[string]any{"id": "ask", "name": "Ask"}, map[string]any{"id": "code", "name": "Code"}}}
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", modes), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}),
		fakeAwait("session/set_mode"), map[string]any{"do": "hang"})...)
	f.script(2, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-2", modes), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	session := f.newChat("fake", "")
	f.mustSend(session.ID, "hi")
	f.waitIdle(session.ID)
	if w, _ := f.send(session.ID, "code it", map[string]any{"mode": "code"}); w.Code != 202 {
		t.Fatalf("send %d %s", w.Code, w.Body)
	}
	f.waitIdle(session.ID)
	messages := f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "agent_exited" || last.Error.Message != "Fake Agent did not answer." {
		t.Fatalf("the unanswered set_mode %+v", last.Error)
	}
	chat := f.chat(session.ID)
	chat.mu.Lock()
	kept := chat.conn != nil
	chat.mu.Unlock()
	if kept {
		t.Fatal("the hung process is kept for the next send")
	}
	f.mustSend(session.ID, "plain")
	f.waitIdle(session.ID)
	messages = f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Status != "complete" || last.Error != nil {
		t.Fatalf("the send after %+v", last)
	}
	if started := f.started(); started != 2 {
		t.Fatalf("%d starts, want 2", started)
	}
}

func TestACPSignInNeeded(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeAwait("session/new"), fakeError(-32000, "Authentication required"))...)
	session := f.newChat("fake", "")
	receipt := f.mustSend(session.ID, "hi")
	f.waitIdle(session.ID)
	messages := f.messages(session.ID)
	if len(messages) != 2 || messages[0].ID != receipt.MessageID {
		t.Fatalf("messages %+v", messages)
	}
	failure := messages[1].Error
	if messages[1].Status != "error" || failure == nil || failure.Code != "agent_auth_required" || !reflect.DeepEqual(failure.AuthMethods, []string{"Log in with Fake", "Use an API key"}) || failure.Message != "Fake Agent needs you to sign in (Log in with Fake, Use an API key). Open it in a terminal to sign in, then send again." {
		t.Fatalf("reply %+v %+v", messages[1], failure)
	}
	// The stream and the page carry the names too.
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+session.ID, nil)
	if !strings.Contains(w.Body.String(), `"error":{"code":"agent_auth_required","message":"Fake Agent needs you to sign in (Log in with Fake, Use an API key). Open it in a terminal to sign in, then send again.","authMethods":["Log in with Fake","Use an API key"]}`) {
		t.Fatalf("page %s", w.Body)
	}
	// The owner signs in from a terminal and sends again: a new process
	// answers, since an agent may read its sign-in only when it starts. Any
	// other refusal is the agent's own words.
	f.script(2, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-9", nil), fakeAwait("session/prompt"), fakeError(-32603, "Model overloaded"))...)
	f.mustSend(session.ID, "again")
	f.waitIdle(session.ID)
	messages = f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "agent_error" || last.Error.Message != "Model overloaded" || last.Error.AuthMethods != nil {
		t.Fatalf("agent error %+v", last.Error)
	}
	if started := f.started(); started != 2 {
		t.Fatalf("%d starts, want 2", started)
	}
}

// A refusal for want of a sign-in ends the process that gave it, whichever
// request it answered: the next send starts a new process, which reads the
// sign-in the owner made meanwhile. No idle process is kept for the refusal.
func TestACPSignInStartsAFreshProcess(t *testing.T) {
	refused := fakeError(-32000, "Authentication required")
	done := fakeReply(map[string]any{"stopReason": "end_turn"})
	for _, test := range []struct {
		method        string
		first, second []map[string]any
	}{
		{"session/new",
			fakeSteps(fakeInit(map[string]any{}), fakeAwait("session/new"), refused),
			fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-2", nil), fakeAwait("session/prompt"), done)},
		{"session/load",
			fakeSteps(fakeInit(map[string]any{"loadSession": true}), fakeAwait("session/load"), refused),
			fakeSteps(fakeInit(map[string]any{"loadSession": true}), fakeAwait("session/load"), fakeReply(nil), fakeAwait("session/prompt"), done)},
		{"session/prompt",
			fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), refused),
			fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-2", nil), fakeAwait("session/prompt"), done)},
	} {
		t.Run(test.method, func(t *testing.T) {
			f := newACPFixture(t, nil)
			f.script(1, test.first...)
			f.script(2, test.second...)
			session := f.newChat("fake", "")
			chat := f.chat(session.ID)
			if test.method == "session/load" {
				// A chat whose ACP session an earlier process made.
				chat.mu.Lock()
				chat.rec.SessionID = "s-0"
				chat.mu.Unlock()
			}
			f.mustSend(session.ID, "hi")
			f.waitIdle(session.ID)
			messages := f.messages(session.ID)
			if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "agent_auth_required" {
				t.Fatalf("the refused turn %+v", last)
			}
			if methods := f.methods(1); methods[len(methods)-1] != test.method {
				t.Fatalf("the first process read %v", methods)
			}
			chat.mu.Lock()
			kept := chat.conn != nil
			chat.mu.Unlock()
			if kept {
				t.Fatal("the process that refused is kept for the next send")
			}
			f.mustSend(session.ID, "again")
			f.waitIdle(session.ID)
			messages = f.messages(session.ID)
			if last := messages[len(messages)-1]; last.Status != "complete" || last.Error != nil {
				t.Fatalf("after signing in %+v", last)
			}
			if started := f.started(); started != 2 {
				t.Fatalf("%d starts, want 2", started)
			}
		})
	}
}

func TestACPCrashLoadAndRestart(t *testing.T) {
	f := newACPFixture(t, nil)
	// The first process streams, then dies mid-turn.
	f.script(1, fakeSteps(fakeInit(map[string]any{"loadSession": true}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), fakeText("s-1", "agent_message_chunk", "Half"), map[string]any{"do": "stderr", "raw": "panic: boom\n"}, map[string]any{"do": "exit", "code": 2})...)
	// The next loads the session.
	f.script(2, fakeSteps(fakeInit(map[string]any{"loadSession": true}), fakeAwait("session/load"),
		// What a load replays is not shown again.
		fakeText("s-1", "user_message_chunk", "first"), fakeText("s-1", "agent_message_chunk", "Half"),
		fakeReply(nil), fakeAwait("session/prompt"), fakeText("s-1", "agent_message_chunk", "Whole"), fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	// The third cannot load it: a new session, with a notice.
	f.script(3, fakeSteps(fakeInit(map[string]any{"loadSession": true}), fakeAwait("session/load"), fakeError(-32002, "Resource not found"), fakeNewSession("s-3", nil), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "max_tokens"}))...)
	session := f.newChat("fake", "")
	f.mustSend(session.ID, "first")
	f.waitIdle(session.ID)
	messages := f.messages(session.ID)
	if reply := messages[1]; reply.Status != "error" || reply.Error.Code != "agent_exited" || reply.Error.Message != "Fake Agent stopped before this reply completed." || reply.Parts[0].Text != "Half" {
		t.Fatalf("crash reply %+v", reply)
	}
	f.mustSend(session.ID, "second")
	f.waitIdle(session.ID)
	load, _ := json.Marshal(f.frames(2)[1]["params"])
	if methods := f.methods(2); !reflect.DeepEqual(methods, []string{"initialize", "session/load", "session/prompt"}) || string(load) != fmt.Sprintf(`{"cwd":%q,"mcpServers":[],"sessionId":"s-1"}`, f.project.Directory) {
		t.Fatalf("second start %v %s", methods, load)
	}
	messages = f.messages(session.ID)
	if reply := messages[len(messages)-1]; reply.Status != "complete" || len(reply.Parts) != 1 || reply.Parts[0].Text != "Whole" {
		t.Fatalf("after the load %+v", reply)
	}
	f.chat(session.ID).stopIfIdle(false)
	f.mustSend(session.ID, "third")
	f.waitIdle(session.ID)
	messages = f.messages(session.ID)
	reply := messages[len(messages)-1]
	if len(reply.Parts) != 2 || reply.Parts[0].Text != "The agent started a new session and does not remember the earlier messages." || reply.Parts[1].Text != "The reply reached the model's output limit." || reply.Status != "complete" {
		t.Fatalf("after a refused load %+v", reply)
	}
	// A host that stopped mid-turn shows the reply failed after a restart.
	chat := f.chat(session.ID)
	chat.mu.Lock()
	chat.rec.Running = messages[len(messages)-2].ID
	chat.rec.Messages[len(chat.rec.Messages)-1].Status = "streaming"
	chat.persistLocked()
	chat.mu.Unlock()
	restarted, err := NewCLIChats(f.store.Path+".chats.json", acpTestRunner{})
	if err != nil {
		t.Fatal(err)
	}
	reloaded, err := restarted.acp.chat(f.project, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if last := reloaded.rec.Messages[len(reloaded.rec.Messages)-1]; last.Status != "error" || last.Error.Message != "AgentLand stopped before this reply completed." || reloaded.rec.Running != "" {
		t.Fatalf("recovered %+v", last)
	}
	restarted.Close()
}

func TestACPProtocolBounds(t *testing.T) {
	f := newACPFixture(t, func(config *acpConfig) { config.lineLimit = 64 << 10; config.initWait = 700 * time.Millisecond })
	// An oversized line ends the turn and the process.
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), map[string]any{"do": "oversize", "bytes": 100 << 10}, map[string]any{"do": "hang"})...)
	session := f.newChat("fake", "")
	f.mustSend(session.ID, "big")
	f.waitIdle(session.ID)
	messages := f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "protocol_error" {
		t.Fatalf("oversized %+v", last)
	}
	// An agent that never answers initialize is ended.
	f.script(2, map[string]any{"do": "hang"})
	f.mustSend(session.ID, "hang")
	f.waitIdle(session.ID)
	messages = f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "agent_exited" || last.Error.Message != "Fake Agent did not start." {
		t.Fatalf("hang %+v", last)
	}
	// Protocol version 2 is not spoken.
	f.script(3, fakeAwait("initialize"), fakeReply(map[string]any{"protocolVersion": 2}))
	f.mustSend(session.ID, "v2")
	f.waitIdle(session.ID)
	messages = f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Error == nil || last.Error.Code != "protocol_error" {
		t.Fatalf("version 2 %+v", last)
	}
	// Requests the host does not serve get "method not found".
	f.script(4, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-4", nil), fakeAwait("session/prompt"),
		map[string]any{"do": "request", "id": "r1", "method": "fs/read_text_file", "params": map[string]any{"sessionId": "s-4", "path": "/etc/passwd"}},
		map[string]any{"do": "awaitResponse", "id": "r1"},
		map[string]any{"do": "request", "id": "r2", "method": "terminal/create", "params": map[string]any{"sessionId": "s-4", "command": "ls"}},
		map[string]any{"do": "awaitResponse", "id": "r2"},
		fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	f.mustSend(session.ID, "read")
	f.waitIdle(session.ID)
	for _, frame := range f.frames(4) {
		if id, _ := frame["id"].(string); id == "r1" || id == "r2" {
			failure, _ := frame["error"].(map[string]any)
			if failure == nil || failure["code"] != float64(-32601) {
				t.Fatalf("%s answered %v", id, frame)
			}
		}
	}
}

func TestACPIdleStopAndBusy(t *testing.T) {
	f := newACPFixture(t, func(config *acpConfig) { config.idleStop = 300 * time.Millisecond })
	f.script(0, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), map[string]any{"do": "sleep", "ms": 600}, fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	session := f.newChat("fake", "")
	f.mustSend(session.ID, "slow")
	waitFor(t, "the turn to run", func() bool { return f.chat(session.ID).working() })
	// A second send while the turn runs is refused; the agent counts busy.
	if w, _ := f.send(session.ID, "again", nil); w.Code != 409 {
		t.Fatalf("busy send %d %s", w.Code, w.Body)
	}
	if !f.host.agentBusy("fake") || f.host.agentBusy("other") {
		t.Fatal("busy")
	}
	w := f.call("GET", "/v1/projects", nil)
	if !strings.Contains(w.Body.String(), `"busyChats":1`) {
		t.Fatalf("workspace activity %s", w.Body)
	}
	f.waitIdle(session.ID)
	// The process outlives the turn, then stops after the idle time.
	chat := f.chat(session.ID)
	waitFor(t, "the idle stop", func() bool {
		chat.mu.Lock()
		defer chat.mu.Unlock()
		return chat.conn == nil
	})
	if f.host.agentBusy("fake") {
		t.Fatal("busy after the turn")
	}
}

func TestACPModesAndOptions(t *testing.T) {
	f := newACPFixture(t, nil)
	modes := map[string]any{"currentModeId": "ask", "availableModes": []any{map[string]any{"id": "ask", "name": "Ask"}, map[string]any{"id": "code", "name": "Code"}}}
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", modes), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}),
		fakeAwait("session/set_mode"), fakeReply(nil), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	session := f.newChat("fake", "")
	// Before the agent listed modes, a mode is not taken.
	if w, _ := f.send(session.ID, "hi", map[string]any{"mode": "code"}); w.Code != 400 || !strings.Contains(w.Body.String(), "unsupported_options") {
		t.Fatalf("mode before modes: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(session.ID, "hi", map[string]any{"effort": "high"}); w.Code != 400 || !strings.Contains(w.Body.String(), "unsupported_options") {
		t.Fatalf("effort: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(session.ID, "hi", map[string]any{"model": "fake/big"}); w.Code != 400 || !strings.Contains(w.Body.String(), "invalid_agent_options") {
		t.Fatalf("model: %d %s", w.Code, w.Body)
	}
	f.mustSend(session.ID, "hi")
	f.waitIdle(session.ID)
	if w, _ := f.send(session.ID, "hi", map[string]any{"mode": "yolo"}); w.Code != 400 || !strings.Contains(w.Body.String(), "invalid_agent_options") {
		t.Fatalf("unknown mode: %d %s", w.Code, w.Body)
	}
	if w, _ := f.send(session.ID, "write it", map[string]any{"mode": "code", "model": "fake/default"}); w.Code != 202 {
		t.Fatalf("mode: %d %s", w.Code, w.Body)
	}
	f.waitIdle(session.ID)
	methods := f.methods(1)
	if !reflect.DeepEqual(methods, []string{"initialize", "session/new", "session/prompt", "session/set_mode", "session/prompt"}) {
		t.Fatalf("methods %v", methods)
	}
	setMode, _ := json.Marshal(f.frames(1)[3]["params"])
	if string(setMode) != `{"modeId":"code","sessionId":"s-1"}` {
		t.Fatalf("set_mode %s", setMode)
	}
	chat := f.chat(session.ID)
	chat.mu.Lock()
	mode := chat.rec.Mode
	chat.mu.Unlock()
	if mode != "code" {
		t.Fatalf("mode %q", mode)
	}
}

func TestACPAvailabilityAndCapabilities(t *testing.T) {
	f := newACPFixture(t, nil)
	var capabilities struct {
		ChatProviders    []string
		ChatFeatures     []string
		Agents           []string
		AgentCatalog     []agentCatalogEntry
		ChatProviderInfo map[string]chatProviderEntry
	}
	json.Unmarshal(f.call("GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if !reflect.DeepEqual(capabilities.ChatProviders, []string{"opencode", "fake"}) || !reflect.DeepEqual(capabilities.Agents, []string{"catalog", "install", "updateSettings", "acp"}) {
		t.Fatalf("capabilities %+v", capabilities)
	}
	if !reflect.DeepEqual(capabilities.AgentCatalog, []agentCatalogEntry{{ID: "fake", Name: "Fake Agent", Chat: true, Terminal: true}}) {
		t.Fatalf("catalog %+v", capabilities.AgentCatalog)
	}
	if info := capabilities.ChatProviderInfo["fake"]; info.Version != "1.0.0" || info.Transport != "acp" || !reflect.DeepEqual(info.Features, []string{"approvals", "modes"}) {
		t.Fatalf("provider info %+v", capabilities.ChatProviderInfo)
	}
	modes := false
	for _, feature := range capabilities.ChatFeatures {
		modes = modes || feature == "modes"
	}
	if !modes {
		t.Fatalf("features %v", capabilities.ChatFeatures)
	}
	// Unknown providers and agents that cannot run chats.
	if w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "provider": "nobody"}); w.Code != 400 || !strings.Contains(w.Body.String(), "invalid_provider") {
		t.Fatalf("unknown %d %s", w.Code, w.Body)
	}
	session := f.newChat("fake", "")
	if err := f.host.agents.store.removeAgent("fake"); err != nil {
		t.Fatal(err)
	}
	if w, _ := f.send(session.ID, "hi", nil); w.Code != 503 || !strings.Contains(w.Body.String(), "agent_unavailable") {
		t.Fatalf("uninstalled %d %s", w.Code, w.Body)
	}
	if messages := f.messages(session.ID); len(messages) != 0 {
		t.Fatalf("a refused send was recorded: %+v", messages)
	}
	// The chat stays listed and readable.
	if listed := f.call("GET", "/v1/sessions?projectId=p1", nil).Body.String(); !strings.Contains(listed, session.ID) {
		t.Fatalf("sessions %s", listed)
	}
	if w := f.call("GET", "/v1/chat/status?projectId=p1&sessionId="+session.ID, nil); w.Code != 200 || !strings.Contains(w.Body.String(), `"state":"idle"`) {
		t.Fatalf("status %d %s", w.Code, w.Body)
	}
	// No rewind, regenerate or fork.
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": session.ID, "messageId": "x"}); w.Code != 400 {
		t.Fatalf("rewind %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/chat/regenerate", map[string]string{"projectId": "p1", "sessionId": session.ID}); w.Code != 501 {
		t.Fatalf("regenerate %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": session.ID}); w.Code != 501 {
		t.Fatalf("fork %d %s", w.Code, w.Body)
	}
}

func TestACPSessionIDsNameTheirAgent(t *testing.T) {
	for id, want := range map[string]bool{
		"gemini:0123456789abcdef0123456789abcdef":             true,
		"github-copilot-cli:0123456789abcdef0123456789abcdef": true,
		"claude:0123456789abcdef0123456789abcdef":             false,
		"codex:0123456789abcdef0123456789abcdef":              false,
		"gemini:0123":                                         false,
		"gemini:0123456789ABCDEF0123456789ABCDEF":             false,
		"Gemini:0123456789abcdef0123456789abcdef":             false,
		"ses_0123456789abcdef":                                false,
		"":                                                    false,
	} {
		if got := isACPSessionID(id); got != want {
			t.Errorf("isACPSessionID(%q) = %v, want %v", id, got, want)
		}
	}
}
