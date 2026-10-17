package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// openCodeFixture is a catalog fixture whose registry lists OpenCode as
// releases of the fake `opencode serve` (the test binary, re-executed).
type openCodeFixture struct {
	*catalogFixture
	records   string // what the fake opencode serve records
	published int
}

func newOpenCodeFixture(t *testing.T, commands map[string]string) *openCodeFixture {
	t.Helper()
	return &openCodeFixture{catalogFixture: newCatalogFixture(t, commands, nil), records: t.TempDir()}
}

// openCodeRelease is a zip whose opencode serves as the fake `opencode
// serve` reporting version, which records what it was given in records.
func openCodeRelease(t *testing.T, version, records string) []byte {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return zipArchive(t, archiveEntry{name: "opencode", body: "#!/bin/sh\nAGENTLAND_FAKE_AGENT=opencode-serve FAKE_OPENCODE_VERSION=" + version + " FAKE_OPENCODE_DIR='" + records + "' exec '" + self + "' \"$@\"\n", mode: 0o755})
}

// publishOpenCode lists OpenCode at version in registry, served from a new
// path it returns (number makes it new): for this Mac, or for platform when
// it is not "", with sha256 when sum is not "".
func publishOpenCode(registry *fakeRegistry, number int, version string, archive []byte, sum, platform string) string {
	path := fmt.Sprintf("/opencode-%s-%d.zip", version, number)
	registry.setFile(path, archive)
	binary := map[string]any{"archive": registry.url(path), "cmd": "./opencode", "args": []string{"acp"}}
	if sum != "" {
		binary["sha256"] = sum
	}
	if platform == "" {
		platform = agentPlatform()
	}
	registry.setAgents(map[string]any{"id": "opencode", "name": "OpenCode", "version": version, "license": "MIT", "distribution": map[string]any{"binary": map[string]any{platform: binary}}})
	return path
}

// release is a zip whose opencode serves as the fake reporting version.
func (f *openCodeFixture) release(version string) []byte {
	return openCodeRelease(f.t, version, f.records)
}

// publish is publishOpenCode for the fixture's registry; the catalog reads
// it at once.
func (f *openCodeFixture) publish(version string, archive []byte, sum, platform string) string {
	f.t.Helper()
	f.published++
	path := publishOpenCode(f.registry, f.published, version, archive, sum, platform)
	if err := f.host.agents.refresh(f.t.Context()); err != nil {
		f.t.Fatal(err)
	}
	return path
}

// waitOpenCode waits until OpenCode's entry satisfies done and no change of
// it runs.
func (f *openCodeFixture) waitOpenCode(what string, done func(agentJSON) bool) agentJSON {
	f.t.Helper()
	var agent agentJSON
	waitFor(f.t, what, func() bool {
		f.host.agents.mu.Lock()
		running := f.host.agents.ops["opencode"] != nil
		f.host.agents.mu.Unlock()
		agent = f.agent("opencode")
		return !running && done(agent)
	})
	return agent
}

// jsonDecode decodes an answer's body or fails the test.
func jsonDecode(t *testing.T, data []byte, out any) {
	t.Helper()
	if err := json.Unmarshal(data, out); err != nil {
		t.Fatalf("%v: %s", err, data)
	}
}

// otherPlatform is a platform that is not this Mac's.
func otherPlatform() string {
	if agentPlatform() == "linux-x86_64" {
		return "linux-aarch64"
	}
	return "linux-x86_64"
}

// Owner's decision (2026-09-27): the Mac app ships no OpenCode. With no
// managed OpenCode, the host installs the registry's at once when it
// starts: no 2-minute wait and no idle wait (OpenCode counts as busy while
// its status query fails, as it does with no OpenCode running), through
// Install's path and OpenCode's check. The entry is a registry agent. Later
// updates wait for idle as before, and a record that fails the checks is
// installed again.
func TestTheMissingOpenCodeInstallsAtOnce(t *testing.T) {
	f := newOpenCodeFixture(t, nil)
	enableAutomaticFor(t, f.catalogFixture)
	catalog := f.host.agents
	var busy atomic.Bool
	busy.Store(true)
	var polls atomic.Int32
	catalog.agentBusyFor = func(id string) bool {
		if id == "opencode" {
			polls.Add(1)
		}
		return busy.Load()
	}
	catalog.idlePoll = 20 * time.Millisecond
	catalog.runningOpenCode = func() string { return "" }
	archive := f.release("1.18.32")
	path := f.publish("1.18.32", archive, sha256Hex(archive), "")
	if agent := f.agent("opencode"); agent.Source != "registry" || agent.State != "notInstalled" || agent.LatestVersion != "1.18.32" || !agent.Verified {
		t.Fatalf("before the start %+v", agent)
	}
	started := time.Now()
	catalog.start()
	agent := f.waitOpenCode("OpenCode to install", func(agent agentJSON) bool { return agent.State == "installed" })
	current, err := catalog.store.managedOpenCode()
	if err != nil || current.Version != "1.18.32" || current.SHA256 == "" || current.Unverified || agent.Source != "registry" || agent.InstalledVersion != "1.18.32" || agent.LastError != "" || f.registry.hitsOf(path) != 1 {
		t.Fatalf("after the start: %+v %v %+v, %d downloads", current, err, agent, f.registry.hitsOf(path))
	}
	if elapsed := time.Since(started); elapsed > time.Minute || polls.Load() != 0 {
		t.Fatalf("the install waited: %v, %d idle checks", elapsed, polls.Load())
	}
	// The check ran the new OpenCode's serve.
	if _, err := os.Stat(filepath.Join(f.records, "serve.json")); err != nil {
		t.Fatalf("OpenCode's check did not run: %v", err)
	}
	// Later updates wait until OpenCode is idle, as before.
	next := f.release("1.18.33")
	f.publish("1.18.33", next, sha256Hex(next), "")
	done := make(chan struct{})
	go func() {
		catalog.updateRun()
		close(done)
	}()
	waitFor(t, "a few idle checks", func() bool { return polls.Load() >= 3 })
	if current, _ := catalog.store.managedOpenCode(); current.Version != "1.18.32" {
		t.Fatalf("updated while busy: %s", current.Version)
	}
	busy.Store(false)
	<-done
	current, err = catalog.store.managedOpenCode()
	if err != nil || current.Version != "1.18.33" || current.Previous == nil || current.Previous.Version != "1.18.32" {
		t.Fatalf("after the update %+v %v", current, err)
	}
	// A program that no longer matches its record's sha256 is installed again
	// when the host starts (ensureOpenCode is what start runs).
	if err := os.WriteFile(current.Command, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.store.managedOpenCode(); err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("a changed program passed: %v", err)
	}
	version, err := catalog.ensureOpenCode(t.Context())
	if err != nil || version != "1.18.33" {
		t.Fatalf("the repair: %q %v", version, err)
	}
	if current, err := catalog.store.managedOpenCode(); err != nil || current.Version != "1.18.33" {
		t.Fatalf("after the repair %+v %v", current, err)
	}
	// OpenCode is never uninstalled: AgentLand's chats need it.
	if w := f.call("POST", "/v1/agents/uninstall", map[string]any{"id": "opencode"}); w.Code != 409 || !strings.Contains(w.Body.String(), `"code":"agent_required"`) {
		t.Fatalf("uninstall %d %s", w.Code, w.Body)
	}
	if _, err := catalog.store.managedOpenCode(); err != nil {
		t.Fatalf("after the refused uninstall: %v", err)
	}
}

// Nothing but a binary checked by the registry's sha256 installs on its own:
// a download without one waits for the owner's Install, and so does a
// registry that offers nothing for this Mac; each says why in lastError.
// A version that fails OpenCode's check is removed. An automatic update run
// installs a verified one at once. An opencode found on the Mac is not
// OpenCode's entry, and no entry is ever bundled.
func TestTheMissingOpenCodeWaitsForTheOwner(t *testing.T) {
	bin := t.TempDir()
	local := writeScript(t, filepath.Join(bin, "opencode"), "exit 0\n")
	f := newOpenCodeFixture(t, map[string]string{"opencode": local})
	enableAutomaticFor(t, f.catalogFixture)
	catalog := f.host.agents
	catalog.agentBusyFor = func(string) bool { return true }
	wantFailure := func(what, code, message string) agentJSON {
		t.Helper()
		_, err := catalog.ensureOpenCode(t.Context())
		var failure *openCodeFailure
		if !errors.As(err, &failure) || failure.code != code || !strings.Contains(failure.message, message) {
			t.Fatalf("%s: %v", what, err)
		}
		agent := f.agent("opencode")
		if agent.Source != "registry" || agent.State != "failed" || agent.LastError != failure.message || agent.InstalledVersion != "" {
			t.Fatalf("%s: %+v", what, agent)
		}
		if versions := versionsOf(t, catalog.store, "opencode"); len(versions) != 0 {
			t.Fatalf("%s left %v", what, versions)
		}
		return agent
	}
	archive := f.release("1.18.32")
	unverified := f.publish("1.18.32", archive, "", "")
	if agent := wantFailure("a download without a checksum", "unverified_download", "has no checksum in the registry; install it by hand"); agent.Verified {
		t.Fatalf("verified %+v", agent)
	}
	if f.registry.hitsOf(unverified) != 0 {
		t.Fatal("an unverified download was fetched")
	}
	f.publish("1.18.32", archive, sha256Hex(archive), otherPlatform())
	if agent := wantFailure("nothing for this Mac", "unsupported_platform", "offers nothing that runs on this Mac"); agent.Supported == nil || *agent.Supported {
		t.Fatalf("supported %+v", agent)
	}
	wrong := f.release("1.18.99")
	f.publish("1.18.32", wrong, sha256Hex(wrong), "")
	wantFailure("a failed check", "check_failed", `reported version "1.18.99"`)
	f.publish("1.18.32", archive, strings.Repeat("0", 64), "")
	wantFailure("a checksum that does not match", "download_failed", "SHA-256 does not match")
	// The owner can still install the unverified download.
	f.publish("1.18.32", archive, "", "")
	f.agents()
	if w := f.call("POST", "/v1/agents/install", map[string]any{"id": "opencode"}); w.Code != 400 || !strings.Contains(w.Body.String(), "unverified_download") {
		t.Fatalf("install without the owner's confirmation %d %s", w.Code, w.Body)
	}
	if w := f.call("POST", "/v1/agents/uninstall", map[string]any{"id": "opencode"}); w.Code != 409 || !strings.Contains(w.Body.String(), `"code":"agent_required"`) {
		t.Fatalf("uninstall %d %s", w.Code, w.Body)
	}
	// The next automatic update run installs a verified one at once, though
	// OpenCode counts as busy.
	path := f.publish("1.18.32", archive, sha256Hex(archive), "")
	catalog.updateRun()
	agent := f.agent("opencode")
	if current, err := catalog.store.managedOpenCode(); err != nil || current.Version != "1.18.32" || agent.State != "installed" || agent.LastError != "" || f.registry.hitsOf(path) != 1 {
		t.Fatalf("after the update run %+v %v %+v", current, err, agent)
	}
	// Capabilities list OpenCode among the usable agents, never bundled.
	var capabilities struct{ AgentCatalog []agentCatalogEntry }
	jsonDecode(t, f.call("GET", "/v1/capabilities", nil).Body.Bytes(), &capabilities)
	if !reflect.DeepEqual(capabilities.AgentCatalog, []agentCatalogEntry{{ID: "opencode", Name: "OpenCode", Chat: true, Terminal: true}}) {
		t.Fatalf("agentCatalog %+v", capabilities.AgentCatalog)
	}
	for _, entry := range f.agents().Agents {
		if entry.Source == "bundled" {
			t.Fatalf("a bundled agent %+v", entry)
		}
	}
}

// The Mac app says the managed OpenCode did not start (its own session only):
// for the current version the host goes back to the previous one when it is
// kept and intact, remembers the version so automatic updates skip it until
// the registry offers another, and says so in lastError. With no previous
// version, or one that no longer matches its sha256, nothing is switched.
// Another version changes nothing.
func TestOpenCodeFailedReport(t *testing.T) {
	f := newOpenCodeFixture(t, nil)
	enableAutomaticFor(t, f.catalogFixture)
	catalog := f.host.agents
	catalog.agentBusyFor = func(string) bool { return false }
	var running atomic.Value
	running.Store("1.18.32")
	catalog.runningOpenCode = func() string { return running.Load().(string) }
	report := func(version, reason string) (int, openCodeFailedResult, string) {
		t.Helper()
		w := f.local("POST", "/v1/agents/opencode/failed", map[string]string{"version": version, "reason": reason})
		var result openCodeFailedResult
		if w.Code == 200 {
			jsonDecode(t, w.Body.Bytes(), &result)
		}
		return w.Code, result, w.Body.String()
	}
	openCode := func() (current agentCurrent, lastError string, restart bool) {
		t.Helper()
		record, err := catalog.store.managedOpenCode()
		if err != nil {
			t.Fatalf("the managed OpenCode: %v", err)
		}
		var local catalogAnswer
		jsonDecode(t, f.local("GET", "/v1/agents", nil).Body.Bytes(), &local)
		for _, agent := range local.Agents {
			if agent.ID == "opencode" {
				lastError, restart = agent.LastError, agent.RestartWanted != nil && *agent.RestartWanted
			}
		}
		return *record, lastError, restart
	}
	first := f.release("1.18.32")
	f.publish("1.18.32", first, sha256Hex(first), "")
	if _, err := catalog.ensureOpenCode(t.Context()); err != nil {
		t.Fatal(err)
	}
	// Devices are refused; bodies are checked.
	if w := f.call("POST", "/v1/agents/opencode/failed", map[string]string{"version": "1.18.32", "reason": "x"}); w.Code != 403 || !strings.Contains(w.Body.String(), "local_only") {
		t.Fatalf("a device %d %s", w.Code, w.Body)
	}
	for _, body := range []any{map[string]string{"version": ""}, map[string]string{"version": "../x"}, map[string]string{"version": "1.18.32", "reason": strings.Repeat("r", 601)}, map[string]any{"version": "1.18.32", "extra": true}} {
		if w := f.local("POST", "/v1/agents/opencode/failed", body); w.Code != 400 || !strings.Contains(w.Body.String(), "invalid_request") {
			t.Fatalf("%v: %d %s", body, w.Code, w.Body)
		}
	}
	if _, lastError, _ := openCode(); lastError != "" || catalog.store.readFailed("opencode") != "" {
		t.Fatalf("a refused report changed something: %q", lastError)
	}
	// With no previous version nothing is switched; the version is remembered.
	code, result, body := report("1.18.32", "it exited with status 1.")
	if code != 200 || result != (openCodeFailedResult{RolledBack: false, Current: "1.18.32"}) {
		t.Fatalf("no previous: %d %s", code, body)
	}
	if current, lastError, _ := openCode(); current.Version != "1.18.32" || lastError != "OpenCode 1.18.32 did not start on this Mac: it exited with status 1." || catalog.store.readFailed("opencode") != "1.18.32" {
		t.Fatalf("no previous: %+v %q", current, lastError)
	}
	// The registry moves on: the memory goes and the update runs.
	second := f.release("1.18.33")
	f.publish("1.18.33", second, sha256Hex(second), "")
	catalog.updateRun()
	if current, lastError, restart := openCode(); current.Version != "1.18.33" || current.Previous == nil || current.Previous.Version != "1.18.32" || lastError != "" || !restart || catalog.store.readFailed("opencode") != "" {
		t.Fatalf("the update after the registry moved on: %+v %q %v", current, lastError, restart)
	}
	// Another version than the current one changes nothing.
	if code, result, body := report("1.18.32", "old news"); code != 200 || result != (openCodeFailedResult{Current: "1.18.33"}) {
		t.Fatalf("not current: %d %s", code, body)
	}
	if current, lastError, _ := openCode(); current.Version != "1.18.33" || lastError != "" || catalog.store.readFailed("opencode") != "" {
		t.Fatalf("not current changed: %+v %q", current, lastError)
	}
	// The current one did not start: back to the previous, kept and intact.
	code, result, body = report("1.18.33", "it did not answer within 30 s\n(exit 1)")
	if code != 200 || result != (openCodeFailedResult{RolledBack: true, Current: "1.18.32"}) {
		t.Fatalf("roll back: %d %s", code, body)
	}
	current, lastError, restart := openCode()
	if current.Version != "1.18.32" || current.Previous != nil || lastError != "OpenCode 1.18.33 did not start on this Mac: it did not answer within 30 s (exit 1). Back to 1.18.32." || restart {
		t.Fatalf("after the roll back: %+v %q restart %v", current, lastError, restart)
	}
	// restartWanted follows the running version as usual.
	running.Store("1.18.31")
	if _, _, restart := openCode(); !restart {
		t.Fatal("no restart for a newer current version")
	}
	running.Store("1.18.32")
	// Automatic updates skip 1.18.33 while the registry offers it.
	downloads := f.registry.hitsOf("/opencode-1.18.33-2.zip")
	catalog.updateRun()
	if current, _, _ := openCode(); current.Version != "1.18.32" || f.registry.hitsOf("/opencode-1.18.33-2.zip") != downloads || catalog.store.readFailed("opencode") != "1.18.33" {
		t.Fatalf("the skip: %+v", current)
	}
	// Until it offers another.
	third := f.release("1.18.34")
	f.publish("1.18.34", third, sha256Hex(third), "")
	catalog.updateRun()
	current, lastError, _ = openCode()
	if current.Version != "1.18.34" || current.Previous == nil || current.Previous.Version != "1.18.32" || lastError != "" || catalog.store.readFailed("opencode") != "" {
		t.Fatalf("the lift: %+v %q", current, lastError)
	}
	// A previous version whose program no longer matches its sha256 is not
	// gone back to.
	if err := os.WriteFile(current.Previous.Command, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if code, result, body := report("1.18.34", ""); code != 200 || result != (openCodeFailedResult{Current: "1.18.34"}) {
		t.Fatalf("a damaged previous: %d %s", code, body)
	}
	if current, lastError, _ := openCode(); current.Version != "1.18.34" || lastError != "OpenCode 1.18.34 did not start on this Mac." || catalog.store.readFailed("opencode") != "1.18.34" {
		t.Fatalf("a damaged previous: %+v %q", current, lastError)
	}
	// While another change of OpenCode runs, the report waits: 409.
	op, err := catalog.beginOp("opencode", "update")
	if err != nil {
		t.Fatal(err)
	}
	if code, _, body := report("1.18.34", "again"); code != 409 || !strings.Contains(body, "agent_busy") {
		t.Fatalf("during a change: %d %s", code, body)
	}
	catalog.endOp("opencode", op)
}

// With no registry to reach and none kept, the install at start says so on
// OpenCode's entry, which is always listed.
func TestTheMissingOpenCodeOffline(t *testing.T) {
	_, store, agent := testHost(t)
	host := newHost(store, agent, HostOptions{Agents: &AgentOptions{Version: "test"}})
	// The registry's server is gone: connections to it are refused.
	registry := newFakeRegistry(t)
	quietAgents(host.agents, nil, nil, registry.server)
	registry.server.Close()
	t.Cleanup(func() {
		host.Close()
		host.agents.close()
	})
	token := paired(t, host, store)
	var answer catalogAnswer
	jsonDecode(t, request(t, host.Handler(), "GET", "/v1/agents", token, nil).Body.Bytes(), &answer)
	listed := false
	for _, entry := range answer.Agents {
		if entry.ID == "opencode" {
			listed = entry.Source == "registry" && entry.State == "notInstalled"
		}
	}
	if !listed {
		t.Fatalf("OpenCode is not listed as a registry agent: %+v", answer.Agents)
	}
	_, err := host.agents.ensureOpenCode(t.Context())
	var failure *openCodeFailure
	if !errors.As(err, &failure) || failure.code != "offline" || !strings.Contains(failure.message, "could not be reached") {
		t.Fatalf("offline: %v", err)
	}
	jsonDecode(t, request(t, host.Handler(), "GET", "/v1/agents", token, nil).Body.Bytes(), &answer)
	for _, entry := range answer.Agents {
		if entry.ID == "opencode" && (entry.State != "failed" || entry.LastError != failure.message) {
			t.Fatalf("OpenCode after the attempt %+v", entry)
		}
	}
}
