package host

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// Every paired device sees and drives every terminal (terminal_shared.go).

// sharedFixture is a host over a keeper that already holds a routed agent of
// this Mac's, "term_mac" in <home>/x, with paired devices A ("Phone A") and B
// ("iPad"), the archive and this Mac's session. HOME is the workspace home, and
// the host's clock is the fixture's, an hour ahead of the agent's start.
type sharedFixture struct {
	*routedFixture
	host             *Host
	clock            *testClock
	a, b             string
	deviceA, deviceB Device
}

func newSharedFixture(t *testing.T) *sharedFixture {
	t.Helper()
	f := newRoutedFixture(t)
	t.Setenv("HOME", f.home)
	f.add("term_mac", routedRecord(f.folder(t, "x")), "")
	host := f.start(t)
	clock := &testClock{now: time.Now().Add(time.Hour).UTC().Truncate(time.Millisecond)}
	host.now = clock.Now
	a := pairedAs(t, host, f.store, "Phone A")
	b := pairedAs(t, host, f.store, "iPad")
	return &sharedFixture{routedFixture: f, host: host, clock: clock, a: a, b: b, deviceA: pairedDevice(t, f.store, a), deviceB: pairedDevice(t, f.store, b)}
}

// othersList is GET /v1/terminals/others as token's device gets it: the
// terminals in order, and each one's raw fields.
func (f *sharedFixture) othersList(t *testing.T, token string) ([]sharedTerminal, []map[string]json.RawMessage) {
	t.Helper()
	w := request(t, f.host.Handler(), "GET", "/v1/terminals/others", token, nil)
	if w.Code != 200 {
		t.Fatalf("others: %d %s", w.Code, w.Body)
	}
	var raw struct {
		Terminals []map[string]json.RawMessage `json:"terminals"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil || raw.Terminals == nil {
		t.Fatalf("others %s: %v", w.Body, err)
	}
	return decodeBody[struct {
		Terminals []sharedTerminal `json:"terminals"`
	}](t, w).Terminals, raw.Terminals
}

// others is othersList by terminal ID.
func (f *sharedFixture) others(t *testing.T, token string) map[string]sharedTerminal {
	t.Helper()
	list, _ := f.othersList(t, token)
	byID := map[string]sharedTerminal{}
	for _, terminal := range list {
		byID[terminal.ID] = terminal
	}
	return byID
}

func TestAnotherDeviceCanReadTypeResizeNameAndEnd(t *testing.T) {
	f := newSharedFixture(t)
	info := createTerminalFixture(t, f.host, f.a)
	f.keeper.emit(info.ID, "ready\r\n")
	waitFor(t, "A's output, read by B", func() bool { return readTerminal(t, f.host, f.b, info.ID, 0).Cursor == 7 })
	post := func(path string, body map[string]any) {
		t.Helper()
		if w := request(t, f.host.Handler(), "POST", path, f.b, body); w.Code != 200 {
			t.Fatalf("B's %s on A's terminal: %d %s", path, w.Code, w.Body)
		}
	}
	post("/v1/terminal/input", map[string]any{"projectId": "p1", "terminalId": info.ID, "data": []byte("ls\n")})
	if got := f.keeper.input(info.ID); got != "ls\n" {
		t.Fatalf("input %q", got)
	}
	post("/v1/terminal/resize", map[string]any{"projectId": "p1", "terminalId": info.ID, "rows": 30, "cols": 100})
	if f.keeper.size() != [2]int{30, 100} {
		t.Fatalf("size %v", f.keeper.size())
	}
	post("/v1/terminal/title", map[string]any{"projectId": "p1", "terminalId": info.ID, "title": "List the files", "basedOn": 7})
	if _, listed, _ := entryState(t, f.host, info.ID); listed.ContextTitle != "List the files" {
		t.Fatalf("title %q", listed.ContextTitle)
	}
	// The Mac's routed agent, outside any workspace, is addressed without one.
	if output := request(t, f.host.Handler(), "GET", "/v1/terminal/output?terminalId=term_mac&cursor=0&wait=0", f.b, nil); output.Code != 200 {
		t.Fatalf("B reads the Mac's agent: %d %s", output.Code, output.Body)
	}
	post("/v1/terminal/input", map[string]any{"terminalId": "term_mac", "data": []byte("y")})
	if got := f.keeper.input("term_mac"); got != "y" {
		t.Fatalf("the Mac's agent got %q", got)
	}
	post("/v1/terminal/close", map[string]any{"projectId": "p1", "terminalId": info.ID})
	if !slices.Contains(f.keeper.endedIDs(), info.ID) {
		t.Fatalf("ended %v", f.keeper.endedIDs())
	}
	// A, still reading it, learns at once that B ended it, before the
	// archive records it.
	w := outputFixture(t, f.host, f.a, info.ID, 0)
	if body := decodeBody[terminalNotFoundBody](t, w); w.Code != 404 || body.Error.Ended == nil || body.Error.Ended.Reason != terminalEndDevice || body.Error.Ended.Device != "iPad" {
		t.Fatalf("A reads the terminal B ended: %d %s", w.Code, w.Body)
	}
	if stored := archivedEnd(t, f.archive, info.ID); stored.EndReason != terminalEndDevice || stored.endedBy != f.deviceB.ID {
		t.Fatalf("archived %+v", stored)
	}
}

func TestAnotherDeviceLearnsHowAClearedTerminalEnded(t *testing.T) {
	f := newSharedFixture(t)
	info := createTerminalFixture(t, f.host, f.a)
	f.keeper.exit(info.ID, 2)
	waitForTerminalEnd(t, f.host, f.b, info.ID)
	if code, body := macPost(t, f.host, "/v1/terminals/clear", map[string]string{"terminalId": info.ID}); code != 200 {
		t.Fatalf("clear: %d %s", code, body)
	}
	for _, target := range []string{"/v1/terminal/output?projectId=p1&terminalId=" + info.ID + "&cursor=0", "/v1/terminal/output?terminalId=" + info.ID + "&cursor=0"} {
		w := request(t, f.host.Handler(), "GET", target, f.b, nil)
		body := decodeBody[terminalNotFoundBody](t, w)
		if w.Code != 404 || body.Error.Ended == nil || body.Error.Ended.Reason != terminalEndProgramExited || body.Error.Ended.ExitCode == nil || *body.Error.Ended.ExitCode != 2 {
			t.Fatalf("%s: %d %s", target, w.Code, w.Body)
		}
	}
	if end := f.host.terminals.clearedEnd(info.ID, ""); end == nil || end.Reason != terminalEndProgramExited {
		t.Fatalf("cleared end %+v", end)
	}
	if end := f.host.terminals.clearedEnd(info.ID, "elsewhere"); end != nil {
		t.Fatalf("another workspace learned %+v", end)
	}
	// The Mac's agent is cleared as it ends; A learns how.
	f.keeper.exit("term_mac", 0)
	waitFor(t, "the agent to be cleared", func() bool { return macEntry(f.host, "term_mac") == nil })
	w := request(t, f.host.Handler(), "GET", "/v1/terminal/output?terminalId=term_mac&cursor=0", f.a, nil)
	if body := decodeBody[terminalNotFoundBody](t, w); w.Code != 404 || body.Error.Ended == nil || body.Error.Ended.Reason != terminalEndProgramExited {
		t.Fatalf("A reads the Mac's ended agent: %d %s", w.Code, w.Body)
	}
}

// A device that finds a cleared terminal gone learns at once how it ended:
// the host remembers the end in the same step that drops the terminal.
func TestAClearedTerminalIsRememberedAsItIsDropped(t *testing.T) {
	f := newSharedFixture(t)
	for round := range 20 {
		info := createTerminalFixture(t, f.host, f.a)
		f.keeper.exit(info.ID, 0)
		waitForTerminalEnd(t, f.host, f.a, info.ID)
		entry := macEntry(f.host, info.ID)
		cleared := make(chan error, 1)
		go func() { cleared <- f.host.terminals.clearEntry(context.Background(), entry, f.host.terminals.now()) }()
		deadline := time.Now().Add(5 * time.Second)
		for macEntry(f.host, info.ID) != nil {
			if time.Now().After(deadline) {
				t.Fatalf("round %d: never cleared", round)
			}
			runtime.Gosched()
		}
		if end := f.host.terminals.clearedEnd(info.ID, ""); end == nil {
			t.Fatalf("round %d: the terminal was dropped before its end was remembered", round)
		}
		if err := <-cleared; err != nil {
			t.Fatal(err)
		}
	}
}

// After a restart (the host remembers no cleared terminal), the archive still
// says how a forgotten terminal ended when a device asks without a workspace:
// one in a workspace, and one outside any.
func TestAForgottenTerminalSaysHowItEndedWithoutAWorkspace(t *testing.T) {
	f := newSharedFixture(t)
	info := createTerminalFixture(t, f.host, f.a)
	if w := request(t, f.host.Handler(), "POST", "/v1/terminal/close", f.a, map[string]any{"projectId": "p1", "terminalId": info.ID}); w.Code != 200 {
		t.Fatalf("close: %d %s", w.Code, w.Body)
	}
	archivedEnd(t, f.archive, info.ID)
	f.keeper.exit("term_mac", 0)
	waitFor(t, "the agent to be cleared", func() bool { return macEntry(f.host, "term_mac") == nil })
	archivedEnd(t, f.archive, "term_mac")
	f.host.terminals.mu.Lock()
	clear(f.host.terminals.cleared)
	f.host.terminals.mu.Unlock()
	for id, want := range map[string]TerminalEnd{info.ID: {Reason: terminalEndDevice, Device: "Phone A"}, "term_mac": {Reason: terminalEndProgramExited}} {
		w := request(t, f.host.Handler(), "GET", "/v1/terminal/output?terminalId="+id+"&cursor=0", f.b, nil)
		body := decodeBody[terminalNotFoundBody](t, w)
		if w.Code != 404 || body.Error.Ended == nil || body.Error.Ended.Reason != want.Reason || body.Error.Ended.Device != want.Device {
			t.Fatalf("%s without a workspace: %d %s", id, w.Code, w.Body)
		}
	}
	if w := request(t, f.host.Handler(), "GET", "/v1/terminal/output?projectId=p1&terminalId="+info.ID+"&cursor=0", f.b, nil); decodeBody[terminalNotFoundBody](t, w).Error.Ended == nil {
		t.Fatalf("in its workspace: %d %s", w.Code, w.Body)
	}
	// The Mac's agent was never in p1.
	if w := request(t, f.host.Handler(), "GET", "/v1/terminal/output?projectId=p1&terminalId=term_mac&cursor=0", f.b, nil); w.Code != 404 || strings.Contains(w.Body.String(), "ended") {
		t.Fatalf("the agent in a workspace it was never in: %d %s", w.Code, w.Body)
	}
	if _, err := f.archive.TerminalEnding(t.Context(), "term_mac", terminalNoWorkspaceArchiveID); err != nil {
		t.Fatalf("the agent's own archive project: %v", err)
	}
}

func TestOwnListStaysOwn(t *testing.T) {
	f := newSharedFixture(t)
	a := createTerminalFixture(t, f.host, f.a)
	b := createTerminalFixture(t, f.host, f.b)
	listed := listedTerminals(t, f.host, f.b)
	if len(listed) != 1 || listed[0].ID != b.ID {
		t.Fatalf("B's list %+v", listed)
	}
	if listed := listedTerminals(t, f.host, f.a); len(listed) != 1 || listed[0].ID != a.ID {
		t.Fatalf("A's list %+v", listed)
	}
}

func TestOthersListsOnlyOtherDevicesRunningTerminals(t *testing.T) {
	f := newSharedFixture(t)
	running := createTerminalFixture(t, f.host, f.a)
	exited := createTerminalFixture(t, f.host, f.a)
	own := createTerminalFixture(t, f.host, f.b)
	f.keeper.exit(exited.ID, 0)
	waitForTerminalEnd(t, f.host, f.a, exited.ID)
	f.keeper.emit(running.ID, "\x1b]0;vim notes.md\a")
	waitFor(t, "the title", func() bool {
		_, info, _ := entryState(t, f.host, running.ID)
		return info.ProgramTitle == "vim notes.md"
	})

	list, raw := f.othersList(t, f.b)
	if len(list) != 2 {
		t.Fatalf("others %+v", list)
	}
	byID := map[string]int{}
	for index, terminal := range list {
		byID[terminal.ID] = index
	}
	if _, listed := byID[own.ID]; listed {
		t.Fatal("B's own terminal is listed")
	}
	phone, phoneRaw := list[byID[running.ID]], raw[byID[running.ID]]
	if phone.DeviceID != f.deviceA.ID || phone.DeviceName != "Phone A" || phone.OnMac || phone.Program != "shell" || phone.Title != "Shell" ||
		phone.ProgramTitle != "vim notes.md" || phone.ContextTitle != "vim notes.md" || phone.Folder != mustProject(t, f.store).Directory ||
		phone.ProjectID == nil || *phone.ProjectID != "p1" || phone.Workspace == nil || *phone.Workspace != "Project" || phone.Routed ||
		phone.Status != "running" || phone.Activity != "working" || phone.LastOutputAt == "" || phone.LastActiveAt != phone.LastOutputAt {
		t.Fatalf("A's terminal %+v", phone)
	}
	if _, err := time.Parse(time.RFC3339, phone.LastOutputAt); err != nil || !strings.HasSuffix(phone.LastOutputAt, "Z") {
		t.Fatalf("lastOutputAt %q", phone.LastOutputAt)
	}
	index, ok := byID["term_mac"]
	if !ok {
		t.Fatalf("the Mac's agent is missing: %+v", list)
	}
	mac, macRaw := list[index], raw[index]
	if !mac.OnMac || mac.DeviceID != localMacDeviceID || mac.DeviceName != "" || mac.ProjectID != nil || mac.Workspace != nil || mac.DisplayFolder != "~/x" ||
		mac.Folder != f.home+"/x" || !mac.Routed || mac.Status != "running" || mac.Program != "claude" || mac.Title != "Claude Code" ||
		mac.Activity != "quiet" || mac.LastActiveAt == "" {
		t.Fatalf("the Mac's agent %+v", mac)
	}
	for key, want := range map[string]string{"projectId": "null", "workspace": "null"} {
		if got := string(macRaw[key]); got != want {
			t.Errorf("the Mac's agent's %s is %s, want %s", key, got, want)
		}
	}
	if _, has := macRaw["lastOutputAt"]; has {
		t.Errorf("the Mac's agent has lastOutputAt %s with no output", macRaw["lastOutputAt"])
	}
	keys := make([]string, 0, len(phoneRaw))
	for key := range phoneRaw {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	if got := strings.Join(keys, ","); got != "activity,contextTitle,contextTitleSource,deviceId,deviceName,displayFolder,folder,id,lastActiveAt,lastOutputAt,onMac,program,programTitle,projectId,routed,status,title,workspace" {
		t.Errorf("keys %s", got)
	}
	// A sees B's terminal and the Mac's, never its own.
	if seen := f.others(t, f.a); len(seen) != 2 || seen[own.ID].DeviceName != "iPad" || seen["term_mac"].ID == "" {
		t.Fatalf("A's others %+v", seen)
	}
}

func TestOthersOrderedByLatestActivity(t *testing.T) {
	f := newSharedFixture(t)
	first := createTerminalFixture(t, f.host, f.a)
	f.clock.Advance(time.Second)
	second := createTerminalFixture(t, f.host, f.a)
	f.clock.Advance(time.Second)
	third := createTerminalFixture(t, f.host, f.a)
	order := func() []string {
		t.Helper()
		list, _ := f.othersList(t, f.b)
		ids := make([]string, len(list))
		for index, terminal := range list {
			ids[index] = terminal.ID
		}
		return ids
	}
	// The Mac's agent started an hour before the fixture's clock.
	if got, want := order(), []string{third.ID, second.ID, first.ID, "term_mac"}; !slices.Equal(got, want) {
		t.Fatalf("by start: %v, want %v", got, want)
	}
	f.clock.Advance(time.Second)
	f.keeper.emit(first.ID, "output")
	waitFor(t, "the output", func() bool { return readTerminal(t, f.host, f.b, first.ID, 0).Cursor == 6 })
	if got, want := order(), []string{first.ID, third.ID, second.ID, "term_mac"}; !slices.Equal(got, want) {
		t.Fatalf("after output: %v, want %v", got, want)
	}
	f.clock.Advance(time.Second)
	if w := request(t, f.host.Handler(), "POST", "/v1/terminal/input", f.a, map[string]any{"projectId": "p1", "terminalId": second.ID, "data": []byte("x")}); w.Code != 200 {
		t.Fatalf("input: %d %s", w.Code, w.Body)
	}
	if got, want := order(), []string{second.ID, first.ID, third.ID, "term_mac"}; !slices.Equal(got, want) {
		t.Fatalf("after input: %v, want %v", got, want)
	}
	f.clock.Advance(time.Second)
	f.keeper.setLastInput("term_mac", f.clock.Now())
	if got, want := order(), []string{"term_mac", second.ID, first.ID, third.ID}; !slices.Equal(got, want) {
		t.Fatalf("after input in the Terminal window: %v, want %v", got, want)
	}
	// Terminals equally recent go by ID.
	f.clock.Advance(time.Second)
	tied := []string{createTerminalFixture(t, f.host, f.a).ID, createTerminalFixture(t, f.host, f.a).ID}
	slices.Sort(tied)
	if got := order(); !slices.Equal(got[:2], tied) {
		t.Fatalf("ties: %v, want %v first", got, tied)
	}
}

// Removing a device (the Mac app ends its terminals and revokes it) ends only
// that device's terminals; the Mac's are never a device's. The revoked device
// gets nothing from any shared route.
func TestRevokeStillEndsOnlyThatDevicesTerminals(t *testing.T) {
	f := newSharedFixture(t)
	a := createTerminalFixture(t, f.host, f.a)
	b := createTerminalFixture(t, f.host, f.b)
	f.keeper.emit(b.ID, "secret")
	waitFor(t, "B's output", func() bool { return readTerminal(t, f.host, f.b, b.ID, 0).Cursor == 6 })
	if code, body := macPost(t, f.host, "/v1/terminals/end-device", map[string]string{"deviceId": f.deviceA.ID}); code != 200 || strings.TrimSpace(body) != `{"ended":1}` {
		t.Fatalf("end-device: %d %s", code, body)
	}
	if err := f.store.RevokeDevice(f.deviceA.ID); err != nil {
		t.Fatal(err)
	}
	if ends := f.keeper.endedIDs(); !slices.Equal(ends, []string{a.ID}) || len(f.keeper.releasedIDs()) != 0 {
		t.Fatalf("ended %v released %v", ends, f.keeper.releasedIDs())
	}
	if entry := macEntry(f.host, "term_mac"); entry == nil || !entry.running() {
		t.Fatal("the Mac's agent did not stay running")
	}
	if terminalStatus(t, f.host, f.b, b.ID) != "running" {
		t.Fatal("B's terminal was touched")
	}
	checks := []struct {
		method, target string
		body           map[string]any
	}{
		{"GET", "/v1/terminals/others", nil},
		{"GET", "/v1/terminal/output?projectId=p1&terminalId=" + b.ID + "&cursor=0", nil},
		{"GET", "/v1/terminal/output?terminalId=term_mac&cursor=0", nil},
		{"POST", "/v1/terminal/input", map[string]any{"projectId": "p1", "terminalId": b.ID, "data": []byte("x")}},
		{"POST", "/v1/terminal/input", map[string]any{"terminalId": "term_mac", "data": []byte("x")}},
		{"POST", "/v1/terminal/resize", map[string]any{"terminalId": "term_mac", "rows": 10, "cols": 10}},
		{"POST", "/v1/terminal/title", map[string]any{"projectId": "p1", "terminalId": b.ID, "title": "Stolen", "basedOn": 1}},
		{"POST", "/v1/terminal/close", map[string]any{"projectId": "p1", "terminalId": b.ID}},
		{"POST", "/v1/terminal/close", map[string]any{"terminalId": "term_mac"}},
	}
	for _, check := range checks {
		var body any
		if check.body != nil {
			body = check.body
		}
		w := request(t, f.host.Handler(), check.method, check.target, f.a, body)
		if w.Code != http.StatusUnauthorized || bytes.Contains(w.Body.Bytes(), []byte("secret")) || bytes.Contains(w.Body.Bytes(), []byte(b.ID)) {
			t.Errorf("revoked %s %s: %d %s", check.method, check.target, w.Code, w.Body)
		}
	}
	if f.keeper.input(b.ID) != "" || f.keeper.input("term_mac") != "" || f.keeper.size() == [2]int{10, 10} || len(f.keeper.endedIDs()) != 1 {
		t.Fatal("a revoked device reached a terminal")
	}
	if _, info, _ := entryState(t, f.host, b.ID); info.ContextTitle == "Stolen" {
		t.Fatal("a revoked device named a terminal")
	}
}

// With terminal access off, the shared routes answer 403 like every terminal
// route, before any terminal is looked at.
func TestOthersRefusedWhileTerminalAccessIsOff(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, false)
	for _, check := range []struct {
		method, target string
		body           any
	}{
		{"GET", "/v1/terminals/others", nil},
		{"GET", "/v1/terminals?projectId=p1", nil},
		{"POST", "/v1/terminals", map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80}},
		{"GET", "/v1/terminal/output?terminalId=term_x&cursor=0", nil},
		{"POST", "/v1/terminal/input", map[string]any{"terminalId": "term_x", "data": []byte("x")}},
		{"POST", "/v1/terminal/resize", map[string]any{"terminalId": "term_x", "rows": 10, "cols": 10}},
		{"POST", "/v1/terminal/title", map[string]any{"terminalId": "term_x", "title": "Name", "basedOn": 1}},
		{"POST", "/v1/terminal/close", map[string]any{"terminalId": "term_x"}},
	} {
		w := request(t, host.Handler(), check.method, check.target, token, check.body)
		if w.Code != 403 || errorCode(t, w) != "terminal_disabled" {
			t.Errorf("%s %s with terminals off: %d %s", check.method, check.target, w.Code, w.Body)
		}
	}
	if fixture.spawnCount() != 0 {
		t.Fatal("spawned with terminals off")
	}
	on, _, _, _ := terminalTestHost(t, true)
	if w := request(t, on.Handler(), "GET", "/v1/terminals/others", "", nil); w.Code != 401 || errorCode(t, w) != "unauthorized" {
		t.Errorf("unauthenticated: %d %s", w.Code, w.Body)
	}
}

// The cap counts the Mac's routed agents too, and says so.
func TestTheLimitTextCountsTerminalWindows(t *testing.T) {
	f := newSharedFixture(t)
	for range terminalCapacity - 1 {
		createTerminalFixture(t, f.host, f.a)
	}
	w := request(t, f.host.Handler(), "POST", "/v1/terminals", f.b, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	want := fmt.Sprintf(`{"error":{"code":"terminal_limit","message":%q}}`, "16 terminals are open on this Mac across all your devices and Terminal windows, including finished ones that haven't been closed. Close one, or end or clear one in AgentLand on the Mac (Settings → Terminals).")
	if w.Code != http.StatusTooManyRequests || strings.TrimSpace(w.Body.String()) != want {
		t.Fatalf("cap: %d %s", w.Code, w.Body)
	}
}

func TestOthersDisplayFolder(t *testing.T) {
	for _, c := range []struct{ folder, home, want string }{
		{"/Users/me/code/app", "/Users/me", "~/code/app"},
		{"/Users/me", "/Users/me", "~"},
		{"/Users/me", "/Users/me/", "~"},
		{"/Users/meadow/app", "/Users/me", "/Users/meadow/app"},
		{"/opt/app", "/Users/me", "/opt/app"},
		{"/Users/me/app", "", "/Users/me/app"},
		{"/app", "/", "/app"},
	} {
		if got := displayFolder(c.folder, c.home); got != c.want {
			t.Errorf("displayFolder(%q, %q) = %q, want %q", c.folder, c.home, got, c.want)
		}
	}
}
