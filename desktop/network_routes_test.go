package host

import (
	"context"
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeTailscale is a Tailscale command line whose answer the test sets: it
// records its arguments and environment, then prints dir/output and exits
// with dir/code, or sleeps when dir/sleep exists.
type fakeTailscale struct {
	dir  string
	path string
}

func newFakeTailscale(t *testing.T) *fakeTailscale {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("uses a shell script")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "tailscale")
	script := "#!/bin/sh\n" +
		"echo \"$@\" > '" + dir + "/arguments'\n" +
		"/usr/bin/env > '" + dir + "/environment'\n" +
		"if [ -f '" + dir + "/sleep' ]; then exec /bin/sleep 5; fi\n" +
		"/bin/cat '" + dir + "/output'\n" +
		"exit \"$(/bin/cat '" + dir + "/code')\"\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	fake := &fakeTailscale{dir: dir, path: path}
	fake.answer(t, "", 0)
	return fake
}

func (f *fakeTailscale) answer(t *testing.T, output string, code int) {
	t.Helper()
	os.Remove(filepath.Join(f.dir, "sleep"))
	if err := os.WriteFile(filepath.Join(f.dir, "output"), []byte(output), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.dir, "code"), []byte(strconv.Itoa(code)), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (f *fakeTailscale) hang(t *testing.T) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.dir, "sleep"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func (f *fakeTailscale) recorded(t *testing.T, name string) string {
	t.Helper()
	data, _ := os.ReadFile(filepath.Join(f.dir, name))
	return string(data)
}

const runningStatus = `{"Version":"1.90.0","BackendState":"Running","TailscaleIPs":["100.88.12.34","fd7a:115c:a1e0::1"],
 "Self":{"HostName":"Robins-Mac-mini","DNSName":"Robins-Mac-mini.tail1a2b3c.ts.net.","TailscaleIPs":["100.88.12.34","fd7a:115c:a1e0::1"]},
 "Peer":{"nodekey:1":{"DNSName":"phone.tail1a2b3c.ts.net.","TailscaleIPs":["100.64.0.2"]}}}`

func shortTailscaleTimeout(t *testing.T) {
	t.Helper()
	previous := tailscaleStatusTimeout
	tailscaleStatusTimeout = 400 * time.Millisecond
	t.Cleanup(func() { tailscaleStatusTimeout = previous })
}

func TestRunningTailscaleGivesItsNameAndAddressesFromTheStatusAlone(t *testing.T) {
	fake := newFakeTailscale(t)
	fake.answer(t, runningStatus, 0)
	t.Setenv("AGENTLAND_OPENCODE_PASSWORD", "secret-password")
	t.Setenv("AGENTLAND_LOCAL_SESSION_TOKEN", "secret-token")
	state, route := readTailscaleRoute(context.Background(), RouteOptions{Port: 9841, ListenHost: "0.0.0.0", TailscaleCLI: fake.path})
	if state != tailscaleRunning || route == nil {
		t.Fatalf("state %v route %+v", state, route)
	}
	want := hostRoute{Kind: "tailscale", Host: "robins-mac-mini.tail1a2b3c.ts.net", Addresses: []string{"100.88.12.34", "fd7a:115c:a1e0::1"}, Port: 9841}
	if got, _ := json.Marshal(route); string(got) != string(mustJSON(t, want)) {
		t.Fatalf("route %s, want %s", got, mustJSON(t, want))
	}
	if arguments := strings.TrimSpace(fake.recorded(t, "arguments")); arguments != "status --json --peers=false" {
		t.Fatalf("the host ran %q; it only ever reads this computer's status", arguments)
	}
	environment := fake.recorded(t, "environment")
	if strings.Contains(environment, "secret-password") || strings.Contains(environment, "secret-token") {
		t.Fatalf("the host's secrets reached the Tailscale command line: %s", environment)
	}
	if !strings.Contains(environment, "TAILSCALE_BE_CLI=1") {
		t.Fatalf("the Mac app's executable must run as the command line: %s", environment)
	}
}

func TestStoppedLoggedOutOrUnreachableTailscaleGivesNoRoute(t *testing.T) {
	fake := newFakeTailscale(t)
	options := RouteOptions{Port: 9841, ListenHost: "0.0.0.0", TailscaleCLI: fake.path}
	for _, backend := range []string{"Stopped", "NeedsLogin", "Starting"} {
		fake.answer(t, strings.Replace(runningStatus, `"Running"`, `"`+backend+`"`, 1), 0)
		if state, route := readTailscaleRoute(context.Background(), options); state != tailscaleOff || route != nil {
			t.Fatalf("%s: state %v route %+v", backend, state, route)
		}
	}
	// The command line could not reach Tailscale (it is not running).
	fake.answer(t, "failed to connect to local tailscaled\n", 1)
	if state, route := readTailscaleRoute(context.Background(), options); state != tailscaleOff || route != nil {
		t.Fatalf("exit 1: state %v route %+v", state, route)
	}
}

func TestMissingTailscaleCommandLineGivesNoRoute(t *testing.T) {
	previous := tailscaleCLIPaths
	tailscaleCLIPaths = []string{filepath.Join(t.TempDir(), "Tailscale"), filepath.Join(t.TempDir(), "tailscale")}
	t.Cleanup(func() { tailscaleCLIPaths = previous })
	if state, route := readTailscaleRoute(context.Background(), RouteOptions{Port: 9841}); state != tailscaleNotFound || route != nil {
		t.Fatalf("standard places: state %v route %+v", state, route)
	}
	configured := RouteOptions{Port: 9841, TailscaleCLI: filepath.Join(t.TempDir(), "missing")}
	if state, route := readTailscaleRoute(context.Background(), configured); state != tailscaleNotFound || route != nil {
		t.Fatalf("configured: state %v route %+v", state, route)
	}
}

func TestUnreadableOrSlowStatusKeepsTheLastRoute(t *testing.T) {
	shortTailscaleTimeout(t)
	fake := newFakeTailscale(t)
	fake.answer(t, "not json", 0)
	advertiser := newRouteAdvertiser(RouteOptions{AdvertisedHost: "Robins-Mac-mini.local.", Port: 9841, ListenHost: "0.0.0.0", TailscaleCLI: fake.path})
	kinds := func() string {
		routes, state := advertiser.routes(context.Background())
		names := []string{string(state)}
		for _, route := range routes {
			names = append(names, route.Kind+"="+route.Host)
		}
		return strings.Join(names, ",")
	}
	if got := kinds(); got != "unknown,local=robins-mac-mini.local" {
		t.Fatalf("before any reading: %s", got)
	}
	advertiser.refresh()
	if got := kinds(); got != "unknown,local=robins-mac-mini.local" {
		t.Fatalf("a first reading that could not be read says so: %s", got)
	}
	fake.answer(t, runningStatus, 0)
	const both = "running,local=robins-mac-mini.local,tailscale=robins-mac-mini.tail1a2b3c.ts.net"
	advertiser.refresh()
	if got := kinds(); got != both {
		t.Fatalf("routes %s", got)
	}
	for _, bad := range []string{"not json", `{"Self":{}}`, `[1,2]`} {
		fake.answer(t, bad, 0)
		advertiser.refresh()
		if got := kinds(); got != both {
			t.Fatalf("after %q: %s", bad, got)
		}
	}
	fake.hang(t)
	started := time.Now()
	advertiser.refresh()
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("a hung command line held the reading for %v", elapsed)
	}
	if got := kinds(); got != both {
		t.Fatalf("after a timeout: %s", got)
	}
	fake.answer(t, strings.Replace(runningStatus, `"Running"`, `"Stopped"`, 1), 0)
	advertiser.refresh()
	if got := kinds(); got != "off,local=robins-mac-mini.local" {
		t.Fatalf("after Tailscale stopped: %s", got)
	}
	// Running, but the listener is bound to an address Tailscale does not have.
	fake.answer(t, runningStatus, 0)
	bound := newRouteAdvertiser(RouteOptions{AdvertisedHost: "mac.local", Port: 9841, ListenHost: "192.168.1.20", TailscaleCLI: fake.path})
	bound.refresh()
	if routes, state := bound.routes(context.Background()); state != tailscaleNotListening || len(routes) != 1 {
		t.Fatalf("a listener Tailscale cannot reach: %v %+v", state, routes)
	}
}

func TestOnlyAddressesTheListenerAcceptsAreRoutes(t *testing.T) {
	addresses := []netip.Addr{netip.MustParseAddr("100.88.12.34"), netip.MustParseAddr("fd7a:115c:a1e0::1")}
	for listen, want := range map[string]int{"": 2, "0.0.0.0": 2, "::": 2, "[::]": 2, "100.88.12.34": 1, "192.168.1.20": 0, "localhost": 0} {
		if got := listenerAccepts(listen, addresses); len(got) != want {
			t.Fatalf("%q accepts %v, want %d", listen, got, want)
		}
	}
	status := tailscaleStatus{BackendState: "Running"}
	status.Self = &struct {
		DNSName      string   `json:"DNSName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
	}{DNSName: "", TailscaleIPs: []string{"100.88.12.34", "bad", "fe80::1%en0"}}
	route := tailscaleRoute(status, RouteOptions{Port: 9841, ListenHost: "0.0.0.0"})
	if route == nil || route.Host != "100.88.12.34" || len(route.Addresses) != 1 {
		t.Fatalf("a route without a name is named by its address: %+v", route)
	}
	if tailscaleRoute(status, RouteOptions{Port: 9841, ListenHost: "192.168.1.20"}) != nil {
		t.Fatal("a listener on another address is not reachable through Tailscale")
	}
}

func TestCapabilitiesListRoutesOnlyWithAnAdvertisedHost(t *testing.T) {
	plain, store, agent := testHost(t)
	w := request(t, plain.Handler(), "GET", "/v1/capabilities", paired(t, plain, store), nil)
	if strings.Contains(w.Body.String(), `"routes"`) {
		t.Fatalf("a host without an advertised name lists routes: %s", w.Body.String())
	}
	fake := newFakeTailscale(t)
	fake.answer(t, runningStatus, 0)
	// The first capabilities answer waits for the first reading.
	if err := os.WriteFile(fake.path, []byte("#!/bin/sh\n/bin/sleep 0.3\n/bin/cat '"+fake.dir+"/output'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	routed := NewWithOptions(store, agent, HostOptions{Routes: &RouteOptions{AdvertisedHost: "Robins-Mac-mini.local", Port: 9841, ListenHost: "0.0.0.0", TailscaleCLI: fake.path}})
	defer routed.Close()
	w = request(t, routed.Handler(), "GET", "/v1/capabilities", paired(t, routed, store), nil)
	var body struct {
		Routes    []hostRoute `json:"routes"`
		Tailscale string      `json:"tailscale"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	want := `[{"kind":"local","host":"robins-mac-mini.local","port":9841},{"kind":"tailscale","host":"robins-mac-mini.tail1a2b3c.ts.net","addresses":["100.88.12.34","fd7a:115c:a1e0::1"],"port":9841}]`
	if got := string(mustJSON(t, body.Routes)); got != want || body.Tailscale != "running" {
		t.Fatalf("routes %s (%s)\nwant %s", got, body.Tailscale, want)
	}
	if w := request(t, routed.Handler(), "GET", "/v1/capabilities", "", nil); w.Code != 401 {
		t.Fatalf("routes are for paired devices only: %d", w.Code)
	}
}

func TestRouteOptionsAreValidated(t *testing.T) {
	for _, options := range []RouteOptions{
		{AdvertisedHost: "", Port: 9841},
		{AdvertisedHost: "https://mac.local", Port: 9841},
		{AdvertisedHost: "mac.local:9841", Port: 9841},
		{AdvertisedHost: "mac.local", Port: 0},
		{AdvertisedHost: "mac.local", Port: 9841, TailscaleCLI: "tailscale"},
	} {
		if ValidateRouteOptions(options) == nil {
			t.Fatalf("%+v was accepted", options)
		}
	}
	if err := ValidateRouteOptions(RouteOptions{AdvertisedHost: "Robins-Mac-mini.local", Port: 9841, TailscaleCLI: "/usr/local/bin/tailscale"}); err != nil {
		t.Fatal(err)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
