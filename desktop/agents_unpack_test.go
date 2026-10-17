package host

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// unpackBytes writes archive bytes to a file and unpacks them into a fresh
// folder, which it returns with the error.
func unpackBytes(t *testing.T, format string, data []byte, limits agentUnpackLimits) (string, error) {
	t.Helper()
	root := t.TempDir()
	archive := filepath.Join(root, "archive")
	if err := os.WriteFile(archive, data, 0o600); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(root, "dest")
	if err := os.Mkdir(dest, 0o700); err != nil {
		t.Fatal(err)
	}
	return dest, unpackAgentArchive(archive, format, dest, limits)
}

func TestUnpackTarGzKeepsWhatIsSafe(t *testing.T) {
	data := tarGz(t,
		archiveEntry{name: "./", dir: true},
		archiveEntry{name: "./bin/", dir: true, mode: 0o777},
		archiveEntry{name: "./bin/agent", body: "#!/bin/sh\n", mode: 0o4755},
		archiveEntry{name: "./README", body: "text", mode: 0o666},
		archiveEntry{name: "./agent", link: "bin/agent"},
		archiveEntry{name: "Versions/A/lib.dylib", body: "lib"},
		archiveEntry{name: "Versions/Current", link: "A"},
		archiveEntry{name: "copy", hardlink: "README"},
		// A later entry of the same name replaces the earlier.
		archiveEntry{name: "./README", body: "newer", mode: 0o644},
	)
	dest, err := unpackBytes(t, "tar.gz", data, defaultAgentUnpackLimits)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dest, "bin", "agent"))
	if err != nil || info.Mode().Perm() != 0o700 || info.Mode()&os.ModeSetuid != 0 {
		t.Fatalf("executable: %v %v (set-user-ID dropped, 0700)", info.Mode(), err)
	}
	info, err = os.Stat(filepath.Join(dest, "README"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("file: %v %v", info.Mode(), err)
	}
	if data, _ := os.ReadFile(filepath.Join(dest, "README")); string(data) != "newer" {
		t.Fatalf("README %q", data)
	}
	if info, err := os.Stat(filepath.Join(dest, "bin")); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("folder: %v %v", info.Mode(), err)
	}
	if target, err := os.Readlink(filepath.Join(dest, "agent")); err != nil || target != "bin/agent" {
		t.Fatalf("link: %q %v", target, err)
	}
	if data, err := os.ReadFile(filepath.Join(dest, "Versions", "Current", "lib.dylib")); err != nil || string(data) != "lib" {
		t.Fatalf("a link to a folder inside: %q %v", data, err)
	}
	if command, err := resolveAgentCmd(dest, "agent"); err != nil || command != filepath.Join(dest, "agent") {
		t.Fatalf("cmd through a link: %q %v", command, err)
	}
}

func TestUnpackRefusesEscapes(t *testing.T) {
	cases := []struct {
		name    string
		entries []archiveEntry
	}{
		{"zip-slip", []archiveEntry{{name: "../evil", body: "x"}}},
		{"zip-slip inside a path", []archiveEntry{{name: "a/../../evil", body: "x"}}},
		{"absolute path", []archiveEntry{{name: "/tmp/agentland-evil", body: "x"}}},
		{"backslash", []archiveEntry{{name: "a\\..\\evil", body: "x"}}},
		{"absolute link", []archiveEntry{{name: "etc", link: "/etc"}}},
		{"link leaving the folder", []archiveEntry{{name: "up", link: "../../../../etc"}}},
		{"link leaving through a folder link", []archiveEntry{{name: "here", link: "."}, {name: "sub/", dir: true}, {name: "sub/up", link: "../here/.."}}},
		{"link made to leave by a later link", []archiveEntry{{name: "x", link: "d/y"}, {name: "d", link: ".."}}},
		{"link loop", []archiveEntry{{name: "a", link: "b"}, {name: "b", link: "a"}, {name: "c", link: "a/x"}}},
		{"write through a link", []archiveEntry{{name: "dir", link: "."}, {name: "dir/file", body: "x"}}},
		{"hard link leaving the folder", []archiveEntry{{name: "passwd", hardlink: "../../../../etc/passwd"}}},
		{"hard link to nothing", []archiveEntry{{name: "copy", hardlink: "missing"}}},
		{"file over a folder", []archiveEntry{{name: "a/", dir: true}, {name: "a/b", body: "x"}, {name: "a", body: "x"}}},
	}
	for _, test := range cases {
		_, err := unpackBytes(t, "tar.gz", tarGz(t, test.entries...), defaultAgentUnpackLimits)
		if !errors.Is(err, errAgentArchive) {
			t.Errorf("%s: %v, want a refusal", test.name, err)
		}
	}
	// Nothing was written outside: the zip-slip file is not beside the temp
	// folders.
	if _, err := os.Stat(filepath.Join(os.TempDir(), "agentland-evil")); err == nil {
		t.Fatal("an entry was written outside the folder")
	}
}

// linksStayInside fails the test for a link in dest that the system resolves
// to a place outside it.
func linksStayInside(t *testing.T, dest string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(dest)
	if err != nil {
		t.Fatal(err)
	}
	filepath.WalkDir(dest, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.Type()&fs.ModeSymlink == 0 {
			return err
		}
		if resolved, err := filepath.EvalSymlinks(path); err == nil && resolved != root && !strings.HasPrefix(resolved, root+string(filepath.Separator)) {
			t.Errorf("%s leads to %s", path, resolved)
		}
		return nil
	})
}

// A file system that looks names up without case, or without Unicode
// normalization (APFS does both), follows a link through another spelling of
// its name, which the checks by name may miss: the tree is resolved again
// on disk, and a link that leaves the folder refuses the archive.
func TestUnpackRefusesLinksReachedByAnotherSpelling(t *testing.T) {
	probe := t.TempDir()
	sameName := func(written, asked string) bool {
		if err := os.WriteFile(filepath.Join(probe, written), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := os.Stat(filepath.Join(probe, asked))
		return err == nil
	}
	foldsCase, foldsForms := sameName("Probe", "PROBE"), sameName("é", "é")
	for _, test := range []struct {
		name    string
		entries []archiveEntry
		leaves  bool // whether the last link would leave the folder here
	}{
		{"another case", []archiveEntry{{name: "./agent", body: "x", mode: 0o755}, {name: "./l", link: "."}, {name: "./esc", link: "L/.."}}, foldsCase},
		{"another case, deeper", []archiveEntry{{name: "d/", dir: true}, {name: "d/up", link: ".."}, {name: "esc", link: "D/UP/.."}}, foldsCase},
		{"another Unicode form", []archiveEntry{{name: "é", link: "."}, {name: "esc", link: "é/.."}}, foldsForms},
	} {
		dest, err := unpackBytes(t, "tar.gz", tarGz(t, test.entries...), defaultAgentUnpackLimits)
		if test.leaves && !errors.Is(err, errAgentArchive) {
			t.Errorf("%s: %v, want a refusal", test.name, err)
		}
		if err == nil {
			linksStayInside(t, dest)
		}
	}
	if runtime.GOOS == "darwin" && !foldsCase {
		t.Log("the temporary folder's file system tells case apart; the case checks ran as on Linux")
	}
}

func TestUnpackZip(t *testing.T) {
	data := zipArchive(t,
		archiveEntry{name: "opencode", body: "#!/bin/sh\n", mode: 0o755},
		archiveEntry{name: "docs/", dir: true},
		archiveEntry{name: "docs/a.txt", body: "a"},
		archiveEntry{name: "latest", link: "opencode"},
	)
	dest, err := unpackBytes(t, "zip", data, defaultAgentUnpackLimits)
	if err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Join(dest, "opencode")); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("opencode %v %v", info, err)
	}
	if target, _ := os.Readlink(filepath.Join(dest, "latest")); target != "opencode" {
		t.Fatalf("link %q", target)
	}
	for _, test := range []struct {
		name  string
		entry archiveEntry
	}{
		{"zip-slip", archiveEntry{name: "../../evil", body: "x"}},
		{"absolute", archiveEntry{name: "/evil", body: "x"}},
		{"link out", archiveEntry{name: "up", link: "../../x"}},
	} {
		if _, err := unpackBytes(t, "zip", zipArchive(t, test.entry), defaultAgentUnpackLimits); !errors.Is(err, errAgentArchive) {
			t.Errorf("zip %s: %v", test.name, err)
		}
	}
	// A zip made without Unix modes leaves the command without its bit; the
	// registry's cmd is made executable.
	dest, err = unpackBytes(t, "zip", zipArchive(t, archiveEntry{name: "tool", body: "#!/bin/sh\n", mode: 0o644}), defaultAgentUnpackLimits)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := resolveAgentCmd(dest, "tool"); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(filepath.Join(dest, "tool")); info.Mode().Perm() != 0o700 {
		t.Fatalf("tool %v", info.Mode())
	}
}

func TestUnpackTarBz2Fixtures(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "agents", "agent.tar.bz2"))
	if err != nil {
		t.Fatal(err)
	}
	dest, err := unpackBytes(t, "tar.bz2", data, defaultAgentUnpackLimits)
	if err != nil {
		t.Fatal(err)
	}
	if command, err := resolveAgentCmd(dest, "goose-current"); err != nil || command != filepath.Join(dest, "goose-current") {
		t.Fatalf("command %q %v", command, err)
	}
	data, err = os.ReadFile(filepath.Join("testdata", "agents", "escape.tar.bz2"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := unpackBytes(t, "tar.bz2", data, defaultAgentUnpackLimits); !errors.Is(err, errAgentArchive) {
		t.Fatalf("a link out of the folder in tar.bz2: %v", err)
	}
	if _, err := unpackBytes(t, "tar.bz2", []byte("not bzip2"), defaultAgentUnpackLimits); !errors.Is(err, errAgentArchive) {
		t.Fatalf("a damaged stream: %v", err)
	}
}

func TestUnpackLimitsAndOddEntries(t *testing.T) {
	many := []archiveEntry{}
	for index := 0; index < 5; index++ {
		many = append(many, archiveEntry{name: "f" + string(rune('a'+index)), body: "x"})
	}
	if _, err := unpackBytes(t, "tar.gz", tarGz(t, many...), agentUnpackLimits{entries: 4, bytes: 1 << 20}); !errors.Is(err, errAgentArchive) {
		t.Fatalf("too many entries: %v", err)
	}
	if _, err := unpackBytes(t, "tar.gz", tarGz(t, archiveEntry{name: "big", body: strings.Repeat("x", 2048)}), agentUnpackLimits{entries: 10, bytes: 1024}); !errors.Is(err, errAgentArchive) {
		t.Fatalf("too many bytes: %v", err)
	}
	// Devices and pipes are refused.
	var buffer bytes.Buffer
	gz := gzip.NewWriter(&buffer)
	writer := tar.NewWriter(gz)
	_ = writer.WriteHeader(&tar.Header{Name: "fifo", Typeflag: tar.TypeFifo, Mode: 0o644})
	_ = writer.Close()
	_ = gz.Close()
	if _, err := unpackBytes(t, "tar.gz", buffer.Bytes(), defaultAgentUnpackLimits); !errors.Is(err, errAgentArchive) {
		t.Fatalf("a pipe: %v", err)
	}
	// cmd must lead to a file inside.
	dest, err := unpackBytes(t, "tar.gz", tarGz(t, archiveEntry{name: "out", link: "sub/../x"}, archiveEntry{name: "sub/", dir: true}, archiveEntry{name: "folder/", dir: true}), defaultAgentUnpackLimits)
	if err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []string{"missing", "folder", "out"} {
		if _, err := resolveAgentCmd(dest, cmd); err == nil {
			t.Errorf("cmd %q resolved", cmd)
		}
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dest, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveAgentCmd(dest, "escape"); err == nil {
		t.Error("cmd through a link out of the folder resolved")
	}
}

func TestFetcherRegistryAndDownloads(t *testing.T) {
	registry := newFakeRegistry(t)
	registry.setAgents(map[string]any{"id": "a", "name": "A", "version": "1.0.0", "distribution": map[string]any{"npx": map[string]any{"package": "a@1.0.0"}}})
	fetcher := newAgentFetcher(registry.server.Client().Transport, "9.9.9")
	data, etag, notModified, err := fetcher.fetchRegistry(context.Background(), registry.url("/registry.json"), "")
	if err != nil || notModified || etag == "" || !strings.Contains(string(data), `"id":"a"`) {
		t.Fatalf("fetch: %v %v %q", err, notModified, etag)
	}
	_, same, notModified, err := fetcher.fetchRegistry(context.Background(), registry.url("/registry.json"), etag)
	if err != nil || !notModified || same != etag {
		t.Fatalf("the ETag again: %v %v", err, notModified)
	}
	registry.mu.Lock()
	first, second := registry.headers[0], registry.headers[1]
	registry.mu.Unlock()
	if first.Get("User-Agent") != "AgentLand-host/9.9.9" || first.Get("Accept") != "application/json" || first.Get("If-None-Match") != "" || second.Get("If-None-Match") != etag {
		t.Fatalf("headers %v %v", first, second)
	}
	// Nothing but these: no cookie, no authorization, nothing about the owner.
	for name := range first {
		switch name {
		case "User-Agent", "Accept", "Accept-Encoding":
		default:
			t.Errorf("the registry request sent %s", name)
		}
	}
	// Over 4 MiB is refused, and so is http.
	registry.mu.Lock()
	registry.document, registry.etag = bytes.Repeat([]byte(" "), agentRegistryLimit+1), ""
	registry.mu.Unlock()
	if _, _, _, err := fetcher.fetchRegistry(context.Background(), registry.url("/registry.json"), ""); !errors.Is(err, errAgentTooLarge) {
		t.Fatalf("over 4 MiB: %v", err)
	}
	if _, _, _, err := fetcher.fetchRegistry(context.Background(), "http://127.0.0.1:9/registry.json", ""); !errors.Is(err, errAgentNotHTTPS) {
		t.Fatalf("http: %v", err)
	}
	// A redirect to http is not followed; one to https is.
	registry.setFile("/archive.tar.gz", []byte("archive bytes"))
	registry.mu.Lock()
	registry.redirect["/moved"] = registry.url("/archive.tar.gz")
	registry.redirect["/downgraded"] = strings.Replace(registry.url("/archive.tar.gz"), "https://", "http://", 1)
	registry.mu.Unlock()
	folder := t.TempDir()
	// The progress it reports: the start, then the end with all 13 bytes.
	var reports [][2]int64
	sum, err := fetcher.download(context.Background(), registry.url("/moved"), filepath.Join(folder, "a"), 1<<20, func(received, total int64) {
		reports = append(reports, [2]int64{received, total})
	})
	if err != nil || sum != sha256Hex([]byte("archive bytes")) {
		t.Fatalf("download through an https redirect: %q %v", sum, err)
	}
	if !reflect.DeepEqual(reports, [][2]int64{{0, 13}, {13, 13}}) {
		t.Fatalf("progress %v", reports)
	}
	if info, _ := os.Stat(filepath.Join(folder, "a")); info.Mode().Perm() != 0o600 {
		t.Fatalf("download mode %v", info.Mode())
	}
	if _, err := fetcher.download(context.Background(), registry.url("/downgraded"), filepath.Join(folder, "b"), 1<<20, nil); !errors.Is(err, errAgentNotHTTPS) {
		t.Fatalf("a redirect to http: %v", err)
	}
	if _, err := fetcher.download(context.Background(), registry.url("/archive.tar.gz"), filepath.Join(folder, "c"), 4, nil); !errors.Is(err, errAgentTooLarge) {
		t.Fatalf("over the limit: %v", err)
	}
	registry.mu.Lock()
	registry.status["/gone"] = http.StatusNotFound
	registry.mu.Unlock()
	if _, err := fetcher.download(context.Background(), registry.url("/gone"), filepath.Join(folder, "d"), 1<<20, nil); !errors.Is(err, errAgentBadStatus) {
		t.Fatalf("404: %v", err)
	}
	// Icons: SVG and PNG only, at most 256 KiB.
	registry.setFile("/icon.svg", []byte(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>`))
	registry.setFile("/icon.png", append([]byte("\x89PNG\r\n\x1a\n"), 0, 0))
	registry.setFile("/icon.gif", []byte("GIF89a"))
	registry.setFile("/huge.svg", append([]byte("<svg>"), bytes.Repeat([]byte(" "), agentIconLimit)...))
	for path, want := range map[string]string{"/icon.svg": "svg", "/icon.png": "png", "/icon.gif": "", "/huge.svg": ""} {
		_, kind, err := fetcher.fetchIcon(context.Background(), registry.url(path))
		if kind != want || (want == "") != (err != nil) {
			t.Errorf("%s: %q %v", path, kind, err)
		}
	}
}
