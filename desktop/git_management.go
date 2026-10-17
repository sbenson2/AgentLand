package host

import (
	"context"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Git management uses the same scoped root, repository lock, bounded process
// runner and disabled hooks as stage/commit. These routes never run arbitrary
// revisions, URLs, refspecs, custom transports or force operations from a caller.
type gitBranchEntry struct {
	Name     string `json:"name"`
	Current  bool   `json:"current"`
	Remote   bool   `json:"remote"`
	Upstream string `json:"upstream,omitempty"`
	Ahead    int    `json:"ahead"`
	Behind   int    `json:"behind"`
}

func (h *Host) gitBranches(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	data, err := runGit(top, 256<<10, "for-each-ref", "--format=%(refname)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)", "refs/heads/", "refs/remotes/")
	if err != nil {
		writeError(w, 503, "git_unavailable", "Branches are unavailable")
		return
	}
	branches := []gitBranchEntry{}
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		fields := strings.Split(line, "\x00")
		if len(fields) != 4 {
			continue
		}
		remote := strings.HasPrefix(fields[0], "refs/remotes/")
		name := strings.TrimPrefix(strings.TrimPrefix(fields[0], "refs/heads/"), "refs/remotes/")
		if remote && strings.HasSuffix(name, "/HEAD") {
			continue
		}
		entry := gitBranchEntry{Name: name, Current: fields[1] == "*", Remote: remote, Upstream: fields[2]}
		tracking := strings.NewReplacer("[", "", "]", "", ",", " ").Replace(fields[3])
		parts := strings.Fields(tracking)
		for i := 0; i+1 < len(parts); i++ {
			switch parts[i] {
			case "ahead":
				entry.Ahead, _ = strconv.Atoi(parts[i+1])
			case "behind":
				entry.Behind, _ = strconv.Atoi(parts[i+1])
			}
		}
		branches = append(branches, entry)
	}
	writeJSON(w, 200, map[string]any{"branches": branches})
}

func validBranchName(top, name string) bool {
	if len(name) == 0 || len(name) > 200 || !utf8.ValidString(name) || strings.HasPrefix(name, "-") || strings.HasPrefix(name, "refs/") || strings.ContainsAny(name, "\r\n\x00") {
		return false
	}
	_, err := runGit(top, 4096, "check-ref-format", "--branch", name)
	return err == nil
}

func gitClean(w http.ResponseWriter, top string) bool {
	return gitCleanFiles(w, top, "normal")
}

func gitCleanFiles(w http.ResponseWriter, top, untracked string) bool {
	data, err := runGit(top, 1<<20, "status", "--porcelain=v1", "-z", "--untracked-files="+untracked)
	if err != nil {
		gitFailed(w)
		return false
	}
	if len(data) != 0 {
		writeError(w, 409, "git_changes_present", "Commit, stash or discard your changes before switching branches or pulling")
		return false
	}
	return true
}

// Checkout/stash can run clean/smudge/process filters from repository config.
// Until there is a safe filter integration, refuse repositories with these
// programs instead of silently running them on the host.
func gitSafeCheckout(w http.ResponseWriter, top string) bool {
	out := runGitCall(context.Background(), gitCall{directory: top, args: []string{"config", "--get-regexp", `^filter\..*\.(clean|smudge|process)$`}, stdoutLimit: 64 << 10, strictOutput: true})
	if out.exitCode == 1 && !out.timedOut && !out.overflow {
		return true
	}
	if out.err != nil {
		gitFailed(w)
		return false
	}
	writeError(w, 409, "git_filter_unsupported", "This repository uses Git filters. Switch branches, pull, discard or manage stashes on the Mac")
	return false
}

func (h *Host) gitBranch(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		Path      string `json:"path"`
		Action    string `json:"action"`
		Name      string `json:"name"`
		Source    string `json:"source"`
	}
	if !decode(w, r, &in) {
		return
	}
	top, unlock, ok := h.gitMutationRepository(w, r, in.ProjectID, in.Path)
	if !ok {
		return
	}
	defer unlock()
	if !validBranchName(top, in.Name) {
		writeError(w, 400, "git_branch_invalid", "Choose a valid branch name of at most 200 bytes")
		return
	}
	var args []string
	switch in.Action {
	case "create":
		args = []string{"branch", "--", in.Name}
	case "switch":
		if _, err := runGit(top, 4096, "show-ref", "--verify", "refs/heads/"+in.Name); err != nil {
			writeError(w, 404, "git_branch_missing", "The local branch is no longer available")
			return
		}
		if !gitClean(w, top) || !gitSafeCheckout(w, top) {
			return
		}
		args = []string{"switch", "--no-guess", "--", in.Name}
	case "track":
		if !validBranchName(top, in.Source) {
			writeError(w, 400, "git_branch_invalid", "Choose a remote branch from the list")
			return
		}
		if _, err := runGit(top, 4096, "show-ref", "--verify", "refs/remotes/"+in.Source); err != nil {
			writeError(w, 404, "git_branch_missing", "The remote branch is no longer available")
			return
		}
		if !gitClean(w, top) || !gitSafeCheckout(w, top) {
			return
		}
		args = []string{"switch", "--track", "-c", in.Name, "refs/remotes/" + in.Source}
	case "delete":
		current, _ := runGit(top, 4096, "symbolic-ref", "--quiet", "--short", "HEAD")
		if strings.TrimSpace(string(current)) == in.Name {
			writeError(w, 409, "git_current_branch", "Switch to another branch before deleting this one")
			return
		}
		ancestor := runGitCall(context.Background(), gitCall{directory: top, args: []string{"merge-base", "--is-ancestor", "refs/heads/" + in.Name, "HEAD"}, stdoutLimit: 4096})
		if ancestor.exitCode == 1 {
			writeError(w, 409, "git_branch_unmerged", "This branch has commits outside the current branch. Merge it on the Mac before deleting it")
			return
		}
		if ancestor.err != nil {
			writeError(w, 404, "git_branch_missing", "The local branch is no longer available")
			return
		}
		args = []string{"branch", "-d", "--", in.Name}
	default:
		writeError(w, 400, "invalid_request", "action takes create, switch, track or delete")
		return
	}
	out := h.runGitMutation(top, h.mutations.gitTimeout, nil, nil, args...)
	if out.err != nil {
		if strings.Contains(string(out.stderr), "already exists") {
			writeError(w, 409, "git_branch_exists", "A branch with this name already exists")
		} else {
			gitMutationFailure(w, out)
		}
		return
	}
	writeJSON(w, 200, map[string]bool{"changed": true})
}

var gitHashPattern = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

func validGitHash(hash string) bool { return gitHashPattern.MatchString(hash) }

type gitHistoryEntry struct {
	Hash      string `json:"hash"`
	Subject   string `json:"subject"`
	Author    string `json:"author"`
	Timestamp int64  `json:"timestamp"`
}

func (h *Host) gitHistory(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	offset := 0
	if cursor := r.URL.Query().Get("cursor"); cursor != "" {
		var err error
		offset, err = strconv.Atoi(cursor)
		if err != nil || offset < 0 || offset > 5000 {
			writeError(w, 400, "invalid_request", "The history cursor is invalid")
			return
		}
	}
	commits := []gitHistoryEntry{}
	head := runGitCall(context.Background(), gitCall{directory: top, args: []string{"rev-parse", "--verify", "--quiet", "HEAD^{commit}"}, stdoutLimit: 4096})
	if head.exitCode == 1 {
		writeJSON(w, 200, map[string]any{"commits": commits})
		return
	}
	data, err := runGit(top, 512<<10, "log", "-31", "--skip="+strconv.Itoa(offset), "--format=%H%x00%an%x00%at%x00%s%x00", "HEAD", "--")
	if err != nil {
		writeError(w, 503, "git_unavailable", "Commit history is unavailable")
		return
	}
	fields := strings.Split(string(data), "\x00")
	for i := 0; i+3 < len(fields); i += 4 {
		hash := strings.TrimLeft(fields[i], "\n")
		if !validGitHash(hash) {
			continue
		}
		timestamp, _ := strconv.ParseInt(fields[i+2], 10, 64)
		commits = append(commits, gitHistoryEntry{Hash: hash, Author: fields[i+1], Timestamp: timestamp, Subject: fields[i+3]})
	}
	next := ""
	if len(commits) > 30 {
		commits = commits[:30]
		if offset+30 <= 5000 {
			next = strconv.Itoa(offset + 30)
		}
	}
	writeJSON(w, 200, map[string]any{"commits": commits, "nextCursor": next})
}

func (h *Host) gitCommitRoot(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	hash := r.URL.Query().Get("commit")
	if !validGitHash(hash) {
		writeError(w, 400, "git_commit_invalid", "Choose a full commit hash from the history")
		return "", "", false
	}
	top, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return "", "", false
	}
	verified, err := runGit(top, 4096, "rev-parse", "--verify", hash+"^{commit}")
	if err != nil || strings.TrimSpace(string(verified)) != hash {
		writeError(w, 404, "git_commit_missing", "This commit is no longer available")
		return "", "", false
	}
	return top, hash, true
}

func (h *Host) gitCommitFiles(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, hash, ok := h.gitCommitRoot(w, r)
	if !ok {
		return
	}
	stash, ok := gitStashPreview(w, r, top, hash)
	if !ok {
		return
	}
	data, err := runGit(top, 1<<20, "diff-tree", "--root", "--first-parent", "-m", "--no-commit-id", "--name-status", "-r", "-z", "--no-renames", hash, "--")
	if err != nil {
		writeError(w, 503, "git_unavailable", "Commit files are unavailable")
		return
	}
	if stash {
		// stash's third parent, when present, is the separate commit of
		// untracked files. Its root diff complements the tracked-file diff.
		third := runGitCall(context.Background(), gitCall{directory: top, args: []string{"rev-parse", "--verify", "--quiet", hash + "^3^{commit}"}, stdoutLimit: 4096})
		if third.err == nil {
			untracked, readErr := runGit(top, 1<<20, "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "--no-renames", strings.TrimSpace(string(third.stdout)), "--")
			if readErr != nil {
				writeError(w, 503, "git_unavailable", "Stash files are unavailable")
				return
			}
			data = append(data, untracked...)
		}
	}
	files := []map[string]string{}
	parts := strings.Split(string(data), "\x00")
	for i := 0; i+1 < len(parts) && len(files) < 500; i += 2 {
		if parts[i] == "" {
			continue
		}
		files = append(files, map[string]string{"status": parts[i], "path": parts[i+1]})
	}
	writeJSON(w, 200, map[string]any{"hash": hash, "files": files, "truncated": len(parts)/2 > 500})
}

func (h *Host) gitCommitDiff(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, hash, ok := h.gitCommitRoot(w, r)
	if !ok {
		return
	}
	stash, ok := gitStashPreview(w, r, top, hash)
	if !ok {
		return
	}
	file, err := filePath(r.URL.Query().Get("file"), false)
	if err != nil {
		writeError(w, 400, "git_path_invalid", "Choose a relative repository file")
		return
	}
	data, err := runGit(top, gitDiffLimit, "show", "--format=", "--first-parent", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", hash, "--", filepath.ToSlash(file))
	if err == nil && len(data) == 0 && stash {
		third := runGitCall(context.Background(), gitCall{directory: top, args: []string{"rev-parse", "--verify", "--quiet", hash + "^3^{commit}"}, stdoutLimit: 4096})
		if third.err == nil {
			data, err = runGit(top, gitDiffLimit, "show", "--format=", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", strings.TrimSpace(string(third.stdout)), "--", filepath.ToSlash(file))
		}
	}
	if err != nil {
		writeError(w, 503, "git_unavailable", "The commit diff is unavailable or exceeds 256 KB")
		return
	}
	writeJSON(w, 200, map[string]string{"path": filepath.ToSlash(file), "diff": string(data)})
}

func gitStashPreview(w http.ResponseWriter, r *http.Request, top, hash string) (bool, bool) {
	stash, err := searchFlag(r.URL.Query().Get("stash"))
	if err != nil {
		writeError(w, 400, "invalid_request", "stash takes true or false")
		return false, false
	}
	if stash {
		list, err := readGitStashes(top)
		if err != nil {
			writeError(w, 503, "git_unavailable", "Stashes are unavailable")
			return false, false
		}
		for _, entry := range list {
			if entry.Hash == hash {
				return true, true
			}
		}
		writeError(w, 409, "git_stash_missing", "This stash is no longer available. Refresh the list")
		return false, false
	}
	return false, true
}

type gitStashEntry struct {
	Hash      string `json:"hash"`
	Message   string `json:"message"`
	Timestamp int64  `json:"timestamp"`
}

func readGitStashes(top string) ([]gitStashEntry, error) {
	data, err := runGit(top, 256<<10, "stash", "list", "-100", "--format=%H%x00%gs%x00%ct%x00")
	if err != nil {
		return nil, err
	}
	list := []gitStashEntry{}
	fields := strings.Split(string(data), "\x00")
	for i := 0; i+2 < len(fields); i += 3 {
		hash := strings.TrimLeft(fields[i], "\n")
		if !validGitHash(hash) {
			continue
		}
		timestamp, _ := strconv.ParseInt(fields[i+2], 10, 64)
		list = append(list, gitStashEntry{Hash: hash, Message: fields[i+1], Timestamp: timestamp})
	}
	return list, nil
}
func (h *Host) gitStashes(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	list, err := readGitStashes(top)
	if err != nil {
		writeError(w, 503, "git_unavailable", "Stashes are unavailable")
		return
	}
	writeJSON(w, 200, map[string]any{"stashes": list})
}
func (h *Host) gitStash(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID        string `json:"projectId"`
		Path             string `json:"path"`
		Action           string `json:"action"`
		Hash             string `json:"hash"`
		Message          string `json:"message"`
		IncludeUntracked bool   `json:"includeUntracked"`
	}
	if !decode(w, r, &in) {
		return
	}
	top, unlock, ok := h.gitMutationRepository(w, r, in.ProjectID, in.Path)
	if !ok {
		return
	}
	defer unlock()
	var args, env []string
	switch in.Action {
	case "save":
		if len(in.Message) > 1024 || !utf8.ValidString(in.Message) || strings.ContainsAny(in.Message, "\x00\r\n") {
			writeError(w, 400, "invalid_request", "Use a one-line stash message of at most 1 KB")
			return
		}
		if !gitSafeCheckout(w, top) {
			return
		}
		untracked := "no"
		if in.IncludeUntracked {
			untracked = "normal"
		}
		pending, err := runGit(top, 1<<20, "status", "--porcelain=v1", "-z", "--untracked-files="+untracked)
		if err != nil {
			gitFailed(w)
			return
		}
		if len(pending) == 0 {
			writeError(w, 409, "git_nothing_to_stash", "There are no changes to stash. Include untracked files to save new files")
			return
		}
		identity, _, err := h.gitSettings(top)
		if err != nil {
			gitFailed(w)
			return
		}
		if !validGitIdentityPart(identity.Name) || !validGitIdentityPart(identity.Email) {
			gitIdentityMissing(w)
			return
		}
		env = []string{"GIT_AUTHOR_NAME=" + identity.Name, "GIT_AUTHOR_EMAIL=" + identity.Email, "GIT_COMMITTER_NAME=" + identity.Name, "GIT_COMMITTER_EMAIL=" + identity.Email,
			// stash push --include-untracked removes the files it saved with Git's own pathspec magic, which
			// GIT_LITERAL_PATHSPECS=1 (gitEnvironment) turns off: the untracked files were saved and also
			// left in place. This push names no paths at all, so nothing a device sends is a pathspec here.
			"GIT_LITERAL_PATHSPECS=0"}
		args = []string{"-c", "commit.gpgsign=false", "stash", "push", "--message", in.Message}
		if in.IncludeUntracked {
			args = append(args, "--include-untracked")
		}
	case "apply", "drop":
		if !validGitHash(in.Hash) {
			writeError(w, 400, "git_commit_invalid", "Choose a stash from the list")
			return
		}
		list, err := readGitStashes(top)
		if err != nil {
			gitFailed(w)
			return
		}
		index := -1
		for i, stash := range list {
			if stash.Hash == in.Hash {
				index = i
				break
			}
		}
		if index < 0 {
			writeError(w, 409, "git_stash_missing", "This stash is no longer available. Refresh the list")
			return
		}
		if in.Action == "drop" {
			args = []string{"stash", "drop", "stash@{" + strconv.Itoa(index) + "}"}
		} else {
			if !gitSafeCheckout(w, top) || !gitCleanFiles(w, top, "no") {
				return
			}
			args = []string{"stash", "apply", "--index", in.Hash}
		}
	default:
		writeError(w, 400, "invalid_request", "action takes save, apply or drop")
		return
	}
	out := h.runGitMutation(top, h.mutations.gitTimeout, nil, env, args...)
	if out.err != nil {
		if in.Action == "apply" && !out.timedOut {
			writeError(w, 409, "git_stash_conflict", "The stash was kept. Applying it may have left conflicts in the files; inspect the changes and resolve them on the Mac")
		} else {
			gitMutationFailure(w, out)
		}
		return
	}
	writeJSON(w, 200, map[string]bool{"changed": true})
}

func (h *Host) gitDiscard(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string   `json:"projectId"`
		Path      string   `json:"path"`
		Files     []string `json:"files"`
		Confirmed bool     `json:"confirmed"`
	}
	if !decodeLimited(w, r, &in, gitIndexBody) {
		return
	}
	if !in.Confirmed {
		writeError(w, 400, "git_confirmation_required", "Confirm discarding these unstaged changes")
		return
	}
	files, ok := gitFileArguments(in.Files)
	if !ok {
		writeError(w, 400, "git_path_invalid", "Choose 1 to 500 tracked files")
		return
	}
	top, unlock, ok := h.gitMutationRepository(w, r, in.ProjectID, in.Path)
	if !ok {
		return
	}
	defer unlock()
	if !gitSafeCheckout(w, top) {
		return
	}
	// Every supplied path must name one indexed file, not a directory or an
	// untracked item. restore --worktree keeps the index and never uses clean.
	for _, file := range files {
		data, err := runGit(top, 64<<10, "ls-files", "--error-unmatch", "-z", "--", file)
		if err != nil || string(data) != file+"\x00" {
			writeError(w, 400, "git_path_invalid", "Only individual tracked files can be discarded")
			return
		}
	}
	out := h.runGitMutation(top, h.mutations.gitTimeout, nil, nil, append([]string{"restore", "--worktree", "--"}, files...)...)
	if out.err != nil {
		gitMutationFailure(w, out)
		return
	}
	writeJSON(w, 200, map[string]bool{"changed": true})
}

type gitRemoteEntry struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	Supported bool   `json:"supported"`
}

func safeRemoteURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err == nil && parsed.Host != "" {
		switch parsed.Scheme {
		case "https", "http", "ssh", "git":
			return !strings.ContainsAny(raw, "\r\n\x00")
		}
	}
	// scp-like SSH URL: [user@]host:path. No flags, local paths or helper syntax.
	host, path, ok := strings.Cut(raw, ":")
	return ok && path != "" && host != "" && !strings.HasPrefix(host, "-") && !strings.Contains(host, "/") && !strings.ContainsAny(raw, " \t\r\n\x00") && !strings.Contains(raw, "::")
}
func remoteConfig(top, name, key string) string {
	data, _ := runGit(top, 64<<10, "config", "--get", "remote."+name+"."+key)
	return strings.TrimSpace(string(data))
}
func remoteDisplayURL(raw string) string {
	if parsed, err := url.Parse(raw); err == nil && parsed.Host != "" {
		parsed.User = nil
		parsed.RawQuery = ""
		parsed.Fragment = ""
		return parsed.String()
	}
	return raw
}
func readGitRemotes(top string) ([]gitRemoteEntry, error) {
	data, err := runGit(top, 64<<10, "remote")
	if err != nil {
		return nil, err
	}
	list := []gitRemoteEntry{}
	for _, name := range strings.Fields(string(data)) {
		// get-url includes insteadOf/pushInsteadOf rewrites and all push URLs.
		// Validate what Git will actually contact, including secondary targets.
		fetchURLs, fetchErr := runGit(top, 64<<10, "remote", "get-url", "--all", "--", name)
		pushURLs, pushErr := runGit(top, 64<<10, "remote", "get-url", "--push", "--all", "--", name)
		raw := strings.Split(strings.TrimSpace(string(fetchURLs)), "\n")[0]
		supported := fetchErr == nil && pushErr == nil && remoteConfig(top, name, "vcs") == ""
		for _, candidate := range strings.Split(strings.TrimSpace(string(fetchURLs))+"\n"+strings.TrimSpace(string(pushURLs)), "\n") {
			if !safeRemoteURL(candidate) {
				supported = false
			}
		}
		list = append(list, gitRemoteEntry{Name: name, URL: remoteDisplayURL(raw), Supported: supported})
	}
	return list, nil
}
func (h *Host) gitRemotes(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	list, err := readGitRemotes(top)
	if err != nil {
		writeError(w, 503, "git_unavailable", "Remotes are unavailable")
		return
	}
	writeJSON(w, 200, map[string]any{"remotes": list})
}

func safeNetworkGitArgs(remote string) []string {
	return []string{"-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "protocol.http.allow=always", "-c", "protocol.ssh.allow=always", "-c", "protocol.git.allow=always", "-c", "credential.helper=", "-c", "credential.interactive=false", "-c", "core.askPass=", "-c", "core.sshCommand=/usr/bin/ssh -F /dev/null -o BatchMode=yes", "-c", "core.gitProxy=none", "-c", "submodule.recurse=false", "-c", "remote." + remote + ".uploadpack=git-upload-pack", "-c", "remote." + remote + ".receivepack=git-receive-pack"}
}
func (h *Host) gitRemote(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		Path      string `json:"path"`
		Action    string `json:"action"`
		Remote    string `json:"remote"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.Remote) == 0 || len(in.Remote) > 200 || strings.HasPrefix(in.Remote, "-") || strings.ContainsAny(in.Remote, "/:\r\n\x00 \t") {
		writeError(w, 400, "git_remote_invalid", "Choose a configured remote name")
		return
	}
	top, unlock, ok := h.gitMutationRepository(w, r, in.ProjectID, in.Path)
	if !ok {
		return
	}
	defer unlock()
	list, err := readGitRemotes(top)
	if err != nil {
		gitFailed(w)
		return
	}
	var chosen *gitRemoteEntry
	for i := range list {
		if list[i].Name == in.Remote {
			chosen = &list[i]
			break
		}
	}
	if chosen == nil {
		writeError(w, 400, "git_remote_invalid", "The remote is no longer configured")
		return
	}
	if !chosen.Supported {
		writeError(w, 409, "git_remote_unsupported", "Only configured HTTP, HTTPS, SSH and Git network remotes are supported")
		return
	}
	branchData, _ := runGit(top, 4096, "symbolic-ref", "--quiet", "--short", "HEAD")
	branch := strings.TrimSpace(string(branchData))
	if in.Action != "fetch" && !validBranchName(top, branch) {
		writeError(w, 409, "git_detached_head", "Switch to a local branch before pulling or pushing")
		return
	}
	networkArgs := safeNetworkGitArgs(in.Remote)
	// Empty values deliberately override repository/inherited prompt and
	// proxy programs. Terminal-prompt suppression alone does not stop askpass.
	networkEnv := []string{"GIT_ASKPASS=", "SSH_ASKPASS=", "GIT_PROXY_COMMAND="}
	fetch := func() gitOutcome {
		return h.runGitMutation(top, h.mutations.gitCommitTimeout, nil, networkEnv, append(networkArgs, "fetch", "--no-recurse-submodules", "--no-tags", "--", in.Remote, "+refs/heads/*:refs/remotes/"+in.Remote+"/*")...)
	}
	var out gitOutcome
	switch in.Action {
	case "fetch":
		out = fetch()
	case "pull":
		if !gitClean(w, top) || !gitSafeCheckout(w, top) {
			return
		}
		mergeData, _ := runGit(top, 4096, "config", "--get", "branch."+branch+".merge")
		trackedRemote, _ := runGit(top, 4096, "config", "--get", "branch."+branch+".remote")
		mergeRef := strings.TrimSpace(string(mergeData))
		if strings.TrimSpace(string(trackedRemote)) != in.Remote || !strings.HasPrefix(mergeRef, "refs/heads/") || !validBranchName(top, strings.TrimPrefix(mergeRef, "refs/heads/")) {
			writeError(w, 409, "git_upstream_missing", "This branch has no upstream on that remote. Set its upstream on the Mac before pulling")
			return
		}
		out = fetch()
		if out.err != nil {
			gitMutationFailure(w, out)
			return
		}
		target := "refs/remotes/" + in.Remote + "/" + strings.TrimPrefix(mergeRef, "refs/heads/")
		ancestor := runGitCall(context.Background(), gitCall{directory: top, args: []string{"merge-base", "--is-ancestor", "HEAD", target}, stdoutLimit: 4096})
		if ancestor.exitCode == 1 {
			ahead := runGitCall(context.Background(), gitCall{directory: top, args: []string{"merge-base", "--is-ancestor", target, "HEAD"}, stdoutLimit: 4096})
			if ahead.err == nil {
				writeJSON(w, 200, map[string]bool{"changed": true})
				return
			}
			writeError(w, 409, "git_diverged", "The branches have diverged. Merge or rebase them on the Mac; the working files were kept")
			return
		}
		if ancestor.err != nil {
			gitFailed(w)
			return
		}
		out = h.runGitMutation(top, h.mutations.gitTimeout, nil, nil, "merge", "--ff-only", "--no-edit", target)
	case "push":
		target := branch
		trackedRemote, _ := runGit(top, 4096, "config", "--get", "branch."+branch+".remote")
		mergeData, _ := runGit(top, 4096, "config", "--get", "branch."+branch+".merge")
		mergeRef := strings.TrimSpace(string(mergeData))
		if strings.TrimSpace(string(trackedRemote)) == in.Remote && strings.HasPrefix(mergeRef, "refs/heads/") {
			target = strings.TrimPrefix(mergeRef, "refs/heads/")
		}
		if !validBranchName(top, target) {
			writeError(w, 400, "git_branch_invalid", "The upstream branch is invalid")
			return
		}
		pushArgs := []string{"push", "--no-verify", "--recurse-submodules=no"}
		// A first push publishes this branch's upstream so subsequent pulls
		// work on the phone. An existing upstream is never overwritten.
		if strings.TrimSpace(string(trackedRemote)) == "" || mergeRef == "" {
			pushArgs = append(pushArgs, "--set-upstream")
		}
		pushArgs = append(pushArgs, "--", in.Remote, "HEAD:refs/heads/"+target)
		out = h.runGitMutation(top, h.mutations.gitCommitTimeout, nil, networkEnv, append(networkArgs, pushArgs...)...)
	default:
		writeError(w, 400, "invalid_request", "action takes fetch, pull or push")
		return
	}
	if out.err != nil {
		text := string(out.stderr)
		if !out.timedOut && (strings.Contains(text, "non-fast-forward") || strings.Contains(text, "fetch first")) {
			writeError(w, 409, "git_diverged", "The remote has commits that are missing here. Fetch and inspect history; merge or rebase on the Mac before pushing")
		} else if !out.timedOut {
			writeErrorWith(w, 409, "git_remote_failed", "The remote operation was not confirmed. Refresh Git and check access and authentication on the Mac before trying again", map[string]any{"outcome": "unknown"})
		} else {
			gitMutationFailure(w, out)
		}
		return
	}
	writeJSON(w, 200, map[string]bool{"changed": true})
}
