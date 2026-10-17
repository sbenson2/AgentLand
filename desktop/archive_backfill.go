package host

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// Backfill (M1 chunk B2): imports the chats the archive does not hold yet.
// A pass runs when the host starts, in the background:
//
//   - OpenCode: for each configured project, GET /session, then every
//     session updated since the last finished one (in the order of their
//     update times) is paged newest first with GET /session/:id/message
//     (limit, before), with timestamps, model and tokens; file parts keep
//     their name and type only. Messages from a rewind point on are archived
//     hidden, and a reply left streaming in an idle session as aborted.
//   - Claude Code and Codex: <state>.chats.json is read, never written; a
//     message the archive already holds is left to live capture, and records
//     without times get the time of their first import.
//
// It makes about four OpenCode requests a second, waits while any chat in
// the hub runs a turn, and keeps its place in backfill_state (source
// "opencode" or "cli", scope the project ID): the cursor names the last
// session finished and the page of the one in progress, so a restart
// resumes there. Writes skip identical snapshots, so running it again
// changes nothing, and a chat deleted from the archive is never read again.
// A failed pass (OpenCode not reachable yet) is retried every minute, and a
// finished host keeps passing every ten minutes so sessions driven outside
// AgentLand (an OpenCode TUI in a terminal, another client) are archived
// without waiting for the next host start.
const (
	backfillRequestGap       = 250 * time.Millisecond
	backfillEvery            = 10 * time.Minute
	backfillPageSize         = 50
	backfillRetry            = time.Minute
	backfillPausePoll        = 250 * time.Millisecond
	backfillSessionListLimit = 32 << 20
)

type archiveBackfill struct {
	host      *Host
	gap       time.Duration
	retry     time.Duration
	every     time.Duration // between finished passes; zero runs one pass
	pausePoll time.Duration
	pageSize  int
	// afterPage runs after each saved page (tests).
	afterPage func()

	mu          sync.Mutex
	state       string // running, paused, retrying or done
	lastRequest time.Time
	cancel      context.CancelFunc
	finished    chan struct{}
}

func newArchiveBackfill(host *Host) *archiveBackfill {
	return &archiveBackfill{host: host, gap: backfillRequestGap, retry: backfillRetry, every: backfillEvery, pausePoll: backfillPausePoll, pageSize: backfillPageSize}
}

// start runs passes in the background: a failed pass is retried, and a
// finished one runs again after every (or never, when every is zero) until
// stop is called.
func (b *archiveBackfill) start() {
	ctx, cancel := context.WithCancel(context.Background())
	b.mu.Lock()
	b.cancel, b.finished = cancel, make(chan struct{})
	b.mu.Unlock()
	go func() {
		defer close(b.finished)
		for {
			err := b.run(ctx)
			if ctx.Err() != nil {
				return
			}
			wait := b.retry
			if err == nil {
				b.setState("done")
				if b.every <= 0 {
					return
				}
				wait = b.every
			} else {
				b.setState("retrying")
			}
			timer := time.NewTimer(wait)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	}()
}

// stop ends a running pass (its place is kept) and waits for it.
func (b *archiveBackfill) stop() {
	b.mu.Lock()
	cancel, finished := b.cancel, b.finished
	b.mu.Unlock()
	if cancel != nil {
		cancel()
		<-finished
	}
}

func (b *archiveBackfill) setState(state string) {
	b.mu.Lock()
	b.state = state
	b.mu.Unlock()
}

func (b *archiveBackfill) status() string {
	if b == nil {
		return ""
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.state
}

// pauseWhileBusy waits while any chat in the hub runs a turn.
func (b *archiveBackfill) pauseWhileBusy(ctx context.Context) error {
	for b.host.chat.busy() {
		b.setState("paused")
		timer := time.NewTimer(b.pausePoll)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	b.setState("running")
	return ctx.Err()
}

// wait runs before each OpenCode request: it keeps the pace and pauses
// while a chat streams.
func (b *archiveBackfill) wait(ctx context.Context) error {
	for {
		if err := b.pauseWhileBusy(ctx); err != nil {
			return err
		}
		b.mu.Lock()
		delay := time.Until(b.lastRequest.Add(b.gap))
		if delay <= 0 {
			b.lastRequest = time.Now()
			b.mu.Unlock()
			return nil
		}
		b.mu.Unlock()
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

// run is one pass over every configured project.
func (b *archiveBackfill) run(ctx context.Context) error {
	b.setState("running")
	st, err := b.host.store.Read()
	if err != nil {
		return err
	}
	adapter, openCode := b.host.agent.(*OpenCodeAdapter)
	if openCode {
		for _, project := range st.Config.Projects {
			if err := b.openCodeProject(ctx, adapter, project); err != nil {
				return err
			}
		}
	}
	if b.host.cliChats != nil {
		if err := b.cliProjects(ctx, st.Config.Projects); err != nil {
			return err
		}
	}
	// Plain chats: the Chats space's chats come last, once OpenCode has
	// confirmed the chat agent there since the host started, so a Chats space
	// OpenCode cannot serve holds up no workspace's import.
	if openCode && b.host.plainChats.seenOnce() {
		for _, project := range b.host.plainChatProjects() {
			if err := b.openCodeProject(ctx, adapter, project); err != nil {
				return err
			}
		}
	}
	return nil
}

// openCodeCursor is the "opencode" cursor: the last finished session (by
// update time, then ID) and the page to continue the one in progress from.
type openCodeCursor struct {
	AfterUpdated int64  `json:"afterUpdated,omitempty"`
	AfterID      string `json:"afterId,omitempty"`
	Session      string `json:"session,omitempty"`
	Updated      int64  `json:"updated,omitempty"`
	Before       string `json:"before,omitempty"`
}

func (c openCodeCursor) encode() string {
	data, _ := json.Marshal(c)
	return string(data)
}

func (c openCodeCursor) after(updated int64, id string) bool {
	return updated > c.AfterUpdated || (updated == c.AfterUpdated && id > c.AfterID)
}

func (b *archiveBackfill) openCodeProject(ctx context.Context, adapter *OpenCodeAdapter, p Project) error {
	archive := b.host.archive
	row, err := archive.backfillRow(ctx, "opencode", p.ID)
	if err != nil {
		return err
	}
	var cursor openCodeCursor
	_ = json.Unmarshal([]byte(row.cursor), &cursor)
	if err := b.wait(ctx); err != nil {
		return err
	}
	listed, err := adapter.backfillSessions(p)
	if err != nil {
		return err
	}
	var sessions, pending []ocSession
	for _, session := range listed {
		if session.ID != "" && sameDirectory(p.Directory, session.Directory) {
			sessions = append(sessions, session)
		}
	}
	sort.Slice(sessions, func(i, j int) bool {
		left, right := int64(sessions[i].Time.Updated), int64(sessions[j].Time.Updated)
		return left < right || (left == right && sessions[i].ID < sessions[j].ID)
	})
	for _, session := range sessions {
		if cursor.after(int64(session.Time.Updated), session.ID) {
			pending = append(pending, session)
		}
	}
	row.chats, row.chatsDone, row.done = int64(len(sessions)), int64(len(sessions)-len(pending)), len(pending) == 0
	if err := archive.saveBackfillRow(row); err != nil || len(pending) == 0 {
		return err
	}
	if err := b.wait(ctx); err != nil {
		return err
	}
	statuses, err := adapter.sessionStatuses(p)
	if err != nil {
		return err
	}
	for _, session := range pending {
		updated := int64(session.Time.Updated)
		deleted, err := archive.chatDeletedRead(ctx, session.ID)
		if err != nil {
			return err
		}
		if !deleted {
			before := ""
			if cursor.Session == session.ID && cursor.Updated == updated {
				before = cursor.Before
			}
			cursor.Session, cursor.Updated, cursor.Before = session.ID, updated, before
			_, err := b.host.importOpenCodeSession(ctx, adapter, p, session, statuses[session.ID], before, b.pageSize, 0, b.wait, func(next string, changed int) error {
				cursor.Before = next
				row.imported += int64(changed)
				row.cursor = cursor.encode()
				if err := archive.saveBackfillRow(row); err != nil {
					return err
				}
				if b.afterPage != nil {
					b.afterPage()
				}
				return nil
			})
			if err != nil {
				return err
			}
		}
		cursor = openCodeCursor{AfterUpdated: updated, AfterID: session.ID}
		row.cursor = cursor.encode()
		row.chatsDone++
		if err := archive.saveBackfillRow(row); err != nil {
			return err
		}
	}
	row.done = true
	return archive.saveBackfillRow(row)
}

// cliProjects imports the Claude Code and Codex chats of each project from
// the chats file, read only.
func (b *archiveBackfill) cliProjects(ctx context.Context, projects []Project) error {
	archive := b.host.archive
	records := map[string]*cliChatRecord{}
	data, err := readPrivateState(b.host.cliChats.path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &records); err != nil {
			return fmt.Errorf("read the Claude Code and Codex chats: %w", err)
		}
	}
	for _, p := range projects {
		row, err := archive.backfillRow(ctx, "cli", p.ID)
		if err != nil {
			return err
		}
		var ids []string
		for id, record := range records {
			if record != nil && isCLISessionID(id) && record.Session.ID == id && record.Session.ProjectID == p.ID && sameDirectory(record.Directory, p.Directory) {
				ids = append(ids, id)
			}
		}
		sort.Strings(ids)
		imported := 0
		for _, id := range ids {
			if err := b.pauseWhileBusy(ctx); err != nil {
				return err
			}
			if deleted, err := archive.chatDeletedRead(ctx, id); err != nil {
				return err
			} else if deleted {
				continue
			}
			changed, err := b.host.importCLIRecord(ctx, p, *records[id])
			if err != nil {
				return err
			}
			imported += changed
		}
		next := row
		next.chats, next.chatsDone, next.done = int64(len(ids)), int64(len(ids)), true
		next.imported += int64(imported)
		if next != row {
			if err := archive.saveBackfillRow(next); err != nil {
				return err
			}
		}
	}
	return nil
}

// importOpenCodeSession copies one OpenCode session into the archive, a
// page at a time from before (a page cursor; empty for the newest page).
// wait runs before each request; onPage learns the cursor of the next page
// ("" after the last) and how many messages changed. maxPages > 0 bounds it.
func (h *Host) importOpenCodeSession(ctx context.Context, adapter *OpenCodeAdapter, p Project, session ocSession, status ocStatus, before string, pageSize, maxPages int, wait func(context.Context) error, onPage func(next string, changed int) error) (int, error) {
	// Chat names: the host's name for the chat, not OpenCode's placeholder.
	name := h.titles.resolveOpenCode(session.ID, session.Title)
	chat := ArchiveChat{ID: session.ID, ProjectID: p.ID, Provider: "opencode", Title: name.Title, TitleSource: name.Source, TitleBasis: name.Basis, CreatedAt: millisecondTime(session.Time.Created), UpdatedAt: millisecondTime(session.Time.Updated)}
	seed, err := h.archive.chatSeedRecord(ctx, session.ID)
	if err != nil {
		return 0, err
	}
	hideFrom := int64(math.MaxInt64)
	if session.Revert != nil && session.Revert.MessageID != "" {
		if err := wait(ctx); err != nil {
			return 0, err
		}
		info, err := adapter.message(p, session.ID, session.Revert.MessageID)
		switch {
		case err == nil:
			hideFrom = openCodeMessageOrd(info.ID, info.Time.Created)
		case !errors.Is(err, ErrNotFound):
			return 0, err
		}
	}
	state, _ := openCodeState(status)
	total := 0
	for page := 0; maxPages <= 0 || page < maxPages; page++ {
		if err := wait(ctx); err != nil {
			return total, err
		}
		raw, more, err := adapter.messagePage(p, session.ID, pageSize, before)
		if err != nil {
			return total, err
		}
		if page == 0 && before == "" {
			chat.Model, chat.Mode, chat.Effort = openCodeChatSettings(raw)
		}
		messages := make([]ArchiveMessage, 0, len(raw))
		for _, item := range raw {
			if item.Info.Role != "user" && item.Info.Role != "assistant" {
				continue
			}
			message := seed.strip(*messageFromOC(item, p.Directory).Unified)
			if state == "idle" && message.Status == "streaming" {
				message.Status = "aborted"
			}
			archived := archiveMessageFromChat(message, session.ID)
			archived.Hidden = message.Ord >= hideFrom
			messages = append(messages, archived)
		}
		changed, err := h.archive.importChat(chat, messages, false)
		if err != nil {
			return total, err
		}
		total += changed
		next := ""
		if more && len(raw) > 0 {
			next = openCodePageCursor(raw[0].Info.ID, int64(raw[0].Info.Time.Created))
		}
		if onPage != nil {
			if err := onPage(next, changed); err != nil {
				return total, err
			}
		}
		if next == "" {
			break
		}
		before = next
	}
	return total, nil
}

// importCLIRecord copies one Claude Code or Codex chat into the archive,
// adding only messages it does not hold yet: live capture keeps the rest.
func (h *Host) importCLIRecord(ctx context.Context, p Project, record cliChatRecord) (int, error) {
	id := record.Session.ID
	provider := record.Session.Provider
	if provider == "" {
		provider = "claude"
		if strings.HasPrefix(id, "codex:") {
			provider = "codex"
		}
	}
	seed, err := h.archive.chatSeedRecord(ctx, id)
	if err != nil {
		return 0, err
	}
	// A streamed Codex chat keeps its parts in the record; the others have
	// only whole messages.
	var unified []ChatMessage
	if record.ACP != nil {
		// ACP chats (acp_store.go): the chat's messages sit under "acp".
		unified = record.acpUnified()
	} else if provider == "codex" && record.Codex != nil {
		unified = record.codexUnified()
	} else if provider == "claude" && len(record.Claude) > 0 {
		// Claude Code streaming (claude_store.go): streamed messages sit under
		// the record's "claude" key.
		unified = record.claudeUnified()
	} else {
		transcript := cliTranscript{session: record.Session, messages: record.Messages, created: record.Created, updated: record.UpdatedAt}
		unified = (cliProvider{provider: provider}).unified(transcript)
	}
	var first time.Time
	var messages []ArchiveMessage
	for _, message := range unified {
		archived := archiveMessageFromChat(seed.strip(message), id)
		if !archived.CreatedAt.IsZero() && (first.IsZero() || archived.CreatedAt.Before(first)) {
			first = archived.CreatedAt
		}
		messages = append(messages, archived)
	}
	name := sessionName(record.Session)
	chat := ArchiveChat{ID: id, ProjectID: p.ID, Provider: provider, Title: name.Title, TitleSource: name.Source, TitleBasis: name.Basis, Model: provider + "/default", CreatedAt: first, UpdatedAt: record.UpdatedAt}
	return h.archive.importChat(chat, messages, true)
}

// refreshArchivedChat imports a chat from its provider when the provider
// still has it, so a continue sees its latest messages. It is bounded and
// best effort: without the provider the archive's copy is used as it is.
func (h *Host) refreshArchivedChat(ctx context.Context, p Project, chatID string) {
	if h.archive == nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, continueRefreshWait)
	defer cancel()
	if isCLISessionID(chatID) {
		if h.cliChats == nil {
			return
		}
		if record, err := h.cliChats.recordCopy(p, chatID); err == nil {
			_, _ = h.importCLIRecord(ctx, p, record)
		}
		return
	}
	adapter, ok := h.agent.(*OpenCodeAdapter)
	if !ok {
		return
	}
	session, err := adapter.sessionInfo(p, chatID)
	if err != nil || session.ID != chatID || !sameDirectory(p.Directory, session.Directory) {
		return
	}
	statuses, err := adapter.sessionStatuses(p)
	if err != nil {
		return
	}
	unpaced := func(ctx context.Context) error { return ctx.Err() }
	_, _ = h.importOpenCodeSession(ctx, adapter, p, session, statuses[chatID], "", backfillPageSize, continueRefreshPages, unpaced, nil)
}

// recordCopy returns a consistent copy of a Claude Code or Codex chat's
// record, for importing it while the chat goes on.
func (c *CLIChats) recordCopy(project Project, id string) (cliChatRecord, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return cliChatRecord{}, err
	}
	copied := *record
	copied.Messages = append([]Message{}, record.Messages...)
	copied.Created = cloneCreated(record.Created)
	copied.Codex = cloneCodexRecord(record.Codex)
	return copied, nil
}

func millisecondTime(milliseconds float64) time.Time {
	if milliseconds <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(int64(milliseconds)).UTC()
}

// backfillSessions lists a project's sessions with their times.
func (a *OpenCodeAdapter) backfillSessions(p Project) ([]ocSession, error) {
	var sessions []ocSession
	err := a.doLimited("GET", "/session", p, nil, &sessions, backfillSessionListLimit)
	return sessions, err
}

// sessionInfo reads one session with its times and rewind point.
func (a *OpenCodeAdapter) sessionInfo(p Project, id string) (ocSession, error) {
	var session ocSession
	err := a.do("GET", "/session/"+url.PathEscape(id), p, nil, &session)
	return session, err
}

// Backfill state.

type backfillRow struct {
	source, scope              string
	cursor                     string
	done                       bool
	imported, chats, chatsDone int64
}

func (a *Archive) backfillRow(ctx context.Context, source, scope string) (backfillRow, error) {
	row := backfillRow{source: source, scope: scope}
	err := a.readDB.QueryRowContext(ctx, `SELECT cursor, done, imported, chats, chats_done FROM backfill_state WHERE source = ? AND scope = ?`, source, scope).
		Scan(&row.cursor, &row.done, &row.imported, &row.chats, &row.chatsDone)
	if errors.Is(err, sql.ErrNoRows) {
		return row, nil
	}
	return row, err
}

// saveBackfillRow writes a source's progress and waits for the commit.
func (a *Archive) saveBackfillRow(row backfillRow) error {
	if a.chatWritesPaused() {
		return ErrArchivePaused
	}
	return a.do(func(t *archiveTx) error {
		_, err := t.exec(`INSERT INTO backfill_state (source, scope, cursor, done, imported, chats, chats_done, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (source, scope) DO UPDATE SET cursor = excluded.cursor, done = excluded.done, imported = excluded.imported,
				chats = excluded.chats, chats_done = excluded.chats_done, updated_at = excluded.updated_at`,
			row.source, row.scope, row.cursor, row.done, row.imported, row.chats, row.chatsDone, t.now)
		return err
	})
}

// chatDeletedRead reports whether a chat was deleted from the archive.
func (a *Archive) chatDeletedRead(ctx context.Context, chatID string) (bool, error) {
	var count int
	err := a.readDB.QueryRowContext(ctx, `SELECT count(*) FROM changes WHERE entity = 'chat' AND chat_id = ? AND entity_id = ? AND op = 'delete'`, chatID, chatID).Scan(&count)
	return count > 0, err
}
