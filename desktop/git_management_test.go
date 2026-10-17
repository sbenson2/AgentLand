package host

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func managementRead(t *testing.T, h *Host, token, route string, value any) *httptest.ResponseRecorder {
	t.Helper()
	w := request(t, h.Handler(), "GET", "/v1/git/"+route+"?projectId=p1", token, nil)
	if w.Code != 200 {
		t.Fatalf("%s: %d %s", route, w.Code, w.Body)
	}
	if err := json.Unmarshal(w.Body.Bytes(), value); err != nil {
		t.Fatal(err)
	}
	return w
}

func TestGitBranchesProtectChangesAndUnmergedBranches(t *testing.T) {
	h, token, dir := gitHost(t)
	original := strings.TrimSpace(testGit(t, dir, "branch", "--show-current"))
	var list struct {
		Branches []struct {
			Name    string
			Current bool
		}
	}
	managementRead(t, h, token, "branches", &list)
	if len(list.Branches) != 1 || list.Branches[0].Name != original || !list.Branches[0].Current {
		t.Fatalf("branches: %+v", list)
	}
	body := func(action, name string) map[string]any { return map[string]any{"action": action, "name": name} }
	if w := gitPost(t, h, token, "/v1/git/branch", body("create", "feature/tree")); w.Code != 200 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	writeFile(t, filepath.Join(dir, "a.txt"), "pending\n")
	wantError(t, "dirty switch", gitPost(t, h, token, "/v1/git/branch", body("switch", "feature/tree")), 409, "git_changes_present")
	if got := strings.TrimSpace(testGit(t, dir, "branch", "--show-current")); got != original {
		t.Fatalf("switched dirty branch: %s", got)
	}
	testGit(t, dir, "restore", "a.txt")
	if w := gitPost(t, h, token, "/v1/git/branch", body("switch", "feature/tree")); w.Code != 200 {
		t.Fatalf("switch: %d %s", w.Code, w.Body)
	}
	wantError(t, "delete current", gitPost(t, h, token, "/v1/git/branch", body("delete", "feature/tree")), 409, "git_current_branch")
	writeFile(t, filepath.Join(dir, "a.txt"), "feature\n")
	testGit(t, dir, "commit", "-qam", "feature")
	testGit(t, dir, "switch", original)
	wantError(t, "unmerged delete", gitPost(t, h, token, "/v1/git/branch", body("delete", "feature/tree")), 409, "git_branch_unmerged")
	for _, name := range []string{"--orphan", "bad..name", "refs/heads/escape", "name\n"} {
		wantError(t, "invalid branch", gitPost(t, h, token, "/v1/git/branch", body("create", name)), 400, "git_branch_invalid")
	}
}

func TestGitHistoryAndCommitDiffAreBoundedAndLiteral(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "nested", "b.txt"), "line\n")
	testGit(t, dir, "add", ".")
	testGit(t, dir, "commit", "-qm", "second")
	hash := strings.TrimSpace(testGit(t, dir, "rev-parse", "HEAD"))
	var history struct {
		Commits    []struct{ Hash, Subject, Author string }
		NextCursor string
	}
	managementRead(t, h, token, "history", &history)
	if len(history.Commits) != 2 || history.Commits[0].Hash != hash || history.Commits[0].Subject != "second" {
		t.Fatalf("history: %+v", history)
	}
	w := request(t, h.Handler(), "GET", "/v1/git/commit?projectId=p1&commit="+hash, token, nil)
	var detail struct {
		Files []struct{ Path, Status string }
	}
	json.Unmarshal(w.Body.Bytes(), &detail)
	if w.Code != 200 || len(detail.Files) != 1 || detail.Files[0].Path != "nested/b.txt" {
		t.Fatalf("detail: %d %s", w.Code, w.Body)
	}
	w = request(t, h.Handler(), "GET", "/v1/git/commit/diff?projectId=p1&commit="+hash+"&file=nested/b.txt", token, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "+line") {
		t.Fatalf("commit diff: %d %s", w.Code, w.Body)
	}
	wantError(t, "revision injection", request(t, h.Handler(), "GET", "/v1/git/commit?projectId=p1&commit=HEAD", token, nil), 400, "git_commit_invalid")
	wantError(t, "history bound", request(t, h.Handler(), "GET", "/v1/git/history?projectId=p1&cursor=999999", token, nil), 400, "invalid_request")
}

func TestGitStashesUseStableIdentityAndPreserveIndex(t *testing.T) {
	h, token, dir := gitHost(t)
	testGit(t, dir, "config", "user.name", "Test")
	testGit(t, dir, "config", "user.email", "test@example.com")
	writeFile(t, filepath.Join(dir, "a.txt"), "staged\n")
	testGit(t, dir, "add", "a.txt")
	writeFile(t, filepath.Join(dir, "a.txt"), "worktree\n")
	writeFile(t, filepath.Join(dir, "untracked.txt"), "keep\n")
	if w := gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "save", "message": "phone work"}); w.Code != 200 {
		t.Fatalf("stash: %d %s", w.Code, w.Body)
	}
	if !gitStatus(t, h, token)["untracked.txt"].Untracked {
		t.Fatal("default stash removed untracked file")
	}
	var list struct {
		Stashes []struct{ Hash, Message string }
	}
	managementRead(t, h, token, "stashes", &list)
	if len(list.Stashes) != 1 || !strings.Contains(list.Stashes[0].Message, "phone work") {
		t.Fatalf("stashes: %+v", list)
	}
	hash := list.Stashes[0].Hash
	if w := gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "apply", "hash": hash}); w.Code != 200 {
		t.Fatalf("apply: %d %s", w.Code, w.Body)
	}
	if change := gitStatus(t, h, token)["a.txt"]; change.Index != "M" || change.Worktree != "M" {
		t.Fatalf("index lost: %+v", change)
	}
	if w := gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "drop", "hash": hash}); w.Code != 200 {
		t.Fatalf("drop: %d %s", w.Code, w.Body)
	}
	wantError(t, "stale stash", gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "drop", "hash": hash}), 409, "git_stash_missing")
}

func TestGitDiscardRequiresConfirmationAndLeavesIndexAndUntracked(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "a.txt"), "staged\n")
	testGit(t, dir, "add", "a.txt")
	writeFile(t, filepath.Join(dir, "a.txt"), "discard\n")
	wantError(t, "unconfirmed discard", gitPost(t, h, token, "/v1/git/discard", map[string]any{"files": []string{"a.txt"}}), 400, "git_confirmation_required")
	if w := gitPost(t, h, token, "/v1/git/discard", map[string]any{"files": []string{"a.txt"}, "confirmed": true}); w.Code != 200 {
		t.Fatalf("discard: %d %s", w.Code, w.Body)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "a.txt"))
	if string(data) != "staged\n" {
		t.Fatalf("discard changed index baseline: %s", data)
	}
	writeFile(t, filepath.Join(dir, "new.txt"), "keep\n")
	wantError(t, "untracked discard", gitPost(t, h, token, "/v1/git/discard", map[string]any{"files": []string{"new.txt"}, "confirmed": true}), 400, "git_path_invalid")
	wantError(t, "path escape", gitPost(t, h, token, "/v1/git/discard", map[string]any{"files": []string{"../outside"}, "confirmed": true}), 400, "git_path_invalid")
}

func TestGitManagementRejectsUnconfiguredAndExecutableRemotes(t *testing.T) {
	h, token, dir := gitHost(t)
	wantError(t, "unknown remote", gitPost(t, h, token, "/v1/git/remote", map[string]any{"remote": "https://example.com/repo.git", "action": "fetch"}), 400, "git_remote_invalid")
	testGit(t, dir, "remote", "add", "unsafe", "ext::sh -c touch marker")
	wantError(t, "executable remote", gitPost(t, h, token, "/v1/git/remote", map[string]any{"remote": "unsafe", "action": "fetch"}), 409, "git_remote_unsupported")
	testGit(t, dir, "remote", "add", "local", dir)
	wantError(t, "local remote", gitPost(t, h, token, "/v1/git/remote", map[string]any{"remote": "local", "action": "push"}), 409, "git_remote_unsupported")
	if _, err := os.Stat(filepath.Join(dir, "marker")); !os.IsNotExist(err) {
		t.Fatal("remote executed helper")
	}
	for _, route := range []string{"branches", "history", "stashes", "remotes"} {
		w := request(t, h.Handler(), "GET", "/v1/git/"+route+"?projectId=p1", "", nil)
		if w.Code == 200 {
			t.Fatalf("unauthenticated %s", route)
		}
	}
}

func TestGitRemoteFetchPullPushAndDivergenceOnLoopback(t *testing.T) {
	h, token, dir := gitHost(t)
	branch := strings.TrimSpace(testGit(t, dir, "branch", "--show-current"))
	base := t.TempDir()
	remoteDir := filepath.Join(base, "remote.git")
	testGit(t, base, "init", "--bare", "-q", remoteDir)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	daemon := exec.Command("git", "daemon", "--listen=127.0.0.1", fmt.Sprintf("--port=%d", port), "--reuseaddr", "--export-all", "--enable=receive-pack", "--base-path="+base, base)
	if err := daemon.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { daemon.Process.Kill(); daemon.Wait() })
	ready := false
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
		if err == nil {
			conn.Close()
			ready = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !ready {
		t.Fatal("loopback git daemon did not start")
	}
	remoteURL := fmt.Sprintf("git://127.0.0.1:%d/remote.git", port)
	testGit(t, dir, "remote", "add", "origin", remoteURL)
	change := func(action string) *httptest.ResponseRecorder {
		return gitPost(t, h, token, "/v1/git/remote", map[string]any{"remote": "origin", "action": action})
	}
	if w := change("push"); w.Code != 200 {
		t.Fatalf("push: %d %s", w.Code, w.Body)
	}
	if upstream := strings.TrimSpace(testGit(t, dir, "rev-parse", "--abbrev-ref", "@{upstream}")); upstream != "origin/"+branch {
		t.Fatalf("new branch push did not establish upstream: %s", upstream)
	}
	other := filepath.Join(base, "other")
	testGit(t, base, "clone", "-q", "--branch", branch, remoteURL, other)
	writeFile(t, filepath.Join(other, "remote.txt"), "from remote\n")
	testGit(t, other, "add", ".")
	testGit(t, other, "commit", "-qm", "remote advance")
	testGit(t, other, "push", "-q", "origin", branch)
	if w := change("fetch"); w.Code != 200 {
		t.Fatalf("fetch: %d %s", w.Code, w.Body)
	}
	if _, err := os.Stat(filepath.Join(dir, "remote.txt")); !os.IsNotExist(err) {
		t.Fatal("fetch changed working files")
	}
	if w := change("pull"); w.Code != 200 {
		t.Fatalf("pull: %d %s", w.Code, w.Body)
	}
	if data, _ := os.ReadFile(filepath.Join(dir, "remote.txt")); string(data) != "from remote\n" {
		t.Fatalf("pull did not update files: %q", data)
	}
	writeFile(t, filepath.Join(dir, "local.txt"), "local\n")
	testGit(t, dir, "add", ".")
	testGit(t, dir, "commit", "-qm", "local advance")
	localHead := strings.TrimSpace(testGit(t, dir, "rev-parse", "HEAD"))
	writeFile(t, filepath.Join(other, "remote.txt"), "diverged\n")
	testGit(t, other, "commit", "-qam", "remote divergence")
	testGit(t, other, "push", "-q", "origin", branch)
	wantError(t, "divergent pull", change("pull"), 409, "git_diverged")
	wantError(t, "nonforce push", change("push"), 409, "git_diverged")
	if got := strings.TrimSpace(testGit(t, dir, "rev-parse", "HEAD")); got != localHead {
		t.Fatal("divergence changed local HEAD")
	}
}

func TestGitManagementStatusListsIndividualUntrackedFiles(t *testing.T) {
	h, token, dir := gitHost(t)
	writeFile(t, filepath.Join(dir, "new", "nested", "file.txt"), "new\n")
	w := request(t, h.Handler(), "GET", "/v1/git/status?projectId=p1&untracked=all", token, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"path":"new/nested/file.txt"`) {
		t.Fatalf("nested status: %d %s", w.Code, w.Body)
	}
}

func TestGitStashPreviewIncludesUntrackedFilesAndNoEmptyStash(t *testing.T) {
	h, token, dir := gitHost(t)
	testGit(t, dir, "config", "user.name", "Test")
	testGit(t, dir, "config", "user.email", "test@example.com")
	writeFile(t, filepath.Join(dir, "new.txt"), "saved new\n")
	wantError(t, "nothing tracked to stash", gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "save", "message": "tracked only"}), 409, "git_nothing_to_stash")
	w := gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "save", "includeUntracked": true, "message": "with new"})
	if w.Code != 200 {
		t.Fatalf("save: %d %s", w.Code, w.Body)
	}
	var list struct{ Stashes []struct{ Hash string } }
	managementRead(t, h, token, "stashes", &list)
	hash := list.Stashes[0].Hash
	w = request(t, h.Handler(), "GET", "/v1/git/commit?projectId=p1&stash=1&commit="+hash, token, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"path":"new.txt"`) {
		t.Fatalf("stash preview: %d %s", w.Code, w.Body)
	}
	w = request(t, h.Handler(), "GET", "/v1/git/commit/diff?projectId=p1&stash=1&commit="+hash+"&file=new.txt", token, nil)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "+saved new") {
		t.Fatalf("stash diff: %d %s", w.Code, w.Body)
	}
}

// A stash that includes untracked files takes them out of the working files, as Git does: under the
// host's literal pathspecs it saved them and left them in place, so the files were never clean (the
// iPhone shakedown's stash, then pull).
func TestGitStashWithUntrackedFilesLeavesTheWorkingFilesClean(t *testing.T) {
	h, token, dir := gitHost(t)
	testGit(t, dir, "config", "user.name", "Test")
	testGit(t, dir, "config", "user.email", "test@example.com")
	writeFile(t, filepath.Join(dir, "README.md"), "# Changed\n")
	writeFile(t, filepath.Join(dir, "new.txt"), "saved new\n")
	testGit(t, dir, "add", "README.md")
	testGit(t, dir, "commit", "-q", "-m", "tracked README")
	writeFile(t, filepath.Join(dir, "README.md"), "# Changed again\n")
	w := gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "save", "includeUntracked": true, "message": "everything"})
	if w.Code != 200 {
		t.Fatalf("save: %d %s", w.Code, w.Body)
	}
	if status := testGit(t, dir, "status", "--porcelain", "--untracked-files=all"); status != "" {
		t.Fatalf("the working files keep %q after a stash with untracked files", status)
	}
	if _, err := os.Stat(filepath.Join(dir, "new.txt")); !os.IsNotExist(err) {
		t.Fatalf("new.txt is still in the working files: %v", err)
	}
	if listed := testGit(t, dir, "stash", "show", "--include-untracked", "--name-only", "stash@{0}"); !strings.Contains(listed, "new.txt") || !strings.Contains(listed, "README.md") {
		t.Fatalf("the stash does not hold both files: %q", listed)
	}
	// Applying it brings both back.
	var list struct{ Stashes []struct{ Hash string } }
	managementRead(t, h, token, "stashes", &list)
	if w := gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "apply", "hash": list.Stashes[0].Hash}); w.Code != 200 {
		t.Fatalf("apply: %d %s", w.Code, w.Body)
	}
	if data, err := os.ReadFile(filepath.Join(dir, "new.txt")); err != nil || string(data) != "saved new\n" {
		t.Fatalf("new.txt after apply: %q %v", data, err)
	}
}

func TestGitManagementCheckoutRefusesConfiguredFilterPrograms(t *testing.T) {
	h, token, dir := gitHost(t)
	testGit(t, dir, "branch", "other")
	testGit(t, dir, "config", "filter.danger.smudge", "sh -c 'touch marker'")
	wantError(t, "switch filter", gitPost(t, h, token, "/v1/git/branch", map[string]any{"action": "switch", "name": "other"}), 409, "git_filter_unsupported")
	writeFile(t, filepath.Join(dir, "a.txt"), "pending\n")
	wantError(t, "stash filter", gitPost(t, h, token, "/v1/git/stash", map[string]any{"action": "save"}), 409, "git_filter_unsupported")
	wantError(t, "discard filter", gitPost(t, h, token, "/v1/git/discard", map[string]any{"files": []string{"a.txt"}, "confirmed": true}), 409, "git_filter_unsupported")
	if _, err := os.Stat(filepath.Join(dir, "marker")); !os.IsNotExist(err) {
		t.Fatal("filter program ran")
	}
}

func TestGitNetworkDoesNotRunRepositoryCredentialPrograms(t *testing.T) {
	h, token, dir := gitHost(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("WWW-Authenticate", `Basic realm="fixture"`)
		w.WriteHeader(401)
	}))
	defer server.Close()
	marker := filepath.Join(dir, "prompt-ran")
	program := filepath.Join(dir, "askpass.sh")
	if err := os.WriteFile(program, []byte("#!/bin/sh\ntouch '"+marker+"'\necho ignored\n"), 0700); err != nil {
		t.Fatal(err)
	}
	testGit(t, dir, "config", "core.askPass", program)
	helperMarker := filepath.Join(dir, "helper-ran")
	helper := filepath.Join(dir, "helper.sh")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\ntouch '"+helperMarker+"'\necho username=fixture\necho password=fixture\n"), 0700); err != nil {
		t.Fatal(err)
	}
	testGit(t, dir, "config", "credential.helper", "!"+helper)
	testGit(t, dir, "remote", "add", "origin", server.URL+"/repo.git")
	w := gitPost(t, h, token, "/v1/git/remote", map[string]any{"remote": "origin", "action": "fetch"})
	if w.Code != 409 || !strings.Contains(w.Body.String(), `"outcome":"unknown"`) {
		t.Fatalf("network failure: %d %s", w.Code, w.Body)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("repository askpass program executed")
	}
	if _, err := os.Stat(helperMarker); !os.IsNotExist(err) {
		t.Fatal("repository credential helper executed")
	}
}
