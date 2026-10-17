package host

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Chat event stream limits (docs/HOST-API.md "Chat event stream").
const (
	chatStreamLifetime   = 120 * time.Second
	chatBeatInterval     = 10 * time.Second
	chatAuthInterval     = 30 * time.Second
	chatWriteTimeout     = 20 * time.Second
	chatStreamPace       = 33 * time.Millisecond
	chatStreamsPerDevice = 8
	chatPageLimit        = 50
	chatPageBytes        = 8 << 20
)

var alreadyClosed = func() chan struct{} {
	closed := make(chan struct{})
	close(closed)
	return closed
}()

type evControl struct {
	Seq     uint64 `json:"seq"`
	Type    string `json:"type"`
	Cursor  string `json:"cursor,omitempty"`
	Resumed *bool  `json:"resumed,omitempty"`
}

func (h *Host) acquireChatStream(device string) bool {
	h.chatStreamsMu.Lock()
	defer h.chatStreamsMu.Unlock()
	if h.chatStreams == nil {
		h.chatStreams = map[string]int{}
	}
	if h.chatStreams[device] >= chatStreamsPerDevice {
		return false
	}
	h.chatStreams[device]++
	return true
}

func (h *Host) releaseChatStream(device string) {
	h.chatStreamsMu.Lock()
	defer h.chatStreamsMu.Unlock()
	if h.chatStreams[device]--; h.chatStreams[device] <= 0 {
		delete(h.chatStreams, device)
	}
}

// chatEvents streams one chat as NDJSON: ready, a snapshot unless the cursor
// resumes, then events from the chat's shared ring, a beat every 10 s and end
// after 120 s. Authorization matches GET /v1/messages and is rechecked while
// the stream is open.
func (h *Host) chatEvents(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	p, s, ok := h.chatScoped(w, query.Get("projectId"), query.Get("sessionId"))
	if !ok {
		return
	}
	provider := h.chatProviderFor(s)
	if provider == nil || provider.transport() == "" {
		writeError(w, 501, "unsupported_operation", "This host cannot stream this chat")
		return
	}
	after := query.Get("after")
	if len(after) > 64 {
		writeError(w, 400, "invalid_request", "The cursor is not valid")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		internal(w)
		return
	}
	select {
	case <-h.stopping:
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.WriteHeader(200)
		w.Write(append(marshalJSONLine(evControl{Type: "stopping"}), '\n'))
		return
	default:
	}
	if !h.acquireChatStream(device.ID) {
		writeError(w, 429, "stream_limit", "Close another chat stream on this device first; each device may stream 8 chats")
		return
	}
	defer h.releaseChatStream(device.ID)
	chat, err := h.chat.subscribe(r.Context(), p, s, provider)
	switch {
	case errors.Is(err, ErrNotFound):
		notFound(w)
		return
	case errors.Is(err, errChatHubFull):
		writeError(w, 503, "chat_streams_busy", "Too many chats are open on this host; close some and try again")
		return
	case errors.Is(err, errChatHubClosed):
		writeError(w, 503, "host_stopping", "The host is stopping")
		return
	case r.Context().Err() != nil:
		return
	case err != nil:
		internal(w)
		return
	}
	defer h.chat.unsubscribe(chat)
	stream := chatStream{host: h, w: w, flusher: flusher, controller: http.NewResponseController(w), r: r, project: p.ID}
	stream.run(chat, after)
}

type chatStream struct {
	host       *Host
	w          http.ResponseWriter
	flusher    http.Flusher
	controller *http.ResponseController
	r          *http.Request
	project    string
	epoch      string
	seq        uint64
	buffer     []byte
}

// write sends buffered lines. Each write gets its own deadline, so a stream
// outlives the server's write timeout while a stuck reader still fails fast.
func (s *chatStream) flush() bool {
	if len(s.buffer) == 0 {
		return true
	}
	if s.host.chatExtendDeadlines {
		_ = s.controller.SetWriteDeadline(time.Now().Add(s.host.chatWriteWait))
	}
	_, err := s.w.Write(s.buffer)
	s.buffer = s.buffer[:0]
	if cap(s.buffer) > 1<<20 {
		// A large batch (at most the ring's 2 MiB) is not kept per stream.
		s.buffer = nil
	}
	if err != nil {
		return false
	}
	// The controller reports a failed flush, which http.Flusher cannot.
	return s.controller.Flush() == nil
}

func (s *chatStream) control(kind string, withCursor bool) {
	line := evControl{Seq: s.seq, Type: kind}
	if withCursor {
		line.Cursor = s.epoch + "." + strconv.FormatUint(s.seq, 10)
	}
	s.buffer = append(append(s.buffer, marshalJSONLine(line)...), '\n')
}

func (s *chatStream) body(body []byte) {
	s.buffer = append(s.buffer, `{"seq":`...)
	s.buffer = strconv.AppendUint(s.buffer, s.seq, 10)
	s.buffer = append(s.buffer, ',')
	s.buffer = append(append(s.buffer, body...), '\n')
}

// events appends ring events, joining consecutive deltas of one part field.
func (s *chatStream) events(events []ringEvent) {
	for index := 0; index < len(events); index++ {
		event := events[index]
		if event.delta == nil {
			s.seq = event.seq
			s.body(event.body)
			continue
		}
		merged := *event.delta
		size := jsonStringSize(merged.text)
		for index+1 < len(events) {
			next := events[index+1].delta
			if next == nil || next.messageID != merged.messageID || next.partID != merged.partID || next.field != merged.field || next.offset != merged.offset+len(merged.text) {
				break
			}
			nextSize := jsonStringSize(next.text)
			if size+nextSize > chatDeltaChunk {
				break
			}
			merged.text += next.text
			size += nextSize
			index++
		}
		s.seq = events[index].seq
		line := marshalJSONLine(evDelta{Seq: s.seq, Type: "part.delta", MessageID: merged.messageID, PartID: merged.partID, Field: merged.field, Offset: merged.offset, Delta: merged.text})
		s.buffer = append(append(s.buffer, line...), '\n')
	}
}

func (s *chatStream) run(chat *hubChat, after string) {
	h := s.host
	hub := h.chat
	if h.chatExtendDeadlines {
		_ = s.controller.SetReadDeadline(time.Now().Add(h.chatStreamFor + time.Minute))
	}
	s.w.Header().Set("Content-Type", "application/x-ndjson")
	s.w.WriteHeader(200)
	hub.mu.Lock()
	var snapshot []byte
	resumed := false
	if epoch, seq, ok := parseChatCursor(after); ok && epoch == chat.ring.epoch && chat.ring.holds(seq) {
		s.epoch, s.seq, resumed = epoch, seq, true
	} else {
		snapshot, s.seq = hub.snapshotLocked(chat)
		s.epoch = chat.ring.epoch
	}
	hub.mu.Unlock()
	ready := evControl{Seq: s.seq, Type: "ready", Cursor: s.epoch + "." + strconv.FormatUint(s.seq, 10), Resumed: &resumed}
	s.buffer = append(append(s.buffer, marshalJSONLine(ready)...), '\n')
	if snapshot != nil {
		s.body(snapshot)
	}
	if !s.flush() {
		return
	}
	lifetime := time.NewTimer(h.chatStreamFor)
	defer lifetime.Stop()
	beat := time.NewTicker(h.chatBeatEvery)
	defer beat.Stop()
	auth := time.NewTicker(h.chatAuthEvery)
	defer auth.Stop()
	var lastEvents time.Time
	for {
		hub.mu.Lock()
		if chat.removed {
			// The host is stopping, or the chat was deleted: a reconnect
			// learns which.
			closing := hub.closed
			hub.mu.Unlock()
			if closing {
				s.control("stopping", false)
			} else {
				s.control("end", true)
			}
			s.flush()
			return
		}
		var events []ringEvent
		more := false
		if s.epoch == chat.ring.epoch && chat.ring.holds(s.seq) {
			events, more = chat.ring.after(s.seq, chatReadBatch)
		} else {
			// The chat was rebuilt or this reader fell behind the ring.
			snapshot, s.seq = hub.snapshotLocked(chat)
			s.epoch = chat.ring.epoch
			s.body(snapshot)
		}
		var wake <-chan struct{} = chat.changed
		if more {
			// More events are waiting: continue without waiting on a change.
			wake = alreadyClosed
		}
		hub.mu.Unlock()
		if len(events) > 0 {
			s.events(events)
			lastEvents = time.Now()
		}
		if !s.flush() {
			return
		}
		select {
		case <-s.r.Context().Done():
			return
		case <-h.stopping:
			s.control("stopping", false)
			s.flush()
			return
		case <-hub.done:
			s.control("stopping", false)
			s.flush()
			return
		case <-lifetime.C:
			s.control("end", true)
			s.flush()
			return
		case <-beat.C:
			s.control("beat", true)
		case <-auth.C:
			if _, ok := h.authenticate(s.r); !ok {
				s.control("unauthorized", false)
				s.flush()
				return
			}
			if _, err := h.chatProject(s.project); err != nil {
				s.control("end", true)
				s.flush()
				return
			}
		case <-wake:
			// Deltas arriving within one pace interval leave as one line.
			if pause := time.Until(lastEvents.Add(h.chatPace)); pause > 0 {
				timer := time.NewTimer(pause)
				select {
				case <-timer.C:
				case <-s.r.Context().Done():
				case <-h.stopping:
				case <-hub.done:
				}
				timer.Stop()
			}
		}
	}
}

// chatMessages pages a chat's messages in the unified model, newest first.
func (h *Host) chatMessages(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	p, s, ok := h.chatScoped(w, query.Get("projectId"), query.Get("sessionId"))
	if !ok {
		return
	}
	limit := chatPageLimit
	if raw := query.Get("limit"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 1 || value > chatPageLimit {
			writeError(w, 400, "invalid_request", "limit must be between 1 and 50")
			return
		}
		limit = value
	}
	before := query.Get("before")
	if len(before) > 256 {
		writeError(w, 400, "invalid_request", "The message is not valid")
		return
	}
	provider := h.chatProviderFor(s)
	if provider == nil {
		notFound(w)
		return
	}
	// Continue (M1 chunk B2): a continued chat's seed is its oldest message.
	if before == chatSeedMessageID {
		writeJSON(w, 200, map[string]any{"messages": []ChatMessage{}, "hasMore": false, "oldestId": ""})
		return
	}
	messages, hasMore, err := provider.page(p, s, before, limit)
	if errors.Is(err, ErrNotFound) {
		writeError(w, 404, "not_found", "Message not found")
		return
	}
	if err != nil {
		internal(w)
		return
	}
	messages, hasMore = h.withSeedPage(s, provider, messages, hasMore, limit)
	// Bound one page's size; the client pages on from the oldest it received.
	size := 0
	for index, message := range messages {
		if size += len(marshalJSONLine(message)); size > chatPageBytes && index > 0 {
			messages, hasMore = messages[:index], true
			break
		}
	}
	oldest := ""
	if len(messages) > 0 {
		oldest = messages[len(messages)-1].ID
	}
	writeJSON(w, 200, map[string]any{"messages": messages, "hasMore": hasMore, "oldestId": oldest})
}

// legacyMessageWithParts is GET /v1/messages?parts=1: the legacy message plus
// its ordered parts, creation time, model and usage.
type legacyMessageWithParts struct {
	Message
	Parts     []ChatPart `json:"parts"`
	CreatedAt string     `json:"createdAt,omitempty"`
	Model     string     `json:"model,omitempty"`
	Usage     *ChatUsage `json:"usage,omitempty"`
}

func (h *Host) messagesWithParts(p Project, s Session, items []Message) []legacyMessageWithParts {
	provider := "opencode"
	var transcript cliTranscript
	if isCLISessionID(s.ID) {
		provider = s.Provider
		transcript, _ = h.cliChats.transcript(p, s.ID)
	}
	unified := unifiedMessages(items, provider, s.ID, func(_ int, message Message) time.Time {
		if created, ok := transcript.created[message.ID]; ok {
			return created
		}
		return transcript.updated
	})
	result := make([]legacyMessageWithParts, len(items))
	for index, item := range items {
		message := unified[index]
		result[index] = legacyMessageWithParts{Message: item, Parts: message.Parts, CreatedAt: message.CreatedAt, Model: message.Model, Usage: message.Usage}
		// Codex streaming: streamed replies name their model.
		if isCLISessionID(s.ID) && item.Role == "assistant" && result[index].Model == "" {
			result[index].Model = provider + "/default"
		}
	}
	return result
}

// Send receipts make POST /v1/messages idempotent per device and chat: a
// repeated clientMessageId returns the first receipt and never sends again.
const (
	receiptsPerChat = 32
	receiptsTotal   = 1024
	receiptLifetime = 24 * time.Hour
)

const (
	receiptPending = iota
	receiptAccepted
	receiptUncertain
	receiptForgotten
)

type sendReceipt struct {
	Accepted  bool   `json:"accepted"`
	MessageID string `json:"messageId,omitempty"`
	TurnID    string `json:"turnId,omitempty"`
	Duplicate bool   `json:"duplicate,omitempty"`
}

type receiptKey struct{ device, project, session, client string }

type receiptEntry struct {
	state   int
	receipt sendReceipt
	done    chan struct{}
	at      time.Time
}

type sendReceipts struct {
	mu      sync.Mutex
	entries map[receiptKey]*receiptEntry
	order   []receiptKey
	now     func() time.Time
}

func newSendReceipts() *sendReceipts {
	return &sendReceipts{entries: map[receiptKey]*receiptEntry{}, now: time.Now}
}

// validClientMessageID accepts 32 to 64 letters, digits, '-' and '_'.
func validClientMessageID(id string) bool {
	if len(id) < 32 || len(id) > 64 {
		return false
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

// reserve returns a new pending entry, or the existing one for a repeat.
func (s *sendReceipts) reserve(key receiptKey) (*receiptEntry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if entry := s.entries[key]; entry != nil {
		if entry.state == receiptPending || now.Sub(entry.at) < receiptLifetime {
			return entry, true
		}
		s.dropLocked(key)
	}
	s.pruneLocked(key, now)
	entry := &receiptEntry{state: receiptPending, done: make(chan struct{}), at: now}
	s.entries[key] = entry
	s.order = append(s.order, key)
	return entry, false
}

func (s *sendReceipts) dropLocked(key receiptKey) {
	delete(s.entries, key)
	for index, other := range s.order {
		if other == key {
			s.order = append(s.order[:index], s.order[index+1:]...)
			break
		}
	}
}

// pruneLocked removes expired receipts, then the oldest settled ones while
// the chat or the host holds too many.
func (s *sendReceipts) pruneLocked(key receiptKey, now time.Time) {
	kept := s.order[:0]
	for _, other := range s.order {
		if entry := s.entries[other]; entry.state != receiptPending && now.Sub(entry.at) >= receiptLifetime {
			delete(s.entries, other)
			continue
		}
		kept = append(kept, other)
	}
	s.order = kept
	sameChat := func(other receiptKey) bool {
		return other.device == key.device && other.project == key.project && other.session == key.session
	}
	for _, limit := range []struct {
		max   int
		match func(receiptKey) bool
	}{{receiptsPerChat - 1, sameChat}, {receiptsTotal - 1, func(receiptKey) bool { return true }}} {
		count := 0
		for _, other := range s.order {
			if limit.match(other) {
				count++
			}
		}
		for index := 0; count > limit.max && index < len(s.order); {
			other := s.order[index]
			if limit.match(other) && s.entries[other].state != receiptPending {
				s.dropLocked(other)
				count--
				continue
			}
			index++
		}
	}
}

func (s *sendReceipts) settle(key receiptKey, entry *receiptEntry, state int, receipt sendReceipt) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry.state, entry.receipt, entry.at = state, receipt, s.now()
	if state == receiptForgotten && s.entries[key] == entry {
		s.dropLocked(key)
	}
	close(entry.done)
}

func (s *sendReceipts) outcome(entry *receiptEntry) (int, sendReceipt) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return entry.state, entry.receipt
}

// awaitReceipt waits for a send with the same clientMessageId to finish. It
// reports whether the caller may send (the earlier attempt definitely did
// not deliver) after writing any response itself.
func (h *Host) awaitReceipt(ctx context.Context, w http.ResponseWriter, entry *receiptEntry) bool {
	select {
	case <-entry.done:
	case <-ctx.Done():
		return false
	case <-h.stopping:
		writeError(w, 503, "host_stopping", "The host is stopping")
		return false
	}
	state, receipt := h.receipts.outcome(entry)
	switch state {
	case receiptAccepted:
		receipt.Duplicate = true
		writeJSON(w, 202, receipt)
	case receiptUncertain:
		writeError(w, 409, "delivery_uncertain", "An earlier send with this ID may have reached the agent; check the chat before sending it again")
	default:
		return true
	}
	return false
}
