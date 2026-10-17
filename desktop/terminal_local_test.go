//go:build darwin || linux

package host

import (
	"bufio"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentland/host/internal/localterm"
	"agentland/host/keeper"
)

// Terminals from Terminal.app (terminal_local.go): `agentland-host terminals
// run` registers on the private local socket, the keeper adopts the agent's
// PTY, and the host follows it as this Mac's.

// localHost is the routed fixture's host at version, serving its local
// registration socket; it answers the socket's path.
func localHost(t *testing.T, f *routedFixture, version string) (*Host, string) {
	t.Helper()
	host := NewWithOptions(f.store, f.keeper, HostOptions{TerminalEnabled: true, Terminals: f.keeper.fakeTerminals, Archive: f.archive,
		LocalSessionToken: routeLocalToken, WorkspaceHome: f.home, Version: version})
	fakeTerminalPrograms(host, true)
	t.Cleanup(func() { host.Close() })
	return host, localListener(t, host)
}

// localListener serves host's registration socket in a short folder under
// /private/tmp: a Unix socket's path fits 103 bytes, and a test's own folder
// is longer.
func localListener(t *testing.T, host *Host) string {
	t.Helper()
	folder, err := os.MkdirTemp("/private/tmp", "al-local-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	path := localterm.SocketPath(filepath.Join(folder, "state.json"))
	closer, err := host.ListenLocalTerminals(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closer.Close() })
	return path
}

// register sends one registration and reads the host's reply; the
// connection stays open for the second line.
func register(t *testing.T, path string, request localterm.Request) (localterm.Reply, *bufio.Reader, net.Conn) {
	t.Helper()
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if request.Op == "" {
		request.Op = localterm.OpRegister
	}
	if err := localterm.WriteLine(conn, request); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	var reply localterm.Reply
	if err := localterm.ReadLine(reader, &reply); err != nil {
		t.Fatalf("reply: %v", err)
	}
	return reply, reader, conn
}

func claudeIn(folder string) localterm.Request {
	return localterm.Request{Command: "/opt/homebrew/bin/claude", Folder: folder, Rows: 24, Cols: 80}
}

// registeredMeta is the record a registration's reply hands the CLI.
func registeredMeta(t *testing.T, reply localterm.Reply) terminalMeta {
	t.Helper()
	if reply.Error != nil || reply.ID == "" {
		t.Fatalf("reply %+v (%+v)", reply, reply.Error)
	}
	meta, err := decodeTerminalMeta(reply.Meta)
	if err != nil {
		t.Fatalf("meta %q: %v", reply.Meta, err)
	}
	return meta
}

// adopt is the keeper adopting the registered terminal, as the CLI makes it.
func adopt(f *routedFixture, reply localterm.Reply) {
	f.keeper.addRunning(keeper.Info{ID: reply.ID, Running: true, Adopted: true, PID: 4242, Started: time.Now(), Meta: reply.Meta}, "")
}

// sendAdopted tells the host the keeper has the terminal and reads its answer.
func sendAdopted(t *testing.T, reader *bufio.Reader, conn net.Conn) localterm.Reply {
	t.Helper()
	if err := localterm.WriteLine(conn, localterm.Request{Op: localterm.OpAdopted}); err != nil {
		t.Fatal(err)
	}
	var reply localterm.Reply
	if err := localterm.ReadLine(reader, &reply); err != nil {
		t.Fatalf("adopted reply: %v", err)
	}
	return reply
}

func TestRoutedProgramNames(t *testing.T) {
	for command, want := range map[string]string{"claude": "claude", "qwen": "qwen-code", "copilot": "github-copilot-cli", "cursor-agent": "cursor",
		"droid": "factory-droid", "opencode": "opencode", "/opt/homebrew/bin/claude": "claude", "codex": "codex"} {
		if id, ok := routedProgram(command); !ok || id != want {
			t.Errorf("%s: %q %v, want %q", command, id, ok, want)
		}
	}
	for _, command := range []string{"vim", "", "Claude", "/bin/sh", "claude-code"} {
		if id, ok := routedProgram(command); ok {
			t.Errorf("%q routed as %q", command, id)
		}
	}
	for id, want := range map[string]string{"claude": "Claude Code", "opencode": "OpenCode", "qwen-code": "Qwen Code", "factory-droid": "Factory Droid"} {
		if label := routedProgramLabel(id); label != want {
			t.Errorf("%s labelled %q, want %q", id, label, want)
		}
	}
}

func TestLocalRegisterNamesTheMacAndTheDeepestWorkspace(t *testing.T) {
	f := newRoutedFixture(t)
	if _, err := f.store.addProject(f.folder(t, "a"), "A"); err != nil {
		t.Fatal(err)
	}
	p2, err := f.store.addProject(f.folder(t, "a", "b"), "B")
	if err != nil {
		t.Fatal(err)
	}
	folder := f.folder(t, "a", "b", "c")
	_, path := localHost(t, f, "1.2.3")
	request := claudeIn(folder)
	request.Version, request.ConversationID = "1.2.3", "0f6f2a3c-1b2d-4e5f-8a9b-0c1d2e3f4a5b"
	reply, _, _ := register(t, path, request)
	meta := registeredMeta(t, reply)
	if meta.Owner != localMacDeviceID || meta.Project != p2.ID || meta.Program != "claude" || meta.Title != "Claude Code" || !meta.Routed ||
		meta.Folder != folder || meta.ConversationID != request.ConversationID || meta.Created.IsZero() || meta.V != 2 {
		t.Fatalf("meta %+v", meta)
	}
	if !strings.Contains(string(reply.Meta), `"v":2`) || !strings.HasPrefix(reply.ID, "term_") {
		t.Fatalf("reply %s %s", reply.ID, reply.Meta)
	}
	// A conversation ID that is not one is left out.
	request.ConversationID = "--resume"
	if meta := registeredMeta(t, first(register(t, path, request))); meta.ConversationID != "" {
		t.Fatalf("conversation %q", meta.ConversationID)
	}
}

func first(reply localterm.Reply, _ *bufio.Reader, _ net.Conn) localterm.Reply { return reply }

func TestLocalRegisterOutsideAnyWorkspaceHasNone(t *testing.T) {
	f := newRoutedFixture(t)
	if _, err := f.store.addProject(f.folder(t, "a"), "A"); err != nil {
		t.Fatal(err)
	}
	folder := f.folder(t, "z")
	_, path := localHost(t, f, "")
	if meta := registeredMeta(t, first(register(t, path, claudeIn(folder)))); meta.Project != "" || meta.Folder != folder || !meta.Routed {
		t.Fatalf("meta %+v", meta)
	}
}

// The CLI sends its folder canonical; the host reads each workspace's folder
// canonical, so a workspace recorded through a link, or in another letter
// case, still holds it. The registration's folder is only ever a string.
func TestFolderMatchesItsWorkspaceThroughSymlinksAndCase(t *testing.T) {
	f := newRoutedFixture(t)
	inside := f.folder(t, "a", "sub")
	link := filepath.Join(f.home, "link")
	if err := os.Symlink(filepath.Join(f.home, "a"), link); err != nil {
		t.Fatal(err)
	}
	p1, err := f.store.addProject(link, "A")
	if err != nil {
		t.Fatal(err)
	}
	_, path := localHost(t, f, "")
	if meta := registeredMeta(t, first(register(t, path, claudeIn(inside)))); meta.Project != p1.ID || meta.Folder != inside {
		t.Fatalf("a workspace through a link: %+v", meta)
	}
	// A folder sent through the link matches by its string alone (the CLI
	// sends it canonical), and is recorded as sent.
	if meta := registeredMeta(t, first(register(t, path, claudeIn(filepath.Join(link, "sub"))))); meta.Project != p1.ID || meta.Folder != filepath.Join(link, "sub") {
		t.Fatalf("the link's own spelling: %+v", meta)
	}
	if runtime.GOOS != "darwin" {
		return
	}
	cased := filepath.Join(f.home, "B")
	f.folder(t, "b", "sub")
	if _, err := os.Stat(cased); err != nil {
		t.Skipf("the test folder's volume is case-sensitive: %v", err)
	}
	p2, err := f.store.addProject(cased, "B")
	if err != nil {
		t.Fatal(err)
	}
	if meta := registeredMeta(t, first(register(t, path, claudeIn(filepath.Join(f.home, "b", "sub"))))); meta.Project != p2.ID {
		t.Fatalf("a workspace in another case: %+v", meta)
	}
}

// terminalFolderJoins reads the workspace's folder canonical (as recorded,
// cleaned, when it is gone) and compares the terminal's folder as a string.
func TestFolderJoinsCompareCanonicalPathsAndKeepMissingFolders(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	workspace := filepath.Join(home, "a")
	if err := os.MkdirAll(filepath.Join(workspace, "b"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "link")
	if err := os.Symlink(workspace, link); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		directory, folder string
		want              bool
	}{
		{workspace, filepath.Join(workspace, "b"), true},
		{link, filepath.Join(workspace, "b"), true},
		// The terminal's folder is never resolved: it is recorded canonical.
		{workspace, filepath.Join(link, "b"), false},
		{workspace, filepath.Join(workspace, "b", "..", "b", "c"), true},
		{link, filepath.Join(workspace, "gone", "x"), true},
		{filepath.Join(home, "gone"), filepath.Join(home, "gone", "x", "..", "y"), true},
		{workspace, filepath.Join(home, "gone"), false},
		{workspace, home, false},
		{"", workspace, false},
		{workspace, "", false},
	} {
		if got := terminalFolderJoins(c.directory, c.folder); got != c.want {
			t.Errorf("terminalFolderJoins(%q, %q) = %v", c.directory, c.folder, got)
		}
	}
	// The workspace's folder is read once per joiner: the archive's rows are
	// then compared as strings.
	joins := terminalFolderJoiner(link)
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if !joins(filepath.Join(workspace, "b")) || joins(filepath.Join(home, "z")) {
		t.Error("the joiner read the workspace's folder again")
	}
	if err := os.Symlink(workspace, link); err != nil {
		t.Fatal(err)
	}
	if canonical, err := canonicalFolder(link); err != nil || canonical != workspace {
		t.Errorf("canonical %q, %v", canonical, err)
	}
	if _, err := canonicalFolder(filepath.Join(home, "gone")); err == nil {
		t.Error("a missing folder has a canonical path")
	}
	if project, ok := deepestWorkspace([]Project{{ID: "outer", Directory: home}, {ID: "inner", Directory: link}, {ID: "other", Directory: filepath.Join(home, "gone")}}, filepath.Join(workspace, "b")); !ok || project.ID != "inner" {
		t.Errorf("deepest %+v %v", project, ok)
	}
}

func TestLocalRegisterRefusals(t *testing.T) {
	cases := []struct {
		name    string
		prepare func(t *testing.T, f *routedFixture, host *Host)
		request func(folder string) localterm.Request
		code    string
		message string
	}{
		{name: "version", request: func(folder string) localterm.Request {
			r := claudeIn(folder)
			r.Version = "other"
			return r
		}, code: localterm.CodeVersion},
		{name: "program", request: func(folder string) localterm.Request {
			r := claudeIn(folder)
			r.Command = "/usr/bin/vim"
			return r
		}, code: localterm.CodeUnknownProgram},
		{name: "relative folder", request: func(string) localterm.Request { return claudeIn("a/b") }, code: localterm.CodeBadRequest},
		{name: "unclean folder", request: func(folder string) localterm.Request { return claudeIn(folder + "/../code") }, code: localterm.CodeBadRequest},
		{name: "trailing slash", request: func(folder string) localterm.Request { return claudeIn(folder + "/") }, code: localterm.CodeBadRequest},
		{name: "NUL", request: func(folder string) localterm.Request { return claudeIn(folder + "\x00x") }, code: localterm.CodeBadRequest},
		{name: "first line", request: func(folder string) localterm.Request {
			r := claudeIn(folder)
			r.Op = localterm.OpAdopted
			return r
		}, code: localterm.CodeBadRequest},
		{name: "no adopt", prepare: func(t *testing.T, f *routedFixture, _ *Host) { f.keeper.setFeatures(nil) }, request: claudeIn, code: localterm.CodeUnavailable},
		{name: "unusable", prepare: func(t *testing.T, _ *routedFixture, host *Host) { host.terminals.setUnusable() }, request: claudeIn, code: localterm.CodeUnavailable},
		{name: "limit", prepare: func(t *testing.T, f *routedFixture, host *Host) {
			for index := range terminalCapacity {
				if w := request(t, host.Handler(), "POST", "/v1/terminals", f.token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80}); w.Code != 201 {
					t.Fatalf("terminal %d: %d %s", index, w.Code, w.Body)
				}
			}
		}, request: claudeIn, code: localterm.CodeLimit, message: "AgentLand has 16 terminals open."},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newRoutedFixture(t)
			folder := f.folder(t, "code")
			host, path := localHost(t, f, "")
			if c.prepare != nil {
				c.prepare(t, f, host)
			}
			reply, reader, _ := register(t, path, c.request(folder))
			if reply.Error == nil || reply.Error.Code != c.code || reply.ID != "" || (c.message != "" && reply.Error.Message != c.message) {
				t.Fatalf("reply %+v (%+v)", reply, reply.Error)
			}
			if reply.Error.Message == "" {
				t.Fatal("a refusal without a message")
			}
			// One line, then the host hangs up, holding no place.
			if _, err := reader.ReadByte(); err != io.EOF {
				t.Fatalf("after the refusal: %v", err)
			}
			host.terminals.mu.Lock()
			starting := host.terminals.starting
			host.terminals.mu.Unlock()
			if starting != 0 {
				t.Fatalf("starting %d", starting)
			}
		})
	}
	t.Run("terminals off", func(t *testing.T) {
		host, _, _, _ := terminalTestHost(t, false)
		reply, _, _ := register(t, localListener(t, host), claudeIn(t.TempDir()))
		if reply.Error == nil || reply.Error.Code != localterm.CodeDisabled || reply.Error.Message != "AgentLand's terminal access is off." {
			t.Fatalf("reply %+v (%+v)", reply, reply.Error)
		}
	})
}

func TestAnAdoptedRegistrationIsFollowed(t *testing.T) {
	f := newRoutedFixture(t)
	folder := f.folder(t, "code")
	host, path := localHost(t, f, "")
	reply, reader, conn := register(t, path, claudeIn(folder))
	adopt(f, reply)
	if answer := sendAdopted(t, reader, conn); !answer.OK || answer.Error != nil {
		t.Fatalf("adopted: %+v (%+v)", answer, answer.Error)
	}
	project, info, meta := entryState(t, host, reply.ID)
	entry := macEntry(host, reply.ID)
	if entry.owner != localMacDeviceID || project.ID != "" || info.Directory != folder || info.Title != "Claude Code" || info.PID != 4242 || !meta.Routed || meta.Program != "claude" {
		t.Fatalf("entry %s %+v in %+v, record %+v", entry.owner, info, project, meta)
	}
	if calls := f.keeper.attachCalls(); len(calls) == 0 || calls[len(calls)-1] != (attachCall{id: reply.ID, from: 0}) {
		t.Fatalf("attaches %+v", calls)
	}
	// Archived outside any workspace, and the keeper's record names the log.
	logs := terminalLogsOf(t, f.archive, reply.ID)
	if len(logs) != 1 || logs[0].ProjectID != terminalNoWorkspaceArchiveID || logs[0].Status != "running" {
		t.Fatalf("logs %+v", logs)
	}
	if kept := f.keeper.meta(t, reply.ID); kept.LogID != logs[0].ID || !kept.Routed || kept.Folder != folder {
		t.Fatalf("kept %+v", kept)
	}
	// Its output reaches the host, and its end clears it.
	f.keeper.emit(reply.ID, "hello")
	waitFor(t, "the output", func() bool {
		entry.mu.Lock()
		defer entry.mu.Unlock()
		return string(entry.output) == "hello"
	})
	f.keeper.exit(reply.ID, 0)
	waitFor(t, "the routed agent to be cleared", func() bool { return macEntry(host, reply.ID) == nil })
	if _, err := reader.ReadByte(); err != io.EOF {
		t.Fatalf("after the answer: %v", err)
	}
}

func TestACancelledRegistrationFreesItsPlace(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	reply, reader, conn := register(t, path, claudeIn(f.folder(t, "code")))
	if reply.Error != nil {
		t.Fatalf("reply %+v", reply.Error)
	}
	host.terminals.mu.Lock()
	reserved := host.terminals.starting
	host.terminals.mu.Unlock()
	if reserved != 1 {
		t.Fatalf("reserved %d", reserved)
	}
	if err := localterm.WriteLine(conn, localterm.Request{Op: localterm.OpCancel}); err != nil {
		t.Fatal(err)
	}
	if _, err := reader.ReadByte(); err != io.EOF {
		t.Fatalf("after cancel: %v", err)
	}
	host.terminals.mu.Lock()
	starting, entries := host.terminals.starting, len(host.terminals.entries)
	host.terminals.mu.Unlock()
	if starting != 0 || entries != 0 || len(f.keeper.attachCalls()) != 0 {
		t.Fatalf("starting %d, entries %d, attaches %v", starting, entries, f.keeper.attachCalls())
	}
}

func TestADroppedConnectionAfterAdoptStillFollows(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	reply, _, conn := register(t, path, claudeIn(f.folder(t, "code")))
	adopt(f, reply)
	conn.Close()
	deadline := time.Now().Add(time.Second)
	for macEntry(host, reply.ID) == nil {
		if time.Now().After(deadline) {
			t.Fatal("the adopted terminal is not followed")
		}
		time.Sleep(5 * time.Millisecond)
	}
	host.terminals.mu.Lock()
	starting := host.terminals.starting
	host.terminals.mu.Unlock()
	if starting != 0 {
		t.Fatalf("starting %d", starting)
	}
}

// A connection that ends before the keeper has it leaves nothing behind.
func TestADroppedRegistrationWithoutAdoptionLeavesNothing(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	_, reader, conn := register(t, path, claudeIn(f.folder(t, "code")))
	if err := localterm.WriteLine(conn, localterm.Request{Op: localterm.OpAdopted}); err != nil {
		t.Fatal(err)
	}
	var answer localterm.Reply
	if err := localterm.ReadLine(reader, &answer); err != nil || answer.OK || answer.Error == nil {
		t.Fatalf("answer %+v, %v", answer, err)
	}
	host.terminals.mu.Lock()
	starting, entries := host.terminals.starting, len(host.terminals.entries)
	host.terminals.mu.Unlock()
	if starting != 0 || entries != 0 {
		t.Fatalf("starting %d, entries %d", starting, entries)
	}
}

// Ruling 4: only a terminal in a workspace checks that its workspace is
// still there; a registration outside any never ends another terminal.
func TestAProjectlessRegistrationEndsNoOtherTerminal(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	w := request(t, host.Handler(), "POST", "/v1/terminals", f.token, map[string]any{"projectId": "p1", "rows": 24, "cols": 80})
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	device := f.keeper.latest()
	reply, reader, conn := register(t, path, claudeIn(f.folder(t, "code")))
	adopt(f, reply)
	if answer := sendAdopted(t, reader, conn); !answer.OK {
		t.Fatalf("adopted: %+v", answer.Error)
	}
	if ends := f.keeper.endedIDs(); len(ends) != 0 {
		t.Fatalf("ended %v", ends)
	}
	if macEntry(host, device) == nil || macEntry(host, reply.ID) == nil {
		t.Fatal("a terminal is gone")
	}
}

// A workspace added between the reply and the adoption holds the terminal:
// its workspace is the deepest one as it is listed, and its record and log
// say so.
func TestARegistrationAdoptedAfterAWorkspaceIsAddedJoinsIt(t *testing.T) {
	f := newRoutedFixture(t)
	folder := f.folder(t, "w", "x")
	host, path := localHost(t, f, "")
	reply, reader, conn := register(t, path, claudeIn(folder))
	if meta := registeredMeta(t, reply); meta.Project != "" {
		t.Fatalf("meta %+v", meta)
	}
	w := request(t, host.Handler(), "POST", "/v1/projects", f.token, map[string]string{"directory": filepath.Join(f.home, "w")})
	if w.Code != 201 {
		t.Fatalf("add: %d %s", w.Code, w.Body)
	}
	project := decodeProject(t, w)
	adopt(f, reply)
	if answer := sendAdopted(t, reader, conn); !answer.OK {
		t.Fatalf("adopted: %+v", answer.Error)
	}
	joined, info, meta := entryState(t, host, reply.ID)
	if joined.ID != project.ID || info.ProjectID != project.ID || meta.Project != project.ID || info.Directory != folder {
		t.Fatalf("entry %+v %+v %+v", joined, info, meta)
	}
	if kept := f.keeper.meta(t, reply.ID); kept.Project != project.ID || !kept.Routed || kept.Folder != folder {
		t.Fatalf("kept %+v", kept)
	}
	if logs := terminalLogsOf(t, f.archive, reply.ID); len(logs) != 1 || logs[0].ProjectID != project.ID {
		t.Fatalf("logs %+v", logs)
	}
}

func TestTheLocalSocketIsPrivate(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Type() != os.ModeSocket || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket %v, %v", info.Mode(), err)
	}
	// Ruling 3: registering is the socket's alone, never an HTTP route (the
	// network and the tunnel reach only those).
	names := []string{localterm.OpRegister, localterm.OpAdopted, localterm.OpCancel, "terminals-local", "localterm", "local-terminal", "terminals/local"}
	for _, route := range routes {
		lower := strings.ToLower(route.path)
		if slices.ContainsFunc(names, func(name string) bool { return strings.Contains(lower, name) }) {
			t.Errorf("route %s %s", route.method, route.path)
		}
	}
	// Two listeners never serve one socket.
	if closer, err := host.ListenLocalTerminals(path); err == nil {
		closer.Close()
		t.Fatal("a second listener took the socket")
	}
	// The socket goes when it closes.
	again, err := host.ListenLocalTerminals(filepath.Join(filepath.Dir(path), "other.sock"))
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
	if _, err := os.Lstat(filepath.Join(filepath.Dir(path), "other.sock")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("after close: %v", err)
	}
}

// Ruling 10: a workspace added in another letter case, or through a link,
// still takes the running terminals outside any under its folder.
func TestFolderUnderAWorkspaceAddedInAnotherSpellingJoinsIt(t *testing.T) {
	f := newRoutedFixture(t)
	folder := f.folder(t, "a", "x")
	f.add("term_agent", routedRecord(folder), "")
	link := filepath.Join(f.home, "link")
	if err := os.Symlink(filepath.Join(f.home, "a"), link); err != nil {
		t.Fatal(err)
	}
	host := f.start(t)
	spelling := filepath.Join(f.home, "A")
	if _, err := os.Stat(spelling); runtime.GOOS != "darwin" || err != nil {
		// Elsewhere (or on a case-sensitive volume) the link stands in: the
		// store records the workspace resolved, so compare through the
		// helper directly.
		if !terminalFolderJoins(link, folder) {
			t.Fatal("the link does not hold the folder")
		}
		return
	}
	w := request(t, host.Handler(), "POST", "/v1/projects", f.token, map[string]string{"directory": spelling})
	if w.Code != 201 {
		t.Fatalf("add: %d %s", w.Code, w.Body)
	}
	project := decodeProject(t, w)
	if joined, info, _ := entryState(t, host, "term_agent"); joined.ID != project.ID || info.ProjectID != project.ID {
		t.Fatalf("joined %+v %+v (workspace %+v)", joined, info, project)
	}
}

// Ruling 26: the host never opens, stats or lists the registration's folder,
// which may be one macOS protects from AgentLand. A folder it cannot read, or
// one that is not there, is taken by its string and placed by it.
func TestLocalRegisterNeverOpensTheFolder(t *testing.T) {
	f := newRoutedFixture(t)
	p1, err := f.store.addProject(f.folder(t, "a"), "A")
	if err != nil {
		t.Fatal(err)
	}
	locked := f.folder(t, "a", "locked")
	inner := f.folder(t, "a", "locked", "inner")
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o755) })
	if _, err := os.Stat(inner); err == nil {
		t.Skip("this user reads a 0000 folder (root)")
	}
	host, path := localHost(t, f, "")
	missing := filepath.Join(f.home, "a", "missing", "deep")
	if meta := registeredMeta(t, first(register(t, path, claudeIn(missing)))); meta.Project != p1.ID || meta.Folder != missing {
		t.Fatalf("missing: %+v", meta)
	}
	reply, reader, conn := register(t, path, claudeIn(inner))
	if meta := registeredMeta(t, reply); meta.Project != p1.ID || meta.Folder != inner {
		t.Fatalf("unreadable: %+v", meta)
	}
	adopt(f, reply)
	if answer := sendAdopted(t, reader, conn); !answer.OK {
		t.Fatalf("adopted: %+v", answer.Error)
	}
	if project, info, _ := entryState(t, host, reply.ID); project.ID != p1.ID || info.Directory != inner {
		t.Fatalf("entry %+v in %+v", info, project)
	}
	// Outside any workspace it is taken all the same.
	if meta := registeredMeta(t, first(register(t, path, claudeIn("/nowhere/at/all")))); meta.Project != "" || meta.Folder != "/nowhere/at/all" {
		t.Fatalf("nowhere: %+v", meta)
	}
}

// A restore and a registration never both follow one terminal: whichever
// lists it first keeps it, the other's log is detached, and the keeper's
// record names the listed entry's log.
func TestARegistrationAndARestoreNeverBothFollowOneTerminal(t *testing.T) {
	t.Run("the registration lists it during the restore", func(t *testing.T) {
		f := newRoutedFixture(t)
		host, path := localHost(t, f, "")
		reply, reader, conn := register(t, path, claudeIn(f.folder(t, "code")))
		adopt(f, reply)
		var fired atomic.Bool
		f.keeper.mu.Lock()
		f.keeper.beforeAttach = func(id string) {
			// Restore's replay attaches first; the registration lists the
			// terminal meanwhile (and attaches itself, past this hook).
			if fired.CompareAndSwap(false, true) {
				if answer := sendAdopted(t, reader, conn); !answer.OK {
					t.Errorf("adopted: %+v", answer.Error)
				}
			}
		}
		f.keeper.mu.Unlock()
		info := keptInfo(t, f, reply.ID)
		if keeps, again := host.restoreTerminal(t.Context(), info, nil); !keeps || again {
			t.Fatalf("restore keeps %v, again %v", keeps, again)
		}
		checkOneFollower(t, f, host, reply.ID)
	})
	t.Run("the restore lists it first", func(t *testing.T) {
		f := newRoutedFixture(t)
		host, path := localHost(t, f, "")
		reply, _, _ := register(t, path, claudeIn(f.folder(t, "code")))
		adopt(f, reply)
		info := keptInfo(t, f, reply.ID)
		if keeps, _ := host.restoreTerminal(t.Context(), info, nil); !keeps {
			t.Fatal("restore dropped it")
		}
		listed := macEntry(host, reply.ID)
		// installEntry itself re-checks as it lists.
		late := host.restoredEntry(info, registeredMeta(t, reply), Project{})
		late.info.Directory = listed.info.Directory
		if err := host.installEntry(late); err != nil {
			t.Fatal(err)
		}
		if macEntry(host, reply.ID) != listed {
			t.Fatal("the second entry replaced the first")
		}
		checkOneFollower(t, f, host, reply.ID)
	})
}

func keptInfo(t *testing.T, f *routedFixture, id string) keeper.Info {
	t.Helper()
	infos, err := f.keeper.List(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	index := slices.IndexFunc(infos, func(info keeper.Info) bool { return info.ID == id })
	if index < 0 {
		t.Fatalf("the keeper has no %s", id)
	}
	return infos[index]
}

// checkOneFollower: one entry follows the terminal, with one open stream, and
// the keeper's record names its log.
func checkOneFollower(t *testing.T, f *routedFixture, host *Host, id string) {
	t.Helper()
	entry := macEntry(host, id)
	if entry == nil || entry.log == nil {
		t.Fatalf("entry %v", entry)
	}
	waitFor(t, "one open stream", func() bool { return f.keeper.openAttachments() == 1 })
	waitFor(t, "the record to name the listed log", func() bool { return f.keeper.meta(t, id).LogID == entry.log.ID() })
	f.keeper.emit(id, "once")
	waitFor(t, "the output", func() bool {
		entry.mu.Lock()
		defer entry.mu.Unlock()
		return string(entry.output) == "once"
	})
}

// A routed agent listed and followed answers OK even when its workspace goes
// as it starts: the removal then ends it, as it ends every terminal there.
func TestARegistrationWhoseWorkspaceGoesAsItStartsAnswersOK(t *testing.T) {
	f := newRoutedFixture(t)
	project, err := f.store.addProject(f.folder(t, "w"), "W")
	if err != nil {
		t.Fatal(err)
	}
	host, path := localHost(t, f, "")
	reply, reader, conn := register(t, path, claudeIn(f.folder(t, "w", "x")))
	adopt(f, reply)
	var fired atomic.Bool
	f.keeper.mu.Lock()
	f.keeper.beforeSetMeta = func(id string) {
		// After it was placed in the workspace, before it is listed.
		if id == reply.ID && fired.CompareAndSwap(false, true) {
			if err := f.store.removeProject(project.ID); err != nil {
				t.Error(err)
			}
		}
	}
	f.keeper.mu.Unlock()
	if answer := sendAdopted(t, reader, conn); !answer.OK || answer.Error != nil {
		t.Fatalf("adopted: %+v (%+v)", answer, answer.Error)
	}
	if !slices.Equal(f.keeper.endedIDs(), []string{reply.ID}) {
		t.Fatalf("ended %v", f.keeper.endedIDs())
	}
	waitFor(t, "it to go", func() bool { return macEntry(host, reply.ID) == nil })
	waitFor(t, "its log's end", func() bool {
		logs := terminalLogsOf(t, f.archive, reply.ID)
		return len(logs) == 1 && logs[0].Status != "running" && logs[0].EndReason == terminalEndWorkspaceRemoved
	})
}
