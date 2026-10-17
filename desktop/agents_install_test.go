package host

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// versionsOf lists an agent's version folders.
func versionsOf(t *testing.T, store agentStore, id string) []string {
	t.Helper()
	entries, err := os.ReadDir(store.agentDir(id))
	if err != nil {
		return nil
	}
	var versions []string
	for _, entry := range entries {
		if entry.IsDir() {
			versions = append(versions, entry.Name())
		}
	}
	sort.Strings(versions)
	return versions
}

func TestInstallBinaryAgent(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	enableAutomaticFor(t, f)
	f.answerInitialize()
	archive := f.fakeAgentArchive()
	f.registry.setFile("/goose-1.0.0.tar.gz", archive)
	f.registry.setAgents(f.fakeAgentEntry("goose", "1.0.0", "/goose-1.0.0.tar.gz", sha256Hex(archive)))
	w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"})
	var accepted agentJSON
	json.Unmarshal(w.Body.Bytes(), &accepted)
	if w.Code != 202 || accepted.State != "installing" {
		t.Fatalf("install %d %s", w.Code, w.Body)
	}
	agent := f.waitSettled("goose")
	if agent.State != "installed" || agent.Source != "registry" || agent.InstalledVersion != "1.0.0" || agent.UpdatedAt == "" || agent.LastError != "" || !agent.AutoUpdates || !agent.Verified || !agent.Chat || !agent.Terminal {
		t.Fatalf("installed %+v", agent)
	}
	store := f.host.agents.store
	current, err := store.readCurrent("goose")
	if err != nil || current == nil {
		t.Fatal(err)
	}
	command := filepath.Join(store.versionDir("goose", "1.0.0"), "agent")
	if current.Command != command || !reflect.DeepEqual(current.Args, []string{"acp"}) || current.Kind != "binary" || current.Unverified || current.Env["AGENTLAND_FAKE_AGENT"] != "acp" {
		t.Fatalf("current.json %+v", current)
	}
	// sha256 is the command file's, not the archive's.
	data, _ := os.ReadFile(command)
	if current.SHA256 != sha256Hex(data) || current.SHA256 == sha256Hex(archive) {
		t.Fatalf("sha256 %s", current.SHA256)
	}
	for _, folder := range []string{store.root, store.agentDir("goose"), store.versionDir("goose", "1.0.0")} {
		if info, err := os.Lstat(folder); err != nil || info.Mode().Perm() != 0o700 {
			t.Fatalf("%s %v %v", folder, info.Mode(), err)
		}
	}
	if info, _ := os.Stat(command); info.Mode().Perm() != 0o700 {
		t.Fatalf("command %v", info.Mode())
	}
	if info, _ := os.Stat(filepath.Join(store.versionDir("goose", "1.0.0"), "README")); info.Mode().Perm() != 0o600 {
		t.Fatalf("file %v", info.Mode())
	}
	// The check sent initialize, with no client capabilities, in a clean
	// environment with the agent's own variables.
	var record struct {
		Argv []string
		Env  map[string]string
	}
	raw, _ := os.ReadFile(filepath.Join(f.dir, "argv-1.json"))
	json.Unmarshal(raw, &record)
	if !reflect.DeepEqual(record.Argv, []string{"acp"}) || record.Env["AGENTLAND_SECRET_PROBE"] != "" || record.Env["OPENCODE_SERVER_PASSWORD"] != "" || record.Env["AGENTLAND_FAKE_ACP_DIR"] != f.dir {
		t.Fatalf("check start %+v", record)
	}
	frames, _ := os.ReadFile(filepath.Join(f.dir, "frames-1.jsonl"))
	if !strings.Contains(string(frames), `"method":"initialize","params":{"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},"protocolVersion":1}`) || strings.Contains(string(frames), "session/new") {
		t.Fatalf("check frames %s", frames)
	}
	// Installing again at the same version does nothing.
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 202 || f.registry.hitsOf("/goose-1.0.0.tar.gz") != 1 {
		t.Fatalf("again %d, downloads %d", w.Code, f.registry.hitsOf("/goose-1.0.0.tar.gz"))
	}
	// The agent chats and has a terminal.
	var capabilities struct {
		ChatProviders    []string
		TerminalPrograms []string
	}
	json.Unmarshal(f.call("GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if !reflect.DeepEqual(capabilities.ChatProviders, []string{"opencode", "goose"}) || !reflect.DeepEqual(capabilities.TerminalPrograms, []string{"shell", "goose"}) {
		t.Fatalf("capabilities %+v", capabilities)
	}
	// While an uninstall runs the agent is uninstalling (the change is held
	// here to see it).
	op, err := f.host.agents.beginOp("goose", "uninstall")
	if err != nil {
		t.Fatal(err)
	}
	if agent := f.agent("goose"); agent.State != "uninstalling" || agent.InstalledVersion != "1.0.0" {
		t.Fatalf("during an uninstall %+v", agent)
	}
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"}); w.Code != 409 || !strings.Contains(w.Body.String(), "agent_busy") {
		t.Fatalf("install during an uninstall %d %s", w.Code, w.Body)
	}
	f.host.agents.endOp("goose", op)
	// Uninstall answers uninstalling, removes the folder, and the agent is
	// installable again.
	w = f.call("POST", "/v1/agents/uninstall", map[string]any{"id": "goose"})
	json.Unmarshal(w.Body.Bytes(), &accepted)
	if w.Code != 202 || accepted.State != "uninstalling" {
		t.Fatalf("uninstall %d %s", w.Code, w.Body)
	}
	waitFor(t, "the uninstall", func() bool { _, err := os.Stat(store.agentDir("goose")); return errors.Is(err, os.ErrNotExist) })
	if agent := f.waitSettled("goose"); agent.State != "notInstalled" || agent.InstalledVersion != "" {
		t.Fatalf("after uninstall %+v", agent)
	}
}

func TestInstallBinaryFailures(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	archive := f.fakeAgentArchive()
	f.registry.setFile("/agent.tar.gz", archive)
	escape := tarGz(t, archiveEntry{name: "./agent", body: "x", mode: 0o755}, archiveEntry{name: "./up", link: "../../../../etc"})
	f.registry.setFile("/escape.tar.gz", escape)
	f.registry.setFile("/nocmd.tar.gz", tarGz(t, archiveEntry{name: "./other", body: "x"}))
	f.registry.setAgents(
		f.fakeAgentEntry("wrongsum", "1.0.0", "/agent.tar.gz", strings.Repeat("0", 64)),
		f.fakeAgentEntry("escape", "1.0.0", "/escape.tar.gz", sha256Hex(escape)),
		f.fakeAgentEntry("nocmd", "1.0.0", "/nocmd.tar.gz", ""),
		f.fakeAgentEntry("missing", "1.0.0", "/missing.tar.gz", strings.Repeat("1", 64)),
		f.fakeAgentEntry("unverified", "1.0.0", "/agent.tar.gz", ""),
	)
	wantFailure := func(id, message string) {
		t.Helper()
		agent := f.waitSettled(id)
		if agent.State != "failed" || !strings.Contains(agent.LastError, message) || agent.InstalledVersion != "" {
			t.Fatalf("%s: %+v", id, agent)
		}
		if versions := versionsOf(t, f.host.agents.store, id); len(versions) != 0 {
			t.Fatalf("%s left %v", id, versions)
		}
	}
	f.call("POST", "/v1/agents/install", map[string]any{"id": "wrongsum"})
	wantFailure("wrongsum", "SHA-256 does not match")
	f.call("POST", "/v1/agents/install", map[string]any{"id": "escape"})
	wantFailure("escape", "The archive was refused")
	f.call("POST", "/v1/agents/install", map[string]any{"id": "missing"})
	wantFailure("missing", "The download failed")
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "nocmd"}); w.Code != 400 || !strings.Contains(w.Body.String(), "unverified_download") {
		t.Fatalf("no checksum %d %s", w.Code, w.Body)
	}
	f.call("POST", "/v1/agents/install", map[string]any{"id": "nocmd", "allowUnverified": true})
	wantFailure("nocmd", "does not hold its command")
	// With the owner's confirmation an unverified download installs, and
	// says so.
	f.call("POST", "/v1/agents/install", map[string]any{"id": "unverified", "allowUnverified": true})
	if agent := f.waitSettled("unverified"); agent.State != "installed" || agent.Verified {
		t.Fatalf("unverified %+v", agent)
	}
	if current, _ := f.host.agents.store.readCurrent("unverified"); current == nil || !current.Unverified {
		t.Fatalf("current %+v", current)
	}
	// lastError survives a restart, until an install succeeds.
	restarted := newAgentCatalog(f.host, f.store.Path, AgentOptions{})
	quietAgents(restarted, nil, nil, f.registry.server)
	restarted.loadRegistry()
	if view, ok := restarted.agent("wrongsum", false); !ok || view.State != "failed" || !strings.Contains(view.LastError, "SHA-256") {
		t.Fatalf("after a restart %+v", view)
	}
	// A check that fails keeps the agent out.
	f.registry.setAgents(f.fakeAgentEntry("badcheck", "1.0.0", "/agent.tar.gz", sha256Hex(archive)))
	os.WriteFile(filepath.Join(f.dir, "script.jsonl"), []byte(`{"do":"await","method":"initialize"}`+"\n"+`{"do":"reply","result":{"protocolVersion":2}}`+"\n"), 0o600)
	f.agents()
	f.host.agents.mu.Lock()
	f.host.agents.fetchedAt = time.Time{}
	f.host.agents.lastAttempt = time.Time{}
	f.host.agents.mu.Unlock()
	f.host.agents.refresh(t.Context())
	f.call("POST", "/v1/agents/install", map[string]any{"id": "badcheck"})
	wantFailure("badcheck", "does not speak ACP protocol version 1")
}

// fakeNPM is an npm that records its arguments and environment and installs
// a package whose bin runs the fake ACP agent.
func fakeNPM(t *testing.T, folder, record, self string) string {
	t.Helper()
	return writeScript(t, filepath.Join(folder, "npm"), `
printf '%s\n' "$@" > '`+record+`.args'
env > '`+record+`.env'
[ "$1" = install ] || exit 9
prefix="$3"
pkg="$6"
name="${pkg%@*}"
mkdir -p "$prefix/node_modules/$name" "$prefix/node_modules/.bin"
printf '{"name":"%s","bin":{"gemini":"cli.js"}}' "$name" > "$prefix/node_modules/$name/package.json"
printf '#!/bin/sh\nexec %s "$@"\n' "'`+self+`'" > "$prefix/node_modules/$name/cli.js"
chmod 755 "$prefix/node_modules/$name/cli.js"
ln -s "../$name/cli.js" "$prefix/node_modules/.bin/gemini"
echo "added 1 package"
`)
}

func TestInstallNPMAndUV(t *testing.T) {
	bin := t.TempDir()
	records := t.TempDir()
	self, _ := os.Executable()
	npm := fakeNPM(t, bin, filepath.Join(records, "npm"), self)
	node := writeScript(t, filepath.Join(bin, "node"), "exit 0\n")
	uv := writeScript(t, filepath.Join(bin, "uv"), `
printf '%s\n' "$@" > '`+filepath.Join(records, "uv")+`.args'
env > '`+filepath.Join(records, "uv")+`.env'
mkdir -p "$UV_TOOL_DIR/fast-agent-acp/bin" "$UV_TOOL_BIN_DIR"
printf '#!/bin/sh\nexec %s "$@"\n' "'`+self+`'" > "$UV_TOOL_DIR/fast-agent-acp/bin/fast-agent-acp"
chmod 755 "$UV_TOOL_DIR/fast-agent-acp/bin/fast-agent-acp"
ln -s "$UV_TOOL_DIR/fast-agent-acp/bin/fast-agent-acp" "$UV_TOOL_BIN_DIR/fast-agent-acp"
`)
	f := newCatalogFixture(t, map[string]string{"npm": npm, "node": node, "uv": uv}, nil)
	f.answerInitialize()
	env := map[string]string{"AGENTLAND_FAKE_AGENT": "acp", "AGENTLAND_FAKE_ACP_DIR": f.dir}
	f.registry.setAgents(
		map[string]any{"id": "gemini", "name": "Gemini CLI", "version": "0.61.0", "distribution": map[string]any{"npx": map[string]any{"package": "@google/gemini-cli@0.61.0", "args": []string{"--acp"}, "env": env}}},
		map[string]any{"id": "fast-agent", "name": "fast-agent", "version": "0.10.1", "distribution": map[string]any{"uvx": map[string]any{"package": "fast-agent-acp==0.10.1", "args": []string{"-x"}, "env": env}}},
	)
	f.agents()
	f.call("POST", "/v1/agents/install", map[string]any{"id": "gemini"})
	if agent := f.waitSettled("gemini"); agent.State != "installed" || !agent.Verified || !agent.Terminal {
		t.Fatalf("gemini %+v", agent)
	}
	store := f.host.agents.store
	folder := store.versionDir("gemini", "0.61.0")
	args, _ := os.ReadFile(filepath.Join(records, "npm.args"))
	if string(args) != strings.Join([]string{"install", "--prefix", folder, "--no-audit", "--no-fund", "@google/gemini-cli@0.61.0"}, "\n")+"\n" {
		t.Fatalf("npm args %q", args)
	}
	npmEnv, _ := os.ReadFile(filepath.Join(records, "npm.env"))
	if strings.Contains(string(npmEnv), "must-not-leak") || !strings.Contains(string(npmEnv), "PATH="+bin+":") {
		t.Fatalf("npm env %s", npmEnv)
	}
	current, _ := store.readCurrent("gemini")
	if current == nil || current.Command != filepath.Join(folder, "node_modules", ".bin", "gemini") || current.Kind != "npx" || current.SHA256 != "" || !reflect.DeepEqual(current.Args, []string{"--acp"}) {
		t.Fatalf("gemini current %+v", current)
	}
	f.call("POST", "/v1/agents/install", map[string]any{"id": "fast-agent"})
	if agent := f.waitSettled("fast-agent"); agent.State != "installed" {
		t.Fatalf("fast-agent %+v", agent)
	}
	folder = store.versionDir("fast-agent", "0.10.1")
	args, _ = os.ReadFile(filepath.Join(records, "uv.args"))
	uvEnv, _ := os.ReadFile(filepath.Join(records, "uv.env"))
	if string(args) != "tool\ninstall\nfast-agent-acp==0.10.1\n" || !strings.Contains(string(uvEnv), "UV_TOOL_DIR="+filepath.Join(folder, "tools")) || !strings.Contains(string(uvEnv), "UV_TOOL_BIN_DIR="+filepath.Join(folder, "bin")) || strings.Contains(string(uvEnv), "must-not-leak") {
		t.Fatalf("uv %q %s", args, uvEnv)
	}
	if current, _ := store.readCurrent("fast-agent"); current == nil || current.Command != filepath.Join(folder, "bin", "fast-agent-acp") || current.Kind != "uvx" {
		t.Fatalf("fast-agent current %+v", current)
	}
	// Without npm the install fails and says why.
	lookup := f.host.agents.lookup
	f.host.agents.lookup = func(program string) (string, bool) {
		if program == "npm" || program == "uv" {
			return "", false
		}
		return lookup(program)
	}
	f.registry.setAgents(map[string]any{"id": "qwen-code", "name": "Qwen Code", "version": "0.24.6", "distribution": map[string]any{"npx": map[string]any{"package": "@qwen-code/qwen-code@0.24.6", "args": []string{"--acp"}}}})
	f.host.agents.mu.Lock()
	f.host.agents.fetchedAt, f.host.agents.lastAttempt = time.Time{}, time.Time{}
	f.host.agents.mu.Unlock()
	f.host.agents.refresh(t.Context())
	f.call("POST", "/v1/agents/install", map[string]any{"id": "qwen-code"})
	if agent := f.waitSettled("qwen-code"); agent.State != "failed" || !strings.Contains(agent.LastError, "npm (Node.js) was not found") {
		t.Fatalf("no npm %+v", agent)
	}
	// An npm that fails: its last line explains.
	failing := writeScript(t, filepath.Join(t.TempDir(), "npm"), "echo 'npm ERR! 404 Not Found - @qwen-code/qwen-code' >&2\nexit 1\n")
	f.host.agents.lookup = func(program string) (string, bool) {
		if program == "npm" {
			return failing, true
		}
		return lookup(program)
	}
	f.call("POST", "/v1/agents/install", map[string]any{"id": "qwen-code"})
	if agent := f.waitSettled("qwen-code"); agent.State != "failed" || agent.LastError != "npm failed: 404 Not Found - @qwen-code/qwen-code" {
		t.Fatalf("npm failing %+v", agent)
	}
}

// npm ends every failure with the path of its log under the Mac user's home.
// lastError gives npm's first error line with a reason instead, and paths
// under the home are written as ~.
func TestInstallerFailureGivesTheReason(t *testing.T) {
	home := "/Users/owner"
	for _, test := range []struct{ name, output, want string }{
		{"npm 10, not found", `npm warn deprecated inflight@1.0.6: not supported
npm error code E404
npm error 404 Not Found - GET https://registry.npmjs.org/@qwen-code%2fqwen-code - Not found
npm error 404
npm error 404  '@qwen-code/qwen-code@0.24.6' is not in this registry.
npm error A complete log of this run can be found in: /Users/owner/.npm/_logs/2026-09-27T08_00_00_000Z-debug-0.log`,
			"404 Not Found - GET https://registry.npmjs.org/@qwen-code%2fqwen-code - Not found"},
		{"npm 10, permissions", `npm error code EACCES
npm error syscall mkdir
npm error path /Users/owner/.npm/_cacache/index-v5
npm error errno -13
npm error Error: EACCES: permission denied, mkdir '/Users/owner/.npm/_cacache/index-v5'
npm error A complete log of this run can be found in: /Users/owner/.npm/_logs/x-debug-0.log`,
			"Error: EACCES: permission denied, mkdir '~/.npm/_cacache/index-v5'"},
		{"npm 6", `npm ERR! code ETARGET
npm ERR! notarget No matching version found for gemini@9.9.9.
npm ERR! A complete log of this run can be found in:
npm ERR!     /Users/owner/.npm/_logs/2020-01-01T00_00_00_000Z-debug.log`,
			"notarget No matching version found for gemini@9.9.9."},
		{"npm with nothing but its codes", "npm error code E500\nnpm error A complete log of this run can be found in: /Users/owner/.npm/_logs/y.log", "npm error code E500"},
		{"uv", "  × No solution found when resolving dependencies:\n  ╰─▶ Because fast-agent-acp==9.9.9 was not found, requirements are unsatisfiable.", "╰─▶ Because fast-agent-acp==9.9.9 was not found, requirements are unsatisfiable."},
		{"silent", "\n\n", "no output"},
	} {
		if got := withoutHomes(installerFailure(test.output), []string{home}); got != test.want {
			t.Errorf("%s: %q, want %q", test.name, got, test.want)
		}
	}
	for text, want := range map[string]string{
		"/Users/owner":                "~",
		"at /Users/owner/.npm: x":     "at ~/.npm: x",
		"'/Users/owner/a b'":          "'~/a b'",
		"/Users/owner2/.npm":          "/Users/owner2/.npm",
		"/private/Users/owner/x":      "/private/Users/owner/x",
		"/Users/owner/x /Users/owner": "~/x ~",
		"/Users/owner/Users/owner/x":  "~/Users/owner/x",
	} {
		if got := withoutHomes(text, []string{home}); got != want {
			t.Errorf("%q: %q, want %q", text, got, want)
		}
	}
	// Through the catalog: the home npm runs with is written as ~ too.
	installerHome := filepath.Clean(os.TempDir())
	npm := writeScript(t, filepath.Join(t.TempDir(), "npm"), "cat >&2 <<'EOF'\nnpm error code EACCES\nnpm error Error: EACCES: permission denied, mkdir '"+filepath.Join(installerHome, ".npm", "_cacache")+"'\nnpm error A complete log of this run can be found in: "+filepath.Join(installerHome, ".npm", "_logs", "z.log")+"\nEOF\nexit 1\n")
	f := newCatalogFixture(t, map[string]string{"npm": npm}, nil)
	f.registry.setAgents(map[string]any{"id": "qwen-code", "name": "Qwen Code", "version": "0.24.6", "distribution": map[string]any{"npx": map[string]any{"package": "@qwen-code/qwen-code@0.24.6", "args": []string{"--acp"}}}})
	f.agents()
	f.call("POST", "/v1/agents/install", map[string]any{"id": "qwen-code"})
	agent := f.waitSettled("qwen-code")
	if agent.LastError != "npm failed: Error: EACCES: permission denied, mkdir '~/.npm/_cacache'" {
		t.Fatalf("lastError %q", agent.LastError)
	}
	// A status an earlier host wrote with a home path is shown without it.
	if err := f.host.agents.store.setStatus("qwen-code", "npm failed: npm error A complete log of this run can be found in: "+filepath.Join(installerHome, ".npm", "_logs", "z.log"), time.Now()); err != nil {
		t.Fatal(err)
	}
	if lastError := f.agent("qwen-code").LastError; strings.Contains(lastError, installerHome) {
		t.Fatalf("lastError %q", lastError)
	}
}

func TestAutomaticUpdates(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	enableAutomaticFor(t, f)
	f.answerInitialize()
	catalog := f.host.agents
	archive := f.fakeAgentArchive()
	for _, version := range []string{"1.0.0", "1.1.0", "1.2.0", "1.3.0", "1.4.0"} {
		f.registry.setFile("/goose-"+version+".tar.gz", archive)
	}
	publish := func(version, sum string) {
		f.registry.setAgents(f.fakeAgentEntry("goose", version, "/goose-"+version+".tar.gz", sum))
		catalog.mu.Lock()
		catalog.fetchedAt, catalog.lastAttempt = time.Time{}, time.Time{}
		catalog.mu.Unlock()
		if err := catalog.refresh(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	publish("1.0.0", sha256Hex(archive))
	f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"})
	f.waitSettled("goose")
	// An update waits while the agent is busy.
	var busy atomic.Bool
	busy.Store(true)
	var polls atomic.Int32
	catalog.agentBusyFor = func(id string) bool {
		polls.Add(1)
		return busy.Load()
	}
	catalog.idlePoll = 20 * time.Millisecond
	publish("1.1.0", sha256Hex(archive))
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "goose"}); w.Code != 409 || !strings.Contains(w.Body.String(), "agent_busy") {
		t.Fatalf("update while busy %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/agents/uninstall", map[string]any{"id": "goose"}); w.Code != 409 {
		t.Fatalf("uninstall while busy %d %s", w.Code, w.Body)
	}
	done := make(chan struct{})
	go func() {
		catalog.updateRun()
		close(done)
	}()
	waitFor(t, "a few idle checks", func() bool { return polls.Load() >= 3 })
	if current, _ := catalog.store.readCurrent("goose"); current.Version != "1.0.0" {
		t.Fatalf("updated while busy: %s", current.Version)
	}
	busy.Store(false)
	<-done
	current, _ := catalog.store.readCurrent("goose")
	if current.Version != "1.1.0" || current.Previous == nil || current.Previous.Version != "1.0.0" {
		t.Fatalf("after the update %+v", current)
	}
	if versions := versionsOf(t, catalog.store, "goose"); !reflect.DeepEqual(versions, []string{"1.0.0", "1.1.0"}) {
		t.Fatalf("versions %v", versions)
	}
	// The next update keeps two versions.
	publish("1.2.0", sha256Hex(archive))
	catalog.updateRun()
	if versions := versionsOf(t, catalog.store, "goose"); !reflect.DeepEqual(versions, []string{"1.1.0", "1.2.0"}) {
		t.Fatalf("versions %v", versions)
	}
	agent := f.agent("goose")
	if agent.InstalledVersion != "1.2.0" || agent.PreviousVersion != "1.1.0" || agent.LatestVersion != "1.2.0" || agent.LastError != "" {
		t.Fatalf("agent %+v", agent)
	}
	// A new version that fails its check is rolled back: the current one
	// stays, the new folder goes, lastError says why.
	os.WriteFile(filepath.Join(f.dir, "script.jsonl"), []byte(`{"do":"exit","code":3}`+"\n"), 0o600)
	publish("1.3.0", sha256Hex(archive))
	catalog.updateRun()
	current, _ = catalog.store.readCurrent("goose")
	agent = f.agent("goose")
	if current.Version != "1.2.0" || agent.State != "installed" || !strings.Contains(agent.LastError, "ended before it answered initialize") {
		t.Fatalf("after a failed check %+v %+v", current, agent)
	}
	if versions := versionsOf(t, catalog.store, "goose"); !reflect.DeepEqual(versions, []string{"1.1.0", "1.2.0"}) {
		t.Fatalf("versions after a rollback %v", versions)
	}
	// A download without a checksum waits for the owner.
	f.answerInitialize()
	publish("1.4.0", "")
	catalog.updateRun()
	if current, _ = catalog.store.readCurrent("goose"); current.Version != "1.2.0" || !strings.Contains(f.agent("goose").LastError, "update it by hand") {
		t.Fatalf("unverified update %+v", current)
	}
	if w := f.call("POST", "/v1/agents/update", map[string]any{"id": "goose"}); w.Code != 400 || !strings.Contains(w.Body.String(), "unverified_download") {
		t.Fatalf("update to an unverified download %d %s", w.Code, w.Body)
	}
	f.call("POST", "/v1/agents/update", map[string]any{"id": "goose", "allowUnverified": true})
	if agent := f.waitSettled("goose"); agent.InstalledVersion != "1.4.0" || agent.Verified || agent.LastError != "" {
		t.Fatalf("after the owner's update %+v", agent)
	}
	// The updater runs on its own: first after firstRun, then every period.
	// (Its start also tries to install OpenCode, which this registry lacks.)
	catalog.firstRun, catalog.every = 10*time.Millisecond, time.Hour
	catalog.jitter = func() time.Duration { return 0 }
	f.registry.setAgents(f.fakeAgentEntry("goose", "1.5.0", "/goose-1.0.0.tar.gz", sha256Hex(archive)))
	catalog.start()
	waitFor(t, "the first run's update", func() bool {
		current, _ := catalog.store.readCurrent("goose")
		return current != nil && current.Version == "1.5.0"
	})
}

// Versions that differ only by case name one folder on macOS: they are one
// version. An install never removes the current or the previous version's
// folder; when the registry names the previous version again, the kept one is
// checked and made current.
func TestInstallVersionsDifferingByCase(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	enableAutomaticFor(t, f)
	f.answerInitialize()
	catalog := f.host.agents
	archive := f.fakeAgentArchive()
	f.registry.setFile("/goose.tar.gz", archive)
	publish := func(version, sum string) {
		t.Helper()
		f.registry.setAgents(f.fakeAgentEntry("goose", version, "/goose.tar.gz", sum))
		catalog.mu.Lock()
		catalog.fetchedAt, catalog.lastAttempt = time.Time{}, time.Time{}
		catalog.mu.Unlock()
		if err := catalog.refresh(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	wrongSum := strings.Repeat("0", 64)
	publish("1.0.0-rc.1", sha256Hex(archive))
	f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"})
	f.waitSettled("goose")
	first, _ := catalog.store.readCurrent("goose")
	// The same version in capitals, with a download that would fail: nothing
	// is downloaded and nothing changes.
	publish("1.0.0-RC.1", wrongSum)
	catalog.updateRun()
	for _, path := range []string{"/v1/agents/update", "/v1/agents/install"} {
		if w := f.call("POST", path, map[string]any{"id": "goose"}); w.Code != 202 {
			t.Fatalf("%s %d %s", path, w.Code, w.Body)
		}
	}
	agent := f.waitSettled("goose")
	if current, _ := catalog.store.readCurrent("goose"); current == nil || current.Version != "1.0.0-rc.1" || agent.LastError != "" || agent.LatestVersion != "1.0.0-rc.1" || f.registry.hitsOf("/goose.tar.gz") != 1 {
		t.Fatalf("after the same version: %+v %+v, %d downloads", current, agent, f.registry.hitsOf("/goose.tar.gz"))
	}
	if _, err := os.Stat(first.Command); err != nil {
		t.Fatalf("the current version's command: %v", err)
	}
	// An update keeps it as previous.
	publish("1.0.0", sha256Hex(archive))
	catalog.updateRun()
	if current, _ := catalog.store.readCurrent("goose"); current.Version != "1.0.0" || current.Previous == nil || current.Previous.Version != "1.0.0-rc.1" {
		t.Fatalf("after the update %+v", current)
	}
	// The registry goes back to the previous version, in capitals, with a
	// download that would fail: the kept version is checked and made current
	// again, and both folders stay.
	publish("1.0.0-RC.1", wrongSum)
	catalog.updateRun()
	current, _ := catalog.store.readCurrent("goose")
	if current.Version != "1.0.0-rc.1" || current.Previous == nil || current.Previous.Version != "1.0.0" || f.registry.hitsOf("/goose.tar.gz") != 2 || f.agent("goose").LastError != "" {
		t.Fatalf("after going back %+v, %d downloads", current, f.registry.hitsOf("/goose.tar.gz"))
	}
	if versions := versionsOf(t, catalog.store, "goose"); !reflect.DeepEqual(versions, []string{"1.0.0", "1.0.0-rc.1"}) {
		t.Fatalf("versions %v", versions)
	}
	// Going back to a kept version that fails its check changes nothing.
	os.WriteFile(filepath.Join(f.dir, "script.jsonl"), []byte(`{"do":"exit","code":3}`+"\n"), 0o600)
	publish("1.0.0", wrongSum)
	catalog.updateRun()
	current, _ = catalog.store.readCurrent("goose")
	if current.Version != "1.0.0-rc.1" || current.Previous == nil || current.Previous.Version != "1.0.0" || !strings.Contains(f.agent("goose").LastError, "ended before it answered initialize") {
		t.Fatalf("after a failed check %+v", current)
	}
	if versions := versionsOf(t, catalog.store, "goose"); !reflect.DeepEqual(versions, []string{"1.0.0", "1.0.0-rc.1"}) {
		t.Fatalf("versions after a failed check %v", versions)
	}
}

// After an OpenCode update, pruning keeps the version the host's OpenCode
// runs until the Mac app restarts it, besides the current and previous ones.
// At start, when the host cannot ask OpenCode yet, every OpenCode version
// stays and only other leftovers go.
func TestOpenCodeUpdatesKeepTheRunningVersion(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	enableAutomaticFor(t, f)
	catalog := f.host.agents
	catalog.openCodeCheck = func(context.Context, string, string) error { return nil }
	var running atomic.Value
	running.Store("1.0.0")
	catalog.runningOpenCode = func() string { return running.Load().(string) }
	archive := zipArchive(t, archiveEntry{name: "opencode", body: "#!/bin/sh\nexit 0\n", mode: 0o755})
	f.registry.setFile("/opencode.zip", archive)
	publish := func(version string) {
		t.Helper()
		f.registry.setAgents(map[string]any{"id": "opencode", "name": "OpenCode", "version": version, "distribution": map[string]any{"binary": map[string]any{agentPlatform(): map[string]any{"archive": f.registry.url("/opencode.zip"), "cmd": "./opencode", "args": []string{"acp"}, "sha256": sha256Hex(archive)}}}})
		catalog.mu.Lock()
		catalog.fetchedAt, catalog.lastAttempt = time.Time{}, time.Time{}
		catalog.mu.Unlock()
		if err := catalog.refresh(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	publish("1.0.0")
	f.call("POST", "/v1/agents/install", map[string]any{"id": "opencode"})
	f.waitSettled("opencode")
	// Two updates while OpenCode still runs 1.0.0: its folder stays.
	publish("1.1.0")
	catalog.updateRun()
	publish("1.2.0")
	catalog.updateRun()
	if versions := versionsOf(t, catalog.store, "opencode"); !reflect.DeepEqual(versions, []string{"1.0.0", "1.1.0", "1.2.0"}) {
		t.Fatalf("versions while 1.0.0 runs %v", versions)
	}
	// Once OpenCode runs 1.2.0, the next update keeps only it and the new one.
	running.Store("1.2.0")
	publish("1.3.0")
	catalog.updateRun()
	if versions := versionsOf(t, catalog.store, "opencode"); !reflect.DeepEqual(versions, []string{"1.2.0", "1.3.0"}) {
		t.Fatalf("versions after the restart %v", versions)
	}
	// At start: OpenCode's version folders stay, its other leftovers go; for
	// other agents only the current and previous versions stay.
	store := catalog.store
	for _, folder := range []string{store.versionDir("opencode", "0.9.0"), filepath.Join(store.agentDir("opencode"), ".check-1"), store.versionDir("goose", "0.9.0"), store.versionDir("goose", "1.0.0")} {
		if err := os.MkdirAll(folder, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(store.agentDir("opencode"), ".download-1"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := writeScript(t, filepath.Join(store.versionDir("goose", "1.0.0"), "goose"), "exit 0\n")
	if err := store.writeCurrent("goose", agentCurrent{Version: "1.0.0", Command: command, Kind: "binary", InstalledAt: chatTimeOf(time.Now())}); err != nil {
		t.Fatal(err)
	}
	catalog.cleanLeftovers()
	if versions := versionsOf(t, store, "opencode"); !reflect.DeepEqual(versions, []string{"0.9.0", "1.2.0", "1.3.0"}) {
		t.Fatalf("OpenCode's versions after a start %v", versions)
	}
	if _, err := os.Stat(filepath.Join(store.agentDir("opencode"), ".download-1")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a download stayed: %v", err)
	}
	if versions := versionsOf(t, store, "goose"); !reflect.DeepEqual(versions, []string{"1.0.0"}) {
		t.Fatalf("goose's versions after a start %v", versions)
	}
}

// Installing an agent installed at another version updates it, by the
// update's rules: refused with 409 agent_busy while it is busy, as update is.
func TestInstallOfAnInstalledAgentIsAnUpdate(t *testing.T) {
	f := newCatalogFixture(t, nil, nil)
	f.answerInitialize()
	catalog := f.host.agents
	archive := f.fakeAgentArchive()
	f.registry.setFile("/goose.tar.gz", archive)
	publish := func(version string) {
		t.Helper()
		f.registry.setAgents(f.fakeAgentEntry("goose", version, "/goose.tar.gz", sha256Hex(archive)))
		catalog.mu.Lock()
		catalog.fetchedAt, catalog.lastAttempt = time.Time{}, time.Time{}
		catalog.mu.Unlock()
		if err := catalog.refresh(t.Context()); err != nil {
			t.Fatal(err)
		}
	}
	publish("1.0.0")
	f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"})
	f.waitSettled("goose")
	var busy atomic.Bool
	busy.Store(true)
	catalog.agentBusyFor = func(string) bool { return busy.Load() }
	publish("1.1.0")
	for _, path := range []string{"/v1/agents/update", "/v1/agents/install"} {
		if w := f.call("POST", path, map[string]any{"id": "goose"}); w.Code != 409 || !strings.Contains(w.Body.String(), "agent_busy") {
			t.Fatalf("%s while busy: %d %s", path, w.Code, w.Body)
		}
	}
	if agent := f.waitSettled("goose"); agent.InstalledVersion != "1.0.0" || f.registry.hitsOf("/goose.tar.gz") != 1 {
		t.Fatalf("changed while busy: %+v", agent)
	}
	busy.Store(false)
	w := f.call("POST", "/v1/agents/install", map[string]any{"id": "goose"})
	var accepted agentJSON
	json.Unmarshal(w.Body.Bytes(), &accepted)
	if w.Code != 202 || accepted.State != "updating" {
		t.Fatalf("install when idle: %d %s", w.Code, w.Body)
	}
	if agent := f.waitSettled("goose"); agent.InstalledVersion != "1.1.0" || agent.PreviousVersion != "1.0.0" {
		t.Fatalf("after the install %+v", agent)
	}
}

func TestInstallCancelledByShutdown(t *testing.T) {
	f := newCatalogFixture(t, map[string]string{"npm": writeScript(t, filepath.Join(t.TempDir(), "npm"), "sleep 30\n")}, nil)
	f.registry.setAgents(map[string]any{"id": "slow", "name": "Slow", "version": "1.0.0", "distribution": map[string]any{"npx": map[string]any{"package": "slow@1.0.0", "args": []string{"--acp"}}}})
	f.agents()
	f.call("POST", "/v1/agents/install", map[string]any{"id": "slow"})
	waitFor(t, "the install to start", func() bool {
		_, err := os.Stat(f.host.agents.store.versionDir("slow", "1.0.0"))
		return err == nil
	})
	started := time.Now()
	f.host.agents.close()
	if time.Since(started) > 10*time.Second {
		t.Fatal("the shutdown waited for the install")
	}
	if versions := versionsOf(t, f.host.agents.store, "slow"); len(versions) != 0 {
		t.Fatalf("an unfinished folder stayed: %v", versions)
	}
	if status := f.host.agents.store.readStatus("slow"); status.LastError != "" {
		t.Fatalf("a shutdown is no failure: %+v", status)
	}
}

func TestOpenCodeCheck(t *testing.T) {
	self, _ := os.Executable()
	records := t.TempDir()
	scratch := t.TempDir()
	opencode := func(version, fail string) string {
		return writeScript(t, filepath.Join(t.TempDir(), "opencode"), "AGENTLAND_FAKE_AGENT=opencode-serve FAKE_OPENCODE_VERSION="+version+" FAKE_OPENCODE_DIR='"+records+"' FAKE_OPENCODE_FAIL="+fail+" exec '"+self+"' \"$@\"\n")
	}
	base := []string{"PATH=/usr/bin:/bin", "HOME=/owner/home", "USER=tester", "AGENTLAND_SECRET_PROBE=must-not-leak", "ANTHROPIC_API_KEY=must-not-leak"}
	if err := checkOpenCode(t.Context(), opencode("1.18.32", ""), "1.18.32", 10*time.Second, base, scratch); err != nil {
		t.Fatal(err)
	}
	var record struct {
		Argv []string
		Env  map[string]string
		Cwd  string
	}
	data, _ := os.ReadFile(filepath.Join(records, "serve.json"))
	json.Unmarshal(data, &record)
	if len(record.Argv) != 6 || record.Argv[0] != "serve" || record.Argv[1] != "--pure" || record.Argv[3] != "127.0.0.1" || record.Argv[4] != "--port" {
		t.Fatalf("argv %v", record.Argv)
	}
	env := record.Env
	if env["HOME"] == "/owner/home" || !strings.HasPrefix(env["HOME"], scratch) || env["OPENCODE_TEST_HOME"] != env["HOME"] || !strings.HasPrefix(env["XDG_DATA_HOME"], scratch) || !strings.HasPrefix(env["XDG_CONFIG_HOME"], scratch) || len(env["OPENCODE_SERVER_PASSWORD"]) != 48 || env["OPENCODE_DISABLE_AUTOUPDATE"] != "true" || env["AGENTLAND_SECRET_PROBE"] != "" || env["ANTHROPIC_API_KEY"] != "" {
		t.Fatalf("environment %v", env)
	}
	// The throwaway folders are gone afterwards.
	if entries, _ := os.ReadDir(scratch); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
	if err := checkOpenCode(t.Context(), opencode("1.18.31", ""), "1.18.32", 10*time.Second, base, scratch); err == nil || !strings.Contains(err.Error(), `reported version "1.18.31"`) {
		t.Fatalf("another version: %v", err)
	}
	if err := checkOpenCode(t.Context(), opencode("1.18.32", "provider"), "1.18.32", 10*time.Second, base, scratch); err == nil || !strings.Contains(err.Error(), "did not list its providers") {
		t.Fatalf("providers failing: %v", err)
	}
	if err := checkOpenCode(t.Context(), writeScript(t, filepath.Join(t.TempDir(), "opencode"), "exit 3\n"), "1.18.32", 10*time.Second, base, scratch); err == nil || !strings.Contains(err.Error(), "stopped before it answered") {
		t.Fatalf("exits at once: %v", err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 200*time.Millisecond)
	defer cancel()
	if err := checkOpenCode(ctx, writeScript(t, filepath.Join(t.TempDir(), "opencode"), "sleep 30\n"), "1.18.32", 100*time.Millisecond, base, scratch); err == nil {
		t.Fatal("a silent OpenCode passed")
	}
	// An OpenCode install uses this check.
	f := newCatalogFixture(t, nil, nil)
	archive := zipArchive(t, archiveEntry{name: "opencode", body: "#!/bin/sh\nAGENTLAND_FAKE_AGENT=opencode-serve FAKE_OPENCODE_VERSION=1.18.32 FAKE_OPENCODE_DIR='" + records + "' exec '" + self + "' \"$@\"\n", mode: 0o755})
	f.registry.setFile("/opencode.zip", archive)
	f.registry.setAgents(map[string]any{"id": "opencode", "name": "OpenCode", "version": "1.18.32", "distribution": map[string]any{"binary": map[string]any{agentPlatform(): map[string]any{"archive": f.registry.url("/opencode.zip"), "cmd": "./opencode", "args": []string{"acp"}, "sha256": sha256Hex(archive)}}}})
	f.agents()
	f.call("POST", "/v1/agents/install", map[string]any{"id": "opencode"})
	agent := f.waitSettled("opencode")
	current, _ := f.host.agents.store.readCurrent("opencode")
	if agent.State != "installed" || agent.Source != "registry" || current == nil || current.SHA256 == "" || !reflect.DeepEqual(current.Args, []string{"acp"}) {
		t.Fatalf("opencode %+v %+v", agent, current)
	}
	if command, ok := f.host.agents.openCodeCommand(); !ok || command != current.Command {
		t.Fatalf("OpenCode's terminals use %q", command)
	}
	if _, ok := f.host.agents.acpLaunch("opencode"); ok {
		t.Fatal("OpenCode chats through ACP")
	}
}
