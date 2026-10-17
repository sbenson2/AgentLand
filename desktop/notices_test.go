package host

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// noticeFixture is a host with CLI chats (the fake runner, or the fake
// codex), this Mac's session for notices and one injected clock for notices
// and presence.
type noticeFixture struct {
	t       *testing.T
	host    *Host
	store   *Store
	token   string
	clock   *testClock
	chats   *CLIChats
	archive *Archive
}

type noticeFixtureOptions struct {
	archive bool
	codex   bool
}

func newNoticeFixture(t *testing.T, options noticeFixtureOptions) *noticeFixture {
	t.Helper()
	directory := t.TempDir()
	oc := newFakeOpenCode(t, directory)
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "host.json"))
	if err := store.Initialize(Config{OpenCodeURL: oc.server.URL, PasswordEnv: "FIXTURE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Fixture", Directory: directory}}}); err != nil {
		t.Fatal(err)
	}
	f := &noticeFixture{t: t, store: store, clock: &testClock{now: time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)}}
	var runner CLIChatRunner = &fakeCLIChatRunner{}
	if options.codex {
		runner = codexTestRunner{config: newCodexFake(t).config()}
	}
	var err error
	if f.chats, err = NewCLIChats(store.Path+".chats.json", runner); err != nil {
		t.Fatal(err)
	}
	if options.archive {
		f.archive = openTestArchive(t, store.Path+".archive", ArchiveOptions{})
	}
	host := newHost(store, NewOpenCodeAdapter(oc.server.URL, "opencode", "fixture", oc.server.Client()), HostOptions{CLIChats: f.chats, Archive: f.archive, LocalSessionToken: routeLocalToken})
	host.now = f.clock.Now
	store.now = f.clock.Now
	host.notices.now = f.clock.Now
	f.host = host
	t.Cleanup(func() { host.Close() })
	f.token = paired(t, host, store)
	return f
}

func (f *noticeFixture) call(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return request(f.t, f.host.Handler(), method, path, f.token, body)
}

func (f *noticeFixture) local(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return localRequest(f.t, f.host.Handler(), method, path, routeLocalToken, body)
}

// flushNotices waits until every event queued so far is processed: it queues
// a notice of its own, about a chat of its own, and waits for it (the worker
// keeps order).
func (f *noticeFixture) flushNotices() {
	f.t.Helper()
	id := "flush_" + cliMessageID()
	f.host.notices.enqueue(noticeEvent{at: f.clock.Now(), dedupe: "flush\x00" + id, notice: Notice{Kind: noticeTurnFinished, ProjectID: "p1", SessionID: id, Title: "flush"}})
	waitFor(f.t, "the notice worker", func() bool {
		f.host.notices.mu.Lock()
		defer f.host.notices.mu.Unlock()
		for _, notice := range f.host.notices.items {
			if notice.SessionID == id {
				return true
			}
		}
		return false
	})
}

// chatNotices lists the recorded notices about one chat.
func (f *noticeFixture) chatNotices(sessionID string) []Notice {
	f.host.notices.mu.Lock()
	defer f.host.notices.mu.Unlock()
	var result []Notice
	for _, notice := range f.host.notices.items {
		if notice.SessionID == sessionID {
			result = append(result, notice)
		}
	}
	return result
}

func turnEnded(sessionID, turn, outcome string) hubEvent {
	return hubEvent{key: sessionKey{"p1", sessionID}, title: "Chat " + sessionID, turn: turn, outcome: outcome}
}

func interactionAsked(sessionID, id, kind string) hubEvent {
	return hubEvent{key: sessionKey{"p1", sessionID}, title: "Chat " + sessionID, interaction: &ChatInteraction{ID: id, ChatID: sessionID, Kind: kind}}
}

func TestNoticesForChatTurnsAndInteractions(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{codex: true})
	chat := func(title string) string {
		w := f.call("POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": title, "provider": "codex"})
		if w.Code != 201 {
			t.Fatalf("create: %d %s", w.Code, w.Body)
		}
		return decodeBody[Session](t, w).ID
	}
	send := func(id, text string) {
		if w := f.call("POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": id, "text": text}); w.Code != 202 {
			t.Fatalf("send %q: %d %s", text, w.Code, w.Body)
		}
	}
	waitKind := func(id, kind string) Notice {
		var found Notice
		waitFor(t, kind+" for "+id, func() bool {
			for _, notice := range f.chatNotices(id) {
				if notice.Kind == kind {
					found = notice
					return true
				}
			}
			return false
		})
		return found
	}
	finished := chat("Plan the release")
	send(finished, "Private words in the prompt")
	notice := waitKind(finished, noticeTurnFinished)
	if notice.Title != "Plan the release" || !notice.MayContainContent || notice.ProjectID != "p1" || notice.ProjectName != "Fixture" || !strings.HasPrefix(notice.ID, "ntc_") || notice.CreatedAt != "2026-09-23T12:00:00.000Z" {
		t.Fatalf("finished: %+v", notice)
	}
	failed := chat("Failing chat")
	send(failed, "FAIL with private words")
	waitKind(failed, noticeTurnFailed)
	approval := chat("Needs approval")
	send(approval, "APPROVE private words")
	waitKind(approval, noticeApprovalNeeded)
	var pending struct{ Permissions []PermissionRequest }
	json.Unmarshal(f.call("GET", "/v1/interactions?projectId=p1&sessionId="+approval, nil).Body.Bytes(), &pending)
	if len(pending.Permissions) != 1 {
		t.Fatalf("pending permissions %+v", pending)
	}
	if w := f.call("POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": approval, "requestId": pending.Permissions[0].ID, "reply": "once"}); w.Code != 200 {
		t.Fatalf("reply: %d %s", w.Code, w.Body)
	}
	waitKind(approval, noticeTurnFinished)
	question := chat("Needs an answer")
	send(question, "ASK private words")
	waitKind(question, noticeQuestionNeeded)
	var asked struct{ Questions []QuestionRequest }
	json.Unmarshal(f.call("GET", "/v1/interactions?projectId=p1&sessionId="+question, nil).Body.Bytes(), &asked)
	if len(asked.Questions) != 1 {
		t.Fatalf("pending questions %+v", asked)
	}
	f.call("POST", "/v1/questions/reject", map[string]string{"projectId": "p1", "sessionId": question, "requestId": asked.Questions[0].ID})
	waitKind(question, noticeTurnFinished)
	f.flushNotices()
	// One notice per event, and never message text.
	for _, id := range []string{finished, failed, approval, question} {
		kinds := map[string]int{}
		for _, notice := range f.chatNotices(id) {
			kinds[notice.Kind]++
		}
		for kind, count := range kinds {
			if count != 1 {
				t.Errorf("%s: %d %s notices", id, count, kind)
			}
		}
	}
	body := f.local("GET", "/v1/notices", nil).Body.String()
	for _, text := range []string{"private", "Private", "Hello from the fake Codex", "Finished.", "Thanks.", "fake provider refused"} {
		if strings.Contains(body, text) {
			t.Fatalf("a notice carries message text %q: %s", text, body)
		}
	}
}

func TestNoticesSkipAChatBeingViewed(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{})
	presence := func(body any) {
		t.Helper()
		if w := f.call("POST", "/v1/device/presence", body); w.Code != 200 {
			t.Fatalf("presence: %d %s", w.Code, w.Body)
		}
	}
	view := func(sessionID string) map[string]any {
		return map[string]any{"active": true, "view": map[string]string{"projectId": "p1", "sessionId": sessionID}}
	}
	presence(view("viewed"))
	f.host.notices.fromChat(turnEnded("viewed", "t1", "completed"))
	f.host.notices.fromChat(interactionAsked("viewed", "i1", "permission"))
	f.host.notices.fromChat(turnEnded("other", "t1", "completed"))
	f.flushNotices()
	if got := f.chatNotices("viewed"); len(got) != 0 {
		t.Fatalf("notices for the viewed chat: %+v", got)
	}
	if got := f.chatNotices("other"); len(got) != 1 {
		t.Fatalf("notices for another chat: %+v", got)
	}
	// 45 s after the device last said so, the chat is no longer viewed.
	f.clock.Advance(45 * time.Second)
	f.host.notices.fromChat(turnEnded("viewed", "t2", "completed"))
	f.flushNotices()
	if got := f.chatNotices("viewed"); len(got) != 1 {
		t.Fatalf("after the view lapsed: %+v", got)
	}
	// A device in the background views nothing.
	presence(view("viewed"))
	presence(map[string]any{"active": false})
	f.host.notices.fromChat(turnEnded("viewed", "t3", "completed"))
	f.flushNotices()
	if got := f.chatNotices("viewed"); len(got) != 2 {
		t.Fatalf("after going to the background: %+v", got)
	}
	// A heartbeat without a view clears it too.
	presence(view("viewed"))
	presence(map[string]any{"active": true})
	f.host.notices.fromChat(turnEnded("viewed", "t4", "completed"))
	f.flushNotices()
	if got := f.chatNotices("viewed"); len(got) != 3 {
		t.Fatalf("after a heartbeat without a view: %+v", got)
	}
	// A revoked device's view counts for nothing and is dropped.
	presence(view("viewed"))
	state, _ := f.store.Read()
	if err := f.store.RevokeDevice(state.Devices[0].ID); err != nil {
		t.Fatal(err)
	}
	f.host.notices.fromChat(turnEnded("viewed", "t5", "completed"))
	f.flushNotices()
	if got := f.chatNotices("viewed"); len(got) != 4 {
		t.Fatalf("after revocation: %+v", got)
	}
	if viewers := f.host.views.viewers("p1", "viewed", f.clock.Now(), time.Minute); len(viewers) != 0 {
		t.Fatalf("a revoked device's view was kept: %v", viewers)
	}
}

func TestPresenceViewIsValidatedAndKeptInMemory(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{})
	for _, view := range []map[string]string{{"projectId": "p1"}, {"sessionId": "s"}, {"projectId": "p1", "sessionId": strings.Repeat("s", 257)}} {
		if w := f.call("POST", "/v1/device/presence", map[string]any{"active": true, "view": view}); w.Code != 400 {
			t.Errorf("view %v: %d %s", view, w.Code, w.Body)
		}
	}
	if w := f.call("POST", "/v1/device/presence", map[string]any{"active": true, "view": map[string]string{"projectId": "p1", "sessionId": "s1", "extra": "x"}}); w.Code != 400 {
		t.Errorf("unknown view field: %d", w.Code)
	}
	if w := f.call("POST", "/v1/device/presence", map[string]any{"active": true, "view": map[string]string{"projectId": "p1", "sessionId": "claude:abc"}}); w.Code != 200 {
		t.Fatalf("view: %d %s", w.Code, w.Body)
	}
	state, err := f.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(state)
	if strings.Contains(string(data), "claude:abc") || strings.Contains(string(data), "view") {
		t.Fatalf("the view reached host state: %s", data)
	}
	if viewers := f.host.views.viewers("p1", "claude:abc", f.clock.Now(), noticeViewWindow); len(viewers) != 1 {
		t.Fatalf("viewers %v", viewers)
	}
	// Presence expiry drops it.
	f.clock.Advance(noticeViewWindow)
	f.host.notices.maintain()
	f.host.views.mu.Lock()
	left := len(f.host.views.views)
	f.host.views.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d views after expiry", left)
	}
}

func TestNoticesCoalesceAndDeduplicate(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{})
	n := f.host.notices
	n.fromChat(interactionAsked("c1", "i1", "permission"))
	f.clock.Advance(5 * time.Second)
	n.fromChat(interactionAsked("c1", "i2", "permission"))
	n.fromChat(interactionAsked("c1", "q1", "question"))
	n.fromChat(interactionAsked("c2", "i3", "permission"))
	f.flushNotices()
	kinds := func(id string) []string {
		var result []string
		for _, notice := range f.chatNotices(id) {
			result = append(result, notice.Kind)
		}
		return result
	}
	if got := strings.Join(kinds("c1"), ","); got != "chat.approval.needed,chat.question.needed" {
		t.Fatalf("within 10 s: %s", got)
	}
	if got := kinds("c2"); len(got) != 1 {
		t.Fatalf("another chat: %v", got)
	}
	// Ten seconds after the first notice another approval gives a notice;
	// the same approval asked again never does.
	f.clock.Advance(5 * time.Second)
	n.fromChat(interactionAsked("c1", "i4", "permission"))
	n.fromChat(interactionAsked("c1", "i1", "permission"))
	f.clock.Advance(time.Minute)
	n.fromChat(interactionAsked("c1", "i1", "permission"))
	n.fromChat(turnEnded("c1", "t1", "completed"))
	n.fromChat(turnEnded("c1", "t1", "completed"))
	// A stopped turn gives none.
	n.fromChat(turnEnded("c1", "t2", "aborted"))
	f.flushNotices()
	if got := strings.Join(kinds("c1"), ","); got != "chat.approval.needed,chat.question.needed,chat.approval.needed,chat.turn.finished" {
		t.Fatalf("after 10 s: %s", got)
	}
}

func TestNoticesLongPoll(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{})
	for _, target := range []string{"/v1/notices?wait=20001", "/v1/notices?wait=-1", "/v1/notices?wait=x", "/v1/notices?after=garbage", "/v1/notices?after=0123456789abcdef.x"} {
		if w := f.local("GET", target, nil); w.Code != 400 {
			t.Errorf("%s: %d %s", target, w.Code, w.Body)
		}
	}
	first := decodeBody[noticePage](t, f.local("GET", "/v1/notices", nil))
	if len(first.Notices) != 0 || first.Cursor != f.host.notices.epoch+".0" || first.HasMore || first.Resync {
		t.Fatalf("empty: %+v", first)
	}
	// A notice wakes a waiting poll.
	done := make(chan noticePage, 1)
	go func() {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/v1/notices?wait=20000&after="+first.Cursor, nil)
		r.RemoteAddr = "127.0.0.1:9000"
		r.Header.Set("Authorization", "Bearer "+routeLocalToken)
		f.host.Handler().ServeHTTP(w, r)
		var page noticePage
		json.Unmarshal(w.Body.Bytes(), &page)
		done <- page
	}()
	time.Sleep(50 * time.Millisecond)
	started := time.Now()
	f.host.notices.fromChat(turnEnded("c1", "t1", "completed"))
	select {
	case page := <-done:
		if len(page.Notices) != 1 || page.Notices[0].Seq != 1 || page.Cursor != f.host.notices.epoch+".1" || time.Since(started) > 5*time.Second {
			t.Fatalf("woken poll: %+v", page)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the poll did not wake")
	}
	// With nothing new it returns after the wait, keeping the cursor.
	started = time.Now()
	page := decodeBody[noticePage](t, f.local("GET", "/v1/notices?wait=100&after="+f.host.notices.epoch+".1", nil))
	if len(page.Notices) != 0 || page.Cursor != f.host.notices.epoch+".1" || time.Since(started) < 100*time.Millisecond {
		t.Fatalf("timed out poll: %+v after %v", page, time.Since(started))
	}
	// Shutdown ends a waiting poll.
	go func() {
		time.Sleep(50 * time.Millisecond)
		f.host.BeginShutdown()
	}()
	started = time.Now()
	page = decodeBody[noticePage](t, f.local("GET", "/v1/notices?wait=20000&after="+f.host.notices.epoch+".1", nil))
	if len(page.Notices) != 0 || time.Since(started) > 5*time.Second {
		t.Fatalf("poll during shutdown: %+v after %v", page, time.Since(started))
	}
	// A cursor of another epoch starts over.
	page = decodeBody[noticePage](t, f.local("GET", "/v1/notices?after=0123456789abcdef.7", nil))
	if !page.Resync || len(page.Notices) != 1 {
		t.Fatalf("other epoch: %+v", page)
	}
	// Pages hold at most 100 notices.
	for index := 0; index < 150; index++ {
		f.host.notices.fromChat(turnEnded("many", strconv.Itoa(index), "completed"))
	}
	f.flushNotices()
	page = decodeBody[noticePage](t, f.local("GET", "/v1/notices?after="+f.host.notices.epoch+".0", nil))
	if len(page.Notices) != 100 || !page.HasMore || page.Cursor != f.host.notices.epoch+".100" {
		t.Fatalf("first page: %d %v %s", len(page.Notices), page.HasMore, page.Cursor)
	}
	page = decodeBody[noticePage](t, f.local("GET", "/v1/notices?after="+page.Cursor, nil))
	if len(page.Notices) != 52 || page.HasMore {
		t.Fatalf("second page: %d %v", len(page.Notices), page.HasMore)
	}
}

func TestNoticesAckSurvivesRestart(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{archive: true})
	for turn := 1; turn <= 3; turn++ {
		f.host.notices.fromChat(turnEnded("c1", strconv.Itoa(turn), "completed"))
	}
	f.flushNotices()
	ack := func(through any) *httptest.ResponseRecorder {
		return f.local("POST", "/v1/notices/ack", map[string]any{"through": through})
	}
	if w := ack(2); w.Code != 200 || w.Body.String() != `{"acked":2}`+"\n" {
		t.Fatalf("ack: %d %s", w.Code, w.Body)
	}
	for _, through := range []any{99, -1, "2"} {
		if w := ack(through); w.Code != 400 {
			t.Errorf("ack %v: %d %s", through, w.Code, w.Body)
		}
	}
	if w := ack(1); w.Code != 200 || w.Body.String() != `{"acked":2}`+"\n" {
		t.Fatalf("an ack moved back: %d %s", w.Code, w.Body)
	}
	page := decodeBody[noticePage](t, f.local("GET", "/v1/notices", nil))
	if len(page.Notices) != 2 || page.Notices[0].Seq != 3 {
		t.Fatalf("after the ack: %+v", page.Notices)
	}
	epoch := f.host.notices.epoch
	// The paired device cannot read or acknowledge notices.
	if w := f.call("GET", "/v1/notices", nil); w.Code != 403 || errorCode(t, w) != "local_only" {
		t.Fatalf("paired device: %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/notices/ack", map[string]int{"through": 3}); w.Code != 403 {
		t.Fatalf("paired ack: %d %s", w.Code, w.Body)
	}
	// Restart on the same archive: the notices, the ack and the numbering stay.
	if err := f.archive.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	restarted := newHost(f.store, f.host.agent, HostOptions{Archive: f.archive, LocalSessionToken: routeLocalToken})
	restarted.notices.now = f.clock.Now
	t.Cleanup(func() { restarted.Close() })
	if restarted.notices.epoch != epoch {
		t.Fatalf("epoch %s, was %s", restarted.notices.epoch, epoch)
	}
	w := localRequest(t, restarted.Handler(), "GET", "/v1/notices", routeLocalToken, nil)
	page = decodeBody[noticePage](t, w)
	if len(page.Notices) != 2 || page.Notices[0].Seq != 3 || page.Notices[0].Title != "Chat c1" || page.Notices[0].ProjectName != "Fixture" {
		t.Fatalf("after restart: %s", w.Body)
	}
	restarted.notices.fromChat(turnEnded("c1", "4", "completed"))
	waitFor(t, "a new notice", func() bool {
		restarted.notices.mu.Lock()
		defer restarted.notices.mu.Unlock()
		return restarted.notices.last == 5
	})
	w = localRequest(t, restarted.Handler(), "GET", "/v1/notices?after="+epoch+".4", routeLocalToken, nil)
	if page := decodeBody[noticePage](t, w); len(page.Notices) != 1 || page.Notices[0].Seq != 5 || page.Resync {
		t.Fatalf("new notice after restart: %s", w.Body)
	}
}

func TestNoticesWithoutArchiveStartOverOnRestart(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{})
	f.host.notices.fromChat(turnEnded("c1", "1", "completed"))
	f.flushNotices()
	old := decodeBody[noticePage](t, f.local("GET", "/v1/notices", nil)).Cursor
	restarted := newHost(f.store, f.host.agent, HostOptions{LocalSessionToken: routeLocalToken})
	t.Cleanup(func() { restarted.Close() })
	w := localRequest(t, restarted.Handler(), "GET", "/v1/notices?after="+old, routeLocalToken, nil)
	if page := decodeBody[noticePage](t, w); !page.Resync || len(page.Notices) != 0 || strings.HasPrefix(page.Cursor, strings.Split(old, ".")[0]) {
		t.Fatalf("after a restart without an archive: %s", w.Body)
	}
}

func TestNoticesKeepSevenDaysAndAThousand(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{archive: true})
	n := f.host.notices
	n.fromChat(turnEnded("old", "1", "completed"))
	f.flushNotices()
	f.clock.Advance(7*24*time.Hour + time.Minute)
	n.maintain()
	if got := f.chatNotices("old"); len(got) != 0 {
		t.Fatalf("a notice older than 7 days: %+v", got)
	}
	for index := 0; index < 1005; index++ {
		n.fromChat(turnEnded(fmt.Sprintf("many_%04d", index), "1", "error"))
	}
	f.flushNotices()
	n.mu.Lock()
	count, first := len(n.items), n.items[0].SessionID
	n.mu.Unlock()
	if count != noticeKeep || first == "many_0000" {
		t.Fatalf("%d notices kept, oldest %s", count, first)
	}
	if err := f.archive.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	stored := archiveCount(t, f.archive, `SELECT count(*) FROM notices`)
	oldest := archiveCount(t, f.archive, `SELECT count(*) FROM notices WHERE chat_id = 'old'`)
	if stored != noticeKeep || oldest != 0 {
		t.Fatalf("archive keeps %d notices, %d old", stored, oldest)
	}
}

// Schedules were removed (2026-10-06): a schedule run's notice an older host
// kept is left out at the next start, and the numbering goes on after it.
func TestNoticesLeaveOutRetainedScheduleRuns(t *testing.T) {
	f := newNoticeFixture(t, noticeFixtureOptions{archive: true})
	created := f.clock.Now()
	if err := f.archive.RecordNotice(ArchiveNotice{Seq: 1, ID: "ntc_old_run", Kind: "schedule.run.finished", ProjectID: "p1", ProjectName: "Fixture", ChatID: "c1", Title: "Nightly", CreatedAt: created}, created.Add(-noticeRetention), noticeKeep); err != nil {
		t.Fatal(err)
	}
	if err := f.archive.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	restarted := newHost(f.store, f.host.agent, HostOptions{Archive: f.archive, LocalSessionToken: routeLocalToken})
	restarted.notices.now = f.clock.Now
	t.Cleanup(func() { restarted.Close() })
	w := localRequest(t, restarted.Handler(), "GET", "/v1/notices", routeLocalToken, nil)
	if page := decodeBody[noticePage](t, w); len(page.Notices) != 0 || strings.Contains(w.Body.String(), "schedule") {
		t.Fatalf("a schedule run's notice was served: %s", w.Body)
	}
	restarted.notices.fromChat(turnEnded("c1", "1", "completed"))
	waitFor(t, "a new notice", func() bool {
		restarted.notices.mu.Lock()
		defer restarted.notices.mu.Unlock()
		return len(restarted.notices.items) == 1 && restarted.notices.items[0].Seq == 2
	})
}
