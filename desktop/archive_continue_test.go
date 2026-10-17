package host

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// Continue with another model (M1 chunk B2).

// archiveSourceChat writes a Claude Code chat that exists only in the
// archive: 14 messages, one of them rewound (hidden).
func archiveSourceChat(t *testing.T, archive *Archive) {
	t.Helper()
	if err := archive.UpsertChat(ArchiveChat{ID: "claude:source", ProjectID: "p1", Provider: "claude", Title: "Database migration", Model: "claude/default", CreatedAt: archiveTestStart}); err != nil {
		t.Fatal(err)
	}
	first := textMessage("claude:source", "m01", "user", 1, "Plan the migration to Postgres.")
	first.Parts = append(first.Parts, ArchivePart{ID: "m01-file", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "schema.sql", MIME: "text/plain", Size: 10}})
	mustArchiveMessage(t, archive, first)
	plan := textMessage("claude:source", "m02", "assistant", 2, "Here is the plan.")
	plan.Parts = append([]ArchivePart{{ID: "m02-thinking", Kind: "reasoning", Text: "PRIVATE REASONING"}}, plan.Parts...)
	plan.Parts = append(plan.Parts, ArchivePart{ID: "m02-tool", Kind: "tool", Tool: &ArchiveTool{Name: "bash", Status: "completed", Title: "go test ./...", Input: `{"command":"go test ./..."}`, Output: strings.Repeat("x", 10000)}})
	mustArchiveMessage(t, archive, plan)
	for n := 3; n <= 12; n++ {
		role := "user"
		if n%2 == 0 {
			role = "assistant"
		}
		mustArchiveMessage(t, archive, textMessage("claude:source", fmt.Sprintf("m%02d", n), role, int64(n), fmt.Sprintf("Middle %d. %s", n, strings.Repeat("filler ", 40))))
	}
	rewound := textMessage("claude:source", "m13", "user", 13, "Rewound question")
	rewound.Hidden = true
	mustArchiveMessage(t, archive, rewound)
	mustArchiveMessage(t, archive, textMessage("claude:source", "m14", "assistant", 14, "Latest answer: done."))
	flushArchive(t, archive)
}

func continueChat(t *testing.T, f *chatFixture, body map[string]any) continueResponse {
	t.Helper()
	w := f.call(t, "POST", "/v1/chat/continue", body)
	if w.Code != 201 {
		t.Fatalf("continue: %d %s", w.Code, w.Body)
	}
	var response continueResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(w.Body.String(), `"parentSessionId":"`+response.ParentSessionID+`"`) || !strings.Contains(w.Body.String(), `"seed":{"included":`) {
		t.Fatalf("response shape: %s", w.Body)
	}
	return response
}

// seedText reads a continued chat's seed from the archive.
func seedText(t *testing.T, archive *Archive, chatID string) string {
	t.Helper()
	seed, err := archive.chatSeedRecord(context.Background(), chatID)
	if err != nil || seed == nil {
		t.Fatalf("seed of %s: %+v %v", chatID, seed, err)
	}
	return seed.text
}

// inOrder checks that each text occurs in seed, in the order given.
func inOrder(t *testing.T, seed string, texts ...string) {
	t.Helper()
	last := -1
	for _, text := range texts {
		index := strings.Index(seed, text)
		if index <= last {
			t.Fatalf("%q is missing or out of order in the seed:\n%s", text, seed)
		}
		last = index
	}
}

func TestContinueSeedsFromTheArchiveWithinTheBudget(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	archiveSourceChat(t, archive)
	// Everything fits: 13 visible messages, in order.
	whole := continueChat(t, f, map[string]any{"projectId": "p1", "sourceSessionId": "claude:source", "provider": "claude", "contextChars": 200000})
	seed := seedText(t, archive, whole.ID)
	if whole.ParentSessionID != "claude:source" || !strings.HasPrefix(whole.ID, "claude:") || whole.Title != "Database migration (continued)" ||
		whole.Seed.Included != 13 || whole.Seed.Omitted != 0 || whole.Seed.Chars != utf8.RuneCountInString(seed) {
		t.Fatalf("response %+v", whole)
	}
	inOrder(t, seed, `Context from an earlier chat, "Database migration" (claude, claude/default)`, "### User · 2026-09-23 12:00 UTC\nPlan the migration to Postgres.",
		"[Attachments: schema.sql]", "### Assistant", "Here is the plan.", "[Tool bash: go test ./... (completed)]", "Middle 3.", "Middle 12.", "Latest answer: done.", "End of the earlier chat.")
	for _, left := range []string{"PRIVATE REASONING", "Rewound question", "xxxxxxxxxx", "in between are left out"} {
		if strings.Contains(seed, left) {
			t.Fatalf("the seed holds %q:\n%s", left, seed)
		}
	}
	chat, err := archive.ArchivedChat(context.Background(), whole.ID)
	if err != nil || chat.ParentID != "claude:source" || chat.Relation != "continue" || chat.Provider != "claude" {
		t.Fatalf("new chat %+v %v", chat, err)
	}

	// A small budget keeps the first request and the newest messages.
	small := continueChat(t, f, map[string]any{"projectId": "p1", "sourceSessionId": "claude:source", "provider": "claude", "contextChars": 1500, "title": "Short"})
	seed = seedText(t, archive, small.ID)
	if small.Seed.Chars > 1500 || small.Seed.Chars != utf8.RuneCountInString(seed) || small.Seed.Omitted == 0 || small.Seed.Included+small.Seed.Omitted != 13 || small.Title != "Short" {
		t.Fatalf("small seed %+v:\n%s", small, seed)
	}
	marker := fmt.Sprintf("[%d messages in between are left out.]", small.Seed.Omitted)
	inOrder(t, seed, "Plan the migration to Postgres.", marker, "Middle 12.", "Latest answer: done.", "End of the earlier chat.")
	if strings.Contains(seed, "Here is the plan.") || strings.Contains(seed, "Middle 3.") {
		t.Fatalf("the small seed kept middle messages:\n%s", seed)
	}
}

// throughMessageId ends the seed at a chosen message: the first user message
// and the newest messages up to and including it, within the same budget;
// the later ones are left out.
func TestContinueThroughAChosenMessage(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	archiveSourceChat(t, archive)
	body := func(through string, chars int) map[string]any {
		return map[string]any{"projectId": "p1", "sourceSessionId": "claude:source", "provider": "claude", "contextChars": chars, "throughMessageId": through}
	}
	// Everything up to m06 fits.
	upTo := continueChat(t, f, body("m06", 200000))
	seed := seedText(t, archive, upTo.ID)
	if upTo.Seed.Included != 6 || upTo.Seed.Omitted != 0 || upTo.Seed.Chars != utf8.RuneCountInString(seed) {
		t.Fatalf("through m06: %+v", upTo.Seed)
	}
	inOrder(t, seed, "up to a point the user chose (later messages are left out)", "Plan the migration to Postgres.", "Here is the plan.", "Middle 3.", "Middle 6.", "End of the earlier chat.")
	for _, later := range []string{"Middle 7.", "Middle 12.", "Latest answer", "Rewound question", "in between are left out"} {
		if strings.Contains(seed, later) {
			t.Fatalf("the seed through m06 holds %q:\n%s", later, seed)
		}
	}
	// A small budget keeps the first message and the newest ones before the
	// chosen one, with the marker for those in between.
	small := continueChat(t, f, body("m10", 1500))
	seed = seedText(t, archive, small.ID)
	marker := fmt.Sprintf("[%d messages in between are left out.]", small.Seed.Omitted)
	if small.Seed.Chars > 1500 || small.Seed.Omitted == 0 || small.Seed.Included+small.Seed.Omitted != 10 {
		t.Fatalf("small seed through m10: %+v\n%s", small.Seed, seed)
	}
	inOrder(t, seed, "Plan the migration to Postgres.", marker, "Middle 10.", "End of the earlier chat.")
	if strings.Contains(seed, "Middle 11.") || strings.Contains(seed, "Latest answer") || strings.Contains(seed, "Middle 3.") {
		t.Fatalf("small seed through m10:\n%s", seed)
	}
	// The first message alone; the last visible message gives the whole chat.
	if only := continueChat(t, f, body("m01", 48000)); only.Seed.Included != 1 || only.Seed.Omitted != 0 || strings.Contains(seedText(t, archive, only.ID), "Here is the plan.") {
		t.Fatalf("through the first message: %+v", only.Seed)
	}
	if whole := continueChat(t, f, body("m14", 200000)); whole.Seed.Included != 13 || !strings.Contains(seedText(t, archive, whole.ID), "Latest answer: done.") {
		t.Fatalf("through the last message: %+v", whole.Seed)
	}
	// A chat continued before never carries its own seed again.
	if again := continueChat(t, f, map[string]any{"projectId": "p1", "sourceSessionId": upTo.ID, "provider": "claude", "throughMessageId": chatSeedMessageID}); again.Seed != (continueSeedInfo{}) {
		t.Fatalf("through the source's seed: %+v", again.Seed)
	}
	// A message of another chat, a rewound one or an unknown one is refused
	// and creates nothing.
	if err := archive.UpsertChat(ArchiveChat{ID: "claude:other", ProjectID: "p1", Provider: "claude", Title: "Other", CreatedAt: archiveTestStart}); err != nil {
		t.Fatal(err)
	}
	mustArchiveMessage(t, archive, textMessage("claude:other", "x01", "user", 1, "Elsewhere"))
	flushArchive(t, archive)
	project, err := f.host.project("p1")
	if err != nil {
		t.Fatal(err)
	}
	before := len(f.chats.ListSessions(project))
	for _, through := range []string{"m13", "x01", "missing", strings.Repeat("m", 257)} {
		wantRouteError(t, "through "+through[:min(len(through), 8)], f.call(t, "POST", "/v1/chat/continue", body(through, 48000)), 400, "invalid_through_message", "Choose a message the chat still shows")
	}
	if after := len(f.chats.ListSessions(project)); after != before {
		t.Fatalf("a refused continue created a chat: %d → %d", before, after)
	}
}

func TestContinueSendsTheSeedWithTheFirstPromptOnly(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	archiveSourceChat(t, archive)
	continued := continueChat(t, f, map[string]any{"projectId": "p1", "sourceSessionId": "claude:source", "provider": "claude", "model": "claude/default", "mode": "build"})
	seed := seedText(t, archive, continued.ID)
	// Nothing is sent by itself; the chat shows the seed as its first message.
	f.runner.mu.Lock()
	calls := len(f.runner.calls)
	f.runner.mu.Unlock()
	if calls != 0 {
		t.Fatal("continue sent something by itself")
	}
	page := func() []ChatMessage {
		w := f.call(t, "GET", "/v1/chat/messages?projectId=p1&sessionId="+url.QueryEscape(continued.ID), nil)
		var body struct{ Messages []ChatMessage }
		json.Unmarshal(w.Body.Bytes(), &body)
		return body.Messages
	}
	if messages := page(); len(messages) != 1 || messages[0].ID != chatSeedMessageID || messages[0].Parts[0].Kind != "context" || messages[0].Parts[0].Text != seed || messages[0].CompletedAt != "" {
		t.Fatalf("before the first prompt: %+v", messages)
	}
	send := func(text string) sendReceipt {
		w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": continued.ID, "text": text})
		var receipt sendReceipt
		json.Unmarshal(w.Body.Bytes(), &receipt)
		if w.Code != 202 {
			t.Fatalf("send %q: %d %s", text, w.Code, w.Body)
		}
		return receipt
	}
	first := send("Carry on")
	archived := waitArchived(t, archive, continued.ID, "the first reply", func(page ArchiveChatPage) bool { return len(page.Messages) == 3 })
	if user := archived.Messages[1]; user.ID != first.MessageID || user.Parts[0].Text != "Carry on" {
		t.Fatalf("the archived first prompt %+v", user)
	}
	if archived.Messages[0].CompletedAt == "" {
		t.Fatalf("the seed does not record that it was sent: %+v", archived.Messages[0])
	}
	messages := page()
	if len(messages) != 3 || messages[1].Parts[0].Text != "Carry on" || messages[2].ID != chatSeedMessageID || messages[2].CompletedAt == "" {
		t.Fatalf("after the first prompt: %+v", messages)
	}
	send("Next")
	waitArchived(t, archive, continued.ID, "the second reply", func(page ArchiveChatPage) bool { return len(page.Messages) == 5 })
	f.runner.mu.Lock()
	defer f.runner.mu.Unlock()
	if len(f.runner.calls) != 2 || f.runner.calls[0].Prompt != seed+"\n\nCarry on" || f.runner.calls[1].Prompt != "Next" {
		t.Fatalf("prompts sent: %d, first starts %q", len(f.runner.calls), f.runner.calls[0].Prompt[:min(60, len(f.runner.calls[0].Prompt))])
	}
}

func TestContinueIntoOpenCodeKeepsThePendingSeedAcrossARestart(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	archiveSourceChat(t, archive)
	continued := continueChat(t, f, map[string]any{"projectId": "p1", "sourceSessionId": "claude:source", "provider": "opencode", "model": "anthropic/claude", "mode": "plan", "contextChars": 4000})
	seed := seedText(t, archive, continued.ID)
	if continued.ID != "ses_created1" || continued.ParentSessionID != "claude:source" {
		t.Fatalf("continued %+v", continued)
	}
	// restart replaces the host with one on the same state files.
	restart := func() *Host {
		if err := f.host.Close(); err != nil {
			t.Fatal(err)
		}
		reopened := openTestArchive(t, archive.directory, ArchiveOptions{})
		archive = reopened
		f.host = newHost(f.store, NewOpenCodeAdapter(f.oc.server.URL, "opencode", "fixture", f.oc.server.Client()), HostOptions{Archive: reopened})
		f.host.chat.capture.every = 20 * time.Millisecond
		t.Cleanup(func() { f.host.Close() })
		return f.host
	}
	restart()
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": continued.ID, "text": "First prompt"}); w.Code != 202 {
		t.Fatalf("first prompt: %d %s", w.Code, w.Body)
	}
	var sent struct {
		MessageID string
		Model     struct{ ProviderID, ModelID string }
		Agent     string
		Parts     []struct{ Type, Text string }
	}
	json.Unmarshal(f.oc.promptBodies()[0], &sent)
	if len(sent.Parts) != 1 || sent.Parts[0].Text != seed+"\n\nFirst prompt" || sent.Model.ModelID != "claude" || sent.Agent != "plan" || sent.MessageID == "" {
		t.Fatalf("first prompt sent %+v", sent)
	}
	// OpenCode's copy of the message holds the seed; the hub and the archive
	// show the prompt alone.
	created := float64(time.Now().UnixMilli())
	f.oc.emit("message.updated", map[string]any{"sessionID": continued.ID, "info": map[string]any{"id": sent.MessageID, "sessionID": continued.ID, "role": "user", "time": map[string]any{"created": created}, "agent": "plan"}})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": continued.ID, "part": map[string]any{"id": fixtureID("prt", 700), "sessionID": continued.ID, "messageID": sent.MessageID, "type": "text", "text": seed + "\n\nFirst prompt"}})
	page := waitArchived(t, archive, continued.ID, "OpenCode's copy of the first prompt", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 2 && len(page.Messages[1].Parts) == 1 && page.Messages[1].Parts[0].ID == fixtureID("prt", 700)
	})
	if page.Messages[1].Parts[0].Text != "First prompt" || page.Messages[0].ID != chatSeedMessageID {
		t.Fatalf("archived after OpenCode's copy %+v", page.Messages)
	}
	live := hubMessages(f.host, sessionKey{"p1", continued.ID})
	if len(live) != 2 || live[0].ID != chatSeedMessageID || live[1].Parts[0].Text != "First prompt" {
		t.Fatalf("hub %+v", live)
	}
	// After another restart the seed is known to be sent.
	restart()
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": continued.ID, "text": "Second prompt"}); w.Code != 202 {
		t.Fatalf("second prompt: %d %s", w.Code, w.Body)
	}
	if texts := f.oc.promptTexts(t); len(texts) != 2 || texts[1] != "Second prompt" {
		t.Fatalf("second prompt sent %q", texts[len(texts)-1])
	}
}

func TestContinueValidatesItsRequest(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	archiveSourceChat(t, archive)
	if err := archive.UpsertChat(ArchiveChat{ID: "elsewhere", ProjectID: "gone", Provider: "opencode"}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	base := func(changes map[string]any) map[string]any {
		body := map[string]any{"projectId": "p1", "sourceSessionId": "claude:source", "provider": "claude"}
		for key, value := range changes {
			body[key] = value
		}
		return body
	}
	for _, check := range []struct {
		body          map[string]any
		status        int
		code, message string
	}{
		{base(map[string]any{"contextChars": 999}), 400, "invalid_request", "contextChars must be between 1000 and 200000"},
		{base(map[string]any{"contextChars": 200001}), 400, "invalid_request", "contextChars must be between 1000 and 200000"},
		{base(map[string]any{"sourceSessionId": ""}), 400, "invalid_request", "Choose the chat to continue"},
		{base(map[string]any{"provider": "gemini"}), 400, "invalid_provider", "Choose an available Mac agent"},
		{base(map[string]any{"model": "anthropic/opus"}), 400, "invalid_agent_options", "Choose settings supported by this Mac agent"},
		{base(map[string]any{"provider": "opencode", "effort": "high"}), 400, "invalid_agent_options", "Choose settings supported by this Mac agent"},
		{base(map[string]any{"provider": "opencode", "mode": "review"}), 400, "invalid_agent_options", "Choose settings supported by this Mac agent"},
		{base(map[string]any{"sourceSessionId": "missing"}), 404, "not_found", "Archived chat not found"},
		{base(map[string]any{"sourceSessionId": "elsewhere"}), 404, "not_found", "Archived chat not found"},
		{base(map[string]any{"projectId": "gone"}), 404, "not_found", "Project or session not found"},
	} {
		wantRouteError(t, fmt.Sprint(check.body), f.call(t, "POST", "/v1/chat/continue", check.body), check.status, check.code, check.message)
	}
	if w := f.call(t, "POST", "/v1/chat/continue", base(map[string]any{"unknown": true})); w.Code != 400 {
		t.Fatalf("unknown field: %d %s", w.Code, w.Body)
	}
	// Without an archive there is nothing to continue from.
	plain, store, _ := testHost(t)
	wantRouteError(t, "no archive", request(t, plain.Handler(), "POST", "/v1/chat/continue", paired(t, plain, store), base(nil)), 501, "archive_unavailable", "This host does not keep an archive")
}

func TestCapabilitiesAdvertiseContinueWithAnArchive(t *testing.T) {
	f, _, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	var capabilities hostCapabilities
	json.Unmarshal(f.call(t, "GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if !slices.Contains(capabilities.ChatFeatures, "continue") || capabilities.Archive == nil || !slices.Contains(capabilities.Archive.Features, "continue") ||
		!slices.Contains(capabilities.ChatFeatures, "continueThrough") || !slices.Contains(capabilities.Archive.Features, "continueThrough") {
		t.Fatalf("with an archive: %+v", capabilities)
	}
	plain, store, _ := testHost(t)
	capabilities = hostCapabilities{}
	json.Unmarshal(request(t, plain.Handler(), "GET", "/v1/capabilities", paired(t, plain, store), nil).Body.Bytes(), &capabilities)
	if slices.Contains(capabilities.ChatFeatures, "continue") || slices.Contains(capabilities.ChatFeatures, "continueThrough") || capabilities.Archive != nil {
		t.Fatalf("without an archive: %+v", capabilities)
	}
}
