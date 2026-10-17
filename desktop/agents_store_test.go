package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAgentStoreCurrentAndPrune(t *testing.T) {
	store := agentStore{root: filepath.Join(t.TempDir(), "host.json.agents")}
	if err := store.ensureAgentDir("goose"); err != nil {
		t.Fatal(err)
	}
	for _, folder := range []string{store.root, store.agentDir("goose")} {
		if info, err := os.Lstat(folder); err != nil || info.Mode().Perm() != 0o700 {
			t.Fatalf("%s: %v %v", folder, info.Mode(), err)
		}
	}
	// A folder that became wider is made 0700 again.
	if err := os.Chmod(store.agentDir("goose"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := store.ensureAgentDir("goose"); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Lstat(store.agentDir("goose")); info.Mode().Perm() != 0o700 {
		t.Fatalf("after ensure: %v", info.Mode())
	}
	command := func(version string) string {
		folder := store.versionDir("goose", version)
		if err := os.MkdirAll(folder, 0o700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(folder, "goose")
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o700); err != nil {
			t.Fatal(err)
		}
		return path
	}
	if current, err := store.readCurrent("goose"); current != nil || err != nil {
		t.Fatalf("no current yet: %+v %v", current, err)
	}
	old := agentCurrent{Version: "1.0.0", Command: command("1.0.0"), Args: []string{"acp"}, Kind: "binary", InstalledAt: chatTimeOf(time.Now())}
	current := agentCurrent{Version: "1.1.0", Command: command("1.1.0"), Kind: "binary", InstalledAt: chatTimeOf(time.Now()), Previous: &old}
	if err := store.writeCurrent("goose", current); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(store.currentPath("goose"))
	if err != nil || info.Mode().Perm() != 0o600 || !info.Mode().IsRegular() {
		t.Fatalf("current.json %v %v", info, err)
	}
	var raw map[string]any
	data, _ := os.ReadFile(store.currentPath("goose"))
	if json.Unmarshal(data, &raw) != nil || raw["args"] == nil || raw["unverified"] != false {
		t.Fatalf("current.json %s (args and unverified are always written)", data)
	}
	read, err := store.readCurrent("goose")
	if err != nil || read.Version != "1.1.0" || read.Previous == nil || read.Previous.Version != "1.0.0" || read.Args == nil {
		t.Fatalf("read %+v %v", read, err)
	}
	// Two versions are kept; everything else goes.
	command("0.9.0")
	os.WriteFile(filepath.Join(store.agentDir("goose"), ".download-1"), []byte("x"), 0o600)
	if err := store.setStatus("goose", "The download failed.", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.prune("goose", "1.1.0", "1.0.0"); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(store.agentDir("goose"))
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if len(names) != 4 || names[0] != "1.0.0" || names[1] != "1.1.0" || names[2] != "current.json" || names[3] != "status.json" {
		t.Fatalf("after prune: %v", names)
	}
	if status := store.readStatus("goose"); status.LastError != "The download failed." {
		t.Fatalf("status %+v", status)
	}
	if err := store.setStatus("goose", "", time.Now()); err != nil || store.readStatus("goose").LastError != "" {
		t.Fatalf("cleared status: %v", err)
	}
	// A previous version whose files are gone is dropped when read.
	os.RemoveAll(store.versionDir("goose", "1.0.0"))
	if read, _ := store.readCurrent("goose"); read.Previous != nil {
		t.Fatalf("previous %+v", read.Previous)
	}
	// A command outside its version's folder, or missing, is damage.
	for _, bad := range []agentCurrent{
		{Version: "1.1.0", Command: filepath.Join(store.agentDir("goose"), "current.json"), Kind: "binary"},
		{Version: "1.1.0", Command: filepath.Join(store.versionDir("goose", "1.1.0"), "missing"), Kind: "binary"},
		{Version: "1.1.0", Command: "relative/goose", Kind: "binary"},
		{Version: "1.1.0", Command: command("1.1.0"), Kind: "docker"},
	} {
		if err := store.writeCurrent("goose", bad); err != nil {
			t.Fatal(err)
		}
		if read, err := store.readCurrent("goose"); read != nil || err == nil {
			t.Errorf("%+v was taken", bad)
		}
	}
	if ids := store.agentIDs(); len(ids) != 1 || ids[0] != "goose" {
		t.Fatalf("ids %v", ids)
	}
	// A link in place of a folder is refused.
	link := filepath.Join(store.root, "linked")
	if err := os.Symlink(t.TempDir(), link); err != nil {
		t.Fatal(err)
	}
	if err := privateAgentFolder(link); err == nil {
		t.Fatal("a link was taken for a folder")
	}
}
