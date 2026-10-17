package host

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

// agentland_fetch (docs/HOST-API.md "The chat agent"): the tool server reads
// one public http or https page for a plain chat, on port 80 or 443. It
// resolves the name, refuses every address that is not the public internet's
// (loopback, private, link-local, shared (carrier-grade NAT, Tailscale's
// too), multicast, unspecified, IPv6 unique-local and IANA's other
// special-purpose blocks; an IPv4-mapped address counts as its IPv4 address)
// and this computer's own addresses with every address on the same links
// (its IPv6 /64 among them), and connects to the very address it checked,
// with no second lookup, on every redirect too (at most 5, http and https
// only, never from https to http, without a Referer to another host). Every
// connection that fails or is refused reads the same to the model, so its
// answers say nothing about the network behind the Mac. It refuses URLs with
// user information, reads at most 5 MB after decompression within 30 s, names
// AgentLand in User-Agent, respects robots.txt for that agent, and gives the
// model the page as Markdown of at most 50 KB and 2,000 lines, within
// OpenCode's own limits for a tool's output (50 KiB and 2,000 lines), so it
// passes it on without cutting it.

const (
	webFetchTimeout     = 30 * time.Second
	webFetchBodyLimit   = 5_000_000
	webFetchRedirects   = 5
	webFetchTextLimit   = 50_000
	webFetchLineLimit   = 2000
	webFetchRobotsLimit = 500 << 10
	webFetchHeaderLimit = 64 << 10
	webFetchAgentToken  = "agentland"
)

// webFetchRefusal is a page agentland_fetch will not read, in words for the
// model.
type webFetchRefusal struct{ reason string }

func (e *webFetchRefusal) Error() string { return e.reason }

func refuseFetch(format string, args ...any) error {
	return &webFetchRefusal{reason: fmt.Sprintf(format, args...)}
}

// errFetchUnreachable is every connection that fails or is refused: a name
// that does not resolve, an address agentland_fetch does not reach, a dial
// that fails. One text for all, so the model learns nothing about what lies
// behind the Mac.
var errFetchUnreachable = &webFetchRefusal{reason: "The page could not be reached."}

// webFetchBlocked are the addresses that are not the public internet's:
// IANA's special-purpose blocks that are not globally reachable.
var webFetchBlocked = func() []netip.Prefix {
	var prefixes []netip.Prefix
	for _, prefix := range []string{
		"0.0.0.0/8",       // this network, unspecified
		"10.0.0.0/8",      // private
		"100.64.0.0/10",   // shared address space: carrier-grade NAT, Tailscale
		"127.0.0.0/8",     // loopback
		"169.254.0.0/16",  // link-local
		"172.16.0.0/12",   // private
		"192.0.0.0/24",    // IETF protocol assignments
		"192.0.2.0/24",    // documentation
		"192.88.99.0/24",  // 6to4 relay anycast
		"192.168.0.0/16",  // private
		"198.18.0.0/15",   // benchmarking
		"198.51.100.0/24", // documentation
		"203.0.113.0/24",  // documentation
		"224.0.0.0/4",     // multicast
		"240.0.0.0/4",     // reserved, broadcast
		"::/96",           // unspecified, loopback, IPv4-compatible
		"::ffff:0:0:0/96", // IPv4-translated
		"64:ff9b:1::/48",  // local-use NAT64
		"100::/64",        // discard-only
		"2001::/23",       // IETF protocol assignments: Teredo (2001::/32), benchmarking (2001:2::/48), ORCHID
		"2001:db8::/32",   // documentation
		"3fff::/20",       // documentation
		"5f00::/16",       // segment routing
		"fc00::/7",        // unique local
		"fe80::/10",       // link-local
		"fec0::/10",       // site-local
		"ff00::/8",        // multicast
	} {
		prefixes = append(prefixes, netip.MustParsePrefix(prefix))
	}
	return prefixes
}()

var (
	webFetchNAT64     = netip.MustParsePrefix("64:ff9b::/96")
	webFetchSixToFour = netip.MustParsePrefix("2002::/16")
	// webFetchIPv6Global is the block IANA allocates IPv6 global unicast
	// addresses from.
	webFetchIPv6Global = netip.MustParsePrefix("2000::/3")
)

// embeddedIPv4 is the IPv4 address a NAT64 or 6to4 address carries.
func embeddedIPv4(address netip.Addr) (netip.Addr, bool) {
	if !address.Is6() || address.Is4In6() {
		return netip.Addr{}, false
	}
	bytes := address.As16()
	switch {
	case webFetchNAT64.Contains(address):
		return netip.AddrFrom4([4]byte(bytes[12:16])), true
	case webFetchSixToFour.Contains(address):
		return netip.AddrFrom4([4]byte(bytes[2:6])), true
	}
	return netip.Addr{}, false
}

// publicAddress reports whether an address is on the public internet: an
// IPv4-mapped address counts as its IPv4 address, and so does the IPv4
// address NAT64 and 6to4 addresses carry.
func publicAddress(address netip.Addr) bool {
	address = address.Unmap()
	if !address.IsValid() || address.Zone() != "" {
		return false
	}
	if inner, ok := embeddedIPv4(address); ok {
		return publicAddress(inner) && (webFetchNAT64.Contains(address) || address.IsGlobalUnicast())
	}
	for _, prefix := range webFetchBlocked {
		if prefix.Contains(address) {
			return false
		}
	}
	if address.Is6() && !webFetchIPv6Global.Contains(address) {
		return false
	}
	return address.IsGlobalUnicast()
}

// localPrefixes are this computer's own addresses with their on-link
// prefixes, as its network interfaces carry them.
func localPrefixes() ([]netip.Prefix, error) {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	return interfacePrefixes(addresses), nil
}

// interfacePrefixes lists each interface address itself, and after it its
// on-link prefix when the mask gives a usable one: a /0 (which would take in
// every address) and a mask that is not canonical give the address alone.
func interfacePrefixes(addresses []net.Addr) []netip.Prefix {
	var prefixes []netip.Prefix
	for _, address := range addresses {
		var ip net.IP
		var mask net.IPMask
		switch address := address.(type) {
		case *net.IPNet:
			ip, mask = address.IP, address.Mask
		case *net.IPAddr:
			ip = address.IP
		default:
			continue
		}
		own, ok := netip.AddrFromSlice(ip)
		if !ok {
			continue
		}
		own = own.Unmap().WithZone("")
		prefixes = append(prefixes, netip.PrefixFrom(own, own.BitLen()))
		ones, bits := mask.Size()
		if own.Is4() && bits == 128 {
			ones -= 96
		}
		if bits != 0 && ones > 0 && ones < own.BitLen() {
			prefixes = append(prefixes, netip.PrefixFrom(own, ones).Masked())
		}
	}
	return prefixes
}

// onLocalLink reports whether an address, or the IPv4 address it carries,
// is one of this computer's or on the same link as one of them.
func onLocalLink(address netip.Addr, local []netip.Prefix) bool {
	candidates := []netip.Addr{address.Unmap().WithZone("")}
	if inner, ok := embeddedIPv4(candidates[0]); ok {
		candidates = append(candidates, inner)
	}
	for _, candidate := range candidates {
		for _, prefix := range local {
			if prefix.Contains(candidate) {
				return true
			}
		}
	}
	return false
}

// webFetchPort reports whether agentland_fetch reads from a port: 80 and
// 443 only (the scheme's default when the URL names none).
func webFetchPort(port string) bool {
	return port == "80" || port == "443"
}

// webFetcher reads pages. resolve, dial and interfaces are the network's;
// tests give their own, and every connection goes to an address resolve gave,
// publicAddress passed and interfaces did not name.
type webFetcher struct {
	userAgent  string
	resolve    func(ctx context.Context, host string) ([]netip.Addr, error)
	dial       func(ctx context.Context, network, address string) (net.Conn, error)
	interfaces func() ([]netip.Prefix, error)
	tls        *tls.Config
	timeout    time.Duration
	bodyLimit  int64
}

func newWebFetcher(version string) *webFetcher {
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	return &webFetcher{
		userAgent: "AgentLand/" + version + " (+fetch)",
		resolve: func(ctx context.Context, host string) ([]netip.Addr, error) {
			return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		},
		dial:       dialer.DialContext,
		interfaces: localPrefixes,
		timeout:    webFetchTimeout,
		bodyLimit:  webFetchBodyLimit,
	}
}

// dialChecked resolves the name once, refuses it when any of its addresses is
// not public or on this computer's links, and connects to one of the
// addresses it checked. Every failure is errFetchUnreachable.
func (f *webFetcher) dialChecked(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil || !webFetchPort(port) {
		return nil, errFetchUnreachable
	}
	var addresses []netip.Addr
	if literal, err := netip.ParseAddr(host); err == nil {
		addresses = []netip.Addr{literal}
	} else if addresses, err = f.resolve(ctx, host); err != nil {
		return nil, errFetchUnreachable
	}
	local, err := f.interfaces()
	if len(addresses) == 0 || err != nil {
		return nil, errFetchUnreachable
	}
	for _, candidate := range addresses {
		if !publicAddress(candidate) || onLocalLink(candidate, local) {
			return nil, errFetchUnreachable
		}
	}
	for _, candidate := range addresses {
		if conn, err := f.dial(ctx, network, net.JoinHostPort(candidate.Unmap().String(), port)); err == nil {
			return conn, nil
		}
	}
	return nil, errFetchUnreachable
}

// checkFetchURL refuses what agentland_fetch never reads: another scheme, a
// URL without a host, one with user information, or a port other than 80
// and 443.
func checkFetchURL(address *url.URL) error {
	switch {
	case address.Scheme != "http" && address.Scheme != "https":
		return refuseFetch("agentland_fetch reads only http and https pages.")
	case address.User != nil:
		return refuseFetch("agentland_fetch does not read URLs that carry a user name or password.")
	case address.Host == "" || address.Hostname() == "" || address.Opaque != "":
		return refuseFetch("The URL has no host.")
	case address.Port() != "" && !webFetchPort(address.Port()):
		return refuseFetch("agentland_fetch reads only pages on the web's standard ports, 80 and 443.")
	}
	return nil
}

func (f *webFetcher) client(robots *robotsCache) *http.Client {
	transport := &http.Transport{
		Proxy:                  nil,
		DialContext:            f.dialChecked,
		TLSClientConfig:        f.tls.Clone(),
		TLSHandshakeTimeout:    10 * time.Second,
		MaxResponseHeaderBytes: webFetchHeaderLimit,
		DisableKeepAlives:      true,
		ForceAttemptHTTP2:      true,
	}
	return &http.Client{Transport: transport, CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if len(via) > webFetchRedirects {
			return refuseFetch("The page redirected more than %d times.", webFetchRedirects)
		}
		if err := checkFetchURL(request.URL); err != nil {
			return err
		}
		previous := via[len(via)-1].URL
		if previous.Scheme == "https" && request.URL.Scheme == "http" {
			return refuseFetch("The page redirected from https to http, which agentland_fetch does not follow.")
		}
		// No Referer names one host to another.
		if !strings.EqualFold(previous.Host, request.URL.Host) {
			request.Header.Del("Referer")
		}
		if robots != nil {
			return robots.check(request.Context(), request.URL)
		}
		return nil
	}}
}

// fetchedPage is what agentland_fetch read: its address after redirects, its
// title and its text as Markdown.
type fetchedPage struct {
	URL, Title, Markdown string
	// Partial: the body did not arrive in full (the connection ended, or the
	// deadline passed, while it was read) or went past the size limit, so
	// the text is only the page's start.
	Partial bool
}

// fetch reads one page.
func (f *webFetcher) fetch(ctx context.Context, raw string) (fetchedPage, error) {
	ctx, cancel := context.WithTimeout(ctx, f.timeout)
	defer cancel()
	raw = strings.TrimSpace(raw)
	address, err := url.Parse(raw)
	if err != nil || raw == "" {
		return fetchedPage{}, refuseFetch("That is not a URL.")
	}
	address.Scheme = strings.ToLower(address.Scheme)
	address.Fragment, address.RawFragment = "", ""
	if err := checkFetchURL(address); err != nil {
		return fetchedPage{}, err
	}
	robots := &robotsCache{fetcher: f, rules: map[string]robotsRules{}}
	if err := robots.check(ctx, address); err != nil {
		return fetchedPage{}, fetchFailure(ctx, err)
	}
	request, err := http.NewRequestWithContext(ctx, "GET", address.String(), nil)
	if err != nil {
		return fetchedPage{}, refuseFetch("That is not a URL.")
	}
	request.Header.Set("User-Agent", f.userAgent)
	request.Header.Set("Accept", "text/html, application/xhtml+xml, text/plain;q=0.9, text/markdown;q=0.9, application/json;q=0.8, */*;q=0.1")
	response, err := f.client(robots).Do(request)
	if err != nil {
		return fetchedPage{}, fetchFailure(ctx, err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return fetchedPage{}, refuseFetch("The page answered HTTP %d.", response.StatusCode)
	}
	final := *response.Request.URL
	final.Fragment, final.RawFragment = "", ""
	if encoding := strings.ToLower(strings.TrimSpace(response.Header.Get("Content-Encoding"))); encoding != "" && encoding != "identity" && !response.Uncompressed {
		return fetchedPage{}, refuseFetch("The page is compressed as %s, which agentland_fetch cannot read.", encoding)
	}
	// A body that ends early (a lost connection, the deadline) or goes past
	// the limit is kept as the page's start, marked Partial.
	body, err := io.ReadAll(io.LimitReader(response.Body, f.bodyLimit+1))
	partial := err != nil || int64(len(body)) > f.bodyLimit
	body = body[:min(int64(len(body)), f.bodyLimit)]
	if err != nil && len(body) == 0 {
		return fetchedPage{}, fetchFailure(ctx, err)
	}
	mediaType, params, _ := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if mediaType == "" {
		mediaType, params, _ = mime.ParseMediaType(http.DetectContentType(body))
	}
	page := fetchedPage{URL: final.String(), Partial: partial}
	switch {
	case mediaType == "text/html" || mediaType == "application/xhtml+xml":
		text := decodeWebText(body, params["charset"], true)
		if page.Title, page.Markdown, err = htmlToMarkdown(ctx, text, &final, webFetchTextLimit*2); err != nil {
			return fetchedPage{}, fetchFailure(ctx, err)
		}
	case strings.HasPrefix(mediaType, "text/") || mediaType == "application/json" || mediaType == "application/xml" ||
		strings.HasSuffix(mediaType, "+json") || strings.HasSuffix(mediaType, "+xml"):
		page.Markdown = strings.TrimSpace(decodeWebText(body, params["charset"], false))
	default:
		return fetchedPage{}, refuseFetch("The page is %s, which agentland_fetch cannot read as text.", mediaType)
	}
	return page, nil
}

// fetchFailure says in words why a page could not be read.
func fetchFailure(ctx context.Context, err error) error {
	var refusal *webFetchRefusal
	if errors.As(err, &refusal) {
		return refusal
	}
	if errors.Is(err, context.DeadlineExceeded) || ctx.Err() != nil {
		return refuseFetch("The page did not answer within %d seconds.", int(webFetchTimeout.Seconds()))
	}
	var certificate *tls.CertificateVerificationError
	if errors.As(err, &certificate) {
		return refuseFetch("The page's HTTPS certificate is not valid.")
	}
	return errFetchUnreachable
}

// decodeWebText returns text as UTF-8: UTF-8 (the default) as it is, with
// invalid bytes replaced, and Latin-1 and windows-1252 converted. An HTML
// page may name its charset in a meta tag.
func decodeWebText(body []byte, charset string, html bool) string {
	charset = strings.ToLower(strings.TrimSpace(charset))
	if charset == "" && html {
		charset = htmlMetaCharset(body)
	}
	switch charset {
	case "iso-8859-1", "latin1", "l1", "iso8859-1", "windows-1252", "cp1252", "us-ascii", "ascii":
		if !utf8.Valid(body) {
			return windows1252(body)
		}
	}
	return strings.ToValidUTF8(string(body), "�")
}

// htmlMetaCharset finds <meta charset="…"> or a Content-Type meta in the
// first 1,024 bytes.
func htmlMetaCharset(body []byte) string {
	head := strings.ToLower(string(body[:min(len(body), 1024)]))
	index := strings.Index(head, "charset=")
	if index < 0 {
		return ""
	}
	value := strings.TrimLeft(head[index+len("charset="):], `"' `)
	end := strings.IndexAny(value, `"'; >/`)
	if end < 0 {
		return ""
	}
	return value[:end]
}

// windows1252 decodes windows-1252, which browsers use for Latin-1 pages too.
func windows1252(body []byte) string {
	high := [32]rune{0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
		0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178}
	var out strings.Builder
	out.Grow(len(body))
	for _, b := range body {
		if b >= 0x80 && b < 0xA0 {
			out.WriteRune(high[b-0x80])
		} else {
			out.WriteRune(rune(b))
		}
	}
	return out.String()
}

// fetchToolText is what the model gets: the page's title and address, then
// its text, within 50 KB and 2,000 lines, inside OpenCode's own limits for a
// tool's output (50 KiB and 2,000 lines), so OpenCode never cuts it. A page
// that did not arrive in full, or is longer than that, ends with a note that
// the text is only its start.
func fetchToolText(page fetchedPage, title string) string {
	body := page.Markdown
	if body == "" {
		body = "(The page has no text.)"
	}
	text := "Title: " + title + "\nURL: " + page.URL + "\n\n" + body
	if page.Partial {
		text += "\n\n[The page was cut short: only its start could be read.]"
	}
	// OpenCode counts lines as the text's line breaks plus one.
	if len(text) <= webFetchTextLimit && strings.Count(text, "\n") < webFetchLineLimit {
		return text
	}
	const cut = "\n\n[The page continues; this is its start.]"
	kept, _ := clipText(text, webFetchTextLimit-len(cut))
	breaks, room := 0, webFetchLineLimit-1-strings.Count(cut, "\n")
	for index := 0; index < len(kept); index++ {
		if kept[index] != '\n' {
			continue
		}
		if breaks == room {
			kept = kept[:index]
			break
		}
		breaks++
	}
	return strings.TrimRight(kept, " \n") + cut
}
