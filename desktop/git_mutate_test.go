package host

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// gitHost has a repository at the project root with a.txt committed.
func gitHost(t *testing.T) (*Host, string, string) {
	t.Helper()
	h, token, dir := fileHost(t)
	testGit(t, dir, "init", "-q")
	writeFile(t, filepath.Join(dir, "a.txt"), "one\n")
	testGit(t, dir, "add", "a.txt")
	testGit(t, dir, "commit", "-qm", "initial")
	return h, token, dir
}

func gitPost(t *testing.T, h *Host, token, route string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	body["projectId"] = "p1"
	return request(t, h.Handler(), "POST", route, token, body)
}

type statusChange struct {
	Path, Status, Index, Worktree, OriginalPath string
	Conflicted, Untracked                       bool
}

func gitStatus(t *testing.T, h *Host, token string) map[string]statusChange {
	t.Helper()
	w := request(t, h.Handler(), "GET", "/v1/git/status?projectId=p1", token, nil)
	if w.Code != 200 {
		t.Fatalf("status: %d %s", w.Code, w.Body)
	}
	var body struct{ Changes []statusChange }
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	out := map[string]statusChange{}
	for _, change := range body.Changes {
		out[change.Path] = change
	}
	return out
}

func gitDiff(t *testing.T, h *Host, token, file string, staged bool) string {
	t.Helper()
	target := "/v1/git/diff?projectId=p1&file=" + file
	if staged {
		target += "&staged=1"
	}
	w := request(t, h.Handler(), "GET", target, token, nil)
	if w.Code != 200 {
		t.Fatalf("diff %s: %d %s", file, w.Code, w.Body)
	}
	var body struct{ Diff string }
	json.Unmarshal(w.Body.Bytes(), &body)
	return body.Diff
}

func author(name, email string) map[string]string {
	return map[string]string{"name": name, "email": email}
}

func TestGitStageUnstageAndCommit(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "a.txt"), "two\n")
	writeFile(t, filepath.Join(dir, "new.txt"), "new\n")
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a.txt", "new.txt"}}); w.Code != 200 || w.Body.String() != `{"staged":2}`+"\n" {
		t.Fatalf("stage: %d %s", w.Code, w.Body)
	}
	status := gitStatus(t, h, token)
	if a := status["a.txt"]; a.Status != "M " || a.Index != "M" || a.Worktree != "" || a.Untracked || a.Conflicted {
		t.Fatalf("a.txt: %+v", a)
	}
	if n := status["new.txt"]; n.Index != "A" || n.Worktree != "" {
		t.Fatalf("new.txt: %+v", n)
	}
	if diff := gitDiff(t, h, token, "a.txt", true); !strings.Contains(diff, "-one\n+two\n") {
		t.Fatalf("staged diff: %q", diff)
	}
	if w := gitPost(t, h, token, "/v1/git/unstage", map[string]any{"files": []string{"new.txt"}}); w.Code != 200 || w.Body.String() != `{"unstaged":1}`+"\n" {
		t.Fatalf("unstage: %d %s", w.Code, w.Body)
	}
	if n := gitStatus(t, h, token)["new.txt"]; !n.Untracked || n.Status != "??" {
		t.Fatalf("new.txt after unstage: %+v", n)
	}
	w := gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "Change a\n\n# kept\nBody\n", "author": author("Ada Lovelace", "ada@example.com")})
	var committed struct {
		Commit       string
		HooksSkipped bool
	}
	json.Unmarshal(w.Body.Bytes(), &committed)
	if w.Code != 200 || !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(committed.Commit) || !committed.HooksSkipped {
		t.Fatalf("commit: %d %s", w.Code, w.Body)
	}
	logged := testGit(t, dir, "log", "-1", "--format=%H|%an|%ae|%cn|%ce|%B")
	if logged != committed.Commit+"|Ada Lovelace|ada@example.com|Ada Lovelace|ada@example.com|Change a\n\n# kept\nBody\n\n" {
		t.Fatalf("log: %q", logged)
	}
	status = gitStatus(t, h, token)
	if _, changed := status["a.txt"]; changed || !status["new.txt"].Untracked {
		t.Fatalf("status after commit: %+v", status)
	}
	wantError(t, "nothing staged", gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "again", "author": author("Ada", "ada@example.com")}), 409, "git_nothing_to_commit")
}

// The Changes section shows what is not staged yet: the working tree against
// the index, separate from the staged diff and from the diff against HEAD.
func TestGitDiffAgainstTheIndex(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "a.txt"), "two\n")
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a.txt"}}); w.Code != 200 {
		t.Fatalf("stage: %d %s", w.Code, w.Body)
	}
	writeFile(t, filepath.Join(dir, "a.txt"), "three\n")
	diff := func(query string) string {
		t.Helper()
		w := request(t, h.Handler(), "GET", "/v1/git/diff?projectId=p1&file=a.txt"+query, token, nil)
		if w.Code != 200 {
			t.Fatalf("diff%s: %d %s", query, w.Code, w.Body)
		}
		var body struct{ Diff string }
		json.Unmarshal(w.Body.Bytes(), &body)
		return body.Diff
	}
	if got := diff("&against=index"); !strings.Contains(got, "-two\n+three\n") {
		t.Fatalf("unstaged diff: %q", got)
	}
	if got := diff("&staged=1"); !strings.Contains(got, "-one\n+two\n") {
		t.Fatalf("staged diff: %q", got)
	}
	if got := diff(""); !strings.Contains(got, "-one\n+three\n") {
		t.Fatalf("diff against HEAD: %q", got)
	}
	if got := diff("&against=head"); !strings.Contains(got, "-one\n+three\n") {
		t.Fatalf("explicit HEAD diff: %q", got)
	}
	writeFile(t, filepath.Join(dir, "fresh.txt"), "fresh\n")
	w := request(t, h.Handler(), "GET", "/v1/git/diff?projectId=p1&file=fresh.txt&against=index", token, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "+fresh") {
		t.Fatalf("untracked file against the index: %d %s", w.Code, w.Body)
	}
	for _, query := range []string{"&against=index&staged=1", "&against=worktree"} {
		wantError(t, query, request(t, h.Handler(), "GET", "/v1/git/diff?projectId=p1&file=a.txt"+query, token, nil), 400, "invalid_request")
	}
}

func TestGitUnstageBeforeTheFirstCommit(t *testing.T) {
	h, token, dir := fileHost(t)
	testGit(t, dir, "init", "-q")
	writeFile(t, filepath.Join(dir, "first.txt"), "first\n")
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"first.txt"}}); w.Code != 200 {
		t.Fatalf("stage: %d %s", w.Code, w.Body)
	}
	if diff := gitDiff(t, h, token, "first.txt", true); !strings.Contains(diff, "new file mode") || !strings.Contains(diff, "+first") {
		t.Fatalf("staged diff before a commit: %q", diff)
	}
	writeFile(t, filepath.Join(dir, "first.txt"), "changed after staging\n")
	if w := gitPost(t, h, token, "/v1/git/unstage", map[string]any{"files": []string{"first.txt"}}); w.Code != 200 {
		t.Fatalf("unstage: %d %s", w.Code, w.Body)
	}
	if change := gitStatus(t, h, token)["first.txt"]; !change.Untracked {
		t.Fatalf("after unstage: %+v", change)
	}
	wantContent(t, filepath.Join(dir, "first.txt"), "changed after staging\n")
	// Staging a new folder as Git status shows it.
	writeFile(t, filepath.Join(dir, "folder", "inside.txt"), "inside\n")
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"folder/"}}); w.Code != 200 {
		t.Fatalf("stage folder: %d %s", w.Code, w.Body)
	}
	if change := gitStatus(t, h, token)["folder/inside.txt"]; change.Index != "A" {
		t.Fatalf("folder file: %+v", change)
	}
}

func TestGitPathsArePassedLiterally(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("these names are not valid on Windows")
	}
	h, token, dir := gitHost(t)
	for _, name := range []string{"a*.txt", "ab.txt", "[ab].txt", "b.txt", "-n", "--force"} {
		writeFile(t, filepath.Join(dir, name), name+"\n")
	}
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a*.txt", "[ab].txt", "-n", "--force"}}); w.Code != 200 {
		t.Fatalf("stage: %d %s", w.Code, w.Body)
	}
	status := gitStatus(t, h, token)
	for name, staged := range map[string]bool{"a*.txt": true, "[ab].txt": true, "-n": true, "--force": true, "ab.txt": false, "b.txt": false} {
		if got := status[name].Index == "A"; got != staged {
			t.Fatalf("%s staged=%v: %+v", name, got, status)
		}
	}
	tooMany := make([]string, gitMutationFiles+1)
	for i := range tooMany {
		tooMany[i] = "f" + strconv.Itoa(i)
	}
	for _, files := range [][]string{{}, tooMany, {":(glob)*.txt"}, {"../outside"}, {"/etc/passwd"}, {"."}, {`a\b`}} {
		wantError(t, "files "+strings.Join(files[:min(len(files), 1)], ""), gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": files}), 400, "git_path_invalid")
	}
	wantError(t, "missing file", gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"missing.txt"}}), 400, "git_path_invalid")
	wantError(t, "unknown field", gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"b.txt"}, "force": true}), 400, "invalid_request")
	if change := gitStatus(t, h, token)["b.txt"]; !change.Untracked {
		t.Fatalf("b.txt staged: %+v", change)
	}
}

func TestGitIdentitySources(t *testing.T) {
	h, token, dir := gitHost(t)
	identity := func() string {
		t.Helper()
		w := request(t, h.Handler(), "GET", "/v1/git/identity?projectId=p1", token, nil)
		if w.Code != 200 {
			t.Fatalf("identity: %d %s", w.Code, w.Body)
		}
		return strings.TrimSpace(w.Body.String())
	}
	if got := identity(); got != `{"name":"","email":"","source":"none"}` {
		t.Fatalf("none: %s", got)
	}
	// The user's configuration is read in the repository, so a conditional
	// include for it applies (Git compares the repository's real path).
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	user := filepath.Join(t.TempDir(), "gitconfig")
	work := filepath.Join(t.TempDir(), "work.gitconfig")
	writeFile(t, user, "[user]\n\tname = User Name\n[includeIf \"gitdir:"+filepath.ToSlash(resolved)+"/\"]\n\tpath = "+filepath.ToSlash(work)+"\n")
	writeFile(t, work, "[user]\n\temail = work@example.com\n")
	h.mutations.gitUserConfig = user
	if got := identity(); got != `{"name":"User Name","email":"work@example.com","source":"user"}` {
		t.Fatalf("user: %s", got)
	}
	testGit(t, dir, "config", "user.email", "repo@example.com")
	if got := identity(); got != `{"name":"User Name","email":"repo@example.com","source":"user"}` {
		t.Fatalf("mixed: %s", got)
	}
	testGit(t, dir, "config", "user.name", "Repo Name")
	if got := identity(); got != `{"name":"Repo Name","email":"repo@example.com","source":"repository"}` {
		t.Fatalf("repository: %s", got)
	}
	// A commit without an author uses the resolved identity.
	writeFile(t, filepath.Join(dir, "a.txt"), "changed\n")
	gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a.txt"}})
	if w := gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "configured"}); w.Code != 200 {
		t.Fatalf("commit: %d %s", w.Code, w.Body)
	}
	if logged := testGit(t, dir, "log", "-1", "--format=%an|%ae"); logged != "Repo Name|repo@example.com\n" {
		t.Fatalf("log: %q", logged)
	}
}

func TestGitCommitTreatsIdentityAndMessageAsData(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "a.txt"), "two\n")
	gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a.txt"}})
	commit := func(body map[string]any) *httptest.ResponseRecorder {
		return gitPost(t, h, token, "/v1/git/commit", body)
	}
	for label, person := range map[string]map[string]string{
		"newline":      author("Eve\nGIT_AUTHOR_NAME=x", "eve@example.com"),
		"angle":        author("Eve <eve@evil>", "eve@example.com"),
		"email angle":  author("Eve", "eve@example.com> <x"),
		"NUL":          author("Eve", "eve@example.com\x00"),
		"tab":          author("Eve\tX", "eve@example.com"),
		"empty":        author("", "eve@example.com"),
		"blank":        author("   ", "eve@example.com"),
		"long":         author(strings.Repeat("e", gitIdentityLimit+1), "eve@example.com"),
		"missing mail": {"name": "Eve"},
	} {
		wantError(t, label, commit(map[string]any{"message": "m", "author": person}), 400, "invalid_request")
	}
	for label, message := range map[string]string{"empty": "", "blank": " \n\t\n", "NUL": "a\x00b", "long": strings.Repeat("m", gitMessageLimit+1)} {
		wantError(t, "message "+label, commit(map[string]any{"message": message, "author": author("Eve", "eve@example.com")}), 400, "invalid_request")
	}
	wantError(t, "unknown field", commit(map[string]any{"message": "m", "amend": true}), 400, "invalid_request")
	wantError(t, "unknown author field", commit(map[string]any{"message": "m", "author": map[string]string{"name": "Eve", "email": "e@example.com", "date": "1970"}}), 400, "invalid_request")
	// Option-like values stay values.
	w := commit(map[string]any{"message": "--amend\n\n-m $(touch pwned)", "author": author("--reset-author", "--dry-run@example.com")})
	if w.Code != 200 {
		t.Fatalf("commit: %d %s", w.Code, w.Body)
	}
	if logged := testGit(t, dir, "log", "-1", "--format=%an|%ae|%B"); logged != "--reset-author|--dry-run@example.com|--amend\n\n-m $(touch pwned)\n\n" {
		t.Fatalf("log: %q", logged)
	}
	wantMissing(t, filepath.Join(dir, "pwned"))
	if count := strings.TrimSpace(testGit(t, dir, "rev-list", "--count", "HEAD")); count != "2" {
		t.Fatalf("%s commits", count)
	}
}

// The host's own GIT_* environment never reaches Git.
func TestGitIgnoresTheHostsGitEnvironment(t *testing.T) {
	h, token, dir := gitHost(t)
	t.Setenv("GIT_DIR", filepath.Join(t.TempDir(), "elsewhere"))
	t.Setenv("GIT_INDEX_FILE", filepath.Join(t.TempDir(), "index"))
	t.Setenv("GIT_AUTHOR_NAME", "Environment Author")
	t.Setenv("GIT_CONFIG_PARAMETERS", "'core.hooksPath'='hooks'")
	writeFile(t, filepath.Join(dir, "a.txt"), "two\n")
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a.txt"}}); w.Code != 200 {
		t.Fatalf("stage: %d %s", w.Code, w.Body)
	}
	if w := gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "m", "author": author("Request Author", "r@example.com")}); w.Code != 200 {
		t.Fatalf("commit: %d %s", w.Code, w.Body)
	}
	if logged := testGit(t, dir, "log", "-1", "--format=%an"); logged != "Request Author\n" {
		t.Fatalf("log: %q", logged)
	}
}

func TestGitRefusesLockedFilteredAndSignedChanges(t *testing.T) {
	h, token, dir := gitHost(t)
	stage := func(files ...string) *httptest.ResponseRecorder {
		return gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": files})
	}
	commit := func() *httptest.ResponseRecorder {
		return gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "m", "author": author("Ada", "ada@example.com")})
	}
	writeFile(t, filepath.Join(dir, "a.txt"), "two\n")

	// A leftover index lock, as a change that timed out may leave.
	lock := filepath.Join(dir, ".git", "index.lock")
	writeFile(t, lock, "")
	wantError(t, "locked stage", stage("a.txt"), 409, "git_index_locked")
	wantError(t, "locked unstage", gitPost(t, h, token, "/v1/git/unstage", map[string]any{"files": []string{"a.txt"}}), 409, "git_index_locked")
	wantError(t, "locked commit", commit(), 409, "git_index_locked")
	os.Remove(lock)

	// Files with a filter driver, as Git LFS configures.
	writeFile(t, filepath.Join(dir, ".gitattributes"), "*.bin filter=lfs diff=lfs merge=lfs -text\n")
	writeFile(t, filepath.Join(dir, "x.bin"), "binary")
	writeFile(t, filepath.Join(dir, "assets", "y.bin"), "binary")
	wantError(t, "filtered file", stage("x.bin", "a.txt"), 409, "git_filter_unsupported")
	wantError(t, "folder with a filtered file", stage("assets/"), 409, "git_filter_unsupported")
	if status := gitStatus(t, h, token); status["a.txt"].Index != "" || !status["x.bin"].Untracked {
		t.Fatalf("a refused request staged files: %+v", status)
	}
	if w := stage("a.txt", ".gitattributes"); w.Code != 200 {
		t.Fatalf("unfiltered files: %d %s", w.Code, w.Body)
	}

	// Signing is required by the repository, by the user, or implied by a bare key.
	testGit(t, dir, "config", "commit.gpgsign", "true")
	wantError(t, "repository signing", commit(), 409, "git_signing_required")
	testGit(t, dir, "config", "--unset", "commit.gpgsign")
	user := filepath.Join(t.TempDir(), "gitconfig")
	writeFile(t, user, "[commit]\n\tgpgsign\n")
	h.mutations.gitUserConfig = user
	wantError(t, "user signing", commit(), 409, "git_signing_required")
	testGit(t, dir, "config", "commit.gpgsign", "false")
	if w := commit(); w.Code != 200 {
		t.Fatalf("repository turns signing off: %d %s", w.Code, w.Body)
	}
	if signature := testGit(t, dir, "log", "-1", "--format=%G?"); signature != "N\n" {
		t.Fatalf("signature state %q", signature)
	}

	// No identity anywhere.
	h.mutations.gitUserConfig = os.DevNull
	writeFile(t, filepath.Join(dir, "a.txt"), "three\n")
	stage("a.txt")
	wantError(t, "identity", gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "m"}), 409, "git_identity_missing")

	// Another change holds the repository.
	top, _ := filepath.EvalSymlinks(dir)
	release, ok := h.mutations.lockRepository(context.Background(), top)
	if !ok {
		t.Fatal("lock")
	}
	h.mutations.gitLockWait = 20 * time.Millisecond
	wantError(t, "busy", stage("a.txt"), 409, "git_busy")
	release()
	h.mutations.gitLockWait = 5 * time.Second

	// A change that runs out of time has an unknown outcome.
	h.mutations.gitTimeout = time.Nanosecond
	if detail := wantError(t, "timeout", stage("a.txt"), 504, "git_timeout"); detail.Outcome != "unknown" {
		t.Fatalf("outcome %q", detail.Outcome)
	}
	h.mutations.gitTimeout = 30 * time.Second
	if w := stage("a.txt"); w.Code != 200 {
		t.Fatalf("after timeout: %d %s", w.Code, w.Body)
	}
}

func TestGitStatusColumnsAndDiffs(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "b.txt"), "b\n")
	writeFile(t, filepath.Join(dir, "c.txt"), "c\n")
	testGit(t, dir, "add", "b.txt", "c.txt")
	testGit(t, dir, "commit", "-qm", "more")
	writeFile(t, filepath.Join(dir, "a.txt"), "worktree\n")
	writeFile(t, filepath.Join(dir, "b.txt"), "staged\n")
	testGit(t, dir, "add", "b.txt")
	writeFile(t, filepath.Join(dir, "b.txt"), "staged then changed\n")
	testGit(t, dir, "mv", "c.txt", "d.txt")
	writeFile(t, filepath.Join(dir, "u.txt"), "untracked\n")
	writeFile(t, filepath.Join(dir, "newdir", "x.txt"), "no newline")
	writeFile(t, filepath.Join(dir, "bin.dat"), "bin\x00")
	status := gitStatus(t, h, token)
	for path, want := range map[string]statusChange{
		"a.txt":   {Path: "a.txt", Status: " M", Worktree: "M"},
		"b.txt":   {Path: "b.txt", Status: "MM", Index: "M", Worktree: "M"},
		"d.txt":   {Path: "d.txt", Status: "R ", Index: "R", OriginalPath: "c.txt"},
		"u.txt":   {Path: "u.txt", Status: "??", Index: "?", Worktree: "?", Untracked: true},
		"newdir/": {Path: "newdir/", Status: "??", Index: "?", Worktree: "?", Untracked: true},
	} {
		if status[path] != want {
			t.Fatalf("%s: %+v, want %+v", path, status[path], want)
		}
	}
	if diff := gitDiff(t, h, token, "b.txt", true); !strings.Contains(diff, "+staged\n") || strings.Contains(diff, "then changed") {
		t.Fatalf("staged diff: %q", diff)
	}
	if diff := gitDiff(t, h, token, "b.txt", false); !strings.Contains(diff, "+staged then changed") {
		t.Fatalf("diff against HEAD: %q", diff)
	}
	if diff := gitDiff(t, h, token, "u.txt", false); diff != "diff --git a/u.txt b/u.txt\nnew file mode 100644\n--- /dev/null\n+++ b/u.txt\n@@ -0,0 +1 @@\n+untracked\n" {
		t.Fatalf("untracked diff: %q", diff)
	}
	if diff := gitDiff(t, h, token, "newdir/x.txt", false); !strings.HasSuffix(diff, "+no newline\n\\ No newline at end of file\n") {
		t.Fatalf("untracked folder file: %q", diff)
	}
	if diff := gitDiff(t, h, token, "bin.dat", false); !strings.HasSuffix(diff, "Binary files /dev/null and b/bin.dat differ\n") {
		t.Fatalf("untracked binary: %q", diff)
	}
	if diff := gitDiff(t, h, token, "u.txt", true); diff != "" {
		t.Fatalf("untracked file has a staged diff: %q", diff)
	}
	if runtime.GOOS != "windows" {
		outside := filepath.Join(t.TempDir(), "secret.txt")
		writeFile(t, outside, "secret\n")
		if err := os.Symlink(outside, filepath.Join(dir, "link.txt")); err != nil {
			t.Fatal(err)
		}
		if diff := gitDiff(t, h, token, "link.txt", false); strings.Contains(diff, "secret") {
			t.Fatalf("diff read through a symlink: %q", diff)
		}
	}
	if w := request(t, h.Handler(), "GET", "/v1/git/diff?projectId=p1&file=a.txt&staged=maybe", token, nil); w.Code != 400 {
		t.Fatalf("invalid staged flag: %d", w.Code)
	}
}

func TestGitConflictsAreReportedAndBlockCommits(t *testing.T) {
	h, token, dir := gitHost(t)
	testGit(t, dir, "checkout", "-q", "-b", "other")
	writeFile(t, filepath.Join(dir, "a.txt"), "other\n")
	testGit(t, dir, "commit", "-qam", "other")
	testGit(t, dir, "checkout", "-q", "main")
	writeFile(t, filepath.Join(dir, "a.txt"), "mine\n")
	testGit(t, dir, "commit", "-qam", "mine")
	command := exec.Command("git", "-C", dir, "-c", "user.name=Setup", "-c", "user.email=setup@example.com", "merge", "-q", "other")
	command.Env = gitEnvironment(false, "", nil)
	if output, err := command.CombinedOutput(); err == nil {
		t.Fatalf("merge did not conflict: %s", output)
	}
	if change := gitStatus(t, h, token)["a.txt"]; !change.Conflicted || change.Status != "UU" {
		t.Fatalf("conflict: %+v", change)
	}
	wantError(t, "conflicted commit", gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "merge", "author": author("Ada", "ada@example.com")}), 409, "git_conflict")
	// Staging the resolution makes the merge committable.
	writeFile(t, filepath.Join(dir, "a.txt"), "resolved\n")
	if w := gitPost(t, h, token, "/v1/git/stage", map[string]any{"files": []string{"a.txt"}}); w.Code != 200 {
		t.Fatalf("stage resolution: %d %s", w.Code, w.Body)
	}
	if w := gitPost(t, h, token, "/v1/git/commit", map[string]any{"message": "merge", "author": author("Ada", "ada@example.com")}); w.Code != 200 {
		t.Fatalf("merge commit: %d %s", w.Code, w.Body)
	}
	if parents := testGit(t, dir, "log", "-1", "--format=%P"); len(strings.Fields(parents)) != 2 {
		t.Fatalf("parents %q", parents)
	}
}
