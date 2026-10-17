package host

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"agentland/host/keeper"
)

var macTerminalRoutes = []routeKey{
	{"GET", "/v1/terminals/running"},
	{"POST", "/v1/terminals/end-all"},
	{"GET", "/v1/terminals/all"},
	{"POST", "/v1/terminals/end"},
	{"POST", "/v1/terminals/clear"},
	{"POST", "/v1/terminals/end-device"},
}

// macHost is a host with two paired devices, A ("Phone") and B ("iPad"), the
// archive and this Mac's session.
func macHost(t *testing.T) (*Host, *Archive, *terminalFixture, [2]string) {
	t.Helper()
	host, archive, fixture, tokenA := archiveRouteHost(t, ArchiveOptions{})
	tokenB := pairedAs(t, host, host.store, "iPad")
	return host, archive, fixture, [2]string{tokenA, tokenB}
}

func pairedAs(t *testing.T, h *Host, store *Store, name string) string {
	t.Helper()
	code, err := store.CreatePairingCode(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	w := request(t, h.Handler(), "POST", "/v1/pair", "", map[string]any{"code": code, "deviceName": name})
	if w.Code != 200 {
		t.Fatalf("pair: %d %s", w.Code, w.Body)
	}
	return decodeBody[struct {
		Token string `json:"token"`
	}](t, w).Token
}

type macList struct {
	Keeper struct {
		State  string `json:"state"`
		Reason string `json:"reason"`
		Adopts *bool  `json:"adopts"`
	} `json:"keeper"`
	Terminals []macTerminal `json:"terminals"`
}

func macAll(t *testing.T, host *Host) macList {
	t.Helper()
	w := localRequest(t, host.Handler(), "GET", "/v1/terminals/all", routeLocalToken, nil)
	if w.Code != 200 {
		t.Fatalf("all: %d %s", w.Code, w.Body)
	}
	return decodeBody[macList](t, w)
}

func macPost(t *testing.T, host *Host, path string, body any) (int, string) {
	t.Helper()
	w := localRequest(t, host.Handler(), "POST", path, routeLocalToken, body)
	return w.Code, w.Body.String()
}

func macEntry(host *Host, id string) *terminalEntry {
	host.terminals.mu.Lock()
	defer host.terminals.mu.Unlock()
	return host.terminals.entries[id]
}

func TestMacRoutesAreRefusedToDevicesAndTheTunnel(t *testing.T) {
	host, _, _, tokens := macHost(t)
	for _, key := range macTerminalRoutes {
		route, known := routeIndex[key]
		if !known || !route.localOnly || !route.notTunnel {
			t.Errorf("%v: known=%v route=%+v", key, known, route)
			continue
		}
		w := request(t, host.Handler(), key.method, key.path, tokens[0], map[string]string{})
		wantRouteError(t, key.method+" "+key.path+" from a device", w, 403, "local_only", "Only this Mac's AgentLand app can use this route")
		w = requestFrom(t, host, key.method, key.path, tokens[0], map[string]string{}, &tunnelPeer{nodeID: "node", deviceID: "device"})
		if w.Code != 403 || errorCode(t, w) != "tunnel_refused" {
			t.Errorf("%v through the tunnel: %d %s", key, w.Code, w.Body)
		}
		if webAllowed(key.path, key.method) {
			t.Errorf("%v is allowed to the web app", key)
		}
	}
}

func TestMacListShowsEveryDevicesTerminals(t *testing.T) {
	host, _, _, tokens := macHost(t)
	a := createTerminalFixture(t, host, tokens[0])
	b := createTerminalFixture(t, host, tokens[1])
	list := macAll(t, host)
	if list.Keeper.State != "running" || len(list.Terminals) != 2 {
		t.Fatalf("list %+v", list)
	}
	byID := map[string]macTerminal{}
	for _, terminal := range list.Terminals {
		byID[terminal.ID] = terminal
	}
	first, second := byID[a.ID], byID[b.ID]
	if first.DeviceName != "Phone" || second.DeviceName != "iPad" || first.DeviceRemoved || first.Status != "running" || first.Program != "shell" ||
		first.ProjectID != "p1" || first.Workspace == "" || first.Title != "Shell" || first.StartedAt == "" || first.EndedAt != "" || first.Reason != "" {
		t.Fatalf("terminals %+v %+v", first, second)
	}
	if _, err := time.Parse(time.RFC3339, first.StartedAt); err != nil || !strings.HasSuffix(first.StartedAt, "Z") {
		t.Fatalf("startedAt %q", first.StartedAt)
	}
	if w := localRequest(t, host.Handler(), "GET", "/v1/terminals/running", routeLocalToken, nil); w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"running":2,"routed":0}` {
		t.Fatalf("running: %d %s", w.Code, w.Body)
	}
	if err := host.store.RevokeDevice(pairedDevice(t, host.store, tokens[0]).ID); err != nil {
		t.Fatal(err)
	}
	for _, terminal := range macAll(t, host).Terminals {
		if terminal.ID == a.ID && !terminal.DeviceRemoved {
			t.Fatalf("A's terminal after its device was removed: %+v", terminal)
		}
		if terminal.ID == b.ID && terminal.DeviceRemoved {
			t.Fatalf("B's terminal: %+v", terminal)
		}
	}
}

// The Mac app names every terminal from its output (HostTerminalNaming): the
// list gives each terminal's size as a device last set it, the cursor after
// its newest output and where its name came from.
func TestMacListGivesNamingTheSizeCursorAndNameSource(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	info := createTerminalFixture(t, host, tokens[0])
	listed := func() macTerminal {
		t.Helper()
		for _, terminal := range macAll(t, host).Terminals {
			if terminal.ID == info.ID {
				return terminal
			}
		}
		t.Fatalf("%s is not listed", info.ID)
		return macTerminal{}
	}
	if first := listed(); first.Rows != 24 || first.Cols != 80 || first.Cursor != 0 || first.ContextTitleSource != "" {
		t.Fatalf("created: %+v", first)
	}
	w := request(t, host.Handler(), "POST", "/v1/terminal/resize", tokens[1], map[string]any{"projectId": "p1", "terminalId": info.ID, "rows": 40, "cols": 100})
	if w.Code != 200 {
		t.Fatalf("resize: %d %s", w.Code, w.Body)
	}
	fixture.emit(fixture.latest(), "fix the login redirect\r\n")
	var cursor uint64
	waitFor(t, "output", func() bool { cursor = listed().Cursor; return cursor > 0 })
	w = localRequest(t, host.Handler(), "POST", "/v1/terminal/title", routeLocalToken, map[string]any{"projectId": "p1", "terminalId": info.ID, "title": "Fix the login redirect", "basedOn": cursor})
	if w.Code != 200 {
		t.Fatalf("the Mac's name: %d %s", w.Code, w.Body)
	}
	if named := listed(); named.Rows != 40 || named.Cols != 100 || named.Title != "Fix the login redirect" || named.ContextTitleSource != "device" {
		t.Fatalf("named: %+v", named)
	}
	// A size the host has not seen (a restored terminal, a routed agent) is left out.
	entry := macEntry(host, info.ID)
	entry.mu.Lock()
	entry.rows, entry.cols = 0, 0
	entry.mu.Unlock()
	if raw := localRequest(t, host.Handler(), "GET", "/v1/terminals/all", routeLocalToken, nil).Body.String(); strings.Contains(raw, `"rows"`) || strings.Contains(raw, `"cols"`) {
		t.Fatalf("an unknown size is listed: %s", raw)
	}
}

func TestMacListSaysWhenTheKeeperIsNotThere(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	info := createTerminalFixture(t, host, tokens[0])
	host.terminals.setUnusable()
	list := macAll(t, host)
	if list.Keeper.State != "unavailable" || list.Keeper.Reason == "" || len(list.Terminals) != 1 {
		t.Fatalf("unusable: %+v", list)
	}
	for _, path := range []string{"/v1/terminals/end", "/v1/terminals/clear"} {
		if code, body := macPost(t, host, path, map[string]string{"terminalId": info.ID}); code != 503 || !strings.Contains(body, "terminals_unavailable") {
			t.Errorf("%s: %d %s", path, code, body)
		}
	}
	for _, path := range []string{"/v1/terminals/end-all", "/v1/terminals/end-device"} {
		if code, body := macPost(t, host, path, map[string]string{"deviceId": "x"}); code != 503 || !strings.Contains(body, "terminals_unavailable") {
			t.Errorf("%s: %d %s", path, code, body)
		}
	}
	host.terminals.setUsable()
	fixture.setStatus(KeeperNone)
	if list := macAll(t, host); list.Keeper.State != "none" {
		t.Fatalf("none: %+v", list)
	}
}

// The keeper's state says whether it can take coding agents typed in
// Terminal: a keeper from before adopt that holds terminals can't, until
// they end (Ruling 51). With no keeper, or one that can't be used, it says
// nothing.
func TestMacListSaysWhetherTheKeeperAdopts(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	createTerminalFixture(t, host, tokens[0])
	if list := macAll(t, host); list.Keeper.State != "running" || list.Keeper.Adopts == nil || !*list.Keeper.Adopts {
		t.Fatalf("this build's keeper: %+v", list.Keeper)
	}
	fixture.setFeatures(nil)
	if list := macAll(t, host); list.Keeper.State != "running" || list.Keeper.Adopts == nil || *list.Keeper.Adopts {
		t.Fatalf("a keeper from before adopt: %+v", list.Keeper)
	}
	if w := localRequest(t, host.Handler(), "GET", "/v1/terminals/all", routeLocalToken, nil); !strings.Contains(w.Body.String(), `"adopts":false`) {
		t.Fatalf("all: %s", w.Body)
	}
	fixture.setStatus(KeeperNone)
	if list := macAll(t, host); list.Keeper.State != "none" || list.Keeper.Adopts != nil {
		t.Fatalf("no keeper: %+v", list.Keeper)
	}
	fixture.setStatus(KeeperRunning)
	host.terminals.setUnusable()
	if list := macAll(t, host); list.Keeper.State != "unavailable" || list.Keeper.Adopts != nil {
		t.Fatalf("an unusable keeper: %+v", list.Keeper)
	}
}

func TestEndOnMacKeepsTheEndForTheDevice(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	info := createTerminalFixture(t, host, tokens[0])
	if code, body := macPost(t, host, "/v1/terminals/end", map[string]string{"terminalId": info.ID}); code != 200 || strings.TrimSpace(body) != `{"ended":true}` {
		t.Fatalf("end: %d %s", code, body)
	}
	output := waitForTerminalEnd(t, host, tokens[0], info.ID)
	if output.Ended == nil || output.Ended.Reason != "endedOnMac" {
		t.Fatalf("device read %+v %+v", output, output.Ended)
	}
	if len(fixture.forgottenIDs()) != 0 {
		t.Fatalf("forgot %v", fixture.forgottenIDs())
	}
	if code, body := macPost(t, host, "/v1/terminals/end", map[string]string{"terminalId": info.ID}); code != 409 || !strings.Contains(body, "terminal_not_running") {
		t.Fatalf("end again: %d %s", code, body)
	}
	if code, body := macPost(t, host, "/v1/terminals/end", map[string]string{"terminalId": "term_missing"}); code != 404 || !strings.Contains(body, "terminal_not_found") {
		t.Fatalf("end unknown: %d %s", code, body)
	}
}

func TestClearForgetsOnlyFinishedTerminals(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	running := createTerminalFixture(t, host, tokens[0])
	done := createTerminalFixture(t, host, tokens[0])
	fixture.exit(done.ID, 0)
	waitForTerminalEnd(t, host, tokens[0], done.ID)
	if code, body := macPost(t, host, "/v1/terminals/clear", map[string]string{"terminalId": running.ID}); code != 409 || !strings.Contains(body, "terminal_running") {
		t.Fatalf("clear running: %d %s", code, body)
	}
	if macEntry(host, running.ID) == nil || len(fixture.forgottenIDs()) != 0 {
		t.Fatal("a running terminal was touched")
	}
	if code, body := macPost(t, host, "/v1/terminals/clear", map[string]string{"terminalId": done.ID}); code != 200 || strings.TrimSpace(body) != `{"cleared":true}` {
		t.Fatalf("clear: %d %s", code, body)
	}
	if macEntry(host, done.ID) != nil || len(fixture.forgottenIDs()) != 1 || fixture.forgottenIDs()[0] != done.ID {
		t.Fatalf("after clear: entry=%v forgotten=%v", macEntry(host, done.ID), fixture.forgottenIDs())
	}
	if code, body := macPost(t, host, "/v1/terminals/clear", map[string]string{"terminalId": done.ID}); code != 404 {
		t.Fatalf("clear again: %d %s", code, body)
	}
}

// This Mac's terminals (routed agents, the browser's) are never ended as a
// removed device's: end-device refuses its ID.
func TestEndDeviceRefusesThisMac(t *testing.T) {
	host, _, fixture, _ := macHost(t)
	response := localRequest(t, host.Handler(), "POST", "/v1/terminals", routeLocalToken, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if response.Code != 201 {
		t.Fatalf("create: %d %s", response.Code, response.Body)
	}
	info := decodeBody[TerminalInfo](t, response)
	if entry := macEntry(host, info.ID); entry == nil || entry.owner != localMacDeviceID {
		t.Fatalf("the Mac's terminal: %+v", entry)
	}
	code, body := macPost(t, host, "/v1/terminals/end-device", map[string]string{"deviceId": localMacDeviceID})
	if code != 400 || !strings.Contains(body, `"invalid_request"`) {
		t.Fatalf("end-device for this Mac: %d %s", code, body)
	}
	if entry := macEntry(host, info.ID); entry == nil || !entry.running() || len(fixture.endedIDs()) != 0 || len(fixture.forgottenIDs()) != 0 {
		t.Fatalf("the Mac's terminal was ended: ends %v, forgets %v", fixture.endedIDs(), fixture.forgottenIDs())
	}
}

func TestEndDeviceEndsAndForgetsThatDevicesTerminals(t *testing.T) {
	host, archive, fixture, tokens := macHost(t)
	deviceA := pairedDevice(t, host.store, tokens[0])
	running := createTerminalFixture(t, host, tokens[0])
	done := createTerminalFixture(t, host, tokens[0])
	other := createTerminalFixture(t, host, tokens[1])
	fixture.exit(done.ID, 0)
	waitForTerminalEnd(t, host, tokens[0], done.ID)
	code, body := macPost(t, host, "/v1/terminals/end-device", map[string]string{"deviceId": deviceA.ID})
	if code != 200 || strings.TrimSpace(body) != `{"ended":1}` {
		t.Fatalf("end-device: %d %s", code, body)
	}
	if macEntry(host, running.ID) != nil || macEntry(host, done.ID) != nil || macEntry(host, other.ID) == nil {
		t.Fatal("wrong entries remain")
	}
	forgotten := fixture.forgottenIDs()
	if len(forgotten) != 2 || !(strings.Contains(strings.Join(forgotten, " "), running.ID) && strings.Contains(strings.Join(forgotten, " "), done.ID)) {
		t.Fatalf("forgotten %v", forgotten)
	}
	if stored := archivedEnd(t, archive, running.ID); stored.EndReason != "deviceRemoved" {
		t.Fatalf("archived %+v", stored)
	}
	if terminalStatus(t, host, tokens[1], other.ID) != "running" {
		t.Fatal("the other device's terminal was touched")
	}
}

func TestEndAllEndsEveryRunningTerminalAsHostStopped(t *testing.T) {
	host, archive, fixture, tokens := macHost(t)
	a := createTerminalFixture(t, host, tokens[0])
	b := createTerminalFixture(t, host, tokens[1])
	done := createTerminalFixture(t, host, tokens[1])
	fixture.exit(done.ID, 0)
	waitForTerminalEnd(t, host, tokens[1], done.ID)
	code, body := macPost(t, host, "/v1/terminals/end-all", map[string]string{})
	if code != 200 || strings.TrimSpace(body) != `{"ended":2,"released":0}` {
		t.Fatalf("end-all: %d %s", code, body)
	}
	for _, id := range []string{a.ID, b.ID} {
		entry := macEntry(host, id)
		if entry == nil || entry.running() {
			t.Fatalf("%s: %+v", id, entry)
		}
		if stored := archivedEnd(t, archive, id); stored.EndReason != "hostStopped" {
			t.Fatalf("%s archived %+v", id, stored)
		}
	}
	if len(fixture.forgottenIDs()) != 0 {
		t.Fatalf("end-all forgot %v", fixture.forgottenIDs())
	}
	if w := localRequest(t, host.Handler(), "GET", "/v1/terminals/running", routeLocalToken, nil); strings.TrimSpace(w.Body.String()) != `{"running":0,"routed":0}` {
		t.Fatalf("running after: %s", w.Body)
	}
}

func TestEndAllReturnsWithinItsBoundWhenTheKeeperHangs(t *testing.T) {
	saved := terminalEndAllWait
	terminalEndAllWait = 300 * time.Millisecond
	t.Cleanup(func() { terminalEndAllWait = saved })
	host, _, fixture, tokens := macHost(t)
	createTerminalFixture(t, host, tokens[0])
	block := make(chan struct{})
	fixture.mu.Lock()
	fixture.endBlock = block
	fixture.mu.Unlock()
	t.Cleanup(func() { close(block) })
	start := time.Now()
	code, body := macPost(t, host, "/v1/terminals/end-all", map[string]string{})
	if code != 200 || time.Since(start) > 3*time.Second || strings.TrimSpace(body) != `{"ended":0,"released":0}` {
		t.Fatalf("end-all with a hung keeper: %d %s after %v", code, body, time.Since(start))
	}
}

func TestFinishedTerminalsAreClearedAfterADay(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	running := createTerminalFixture(t, host, tokens[0])
	info := createTerminalFixture(t, host, tokens[0])
	fixture.emit(info.ID, "build output\r\n")
	waitFor(t, "the output", func() bool { return readTerminal(t, host, tokens[0], info.ID, 0).Cursor >= 14 })
	fixture.exit(info.ID, 0)
	waitForTerminalEnd(t, host, tokens[0], info.ID)
	endedAt := macEntry(host, info.ID).endedAt
	if host.terminals.clearFinished(endedAt.Add(24*time.Hour-time.Minute)) != 0 || len(macAll(t, host).Terminals) != 2 {
		t.Fatal("cleared at 23 h 59 min")
	}
	if host.terminals.clearFinished(endedAt.Add(24*time.Hour+time.Minute)) != 1 {
		t.Fatal("did not clear at 24 h 1 min")
	}
	if list := macAll(t, host); len(list.Terminals) != 1 || list.Terminals[0].ID != running.ID {
		t.Fatalf("after: %+v", list)
	}
	if forgotten := fixture.forgottenIDs(); len(forgotten) != 1 || forgotten[0] != info.ID {
		t.Fatalf("forgotten %v", forgotten)
	}
	// A running terminal is never cleared, however old.
	if host.terminals.clearFinished(time.Now().Add(1000*time.Hour)) != 0 || macEntry(host, running.ID) == nil {
		t.Fatal("cleared a running terminal")
	}
	w := outputFixture(t, host, tokens[0], info.ID, 0)
	body := decodeBody[terminalNotFoundBody](t, w)
	if w.Code != 404 || body.Error.Code != "terminal_not_found" || body.Error.Ended == nil || body.Error.Ended.Reason != "programExited" {
		t.Fatalf("device read: %d %s", w.Code, w.Body)
	}
	// Every paired device learns it (terminal_shared.go).
	other := outputFixture(t, host, tokens[1], info.ID, 0)
	if otherBody := decodeBody[terminalNotFoundBody](t, other); other.Code != 404 || otherBody.Error.Ended == nil || otherBody.Error.Ended.Reason != "programExited" {
		t.Fatalf("another device read: %d %s", other.Code, other.Body)
	}
	// The archive still has the output.
	flushArchive(t, host.archive)
	logs := terminalLogsOf(t, host.archive, info.ID)
	if len(logs) != 1 || logs[0].Bytes != 14 || logs[0].Status != "exited" {
		t.Fatalf("archive %+v", logs)
	}
}

func TestAFailedForgetKeepsTheEntryForTheNextTick(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	info := createTerminalFixture(t, host, tokens[0])
	fixture.exit(info.ID, 0)
	waitForTerminalEnd(t, host, tokens[0], info.ID)
	endedAt := macEntry(host, info.ID).endedAt
	later := endedAt.Add(25 * time.Hour)
	fixture.mu.Lock()
	fixture.forgetErr = fakeKeeperError(keeper.CodeBadRequest)
	fixture.mu.Unlock()
	if host.terminals.clearFinished(later) != 0 || macEntry(host, info.ID) == nil {
		t.Fatal("dropped an entry the keeper still holds")
	}
	fixture.mu.Lock()
	fixture.forgetErr = nil
	fixture.mu.Unlock()
	if host.terminals.clearFinished(later) != 1 || macEntry(host, info.ID) != nil {
		t.Fatal("did not clear on the next tick")
	}
}

func TestADayPassedWhileAwayClearsAtRestore(t *testing.T) {
	store, fixture, token, device := restoreFixture(t)
	archive := testArchive(t, ArchiveOptions{})
	fixture.addRunning(keptTerminal("term_old", shellRecord(device), 0), "old output\r\n")
	fixture.exit("term_old", 0)
	fixture.mu.Lock()
	fixture.terminals["term_old"].info.Exit.At = time.Now().Add(-25 * time.Hour)
	fixture.mu.Unlock()
	host := restoreHost(t, store, fixture, fixture, archive)
	if listed := listedTerminals(t, host, token); len(listed) != 0 {
		t.Fatalf("listed %+v", listed)
	}
	if forgotten := fixture.forgottenIDs(); len(forgotten) != 1 || forgotten[0] != "term_old" {
		t.Fatalf("forgotten %v", forgotten)
	}
	logs := terminalLogsOf(t, archive, "term_old")
	if len(logs) != 1 || logs[0].Status != "exited" || logs[0].Bytes != 12 {
		t.Fatalf("logs %+v", logs)
	}
}

func TestCapCountsEveryDeviceAndSaysWhere(t *testing.T) {
	host, _, _, tokens := macHost(t)
	for range terminalCapacity {
		createTerminalFixture(t, host, tokens[0])
	}
	w := request(t, host.Handler(), "POST", "/v1/terminals", tokens[1], map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if w.Code != http.StatusTooManyRequests || errorCode(t, w) != "terminal_limit" || !strings.Contains(w.Body.String(), "all your devices") || !strings.Contains(w.Body.String(), "Settings → Terminals") {
		t.Fatalf("cap: %d %s", w.Code, w.Body)
	}
}

func TestOnlyOpenCodeTerminalsDelayOpenCodeRestarts(t *testing.T) {
	host, _, _, tokens := macHost(t)
	fakeTerminalPrograms(host, true)
	createTerminalFixture(t, host, tokens[0])
	if host.anythingRuns() {
		t.Fatal("a running shell counts")
	}
	w := request(t, host.Handler(), "POST", "/v1/terminals", tokens[0], map[string]any{"projectId": "p1", "title": "OpenCode", "program": "opencode", "rows": 24, "cols": 80})
	if w.Code != 201 {
		t.Fatalf("opencode terminal: %d %s", w.Code, w.Body)
	}
	if !host.anythingRuns() {
		t.Fatal("a running opencode terminal does not count")
	}
}

func TestAMacOwnTerminalIsListedAsThisMac(t *testing.T) {
	host, _, _, _ := macHost(t)
	w := localRequest(t, host.Handler(), "POST", "/v1/terminals", routeLocalToken, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if w.Code != 201 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	list := macAll(t, host)
	if len(list.Terminals) != 1 || list.Terminals[0].DeviceName != "This Mac" || list.Terminals[0].DeviceRemoved {
		t.Fatalf("list %+v", list.Terminals)
	}
}

// With no keeper running, Forget answers errNoKeeper: the terminals are gone
// and clearing them must still work.
func TestClearsWorkWithNoKeeper(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	deviceA := pairedDevice(t, host.store, tokens[0])
	var ids []string
	for range terminalCapacity {
		ids = append(ids, createTerminalFixture(t, host, tokens[0]).ID)
	}
	fixture.setStatus(KeeperNone)
	for _, id := range ids {
		fixture.exit(id, 0)
		waitForTerminalEnd(t, host, tokens[0], id)
	}
	fixture.mu.Lock()
	fixture.forgetErr = errNoKeeper
	fixture.mu.Unlock()
	if code, body := macPost(t, host, "/v1/terminals/clear", map[string]string{"terminalId": ids[0]}); code != 200 {
		t.Fatalf("clear: %d %s", code, body)
	}
	endedAt := macEntry(host, ids[1]).endedAt
	if host.terminals.clearFinished(endedAt.Add(25*time.Hour)) != terminalCapacity-1 {
		t.Fatalf("one-day clear left %d", len(macAll(t, host).Terminals))
	}
	if code, body := macPost(t, host, "/v1/terminals/end-device", map[string]string{"deviceId": deviceA.ID}); code != 200 {
		t.Fatalf("end-device: %d %s", code, body)
	}
	if len(macAll(t, host).Terminals) != 0 {
		t.Fatal("entries remain")
	}
	fixture.setStatus(KeeperRunning)
	createTerminalFixture(t, host, tokens[0])
}

func TestAHungForgetDoesNotHoldUpClearingOrClose(t *testing.T) {
	host, _, fixture, tokens := macHost(t)
	info := createTerminalFixture(t, host, tokens[0])
	fixture.exit(info.ID, 0)
	waitForTerminalEnd(t, host, tokens[0], info.ID)
	fixture.mu.Lock()
	fixture.forgetBlock = make(chan struct{})
	fixture.mu.Unlock()
	endedAt := macEntry(host, info.ID).endedAt
	// A pass stops at its deadline.
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if host.terminals.clearFinishedWithin(ctx, endedAt.Add(25*time.Hour)) != 0 || time.Since(start) > 2*time.Second {
		t.Fatalf("pass took %v", time.Since(start))
	}
	// Close is not held by a pass in progress.
	host.terminals.now = func() time.Time { return endedAt.Add(25 * time.Hour) }
	host.startMaintenance(10 * time.Millisecond)
	time.Sleep(200 * time.Millisecond)
	closed := make(chan struct{})
	go func() { host.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("Close waited for a hung Forget")
	}
}
