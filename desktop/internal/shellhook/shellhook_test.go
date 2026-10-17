package shellhook

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testPrograms stands in for the host's list (host.RoutedAgentPrograms).
var testPrograms = []string{"claude", "codex", "opencode"}

// fixture is a temp home and a host state beside it.
type fixture struct {
	home, state string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	if err := os.Mkdir(home, 0o755); err != nil {
		t.Fatal(err)
	}
	return &fixture{home: home, state: filepath.Join(dir, "state", "host.json")}
}

func (f *fixture) options() Options {
	return Options{StatePath: f.state, Executable: "/Applications/AgentLand.app/Contents/MacOS/agentland-host", Home: f.home, Programs: testPrograms}
}

func (f *fixture) zshrc() string  { return filepath.Join(f.home, ".zshrc") }
func (f *fixture) backup() string { return f.zshrc() + ".agentland-backup" }

func (f *fixture) write(t *testing.T, content string) {
	t.Helper()
	if err := os.WriteFile(f.zshrc(), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) read(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.zshrc())
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func (f *fixture) on(t *testing.T) {
	t.Helper()
	if err := On(f.options()); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) off(t *testing.T) {
	t.Helper()
	if err := Off(f.options()); err != nil {
		t.Fatal(err)
	}
}

// block is the block On adds for f.
func (f *fixture) block() string {
	_, hook, _ := Paths(f.state)
	return StartMarker + "\n" +
		"# Added by AgentLand (Settings → Advanced). Turn the switch off there to remove it.\n" +
		"if [[ -r " + quote(hook) + " ]]; then source " + quote(hook) + "; fi\n" +
		EndMarker + "\n"
}

func exists(t *testing.T, path string) bool {
	t.Helper()
	_, err := os.Lstat(path)
	if err == nil {
		return true
	}
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatal(err)
	}
	return false
}

func TestOnAddsOneBlockAndABackupOnce(t *testing.T) {
	f := newFixture(t)
	original := "export PATH=$HOME/bin:$PATH\n"
	f.write(t, original)
	f.on(t)
	f.on(t)
	if got, want := f.read(t), original+"\n"+f.block(); got != want {
		t.Fatalf(".zshrc after On, On:\n%q\nwant\n%q", got, want)
	}
	if got := strings.Count(f.read(t), StartMarker); got != 1 {
		t.Fatalf("%d blocks", got)
	}
	backup, err := os.ReadFile(f.backup())
	if err != nil || string(backup) != original {
		t.Fatalf("backup %q, %v; want %q", backup, err, original)
	}
	if info, err := os.Stat(f.backup()); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("backup mode %v, %v", info.Mode(), err)
	}
	// Written once: a later On, after the user changed the file, keeps the
	// first original.
	f.off(t)
	f.write(t, "export EDITOR=vi\n")
	f.on(t)
	if backup, err := os.ReadFile(f.backup()); err != nil || string(backup) != original {
		t.Fatalf("backup after a second cycle %q, %v; want %q", backup, err, original)
	}
}

// On writes the hook script and the switch, private to this user.
func TestOnWritesTheHookAndTheSwitch(t *testing.T) {
	f := newFixture(t)
	f.on(t)
	dir, hook, state := Paths(f.state)
	if want := filepath.Join(filepath.Dir(f.state), "shell"); dir != want || hook != filepath.Join(want, "agentland.zsh") || state != filepath.Join(want, "routing") {
		t.Fatalf("Paths = %q %q %q", dir, hook, state)
	}
	for path, mode := range map[string]fs.FileMode{dir: 0o700 | fs.ModeDir, hook: 0o600, state: 0o600} {
		info, err := os.Stat(path)
		if err != nil || info.Mode() != mode {
			t.Fatalf("%s: %v %v, want %v", path, info.Mode(), err, mode)
		}
	}
	data, err := os.ReadFile(hook)
	if err != nil || string(data) != Script(f.options().Executable, f.state, state, testPrograms) {
		t.Fatalf("hook %q, %v", data, err)
	}
	if data, err := os.ReadFile(state); err != nil || string(data) != "on\n" {
		t.Fatalf("switch %q, %v", data, err)
	}
	if !SwitchOn(f.state) {
		t.Fatal("SwitchOn after On is false")
	}
}

func TestOffRestoresTheFileExactly(t *testing.T) {
	for name, original := range map[string]string{
		"a trailing newline":    "export A=1\n",
		"no trailing newline":   "export A=1",
		"a trailing blank line": "export A=1\n\n",
		"an empty file":         "",
		"only a comment":        "# mine",
	} {
		for steps, run := range map[string]func(t *testing.T, f *fixture){
			"on, off":        func(t *testing.T, f *fixture) { f.on(t); f.off(t) },
			"on, on, off":    func(t *testing.T, f *fixture) { f.on(t); f.on(t); f.off(t) },
			"on, pause, off": func(t *testing.T, f *fixture) { f.on(t); f.pause(t); f.off(t) },
			"on, pause, on, off": func(t *testing.T, f *fixture) {
				f.on(t)
				f.pause(t)
				f.on(t)
				f.off(t)
			},
		} {
			t.Run(name+"/"+steps, func(t *testing.T) {
				f := newFixture(t)
				f.write(t, original)
				run(t, f)
				if got := f.read(t); got != original {
					t.Fatalf("after %s: %q, want %q", steps, got, original)
				}
				dir, _, _ := Paths(f.state)
				if exists(t, dir) {
					t.Fatal("the hook folder is still there")
				}
			})
		}
	}
}

func (f *fixture) pause(t *testing.T) {
	t.Helper()
	if err := Pause(f.options()); err != nil {
		t.Fatal(err)
	}
}

// Lines the user added after the block stay, and so does the newline On
// added to end their last line, which now ends a line in the middle.
func TestOffAfterTheUserAddedLinesBelowTheBlock(t *testing.T) {
	f := newFixture(t)
	f.write(t, "export A=1")
	f.on(t)
	f.write(t, f.read(t)+"alias ll='ls -l'\n")
	f.off(t)
	if got, want := f.read(t), "export A=1\nalias ll='ls -l'\n"; got != want {
		t.Fatalf("%q, want %q", got, want)
	}
}

func TestOffRemovesAnEditedBlock(t *testing.T) {
	f := newFixture(t)
	original := "export A=1\n"
	f.write(t, original)
	f.on(t)
	edited := strings.Replace(f.read(t), "# Added by AgentLand", "# I changed this line; Added by AgentLand", 1)
	edited = strings.Replace(edited, "then source", "then . ", 1)
	f.write(t, edited)
	f.off(t)
	if got := f.read(t); got != original {
		t.Fatalf("%q, want %q", got, original)
	}
}

func TestDamagedMarkersChangeNothing(t *testing.T) {
	for name, content := range map[string]string{
		"a start without an end": "export A=1\n" + StartMarker + "\nsource x\n",
		"an end without a start": "export A=1\nsource x\n" + EndMarker + "\n",
		"two starts":             StartMarker + "\n" + StartMarker + "\nsource x\n" + EndMarker + "\n",
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.write(t, content)
			for action, call := range map[string]func(Options) error{"On": On, "Off": Off, "Pause": Pause} {
				err := call(f.options())
				var damaged *DamagedBlockError
				if !errors.As(err, &damaged) || damaged.Path != f.zshrc() {
					t.Fatalf("%s: %v", action, err)
				}
				want := "AgentLand's block in " + f.zshrc() + ` is damaged. Remove the lines from "# >>> AgentLand: coding agents from Terminal >>>" to "# <<< AgentLand: coding agents from Terminal <<<" by hand, then try again.`
				if err.Error() != want {
					t.Fatalf("%s: %q", action, err.Error())
				}
				if got := f.read(t); got != content {
					t.Fatalf("%s changed the file: %q", action, got)
				}
				dir, _, _ := Paths(f.state)
				if exists(t, dir) || exists(t, f.backup()) {
					t.Fatalf("%s wrote the hook folder or a backup", action)
				}
			}
			status, err := Get(f.options())
			if err != nil || status.Block != "damaged" {
				t.Fatalf("Get: %+v %v", status, err)
			}
		})
	}
}

// A damaged block doesn't keep routing on: Off and Pause still take the
// switch away, leave .zshrc and the hook script as they are, and then say
// the block is damaged. An Off once the user has repaired it finishes.
func TestADamagedBlockStillTurnsRoutingOff(t *testing.T) {
	for action, call := range map[string]func(Options) error{"off": Off, "pause": Pause} {
		t.Run(action, func(t *testing.T) {
			f := newFixture(t)
			original := "export A=1\n"
			f.write(t, original)
			f.on(t)
			healthy := f.read(t)
			damaged := healthy + StartMarker + "\n"
			f.write(t, damaged)
			_, hook, state := Paths(f.state)
			script, err := os.ReadFile(hook)
			if err != nil {
				t.Fatal(err)
			}
			var damagedErr *DamagedBlockError
			if err := call(f.options()); !errors.As(err, &damagedErr) || damagedErr.Path != f.zshrc() {
				t.Fatalf("%s: %v", action, err)
			}
			if SwitchOn(f.state) || exists(t, state) {
				t.Fatalf("%s left routing on", action)
			}
			if got := f.read(t); got != damaged {
				t.Fatalf("%s changed .zshrc: %q", action, got)
			}
			if data, err := os.ReadFile(hook); err != nil || string(data) != string(script) {
				t.Fatalf("%s changed the hook script: %q, %v", action, data, err)
			}
			f.write(t, healthy)
			f.off(t)
			if got := f.read(t); got != original {
				t.Fatalf("after the repair, Off left %q", got)
			}
		})
	}
}

// hardLink makes .zshrc a hard link to a file in a dotfiles folder, as
// some dotfile managers do, and returns that file.
func (f *fixture) hardLink(t *testing.T) string {
	t.Helper()
	dotfiles := filepath.Join(filepath.Dir(f.home), "dotfiles")
	if err := os.MkdirAll(dotfiles, 0o755); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dotfiles, "zshrc")
	if err := os.Link(f.zshrc(), other); err != nil {
		t.Fatal(err)
	}
	return other
}

// sameFile says .zshrc and other are still one file.
func (f *fixture) sameFile(t *testing.T, other string) bool {
	t.Helper()
	a, err := os.Stat(f.zshrc())
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.Stat(other)
	if err != nil {
		t.Fatal(err)
	}
	return os.SameFile(a, b)
}

// A hard-linked .zshrc is refused rather than split from its other link by
// the temp file and rename every change goes through: On changes nothing,
// and Off still turns routing off and removes the hook script, leaves the
// file as it is and says why, as for a .zshrc it can't read.
func TestAHardLinkedZshrcIsRefused(t *testing.T) {
	want := func(t *testing.T, f *fixture, err error) {
		t.Helper()
		message := f.zshrc() + " is a hard link, which AgentLand's change would break. Replace it with a symbolic link or a copy, then try again."
		if err == nil || err.Error() != message {
			t.Fatalf("%v; want %q", err, message)
		}
	}
	t.Run("on", func(t *testing.T) {
		f := newFixture(t)
		original := "export A=1\n"
		f.write(t, original)
		other := f.hardLink(t)
		want(t, f, On(f.options()))
		if got := f.read(t); got != original || !f.sameFile(t, other) {
			t.Fatalf("On changed .zshrc: %q", got)
		}
		if dir, _, _ := Paths(f.state); exists(t, dir) || exists(t, f.backup()) {
			t.Fatal("On wrote the hook folder or a backup")
		}
	})
	t.Run("off", func(t *testing.T) {
		f := newFixture(t)
		original := "export A=1\n"
		f.write(t, original)
		f.on(t)
		withBlock := f.read(t)
		other := f.hardLink(t)
		want(t, f, Off(f.options()))
		_, hook, state := Paths(f.state)
		if SwitchOn(f.state) || exists(t, state) || exists(t, hook) {
			t.Fatal("Off left routing on or the hook script")
		}
		if got := f.read(t); got != withBlock || !f.sameFile(t, other) {
			t.Fatalf("Off changed .zshrc: %q", got)
		}
		if err := os.Remove(other); err != nil {
			t.Fatal(err)
		}
		f.off(t)
		if got := f.read(t); got != original {
			t.Fatalf("once one file, Off left %q", got)
		}
	})
}

func TestOnEditsThroughASymlinkedZshrc(t *testing.T) {
	f := newFixture(t)
	dotfiles := filepath.Join(filepath.Dir(f.home), "dotfiles")
	if err := os.Mkdir(dotfiles, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dotfiles, "zshrc")
	original := "export A=1\n# from my dotfiles"
	if err := os.WriteFile(target, []byte(original), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(target, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../dotfiles/zshrc", f.zshrc()); err != nil {
		t.Fatal(err)
	}
	isLink := func() {
		t.Helper()
		info, err := os.Lstat(f.zshrc())
		if err != nil || info.Mode()&fs.ModeSymlink == 0 {
			t.Fatalf(".zshrc is no longer a link: %v %v", info.Mode(), err)
		}
	}
	f.on(t)
	isLink()
	data, err := os.ReadFile(target)
	if err != nil || !strings.HasSuffix(string(data), f.block()) || !strings.HasPrefix(string(data), original) {
		t.Fatalf("target %q, %v", data, err)
	}
	if info, err := os.Stat(target); err != nil || info.Mode().Perm() != 0o640 {
		t.Fatalf("target mode %v %v", info.Mode(), err)
	}
	if backup, err := os.ReadFile(f.backup()); err != nil || string(backup) != original {
		t.Fatalf("backup %q, %v", backup, err)
	}
	f.off(t)
	isLink()
	if data, err := os.ReadFile(target); err != nil || string(data) != original {
		t.Fatalf("target after Off %q, %v", data, err)
	}
	if leftovers, _ := filepath.Glob(filepath.Join(dotfiles, ".*")); len(leftovers) != 0 {
		t.Fatalf("temp files left beside the target: %q", leftovers)
	}
}

func TestMissingZshrcIsCreatedAndRemoved(t *testing.T) {
	f := newFixture(t)
	f.on(t)
	info, err := os.Stat(f.zshrc())
	if err != nil || info.Mode().Perm() != 0o644 {
		t.Fatalf(".zshrc %v %v", info.Mode(), err)
	}
	if got := f.read(t); got != f.block() {
		t.Fatalf("%q", got)
	}
	if exists(t, f.backup()) {
		t.Fatal("a backup of a file that did not exist")
	}
	f.on(t)
	if exists(t, f.backup()) {
		t.Fatal("a second On backed up AgentLand's own file")
	}
	f.off(t)
	if exists(t, f.zshrc()) {
		t.Fatal(".zshrc is still there")
	}
}

// Off deletes .zshrc only when On made it, whatever backups there are: a
// backup of an earlier file doesn't keep an empty file On created behind
// (also after a Pause), and a missing backup doesn't take away an empty
// file the user had.
func TestOffDeletesTheZshrcOnlyWhenOnMadeIt(t *testing.T) {
	t.Run("made by On, with a backup of an earlier file", func(t *testing.T) {
		f := newFixture(t)
		f.write(t, "export A=1\n")
		f.on(t)
		f.off(t)
		if !exists(t, f.backup()) {
			t.Fatal("no backup of the earlier file")
		}
		if err := os.Remove(f.zshrc()); err != nil {
			t.Fatal(err)
		}
		f.on(t)
		f.pause(t)
		f.on(t)
		f.off(t)
		if exists(t, f.zshrc()) {
			t.Fatalf("the .zshrc On made is still there: %q", f.read(t))
		}
		if dir, _, _ := Paths(f.state); exists(t, dir) {
			t.Fatal("the hook folder is still there")
		}
	})
	t.Run("the user's empty file, its backup gone", func(t *testing.T) {
		f := newFixture(t)
		f.write(t, "")
		f.on(t)
		if err := os.Remove(f.backup()); err != nil {
			t.Fatal(err)
		}
		f.off(t)
		if !exists(t, f.zshrc()) || f.read(t) != "" {
			t.Fatal("Off took away the user's empty .zshrc")
		}
	})
}

// A .zshrc AgentLand can't read (here a link into a dotfiles folder that
// moved) doesn't keep routing on: Pause and Off turn the switch off first,
// and Off says which file it could not change. What On recorded about the
// file stays, so an Off once the link works again leaves it exactly as it was.
func TestAZshrcThatCannotBeReadStillTurnsRoutingOff(t *testing.T) {
	for _, action := range []string{"pause", "off"} {
		t.Run(action, func(t *testing.T) {
			f := newFixture(t)
			dotfiles := filepath.Join(filepath.Dir(f.home), "dotfiles")
			if err := os.Mkdir(dotfiles, 0o755); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(dotfiles, "zshrc")
			original := "export A=1" // On ends this line, and records that it did
			if err := os.WriteFile(target, []byte(original), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, f.zshrc()); err != nil {
				t.Fatal(err)
			}
			f.on(t)
			if err := os.Rename(target, target+".moved"); err != nil {
				t.Fatal(err)
			}
			_, hook, state := Paths(f.state)
			if action == "pause" {
				if err := Pause(f.options()); err != nil {
					t.Fatalf("Pause: %v", err)
				}
			} else {
				err := Off(f.options())
				if err == nil || !strings.Contains(err.Error(), f.zshrc()) {
					t.Fatalf("Off: %v; want an error naming %s", err, f.zshrc())
				}
				if exists(t, hook) {
					t.Fatal("Off left the hook script")
				}
			}
			if SwitchOn(f.state) || exists(t, state) {
				t.Fatalf("%s left routing on", action)
			}
			if err := os.Rename(target+".moved", target); err != nil {
				t.Fatal(err)
			}
			f.off(t)
			if data, err := os.ReadFile(target); err != nil || string(data) != original {
				t.Fatalf("the target after Off: %q, %v; want %q", data, err, original)
			}
			if dir, _, _ := Paths(f.state); exists(t, dir) {
				t.Fatal("the hook folder is still there")
			}
		})
	}
}

func TestPauseKeepsTheBlockAndStopsRouting(t *testing.T) {
	f := newFixture(t)
	original := "export A=1\n"
	f.write(t, original)
	f.on(t)
	f.pause(t)
	_, hook, state := Paths(f.state)
	if exists(t, state) || SwitchOn(f.state) {
		t.Fatal("the switch file is still there")
	}
	if !exists(t, hook) || !strings.Contains(f.read(t), f.block()) {
		t.Fatal("Pause took the hook or the block away")
	}
	if status, err := Get(f.options()); err != nil || status.On || status.Block != "present" {
		t.Fatalf("%+v %v", status, err)
	}
	f.pause(t) // twice is fine
	f.off(t)
	if got := f.read(t); got != original {
		t.Fatalf("%q", got)
	}
}

func TestStatusReportsTheBlock(t *testing.T) {
	f := newFixture(t)
	check := func(on bool, block string) {
		t.Helper()
		status, err := Get(f.options())
		if err != nil || status != (Status{On: on, Block: block, Zshrc: f.zshrc()}) {
			t.Fatalf("%+v %v; want on %v, %s", status, err, on, block)
		}
	}
	check(false, "absent")
	f.write(t, "export A=1\n")
	check(false, "absent")
	f.on(t)
	check(true, "present")
	data, err := json.Marshal(Status{On: true, Block: "present", Zshrc: "/z"})
	if err != nil || string(data) != `{"on":true,"block":"present","zshrc":"/z"}` {
		t.Fatalf("%s %v", data, err)
	}
	f.write(t, f.read(t)+EndMarker+"\n")
	check(true, "damaged")
}

func TestScriptQuotesPathsAndListsTheTable(t *testing.T) {
	script := Script("/Apps/It's here/agentland-host", "/s/host.json", "/s/shell/routing", []string{"claude", "copilot", "bad name", "opencode", "claude"})
	for _, want := range []string{
		`typeset -g _agentland_bin='/Apps/It'\''s here/agentland-host' _agentland_state='/s/host.json' _agentland_switch='/s/shell/routing'`,
		`typeset -gA _agentland_subcommands=(claude 'update upgrade mcp doctor config install migrate-installer setup-token plugin plugins auth auto-mode agents attach logs stop kill rm respawn purge import gateway ultrareview' opencode 'run serve web acp mcp models stats export import github upgrade uninstall auth agent debug')`,
		`typeset -gA _agentland_own_flags=(claude '--bg --background')`,
		"for _agentland_name in claude copilot opencode; do\n",
		`eval "function ${_agentland_name} { _agentland_route ${_agentland_name} \"\$@\"; }"`,
	} {
		if !strings.Contains(script, want) {
			t.Errorf("no %q in\n%s", want, script)
		}
	}
	if strings.Contains(script, "bad name") {
		t.Error("a name that is not a plain command made it into the script")
	}
}
