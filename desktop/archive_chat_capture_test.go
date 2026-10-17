package host

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Chat capture (M1 chunk B2): the hub's chats in the archive.

// newArchiveChatFixture is newChatFixture with an archive at
// <state>.archive, a capture interval of 20 ms, an unpaced backfill (not
// started) and an HTTP server for event streams. chatsFile, when set, is
// written as <state>.chats.json before the CLI chats load it.
func newArchiveChatFixture(t *testing.T, options ArchiveOptions, chatsFile func(directory string) []byte) (*chatFixture, *Archive, *httptest.Server) {
	t.Helper()
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Fixture", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	f := &chatFixture{store: store, oc: oc, runner: &fakeCLIChatRunner{}, clock: &testClock{now: time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)}}
	var err error
	if f.attachments, err = NewAttachmentStore(store.Path + ".attachments"); err != nil {
		t.Fatal(err)
	}
	f.queuePath = store.Path + ".queue.json"
	if f.queue, err = NewPromptQueue(f.queuePath); err != nil {
		t.Fatal(err)
	}
	f.chatsPath = store.Path + ".chats.json"
	if chatsFile != nil {
		if err := writePrivateState(f.chatsPath, chatsFile(directory)); err != nil {
			t.Fatal(err)
		}
	}
	if f.chats, err = NewCLIChats(f.chatsPath, f.runner); err != nil {
		t.Fatal(err)
	}
	f.attachments.now = f.clock.Now
	f.queue.now = f.clock.Now
	archive := openTestArchive(t, store.Path+".archive", options)
	f.host = newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: f.chats, Attachments: f.attachments, Queue: f.queue, Archive: archive, LocalSessionToken: routeLocalToken})
	f.host.chatPace, f.host.chatBeatEvery, f.host.chatAuthEvery = time.Millisecond, time.Hour, time.Hour
	f.host.chat.capture.every = 20 * time.Millisecond
	f.host.backfill.gap, f.host.backfill.pausePoll = 0, 10*time.Millisecond
	t.Cleanup(func() { f.host.Close() })
	f.token = paired(t, f.host, store)
	server := httptest.NewServer(f.host.Handler())
	t.Cleanup(server.Close)
	return f, archive, server
}

// newArchiveCodexFixture is newCodexFixture with an archive.
func newArchiveCodexFixture(t *testing.T, fake *codexFake) (*codexFixture, *Archive) {
	t.Helper()
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Codex", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(store.Path+".chats.json", codexTestRunner{config: fake.config()})
	if err != nil {
		t.Fatal(err)
	}
	archive := openTestArchive(t, store.Path+".archive", ArchiveOptions{})
	host := newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: chats, Archive: archive})
	host.chatPace, host.chatBeatEvery, host.chatAuthEvery = time.Millisecond, time.Hour, time.Hour
	host.chat.capture.every = 20 * time.Millisecond
	server := httptest.NewServer(host.Handler())
	f := &codexFixture{t: t, fake: fake, host: host, store: store, chats: chats, server: server, project: mustProject(t, store)}
	t.Cleanup(func() {
		server.Close()
		host.Close()
	})
	f.token = paired(t, host, store)
	return f, archive
}

func archivedPage(t *testing.T, archive *Archive, chatID string) ArchiveChatPage {
	t.Helper()
	page, err := archive.ChatPage(context.Background(), chatID, "", 50)
	if err != nil {
		t.Fatalf("archived chat %s: %v", chatID, err)
	}
	return page
}

// waitArchived waits until the archive's copy of a chat passes check.
func waitArchived(t *testing.T, archive *Archive, chatID, what string, check func(ArchiveChatPage) bool) ArchiveChatPage {
	t.Helper()
	var page ArchiveChatPage
	waitFor(t, what, func() bool {
		var err error
		page, err = archive.ChatPage(context.Background(), chatID, "", 50)
		return err == nil && check(page)
	})
	return page
}

// sameArchived checks that the archive holds the hub's messages as they are:
// IDs, order, times, model, usage and parts.
func sameArchived(t *testing.T, archived []archiveMessageJSON, live []ChatMessage) {
	t.Helper()
	if len(archived) != len(live) {
		t.Fatalf("%d archived messages, %d live", len(archived), len(live))
	}
	for index, message := range live {
		got := archived[index]
		if got.ID != message.ID || got.Role != message.Role || got.Status != message.Status || got.Ord != message.Ord || got.TurnID != message.TurnID ||
			got.CreatedAt != message.CreatedAt || got.CompletedAt != message.CompletedAt || got.Model != message.Model || got.Hidden {
			t.Fatalf("message %d:\n archived %+v\n live     %+v", index, got, message)
		}
		if (got.Usage == nil) != (message.Usage == nil) || (got.Usage != nil && (got.Usage.Input != message.Usage.Input || got.Usage.Output != message.Usage.Output)) {
			t.Fatalf("usage of %s: %+v vs %+v", message.ID, got.Usage, message.Usage)
		}
		if len(got.Parts) != len(message.Parts) {
			t.Fatalf("parts of %s: %+v vs %+v", message.ID, got.Parts, message.Parts)
		}
		for number, part := range message.Parts {
			stored := got.Parts[number]
			if stored.ID != part.ID || stored.Kind != part.Kind || stored.Text != part.Text || stored.Start != part.Start || stored.End != part.End {
				t.Fatalf("part %d of %s: %+v vs %+v", number, message.ID, stored, part)
			}
			if part.Tool != nil && (stored.Tool == nil || stored.Tool.Name != part.Tool.Name || stored.Tool.Output != part.Tool.Output || stored.Tool.Status != part.Tool.Status) {
				t.Fatalf("tool of %s: %+v vs %+v", message.ID, stored.Tool, part.Tool)
			}
		}
	}
}

func TestChatCaptureWritesAStreamedOpenCodeChatToTheArchive(t *testing.T) {
	f, archive, server := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	stream, status, body := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	if status != 200 {
		t.Fatalf("open: %d %s", status, body)
	}
	stream.until(t, "snapshot", 5*time.Second)
	emitTurn(f, 3, 4, "Hel", "lo ", "wörld")
	stream.until(t, "turn.finished", 5*time.Second)
	page := waitArchived(t, archive, "s1", "the finished reply", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 4 && page.Messages[3].Status == "complete" && len(page.Messages[3].Parts) == 1 && page.Messages[3].Parts[0].Text == "Hello wörld"
	})
	sameArchived(t, page.Messages, hubMessages(f.host, sessionKey{"p1", "s1"}))
	if chat := page.Chat; chat.Provider != "opencode" || chat.Title != "Fixture" || chat.Model != "anthropic/claude" || chat.Mode != "build" ||
		chat.CreatedAt != chatTime(fixtureEpochMs+1000) || chat.UpdatedAt != chatTime(fixtureEpochMs+4500) {
		t.Fatalf("chat %+v", chat)
	}
	// Devices receive it through the change feed and the chat route.
	changes := decodeBody[ArchiveChanges](t, f.call(t, "GET", "/v1/archive/changes", nil))
	want := []string{"chat:s1:upsert"}
	for _, message := range page.Messages {
		want = append(want, "message:"+message.ID+":upsert")
	}
	got := changeNames(t, changes)
	if strings.Join(sortedCopy(got), " ") != strings.Join(sortedCopy(want), " ") {
		t.Fatalf("change feed %v, want %v", got, want)
	}
	routed := decodeBody[ArchiveChatPage](t, f.call(t, "GET", "/v1/archive/chat?chatId=s1", nil))
	sameArchived(t, routed.Messages, hubMessages(f.host, sessionKey{"p1", "s1"}))
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures %d: %s", archive.failures.Load(), archive.lastErr)
	}
}

func sortedCopy(values []string) []string {
	copied := slices.Clone(values)
	slices.Sort(copied)
	return copied
}

func TestChatCaptureSnapshotsAStreamingReply(t *testing.T) {
	f, archive, server := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.host.chat.mu.Lock()
	f.host.chat.capture.every = 150 * time.Millisecond
	f.host.chat.mu.Unlock()
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	user := ocUserFixture(3, "Write a long answer")
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": user["info"]})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": user["parts"].([]any)[0]})
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(4, 3, false)})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(4, 1, "", false)})
	delta := func(text string) {
		f.oc.emit("message.part.delta", map[string]any{"sessionID": "s1", "messageID": fixtureID("msg", 4), "partID": fixtureID("prt", 401), "field": "text", "delta": text})
	}
	// While the reply streams, the archive follows it within the interval,
	// so a crash loses little.
	delta("First half, ")
	waitArchived(t, archive, "s1", "a streaming snapshot", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 2 && page.Messages[1].Status == "streaming" && len(page.Messages[1].Parts) == 1 && page.Messages[1].Parts[0].Text == "First half, "
	})
	delta("second half.")
	waitArchived(t, archive, "s1", "a later snapshot", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 2 && len(page.Messages[1].Parts) == 1 && page.Messages[1].Parts[0].Text == "First half, second half."
	})
	f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": ocTextPartFixture(4, 1, "First half, second half.", true)})
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": ocAssistantInfo(4, 3, true)})
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
	stream.until(t, "turn.finished", 5*time.Second)
	page := waitArchived(t, archive, "s1", "the final reply", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 2 && page.Messages[1].Status == "complete"
	})
	if usage := page.Messages[1].Usage; usage == nil || usage.Input != 100 || page.Messages[1].CompletedAt == "" {
		t.Fatalf("final reply %+v", page.Messages[1])
	}
}

func TestChatCaptureMakesTheUserMessageDurableBeforeDelivery(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	gate, received := make(chan struct{}), make(chan struct{}, 1)
	f.oc.set(func(oc *fakeOpenCode) { oc.promptGate, oc.received = gate, received })
	notes := []byte("# Notes\nkeep these\n")
	upload := f.uploadID(t, f.token, "s1", "notes.md", "text/markdown", notes)
	body, _ := json.Marshal(map[string]any{"projectId": "p1", "sessionId": "s1", "text": "Keep this", "attachments": []string{upload}})
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		r := httptest.NewRequest("POST", "/v1/messages", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+f.token)
		w := httptest.NewRecorder()
		f.host.Handler().ServeHTTP(w, r)
		done <- w
	}()
	select {
	case <-received:
	case <-time.After(10 * time.Second):
		t.Fatal("OpenCode never received the prompt")
	}
	// OpenCode holds the prompt without answering. A host that crashed now
	// would find the message in its archive when it starts again.
	restarted, err := OpenArchive(archive.directory, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	page, err := restarted.ChatPage(context.Background(), "s1", "", 50)
	if err != nil || len(page.Messages) != 1 {
		t.Fatalf("after the crash: %+v %v", page, err)
	}
	sent := page.Messages[0]
	sum := sha256.Sum256(notes)
	digest := hex.EncodeToString(sum[:])
	if sent.Role != "user" || sent.Status != "complete" || len(sent.Parts) != 2 || sent.Parts[0].Text != "Keep this" ||
		sent.Parts[1].Attachment == nil || sent.Parts[1].Attachment.Name != "notes.md" || sent.Parts[1].Attachment.SHA256 != digest || sent.Parts[1].Attachment.Size != int64(len(notes)) {
		t.Fatalf("archived before delivery: %+v", sent)
	}
	if stored, err := os.ReadFile(restarted.blobPath(digest)); err != nil || !bytes.Equal(stored, notes) {
		t.Fatalf("attachment bytes %q %v", stored, err)
	}
	close(gate)
	w := <-done
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	if w.Code != 202 || receipt.MessageID != sent.ID {
		t.Fatalf("send: %d %s, archived as %s", w.Code, w.Body, sent.ID)
	}
	// OpenCode stored the prompt under the archived message's ID.
	var prompt struct{ MessageID string }
	json.Unmarshal(f.oc.promptBodies()[0], &prompt)
	if prompt.MessageID != sent.ID {
		t.Fatalf("OpenCode's message %q, archived %q", prompt.MessageID, sent.ID)
	}
}

func TestChatCaptureRemovesACopyThatWasNeverDelivered(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.set(func(oc *fakeOpenCode) { oc.promptCode = 400 })
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "Rejected"}); w.Code == 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	flushArchive(t, archive)
	if count := archiveCount(t, archive, `SELECT count(*) FROM messages WHERE chat_id = 's1'`); count != 0 {
		t.Fatalf("a prompt OpenCode refused stayed archived: %d", count)
	}
	changes, _ := archive.Changes(context.Background(), "", 100, []string{"p1"})
	if names := strings.Join(changeNames(t, changes), " "); !strings.Contains(names, ":delete") {
		t.Fatalf("no tombstone for the removed copy: %s", names)
	}
}

func TestChatCaptureRecordsCoarseCLIChats(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	id := f.cliSession(t, "claude")
	upload := f.uploadID(t, f.token, id, "plan.txt", "text/plain", []byte("step one"))
	w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": id, "text": "hello", "attachments": []string{upload}})
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	if w.Code != 202 || receipt.MessageID == "" {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	page := waitArchived(t, archive, id, "the Claude Code reply", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 2 && len(page.Messages[1].Parts) > 0 && page.Messages[1].Parts[0].Text == "Reply to hello"
	})
	user, reply := page.Messages[0], page.Messages[1]
	sum := sha256.Sum256([]byte("step one"))
	if page.Chat.Provider != "claude" || user.ID != receipt.MessageID || user.Parts[0].Text != "hello" || len(user.Parts) != 2 ||
		user.Parts[1].Attachment == nil || user.Parts[1].Attachment.SHA256 != hex.EncodeToString(sum[:]) ||
		reply.Role != "assistant" || reply.Status != "complete" || reply.Model != "claude/default" {
		t.Fatalf("archived CLI chat %+v", page)
	}
	// The run's upload is gone once it ends; the archive keeps the bytes.
	waitFor(t, "the upload to be removed", func() bool {
		f.attachments.mu.Lock()
		defer f.attachments.mu.Unlock()
		return len(f.attachments.items) == 0
	})
	if _, err := os.Stat(archive.blobPath(hex.EncodeToString(sum[:]))); err != nil {
		t.Fatalf("attachment blob: %v", err)
	}
}

// A send follows a chat no device streams: the hub keeps it through the
// turn, then lets it go.
func TestChatCaptureFollowsAnUnwatchedChatThroughItsTurn(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	hub := f.host.chat
	hub.mu.Lock()
	hub.evictIdle, hub.janitorGap, hub.followGrace = 10*time.Millisecond, 5*time.Millisecond, time.Hour
	hub.mu.Unlock()
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "Work on it"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	tracked := func() *hubChat {
		hub.mu.Lock()
		defer hub.mu.Unlock()
		return hub.chats[sessionKey{"p1", "s1"}]
	}
	time.Sleep(60 * time.Millisecond)
	if c := tracked(); c == nil {
		t.Fatal("an unwatched chat left the hub before its turn")
	}
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	time.Sleep(60 * time.Millisecond)
	if tracked() == nil {
		t.Fatal("a followed chat left the hub during its turn")
	}
	reply := ocAssistantFixture(4, 3, "Done")
	feed(t, f, "message.updated", map[string]any{"sessionID": "s1", "info": reply["info"]})
	feed(t, f, "message.part.updated", map[string]any{"sessionID": "s1", "part": reply["parts"].([]any)[0]})
	feed(t, f, "session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "idle"}})
	waitArchived(t, archive, "s1", "the reply", func(page ArchiveChatPage) bool { return len(page.Messages) == 2 })
	waitFor(t, "the chat to leave the hub after its turn", func() bool { return tracked() == nil })
}

func TestChatCaptureKeepsAttachmentBytesUnderTheProvidersCopy(t *testing.T) {
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	notes, photo := []byte("# Plan\n"), []byte("\x89PNG fixture")
	ids := []string{f.uploadID(t, f.token, "s1", "notes.md", "text/markdown", notes), f.uploadID(t, f.token, "s1", "photo.png", "image/png", photo)}
	w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "See files", "attachments": ids})
	var receipt sendReceipt
	json.Unmarshal(w.Body.Bytes(), &receipt)
	if w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	digest := func(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
	page := archivedPage(t, archive, "s1")
	if len(page.Messages) != 1 || page.Messages[0].Parts[1].Attachment.SHA256 != digest(notes) || page.Messages[0].Parts[2].Attachment.SHA256 != digest(photo) {
		t.Fatalf("sent message %+v", page.Messages)
	}
	// OpenCode's own copy names the files without their bytes (text types as
	// text/plain); the archived blobs stay referenced.
	created := float64(time.Now().UnixMilli())
	info := map[string]any{"id": receipt.MessageID, "sessionID": "s1", "role": "user", "time": map[string]any{"created": created}, "agent": "build", "model": map[string]any{"providerID": "anthropic", "modelID": "claude"}}
	f.oc.emit("message.updated", map[string]any{"sessionID": "s1", "info": info})
	for index, part := range []map[string]any{
		{"type": "text", "text": "See files"},
		{"type": "file", "mime": "text/plain", "filename": "notes.md", "url": "data:text/plain;base64,IyBQbGFuCg=="},
		{"type": "file", "mime": "image/png", "filename": "photo.png", "url": "data:image/png;base64,AA=="},
	} {
		part["id"], part["sessionID"], part["messageID"] = fixtureID("prt", 900+index), "s1", receipt.MessageID
		f.oc.emit("message.part.updated", map[string]any{"sessionID": "s1", "part": part})
	}
	// The parts arrive one event at a time, so wait for all three of
	// OpenCode's parts rather than the first one replacing the host's copy.
	page = waitArchived(t, archive, "s1", "OpenCode's copy of the message", func(page ArchiveChatPage) bool {
		if len(page.Messages) != 1 || len(page.Messages[0].Parts) != 3 {
			return false
		}
		for index, part := range page.Messages[0].Parts {
			if part.ID != fixtureID("prt", 900+index) {
				return false
			}
		}
		return true
	})
	parts := page.Messages[0].Parts
	if parts[1].Attachment.SHA256 != digest(notes) || parts[1].Attachment.MIME != "text/plain" || parts[2].Attachment.SHA256 != digest(photo) || parts[2].Attachment.Size != int64(len(photo)) {
		t.Fatalf("attachments after OpenCode's copy %+v %+v", parts[1].Attachment, parts[2].Attachment)
	}
	if refs := archiveCount(t, archive, `SELECT sum(refcount) FROM blobs`); refs != 2 {
		t.Fatalf("blob references %d", refs)
	}
}

func TestChatCaptureKeepsChatTextWhenDiskIsLowButNotAttachmentBytes(t *testing.T) {
	var free atomic.Uint64
	free.Store(1 << 30)
	f, archive, _ := newArchiveChatFixture(t, ArchiveOptions{FreeSpace: func(string) (uint64, error) { return free.Load(), nil }}, nil)
	upload := f.uploadID(t, f.token, "s1", "notes.txt", "text/plain", []byte("low disk"))
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "Still kept", "attachments": []string{upload}}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	page := archivedPage(t, archive, "s1")
	if len(page.Messages) != 1 || page.Messages[0].Parts[0].Text != "Still kept" || page.Messages[0].Parts[1].Attachment == nil || page.Messages[0].Parts[1].Attachment.SHA256 != "" {
		t.Fatalf("below 2 GiB: %+v", page.Messages)
	}
	// Below 256 MiB chat text pauses too; delivery goes ahead.
	free.Store(archiveChatMinimumFree - 1)
	archive.maintain()
	if w := f.call(t, "POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "Not archived"}); w.Code != 202 {
		t.Fatalf("send below 256 MiB: %d %s", w.Code, w.Body)
	}
	if len(f.oc.promptBodies()) != 2 {
		t.Fatal("the prompt was not delivered")
	}
	if page := archivedPage(t, archive, "s1"); len(page.Messages) != 1 {
		t.Fatalf("below 256 MiB: %+v", page.Messages)
	}
}

func TestChatCaptureRecordsInteractionsWithoutAnswers(t *testing.T) {
	f, archive, server := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	f.oc.emit("session.status", map[string]any{"sessionID": "s1", "status": map[string]any{"type": "busy"}})
	f.oc.emit("permission.asked", map[string]any{"id": "per_1", "sessionID": "s1", "permission": "bash", "patterns": []string{"git push"}, "metadata": map[string]string{"description": "Push", "command": "git push https://SECRET-TOKEN@example.com"}})
	f.oc.emit("question.asked", map[string]any{"id": "que_1", "sessionID": "s1", "questions": []any{map[string]any{"question": "Which token should I use?", "header": "Token", "options": []any{map[string]string{"label": "A"}}}}})
	f.oc.emit("permission.replied", map[string]any{"sessionID": "s1", "requestID": "per_1", "reply": "once"})
	f.oc.emit("question.replied", map[string]any{"sessionID": "s1", "requestID": "que_1", "answers": [][]string{{"hunter2"}}})
	resolved := 0
	for resolved < 2 {
		if event := stream.next(t, 5*time.Second); event.Type == "interaction.resolved" {
			resolved++
		}
	}
	type row struct{ id, kind, outcome, summary, resolved string }
	var rows []row
	waitFor(t, "both interactions in the archive", func() bool {
		rows = nil
		result, err := archive.readDB.Query(`SELECT id, kind, outcome, summary, COALESCE(resolved_at, '') FROM interactions WHERE chat_id = 's1' ORDER BY id`)
		if err != nil {
			return false
		}
		defer result.Close()
		for result.Next() {
			var item row
			result.Scan(&item.id, &item.kind, &item.outcome, &item.summary, &item.resolved)
			rows = append(rows, item)
		}
		return len(rows) == 2 && rows[0].outcome != "" && rows[1].outcome != ""
	})
	if rows[0] != (row{"per_1", "permission", "once", "bash: git push", rows[0].resolved}) || rows[1] != (row{"que_1", "question", "answered", "Which token should I use?", rows[1].resolved}) || rows[0].resolved == "" {
		t.Fatalf("interactions %+v", rows)
	}
	for _, format := range []string{"json", "markdown", "jsonl"} {
		export := f.call(t, "GET", "/v1/archive/export?chatId=s1&format="+format, nil)
		if export.Code != 200 || strings.Contains(export.Body.String(), "hunter2") || strings.Contains(export.Body.String(), "SECRET-TOKEN") {
			t.Fatalf("%s export leaks an answer or input: %d %s", format, export.Code, export.Body)
		}
	}
}

func TestChatCaptureAndBackfillLeaveADeletedChatDeleted(t *testing.T) {
	f, archive, server := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	waitArchived(t, archive, "s1", "the chat", func(page ArchiveChatPage) bool { return len(page.Messages) == 2 })
	if w := f.call(t, "POST", "/v1/archive/delete", map[string]string{"kind": "chat", "id": "s1"}); w.Code != 200 {
		t.Fatalf("delete: %d %s", w.Code, w.Body)
	}
	// The chat goes on in OpenCode and through AgentLand.
	emitTurn(f, 3, 4, "After ", "the delete")
	stream.until(t, "turn.finished", 5*time.Second)
	if w := f.call(t, "POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "Another"}); w.Code != 202 {
		t.Fatalf("send: %d %s", w.Code, w.Body)
	}
	f.oc.addMessages("s1", ocUserFixture(3, "Second"), ocAssistantFixture(4, 3, "After the delete"))
	f.oc.set(func(oc *fakeOpenCode) { oc.updated["s1"] = fixtureEpochMs + 9000 })
	reads := len(f.oc.pageReads)
	if err := f.host.backfill.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond) // several capture intervals
	flushArchive(t, archive)
	if count := archiveCount(t, archive, `SELECT count(*) FROM chats WHERE id = 's1'`) + archiveCount(t, archive, `SELECT count(*) FROM messages WHERE chat_id = 's1'`); count != 0 {
		t.Fatalf("the deleted chat came back: %d rows", count)
	}
	f.oc.set(func(oc *fakeOpenCode) {
		for _, read := range oc.pageReads[reads:] {
			if strings.HasPrefix(read, "s1 ") {
				t.Errorf("the backfill read a deleted chat: %v", oc.pageReads[reads:])
			}
		}
	})
	changes, _ := archive.Changes(context.Background(), "", 100, []string{"p1"})
	if got := strings.Join(changeNames(t, changes), " "); got != "chat:s1:delete" {
		t.Fatalf("change feed %s", got)
	}
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures %d: %s", archive.failures.Load(), archive.lastErr)
	}
}

func TestChatCaptureHidesRewoundMessagesAndShowsThemOnRestore(t *testing.T) {
	f, archive, server := newArchiveChatFixture(t, ArchiveOptions{}, nil)
	f.oc.addMessages("s1", ocUserFixture(1, "First"), ocAssistantFixture(2, 1, "One"), ocUserFixture(3, "Second"), ocAssistantFixture(4, 3, "Two"))
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	waitArchived(t, archive, "s1", "the chat", func(page ArchiveChatPage) bool { return len(page.Messages) == 4 })
	hidden := func(page ArchiveChatPage) string {
		names := []string{}
		for _, message := range page.Messages {
			if message.Hidden {
				names = append(names, message.ID)
			}
		}
		return strings.Join(names, " ")
	}
	rewound := fixtureID("msg", 3)
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s1"] = rewound })
	f.oc.emit("session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Fixture", "directory": f.oc.directory, "revert": map[string]string{"messageID": rewound}}})
	waitArchived(t, archive, "s1", "the rewound messages to be hidden", func(page ArchiveChatPage) bool {
		return hidden(page) == rewound+" "+fixtureID("msg", 4)
	})
	// Rewound messages are not searched.
	if results, _ := archive.Search(context.Background(), ArchiveSearch{Text: "Two", Limit: 10}, []string{"p1"}); len(results.Results) != 0 {
		t.Fatalf("a hidden message was found: %+v", results.Results)
	}
	f.oc.set(func(oc *fakeOpenCode) { oc.reverts["s1"] = "" })
	f.oc.emit("session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": "Fixture", "directory": f.oc.directory}})
	waitArchived(t, archive, "s1", "a restore to show them again", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 4 && hidden(page) == ""
	})
}

func TestChatCaptureRecordsAStreamedCodexChat(t *testing.T) {
	f, archive := newArchiveCodexFixture(t, newCodexFake(t))
	id := f.newChat()
	// No device streams the chat: the send follows it.
	receipt := f.send(id, "Say hello", nil)
	f.idle(id)
	page := waitArchived(t, archive, id, "the Codex reply", func(page ArchiveChatPage) bool {
		return len(page.Messages) == 2 && page.Messages[1].Status == "complete" && len(page.Messages[1].Parts) == 2
	})
	user, reply := page.Messages[0], page.Messages[1]
	if page.Chat.Provider != "codex" || user.ID != receipt.MessageID || user.Parts[0].Text != "Say hello" ||
		reply.Parts[0].Kind != "reasoning" || reply.Parts[0].Text != "Thinking it over." || reply.Parts[1].Text != "Hello from the fake Codex." ||
		reply.Model != "codex/default" || reply.Usage == nil || reply.Usage.Input != 100 || reply.TurnID != receipt.MessageID {
		t.Fatalf("archived Codex chat %+v", page)
	}
	sameArchived(t, page.Messages, hubMessages(f.host, sessionKey{"p1", id}))
	if archive.failures.Load() != 0 {
		t.Fatalf("write failures %d: %s", archive.failures.Load(), archive.lastErr)
	}
}

// A fork is archived with a link to the chat it was copied from.
func TestArchiveRecordsForksWithTheirSource(t *testing.T) {
	fake := newCodexFake(t)
	f, archive := newArchiveCodexFixture(t, fake)
	id := f.newChat()
	first := f.send(id, "First", nil)
	f.idle(id)
	w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": id, "messageId": first.MessageID, "title": "Branch"})
	if w.Code != 201 {
		t.Fatalf("fork: %d %s", w.Code, w.Body)
	}
	var forked Session
	json.Unmarshal(w.Body.Bytes(), &forked)
	archiveEventually(t, "the fork to be archived with its source", func() bool {
		page, err := archive.ChatPage(context.Background(), forked.ID, "", 50)
		return err == nil && page.Chat.ParentID == id && page.Chat.Relation == "fork" && page.Chat.Provider == "codex"
	})
}
