package host

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Routes (docs/HOST-API.md, "Routes"): the ways a paired device can reach
// this host, listed in GET /v1/capabilities. The local route is the name the
// host is advertised by on the local network. The Tailscale route comes from
// reading `tailscale status --json` at start and every five minutes; the host
// never runs another subcommand and never changes Tailscale. Devices reach
// every route with the certificate they paired with, validated for the name
// they paired with, so a route is a way in, never a new identity.

// RouteOptions turns route advertising on (serve --advertised-host).
type RouteOptions struct {
	// AdvertisedHost is the name devices on the local network reach this
	// host by: the Mac's Bonjour name.
	AdvertisedHost string
	// Port is the listener's port. ListenHost is its host: empty or a
	// wildcard for every address, otherwise the one address it accepts.
	Port       int
	ListenHost string
	// TailscaleCLI is the Tailscale command line to read. Empty looks in
	// the standard install locations (tailscaleCLIPaths).
	TailscaleCLI string
}

// hostRoute is one entry of capabilities.routes.
type hostRoute struct {
	Kind      string   `json:"kind"`
	Host      string   `json:"host"`
	Addresses []string `json:"addresses,omitempty"`
	Port      int      `json:"port"`
}

// tailscaleCLIPaths are where the Tailscale command line is installed: the
// Mac app's own executable (in /Applications or this user's ~/Applications),
// then Homebrew's on Apple silicon and Intel.
var tailscaleCLIPaths = func() []string {
	paths := []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale"}
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(home, "/") {
		paths = append(paths, filepath.Join(home, "Applications", "Tailscale.app", "Contents", "MacOS", "Tailscale"))
	}
	return append(paths, "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale")
}()

// Detection bounds; tests shorten them.
var (
	tailscaleStatusTimeout   = 4 * time.Second
	tailscaleRefreshInterval = 5 * time.Minute
)

const (
	// tailscaleStatusOutputCap bounds what is read of the status. With
	// --peers=false it describes this computer alone, a few kilobytes.
	tailscaleStatusOutputCap = 1 << 20
	// maxRouteAddresses bounds the addresses of one route.
	maxRouteAddresses = 4
)

// tailscaleState is what one reading of the status says; capabilities
// report it beside the routes as "tailscale".
type tailscaleState string

const (
	// tailscaleUnknown: the reading failed (it timed out, or its output
	// could not be read). The last known route and state stay; before any
	// reading succeeded the state is unknown.
	tailscaleUnknown tailscaleState = "unknown"
	// tailscaleNotFound: no Tailscale command line in the known places.
	tailscaleNotFound tailscaleState = "notFound"
	// tailscaleOff: the command line could not reach Tailscale, or
	// Tailscale does not run. No route.
	tailscaleOff tailscaleState = "off"
	// tailscaleNotListening: Tailscale runs, but the listener accepts none
	// of its addresses (it is bound to another one). No route.
	tailscaleNotListening tailscaleState = "notListening"
	// tailscaleRunning: Tailscale runs; the route is the one read.
	tailscaleRunning tailscaleState = "running"
)

// routeAdvertiser keeps the host's routes: the fixed local one and the
// Tailscale one it reads now and then.
type routeAdvertiser struct {
	options RouteOptions
	every   time.Duration

	mu        sync.Mutex
	tailscale *hostRoute
	state     tailscaleState
	// checked closes once the first reading finished, so the first
	// capabilities answer already knows whether Tailscale runs.
	checked   chan struct{}
	stop      chan struct{}
	done      chan struct{}
	started   bool
	closeOnce sync.Once
}

func newRouteAdvertiser(options RouteOptions) *routeAdvertiser {
	options.AdvertisedHost = normalizedRouteHost(options.AdvertisedHost)
	return &routeAdvertiser{options: options, every: tailscaleRefreshInterval, state: tailscaleUnknown,
		checked: make(chan struct{}), stop: make(chan struct{}), done: make(chan struct{})}
}

// start reads Tailscale's status now and then every interval until close.
func (a *routeAdvertiser) start() {
	a.mu.Lock()
	a.started = true
	a.mu.Unlock()
	go func() {
		defer close(a.done)
		a.refresh()
		close(a.checked)
		ticker := time.NewTicker(a.every)
		defer ticker.Stop()
		for {
			select {
			case <-a.stop:
				return
			case <-ticker.C:
				a.refresh()
			}
		}
	}()
}

func (a *routeAdvertiser) close() {
	if a == nil {
		return
	}
	a.closeOnce.Do(func() {
		close(a.stop)
		a.mu.Lock()
		started := a.started
		a.mu.Unlock()
		if started {
			<-a.done
		}
	})
}

// refresh reads the status once. A reading that failed keeps the last route,
// so one slow answer does not take the route away from devices.
func (a *routeAdvertiser) refresh() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		select {
		case <-a.stop:
			cancel()
		case <-ctx.Done():
		}
	}()
	state, route := readTailscaleRoute(ctx, a.options)
	if state == tailscaleUnknown {
		return
	}
	a.mu.Lock()
	a.tailscale, a.state = route, state
	a.mu.Unlock()
}

// routes lists the local route, then the Tailscale route while Tailscale
// runs, and what the last reading said of Tailscale. Before the first reading
// has finished it waits for it, bounded by the reading's own timeout, or
// until ctx ends.
func (a *routeAdvertiser) routes(ctx context.Context) ([]hostRoute, tailscaleState) {
	if a == nil {
		return nil, ""
	}
	a.mu.Lock()
	started := a.started
	a.mu.Unlock()
	if started {
		wait := time.NewTimer(tailscaleStatusTimeout + 2*time.Second)
		select {
		case <-a.checked:
		case <-ctx.Done():
		case <-wait.C:
		}
		wait.Stop()
	}
	var result []hostRoute
	if a.options.AdvertisedHost != "" {
		result = append(result, hostRoute{Kind: "local", Host: a.options.AdvertisedHost, Port: a.options.Port})
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.tailscale != nil {
		route := *a.tailscale
		route.Addresses = append([]string(nil), a.tailscale.Addresses...)
		result = append(result, route)
	}
	return result, a.state
}

// tailscaleCLI finds the command line: the configured one, or the first
// standard location that holds an executable file.
func tailscaleCLI(configured string) (string, bool) {
	candidates := tailscaleCLIPaths
	if configured != "" {
		candidates = []string{configured}
	}
	for _, path := range candidates {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return path, true
		}
	}
	return "", false
}

// tailscaleStatus is the part of `tailscale status --json` a route needs.
type tailscaleStatus struct {
	BackendState string   `json:"BackendState"`
	TailscaleIPs []string `json:"TailscaleIPs"`
	Self         *struct {
		DNSName      string   `json:"DNSName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
	} `json:"Self"`
}

// readTailscaleRoute runs `tailscale status --json --peers=false` once:
// this computer's status only, never the other devices of the tailnet,
// bounded in time and output, with an environment that carries none of the
// host's secrets.
func readTailscaleRoute(ctx context.Context, options RouteOptions) (tailscaleState, *hostRoute) {
	path, found := tailscaleCLI(options.TailscaleCLI)
	if !found {
		return tailscaleNotFound, nil
	}
	ctx, cancel := context.WithTimeout(ctx, tailscaleStatusTimeout)
	defer cancel()
	output := &cappedOutput{limit: tailscaleStatusOutputCap}
	command := exec.CommandContext(ctx, path, "status", "--json", "--peers=false")
	command.Env = tailscaleEnvironment()
	command.Stdout = output
	command.WaitDelay = time.Second
	err := command.Run()
	if ctx.Err() != nil {
		return tailscaleUnknown, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		// The command line answered: it could not reach a running Tailscale.
		return tailscaleOff, nil
	}
	if err != nil || output.truncated {
		return tailscaleUnknown, nil
	}
	var status tailscaleStatus
	if json.Unmarshal(output.data, &status) != nil || status.BackendState == "" {
		return tailscaleUnknown, nil
	}
	if status.BackendState != "Running" {
		return tailscaleOff, nil
	}
	route := tailscaleRoute(status, options)
	if route == nil {
		return tailscaleNotListening, nil
	}
	return tailscaleRunning, route
}

// tailscaleEnvironment is what the command line needs to find Tailscale for
// this user: the home folder and user name, never the host's passwords or
// session tokens. TAILSCALE_BE_CLI keeps the Mac app's executable a command
// line when it is not run from a terminal.
func tailscaleEnvironment() []string {
	env := []string{"LC_ALL=C", "TAILSCALE_BE_CLI=1"}
	for _, key := range []string{"HOME", "USER", "LOGNAME", "TMPDIR"} {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return env
}

// tailscaleRoute is the route a running Tailscale gives: its MagicDNS name
// without the trailing dot and the addresses this host's listener accepts.
// Nil when the listener accepts none of them.
func tailscaleRoute(status tailscaleStatus, options RouteOptions) *hostRoute {
	raw := status.TailscaleIPs
	name := ""
	if status.Self != nil {
		name = status.Self.DNSName
		if len(status.Self.TailscaleIPs) > 0 {
			raw = status.Self.TailscaleIPs
		}
	}
	var addresses []netip.Addr
	for _, value := range raw {
		if address, err := netip.ParseAddr(value); err == nil && address.Zone() == "" && !address.IsUnspecified() {
			addresses = append(addresses, address.Unmap())
		}
		if len(addresses) == maxRouteAddresses {
			break
		}
	}
	addresses = listenerAccepts(options.ListenHost, addresses)
	if len(addresses) == 0 {
		return nil
	}
	route := &hostRoute{Kind: "tailscale", Host: normalizedRouteHost(name), Port: options.Port}
	for _, address := range addresses {
		route.Addresses = append(route.Addresses, address.String())
	}
	if route.Host == "" {
		route.Host = route.Addresses[0]
	}
	return route
}

// listenerAccepts keeps the addresses the listener takes connections on. A
// wildcard listener takes them all: Go listens on both address families for
// either wildcard. A listener on one address takes only that one, and one on
// a name is not known to take any.
func listenerAccepts(listenHost string, addresses []netip.Addr) []netip.Addr {
	host := strings.Trim(listenHost, "[]")
	if host == "" {
		return addresses
	}
	listen, err := netip.ParseAddr(host)
	if err != nil {
		return nil
	}
	if listen.IsUnspecified() {
		return addresses
	}
	for _, address := range addresses {
		if address == listen.Unmap() {
			return []netip.Addr{address}
		}
	}
	return nil
}

// normalizedRouteHost is a DNS name in lower case without a trailing dot, or
// an IP address; anything else is empty.
func normalizedRouteHost(value string) string {
	value = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), "."))
	if address, err := netip.ParseAddr(strings.Trim(value, "[]")); err == nil && address.Zone() == "" {
		return address.Unmap().String()
	}
	if len(value) == 0 || len(value) > 253 {
		return ""
	}
	for _, label := range strings.Split(value, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return ""
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return ""
			}
		}
	}
	return value
}

// ValidateRouteOptions checks serve's route settings before anything opens.
func ValidateRouteOptions(options RouteOptions) error {
	if normalizedRouteHost(options.AdvertisedHost) == "" {
		return errors.New("--advertised-host must be a DNS name or IP address without a scheme, path or port")
	}
	if options.Port < 1 || options.Port > 65535 {
		return fmt.Errorf("the listener's port %d cannot be advertised", options.Port)
	}
	if options.TailscaleCLI != "" && !strings.HasPrefix(options.TailscaleCLI, "/") {
		return errors.New("--tailscale-cli must be an absolute path")
	}
	return nil
}
