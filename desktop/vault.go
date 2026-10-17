package host

import (
	"cmp"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

// The vault writer keeps a folder of Markdown notes in step with the archive:
// a note per chat under Chats/<workspace>/ and per terminal under
// Terminals/<workspace>/, named once (vault_files.go) and rewritten as the
// chat or terminal goes on, with the images chats embed under Attachments/;
// hubs that list them by workspace (Workspaces/) and by provider
// (Providers/), a note per day (Daily/) and a README (vault_lists.go).
//
// It reads the change feed raw (vaultChangeRows), 500 changes at a time from
// its cursor, into a dirty set: one entry per note, with the oldest change it
// has not written. Each entry is rendered from one short read transaction and
// written with writeNote. A chat is rendered at most every 5 s, so a reply
// that streams rewrites its note every 5 s, and its messages are kept
// rendered by their archive digest, so only what changed is masked again. The
// cursor saved with the records of what was written is the oldest change
// still dirty less one: a restart reads again only what may be unwritten and
// rewrites nothing that is current.
//
// A running terminal is not in the change feed until it ends: the writer
// feeds each open log's new output to a model of its note (vault_terminal.go)
// every 30 s and rewrites the note's changed parts, never appending, so the
// user's text below the marker stays last. When the terminal ends, its final
// change renders the whole note again from the log in one pass.
//
// Turned on for a folder, it first writes every chat and terminal the archive
// holds (the backfill: the changes up to the feed's newest when it started),
// at most 25 notes a second, after live changes and never while a chat runs a
// turn. Deleting a chat or terminal keeps its note, and the hubs keep listing
// it (they list what the vault holds).
//
// The folder is the vault's while its marker (.agentland/vault.json) names
// this archive: a folder another archive writes is refused. Before each pass
// the writer checks that the folder is still where it was, is still this
// archive's and has at least 1 GiB free, and pauses otherwise (vaultStatus's
// Reason), trying again every 30 s. It never writes in Notes/, which it
// creates empty for the user.

const (
	vaultChatEvery   = 5 * time.Second
	vaultBackfillGap = time.Second / 25
	vaultPageSize    = 500
	vaultPausePoll   = 250 * time.Millisecond
	vaultRetry       = 30 * time.Second
	// vaultCacheBytes bounds the rendered messages kept, the chat being
	// written aside.
	vaultCacheBytes = 64 << 20
	// vaultLongestShortID is the longest short ID tried when a new note's
	// name is taken.
	vaultLongestShortID = 12
	// A running terminal's note is rewritten at most every
	// vaultTerminalEvery, and the hubs and Daily notes at most every
	// vaultHubEvery.
	vaultTerminalEvery = 30 * time.Second
	vaultHubEvery      = 30 * time.Second
	// vaultMinimumFree is the least free space the vault writes with.
	vaultMinimumFree = 1 << 30
	vaultMarkerPath  = ".agentland/vault.json"
	vaultMarkerLimit = 64 << 10
	vaultNotesFolder = "Notes"
)

// Why the writer is paused (vaultStatus.Reason).
const (
	vaultPausedMissing    = "folder_missing" // the folder is not at its path
	vaultPausedPermission = "permission"     // the system refused access
	vaultPausedLowSpace   = "low_space"      // less than 1 GiB free
	vaultPausedOther      = "other_archive"  // another archive writes the folder
	vaultPausedError      = "error"
)

// vaultPause is an error that names why the writer is paused.
type vaultPause struct {
	reason string
	err    error
}

func (pause *vaultPause) Error() string { return pause.err.Error() }
func (pause *vaultPause) Unwrap() error { return pause.err }

// vaultPauseReason classifies a failed pass.
func vaultPauseReason(err error) string {
	var pause *vaultPause
	switch {
	case errors.As(err, &pause):
		return pause.reason
	case errors.Is(err, fs.ErrPermission):
		return vaultPausedPermission
	}
	return vaultPausedError
}

// vaultMarker is .agentland/vault.json: the archive (its epoch) and vault
// that write the folder.
type vaultMarker struct {
	Version int    `json:"version"`
	Archive string `json:"archive"`
	Vault   string `json:"vault"`
}

// vaultStatus is what the writer reports.
type vaultStatus struct {
	// State is off, writing (notes are waiting), current or paused (the last
	// pass failed: Reason, one of the vaultPaused values, and Message say
	// why).
	State   string
	Reason  string
	Message string
	Notes   int64 // chat and terminal notes in the folder
	Pending int   // notes waiting to be written
	// Skipped counts notes left alone: edited without their marker, or
	// another file where they would go.
	Skipped     int
	Backfill    vaultProgress
	LastWriteAt time.Time
}

// vaultProgress is the backfill's progress, in notes.
type vaultProgress struct {
	Done, Total int64
}

// vaultKey names a note's source: a chat (entity "chat") or a terminal log.
type vaultKey struct {
	entity, id string
}

// vaultDirty is a note with changes the vault has not written: the oldest of
// them, the newest, and when to try again after a write that has to wait.
type vaultDirty struct {
	first, last int64
	retry       time.Time
	done        bool // written in this pass, until the pass is saved
}

// vaultQueued is a dirty entry in the order of its oldest change.
type vaultQueued struct {
	key vaultKey
	seq int64
}

// vaultBatch is what one pass saves.
type vaultBatch struct {
	files      []vaultFileRecord
	paths      map[string]vaultFileKey // the files' paths
	done       []vaultKey
	notes      int64             // new notes
	workspaces map[string]string // workspace names, read once a pass
	listed     bool              // a note's listing was recorded
	lists      bool              // the hubs and Daily notes are written
}

// vaultSource is the note a writeParts call writes: its records' entity and
// ID, its agentland-id, its first title and its listing.
type vaultSource struct {
	entity, id, noteID string
	firstTitle         string
	listing            vaultListing
}

// vaultRunning is a running terminal's note as the writer builds it: its
// model, fed the log so far, when it is next due and the title it was last
// written with.
type vaultRunning struct {
	model   *vaultTerminal
	due     time.Time
	title   string
	written bool
}

// vaultChatCache keeps a chat's rendered messages by message ID with their
// archive digests, valid while the renderer's context is the same.
type vaultChatCache struct {
	context  string
	messages map[string]vaultCachedMessage
	size     int
	used     int64
}

type vaultCachedMessage struct {
	digest string
	note   vaultMessageNote
}

func (cache *vaultChatCache) has(ref vaultMessageRef) bool {
	if cache == nil || ref.digest == "" {
		return false
	}
	cached, found := cache.messages[ref.id]
	return found && cached.digest == ref.digest
}

// vaultMessageRef is a visible message: its ID and archive digest (empty for
// a message whose digest was cleared, which is never kept rendered).
type vaultMessageRef struct {
	id, digest string
}

// vaultWorkspace is a workspace's current name and its folder, fixed when the
// vault first saw it.
type vaultWorkspace struct {
	name, folder string
}

type vaultWriter struct {
	archive *Archive
	vaultID string
	folder  string

	now        func() time.Time
	busy       func() bool              // a chat runs a turn
	workspaces func() map[string]string // workspace names by project ID
	location   *time.Location           // note times (time.Local when nil)
	// terminals says whether terminals have notes (on unless turned off).
	terminals bool
	// adopt lets the writer take over a folder another archive's marker
	// names, once: it is cleared when the writer writes its own marker.
	adopt bool
	// chatEvery, terminalEvery and hubEvery are the least times between
	// writes of a chat's note, a running terminal's and the hubs.
	chatEvery, terminalEvery, hubEvery time.Duration
	// backfillGap is the least time between backfill notes; pausePoll how
	// often a paused backfill checks again; retry how long a failed pass
	// waits.
	backfillGap, pausePoll, retry time.Duration
	freeSpace                     func(directory string) (uint64, error)
	newTerminal                   func() *vaultTerminal
	// afterWrite runs after each file is written (tests).
	afterWrite func(path string)
	save       func(vaultStateRecord, []vaultFileRecord, []vaultFileKey) error

	mu       sync.Mutex
	cancel   context.CancelFunc
	finished chan struct{}
	stat     vaultStatus

	// The rest belongs to whoever runs passes: run, or a test.
	root       *os.Root
	ready      bool // the state below is loaded
	counting   bool // the first read on turning on counts the backfill
	read       int64
	until      int64 // the backfill is the changes up to this seq
	total      int64 // notes in the backfill
	backlog    int64 // dirty entries from the backfill
	saved      vaultStateRecord
	dirty      map[vaultKey]*vaultDirty
	live       map[vaultKey]bool // dirty entries with changes after the backfill
	queue      []vaultQueued
	rendered   map[string]time.Time // when each chat was last rendered
	folders    map[string]string    // workspace folders by project ID
	leftAlone  map[string]bool      // note paths
	caches     map[string]*vaultChatCache
	cacheBytes int
	uses       int64
	backfillAt time.Time // when the next backfill note may be written
	notes      int64
	lastWrite  time.Time
	running    map[string]*vaultRunning // by terminal log ID
	listsDirty bool                     // the hubs may list something new
	listsAt    time.Time                // when the hubs may be written again
	listNames  map[string]string        // the workspace names they were written with
	// messageRenders counts messages rendered (tests).
	messageRenders int
}

// newVaultWriter writes the vault vaultID into folder. It is off until
// start.
func newVaultWriter(archive *Archive, vaultID, folder string) *vaultWriter {
	return &vaultWriter{archive: archive, vaultID: vaultID, folder: folder, now: time.Now,
		busy: func() bool { return false }, workspaces: func() map[string]string { return nil }, terminals: true,
		chatEvery: vaultChatEvery, terminalEvery: vaultTerminalEvery, hubEvery: vaultHubEvery,
		backfillGap: vaultBackfillGap, pausePoll: vaultPausePoll, retry: vaultRetry,
		freeSpace: archive.freeSpace, newTerminal: newVaultTerminal, save: archive.saveVault, stat: vaultStatus{State: "off"}}
}

// start runs passes in the background until stop.
func (w *vaultWriter) start() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.cancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan struct{})
	w.cancel, w.finished = cancel, finished
	w.stat.State, w.stat.Reason, w.stat.Message = "writing", "", ""
	go func() {
		defer close(finished)
		w.run(ctx)
	}()
}

// stop ends the passes and waits for them, which takes well under a second:
// a pass stops between notes and between messages. The notes stay as they
// are, and the next start goes on from the saved cursor.
func (w *vaultWriter) stop() {
	w.mu.Lock()
	cancel, finished := w.cancel, w.finished
	w.cancel, w.finished = nil, nil
	w.mu.Unlock()
	if cancel != nil {
		cancel()
		<-finished
	}
	w.close()
	w.mu.Lock()
	w.stat.State, w.stat.Reason, w.stat.Message = "off", "", ""
	w.mu.Unlock()
}

func (w *vaultWriter) status() vaultStatus {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.stat
}

// run passes until ctx ends, waiting between passes for a change, the next
// note that is due, or (after a failure) the retry delay.
func (w *vaultWriter) run(ctx context.Context) {
	for {
		changed := w.archive.changeSignal()
		next, err := w.pass(ctx)
		if ctx.Err() != nil {
			return
		}
		var timer *time.Timer
		var due <-chan time.Time
		switch {
		case err != nil:
			timer = time.NewTimer(w.retry)
		case !next.IsZero():
			timer = time.NewTimer(max(next.Sub(w.now()), 0))
		}
		if timer != nil {
			due = timer.C
		}
		select {
		case <-ctx.Done():
		case <-changed:
		case <-due:
		}
		if timer != nil {
			timer.Stop()
		}
	}
}

// pass reads the change feed, writes the notes that are due and saves what it
// wrote with the cursor. It returns when the next note is due: zero when none
// waits for anything but a change.
func (w *vaultWriter) pass(ctx context.Context) (time.Time, error) {
	next, err := w.writePass(ctx)
	if ctx.Err() == nil {
		w.report(err)
	}
	return next, err
}

func (w *vaultWriter) report(err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err != nil {
		w.stat.State, w.stat.Reason, w.stat.Message = "paused", vaultPauseReason(err), err.Error()
		return
	}
	state := "current"
	if len(w.dirty) > 0 {
		state = "writing"
	}
	w.stat = vaultStatus{State: state, Notes: w.notes, Pending: len(w.dirty), Skipped: len(w.leftAlone),
		Backfill: vaultProgress{Done: max(w.total-w.backlog, 0), Total: w.total}, LastWriteAt: w.lastWrite}
}

// open readies the writer for a pass. Once prepared, it checks that the
// folder at the vault's path is still the one it opened (one moved away,
// deleted or replaced is opened again from its path, if anything is there),
// that it is still this archive's, and that it has room.
func (w *vaultWriter) open(ctx context.Context) error {
	if w.ready {
		info, err := os.Stat(w.folder)
		opened, openedErr := w.root.Stat(".")
		if err != nil || openedErr != nil || !os.SameFile(info, opened) {
			w.close()
		} else if err := w.claim(w.root); err != nil {
			return err
		}
	}
	if err := w.prepare(ctx); err != nil {
		return err
	}
	free, err := w.freeSpace(w.folder)
	if err != nil {
		return err
	}
	if free < vaultMinimumFree {
		return &vaultPause{reason: vaultPausedLowSpace, err: fmt.Errorf("less than 1 GB is free for the vault folder %s", w.folder)}
	}
	return nil
}

// close forgets the open folder; the next pass prepares again.
func (w *vaultWriter) close() {
	if w.root != nil {
		w.root.Close()
		w.root = nil
	}
	w.ready = false
}

// prepare loads the vault's state, once: on first use the folder is created,
// with an empty Notes/ for the user, and the backfill starts from the
// beginning of the feed. A vault whose folder is gone is paused, not
// created again. Temporary files a cut-short write left are removed.
func (w *vaultWriter) prepare(ctx context.Context) error {
	if w.ready {
		return nil
	}
	state, err := w.archive.vaultState(ctx, w.vaultID)
	first := errors.Is(err, sql.ErrNoRows)
	if err != nil && !first {
		return err
	}
	if first {
		if err := os.MkdirAll(w.folder, 0o700); err != nil {
			return err
		}
		state = vaultStateRecord{BackfillUntil: -1}
	}
	notes, err := w.archive.vaultNoteCount(ctx, w.vaultID)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(w.folder)
	if errors.Is(err, fs.ErrNotExist) {
		return &vaultPause{reason: vaultPausedMissing, err: fmt.Errorf("the vault folder %s is missing", w.folder)}
	}
	if err != nil {
		return err
	}
	if err := w.claim(root); err != nil {
		root.Close()
		return err
	}
	if first {
		if err := root.Mkdir(vaultNotesFolder, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			root.Close()
			return err
		}
	}
	vaultRemoveTemporaryFiles(root)
	w.close()
	// A vault that has not read the feed since it was turned on or reset
	// (resetVault) counts its backfill on its first read.
	w.root, w.ready, w.counting = root, true, state.BackfillUntil < 0
	w.read, w.until, w.total, w.backlog, w.saved = state.Cursor, state.BackfillUntil, state.BackfillTotal, 0, state
	w.dirty, w.live, w.queue = map[vaultKey]*vaultDirty{}, map[vaultKey]bool{}, nil
	w.rendered, w.folders, w.leftAlone = map[string]time.Time{}, map[string]string{}, map[string]bool{}
	w.caches, w.cacheBytes, w.backfillAt, w.notes = map[string]*vaultChatCache{}, 0, time.Time{}, notes
	w.running, w.listsDirty, w.listsAt, w.listNames = map[string]*vaultRunning{}, true, time.Time{}, nil
	return nil
}

// claim makes sure the folder is this archive's vault: a folder without a
// marker gets this archive's, and one whose marker names another archive (or
// cannot be read) is refused unless the writer adopts it.
func (w *vaultWriter) claim(root *os.Root) error {
	marker := vaultMarker{Version: 1, Archive: w.archive.epoch, Vault: w.vaultID}
	info, err := root.Lstat(filepath.FromSlash(vaultMarkerPath))
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return err
	default:
		found, ours := vaultMarker{}, info.Mode().IsRegular() && info.Size() <= vaultMarkerLimit
		if ours {
			data, err := root.ReadFile(filepath.FromSlash(vaultMarkerPath))
			if err != nil {
				return err
			}
			ours = json.Unmarshal(data, &found) == nil && found.Archive == marker.Archive
		}
		if found == marker {
			return nil
		}
		if !ours && !w.adopt {
			return &vaultPause{reason: vaultPausedOther, err: fmt.Errorf("the folder %s is another AgentLand archive's vault", w.folder)}
		}
	}
	if err := root.MkdirAll(filepath.Dir(filepath.FromSlash(vaultMarkerPath)), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(marker)
	if err != nil {
		return err
	}
	if err := replaceVaultFile(root, vaultMarkerPath, append(data, '\n')); err != nil {
		return err
	}
	// A folder is taken over once: should another archive take it back, this
	// writer is refused again instead of taking turns with it.
	w.adopt = false
	return nil
}

// vaultOwnFolders are the folders the writer writes in.
var vaultOwnFolders = []string{"Chats", "Terminals", "Workspaces", "Providers", "Daily", "Attachments", ".agentland"}

// vaultRemoveTemporaryFiles removes the temporary files that writes cut short
// left in the vault's own folders and at its top. Notes/ and the user's other
// folders are not looked at.
func vaultRemoveTemporaryFiles(root *os.Root) {
	remove := func(name string, entry fs.DirEntry) {
		if entry.Type().IsRegular() && strings.HasPrefix(entry.Name(), vaultTempPrefix) {
			_ = root.Remove(filepath.FromSlash(name))
		}
	}
	if entries, err := fs.ReadDir(root.FS(), "."); err == nil {
		for _, entry := range entries {
			remove(entry.Name(), entry)
		}
	}
	for _, folder := range vaultOwnFolders {
		_ = fs.WalkDir(root.FS(), folder, func(name string, entry fs.DirEntry, err error) error {
			if err == nil {
				remove(name, entry)
			}
			return nil
		})
	}
}

// readFeed reads the changes after the newest read into the dirty set.
func (w *vaultWriter) readFeed(ctx context.Context) error {
	for {
		page, err := w.archive.vaultChangeRows(ctx, w.read, vaultPageSize)
		if err != nil {
			return err
		}
		if w.until < 0 {
			w.until = page.High
		}
		for _, row := range page.Rows {
			w.mark(row)
		}
		if count := len(page.Rows); count > 0 {
			w.read = page.Rows[count-1].Seq
		}
		if len(page.Rows) < vaultPageSize {
			break
		}
	}
	if w.counting {
		w.total, w.counting = w.backlog, false
	}
	return nil
}

func (w *vaultWriter) mark(row vaultChange) {
	key := vaultKey{entity: row.Entity, id: row.EntityID}
	if row.Entity == "chat" || row.Entity == "message" {
		key = vaultKey{entity: "chat", id: row.ChatID}
	}
	if key.id == "" {
		return
	}
	entry := w.dirty[key]
	if entry == nil {
		entry = &vaultDirty{first: row.Seq}
		w.dirty[key] = entry
		w.queue = append(w.queue, vaultQueued{key: key, seq: row.Seq})
		if row.Seq <= w.until {
			w.backlog++
		}
	}
	entry.last = row.Seq
	if row.Seq > w.until {
		w.live[key] = true
	}
}

// due is when an entry may be written: after a retry delay, and for a chat
// no sooner than chatEvery after it was last rendered.
func (w *vaultWriter) due(key vaultKey, entry *vaultDirty) time.Time {
	due := entry.retry
	if at, found := w.rendered[key.id]; found && key.entity == "chat" && at.Add(w.chatEvery).After(due) {
		due = at.Add(w.chatEvery)
	}
	return due
}

func (w *vaultWriter) writePass(ctx context.Context) (time.Time, error) {
	if err := w.open(ctx); err != nil {
		return time.Time{}, err
	}
	if err := w.readFeed(ctx); err != nil {
		return time.Time{}, err
	}
	now := w.now()
	if len(w.rendered) > 1024 {
		for id, at := range w.rendered {
			if !at.Add(w.chatEvery).After(now) {
				delete(w.rendered, id)
			}
		}
	}
	batch := &vaultBatch{paths: map[string]vaultFileKey{}}
	var next time.Time
	var failure error
	process := func(key vaultKey, entry *vaultDirty) (rendered bool) {
		rendered, retry, err := w.writeEntry(ctx, key, now, batch)
		switch {
		case err != nil:
			failure = err
		case !retry.IsZero():
			entry.retry = retry
			next = vaultEarliest(next, retry)
		default:
			entry.done = true
			batch.done = append(batch.done, key)
		}
		return rendered
	}

	// Live changes first, oldest first, each when it is due.
	live := make([]vaultKey, 0, len(w.live))
	for key := range w.live {
		live = append(live, key)
	}
	slices.SortFunc(live, func(a, b vaultKey) int { return cmp.Compare(w.dirty[a].first, w.dirty[b].first) })
	for _, key := range live {
		if failure != nil || ctx.Err() != nil {
			break
		}
		entry := w.dirty[key]
		if due := w.due(key, entry); due.After(now) {
			next = vaultEarliest(next, due)
			continue
		}
		process(key, entry)
		now = w.now()
	}

	// Running terminals, each every terminalEvery.
	if failure == nil && ctx.Err() == nil {
		due, err := w.pollTerminals(ctx, now, batch)
		next, failure = vaultEarliest(next, due), err
		now = w.now()
	}

	// Then the backfill, oldest first, at its pace and never while a chat
	// runs a turn.
	if w.backlog > 0 && failure == nil && ctx.Err() == nil {
		if w.busy() {
			next = vaultEarliest(next, now.Add(w.pausePoll))
		} else {
			for _, item := range w.queue {
				if failure != nil || ctx.Err() != nil {
					break
				}
				entry := w.dirty[item.key]
				if entry == nil || entry.first != item.seq || entry.done || w.live[item.key] {
					continue
				}
				if due := w.due(item.key, entry); due.After(now) {
					next = vaultEarliest(next, due)
					continue
				}
				if w.backfillAt.After(now) {
					next = vaultEarliest(next, w.backfillAt)
					break
				}
				if process(item.key, entry) {
					w.backfillAt = vaultLatest(w.backfillAt, now).Add(w.backfillGap)
				}
				now = w.now()
			}
		}
	}

	// Then the hubs, the Daily notes and the README, with what this pass
	// wrote.
	if failure == nil && ctx.Err() == nil {
		due, err := w.writeLists(ctx, now, batch)
		next, failure = vaultEarliest(next, due), err
	}

	if err := w.saveBatch(batch); err != nil {
		return next, err
	}
	if failure == nil {
		failure = ctx.Err()
	}
	return next, failure
}

// saveBatch records the pass's files with the cursor (the oldest change still
// dirty, less one) and the backfill's progress; then what it wrote is no
// longer dirty. When the records cannot be saved everything stays dirty, to
// be written (or found unchanged) again.
func (w *vaultWriter) saveBatch(batch *vaultBatch) error {
	cursor := w.read
	for _, item := range w.queue {
		if entry := w.dirty[item.key]; entry != nil && entry.first == item.seq && !entry.done {
			cursor = item.seq - 1
			break
		}
	}
	backlog := w.backlog
	for _, key := range batch.done {
		if w.dirty[key].first <= w.until {
			backlog--
		}
	}
	state := vaultStateRecord{VaultID: w.vaultID, Root: w.folder, Cursor: cursor, BackfillUntil: w.until,
		BackfillTotal: w.total, BackfillDone: max(w.total-backlog, 0)}
	saved := w.saved
	saved.UpdatedAt = time.Time{}
	if len(batch.files) > 0 || saved != state {
		if err := w.save(state, batch.files, nil); err != nil {
			for _, key := range batch.done {
				w.dirty[key].done = false
			}
			// Folders chosen in this pass were not recorded.
			w.folders = map[string]string{}
			return err
		}
		w.saved = state
	}
	if batch.lists {
		w.listsDirty, w.listNames = false, batch.workspaces
	}
	for _, key := range batch.done {
		delete(w.dirty, key)
		delete(w.live, key)
	}
	w.backlog, w.notes = backlog, w.notes+batch.notes
	for len(w.queue) > 0 {
		if entry := w.dirty[w.queue[0].key]; entry != nil && entry.first == w.queue[0].seq {
			break
		}
		w.queue[0] = vaultQueued{}
		w.queue = w.queue[1:]
	}
	if len(w.queue) == 0 {
		w.queue = nil
	}
	return nil
}

// writeEntry writes one dirty entry's note. It reports whether it rendered
// one (which the backfill's pace counts) and, when the note has to wait, when
// to try again.
func (w *vaultWriter) writeEntry(ctx context.Context, key vaultKey, now time.Time, batch *vaultBatch) (bool, time.Time, error) {
	switch key.entity {
	case "chat":
		return w.writeChat(ctx, key.id, now, batch)
	case "terminalLog":
		return w.writeTerminal(ctx, key.id, now, batch)
	}
	return false, time.Time{}, nil
}

// writeChat renders a chat's note and writes its parts and images. A chat is
// written once it has a real title or a finished reply; a deleted chat's
// note stays as it is.
func (w *vaultWriter) writeChat(ctx context.Context, chatID string, now time.Time, batch *vaultBatch) (bool, time.Time, error) {
	snapshot, err := w.loadChat(ctx, chatID)
	if errors.Is(err, sql.ErrNoRows) || err == nil && !snapshot.ready {
		return false, time.Time{}, nil
	}
	if err != nil {
		return false, time.Time{}, err
	}
	chat := snapshot.chat
	workspace, err := w.workspace(ctx, chat.ProjectID, batch)
	if err != nil {
		return false, time.Time{}, err
	}
	names := vaultChatNames{ProviderName: vaultProviderName(chat.Provider), WorkspaceName: workspace.name, WorkspaceFolder: workspace.folder, Location: w.location}
	if chat.Relation == "continue" && chat.ParentID != "" {
		parent, err := w.archive.vaultFile(ctx, w.vaultID, vaultFileKey{Entity: "chat", EntityID: chat.ParentID, Part: 1})
		if err == nil {
			names.ContinuedFrom = vaultLink{Path: strings.TrimSuffix(parent.Path, ".md"), Title: snapshot.parentTitle}
		} else if !errors.Is(err, sql.ErrNoRows) {
			return false, time.Time{}, err
		}
	}
	key := vaultFileKey{Entity: "chat", EntityID: chatID, Part: 1}
	record, err := w.archive.vaultFile(ctx, w.vaultID, key)
	recorded := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, time.Time{}, err
	}
	// The note keeps the name and the first real title it was given.
	named := chat.TitleSource != titleDefault
	names.FirstTitle = record.FirstTitle
	if names.FirstTitle == "" && named {
		names.FirstTitle = chat.Title
	}

	r := newVaultChatRenderer(chat, names)
	notes, err := w.messageNotes(ctx, r, chatID, snapshot)
	if err != nil {
		return false, time.Time{}, err
	}
	w.rendered[chatID] = now
	title := ""
	if named {
		title = maskVaultSecrets(chat.Title)
	}
	source := vaultSource{entity: "chat", id: chatID, noteID: "chat/" + chatID, firstTitle: names.FirstTitle,
		listing: vaultListing{Title: vaultChatTitle(chat), Provider: chat.Provider, ProjectID: chat.ProjectID, Started: chat.CreatedAt, Active: chat.UpdatedAt}}
	retry, err := w.writeNamed(ctx, key, record, recorded, batch, func(length int) string {
		return "Chats/" + workspace.folder + "/" + vaultNoteBase(r.started, title, chatID, length)
	}, func(base string) (time.Time, error) {
		names.Base = base
		r.names = names
		return w.writeParts(ctx, source, r.parts(chat, notes, snapshot.interactions), record, recorded, now, batch)
	})
	return true, retry, err
}

// writeNamed writes a note under its recorded name or, for a new note, under
// the first of its names (name gives one for each short ID length) that no
// other file holds; a note no name fits is left alone. write writes the note
// at a base path (without ".md") and returns errVaultNotOurs when another
// file is there.
func (w *vaultWriter) writeNamed(ctx context.Context, key vaultFileKey, record vaultFileRecord, recorded bool, batch *vaultBatch,
	name func(length int) string, write func(base string) (time.Time, error)) (time.Time, error) {
	for length := vaultShortIDLength; ; length++ {
		base := strings.TrimSuffix(record.Path, ".md")
		if !recorded {
			base = name(length)
			taken, err := w.pathTaken(ctx, base+".md", key, batch)
			if err != nil {
				return time.Time{}, err
			}
			if taken {
				if length < vaultLongestShortID {
					continue
				}
				w.leftAlone[base+".md"] = true
				return time.Time{}, nil
			}
		}
		retry, err := write(base)
		if errors.Is(err, errVaultNotOurs) {
			if length < vaultLongestShortID {
				continue
			}
			w.leftAlone[base+".md"] = true
			err = nil
		}
		return retry, err
	}
}

// writeParts writes a note's parts, those whose text changed, and copies the
// images they embed. Its first part is recorded with the note's first title
// and listing. A new note whose first part finds another file at its path
// returns errVaultNotOurs, so the caller can name it again.
func (w *vaultWriter) writeParts(ctx context.Context, source vaultSource, parts []notePart, first vaultFileRecord, recorded bool, now time.Time, batch *vaultBatch) (time.Time, error) {
	var retry time.Time
	for _, part := range parts {
		key := vaultFileKey{Entity: source.entity, EntityID: source.id, Part: part.Part}
		record, known := first, recorded
		if part.Part > 1 {
			var err error
			record, err = w.archive.vaultFile(ctx, w.vaultID, key)
			if known = err == nil; err != nil && !errors.Is(err, sql.ErrNoRows) {
				return retry, err
			}
		}
		known = known && record.Path == part.Path
		file := vaultFileRecord{vaultFileKey: key, Path: part.Path, Digest: vaultDigest(vaultNoteHead(part.Text))}
		if part.Part == 1 {
			file.FirstTitle, file.Listing = source.firstTitle, source.listing
		}
		switch {
		case known && record.Digest == file.Digest:
			// As far as the vault knows the note holds this text already.
			if record.FirstTitle != file.FirstTitle || record.Listing != file.Listing {
				w.record(batch, file)
			}
		case !known && part.Part > 1:
			if taken, err := w.pathTaken(ctx, part.Path, key, batch); err != nil || taken {
				if taken {
					w.leftAlone[part.Path] = true
				}
				if err != nil {
					return retry, err
				}
				continue
			}
			fallthrough
		default:
			outcome, digest, err := writeNote(w.root, vaultNote{Path: part.Path, ID: source.noteID, Generated: part.Text, Recorded: known, Digest: record.Digest})
			switch {
			case errors.Is(err, errVaultNotOurs) && part.Part == 1 && !recorded:
				return retry, err
			case errors.Is(err, errVaultNotOurs):
				w.leftAlone[part.Path] = true
				continue
			case errors.Is(err, errVaultChanged):
				// Saved in Obsidian meanwhile: the user's save wins for now.
				retry = vaultEarliest(retry, now.Add(w.chatEvery))
				continue
			case err != nil:
				return retry, err
			}
			switch outcome {
			case vaultUserEdited:
				w.leftAlone[part.Path] = true
				continue
			case vaultEvicted:
				retry = vaultEarliest(retry, now.Add(w.retry))
				continue
			case vaultWritten:
				w.wrote(part.Path, now)
			}
			delete(w.leftAlone, part.Path)
			file.Digest = digest
			w.record(batch, file)
			if part.Part == 1 && !recorded {
				batch.notes++
			}
		}
		for _, attachment := range part.Attachments {
			if err := w.copyAttachment(ctx, attachment, now, batch); err != nil {
				return retry, err
			}
		}
	}
	return retry, nil
}

// copyAttachment copies an embedded image from the archive the first time a
// note embeds it. An image the archive does not hold is skipped.
func (w *vaultWriter) copyAttachment(ctx context.Context, attachment vaultAttachment, now time.Time, batch *vaultBatch) error {
	key := vaultFileKey{Entity: "attachment", EntityID: attachment.Path, Part: 1}
	if _, found := batch.paths[attachment.Path]; found {
		return nil
	}
	if _, err := w.archive.vaultFile(ctx, w.vaultID, key); !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	blob, err := w.archive.openBlob(attachment.SHA256, attachment.Size)
	if err != nil {
		return nil
	}
	defer blob.Close()
	written, err := writeVaultFile(w.root, attachment.Path, blob)
	if err != nil {
		return err
	}
	if written {
		w.wrote(attachment.Path, now)
	}
	batch.files = append(batch.files, vaultFileRecord{vaultFileKey: key, Path: attachment.Path, Digest: attachment.SHA256})
	batch.paths[attachment.Path] = key
	return nil
}

// record adds a file's record to the batch; a note's first part brings its
// listing, which the hubs show.
func (w *vaultWriter) record(batch *vaultBatch, file vaultFileRecord) {
	batch.files = append(batch.files, file)
	batch.paths[file.Path] = file.vaultFileKey
	if file.Part == 1 && (file.Entity == "chat" || file.Entity == "terminalLog") {
		batch.listed = true
	}
}

func (w *vaultWriter) wrote(path string, now time.Time) {
	w.lastWrite = now
	if w.afterWrite != nil {
		w.afterWrite(path)
	}
}

// pathTaken says whether the vault holds path for another file.
func (w *vaultWriter) pathTaken(ctx context.Context, path string, key vaultFileKey, batch *vaultBatch) (bool, error) {
	if owner, found := batch.paths[path]; found {
		return owner != key, nil
	}
	record, err := w.archive.vaultFileAt(ctx, w.vaultID, path)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil && record.vaultFileKey != key, err
}

// workspace returns a workspace's current name and its folder. The folder is
// named the first time the vault sees the workspace and recorded as its hub's
// path, Workspaces/<folder>.md (vault_lists.go writes it); a rename leaves it.
// The spaces that are not workspaces have their own names (vaultSpaceName);
// a workspace removed before it was seen is named by its ID.
func (w *vaultWriter) workspace(ctx context.Context, projectID string, batch *vaultBatch) (vaultWorkspace, error) {
	workspace := vaultWorkspace{name: w.workspaceNames(batch)[projectID]}
	if name := vaultSpaceName(projectID); name != "" {
		workspace.name = name
	}
	if folder, found := w.folders[projectID]; found {
		workspace.folder = folder
		return workspace, nil
	}
	key := vaultFileKey{Entity: "workspace", EntityID: projectID, Part: 1}
	record, err := w.archive.vaultFile(ctx, w.vaultID, key)
	switch {
	case err == nil:
		workspace.folder = strings.TrimSuffix(path.Base(record.Path), ".md")
	case errors.Is(err, sql.ErrNoRows):
		workspace.folder = vaultSafeName(workspace.name)
		if workspace.folder == "" {
			workspace.folder = vaultSafeName(projectID)
		}
		if workspace.folder == "" {
			workspace.folder = "Workspace"
		}
		hub := "Workspaces/" + workspace.folder + ".md"
		taken, err := w.pathTaken(ctx, hub, key, batch)
		if err != nil {
			return workspace, err
		}
		if taken {
			workspace.folder += " (" + vaultShortID(projectID, vaultShortIDLength) + ")"
			hub = "Workspaces/" + workspace.folder + ".md"
		}
		batch.files = append(batch.files, vaultFileRecord{vaultFileKey: key, Path: hub, FirstTitle: workspace.name})
		batch.paths[hub] = key
	default:
		return workspace, err
	}
	w.folders[projectID] = workspace.folder
	return workspace, nil
}

// vaultSpaceName is the name of a space that is not a workspace, by its
// archive project ID: the Chats space is General, and terminals outside any
// workspace (terminalNoWorkspaceArchiveID) are Outside Workspaces. It is ""
// for a workspace.
func vaultSpaceName(projectID string) string {
	switch projectID {
	case plainChatsProjectID:
		return "General"
	case terminalNoWorkspaceArchiveID:
		return "Outside Workspaces"
	}
	return ""
}

// workspaceNames are the workspaces' names by project ID, read once a pass.
func (w *vaultWriter) workspaceNames(batch *vaultBatch) map[string]string {
	if batch.workspaces == nil {
		batch.workspaces = w.workspaces()
		if batch.workspaces == nil {
			batch.workspaces = map[string]string{}
		}
	}
	return batch.workspaces
}

// writeTerminal writes an ended terminal's note: the whole log, rendered
// again in one pass. A running terminal's note is written by pollTerminals; a
// deleted terminal's note stays as it is.
func (w *vaultWriter) writeTerminal(ctx context.Context, id string, now time.Time, batch *vaultBatch) (bool, time.Time, error) {
	if !w.terminals {
		return false, time.Time{}, nil
	}
	log, err := archiveLoadTerminalLog(ctx, w.archive.readDB, id)
	if errors.Is(err, sql.ErrNoRows) || err == nil && log.Status == "running" {
		// A log still running when the archive was read again ends with a
		// change of its own.
		return false, time.Time{}, nil
	}
	if err != nil {
		return false, time.Time{}, err
	}
	delete(w.running, id)
	model := w.newTerminal()
	if err := w.feedTerminal(ctx, model, log); err != nil {
		return true, time.Time{}, err
	}
	retry, err := w.writeTerminalNote(ctx, log, model, now, batch)
	return true, retry, err
}

// pollTerminals writes the notes of the terminals that run, each every
// terminalEvery while it has new output or a new title: their models are fed
// what the logs gained, and the notes' changed parts (the newest, mostly) are
// rewritten whole. It returns when the next is due.
func (w *vaultWriter) pollTerminals(ctx context.Context, now time.Time, batch *vaultBatch) (time.Time, error) {
	var next time.Time
	if !w.terminals {
		return next, nil
	}
	open := []string{}
	for _, log := range w.archive.openLogs() {
		open = append(open, log.ID())
	}
	slices.Sort(open)
	for id := range w.running {
		if _, found := slices.BinarySearch(open, id); !found {
			delete(w.running, id) // ended: its final change comes through the feed
		}
	}
	for _, id := range open {
		if err := ctx.Err(); err != nil {
			return next, err
		}
		running := w.running[id]
		if running == nil {
			running = &vaultRunning{model: w.newTerminal()}
			w.running[id] = running
		}
		if running.due.After(now) {
			next = vaultEarliest(next, running.due)
			continue
		}
		running.due = now.Add(w.terminalEvery)
		next = vaultEarliest(next, running.due)
		log, err := archiveLoadTerminalLog(ctx, w.archive.readDB, id)
		if errors.Is(err, sql.ErrNoRows) {
			delete(w.running, id)
			continue
		}
		if err != nil {
			return next, err
		}
		if log.Status != "running" {
			continue
		}
		fed := running.model.offset()
		if err := w.feedTerminal(ctx, running.model, log); err != nil {
			return next, err
		}
		if running.written && running.model.offset() == fed && running.title == log.Title {
			continue
		}
		retry, err := w.writeTerminalNote(ctx, log, running.model, now, batch)
		if err != nil {
			return next, err
		}
		running.written, running.title = retry.IsZero(), log.Title
	}
	return next, nil
}

// feedTerminal feeds a model the output of log it has not seen, up to the
// log's size when the first read was made, a megabyte at a time.
func (w *vaultWriter) feedTerminal(ctx context.Context, model *vaultTerminal, log archiveTerminalLogJSON) error {
	end := int64(-1)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		chunk, err := w.archive.ReadTerminalLog(log, model.offset(), terminalLogRangeLimit)
		if errors.Is(err, ErrNotFound) || errors.Is(err, errArchiveRange) {
			return nil // the file is gone or shorter: the note shows what was read
		}
		if err != nil {
			return err
		}
		model.write(chunk.Data)
		if end < 0 {
			end = chunk.Size
		}
		if len(chunk.Data) == 0 || chunk.Next >= end {
			return nil
		}
	}
}

// writeTerminalNote writes a terminal's note from its model. A new note is
// named for the time the terminal started and its program, such as
// "2026-10-12 1432 shell (7hq2ab)".
func (w *vaultWriter) writeTerminalNote(ctx context.Context, log archiveTerminalLogJSON, model *vaultTerminal, now time.Time, batch *vaultBatch) (time.Time, error) {
	workspace, err := w.workspace(ctx, log.ProjectID, batch)
	if err != nil {
		return time.Time{}, err
	}
	key := vaultFileKey{Entity: "terminalLog", EntityID: log.ID, Part: 1}
	record, err := w.archive.vaultFile(ctx, w.vaultID, key)
	recorded := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, err
	}
	names := vaultTerminalNames{WorkspaceName: workspace.name, WorkspaceFolder: workspace.folder, Location: w.location}
	started := vaultLocalTime(log.StartedAt, w.location)
	program := vaultLine(maskVaultSecrets(log.Program))
	if program == "" {
		program = "terminal"
	}
	source := vaultSource{entity: "terminalLog", id: log.ID, noteID: "terminal/" + log.ID,
		listing: vaultListing{Title: vaultTerminalTitle(log), ProjectID: log.ProjectID, Started: log.StartedAt, Active: log.EndedAt}}
	return w.writeNamed(ctx, key, record, recorded, batch, func(length int) string {
		return "Terminals/" + workspace.folder + "/" + vaultNoteBase(started, started.Format("1504")+" "+program, log.ID, length)
	}, func(base string) (time.Time, error) {
		names.Base = base
		return w.writeParts(ctx, source, model.render(log, names), record, recorded, now, batch)
	})
}

// vaultLocalTime reads an archive time in location (time.Local when nil).
func vaultLocalTime(text string, location *time.Location) time.Time {
	if location == nil {
		location = time.Local
	}
	t, err := time.Parse(archiveTimeLayout, text)
	if err != nil {
		return time.Time{}
	}
	return t.In(location)
}

// vaultChatSnapshot is what a chat's note is rendered from, read in one
// transaction: the chat, its visible messages in order, those of them not
// kept rendered, its interactions and the title of the chat it continues.
type vaultChatSnapshot struct {
	chat         archiveChatJSON
	ready        bool // it has a real title or a finished reply
	messages     []vaultMessageRef
	loaded       map[string]archiveMessageJSON
	cache        *vaultChatCache // the rendered messages it can reuse
	interactions []archiveInteractionJSON
	parentTitle  string
}

func (w *vaultWriter) loadChat(ctx context.Context, chatID string) (vaultChatSnapshot, error) {
	snapshot := vaultChatSnapshot{loaded: map[string]archiveMessageJSON{}}
	tx, err := w.archive.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return snapshot, err
	}
	defer tx.Rollback()
	if snapshot.chat, err = archiveLoadChat(ctx, tx, chatID); err != nil {
		return snapshot, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT id, digest, role, status FROM messages WHERE chat_id = ? AND hidden = 0 ORDER BY ord, pk`, chatID)
	if err != nil {
		return snapshot, err
	}
	replied := false
	for rows.Next() {
		var ref vaultMessageRef
		var role, status string
		if err := rows.Scan(&ref.id, &ref.digest, &role, &status); err != nil {
			rows.Close()
			return snapshot, err
		}
		replied = replied || role == "assistant" && status != "streaming"
		snapshot.messages = append(snapshot.messages, ref)
	}
	if err := rows.Close(); err != nil {
		return snapshot, err
	}
	if err := rows.Err(); err != nil {
		return snapshot, err
	}
	chat := snapshot.chat
	if snapshot.ready = chat.TitleSource != titleDefault || replied; !snapshot.ready {
		return snapshot, nil
	}

	rendering := newVaultChatRenderer(chat, vaultChatNames{ProviderName: vaultProviderName(chat.Provider), Location: w.location}).context()
	if cache := w.caches[chatID]; cache != nil && cache.context == rendering {
		snapshot.cache = cache
	}
	missing := []string{}
	for _, ref := range snapshot.messages {
		if !snapshot.cache.has(ref) {
			missing = append(missing, ref.id)
		}
	}
	for start := 0; start < len(missing); start += vaultPageSize {
		ids := missing[start:min(start+vaultPageSize, len(missing))]
		messages, err := archiveLoadMessages(ctx, tx, `WHERE m.chat_id = ? AND m.id IN (`+archivePlaceholders(len(ids))+`) ORDER BY m.ord, m.pk`,
			append([]any{chatID}, archiveArgs(ids)...)...)
		if err != nil {
			return snapshot, err
		}
		for _, message := range messages {
			snapshot.loaded[message.ID] = message
		}
	}
	if snapshot.interactions, err = archiveLoadInteractions(ctx, tx, chatID); err != nil {
		return snapshot, err
	}
	if chat.Relation == "continue" && chat.ParentID != "" {
		parent, err := archiveLoadChat(ctx, tx, chat.ParentID)
		if err == nil {
			snapshot.parentTitle = parent.Title
		} else if !errors.Is(err, sql.ErrNoRows) {
			return snapshot, err
		}
	}
	return snapshot, nil
}

// messageNotes renders a chat's visible messages, reusing those kept
// rendered, and keeps the result for the chat's next render.
func (w *vaultWriter) messageNotes(ctx context.Context, r *vaultChatRenderer, chatID string, snapshot vaultChatSnapshot) ([]vaultMessageNote, error) {
	fresh := &vaultChatCache{context: r.context(), messages: make(map[string]vaultCachedMessage, len(snapshot.messages))}
	notes := make([]vaultMessageNote, 0, len(snapshot.messages))
	for _, ref := range snapshot.messages {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		cached, found := vaultCachedMessage{}, snapshot.cache.has(ref)
		if found {
			cached = snapshot.cache.messages[ref.id]
		} else if message, loaded := snapshot.loaded[ref.id]; loaded {
			cached = vaultCachedMessage{digest: ref.digest, note: r.message(message)}
			w.messageRenders++
		} else {
			continue
		}
		if ref.digest != "" {
			fresh.messages[ref.id] = cached
			fresh.size += len(cached.note.Text)
		}
		notes = append(notes, cached.note)
	}
	w.keepCache(chatID, fresh)
	return notes, nil
}

// keepCache keeps a chat's rendered messages, dropping the least recently
// used chats' beyond vaultCacheBytes.
func (w *vaultWriter) keepCache(chatID string, cache *vaultChatCache) {
	if old := w.caches[chatID]; old != nil {
		w.cacheBytes -= old.size
	}
	w.uses++
	cache.used = w.uses
	w.caches[chatID] = cache
	w.cacheBytes += cache.size
	for w.cacheBytes > vaultCacheBytes && len(w.caches) > 1 {
		oldest := ""
		for id, kept := range w.caches {
			if id != chatID && (oldest == "" || kept.used < w.caches[oldest].used) {
				oldest = id
			}
		}
		w.cacheBytes -= w.caches[oldest].size
		delete(w.caches, oldest)
	}
}

// vaultProviderName is a chat provider's display name, such as Claude Code.
func vaultProviderName(provider string) string {
	if provider == "opencode" {
		return "OpenCode"
	}
	if spec, found := localAgentSpecFor(provider); found {
		return spec.name
	}
	return provider
}

// vaultEarliest is the earlier of two times, where zero is no time.
func vaultEarliest(a, b time.Time) time.Time {
	if a.IsZero() || !b.IsZero() && b.Before(a) {
		return b
	}
	return a
}

func vaultLatest(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}
