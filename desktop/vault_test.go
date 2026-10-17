package host

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// vaultFixture is an archive and a vault folder, with a clock the tests move
// and a log of the files the writer writes.
type vaultFixture struct {
	t       *testing.T
	archive *Archive
	folder  string
	busy    atomic.Bool

	mu     sync.Mutex
	clock  time.Time
	writes map[string]int
	order  []string
}

// newVaultFixture's archive keeps the fixture's time too, so a terminal ends
// when the test says.
func newVaultFixture(t *testing.T) *vaultFixture {
	f := &vaultFixture{t: t, folder: filepath.Join(t.TempDir(), "AgentLand Vault"), clock: archiveTestStart.Add(time.Hour), writes: map[string]int{}}
	f.archive = testArchive(t, ArchiveOptions{Now: f.now})
	return f
}

func (f *vaultFixture) now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.clock
}

func (f *vaultFixture) advance(by time.Duration) {
	f.mu.Lock()
	f.clock = f.clock.Add(by)
	f.mu.Unlock()
}

func (f *vaultFixture) wrote(path string) {
	f.mu.Lock()
	f.writes[path]++
	f.order = append(f.order, path)
	f.mu.Unlock()
}

// noteWrites lists the chat and terminal notes written, in order (f.order
// has every file, hubs and Daily notes too).
func (f *vaultFixture) noteWrites() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	notes := []string{}
	for _, path := range f.order {
		if strings.HasPrefix(path, "Chats/") || strings.HasPrefix(path, "Terminals/") {
			notes = append(notes, path)
		}
	}
	return notes
}

// written returns how many chat and terminal notes were written and the
// newest.
func (f *vaultFixture) written() (int, string) {
	notes := f.noteWrites()
	if len(notes) == 0 {
		return 0, ""
	}
	return len(notes), notes[len(notes)-1]
}

// files returns how many files of any kind were written.
func (f *vaultFixture) files() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.order)
}

func (f *vaultFixture) forget() {
	f.mu.Lock()
	f.writes, f.order = map[string]int{}, nil
	f.mu.Unlock()
}

// writer is a vault writer for the fixture's folder, clock and workspaces.
func (f *vaultFixture) writer() *vaultWriter {
	w := newVaultWriter(f.archive, "v1", f.folder)
	w.now = f.now
	w.busy = f.busy.Load
	w.workspaces = func() map[string]string { return map[string]string{"p1": "AgentLand"} }
	w.location = vaultTestZone
	w.afterWrite = f.wrote
	f.t.Cleanup(w.stop)
	return w
}

// pass commits what the archive has queued, then runs one pass.
func (f *vaultFixture) pass(w *vaultWriter) time.Time {
	f.t.Helper()
	flushArchive(f.t, f.archive)
	next, err := w.pass(context.Background())
	if err != nil {
		f.t.Fatal(err)
	}
	return next
}

// notesIn lists the vault's Markdown files under a folder, such as "Chats/".
func (f *vaultFixture) notesIn(folder string) []string {
	notes := []string{}
	for _, note := range f.notes() {
		if strings.HasPrefix(note, folder) {
			notes = append(notes, note)
		}
	}
	return notes
}

// notes lists the vault's Markdown files.
func (f *vaultFixture) notes() []string {
	f.t.Helper()
	notes := []string{}
	err := filepath.WalkDir(f.folder, func(path string, entry fs.DirEntry, err error) error {
		if err == nil && strings.HasSuffix(path, ".md") {
			relative, _ := filepath.Rel(f.folder, path)
			notes = append(notes, filepath.ToSlash(relative))
		}
		return err
	})
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		f.t.Fatal(err)
	}
	slices.Sort(notes)
	return notes
}

func (f *vaultFixture) read(path string) string {
	f.t.Helper()
	return readVaultFile(f.t, filepath.Join(f.folder, filepath.FromSlash(path)))
}

func (f *vaultFixture) modified(path string) time.Time {
	f.t.Helper()
	info, err := os.Stat(filepath.Join(f.folder, filepath.FromSlash(path)))
	if err != nil {
		f.t.Fatal(err)
	}
	return info.ModTime()
}

// vaultChatPath is where the fixture's chats (started archiveTestStart, in
// p1) are written.
func vaultChatPath(id, title string) string {
	return "Chats/AgentLand/" + vaultNoteBase(archiveTestStart.In(vaultTestZone), title, id, vaultShortIDLength) + ".md"
}

func vaultWaitFor(t *testing.T, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestVaultBackfillWritesEachChatOnce(t *testing.T) {
	f := newVaultFixture(t)
	paths := map[string]string{}
	for index := range 30 {
		id, title := fmt.Sprintf("c%02d", index), fmt.Sprintf("Chat %02d", index)
		mustArchiveChat(t, f.archive, id, "p1", title)
		mustArchiveMessage(t, f.archive, textMessage(id, id+"-m1", "user", 1, "hello "+title))
		paths[id] = vaultChatPath(id, title)
	}
	// A chat still named by a placeholder, with no reply yet, has no note.
	mustArchiveChat(t, f.archive, "pending", "p1", "New chat")
	mustArchiveMessage(t, f.archive, textMessage("pending", "pending-m1", "user", 1, "hi"))
	w := f.writer()
	if status := w.status(); status.State != "off" {
		t.Fatalf("status before start %+v", status)
	}
	f.pass(w)
	if status := w.status(); status.Backfill.Total != 31 || status.Backfill.Done != 1 || status.State != "writing" || status.Pending != 30 {
		t.Fatalf("status after the first pass %+v", status)
	}
	if _, err := os.Stat(f.folder); err != nil {
		t.Fatalf("the folder was not created: %v", err)
	}

	// At most 25 notes a second.
	start := f.now()
	for f.now().Sub(start) < time.Second {
		f.advance(10 * time.Millisecond)
		f.pass(w)
	}
	if count, _ := f.written(); count < 24 || count > 26 {
		t.Fatalf("%d notes in the first second", count)
	}

	// A live change goes before the backfill.
	before, _ := f.written()
	mustArchiveChat(t, f.archive, "live", "p1", "Live chat")
	f.pass(w)
	if writes := f.noteWrites(); len(writes) == before || writes[before] != vaultChatPath("live", "Live chat") {
		t.Fatalf("writes after the live change %v", writes[before:])
	}

	// While a chat streams the backfill waits; live notes do not.
	f.busy.Store(true)
	before, _ = f.written()
	for range 10 {
		f.advance(100 * time.Millisecond)
		if next := f.pass(w); !next.Equal(f.now().Add(w.pausePoll)) {
			t.Fatalf("next pass at %v while busy", next)
		}
	}
	if count, _ := f.written(); count != before {
		t.Fatalf("%d notes written while a chat streamed", count-before)
	}
	mustArchiveChat(t, f.archive, "live2", "p1", "Second live chat")
	f.pass(w)
	if count, newest := f.written(); count != before+1 || newest != vaultChatPath("live2", "Second live chat") {
		t.Fatalf("%d writes while busy, newest %s", count-before, newest)
	}
	f.busy.Store(false)

	for range 200 {
		if w.status().Backfill.Done == 31 {
			break
		}
		f.advance(40 * time.Millisecond)
		f.pass(w)
	}
	paths["live"], paths["live2"] = vaultChatPath("live", "Live chat"), vaultChatPath("live2", "Second live chat")
	for id, path := range paths {
		if f.writes[path] != 1 {
			t.Errorf("%s written %d times", id, f.writes[path])
		}
	}
	if count, _ := f.written(); count != len(paths) || len(f.notesIn("Chats/")) != len(paths) {
		t.Fatalf("%d notes written, %d in the folder: %v", count, len(f.notesIn("Chats/")), f.notes())
	}
	status := w.status()
	if status.State != "current" || status.Pending != 0 || status.Backfill.Done != 31 || status.Backfill.Total != 31 || status.Notes != 32 {
		t.Fatalf("status at the end %+v", status)
	}
	// The hubs, written at most every 30 s, catch up; then nothing waits.
	f.advance(vaultHubEvery)
	if next := f.pass(w); !next.IsZero() {
		t.Fatalf("next pass at %v with nothing to do", next)
	}
	state, err := f.archive.vaultState(t.Context(), "v1")
	if high, _ := f.archive.vaultChangeRows(t.Context(), 0, 1); err != nil || state.Cursor != high.High || state.BackfillDone != 31 || state.BackfillTotal != 31 || state.Root != f.folder {
		t.Fatalf("saved state %+v (feed at %d) %v", state, high.High, err)
	}
}

func TestVaultRestartResumesWithoutRewriting(t *testing.T) {
	f := newVaultFixture(t)
	for _, id := range []string{"c1", "c2", "c3"} {
		mustArchiveChat(t, f.archive, id, "p1", "Chat "+id)
		mustArchiveMessage(t, f.archive, textMessage(id, id+"-m1", "user", 1, "hello"))
	}
	// An image is copied once, beside the notes.
	sum, err := f.archive.StoreBlob(strings.NewReader("PNG bytes"), "image/png")
	if err != nil {
		t.Fatal(err)
	}
	image := textMessage("c3", "c3-m2", "user", 2, "")
	image.Parts = []ArchivePart{{ID: "c3-m2-image", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "shot.png", MIME: "image/png", Size: 9, SHA256: sum}}}
	mustArchiveMessage(t, f.archive, image)
	attachment := "Attachments/2026-09/" + sum[:12] + "-shot.png"

	first := f.writer()
	for range 10 {
		f.advance(40 * time.Millisecond)
		f.pass(first)
	}
	f.advance(vaultHubEvery) // the hubs list all three
	f.pass(first)
	if status := first.status(); status.State != "current" || status.Notes != 3 {
		t.Fatalf("first run %+v", status)
	}
	if data, err := os.ReadFile(filepath.Join(f.folder, attachment)); err != nil || string(data) != "PNG bytes" {
		t.Fatalf("attachment %q %v", data, err)
	}
	if !strings.Contains(f.read(vaultChatPath("c3", "Chat c3")), "![["+attachment+"]]") {
		t.Fatal("the note does not embed its image")
	}
	first.stop()

	long := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	notes := f.notes()
	for _, note := range append(slices.Clone(notes), attachment) {
		if err := os.Chtimes(filepath.Join(f.folder, note), long, long); err != nil {
			t.Fatal(err)
		}
	}
	f.forget()
	second := f.writer()
	f.pass(second)
	if count := f.files(); count != 0 {
		t.Fatalf("%d files rewritten after a restart: %v", count, f.writes)
	}
	if status := second.status(); status.State != "current" || status.Notes != 3 || status.Pending != 0 {
		t.Fatalf("after a restart %+v", status)
	}

	// A new message rewrites its chat's note and only that.
	mustArchiveMessage(t, f.archive, textMessage("c2", "c2-m2", "assistant", 2, "a reply"))
	f.pass(second)
	if count, newest := f.written(); count != 1 || newest != vaultChatPath("c2", "Chat c2") {
		t.Fatalf("%d writes, newest %s", count, newest)
	}
	for _, note := range append(notes, attachment) {
		if modified := f.modified(note); note != vaultChatPath("c2", "Chat c2") && !modified.Equal(long) {
			t.Errorf("%s modified at %v", note, modified)
		}
	}
	if !slices.Equal(f.notes(), notes) {
		t.Fatalf("notes %v, were %v", f.notes(), notes)
	}
}

func TestVaultStreamingChatAtMostEveryFiveSeconds(t *testing.T) {
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "Streaming")
	mustArchiveMessage(t, f.archive, textMessage("c1", "m1", "user", 1, "tell me a story"))
	w := f.writer()
	f.pass(w)
	path := vaultChatPath("c1", "Streaming")
	writes := []time.Time{f.now()}
	if f.writes[path] != 1 {
		t.Fatalf("first write %v", f.writes)
	}

	// The reply streams for twelve seconds, a snapshot every half second.
	var reply ArchiveMessage
	for step := 1; step <= 24; step++ {
		f.advance(500 * time.Millisecond)
		reply = textMessage("c1", "m2", "assistant", 2, strings.TrimSpace(strings.Repeat(fmt.Sprintf("word%d ", step), step)))
		if step < 24 {
			reply.Status = "streaming"
		}
		mustArchiveMessage(t, f.archive, reply)
		next := f.pass(w)
		if f.writes[path] > len(writes) {
			writes = append(writes, f.now())
		} else if due := writes[len(writes)-1].Add(vaultChatEvery); !next.Equal(due) {
			t.Fatalf("step %d: next pass at %v, due %v", step, next, due)
		}
	}
	f.advance(3 * time.Second)
	f.pass(w)
	if f.writes[path] > len(writes) {
		writes = append(writes, f.now())
	}
	start := writes[0]
	if len(writes) != 4 || writes[1] != start.Add(5*time.Second) || writes[2] != start.Add(10*time.Second) || writes[3] != start.Add(15*time.Second) {
		t.Fatalf("writes at %v", writes)
	}
	if text := f.read(path); !strings.Contains(text, reply.Parts[0].Text) || strings.Contains(text, "still being written") {
		t.Fatalf("final note\n%s", text)
	}
	// The question was masked once; the reply once per write.
	if w.messageRenders != 4 {
		t.Fatalf("%d messages rendered", w.messageRenders)
	}
}

func TestVaultTitleChangeKeepsPathUpdatesAliases(t *testing.T) {
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "Plan the vault writer")
	mustArchiveMessage(t, f.archive, textMessage("c1", "m1", "user", 1, "hello"))
	w := f.writer()
	f.pass(w)
	path := vaultChatPath("c1", "Plan the vault writer")
	record, err := f.archive.vaultFile(t.Context(), "v1", vaultFileKey{Entity: "chat", EntityID: "c1", Part: 1})
	if err != nil || record.Path != path || record.FirstTitle != "Plan the vault writer" {
		t.Fatalf("record %+v %v", record, err)
	}

	// The chat and its workspace are renamed.
	mustArchiveChat(t, f.archive, "c1", "p1", "Wire the vault status")
	w.workspaces = func() map[string]string { return map[string]string{"p1": "AgentLand App"} }
	f.advance(vaultChatEvery)
	f.pass(w)
	if notes := f.notesIn("Chats/"); !slices.Equal(notes, []string{path}) {
		t.Fatalf("notes %v", notes)
	}
	text := f.read(path)
	fields := vaultFrontmatter(t, text)
	if fields["title"] != `"Wire the vault status"` || fields["aliases"] != `["Plan the vault writer","Wire the vault status"]` ||
		fields["workspace"] != `"[[Workspaces/AgentLand|AgentLand App]]"` || !strings.Contains(text, "\n# Wire the vault status\n") {
		t.Fatalf("renamed note\n%s", text)
	}
	if record, err := f.archive.vaultFile(t.Context(), "v1", vaultFileKey{Entity: "chat", EntityID: "c1", Part: 1}); err != nil || record.FirstTitle != "Plan the vault writer" {
		t.Fatalf("record after renaming %+v %v", record, err)
	}

	// A chat first written under a placeholder is Untitled, and its first
	// real title becomes its first alias.
	mustArchiveChat(t, f.archive, "c2", "p1", "New chat")
	mustArchiveMessage(t, f.archive, textMessage("c2", "c2-m1", "user", 1, "tides?"))
	f.pass(w)
	if len(f.notesIn("Chats/")) != 1 {
		t.Fatalf("a placeholder chat has a note: %v", f.notes())
	}
	mustArchiveMessage(t, f.archive, textMessage("c2", "c2-m2", "assistant", 2, "Twice a day."))
	f.pass(w)
	untitled := vaultChatPath("c2", "")
	if !slices.Contains(f.notesIn("Chats/"), untitled) {
		t.Fatalf("notes %v", f.notes())
	}
	for _, title := range []string{"Tide tables", "Tide tables for May"} {
		mustArchiveChat(t, f.archive, "c2", "p1", title)
		f.advance(vaultChatEvery)
		f.pass(w)
	}
	if fields := vaultFrontmatter(t, f.read(untitled)); fields["aliases"] != `["Tide tables","Tide tables for May"]` || len(f.notesIn("Chats/")) != 2 {
		t.Fatalf("placeholder chat renamed: %v %v", fields, f.notes())
	}
}

func TestVaultCrashBetweenWriteAndRecordAdopts(t *testing.T) {
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	mustArchiveMessage(t, f.archive, textMessage("c1", "m1", "user", 1, "hello"))
	crashed := f.writer()
	crashed.save = func(vaultStateRecord, []vaultFileRecord, []vaultFileKey) error { return errors.New("the host stopped") }
	flushArchive(t, f.archive)
	if _, err := crashed.pass(t.Context()); err == nil {
		t.Fatal("the pass did not report the failed save")
	}
	if status := crashed.status(); status.State != "paused" || !strings.Contains(status.Message, "the host stopped") {
		t.Fatalf("status %+v", status)
	}
	crashed.stop()
	path := vaultChatPath("c1", "One")
	if _, err := f.archive.vaultFile(t.Context(), "v1", vaultFileKey{Entity: "chat", EntityID: "c1", Part: 1}); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("record after the crash: %v", err)
	}
	// The user writes below the marker before AgentLand starts again.
	full := filepath.Join(f.folder, filepath.FromSlash(path))
	if err := os.WriteFile(full, []byte(f.read(path)+"My own notes.\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	f.forget()
	w := f.writer()
	f.pass(w)
	record, err := f.archive.vaultFile(t.Context(), "v1", vaultFileKey{Entity: "chat", EntityID: "c1", Part: 1})
	if err != nil || record.Path != path || record.Digest == "" {
		t.Fatalf("record %+v %v", record, err)
	}
	if count := f.files(); count != 0 || !slices.Equal(f.notesIn("Chats/"), []string{path}) || !strings.HasSuffix(f.read(path), "\nMy own notes.\n") {
		t.Fatalf("%d writes, notes %v:\n%s", count, f.notes(), f.read(path))
	}

	// The adopted note is the vault's again.
	mustArchiveMessage(t, f.archive, textMessage("c1", "m2", "assistant", 2, "hi there"))
	f.advance(vaultChatEvery)
	f.pass(w)
	if text := f.read(path); !strings.Contains(text, "hi there") || !strings.HasSuffix(text, "\nMy own notes.\n") {
		t.Fatalf("note\n%s", text)
	}
}

func TestVaultOffStopsAndKeepsFiles(t *testing.T) {
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	mustArchiveMessage(t, f.archive, textMessage("c1", "m1", "user", 1, "hello"))
	w := f.writer()
	w.now = time.Now
	w.start()
	one := vaultChatPath("c1", "One")
	vaultWaitFor(t, "the first note", func() bool { return w.status().State == "current" && w.status().Notes == 1 })
	text := f.read(one)

	w.stop()
	if status := w.status(); status.State != "off" {
		t.Fatalf("status when off %+v", status)
	}
	mustArchiveChat(t, f.archive, "c2", "p1", "Two")
	mustArchiveMessage(t, f.archive, textMessage("c2", "m1", "user", 1, "hello"))
	flushArchive(t, f.archive)
	if count, _ := f.written(); count != 1 || !slices.Equal(f.notesIn("Chats/"), []string{one}) || f.read(one) != text {
		t.Fatalf("%d writes while off, notes %v", count, f.notes())
	}

	// On again, it writes what changed meanwhile and leaves the rest.
	modified := f.modified(one)
	w.start()
	vaultWaitFor(t, "the second note", func() bool { return w.status().State == "current" && w.status().Notes == 2 })
	w.stop()
	if notes := f.notesIn("Chats/"); !slices.Equal(notes, []string{one, vaultChatPath("c2", "Two")}) || !f.modified(one).Equal(modified) {
		t.Fatalf("notes %v", notes)
	}
}

func TestVaultStopsWithinASecond(t *testing.T) {
	f := newVaultFixture(t)
	for index := range 200 {
		mustArchiveChat(t, f.archive, fmt.Sprintf("c%03d", index), "p1", fmt.Sprintf("Chat %03d", index))
	}
	w := f.writer()
	w.now, w.backfillGap = time.Now, 0
	// Each note takes 20 ms, so the backfill alone would take four seconds.
	w.afterWrite = func(path string) {
		f.wrote(path)
		time.Sleep(20 * time.Millisecond)
	}
	stopTimed := func(what string) {
		t.Helper()
		started := time.Now()
		w.stop()
		if elapsed := time.Since(started); elapsed > time.Second {
			t.Fatalf("stopping %s took %v", what, elapsed)
		}
	}
	w.start()
	vaultWaitFor(t, "the backfill to start", func() bool { count, _ := f.written(); return count >= 3 })
	stopTimed("the backfill")
	if count, _ := f.written(); count >= 200 {
		t.Fatalf("the backfill finished (%d notes) before it was stopped", count)
	}

	// Waiting for changes.
	w.afterWrite = f.wrote
	w.start()
	vaultWaitFor(t, "the backfill to finish", func() bool { return w.status().State == "current" })
	stopTimed("a waiting writer")
	w.stop() // stopping twice is fine

	// Holding a backfill back while a chat streams.
	f.busy.Store(true)
	f.forget()
	w = newVaultWriter(f.archive, "v2", filepath.Join(t.TempDir(), "Another Vault"))
	w.busy, w.afterWrite = f.busy.Load, f.wrote
	w.start()
	vaultWaitFor(t, "the backfill to wait", func() bool { return w.status().Pending == 200 })
	stopTimed("a waiting backfill")
	if count, _ := f.written(); count != 0 {
		t.Fatalf("%d notes written while a chat streamed", count)
	}
}

func TestVaultRunningTerminalRewritesCurrentPartThenFinal(t *testing.T) {
	f := newVaultFixture(t)
	w := f.writer()
	// Parts of about 300 bytes, so the note grows parts while it runs.
	w.newTerminal = func() *vaultTerminal {
		model := newVaultTerminal()
		model.partLimit = 300
		return model
	}
	log := vaultTestTerminal(t, f.archive, "p1", "Build", "shell", archiveTestStart, "$ make\r\nstep 01\r\n", "")
	f.pass(w)
	base := vaultTerminalBase("AgentLand", log.ID(), "shell", archiveTestStart)
	path := base + ".md"
	first := f.now()
	if text := f.read(path); f.writes[path] != 1 || !strings.Contains(text, "step 01") || vaultFrontmatter(t, text)["status"] != `"running"` {
		t.Fatalf("%d writes, note\n%s", f.writes[path], text)
	}
	if status := w.status(); status.State != "current" || status.Notes != 1 {
		t.Fatalf("status %+v", status)
	}
	// The user writes below the marker while it runs.
	full := filepath.Join(f.folder, filepath.FromSlash(path))
	if err := os.WriteFile(full, []byte(f.read(path)+"Mine.\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	// New output waits until 30 s after the last write; then the note is
	// rewritten, never appended to.
	log.Append([]byte("step 02\r\n"))
	f.advance(10 * time.Second)
	if next := f.pass(w); f.writes[path] != 1 || !next.Equal(first.Add(vaultTerminalEvery)) {
		t.Fatalf("%d writes after 10 s, next pass at %v", f.writes[path], next)
	}
	f.advance(20 * time.Second)
	f.pass(w)
	if text := f.read(path); f.writes[path] != 2 || !strings.Contains(text, "step 02") || !strings.HasSuffix(text, "\n"+vaultEndMarker+"\nMine.\n") {
		t.Fatalf("%d writes, note\n%s", f.writes[path], text)
	}
	// Nothing new: nothing written.
	f.advance(vaultTerminalEvery)
	f.pass(w)
	if f.writes[path] != 2 {
		t.Fatalf("%d writes without new output", f.writes[path])
	}

	// It outgrows its first part; then only the newest part is rewritten.
	for step := 3; step <= 40; step++ {
		log.Append(fmt.Appendf(nil, "step %02d\r\n", step))
	}
	f.advance(vaultTerminalEvery)
	f.pass(w)
	second := vaultPartBase(base, 2) + ".md"
	if parts := f.notesIn("Terminals/"); !slices.Equal(parts, []string{second, path}) {
		t.Fatalf("parts %v", parts)
	}
	before := maps.Clone(f.writes)
	log.Append([]byte("step 41\r\n"))
	f.advance(vaultTerminalEvery)
	f.pass(w)
	if f.writes[path] != before[path] || f.writes[second] != before[second]+1 || !strings.Contains(f.read(second), "step 41") {
		t.Fatalf("writes %v, were %v", f.writes, before)
	}

	// It ends: the whole note is rendered again from the log, once.
	code := 0
	log.Close("exited", &code)
	f.advance(time.Second)
	f.pass(w)
	ended, err := archiveLoadTerminalLog(t.Context(), f.archive.readDB, log.ID())
	if err != nil {
		t.Fatal(err)
	}
	model := newVaultTerminal()
	model.partLimit = 300
	if err := w.feedTerminal(t.Context(), model, ended); err != nil {
		t.Fatal(err)
	}
	want := model.render(ended, vaultTerminalNames{Base: base, WorkspaceName: "AgentLand", WorkspaceFolder: "AgentLand", Location: vaultTestZone})
	if len(want) != 2 {
		t.Fatalf("%d parts in the whole render", len(want))
	}
	for _, part := range want {
		if head := vaultHead(t, f.read(part.Path)); head != strings.TrimRight(part.Text, "\n")+"\n" {
			t.Fatalf("%s\n%s\nwant\n%s", part.Path, head, part.Text)
		}
	}
	fields := vaultFrontmatter(t, f.read(path))
	if fields["status"] != `"exited"` || fields["exit-code"] != "0" || fields["ended"] == "" || !strings.HasSuffix(f.read(path), "\nMine.\n") {
		t.Fatalf("final note\n%s", f.read(path))
	}
	if len(w.running) != 0 || f.writes[path] != before[path]+1 {
		t.Fatalf("%d terminals still polled, %d writes", len(w.running), f.writes[path])
	}
	f.advance(vaultTerminalEvery)
	if next := f.pass(w); f.writes[path] != before[path]+1 || !next.IsZero() && next.Before(w.listsAt) {
		t.Fatalf("written again after it ended (%d), next pass at %v", f.writes[path], next)
	}

	// With terminal notes turned off, a vault has none.
	other := newVaultWriter(f.archive, "v2", filepath.Join(t.TempDir(), "No Terminals"))
	other.terminals, other.location = false, vaultTestZone
	t.Cleanup(other.stop)
	running := vaultTestTerminal(t, f.archive, "p1", "Shell", "shell", archiveTestStart, "ls\r\n", "")
	defer running.Close("exited", nil)
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	flushArchive(t, f.archive)
	if _, err := other.pass(t.Context()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(other.folder, "Terminals")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("terminal notes written while turned off: %v", err)
	}
}

// vaultTree reads every file under a folder: its content and when it was
// modified.
func vaultTree(t *testing.T, folder string) map[string]string {
	t.Helper()
	tree := map[string]string{}
	err := filepath.WalkDir(folder, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		relative, _ := filepath.Rel(folder, path)
		tree[filepath.ToSlash(relative)] = info.ModTime().String() + "\n" + string(data)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

func TestVaultFolderMissingPausesAndResumes(t *testing.T) {
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	w := f.writer()
	f.settle(w)
	one := vaultChatPath("c1", "One")
	modified := f.modified(one)

	// The folder is moved away (or its drive leaves): the writer pauses and
	// neither makes it again nor follows it.
	moved := f.folder + " moved"
	if err := os.Rename(f.folder, moved); err != nil {
		t.Fatal(err)
	}
	away := vaultTree(t, moved)
	mustArchiveChat(t, f.archive, "c2", "p1", "Two")
	flushArchive(t, f.archive)
	for _, writer := range []*vaultWriter{w, f.writer()} {
		if _, err := writer.pass(t.Context()); err == nil {
			t.Fatal("a pass without the folder succeeded")
		}
		if status := writer.status(); status.State != "paused" || status.Reason != vaultPausedMissing || !strings.Contains(status.Message, f.folder) {
			t.Fatalf("status %+v", status)
		}
	}
	if _, err := os.Stat(f.folder); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the folder was made again: %v", err)
	}
	if tree := vaultTree(t, moved); !maps.Equal(tree, away) {
		t.Fatal("the moved folder was written")
	}

	// It comes back: the writer goes on where it stopped.
	if err := os.Rename(moved, f.folder); err != nil {
		t.Fatal(err)
	}
	f.settle(w)
	if notes := f.notesIn("Chats/"); !slices.Equal(notes, []string{one, vaultChatPath("c2", "Two")}) || !f.modified(one).Equal(modified) {
		t.Fatalf("notes %v", notes)
	}
	if status := w.status(); status.State != "current" || status.Reason != "" || status.Notes != 2 {
		t.Fatalf("status %+v", status)
	}
}

func TestVaultUnwritableReportsPermission(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs Unix permissions that apply to the test")
	}
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	w := f.writer()
	f.settle(w)
	if err := os.Chmod(f.folder, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(f.folder, 0o700) })
	mustArchiveChat(t, f.archive, "c2", "p1", "Two")
	flushArchive(t, f.archive)
	for _, writer := range []*vaultWriter{w, f.writer()} {
		if _, err := writer.pass(t.Context()); !errors.Is(err, fs.ErrPermission) {
			t.Fatalf("pass in a folder it may not use: %v", err)
		}
		if status := writer.status(); status.State != "paused" || status.Reason != vaultPausedPermission {
			t.Fatalf("status %+v", status)
		}
	}

	if err := os.Chmod(f.folder, 0o700); err != nil {
		t.Fatal(err)
	}
	f.settle(w)
	if notes := f.notesIn("Chats/"); len(notes) != 2 || w.status().Reason != "" {
		t.Fatalf("notes %v, status %+v", notes, w.status())
	}
}

func TestVaultPausesBelowOneGiBFree(t *testing.T) {
	f := newVaultFixture(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	var free atomic.Uint64
	free.Store(vaultMinimumFree - 1)
	w := f.writer()
	w.freeSpace = func(folder string) (uint64, error) {
		if folder != f.folder {
			t.Errorf("free space asked for %s", folder)
		}
		return free.Load(), nil
	}
	flushArchive(t, f.archive)
	if _, err := w.pass(t.Context()); err == nil {
		t.Fatal("a pass with too little space succeeded")
	}
	if status := w.status(); status.State != "paused" || status.Reason != vaultPausedLowSpace || f.files() != 0 {
		t.Fatalf("status %+v, %d files", status, f.files())
	}
	free.Store(vaultMinimumFree)
	f.settle(w)
	if count, _ := f.written(); count != 1 {
		t.Fatalf("%d notes", count)
	}
}

func TestVaultRefusesAnotherArchivesFolder(t *testing.T) {
	mine := newVaultFixture(t)
	mustArchiveChat(t, mine.archive, "c1", "p1", "Mine")
	w := mine.writer()
	mine.settle(w)
	before := vaultTree(t, mine.folder)

	// Another Mac's archive syncs the same folder.
	theirs := newVaultFixture(t)
	theirs.folder = mine.folder
	mustArchiveChat(t, theirs.archive, "c9", "p1", "Theirs")
	other := theirs.writer()
	flushArchive(t, theirs.archive)
	if _, err := other.pass(t.Context()); err == nil {
		t.Fatal("another archive's writer wrote in the folder")
	}
	if status := other.status(); status.State != "paused" || status.Reason != vaultPausedOther {
		t.Fatalf("status %+v", status)
	}
	if tree := vaultTree(t, mine.folder); !maps.Equal(tree, before) || theirs.files() != 0 {
		t.Fatalf("the folder changed: %d files written", theirs.files())
	}

	// Taken over on purpose, it is theirs, and this archive stops writing.
	other.adopt = true
	theirs.settle(other)
	if !slices.Contains(theirs.notesIn("Chats/"), vaultChatPath("c9", "Theirs")) {
		t.Fatalf("notes %v", theirs.notes())
	}
	mustArchiveChat(t, mine.archive, "c2", "p1", "Mine too")
	flushArchive(t, mine.archive)
	if _, err := w.pass(t.Context()); err == nil || w.status().Reason != vaultPausedOther {
		t.Fatalf("pass after the take-over: %v, %+v", err, w.status())
	}
}

func TestVaultNeverWritesNotes(t *testing.T) {
	f := newVaultFixture(t)
	notes := filepath.Join(f.folder, vaultNotesFolder)
	stale := filepath.Join(f.folder, "Chats", "Old", vaultTempPrefix+"stale")
	for path, text := range map[string]string{
		filepath.Join(notes, "Moved chat.md"):           "---\nagentland-id: chat/c1\n---\nMine.\n",
		filepath.Join(notes, "Chats", "Plan.md"):        "My plan.\n",
		filepath.Join(notes, vaultTempPrefix+"mine.md"): "Also mine.\n",
		stale: "half a note",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	before := vaultTree(t, notes)
	// A workspace named Notes still gets its own folders.
	mustArchiveChat(t, f.archive, "c1", "p1", "One")
	vaultTestTerminal(t, f.archive, "p1", "Build", "shell", archiveTestStart, "make\r\n", "exited")
	w := f.writer()
	w.workspaces = func() map[string]string { return map[string]string{"p1": "Notes"} }
	f.settle(w)
	if tree := vaultTree(t, notes); !maps.Equal(tree, before) {
		t.Fatalf("Notes/ changed: %v", tree)
	}
	for path := range f.writes {
		if strings.HasPrefix(path, vaultNotesFolder+"/") {
			t.Fatalf("wrote %s", path)
		}
	}
	if _, err := os.Stat(stale); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a stale temporary file is still there: %v", err)
	}
	if !slices.Contains(f.notes(), "Chats/Notes/"+vaultNoteBase(archiveTestStart.In(vaultTestZone), "One", "c1", vaultShortIDLength)+".md") || !slices.Contains(f.notes(), "Workspaces/Notes.md") {
		t.Fatalf("notes %v", f.notes())
	}

	// A new vault's Notes/ is made empty.
	fresh := newVaultWriter(f.archive, "v2", filepath.Join(t.TempDir(), "Fresh Vault"))
	t.Cleanup(fresh.stop)
	if _, err := fresh.pass(t.Context()); err != nil {
		t.Fatal(err)
	}
	if entries, err := os.ReadDir(filepath.Join(fresh.folder, vaultNotesFolder)); err != nil || len(entries) != 0 {
		t.Fatalf("Notes/ in a new vault: %v %v", entries, err)
	}
}
