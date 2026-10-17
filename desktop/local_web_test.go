package host

import (
	"bytes"
	"context"
	"encoding/json"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func localWebFixture(t *testing.T) (*localWeb, *Host, string) {
	t.Helper()
	store := NewStore(filepath.Join(t.TempDir(), "state.json"))
	project := t.TempDir()
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: project}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	h := newHost(store, &fakeAgent{sessions: map[string]Session{}}, HostOptions{LocalSessionToken: "native-local-token"})
	assets := t.TempDir()
	if err := os.WriteFile(filepath.Join(assets, "index.html"), []byte("<!doctype html><script src=app.js></script>"), 0600); err != nil {
		t.Fatal(err)
	}
	w, err := NewLocalWebHandler(assets, store.Path, h, "native-local-token")
	if err != nil {
		t.Fatal(err)
	}
	w.SetAddress("127.0.0.1:43127")
	return w, h, store.Path
}

func localWebRequest(t *testing.T, handler http.Handler, method, path, host, origin, auth string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, "http://"+host+path, bytes.NewReader(data))
	r.Host = host
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	if auth != "" {
		r.Header.Set("Authorization", "Bearer "+auth)
	}
	if method != http.MethodGet && method != http.MethodHead && origin == "" {
		r.Header.Set("Sec-Fetch-Site", "same-origin")
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func localWebGrant(t *testing.T, w *localWeb) string {
	t.Helper()
	response := httptest.NewRecorder()
	w.launch(httptest.NewRequest(http.MethodPost, "http://127.0.0.1:43127/v1/local-web/launch", nil), response)
	var result struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	grant := strings.TrimPrefix(strings.Split(result.URL, "#launch=")[1], "")
	return grant
}

func localWebSession(t *testing.T, w *localWeb) string {
	t.Helper()
	grant := localWebGrant(t, w)
	response := localWebRequest(t, w.handler(), http.MethodPost, "/web/session", "127.0.0.1:43127", "http://127.0.0.1:43127", "", map[string]string{"grant": grant})
	if response.Code != http.StatusOK {
		t.Fatalf("session: %d %s", response.Code, response.Body)
	}
	var result struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result.Token
}

func TestLocalWebGrantIsOneTimeAndExpires(t *testing.T) {
	w, _, _ := localWebFixture(t)
	grant := localWebGrant(t, w)
	first := localWebRequest(t, w.handler(), http.MethodPost, "/web/session", "127.0.0.1:43127", "http://127.0.0.1:43127", "", map[string]string{"grant": grant})
	if first.Code != http.StatusOK {
		t.Fatalf("first exchange=%d", first.Code)
	}
	replay := localWebRequest(t, w.handler(), http.MethodPost, "/web/session", "127.0.0.1:43127", "http://127.0.0.1:43127", "", map[string]string{"grant": grant})
	if replay.Code != http.StatusUnauthorized {
		t.Fatalf("replay=%d", replay.Code)
	}
	grant = localWebGrant(t, w)
	w.mu.Lock()
	w.grants[grant] = time.Now().Add(-time.Second)
	w.mu.Unlock()
	expired := localWebRequest(t, w.handler(), http.MethodPost, "/web/session", "127.0.0.1:43127", "http://127.0.0.1:43127", "", map[string]string{"grant": grant})
	if expired.Code != http.StatusUnauthorized {
		t.Fatalf("expired=%d", expired.Code)
	}
}

func TestLocalWebRejectsHostOriginAndTraversal(t *testing.T) {
	w, _, _ := localWebFixture(t)
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/", "localhost:43127", "", "", nil).Code; got != http.StatusForbidden {
		t.Fatalf("host=%d", got)
	}
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/", "127.0.0.1:43127", "http://evil.example", "", nil).Code; got != http.StatusForbidden {
		t.Fatalf("origin=%d", got)
	}
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/../index.html", "127.0.0.1:43127", "", "", nil).Code; got != http.StatusOK {
		t.Fatalf("clean traversal should resolve SPA root: %d", got)
	}
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/missing", "127.0.0.1:43127", "", "", nil).Code; got != http.StatusOK {
		t.Fatalf("SPA fallback=%d", got)
	}
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/", "127.0.0.1:43127", "http://127.0.0.1:43127", "", nil).Header().Get("Content-Security-Policy"); !strings.Contains(got, "frame-ancestors 'none'") {
		t.Fatalf("CSP=%q", got)
	}
}

func TestLocalWebStateCASPersistenceAndLegacyImport(t *testing.T) {
	w, h, statePath := localWebFixture(t)
	token := localWebSession(t, w)
	api := w.handler()
	put := localWebRequest(t, api, http.MethodPut, "/web/state", "127.0.0.1:43127", "http://127.0.0.1:43127", token, map[string]any{"revision": 0, "state": map[string]any{"tabs": []string{"one"}, "custom": true}})
	if put.Code != http.StatusOK {
		t.Fatalf("put=%d %s", put.Code, put.Body)
	}
	conflict := localWebRequest(t, api, http.MethodPut, "/web/state", "127.0.0.1:43127", "http://127.0.0.1:43127", token, map[string]any{"revision": 0, "state": map[string]any{}})
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict=%d", conflict.Code)
	}
	if got := localWebRequest(t, api, http.MethodGet, "/web/state", "127.0.0.1:43127", "", token, nil).Code; got != http.StatusOK {
		t.Fatalf("get=%d", got)
	}
	request := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:43127/v1/local-web/import", strings.NewReader(`{"legacy":{"version":1,"tabs":[]}}`))
	request.Host = "127.0.0.1:43127"
	request.RemoteAddr = "127.0.0.1:2"
	request.Header.Set("Authorization", "Bearer native-local-token")
	imported := httptest.NewRecorder()
	h.localWeb = w
	h.localWebImport(imported, request)
	if imported.Code != http.StatusOK || !strings.Contains(imported.Body.String(), `"imported":true`) {
		t.Fatalf("import=%d %s", imported.Code, imported.Body)
	}
	request2 := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:43127/v1/local-web/import", strings.NewReader(`{"legacy":{"version":1,"tabs":[]}}`))
	request2.Host = "127.0.0.1:43127"
	request2.RemoteAddr = "127.0.0.1:2"
	request2.Header.Set("Authorization", "Bearer native-local-token")
	second := httptest.NewRecorder()
	h.localWebImport(second, request2)
	if !strings.Contains(second.Body.String(), `"imported":false`) {
		t.Fatalf("second import=%s", second.Body)
	}
	if _, err := os.Stat(statePath + ".web.json"); err != nil {
		t.Fatal(err)
	}
}

func TestLocalWebStateRejectsCorruptAndNonObjectPersistence(t *testing.T) {
	w, _, statePath := localWebFixture(t)
	token := localWebSession(t, w)
	for _, raw := range []string{"{", `null`, `{"revision":0,"state":null}`, `{"revision":-1,"state":{}}`} {
		if err := writePrivateState(statePath+".web.json", []byte(raw)); err != nil {
			t.Fatal(err)
		}
		get := localWebRequest(t, w.handler(), http.MethodGet, "/web/state", "127.0.0.1:43127", "", token, nil)
		if get.Code != http.StatusBadGateway {
			t.Fatalf("raw %q GET=%d", raw, get.Code)
		}
		put := localWebRequest(t, w.handler(), http.MethodPut, "/web/state", "127.0.0.1:43127", "http://127.0.0.1:43127", token, map[string]any{"revision": 0, "state": map[string]any{}})
		if put.Code != http.StatusBadGateway {
			t.Fatalf("raw %q PUT=%d", raw, put.Code)
		}
	}
}

func TestLocalWebStateCapsMergedPersistenceAndWebFetchNavigation(t *testing.T) {
	w, _, statePath := localWebFixture(t)
	token := localWebSession(t, w)
	data := []byte(`{"revision":0,"state":{"blob":"` + strings.Repeat("x", webPersistLimit-40) + `"}}`)
	if err := writePrivateState(statePath+".web.json", data); err != nil {
		t.Fatal(err)
	}
	put := localWebRequest(t, w.handler(), http.MethodPut, "/web/state", "127.0.0.1:43127", "http://127.0.0.1:43127", token, map[string]any{"revision": 0, "state": map[string]any{"next": true}})
	if put.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("merged cap=%d", put.Code)
	}
	data = []byte(`{"revision":0,"state":{}}`)
	if err := writePrivateState(statePath+".web.json", data); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:43127/web/state", nil)
	request.Host = "127.0.0.1:43127"
	request.Header.Set("Sec-Fetch-Site", "none")
	response := httptest.NewRecorder()
	w.handler().ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("web state navigation=%d", response.Code)
	}
}

func TestLocalWebMaxRevisionDoesNotMutate(t *testing.T) {
	w, h, statePath := localWebFixture(t)
	token := localWebSession(t, w)
	original := []byte(`{"revision":9007199254740991,"state":{"keep":true}}` + "\n")
	if err := writePrivateState(statePath+".web.json", original); err != nil {
		t.Fatal(err)
	}
	put := localWebRequest(t, w.handler(), http.MethodPut, "/web/state", "127.0.0.1:43127", "http://127.0.0.1:43127", token, map[string]any{"revision": webMaxRevision, "state": map[string]any{"changed": true}})
	if put.Code != http.StatusConflict {
		t.Fatalf("max PUT=%d", put.Code)
	}
	request := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:43127/v1/local-web/import", strings.NewReader(`{"legacy":{}}`))
	request.Host = "127.0.0.1:43127"
	request.RemoteAddr = "127.0.0.1:2"
	request.Header.Set("Authorization", "Bearer native-local-token")
	response := httptest.NewRecorder()
	h.localWeb = w
	h.localWebImport(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("max import=%d", response.Code)
	}
	readBack, err := os.ReadFile(statePath + ".web.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(readBack) != string(original) {
		t.Fatalf("max revision file changed")
	}
}

func TestLocalWebAllowlistAndBrowserAuth(t *testing.T) {
	w, _, _ := localWebFixture(t)
	token := localWebSession(t, w)
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/api/v1/providers", "127.0.0.1:43127", "http://127.0.0.1:43127", token, nil).Code; got != http.StatusNotFound {
		t.Fatalf("providers=%d", got)
	}
	if got := localWebRequest(t, w.handler(), http.MethodPost, "/api/v1/git/commit", "127.0.0.1:43127", "http://127.0.0.1:43127", token, nil).Code; got != http.StatusNotFound {
		t.Fatalf("git mutation=%d", got)
	}
	if got := localWebRequest(t, w.handler(), http.MethodGet, "/api/v1/projects", "127.0.0.1:43127", "http://127.0.0.1:43127", "wrong", nil).Code; got != http.StatusUnauthorized {
		t.Fatalf("auth=%d", got)
	}
}

// The browser's chat (2026-10-12) calls Continue in <workspace>, Run again and the
// queue. Each must reach the host's own handler, which answers for itself, and
// every /v1 path the browser bundle names must be on the allowlist.
func TestLocalWebAllowsEveryRouteTheBrowserCalls(t *testing.T) {
	w, _, _ := localWebFixture(t)
	token := localWebSession(t, w)
	const refused = "Route not available to local web"
	for _, path := range []string{"/v1/chat/continue", "/v1/chat/regenerate", "/v1/queue", "/v1/queue/remove"} {
		response := localWebRequest(t, w.handler(), http.MethodPost, "/api"+path, "127.0.0.1:43127", "http://127.0.0.1:43127", token, map[string]string{"projectId": "p1", "sessionId": "missing", "sourceSessionId": "missing", "itemId": "missing"})
		if strings.Contains(response.Body.String(), refused) {
			t.Fatalf("POST %s refused by the allowlist: %d %s", path, response.Code, response.Body)
		}
	}
	if response := localWebRequest(t, w.handler(), http.MethodGet, "/api/v1/queue", "127.0.0.1:43127", "http://127.0.0.1:43127", token, nil); response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), refused) {
		t.Fatalf("GET queue=%d %s", response.Code, response.Body)
	}

	source := filepath.Join("..", "web", "src")
	if _, err := os.Stat(source); err != nil {
		t.Skipf("no browser source: %v", err)
	}
	paths := regexp.MustCompile(`/v1/[A-Za-z0-9/_-]+`)
	found := 0
	err := filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() || strings.Contains(entry.Name(), ".test.") {
			return err
		}
		if ext := filepath.Ext(path); ext != ".ts" && ext != ".tsx" {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, route := range paths.FindAllString(string(data), -1) {
			found++
			if !webAllowed(route, http.MethodGet) && !webAllowed(route, http.MethodPost) {
				t.Errorf("%s calls %s, which the local web allowlist refuses", path, route)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found == 0 {
		t.Fatal("found no /v1 routes in the browser source")
	}
}

// Terminal routes no longer check the owner (terminals from other devices,
// 2026-10-15), and the browser acts as this Mac's session: it lists only its
// own terminals, routed agents included (GET /v1/terminals), never another
// device's (/v1/terminals/others) nor the Mac's own terminal routes.
func TestLocalWebListsNoOtherDevicesTerminals(t *testing.T) {
	w, _, _ := localWebFixture(t)
	token := localWebSession(t, w)
	const refused = "Route not available to local web"
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/v1/terminals/others"}, {http.MethodGet, "/v1/terminals/all"}, {http.MethodGet, "/v1/terminals/running"},
		{http.MethodPost, "/v1/terminals/end-all"}, {http.MethodPost, "/v1/terminals/end"}, {http.MethodPost, "/v1/terminals/clear"},
		{http.MethodPost, "/v1/terminals/end-device"},
	} {
		if webAllowed(route.path, route.method) {
			t.Errorf("%s %s is on the local web allowlist", route.method, route.path)
		}
		response := localWebRequest(t, w.handler(), route.method, "/api"+route.path, "127.0.0.1:43127", "http://127.0.0.1:43127", token, nil)
		if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), refused) {
			t.Errorf("%s %s: %d %s", route.method, route.path, response.Code, response.Body)
		}
	}
}

func TestServeContextStopsHostLocalWeb(t *testing.T) {
	assets := t.TempDir()
	_ = os.WriteFile(filepath.Join(assets, "index.html"), []byte("ok"), 0600)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	address := make(chan string, 1)
	web := &WebListen{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }), SetAddress: func(value string) { address <- value }}
	done := make(chan error, 1)
	go func() {
		done <- ServeContext(ctx, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}), ListenOptions{Address: "127.0.0.1:0", DevelopmentHTTP: true, Web: web})
	}()
	var webAddress string
	select {
	case webAddress = <-address:
	case <-time.After(3 * time.Second):
		t.Fatal("local web listener did not bind")
	}
	conn, err := net.DialTimeout("tcp", webAddress, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("ServeContext did not stop")
	}
	if _, err := net.DialTimeout("tcp", webAddress, 100*time.Millisecond); err == nil {
		t.Fatal("web listener remained open")
	}
}
