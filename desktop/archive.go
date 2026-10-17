package host

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"

	_ "modernc.org/sqlite" // pure-Go SQLite with FTS5, registered as "sqlite"
)

// Archive is AgentLand's own copy of every chat and terminal session, so
// nothing depends on a provider keeping its history. It lives in
// <state>.archive/ (mode 0700, owned by this user, never a symlink):
//
//	archive.db                   SQLite in WAL mode, mode 0600 (archive_schema.go)
//	blobs/ab/<sha256>            chat attachments, stored once per content
//	terminals/YYYY/MM/<id>.log   raw terminal output; keystrokes are never recorded
//
// One writer goroutine applies all changes in batches: 250 ms after the first
// queued write, or at once when a caller waits for the result. Reads use a
// separate pool of query-only connections. Retention is unlimited; only an
// explicit delete removes data. When the archive's file system runs low,
// terminal output and attachment bytes stop being recorded below 2 GiB free,
// and chat text (chats, messages, interactions) only below 256 MiB; both
// resume when space returns.
//
// The API the rest of the host calls:
//
//	UpsertChat(ArchiveChat) error                 chat metadata (queued)
//	UpsertMessage(ArchiveMessage) error           a full snapshot of one message (queued); call it
//	                                              periodically while it streams and once when final
//	RecordInteraction(ArchiveInteraction) error   how an approval or question ended (queued)
//	DeleteChat(chatID string) error               removes a chat, leaves a tombstone (waits)
//	DeleteMessage(chatID, messageID) error        removes one message, leaves a tombstone (waits)
//	HideMessagesFrom(chatID, messageID) error     hides a rewound chat's messages from one on (queued)
//	StoreBlob(io.Reader, mime) (sha256, error)    keeps an attachment's bytes (waits)
//	Flush(ctx) error                              waits until earlier writes are committed
//	OpenTerminalLog(TerminalLogInfo)              then (*TerminalLog).Append and Close
//	Changes, ChatPage, Search, Export, TerminalLogs, ReadTerminalLog, DeleteTerminalLog, Stats
//
// Queued calls return once the input is validated; later write failures are
// counted in Stats. Flush after a queued call makes it durable before the
// caller acts on it, such as a user message before delivery. Chat delivery and terminal output never depend on the
// archive: callers note ErrArchivePaused, ErrArchiveBusy or ErrArchiveClosed
// and carry on. Writes to a deleted chat are ignored, so a delete stays final.
type Archive struct {
	directory  string
	writeDB    *sql.DB
	readDB     *sql.DB
	epoch      string
	now        func() time.Time
	freeSpace  func(string) (uint64, error)
	batchDelay time.Duration
	// enqueueWait bounds how long a write waits for room in a full queue.
	enqueueWait time.Duration

	mu      sync.Mutex
	pending []*archiveOp
	keyed   map[string]*archiveOp
	room    chan struct{} // closed and replaced whenever the writer takes a batch
	closed  bool
	logs    map[string]*TerminalLog
	lastErr string
	gcAt    time.Time

	wake       chan struct{}
	urgent     chan struct{}
	closing    chan struct{}
	writerDone chan struct{}
	closeOnce  sync.Once

	// feed closes (and is replaced) after each committed batch that recorded
	// a change, waking change-feed long-polls (GET /v1/archive/changes?wait).
	feedMu sync.Mutex
	feed   chan struct{}

	// paused stops terminal output and attachment bytes below 2 GiB free;
	// chatPaused stops chat text below 256 MiB.
	paused     atomic.Bool
	chatPaused atomic.Bool
	freeBytes  atomic.Int64 // -1 when unknown
	skipped    atomic.Int64
	failures   atomic.Int64
	batches    atomic.Int64 // transactions attempted by the writer
}

// ArchiveOptions replaces the clock, the free-space probe and the batching
// window in tests. The zero value is right for the host.
type ArchiveOptions struct {
	Now        func() time.Time
	FreeSpace  func(directory string) (uint64, error)
	BatchDelay time.Duration
}

const (
	archiveBatchDelay    = 250 * time.Millisecond
	archiveQueueCapacity = 4096
	archiveEnqueueWait   = 5 * time.Second
	// archiveMinimumFree pauses terminal output and attachment bytes, the
	// bulky part of the archive; archiveChatMinimumFree pauses chat text,
	// which is small and the owner's priority.
	archiveMinimumFree     = 2 << 30
	archiveChatMinimumFree = 256 << 20
	archiveBlobLimit       = 64 << 20
	archiveBlobGrace       = 24 * time.Hour
	archiveGCInterval      = time.Hour
	archiveReadConnections = 4
	archiveIDLimit         = 256
	archiveLabelLimit      = 256
	archiveTitleLimit      = 1 << 10
	archiveSummaryLimit    = 1 << 10
	archiveErrorLimit      = 4 << 10
	archiveSearchTextLimit = 256 << 10
	archivePartTextLimit   = 2 << 20
	archiveToolFieldLimit  = 64 << 10
	archiveMessageBudget   = 8 << 20
	archivePartsPerMessage = 2048
)

var (
	ErrArchiveClosed       = errors.New("the archive is closed")
	ErrArchiveBusy         = errors.New("the archive write queue is full")
	ErrArchivePaused       = errors.New("archive capture is paused because free disk space is low")
	ErrArchiveBlobTooLarge = errors.New("the file is too large to archive")
	errArchiveInvalid      = errors.New("invalid archive record")
	errArchiveUnknownChat  = errors.New("the chat is not in the archive")
	errArchiveLogActive    = errors.New("the terminal is still running")
	// errArchiveSkipped marks a write that was intentionally not applied,
	// such as a message for a deleted chat.
	errArchiveSkipped = errors.New("archive write skipped")
)

const archiveWriterDSN = "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(1)&_txlock=immediate"
const archiveReaderDSN = "?_pragma=busy_timeout(5000)&_pragma=query_only(1)"

// OpenArchive opens or creates the archive in directory, migrates its schema
// and starts the writer. Close stops the writer after committing every
// queued write.
func OpenArchive(directory string, options ArchiveOptions) (*Archive, error) {
	directory = filepath.Clean(directory)
	// The SQLite driver reads everything after the first '?' as options.
	if strings.ContainsRune(directory, '?') {
		return nil, errors.New("the archive path must not contain '?'")
	}
	if err := ensureArchiveDirectory(directory); err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "archive.db")
	if err := prepareArchiveDatabase(path); err != nil {
		return nil, err
	}
	a := &Archive{
		directory:   directory,
		now:         time.Now,
		freeSpace:   archiveFreeSpace,
		batchDelay:  archiveBatchDelay,
		enqueueWait: archiveEnqueueWait,
		keyed:       map[string]*archiveOp{},
		room:        make(chan struct{}),
		logs:        map[string]*TerminalLog{},
		wake:        make(chan struct{}, 1),
		urgent:      make(chan struct{}, 1),
		closing:     make(chan struct{}),
		writerDone:  make(chan struct{}),
		feed:        make(chan struct{}),
	}
	if options.Now != nil {
		a.now = options.Now
	}
	if options.FreeSpace != nil {
		a.freeSpace = options.FreeSpace
	}
	if options.BatchDelay > 0 {
		a.batchDelay = options.BatchDelay
	}
	if err := a.openDatabases(path); err != nil {
		a.closeDatabases()
		return nil, err
	}
	a.checkFreeSpace()
	go a.writeLoop()
	return a, nil
}

func (a *Archive) openDatabases(path string) error {
	var err error
	if a.writeDB, err = sql.Open("sqlite", path+archiveWriterDSN); err != nil {
		return err
	}
	// Only the writer goroutine uses this connection once the archive is open.
	a.writeDB.SetMaxOpenConns(1)
	a.writeDB.SetMaxIdleConns(1)
	a.writeDB.SetConnMaxLifetime(0)
	a.writeDB.SetConnMaxIdleTime(0)
	var mode string
	if err = a.writeDB.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil {
		return err
	}
	if mode != "wal" {
		return fmt.Errorf("the archive database is in %q journal mode, not WAL", mode)
	}
	if err = migrateArchive(a.writeDB, archiveRandomID(8), a.now().UnixMilli()); err != nil {
		return err
	}
	if err = a.writeDB.QueryRow(`SELECT archive_epoch FROM meta WHERE id = 1`).Scan(&a.epoch); err != nil {
		return err
	}
	if err = validateArchiveSidecars(path); err != nil {
		return err
	}
	// Logs left running are the host's to settle once it knows which
	// terminals the keeper still holds (terminal_restore.go).
	if a.readDB, err = sql.Open("sqlite", path+archiveReaderDSN); err != nil {
		return err
	}
	a.readDB.SetMaxOpenConns(archiveReadConnections)
	a.readDB.SetMaxIdleConns(archiveReadConnections)
	a.readDB.SetConnMaxIdleTime(5 * time.Minute)
	return a.readDB.Ping()
}

func (a *Archive) closeDatabases() error {
	var errs []error
	if a.readDB != nil {
		errs = append(errs, a.readDB.Close())
	}
	if a.writeDB != nil {
		errs = append(errs, a.writeDB.Close())
	}
	return errors.Join(errs...)
}

// Close detaches terminal logs that are still open (their terminals keep
// running in the keeper, and the next host resumes them), commits every
// queued write, stops the writer and closes the database. It is safe to call
// more than once.
func (a *Archive) Close() error {
	var err error
	a.closeOnce.Do(func() {
		for _, log := range a.openLogs() {
			log.Detach()
		}
		a.mu.Lock()
		a.closed = true
		a.mu.Unlock()
		close(a.closing)
		<-a.writerDone
		_, _ = a.writeDB.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
		err = a.closeDatabases()
	})
	return err
}

// ensureArchiveDirectory applies the private state-directory rules (no
// symlink, not group- or world-writable) plus ownership, then sets 0700.
func ensureArchiveDirectory(directory string) error {
	if err := ensurePrivateStateDirectory(filepath.Join(directory, "archive.db")); err != nil {
		return err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return err
	}
	if err := requireArchiveOwner(directory, info); err != nil {
		return err
	}
	return os.Chmod(directory, 0700)
}

// ensureTree creates or checks each directory below the archive directory,
// one level at a time, so no component can be a symlink.
func (a *Archive) ensureTree(parts ...string) (string, error) {
	current := a.directory
	for _, part := range parts {
		current = filepath.Join(current, part)
		if err := ensurePrivateStateDirectory(filepath.Join(current, "entry")); err != nil {
			return "", err
		}
	}
	return current, nil
}

// prepareArchiveDatabase creates archive.db as an empty 0600 file before
// SQLite opens it, or checks the existing one.
func prepareArchiveDatabase(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		file, err := createArchiveFile(path, os.O_WRONLY)
		if err != nil {
			return err
		}
		return file.Close()
	}
	if err != nil {
		return err
	}
	if err := validateArchiveFile(path, info); err != nil {
		return err
	}
	return validateArchiveSidecars(path)
}

func validateArchiveSidecars(path string) error {
	for _, suffix := range []string{"-wal", "-shm"} {
		info, err := os.Lstat(path + suffix)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if err := validateArchiveSidecar(path+suffix, info); err != nil {
			return err
		}
	}
	return nil
}

func archiveRandomID(size int) string {
	data := make([]byte, size)
	_, _ = rand.Read(data) // crypto/rand.Read does not fail on supported platforms
	return hex.EncodeToString(data)
}

// Writer.

type archiveOp struct {
	// key coalesces queued writes that fully replace the same record (message
	// snapshots, terminal log sizes): a newer write replaces the queued one in
	// place. Empty keys never coalesce.
	key   string
	apply func(*archiveTx) error
	// done receives the result for a caller that waits.
	done chan error
}

// archiveTx is one batch transaction. Each operation runs inside a savepoint,
// so one bad record does not undo the rest of the batch.
type archiveTx struct {
	tx    *sql.Tx
	stmts map[string]*sql.Stmt
	now   int64
	// after holds the current operation's file removals, run after commit.
	after []func()
	// gc asks for a blob collection at the end of the batch.
	gc bool
	// changed says the batch recorded a change for the change feed.
	changed bool
}

func (t *archiveTx) stmt(query string) (*sql.Stmt, error) {
	if statement := t.stmts[query]; statement != nil {
		return statement, nil
	}
	statement, err := t.tx.Prepare(query)
	if err != nil {
		return nil, err
	}
	t.stmts[query] = statement
	return statement, nil
}

func (t *archiveTx) exec(query string, args ...any) (sql.Result, error) {
	statement, err := t.stmt(query)
	if err != nil {
		return nil, err
	}
	return statement.Exec(args...)
}

func (t *archiveTx) queryRow(query string, args ...any) *sql.Row {
	statement, err := t.stmt(query)
	if err != nil {
		return t.tx.QueryRow(query, args...)
	}
	return statement.QueryRow(args...)
}

func notifyArchive(channel chan struct{}) {
	select {
	case channel <- struct{}{}:
	default:
	}
}

// submit queues an operation. When the queue is full it waits up to five
// seconds for the writer to take a batch, then reports ErrArchiveBusy.
func (a *Archive) submit(op *archiveOp) error {
	deadline := time.Now().Add(a.enqueueWait)
	coalesce := op.key != "" && op.done == nil
	a.mu.Lock()
	for {
		if a.closed {
			a.mu.Unlock()
			return ErrArchiveClosed
		}
		if queued := a.keyed[op.key]; coalesce && queued != nil {
			queued.apply = op.apply
			a.mu.Unlock()
			return nil
		}
		if len(a.pending) < archiveQueueCapacity {
			break
		}
		room := a.room
		a.mu.Unlock()
		wait := time.Until(deadline)
		if wait <= 0 {
			return ErrArchiveBusy
		}
		timer := time.NewTimer(wait)
		select {
		case <-room:
		case <-timer.C:
		case <-a.closing:
		}
		timer.Stop()
		a.mu.Lock()
	}
	a.pending = append(a.pending, op)
	if coalesce {
		a.keyed[op.key] = op
	}
	a.mu.Unlock()
	notifyArchive(a.wake)
	if op.done != nil {
		notifyArchive(a.urgent)
	}
	return nil
}

// do runs apply in the writer and waits for its commit.
func (a *Archive) do(apply func(*archiveTx) error) error {
	op := &archiveOp{apply: apply, done: make(chan error, 1)}
	if err := a.submit(op); err != nil {
		return err
	}
	return <-op.done
}

// Flush waits until every write queued before it is committed.
func (a *Archive) Flush(ctx context.Context) error {
	op := &archiveOp{apply: func(*archiveTx) error { return nil }, done: make(chan error, 1)}
	if err := a.submit(op); err != nil {
		return err
	}
	select {
	case err := <-op.done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (a *Archive) writeLoop() {
	defer close(a.writerDone)
	for {
		select {
		case <-a.wake:
		case <-a.closing:
			a.writePending()
			return
		}
		timer := time.NewTimer(a.batchDelay)
		select {
		case <-timer.C:
		case <-a.urgent:
		case <-a.closing:
		}
		timer.Stop()
		a.writePending()
	}
}

func (a *Archive) writePending() {
	a.mu.Lock()
	ops := a.pending
	a.pending = nil
	a.keyed = map[string]*archiveOp{}
	close(a.room)
	a.room = make(chan struct{})
	a.mu.Unlock()
	if len(ops) > 0 {
		a.commit(ops)
	}
}

// commit applies one batch in a single transaction and reports each result.
func (a *Archive) commit(ops []*archiveOp) {
	results := make([]error, len(ops))
	afters := make([][]func(), len(ops))
	var removed []string
	changed := false
	err := func() error {
		tx, err := a.writeDB.Begin()
		if err != nil {
			return err
		}
		t := &archiveTx{tx: tx, stmts: map[string]*sql.Stmt{}, now: a.now().UnixMilli()}
		for index, op := range ops {
			if _, err := tx.Exec(`SAVEPOINT archive_op`); err != nil {
				_ = tx.Rollback()
				return err
			}
			t.after = nil
			results[index] = op.apply(t)
			if results[index] != nil {
				if _, err := tx.Exec(`ROLLBACK TO archive_op`); err != nil {
					_ = tx.Rollback()
					return err
				}
			} else {
				afters[index] = t.after
			}
			if _, err := tx.Exec(`RELEASE archive_op`); err != nil {
				_ = tx.Rollback()
				return err
			}
		}
		if t.gc {
			removed = a.collectBlobs(t)
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		changed = t.changed
		return nil
	}()
	if err != nil {
		removed = nil
		for index := range results {
			if results[index] == nil {
				results[index] = err
			}
			afters[index] = nil
		}
	}
	a.batches.Add(1)
	if changed {
		a.signalChanges()
	}
	for _, sum := range removed {
		_ = os.Remove(a.blobPath(sum))
	}
	for index, op := range ops {
		for _, after := range afters[index] {
			after()
		}
		result := results[index]
		if errors.Is(result, errArchiveSkipped) {
			result = nil
		}
		if op.done != nil {
			op.done <- result
		} else if result != nil {
			a.recordFailure(result)
		}
	}
}

// changeSignal returns a channel that closes once a later batch commits a
// change. Take it before reading the feed, so no change falls in between.
func (a *Archive) changeSignal() <-chan struct{} {
	a.feedMu.Lock()
	defer a.feedMu.Unlock()
	return a.feed
}

func (a *Archive) signalChanges() {
	a.feedMu.Lock()
	close(a.feed)
	a.feed = make(chan struct{})
	a.feedMu.Unlock()
}

func (a *Archive) recordFailure(err error) {
	a.failures.Add(1)
	a.mu.Lock()
	a.lastErr = err.Error()
	a.mu.Unlock()
}

// collectBlobs removes blob rows that nothing references: at once after their
// last reference went, or 24 hours after a store that was never referenced.
// The files are removed after the commit.
func (a *Archive) collectBlobs(t *archiveTx) []string {
	if _, err := t.tx.Exec(`SAVEPOINT archive_gc`); err != nil {
		a.recordFailure(err)
		return nil
	}
	cutoff := t.now - archiveBlobGrace.Milliseconds()
	var removed []string
	err := func() error {
		rows, err := t.tx.Query(`SELECT sha256 FROM blobs WHERE refcount <= 0 AND (released_at IS NOT NULL OR created_at < ?) LIMIT 1000`, cutoff)
		if err != nil {
			return err
		}
		for rows.Next() {
			var sum string
			if err := rows.Scan(&sum); err != nil {
				rows.Close()
				return err
			}
			removed = append(removed, sum)
		}
		if err := rows.Close(); err != nil {
			return err
		}
		for _, sum := range removed {
			if _, err := t.exec(`DELETE FROM blobs WHERE sha256 = ?`, sum); err != nil {
				return err
			}
		}
		return nil
	}()
	if err != nil {
		_, _ = t.tx.Exec(`ROLLBACK TO archive_gc`)
		_, _ = t.tx.Exec(`RELEASE archive_gc`)
		a.recordFailure(err)
		return nil
	}
	if _, err := t.tx.Exec(`RELEASE archive_gc`); err != nil {
		a.recordFailure(err)
		return nil
	}
	return removed
}

// maintain runs from the host's maintenance loop: it rechecks free space,
// writes buffered terminal output and schedules the hourly blob collection.
func (a *Archive) maintain() {
	a.checkFreeSpace()
	a.flushTerminalLogs()
	now := a.now()
	a.mu.Lock()
	due := !now.Before(a.gcAt)
	if due {
		a.gcAt = now.Add(archiveGCInterval)
	}
	a.mu.Unlock()
	if due {
		_ = a.submit(&archiveOp{key: "gc", apply: func(t *archiveTx) error { t.gc = true; return nil }})
	}
}

// checkFreeSpace pauses terminal output and attachment bytes below 2 GiB
// free, chat text below 256 MiB, and resumes each above its floor. An unknown
// amount never pauses capture.
func (a *Archive) checkFreeSpace() {
	free, err := a.freeSpace(a.directory)
	if err != nil {
		a.freeBytes.Store(-1)
		a.paused.Store(false)
		a.chatPaused.Store(false)
		return
	}
	a.freeBytes.Store(int64(min(free, math.MaxInt64)))
	a.paused.Store(free < archiveMinimumFree)
	a.chatPaused.Store(free < archiveChatMinimumFree)
}

// chatWritesPaused counts and reports a chat write refused for low disk space.
func (a *Archive) chatWritesPaused() bool {
	if a.chatPaused.Load() {
		a.skipped.Add(1)
		return true
	}
	return false
}

// Records callers write.

// ArchiveChat is one chat's metadata. ProjectID and Provider are fixed by the
// first write. Later writes replace the other fields, except that a field left
// empty keeps its stored value, CreatedAt only moves earlier and UpdatedAt
// only later. A zero time is filled in by the writer: the stored value for a
// known chat, the time of the write for a new one. ParentID and Relation
// ("continue" for a chat continued from another) link a chat to its source.
// TitleSource and TitleBasis (chat names, chat_title.go) go with Title: a
// write with a source replaces all three (an empty basis clears the stored
// one); a write without one that changes the title stores the source the
// title implies and no basis, and otherwise keeps both.
type ArchiveChat struct {
	ID, ProjectID, Provider    string
	Title, Model, Mode, Effort string
	TitleSource, TitleBasis    string
	ParentID, Relation         string
	CreatedAt, UpdatedAt       time.Time
}

// ArchiveMessage is a full snapshot of one message. Parts are kept in slice
// order. CompletedAt is zero while the message streams. A zero CreatedAt keeps
// the stored creation time (the write's time for a new message), so a record
// without times can be written again without changing anything. Attachment
// bytes stay with their message until it is deleted: an attachment part
// without SHA256 takes the blob its stored copy had for an attachment of the
// same name, and stored attachments with bytes that a snapshot leaves out
// are kept. Providers never return file contents, so a later snapshot of a
// sent message must not drop the archived bytes.
type ArchiveMessage struct {
	ID, ChatID, TurnID      string
	Role                    string // user | assistant
	Status                  string // streaming | complete | error | aborted
	Model                   string
	Ord                     int64
	CreatedAt, CompletedAt  time.Time
	Usage                   *ArchiveUsage
	ErrorCode, ErrorMessage string
	Hidden                  bool // rewound: kept, but hidden in the chat
	Parts                   []ArchivePart
}

type ArchiveUsage struct {
	Input, Output, Reasoning, CacheRead, CacheWrite int64
	CostMicros                                      *int64
}

// ArchivePart is one ordered piece of a message. Kind is text, reasoning,
// tool, attachment, patch, notice or context.
type ArchivePart struct {
	ID, Kind, Text string
	Tool           *ArchiveTool
	Attachment     *ArchiveAttachment
	Start, End     time.Time
	Truncated      bool
}

// ArchiveTool fields beyond 64 KiB are cut and marked Truncated. Plain
// chats' sources and memory entry (plain_chat_results.go) are kept with the
// part; a tool without them encodes as before, so an identical rewrite of a
// message from before them is still skipped.
type ArchiveTool struct {
	Name, CallID, Status, Title string
	Input, Output, Error        string
	Truncated                   bool
	ChatToolResults
}

// ArchiveAttachment is display metadata; SHA256 comes from StoreBlob and is
// empty when the file's bytes were not kept.
type ArchiveAttachment struct {
	Name, MIME string
	Size       int64
	SHA256     string
}

// ArchiveInteraction records how an approval or question ended. It has no
// field for answers on purpose: secret answers are never stored.
type ArchiveInteraction struct {
	ID, ChatID            string
	Kind                  string // permission | question
	Outcome               string // once | always | reject | answered | rejected | expired
	Summary               string // the tool or question, never an answer
	CreatedAt, ResolvedAt time.Time
}

var (
	archiveRoles         = map[string]bool{"user": true, "assistant": true}
	archiveStatuses      = map[string]bool{"streaming": true, "complete": true, "error": true, "aborted": true}
	archivePartKinds     = map[string]bool{"text": true, "reasoning": true, "tool": true, "attachment": true, "patch": true, "notice": true, "context": true}
	archiveToolStatuses  = map[string]bool{"pending": true, "running": true, "completed": true, "error": true}
	archiveInteractKinds = map[string]bool{"permission": true, "question": true}
	archiveOutcomes      = map[string]bool{"": true, "once": true, "always": true, "reject": true, "answered": true, "rejected": true, "expired": true}
)

func archiveInvalid(field string) error { return fmt.Errorf("%w: %s", errArchiveInvalid, field) }

// archiveCheckID accepts a nonempty, printable identifier of at most 256 bytes.
func archiveCheckID(field, value string) error {
	if value == "" || len(value) > archiveIDLimit || !utf8.ValidString(value) || strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return archiveInvalid(field)
	}
	return nil
}

// archiveClip returns valid UTF-8 of at most limit bytes, cut at a character
// boundary, and whether anything was cut.
func archiveClip(value string, limit int) (string, bool) {
	value = strings.ToValidUTF8(value, "�")
	if len(value) <= limit {
		return value, false
	}
	if limit <= 0 {
		return "", value != ""
	}
	end := limit
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end], true
}

// archiveLabel is a one-line display string: controls become spaces.
func archiveLabel(value string, limit int) string {
	value, _ = archiveClip(value, limit)
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, value))
}

func archiveMillis(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UnixMilli()
}

func archiveTime(t time.Time) time.Time {
	if t.IsZero() {
		return time.Time{}
	}
	return time.UnixMilli(t.UnixMilli()).UTC()
}

func (a *Archive) normalizeChat(chat ArchiveChat) (ArchiveChat, error) {
	for _, field := range []struct{ name, value string }{{"chat id", chat.ID}, {"project id", chat.ProjectID}} {
		if err := archiveCheckID(field.name, field.value); err != nil {
			return ArchiveChat{}, err
		}
	}
	chat.Provider = archiveLabel(chat.Provider, archiveLabelLimit)
	if chat.Provider == "" {
		return ArchiveChat{}, archiveInvalid("provider")
	}
	if chat.ParentID != "" {
		if err := archiveCheckID("parent id", chat.ParentID); err != nil {
			return ArchiveChat{}, err
		}
	}
	chat.Relation = archiveLabel(chat.Relation, archiveLabelLimit)
	chat.Title = archiveLabel(chat.Title, archiveTitleLimit)
	switch chat.TitleSource {
	case "", titleDefault, titleProvider, titleAuto, titleDevice:
	default:
		return ArchiveChat{}, archiveInvalid("title source")
	}
	if chat.TitleSource == "" {
		chat.TitleBasis = ""
	}
	chat.TitleBasis = archiveLabel(chat.TitleBasis, archiveLabelLimit)
	chat.Model = archiveLabel(chat.Model, archiveLabelLimit)
	chat.Mode = archiveLabel(chat.Mode, archiveLabelLimit)
	chat.Effort = archiveLabel(chat.Effort, archiveLabelLimit)
	// Zero times stay zero for the writer to fill in (see ArchiveChat).
	if chat.UpdatedAt.IsZero() {
		chat.UpdatedAt = chat.CreatedAt
	}
	chat.CreatedAt, chat.UpdatedAt = archiveTime(chat.CreatedAt), archiveTime(chat.UpdatedAt)
	return chat, nil
}

// archiveMessageRecord is a validated, bounded message ready for the writer.
type archiveMessageRecord struct {
	ArchiveMessage
	searchText string
	digest     string
}

// normalizeMessage validates a snapshot and bounds it: text parts at 2 MiB,
// tool fields at 64 KiB, 8 MiB for the whole message and 2048 parts. Cut
// fields are marked truncated.
func (a *Archive) normalizeMessage(message ArchiveMessage) (archiveMessageRecord, error) {
	for _, field := range []struct{ name, value string }{{"message id", message.ID}, {"chat id", message.ChatID}} {
		if err := archiveCheckID(field.name, field.value); err != nil {
			return archiveMessageRecord{}, err
		}
	}
	if message.TurnID != "" {
		if err := archiveCheckID("turn id", message.TurnID); err != nil {
			return archiveMessageRecord{}, err
		}
	}
	if !archiveRoles[message.Role] {
		return archiveMessageRecord{}, archiveInvalid("role")
	}
	if !archiveStatuses[message.Status] {
		return archiveMessageRecord{}, archiveInvalid("status")
	}
	message.Model = archiveLabel(message.Model, archiveLabelLimit)
	message.ErrorCode = archiveLabel(message.ErrorCode, archiveLabelLimit)
	message.ErrorMessage, _ = archiveClip(message.ErrorMessage, archiveErrorLimit)
	// A zero CreatedAt stays zero for the writer (see ArchiveMessage), so the
	// digest of a record without times does not depend on when it is written.
	message.CreatedAt, message.CompletedAt = archiveTime(message.CreatedAt), archiveTime(message.CompletedAt)
	if message.Usage != nil {
		usage := *message.Usage
		if usage.CostMicros != nil {
			cost := *usage.CostMicros
			usage.CostMicros = &cost
		}
		message.Usage = &usage
	}
	budget := archiveMessageBudget
	clip := func(value string, limit int) (string, bool) {
		clipped, cut := archiveClip(value, min(limit, budget))
		budget -= len(clipped)
		return clipped, cut
	}
	source := message.Parts
	omitted := 0
	if len(source) > archivePartsPerMessage {
		omitted = len(source) - (archivePartsPerMessage - 1)
		source = source[:archivePartsPerMessage-1]
	}
	parts := make([]ArchivePart, 0, len(source)+1)
	var search strings.Builder
	for index, part := range source {
		if part.ID == "" {
			part.ID = fmt.Sprintf("part-%d", index)
		}
		if err := archiveCheckID("part id", part.ID); err != nil {
			return archiveMessageRecord{}, err
		}
		if !archivePartKinds[part.Kind] {
			return archiveMessageRecord{}, archiveInvalid("part kind")
		}
		var cut bool
		part.Text, cut = clip(part.Text, archivePartTextLimit)
		part.Truncated = part.Truncated || cut
		part.Start, part.End = archiveTime(part.Start), archiveTime(part.End)
		if part.Tool != nil {
			tool := *part.Tool
			if tool.Status == "" {
				tool.Status = "pending"
			}
			if !archiveToolStatuses[tool.Status] {
				return archiveMessageRecord{}, archiveInvalid("tool status")
			}
			tool.Name = archiveLabel(tool.Name, archiveLabelLimit)
			tool.CallID = archiveLabel(tool.CallID, archiveLabelLimit)
			tool.Title = archiveLabel(tool.Title, archiveTitleLimit)
			var inputCut, outputCut, errorCut bool
			tool.Input, inputCut = clip(tool.Input, archiveToolFieldLimit)
			tool.Output, outputCut = clip(tool.Output, archiveToolFieldLimit)
			tool.Error, errorCut = clip(tool.Error, archiveToolFieldLimit)
			tool.Truncated = tool.Truncated || inputCut || outputCut || errorCut
			tool.ChatToolResults = archiveToolResults(tool.ChatToolResults)
			part.Tool = &tool
		}
		if part.Attachment != nil {
			attachment := *part.Attachment
			attachment.Name = archiveLabel(attachment.Name, archiveLabelLimit)
			attachment.MIME = archiveLabel(attachment.MIME, archiveLabelLimit)
			if attachment.Size < 0 {
				attachment.Size = 0
			}
			if attachment.SHA256 != "" && !archiveValidSHA(attachment.SHA256) {
				return archiveMessageRecord{}, archiveInvalid("attachment sha256")
			}
			part.Attachment = &attachment
		}
		if part.Kind == "text" && part.Text != "" {
			if search.Len() > 0 {
				search.WriteString("\n\n")
			}
			search.WriteString(part.Text)
		}
		parts = append(parts, part)
	}
	if omitted > 0 {
		parts = append(parts, ArchivePart{ID: "agentland-omitted-parts", Kind: "notice", Text: fmt.Sprintf("%d more parts were not archived", omitted)})
	}
	message.Parts = parts
	// U+0002 and U+0003 mark matches in search snippets, so the index never
	// contains them.
	searchText, _ := archiveClip(strings.NewReplacer("\x02", "", "\x03", "").Replace(search.String()), archiveSearchTextLimit)
	encoded, err := json.Marshal(message)
	if err != nil {
		return archiveMessageRecord{}, err
	}
	sum := sha256.Sum256(encoded)
	return archiveMessageRecord{ArchiveMessage: message, searchText: searchText, digest: hex.EncodeToString(sum[:])}, nil
}

func archiveValidSHA(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

// UpsertChat queues a chat's metadata. An identical rewrite changes nothing.
func (a *Archive) UpsertChat(chat ArchiveChat) error {
	chat, err := a.normalizeChat(chat)
	if err != nil {
		return err
	}
	if a.chatWritesPaused() {
		return ErrArchivePaused
	}
	// Chat writes are not coalesced: the first one fixes the project, the
	// provider and the earliest creation time.
	return a.submit(&archiveOp{apply: func(t *archiveTx) error { return t.upsertChat(chat) }})
}

// UpsertMessage queues a full snapshot of a message. A queued snapshot of the
// same message is replaced, and an identical rewrite changes nothing. The
// chat must have been written first.
func (a *Archive) UpsertMessage(message ArchiveMessage) error {
	record, err := a.normalizeMessage(message)
	if err != nil {
		return err
	}
	if a.chatWritesPaused() {
		return ErrArchivePaused
	}
	return a.submit(&archiveOp{key: "message\x00" + record.ChatID + "\x00" + record.ID, apply: func(t *archiveTx) error {
		_, err := t.upsertMessage(record)
		return err
	}})
}

// importChat writes a chat and a batch of its messages in one transaction and
// waits for the commit. It reports how many messages were new or changed, so
// a repeated import reports zero. With keepExisting, messages the archive
// already holds are left as they are. A deleted chat is skipped; messages
// that fail validation are counted as write errors and left out.
func (a *Archive) importChat(chat ArchiveChat, messages []ArchiveMessage, keepExisting bool) (int, error) {
	chat, err := a.normalizeChat(chat)
	if err != nil {
		return 0, err
	}
	records := make([]archiveMessageRecord, 0, len(messages))
	for _, message := range messages {
		record, err := a.normalizeMessage(message)
		if err != nil {
			a.recordFailure(fmt.Errorf("import message %q: %w", message.ID, err))
			continue
		}
		records = append(records, record)
	}
	if a.chatWritesPaused() {
		return 0, ErrArchivePaused
	}
	changed := 0
	err = a.do(func(t *archiveTx) error {
		changed = 0
		if err := t.upsertChat(chat); err != nil {
			return err
		}
		for _, record := range records {
			if keepExisting {
				var count int
				if err := t.queryRow(`SELECT count(*) FROM messages WHERE chat_id = ? AND id = ?`, record.ChatID, record.ID).Scan(&count); err != nil {
					return err
				}
				if count > 0 {
					continue
				}
			}
			did, err := t.upsertMessage(record)
			if err != nil {
				return err
			}
			if did {
				changed++
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return changed, nil
}

// DeleteMessage removes one message and leaves a tombstone in the change
// feed. It waits for the commit; an unknown message or chat is not an error.
// Deleting frees space, so it is never paused.
func (a *Archive) DeleteMessage(chatID, messageID string) error {
	if archiveCheckID("chat id", chatID) != nil || archiveCheckID("message id", messageID) != nil {
		return nil
	}
	return a.do(func(t *archiveTx) error {
		project, err := t.chatProject(chatID)
		if errors.Is(err, errArchiveSkipped) || errors.Is(err, errArchiveUnknownChat) {
			return nil
		}
		if err != nil {
			return err
		}
		var pk int64
		err = t.queryRow(`SELECT pk FROM messages WHERE chat_id = ? AND id = ?`, chatID, messageID).Scan(&pk)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		for _, statement := range []string{`DELETE FROM parts WHERE message_pk = ?`, `DELETE FROM messages WHERE pk = ?`} {
			if _, err := t.exec(statement, pk); err != nil {
				return err
			}
		}
		t.gc = true
		return t.recordChange("message", messageID, chatID, project, "delete")
	})
}

// HideMessagesFrom queues marking a chat's messages from messageID on (in
// order) as hidden, as a rewind hides them. A later snapshot of one of them
// shows it again, as a restore does. Nothing happens when the message is not
// archived.
func (a *Archive) HideMessagesFrom(chatID, messageID string) error {
	for _, field := range []struct{ name, value string }{{"chat id", chatID}, {"message id", messageID}} {
		if err := archiveCheckID(field.name, field.value); err != nil {
			return err
		}
	}
	if a.chatWritesPaused() {
		return ErrArchivePaused
	}
	return a.submit(&archiveOp{apply: func(t *archiveTx) error { return t.hideMessagesFrom(chatID, messageID) }})
}

// RecordInteraction queues the outcome of an approval or question.
func (a *Archive) RecordInteraction(interaction ArchiveInteraction) error {
	for _, field := range []struct{ name, value string }{{"interaction id", interaction.ID}, {"chat id", interaction.ChatID}} {
		if err := archiveCheckID(field.name, field.value); err != nil {
			return err
		}
	}
	if !archiveInteractKinds[interaction.Kind] {
		return archiveInvalid("interaction kind")
	}
	if !archiveOutcomes[interaction.Outcome] {
		return archiveInvalid("interaction outcome")
	}
	interaction.Summary = archiveLabel(interaction.Summary, archiveSummaryLimit)
	if interaction.CreatedAt.IsZero() {
		interaction.CreatedAt = a.now()
	}
	interaction.CreatedAt, interaction.ResolvedAt = archiveTime(interaction.CreatedAt), archiveTime(interaction.ResolvedAt)
	if a.chatWritesPaused() {
		return ErrArchivePaused
	}
	return a.submit(&archiveOp{apply: func(t *archiveTx) error { return t.recordInteraction(interaction) }})
}

// DeleteChat removes a chat with its messages, parts and interactions,
// releases its attachments and leaves a tombstone in the change feed. It
// waits for the commit; deleting a deleted chat succeeds, an unknown chat
// returns ErrNotFound.
func (a *Archive) DeleteChat(chatID string) error {
	if err := archiveCheckID("chat id", chatID); err != nil {
		return ErrNotFound
	}
	return a.do(func(t *archiveTx) error { return t.deleteChat(chatID) })
}

// StoreBlob copies an attachment into the archive (up to 64 MiB) and returns
// its SHA-256 for ArchiveAttachment.SHA256. Identical content is stored once.
// A blob that no message references is removed after 24 hours.
func (a *Archive) StoreBlob(r io.Reader, mimeType string) (string, error) {
	mimeType = archiveLabel(mimeType, archiveLabelLimit)
	if a.paused.Load() {
		a.skipped.Add(1)
		return "", ErrArchivePaused
	}
	directory, err := a.ensureTree("blobs")
	if err != nil {
		return "", err
	}
	incoming := filepath.Join(directory, ".incoming-"+archiveRandomID(12))
	file, err := createArchiveFile(incoming, os.O_WRONLY)
	if err != nil {
		return "", err
	}
	digest := sha256.New()
	size, err := io.Copy(io.MultiWriter(file, digest), io.LimitReader(r, archiveBlobLimit+1))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err == nil && size > archiveBlobLimit {
		err = ErrArchiveBlobTooLarge
	}
	if err != nil {
		_ = os.Remove(incoming)
		return "", err
	}
	sum := hex.EncodeToString(digest.Sum(nil))
	err = a.do(func(t *archiveTx) error {
		// The rename runs in the writer, so it cannot race the collection of
		// a released blob with the same content.
		if _, err := a.ensureTree("blobs", sum[:2]); err != nil {
			return err
		}
		if err := os.Rename(incoming, a.blobPath(sum)); err != nil {
			return err
		}
		_, err := t.exec(`INSERT INTO blobs (sha256, size, mime, refcount, created_at) VALUES (?, ?, ?, 0, ?)
			ON CONFLICT (sha256) DO UPDATE SET released_at = NULL, created_at = excluded.created_at`, sum, size, mimeType, t.now)
		return err
	})
	if err != nil {
		_ = os.Remove(incoming)
		return "", err
	}
	return sum, nil
}

func (a *Archive) blobPath(sum string) string {
	return filepath.Join(a.directory, "blobs", sum[:2], sum)
}

// Writer-side record operations.

// chatProject returns the chat's project. A deleted chat reports
// errArchiveSkipped and an unknown chat errArchiveUnknownChat.
func (t *archiveTx) chatProject(chatID string) (string, error) {
	var project string
	err := t.queryRow(`SELECT project_id FROM chats WHERE id = ?`, chatID).Scan(&project)
	if err == nil {
		return project, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	deleted, err := t.chatDeleted(chatID)
	if err != nil {
		return "", err
	}
	if deleted {
		return "", errArchiveSkipped
	}
	return "", errArchiveUnknownChat
}

func (t *archiveTx) chatDeleted(chatID string) (bool, error) {
	var count int
	err := t.queryRow(`SELECT count(*) FROM changes WHERE entity = 'chat' AND chat_id = ? AND entity_id = ? AND op = 'delete'`, chatID, chatID).Scan(&count)
	return count > 0, err
}

func (t *archiveTx) recordChange(entity, entityID, chatID, projectID, op string) error {
	_, err := t.exec(`INSERT OR REPLACE INTO changes (entity, entity_id, chat_id, project_id, op, at) VALUES (?, ?, ?, ?, ?, ?)`, entity, entityID, chatID, projectID, op, t.now)
	if err == nil {
		t.changed = true
	}
	return err
}

func (t *archiveTx) upsertChat(chat ArchiveChat) error {
	deleted, err := t.chatDeleted(chat.ID)
	if err != nil {
		return err
	}
	if deleted {
		return errArchiveSkipped
	}
	var stored ArchiveChat
	var storedCreated, storedUpdated int64
	err = t.queryRow(`SELECT project_id, provider, title, title_source, title_basis, model, mode, effort, parent_id, relation, created_at, updated_at FROM chats WHERE id = ?`, chat.ID).
		Scan(&stored.ProjectID, &stored.Provider, &stored.Title, &stored.TitleSource, &stored.TitleBasis, &stored.Model, &stored.Mode, &stored.Effort, &stored.ParentID, &stored.Relation, &storedCreated, &storedUpdated)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// A new chat without times was created now; UpdatedAt is never before
		// CreatedAt.
		created, updated := t.now, t.now
		if !chat.CreatedAt.IsZero() {
			created = chat.CreatedAt.UnixMilli()
			updated = max(created, chat.UpdatedAt.UnixMilli())
		} else if !chat.UpdatedAt.IsZero() {
			created = min(created, chat.UpdatedAt.UnixMilli())
			updated = chat.UpdatedAt.UnixMilli()
		}
		// Chat names: a title written without a source has the one it implies.
		if chat.TitleSource == "" {
			chat.TitleSource = titleSourceFor(chat.Title)
		}
		_, err = t.exec(`INSERT INTO chats (id, project_id, provider, title, title_source, title_basis, model, mode, effort, parent_id, relation, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			chat.ID, chat.ProjectID, chat.Provider, chat.Title, chat.TitleSource, chat.TitleBasis, chat.Model, chat.Mode, chat.Effort, chat.ParentID, chat.Relation, created, updated)
		if err != nil {
			return err
		}
		return t.recordChange("chat", chat.ID, chat.ID, chat.ProjectID, "upsert")
	case err != nil:
		return err
	}
	created, updated := storedCreated, storedUpdated
	if !chat.CreatedAt.IsZero() {
		created = min(storedCreated, chat.CreatedAt.UnixMilli())
	}
	if !chat.UpdatedAt.IsZero() {
		updated = max(storedUpdated, chat.UpdatedAt.UnixMilli())
	}
	next := stored
	for _, field := range []struct {
		stored   *string
		incoming string
	}{
		{&next.Model, chat.Model}, {&next.Mode, chat.Mode}, {&next.Effort, chat.Effort},
		{&next.ParentID, chat.ParentID}, {&next.Relation, chat.Relation},
	} {
		if field.incoming != "" {
			*field.stored = field.incoming
		}
	}
	// Chat names: the title, its source and its basis change together.
	switch {
	case chat.TitleSource != "":
		next.Title, next.TitleSource, next.TitleBasis = chat.Title, chat.TitleSource, chat.TitleBasis
	case chat.Title != "" && chat.Title != stored.Title:
		next.Title, next.TitleSource, next.TitleBasis = chat.Title, titleSourceFor(chat.Title), ""
	}
	if next == stored && created == storedCreated && updated == storedUpdated {
		return nil
	}
	if _, err = t.exec(`UPDATE chats SET title = ?, title_source = ?, title_basis = ?, model = ?, mode = ?, effort = ?, parent_id = ?, relation = ?, created_at = ?, updated_at = ? WHERE id = ?`,
		next.Title, next.TitleSource, next.TitleBasis, next.Model, next.Mode, next.Effort, next.ParentID, next.Relation, created, updated, chat.ID); err != nil {
		return err
	}
	return t.recordChange("chat", chat.ID, chat.ID, stored.ProjectID, "upsert")
}

// upsertMessage writes a message snapshot and reports whether anything
// changed: an identical rewrite (same digest) is skipped.
func (t *archiveTx) upsertMessage(record archiveMessageRecord) (bool, error) {
	project, err := t.chatProject(record.ChatID)
	if err != nil {
		return false, err
	}
	var digest string
	var storedPK, storedCreated int64
	err = t.queryRow(`SELECT pk, digest, created_at FROM messages WHERE chat_id = ? AND id = ?`, record.ChatID, record.ID).Scan(&storedPK, &digest, &storedCreated)
	exists := err == nil
	if exists && digest == record.digest {
		return false, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	created := record.CreatedAt.UnixMilli()
	if record.CreatedAt.IsZero() {
		created = t.now
		if exists {
			created = storedCreated
		}
	}
	parts := record.Parts
	if exists {
		if parts, err = t.keepBlobs(storedPK, parts); err != nil {
			return false, err
		}
	}
	var usage [6]any
	if record.Usage != nil {
		usage = [6]any{record.Usage.Input, record.Usage.Output, record.Usage.Reasoning, record.Usage.CacheRead, record.Usage.CacheWrite, nil}
		if record.Usage.CostMicros != nil {
			usage[5] = *record.Usage.CostMicros
		}
	}
	var pk int64
	err = t.queryRow(`INSERT INTO messages (chat_id, id, ord, turn_id, role, status, model, created_at, completed_at,
			usage_input, usage_output, usage_reasoning, usage_cache_read, usage_cache_write, usage_cost_micros,
			error_code, error_message, hidden, search_text, digest)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (chat_id, id) DO UPDATE SET ord = excluded.ord, turn_id = excluded.turn_id, role = excluded.role,
			status = excluded.status, model = excluded.model, created_at = excluded.created_at, completed_at = excluded.completed_at,
			usage_input = excluded.usage_input, usage_output = excluded.usage_output, usage_reasoning = excluded.usage_reasoning,
			usage_cache_read = excluded.usage_cache_read, usage_cache_write = excluded.usage_cache_write,
			usage_cost_micros = excluded.usage_cost_micros, error_code = excluded.error_code, error_message = excluded.error_message,
			hidden = excluded.hidden, search_text = excluded.search_text, digest = excluded.digest
		RETURNING pk`,
		record.ChatID, record.ID, record.Ord, record.TurnID, record.Role, record.Status, record.Model,
		created, archiveMillis(record.CompletedAt),
		usage[0], usage[1], usage[2], usage[3], usage[4], usage[5],
		record.ErrorCode, record.ErrorMessage, record.Hidden, record.searchText, record.digest).Scan(&pk)
	if err != nil {
		return false, err
	}
	if _, err = t.exec(`DELETE FROM parts WHERE message_pk = ?`, pk); err != nil {
		return false, err
	}
	for ord, part := range parts {
		var toolName any
		var tool ArchiveTool
		if part.Tool != nil {
			tool = *part.Tool
			toolName = tool.Name
		}
		sources, memoryID, memoryText := "", "", ""
		if len(tool.Sources) > 0 {
			encoded, err := json.Marshal(tool.Sources)
			if err != nil {
				return false, err
			}
			sources = string(encoded)
		}
		if tool.Memory != nil {
			memoryID, memoryText = tool.Memory.ID, tool.Memory.Text
		}
		truncated := part.Truncated || tool.Truncated
		var attachmentName, blob any
		var attachment ArchiveAttachment
		if part.Attachment != nil {
			attachment = *part.Attachment
			attachmentName = attachment.Name
			if attachment.SHA256 != "" {
				var count int
				if err := t.queryRow(`SELECT count(*) FROM blobs WHERE sha256 = ?`, attachment.SHA256).Scan(&count); err != nil {
					return false, err
				}
				if count > 0 {
					blob = attachment.SHA256
				}
			}
		}
		if _, err := t.exec(`INSERT INTO parts (message_pk, ord, id, kind, text, tool_name, tool_call_id, tool_status, tool_title,
				tool_input, tool_output, tool_error, truncated, attachment_name, attachment_mime, attachment_size, blob_sha256,
				started_at, ended_at, tool_sources, tool_memory_id, tool_memory_text)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			pk, ord, part.ID, part.Kind, part.Text, toolName, tool.CallID, tool.Status, tool.Title,
			tool.Input, tool.Output, tool.Error, truncated, attachmentName, attachment.MIME, attachment.Size, blob,
			archiveMillis(part.Start), archiveMillis(part.End), sources, memoryID, memoryText); err != nil {
			return false, err
		}
	}
	return true, t.recordChange("message", record.ID, record.ChatID, project, "upsert")
}

// keepBlobs keeps the attachment bytes the stored copy of a message had. An
// attachment part that arrives without a SHA-256 takes the blob (and size)
// of the stored attachment with the same name, matched in order; stored
// attachments with bytes that the snapshot does not name stay after its
// parts. A provider's copy of a sent message never carries file contents
// and may arrive before its parts do. It runs before the stored parts are
// replaced, so the blob's reference count never reaches zero in between.
func (t *archiveTx) keepBlobs(pk int64, parts []ArchivePart) ([]ArchivePart, error) {
	type kept struct {
		part ArchivePart
		used bool
	}
	var stored []kept
	rows, err := t.tx.Query(`SELECT id, attachment_name, attachment_mime, attachment_size, blob_sha256 FROM parts WHERE message_pk = ? AND blob_sha256 IS NOT NULL ORDER BY ord`, pk)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		attachment := &ArchiveAttachment{}
		entry := kept{part: ArchivePart{Kind: "attachment", Attachment: attachment}}
		var name sql.NullString
		if err := rows.Scan(&entry.part.ID, &name, &attachment.MIME, &attachment.Size, &attachment.SHA256); err != nil {
			rows.Close()
			return nil, err
		}
		attachment.Name = name.String
		stored = append(stored, entry)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if len(stored) == 0 {
		return parts, nil
	}
	result := slices.Clone(parts)
	for index := range result {
		attachment := result[index].Attachment
		if attachment == nil {
			continue
		}
		for match := range stored {
			previous := stored[match].part.Attachment
			if stored[match].used || previous.Name != attachment.Name || (attachment.SHA256 != "" && attachment.SHA256 != previous.SHA256) {
				continue
			}
			stored[match].used = true
			merged := *attachment
			merged.SHA256 = previous.SHA256
			if merged.Size == 0 {
				merged.Size = previous.Size
			}
			result[index].Attachment = &merged
			break
		}
	}
	for _, entry := range stored {
		if !entry.used {
			result = append(result, entry.part)
		}
	}
	return result, nil
}

// hideMessagesFrom hides the chat's visible messages ordered at or after the
// given one. Their digests are cleared, so a later snapshot (a restore)
// always writes them again.
func (t *archiveTx) hideMessagesFrom(chatID, messageID string) error {
	project, err := t.chatProject(chatID)
	if errors.Is(err, errArchiveSkipped) || errors.Is(err, errArchiveUnknownChat) {
		return nil
	}
	if err != nil {
		return err
	}
	var ord, pk int64
	err = t.queryRow(`SELECT ord, pk FROM messages WHERE chat_id = ? AND id = ?`, chatID, messageID).Scan(&ord, &pk)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	rows, err := t.tx.Query(`UPDATE messages SET hidden = 1, digest = '' WHERE chat_id = ? AND hidden = 0 AND (ord, pk) >= (?, ?) RETURNING id`, chatID, ord, pk)
	if err != nil {
		return err
	}
	var hidden []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		hidden = append(hidden, id)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, id := range hidden {
		if err := t.recordChange("message", id, chatID, project, "upsert"); err != nil {
			return err
		}
	}
	return nil
}

func (t *archiveTx) recordInteraction(interaction ArchiveInteraction) error {
	if _, err := t.chatProject(interaction.ChatID); err != nil {
		return err
	}
	_, err := t.exec(`INSERT INTO interactions (chat_id, id, kind, outcome, summary, created_at, resolved_at) VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (chat_id, id) DO UPDATE SET kind = excluded.kind, outcome = excluded.outcome, summary = excluded.summary,
			resolved_at = excluded.resolved_at`,
		interaction.ChatID, interaction.ID, interaction.Kind, interaction.Outcome, interaction.Summary,
		interaction.CreatedAt.UnixMilli(), archiveMillis(interaction.ResolvedAt))
	return err
}

func (t *archiveTx) deleteChat(chatID string) error {
	project, err := t.chatProject(chatID)
	if errors.Is(err, errArchiveSkipped) {
		return nil
	}
	if errors.Is(err, errArchiveUnknownChat) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	for _, statement := range []string{
		`DELETE FROM parts WHERE message_pk IN (SELECT pk FROM messages WHERE chat_id = ?)`,
		`DELETE FROM messages WHERE chat_id = ?`,
		`DELETE FROM interactions WHERE chat_id = ?`,
		`DELETE FROM chats WHERE id = ?`,
		`DELETE FROM changes WHERE entity = 'message' AND chat_id = ?`,
	} {
		if _, err := t.exec(statement, chatID); err != nil {
			return err
		}
	}
	t.gc = true
	return t.recordChange("chat", chatID, chatID, project, "delete")
}
