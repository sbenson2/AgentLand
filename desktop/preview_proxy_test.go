package host

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"net/textproto"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// seenRequest is what an upstream received.
type seenRequest struct {
	method, host, uri string
	header            http.Header
}

// upstream is a loopback web server standing in for a dev server. It
// records each request, then runs handle (or answers with its path).
type upstream struct {
	*httptest.Server
	port int

	mu   sync.Mutex
	seen []seenRequest
}

func newUpstream(t *testing.T, handle http.HandlerFunc) *upstream {
	t.Helper()
	u := &upstream{}
	u.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u.mu.Lock()
		u.seen = append(u.seen, seenRequest{r.Method, r.Host, r.RequestURI, r.Header.Clone()})
		u.mu.Unlock()
		if handle != nil {
			handle(w, r)
			return
		}
		fmt.Fprint(w, "upstream "+r.URL.Path)
	}))
	t.Cleanup(u.Close)
	u.port = u.Listener.Addr().(*net.TCPAddr).Port
	return u
}

func (u *upstream) requests() []seenRequest {
	u.mu.Lock()
	defer u.mu.Unlock()
	return append([]seenRequest(nil), u.seen...)
}

func (u *upstream) last(t *testing.T) seenRequest {
	t.Helper()
	seen := u.requests()
	if len(seen) == 0 {
		t.Fatal("the upstream received nothing")
	}
	return seen[len(seen)-1]
}

// serve runs the preview listener's handler over TLS (HTTP/1.1 unless http2).
// Its cleanup ends preview sessions first, so no proxied stream holds Close.
func (f *previewFixture) serve(t *testing.T, http2 bool) *httptest.Server {
	t.Helper()
	server := httptest.NewUnstartedServer(f.host.PreviewHandler())
	server.EnableHTTP2 = http2
	server.StartTLS()
	t.Cleanup(func() {
		f.host.StopPreviews()
		server.Close()
	})
	return server
}

// servePlain runs the preview handler over plain HTTP for raw-socket tests.
func (f *previewFixture) servePlain(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(f.host.PreviewHandler())
	t.Cleanup(func() {
		f.host.StopPreviews()
		server.Close()
	})
	return server
}

// previewFor opens a session of f.token for u.
func (f *previewFixture) previewFor(t *testing.T, u *upstream) previewGrant {
	t.Helper()
	f.listen(u.port)
	return f.open(t, f.token, u.port)
}

func (g previewGrant) cookie() string { return g.Cookie.Name + "=" + g.Cookie.Value }

// send makes one request through the preview listener without following
// redirects.
func send(t *testing.T, server *httptest.Server, method, target string, header http.Header, body io.Reader) *http.Response {
	t.Helper()
	request, err := http.NewRequest(method, server.URL+target, body)
	if err != nil {
		t.Fatal(err)
	}
	for name, values := range header {
		if name == "Host" {
			request.Host = values[0]
			continue
		}
		request.Header[name] = values
	}
	client := *server.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { response.Body.Close() })
	return response
}

func readBody(t *testing.T, response *http.Response) string {
	t.Helper()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// wantProxyError checks an answer from the proxy itself.
func wantProxyError(t *testing.T, label string, response *http.Response, status int, code string) {
	t.Helper()
	body := readBody(t, response)
	if response.StatusCode != status || response.Header.Get("X-AgentLand-Preview-Error") != code || !strings.Contains(body, fmt.Sprintf(`"code":%q`, code)) {
		t.Errorf("%s: %d %q %s, want %d %s", label, response.StatusCode, response.Header.Get("X-AgentLand-Preview-Error"), body, status, code)
	}
}

func TestPreviewProxyNeedsALiveSessionCookie(t *testing.T) {
	f := newPreviewFixture(t)
	mine := newUpstream(t, nil)
	theirs := newUpstream(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "theirs") })
	server := f.serve(t, false)
	grant := f.previewFor(t, mine)
	other := paired(t, f.host, f.store)
	f.listen(theirs.port)
	otherGrant := f.open(t, other, theirs.port)

	wantProxyError(t, "no cookie", send(t, server, "GET", "/", nil, nil), 401, "preview_session_required")
	wantProxyError(t, "wrong cookie", send(t, server, "GET", "/", http.Header{"Cookie": {previewCookieName + "=" + strings.Repeat("A", 43)}}, nil), 401, "preview_session_required")
	wantProxyError(t, "cookie under another name", send(t, server, "GET", "/", http.Header{"Cookie": {"agentland-preview=" + grant.Cookie.Value}}, nil), 401, "preview_session_required")
	if len(mine.requests()) != 0 {
		t.Fatal("an unauthenticated request reached the upstream")
	}
	if response := send(t, server, "GET", "/page", http.Header{"Cookie": {grant.cookie()}}, nil); response.StatusCode != 200 || readBody(t, response) != "upstream /page" {
		t.Fatalf("own session: %d", response.StatusCode)
	}
	// A cookie opens exactly its own session's port.
	if response := send(t, server, "GET", "/", http.Header{"Cookie": {otherGrant.cookie()}}, nil); readBody(t, response) != "theirs" {
		t.Fatal("another device's session reached another port")
	}

	// A revoked device's sessions end within the recheck interval.
	if err := f.store.RevokeDevice(f.deviceID(t, other)); err != nil {
		t.Fatal(err)
	}
	f.advance(previewDeviceRecheck + time.Second)
	wantProxyError(t, "revoked device", send(t, server, "GET", "/", http.Header{"Cookie": {otherGrant.cookie()}}, nil), 401, "preview_session_required")
	if f.session(otherGrant.SessionID) != nil {
		t.Fatal("a revoked device kept its session")
	}
	if response := send(t, server, "GET", "/", http.Header{"Cookie": {grant.cookie()}}, nil); response.StatusCode != 200 {
		t.Fatalf("a paired device lost access: %d", response.StatusCode)
	}

	// Revoked and expired sessions.
	request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", f.token, map[string]string{"sessionId": grant.SessionID})
	wantProxyError(t, "revoked session", send(t, server, "GET", "/", http.Header{"Cookie": {grant.cookie()}}, nil), 401, "preview_session_required")
	idle := f.open(t, f.token, mine.port)
	f.advance(31 * time.Minute)
	wantProxyError(t, "idle session", send(t, server, "GET", "/", http.Header{"Cookie": {idle.cookie()}}, nil), 401, "preview_session_required")
}

func TestPreviewProxyOnlyReachesTheSessionPort(t *testing.T) {
	f := newPreviewFixture(t)
	target := newUpstream(t, nil)
	server := f.serve(t, false)
	grant := f.previewFor(t, target)

	// The Host header never chooses the destination.
	response := send(t, server, "GET", "/latest/meta-data", http.Header{"Cookie": {grant.cookie()}, "Host": {"169.254.169.254"}}, nil)
	if response.StatusCode != 200 || readBody(t, response) != "upstream /latest/meta-data" || target.last(t).host != fmt.Sprintf("localhost:%d", target.port) {
		t.Fatalf("Host override: %d %+v", response.StatusCode, target.last(t))
	}

	raw := func(line string) *http.Response {
		t.Helper()
		conn, err := tls.Dial("tcp", server.Listener.Addr().String(), server.Client().Transport.(*http.Transport).TLSClientConfig)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		fmt.Fprintf(conn, "%s\r\nHost: 169.254.169.254\r\nCookie: %s\r\n\r\n", line, grant.cookie())
		response, err := http.ReadResponse(bufio.NewReader(conn), nil)
		if err != nil {
			t.Fatal(err)
		}
		return response
	}
	before := len(target.requests())
	wantProxyError(t, "absolute-form URI", raw("GET http://169.254.169.254/latest HTTP/1.1"), 400, "bad_request")
	wantProxyError(t, "absolute-form URI to the upstream", raw(fmt.Sprintf("GET http://127.0.0.1:%d/ HTTP/1.1", target.port)), 400, "bad_request")
	wantProxyError(t, "CONNECT", raw("CONNECT 127.0.0.1:22 HTTP/1.1"), 400, "bad_request")
	if len(target.requests()) != before {
		t.Fatal("a rejected request reached the upstream")
	}

	// The transport dials nothing but loopback at the rewritten port.
	for _, address := range []string{"10.0.0.1:80", "localhost:80", "[::1]:80", "127.0.0.1:0", "127.0.0.1:70000", "127.0.0.1", "169.254.169.254:80"} {
		if conn, err := dialPreviewUpstream(context.Background(), "tcp", address); err == nil {
			conn.Close()
			t.Errorf("dialed %s", address)
		}
	}
	if f.host.preview.transport.Proxy != nil {
		t.Error("the transport uses a proxy")
	}
}

func TestPreviewProxyRewritesRequestHeaders(t *testing.T) {
	f := newPreviewFixture(t)
	target := newUpstream(t, nil)
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	upstreamOrigin := fmt.Sprintf("http://localhost:%d", target.port)
	header := http.Header{
		"Cookie":            {grant.cookie() + "; theme=dark; __host-agentland-preview=other", "lang=en"},
		"Origin":            {server.URL},
		"Referer":           {server.URL + "/start?a=b"},
		"X-Forwarded-For":   {"203.0.113.9"},
		"X-Forwarded-Host":  {"evil.example"},
		"X-Forwarded-Proto": {"http"},
		"Forwarded":         {"for=203.0.113.9"},
		"Connection":        {"X-Hop"},
		"X-Hop":             {"1"},
		"Authorization":     {"Basic YXBwOmFwcA=="},
	}
	// The query goes on exactly as sent, even a part Go cannot parse.
	response := send(t, server, "GET", "/page?x=1&y=%zz;z", header, nil)
	if response.StatusCode != 200 {
		t.Fatalf("status %d", response.StatusCode)
	}
	seen := target.last(t)
	checks := map[string][2]string{
		"Host":              {seen.host, fmt.Sprintf("localhost:%d", target.port)},
		"URI":               {seen.uri, "/page?x=1&y=%zz;z"},
		"Origin":            {seen.header.Get("Origin"), upstreamOrigin},
		"Referer":           {seen.header.Get("Referer"), upstreamOrigin + "/start?a=b"},
		"Cookie":            {strings.Join(seen.header.Values("Cookie"), "|"), "theme=dark; lang=en"},
		"X-Forwarded-Proto": {seen.header.Get("X-Forwarded-Proto"), "https"},
		"X-Forwarded-For":   {seen.header.Get("X-Forwarded-For"), ""},
		"X-Forwarded-Host":  {seen.header.Get("X-Forwarded-Host"), ""},
		"Forwarded":         {seen.header.Get("Forwarded"), ""},
		"X-Hop":             {seen.header.Get("X-Hop"), ""},
		"Authorization":     {seen.header.Get("Authorization"), "Basic YXBwOmFwcA=="},
	}
	for name, pair := range checks {
		if pair[0] != pair[1] {
			t.Errorf("%s: %q, want %q", name, pair[0], pair[1])
		}
	}

	// Another site's Origin and Referer on a GET go on unchanged; a Cookie
	// header with only the session cookie is dropped.
	send(t, server, "GET", "/", http.Header{"Cookie": {grant.cookie()}, "Origin": {"https://example.com"}, "Referer": {"https://example.com/x"}}, nil)
	seen = target.last(t)
	if seen.header.Get("Origin") != "https://example.com" || seen.header.Get("Referer") != "https://example.com/x" || len(seen.header.Values("Cookie")) != 0 {
		t.Errorf("foreign headers: %v", seen.header)
	}
}

func TestPreviewProxyRewritesResponseHeaders(t *testing.T) {
	f := newPreviewFixture(t)
	var target *upstream
	target = newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		header := w.Header()
		header.Set("Location", fmt.Sprintf("http://localhost:%d/next?x=1#top", target.port))
		header.Add("Set-Cookie", "session=abc; Domain=localhost; Path=/; HttpOnly")
		header.Add("Set-Cookie", "__Host-agentland-preview=stolen; Path=/; Secure")
		header.Add("Set-Cookie", "=__Host-agentland-preview=nameless")
		header.Add("Set-Cookie", "__HOST-AGENTLAND-PREVIEW=upper")
		header.Add("Set-Cookie", "other=1; domain=.example.com; Secure")
		header.Set("Strict-Transport-Security", "max-age=31536000")
		header.Set("X-AgentLand-Preview-Error", "spoofed")
		header.Set("X-Custom", "kept")
		w.WriteHeader(302)
	})
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	response := send(t, server, "GET", "/login", http.Header{"Cookie": {grant.cookie()}}, nil)
	want := map[string][]string{
		"Location":                  {"/next?x=1#top"},
		"Set-Cookie":                {"session=abc; Path=/; HttpOnly", "other=1; Secure"},
		"Strict-Transport-Security": nil,
		"X-Agentland-Preview-Error": nil,
		"X-Custom":                  {"kept"},
	}
	for name, values := range want {
		if got := response.Header.Values(name); !reflect.DeepEqual(got, values) && !(len(got) == 0 && len(values) == 0) {
			t.Errorf("%s: %q, want %q", name, got, values)
		}
	}
	if response.StatusCode != 302 {
		t.Errorf("status %d", response.StatusCode)
	}
}

func TestPreviewLocationRewrite(t *testing.T) {
	info := &previewRequest{session: &previewSession{port: 5173}, host: "mac.local:9842", secure: true}
	cases := map[string]string{
		"http://localhost:5173/next?x=1":          "/next?x=1",
		"https://127.0.0.1:5173/a#b":              "/a#b",
		"http://[::1]:5173":                       "/",
		"http://LOCALHOST:5173/x?":                "/x?",
		"http://user@localhost:5173/private":      "/private",
		"http://localhost:5173//evil.example/x":   "https://mac.local:9842//evil.example/x",
		"http://localhost:5173/%2F%2Fevil":        "/%2F%2Fevil",
		"http://localhost:3000/other":             "http://localhost:3000/other",
		"http://localhost/x":                      "http://localhost/x",
		"https://example.com/login":               "https://example.com/login",
		"/relative":                               "/relative",
		"javascript:alert(1)":                     "javascript:alert(1)",
		"http://192.168.1.8:5173/lan":             "http://192.168.1.8:5173/lan",
		"http://localhost:5173/path with space":   "/path%20with%20space",
		"http://localhost:5173/caf%C3%A9?q=a%20b": "/caf%C3%A9?q=a%20b",
	}
	for location, want := range cases {
		if got := previewLocation(location, info); got != want {
			t.Errorf("previewLocation(%q) = %q, want %q", location, got, want)
		}
	}
	if got := previewLocation("http://localhost:80/x", &previewRequest{session: &previewSession{port: 80}, host: "h:1"}); got != "/x" {
		t.Errorf("default port: %q", got)
	}
	// Without a Host to name, a // path is left alone rather than becoming
	// "https:////evil.example", which browsers read as another host.
	if got := previewLocation("http://localhost:5173//evil.example", &previewRequest{session: &previewSession{port: 5173}}); got != "http://localhost:5173//evil.example" {
		t.Errorf("no Host: %q", got)
	}
}

func TestPreviewProxySanitizesEarlyHints(t *testing.T) {
	f := newPreviewFixture(t)
	target := newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Link", "</app.css>; rel=preload")
		w.Header().Add("Set-Cookie", "__Host-agentland-preview=early")
		w.Header().Set("Strict-Transport-Security", "max-age=1")
		w.WriteHeader(http.StatusEarlyHints)
		fmt.Fprint(w, "final")
	})
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	var hints []textproto.MIMEHeader
	var mu sync.Mutex
	trace := &httptrace.ClientTrace{Got1xxResponse: func(code int, header textproto.MIMEHeader) error {
		mu.Lock()
		defer mu.Unlock()
		hints = append(hints, header)
		return nil
	}}
	request, _ := http.NewRequestWithContext(httptrace.WithClientTrace(context.Background(), trace), "GET", server.URL+"/", nil)
	request.Header.Set("Cookie", grant.cookie())
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if readBody(t, response) != "final" {
		t.Fatal("final answer missing")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(hints) != 1 || hints[0].Get("Link") == "" || len(hints[0].Values("Set-Cookie")) != 0 || hints[0].Get("Strict-Transport-Security") != "" {
		t.Fatalf("early hints %v", hints)
	}
}

func TestPreviewProxyReservesItsPathsAndServesNoAPI(t *testing.T) {
	f := newPreviewFixture(t)
	target := newUpstream(t, nil)
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	for _, path := range []string{"/__agentland", "/__agentland/", "/__agentland/session", "/a/../__agentland/x", "/%5F%5Fagentland/x"} {
		wantProxyError(t, path, send(t, server, "GET", path, http.Header{"Cookie": {grant.cookie()}}, nil), 404, "not_found")
	}
	if len(target.requests()) != 0 {
		t.Fatal("a reserved path reached the upstream")
	}
	// /v1 belongs to the previewed server here, not to the host API.
	response := send(t, server, "GET", "/v1/health", http.Header{"Cookie": {grant.cookie()}, "Authorization": {"Bearer " + f.token}}, nil)
	if body := readBody(t, response); response.StatusCode != 200 || body != "upstream /v1/health" {
		t.Fatalf("/v1 on the preview listener: %d %s", response.StatusCode, body)
	}
	if response := send(t, server, "GET", "/__agentlandish", http.Header{"Cookie": {grant.cookie()}}, nil); response.StatusCode != 200 {
		t.Fatalf("a path that only starts like the reserved one: %d", response.StatusCode)
	}
}

func TestPreviewProxyRefusesCrossSiteRequests(t *testing.T) {
	f := newPreviewFixture(t)
	target := newUpstream(t, nil)
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	cookie := grant.cookie()
	for _, method := range []string{"POST", "PUT", "PATCH", "DELETE", "OPTIONS"} {
		for _, origin := range [][]string{{"https://evil.example"}, {"null"}, {server.URL, "https://evil.example"}, {strings.Replace(server.URL, "https://", "http://", 1)}} {
			label := fmt.Sprintf("%s from %v", method, origin)
			wantProxyError(t, label, send(t, server, method, "/submit", http.Header{"Cookie": {cookie}, "Origin": origin}, strings.NewReader("x")), 403, "cross_site_rejected")
		}
	}
	if len(target.requests()) != 0 {
		t.Fatal("a cross-site request reached the upstream")
	}
	if response := send(t, server, "POST", "/submit", http.Header{"Cookie": {cookie}, "Origin": {server.URL}}, strings.NewReader("x")); response.StatusCode != 200 || target.last(t).header.Get("Origin") != fmt.Sprintf("http://localhost:%d", target.port) {
		t.Fatalf("same-origin POST: %d %v", response.StatusCode, target.last(t).header)
	}
	if response := send(t, server, "POST", "/submit", http.Header{"Cookie": {cookie}}, strings.NewReader("x")); response.StatusCode != 200 {
		t.Fatalf("POST without Origin: %d", response.StatusCode)
	}
	for _, method := range []string{"GET", "HEAD"} {
		if response := send(t, server, method, "/", http.Header{"Cookie": {cookie}, "Origin": {"https://evil.example"}}, nil); response.StatusCode != 200 {
			t.Fatalf("cross-site %s: %d", method, response.StatusCode)
		}
	}
}

func TestPreviewProxyLimitsRequestBodies(t *testing.T) {
	f := newPreviewFixture(t)
	f.host.preview.limits.bodyBytes = 1024
	received := make(chan int, 8)
	target := newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		data, err := io.ReadAll(r.Body)
		if err != nil {
			return
		}
		received <- len(data)
	})
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	header := http.Header{"Cookie": {grant.cookie()}}
	wantProxyError(t, "declared length over the limit", send(t, server, "POST", "/upload", header, bytes.NewReader(make([]byte, 2048))), 413, "request_too_large")
	if len(target.requests()) != 0 {
		t.Fatal("an oversized body reached the upstream")
	}
	// A chunked body is cut off at the limit.
	wantProxyError(t, "chunked body over the limit", send(t, server, "POST", "/upload", header, io.MultiReader(bytes.NewReader(make([]byte, 4096)))), 413, "request_too_large")
	if response := send(t, server, "POST", "/upload", header, bytes.NewReader(make([]byte, 1024))); response.StatusCode != 200 || <-received != 1024 {
		t.Fatalf("body at the limit: %d", response.StatusCode)
	}
	if defaultPreviewLimits.bodyBytes != 64<<20 || defaultPreviewLimits.concurrent != 64 {
		t.Fatalf("default limits %+v", defaultPreviewLimits)
	}
}

func TestPreviewProxyTimesOutSlowRequestBodies(t *testing.T) {
	f := newPreviewFixture(t)
	f.host.preview.limits.bodyTimeout = 300 * time.Millisecond
	f.host.preview.limits.bodyRate = 1 << 30
	target := newUpstream(t, func(w http.ResponseWriter, r *http.Request) { _, _ = io.ReadAll(r.Body) })
	server := f.servePlain(t)
	grant := f.previewFor(t, target)
	conn, err := net.Dial("tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "POST /upload HTTP/1.1\r\nHost: preview\r\nCookie: %s\r\nContent-Length: 100\r\n\r\n0123456789", grant.cookie())
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	wantProxyError(t, "stalled body", response, 408, "request_timeout")
}

func TestPreviewProxyLimitsConcurrentRequests(t *testing.T) {
	f := newPreviewFixture(t)
	f.host.preview.limits.concurrent = 2
	arrived := make(chan struct{}, 8)
	release := make(chan struct{})
	target := newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/wait" {
			arrived <- struct{}{}
			<-release
		}
		fmt.Fprint(w, "done")
	})
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	header := http.Header{"Cookie": {grant.cookie()}}
	results := make(chan int, 2)
	for range 2 {
		go func() {
			request, _ := http.NewRequest("GET", server.URL+"/wait", nil)
			request.Header.Set("Cookie", grant.cookie())
			response, err := server.Client().Do(request)
			if err != nil {
				results <- 0
				return
			}
			response.Body.Close()
			results <- response.StatusCode
		}()
	}
	for range 2 {
		select {
		case <-arrived:
		case <-time.After(5 * time.Second):
			t.Fatal("requests did not reach the upstream")
		}
	}
	wantProxyError(t, "third concurrent request", send(t, server, "GET", "/", header, nil), 429, "preview_busy")
	close(release)
	for range 2 {
		if status := <-results; status != 200 {
			t.Fatalf("held request: %d", status)
		}
	}
	if response := send(t, server, "GET", "/", header, nil); response.StatusCode != 200 {
		t.Fatalf("after the burst: %d", response.StatusCode)
	}
}

// Idle gaps longer than the write window do not cut a streamed answer, over
// HTTP/1.1 or HTTP/2.
func TestPreviewProxyStreamsPastTheWriteWindow(t *testing.T) {
	for _, http2 := range []bool{false, true} {
		t.Run(fmt.Sprintf("http2=%v", http2), func(t *testing.T) {
			f := newPreviewFixture(t)
			f.host.preview.limits.writeWindow = 150 * time.Millisecond
			target := newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
				time.Sleep(400 * time.Millisecond)
				w.Header().Set("Content-Type", "text/event-stream")
				for _, part := range []string{"data: a\n\n", "data: b\n\n"} {
					fmt.Fprint(w, part)
					w.(http.Flusher).Flush()
					time.Sleep(400 * time.Millisecond)
				}
			})
			server := f.serve(t, http2)
			grant := f.previewFor(t, target)
			response := send(t, server, "GET", "/events", http.Header{"Cookie": {grant.cookie()}}, nil)
			if http2 && response.ProtoMajor != 2 {
				t.Fatalf("protocol %s", response.Proto)
			}
			if body := readBody(t, response); response.StatusCode != 200 || body != "data: a\n\ndata: b\n\n" {
				t.Fatalf("stream: %d %q", response.StatusCode, body)
			}
		})
	}
}

// A client that stops reading loses its response within the write window
// instead of holding the request.
func TestPreviewProxyReleasesStalledReaders(t *testing.T) {
	f := newPreviewFixture(t)
	f.host.preview.limits.writeWindow = 200 * time.Millisecond
	target := newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		chunk := bytes.Repeat([]byte("x"), 32<<10)
		for range 2048 {
			if _, err := w.Write(chunk); err != nil {
				return
			}
		}
	})
	server := f.servePlain(t)
	grant := f.previewFor(t, target)
	conn, err := net.Dial("tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "GET /big HTTP/1.1\r\nHost: preview\r\nCookie: %s\r\n\r\n", grant.cookie())
	session := f.session(grant.SessionID)
	archiveEventually(t, "the request starts", func() bool {
		f.host.preview.mu.Lock()
		defer f.host.preview.mu.Unlock()
		return session.inflight == 1
	})
	archiveEventually(t, "the stalled request ends", func() bool {
		f.host.preview.mu.Lock()
		defer f.host.preview.mu.Unlock()
		return session.inflight == 0
	})
}

func TestPreviewProxyReportsAMissingUpstream(t *testing.T) {
	f := newPreviewFixture(t)
	target := newUpstream(t, nil)
	server := f.serve(t, false)
	grant := f.previewFor(t, target)
	target.Close()
	wantProxyError(t, "stopped dev server", send(t, server, "GET", "/", http.Header{"Cookie": {grant.cookie()}}, nil), 502, "upstream_unavailable")
}

func TestPreviewProxyReachesAServerOnIPv6LoopbackOnly(t *testing.T) {
	listener, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skip("no IPv6 loopback:", err)
	}
	only6 := &httptest.Server{Listener: listener, Config: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "from ::1 as "+r.Host)
	})}}
	only6.Start()
	defer only6.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	if probe, err := net.Dial("tcp4", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
		probe.Close()
		t.Skip("the port is also taken on 127.0.0.1")
	}
	f := newPreviewFixture(t)
	server := f.serve(t, false)
	f.listen(port)
	grant := f.open(t, f.token, port)
	response := send(t, server, "GET", "/", http.Header{"Cookie": {grant.cookie()}}, nil)
	if body := readBody(t, response); body != fmt.Sprintf("from ::1 as localhost:%d", port) {
		t.Fatalf("IPv6-only server: %d %q", response.StatusCode, body)
	}
}

// echoUpstream accepts WebSockets and echoes each message.
func echoUpstream(t *testing.T) (*upstream, chan string) {
	t.Helper()
	origins := make(chan string, 8)
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool {
		origins <- r.Header.Get("Origin")
		return true
	}}
	return newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			kind, data, err := conn.ReadMessage()
			if err != nil || conn.WriteMessage(kind, data) != nil {
				return
			}
		}
	}), origins
}

func dialPreviewSocket(t *testing.T, server *httptest.Server, cookie, origin string) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	dialer := websocket.Dialer{HandshakeTimeout: 5 * time.Second, TLSClientConfig: server.Client().Transport.(*http.Transport).TLSClientConfig}
	header := http.Header{"Cookie": {cookie}, "Origin": {origin}}
	conn, response, err := dialer.Dial(strings.Replace(server.URL, "https://", "wss://", 1)+"/hmr", header)
	if conn != nil {
		t.Cleanup(func() { conn.Close() })
	}
	return conn, response, err
}

func echo(t *testing.T, conn *websocket.Conn, text string) {
	t.Helper()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(text)); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, data, err := conn.ReadMessage(); err != nil || string(data) != text {
		t.Fatalf("echo %q: %q %v", text, data, err)
	}
}

// wantClosed waits for the host to close conn.
func wantClosed(t *testing.T, label string, conn *websocket.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, _, err := conn.ReadMessage()
	var network net.Error
	if err == nil || (errors.As(err, &network) && network.Timeout()) {
		t.Fatalf("%s: the WebSocket stayed open: %v", label, err)
	}
}

func TestPreviewProxyWebSockets(t *testing.T) {
	f := newPreviewFixture(t)
	target, origins := echoUpstream(t)
	server := f.serve(t, false)
	grant := f.previewFor(t, target)

	conn, _, err := dialPreviewSocket(t, server, grant.cookie(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	echo(t, conn, "hot update")
	if origin := <-origins; origin != fmt.Sprintf("http://localhost:%d", target.port) {
		t.Fatalf("upstream saw Origin %q", origin)
	}
	if seen := target.last(t); seen.host != fmt.Sprintf("localhost:%d", target.port) {
		t.Fatalf("upstream saw Host %q", seen.host)
	}

	// Cross-site WebSockets and those without a session are refused.
	if _, response, err := dialPreviewSocket(t, server, grant.cookie(), "https://evil.example"); err == nil || response == nil || response.StatusCode != 403 {
		t.Fatalf("cross-site WebSocket: %v %v", response, err)
	}
	if _, response, err := dialPreviewSocket(t, server, "", server.URL); err == nil || response == nil || response.StatusCode != 401 {
		t.Fatalf("WebSocket without a session: %v %v", response, err)
	}

	// Revoking the session closes its WebSocket.
	if w := request(t, f.host.Handler(), "POST", "/v1/preview/sessions/revoke", f.token, map[string]string{"sessionId": grant.SessionID}); w.Code != 200 {
		t.Fatalf("revoke: %d", w.Code)
	}
	wantClosed(t, "revoked session", conn)

	// So do the sweep after the device is revoked, and stopping previews.
	other := paired(t, f.host, f.store)
	otherGrant := f.open(t, other, target.port)
	otherConn, _, err := dialPreviewSocket(t, server, otherGrant.cookie(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	echo(t, otherConn, "second device")
	stay := f.open(t, f.token, target.port)
	stayConn, _, err := dialPreviewSocket(t, server, stay.cookie(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.store.RevokeDevice(f.deviceID(t, other)); err != nil {
		t.Fatal(err)
	}
	f.host.preview.sweep()
	wantClosed(t, "revoked device", otherConn)
	echo(t, stayConn, "still paired")

	// An open WebSocket keeps its session from idling out, but not past 12
	// hours.
	f.advance(time.Hour)
	f.host.preview.sweep()
	echo(t, stayConn, "after an idle hour")
	f.advance(12 * time.Hour)
	f.host.preview.sweep()
	wantClosed(t, "12 hours", stayConn)

	last := f.open(t, f.token, target.port)
	lastConn, _, err := dialPreviewSocket(t, server, last.cookie(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	echo(t, lastConn, "before stopping")
	f.host.StopPreviews()
	wantClosed(t, "stopped previews", lastConn)
	wantProxyError(t, "request while stopping", send(t, server, "GET", "/", http.Header{"Cookie": {last.cookie()}}, nil), 503, "host_stopping")
}
