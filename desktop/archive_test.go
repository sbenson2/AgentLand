package host

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// archiveTestStart is the fixed clock the archive tests start from.
var archiveTestStart = time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)

func testArchive(t *testing.T, options ArchiveOptions) *Archive {
	t.Helper()
	return openTestArchive(t, filepath.Join(t.TempDir(), "state.json.archive"), options)
}

// openTestArchive opens an archive with plenty of free space and a short
// batching window unless the options say otherwise, and closes it after t.
func openTestArchive(t *testing.T, directory string, options ArchiveOptions) *Archive {
	t.Helper()
	if options.BatchDelay == 0 {
		options.BatchDelay = 2 * time.Millisecond
	}
	if options.FreeSpace == nil {
		options.FreeSpace = func(string) (uint64, error) { return 64 << 30, nil }
	}
	archive, err := OpenArchive(directory, options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { archive.Close() })
	return archive
}

func flushArchive(t *testing.T, archive *Archive) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := archive.Flush(ctx); err != nil {
		t.Fatal(err)
	}
}

func mustArchiveChat(t *testing.T, archive *Archive, id, project, title string) {
	t.Helper()
	if err := archive.UpsertChat(ArchiveChat{ID: id, ProjectID: project, Provider: "opencode", Title: title, CreatedAt: archiveTestStart}); err != nil {
		t.Fatal(err)
	}
}

func mustArchiveMessage(t *testing.T, archive *Archive, message ArchiveMessage) {
	t.Helper()
	if err := archive.UpsertMessage(message); err != nil {
		t.Fatal(err)
	}
}

func textMessage(chatID, id, role string, ord int64, text string) ArchiveMessage {
	return ArchiveMessage{ID: id, ChatID: chatID, Role: role, Status: "complete", Ord: ord,
		CreatedAt: archiveTestStart.Add(time.Duration(ord) * time.Second),
		Parts:     []ArchivePart{{ID: id + "-text", Kind: "text", Text: text}}}
}

func archiveCount(t *testing.T, archive *Archive, query string, args ...any) int64 {
	t.Helper()
	var count int64
	if err := archive.readDB.QueryRow(query, args...).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

// changeNames lists a page as entity:id:op.
func changeNames(t *testing.T, page ArchiveChanges) []string {
	t.Helper()
	names := []string{}
	for _, change := range page.Changes {
		var payload struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(change.Payload, &payload); err != nil {
			t.Fatal(err)
		}
		names = append(names, change.Entity+":"+payload.ID+":"+change.Op)
	}
	return names
}

func TestArchiveSchemaIsCreatedOnceAndReopened(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	first, err := OpenArchive(directory, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }})
	if err != nil {
		t.Fatal(err)
	}
	epoch := first.epoch
	if len(epoch) != 16 {
		t.Fatalf("epoch %q", epoch)
	}
	var tables []string
	rows, err := first.readDB.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'message_fts_%' ORDER BY name`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var name string
		rows.Scan(&name)
		tables = append(tables, name)
	}
	rows.Close()
	want := "backfill_state blobs changes chats interactions message_fts messages meta notice_ack notices parts schedule_runs terminal_logs vault_files vault_state"
	if strings.Join(tables, " ") != want {
		t.Fatalf("tables %v", tables)
	}
	var journal string
	if err := first.readDB.QueryRow(`PRAGMA journal_mode`).Scan(&journal); err != nil || journal != "wal" {
		t.Fatalf("journal mode %q %v", journal, err)
	}
	// Migrating an up-to-date database changes nothing.
	if err := migrateArchive(first.writeDB, "other", 1); err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second := openTestArchive(t, directory, ArchiveOptions{})
	if second.epoch != epoch {
		t.Fatalf("epoch changed on reopen: %q -> %q", epoch, second.epoch)
	}
	if version := archiveCount(t, second, `SELECT schema_version FROM meta`); version != int64(len(archiveMigrations)) {
		t.Fatalf("schema version %d", version)
	}
	if rows := archiveCount(t, second, `SELECT count(*) FROM meta`); rows != 1 {
		t.Fatalf("meta rows %d", rows)
	}
}

func TestArchiveRefusesANewerSchema(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive := openTestArchive(t, directory, ArchiveOptions{})
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(directory, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE meta SET schema_version = 99`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	if _, err := OpenArchive(directory, ArchiveOptions{}); !errors.Is(err, errArchiveNewerSchema) {
		t.Fatalf("newer schema opened: %v", err)
	}
}

func TestArchiveRefusesSymlinksAndAmbiguousPaths(t *testing.T) {
	real := filepath.Join(t.TempDir(), "real")
	if err := os.Mkdir(real, 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "state.json.archive")
	if err := os.Symlink(real, link); err != nil {
		t.Skipf("symlinks are unavailable: %v", err)
	}
	if _, err := OpenArchive(link, ArchiveOptions{}); err == nil {
		t.Fatal("opened an archive through a symlinked directory")
	}
	if entries, _ := os.ReadDir(real); len(entries) != 0 {
		t.Fatalf("wrote through the symlink: %v", entries)
	}

	directory := filepath.Join(t.TempDir(), "state.json.archive")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "elsewhere.db")
	if err := os.WriteFile(target, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(directory, "archive.db")); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenArchive(directory, ArchiveOptions{}); err == nil {
		t.Fatal("opened a symlinked archive.db")
	}

	if _, err := OpenArchive(filepath.Join(t.TempDir(), "odd?name"), ArchiveOptions{}); err == nil {
		t.Fatal("accepted a path the SQLite driver would misread")
	}
}

func TestArchiveWriterBatchesAndCoalescesSnapshots(t *testing.T) {
	// The window outlasts the test, so only Flush commits the batch.
	archive := testArchive(t, ArchiveOptions{BatchDelay: time.Hour})
	before := archive.batches.Load()
	mustArchiveChat(t, archive, "c1", "p1", "Batch")
	for step := range 20 {
		message := textMessage("c1", "m1", "assistant", 1, strings.Repeat("word ", step+1))
		message.Status = "streaming"
		mustArchiveMessage(t, archive, message)
	}
	for index := range 5 {
		mustArchiveMessage(t, archive, textMessage("c1", fmt.Sprintf("other-%d", index), "user", int64(10+index), "hello"))
	}
	archive.mu.Lock()
	queued := len(archive.pending)
	archive.mu.Unlock()
	if queued != 7 {
		t.Fatalf("queued %d operations, want the chat, one coalesced snapshot and five messages", queued)
	}
	flushArchive(t, archive)
	if batches := archive.batches.Load() - before; batches != 1 {
		t.Fatalf("%d batches, want one", batches)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM messages`); count != 6 {
		t.Fatalf("%d messages", count)
	}
	if text := archiveCount(t, archive, `SELECT length(text) FROM parts WHERE id = 'm1-text'`); text != int64(len(strings.Repeat("word ", 20))) {
		t.Fatalf("latest snapshot not stored: length %d", text)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM changes WHERE entity = 'message' AND entity_id = 'm1'`); count != 1 {
		t.Fatalf("message appears %d times in the change feed", count)
	}
	// An identical rewrite changes nothing.
	seq := archiveCount(t, archive, `SELECT seq FROM changes WHERE entity = 'message' AND entity_id = 'm1'`)
	message := textMessage("c1", "m1", "assistant", 1, strings.Repeat("word ", 20))
	message.Status = "streaming"
	mustArchiveMessage(t, archive, message)
	mustArchiveChat(t, archive, "c1", "p1", "Batch")
	flushArchive(t, archive)
	if after := archiveCount(t, archive, `SELECT seq FROM changes WHERE entity = 'message' AND entity_id = 'm1'`); after != seq {
		t.Fatalf("identical snapshot moved the message from seq %d to %d", seq, after)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM changes`); count != 7 {
		t.Fatalf("%d changes", count)
	}
}

func TestArchiveCloseCommitsQueuedWritesAndStopsTheWriter(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive, err := OpenArchive(directory, ArchiveOptions{BatchDelay: time.Hour, FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }})
	if err != nil {
		t.Fatal(err)
	}
	mustArchiveChat(t, archive, "c1", "p1", "Queued")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "kept on close"))
	closed := make(chan error, 1)
	go func() { closed <- archive.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Close did not stop the writer")
	}
	select {
	case <-archive.writerDone:
	default:
		t.Fatal("the writer goroutine is still running")
	}
	if err := archive.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "opencode"}); !errors.Is(err, ErrArchiveClosed) {
		t.Fatalf("write after Close: %v", err)
	}
	if err := archive.Flush(context.Background()); !errors.Is(err, ErrArchiveClosed) {
		t.Fatalf("flush after Close: %v", err)
	}
	if info, err := os.Stat(filepath.Join(directory, "archive.db-wal")); err == nil && info.Size() != 0 {
		t.Errorf("WAL not checkpointed on close: %d bytes", info.Size())
	}
	reopened := openTestArchive(t, directory, ArchiveOptions{})
	if count := archiveCount(t, reopened, `SELECT count(*) FROM messages WHERE id = 'm1'`); count != 1 {
		t.Fatal("a queued message was lost on Close")
	}
}

func TestArchiveQueuedWritesWaitForRoomThenReportBusy(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{BatchDelay: time.Hour})
	archive.enqueueWait = 200 * time.Millisecond
	// Fill the queue without waking the writer.
	archive.mu.Lock()
	for range archiveQueueCapacity {
		archive.pending = append(archive.pending, &archiveOp{apply: func(*archiveTx) error { return nil }})
	}
	archive.mu.Unlock()
	started := time.Now()
	err := archive.UpsertChat(ArchiveChat{ID: "c1", ProjectID: "p1", Provider: "opencode"})
	if !errors.Is(err, ErrArchiveBusy) || time.Since(started) < archive.enqueueWait {
		t.Fatalf("full queue: %v after %v", err, time.Since(started))
	}
	// Taking a batch makes room for a waiting write.
	result := make(chan error, 1)
	go func() { result <- archive.UpsertChat(ArchiveChat{ID: "c1", ProjectID: "p1", Provider: "opencode"}) }()
	time.Sleep(50 * time.Millisecond)
	archive.writePending()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a waiting write did not get the room")
	}
}

func TestArchiveChangeFeedCursorsTombstonesAndProjects(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	ctx := context.Background()
	projects := []string{"p1", "p2"}
	mustArchiveChat(t, archive, "c1", "p1", "One")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "first"))
	mustArchiveMessage(t, archive, textMessage("c1", "m2", "assistant", 1, "second"))
	mustArchiveChat(t, archive, "c2", "p2", "Two")
	mustArchiveChat(t, archive, "c3", "p3", "Unconfigured")
	mustArchiveMessage(t, archive, textMessage("c3", "m9", "user", 0, "hidden from devices"))
	flushArchive(t, archive)

	page, err := archive.Changes(ctx, "", 100, projects)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(changeNames(t, page), " "); got != "chat:c1:upsert message:m1:upsert message:m2:upsert chat:c2:upsert" || page.Resync || page.HasMore {
		t.Fatalf("first sync: %s resync=%v more=%v", got, page.Resync, page.HasMore)
	}
	if !strings.HasPrefix(page.Cursor, page.Epoch+".") || !strings.HasPrefix(page.Epoch, archive.epoch+"-") {
		t.Fatalf("cursor %q epoch %q", page.Cursor, page.Epoch)
	}
	var message archiveMessageJSON
	if err := json.Unmarshal(page.Changes[1].Payload, &message); err != nil || message.ChatID != "c1" || message.Provider != "opencode" || len(message.Parts) != 1 || message.Parts[0].Text != "first" {
		t.Fatalf("message payload %s %v", page.Changes[1].Payload, err)
	}

	// An update moves the message to the end; the cursor returns only it.
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "first, edited"))
	flushArchive(t, archive)
	next, err := archive.Changes(ctx, page.Cursor, 100, projects)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(changeNames(t, next), " "); got != "message:m1:upsert" || next.Resync {
		t.Fatalf("after update: %s", got)
	}
	all, _ := archive.Changes(ctx, "", 100, projects)
	if got := strings.Join(changeNames(t, all), " "); got != "chat:c1:upsert message:m2:upsert chat:c2:upsert message:m1:upsert" {
		t.Fatalf("each entity once at its latest seq: %s", got)
	}

	// Paging.
	first, _ := archive.Changes(ctx, "", 2, projects)
	if len(first.Changes) != 2 || !first.HasMore {
		t.Fatalf("page of two: %v more=%v", changeNames(t, first), first.HasMore)
	}
	rest, _ := archive.Changes(ctx, first.Cursor, 2, projects)
	if got := strings.Join(changeNames(t, rest), " "); got != "chat:c2:upsert message:m1:upsert" || rest.HasMore {
		t.Fatalf("second page: %s more=%v", got, rest.HasMore)
	}

	// Another epoch, another project set, or a cursor past the newest change
	// all restart from the beginning with resync.
	for _, cursor := range []string{"0123456789abcdef-00000000.1", strings.Replace(next.Cursor, ".", ".9", 1) + "99"} {
		again, err := archive.Changes(ctx, cursor, 100, projects)
		if err != nil || !again.Resync || len(again.Changes) != 4 {
			t.Fatalf("cursor %q: resync=%v %v %v", cursor, again.Resync, changeNames(t, again), err)
		}
	}
	narrowed, err := archive.Changes(ctx, next.Cursor, 100, []string{"p1"})
	if err != nil || !narrowed.Resync || narrowed.Epoch == next.Epoch {
		t.Fatalf("project change: resync=%v epoch %q vs %q %v", narrowed.Resync, narrowed.Epoch, next.Epoch, err)
	}
	if got := strings.Join(changeNames(t, narrowed), " "); got != "chat:c1:upsert message:m2:upsert message:m1:upsert" {
		t.Fatalf("narrowed: %s", got)
	}
	for _, cursor := range []string{"garbage", ".5", next.Epoch + ".x", next.Epoch + ".-1"} {
		if _, err := archive.Changes(ctx, cursor, 100, projects); !errors.Is(err, errArchiveCursor) {
			t.Fatalf("cursor %q accepted: %v", cursor, err)
		}
	}

	// A delete leaves a tombstone and removes the chat's message changes;
	// later writes to the chat are ignored.
	cursor := all.Cursor
	if err := archive.DeleteChat("c1"); err != nil {
		t.Fatal(err)
	}
	if err := archive.DeleteChat("c1"); err != nil {
		t.Fatalf("deleting again: %v", err)
	}
	if err := archive.DeleteChat("missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown chat: %v", err)
	}
	mustArchiveMessage(t, archive, textMessage("c1", "m3", "user", 3, "after delete"))
	mustArchiveChat(t, archive, "c1", "p1", "Resurrected")
	flushArchive(t, archive)
	deleted, err := archive.Changes(ctx, cursor, 100, projects)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(changeNames(t, deleted), " "); got != "chat:c1:delete" || string(deleted.Changes[0].Payload) != `{"id":"c1"}` {
		t.Fatalf("tombstone: %s %s", got, deleted.Changes[0].Payload)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM messages WHERE chat_id = 'c1'`) + archiveCount(t, archive, `SELECT count(*) FROM chats WHERE id = 'c1'`); count != 0 {
		t.Fatal("a deleted chat came back")
	}
	final, _ := archive.Changes(ctx, "", 100, projects)
	if got := strings.Join(changeNames(t, final), " "); got != "chat:c2:upsert chat:c1:delete" {
		t.Fatalf("after delete: %s", got)
	}
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures: %d", archive.failures.Load())
	}
	requireSearchIndexConsistent(t, archive)
	if page, _ := archive.Search(ctx, ArchiveSearch{Text: "first", Limit: 10}, []string{"p1", "p2", "p3"}); len(page.Results) != 0 {
		t.Fatalf("deleted messages are still searchable: %+v", page.Results)
	}
}

// requireSearchIndexConsistent runs FTS5's integrity check, which with rank 1
// also compares the index with the messages table.
func requireSearchIndexConsistent(t *testing.T, archive *Archive) {
	t.Helper()
	if _, err := archive.writeDB.Exec(`INSERT INTO message_fts (message_fts, rank) VALUES ('integrity-check', 1)`); err != nil {
		t.Fatalf("search index: %v", err)
	}
}

func TestArchiveChatKeepsItsProjectAndProvider(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "First title")
	if err := archive.UpsertChat(ArchiveChat{ID: "c1", ProjectID: "p2", Provider: "codex", Title: "Renamed", CreatedAt: archiveTestStart.Add(time.Hour), UpdatedAt: archiveTestStart.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	flushArchive(t, archive)
	chat, err := archive.ArchivedChat(t.Context(), "c1")
	if err != nil || chat.ProjectID != "p1" || chat.Provider != "opencode" || chat.Title != "Renamed" ||
		chat.CreatedAt != "2026-09-23T12:00:00.000Z" || chat.UpdatedAt != "2026-09-23T13:00:00.000Z" {
		t.Fatalf("chat %+v %v", chat, err)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM changes WHERE project_id = 'p1' AND entity_id = 'c1'`); count != 1 {
		t.Fatalf("the change stayed with the chat's project: %d", count)
	}
}

func TestArchiveChangeFeedPagesStayNearTwoMegabytes(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Large")
	for index := range 3 {
		mustArchiveMessage(t, archive, textMessage("c1", fmt.Sprintf("m%d", index), "assistant", int64(index), strings.Repeat("a", 900<<10)))
	}
	flushArchive(t, archive)
	page, err := archive.Changes(context.Background(), "", 200, []string{"p1"})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Changes) != 3 || !page.HasMore {
		t.Fatalf("first page holds %d changes, more=%v", len(page.Changes), page.HasMore)
	}
	size := 0
	for _, change := range page.Changes {
		size += len(change.Payload)
	}
	if size > archiveChangesPageBytes {
		t.Fatalf("page of %d bytes", size)
	}
	rest, _ := archive.Changes(context.Background(), page.Cursor, 200, []string{"p1"})
	if got := strings.Join(changeNames(t, rest), " "); got != "message:m2:upsert" || rest.HasMore {
		t.Fatalf("rest: %s", got)
	}
}

func TestArchiveSearchQuotesTermsFiltersAndMarksSnippets(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	ctx := context.Background()
	mustArchiveChat(t, archive, "c1", "p1", "Animals")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "The quick brown fox jumps over the lazy dog"))
	mustArchiveMessage(t, archive, textMessage("c1", "m2", "assistant", 1, "Café au lait, s'il vous plaît"))
	hidden := textMessage("c1", "m3", "user", 2, "a quick secret that was rewound")
	hidden.Hidden = true
	mustArchiveMessage(t, archive, hidden)
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p2", Provider: "claude", Title: "Operators", CreatedAt: archiveTestStart}); err != nil {
		t.Fatal(err)
	}
	mustArchiveMessage(t, archive, textMessage("c2", "m4", "user", 0, "foo OR bar baz quick"))
	mustArchiveChat(t, archive, "c3", "p3", "Elsewhere")
	mustArchiveMessage(t, archive, textMessage("c3", "m5", "user", 0, "quick fox in an unconfigured project"))
	flushArchive(t, archive)
	projects := []string{"p1", "p2"}
	find := func(search ArchiveSearch) []string {
		t.Helper()
		if search.Limit == 0 {
			search.Limit = 20
		}
		page, err := archive.Search(ctx, search, projects)
		if err != nil {
			t.Fatalf("search %q: %v", search.Text, err)
		}
		ids := []string{}
		for _, result := range page.Results {
			ids = append(ids, result.MessageID)
		}
		slices.Sort(ids)
		return ids
	}
	page, err := archive.Search(ctx, ArchiveSearch{Text: "fox", Limit: 20}, projects)
	if err != nil || len(page.Results) != 1 {
		t.Fatalf("fox: %+v %v", page, err)
	}
	result := page.Results[0]
	if result.ChatID != "c1" || result.ProjectID != "p1" || result.Provider != "opencode" || result.Title != "Animals" || result.Role != "user" ||
		result.CreatedAt != "2026-09-23T12:00:00.000Z" || !strings.Contains(result.Snippet, "brown \x02fox\x03 jumps") {
		t.Fatalf("result %+v", result)
	}
	// Each result names its chat's provider.
	if claude, err := archive.Search(ctx, ArchiveSearch{Text: "baz", Limit: 20}, projects); err != nil || len(claude.Results) != 1 || claude.Results[0].Provider != "claude" {
		t.Fatalf("provider of a Claude chat's result: %+v %v", claude, err)
	}
	for _, check := range []struct {
		search ArchiveSearch
		want   string
	}{
		{ArchiveSearch{Text: "quick"}, "m1 m4"},
		{ArchiveSearch{Text: "cafe"}, "m2"},
		{ArchiveSearch{Text: "qui*"}, "m1 m4"},
		{ArchiveSearch{Text: "qui"}, ""},
		{ArchiveSearch{Text: "quick", ProjectID: "p2"}, "m4"},
		{ArchiveSearch{Text: "quick", Provider: "claude"}, "m4"},
		{ArchiveSearch{Text: "quick", From: archiveTestStart.Add(time.Second)}, ""},
		{ArchiveSearch{Text: "quick", To: archiveTestStart.Add(time.Second)}, "m1 m4"},
		{ArchiveSearch{Text: "rewound"}, ""},
		{ArchiveSearch{Text: "unconfigured"}, ""},
		// Operators are only words: "OR" must appear in the text.
		{ArchiveSearch{Text: "foo OR bar"}, "m4"},
		{ArchiveSearch{Text: "quick OR lazy"}, ""},
		{ArchiveSearch{Text: "quick NOT fox"}, ""},
		{ArchiveSearch{Text: "NEAR(quick fox)"}, ""},
		{ArchiveSearch{Text: "search_text:quick"}, ""},
		{ArchiveSearch{Text: `"unbalanced quick`}, ""},
		{ArchiveSearch{Text: `quick" OR "lazy`}, ""},
		{ArchiveSearch{Text: "-quick ^fox"}, "m1"},
		{ArchiveSearch{Text: "(quick) AND"}, ""},
		{ArchiveSearch{Text: "* ** -- \"\""}, ""},
	} {
		if got := strings.Join(find(check.search), " "); got != check.want {
			t.Errorf("%+v: %q, want %q", check.search, got, check.want)
		}
	}
	first, err := archive.Search(ctx, ArchiveSearch{Text: "quick", Limit: 1}, projects)
	if err != nil || len(first.Results) != 1 || first.NextCursor != "s.1" {
		t.Fatalf("first page %+v %v", first, err)
	}
	second, err := archive.Search(ctx, ArchiveSearch{Text: "quick", Limit: 1, Cursor: first.NextCursor}, projects)
	if err != nil || len(second.Results) != 1 || second.NextCursor != "" || second.Results[0].MessageID == first.Results[0].MessageID {
		t.Fatalf("second page %+v %v", second, err)
	}
	for _, cursor := range []string{"1", "s.x", "s.-1", "s.99999"} {
		if _, err := archive.Search(ctx, ArchiveSearch{Text: "quick", Limit: 1, Cursor: cursor}, projects); !errors.Is(err, errArchiveCursor) {
			t.Errorf("cursor %q: %v", cursor, err)
		}
	}
	// Rewriting a message replaces its indexed text.
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "a slow green turtle"))
	flushArchive(t, archive)
	if got := strings.Join(find(ArchiveSearch{Text: "fox"}), " "); got != "" {
		t.Fatalf("old text still indexed: %q", got)
	}
	if got := strings.Join(find(ArchiveSearch{Text: "turtle"}), " "); got != "m1" {
		t.Fatalf("new text not indexed: %q", got)
	}
	requireSearchIndexConsistent(t, archive)
}

func TestArchiveMatchQueryQuotesEveryTerm(t *testing.T) {
	for input, want := range map[string]string{
		"hello world": `"hello" "world"`,
		`say "hi"`:    `"say" """hi"""`,
		"prefix*":     `"prefix"*`,
		"a* b":        `"a*" "b"`,
		"NEAR(a b)":   `"NEAR(a" "b)"`,
		"col:term":    `"col:term"`,
		"--- ***":     ``,
		"  ":          ``,
		"日本語 テキスト*":   `"日本語" "テキスト"*`,
	} {
		if got := archiveMatchQuery(input); got != want {
			t.Errorf("%q -> %q, want %q", input, got, want)
		}
	}
}

func TestArchiveBlobsAreSharedReleasedAndCollected(t *testing.T) {
	now := archiveTestStart
	var clock atomic.Int64
	clock.Store(now.UnixMilli())
	archive := testArchive(t, ArchiveOptions{Now: func() time.Time { return time.UnixMilli(clock.Load()) }})
	sum, err := archive.StoreBlob(strings.NewReader("attached bytes"), "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	again, err := archive.StoreBlob(strings.NewReader("attached bytes"), "text/plain")
	if err != nil || again != sum {
		t.Fatalf("same content stored as %q and %q: %v", sum, again, err)
	}
	if data, err := os.ReadFile(archive.blobPath(sum)); err != nil || string(data) != "attached bytes" {
		t.Fatalf("blob file %q %v", data, err)
	}
	if entries, _ := os.ReadDir(filepath.Join(archive.directory, "blobs")); len(entries) != 1 {
		t.Fatalf("blobs directory holds %d entries (temporary files left?)", len(entries))
	}
	attachment := func(id, chat string, sha string) ArchiveMessage {
		message := textMessage(chat, id, "user", 0, "see attached")
		message.Parts = append(message.Parts, ArchivePart{ID: id + "-file", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "notes.txt", MIME: "text/plain", Size: 14, SHA256: sha}})
		return message
	}
	mustArchiveChat(t, archive, "c1", "p1", "Files")
	mustArchiveChat(t, archive, "c2", "p1", "More files")
	mustArchiveMessage(t, archive, attachment("m1", "c1", sum))
	mustArchiveMessage(t, archive, attachment("m2", "c2", sum))
	unknown := strings.Repeat("ab", 32)
	mustArchiveMessage(t, archive, attachment("m3", "c2", unknown))
	flushArchive(t, archive)
	if refs := archiveCount(t, archive, `SELECT refcount FROM blobs WHERE sha256 = ?`, sum); refs != 2 {
		t.Fatalf("refcount %d", refs)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM parts WHERE blob_sha256 IS NOT NULL AND id = 'm3-file'`); count != 0 {
		t.Fatal("kept a reference to a blob the archive does not have")
	}
	page, _ := archive.ChatPage(context.Background(), "c2", "", 50)
	if page.Messages[0].Parts[1].Attachment.SHA256 != sum || page.Messages[1].Parts[1].Attachment.SHA256 != "" {
		t.Fatalf("attachment payloads %+v %+v", page.Messages[0].Parts[1].Attachment, page.Messages[1].Parts[1].Attachment)
	}
	// Rewriting a message keeps its file (M1 chunk B2); deleting the message
	// releases one reference.
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "file removed"))
	flushArchive(t, archive)
	if refs := archiveCount(t, archive, `SELECT refcount FROM blobs WHERE sha256 = ?`, sum); refs != 2 {
		t.Fatalf("refcount after rewrite %d", refs)
	}
	if err := archive.DeleteMessage("c1", "m1"); err != nil {
		t.Fatal(err)
	}
	if refs := archiveCount(t, archive, `SELECT refcount FROM blobs WHERE sha256 = ?`, sum); refs != 1 {
		t.Fatalf("refcount after deleting the message %d", refs)
	}
	// Deleting the last chat that refers to it removes the file at once.
	if err := archive.DeleteChat("c2"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(archive.blobPath(sum)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("released blob still on disk: %v", err)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM blobs`); count != 0 {
		t.Fatalf("%d blob rows remain", count)
	}
	// A blob nothing refers to stays 24 hours, then the hourly collection removes it.
	orphan, err := archive.StoreBlob(bytes.NewReader([]byte{1, 2, 3}), "application/octet-stream")
	if err != nil {
		t.Fatal(err)
	}
	archive.maintain()
	flushArchive(t, archive)
	if _, err := os.Stat(archive.blobPath(orphan)); err != nil {
		t.Fatalf("fresh blob collected: %v", err)
	}
	clock.Store(now.Add(25 * time.Hour).UnixMilli())
	archive.maintain()
	flushArchive(t, archive)
	if _, err := os.Stat(archive.blobPath(orphan)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unreferenced blob kept after a day: %v", err)
	}
	if _, err := archive.StoreBlob(io.LimitReader(zeroReader{}, archiveBlobLimit+1), "application/octet-stream"); !errors.Is(err, ErrArchiveBlobTooLarge) {
		t.Fatalf("oversized blob: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(archive.directory, "blobs"))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".incoming-") {
			t.Fatalf("an oversized upload left %s", entry.Name())
		}
	}
}

type zeroReader struct{}

func (zeroReader) Read(data []byte) (int, error) {
	clear(data)
	return len(data), nil
}

func TestArchiveBoundsMessagesAndRejectsInvalidRecords(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Bounds")
	message := textMessage("c1", "m1", "assistant", 0, strings.Repeat("é", 1<<20)+"tail")
	message.Parts = append(message.Parts, ArchivePart{ID: "tool", Kind: "tool", Tool: &ArchiveTool{Name: "bash", Status: "completed", Output: strings.Repeat("x", 100<<10)}})
	for index := range archivePartsPerMessage {
		message.Parts = append(message.Parts, ArchivePart{Kind: "reasoning", Text: fmt.Sprintf("step %d", index)})
	}
	mustArchiveMessage(t, archive, message)
	flushArchive(t, archive)
	page, err := archive.ChatPage(context.Background(), "c1", "", 50)
	if err != nil {
		t.Fatal(err)
	}
	parts := page.Messages[0].Parts
	if len(parts) != archivePartsPerMessage || parts[len(parts)-1].Kind != "notice" || parts[len(parts)-1].Text != "3 more parts were not archived" {
		t.Fatalf("%d parts, last %+v", len(parts), parts[len(parts)-1])
	}
	if text := parts[0].Text; len(text) > archivePartTextLimit || !parts[0].Truncated || strings.HasSuffix(text, "tail") || !strings.HasSuffix(text, "é") {
		t.Fatalf("text part %d bytes truncated=%v", len(text), parts[0].Truncated)
	}
	if tool := parts[1].Tool; tool == nil || len(tool.Output) != archiveToolFieldLimit || !tool.Truncated {
		t.Fatalf("tool %+v", tool)
	}
	if length := archiveCount(t, archive, `SELECT length(CAST(search_text AS BLOB)) FROM messages`); length > archiveSearchTextLimit {
		t.Fatalf("search text %d bytes", length)
	}
	for _, bad := range []ArchiveMessage{
		{ID: "m2", ChatID: "c1", Role: "system", Status: "complete"},
		{ID: "m2", ChatID: "c1", Role: "user", Status: "done"},
		{ID: "bad\nid", ChatID: "c1", Role: "user", Status: "complete"},
		{ID: "", ChatID: "c1", Role: "user", Status: "complete"},
		{ID: "m2", ChatID: "c1", Role: "user", Status: "complete", Parts: []ArchivePart{{Kind: "image"}}},
		{ID: "m2", ChatID: "c1", Role: "user", Status: "complete", Parts: []ArchivePart{{Kind: "attachment", Attachment: &ArchiveAttachment{SHA256: "../../etc"}}}},
	} {
		if err := archive.UpsertMessage(bad); !errors.Is(err, errArchiveInvalid) {
			t.Errorf("accepted %+v: %v", bad, err)
		}
	}
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1"}); !errors.Is(err, errArchiveInvalid) {
		t.Errorf("chat without a provider: %v", err)
	}
	if err := archive.RecordInteraction(ArchiveInteraction{ID: "i1", ChatID: "c1", Kind: "permission", Outcome: "maybe"}); !errors.Is(err, errArchiveInvalid) {
		t.Errorf("unknown outcome: %v", err)
	}
	// A message for a chat that was never written fails in the writer.
	mustArchiveMessage(t, archive, textMessage("nochat", "m1", "user", 0, "orphan"))
	flushArchive(t, archive)
	if archive.failures.Load() != 1 {
		t.Fatalf("failures %d", archive.failures.Load())
	}
}

func TestArchiveChatPagesRunNewestFirstOldestWithinAPage(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	ctx := context.Background()
	mustArchiveChat(t, archive, "c1", "p1", "Paged")
	for index := range 5 {
		message := textMessage("c1", fmt.Sprintf("m%d", index), "user", int64(index), fmt.Sprintf("message %d", index))
		message.Hidden = index == 4
		mustArchiveMessage(t, archive, message)
	}
	flushArchive(t, archive)
	ids := func(page ArchiveChatPage) string {
		var names []string
		for _, message := range page.Messages {
			names = append(names, message.ID)
		}
		return strings.Join(names, " ")
	}
	newest, err := archive.ChatPage(ctx, "c1", "", 2)
	if err != nil || ids(newest) != "m3 m4" || !newest.HasMore || newest.OldestID != "m3" || !newest.Messages[1].Hidden {
		t.Fatalf("newest %s more=%v oldest=%s %v", ids(newest), newest.HasMore, newest.OldestID, err)
	}
	older, _ := archive.ChatPage(ctx, "c1", newest.OldestID, 2)
	oldest, _ := archive.ChatPage(ctx, "c1", older.OldestID, 2)
	if ids(older) != "m1 m2" || !older.HasMore || ids(oldest) != "m0" || oldest.HasMore {
		t.Fatalf("older %s, oldest %s more=%v", ids(older), ids(oldest), oldest.HasMore)
	}
	if _, err := archive.ChatPage(ctx, "c1", "missing", 2); !errors.Is(err, errArchiveBefore) {
		t.Fatalf("unknown before: %v", err)
	}
	if _, err := archive.ChatPage(ctx, "missing", "", 2); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("unknown chat: %v", err)
	}
}

// Terminal output and attachment bytes pause below 2 GiB free; chat text keeps
// recording down to 256 MiB and pauses only below that.
func TestArchiveLowDiskPausesTerminalOutputBeforeChatText(t *testing.T) {
	var free atomic.Uint64
	free.Store(archiveMinimumFree - 1)
	archive := testArchive(t, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return free.Load(), nil }})
	if !archive.paused.Load() || archive.chatPaused.Load() {
		t.Fatalf("below 2 GiB at open: paused=%v chatPaused=%v", archive.paused.Load(), archive.chatPaused.Load())
	}
	// Chat text is still recorded.
	mustArchiveChat(t, archive, "c1", "p1", "Low disk")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "still kept"))
	if err := archive.RecordInteraction(ArchiveInteraction{ID: "i1", ChatID: "c1", Kind: "permission", Outcome: "once", Summary: "bash"}); err != nil {
		t.Fatalf("interaction below 2 GiB: %v", err)
	}
	// Attachment bytes and terminal output are not.
	if _, err := archive.StoreBlob(strings.NewReader("x"), "text/plain"); !errors.Is(err, ErrArchivePaused) {
		t.Fatalf("blob below 2 GiB: %v", err)
	}
	log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("skipped"))
	flushArchive(t, archive)
	if count := archiveCount(t, archive, `SELECT count(*) FROM messages WHERE id = 'm1'`) + archiveCount(t, archive, `SELECT count(*) FROM interactions`); count != 2 {
		t.Fatalf("chat text below 2 GiB: %d rows", count)
	}
	stats, err := archive.Stats(context.Background(), []string{"p1"})
	if err != nil || !stats.CapturePaused || stats.ChatCapturePaused || stats.SkippedWrites != 1 || stats.FreeBytes == nil || *stats.FreeBytes != archiveMinimumFree-1 ||
		stats.MinimumFreeBytes != archiveMinimumFree || stats.ChatMinimumFreeBytes != archiveChatMinimumFree {
		t.Fatalf("stats below 2 GiB %+v %v", stats, err)
	}
	log.mu.Lock()
	gap := log.gap
	log.mu.Unlock()
	if gap != int64(len("skipped")) {
		t.Fatalf("terminal gap %d", gap)
	}

	// Below 256 MiB chat text pauses too.
	free.Store(archiveChatMinimumFree - 1)
	archive.maintain()
	if err := archive.UpsertChat(ArchiveChat{ID: "c2", ProjectID: "p1", Provider: "opencode"}); !errors.Is(err, ErrArchivePaused) {
		t.Fatalf("chat below 256 MiB: %v", err)
	}
	if err := archive.UpsertMessage(textMessage("c1", "m2", "user", 1, "dropped")); !errors.Is(err, ErrArchivePaused) {
		t.Fatalf("message below 256 MiB: %v", err)
	}
	if err := archive.RecordInteraction(ArchiveInteraction{ID: "i2", ChatID: "c1", Kind: "question"}); !errors.Is(err, ErrArchivePaused) {
		t.Fatalf("interaction below 256 MiB: %v", err)
	}
	if _, err := archive.importChat(ArchiveChat{ID: "c1", ProjectID: "p1", Provider: "opencode"}, nil, false); !errors.Is(err, ErrArchivePaused) {
		t.Fatalf("import below 256 MiB: %v", err)
	}
	// Deleting frees space and still works.
	if err := archive.DeleteMessage("c1", "m1"); err != nil {
		t.Fatalf("delete below 256 MiB: %v", err)
	}
	stats, _ = archive.Stats(context.Background(), []string{"p1"})
	if !stats.CapturePaused || !stats.ChatCapturePaused || stats.SkippedWrites != 5 {
		t.Fatalf("stats below 256 MiB %+v", stats)
	}

	// Each resumes above its own floor.
	free.Store(archiveChatMinimumFree)
	archive.maintain()
	if !archive.paused.Load() || archive.chatPaused.Load() {
		t.Fatal("chat text did not resume at 256 MiB")
	}
	free.Store(archiveMinimumFree)
	archive.maintain()
	if archive.paused.Load() {
		t.Fatal("capture did not resume")
	}
	mustArchiveChat(t, archive, "c1", "p1", "Resumed")
	flushArchive(t, archive)
	// An unknown amount of free space never pauses capture.
	unknown := testArchive(t, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return 0, errors.New("statfs failed") }})
	stats, _ = unknown.Stats(context.Background(), nil)
	if unknown.paused.Load() || unknown.chatPaused.Load() || stats.FreeBytes != nil {
		t.Fatalf("unknown free space: paused=%v chat=%v free=%v", unknown.paused.Load(), unknown.chatPaused.Load(), stats.FreeBytes)
	}
}
