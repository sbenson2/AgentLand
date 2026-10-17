package host

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLocalSessionCredentialOnlyWorksFromLoopback(t *testing.T) {
	h, store, agent := testHost(t)
	h = NewWithOptions(store, agent, HostOptions{LocalSessionToken: "temporary-secret"})
	for _, tc := range []struct {
		remote string
		token  string
		want   int
	}{
		{"127.0.0.1:9000", "temporary-secret", 200},
		{"[::1]:9000", "temporary-secret", 200},
		{"192.0.2.1:9000", "temporary-secret", 401},
		{"127.0.0.1:9000", "wrong", 401},
	} {
		r := httptest.NewRequest("GET", "/v1/projects", nil)
		r.RemoteAddr = tc.remote
		r.Header.Set("Authorization", "Bearer "+tc.token)
		w := httptest.NewRecorder()
		h.Handler().ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Errorf("remote=%s token=%s: status=%d, want %d", tc.remote, tc.token, w.Code, tc.want)
		}
	}
	if state, err := store.Read(); err != nil || len(state.Devices) != 0 {
		t.Fatalf("local session created device record: %v %v", state, err)
	}
	presence := httptest.NewRequest("POST", "/v1/device/presence", strings.NewReader(`{"active":true}`))
	presence.RemoteAddr = "127.0.0.1:9000"
	presence.Header.Set("Authorization", "Bearer temporary-secret")
	response := httptest.NewRecorder()
	h.Handler().ServeHTTP(response, presence)
	if got := response.Code; got != 403 {
		t.Fatalf("local desktop presence status=%d, want 403", got)
	}
}
