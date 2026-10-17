package host

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type pulseLine struct {
	Type       string `json:"type"`
	IntervalMs int    `json:"intervalMs"`
	Revision   string `json:"revision"`
}

func openPulse(t *testing.T, base, token string) (*bufio.Scanner, func()) {
	t.Helper()
	req, _ := http.NewRequest("GET", base+"/v1/pulse", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 {
		response.Body.Close()
		t.Fatalf("pulse status %d", response.StatusCode)
	}
	if got := response.Header.Get("Content-Type"); got != "application/x-ndjson" {
		t.Fatalf("pulse content type %q", got)
	}
	return bufio.NewScanner(response.Body), func() { response.Body.Close() }
}

func nextPulse(t *testing.T, lines *bufio.Scanner, within time.Duration) pulseLine {
	t.Helper()
	result := make(chan pulseLine, 1)
	go func() {
		var line pulseLine
		if lines.Scan() {
			_ = json.Unmarshal(lines.Bytes(), &line)
		}
		result <- line
	}()
	select {
	case line := <-result:
		return line
	case <-time.After(within):
		t.Fatalf("no pulse line within %v", within)
		return pulseLine{}
	}
}

func TestPulseStreamsBeatsThenEndsBeforeTheWriteTimeout(t *testing.T) {
	host, store, _ := testHost(t)
	token := paired(t, host, store)
	host.pulseEvery = 20 * time.Millisecond
	host.pulseFor = 110 * time.Millisecond
	server := httptest.NewServer(host.Handler())
	defer server.Close()
	lines, done := openPulse(t, server.URL, token)
	defer done()
	if ready := nextPulse(t, lines, time.Second); ready.Type != "ready" || ready.IntervalMs != 20 {
		t.Fatalf("first pulse line %+v", ready)
	}
	beats := 0
	for {
		line := nextPulse(t, lines, time.Second)
		if line.Type == "end" {
			break
		}
		if line.Type != "beat" {
			t.Fatalf("unexpected pulse line %+v", line)
		}
		beats++
	}
	if beats < 2 {
		t.Fatalf("expected repeated beats before the stream ended, got %d", beats)
	}
	if pulseLifetime >= 35*time.Second || pulseInterval*3 >= pulseLifetime {
		t.Fatal("a pulse must end inside the server write timeout and beat several times")
	}
}

func TestPulseRequiresDeviceAuthentication(t *testing.T) {
	host, store, _ := testHost(t)
	_ = paired(t, host, store)
	if response := request(t, host.Handler(), "GET", "/v1/pulse", "", nil); response.Code != 401 {
		t.Fatalf("unauthenticated pulse: %d", response.Code)
	}
	if response := request(t, host.Handler(), "GET", "/v1/pulse", "not-a-token", nil); response.Code != 401 {
		t.Fatalf("unknown token pulse: %d", response.Code)
	}
}

func TestBeginShutdownReleasesPulsesAndTerminalWaitsImmediately(t *testing.T) {
	host, _, token, _ := terminalTestHost(t, true)
	terminal := createTerminalFixture(t, host, token)
	server := httptest.NewServer(host.Handler())
	defer server.Close()
	lines, done := openPulse(t, server.URL, token)
	defer done()
	if line := nextPulse(t, lines, time.Second); line.Type != "ready" {
		t.Fatalf("first pulse line %+v", line)
	}
	waited := make(chan time.Duration, 1)
	go func() {
		started := time.Now()
		response, err := http.DefaultClient.Do(authorizedGet(server.URL+fmt.Sprintf("/v1/terminal/output?projectId=p1&terminalId=%s&cursor=0&wait=15000", terminal.ID), token))
		if err == nil {
			response.Body.Close()
		}
		waited <- time.Since(started)
	}()
	time.Sleep(80 * time.Millisecond)
	stopped := time.Now()
	host.BeginShutdown()
	host.BeginShutdown()
	if line := nextPulse(t, lines, time.Second); line.Type != "stopping" {
		t.Fatalf("open pulse after shutdown began: %+v", line)
	}
	select {
	case elapsed := <-waited:
		if elapsed > 3*time.Second {
			t.Fatalf("terminal wait outlived shutdown: %v", elapsed)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("terminal long-poll did not end when shutdown began")
	}
	if time.Since(stopped) > 2*time.Second {
		t.Fatal("shutdown notification was not prompt")
	}
	fresh, closeFresh := openPulse(t, server.URL, token)
	defer closeFresh()
	if line := nextPulse(t, fresh, time.Second); line.Type != "stopping" {
		t.Fatalf("a pulse opened while stopping must say so at once: %+v", line)
	}
}

func TestTerminalOutputHoldsUntilNewBytesWithinTheRequestedWait(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	terminal := createTerminalFixture(t, host, token)
	result := make(chan terminalOutput, 1)
	started := time.Now()
	go func() {
		var output terminalOutput
		response := request(t, host.Handler(), "GET", fmt.Sprintf("/v1/terminal/output?projectId=p1&terminalId=%s&cursor=0&wait=10000", terminal.ID), token, nil)
		_ = json.Unmarshal(response.Body.Bytes(), &output)
		result <- output
	}()
	time.Sleep(600 * time.Millisecond)
	fixture.emit(terminal.ID, "echo")
	select {
	case output := <-result:
		elapsed := time.Since(started)
		if string(output.Data) != "echo" || output.Cursor != 4 {
			t.Fatalf("output %+v", output)
		}
		if elapsed < 500*time.Millisecond {
			t.Fatalf("the request returned before any bytes existed: %v", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("new bytes did not release the waiting request")
	}
	if response := request(t, host.Handler(), "GET", fmt.Sprintf("/v1/terminal/output?projectId=p1&terminalId=%s&cursor=4&wait=soon", terminal.ID), token, nil); response.Code != 400 {
		t.Fatalf("invalid wait: %d", response.Code)
	}
	quick := time.Now()
	if response := request(t, host.Handler(), "GET", fmt.Sprintf("/v1/terminal/output?projectId=p1&terminalId=%s&cursor=4&wait=0", terminal.ID), token, nil); response.Code != 200 || time.Since(quick) > 200*time.Millisecond {
		t.Fatalf("wait=0 must answer immediately: %d after %v", response.Code, time.Since(quick))
	}
}

func TestServeContextTellsPulsesTheHostIsStoppingAndDrainsQuickly(t *testing.T) {
	host, store, _ := testHost(t)
	token := paired(t, host, store)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() {
		served <- ServeContext(ctx, host.Handler(), ListenOptions{Address: address, DevelopmentHTTP: true, OnShutdown: host.BeginShutdown})
	}()
	base := "http://" + address
	deadline := time.Now().Add(5 * time.Second)
	for {
		if response, err := http.Get(base + "/v1/health"); err == nil {
			response.Body.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("server did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	lines, done := openPulse(t, base, token)
	defer done()
	if line := nextPulse(t, lines, time.Second); line.Type != "ready" {
		t.Fatalf("first pulse line %+v", line)
	}
	began := time.Now()
	cancel()
	if line := nextPulse(t, lines, 2*time.Second); line.Type != "stopping" {
		t.Fatalf("pulse during graceful shutdown: %+v", line)
	}
	select {
	case err := <-served:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			t.Fatal(err)
		}
		if time.Since(began) > 4*time.Second {
			t.Fatalf("shutdown waited on a pulse: %v", time.Since(began))
		}
	case <-time.After(8 * time.Second):
		t.Fatal("graceful shutdown did not finish")
	}
	if _, err := http.Get(base + "/v1/health"); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("stopped host still answered: %v", err)
	}
}

func authorizedGet(url, token string) *http.Request {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}

// A host with remote access names the revision of capabilities.remoteAccess
// right after ready and again whenever it changes, so a connected device reads
// capabilities again when the Mac's switch, addresses or relay change.
func TestPulseAnnouncesRemoteAccessChanges(t *testing.T) {
	h, store := remoteHost(t)
	token, _ := pairWithNode(t, h, store, "Phone", nil)
	h.pulseEvery = time.Hour
	server := httptest.NewServer(h.Handler())
	defer server.Close()
	revision := func() string {
		var out struct {
			RemoteAccess struct {
				Revision string `json:"revision"`
			} `json:"remoteAccess"`
		}
		json.Unmarshal(request(t, h.Handler(), "GET", "/v1/capabilities", token, nil).Body.Bytes(), &out)
		return out.RemoteAccess.Revision
	}
	lines, done := openPulse(t, server.URL, token)
	defer done()
	if line := nextPulse(t, lines, time.Second); line.Type != "ready" {
		t.Fatalf("first pulse line %+v", line)
	}
	first := nextPulse(t, lines, time.Second)
	if first.Type != "remoteAccess" || first.Revision == "" || first.Revision != revision() {
		t.Fatalf("second pulse line %+v, capabilities' revision %s", first, revision())
	}
	mac := newNodeKey(t)
	report := func(body map[string]any) {
		t.Helper()
		if w := macRequest(t, h, "POST", "/v1/remote-access/endpoint", body); w.Code != 200 {
			t.Fatalf("report: %d %s", w.Code, w.Body.String())
		}
	}
	report(map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38842, "directAddresses": []string{"1.2.3.4:38842"}})
	on := nextPulse(t, lines, time.Second)
	if on.Type != "remoteAccess" || on.Revision == first.Revision || on.Revision != revision() {
		t.Fatalf("after the switch went on: %+v, capabilities' revision %s", on, revision())
	}
	// A report that changes nothing devices see (the bound port) says nothing;
	// the next change is the next line.
	report(map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38843, "directAddresses": []string{"1.2.3.4:38842"}})
	report(map[string]any{"enabled": true, "nodeId": mac.id, "udpPort": 38843, "directAddresses": []string{"5.6.7.8:40000"}})
	moved := nextPulse(t, lines, time.Second)
	if moved.Type != "remoteAccess" || moved.Revision == on.Revision || moved.Revision != revision() {
		t.Fatalf("after the address changed: %+v, capabilities' revision %s", moved, revision())
	}

	// A host without remote access sends no such line.
	plain, plainStore, _ := testHost(t)
	plainToken := paired(t, plain, plainStore)
	plain.pulseEvery = 20 * time.Millisecond
	plainServer := httptest.NewServer(plain.Handler())
	defer plainServer.Close()
	plainLines, plainDone := openPulse(t, plainServer.URL, plainToken)
	defer plainDone()
	if line := nextPulse(t, plainLines, time.Second); line.Type != "ready" {
		t.Fatalf("first pulse line %+v", line)
	}
	if line := nextPulse(t, plainLines, time.Second); line.Type != "beat" {
		t.Fatalf("a host without remote access sent %+v", line)
	}
}
