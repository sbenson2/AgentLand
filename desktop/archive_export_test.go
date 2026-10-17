package host

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// exportFixture archives one chat with every part kind, a hidden (rewound)
// message, an error reply and an interaction, on a fixed clock.
func exportFixture(t *testing.T) *Archive {
	t.Helper()
	archive := testArchive(t, ArchiveOptions{Now: func() time.Time { return archiveTestStart.Add(time.Hour) }})
	if err := archive.UpsertChat(ArchiveChat{ID: "ses_1", ProjectID: "p1", Provider: "opencode", Title: "Fix the build", Model: "big-model", CreatedAt: archiveTestStart}); err != nil {
		t.Fatal(err)
	}
	sum, err := archive.StoreBlob(strings.NewReader("FAIL: TestX\n"), "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	cost := int64(1234)
	messages := []ArchiveMessage{
		{ID: "msg_1", ChatID: "ses_1", TurnID: "turn_1", Role: "user", Status: "complete", Ord: 0, CreatedAt: archiveTestStart,
			Parts: []ArchivePart{
				{ID: "prt_1", Kind: "text", Text: "Why does `go test` fail?"},
				{ID: "prt_2", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "test.log", MIME: "text/plain", Size: 12, SHA256: sum}},
			}},
		{ID: "msg_2", ChatID: "ses_1", TurnID: "turn_1", Role: "assistant", Status: "complete", Model: "big-model", Ord: 1,
			CreatedAt: archiveTestStart.Add(2 * time.Second), CompletedAt: archiveTestStart.Add(9 * time.Second),
			Usage: &ArchiveUsage{Input: 100, Output: 50, Reasoning: 10, CacheRead: 5, CacheWrite: 1, CostMicros: &cost},
			Parts: []ArchivePart{
				{ID: "prt_3", Kind: "reasoning", Text: "Look at the log.\n\nThen the test.", Start: archiveTestStart.Add(2 * time.Second), End: archiveTestStart.Add(3 * time.Second)},
				{ID: "prt_4", Kind: "tool", Tool: &ArchiveTool{Name: "bash", CallID: "call_1", Status: "completed", Title: "Run tests",
					Input: `{"command":"go test ./..."}`, Output: "--- FAIL: TestX\n```\nnested fence\n```"}},
				{ID: "prt_5", Kind: "text", Text: "The test expects **two** values.\n"},
				{ID: "prt_6", Kind: "patch", Text: "--- a/x.go\n+++ b/x.go"},
				{ID: "prt_7", Kind: "notice", Text: "Files were restored."},
			}},
		{ID: "msg_3", ChatID: "ses_1", Role: "user", Status: "complete", Ord: 2, CreatedAt: archiveTestStart.Add(20 * time.Second), Hidden: true,
			Parts: []ArchivePart{{ID: "prt_8", Kind: "text", Text: "rewound question"}}},
		{ID: "msg_4", ChatID: "ses_1", Role: "assistant", Status: "error", Ord: 3, CreatedAt: archiveTestStart.Add(30 * time.Second),
			ErrorCode: "provider_error", ErrorMessage: "The model is unavailable",
			Parts: []ArchivePart{{ID: "prt_9", Kind: "context", Text: "Seed from another chat"}}},
	}
	for _, message := range messages {
		mustArchiveMessage(t, archive, message)
	}
	if err := archive.RecordInteraction(ArchiveInteraction{ID: "per_1", ChatID: "ses_1", Kind: "permission", Outcome: "once", Summary: "bash: go test ./...",
		CreatedAt: archiveTestStart.Add(4 * time.Second), ResolvedAt: archiveTestStart.Add(5 * time.Second)}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	return archive
}

func exportText(t *testing.T, archive *Archive, chatID, format string) string {
	t.Helper()
	var out bytes.Buffer
	if err := archive.Export(context.Background(), &out, chatID, format); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

const exportMarkdownGolden = "# Fix the build\n" +
	"\n" +
	"- Chat: ses_1\n" +
	"- Project: p1\n" +
	"- Provider: opencode\n" +
	"- Model: big-model\n" +
	"- Created: 2026-09-23T12:00:00.000Z\n" +
	"- Exported: 2026-09-23T13:00:00.000Z\n" +
	"\n" +
	"## User · 2026-09-23T12:00:00.000Z\n" +
	"\n" +
	"Why does `go test` fail?\n" +
	"\n" +
	"**Attachment:** test.log (text/plain, 12 bytes)\n" +
	"\n" +
	"## Assistant · big-model · 2026-09-23T12:00:02.000Z\n" +
	"\n" +
	"> **Reasoning**\n" +
	">\n" +
	"> Look at the log.\n" +
	">\n" +
	"> Then the test.\n" +
	"\n" +
	"**Tool:** bash (completed) — Run tests\n" +
	"\n" +
	"Input:\n" +
	"\n" +
	"```\n" +
	"{\"command\":\"go test ./...\"}\n" +
	"```\n" +
	"\n" +
	"Output:\n" +
	"\n" +
	"````\n" +
	"--- FAIL: TestX\n" +
	"```\n" +
	"nested fence\n" +
	"```\n" +
	"````\n" +
	"\n" +
	"The test expects **two** values.\n" +
	"\n" +
	"**Patch**\n" +
	"\n" +
	"```\n" +
	"--- a/x.go\n" +
	"+++ b/x.go\n" +
	"```\n" +
	"\n" +
	"> Note: Files were restored.\n" +
	"\n" +
	"## Assistant · 2026-09-23T12:00:30.000Z\n" +
	"\n" +
	"> **Context from another chat**\n" +
	">\n" +
	"> Seed from another chat\n" +
	"\n" +
	"**Error:** The model is unavailable (provider_error)\n"

func TestArchiveMarkdownExportGolden(t *testing.T) {
	archive := exportFixture(t)
	if got := exportText(t, archive, "ses_1", "markdown"); got != exportMarkdownGolden {
		t.Fatalf("markdown export:\n%s\n--- want ---\n%s", got, exportMarkdownGolden)
	}
}

func TestArchiveJSONExportGolden(t *testing.T) {
	archive := exportFixture(t)
	sum := fmt.Sprintf("%x", sha256.Sum256([]byte("FAIL: TestX\n")))
	want := `{"format":"agentland.chat","version":1,"exportedAt":"2026-09-23T13:00:00.000Z",` +
		`"chat":{"id":"ses_1","projectId":"p1","provider":"opencode","title":"Fix the build","titleSource":"provider","model":"big-model","createdAt":"2026-09-23T12:00:00.000Z","updatedAt":"2026-09-23T12:00:00.000Z"},` +
		`"messages":[` +
		`{"id":"msg_1","chatId":"ses_1","turnId":"turn_1","role":"user","status":"complete","ord":0,"createdAt":"2026-09-23T12:00:00.000Z","provider":"opencode","parts":[` +
		`{"id":"prt_1","kind":"text","ord":0,"text":"Why does ` + "`go test`" + ` fail?"},` +
		`{"id":"prt_2","kind":"attachment","ord":1,"attachment":{"name":"test.log","mime":"text/plain","size":12,"sha256":"` + sum + `"}}]},` +
		`{"id":"msg_2","chatId":"ses_1","turnId":"turn_1","role":"assistant","status":"complete","ord":1,"createdAt":"2026-09-23T12:00:02.000Z","completedAt":"2026-09-23T12:00:09.000Z","provider":"opencode","model":"big-model",` +
		`"usage":{"input":100,"output":50,"reasoning":10,"cacheRead":5,"cacheWrite":1,"costMicros":1234},"parts":[` +
		`{"id":"prt_3","kind":"reasoning","ord":0,"text":"Look at the log.\n\nThen the test.","start":"2026-09-23T12:00:02.000Z","end":"2026-09-23T12:00:03.000Z"},` +
		`{"id":"prt_4","kind":"tool","ord":1,"tool":{"name":"bash","callId":"call_1","status":"completed","title":"Run tests","input":"{\"command\":\"go test ./...\"}","output":"--- FAIL: TestX\n` + "```" + `\nnested fence\n` + "```" + `","truncated":false}},` +
		`{"id":"prt_5","kind":"text","ord":2,"text":"The test expects **two** values.\n"},` +
		`{"id":"prt_6","kind":"patch","ord":3,"text":"--- a/x.go\n+++ b/x.go"},` +
		`{"id":"prt_7","kind":"notice","ord":4,"text":"Files were restored."}]},` +
		`{"id":"msg_3","chatId":"ses_1","role":"user","status":"complete","ord":2,"createdAt":"2026-09-23T12:00:20.000Z","provider":"opencode","hidden":true,"parts":[` +
		`{"id":"prt_8","kind":"text","ord":0,"text":"rewound question"}]},` +
		`{"id":"msg_4","chatId":"ses_1","role":"assistant","status":"error","ord":3,"createdAt":"2026-09-23T12:00:30.000Z","provider":"opencode","error":{"code":"provider_error","message":"The model is unavailable"},"parts":[` +
		`{"id":"prt_9","kind":"context","ord":0,"text":"Seed from another chat"}]}],` +
		`"interactions":[{"id":"per_1","chatId":"ses_1","kind":"permission","outcome":"once","summary":"bash: go test ./...","createdAt":"2026-09-23T12:00:04.000Z","resolvedAt":"2026-09-23T12:00:05.000Z"}]}` + "\n"
	if got := exportText(t, archive, "ses_1", "json"); got != want {
		t.Fatalf("json export:\n%s\n--- want ---\n%s", got, want)
	}
}

func TestArchiveExportLinesAndErrors(t *testing.T) {
	archive := exportFixture(t)
	lines := strings.Split(strings.TrimSuffix(exportText(t, archive, "ses_1", "jsonl"), "\n"), "\n")
	var kinds []string
	for _, line := range lines {
		kind, _, _ := strings.Cut(strings.TrimPrefix(line, `{"type":"`), `"`)
		kinds = append(kinds, kind)
	}
	if strings.Join(kinds, " ") != "chat message message message message interaction" {
		t.Fatalf("chat lines %v", kinds)
	}
	whole := strings.Split(strings.TrimSuffix(exportText(t, archive, "", "jsonl"), "\n"), "\n")
	if !strings.HasPrefix(whole[0], `{"type":"archive","format":"agentland.archive","version":1,"epoch":"`+archive.epoch+`","exportedAt":"2026-09-23T13:00:00.000Z"}`) ||
		whole[len(whole)-1] != `{"type":"end","chats":1,"messages":4,"terminalLogs":0}` || len(whole) != 8 {
		t.Fatalf("whole archive %v", whole)
	}
	var out bytes.Buffer
	if err := archive.Export(context.Background(), &out, "missing", "markdown"); !errors.Is(err, sql.ErrNoRows) || out.Len() != 0 {
		t.Fatalf("missing chat: %v %q", err, out.String())
	}
	for _, check := range []struct{ chat, format string }{{"ses_1", "html"}, {"", "markdown"}, {"", "json"}} {
		if err := archive.Export(context.Background(), &out, check.chat, check.format); !errors.Is(err, errArchiveExportFormat) {
			t.Errorf("%+v: %v", check, err)
		}
	}
}
