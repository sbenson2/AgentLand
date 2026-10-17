package host

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// installRun is what one install-opencode run wrote and returned.
type installRun struct {
	events []installEvent
	err    error
}

// names lists the runs' event names.
func (r installRun) names() []string {
	names := []string{}
	for _, event := range r.events {
		if len(names) > 0 && event.Event == "downloading" && names[len(names)-1] == "downloading" {
			continue // one entry for a download's reports
		}
		names = append(names, event.Event)
	}
	return names
}

func (r installRun) last() installEvent {
	if len(r.events) == 0 {
		return installEvent{}
	}
	return r.events[len(r.events)-1]
}

// runInstallOpenCode runs install-opencode on state with the registry
// server (nil: every read fails at once), as the CLI does.
func runInstallOpenCode(t *testing.T, ctx context.Context, state string, server *httptest.Server) installRun {
	t.Helper()
	var output bytes.Buffer
	err := InstallOpenCode(ctx, InstallOpenCodeOptions{StatePath: state, Version: "test", Output: &output, configure: func(c *agentCatalog) {
		quietAgents(c, nil, nil, server)
	}})
	run := installRun{err: err}
	for _, line := range strings.Split(strings.TrimSpace(output.String()), "\n") {
		var event installEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("an event that is not a JSON object: %q", line)
		}
		run.events = append(run.events, event)
	}
	if (err == nil) != (run.last().Event == "ready") {
		t.Fatalf("returned %v after %+v", err, run.last())
	}
	return run
}

// `agentland-host install-opencode --state <host.json>` makes sure a valid
// managed OpenCode is there: ready at once with a valid one, else the
// registry's installed through the catalog's path, reported as JSON events.
// Each failure has its code, and its text shows home paths as ~/….
func TestInstallOpenCodeCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	records := t.TempDir()
	registry := newFakeRegistry(t)
	archive := openCodeRelease(t, "1.18.32", records)
	path := publishOpenCode(registry, 1, "1.18.32", archive, sha256Hex(archive), "")
	state := filepath.Join(home, "state", "host.json")
	store := agentStore{root: state + ".agents"}

	run := runInstallOpenCode(t, t.Context(), state, registry.server)
	if !reflect.DeepEqual(run.names(), []string{"registry", "downloading", "checking", "ready"}) || run.last().Version != "1.18.32" {
		t.Fatalf("first run %+v", run.events)
	}
	size := int64(len(archive))
	download := run.events[1]
	final := run.events[len(run.events)-3]
	if download.Version != "1.18.32" || *download.Received != 0 || *download.Total != size || *final.Received != size || *final.Total != size || run.events[len(run.events)-2].Version != "1.18.32" {
		t.Fatalf("the download's events %+v", run.events)
	}
	current, err := store.managedOpenCode()
	if err != nil || current.Version != "1.18.32" || registry.hitsOf(path) != 1 {
		t.Fatalf("after the install %+v %v", current, err)
	}
	if _, err := os.Stat(filepath.Join(records, "serve.json")); err != nil {
		t.Fatalf("OpenCode's check did not run: %v", err)
	}
	// A valid one is ready at once: no registry read, no download, even when
	// the registry offers another version (serve updates it).
	next := openCodeRelease(t, "1.18.33", records)
	publishOpenCode(registry, 2, "1.18.33", next, sha256Hex(next), "")
	reads := registry.hitsOf("/registry.json")
	run = runInstallOpenCode(t, t.Context(), state, registry.server)
	if !reflect.DeepEqual(run.names(), []string{"ready"}) || run.last().Version != "1.18.32" || registry.hitsOf("/registry.json") != reads {
		t.Fatalf("a valid one %+v, %d reads", run.events, registry.hitsOf("/registry.json")-reads)
	}
	// A damaged one is installed again, from the registry as it is now.
	if err := os.WriteFile(current.Command, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	run = runInstallOpenCode(t, t.Context(), state, registry.server)
	if !reflect.DeepEqual(run.names(), []string{"registry", "downloading", "checking", "ready"}) || run.last().Version != "1.18.33" {
		t.Fatalf("a damaged one %+v", run.events)
	}
	if current, err := store.managedOpenCode(); err != nil || current.Version != "1.18.33" {
		t.Fatalf("after the repair %+v %v", current, err)
	}
	// Each failure, in a state of its own.
	failure := func(what, code, text string, server *httptest.Server, names ...string) {
		t.Helper()
		folder := filepath.Join(home, strings.ReplaceAll(what, " ", "-"))
		run := runInstallOpenCode(t, t.Context(), filepath.Join(folder, "host.json"), server)
		last := run.last()
		var refused *openCodeFailure
		if !reflect.DeepEqual(run.names(), append(names, "failed")) || last.Code != code || !strings.Contains(last.Error, text) || !errors.As(run.err, &refused) || refused.code != code {
			t.Fatalf("%s: %+v %v", what, run.events, run.err)
		}
		if strings.Contains(last.Error, home) {
			t.Fatalf("%s: the error shows the home folder: %q", what, last.Error)
		}
		if _, err := os.Stat(filepath.Join(folder, "host.json.agents", "opencode", "current.json")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s: a record was written: %v", what, err)
		}
	}
	unverified := publishOpenCode(registry, 3, "1.18.34", next, "", "")
	failure("no checksum", "unverified_download", "has no checksum in the registry; install it by hand", registry.server, "registry")
	if registry.hitsOf(unverified) != 0 {
		t.Fatal("an unverified download was fetched")
	}
	publishOpenCode(registry, 4, "1.18.34", next, sha256Hex(next), otherPlatform())
	failure("other platform", "unsupported_platform", "offers nothing that runs on this Mac", registry.server, "registry")
	wrong := openCodeRelease(t, "1.18.99", records)
	publishOpenCode(registry, 5, "1.18.34", wrong, sha256Hex(wrong), "")
	failure("failed check", "check_failed", `reported version "1.18.99"`, registry.server, "registry", "downloading", "checking")
	publishOpenCode(registry, 6, "1.18.34", next, strings.Repeat("0", 64), "")
	failure("wrong checksum", "download_failed", "SHA-256 does not match", registry.server, "registry", "downloading")
	registry.mu.Lock()
	registry.status["/registry.json"] = http.StatusServiceUnavailable
	registry.mu.Unlock()
	failure("registry error", "registry_unavailable", "HTTP 503", registry.server, "registry")
	gone := newFakeRegistry(t)
	gone.server.Close()
	failure("offline", "offline", "The registry could not be reached", gone.server, "registry")
	// A state folder that cannot be made: the error names it from ~.
	if err := os.WriteFile(filepath.Join(home, "file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	run = runInstallOpenCode(t, t.Context(), filepath.Join(home, "file", "state", "host.json"), registry.server)
	if last := run.last(); last.Code != "storage_error" || !strings.Contains(last.Error, "~/file/state") || strings.Contains(last.Error, home) {
		t.Fatalf("a state folder under a file: %+v", run.events)
	}
}

// On a first launch the Mac app runs install-opencode before `init`: the
// state's folder is there, host.json is not. It installs OpenCode without
// reading or making host.json; `init` then makes host.json beside what it
// left, and serve on the same path takes the lock and finds the managed
// OpenCode, installing nothing.
func TestInstallOpenCodeBeforeInit(t *testing.T) {
	records := t.TempDir()
	registry := newFakeRegistry(t)
	archive := openCodeRelease(t, "1.18.32", records)
	path := publishOpenCode(registry, 1, "1.18.32", archive, sha256Hex(archive), "")
	folder := t.TempDir()
	state := filepath.Join(folder, "host.json")
	run := runInstallOpenCode(t, t.Context(), state, registry.server)
	if !reflect.DeepEqual(run.names(), []string{"registry", "downloading", "checking", "ready"}) || run.last().Version != "1.18.32" {
		t.Fatalf("install before init %+v", run.events)
	}
	if _, err := os.Stat(state); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("host.json was made or read: %v", err)
	}
	entries, err := os.ReadDir(folder)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if !reflect.DeepEqual(names, []string{"host.json.agents", "host.json.serve.lock"}) {
		t.Fatalf("the state folder holds %v", names)
	}
	// init on the same path.
	store := NewStore(state)
	if err := store.Initialize(Config{OpenCodeURL: "http://127.0.0.1:4197", PasswordEnv: "AGENTLAND_OPENCODE_PASSWORD", Projects: []Project{{ID: "p1", Name: "Project", Directory: t.TempDir()}}}); err != nil {
		t.Fatalf("init after install-opencode: %v", err)
	}
	// serve on the same path: its lock, then its catalog.
	release, err := LockState(state)
	if err != nil {
		t.Fatalf("serve's lock after install-opencode: %v", err)
	}
	defer release()
	host := newHost(store, &fakeAgent{sessions: map[string]Session{}}, HostOptions{Agents: &AgentOptions{Version: "test"}})
	quietAgents(host.agents, nil, nil, registry.server)
	t.Cleanup(func() {
		host.Close()
		host.agents.close()
	})
	host.agents.start()
	var answer catalogAnswer
	jsonDecode(t, request(t, host.Handler(), "GET", "/v1/agents", paired(t, host, store), nil).Body.Bytes(), &answer)
	found := false
	for _, agent := range answer.Agents {
		if agent.ID == "opencode" {
			found = agent.Source == "registry" && agent.State == "installed" && agent.InstalledVersion == "1.18.32"
		}
	}
	if !found {
		t.Fatalf("serve's catalog %+v", answer.Agents)
	}
	if _, err := host.agents.store.managedOpenCode(); err != nil || registry.hitsOf(path) != 1 {
		t.Fatalf("serve's start: %v, %d downloads", err, registry.hitsOf(path))
	}
}

// A download's progress is reported when it starts, at most every half
// second while it runs, and when it ends; a total the server did not give
// is left out of the event, and none of its received counts is.
func TestDownloadProgressEvents(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	clock := func() time.Time { return now }
	var reports [][2]int64
	record := func(received, total int64) { reports = append(reports, [2]int64{received, total}) }
	progress := newDownloadProgress(record, -5, clock)
	for range 10 {
		now = now.Add(100 * time.Millisecond)
		progress.Write(make([]byte, 10))
	}
	progress.finish()
	if !reflect.DeepEqual(reports, [][2]int64{{0, -1}, {50, -1}, {100, -1}}) {
		t.Fatalf("reports %v", reports)
	}
	reports = nil
	progress = newDownloadProgress(record, 70, clock)
	for range 7 {
		now = now.Add(100 * time.Millisecond)
		progress.Write(make([]byte, 10))
	}
	progress.finish()
	if !reflect.DeepEqual(reports, [][2]int64{{0, 70}, {50, 70}, {70, 70}}) {
		t.Fatalf("reports %v", reports)
	}
	var output bytes.Buffer
	events := &installEvents{out: &output}
	events.downloading("1.18.32", 0, 70)
	events.downloading("1.18.32", 5, -1)
	if want := `{"event":"downloading","version":"1.18.32","received":0,"total":70}` + "\n" + `{"event":"downloading","version":"1.18.32","received":5}` + "\n"; output.String() != want {
		t.Fatalf("events %q", output.String())
	}
}

// install-opencode takes the state's lock as serve does: it fails at once
// with busy while another process holds it (and serve fails while it runs).
// Stopped midway it says so, leaves no version folder and lets go of the
// lock.
func TestInstallOpenCodeTakesTheStateLock(t *testing.T) {
	records := t.TempDir()
	registry := newFakeRegistry(t)
	archive := openCodeRelease(t, "1.18.32", records)
	path := publishOpenCode(registry, 1, "1.18.32", archive, sha256Hex(archive), "")
	state := filepath.Join(t.TempDir(), "host.json")
	release, err := LockState(state)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := LockState(state); !errors.Is(err, ErrStateBusy) {
		t.Fatalf("a second lock: %v", err)
	}
	started := time.Now()
	run := runInstallOpenCode(t, t.Context(), state, registry.server)
	if !reflect.DeepEqual(run.names(), []string{"failed"}) || run.last().Code != "busy" || time.Since(started) > 2*time.Second {
		t.Fatalf("while the lock is held %+v after %v", run.events, time.Since(started))
	}
	if _, err := os.Stat(state + ".agents"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the agents folder was made: %v", err)
	}
	if info, err := os.Stat(state + ".serve.lock"); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the lock file %v %v", info, err)
	}
	release()
	// Stopped during the download.
	hold := registry.holdPath(path)
	defer hold()
	ctx, cancel := context.WithCancel(t.Context())
	go func() {
		for deadline := time.Now().Add(10 * time.Second); registry.hitsOf(path) == 0 && time.Now().Before(deadline); {
			time.Sleep(5 * time.Millisecond)
		}
		cancel()
	}()
	run = runInstallOpenCode(t, ctx, state, registry.server)
	if !reflect.DeepEqual(run.names(), []string{"registry", "failed"}) || run.last().Code != "cancelled" {
		t.Fatalf("stopped %+v", run.events)
	}
	if versions := versionsOf(t, agentStore{root: state + ".agents"}, "opencode"); len(versions) != 0 {
		t.Fatalf("left %v", versions)
	}
	entries, _ := os.ReadDir(filepath.Join(state+".agents", "opencode"))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".") {
			t.Fatalf("left %s", entry.Name())
		}
	}
	release, err = LockState(state)
	if err != nil {
		t.Fatalf("the lock after a stop: %v", err)
	}
	release()
}
