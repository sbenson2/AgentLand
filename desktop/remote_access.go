package host

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Remote access (docs/HOST-API.md, "Remote access (iroh)"). A paired device
// reaches this Mac from anywhere through iroh: the Mac app admits only the
// node IDs of paired devices and bridges each of their streams to the tunnel
// socket (tunnel.go), where requests are never this Mac's own. This file keeps
// the devices' node IDs (given at pairing or registered later, each with a
// proof that the device holds the key), the list the Mac app's gate follows,
// and the Mac endpoint's last report, which capabilities advertise.

const (
	remoteAccessVersion = 1
	// nodeProofDomain is the first line of every message a device signs.
	nodeProofDomain = "agentland-iroh-node/1"
	// remotePeersMaxWait bounds the peers long-poll, as the other long-polls.
	remotePeersMaxWait = 20 * time.Second
	// remoteStateWatchEvery is how often the state file is checked for a
	// change another process made (the revoke command).
	remoteStateWatchEvery = 250 * time.Millisecond
	maxDirectAddresses    = 8
	maxRelayURLBytes      = 256
)

// validNodeID reports whether s is a node ID as the contract writes it: the
// 32-byte Ed25519 public key in 64 lowercase hexadecimal characters.
func validNodeID(s string) bool { return lowerHex(s, 2*ed25519.PublicKeySize) }

// validNodeProof reports whether s is an Ed25519 signature in 128 lowercase
// hexadecimal characters.
func validNodeProof(s string) bool { return lowerHex(s, 2*ed25519.SignatureSize) }

func lowerHex(s string, length int) bool {
	if len(s) != length {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// nodeProofMessage is what a device signs with its iroh key: four lines
// joined by a line feed, without a final one.
func nodeProofMessage(purpose, binding, nodeID string) []byte {
	return []byte(nodeProofDomain + "\n" + purpose + "\n" + binding + "\n" + nodeID)
}

// verifyNodeProof checks proof, an Ed25519 signature, over the message for
// purpose and binding, with the node ID as the public key. A key that no
// private key backs is refused first: crypto/ed25519.Verify is cofactorless
// and takes small-order keys, for which a signature verifies without any
// private key (the identity key with R = identity and S = 0 verifies for
// every message).
func verifyNodeProof(purpose, binding, nodeID, proof string) bool {
	if !validNodeID(nodeID) || !validNodeProof(proof) {
		return false
	}
	key, err := hex.DecodeString(nodeID)
	if err != nil || !strongNodeKey(key) {
		return false
	}
	signature, err := hex.DecodeString(proof)
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(key), nodeProofMessage(purpose, binding, nodeID), signature)
}

// smallOrderY are the y coordinates (little-endian, the sign bit clear) of
// Ed25519's eight points of small order: 1 (the identity), p-1 (order 2), 0
// (the two of order 4) and the two y of the four points of order 8.
var smallOrderY = [5][32]byte{
	{0x01},
	{0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
	{},
	{0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
		0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05},
	{0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
		0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a},
}

// strongNodeKey reports whether key could be a device's Ed25519 public key:
// y is canonical (below p = 2^255 - 19, so one key has one node ID) and the
// point is not of small order. Points off the curve are refused by
// ed25519.Verify itself. iroh's own check (verify_strict) refuses the same
// keys, so no iroh handshake can be made with one.
func strongNodeKey(key []byte) bool {
	if len(key) != ed25519.PublicKeySize {
		return false
	}
	var y [32]byte
	copy(y[:], key)
	y[31] &= 0x7f
	// Compare with p from the most significant byte: 7f ff … ff ed.
	below := false
	for i := 31; i >= 0; i-- {
		limb := byte(0xff)
		switch i {
		case 31:
			limb = 0x7f
		case 0:
			limb = 0xed
		}
		if y[i] != limb {
			below = y[i] < limb
			break
		}
	}
	if !below {
		return false
	}
	for _, weak := range smallOrderY {
		if y == weak {
			return false
		}
	}
	return true
}

// strongNodeID is validNodeID for a key a device can hold.
func strongNodeID(nodeID string) bool {
	if !validNodeID(nodeID) {
		return false
	}
	key, err := hex.DecodeString(nodeID)
	return err == nil && strongNodeKey(key)
}

// remotePeer is one node ID the Mac app's gate admits, with its device.
type remotePeer struct {
	DeviceID string `json:"deviceId"`
	NodeID   string `json:"nodeId"`
}

// remoteEndpoint is the Mac endpoint's last report. The state file keeps it
// (State.RemoteAccess), so a host that starts again advertises it until the
// Mac app reports again.
type remoteEndpoint struct {
	enabled         bool
	nodeID          string
	udpPort         int
	directAddresses []string
	fallbackRelay   bool
	relayURL        string
	// sequence is the store's (Store.SetRemoteAccessReport): it orders the
	// reports devices see, so a phone can tell whether the iCloud address
	// record is newer than the entry it keeps.
	sequence int64
}

// revision identifies what devices see of the report (all of it but the
// bound port): the same report has the same revision, across restarts too.
func (r remoteEndpoint) revision() string {
	digest := sha256.New()
	fmt.Fprintf(digest, "agentland-remote-access/1\n%t\n%s\n%s\n%t\n%s\n%d", r.enabled, r.nodeID, strings.Join(r.directAddresses, ","), r.fallbackRelay,
		r.relayURL, r.sequence)
	return hex.EncodeToString(digest.Sum(nil))[:32]
}

func (r remoteEndpoint) stored() RemoteAccessReport {
	return RemoteAccessReport{Enabled: r.enabled, NodeID: r.nodeID, UDPPort: r.udpPort, DirectAddresses: slices.Clone(r.directAddresses),
		FallbackRelay: r.fallbackRelay, RelayURL: r.relayURL, Sequence: r.sequence}
}

// endpointFromStored checks a kept report against today's rules, as if the
// Mac app sent it now.
func endpointFromStored(stored RemoteAccessReport) (remoteEndpoint, bool) {
	in := endpointReportInput{Enabled: &stored.Enabled, DirectAddresses: stored.DirectAddresses}
	if stored.NodeID != "" {
		in.NodeID = &stored.NodeID
	}
	if stored.UDPPort != 0 {
		in.UDPPort = &stored.UDPPort
	}
	if stored.FallbackRelay {
		in.FallbackRelay = &stored.FallbackRelay
	}
	if stored.RelayURL != "" {
		in.RelayURL = &stored.RelayURL
	}
	report, problem := in.validated()
	report.sequence = max(stored.Sequence, 0)
	return report, problem == ""
}

// remoteAccessCapabilities is capabilities.remoteAccess.
type remoteAccessCapabilities struct {
	Version         int      `json:"version"`
	Revision        string   `json:"revision"`
	Enabled         bool     `json:"enabled"`
	NodeID          string   `json:"nodeId,omitempty"`
	DirectAddresses []string `json:"directAddresses"`
	FallbackRelay   bool     `json:"fallbackRelay"`
	RelayURL        string   `json:"relayUrl,omitempty"`
	Sequence        int64    `json:"sequence"`
	DeviceNodeID    string   `json:"deviceNodeId,omitempty"`
}

// remoteAccess is present when serve runs with --tunnel-socket and the
// Mac's local session.
type remoteAccess struct {
	host *Host

	mu       sync.Mutex
	report   remoteEndpoint
	revision string
	// reportChanged is closed and replaced whenever the revision changes.
	reportChanged chan struct{}
	peers         []remotePeer
	version       string
	// changed is closed and replaced whenever the peer list changes.
	changed chan struct{}
	// reportMu serializes reports, so the kept one is the advertised one.
	reportMu sync.Mutex

	// refreshMu serializes reading the state and publishing the list, so an
	// older reading never replaces a newer one.
	refreshMu sync.Mutex
	stateFile os.FileInfo

	// The tunnel socket's connections (tunnel.go).
	tunnel *tunnelConns

	watchEvery time.Duration
	running    bool
	stop       chan struct{}
	done       chan struct{}
	startOnce  sync.Once
	closeOnce  sync.Once
}

func newRemoteAccess(h *Host) *remoteAccess {
	// An empty list is [] on the wire, never null: AgentLandCore's
	// RemoteAccessPeers requires the array, and refresh keeps this one until
	// the list's version changes.
	return &remoteAccess{host: h, revision: remoteEndpoint{}.revision(), reportChanged: make(chan struct{}),
		changed: make(chan struct{}), peers: []remotePeer{}, version: peerVersion(nil), tunnel: newTunnelConns(),
		watchEvery: remoteStateWatchEvery, stop: make(chan struct{}), done: make(chan struct{})}
}

// loadReport advertises the report the state file kept, when today's rules
// still take it and no paired device has its node ID.
func (a *remoteAccess) loadReport() {
	st, err := a.host.store.Read()
	if err != nil || st.RemoteAccess == nil {
		return
	}
	report, ok := endpointFromStored(*st.RemoteAccess)
	if !ok {
		return
	}
	for _, device := range st.Devices {
		if report.nodeID != "" && device.RevokedAt == nil && device.IrohNodeID == report.nodeID {
			return
		}
	}
	a.setReport(report)
}

// setReport advertises report and wakes the pulses when devices see a change.
func (a *remoteAccess) setReport(report remoteEndpoint) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.report = report
	if revision := report.revision(); revision != a.revision {
		a.revision = revision
		close(a.reportChanged)
		a.reportChanged = make(chan struct{})
	}
}

// reportState is the advertised revision and the channel closed when it
// changes (the pulse).
func (a *remoteAccess) reportState() (string, <-chan struct{}) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.revision, a.reportChanged
}

// start reads the peer list now and follows the state file until close.
func (a *remoteAccess) start() {
	if a == nil {
		return
	}
	a.startOnce.Do(func() {
		a.loadReport()
		a.refresh()
		a.mu.Lock()
		a.running = true
		a.mu.Unlock()
		go func() {
			defer close(a.done)
			ticker := time.NewTicker(a.watchEvery)
			defer ticker.Stop()
			for {
				select {
				case <-a.stop:
					return
				case <-ticker.C:
					if a.stateFileChanged() {
						a.refresh()
					}
				}
			}
		}()
	})
}

func (a *remoteAccess) close() {
	if a == nil {
		return
	}
	a.closeOnce.Do(func() {
		close(a.stop)
		// A start after close does nothing; one in progress finishes first.
		a.startOnce.Do(func() {})
		a.mu.Lock()
		running := a.running
		a.mu.Unlock()
		if running {
			<-a.done
		}
		a.tunnel.closeAll()
	})
}

// stateFileChanged reports whether the state file is another file, or has
// another size or modification time, than at the last reading.
func (a *remoteAccess) stateFileChanged() bool {
	info, err := os.Stat(a.host.store.Path)
	if err != nil {
		return false
	}
	a.refreshMu.Lock()
	last := a.stateFile
	a.refreshMu.Unlock()
	return last == nil || !os.SameFile(last, info) || last.Size() != info.Size() || !last.ModTime().Equal(info.ModTime())
}

// refresh reads the devices' node IDs and, when the list changed, wakes the
// peers long-polls and closes tunnel connections whose node ID no longer
// belongs to the device they were admitted for.
func (a *remoteAccess) refresh() {
	a.refreshMu.Lock()
	defer a.refreshMu.Unlock()
	info, _ := os.Stat(a.host.store.Path)
	st, err := a.host.store.Read()
	if err != nil {
		return
	}
	a.stateFile = info
	peers := peersOf(st)
	version := peerVersion(peers)
	a.mu.Lock()
	changed := version != a.version
	if changed {
		a.peers, a.version = peers, version
		close(a.changed)
		a.changed = make(chan struct{})
	}
	a.mu.Unlock()
	if changed {
		current := make(map[string]string, len(peers))
		for _, peer := range peers {
			current[peer.NodeID] = peer.DeviceID
		}
		a.tunnel.closeStale(current)
	}
}

// peersOf lists the paired devices that are not revoked and have a node ID,
// sorted by node ID.
func peersOf(st State) []remotePeer {
	peers := []remotePeer{}
	for _, device := range st.Devices {
		if device.RevokedAt == nil && strongNodeID(device.IrohNodeID) {
			peers = append(peers, remotePeer{DeviceID: device.ID, NodeID: device.IrohNodeID})
		}
	}
	slices.SortFunc(peers, func(a, b remotePeer) int { return strings.Compare(a.NodeID, b.NodeID) })
	return peers
}

// peerVersion depends only on the list, so it survives restarts.
func peerVersion(peers []remotePeer) string {
	digest := sha256.New()
	for _, peer := range peers {
		digest.Write([]byte(peer.NodeID + " " + peer.DeviceID + "\n"))
	}
	return hex.EncodeToString(digest.Sum(nil))[:32]
}

// deviceForNode finds the paired device, not revoked, that has nodeID, from
// the state as it is now.
func (h *Host) deviceForNode(nodeID string) (Device, bool) {
	st, err := h.store.Read()
	if err != nil {
		return Device{}, false
	}
	for _, device := range st.Devices {
		if device.RevokedAt == nil && device.IrohNodeID == nodeID {
			return device, true
		}
	}
	return Device{}, false
}

func (a *remoteAccess) snapshot() ([]remotePeer, string, <-chan struct{}) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]remotePeer{}, a.peers...), a.version, a.changed
}

func (a *remoteAccess) macNodeID() string {
	if a == nil {
		return ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.report.nodeID
}

// capability is capabilities.remoteAccess for a caller whose registered node
// ID is deviceNodeID (empty for none and for this Mac's session).
func (a *remoteAccess) capability(deviceNodeID string) *remoteAccessCapabilities {
	a.mu.Lock()
	defer a.mu.Unlock()
	result := &remoteAccessCapabilities{Version: remoteAccessVersion, Revision: a.revision, Enabled: a.report.enabled, NodeID: a.report.nodeID,
		DirectAddresses: slices.Clone(a.report.directAddresses), FallbackRelay: a.report.fallbackRelay,
		RelayURL: a.report.relayURL, Sequence: a.report.sequence, DeviceNodeID: deviceNodeID}
	if result.DirectAddresses == nil {
		result.DirectAddresses = []string{}
	}
	return result
}

func remoteAccessUnavailable(w http.ResponseWriter) {
	writeError(w, 501, "remote_access_unavailable", "This host does not serve remote access")
}

// remoteAccessPeers serves GET /v1/remote-access/peers (local-only): the node
// IDs the Mac app's gate admits, long-polled with after and wait.
func (h *Host) remoteAccessPeers(w http.ResponseWriter, r *http.Request) {
	a := h.remote
	if a == nil {
		remoteAccessUnavailable(w)
		return
	}
	query := r.URL.Query()
	wait := time.Duration(0)
	if raw := query.Get("wait"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 || time.Duration(value)*time.Millisecond > remotePeersMaxWait {
			writeError(w, 400, "invalid_request", "wait must be between 0 and 20000 milliseconds")
			return
		}
		wait = time.Duration(value) * time.Millisecond
	}
	after := query.Get("after")
	if len(after) > 64 {
		writeError(w, 400, "invalid_request", "after must be a version this host gave")
		return
	}
	a.refresh()
	peers, version, changed := a.snapshot()
	if wait > 0 && after == version {
		timer := time.NewTimer(wait)
		defer timer.Stop()
		select {
		case <-changed:
		case <-timer.C:
		case <-h.stopping:
		case <-r.Context().Done():
			return
		}
		peers, version, _ = a.snapshot()
	}
	writeJSON(w, 200, map[string]any{"version": version, "peers": peers})
}

// reportRemoteEndpoint serves POST /v1/remote-access/endpoint (local-only):
// the Mac endpoint's state, which replaces the last report as a whole and is
// kept in the state file.
func (h *Host) reportRemoteEndpoint(w http.ResponseWriter, r *http.Request) {
	a := h.remote
	if a == nil {
		remoteAccessUnavailable(w)
		return
	}
	var in endpointReportInput
	if !decode(w, r, &in) {
		return
	}
	report, problem := in.validated()
	if problem != "" {
		writeError(w, 400, "invalid_request", problem)
		return
	}
	if report.nodeID != "" {
		if _, taken := h.deviceForNode(report.nodeID); taken {
			writeError(w, 409, "node_id_in_use", "A paired device has this node ID")
			return
		}
	}
	a.reportMu.Lock()
	defer a.reportMu.Unlock()
	sequence, err := h.store.SetRemoteAccessReport(report.stored())
	if err != nil {
		writeError(w, 500, "storage_error", "The host could not keep the report")
		return
	}
	report.sequence = sequence
	a.setReport(report)
	writeJSON(w, 200, a.capability(""))
}

type endpointReportInput struct {
	Enabled         *bool    `json:"enabled"`
	NodeID          *string  `json:"nodeId"`
	UDPPort         *int     `json:"udpPort"`
	DirectAddresses []string `json:"directAddresses"`
	FallbackRelay   *bool    `json:"fallbackRelay"`
	RelayURL        *string  `json:"relayUrl"`
}

// validated checks a report against the contract; problem is a message safe
// to show when it does not hold.
func (in endpointReportInput) validated() (report remoteEndpoint, problem string) {
	if in.Enabled == nil {
		return report, "enabled is required"
	}
	report.enabled = *in.Enabled
	if in.NodeID != nil {
		if !validNodeID(*in.NodeID) {
			return report, "nodeId must be 64 lowercase hexadecimal characters"
		}
		if !strongNodeID(*in.NodeID) {
			return report, "nodeId must be an Ed25519 public key an endpoint can hold"
		}
		report.nodeID = *in.NodeID
	} else if report.enabled {
		return report, "nodeId is required while remote access is on"
	}
	if in.UDPPort != nil {
		if *in.UDPPort < 1 || *in.UDPPort > 65535 {
			return report, "udpPort must be between 1 and 65535"
		}
		report.udpPort = *in.UDPPort
	} else if report.enabled {
		return report, "udpPort is required while remote access is on"
	}
	if len(in.DirectAddresses) > 0 && !report.enabled {
		return report, "directAddresses are only for remote access that is on"
	}
	if len(in.DirectAddresses) > maxDirectAddresses {
		return report, "directAddresses holds at most 8 addresses"
	}
	for _, raw := range in.DirectAddresses {
		address, ok := directAddress(raw)
		if !ok {
			return report, "directAddresses must be ip:port addresses a device can reach"
		}
		if slices.Contains(report.directAddresses, address) {
			return report, "directAddresses must not repeat an address"
		}
		report.directAddresses = append(report.directAddresses, address)
	}
	if in.FallbackRelay != nil && *in.FallbackRelay {
		if !report.enabled {
			return report, "fallbackRelay is only for remote access that is on"
		}
		report.fallbackRelay = true
	}
	if in.RelayURL != nil {
		if !report.fallbackRelay {
			return report, "relayUrl is only for the fallback relay"
		}
		if !validRelayURL(*in.RelayURL) {
			return report, "relayUrl must be an https URL of at most 256 bytes without user, query or fragment"
		}
		report.relayURL = *in.RelayURL
	}
	return report, ""
}

// directAddress checks one ip:port and returns it in canonical form: a
// global unicast IP (globalUnicast) without a zone, an IPv6 address in
// brackets, and a port above 0.
func directAddress(raw string) (string, bool) {
	if len(raw) > 64 {
		return "", false
	}
	address, err := netip.ParseAddrPort(raw)
	if err != nil || address.Port() == 0 {
		return "", false
	}
	ip := address.Addr().Unmap()
	if !globalUnicast(ip) {
		return "", false
	}
	return netip.AddrPortFrom(ip, address.Port()).String(), true
}

// nonGlobalPrefixes are the special-purpose blocks (IANA's registries) that
// are not reachable from the internet, beyond those netip classifies.
var nonGlobalPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),       // this network
	netip.MustParsePrefix("100.64.0.0/10"),   // shared address space: carrier-grade NAT, Tailscale
	netip.MustParsePrefix("192.0.0.0/24"),    // IETF protocol assignments (DS-Lite's 192.0.0.2)
	netip.MustParsePrefix("192.0.2.0/24"),    // documentation
	netip.MustParsePrefix("198.18.0.0/15"),   // benchmarking
	netip.MustParsePrefix("198.51.100.0/24"), // documentation
	netip.MustParsePrefix("203.0.113.0/24"),  // documentation
	netip.MustParsePrefix("240.0.0.0/4"),     // reserved
	netip.MustParsePrefix("2001::/23"),       // IETF protocol assignments: Teredo, benchmarking, ORCHID
	netip.MustParsePrefix("2001:db8::/32"),   // documentation
	netip.MustParsePrefix("3fff::/20"),       // documentation
}

// ipv6GlobalUnicast is the block IANA allocates global unicast addresses from.
var ipv6GlobalUnicast = netip.MustParsePrefix("2000::/3")

// globalUnicast reports whether ip can be reached from the internet: not
// unspecified, loopback, link-local, multicast or broadcast, not private
// (RFC 1918, unique local), not shared (100.64.0.0/10), and in no other
// block that is not globally reachable; an IPv6 address in 2000::/3.
func globalUnicast(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsValid() || ip.Zone() != "" || !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	if ip.Is6() && !ipv6GlobalUnicast.Contains(ip) {
		return false
	}
	for _, prefix := range nonGlobalPrefixes {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}

// validRelayURL: an https URL with a host, without user, query or fragment,
// its path empty or "/", at most 256 bytes of printable ASCII.
func validRelayURL(raw string) bool {
	if raw == "" || len(raw) > maxRelayURLBytes || strings.ContainsAny(raw, "#?@\\") {
		return false
	}
	for _, r := range raw {
		if r > unicode.MaxASCII || unicode.IsSpace(r) || unicode.IsControl(r) {
			return false
		}
	}
	parsed, err := url.Parse(raw)
	return err == nil && parsed.Scheme == "https" && parsed.Hostname() != "" && parsed.User == nil && parsed.Opaque == "" &&
		parsed.RawQuery == "" && parsed.Fragment == "" && (parsed.Path == "" || parsed.Path == "/")
}

// registerDeviceNode serves POST /v1/remote-access/device: a paired device
// registers its node ID with a proof, over the TCP listener only (serveHTTP
// refuses the route through the tunnel).
func (h *Host) registerDeviceNode(w http.ResponseWriter, r *http.Request) {
	a := h.remote
	if a == nil {
		remoteAccessUnavailable(w)
		return
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	if device.ID == "local-mac" {
		writeError(w, 403, "device_only", "Only paired devices register a node ID")
		return
	}
	var in struct {
		NodeID string `json:"nodeId"`
		Proof  string `json:"proof"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validNodeID(in.NodeID) || !validNodeProof(in.Proof) {
		writeError(w, 400, "invalid_request", "nodeId must be 64 and proof 128 lowercase hexadecimal characters")
		return
	}
	if !verifyNodeProof("register", device.ID, in.NodeID, in.Proof) {
		writeError(w, 400, "invalid_node_proof", "The proof does not show that this device holds the node's key")
		return
	}
	if in.NodeID == a.macNodeID() {
		writeError(w, 409, "node_id_in_use", "This Mac's own endpoint has this node ID")
		return
	}
	if _, err := h.store.SetDeviceNodeID(device.ID, in.NodeID); err != nil {
		if errors.Is(err, ErrNotFound) {
			writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
			return
		}
		internal(w)
		return
	}
	a.refresh()
	writeJSON(w, 200, map[string]string{"nodeId": in.NodeID})
}

// pairingNode checks the optional node members of POST /v1/pair before the
// code is redeemed. It returns the node ID to keep ("" for none) and false
// after answering a refusal.
func (h *Host) pairingNode(w http.ResponseWriter, code string, nodeID, proof *string) (string, bool) {
	if nodeID == nil && proof == nil {
		return "", true
	}
	if nodeID == nil || proof == nil || !validNodeID(*nodeID) || !validNodeProof(*proof) {
		writeError(w, 400, "invalid_request", "irohNodeId (64) and irohNodeProof (128 lowercase hexadecimal characters) go together")
		return "", false
	}
	if !verifyNodeProof("pair", code, *nodeID, *proof) {
		writeError(w, 400, "invalid_node_proof", "The proof does not show that this device holds the node's key")
		return "", false
	}
	if *nodeID == h.remote.macNodeID() {
		writeError(w, 409, "node_id_in_use", "This Mac's own endpoint has this node ID")
		return "", false
	}
	return *nodeID, true
}
