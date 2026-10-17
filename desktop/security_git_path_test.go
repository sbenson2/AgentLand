package host

import (
    "context"
    "fmt"
    "net/http/httptest"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "time"
)

// A repository lock pauses the real stage route after path validation. The
// moves use authenticated native routes and no artificial filesystem rights.
func TestGitStageCannotFollowConcurrentFileMovesOutsideProject(t *testing.T) {
    h, token, project := fileHost(t)
    repository := filepath.Join(project, "repo")
    outside := t.TempDir()
    if err := os.Mkdir(repository, 0700); err != nil { t.Fatal(err) }
    for _, directory := range []string{repository, outside} {
        testGit(t, directory, "init", "-q")
        writeFile(t, filepath.Join(directory, "marker.txt"), "dummy marker\n")
    }
    if err := os.Symlink(outside, filepath.Join(project, "parked")); err != nil { t.Fatal(err) }
    canonical, err := filepath.EvalSymlinks(repository)
    if err != nil { t.Fatal(err) }
    release, ok := h.mutations.lockRepository(context.Background(), canonical)
    if !ok { t.Fatal("fixture repository lock unavailable") }
    defer func() { if release != nil { release() } }()
    stage := make(chan *httptest.ResponseRecorder, 1)
    go func() { stage <- gitPost(t, h, token, "/v1/git/stage", map[string]any{"path":"repo", "files":[]string{"marker.txt"}}) }()
    deadline := time.Now().Add(2*time.Second)
    for {
        h.mutations.mu.Lock()
        lock := h.mutations.gitLocks[canonical]
        waiting := lock != nil && lock.users == 2
        h.mutations.mu.Unlock()
        if waiting { break }
        if time.Now().After(deadline) { t.Fatal("stage did not reach repository lock after validation") }
        time.Sleep(time.Millisecond)
    }
    // TryLock observes whether Git retained the shared file-mutation lock.
    // On the vulnerable base both moves complete before stage resumes. On
    // the fixed path they can run only after the anchored operation finishes.
    unlocked := h.filesMu.TryLock()
    if unlocked { h.filesMu.Unlock() }
    move := func(from, to string) {
        w := request(t, h.Handler(), "POST", "/v1/files/move", token,
                     map[string]any{"projectId":"p1", "from":from, "to":to})
        if w.Code != 200 { t.Fatalf("move %s to %s: %d %s", from, to, w.Code, w.Body) }
    }
    if unlocked {
        move("repo", "repo.saved")
        move("parked", "repo")
    }
    release(); release = nil
    select {
    case result := <-stage:
        if result.Code != 200 { t.Fatalf("stage: %d %s", result.Code, result.Body) }
    case <-time.After(5*time.Second): t.Fatal("stage did not finish")
    }
    if !unlocked {
        move("repo", "repo.saved")
        move("parked", "repo")
    }
    staged := strings.TrimSpace(testGit(t, outside, "diff", "--cached", "--name-only"))
    fmt.Printf("PPV_REACHED\nBoth native moves succeeded; outside index=%q; serialized=%v\n", staged, !unlocked)
    if staged != "" { t.Fatalf("Git staged a marker outside the configured project: %q", staged) }
}
