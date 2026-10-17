package host

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// Backfill (M1 chunk B2).

// nullTimeCLIChat is a chats file with one Claude Code chat from before
// message times were kept: its times are null.
func nullTimeCLIChat(directory string) []byte {
	data, _ := json.Marshal(map[string]any{"claude:0123abcd": map[string]any{
		"session":   map[string]any{"id": "claude:0123abcd", "title": "Old chat", "projectId": "p1", "provider": "claude"},
		"directory": directory,
		"messages":  []any{map[string]any{"id": "u1", "role": "user", "text": "Old question"}, map[string]any{"id": "a1", "role": "assistant", "text": "Old answer"}},
		"updatedAt": nil,
		"created":   nil,
	}})
	return data
}

func backfillRows(t *testing.T, archive *Archive) map[string]ArchiveBackfillProgress {
	t.Helper()
	stats, err := archive.Stats(context.Background(), []string{"p1"})
	if err != nil {
		t.Fatal(err)
	}
	rows := map[string]ArchiveBackfillProgress{}
	for _, row := range stats.Backfill {
		rows[row.Source+"/"+row.Scope] = row
	}
	return rows
}

func highestChange(t *testing.T, archive *Archive) int64 {
	t.Helper()
	return archiveCount(t, archive, `SELECT COALESCE(max(seq), 0) FROM changes`)
}

func TestBackfillImportsOpenCodeSessionsAndCLIChatsOnce(t *testing.T) {
	clock := archiveTestStart
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{Now: func() time.Time { return clock }}, nullTimeCLIChat)
	f.oc.set(func(oc *fakeOpenCode) {
		for _, id := range []string{"s2", "s3"} {
			oc.reverts[id] = ""
		}
		oc.updated["s1"], oc.updated["s2"], oc.updated["s3"] = fixtureEpochMs+1000, fixtureEpochMs+2000, fixtureEpochMs+3000
		// s2 is rewound to its second user message; s3's reply was left
		// streaming in an idle session.
		oc.reverts["s2"] = fixtureID("msg", 23)
		oc.status["s3"] = "idle"
	})
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	f.oc.addMessages("s2", ocUserFixture(21, "Keep"), ocAssistantFixture(22, 21, "Kept"), ocUserFixture(23, "Rewound"), ocAssistantFixture(24, 23, "Hidden reply"))
	f.oc.addMessages("s3", ocUserFixture(31, "Start"), map[string]any{"info": ocAssistantInfo(32, 31, false), "parts": []any{ocTextPartFixture(32, 1, "Half a", false)}})
	if err := f.host.backfill.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	one := archivedPage(t, archive, "s1")
	if len(one.Messages) != 2 || one.Messages[1].Usage == nil || one.Messages[1].Usage.Input != 100 || one.Messages[1].Model != "anthropic/claude" ||
		one.Messages[0].CreatedAt != chatTime(fixtureEpochMs+1000) || one.Chat.CreatedAt != chatTime(fixtureEpochMs-1000) || one.Chat.UpdatedAt != chatTime(fixtureEpochMs+1000) ||
		one.Chat.Model != "anthropic/claude" || one.Chat.Mode != "build" {
		t.Fatalf("s1 %+v", one)
	}
	two := archivedPage(t, archive, "s2")
	if len(two.Messages) != 4 || two.Messages[1].Hidden || !two.Messages[2].Hidden || !two.Messages[3].Hidden {
		t.Fatalf("s2 hidden flags %+v", two.Messages)
	}
	three := archivedPage(t, archive, "s3")
	if len(three.Messages) != 2 || three.Messages[1].Status != "aborted" || three.Messages[1].Parts[0].Text != "Half a" {
		t.Fatalf("s3 %+v", three.Messages)
	}
	old := archivedPage(t, archive, "claude:0123abcd")
	if old.Chat.Provider != "claude" || old.Chat.Title != "Old chat" || len(old.Messages) != 2 || old.Messages[1].Parts[0].Text != "Old answer" ||
		old.Messages[0].CreatedAt != "2026-09-23T12:00:00.000Z" || old.Messages[1].Model != "claude/default" {
		t.Fatalf("the CLI chat without times %+v", old)
	}
	rows := backfillRows(t, archive)
	if row := rows["opencode/p1"]; !row.Done || row.Chats != 3 || row.ChatsDone != 3 || row.Imported != 8 {
		t.Fatalf("OpenCode progress %+v", row)
	}
	if row := rows["cli/p1"]; !row.Done || row.Chats != 1 || row.ChatsDone != 1 || row.Imported != 2 {
		t.Fatalf("CLI progress %+v", row)
	}

	// Running it again (a later start, with the clock moved on) reads only
	// the session list and changes nothing.
	clock = archiveTestStart.Add(time.Hour)
	seq := highestChange(t, archive)
	var pageReads, listReads int
	f.oc.set(func(oc *fakeOpenCode) { pageReads, listReads = len(oc.pageReads), oc.listReads })
	if err := f.host.backfill.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.oc.set(func(oc *fakeOpenCode) {
		if len(oc.pageReads) != pageReads || oc.listReads != listReads+1 {
			t.Errorf("a repeated pass read %v and listed %d times", oc.pageReads[pageReads:], oc.listReads-listReads)
		}
	})
	if after := highestChange(t, archive); after != seq {
		t.Fatalf("a repeated pass changed the archive: seq %d -> %d", seq, after)
	}
	if again := backfillRows(t, archive); again["opencode/p1"].Imported != 8 || again["cli/p1"].Imported != 2 {
		t.Fatalf("progress after a repeated pass %+v", again)
	}
	if page := archivedPage(t, archive, "claude:0123abcd"); page.Messages[0].CreatedAt != "2026-09-23T12:00:00.000Z" {
		t.Fatalf("a record without times moved: %+v", page.Messages[0])
	}

	// A session updated since is read again; the others are not.
	f.oc.addMessages("s1", ocUserFixture(3, "Later"))
	f.oc.set(func(oc *fakeOpenCode) {
		oc.updated["s1"] = fixtureEpochMs + 9000
		pageReads = len(oc.pageReads)
	})
	if err := f.host.backfill.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.oc.set(func(oc *fakeOpenCode) {
		if reads := strings.Join(oc.pageReads[pageReads:], ","); reads != "s1 " {
			t.Errorf("pages read for the update: %q", reads)
		}
	})
	if page := archivedPage(t, archive, "s1"); len(page.Messages) != 3 {
		t.Fatalf("the update was not imported: %+v", page.Messages)
	}
	if row := backfillRows(t, archive)["opencode/p1"]; !row.Done || row.Imported != 9 || row.ChatsDone != 3 {
		t.Fatalf("progress after the update %+v", row)
	}
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures %d: %s", archive.failures.Load(), archive.lastErr)
	}
}

func TestBackfillWaitsWhileAChatStreams(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	hubChatFor(t, f, "s1")
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	var reads int
	f.oc.set(func(oc *fakeOpenCode) { reads = oc.listReads + len(oc.pageReads) })
	done := make(chan error, 1)
	go func() { done <- f.host.backfill.run(context.Background()) }()
	waitFor(t, "the backfill to pause", func() bool { return f.host.backfill.status() == "paused" })
	time.Sleep(100 * time.Millisecond)
	f.oc.set(func(oc *fakeOpenCode) {
		if now := oc.listReads + len(oc.pageReads); now != reads {
			t.Errorf("the backfill made %d requests while a chat streamed", now-reads)
		}
	})
	// This Mac's stats show why the backfill waits.
	stats := decodeBody[ArchiveStats](t, localRequest(t, f.host.Handler(), "GET", "/v1/archive/stats", routeLocalToken, nil))
	if stats.BackfillState != "paused" {
		t.Fatalf("stats while paused %+v", stats)
	}
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the backfill did not resume")
	}
	if row := backfillRows(t, archive)["opencode/p1"]; !row.Done {
		t.Fatalf("progress %+v", row)
	}
}

func TestBackfillResumesWhereItStoppedAfterARestart(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.set(func(oc *fakeOpenCode) {
		oc.reverts["s2"] = ""
		oc.updated["s1"], oc.updated["s2"] = fixtureEpochMs+1000, fixtureEpochMs+2000
	})
	for n := 1; n <= 120; n++ {
		f.oc.addMessages("s1", ocUserFixture(n, fmt.Sprintf("Message %d", n)))
	}
	f.oc.addMessages("s2", ocUserFixture(500, "Other"))
	ctx, cancel := context.WithCancel(context.Background())
	f.host.backfill.afterPage = cancel
	if err := f.host.backfill.run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("interrupted pass: %v", err)
	}
	row, err := archive.backfillRow(context.Background(), "opencode", "p1")
	if err != nil {
		t.Fatal(err)
	}
	var cursor openCodeCursor
	json.Unmarshal([]byte(row.cursor), &cursor)
	if row.done || cursor.Session != "s1" || cursor.Before == "" || row.imported != 50 || row.chatsDone != 0 {
		t.Fatalf("saved place %+v %+v", row, cursor)
	}
	// A new host on the same state continues from the saved page.
	if err := f.host.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openTestArchive(t, archive.directory, ArchiveOptions{})
	restarted := newHost(f.store, NewOpenCodeAdapter(f.oc.server.URL, "opencode", "fixture", f.oc.server.Client()), HostOptions{Archive: reopened})
	t.Cleanup(func() { restarted.Close() })
	restarted.backfill.gap = 0
	var reads int
	f.oc.set(func(oc *fakeOpenCode) { reads = len(oc.pageReads) })
	if err := restarted.backfill.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.oc.set(func(oc *fakeOpenCode) {
		after := oc.pageReads[reads:]
		if len(after) != 3 || after[0] != "s1 "+cursor.Before || !strings.HasPrefix(after[1], "s1 ") || after[2] != "s2 " {
			t.Errorf("pages read after the restart: %v", after)
		}
	})
	if count := archiveCount(t, reopened, `SELECT count(*) FROM messages WHERE chat_id = 's1'`); count != 120 {
		t.Fatalf("s1 has %d messages", count)
	}
	if row := backfillRows(t, reopened)["opencode/p1"]; !row.Done || row.Imported != 121 || row.ChatsDone != 2 || row.Chats != 2 {
		t.Fatalf("progress after the restart %+v", row)
	}
}

func TestBackfillPacesOpenCodeRequestsAndRetriesLater(t *testing.T) {
	f, _, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.set(func(oc *fakeOpenCode) {
		for n := 2; n <= 4; n++ {
			oc.reverts[fmt.Sprintf("s%d", n)] = ""
		}
	})
	backfill := f.host.backfill
	backfill.gap = 40 * time.Millisecond
	started := time.Now()
	if err := backfill.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	// A list, the statuses and one page for each of four sessions.
	if elapsed := time.Since(started); elapsed < 5*backfill.gap {
		t.Fatalf("six requests took %v with a %v gap", elapsed, backfill.gap)
	}
	// A pass that fails (OpenCode unreachable) is retried.
	f.oc.server.Close()
	backfill.retry = time.Hour
	backfill.start()
	waitFor(t, "a retry to be scheduled", func() bool { return backfill.status() == "retrying" })
	backfill.stop()
}

// A finished host keeps passing, so sessions driven outside AgentLand while
// it runs are archived without a restart.
func TestBackfillRunsAgainAfterFinishing(t *testing.T) {
	f, _, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	backfill := f.host.backfill
	backfill.stop()
	backfill.gap, backfill.every = 0, 20*time.Millisecond
	f.oc.set(func(oc *fakeOpenCode) { oc.listReads = 0 })
	backfill.start()
	waitFor(t, "a second pass", func() bool {
		f.oc.mu.Lock()
		defer f.oc.mu.Unlock()
		return f.oc.listReads >= 2
	})
	backfill.stop()
}
