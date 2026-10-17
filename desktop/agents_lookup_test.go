package host

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// After Homebrew, /usr/local/bin, ~/.local/bin and PATH, commands are found
// where Node.js and tool version managers keep them, in order: Volta, asdf,
// mise, fnm's default alias, nvm's default version. Only regular executable
// files count, in folders this user owns.
func TestFindCommandInVersionManagers(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the version managers' folders are Unix ones")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", t.TempDir())
	// No command of this name is in Homebrew or /usr/local/bin.
	const name = "agentland-test-tool"
	place := func(folder string) string {
		t.Helper()
		return writeScript(t, filepath.Join(home, folder, name), "exit 0\n")
	}
	found := func(want string) {
		t.Helper()
		got, ok := findCommand(name)
		if want == "" {
			if ok {
				t.Fatalf("found %q, want nothing", got)
			}
			return
		}
		if !ok || got != want {
			t.Fatalf("found %q (%v), want %q", got, ok, want)
		}
	}
	found("")
	// nvm: the highest version, unless ~/.nvm/alias/default names one.
	for _, version := range []string{"v18.20.4", "v20.9.0", "v20.11.1", "v9.11.2"} {
		place(filepath.Join(".nvm", "versions", "node", version, "bin"))
	}
	if err := os.MkdirAll(filepath.Join(home, ".nvm", "versions", "node", "system"), 0o700); err != nil {
		t.Fatal(err)
	}
	nvm := func(version string) string {
		return filepath.Join(home, ".nvm", "versions", "node", version, "bin", name)
	}
	found(nvm("v20.11.1"))
	alias := func(name, target string) {
		t.Helper()
		path := filepath.Join(home, ".nvm", "alias", filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(target+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for target, want := range map[string]string{
		"18":        "v18.20.4",
		"v20.9":     "v20.9.0",
		"v20.9.0":   "v20.9.0",
		"20":        "v20.11.1",
		"node":      "v20.11.1",
		"lts/*":     "v18.20.4", // lts/* → lts/hydrogen → v18.20.4
		"system":    "v20.11.1", // no such version: the highest
		"../../etc": "v20.11.1",
		"22":        "v20.11.1", // not installed: the highest
	} {
		alias("lts/*", "lts/hydrogen")
		alias("lts/hydrogen", "v18.20.4")
		alias("default", target)
		if got, _ := findCommand(name); got != nvm(want) {
			t.Errorf("default %q: found %q, want %q", target, got, nvm(want))
		}
	}
	alias("default", "20")
	// fnm's default alias: the macOS folder of older versions, then the
	// current one.
	fnmMac := place(filepath.Join("Library", "Application Support", "fnm", "aliases", "default", "bin"))
	found(fnmMac)
	fnm := place(filepath.Join(".local", "share", "fnm", "aliases", "default", "bin"))
	found(fnm)
	mise := place(filepath.Join(".local", "share", "mise", "shims"))
	found(mise)
	asdf := place(filepath.Join(".asdf", "shims"))
	found(asdf)
	// Volta's shims are links; a link to a regular executable counts.
	target := writeScript(t, filepath.Join(home, ".volta", "tools", "shim"), "exit 0\n")
	volta := filepath.Join(home, ".volta", "bin", name)
	if err := os.MkdirAll(filepath.Dir(volta), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, volta); err != nil {
		t.Fatal(err)
	}
	found(volta)
	// ~/.local/bin and PATH come first.
	local := place(filepath.Join(".local", "bin"))
	found(local)
	if err := os.Remove(local); err != nil {
		t.Fatal(err)
	}
	onPath := writeScript(t, filepath.Join(t.TempDir(), name), "exit 0\n")
	t.Setenv("PATH", filepath.Dir(onPath))
	found(onPath)
	t.Setenv("PATH", t.TempDir())
	// Only regular executable files: a folder or a file nobody may run is
	// passed over.
	if err := os.Remove(volta); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(volta, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(asdf, 0o600); err != nil {
		t.Fatal(err)
	}
	found(mise)
	// Folders another user owns are passed over: none of these counts for
	// another uid.
	if got, ok := findCommandAs(name, os.Getuid()+1); ok {
		t.Fatalf("found %q in another user's folders", got)
	}
}
