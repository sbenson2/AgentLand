package host

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode/utf8"
)

// Continue with another model (M1 chunk B2): POST /v1/chat/continue starts a
// new chat, with any provider, from an archived one. The seed is built from
// the archive, so it works after the source's provider is gone: the source's
// first user message, then its newest messages up to the budget, in order;
// tool calls summarized in one line each, reasoning left out, attachments
// listed by name.
//
// The seed is the new chat's own message (ID "agentland-seed", role user,
// ord 0) with one context part, in the archive and at the start of the chat
// in the hub and in GET /v1/chat/messages. Nothing is sent by itself: the
// chat's first prompt goes to the provider as seed + "\n\n" + prompt, and the
// provider's copy of that message is shown and archived without the seed.
// The seed message's completedAt records when it was sent; a prompt after a
// rewind of that first message carries it again.
const (
	chatSeedMessageID    = "agentland-seed"
	chatSeedPartID       = "agentland-seed-context"
	chatSeedSeparator    = "\n\n"
	continueDefaultChars = 48000
	continueMinimumChars = 1000
	continueMaximumChars = 200000
	// continueSeedBytes also bounds the seed in bytes, so the first prompt
	// (seed plus at most 32 KiB) stays within a text part's 512 KiB and the
	// seed can be recognized in the provider's copy.
	continueSeedBytes = 384 << 10
	// continueRefresh bounds importing the source from its provider first.
	continueRefreshWait  = 15 * time.Second
	continueRefreshPages = 100
)

// chatSeed is a continued chat's seed. text and createdAt never change;
// carrier and deliveredAt change under the hub's lock.
type chatSeed struct {
	text      string
	createdAt time.Time
	// The chat's provider and the model, mode and effort it was continued
	// with: defaults for the prompt that carries the seed.
	provider, model, mode, effort string
	// carrier is the user message that carried the seed, deliveredAt when;
	// both empty while the seed waits for the first prompt.
	carrier     string
	deliveredAt time.Time
}

// defaults fills a prompt's empty model, mode and effort with the ones the
// chat was continued with (see continueOptions).
func (s chatSeed) defaults(options PromptOptions) PromptOptions {
	if options.Model == "" {
		options.Model = s.model
	}
	// Claude Code streaming: Claude chats take a mode and effort like Codex.
	if s.provider == "codex" || (s.provider == "claude" && validClaudeMode(s.mode)) {
		if options.Mode == "" {
			options.Mode = s.mode
		}
		if options.Effort == "" {
			options.Effort = s.effort
		}
	} else if options.Agent == "" {
		options.Agent = s.mode
	}
	return options
}

// message is the seed as the chat's first message.
func (s *chatSeed) message(chatID, provider string) ChatMessage {
	return ChatMessage{ID: chatSeedMessageID, ChatID: chatID, TurnID: chatSeedMessageID, Role: "user", Status: "complete", Ord: 0,
		CreatedAt: chatTimeOf(s.createdAt), CompletedAt: chatTimeOf(s.deliveredAt), Provider: provider,
		Parts: []ChatPart{{ID: chatSeedPartID, Kind: "context", Ord: 0, Text: s.text}}}
}

// stripPart removes the seed from the start of the text of the user message
// that carried it. A nil seed changes nothing.
func (s *chatSeed) stripPart(part ChatPart) ChatPart {
	if s == nil || part.Kind != "text" {
		return part
	}
	rest, ok := strings.CutPrefix(part.Text, s.text)
	if !ok {
		return part
	}
	if after, cut := strings.CutPrefix(rest, chatSeedSeparator); cut {
		rest = after
	} else if strings.TrimSpace(rest) != "" {
		return part
	}
	part.Text = rest
	return part
}

// strip applies stripPart to a user message's parts.
func (s *chatSeed) strip(message ChatMessage) ChatMessage {
	if s == nil || message.Role != "user" || message.ID == chatSeedMessageID {
		return message
	}
	for index, part := range message.Parts {
		if stripped := s.stripPart(part); stripped.Text != part.Text {
			parts := slices.Clone(message.Parts)
			parts[index] = stripped
			message.Parts = parts
			break
		}
	}
	return message
}

// ensureSeed reads a chat's seed from the archive the first time the hub
// needs it and caches the answer (nil when the chat has none).
func (h *chatHub) ensureSeed(ctx context.Context, chatID string) {
	if h.capture == nil {
		return
	}
	h.mu.Lock()
	_, known := h.seeds[chatID]
	h.mu.Unlock()
	if known {
		return
	}
	seed, err := h.capture.archive.chatSeedRecord(ctx, chatID)
	if err != nil {
		return
	}
	h.mu.Lock()
	if _, known := h.seeds[chatID]; !known {
		h.seeds[chatID] = seed
	}
	h.mu.Unlock()
}

// registerSeed records a new continued chat's seed.
func (h *chatHub) registerSeed(chatID string, seed *chatSeed) {
	h.mu.Lock()
	h.seeds[chatID] = seed
	h.mu.Unlock()
}

// forgetSeed drops a cached seed, after the chat is deleted from the archive.
func (h *chatHub) forgetSeed(chatID string) {
	h.mu.Lock()
	delete(h.seeds, chatID)
	h.mu.Unlock()
}

// seedCopy returns a chat's seed, reading it from the archive if needed.
func (h *chatHub) seedCopy(ctx context.Context, chatID string) (chatSeed, bool) {
	h.ensureSeed(ctx, chatID)
	h.mu.Lock()
	defer h.mu.Unlock()
	if seed := h.seeds[chatID]; seed != nil {
		return *seed, true
	}
	return chatSeed{}, false
}

// pendingSeed returns the seed the next prompt must carry: one not sent yet,
// or one whose carrier the chat's rewind point hides.
func (h *chatHub) pendingSeed(s Session) (chatSeed, bool) {
	seed, ok := h.seedCopy(context.Background(), s.ID)
	if !ok {
		return chatSeed{}, false
	}
	return seed, seed.deliveredAt.IsZero() || (s.RewindMessageID != "" && s.RewindMessageID == seed.carrier)
}

// markSeed records that the seed went out with carrier at deliveredAt, or
// (zero time) that it waits again, in the hub and in the archive.
func (h *chatHub) markSeed(key sessionKey, chatID, carrier string, deliveredAt time.Time) {
	h.mu.Lock()
	seed := h.seeds[chatID]
	if seed == nil {
		h.mu.Unlock()
		return
	}
	seed.carrier, seed.deliveredAt = carrier, deliveredAt
	provider := ""
	if c := h.chats[key]; c != nil {
		provider = c.provider.name()
		if entry, _ := c.find(chatSeedMessageID); entry != nil {
			c.updateHeader(entry, seed.message(chatID, provider), 0)
		}
	}
	message := seed.message(chatID, provider)
	h.mu.Unlock()
	if h.capture != nil {
		h.capture.written(chatID, h.capture.archive.UpsertMessage(archiveMessageFromChat(message, chatID)))
	}
}

// chatSeedRecord reads a chat's seed from the archive; nil when it has none.
func (a *Archive) chatSeedRecord(ctx context.Context, chatID string) (*chatSeed, error) {
	seed := &chatSeed{}
	var created int64
	var delivered sql.NullInt64
	err := a.readDB.QueryRowContext(ctx, `SELECT m.created_at, m.completed_at, p.text FROM messages m JOIN parts p ON p.message_pk = m.pk
		WHERE m.chat_id = ? AND m.id = ? AND p.kind = 'context' ORDER BY p.ord LIMIT 1`, chatID, chatSeedMessageID).Scan(&created, &delivered, &seed.text)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	seed.createdAt = time.UnixMilli(created).UTC()
	if delivered.Valid {
		seed.deliveredAt = time.UnixMilli(delivered.Int64).UTC()
		err = a.readDB.QueryRowContext(ctx, `SELECT id FROM messages WHERE chat_id = ? AND role = 'user' AND id != ? ORDER BY ord, pk LIMIT 1`, chatID, chatSeedMessageID).Scan(&seed.carrier)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
	}
	if err := a.readDB.QueryRowContext(ctx, `SELECT provider, model, mode, effort FROM chats WHERE id = ?`, chatID).Scan(&seed.provider, &seed.model, &seed.mode, &seed.effort); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	return seed, nil
}

// withSeedPage adds a continued chat's seed to GET /v1/chat/messages: the
// provider's copy of the carrying message without the seed, and the seed
// message itself on the last page.
func (h *Host) withSeedPage(s Session, provider chatProvider, messages []ChatMessage, hasMore bool, limit int) ([]ChatMessage, bool) {
	seed, ok := h.chat.seedCopy(context.Background(), s.ID)
	if !ok {
		return messages, hasMore
	}
	for index := range messages {
		messages[index] = seed.strip(messages[index])
	}
	if !hasMore {
		if len(messages) < limit {
			messages = append(messages, seed.message(s.ID, provider.name()))
		} else {
			hasMore = true
		}
	}
	return messages, hasMore
}

// Seed.

type continueSeed struct {
	text                     string
	included, omitted, chars int
}

type seedEntry struct {
	text         string
	chars, bytes int // including the blank line before it
}

func newSeedEntry(text string) seedEntry {
	return seedEntry{text: text, chars: utf8.RuneCountInString(text) + 2, bytes: len(text) + 2}
}

// clipped shortens an entry to fit, keeping its start.
func (e seedEntry) clipped(chars, bytes int) seedEntry {
	if e.chars <= chars && e.bytes <= bytes {
		return e
	}
	const mark = "\n[… shortened]"
	keepChars, keepBytes := chars-2-utf8.RuneCountInString(mark), bytes-2-len(mark)
	// end is the longest prefix, on a character boundary, within both bounds.
	end, count := 0, 0
	for index := range e.text {
		if count > keepChars || index > keepBytes {
			break
		}
		end, count = index, count+1
	}
	return newSeedEntry(strings.TrimRight(e.text[:end], " \n") + mark)
}

// errContinueThrough: throughMessageId names no message the source chat
// shows (unknown, or hidden by a rewind).
var errContinueThrough = errors.New("the chat does not show that message")

// errSeedThroughReached stops reading the source after its through message.
var errSeedThroughReached = errors.New("the seed's last message was read")

// buildContinueSeed renders the seed of a continued chat from its archived
// messages; an empty text means nothing could be carried. A through message
// ends the source there: the seed keeps its first user message and the
// newest messages up to and including it, and leaves the later ones out.
func (a *Archive) buildContinueSeed(ctx context.Context, chat archiveChatJSON, budget int, through string) (continueSeed, error) {
	source := chat.Title
	if source == "" {
		source = "Untitled chat"
	}
	labels := []string{chat.Provider}
	if chat.Model != "" {
		labels = append(labels, chat.Model)
	}
	held := "the most recent messages"
	if through != "" {
		held = "the most recent messages up to a point the user chose (later messages are left out)"
	}
	header := fmt.Sprintf("Context from an earlier chat, %q (%s), continued here with another model. It holds the first user message and %s; tool calls are summarized in one line each and reasoning is left out.",
		archiveLabel(source, 200), strings.Join(labels, ", "), held)
	const footer = "End of the earlier chat. The new message follows."
	const markerLimit = "[9999999 messages in between are left out.]"
	reserve := newSeedEntry(header).chars + newSeedEntry(footer).chars + newSeedEntry(markerLimit).chars
	reserveBytes := len(header) + len(footer) + len(markerLimit) + 6
	budgetChars, budgetBytes := budget-reserve, continueSeedBytes-reserveBytes

	tx, err := a.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return continueSeed{}, err
	}
	defer tx.Rollback()
	if through != "" {
		var hidden bool
		err := tx.QueryRowContext(ctx, `SELECT hidden FROM messages WHERE chat_id = ? AND id = ?`, chat.ID, through).Scan(&hidden)
		switch {
		case errors.Is(err, sql.ErrNoRows) || (err == nil && hidden):
			return continueSeed{}, errContinueThrough
		case err != nil:
			return continueSeed{}, err
		}
	}
	var first *seedEntry
	var newest []seedEntry // the latest messages that may fit, oldest first
	sumChars, sumBytes, eligible := 0, 0, 0
	visit := func(message archiveMessageJSON) {
		if message.Hidden || message.ID == chatSeedMessageID {
			return
		}
		text := renderSeedMessage(message)
		if text == "" {
			return
		}
		eligible++
		entry := newSeedEntry(text).clipped(budgetChars, budgetBytes)
		if first == nil && message.Role == "user" {
			first = &entry
			return
		}
		newest = append(newest, entry)
		sumChars, sumBytes = sumChars+entry.chars, sumBytes+entry.bytes
		// Older entries that the newer ones already crowd out can go.
		for len(newest) > 1 && (sumChars-newest[0].chars >= budgetChars || sumBytes-newest[0].bytes >= budgetBytes) {
			sumChars, sumBytes = sumChars-newest[0].chars, sumBytes-newest[0].bytes
			newest = newest[1:]
		}
	}
	err = archiveEachMessage(ctx, tx, chat.ID, func(message archiveMessageJSON) error {
		visit(message)
		if through != "" && message.ID == through {
			return errSeedThroughReached
		}
		return nil
	})
	if errors.Is(err, errSeedThroughReached) {
		err = nil
	}
	if err != nil || eligible == 0 {
		return continueSeed{}, err
	}
	leftChars, leftBytes := budgetChars, budgetBytes
	var blocks []string
	included := 0
	if first != nil {
		kept := first.clipped(leftChars, leftBytes)
		blocks = append(blocks, kept.text)
		leftChars, leftBytes = leftChars-kept.chars, leftBytes-kept.bytes
		included++
	}
	var latest []string
	for index := len(newest) - 1; index >= 0; index-- {
		entry := newest[index]
		if entry.chars <= leftChars && entry.bytes <= leftBytes {
			latest = append(latest, entry.text)
			leftChars, leftBytes = leftChars-entry.chars, leftBytes-entry.bytes
			continue
		}
		// The newest message alone is too large: keep its start.
		if len(latest) == 0 && leftChars >= 200 && leftBytes >= 200 {
			latest = append(latest, entry.clipped(leftChars, leftBytes).text)
		}
		break
	}
	slices.Reverse(latest)
	included += len(latest)
	omitted := eligible - included
	if omitted > 0 {
		blocks = append(blocks, fmt.Sprintf("[%d messages in between are left out.]", omitted))
	}
	blocks = append(blocks, latest...)
	text := header + "\n\n" + strings.Join(blocks, "\n\n") + "\n\n" + footer
	return continueSeed{text: text, included: included, omitted: omitted, chars: utf8.RuneCountInString(text)}, nil
}

// renderSeedMessage writes one message for the seed; empty when it has
// nothing to carry (reasoning, notices and earlier seeds are left out).
func renderSeedMessage(message archiveMessageJSON) string {
	var lines, files []string
	for _, part := range message.Parts {
		switch part.Kind {
		case "text":
			if text := strings.TrimSpace(part.Text); text != "" {
				lines = append(lines, text)
			}
		case "tool":
			if part.Tool != nil {
				lines = append(lines, seedToolLine(part.Tool))
			}
		case "attachment":
			if part.Attachment != nil {
				files = append(files, part.Attachment.Name)
			}
		case "patch":
			if changed := strings.Fields(part.Text); len(changed) > 0 {
				if len(changed) > 20 {
					changed = append(changed[:20], fmt.Sprintf("and %d more", len(changed)-20))
				}
				lines = append(lines, "[Changed files: "+strings.Join(changed, ", ")+"]")
			}
		}
	}
	if len(files) > 0 {
		lines = append(lines, "[Attachments: "+strings.Join(files, ", ")+"]")
	}
	if len(lines) > 0 && message.Status == "aborted" {
		lines = append(lines, "[This reply was stopped before it finished.]")
	}
	if message.Error != nil && message.Error.Message != "" {
		lines = append(lines, "[This reply failed: "+seedLine(message.Error.Message, 300)+"]")
	}
	if len(lines) == 0 {
		return ""
	}
	heading := "User"
	if message.Role == "assistant" {
		heading = "Assistant"
		if message.Model != "" {
			heading += " (" + message.Model + ")"
		}
	}
	if when := seedTime(message.CreatedAt); when != "" {
		heading += " · " + when
	}
	return "### " + heading + "\n" + strings.Join(lines, "\n")
}

// seedToolLine summarizes a tool call in one line: its title, or the start
// of its input.
func seedToolLine(tool *archiveToolJSON) string {
	about := tool.Title
	if about == "" {
		about = tool.Input
	}
	line := "[Tool " + seedLine(tool.Name, 60)
	if about = seedLine(about, 160); about != "" {
		line += ": " + about
	}
	return line + " (" + tool.Status + ")]"
}

// seedLine flattens text to one line of at most limit characters.
func seedLine(text string, limit int) string {
	text = strings.Join(strings.Fields(text), " ")
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	runes := []rune(text)
	return string(runes[:limit-1]) + "…"
}

func seedTime(value string) string {
	parsed := parseChatTime(value)
	if parsed.IsZero() {
		return ""
	}
	return parsed.UTC().Format("2006-01-02 15:04 UTC")
}

// Route.

type continueSeedInfo struct {
	Included int `json:"included"`
	Omitted  int `json:"omitted"`
	Chars    int `json:"chars"`
}

// continueResponse is the new chat, with ParentSessionID naming the source
// as a fork's does, and the seed's size.
type continueResponse struct {
	Session
	Seed continueSeedInfo `json:"seed"`
}

// chatProviderNamed returns the provider for new chats of that name, as
// chatProviderFor picks it for their session IDs.
func (h *Host) chatProviderNamed(name string) chatProvider {
	// ACP chats: an agent that can run them now.
	if name != "opencode" && name != "claude" && name != "codex" {
		if h.cliChats == nil || !h.cliChats.acp.offers(name) {
			return nil
		}
		return h.cliChats.acpProviderFor("", name)
	}
	id := "continue"
	if name != "opencode" {
		id = name + ":continue"
	}
	provider := h.chatProviderFor(Session{ID: id})
	if provider == nil || provider.name() != name {
		return nil
	}
	return provider
}

// continueOptions checks a continue's model, mode and effort for the new
// chat's provider and returns them as the options of its first prompt: an
// OpenCode or Claude Code mode is the agent; Codex takes a mode and effort
// through its engine.
func (h *Host) continueOptions(provider, model, mode, effort string) (PromptOptions, bool) {
	if provider == "codex" && h.cliChats != nil && h.cliChats.codex != nil {
		options := PromptOptions{Model: model, Mode: mode, Effort: effort}
		_, ok := codexSettings{mode: codexDefaultMode}.with(options)
		return options, ok
	}
	// Claude Code streaming (claude_provider.go): a permission mode and an
	// effort go to the Claude engine.
	if provider == "claude" && h.cliChats != nil && h.cliChats.claude != nil {
		options := PromptOptions{Model: model, Mode: mode, Effort: effort}
		return options, claudeValidOptions(options)
	}
	options := PromptOptions{Model: model, Agent: mode}
	if effort != "" || !validPromptOptions(options) {
		return options, false
	}
	if provider != "opencode" && !cliOptionsSupported(provider, options) {
		return options, false
	}
	return options, true
}

// continueChat is POST /v1/chat/continue.
func (h *Host) continueChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID       string `json:"projectId"`
		SourceSessionID string `json:"sourceSessionId"`
		Provider        string `json:"provider"`
		Model           string `json:"model,omitempty"`
		Mode            string `json:"mode,omitempty"`
		Effort          string `json:"effort,omitempty"`
		Title           string `json:"title,omitempty"`
		ContextChars    *int   `json:"contextChars,omitempty"`
		// continueThrough: the seed ends with this message of the source.
		ThroughMessageID string `json:"throughMessageId,omitempty"`
	}
	if !decode(w, r, &in) || !h.archiveAvailable(w) {
		return
	}
	budget := continueDefaultChars
	if in.ContextChars != nil {
		budget = *in.ContextChars
	}
	switch {
	case budget < continueMinimumChars || budget > continueMaximumChars:
		writeError(w, 400, "invalid_request", "contextChars must be between 1000 and 200000")
		return
	case in.SourceSessionID == "" || len(in.SourceSessionID) > archiveIDLimit:
		writeError(w, 400, "invalid_request", "Choose the chat to continue")
		return
	case len(in.Title) > 200:
		writeError(w, 400, "invalid_request", "Title is too long")
		return
	case len(in.Model) > 512 || len(in.Mode) > 64 || len(in.Effort) > 64:
		writeError(w, 400, "invalid_request", "Choose a valid model, mode and effort")
		return
	case len(in.ThroughMessageID) > archiveIDLimit:
		writeError(w, 400, "invalid_through_message", "Choose a message the chat still shows")
		return
	}
	p, err := h.chatProject(in.ProjectID)
	if err != nil {
		notFound(w)
		return
	}
	// Plain chats: a plain chat continues in a plain chat, with OpenCode's
	// chat agent.
	plain := h.isPlainChat(p)
	// Subscriptions only, for every Claude Code and Codex chat.
	if !h.chatProviderReady(w, r, p, in.Provider) {
		return
	}
	if plain && plainChatOptionsRefused(w, in.Mode) {
		return
	}
	if !slices.Contains(h.advertisedCapabilities().ChatProviders, in.Provider) {
		writeError(w, 400, "invalid_provider", "Choose an available Mac agent")
		return
	}
	if _, ok := h.continueOptions(in.Provider, in.Model, in.Mode, in.Effort); !ok {
		writeError(w, 400, "invalid_agent_options", "Choose settings supported by this Mac agent")
		return
	}
	// Bring the source up to date while its provider still has it; without
	// it, the archive's copy is used as it is. A Chats-space source is
	// brought up to date there.
	sourceProject := p
	if !plain && h.plainChats != nil {
		if known, err := h.archive.ArchivedChat(r.Context(), in.SourceSessionID); err == nil && known.ProjectID == plainChatsProjectID {
			sourceProject = h.plainChats.project()
		}
	}
	h.refreshArchivedChat(r.Context(), sourceProject, in.SourceSessionID)
	source, ok := h.visibleArchivedChat(w, r, in.SourceSessionID)
	if !ok {
		return
	}
	// Plain chats: nothing continues into the Chats space from a workspace.
	// A Chats-space chat continues there, or (since Chat runs in the
	// workspaces, 2026-10-12) in a workspace's Claude Code or Codex chat,
	// with the conversation as the new chat's context; nothing is sent.
	sourcePlain := h.plainChats != nil && source.ProjectID == plainChatsProjectID
	intoWorkspace := sourcePlain && !plain && (in.Provider == "claude" || in.Provider == "codex")
	if plain != sourcePlain && !intoWorkspace {
		writeError(w, 400, plainChatScopeCode, "A plain chat continues in a plain chat or a workspace's Claude Code or Codex chat, and a workspace's chat only in its workspace")
		return
	}
	if source.ProjectID != p.ID && !intoWorkspace {
		writeError(w, 404, "not_found", "Archived chat not found")
		return
	}
	if plain && source.Provider != "" && source.Provider != in.Provider {
		writeError(w, 400, plainChatProviderCode, "Continue this chat with its original provider")
		return
	}
	seed, err := h.archive.buildContinueSeed(r.Context(), source, budget, in.ThroughMessageID)
	if errors.Is(err, errContinueThrough) {
		writeError(w, 400, "invalid_through_message", "Choose a message the chat still shows")
		return
	}
	if err != nil {
		archiveFailure(w)
		return
	}
	if h.archive.chatPaused.Load() {
		writeError(w, 507, "insufficient_storage", "This Mac is too low on disk space to keep the new chat")
		return
	}
	provider := h.chatProviderNamed(in.Provider)
	if provider == nil {
		writeError(w, 503, "agent_unavailable", "This Mac agent is unavailable")
		return
	}
	title := in.Title
	if title == "" {
		title = continueTitle(source.Title)
	}
	created, err := provider.create(p, title)
	if errors.Is(err, ErrCLIChatUnavailable) || errors.Is(err, errACPUnavailable) || errors.Is(err, errPlainChatUnavailable) {
		writeError(w, 503, "agent_unavailable", "This Mac agent is unavailable")
		return
	}
	if err != nil {
		internal(w)
		return
	}
	s, err := h.session(p, created.ID)
	if err != nil {
		internal(w)
		return
	}
	now := h.now()
	capture := &chatCapture{archive: h.archive}
	capture.written(s.ID, h.archive.UpsertChat(ArchiveChat{ID: s.ID, ProjectID: p.ID, Provider: in.Provider, Title: s.Title, TitleSource: s.TitleSource, TitleBasis: s.TitleBasis, Model: in.Model, Mode: in.Mode, Effort: in.Effort,
		ParentID: source.ID, Relation: "continue", CreatedAt: now, UpdatedAt: now}))
	if seed.text != "" {
		stored := &chatSeed{text: seed.text, createdAt: time.UnixMilli(now.UnixMilli()).UTC(), provider: in.Provider, model: in.Model, mode: in.Mode, effort: in.Effort}
		capture.written(s.ID, h.archive.UpsertMessage(archiveMessageFromChat(stored.message(s.ID, in.Provider), s.ID)))
		h.chat.registerSeed(s.ID, stored)
	}
	ctx, cancel := context.WithTimeout(r.Context(), archiveDeliveryWait)
	defer cancel()
	capture.written(s.ID, h.archive.Flush(ctx))
	s.ParentSessionID = source.ID
	writeJSON(w, 201, continueResponse{Session: s, Seed: continueSeedInfo{Included: seed.included, Omitted: seed.omitted, Chars: seed.chars}})
}

// continueTitle names a continued chat after its source.
func continueTitle(source string) string {
	if source == "" {
		return "Continued chat"
	}
	title, _ := clipText(source, 188)
	return title + " (continued)"
}
