package host

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func testHost(t *testing.T) (*Host, *Store, *fakeAgent) {
	t.Helper()
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "state.json"))
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: t.TempDir()}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	agent := &fakeAgent{sessions: map[string]Session{"s1": {ID: "s1", Title: "One", ProjectID: "p1", Directory: mustProject(t, store).Directory}}}
	return New(store, agent), store, agent
}

func mustProject(t *testing.T, store *Store) Project {
	s, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	return s.Config.Projects[0]
}
func request(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func paired(t *testing.T, h *Host, store *Store) string {
	t.Helper()
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	w := request(t, h.Handler(), "POST", "/v1/pair", "", map[string]any{"code": code, "deviceName": "Phone"})
	if w.Code != 200 {
		t.Fatalf("pair: %d %s", w.Code, w.Body.String())
	}
	var out struct {
		Token string `json:"token"`
	}
	json.Unmarshal(w.Body.Bytes(), &out)
	return out.Token
}

func TestUnauthenticatedProtectedRoute(t *testing.T) {
	h, _, _ := testHost(t)
	w := request(t, h.Handler(), "GET", "/v1/projects", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", w.Code)
	}
}

func TestPairingSingleUseExpiryConcurrencyAndRevocation(t *testing.T) {
	h, store, _ := testHost(t)
	code, _ := store.CreatePairingCode(time.Minute)
	var wg sync.WaitGroup
	statuses := make(chan int, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			statuses <- request(t, h.Handler(), "POST", "/v1/pair", "", map[string]any{"code": code, "deviceName": "Phone"}).Code
		}()
	}
	wg.Wait()
	close(statuses)
	successes := 0
	for status := range statuses {
		if status == 200 {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("successes=%d", successes)
	}
	expired, _ := store.CreatePairingCode(-time.Second)
	if got := request(t, h.Handler(), "POST", "/v1/pair", "", map[string]any{"code": expired, "deviceName": "Late"}).Code; got != 401 {
		t.Fatalf("expired=%d", got)
	}
	token := paired(t, h, store)
	state, _ := store.Read()
	id := state.Devices[len(state.Devices)-1].ID
	if err := store.RevokeDevice(id); err != nil {
		t.Fatal(err)
	}
	if got := request(t, h.Handler(), "GET", "/v1/projects", token, nil).Code; got != 401 {
		t.Fatalf("revoked=%d", got)
	}
}

func TestRejectsBrowserOrigin(t *testing.T) {
	h, store, _ := testHost(t)
	token := paired(t, h, store)
	r := httptest.NewRequest("GET", "/v1/projects", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("got %d", w.Code)
	}
}

func TestMutationRejectsUnknownAndOversizedBodies(t *testing.T) {
	h, store, _ := testHost(t)
	token := paired(t, h, store)
	if got := request(t, h.Handler(), "POST", "/v1/sessions", token, map[string]any{"projectId": "p1", "title": "x", "extra": true}).Code; got != 400 {
		t.Fatalf("unknown=%d", got)
	}
	r := httptest.NewRequest("POST", "/v1/messages", strings.NewReader(strings.Repeat("x", maxRequestBody+1)))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	if w.Code != 400 {
		t.Fatalf("oversized=%d", w.Code)
	}
}

func TestPairingAttemptLimiterBoundsDistinctClientRetention(t *testing.T) {
	h, _, _ := testHost(t)
	for i := 0; i < maxPairingClients+500; i++ {
		h.allowPair(fmt.Sprintf("192.0.%d.%d:1234", i/256, i%256))
	}
	if len(h.pairAttempts) > maxPairingClients {
		t.Fatalf("retained clients=%d", len(h.pairAttempts))
	}
}

func TestHTTPDevelopmentListenerMustBeExplicitAndLoopback(t *testing.T) {
	if err := ValidateListen(ListenOptions{Address: "127.0.0.1:8080", DevelopmentHTTP: true}); err != nil {
		t.Fatal(err)
	}
	if err := ValidateListen(ListenOptions{Address: "0.0.0.0:8080", DevelopmentHTTP: true}); err == nil {
		t.Fatal("accepted public HTTP")
	}
	if err := ValidateListen(ListenOptions{Address: "127.0.0.1:8080"}); err == nil {
		t.Fatal("accepted TLS listener without certificate")
	}
}

func TestProjectAndSessionScope(t *testing.T) {
	h, store, agent := testHost(t)
	token := paired(t, h, store)
	if got := request(t, h.Handler(), "GET", "/v1/sessions?projectId=missing", token, nil).Code; got != 404 {
		t.Fatalf("project=%d", got)
	}
	agent.sessions["foreign"] = Session{ID: "foreign", Title: "Foreign", ProjectID: "other", Directory: t.TempDir()}
	if got := request(t, h.Handler(), "GET", "/v1/messages?projectId=p1&sessionId=foreign", token, nil).Code; got != 404 {
		t.Fatalf("session=%d", got)
	}
}

func TestProtocolRouteStatusAndResponseMapping(t *testing.T) {
	h, store, agent := testHost(t)
	token := paired(t, h, store)
	agent.messages = []Message{{ID: "m1", Role: "assistant", Text: "hello"}}
	checks := []struct {
		method, path string
		body         any
		status       int
		contains     string
	}{
		{"GET", "/v1/health", nil, 200, `"protocolVersion":1`},
		{"GET", "/v1/projects", nil, 200, `"id":"p1"`},
		{"GET", "/v1/sessions?projectId=p1", nil, 200, `"projectId":"p1"`},
		{"POST", "/v1/sessions", map[string]any{"projectId": "p1", "title": "New"}, 201, `"id":"new"`},
		{"GET", "/v1/messages?projectId=p1&sessionId=s1", nil, 200, `"text":"hello"`},
		{"POST", "/v1/messages", map[string]any{"projectId": "p1", "sessionId": "s1", "text": "go"}, 202, `"accepted":true`},
		{"POST", "/v1/abort", map[string]any{"projectId": "p1", "sessionId": "s1"}, 200, `"aborted":true`},
	}
	for _, c := range checks {
		auth := token
		if c.path == "/v1/health" {
			auth = ""
		}
		w := request(t, h.Handler(), c.method, c.path, auth, c.body)
		if w.Code != c.status || !strings.Contains(w.Body.String(), c.contains) {
			t.Fatalf("%s %s: %d %s", c.method, c.path, w.Code, w.Body.String())
		}
	}
	if agent.prompted != "s1:go" || agent.aborted != "s1" {
		t.Fatalf("prompt=%q abort=%q", agent.prompted, agent.aborted)
	}
}

func TestDurableStateAndPermissions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state", "state.json")
	store := NewStore(path)
	if err := store.Initialize(Config{OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD", Projects: []Project{{ID: "p", Name: "P", Directory: dir}}}); err != nil {
		t.Fatal(err)
	}
	code, _ := store.CreatePairingCode(time.Minute)
	if _, _, err := NewStore(path).RedeemPairingCode(code, "Phone"); err != nil {
		t.Fatal(err)
	}
	state, err := NewStore(path).Read()
	if err != nil || len(state.Devices) != 1 {
		t.Fatalf("state=%+v err=%v", state, err)
	}
	info, _ := os.Stat(path)
	// Windows permissions are checked through its DACL test; POSIX mode bits
	// cannot express the security descriptor returned by that platform.
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0600 {
		t.Fatalf("mode=%o", info.Mode().Perm())
	}
}

func TestPairingRedemptionIsSerializedAcrossProcesses(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state", "state.json")
	store := NewStore(path)
	if err := store.Initialize(Config{OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD", Projects: []Project{{ID: "p", Name: "P", Directory: dir}}}); err != nil {
		t.Fatal(err)
	}
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	commands := []*exec.Cmd{exec.Command(os.Args[0], "-test.run=^TestStoreRedeemHelper$"), exec.Command(os.Args[0], "-test.run=^TestStoreRedeemHelper$")}
	for _, cmd := range commands {
		cmd.Env = append(os.Environ(), "AGENT_MOBILE_STORE_HELPER=1", "AGENT_MOBILE_STORE_PATH="+path, "AGENT_MOBILE_PAIR_CODE="+code)
	}
	results := make(chan error, 2)
	for _, cmd := range commands {
		go func(c *exec.Cmd) { results <- c.Run() }(cmd)
	}
	successes := 0
	for range commands {
		if <-results == nil {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("successful redemptions=%d", successes)
	}
	state, err := store.Read()
	if err != nil || len(state.Devices) != 1 {
		t.Fatalf("devices=%d err=%v", len(state.Devices), err)
	}
}

func TestStoreRedeemHelper(t *testing.T) {
	if os.Getenv("AGENT_MOBILE_STORE_HELPER") != "1" {
		return
	}
	_, _, err := NewStore(os.Getenv("AGENT_MOBILE_STORE_PATH")).RedeemPairingCode(os.Getenv("AGENT_MOBILE_PAIR_CODE"), "Helper")
	if err != nil {
		os.Exit(3)
	}
}

type fakeAgent struct {
	sessions          map[string]Session
	messages          []Message
	created           Session
	prompted, aborted string
}

func (f *fakeAgent) ListSessions(Project) ([]Session, error) {
	out := []Session{}
	for _, s := range f.sessions {
		out = append(out, s)
	}
	return out, nil
}
func (f *fakeAgent) CreateSession(p Project, title string) (Session, error) {
	f.created = Session{ID: "new", Title: title, ProjectID: p.ID, Directory: p.Directory}
	f.sessions["new"] = f.created
	return f.created, nil
}
func (f *fakeAgent) GetSession(_ Project, id string) (Session, error) {
	s, ok := f.sessions[id]
	if !ok {
		return Session{}, ErrNotFound
	}
	return s, nil
}
func (f *fakeAgent) Messages(Project, string) ([]Message, error) { return f.messages, nil }
func (f *fakeAgent) Prompt(_ Project, id, text string) error {
	f.prompted = id + ":" + text
	return nil
}
func (f *fakeAgent) Abort(_ Project, id string) error { f.aborted = id; return nil }
