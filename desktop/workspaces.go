package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"
)

// Workspaces (docs/HOST-API.md, "Workspaces"). A workspace is a configured
// project. Devices list the workspaces with details, browse the folders of the
// workspace home (this user's home folder, or serve --workspace-home), and
// add, create, rename and remove workspaces. Each change is one transaction on
// the host state that keeps devices, pending pairings and the other
// workspaces. Routes read the projects from the state on every request, so a
// change applies at once and the archive feed's epoch and notices follow it.
//
// Folders are reached through the home's os.Root, like project files: a path
// must lie inside the home before and after its symbolic links are resolved,
// and the open itself cannot leave the home. The home's Library, any .Trash,
// and dot folders (unless asked for) are left out of listings and refused.

const (
	workspaceNameLimit = 100
	// folderListLimit caps a listing; folderScanLimit caps the entries read
	// from one folder.
	folderListLimit = 2000
	folderScanLimit = 100_000
	folderPathLimit = 4096
	// removedProjectsKept bounds the record of removed workspaces.
	removedProjectsKept = 100
	workspaceGitTimeout = 15 * time.Second
	// workspaceActivityWait bounds how long details wait for OpenCode's
	// session states.
	workspaceActivityWait = 2 * time.Second
)

// projectFeatures are the workspace features every host serves.
var projectFeatures = []string{"details", "browse", "add", "create", "rename", "remove"}

type projectCapabilities struct {
	Version  int      `json:"version"`
	Features []string `json:"features"`
}

// RemovedProject records a removed workspace's folder, so adding that folder
// again brings back its ID and with it its archived chats and terminal logs.
type RemovedProject struct {
	ID        string `json:"id"`
	Directory string `json:"directory"`
}

type projectActivity struct {
	BusyChats int `json:"busyChats"`
	Terminals int `json:"terminals"`
}

// projectDetails is a workspace in GET /v1/projects and in the answers of
// add, create and rename.
type projectDetails struct {
	ID            string          `json:"id"`
	Name          string          `json:"name"`
	Directory     string          `json:"directory"`
	GitRepository bool            `json:"gitRepository"`
	Activity      projectActivity `json:"activity"`
}

type folderRoot struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type folderEntry struct {
	Name          string `json:"name"`
	Path          string `json:"path"`
	WorkspaceID   string `json:"workspaceId,omitempty"`
	GitRepository bool   `json:"gitRepository"`
}

type folderListing struct {
	Path        string        `json:"path"`
	DisplayPath string        `json:"displayPath"`
	Parent      string        `json:"parent,omitempty"`
	Roots       []folderRoot  `json:"roots"`
	Folders     []folderEntry `json:"folders"`
	Truncated   bool          `json:"truncated"`
}

var (
	errFolderPath    = errors.New("the folder path is not absolute")
	errFolderRefused = errors.New("not an allowed folder inside the workspace home")
	errLastWorkspace = errors.New("the last workspace cannot be removed")
)

type alreadyWorkspaceError struct{ id string }

func (alreadyWorkspaceError) Error() string { return "the folder already is a workspace" }

func folderNotFound(w http.ResponseWriter) {
	writeError(w, 404, "not_found", "The folder is missing, is not a folder, or is outside the home folder")
}
func workspaceNotFound(w http.ResponseWriter) {
	writeError(w, 404, "not_found", "Workspace not found")
}
func invalidWorkspaceName(w http.ResponseWriter) {
	writeError(w, 400, "invalid_request", "Name the workspace with 1 to 100 characters, without = or line breaks")
}
func lastWorkspace(w http.ResponseWriter) {
	writeError(w, 409, "last_workspace", "The host needs at least one workspace; add another before removing this one")
}

// Listing workspaces.

func (h *Host) projects(w http.ResponseWriter, _ *http.Request) {
	st, err := h.store.Read()
	if err != nil {
		internal(w)
		return
	}
	writeJSON(w, 200, map[string]any{"projects": h.projectDetails(st.Config.Projects)})
}

// projectDetails describes workspaces with their folder, whether it holds a
// .git entry, and the chat turns and terminals running there now.
func (h *Host) projectDetails(projects []Project) []projectDetails {
	busy := h.busyChats(projects)
	out := make([]projectDetails, len(projects))
	for index, project := range projects {
		_, err := os.Lstat(filepath.Join(project.Directory, ".git"))
		out[index] = projectDetails{ID: project.ID, Name: project.Name, Directory: project.Directory, GitRepository: err == nil,
			Activity: projectActivity{BusyChats: busy[index], Terminals: h.liveTerminals(project.ID)}}
	}
	return out
}

// sessionStatusReader is OpenCode's GET /session/status for one project.
type sessionStatusReader interface {
	sessionStatuses(Project) (map[string]ocStatus, error)
}

// busyChats counts each project's chats with a turn running: OpenCode's busy
// or retrying sessions, and the Claude Code and Codex chats at work. OpenCode
// is asked for every project at once and waited for at most
// workspaceActivityWait; a project it has not answered for by then, or could
// not answer for, counts none of its OpenCode chats.
func (h *Host) busyChats(projects []Project) []int {
	counts := h.openCodeBusyChats(projects)
	if h.cliChats != nil {
		for index, project := range projects {
			counts[index] += h.cliChats.busyIn(project)
		}
	}
	return counts
}

// openCodeBusyChats counts each project's OpenCode sessions that are busy or
// retrying, as busyChats does.
func (h *Host) openCodeBusyChats(projects []Project) []int {
	counts, _ := h.openCodeActivity(projects)
	return counts
}

// openCodeActivity counts each project's OpenCode sessions that are busy or
// retrying, asking OpenCode for every project at once and waiting at most
// workspaceActivityWait. answered is false for a project it could not answer
// for or did not answer for in time (whose count is then 0); without an
// OpenCode to ask, every project is answered.
func (h *Host) openCodeActivity(projects []Project) (counts []int, answered []bool) {
	counts, answered = make([]int, len(projects)), make([]bool, len(projects))
	reader, ok := h.agent.(sessionStatusReader)
	if !ok || len(projects) == 0 {
		for index := range answered {
			answered[index] = true
		}
		return counts, answered
	}
	type answer struct {
		index, busy int
		ok          bool
	}
	answers := make(chan answer, len(projects))
	for index, project := range projects {
		go func() {
			busy := 0
			statuses, err := reader.sessionStatuses(project)
			if err == nil {
				for _, status := range statuses {
					if status.Type == "busy" || status.Type == "retry" {
						busy++
					}
				}
			}
			answers <- answer{index, busy, err == nil}
		}()
	}
	timer := time.NewTimer(workspaceActivityWait)
	defer timer.Stop()
waiting:
	for range projects {
		select {
		case got := <-answers:
			counts[got.index], answered[got.index] = got.busy, got.ok
		case <-timer.C:
			break waiting
		}
	}
	return counts, answered
}

// busyIn counts a project's Claude Code, Codex and ACP chats with a turn
// running, as Status reports them. A Claude or ACP chat its engine has not
// loaded runs no turn, so none is loaded to find out.
func (c *CLIChats) busyIn(project Project) int {
	count := 0
	var claudeChats []string
	c.mu.Lock()
	for id, record := range c.records {
		if record.Session.ProjectID != project.ID || !sameDirectory(record.Directory, project.Directory) {
			continue
		}
		if c.claude != nil && isClaudeSessionID(id) {
			claudeChats = append(claudeChats, id)
		} else if record.Busy {
			count++
		}
	}
	c.mu.Unlock()
	for _, id := range claudeChats {
		if chat := c.claude.loadedChat(id); chat != nil {
			if state := chat.activity(); state == "busy" || state == "retry" {
				count++
			}
		}
	}
	// ACP chats (acp_engine.go).
	return count + c.acp.busyIn(project)
}

// loadedChat is the Claude chat the engine holds, or nil.
func (e *claudeEngine) loadedChat(id string) *claudeChat {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.chats[id]
}

// liveTerminals counts the running terminals of a workspace, whichever device
// opened them.
func (h *Host) liveTerminals(projectID string) int {
	if h.terminals == nil {
		return 0
	}
	h.terminals.mu.Lock()
	defer h.terminals.mu.Unlock()
	count := 0
	for _, entry := range h.terminals.entries {
		if entry.project.ID == projectID {
			entry.mu.Lock()
			if entry.info.Status == "running" {
				count++
			}
			entry.mu.Unlock()
		}
	}
	return count
}

// endTerminals ends and forgets every terminal of a workspace, whichever
// device opened it and routed agents too, as POST /v1/terminal/close does. A
// terminal the keeper could not end or forget stays listed, and the error is
// returned. Terminals outside any workspace are never among them.
func (h *Host) endTerminals(projectID string) error {
	if h.terminals == nil || projectID == "" {
		return nil
	}
	manager := h.terminals
	manager.mu.Lock()
	var entries []*terminalEntry
	for _, entry := range manager.entries {
		if entry.project.ID == projectID {
			entries = append(entries, entry)
		}
	}
	manager.mu.Unlock()
	var failures []error
	for _, entry := range entries {
		entry.writeMu.Lock()
		if err := manager.endAndForget(context.Background(), entry, terminalEndWorkspaceRemoved, nil); err != nil {
			failures = append(failures, err)
		}
		entry.writeMu.Unlock()
	}
	return errors.Join(failures...)
}

// joinWorkspace is what adding a workspace does for the terminals outside
// any: every running one whose folder is the workspace's or lies under it
// joins it, with its record in the keeper (written as saveContextTitle
// writes) and its archive log. It returns how many joined.
//
// A listed one there that has ended keeps no workspace, but its log moves
// too, though its end may not have reached the archive yet (follow records
// it just after the end). The logs of terminals no longer listed move in the
// archive (terminalsJoinWorkspace).
//
// The workspace's folder is read once, before the locks (terminalFolderJoiner);
// the terminals' folders are compared as strings.
func (manager *terminalManager) joinWorkspace(project Project) int {
	joins := terminalFolderJoiner(project.Directory)
	manager.mu.Lock()
	var joined, ended []*terminalEntry
	for _, entry := range manager.entries {
		entry.mu.Lock()
		switch {
		case entry.project.ID != "" || !joins(entry.info.Directory):
		case entry.info.Status == "running":
			// Under both locks: entry.project is read under either.
			entry.project = project
			entry.info.ProjectID = project.ID
			entry.meta.Project = project.ID
			joined = append(joined, entry)
		default:
			ended = append(ended, entry)
		}
		entry.mu.Unlock()
	}
	manager.mu.Unlock()
	for _, entry := range joined {
		manager.saveMeta(entry)
		entry.log.MoveToProject(project.ID)
		log.Printf("terminals: id=%s joined workspace=%s", entry.info.ID, project.ID)
	}
	for _, entry := range ended {
		entry.log.MoveToProject(project.ID)
	}
	return len(joined)
}

// terminalFolderJoiner answers whether a terminal in a folder joins the
// workspace whose directory this is: the folder is it or lies under it.
// joinWorkspace and the archive's move of projectless logs
// (terminalsJoinWorkspace) both compare through it, and a registration's
// deepestWorkspace compares the same way (workspaceDirectory).
//
// The directory is read once, canonical (canonicalFolder), so a workspace
// added through a symbolic link or in another letter case holds the folder;
// as recorded, cleaned, it holds it too, and that is all when it is gone. The
// folder is compared only as a string, cleaned: a terminal's folder is
// recorded canonical (the CLI sends its own cwd canonical,
// localterm.Request.Folder), and the host never opens it. On macOS that
// would ask the person to let AgentLand into their Downloads, Desktop,
// Documents or an external drive, which an agent typed in Terminal.app never
// needs (docs/HOST-API.md, "Terminals started in Terminal on the Mac").
func terminalFolderJoiner(directory string) func(folder string) bool {
	if directory == "" {
		return func(string) bool { return false }
	}
	return newWorkspaceDirectory(directory).holds
}

// terminalFolderJoins is terminalFolderJoiner for one folder.
func terminalFolderJoins(directory, folder string) bool {
	return terminalFolderJoiner(directory)(folder)
}

// workspaceDirectory is a workspace's directory, canonical and as recorded
// (cleaned).
type workspaceDirectory struct{ canonical, recorded string }

func newWorkspaceDirectory(directory string) workspaceDirectory {
	recorded := filepath.Clean(directory)
	canonical := recorded
	if resolved, err := canonicalFolder(directory); err == nil {
		canonical = resolved
	}
	return workspaceDirectory{canonical: canonical, recorded: recorded}
}

// holds is whether folder, a string, is the workspace's directory or lies
// under it.
func (w workspaceDirectory) holds(folder string) bool {
	if folder == "" {
		return false
	}
	folder = filepath.Clean(folder)
	return inside(w.canonical, folder) || (w.recorded != w.canonical && inside(w.recorded, folder))
}

// terminalsJoinWorkspace runs as a workspace is added: the running terminals
// outside any workspace in or under its folder join it (joinWorkspace), and
// the archive files there the logs of every other terminal outside any that
// ran in or under it, ended or no longer listed, so the workspace's search
// and Resume find them.
func (h *Host) terminalsJoinWorkspace(project Project) {
	if h.terminals != nil {
		h.terminals.joinWorkspace(project)
	}
	if h.archive == nil {
		return
	}
	// Read once, and the archive's rows compared as strings: nothing opens a
	// file inside the archive's writer.
	moved, err := h.archive.MoveProjectlessTerminalLogs(project.ID, terminalFolderJoiner(project.Directory))
	switch {
	case err != nil && !errors.Is(err, ErrArchiveClosed):
		log.Printf("terminals: could not file terminal logs under workspace=%s: %v", project.ID, err)
	case moved > 0:
		log.Printf("terminals: filed %d terminal logs under workspace=%s", moved, project.ID)
	}
}

// The workspace home.

// workspaceHome answers the workspace home as configured (or this user's home
// folder), cleaned, and with its symbolic links resolved.
func (h *Host) workspaceHome() (given, resolved string, err error) {
	given = h.workspaceHomeOption
	if given == "" {
		if given, err = os.UserHomeDir(); err != nil {
			return "", "", err
		}
	}
	if !filepath.IsAbs(given) {
		return "", "", errFolderRefused
	}
	given = filepath.Clean(given)
	resolved, err = filepath.EvalSymlinks(given)
	return given, resolved, err
}

// homeFolder is a folder inside the workspace home: the resolved home, the
// folder's resolved path, and that path relative to the home ("." for the
// home itself).
type homeFolder struct{ home, path, rel string }

// resolveFolder checks an absolute path the way browsing, adding and creating
// accept it: inside the home before and after its symbolic links are
// resolved, and not a folder the rules leave out. hidden admits dot folders.
// The caller still opens the folder through the home's os.Root.
func (h *Host) resolveFolder(raw string, hidden bool) (homeFolder, error) {
	if len(raw) > folderPathLimit || strings.ContainsRune(raw, 0) || !filepath.IsAbs(raw) {
		return homeFolder{}, errFolderPath
	}
	given, home, err := h.workspaceHome()
	if err != nil {
		return homeFolder{}, errFolderRefused
	}
	// Only a path naming the home or a folder inside it is resolved, so a
	// request never makes the host look anywhere else.
	cleaned := filepath.Clean(raw)
	if !inside(home, cleaned) && !inside(given, cleaned) {
		return homeFolder{}, errFolderRefused
	}
	resolved, err := filepath.EvalSymlinks(cleaned)
	if err != nil || !inside(home, resolved) {
		return homeFolder{}, errFolderRefused
	}
	rel, err := filepath.Rel(home, resolved)
	if err != nil || leftOutFolder(rel, hidden) {
		return homeFolder{}, errFolderRefused
	}
	return homeFolder{home: home, path: resolved, rel: rel}, nil
}

// inside reports whether target is base or lies below it (cleaned paths).
func inside(base, target string) bool {
	rel, err := filepath.Rel(base, target)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// leftOutName reports a folder name the rules leave out: any .Trash, the
// home's Library, and dot folders unless hidden.
func leftOutName(name string, inHome, hidden bool) bool {
	return strings.EqualFold(name, ".Trash") || (inHome && strings.EqualFold(name, "Library")) || (!hidden && strings.HasPrefix(name, "."))
}

// leftOutFolder applies leftOutName to each folder of a path relative to the
// home.
func leftOutFolder(rel string, hidden bool) bool {
	if rel == "." {
		return false
	}
	for index, name := range strings.Split(filepath.ToSlash(rel), "/") {
		if leftOutName(name, index == 0, hidden) {
			return true
		}
	}
	return false
}

func displayPath(rel string) string {
	if rel == "." {
		return "~"
	}
	return "~/" + filepath.ToSlash(rel)
}

// Browsing.

func (h *Host) browseFolders(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	hidden := query.Get("hidden") == "1"
	path := query.Get("path")
	if path == "" {
		_, home, err := h.workspaceHome()
		if err != nil {
			folderNotFound(w)
			return
		}
		path = home
	}
	folder, err := h.resolveFolder(path, hidden)
	if errors.Is(err, errFolderPath) {
		writeError(w, 400, "invalid_request", "Choose an absolute folder path to browse")
		return
	}
	if err != nil {
		folderNotFound(w)
		return
	}
	root, err := os.OpenRoot(folder.home)
	if err != nil {
		folderNotFound(w)
		return
	}
	defer root.Close()
	sub, err := root.OpenRoot(folder.rel)
	if err != nil {
		folderNotFound(w)
		return
	}
	defer sub.Close()
	dir, err := openDirectory(sub, ".")
	if err != nil {
		folderNotFound(w)
		return
	}
	defer dir.Close()
	entries, truncated, err := folderCandidates(dir, folder.rel == ".", hidden)
	if err != nil {
		folderNotFound(w)
		return
	}
	st, err := h.store.Read()
	if err != nil {
		internal(w)
		return
	}
	listing := folderListing{Path: folder.path, DisplayPath: displayPath(folder.rel), Roots: folderRoots(root, folder.home, st.Config.Projects, hidden), Folders: []folderEntry{}, Truncated: truncated}
	if folder.rel != "." {
		listing.Parent = filepath.Dir(folder.path)
	}
	workspaces := workspaceFolders(st.Config.Projects)
	for _, entry := range entries {
		item, info, ok := listedFolder(root, sub, folder, entry, hidden)
		if !ok {
			continue
		}
		if len(listing.Folders) == folderListLimit {
			listing.Truncated = true
			break
		}
		item.WorkspaceID = workspaces.id(info)
		listing.Folders = append(listing.Folders, item)
	}
	writeJSON(w, 200, listing)
}

// folderCandidates reads at most folderScanLimit entries of a folder and
// keeps the folders and symbolic links the rules allow, sorted by name
// without regard to case. It reports whether entries were left unread.
func folderCandidates(dir *os.File, atHome, hidden bool) ([]os.DirEntry, bool, error) {
	var kept []os.DirEntry
	scanned, unread := 0, false
	for {
		batch, err := dir.ReadDir(512)
		for _, entry := range batch {
			kind := entry.Type()
			if (kind.IsDir() || kind&os.ModeSymlink != 0) && !leftOutName(entry.Name(), atHome, hidden) {
				kept = append(kept, entry)
			}
		}
		scanned += len(batch)
		if errors.Is(err, io.EOF) || (err == nil && len(batch) == 0) {
			break
		}
		if err != nil {
			return nil, false, err
		}
		if scanned >= folderScanLimit {
			unread = true
			break
		}
	}
	slices.SortFunc(kept, func(a, b os.DirEntry) int {
		if order := strings.Compare(strings.ToLower(a.Name()), strings.ToLower(b.Name())); order != 0 {
			return order
		}
		return strings.Compare(a.Name(), b.Name())
	})
	return kept, unread, nil
}

// listedFolder answers an entry of the listed folder when it is a folder, or
// a symbolic link to a folder inside the home that the rules allow (listed
// under its resolved path), with its file information.
func listedFolder(root, sub *os.Root, folder homeFolder, entry os.DirEntry, hidden bool) (folderEntry, os.FileInfo, bool) {
	name := entry.Name()
	item := folderEntry{Name: name, Path: filepath.Join(folder.path, name)}
	if entry.Type()&os.ModeSymlink == 0 {
		info, err := entry.Info()
		if err != nil || !info.IsDir() {
			return folderEntry{}, nil, false
		}
		_, err = sub.Lstat(filepath.Join(name, ".git"))
		item.GitRepository = err == nil
		return item, info, true
	}
	target, err := filepath.EvalSymlinks(item.Path)
	if err != nil || !inside(folder.home, target) {
		return folderEntry{}, nil, false
	}
	rel, err := filepath.Rel(folder.home, target)
	if err != nil || rel == "." || leftOutFolder(rel, hidden) {
		return folderEntry{}, nil, false
	}
	info, err := root.Stat(rel)
	if err != nil || !info.IsDir() {
		return folderEntry{}, nil, false
	}
	_, err = root.Lstat(filepath.Join(rel, ".git"))
	item.Path, item.GitRepository = target, err == nil
	return item, info, true
}

// folderRoots offers the home folder and, when they exist inside it and the
// rules allow them, its Developer, Desktop and Documents folders and the
// folders holding the configured workspaces.
func folderRoots(root *os.Root, home string, projects []Project, hidden bool) []folderRoot {
	roots := []folderRoot{{Name: filepath.Base(home), Path: home}}
	offer := func(name, candidate string) {
		resolved, err := filepath.EvalSymlinks(candidate)
		if err != nil || !inside(home, resolved) || slices.ContainsFunc(roots, func(offered folderRoot) bool { return offered.Path == resolved }) {
			return
		}
		rel, err := filepath.Rel(home, resolved)
		if err != nil || leftOutFolder(rel, hidden) {
			return
		}
		if info, err := root.Stat(rel); err != nil || !info.IsDir() {
			return
		}
		roots = append(roots, folderRoot{Name: name, Path: resolved})
	}
	for _, name := range []string{"Developer", "Desktop", "Documents"} {
		offer(name, filepath.Join(home, name))
	}
	for _, project := range projects {
		parent := filepath.Dir(project.Directory)
		offer(filepath.Base(parent), parent)
	}
	return roots
}

// workspaceSet finds the workspace a folder is, by file identity.
type workspaceFolder struct {
	id   string
	info os.FileInfo
}
type workspaceSet []workspaceFolder

func workspaceFolders(projects []Project) workspaceSet {
	var set workspaceSet
	for _, project := range projects {
		if info, err := os.Stat(project.Directory); err == nil && info.IsDir() {
			set = append(set, workspaceFolder{project.ID, info})
		}
	}
	return set
}

func (s workspaceSet) id(info os.FileInfo) string {
	for _, workspace := range s {
		if os.SameFile(workspace.info, info) {
			return workspace.id
		}
	}
	return ""
}

// Adding and creating.

func (h *Host) addProject(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Directory string `json:"directory"`
		Name      string `json:"name,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	name := ""
	if in.Name != "" {
		var ok bool
		if name, ok = workspaceName(in.Name); !ok {
			invalidWorkspaceName(w)
			return
		}
	}
	folder, err := h.resolveFolder(in.Directory, true)
	if errors.Is(err, errFolderPath) {
		writeError(w, 400, "invalid_request", "Choose an absolute folder to add")
		return
	}
	if err == nil && folder.rel == "." {
		writeError(w, 400, "invalid_request", "Choose a folder inside the home folder; the home folder itself cannot be a workspace")
		return
	}
	if err == nil {
		err = homeDirectory(folder)
	}
	if err != nil {
		folderNotFound(w)
		return
	}
	if name == "" {
		name = folderWorkspaceName(filepath.Base(folder.path))
	}
	h.workspaceMu.Lock()
	project, err := h.store.addProject(folder.path, name)
	h.workspaceMu.Unlock()
	if err != nil {
		addFailure(w, err)
		return
	}
	h.terminalsJoinWorkspace(project)
	h.workspacesChanged()
	writeJSON(w, 201, h.projectDetails([]Project{project})[0])
}

// homeDirectory opens the folder through the home's os.Root, so it is a
// directory the home contains.
func homeDirectory(folder homeFolder) error {
	root, err := os.OpenRoot(folder.home)
	if err != nil {
		return err
	}
	defer root.Close()
	dir, err := openDirectory(root, folder.rel)
	if err != nil {
		return err
	}
	return dir.Close()
}

func addFailure(w http.ResponseWriter, err error) {
	var already alreadyWorkspaceError
	if errors.As(err, &already) {
		writeErrorWith(w, 409, "already_workspace", "This folder already is a workspace", map[string]any{"projectId": already.id})
		return
	}
	internal(w)
}

func (h *Host) createProject(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ParentDirectory string `json:"parentDirectory"`
		Name            string `json:"name"`
		Git             bool   `json:"git,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	name, ok := newFolderName(in.Name)
	if !ok {
		writeError(w, 400, "invalid_request", "Name the new folder with 1 to 100 characters, without /, =, line breaks or a leading dot")
		return
	}
	parent, err := h.resolveFolder(in.ParentDirectory, true)
	if errors.Is(err, errFolderPath) {
		writeError(w, 400, "invalid_request", "Choose an absolute folder to create the workspace in")
		return
	}
	if err != nil {
		folderNotFound(w)
		return
	}
	h.workspaceMu.Lock()
	if err := makeHomeFolder(parent, name); err != nil {
		h.workspaceMu.Unlock()
		switch {
		case errors.Is(err, os.ErrExist):
			writeError(w, 409, "already_exists", "A file or folder with that name already exists")
		case errors.Is(err, errFolderRefused):
			folderNotFound(w)
		case errors.Is(err, syscall.ENOSPC):
			insufficientStorage(w)
		default:
			writeError(w, 403, "file_unavailable", "The folder cannot be made there")
		}
		return
	}
	// A failed git init leaves the folder, which is added all the same.
	directory := filepath.Join(parent.path, name)
	var gitErr error
	if in.Git {
		gitErr = runGitCall(context.Background(), gitCall{directory: directory, args: []string{"init", "--quiet", "-b", "main"}, timeout: workspaceGitTimeout, stdoutLimit: 4 << 10}).err
	}
	project, err := h.store.addProject(directory, name)
	h.workspaceMu.Unlock()
	if err != nil {
		addFailure(w, err)
		return
	}
	h.workspacesChanged()
	if gitErr != nil {
		writeErrorWith(w, 500, "git_failed", "The folder was made and added as a workspace, but Git could not start a repository in it", map[string]any{"projectId": project.ID})
		return
	}
	writeJSON(w, 201, h.projectDetails([]Project{project})[0])
}

// makeHomeFolder makes name, mode 0755, in the parent folder through the
// home's os.Root; mkdirat never follows a symbolic link at the new name.
func makeHomeFolder(parent homeFolder, name string) error {
	root, err := os.OpenRoot(parent.home)
	if err != nil {
		return errFolderRefused
	}
	defer root.Close()
	folder, err := root.OpenRoot(parent.rel)
	if err != nil {
		return errFolderRefused
	}
	defer folder.Close()
	return folder.Mkdir(name, 0o755)
}

// Renaming and removing.

func (h *Host) renameProject(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if !decode(w, r, &in) {
		return
	}
	name, ok := workspaceName(in.Name)
	if !ok {
		invalidWorkspaceName(w)
		return
	}
	h.workspaceMu.Lock()
	project, err := h.store.renameProject(in.ID, name)
	h.workspaceMu.Unlock()
	if errors.Is(err, ErrNotFound) {
		workspaceNotFound(w)
		return
	}
	if err != nil {
		internal(w)
		return
	}
	writeJSON(w, 200, h.projectDetails([]Project{project})[0])
}

func (h *Host) removeProject(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID           string `json:"id"`
		EndTerminals bool   `json:"endTerminals,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.ID == "" {
		writeError(w, 400, "invalid_request", "Choose a workspace to remove")
		return
	}
	h.workspaceMu.Lock()
	defer h.workspaceMu.Unlock()
	st, err := h.store.Read()
	if err != nil {
		internal(w)
		return
	}
	index := slices.IndexFunc(st.Config.Projects, func(p Project) bool { return p.ID == in.ID })
	if index < 0 {
		workspaceNotFound(w)
		return
	}
	if len(st.Config.Projects) == 1 {
		lastWorkspace(w)
		return
	}
	project := st.Config.Projects[index]
	busy, terminals := h.busyChats([]Project{project})[0], h.liveTerminals(project.ID)
	if busy > 0 || (terminals > 0 && !in.EndTerminals) {
		message := "Terminals are open in this workspace; end them to remove it"
		if busy > 0 {
			message = "A chat is working in this workspace; stop it or let it finish before removing the workspace"
		}
		writeErrorWith(w, 409, "workspace_busy", message, map[string]any{"busyChats": busy, "terminals": terminals})
		return
	}
	if err := h.endTerminals(project.ID); err != nil {
		internal(w)
		return
	}
	if err := h.store.removeProject(project.ID); err != nil {
		switch {
		case errors.Is(err, ErrNotFound):
			workspaceNotFound(w)
		case errors.Is(err, errLastWorkspace):
			lastWorkspace(w)
		default:
			internal(w)
		}
		return
	}
	// A terminal opened while this ran goes with the workspace.
	_ = h.endTerminals(project.ID)
	h.views.forgetProject(project.ID)
	h.workspacesChanged()
	writeJSON(w, 200, map[string]bool{"removed": true})
}

// workspacesChanged wakes archive change feeds that wait for a change: their
// epoch follows the configured workspaces, so they answer with a resync.
func (h *Host) workspacesChanged() {
	if h.archive != nil {
		h.archive.signalChanges()
	}
}

// Names and IDs.

// workspaceName trims a workspace name and checks it: 1 to 100 characters,
// no "=" (the CLI's project flags use it) and no line breaks or other control
// characters.
func workspaceName(raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	if !utf8.ValidString(name) {
		return "", false
	}
	if count := utf8.RuneCountInString(name); count < 1 || count > workspaceNameLimit {
		return "", false
	}
	for _, r := range name {
		if r == '=' || unicode.IsControl(r) || r == ' ' || r == ' ' {
			return "", false
		}
	}
	return name, true
}

// newFolderName checks the name of a folder to create, which is also the
// workspace's name: a workspace name that is a single path component not
// starting with a dot.
func newFolderName(raw string) (string, bool) {
	name, ok := workspaceName(raw)
	if !ok || strings.HasPrefix(name, ".") || strings.ContainsAny(name, `/\`) || len(name) > 255 {
		return "", false
	}
	return name, true
}

// folderWorkspaceName makes a workspace name of a folder's name.
func folderWorkspaceName(base string) string {
	name := strings.Map(func(r rune) rune {
		switch {
		case r == '=':
			return '-'
		case unicode.IsControl(r) || r == ' ' || r == ' ' || r == utf8.RuneError:
			return ' '
		}
		return r
	}, base)
	if runes := []rune(strings.TrimSpace(name)); len(runes) > workspaceNameLimit {
		name = string(runes[:workspaceNameLimit])
	}
	if name = strings.TrimSpace(name); name == "" {
		return "Workspace"
	}
	return name
}

// workspaceSlug is the name in lower-case ASCII letters and digits with
// hyphens between words, about 24 characters at most; "workspace" when
// nothing is left.
func workspaceSlug(name string) string {
	var slug strings.Builder
	gap := false
	for _, r := range strings.ToLower(name) {
		if slug.Len() >= 24 {
			break
		}
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') {
			gap = true
			continue
		}
		if gap && slug.Len() > 0 {
			slug.WriteByte('-')
		}
		gap = false
		slug.WriteRune(r)
	}
	if slug.Len() == 0 {
		return "workspace"
	}
	return slug.String()
}

// newWorkspaceID makes a slug of the name with a random suffix that no
// workspace, present or removed, has.
func newWorkspaceID(name string, st *State) (string, error) {
	slug := workspaceSlug(name)
	for range 32 {
		suffix := make([]byte, 3)
		if _, err := rand.Read(suffix); err != nil {
			return "", err
		}
		if id := slug + "-" + hex.EncodeToString(suffix); !workspaceIDTaken(st, id) {
			return id, nil
		}
	}
	return "", errors.New("no free workspace ID")
}

func workspaceIDTaken(st *State, id string) bool {
	return slices.ContainsFunc(st.Config.Projects, func(p Project) bool { return p.ID == id }) ||
		slices.ContainsFunc(st.RemovedProjects, func(removed RemovedProject) bool { return removed.ID == id })
}

// State changes. Each is one transaction under the state lock, so devices,
// pending pairings and the other workspaces are kept as they are.

// addProject adds a folder as a workspace. The folder of a removed workspace
// gets that workspace's ID back; another gets a new one.
func (s *Store) addProject(directory, name string) (Project, error) {
	var added Project
	err := s.update(func(st *State) error {
		for _, project := range st.Config.Projects {
			if project.Directory == directory || sameDirectory(project.Directory, directory) {
				return alreadyWorkspaceError{project.ID}
			}
		}
		id := ""
		for index, removed := range st.RemovedProjects {
			if sameFolderPath(removed.Directory, directory) && !slices.ContainsFunc(st.Config.Projects, func(p Project) bool { return p.ID == removed.ID }) {
				id = removed.ID
				st.RemovedProjects = slices.Delete(st.RemovedProjects, index, index+1)
				break
			}
		}
		if id == "" {
			var err error
			if id, err = newWorkspaceID(name, st); err != nil {
				return err
			}
		}
		added = Project{ID: id, Name: name, Directory: directory}
		st.Config.Projects = append(st.Config.Projects, added)
		return nil
	})
	return added, err
}

// sameFolderPath reports whether a recorded folder path names directory, a
// resolved path.
func sameFolderPath(recorded, directory string) bool {
	if filepath.Clean(recorded) == directory {
		return true
	}
	resolved, err := filepath.EvalSymlinks(recorded)
	return err == nil && resolved == directory
}

func (s *Store) renameProject(id, name string) (Project, error) {
	var renamed Project
	err := s.update(func(st *State) error {
		for index := range st.Config.Projects {
			if st.Config.Projects[index].ID == id {
				st.Config.Projects[index].Name = name
				renamed = st.Config.Projects[index]
				return nil
			}
		}
		return ErrNotFound
	})
	return renamed, err
}

// removeProject takes a workspace out of the configuration, never the last
// one, and records its folder. Its files are not touched.
func (s *Store) removeProject(id string) error {
	return s.update(func(st *State) error {
		index := slices.IndexFunc(st.Config.Projects, func(p Project) bool { return p.ID == id })
		if index < 0 {
			return ErrNotFound
		}
		if len(st.Config.Projects) == 1 {
			return errLastWorkspace
		}
		removed := st.Config.Projects[index]
		st.Config.Projects = slices.Delete(st.Config.Projects, index, index+1)
		st.RemovedProjects = slices.DeleteFunc(st.RemovedProjects, func(r RemovedProject) bool {
			return r.ID == removed.ID || r.Directory == removed.Directory
		})
		st.RemovedProjects = append(st.RemovedProjects, RemovedProject{ID: removed.ID, Directory: removed.Directory})
		if extra := len(st.RemovedProjects) - removedProjectsKept; extra > 0 {
			st.RemovedProjects = slices.Delete(st.RemovedProjects, 0, extra)
		}
		return nil
	})
}
