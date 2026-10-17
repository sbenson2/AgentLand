package host

import (
	"net/http"
	"testing"
	"time"
)

func TestDevicePresenceRequiresAuthenticationAndExpires(t *testing.T) {
	h, store, _ := testHost(t)
	token := paired(t, h, store)
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	h.now = func() time.Time { return base }
	store.now = h.now
	if got := request(t, h.Handler(), "POST", "/v1/device/presence", "", map[string]bool{"active": true}).Code; got != http.StatusUnauthorized {
		t.Fatalf("unauthenticated presence: %d", got)
	}
	if got := request(t, h.Handler(), "POST", "/v1/device/presence", token, map[string]bool{"active": true}).Code; got != 200 {
		t.Fatalf("heartbeat: %d", got)
	}
	devices, err := store.ListDevices()
	if err != nil || len(devices) != 1 || !devices[0].IsPresent(base.Add(44*time.Second)) {
		t.Fatalf("fresh presence: %+v, %v", devices, err)
	}
	if devices[0].IsPresent(base.Add(46 * time.Second)) {
		t.Fatal("stale heartbeat must expire")
	}
	if got := request(t, h.Handler(), "POST", "/v1/device/presence", token, map[string]bool{"active": false}).Code; got != 200 {
		t.Fatalf("background: %d", got)
	}
	devices, _ = store.ListDevices()
	if devices[0].IsPresent(base) {
		t.Fatal("background must clear presence")
	}
	if got := request(t, h.Handler(), "POST", "/v1/device/presence", token, map[string]bool{"active": true}).Code; got != 200 {
		t.Fatalf("second heartbeat: %d", got)
	}
	if err := store.RevokeDevice(devices[0].ID); err != nil {
		t.Fatal(err)
	}
	devices, _ = store.ListDevices()
	if devices[0].IsPresent(base) {
		t.Fatal("revoked device must not be present")
	}
	if got := request(t, h.Handler(), "POST", "/v1/device/presence", token, map[string]bool{"active": true}).Code; got != http.StatusUnauthorized {
		t.Fatalf("revoked heartbeat: %d", got)
	}
}

func TestListedDeviceNameCannotInjectCLIColumnsOrRows(t *testing.T) {
	_, store, _ := testHost(t)
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = store.RedeemPairingCode(code, "Phone\tperson\nsecond row\rhidden")
	if err != nil {
		t.Fatal(err)
	}
	devices, err := store.ListDevices()
	if err != nil || len(devices) != 1 {
		t.Fatal(err, devices)
	}
	if got := devices[0].Name; got != "Phone person second row hidden" {
		t.Fatalf("listed name = %q", got)
	}
}
