package host

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Store behavior added for chat capture, backfill and continue (M1 chunk B2).

func TestArchiveChatFieldsLeftEmptyKeepTheirValues(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "claude", Title: "Continued", Model: "claude/default", Mode: "build",
		ParentID: "c1", Relation: "continue", CreatedAt: archiveTestStart, UpdatedAt: archiveTestStart.Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	seq := archiveCount(t, archive, `SELECT seq FROM changes WHERE entity = 'chat' AND entity_id = 'c2'`)
	// A write that knows only the title (as live capture of a new provider
	// chat does) keeps the parent, relation, model and times.
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "claude", Title: "Continued"}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	if after := archiveCount(t, archive, `SELECT seq FROM changes WHERE entity = 'chat' AND entity_id = 'c2'`); after != seq {
		t.Fatalf("a write of known values moved the chat from seq %d to %d", seq, after)
	}
	chat, err := archive.ArchivedChat(t.Context(), "c2")
	if err != nil || chat.ParentID != "c1" || chat.Relation != "continue" || chat.Model != "claude/default" || chat.Mode != "build" ||
		chat.CreatedAt != "2026-09-23T12:00:00.000Z" || chat.UpdatedAt != "2026-09-23T12:01:00.000Z" {
		t.Fatalf("chat %+v %v", chat, err)
	}
	// Non-empty values still replace the stored ones; times only widen.
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "claude", Title: "Renamed", Model: "claude/opus", UpdatedAt: archiveTestStart}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	chat, _ = archive.ArchivedChat(t.Context(), "c2")
	if chat.Title != "Renamed" || chat.Model != "claude/opus" || chat.Mode != "build" || chat.UpdatedAt != "2026-09-23T12:01:00.000Z" {
		t.Fatalf("after rename %+v", chat)
	}
	page, _ := archive.Changes(t.Context(), "", 10, []string{"p1"})
	if len(page.Changes) != 1 || !strings.Contains(string(page.Changes[0].Payload), `"parentId":"c1","relation":"continue"`) {
		t.Fatalf("chat payload %s", page.Changes[0].Payload)
	}
}

func TestArchiveRecordsWithoutTimesAreStableAcrossRewrites(t *testing.T) {
	var clock atomic.Int64
	clock.Store(archiveTestStart.UnixMilli())
	archive := testArchive(t, ArchiveOptions{Now: func() time.Time { return time.UnixMilli(clock.Load()) }})
	chat := ArchiveChat{ID: "c1", ProjectID: "p1", Provider: "claude", Title: "No times"}
	message := ArchiveMessage{ID: "m1", ChatID: "c1", Role: "user", Status: "complete", Ord: 1, Parts: []ArchivePart{{ID: "m1:0", Kind: "text", Text: "hello"}}}
	if changed, err := archive.importChat(chat, []ArchiveMessage{message}, false); err != nil || changed != 1 {
		t.Fatalf("first import: %d %v", changed, err)
	}
	// A later identical import, with the clock moved on, changes nothing.
	clock.Store(archiveTestStart.Add(time.Hour).UnixMilli())
	before := archiveCount(t, archive, `SELECT COALESCE(max(seq), 0) FROM changes`)
	if changed, err := archive.importChat(chat, []ArchiveMessage{message}, false); err != nil || changed != 0 {
		t.Fatalf("second import: %d %v", changed, err)
	}
	if after := archiveCount(t, archive, `SELECT COALESCE(max(seq), 0) FROM changes`); after != before {
		t.Fatalf("a repeated import changed the feed: %d -> %d", before, after)
	}
	page, _ := archive.ChatPage(t.Context(), "c1", "", 10)
	if page.Chat.CreatedAt != "2026-09-23T12:00:00.000Z" || page.Chat.UpdatedAt != "2026-09-23T12:00:00.000Z" || page.Messages[0].CreatedAt != "2026-09-23T12:00:00.000Z" {
		t.Fatalf("times %+v %+v", page.Chat, page.Messages[0])
	}
	// A changed message without a time keeps its first time.
	message.Parts[0].Text = "hello again"
	if changed, _ := archive.importChat(chat, []ArchiveMessage{message}, false); changed != 1 {
		t.Fatalf("changed import: %d", changed)
	}
	page, _ = archive.ChatPage(t.Context(), "c1", "", 10)
	if page.Messages[0].CreatedAt != "2026-09-23T12:00:00.000Z" || page.Messages[0].Parts[0].Text != "hello again" {
		t.Fatalf("rewritten %+v", page.Messages[0])
	}
}

func TestArchiveKeepsAttachmentBlobsWhenAProviderSnapshotHasNone(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	sum, err := archive.StoreBlob(strings.NewReader("# Notes"), "text/markdown")
	if err != nil {
		t.Fatal(err)
	}
	mustArchiveChat(t, archive, "c1", "p1", "Files")
	sent := textMessage("c1", "m1", "user", 0, "see notes")
	sent.Parts = append(sent.Parts, ArchivePart{ID: "m1:file:0", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "notes.md", MIME: "text/markdown", Size: 7, SHA256: sum}})
	mustArchiveMessage(t, archive, sent)
	flushArchive(t, archive)
	// The provider's copy names the file (with its own type) but has no bytes.
	provider := textMessage("c1", "m1", "user", 0, "see notes")
	provider.Parts = []ArchivePart{{ID: "prt_1", Kind: "text", Text: "see notes"}, {ID: "prt_2", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "notes.md", MIME: "text/plain"}}}
	mustArchiveMessage(t, archive, provider)
	flushArchive(t, archive)
	page, _ := archive.ChatPage(t.Context(), "c1", "", 10)
	attachment := page.Messages[0].Parts[1].Attachment
	if attachment == nil || attachment.SHA256 != sum || attachment.Size != 7 || attachment.MIME != "text/plain" || page.Messages[0].Parts[1].ID != "prt_2" {
		t.Fatalf("attachment after the provider's snapshot %+v", page.Messages[0].Parts)
	}
	if refs := archiveCount(t, archive, `SELECT refcount FROM blobs WHERE sha256 = ?`, sum); refs != 1 {
		t.Fatalf("refcount %d", refs)
	}
	// A snapshot that comes before its parts (OpenCode announces a message,
	// then its parts) keeps the file after them; the message's own parts
	// take it back.
	mustArchiveMessage(t, archive, ArchiveMessage{ID: "m1", ChatID: "c1", Role: "user", Status: "complete", Ord: 0, CreatedAt: archiveTestStart})
	flushArchive(t, archive)
	page, _ = archive.ChatPage(t.Context(), "c1", "", 10)
	if parts := page.Messages[0].Parts; len(parts) != 1 || parts[0].Attachment == nil || parts[0].Attachment.SHA256 != sum || parts[0].ID != "prt_2" {
		t.Fatalf("a snapshot without parts %+v", parts)
	}
	mustArchiveMessage(t, archive, provider)
	flushArchive(t, archive)
	page, _ = archive.ChatPage(t.Context(), "c1", "", 10)
	if parts := page.Messages[0].Parts; len(parts) != 2 || parts[1].Attachment.SHA256 != sum {
		t.Fatalf("the provider's parts again %+v", parts)
	}
	if refs := archiveCount(t, archive, `SELECT refcount FROM blobs WHERE sha256 = ?`, sum); refs != 1 {
		t.Fatalf("refcount %d", refs)
	}
	// Deleting the message releases the bytes, which go at once.
	if err := archive.DeleteMessage("c1", "m1"); err != nil {
		t.Fatal(err)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM blobs WHERE sha256 = ?`, sum); count != 0 {
		t.Fatalf("blob rows after deleting the message %d", count)
	}
	if _, err := os.Stat(archive.blobPath(sum)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("blob file after deleting the message: %v", err)
	}
}

func TestArchiveDeletesAndHidesSingleMessages(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	ctx := context.Background()
	mustArchiveChat(t, archive, "c1", "p1", "Rewound")
	for index, id := range []string{"m1", "m2", "m3", "m4"} {
		role := "user"
		if index%2 == 1 {
			role = "assistant"
		}
		mustArchiveMessage(t, archive, textMessage("c1", id, role, int64(index+1), "text "+id))
	}
	flushArchive(t, archive)
	cursor := func() string { page, _ := archive.Changes(ctx, "", 100, []string{"p1"}); return page.Cursor }()
	// A rewind to m3 hides m3 and m4.
	if err := archive.HideMessagesFrom("c1", "m3"); err != nil {
		t.Fatal(err)
	}
	if err := archive.HideMessagesFrom("c1", "missing"); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	page, _ := archive.ChatPage(ctx, "c1", "", 10)
	hidden := ""
	for _, message := range page.Messages {
		if message.Hidden {
			hidden += message.ID + " "
		}
	}
	if hidden != "m3 m4 " {
		t.Fatalf("hidden %q", hidden)
	}
	changed, _ := archive.Changes(ctx, cursor, 100, []string{"p1"})
	if got := strings.Join(changeNames(t, changed), " "); got != "message:m3:upsert message:m4:upsert" {
		t.Fatalf("changes after hiding: %s", got)
	}
	// A restore writes the same messages again and shows them.
	mustArchiveMessage(t, archive, textMessage("c1", "m3", "user", 3, "text m3"))
	flushArchive(t, archive)
	page, _ = archive.ChatPage(ctx, "c1", "", 10)
	if page.Messages[2].Hidden || !page.Messages[3].Hidden {
		t.Fatalf("after restoring m3: %+v", page.Messages)
	}
	// Deleting one message leaves a tombstone with its chat.
	if err := archive.DeleteMessage("c1", "m2"); err != nil {
		t.Fatal(err)
	}
	for _, missing := range [][2]string{{"c1", "m2"}, {"c1", "none"}, {"none", "m1"}, {"c1", "bad\nid"}} {
		if err := archive.DeleteMessage(missing[0], missing[1]); err != nil {
			t.Fatalf("delete %v again: %v", missing, err)
		}
	}
	all, _ := archive.Changes(ctx, "", 100, []string{"p1"})
	names := strings.Join(changeNames(t, all), " ")
	if !strings.HasSuffix(names, "message:m2:delete") || strings.Contains(names, "message:m2:upsert") {
		t.Fatalf("changes after deleting m2: %s", names)
	}
	if last := all.Changes[len(all.Changes)-1]; string(last.Payload) != `{"id":"m2","chatId":"c1"}` {
		t.Fatalf("tombstone %s", last.Payload)
	}
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures %d", archive.failures.Load())
	}
	requireSearchIndexConsistent(t, archive)
}

func TestArchiveImportCountsChangesAndSkipsDeletedChats(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	chat := ArchiveChat{ID: "c1", ProjectID: "p1", Provider: "opencode", Title: "Imported", CreatedAt: archiveTestStart}
	messages := []ArchiveMessage{textMessage("c1", "m1", "user", 1, "one"), textMessage("c1", "m2", "assistant", 2, "two"), {ID: "bad", ChatID: "c1", Role: "system", Status: "complete"}}
	if changed, err := archive.importChat(chat, messages, false); err != nil || changed != 2 {
		t.Fatalf("import: %d %v", changed, err)
	}
	if archive.failures.Load() != 1 {
		t.Fatalf("the invalid message was not counted: %d", archive.failures.Load())
	}
	messages[1].Parts[0].Text = "two, edited"
	if changed, _ := archive.importChat(chat, messages[:2], false); changed != 1 {
		t.Fatalf("changed import: %d", changed)
	}
	if err := archive.DeleteChat("c1"); err != nil {
		t.Fatal(err)
	}
	if changed, err := archive.importChat(chat, messages[:2], false); err != nil || changed != 0 {
		t.Fatalf("import of a deleted chat: %d %v", changed, err)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM chats`) + archiveCount(t, archive, `SELECT count(*) FROM messages`); count != 0 {
		t.Fatal("an import resurrected a deleted chat")
	}
}

func TestArchiveMigratesAVersionOneDatabase(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive := openTestArchive(t, directory, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Before")
	flushArchive(t, archive)
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	// Turn it back into a version 1 database.
	db, err := sql.Open("sqlite", filepath.Join(directory, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`ALTER TABLE chats DROP COLUMN relation`,
		`ALTER TABLE backfill_state DROP COLUMN chats`,
		`ALTER TABLE backfill_state DROP COLUMN chats_done`,
		// Version 3 (schedules and notices).
		`ALTER TABLE schedule_runs DROP COLUMN manual`,
		`ALTER TABLE schedule_runs DROP COLUMN scheduled_at`,
		`ALTER TABLE notices DROP COLUMN project_name`,
		`DROP TABLE notice_ack`,
		// Version 4 (chat names).
		`ALTER TABLE chats DROP COLUMN title_source`,
		`ALTER TABLE chats DROP COLUMN title_basis`,
		// Version 5 (plain chats).
		`ALTER TABLE parts DROP COLUMN tool_sources`,
		`ALTER TABLE parts DROP COLUMN tool_memory_id`,
		`ALTER TABLE parts DROP COLUMN tool_memory_text`,
		// Version 6 (vault).
		`DROP TABLE vault_files`,
		`DROP TABLE vault_state`,
		// Version 7 (terminal ends).
		`DROP INDEX terminal_logs_by_terminal`,
		`ALTER TABLE terminal_logs DROP COLUMN end_reason`,
		`ALTER TABLE terminal_logs DROP COLUMN ended_by_device_id`,
		`ALTER TABLE terminal_logs DROP COLUMN conversation_id`,
		// Version 8 (terminals outside any workspace).
		`ALTER TABLE terminal_logs DROP COLUMN folder`,
		`UPDATE meta SET schema_version = 1`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()
	reopened := openTestArchive(t, directory, ArchiveOptions{})
	if version := archiveCount(t, reopened, `SELECT schema_version FROM meta`); version != int64(len(archiveMigrations)) {
		t.Fatalf("schema version %d", version)
	}
	chat, err := reopened.ArchivedChat(t.Context(), "c1")
	if err != nil || chat.Title != "Before" || chat.Relation != "" || chat.TitleSource != "provider" || chat.TitleBasis != "" {
		t.Fatalf("chat after migration %+v %v", chat, err)
	}
	if err := reopened.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "codex", ParentID: "c1", Relation: "continue"}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, reopened)
	if chat, _ := reopened.ArchivedChat(t.Context(), "c2"); chat.Relation != "continue" {
		t.Fatalf("relation after migration %+v", chat)
	}
}
