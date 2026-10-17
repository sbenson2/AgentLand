package host

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Notices (M5): short records of chat events for this Mac's
// app, which turns them into notifications through the owner's iCloud. The
// host keeps them only when it runs with the Mac's local session (the only
// reader): in the archive's notices table when it keeps an archive, otherwise
// in memory; 7 days and 1000 notices at most either way.
//
// A notice names a kind, the project and chat it concerns and the chat's
// title, never message text. The chat hub reports turns that end and
// approvals or questions that appear (chat_hub_events.go). A chat notice is
// not issued while a present device reported viewing that chat within 45 s, a
// second approval (or question) notice for one chat within 10 s of the last
// one is left out, and one turn or interaction gives one notice. Retained
// schedule.run notices from before schedules were removed (2026-10-06) are
// left out when the host starts.
//
// POST /v1/device/presence also takes the chat a device shows (view). Views
// live in memory only and lapse with the device's presence or revocation.

const (
	noticeRetention  = 7 * 24 * time.Hour
	noticeKeep       = 1000
	noticeViewWindow = 45 * time.Second
	noticeCoalesce   = 10 * time.Second
	noticePageLimit  = 100
	noticeMaxWait    = 20 * time.Second
	noticeQueueLimit = 1024
	noticeRecentKeys = 512
)

const (
	noticeTurnFinished   = "chat.turn.finished"
	noticeTurnFailed     = "chat.turn.failed"
	noticeApprovalNeeded = "chat.approval.needed"
	noticeQuestionNeeded = "chat.question.needed"
)

var errNoticeAhead = errors.New("no notice has that sequence number yet")

// Notice is one notice as GET /v1/notices returns it.
type Notice struct {
	Seq               int64  `json:"seq"`
	ID                string `json:"id"`
	Kind              string `json:"kind"`
	ProjectID         string `json:"projectId"`
	ProjectName       string `json:"projectName"`
	SessionID         string `json:"sessionId,omitempty"`
	Title             string `json:"title"`
	MayContainContent bool   `json:"mayContainContent"`
	CreatedAt         string `json:"createdAt"`

	created time.Time
}

// noticeEvent is a notice waiting to be checked and recorded.
type noticeEvent struct {
	notice Notice
	at     time.Time
	// chat notices are left out while a device views the chat.
	chat bool
	// dedupe names the turn or interaction, which gives one notice.
	dedupe string
	// coalesce groups approval (or question) notices of one chat.
	coalesce string
}

type noticeCenter struct {
	host    *Host
	archive *Archive
	epoch   string
	// Test seams.
	now                     func() time.Time
	coalesceFor, viewWindow time.Duration

	mu      sync.Mutex
	items   []Notice // retained, oldest first
	last    int64    // newest sequence number ever issued
	acked   int64
	changed chan struct{} // closed and replaced when a notice is recorded
	pending []noticeEvent
	closed  bool

	// Only the worker uses these.
	recent      map[string]bool
	recentOrder []string
	lastSent    map[string]time.Time

	wake    chan struct{}
	done    chan struct{}
	stopped chan struct{}
}

func newNoticeCenter(host *Host) *noticeCenter {
	n := &noticeCenter{host: host, archive: host.archive, now: time.Now, coalesceFor: noticeCoalesce, viewWindow: noticeViewWindow, changed: make(chan struct{}),
		recent: map[string]bool{}, lastSent: map[string]time.Time{}, wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{})}
	if n.archive != nil {
		// Notices past 7 days go at the first maintenance, a second later.
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		state, err := n.archive.NoticeState(ctx, noticeKeep)
		cancel()
		if err == nil {
			n.epoch, n.last, n.acked = n.archive.epoch, state.Last, state.Acked
			for _, stored := range state.Notices {
				if strings.HasPrefix(stored.Kind, "schedule.") {
					continue // a schedule run's, from before schedules were removed
				}
				created := stored.CreatedAt
				n.items = append(n.items, Notice{Seq: stored.Seq, ID: stored.ID, Kind: stored.Kind, ProjectID: stored.ProjectID, ProjectName: stored.ProjectName,
					SessionID: stored.ChatID, Title: stored.Title, MayContainContent: stored.MayContainContent,
					CreatedAt: chatTimeOf(created), created: created})
			}
		} else {
			// Keep them in memory rather than reuse a number the table holds.
			n.archive = nil
		}
	}
	if n.epoch == "" {
		n.epoch = archiveRandomID(8)
	}
	go n.run()
	return n
}

// enqueue hands an event to the worker without blocking. It may run under
// the chat hub's lock.
func (n *noticeCenter) enqueue(event noticeEvent) {
	n.mu.Lock()
	if n.closed || len(n.pending) >= noticeQueueLimit {
		n.mu.Unlock()
		return
	}
	n.pending = append(n.pending, event)
	n.mu.Unlock()
	notifyArchive(n.wake)
}

// chatObserved is the chat hub's observer (chat_hub_events.go). It runs
// under the hub's lock.
func (h *Host) chatObserved(event hubEvent) {
	h.notices.fromChat(event)
}

// fromChat turns a hub event into a chat notice. A chat's title may come
// from its content (providers and apps name chats after the first message).
func (n *noticeCenter) fromChat(event hubEvent) {
	if n == nil {
		return
	}
	notice := Notice{ProjectID: event.key.projectID, SessionID: event.key.sessionID, Title: event.title, MayContainContent: event.title != ""}
	queued := noticeEvent{at: n.now(), chat: true}
	switch interaction := event.interaction; {
	case interaction != nil:
		notice.Kind = noticeApprovalNeeded
		if interaction.Kind == "question" {
			notice.Kind = noticeQuestionNeeded
		}
		queued.dedupe = "interaction\x00" + event.key.sessionID + "\x00" + interaction.ID
		queued.coalesce = notice.Kind + "\x00" + event.key.projectID + "\x00" + event.key.sessionID
	case event.outcome == "completed":
		notice.Kind = noticeTurnFinished
	case event.outcome == "error":
		notice.Kind = noticeTurnFailed
	default:
		return // stopped by someone
	}
	if event.turn != "" && event.interaction == nil {
		queued.dedupe = "turn\x00" + event.key.sessionID + "\x00" + event.turn
	}
	queued.notice = notice
	n.enqueue(queued)
}

// run records queued events in order until close.
func (n *noticeCenter) run() {
	defer close(n.stopped)
	for {
		n.mu.Lock()
		batch := n.pending
		n.pending = nil
		n.mu.Unlock()
		for _, event := range batch {
			n.process(event)
		}
		if len(batch) > 0 {
			continue
		}
		select {
		case <-n.wake:
		case <-n.done:
			n.mu.Lock()
			batch := n.pending
			n.pending = nil
			n.mu.Unlock()
			for _, event := range batch {
				n.process(event)
			}
			return
		}
	}
}

// process applies deduplication, the viewing rule and coalescing, then
// records the notice.
func (n *noticeCenter) process(event noticeEvent) {
	if event.dedupe != "" {
		if n.recent[event.dedupe] {
			return
		}
		n.recent[event.dedupe] = true
		n.recentOrder = append(n.recentOrder, event.dedupe)
		if len(n.recentOrder) > noticeRecentKeys {
			delete(n.recent, n.recentOrder[0])
			n.recentOrder = n.recentOrder[1:]
		}
	}
	if event.chat && n.host.viewing(event.notice.ProjectID, event.notice.SessionID, event.at, n.viewWindow) {
		return
	}
	if event.coalesce != "" {
		if last, sent := n.lastSent[event.coalesce]; sent && event.at.Sub(last) < n.coalesceFor && !event.at.Before(last) {
			return
		}
		n.lastSent[event.coalesce] = event.at
		if len(n.lastSent) > noticeRecentKeys {
			for key, at := range n.lastSent {
				if event.at.Sub(at) >= n.coalesceFor {
					delete(n.lastSent, key)
				}
			}
		}
	}
	// A plain chat's notice names the Chats space.
	project, err := n.host.chatProject(event.notice.ProjectID)
	if err != nil {
		return // the project left the configuration
	}
	notice := event.notice
	notice.ID = "ntc_" + cliMessageID()
	notice.ProjectName = project.Name
	notice.created = event.at.Round(0).UTC()
	notice.CreatedAt = chatTimeOf(notice.created)
	n.record(notice)
}

func (n *noticeCenter) record(notice Notice) {
	n.mu.Lock()
	n.last++
	notice.Seq = n.last
	n.items = append(n.items, notice)
	n.pruneLocked(notice.created)
	close(n.changed)
	n.changed = make(chan struct{})
	archive := n.archive
	n.mu.Unlock()
	if archive == nil {
		return
	}
	stored := ArchiveNotice{Seq: notice.Seq, ID: notice.ID, Kind: notice.Kind, ProjectID: notice.ProjectID, ProjectName: notice.ProjectName, ChatID: notice.SessionID,
		Title: notice.Title, MayContainContent: notice.MayContainContent, CreatedAt: notice.created}
	if err := archive.RecordNotice(stored, notice.created.Add(-noticeRetention), noticeKeep); err != nil && !errors.Is(err, ErrArchiveClosed) {
		archive.recordFailure(fmt.Errorf("record notice: %w", err))
	}
}

// pruneLocked drops notices older than 7 days and all but the newest 1000.
func (n *noticeCenter) pruneLocked(now time.Time) {
	cutoff := now.Add(-noticeRetention)
	drop := 0
	for drop < len(n.items) && (len(n.items)-drop > noticeKeep || n.items[drop].created.Before(cutoff)) {
		drop++
	}
	if drop > 0 {
		n.items = append([]Notice(nil), n.items[drop:]...)
	}
}

// maintain runs from the host's maintenance loop.
func (n *noticeCenter) maintain() {
	now := n.now()
	n.mu.Lock()
	n.pruneLocked(now)
	n.mu.Unlock()
	n.host.views.expire(now, n.viewWindow)
}

// pageLocked returns the notices after seq, at most one page.
func (n *noticeCenter) pageLocked(after int64) ([]Notice, bool) {
	start := sort.Search(len(n.items), func(i int) bool { return n.items[i].Seq > after })
	end := min(len(n.items), start+noticePageLimit)
	return append([]Notice{}, n.items[start:end]...), end < len(n.items)
}

// ack records that the app handled every notice through seq; it never moves
// back.
func (n *noticeCenter) ack(through int64) (int64, error) {
	n.mu.Lock()
	if through > n.last {
		n.mu.Unlock()
		return 0, errNoticeAhead
	}
	n.acked = max(n.acked, through)
	acked, archive := n.acked, n.archive
	n.mu.Unlock()
	if archive != nil {
		if err := archive.AckNotices(acked); err != nil {
			return acked, err
		}
	}
	return acked, nil
}

// close records what is queued and stops the worker; the archive closes
// after it.
func (n *noticeCenter) close() {
	if n == nil {
		return
	}
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return
	}
	n.closed = true
	n.mu.Unlock()
	close(n.done)
	<-n.stopped
}

// Routes (local-only: this Mac's app).

type noticePage struct {
	Notices []Notice `json:"notices"`
	Cursor  string   `json:"cursor"`
	HasMore bool     `json:"hasMore"`
	Resync  bool     `json:"resync"`
}

// listNotices serves GET /v1/notices?after&wait: the notices after the
// cursor (after the acknowledged ones without it), at most 100. With wait (at
// most 20000 ms) and nothing to return, it waits for the next notice. A
// cursor from another epoch (a new archive, or a host without one that
// restarted) starts over with resync.
func (h *Host) listNotices(w http.ResponseWriter, r *http.Request) {
	n := h.notices
	if n == nil {
		writeError(w, 501, "notices_unavailable", "This host keeps no notices")
		return
	}
	query := r.URL.Query()
	wait := time.Duration(0)
	if raw := query.Get("wait"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 || time.Duration(value)*time.Millisecond > noticeMaxWait {
			writeError(w, 400, "invalid_request", "wait must be between 0 and 20000 milliseconds")
			return
		}
		wait = time.Duration(value) * time.Millisecond
	}
	after := query.Get("after")
	if len(after) > 64 {
		writeError(w, 400, "invalid_request", "The cursor is not valid")
		return
	}
	n.mu.Lock()
	from, resync := n.acked, false
	if after != "" {
		epoch, seq, ok := parseChatCursor(after)
		if !ok || seq > math.MaxInt64 {
			n.mu.Unlock()
			writeError(w, 400, "invalid_request", "The cursor is not valid")
			return
		}
		from = int64(seq)
		if epoch != n.epoch || from > n.last {
			from, resync = 0, true
		}
	}
	epoch := n.epoch
	n.mu.Unlock()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	expired := wait <= 0
	for {
		n.mu.Lock()
		notices, more := n.pageLocked(from)
		changed := n.changed
		n.mu.Unlock()
		if len(notices) > 0 || expired {
			cursor := from
			if len(notices) > 0 {
				cursor = notices[len(notices)-1].Seq
			}
			writeJSON(w, 200, noticePage{Notices: notices, Cursor: epoch + "." + strconv.FormatInt(cursor, 10), HasMore: more, Resync: resync})
			return
		}
		select {
		case <-changed:
		case <-timer.C:
			expired = true
		case <-h.stopping:
			expired = true
		case <-r.Context().Done():
			return
		}
	}
}

// ackNotices serves POST /v1/notices/ack {through}: the seq of the newest
// notice the app has handled.
func (h *Host) ackNotices(w http.ResponseWriter, r *http.Request) {
	n := h.notices
	if n == nil {
		writeError(w, 501, "notices_unavailable", "This host keeps no notices")
		return
	}
	var in struct {
		Through *int64 `json:"through"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Through == nil || *in.Through < 0 {
		writeError(w, 400, "invalid_request", "through must be the seq of a notice")
		return
	}
	acked, err := n.ack(*in.Through)
	switch {
	case errors.Is(err, errNoticeAhead):
		writeError(w, 400, "invalid_request", "No notice has that seq yet; the host may have started over")
	case err != nil:
		writeError(w, 500, "storage_error", "The host could not save the acknowledgement")
	default:
		writeJSON(w, 200, map[string]int64{"acked": acked})
	}
}

// Presence views.

// presenceViewInput is the view member of POST /v1/device/presence.
type presenceViewInput struct {
	ProjectID string `json:"projectId"`
	SessionID string `json:"sessionId"`
}

func (v *presenceViewInput) valid() bool {
	return v.ProjectID != "" && v.SessionID != "" && len(v.ProjectID) <= archiveIDLimit && len(v.SessionID) <= archiveIDLimit
}

type presenceView struct {
	projectID, sessionID string
	at                   time.Time
}

// presenceViews holds the chat each present device reported showing, in
// memory only.
type presenceViews struct {
	mu    sync.Mutex
	views map[string]presenceView // by device ID
}

// update records a device's view with its heartbeat; a heartbeat without a
// view, or an inactive one, clears it.
func (v *presenceViews) update(device string, active bool, view *presenceViewInput, at time.Time) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if !active || view == nil {
		delete(v.views, device)
		return
	}
	if v.views == nil {
		v.views = map[string]presenceView{}
	}
	v.views[device] = presenceView{projectID: view.ProjectID, sessionID: view.SessionID, at: at}
}

// viewers lists the devices that reported viewing the chat within window
// of at.
func (v *presenceViews) viewers(projectID, sessionID string, at time.Time, window time.Duration) []string {
	v.mu.Lock()
	defer v.mu.Unlock()
	var devices []string
	for device, view := range v.views {
		if view.projectID == projectID && view.sessionID == sessionID && at.Sub(view.at) < window {
			devices = append(devices, device)
		}
	}
	return devices
}

func (v *presenceViews) forget(devices []string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	for _, device := range devices {
		delete(v.views, device)
	}
}

// forgetProject drops the views of a removed workspace's chats.
func (v *presenceViews) forgetProject(projectID string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	for device, view := range v.views {
		if view.projectID == projectID {
			delete(v.views, device)
		}
	}
}

// expire drops views older than window.
func (v *presenceViews) expire(now time.Time, window time.Duration) {
	v.mu.Lock()
	defer v.mu.Unlock()
	for device, view := range v.views {
		if now.Sub(view.at) >= window {
			delete(v.views, device)
		}
	}
}

// viewing reports whether a present, not revoked device reported viewing the
// chat within window of at. Views of devices that are gone or revoked are
// dropped.
func (h *Host) viewing(projectID, sessionID string, at time.Time, window time.Duration) bool {
	devices := h.views.viewers(projectID, sessionID, at, window)
	if len(devices) == 0 {
		return false
	}
	state, err := h.store.Read()
	if err != nil {
		return false
	}
	present := false
	var gone []string
	for _, id := range devices {
		index := slices.IndexFunc(state.Devices, func(device Device) bool { return device.ID == id })
		if index >= 0 && devicePresentAt(state.Devices[index], at) {
			present = true
		} else {
			gone = append(gone, id)
		}
	}
	h.views.forget(gone)
	return present
}

// devicePresentAt is Device.IsPresent that also counts a heartbeat made
// just after at.
func devicePresentAt(device Device, at time.Time) bool {
	if device.RevokedAt != nil || device.LastSeenAt == nil {
		return false
	}
	since := at.Sub(*device.LastSeenAt)
	return since < presenceTTL && since > -presenceTTL
}
