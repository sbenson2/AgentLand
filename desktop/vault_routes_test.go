package host

import (
	"encoding/json"
	"errors"
	"io/fs"
	"maps"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// vaultHostFixture is a host with terminals, the archive and this Mac's
// session, which offers the vault at a default folder that does not exist yet.
type vaultHostFixture struct {
	t       *testing.T
	host    *Host
	store   *Store
	archive *Archive
	fixture *terminalFixture
	token   string // a paired device's
	folder  string // the default folder
}

func newVaultHost(t *testing.T) *vaultHostFixture {
	t.Helper()
	_, store, agent := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	fixture := newTerminalFixture(agent)
	folder := filepath.Join(t.TempDir(), "AgentLand Vault")
	host := newHost(store, fixture, HostOptions{TerminalEnabled: true, Terminals: fixture.fakeTerminals, LocalSessionToken: routeLocalToken, Archive: archive, Vault: &VaultOptions{DefaultFolder: folder}})
	fakeTerminalPrograms(host, false)
	// The writer stops before the archive closes.
	t.Cleanup(host.vault.close)
	return &vaultHostFixture{t: t, host: host, store: store, archive: archive, fixture: fixture, token: paired(t, host, store), folder: folder}
}

func (f *vaultHostFixture) status() vaultAnswer {
	f.t.Helper()
	w := localRequest(f.t, f.host.Handler(), "GET", "/v1/vault", routeLocalToken, nil)
	if w.Code != 200 {
		f.t.Fatalf("vault status: %d %s", w.Code, w.Body)
	}
	return decodeBody[vaultAnswer](f.t, w)
}

func (f *vaultHostFixture) post(path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	return localRequest(f.t, f.host.Handler(), "POST", path, routeLocalToken, body)
}

// set changes the settings and returns the status it answers.
func (f *vaultHostFixture) set(body any) vaultAnswer {
	f.t.Helper()
	w := f.post("/v1/vault/settings", body)
	if w.Code != 200 {
		f.t.Fatalf("vault settings %v: %d %s", body, w.Code, w.Body)
	}
	return decodeBody[vaultAnswer](f.t, w)
}

// settle waits until the vault is current with notes notes.
func (f *vaultHostFixture) settle(notes int64) vaultAnswer {
	f.t.Helper()
	flushArchive(f.t, f.archive)
	var status vaultAnswer
	vaultWaitFor(f.t, "the vault to be current", func() bool {
		status = f.status()
		if status.State == "paused" {
			f.t.Fatalf("the vault paused: %+v", status)
		}
		return status.State == "current" && status.Notes == notes
	})
	return status
}

func (f *vaultHostFixture) settings() *VaultSettings {
	f.t.Helper()
	state, err := f.store.Read()
	if err != nil {
		f.t.Fatal(err)
	}
	return state.Vault
}

// vaultMarkdown lists the Markdown files under folder/sub.
func vaultMarkdown(t *testing.T, folder, sub string) []string {
	t.Helper()
	notes := []string{}
	err := filepath.WalkDir(filepath.Join(folder, sub), func(path string, entry fs.DirEntry, err error) error {
		if err == nil && strings.HasSuffix(path, ".md") {
			relative, _ := filepath.Rel(folder, path)
			notes = append(notes, filepath.ToSlash(relative))
		}
		return err
	})
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		t.Fatal(err)
	}
	return notes
}

func TestVaultIsOffByDefault(t *testing.T) {
	_, store, agent := testHost(t)
	archive := testArchive(t, ArchiveOptions{})
	mustArchiveChat(t, archive, "c1", "p1", "Fix the build")
	flushArchive(t, archive)
	folder := filepath.Join(t.TempDir(), "AgentLand Vault")
	host := NewWithOptions(store, agent, HostOptions{LocalSessionToken: routeLocalToken, Archive: archive, Vault: &VaultOptions{DefaultFolder: folder}})
	f := &vaultHostFixture{t: t, host: host, store: store, archive: archive}

	status := f.status()
	want := vaultAnswer{Folder: folder, DefaultFolder: folder, Terminals: true, State: "off"}
	if !reflect.DeepEqual(status, want) {
		t.Fatalf("status %+v, want %+v", status, want)
	}
	if host.vault.writer != nil || f.settings() != nil {
		t.Fatalf("a vault runs or is saved: %v %+v", host.vault.writer, f.settings())
	}
	raw, err := os.ReadFile(store.Path)
	if err != nil || strings.Contains(string(raw), `"vault"`) {
		t.Fatalf("state file %s %v", raw, err)
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(folder); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the vault folder was made: %v", err)
	}
}

func TestVaultSettingsApplyWithoutEndingSessions(t *testing.T) {
	f := newVaultHost(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "Fix the build")
	terminal := createTerminalFixture(t, f.host, f.token)
	f.fixture.emit(terminal.ID, "make\r\n")

	if status := f.set(map[string]bool{"enabled": true}); !status.Enabled || status.State == "off" || status.Folder != f.folder {
		t.Fatalf("turned on: %+v", status)
	}
	if info, err := os.Stat(f.folder); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("vault folder %v %v", info, err)
	}
	// The chat's note and the running terminal's.
	f.settle(2)
	if notes := vaultMarkdown(t, f.folder, "Terminals"); len(notes) != 1 {
		t.Fatalf("terminal notes %v", notes)
	}

	stillRunning := func(label string) {
		t.Helper()
		w := request(t, f.host.Handler(), "GET", "/v1/terminals?projectId=p1", f.token, nil)
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"id":"`+terminal.ID+`"`) || !strings.Contains(w.Body.String(), `"status":"running"`) {
			t.Fatalf("%s: terminals %d %s", label, w.Code, w.Body)
		}
		if ends := f.fixture.endedIDs(); len(ends) != 0 {
			t.Fatalf("%s: terminals %v ended", label, ends)
		}
	}
	off := f.set(map[string]bool{"enabled": false})
	if off.Enabled || off.State != "off" || off.Notes != 2 || f.host.vault.writer != nil {
		t.Fatalf("turned off: %+v", off)
	}
	stillRunning("off")
	if notes := vaultMarkdown(t, f.folder, "Chats"); len(notes) != 1 {
		t.Fatalf("turning off removed notes: %v", notes)
	}
	w := request(t, f.host.Handler(), "POST", "/v1/terminal/input", f.token, map[string]any{"projectId": "p1", "terminalId": terminal.ID, "data": []byte("ls\n")})
	if w.Code != 200 && w.Code != 202 {
		t.Fatalf("input after turning off: %d %s", w.Code, w.Body)
	}
	vaultWaitFor(t, "the input to reach the shell", func() bool { return f.fixture.input(terminal.ID) == "ls\n" })

	if on := f.set(map[string]bool{"enabled": true}); !on.Enabled {
		t.Fatalf("turned on again: %+v", on)
	}
	mustArchiveChat(t, f.archive, "c2", "p1", "Plan the vault")
	f.settle(3)
	stillRunning("on again")
}

func TestVaultSettingsValidateFolder(t *testing.T) {
	f := newVaultHost(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	stateFolder := filepath.Dir(f.store.Path)
	scratch := t.TempDir()
	file := filepath.Join(scratch, "notes.txt")
	if err := os.WriteFile(file, []byte("mine"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(scratch, "state-link")
	if err := os.Symlink(stateFolder, link); err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct {
		label   string
		body    any
		status  int
		code    string
		message string
	}{
		{"nothing", map[string]any{}, 400, "invalid_request", "Send enabled, folder, terminals or adopt"},
		{"a relative folder", map[string]string{"folder": "AgentLand Vault"}, 400, "invalid_folder", "Choose an absolute folder for the vault"},
		{"the top folder", map[string]string{"folder": "/"}, 400, "invalid_folder", "The vault needs a folder of its own, not the disk's top folder"},
		{"the home folder", map[string]string{"folder": home + "/"}, 400, "invalid_folder", "The vault needs a folder of its own, not your home folder"},
		{"the state folder", map[string]string{"folder": stateFolder}, 400, "invalid_folder", "The vault cannot be in AgentLand's own state folder"},
		{"inside the state folder", map[string]string{"folder": filepath.Join(stateFolder, "Vault")}, 400, "invalid_folder", "The vault cannot be in AgentLand's own state folder"},
		{"a link to the state folder", map[string]string{"folder": filepath.Join(link, "Vault")}, 400, "invalid_folder", "The vault cannot be in AgentLand's own state folder"},
		{"a file", map[string]string{"folder": file}, 400, "invalid_folder", "That is a file; choose a folder for the vault"},
		{"a control character", map[string]string{"folder": scratch + "/a\nb"}, 400, "invalid_folder", "Choose an absolute folder for the vault"},
	} {
		w := f.post("/v1/vault/settings", check.body)
		wantRouteError(t, check.label, w, check.status, check.code, check.message)
	}
	if os.Geteuid() != 0 {
		locked := filepath.Join(scratch, "locked")
		if err := os.Mkdir(locked, 0o500); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(locked, 0o700) })
		for _, folder := range []string{locked, filepath.Join(locked, "Vault")} {
			w := f.post("/v1/vault/settings", map[string]any{"enabled": true, "folder": folder})
			if w.Code != 409 || !strings.Contains(w.Body.String(), `"code":"folder_unwritable"`) || !strings.Contains(w.Body.String(), "AgentLand cannot write in "+folder) {
				t.Fatalf("unwritable %s: %d %s", folder, w.Code, w.Body)
			}
		}
	}
	if settings := f.settings(); settings != nil || f.host.vault.writer != nil {
		t.Fatalf("a refused change was kept: %+v", settings)
	}
	if _, err := os.Stat(f.folder); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the default folder was made: %v", err)
	}

	// A folder chosen while the vault is off is only saved, cleaned.
	chosen := filepath.Join(scratch, "Obsidian", "AgentLand")
	status := f.set(map[string]string{"folder": chosen + "/"})
	if status.Enabled || status.Folder != chosen || status.DefaultFolder != f.folder {
		t.Fatalf("chosen folder: %+v", status)
	}
	if _, err := os.Stat(chosen); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a folder was made while off: %v", err)
	}
	// Turned on, it is made; inside an Obsidian vault, that vault is named.
	if err := os.MkdirAll(filepath.Join(scratch, "Obsidian", ".obsidian"), 0o700); err != nil {
		t.Fatal(err)
	}
	on := f.set(map[string]bool{"enabled": true})
	if !on.Enabled || on.Folder != chosen || on.ObsidianVault != filepath.Join(scratch, "Obsidian") {
		t.Fatalf("turned on: %+v", on)
	}
	if info, err := os.Stat(chosen); err != nil || !info.IsDir() {
		t.Fatalf("chosen folder %v", err)
	}
	// An empty folder goes back to the default.
	if status := f.set(map[string]string{"folder": ""}); status.Folder != f.folder || f.settings().Folder != f.folder {
		t.Fatalf("default again: %+v %+v", status, f.settings())
	}
}

func TestVaultSettingsKeepOtherState(t *testing.T) {
	f := newVaultHost(t)
	if _, err := f.store.CreatePairingCode(time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := f.store.update(func(state *State) error {
		state.AutomaticUpdates = true
		state.RemovedProjects = []RemovedProject{{ID: "old-1", Directory: t.TempDir()}}
		state.RemoteAccess = &RemoteAccessReport{Enabled: true, NodeID: strings.Repeat("a", 64), UDPPort: 38842, Sequence: 3}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	before, err := f.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	f.set(map[string]bool{"enabled": true})
	f.set(map[string]any{"terminals": false, "folder": filepath.Join(t.TempDir(), "Other")})
	f.set(map[string]bool{"enabled": false})
	after, err := f.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	saved := after.Vault
	after.Vault = nil
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("state changed:\n%+v\nwas\n%+v", after, before)
	}
	if saved == nil || saved.Enabled || saved.Terminals == nil || *saved.Terminals || saved.ID == "" {
		t.Fatalf("vault settings %+v", saved)
	}
}

func TestVaultCapabilityOnlyForThisMac(t *testing.T) {
	f := newVaultHost(t)
	capabilities := func(host *Host, local bool, token string) string {
		t.Helper()
		var w *httptest.ResponseRecorder
		if local {
			w = localRequest(t, host.Handler(), "GET", "/v1/capabilities", routeLocalToken, nil)
		} else {
			w = request(t, host.Handler(), "GET", "/v1/capabilities", token, nil)
		}
		if w.Code != 200 {
			t.Fatalf("capabilities: %d %s", w.Code, w.Body)
		}
		return w.Body.String()
	}
	if body := capabilities(f.host, true, ""); !strings.Contains(body, `"vault":{"version":1}`) {
		t.Fatalf("this Mac's capabilities %s", body)
	}
	if body := capabilities(f.host, false, f.token); strings.Contains(body, `"vault"`) {
		t.Fatalf("a device's capabilities %s", body)
	}
	if w := request(t, f.host.Handler(), "GET", "/v1/vault", f.token, nil); w.Code != 403 {
		t.Fatalf("a device read the vault: %d %s", w.Code, w.Body)
	}

	// Without the vault's options, or without an archive, there is no vault.
	_, store, agent := testHost(t)
	for label, options := range map[string]HostOptions{
		"no options": {LocalSessionToken: routeLocalToken, Archive: testArchive(t, ArchiveOptions{})},
		"no archive": {LocalSessionToken: routeLocalToken, Vault: &VaultOptions{DefaultFolder: filepath.Join(t.TempDir(), "Vault")}},
	} {
		host := newHost(store, agent, options)
		if host.vault != nil {
			t.Fatalf("%s: a vault", label)
		}
		if body := capabilities(host, true, ""); strings.Contains(body, `"vault"`) {
			t.Fatalf("%s: capabilities %s", label, body)
		}
		for _, route := range [][2]string{{"GET", "/v1/vault"}, {"POST", "/v1/vault/settings"}, {"POST", "/v1/vault/rebuild"}} {
			w := localRequest(t, host.Handler(), route[0], route[1], routeLocalToken, map[string]bool{"enabled": true})
			wantRouteError(t, label+" "+route[1], w, 503, "vault_unavailable", "This host keeps no archive, so it has no vault")
		}
	}
}

func TestVaultSettingsSurviveRestart(t *testing.T) {
	_, store, agent := testHost(t)
	directory := filepath.Join(t.TempDir(), "state.json.archive")
	folder := filepath.Join(t.TempDir(), "AgentLand Vault")
	start := func() (*Host, *Archive) {
		archive, err := OpenArchive(directory, ArchiveOptions{BatchDelay: 2 * time.Millisecond, FreeSpace: func(string) (uint64, error) { return 64 << 30, nil }})
		if err != nil {
			t.Fatal(err)
		}
		host := NewWithOptions(store, agent, HostOptions{LocalSessionToken: routeLocalToken, Archive: archive, Vault: &VaultOptions{DefaultFolder: folder}})
		t.Cleanup(func() { host.Close() })
		return host, archive
	}
	host, archive := start()
	f := &vaultHostFixture{t: t, host: host, store: store, archive: archive}
	mustArchiveChat(t, archive, "c1", "p1", "Fix the build")
	f.set(map[string]any{"enabled": true, "terminals": false})
	f.settle(1)
	saved := f.settings()
	notes := vaultMarkdown(t, folder, "Chats")
	if len(notes) != 1 {
		t.Fatalf("notes %v", notes)
	}
	note := filepath.Join(folder, filepath.FromSlash(notes[0]))
	written, err := os.Stat(note)
	if err != nil {
		t.Fatal(err)
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	if host.vault.writer != nil {
		t.Fatal("Close left the writer running")
	}
	wantRouteError(t, "a change after Close", f.post("/v1/vault/settings", map[string]bool{"enabled": true}), 503, "vault_unavailable", "The host is stopping")

	host, archive = start()
	f.host, f.archive = host, archive
	if host.vault.writer == nil {
		t.Fatal("the vault did not start with the host")
	}
	mustArchiveChat(t, archive, "c2", "p1", "Plan the vault")
	status := f.settle(2)
	if !status.Enabled || status.Terminals || status.Folder != folder || !reflect.DeepEqual(f.settings(), saved) {
		t.Fatalf("after a restart: %+v, saved %+v, was %+v", status, f.settings(), saved)
	}
	if again, err := os.Stat(note); err != nil || !again.ModTime().Equal(written.ModTime()) {
		t.Fatalf("the first note was written again: %v", err)
	}
}

func TestVaultRebuildWritesEverythingAgain(t *testing.T) {
	f := newVaultHost(t)
	wantRouteError(t, "rebuild while off", f.post("/v1/vault/rebuild", nil), 409, "vault_off", "Turn the vault on to rebuild it")
	mustArchiveChat(t, f.archive, "c1", "p1", "Fix the build")
	mustArchiveChat(t, f.archive, "c2", "p1", "Plan the vault")
	f.set(map[string]bool{"enabled": true})
	f.settle(2)
	notes := vaultMarkdown(t, f.folder, "Chats")
	if len(notes) != 2 {
		t.Fatalf("notes %v", notes)
	}
	deleted := filepath.Join(f.folder, filepath.FromSlash(notes[0]))
	kept := filepath.Join(f.folder, filepath.FromSlash(notes[1]))
	if err := os.Remove(deleted); err != nil {
		t.Fatal(err)
	}
	text, err := os.ReadFile(kept)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kept, append(text, "My own note.\n"...), 0o600); err != nil {
		t.Fatal(err)
	}
	mine := filepath.Join(f.folder, vaultNotesFolder, "Mine.md")
	if err := os.WriteFile(mine, []byte("Mine.\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	w := f.post("/v1/vault/rebuild", nil)
	if w.Code != 200 {
		t.Fatalf("rebuild: %d %s", w.Code, w.Body)
	}
	vaultWaitFor(t, "the deleted note to come back", func() bool {
		_, err := os.Stat(deleted)
		return err == nil && f.status().State == "current"
	})
	if again, err := os.ReadFile(kept); err != nil || !strings.HasSuffix(string(again), "My own note.\n") {
		t.Fatalf("the user's text: %q %v", again, err)
	}
	if text, err := os.ReadFile(mine); err != nil || string(text) != "Mine.\n" {
		t.Fatalf("Notes/ changed: %q %v", text, err)
	}
	if status := f.status(); status.Notes != 2 || status.Backfill.Total != 2 || status.Backfill.Done != 2 {
		t.Fatalf("status after a rebuild %+v", status)
	}
}

func TestVaultNewFolderStartsANewVault(t *testing.T) {
	f := newVaultHost(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "Fix the build")
	f.set(map[string]bool{"enabled": true})
	f.settle(1)
	first := f.settings().ID
	before := vaultTree(t, f.folder)

	other := filepath.Join(t.TempDir(), "Other Vault")
	if status := f.set(map[string]string{"folder": other}); status.Folder != other || f.settings().ID == first {
		t.Fatalf("new folder: %+v %+v", status, f.settings())
	}
	f.settle(1)
	if notes := vaultMarkdown(t, other, "Chats"); len(notes) != 1 {
		t.Fatalf("the new folder's notes %v", notes)
	}
	mustArchiveChat(t, f.archive, "c2", "p1", "Plan the vault")
	f.settle(2)
	if after := vaultTree(t, f.folder); !maps.Equal(after, before) {
		t.Fatal("the old folder changed")
	}

	// Back at the first folder, its vault goes on where it was.
	f.set(map[string]string{"folder": f.folder})
	if f.settings().ID != first {
		t.Fatalf("vault %q, want %q", f.settings().ID, first)
	}
	f.settle(2)
	if notes := vaultMarkdown(t, f.folder, "Chats"); len(notes) != 2 {
		t.Fatalf("notes %v", notes)
	}

	// A folder deleted while the vault was off is written whole when it is
	// turned on again.
	f.set(map[string]bool{"enabled": false})
	if err := os.RemoveAll(f.folder); err != nil {
		t.Fatal(err)
	}
	f.set(map[string]bool{"enabled": true})
	f.settle(2)
	if notes := vaultMarkdown(t, f.folder, "Chats"); len(notes) != 2 || f.settings().ID != first {
		t.Fatalf("notes %v in vault %q", notes, f.settings().ID)
	}
}

func TestVaultAdoptsAnotherArchivesFolderOnce(t *testing.T) {
	f := newVaultHost(t)
	if err := os.MkdirAll(filepath.Join(f.folder, ".agentland"), 0o700); err != nil {
		t.Fatal(err)
	}
	marker, _ := json.Marshal(vaultMarker{Version: 1, Archive: "another-archive", Vault: "theirs"})
	if err := os.WriteFile(filepath.Join(f.folder, filepath.FromSlash(vaultMarkerPath)), marker, 0o600); err != nil {
		t.Fatal(err)
	}
	mustArchiveChat(t, f.archive, "c1", "p1", "Fix the build")
	f.set(map[string]bool{"enabled": true})
	vaultWaitFor(t, "the vault to pause", func() bool { return f.status().Reason == vaultPausedOther })
	if status := f.status(); status.State != "paused" || !strings.Contains(status.Message, "another AgentLand archive's vault") {
		t.Fatalf("status %+v", status)
	}

	f.set(map[string]bool{"adopt": true})
	f.settle(1)
	if raw, err := os.ReadFile(f.store.Path); err != nil || strings.Contains(string(raw), "adopt") {
		t.Fatalf("adopt was saved: %s %v", raw, err)
	}
	// Taken back by the other archive, the folder is refused again.
	if err := os.WriteFile(filepath.Join(f.folder, filepath.FromSlash(vaultMarkerPath)), marker, 0o600); err != nil {
		t.Fatal(err)
	}
	mustArchiveChat(t, f.archive, "c2", "p1", "Plan the vault")
	flushArchive(t, f.archive)
	vaultWaitFor(t, "the vault to pause again", func() bool { return f.status().Reason == vaultPausedOther })
}

func TestVaultTerminalsTurnedOnWriteEarlierTerminals(t *testing.T) {
	f := newVaultHost(t)
	mustArchiveChat(t, f.archive, "c1", "p1", "Fix the build")
	vaultTestTerminal(t, f.archive, "p1", "Build", "shell", archiveTestStart, "make\r\n", "exited")
	f.set(map[string]any{"enabled": true, "terminals": false})
	f.settle(1)
	if notes := vaultMarkdown(t, f.folder, "Terminals"); len(notes) != 0 {
		t.Fatalf("terminal notes while off: %v", notes)
	}
	if status := f.set(map[string]bool{"terminals": true}); !status.Terminals {
		t.Fatalf("terminals on: %+v", status)
	}
	f.settle(2)
	if notes := vaultMarkdown(t, f.folder, "Terminals"); len(notes) != 1 {
		t.Fatalf("terminal notes %v", notes)
	}
}
