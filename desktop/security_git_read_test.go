package host

import (
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Pause the real Git executable after repository validation, then attempt the
// same authenticated file moves as the mutation regression. The wrapper changes
// timing only; Git still reads real disposable repositories.
func TestGitReadsCannotFollowConcurrentFileMovesOutsideProject(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses a POSIX shell and directory symlinks")
	}
	realGit, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	for _, route := range []string{"status", "diff", "identity", "branches", "history", "commit", "commit/diff", "stashes", "remotes"} {
		t.Run(route, func(t *testing.T) {
			h, token, project := fileHost(t)
			repository := filepath.Join(project, "repo")
			outside := t.TempDir()
			if err := os.Mkdir(repository, 0700); err != nil {
				t.Fatal(err)
			}
			testGit(t, repository, "init", "-q")
			writeFile(t, filepath.Join(repository, "marker.txt"), "inside initial\n")
			testGit(t, repository, "add", "marker.txt")
			testGit(t, repository, "commit", "-qm", "inside commit")
			hash := strings.TrimSpace(testGit(t, repository, "rev-parse", "HEAD"))
			testGit(t, outside, "clone", "-q", repository, ".")
			testGit(t, outside, "branch", "outside-only")
			writeFile(t, filepath.Join(repository, "marker.txt"), "inside current\n")
			writeFile(t, filepath.Join(outside, "marker.txt"), "outside-secret\n")
			writeFile(t, filepath.Join(outside, "outside-secret.txt"), "dummy private data\n")
			if err := os.Symlink(outside, filepath.Join(project, "parked")); err != nil {
				t.Fatal(err)
			}

			gate := t.TempDir()
			wrapper := `#!/bin/sh
case "$*" in
  *" rev-parse --show-toplevel") exec "$AGENTLAND_TEST_REAL_GIT" "$@" ;;
esac
if [ ! -f "$AGENTLAND_TEST_GIT_GATE/release" ]; then
  : > "$AGENTLAND_TEST_GIT_GATE/reached"
  attempts=0
  while [ ! -f "$AGENTLAND_TEST_GIT_GATE/release" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 500 ] || exit 97
    sleep 0.01
  done
fi
exec "$AGENTLAND_TEST_REAL_GIT" "$@"
`
			if err := os.WriteFile(filepath.Join(gate, "git"), []byte(wrapper), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("AGENTLAND_TEST_REAL_GIT", realGit)
			t.Setenv("AGENTLAND_TEST_GIT_GATE", gate)
			t.Setenv("PATH", gate+string(os.PathListSeparator)+os.Getenv("PATH"))
			release := func() { writeFile(t, filepath.Join(gate, "release"), "") }
			defer release()
			w := httptest.NewRecorder()
			r := httptest.NewRequest("GET", "/v1/git/"+route+"?projectId=p1&path=repo&file=marker.txt&commit="+hash, nil)
			r.Header.Set("Authorization", "Bearer "+token)
			done := make(chan struct{})
			go func() {
				h.Handler().ServeHTTP(w, r)
				close(done)
			}()
			deadline := time.Now().Add(3 * time.Second)
			for {
				if _, err := os.Stat(filepath.Join(gate, "reached")); err == nil {
					break
				}
				select {
				case <-done:
					t.Fatalf("read finished before the Git gate: %d %s", w.Code, w.Body)
				default:
				}
				if time.Now().After(deadline) {
					t.Fatal("read did not reach Git after repository validation")
				}
				time.Sleep(time.Millisecond)
			}
			unlocked := h.filesMu.TryLock()
			if unlocked {
				h.filesMu.Unlock()
			}
			move := func(from, to string) {
				result := request(t, h.Handler(), "POST", "/v1/files/move", token,
					map[string]any{"projectId": "p1", "from": from, "to": to})
				if result.Code != 200 {
					t.Fatalf("move %s to %s: %d %s", from, to, result.Code, result.Body)
				}
			}
			if unlocked {
				move("repo", "repo.saved")
				move("parked", "repo")
			}
			release()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("read did not finish after releasing Git")
			}
			if !unlocked {
				move("repo", "repo.saved")
				move("parked", "repo")
			}
			if w.Code != 200 {
				t.Fatalf("read: %d %s", w.Code, w.Body)
			}
			if unlocked || strings.Contains(w.Body.String(), "outside-secret") || strings.Contains(w.Body.String(), "outside-only") {
				t.Fatalf("Git read allowed repository replacement: serialized=%v response=%s", !unlocked, w.Body)
			}
		})
	}
}
