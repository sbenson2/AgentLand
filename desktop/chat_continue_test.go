//go:build darwin || linux

package host

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"agentland/host/internal/localterm"
)

// Continuing a chat in a new one (chat_continue.go): `agentland-host chats
// continue`, run by a Claude Code chat's tool, asks on the private local
// socket; the host starts a new Claude Code chat in the same workspace with
// the old one's title and settings and the prompt as its first message,
// records where the old chat continued, then stops the old chat's reply and
// process. The CLI's side is tested in internal/termrun and
// cmd/agentland-host.

// continueChatOn sends one chat continue to the host's local socket and
// reads its one answer (continueOn).
func continueChatOn(t *testing.T, path string, request localterm.Request) localterm.Reply {
	t.Helper()
	request.Op = localterm.OpContinueChat
	return continueOn(t, path, request)
}

// workingTurn is a turn that waits for its Bash approval (perm-1), then
// ends: the old chat's turn, still running while its tool runs the command.
func workingTurn() []any {
	return []any{
		step(map[string]any{"do": "user", "echo": true}),
		askLine("perm-1", `{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"agentland-host chats continue -- go on"},"tool_use_id":"toolu_1"}`),
		awaitLine("perm-1"),
		resultLine("success", false, 0.001, ""),
	}
}

// userFrameText is the text of the first prompt the n-th start read.
func (f *claudeFixture) userFrameText(n int) string {
	f.t.Helper()
	for _, frame := range f.frames(n) {
		if frame["type"] != "user" {
			continue
		}
		message, _ := frame["message"].(map[string]any)
		content, _ := message["content"].([]any)
		if len(content) > 0 {
			block, _ := content[0].(map[string]any)
			text, _ := block["text"].(string)
			return text
		}
	}
	return ""
}

// untilLine reads the stream until a line holds want.
func (s *streamReader) untilLine(t *testing.T, want string, within time.Duration) streamEvent {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		if event := s.next(t, time.Until(deadline)); strings.Contains(event.raw, want) {
			return event
		}
	}
}

func TestChatContinueStartsANewChatInTheSameWorkspace(t *testing.T) {
	f := newClaudeFixture(t, nil)
	path := localListener(t, f.host)
	f.host.chatContinueWait = 10 * time.Second
	f.script(1, step(map[string]any{"do": "init"}), workingTurn())
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "Reading it.", "", 0.001))
	w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": "Claude Code chat", "provider": "claude", "model": "claude/sonnet", "mode": "acceptEdits", "effort": "high"})
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	var created Session
	json.Unmarshal(w.Body.Bytes(), &created)
	old := created.ID
	stream := f.stream(old)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(old, "Fix the login redirect on safari", nil)
	stream.until(t, "interaction.requested", 10*time.Second)
	named, err := f.host.session(f.project, old)
	if err != nil || named.TitleSource != titleAuto {
		t.Fatalf("the old chat's name: %+v %v", named, err)
	}

	prompt := "Read HANDOFF.md and finish the redirect fix"
	reply := continueChatOn(t, path, localterm.Request{Chat: old, Prompt: "  " + prompt + " "})
	if reply.Error != nil || !isClaudeSessionID(reply.ID) || reply.ID == old {
		t.Fatalf("reply %+v %+v", reply, reply.Error)
	}
	next := reply.ID

	// The new chat: same workspace, same title kept as its creator's, the
	// old chat's model, mode and effort, and the prompt as its first message.
	s, err := f.host.session(f.project, next)
	if err != nil || s.ProjectID != "p1" || s.Title != named.Title || s.TitleSource != titleProvider {
		t.Fatalf("new chat %+v %v", s, err)
	}
	chat := f.chatState(next)
	chat.mu.Lock()
	model, mode, effort := chat.rec.Model, chat.rec.Mode, chat.rec.Effort
	chat.mu.Unlock()
	if model != "sonnet" || mode != "acceptEdits" || effort != "high" {
		t.Fatalf("settings %q %q %q", model, mode, effort)
	}
	if got := f.userFrameText(2); got != prompt {
		t.Fatalf("first message %q", got)
	}
	if args := f.argv(2); argValue(args, "--model") != "sonnet" || argValue(args, "--permission-mode") != "acceptEdits" || argValue(args, "--effort") != "high" {
		t.Fatalf("new chat's argv %q", args)
	}
	f.waitIdle(next)
	if s, _ := f.host.session(f.project, next); s.Title != named.Title || s.TitleSource != titleProvider {
		t.Fatalf("the new chat was renamed after its reply: %+v", s)
	}

	// The old chat names the new one: at once to its followers, in its
	// snapshot and in its saved record.
	event := stream.untilLine(t, `"continuedIn":"`+next+`"`, 5*time.Second)
	var updated struct{ Type, ContinuedIn, ContinuedAt string }
	json.Unmarshal([]byte(event.raw), &updated)
	at, err := time.Parse(time.RFC3339Nano, updated.ContinuedAt)
	if updated.Type != "chat.updated" || err != nil || time.Since(at) > time.Minute || !strings.HasSuffix(updated.ContinuedAt, "Z") || len(updated.ContinuedAt) != len("2026-10-26T10:00:00.000Z") {
		t.Fatalf("chat.updated %s", event.raw)
	}
	again := f.stream(old)
	if snapshot := again.until(t, "snapshot", 5*time.Second); snapshot[len(snapshot)-1].Chat.ContinuedIn != next || snapshot[len(snapshot)-1].Chat.ContinuedAt != updated.ContinuedAt {
		t.Fatalf("snapshot %s", snapshot[len(snapshot)-1].raw)
	}
	registry, _ := os.ReadFile(f.store.Path + ".chats.json")
	if !strings.Contains(string(registry), `"continuedIn":"`+next+`"`) || !strings.Contains(string(registry), `"continuedAt":"`+updated.ContinuedAt+`"`) {
		t.Fatal("the continuation is not in the old chat's record")
	}

	// The old turn ends on its own within the wait: nothing interrupts it,
	// and its process stops.
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": old, "requestId": "perm-1", "reply": "once"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	if rest := stream.until(t, "turn.finished", 10*time.Second); rest[len(rest)-1].Outcome != "completed" {
		t.Fatalf("old turn: %s", rest[len(rest)-1].raw)
	}
	waitFor(t, "the old chat's process to stop", func() bool { return !f.live(old) })
	if controls := strings.Join(f.controls(1), ","); strings.Contains(controls, "interrupt") {
		t.Fatalf("the old turn was interrupted: %s", controls)
	}

	// The old chat stays usable: a send starts its process again.
	f.script(3, step(map[string]any{"do": "init"}), textTurn("msg_3", "Still here.", "", 0.001))
	f.mustSend(old, "one more thing", nil)
	f.waitIdle(old)
	if f.started() != 3 {
		t.Fatalf("starts: %d", f.started())
	}
}

// A turn that does not end on its own is stopped as Stop does, and the
// process ends.
func TestChatContinueStopsTheOldTurnAndItsProcess(t *testing.T) {
	f := newClaudeFixture(t, nil)
	path := localListener(t, f.host)
	f.host.chatContinueWait = 200 * time.Millisecond
	f.script(1,
		step(map[string]any{"do": "init"}),
		step(map[string]any{"do": "user", "echo": true}),
		messageStart("msg_1"),
		claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`),
		claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Handing off"}}`),
		step(map[string]any{"do": "control", "subtype": "interrupt", "respond": json.RawMessage(`{"still_queued":[]}`)}),
		assistantBlock("msg_1", "", `{"type":"text","text":"Handing off"}`, `,"aborted":true`),
		emit(`{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":[],"total_cost_usd":0.001,"usage":{},"session_id":"$session","uuid":"`+newClaudeUUID()+`"}`),
	)
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "Reading it.", "", 0.001))
	old := f.newChat()
	stream := f.stream(old)
	stream.until(t, "snapshot", 5*time.Second)
	f.mustSend(old, "Hand off", nil)
	stream.until(t, "part.delta", 10*time.Second)
	reply := continueChatOn(t, path, localterm.Request{Chat: old, Prompt: "go on"})
	if reply.Error != nil || reply.ID == "" {
		t.Fatalf("reply %+v %+v", reply, reply.Error)
	}
	rest := stream.until(t, "turn.finished", 10*time.Second)
	if last := rest[len(rest)-1]; last.Outcome != "aborted" {
		t.Fatalf("outcome: %s", last.raw)
	}
	waitFor(t, "the old chat's process to stop", func() bool { return !f.live(old) })
	if controls := strings.Join(f.controls(1), ","); controls != "initialize,interrupt" {
		t.Fatalf("controls: %s", controls)
	}
	// The new chat runs on.
	f.waitIdle(reply.ID)
	if !f.live(reply.ID) {
		t.Fatal("the new chat's process stopped")
	}
}

func TestChatContinueRefusals(t *testing.T) {
	f := newClaudeFixture(t, func(config *claudeConfig) { config.maxLive = 1 })
	path := localListener(t, f.host)
	f.host.version = "1.2.3"
	f.script(1, step(map[string]any{"do": "init"}), workingTurn())
	old := f.newChat()
	f.mustSend(old, "work", nil)
	waitFor(t, "the approval", func() bool { status, _ := f.chats.Status(f.project, old); return status.State == "busy" })
	// Chats the registry holds outside a workspace the host has.
	f.chats.mu.Lock()
	f.chats.records["claude:plain"] = &cliChatRecord{Session: Session{ID: "claude:plain", ProjectID: plainChatsProjectID, Provider: "claude", Title: "Plain"}, Directory: f.project.Directory}
	f.chats.records["claude:gone"] = &cliChatRecord{Session: Session{ID: "claude:gone", ProjectID: "gone", Provider: "claude", Title: "Gone"}, Directory: f.project.Directory}
	f.chats.mu.Unlock()
	codex, err := f.chats.CreateSession(f.project, "Codex chat", "codex")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name    string
		request localterm.Request
		code    string
		message string
	}{
		{"another version", localterm.Request{Chat: old, Prompt: "go on", Version: "9.9.9"}, localterm.CodeVersion, "different versions"},
		{"no prompt", localterm.Request{Chat: old, Prompt: "  ", Version: "1.2.3"}, localterm.CodeBadRequest, "one line"},
		{"an option", localterm.Request{Chat: old, Prompt: "--resume", Version: "1.2.3"}, localterm.CodeBadRequest, "one line"},
		{"two lines", localterm.Request{Chat: old, Prompt: "a\nb", Version: "1.2.3"}, localterm.CodeBadRequest, "one line"},
		{"no chat", localterm.Request{Prompt: "go on", Version: "1.2.3"}, localterm.CodeChatNotContinuable, "isn't an AgentLand chat"},
		{"a Codex chat", localterm.Request{Chat: codex.ID, Prompt: "go on", Version: "1.2.3"}, localterm.CodeChatNotContinuable, "Only a Claude Code chat"},
		{"an unknown chat", localterm.Request{Chat: "claude:nope", Prompt: "go on", Version: "1.2.3"}, localterm.CodeChatNotContinuable, "doesn't have this chat"},
		{"a plain chat", localterm.Request{Chat: "claude:plain", Prompt: "go on", Version: "1.2.3"}, localterm.CodeChatNotContinuable, "isn't in a workspace"},
		{"a removed workspace", localterm.Request{Chat: "claude:gone", Prompt: "go on", Version: "1.2.3"}, localterm.CodeChatNotContinuable, "workspace was removed"},
		// Every process works: the new chat cannot start.
		{"the process limit", localterm.Request{Chat: old, Prompt: "go on", Version: "1.2.3"}, localterm.CodeLimit, "1 Claude Code chats working"},
	} {
		reply := continueChatOn(t, path, c.request)
		if reply.ID != "" || reply.Error == nil || reply.Error.Code != c.code || !strings.Contains(reply.Error.Message, c.message) {
			t.Errorf("%s: %+v %+v", c.name, reply, reply.Error)
		}
	}
	// Nothing was recorded, and the new chat the limit refused is gone.
	f.chats.mu.Lock()
	count := len(f.chats.records)
	f.chats.mu.Unlock()
	f.chats.claude.mu.Lock()
	engine := len(f.chats.claude.chats)
	f.chats.claude.mu.Unlock()
	if count != 4 || engine != 1 {
		t.Fatalf("registry %d, engine %d", count, engine)
	}
	chat := f.chatState(old)
	chat.mu.Lock()
	continued := chat.rec.ContinuedIn
	chat.mu.Unlock()
	if continued != "" {
		t.Fatalf("recorded %q", continued)
	}
	f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": old, "requestId": "perm-1", "reply": "once"})
	f.waitIdle(old)

	// Without Claude Code chats.
	if _, _, refusal := (&Host{}).continueLocalChat(localterm.Request{Chat: old, Prompt: "go on"}); refusal == nil || refusal.Code != localterm.CodeUnavailable {
		t.Fatalf("no chats: %+v", refusal)
	}
}

// A chat deleted from the archive is not continued.
func TestChatContinueRefusesADeletedChat(t *testing.T) {
	f, archive := newClaudeArchiveFixture(t)
	path := localListener(t, f.host)
	old := f.newChat()
	if err := archive.UpsertChat(ArchiveChat{ID: old, ProjectID: "p1", Provider: "claude", Title: "Claude"}); err != nil {
		t.Fatal(err)
	}
	if err := archive.DeleteChat(old); err != nil {
		t.Fatal(err)
	}
	if deleted, err := archive.chatDeletedRead(context.Background(), old); err != nil || !deleted {
		t.Fatalf("deleted %v %v", deleted, err)
	}
	reply := continueChatOn(t, path, localterm.Request{Chat: old, Prompt: "go on"})
	if reply.Error == nil || reply.Error.Code != localterm.CodeChatNotContinuable || reply.Error.Message != "This chat was deleted." {
		t.Fatalf("reply %+v %+v", reply, reply.Error)
	}
}

// A new chat whose prompt could not go is removed everywhere: the
// registry, the engine, the hub and the archive.
func TestChatContinueRemovesAHalfMadeChat(t *testing.T) {
	f := newClaudeFixtureWith(t, func(config *claudeConfig) { config.maxLive = 1 }, true)
	path := localListener(t, f.host)
	f.script(1, step(map[string]any{"do": "init"}), workingTurn())
	old := f.newChat()
	f.mustSend(old, "work", nil)
	waitFor(t, "the approval", func() bool { status, _ := f.chats.Status(f.project, old); return status.State == "busy" })
	reply := continueChatOn(t, path, localterm.Request{Chat: old, Prompt: "go on"})
	if reply.Error == nil || reply.Error.Code != localterm.CodeLimit {
		t.Fatalf("reply %+v %+v", reply, reply.Error)
	}
	archived := func() []string {
		rows, err := f.host.archive.readDB.Query(`SELECT id FROM chats`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var ids []string
		for rows.Next() {
			var id string
			rows.Scan(&id)
			ids = append(ids, id)
		}
		return ids
	}
	held := func() int {
		f.host.chat.mu.Lock()
		defer f.host.chat.mu.Unlock()
		return len(f.host.chat.chats)
	}
	// The capture writes every 20 ms; give it time to write anything late.
	time.Sleep(300 * time.Millisecond)
	waitFor(t, "the hub to drop the new chat", func() bool { return held() <= 1 })
	if ids := archived(); len(ids) != 1 || ids[0] != old {
		t.Fatalf("archived chats %q", ids)
	}
	f.chats.mu.Lock()
	count := len(f.chats.records)
	f.chats.mu.Unlock()
	if count != 1 {
		t.Fatalf("registry %d", count)
	}
	f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": old, "requestId": "perm-1", "reply": "once"})
	f.waitIdle(old)
}
