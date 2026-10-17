package host

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"sort"
	"sync"
	"time"
)

// Web previews (serve --enable-preview). A paired device's Browser tab opens
// a web server that this computer's user runs on a loopback port, such as a
// Vite or Next dev server, through the preview listener: a second HTTPS
// listener with the API's certificate whose handler (preview_proxy.go) sends
// every request of a session to that port over loopback and nowhere else.
// The /v1/preview routes list ports and create, list and end sessions. A
// session's secret leaves the host only in the answer that creates it; the
// app puts it in its web view as the __Host- cookie. The host keeps only the
// secret's SHA-256, in memory, so a host restart ends every session.

// DefaultPreviewPort is the preview listener's port unless serve's
// --preview-listen names another.
const DefaultPreviewPort = 9842

const (
	previewCookieName        = "__Host-agentland-preview"
	previewIdleTimeout       = 30 * time.Minute
	previewSessionLifetime   = 12 * time.Hour
	previewSessionsPerDevice = 8
	previewSessionsTotal     = 64
	// A proxied request trusts a device check this recent, and the sweep
	// repeats the check this often while sessions exist.
	previewDeviceRecheck = 5 * time.Second
	previewTimeLayout    = "2006-01-02T15:04:05.000Z"
)

var (
	errPreviewStopped      = errors.New("web previews are stopping")
	errPreviewSessionLimit = errors.New("too many preview sessions")
)

// PreviewOptions turns on web previews.
type PreviewOptions struct {
	// Port is the preview listener's port, advertised in capabilities.
	Port int
	// APIPort is the API listener's port. Discovery never lists it, Port or
	// the configured OpenCode port.
	APIPort int
	// AllowPorts lists ports from the default exclusions (SSH, printing,
	// Docker, databases and search) that previews may use anyway.
	AllowPorts []int
}

// previewLimits bound the proxy; tests shrink them.
type previewLimits struct {
	bodyBytes     int64         // one request body
	concurrent    int           // requests in progress per session, WebSockets included
	writeWindow   time.Duration // for each write of a response
	bodyTimeout   time.Duration // to receive a request body, plus a second per bodyRate bytes
	bodyRate      int64
	sweepInterval time.Duration
}

var defaultPreviewLimits = previewLimits{
	bodyBytes:     64 << 20,
	concurrent:    64,
	writeWindow:   time.Minute,
	bodyTimeout:   2 * time.Minute,
	bodyRate:      256 << 10,
	sweepInterval: previewDeviceRecheck,
}

type previewManager struct {
	store   *Store
	port    int
	apiPort int
	allowed map[int]bool
	pid     int
	now     func() time.Time
	// discover lists listening sockets; tests replace it.
	discover  func(context.Context) ([]portListener, error)
	limits    previewLimits
	transport *http.Transport
	proxy     *httputil.ReverseProxy

	mu             sync.Mutex
	sessions       map[string]*previewSession // by ID
	devices        map[string]bool            // paired device ID → not revoked, as of devicesChecked
	devicesChecked time.Time
	stopped        bool
	sweeping       bool
	stop           chan struct{}

	// refreshMu lets one caller at a time read the host state for devices.
	refreshMu sync.Mutex

	scanMu sync.Mutex
	scan   *previewScan
}

// previewSession gives one device access to one port.
type previewSession struct {
	id       string
	deviceID string
	port     int
	secret   [sha256.Size]byte // SHA-256 of the cookie value
	created  time.Time
	// ctx ends with the session, which stops its requests.
	ctx    context.Context
	cancel context.CancelFunc

	// Guarded by previewManager.mu.
	lastUsed time.Time
	inflight int
	upgraded map[*previewConn]struct{}
	ended    bool
}

func newPreviewManager(store *Store, options PreviewOptions) *previewManager {
	m := &previewManager{
		store:    store,
		port:     options.Port,
		apiPort:  options.APIPort,
		allowed:  map[int]bool{},
		pid:      os.Getpid(),
		now:      time.Now,
		discover: platformListeners,
		limits:   defaultPreviewLimits,
		sessions: map[string]*previewSession{},
		devices:  map[string]bool{},
		stop:     make(chan struct{}),
	}
	for _, port := range options.AllowPorts {
		m.allowed[port] = true
	}
	m.transport = newPreviewTransport()
	m.proxy = &httputil.ReverseProxy{
		Rewrite:        m.rewrite,
		Transport:      m.transport,
		ModifyResponse: m.modifyResponse,
		ErrorHandler:   m.proxyError,
		ErrorLog:       log.New(io.Discard, "", 0),
	}
	return m
}

// previewCapabilities is the "preview" key of GET /v1/capabilities: the
// preview listener's port and scheme, which clients combine with the host
// name they connected to, and what the preview routes add: "revokeAll"
// (POST /v1/preview/sessions/revoke takes all).
type previewCapabilities struct {
	Port     int      `json:"port"`
	Scheme   string   `json:"scheme"`
	Features []string `json:"features"`
}

// previewCapabilitiesFor describes a preview listener on port. It always
// serves HTTPS, with the API's certificate.
func previewCapabilitiesFor(port int) *previewCapabilities {
	return &previewCapabilities{Port: port, Scheme: "https", Features: []string{"revokeAll"}}
}

// PreviewHandler serves the preview listener (preview_proxy.go). Without
// web previews it answers 404.
func (h *Host) PreviewHandler() http.Handler {
	if h.preview == nil {
		return http.NotFoundHandler()
	}
	return h.preview
}

// StopPreviews ends every preview session, stopping its requests and closing
// its upgraded (WebSocket) connections, which http.Server.Shutdown neither
// closes nor waits for; later preview requests answer 503. It is the preview
// listener's shutdown hook and safe to call more than once.
func (h *Host) StopPreviews() {
	if h.preview != nil {
		h.preview.shutdown()
	}
}

// Routes.

// previewAccess answers 403 preview_disabled when web previews are off.
func (h *Host) previewAccess(w http.ResponseWriter, r *http.Request) (*previewManager, Device, bool) {
	if h.preview == nil {
		writeError(w, 403, "preview_disabled", "Enable web previews explicitly on your AgentLand host")
		return nil, Device{}, false
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return nil, Device{}, false
	}
	return h.preview, device, true
}

func portDiscoveryFailed(w http.ResponseWriter) {
	writeError(w, 503, "port_discovery_failed", "This computer's listening ports could not be read")
}

func (h *Host) previewPorts(w http.ResponseWriter, r *http.Request) {
	m, _, ok := h.previewAccess(w, r)
	if !ok {
		return
	}
	ports, err := m.ports(r.Context())
	if err != nil {
		portDiscoveryFailed(w)
		return
	}
	writeJSON(w, 200, map[string]any{"ports": ports})
}

func (h *Host) createPreviewSession(w http.ResponseWriter, r *http.Request) {
	m, device, ok := h.previewAccess(w, r)
	if !ok {
		return
	}
	var in struct {
		Port int `json:"port"`
	}
	if !decode(w, r, &in) {
		return
	}
	if device.ID == "local-mac" {
		writeError(w, 403, "preview_unavailable", "This Mac opens its own ports directly; web previews are for paired devices")
		return
	}
	// Remote access: the preview listener is not bridged through the tunnel.
	if _, tunnel := tunnelPeerFrom(r.Context()); tunnel {
		writeError(w, 403, "preview_unavailable", "Web previews are not available through remote access")
		return
	}
	if in.Port < 1 || in.Port > 65535 {
		writeError(w, 400, "invalid_request", "Choose a port between 1 and 65535")
		return
	}
	excluded, err := m.excludedPorts()
	if err != nil {
		portDiscoveryFailed(w)
		return
	}
	if excluded[in.Port] {
		writeError(w, 403, "port_not_allowed", "AgentLand does not open this port in web previews")
		return
	}
	ports, err := m.ports(r.Context())
	if err != nil {
		portDiscoveryFailed(w)
		return
	}
	listening := false
	for _, port := range ports {
		listening = listening || port.Port == in.Port
	}
	if !listening {
		writeError(w, 404, "port_not_listening", "Nothing on this computer is listening on that port")
		return
	}
	session, secret, err := m.create(device.ID, in.Port)
	switch {
	case errors.Is(err, errPreviewStopped):
		writeError(w, 503, "host_stopping", "The host is stopping")
		return
	case errors.Is(err, errPreviewSessionLimit):
		writeError(w, 429, "preview_session_limit", "Close a web preview before opening another")
		return
	case err != nil:
		writeError(w, 500, "preview_failed", "The web preview could not be opened")
		return
	}
	writeJSON(w, 201, map[string]any{
		"sessionId":   session.id,
		"previewPort": m.port,
		"cookie": map[string]any{
			"name":          previewCookieName,
			"value":         secret,
			"maxAgeSeconds": int(previewSessionLifetime / time.Second),
		},
	})
}

func (h *Host) listPreviewSessions(w http.ResponseWriter, r *http.Request) {
	m, device, ok := h.previewAccess(w, r)
	if !ok {
		return
	}
	writeJSON(w, 200, map[string]any{"sessions": m.list(device.ID)})
}

// previewRevokedAll answers a revoke of all the caller's sessions.
type previewRevokedAll struct {
	Revoked bool `json:"revoked"`
	// Count is how many live sessions ended.
	Count int `json:"count"`
}

// revokePreviewSession serves POST /v1/preview/sessions/revoke: {sessionId}
// ends one of the caller's sessions; {all: true} ends every one of them,
// such as those an app opened before it restarted.
func (h *Host) revokePreviewSession(w http.ResponseWriter, r *http.Request) {
	m, device, ok := h.previewAccess(w, r)
	if !ok {
		return
	}
	var in struct {
		SessionID string `json:"sessionId"`
		All       bool   `json:"all"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.All {
		if in.SessionID != "" {
			writeError(w, 400, "invalid_request", "Send a preview session ID or all, not both")
			return
		}
		writeJSON(w, 200, previewRevokedAll{Revoked: true, Count: m.revokeAll(device.ID)})
		return
	}
	if in.SessionID == "" || len(in.SessionID) > 64 {
		writeError(w, 400, "invalid_request", "A preview session ID is required")
		return
	}
	if !m.revoke(device.ID, in.SessionID) {
		writeError(w, 404, "preview_session_not_found", "Preview session not found for this device")
		return
	}
	writeJSON(w, 200, map[string]bool{"revoked": true})
}

// Ports.

// ports lists the ports a preview may open now: listening on loopback or
// every address, for this user, and not excluded.
func (m *previewManager) ports(ctx context.Context) ([]PreviewPort, error) {
	found, err := m.scanListeners(ctx)
	if err != nil {
		return nil, err
	}
	excluded, err := m.excludedPorts()
	if err != nil {
		return nil, err
	}
	return filterPreviewPorts(found, excluded, m.pid), nil
}

// excludedPorts are AgentLand's own listeners, the configured OpenCode
// server and the default exclusions the host has not allowed.
func (m *previewManager) excludedPorts() (map[int]bool, error) {
	state, err := m.store.Read()
	if err != nil {
		return nil, err
	}
	excluded := map[int]bool{m.port: true, m.apiPort: true}
	if port := loopbackURLPort(state.Config.OpenCodeURL); port > 0 {
		excluded[port] = true
	}
	for _, port := range previewDefaultExcludedPorts {
		if !m.allowed[port] {
			excluded[port] = true
		}
	}
	return excluded, nil
}

// previewScan is one run of discover that concurrent callers share.
type previewScan struct {
	done  chan struct{}
	found []portListener
	err   error
}

// scanListeners runs at most one discovery at a time. The run has its own
// deadline, so a caller that goes away does not fail the others.
func (m *previewManager) scanListeners(ctx context.Context) ([]portListener, error) {
	m.scanMu.Lock()
	scan := m.scan
	if scan == nil {
		scan = &previewScan{done: make(chan struct{})}
		m.scan = scan
		go func() {
			scanContext, cancel := context.WithTimeout(context.Background(), previewScanTimeout+time.Second)
			scan.found, scan.err = m.discover(scanContext)
			cancel()
			m.scanMu.Lock()
			m.scan = nil
			m.scanMu.Unlock()
			close(scan.done)
		}()
	}
	m.scanMu.Unlock()
	select {
	case <-scan.done:
		return scan.found, scan.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Sessions.

// create stores a new session for deviceID and returns it with its secret,
// 32 random bytes in unpadded base64url.
func (m *previewManager) create(deviceID string, port int) (*previewSession, string, error) {
	var raw [32]byte
	var id [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return nil, "", err
	}
	if _, err := rand.Read(id[:]); err != nil {
		return nil, "", err
	}
	secret := base64.RawURLEncoding.EncodeToString(raw[:])
	now := m.now()
	ctx, cancel := context.WithCancel(context.Background())
	session := &previewSession{id: hex.EncodeToString(id[:]), deviceID: deviceID, port: port, secret: sha256.Sum256([]byte(secret)), created: now, ctx: ctx, cancel: cancel, lastUsed: now, upgraded: map[*previewConn]struct{}{}}
	var closing []*previewConn
	m.mu.Lock()
	err := func() error {
		if m.stopped {
			return errPreviewStopped
		}
		owned := 0
		for _, other := range m.sessions {
			if m.expiredLocked(other, now) {
				closing = append(closing, m.endLocked(other)...)
			} else if other.deviceID == deviceID {
				owned++
			}
		}
		if owned >= previewSessionsPerDevice || len(m.sessions) >= previewSessionsTotal {
			return errPreviewSessionLimit
		}
		m.sessions[session.id] = session
		if !m.sweeping {
			m.sweeping = true
			go m.sweepLoop()
		}
		return nil
	}()
	m.mu.Unlock()
	closePreviewConns(closing)
	if err != nil {
		cancel()
		return nil, "", err
	}
	return session, secret, nil
}

// previewSessionInfo is one entry of GET /v1/preview/sessions; it never
// includes the secret.
type previewSessionInfo struct {
	SessionID  string `json:"sessionId"`
	Port       int    `json:"port"`
	CreatedAt  string `json:"createdAt"`
	LastUsedAt string `json:"lastUsedAt"`
	ExpiresAt  string `json:"expiresAt"`
}

func previewTime(t time.Time) string { return t.UTC().Format(previewTimeLayout) }

func (m *previewManager) list(deviceID string) []previewSessionInfo {
	now := m.now()
	out := []previewSessionInfo{}
	var closing []*previewConn
	m.mu.Lock()
	for _, session := range m.sessions {
		if session.deviceID != deviceID {
			continue
		}
		if m.expiredLocked(session, now) {
			closing = append(closing, m.endLocked(session)...)
			continue
		}
		out = append(out, previewSessionInfo{SessionID: session.id, Port: session.port, CreatedAt: previewTime(session.created), LastUsedAt: previewTime(session.lastUsed), ExpiresAt: previewTime(session.created.Add(previewSessionLifetime))})
	}
	m.mu.Unlock()
	closePreviewConns(closing)
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt < out[j].CreatedAt
		}
		return out[i].SessionID < out[j].SessionID
	})
	return out
}

// revoke ends deviceID's session sessionID.
func (m *previewManager) revoke(deviceID, sessionID string) bool {
	m.mu.Lock()
	session := m.sessions[sessionID]
	if session == nil || session.deviceID != deviceID {
		m.mu.Unlock()
		return false
	}
	closing := m.endLocked(session)
	m.mu.Unlock()
	closePreviewConns(closing)
	return true
}

// revokeAll ends every session of deviceID and reports how many of them
// were live (listed by GET /v1/preview/sessions); expired ones end too.
func (m *previewManager) revokeAll(deviceID string) int {
	now := m.now()
	count := 0
	var closing []*previewConn
	m.mu.Lock()
	for _, session := range m.sessions {
		if session.deviceID != deviceID {
			continue
		}
		if !m.expiredLocked(session, now) {
			count++
		}
		closing = append(closing, m.endLocked(session)...)
	}
	m.mu.Unlock()
	closePreviewConns(closing)
	return count
}

// expiredLocked: 12 hours after creation, or 30 minutes after the last
// request while none is in progress.
func (m *previewManager) expiredLocked(session *previewSession, now time.Time) bool {
	return !now.Before(session.created.Add(previewSessionLifetime)) || (session.inflight == 0 && !now.Before(session.lastUsed.Add(previewIdleTimeout)))
}

// endLocked removes a session and stops its requests. The caller closes the
// returned upgraded connections after unlocking: closing a TLS connection
// may wait to send its close alert.
func (m *previewManager) endLocked(session *previewSession) []*previewConn {
	if session.ended {
		return nil
	}
	session.ended = true
	delete(m.sessions, session.id)
	session.cancel()
	conns := make([]*previewConn, 0, len(session.upgraded))
	for conn := range session.upgraded {
		conns = append(conns, conn)
	}
	return conns
}

// sessionFor finds the live session whose cookie the request carries. The
// SHA-256 of at most four cookie values of that name is compared with every
// session's in constant time.
func (m *previewManager) sessionFor(r *http.Request) *previewSession {
	cookies := r.CookiesNamed(previewCookieName)
	if len(cookies) > 4 {
		cookies = cookies[:4]
	}
	var sums [][sha256.Size]byte
	for _, cookie := range cookies {
		if len(cookie.Value) <= 128 {
			sums = append(sums, sha256.Sum256([]byte(cookie.Value)))
		}
	}
	if len(sums) == 0 {
		return nil
	}
	var found *previewSession
	var closing []*previewConn
	m.mu.Lock()
	for _, session := range m.sessions {
		for i := range sums {
			if subtle.ConstantTimeCompare(sums[i][:], session.secret[:]) == 1 && found == nil {
				found = session
			}
		}
	}
	if found != nil && m.expiredLocked(found, m.now()) {
		closing = m.endLocked(found)
		found = nil
	}
	m.mu.Unlock()
	closePreviewConns(closing)
	return found
}

type previewAdmission int

const (
	previewAdmitted previewAdmission = iota
	previewEnded
	previewBusy
)

// acquire counts a request in progress for the session.
func (m *previewManager) acquire(session *previewSession) previewAdmission {
	m.mu.Lock()
	defer m.mu.Unlock()
	switch {
	case session.ended:
		return previewEnded
	case session.inflight >= m.limits.concurrent:
		return previewBusy
	}
	session.inflight++
	session.lastUsed = m.now()
	return previewAdmitted
}

func (m *previewManager) release(session *previewSession) {
	m.mu.Lock()
	session.inflight--
	session.lastUsed = m.now()
	m.mu.Unlock()
}

func (m *previewManager) sessionEnded(session *previewSession) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return session.ended
}

// previewConn is an upgraded (WebSocket) connection of a session. Ending the
// session or stopping previews closes it.
type previewConn struct {
	net.Conn
	manager *previewManager
	session *previewSession
	once    sync.Once
}

// track registers a hijacked connection with its session; it fails once the
// session has ended.
func (m *previewManager) track(session *previewSession, conn net.Conn) (*previewConn, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if session.ended {
		return nil, false
	}
	tracked := &previewConn{Conn: conn, manager: m, session: session}
	session.upgraded[tracked] = struct{}{}
	return tracked, true
}

func (c *previewConn) Close() error {
	c.once.Do(func() {
		c.manager.mu.Lock()
		delete(c.session.upgraded, c)
		c.manager.mu.Unlock()
	})
	return c.Conn.Close()
}

// closePreviewConns closes connections in parallel; each close is bounded by
// the TLS close alert's own deadline.
func closePreviewConns(conns []*previewConn) {
	var group sync.WaitGroup
	for _, conn := range conns {
		group.Add(1)
		go func() {
			defer group.Done()
			_ = conn.Close()
		}()
	}
	group.Wait()
}

// Devices.

// deviceActive reports whether a device is paired and not revoked, from a
// check at most previewDeviceRecheck old. A failed read of the host state
// fails closed.
func (m *previewManager) deviceActive(id string) bool {
	if active, fresh := m.cachedDevice(id); fresh {
		return active
	}
	m.refreshMu.Lock()
	defer m.refreshMu.Unlock()
	if active, fresh := m.cachedDevice(id); fresh {
		return active
	}
	if m.refreshDevices() != nil {
		return false
	}
	active, _ := m.cachedDevice(id)
	return active
}

// cachedDevice answers from the last check. A device that check did not
// know, such as one paired since, is never fresh.
func (m *previewManager) cachedDevice(id string) (bool, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	active, known := m.devices[id]
	age := m.now().Sub(m.devicesChecked)
	return active, known && !m.devicesChecked.IsZero() && age >= 0 && age < previewDeviceRecheck
}

// refreshDevices reads the paired devices once and ends the sessions of
// devices that were revoked or removed. The caller holds refreshMu.
func (m *previewManager) refreshDevices() error {
	state, err := m.store.Read()
	if err != nil {
		return err
	}
	active := map[string]bool{}
	for _, device := range state.Devices {
		active[device.ID] = device.RevokedAt == nil
	}
	var closing []*previewConn
	m.mu.Lock()
	m.devices, m.devicesChecked = active, m.now()
	for _, session := range m.sessions {
		if !active[session.deviceID] {
			closing = append(closing, m.endLocked(session)...)
		}
	}
	m.mu.Unlock()
	closePreviewConns(closing)
	return nil
}

// Sweeping and shutdown.

// sweepLoop runs while sessions exist; create starts it.
func (m *previewManager) sweepLoop() {
	ticker := time.NewTicker(m.limits.sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-m.stop:
		case <-ticker.C:
			m.sweep()
		}
		m.mu.Lock()
		if m.stopped || len(m.sessions) == 0 {
			m.sweeping = false
			m.mu.Unlock()
			return
		}
		m.mu.Unlock()
	}
}

// sweep ends expired sessions and those of revoked devices, which also
// closes their WebSockets without waiting for another request.
func (m *previewManager) sweep() {
	now := m.now()
	var closing []*previewConn
	m.mu.Lock()
	for _, session := range m.sessions {
		if m.expiredLocked(session, now) {
			closing = append(closing, m.endLocked(session)...)
		}
	}
	remaining := len(m.sessions)
	m.mu.Unlock()
	closePreviewConns(closing)
	if remaining > 0 {
		m.refreshMu.Lock()
		_ = m.refreshDevices()
		m.refreshMu.Unlock()
	}
}

func (m *previewManager) shutdown() {
	m.mu.Lock()
	if m.stopped {
		m.mu.Unlock()
		return
	}
	m.stopped = true
	close(m.stop)
	var closing []*previewConn
	for _, session := range m.sessions {
		closing = append(closing, m.endLocked(session)...)
	}
	m.mu.Unlock()
	closePreviewConns(closing)
	m.transport.CloseIdleConnections()
}

func (m *previewManager) isStopped() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stopped
}
