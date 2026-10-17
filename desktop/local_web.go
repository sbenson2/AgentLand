package host

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	webGrantLife    = time.Minute
	webSessionLife  = 8 * time.Hour
	webMaxGrants    = 128
	webMaxSessions  = 64
	webStateLimit   = 2 << 20
	webPersistLimit = 8 << 20
	webMaxRevision  = 1<<53 - 1
)

var errWebStateTooLarge = errors.New("local web state is too large")

func readWebState(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Size() > webPersistLimit {
		return nil, errWebStateTooLarge
	}
	return readPrivateState(path)
}

// WebListen is an optional, plain HTTP listener bound only to literal
// 127.0.0.1. It is deliberately separate from the device-facing API listener.
type WebListen struct {
	Assets     string
	StatePath  string
	LocalToken string
	Host       *Host
	Handler    http.Handler
	SetAddress func(string)
}

func NewLocalWebHandler(assets, statePath string, h *Host, token string) (*localWeb, error) {
	w, err := newLocalWeb(WebListen{Assets: assets, StatePath: statePath, Host: h, LocalToken: token})
	if err != nil {
		return nil, err
	}
	return w, nil
}
func (w *localWeb) Handler() http.Handler     { return w.handler() }
func (w *localWeb) SetAddress(address string) { w.setAddress(address) }
func (h *Host) SetLocalWeb(w *localWeb)       { h.configureLocalWeb(w) }

type localWeb struct {
	assets, statePath string
	host              *Host
	mu                sync.Mutex
	stateMu           sync.Mutex
	grants            map[string]time.Time
	sessions          map[string]time.Time
	address           string
}

func newLocalWeb(o WebListen) (*localWeb, error) {
	if o.Assets == "" || !filepath.IsAbs(o.Assets) {
		return nil, errors.New("web assets must be an absolute directory")
	}
	info, err := os.Stat(o.Assets)
	if err != nil {
		return nil, fmt.Errorf("web assets directory is not usable: %w", err)
	}
	if !info.IsDir() {
		return nil, errors.New("web assets path is not a directory")
	}
	if o.LocalToken == "" || o.Host == nil {
		return nil, errors.New("local web needs a local session")
	}
	return &localWeb{assets: o.Assets, statePath: o.StatePath, host: o.Host, grants: map[string]time.Time{}, sessions: map[string]time.Time{}}, nil
}

func (h *Host) localWebLaunch(out http.ResponseWriter, r *http.Request) {
	if h.localWeb == nil {
		writeError(out, 404, "not_found", "Local web is disabled")
		return
	}
	h.localWeb.launch(r, out)
}
func (h *Host) localWebImport(out http.ResponseWriter, r *http.Request) {
	if h.localWeb == nil {
		writeError(out, 404, "not_found", "Local web is disabled")
		return
	}
	h.localWeb.importLegacy(out, r)
}

func (w *localWeb) setAddress(address string) { w.mu.Lock(); w.address = address; w.mu.Unlock() }
func (w *localWeb) url() string               { w.mu.Lock(); defer w.mu.Unlock(); return "http://" + w.address + "/" }

func (w *localWeb) launch(r *http.Request, out http.ResponseWriter) {
	// The API handler has already required the local-mac bearer token and the
	// route is localOnly. The launch request is made by the native companion,
	// so it intentionally has no browser Origin.
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.address == "" {
		writeError(out, 503, "web_unavailable", "Local web is not listening")
		return
	}
	w.pruneLocked(time.Now())
	if len(w.grants) >= webMaxGrants {
		writeError(out, 429, "web_busy", "Too many pending web launches")
		return
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		internal(out)
		return
	}
	grant := hex.EncodeToString(b)
	w.grants[grant] = time.Now().Add(webGrantLife)
	writeJSON(out, 200, map[string]string{"url": "http://" + w.address + "/#launch=" + grant})
}

func (w *localWeb) handler() http.Handler { return http.HandlerFunc(w.serve) }

func (w *localWeb) serve(out http.ResponseWriter, r *http.Request) {
	out.Header().Set("X-Content-Type-Options", "nosniff")
	out.Header().Set("X-Frame-Options", "DENY")
	out.Header().Set("Referrer-Policy", "no-referrer")
	out.Header().Set("Cache-Control", "no-store")
	out.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'")
	if !w.sameRequest(r, strings.HasPrefix(r.URL.Path, "/api/")) {
		http.Error(out, "forbidden", http.StatusForbidden)
		return
	}
	switch {
	case r.URL.Path == "/web/session":
		w.exchange(out, r)
	case r.URL.Path == "/web/state":
		w.state(out, r)
	case strings.HasPrefix(r.URL.Path, "/api/"):
		w.proxy(out, r)
	default:
		w.static(out, r)
	}
}

func (w *localWeb) sameRequest(r *http.Request, api bool) bool {
	if r.Host != w.address {
		return false
	}
	u, err := url.Parse("http://" + r.Host)
	if err != nil || u.Host != w.address {
		return false
	}
	for _, origin := range r.Header.Values("Origin") {
		if origin == "null" || origin != "http://"+w.address {
			return false
		}
	}
	fetchSite := r.Header.Get("Sec-Fetch-Site")
	if fetchSite != "" && fetchSite != "same-origin" && !(fetchSite == "none" && !api && !strings.HasPrefix(r.URL.Path, "/web/") && (r.Method == http.MethodGet || r.Method == http.MethodHead)) {
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Header.Get("Origin") != "http://"+w.address {
		return false
	}
	return true
}

func (w *localWeb) exchange(out http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(out, r)
		return
	}
	var in struct {
		Grant string `json:"grant"`
	}
	if !decodeLimited(out, r, &in, 4096) {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	now := time.Now()
	w.pruneLocked(now)
	expires, ok := w.grants[in.Grant]
	if !ok || !expires.After(now) {
		writeError(out, 401, "invalid_grant", "Launch grant is invalid or expired")
		return
	}
	delete(w.grants, in.Grant)
	if len(w.sessions) >= webMaxSessions {
		writeError(out, 429, "web_busy", "Too many web sessions")
		return
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		internal(out)
		return
	}
	token := hex.EncodeToString(b)
	w.sessions[token] = now.Add(webSessionLife)
	writeJSON(out, 200, map[string]any{"token": token, "expiresAt": now.Add(webSessionLife)})
}

func (w *localWeb) browserToken(r *http.Request) bool {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return false
	}
	token := strings.TrimPrefix(value, "Bearer ")
	w.mu.Lock()
	defer w.mu.Unlock()
	expires, ok := w.sessions[token]
	if !ok || !expires.After(time.Now()) {
		delete(w.sessions, token)
		return false
	}
	return len(token) == 64
}

func (w *localWeb) proxy(out http.ResponseWriter, r *http.Request) {
	if !w.browserToken(r) {
		writeError(out, 401, "unauthorized", "Valid browser authentication is required")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/api")
	if !webAllowed(path, r.Method) {
		writeError(out, 404, "not_found", "Route not available to local web")
		return
	}
	clone := r.Clone(r.Context())
	clone.URL.Path = path
	clone.URL.RawPath = ""
	clone.RequestURI = clone.URL.RequestURI()
	clone.Host = "127.0.0.1"
	clone.RemoteAddr = "127.0.0.1:1"
	clone.Header = clone.Header.Clone()
	clone.Header.Del("Origin")
	clone.Header.Set("Authorization", "Bearer "+w.host.localSessionToken)
	w.host.serveHTTP(out, clone)
}

var webAllowedRoutes = map[string]map[string]bool{
	"GET": {
		"/v1/capabilities": true, "/v1/pulse": true, "/v1/projects": true, "/v1/folders": true,
		"/v1/agents": true, "/v1/agents/icon": true, "/v1/sessions": true,
		"/v1/chat/options": true, "/v1/chat/status": true, "/v1/messages": true,
		"/v1/chat/events": true, "/v1/chat/messages": true, "/v1/interactions": true,
		"/v1/files": true, "/v1/file": true, "/v1/files/search": true,
		"/v1/git/repositories": true, "/v1/git/status": true, "/v1/git/diff": true,
		"/v1/git/identity": true, "/v1/git/branches": true, "/v1/git/history": true,
		"/v1/git/commit": true, "/v1/git/commit/diff": true, "/v1/git/remotes": true,
		"/v1/git/stashes": true, "/v1/terminals": true, "/v1/terminal/output": true,
	},
	"POST": {
		"/v1/projects": true, "/v1/projects/create": true, "/v1/projects/rename": true,
		"/v1/projects/remove": true, "/v1/sessions": true, "/v1/messages": true,
		"/v1/messages/rewind": true, "/v1/messages/restore": true, "/v1/attachments": true,
		"/v1/abort": true, "/v1/permissions/reply": true, "/v1/questions/reply": true,
		"/v1/questions/reject": true, "/v1/files/move": true, "/v1/files/mkdir": true,
		"/v1/files/upload": true, "/v1/files/delete": true, "/v1/file": true,
		"/v1/terminals": true, "/v1/terminal/input": true, "/v1/terminal/resize": true,
		"/v1/terminal/close": true, "/v1/chat/regenerate": true, "/v1/chat/continue": true,
		"/v1/queue": true, "/v1/queue/remove": true,
	},
}

func webAllowed(path, method string) bool { return webAllowedRoutes[method][path] }

func (w *localWeb) static(out http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "HEAD" {
		http.NotFound(out, r)
		return
	}
	name := strings.TrimPrefix(filepath.Clean("/"+r.URL.Path), "/")
	if name == "." {
		name = ""
	}
	root, err := os.OpenRoot(w.assets)
	if err != nil {
		http.NotFound(out, r)
		return
	}
	defer root.Close()
	open := func(candidate string) (*os.File, os.FileInfo, error) {
		f, e := root.Open(candidate)
		if e != nil {
			return nil, nil, e
		}
		i, e := f.Stat()
		if e != nil || i.IsDir() {
			f.Close()
			return nil, nil, os.ErrNotExist
		}
		return f, i, nil
	}
	file, info, err := open(name)
	if err != nil {
		file, info, err = open("index.html")
	}
	if err != nil {
		http.NotFound(out, r)
		return
	}
	defer file.Close()
	http.ServeContent(out, r, filepath.Base(name), info.ModTime(), file)
}

func (w *localWeb) state(out http.ResponseWriter, r *http.Request) {
	w.stateMu.Lock()
	defer w.stateMu.Unlock()
	if !w.browserToken(r) {
		writeError(out, 401, "unauthorized", "Valid browser authentication is required")
		return
	}
	if r.Method == "GET" {
		raw, err := readWebState(w.statePath + ".web.json")
		if os.IsNotExist(err) {
			raw = []byte(`{"revision":0,"state":{}}`)
		}
		if err != nil && !os.IsNotExist(err) {
			internal(out)
			return
		}
		var persisted map[string]any
		if json.Unmarshal(raw, &persisted) != nil || persisted == nil {
			internal(out)
			return
		}
		revision, validRevision := persisted["revision"].(float64)
		state, validState := persisted["state"].(map[string]any)
		if !validRevision || revision < 0 || revision > webMaxRevision || revision != math.Trunc(revision) || !validState || state == nil {
			internal(out)
			return
		}
		out.Header().Set("Content-Type", "application/json")
		out.Write(raw)
		return
	}
	if r.Method != "PUT" {
		http.NotFound(out, r)
		return
	}
	var in struct {
		Revision int             `json:"revision"`
		State    json.RawMessage `json:"state"`
	}
	if !decodeLimited(out, r, &in, webStateLimit) {
		return
	}
	if in.Revision < 0 || int64(in.Revision) > webMaxRevision {
		writeError(out, 400, "invalid_request", "revision is out of range")
		return
	}
	if len(in.State) == 0 || !json.Valid(in.State) {
		writeError(out, 400, "invalid_request", "state must be JSON")
		return
	}
	var obj any
	if json.Unmarshal(in.State, &obj) != nil {
		writeError(out, 400, "invalid_request", "state must be JSON")
		return
	}
	stateObject, ok := obj.(map[string]any)
	if !ok {
		writeError(out, 400, "invalid_request", "state must be an object")
		return
	}
	raw, err := readWebState(w.statePath + ".web.json")
	current := 0
	container := map[string]any{}
	if err == nil {
		if json.Unmarshal(raw, &container) != nil || container == nil {
			internal(out)
			return
		}
		value, ok := container["revision"].(float64)
		if !ok || value < 0 || value > webMaxRevision || value != math.Trunc(value) {
			internal(out)
			return
		}
		current = int(value)
		if previous, exists := container["state"]; exists {
			if _, ok := previous.(map[string]any); !ok {
				internal(out)
				return
			}
		}
	} else if !os.IsNotExist(err) {
		internal(out)
		return
	}
	if in.Revision != current {
		writeJSON(out, 409, map[string]any{"revision": current, "state": container["state"]})
		return
	}
	if current >= webMaxRevision {
		writeError(out, 409, "revision_exhausted", "Local web state revision cannot advance")
		return
	}
	container["revision"] = current + 1
	oldState, _ := container["state"].(map[string]any)
	if oldState == nil {
		oldState = map[string]any{}
	}
	for key, value := range stateObject {
		oldState[key] = value
	}
	container["state"] = oldState
	data, _ := json.Marshal(container)
	if len(data)+1 > webPersistLimit {
		writeError(out, 413, "state_too_large", "Local web state is too large")
		return
	}
	if err := writePrivateState(w.statePath+".web.json", append(data, '\n')); err != nil {
		internal(out)
		return
	}
	writeJSON(out, 200, map[string]any{"revision": current + 1, "state": oldState})
}

func (w *localWeb) importLegacy(out http.ResponseWriter, r *http.Request) {
	w.stateMu.Lock()
	defer w.stateMu.Unlock()
	if !w.host.localSession(r) {
		writeError(out, 403, "local_only", "Only this Mac can import local web state")
		return
	}
	var in struct {
		Legacy json.RawMessage `json:"legacy"`
	}
	if !decodeLimited(out, r, &in, webStateLimit) {
		return
	}
	raw, err := readWebState(w.statePath + ".web.json")
	container := map[string]any{"revision": 0, "state": map[string]any{}}
	if err == nil {
		if json.Unmarshal(raw, &container) != nil || container == nil {
			internal(out)
			return
		}
		if value, ok := container["revision"].(float64); !ok || value < 0 || value > webMaxRevision || value != math.Trunc(value) {
			internal(out)
			return
		}
	} else if !os.IsNotExist(err) {
		internal(out)
		return
	}
	state, ok := container["state"].(map[string]any)
	if !ok {
		if _, exists := container["state"]; exists {
			internal(out)
			return
		}
		state = map[string]any{}
		container["state"] = state
	}
	if _, exists := state["legacy"]; exists {
		writeJSON(out, 200, map[string]bool{"imported": false})
		return
	}
	if revision, ok := container["revision"].(float64); ok && revision >= webMaxRevision {
		writeError(out, 409, "revision_exhausted", "Local web state revision cannot advance")
		return
	}
	var legacy any
	if json.Unmarshal(in.Legacy, &legacy) != nil {
		writeError(out, 400, "invalid_request", "legacy must be JSON")
		return
	}
	if _, ok := legacy.(map[string]any); !ok {
		writeError(out, 400, "invalid_request", "legacy must be an object")
		return
	}
	state["legacy"] = legacy
	if revision, ok := container["revision"].(float64); ok {
		container["revision"] = int(revision) + 1
	} else {
		container["revision"] = 1
	}
	data, _ := json.Marshal(container)
	if len(data)+1 > webPersistLimit {
		writeError(out, 413, "state_too_large", "Local web state is too large")
		return
	}
	if err := writePrivateState(w.statePath+".web.json", append(data, '\n')); err != nil {
		internal(out)
		return
	}
	writeJSON(out, 200, map[string]bool{"imported": true})
}

func (w *localWeb) pruneLocked(now time.Time) {
	for k, v := range w.grants {
		if !v.After(now) {
			delete(w.grants, k)
		}
	}
	for k, v := range w.sessions {
		if !v.After(now) {
			delete(w.sessions, k)
		}
	}
}
