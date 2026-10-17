package host

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// This opt-in check installs one agent from the real ACP registry into a
// temporary state folder and runs its initialize check: goose, or the agent
// AGENTLAND_TEST_ACP_LIVE_AGENT names. It needs network and spends no model
// credits: initialize makes no session and calls no model. It never touches
// the owner's state or their installed commands: the catalog finds no command
// on the Mac, and the agent runs with a throwaway HOME and TMPDIR.
func TestLiveRegistryInstall(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_ACP_LIVE") != "1" {
		t.Skip("set AGENTLAND_TEST_ACP_LIVE=1 to install an agent from the real registry into a temporary folder")
	}
	id := os.Getenv("AGENTLAND_TEST_ACP_LIVE_AGENT")
	if id == "" {
		id = "goose"
	}
	root := t.TempDir()
	home := filepath.Join(root, "home")
	temporary := filepath.Join(root, "tmp")
	for _, folder := range []string{home, temporary} {
		if err := os.Mkdir(folder, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	statePath := filepath.Join(root, "state", "host.json")
	catalog := newAgentCatalog(nil, statePath, AgentOptions{Version: "live-test"})
	t.Cleanup(catalog.close)
	catalog.lookup = func(string) (string, bool) { return "", false }
	catalog.versionOf = func(string) string { return "" }
	catalog.baseEnv = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + home, "TMPDIR=" + temporary, "LANG=en_US.UTF-8"}
	if err := catalog.refresh(t.Context()); err != nil {
		t.Fatalf("registry: %v", err)
	}
	registry, ok := catalog.registryEntry(id)
	if !ok {
		t.Fatalf("the registry lists no %s", id)
	}
	dist, ok := registry.choose(catalog.platform)
	if !ok {
		t.Fatalf("%s offers nothing for %s", id, catalog.platform)
	}
	t.Logf("%s %s: %s distribution, verified %v", id, registry.Version, dist.Kind, dist.Verified)
	started := time.Now()
	if err := catalog.installVersion(t.Context(), id, registry, dist, !dist.Verified); err != nil {
		t.Fatalf("install: %v", err)
	}
	current, err := catalog.store.readCurrent(id)
	if err != nil || current == nil {
		t.Fatalf("current.json: %+v %v", current, err)
	}
	if current.Version != registry.Version || (current.Kind == "binary" && current.SHA256 == "") {
		t.Fatalf("current.json %+v", current)
	}
	t.Logf("installed and checked in %s: %s (%s)", time.Since(started).Round(time.Millisecond), filepath.Base(current.Command), current.Kind)
	for _, folder := range []string{catalog.store.root, catalog.store.agentDir(id), catalog.store.versionDir(id, current.Version)} {
		if info, err := os.Lstat(folder); err != nil || info.Mode().Perm() != 0o700 {
			t.Fatalf("%s: %v %v", folder, info.Mode(), err)
		}
	}
	// The check again, on its own, as automatic updates run it.
	if err := catalog.check(t.Context(), id, *current); err != nil {
		t.Fatalf("initialize check: %v", err)
	}
}
