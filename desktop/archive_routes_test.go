package host

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// localRequest calls h as this Mac's own app: the local token over loopback.
func localRequest(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.RemoteAddr = "127.0.0.1:9000"
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func archiveEventually(t *testing.T, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// archiveRouteHost has terminals, the archive and this Mac's session token;
// its maintenance loop is stopped, so tests call maintain themselves.
func archiveRouteHost(t *testing.T, options ArchiveOptions) (*Host, *Archive, *terminalFixture, string) {
	t.Helper()
	_, store, agent := testHost(t)
	archive := testArchive(t, options)
	fixture := newTerminalFixture(agent)
	host := newHost(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, LocalSessionToken: routeLocalToken, Archive: archive, RemoteAccess: true, Agents: &AgentOptions{Version: "test"},
		Vault: &VaultOptions{DefaultFolder: filepath.Join(t.TempDir(), "AgentLand Vault")}})
	t.Cleanup(host.vault.close)
	fakeTerminalPrograms(host, false)
	// Agents: no command of the owner's is found and the registry is never
	// reached.
	quietAgents(host.agents, nil, nil, nil)
	t.Cleanup(host.agents.close)
	return host, archive, fixture, paired(t, host, store)
}

func decodeBody[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatalf("decode %s: %v", w.Body, err)
	}
	return value
}

func TestLocalOnlyRoutesAdmitOnlyThisMac(t *testing.T) {
	host, _, _, token := archiveRouteHost(t, ArchiveOptions{})
	local := 0
	for _, entry := range routes {
		if !entry.localOnly {
			continue
		}
		if strings.HasPrefix(entry.path, "/v1/local-web/") {
			continue
		}
		local++
		name := entry.method + " " + entry.path
		for label, w := range map[string]*httptest.ResponseRecorder{
			"a paired device":               request(t, host.Handler(), entry.method, entry.path, token, nil),
			"a paired device over loopback": localRequest(t, host.Handler(), entry.method, entry.path, token, nil),
		} {
			wantRouteError(t, name+" from "+label, w, 403, "local_only", "Only this Mac's AgentLand app can use this route")
		}
		wantRouteError(t, name+" with the Mac's token from the network", request(t, host.Handler(), entry.method, entry.path, routeLocalToken, nil), 401, "unauthorized", "Valid bearer authentication is required")
		// Notices: an acknowledgement names the notice it goes through.
		var body any
		if entry.method == "POST" && entry.path == "/v1/notices/ack" {
			body = map[string]int{"through": 0}
		}
		// Remote access: a report says whether the switch is on.
		if entry.method == "POST" && entry.path == "/v1/remote-access/endpoint" {
			body = map[string]bool{"enabled": false}
		}
		// Agents: a report names the OpenCode version that did not start.
		if entry.method == "POST" && entry.path == "/v1/agents/opencode/failed" {
			body = map[string]string{"version": "1.18.33"}
		}
		// Vault: a change names a setting, and a vault that is off cannot
		// be rebuilt.
		want := 200
		if entry.method == "POST" && entry.path == "/v1/vault/settings" {
			body = map[string]bool{"enabled": false}
		}
		if entry.method == "POST" && entry.path == "/v1/vault/rebuild" {
			want = 409
		}
		// Chat's sign-ins: this host runs no Claude Code or Codex chats.
		if entry.method == "POST" && entry.path == "/v1/chat/providers/check" {
			want = 404
		}
		// Terminals: the Mac-only routes name a terminal or a device.
		switch entry.path {
		case "/v1/terminals/end", "/v1/terminals/clear":
			body, want = map[string]string{"terminalId": "missing"}, 404
		case "/v1/terminals/end-device":
			body = map[string]string{"deviceId": "missing"}
		}
		if w := localRequest(t, host.Handler(), entry.method, entry.path, routeLocalToken, body); w.Code != want {
			t.Errorf("%s from this Mac: %d %s", name, w.Code, w.Body)
		}
	}
	if local == 0 {
		t.Fatal("no local-only routes to check")
	}
	// This Mac also uses the ordinary routes.
	if w := localRequest(t, host.Handler(), "GET", "/v1/archive/changes", routeLocalToken, nil); w.Code != 200 {
		t.Errorf("changes from this Mac: %d %s", w.Code, w.Body)
	}
}

// seedArchive writes a chat in the configured project p1 and one in a project
// that is no longer configured, each with a message and a terminal log.
func seedArchive(t *testing.T, archive *Archive) (visibleLog, hiddenLog string) {
	t.Helper()
	mustArchiveChat(t, archive, "c1", "p1", "Fix the build")
	mustArchiveMessage(t, archive, textMessage("c1", "m1", "user", 0, "shared secret word"))
	mustArchiveChat(t, archive, "c9", "gone", "Removed project")
	mustArchiveMessage(t, archive, textMessage("c9", "m9", "user", 0, "shared secret word elsewhere"))
	for _, project := range []string{"p1", "gone"} {
		log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: project, OwnerDeviceID: "d1", Title: "Shell", Program: "shell"})
		if err != nil {
			t.Fatal(err)
		}
		log.Append([]byte("output of " + project))
		log.Close("exited", nil)
		if project == "p1" {
			visibleLog = log.ID()
		} else {
			hiddenLog = log.ID()
		}
	}
	flushArchive(t, archive)
	return visibleLog, hiddenLog
}

func TestArchiveRoutesServeOnlyConfiguredProjects(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{Now: func() time.Time { return archiveTestStart }})
	visibleLog, hiddenLog := seedArchive(t, archive)
	get := func(target string) *httptest.ResponseRecorder {
		return request(t, host.Handler(), "GET", target, token, nil)
	}

	w := get("/v1/archive/chat?chatId=c1")
	page := decodeBody[ArchiveChatPage](t, w)
	if w.Code != 200 || page.Chat.Title != "Fix the build" || len(page.Messages) != 1 || page.Messages[0].Parts[0].Text != "shared secret word" {
		t.Fatalf("visible chat: %d %s", w.Code, w.Body)
	}
	for _, check := range []struct {
		method, target string
		body           any
		message        string
	}{
		{"GET", "/v1/archive/chat?chatId=c9", nil, "Archived chat not found"},
		{"GET", "/v1/archive/export?chatId=c9&format=json", nil, "Archived chat not found"},
		{"POST", "/v1/archive/delete", map[string]string{"kind": "chat", "id": "c9"}, "Archived chat not found"},
		{"GET", "/v1/archive/terminal-log?id=" + hiddenLog, nil, "Terminal log not found"},
		{"POST", "/v1/archive/delete", map[string]string{"kind": "terminalLog", "id": hiddenLog}, "Terminal log not found"},
		{"GET", "/v1/archive/terminal-logs?projectId=gone", nil, "Project not found"},
		{"GET", "/v1/archive/search?q=secret&projectId=gone", nil, "Project not found"},
	} {
		wantRouteError(t, check.method+" "+check.target, request(t, host.Handler(), check.method, check.target, token, check.body), 404, "not_found", check.message)
	}

	search := decodeBody[ArchiveSearchPage](t, get("/v1/archive/search?q=secret"))
	if len(search.Results) != 1 || search.Results[0].ChatID != "c1" || !strings.Contains(search.Results[0].Snippet, "\x02secret\x03") {
		t.Fatalf("search %+v", search)
	}
	changes := decodeBody[ArchiveChanges](t, get("/v1/archive/changes"))
	if got := strings.Join(changeNames(t, changes), " "); got != "chat:c1:upsert message:m1:upsert terminalLog:"+visibleLog+":upsert" {
		t.Fatalf("changes: %s", got)
	}
	logs := decodeBody[ArchiveTerminalLogPage](t, get("/v1/archive/terminal-logs"))
	if len(logs.Logs) != 1 || logs.Logs[0].ID != visibleLog || logs.Logs[0].Status != "exited" || logs.Logs[0].Bytes != int64(len("output of p1")) {
		t.Fatalf("terminal logs %+v", logs)
	}

	// This Mac sees the hidden chat counted in stats and in the whole export.
	stats := decodeBody[ArchiveStats](t, localRequest(t, host.Handler(), "GET", "/v1/archive/stats", routeLocalToken, nil))
	if stats.Chats != 2 || stats.HiddenChats != 1 || stats.Messages != 2 || stats.TerminalLogs != 2 || stats.SchemaVersion != len(archiveMigrations) || stats.CapturePaused || stats.ChatCapturePaused {
		t.Fatalf("stats %+v", stats)
	}
	wantRouteError(t, "whole export from a device", get("/v1/archive/export?format=jsonl"), 403, "local_only", "Only this Mac's AgentLand app can export the whole archive")
	w = localRequest(t, host.Handler(), "GET", "/v1/archive/export?format=jsonl", routeLocalToken, nil)
	lines := strings.Split(strings.TrimSpace(w.Body.String()), "\n")
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/x-ndjson" || !strings.Contains(w.Body.String(), `"id":"c9"`) ||
		lines[len(lines)-1] != `{"type":"end","chats":2,"messages":2,"terminalLogs":2}` ||
		w.Header().Get("Content-Disposition") != `attachment; filename=agentland-archive-`+time.Now().UTC().Format("2006-01-02")+`.jsonl` {
		t.Fatalf("whole export: %d %v\n%s", w.Code, w.Header(), w.Body)
	}
}

func TestArchiveExportRouteStreamsAnAttachment(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{Now: func() time.Time { return archiveTestStart }})
	seedArchive(t, archive)
	for _, check := range []struct {
		target, contentType, filename, start string
	}{
		{"/v1/archive/export?chatId=c1", "text/markdown; charset=utf-8", "Fix-the-build.md", "# Fix the build\n"},
		{"/v1/archive/export?chatId=c1&format=json", "application/json", "Fix-the-build.json", `{"format":"agentland.chat","version":1,`},
		{"/v1/archive/export?chatId=c1&format=jsonl", "application/x-ndjson", "Fix-the-build.jsonl", `{"type":"chat","chat":{"id":"c1"`},
	} {
		w := request(t, host.Handler(), "GET", check.target, token, nil)
		if w.Code != 200 || w.Header().Get("Content-Type") != check.contentType || w.Header().Get("Cache-Control") != "no-store" ||
			w.Header().Get("Content-Disposition") != "attachment; filename="+check.filename || !strings.HasPrefix(w.Body.String(), check.start) {
			t.Errorf("%s: %d %v\n%s", check.target, w.Code, w.Header(), w.Body)
		}
	}
	var exported map[string]any
	if err := json.Unmarshal(request(t, host.Handler(), "GET", "/v1/archive/export?chatId=c1&format=json", token, nil).Body.Bytes(), &exported); err != nil {
		t.Fatalf("JSON export does not parse: %v", err)
	}
	wantRouteError(t, "JSON without a chat", request(t, host.Handler(), "GET", "/v1/archive/export?format=json", token, nil), 400, "invalid_request", "Choose a chat to export as Markdown or JSON")
	if name := archiveFilename("Überprüfung: «build» / 2026", "chat"); name != "Überprüfung-build-2026" {
		t.Errorf("filename %q", name)
	}
	if name := archiveFilename("../..", "chat"); name != "chat" {
		t.Errorf("filename %q", name)
	}
}

func TestArchiveDeleteRouteLeavesTombstones(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{})
	visibleLog, _ := seedArchive(t, archive)
	before := decodeBody[ArchiveChanges](t, request(t, host.Handler(), "GET", "/v1/archive/changes", token, nil))
	w := request(t, host.Handler(), "POST", "/v1/archive/delete", token, map[string]string{"kind": "chat", "id": "c1"})
	if w.Code != 200 || w.Body.String() != `{"deleted":true}`+"\n" {
		t.Fatalf("delete chat: %d %s", w.Code, w.Body)
	}
	wantRouteError(t, "deleted chat", request(t, host.Handler(), "GET", "/v1/archive/chat?chatId=c1", token, nil), 404, "not_found", "Archived chat not found")
	wantRouteError(t, "delete again", request(t, host.Handler(), "POST", "/v1/archive/delete", token, map[string]string{"kind": "chat", "id": "c1"}), 404, "not_found", "Archived chat not found")

	running, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: "p1", Title: "Busy"})
	if err != nil {
		t.Fatal(err)
	}
	wantRouteError(t, "running log", request(t, host.Handler(), "POST", "/v1/archive/delete", token, map[string]string{"kind": "terminalLog", "id": running.ID()}), 409, "terminal_running", "End the terminal before deleting its log")
	running.Close("exited", nil)
	log, err := archive.ArchivedTerminalLog(t.Context(), visibleLog)
	if err != nil {
		t.Fatal(err)
	}
	path, _ := archive.terminalLogPath(log.file)
	if w := request(t, host.Handler(), "POST", "/v1/archive/delete", token, map[string]string{"kind": "terminalLog", "id": visibleLog}); w.Code != 200 {
		t.Fatalf("delete log: %d %s", w.Code, w.Body)
	}
	if _, err := archive.ArchivedTerminalLog(t.Context(), visibleLog); err == nil {
		t.Fatal("deleted log still listed")
	}
	archiveEventually(t, "the log file to be removed", func() bool { return !fileExists(path) })
	after := decodeBody[ArchiveChanges](t, request(t, host.Handler(), "GET", "/v1/archive/changes?after="+before.Cursor, token, nil))
	if got := strings.Join(changeNames(t, after), " "); got != "chat:c1:delete terminalLog:"+running.ID()+":upsert terminalLog:"+visibleLog+":delete" {
		t.Fatalf("changes after deletes: %s", got)
	}
	for _, body := range []any{map[string]string{"kind": "file", "id": "x"}, map[string]any{"kind": "chat", "id": "c1", "force": true}} {
		if w := request(t, host.Handler(), "POST", "/v1/archive/delete", token, body); w.Code != 400 {
			t.Errorf("delete %v: %d %s", body, w.Code, w.Body)
		}
	}
}

// The change feed long-polls: with wait and nothing after the cursor, the
// request waits for the next change of a configured project, answers the
// empty page when the wait ends, and ends at once when the host stops.
func TestArchiveChangesLongPoll(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{})
	seedArchive(t, archive)
	get := func(target string) *httptest.ResponseRecorder {
		return request(t, host.Handler(), "GET", target, token, nil)
	}
	for _, target := range []string{"/v1/archive/changes?wait=20001", "/v1/archive/changes?wait=-1", "/v1/archive/changes?wait=soon"} {
		wantRouteError(t, target, get(target), 400, "invalid_request", "wait must be between 0 and 20000 milliseconds")
	}
	caughtUp := decodeBody[ArchiveChanges](t, get("/v1/archive/changes"))
	poll := func(query string) (chan ArchiveChanges, time.Time) {
		done := make(chan ArchiveChanges, 1)
		started := time.Now()
		go func() {
			var page ArchiveChanges
			w := get("/v1/archive/changes?" + query)
			if w.Code == 200 {
				json.Unmarshal(w.Body.Bytes(), &page)
			}
			done <- page
		}()
		return done, started
	}
	answer := func(label string, done chan ArchiveChanges) ArchiveChanges {
		t.Helper()
		select {
		case page := <-done:
			return page
		case <-time.After(10 * time.Second):
			t.Fatalf("%s: the poll did not answer", label)
			return ArchiveChanges{}
		}
	}

	// Without wait an empty page answers at once, as before.
	started := time.Now()
	if page := decodeBody[ArchiveChanges](t, get("/v1/archive/changes?after="+caughtUp.Cursor)); len(page.Changes) != 0 || page.Cursor != caughtUp.Cursor || time.Since(started) > time.Second {
		t.Fatalf("no wait: %+v after %v", page, time.Since(started))
	}

	// A new change wakes a waiting poll.
	done, started := poll("wait=20000&after=" + caughtUp.Cursor)
	time.Sleep(100 * time.Millisecond)
	mustArchiveMessage(t, archive, textMessage("c1", "m2", "assistant", 1, "a reply"))
	woken := answer("woken", done)
	if got := strings.Join(changeNames(t, woken), " "); got != "message:m2:upsert" || woken.Resync || time.Since(started) > 5*time.Second {
		t.Fatalf("woken poll: %s %+v after %v", got, woken, time.Since(started))
	}

	// A change in a project the feed leaves out does not end the wait; the
	// wait's end answers the empty page at the same position.
	done, started = poll("wait=400&after=" + woken.Cursor)
	time.Sleep(100 * time.Millisecond)
	mustArchiveMessage(t, archive, textMessage("c9", "m10", "user", 1, "elsewhere"))
	expired := answer("expired", done)
	if len(expired.Changes) != 0 || expired.Resync || expired.HasMore || time.Since(started) < 400*time.Millisecond {
		t.Fatalf("expired poll: %s after %v", strings.Join(changeNames(t, expired), " "), time.Since(started))
	}
	if again := decodeBody[ArchiveChanges](t, get("/v1/archive/changes?after="+expired.Cursor)); len(again.Changes) != 0 {
		t.Fatalf("the expired cursor skipped nothing: %s", strings.Join(changeNames(t, again), " "))
	}

	// A cursor of another epoch answers its resync at once.
	started = time.Now()
	if resync := decodeBody[ArchiveChanges](t, get("/v1/archive/changes?wait=20000&after=elsewhere.3")); !resync.Resync || len(resync.Changes) == 0 || time.Since(started) > 5*time.Second {
		t.Fatalf("resync: %+v after %v", resync, time.Since(started))
	}

	// Shutdown ends a waiting poll promptly with the empty page.
	done, started = poll("wait=20000&after=" + expired.Cursor)
	time.Sleep(100 * time.Millisecond)
	host.BeginShutdown()
	if stopped := answer("stopping", done); len(stopped.Changes) != 0 || stopped.Cursor != expired.Cursor || time.Since(started) > 5*time.Second {
		t.Fatalf("poll during shutdown: %+v after %v", stopped, time.Since(started))
	}
	// Once stopping, a poll does not wait at all.
	started = time.Now()
	if page := decodeBody[ArchiveChanges](t, get("/v1/archive/changes?wait=20000&after="+expired.Cursor)); len(page.Changes) != 0 || time.Since(started) > 5*time.Second {
		t.Fatalf("poll after shutdown began: %+v after %v", page, time.Since(started))
	}
}

// A long-poll outlasts the listener's timeouts over HTTP/1.1, scaled down
// here: it extends its connection's deadlines. Without that, the write
// timeout closes the connection before the answer (an EOF for the client).
func TestArchiveChangesLongPollOutlivesTheServerTimeoutsOverHTTP1(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{})
	seedArchive(t, archive)
	caughtUp := decodeBody[ArchiveChanges](t, request(t, host.Handler(), "GET", "/v1/archive/changes", token, nil))
	scaled := serverTimeouts{readHeader: 300 * time.Millisecond, read: 300 * time.Millisecond, write: 300 * time.Millisecond, idle: 5 * time.Second}
	base := serveHTTP1(t, host.Handler(), newHTTPServer(nil, "", scaled))
	transport := &http.Transport{ForceAttemptHTTP2: false, TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{}}
	defer transport.CloseIdleConnections()
	poll, _ := http.NewRequest("GET", base+"/v1/archive/changes?wait=1200&after="+caughtUp.Cursor, nil)
	poll.Header.Set("Authorization", "Bearer "+token)
	started := time.Now()
	response, err := (&http.Client{Transport: transport}).Do(poll)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	var page ArchiveChanges
	if err != nil || response.StatusCode != 200 || response.ProtoMajor != 1 || json.Unmarshal(body, &page) != nil || page.Cursor != caughtUp.Cursor ||
		time.Since(started) < 1200*time.Millisecond {
		t.Fatalf("long-poll over HTTP/1.1: %d %q after %v (%v)", response.StatusCode, body, time.Since(started), err)
	}
}

func TestArchiveRoutesValidateInput(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{})
	visibleLog, _ := seedArchive(t, archive)
	for _, check := range []struct {
		target, code, message string
	}{
		{"/v1/archive/search?q=" + strings.Repeat("a", 257), "invalid_request", "Search text is limited to 256 bytes"},
		{"/v1/archive/search?q=%20%20", "invalid_request", "Enter text to search for"},
		{"/v1/archive/search?q=a&limit=51", "invalid_request", "Limit must be between 1 and 50"},
		{"/v1/archive/search?q=a&from=yesterday", "invalid_request", "Dates must be RFC 3339 timestamps"},
		{"/v1/archive/search?q=a&cursor=nope", "invalid_cursor", "The search cursor is not valid"},
		{"/v1/archive/changes?limit=201", "invalid_request", "Limit must be between 1 and 200"},
		{"/v1/archive/changes?after=nope", "invalid_cursor", "The archive cursor is not valid"},
		{"/v1/archive/chat?chatId=c1&before=missing", "invalid_request", "The message to page before is not in this chat"},
		{"/v1/archive/terminal-logs?after=nope", "invalid_cursor", "The terminal log cursor is not valid"},
		{"/v1/archive/terminal-log?id=" + visibleLog + "&length=1048577", "invalid_request", "Length must be between 1 and 1048576 bytes"},
		{"/v1/archive/terminal-log?id=" + visibleLog + "&offset=-1", "invalid_request", "Offset must be a nonnegative number of bytes"},
		{"/v1/archive/terminal-log?id=" + visibleLog + "&format=html", "invalid_request", "Choose raw or text"},
		{"/v1/archive/terminal-log?id=" + visibleLog + "&offset=999", "invalid_range", "The offset is past the end of the terminal log"},
	} {
		wantRouteError(t, check.target, request(t, host.Handler(), "GET", check.target, token, nil), 400, check.code, check.message)
	}
}

func TestArchiveRoutesWithoutAnArchive(t *testing.T) {
	host, store, _ := testHost(t)
	token := paired(t, host, store)
	for _, entry := range routes {
		if !strings.HasPrefix(entry.path, "/v1/archive/") || entry.localOnly {
			continue
		}
		var body any
		if entry.method == "POST" {
			body = map[string]string{"kind": "chat", "id": "c1"}
		}
		wantRouteError(t, entry.path, request(t, host.Handler(), entry.method, entry.path, token, body), 501, "archive_unavailable", "This host does not keep an archive")
	}
	caps := request(t, host.Handler(), "GET", "/v1/capabilities", token, nil)
	if strings.Contains(caps.Body.String(), "archive") {
		t.Fatalf("capabilities without an archive: %s", caps.Body)
	}
}

func TestArchiveTerminalLogRouteReadsRawAndTextRanges(t *testing.T) {
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{})
	log, err := archive.OpenTerminalLog(TerminalLogInfo{ProjectID: "p1", Title: "Colors"})
	if err != nil {
		t.Fatal(err)
	}
	raw := "abc\x1b[31mdef\x1b[0m\r"
	log.Append([]byte(raw))
	read := func(query string) archiveTerminalRangeJSON {
		t.Helper()
		w := request(t, host.Handler(), "GET", "/v1/archive/terminal-log?id="+log.ID()+query, token, nil)
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", query, w.Code, w.Body)
		}
		return decodeBody[archiveTerminalRangeJSON](t, w)
	}
	// A running terminal's buffered output is written before the read.
	running := read("")
	data, _ := base64.StdEncoding.DecodeString(running.Data.(string))
	if string(data) != raw || running.EOF || running.Status != "running" || running.Next != int64(len(raw)) || running.Size != int64(len(raw)) {
		t.Fatalf("running read %+v %q", running, data)
	}
	// While it runs, a trailing CR waits for the next range.
	if text := read("&format=text&offset=8"); text.Data != "def" || text.Next != 15 || text.EOF {
		t.Fatalf("running text %+v", text)
	}
	log.Close("exited", nil)
	flushArchive(t, archive)
	// A range that ends inside an escape sequence stops before it.
	first := read("&format=text&length=6")
	if first.Data != "abc" || first.Next != 3 || first.EOF {
		t.Fatalf("first text range %+v", first)
	}
	rest := read("&format=text&offset=3")
	if rest.Data != "def\n" || rest.Next != int64(len(raw)) || !rest.EOF || rest.Status != "exited" {
		t.Fatalf("rest %+v", rest)
	}
	if end := read("&offset=16"); end.Data != "" || !end.EOF || end.Next != 16 {
		t.Fatalf("read at the end %+v", end)
	}
}
