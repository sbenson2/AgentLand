package host

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestFileBrowseReadSaveAndConflicts(t *testing.T) {
	h, st, _ := testHost(t)
	token := paired(t, h, st)
	dir := mustProject(t, st).Directory
	if err := os.WriteFile(filepath.Join(dir, "hello.txt"), []byte("before\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "folder"), 0700); err != nil {
		t.Fatal(err)
	}
	list := request(t, h.Handler(), "GET", "/v1/files?projectId=p1&path=", token, nil)
	if list.Code != 200 {
		t.Fatalf("list: %d %s", list.Code, list.Body.String())
	}
	var listing struct {
		Entries []struct {
			Name, Path  string
			IsDirectory bool
		}
	}
	if err := json.Unmarshal(list.Body.Bytes(), &listing); err != nil {
		t.Fatal(err)
	}
	if len(listing.Entries) != 2 || listing.Entries[0].Name != "folder" || !listing.Entries[0].IsDirectory {
		t.Fatal(list.Body.String())
	}
	read := request(t, h.Handler(), "GET", "/v1/file?projectId=p1&path=hello.txt", token, nil)
	if read.Code != 200 {
		t.Fatalf("read: %d %s", read.Code, read.Body.String())
	}
	var doc struct{ Path, Content, Revision string }
	json.Unmarshal(read.Body.Bytes(), &doc)
	if doc.Content != "before\n" || doc.Revision == "" {
		t.Fatal(read.Body.String())
	}
	body := map[string]string{"projectId": "p1", "path": "hello.txt", "content": "after\n", "revision": doc.Revision}
	statuses := make(chan int, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); statuses <- request(t, h.Handler(), "POST", "/v1/file", token, body).Code }()
	}
	wg.Wait()
	close(statuses)
	counts := map[int]int{}
	for code := range statuses {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatal(counts)
	}
	contents, _ := os.ReadFile(filepath.Join(dir, "hello.txt"))
	if string(contents) != "after\n" {
		t.Fatal(string(contents))
	}
	info, _ := os.Stat(filepath.Join(dir, "hello.txt"))
	if info.Mode().Perm() != 0600 {
		t.Fatalf("permissions changed: %o", info.Mode().Perm())
	}
	created := request(t, h.Handler(), "POST", "/v1/file", token, map[string]string{"projectId": "p1", "path": "new.txt", "content": "new", "revision": ""})
	if created.Code != 200 {
		t.Fatal(created.Code, created.Body.String())
	}
	if got := request(t, h.Handler(), "POST", "/v1/file", token, map[string]string{"projectId": "p1", "path": "new.txt", "content": "overwrite", "revision": ""}); got.Code != 409 {
		t.Fatal(got.Code)
	}
}
func TestFilePathsCannotEscapeProjectAndRejectBinary(t *testing.T) {
	h, st, _ := testHost(t)
	token := paired(t, h, st)
	dir := mustProject(t, st).Directory
	outside := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(outside, []byte("secret"), 0600)
	if err := os.Symlink(outside, filepath.Join(dir, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"../secret", outside, "escape", "C:\\Windows\\file"} {
		w := request(t, h.Handler(), "GET", "/v1/file?projectId=p1&path="+url.QueryEscape(p), token, nil)
		if w.Code == 200 || strings.Contains(w.Body.String(), "\"content\"") {
			t.Fatalf("escaped %q: %s", p, w.Body.String())
		}
	}
	os.WriteFile(filepath.Join(dir, "binary"), []byte{0, 1, 2}, 0600)
	if w := request(t, h.Handler(), "GET", "/v1/file?projectId=p1&path=binary", token, nil); w.Code != 415 {
		t.Fatal(w.Code, w.Body.String())
	}
	os.WriteFile(filepath.Join(dir, "large"), []byte(strings.Repeat("x", (1<<20)+1)), 0600)
	if w := request(t, h.Handler(), "GET", "/v1/file?projectId=p1&path=large", token, nil); w.Code != 413 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := request(t, h.Handler(), "GET", "/v1/files?projectId=unknown", token, nil); w.Code != 404 {
		t.Fatal(w.Code)
	}
	if w := request(t, h.Handler(), "GET", "/v1/files?projectId=p1", "", nil); w.Code != 401 {
		t.Fatal(w.Code)
	}
	bad := request(t, h.Handler(), "POST", "/v1/file", token, map[string]string{"projectId": "p1", "path": "escape", "content": "changed", "revision": ""})
	if bad.Code == 200 {
		t.Fatal("symlink write accepted")
	}
	got, _ := os.ReadFile(outside)
	if string(got) != "secret" {
		t.Fatal("outside file changed")
	}
}
