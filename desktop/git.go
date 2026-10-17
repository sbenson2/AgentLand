package host

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

type gitRepository struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// gitChange is one porcelain v1 status entry. Status keeps both columns;
// Index and Worktree are those columns with a space (unchanged) as "".
type gitChange struct {
	Path         string `json:"path"`
	Status       string `json:"status"`
	Index        string `json:"index"`
	Worktree     string `json:"worktree"`
	Conflicted   bool   `json:"conflicted"`
	Untracked    bool   `json:"untracked"`
	OriginalPath string `json:"originalPath,omitempty"`
}

type cappedGitOutput struct {
	bytes.Buffer
	limit int
}

func (b *cappedGitOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.limit {
		return 0, errors.New("git output limit exceeded")
	}
	return b.Buffer.Write(p)
}

// runGit runs a read-only Git command with the fixed environment of
// runGitCall and fails when stdout exceeds limit.
func runGit(directory string, limit int, args ...string) ([]byte, error) {
	out := runGitCall(context.Background(), gitCall{directory: directory, args: args, timeout: gitReadTimeout, stdoutLimit: limit, strictOutput: true})
	if out.err != nil {
		return nil, out.err
	}
	return out.stdout, nil
}

func gitStatusColumn(column byte) string {
	if column == ' ' {
		return ""
	}
	return string(column)
}

func gitConflicted(x, y byte) bool {
	return x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D')
}

func insideDirectory(root, target string) bool {
	relative, err := filepath.Rel(root, target)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// The caller must hold filesMu until its last use of the returned path: Git's
// later -C lookup must not follow a concurrent AgentLand move outside the root.
func (h *Host) gitRoot(w http.ResponseWriter, projectID, relative string) (string, bool) {
	project, err := h.project(projectID)
	if err != nil {
		notFound(w)
		return "", false
	}
	name, err := filePath(relative, true)
	if err != nil {
		writeError(w, 400, "invalid_path", "Choose a relative workspace folder")
		return "", false
	}
	root, err := os.OpenRoot(project.Directory)
	if err != nil {
		writeError(w, 503, "project_unavailable", "The workspace folder is unavailable")
		return "", false
	}
	defer root.Close()
	directory, err := root.OpenRoot(name)
	if err != nil {
		fileFailure(w, err)
		return "", false
	}
	defer directory.Close()
	base, err := filepath.EvalSymlinks(project.Directory)
	if err != nil {
		fileFailure(w, err)
		return "", false
	}
	target, err := filepath.EvalSymlinks(filepath.Join(project.Directory, name))
	if err != nil || !insideDirectory(base, target) {
		writeError(w, 403, "path_unavailable", "The folder is outside the workspace")
		return "", false
	}
	top, err := runGit(target, 4096, "rev-parse", "--show-toplevel")
	if err != nil || strings.TrimSpace(string(top)) != target {
		writeError(w, 404, "git_repository_not_found", "Choose a Git repository inside this workspace")
		return "", false
	}
	return target, true
}

func (h *Host) gitRepositories(w http.ResponseWriter, r *http.Request) {
	project, err := h.project(r.URL.Query().Get("projectId"))
	if err != nil {
		notFound(w)
		return
	}
	root, err := os.OpenRoot(project.Directory)
	if err != nil {
		writeError(w, 503, "project_unavailable", "The workspace folder is unavailable")
		return
	}
	defer root.Close()
	listing, err := root.Open(".")
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer listing.Close()
	entries, err := listing.ReadDir(501)
	if err != nil && !errors.Is(err, io.EOF) {
		fileFailure(w, err)
		return
	}
	if len(entries) > 500 {
		writeError(w, 413, "directory_too_large", "This workspace has too many folders to scan")
		return
	}
	repositories := []gitRepository{}
	if _, err := root.Lstat(".git"); err == nil {
		repositories = append(repositories, gitRepository{Name: project.Name, Path: "."})
	}
	for _, entry := range entries {
		if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		if _, err := root.Lstat(filepath.Join(entry.Name(), ".git")); err == nil {
			repositories = append(repositories, gitRepository{Name: entry.Name(), Path: entry.Name()})
		}
	}
	writeJSON(w, 200, map[string]any{"repositories": repositories})
}

func (h *Host) gitStatus(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	directory, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	branch, err := runGit(directory, 4096, "symbolic-ref", "--quiet", "--short", "HEAD")
	if err != nil {
		branch, err = runGit(directory, 4096, "rev-parse", "--short", "HEAD")
	}
	if err != nil {
		branch = []byte("No commits")
	}
	untracked := "normal"
	if requested := r.URL.Query().Get("untracked"); requested != "" {
		if requested != "all" {
			writeError(w, 400, "invalid_request", "untracked takes all")
			return
		}
		untracked = "all"
	}
	output, err := runGit(directory, 1<<20, "status", "--porcelain=v1", "-z", "--untracked-files="+untracked)
	if err != nil {
		writeError(w, 503, "git_unavailable", "Git status is unavailable")
		return
	}
	changes := []gitChange{}
	records := bytes.Split(output, []byte{0})
	for i := 0; i < len(records); i++ {
		record := records[i]
		if len(record) < 4 {
			continue
		}
		status := string(record[:2])
		change := gitChange{Path: string(record[3:]), Status: status, Index: gitStatusColumn(record[0]), Worktree: gitStatusColumn(record[1]), Conflicted: gitConflicted(record[0], record[1]), Untracked: status == "??"}
		if strings.ContainsAny(status, "RC") {
			// porcelain -z appends the old rename/copy path
			if i++; i < len(records) {
				change.OriginalPath = string(records[i])
			}
		}
		changes = append(changes, change)
		if len(changes) >= 501 {
			break
		}
	}
	truncated := len(changes) > 500
	if truncated {
		changes = changes[:500]
	}
	writeJSON(w, 200, map[string]any{"branch": strings.TrimSpace(string(branch)), "changes": changes, "truncated": truncated})
}

func (h *Host) gitDiff(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	directory, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	file, err := filePath(r.URL.Query().Get("file"), false)
	if err != nil {
		writeError(w, 400, "invalid_path", "Choose a relative repository file")
		return
	}
	staged, err := searchFlag(r.URL.Query().Get("staged"))
	if err != nil {
		writeError(w, 400, "invalid_request", "staged takes true or false")
		return
	}
	// against=index compares the working tree with the index: the changes
	// that are not staged yet. The default compares with HEAD.
	against := r.URL.Query().Get("against")
	if (against != "" && against != "head" && against != "index") || (staged && against == "index") {
		writeError(w, 400, "invalid_request", "against takes head or index, and index cannot be combined with staged")
		return
	}
	var output []byte
	if staged {
		// The index against HEAD (or against nothing before the first commit).
		output, err = runGit(directory, gitDiffLimit, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--", filepath.ToSlash(file))
	} else if against == "index" {
		output, err = runGit(directory, gitDiffLimit, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", filepath.ToSlash(file))
		if err == nil && len(output) == 0 {
			output = h.untrackedDiff(r.URL.Query().Get("projectId"), r.URL.Query().Get("path"), directory, file)
		}
	} else {
		output, err = runGit(directory, gitDiffLimit, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--", filepath.ToSlash(file))
		if err != nil {
			output, err = runGit(directory, gitDiffLimit, "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", filepath.ToSlash(file))
		}
		if err == nil && len(output) == 0 {
			output = h.untrackedDiff(r.URL.Query().Get("projectId"), r.URL.Query().Get("path"), directory, file)
		}
	}
	if err != nil {
		writeError(w, 503, "git_unavailable", "Git diff is unavailable")
		return
	}
	writeJSON(w, 200, map[string]string{"path": filepath.ToSlash(file), "diff": string(output)})
}

const gitDiffLimit = 256 << 10

// untrackedDiff shows an untracked file as a new file, the way Git would once
// it is added. The file is read through the project root and must be a
// regular file; anything else, or a diff over the size limit, stays empty.
func (h *Host) untrackedDiff(projectID, repository, directory, file string) []byte {
	status, err := runGit(directory, 64<<10, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", filepath.ToSlash(file))
	if err != nil || !bytes.HasPrefix(status, []byte("?? ")) {
		return nil
	}
	project, err := h.project(projectID)
	if err != nil {
		return nil
	}
	repositoryPath, err := filePath(repository, true)
	if err != nil {
		return nil
	}
	root, err := os.OpenRoot(project.Directory)
	if err != nil {
		return nil
	}
	defer root.Close()
	name := filepath.Join(repositoryPath, file)
	info, err := root.Lstat(name)
	if err != nil || !info.Mode().IsRegular() || info.Size() > gitDiffLimit {
		return nil
	}
	handle, err := openProjectFile(root, name)
	if err != nil {
		return nil
	}
	defer handle.Close()
	opened, err := handle.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(handle, gitDiffLimit+1))
	if err != nil || len(data) > gitDiffLimit {
		return nil
	}
	slash := filepath.ToSlash(file)
	mode := "100644"
	if opened.Mode().Perm()&0o111 != 0 {
		mode = "100755"
	}
	var diff bytes.Buffer
	diff.WriteString("diff --git a/" + slash + " b/" + slash + "\nnew file mode " + mode + "\n")
	switch {
	case len(data) == 0:
	case bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data):
		diff.WriteString("Binary files /dev/null and b/" + slash + " differ\n")
	default:
		lines := strings.SplitAfter(string(data), "\n")
		if lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
		count := "1"
		if len(lines) != 1 {
			count = "1," + strconv.Itoa(len(lines))
		}
		diff.WriteString("--- /dev/null\n+++ b/" + slash + "\n@@ -0,0 +" + count + " @@\n")
		for _, line := range lines {
			diff.WriteString("+" + line)
		}
		if !strings.HasSuffix(lines[len(lines)-1], "\n") {
			diff.WriteString("\n\\ No newline at end of file\n")
		}
	}
	if diff.Len() > gitDiffLimit {
		return nil
	}
	return diff.Bytes()
}
