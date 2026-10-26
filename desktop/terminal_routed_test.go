package host

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// Terminals outside any workspace, and routed agents: coding agents typed in
// Terminal.app that the keeper adopted (terminal_backend.go, meta V2).

// routedFixture is a store with one paired device, the archive, a workspace
// home and a fake keeper that already holds terminals, before a host
// restores from them. The host also answers this Mac's session.
type routedFixture struct {
	store   *Store
	keeper  *terminalFixture
	archive *Archive
	token   string
	device  Device
	home    string // the workspace home, its symbolic links resolved
}

func newRoutedFixture(t *testing.T) *routedFixture {
	t.Helper()
	store, keeper, token, device := restoreFixture(t)
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return &routedFixture{store: store, keeper: keeper, archive: testArchive(t, ArchiveOptions{}), token: token, device: device, home: home}
}

// folder makes a folder in the workspace home.
func (f *routedFixture) folder(t *testing.T, parts ...string) string {
	t.Helper()
	path := filepath.Join(append([]string{f.home}, parts...)...)
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// routedRecord is a routed agent's record: this Mac's, in folder, in no
// workspace.
func routedRecord(folder string) terminalMeta {
	return terminalMeta{Owner: localMacDeviceID, Folder: folder, Program: "claude", Title: "Claude Code", Routed: true, Created: time.Now().UTC()}
}

// add is a terminal the keeper holds; a routed one it adopted.
func (f *routedFixture) add(id string, meta terminalMeta, output string) {
	info := keptTerminal(id, meta, 0)
	info.Adopted = meta.Routed
	f.keeper.addRunning(info, output)
}

func (f *routedFixture) start(t *testing.T) *Host {
	t.Helper()
	host := NewWithOptions(f.store, f.keeper, HostOptions{TerminalEnabled: true, Terminals: f.keeper.fakeTerminals, Archive: f.archive,
		LocalSessionToken: routeLocalToken, WorkspaceHome: f.home})
	fakeTerminalPrograms(host, true)
	t.Cleanup(func() { host.Close() })
	return host
}

// entryState is a listed terminal's workspace, info and record.
func entryState(t *testing.T, host *Host, id string) (Project, TerminalInfo, terminalMeta) {
	t.Helper()
	entry := macEntry(host, id)
	if entry == nil {
		t.Fatalf("%s is not listed", id)
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return entry.project, entry.info, entry.meta
}

func TestRestoreKeepsAProjectlessTerminal(t *testing.T) {
	f := newRoutedFixture(t)
	folder := f.folder(t, "code")
	f.add("term_agent", routedRecord(folder), "hello")
	host := f.start(t)

	project, info, meta := entryState(t, host, "term_agent")
	if info.Status != "running" || info.ProjectID != "" || project.ID != "" || info.Directory != folder || !meta.Routed {
		t.Fatalf("restored %+v in %+v, record %+v", info, project, meta)
	}
	if ends := f.keeper.endedIDs(); len(ends) != 0 {
		t.Fatalf("ended %v", ends)
	}
	logs := terminalLogsOf(t, f.archive, "term_agent")
	if len(logs) != 1 || logs[0].ProjectID != terminalNoWorkspaceArchiveID || logs[0].Status != "running" || logs[0].Bytes != 5 {
		t.Fatalf("logs %+v", logs)
	}
}

func TestRemovingAWorkspaceNeverEndsAProjectlessTerminal(t *testing.T) {
	f := newRoutedFixture(t)
	second, err := f.store.addProject(f.folder(t, "second"), "Second")
	if err != nil {
		t.Fatal(err)
	}
	f.add("term_free", routedRecord(f.folder(t, "second", "inside")), "")
	inWorkspace := routedRecord(second.Directory)
	inWorkspace.Project = second.ID
	f.add("term_in", inWorkspace, "")
	host := f.start(t)

	if err := host.endTerminals(""); err != nil {
		t.Fatal(err)
	}
	w := request(t, host.Handler(), "POST", "/v1/projects/remove", f.token, map[string]any{"id": second.ID, "endTerminals": true})
	if w.Code != 200 {
		t.Fatalf("remove: %d %s", w.Code, w.Body)
	}
	if !slices.Equal(f.keeper.endedIDs(), []string{"term_in"}) {
		t.Fatalf("ended %v", f.keeper.endedIDs())
	}
	if stored := archivedEnd(t, f.archive, "term_in"); stored.EndReason != terminalEndWorkspaceRemoved {
		t.Fatalf("archived %+v", stored)
	}
	if _, info, _ := entryState(t, host, "term_free"); info.Status != "running" {
		t.Fatalf("projectless %+v", info)
	}
}

func TestProjectlessRoutesAddressByTerminalID(t *testing.T) {
	f := newRoutedFixture(t)
	record := terminalMeta{Owner: f.device.ID, Folder: f.folder(t, "code"), Program: "shell", Title: "Shell", Created: time.Now().UTC()}
	f.add("term_free", record, "hello")
	host := f.start(t)
	type call struct {
		method, path string
		body         map[string]any
	}
	// calls are the five routes for the terminal, in projectID when one is
	// named; close goes last.
	calls := func(projectID string) []call {
		query := "terminalId=term_free&cursor=0&wait=0"
		if projectID != "" {
			query += "&projectId=" + projectID
		}
		body := func(fields map[string]any) map[string]any {
			fields["terminalId"] = "term_free"
			if projectID != "" {
				fields["projectId"] = projectID
			}
			return fields
		}
		return []call{
			{"GET", "/v1/terminal/output?" + query, nil},
			{"POST", "/v1/terminal/input", body(map[string]any{"data": []byte("ls\r")})},
			{"POST", "/v1/terminal/resize", body(map[string]any{"rows": 30, "cols": 100})},
			{"POST", "/v1/terminal/title", body(map[string]any{"title": "Listing files", "basedOn": 5})},
			{"POST", "/v1/terminal/close", body(map[string]any{})},
		}
	}
	for _, c := range calls("p1") {
		if w := request(t, host.Handler(), c.method, c.path, f.token, c.body); w.Code != 404 || !strings.Contains(w.Body.String(), "terminal_not_found") {
			t.Errorf("%s %s in p1: %d %s", c.method, c.path, w.Code, w.Body)
		}
	}
	for _, c := range calls("") {
		if w := request(t, host.Handler(), c.method, c.path, f.token, c.body); w.Code != 200 {
			t.Errorf("%s %s: %d %s", c.method, c.path, w.Code, w.Body)
		}
	}
	if input, size := f.keeper.input("term_free"), f.keeper.size(); input != "ls\r" || size != [2]int{30, 100} {
		t.Fatalf("input %q size %v", input, size)
	}
	if !slices.Equal(f.keeper.endedIDs(), []string{"term_free"}) || macEntry(host, "term_free") != nil {
		t.Fatalf("closed: ended %v", f.keeper.endedIDs())
	}
}

func TestAddingAWorkspaceAdoptsRunningProjectlessTerminalsUnderIt(t *testing.T) {
	f := newRoutedFixture(t)
	under, outside := f.folder(t, "a", "b", "c"), f.folder(t, "z")
	f.add("term_under", routedRecord(under), "under")
	f.add("term_outside", routedRecord(outside), "outside")
	// An agent in the new workspace's folder that ended before it was added.
	f.add("term_ended", routedRecord(f.folder(t, "a", "b")), "ended")
	host := f.start(t)
	f.keeper.exit("term_ended", 0)
	waitFor(t, "the ended agent to be cleared", func() bool { return macEntry(host, "term_ended") == nil })

	w := request(t, host.Handler(), "POST", "/v1/projects", f.token, map[string]string{"directory": filepath.Join(f.home, "a", "b")})
	if w.Code != 201 {
		t.Fatalf("add: %d %s", w.Code, w.Body)
	}
	project := decodeProject(t, w)
	joined, info, meta := entryState(t, host, "term_under")
	if joined.ID != project.ID || info.ProjectID != project.ID || meta.Project != project.ID || info.Status != "running" {
		t.Fatalf("joined %+v %+v %+v", joined, info, meta)
	}
	waitFor(t, "the keeper's record to name the workspace", func() bool { return f.keeper.meta(t, "term_under").Project == project.ID })
	if kept := f.keeper.meta(t, "term_under"); kept.V != 2 || !kept.Routed || kept.Folder != under {
		t.Fatalf("kept %+v", kept)
	}
	if left, info, _ := entryState(t, host, "term_outside"); left.ID != "" || info.ProjectID != "" || f.keeper.meta(t, "term_outside").Project != "" {
		t.Fatalf("outside %+v %+v", left, info)
	}
	for id, want := range map[string]string{"term_under": project.ID, "term_ended": project.ID, "term_outside": terminalNoWorkspaceArchiveID} {
		if logs := terminalLogsOf(t, f.archive, id); len(logs) != 1 || logs[0].ProjectID != want {
			t.Errorf("%s logs %+v, want %s", id, logs, want)
		}
	}
	// The workspace's search finds both.
	listed := decodeBody[ArchiveTerminalLogPage](t, request(t, host.Handler(), "GET", "/v1/archive/terminal-logs?projectId="+project.ID, f.token, nil))
	if len(listed.Logs) != 2 {
		t.Fatalf("listed %+v", listed.Logs)
	}
}

func TestARoutedTerminalIsClearedAsSoonAsItEnds(t *testing.T) {
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "working")
	host := f.start(t)
	f.keeper.exit("term_agent", 0)
	// The clear runs in the background: the keeper forgets the terminal, and
	// only then does the host drop it and remember how it ended, in one step
	// (clearEntry). So the test waits for all three, within
	// waitFor's few seconds, which is still nothing like the day a finished
	// terminal is otherwise kept.
	waitFor(t, "the ended agent to be forgotten and cleared", func() bool {
		return slices.Equal(f.keeper.forgottenIDs(), []string{"term_agent"}) && macEntry(host, "term_agent") == nil &&
			host.terminals.clearedEnd("term_agent", "") != nil
	})
	if end := host.terminals.clearedEnd("term_agent", ""); end == nil || end.Reason != terminalEndProgramExited {
		t.Fatalf("cleared end %+v", end)
	}
	if stored := archivedEnd(t, f.archive, "term_agent"); stored.Status != "exited" || stored.EndReason != terminalEndProgramExited || stored.Bytes != 7 {
		t.Fatalf("archived %+v", stored)
	}
}

func TestEndAllReleasesRoutedAndEndsTheRest(t *testing.T) {
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "")
	host := f.start(t)
	device := createTerminalFixture(t, host, f.token)

	code, body := macPost(t, host, "/v1/terminals/end-all", map[string]string{})
	if code != 200 || strings.TrimSpace(body) != `{"ended":1,"released":1}` {
		t.Fatalf("end-all: %d %s", code, body)
	}
	if ends, releases := f.keeper.endedIDs(), f.keeper.releasedIDs(); !slices.Equal(ends, []string{device.ID}) || !slices.Equal(releases, []string{"term_agent"}) {
		t.Fatalf("ended %v released %v", ends, releases)
	}
	if stored := archivedEnd(t, f.archive, "term_agent"); stored.EndReason != terminalEndKeptInTerminal || stored.Status != "disconnected" {
		t.Fatalf("archived %+v", stored)
	}
	waitFor(t, "the released agent to be cleared", func() bool { return macEntry(host, "term_agent") == nil })
	if end := host.terminals.clearedEnd("term_agent", ""); end == nil || end.Reason != terminalEndKeptInTerminal {
		t.Fatalf("cleared end %+v", end)
	}
	if stored := archivedEnd(t, f.archive, device.ID); stored.EndReason != terminalEndHostStopped {
		t.Fatalf("device terminal archived %+v", stored)
	}
}

func TestEndOnARoutedTerminalEndsIt(t *testing.T) {
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "")
	host := f.start(t)
	if code, body := macPost(t, host, "/v1/terminals/end", map[string]string{"terminalId": "term_agent"}); code != 200 {
		t.Fatalf("end: %d %s", code, body)
	}
	if ends, releases := f.keeper.endedIDs(), f.keeper.releasedIDs(); !slices.Equal(ends, []string{"term_agent"}) || len(releases) != 0 {
		t.Fatalf("ended %v released %v", ends, releases)
	}
	if stored := archivedEnd(t, f.archive, "term_agent"); stored.EndReason != terminalEndOnMac {
		t.Fatalf("archived %+v", stored)
	}
}

func TestRunningCountsRouted(t *testing.T) {
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "")
	host := f.start(t)
	createTerminalFixture(t, host, f.token)
	w := localRequest(t, host.Handler(), "GET", "/v1/terminals/running", routeLocalToken, nil)
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"running":2,"routed":1}` {
		t.Fatalf("running: %d %s", w.Code, w.Body)
	}
}

func TestMacListMarksRouted(t *testing.T) {
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "")
	host := f.start(t)
	device := createTerminalFixture(t, host, f.token)
	list := macAll(t, host).Terminals
	byID := map[string]macTerminal{}
	for _, terminal := range list {
		byID[terminal.ID] = terminal
	}
	if agent := byID["term_agent"]; len(list) != 2 || !agent.Routed || agent.Workspace != "" || agent.ProjectID != "" || agent.DeviceName != "This Mac" || agent.Program != "claude" {
		t.Fatalf("listed %+v", list)
	}
	if other := byID[device.ID]; other.Routed || other.Workspace != "Project" {
		t.Fatalf("device terminal %+v", other)
	}
}

func TestEveryHostTerminalGetsItsID(t *testing.T) {
	f := newRoutedFixture(t)
	host := f.start(t)
	// The host itself runs in an AgentLand terminal.
	host.terminals.launcher.environ = func() []string {
		return []string{"SHELL=/bin/sh", "PATH=/usr/bin:/bin", "AGENTLAND_TERMINAL=term_outer"}
	}
	info := createTerminalFixture(t, host, f.token)
	var marked []string
	for _, item := range f.keeper.lastSpawn().Env {
		if strings.HasPrefix(item, "AGENTLAND_TERMINAL=") {
			marked = append(marked, item)
		}
	}
	if !slices.Equal(marked, []string{"AGENTLAND_TERMINAL=" + info.ID}) {
		t.Fatalf("environment marks %v", marked)
	}
	if env := terminalEnvironmentWithID([]string{"A=1", "AGENTLAND_TERMINAL=term_outer", "B=2"}, "term_new", "", ""); !slices.Equal(env, []string{"A=1", "B=2", "AGENTLAND_TERMINAL=term_new"}) {
		t.Fatalf("environment %v", env)
	}
}

func TestProjectlessLogStaysOutOfWorkspaceSearch(t *testing.T) {
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "secret-free output")
	host := f.start(t)
	logs := terminalLogsOf(t, f.archive, "term_agent")
	if len(logs) != 1 || logs[0].ProjectID != terminalNoWorkspaceArchiveID {
		t.Fatalf("logs %+v", logs)
	}
	for _, path := range []string{"/v1/archive/terminal-logs?projectId=p1", "/v1/archive/terminal-logs"} {
		w := request(t, host.Handler(), "GET", path, f.token, nil)
		if w.Code != 200 || strings.Contains(w.Body.String(), logs[0].ID) {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body)
		}
	}
}

// changeProject is the workspace the change feed names for a terminal log.
func changeProject(t *testing.T, archive *Archive, logID string) string {
	t.Helper()
	flushArchive(t, archive)
	var project string
	if err := archive.readDB.QueryRowContext(t.Context(), `SELECT project_id FROM changes WHERE entity = 'terminalLog' AND entity_id = ?`, logID).Scan(&project); err != nil {
		t.Fatal(err)
	}
	return project
}

// The two windows where a terminal outside any workspace has ended but its
// log has not recorded the end yet: one still listed, whose follower has yet
// to record it, and one a device closed, dropped before that. Adding the
// workspace files both logs there, and each end, recorded after the move,
// names the workspace in the change feed.
func TestAProjectlessLogEndingAsItsWorkspaceIsAddedMovesThere(t *testing.T) {
	f := newRoutedFixture(t)
	folder := f.folder(t, "a", "b")
	f.add("term_ending", terminalMeta{Owner: f.device.ID, Folder: folder, Program: "shell", Title: "Shell", Created: time.Now().UTC()}, "bye")
	host := f.start(t)
	dropped, err := f.archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_dropped", ProjectID: terminalNoWorkspaceArchiveID, Folder: filepath.Join(folder, "c"), OwnerDeviceID: f.device.ID})
	if err != nil {
		t.Fatal(err)
	}
	// Ended, but the keeper has not reported the exit to the follower yet.
	entry := macEntry(host, "term_ending")
	entry.mu.Lock()
	entry.endLocked("exited", terminalEndProgramExited, nil, nil)
	entry.mu.Unlock()
	ending := terminalLogsOf(t, f.archive, "term_ending")
	if len(ending) != 1 || ending[0].Status != "running" {
		t.Fatalf("logs before %+v", ending)
	}

	w := request(t, host.Handler(), "POST", "/v1/projects", f.token, map[string]string{"directory": folder})
	if w.Code != 201 {
		t.Fatalf("add: %d %s", w.Code, w.Body)
	}
	project := decodeProject(t, w)
	for _, id := range []string{"term_ending", "term_dropped"} {
		if logs := terminalLogsOf(t, f.archive, id); len(logs) != 1 || logs[0].ProjectID != project.ID {
			t.Errorf("%s logs %+v", id, logs)
		}
	}
	if joined, _, _ := entryState(t, host, "term_ending"); joined.ID != "" {
		t.Fatalf("an ended terminal joined %+v", joined)
	}
	f.keeper.exit("term_ending", 0)
	dropped.CloseEnded("exited", nil, terminalEndDevice, f.device.ID)
	if stored := archivedEnd(t, f.archive, "term_ending"); stored.ProjectID != project.ID {
		t.Fatalf("archived %+v", stored)
	}
	for _, logID := range []string{ending[0].ID, dropped.ID()} {
		if named := changeProject(t, f.archive, logID); named != project.ID {
			t.Errorf("the change feed names %s for %s", named, logID)
		}
	}
}

// A log's end snapshotted before its terminal joined a workspace and queued
// after the move still names the new workspace in the change feed.
func TestAProjectlessLogsEndQueuedBeforeAMoveNamesTheNewWorkspace(t *testing.T) {
	archive := testArchive(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{TerminalID: "term_x", ProjectID: terminalNoWorkspaceArchiveID, Folder: "/Users/someone/code"})
	if err != nil {
		t.Fatal(err)
	}
	log.Append([]byte("output"))
	log.mu.Lock()
	log.writeLocked()
	log.status = "exited"
	row := log.rowLocked()
	log.mu.Unlock()
	log.MoveToProject("p2")
	archive.submitTerminalLogRow(row, true)
	if named := changeProject(t, archive, log.ID()); named != "p2" {
		t.Fatalf("the change feed names %s", named)
	}
	if stored := storedTerminalLog(t, archive, log.ID()); stored.ProjectID != "p2" || stored.Status != "exited" {
		t.Fatalf("stored %+v", stored)
	}
}

// A routed agent whose end no follower records (the keeper could not be used
// for it, and then it was gone) is cleared at once too.
func TestARoutedAgentNoFollowerRecordsIsStillCleared(t *testing.T) {
	shortKeeperRetry(t)
	f := newRoutedFixture(t)
	f.add("term_agent", routedRecord(f.folder(t, "code")), "working")
	host := f.start(t)
	entry := macEntry(host, "term_agent")
	f.keeper.setStatus(KeeperUnusable)
	f.keeper.dropAttachments("term_agent")
	select {
	case <-entry.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the follower kept following an unusable keeper")
	}
	// The keeper is gone: the retry loop finds none, and Forget has none to ask.
	f.keeper.mu.Lock()
	f.keeper.status, f.keeper.forgetErr = KeeperNone, errNoKeeper
	f.keeper.mu.Unlock()
	waitFor(t, "the agent to be cleared", func() bool { return macEntry(host, "term_agent") == nil })
	if end := host.terminals.clearedEnd("term_agent", ""); end == nil || end.Reason != terminalEndKeeperStopped {
		t.Fatalf("cleared end %+v", end)
	}
	if stored := archivedEnd(t, f.archive, "term_agent"); stored.EndReason != terminalEndKeeperStopped {
		t.Fatalf("archived %+v", stored)
	}
}
