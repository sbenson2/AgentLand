package host

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

const previewLocalToken = "preview-local-session"

// previewFixture is a host with web previews on (preview port 9842, API port
// 9841; testHost configures OpenCode on 4096). Its port discovery answers
// from listening and its clock can jump ahead.
type previewFixture struct {
	host  *Host
	store *Store
	token string

	mu        sync.Mutex
	listening []portListener
	scanErr   error
	offset    time.Duration
}

func newPreviewFixture(t *testing.T, allow ...int) *previewFixture {
	t.Helper()
	_, store, agent := testHost(t)
	f := &previewFixture{store: store}
	f.host = newHost(store, agent, HostOptions{LocalSessionToken: previewLocalToken, Preview: &PreviewOptions{Port: 9842, APIPort: 9841, AllowPorts: allow}})
	f.host.preview.discover = func(context.Context) ([]portListener, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		return append([]portListener(nil), f.listening...), f.scanErr
	}
	f.host.preview.now = f.now
	t.Cleanup(f.host.StopPreviews)
	f.token = paired(t, f.host, store)
	return f
}

func (f *previewFixture) now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return time.Now().Add(f.offset)
}

func (f *previewFixture) advance(d time.Duration) {
	f.mu.Lock()
	f.offset += d
	f.mu.Unlock()
}

// listen makes discovery report node listening on 127.0.0.1 at each port.
func (f *previewFixture) listen(ports ...int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, port := range ports {
		f.listening = append(f.listening, portListener{ip: net.IPv4(127, 0, 0, 1), port: port, process: "node", pid: 4242})
	}
}

// session is the live session with id, or nil.
func (f *previewFixture) session(id string) *previewSession {
	f.host.preview.mu.Lock()
	defer f.host.preview.mu.Unlock()
	return f.host.preview.sessions[id]
}

func (f *previewFixture) sessionCount() int {
	f.host.preview.mu.Lock()
	defer f.host.preview.mu.Unlock()
	return len(f.host.preview.sessions)
}

// deviceID is the ID of the device paired with token.
func (f *previewFixture) deviceID(t *testing.T, token string) string {
	t.Helper()
	device, ok := f.store.Authenticate(token)
	if !ok {
		t.Fatal("token is not paired")
	}
	return device.ID
}

type previewGrant struct {
	SessionID   string `json:"sessionId"`
	PreviewPort int    `json:"previewPort"`
	Cookie      struct {
		Name          string `json:"name"`
		Value         string `json:"value"`
		MaxAgeSeconds int    `json:"maxAgeSeconds"`
	} `json:"cookie"`
}

func (f *previewFixture) open(t *testing.T, token string, port int) previewGrant {
	t.Helper()
	w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions", token, map[string]int{"port": port})
	if w.Code != 201 {
		t.Fatalf("open a preview of %d: %d %s", port, w.Code, w.Body)
	}
	var grant previewGrant
	if err := json.Unmarshal(w.Body.Bytes(), &grant); err != nil {
		t.Fatal(err)
	}
	return grant
}

type previewListing struct {
	Sessions []previewSessionInfo `json:"sessions"`
}

func (f *previewFixture) sessions(t *testing.T, token string) []previewSessionInfo {
	t.Helper()
	w := request(t, f.host.Handler(), "GET", "/v1/preview/sessions", token, nil)
	if w.Code != 200 {
		t.Fatalf("list previews: %d %s", w.Code, w.Body)
	}
	var listing previewListing
	if err := json.Unmarshal(w.Body.Bytes(), &listing); err != nil {
		t.Fatal(err)
	}
	return listing.Sessions
}

func wantPreviewError(t *testing.T, label string, status int, code string, got int, body string) {
	t.Helper()
	if got != status || !strings.Contains(body, fmt.Sprintf(`"code":%q`, code)) {
		t.Errorf("%s: %d %s, want %d %s", label, got, body, status, code)
	}
}

func TestPreviewSessionsCreateListAndRevoke(t *testing.T) {
	f := newPreviewFixture(t)
	f.listen(5173)
	grant := f.open(t, f.token, 5173)
	if grant.PreviewPort != 9842 || grant.Cookie.Name != "__Host-agentland-preview" || grant.Cookie.MaxAgeSeconds != 12*60*60 {
		t.Fatalf("grant %+v", grant)
	}
	if raw, err := base64.RawURLEncoding.DecodeString(grant.Cookie.Value); err != nil || len(raw) != 32 {
		t.Fatalf("cookie value %q is not 32 bytes of base64url: %v", grant.Cookie.Value, err)
	}
	if id, err := hex.DecodeString(grant.SessionID); err != nil || len(id) != 16 {
		t.Fatalf("session ID %q", grant.SessionID)
	}
	// The host keeps only the secret's SHA-256.
	session := f.session(grant.SessionID)
	if session == nil || session.secret != sha256.Sum256([]byte(grant.Cookie.Value)) {
		t.Fatal("the stored secret is not the cookie value's SHA-256")
	}
	w := request(t, f.host.Handler(), "GET", "/v1/preview/sessions", f.token, nil)
	if w.Code != 200 || strings.Contains(w.Body.String(), grant.Cookie.Value) {
		t.Fatalf("listing: %d %s", w.Code, w.Body)
	}
	listed := f.sessions(t, f.token)
	if len(listed) != 1 || listed[0].SessionID != grant.SessionID || listed[0].Port != 5173 {
		t.Fatalf("listed %+v", listed)
	}
	created, err := time.Parse(time.RFC3339, listed[0].CreatedAt)
	expires, err2 := time.Parse(time.RFC3339, listed[0].ExpiresAt)
	if err != nil || err2 != nil || expires.Sub(created) != 12*time.Hour || !strings.HasSuffix(listed[0].LastUsedAt, "Z") {
		t.Fatalf("times %+v", listed[0])
	}

	// Another device sees and ends none of these sessions.
	other := paired(t, f.host, f.store)
	if listed := f.sessions(t, other); len(listed) != 0 {
		t.Fatalf("another device listed %+v", listed)
	}
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", other, map[string]string{"sessionId": grant.SessionID})
	wantPreviewError(t, "revoke by another device", 404, "preview_session_not_found", w.Code, w.Body.String())

	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", f.token, map[string]string{"sessionId": grant.SessionID})
	if w.Code != 200 || w.Body.String() != `{"revoked":true}`+"\n" {
		t.Fatalf("revoke: %d %s", w.Code, w.Body)
	}
	if listed := f.sessions(t, f.token); len(listed) != 0 {
		t.Fatalf("after revoke %+v", listed)
	}
	if session.ctx.Err() == nil {
		t.Fatal("revoking did not stop the session's requests")
	}
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", f.token, map[string]string{"sessionId": grant.SessionID})
	wantPreviewError(t, "second revoke", 404, "preview_session_not_found", w.Code, w.Body.String())
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", f.token, map[string]string{"sessionId": ""})
	wantPreviewError(t, "revoke without an ID", 400, "invalid_request", w.Code, w.Body.String())
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]any{"port": 5173, "host": "example.com"})
	wantPreviewError(t, "unknown field", 400, "invalid_request", w.Code, w.Body.String())
}

func TestPreviewSessionLimits(t *testing.T) {
	f := newPreviewFixture(t)
	f.listen(5173)
	var first previewGrant
	for i := range previewSessionsPerDevice {
		grant := f.open(t, f.token, 5173)
		if i == 0 {
			first = grant
		}
	}
	w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": 5173})
	wantPreviewError(t, "ninth session", 429, "preview_session_limit", w.Code, w.Body.String())
	// The limit is per device; ending a session makes room again.
	others := []string{}
	for range previewSessionsTotal/previewSessionsPerDevice - 1 {
		others = append(others, paired(t, f.host, f.store))
	}
	for _, token := range others {
		for range previewSessionsPerDevice {
			f.open(t, token, 5173)
		}
	}
	// The host holds at most previewSessionsTotal.
	last := paired(t, f.host, f.store)
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions", last, map[string]int{"port": 5173})
	wantPreviewError(t, "session beyond the host's limit", 429, "preview_session_limit", w.Code, w.Body.String())
	if w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", f.token, map[string]string{"sessionId": first.SessionID}); w.Code != 200 {
		t.Fatalf("revoke: %d %s", w.Code, w.Body)
	}
	f.open(t, last, 5173)
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": 5173})
	wantPreviewError(t, "full host", 429, "preview_session_limit", w.Code, w.Body.String())
}

func TestPreviewSessionsExpire(t *testing.T) {
	f := newPreviewFixture(t)
	f.listen(5173)
	idle := f.open(t, f.token, 5173)
	f.advance(29 * time.Minute)
	if listed := f.sessions(t, f.token); len(listed) != 1 {
		t.Fatalf("a session idle for 29 minutes ended: %+v", listed)
	}
	f.advance(2 * time.Minute)
	if listed := f.sessions(t, f.token); len(listed) != 0 {
		t.Fatalf("a session idle for 31 minutes is listed: %+v", listed)
	}
	if f.session(idle.SessionID) != nil {
		t.Fatal("the idle session was kept")
	}

	// A request in progress (such as a WebSocket) keeps a session from
	// idling out, but not past 12 hours.
	busy := f.open(t, f.token, 5173)
	session := f.session(busy.SessionID)
	if f.host.preview.acquire(session) != previewAdmitted {
		t.Fatal("not admitted")
	}
	f.advance(3 * time.Hour)
	f.host.preview.sweep()
	if len(f.sessions(t, f.token)) != 1 {
		t.Fatal("a session with a request in progress idled out")
	}
	f.host.preview.release(session)
	f.advance(29 * time.Minute)
	f.host.preview.sweep()
	if len(f.sessions(t, f.token)) != 1 {
		t.Fatal("idle time did not restart when the request ended")
	}
	if f.host.preview.acquire(session) != previewAdmitted {
		t.Fatal("not admitted")
	}
	f.advance(9 * time.Hour)
	f.host.preview.sweep()
	if len(f.sessions(t, f.token)) != 0 || session.ctx.Err() == nil {
		t.Fatal("a session outlived 12 hours")
	}
	if f.host.preview.acquire(session) != previewEnded {
		t.Fatal("an ended session admitted a request")
	}
}

func TestPreviewSessionsOpenOnlyListeningAllowedPorts(t *testing.T) {
	f := newPreviewFixture(t)
	// 9841 and 9842 are AgentLand's own listeners, 4096 is the configured
	// OpenCode server, 22 and 5432 are default exclusions.
	f.listen(5173, 9841, 9842, 4096, 22, 5432)
	for _, port := range []int{0, -1, 65536} {
		w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": port})
		wantPreviewError(t, fmt.Sprint("port ", port), 400, "invalid_request", w.Code, w.Body.String())
	}
	for _, port := range []int{9841, 9842, 4096, 22, 5432, 631, 2375, 2376, 3306, 6379, 9200, 27017} {
		w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": port})
		wantPreviewError(t, fmt.Sprint("excluded port ", port), 403, "port_not_allowed", w.Code, w.Body.String())
	}
	w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": 3000})
	wantPreviewError(t, "port nothing listens on", 404, "port_not_listening", w.Code, w.Body.String())
	w = request(t, f.host.Handler(), "GET", "/v1/preview/ports", f.token, nil)
	if w.Code != 200 || w.Body.String() != `{"ports":[{"port":5173,"address":"127.0.0.1","process":"node"}]}`+"\n" {
		t.Fatalf("ports: %d %s", w.Code, w.Body)
	}
	f.open(t, f.token, 5173)

	// Discovery runs again for each new session.
	f.mu.Lock()
	f.listening = nil
	f.mu.Unlock()
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": 5173})
	wantPreviewError(t, "port that stopped listening", 404, "port_not_listening", w.Code, w.Body.String())
	f.mu.Lock()
	f.scanErr = errors.New("lsof failed")
	f.mu.Unlock()
	w = request(t, f.host.Handler(), "GET", "/v1/preview/ports", f.token, nil)
	wantPreviewError(t, "failed discovery", 503, "port_discovery_failed", w.Code, w.Body.String())
	w = request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": 5173})
	wantPreviewError(t, "session after failed discovery", 503, "port_discovery_failed", w.Code, w.Body.String())

	// The owner may allow a default exclusion, never AgentLand's own ports.
	allowed := newPreviewFixture(t, 5432, 9841, 4096)
	allowed.listen(5432, 9841, 4096)
	w = request(t, allowed.host.Handler(), "GET", "/v1/preview/ports", allowed.token, nil)
	if w.Code != 200 || w.Body.String() != `{"ports":[{"port":5432,"address":"127.0.0.1","process":"node"}]}`+"\n" {
		t.Fatalf("allowed ports: %d %s", w.Code, w.Body)
	}
	allowed.open(t, allowed.token, 5432)
	for _, port := range []int{9841, 4096} {
		w := request(t, allowed.host.Handler(), "POST", "/v1/preview/sessions", allowed.token, map[string]int{"port": port})
		wantPreviewError(t, fmt.Sprint("own port ", port), 403, "port_not_allowed", w.Code, w.Body.String())
	}
}

func TestPreviewSessionsAreForPairedDevices(t *testing.T) {
	f := newPreviewFixture(t)
	f.listen(5173)
	w := localRequest(t, f.host.Handler(), "POST", "/v1/preview/sessions", previewLocalToken, map[string]int{"port": 5173})
	wantPreviewError(t, "this Mac's own session", 403, "preview_unavailable", w.Code, w.Body.String())
	if w := localRequest(t, f.host.Handler(), "GET", "/v1/preview/ports", previewLocalToken, nil); w.Code != 200 || !strings.Contains(w.Body.String(), `"port":5173`) {
		t.Fatalf("this Mac lists ports: %d %s", w.Code, w.Body)
	}
	if w := localRequest(t, f.host.Handler(), "GET", "/v1/preview/sessions", previewLocalToken, nil); w.Code != 200 || w.Body.String() != `{"sessions":[]}`+"\n" {
		t.Fatalf("this Mac's sessions: %d %s", w.Code, w.Body)
	}
}

func TestPreviewRoutesNeedPreviewsEnabled(t *testing.T) {
	plain, store, _ := testHost(t)
	token := paired(t, plain, store)
	checks := []struct {
		method, target string
		body           any
	}{
		{"GET", "/v1/preview/ports", nil},
		{"POST", "/v1/preview/sessions", map[string]int{"port": 5173}},
		{"GET", "/v1/preview/sessions", nil},
		{"POST", "/v1/preview/sessions/revoke", map[string]string{"sessionId": "x"}},
	}
	for _, check := range checks {
		w := request(t, plain.Handler(), check.method, check.target, token, check.body)
		wantPreviewError(t, check.method+" "+check.target, 403, "preview_disabled", w.Code, w.Body.String())
	}
	if w := request(t, plain.Handler(), "GET", "/v1/capabilities", token, nil); strings.Contains(w.Body.String(), "preview") {
		t.Fatalf("capabilities without previews: %s", w.Body)
	}
	if w := request(t, plain.PreviewHandler(), "GET", "/", "", nil); w.Code != 404 {
		t.Fatalf("preview handler without previews: %d", w.Code)
	}
	plain.StopPreviews()

	f := newPreviewFixture(t)
	w := request(t, f.host.Handler(), "GET", "/v1/capabilities", f.token, nil)
	if w.Code != 200 || !strings.HasSuffix(w.Body.String(), `,"preview":{"port":9842,"scheme":"https","features":["revokeAll"]}}`+"\n") {
		t.Fatalf("capabilities with previews: %s", w.Body)
	}
}

// {all: true} ends every session of the calling device, such as those an
// app opened before it restarted, and no other device's.
func TestPreviewSessionsRevokeAll(t *testing.T) {
	f := newPreviewFixture(t)
	f.listen(5173, 8000)
	mine := []previewGrant{f.open(t, f.token, 5173), f.open(t, f.token, 8000), f.open(t, f.token, 5173)}
	other := paired(t, f.host, f.store)
	theirs := f.open(t, other, 5173)
	// mine[0] idles out (it ends, uncounted); the others were used meanwhile.
	f.advance(29 * time.Minute)
	for _, grant := range append(mine[1:], theirs) {
		session := f.session(grant.SessionID)
		if f.host.preview.acquire(session) != previewAdmitted {
			t.Fatal("not admitted")
		}
		f.host.preview.release(session)
	}
	f.advance(2 * time.Minute)
	held := f.session(mine[1].SessionID)

	revokeAll := func(token string, body any) (int, string) {
		w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", token, body)
		return w.Code, w.Body.String()
	}
	if code, body := revokeAll(f.token, map[string]bool{"all": true}); code != 200 || body != `{"revoked":true,"count":2}`+"\n" {
		t.Fatalf("revoke all: %d %s", code, body)
	}
	for _, grant := range mine {
		if f.session(grant.SessionID) != nil {
			t.Fatalf("session %s outlived revoke all", grant.SessionID)
		}
	}
	if held.ctx.Err() == nil {
		t.Fatal("revoke all did not stop a session's requests")
	}
	if listed := f.sessions(t, other); len(listed) != 1 || listed[0].SessionID != theirs.SessionID {
		t.Fatalf("another device's sessions: %+v", listed)
	}
	// Nothing left: still revoked, none counted. The limit counts from zero again.
	if code, body := revokeAll(f.token, map[string]bool{"all": true}); code != 200 || body != `{"revoked":true,"count":0}`+"\n" {
		t.Fatalf("revoke all again: %d %s", code, body)
	}
	for range previewSessionsPerDevice {
		f.open(t, f.token, 5173)
	}
	code, body := revokeAll(f.token, map[string]any{"all": true, "sessionId": theirs.SessionID})
	wantPreviewError(t, "all with a session ID", 400, "invalid_request", code, body)
	code, body = revokeAll(f.token, map[string]any{"all": false})
	wantPreviewError(t, "all false without a session ID", 400, "invalid_request", code, body)
	if f.session(theirs.SessionID) == nil || len(f.sessions(t, f.token)) != previewSessionsPerDevice {
		t.Fatal("a refused revoke ended sessions")
	}
}

func TestPreviewsStopWithTheHost(t *testing.T) {
	f := newPreviewFixture(t)
	f.listen(5173)
	grant := f.open(t, f.token, 5173)
	session := f.session(grant.SessionID)
	if err := f.host.Close(); err != nil {
		t.Fatal(err)
	}
	if session.ctx.Err() == nil || f.sessionCount() != 0 {
		t.Fatal("closing the host kept a preview session")
	}
	w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions", f.token, map[string]int{"port": 5173})
	wantPreviewError(t, "session while stopping", 503, "host_stopping", w.Code, w.Body.String())
	f.host.StopPreviews()
}
