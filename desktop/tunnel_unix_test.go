//go:build darwin || linux

package host

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// The tunnel socket end to end (docs/HOST-API.md, "The tunnel socket"): the
// API over a real Unix socket with TLS, the preamble, refusals, revocation and
// the socket file's life.

// shortStateFolder is a state folder whose socket path fits sun_path.
func shortStateFolder(t *testing.T) string {
	t.Helper()
	base := ""
	if len(os.TempDir()) > 60 {
		base = "/tmp"
	}
	folder, err := os.MkdirTemp(base, "al-tun")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	return folder
}

// tunnelFixture is a remote-access host serving TCP and the tunnel socket.
type tunnelFixture struct {
	host    *Host
	store   *Store
	socket  string
	pool    *x509.CertPool
	address string
	cancel  context.CancelFunc
	served  chan error
}

func newTunnelFixture(t *testing.T) *tunnelFixture {
	t.Helper()
	folder := shortStateFolder(t)
	if err := os.Chmod(folder, 0700); err != nil {
		t.Fatal(err)
	}
	store := NewStore(filepath.Join(folder, "host.json"))
	project := t.TempDir()
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: project}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	agent := &fakeAgent{sessions: map[string]Session{}}
	h := NewWithOptions(store, agent, HostOptions{LocalSessionToken: testLocalSession, RemoteAccess: true})
	certificateFile, keyFile, pool := testCertificate(t)
	f := &tunnelFixture{host: h, store: store, socket: filepath.Join(folder, "tunnel.sock"), pool: pool, address: freeLoopbackAddress(t), served: make(chan error, 1)}
	if err := ValidateTunnelSocket(store.Path, f.socket); err != nil {
		t.Fatal(err)
	}
	var ctx context.Context
	ctx, f.cancel = context.WithCancel(context.Background())
	go func() {
		f.served <- ServeContext(ctx, h.Handler(), ListenOptions{Address: f.address, CertificateFile: certificateFile, KeyFile: keyFile,
			OnShutdown: h.BeginShutdown, Tunnel: h.TunnelListen(f.socket)})
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if conn, err := net.Dial("unix", f.socket); err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the tunnel socket did not open")
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		f.stop(t)
		h.Close()
	})
	return f
}

func (f *tunnelFixture) stop(t *testing.T) {
	t.Helper()
	if f.cancel == nil {
		return
	}
	f.cancel()
	f.cancel = nil
	select {
	case err := <-f.served:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Errorf("ServeContext: %v", err)
		}
	case <-time.After(12 * time.Second):
		t.Error("the host did not stop")
	}
}

// client speaks HTTPS through the tunnel socket as the Mac app's bridge
// would carry a phone's connection: the preamble, then TLS for 127.0.0.1.
func (f *tunnelFixture) client(preamble string) *http.Client {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, "unix", f.socket)
			if err != nil {
				return nil, err
			}
			if _, err := io.WriteString(conn, preamble); err != nil {
				conn.Close()
				return nil, err
			}
			return conn, nil
		},
		TLSClientConfig:   &tls.Config{RootCAs: f.pool, ServerName: "127.0.0.1"},
		ForceAttemptHTTP2: true,
	}
	return &http.Client{Transport: transport, Timeout: 10 * time.Second}
}

func preambleFor(nodeID string) string { return "agentland-tunnel/1 " + nodeID + "\n" }

func call(t *testing.T, client *http.Client, method, path, token string, body string) (int, string) {
	t.Helper()
	request, err := http.NewRequest(method, "https://127.0.0.1"+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer response.Body.Close()
	data, _ := io.ReadAll(response.Body)
	var envelope struct {
		Error struct{ Code string } `json:"error"`
	}
	json.Unmarshal(data, &envelope)
	return response.StatusCode, envelope.Error.Code
}

// closedWithoutAWord reports whether the host closed conn without writing.
// Linux sends RST when a socket closes with unread data, so a refusal that
// never reads what the client sent ends as ECONNRESET there; both endings are
// "without a word" as long as no byte arrived.
func closedWithoutAWord(t *testing.T, conn net.Conn, within time.Duration) bool {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(within))
	n, err := conn.Read(make([]byte, 16))
	if ok := n == 0 && (errors.Is(err, io.EOF) || errors.Is(err, syscall.ECONNRESET)); !ok {
		t.Logf("connection ending: read n=%d err=%v", n, err)
		return false
	}
	return true
}

func TestTunnelSocketServesTheAPIAndIsNeverLocal(t *testing.T) {
	f := newTunnelFixture(t)
	info, err := os.Lstat(f.socket)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Type() != os.ModeSocket || info.Mode().Perm() != 0600 || int(info.Sys().(*syscall.Stat_t).Uid) != os.Getuid() {
		t.Fatalf("socket mode %v", info.Mode())
	}
	if leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(f.socket), ".t*")); len(leftovers) != 0 {
		t.Fatalf("the private bind folder was left: %v", leftovers)
	}
	key, otherKey := newNodeKey(t), newNodeKey(t)
	token, _ := pairWithNode(t, f.host, f.store, "Phone", &key)
	otherToken, _ := pairWithNode(t, f.host, f.store, "iPad", &otherKey)
	client := f.client(preambleFor(key.id))
	defer client.CloseIdleConnections()

	for _, tc := range []struct {
		method, path, token, body string
		status                    int
		code                      string
	}{
		{"GET", "/v1/health", "", "", 200, ""},
		{"GET", "/v1/projects", token, "", 200, ""},
		{"GET", "/v1/projects", testLocalSession, "", 401, "unauthorized"},
		{"GET", "/v1/remote-access/peers", testLocalSession, "", 401, "unauthorized"},
		{"GET", "/v1/remote-access/peers", token, "", 403, "local_only"},
		{"GET", "/v1/projects", otherToken, "", 403, "tunnel_device_mismatch"},
		{"POST", "/v1/pair", "", `{"code":"0000000000","deviceName":"Stranger"}`, 403, "tunnel_refused"},
		{"POST", "/v1/remote-access/device", token, `{"nodeId":"` + key.id + `","proof":"` + strings.Repeat("0", 128) + `"}`, 403, "tunnel_refused"},
		{"GET", "/v1/projects", "", "", 401, "unauthorized"},
	} {
		if status, code := call(t, client, tc.method, tc.path, tc.token, tc.body); status != tc.status || code != tc.code {
			t.Errorf("%s %s with %q: %d %s, want %d %s", tc.method, tc.path, tc.token, status, code, tc.status, tc.code)
		}
	}
	// The TCP listener still serves this Mac's session over loopback.
	tcp := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: f.pool}}, Timeout: 10 * time.Second}
	defer tcp.CloseIdleConnections()
	request, _ := http.NewRequest("GET", "https://"+f.address+"/v1/remote-access/peers", nil)
	request.Header.Set("Authorization", "Bearer "+testLocalSession)
	response, err := tcp.Do(request)
	if err != nil || response.StatusCode != 200 {
		t.Fatalf("the Mac over TCP: %v %v", response, err)
	}
	response.Body.Close()

	// Shutting down removes the socket.
	f.stop(t)
	if _, err := os.Lstat(f.socket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the socket is still there after the host stopped: %v", err)
	}
}

func TestTunnelRefusesBadPreamblesAndUnknownNodes(t *testing.T) {
	f := newTunnelFixture(t)
	key := newNodeKey(t)
	pairWithNode(t, f.host, f.store, "Phone", &key)
	stranger := newNodeKey(t)
	for name, preamble := range map[string]string{
		"an unknown node ID": preambleFor(stranger.id),
		"a later version":    "agentland-tunnel/2 " + key.id + "\n",
		"upper case":         "agentland-tunnel/1 " + strings.ToUpper(key.id) + "\n",
		"TLS at once":        "\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" + strings.Repeat("\x00", 73),
	} {
		conn, err := net.Dial("unix", f.socket)
		if err != nil {
			t.Fatal(err)
		}
		io.WriteString(conn, preamble)
		if !closedWithoutAWord(t, conn, 3*time.Second) {
			t.Errorf("%s: the connection was not closed without a word", name)
		}
		conn.Close()
	}
	// A short preamble is closed at the 5 s deadline, not left open.
	conn, err := net.Dial("unix", f.socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "agentland-tunnel/1 ")
	began := time.Now()
	if !closedWithoutAWord(t, conn, 8*time.Second) {
		t.Fatal("a short preamble was not closed")
	}
	if elapsed := time.Since(began); elapsed < 4*time.Second || elapsed > 7*time.Second {
		t.Fatalf("a short preamble was closed after %v, want about 5 s", elapsed)
	}
	// The paired device still gets in.
	client := f.client(preambleFor(key.id))
	defer client.CloseIdleConnections()
	if status, _ := call(t, client, "GET", "/v1/health", "", ""); status != 200 {
		t.Fatalf("the paired device: %d", status)
	}
	if open, admitted := f.host.remote.tunnel.count(); open != admitted {
		t.Fatalf("refused connections still hold places: open %d admitted %d", open, admitted)
	}
}

func TestTunnelClosesARevokedDevicesConnections(t *testing.T) {
	f := newTunnelFixture(t)
	key := newNodeKey(t)
	token, id := pairWithNode(t, f.host, f.store, "Phone", &key)
	client := f.client(preambleFor(key.id))
	defer client.CloseIdleConnections()
	request, _ := http.NewRequest("GET", "https://127.0.0.1/v1/pulse", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := client.Do(request)
	if err != nil || response.StatusCode != 200 {
		t.Fatalf("pulse: %v %v", response, err)
	}
	defer response.Body.Close()
	lines := bufio.NewReader(response.Body)
	if line, err := lines.ReadString('\n'); err != nil || !strings.Contains(line, "ready") {
		t.Fatalf("pulse: %q %v", line, err)
	}
	// Another process revokes the device (the revoke command).
	if err := NewStore(f.store.Path).RevokeDevice(id); err != nil {
		t.Fatal(err)
	}
	revoked := time.Now()
	ended := make(chan error, 1)
	go func() {
		for {
			if _, err := lines.ReadString('\n'); err != nil {
				ended <- err
				return
			}
		}
	}()
	select {
	case <-ended:
		if elapsed := time.Since(revoked); elapsed > time.Second {
			t.Fatalf("the connection ended %v after the revocation", elapsed)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the revoked device's tunnel connection stayed open")
	}
	// Its node ID is refused from now on.
	conn, err := net.Dial("unix", f.socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, preambleFor(key.id))
	if !closedWithoutAWord(t, conn, 3*time.Second) {
		t.Fatal("a revoked device's node ID was admitted")
	}
}

// Pairing again (owner, 2026-10-17) closes the replaced record's tunnel
// connections, as a revocation does; the new token gets in.
func TestTunnelClosesTheConnectionsOfADeviceThatPairsAgain(t *testing.T) {
	f := newTunnelFixture(t)
	key := newNodeKey(t)
	token, id := pairWithNode(t, f.host, f.store, "Phone", &key)
	client := f.client(preambleFor(key.id))
	defer client.CloseIdleConnections()
	request, _ := http.NewRequest("GET", "https://127.0.0.1/v1/pulse", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := client.Do(request)
	if err != nil || response.StatusCode != 200 {
		t.Fatalf("pulse: %v %v", response, err)
	}
	defer response.Body.Close()
	lines := bufio.NewReader(response.Body)
	if line, err := lines.ReadString('\n'); err != nil || !strings.Contains(line, "ready") {
		t.Fatalf("pulse: %q %v", line, err)
	}
	newToken, again := pairAgain(t, f.host, f.store, "Phone", token, &key)
	if again != id {
		t.Fatalf("paired again as %s, want %s", again, id)
	}
	paired := time.Now()
	ended := make(chan error, 1)
	go func() {
		for {
			if _, err := lines.ReadString('\n'); err != nil {
				ended <- err
				return
			}
		}
	}()
	select {
	case <-ended:
		if elapsed := time.Since(paired); elapsed > time.Second {
			t.Fatalf("the connection ended %v after pairing again", elapsed)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the replaced token's tunnel connection stayed open")
	}
	fresh := f.client(preambleFor(key.id))
	defer fresh.CloseIdleConnections()
	if status, _ := call(t, fresh, "GET", "/v1/projects", newToken, ""); status != 200 {
		t.Fatalf("the new token through the tunnel: %d", status)
	}
	if status, _ := call(t, fresh, "GET", "/v1/projects", token, ""); status != 401 {
		t.Fatalf("the old token through the tunnel: %d", status)
	}
}

func TestTunnelRefusesAnotherUsersProcesses(t *testing.T) {
	folder := shortStateFolder(t)
	h, store := remoteHost(t)
	key := newNodeKey(t)
	pairWithNode(t, h, store, "Phone", &key)
	socket, err := listenTunnelSocket(filepath.Join(folder, "tunnel.sock"))
	if err != nil {
		t.Fatal(err)
	}
	checked := make(chan struct{}, 1)
	socket.checkPeer = func(conn net.Conn) error {
		if err := sameUserPeer(conn); err != nil {
			t.Errorf("this user's own process was refused: %v", err)
		}
		checked <- struct{}{}
		return errors.New("another user")
	}
	listener := newTunnelListener(socket, h)
	defer listener.Close()
	conn, err := net.Dial("unix", socket.path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, preambleFor(key.id))
	<-checked
	if !closedWithoutAWord(t, conn, 3*time.Second) {
		t.Fatal("a connection from another user was not closed")
	}
}

func TestTunnelSocketFile(t *testing.T) {
	folder := shortStateFolder(t)
	path := filepath.Join(folder, "tunnel.sock")
	// A socket left by a host that crashed is replaced.
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	socket, err := listenTunnelSocket(path)
	if err != nil {
		t.Fatalf("a stale socket was not replaced: %v", err)
	}
	// A live one is not.
	if _, err := listenTunnelSocket(path); err == nil || !strings.Contains(err.Error(), "another host") {
		t.Fatalf("a live socket: %v", err)
	}
	socket.listener.Close()
	socket.remove()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the socket file stayed: %v", err)
	}
	// Anything else at the path fails the start and is left alone.
	if err := os.WriteFile(path, []byte("state"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := listenTunnelSocket(path); err == nil || !strings.Contains(err.Error(), "not a socket") {
		t.Fatalf("a regular file: %v", err)
	}
	if data, _ := os.ReadFile(path); string(data) != "state" {
		t.Fatal("the file at the path was changed")
	}
	os.Remove(path)
	// A host removes only its own socket file.
	socket, err = listenTunnelSocket(path)
	if err != nil {
		t.Fatal(err)
	}
	socket.listener.Close()
	os.Remove(path)
	if err := os.WriteFile(path, []byte("another"), 0600); err != nil {
		t.Fatal(err)
	}
	socket.remove()
	if data, _ := os.ReadFile(path); string(data) != "another" {
		t.Fatal("a host removed a file that was not its socket")
	}
}

// syncBuffer collects the standard logger's lines while a test runs.
type syncBuffer struct {
	mu   sync.Mutex
	data strings.Builder
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.String()
}

func captureLog(t *testing.T) *syncBuffer {
	t.Helper()
	buffer := &syncBuffer{}
	log.SetOutput(io.MultiWriter(os.Stderr, buffer))
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return buffer
}

// Standard error names a tunnel connection by its device and the first 8
// characters of its node ID only, net/http's own lines included: a TLS
// handshake that fails through the bridge is logged with the connection's
// remote address.
func TestTunnelLogsNeverCarryAWholeNodeID(t *testing.T) {
	logged := captureLog(t)
	f := newTunnelFixture(t)
	key := newNodeKey(t)
	pairWithNode(t, f.host, f.store, "Phone", &key)
	conn, err := net.Dial("unix", f.socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	// The preamble, then a ClientHello whose handshake message claims more
	// bytes than TLS allows.
	io.WriteString(conn, preambleFor(key.id)+"\x16\x03\x01\x00\x08\x01\xff\xff\xff\x03\x03\x00\x00")
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(logged.String(), "TLS handshake error") {
		if time.Now().After(deadline) {
			t.Fatalf("no handshake error was logged:\n%s", logged)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(logged.String(), "iroh/"+key.id[:8]) {
		t.Errorf("the handshake error does not name the node's first 8 characters:\n%s", logged)
	}
	if strings.Contains(logged.String(), key.id) || strings.Contains(logged.String(), key.id[:9]) {
		t.Fatalf("standard error carries more of the node ID than its first 8 characters:\n%s", logged)
	}
}
