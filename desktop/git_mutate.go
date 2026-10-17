package host

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Git changes: stage, unstage and commit, plus the commit identity. They run
// through runGitCall (git_command.go), one change per repository at a time.

const (
	gitMutationFiles = 500
	gitIndexBody     = 640 << 10 // up to 500 paths of 1024 bytes
	gitMessageLimit  = 16 << 10
	gitIdentityLimit = 200
)

// repositoryLock serializes Git changes to one repository.
type repositoryLock struct {
	slot  chan struct{}
	users int
}

// lockRepository waits up to gitLockWait for the repository's lock.
func (m *hostMutations) lockRepository(ctx context.Context, top string) (func(), bool) {
	m.mu.Lock()
	lock := m.gitLocks[top]
	if lock == nil {
		lock = &repositoryLock{slot: make(chan struct{}, 1)}
		m.gitLocks[top] = lock
	}
	lock.users++
	m.mu.Unlock()
	forget := func() {
		m.mu.Lock()
		if lock.users--; lock.users == 0 {
			delete(m.gitLocks, top)
		}
		m.mu.Unlock()
	}
	wait := time.NewTimer(m.gitLockWait)
	defer wait.Stop()
	select {
	case lock.slot <- struct{}{}:
		return func() { <-lock.slot; forget() }, true
	case <-wait.C:
	case <-ctx.Done():
	}
	forget()
	return nil, false
}

// decodeLimited is decode with a larger body limit.
func decodeLimited(w http.ResponseWriter, r *http.Request, out any, limit int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(out); err != nil {
		writeError(w, 400, "invalid_request", "Invalid JSON request")
		return false
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		writeError(w, 400, "invalid_request", "Only one JSON value is allowed")
		return false
	}
	return true
}

func gitTimedOut(w http.ResponseWriter) {
	writeErrorWith(w, 504, "git_timeout", "Git did not finish in time. The change may or may not have been made; check the status before trying again", map[string]any{"outcome": "unknown"})
}

func gitIndexIsLocked(w http.ResponseWriter) {
	writeError(w, 409, "git_index_locked", "Git's index is locked. If no other Git command is running, remove .git/index.lock")
}

func gitFailed(w http.ResponseWriter) {
	writeError(w, 500, "git_failed", "Git could not complete the change")
}

// gitMutationFailure chooses a safe error from Git's messages, which run in
// the C locale; the messages themselves are never returned.
func gitMutationFailure(w http.ResponseWriter, out gitOutcome) {
	if out.timedOut {
		gitTimedOut(w)
		return
	}
	text := string(out.stderr) + "\n" + string(out.stdout)
	switch {
	case strings.Contains(text, "index.lock"):
		gitIndexIsLocked(w)
	case strings.Contains(text, "unmerged") || strings.Contains(text, "unresolved conflict"):
		writeError(w, 409, "git_conflict", "Resolve the merge conflicts first")
	case strings.Contains(text, "did not match any file"), strings.Contains(text, "ignored by one of your .gitignore files"), strings.Contains(text, "beyond a symbolic link"), strings.Contains(text, "outside repository"), strings.Contains(text, "not removing"):
		writeError(w, 400, "git_path_invalid", "A path does not exist in this repository or is ignored")
	case strings.Contains(text, "nothing to commit"), strings.Contains(text, "nothing added to commit"), strings.Contains(text, "no changes added to commit"):
		writeError(w, 409, "git_nothing_to_commit", "Stage changes before committing")
	case strings.Contains(text, "Please tell me who you are"), strings.Contains(text, "empty ident"), strings.Contains(text, "unable to auto-detect email"):
		gitIdentityMissing(w)
	case strings.Contains(text, "gpg failed"), strings.Contains(text, "failed to sign"):
		gitSigningRequired(w)
	default:
		gitFailed(w)
	}
}

func gitIdentityMissing(w http.ResponseWriter) {
	writeError(w, 409, "git_identity_missing", "Set a commit name and email for this repository or send an author")
}

func gitSigningRequired(w http.ResponseWriter) {
	writeError(w, 409, "git_signing_required", "This repository requires signed commits, which AgentLand does not make; commit on the Mac")
}

// gitMutationRepository resolves the repository, takes its lock and refuses a
// leftover index lock, such as one left by a change that timed out. It holds
// the shared file-mutation lock from the resolution through the Git change:
// the resolved path is used later with Git's -C, and a concurrent move must
// not be able to redirect that use outside the project.
func (h *Host) gitMutationRepository(w http.ResponseWriter, r *http.Request, projectID, relative string) (string, func(), bool) {
	h.filesMu.Lock()
	top, ok := h.gitRoot(w, projectID, relative)
	if !ok {
		h.filesMu.Unlock()
		return "", nil, false
	}
	unlock, ok := h.mutations.lockRepository(r.Context(), top)
	if !ok {
		h.filesMu.Unlock()
		writeError(w, 409, "git_busy", "Another Git change is running in this repository")
		return "", nil, false
	}
	indexLock, err := runGit(top, 4096, "rev-parse", "--git-path", "index.lock")
	if err != nil {
		unlock()
		h.filesMu.Unlock()
		gitFailed(w)
		return "", nil, false
	}
	lockPath := strings.TrimRight(string(indexLock), "\r\n")
	if !filepath.IsAbs(lockPath) {
		lockPath = filepath.Join(top, lockPath)
	}
	if _, err := os.Lstat(lockPath); err == nil {
		unlock()
		h.filesMu.Unlock()
		gitIndexIsLocked(w)
		return "", nil, false
	}
	return top, func() {
		unlock()
		h.filesMu.Unlock()
	}, true
}

func (h *Host) runGitMutation(top string, timeout time.Duration, stdin io.Reader, env []string, args ...string) gitOutcome {
	// A change is not tied to the request: stopping Git halfway because the
	// client left could leave the repository locked.
	return runGitCall(context.Background(), gitCall{directory: top, args: args, timeout: timeout, stdoutLimit: 64 << 10, stdin: stdin, env: env})
}

// gitFileArguments validates the files of a stage or unstage request like file
// paths. A trailing slash, as Git status shows for an untracked folder, is
// accepted.
func gitFileArguments(files []string) ([]string, bool) {
	if len(files) == 0 || len(files) > gitMutationFiles {
		return nil, false
	}
	out := make([]string, 0, len(files))
	for _, file := range files {
		name, err := filePath(strings.TrimSuffix(file, "/"), false)
		if err != nil {
			return nil, false
		}
		out = append(out, filepath.ToSlash(name))
	}
	return out, true
}

// gitFilteredFiles reports whether any file the pathspecs cover has a Git
// filter (for example Git LFS). Staging such a file would run the filter
// program named by the repository's configuration.
func gitFilteredFiles(top string, files []string) (bool, error) {
	listed := runGitCall(context.Background(), gitCall{directory: top, args: append([]string{"ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"}, files...), timeout: gitReadTimeout, stdoutLimit: 8 << 20, strictOutput: true})
	if listed.err != nil {
		return false, listed.err
	}
	if len(listed.stdout) == 0 {
		return false, nil
	}
	checked := runGitCall(context.Background(), gitCall{directory: top, args: []string{"check-attr", "-z", "--stdin", "filter"}, timeout: gitReadTimeout, stdoutLimit: 32 << 20, stdin: bytes.NewReader(listed.stdout), strictOutput: true})
	if checked.err != nil {
		return false, checked.err
	}
	// -z output is path NUL attribute NUL value NUL for each path.
	fields := strings.Split(strings.TrimSuffix(string(checked.stdout), "\x00"), "\x00")
	for i := 2; i < len(fields); i += 3 {
		if value := fields[i]; value != "unspecified" && value != "unset" {
			return true, nil
		}
	}
	return false, nil
}

func (h *Host) gitStage(w http.ResponseWriter, r *http.Request)   { h.changeGitIndex(w, r, true) }
func (h *Host) gitUnstage(w http.ResponseWriter, r *http.Request) { h.changeGitIndex(w, r, false) }

func (h *Host) changeGitIndex(w http.ResponseWriter, r *http.Request, stage bool) {
	var in struct {
		ProjectID string   `json:"projectId"`
		Path      string   `json:"path"`
		Files     []string `json:"files"`
	}
	if !decodeLimited(w, r, &in, gitIndexBody) {
		return
	}
	files, ok := gitFileArguments(in.Files)
	if !ok {
		writeError(w, 400, "git_path_invalid", "Send 1 to 500 relative repository paths")
		return
	}
	top, unlock, ok := h.gitMutationRepository(w, r, in.ProjectID, in.Path)
	if !ok {
		return
	}
	defer unlock()
	var out gitOutcome
	if stage {
		filtered, err := gitFilteredFiles(top, files)
		if err != nil {
			gitFailed(w)
			return
		}
		if filtered {
			writeError(w, 409, "git_filter_unsupported", "Files handled by a Git filter, such as Git LFS, can't be staged here")
			return
		}
		out = h.runGitMutation(top, h.mutations.gitTimeout, nil, nil, append([]string{"add", "--"}, files...)...)
	} else {
		head := runGitCall(context.Background(), gitCall{directory: top, args: []string{"rev-parse", "--verify", "--quiet", "HEAD^{commit}"}, timeout: gitReadTimeout, stdoutLimit: 4096, strictOutput: true})
		switch {
		case head.err == nil:
			out = h.runGitMutation(top, h.mutations.gitTimeout, nil, nil, append([]string{"restore", "--staged", "--"}, files...)...)
		case head.exitCode == 1:
			// Before the first commit there is no HEAD to restore from; only
			// the index entries are removed, never the files.
			out = h.runGitMutation(top, h.mutations.gitTimeout, nil, nil, append([]string{"rm", "--cached", "-r", "-f", "-q", "--ignore-unmatch", "--"}, files...)...)
		default:
			gitFailed(w)
			return
		}
	}
	if out.err != nil {
		gitMutationFailure(w, out)
		return
	}
	key := "unstaged"
	if stage {
		key = "staged"
	}
	writeJSON(w, 200, map[string]int{key: len(files)})
}

// gitIdentity is the name and email a commit would use. Source is
// "repository" when both come from the repository's configuration, "user"
// when the user's global configuration supplies either, and "none" when one
// is missing.
type gitIdentity struct {
	Name   string `json:"name"`
	Email  string `json:"email"`
	Source string `json:"source"`
}

type gitConfigValues struct {
	name, email string
	signing     *bool
}

// readGitConfig reads user.name, user.email and commit.gpgsign from the
// repository's configuration, or, with user set, from the user's global
// configuration evaluated in the repository (so conditional includes apply).
func (h *Host) readGitConfig(top string, user bool) (gitConfigValues, error) {
	args := []string{"config"}
	if user {
		args = append(args, "--global")
	}
	args = append(args, "-z", "--includes", "--get-regexp", `^(user\.(name|email)|commit\.gpgsign)$`)
	out := runGitCall(context.Background(), gitCall{directory: top, args: args, timeout: gitReadTimeout, stdoutLimit: 64 << 10, strictOutput: true, userConfig: user, userConfigPath: h.mutations.gitUserConfig})
	values := gitConfigValues{}
	if out.err != nil {
		if out.exitCode == 1 && !out.timedOut && !out.overflow {
			return values, nil // nothing set
		}
		return values, out.err
	}
	for _, entry := range strings.Split(string(out.stdout), "\x00") {
		key, value, hasValue := strings.Cut(entry, "\n")
		switch strings.ToLower(key) {
		case "user.name":
			values.name = value
		case "user.email":
			values.email = value
		case "commit.gpgsign":
			// A key without "=" is true.
			enabled := !hasValue || gitBool(value)
			values.signing = &enabled
		}
	}
	return values, nil
}

func gitBool(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true", "yes", "on":
		return true
	case "false", "no", "off", "":
		return false
	}
	number, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && number != 0
}

// gitSettings resolves the commit identity and whether commits must be signed.
// The repository's settings win over the user's.
func (h *Host) gitSettings(top string) (gitIdentity, bool, error) {
	repository, err := h.readGitConfig(top, false)
	if err != nil {
		return gitIdentity{}, false, err
	}
	user, err := h.readGitConfig(top, true)
	if err != nil {
		user = gitConfigValues{}
	}
	identity := gitIdentity{Name: repository.name, Email: repository.email, Source: "repository"}
	if identity.Name == "" && user.name != "" {
		identity.Name, identity.Source = user.name, "user"
	}
	if identity.Email == "" && user.email != "" {
		identity.Email, identity.Source = user.email, "user"
	}
	if identity.Name == "" || identity.Email == "" {
		identity.Source = "none"
	}
	signing := repository.signing
	if signing == nil {
		signing = user.signing
	}
	return identity, signing != nil && *signing, nil
}

func (h *Host) gitIdentityRoute(w http.ResponseWriter, r *http.Request) {
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	top, ok := h.gitRoot(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("path"))
	if !ok {
		return
	}
	identity, _, err := h.gitSettings(top)
	if err != nil {
		writeError(w, 503, "git_unavailable", "Git configuration is unavailable")
		return
	}
	writeJSON(w, 200, identity)
}

// validGitIdentityPart accepts a name or email Git will store as given.
func validGitIdentityPart(value string) bool {
	if len(value) > gitIdentityLimit || !utf8.ValidString(value) || strings.TrimSpace(value) == "" {
		return false
	}
	for _, r := range value {
		if r == '<' || r == '>' || unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validCommitMessage(message string) bool {
	return len(message) <= gitMessageLimit && utf8.ValidString(message) && !strings.ContainsRune(message, 0) && strings.TrimSpace(message) != ""
}

// gitCommit commits the staged changes. The identity travels in the
// environment and the message on stdin, never in arguments. Hooks are
// disabled and signing is never attempted: a repository that requires
// signing is refused.
func (h *Host) gitCommit(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		Path      string `json:"path"`
		Message   string `json:"message"`
		Author    *struct {
			Name  string `json:"name"`
			Email string `json:"email"`
		} `json:"author,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validCommitMessage(in.Message) {
		writeError(w, 400, "invalid_request", "Write a commit message of at most 16 KiB")
		return
	}
	if in.Author != nil && (!validGitIdentityPart(in.Author.Name) || !validGitIdentityPart(in.Author.Email)) {
		writeError(w, 400, "invalid_request", "The author name and email must each be one line of at most 200 bytes without < or >")
		return
	}
	top, unlock, ok := h.gitMutationRepository(w, r, in.ProjectID, in.Path)
	if !ok {
		return
	}
	defer unlock()
	identity, signing, err := h.gitSettings(top)
	if err != nil {
		gitFailed(w)
		return
	}
	if signing {
		gitSigningRequired(w)
		return
	}
	name, email := identity.Name, identity.Email
	if in.Author != nil {
		name, email = in.Author.Name, in.Author.Email
	}
	if !validGitIdentityPart(name) || !validGitIdentityPart(email) {
		gitIdentityMissing(w)
		return
	}
	if h.nothingStaged(top) {
		writeError(w, 409, "git_nothing_to_commit", "Stage changes before committing")
		return
	}
	env := []string{"GIT_AUTHOR_NAME=" + name, "GIT_AUTHOR_EMAIL=" + email, "GIT_COMMITTER_NAME=" + name, "GIT_COMMITTER_EMAIL=" + email}
	out := h.runGitMutation(top, h.mutations.gitCommitTimeout, strings.NewReader(in.Message), env, "commit", "--quiet", "--no-verify", "--no-gpg-sign", "--cleanup=whitespace", "-F", "-")
	if out.err != nil {
		gitMutationFailure(w, out)
		return
	}
	commit, err := runGit(top, 4096, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		commit = nil // the commit exists; a missing hash must not look like a failure
	}
	writeJSON(w, 200, map[string]any{"commit": strings.TrimSpace(string(commit)), "hooksSkipped": true})
}

// nothingStaged reports an index that matches HEAD outside a merge. During a
// merge an unchanged index still makes a merge commit, so Git decides.
func (h *Host) nothingStaged(top string) bool {
	same := runGitCall(context.Background(), gitCall{directory: top, args: []string{"diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv"}, timeout: gitReadTimeout, stdoutLimit: 4096})
	if same.err != nil {
		return false
	}
	merging := runGitCall(context.Background(), gitCall{directory: top, args: []string{"rev-parse", "-q", "--verify", "MERGE_HEAD"}, timeout: gitReadTimeout, stdoutLimit: 4096})
	return merging.exitCode == 1
}
