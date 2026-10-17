package host

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// agentland_fetch (web_fetch.go, web_robots.go, web_markdown.go) against
// local test servers. Names resolve through a fake resolver to addresses the
// test chooses, and the dial it records goes to the local server, so the
// checks run on the addresses a real lookup would give.

func TestPublicAddress(t *testing.T) {
	for _, blocked := range []string{
		"127.0.0.1", "127.8.9.10", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.100.100.100", "100.127.255.255",
		"169.254.169.254", "224.0.0.1", "239.255.255.250", "255.255.255.255", "240.0.0.1", "0.0.0.0", "0.1.2.3", "198.18.0.1", "192.0.0.8",
		"::", "::1", "fc00::1", "fd7a:115c:a1e0::1", "fe80::1", "fe80::1%en0", "fec0::1", "ff02::1", "::127.0.0.1",
		"::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254", "::ffff:100.64.0.1", "::ffff:192.168.0.1",
		"64:ff9b::a00:1", "64:ff9b::7f00:1", "64:ff9b:1::1", "2002:c0a8:101::1", "2002:7f00:1::1",
		// IANA's other special-purpose blocks: documentation, 6to4 relays (and
		// their 6to4 address), IPv4-translated, discard-only, Teredo,
		// benchmarking, segment routing, and IPv6 outside global unicast.
		"192.0.2.1", "198.51.100.1", "203.0.113.5", "192.88.99.1", "2002:c058:6301::1", "::ffff:0:7f00:1", "::ffff:0:5db8:d822",
		"100::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2", "2001:2::1", "2001:db8::1", "3fff::1", "5f00::1", "4000::1", "64:ff9b::cb00:7105",
	} {
		if publicAddress(netip.MustParseAddr(blocked)) {
			t.Errorf("%s counts as public", blocked)
		}
	}
	for _, public := range []string{"93.184.216.34", "1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e", "::ffff:93.184.216.34", "64:ff9b::5db8:d822", "2002:5db8:d822::1"} {
		if !publicAddress(netip.MustParseAddr(public)) {
			t.Errorf("%s does not count as public", public)
		}
	}
}

// fetchNetwork resolves names from a table (a name may answer differently
// each time) and records what it resolved and dialed; every dial reaches the
// local server. local are the addresses and on-link prefixes the fetcher sees
// as this computer's.
type fetchNetwork struct {
	mu      sync.Mutex
	answers map[string][][]string // name → the answer to each lookup; the last repeats
	lookups []string
	dialed  []string
	server  string
	local   []netip.Prefix
}

func (n *fetchNetwork) fetcher(t *testing.T) *webFetcher {
	t.Helper()
	fetcher := newWebFetcher("test")
	fetcher.resolve = func(_ context.Context, host string) ([]netip.Addr, error) {
		n.mu.Lock()
		defer n.mu.Unlock()
		n.lookups = append(n.lookups, host)
		answers := n.answers[host]
		if len(answers) == 0 {
			return nil, fmt.Errorf("no such host %s", host)
		}
		answer := answers[0]
		if len(answers) > 1 {
			n.answers[host] = answers[1:]
		}
		var addresses []netip.Addr
		for _, value := range answer {
			addresses = append(addresses, netip.MustParseAddr(value))
		}
		return addresses, nil
	}
	fetcher.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		n.mu.Lock()
		n.dialed = append(n.dialed, address)
		n.mu.Unlock()
		var dialer net.Dialer
		return dialer.DialContext(ctx, network, n.server)
	}
	fetcher.interfaces = func() ([]netip.Prefix, error) {
		n.mu.Lock()
		defer n.mu.Unlock()
		return n.local, nil
	}
	return fetcher
}

func (n *fetchNetwork) record() ([]string, []string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]string(nil), n.lookups...), append([]string(nil), n.dialed...)
}

// newFetchServer serves handler on loopback, and a network whose names
// answer public addresses by default.
func newFetchServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *fetchNetwork) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server, &fetchNetwork{server: server.Listener.Addr().String(), answers: map[string][][]string{
		"pages.example": {{"93.184.215.10"}}, "other.example": {{"93.184.215.20"}}}}
}

func TestFetchReadsAPublicPageAsMarkdown(t *testing.T) {
	var agents []string
	var mu sync.Mutex
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		agents = append(agents, r.URL.Path+" "+r.Header.Get("User-Agent"))
		mu.Unlock()
		switch r.URL.Path {
		case "/robots.txt":
			fmt.Fprint(w, "User-agent: *\nDisallow: /private\n")
		case "/tides":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, `<!doctype html><html><head><title>Lisbon  tides &amp; times</title><style>p{}</style><script>alert("x")</script></head>
<body><nav><a href="/">Home</a></nav><h1>Tides</h1><p>High tide is at <strong>06:12</strong>, see <a href="/table?day=1#top">the table</a>.</p>
<ul><li>Morning</li><li>Evening<ol start="3"><li>late</li></ol></li></ul><pre>  06:12  high
  12:30  low</pre><p hidden>secret</p><footer>© Tides</footer></body></html>`)
		}
	})
	page, err := network.fetcher(t).fetch(t.Context(), "http://pages.example/tides#section")
	if err != nil {
		t.Fatal(err)
	}
	want := "# Tides\n\nHigh tide is at **06:12**, see [the table](http://pages.example/table?day=1).\n\n- Morning\n- Evening\n  3. late\n\n```\n  06:12  high\n  12:30  low\n```"
	if page.URL != "http://pages.example/tides" || page.Title != "Lisbon tides & times" || page.Markdown != want {
		t.Fatalf("page %+v\nmarkdown %q\nwant     %q", page, page.Markdown, want)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(agents) != 2 || agents[0] != "/robots.txt AgentLand/test (+fetch)" || agents[1] != "/tides AgentLand/test (+fetch)" {
		t.Fatalf("requests %v", agents)
	}
	// What the model gets: the title and address, then the page.
	text := fetchToolText(page, page.Title)
	if !strings.HasPrefix(text, "Title: Lisbon tides & times\nURL: http://pages.example/tides\n\n# Tides\n") {
		t.Fatalf("tool text %q", text)
	}
}

func TestFetchRefusesNonPublicAddresses(t *testing.T) {
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "reached") })
	network.answers["loopback.example"] = [][]string{{"127.0.0.1"}}
	network.answers["mapped.example"] = [][]string{{"::ffff:192.168.1.1"}}
	network.answers["unique-local.example"] = [][]string{{"fd00::5"}}
	network.answers["tailnet.example"] = [][]string{{"100.101.102.103"}}
	network.answers["mixed.example"] = [][]string{{"93.184.215.30", "10.0.0.8"}}
	network.answers["teredo.example"] = [][]string{{"2001:0:4136:e378:8000:63bf:3fff:fdd2"}}
	network.answers["documentation.example"] = [][]string{{"203.0.113.9"}}
	network.answers["empty.example"] = [][]string{{}}
	fetcher := network.fetcher(t)
	// Every address it does not reach, and a name that does not resolve,
	// reads the same.
	for _, address := range []string{
		"http://loopback.example/", "http://mapped.example/", "http://unique-local.example/", "http://tailnet.example/", "http://mixed.example/",
		"http://teredo.example/", "http://documentation.example/", "http://empty.example/", "http://missing.example/",
		"http://127.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://[fe80::1]/", "http://169.254.169.254/latest/meta-data/", "http://0.0.0.0/",
	} {
		if _, err := fetcher.fetch(t.Context(), address); err == nil || err.Error() != "The page could not be reached." {
			t.Errorf("%s: %v", address, err)
		}
	}
	for _, address := range []string{"ftp://pages.example/", "file:///etc/passwd", "http://user:secret@pages.example/", "http://@pages.example/", "gopher://pages.example/", "not a url", "/relative"} {
		if _, err := fetcher.fetch(t.Context(), address); err == nil {
			t.Errorf("%s was read", address)
		}
	}
	if _, dialed := network.record(); len(dialed) != 0 {
		t.Fatalf("dialed %v", dialed)
	}
	// A connection that fails reads the same too.
	failing := network.fetcher(t)
	failing.dial = func(context.Context, string, string) (net.Conn, error) { return nil, errors.New("connection refused") }
	if _, err := failing.fetch(t.Context(), "http://pages.example/"); err == nil || err.Error() != "The page could not be reached." {
		t.Fatalf("a refused connection: %v", err)
	}
}

// This computer's own addresses, and every address on the same links (the
// Mac's IPv6 /64 among them), are refused like private ones, NAT64 and 6to4
// addresses by the IPv4 address they carry.
func TestFetchRefusesThisComputersLinks(t *testing.T) {
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, "reached")
	})
	network.local = []netip.Prefix{netip.MustParsePrefix("2606:4700:10::/64"), netip.MustParsePrefix("93.184.200.7/32"), netip.MustParsePrefix("1.2.3.0/24")}
	network.answers["neighbour.example"] = [][]string{{"2606:4700:10::99"}}
	network.answers["self.example"] = [][]string{{"93.184.200.7"}}
	network.answers["subnet.example"] = [][]string{{"1.2.3.200"}}
	network.answers["nat64.example"] = [][]string{{"64:ff9b::5db8:c807"}}
	network.answers["sixtofour.example"] = [][]string{{"2002:5db8:c807::1"}}
	network.answers["elsewhere.example"] = [][]string{{"2606:4700:11::1"}}
	fetcher := network.fetcher(t)
	for _, address := range []string{"http://neighbour.example/", "http://self.example/", "http://subnet.example/", "http://nat64.example/", "http://sixtofour.example/", "http://[2606:4700:10::1]/"} {
		if _, err := fetcher.fetch(t.Context(), address); err == nil || err.Error() != "The page could not be reached." {
			t.Errorf("%s: %v", address, err)
		}
	}
	if _, dialed := network.record(); len(dialed) != 0 {
		t.Fatalf("dialed %v", dialed)
	}
	if page, err := fetcher.fetch(t.Context(), "http://elsewhere.example/"); err != nil || page.Markdown != "reached" {
		t.Fatalf("a public address off the Mac's links: %+v %v", page, err)
	}
	// When the Mac's addresses cannot be listed, nothing is reached.
	blind := network.fetcher(t)
	blind.interfaces = func() ([]netip.Prefix, error) { return nil, errors.New("no interfaces") }
	if _, err := blind.fetch(t.Context(), "http://elsewhere.example/"); err == nil || err.Error() != "The page could not be reached." {
		t.Fatalf("without the interfaces: %v", err)
	}
	// The real list holds loopback, with its prefix.
	local, err := localPrefixes()
	if err != nil || !slices.ContainsFunc(local, func(prefix netip.Prefix) bool { return prefix.Contains(netip.MustParseAddr("127.0.0.1")) }) {
		t.Fatalf("this computer's prefixes %v %v", local, err)
	}
}

// Each interface address is in the list itself, whatever its mask; its
// on-link prefix too when the mask is a usable one (not /0, canonical).
func TestInterfacePrefixesKeepEveryOwnAddress(t *testing.T) {
	network := func(ip string, mask net.IPMask) net.Addr { return &net.IPNet{IP: net.ParseIP(ip), Mask: mask} }
	got := interfacePrefixes([]net.Addr{
		network("192.0.2.10", net.CIDRMask(24, 32)),                                                  // an ordinary /24
		network("93.184.200.7", net.CIDRMask(0, 32)),                                                 // a /0: the address alone
		network("93.184.200.8", net.IPv4Mask(255, 0, 255, 0)),                                        // not canonical: the address alone
		network("93.184.200.9", net.CIDRMask(120, 128)),                                              // IPv4 in 16 bytes with a /120 (a /24)
		network("2606:4700:10::5", net.CIDRMask(64, 128)),                                            // IPv6 /64
		network("2606:4700:11::5", net.CIDRMask(0, 128)),                                             // IPv6 /0
		network("2606:4700:12::5", net.IPMask{0xff, 0, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}), // not canonical
		network("2606:4700:13::5", nil),                                                              // no mask
		&net.IPAddr{IP: net.ParseIP("93.184.200.10")},                                                // an address without a mask
		&net.UnixAddr{Name: "/tmp/socket", Net: "unix"},                                              // not an IP address
	})
	var shown []string
	for _, prefix := range got {
		shown = append(shown, prefix.String())
	}
	want := []string{"192.0.2.10/32", "192.0.2.0/24", "93.184.200.7/32", "93.184.200.8/32", "93.184.200.9/32", "93.184.200.0/24",
		"2606:4700:10::5/128", "2606:4700:10::/64", "2606:4700:11::5/128", "2606:4700:12::5/128", "2606:4700:13::5/128", "93.184.200.10/32"}
	if !slices.Equal(shown, want) {
		t.Fatalf("prefixes %v\nwant     %v", shown, want)
	}
}

// Pages are read on ports 80 and 443 only, redirects included.
func TestFetchReadsOnlyTheWebsPorts(t *testing.T) {
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/robots.txt":
			http.NotFound(w, r)
		case "/go":
			http.Redirect(w, r, r.URL.Query().Get("to"), http.StatusFound)
		default:
			fmt.Fprint(w, "page")
		}
	})
	fetcher := network.fetcher(t)
	for _, address := range []string{"http://pages.example:8080/", "http://pages.example:22/", "https://pages.example:8443/",
		"http://pages.example/go?to=" + url.QueryEscape("http://other.example:3000/")} {
		if _, err := fetcher.fetch(t.Context(), address); err == nil || !strings.Contains(err.Error(), "ports, 80 and 443") {
			t.Errorf("%s: %v", address, err)
		}
	}
	if page, err := fetcher.fetch(t.Context(), "http://pages.example:80/page"); err != nil || page.Markdown != "page" {
		t.Fatalf("port 80: %+v %v", page, err)
	}
	if page, err := fetcher.fetch(t.Context(), "http://pages.example:443/page"); err != nil || page.Markdown != "page" {
		t.Fatalf("port 443: %+v %v", page, err)
	}
	for _, dialed := range network.dialed {
		if !strings.HasSuffix(dialed, ":80") && !strings.HasSuffix(dialed, ":443") {
			t.Fatalf("dialed %s", dialed)
		}
	}
}

// A redirect never goes from https to http, and no Referer names one host to
// another.
func TestFetchRedirectsKeepHTTPSAndNoCrossHostReferer(t *testing.T) {
	var mu sync.Mutex
	referers := map[string]string{}
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/robots.txt":
			http.NotFound(w, r)
		case "/go":
			http.Redirect(w, r, r.URL.Query().Get("to"), http.StatusFound)
		default:
			mu.Lock()
			referers[r.Host+r.URL.Path] = r.Header.Get("Referer")
			mu.Unlock()
			fmt.Fprint(w, "page")
		}
	})
	fetcher := network.fetcher(t)
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/go?to="+url.QueryEscape("http://other.example/away")); err != nil {
		t.Fatal(err)
	}
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/go?to="+url.QueryEscape("/here")); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	if referers["other.example/away"] != "" || !strings.HasPrefix(referers["pages.example/here"], "http://pages.example/go") {
		t.Errorf("referers %v", referers)
	}
	mu.Unlock()

	secure := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		http.Redirect(w, r, "http://example.com/plain", http.StatusFound)
	}))
	defer secure.Close()
	pool := x509.NewCertPool()
	pool.AddCert(secure.Certificate())
	tlsNetwork := &fetchNetwork{server: secure.Listener.Addr().String(), answers: map[string][][]string{"example.com": {{"93.184.215.60"}}}}
	tlsFetcher := tlsNetwork.fetcher(t)
	tlsFetcher.tls = &tls.Config{RootCAs: pool}
	if _, err := tlsFetcher.fetch(t.Context(), "https://example.com/down"); err == nil || !strings.Contains(err.Error(), "from https to http") {
		t.Fatalf("https to http: %v", err)
	}
}

func TestFetchDialsTheAddressItChecked(t *testing.T) {
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, "public page")
	})
	// A name that answers a public address, then a private one: each
	// connection looks the name up once and dials exactly what it checked.
	network.answers["rebind.example"] = [][]string{{"93.184.215.40"}, {"127.0.0.1"}}
	fetcher := network.fetcher(t)
	_, err := fetcher.fetch(t.Context(), "http://rebind.example/page")
	if err == nil || err.Error() != "The page could not be reached." {
		t.Fatalf("a name that turned private was read: %v", err)
	}
	lookups, dialed := network.record()
	if len(lookups) != 2 || len(dialed) != 1 || !strings.HasPrefix(dialed[0], "93.184.215.40:") {
		t.Fatalf("lookups %v, dialed %v", lookups, dialed)
	}
	// And a name that stays public is read, one lookup per connection.
	network.answers["steady.example"] = [][]string{{"2606:4700:4700::1111"}, {"93.184.215.41"}}
	network.mu.Lock()
	network.lookups, network.dialed = nil, nil
	network.mu.Unlock()
	if page, err := fetcher.fetch(t.Context(), "http://steady.example/page"); err != nil || page.Markdown != "public page" {
		t.Fatalf("steady: %+v %v", page, err)
	}
	lookups, dialed = network.record()
	if len(lookups) != 2 || len(dialed) != 2 || dialed[0] != "[2606:4700:4700::1111]:80" || dialed[1] != "93.184.215.41:80" {
		t.Fatalf("lookups %v, dialed %v", lookups, dialed)
	}
}

func TestFetchChecksEveryRedirect(t *testing.T) {
	server, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/robots.txt":
			http.NotFound(w, r)
		case strings.HasPrefix(r.URL.Path, "/hop/"):
			var hop int
			fmt.Sscanf(r.URL.Path, "/hop/%d", &hop)
			if hop == 0 {
				fmt.Fprint(w, "arrived")
				return
			}
			http.Redirect(w, r, fmt.Sprintf("/hop/%d", hop-1), http.StatusFound)
		default:
			http.Redirect(w, r, r.URL.Query().Get("to"), http.StatusFound)
		}
	})
	network.answers["internal.example"] = [][]string{{"10.0.0.5"}}
	fetcher := network.fetcher(t)
	for _, target := range []string{"ftp://pages.example/file", "http://127.0.0.1:" + strings.Split(server.Listener.Addr().String(), ":")[1] + "/", "http://internal.example/admin",
		"http://user:pw@other.example/", "file:///etc/hosts", "http://[::ffff:10.0.0.1]/"} {
		_, err := fetcher.fetch(t.Context(), "http://pages.example/go?to="+url.QueryEscape(target))
		if err == nil {
			t.Errorf("a redirect to %s was followed", target)
		}
	}
	if page, err := fetcher.fetch(t.Context(), "http://pages.example/hop/5"); err != nil || page.Markdown != "arrived" {
		t.Fatalf("five redirects: %+v %v", page, err)
	}
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/hop/6"); err == nil || !strings.Contains(err.Error(), "redirected more than 5 times") {
		t.Fatalf("six redirects: %v", err)
	}
	// The address a page ends at is its source.
	if page, err := fetcher.fetch(t.Context(), "http://pages.example/go?to="+url.QueryEscape("http://other.example/hop/0")); err != nil || page.URL != "http://other.example/hop/0" {
		t.Fatalf("redirected page %+v %v", page, err)
	}
	for _, dialed := range network.dialed {
		if strings.HasPrefix(dialed, "10.") || strings.HasPrefix(dialed, "127.") || strings.Contains(dialed, "ffff") {
			t.Fatalf("dialed %s", dialed)
		}
	}
}

func TestFetchCapsDecompressedSize(t *testing.T) {
	var bomb bytes.Buffer
	writer := gzip.NewWriter(&bomb)
	chunk := bytes.Repeat([]byte("a"), 1<<20)
	for range 20 {
		writer.Write(chunk)
	}
	writer.Close()
	if bomb.Len() > 256<<10 {
		t.Fatalf("the compressed body is %d bytes", bomb.Len())
	}
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/robots.txt":
			http.NotFound(w, r)
		case "/bomb":
			w.Header().Set("Content-Type", "text/plain")
			w.Header().Set("Content-Encoding", "gzip")
			w.Write(bomb.Bytes())
		case "/brotli":
			w.Header().Set("Content-Type", "text/html")
			w.Header().Set("Content-Encoding", "br")
			w.Write([]byte{0x1b, 0x03})
		case "/image":
			w.Header().Set("Content-Type", "image/png")
			w.Write([]byte("\x89PNG\r\n"))
		case "/latin":
			w.Header().Set("Content-Type", "text/plain; charset=windows-1252")
			w.Write([]byte("caf\xe9 \x93quoted\x94"))
		}
	})
	fetcher := network.fetcher(t)
	page, err := fetcher.fetch(t.Context(), "http://pages.example/bomb")
	if err != nil || len(page.Markdown) != webFetchBodyLimit {
		t.Fatalf("a 20 MiB page after decompression gave %d bytes (%v)", len(page.Markdown), err)
	}
	if text := fetchToolText(page, "Bomb"); len(text) > webFetchTextLimit || strings.Count(text, "\n") >= webFetchLineLimit || !strings.HasSuffix(text, "[The page continues; this is its start.]") {
		t.Fatalf("tool text of %d bytes", len(text))
	}
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/brotli"); err == nil || !strings.Contains(err.Error(), "compressed as br") {
		t.Fatalf("br: %v", err)
	}
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/image"); err == nil || !strings.Contains(err.Error(), "image/png") {
		t.Fatalf("image: %v", err)
	}
	if page, err := fetcher.fetch(t.Context(), "http://pages.example/latin"); err != nil || page.Markdown != "café “quoted”" {
		t.Fatalf("windows-1252: %q %v", page.Markdown, err)
	}
}

// A body that did not arrive in full (the connection ended, the deadline
// passed while it was read, or it passed the size limit) is only the page's
// start, and the model is told so.
func TestFetchMarksPagesCutShort(t *testing.T) {
	const partialNote = "\n\n[The page was cut short: only its start could be read.]"
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		kind, ending, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
		switch {
		case kind == "robots.txt" && r.Host == "cut.example":
			// A robots.txt whose connection ends before its rules do.
			w.Header().Set("Content-Length", "100000")
			w.WriteHeader(200)
			fmt.Fprint(w, "User-agent: *\nAllow: /public\n")
			w.(http.Flusher).Flush()
			if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
				conn.Close()
			}
			return
		case kind == "robots.txt":
			http.NotFound(w, r)
			return
		}
		switch kind {
		case "html":
			w.Header().Set("Content-Type", "text/html")
		case "json":
			w.Header().Set("Content-Type", "application/json")
		default:
			w.Header().Set("Content-Type", "text/plain")
		}
		body := map[string]string{"text": "first part", "html": "<p>first part</p>", "json": `{"first": "part"`}[kind]
		if ending == "whole" {
			fmt.Fprint(w, body)
			return
		}
		w.Header().Set("Content-Length", "100000")
		w.WriteHeader(200)
		fmt.Fprint(w, body)
		w.(http.Flusher).Flush()
		switch ending {
		case "reset":
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				conn.Close()
			}
		case "stall":
			<-r.Context().Done()
		}
	})
	fetcher := network.fetcher(t)
	fetcher.timeout = 500 * time.Millisecond
	for _, check := range []struct {
		path, markdown string
	}{
		{"/text/reset", "first part"},
		{"/text/stall", "first part"},
		{"/json/reset", `{"first": "part"`},
		{"/json/stall", `{"first": "part"`},
		{"/html/reset", "first part"},
	} {
		page, err := fetcher.fetch(t.Context(), "http://pages.example"+check.path)
		if err != nil || page.Markdown != check.markdown || !page.Partial {
			t.Fatalf("%s: %+v %v", check.path, page, err)
		}
		if text := fetchToolText(page, "Cut"); !strings.HasSuffix(text, check.markdown+partialNote) {
			t.Fatalf("%s: tool text %q", check.path, text)
		}
	}
	// An HTML page the deadline cut cannot be converted within it.
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/html/stall"); err == nil || !strings.Contains(err.Error(), "did not answer within") {
		t.Fatalf("an HTML page the deadline cut: %v", err)
	}
	// A whole page carries no note.
	for _, kind := range []string{"text", "html", "json"} {
		page, err := fetcher.fetch(t.Context(), "http://pages.example/"+kind+"/whole")
		if err != nil || page.Partial || strings.Contains(fetchToolText(page, "Whole"), "cut short") {
			t.Fatalf("%s whole: %+v %v", kind, page, err)
		}
	}
	// A robots.txt cut short may have lost rules: it disallows everything.
	network.answers["cut.example"] = [][]string{{"93.184.215.70"}}
	if _, err := fetcher.fetch(t.Context(), "http://cut.example/public"); err == nil || !strings.Contains(err.Error(), "robots.txt") {
		t.Fatalf("a robots.txt cut short: %v", err)
	}
	// A body past the size limit is its start.
	fetcher.bodyLimit = 5
	page, err := fetcher.fetch(t.Context(), "http://pages.example/text/whole")
	if err != nil || page.Markdown != "first" || !page.Partial || !strings.HasSuffix(fetchToolText(page, "Long"), "first"+partialNote) {
		t.Fatalf("past the limit: %+v %v", page, err)
	}
}

func TestFetchStopsAtItsTimeout(t *testing.T) {
	release := make(chan struct{})
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	defer close(release)
	fetcher := network.fetcher(t)
	fetcher.timeout = 200 * time.Millisecond
	started := time.Now()
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/slow"); err == nil || !strings.Contains(err.Error(), "did not answer within") {
		t.Fatalf("slow page: %v", err)
	}
	if time.Since(started) > 5*time.Second {
		t.Fatal("the timeout did not stop the read")
	}
}

func TestFetchRespectsRobotsTXT(t *testing.T) {
	robots := map[string]string{}
	status := map[string]int{}
	var mu sync.Mutex
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/robots.txt":
			if code := status[r.Host]; code != 0 {
				w.WriteHeader(code)
				return
			}
			fmt.Fprint(w, robots[r.Host])
		case "/redirect":
			http.Redirect(w, r, r.URL.Query().Get("to"), http.StatusFound)
		default:
			fmt.Fprint(w, "page "+r.URL.Path)
		}
	})
	network.answers["closed.example"] = [][]string{{"93.184.215.50"}}
	network.answers["broken.example"] = [][]string{{"93.184.215.51"}}
	network.answers["gone.example"] = [][]string{{"93.184.215.52"}}
	robots["pages.example"] = "# comments\nUser-agent: *\nDisallow: /\n\nUser-agent: AgentLand\nUser-agent: SomeBot\nAllow: /open\nDisallow: /open/secret\nDisallow: /*.pdf$\n"
	robots["other.example"] = "User-agent: *\nDisallow: /\n"
	robots["closed.example"] = "User-agent: agentland/2.0\nDisallow: /\nUser-agent: *\nAllow: /\n"
	status["broken.example"] = 503
	status["gone.example"] = 404
	fetcher := network.fetcher(t)
	for address, allowed := range map[string]bool{
		"http://pages.example/open":             true,
		"http://pages.example/open/page":        true,
		"http://pages.example/open/secret":      false,
		"http://pages.example/open/report.pdf":  false,
		"http://pages.example/open/report.pdfx": true,
		// AgentLand's own group applies, not "*" too.
		"http://pages.example/closed":  true,
		"http://other.example/":        false,
		"http://closed.example/":       false,
		"http://broken.example/":       false,
		"http://gone.example/anything": true,
	} {
		_, err := fetcher.fetch(t.Context(), address)
		if allowed != (err == nil) {
			t.Errorf("%s: %v", address, err)
		}
		if !allowed && err != nil && !strings.Contains(err.Error(), "robots.txt") {
			t.Errorf("%s: %v", address, err)
		}
	}
	// A redirect to a host whose robots.txt forbids it is refused.
	if _, err := fetcher.fetch(t.Context(), "http://gone.example/redirect?to="+url.QueryEscape("http://other.example/page")); err == nil || !strings.Contains(err.Error(), "robots.txt") {
		t.Fatalf("a redirect past robots.txt: %v", err)
	}
	if page, err := fetcher.fetch(t.Context(), "http://gone.example/redirect?to="+url.QueryEscape("http://pages.example/open")); err != nil || page.Markdown != "page /open" {
		t.Fatalf("a redirect robots.txt allows: %+v %v", page, err)
	}
}

func TestFetchHTTPSChecksTheNameItWasGiven(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, "secure")
	}))
	defer server.Close()
	pool := x509.NewCertPool()
	pool.AddCert(server.Certificate())
	network := &fetchNetwork{server: server.Listener.Addr().String(), answers: map[string][][]string{"example.com": {{"93.184.215.60"}}, "wrong.example": {{"93.184.215.61"}}}}
	fetcher := network.fetcher(t)
	fetcher.tls = &tls.Config{RootCAs: pool}
	if page, err := fetcher.fetch(t.Context(), "https://example.com/"); err != nil || page.Markdown != "secure" {
		t.Fatalf("https: %+v %v", page, err)
	}
	// The certificate is checked for the URL's name, not the address dialed.
	if _, err := fetcher.fetch(t.Context(), "https://wrong.example/"); err == nil {
		t.Fatal("a certificate for another name was accepted")
	}
}

// parseTestRobots parses a robots.txt for AgentLand.
func parseTestRobots(t *testing.T, data string) robotsRules {
	t.Helper()
	rules, err := parseRobots(t.Context(), []byte(data), webFetchAgentToken)
	if err != nil {
		t.Fatal(err)
	}
	return rules
}

func robotsAllow(t *testing.T, rules robotsRules, path string) bool {
	t.Helper()
	allowed, err := rules.allowed(t.Context(), path)
	if err != nil {
		t.Fatal(err)
	}
	return allowed
}

func TestParseRobots(t *testing.T) {
	rules := parseTestRobots(t, "User-agent: Googlebot\nDisallow: /\n\nuser-AGENT: AgentLand/1.0\nallow: /a/b\ndisallow: /a\nDisallow:\nDisallow: /x*y$\nDisallow: /s**t*\n")
	for path, allowed := range map[string]bool{"/": true, "/a": false, "/a/b": true, "/a/bc": true, "/a/c": false, "/robots.txt": true, "/x-long-y": false, "/x-long-y/z": true,
		"/st": false, "/s-t-": false, "/s": true} {
		if robotsAllow(t, rules, path) != allowed {
			t.Errorf("%s: allowed %v", path, !allowed)
		}
	}
	// Allow wins a tie; no matching group means the "*" groups.
	if !robotsAllow(t, parseTestRobots(t, "User-agent: *\nDisallow: /page\nAllow: /page\n"), "/page") {
		t.Error("a tie was not allowed")
	}
	if !robotsAllow(t, parseTestRobots(t, "Disallow: /\n"), "/") {
		t.Error("a rule outside a group applied")
	}
	// A group named by several user-agent lines is one group; a rule after
	// its user-agent lines belongs to each group those lines name.
	shared := parseTestRobots(t, "User-agent: other\nUser-agent: AgentLand\nUser-agent: *\nDisallow: /both\n\nUser-agent: *\nDisallow: /star\n")
	if len(shared) != 1 || robotsAllow(t, shared, "/both") || !robotsAllow(t, shared, "/star") {
		t.Fatalf("rules %+v", shared)
	}
}

// A hostile robots.txt costs no more than its size: a group's rules are kept
// once however many user-agent lines name it, a file with more rules for the
// agent than it can honor disallows everything, patterns are split once, and a
// read that ends stops the parse and the match.
func TestRobotsStayWithinTheirLimits(t *testing.T) {
	agents := strings.Repeat("user-agent:*\nUser-agent: AgentLand\n", 4000)
	start := time.Now()
	rules := parseTestRobots(t, agents+strings.Repeat("allow:/x\n", 1000)+"disallow:/private\n")
	if len(rules) != 1001 || robotsAllow(t, rules, "/private") || !robotsAllow(t, rules, "/public") {
		t.Fatalf("%d rules", len(rules))
	}
	for _, over := range []string{
		strings.Repeat("allow:/x\n", robotsRuleLimit+1),
		"disallow:/" + strings.Repeat("a", robotsPatternLimit) + "\n",
		strings.Repeat("disallow:/"+strings.Repeat("*a", 20)+"\n", robotsPartLimit/20+1),
	} {
		if rules := parseTestRobots(t, agents+over); robotsAllow(t, rules, "/public") || len(rules) != 1 {
			t.Fatalf("a robots.txt over the limits kept %d rules", len(rules))
		}
	}
	// The reviewers' file: 4,000 user-agent lines, then 4,000 rules, within
	// robots.txt's 500 KiB.
	flood := strings.Repeat("user-agent:*\n", 4000) + strings.Repeat("allow:x\n", 4000)
	if len(flood) > webFetchRobotsLimit || robotsAllow(t, parseTestRobots(t, flood), "/page") {
		t.Fatal("the flood was honored")
	}
	// Many stars match in time linear in the path.
	stars := parseTestRobots(t, "User-agent: *\nDisallow: /"+strings.Repeat("*a", 1000)+"$\n")
	if robotsAllow(t, stars, "/"+strings.Repeat("a", 999)) != true || robotsAllow(t, stars, "/"+strings.Repeat("ba", 50000)) {
		t.Fatal("stars matched wrongly")
	}
	if took := time.Since(start); took > 5*time.Second {
		t.Fatalf("hostile robots.txt files took %v", took)
	}
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := parseRobots(cancelled, []byte(flood), webFetchAgentToken); !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled parse: %v", err)
	}
	if _, err := stars.allowed(cancelled, "/a"); !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled match: %v", err)
	}
}

func TestHTMLToMarkdown(t *testing.T) {
	base, _ := url.Parse("https://example.com/docs/page.html")
	title, markdown, err := htmlToMarkdown(t.Context(), `<html><head><title>
  Docs&nbsp;page </title></head><body>
<!-- a comment <p>not text</p> -->
<h2>Section <em>one</em></h2>
<p>Read <a href="../guide">the guide</a>, <a href="javascript:alert(1)">not this</a>, <a href="https://example.org/"><img src="x.png"></a>
and <code>go test</code>.</p>
<table><tr><th>Day</th><th>Tide</th></tr><tr><td>Mon</td><td>06:12</td></tr></table>
<blockquote>Quoted</blockquote><hr><p>A&lt;B &amp; &#x263A;</p>
<svg><text>vector</text></svg><div aria-hidden="true">hidden</div>
<nav>unclosed navigation keeps its text
</body></html>`, base, 1<<20)
	want := "## Section *one*\n\nRead [the guide](https://example.com/guide), not this, and `go test`.\n\nDay | Tide\nMon | 06:12\n\n> Quoted\n\n---\n\nA<B & ☺\n\nunclosed navigation keeps its text"
	if err != nil || title != "Docs page" || markdown != want {
		t.Fatalf("title %q\nmarkdown %q\nwant     %q\n%v", title, markdown, want, err)
	}
	// Output stops growing at its limit.
	_, long, _ := htmlToMarkdown(t.Context(), "<p>"+strings.Repeat("word ", 100000)+"</p>", base, 1000)
	if len(long) > 1000 {
		t.Fatalf("%d bytes past a 1000-byte limit", len(long))
	}
	// Empty links are left out, nested ones too, with the text around them;
	// an end tag that closes nothing writes nothing.
	_, links, _ := htmlToMarkdown(t.Context(), `<p>a <a href="/x"> <a href="/y"><br></a> </a>b</i></b></code> <a href="/z">c</a></p>`, base, 1000)
	if links != "a b [c](https://example.com/z)" {
		t.Fatalf("links %q", links)
	}
}

// A hostile page costs linear work: unmatched end tags, empty links, nested
// links, deep nesting, runs of line breaks and floods of tiny tags convert
// well within the read's deadline, and a read that ends stops the conversion.
func TestHTMLToMarkdownStaysLinear(t *testing.T) {
	base, _ := url.Parse("https://example.com/")
	for name, page := range map[string]string{
		"unmatched end tags":          strings.Repeat("<b>", 40000) + strings.Repeat("</i>", 40000),
		"empty links after long text": "<p>" + strings.Repeat("word ", 19000) + "</p>" + strings.Repeat(`<a href=/x> </a>`, 40000),
		"nested links":                strings.Repeat(`<a href=/x>`, 20000) + strings.Repeat("<br>", 20000) + "x" + strings.Repeat("</a>", 20000),
		"line breaks then blocks":     strings.Repeat("<br>", 50000) + strings.Repeat("<p>", 50000),
		"deep nesting":                strings.Repeat("<div><nav>", 30000) + "text" + strings.Repeat("</nav></div>", 30000),
		"tiny tags":                   strings.Repeat("<a>", 1_600_000),
		"attributes":                  strings.Repeat(`<p a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8>`, 100000),
	} {
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		start := time.Now()
		_, markdown, err := htmlToMarkdown(t.Context(), page, base, webFetchTextLimit*2)
		took := time.Since(start)
		runtime.ReadMemStats(&after)
		allocated := after.TotalAlloc - before.TotalAlloc
		t.Logf("%s (%d bytes): %v, %d MB allocated", name, len(page), took, allocated>>20)
		if err != nil || len(markdown) > webFetchTextLimit*2 {
			t.Fatalf("%s: %d bytes, %v", name, len(markdown), err)
		}
		if took > 5*time.Second || allocated > 64<<20 {
			t.Errorf("%s took %v and %d MB", name, took, allocated>>20)
		}
	}
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if _, _, err := htmlToMarkdown(cancelled, "<p>text</p>", base, 1000); !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled conversion: %v", err)
	}
}

// The reviewers' hostile site end to end: a robots.txt flood is refused at
// once, and a hostile page is read well within the deadline.
func TestFetchOfAHostileSiteEndsInTime(t *testing.T) {
	robots := strings.Repeat("User-agent: *\n", 3000) + strings.Repeat("Allow: /x\n", 3000)
	page := strings.Repeat("<span>", 40000) + strings.Repeat("</i>", 40000) + "<p>end</p>"
	_, network := newFetchServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/robots.txt" && r.Host == "pages.example":
			fmt.Fprint(w, robots)
		case r.URL.Path == "/robots.txt":
			http.NotFound(w, r)
		default:
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, page)
		}
	})
	fetcher := network.fetcher(t)
	fetcher.timeout = 5 * time.Second
	start := time.Now()
	if _, err := fetcher.fetch(t.Context(), "http://pages.example/article"); err == nil || !strings.Contains(err.Error(), "robots.txt") {
		t.Fatalf("the flood: %v", err)
	}
	read, err := fetcher.fetch(t.Context(), "http://other.example/article")
	if err != nil || read.Markdown != "end" {
		t.Fatalf("the page: %+v %v", read, err)
	}
	if took := time.Since(start); took > 5*time.Second {
		t.Fatalf("took %v", took)
	}
}
