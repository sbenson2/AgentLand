package host

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Remote access (docs/HOST-API.md, "Remote access (iroh)"): node IDs at
// pairing and registration, the Mac app's peer list and endpoint report,
// capabilities, and requests that come through the tunnel.

const testLocalSession = "local-session-secret"

type nodeKey struct {
	private ed25519.PrivateKey
	id      string
}

func newNodeKey(t *testing.T) nodeKey {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return nodeKey{private: private, id: hex.EncodeToString(public)}
}

func (k nodeKey) proof(purpose, binding string) string {
	return hex.EncodeToString(ed25519.Sign(k.private, nodeProofMessage(purpose, binding, k.id)))
}

// remoteHost is a host with remote access and the Mac's local session.
func remoteHost(t *testing.T) (*Host, *Store) {
	t.Helper()
	_, store, agent := testHost(t)
	h := NewWithOptions(store, agent, HostOptions{LocalSessionToken: testLocalSession, RemoteAccess: true})
	t.Cleanup(func() { h.Close() })
	return h, store
}

// macRequest is the Mac app's own request over loopback.
func macRequest(t *testing.T, h *Host, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return requestFrom(t, h, method, path, testLocalSession, body, nil)
}

// requestFrom sends a request from loopback, or through the tunnel as peer.
func requestFrom(t *testing.T, h *Host, method, path, token string, body any, peer *tunnelPeer) *httptest.ResponseRecorder {
	t.Helper()
	var reader *strings.Reader
	switch value := body.(type) {
	case nil:
		reader = strings.NewReader("")
	case string:
		reader = strings.NewReader(value)
	default:
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		reader = strings.NewReader(string(data))
	}
	r := httptest.NewRequest(method, path, reader)
	r.RemoteAddr = "127.0.0.1:50000"
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if peer != nil {
		// The worst case: a tunnel request that looks like loopback. The
		// socket's own connections have a remote address that is no IP.
		r = r.WithContext(context.WithValue(r.Context(), tunnelPeerKey{}, *peer))
	}
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	return w
}

// pairWithNode pairs a device, with a node ID and its proof when key is set.
func pairWithNode(t *testing.T, h *Host, store *Store, name string, key *nodeKey) (token, deviceID string) {
	t.Helper()
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"code": code, "deviceName": name}
	if key != nil {
		body["irohNodeId"], body["irohNodeProof"] = key.id, key.proof("pair", code)
	}
	w := request(t, h.Handler(), "POST", "/v1/pair", "", body)
	if w.Code != 200 {
		t.Fatalf("pair: %d %s", w.Code, w.Body.String())
	}
	var out struct {
		Token    string `json:"token"`
		DeviceID string `json:"deviceId"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out.Token, out.DeviceID
}

func deviceNode(t *testing.T, store *Store, id string) string {
	t.Helper()
	st, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	for _, device := range st.Devices {
		if device.ID == id {
			return device.IrohNodeID
		}
	}
	t.Fatalf("no device %s", id)
	return ""
}

type peersAnswer struct {
	Version string       `json:"version"`
	Peers   []remotePeer `json:"peers"`
}

func readPeers(t *testing.T, w *httptest.ResponseRecorder) peersAnswer {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("peers: %d %s", w.Code, w.Body.String())
	}
	var out peersAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestNodeProofMessageAndVerification(t *testing.T) {
	key := newNodeKey(t)
	if got := string(nodeProofMessage("register", "9c1e44d0a7b2c35f8e016d42", key.id)); got != "agentland-iroh-node/1\nregister\n9c1e44d0a7b2c35f8e016d42\n"+key.id {
		t.Fatalf("message = %q", got)
	}
	proof := key.proof("register", "device-1")
	if !validNodeID(key.id) || !validNodeProof(proof) || !verifyNodeProof("register", "device-1", key.id, proof) {
		t.Fatal("a proof made with the key does not verify")
	}
	other := newNodeKey(t)
	for name, ok := range map[string]bool{
		"another purpose":    verifyNodeProof("pair", "device-1", key.id, proof),
		"another binding":    verifyNodeProof("register", "device-2", key.id, proof),
		"another node ID":    verifyNodeProof("register", "device-1", other.id, proof),
		"another key's sign": verifyNodeProof("register", "device-1", key.id, other.proof("register", "device-1")),
		"upper case node ID": verifyNodeProof("register", "device-1", strings.ToUpper(key.id), proof),
		"upper case proof":   verifyNodeProof("register", "device-1", key.id, strings.ToUpper(proof)),
	} {
		if ok {
			t.Errorf("%s verified", name)
		}
	}
	for _, bad := range []string{"", key.id[:63], key.id + "0", strings.ToUpper(key.id), strings.Repeat("g", 64), "k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8"} {
		if validNodeID(bad) {
			t.Errorf("node ID %q accepted", bad)
		}
	}
	// A key that no private key backs: the identity point, whose all-zero
	// "signature" (R = identity, S = 0) verifies for every message with
	// crypto/ed25519 alone.
	identity, forged := "01"+strings.Repeat("0", 62), "01"+strings.Repeat("0", 126)
	if verifyNodeProof("register", "device-1", identity, forged) || verifyNodeProof("pair", "0012345678", identity, forged) {
		t.Fatal("a proof for the identity key verified")
	}
}

// Pairing and registering refuse a node ID no device can hold, and a Mac
// endpoint report cannot name one; one kept before this rule is never listed.
func TestWeakNodeKeysAreNeverAdmitted(t *testing.T) {
	h, store := remoteHost(t)
	identity, forged := "01"+strings.Repeat("0", 62), "01"+strings.Repeat("0", 126)
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	w := request(t, h.Handler(), "POST", "/v1/pair", "", map[string]any{"code": code, "deviceName": "Phone", "irohNodeId": identity, "irohNodeProof": forged})
	if w.Code != 400 || errorCode(t, w) != "invalid_node_proof" {
		t.Fatalf("pairing with the identity key: %d %s", w.Code, w.Body.String())
	}
	token, id := pairWithNode(t, h, store, "Phone", nil)
	w = request(t, h.Handler(), "POST", "/v1/remote-access/device", token, map[string]string{"nodeId": identity, "proof": forged})
	if w.Code != 400 || errorCode(t, w) != "invalid_node_proof" {
		t.Fatalf("registering the identity key: %d %s", w.Code, w.Body.String())
	}
	if deviceNode(t, store, id) != "" {
		t.Fatal("a weak key was kept")
	}
	for _, weak := range weakNodeKeys() {
		w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": false, "nodeId": weak})
		if w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Errorf("the Mac reporting %s: %d %s", weak, w.Code, w.Body.String())
		}
	}
	// A weak node ID in the state file (kept before this rule) is not listed.
	if _, err := store.SetDeviceNodeID(id, identity); err != nil {
		t.Fatal(err)
	}
	if peers := readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers", nil)); len(peers.Peers) != 0 {
		t.Fatalf("a weak node ID is listed: %+v", peers)
	}
}

// nonGlobalAddresses are ip:port addresses a Mac may not advertise: not
// global unicast. AgentLandCore's RemoteAccessClientTests refuses the same.
var nonGlobalAddresses = []string{
	"0.0.0.0:38842", "0.1.2.3:38842", // this network
	"10.0.0.5:38842", "172.16.0.1:38842", "172.31.255.255:38842", "192.168.0.5:38842", // private (an inner router's WAN)
	"100.64.0.1:38842", "100.72.3.9:38842", "100.127.255.255:38842", // shared address space: carrier-grade NAT, Tailscale
	"127.0.0.1:38842", "169.254.1.1:38842", // loopback, link-local
	"192.0.0.2:38842",                                            // IETF protocol assignments (DS-Lite)
	"192.0.2.1:38842", "198.51.100.7:38842", "203.0.113.7:38842", // documentation
	"198.18.0.1:38842", "198.19.255.255:38842", // benchmarking
	"224.0.0.1:38842", "240.0.0.1:38842", "255.255.255.255:38842", // multicast, reserved, broadcast
	"[::]:38842", "[::1]:38842", "[::1.2.3.4]:38842", "[::ffff:192.168.0.5]:38842", "[64:ff9b::102:304]:38842", "[100::1]:38842",
	"[fd7a:115c:a1e0::1]:38842", "[fc00::1]:38842", "[fe80::1]:38842", "[ff02::1]:38842", // unique local (Tailscale's), link-local, multicast
	"[2001::1]:38842", "[2001:2::1]:38842", "[2001:db8::7]:38842", "[3fff::1]:38842", // Teredo, benchmarking, documentation
}

// weakNodeKeys are the encodings of Ed25519 keys that no private key backs:
// the eight points of small order (y = 1, p-1, 0 and the two y of order 8,
// each with both signs of x) and their non-canonical encodings (y + p).
// AgentLandCore's RemoteAccessClientTests refuses the same list.
func weakNodeKeys() []string {
	ys := []string{
		"0100000000000000000000000000000000000000000000000000000000000000", // 1: the identity
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p-1: order 2
		"0000000000000000000000000000000000000000000000000000000000000000", // 0: order 4
		"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05", // order 8
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a", // p minus that: order 8
		"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p (0 again)
		"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p+1 (1 again)
	}
	var keys []string
	for _, y := range ys {
		signed, _ := hex.DecodeString(y)
		signed[31] |= 0x80
		keys = append(keys, y, hex.EncodeToString(signed))
	}
	return keys
}

// A node ID proof shows that the device holds the key. crypto/ed25519.Verify
// is cofactorless and takes small-order keys, for which a signature verifies
// without any private key: the identity key with R = identity and S = 0
// verifies for every message. verifyNodeProof refuses every such key.
func TestNodeProofRefusesKeysNoDeviceHolds(t *testing.T) {
	identity := "01" + strings.Repeat("0", 62)
	forged := "01" + strings.Repeat("0", 126)
	signature, _ := hex.DecodeString(forged)
	for _, weak := range weakNodeKeys() {
		key, _ := hex.DecodeString(weak)
		// Find a binding whose message the forged signature verifies for with
		// the standard library alone (for each of these keys, non-canonical
		// ones included), which shows that the key is of small order; the host
		// must still refuse it.
		shown := false
		for i := 0; i < 512 && !shown; i++ {
			binding := "device-" + strconv.Itoa(i)
			if ed25519.Verify(ed25519.PublicKey(key), nodeProofMessage("register", binding, weak), signature) {
				shown = true
				if verifyNodeProof("register", binding, weak, forged) {
					t.Errorf("a forged proof for %s verified", weak)
				}
			}
		}
		if !shown {
			t.Errorf("%s: the forged signature never verified with crypto/ed25519; is it of small order?", weak)
		}
		if strongNodeKey(key) {
			t.Errorf("%s counts as a key a device can hold", weak)
		}
	}
	// The reported vector, for both purposes and any binding.
	for _, purpose := range []string{"pair", "register"} {
		for _, binding := range []string{"0012345678", "9c1e44d0a7b2c35f8e016d42", ""} {
			if verifyNodeProof(purpose, binding, identity, forged) {
				t.Errorf("the identity key's forged %s proof for %q verified", purpose, binding)
			}
		}
	}
	// Every non-canonical encoding (y at p or above) is refused; a real key
	// is not.
	for low := 0xed; low <= 0xff; low++ {
		for _, sign := range []byte{0x7f, 0xff} {
			key := make([]byte, 32)
			key[0], key[31] = byte(low), sign
			for i := 1; i < 31; i++ {
				key[i] = 0xff
			}
			if strongNodeKey(key) {
				t.Errorf("non-canonical %x accepted", key)
			}
		}
	}
	real := newNodeKey(t)
	realKey, _ := hex.DecodeString(real.id)
	if !strongNodeKey(realKey) || !verifyNodeProof("register", "device-1", real.id, real.proof("register", "device-1")) {
		t.Fatal("a real key was refused")
	}
}

// The Ed25519 key of seed 00 01 … 1f and its proofs; AgentLandCore's
// RemoteAccessClientTests checks the same proofs over its own message bytes.
func TestNodeProofCrossLanguageVector(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	private := ed25519.NewKeyFromSeed(seed)
	node := hex.EncodeToString(private.Public().(ed25519.PublicKey))
	if node != "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8" {
		t.Fatalf("node ID %s", node)
	}
	for _, vector := range []struct{ purpose, binding, proof string }{
		{"pair", "0012345678", "f44713a67909e6ff5cfcaa1eb6af9d58a72b48d583e08c4bda9998e8820c7d8b91f88bb40aeeaf0f14354952217463de56c79edf2b8864d506827a1c1abca40b"},
		{"register", "9c1e44d0a7b2c35f8e016d42", "3d2c1c5c1712258597954c7749de7ef20dcefc0f0b8f89ced84816af6a763ed87272ee7b0fe5aba8c0218f9d9cb4bd6c4fd17d0706f8579dbb473d7a8c350404"},
	} {
		if got := hex.EncodeToString(ed25519.Sign(private, nodeProofMessage(vector.purpose, vector.binding, node))); got != vector.proof {
			t.Errorf("%s proof %s", vector.purpose, got)
		}
		if !verifyNodeProof(vector.purpose, vector.binding, node, vector.proof) {
			t.Errorf("%s proof does not verify", vector.purpose)
		}
	}
}

func TestPairingKeepsTheNodeIDAndRevokingRemovesIt(t *testing.T) {
	h, store := remoteHost(t)
	key := newNodeKey(t)
	token, id := pairWithNode(t, h, store, "Phone", &key)
	if got := deviceNode(t, store, id); got != key.id {
		t.Fatalf("node ID %q, want %q", got, key.id)
	}
	peers := readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers", nil))
	if len(peers.Peers) != 1 || peers.Peers[0] != (remotePeer{DeviceID: id, NodeID: key.id}) {
		t.Fatalf("peers %+v", peers)
	}
	// Pairing without the members works as before and keeps no node ID.
	_, plain := pairWithNode(t, h, store, "iPad", nil)
	if got := deviceNode(t, store, plain); got != "" {
		t.Fatalf("a device paired without a node ID has %q", got)
	}
	if err := store.RevokeDevice(id); err != nil {
		t.Fatal(err)
	}
	if got := deviceNode(t, store, id); got != "" {
		t.Fatalf("a revoked device keeps node ID %q", got)
	}
	if peers := readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers", nil)); len(peers.Peers) != 0 {
		t.Fatalf("revoked device still listed: %+v", peers)
	}
	if got := request(t, h.Handler(), "GET", "/v1/projects", token, nil).Code; got != 401 {
		t.Fatalf("revoked token: %d", got)
	}
}

func TestPairingChecksTheNodeMembersBeforeTheCode(t *testing.T) {
	h, store := remoteHost(t)
	key := newNodeKey(t)
	mac := newNodeKey(t)
	if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": false, "nodeId": mac.id}); w.Code != 200 {
		t.Fatalf("report: %d %s", w.Code, w.Body.String())
	}
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		body   map[string]any
		status int
		code   string
	}{
		{"node ID alone", map[string]any{"irohNodeId": key.id}, 400, "invalid_request"},
		{"proof alone", map[string]any{"irohNodeProof": key.proof("pair", code)}, 400, "invalid_request"},
		{"upper case node ID", map[string]any{"irohNodeId": strings.ToUpper(key.id), "irohNodeProof": key.proof("pair", code)}, 400, "invalid_request"},
		{"short proof", map[string]any{"irohNodeId": key.id, "irohNodeProof": key.proof("pair", code)[:100]}, 400, "invalid_request"},
		{"proof for another code", map[string]any{"irohNodeId": key.id, "irohNodeProof": key.proof("pair", "0000000000")}, 400, "invalid_node_proof"},
		{"proof for registering", map[string]any{"irohNodeId": key.id, "irohNodeProof": key.proof("register", code)}, 400, "invalid_node_proof"},
		{"the Mac's node ID", map[string]any{"irohNodeId": mac.id, "irohNodeProof": mac.proof("pair", code)}, 409, "node_id_in_use"},
	} {
		tc.body["code"], tc.body["deviceName"] = code, "Phone"
		w := request(t, h.Handler(), "POST", "/v1/pair", "", tc.body)
		if w.Code != tc.status || errorCode(t, w) != tc.code {
			t.Errorf("%s: %d %s, want %d %s", tc.name, w.Code, w.Body.String(), tc.status, tc.code)
		}
	}
	// None of those used the code up.
	w := request(t, h.Handler(), "POST", "/v1/pair", "", map[string]any{"code": code, "deviceName": "Phone", "irohNodeId": key.id, "irohNodeProof": key.proof("pair", code)})
	if w.Code != 200 {
		t.Fatalf("the code was used up by a refusal: %d %s", w.Code, w.Body.String())
	}
}

// Pairing again (owner, 2026-10-17): a node ID the device proves it holds
// names its record, which the pairing replaces; a token that names another
// record wins, and that record takes the node ID from the older one.
func TestPairingTakesTheNodeIDFromAnOlderRecord(t *testing.T) {
	h, store := remoteHost(t)
	key := newNodeKey(t)
	oldToken, oldID := pairWithNode(t, h, store, "Phone", &key)
	// The same phone after a reinstall: the Keychain kept the key, not the token.
	newToken, newID := pairWithNode(t, h, store, "Phone", &key)
	if newID != oldID || deviceNode(t, store, oldID) != key.id {
		t.Fatalf("paired again as %s (was %s), node %q", newID, oldID, deviceNode(t, store, oldID))
	}
	if got := request(t, h.Handler(), "GET", "/v1/projects", oldToken, nil).Code; got != 401 {
		t.Fatalf("the replaced token still works: %d", got)
	}
	if got := request(t, h.Handler(), "GET", "/v1/projects", newToken, nil).Code; got != 200 {
		t.Fatalf("the new token: %d", got)
	}
	peers := readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers", nil))
	if len(peers.Peers) != 1 || peers.Peers[0] != (remotePeer{DeviceID: oldID, NodeID: key.id}) {
		t.Fatalf("peers %+v", peers)
	}
	// An older duplicate record of the same phone, without the node ID (paired
	// before remote access), pairs again with its token and the key: the
	// token's record is replaced and takes the node ID; the other keeps its
	// token but loses the node ID.
	duplicateToken, duplicateID := pairWithNode(t, h, store, "Phone", nil)
	_, again := pairAgain(t, h, store, "Phone", duplicateToken, &key)
	if again != duplicateID || deviceNode(t, store, duplicateID) != key.id || deviceNode(t, store, oldID) != "" {
		t.Fatalf("paired again as %s (token's %s), nodes %q and %q", again, duplicateID, deviceNode(t, store, duplicateID), deviceNode(t, store, oldID))
	}
	if got := request(t, h.Handler(), "GET", "/v1/projects", newToken, nil).Code; got != 200 {
		t.Fatalf("the other record lost its token: %d", got)
	}
	peers = readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers", nil))
	if len(peers.Peers) != 1 || peers.Peers[0].DeviceID != duplicateID {
		t.Fatalf("peers %+v", peers)
	}
	if got := len(deviceRecords(t, store)); got != 2 {
		t.Fatalf("%d records, want 2", got)
	}
}

func TestRegisteringANodeID(t *testing.T) {
	h, store := remoteHost(t)
	token, id := pairWithNode(t, h, store, "Phone", nil)
	key := newNodeKey(t)
	register := func(token string, body any) *httptest.ResponseRecorder {
		return request(t, h.Handler(), "POST", "/v1/remote-access/device", token, body)
	}
	w := register(token, map[string]string{"nodeId": key.id, "proof": key.proof("register", id)})
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"nodeId":"`+key.id+`"}` {
		t.Fatalf("register: %d %s", w.Code, w.Body.String())
	}
	if deviceNode(t, store, id) != key.id {
		t.Fatal("node ID not kept")
	}
	// The same node ID again changes nothing and answers the same.
	if w := register(token, map[string]string{"nodeId": key.id, "proof": key.proof("register", id)}); w.Code != 200 {
		t.Fatalf("again: %d %s", w.Code, w.Body.String())
	}
	// Capabilities name the caller's own node ID.
	var capabilities struct {
		RemoteAccess *remoteAccessCapabilities `json:"remoteAccess"`
	}
	json.Unmarshal(request(t, h.Handler(), "GET", "/v1/capabilities", token, nil).Body.Bytes(), &capabilities)
	if capabilities.RemoteAccess == nil || capabilities.RemoteAccess.DeviceNodeID != key.id {
		t.Fatalf("capabilities %+v", capabilities.RemoteAccess)
	}
	// Another device registering it takes it.
	otherToken, otherID := pairWithNode(t, h, store, "iPad", nil)
	if w := register(otherToken, map[string]string{"nodeId": key.id, "proof": key.proof("register", otherID)}); w.Code != 200 {
		t.Fatalf("move: %d %s", w.Code, w.Body.String())
	}
	if deviceNode(t, store, id) != "" || deviceNode(t, store, otherID) != key.id {
		t.Fatal("the node ID did not move to the device that proved it holds the key")
	}
	mac := newNodeKey(t)
	macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": false, "nodeId": mac.id})
	for _, tc := range []struct {
		name   string
		token  string
		body   any
		status int
		code   string
	}{
		{"a proof bound to another device", token, map[string]string{"nodeId": key.id, "proof": key.proof("register", otherID)}, 400, "invalid_node_proof"},
		{"a pairing proof", token, map[string]string{"nodeId": key.id, "proof": key.proof("pair", id)}, 400, "invalid_node_proof"},
		{"no proof", token, map[string]string{"nodeId": key.id}, 400, "invalid_request"},
		{"an unknown member", token, map[string]string{"nodeId": key.id, "proof": key.proof("register", id), "name": "x"}, 400, "invalid_request"},
		{"the Mac's node ID", token, map[string]string{"nodeId": mac.id, "proof": mac.proof("register", id)}, 409, "node_id_in_use"},
		{"no token", "", map[string]string{"nodeId": key.id, "proof": key.proof("register", id)}, 401, "unauthorized"},
	} {
		if w := register(tc.token, tc.body); w.Code != tc.status || errorCode(t, w) != tc.code {
			t.Errorf("%s: %d %s, want %d %s", tc.name, w.Code, w.Body.String(), tc.status, tc.code)
		}
	}
	w = macRequest(t, h, "POST", "/v1/remote-access/device", map[string]string{"nodeId": key.id, "proof": key.proof("register", "local-mac")})
	if w.Code != 403 || errorCode(t, w) != "device_only" {
		t.Fatalf("the Mac's session: %d %s", w.Code, w.Body.String())
	}
	// A host without the tunnel socket serves no remote access.
	plain, plainStore, _ := testHost(t)
	plainToken, plainID := pairWithNode(t, plain, plainStore, "Phone", nil)
	w = request(t, plain.Handler(), "POST", "/v1/remote-access/device", plainToken, map[string]string{"nodeId": key.id, "proof": key.proof("register", plainID)})
	if w.Code != 501 || errorCode(t, w) != "remote_access_unavailable" {
		t.Fatalf("host without remote access: %d %s", w.Code, w.Body.String())
	}
}

func TestPeersLongPollWakesOnChanges(t *testing.T) {
	h, store := remoteHost(t)
	first := readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers", nil))
	if len(first.Peers) != 0 || first.Version == "" || len(first.Version) > 64 {
		t.Fatalf("empty list: %+v", first)
	}
	// Nothing changes: the wait passes and the same version comes back.
	began := time.Now()
	same := readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers?wait=300&after="+first.Version, nil))
	if same.Version != first.Version || time.Since(began) < 250*time.Millisecond {
		t.Fatalf("unchanged list answered %+v after %v", same, time.Since(began))
	}
	// Another version answers at once.
	if w := macRequest(t, h, "GET", "/v1/remote-access/peers?wait=20000&after=older", nil); readPeers(t, w).Version != first.Version {
		t.Fatal("another version was not answered at once")
	}

	// Pairing through the host wakes a waiting request at once.
	key := newNodeKey(t)
	answered := make(chan peersAnswer, 1)
	go func() {
		answered <- readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers?wait=20000&after="+first.Version, nil))
	}()
	time.Sleep(100 * time.Millisecond)
	_, id := pairWithNode(t, h, store, "Phone", &key)
	var paired peersAnswer
	select {
	case paired = <-answered:
	case <-time.After(2 * time.Second):
		t.Fatal("pairing did not wake the long-poll")
	}
	if paired.Version == first.Version || len(paired.Peers) != 1 || paired.Peers[0].NodeID != key.id || paired.Peers[0].DeviceID != id {
		t.Fatalf("after pairing: %+v", paired)
	}

	// Another process revoking (the revoke command writes the state file) is
	// noticed within 250 ms.
	go func() {
		answered <- readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers?wait=20000&after="+paired.Version, nil))
	}()
	time.Sleep(100 * time.Millisecond)
	revokedAt := time.Now()
	if err := NewStore(store.Path).RevokeDevice(id); err != nil {
		t.Fatal(err)
	}
	select {
	case revoked := <-answered:
		if len(revoked.Peers) != 0 || revoked.Version != first.Version {
			t.Fatalf("after revoking: %+v", revoked)
		}
		if elapsed := time.Since(revokedAt); elapsed > time.Second {
			t.Fatalf("revocation noticed after %v", elapsed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("revoking in another process did not wake the long-poll")
	}

	// A host that starts stopping answers at once.
	go func() {
		answered <- readPeers(t, macRequest(t, h, "GET", "/v1/remote-access/peers?wait=20000&after="+first.Version, nil))
	}()
	time.Sleep(100 * time.Millisecond)
	h.BeginShutdown()
	select {
	case <-answered:
	case <-time.After(2 * time.Second):
		t.Fatal("stopping did not end the long-poll")
	}
}

// An empty list is written [], never null, whatever came before: a fresh
// host, one whose devices have no node ID, one started again and one whose
// last node ID was revoked all answer the same body, which AgentLandCore's
// RemoteAccessPeers decodes (its peers are not optional).
func TestPeersAnswerAnEmptyListAsAnArray(t *testing.T) {
	h, store := remoteHost(t)
	empty := `{"peers":[],"version":"` + peerVersion(nil) + `"}`
	body := func(h *Host) string {
		t.Helper()
		w := macRequest(t, h, "GET", "/v1/remote-access/peers", nil)
		if w.Code != 200 {
			t.Fatalf("peers: %d %s", w.Code, w.Body.String())
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(raw)
		return string(data)
	}
	if got := body(h); got != empty {
		t.Fatalf("a fresh host: %s", got)
	}
	// A long-poll that times out answers the same.
	if w := macRequest(t, h, "GET", "/v1/remote-access/peers?wait=50&after="+peerVersion(nil), nil); !strings.Contains(w.Body.String(), `"peers":[]`) {
		t.Fatalf("a long-poll: %s", w.Body.String())
	}
	pairWithNode(t, h, store, "iPad", nil)
	if got := body(h); got != empty {
		t.Fatalf("devices without a node ID: %s", got)
	}
	again := NewWithOptions(store, &fakeAgent{sessions: map[string]Session{}}, HostOptions{LocalSessionToken: testLocalSession, RemoteAccess: true})
	t.Cleanup(func() { again.Close() })
	if got := body(again); got != empty {
		t.Fatalf("a host started again: %s", got)
	}
	key := newNodeKey(t)
	_, id := pairWithNode(t, h, store, "Phone", &key)
	if err := store.RevokeDevice(id); err != nil {
		t.Fatal(err)
	}
	if got := body(h); got != empty {
		t.Fatalf("after the last node ID was revoked: %s", got)
	}
}

func TestPeersRouteRefusals(t *testing.T) {
	h, store := remoteHost(t)
	for _, query := range []string{"?wait=-1", "?wait=20001", "?wait=soon", "?after=" + strings.Repeat("a", 65)} {
		if w := macRequest(t, h, "GET", "/v1/remote-access/peers"+query, nil); w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Errorf("%s: %d %s", query, w.Code, w.Body.String())
		}
	}
	token, _ := pairWithNode(t, h, store, "Phone", nil)
	for _, path := range []string{"/v1/remote-access/peers"} {
		if w := request(t, h.Handler(), "GET", path, token, nil); w.Code != 403 || errorCode(t, w) != "local_only" {
			t.Errorf("paired device on %s: %d", path, w.Code)
		}
	}
	if w := request(t, h.Handler(), "POST", "/v1/remote-access/endpoint", token, map[string]any{"enabled": false}); w.Code != 403 || errorCode(t, w) != "local_only" {
		t.Errorf("paired device reporting: %d", w.Code)
	}
	_, plainStore, agent := testHost(t)
	plain := NewWithOptions(plainStore, agent, HostOptions{LocalSessionToken: testLocalSession})
	t.Cleanup(func() { plain.Close() })
	for _, route := range [][2]string{{"GET", "/v1/remote-access/peers"}, {"POST", "/v1/remote-access/endpoint"}} {
		if w := macRequest(t, plain, route[0], route[1], map[string]any{"enabled": false}); w.Code != 501 || errorCode(t, w) != "remote_access_unavailable" {
			t.Errorf("host without the tunnel socket, %s: %d %s", route[1], w.Code, w.Body.String())
		}
	}
}

func TestEndpointReportAndCapabilities(t *testing.T) {
	h, store := remoteHost(t)
	token, id := pairWithNode(t, h, store, "Phone", nil)
	capabilitiesOf := func(token string, peer *tunnelPeer) map[string]any {
		t.Helper()
		w := requestFrom(t, h, "GET", "/v1/capabilities", token, nil, peer)
		if w.Code != 200 {
			t.Fatalf("capabilities: %d %s", w.Code, w.Body.String())
		}
		var out map[string]any
		json.Unmarshal(w.Body.Bytes(), &out)
		return out
	}
	// The members devices read, without the revision (which
	// TestEndpointReportOutlivesARestart and the pulse tests follow).
	remote := func(capabilities map[string]any) string {
		t.Helper()
		entry, _ := capabilities["remoteAccess"].(map[string]any)
		if revision, _ := entry["revision"].(string); len(revision) != 32 {
			t.Fatalf("revision %v", entry["revision"])
		}
		delete(entry, "revision")
		data, _ := json.Marshal(entry)
		return string(data)
	}
	if got := remote(capabilitiesOf(token, nil)); got != `{"directAddresses":[],"enabled":false,"fallbackRelay":false,"sequence":0,"version":1}` {
		t.Fatalf("before a report: %s", got)
	}
	mac, phone := newNodeKey(t), newNodeKey(t)
	good := map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38842, "directAddresses": []string{"1.2.3.4:38842", "[2A01:4F8::7]:38842"},
		"fallbackRelay": true, "relayUrl": "https://euw1-1.relay.example./"}
	w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", good)
	want := `{"directAddresses":["1.2.3.4:38842","[2a01:4f8::7]:38842"],"enabled":true,"fallbackRelay":true,"nodeId":"` + mac.id + `","relayUrl":"https://euw1-1.relay.example./","sequence":1,"version":1}`
	var echoed map[string]any
	json.Unmarshal(w.Body.Bytes(), &echoed)
	delete(echoed, "revision")
	if data, _ := json.Marshal(echoed); w.Code != 200 || string(data) != want {
		t.Fatalf("report: %d %s", w.Code, w.Body.String())
	}
	if got := remote(capabilitiesOf(token, nil)); got != want {
		t.Fatalf("devices see %s", got)
	}
	// This Mac's session sees the same, without deviceNodeId.
	if got := remote(capabilitiesOf(testLocalSession, nil)); got != want {
		t.Fatalf("the Mac sees %s", got)
	}
	if _, err := store.SetDeviceNodeID(id, phone.id); err != nil {
		t.Fatal(err)
	}
	if got := remote(capabilitiesOf(token, nil)); !strings.Contains(got, `"deviceNodeId":"`+phone.id+`"`) {
		t.Fatalf("the caller's node ID is missing: %s", got)
	}

	for _, tc := range []struct {
		name string
		body string
	}{
		{"no enabled", `{"nodeId":"` + mac.id + `","udpPort":38842}`},
		{"on without a node ID", `{"enabled":true,"udpPort":38842}`},
		{"on without a port", `{"enabled":true,"nodeId":"` + mac.id + `"}`},
		{"port 0", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":0}`},
		{"port 65536", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":65536}`},
		{"upper case node ID", `{"enabled":true,"nodeId":"` + strings.ToUpper(mac.id) + `","udpPort":38842}`},
		{"addresses while off", `{"enabled":false,"directAddresses":["1.2.3.4:38842"]}`},
		{"fallback while off", `{"enabled":false,"fallbackRelay":true}`},
		{"relay without the fallback", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"relayUrl":"https://relay.example"}`},
		{"http relay", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"fallbackRelay":true,"relayUrl":"http://relay.example"}`},
		{"relay with a query", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"fallbackRelay":true,"relayUrl":"https://relay.example/?a=1"}`},
		{"relay with a user", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"fallbackRelay":true,"relayUrl":"https://me@relay.example"}`},
		{"relay with a path", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"fallbackRelay":true,"relayUrl":"https://relay.example/relay"}`},
		{"empty relay", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"fallbackRelay":true,"relayUrl":""}`},
		{"long relay", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"fallbackRelay":true,"relayUrl":"https://` + strings.Repeat("a", 250) + `.example"}`},
		{"a loopback address", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["127.0.0.1:38842"]}`},
		{"a link-local address", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["[fe80::1]:38842"]}`},
		{"a zone", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["[2a01:4f8::1%en0]:38842"]}`},
		{"an unspecified address", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["0.0.0.0:38842"]}`},
		{"a multicast address", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["224.0.0.1:38842"]}`},
		{"a name", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["mac.example:38842"]}`},
		{"no port", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["1.2.3.4"]}`},
		{"port 0 address", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["1.2.3.4:0"]}`},
		{"a repeated address", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["1.2.3.4:1","1.2.3.4:1"]}`},
		{"nine addresses", `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["1.2.3.1:1","1.2.3.2:1","1.2.3.3:1","1.2.3.4:1","1.2.3.5:1","1.2.3.6:1","1.2.3.7:1","1.2.3.8:1","1.2.3.9:1"]}`},
		{"an unknown member", `{"enabled":false,"relay":"https://relay.example"}`},
	} {
		if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", tc.body); w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Errorf("%s: %d %s", tc.name, w.Code, w.Body.String())
		}
	}
	// Only global unicast addresses: what an inner router, carrier-grade NAT or
	// a network without a public address hands out is refused, so a phone never
	// dials an address it cannot reach (or someone else's on its own network).
	for _, address := range nonGlobalAddresses {
		body := `{"enabled":true,"nodeId":"` + mac.id + `","udpPort":38842,"directAddresses":["` + address + `"]}`
		if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", body); w.Code != 400 || errorCode(t, w) != "invalid_request" {
			t.Errorf("%s: %d %s", address, w.Code, w.Body.String())
		}
	}
	for _, address := range []string{"8.8.8.8:1", "100.63.255.255:38842", "100.128.0.1:38842", "172.32.0.1:38842", "198.20.0.1:38842",
		"[2a01:4f8::7]:38842", "[2001:200::1]:38842", "[2002:c000:204::1]:38842", "[3fff:1000::1]:38842"} {
		if _, ok := directAddress(address); !ok {
			t.Errorf("a global address was refused: %s", address)
		}
	}
	// The refusals changed nothing.
	if got := remote(capabilitiesOf(testLocalSession, nil)); got != want {
		t.Fatalf("a refused report changed the advertised one: %s", got)
	}
	// A device's node ID is not the Mac's.
	if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": false, "nodeId": phone.id}); w.Code != 409 || errorCode(t, w) != "node_id_in_use" {
		t.Fatalf("a device's node ID: %d %s", w.Code, w.Body.String())
	}
	// Turning it off replaces the report as a whole; the node ID may stay.
	w = macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": false, "nodeId": mac.id, "udpPort": 38842, "fallbackRelay": false, "directAddresses": []string{}})
	if w.Code != 200 {
		t.Fatalf("off: %d %s", w.Code, w.Body.String())
	}
	if got := remote(capabilitiesOf(testLocalSession, nil)); got != `{"directAddresses":[],"enabled":false,"fallbackRelay":false,"nodeId":"`+mac.id+`","sequence":2,"version":1}` {
		t.Fatalf("off: %s", got)
	}
	// Hosts without the tunnel socket list no remoteAccess.
	plain, _, _ := testHost(t)
	if _, listed := capabilitiesFor(t, plain)["remoteAccess"]; listed {
		t.Fatal("a host without the tunnel socket lists remoteAccess")
	}
}

// The last report outlives a restart: a host that starts again advertises it
// (with the same revision) until the Mac app reports again, so a device that
// reads capabilities in between never learns that remote access is off while
// the switch is on. Only a report of the switch going off turns it off.
func TestEndpointReportOutlivesARestart(t *testing.T) {
	h, store := remoteHost(t)
	token, _ := pairWithNode(t, h, store, "Phone", nil)
	mac := newNodeKey(t)
	remoteOf := func(h *Host) remoteAccessCapabilities {
		t.Helper()
		var out struct {
			RemoteAccess remoteAccessCapabilities `json:"remoteAccess"`
		}
		w := request(t, h.Handler(), "GET", "/v1/capabilities", token, nil)
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || w.Code != 200 {
			t.Fatalf("capabilities: %d %s", w.Code, w.Body.String())
		}
		return out.RemoteAccess
	}
	restart := func() *Host {
		t.Helper()
		again := NewWithOptions(store, &fakeAgent{sessions: map[string]Session{}}, HostOptions{LocalSessionToken: testLocalSession, RemoteAccess: true})
		t.Cleanup(func() { again.Close() })
		return again
	}
	none := remoteOf(h)
	if none.Enabled || none.NodeID != "" || none.Revision == "" {
		t.Fatalf("before any report: %+v", none)
	}
	if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38842,
		"directAddresses": []string{"1.2.3.4:38842"}, "fallbackRelay": true, "relayUrl": "https://euw1-1.relay.example./"}); w.Code != 200 {
		t.Fatalf("report: %d %s", w.Code, w.Body.String())
	}
	on := remoteOf(h)
	if !on.Enabled || on.Revision == none.Revision || len(on.Revision) != 32 {
		t.Fatalf("after the report: %+v", on)
	}
	again := restart()
	if got := remoteOf(again); !slices.Equal(got.DirectAddresses, on.DirectAddresses) || got.Enabled != on.Enabled || got.NodeID != on.NodeID ||
		got.RelayURL != on.RelayURL || got.FallbackRelay != on.FallbackRelay || got.Revision != on.Revision {
		t.Fatalf("a host started again advertises %+v, want %+v", got, on)
	}
	// The same report again keeps the revision; the switch going off is kept too.
	if w := macRequest(t, again, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38842,
		"directAddresses": []string{"1.2.3.4:38842"}, "fallbackRelay": true, "relayUrl": "https://euw1-1.relay.example./"}); w.Code != 200 || remoteOf(again).Revision != on.Revision {
		t.Fatalf("the same report: %d %s", w.Code, w.Body.String())
	}
	if w := macRequest(t, again, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": false, "nodeId": mac.id}); w.Code != 200 {
		t.Fatalf("off: %d %s", w.Code, w.Body.String())
	}
	off := restart()
	if got := remoteOf(off); got.Enabled || got.NodeID != mac.id || len(got.DirectAddresses) != 0 || got.Revision == on.Revision {
		t.Fatalf("after the switch went off and a restart: %+v", got)
	}
	// A kept report that today's rules refuse (an address no device can
	// reach) is dropped at start, not advertised.
	if err := store.update(func(st *State) error {
		st.RemoteAccess = &RemoteAccessReport{Enabled: true, NodeID: mac.id, UDPPort: 38842, DirectAddresses: []string{"192.168.0.5:38842"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if got := remoteOf(restart()); got.Enabled || got.NodeID != "" || got.Revision != none.Revision {
		t.Fatalf("a refused kept report was advertised: %+v", got)
	}
	// So is one whose node ID a paired device has since taken.
	phone := newNodeKey(t)
	pairWithNode(t, h, store, "iPad", &phone)
	if err := store.update(func(st *State) error {
		st.RemoteAccess = &RemoteAccessReport{Enabled: true, NodeID: phone.id, UDPPort: 38842, DirectAddresses: []string{"1.2.3.4:38842"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if got := remoteOf(restart()); got.Enabled || got.NodeID != "" {
		t.Fatalf("a kept report with a device's node ID was advertised: %+v", got)
	}
}

// The sequence orders the reports devices see, so a phone can tell whether
// the iCloud address record (which carries the sequence of the report it
// follows) is newer than the entry it keeps: it grows with every report that
// changes what devices see, stays for the same report and a change of the
// bound port alone, and never goes back, across restarts and when a kept
// report is dropped at start.
func TestEndpointReportSequenceOrdersWhatDevicesSee(t *testing.T) {
	h, store := remoteHost(t)
	token, _ := pairWithNode(t, h, store, "Phone", nil)
	mac := newNodeKey(t)
	remoteOf := func(h *Host) remoteAccessCapabilities {
		t.Helper()
		var out struct {
			RemoteAccess remoteAccessCapabilities `json:"remoteAccess"`
		}
		w := request(t, h.Handler(), "GET", "/v1/capabilities", token, nil)
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || w.Code != 200 {
			t.Fatalf("capabilities: %d %s", w.Code, w.Body.String())
		}
		return out.RemoteAccess
	}
	report := func(h *Host, body map[string]any) remoteAccessCapabilities {
		t.Helper()
		w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", body)
		var answer remoteAccessCapabilities
		if err := json.Unmarshal(w.Body.Bytes(), &answer); err != nil || w.Code != 200 {
			t.Fatalf("report: %d %s", w.Code, w.Body.String())
		}
		if got := remoteOf(h); got.Sequence != answer.Sequence || got.Revision != answer.Revision {
			t.Fatalf("the answer (%d) and capabilities (%d) differ", answer.Sequence, got.Sequence)
		}
		return answer
	}
	restart := func() *Host {
		t.Helper()
		again := NewWithOptions(store, &fakeAgent{sessions: map[string]Session{}}, HostOptions{LocalSessionToken: testLocalSession, RemoteAccess: true})
		t.Cleanup(func() { again.Close() })
		return again
	}
	on := map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38842, "directAddresses": []string{"1.2.3.4:38842"}}
	if got := remoteOf(h).Sequence; got != 0 {
		t.Fatalf("before any report: %d", got)
	}
	if got := report(h, map[string]any{"enabled": false, "nodeId": mac.id}).Sequence; got != 1 {
		t.Fatalf("the launch report: %d", got)
	}
	first := report(h, on)
	if first.Sequence != 2 {
		t.Fatalf("switched on: %d", first.Sequence)
	}
	if again := report(h, on); again.Sequence != 2 || again.Revision != first.Revision {
		t.Fatalf("the same report again: %+v", again)
	}
	moved := map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38843, "directAddresses": []string{"1.2.3.4:38842"}}
	if again := report(h, moved); again.Sequence != 2 || again.Revision != first.Revision {
		t.Fatalf("only the bound port changed: %+v", again)
	}
	// A refused report changes nothing.
	if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", map[string]any{"enabled": true, "nodeId": mac.id}); w.Code != 400 {
		t.Fatalf("a report without a port: %d", w.Code)
	}
	if got := remoteOf(h).Sequence; got != 2 {
		t.Fatalf("after a refused report: %d", got)
	}
	if got := report(h, map[string]any{"enabled": false, "nodeId": mac.id}).Sequence; got != 3 {
		t.Fatalf("switched off: %d", got)
	}
	if got := remoteOf(restart()); got.Sequence != 3 || got.Enabled {
		t.Fatalf("after a restart: %+v", got)
	}
	// A kept report today's rules refuse is dropped at start (devices see
	// none, sequence 0), and the next report still comes after it.
	if err := store.update(func(st *State) error {
		st.RemoteAccess = &RemoteAccessReport{Enabled: true, NodeID: mac.id, UDPPort: 38842, DirectAddresses: []string{"192.168.0.5:38842"}, Sequence: 7}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	dropped := restart()
	if got := remoteOf(dropped); got.Sequence != 0 || got.NodeID != "" {
		t.Fatalf("a dropped report: %+v", got)
	}
	if got := report(dropped, on).Sequence; got != 8 {
		t.Fatalf("after a dropped report: %d", got)
	}
	// A report kept by a host before sequences counts as 0, so even the same
	// report gets one a record can carry.
	if err := store.update(func(st *State) error {
		st.RemoteAccess = &RemoteAccessReport{Enabled: true, NodeID: mac.id, UDPPort: 38842, DirectAddresses: []string{"1.2.3.4:38842"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	older := restart()
	if got := remoteOf(older).Sequence; got != 0 {
		t.Fatalf("a kept report without a sequence: %d", got)
	}
	if got := report(older, on).Sequence; got != 1 {
		t.Fatalf("the same report on a host that kept none: %d", got)
	}
}

func capabilitiesFor(t *testing.T, h *Host) map[string]any {
	t.Helper()
	token := paired(t, h, h.store)
	var out map[string]any
	json.Unmarshal(request(t, h.Handler(), "GET", "/v1/capabilities", token, nil).Body.Bytes(), &out)
	return out
}

// Requests through the tunnel are never this Mac's own, are bound to the
// preamble's device, and cannot pair or register (the socket itself is in
// tunnel_unix_test.go).
func TestTunnelRequestsAreNeverLocal(t *testing.T) {
	_, store, agent := testHost(t)
	h := NewWithOptions(store, agent, HostOptions{LocalSessionToken: testLocalSession, RemoteAccess: true, Preview: &PreviewOptions{Port: 9842, APIPort: 9841}})
	t.Cleanup(func() { h.Close() })
	key, otherKey := newNodeKey(t), newNodeKey(t)
	token, id := pairWithNode(t, h, store, "Phone", &key)
	otherToken, otherID := pairWithNode(t, h, store, "iPad", &otherKey)
	peer := &tunnelPeer{nodeID: key.id, deviceID: id}
	through := func(method, path, token string, body any) *httptest.ResponseRecorder {
		return requestFrom(t, h, method, path, token, body, peer)
	}

	if w := through("GET", "/v1/health", "", nil); w.Code != 200 {
		t.Fatalf("health: %d", w.Code)
	}
	if w := through("GET", "/v1/projects", token, nil); w.Code != 200 {
		t.Fatalf("the device's own token: %d %s", w.Code, w.Body.String())
	}
	for _, path := range []string{"/v1/projects", "/v1/remote-access/peers", "/v1/notices", "/v1/archive/stats"} {
		if w := through("GET", path, testLocalSession, nil); w.Code != 401 {
			t.Errorf("the local session through the tunnel on %s: %d", path, w.Code)
		}
	}
	if w := through("GET", "/v1/remote-access/peers", token, nil); w.Code != 403 || errorCode(t, w) != "local_only" {
		t.Errorf("a local-only route: %d %s", w.Code, w.Body.String())
	}
	if w := through("GET", "/v1/projects", otherToken, nil); w.Code != 403 || errorCode(t, w) != "tunnel_device_mismatch" {
		t.Errorf("another device's token: %d %s", w.Code, w.Body.String())
	}
	code, _ := store.CreatePairingCode(time.Minute)
	if w := through("POST", "/v1/pair", "", map[string]any{"code": code, "deviceName": "Stranger"}); w.Code != 403 || errorCode(t, w) != "tunnel_refused" {
		t.Errorf("pairing: %d %s", w.Code, w.Body.String())
	}
	h.attempts.Lock()
	counted := len(h.allPairAttempts)
	h.attempts.Unlock()
	if counted != 2 {
		t.Errorf("pairing through the tunnel counted toward the limits: %d attempts", counted)
	}
	if w := through("POST", "/v1/remote-access/device", token, map[string]string{"nodeId": key.id, "proof": key.proof("register", id)}); w.Code != 403 || errorCode(t, w) != "tunnel_refused" {
		t.Errorf("registering: %d %s", w.Code, w.Body.String())
	}
	// Previews are not bridged.
	var capabilities map[string]any
	json.Unmarshal(through("GET", "/v1/capabilities", token, nil).Body.Bytes(), &capabilities)
	if _, listed := capabilities["preview"]; listed {
		t.Error("capabilities through the tunnel list previews")
	}
	if _, listed := capabilities["remoteAccess"]; !listed {
		t.Error("capabilities through the tunnel leave out remoteAccess")
	}
	json.Unmarshal(request(t, h.Handler(), "GET", "/v1/capabilities", token, nil).Body.Bytes(), &capabilities)
	if _, listed := capabilities["preview"]; !listed {
		t.Error("capabilities over TCP leave out previews")
	}
	if w := through("POST", "/v1/preview/sessions", token, map[string]int{"port": 3000}); w.Code != 403 || errorCode(t, w) != "preview_unavailable" {
		t.Errorf("a preview session: %d %s", w.Code, w.Body.String())
	}
	// A node ID that moved to another device no longer carries the old one's
	// token.
	if _, err := store.SetDeviceNodeID(otherID, key.id); err != nil {
		t.Fatal(err)
	}
	if w := through("GET", "/v1/projects", token, nil); w.Code != 403 || errorCode(t, w) != "tunnel_device_mismatch" {
		t.Errorf("after the node ID moved: %d %s", w.Code, w.Body.String())
	}
	// The same token over TCP from loopback is still a paired device's, and
	// the local session over loopback still the Mac's.
	if w := request(t, h.Handler(), "GET", "/v1/projects", token, nil); w.Code != 200 {
		t.Errorf("TCP: %d", w.Code)
	}
	if w := macRequest(t, h, "GET", "/v1/remote-access/peers", nil); w.Code != 200 {
		t.Errorf("the Mac over loopback: %d", w.Code)
	}
}

func TestParseTunnelPreamble(t *testing.T) {
	key := newNodeKey(t)
	line := "agentland-tunnel/1 " + key.id + "\n"
	if len(line) != 84 || tunnelPreambleLength != 84 {
		t.Fatalf("preamble length %d", len(line))
	}
	if nodeID, ok := parseTunnelPreamble([]byte(line)); !ok || nodeID != key.id {
		t.Fatalf("parsed %q %v", nodeID, ok)
	}
	for _, bad := range []string{
		"agentland-tunnel/2 " + key.id + "\n",
		"agentland-tunnel/1 " + strings.ToUpper(key.id) + "\n",
		"agentland-tunnel/1 " + key.id + "\r",
		"agentland-tunnel/1  " + key.id[1:] + "\n",
		"AGENTLAND-TUNNEL/1 " + key.id + "\n",
		"agentland-tunnel/1 " + key.id,
		"agentland-tunnel/1 " + key.id + "\n\n",
		"\x16\x03\x01" + strings.Repeat("x", 81),
	} {
		if _, ok := parseTunnelPreamble([]byte(bad)); ok {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestTunnelConnectionLimits(t *testing.T) {
	conns := newTunnelConns()
	conns.openLimit, conns.peerOpenLimit, conns.peerMinuteLimit = 4, 2, 3
	now := time.Unix(1_800_000_000, 0)
	conns.now = func() time.Time { return now }
	a, b := tunnelPeer{nodeID: strings.Repeat("a", 64), deviceID: "A"}, tunnelPeer{nodeID: strings.Repeat("b", 64), deviceID: "B"}
	admit := func(peer tunnelPeer) (*tunnelConn, string) {
		if !conns.reserve() {
			return nil, "full"
		}
		client, server := net.Pipe()
		t.Cleanup(func() { client.Close() })
		return conns.admit(server, peer)
	}
	first, _ := admit(a)
	second, _ := admit(a)
	if first == nil || second == nil {
		t.Fatal("the first two were refused")
	}
	if conn, reason := admit(a); conn != nil || reason != "too many open connections" {
		t.Fatalf("third open connection: %v %q", conn, reason)
	}
	second.Close()
	if conn, reason := admit(a); conn == nil {
		t.Fatalf("after one closed: %q", reason)
	}
	// Three opened within the minute: the next waits for the minute to pass.
	first.Close()
	if conn, reason := admit(a); conn != nil || reason != "too many connections in the last minute" {
		t.Fatalf("fourth in a minute: %v %q", conn, reason)
	}
	now = now.Add(61 * time.Second)
	third, reason := admit(a)
	if third == nil {
		t.Fatalf("after the minute: %q", reason)
	}
	// The open places are shared by all peers.
	b1, _ := admit(b)
	if b1 == nil {
		t.Fatal("peer b refused")
	}
	if !conns.reserve() {
		t.Fatal("the fourth place was taken")
	}
	if conns.reserve() {
		t.Fatal("a fifth place was given")
	}
	conns.unreserve()
	// A node ID that moved or was revoked closes its connections.
	conns.closeStale(map[string]string{b.nodeID: "B", a.nodeID: "C"})
	if open, admitted := conns.count(); admitted != 1 || open != 1 {
		t.Fatalf("after closeStale: open %d admitted %d", open, admitted)
	}
	conns.closeAll()
	if open, admitted := conns.count(); admitted != 0 || open != 0 {
		t.Fatalf("after closeAll: open %d admitted %d", open, admitted)
	}
}

func TestValidateTunnelSocket(t *testing.T) {
	if !tunnelSocketSupported() {
		if err := ValidateTunnelSocket("/state/host.json", "/state/tunnel.sock"); err == nil {
			t.Fatal("accepted on a system without the tunnel socket")
		}
		return
	}
	if err := ValidateTunnelSocket("/Users/me/Library/Application Support/agentland/host.json", "/Users/me/Library/Application Support/agentland/tunnel.sock"); err != nil {
		t.Fatal(err)
	}
	for _, socket := range []string{
		"tunnel.sock",
		"/Users/me/Library/Application Support/agentland/../agentland/tunnel.sock",
		"/Users/me/tunnel.sock",
		"/Users/me/Library/Application Support/agentland/sub/tunnel.sock",
		"/Users/me/Library/Application Support/agentland/host.json",
		"/Users/me/Library/Application Support/agentland/" + strings.Repeat("s", 60),
	} {
		if err := ValidateTunnelSocket("/Users/me/Library/Application Support/agentland/host.json", socket); err == nil {
			t.Errorf("accepted %q", socket)
		}
	}
	folder := "/" + strings.Repeat("f", 93)
	if err := ValidateTunnelSocket(folder+"/host.json", folder+"/t"); err == nil {
		t.Error("accepted a folder too long for the private bind folder")
	}
}
