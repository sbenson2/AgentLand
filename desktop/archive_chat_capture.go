package host

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

// Chat capture (M1 chunk B2): the archive keeps every chat the chat hub
// holds, whichever provider feeds it. Capture reads the hub's materialized
// state, never a provider's own format, so a new provider that updates the
// hub through its message, part, delta, info and interaction methods is
// captured without changes here.
//
//   - A message is written when the hub adds or changes it: user messages,
//     finished replies, status changes and provider reads at once, a
//     streaming reply at most once a second (chatCaptureInterval), so a
//     crash loses little. Each write is a full snapshot; the archive skips
//     identical ones.
//   - The chat row goes first in every batch, with the hub's title, model,
//     mode and effort, and the activity times of the messages in the window.
//   - Interactions are recorded when requested and when resolved, with the
//     outcome and a one-line summary (the tool or the question), never an
//     answer: answers do not pass through the hub.
//   - A rewind hides the archived messages from the rewind point on; a
//     restore writes them again. A message the provider removes stays
//     archived as last seen.
//   - deliverPrompt writes the user message and flushes it before the
//     provider sees it (prepareDelivery), after copying its attachments into
//     the archive, and follows the chat through its turn so the reply is
//     captured even when no device streams the chat.
//
// The hub holds at most 32 chats and only those someone streams or a send
// follows; the backfill (archive_backfill.go) imports the rest.
const (
	chatCaptureInterval = time.Second
	// chatFollowGrace is how long a followed chat stays in the hub waiting
	// for its turn to start; a turn in progress holds it until it ends.
	chatFollowGrace    = 2 * time.Minute
	chatFollowLoadWait = 10 * time.Second
	// archiveDeliveryWait bounds making a user message durable; delivery
	// goes ahead afterwards whatever the archive does.
	archiveDeliveryWait = 5 * time.Second
)

// chatCapture writes the hub's changes to the archive. Its loop runs from
// the first tracked chat until the hub closes.
type chatCapture struct {
	hub     *chatHub
	archive *Archive
	every   time.Duration
	wake    chan struct{}
	running bool // under hub.mu
}

// chatCaptureState is one chat's changes not yet written, under hub.mu.
type chatCaptureState struct {
	info         bool
	dirty        map[string]bool
	held         []ChatMessage // changed messages that left the window
	interactions []ArchiveInteraction
	hideFrom     string
	urgent       bool
	since        time.Time // first change not yet written
}

// captureBatch is one chat's writes, made outside the hub's lock.
type captureBatch struct {
	chat         ArchiveChat
	messages     []ArchiveMessage
	interactions []ArchiveInteraction
	hideFrom     string
}

func (c *chatCapture) notify() {
	if c != nil {
		notifyArchive(c.wake)
	}
}

// mark records that the chat has something to write. The loop is woken when
// the chat was clean (to time its next write) or the change is urgent.
func (c *hubChat) mark(urgent bool) {
	state := &c.captured
	wake := state.since.IsZero() || (urgent && !state.urgent)
	if state.since.IsZero() {
		state.since = c.capture.hub.now()
	}
	state.urgent = state.urgent || urgent
	if wake {
		c.capture.notify()
	}
}

func (c *hubChat) noteMessage(id string, urgent bool) {
	if c.capture == nil {
		return
	}
	if c.captured.dirty == nil {
		c.captured.dirty = map[string]bool{}
	}
	c.captured.dirty[id] = true
	c.mark(urgent)
}

func (c *hubChat) noteInfo(urgent bool) {
	if c.capture == nil {
		return
	}
	c.captured.info = true
	c.mark(urgent)
}

// noteInteraction records a requested (outcome "") or resolved interaction.
func (c *hubChat) noteInteraction(interaction ChatInteraction, outcome string) {
	if c.capture == nil {
		return
	}
	record := ArchiveInteraction{ID: interaction.ID, ChatID: c.key.sessionID, Kind: interaction.Kind, Summary: interactionSummary(interaction), CreatedAt: parseChatTime(interaction.CreatedAt)}
	switch outcome {
	case "":
	case "once", "always", "reject", "answered", "rejected":
		record.Outcome = outcome
	default:
		// "gone": the interaction disappeared without a reply the host saw.
		record.Outcome = "expired"
	}
	if outcome != "" {
		record.ResolvedAt = c.capture.hub.now()
	}
	c.captured.interactions = append(c.captured.interactions, record)
	c.mark(true)
}

// holdCaptured keeps the last state of a changed message that leaves the
// window, so it is still written.
func (c *hubChat) holdCaptured(entry *hubMessage) {
	if c.capture == nil || !c.captured.dirty[entry.header.ID] {
		return
	}
	delete(c.captured.dirty, entry.header.ID)
	c.captured.held = append(c.captured.held, entry.full())
}

// captureRewind hides the archived messages from the rewind point on.
func (c *hubChat) captureRewind(messageID string) {
	if c.capture == nil {
		return
	}
	c.captured.hideFrom = messageID
	c.mark(true)
}

func (c *hubChat) pendingCapture() bool {
	return c.capture != nil && !c.captured.since.IsZero()
}

// turnEnded releases a follow once the turn that began after it ends.
func (c *hubChat) turnEnded() {
	if c.following && c.followStarted {
		c.following, c.followStarted = false, false
		if c.capture != nil {
			c.lastActive = c.capture.hub.now()
		}
	}
}

// followedLocked reports whether a follow still holds the chat: while its
// turn runs, or for the grace period while none has started.
func (c *hubChat) followedLocked(now time.Time) bool {
	return c.following && (running(c.status.State) || now.Before(c.followUntil))
}

func (h *chatHub) ensureCaptureLocked() {
	if h.capture == nil || h.capture.running || h.closed {
		return
	}
	h.capture.running = true
	h.work.Add(1)
	go h.captureLoop()
}

func (h *chatHub) captureLoop() {
	defer h.work.Done()
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	for {
		h.mu.Lock()
		batches, wait := h.collectCaptureLocked(false)
		h.mu.Unlock()
		h.capture.write(batches)
		if wait <= 0 {
			wait = time.Hour
		}
		timer.Reset(wait)
		select {
		case <-h.done:
			return
		case <-h.capture.wake:
		case <-timer.C:
		}
	}
}

// collectCaptureLocked takes the changes that are due (all of them when all
// is set) and returns how long until the next one is due (zero: none).
func (h *chatHub) collectCaptureLocked(all bool) ([]captureBatch, time.Duration) {
	batches := h.captureRemoved
	h.captureRemoved = nil
	now := h.now()
	var wait time.Duration
	for _, c := range h.chats {
		if !c.pendingCapture() {
			continue
		}
		due := c.captured.since.Add(h.capture.every)
		if all || c.captured.urgent || !now.Before(due) {
			batches = append(batches, h.captureBatchLocked(c))
			continue
		}
		if next := due.Sub(now); wait == 0 || next < wait {
			wait = next
		}
	}
	return batches, wait
}

// captureBatchLocked takes one chat's changes, leaving it clean.
func (h *chatHub) captureBatchLocked(c *hubChat) captureBatch {
	state := c.captured
	c.captured = chatCaptureState{}
	batch := captureBatch{chat: c.archiveChat(), interactions: state.interactions, hideFrom: state.hideFrom}
	for _, message := range state.held {
		batch.messages = append(batch.messages, archiveMessageFromChat(message, c.key.sessionID))
	}
	for _, entry := range c.messages {
		if state.dirty[entry.header.ID] {
			batch.messages = append(batch.messages, archiveMessageFromChat(entry.full(), c.key.sessionID))
		}
	}
	return batch
}

// archiveChat is the chat row: the hub's metadata and the activity times of
// the messages in its window. The creation time is known only when the
// window reaches the start of the chat.
func (c *hubChat) archiveChat() ArchiveChat {
	chat := ArchiveChat{ID: c.key.sessionID, ProjectID: c.key.projectID, Provider: c.provider.name(), Title: c.info.Title, TitleSource: c.info.TitleSource, TitleBasis: c.info.TitleBasis, Model: c.info.Model, Mode: c.info.Mode, Effort: c.info.Effort}
	var first, last time.Time
	for _, entry := range c.messages {
		created, completed := parseChatTime(entry.header.CreatedAt), parseChatTime(entry.header.CompletedAt)
		if !created.IsZero() && (first.IsZero() || created.Before(first)) {
			first = created
		}
		for _, at := range []time.Time{created, completed} {
			if at.After(last) {
				last = at
			}
		}
	}
	if !c.hasOlder {
		chat.CreatedAt = first
	}
	chat.UpdatedAt = last
	return chat
}

// write makes a batch's writes in order: the chat, its messages, its
// interactions, then a rewind's hiding.
func (c *chatCapture) write(batches []captureBatch) {
	for _, batch := range batches {
		if !c.written(batch.chat.ID, c.archive.UpsertChat(batch.chat)) {
			continue
		}
		for _, message := range batch.messages {
			c.written(batch.chat.ID, c.archive.UpsertMessage(message))
		}
		for _, interaction := range batch.interactions {
			c.written(batch.chat.ID, c.archive.RecordInteraction(interaction))
		}
		if batch.hideFrom != "" {
			c.written(batch.chat.ID, c.archive.HideMessagesFrom(batch.chat.ID, batch.hideFrom))
		}
	}
}

// written reports whether a write was accepted. Paused and closed archives
// are expected; anything else is counted as a write error.
func (c *chatCapture) written(chatID string, err error) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, ErrArchivePaused), errors.Is(err, ErrArchiveClosed):
	default:
		c.archive.recordFailure(fmt.Errorf("capture chat %s: %w", chatID, err))
	}
	return false
}

// archiveMessageFromChat converts one message of the conversation model. The
// message's ord and times carry over, so archived messages sort as the live
// chat does.
func archiveMessageFromChat(message ChatMessage, chatID string) ArchiveMessage {
	result := ArchiveMessage{ID: message.ID, ChatID: chatID, TurnID: message.TurnID, Role: message.Role, Status: message.Status, Model: message.Model, Ord: message.Ord,
		CreatedAt: parseChatTime(message.CreatedAt), CompletedAt: parseChatTime(message.CompletedAt)}
	if usage := message.Usage; usage != nil {
		result.Usage = &ArchiveUsage{Input: usage.Input, Output: usage.Output, Reasoning: usage.Reasoning, CacheRead: usage.CacheRead, CacheWrite: usage.CacheWrite}
		if usage.CostMicros != nil {
			cost := *usage.CostMicros
			result.Usage.CostMicros = &cost
		}
	}
	if message.Error != nil {
		result.ErrorCode, result.ErrorMessage = message.Error.Code, message.Error.Message
	}
	result.Parts = make([]ArchivePart, 0, len(message.Parts))
	for _, part := range message.Parts {
		archived := ArchivePart{ID: part.ID, Kind: part.Kind, Text: part.Text, Start: parseChatTime(part.Start), End: parseChatTime(part.End), Truncated: part.Truncated}
		if tool := part.Tool; tool != nil {
			archived.Tool = &ArchiveTool{Name: tool.Name, CallID: tool.CallID, Status: tool.Status, Title: tool.Title, Input: tool.Input, Output: tool.Output, Error: tool.Error, Truncated: tool.Truncated,
				ChatToolResults: tool.ChatToolResults}
		}
		if attachment := part.Attachment; attachment != nil {
			archived.Attachment = &ArchiveAttachment{Name: attachment.Name, MIME: attachment.MIME}
		}
		result.Parts = append(result.Parts, archived)
	}
	return result
}

// interactionSummary names what an interaction was about, never an answer:
// the tool and its patterns for a permission, the questions' text for a
// question.
func interactionSummary(interaction ChatInteraction) string {
	if permission := interaction.Permission; permission != nil {
		if permission.Title == "" {
			return permission.Tool
		}
		return permission.Tool + ": " + permission.Title
	}
	texts := make([]string, 0, len(interaction.Questions))
	for _, question := range interaction.Questions {
		text := question.Text
		if text == "" {
			text = question.Header
		}
		texts = append(texts, text)
	}
	return strings.Join(texts, " / ")
}

// follow keeps a chat in the hub through its next turn, loading it when no
// device streams it, so the archive captures the turn. It is best effort: a
// chat the hub cannot hold is left to the backfill.
func (h *chatHub) follow(p Project, s Session, provider chatProvider) {
	// Notices (notices.go): the hub follows for them too, archive or not.
	if (h.capture == nil && !h.noticeFollow) || provider.transport() == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), chatFollowLoadWait)
	defer cancel()
	c, err := h.subscribe(ctx, p, s, provider)
	if err != nil {
		return
	}
	h.mu.Lock()
	c.following, c.followStarted = true, false
	c.followUntil = h.now().Add(h.followGrace)
	h.mu.Unlock()
	h.unsubscribe(c)
}

// busy reports whether any chat in the hub is running a turn; the backfill
// waits while one is.
func (h *chatHub) busy() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, c := range h.chats {
		if running(c.status.State) {
			return true
		}
	}
	return false
}

// nextOrd returns an ord after the chat's newest message in the hub.
func (h *chatHub) nextOrd(key sessionKey) (int64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if c == nil || len(c.messages) == 0 {
		return 0, false
	}
	return c.messages[len(c.messages)-1].header.Ord + 1, true
}

// nextMessageOrd returns an ord after the chat's newest archived message.
func (a *Archive) nextMessageOrd(ctx context.Context, chatID string) (int64, error) {
	var ord int64
	err := a.readDB.QueryRowContext(ctx, `SELECT COALESCE(max(ord), 0) + 1 FROM messages WHERE chat_id = ?`, chatID).Scan(&ord)
	return ord, err
}

// archiveDelivery is what deliverPrompt recorded before a send.
type archiveDelivery struct {
	chatID    string
	key       sessionKey
	messageID string
	seeded    bool
}

// messageIDMaker is a provider that names the user message before sending:
// OpenCode takes a host ID in its own format; the CLI chats use host IDs.
type messageIDMaker interface{ newMessageID(time.Time) string }

func (o openCodeProvider) newMessageID(now time.Time) string { return newOpenCodeMessageID(now) }
func (c cliProvider) newMessageID(time.Time) string          { return cliMessageID() }

// prepareDelivery runs before deliverPrompt sends a prompt, when the host
// keeps an archive. It follows the chat through its turn, prefixes a
// continued chat's pending seed (archive_continue.go), copies the
// attachments into the archive before the attachment store removes them,
// and makes the user message durable: written and flushed before the
// provider sees it. It sets prompt.messageID; the archive's copy carries the
// user's own text, without the seed.
func (h *Host) prepareDelivery(p Project, s Session, provider chatProvider, prompt *chatPrompt) *archiveDelivery {
	if h.archive == nil {
		// Notices (notices.go): without an archive the chat is still
		// followed through its turn, so its end is noticed.
		if h.chat.noticeFollow {
			h.chat.follow(p, s, provider)
		}
		return nil
	}
	now := h.now()
	key := sessionKey{p.ID, s.ID}
	h.chat.follow(p, s, provider)
	delivery := &archiveDelivery{chatID: s.ID, key: key}
	if maker, ok := provider.(messageIDMaker); ok {
		delivery.messageID = maker.newMessageID(now)
	} else {
		delivery.messageID = cliMessageID()
	}
	prompt.messageID = delivery.messageID
	text := prompt.text
	if seed, pending := h.chat.pendingSeed(s); pending {
		prompt.text = seed.text + chatSeedSeparator + prompt.text
		prompt.options = seed.defaults(prompt.options)
		delivery.seeded = true
	}
	message := ArchiveMessage{ID: delivery.messageID, ChatID: s.ID, TurnID: delivery.messageID, Role: "user", Status: "complete", Model: prompt.options.Model, CreatedAt: now}
	if ord, ok := h.chat.nextOrd(key); ok {
		message.Ord = ord
	} else if ord, err := h.archive.nextMessageOrd(context.Background(), s.ID); err == nil {
		message.Ord = ord
	}
	if text != "" {
		message.Parts = append(message.Parts, ArchivePart{ID: delivery.messageID + ":text", Kind: "text", Text: text})
	}
	for index, file := range prompt.files {
		attachment := &ArchiveAttachment{Name: file.Name, MIME: file.MIME, Size: file.Size}
		if sum, err := h.storeAttachmentBlob(file); err == nil {
			attachment.SHA256 = sum
		}
		message.Parts = append(message.Parts, ArchivePart{ID: fmt.Sprintf("%s:file:%d", delivery.messageID, index), Kind: "attachment", Attachment: attachment})
	}
	capture := &chatCapture{archive: h.archive}
	if !capture.written(s.ID, h.archive.UpsertChat(ArchiveChat{ID: s.ID, ProjectID: p.ID, Provider: provider.name(), Title: s.Title, TitleSource: s.TitleSource, TitleBasis: s.TitleBasis, UpdatedAt: now})) {
		return delivery
	}
	capture.written(s.ID, h.archive.UpsertMessage(message))
	ctx, cancel := context.WithTimeout(context.Background(), archiveDeliveryWait)
	defer cancel()
	capture.written(s.ID, h.archive.Flush(ctx))
	return delivery
}

// finishDelivery settles the archived user message after a send. When the
// provider certainly did not receive the prompt, the copy is removed and a
// seed waits for the next prompt. When the provider named the message
// itself, its copy arrives through the hub and replaces the host's. A seed
// counts as sent once the provider may have received it, so it is never
// sent again automatically after an uncertain delivery.
func (h *Host) finishDelivery(delivery *archiveDelivery, id string, err error, definite bool) {
	if delivery == nil {
		return
	}
	carrier := delivery.messageID
	switch {
	case err != nil && definite:
		_ = h.archive.DeleteMessage(delivery.chatID, delivery.messageID)
		return
	case err == nil && id != "" && id != delivery.messageID:
		_ = h.archive.DeleteMessage(delivery.chatID, delivery.messageID)
		carrier = id
	}
	if delivery.seeded {
		h.chat.markSeed(delivery.key, delivery.chatID, carrier, h.now())
	}
}

// storeAttachmentBlob copies one claimed upload into the archive.
func (h *Host) storeAttachmentBlob(file ChatAttachment) (string, error) {
	handle, err := os.Open(file.Path)
	if err != nil {
		return "", err
	}
	defer handle.Close()
	info, err := handle.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return "", errAttachmentUnreadable
	}
	sum, err := h.archive.StoreBlob(handle, file.MIME)
	if err != nil && !errors.Is(err, ErrArchivePaused) && !errors.Is(err, ErrArchiveClosed) {
		h.archive.recordFailure(fmt.Errorf("archive attachment: %w", err))
	}
	return sum, err
}

// deliveryDefinitelyFailed reports failures after which the provider cannot
// have received the prompt, as the send receipts judge them. A Claude Code
// prompt written without its replayed echo stays uncertain (claude_chat.go).
func deliveryDefinitelyFailed(s Session, err error) bool {
	return err != nil && ((isCLISessionID(s.ID) && !errors.Is(err, errDeliveryUncertain)) || promptNotDelivered(err))
}
