package host

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestArchiveMigratesVersion5WithDataIntact(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive := openTestArchive(t, directory, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Before the vault")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "kept through the migration"))
	flushArchive(t, archive)
	before, err := archive.vaultChangeRows(t.Context(), 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	// Turn it back into a version 5 database.
	db, err := sql.Open("sqlite", filepath.Join(directory, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{`DROP TABLE vault_files`, `DROP TABLE vault_state`,
		`DROP INDEX terminal_logs_by_terminal`, `ALTER TABLE terminal_logs DROP COLUMN end_reason`,
		`ALTER TABLE terminal_logs DROP COLUMN ended_by_device_id`, `ALTER TABLE terminal_logs DROP COLUMN conversation_id`,
		`ALTER TABLE terminal_logs DROP COLUMN folder`, `UPDATE meta SET schema_version = 5`} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	reopened := openTestArchive(t, directory, ArchiveOptions{})
	if version := archiveCount(t, reopened, `SELECT schema_version FROM meta`); version != int64(len(archiveMigrations)) || len(archiveMigrations) != 8 {
		t.Fatalf("schema version %d of %d", version, len(archiveMigrations))
	}
	chat, err := reopened.ArchivedChat(t.Context(), "c1")
	if err != nil || chat.Title != "Before the vault" {
		t.Fatalf("chat after migration %+v %v", chat, err)
	}
	page, err := reopened.ChatPage(t.Context(), "c1", "", 10)
	if err != nil || len(page.Messages) != 1 || page.Messages[0].Parts[0].Text != "kept through the migration" {
		t.Fatalf("messages after migration %+v %v", page, err)
	}
	after, err := reopened.vaultChangeRows(t.Context(), 0, 100)
	if err != nil || fmt.Sprint(after) != fmt.Sprint(before) {
		t.Fatalf("change feed after migration %v (was %v) %v", after, before, err)
	}
	// The new tables start empty and take records.
	if _, err := reopened.vaultState(t.Context(), "v1"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("vault state in a migrated archive: %v", err)
	}
	if err := reopened.saveVault(vaultStateRecord{VaultID: "v1", Root: "/vault", Cursor: after.High}, nil, nil); err != nil {
		t.Fatal(err)
	}
}

// vaultRowNames lists changes as entity:id:op:project.
func vaultRowNames(rows []vaultChange) string {
	names := []string{}
	for _, row := range rows {
		names = append(names, row.Entity+":"+row.EntityID+":"+row.Op+":"+row.ProjectID)
	}
	return strings.Join(names, " ")
}

func TestVaultChangeRowsSeeEveryProjectInOrder(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	ctx := context.Background()
	empty, err := archive.vaultChangeRows(ctx, 0, 10)
	if err != nil || len(empty.Rows) != 0 || empty.High != 0 {
		t.Fatalf("empty archive %+v %v", empty, err)
	}
	mustArchiveChat(t, archive, "c1", "p1", "One")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "first"))
	mustArchiveMessage(t, archive, textMessage("c1", "m2", "assistant", 1, "second"))
	mustArchiveChat(t, archive, "c2", "p2", "Two")
	log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: "removed-project"})
	if err != nil {
		t.Fatal(err)
	}
	log.Close("exited", nil)
	flushArchive(t, archive)
	// A deleted message and a deleted chat leave tombstones at the end.
	if err := archive.DeleteMessage("c1", "m2"); err != nil {
		t.Fatal(err)
	}
	if err := archive.DeleteChat("c2"); err != nil {
		t.Fatal(err)
	}

	all, err := archive.vaultChangeRows(ctx, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	want := "chat:c1:upsert:p1 message:m1:upsert:p1 terminalLog:" + log.ID() + ":upsert:removed-project message:m2:delete:p1 chat:c2:delete:p2"
	if got := vaultRowNames(all.Rows); got != want {
		t.Fatalf("rows\n got %s\nwant %s", got, want)
	}
	if all.Rows[1].ChatID != "c1" || all.Rows[2].ChatID != "" {
		t.Fatalf("chat ids %+v", all.Rows)
	}
	if last := all.Rows[len(all.Rows)-1].Seq; all.High != last {
		t.Fatalf("high-water mark %d, newest row %d", all.High, last)
	}
	for index := 1; index < len(all.Rows); index++ {
		if all.Rows[index].Seq <= all.Rows[index-1].Seq {
			t.Fatalf("rows out of order %+v", all.Rows)
		}
	}
	// The project list that limits a device's feed does not limit the vault.
	feed, err := archive.Changes(ctx, "", 100, []string{"p1"})
	if err != nil || len(feed.Changes) >= len(all.Rows) {
		t.Fatalf("device feed %d rows, vault %d", len(feed.Changes), len(all.Rows))
	}

	// Pages follow the cursor and always report the newest seq.
	first, err := archive.vaultChangeRows(ctx, 0, 2)
	if err != nil || vaultRowNames(first.Rows) != "chat:c1:upsert:p1 message:m1:upsert:p1" || first.High != all.High {
		t.Fatalf("first page %+v %v", first, err)
	}
	rest, err := archive.vaultChangeRows(ctx, first.Rows[1].Seq, 100)
	if err != nil || vaultRowNames(rest.Rows) != vaultRowNames(all.Rows[2:]) {
		t.Fatalf("second page %+v %v", rest, err)
	}
	none, err := archive.vaultChangeRows(ctx, all.High, 100)
	if err != nil || len(none.Rows) != 0 || none.High != all.High {
		t.Fatalf("caught up %+v %v", none, err)
	}
}

func TestVaultFilesKeepOnePathPerNote(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{Now: func() time.Time { return archiveTestStart }})
	ctx := context.Background()
	if _, err := archive.vaultState(ctx, "v1"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("missing state: %v", err)
	}
	if _, err := archive.vaultFile(ctx, "v1", vaultFileKey{Entity: "chat", EntityID: "c1", Part: 1}); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("missing file: %v", err)
	}
	state := vaultStateRecord{VaultID: "v1", Root: "/Users/me/AgentLand Vault", Cursor: 5, BackfillUntil: 4, BackfillTotal: 3, BackfillDone: 1}
	c1 := vaultFileKey{Entity: "chat", EntityID: "c1", Part: 1}
	first := vaultFileRecord{vaultFileKey: c1, Path: "Chats/AgentLand/2026-09-23 One (abc123).md", Digest: "d1", FirstTitle: "One"}
	if err := archive.saveVault(state, []vaultFileRecord{first}, nil); err != nil {
		t.Fatal(err)
	}
	saved, err := archive.vaultState(ctx, "v1")
	if err != nil || saved.Root != state.Root || saved.Cursor != 5 || saved.BackfillUntil != 4 || saved.BackfillTotal != 3 || saved.BackfillDone != 1 || !saved.UpdatedAt.Equal(archiveTestStart) {
		t.Fatalf("state %+v %v", saved, err)
	}
	file, err := archive.vaultFile(ctx, "v1", c1)
	if err != nil || file.Path != first.Path || file.Digest != "d1" || file.FirstTitle != "One" || !file.WrittenAt.Equal(archiveTestStart) {
		t.Fatalf("file %+v %v", file, err)
	}
	if found, err := archive.vaultFileAt(ctx, "v1", first.Path); err != nil || found.vaultFileKey != c1 {
		t.Fatalf("file at path %+v %v", found, err)
	}

	// What hubs list of a note is kept with its first part.
	listed := vaultFileRecord{vaultFileKey: vaultFileKey{Entity: "terminalLog", EntityID: "tl_1", Part: 1}, Path: "Terminals/AgentLand/2026-09-23 1200 shell (q1w2e3).md",
		Digest: "d5", Listing: vaultListing{Title: "Build", ProjectID: "p1", Started: "2026-09-23T12:00:00.000Z"}}
	hub := vaultFileRecord{vaultFileKey: vaultFileKey{Entity: "workspace", EntityID: "p1", Part: 1}, Path: "Workspaces/AgentLand.md", FirstTitle: "AgentLand"}
	if err := archive.saveVault(state, []vaultFileRecord{listed, hub}, nil); err != nil {
		t.Fatal(err)
	}
	notes, err := archive.vaultFiles(ctx, "v1", "chat", "terminalLog")
	if err != nil || len(notes) != 2 || notes[0].vaultFileKey != c1 || notes[0].Listing != (vaultListing{}) || notes[1].Listing != listed.Listing {
		t.Fatalf("notes %+v %v", notes, err)
	}
	if hubs, err := archive.vaultFiles(ctx, "v1", "workspace"); err != nil || len(hubs) != 1 || hubs[0].Path != hub.Path || hubs[0].Digest != "" {
		t.Fatalf("hubs %+v %v", hubs, err)
	}

	// A note found elsewhere (moved in Obsidian) keeps one record, at its new path.
	moved := vaultFileRecord{vaultFileKey: c1, Path: "Notes/Kept/One.md", Digest: "d2"}
	state.Cursor = 6
	if err := archive.saveVault(state, []vaultFileRecord{moved}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := archive.vaultFileAt(ctx, "v1", first.Path); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("old path still recorded: %v", err)
	}
	if count := archiveCount(t, archive, `SELECT count(*) FROM vault_files WHERE vault_id = 'v1' AND entity = 'chat' AND entity_id = 'c1'`); count != 1 {
		t.Fatalf("records for one note: %d", count)
	}

	// Another note cannot take that path; the whole batch is refused.
	c2 := vaultFileKey{Entity: "chat", EntityID: "c2", Part: 1}
	state.Cursor = 7
	if err := archive.saveVault(state, []vaultFileRecord{{vaultFileKey: c2, Path: moved.Path, Digest: "d3"}}, nil); err == nil {
		t.Fatal("two notes share a path")
	}
	if saved, _ := archive.vaultState(ctx, "v1"); saved.Cursor != 6 {
		t.Fatalf("a refused batch moved the cursor to %d", saved.Cursor)
	}
	if _, err := archive.vaultFile(ctx, "v1", c2); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("refused note recorded: %v", err)
	}

	// Another vault keeps its own paths.
	if err := archive.saveVault(vaultStateRecord{VaultID: "v2", Root: "/elsewhere"}, []vaultFileRecord{{vaultFileKey: c2, Path: moved.Path}}, nil); err != nil {
		t.Fatal(err)
	}
	// A removed record frees its path in the same batch.
	if err := archive.saveVault(state, []vaultFileRecord{{vaultFileKey: c2, Path: moved.Path, Digest: "d4"}}, []vaultFileKey{c1}); err != nil {
		t.Fatal(err)
	}
	if _, err := archive.vaultFile(ctx, "v1", c1); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("removed record kept: %v", err)
	}
	if found, err := archive.vaultFileAt(ctx, "v1", moved.Path); err != nil || found.vaultFileKey != c2 || found.Digest != "d4" {
		t.Fatalf("path after removal %+v %v", found, err)
	}
	for _, bad := range []vaultFileRecord{{vaultFileKey: vaultFileKey{Entity: "chat", EntityID: "", Part: 1}, Path: "x.md"}, {vaultFileKey: c1, Path: ""}, {vaultFileKey: vaultFileKey{Entity: "chat", EntityID: "c1", Part: 0}, Path: "x.md"}} {
		if err := archive.saveVault(state, []vaultFileRecord{bad}, nil); !errors.Is(err, errArchiveInvalid) {
			t.Fatalf("invalid record %+v saved: %v", bad, err)
		}
	}
	if err := archive.saveVault(vaultStateRecord{}, nil, nil); !errors.Is(err, errArchiveInvalid) {
		t.Fatalf("state without a vault id saved: %v", err)
	}
	// Vault writes are not changes: they never wake the change feed.
	signal := archive.changeSignal()
	if err := archive.saveVault(state, nil, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-signal:
		t.Fatal("a vault write signalled the change feed")
	default:
	}
}
