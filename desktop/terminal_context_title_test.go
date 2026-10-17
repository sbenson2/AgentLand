package host

import (
	"encoding/json"
	"testing"
	"time"
)

func TestTerminalContextTitleFreshnessAndArchive(t *testing.T) {
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{})
	info := createTerminalFixture(t, host, token)
	log := archive.openLogs()[0]
	fixture.emit(fixture.latest(), "first task\r\n")
	var cursor uint64
	waitFor(t, "output", func() bool {
		var output terminalOutput
		json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &output)
		cursor = output.Cursor
		return cursor > 0
	})
	rename := func(title string, basis uint64, expected int) {
		t.Helper()
		w := request(t, host.Handler(), "POST", "/v1/terminal/title", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "title": title, "basedOn": basis})
		if w.Code != expected {
			t.Fatalf("rename: %d %s", w.Code, w.Body)
		}
	}
	rename("Repair login redirect", cursor, 200)
	rename("Invalid future title", cursor+1000, 400)
	rename("", cursor, 400)
	// The program's newer title is its programTitle; the device's name stays
	// until a device names the terminal again, and a name of older output than
	// that one is stale.
	fixture.emit(fixture.latest(), "\x1b]2;Add login regression tests\x07")
	waitFor(t, "newer program title", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ProgramTitle == "Add login regression tests"
	})
	if list, _ := listTerminalsFixture(t, host, token); list[0].ContextTitle != "Repair login redirect" || list[0].ContextTitleSource != "device" {
		t.Fatalf("the program's title replaced the device's name: %+v", list[0])
	}
	var newer uint64
	waitFor(t, "newer output", func() bool {
		var output terminalOutput
		json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &output)
		newer = output.Cursor
		return newer > cursor
	})
	rename("Add login regression tests", newer, 200)
	rename("Stale repair title", cursor, 409)
	fixture.emit(fixture.latest(), "\x1b]2;Shell\x07")
	waitFor(t, "idle", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ProgramTitle == "" && list[0].ContextTitle == "Add login regression tests"
	})
	if w := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]string{"projectId": "p1", "terminalId": info.ID}); w.Code != 200 {
		t.Fatalf("close: %d", w.Code)
	}
	archiveEventually(t, "closed", func() bool { return archive.openLog(log.ID()) == nil })
	flushArchive(t, archive)
	stored, err := archive.ArchivedTerminalLog(t.Context(), log.ID())
	if err != nil || stored.Title != "Add login regression tests" || stored.Program != "shell" {
		t.Fatalf("saved title: %+v %v", stored, err)
	}
	// A late summary can update history without reopening or replaying the log.
	log.Rename("Login regression coverage")
	flushArchive(t, archive)
	stored, err = archive.ArchivedTerminalLog(t.Context(), log.ID())
	if err != nil || stored.Title != "Login regression coverage" || stored.Status != "exited" {
		t.Fatalf("final summary: %+v %v", stored, err)
	}
}

func TestRepeatedProgramTitleKeepsContextSummary(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	packet := []byte("\x1b]2;Fix login\x07")
	fixture.emit(fixture.latest(), string(packet))
	waitFor(t, "program title", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ContextTitle == "Fix login"
	})
	w := request(t, host.Handler(), "POST", "/v1/terminal/title", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "title": "Repair Safari login redirect", "basedOn": len(packet)})
	if w.Code != 200 {
		t.Fatalf("summary: %d %s", w.Code, w.Body)
	}
	fixture.emit(fixture.latest(), string(packet))
	waitFor(t, "repeated title read", func() bool {
		var out terminalOutput
		json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &out)
		return out.Cursor == uint64(2*len(packet))
	})
	list, _ := listTerminalsFixture(t, host, token)
	if list[0].ContextTitle != "Repair Safari login redirect" {
		t.Fatalf("repeat reverted summary: %+v", list[0])
	}
}

func TestTerminalContextTitleRequiresOwnerAndWorkspace(t *testing.T) {
	host, _, token, _ := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	for _, check := range []struct {
		token, project string
		code           int
	}{{"", "p1", 401}, {token, "missing", 404}} {
		w := request(t, host.Handler(), "POST", "/v1/terminal/title", check.token, map[string]any{"projectId": check.project, "terminalId": info.ID, "title": "Repair login redirect", "basedOn": 1})
		if w.Code != check.code {
			t.Fatalf("scope: %d %s", w.Code, w.Body)
		}
	}
}

// A rename waiting for room in a full archive queue holds up neither the
// terminal's routes nor its output.
func TestTerminalRenameWaitsOutsideTheTerminal(t *testing.T) {
	host, archive, fixture, token := archiveRouteHost(t, ArchiveOptions{BatchDelay: time.Hour})
	info := createTerminalFixture(t, host, token)
	cursorNow := func() uint64 {
		var output terminalOutput
		json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &output)
		return output.Cursor
	}
	fixture.emit(fixture.latest(), "first task\r\n")
	waitFor(t, "output", func() bool { return cursorNow() > 0 })
	cursor := cursorNow()
	archive.mu.Lock()
	for range archiveQueueCapacity {
		archive.pending = append(archive.pending, &archiveOp{apply: func(*archiveTx) error { return nil }})
	}
	archive.mu.Unlock()
	renamed := make(chan int, 1)
	go func() {
		w := request(t, host.Handler(), "POST", "/v1/terminal/title", token, map[string]any{"projectId": "p1", "terminalId": info.ID, "title": "Repair login redirect", "basedOn": cursor})
		renamed <- w.Code
	}()
	waitFor(t, "the description", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ContextTitle == "Repair login redirect"
	})
	started := time.Now()
	fixture.emit(fixture.latest(), "more\r\n")
	fixture.emit(fixture.latest(), "output\r\n")
	for cursorNow() < cursor+uint64(len("more\r\noutput\r\n")) {
		if time.Since(started) > time.Second {
			t.Fatal("output waited for the archive")
		}
		time.Sleep(10 * time.Millisecond)
	}
	select {
	case code := <-renamed:
		t.Fatalf("rename answered before the archive had room: %d", code)
	default:
	}
	archive.writePending()
	if code := <-renamed; code != 200 {
		t.Fatalf("rename: %d", code)
	}
}
