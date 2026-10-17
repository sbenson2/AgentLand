package host

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// The JSON shapes below follow the conversation model in docs/HOST-API.md.
// Times are RFC 3339 UTC with milliseconds.

type archiveChatJSON struct {
	ID        string `json:"id"`
	ProjectID string `json:"projectId"`
	Provider  string `json:"provider"`
	Title     string `json:"title"`
	// Chat names (chat_title.go, schema v4).
	TitleSource string `json:"titleSource"`
	TitleBasis  string `json:"titleBasis,omitempty"`
	Model       string `json:"model,omitempty"`
	Mode        string `json:"mode,omitempty"`
	Effort      string `json:"effort,omitempty"`
	ParentID    string `json:"parentId,omitempty"`
	// Relation says how the chat follows ParentID: "continue" (M1 chunk B2).
	Relation  string `json:"relation,omitempty"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

type archiveMessageJSON struct {
	ID          string            `json:"id"`
	ChatID      string            `json:"chatId"`
	TurnID      string            `json:"turnId,omitempty"`
	Role        string            `json:"role"`
	Status      string            `json:"status"`
	Ord         int64             `json:"ord"`
	CreatedAt   string            `json:"createdAt"`
	CompletedAt string            `json:"completedAt,omitempty"`
	Provider    string            `json:"provider"`
	Model       string            `json:"model,omitempty"`
	Usage       *archiveUsageJSON `json:"usage,omitempty"`
	Error       *archiveErrorJSON `json:"error,omitempty"`
	Hidden      bool              `json:"hidden,omitempty"`
	Parts       []archivePartJSON `json:"parts"`
	pk          int64
}

type archiveUsageJSON struct {
	Input      int64  `json:"input"`
	Output     int64  `json:"output"`
	Reasoning  int64  `json:"reasoning"`
	CacheRead  int64  `json:"cacheRead"`
	CacheWrite int64  `json:"cacheWrite"`
	CostMicros *int64 `json:"costMicros,omitempty"`
}

type archiveErrorJSON struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type archivePartJSON struct {
	ID         string                 `json:"id"`
	Kind       string                 `json:"kind"`
	Ord        int64                  `json:"ord"`
	Text       string                 `json:"text,omitempty"`
	Tool       *archiveToolJSON       `json:"tool,omitempty"`
	Attachment *archiveAttachmentJSON `json:"attachment,omitempty"`
	Start      string                 `json:"start,omitempty"`
	End        string                 `json:"end,omitempty"`
	Truncated  bool                   `json:"truncated,omitempty"`
}

type archiveToolJSON struct {
	Name      string `json:"name"`
	CallID    string `json:"callId"`
	Status    string `json:"status"`
	Title     string `json:"title,omitempty"`
	Input     string `json:"input,omitempty"`
	Output    string `json:"output,omitempty"`
	Error     string `json:"error,omitempty"`
	Truncated bool   `json:"truncated"`
	// Plain chats: sources and the memory entry, as the tool part had them.
	ChatToolResults
}

type archiveAttachmentJSON struct {
	Name   string `json:"name"`
	MIME   string `json:"mime"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256,omitempty"`
}

type archiveInteractionJSON struct {
	ID         string `json:"id"`
	ChatID     string `json:"chatId"`
	Kind       string `json:"kind"`
	Outcome    string `json:"outcome,omitempty"`
	Summary    string `json:"summary,omitempty"`
	CreatedAt  string `json:"createdAt"`
	ResolvedAt string `json:"resolvedAt,omitempty"`
}

type archiveTerminalLogJSON struct {
	ID        string `json:"id"`
	ProjectID string `json:"projectId"`
	Title     string `json:"title"`
	Program   string `json:"program"`
	StartedAt string `json:"startedAt"`
	EndedAt   string `json:"endedAt,omitempty"`
	Status    string `json:"status"`
	ExitCode  *int64 `json:"exitCode,omitempty"`
	Bytes     int64  `json:"bytes"`
	GapBytes  int64  `json:"gapBytes"`
	// How it ended (v7, terminal_end.go); empty for logs from before.
	EndReason      string `json:"endReason,omitempty"`
	ConversationID string `json:"conversationId,omitempty"`
	file           string
	started        int64
	endedBy        string
}

type archiveTombstoneJSON struct {
	ID     string `json:"id"`
	ChatID string `json:"chatId,omitempty"`
}

const archiveTimeLayout = "2006-01-02T15:04:05.000Z"

func archiveTimeText(milliseconds int64) string {
	return time.UnixMilli(milliseconds).UTC().Format(archiveTimeLayout)
}

func archiveNullTime(value sql.NullInt64) string {
	if !value.Valid {
		return ""
	}
	return archiveTimeText(value.Int64)
}

type archiveQuerier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func archivePlaceholders(count int) string {
	return strings.TrimSuffix(strings.Repeat("?, ", count), ", ")
}

func archiveArgs[T any](values []T) []any {
	args := make([]any, len(values))
	for index, value := range values {
		args[index] = value
	}
	return args
}

func archiveLoadChat(ctx context.Context, q archiveQuerier, id string) (archiveChatJSON, error) {
	var chat archiveChatJSON
	var created, updated int64
	err := q.QueryRowContext(ctx, `SELECT id, project_id, provider, title, title_source, title_basis, model, mode, effort, parent_id, relation, created_at, updated_at FROM chats WHERE id = ?`, id).
		Scan(&chat.ID, &chat.ProjectID, &chat.Provider, &chat.Title, &chat.TitleSource, &chat.TitleBasis, &chat.Model, &chat.Mode, &chat.Effort, &chat.ParentID, &chat.Relation, &created, &updated)
	chat.CreatedAt, chat.UpdatedAt = archiveTimeText(created), archiveTimeText(updated)
	// A chat archived before sources were kept has the one its title implies.
	if err == nil && chat.TitleSource == "" {
		chat.TitleSource, chat.TitleBasis = titleSourceFor(chat.Title), ""
	}
	return chat, err
}

const archiveMessageSelect = `SELECT m.pk, m.id, m.chat_id, m.turn_id, m.role, m.status, m.ord, m.created_at, m.completed_at, c.provider, m.model,
	m.usage_input, m.usage_output, m.usage_reasoning, m.usage_cache_read, m.usage_cache_write, m.usage_cost_micros,
	m.error_code, m.error_message, m.hidden
	FROM messages m JOIN chats c ON c.id = m.chat_id `

// archiveLoadMessages runs archiveMessageSelect with the given condition and
// order, then attaches each message's parts.
func archiveLoadMessages(ctx context.Context, q archiveQuerier, tail string, args ...any) ([]archiveMessageJSON, error) {
	rows, err := q.QueryContext(ctx, archiveMessageSelect+tail, args...)
	if err != nil {
		return nil, err
	}
	messages := []archiveMessageJSON{}
	for rows.Next() {
		var m archiveMessageJSON
		var created int64
		var completed sql.NullInt64
		var usage [6]sql.NullInt64
		var errorCode, errorMessage string
		if err := rows.Scan(&m.pk, &m.ID, &m.ChatID, &m.TurnID, &m.Role, &m.Status, &m.Ord, &created, &completed, &m.Provider, &m.Model,
			&usage[0], &usage[1], &usage[2], &usage[3], &usage[4], &usage[5], &errorCode, &errorMessage, &m.Hidden); err != nil {
			rows.Close()
			return nil, err
		}
		m.CreatedAt, m.CompletedAt = archiveTimeText(created), archiveNullTime(completed)
		if usage[0].Valid {
			m.Usage = &archiveUsageJSON{Input: usage[0].Int64, Output: usage[1].Int64, Reasoning: usage[2].Int64, CacheRead: usage[3].Int64, CacheWrite: usage[4].Int64}
			if usage[5].Valid {
				cost := usage[5].Int64
				m.Usage.CostMicros = &cost
			}
		}
		if errorCode != "" || errorMessage != "" {
			m.Error = &archiveErrorJSON{Code: errorCode, Message: errorMessage}
		}
		m.Parts = []archivePartJSON{}
		messages = append(messages, m)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return messages, archiveLoadParts(ctx, q, messages)
}

func archiveLoadParts(ctx context.Context, q archiveQuerier, messages []archiveMessageJSON) error {
	index := map[int64]*archiveMessageJSON{}
	var keys []int64
	for i := range messages {
		index[messages[i].pk] = &messages[i]
		keys = append(keys, messages[i].pk)
	}
	for len(keys) > 0 {
		batch := keys[:min(len(keys), 100)]
		keys = keys[len(batch):]
		rows, err := q.QueryContext(ctx, `SELECT message_pk, ord, id, kind, text, tool_name, tool_call_id, tool_status, tool_title,
			tool_input, tool_output, tool_error, truncated, attachment_name, attachment_mime, attachment_size, blob_sha256,
			started_at, ended_at, tool_sources, tool_memory_id, tool_memory_text FROM parts WHERE message_pk IN (`+archivePlaceholders(len(batch))+`) ORDER BY message_pk, ord`, archiveArgs(batch)...)
		if err != nil {
			return err
		}
		for rows.Next() {
			var pk int64
			var part archivePartJSON
			var tool archiveToolJSON
			var toolName, attachmentName, blob sql.NullString
			var attachment archiveAttachmentJSON
			var truncated bool
			var started, ended sql.NullInt64
			var sources, memoryID, memoryText string
			if err := rows.Scan(&pk, &part.Ord, &part.ID, &part.Kind, &part.Text, &toolName, &tool.CallID, &tool.Status, &tool.Title,
				&tool.Input, &tool.Output, &tool.Error, &truncated, &attachmentName, &attachment.MIME, &attachment.Size, &blob,
				&started, &ended, &sources, &memoryID, &memoryText); err != nil {
				rows.Close()
				return err
			}
			if toolName.Valid {
				tool.Name, tool.Truncated = toolName.String, truncated
				// Plain chats: what the part named, as it was kept.
				if sources != "" {
					_ = json.Unmarshal([]byte(sources), &tool.Sources)
				}
				if memoryID != "" {
					tool.Memory = &ChatToolMemory{ID: memoryID, Text: memoryText}
				}
				part.Tool = &tool
			} else {
				part.Truncated = truncated
			}
			if attachmentName.Valid {
				attachment.Name, attachment.SHA256 = attachmentName.String, blob.String
				part.Attachment = &attachment
			}
			part.Start, part.End = archiveNullTime(started), archiveNullTime(ended)
			if message := index[pk]; message != nil {
				message.Parts = append(message.Parts, part)
			}
		}
		if err := rows.Close(); err != nil {
			return err
		}
		if err := rows.Err(); err != nil {
			return err
		}
	}
	return nil
}

func archiveLoadTerminalLog(ctx context.Context, q archiveQuerier, id string) (archiveTerminalLogJSON, error) {
	logs, err := archiveScanTerminalLogs(q.QueryContext(ctx, archiveTerminalLogSelect+`WHERE id = ?`, id))
	if err != nil {
		return archiveTerminalLogJSON{}, err
	}
	if len(logs) == 0 {
		return archiveTerminalLogJSON{}, sql.ErrNoRows
	}
	return logs[0], nil
}

const archiveTerminalLogSelect = `SELECT ` + archiveTerminalLogColumns + ` FROM terminal_logs `

// archiveTerminalLogColumns are the columns archiveScanTerminalLogs reads.
const archiveTerminalLogColumns = `id, project_id, title, program, started_at, ended_at, status, exit_code, bytes, gap_bytes, file, end_reason, ended_by_device_id, conversation_id`

func archiveScanTerminalLogs(rows *sql.Rows, err error) ([]archiveTerminalLogJSON, error) {
	if err != nil {
		return nil, err
	}
	logs := []archiveTerminalLogJSON{}
	for rows.Next() {
		var log archiveTerminalLogJSON
		var ended, exitCode sql.NullInt64
		if err := rows.Scan(&log.ID, &log.ProjectID, &log.Title, &log.Program, &log.started, &ended, &log.Status, &exitCode, &log.Bytes, &log.GapBytes, &log.file,
			&log.EndReason, &log.endedBy, &log.ConversationID); err != nil {
			rows.Close()
			return nil, err
		}
		log.StartedAt, log.EndedAt = archiveTimeText(log.started), archiveNullTime(ended)
		if exitCode.Valid {
			code := exitCode.Int64
			log.ExitCode = &code
		}
		logs = append(logs, log)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	return logs, rows.Err()
}

// Change feed.

// ArchiveChanges is one page of GET /v1/archive/changes.
type ArchiveChanges struct {
	Epoch   string          `json:"epoch"`
	Resync  bool            `json:"resync"`
	Changes []ArchiveChange `json:"changes"`
	Cursor  string          `json:"cursor"`
	HasMore bool            `json:"hasMore"`
}

// ArchiveChange carries the entity's current state for an upsert, or its IDs
// for a delete.
type ArchiveChange struct {
	Seq     int64           `json:"seq"`
	Entity  string          `json:"entity"`
	Op      string          `json:"op"`
	Payload json.RawMessage `json:"payload"`
}

var (
	errArchiveCursor = errors.New("invalid archive cursor")
	errArchiveBefore = errors.New("the message to page before is not in this chat")
)

const (
	archiveChangesPageBytes = 2 << 20
	archiveChatPageBytes    = 4 << 20
	archiveSearchMaxOffset  = 10000
)

// feedEpoch combines the database's epoch with the configured project set.
// Changing which projects are configured changes the epoch, so clients
// resync: chats of a removed project disappear from devices, and they come
// back when the project is added again.
func (a *Archive) feedEpoch(projects []string) string {
	sorted := slices.Clone(projects)
	slices.Sort(sorted)
	digest := sha256.New()
	for _, project := range sorted {
		digest.Write([]byte(project))
		digest.Write([]byte{0})
	}
	return a.epoch + "-" + hex.EncodeToString(digest.Sum(nil))[:8]
}

// Changes returns the changes after cursor for chats and terminal logs in the
// given projects, oldest first, at most limit of them and about 2 MiB (a page
// always carries at least one change). An empty cursor starts from the
// beginning. A cursor from another epoch, or one past the newest change,
// restarts from the beginning with Resync set: the client drops its copy
// before applying the page.
func (a *Archive) Changes(ctx context.Context, cursor string, limit int, projects []string) (ArchiveChanges, error) {
	epoch := a.feedEpoch(projects)
	result := ArchiveChanges{Epoch: epoch, Changes: []ArchiveChange{}}
	var after int64
	if cursor != "" {
		dot := strings.LastIndexByte(cursor, '.')
		if dot <= 0 {
			return result, errArchiveCursor
		}
		seq, err := strconv.ParseInt(cursor[dot+1:], 10, 64)
		if err != nil || seq < 0 {
			return result, errArchiveCursor
		}
		if cursor[:dot] == epoch {
			after = seq
		} else {
			result.Resync = true
		}
	}
	tx, err := a.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	var high int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'changes'), 0)`).Scan(&high); err != nil {
		return result, err
	}
	if after > high {
		result.Resync, after = true, 0
	}
	result.Cursor = fmt.Sprintf("%s.%d", epoch, high)
	if len(projects) == 0 {
		return result, nil
	}
	type changeRow struct {
		seq                          int64
		entity, entityID, chatID, op string
	}
	rows, err := tx.QueryContext(ctx, `SELECT seq, entity, entity_id, chat_id, op FROM changes WHERE seq > ? AND project_id IN (`+
		archivePlaceholders(len(projects))+`) ORDER BY seq LIMIT ?`, append(append([]any{after}, archiveArgs(projects)...), limit+1)...)
	if err != nil {
		return result, err
	}
	var found []changeRow
	for rows.Next() {
		var row changeRow
		if err := rows.Scan(&row.seq, &row.entity, &row.entityID, &row.chatID, &row.op); err != nil {
			rows.Close()
			return result, err
		}
		found = append(found, row)
	}
	if err := rows.Close(); err != nil {
		return result, err
	}
	if len(found) > limit {
		found, result.HasMore = found[:limit], true
	}
	last, size := after, 0
	for _, row := range found {
		payload, err := a.changePayload(ctx, tx, row.entity, row.entityID, row.chatID, row.op)
		if errors.Is(err, sql.ErrNoRows) {
			last = row.seq
			continue
		}
		if err != nil {
			return result, err
		}
		cost := len(payload) + 96
		if len(result.Changes) > 0 && size+cost > archiveChangesPageBytes {
			result.HasMore = true
			break
		}
		result.Changes = append(result.Changes, ArchiveChange{Seq: row.seq, Entity: row.entity, Op: row.op, Payload: payload})
		size += cost
		last = row.seq
	}
	if result.HasMore {
		result.Cursor = fmt.Sprintf("%s.%d", epoch, last)
	}
	return result, nil
}

func (a *Archive) changePayload(ctx context.Context, q archiveQuerier, entity, entityID, chatID, op string) (json.RawMessage, error) {
	var value any
	switch {
	case op == "delete" && entity == "message":
		value = archiveTombstoneJSON{ID: entityID, ChatID: chatID}
	case op == "delete":
		value = archiveTombstoneJSON{ID: entityID}
	case entity == "chat":
		chat, err := archiveLoadChat(ctx, q, entityID)
		if err != nil {
			return nil, err
		}
		value = chat
	case entity == "message":
		messages, err := archiveLoadMessages(ctx, q, `WHERE m.chat_id = ? AND m.id = ?`, chatID, entityID)
		if err != nil {
			return nil, err
		}
		if len(messages) == 0 {
			return nil, sql.ErrNoRows
		}
		value = messages[0]
	case entity == "terminalLog":
		log, err := archiveLoadTerminalLog(ctx, q, entityID)
		if err != nil {
			return nil, err
		}
		value = log
	default:
		return nil, sql.ErrNoRows
	}
	return json.Marshal(value)
}

// Chat pages.

// ArchiveChatPage is GET /v1/archive/chat: the chat and one page of its
// messages, oldest first. The first page holds the newest messages; the next
// page ends before OldestID.
type ArchiveChatPage struct {
	Chat     archiveChatJSON      `json:"chat"`
	Messages []archiveMessageJSON `json:"messages"`
	HasMore  bool                 `json:"hasMore"`
	OldestID string               `json:"oldestId,omitempty"`
}

// ArchivedChat reads one chat's metadata; sql.ErrNoRows when it is not archived.
func (a *Archive) ArchivedChat(ctx context.Context, chatID string) (archiveChatJSON, error) {
	return archiveLoadChat(ctx, a.readDB, chatID)
}

// ChatPage returns up to limit messages before the message with ID before
// (or the newest ones), about 4 MiB at most, hidden messages included.
func (a *Archive) ChatPage(ctx context.Context, chatID, before string, limit int) (ArchiveChatPage, error) {
	tx, err := a.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return ArchiveChatPage{}, err
	}
	defer tx.Rollback()
	chat, err := archiveLoadChat(ctx, tx, chatID)
	if err != nil {
		return ArchiveChatPage{}, err
	}
	ord, pk := int64(math.MaxInt64), int64(math.MaxInt64)
	if before != "" {
		if err := tx.QueryRowContext(ctx, `SELECT ord, pk FROM messages WHERE chat_id = ? AND id = ?`, chatID, before).Scan(&ord, &pk); errors.Is(err, sql.ErrNoRows) {
			return ArchiveChatPage{}, errArchiveBefore
		} else if err != nil {
			return ArchiveChatPage{}, err
		}
	}
	messages, err := archiveLoadMessages(ctx, tx, `WHERE m.chat_id = ? AND (m.ord, m.pk) < (?, ?) ORDER BY m.ord DESC, m.pk DESC LIMIT ?`, chatID, ord, pk, limit+1)
	if err != nil {
		return ArchiveChatPage{}, err
	}
	page := ArchiveChatPage{Chat: chat}
	if len(messages) > limit {
		messages, page.HasMore = messages[:limit], true
	}
	size := 0
	for index, message := range messages {
		size += archiveMessageSize(message)
		if index > 0 && size > archiveChatPageBytes {
			messages, page.HasMore = messages[:index], true
			break
		}
	}
	slices.Reverse(messages)
	page.Messages = messages
	if len(messages) > 0 {
		page.OldestID = messages[0].ID
	}
	return page, nil
}

// archiveMessageSize estimates a message's encoded size.
func archiveMessageSize(message archiveMessageJSON) int {
	size := 512 + len(message.ID) + len(message.ChatID)
	for _, part := range message.Parts {
		size += 256 + len(part.Text)
		if part.Tool != nil {
			size += len(part.Tool.Input) + len(part.Tool.Output) + len(part.Tool.Error) + len(part.Tool.Title)
		}
	}
	return size
}

// Search.

// ArchiveSearch is a full-text query. Text is split into terms that are each
// quoted, so no FTS5 syntax can be injected; a '*' ending the last term makes
// it a prefix. ProjectID, Provider, From and To narrow the results.
type ArchiveSearch struct {
	Text      string
	ProjectID string
	Provider  string
	From, To  time.Time
	Limit     int
	Cursor    string
}

// ArchiveSearchResult marks each match in Snippet between U+0002 and U+0003;
// the index never contains those characters. Provider is the chat's.
type ArchiveSearchResult struct {
	ChatID    string `json:"chatId"`
	MessageID string `json:"messageId"`
	ProjectID string `json:"projectId"`
	Provider  string `json:"provider"`
	Title     string `json:"title"`
	Role      string `json:"role"`
	CreatedAt string `json:"createdAt"`
	Snippet   string `json:"snippet"`
}

type ArchiveSearchPage struct {
	Results    []ArchiveSearchResult `json:"results"`
	NextCursor string                `json:"nextCursor,omitempty"`
}

// archiveMatchQuery turns user text into an FTS5 query of quoted terms. Terms
// without any letter or digit are dropped, since they would not match a token.
func archiveMatchQuery(text string) string {
	fields := strings.Fields(text)
	terms := make([]string, 0, len(fields))
	for index, field := range fields {
		prefix := false
		if index == len(fields)-1 && strings.HasSuffix(field, "*") {
			field, prefix = strings.TrimRight(field, "*"), true
		}
		if strings.IndexFunc(field, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.Is(unicode.Co, r) }) < 0 {
			continue
		}
		term := `"` + strings.ReplaceAll(field, `"`, `""`) + `"`
		if prefix {
			term += "*"
		}
		terms = append(terms, term)
	}
	return strings.Join(terms, " ")
}

// Search returns matching, visible messages in the given projects, best
// matches first.
func (a *Archive) Search(ctx context.Context, search ArchiveSearch, projects []string) (ArchiveSearchPage, error) {
	page := ArchiveSearchPage{Results: []ArchiveSearchResult{}}
	offset := 0
	if search.Cursor != "" {
		value, ok := strings.CutPrefix(search.Cursor, "s.")
		parsed, err := strconv.Atoi(value)
		if !ok || err != nil || parsed < 0 || parsed > archiveSearchMaxOffset {
			return page, errArchiveCursor
		}
		offset = parsed
	}
	match := archiveMatchQuery(search.Text)
	if match == "" || len(projects) == 0 {
		return page, nil
	}
	conditions := []string{`message_fts MATCH ?`, `m.hidden = 0`, `c.project_id IN (` + archivePlaceholders(len(projects)) + `)`}
	args := append([]any{match}, archiveArgs(projects)...)
	if search.ProjectID != "" {
		conditions, args = append(conditions, `c.project_id = ?`), append(args, search.ProjectID)
	}
	if search.Provider != "" {
		conditions, args = append(conditions, `c.provider = ?`), append(args, search.Provider)
	}
	if !search.From.IsZero() {
		conditions, args = append(conditions, `m.created_at >= ?`), append(args, search.From.UnixMilli())
	}
	if !search.To.IsZero() {
		conditions, args = append(conditions, `m.created_at < ?`), append(args, search.To.UnixMilli())
	}
	args = append(args, search.Limit+1, offset)
	rows, err := a.readDB.QueryContext(ctx, `SELECT m.chat_id, m.id, c.project_id, c.provider, c.title, m.role, m.created_at,
			snippet(message_fts, 0, char(2), char(3), '…', 16)
		FROM message_fts JOIN messages m ON m.pk = message_fts.rowid JOIN chats c ON c.id = m.chat_id
		WHERE `+strings.Join(conditions, " AND ")+` ORDER BY rank, m.created_at DESC, m.pk DESC LIMIT ? OFFSET ?`, args...)
	if err != nil {
		return page, err
	}
	for rows.Next() {
		var result ArchiveSearchResult
		var created int64
		if err := rows.Scan(&result.ChatID, &result.MessageID, &result.ProjectID, &result.Provider, &result.Title, &result.Role, &created, &result.Snippet); err != nil {
			rows.Close()
			return page, err
		}
		result.CreatedAt = archiveTimeText(created)
		page.Results = append(page.Results, result)
	}
	if err := rows.Close(); err != nil {
		return page, err
	}
	if err := rows.Err(); err != nil {
		return page, err
	}
	if len(page.Results) > search.Limit {
		page.Results = page.Results[:search.Limit]
		if next := offset + search.Limit; next <= archiveSearchMaxOffset {
			page.NextCursor = "s." + strconv.Itoa(next)
		}
	}
	return page, nil
}

// Terminal log listing.

// ArchiveTerminalLogPage lists terminal logs, newest first.
type ArchiveTerminalLogPage struct {
	Logs       []archiveTerminalLogJSON `json:"logs"`
	NextCursor string                   `json:"nextCursor,omitempty"`
}

// TerminalLogs lists logs in the given projects (optionally one of them),
// continuing after cursor.
func (a *Archive) TerminalLogs(ctx context.Context, projectID string, projects []string, cursor string, limit int) (ArchiveTerminalLogPage, error) {
	page := ArchiveTerminalLogPage{Logs: []archiveTerminalLogJSON{}}
	if len(projects) == 0 {
		return page, nil
	}
	conditions := []string{`project_id IN (` + archivePlaceholders(len(projects)) + `)`}
	args := archiveArgs(projects)
	if projectID != "" {
		conditions, args = append(conditions, `project_id = ?`), append(args, projectID)
	}
	if cursor != "" {
		started, id, ok := strings.Cut(cursor, ".")
		value, err := strconv.ParseInt(started, 10, 64)
		if !ok || err != nil || archiveCheckID("cursor", id) != nil {
			return page, errArchiveCursor
		}
		conditions, args = append(conditions, `(started_at, id) < (?, ?)`), append(args, value, id)
	}
	args = append(args, limit+1)
	logs, err := archiveScanTerminalLogs(a.readDB.QueryContext(ctx, archiveTerminalLogSelect+`WHERE `+strings.Join(conditions, " AND ")+` ORDER BY started_at DESC, id DESC LIMIT ?`, args...))
	if err != nil {
		return page, err
	}
	if len(logs) > limit {
		logs = logs[:limit]
		last := logs[len(logs)-1]
		page.NextCursor = fmt.Sprintf("%d.%s", last.started, last.ID)
	}
	page.Logs = logs
	return page, nil
}

// terminalEndRecord is how the archive says a terminal ended, with the ID of
// the device that ended it.
type terminalEndRecord struct {
	end     TerminalEnd
	endedBy string
}

// TerminalEnding reads how the newest log of a terminal in this workspace
// ended, whichever device opened it; an empty projectID names none, and finds
// the terminal's newest log in any workspace or outside every one
// (terminalNoWorkspaceArchiveID). sql.ErrNoRows when there is none or it is
// still running. A log from before v7 has no reason, except an interrupted
// one.
func (a *Archive) TerminalEnding(ctx context.Context, terminalID, projectID string) (terminalEndRecord, error) {
	query, args := archiveTerminalLogSelect+`WHERE terminal_id = ? AND project_id = ? ORDER BY started_at DESC LIMIT 1`, []any{terminalID, projectID}
	if projectID == "" {
		query, args = archiveTerminalLogSelect+`WHERE terminal_id = ? ORDER BY started_at DESC LIMIT 1`, []any{terminalID}
	}
	logs, err := archiveScanTerminalLogs(a.readDB.QueryContext(ctx, query, args...))
	if err != nil {
		return terminalEndRecord{}, err
	}
	if len(logs) == 0 || logs[0].Status == "running" || logs[0].EndedAt == "" {
		return terminalEndRecord{}, sql.ErrNoRows
	}
	log := logs[0]
	reason := log.EndReason
	if reason == "" && log.Status == "interrupted" {
		reason = terminalEndHostInterrupted
	}
	end := TerminalEnd{Reason: reason, At: log.EndedAt, Program: log.Program, ConversationID: log.ConversationID}
	if log.ExitCode != nil {
		code := int(*log.ExitCode)
		end.ExitCode = &code
	}
	return terminalEndRecord{end: end, endedBy: log.endedBy}, nil
}

// ArchivedTerminalLog reads one log's metadata; sql.ErrNoRows when unknown.
func (a *Archive) ArchivedTerminalLog(ctx context.Context, id string) (archiveTerminalLogJSON, error) {
	return archiveLoadTerminalLog(ctx, a.readDB, id)
}

// Stats.

// ArchiveStats is GET /v1/archive/stats, for this Mac only.
//
// Two floors apply to free space: below MinimumFreeBytes (2 GiB) terminal
// output and attachment bytes are not recorded (CapturePaused); below
// ChatMinimumFreeBytes (256 MiB) chat text is not recorded either
// (ChatCapturePaused).
type ArchiveStats struct {
	SchemaVersion        int                       `json:"schemaVersion"`
	Directory            string                    `json:"directory"`
	DatabaseBytes        int64                     `json:"databaseBytes"`
	Chats                int64                     `json:"chats"`
	Messages             int64                     `json:"messages"`
	HiddenChats          int64                     `json:"hiddenChats"`
	Blobs                int64                     `json:"blobs"`
	BlobBytes            int64                     `json:"blobBytes"`
	TerminalLogs         int64                     `json:"terminalLogs"`
	TerminalLogBytes     int64                     `json:"terminalLogBytes"`
	GapBytes             int64                     `json:"gapBytes"`
	FreeBytes            *int64                    `json:"freeBytes"`
	MinimumFreeBytes     int64                     `json:"minimumFreeBytes"`
	CapturePaused        bool                      `json:"capturePaused"`
	ChatMinimumFreeBytes int64                     `json:"chatMinimumFreeBytes"`
	ChatCapturePaused    bool                      `json:"chatCapturePaused"`
	SkippedWrites        int64                     `json:"skippedWrites"`
	WriteErrors          int64                     `json:"writeErrors"`
	LastError            string                    `json:"lastError,omitempty"`
	PendingWrites        int                       `json:"pendingWrites"`
	Backfill             []ArchiveBackfillProgress `json:"backfill"`
	// BackfillState is the backfill job's state (archive_backfill.go):
	// running, paused (a chat is streaming), retrying or done; absent when
	// the host runs none.
	BackfillState string `json:"backfillState,omitempty"`
}

// ArchiveBackfillProgress is one source and scope of the backfill: source
// "opencode" or "cli", scope a project ID. Chats counts the chats the last
// pass found and ChatsDone those it finished; Imported counts messages it
// added or changed over all passes.
type ArchiveBackfillProgress struct {
	Source    string `json:"source"`
	Scope     string `json:"scope"`
	Done      bool   `json:"done"`
	Imported  int64  `json:"imported"`
	Chats     int64  `json:"chats"`
	ChatsDone int64  `json:"chatsDone"`
	UpdatedAt string `json:"updatedAt"`
}

// Stats reports sizes, counts, capture state and backfill progress.
// HiddenChats counts chats whose project is not among projects.
func (a *Archive) Stats(ctx context.Context, projects []string) (ArchiveStats, error) {
	stats := ArchiveStats{Directory: a.directory, MinimumFreeBytes: archiveMinimumFree, ChatMinimumFreeBytes: archiveChatMinimumFree, Backfill: []ArchiveBackfillProgress{}}
	tx, err := a.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return stats, err
	}
	defer tx.Rollback()
	visible := `0`
	if len(projects) > 0 {
		visible = `project_id IN (` + archivePlaceholders(len(projects)) + `)`
	}
	for _, query := range []struct {
		sql  string
		args []any
		dest []any
	}{
		{`SELECT schema_version FROM meta WHERE id = 1`, nil, []any{&stats.SchemaVersion}},
		{`SELECT count(*) FROM chats`, nil, []any{&stats.Chats}},
		{`SELECT count(*) FROM chats WHERE NOT (` + visible + `)`, archiveArgs(projects), []any{&stats.HiddenChats}},
		{`SELECT count(*) FROM messages`, nil, []any{&stats.Messages}},
		{`SELECT count(*), COALESCE(sum(size), 0) FROM blobs`, nil, []any{&stats.Blobs, &stats.BlobBytes}},
		{`SELECT count(*), COALESCE(sum(bytes), 0), COALESCE(sum(gap_bytes), 0) FROM terminal_logs`, nil, []any{&stats.TerminalLogs, &stats.TerminalLogBytes, &stats.GapBytes}},
	} {
		if err := tx.QueryRowContext(ctx, query.sql, query.args...).Scan(query.dest...); err != nil {
			return stats, err
		}
	}
	rows, err := tx.QueryContext(ctx, `SELECT source, scope, done, imported, chats, chats_done, updated_at FROM backfill_state ORDER BY source, scope`)
	if err != nil {
		return stats, err
	}
	for rows.Next() {
		var progress ArchiveBackfillProgress
		var updated int64
		if err := rows.Scan(&progress.Source, &progress.Scope, &progress.Done, &progress.Imported, &progress.Chats, &progress.ChatsDone, &updated); err != nil {
			rows.Close()
			return stats, err
		}
		progress.UpdatedAt = archiveTimeText(updated)
		stats.Backfill = append(stats.Backfill, progress)
	}
	if err := rows.Close(); err != nil {
		return stats, err
	}
	for _, suffix := range []string{"", "-wal"} {
		if info, err := os.Stat(filepath.Join(a.directory, "archive.db"+suffix)); err == nil {
			stats.DatabaseBytes += info.Size()
		}
	}
	if free := a.freeBytes.Load(); free >= 0 {
		stats.FreeBytes = &free
	}
	stats.CapturePaused = a.paused.Load()
	stats.ChatCapturePaused = a.chatPaused.Load()
	stats.SkippedWrites = a.skipped.Load()
	stats.WriteErrors = a.failures.Load()
	a.mu.Lock()
	stats.LastError = a.lastErr
	stats.PendingWrites = len(a.pending)
	a.mu.Unlock()
	return stats, nil
}
