package host

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

type searchBody struct {
	Results []struct {
		Path      string
		Matches   []searchMatch
		Truncated bool
	}
	TruncatedReason string
}

func search(t *testing.T, h *Host, token, query string) (searchBody, *httptest.ResponseRecorder) {
	t.Helper()
	w := request(t, h.Handler(), "GET", "/v1/files/search?projectId=p1&"+query, token, nil)
	var body searchBody
	if w.Code == 200 {
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
	}
	return body, w
}

// found lists "path:line" for every match.
func (b searchBody) found() []string {
	out := []string{}
	for _, result := range b.Results {
		for _, match := range result.Matches {
			out = append(out, result.Path+":"+strconv.Itoa(match.Line))
		}
	}
	sort.Strings(out)
	return out
}

func wantFound(t *testing.T, label string, body searchBody, want ...string) {
	t.Helper()
	sort.Strings(want)
	if got := body.found(); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("%s: found %v, want %v", label, got, want)
	}
}

func TestFileSearchMatchesTextOrPatterns(t *testing.T) {
	h, token, dir := fileHost(t)
	writeFile(t, filepath.Join(dir, "a.txt"), "a.c\nabc\r\nA.C\n")
	writeFile(t, filepath.Join(dir, "notes.md"), "nothing here\n")
	writeFile(t, filepath.Join(dir, "sub", "deep.txt"), "a.c again")
	writeFile(t, filepath.Join(dir, "unicode.txt"), "éé needle")
	for _, test := range []struct {
		query string
		want  []string
	}{
		{"q=a.c", []string{"a.txt:1", "a.txt:3", "sub/deep.txt:1"}},
		{"q=a.c&caseSensitive=true", []string{"a.txt:1", "sub/deep.txt:1"}},
		{"q=a.c&regex=true", []string{"a.txt:1", "a.txt:2", "a.txt:3", "sub/deep.txt:1"}},
		{"q=a.c&regex=1&caseSensitive=1", []string{"a.txt:1", "a.txt:2", "sub/deep.txt:1"}},
		{"q=" + url.QueryEscape("^abc$") + "&regex=true", []string{"a.txt:2"}},
		{"q=a.c&path=sub", []string{"sub/deep.txt:1"}},
		{"q=here&include=" + url.QueryEscape("*.md"), []string{"notes.md:1"}},
		{"q=a.c&include=" + url.QueryEscape("*.md, sub/*.txt"), []string{"sub/deep.txt:1"}},
		{"q=missing", []string{}},
	} {
		body, w := search(t, h, token, test.query)
		if w.Code != 200 || body.TruncatedReason != "" {
			t.Fatalf("%s: %d %s", test.query, w.Code, w.Body)
		}
		wantFound(t, test.query, body, test.want...)
	}
	body, _ := search(t, h, token, "q=needle")
	if len(body.Results) != 1 || body.Results[0].Matches[0].Column != 4 || body.Results[0].Matches[0].Preview != "éé needle" {
		t.Fatalf("column in characters: %+v", body.Results)
	}
	body, _ = search(t, h, token, "q=abc")
	if match := body.Results[0].Matches[0]; match.Preview != "abc" {
		t.Fatalf("carriage return kept in preview: %q", match.Preview)
	}
	// Without caseSensitive, plain text folds case like Unicode does: "k" also
	// matches the Kelvin sign, in files with or without other non-ASCII text.
	writeFile(t, filepath.Join(dir, "kelvin.txt"), "300 K\n")
	writeFile(t, filepath.Join(dir, "upper.txt"), "UPPER K\n")
	body, _ = search(t, h, token, "q=k&include="+url.QueryEscape("kelvin.txt,upper.txt"))
	wantFound(t, "case folding", body, "kelvin.txt:1", "upper.txt:1")
	// Plain text is never a pattern.
	if _, w := search(t, h, token, "q="+url.QueryEscape("(")); w.Code != 200 {
		t.Fatalf("literal parenthesis: %d %s", w.Code, w.Body)
	}
	for _, bad := range []struct {
		query  string
		status int
		code   string
	}{
		{"q=", 400, "invalid_request"},
		{"q=" + url.QueryEscape("two\nlines"), 400, "invalid_request"},
		{"q=" + strings.Repeat("x", searchQueryLimit+1), 400, "invalid_request"},
		{"q=" + url.QueryEscape("(") + "&regex=true", 400, "invalid_pattern"},
		{"q=x&regex=maybe", 400, "invalid_request"},
		{"q=x&include=" + url.QueryEscape("[x"), 400, "invalid_request"},
		{"q=x&path=..", 400, "invalid_path"},
		{"q=x&path=a.txt", 400, "invalid_path"},
		{"q=x&path=missing", 404, "file_not_found"},
	} {
		_, w := search(t, h, token, bad.query)
		wantError(t, bad.query, w, bad.status, bad.code)
	}
	if w := request(t, h.Handler(), "GET", "/v1/files/search?projectId=missing&q=x", token, nil); w.Code != 404 {
		t.Fatalf("unknown project: %d", w.Code)
	}
	if w := request(t, h.Handler(), "GET", "/v1/files/search?projectId=p1&q=x", "", nil); w.Code != 401 {
		t.Fatalf("unauthenticated: %d", w.Code)
	}
}

func TestFileSearchSkipsBinaryLargeGitAndSymlinkedFiles(t *testing.T) {
	h, token, dir := fileHost(t)
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "secret.txt"), "needle outside")
	writeFile(t, filepath.Join(dir, "good.txt"), "needle")
	writeFile(t, filepath.Join(dir, "binary.dat"), "needle\x00")
	writeFile(t, filepath.Join(dir, "latin1.txt"), "needle \xff")
	writeFile(t, filepath.Join(dir, "large.txt"), "needle"+strings.Repeat("x", maxTextFile))
	// Not a working repository, so the folder is walked and .git skipped.
	writeFile(t, filepath.Join(dir, ".git", "notes"), "needle")
	if runtime.GOOS != "windows" {
		if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(dir, "link.txt")); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(outside, filepath.Join(dir, "linked")); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink("good.txt", filepath.Join(dir, "inner-link.txt")); err != nil {
			t.Fatal(err)
		}
	}
	body, w := search(t, h, token, "q=needle")
	if w.Code != 200 {
		t.Fatalf("search: %d %s", w.Code, w.Body)
	}
	wantFound(t, "skips", body, "good.txt:1")
}

func TestFileSearchBoundsItsWork(t *testing.T) {
	h, token, dir := fileHost(t)
	for _, name := range []string{"1.txt", "2.txt", "3.txt", "4.txt", "5.txt"} {
		writeFile(t, filepath.Join(dir, name), "needle\nneedle\n")
	}
	limits := func(change func(*searchLimits)) {
		h.mutations.search = defaultSearchLimits
		change(&h.mutations.search)
	}
	limits(func(l *searchLimits) { l.files = 3 })
	body, _ := search(t, h, token, "q=needle")
	if body.TruncatedReason != "files" || len(body.Results) != 3 {
		t.Fatalf("files: %+v", body)
	}
	limits(func(l *searchLimits) { l.matches = 5 })
	body, _ = search(t, h, token, "q=needle")
	if body.TruncatedReason != "matches" || len(body.found()) != 5 {
		t.Fatalf("matches: %+v", body)
	}
	// Reaching the limit exactly is not truncation.
	limits(func(l *searchLimits) { l.matches = 10 })
	body, _ = search(t, h, token, "q=needle")
	if body.TruncatedReason != "" || len(body.found()) != 10 {
		t.Fatalf("exact matches: %+v", body)
	}
	limits(func(l *searchLimits) { l.fileMatches = 1 })
	body, _ = search(t, h, token, "q=needle")
	if body.TruncatedReason != "" || len(body.Results) != 5 || len(body.Results[0].Matches) != 1 || !body.Results[0].Truncated {
		t.Fatalf("per file: %+v", body)
	}
	limits(func(l *searchLimits) { l.bytes = 20 })
	body, _ = search(t, h, token, "q=needle")
	if body.TruncatedReason != "bytes" || len(body.Results) != 1 {
		t.Fatalf("bytes: %+v", body)
	}
	// The first file waits out the time limit.
	limits(func(l *searchLimits) { l.timeout = 50 * time.Millisecond })
	h.mutations.searchHook = func(ctx context.Context) { <-ctx.Done() }
	body, w := search(t, h, token, "q=needle")
	if w.Code != 200 || body.TruncatedReason != "time" || len(body.Results) != 0 {
		t.Fatalf("time: %d %s", w.Code, w.Body)
	}
	h.mutations.searchHook = nil
	h.mutations.search = defaultSearchLimits

	// Previews stay short and whole characters around the match.
	line := strings.Repeat("é", 2000) + "needle" + strings.Repeat("ü", 2000)
	writeFile(t, filepath.Join(dir, "long.txt"), line)
	body, _ = search(t, h, token, "q=needle&include=long.txt")
	if len(body.Results) != 1 {
		t.Fatalf("long line: %+v", body)
	}
	match := body.Results[0].Matches[0]
	if len(match.Preview) > searchPreviewBytes || !utf8.ValidString(match.Preview) || !strings.Contains(match.Preview, "needle") || match.Column != 2001 {
		t.Fatalf("preview %d bytes %q column %d", len(match.Preview), match.Preview, match.Column)
	}
}

func TestFileSearchFollowsGitIgnoreRules(t *testing.T) {
	h, token, dir := fileHost(t)
	testGit(t, dir, "init", "-q")
	writeFile(t, filepath.Join(dir, ".gitignore"), "ignored.txt\nbuild/\n")
	writeFile(t, filepath.Join(dir, "tracked.txt"), "needle")
	testGit(t, dir, "add", ".gitignore", "tracked.txt")
	testGit(t, dir, "commit", "-qm", "initial")
	writeFile(t, filepath.Join(dir, "untracked.txt"), "needle")
	writeFile(t, filepath.Join(dir, "ignored.txt"), "needle")
	writeFile(t, filepath.Join(dir, "build", "out.txt"), "needle")
	// A nested repository keeps its own ignore rules.
	nested := filepath.Join(dir, "nested")
	writeFile(t, filepath.Join(nested, "visible.txt"), "needle")
	writeFile(t, filepath.Join(nested, "secret.txt"), "needle")
	writeFile(t, filepath.Join(nested, ".gitignore"), "secret.txt\n")
	testGit(t, nested, "init", "-q")
	body, w := search(t, h, token, "q=needle")
	if w.Code != 200 {
		t.Fatalf("search: %d %s", w.Code, w.Body)
	}
	wantFound(t, "repository", body, "nested/visible.txt:1", "tracked.txt:1", "untracked.txt:1")
	body, _ = search(t, h, token, "q=needle&path=nested")
	wantFound(t, "nested start", body, "nested/visible.txt:1")
}

func TestFileSearchUsesGitForRepositoriesInsideAPlainFolder(t *testing.T) {
	h, token, dir := fileHost(t)
	app := filepath.Join(dir, "app")
	writeFile(t, filepath.Join(app, ".gitignore"), "node_modules/\n")
	writeFile(t, filepath.Join(app, "main.txt"), "needle")
	writeFile(t, filepath.Join(app, "node_modules", "lib.txt"), "needle")
	testGit(t, app, "init", "-q")
	writeFile(t, filepath.Join(dir, "loose.txt"), "needle")
	body, _ := search(t, h, token, "q=needle")
	wantFound(t, "plain folder", body, "app/main.txt:1", "loose.txt:1")
}

// A repository above the project, such as a home folder under version control
// that ignores everything, does not decide what the project's search sees.
func TestFileSearchIgnoresRepositoriesAboveTheProject(t *testing.T) {
	outer := t.TempDir()
	testGit(t, outer, "init", "-q")
	writeFile(t, filepath.Join(outer, ".gitignore"), "*\n")
	project := filepath.Join(outer, "project")
	writeFile(t, filepath.Join(project, "file.txt"), "needle")
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "state.json"))
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Nested", Directory: project}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	h := New(store, &fakeAgent{sessions: map[string]Session{}})
	body, w := search(t, h, paired(t, h, store), "q=needle")
	if w.Code != 200 {
		t.Fatalf("search: %d %s", w.Code, w.Body)
	}
	wantFound(t, "outer repository", body, "file.txt:1")
}

func TestFileSearchRunsOnePerDevice(t *testing.T) {
	h, store, _ := testHost(t)
	token := paired(t, h, store)
	other := paired(t, h, store)
	dir := mustProject(t, store).Directory
	for _, name := range []string{"1.txt", "2.txt", "3.txt"} {
		writeFile(t, filepath.Join(dir, name), "needle")
	}
	// hold stops the first file of the next search until release is closed;
	// every later file, in any search, passes straight through.
	hold := func() (chan struct{}, chan struct{}) {
		entered, release := make(chan struct{}), make(chan struct{})
		var held atomic.Bool
		h.mutations.searchHook = func(context.Context) {
			if held.CompareAndSwap(false, true) {
				close(entered)
				<-release
			}
		}
		return entered, release
	}
	run := func(credential string) chan *httptest.ResponseRecorder {
		result := make(chan *httptest.ResponseRecorder, 1)
		go func() {
			result <- request(t, h.Handler(), "GET", "/v1/files/search?projectId=p1&q=needle", credential, nil)
		}()
		return result
	}

	// A newer search from the same device replaces the running one.
	entered, release := hold()
	first := run(token)
	<-entered
	if second := <-run(token); second.Code != 200 || !strings.Contains(second.Body.String(), `"path":"3.txt"`) {
		t.Fatalf("second search: %d %s", second.Code, second.Body)
	}
	close(release)
	wantError(t, "replaced search", <-first, 409, "search_superseded")

	// Another device's search does not.
	entered, release = hold()
	first = run(token)
	<-entered
	if second := <-run(other); second.Code != 200 {
		t.Fatalf("other device: %d %s", second.Code, second.Body)
	}
	close(release)
	if w := <-first; w.Code != 200 || !strings.Contains(w.Body.String(), `"path":"3.txt"`) {
		t.Fatalf("first device after the other: %d %s", w.Code, w.Body)
	}

	// A client that goes away stops the search and gets no answer.
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	h.mutations.searchHook = func(context.Context) { calls++; cancel() }
	r := httptest.NewRequest("GET", "/v1/files/search?projectId=p1&q=needle", nil).WithContext(ctx)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	if w.Body.Len() != 0 || calls != 1 {
		t.Fatalf("cancelled search wrote %q after %d files", w.Body.String(), calls)
	}
	h.mutations.mu.Lock()
	running := len(h.mutations.searches)
	h.mutations.mu.Unlock()
	if running != 0 {
		t.Fatalf("%d searches still registered", running)
	}
}
