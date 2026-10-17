package host

import (
	"encoding/json"
	"errors"
	"io"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
)

func init() {
	// No test uses the owner's Trash or global Git configuration. A test that
	// needs either points its host at a temporary one.
	defaultTrashDirectory = func() (string, error) { return "", errTrashUnavailable }
	defaultGitUserConfig = os.DevNull
}

type errorDetail struct {
	Code                   string
	Message                string
	SuggestedName          string
	PermanentDeleteAllowed bool
	Outcome                string
}

func decodeError(t *testing.T, w *httptest.ResponseRecorder) errorDetail {
	t.Helper()
	var body struct{ Error errorDetail }
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body %q: %v", w.Body.String(), err)
	}
	return body.Error
}

func wantError(t *testing.T, label string, w *httptest.ResponseRecorder, status int, code string) errorDetail {
	t.Helper()
	if w.Code != status {
		t.Fatalf("%s: %d %s, want %d %s", label, w.Code, w.Body, status, code)
	}
	detail := decodeError(t, w)
	if detail.Code != code {
		t.Fatalf("%s: %s, want %s", label, w.Body, code)
	}
	return detail
}

func fileHost(t *testing.T) (*Host, string, string) {
	t.Helper()
	h, store, _ := testHost(t)
	return h, paired(t, h, store), mustProject(t, store).Directory
}

func writeFile(t *testing.T, name, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func wantContent(t *testing.T, name, content string) {
	t.Helper()
	got, err := os.ReadFile(name)
	if err != nil || string(got) != content {
		t.Fatalf("%s: %q %v, want %q", name, got, err, content)
	}
}

func wantMissing(t *testing.T, name string) {
	t.Helper()
	if _, err := os.Lstat(name); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("%s still exists: %v", name, err)
	}
}

func uploadFile(h *Host, token, name string, body io.Reader, length int64) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/v1/files/upload?projectId=p1&path="+url.QueryEscape(name), body)
	r.ContentLength = length
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	return w
}

func TestAlternativeNames(t *testing.T) {
	for _, test := range []struct {
		name      string
		n         int
		directory bool
		want      string
	}{
		{"notes.txt", 1, false, "notes 2.txt"},
		{"notes.txt", 2, false, "notes 3.txt"},
		{"photo 2.jpg", 1, false, "photo 3.jpg"},
		{"archive.tar.gz", 1, false, "archive.tar 2.gz"},
		{".env", 1, false, ".env 2"},
		{"Makefile", 1, false, "Makefile 2"},
		{"v1.2", 1, true, "v1.2 2"},
		{"folder 9", 1, true, "folder 10"},
		{"take 02", 1, false, "take 02 2"},
		{"x 1", 1, false, "x 1 2"},
	} {
		if got := alternativeName(test.name, test.n, test.directory); got != test.want {
			t.Errorf("alternativeName(%q, %d, %v) = %q, want %q", test.name, test.n, test.directory, got, test.want)
		}
	}
}

func TestFileMoveNeverReplacesAndSuggestsAFreeName(t *testing.T) {
	h, token, dir := fileHost(t)
	writeFile(t, filepath.Join(dir, "a.txt"), "a")
	writeFile(t, filepath.Join(dir, "b.txt"), "b")
	writeFile(t, filepath.Join(dir, "b 2.txt"), "b2")
	move := func(from, to string) *httptest.ResponseRecorder {
		return request(t, h.Handler(), "POST", "/v1/files/move", token, map[string]string{"projectId": "p1", "from": from, "to": to})
	}
	if detail := wantError(t, "move onto b.txt", move("a.txt", "b.txt"), 409, "file_exists"); detail.SuggestedName != "b 3.txt" {
		t.Fatalf("suggested %q", detail.SuggestedName)
	}
	if detail := wantError(t, "move onto itself", move("a.txt", "a.txt"), 409, "file_exists"); detail.SuggestedName != "a 2.txt" {
		t.Fatalf("suggested %q", detail.SuggestedName)
	}
	wantContent(t, filepath.Join(dir, "a.txt"), "a")
	wantContent(t, filepath.Join(dir, "b.txt"), "b")
	if runtime.GOOS != "windows" {
		// A dangling symlink is an entry too; it is never replaced.
		if err := os.Symlink("nowhere", filepath.Join(dir, "dangling")); err != nil {
			t.Fatal(err)
		}
		wantError(t, "move onto a dangling symlink", move("a.txt", "dangling"), 409, "file_exists")
		if target, err := os.Readlink(filepath.Join(dir, "dangling")); err != nil || target != "nowhere" {
			t.Fatalf("symlink changed: %q %v", target, err)
		}
	}

	w := move("a.txt", "c.txt")
	if w.Code != 200 || w.Body.String() != `{"name":"c.txt","path":"c.txt","isDirectory":false,"size":1}`+"\n" {
		t.Fatalf("rename: %d %s", w.Code, w.Body)
	}
	wantMissing(t, filepath.Join(dir, "a.txt"))
	wantContent(t, filepath.Join(dir, "c.txt"), "a")
	writeFile(t, filepath.Join(dir, "folder", "inner.txt"), "inner")
	if w := move("c.txt", "folder/c.txt"); w.Code != 200 || !strings.Contains(w.Body.String(), `"path":"folder/c.txt"`) {
		t.Fatalf("move into folder: %d %s", w.Code, w.Body)
	}
	if w := move("folder", "renamed"); w.Code != 200 || !strings.Contains(w.Body.String(), `"isDirectory":true`) {
		t.Fatalf("move folder: %d %s", w.Code, w.Body)
	}
	wantContent(t, filepath.Join(dir, "renamed", "inner.txt"), "inner")
	wantError(t, "folder into itself", move("renamed", "renamed/deeper/renamed"), 400, "invalid_move")
	if err := os.Mkdir(filepath.Join(dir, "renamed", "deeper"), 0o700); err != nil {
		t.Fatal(err)
	}
	wantError(t, "folder into its child", move("renamed", "renamed/deeper/renamed"), 400, "invalid_move")
	wantError(t, "missing source", move("missing.txt", "x.txt"), 404, "file_not_found")
	wantError(t, "missing destination folder", move("b.txt", "missing/b.txt"), 404, "file_not_found")
	for _, bad := range [][2]string{{"", "x"}, {".", "x"}, {"b.txt", "."}, {"../b.txt", "x"}, {"b.txt", "../x"}, {"/b.txt", "x"}, {"b.txt", `a\b`}} {
		wantError(t, "invalid "+bad[0]+" → "+bad[1], move(bad[0], bad[1]), 400, "invalid_path")
	}
	// Only the case changes; on a case-insensitive volume this is the same entry.
	writeFile(t, filepath.Join(dir, "Case.txt"), "case")
	if w := move("Case.txt", "case.txt"); w.Code != 200 {
		t.Fatalf("case-only rename: %d %s", w.Code, w.Body)
	}
	entries, _ := os.ReadDir(dir)
	names := map[string]bool{}
	for _, entry := range entries {
		names[entry.Name()] = true
	}
	if !names["case.txt"] || names["Case.txt"] {
		t.Fatalf("entries after case rename: %v", names)
	}
	if w := request(t, h.Handler(), "POST", "/v1/files/move", "", map[string]string{"projectId": "p1", "from": "b.txt", "to": "z.txt"}); w.Code != 401 {
		t.Fatalf("unauthenticated move: %d", w.Code)
	}
}

func TestFileMakeDirectory(t *testing.T) {
	h, token, dir := fileHost(t)
	mkdir := func(name string) *httptest.ResponseRecorder {
		return request(t, h.Handler(), "POST", "/v1/files/mkdir", token, map[string]string{"projectId": "p1", "path": name})
	}
	w := mkdir("New Folder")
	if w.Code != 201 || w.Body.String() != `{"name":"New Folder","path":"New Folder","isDirectory":true,"size":0}`+"\n" {
		t.Fatalf("mkdir: %d %s", w.Code, w.Body)
	}
	if info, err := os.Lstat(filepath.Join(dir, "New Folder")); err != nil || !info.IsDir() {
		t.Fatalf("created: %v %v", info, err)
	}
	if detail := wantError(t, "existing folder", mkdir("New Folder"), 409, "file_exists"); detail.SuggestedName != "New Folder 2" {
		t.Fatalf("suggested %q", detail.SuggestedName)
	}
	writeFile(t, filepath.Join(dir, "file.txt"), "x")
	wantError(t, "existing file", mkdir("file.txt"), 409, "file_exists")
	if w := mkdir("New Folder/child"); w.Code != 201 {
		t.Fatalf("nested: %d %s", w.Code, w.Body)
	}
	wantError(t, "missing parent", mkdir("missing/child"), 404, "file_not_found")
	wantError(t, "project folder", mkdir("."), 400, "invalid_path")
	wantError(t, "outside", mkdir("../escape"), 400, "invalid_path")
}

func TestFileUploadNeverOverwritesAndPublishesCompleteFiles(t *testing.T) {
	h, token, dir := fileHost(t)
	w := uploadFile(h, token, "up.txt", strings.NewReader("hello"), 5)
	if w.Code != 201 || w.Body.String() != `{"name":"up.txt","path":"up.txt","isDirectory":false,"size":5}`+"\n" {
		t.Fatalf("upload: %d %s", w.Code, w.Body)
	}
	wantContent(t, filepath.Join(dir, "up.txt"), "hello")
	if runtime.GOOS != "windows" {
		// The file gets 0644 limited by the umask, like any new file.
		reference, err := os.OpenFile(filepath.Join(t.TempDir(), "reference"), os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := reference.Stat()
		reference.Close()
		got, _ := os.Stat(filepath.Join(dir, "up.txt"))
		if got.Mode().Perm() != want.Mode().Perm() {
			t.Fatalf("mode %o, want %o", got.Mode().Perm(), want.Mode().Perm())
		}
	}
	if detail := wantError(t, "taken name", uploadFile(h, token, "up.txt", strings.NewReader("other"), 5), 409, "file_exists"); detail.SuggestedName != "up 2.txt" {
		t.Fatalf("suggested %q", detail.SuggestedName)
	}
	wantContent(t, filepath.Join(dir, "up.txt"), "hello")
	if w := uploadFile(h, token, "empty.txt", strings.NewReader(""), 0); w.Code != 201 {
		t.Fatalf("empty upload: %d %s", w.Code, w.Body)
	}
	wantContent(t, filepath.Join(dir, "empty.txt"), "")
	wantError(t, "missing folder", uploadFile(h, token, "missing/x.txt", strings.NewReader("x"), 1), 404, "file_not_found")
	wantError(t, "project folder", uploadFile(h, token, ".", strings.NewReader("x"), 1), 400, "invalid_path")
	wantError(t, "no length", uploadFile(h, token, "stream.txt", strings.NewReader("x"), -1), 411, "length_required")
	// A body shorter than its declared length is never published.
	wantError(t, "short body", uploadFile(h, token, "short.txt", strings.NewReader("abc"), 10), 400, "upload_incomplete")
	wantMissing(t, filepath.Join(dir, "short.txt"))

	h.mutations.uploadLimit = 8
	wantError(t, "declared too large", uploadFile(h, token, "big.txt", strings.NewReader("123456789"), 9), 413, "file_too_large")
	wantMissing(t, filepath.Join(dir, "big.txt"))
	if w := uploadFile(h, token, "exact.txt", strings.NewReader("12345678"), 8); w.Code != 201 {
		t.Fatalf("exact limit: %d %s", w.Code, w.Body)
	}
	h.mutations.uploadLimit = defaultFileUploadLimit

	h.mutations.freeSpace = func(*os.File) (uint64, error) { return uploadFreeSpaceReserve + 3, nil }
	wantError(t, "low space", uploadFile(h, token, "space.txt", strings.NewReader("1234"), 4), 507, "insufficient_storage")
	wantMissing(t, filepath.Join(dir, "space.txt"))
	if w := uploadFile(h, token, "space.txt", strings.NewReader("123"), 3); w.Code != 201 {
		t.Fatalf("upload within free space: %d %s", w.Code, w.Body)
	}
	h.mutations.freeSpace = freeSpace

	// The name is taken while the body arrives: the link refuses it. A pipe
	// write returns once the handler has read it, so it is past its checks.
	body, writer := io.Pipe()
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() { result <- uploadFile(h, token, "late.txt", body, 4) }()
	writer.Write([]byte("la"))
	writeFile(t, filepath.Join(dir, "late.txt"), "first")
	writer.Write([]byte("te"))
	writer.Close()
	wantError(t, "name taken during upload", <-result, 409, "file_exists")
	wantContent(t, filepath.Join(dir, "late.txt"), "first")

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".agentland-upload-") {
			t.Fatalf("temporary file left: %s", entry.Name())
		}
	}
	if w := uploadFile(h, "", "anon.txt", strings.NewReader("x"), 1); w.Code != 401 {
		t.Fatalf("unauthenticated upload: %d", w.Code)
	}
}

func uploadsInProgress(h *Host) int {
	h.mutations.mu.Lock()
	defer h.mutations.mu.Unlock()
	total := 0
	for _, count := range h.mutations.uploads {
		total += count
	}
	return total
}

func TestFileUploadsAreLimitedPerDevice(t *testing.T) {
	h, store, _ := testHost(t)
	token := paired(t, h, store)
	other := paired(t, h, store)
	type pending struct {
		writer *io.PipeWriter
		result chan *httptest.ResponseRecorder
	}
	start := func(name string) pending {
		body, writer := io.Pipe()
		p := pending{writer, make(chan *httptest.ResponseRecorder, 1)}
		go func() { p.result <- uploadFile(h, token, name, body, 2) }()
		return p
	}
	first, second := start("one.txt"), start("two.txt")
	waitFor(t, "two uploads in progress", func() bool { return uploadsInProgress(h) == 2 })
	wantError(t, "third upload", uploadFile(h, token, "three.txt", strings.NewReader("33"), 2), 429, "upload_limit")
	if w := uploadFile(h, other, "other.txt", strings.NewReader("oo"), 2); w.Code != 201 {
		t.Fatalf("another device: %d %s", w.Code, w.Body)
	}
	for _, p := range []pending{first, second} {
		p.writer.Write([]byte("ok"))
		p.writer.Close()
		if w := <-p.result; w.Code != 201 {
			t.Fatalf("held upload: %d %s", w.Code, w.Body)
		}
	}
	if w := uploadFile(h, token, "three.txt", strings.NewReader("33"), 2); w.Code != 201 {
		t.Fatalf("after the others finished: %d %s", w.Code, w.Body)
	}
	if uploadsInProgress(h) != 0 {
		t.Fatal("upload slots were not released")
	}
}

func deleteRequest(t *testing.T, h *Host, token string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	body["projectId"] = "p1"
	return request(t, h.Handler(), "POST", "/v1/files/delete", token, body)
}

func TestFileDeleteMovesToTheTrashWithFreeNames(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the host has no Trash on Windows")
	}
	h, token, dir := fileHost(t)
	trash := t.TempDir()
	h.mutations.trashDirectory = func() (string, error) { return trash, nil }
	writeFile(t, filepath.Join(trash, "a.txt"), "old")
	writeFile(t, filepath.Join(trash, "a 2.txt"), "older")
	writeFile(t, filepath.Join(dir, "a.txt"), "mine")
	w := deleteRequest(t, h, token, map[string]any{"path": "a.txt"})
	if w.Code != 200 || w.Body.String() != `{"path":"a.txt","trashName":"a 3.txt","trashed":true}`+"\n" {
		t.Fatalf("trash: %d %s", w.Code, w.Body)
	}
	wantMissing(t, filepath.Join(dir, "a.txt"))
	wantContent(t, filepath.Join(trash, "a 3.txt"), "mine")
	wantContent(t, filepath.Join(trash, "a.txt"), "old")
	wantContent(t, filepath.Join(trash, "a 2.txt"), "older")
	for _, want := range []string{"folder", "folder 2"} {
		writeFile(t, filepath.Join(dir, "folder", "inner.txt"), want)
		if w := deleteRequest(t, h, token, map[string]any{"path": "folder"}); w.Code != 200 || !strings.Contains(w.Body.String(), `"trashName":"`+want+`"`) {
			t.Fatalf("trash folder: %d %s", w.Code, w.Body)
		}
		wantContent(t, filepath.Join(trash, want, "inner.txt"), want)
	}
	wantError(t, "missing", deleteRequest(t, h, token, map[string]any{"path": "a.txt"}), 404, "file_not_found")
	for _, bad := range []string{"", ".", "../a.txt", "/tmp"} {
		wantError(t, "invalid "+bad, deleteRequest(t, h, token, map[string]any{"path": bad}), 400, "invalid_path")
	}
}

func TestFileDeleteReportsAnUnavailableTrash(t *testing.T) {
	h, token, dir := fileHost(t)
	writeFile(t, filepath.Join(dir, "keep.txt"), "keep")
	unavailable := func(label string) {
		t.Helper()
		if detail := wantError(t, label, deleteRequest(t, h, token, map[string]any{"path": "keep.txt"}), 409, "trash_unavailable"); !detail.PermanentDeleteAllowed {
			t.Fatalf("%s: permanent delete not offered", label)
		}
		wantContent(t, filepath.Join(dir, "keep.txt"), "keep")
	}
	// Tests run with no Trash, like Linux and Windows hosts.
	unavailable("no trash")
	if runtime.GOOS == "windows" {
		return
	}
	trash := t.TempDir()
	h.mutations.trashDirectory = func() (string, error) { return trash, nil }
	h.mutations.renameNoReplace = func(_ *os.File, from string, _ *os.File, to string) error {
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
	}
	unavailable("another volume")
	h.mutations.renameNoReplace = renameNoReplace
	link := filepath.Join(t.TempDir(), "Trash")
	if err := os.Symlink(trash, link); err != nil {
		t.Fatal(err)
	}
	h.mutations.trashDirectory = func() (string, error) { return link, nil }
	unavailable("symlinked trash")
	plain := filepath.Join(t.TempDir(), "Trash")
	writeFile(t, plain, "not a folder")
	h.mutations.trashDirectory = func() (string, error) { return plain, nil }
	unavailable("trash is a file")
	if entries, _ := os.ReadDir(trash); len(entries) != 0 {
		t.Fatalf("trash received %v", entries)
	}
}

func TestFilePermanentDeleteNeedsConfirmation(t *testing.T) {
	h, token, dir := fileHost(t)
	writeFile(t, filepath.Join(dir, "gone.txt"), "x")
	writeFile(t, filepath.Join(dir, "tree", "a", "b.txt"), "b")
	wantError(t, "no confirmation", deleteRequest(t, h, token, map[string]any{"path": "gone.txt", "permanent": true}), 400, "confirmation_required")
	wantError(t, "wrong confirmation", deleteRequest(t, h, token, map[string]any{"path": "gone.txt", "permanent": true, "confirmPath": "tree"}), 400, "confirmation_required")
	wantContent(t, filepath.Join(dir, "gone.txt"), "x")
	w := deleteRequest(t, h, token, map[string]any{"path": "gone.txt", "permanent": true, "confirmPath": "gone.txt"})
	if w.Code != 200 || w.Body.String() != `{"path":"gone.txt","trashed":false}`+"\n" {
		t.Fatalf("permanent delete: %d %s", w.Code, w.Body)
	}
	wantMissing(t, filepath.Join(dir, "gone.txt"))
	if w := deleteRequest(t, h, token, map[string]any{"path": "tree", "permanent": true, "confirmPath": "tree"}); w.Code != 200 {
		t.Fatalf("delete tree: %d %s", w.Code, w.Body)
	}
	wantMissing(t, filepath.Join(dir, "tree"))
	wantError(t, "project folder", deleteRequest(t, h, token, map[string]any{"path": ".", "permanent": true, "confirmPath": "."}), 400, "invalid_path")
	if runtime.GOOS != "windows" {
		outside := t.TempDir()
		writeFile(t, filepath.Join(outside, "precious.txt"), "precious")
		if err := os.Symlink(outside, filepath.Join(dir, "link")); err != nil {
			t.Fatal(err)
		}
		if w := deleteRequest(t, h, token, map[string]any{"path": "link", "permanent": true, "confirmPath": "link"}); w.Code != 200 {
			t.Fatalf("delete symlink: %d %s", w.Code, w.Body)
		}
		wantMissing(t, filepath.Join(dir, "link"))
		wantContent(t, filepath.Join(outside, "precious.txt"), "precious")
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("project folder removed")
	}
}

// Swapping a folder for a symlink to another directory while changes run must
// never let a change create, move, trash or remove anything outside the project.
func TestFileChangesStayInsideTheProjectWhileSymlinksSwap(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need extra privileges on Windows")
	}
	h, token, dir := fileHost(t)
	trash := t.TempDir()
	h.mutations.trashDirectory = func() (string, error) { return trash, nil }
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "keep.txt"), "outside")
	writeFile(t, filepath.Join(dir, "inside.txt"), "inside")
	if err := os.Mkdir(filepath.Join(dir, "real"), 0o700); err != nil {
		t.Fatal(err)
	}
	var stop atomic.Bool
	var swapper sync.WaitGroup
	swapper.Add(1)
	go func() {
		defer swapper.Done()
		swap, real := filepath.Join(dir, "swap"), filepath.Join(dir, "real")
		for !stop.Load() {
			os.Rename(real, swap) // swap is a real folder in the project
			os.Rename(swap, real)
			os.Symlink(outside, swap) // swap points outside the project
			os.Remove(swap)
		}
	}()
	for i := range 200 {
		n := strconv.Itoa(i)
		request(t, h.Handler(), "POST", "/v1/files/mkdir", token, map[string]string{"projectId": "p1", "path": "swap/made-" + n})
		uploadFile(h, token, "swap/up-"+n, strings.NewReader("x"), 1)
		request(t, h.Handler(), "POST", "/v1/files/move", token, map[string]string{"projectId": "p1", "from": "inside.txt", "to": "swap/moved-" + n})
		request(t, h.Handler(), "POST", "/v1/files/move", token, map[string]string{"projectId": "p1", "from": "swap/moved-" + n, "to": "inside.txt"})
		request(t, h.Handler(), "POST", "/v1/files/move", token, map[string]string{"projectId": "p1", "from": "swap/keep.txt", "to": "stolen-" + n})
		deleteRequest(t, h, token, map[string]any{"path": "swap/keep.txt"})
		deleteRequest(t, h, token, map[string]any{"path": "swap/keep.txt", "permanent": true, "confirmPath": "swap/keep.txt"})
		search := request(t, h.Handler(), "GET", "/v1/files/search?projectId=p1&path=swap&q=outside", token, nil)
		if strings.Contains(search.Body.String(), "keep.txt") {
			t.Fatalf("search read outside the project: %s", search.Body)
		}
	}
	stop.Store(true)
	swapper.Wait()
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 1 || entries[0].Name() != "keep.txt" {
		names := []string{}
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("outside directory changed: %v %v", names, err)
	}
	wantContent(t, filepath.Join(outside, "keep.txt"), "outside")
	if entries, _ := os.ReadDir(trash); len(entries) != 0 {
		t.Fatalf("trash received an outside file: %v", entries)
	}
	matches, _ := filepath.Glob(filepath.Join(dir, "stolen-*"))
	if len(matches) != 0 {
		t.Fatalf("an outside file moved into the project: %v", matches)
	}
}
