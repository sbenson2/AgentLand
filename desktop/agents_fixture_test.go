package host

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Fakes for the agent catalog's tests: a registry served over TLS on
// loopback, commands found only where a test puts them, and archives built in
// memory. No test reads the real registry, runs the owner's commands or
// touches the owner's state.

// failingTransport answers every request with an error at once.
type failingTransport struct{}

func (failingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("no network in tests")
}

// fakeRegistry serves a registry document, icons and archives over TLS, and
// records what it was asked.
type fakeRegistry struct {
	t      *testing.T
	server *httptest.Server

	mu       sync.Mutex
	document []byte
	etag     string
	files    map[string][]byte // path → body
	status   map[string]int    // path → status to answer instead
	headers  []http.Header     // of registry requests
	hits     map[string]int
	redirect map[string]string        // path → Location
	hold     map[string]chan struct{} // path → answered once closed
}

func newFakeRegistry(t *testing.T) *fakeRegistry {
	t.Helper()
	f := &fakeRegistry{t: t, files: map[string][]byte{}, status: map[string]int{}, hits: map[string]int{}, redirect: map[string]string{}, hold: map[string]chan struct{}{}}
	f.server = httptest.NewTLSServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

// holdPath keeps requests for path unanswered until the returned release
// (also called at the test's end) runs.
func (f *fakeRegistry) holdPath(path string) (release func()) {
	gate := make(chan struct{})
	f.mu.Lock()
	f.hold[path] = gate
	f.mu.Unlock()
	var once sync.Once
	release = func() { once.Do(func() { close(gate) }) }
	f.t.Cleanup(release)
	return release
}

func (f *fakeRegistry) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.hits[r.URL.Path]++
	if gate := f.hold[r.URL.Path]; gate != nil {
		f.mu.Unlock()
		select {
		case <-gate:
		case <-r.Context().Done():
			return
		}
		f.mu.Lock()
	}
	if location := f.redirect[r.URL.Path]; location != "" {
		f.mu.Unlock()
		http.Redirect(w, r, location, http.StatusFound)
		return
	}
	if status := f.status[r.URL.Path]; status != 0 {
		f.mu.Unlock()
		w.WriteHeader(status)
		return
	}
	if r.URL.Path == "/registry.json" {
		f.headers = append(f.headers, r.Header.Clone())
		document, etag := f.document, f.etag
		f.mu.Unlock()
		if etag != "" && r.Header.Get("If-None-Match") == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		if etag != "" {
			w.Header().Set("ETag", etag)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(document)
		return
	}
	body, ok := f.files[r.URL.Path]
	f.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	_, _ = w.Write(body)
}

func (f *fakeRegistry) url(path string) string { return f.server.URL + path }

// setAgents serves a registry of these entries (JSON objects).
func (f *fakeRegistry) setAgents(agents ...map[string]any) {
	f.t.Helper()
	document, err := json.Marshal(map[string]any{"version": "1.0.0", "agents": agents, "extensions": []any{}})
	if err != nil {
		f.t.Fatal(err)
	}
	f.mu.Lock()
	f.document = document
	f.etag = fmt.Sprintf(`"%x"`, sha256.Sum256(document))
	f.mu.Unlock()
}

func (f *fakeRegistry) setFile(path string, body []byte) {
	f.mu.Lock()
	f.files[path] = body
	f.mu.Unlock()
}

func (f *fakeRegistry) hitsOf(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[path]
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// archiveEntry is one entry of an archive a test builds.
type archiveEntry struct {
	name     string
	body     string
	mode     int64
	link     string // symbolic link target
	hardlink string // hard link target
	dir      bool
}

func tarGz(t *testing.T, entries ...archiveEntry) []byte {
	t.Helper()
	var buffer bytes.Buffer
	gz := gzip.NewWriter(&buffer)
	writer := tar.NewWriter(gz)
	for _, entry := range entries {
		header := &tar.Header{Name: entry.name, Mode: entry.mode, ModTime: time.Unix(1_700_000_000, 0)}
		switch {
		case entry.dir:
			header.Typeflag = tar.TypeDir
			if header.Mode == 0 {
				header.Mode = 0o755
			}
		case entry.link != "":
			header.Typeflag, header.Linkname = tar.TypeSymlink, entry.link
		case entry.hardlink != "":
			header.Typeflag, header.Linkname = tar.TypeLink, entry.hardlink
		default:
			header.Typeflag, header.Size = tar.TypeReg, int64(len(entry.body))
			if header.Mode == 0 {
				header.Mode = 0o644
			}
		}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeReg {
			if _, err := writer.Write([]byte(entry.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func zipArchive(t *testing.T, entries ...archiveEntry) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for _, entry := range entries {
		header := &zip.FileHeader{Name: entry.name, Method: zip.Deflate}
		switch {
		case entry.dir:
			header.Name = strings.TrimSuffix(entry.name, "/") + "/"
			header.SetMode(0o755 | os.ModeDir)
		case entry.link != "":
			header.SetMode(0o777 | os.ModeSymlink)
		default:
			mode := os.FileMode(entry.mode)
			if mode == 0 {
				mode = 0o644
			}
			header.SetMode(mode)
		}
		file, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		switch {
		case entry.link != "":
			_, err = file.Write([]byte(entry.link))
		case !entry.dir:
			_, err = file.Write([]byte(entry.body))
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// writeScript writes an executable shell script.
func writeScript(t *testing.T, path, body string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}
