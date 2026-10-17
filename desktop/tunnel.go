package host

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// The tunnel socket (docs/HOST-API.md, "The tunnel socket"): serve
// --tunnel-socket serves the API on a Unix domain socket that only this
// user's processes reach. The Mac app bridges each iroh stream of a paired
// device to one connection, which starts with a fixed preamble naming the
// node ID iroh verified; the phone's TLS follows unchanged. Requests through
// it are never this Mac's own (authenticate), are bound to the device whose
// node ID the preamble names, and cannot pair or register (serveHTTP).

const (
	tunnelPreambleVersion = "agentland-tunnel/1"
	// tunnelPreambleLength: the version, a space, 64 hex characters, a line feed.
	tunnelPreambleLength = len(tunnelPreambleVersion) + 1 + 64 + 1
	tunnelPreambleWait   = 5 * time.Second
	// Limits: connections open at once per device and in all (those still
	// sending their preamble count), and connections a device opens a minute.
	tunnelPeerOpenLimit   = 16
	tunnelPeerMinuteLimit = 60
	tunnelOpenLimit       = 128
	// maxTunnelSocketPath fits sun_path on macOS (104 bytes with its NUL);
	// the socket is bound first in a private folder whose path is 11 bytes
	// longer than the state folder's.
	maxTunnelSocketPath   = 103
	maxTunnelSocketFolder = maxTunnelSocketPath - len("/.t000000/s")
)

var errTunnelUnsupported = errors.New("the remote access tunnel socket needs macOS or Linux")

// parseTunnelPreamble returns the node ID a preamble names. Anything but the
// exact line, a later version's included, is refused.
func parseTunnelPreamble(line []byte) (string, bool) {
	prefix := tunnelPreambleVersion + " "
	if len(line) != tunnelPreambleLength || line[len(line)-1] != '\n' || string(line[:len(prefix)]) != prefix {
		return "", false
	}
	nodeID := string(line[len(prefix) : len(line)-1])
	if !validNodeID(nodeID) {
		return "", false
	}
	return nodeID, true
}

// ValidateTunnelSocket checks --tunnel-socket: an absolute, clean path
// directly in the state file's folder, short enough for a Unix socket.
func ValidateTunnelSocket(statePath, socketPath string) error {
	if !tunnelSocketSupported() {
		return errTunnelUnsupported
	}
	if !filepath.IsAbs(socketPath) || filepath.Clean(socketPath) != socketPath {
		return errors.New("--tunnel-socket must be an absolute path")
	}
	state, err := filepath.Abs(statePath)
	if err != nil {
		return err
	}
	if filepath.Dir(socketPath) != filepath.Dir(state) || socketPath == state {
		return errors.New("--tunnel-socket must name a file directly in the state file's folder")
	}
	if len(socketPath) > maxTunnelSocketPath || len(filepath.Dir(socketPath)) > maxTunnelSocketFolder {
		return errors.New("--tunnel-socket is too long for a Unix socket (at most 103 bytes, its folder at most 92)")
	}
	return nil
}

// TunnelListen is the tunnel socket of serve --tunnel-socket, made by
// Host.TunnelListen so its connections follow the host's devices.
type TunnelListen struct {
	Path string
	host *Host
}

// TunnelListen returns the tunnel socket listener options for path. The host
// must run with remote access (HostOptions.RemoteAccess and the local session).
func (h *Host) TunnelListen(path string) *TunnelListen { return &TunnelListen{Path: path, host: h} }

// tunnelSocket is the bound socket (tunnel_socket_unix.go).
type tunnelSocket struct {
	listener net.Listener
	path     string
	info     os.FileInfo
	// checkPeer refuses connections from another user's processes.
	checkPeer func(net.Conn) error
}

// remove deletes the socket file if it is still this socket's.
func (s *tunnelSocket) remove() {
	if s.info == nil {
		return
	}
	if info, err := os.Lstat(s.path); err == nil && os.SameFile(info, s.info) {
		_ = os.Remove(s.path)
	}
}

// tunnelPeer is who a tunnel connection belongs to: the node ID the preamble
// named and the device that had it when the connection was admitted.
type tunnelPeer struct{ nodeID, deviceID string }

type tunnelPeerKey struct{}

// tunnelPeerFrom reports the tunnel peer of a request through the tunnel.
func tunnelPeerFrom(ctx context.Context) (tunnelPeer, bool) {
	peer, ok := ctx.Value(tunnelPeerKey{}).(tunnelPeer)
	return peer, ok
}

func shortNodeID(nodeID string) string {
	if len(nodeID) > 8 {
		return nodeID[:8]
	}
	return nodeID
}

// tunnelConns counts the tunnel connections and holds the admitted ones, so
// the limits apply per device and a device's connections close when its node
// ID is no longer its own.
type tunnelConns struct {
	mu                                        sync.Mutex
	open                                      int
	byNode                                    map[string]map[*tunnelConn]struct{}
	opened                                    map[string][]time.Time
	openLimit, peerOpenLimit, peerMinuteLimit int
	now                                       func() time.Time
}

func newTunnelConns() *tunnelConns {
	return &tunnelConns{byNode: map[string]map[*tunnelConn]struct{}{}, opened: map[string][]time.Time{},
		openLimit: tunnelOpenLimit, peerOpenLimit: tunnelPeerOpenLimit, peerMinuteLimit: tunnelPeerMinuteLimit, now: time.Now}
}

// reserve takes one of the open places for a connection that has just been
// accepted; unreserve gives it back when the connection is refused.
func (c *tunnelConns) reserve() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.open >= c.openLimit {
		return false
	}
	c.open++
	return true
}

func (c *tunnelConns) unreserve() {
	c.mu.Lock()
	c.open--
	c.mu.Unlock()
}

// admit registers a connection with a reserved place for peer, or refuses it
// (and gives the place back) with the reason.
func (c *tunnelConns) admit(raw net.Conn, peer tunnelPeer) (*tunnelConn, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	recent := c.opened[peer.nodeID][:0]
	for _, at := range c.opened[peer.nodeID] {
		if now.Sub(at) < time.Minute {
			recent = append(recent, at)
		}
	}
	c.opened[peer.nodeID] = recent
	reason := ""
	switch {
	case len(c.byNode[peer.nodeID]) >= c.peerOpenLimit:
		reason = "too many open connections"
	case len(recent) >= c.peerMinuteLimit:
		reason = "too many connections in the last minute"
	}
	if reason != "" {
		c.open--
		if len(recent) == 0 {
			delete(c.opened, peer.nodeID)
		}
		return nil, reason
	}
	c.opened[peer.nodeID] = append(recent, now)
	conn := &tunnelConn{Conn: raw, peer: peer, conns: c}
	if c.byNode[peer.nodeID] == nil {
		c.byNode[peer.nodeID] = map[*tunnelConn]struct{}{}
	}
	c.byNode[peer.nodeID][conn] = struct{}{}
	return conn, ""
}

func (c *tunnelConns) release(conn *tunnelConn) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if set := c.byNode[conn.peer.nodeID]; set != nil {
		if _, held := set[conn]; held {
			delete(set, conn)
			c.open--
			if len(set) == 0 {
				delete(c.byNode, conn.peer.nodeID)
			}
		}
	}
}

// closeStale closes the connections whose node ID is no longer the device's
// they were admitted for (current maps node IDs to device IDs).
func (c *tunnelConns) closeStale(current map[string]string) {
	for _, conn := range c.matching(func(conn *tunnelConn) bool { return current[conn.peer.nodeID] != conn.peer.deviceID }) {
		log.Printf("remote access: closed a tunnel connection of device %s (node %s): the device was revoked or its node ID changed", conn.peer.deviceID, shortNodeID(conn.peer.nodeID))
		conn.Close()
	}
}

// closeDevice closes the connections admitted for deviceID: it paired again,
// so the token they carried no longer works (docs/HOST-API.md, "Pairing
// again").
func (c *tunnelConns) closeDevice(deviceID string) {
	for _, conn := range c.matching(func(conn *tunnelConn) bool { return conn.peer.deviceID == deviceID }) {
		log.Printf("remote access: closed a tunnel connection of device %s (node %s): the device paired again", conn.peer.deviceID, shortNodeID(conn.peer.nodeID))
		conn.Close()
	}
}

// closeAll closes every admitted connection (the host is closing).
func (c *tunnelConns) closeAll() {
	for _, conn := range c.matching(func(*tunnelConn) bool { return true }) {
		conn.Close()
	}
}

func (c *tunnelConns) matching(match func(*tunnelConn) bool) []*tunnelConn {
	var found []*tunnelConn
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, set := range c.byNode {
		for conn := range set {
			if match(conn) {
				found = append(found, conn)
			}
		}
	}
	return found
}

// count reports the open connections, for tests.
func (c *tunnelConns) count() (open int, admitted int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, set := range c.byNode {
		admitted += len(set)
	}
	return c.open, admitted
}

// tunnelConn is an admitted tunnel connection. Its remote address is not an
// IP address and not host:port, so nothing can take it for loopback.
type tunnelConn struct {
	net.Conn
	peer  tunnelPeer
	conns *tunnelConns
	once  sync.Once
}

func (c *tunnelConn) Close() error {
	c.once.Do(func() { c.conns.release(c) })
	return c.Conn.Close()
}

// RemoteAddr is "iroh/" and the node ID's first 8 characters: net/http logs
// it on its own (a failed TLS handshake), and standard error never carries a
// whole node ID. Requests find their peer in their context, not here.
func (c *tunnelConn) RemoteAddr() net.Addr { return tunnelAddr(shortNodeID(c.peer.nodeID)) }

type tunnelAddr string

func (a tunnelAddr) Network() string { return "iroh" }
func (a tunnelAddr) String() string  { return "iroh/" + string(a) }

// tunnelListener accepts from the socket, reads each preamble on its own
// goroutine and hands the HTTP server only admitted connections.
type tunnelListener struct {
	socket       *tunnelSocket
	host         *Host
	conns        *tunnelConns
	preambleWait time.Duration

	ready     chan *tunnelConn
	failed    chan error
	done      chan struct{}
	closeOnce sync.Once
	pendingMu sync.Mutex
	pending   map[net.Conn]struct{}
}

func newTunnelListener(socket *tunnelSocket, h *Host) *tunnelListener {
	l := &tunnelListener{socket: socket, host: h, conns: h.remote.tunnel, preambleWait: tunnelPreambleWait,
		ready: make(chan *tunnelConn), failed: make(chan error, 1), done: make(chan struct{}), pending: map[net.Conn]struct{}{}}
	go l.acceptLoop()
	return l
}

func (l *tunnelListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.ready:
		return conn, nil
	case err := <-l.failed:
		return nil, err
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *tunnelListener) Addr() net.Addr { return l.socket.listener.Addr() }

// Close stops accepting, removes the socket file and closes the connections
// still sending their preamble; admitted ones belong to the HTTP server.
func (l *tunnelListener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.done)
		err = l.socket.listener.Close()
		l.socket.remove()
		l.pendingMu.Lock()
		for conn := range l.pending {
			conn.Close()
		}
		l.pendingMu.Unlock()
	})
	return err
}

func (l *tunnelListener) closed() bool {
	select {
	case <-l.done:
		return true
	default:
		return false
	}
}

func (l *tunnelListener) acceptLoop() {
	backoff := 5 * time.Millisecond
	for {
		raw, err := l.socket.listener.Accept()
		if err != nil {
			if l.closed() {
				return
			}
			if errors.Is(err, net.ErrClosed) {
				l.failed <- err
				return
			}
			// Out of descriptors and the like: wait and accept again.
			time.Sleep(backoff)
			backoff = min(2*backoff, time.Second)
			continue
		}
		backoff = 5 * time.Millisecond
		if !l.conns.reserve() {
			log.Printf("remote access: refused a tunnel connection: %d are open", tunnelOpenLimit)
			raw.Close()
			continue
		}
		go l.handshake(raw)
	}
}

// handshake checks the connecting process's user and the preamble, then
// admits the connection for its device or closes it without a word.
func (l *tunnelListener) handshake(raw net.Conn) {
	refuse := func(reason, nodeID string) {
		if nodeID != "" {
			log.Printf("remote access: refused a tunnel connection from node %s: %s", shortNodeID(nodeID), reason)
		} else {
			log.Printf("remote access: refused a tunnel connection: %s", reason)
		}
		raw.Close()
	}
	if err := l.socket.checkPeer(raw); err != nil {
		l.conns.unreserve()
		refuse("it does not come from this user's processes", "")
		return
	}
	if !l.track(raw) {
		l.conns.unreserve()
		raw.Close()
		return
	}
	defer l.untrack(raw)
	line := make([]byte, tunnelPreambleLength)
	_ = raw.SetReadDeadline(time.Now().Add(l.preambleWait))
	_, err := io.ReadFull(raw, line)
	nodeID, ok := "", false
	if err == nil {
		nodeID, ok = parseTunnelPreamble(line)
	}
	if !ok {
		l.conns.unreserve()
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() {
			refuse("no preamble within 5 s", "")
		} else {
			refuse("not a tunnel preamble", "")
		}
		return
	}
	select {
	case <-l.host.stopping:
		l.conns.unreserve()
		refuse("the host is stopping", nodeID)
		return
	default:
	}
	device, found := l.host.deviceForNode(nodeID)
	if !found {
		l.conns.unreserve()
		refuse("no paired device has this node ID", nodeID)
		return
	}
	conn, reason := l.conns.admit(raw, tunnelPeer{nodeID: nodeID, deviceID: device.ID})
	if conn == nil {
		refuse(reason, nodeID)
		return
	}
	_ = raw.SetReadDeadline(time.Time{})
	select {
	case l.ready <- conn:
		log.Printf("remote access: tunnel connection of device %s (node %s)", device.ID, shortNodeID(nodeID))
	case <-l.done:
		conn.Close()
	}
}

// track records a connection still sending its preamble, so Close ends it;
// false once the listener is closed.
func (l *tunnelListener) track(conn net.Conn) bool {
	l.pendingMu.Lock()
	defer l.pendingMu.Unlock()
	if l.closed() {
		return false
	}
	l.pending[conn] = struct{}{}
	return true
}

func (l *tunnelListener) untrack(conn net.Conn) {
	l.pendingMu.Lock()
	delete(l.pending, conn)
	l.pendingMu.Unlock()
}

// tunnelConnContext gives every request of a tunnel connection its peer.
func tunnelConnContext(ctx context.Context, c net.Conn) context.Context {
	if secure, ok := c.(*tls.Conn); ok {
		c = secure.NetConn()
	}
	if conn, ok := c.(*tunnelConn); ok {
		return context.WithValue(ctx, tunnelPeerKey{}, conn.peer)
	}
	return ctx
}

// requireTunnelPeer is the tunnel server's handler: a request without a
// tunnel peer never reaches the API from the socket (it fails closed).
func requireTunnelPeer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := tunnelPeerFrom(r.Context()); !ok {
			w.Header().Set("Content-Type", "application/json")
			writeError(w, 403, "tunnel_refused", "This connection did not come through the tunnel")
			return
		}
		next.ServeHTTP(w, r)
	})
}
