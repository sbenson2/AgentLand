package host

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func openVaultRoot(t *testing.T) (*os.Root, string) {
	t.Helper()
	directory := t.TempDir()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { root.Close() })
	return root, directory
}

func readVaultFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func vaultTempFiles(t *testing.T, directory string) []string {
	t.Helper()
	var found []string
	filepath.WalkDir(directory, func(path string, entry os.DirEntry, err error) error {
		if err == nil && strings.HasPrefix(entry.Name(), ".agentland-tmp-") {
			found = append(found, path)
		}
		return nil
	})
	return found
}

func vaultTestNote(id, title string) string {
	return "---\nagentland-id: \"" + id + "\"\ntype: \"chat\"\n---\n# " + title + "\n\nSome text.\n"
}

func TestVaultNoteNamesAreSafeAndStable(t *testing.T) {
	for _, test := range []struct{ title, want string }{
		{`Fix: the "archive" / export?`, "Fix the archive export"},
		{"..hidden title.", "hidden title"},
		{"#tag [[link]] ^block | pipe <a> *b* C:\\d", "tag link block pipe a b C d"},
		{"line\nbreak\ttab\x00end", "line break tab end"},
		{"  ... ", ""},
		{"bad \xff utf-8", "bad utf-8"},
		{strings.Repeat("word ", 30), strings.TrimSpace(strings.Repeat("word ", 12))},
	} {
		if got := vaultSafeName(test.title); got != test.want {
			t.Errorf("vaultSafeName(%q) = %q, want %q", test.title, got, test.want)
		}
	}
	long := vaultSafeName(strings.Repeat("é", 100))
	if utf8.RuneCountInString(long) != vaultNameLimit {
		t.Fatalf("long name has %d characters", utf8.RuneCountInString(long))
	}
	if emoji := vaultSafeName(strings.Repeat("🎪", 100)); len(emoji) > vaultNameBytes || !utf8.ValidString(emoji) || emoji == "" {
		t.Fatalf("emoji name is %d bytes: %q", len(emoji), emoji)
	}

	short := vaultShortID("ses_8f2k3f9a2c", 6)
	if len(short) != 6 || strings.Trim(short, "0123456789abcdefghijklmnopqrstuv") != "" {
		t.Fatalf("short id %q", short)
	}
	if again := vaultShortID("ses_8f2k3f9a2c", 6); again != short {
		t.Fatalf("short id changed: %q then %q", short, again)
	}
	if longer := vaultShortID("ses_8f2k3f9a2c", 8); !strings.HasPrefix(longer, short) || len(longer) != 8 {
		t.Fatalf("a longer short id %q does not extend %q", longer, short)
	}
	if other := vaultShortID("ses_8f2k3f9a2d", 6); other == short {
		t.Fatalf("two ids share %q", short)
	}

	pacific, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	// 01:30 UTC on the 13th is still the 12th in California.
	started := time.Date(2026, 10, 13, 1, 30, 0, 0, time.UTC).In(pacific)
	base := vaultNoteBase(started, "Plan: the vault writer", "ses_8f2k3f9a2c", 6)
	if base != "2026-10-12 Plan the vault writer ("+short+")" {
		t.Fatalf("note base %q", base)
	}
	if untitled := vaultNoteBase(started, " ?? ", "ses_8f2k3f9a2c", 6); untitled != "2026-10-12 Untitled ("+short+")" {
		t.Fatalf("untitled base %q", untitled)
	}
	if vaultPartBase(base, 1) != base || vaultPartBase(base, 2) != base+" part 2" {
		t.Fatalf("part names %q %q", vaultPartBase(base, 1), vaultPartBase(base, 2))
	}
}

func TestVaultUserTailSurvivesAndMarkerIsEscaped(t *testing.T) {
	root, directory := openVaultRoot(t)
	path := filepath.Join(directory, "Chats", "AgentLand", "One.md")
	// The chat quotes the marker; the copy must not end AgentLand's part.
	generated := vaultTestNote("chat/c1", "One") + "\nThe marker is\n%% agentland:end %%\nin the docs.\n"
	note := vaultNote{Path: "Chats/AgentLand/One.md", ID: "chat/c1", Generated: generated}
	outcome, digest, err := writeNote(root, note)
	if err != nil || outcome != vaultWritten || digest == "" {
		t.Fatalf("first write %v %q %v", outcome, digest, err)
	}
	content := readVaultFile(t, path)
	if strings.Count(content, "\n"+vaultEndMarker+"\n") != 1 || !strings.HasSuffix(content, "\n\n"+vaultEndMarker+"\n") {
		t.Fatalf("one marker line, at the end:\n%s", content)
	}
	head, tail, found := splitUserTail(content)
	if !found || tail != "" || head != vaultNoteHead(generated) || !strings.Contains(head, "in the docs.") {
		t.Fatalf("split %v %q %q", found, head, tail)
	}
	if vaultDigest(head) != digest {
		t.Fatal("the digest is not the written head's")
	}

	// The user's text below the marker survives a rewrite.
	mine := "\nMy own notes, [[Links]] and all.\n"
	if err := os.WriteFile(path, []byte(content+mine), 0o600); err != nil {
		t.Fatal(err)
	}
	note.Generated, note.Recorded, note.Digest = vaultTestNote("chat/c1", "One, renamed"), true, digest
	outcome, digest, err = writeNote(root, note)
	if err != nil || outcome != vaultWritten {
		t.Fatalf("rewrite %v %v", outcome, err)
	}
	content = readVaultFile(t, path)
	if want := vaultNoteHead(note.Generated) + vaultEndMarker + "\n" + mine; content != want {
		t.Fatalf("after rewrite\n%s\nwant\n%s", content, want)
	}

	// The same text again is not written at all.
	before, _ := os.Stat(path)
	time.Sleep(20 * time.Millisecond)
	note.Digest = digest
	if outcome, again, err := writeNote(root, note); err != nil || outcome != vaultUnchanged || again != digest {
		t.Fatalf("unchanged write %v %v", outcome, err)
	}
	if after, _ := os.Stat(path); !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("an unchanged note was rewritten")
	}

	// The marker line is found with trailing spaces or CRLF; a quoted or
	// indented copy is not the marker.
	for _, test := range []struct {
		content, head, tail string
		found               bool
	}{
		{"a\n%% agentland:end %%  \r\nb\n", "a\n", "b\n", true},
		{"a\n%% agentland:end %%", "a\n", "", true},
		{"a\n> %% agentland:end %%\n  %% agentland:end %%\nb\n", "a\n> %% agentland:end %%\n  %% agentland:end %%\nb\n", "", false},
	} {
		head, tail, found := splitUserTail(test.content)
		if head != test.head || tail != test.tail || found != test.found {
			t.Errorf("split %q = %q %q %v", test.content, head, tail, found)
		}
	}
}

func TestVaultEditedNoteWithoutMarkerIsLeftAlone(t *testing.T) {
	root, directory := openVaultRoot(t)
	path := filepath.Join(directory, "One.md")
	note := vaultNote{Path: "One.md", ID: "chat/c1", Generated: vaultTestNote("chat/c1", "One")}
	_, digest, err := writeNote(root, note)
	if err != nil {
		t.Fatal(err)
	}
	note.Recorded, note.Digest = true, digest
	note.Generated = vaultTestNote("chat/c1", "One, later")

	// The user rewrote the note and took the marker out: it is theirs now.
	edited := "---\nagentland-id: \"chat/c1\"\n---\n# My summary\n\nShorter.\n"
	if err := os.WriteFile(path, []byte(edited), 0o600); err != nil {
		t.Fatal(err)
	}
	if outcome, _, err := writeNote(root, note); err != nil || outcome != vaultUserEdited {
		t.Fatalf("edited note: %v %v", outcome, err)
	}
	if readVaultFile(t, path) != edited {
		t.Fatal("an edited note was overwritten")
	}

	// Only the marker (and the empty tail) went: nothing of theirs to keep.
	if err := os.WriteFile(path, []byte(vaultNoteHead(vaultTestNote("chat/c1", "One"))), 0o600); err != nil {
		t.Fatal(err)
	}
	if outcome, _, err := writeNote(root, note); err != nil || outcome != vaultWritten {
		t.Fatalf("note without its marker but unedited: %v %v", outcome, err)
	}
	if !strings.HasSuffix(readVaultFile(t, path), vaultEndMarker+"\n") {
		t.Fatal("the marker was not put back")
	}

	// A file AgentLand never wrote is never replaced.
	theirs := filepath.Join(directory, "Theirs.md")
	if err := os.WriteFile(theirs, []byte("# Mine\n\n"+vaultEndMarker+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := writeNote(root, vaultNote{Path: "Theirs.md", ID: "chat/c2", Generated: vaultTestNote("chat/c2", "Two")}); !errors.Is(err, errVaultNotOurs) {
		t.Fatalf("another file at the path: %v", err)
	}
	if readVaultFile(t, theirs) != "# Mine\n\n"+vaultEndMarker+"\n" {
		t.Fatal("a file AgentLand never wrote was replaced")
	}
}

func TestVaultAtomicWriteLeavesNoPartialFile(t *testing.T) {
	root, directory := openVaultRoot(t)
	path := filepath.Join(directory, "Chats", "General", "One.md")
	note := vaultNote{Path: "Chats/General/One.md", ID: "chat/c1", Generated: vaultTestNote("chat/c1", "One")}
	_, digest, err := writeNote(root, note)
	if err != nil {
		t.Fatal(err)
	}
	first := readVaultFile(t, path)
	for _, folder := range []string{"Chats", "Chats/General"} {
		if info, err := os.Stat(filepath.Join(directory, folder)); err != nil || info.Mode().Perm() != 0o700 {
			t.Fatalf("folder %s: %v %v", folder, info.Mode(), err)
		}
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Fatalf("note mode %v", info.Mode())
	}

	// Until the rename, readers see the old note and the new one is whole
	// in a private temporary file beside it.
	note.Recorded, note.Digest, note.Generated = true, digest, vaultTestNote("chat/c1", "One, longer")+strings.Repeat("more text\n", 1000)
	checked := false
	vaultBeforeRename = func(rel string) {
		checked = true
		if readVaultFile(t, path) != first {
			t.Error("the note changed before the rename")
		}
		temps := vaultTempFiles(t, directory)
		if len(temps) != 1 || filepath.Dir(temps[0]) != filepath.Dir(path) {
			t.Errorf("temporary files %v", temps)
			return
		}
		if info, _ := os.Stat(temps[0]); info.Mode().Perm() != 0o600 {
			t.Errorf("temporary file mode %v", info.Mode())
		}
		if readVaultFile(t, temps[0]) != vaultNoteHead(note.Generated)+vaultEndMarker+"\n" {
			t.Error("the temporary file is not the whole note")
		}
	}
	t.Cleanup(func() { vaultBeforeRename = nil })
	if outcome, _, err := writeNote(root, note); err != nil || outcome != vaultWritten || !checked {
		t.Fatalf("rewrite %v %v checked=%v", outcome, err, checked)
	}
	if temps := vaultTempFiles(t, directory); len(temps) != 0 {
		t.Fatalf("temporary files left %v", temps)
	}

	// The user saved the note while AgentLand wrote it: theirs stays.
	typed := readVaultFile(t, path) + "\nTyped in Obsidian meanwhile.\n"
	vaultBeforeRename = func(string) {
		if err := os.WriteFile(path, []byte(typed), 0o600); err != nil {
			t.Error(err)
		}
		future := time.Now().Add(time.Minute)
		os.Chtimes(path, future, future)
	}
	note.Generated = vaultTestNote("chat/c1", "One, third")
	if _, _, err := writeNote(root, note); !errors.Is(err, errVaultChanged) {
		t.Fatalf("a note that changed during the write: %v", err)
	}
	vaultBeforeRename = nil
	if readVaultFile(t, path) != typed {
		t.Fatal("the user's save was overwritten")
	}
	if temps := vaultTempFiles(t, directory); len(temps) != 0 {
		t.Fatalf("temporary files left after a changed note %v", temps)
	}

	// A folder that cannot be written fails the write and leaves the note.
	if err := os.Chmod(filepath.Dir(path), 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Dir(path), 0o700) })
	if _, _, err := writeNote(root, note); err == nil {
		t.Fatal("wrote into a read-only folder")
	}
	if readVaultFile(t, path) != typed {
		t.Fatal("a failed write changed the note")
	}
	if temps := vaultTempFiles(t, directory); len(temps) != 0 {
		t.Fatalf("temporary files left after a failure %v", temps)
	}
}

func TestVaultWriteCannotFollowSymlinkOut(t *testing.T) {
	root, directory := openVaultRoot(t)
	outside := t.TempDir()
	target := filepath.Join(outside, "target.md")
	if err := os.WriteFile(target, []byte("outside\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(directory, "Chats")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(directory, "Terminals"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(directory, "Terminals", "t.md")); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"Chats/One.md", "Chats/target.md", "Terminals/t.md", "../escape.md", filepath.Join(outside, "abs.md"), ""} {
		if _, _, err := writeNote(root, vaultNote{Path: rel, ID: "chat/c1", Generated: vaultTestNote("chat/c1", "One")}); err == nil {
			t.Errorf("wrote %q", rel)
		}
	}
	entries, _ := os.ReadDir(outside)
	if len(entries) != 1 || readVaultFile(t, target) != "outside\n" {
		t.Fatalf("outside the vault: %v", entries)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(directory), "escape.md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("wrote above the vault")
	}
	if temps := vaultTempFiles(t, outside); len(temps) != 0 {
		t.Fatalf("temporary files outside %v", temps)
	}
}

func TestVaultAdoptsFileWithItsAgentLandID(t *testing.T) {
	root, directory := openVaultRoot(t)
	mine := "\nWritten below the marker.\n"
	// A note written before its record was saved (a crash in between), and
	// one whose frontmatter Obsidian has rewritten without quotes.
	for index, frontmatter := range []string{"agentland-id: \"chat/c1\"", "agentland-id: chat/c1", "agentland-id: 'chat/c1'"} {
		name := []string{"a.md", "b.md", "c.md"}[index]
		existing := "---\n" + frontmatter + "\ntype: chat\n---\n# Old\n\n" + vaultEndMarker + "\n" + mine
		if err := os.WriteFile(filepath.Join(directory, name), []byte(existing), 0o600); err != nil {
			t.Fatal(err)
		}
		note := vaultNote{Path: name, ID: "chat/c1", Generated: vaultTestNote("chat/c1", "New")}
		outcome, _, err := writeNote(root, note)
		if err != nil || outcome != vaultWritten {
			t.Fatalf("%s: %v %v", name, outcome, err)
		}
		if got := readVaultFile(t, filepath.Join(directory, name)); got != vaultNoteHead(note.Generated)+vaultEndMarker+"\n"+mine {
			t.Fatalf("%s adopted as\n%s", name, got)
		}
	}

	// Ours by its ID but without the marker: the user's now.
	edited := "---\nagentland-id: chat/c1\n---\n# Rewritten by hand\n"
	if err := os.WriteFile(filepath.Join(directory, "d.md"), []byte(edited), 0o600); err != nil {
		t.Fatal(err)
	}
	if outcome, _, err := writeNote(root, vaultNote{Path: "d.md", ID: "chat/c1", Generated: vaultTestNote("chat/c1", "New")}); err != nil || outcome != vaultUserEdited {
		t.Fatalf("unrecorded note without its marker: %v %v", outcome, err)
	}
	if readVaultFile(t, filepath.Join(directory, "d.md")) != edited {
		t.Fatal("an unrecorded edited note was overwritten")
	}

	// Another chat's note, or an ID only in the text, is not adopted.
	for name, content := range map[string]string{
		"e.md": "---\nagentland-id: \"chat/c2\"\n---\n# Other\n\n" + vaultEndMarker + "\n",
		"f.md": "# Notes\n\nagentland-id: chat/c1\n\n" + vaultEndMarker + "\n",
	} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := writeNote(root, vaultNote{Path: name, ID: "chat/c1", Generated: vaultTestNote("chat/c1", "New")}); !errors.Is(err, errVaultNotOurs) {
			t.Fatalf("%s adopted: %v", name, err)
		}
		if readVaultFile(t, filepath.Join(directory, name)) != content {
			t.Fatalf("%s changed", name)
		}
	}
}
