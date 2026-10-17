package host

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode"
)

type Config struct {
	OpenCodeURL string    `json:"openCodeUrl"`
	PasswordEnv string    `json:"passwordEnv"`
	Projects    []Project `json:"projects"`
}
type pairingCode struct {
	Hash      string    `json:"hash"`
	ExpiresAt time.Time `json:"expiresAt"`
}
type Device struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	TokenHash  string     `json:"tokenHash,omitempty"`
	CreatedAt  time.Time  `json:"createdAt"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
	LastSeenAt *time.Time `json:"lastSeenAt,omitempty"`
	// PairedAt is when the device last paired again over this record
	// (RedeemPairing); absent until then, so CreatedAt stays the first pairing.
	PairedAt *time.Time `json:"pairedAt,omitempty"`
	// Remote access (remote_access.go): the device's iroh node ID, 64
	// lowercase hex characters, given at pairing or registered later with a
	// proof that the device holds its key. The Mac admits only these node IDs,
	// and the tunnel socket binds each connection to one. Revoking clears it.
	IrohNodeID string `json:"irohNodeId,omitempty"`
}

const presenceTTL = 45 * time.Second

func (d Device) IsPresent(now time.Time) bool {
	return d.RevokedAt == nil && d.LastSeenAt != nil && !d.LastSeenAt.After(now) && now.Sub(*d.LastSeenAt) < presenceTTL
}

type State struct {
	AutomaticUpdates bool          `json:"automaticUpdates,omitempty"`
	Version          int           `json:"version"`
	Config           Config        `json:"config"`
	PairingCodes     []pairingCode `json:"pairingCodes,omitempty"`
	Devices          []Device      `json:"devices,omitempty"`
	// Workspaces (workspaces.go): the folders of removed workspaces, so adding
	// one again brings back its ID. Kept outside Config, which config set
	// replaces as a whole.
	RemovedProjects []RemovedProject `json:"removedProjects,omitempty"`
	// Remote access (remote_access.go): the Mac endpoint's last report, kept
	// so a host that starts again advertises it until the Mac app reports
	// again, instead of telling devices that remote access is off.
	RemoteAccess *RemoteAccessReport `json:"remoteAccess,omitempty"`
	// Vault (vault_routes.go): the Markdown copy of the archive as POST
	// /v1/vault/settings left it. Absent, the vault is off.
	Vault *VaultSettings `json:"vault,omitempty"`
}

// RemoteAccessReport is the Mac endpoint's last report as the state file
// keeps it (POST /v1/remote-access/endpoint).
type RemoteAccessReport struct {
	Enabled         bool     `json:"enabled"`
	NodeID          string   `json:"nodeId,omitempty"`
	UDPPort         int      `json:"udpPort,omitempty"`
	DirectAddresses []string `json:"directAddresses,omitempty"`
	FallbackRelay   bool     `json:"fallbackRelay,omitempty"`
	RelayURL        string   `json:"relayUrl,omitempty"`
	// Sequence orders the reports devices see (capabilities.remoteAccess
	// sequence, and the iCloud address record's): it grows by one with each
	// kept report that changes what devices see and never goes back, also when
	// a kept report is dropped at start.
	Sequence int64 `json:"sequence,omitempty"`
}
type Store struct {
	Path string
	now  func() time.Time
}

func NewStore(path string) *Store { return &Store{Path: path, now: time.Now} }

func ValidateConfig(c Config) error {
	if c.PasswordEnv == "" {
		return errors.New("OpenCode password environment variable name is required")
	}
	if len(c.Projects) == 0 {
		return errors.New("at least one project is required")
	}
	u, err := url.Parse(c.OpenCodeURL)
	if err != nil || u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("OpenCode URL must be a loopback HTTP URL without credentials, query, or fragment")
	}
	host := u.Hostname()
	ip := net.ParseIP(host)
	if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("OpenCode URL must be loopback")
	}
	seen := map[string]bool{}
	for i := range c.Projects {
		p := &c.Projects[i]
		if p.ID == "" || p.Name == "" || !filepath.IsAbs(p.Directory) || seen[p.ID] {
			return errors.New("projects require unique IDs, names, and absolute directories")
		}
		// Plain chats (plain_chats.go): the Chats space's ID is reserved.
		if p.ID == plainChatsProjectID {
			return fmt.Errorf("project ID %q is reserved for plain chats; choose another", plainChatsProjectID)
		}
		clean, err := filepath.Abs(p.Directory)
		if err != nil {
			return err
		}
		p.Directory = filepath.Clean(clean)
		info, err := os.Stat(p.Directory)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("project directory %q is not an existing directory", p.Directory)
		}
		seen[p.ID] = true
	}
	return nil
}

func (s *Store) Initialize(c Config) error {
	if err := ValidateConfig(c); err != nil {
		return err
	}
	return s.withLock(func() error {
		if _, err := os.Stat(s.Path); err == nil {
			return errors.New("state already exists")
		}
		return s.write(State{Version: 1, Config: c})
	})
}
func (s *Store) Read() (State, error) {
	var out State
	err := s.withLock(func() error { var err error; out, err = s.read(); return err })
	return out, err
}
func (s *Store) CreatePairingCode(ttl time.Duration) (string, error) {
	code, err := randomCode(10)
	if err != nil {
		return "", err
	}
	return s.storePairingCode(code, ttl)
}

// CreatePairingPIN uses unbiased cryptographic randomness. The HTTPS pairing
// route also limits guesses across all network addresses, not only per client.
func (s *Store) CreatePairingPIN(ttl time.Duration) (string, error) {
	if ttl <= 0 || ttl > 10*time.Minute {
		return "", errors.New("PIN lifetime must be positive and at most ten minutes")
	}
	number, err := rand.Int(rand.Reader, big.NewInt(10_000_000_000))
	if err != nil {
		return "", err
	}
	return s.storePairingCode(fmt.Sprintf("%010d", number.Int64()), ttl)
}

func (s *Store) storePairingCode(code string, ttl time.Duration) (string, error) {
	expires := s.now().Add(ttl)
	err := s.update(func(st *State) error {
		st.PairingCodes = append(st.PairingCodes, pairingCode{Hash: hash(code), ExpiresAt: expires})
		return nil
	})
	return code, err
}
func (s *Store) RedeemPairingCode(code, name string) (string, string, error) {
	return s.RedeemPairingCodeWithNode(code, name, "")
}

// RedeemPairingCodeWithNode pairs a device as RedeemPairingCode does and, with
// a node ID, keeps it in the record. The caller has verified that the device
// holds the node's key, so a device record that has the node ID is the same
// device pairing again and is replaced (RedeemPairing).
func (s *Store) RedeemPairingCodeWithNode(code, name, nodeID string) (string, string, error) {
	pairing, err := s.RedeemPairing(code, name, nodeID, "")
	return pairing.Token, pairing.DeviceID, err
}

// Pairing is a redeemed pairing code: the device's new token and its ID, and
// whether it replaced the record of a device paired before.
type Pairing struct {
	Token    string
	DeviceID string
	Replaced bool
}

// RedeemPairing spends a valid pairing code once. A device that shows it was
// paired before replaces its own record instead of adding another
// (docs/HOST-API.md, "Pairing again"): the record that previousToken
// authenticates, else the one with nodeID (which the caller has verified the
// device holds). That record keeps its ID, so the device's terminals stay its
// own, and its creation time, presence and, without a new node ID, its node
// ID; it takes the new name and a new token, and the old token stops working.
// A proof that matches no record that is not revoked adds a record, as a
// first pairing does; it never refuses the code.
func (s *Store) RedeemPairing(code, name, nodeID, previousToken string) (Pairing, error) {
	if len(strings.TrimSpace(name)) < 1 || len(name) > 80 {
		return Pairing{}, errors.New("invalid device name")
	}
	token, err := randomCode(32)
	if err != nil {
		return Pairing{}, err
	}
	idBytes := make([]byte, 12)
	if _, err = rand.Read(idBytes); err != nil {
		return Pairing{}, err
	}
	pairing := Pairing{Token: token, DeviceID: hex.EncodeToString(idBytes)}
	err = s.update(func(st *State) error {
		now := s.now()
		idx := -1
		wanted := hash(code)
		valid := st.PairingCodes[:0]
		for _, p := range st.PairingCodes {
			if p.ExpiresAt.After(now) {
				if idx < 0 && constantEqual(p.Hash, wanted) {
					idx = len(valid)
				}
				valid = append(valid, p)
			}
		}
		st.PairingCodes = valid
		if idx < 0 {
			return errors.New("invalid or expired pairing code")
		}
		st.PairingCodes = append(st.PairingCodes[:idx], st.PairingCodes[idx+1:]...)
		previous := pairedBefore(st, nodeID, previousToken)
		releaseNodeID(st, nodeID)
		if previous < 0 {
			st.Devices = append(st.Devices, Device{ID: pairing.DeviceID, Name: name, TokenHash: hash(token), CreatedAt: now, IrohNodeID: nodeID})
			return nil
		}
		device := &st.Devices[previous]
		device.Name, device.TokenHash, device.PairedAt = name, hash(token), &now
		if nodeID != "" {
			device.IrohNodeID = nodeID
		}
		pairing.DeviceID, pairing.Replaced = device.ID, true
		return nil
	})
	if err != nil {
		return Pairing{}, err
	}
	return pairing, nil
}

// pairedBefore finds the record, not revoked, of a device that pairs again:
// the one previousToken authenticates, else the one with nodeID; -1 for none.
// Every record's token hash is compared, in constant time each.
func pairedBefore(st *State, nodeID, previousToken string) int {
	found := -1
	if previousToken != "" {
		wanted := hash(previousToken)
		for i, d := range st.Devices {
			if constantEqual(d.TokenHash, wanted) && d.RevokedAt == nil && found < 0 {
				found = i
			}
		}
	}
	if found >= 0 || nodeID == "" {
		return found
	}
	for i, d := range st.Devices {
		if d.RevokedAt == nil && d.IrohNodeID == nodeID {
			return i
		}
	}
	return -1
}
func (s *Store) Authenticate(token string) (Device, bool) {
	st, err := s.Read()
	if err != nil {
		return Device{}, false
	}
	wanted := hash(token)
	for _, d := range st.Devices {
		if d.RevokedAt == nil && constantEqual(d.TokenHash, wanted) {
			return d, true
		}
	}
	return Device{}, false
}
func (s *Store) RevokeDevice(id string) error {
	return s.update(func(st *State) error {
		for i := range st.Devices {
			if st.Devices[i].ID == id {
				now := s.now()
				st.Devices[i].RevokedAt = &now
				st.Devices[i].LastSeenAt = nil
				// Remote access: a revoked device's node ID is no longer admitted.
				st.Devices[i].IrohNodeID = ""
				return nil
			}
		}
		return ErrNotFound
	})
}

// SetDeviceNodeID gives a paired device that is not revoked the iroh node ID
// it proved it holds, replacing its previous one; another record that had the
// node ID loses it. It reports whether anything changed.
func (s *Store) SetDeviceNodeID(id, nodeID string) (bool, error) {
	changed := false
	err := s.update(func(st *State) error {
		index := -1
		for i := range st.Devices {
			if st.Devices[i].ID == id && st.Devices[i].RevokedAt == nil {
				index = i
			}
		}
		if index < 0 {
			return ErrNotFound
		}
		if st.Devices[index].IrohNodeID == nodeID {
			return errStateUnchanged
		}
		releaseNodeID(st, nodeID)
		st.Devices[index].IrohNodeID = nodeID
		changed = true
		return nil
	})
	if errors.Is(err, errStateUnchanged) {
		err = nil
	}
	return changed, err
}

func (r RemoteAccessReport) equal(other RemoteAccessReport) bool {
	return r.UDPPort == other.UDPPort && r.Sequence == other.Sequence && r.sameForDevices(other)
}

// sameForDevices: devices see no difference (the bound port is not theirs).
func (r RemoteAccessReport) sameForDevices(other RemoteAccessReport) bool {
	return r.Enabled == other.Enabled && r.NodeID == other.NodeID && slices.Equal(r.DirectAddresses, other.DirectAddresses) &&
		r.FallbackRelay == other.FallbackRelay && r.RelayURL == other.RelayURL
}

// SetRemoteAccessReport keeps the Mac endpoint's last report and returns the
// sequence it keeps it with: the kept one's plus one when devices see a
// change, the same otherwise (the same report again writes nothing). A kept
// report without a sequence (from a host before sequences) counts as 0.
func (s *Store) SetRemoteAccessReport(report RemoteAccessReport) (int64, error) {
	var sequence int64
	err := s.update(func(st *State) error {
		report.Sequence = 1
		if previous := st.RemoteAccess; previous != nil {
			report.Sequence = max(previous.Sequence, 0)
			if report.Sequence == 0 || !previous.sameForDevices(report) {
				report.Sequence++
			}
		}
		sequence = report.Sequence
		if st.RemoteAccess != nil && st.RemoteAccess.equal(report) {
			return errStateUnchanged
		}
		st.RemoteAccess = &report
		return nil
	})
	if errors.Is(err, errStateUnchanged) {
		err = nil
	}
	return sequence, err
}

// errStateUnchanged ends an update without writing the state.
var errStateUnchanged = errors.New("state unchanged")

// releaseNodeID takes nodeID from every device record that has it.
func releaseNodeID(st *State, nodeID string) {
	if nodeID == "" {
		return
	}
	for i := range st.Devices {
		if st.Devices[i].IrohNodeID == nodeID {
			st.Devices[i].IrohNodeID = ""
		}
	}
}

func (s *Store) SetDevicePresence(id string, active bool) error {
	return s.update(func(st *State) error {
		for i := range st.Devices {
			if st.Devices[i].ID == id && st.Devices[i].RevokedAt == nil {
				st.Devices[i].LastSeenAt = nil
				if active {
					now := s.now()
					st.Devices[i].LastSeenAt = &now
				}
				return nil
			}
		}
		return ErrNotFound
	})
}
func (s *Store) ListDevices() ([]Device, error) {
	st, err := s.Read()
	if err != nil {
		return nil, err
	}
	for i := range st.Devices {
		st.Devices[i].TokenHash = ""
		st.Devices[i].Name = strings.Join(strings.Fields(strings.Map(func(r rune) rune {
			if unicode.IsControl(r) {
				return ' '
			}
			return r
		}, st.Devices[i].Name)), " ")
	}
	return st.Devices, nil
}

func (s *Store) update(fn func(*State) error) error {
	return s.withLock(func() error {
		st, err := s.read()
		if err != nil {
			return err
		}
		if err = fn(&st); err != nil {
			return err
		}
		return s.write(st)
	})
}
func (s *Store) read() (State, error) {
	var st State
	b, err := readPrivateState(s.Path)
	if err != nil {
		return st, err
	}
	if err = json.Unmarshal(b, &st); err != nil {
		return st, err
	}
	return st, nil
}
func (s *Store) write(st State) error {
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return writePrivateState(s.Path, append(b, '\n'))
}
func (s *Store) withLock(fn func() error) error {
	return withPrivateStateLock(s.Path, fn)
}
func randomCode(n int) (string, error) {
	b := make([]byte, n)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return "", err
	}
	return strings.TrimRight(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b), "="), nil
}
func hash(v string) string           { sum := sha256.Sum256([]byte(v)); return hex.EncodeToString(sum[:]) }
func constantEqual(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }
func DefaultStatePath() string {
	configDirectory, err := os.UserConfigDir()
	if err != nil {
		return "agentland-host.json"
	}
	return filepath.Join(configDirectory, "agentland", "host.json")
}
func (c Config) Password() (string, error) {
	v := os.Getenv(c.PasswordEnv)
	if c.PasswordEnv == "" || v == "" {
		return "", fmt.Errorf("OpenCode password environment variable %q is not set", c.PasswordEnv)
	}
	return v, nil
}

// UpdateConfig preserves all authentication state and validates before taking the
// existing protected-state transaction. Callers restart their own host process
// to apply adapter settings; this never restarts another installation.
func (s *Store) UpdateConfig(c Config) error {
	if err := ValidateConfig(c); err != nil {
		return err
	}
	return s.update(func(st *State) error { st.Config = c; return nil })
}
