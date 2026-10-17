package host

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Pairing again (docs/HOST-API.md, "Pairing again"; owner, 2026-10-17): a
// device that shows it was paired before replaces its own record.

// pairAgain redeems a new code, offering previousToken as the bearer token
// and, with key, the node ID with its proof.
func pairAgain(t *testing.T, h *Host, store *Store, name, previousToken string, key *nodeKey) (token, deviceID string) {
	t.Helper()
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"code": code, "deviceName": name}
	if key != nil {
		body["irohNodeId"], body["irohNodeProof"] = key.id, key.proof("pair", code)
	}
	w := request(t, h.Handler(), "POST", "/v1/pair", previousToken, body)
	if w.Code != 200 {
		t.Fatalf("pair: %d %s", w.Code, w.Body.String())
	}
	var out map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 || out["token"] == "" || out["deviceId"] == "" {
		t.Fatalf("pair answered %s", w.Body.String())
	}
	return out["token"], out["deviceId"]
}

func deviceRecords(t *testing.T, store *Store) []Device {
	t.Helper()
	st, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	return st.Devices
}

func authenticates(t *testing.T, h *Host, token string) bool {
	t.Helper()
	switch code := request(t, h.Handler(), "GET", "/v1/projects", token, nil).Code; code {
	case 200:
		return true
	case 401:
		return false
	default:
		t.Fatalf("GET /v1/projects: %d", code)
		return false
	}
}

func TestPairingAgainWithTheOldTokenReplacesTheRecord(t *testing.T) {
	h, store, _ := testHost(t)
	now := time.Unix(1_800_000_000, 0).UTC()
	store.now = func() time.Time { return now }
	oldToken, id := pairAgain(t, h, store, "Phone", "", nil)
	if err := store.SetDevicePresence(id, true); err != nil {
		t.Fatal(err)
	}
	before := deviceRecords(t, store)[0]

	now = now.Add(time.Hour)
	newToken, again := pairAgain(t, h, store, "Phone (renamed)", oldToken, nil)
	if again != id {
		t.Fatalf("paired again as %s, want the record %s", again, id)
	}
	if newToken == oldToken || authenticates(t, h, oldToken) || !authenticates(t, h, newToken) {
		t.Fatal("the old token still works, or the new one does not")
	}
	records := deviceRecords(t, store)
	if len(records) != 1 {
		t.Fatalf("%d records, want 1", len(records))
	}
	after := records[0]
	if after.Name != "Phone (renamed)" || !after.CreatedAt.Equal(before.CreatedAt) || after.PairedAt == nil || !after.PairedAt.Equal(now) {
		t.Fatalf("record %+v", after)
	}
	if after.LastSeenAt == nil || !after.LastSeenAt.Equal(*before.LastSeenAt) || after.RevokedAt != nil {
		t.Fatalf("presence or revocation changed: %+v", after)
	}
	// The Mac's device list reports the latest pairing.
	if listed, err := store.ListDevices(); err != nil || len(listed) != 1 || listed[0].PairedAt == nil {
		t.Fatalf("listed %+v %v", listed, err)
	}
}

func TestPairingAgainEndsTheOldTokensChatStream(t *testing.T) {
	f, server := streamFixture(t)
	f.host.chatAuthEvery = 30 * time.Millisecond
	stream, _, _ := openStream(t, server, f.token, "projectId=p1&sessionId=s1")
	stream.until(t, "snapshot", 5*time.Second)
	_, again := pairAgain(t, f.host, f.store, "Phone", f.token, nil)
	if records := deviceRecords(t, f.store); len(records) != 1 || records[0].ID != again {
		t.Fatalf("records %+v", records)
	}
	if line := stream.next(t, 2*time.Second); line.Type != "unauthorized" {
		t.Fatalf("after pairing again: %s", line.raw)
	}
	if !stream.ended(time.Second) {
		t.Fatal("the old token's stream stayed open")
	}
}

func TestPairingAgainWithAWrongOrRevokedProofAddsARecord(t *testing.T) {
	h, store := remoteHost(t)
	token, id := pairAgain(t, h, store, "Phone", "", nil)
	for name, offered := range map[string]string{
		"a token no device has":    "not-a-token",
		"a token with a suffix":    token + "x",
		"an oversized token":       strings.Repeat("A", maxPairingTokenBytes+1),
		"this Mac's local session": testLocalSession,
	} {
		newToken, newID := pairAgain(t, h, store, "Other", offered, nil)
		if newID == id || !authenticates(t, h, token) || !authenticates(t, h, newToken) {
			t.Errorf("%s: replaced the record or a token stopped working", name)
		}
	}
	// Another scheme than Bearer is not a proof.
	code, _ := store.CreatePairingCode(time.Minute)
	r := httptest.NewRequest("POST", "/v1/pair", strings.NewReader(fmt.Sprintf(`{"code":%q,"deviceName":"Basic"}`, code)))
	r.Header.Set("Authorization", "Basic "+token)
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	if w.Code != 200 || strings.Contains(w.Body.String(), id) || !authenticates(t, h, token) {
		t.Fatalf("basic: %d %s", w.Code, w.Body.String())
	}

	// A revoked record is never paired again, by its token or by its node ID.
	key := newNodeKey(t)
	revokedToken, revokedID := pairAgain(t, h, store, "Lost phone", "", &key)
	if err := store.RevokeDevice(revokedID); err != nil {
		t.Fatal(err)
	}
	_, byToken := pairAgain(t, h, store, "Lost phone", revokedToken, nil)
	_, byNode := pairAgain(t, h, store, "Lost phone", "", &key)
	if byToken == revokedID || byNode == revokedID || byToken == byNode || authenticates(t, h, revokedToken) {
		t.Fatalf("revoked %s paired again as %s and %s", revokedID, byToken, byNode)
	}
	for _, d := range deviceRecords(t, store) {
		if d.ID == revokedID && (d.RevokedAt == nil || d.PairedAt != nil) {
			t.Fatalf("the revoked record changed: %+v", d)
		}
	}
	if got := len(deviceRecords(t, store)); got != 1+4+1+1+2 {
		t.Fatalf("%d records", got)
	}
}

func TestPairingWithoutAProofAddsARecord(t *testing.T) {
	h, store, _ := testHost(t)
	first, firstID := pairAgain(t, h, store, "Phone", "", nil)
	second, secondID := pairAgain(t, h, store, "Phone", "", nil)
	if firstID == secondID || !authenticates(t, h, first) || !authenticates(t, h, second) {
		t.Fatal("pairing without a proof replaced a record")
	}
	if records := deviceRecords(t, store); len(records) != 2 || records[0].PairedAt != nil || records[1].PairedAt != nil {
		t.Fatalf("records %+v", records)
	}
}

// A proof never spends, bypasses or explains a refused code: the answer is the
// one without a proof, the limits count it as any other attempt, and the
// record and its token stay as they were.
func TestPairingAgainKeepsTheCodeRulesAndLimits(t *testing.T) {
	h, store, _ := testHost(t)
	now := time.Unix(1_800_000_000, 0)
	h.now = func() time.Time { return now }
	token, id := pairAgain(t, h, store, "Phone", "", nil)
	expired, err := store.CreatePairingCode(-time.Second)
	if err != nil {
		t.Fatal(err)
	}
	try := func(code, offered string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/v1/pair", strings.NewReader(fmt.Sprintf(`{"code":%q,"deviceName":"Phone"}`, code)))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+offered)
		r.RemoteAddr = "192.0.2.7:12345"
		w := httptest.NewRecorder()
		h.Handler().ServeHTTP(w, r)
		return w
	}
	refused := `{"error":{"code":"invalid_pairing_code","message":"Pairing code is invalid or expired"}}` + "\n"
	for attempt := 2; attempt <= 10; attempt++ {
		code := "1234567890"
		if attempt%2 == 0 {
			code = expired
		}
		if w := try(code, token); w.Code != 401 || w.Body.String() != refused {
			t.Fatalf("attempt %d: %d %s", attempt, w.Code, w.Body.String())
		}
	}
	// pairAgain's request came from another address; this client has had 9.
	if w := try("1234567890", token); w.Code != 401 {
		t.Fatalf("tenth attempt: %d", w.Code)
	}
	code, _ := store.CreatePairingCode(time.Minute)
	if w := try(code, token); w.Code != http.StatusTooManyRequests {
		t.Fatalf("a proof bypassed the per-client limit: %d %s", w.Code, w.Body.String())
	}
	if !authenticates(t, h, token) {
		t.Fatal("refused attempts changed the record's token")
	}
	if records := deviceRecords(t, store); len(records) != 1 || records[0].ID != id || records[0].PairedAt != nil {
		t.Fatalf("records %+v", records)
	}
	// The code the limit refused was not spent: once the window passes it
	// pairs again, once.
	now = now.Add(time.Minute)
	if w := try(code, token); w.Code != 200 || !strings.Contains(w.Body.String(), `"deviceId":"`+id+`"`) {
		t.Fatalf("after the window: %d %s", w.Code, w.Body.String())
	}
	if w := try(code, "not-a-token"); w.Code != 401 {
		t.Fatalf("the code paired twice: %d", w.Code)
	}
}
