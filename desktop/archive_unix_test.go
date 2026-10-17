//go:build !windows

package host

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestArchiveFilesAndDirectoriesArePrivate(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive := openTestArchive(t, directory, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Private")
	sum, err := archive.StoreBlob(strings.NewReader("attachment"), "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: "p1"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("output"))
	log.Close("exited", nil)
	flushArchive(t, archive)
	stored, err := archive.ArchivedTerminalLog(t.Context(), log.ID())
	if err != nil {
		t.Fatal(err)
	}
	logPath, _ := archive.terminalLogPath(stored.file)
	want := map[string]os.FileMode{
		directory:                                  0700 | os.ModeDir,
		filepath.Join(directory, "archive.db"):     0600,
		filepath.Join(directory, "archive.db-wal"): 0600,
		filepath.Join(directory, "archive.db-shm"): 0600,
		filepath.Join(directory, "blobs"):          0700 | os.ModeDir,
		filepath.Join(directory, "blobs", sum[:2]): 0700 | os.ModeDir,
		archive.blobPath(sum):                      0600,
		filepath.Join(directory, "terminals"):      0700 | os.ModeDir,
		filepath.Dir(logPath):                      0700 | os.ModeDir,
		filepath.Dir(filepath.Dir(logPath)):        0700 | os.ModeDir,
		logPath:                                    0600,
	}
	for path, mode := range want {
		info, err := os.Lstat(path)
		if err != nil {
			t.Errorf("%s: %v", path, err)
			continue
		}
		if got := info.Mode() & (os.ModeType | os.ModePerm); got != mode {
			t.Errorf("%s: mode %v, want %v", path, got, mode)
		}
	}
}

// A blob file swapped for a symlink, or cut short, is never served.
func TestArchiveBlobRouteRefusesATamperedFile(t *testing.T) {
	host, archive, token, sums := archiveBlobFixture(t)
	get := func() *httptest.ResponseRecorder {
		return request(t, host.Handler(), "GET", "/v1/archive/blob?chatId=c1&messageId=m5&name=notes.txt", token, nil)
	}
	path := archive.blobPath(sums["notes1"])
	elsewhere := filepath.Join(t.TempDir(), "elsewhere.txt")
	if err := os.WriteFile(elsewhere, []byte("first notes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path, path+".kept"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, path); err != nil {
		t.Fatal(err)
	}
	wantRouteError(t, "symlinked blob", get(), 500, "archive_error", "The archive could not complete the request")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	wantRouteError(t, "blob cut short", get(), 500, "archive_error", "The archive could not complete the request")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	wantRouteError(t, "blob file gone", get(), 404, "attachment_not_archived", "This attachment's bytes were not archived")
	if err := os.Rename(path+".kept", path); err != nil {
		t.Fatal(err)
	}
	if w := get(); w.Code != 200 || w.Body.String() != "first notes" {
		t.Fatalf("restored blob: %d %q", w.Code, w.Body)
	}
}

func TestArchiveRefusesSharedDirectoriesAndFiles(t *testing.T) {
	shared := filepath.Join(t.TempDir(), "shared.archive")
	if err := os.Mkdir(shared, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(shared, 0777); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenArchive(shared, ArchiveOptions{}); err == nil || !strings.Contains(err.Error(), "dedicated AgentLand directory") {
		t.Fatalf("world-writable archive directory: %v", err)
	}

	directory := filepath.Join(t.TempDir(), "state.json.archive")
	archive := openTestArchive(t, directory, ArchiveOptions{})
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(directory, "archive.db")
	if err := os.Chmod(database, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenArchive(directory, ArchiveOptions{}); err == nil || !strings.Contains(err.Error(), "regular private file") {
		t.Fatalf("readable archive.db: %v", err)
	}
	if err := os.Chmod(database, 0600); err != nil {
		t.Fatal(err)
	}
	// An existing directory that is too open is tightened to 0700.
	if err := os.Chmod(directory, 0755); err != nil {
		t.Fatal(err)
	}
	openTestArchive(t, directory, ArchiveOptions{})
	if info, err := os.Stat(directory); err != nil || info.Mode().Perm() != 0700 {
		t.Fatalf("directory mode %v %v", info.Mode(), err)
	}
}
