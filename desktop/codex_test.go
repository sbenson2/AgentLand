package host

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The Codex engine against the fake codex (codex_fake_test.go): streaming
// order, approvals, questions, stops, failures, restarts, rewind, fork,
// options and the codex exec fallback.

func TestCodexStreamsATurnInOrder(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	stream := f.stream(id)
	client := newClientChat(t)
	for _, event := range stream.until(t, "snapshot", 5*time.Second) {
		client.apply(event)
	}
	receipt := f.send(id, "Say hello", nil)
	if !receipt.Accepted || receipt.MessageID == "" || receipt.TurnID != receipt.MessageID {
		t.Fatalf("receipt: %+v", receipt)
	}
	events := stream.until(t, "turn.finished", 10*time.Second)
	for _, event := range events {
		client.apply(event)
	}
	// Types in the order the host sent them, with repeated deltas folded.
	order := []string{}
	for _, event := range events {
		kind := event.Type
		if kind == "part.created" || kind == "part.updated" {
			kind += ":" + event.Part.Kind
		}
		if len(order) == 0 || order[len(order)-1] != kind {
			order = append(order, kind)
		}
	}
	// Each item's part is created, streams deltas and is updated once more
	// when the item completes (with its end time).
	want := []string{"message.created", "turn.started", "status", "message.created", "part.created:reasoning", "part.delta", "part.updated:reasoning", "part.created:text", "part.delta", "part.updated:text", "message.updated", "status", "turn.finished"}
	if strings.Join(order, ",") != strings.Join(want, ",") {
		t.Fatalf("event order:\n got %s\nwant %s", strings.Join(order, ","), strings.Join(want, ","))
	}
	finished := events[len(events)-1]
	if finished.TurnID != receipt.MessageID || finished.Outcome != "completed" || finished.Usage == nil || finished.Usage.Input != 100 || finished.Usage.CacheRead != 20 || finished.Usage.Output != 25 || finished.Usage.Reasoning != 5 {
		t.Fatalf("turn.finished: %s", finished.raw)
	}
	messages := client.ordered()
	if len(messages) != 2 {
		t.Fatalf("client messages: %+v", messages)
	}
	reply := messages[1]
	if reply.Role != "assistant" || reply.Status != "complete" || reply.TurnID != receipt.MessageID || reply.Model != "codex/default" || len(reply.Parts) != 2 {
		t.Fatalf("reply: %+v", reply)
	}
	if reply.Parts[0].Kind != "reasoning" || reply.Parts[0].Text != "Thinking it over." || reply.Parts[1].Kind != "text" || reply.Parts[1].Text != "Hello from the fake Codex." {
		t.Fatalf("parts: %+v", reply.Parts)
	}
	// The client's copy matches what the hub and a fresh read hold.
	f.idle(id)
	sameMessages(t, messages, hubMessages(f.host, sessionKey{"p1", id}))
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil)
	var page struct {
		Messages []ChatMessage `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &page)
	if len(page.Messages) != 2 || page.Messages[0].Parts[1].Text != "Hello from the fake Codex." || page.Messages[0].Usage == nil {
		t.Fatalf("page: %s", w.Body)
	}
	// The legacy shape: joined text and reasoning, no parts.
	legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil)
	if strings.Contains(legacy.Body.String(), `"parts"`) {
		t.Fatalf("legacy messages carry parts: %s", legacy.Body)
	}
	var body struct {
		Messages []Message `json:"messages"`
	}
	json.Unmarshal(legacy.Body.Bytes(), &body)
	if len(body.Messages) != 2 || body.Messages[0].Text != "Say hello" || body.Messages[1].Text != "Hello from the fake Codex." || len(body.Messages[1].Reasoning) != 1 || body.Messages[1].Reasoning[0].Text != "Thinking it over." {
		t.Fatalf("legacy: %s", legacy.Body)
	}
	withParts := f.call("GET", "/v1/messages?parts=1&projectId=p1&sessionId="+id, nil)
	if !strings.Contains(withParts.Body.String(), `"model":"codex/default"`) || !strings.Contains(withParts.Body.String(), `"kind":"reasoning"`) {
		t.Fatalf("legacy with parts: %s", withParts.Body)
	}
	// The thread started in the project in Ask, a new chat's mode (the
	// workspace-write sandbox, approvals asked in the chat), and the turn
	// named the host's user message.
	start := f.fake.requests("thread/start")
	if len(start) != 1 {
		t.Fatalf("thread/start: %d", len(start))
	}
	var params map[string]any
	json.Unmarshal(start[0].Params, &params)
	if params["cwd"] != f.project.Directory || params["sandbox"] != "workspace-write" || params["approvalPolicy"] != "on-request" || params["approvalsReviewer"] != "user" {
		t.Fatalf("thread/start params: %s", start[0].Params)
	}
	turns := f.fake.requests("turn/start")
	if len(turns) != 1 || !strings.Contains(string(turns[0].Params), `"clientUserMessageId":"`+receipt.MessageID+`"`) || !strings.Contains(string(turns[0].Params), `"input":[{"text":"Say hello","type":"text"}]`) {
		t.Fatalf("turn/start: %+v", turns)
	}
	if strings.Contains(string(turns[0].Params), "sandboxPolicy") {
		t.Fatalf("turn/start overrode an unchanged mode: %s", turns[0].Params)
	}
	// The handshake named the host and sent no jsonrpc member.
	initialize := f.fake.requests("initialize")
	if len(initialize) != 1 || !strings.Contains(string(initialize[0].Params), `"name":"agentland_host"`) || strings.Contains(initialize[0].raw, "jsonrpc") {
		t.Fatalf("initialize: %+v", initialize)
	}
}

func TestCodexApprovalsOfferTheAvailableDecisions(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "APPROVE this", map[string]any{"mode": "ask"})
	events := stream.until(t, "interaction.requested", 10*time.Second)
	interaction := events[len(events)-1].Interaction
	if interaction.Kind != "permission" || !reflect.DeepEqual(interaction.Choices, []string{"once", "always", "reject"}) || interaction.Permission.Tool != "Command" || interaction.Permission.Title != "touch x" || interaction.Permission.Detail != "Needs to write" || interaction.Permission.Input != "/bin/zsh -lc 'touch x'" ||
		interaction.AlwaysLabel != "Allow this command in this chat" || !strings.HasPrefix(interaction.AlwaysDetail, "Not saved: Codex forgets it") {
		t.Fatalf("interaction: %+v %+v", interaction, interaction.Permission)
	}
	status := stream.until(t, "status", 5*time.Second)
	if status[len(status)-1].State != "waiting" {
		t.Fatalf("status while waiting: %s", status[len(status)-1].raw)
	}
	// The legacy list shows the request too.
	list := f.call("GET", "/v1/interactions?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(list.Body.String(), `"id":"`+interaction.ID+`"`) || !strings.Contains(list.Body.String(), `"permission":"command"`) {
		t.Fatalf("interactions: %s", list.Body)
	}
	// A choice the request does not offer is refused; always is accepted.
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": "codex_missing", "reply": "once"}); w.Code != 404 {
		t.Fatalf("unknown request: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": interaction.ID, "reply": "always"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	events = stream.until(t, "turn.finished", 10*time.Second)
	resolved := ""
	for _, event := range events {
		if event.Type == "interaction.resolved" {
			resolved = event.ID + ":" + event.Outcome
		}
	}
	if resolved != interaction.ID+":always" || events[len(events)-1].Outcome != "completed" {
		t.Fatalf("resolution: %s %s", resolved, eventTypes(events))
	}
	decision := ""
	for _, entry := range f.fake.log() {
		if len(entry.Decision) > 0 {
			decision = string(entry.Decision)
		}
	}
	if decision != `{"decision":"acceptForSession"}` {
		t.Fatalf("decision sent to Codex: %s", decision)
	}
	// The mode picked for the message applied to the new thread.
	start := f.fake.requests("thread/start")
	if len(start) != 1 || !strings.Contains(string(start[0].Params), `"approvalsReviewer":"user"`) {
		t.Fatalf("thread/start: %+v", start)
	}
	f.idle(id)
	messages := f.messages(id)
	tools := messages[len(messages)-1].Tools
	if len(tools) != 1 || tools[0].Name != "Command" || tools[0].Status != "completed" || tools[0].Output != "done\n" {
		t.Fatalf("tool: %+v", tools)
	}
}

func TestCodexCommandDecisionsFollowTheList(t *testing.T) {
	for _, test := range []struct {
		available string
		want      map[string]string
	}{
		{`["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","x"]}},"cancel"]`, map[string]string{"once": `{"decision":"accept"}`, "always": `{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","x"]}}}`, "reject": `{"decision":"cancel"}`}},
		{`["accept","decline"]`, map[string]string{"once": `{"decision":"accept"}`, "reject": `{"decision":"decline"}`}},
		{`["acceptForSession","decline","cancel"]`, map[string]string{"always": `{"decision":"acceptForSession"}`, "reject": `{"decision":"decline"}`}},
		{`[{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"example.com","action":"allow"}}},"decline"]`, map[string]string{"always": `{"decision":{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"example.com","action":"allow"}}}}`, "reject": `{"decision":"decline"}`}},
		{``, map[string]string{"once": `{"decision":"accept"}`, "always": `{"decision":"acceptForSession"}`, "reject": `{"decision":"decline"}`}},
	} {
		var available []json.RawMessage
		json.Unmarshal([]byte(test.available), &available)
		decisions := codexCommandDecisions(available)
		got := map[string]string{}
		for choice, result := range decisions {
			got[choice] = string(marshalJSONLine(result))
		}
		if !reflect.DeepEqual(got, test.want) {
			t.Errorf("%s:\n got %v\nwant %v", test.available, got, test.want)
		}
	}
}

func TestCodexFileAndPermissionApprovals(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "FILES please", map[string]any{"mode": "ask"})
	events := stream.until(t, "interaction.requested", 10*time.Second)
	interaction := events[len(events)-1].Interaction
	if interaction.Permission.Tool != "Edit" || interaction.Permission.Title != "Edit notes/a.txt" || interaction.Permission.Input != "add notes/a.txt" || !reflect.DeepEqual(interaction.Choices, []string{"once", "always", "reject"}) {
		t.Fatalf("file approval: %+v %+v", interaction, interaction.Permission)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": interaction.ID, "reply": "once"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	events = stream.until(t, "turn.finished", 10*time.Second)
	f.idle(id)
	messages := f.messages(id)
	last := messages[len(messages)-1]
	if len(last.Tools) != 1 || last.Tools[0].Name != "Edit" || last.Tools[0].Status != "completed" || last.Tools[0].Output != "+hello\n+world\n" {
		t.Fatalf("edit tool: %+v", last.Tools)
	}
	page := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	if !strings.Contains(page.Body.String(), `"kind":"patch","ord":2,"text":"notes/a.txt"`) {
		t.Fatalf("patch part: %s", page.Body)
	}
	f.send(id, "PERMS now", nil)
	events = stream.until(t, "interaction.requested", 10*time.Second)
	interaction = events[len(events)-1].Interaction
	if interaction.Permission.Tool != "Permissions" || interaction.Permission.Input != `{"network":{"enabled":true}}` {
		t.Fatalf("permissions approval: %+v", interaction.Permission)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": id, "requestId": interaction.ID, "reply": "reject"}); w.Code != 200 {
		t.Fatalf("reject: %d %s", w.Code, w.Body)
	}
	stream.until(t, "turn.finished", 10*time.Second)
	decisions := []string{}
	for _, entry := range f.fake.log() {
		if len(entry.Decision) > 0 {
			decisions = append(decisions, string(entry.Decision))
		}
		if len(entry.Permissions) > 0 {
			decisions = append(decisions, string(entry.Permissions))
		}
	}
	if strings.Join(decisions, " ") != `{"decision":"accept"} {"permissions":{},"scope":"turn"}` {
		t.Fatalf("answers sent to Codex: %v", decisions)
	}
}

func TestCodexQuestionsKeepSecretAnswersOut(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "ASK me", nil)
	events := stream.until(t, "interaction.requested", 10*time.Second)
	question := events[len(events)-1].Interaction
	if question.Kind != "question" || len(question.Questions) != 2 {
		t.Fatalf("question: %s", events[len(events)-1].raw)
	}
	first, second := question.Questions[0], question.Questions[1]
	if first.ID != "0" || !first.Secret || !first.Custom || len(first.Options) != 0 || second.Secret || !second.Custom || len(second.Options) != 2 || second.Options[0].Label != "Red" {
		t.Fatalf("questions: %+v", question.Questions)
	}
	list := f.call("GET", "/v1/interactions?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(list.Body.String(), `"secret":true`) {
		t.Fatalf("legacy question: %s", list.Body)
	}
	// Answers are checked against the questions before they go to Codex.
	if w := f.call("POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": id, "requestId": question.ID, "answers": [][]string{{"only one"}}}); w.Code != 400 {
		t.Fatalf("short answers: %d %s", w.Code, w.Body)
	}
	secret := "s3cret-token-value"
	if w := f.call("POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": id, "requestId": question.ID, "answers": [][]string{{secret}, {"Blue"}}}); w.Code != 200 {
		t.Fatalf("answer: %d %s", w.Code, w.Body)
	}
	events = stream.until(t, "turn.finished", 10*time.Second)
	outcome := ""
	for _, event := range events {
		if event.Type == "interaction.resolved" {
			outcome = event.Outcome
		}
	}
	if outcome != "answered" {
		t.Fatalf("outcome %q", outcome)
	}
	answers := ""
	for _, entry := range f.fake.log() {
		if len(entry.Answers) > 0 {
			answers = string(entry.Answers)
		}
	}
	if answers != `{"answers":{"color":{"answers":["Blue"]},"token":{"answers":["`+secret+`"]}}}` {
		t.Fatalf("answers sent to Codex: %s", answers)
	}
	f.idle(id)
	state, err := os.ReadFile(f.store.Path + ".chats.json")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(state), secret) {
		t.Fatal("the secret answer was stored")
	}
	for _, message := range f.messages(id) {
		if strings.Contains(message.Text, secret) {
			t.Fatal("the secret answer is in the transcript")
		}
	}
	// A rejected question sends no answers.
	f.send(id, "ASK again", nil)
	events = stream.until(t, "interaction.requested", 10*time.Second)
	if w := f.call("POST", "/v1/questions/reject", map[string]any{"projectId": "p1", "sessionId": id, "requestId": events[len(events)-1].Interaction.ID}); w.Code != 200 {
		t.Fatalf("reject: %d %s", w.Code, w.Body)
	}
	stream.until(t, "turn.finished", 10*time.Second)
	for _, entry := range f.fake.log() {
		if len(entry.Answers) > 0 {
			answers = string(entry.Answers)
		}
	}
	if answers != `{"answers":{}}` {
		t.Fatalf("rejected answers: %s", answers)
	}
}

func TestCodexRefusesRequestsItDoesNotHandle(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	f.send(id, "ELICIT something", nil)
	f.idle(id)
	var elicitation, unknown string
	for _, entry := range f.fake.log() {
		if len(entry.Elicitation) > 0 {
			elicitation = string(entry.Elicitation)
		}
		if len(entry.Unknown) > 0 {
			unknown = string(entry.Unknown)
		}
	}
	if !strings.Contains(elicitation, `"code":-32601`) || !strings.Contains(unknown, `"code":-32601`) {
		t.Fatalf("answers: elicitation %s, unknown %s", elicitation, unknown)
	}
	messages := f.messages(id)
	if messages[len(messages)-1].Text != "Carried on." {
		t.Fatalf("reply: %+v", messages[len(messages)-1])
	}
}

func TestCodexStopInterruptsTheTurn(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "STALL please", nil)
	stream.until(t, "part.delta", 10*time.Second)
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("abort: %d %s", w.Code, w.Body)
	}
	events := stream.until(t, "turn.finished", 10*time.Second)
	if events[len(events)-1].Outcome != "aborted" {
		t.Fatalf("outcome: %s", events[len(events)-1].raw)
	}
	interrupts := f.fake.requests("turn/interrupt")
	turns := f.fake.requests("turn/start")
	if len(interrupts) != 1 || len(turns) != 1 {
		t.Fatalf("interrupts %d, turns %d", len(interrupts), len(turns))
	}
	var params map[string]string
	json.Unmarshal(interrupts[0].Params, &params)
	if params["threadId"] != "thread-1" || params["turnId"] != "turn-1" {
		t.Fatalf("turn/interrupt params: %s", interrupts[0].Params)
	}
	f.idle(id)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(w.Body.String(), `"status":"aborted"`) || !strings.Contains(w.Body.String(), `"text":"Working"`) {
		t.Fatalf("stopped reply: %s", w.Body)
	}
}

func TestCodexFailedTurnRetriesThenFails(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "FAIL please", nil)
	events := stream.until(t, "turn.finished", 10*time.Second)
	states := []string{}
	for _, event := range events {
		if event.Type == "status" {
			states = append(states, event.State)
		}
	}
	if strings.Join(states, ",") != "running,retry,error" && strings.Join(states, ",") != "running,retry,running,error" {
		t.Fatalf("states: %v (%s)", states, eventTypes(events))
	}
	if events[len(events)-1].Outcome != "error" {
		t.Fatalf("outcome: %s", events[len(events)-1].raw)
	}
	f.idle(id)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(w.Body.String(), `"error":{"code":"provider_auth","message":"fake provider refused"}`) {
		t.Fatalf("failed reply: %s", w.Body)
	}
	messages := f.messages(id)
	if messages[len(messages)-1].Error != "fake provider refused" {
		t.Fatalf("legacy error: %+v", messages[len(messages)-1])
	}
}

func TestCodexToolsNoticesAndUnknownItems(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	f.send(id, "TOOLS please", nil)
	f.idle(id)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	var page struct {
		Messages []ChatMessage `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &page)
	parts := page.Messages[0].Parts
	summary := []string{}
	for _, part := range parts {
		switch part.Kind {
		case "tool":
			summary = append(summary, "tool:"+part.Tool.Name+":"+part.Tool.Status+":"+part.Tool.Output)
		default:
			summary = append(summary, part.Kind+":"+part.Text)
		}
	}
	want := []string{
		"tool:docs.search:completed:found it",
		"tool:WebSearch:completed:",
		"tool:Plan:completed:[x] Read\n[~] Write",
		"notice:The conversation was compacted to fit the model's context.",
		"notice:Model metadata not found",
		"notice:Auto-review denied: rm -rf /tmp/x\nToo risky",
		"text:Tools done.",
	}
	if strings.Join(summary, "|") != strings.Join(want, "|") {
		t.Fatalf("parts:\n got %q\nwant %q", summary, want)
	}
}

func TestCodexLongOutputsAreBounded(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	f.send(id, "OUT please", nil)
	f.idle(id)
	many := f.newChat()
	f.send(many, "MANY please", nil)
	f.idle(many)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	var page struct {
		Messages []ChatMessage `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &page)
	tool := page.Messages[0].Parts[0].Tool
	if len(tool.Output) != chatToolFieldLimit || !tool.Truncated || tool.Status != "error" || tool.Error != "The command exited with code 1." {
		t.Fatalf("bounded output: %d bytes, truncated %v, %s %q", len(tool.Output), tool.Truncated, tool.Status, tool.Error)
	}
	// 300 items and a reply: the turn continues in a second message.
	w = f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+many, nil)
	json.Unmarshal(w.Body.Bytes(), &page)
	if len(page.Messages) != 3 || len(page.Messages[1].Parts) != chatPartsPerMessage || len(page.Messages[0].Parts) != 301-chatPartsPerMessage || page.Messages[0].TurnID != page.Messages[2].ID || page.Messages[1].TurnID != page.Messages[2].ID {
		t.Fatalf("rollover: %d messages", len(page.Messages))
	}
	if page.Messages[0].Status != "complete" || page.Messages[1].Status != "complete" {
		t.Fatalf("rollover status: %s %s", page.Messages[1].Status, page.Messages[0].Status)
	}
}

func TestCodexSkipsAnOversizedLine(t *testing.T) {
	f := newCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	f.send(id, "BIG line", nil)
	f.idle(id)
	messages := f.messages(id)
	if messages[len(messages)-1].Text != "After the big line." {
		t.Fatalf("reply after an oversized line: %+v", messages[len(messages)-1])
	}
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	if !strings.Contains(w.Body.String(), "too large to show") {
		t.Fatalf("no notice of the skipped line: %s", w.Body)
	}
}

func TestCodexCrashEndsTheTurnAndRestartsWithBackoff(t *testing.T) {
	fake := newCodexFake(t, "AGENTLAND_CODEX_FAKE_STDERR=1")
	f := newCodexFixture(t, fake)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "CRASH now", nil)
	events := stream.until(t, "turn.finished", 10*time.Second)
	if events[len(events)-1].Outcome != "error" {
		t.Fatalf("crashed turn: %s", events[len(events)-1].raw)
	}
	f.idle(id)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	if !strings.Contains(w.Body.String(), "Codex stopped before this reply completed.") || !strings.Contains(w.Body.String(), `"text":"Partial"`) {
		t.Fatalf("crashed reply: %s", w.Body)
	}
	// The crash is logged with the end of Codex's stderr, bounded.
	logs := fake.diagnostics()
	if len(logs) != 1 || !strings.HasPrefix(logs[0], "codex app-server exited unexpectedly: noise") || len(logs[0]) > 3<<10 {
		t.Fatalf("diagnostics: %d %q", len(logs), logs)
	}
	// The next message starts Codex again, no sooner than the first backoff
	// step after the crash, and resumes the thread before the turn.
	f.chats.codex.mu.Lock()
	nextStart := f.chats.codex.nextStart
	f.chats.codex.mu.Unlock()
	f.send(id, "Hello again", nil)
	f.idle(id)
	if fake.starts() != 2 {
		t.Fatalf("starts: %d", fake.starts())
	}
	starts := []int64{}
	for _, entry := range fake.log() {
		if entry.Start != 0 {
			starts = append(starts, entry.At)
		}
	}
	if nextStart.IsZero() || len(starts) != 2 || starts[1] < nextStart.UnixMilli() {
		t.Fatalf("restart at %v, backoff until %v", starts, nextStart.UnixMilli())
	}
	resumes := fake.requests("thread/resume")
	if len(resumes) != 1 || !strings.Contains(string(resumes[0].Params), `"threadId":"thread-1"`) || !strings.Contains(string(resumes[0].Params), `"excludeTurns":true`) {
		t.Fatalf("resume: %+v", resumes)
	}
	if messages := f.messages(id); messages[len(messages)-1].Text != "Hello from the fake Codex." {
		t.Fatalf("after restart: %+v", messages[len(messages)-1])
	}
}

func TestCodexBackoffSteps(t *testing.T) {
	config := codexEngineConfig{}
	got := []time.Duration{}
	for crashes := 0; crashes < 5; crashes++ {
		got = append(got, config.backoffAt(crashes))
	}
	if !reflect.DeepEqual(got, []time.Duration{time.Second, 5 * time.Second, 30 * time.Second, 30 * time.Second, 30 * time.Second}) {
		t.Fatalf("backoff: %v", got)
	}
	// A start waits out the backoff.
	fake := newCodexFake(t)
	engine := newCodexEngine(&CLIChats{records: map[string]*cliChatRecord{}}, fake.config())
	defer engine.close()
	engine.nextStart = time.Now().Add(300 * time.Millisecond)
	started := time.Now()
	if _, err := engine.connection(); err != nil {
		t.Fatal(err)
	}
	if waited := time.Since(started); waited < 250*time.Millisecond {
		t.Fatalf("started after %v", waited)
	}
}

func TestCodexAdoptsExternallyReplacedExecutableWhenIdle(t *testing.T) {
	fake := newCodexFake(t)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	first := writeScript(t, filepath.Join(dir, "codex-one"), "exec '"+self+"' \"$@\"\n")
	second := writeScript(t, filepath.Join(dir, "codex-two"), "exec '"+self+"' \"$@\"\n")
	command := filepath.Join(dir, "codex")
	if err := os.Symlink(first, command); err != nil {
		t.Fatal(err)
	}
	config := fake.config()
	config.executable = func() (string, bool) { return command, true }
	config.idleCheck = 10 * time.Millisecond
	config.idleStop = time.Hour
	engine := newCodexEngine(&CLIChats{records: map[string]*cliChatRecord{}, processes: newAgentProcesses()}, config)
	defer engine.close()
	if _, err := engine.connection(); err != nil {
		t.Fatal(err)
	}
	engine.mu.Lock()
	original := engine.conn
	engine.mu.Unlock()
	engine.hold()
	replacement := filepath.Join(dir, "next")
	if err := os.Symlink(second, replacement); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, command); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	engine.mu.Lock()
	duringWork := engine.conn
	engine.mu.Unlock()
	if duringWork != original || original.exited() {
		t.Fatal("the replaced executable interrupted active Codex work")
	}
	engine.release()
	waitFor(t, "the idle app-server to adopt the replacement", func() bool {
		engine.mu.Lock()
		defer engine.mu.Unlock()
		return engine.conn == nil
	})
	if _, err := engine.connection(); err != nil {
		t.Fatal(err)
	}
	if fake.starts() != 2 {
		t.Fatalf("app-server starts: %d", fake.starts())
	}
}

func TestCodexUncertainDeliveryIsNeverResent(t *testing.T) {
	fake := newCodexFake(t)
	f := newCodexFixture(t, fake)
	id := f.newChat()
	receipt := f.send(id, "CRASHSTART now", map[string]any{"clientMessageId": "0123456789abcdef0123456789abcdef"})
	f.idle(id)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(w.Body.String(), `"code":"delivery_uncertain"`) {
		t.Fatalf("uncertain reply: %s", w.Body)
	}
	repeat := f.send(id, "CRASHSTART now", map[string]any{"clientMessageId": "0123456789abcdef0123456789abcdef"})
	if !repeat.Duplicate || repeat.MessageID != receipt.MessageID {
		t.Fatalf("repeat: %+v", repeat)
	}
	if turns := fake.requests("turn/start"); len(turns) != 1 {
		t.Fatalf("turn/start sent %d times", len(turns))
	}
}

func TestCodexCompatibilityModeDropsMissingFeatures(t *testing.T) {
	fake := newCodexFake(t, "AGENTLAND_CODEX_FAKE_VERSION=0.200.0", "AGENTLAND_CODEX_FAKE_MISSING=thread/fork,model/list")
	f := newCodexFixture(t, fake)
	id := f.newChat()
	f.send(id, "Hello", nil)
	f.idle(id)
	entry := f.host.advertisedCapabilities().ChatProviderInfo.Codex
	if entry.Version != "0.200.0" || entry.Transport != "app-server" || !reflect.DeepEqual(entry.Features, []string{"rewind", "fork", "approvals", "modes", "effort"}) {
		t.Fatalf("before: %+v", entry)
	}
	options := f.call("GET", "/v1/chat/options?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(options.Body.String(), `"models":[{"id":"codex/default"`) || strings.Contains(options.Body.String(), "fake-large") {
		t.Fatalf("options without model/list: %s", options.Body)
	}
	if w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 501 {
		t.Fatalf("fork without thread/fork: %d %s", w.Code, w.Body)
	}
	entry = f.host.advertisedCapabilities().ChatProviderInfo.Codex
	if !reflect.DeepEqual(entry.Features, []string{"rewind", "approvals", "modes", "effort"}) {
		t.Fatalf("after: %+v", entry)
	}
}

func TestCodexHandshakeFailureFallsBackToExec(t *testing.T) {
	fake := newCodexFake(t, "AGENTLAND_CODEX_FAKE_FAIL_HANDSHAKE=1")
	f := newCodexFixture(t, fake)
	id := f.newChat()
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	receipt := f.send(id, "First over exec", nil)
	events := stream.until(t, "turn.finished", 10*time.Second)
	if events[len(events)-1].Outcome != "completed" || events[len(events)-1].TurnID != receipt.MessageID {
		t.Fatalf("exec turn: %s", events[len(events)-1].raw)
	}
	f.idle(id)
	f.send(id, "Second over exec", map[string]any{"model": "codex/fake-large", "effort": "high"})
	f.idle(id)
	runs := []fakeEntry{}
	for _, entry := range fake.log() {
		if len(entry.Exec) > 0 {
			runs = append(runs, entry)
		}
	}
	if len(runs) != 2 {
		t.Fatalf("exec runs: %d", len(runs))
	}
	directory := f.project.Directory
	wantNew := "exec --json --skip-git-repo-check --approve-for-me -C " + directory + ` -c forced_login_method="chatgpt" -`
	wantResume := `exec resume --json --skip-git-repo-check -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review" -m fake-large -c model_reasoning_effort="high" -c forced_login_method="chatgpt" exec-thread-1 -`
	if got := strings.Join(runs[0].Exec, " "); got != wantNew {
		t.Fatalf("new run:\n got %s\nwant %s", got, wantNew)
	}
	if got := strings.Join(runs[1].Exec, " "); got != wantResume {
		t.Fatalf("resumed run:\n got %s\nwant %s", got, wantResume)
	}
	for _, run := range runs {
		if !sameDirectory(run.Cwd, directory) {
			t.Fatalf("exec ran in %s, not the project", run.Cwd)
		}
	}
	if runs[0].Stdin != "First over exec" {
		t.Fatalf("stdin: %q", runs[0].Stdin)
	}
	entry := f.host.advertisedCapabilities().ChatProviderInfo.Codex
	if entry.Transport != "exec" || !reflect.DeepEqual(entry.Features, []string{"modes", "effort"}) {
		t.Fatalf("capabilities: %+v", entry)
	}
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	var page struct {
		Messages []ChatMessage `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &page)
	reply := page.Messages[0]
	kinds := []string{}
	for _, part := range reply.Parts {
		kinds = append(kinds, part.Kind)
	}
	if strings.Join(kinds, ",") != "notice,reasoning,tool,tool,patch,text" || reply.Parts[5].Text != "Exec reply: Second over exec" || reply.Usage == nil || reply.Usage.Input != 0 || reply.Usage.Output != 0 {
		// The second run reports the same thread total as the first, so its
		// own use is zero.
		t.Fatalf("exec reply: %s %+v", strings.Join(kinds, ","), reply.Usage)
	}
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": receipt.MessageID}); w.Code != 400 {
		t.Fatalf("rewind over exec: %d %s", w.Code, w.Body)
	}
	options := f.call("GET", "/v1/chat/options?projectId=p1&sessionId="+id, nil)
	if strings.Contains(options.Body.String(), `"id":"ask"`) || !strings.Contains(options.Body.String(), `"id":"auto-review"`) {
		t.Fatalf("exec modes: %s", options.Body)
	}
}

func TestCodexExecReadsLongLinesAndStops(t *testing.T) {
	fake := newCodexFake(t)
	config := fake.config()
	config.execOnly = true
	f := newCodexFixtureWith(t, fake, config)
	id := f.newChat()
	f.send(id, "HUGE output", nil)
	f.idle(id)
	w := f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	var page struct {
		Messages []ChatMessage `json:"messages"`
	}
	json.Unmarshal(w.Body.Bytes(), &page)
	reply := page.Messages[0]
	texts := []string{}
	for _, part := range reply.Parts {
		if part.Kind == "text" {
			texts = append(texts, fmt.Sprint(len(part.Text), part.Truncated))
		}
	}
	// The 5 MiB line is read (and bounded to 512 KiB); the 9 MiB line is
	// skipped with a notice; the final reply arrives.
	if reply.Status != "complete" || strings.Join(texts, " ") != fmt.Sprint(chatTextLimit, " true ", len("Exec reply: HUGE output"), " false") || !strings.Contains(w.Body.String(), "too large to show") {
		t.Fatalf("long lines: %s %v", reply.Status, texts)
	}
	// Stop ends the exec process group.
	f.send(id, "EXECSTALL now", nil)
	waitFor(t, "the exec run", func() bool {
		for _, entry := range fake.log() {
			if strings.Contains(entry.Stdin, "EXECSTALL") {
				return true
			}
		}
		return false
	})
	started := time.Now()
	if w := f.call("POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 {
		t.Fatalf("abort: %d %s", w.Code, w.Body)
	}
	f.idle(id)
	if time.Since(started) > 5*time.Second {
		t.Fatal("stop took too long")
	}
	w = f.call("GET", "/v1/chat/messages?projectId=p1&sessionId="+id+"&limit=1", nil)
	if !strings.Contains(w.Body.String(), `"status":"aborted"`) {
		t.Fatalf("stopped exec reply: %s", w.Body)
	}
	f.send(id, "EXECFAIL now", nil)
	f.idle(id)
	if messages := f.messages(id); messages[len(messages)-1].Error != "fake provider refused" {
		t.Fatalf("failed exec: %+v", messages[len(messages)-1])
	}
}

func TestCodexExecArguments(t *testing.T) {
	image := ChatAttachment{Path: "/state/att_1.png", Name: "a.png", MIME: "image/png"}
	comma := ChatAttachment{Path: "/odd,dir/att_2.png", Name: "b.png", MIME: "image/png"}
	pdf := ChatAttachment{Path: "/state/att_3.pdf", Name: "c.pdf", MIME: "application/pdf"}
	for _, test := range []struct {
		thread   string
		settings codexSettings
		files    []ChatAttachment
		want     string
		listed   int
	}{
		{"", codexSettings{mode: "auto-review"}, nil, `exec --json --skip-git-repo-check --approve-for-me -C /repo -c forced_login_method="chatgpt" -`, 0},
		{"t1", codexSettings{mode: "auto-review"}, nil, `exec resume --json --skip-git-repo-check -c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review" -c forced_login_method="chatgpt" t1 -`, 0},
		{"", codexSettings{mode: "read-only", model: "m1", effort: "low"}, []ChatAttachment{image, comma, pdf}, `exec -i /state/att_1.png --json --skip-git-repo-check -c sandbox_mode="read-only" -c approval_policy="never" -C /repo -m m1 -c model_reasoning_effort="low" -c forced_login_method="chatgpt" -`, 2},
		{"t1", codexSettings{mode: "full-access"}, []ChatAttachment{image}, `exec resume -i /state/att_1.png --json --skip-git-repo-check -c sandbox_mode="danger-full-access" -c approval_policy="never" -c forced_login_method="chatgpt" t1 -`, 0},
		{"", codexSettings{mode: "ask"}, nil, `exec --json --skip-git-repo-check --approve-for-me -C /repo -c forced_login_method="chatgpt" -`, 0},
	} {
		args, listed := codexExecArgs("/repo", test.thread, test.files, test.settings, nil)
		if strings.Join(args, " ") != test.want || len(listed) != test.listed {
			t.Errorf("%+v:\n got %s (%d listed)\nwant %s", test.settings, strings.Join(args, " "), len(listed), test.want)
		}
	}
}

func TestCodexRewindHidesThenRevertsOnSend(t *testing.T) {
	fake := newCodexFake(t)
	f := newCodexFixture(t, fake)
	id := f.newChat()
	first := f.send(id, "First", nil)
	f.idle(id)
	second := f.send(id, "Second", nil)
	f.idle(id)
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	// Only the latest message can be rewound.
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": first.MessageID}); w.Code != 400 {
		t.Fatalf("older message: %d %s", w.Code, w.Body)
	}
	w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": second.MessageID})
	if w.Code != 200 || w.Body.String() != `{"filesRestore":"unavailable","rewound":true}`+"\n" {
		t.Fatalf("rewind: %d %s", w.Code, w.Body)
	}
	events := stream.until(t, "snapshot", 5*time.Second)
	snapshot := events[len(events)-1]
	if snapshot.Rewind == nil || snapshot.Rewind.MessageID != second.MessageID || len(snapshot.Messages) != 2 {
		t.Fatalf("rewound snapshot: %s", snapshot.raw)
	}
	legacy := f.call("GET", "/v1/messages?projectId=p1&sessionId="+id, nil)
	if !strings.Contains(legacy.Body.String(), `"rewind":{"messageId":"`+second.MessageID+`"}`) || strings.Contains(legacy.Body.String(), "Second") {
		t.Fatalf("legacy while rewound: %s", legacy.Body)
	}
	if len(fake.requests("thread/revert")) != 0 {
		t.Fatal("thread/revert before the next send")
	}
	// Restore brings the messages back; nothing is sent to Codex.
	if w := f.call("POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": id}); w.Code != 200 || !strings.Contains(w.Body.String(), `"filesRestore":"unavailable"`) {
		t.Fatalf("restore: %d %s", w.Code, w.Body)
	}
	if messages := f.messages(id); len(messages) != 4 {
		t.Fatalf("restored: %d messages", len(messages))
	}
	// Rewind again and send the edit: Codex drops the old turn first.
	if w := f.call("POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": id, "messageId": second.MessageID}); w.Code != 200 {
		t.Fatalf("rewind again: %d %s", w.Code, w.Body)
	}
	f.send(id, "Second, edited", nil)
	f.idle(id)
	reverts := fake.requests("thread/revert")
	if len(reverts) != 1 || string(reverts[0].Params) != `{"beforeTurnId":"turn-2","threadId":"thread-1"}` {
		t.Fatalf("thread/revert: %+v", reverts)
	}
	log := fake.log()
	revertAt, turnAt := -1, -1
	for index, entry := range log {
		if entry.Method == "thread/revert" {
			revertAt = index
		}
		if entry.Method == "turn/start" && strings.Contains(string(entry.Params), "Second, edited") {
			turnAt = index
		}
	}
	if revertAt < 0 || turnAt < revertAt {
		t.Fatalf("revert %d, turn %d", revertAt, turnAt)
	}
	messages := f.messages(id)
	if len(messages) != 4 || messages[2].Text != "Second, edited" {
		t.Fatalf("after the edit: %+v", messages)
	}
}

func TestCodexForkCopiesThroughATurn(t *testing.T) {
	fake := newCodexFake(t)
	f := newCodexFixture(t, fake)
	id := f.newChat()
	first := f.send(id, "First", nil)
	f.idle(id)
	f.send(id, "Second", nil)
	f.idle(id)
	w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "messageId": first.MessageID, "title": "Branch"})
	if w.Code != 201 {
		t.Fatalf("fork: %d %s", w.Code, w.Body)
	}
	var forked Session
	json.Unmarshal(w.Body.Bytes(), &forked)
	if forked.Title != "Branch" || forked.ParentSessionID != id || !strings.HasPrefix(forked.ID, "codex:") || forked.ProjectID != "p1" {
		t.Fatalf("forked: %s", w.Body)
	}
	forks := fake.requests("thread/fork")
	if len(forks) != 1 || !strings.Contains(string(forks[0].Params), `"lastTurnId":"turn-1"`) || !strings.Contains(string(forks[0].Params), `"threadId":"thread-1"`) || !strings.Contains(string(forks[0].Params), `"excludeTurns":true`) {
		t.Fatalf("thread/fork: %+v", forks)
	}
	copied := f.messages(forked.ID)
	if len(copied) != 2 || copied[0].Text != "First" || copied[1].Text != "Hello from the fake Codex." {
		t.Fatalf("copied: %+v", copied)
	}
	// The fork runs on its own thread.
	f.send(forked.ID, "In the branch", nil)
	f.idle(forked.ID)
	turns := fake.requests("turn/start")
	if last := turns[len(turns)-1]; !strings.Contains(string(last.Params), `"threadId":"thread-2"`) {
		t.Fatalf("branch turn: %s", last.Params)
	}
	if original := f.messages(id); len(original) != 4 {
		t.Fatalf("original changed: %d", len(original))
	}
}

func TestCodexOptionsModelsAndModes(t *testing.T) {
	fake := newCodexFake(t)
	f := newCodexFixture(t, fake)
	id := f.newChat()
	w := f.call("GET", "/v1/chat/options?projectId=p1&sessionId="+id, nil)
	var options ChatOptions
	json.Unmarshal(w.Body.Bytes(), &options)
	if len(options.Models) != 2 || options.Models[1].ID != "codex/fake-large" || !reflect.DeepEqual(options.Models[1].Efforts, []string{"low", "medium", "high"}) || options.Models[1].DefaultEffort != "medium" || options.DefaultMode != "ask" || len(options.Modes) != 4 || options.Modes[0].ID != "ask" || options.Modes[0].Name != "Ask" || options.Modes[1].ID != "auto-review" {
		t.Fatalf("options: %s", w.Body)
	}
	if w := f.call("GET", "/v1/chat/options?projectId=p1&provider=codex", nil); !strings.Contains(w.Body.String(), `"codex/fake-large"`) {
		t.Fatalf("options for a new chat: %s", w.Body)
	}
	// Invalid settings are refused before anything is sent.
	for _, body := range []map[string]any{{"mode": "sideways"}, {"effort": "Very High"}, {"model": "other/model"}} {
		payload := map[string]any{"projectId": "p1", "sessionId": id, "text": "x"}
		for key, value := range body {
			payload[key] = value
		}
		if w := f.call("POST", "/v1/messages", payload); w.Code != 400 {
			t.Fatalf("%v: %d %s", body, w.Code, w.Body)
		}
	}
	stream := f.stream(id)
	stream.until(t, "snapshot", 5*time.Second)
	f.send(id, "Hello", nil)
	f.idle(id)
	f.send(id, "Deeper", map[string]any{"model": "codex/fake-large", "mode": "read-only", "effort": "high"})
	events := stream.until(t, "chat.updated", 10*time.Second)
	updated := events[len(events)-1]
	if !strings.Contains(updated.raw, `"model":"codex/fake-large"`) || !strings.Contains(updated.raw, `"mode":"read-only"`) || !strings.Contains(updated.raw, `"effort":"high"`) {
		t.Fatalf("chat.updated: %s", updated.raw)
	}
	f.idle(id)
	turns := fake.requests("turn/start")
	var params map[string]any
	json.Unmarshal(turns[1].Params, &params)
	if params["model"] != "fake-large" || params["effort"] != "high" || params["approvalPolicy"] != "on-request" || params["approvalsReviewer"] != "user" || !reflect.DeepEqual(params["sandboxPolicy"], map[string]any{"type": "readOnly"}) {
		t.Fatalf("turn/start with new settings: %s", turns[1].Params)
	}
	// The next turn keeps the settings without overriding the mode again.
	f.send(id, "Again", nil)
	f.idle(id)
	turns = fake.requests("turn/start")
	if last := string(turns[2].Params); strings.Contains(last, "sandboxPolicy") || !strings.Contains(last, `"model":"fake-large"`) {
		t.Fatalf("third turn: %s", last)
	}
	snapshot := f.stream(id).until(t, "snapshot", 5*time.Second)
	if chat := snapshot[len(snapshot)-1].Chat; chat.Model != "codex/fake-large" || chat.Mode != "read-only" || chat.Effort != "high" {
		t.Fatalf("snapshot chat: %+v", chat)
	}
	// OpenCode chats do not take a mode or effort yet.
	if w := f.call("POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "x", "mode": "ask"}); w.Code != 400 && w.Code != 404 {
		t.Fatalf("OpenCode mode: %d %s", w.Code, w.Body)
	}
}

func TestCodexIdleStopAndLoadedThreadLimit(t *testing.T) {
	fake := newCodexFake(t)
	config := fake.config()
	config.maxThreads = 2
	config.idleStop = 300 * time.Millisecond
	f := newCodexFixtureWith(t, fake, config)
	chats := []string{f.newChat(), f.newChat(), f.newChat()}
	for _, id := range chats {
		f.send(id, "Hello", nil)
		f.idle(id)
	}
	unsubscribed := fake.requests("thread/unsubscribe")
	if len(unsubscribed) != 1 || !strings.Contains(string(unsubscribed[0].Params), `"threadId":"thread-1"`) {
		t.Fatalf("unsubscribe: %+v", unsubscribed)
	}
	// Idle, the app-server stops; the next message starts it again and
	// resumes the thread.
	waitFor(t, "the idle stop", func() bool {
		f.chats.codex.mu.Lock()
		defer f.chats.codex.mu.Unlock()
		return f.chats.codex.conn == nil
	})
	f.send(chats[2], "After idle", nil)
	f.idle(chats[2])
	if fake.starts() != 2 {
		t.Fatalf("starts: %d", fake.starts())
	}
	resumes := fake.requests("thread/resume")
	if len(resumes) != 1 || !strings.Contains(string(resumes[0].Params), `"threadId":"thread-3"`) {
		t.Fatalf("resume after idle: %+v", resumes)
	}
}

func TestCodexStderrIsBounded(t *testing.T) {
	ring := newCodexRing(codexStderrRing)
	for index := 0; index < 5000; index++ {
		fmt.Fprintf(ring, "line %d\n", index)
	}
	tail := ring.tail()
	if len(tail) > codexStderrRing || !strings.HasSuffix(tail, "line 4999\n") {
		t.Fatalf("ring: %d bytes", len(tail))
	}
	ring.Write([]byte(strings.Repeat("x", 3*codexStderrRing)))
	if len(ring.tail()) != codexStderrRing {
		t.Fatalf("ring after a large write: %d", len(ring.tail()))
	}
}

func TestCodexLineReaderSkipsOversizedLines(t *testing.T) {
	input := "short\n" + strings.Repeat("a", 100) + "\nnext\r\nlast"
	reader := newCodexLineReader(strings.NewReader(input), 50)
	var got []string
	for {
		line, skipped, err := reader.next()
		if skipped > 0 {
			got = append(got, fmt.Sprintf("skipped %d", skipped))
			continue
		}
		if err != nil {
			break
		}
		got = append(got, string(line))
	}
	if strings.Join(got, "|") != "short|skipped 101|next|last" {
		t.Fatalf("lines: %q", got)
	}
}

func TestCodexVersionFromUserAgent(t *testing.T) {
	for agent, want := range map[string]string{
		"agentland_host/0.156.1 (Mac OS 26.4.1; arm64) Apple_Terminal/470 (agentland_host; 0.0.1)": "0.156.1",
		"codex_cli_rs/0.157.0-alpha.2 (Linux)":                                                     "0.157.0-alpha.2",
		"no version":                                                                               "",
	} {
		if got := codexVersionFromUserAgent(agent); got != want {
			t.Errorf("%q: %q", agent, got)
		}
	}
	for version, tested := range map[string]bool{"0.156.1": true, "0.156.9": true, "0.157.0": false, "0.161.9": false,
		"0.162.1": true, "0.163.0": true, "0.170.2": true, "1.0.0": false, "": false} {
		if codexTestedVersion(version) != tested {
			t.Errorf("tested range: %q", version)
		}
	}
}

func TestCodexRecordsSurviveARestartOfTheHost(t *testing.T) {
	fake := newCodexFake(t)
	f := newCodexFixture(t, fake)
	id := f.newChat()
	f.send(id, "Remember me", map[string]any{"mode": "ask", "effort": "low"})
	f.idle(id)
	restored, err := NewCLIChats(f.store.Path+".chats.json", codexTestRunner{config: fake.config()})
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	load, err := restored.codex.load(f.project, id, 40)
	if err != nil {
		t.Fatal(err)
	}
	if load.info.Mode != "ask" || load.info.Effort != "low" || len(load.messages) != 2 || load.messages[1].Parts[1].Text != "Hello from the fake Codex." {
		t.Fatalf("restored: %+v %+v", load.info, load.messages)
	}
	data, _ := os.ReadFile(filepath.Join(filepath.Dir(f.store.Path), "host.json.chats.json"))
	if !strings.Contains(string(data), `"turns":{`) {
		t.Fatalf("turn IDs are not kept: %s", data)
	}
}
