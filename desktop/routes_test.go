package host

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// routeLocalToken is routeHost's session token for this Mac's own app.
const routeLocalToken = "route-local-session"

// routeHost enables terminals, the queue and the archive, keeps a Git
// repository with one file in the project and shortens the pulse, so each
// route answers from its own handler instead of a shared "feature disabled"
// error.
func routeHost(t *testing.T) (*Host, *Store, *terminalFixture, string) {
	t.Helper()
	_, store, agent := testHost(t)
	agent.messages = []Message{{ID: "m1", Role: "assistant", Text: "routed reply"}}
	directory := mustProject(t, store).Directory
	if err := os.WriteFile(filepath.Join(directory, "notes.txt"), []byte("routes"), 0600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("git", "init", "-q", directory).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, output)
	}
	queue, err := NewPromptQueue(filepath.Join(t.TempDir(), "queue.json"))
	if err != nil {
		t.Fatal(err)
	}
	fixture := newTerminalFixture(agent)
	// newHost leaves the queue dispatcher stopped, so a queued message stays queued.
	host := newHost(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, Queue: queue, LocalSessionToken: routeLocalToken, Archive: testArchive(t, ArchiveOptions{}), Preview: &PreviewOptions{Port: 9842, APIPort: 9841}, RemoteAccess: true, Agents: &AgentOptions{Version: "test"},
		Vault: &VaultOptions{DefaultFolder: filepath.Join(t.TempDir(), "AgentLand Vault")}})
	host.pulseFor = time.Millisecond
	// Terminals: no program of the owner's is found.
	fakeTerminalPrograms(host, false)
	// Agents: no command of the owner's is found and the registry is never
	// reached.
	quietAgents(host.agents, nil, nil, nil)
	t.Cleanup(host.agents.close)
	// Web previews: discovery lists one dev server.
	host.preview.discover = func(context.Context) ([]portListener, error) {
		return []portListener{{ip: net.IPv4(127, 0, 0, 1), port: 5173, process: "node", pid: 1}}, nil
	}
	t.Cleanup(host.StopPreviews)
	return host, store, fixture, paired(t, host, store)
}

// routeCheck is a request that only the handler it is routed to answers with
// this status and marker. Handlers share helpers (project and chat scoping,
// interaction and terminal lookups), so several requests fail a validation
// step that the handler runs before the shared helper.
type routeCheck struct {
	method, target string
	body           any
	status         int
	marker         string
}

func (c routeCheck) key() routeKey {
	path, _, _ := strings.Cut(c.target, "?")
	return routeKey{c.method, path}
}

// routeChecks has exactly one request per route, answered by a routeHost.
var routeChecks = []routeCheck{
	{"GET", "/v1/health", nil, 200, `{"protocolVersion":1,"status":"ok"}`},
	{"POST", "/v1/pair", map[string]string{"code": "wrong"}, 401, `"code":"invalid_pairing_code"`},

	{"GET", "/v1/capabilities", nil, 200, `{"chatFeatures":["reasoning","queue","parts","stop","continue","continueThrough","clientMessageId","title"],"chatProviders":["opencode"],"interactions":false,"terminal":true,"terminalPrograms":["shell"],"terminalFeatures":["title","keep","shared"],"archive":{"version":1,"features":["sync","search","export","terminalLogs","continue","continueThrough","changesWait","blobs"]},"files":["move","mkdir","upload",`},
	{"GET", "/v1/pulse", nil, 200, `{"type":"ready","intervalMs":1500}`},
	{"POST", "/v1/device/presence", map[string]any{}, 400, "Active state is required"},

	// Workspaces (workspaces.go).
	{"GET", "/v1/projects", nil, 200, `{"projects":[{"id":"p1","name":"Project","directory":"`},
	{"GET", "/v1/folders?path=relative", nil, 400, "Choose an absolute folder path to browse"},
	{"POST", "/v1/projects", map[string]string{"directory": "relative"}, 400, "Choose an absolute folder to add"},
	{"POST", "/v1/projects/create", map[string]string{"parentDirectory": "", "name": ".hidden"}, 400, "Name the new folder with 1 to 100 characters"},
	{"POST", "/v1/projects/rename", map[string]string{"id": "p1", "name": "a=b"}, 400, "Name the workspace with 1 to 100 characters"},
	{"POST", "/v1/projects/remove", map[string]string{"id": "p1"}, 409, `"code":"last_workspace"`},

	{"GET", "/v1/sessions?projectId=p1", nil, 200, `{"sessions":[{"id":"s1"`},
	{"POST", "/v1/sessions", map[string]string{"projectId": "p1", "title": "Routed"}, 201, `{"id":"new","title":"Routed"`},
	{"GET", "/v1/chat/options?projectId=p1", nil, 200, `{"models":[],"defaultModel":"","agents":[]}`},
	{"GET", "/v1/chat/status?projectId=p1&sessionId=s1", nil, 200, `{"state":"unknown"}`},
	{"GET", "/v1/messages?projectId=p1&sessionId=s1", nil, 200, `"text":"routed reply"`},
	{"POST", "/v1/messages", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "routed"}, 202, `{"accepted":true}`},
	{"POST", "/v1/messages/rewind", map[string]string{"projectId": "p1", "sessionId": "s1"}, 400, "A message is required"},
	{"POST", "/v1/messages/restore", map[string]string{"projectId": "p1", "sessionId": "s1"}, 400, "Only OpenCode, Claude Code and Codex chats can be rewound"},
	{"POST", "/v1/attachments?projectId=p1&sessionId=s1", nil, 501, "This host does not accept attachments"},
	{"POST", "/v1/abort", map[string]string{"projectId": "p1", "sessionId": "s1"}, 200, `{"aborted":true}`},
	// The fake agent has no event stream, so its chats cannot be streamed.
	{"GET", "/v1/chat/events?projectId=p1&sessionId=s1", nil, 501, "This host cannot stream this chat"},
	{"GET", "/v1/chat/messages?projectId=p1&sessionId=s1", nil, 200, `"oldestId":"m1"`},
	// Chat fork: only Codex chats fork so far.
	{"POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": "s1"}, 501, "This chat cannot be forked"},
	{"POST", "/v1/chat/regenerate", map[string]string{"projectId": "p1", "sessionId": "s1"}, 501, "This chat cannot be regenerated"},
	// Chat names: the fake agent cannot rename its chats.
	{"POST", "/v1/chat/title", map[string]string{"projectId": "p1", "sessionId": "s1", "title": "Named", "basedOn": "m1"}, 502, "provider_unavailable"},

	// Plain chats' memory: the route host has no plain chats.
	{"GET", "/v1/memory", nil, 503, `"code":"memory_unavailable"`},
	{"PATCH", "/v1/memory", map[string]string{"id": "mem_1", "text": "x"}, 503, `"code":"memory_unavailable"`},
	{"DELETE", "/v1/memory?id=mem_1", nil, 503, `"code":"memory_unavailable"`},
	{"POST", "/v1/memory/settings", map[string]bool{"enabled": false}, 503, `"code":"memory_unavailable"`},

	{"GET", "/v1/queue?projectId=p1&sessionId=s1", nil, 200, `{"items":[]}`},
	{"POST", "/v1/queue", map[string]string{"projectId": "p1", "sessionId": "s1", "text": "later"}, 201, `"status":"queued"`},
	{"POST", "/v1/queue/remove", map[string]string{"projectId": "p1", "sessionId": "s1", "itemId": "missing"}, 404, "Queued message not found"},

	{"GET", "/v1/interactions?projectId=p1&sessionId=s1", nil, 501, "This host does not support agent interactions"},
	{"POST", "/v1/permissions/reply", map[string]string{"projectId": "p1", "sessionId": "s1", "requestId": "r1", "reply": "always"}, 400, "Choose allow once or deny"},
	// The two question routes answer the same body differently.
	{"POST", "/v1/questions/reply", map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": "r1", "answers": [][]string{{"Yes"}}}, 501, "This host does not support agent interactions"},
	{"POST", "/v1/questions/reject", map[string]any{"projectId": "p1", "sessionId": "s1", "requestId": "r1", "answers": [][]string{{"Yes"}}}, 400, "cancellation takes no answers"},

	{"GET", "/v1/files?projectId=p1", nil, 200, `"name":"notes.txt"`},
	{"GET", "/v1/file?projectId=p1&path=notes.txt", nil, 200, `{"path":"notes.txt","content":"routes","revision":`},
	{"POST", "/v1/file", map[string]string{"projectId": "p1", "path": "notes.txt", "content": "edited", "revision": "stale"}, 409, `"code":"file_conflict"`},

	{"GET", "/v1/git/repositories?projectId=p1", nil, 200, `{"repositories":[{"name":"Project","path":"."}]}`},
	{"GET", "/v1/git/status?projectId=p1", nil, 200, `"changes":[`},
	// notes.txt is untracked, so the diff shows it as a new file.
	{"GET", "/v1/git/diff?projectId=p1&file=notes.txt", nil, 200, `{"diff":"diff --git a/notes.txt b/notes.txt\nnew file mode 100644\n--- /dev/null\n+++ b/notes.txt\n@@ -0,0 +1 @@\n+routes\n`},

	// Project file changes, file search and Git changes. None of them changes
	// notes.txt, and unstaging undoes the staging.
	{"POST", "/v1/files/move", map[string]string{"projectId": "p1", "from": "notes.txt", "to": "notes.txt"}, 409, "choose another name"},
	{"POST", "/v1/files/mkdir", map[string]string{"projectId": "p1", "path": "notes.txt"}, 409, "A file or folder with that name already exists"},
	{"POST", "/v1/files/upload?projectId=p1&path=notes.txt", nil, 409, "the upload did not replace it"},
	{"POST", "/v1/files/delete", map[string]any{"projectId": "p1", "path": "notes.txt", "permanent": true}, 400, `"code":"confirmation_required"`},
	{"GET", "/v1/files/search?projectId=p1&q=routes", nil, 200, `"matches":[{"line":1,"column":1,"preview":"routes"}]`},
	{"GET", "/v1/git/identity?projectId=p1", nil, 200, `"source":"none"`},
	{"POST", "/v1/git/stage", map[string]any{"projectId": "p1", "files": []string{"notes.txt"}}, 200, `{"staged":1}`},
	{"POST", "/v1/git/unstage", map[string]any{"projectId": "p1", "files": []string{"notes.txt"}}, 200, `{"unstaged":1}`},
	{"POST", "/v1/git/commit", map[string]string{"projectId": "p1", "message": "routed"}, 409, `"code":"git_identity_missing"`},
	{"GET", "/v1/git/branches?projectId=p1", nil, 200, `"branches":[]`},
	{"POST", "/v1/git/branch", map[string]string{"projectId": "p1", "action": "create", "name": "--invalid"}, 400, `"code":"git_branch_invalid"`},
	{"GET", "/v1/git/history?projectId=p1", nil, 200, `"commits":[]`},
	{"GET", "/v1/git/commit?projectId=p1&commit=invalid", nil, 400, `"code":"git_commit_invalid"`},
	{"GET", "/v1/git/commit/diff?projectId=p1&commit=invalid", nil, 400, `"code":"git_commit_invalid"`},
	{"GET", "/v1/git/remotes?projectId=p1", nil, 200, `"remotes":[]`},
	{"POST", "/v1/git/remote", map[string]string{"projectId": "p1", "remote": "--invalid", "action": "fetch"}, 400, `"code":"git_remote_invalid"`},
	{"GET", "/v1/git/stashes?projectId=p1", nil, 200, `"stashes":[]`},
	{"POST", "/v1/git/stash", map[string]string{"projectId": "p1", "action": "invalid"}, 400, `action takes save, apply or drop`},
	{"POST", "/v1/git/discard", map[string]string{"projectId": "p1"}, 400, `"code":"git_confirmation_required"`},

	{"GET", "/v1/terminals?projectId=p1", nil, 200, `{"terminals":[]}`},
	{"GET", "/v1/terminals/others", nil, 200, `{"terminals":[]}`},
	{"POST", "/v1/terminals", map[string]any{"projectId": "p1", "rows": 0, "cols": 0}, 400, "Terminal dimensions or title are invalid"},
	{"GET", "/v1/terminal/output?projectId=p1", nil, 400, "A nonnegative terminal cursor is required"},
	{"POST", "/v1/terminal/title", map[string]any{"projectId": "p1", "terminalId": "missing", "title": "Repair login redirect", "basedOn": 1}, 404, `"code":"terminal_not_found"`},
	{"POST", "/v1/terminal/input", map[string]string{"projectId": "p1", "terminalId": "missing"}, 400, "Terminal input must contain"},
	{"POST", "/v1/terminal/resize", map[string]any{"projectId": "p1", "terminalId": "missing", "rows": 0, "cols": 0}, 400, "Terminal dimensions are invalid"},
	{"POST", "/v1/terminal/close", map[string]string{"projectId": "p1", "terminalId": "missing"}, 404, `"code":"terminal_not_found"`},
	// Mac-only terminal routes, called as this Mac's app.
	{"GET", "/v1/terminals/running", nil, 200, `{"running":0,"routed":0}`},
	{"POST", "/v1/terminals/end-all", map[string]string{}, 200, `{"ended":0,"released":0}`},
	{"GET", "/v1/terminals/all", nil, 200, `{"keeper":{"adopts":true,"state":"running"},"terminals":[]}`},
	{"POST", "/v1/terminals/end", map[string]string{"terminalId": "missing"}, 404, `"code":"terminal_not_found"`},
	{"POST", "/v1/terminals/clear", map[string]string{"terminalId": "missing"}, 404, `"code":"terminal_not_found"`},
	{"POST", "/v1/terminals/end-device", map[string]string{"deviceId": "missing"}, 200, `{"ended":0}`},

	// Archive (M1 chunk B1). Local-only routes are called as this Mac's app.
	// The message sent above was archived before delivery (M1 chunk B2).
	{"GET", "/v1/archive/changes", nil, 200, `"resync":false,"changes":[{"seq":1,"entity":"chat","op":"upsert","payload":{"id":"s1"`},
	{"GET", "/v1/archive/chat?chatId=missing&limit=51", nil, 400, "Limit must be between 1 and 50"},
	{"GET", "/v1/archive/search", nil, 400, "Enter text to search for"},
	{"GET", "/v1/archive/export?format=pdf", nil, 400, "Choose markdown, json or jsonl"},
	{"GET", "/v1/archive/terminal-logs?projectId=p1", nil, 200, `{"logs":[]}`},
	{"GET", "/v1/archive/terminal-log?id=missing", nil, 404, "Terminal log not found"},
	{"POST", "/v1/archive/delete", map[string]string{"kind": "file", "id": "x"}, 400, "Choose chat or terminalLog"},
	{"GET", "/v1/archive/stats", nil, 200, `"schemaVersion":8`},
	{"GET", "/v1/archive/blob?chatId=s1", nil, 400, "Name the message and the attachment"},
	// Vault, called as this Mac's app: it is off.
	{"GET", "/v1/vault", nil, 200, `{"enabled":false,"folder":"`},
	{"POST", "/v1/vault/settings", map[string]string{"folder": "relative"}, 400, "Choose an absolute folder for the vault"},
	{"POST", "/v1/vault/rebuild", nil, 409, `"code":"vault_off"`},
	// Continue (M1 chunk B2).
	{"POST", "/v1/chat/continue", map[string]any{"projectId": "p1", "sourceSessionId": "s1", "provider": "opencode", "contextChars": 10}, 400, "contextChars must be between 1000 and 200000"},
	// Chat's sign-ins: a host without Claude Code and Codex chats checks none.
	{"POST", "/v1/chat/providers/check", nil, 404, "This host checks no Chat sign-ins"},

	// Web previews.
	{"GET", "/v1/preview/ports", nil, 200, `{"ports":[{"port":5173,"address":"127.0.0.1","process":"node"}]}`},
	{"POST", "/v1/preview/sessions", map[string]int{"port": 0}, 400, "Choose a port between 1 and 65535"},
	{"GET", "/v1/preview/sessions", nil, 200, `{"sessions":[]}`},
	{"POST", "/v1/preview/sessions/revoke", map[string]string{"sessionId": "missing"}, 404, `"code":"preview_session_not_found"`},

	// Notices, called as this Mac's app.
	{"GET", "/v1/notices", nil, 200, `{"notices":[],"cursor":"`},
	{"POST", "/v1/notices/ack", map[string]int{"through": 5}, 400, "No notice has that seq yet"},

	// Agents: the catalog (Claude Code and Codex are always listed), icons,
	// changes and OpenCode's providers (the route host has no OpenCode).
	{"GET", "/v1/agents", nil, 200, `{"automaticUpdates":false,"registry":{"error":"The registry could not be reached."},"agents":[{"id":"claude","name":"Claude Code","source":"local","state":"notInstalled"`},
	{"GET", "/v1/agents/icon?id=codex", nil, 404, "No icon for this agent"},
	{"POST", "/v1/agents/install", map[string]string{"id": "claude"}, 409, `"code":"not_managed"`},
	{"POST", "/v1/agents/uninstall", map[string]string{"id": "no-such-agent"}, 404, `"code":"unknown_agent"`},
	{"POST", "/v1/agents/settings", map[string]any{"automaticUpdates": false}, 200, `{"automaticUpdates":false}`},
	{"POST", "/v1/agents/update", map[string]any{"id": "Codex", "allowUnverified": true}, 404, "No agent has that id"},
	{"GET", "/v1/providers", nil, 503, `"code":"provider_catalog_unavailable"`},
	// Called as this Mac's app: a version that is not current changes nothing.
	{"POST", "/v1/agents/opencode/failed", map[string]string{"version": "1.18.33", "reason": "it exited"}, 200, `{"rolledBack":false,"current":""}`},

	// Remote access: the peer list and endpoint report as this Mac's app,
	// registration as a paired device.
	{"GET", "/v1/remote-access/peers?wait=20001", nil, 400, "wait must be between 0 and 20000 milliseconds"},
	{"POST", "/v1/remote-access/endpoint", map[string]bool{"enabled": true}, 400, "nodeId is required while remote access is on"},
	{"POST", "/v1/remote-access/device", map[string]string{"nodeId": "x"}, 400, "nodeId must be 64 and proof 128 lowercase hexadecimal characters"},
}

// wantRouteError checks an answer from serveHTTP itself: the exact JSON error
// and the headers every response carries.
func wantRouteError(t *testing.T, label string, w *httptest.ResponseRecorder, status int, code, message string) {
	t.Helper()
	body := fmt.Sprintf(`{"error":{"code":%q,"message":%q}}`+"\n", code, message)
	if w.Code != status || w.Body.String() != body {
		t.Errorf("%s: %d %q, want %d %q", label, w.Code, w.Body.String(), status, body)
	}
	if w.Header().Get("Content-Type") != "application/json" || w.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("%s: headers %v", label, w.Header())
	}
}

func withOrigin(h http.Handler, origin string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("Origin", origin)
		h.ServeHTTP(w, r)
	})
}

func TestRouteTableEntries(t *testing.T) {
	methods := map[string]bool{"GET": true, "POST": true, "PUT": true, "PATCH": true, "DELETE": true}
	public, local, notTunnel := []string{}, []string{}, []string{}
	for _, entry := range routes {
		name := entry.method + " " + entry.path
		if entry.handle == nil || !methods[entry.method] || !strings.HasPrefix(entry.path, "/v1/") {
			t.Errorf("%s: a route needs a handler, an upper-case method and a /v1/ path", name)
		}
		if entry.public {
			public = append(public, name)
		}
		if entry.localOnly {
			local = append(local, name)
		}
		if entry.notTunnel {
			notTunnel = append(notTunnel, name)
		}
		if entry.public && entry.localOnly {
			t.Errorf("%s cannot be both public and local-only", name)
		}
	}
	sort.Strings(public)
	if strings.Join(public, ", ") != "GET /v1/health, POST /v1/pair" {
		t.Errorf("public routes %v; only health and pairing skip authentication", public)
	}
	sort.Strings(local)
	if strings.Join(local, ", ") != "GET /v1/archive/stats, GET /v1/notices, GET /v1/remote-access/peers, GET /v1/terminals/all, GET /v1/terminals/running, GET /v1/vault, POST /v1/agents/opencode/failed, POST /v1/chat/providers/check, POST /v1/local-web/import, POST /v1/local-web/launch, POST /v1/notices/ack, POST /v1/remote-access/endpoint, POST /v1/terminals/clear, POST /v1/terminals/end, POST /v1/terminals/end-all, POST /v1/terminals/end-device, POST /v1/vault/rebuild, POST /v1/vault/settings" {
		t.Errorf("local-only routes %v", local)
	}
	// Remote access: pairing and registering happen over the TCP listener.
	sort.Strings(notTunnel)
	if strings.Join(notTunnel, ", ") != "GET /v1/terminals/all, GET /v1/terminals/running, POST /v1/local-web/import, POST /v1/local-web/launch, POST /v1/pair, POST /v1/remote-access/device, POST /v1/terminals/clear, POST /v1/terminals/end, POST /v1/terminals/end-all, POST /v1/terminals/end-device" {
		t.Errorf("routes refused through the tunnel %v", notTunnel)
	}
	checks := map[routeKey]int{}
	for _, check := range routeChecks {
		if _, known := routeIndex[check.key()]; !known {
			t.Errorf("check for unknown route %s %s", check.method, check.target)
		}
		checks[check.key()]++
	}
	for _, entry := range routes {
		if strings.HasPrefix(entry.path, "/v1/local-web/") {
			continue
		}
		if count := checks[routeKey{entry.method, entry.path}]; count != 1 {
			t.Errorf("%s %s has %d requests in routeChecks, want 1", entry.method, entry.path, count)
		}
	}
}

func TestRouteIndexRejectsDuplicates(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("a repeated method and path was accepted")
		}
	}()
	indexRoutes([]route{
		{method: "GET", path: "/v1/health", handle: (*Host).health},
		{method: "GET", path: "/v1/health", handle: (*Host).projects},
	})
}

func TestRoutesReachTheirHandlers(t *testing.T) {
	host, _, fixture, token := routeHost(t)
	for _, check := range routeChecks {
		auth := token
		if routeIndex[check.key()].public {
			auth = ""
		}
		var w *httptest.ResponseRecorder
		if routeIndex[check.key()].localOnly {
			w = localRequest(t, host.Handler(), check.method, check.target, routeLocalToken, check.body)
		} else {
			w = request(t, host.Handler(), check.method, check.target, auth, check.body)
		}
		if w.Code != check.status || !strings.Contains(w.Body.String(), check.marker) {
			t.Errorf("%s %s: %d %s, want %d with %s", check.method, check.target, w.Code, w.Body, check.status, check.marker)
		}
		contentType := "application/json"
		if check.key() == (routeKey{"GET", "/v1/pulse"}) {
			contentType = "application/x-ndjson"
		}
		if w.Header().Get("Content-Type") != contentType || w.Header().Get("Cache-Control") != "no-store" {
			t.Errorf("%s %s: headers %v", check.method, check.target, w.Header())
		}
	}
	if fixture.created.Title != "Routed" || fixture.prompted != "s1:routed" || fixture.aborted != "s1" {
		t.Errorf("handler effects: created=%q prompted=%q aborted=%q", fixture.created.Title, fixture.prompted, fixture.aborted)
	}
}

func TestRoutesAnswerOtherMethodsAsNotFound(t *testing.T) {
	host, _, _, token := routeHost(t)
	paths := map[string]bool{"/": true, "/v1/": true, "/v1/unknown": true, "/v1/projects/": true, "/V1/projects": true}
	for _, entry := range routes {
		paths[entry.path] = true
	}
	for path := range paths {
		for _, method := range []string{"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "get"} {
			if _, known := routeIndex[routeKey{method, path}]; known {
				continue
			}
			name := method + " " + path
			wantRouteError(t, name, request(t, host.Handler(), method, path, token, nil), 404, "not_found", "Route not found")
			wantRouteError(t, name+" without a token", request(t, host.Handler(), method, path, "", nil), 401, "unauthorized", "Valid bearer authentication is required")
		}
	}
}

func TestProtectedRoutesRequireBearerAuthentication(t *testing.T) {
	host, store, fixture, token := routeHost(t)
	state, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeDevice(state.Devices[0].ID); err != nil {
		t.Fatal(err)
	}
	for _, check := range routeChecks {
		if routeIndex[check.key()].public {
			continue
		}
		for _, credential := range []string{"", "not-a-token", token} {
			label := fmt.Sprintf("%s %s with token %q", check.method, check.target, credential)
			wantRouteError(t, label, request(t, host.Handler(), check.method, check.target, credential, check.body), 401, "unauthorized", "Valid bearer authentication is required")
		}
	}
	if fixture.created.ID != "" || fixture.prompted != "" || fixture.aborted != "" || len(host.queue.Items("p1", "s1")) != 0 {
		t.Error("a handler ran without valid authentication")
	}
}

func TestRoutesRejectBrowserOrigins(t *testing.T) {
	host, _, fixture, token := routeHost(t)
	checks := append([]routeCheck{{method: "GET", target: "/v1/unknown"}}, routeChecks...)
	for _, origin := range []string{"https://example.com", "null"} {
		handler := withOrigin(host.Handler(), origin)
		for _, check := range checks {
			for _, credential := range []string{token, ""} {
				label := fmt.Sprintf("%s %s from %s with token %q", check.method, check.target, origin, credential)
				wantRouteError(t, label, request(t, handler, check.method, check.target, credential, check.body), 403, "origin_rejected", "Browser origins are not allowed")
			}
		}
	}
	// Only the pairing done by routeHost counts toward the pairing limits.
	if fixture.created.ID != "" || fixture.prompted != "" || fixture.aborted != "" || len(host.allPairAttempts) != 1 {
		t.Error("a handler ran for a browser origin")
	}
}

func TestHealthAndPairingStayOpen(t *testing.T) {
	host, store, _, _ := routeHost(t)
	for _, credential := range []string{"", "not-a-token"} {
		w := request(t, host.Handler(), "GET", "/v1/health", credential, nil)
		if w.Code != 200 || w.Body.String() != `{"protocolVersion":1,"status":"ok"}`+"\n" {
			t.Errorf("health with token %q: %d %s", credential, w.Code, w.Body)
		}
		code, err := store.CreatePairingCode(time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		w = request(t, host.Handler(), "POST", "/v1/pair", credential, map[string]string{"code": code, "deviceName": "Open"})
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"token":"`) {
			t.Errorf("pair with token %q: %d %s", credential, w.Code, w.Body)
		}
	}
}

// The capabilities keep the keys and order of the map they replaced: every
// original key is present on an unconfigured host and empty lists are []
// rather than null. The file, Git change and workspace keys follow on every host;
// chatProviderInfo appears only when chats can stream.
func TestCapabilitiesKeepTheirJSON(t *testing.T) {
	changes := `,"files":["move","mkdir","upload","trash","delete","search"],"git":["stage","unstage","commit","stagedDiff","unstagedDiff","identity","branches","history","remotes","stashes","discard","untrackedFiles"],"projects":{"version":1,"features":["details","browse","add","create","rename","remove"]}}` + "\n"
	if runtime.GOOS != "darwin" {
		changes = `,"files":["move","mkdir","upload","delete","search"],"git":["stage","unstage","commit","stagedDiff","unstagedDiff","identity","branches","history","remotes","stashes","discard","untrackedFiles"],"projects":{"version":1,"features":["details","browse","add","create","rename","remove"]}}` + "\n"
	}
	// Presence views (notices.go) work on every host.
	changes = strings.TrimSuffix(changes, "}\n") + `,"presence":["views"]}` + "\n"
	plain, store, _ := testHost(t)
	w := request(t, plain.Handler(), "GET", "/v1/capabilities", paired(t, plain, store), nil)
	want := `{"chatFeatures":["reasoning","parts","stop","clientMessageId","title"],"chatProviders":["opencode"],"interactions":false,"terminal":false,"terminalPrograms":[]` + changes
	if w.Code != 200 || w.Body.String() != want {
		t.Errorf("unconfigured host: %d %s", w.Code, w.Body)
	}
	w = newChatFixture(t).call(t, "GET", "/v1/capabilities", nil)
	want = `{"chatFeatures":["reasoning","attachments","queue","rewind","events","parts","stop","clientMessageId","regenerate","title"],"chatProviders":["opencode","claude","codex"],"interactions":true,"terminal":false,"terminalPrograms":[]` + strings.TrimSuffix(changes, `,"presence":["views"]}`+"\n") + `,"chatProviderInfo":{"opencode":{"transport":"sse","features":["rewind","restoreFiles","approvals","questions"]},"claude":{"transport":"coarse","features":[]},"codex":{"transport":"coarse","features":[]}},"presence":["views"]}` + "\n"
	if w.Code != 200 || w.Body.String() != want {
		t.Errorf("configured host: %d %s", w.Code, w.Body)
	}
}
