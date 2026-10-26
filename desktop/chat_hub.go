package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Bounds and timing of the chat hub. Every buffer it keeps is limited by
// count and by bytes; chats nobody watches are dropped and rebuilt from the
// provider when someone opens them again.
const (
	chatSnapshotMessages  = 40
	chatReconcileMessages = 20
	chatWindowMessages    = 60
	chatWindowBytes       = 1 << 20
	chatInteractionsLimit = 16
	chatRingEvents        = 2048
	chatRingBytes         = 2 << 20
	chatReadBatch         = 512
	// chatEventBudget bounds one event's JSON so the whole line, with its
	// "seq", stays under the contract's 256 KiB.
	chatEventBudget              = 200 << 10
	chatDeltaChunk               = 64 << 10
	chatInteractionBudget        = 64 << 10
	chatSnapshotInteractionBytes = 64 << 10
	chatQueueTextLimit           = 4 << 10
	chatMaxChats                 = 32
	chatPendingEvents            = 1024
	chatPendingBytes             = 4 << 20
	chatLoadConcurrency          = 4
	chatAbortedTurns             = 16
	chatEvictIdle                = 3 * time.Minute
	chatEvictBusy                = 30 * time.Minute
	chatJanitorInterval          = 15 * time.Second
	chatPumpWait                 = 2 * time.Second
)

var (
	errChatHubFull   = errors.New("too many chats are open on this host")
	errChatHubClosed = errors.New("the host is stopping")
)

// ringDelta keeps a part.delta structured so a slow reader can receive
// several consecutive deltas of one part as a single line.
type ringDelta struct {
	messageID, partID, field string
	offset                   int
	text                     string
}

// ringEvent is one encoded event: body is its JSON object without the opening
// brace, so a reader adds {"seq":N, in front.
type ringEvent struct {
	seq   uint64
	body  []byte
	delta *ringDelta
	size  int
}

// chatRing is a chat's shared event history. Every subscriber reads it from
// its own cursor; nothing is queued per subscriber.
type chatRing struct {
	epoch     string
	first     uint64 // seq of events[head]
	next      uint64 // seq of the next event
	events    []ringEvent
	head      int
	bytes     int
	maxEvents int
	maxBytes  int
}

func newChatRing(maxEvents, maxBytes int) chatRing {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		panic(err)
	}
	return chatRing{epoch: hex.EncodeToString(random[:]), first: 1, next: 1, maxEvents: maxEvents, maxBytes: maxBytes}
}

func (r *chatRing) last() uint64 { return r.next - 1 }
func (r *chatRing) count() int   { return len(r.events) - r.head }

func (r *chatRing) push(event ringEvent) {
	event.seq = r.next
	r.next++
	r.events = append(r.events, event)
	r.bytes += event.size
	for r.count() > 1 && (r.count() > r.maxEvents || r.bytes > r.maxBytes) {
		r.bytes -= r.events[r.head].size
		r.events[r.head] = ringEvent{}
		r.head++
		r.first++
	}
	if r.head >= 64 && r.head*2 >= len(r.events) {
		r.events = append([]ringEvent(nil), r.events[r.head:]...)
		r.head = 0
	}
}

// holds reports whether a reader that has seen seq can continue from here.
func (r *chatRing) holds(seq uint64) bool { return seq <= r.last() && seq+1 >= r.first }

// after copies up to limit events following seq; more reports a remainder.
func (r *chatRing) after(seq uint64, limit int) ([]ringEvent, bool) {
	start := r.head + int(seq+1-r.first)
	end := min(len(r.events), start+limit)
	return append([]ringEvent(nil), r.events[start:end]...), end < len(r.events)
}

func (r *chatRing) cursor(seq uint64) string { return r.epoch + "." + strconv.FormatUint(seq, 10) }

// parseChatCursor splits "<epoch>.<seq>".
func parseChatCursor(cursor string) (string, uint64, bool) {
	epoch, number, ok := strings.Cut(cursor, ".")
	if !ok || len(epoch) != 16 {
		return "", 0, false
	}
	if _, err := hex.DecodeString(epoch); err != nil {
		return "", 0, false
	}
	seq, err := strconv.ParseUint(number, 10, 64)
	return epoch, seq, err == nil
}

type hubPart struct {
	part ChatPart
	// live parts were last written by the provider's event stream, so its
	// deltas apply to them. Parts read over REST wait for the next full update.
	live    bool
	touched uint64
}

type hubMessage struct {
	header  ChatMessage // Parts unused; see parts
	parts   []*hubPart  // ascending ord
	touched uint64
}

func (m *hubMessage) full() ChatMessage {
	message := m.header
	message.Parts = make([]ChatPart, len(m.parts))
	for index, part := range m.parts {
		message.Parts[index] = part.part
	}
	return message
}

func (m *hubMessage) part(id string) (*hubPart, int) {
	for index, part := range m.parts {
		if part.part.ID == id {
			return part, index
		}
	}
	return nil, -1
}

func (m *hubMessage) bytes() int {
	size := 512 + len(m.header.Error.message())
	for _, part := range m.parts {
		size += 256 + len(part.part.Text)
		if tool := part.part.Tool; tool != nil {
			size += len(tool.Input) + len(tool.Output) + len(tool.Error) + len(tool.Title)
		}
	}
	return size
}

func (e *ChatError) message() string {
	if e == nil {
		return ""
	}
	return e.Message
}

type hubInteraction struct {
	interaction ChatInteraction
}

// openCodeEvent is one event from OpenCode's /global/event stream.
type openCodeEvent struct {
	directory  string
	kind       string
	sessionID  string
	properties json.RawMessage
}

// hubChat is the hub's state for one chat, shared by all its subscribers.
type hubChat struct {
	key      sessionKey
	project  Project
	provider chatProvider
	opencode bool

	info   ChatInfo
	rewind string
	// seenRewind is the rewind point OpenCode reported last. It leads rewind
	// while a rebuild is loading, so a restore right after a rewind is not
	// mistaken for no change.
	seenRewind   string
	messages     []*hubMessage // ascending ord
	hasOlder     bool
	state        string // provider activity: idle, busy or retry
	retry        *ChatRetry
	interactions []*hubInteraction
	queue        []QueueItem
	status       ChatStatusInfo // last status sent
	turn         string         // turn running now
	turnFailed   bool           // OpenCode reported a session error in this turn
	abortedTurns []string       // Claude Code and Codex turns the user stopped

	ring    chatRing
	changed chan struct{} // closed and replaced whenever the ring or state changes

	subscribers  int
	lastActive   time.Time
	loading      bool
	awaitingPump bool
	loaded       chan struct{}
	loadErr      error
	pending      []openCodeEvent
	pendingBytes int
	pendingLost  bool
	reconciling  bool
	again        bool
	rebuild      bool
	removed      bool

	statusTouched       uint64
	interactionsTouched uint64

	// Archive capture (M1 chunk B2, archive_chat_capture.go): changes not yet
	// written to the archive (nil capture without an archive), the seed of a
	// continued chat, and a follow that keeps the chat through a turn no
	// device streams.
	capture       *chatCapture
	captured      chatCaptureState
	seed          *chatSeed
	following     bool
	followStarted bool
	followUntil   time.Time

	// Notices (chat_hub_events.go): the host's observer of ended turns and
	// new interactions.
	observe func(hubEvent)

	// Chat names (chat_title.go): the host's names, applied over the titles
	// providers give.
	titles *ChatTitleStore
}

func (c *hubChat) wake() {
	close(c.changed)
	c.changed = make(chan struct{})
}

func (c *hubChat) pushBody(body []byte) {
	c.ring.push(ringEvent{body: body[1:], size: len(body) + 24})
	c.wake()
}

func (c *hubChat) emit(event any) { c.pushBody(marshalJSONLine(event)) }

// emitDelta sends text appended to a part field, in chunks that fit a line.
func (c *hubChat) emitDelta(messageID, partID, field string, offset int, text string) {
	// Archive capture: every provider's streamed text passes here.
	if text != "" {
		c.noteMessage(messageID, false)
	}
	for text != "" {
		chunk := clipJSON(text, chatDeltaChunk)
		if chunk == "" {
			return
		}
		c.ring.push(ringEvent{delta: &ringDelta{messageID: messageID, partID: partID, field: field, offset: offset, text: chunk}, size: len(chunk) + len(messageID) + len(partID) + 96})
		offset += len(chunk)
		text = text[len(chunk):]
	}
	c.wake()
}

type evMessage struct {
	Type    string      `json:"type"`
	Message ChatMessage `json:"message"`
}

type evMessageUpdated struct {
	Type        string     `json:"type"`
	MessageID   string     `json:"messageId"`
	Status      string     `json:"status,omitempty"`
	CompletedAt string     `json:"completedAt,omitempty"`
	Usage       *ChatUsage `json:"usage,omitempty"`
	Error       *ChatError `json:"error,omitempty"`
}

type evMessageRemoved struct {
	Type      string `json:"type"`
	MessageID string `json:"messageId"`
}

type evPart struct {
	Type      string   `json:"type"`
	MessageID string   `json:"messageId"`
	Part      ChatPart `json:"part"`
}

type evPartRemoved struct {
	Type      string `json:"type"`
	MessageID string `json:"messageId"`
	PartID    string `json:"partId"`
}

type evDelta struct {
	Seq       uint64 `json:"seq"`
	Type      string `json:"type"`
	MessageID string `json:"messageId"`
	PartID    string `json:"partId"`
	Field     string `json:"field"`
	Offset    int    `json:"offset"`
	Delta     string `json:"delta"`
}

type evInteraction struct {
	Type        string          `json:"type"`
	Interaction ChatInteraction `json:"interaction"`
}

type evResolved struct {
	Type    string `json:"type"`
	ID      string `json:"id"`
	Outcome string `json:"outcome"`
}

type evQueue struct {
	Type  string      `json:"type"`
	Items []QueueItem `json:"items"`
}

type evTurn struct {
	Type    string     `json:"type"`
	TurnID  string     `json:"turnId"`
	Outcome string     `json:"outcome,omitempty"`
	Usage   *ChatUsage `json:"usage,omitempty"`
}

type evStatus struct {
	Type  string     `json:"type"`
	State string     `json:"state"`
	Retry *ChatRetry `json:"retry,omitempty"`
}

// evChatUpdated carries what changed. The title comes with its source, and
// its basis when it has one, whenever any of the three changes (chat names,
// chat_title.go).
type evChatUpdated struct {
	Type        string  `json:"type"`
	Title       *string `json:"title,omitempty"`
	TitleSource string  `json:"titleSource,omitempty"`
	TitleBasis  string  `json:"titleBasis,omitempty"`
	Model       string  `json:"model,omitempty"`
	Mode        string  `json:"mode,omitempty"`
	Effort      string  `json:"effort,omitempty"`
	// A chat continued in a new one (chat_continue.go).
	ContinuedIn string `json:"continuedIn,omitempty"`
	ContinuedAt string `json:"continuedAt,omitempty"`
}

type rewindRef struct {
	MessageID string `json:"messageId"`
}

type evSnapshot struct {
	Type         string            `json:"type"`
	Chat         ChatInfo          `json:"chat"`
	Messages     []ChatMessage     `json:"messages"`
	HasMore      bool              `json:"hasMore"`
	Status       ChatStatusInfo    `json:"status"`
	Interactions []ChatInteraction `json:"interactions"`
	Queue        []QueueItem       `json:"queue"`
	Rewind       *rewindRef        `json:"rewind,omitempty"`
}

// emitPart sends part.created or part.updated. A part too large for one line
// goes out shortened and is completed with part.delta lines.
func (c *hubChat) emitPart(kind, messageID string, part ChatPart) {
	body := marshalJSONLine(evPart{kind, messageID, part})
	if len(body) <= chatEventBudget {
		c.pushBody(body)
		return
	}
	head := part
	field, rest := "text", part.Text
	if part.Tool != nil {
		tool := *part.Tool
		head.Tool = &tool
		field, rest = "output", tool.Output
		tool.Output = ""
		if len(marshalJSONLine(evPart{kind, messageID, head})) > chatEventBudget-chatDeltaChunk {
			// The input or error alone cannot share a line: shorten them.
			tool.Input = clipJSON(tool.Input, 32<<10)
			tool.Error = clipJSON(tool.Error, 32<<10)
			tool.Truncated = true
		}
		tool.Output = clipJSON(rest, chatEventBudget-len(marshalJSONLine(evPart{kind, messageID, head})))
		rest = rest[len(tool.Output):]
		c.pushBody(marshalJSONLine(evPart{kind, messageID, head}))
		c.emitDelta(messageID, part.ID, field, len(tool.Output), rest)
		return
	}
	head.Text = ""
	head.Text = clipJSON(rest, chatEventBudget-len(marshalJSONLine(evPart{kind, messageID, head})))
	rest = rest[len(head.Text):]
	c.pushBody(marshalJSONLine(evPart{kind, messageID, head}))
	c.emitDelta(messageID, part.ID, field, len(head.Text), rest)
}

// emitMessage sends message.created; parts that do not fit follow as
// part.created lines.
func (c *hubChat) emitMessage(message ChatMessage) {
	body := marshalJSONLine(evMessage{"message.created", message})
	if len(body) <= chatEventBudget {
		c.pushBody(body)
		return
	}
	header := message
	header.Parts = []ChatPart{}
	size := len(marshalJSONLine(evMessage{"message.created", header}))
	count := 0
	for _, part := range message.Parts {
		partSize := len(marshalJSONLine(part)) + 1
		if size+partSize > chatEventBudget {
			break
		}
		size += partSize
		count++
	}
	header.Parts = message.Parts[:count]
	c.pushBody(marshalJSONLine(evMessage{"message.created", header}))
	for _, part := range message.Parts[count:] {
		c.emitPart("part.created", message.ID, part)
	}
}

func (c *hubChat) find(id string) (*hubMessage, int) {
	for index, message := range c.messages {
		if message.header.ID == id {
			return message, index
		}
	}
	return nil, -1
}

func newHubMessage(message ChatMessage, live bool, touched uint64) *hubMessage {
	result := &hubMessage{header: message, touched: touched}
	result.header.Parts = nil
	for index, part := range message.Parts {
		if index == chatPartsPerMessage {
			break
		}
		result.parts = append(result.parts, &hubPart{part: part, live: live, touched: touched})
	}
	return result
}

// insertMessage adds a message in ord order and announces it.
func (c *hubChat) insertMessage(message ChatMessage, live bool, touched uint64) *hubMessage {
	message = c.seed.strip(message)
	entry := newHubMessage(message, live, touched)
	position := sort.Search(len(c.messages), func(i int) bool { return c.messages[i].header.Ord > message.Ord })
	c.messages = append(c.messages, nil)
	copy(c.messages[position+1:], c.messages[position:])
	c.messages[position] = entry
	c.emitMessage(entry.full())
	c.noteMessage(message.ID, message.Role == "user" || message.Status != "streaming")
	return entry
}

func (c *hubChat) updateHeader(entry *hubMessage, next ChatMessage, touched uint64) {
	previous := entry.header
	next.Parts = nil
	entry.header = next
	entry.touched = max(entry.touched, touched)
	if !reflect.DeepEqual(previous, next) {
		c.noteMessage(next.ID, previous.Status != next.Status)
	}
	event := evMessageUpdated{Type: "message.updated", MessageID: next.ID}
	changed := false
	if previous.Status != next.Status {
		event.Status, changed = next.Status, true
	}
	if previous.CompletedAt != next.CompletedAt && next.CompletedAt != "" {
		event.CompletedAt, changed = next.CompletedAt, true
	}
	if !reflect.DeepEqual(previous.Usage, next.Usage) && next.Usage != nil {
		event.Usage, changed = next.Usage, true
	}
	if !reflect.DeepEqual(previous.Error, next.Error) && next.Error != nil {
		event.Error, changed = next.Error, true
	}
	if changed {
		c.emit(event)
	}
}

func (c *hubChat) removeMessage(id string) {
	if entry, index := c.find(id); index >= 0 {
		// The archive keeps a message the provider removed, as last seen.
		c.holdCaptured(entry)
		c.messages = append(c.messages[:index], c.messages[index+1:]...)
		c.emit(evMessageRemoved{"message.removed", id})
	}
}

// upsertPart applies a whole part. Unknown messages are ignored: they are
// outside the hub's window or have not been announced yet.
func (c *hubChat) upsertPart(messageID string, part ChatPart, live bool, touched uint64) {
	entry, _ := c.find(messageID)
	if entry == nil {
		return
	}
	if entry.header.Role == "user" {
		part = c.seed.stripPart(part)
	}
	entry.touched = max(entry.touched, touched)
	if existing, _ := entry.part(part.ID); existing != nil {
		existing.live = live
		existing.touched = max(existing.touched, touched)
		if !reflect.DeepEqual(existing.part, part) {
			existing.part = part
			c.emitPart("part.updated", messageID, part)
			c.noteMessage(messageID, false)
		}
		return
	}
	if len(entry.parts) >= chatPartsPerMessage {
		return
	}
	position := sort.Search(len(entry.parts), func(i int) bool { return entry.parts[i].part.Ord > part.Ord })
	entry.parts = append(entry.parts, nil)
	copy(entry.parts[position+1:], entry.parts[position:])
	entry.parts[position] = &hubPart{part: part, live: live, touched: touched}
	c.emitPart("part.created", messageID, part)
	c.noteMessage(messageID, false)
}

func (c *hubChat) removePart(messageID, partID string) {
	entry, _ := c.find(messageID)
	if entry == nil {
		return
	}
	if _, index := entry.part(partID); index >= 0 {
		entry.parts = append(entry.parts[:index], entry.parts[index+1:]...)
		c.emit(evPartRemoved{"part.removed", messageID, partID})
		c.noteMessage(messageID, false)
	}
}

// appendDelta applies streamed text to a live part. A part at its size bound
// stops growing and is marked truncated.
func (c *hubChat) appendDelta(messageID, partID, field, delta string, touched uint64) {
	entry, _ := c.find(messageID)
	if entry == nil || field != "text" {
		return
	}
	part, _ := entry.part(partID)
	if part == nil || !part.live || part.part.Truncated {
		return
	}
	limit := chatTextLimit
	switch part.part.Kind {
	case "text":
	case "reasoning":
		limit = chatReasoningLimit
	default:
		return
	}
	part.touched = max(part.touched, touched)
	entry.touched = max(entry.touched, touched)
	offset := len(part.part.Text)
	accepted, cut := clipText(delta, limit-offset)
	if accepted != "" {
		part.part.Text += accepted
		c.emitDelta(messageID, partID, "text", offset, accepted)
	}
	if cut {
		part.part.Truncated = true
		c.emitPart("part.updated", messageID, part.part)
		c.noteMessage(messageID, false)
	}
}

func (c *hubChat) newestUserID() string {
	for index := len(c.messages) - 1; index >= 0; index-- {
		if c.messages[index].header.Role == "user" {
			return c.messages[index].header.ID
		}
	}
	return ""
}

func running(state string) bool { return state == "running" || state == "waiting" || state == "retry" }

func (c *hubChat) computeStatus() ChatStatusInfo {
	switch c.state {
	case "busy":
		if len(c.interactions) > 0 {
			return ChatStatusInfo{State: "waiting"}
		}
		return ChatStatusInfo{State: "running"}
	case "retry":
		return ChatStatusInfo{State: "retry", Retry: c.retry}
	}
	if count := len(c.messages); count > 0 {
		newest := c.messages[count-1].header
		if (newest.Role == "assistant" && newest.Status == "error") || (newest.Role == "user" && c.turnFailed) {
			return ChatStatusInfo{State: "error"}
		}
	}
	return ChatStatusInfo{State: "idle"}
}

func (c *hubChat) turnAborted(turn string) bool {
	for _, aborted := range c.abortedTurns {
		if aborted == turn {
			return true
		}
	}
	return false
}

func (c *hubChat) turnOutcome(turn string) (string, *ChatUsage) {
	var usage *ChatUsage
	var last *hubMessage
	aborted := false
	for _, message := range c.messages {
		if message.header.Role != "assistant" || message.header.TurnID != turn {
			continue
		}
		last = message
		aborted = aborted || message.header.Status == "aborted"
		if u := message.header.Usage; u != nil {
			if usage == nil {
				usage = &ChatUsage{}
			}
			usage.Input += u.Input
			usage.Output += u.Output
			usage.Reasoning += u.Reasoning
			usage.CacheRead += u.CacheRead
			usage.CacheWrite += u.CacheWrite
			if u.CostMicros != nil {
				if usage.CostMicros == nil {
					usage.CostMicros = new(int64)
				}
				*usage.CostMicros += *u.CostMicros
			}
		}
	}
	switch {
	case aborted:
		return "aborted", usage
	case last != nil && last.header.Status == "error":
		return "error", usage
	case last == nil && c.turnFailed:
		return "error", usage
	}
	return "completed", usage
}

// recomputeStatus sends status and turn events when the derived state changes.
func (c *hubChat) recomputeStatus() {
	next := c.computeStatus()
	wasRunning, isRunning := running(c.status.State), running(next.State)
	if !wasRunning && isRunning {
		c.turn = c.newestUserID()
		c.turnFailed = false
		c.emit(evTurn{Type: "turn.started", TurnID: c.turn})
		next = c.computeStatus()
		// Archive capture: a followed chat is held until this turn ends.
		c.followStarted = c.following
	}
	if !reflect.DeepEqual(next, c.status) {
		c.status = next
		c.emit(evStatus{"status", next.State, next.Retry})
	}
	if wasRunning && !isRunning {
		// A reply that never completed before the chat went idle was abandoned.
		for _, message := range c.messages {
			if message.header.Role == "assistant" && message.header.TurnID == c.turn && message.header.Status == "streaming" {
				abandoned := message.header
				abandoned.Status = "aborted"
				c.updateHeader(message, abandoned, 0)
			}
		}
		outcome, usage := c.turnOutcome(c.turn)
		c.emit(evTurn{Type: "turn.finished", TurnID: c.turn, Outcome: outcome, Usage: usage})
		// Notices (chat_hub_events.go).
		c.noteEndedTurn(c.turn, outcome)
		c.turn = ""
		// Archive capture: the finished turn is written at once, with the
		// chat's new activity time, and a followed chat is released.
		c.noteInfo(true)
		c.turnEnded()
	}
}

// applyInfo applies a provider's read or update of the chat: its title,
// turned into the name the host shows (named), a model, mode or effort it
// gives, and where it continued.
func (c *hubChat) applyInfo(info ChatInfo) {
	info = c.named(info)
	event := evChatUpdated{Type: "chat.updated"}
	changed := c.takeName(chatName{Title: info.Title, Source: info.TitleSource, Basis: info.TitleBasis}, &event)
	if c.takeSettings(info.Model, info.Mode, info.Effort, &event) {
		changed = true
	}
	if c.takeContinuation(info.ContinuedIn, info.ContinuedAt, &event) {
		changed = true
	}
	if changed {
		c.emit(event)
		c.noteInfo(false)
	}
}

// applySettings applies a model, mode or effort without touching the title.
func (c *hubChat) applySettings(model, mode, effort string) {
	event := evChatUpdated{Type: "chat.updated"}
	if c.takeSettings(model, mode, effort, &event) {
		c.emit(event)
		c.noteInfo(false)
	}
}

// setName applies a name the host just gave the chat.
func (c *hubChat) setName(name chatName) {
	event := evChatUpdated{Type: "chat.updated"}
	if c.takeName(name, &event) {
		c.emit(event)
		c.noteInfo(true)
	}
}

// named turns the title a provider gave into the name the host shows, with
// its source and basis: OpenCode titles through the host's names; Claude
// Code and Codex chats as their registry has them, or as the host named them
// since, when a read began before that.
func (c *hubChat) named(info ChatInfo) ChatInfo {
	name := chatName{Title: info.Title, Source: info.TitleSource, Basis: info.TitleBasis}
	switch {
	case c.opencode:
		name = c.titles.resolveOpenCode(c.key.sessionID, info.Title)
	default:
		if latest, ok := c.titles.memoryName(c.key.sessionID); ok {
			name = latest
		}
		if name.Source == "" {
			name = chatName{Title: name.Title, Source: titleSourceFor(name.Title)}
		}
	}
	info.Title, info.TitleSource, info.TitleBasis = name.Title, name.Source, name.Basis
	return info
}

func (c *hubChat) takeName(name chatName, event *evChatUpdated) bool {
	if name.Title == c.info.Title && name.Source == c.info.TitleSource && name.Basis == c.info.TitleBasis {
		return false
	}
	c.info.Title, c.info.TitleSource, c.info.TitleBasis = name.Title, name.Source, name.Basis
	title := name.Title
	event.Title, event.TitleSource, event.TitleBasis = &title, name.Source, name.Basis
	return true
}

func (c *hubChat) takeSettings(model, mode, effort string, event *evChatUpdated) bool {
	changed := false
	if model != "" && model != c.info.Model {
		c.info.Model, event.Model, changed = model, model, true
	}
	if mode != "" && mode != c.info.Mode {
		c.info.Mode, event.Mode, changed = mode, mode, true
	}
	if effort != "" && effort != c.info.Effort {
		c.info.Effort, event.Effort, changed = effort, effort, true
	}
	return changed
}

// takeContinuation takes the chat a chat continued in and when
// (chat_continue.go); a read without one leaves the one the hub has.
func (c *hubChat) takeContinuation(in, at string, event *evChatUpdated) bool {
	if in == "" || (in == c.info.ContinuedIn && at == c.info.ContinuedAt) {
		return false
	}
	c.info.ContinuedIn, c.info.ContinuedAt = in, at
	event.ContinuedIn, event.ContinuedAt = in, at
	return true
}

// fitInteraction keeps an interaction event within its line budget.
func fitInteraction(interaction ChatInteraction) ChatInteraction {
	if len(marshalJSONLine(interaction)) <= chatInteractionBudget {
		return interaction
	}
	if interaction.Permission != nil {
		permission := *interaction.Permission
		permission.Input = clipJSON(permission.Input, 8<<10)
		permission.Title = clipJSON(permission.Title, 512)
		permission.Detail = clipJSON(permission.Detail, 512)
		interaction.Permission = &permission
	}
	questions := make([]ChatQuestion, 0, min(len(interaction.Questions), 4))
	for index, question := range interaction.Questions {
		if index == 4 {
			break
		}
		question.Text = clipJSON(question.Text, 1<<10)
		options := make([]ChatQuestionOption, 0, min(len(question.Options), 16))
		for number, option := range question.Options {
			if number == 16 {
				break
			}
			options = append(options, ChatQuestionOption{Label: clipJSON(option.Label, 128)})
		}
		question.Options = options
		questions = append(questions, question)
	}
	if interaction.Questions != nil {
		interaction.Questions = questions
	}
	return interaction
}

func (c *hubChat) upsertInteraction(interaction ChatInteraction, touched uint64) {
	c.interactionsTouched = max(c.interactionsTouched, touched)
	interaction = fitInteraction(interaction)
	for _, existing := range c.interactions {
		if existing.interaction.ID == interaction.ID {
			interaction.CreatedAt = existing.interaction.CreatedAt
			if !reflect.DeepEqual(existing.interaction, interaction) {
				existing.interaction = interaction
				c.emit(evInteraction{"interaction.requested", interaction})
				c.noteInteraction(interaction, "")
			}
			return
		}
	}
	if len(c.interactions) >= chatInteractionsLimit {
		return
	}
	c.interactions = append(c.interactions, &hubInteraction{interaction: interaction})
	c.emit(evInteraction{"interaction.requested", interaction})
	c.noteInteraction(interaction, "")
	// Notices (chat_hub_events.go).
	c.noteNewInteraction(interaction)
	c.recomputeStatus()
}

func (c *hubChat) resolveInteraction(id, outcome string, touched uint64) {
	c.interactionsTouched = max(c.interactionsTouched, touched)
	for index, existing := range c.interactions {
		if existing.interaction.ID == id {
			c.interactions = append(c.interactions[:index], c.interactions[index+1:]...)
			c.emit(evResolved{"interaction.resolved", id, outcome})
			c.noteInteraction(existing.interaction, outcome)
			c.recomputeStatus()
			return
		}
	}
}

func (c *hubChat) replaceInteractions(next []ChatInteraction) {
	wanted := map[string]bool{}
	for _, interaction := range next {
		wanted[interaction.ID] = true
	}
	for _, existing := range append([]*hubInteraction(nil), c.interactions...) {
		if !wanted[existing.interaction.ID] {
			c.resolveInteraction(existing.interaction.ID, "gone", 0)
		}
	}
	for _, interaction := range next {
		c.upsertInteraction(interaction, 0)
	}
}

// trim keeps the newest messages within the window; older ones are paged
// from the provider.
func (c *hubChat) trim() {
	total := 0
	for _, message := range c.messages {
		total += message.bytes()
	}
	drop := 0
	for len(c.messages)-drop > 1 && (len(c.messages)-drop > chatWindowMessages || total > chatWindowBytes) {
		total -= c.messages[drop].bytes()
		// Archive capture: a change not yet written leaves with the message.
		c.holdCaptured(c.messages[drop])
		drop++
	}
	if drop > 0 {
		c.messages = append([]*hubMessage(nil), c.messages[drop:]...)
		c.hasOlder = true
	}
}

func clippedQueue(items []QueueItem) []QueueItem {
	result := make([]QueueItem, len(items))
	for index, item := range items {
		item.Text = clipJSON(item.Text, chatQueueTextLimit)
		item.Error = clipJSON(item.Error, chatShortLimit)
		result[index] = item
	}
	return result
}

// chatHub owns the live state of every chat a device streams: messages with
// parts, status, interactions, queue and rewind point, plus each chat's
// event ring. Providers feed it; streams read it.
type chatHub struct {
	host      *Host
	mu        sync.Mutex
	chats     map[sessionKey]*hubChat
	bySession map[string][]*hubChat // OpenCode session ID to its chats
	// counter increases with every change from a live event stream. A REST
	// read never overrides state changed after the read began.
	counter uint64
	closed  bool
	done    chan struct{}
	work    sync.WaitGroup
	slots   chan struct{}
	janitor bool

	pump      *openCodeEventPump
	pumpReady chan struct{} // closed when the first connection is up
	version   string
	sameDirs  map[[2]string]bool

	now                              func() time.Time
	evictIdle, evictBusy, janitorGap time.Duration
	pumpWait, pumpSilence            time.Duration
	pumpBackoff, pumpMaxBackoff      time.Duration
	ringEvents, ringBytes            int

	// Archive capture (M1 chunk B2, archive_chat_capture.go): nil without an
	// archive. captureRemoved holds the unwritten changes of chats that left
	// the hub; seeds caches continued chats' seeds by chat ID (nil: none).
	capture        *chatCapture
	captureRemoved []captureBatch
	seeds          map[string]*chatSeed
	followGrace    time.Duration

	// Notices (chat_hub_events.go, notices.go): observer is
	// given to every chat the hub tracks; noticeFollow keeps a chat through
	// its turn after a send even without an archive, so its end is noticed.
	observer     func(hubEvent)
	noticeFollow bool
}

func newChatHub(host *Host) *chatHub {
	hub := &chatHub{host: host, chats: map[sessionKey]*hubChat{}, bySession: map[string][]*hubChat{}, done: make(chan struct{}), slots: make(chan struct{}, chatLoadConcurrency), sameDirs: map[[2]string]bool{}, now: time.Now, evictIdle: chatEvictIdle, evictBusy: chatEvictBusy, janitorGap: chatJanitorInterval, pumpWait: chatPumpWait, pumpSilence: openCodeEventSilence, pumpBackoff: openCodeEventBackoff, pumpMaxBackoff: openCodeEventMaxBackoff, ringEvents: chatRingEvents, ringBytes: chatRingBytes}
	// Archive capture.
	hub.seeds, hub.followGrace = map[string]*chatSeed{}, chatFollowGrace
	if host.archive != nil {
		hub.capture = &chatCapture{hub: hub, archive: host.archive, every: chatCaptureInterval, wake: make(chan struct{}, 1)}
	}
	return hub
}

// streams reports whether every provider's chats can be streamed.
func (h *chatHub) streams() bool {
	return openCodeProvider{agent: h.host.agent}.transport() != ""
}

func (h *chatHub) openCodeVersion() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.version
}

// subscribe returns the chat's live state, loading it from the provider when
// no one streams it yet. The caller must unsubscribe.
func (h *chatHub) subscribe(ctx context.Context, p Project, s Session, provider chatProvider) (*hubChat, error) {
	key := sessionKey{p.ID, s.ID}
	// Archive capture: a continued chat's seed is read before its state.
	h.ensureSeed(ctx, s.ID)
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil, errChatHubClosed
	}
	if c := h.chats[key]; c != nil {
		c.subscribers++
		loaded := c.loaded
		h.mu.Unlock()
		select {
		case <-loaded:
		case <-ctx.Done():
			h.unsubscribe(c)
			return nil, ctx.Err()
		case <-h.done:
			h.unsubscribe(c)
			return nil, errChatHubClosed
		}
		h.mu.Lock()
		err := c.loadErr
		if err == nil && c.removed {
			err = ErrNotFound
		}
		h.mu.Unlock()
		if err != nil {
			h.unsubscribe(c)
			return nil, err
		}
		return c, nil
	}
	if len(h.chats) >= chatMaxChats && !h.evictOneLocked() {
		h.mu.Unlock()
		return nil, errChatHubFull
	}
	c := &hubChat{key: key, project: p, provider: provider, opencode: provider.name() == "opencode", loading: true, loaded: make(chan struct{}), subscribers: 1, lastActive: h.now(), changed: make(chan struct{}), ring: newChatRing(h.ringEvents, h.ringBytes), titles: h.host.titles}
	// Archive capture.
	c.capture, c.seed = h.capture, h.seeds[s.ID]
	h.ensureCaptureLocked()
	// Notices.
	c.observe = h.observer
	h.chats[key] = c
	var ready chan struct{}
	if c.opencode {
		h.bySession[s.ID] = append(h.bySession[s.ID], c)
		h.ensurePumpLocked()
		ready = h.pumpReady
		c.awaitingPump = ready != nil
	}
	h.ensureJanitorLocked()
	h.mu.Unlock()
	// Live providers (chat_hub_live.go): read and switch to live changes at once.
	if live, ok := provider.(liveChatProvider); ok {
		return h.subscribeLive(c, live, p, s.ID)
	}
	if ready != nil {
		// Load after the event stream is up so no change falls between them.
		timer := time.NewTimer(h.pumpWait)
		select {
		case <-ready:
		case <-timer.C:
		case <-ctx.Done():
		case <-h.done:
		}
		timer.Stop()
		h.mu.Lock()
		c.awaitingPump = false
		h.mu.Unlock()
	}
	load, err := h.loadWithSlot(provider, p, s.ID, chatSnapshotMessages)
	h.mu.Lock()
	defer h.mu.Unlock()
	if err == nil && (c.removed || h.closed) {
		err = errChatHubClosed
	}
	if err != nil {
		c.loadErr = err
		c.loading = false
		close(c.loaded)
		h.removeChatLocked(c)
		return nil, err
	}
	h.applyInitialLocked(c, load)
	c.loading = false
	close(c.loaded)
	pending := c.pending
	c.pending, c.pendingBytes = nil, 0
	if c.pendingLost {
		c.pendingLost = false
		c.again = true
	} else {
		for _, event := range pending {
			h.applyOpenCodeLocked(c, event)
		}
	}
	if c.again {
		c.again = false
		h.requestReconcileLocked(c)
	}
	return c, nil
}

func (h *chatHub) unsubscribe(c *hubChat) {
	h.mu.Lock()
	c.subscribers--
	c.lastActive = h.now()
	h.mu.Unlock()
}

func (h *chatHub) loadWithSlot(provider chatProvider, p Project, sessionID string, limit int) (chatLoad, error) {
	select {
	case h.slots <- struct{}{}:
	case <-h.done:
		return chatLoad{}, errChatHubClosed
	}
	defer func() { <-h.slots }()
	return provider.load(p, sessionID, limit)
}

// applyInitialLocked replaces the chat's state and starts a new ring epoch;
// subscribers see the epoch change and receive a snapshot.
func (h *chatHub) applyInitialLocked(c *hubChat, load chatLoad) {
	// Archive capture: changes not yet written leave with the old state, and
	// a new rewind point hides the archived messages from it on.
	for _, entry := range c.messages {
		c.holdCaptured(entry)
	}
	if load.rewind != "" && load.rewind != c.rewind {
		c.captureRewind(load.rewind)
	}
	c.info = c.named(load.info)
	c.info.ID, c.info.Provider = c.key.sessionID, c.provider.name()
	c.rewind, c.seenRewind = load.rewind, load.rewind
	c.messages = nil
	for _, message := range load.messages {
		c.messages = append(c.messages, newHubMessage(c.seed.strip(message), false, 0))
	}
	// A continued chat shows its seed first once the window reaches back to
	// the start of the chat.
	if c.seed != nil && !load.hasOlder {
		c.messages = append(c.messages, newHubMessage(c.seed.message(c.key.sessionID, c.provider.name()), false, 0))
	}
	sort.SliceStable(c.messages, func(i, j int) bool { return c.messages[i].header.Ord < c.messages[j].header.Ord })
	// Archive capture: a read is a consistent snapshot, written at once.
	for _, entry := range c.messages {
		c.noteMessage(entry.header.ID, true)
	}
	c.noteInfo(true)
	c.hasOlder = load.hasOlder
	c.state, c.retry = load.state, load.retry
	c.interactions = nil
	for _, interaction := range load.interactions {
		if len(c.interactions) < chatInteractionsLimit {
			c.interactions = append(c.interactions, &hubInteraction{interaction: fitInteraction(interaction)})
			c.noteInteraction(c.interactions[len(c.interactions)-1].interaction, "")
		}
	}
	c.markAborted(load)
	c.queue = h.queueItemsLocked(c.key)
	c.trim()
	c.status = c.computeStatus()
	c.turn, c.turnFailed = "", false
	if running(c.status.State) {
		c.turn = c.newestUserID()
	}
	c.ring = newChatRing(h.ringEvents, h.ringBytes)
	c.wake()
}

// markAborted shows stopped Claude Code and Codex replies as aborted instead
// of failed.
func (c *hubChat) markAborted(load chatLoad) {
	if c.opencode {
		return
	}
	for index := range load.messages {
		message := &load.messages[index]
		if message.Role == "assistant" && message.Status == "error" && c.turnAborted(message.TurnID) {
			message.Status, message.Error = "aborted", nil
		}
	}
}

// applyLoadLocked merges a provider read into the chat. Anything a live event
// changed after the read began (touched > start) keeps its newer state.
func (h *chatHub) applyLoadLocked(c *hubChat, load chatLoad, start uint64) {
	c.markAborted(load)
	c.applyInfo(load.info)
	if len(load.messages) > 0 && len(c.messages) > 0 && load.hasOlder && load.messages[0].Ord > c.messages[len(c.messages)-1].header.Ord {
		// The read does not reach back to what the hub holds: start over.
		h.applyInitialLocked(c, load)
		return
	}
	seen := map[string]bool{}
	for _, message := range load.messages {
		seen[message.ID] = true
		entry, _ := c.find(message.ID)
		if entry == nil {
			c.insertMessage(message, false, 0)
			continue
		}
		if entry.touched <= start {
			c.updateHeader(entry, message, 0)
		}
		wanted := map[string]bool{}
		for _, part := range message.Parts {
			wanted[part.ID] = true
			existing, _ := entry.part(part.ID)
			if existing != nil && existing.touched > start {
				continue
			}
			c.upsertPart(message.ID, part, false, 0)
		}
		for _, part := range append([]*hubPart(nil), entry.parts...) {
			if !wanted[part.part.ID] && part.touched <= start {
				c.removePart(message.ID, part.part.ID)
			}
		}
	}
	oldest := int64(math.MinInt64)
	if load.hasOlder {
		if len(load.messages) == 0 {
			oldest = math.MaxInt64
		} else {
			oldest = load.messages[0].Ord
		}
	}
	for _, entry := range append([]*hubMessage(nil), c.messages...) {
		// A continued chat's seed is the host's own message, never the provider's.
		if !seen[entry.header.ID] && entry.touched <= start && entry.header.Ord >= oldest && entry.header.ID != chatSeedMessageID {
			c.removeMessage(entry.header.ID)
		}
	}
	if c.statusTouched <= start {
		c.state, c.retry = load.state, load.retry
	}
	if c.interactionsTouched <= start {
		c.replaceInteractions(load.interactions)
	}
	c.recomputeStatus()
	c.trim()
}

func (h *chatHub) queueItemsLocked(key sessionKey) []QueueItem {
	if h.host.queue == nil {
		return []QueueItem{}
	}
	return h.host.queue.Items(key.projectID, key.sessionID)
}

// snapshotLocked encodes the chat's state for one subscriber and returns the
// ring position it reflects. It holds the newest messages that fit one line
// (at most 40). When the newest message alone is too large, its remaining
// parts, like interactions beyond their budget, are re-sent right after the
// snapshot as ordinary events every subscriber can apply again.
func (h *chatHub) snapshotLocked(c *hubChat) ([]byte, uint64) {
	snapshot := evSnapshot{Type: "snapshot", Chat: c.info, Messages: []ChatMessage{}, Status: c.status, Interactions: []ChatInteraction{}, Queue: clippedQueue(c.queue)}
	if c.rewind != "" {
		snapshot.Rewind = &rewindRef{MessageID: c.rewind}
	}
	var laterInteractions []ChatInteraction
	used := 0
	for _, entry := range c.interactions {
		size := len(marshalJSONLine(entry.interaction)) + 1
		if len(laterInteractions) == 0 && used+size <= chatSnapshotInteractionBytes {
			snapshot.Interactions = append(snapshot.Interactions, entry.interaction)
			used += size
		} else {
			laterInteractions = append(laterInteractions, entry.interaction)
		}
	}
	budget := chatEventBudget - len(marshalJSONLine(snapshot))
	var included []ChatMessage
	var laterParts []ChatPart
	laterMessage := ""
	for index := len(c.messages) - 1; index >= 0 && len(included) < chatSnapshotMessages; index-- {
		message := c.messages[index].full()
		size := len(marshalJSONLine(message)) + 1
		if size <= budget {
			included = append(included, message)
			budget -= size
			continue
		}
		if len(included) == 0 {
			header := message
			header.Parts = []ChatPart{}
			size := len(marshalJSONLine(header)) + 1
			for _, part := range message.Parts {
				partSize := len(marshalJSONLine(part)) + 1
				if len(laterParts) == 0 && size+partSize <= budget {
					header.Parts = append(header.Parts, part)
					size += partSize
				} else {
					laterParts = append(laterParts, part)
				}
			}
			included = append(included, header)
			laterMessage = message.ID
		}
		break
	}
	for left, right := 0, len(included)-1; left < right; left, right = left+1, right-1 {
		included[left], included[right] = included[right], included[left]
	}
	snapshot.Messages = included
	snapshot.HasMore = c.hasOlder || len(included) < len(c.messages)
	body := marshalJSONLine(snapshot)
	seq := c.ring.last()
	for _, part := range laterParts {
		c.emitPart("part.updated", laterMessage, part)
	}
	for _, interaction := range laterInteractions {
		c.emit(evInteraction{"interaction.requested", interaction})
	}
	return body[1:], seq
}

// requestReconcileLocked reads the chat from its provider again, one read at
// a time per chat; a request during a read runs another afterwards.
func (h *chatHub) requestReconcileLocked(c *hubChat) {
	if c.removed || h.closed {
		return
	}
	if c.loading || c.reconciling {
		c.again = true
		return
	}
	c.reconciling = true
	h.work.Add(1)
	go h.reconcile(c)
}

func (h *chatHub) reconcile(c *hubChat) {
	defer h.work.Done()
	// Live providers (chat_hub_live.go) are read under their own lock.
	if live, ok := c.provider.(liveChatProvider); ok {
		h.reconcileLive(c, live)
		return
	}
	for {
		// A request that arrives during the read sets these again, so the
		// next pass sees it.
		h.mu.Lock()
		start := h.counter
		rebuild := c.rebuild
		c.rebuild, c.again = false, false
		h.mu.Unlock()
		limit := chatReconcileMessages
		if rebuild {
			limit = chatSnapshotMessages
		}
		load, err := h.loadWithSlot(c.provider, c.project, c.key.sessionID, limit)
		h.mu.Lock()
		if c.removed || h.closed {
			c.reconciling = false
			h.mu.Unlock()
			return
		}
		switch {
		case errors.Is(err, ErrNotFound):
			h.removeChatLocked(c)
		case err != nil:
			// Keep the current state; the next change or reconnect reads again.
		case rebuild || load.rewind != c.rewind:
			h.applyInitialLocked(c, load)
		default:
			h.applyLoadLocked(c, load, start)
		}
		if !c.again || c.removed {
			c.reconciling = false
			h.mu.Unlock()
			return
		}
		h.mu.Unlock()
	}
}

func (h *chatHub) removeChatLocked(c *hubChat) {
	// Archive capture: the chat's unwritten changes are written after it goes.
	if c.pendingCapture() {
		h.captureRemoved = append(h.captureRemoved, h.captureBatchLocked(c))
		c.capture.notify()
	}
	if h.chats[c.key] == c {
		delete(h.chats, c.key)
	}
	if list := h.bySession[c.key.sessionID]; len(list) > 0 {
		kept := list[:0]
		for _, other := range list {
			if other != c {
				kept = append(kept, other)
			}
		}
		if len(kept) == 0 {
			delete(h.bySession, c.key.sessionID)
		} else {
			h.bySession[c.key.sessionID] = kept
		}
	}
	c.removed = true
	c.wake()
}

func (h *chatHub) evictableLocked(c *hubChat, now time.Time) bool {
	if c.subscribers > 0 || c.loading || c.reconciling || c.followedLocked(now) {
		return false
	}
	idle := now.Sub(c.lastActive)
	return (!running(c.status.State) && idle >= h.evictIdle) || idle >= h.evictBusy
}

// evictOneLocked drops the chat unwatched the longest to make room.
func (h *chatHub) evictOneLocked() bool {
	var oldest *hubChat
	now := h.now()
	for _, c := range h.chats {
		if c.subscribers == 0 && !c.loading && !c.reconciling && !c.followedLocked(now) && (oldest == nil || c.lastActive.Before(oldest.lastActive)) {
			oldest = c
		}
	}
	if oldest == nil {
		return false
	}
	h.removeChatLocked(oldest)
	return true
}

func (h *chatHub) ensureJanitorLocked() {
	if h.janitor || h.closed {
		return
	}
	h.janitor = true
	h.work.Add(1)
	go h.runJanitor()
}

func (h *chatHub) runJanitor() {
	defer h.work.Done()
	ticker := time.NewTicker(h.janitorGap)
	defer ticker.Stop()
	for {
		select {
		case <-h.done:
			return
		case <-ticker.C:
		}
		if !h.sweep() {
			return
		}
	}
}

// sweep evicts idle chats and stops the event stream once no OpenCode chat
// is tracked. It returns false, ending the janitor, when no chat remains.
func (h *chatHub) sweep() bool {
	h.mu.Lock()
	now := h.now()
	for _, c := range h.chats {
		if h.evictableLocked(c, now) {
			h.removeChatLocked(c)
		}
	}
	var stop *openCodeEventPump
	if h.pump != nil && len(h.bySession) == 0 {
		stop, h.pump, h.pumpReady = h.pump, nil, nil
	}
	keep := len(h.chats) > 0
	if !keep {
		h.janitor = false
	}
	h.mu.Unlock()
	if stop != nil {
		stop.stop()
	}
	return keep
}

func (h *chatHub) close() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		h.work.Wait()
		return
	}
	h.closed = true
	// Archive capture: every change not yet written goes out last, after the
	// capture loop has stopped, and before the host closes the archive.
	var final []captureBatch
	if h.capture != nil {
		final, _ = h.collectCaptureLocked(true)
	}
	close(h.done)
	pump := h.pump
	h.pump, h.pumpReady = nil, nil
	for _, c := range h.chats {
		c.removed = true
		c.wake()
	}
	h.chats, h.bySession = map[sessionKey]*hubChat{}, map[string][]*hubChat{}
	h.mu.Unlock()
	if pump != nil {
		pump.stop()
	}
	h.work.Wait()
	if h.capture != nil {
		h.capture.write(final)
	}
}

func (h *chatHub) ensurePumpLocked() {
	if h.pump != nil || h.closed {
		return
	}
	source, ok := h.host.agent.(chatEventSource)
	if !ok {
		return
	}
	h.pumpReady = make(chan struct{})
	h.pump = source.eventPump(h, h.pumpSilence, h.pumpBackoff, h.pumpMaxBackoff)
	h.pump.start()
}

// sameDirLocked compares an event's directory with a project directory by
// file identity, caching the answer.
func (h *chatHub) sameDirLocked(eventDirectory, projectDirectory string) bool {
	if eventDirectory == "" {
		return false
	}
	key := [2]string{eventDirectory, projectDirectory}
	same, known := h.sameDirs[key]
	if !known {
		if len(h.sameDirs) >= 256 {
			h.sameDirs = map[[2]string]bool{}
		}
		same = sameDirectory(eventDirectory, projectDirectory)
		h.sameDirs[key] = same
	}
	return same
}

// openCodeConnected learns that the event stream came up or went down.
// Nothing is replayed after a reconnect, so every tracked OpenCode chat is
// read again over REST.
func (h *chatHub) openCodeConnected(pump *openCodeEventPump, up bool, version string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if pump != h.pump || h.closed {
		return
	}
	if !up {
		for _, c := range h.chats {
			if !c.opencode {
				continue
			}
			for _, message := range c.messages {
				for _, part := range message.parts {
					part.live = false
				}
			}
		}
		return
	}
	if version != "" {
		h.version = version
	}
	if h.pumpReady != nil {
		close(h.pumpReady)
		h.pumpReady = nil
	}
	for _, c := range h.chats {
		if c.opencode && !c.awaitingPump {
			h.requestReconcileLocked(c)
		}
	}
}

// openCodeOversized handles an event too large to read: the chat it names,
// or every OpenCode chat when it names none, is read again over REST.
func (h *chatHub) openCodeOversized(pump *openCodeEventPump, directory, sessionID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if pump != h.pump || h.closed {
		return
	}
	for _, c := range h.chats {
		if !c.opencode || (sessionID != "" && c.key.sessionID != sessionID) {
			continue
		}
		if c.loading {
			c.pendingLost = true
			continue
		}
		h.requestReconcileLocked(c)
	}
}

func (h *chatHub) openCodeEvent(pump *openCodeEventPump, event openCodeEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if pump != h.pump || h.closed {
		return
	}
	switch event.kind {
	case "global.disposed", "server.instance.disposed":
		var properties struct{ Directory string }
		_ = json.Unmarshal(event.properties, &properties)
		for _, c := range h.chats {
			if c.opencode && (properties.Directory == "" || h.sameDirLocked(properties.Directory, c.project.Directory)) {
				h.requestReconcileLocked(c)
			}
		}
		return
	}
	if event.sessionID == "" {
		return
	}
	for _, c := range append([]*hubChat(nil), h.bySession[event.sessionID]...) {
		if !h.sameDirLocked(event.directory, c.project.Directory) {
			continue
		}
		if c.loading {
			if len(c.pending) >= chatPendingEvents || c.pendingBytes+len(event.properties) > chatPendingBytes {
				c.pending, c.pendingBytes, c.pendingLost = nil, 0, true
				continue
			}
			if !c.pendingLost {
				c.pending = append(c.pending, event)
				c.pendingBytes += len(event.properties)
			}
			continue
		}
		h.applyOpenCodeLocked(c, event)
	}
}

// applyOpenCodeLocked applies one OpenCode 1.18.31 bus event to a chat.
func (h *chatHub) applyOpenCodeLocked(c *hubChat, event openCodeEvent) {
	h.counter++
	touched := h.counter
	switch event.kind {
	case "message.updated":
		var properties struct {
			Info ocInfo `json:"info"`
		}
		if json.Unmarshal(event.properties, &properties) != nil || properties.Info.ID == "" {
			return
		}
		info := properties.Info
		if info.Role != "user" && info.Role != "assistant" {
			return
		}
		header := chatHeaderFromOC(info)
		if entry, _ := c.find(header.ID); entry != nil {
			c.updateHeader(entry, header, touched)
		} else {
			c.insertMessage(header, true, touched)
			c.trim()
		}
		c.applySettings(openCodeChatSettings([]ocMessage{{Info: info}}))
		c.recomputeStatus()
	case "message.removed":
		var properties struct {
			MessageID string `json:"messageID"`
		}
		if json.Unmarshal(event.properties, &properties) == nil {
			c.removeMessage(properties.MessageID)
			c.recomputeStatus()
		}
	case "message.part.updated":
		var properties struct {
			Part ocPart `json:"part"`
		}
		if json.Unmarshal(event.properties, &properties) != nil || properties.Part.ID == "" {
			return
		}
		part := properties.Part
		entry, _ := c.find(part.MessageID)
		if entry == nil {
			return
		}
		index := len(entry.parts)
		if _, existing := entry.part(part.ID); existing >= 0 {
			index = existing
		}
		mapped, ok := chatPartFromOC(part, index, c.project.Directory)
		if !ok {
			c.removePart(part.MessageID, part.ID)
			return
		}
		c.upsertPart(part.MessageID, mapped, true, touched)
	case "message.part.delta":
		var properties struct {
			MessageID string `json:"messageID"`
			PartID    string `json:"partID"`
			Field     string `json:"field"`
			Delta     string `json:"delta"`
		}
		if json.Unmarshal(event.properties, &properties) == nil {
			c.appendDelta(properties.MessageID, properties.PartID, properties.Field, properties.Delta, touched)
		}
	case "message.part.removed":
		var properties struct {
			MessageID string `json:"messageID"`
			PartID    string `json:"partID"`
		}
		if json.Unmarshal(event.properties, &properties) == nil {
			c.removePart(properties.MessageID, properties.PartID)
		}
	case "session.status":
		var properties struct {
			Status ocStatus `json:"status"`
		}
		if json.Unmarshal(event.properties, &properties) != nil {
			return
		}
		c.state, c.retry = openCodeState(properties.Status)
		c.statusTouched = touched
		c.recomputeStatus()
	case "session.idle":
		c.state, c.retry = "idle", nil
		c.statusTouched = touched
		c.recomputeStatus()
	case "session.updated":
		var properties struct {
			Info ocSession `json:"info"`
		}
		if json.Unmarshal(event.properties, &properties) != nil {
			return
		}
		c.applyInfo(ChatInfo{Title: properties.Info.Title})
		revert := ""
		if properties.Info.Revert != nil {
			revert = properties.Info.Revert.MessageID
		}
		if revert != c.seenRewind {
			// A rewind or restore changes which messages are visible: rebuild
			// the chat so every subscriber receives a fresh snapshot.
			c.seenRewind = revert
			c.rebuild = true
			h.requestReconcileLocked(c)
		}
	case "session.deleted":
		h.removeChatLocked(c)
	case "session.error":
		c.turnFailed = true
		c.recomputeStatus()
	case "permission.asked":
		var properties struct {
			ID         string          `json:"id"`
			SessionID  string          `json:"sessionID"`
			Permission string          `json:"permission"`
			Patterns   []string        `json:"patterns"`
			Metadata   json.RawMessage `json:"metadata"`
		}
		if json.Unmarshal(event.properties, &properties) != nil || properties.ID == "" {
			return
		}
		request := PermissionRequest{ID: properties.ID, SessionID: properties.SessionID, Permission: properties.Permission, Patterns: properties.Patterns, Details: string(properties.Metadata)}
		c.upsertInteraction(chatPermissionInteraction(request, chatTimeOf(h.now())), touched)
	case "question.asked":
		var properties struct {
			ID        string `json:"id"`
			SessionID string `json:"sessionID"`
			Questions []struct {
				Header, Question string
				Options          []QuestionOption
				Multiple         bool
				Custom           *bool
			} `json:"questions"`
		}
		if json.Unmarshal(event.properties, &properties) != nil || properties.ID == "" {
			return
		}
		request := QuestionRequest{ID: properties.ID, SessionID: properties.SessionID}
		for _, question := range properties.Questions {
			request.Questions = append(request.Questions, QuestionInfo{Header: question.Header, Question: question.Question, Options: question.Options, Multiple: question.Multiple, Custom: question.Custom == nil || *question.Custom})
		}
		c.upsertInteraction(chatQuestionInteraction(request, chatTimeOf(h.now())), touched)
	case "permission.replied", "question.replied", "question.rejected":
		var properties struct {
			RequestID string `json:"requestID"`
			Reply     string `json:"reply"`
		}
		if json.Unmarshal(event.properties, &properties) != nil {
			return
		}
		outcome := properties.Reply
		switch event.kind {
		case "question.replied":
			outcome = "answered"
		case "question.rejected":
			outcome = "rejected"
		}
		c.resolveInteraction(properties.RequestID, outcome, touched)
	}
}

// queueChanged announces a chat's queue after the host changed it.
func (h *chatHub) queueChanged(key sessionKey) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if c == nil || c.loading || h.closed {
		return
	}
	items := h.queueItemsLocked(key)
	if !reflect.DeepEqual(items, c.queue) {
		c.queue = items
		c.emit(evQueue{"queue.updated", clippedQueue(items)})
	}
}

// cliChanged reads a Claude Code or Codex chat again after its transcript or
// status changed.
func (h *chatHub) cliChanged(projectID, sessionID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c := h.chats[sessionKey{projectID, sessionID}]; c != nil {
		h.requestReconcileLocked(c)
	}
}

// interrupted records that the user stopped a Claude Code or Codex turn, so
// its reply shows as aborted rather than failed.
func (h *chatHub) interrupted(key sessionKey) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if c == nil || c.opencode || c.turn == "" || c.turnAborted(c.turn) {
		return
	}
	c.abortedTurns = append(c.abortedTurns, c.turn)
	if len(c.abortedTurns) > chatAbortedTurns {
		c.abortedTurns = c.abortedTurns[1:]
	}
}
