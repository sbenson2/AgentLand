package host

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// workspaceAgent reports busy OpenCode sessions per project.
type workspaceAgent struct {
	*terminalFixture
	mu   sync.Mutex
	busy map[string]int // project ID → sessions with a turn running
}

func (a *workspaceAgent) sessionStatuses(p Project) (map[string]ocStatus, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	statuses := map[string]ocStatus{"idle": {Type: "idle"}}
	for index := range a.busy[p.ID] {
		statuses[fmt.Sprintf("busy%d", index)] = ocStatus{Type: "busy"}
	}
	return statuses, nil
}

func (a *workspaceAgent) setBusy(projectID string, count int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.busy[projectID] = count
}

// workspaceFixture is a host whose workspace home is a temporary folder:
//
//	Developer/first (workspace p1, a Git repository), Developer/Library,
//	Desktop, Documents, Library, .Trash, .config/tool, Zeta, alpha,
//	notes.txt, and links: inside-link → Developer, outside-link → a folder
//	outside the home, trash-link → .Trash, library-link → Library,
//	file-link → notes.txt.
type workspaceFixture struct {
	host     *Host
	store    *Store
	agent    *workspaceAgent
	token    string
	home     string // as configured
	real     string // with symbolic links resolved
	outside  string
	terminal *terminalFixture
}

func newWorkspaceFixture(t *testing.T, options HostOptions) *workspaceFixture {
	t.Helper()
	home := t.TempDir()
	outside := t.TempDir()
	for _, folder := range []string{"Developer/first/.git", "Developer/Library", "Desktop", "Documents", "Library", ".Trash", ".config/tool", "Zeta", "alpha"} {
		if err := os.MkdirAll(filepath.Join(home, folder), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "notes.txt"), []byte("notes"), 0o600); err != nil {
		t.Fatal(err)
	}
	for link, target := range map[string]string{"inside-link": filepath.Join(home, "Developer"), "outside-link": outside, "trash-link": filepath.Join(home, ".Trash"), "library-link": filepath.Join(home, "Library"), "file-link": filepath.Join(home, "notes.txt")} {
		if err := os.Symlink(target, filepath.Join(home, link)); err != nil {
			t.Fatal(err)
		}
	}
	real, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	store := NewStore(filepath.Join(t.TempDir(), "private-state", "state.json"))
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "First", Directory: filepath.Join(home, "Developer", "first")}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	terminal := newTerminalFixture(&fakeAgent{sessions: map[string]Session{}})
	agent := &workspaceAgent{terminalFixture: terminal, busy: map[string]int{}}
	options.TerminalEnabled, options.WorkspaceHome, options.Terminals = true, home, terminal.fakeTerminals
	fixture := &workspaceFixture{store: store, agent: agent, home: home, real: real, outside: outside, terminal: terminal}
	fixture.host = newHost(store, agent, options)
	fakeTerminalPrograms(fixture.host, false)
	t.Cleanup(func() { fixture.host.Close() })
	fixture.token = paired(t, fixture.host, store)
	return fixture
}

func (f *workspaceFixture) call(t *testing.T, method, target string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return request(t, f.host.Handler(), method, target, f.token, body)
}

func (f *workspaceFixture) browse(t *testing.T, query url.Values) (*httptest.ResponseRecorder, folderListing) {
	t.Helper()
	w := f.call(t, "GET", "/v1/folders?"+query.Encode(), nil)
	var listing folderListing
	if w.Code == 200 {
		if err := json.Unmarshal(w.Body.Bytes(), &listing); err != nil {
			t.Fatal(err)
		}
	}
	return w, listing
}

func (f *workspaceFixture) add(t *testing.T, directory string) projectDetails {
	t.Helper()
	w := f.call(t, "POST", "/v1/projects", map[string]string{"directory": directory})
	if w.Code != 201 {
		t.Fatalf("add %s: %d %s", directory, w.Code, w.Body)
	}
	return decodeProject(t, w)
}

func decodeProject(t *testing.T, w *httptest.ResponseRecorder) projectDetails {
	t.Helper()
	var project projectDetails
	if err := json.Unmarshal(w.Body.Bytes(), &project); err != nil {
		t.Fatal(err)
	}
	return project
}

type workspaceError struct {
	Error struct {
		Code      string `json:"code"`
		Message   string `json:"message"`
		ProjectID string `json:"projectId"`
		BusyChats *int   `json:"busyChats"`
		Terminals *int   `json:"terminals"`
	} `json:"error"`
}

func decodeWorkspaceError(t *testing.T, w *httptest.ResponseRecorder) workspaceError {
	t.Helper()
	var answer workspaceError
	if err := json.Unmarshal(w.Body.Bytes(), &answer); err != nil {
		t.Fatalf("%d %s: %v", w.Code, w.Body, err)
	}
	return answer
}

func projectIDs(t *testing.T, store *Store) []string {
	t.Helper()
	st, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	ids := []string{}
	for _, project := range st.Config.Projects {
		ids = append(ids, project.ID)
	}
	return ids
}

func folderNames(listing folderListing) []string {
	names := []string{}
	for _, folder := range listing.Folders {
		names = append(names, folder.Name)
	}
	return names
}

func TestWorkspaceDetails(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	zeta := f.add(t, filepath.Join(f.home, "Zeta"))
	if w := f.call(t, "POST", "/v1/terminals", map[string]any{"projectId": zeta.ID, "title": "Shell", "rows": 24, "cols": 80}); w.Code != 201 {
		t.Fatalf("terminal: %d %s", w.Code, w.Body)
	}
	f.agent.setBusy("p1", 2)
	w := f.call(t, "GET", "/v1/projects", nil)
	var answer struct{ Projects []projectDetails }
	if err := json.Unmarshal(w.Body.Bytes(), &answer); w.Code != 200 || err != nil {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	want := []projectDetails{
		{ID: "p1", Name: "First", Directory: filepath.Join(f.home, "Developer", "first"), GitRepository: true, Activity: projectActivity{BusyChats: 2}},
		{ID: zeta.ID, Name: "Zeta", Directory: filepath.Join(f.real, "Zeta"), Activity: projectActivity{Terminals: 1}},
	}
	if !slices.Equal(answer.Projects, want) {
		t.Errorf("projects %+v, want %+v", answer.Projects, want)
	}
	// The legacy members keep their names.
	if !strings.HasPrefix(w.Body.String(), `{"projects":[{"id":"p1","name":"First","directory":`) {
		t.Errorf("body %s", w.Body)
	}
}

func TestBrowseFolders(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	developer := filepath.Join(f.real, "Developer")
	homeRoots := []folderRoot{{filepath.Base(f.real), f.real}, {"Developer", developer}, {"Desktop", filepath.Join(f.real, "Desktop")}, {"Documents", filepath.Join(f.real, "Documents")}}
	cases := []struct {
		name        string
		query       url.Values
		status      int
		path        string
		display     string
		parent      string
		folders     []string
		workspaceOf map[string]string // folder name → workspace ID
		gitOf       []string          // folders holding .git
	}{
		{name: "home by default", query: url.Values{}, status: 200, path: f.real, display: "~",
			folders: []string{"alpha", "Desktop", "Developer", "Documents", "inside-link", "Zeta"}},
		{name: "home as configured", query: url.Values{"path": {f.home}}, status: 200, path: f.real, display: "~",
			folders: []string{"alpha", "Desktop", "Developer", "Documents", "inside-link", "Zeta"}},
		{name: "dot folders when asked, never .Trash or the home's Library", query: url.Values{"hidden": {"1"}}, status: 200, path: f.real, display: "~",
			folders: []string{".config", "alpha", "Desktop", "Developer", "Documents", "inside-link", "Zeta"}},
		{name: "a sub-folder with a workspace and a Library of its own", query: url.Values{"path": {filepath.Join(f.home, "Developer")}}, status: 200, path: developer, display: "~/Developer", parent: f.real,
			folders: []string{"first", "Library"}, workspaceOf: map[string]string{"first": "p1"}, gitOf: []string{"first"}},
		{name: "a link inside the home", query: url.Values{"path": {filepath.Join(f.home, "inside-link")}}, status: 200, path: developer, display: "~/Developer", parent: f.real,
			folders: []string{"first", "Library"}, workspaceOf: map[string]string{"first": "p1"}, gitOf: []string{"first"}},
		{name: "a dot folder when asked", query: url.Values{"path": {filepath.Join(f.home, ".config")}, "hidden": {"1"}}, status: 200, path: filepath.Join(f.real, ".config"), display: "~/.config", parent: f.real, folders: []string{"tool"}},
		{name: "a dot folder", query: url.Values{"path": {filepath.Join(f.home, ".config")}}, status: 404},
		{name: "a .git folder", query: url.Values{"path": {filepath.Join(f.home, "Developer", "first", ".git")}}, status: 404},
		{name: "the home's Library", query: url.Values{"path": {filepath.Join(f.home, "Library")}, "hidden": {"1"}}, status: 404},
		{name: "the Trash", query: url.Values{"path": {filepath.Join(f.home, ".Trash")}, "hidden": {"1"}}, status: 404},
		{name: "a link to the Trash", query: url.Values{"path": {filepath.Join(f.home, "trash-link")}, "hidden": {"1"}}, status: 404},
		{name: "a link to the Library", query: url.Values{"path": {filepath.Join(f.home, "library-link")}}, status: 404},
		{name: "a link leading outside", query: url.Values{"path": {filepath.Join(f.home, "outside-link")}}, status: 404},
		{name: "a folder outside", query: url.Values{"path": {f.outside}}, status: 404},
		{name: "the root folder", query: url.Values{"path": {"/"}}, status: 404},
		{name: "a path climbing out", query: url.Values{"path": {filepath.Join(f.home, "Developer") + "/../.."}}, status: 404},
		{name: "a file", query: url.Values{"path": {filepath.Join(f.home, "notes.txt")}}, status: 404},
		{name: "a link to a file", query: url.Values{"path": {filepath.Join(f.home, "file-link")}}, status: 404},
		{name: "a missing folder", query: url.Values{"path": {filepath.Join(f.home, "missing")}}, status: 404},
		{name: "a relative path", query: url.Values{"path": {"Developer"}}, status: 400},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w, listing := f.browse(t, c.query)
			if w.Code != c.status {
				t.Fatalf("%d %s, want %d", w.Code, w.Body, c.status)
			}
			if c.status != 200 {
				wantCode := map[int]string{400: "invalid_request", 404: "not_found"}[c.status]
				if got := decodeWorkspaceError(t, w).Error.Code; got != wantCode {
					t.Errorf("code %q, want %q", got, wantCode)
				}
				return
			}
			if listing.Path != c.path || listing.DisplayPath != c.display || listing.Parent != c.parent || listing.Truncated {
				t.Errorf("path %q display %q parent %q truncated %v", listing.Path, listing.DisplayPath, listing.Parent, listing.Truncated)
			}
			if got := folderNames(listing); !slices.Equal(got, c.folders) {
				t.Errorf("folders %v, want %v", got, c.folders)
			}
			if !slices.Equal(listing.Roots, homeRoots) {
				t.Errorf("roots %v, want %v", listing.Roots, homeRoots)
			}
			for _, folder := range listing.Folders {
				wantPath := filepath.Join(listing.Path, folder.Name)
				if folder.Name == "inside-link" {
					wantPath = developer
				}
				if folder.Path != wantPath || folder.WorkspaceID != c.workspaceOf[folder.Name] || folder.GitRepository != slices.Contains(c.gitOf, folder.Name) {
					t.Errorf("folder %+v", folder)
				}
			}
		})
	}
	// A workspace's parent folder is offered as a root once it is configured.
	projects := filepath.Join(f.home, "Documents", "Projects")
	if err := os.MkdirAll(filepath.Join(projects, "app"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.add(t, filepath.Join(projects, "app"))
	_, listing := f.browse(t, url.Values{})
	want := append(slices.Clone(homeRoots), folderRoot{"Projects", filepath.Join(f.real, "Documents", "Projects")})
	if !slices.Equal(listing.Roots, want) {
		t.Errorf("roots %v, want %v", listing.Roots, want)
	}
}

func TestBrowseFoldersListsAtMost2000(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	many := filepath.Join(f.home, "many")
	for index := range folderListLimit + 1 {
		if err := os.MkdirAll(filepath.Join(many, fmt.Sprintf("f%04d", index)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(many, "a-file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	w, listing := f.browse(t, url.Values{"path": {many}})
	if w.Code != 200 || len(listing.Folders) != folderListLimit || !listing.Truncated || listing.Folders[0].Name != "f0000" || listing.Folders[folderListLimit-1].Name != "f1999" {
		t.Fatalf("%d: %d folders, truncated %v", w.Code, len(listing.Folders), listing.Truncated)
	}
	if err := os.Remove(filepath.Join(many, "f2000")); err != nil {
		t.Fatal(err)
	}
	if _, listing = f.browse(t, url.Values{"path": {many}}); len(listing.Folders) != folderListLimit || listing.Truncated {
		t.Fatalf("exactly 2000: %d folders, truncated %v", len(listing.Folders), listing.Truncated)
	}
}

func TestAddWorkspace(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	cases := []struct {
		name   string
		body   map[string]string
		status int
		code   string
		want   string // added name
		prefix string // ID prefix
		of     string // projectId of an already_workspace answer
	}{
		{name: "a folder keeps its name", body: map[string]string{"directory": filepath.Join(f.home, "Zeta")}, status: 201, want: "Zeta", prefix: "zeta-"},
		{name: "a given name is trimmed", body: map[string]string{"directory": filepath.Join(f.home, "alpha"), "name": "  My App 2 "}, status: 201, want: "My App 2", prefix: "my-app-2-"},
		{name: "a dot folder", body: map[string]string{"directory": filepath.Join(f.home, ".config", "tool")}, status: 201, want: "tool", prefix: "tool-"},
		{name: "a folder already added", body: map[string]string{"directory": filepath.Join(f.real, "Developer", "first")}, status: 409, code: "already_workspace", of: "p1"},
		{name: "a folder already added, through a link", body: map[string]string{"directory": filepath.Join(f.home, "inside-link", "first")}, status: 409, code: "already_workspace", of: "p1"},
		{name: "the home itself", body: map[string]string{"directory": f.home}, status: 400, code: "invalid_request"},
		{name: "a link leading outside", body: map[string]string{"directory": filepath.Join(f.home, "outside-link")}, status: 404, code: "not_found"},
		{name: "a folder outside", body: map[string]string{"directory": f.outside}, status: 404, code: "not_found"},
		{name: "the home's Library", body: map[string]string{"directory": filepath.Join(f.home, "Library")}, status: 404, code: "not_found"},
		{name: "a link to the Library", body: map[string]string{"directory": filepath.Join(f.home, "library-link")}, status: 404, code: "not_found"},
		{name: "the Trash", body: map[string]string{"directory": filepath.Join(f.home, ".Trash")}, status: 404, code: "not_found"},
		{name: "a file", body: map[string]string{"directory": filepath.Join(f.home, "notes.txt")}, status: 404, code: "not_found"},
		{name: "a missing folder", body: map[string]string{"directory": filepath.Join(f.home, "missing")}, status: 404, code: "not_found"},
		{name: "a relative path", body: map[string]string{"directory": "Zeta"}, status: 400, code: "invalid_request"},
		{name: "a name with =", body: map[string]string{"directory": filepath.Join(f.home, "Desktop"), "name": "a=b"}, status: 400, code: "invalid_request"},
		{name: "a name with a line break", body: map[string]string{"directory": filepath.Join(f.home, "Desktop"), "name": "a\nb"}, status: 400, code: "invalid_request"},
		{name: "a name too long", body: map[string]string{"directory": filepath.Join(f.home, "Desktop"), "name": strings.Repeat("é", 101)}, status: 400, code: "invalid_request"},
		{name: "a blank name", body: map[string]string{"directory": filepath.Join(f.home, "Desktop"), "name": " \t "}, status: 400, code: "invalid_request"},
		{name: "an unknown member", body: map[string]string{"directory": filepath.Join(f.home, "Desktop"), "path": "x"}, status: 400, code: "invalid_request"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			before := projectIDs(t, f.store)
			w := f.call(t, "POST", "/v1/projects", c.body)
			if w.Code != c.status {
				t.Fatalf("%d %s, want %d", w.Code, w.Body, c.status)
			}
			if c.status != 201 {
				answer := decodeWorkspaceError(t, w)
				if answer.Error.Code != c.code || answer.Error.ProjectID != c.of {
					t.Errorf("error %+v", answer.Error)
				}
				if after := projectIDs(t, f.store); !slices.Equal(after, before) {
					t.Errorf("projects %v, want %v", after, before)
				}
				return
			}
			project := decodeProject(t, w)
			resolved, _ := filepath.EvalSymlinks(c.body["directory"])
			if project.Name != c.want || !strings.HasPrefix(project.ID, c.prefix) || len(project.ID) != len(c.prefix)+6 || project.Directory != resolved {
				t.Errorf("added %+v", project)
			}
			if after := projectIDs(t, f.store); !slices.Equal(after, append(before, project.ID)) {
				t.Errorf("projects %v", after)
			}
		})
	}
}

func TestReaddingARemovedFolderRestoresItsID(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	zeta := f.add(t, filepath.Join(f.home, "Zeta"))
	if w := f.call(t, "POST", "/v1/projects/remove", map[string]string{"id": zeta.ID}); w.Code != 200 || w.Body.String() != `{"removed":true}`+"\n" {
		t.Fatalf("remove: %d %s", w.Code, w.Body)
	}
	if _, err := os.Stat(filepath.Join(f.home, "Zeta")); err != nil {
		t.Fatalf("the folder went with the workspace: %v", err)
	}
	st, _ := f.store.Read()
	if !slices.Equal(st.RemovedProjects, []RemovedProject{{zeta.ID, zeta.Directory}}) {
		t.Fatalf("removed %v", st.RemovedProjects)
	}
	// Through a link to its parent, the same folder gets its ID back.
	if err := os.Symlink(f.home, filepath.Join(f.home, "Desktop", "home-link")); err != nil {
		t.Fatal(err)
	}
	again := f.add(t, filepath.Join(f.home, "Desktop", "home-link", "Zeta"))
	if again.ID != zeta.ID || again.Name != "Zeta" {
		t.Errorf("added again as %+v, want ID %s", again, zeta.ID)
	}
	if st, _ = f.store.Read(); len(st.RemovedProjects) != 0 {
		t.Errorf("removed %v after adding again", st.RemovedProjects)
	}
	// Another folder gets a new ID.
	if alpha := f.add(t, filepath.Join(f.home, "alpha")); alpha.ID == zeta.ID || !strings.HasPrefix(alpha.ID, "alpha-") {
		t.Errorf("alpha %+v", alpha)
	}
}

func TestCreateWorkspace(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	cases := []struct {
		name   string
		body   map[string]any
		status int
		code   string
		git    bool
	}{
		{name: "in the home", body: map[string]any{"parentDirectory": f.home, "name": "New App"}, status: 201},
		{name: "with Git", body: map[string]any{"parentDirectory": filepath.Join(f.home, "Developer"), "name": "tool", "git": true}, status: 201, git: true},
		{name: "through a link inside the home", body: map[string]any{"parentDirectory": filepath.Join(f.home, "inside-link"), "name": "linked"}, status: 201},
		{name: "an existing folder", body: map[string]any{"parentDirectory": f.home, "name": "Zeta"}, status: 409, code: "already_exists"},
		{name: "an existing file", body: map[string]any{"parentDirectory": f.home, "name": "notes.txt"}, status: 409, code: "already_exists"},
		{name: "over a link leading outside", body: map[string]any{"parentDirectory": f.home, "name": "outside-link"}, status: 409, code: "already_exists"},
		{name: "in a link leading outside", body: map[string]any{"parentDirectory": filepath.Join(f.home, "outside-link"), "name": "escape"}, status: 404, code: "not_found"},
		{name: "in the home's Library", body: map[string]any{"parentDirectory": filepath.Join(f.home, "Library"), "name": "x"}, status: 404, code: "not_found"},
		{name: "in the Trash", body: map[string]any{"parentDirectory": filepath.Join(f.home, ".Trash"), "name": "x"}, status: 404, code: "not_found"},
		{name: "in a missing folder", body: map[string]any{"parentDirectory": filepath.Join(f.home, "missing"), "name": "x"}, status: 404, code: "not_found"},
		{name: "in a file", body: map[string]any{"parentDirectory": filepath.Join(f.home, "notes.txt"), "name": "x"}, status: 404, code: "not_found"},
		{name: "outside the home", body: map[string]any{"parentDirectory": f.outside, "name": "x"}, status: 404, code: "not_found"},
		{name: "a relative parent", body: map[string]any{"parentDirectory": "Developer", "name": "x"}, status: 400, code: "invalid_request"},
	}
	for _, name := range []string{"", ".", "..", ".hidden", "a/b", "../x", "a=b", "x\ny", strings.Repeat("x", 101)} {
		cases = append(cases, struct {
			name   string
			body   map[string]any
			status int
			code   string
			git    bool
		}{name: fmt.Sprintf("the name %q", name), body: map[string]any{"parentDirectory": f.home, "name": name}, status: 400, code: "invalid_request"})
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			before := projectIDs(t, f.store)
			w := f.call(t, "POST", "/v1/projects/create", c.body)
			if w.Code != c.status {
				t.Fatalf("%d %s, want %d", w.Code, w.Body, c.status)
			}
			if c.status != 201 {
				if got := decodeWorkspaceError(t, w).Error.Code; got != c.code {
					t.Errorf("code %q, want %q", got, c.code)
				}
				if after := projectIDs(t, f.store); !slices.Equal(after, before) {
					t.Errorf("projects %v", after)
				}
				return
			}
			project := decodeProject(t, w)
			parent, _ := filepath.EvalSymlinks(c.body["parentDirectory"].(string))
			directory := filepath.Join(parent, c.body["name"].(string))
			info, err := os.Stat(directory)
			if err != nil || !info.IsDir() || info.Mode().Perm() != 0o755 {
				t.Fatalf("folder %v %v", info, err)
			}
			if project.Name != c.body["name"] || project.Directory != directory || project.GitRepository != c.git {
				t.Errorf("created %+v", project)
			}
			head, err := os.ReadFile(filepath.Join(directory, ".git", "HEAD"))
			if c.git && (err != nil || string(head) != "ref: refs/heads/main\n") {
				t.Errorf("HEAD %q %v", head, err)
			}
			if after := projectIDs(t, f.store); !slices.Equal(after, append(before, project.ID)) {
				t.Errorf("projects %v", after)
			}
		})
	}
	if _, err := os.Lstat(filepath.Join(f.outside, "escape")); err == nil {
		t.Error("a folder was made outside the home")
	}
}

func TestCreateWorkspaceKeepsTheFolderWhenGitFails(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	t.Setenv("PATH", t.TempDir())
	w := f.call(t, "POST", "/v1/projects/create", map[string]any{"parentDirectory": f.home, "name": "No Git", "git": true})
	answer := decodeWorkspaceError(t, w)
	if w.Code != 500 || answer.Error.Code != "git_failed" || answer.Error.ProjectID == "" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if info, err := os.Stat(filepath.Join(f.home, "No Git")); err != nil || !info.IsDir() {
		t.Fatalf("folder: %v", err)
	}
	if ids := projectIDs(t, f.store); !slices.Equal(ids, []string{"p1", answer.Error.ProjectID}) {
		t.Errorf("projects %v", ids)
	}
}

func TestRenameWorkspace(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	cases := []struct {
		name   string
		body   map[string]string
		status int
		code   string
		want   string
	}{
		{name: "a new name", body: map[string]string{"id": "p1", "name": " Renamed "}, status: 200, want: "Renamed"},
		{name: "an unknown workspace", body: map[string]string{"id": "missing", "name": "Other"}, status: 404, code: "not_found"},
		{name: "an empty name", body: map[string]string{"id": "p1", "name": ""}, status: 400, code: "invalid_request"},
		{name: "a name with =", body: map[string]string{"id": "p1", "name": "a=b"}, status: 400, code: "invalid_request"},
		{name: "a name with a line break", body: map[string]string{"id": "p1", "name": "a\rb"}, status: 400, code: "invalid_request"},
		{name: "a name too long", body: map[string]string{"id": "p1", "name": strings.Repeat("x", 101)}, status: 400, code: "invalid_request"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := f.call(t, "POST", "/v1/projects/rename", c.body)
			if w.Code != c.status {
				t.Fatalf("%d %s, want %d", w.Code, w.Body, c.status)
			}
			st, _ := f.store.Read()
			if c.status != 200 {
				if got := decodeWorkspaceError(t, w).Error.Code; got != c.code || st.Config.Projects[0].Name != "Renamed" {
					t.Errorf("code %q, name %q", got, st.Config.Projects[0].Name)
				}
				return
			}
			if project := decodeProject(t, w); project.ID != "p1" || project.Name != c.want || st.Config.Projects[0].Name != c.want {
				t.Errorf("renamed %+v, stored %q", project, st.Config.Projects[0].Name)
			}
		})
	}
}

func TestRemoveWorkspace(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	zeta := f.add(t, filepath.Join(f.home, "Zeta"))
	terminal := f.call(t, "POST", "/v1/terminals", map[string]any{"projectId": zeta.ID, "title": "Shell", "rows": 24, "cols": 80})
	if terminal.Code != 201 {
		t.Fatalf("terminal: %d %s", terminal.Code, terminal.Body)
	}
	f.host.views.update("phone", true, &presenceViewInput{ProjectID: zeta.ID, SessionID: "s1"}, time.Now())
	f.host.views.update("pad", true, &presenceViewInput{ProjectID: "p1", SessionID: "s1"}, time.Now())
	one, zero := 1, 0
	count := func(value *int) string {
		if value == nil {
			return "absent"
		}
		return fmt.Sprint(*value)
	}
	cases := []struct {
		name            string
		body            map[string]any
		busy            int
		status          int
		code            string
		busyChats, open *int
		removed         bool
	}{
		{name: "an empty ID", body: map[string]any{"id": ""}, status: 400, code: "invalid_request"},
		{name: "an unknown workspace", body: map[string]any{"id": "missing"}, status: 404, code: "not_found"},
		{name: "terminals open", body: map[string]any{"id": zeta.ID}, status: 409, code: "workspace_busy", busyChats: &zero, open: &one},
		{name: "a chat working, even when ending terminals", body: map[string]any{"id": zeta.ID, "endTerminals": true}, busy: 1, status: 409, code: "workspace_busy", busyChats: &one, open: &one},
		{name: "ending its terminals", body: map[string]any{"id": zeta.ID, "endTerminals": true}, status: 200, removed: true},
		{name: "the last workspace", body: map[string]any{"id": "p1"}, status: 409, code: "last_workspace", removed: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f.agent.setBusy(zeta.ID, c.busy)
			w := f.call(t, "POST", "/v1/projects/remove", c.body)
			if w.Code != c.status {
				t.Fatalf("%d %s, want %d", w.Code, w.Body, c.status)
			}
			if c.status != 200 {
				answer := decodeWorkspaceError(t, w)
				if answer.Error.Code != c.code || count(answer.Error.BusyChats) != count(c.busyChats) || count(answer.Error.Terminals) != count(c.open) {
					t.Errorf("error %+v", answer.Error)
				}
			}
			if ids := projectIDs(t, f.store); slices.Contains(ids, zeta.ID) == c.removed {
				t.Errorf("projects %v", ids)
			}
		})
	}
	f.host.terminals.mu.Lock()
	left := len(f.host.terminals.entries)
	f.host.terminals.mu.Unlock()
	if left != 0 || len(f.terminal.endedIDs()) != 1 || len(f.terminal.forgottenIDs()) != 1 {
		t.Errorf("%d terminals left, %v ended, %v forgotten", left, f.terminal.endedIDs(), f.terminal.forgottenIDs())
	}
	if _, err := os.Stat(filepath.Join(f.home, "Zeta")); err != nil {
		t.Errorf("the folder went with the workspace: %v", err)
	}
	if f.host.views.viewers(zeta.ID, "s1", time.Now(), time.Minute) != nil || len(f.host.views.viewers("p1", "s1", time.Now(), time.Minute)) != 1 {
		t.Error("presence views were not refreshed")
	}
}

// A terminal that starts while its workspace is removed goes with it.
func TestTerminalStartedDuringRemovalGoesWithTheWorkspace(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{})
	zeta := f.add(t, filepath.Join(f.home, "Zeta"))
	entered, release := make(chan struct{}), make(chan struct{})
	f.terminal.mu.Lock()
	f.terminal.spawnEntered, f.terminal.spawnRelease = entered, release
	f.terminal.mu.Unlock()
	created := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		created <- f.call(t, "POST", "/v1/terminals", map[string]any{"projectId": zeta.ID, "title": "Shell", "rows": 24, "cols": 80})
	}()
	<-entered
	if w := f.call(t, "POST", "/v1/projects/remove", map[string]string{"id": zeta.ID}); w.Code != 200 {
		t.Fatalf("remove: %d %s", w.Code, w.Body)
	}
	close(release)
	if w := <-created; w.Code != 404 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	f.host.terminals.mu.Lock()
	left := len(f.host.terminals.entries)
	f.host.terminals.mu.Unlock()
	if left != 0 || len(f.terminal.endedIDs()) != 1 || len(f.terminal.forgottenIDs()) != 1 {
		t.Errorf("%d terminals left, %v ended, %v forgotten", left, f.terminal.endedIDs(), f.terminal.forgottenIDs())
	}
}

// Claude Code and Codex chats at work count as well.
func TestCLIChatsAtWorkKeepAWorkspaceBusy(t *testing.T) {
	chats, err := NewCLIChats(filepath.Join(t.TempDir(), "chats.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	f := newWorkspaceFixture(t, HostOptions{CLIChats: chats})
	f.add(t, filepath.Join(f.home, "Zeta"))
	record := &cliChatRecord{Session: Session{ID: "codex:busy", ProjectID: "p1", Provider: "codex"}, Directory: filepath.Join(f.home, "Developer", "first"), Busy: true}
	chats.mu.Lock()
	chats.records[record.Session.ID] = record
	chats.mu.Unlock()
	if details := f.host.projectDetails([]Project{{ID: "p1", Directory: record.Directory}}); details[0].Activity.BusyChats != 1 {
		t.Errorf("activity %+v", details[0].Activity)
	}
	w := f.call(t, "POST", "/v1/projects/remove", map[string]any{"id": "p1", "endTerminals": true})
	if answer := decodeWorkspaceError(t, w); w.Code != 409 || answer.Error.Code != "workspace_busy" || *answer.Error.BusyChats != 1 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	chats.mu.Lock()
	record.Busy = false
	chats.mu.Unlock()
	if w := f.call(t, "POST", "/v1/projects/remove", map[string]any{"id": "p1"}); w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

// Workspace changes keep devices and pending pairings, and the archive
// feed's epoch follows the configured workspaces: a feed waiting for a change
// answers with a resync.
func TestWorkspaceChangesKeepStateAndMoveTheEpoch(t *testing.T) {
	f := newWorkspaceFixture(t, HostOptions{Archive: testArchive(t, ArchiveOptions{})})
	code, err := f.store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	changes := func(query string) ArchiveChanges {
		t.Helper()
		w := f.call(t, "GET", "/v1/archive/changes"+query, nil)
		var page ArchiveChanges
		if err := json.Unmarshal(w.Body.Bytes(), &page); w.Code != 200 || err != nil {
			t.Fatalf("changes: %d %s", w.Code, w.Body)
		}
		return page
	}
	first := changes("")
	zeta := f.add(t, filepath.Join(f.home, "Zeta"))
	second := changes("?after=" + url.QueryEscape(first.Cursor))
	if second.Epoch == first.Epoch || !second.Resync {
		t.Fatalf("after adding: epoch %s (was %s), resync %v", second.Epoch, first.Epoch, second.Resync)
	}
	if w := f.call(t, "POST", "/v1/projects/rename", map[string]string{"id": zeta.ID, "name": "Renamed"}); w.Code != 200 {
		t.Fatalf("rename: %d %s", w.Code, w.Body)
	}
	if renamed := changes("?after=" + url.QueryEscape(second.Cursor)); renamed.Epoch != second.Epoch || renamed.Resync {
		t.Fatalf("a rename moved the epoch")
	}
	waited := make(chan ArchiveChanges, 1)
	go func() {
		w := f.call(t, "GET", "/v1/archive/changes?wait=15000&after="+url.QueryEscape(second.Cursor), nil)
		var page ArchiveChanges
		json.Unmarshal(w.Body.Bytes(), &page)
		waited <- page
	}()
	time.Sleep(100 * time.Millisecond)
	if w := f.call(t, "POST", "/v1/projects/remove", map[string]string{"id": zeta.ID}); w.Code != 200 {
		t.Fatalf("remove: %d %s", w.Code, w.Body)
	}
	select {
	case page := <-waited:
		if page.Epoch != first.Epoch || !page.Resync {
			t.Errorf("waiting feed: epoch %s (want %s), resync %v", page.Epoch, first.Epoch, page.Resync)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a waiting feed did not wake when a workspace was removed")
	}
	st, err := f.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Devices) != 1 || len(st.PairingCodes) != 1 || !slices.Equal(st.RemovedProjects, []RemovedProject{{zeta.ID, zeta.Directory}}) || st.Config.OpenCodeURL != "http://127.0.0.1:4096" {
		t.Errorf("state %+v", st)
	}
	if w := f.call(t, "GET", "/v1/projects", nil); w.Code != 200 {
		t.Errorf("the paired device lost access: %d", w.Code)
	}
	if _, _, err := f.store.RedeemPairingCode(code, "Tablet"); err != nil {
		t.Errorf("the pending pairing was lost: %v", err)
	}
}
