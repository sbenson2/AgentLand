package host

import (
	"encoding/json"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestGitExplorerListsConfiguredFolderRepositoriesAndChanges(t *testing.T) {
	h, store, _ := testHost(t)
	token := paired(t, h, store)
	root := mustProject(t, store).Directory
	repo := filepath.Join(root, "app")
	if err := os.Mkdir(repo, 0700); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-q", repo}, {"-C", repo, "config", "user.email", "test@example.com"}, {"-C", repo, "config", "user.name", "Test"}} {
		if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, output)
		}
	}
	file := filepath.Join(repo, "note.txt")
	if err := os.WriteFile(file, []byte("before\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"-C", repo, "add", "note.txt"}, {"-C", repo, "commit", "-qm", "initial"}} {
		if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, output)
		}
	}
	if err := os.WriteFile(file, []byte("after\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "new.txt"), []byte("new\n"), 0600); err != nil {
		t.Fatal(err)
	}

	repositories := request(t, h.Handler(), "GET", "/v1/git/repositories?projectId=p1", token, nil)
	if repositories.Code != 200 {
		t.Fatalf("repositories: %d %s", repositories.Code, repositories.Body)
	}
	var listed struct{ Repositories []struct{ Name, Path string } }
	if err := json.Unmarshal(repositories.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	if len(listed.Repositories) != 1 || listed.Repositories[0].Path != "app" {
		t.Fatal(repositories.Body.String())
	}

	status := request(t, h.Handler(), "GET", "/v1/git/status?projectId=p1&path=app", token, nil)
	if status.Code != 200 {
		t.Fatalf("status: %d %s", status.Code, status.Body)
	}
	var changed struct {
		Branch  string
		Changes []struct{ Path, Status string }
	}
	if err := json.Unmarshal(status.Body.Bytes(), &changed); err != nil {
		t.Fatal(err)
	}
	if changed.Branch == "" || len(changed.Changes) != 2 {
		t.Fatal(status.Body.String())
	}

	diff := request(t, h.Handler(), "GET", "/v1/git/diff?projectId=p1&path=app&file=note.txt", token, nil)
	if diff.Code != 200 || !strings.Contains(diff.Body.String(), "+after") {
		t.Fatalf("diff: %d %s", diff.Code, diff.Body)
	}
	if got := request(t, h.Handler(), "GET", "/v1/git/repositories?projectId=p1", "", nil); got.Code != 401 {
		t.Fatal(got.Code)
	}
	for _, path := range []string{"../outside", "/tmp", "missing"} {
		got := request(t, h.Handler(), "GET", "/v1/git/status?projectId=p1&path="+url.QueryEscape(path), token, nil)
		if got.Code == 200 {
			t.Fatalf("invalid repo %q accepted: %s", path, got.Body)
		}
	}
}
