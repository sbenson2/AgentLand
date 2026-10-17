package host

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

const (
	queueCapacity = 20
	// queueSettleTimeout bounds the wait for an accepted prompt to show up in
	// the transcript before the next queued message may be sent.
	queueSettleTimeout = 90 * time.Second
	queueRestartError  = "AgentLand restarted before this message was confirmed. Check the chat before sending it again."
)

var (
	errQueueFull        = errors.New("queue is full")
	errQueueItemSending = errors.New("queued message is being sent")
)

type QueueItem struct {
	ID        string `json:"id"`
	Text      string `json:"text"`
	Model     string `json:"model,omitempty"`
	Agent     string `json:"agent,omitempty"`
	CreatedAt string `json:"createdAt"`
	Status    string `json:"status"`
	Error     string `json:"error,omitempty"`
}

type queueEntry struct {
	items []QueueItem
	// After a prompt is accepted, the next one waits until the transcript has
	// grown by a user and an assistant message past settleCount (or the timeout).
	settleSince time.Time
	settleCount int
}

type queueFileEntry struct {
	ProjectID string      `json:"projectId"`
	SessionID string      `json:"sessionId"`
	Items     []QueueItem `json:"items"`
}

// PromptQueue holds messages the host sends to a chat after its current turn.
// Items are shared by every device and survive restarts. A message whose
// delivery was not confirmed is marked failed and never sent again by the host.
type PromptQueue struct {
	mu      sync.Mutex
	path    string
	entries map[sessionKey]*queueEntry
	now     func() time.Time
}

func NewPromptQueue(path string) (*PromptQueue, error) {
	q := &PromptQueue{path: path, entries: map[sessionKey]*queueEntry{}, now: time.Now}
	data, err := readPrivateState(path)
	if errors.Is(err, os.ErrNotExist) {
		return q, nil
	}
	if err != nil {
		return nil, err
	}
	var saved []queueFileEntry
	if err := json.Unmarshal(data, &saved); err != nil {
		return nil, err
	}
	recovered := false
	for _, entry := range saved {
		for index := range entry.Items {
			if entry.Items[index].Status == "sending" {
				entry.Items[index].Status = "failed"
				entry.Items[index].Error = queueRestartError
				recovered = true
			}
		}
		if len(entry.Items) > 0 {
			q.entries[sessionKey{entry.ProjectID, entry.SessionID}] = &queueEntry{items: entry.Items}
		}
	}
	if recovered {
		if err := q.saveLocked(); err != nil {
			return nil, err
		}
	}
	return q, nil
}

func (q *PromptQueue) saveLocked() error {
	saved := []queueFileEntry{}
	for key, entry := range q.entries {
		if len(entry.items) > 0 {
			saved = append(saved, queueFileEntry{ProjectID: key.projectID, SessionID: key.sessionID, Items: entry.items})
		}
	}
	sort.Slice(saved, func(i, j int) bool {
		if saved[i].ProjectID == saved[j].ProjectID {
			return saved[i].SessionID < saved[j].SessionID
		}
		return saved[i].ProjectID < saved[j].ProjectID
	})
	data, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	return writePrivateState(q.path, append(data, '\n'))
}

// dropIdleLocked forgets a chat with no items once its settle window is over.
func (q *PromptQueue) dropIdleLocked(key sessionKey) {
	entry := q.entries[key]
	if entry == nil || len(entry.items) > 0 {
		return
	}
	if entry.settleSince.IsZero() || q.now().Sub(entry.settleSince) >= queueSettleTimeout {
		delete(q.entries, key)
	}
}

func (q *PromptQueue) Items(projectID, sessionID string) []QueueItem {
	q.mu.Lock()
	defer q.mu.Unlock()
	items := []QueueItem{}
	if entry := q.entries[sessionKey{projectID, sessionID}]; entry != nil {
		items = append(items, entry.items...)
	}
	return items
}

func (q *PromptQueue) count(key sessionKey) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	if entry := q.entries[key]; entry != nil {
		return len(entry.items)
	}
	return 0
}

func (q *PromptQueue) add(key sessionKey, text string, options PromptOptions) (QueueItem, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil {
		entry = &queueEntry{}
		q.entries[key] = entry
	}
	if len(entry.items) >= queueCapacity {
		return QueueItem{}, errQueueFull
	}
	item := QueueItem{ID: "q_" + cliMessageID(), Text: text, Model: options.Model, Agent: options.Agent, CreatedAt: q.now().UTC().Format(time.RFC3339), Status: "queued"}
	entry.items = append(entry.items, item)
	if err := q.saveLocked(); err != nil {
		entry.items = entry.items[:len(entry.items)-1]
		q.dropIdleLocked(key)
		return QueueItem{}, err
	}
	return item, nil
}

func (q *PromptQueue) remove(key sessionKey, itemID string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil {
		return ErrNotFound
	}
	for index, item := range entry.items {
		if item.ID != itemID {
			continue
		}
		if item.Status == "sending" {
			return errQueueItemSending
		}
		previous := entry.items
		entry.items = append(append([]QueueItem{}, entry.items[:index]...), entry.items[index+1:]...)
		if err := q.saveLocked(); err != nil {
			entry.items = previous
			return err
		}
		q.dropIdleLocked(key)
		return nil
	}
	return ErrNotFound
}

func (q *PromptQueue) keys() []sessionKey {
	q.mu.Lock()
	defer q.mu.Unlock()
	keys := make([]sessionKey, 0, len(q.entries))
	for key := range q.entries {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].projectID == keys[j].projectID {
			return keys[i].sessionID < keys[j].sessionID
		}
		return keys[i].projectID < keys[j].projectID
	})
	return keys
}

// next returns the head item and settle state when the head is waiting.
func (q *PromptQueue) next(key sessionKey) (QueueItem, time.Time, int, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.dropIdleLocked(key)
	entry := q.entries[key]
	if entry == nil || len(entry.items) == 0 || entry.items[0].Status != "queued" {
		return QueueItem{}, time.Time{}, 0, false
	}
	return entry.items[0], entry.settleSince, entry.settleCount, true
}

// settle records an accepted prompt; count is the transcript length before it.
func (q *PromptQueue) settle(key sessionKey, count int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil {
		entry = &queueEntry{}
		q.entries[key] = entry
	}
	entry.settleSince = q.now()
	entry.settleCount = count
}

// begin durably marks the head as sending before any delivery attempt, so a
// restart during delivery can only turn it into a failed item.
func (q *PromptQueue) begin(key sessionKey, itemID string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil || len(entry.items) == 0 || entry.items[0].ID != itemID || entry.items[0].Status != "queued" {
		return false
	}
	entry.items[0].Status = "sending"
	if err := q.saveLocked(); err != nil {
		entry.items[0].Status = "queued"
		return false
	}
	return true
}

// finish removes a delivered item, starting its settle window from count, or
// marks it failed. Failed items are never retried and hold back the rest of
// the chat's queue until removed.
func (q *PromptQueue) finish(key sessionKey, itemID, failure string, count int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil {
		return
	}
	for index, item := range entry.items {
		if item.ID != itemID {
			continue
		}
		if failure == "" {
			entry.items = append(append([]QueueItem{}, entry.items[:index]...), entry.items[index+1:]...)
			entry.settleSince = q.now()
			entry.settleCount = count
		} else {
			entry.items[index].Status = "failed"
			entry.items[index].Error = failure
		}
		_ = q.saveLocked()
		return
	}
}

// requeue puts a head that was being sent back in the queue, as it was: its
// delivery certainly did not happen (sendQueued).
func (q *PromptQueue) requeue(key sessionKey, itemID string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil || len(entry.items) == 0 || entry.items[0].ID != itemID || entry.items[0].Status != "sending" {
		return
	}
	entry.items[0].Status, entry.items[0].Error = "queued", ""
	_ = q.saveLocked()
}

// fail marks a waiting head that can no longer be delivered.
func (q *PromptQueue) fail(key sessionKey, itemID, failure string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	entry := q.entries[key]
	if entry == nil || len(entry.items) == 0 || entry.items[0].ID != itemID || entry.items[0].Status != "queued" {
		return
	}
	entry.items[0].Status = "failed"
	entry.items[0].Error = failure
	_ = q.saveLocked()
}

func queueFailure(err error) string {
	switch {
	case errors.Is(err, ErrCLIChatBusy):
		return "The agent was busy, so this message was not sent."
	case errors.Is(err, ErrCLIChatUnavailable), errors.Is(err, errOptionsUnsupported):
		return "This chat no longer accepts the selected model or mode, so this message was not sent."
	case errors.Is(err, ErrNotFound):
		return "This chat is no longer available."
	case promptNotDelivered(err):
		return "The agent did not accept this message."
	default:
		return "AgentLand could not confirm this message was delivered. Check the chat before sending it again."
	}
}

func (h *Host) dispatchQueue(stop <-chan struct{}) {
	for _, key := range h.queue.keys() {
		select {
		case <-stop:
			return
		default:
		}
		h.dispatchNext(key)
	}
}

// dispatchNext sends one chat's head item when the chat is idle, not rewound,
// and has settled after the previous prompt accepted through this host.
func (h *Host) dispatchNext(key sessionKey) {
	item, _, _, waiting := h.queue.next(key)
	if !waiting {
		return
	}
	defer h.chat.queueChanged(key)
	project, err := h.chatProject(key.projectID)
	if errors.Is(err, ErrNotFound) {
		h.queue.fail(key, item.ID, queueFailure(err))
		return
	}
	if err != nil {
		return
	}
	// Plain chats: queued messages wait while the chat agent is not
	// confirmed. A Claude Code or Codex chat of the Chats space is read-only:
	// what was queued before stays queued and unsent.
	if h.isPlainChat(project) && (cliChatProvider(key.sessionID) != "" || (!isCLISessionID(key.sessionID) && !h.plainChats.confirmedNow())) {
		return
	}
	unlock := h.lockSession(key.projectID, key.sessionID)
	defer unlock()
	// Read the head and settle window again: a direct prompt or a removal may
	// have happened while this dispatcher waited for the chat.
	item, settleSince, settleCount, waiting := h.queue.next(key)
	if !waiting {
		return
	}
	state, err := h.chatState(project, key.sessionID)
	if errors.Is(err, ErrNotFound) {
		h.queue.fail(key, item.ID, queueFailure(err))
		return
	}
	if err != nil || state != "idle" {
		return
	}
	session, err := h.session(project, key.sessionID)
	if errors.Is(err, ErrNotFound) {
		h.queue.fail(key, item.ID, queueFailure(err))
		return
	}
	if err != nil || session.RewindMessageID != "" {
		return
	}
	transcript, err := h.transcript(project, session)
	if err != nil {
		return
	}
	if !settleSince.IsZero() && h.queue.now().Sub(settleSince) < queueSettleTimeout && len(transcript) < settleCount+2 {
		return
	}
	// No delivery begins once the host is stopping: the message stays queued
	// for the next start.
	if h.stoppingNow() || !h.queue.begin(key, item.ID) {
		return
	}
	h.chat.queueChanged(key)
	h.sendQueued(key, item, project, session, len(transcript))
}

// sendQueued delivers the head that begin marked sending; count is the
// transcript's length before it. A message the agent certainly did not get
// (deliveryDefinitelyFailed) while the host began stopping (its agents'
// processes end at BeginShutdown, so they refuse it) goes back to queued:
// the queue is kept on disk, so the next start sends it, once. Otherwise a
// refusal marks it failed, and a delivery that may have happened stays
// failed with "could not confirm", as ever.
func (h *Host) sendQueued(key sessionKey, item QueueItem, project Project, session Session, count int) {
	_, err := h.deliverPrompt(project, session, item.Text, PromptOptions{Model: item.Model, Agent: item.Agent}, nil)
	switch {
	case err == nil:
		h.queue.finish(key, item.ID, "", count)
	case h.stoppingNow() && deliveryDefinitelyFailed(session, err):
		h.queue.requeue(key, item.ID)
	case errors.Is(err, errPlainChatUnavailable), errors.Is(err, errChatsSpaceRetired):
		// The chat agent was not confirmed at the send (a check failed after
		// dispatchNext's), or the chat is read-only: nothing was sent, and
		// the message waits.
		h.queue.requeue(key, item.ID)
	default:
		h.queue.finish(key, item.ID, queueFailure(err), count)
	}
}

// stoppingNow reports whether the host's shutdown has begun (BeginShutdown).
func (h *Host) stoppingNow() bool {
	select {
	case <-h.stopping:
		return true
	default:
		return false
	}
}

func (h *Host) queueAvailable(w http.ResponseWriter) bool {
	if h.queue == nil {
		writeError(w, 501, "unsupported_operation", "This host does not keep a message queue")
		return false
	}
	return true
}

func (h *Host) listQueue(w http.ResponseWriter, r *http.Request) {
	if !h.queueAvailable(w) {
		return
	}
	p, s, ok := h.chatScoped(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("sessionId"))
	if !ok {
		return
	}
	writeJSON(w, 200, map[string]any{"items": h.queue.Items(p.ID, s.ID)})
}

func (h *Host) addQueue(w http.ResponseWriter, r *http.Request) {
	if !h.queueAvailable(w) {
		return
	}
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		Text      string `json:"text"`
		Model     string `json:"model,omitempty"`
		Agent     string `json:"agent,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Text == "" || len(in.Text) > maxPromptText {
		writeError(w, 400, "invalid_request", "Text is required and must not exceed 32768 bytes")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	// Plain chats: the chat agent runs every prompt, and the Chats space's
	// Claude Code and Codex chats take nothing new.
	if h.chatsSpaceReadOnly(w, p, s) || (h.isPlainChat(p) && plainChatOptionsRefused(w, in.Agent)) {
		return
	}
	options := PromptOptions{Model: in.Model, Agent: in.Agent}
	if !validPromptOptions(options) {
		writeError(w, 400, "invalid_request", "Choose a valid model and agent mode")
		return
	}
	if isCLISessionID(s.ID) {
		if !cliOptionsSupported(s.Provider, options) {
			writeError(w, 400, "invalid_agent_options", "Choose settings supported by this Mac agent")
			return
		}
	} else if _, configurable := h.agent.(ConfigurableAgent); !configurable && (options.Model != "" || options.Agent != "") {
		writeError(w, 400, "unsupported_options", "This host does not support model overrides")
		return
	}
	item, err := h.queue.add(sessionKey{p.ID, s.ID}, in.Text, options)
	if errors.Is(err, errQueueFull) {
		writeError(w, 409, "queue_full", "A chat can hold at most 20 queued messages")
		return
	}
	if err != nil {
		writeError(w, 500, "storage_error", "The host could not save the queue")
		return
	}
	h.chat.queueChanged(sessionKey{p.ID, s.ID})
	writeJSON(w, 201, item)
}

func (h *Host) removeQueue(w http.ResponseWriter, r *http.Request) {
	if !h.queueAvailable(w) {
		return
	}
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		ItemID    string `json:"itemId"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.ItemID == "" {
		writeError(w, 400, "invalid_request", "A queued message is required")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	switch err := h.queue.remove(sessionKey{p.ID, s.ID}, in.ItemID); {
	case errors.Is(err, ErrNotFound):
		writeError(w, 404, "not_found", "Queued message not found")
	case errors.Is(err, errQueueItemSending):
		writeError(w, 409, "queue_item_sending", "This message is being sent now")
	case err != nil:
		writeError(w, 500, "storage_error", "The host could not save the queue")
	default:
		h.chat.queueChanged(sessionKey{p.ID, s.ID})
		writeJSON(w, 200, map[string]bool{"removed": true})
	}
}
