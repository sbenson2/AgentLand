package host

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPairingLimitsDistributedGuessesAndRecoversAfterWindow(t *testing.T) {
	h, _, _ := testHost(t)
	now := time.Unix(1_800_000_000, 0)
	h.now = func() time.Time { return now }
	try := func(client int) int {
		r := httptest.NewRequest("POST", "/v1/pair", strings.NewReader(`{"code":"1234567890","deviceName":"Phone"}`))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = fmt.Sprintf("192.0.2.%d:12345", client)
		w := httptest.NewRecorder()
		h.Handler().ServeHTTP(w, r)
		return w.Code
	}
	for i := 1; i <= 30; i++ {
		if got := try(i); got != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %d", i, got)
		}
	}
	if got := try(31); got != http.StatusTooManyRequests {
		t.Fatalf("a new address bypassed the shared attempt limit: status %d", got)
	}
	now = now.Add(time.Minute)
	if got := try(31); got != http.StatusUnauthorized {
		t.Fatalf("attempts did not recover after the window: %d", got)
	}
}
