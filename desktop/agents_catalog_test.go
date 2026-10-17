package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// quietAgents makes a catalog safe for tests: it finds only the commands in
// commands (program → path), runs nothing for versions (versions gives them
// by path), and reads the registry from server (nil: every read fails at
// once).
func quietAgents(c *agentCatalog, commands map[string]string, versions map[string]string, server *httptest.Server) {
	c.lookup = func(program string) (string, bool) {
		path, ok := commands[program]
		return path, ok
	}
	c.versionOf = func(path string) string { return versions[path] }
	c.baseEnv = []string{"PATH=/usr/bin:/bin", "HOME=" + os.TempDir(), "AGENTLAND_SECRET_PROBE=must-not-leak", "OPENCODE_SERVER_PASSWORD=must-not-leak"}
	if server == nil {
		c.fetcher = newAgentFetcher(failingTransport{}, "test")
		c.registryURL = "https://registry.invalid/registry.json"
	} else {
		c.fetcher = newAgentFetcher(server.Client().Transport, "test")
		c.registryURL = server.URL + "/registry.json"
	}
	c.registryWait, c.iconWait = 5*time.Second, 5*time.Second
}

// catalogFixture is a host with the agent catalog, reading a fake registry,
// finding only the fake commands a test gives it.
type catalogFixture struct {
	t         *testing.T
	host      *Host
	store     *Store
	registry  *fakeRegistry
	token     string
	self      string
	dir       string // the fake ACP agent's scripts and records
	terminals *terminalFixture
}

const catalogLocalToken = "catalog-local-session"

func newCatalogFixture(t *testing.T, commands, versions map[string]string) *catalogFixture {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	_, store, agent := testHost(t)
	chats, err := NewCLIChats(store.Path+".chats.json", acpTestRunner{})
	if err != nil {
		t.Fatal(err)
	}
	backend := newTerminalFixture(agent)
	host := newHost(store, backend, HostOptions{TerminalEnabled: true, Terminals: backend.fakeTerminals, CLIChats: chats, LocalSessionToken: catalogLocalToken, Agents: &AgentOptions{Version: "test"}})
	registry := newFakeRegistry(t)
	if commands == nil {
		commands = map[string]string{}
	}
	quietAgents(host.agents, commands, versions, registry.server)
	// Terminals: the shell and the catalog's agents only.
	fakeTerminalPrograms(host, false)
	f := &catalogFixture{t: t, host: host, store: store, registry: registry, self: self, dir: t.TempDir(), terminals: backend}
	t.Cleanup(func() {
		host.Close()
		host.agents.close()
	})
	f.token = paired(t, host, store)
	return f
}

func (f *catalogFixture) call(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return request(f.t, f.host.Handler(), method, path, f.token, body)
}

func (f *catalogFixture) local(method, path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return localRequest(f.t, f.host.Handler(), method, path, catalogLocalToken, body)
}

type catalogAnswer struct {
	Registry struct {
		FetchedAt string `json:"fetchedAt"`
		Error     string `json:"error"`
	} `json:"registry"`
	Agents []agentJSON `json:"agents"`
}

func (f *catalogFixture) agents() catalogAnswer {
	f.t.Helper()
	w := f.call("GET", "/v1/agents", nil)
	if w.Code != 200 {
		f.t.Fatalf("agents %d %s", w.Code, w.Body)
	}
	var answer catalogAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &answer); err != nil {
		f.t.Fatal(err)
	}
	return answer
}

func (f *catalogFixture) agent(id string) agentJSON {
	f.t.Helper()
	for _, agent := range f.agents().Agents {
		if agent.ID == id {
			return agent
		}
	}
	f.t.Fatalf("%s is not listed", id)
	return agentJSON{}
}

// waitState waits for the agent to reach a state other than installing or
// updating.
func (f *catalogFixture) waitSettled(id string) agentJSON {
	f.t.Helper()
	var agent agentJSON
	waitFor(f.t, id+" to settle", func() bool {
		for _, entry := range f.agents().Agents {
			if entry.ID == id {
				agent = entry
				return entry.State != "installing" && entry.State != "updating"
			}
		}
		return false
	})
	f.host.agents.mu.Lock()
	op := f.host.agents.ops[id]
	f.host.agents.mu.Unlock()
	if op != nil {
		<-op.done
	}
	return agent
}

// fakeAgentArchive is a release archive whose ./agent runs the test binary as
// the fake ACP agent.
func (f *catalogFixture) fakeAgentArchive() []byte {
	return tarGz(f.t, archiveEntry{name: "./agent", body: "#!/bin/sh\nexec '" + f.self + "' \"$@\"\n", mode: 0o755}, archiveEntry{name: "./README", body: "fake"})
}

// fakeAgentEntry is a registry entry for the fake agent at version, served
// from path, with sha256 when sum is not "".
func (f *catalogFixture) fakeAgentEntry(id, version, path, sum string) map[string]any {
	binary := map[string]any{"archive": f.registry.url(path), "cmd": "./agent", "args": []string{"acp"}, "env": map[string]string{"AGENTLAND_FAKE_AGENT": "acp", "AGENTLAND_FAKE_ACP_DIR": f.dir}}
	if sum != "" {
		binary["sha256"] = sum
	}
	return map[string]any{"id": id, "name": "Fake " + id, "version": version, "description": "A fake agent", "license": "MIT", "icon": f.registry.url("/icons/" + id + ".svg"),
		"distribution": map[string]any{"binary": map[string]any{agentPlatform(): binary}}}
}

// answerInitialize makes every start of the fake answer initialize.
func (f *catalogFixture) answerInitialize() {
	f.t.Helper()
	steps := fakeInit(map[string]any{})
	lines := []string{}
	for _, step := range steps {
		data, _ := json.Marshal(step)
		lines = append(lines, string(data))
	}
	if err := os.WriteFile(filepath.Join(f.dir, "script.jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

func TestCatalogListsRegistryLocalAndNativeAgents(t *testing.T) {
	bin := t.TempDir()
	gemini := writeScript(t, filepath.Join(bin, "gemini"), "exit 0\n")
	amp := writeScript(t, filepath.Join(bin, "amp"), "exit 0\n")
	claude := writeScript(t, filepath.Join(bin, "claude"), "exit 0\n")
	f := newCatalogFixture(t, map[string]string{"gemini": gemini, "amp": amp, "claude": claude}, map[string]string{gemini: "0.60.1", amp: "0.0.17"})
	var entries []map[string]any
	json.Unmarshal([]byte(`[`+strings.Join([]string{
		`{"id":"goose","name":"goose","version":"1.52.0","description":"A local agent","website":"https://block.github.io/goose/","license":"Apache-2.0","icon":"` + f.registry.url("/icons/goose.svg") + `","distribution":{"binary":{"` + agentPlatform() + `":{"archive":"https://example.com/goose.tar.bz2","cmd":"./goose","args":["acp"],"sha256":"` + strings.Repeat("a", 64) + `"}}}}`,
		`{"id":"gemini","name":"Gemini CLI","version":"0.61.0","description":"Google's official CLI for Gemini","repository":"https://github.com/google-gemini/gemini-cli","license":"Apache-2.0","distribution":{"npx":{"package":"@google/gemini-cli@0.61.0","args":["--acp"]}}}`,
		`{"id":"claude-acp","name":"Claude Agent","version":"0.81.2","license":"proprietary","icon":"` + f.registry.url("/icons/claude-acp.svg") + `","distribution":{"npx":{"package":"@agentclientprotocol/claude-agent-acp@0.81.2"}}}`,
		`{"id":"codex-acp","name":"Codex","version":"1.13.1","distribution":{"npx":{"package":"@agentclientprotocol/codex-acp@1.13.1"}}}`,
		`{"id":"opencode","name":"OpenCode","version":"1.18.32","license":"MIT","distribution":{"binary":{"` + agentPlatform() + `":{"archive":"https://example.com/opencode.zip","cmd":"./opencode","args":["acp"],"sha256":"` + strings.Repeat("b", 64) + `"}}}}`,
		`{"id":"cursor","name":"Cursor","version":"2026.09.18","distribution":{"binary":{"` + agentPlatform() + `":{"archive":"https://example.com/cursor.tar.gz","cmd":"./cursor-agent","args":["acp"]}}}}`,
		`{"id":"pi-acp","name":"pi ACP","version":"0.0.34","distribution":{"npx":{"package":"pi-acp@0.0.34"}}}`,
	}, ",")+`]`), &entries)
	f.registry.setAgents(entries...)
	f.registry.setFile("/icons/goose.svg", []byte(`<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>`))
	f.registry.setFile("/icons/claude-acp.svg", []byte(`<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>`))
	answer := f.agents()
	if answer.Registry.Error != "" || answer.Registry.FetchedAt == "" {
		t.Fatalf("registry %+v", answer.Registry)
	}
	names := []string{}
	byID := map[string]agentJSON{}
	for _, agent := range answer.Agents {
		names = append(names, agent.Name)
		byID[agent.ID] = agent
	}
	if !reflect.DeepEqual(names, []string{"Amp", "Claude Code", "Codex", "Cursor", "Gemini CLI", "goose", "OpenCode", "pi ACP"}) {
		t.Fatalf("names %v (claude-acp and codex-acp are claude and codex)", names)
	}
	want := map[string]agentJSON{
		"amp":      {ID: "amp", Name: "Amp", Source: "local", State: "installed", InstalledVersion: "0.0.17", Terminal: true, Verified: true},
		"claude":   {ID: "claude", Name: "Claude Code", Source: "local", State: "installed", Terminal: true, Verified: true},
		"codex":    {ID: "codex", Name: "Codex", Source: "local", State: "notInstalled", Verified: true},
		"cursor":   {ID: "cursor", Name: "Cursor", Source: "registry", State: "notInstalled", LatestVersion: "2026.09.18", Chat: true, Terminal: true},
		"gemini":   {ID: "gemini", Name: "Gemini CLI", Description: "Google's official CLI for Gemini", Website: "https://github.com/google-gemini/gemini-cli", License: "Apache-2.0", Source: "local", State: "installed", InstalledVersion: "0.60.1", LatestVersion: "0.61.0", Chat: true, Terminal: true, Verified: true},
		"goose":    {ID: "goose", Name: "goose", Description: "A local agent", Website: "https://block.github.io/goose/", License: "Apache-2.0", Source: "registry", State: "notInstalled", LatestVersion: "1.52.0", Chat: true, Terminal: true, Verified: true},
		"opencode": {ID: "opencode", Name: "OpenCode", License: "MIT", Source: "registry", State: "notInstalled", LatestVersion: "1.18.32", Chat: true, Verified: true},
		"pi-acp":   {ID: "pi-acp", Name: "pi ACP", Source: "registry", State: "notInstalled", LatestVersion: "0.0.34", Chat: true, Verified: true},
	}
	for id, expected := range want {
		if got := byID[id]; !reflect.DeepEqual(got, expected) {
			t.Errorf("%s:\n got %+v\nwant %+v", id, got, expected)
		}
	}
	// Paths, commands and environments never leave the host.
	body := f.call("GET", "/v1/agents", nil).Body.String()
	for _, secret := range []string{bin, "npx", "@google/gemini-cli", "example.com", "sha256", "--acp"} {
		if strings.Contains(body, secret) {
			t.Errorf("the catalog shows %q", secret)
		}
	}
	// The Mac's own session also gets OpenCode's restart fields.
	if byID["opencode"].RestartWanted != nil || byID["opencode"].IdleForSeconds != nil {
		t.Fatal("a device got the local session's fields")
	}
	var local catalogAnswer
	json.Unmarshal(f.local("GET", "/v1/agents", nil).Body.Bytes(), &local)
	for _, agent := range local.Agents {
		if agent.ID == "opencode" && (agent.RestartWanted == nil || *agent.RestartWanted || agent.IdleForSeconds == nil) {
			t.Fatalf("local opencode %+v", agent)
		}
		if agent.ID != "opencode" && agent.IdleForSeconds != nil {
			t.Fatalf("%s has idleForSeconds", agent.ID)
		}
	}
	// Capabilities: the usable agents, the ACP chat agents and terminals.
	var capabilities struct {
		ChatProviders    []string
		TerminalPrograms []string
		Agents           []string
		AgentCatalog     []agentCatalogEntry
		ChatProviderInfo map[string]chatProviderEntry
	}
	json.Unmarshal(f.call("GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if !reflect.DeepEqual(capabilities.AgentCatalog, []agentCatalogEntry{{ID: "claude", Name: "Claude Code", Terminal: true}, {ID: "amp", Name: "Amp", Terminal: true}, {ID: "gemini", Name: "Gemini CLI", Chat: true, Terminal: true}}) {
		t.Fatalf("agentCatalog %+v", capabilities.AgentCatalog)
	}
	if !reflect.DeepEqual(capabilities.ChatProviders, []string{"opencode", "gemini"}) || !reflect.DeepEqual(capabilities.TerminalPrograms, []string{"shell", "amp", "gemini"}) {
		t.Fatalf("providers %v terminals %v", capabilities.ChatProviders, capabilities.TerminalPrograms)
	}
	// (chatProviderInfo needs chats that stream; the ACP tests read it.)
	// A local agent's chats run the local command with the registry's
	// arguments for its id.
	launch, ok := f.host.agents.acpLaunch("gemini")
	if !ok || launch.command != gemini || !reflect.DeepEqual(launch.args, []string{"--acp"}) || launch.name != "Gemini CLI" {
		t.Fatalf("gemini launch %+v", launch)
	}
	if _, ok := f.host.agents.acpLaunch("amp"); ok {
		t.Fatal("amp chats")
	}
	// Icons come through the host; claude shows claude-acp's.
	w := f.call("GET", "/v1/agents/icon?id=goose", nil)
	if w.Code != 200 || w.Header().Get("Content-Type") != "image/svg+xml" || w.Header().Get("X-Content-Type-Options") != "nosniff" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") || w.Header().Get("Cache-Control") != "private, max-age=86400" || !strings.Contains(w.Body.String(), "<circle") {
		t.Fatalf("icon %d %v %s", w.Code, w.Header(), w.Body)
	}
	etag := w.Header().Get("ETag")
	r := httptest.NewRequest("GET", "/v1/agents/icon?id=goose", nil)
	r.Header.Set("Authorization", "Bearer "+f.token)
	r.Header.Set("If-None-Match", etag)
	cached := httptest.NewRecorder()
	f.host.Handler().ServeHTTP(cached, r)
	if cached.Code != 304 {
		t.Fatalf("If-None-Match %d", cached.Code)
	}
	if w := f.call("GET", "/v1/agents/icon?id=claude", nil); w.Code != 200 || !strings.Contains(w.Body.String(), "<rect") {
		t.Fatalf("claude icon %d %s", w.Code, w.Body)
	}
	if w := f.call("GET", "/v1/agents/icon?id=cursor", nil); w.Code != 404 {
		t.Fatalf("no icon %d", w.Code)
	}
	if w := f.call("GET", "/v1/agents/icon?id=../../etc/passwd", nil); w.Code != 404 {
		t.Fatalf("a path as id %d", w.Code)
	}
	if hits := f.registry.hitsOf("/icons/goose.svg"); hits != 1 {
		t.Fatalf("the icon was read %d times", hits)
	}
	// Unauthenticated callers get nothing.
	if w := request(t, f.host.Handler(), "GET", "/v1/agents", "", nil); w.Code != 401 {
		t.Fatalf("no token %d", w.Code)
	}
}

func TestCatalogRegistryReads(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.registry.setAgents(f.fakeAgentEntry("goose", "1.0.0", "/goose.tar.gz", ""))
	first := f.agents()
	if first.Registry.FetchedAt == "" || f.registry.hitsOf("/registry.json") != 1 {
		t.Fatalf("first read %+v", first.Registry)
	}
	// Within the hour the copy answers.
	f.agents()
	if f.registry.hitsOf("/registry.json") != 1 {
		t.Fatal("the registry was read again within the hour")
	}
	// An hour later it is read again with its ETag; a 304 keeps the copy.
	catalog := f.host.agents
	catalog.mu.Lock()
	catalog.fetchedAt = catalog.fetchedAt.Add(-2 * time.Hour)
	catalog.lastAttempt = time.Time{}
	catalog.mu.Unlock()
	f.agents()
	waitFor(t, "the background read", func() bool { return f.registry.hitsOf("/registry.json") == 2 })
	waitFor(t, "the read to finish", func() bool {
		catalog.mu.Lock()
		defer catalog.mu.Unlock()
		return catalog.fetching == nil && time.Since(catalog.fetchedAt) < time.Minute
	})
	f.registry.mu.Lock()
	sentETag := f.registry.headers[1].Get("If-None-Match")
	f.registry.mu.Unlock()
	// goose, and Claude Code, Codex and OpenCode, which are always listed.
	if sentETag == "" || len(f.agents().Agents) != 4 {
		t.Fatalf("If-None-Match %q", sentETag)
	}
	// A failed read keeps the copy and says why.
	f.registry.mu.Lock()
	f.registry.status["/registry.json"] = 503
	f.registry.mu.Unlock()
	if err := catalog.refresh(catalog.ctx); err == nil {
		t.Fatal("a 503 was taken")
	}
	answer := f.agents()
	if answer.Registry.Error != "The registry did not answer: the server did not answer with the file (HTTP 503)." || len(answer.Agents) != 4 {
		t.Fatalf("after a failure %+v %d", answer.Registry, len(answer.Agents))
	}
	// A new host reads the kept copy at start.
	restarted := newAgentCatalog(f.host, f.store.Path, AgentOptions{})
	quietAgents(restarted, nil, nil, nil)
	if _, ok := restarted.registryEntry("goose"); !ok {
		t.Fatal("the kept copy was not read")
	}
	if info, err := os.Stat(restarted.store.registryPath()); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("registry copy %v %v", info, err)
	}
}

// A registry at its 4 MiB limit made of tiny entries (about 47,000): the
// host keeps the first 2,000 in the document's order, and the catalog is
// assembled quickly (once a linear search per id, about 10 s a request).
func TestCatalogLargeRegistry(t *testing.T) {
	entry := func(index int) string {
		return fmt.Sprintf(`{"id":"a%05d","name":"A","version":"1.0.0","distribution":{"npx":{"package":"a@1.0.0"}}},`, index)
	}
	head, tail := `{"version":"1.0.0","agents":[`, `]}`
	count := (agentRegistryLimit - len(head) - len(tail)) / len(entry(0))
	var document strings.Builder
	document.WriteString(head)
	// Descending ids: the first entries of the document are not the lowest.
	for index := count - 1; index >= 0; index-- {
		document.WriteString(entry(index))
	}
	data := []byte(strings.TrimSuffix(document.String(), ",") + tail)
	if len(data) > agentRegistryLimit || count < 40_000 {
		t.Fatalf("%d bytes, %d entries", len(data), count)
	}
	agents, err := parseRegistry(data)
	if err != nil || len(agents) != agentRegistryEntryLimit || agents[0].ID != fmt.Sprintf("a%05d", count-2000) || agents[len(agents)-1].ID != fmt.Sprintf("a%05d", count-1) {
		t.Fatalf("kept %d, %v", len(agents), err)
	}
	f := newCatalogFixture(t, nil, nil)
	f.registry.mu.Lock()
	f.registry.document, f.registry.etag = data, ""
	f.registry.mu.Unlock()
	// The entries kept, and Claude Code, Codex and OpenCode.
	if answer := f.agents(); len(answer.Agents) != agentRegistryEntryLimit+3 {
		t.Fatalf("listed %d", len(answer.Agents))
	}
	started := time.Now()
	for range 3 {
		f.agents()
		if _, known := f.host.agents.knownAgent(fmt.Sprintf("a%05d", count-1)); !known {
			t.Fatal("the last entry kept is unknown")
		}
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("three lists and lookups took %v", elapsed)
	}
	if _, known := f.host.agents.knownAgent(fmt.Sprintf("a%05d", count-2001)); known {
		t.Fatal("an entry past the limit is listed")
	}
}

// Icons are kept up to the cache's limit in all, and those of ids the
// registry no longer lists go at its next read, with anything else there.
func TestCatalogIconCacheLimitAndPrune(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	catalog := f.host.agents
	catalog.iconLimit = 1000
	icon := []byte(`<svg xmlns="http://www.w3.org/2000/svg">` + strings.Repeat(" ", 600) + `</svg>`)
	f.registry.setFile("/icons/gemini.svg", icon)
	f.registry.setFile("/icons/goose.svg", icon)
	gemini, goose := f.fakeAgentEntry("gemini", "1.0.0", "/gemini.tar.gz", ""), f.fakeAgentEntry("goose", "1.0.0", "/goose.tar.gz", "")
	f.registry.setAgents(gemini, goose)
	kept := func(name string) bool {
		_, err := os.Stat(filepath.Join(catalog.store.iconDir(), name))
		return err == nil
	}
	// One at a time by id: gemini's is kept, goose's would pass the limit.
	f.agents()
	waitFor(t, "both icons to be read", func() bool {
		catalog.mu.Lock()
		defer catalog.mu.Unlock()
		return f.registry.hitsOf("/icons/goose.svg") == 1 && catalog.iconBusy["goose"] == nil
	})
	if !kept("gemini.svg") {
		t.Fatal("gemini's icon was not kept")
	}
	if kept("goose.svg") {
		t.Fatal("an icon past the limit was kept")
	}
	// The registry drops gemini: its icon goes, with a stray file, and
	// goose's fits.
	if err := os.WriteFile(filepath.Join(catalog.store.iconDir(), ".state-1"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.registry.setAgents(goose)
	if err := catalog.refresh(t.Context()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "goose's icon", func() bool { return kept("goose.svg") })
	if kept("gemini.svg") || kept(".state-1") {
		t.Fatal("the icons folder kept what the registry no longer lists")
	}
	if w := f.call("GET", "/v1/agents/icon?id=goose", nil); w.Code != 200 {
		t.Fatalf("goose's icon %d", w.Code)
	}
}

// GET /v1/agents/icon answers 404 when there is no icon to give and 503
// icon_unavailable when it could not be fetched in time; a read that goes on
// keeps the icon for a later request.
func TestCatalogIconAnswers(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.host.agents.iconWait = 200 * time.Millisecond
	svg := []byte(`<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>`)
	release := f.registry.holdPath("/icons/slow.svg")
	f.registry.setFile("/icons/slow.svg", svg)
	f.registry.setFile("/icons/gif.svg", []byte("GIF89a"))
	f.registry.mu.Lock()
	f.registry.status["/icons/broken.svg"] = 500
	f.registry.status["/icons/busy.svg"] = 429
	f.registry.status["/icons/denied.svg"] = 403
	f.registry.mu.Unlock()
	entries := []map[string]any{}
	for _, id := range []string{"slow", "broken", "busy", "denied", "missing", "gif", "noicon"} {
		entries = append(entries, f.fakeAgentEntry(id, "1.0.0", "/"+id+".tar.gz", ""))
	}
	delete(entries[len(entries)-1], "icon")
	f.registry.setAgents(entries...)
	f.agents()
	for _, test := range []struct {
		id, code string
		status   int
	}{
		{"slow", "icon_unavailable", 503},   // no answer within the wait
		{"broken", "icon_unavailable", 503}, // 500
		{"busy", "icon_unavailable", 503},   // 429
		{"denied", "not_found", 404},        // 403
		{"missing", "not_found", 404},       // 404
		{"gif", "not_found", 404},           // neither SVG nor PNG
		{"noicon", "not_found", 404},        // the registry names none
		{"nobody", "not_found", 404},        // unknown
	} {
		w := f.call("GET", "/v1/agents/icon?id="+test.id, nil)
		if w.Code != test.status || !strings.Contains(w.Body.String(), `"code":"`+test.code+`"`) {
			t.Errorf("%s: %d %s, want %d %s", test.id, w.Code, w.Body, test.status, test.code)
		}
	}
	release()
	waitFor(t, "the slow icon", func() bool {
		w := f.call("GET", "/v1/agents/icon?id=slow", nil)
		return w.Code == 200 && strings.Contains(w.Body.String(), "<rect")
	})
}

// An id that names one of the agents folder's own files is no agent: the
// registry's copy (registry.json) is never uninstalled or installed over, and
// a folder of that kind is not taken for an agent.
func TestCatalogRefusesStoreNames(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	archive := f.fakeAgentArchive()
	f.registry.setFile("/a.tar.gz", archive)
	f.registry.setAgents(f.fakeAgentEntry("registry.json", "1.0.0", "/a.tar.gz", sha256Hex(archive)), f.fakeAgentEntry("goose", "1.0.0", "/a.tar.gz", sha256Hex(archive)))
	for _, agent := range f.agents().Agents {
		if strings.HasSuffix(agent.ID, ".json") {
			t.Fatalf("listed %q", agent.ID)
		}
	}
	store := f.host.agents.store
	cache, err := os.ReadFile(store.registryPath())
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/v1/agents/uninstall", "/v1/agents/install", "/v1/agents/update"} {
		if w := f.call("POST", path, map[string]any{"id": "registry.json"}); w.Code != 404 || !strings.Contains(w.Body.String(), "unknown_agent") {
			t.Fatalf("%s %d %s", path, w.Code, w.Body)
		}
	}
	if w := f.call("GET", "/v1/agents/icon?id=registry.json", nil); w.Code != 404 {
		t.Fatalf("icon %d", w.Code)
	}
	if data, err := os.ReadFile(store.registryPath()); err != nil || string(data) != string(cache) {
		t.Fatalf("the registry's copy changed: %v", err)
	}
	if err := os.Mkdir(filepath.Join(store.root, "notes.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	if ids := store.agentIDs(); len(ids) != 0 {
		t.Fatalf("agents %v", ids)
	}
	if _, ok := f.host.agents.acpLaunch("registry.json"); ok {
		t.Fatal("registry.json chats")
	}
}

// A registry agent not installed that offers nothing for this Mac says so
// with supported: false and verified: false, and install answers 400
// unsupported_platform; every other agent carries no supported member.
func TestCatalogUnsupportedPlatform(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	other := "linux-x86_64"
	if agentPlatform() == other {
		other = "linux-aarch64"
	}
	elsewhere := func(id string) map[string]any {
		return map[string]any{"id": id, "name": id, "version": "1.0.0", "distribution": map[string]any{"binary": map[string]any{other: map[string]any{"archive": "https://example.com/a.tar.gz", "cmd": "./a", "sha256": strings.Repeat("a", 64)}}}}
	}
	f.registry.setAgents(elsewhere("kimi"), elsewhere("opencode"), f.fakeAgentEntry("cursor", "1.0.0", "/cursor.tar.gz", ""), f.fakeAgentEntry("goose", "1.0.0", "/goose.tar.gz", strings.Repeat("b", 64)))
	var answer struct{ Agents []map[string]any }
	if err := json.Unmarshal(f.call("GET", "/v1/agents", nil).Body.Bytes(), &answer); err != nil {
		t.Fatal(err)
	}
	byID := map[string]map[string]any{}
	for _, agent := range answer.Agents {
		byID[agent["id"].(string)] = agent
	}
	for _, id := range []string{"kimi", "opencode"} {
		if agent := byID[id]; agent["supported"] != false || agent["verified"] != false || agent["state"] != "notInstalled" {
			t.Errorf("%s %v", id, agent)
		}
		if w := f.call("POST", "/v1/agents/install", map[string]any{"id": id}); w.Code != 400 || !strings.Contains(w.Body.String(), "unsupported_platform") {
			t.Errorf("install %s: %d %s", id, w.Code, w.Body)
		}
	}
	for id, verified := range map[string]bool{"cursor": false, "goose": true, "claude": true, "codex": true} {
		if _, present := byID[id]["supported"]; present || byID[id]["verified"] != verified {
			t.Errorf("%s %v", id, byID[id])
		}
	}
}

func TestCatalogChangeRefusals(t *testing.T) {
	bin := t.TempDir()
	gemini := writeScript(t, filepath.Join(bin, "gemini"), "exit 0\n")
	f := newCatalogFixture(t, map[string]string{"gemini": gemini, "amp": writeScript(t, filepath.Join(bin, "amp"), "exit 0\n")}, nil)
	other := "linux-x86_64"
	if agentPlatform() == other {
		other = "linux-aarch64"
	}
	var kimi map[string]any
	json.Unmarshal([]byte(`{"id":"kimi","name":"Kimi CLI","version":"1.52.0","distribution":{"binary":{"`+other+`":{"archive":"https://example.com/k.tar.gz","cmd":"./kimi"}}}}`), &kimi)
	f.registry.setAgents(f.fakeAgentEntry("cursor", "1.0.0", "/cursor.tar.gz", ""), kimi)
	f.agents()
	cases := []struct {
		path   string
		body   any
		status int
		code   string
	}{
		{"/v1/agents/install", map[string]any{"id": "claude"}, 409, "not_managed"},
		{"/v1/agents/update", map[string]any{"id": "codex"}, 409, "not_managed"},
		{"/v1/agents/uninstall", map[string]any{"id": "gemini"}, 409, "not_managed"},
		{"/v1/agents/update", map[string]any{"id": "amp"}, 409, "not_managed"},
		{"/v1/agents/install", map[string]any{"id": "amp"}, 409, "not_managed"},
		{"/v1/agents/install", map[string]any{"id": "nobody"}, 404, "unknown_agent"},
		{"/v1/agents/install", map[string]any{"id": "kimi"}, 400, "unsupported_platform"},
		{"/v1/agents/install", map[string]any{"id": "cursor"}, 400, "unverified_download"},
		{"/v1/agents/install", map[string]any{"id": "cursor", "extra": true}, 400, "invalid_request"},
		{"/v1/agents/uninstall", map[string]any{"id": "cursor", "allowUnverified": true}, 400, "invalid_request"},
		{"/v1/agents/update", map[string]any{"id": "cursor"}, 202, ""},
		{"/v1/agents/uninstall", map[string]any{"id": "cursor"}, 202, ""},
	}
	for _, test := range cases {
		w := f.call("POST", test.path, test.body)
		if w.Code != test.status || (test.code != "" && !strings.Contains(w.Body.String(), `"code":"`+test.code+`"`)) {
			t.Errorf("%s %v: %d %s, want %d %s", test.path, test.body, w.Code, w.Body, test.status, test.code)
		}
	}
	// A host without the catalog answers 501.
	plain, store, _ := testHost(t)
	token := paired(t, plain, store)
	if w := request(t, plain.Handler(), "GET", "/v1/agents", token, nil); w.Code != 501 || !strings.Contains(w.Body.String(), "agents_unavailable") {
		t.Fatalf("no catalog %d %s", w.Code, w.Body)
	}
	var capabilities map[string]any
	json.Unmarshal(request(t, plain.Handler(), "GET", "/v1/capabilities", token, nil).Body.Bytes(), &capabilities)
	if _, listed := capabilities["agents"]; listed {
		t.Fatalf("capabilities without a catalog %v", capabilities)
	}
}

func TestCatalogTerminalsForAgents(t *testing.T) {
	bin := t.TempDir()
	goose := writeScript(t, filepath.Join(bin, "goose"), "exit 0\n")
	f := newCatalogFixture(t, map[string]string{"goose": goose, "node": filepath.Join(bin, "node")}, nil)
	// A registry install of an npm package with ACP arguments has a terminal;
	// one without arguments (an ACP-only server) has none.
	store := f.host.agents.store
	for id, args := range map[string][]string{"gemini": {"--acp"}, "pi-acp": {}} {
		if err := store.ensureAgentDir(id); err != nil {
			t.Fatal(err)
		}
		command := writeScript(t, filepath.Join(store.versionDir(id, "1.0.0"), "node_modules", ".bin", id), "exit 0\n")
		if err := store.writeCurrent(id, agentCurrent{Version: "1.0.0", Command: command, Args: args, Kind: "npx", Name: id, Env: map[string]string{"NO_UPDATE": "1"}, InstalledAt: chatTimeOf(time.Now())}); err != nil {
			t.Fatal(err)
		}
	}
	var capabilities struct{ TerminalPrograms []string }
	json.Unmarshal(f.call("GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if !reflect.DeepEqual(capabilities.TerminalPrograms, []string{"shell", "gemini", "goose"}) {
		t.Fatalf("terminal programs %v", capabilities.TerminalPrograms)
	}
	for _, program := range []string{"gemini", "goose"} {
		w := f.call("POST", "/v1/terminals", map[string]any{"projectId": "p1", "title": "Agent", "rows": 24, "cols": 80, "program": program})
		if w.Code != 201 {
			t.Fatalf("%s terminal %d %s", program, w.Code, w.Body)
		}
	}
	if w := f.call("POST", "/v1/terminals", map[string]any{"projectId": "p1", "title": "Agent", "rows": 24, "cols": 80, "program": "pi-acp"}); w.Code != 400 {
		t.Fatalf("an ACP-only agent's terminal %d %s", w.Code, w.Body)
	}
	f.terminals.mu.Lock()
	spawns := slices.Clone(f.terminals.spawns)
	f.terminals.mu.Unlock()
	if len(spawns) != 2 || spawns[0].Path != filepath.Join(store.versionDir("gemini", "1.0.0"), "node_modules", ".bin", "gemini") || len(spawns[0].Args) != 0 || !slices.Contains(spawns[0].Env, "NO_UPDATE=1") ||
		!slices.ContainsFunc(spawns[0].Env, func(item string) bool { return strings.HasPrefix(item, "PATH="+bin+string(os.PathListSeparator)) }) {
		t.Fatalf("gemini launch %+v", spawns)
	}
	if spawns[1].Path != goose || spawns[1].Args != nil || slices.Contains(spawns[1].Env, "NO_UPDATE=1") {
		t.Fatalf("goose launch %+v", spawns[1])
	}
	// The terminal is the agent's: its updates wait.
	if !f.host.agentBusy("gemini") || f.host.agentBusy("pi-acp") {
		t.Fatal("busy by terminal")
	}
	// idleForSeconds follows terminals too.
	if f.host.agents.idleForSeconds() != 0 {
		t.Fatal("idle while terminals run")
	}
}

// statusAgent is an OpenCode whose session status answers, fails or answers
// late.
type statusAgent struct {
	*fakeAgent
	mu    sync.Mutex
	fail  bool
	delay time.Duration
	busy  int
}

func (a *statusAgent) sessionStatuses(Project) (map[string]ocStatus, error) {
	a.mu.Lock()
	fail, delay, busy := a.fail, a.delay, a.busy
	a.mu.Unlock()
	time.Sleep(delay)
	if fail {
		return nil, errors.New("OpenCode did not answer")
	}
	statuses := map[string]ocStatus{"idle": {Type: "idle"}}
	for index := range busy {
		statuses[fmt.Sprintf("busy%d", index)] = ocStatus{Type: "busy"}
	}
	return statuses, nil
}

func (a *statusAgent) set(fail bool, delay time.Duration, busy int) {
	a.mu.Lock()
	a.fail, a.delay, a.busy = fail, delay, busy
	a.mu.Unlock()
}

// An OpenCode status query that fails or takes longer than 2 s counts as a
// turn running: OpenCode is busy for its updates and nothing is idle, since
// a stuck OpenCode may be in the middle of a turn. The workspaces' counts
// stay as they were (none of its chats counted).
func TestOpenCodeUnansweredCountsAsBusy(t *testing.T) {
	_, store, fake := testHost(t)
	agent := &statusAgent{fakeAgent: fake}
	host := newHost(store, agent, HostOptions{Agents: &AgentOptions{Version: "test"}})
	quietAgents(host.agents, nil, nil, nil)
	t.Cleanup(func() {
		host.Close()
		host.agents.close()
	})
	catalog := host.agents
	now := time.Now()
	var mu sync.Mutex
	catalog.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	later := func(by time.Duration) {
		mu.Lock()
		now = now.Add(by)
		mu.Unlock()
	}
	later(90 * time.Second)
	if host.agentBusy("opencode") || catalog.idleForSeconds() != 90 {
		t.Fatal("busy while OpenCode answers idle")
	}
	agent.set(false, 0, 1)
	if !host.agentBusy("opencode") || catalog.idleForSeconds() != 0 {
		t.Fatal("idle while an OpenCode turn runs")
	}
	agent.set(true, 0, 0)
	later(90 * time.Second)
	if !host.agentBusy("opencode") || catalog.idleForSeconds() != 0 {
		t.Fatal("idle while OpenCode's status fails")
	}
	if details := host.projectDetails([]Project{mustProject(t, store)}); details[0].Activity.BusyChats != 0 {
		t.Fatalf("workspace details %+v", details[0].Activity)
	}
	agent.set(false, workspaceActivityWait+500*time.Millisecond, 0)
	later(90 * time.Second)
	if !host.agentBusy("opencode") || catalog.idleForSeconds() != 0 {
		t.Fatal("idle while OpenCode's status is late")
	}
	if host.agentBusy("goose") {
		t.Fatal("another agent waits for OpenCode")
	}
	agent.set(false, 0, 0)
	later(30 * time.Second)
	if host.agentBusy("opencode") || catalog.idleForSeconds() != 30 {
		t.Fatal("not idle once OpenCode answers again")
	}
}

func TestCatalogIdleAndRestart(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	catalog := f.host.agents
	now := time.Now()
	runs := true
	var mu sync.Mutex
	catalog.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	catalog.anythingRunsFor = func() bool { mu.Lock(); defer mu.Unlock(); return runs }
	catalog.runningOpenCode = func() string { return "1.18.31" }
	if idle := catalog.idleForSeconds(); idle != 0 {
		t.Fatalf("idle %d while something runs", idle)
	}
	mu.Lock()
	runs, now = false, now.Add(90*time.Second)
	mu.Unlock()
	if idle := catalog.idleForSeconds(); idle != 90 {
		t.Fatalf("idle %d, want 90", idle)
	}
	if catalog.restartWanted(t.Context()) {
		t.Fatal("a restart without a managed OpenCode")
	}
	store := catalog.store
	if err := store.ensureAgentDir("opencode"); err != nil {
		t.Fatal(err)
	}
	command := writeScript(t, filepath.Join(store.versionDir("opencode", "1.18.32"), "opencode"), "exit 0\n")
	if err := store.writeCurrent("opencode", agentCurrent{Version: "1.18.32", Command: command, Args: []string{"acp"}, Kind: "binary", SHA256: strings.Repeat("c", 64), InstalledAt: chatTimeOf(now)}); err != nil {
		t.Fatal(err)
	}
	if !catalog.restartWanted(t.Context()) {
		t.Fatal("no restart for a newer managed OpenCode")
	}
	catalog.runningOpenCode = func() string { return "1.18.32" }
	if catalog.restartWanted(t.Context()) {
		t.Fatal("a restart for the running version")
	}
	catalog.runningOpenCode = func() string { return "1.19.0" }
	if catalog.restartWanted(t.Context()) {
		t.Fatal("a restart for an older managed OpenCode")
	}
	var local catalogAnswer
	json.Unmarshal(f.local("GET", "/v1/agents", nil).Body.Bytes(), &local)
	for _, agent := range local.Agents {
		if agent.ID == "opencode" && (agent.Source != "registry" || agent.InstalledVersion != "1.18.32" || agent.RestartWanted == nil || *agent.RestartWanted || *agent.IdleForSeconds != 90) {
			t.Fatalf("opencode %+v", agent)
		}
	}
	for _, test := range []struct {
		a, b  string
		newer bool
	}{{"1.18.32", "1.18.31", true}, {"1.18.31", "1.18.32", false}, {"1.10.0", "1.9.9", true}, {"2026.09.18", "2026.09.1", true}, {"1.0.0", "1.0.0", false}, {"1.0.0-beta", "1.0.0", false}, {"abc", "1.0.0", true}} {
		if got := agentVersionNewer(test.a, test.b); got != test.newer {
			t.Errorf("%s newer than %s: %v", test.a, test.b, got)
		}
	}
}
