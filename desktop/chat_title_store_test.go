package host

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestChatTitleStoreResolvesOpenCodeTitles(t *testing.T) {
	store := newMemoryChatTitleStore()
	auto := chatName{Title: "Fix the login redirect", Source: "auto", Basis: "msg_2"}
	device := chatName{Title: "Login redirect", Source: "device", Basis: "msg_4"}
	if err := store.setOpenCode("auto", "p1", auto, ""); err != nil {
		t.Fatal(err)
	}
	if err := store.setOpenCode("device", "p1", device, "Old OpenCode title"); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, chat, raw string
		want            chatName
	}{
		{"nothing named, placeholder", "other", "New session - 2026-09-26T10:00:00.000Z", chatName{Title: "New session - 2026-09-26T10:00:00.000Z", Source: "default"}},
		{"nothing named, a title", "other", "Generated title", chatName{Title: "Generated title", Source: "provider"}},
		{"auto over OpenCode's untitled", "auto", "New session - 2026-09-26T10:00:00.000Z", auto},
		{"auto over the app's placeholder", "auto", "New chat", auto},
		{"OpenCode's own title replaces auto", "auto", "Safari redirect loop", chatName{Title: "Safari redirect loop", Source: "provider"}},
		{"device echo", "device", "Login redirect", device},
		{"device over a placeholder", "device", "New chat", device},
		{"a late update from before the rename", "device", "Old OpenCode title", device},
		{"a rename in OpenCode afterwards", "device", "Renamed in the TUI", chatName{Title: "Renamed in the TUI", Source: "provider"}},
	}
	for _, c := range cases {
		if got := store.resolveOpenCode(c.chat, c.raw); got != c.want {
			t.Errorf("%s: %+v, want %+v", c.name, got, c.want)
		}
	}
	// A rename in flight: OpenCode's echo counts as the device name until
	// it is kept or given up.
	pending := chatName{Title: "In flight", Source: "device", Basis: "msg_9"}
	store.beginRename("auto", pending)
	if got := store.resolveOpenCode("auto", "In flight"); got != pending {
		t.Fatalf("echo in flight: %+v", got)
	}
	if got := store.resolveOpenCode("auto", "New chat"); got != auto {
		t.Fatalf("the old name in flight: %+v", got)
	}
	store.endRename("auto")
	if got := store.resolveOpenCode("auto", "In flight"); got.Source != "provider" {
		t.Fatalf("after giving up: %+v", got)
	}
	// Claude Code and Codex names live in memory only.
	store.setMemory("claude:x", "p1", auto)
	if got, ok := store.memoryName("claude:x"); !ok || got != auto {
		t.Fatalf("memory name %+v %v", got, ok)
	}
	var nothing *ChatTitleStore
	if got := nothing.resolveOpenCode("x", "Title"); got.Source != "provider" {
		t.Fatalf("no store: %+v", got)
	}
}

// OpenCode's echo of a device name can come before OpenCode answers the
// rename: the hub counts it as the device's, never as OpenCode's title.
func TestAnEarlyEchoOfADeviceNameIsTheDevices(t *testing.T) {
	f := newChatFixture(t)
	chat := hubChatFor(t, f, "s1")
	start := ringSeq(f, chat)
	name := chatName{Title: "Fix the login redirect", Source: "device", Basis: "msg_3"}
	f.host.titles.beginRename("s1", name)
	feed(t, f, "session.updated", map[string]any{"sessionID": "s1", "info": map[string]any{"id": "s1", "title": name.Title, "directory": f.oc.directory}})
	sameEvents(t, "the early echo", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Fix the login redirect","titleSource":"device","titleBasis":"msg_3"}`)
	if err := f.host.titles.setOpenCode("s1", "p1", name, "Fixture"); err != nil {
		t.Fatal(err)
	}
	f.host.titles.endRename("s1")
	if !f.host.chat.rename(sessionKey{"p1", "s1"}, name) {
		t.Fatal("the hub does not hold the chat")
	}
	sameEvents(t, "after the rename is kept", titleEvents(f, chat, start), `{"type":"chat.updated","title":"Fix the login redirect","titleSource":"device","titleBasis":"msg_3"}`)
}

func TestChatTitleStoreFileAndLimits(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "host.json.titles.json")
	store, err := NewChatTitleStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if store.limit != 2048 {
		t.Fatalf("limit %d", store.limit)
	}
	clock := &testClock{now: time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)}
	store.now, store.limit = clock.Now, 8
	for index := range 10 {
		clock.Advance(time.Second)
		if err := store.setOpenCode(fmt.Sprintf("ses_%05d", index), "p1", chatName{Title: "Auto", Source: "auto", Basis: "m"}, ""); err != nil {
			t.Fatal(err)
		}
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("file %v %v", info, err)
	}
	reopened, err := NewChatTitleStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(reopened.saved) != 8 {
		t.Fatalf("%d names kept", len(reopened.saved))
	}
	for _, forgotten := range []string{"ses_00000", "ses_00001"} {
		if got := reopened.resolveOpenCode(forgotten, "New chat"); got.Source != "default" {
			t.Fatalf("the oldest name was kept: %+v", got)
		}
	}
	if got := reopened.resolveOpenCode("ses_00002", "New chat"); got.Source != "auto" {
		t.Fatalf("a newer name was forgotten: %+v", got)
	}
	// A file from a newer host is refused, not overwritten.
	if err := writePrivateState(path, []byte(`{"version":2,"chats":{}}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := NewChatTitleStore(path); err == nil {
		t.Fatal("a newer file was read")
	}
	// Unknown sources in the file are dropped.
	if err := writePrivateState(path, []byte(`{"version":1,"chats":{"a":{"projectId":"p1","title":"T","titleSource":"provider"},"b":{"projectId":"p1","title":"T","titleSource":"device","titleBasis":"m"}}}`)); err != nil {
		t.Fatal(err)
	}
	if loaded, err := NewChatTitleStore(path); err != nil || len(loaded.saved) != 1 || loaded.saved["b"] == nil {
		t.Fatalf("loaded %+v %v", loaded, err)
	}
}
