package host

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// searchLimits bounds one GET /v1/files/search.
type searchLimits struct {
	files       int   // files examined
	bytes       int64 // file contents read
	matches     int   // matching lines returned in total
	fileMatches int   // matching lines returned per file
	timeout     time.Duration
}

var defaultSearchLimits = searchLimits{files: 20000, bytes: 64 << 20, matches: 500, fileMatches: 20, timeout: 5 * time.Second}

const (
	searchQueryLimit      = 512
	searchIncludeLimit    = 256
	searchIncludePatterns = 16
	searchPreviewBytes    = 240
	searchPreviewLead     = 60
	searchPathLimit       = 1024
)

var (
	errSearchSuperseded = errors.New("a newer search from this device replaced this one")
	errSearchTimeLimit  = errors.New("the search time limit was reached")
)

type searchMatch struct {
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	Preview string `json:"preview"`
}

type searchResult struct {
	Path    string        `json:"path"`
	Matches []searchMatch `json:"matches"`
	// Truncated says this file has more matching lines than it returned.
	Truncated bool `json:"truncated,omitempty"`
}

type activeSearch struct{ cancel context.CancelCauseFunc }

// startSearch makes this the device's one running search: an earlier one is
// cancelled with errSearchSuperseded. The context also ends with the request
// and at the time limit.
func (m *hostMutations) startSearch(parent context.Context, device string) (context.Context, func()) {
	ctx, cancel := context.WithCancelCause(parent)
	current := &activeSearch{cancel: cancel}
	m.mu.Lock()
	if previous := m.searches[device]; previous != nil {
		previous.cancel(errSearchSuperseded)
	}
	m.searches[device] = current
	m.mu.Unlock()
	timed, stop := context.WithTimeoutCause(ctx, m.search.timeout, errSearchTimeLimit)
	return timed, func() {
		stop()
		cancel(nil)
		m.mu.Lock()
		if m.searches[device] == current {
			delete(m.searches, device)
		}
		m.mu.Unlock()
	}
}

// lineMatcher returns the byte offset of the first match in one line.
type lineMatcher func(line string) (int, bool)

// compileSearch returns a line matcher and, for plain text, a whole-file test
// that skips files without a match quickly. Plain text cannot span lines, so
// the whole-file test never hides a matching line.
func compileSearch(query string, regex, caseSensitive bool) (lineMatcher, func(string) bool, error) {
	if !regex && caseSensitive {
		return func(line string) (int, bool) {
			index := strings.Index(line, query)
			return index, index >= 0
		}, func(text string) bool { return strings.Contains(text, query) }, nil
	}
	pattern := query
	if !regex {
		pattern = regexp.QuoteMeta(query)
	}
	if !caseSensitive {
		pattern = "(?i)" + pattern
	}
	expression, err := regexp.Compile(pattern)
	if err != nil {
		return nil, nil, err
	}
	var quick func(string) bool
	if !regex {
		quick = expression.MatchString
		if asciiOnly(query) {
			// In ASCII text an ASCII query matches exactly where its ASCII
			// lowercase form does; only other text needs Unicode case folding.
			lowered := strings.ToLower(query)
			quick = func(text string) bool {
				if !asciiOnly(text) {
					return expression.MatchString(text)
				}
				return strings.Contains(strings.ToLower(text), lowered)
			}
		}
	}
	return func(line string) (int, bool) {
		location := expression.FindStringIndex(line)
		if location == nil {
			return 0, false
		}
		return location[0], true
	}, quick, nil
}

func asciiOnly(text string) bool {
	for i := 0; i < len(text); i++ {
		if text[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// parseSearchInclude reads comma-separated glob patterns. A pattern without
// "/" matches a file's name; one with "/" matches its project-relative path.
func parseSearchInclude(raw string) ([]string, error) {
	if raw == "" {
		return nil, nil
	}
	parts := strings.Split(raw, ",")
	if len(raw) > searchIncludeLimit || len(parts) > searchIncludePatterns {
		return nil, errors.New("too many include patterns")
	}
	patterns := []string{}
	for _, part := range parts {
		pattern := strings.TrimSpace(part)
		if pattern == "" {
			continue
		}
		if _, err := path.Match(pattern, ""); err != nil {
			return nil, err
		}
		patterns = append(patterns, pattern)
	}
	return patterns, nil
}

func searchIncluded(patterns []string, name string) bool {
	if len(patterns) == 0 {
		return true
	}
	base := path.Base(name)
	for _, pattern := range patterns {
		target := base
		if strings.Contains(pattern, "/") {
			target = name
		}
		if matched, _ := path.Match(pattern, target); matched {
			return true
		}
	}
	return false
}

func searchFlag(value string) (bool, error) {
	if value == "" {
		return false, nil
	}
	return strconv.ParseBool(value)
}

// searchPreview returns at most searchPreviewBytes of the line around the match,
// cut at character boundaries.
func searchPreview(line string, match int) string {
	if len(line) <= searchPreviewBytes {
		return line
	}
	from := max(0, min(match-searchPreviewLead, len(line)-searchPreviewBytes))
	for from < len(line) && !utf8.RuneStart(line[from]) {
		from++
	}
	to := min(len(line), from+searchPreviewBytes)
	for to < len(line) && to > from && !utf8.RuneStart(line[to]) {
		to--
	}
	return line[from:to]
}

// fileSearch walks one search. Every folder is held open as its own os.Root,
// so each entry costs one lookup relative to its folder rather than a walk
// from the project root. No symlink is followed: an entry is used only when
// the handle opened for it is the file or folder its lstat named.
type fileSearch struct {
	ctx       context.Context
	root      *os.Root // the project
	directory string   // absolute project directory, used to run Git
	match     lineMatcher
	quick     func(string) bool
	include   []string
	limits    searchLimits
	hook      func(context.Context)
	// folders keeps the folders of Git-listed names open, by project path.
	folders map[string]*os.Root

	files     int
	bytes     int64
	matches   int
	results   []searchResult
	truncated string
}

const searchOpenFolders = 64

func (s *fileSearch) done() bool { return s.truncated != "" || s.ctx.Err() != nil }

func (s *fileSearch) stop(reason string) {
	if s.truncated == "" {
		s.truncated = reason
	}
}

func (s *fileSearch) closeFolders() {
	for name, folder := range s.folders {
		folder.Close()
		delete(s.folders, name)
	}
}

// folder opens a project folder through the project root, reusing the few
// kept open. Git lists paths in order, so neighbors share a folder.
func (s *fileSearch) folder(rel string) (*os.Root, bool) {
	if folder := s.folders[rel]; folder != nil {
		return folder, true
	}
	if len(s.folders) >= searchOpenFolders {
		s.closeFolders()
	}
	folder, err := s.root.OpenRoot(rel)
	if err != nil {
		return nil, false
	}
	s.folders[rel] = folder
	return folder, true
}

// searchFolder searches one folder: with Git's file list when it is in a
// repository whose top level is inside the project, and otherwise by walking.
func (s *fileSearch) searchFolder(rel string, folder *os.Root, start bool) {
	if s.done() || s.listWithGit(rel, folder, start) || s.done() {
		return
	}
	s.walk(rel, folder)
}

// inRepository reports a .git entry in the folder or, for the start folder, in
// a folder above it inside the project. Git runs only then: a repository above
// the project (such as a home folder under version control) does not decide
// what the project's search sees, and a project without Git never starts it.
func (s *fileSearch) inRepository(rel string, folder *os.Root, start bool) bool {
	if _, err := folder.Lstat(".git"); err == nil {
		return true
	}
	for directory := rel; start && directory != "."; {
		directory = filepath.Dir(directory)
		if _, err := s.root.Lstat(filepath.Join(directory, ".git")); err == nil {
			return true
		}
	}
	return false
}

// listWithGit lists tracked files and untracked files that are not ignored. It
// reports false, and the folder is walked instead, when Git cannot list it.
func (s *fileSearch) listWithGit(rel string, folder *os.Root, start bool) bool {
	if !s.inRepository(rel, folder, start) {
		return false
	}
	directory, ok := s.gitDirectory(rel, folder)
	if !ok {
		return false
	}
	inside := runGitCall(s.ctx, gitCall{directory: directory, args: []string{"rev-parse", "--is-inside-work-tree"}, timeout: gitReadTimeout, stdoutLimit: 64, strictOutput: true})
	if inside.err != nil || strings.TrimSpace(string(inside.stdout)) != "true" {
		return false
	}
	listed := false
	err := streamGit(s.ctx, directory, []string{"ls-files", "-z", "--cached", "--others", "--exclude-standard"}, func(entry string) bool {
		listed = true
		s.searchListed(rel, entry)
		return !s.done()
	})
	return err == nil || listed
}

// gitDirectory returns the absolute path of the folder for running Git, only
// while that path still names the folder opened through the project root. Git
// only lists names; every file is then opened through the root.
func (s *fileSearch) gitDirectory(rel string, folder *os.Root) (string, bool) {
	if s.directory == "" {
		return "", false
	}
	opened, err := folder.Stat(".")
	if err != nil {
		return "", false
	}
	absolute := filepath.Join(s.directory, rel)
	named, err := os.Stat(absolute)
	if err != nil || !os.SameFile(opened, named) {
		return "", false
	}
	return absolute, true
}

// searchListed handles one entry of git ls-files, relative to the folder at
// base. A nested repository is listed as a folder ("name/"); Git does not list
// into it, so it is searched on its own.
func (s *fileSearch) searchListed(base, entry string) {
	name, err := filePath(strings.TrimSuffix(entry, "/"), false)
	if err != nil {
		return
	}
	rel := filepath.Join(base, name)
	folder, ok := s.folder(filepath.Dir(rel))
	if !ok {
		return
	}
	s.searchEntry(folder, filepath.Base(rel), rel)
}

func (s *fileSearch) walk(rel string, folder *os.Root) {
	listing, err := openProjectFile(folder, ".")
	if err != nil {
		return
	}
	entries, _ := listing.ReadDir(s.limits.files + 1)
	listing.Close()
	crowded := len(entries) > s.limits.files
	if crowded {
		entries = entries[:s.limits.files]
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		if s.done() {
			return
		}
		if entry.Name() == ".git" || entry.Type()&fs.ModeSymlink != 0 {
			continue
		}
		if entry.IsDir() || entry.Type().IsRegular() {
			s.searchEntry(folder, entry.Name(), filepath.Join(rel, entry.Name()))
		}
	}
	if crowded {
		s.stop("files")
	}
}

// searchEntry searches base in folder; rel is its path in the project. A
// folder is searched recursively (from Git's list, it is a nested repository
// or a submodule), a regular file is read, and anything else is skipped.
func (s *fileSearch) searchEntry(folder *os.Root, base, rel string) {
	name := filepath.ToSlash(rel)
	if _, err := filePath(name, false); err != nil || hasGitElement(name) {
		return
	}
	info, err := folder.Lstat(base)
	if err != nil {
		return
	}
	switch {
	case info.IsDir():
		inner, err := folder.OpenRoot(base)
		if err != nil {
			return
		}
		defer inner.Close()
		if opened, err := inner.Stat("."); err == nil && os.SameFile(info, opened) {
			s.searchFolder(rel, inner, false)
		}
	case info.Mode().IsRegular() && searchIncluded(s.include, name):
		s.searchFile(folder, base, name, info)
	}
}

func hasGitElement(name string) bool {
	for _, element := range strings.Split(name, "/") {
		if element == ".git" {
			return true
		}
	}
	return false
}

// searchFile reads one regular text file of at most 1 MiB and records its
// matching lines. Files with NUL bytes or invalid UTF-8 are skipped.
func (s *fileSearch) searchFile(folder *os.Root, base, name string, info os.FileInfo) {
	if s.hook != nil {
		s.hook(s.ctx)
	}
	if s.done() {
		return
	}
	if s.files >= s.limits.files {
		s.stop("files")
		return
	}
	s.files++
	if info.Size() > maxTextFile {
		return
	}
	if s.bytes+info.Size() > s.limits.bytes {
		s.stop("bytes")
		return
	}
	file, err := openProjectFile(folder, base)
	if err != nil {
		return
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		return
	}
	data, err := io.ReadAll(io.LimitReader(file, maxTextFile+1))
	s.bytes += int64(len(data))
	if err != nil || len(data) > maxTextFile || bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
		return
	}
	text := string(data)
	if s.quick != nil && !s.quick(text) {
		return
	}
	var result *searchResult
	number := 0
	for rest := text; rest != ""; {
		var line string
		line, rest, _ = strings.Cut(rest, "\n")
		number++
		line = strings.TrimSuffix(line, "\r")
		start, found := s.match(line)
		if !found {
			continue
		}
		if result != nil && len(result.Matches) >= s.limits.fileMatches {
			result.Truncated = true
			return
		}
		if s.matches >= s.limits.matches {
			s.stop("matches")
			return
		}
		if result == nil {
			s.results = append(s.results, searchResult{Path: name, Matches: []searchMatch{}})
			result = &s.results[len(s.results)-1]
		}
		result.Matches = append(result.Matches, searchMatch{Line: number, Column: utf8.RuneCountInString(line[:start]) + 1, Preview: searchPreview(line, start)})
		s.matches++
	}
}

// streamGit runs a read-only Git command and passes each NUL-terminated entry
// of its output to handle until handle returns false. Git stops with ctx.
func streamGit(ctx context.Context, directory string, args []string, handle func(string) bool) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	command := exec.CommandContext(ctx, "git", gitCommandArgs(directory, args)...)
	command.Env = gitEnvironment(false, "", nil)
	command.Stderr = &tailOutput{limit: gitStderrLimit}
	command.WaitDelay = 2 * time.Second
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	if err := command.Start(); err != nil {
		return err
	}
	reader := bufio.NewReaderSize(stdout, 64<<10)
	stopped := false
	for {
		entry, err := reader.ReadString(0)
		if err != nil {
			break
		}
		if !handle(entry[:len(entry)-1]) {
			stopped = true
			break
		}
	}
	if stopped {
		cancel()
	}
	waitErr := command.Wait()
	switch {
	case stopped:
		return nil
	case ctx.Err() != nil:
		return ctx.Err()
	}
	return waitErr
}

// searchFiles answers GET /v1/files/search.
func (h *Host) searchFiles(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	text := query.Get("q")
	if text == "" || len(text) > searchQueryLimit || !utf8.ValidString(text) || strings.ContainsAny(text, "\x00\r\n") {
		writeError(w, 400, "invalid_request", "Enter up to 512 bytes of search text on one line")
		return
	}
	start, err := filePath(query.Get("path"), true)
	if err != nil {
		writeError(w, 400, "invalid_path", "Choose a relative project folder")
		return
	}
	regex, regexErr := searchFlag(query.Get("regex"))
	caseSensitive, caseErr := searchFlag(query.Get("caseSensitive"))
	if regexErr != nil || caseErr != nil {
		writeError(w, 400, "invalid_request", "regex and caseSensitive take true or false")
		return
	}
	match, quick, err := compileSearch(text, regex, caseSensitive)
	if err != nil {
		writeError(w, 400, "invalid_pattern", "The regular expression is not valid")
		return
	}
	include, err := parseSearchInclude(query.Get("include"))
	if err != nil {
		writeError(w, 400, "invalid_request", "include takes up to 16 comma-separated patterns such as *.go")
		return
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	project, err := h.project(query.Get("projectId"))
	if err != nil {
		notFound(w)
		return
	}
	root, err := os.OpenRoot(project.Directory)
	if err != nil {
		writeError(w, 503, "project_unavailable", "The project directory is unavailable")
		return
	}
	defer root.Close()
	folder, err := openProjectFile(root, start)
	if err != nil {
		fileFailure(w, err)
		return
	}
	info, err := folder.Stat()
	folder.Close()
	if err != nil || !info.IsDir() {
		writeError(w, 400, "invalid_path", "Choose a project folder to search")
		return
	}
	startFolder, err := root.OpenRoot(start)
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer startFolder.Close()
	ctx, finish := h.mutations.startSearch(r.Context(), device.ID)
	defer finish()
	search := &fileSearch{ctx: ctx, root: root, directory: project.Directory, match: match, quick: quick, include: include, limits: h.mutations.search, hook: h.mutations.searchHook, folders: map[string]*os.Root{}, results: []searchResult{}}
	defer search.closeFolders()
	search.searchFolder(start, startFolder, true)
	if r.Context().Err() != nil {
		return // the client is gone
	}
	switch cause := context.Cause(ctx); {
	case errors.Is(cause, errSearchSuperseded):
		writeError(w, 409, "search_superseded", "A newer search from this device replaced this one")
		return
	case errors.Is(cause, errSearchTimeLimit):
		search.stop("time")
	}
	writeJSON(w, 200, struct {
		Results         []searchResult `json:"results"`
		TruncatedReason string         `json:"truncatedReason,omitempty"`
	}{search.results, search.truncated})
}
