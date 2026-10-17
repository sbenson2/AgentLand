package host

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
	"unicode/utf8"
)

// The host's HTTP client for the registry, icons and agent downloads
// (docs/HOST-API.md "Agents"). It sends a plain User-Agent and nothing about
// the owner or the Mac, keeps no cookies, and follows redirects only to https.

const (
	agentRegistryWait = 30 * time.Second
	agentIconLimit    = 256 << 10
	// agentIconCacheLimit bounds all the icons kept in <state>.agents/.icons.
	agentIconCacheLimit = 64 << 20
	agentIconWait       = 15 * time.Second
	agentArchiveLimit   = 500 << 20
	agentDownloadWait   = 30 * time.Minute
)

var (
	errAgentNotHTTPS  = errors.New("only https addresses are fetched")
	errAgentTooLarge  = errors.New("the answer is larger than the host takes")
	errAgentBadStatus = errors.New("the server did not answer with the file")
	errAgentIconKind  = errors.New("the icon is neither SVG nor PNG")
)

// agentStatusError is an answer other than 200, with its status.
type agentStatusError struct{ status int }

func (e agentStatusError) Error() string {
	return fmt.Sprintf("%s (HTTP %d)", errAgentBadStatus, e.status)
}

func (e agentStatusError) Unwrap() error { return errAgentBadStatus }

// agentFetcher performs the catalog's requests.
type agentFetcher struct {
	client    *http.Client
	userAgent string
}

// newAgentFetcher uses transport (nil: a fresh default transport) with the
// https-only redirect policy.
func newAgentFetcher(transport http.RoundTripper, version string) *agentFetcher {
	if transport == nil {
		base := http.DefaultTransport.(*http.Transport).Clone()
		transport = base
	}
	if version == "" {
		version = "dev"
	}
	client := &http.Client{Transport: transport, CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if request.URL.Scheme != "https" {
			return errAgentNotHTTPS
		}
		return nil
	}}
	return &agentFetcher{client: client, userAgent: "AgentLand-host/" + version}
}

func (f *agentFetcher) request(ctx context.Context, address string) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	if request.URL.Scheme != "https" {
		return nil, errAgentNotHTTPS
	}
	request.Header.Set("User-Agent", f.userAgent)
	return request, nil
}

// fetchRegistry reads the registry document. With an ETag it asks
// If-None-Match, and a 304 answers notModified.
func (f *agentFetcher) fetchRegistry(ctx context.Context, address, etag string) (data []byte, newETag string, notModified bool, err error) {
	ctx, cancel := context.WithTimeout(ctx, agentRegistryWait)
	defer cancel()
	request, err := f.request(ctx, address)
	if err != nil {
		return nil, "", false, err
	}
	request.Header.Set("Accept", "application/json")
	if etag != "" {
		request.Header.Set("If-None-Match", etag)
	}
	response, err := f.client.Do(request)
	if err != nil {
		return nil, "", false, err
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case http.StatusNotModified:
		return nil, etag, true, nil
	case http.StatusOK:
	default:
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return nil, "", false, fmt.Errorf("%w (HTTP %d)", errAgentBadStatus, response.StatusCode)
	}
	data, err = io.ReadAll(io.LimitReader(response.Body, agentRegistryLimit+1))
	if err != nil {
		return nil, "", false, err
	}
	if len(data) > agentRegistryLimit {
		return nil, "", false, errAgentTooLarge
	}
	newETag = response.Header.Get("ETag")
	if len(newETag) > 256 || !utf8.ValidString(newETag) {
		newETag = ""
	}
	return data, newETag, false, nil
}

// fetchIcon reads an icon: at most 256 KiB, kept only as SVG or PNG.
func (f *agentFetcher) fetchIcon(ctx context.Context, address string) ([]byte, string, error) {
	ctx, cancel := context.WithTimeout(ctx, agentIconWait)
	defer cancel()
	request, err := f.request(ctx, address)
	if err != nil {
		return nil, "", err
	}
	request.Header.Set("Accept", "image/svg+xml, image/png")
	response, err := f.client.Do(request)
	if err != nil {
		return nil, "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, "", agentStatusError{response.StatusCode}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, agentIconLimit+1))
	if err != nil {
		return nil, "", err
	}
	if len(data) > agentIconLimit {
		return nil, "", errAgentTooLarge
	}
	kind := agentIconKind(data)
	if kind == "" {
		return nil, "", errAgentIconKind
	}
	return data, kind, nil
}

// iconGone reports a failed icon read that asking again would not change:
// a file refused by size or kind, a redirect to http, or a 4xx answer other
// than 408 and 429.
func iconGone(err error) bool {
	var status agentStatusError
	if errors.As(err, &status) {
		return status.status >= 400 && status.status < 500 && status.status != http.StatusRequestTimeout && status.status != http.StatusTooManyRequests
	}
	return errors.Is(err, errAgentTooLarge) || errors.Is(err, errAgentIconKind) || errors.Is(err, errAgentNotHTTPS)
}

// agentIconKind is "png" for a PNG signature, "svg" for UTF-8 text that
// holds an <svg element, else "".
func agentIconKind(data []byte) string {
	if bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")) {
		return "png"
	}
	if utf8.Valid(data) && bytes.Contains(bytes.ToLower(data), []byte("<svg")) {
		return "svg"
	}
	return ""
}

// downloadProgressEvery is the shortest time between two reports of a
// download's progress.
const downloadProgressEvery = 500 * time.Millisecond

// downloadProgress reports how much of a download has arrived: when it
// starts, then at most every downloadProgressEvery, and when it ends. total
// is -1 when the server did not say. Its writes come from one goroutine.
type downloadProgress struct {
	report          func(received, total int64)
	total, received int64
	now             func() time.Time
	last            time.Time
	reported        int64
}

func newDownloadProgress(report func(received, total int64), total int64, now func() time.Time) *downloadProgress {
	if total < 0 {
		total = -1
	}
	p := &downloadProgress{report: report, total: total, now: now, last: now()}
	report(0, total)
	return p
}

func (p *downloadProgress) Write(data []byte) (int, error) {
	p.received += int64(len(data))
	if now := p.now(); now.Sub(p.last) >= downloadProgressEvery {
		p.last, p.reported = now, p.received
		p.report(p.received, p.total)
	}
	return len(data), nil
}

// finish reports the end, unless the last report said it.
func (p *downloadProgress) finish() {
	if p.reported != p.received || p.received == 0 {
		p.reported = p.received
		p.report(p.received, p.total)
	}
}

// download writes address into target (created 0600) and returns its
// SHA-256. More than limit bytes, or more time than the context allows,
// fails. progress, when not nil, hears how much has arrived
// (downloadProgress).
func (f *agentFetcher) download(ctx context.Context, address, target string, limit int64, progress func(received, total int64)) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, agentDownloadWait)
	defer cancel()
	request, err := f.request(ctx, address)
	if err != nil {
		return "", err
	}
	response, err := f.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w (HTTP %d)", errAgentBadStatus, response.StatusCode)
	}
	if response.ContentLength > limit {
		return "", errAgentTooLarge
	}
	file, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	destination := io.MultiWriter(file, hash)
	var counter *downloadProgress
	if progress != nil {
		counter = newDownloadProgress(progress, response.ContentLength, time.Now)
		destination = io.MultiWriter(file, hash, counter)
	}
	written, copyErr := io.Copy(destination, io.LimitReader(response.Body, limit+1))
	closeErr := file.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if written > limit {
		return "", errAgentTooLarge
	}
	if counter != nil {
		counter.finish()
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
