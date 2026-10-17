package host

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The preview listener's handler. Every request needs a live session's
// cookie; the proxy sends it to the session's port on 127.0.0.1 (or ::1) and
// nowhere else, whatever the request's Host header or URI say. /v1 is not
// served here: every path except those under /__agentland/ goes to that port.

const (
	// previewErrorHeader marks answers of the proxy itself, so the app can
	// tell them from the previewed server's own answers.
	previewErrorHeader = "X-AgentLand-Preview-Error"
	// previewReserved and the paths under it are kept for the host.
	previewReserved = "/__agentland"
)

var errPreviewSessionEnded = errors.New("the web preview session ended")

// previewRequest carries a proxied request's session to the proxy's hooks.
type previewRequest struct {
	session *previewSession
	host    string // the preview listener as the client addressed it
	secure  bool
	body    *previewBody
}

type previewRequestKey struct{}

func previewRequestOf(ctx context.Context) *previewRequest {
	info, _ := ctx.Value(previewRequestKey{}).(*previewRequest)
	return info
}

// previewError answers for the proxy itself, as JSON errors like the API's,
// with previewErrorHeader set to the code.
func previewError(w http.ResponseWriter, status int, code, message string) {
	header := w.Header()
	header.Set("Content-Type", "application/json")
	header.Set("Cache-Control", "no-store")
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set(previewErrorHeader, code)
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

func previewSessionRequired(w http.ResponseWriter) {
	previewError(w, 401, "preview_session_required", "Open this web preview again from AgentLand")
}

func (m *previewManager) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case m.isStopped():
		previewError(w, 503, "host_stopping", "The host is stopping")
		return
	case r.Method == http.MethodConnect || r.URL.IsAbs() || r.URL.Host != "" || !strings.HasPrefix(r.RequestURI, "/"):
		previewError(w, 400, "bad_request", "Send the preview listener a path, not a full URL")
		return
	case previewReservedPath(r.URL.Path):
		previewError(w, 404, "not_found", "Not found")
		return
	case previewCrossSite(r):
		previewError(w, 403, "cross_site_rejected", "Requests from other sites are not allowed")
		return
	}
	session := m.sessionFor(r)
	if session == nil || !m.deviceActive(session.deviceID) {
		previewSessionRequired(w)
		return
	}
	if r.ContentLength > m.limits.bodyBytes {
		previewError(w, 413, "request_too_large", "The request body is too large for a web preview")
		return
	}
	switch m.acquire(session) {
	case previewEnded:
		previewSessionRequired(w)
		return
	case previewBusy:
		previewError(w, 429, "preview_busy", "Too many requests are in progress for this web preview")
		return
	}
	defer m.release(session)
	m.forward(w, r, session)
}

// forward proxies one admitted request. Its context ends with the session.
func (m *previewManager) forward(w http.ResponseWriter, r *http.Request, session *previewSession) {
	controller := http.NewResponseController(w)
	info := &previewRequest{session: session, host: r.Host, secure: r.TLS != nil}
	ctx, cancel := context.WithCancel(context.WithValue(r.Context(), previewRequestKey{}, info))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	outbound := r.WithContext(ctx)
	if r.Body != nil && r.Body != http.NoBody && r.ContentLength != 0 {
		info.body = newPreviewBody(w, r, controller, m.limits)
		defer info.body.finish()
		outbound.Body = info.body
	}
	writer := &previewResponseWriter{ResponseWriter: w, controller: controller, manager: m, session: session, window: m.limits.writeWindow}
	defer writer.finish()
	m.proxy.ServeHTTP(writer, outbound)
}

func previewReservedPath(requestPath string) bool {
	clean := path.Clean("/" + requestPath)
	return clean == previewReserved || strings.HasPrefix(clean, previewReserved+"/")
}

// previewCrossSite reports a request another site's page could have sent: a
// method other than GET and HEAD, or a connection upgrade such as a
// WebSocket, whose Origin is not the preview origin.
func previewCrossSite(r *http.Request) bool {
	origins := r.Header.Values("Origin")
	if len(origins) == 0 {
		return false
	}
	if (r.Method == http.MethodGet || r.Method == http.MethodHead) && !upgradeRequested(r.Header) {
		return false
	}
	return len(origins) != 1 || !previewSameOrigin(origins[0], r.Host, r.TLS != nil)
}

func upgradeRequested(header http.Header) bool {
	if header.Get("Upgrade") == "" {
		return false
	}
	for _, value := range header.Values("Connection") {
		for token := range strings.SplitSeq(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
				return true
			}
		}
	}
	return false
}

// previewSameOrigin reports whether origin is the preview listener as the
// client addressed it (host, the listener's scheme, the port).
func previewSameOrigin(origin, host string, secure bool) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	scheme := "http"
	if secure {
		scheme = "https"
	}
	return strings.EqualFold(u.Scheme, scheme) && canonicalAuthority(u.Host, scheme) == canonicalAuthority(host, scheme)
}

func canonicalAuthority(authority, scheme string) string {
	host, port, err := net.SplitHostPort(authority)
	if err != nil {
		host, port = strings.TrimSuffix(strings.TrimPrefix(authority, "["), "]"), ""
	}
	if port == "" {
		port = "80"
		if scheme == "https" {
			port = "443"
		}
	}
	return net.JoinHostPort(strings.ToLower(host), port)
}

// Outgoing requests.

// rewrite addresses the session's port with Host localhost:<port>, which dev
// servers such as Vite check, and presents requests from the preview origin
// as coming from http://localhost:<port>.
func (m *previewManager) rewrite(pr *httputil.ProxyRequest) {
	info := previewRequestOf(pr.In.Context())
	if info == nil {
		pr.Out.URL.Host = "invalid.invalid"
		return
	}
	port := strconv.Itoa(info.session.port)
	pr.Out.URL.Scheme = "http"
	pr.Out.URL.Host = net.JoinHostPort("127.0.0.1", port)
	// The query goes on exactly as sent; the proxy never reads it.
	pr.Out.URL.RawQuery = pr.In.URL.RawQuery
	pr.Out.Host = "localhost:" + port
	header := pr.Out.Header
	if origin := header.Get("Origin"); origin != "" && previewSameOrigin(origin, info.host, info.secure) {
		header.Set("Origin", "http://localhost:"+port)
	}
	if referer := header.Get("Referer"); referer != "" {
		if u, err := url.Parse(referer); err == nil && u.Host != "" && previewSameOrigin(u.Scheme+"://"+u.Host, info.host, info.secure) {
			u.Scheme, u.Host, u.User = "http", "localhost:"+port, nil
			header.Set("Referer", u.String())
		}
	}
	stripPreviewCookie(header)
	header.Set("X-Forwarded-Proto", "https")
}

// stripPreviewCookie removes the session cookie from the Cookie header and
// keeps the previewed site's own cookies.
func stripPreviewCookie(header http.Header) {
	values := header.Values("Cookie")
	if len(values) == 0 {
		return
	}
	var kept []string
	for _, value := range values {
		for pair := range strings.SplitSeq(value, ";") {
			pair = strings.TrimSpace(pair)
			name, _, _ := strings.Cut(pair, "=")
			if pair != "" && !strings.EqualFold(strings.TrimSpace(name), previewCookieName) {
				kept = append(kept, pair)
			}
		}
	}
	header.Del("Cookie")
	if len(kept) > 0 {
		header.Set("Cookie", strings.Join(kept, "; "))
	}
}

// newPreviewTransport never uses a proxy from the environment, never follows
// redirects (only http.Client does) and dials nothing but loopback.
func newPreviewTransport() *http.Transport {
	return &http.Transport{
		Proxy:                  nil,
		DialContext:            dialPreviewUpstream,
		MaxIdleConns:           64,
		MaxIdleConnsPerHost:    16,
		IdleConnTimeout:        time.Minute,
		ResponseHeaderTimeout:  2 * time.Minute,
		ExpectContinueTimeout:  time.Second,
		MaxResponseHeaderBytes: 256 << 10,
		DisableCompression:     true,
	}
}

// dialPreviewUpstream connects to a session's port on 127.0.0.1, or on ::1
// when that fails (a dev server bound to ::1 alone, as Node does for
// "localhost" on macOS). It accepts only the address rewrite sets from the
// session.
func dialPreviewUpstream(ctx context.Context, _, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	number, convertErr := strconv.Atoi(port)
	if err != nil || convertErr != nil || host != "127.0.0.1" || number < 1 || number > 65535 {
		return nil, fmt.Errorf("web preview upstream %q is not a loopback port", address)
	}
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort("127.0.0.1", port))
	if err != nil && ctx.Err() == nil {
		if conn6, err6 := dialer.DialContext(ctx, "tcp6", net.JoinHostPort("::1", port)); err6 == nil {
			return conn6, nil
		}
	}
	return conn, err
}

// Responses.

func (m *previewManager) modifyResponse(res *http.Response) error {
	info := previewRequestOf(res.Request.Context())
	if info == nil {
		return errPreviewSessionEnded
	}
	if locations := res.Header.Values("Location"); len(locations) > 0 {
		rewritten := make([]string, len(locations))
		for i, location := range locations {
			rewritten[i] = previewLocation(location, info)
		}
		res.Header["Location"] = rewritten
	}
	sanitizePreviewHeader(res.Header)
	return nil
}

// previewLocation turns a redirect to the previewed server's own address
// (localhost, 127.0.0.1 or ::1 with the session's port) into a path on the
// preview origin. A path starting with // or /\ stays absolute on the
// preview origin: as a relative reference it would name another host.
func previewLocation(location string, info *previewRequest) string {
	u, err := url.Parse(location)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Opaque != "" {
		return location
	}
	host := strings.ToLower(u.Hostname())
	if host != "localhost" && host != "127.0.0.1" && host != "::1" {
		return location
	}
	port := u.Port()
	if port == "" {
		port = "80"
		if u.Scheme == "https" {
			port = "443"
		}
	}
	if port != strconv.Itoa(info.session.port) {
		return location
	}
	target := u.EscapedPath()
	if target == "" {
		target = "/"
	}
	if u.ForceQuery || u.RawQuery != "" {
		target += "?" + u.RawQuery
	}
	if u.Fragment != "" {
		target += "#" + u.EscapedFragment()
	}
	if strings.HasPrefix(target, "//") || strings.HasPrefix(target, "/\\") {
		if info.host == "" {
			return location
		}
		scheme := "http"
		if info.secure {
			scheme = "https"
		}
		return scheme + "://" + info.host + target
	}
	return target
}

// sanitizePreviewHeader removes what a previewed server must not set on the
// preview origin: the session cookie (also as a nameless cookie, which
// browsers send as name=value), cookie domains, HSTS and the proxy's own
// error marker.
func sanitizePreviewHeader(header http.Header) {
	if lines := header.Values("Set-Cookie"); len(lines) > 0 {
		kept := make([]string, 0, len(lines))
		for _, line := range lines {
			if !setsPreviewCookie(line) {
				kept = append(kept, withoutCookieDomain(line))
			}
		}
		header.Del("Set-Cookie")
		for _, line := range kept {
			header.Add("Set-Cookie", line)
		}
	}
	header.Del("Strict-Transport-Security")
	header.Del(previewErrorHeader)
}

func setsPreviewCookie(line string) bool {
	pair, _, _ := strings.Cut(line, ";")
	pair = strings.TrimSpace(pair)
	if nameless, found := strings.CutPrefix(pair, "="); found {
		pair = strings.TrimSpace(nameless)
	}
	name, _, _ := strings.Cut(pair, "=")
	return strings.EqualFold(strings.TrimSpace(name), previewCookieName)
}

func withoutCookieDomain(line string) string {
	parts := strings.Split(line, ";")
	kept := make([]string, 0, len(parts))
	kept = append(kept, parts[0])
	for _, attribute := range parts[1:] {
		name, _, _ := strings.Cut(attribute, "=")
		if !strings.EqualFold(strings.TrimSpace(name), "domain") {
			kept = append(kept, attribute)
		}
	}
	return strings.Join(kept, ";")
}

func (m *previewManager) proxyError(w http.ResponseWriter, r *http.Request, err error) {
	if writer, ok := w.(*previewResponseWriter); ok && writer.hijacked {
		return
	}
	info := previewRequestOf(r.Context())
	var tooLarge *http.MaxBytesError
	var network net.Error
	switch {
	case errors.As(err, &tooLarge):
		previewError(w, 413, "request_too_large", "The request body is too large for a web preview")
	case info == nil || m.sessionEnded(info.session):
		previewSessionRequired(w)
	case info.body != nil && errors.Is(info.body.readError(), os.ErrDeadlineExceeded):
		previewError(w, 408, "request_timeout", "The request body did not arrive in time")
	case errors.As(err, &network) && network.Timeout():
		previewError(w, 504, "upstream_timeout", "The previewed web server did not answer in time")
	default:
		previewError(w, 502, "upstream_unavailable", "Nothing answered on this web preview's port")
	}
}

// previewBody limits a request body's size and the time to receive it. The
// read deadline is lifted when the body is complete, so a long response to it
// (a streamed reply to a POST) is not cut off. A body that fails keeps its
// deadline: before answering, the server reads what is left of a small body,
// and that read must not wait for a client that stopped sending.
type previewBody struct {
	io.ReadCloser
	controller *http.ResponseController

	mu      sync.Mutex
	pending bool  // the deadline is set and the handler has not returned
	err     error // the read error that ended the body early
}

func newPreviewBody(w http.ResponseWriter, r *http.Request, controller *http.ResponseController, limits previewLimits) *previewBody {
	size := r.ContentLength
	if size < 0 || size > limits.bodyBytes {
		size = limits.bodyBytes
	}
	timeout := limits.bodyTimeout + time.Duration(size/limits.bodyRate)*time.Second
	body := &previewBody{ReadCloser: http.MaxBytesReader(w, r.Body, limits.bodyBytes), controller: controller}
	body.pending = controller.SetReadDeadline(time.Now().Add(timeout)) == nil
	return body
}

func (b *previewBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if err != nil {
		b.mu.Lock()
		if err != io.EOF && b.err == nil {
			b.err = err
		}
		if b.pending && err == io.EOF {
			_ = b.controller.SetReadDeadline(time.Time{})
		}
		b.pending = false
		b.mu.Unlock()
	}
	return n, err
}

func (b *previewBody) readError() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

// finish runs as the handler returns; the controller may not be used after
// that. An unfinished body keeps its deadline for the server's discard.
func (b *previewBody) finish() {
	b.mu.Lock()
	b.pending = false
	b.mu.Unlock()
}

// previewResponseWriter sets a write deadline around each write, so a client
// that stops reading cannot hold the handler while a response may stream as
// long as the upstream keeps it open. The listener has no write timeout, and
// on HTTP/2 a deadline is a timer on the stream, so none stays armed while
// the upstream prepares its answer. It also registers hijacked (WebSocket)
// connections with the session and sanitizes informational (1xx) answers.
type previewResponseWriter struct {
	http.ResponseWriter
	controller *http.ResponseController
	manager    *previewManager
	session    *previewSession
	window     time.Duration
	hijacked   bool
}

func (w *previewResponseWriter) WriteHeader(status int) {
	if status >= 100 && status < 200 {
		sanitizePreviewHeader(w.Header())
	}
	w.arm()
	defer w.disarm()
	w.ResponseWriter.WriteHeader(status)
}

func (w *previewResponseWriter) Write(p []byte) (int, error) {
	w.arm()
	defer w.disarm()
	return w.ResponseWriter.Write(p)
}

func (w *previewResponseWriter) Flush() { _ = w.FlushError() }

func (w *previewResponseWriter) FlushError() error {
	w.arm()
	defer w.disarm()
	return w.controller.Flush()
}

func (w *previewResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, buffered, err := w.controller.Hijack()
	if err != nil {
		return nil, nil, err
	}
	w.hijacked = true
	tracked, ok := w.manager.track(w.session, conn)
	if !ok {
		_ = conn.Close()
		return nil, nil, errPreviewSessionEnded
	}
	return tracked, buffered, nil
}

func (w *previewResponseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *previewResponseWriter) arm() {
	_ = w.controller.SetWriteDeadline(time.Now().Add(w.window))
}

func (w *previewResponseWriter) disarm() { _ = w.controller.SetWriteDeadline(time.Time{}) }

// finish arms the deadline for the rest of the response, which the server
// writes after the handler returns.
func (w *previewResponseWriter) finish() {
	if !w.hijacked {
		w.arm()
	}
}
