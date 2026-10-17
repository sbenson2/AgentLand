package host

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// The vault's settings and status (vault.go writes the vault): GET /v1/vault,
// POST /v1/vault/settings and POST /v1/vault/rebuild, for this Mac's app
// alone, and capabilities.vault for its session. The state file keeps the
// settings (State.Vault); absent, the vault is off and no folder is made. A
// change restarts only the writer, never the host: terminals, chats and their
// streams go on.
//
// Each folder is a vault of its own in the archive (vault_state's root).
// Turned on in a folder, the vault goes on where that folder's vault left off,
// or starts a new one, which writes every chat and terminal; the folder it
// leaves is left as it is. A folder the vault had to make again, or whose
// marker no longer names its vault, is written whole again (resetVault), so
// a vault folder deleted while the vault was off comes back complete.

// VaultOptions offers the vault.
type VaultOptions struct {
	// DefaultFolder is the folder of a vault turned on without one chosen
	// (serve: ~/AgentLand Vault).
	DefaultFolder string
}

// VaultSettings is the vault as the state file keeps it.
type VaultSettings struct {
	Enabled bool `json:"enabled,omitempty"`
	// Folder is the folder the vault writes in.
	Folder string `json:"folder,omitempty"`
	// Terminals says whether terminals get notes; absent, they do.
	Terminals *bool `json:"terminals,omitempty"`
	// ID names the folder's vault in the archive (vault_state). It is chosen
	// when the vault is turned on in a folder.
	ID string `json:"id,omitempty"`
}

func (s VaultSettings) terminals() bool { return s.Terminals == nil || *s.Terminals }

const (
	// vaultPathLimit bounds a folder's path, in bytes.
	vaultPathLimit = 1024
	// The bytes GET /v1/vault reports are counted again after a write, and
	// at most every vaultSizeEvery otherwise, over at most vaultSizeLimit
	// files and folders.
	vaultSizeEvery = time.Minute
	vaultSizeLimit = 100_000
)

// hostVault holds the vault's writer and serializes its changes.
type hostVault struct {
	host    *Host
	options VaultOptions
	// configure adjusts each writer before it starts (tests).
	configure func(*vaultWriter)

	mu     sync.Mutex
	writer *vaultWriter // nil while the vault is off
	closed bool
	size   vaultCount
}

// vaultCount is the last count of a vault folder's bytes.
type vaultCount struct {
	folder  string
	written time.Time // the writer's last write then
	notes   int64
	at      time.Time
	bytes   int64
}

func newHostVault(host *Host, options VaultOptions) *hostVault {
	if options.DefaultFolder != "" {
		options.DefaultFolder = filepath.Clean(options.DefaultFolder)
	}
	return &hostVault{host: host, options: options}
}

// start runs the writer when the state file says the vault is on (the host's
// start). A folder that went missing meanwhile is not made again: the writer
// pauses until it is back.
func (v *hostVault) start() {
	if v == nil {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	settings, err := v.settings()
	if err != nil || !settings.Enabled || settings.ID == "" || v.folder(settings) == "" || v.closed {
		return
	}
	v.run(settings, false)
}

// close stops the writer for good (Host.Close, before the archive closes).
func (v *hostVault) close() {
	if v == nil {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	v.closed = true
	v.stopWriter()
}

func (v *hostVault) settings() (VaultSettings, error) {
	state, err := v.host.store.Read()
	if err != nil || state.Vault == nil {
		return VaultSettings{}, err
	}
	return *state.Vault, nil
}

func (v *hostVault) folder(settings VaultSettings) string {
	if settings.Folder != "" {
		return settings.Folder
	}
	return v.options.DefaultFolder
}

// run starts a writer for settings; adopt lets it take over a folder another
// archive's marker names. Hold mu.
func (v *hostVault) run(settings VaultSettings, adopt bool) {
	w := newVaultWriter(v.host.archive, settings.ID, v.folder(settings))
	w.busy = v.host.chat.busy
	w.workspaces = v.host.vaultWorkspaceNames
	w.terminals = settings.terminals()
	w.adopt = adopt
	if v.configure != nil {
		v.configure(w)
	}
	v.writer = w
	w.start()
}

// stopWriter stops the writer, within a second. Hold mu.
func (v *hostVault) stopWriter() {
	if v.writer != nil {
		v.writer.stop()
		v.writer = nil
	}
}

// vaultWorkspaceNames are the workspaces' names by ID, for the writer's
// workspace folders and hubs.
func (h *Host) vaultWorkspaceNames() map[string]string {
	state, err := h.store.Read()
	if err != nil {
		return nil
	}
	names := make(map[string]string, len(state.Config.Projects))
	for _, project := range state.Config.Projects {
		names[project.ID] = project.Name
	}
	return names
}

// The routes.

// vaultAnswer is the body of GET /v1/vault and of the changes' answers.
type vaultAnswer struct {
	Enabled       bool   `json:"enabled"`
	Folder        string `json:"folder"`
	DefaultFolder string `json:"defaultFolder"`
	Terminals     bool   `json:"terminals"`
	// State is off, writing, current or paused (Reason, one of the
	// vaultPaused values, and Message say why).
	State   string `json:"state"`
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message,omitempty"`
	// Notes counts the chat and terminal notes written, Bytes the files in
	// the vault's own folders, Pending the notes waiting and Skipped those
	// left alone (edited without their marker, or another file in the way).
	Notes    int64               `json:"notes"`
	Bytes    int64               `json:"bytes"`
	Pending  int                 `json:"pending"`
	Skipped  int                 `json:"skipped"`
	Backfill vaultBackfillAnswer `json:"backfill"`
	// LastWriteAt is the last file written since the host started.
	LastWriteAt string `json:"lastWriteAt,omitempty"`
	// ObsidianVault is the Obsidian vault the folder is in (the folder, or
	// the nearest folder above it, holding .obsidian).
	ObsidianVault string `json:"obsidianVault,omitempty"`
}

// vaultBackfillAnswer is the first write's progress, in notes.
type vaultBackfillAnswer struct {
	Done  int64 `json:"done"`
	Total int64 `json:"total"`
}

// vaultCapability is capabilities.vault.
type vaultCapability struct {
	Version int `json:"version"`
}

// vaultSettingsInput is POST /v1/vault/settings. Every field is optional,
// but one is needed; adopt is not kept.
type vaultSettingsInput struct {
	Enabled   *bool   `json:"enabled"`
	Folder    *string `json:"folder"`
	Terminals *bool   `json:"terminals"`
	Adopt     *bool   `json:"adopt"`
}

// vaultReset is what a change does to the vault's records (resetVault).
type vaultReset int

const (
	vaultKeep    vaultReset = iota
	vaultReread             // read the feed again
	vaultRewrite            // read it again and compare every note with its file
)

func (h *Host) vaultAvailable(w http.ResponseWriter) bool {
	if h.vault == nil {
		writeError(w, 503, "vault_unavailable", "This host keeps no archive, so it has no vault")
		return false
	}
	return true
}

// vaultFailure answers a state file or archive that could not be read or
// written.
func vaultFailure(w http.ResponseWriter) {
	writeError(w, 500, "vault_error", "The vault's settings or records could not be read or saved")
}

// vaultStatusRoute is GET /v1/vault.
func (h *Host) vaultStatusRoute(w http.ResponseWriter, r *http.Request) {
	if !h.vaultAvailable(w) {
		return
	}
	h.vault.mu.Lock()
	defer h.vault.mu.Unlock()
	h.vault.respond(w, r.Context())
}

// vaultSettingsRoute is POST /v1/vault/settings {enabled?, folder?,
// terminals?, adopt?}. A folder must be absolute and neither the disk's top
// folder, the home folder nor in the host's state folder (followed through
// links), and not a file; an empty folder is the default. Turning the vault
// on, or moving it while on, makes the folder (0700) and checks that a file
// can be written in it. The settings are saved, the writer restarts with
// them (so sending enabled true again tries a paused vault again), and the
// answer is the status.
func (h *Host) vaultSettingsRoute(w http.ResponseWriter, r *http.Request) {
	if !h.vaultAvailable(w) {
		return
	}
	var in vaultSettingsInput
	if !decode(w, r, &in) {
		return
	}
	if in.Enabled == nil && in.Folder == nil && in.Terminals == nil && in.Adopt == nil {
		writeError(w, 400, "invalid_request", "Send enabled, folder, terminals or adopt")
		return
	}
	v := h.vault
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.closed {
		writeError(w, 503, "vault_unavailable", "The host is stopping")
		return
	}
	current, err := v.settings()
	if err != nil {
		vaultFailure(w)
		return
	}
	next := current
	next.Folder = v.folder(current)
	if in.Folder != nil {
		next.Folder = v.options.DefaultFolder
		if *in.Folder != "" {
			folder, problem := v.checkFolder(*in.Folder)
			if problem != "" {
				writeError(w, 400, "invalid_folder", problem)
				return
			}
			next.Folder = folder
		}
	}
	moved := next.Folder != v.folder(current)
	if moved {
		next.ID = ""
	}
	if in.Enabled != nil {
		next.Enabled = *in.Enabled
	}
	if in.Terminals != nil {
		terminals := *in.Terminals
		next.Terminals = &terminals
	}
	reset := vaultKeep
	if next.Enabled && (!current.Enabled || moved || next.ID == "") {
		if reset, err = v.activate(r.Context(), w, &next); err != nil {
			return
		}
	}
	if reset == vaultKeep && !current.terminals() && next.terminals() && next.ID != "" {
		// Terminals ended while they were off get their notes now.
		reset = vaultReread
	}
	if err := h.store.update(func(state *State) error {
		saved := next
		state.Vault = &saved
		return nil
	}); err != nil {
		vaultFailure(w)
		return
	}
	v.stopWriter()
	var failure error
	if reset != vaultKeep {
		failure = h.archive.resetVault(next.ID, reset == vaultRewrite)
	}
	if next.Enabled {
		v.run(next, in.Adopt != nil && *in.Adopt)
	}
	if failure != nil {
		vaultFailure(w)
		return
	}
	v.respond(w, r.Context())
}

// activate readies the folder of a vault that turns on or moves: it makes
// the folder and checks that it can write there, and chooses the folder's
// vault: the one the settings name, else the one that last wrote there, else
// a new one. A known vault whose folder was made now or no longer carries
// its marker is written whole again. On failure it answers w and returns the
// error. Hold mu.
func (v *hostVault) activate(ctx context.Context, w http.ResponseWriter, next *VaultSettings) (vaultReset, error) {
	if next.Folder == "" {
		writeError(w, 400, "invalid_folder", "Choose a folder for the vault")
		return vaultKeep, errors.New("no folder")
	}
	if _, problem := v.checkFolder(next.Folder); problem != "" {
		writeError(w, 400, "invalid_folder", problem)
		return vaultKeep, errors.New(problem)
	}
	created, err := vaultEnsureFolder(next.Folder)
	if err != nil {
		reason := err
		var pathErr *fs.PathError
		if errors.As(err, &pathErr) {
			reason = pathErr.Err
		}
		writeError(w, 409, "folder_unwritable", fmt.Sprintf("AgentLand cannot write in %s: %v", next.Folder, reason))
		return vaultKeep, err
	}
	archive := v.host.archive
	if next.ID == "" {
		if next.ID, err = archive.vaultAt(ctx, next.Folder); err != nil {
			vaultFailure(w)
			return vaultKeep, err
		}
	}
	if next.ID == "" {
		next.ID = archiveRandomID(8)
		return vaultKeep, nil
	}
	_, err = archive.vaultState(ctx, next.ID)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return vaultKeep, nil
	case err != nil:
		vaultFailure(w)
		return vaultKeep, err
	case created || !vaultFolderMarked(next.Folder, archive.epoch, next.ID):
		return vaultRewrite, nil
	}
	return vaultKeep, nil
}

// vaultRebuildRoute is POST /v1/vault/rebuild: the vault, which must be on,
// writes everything again (resetVault with rewrite). It deletes nothing.
func (h *Host) vaultRebuildRoute(w http.ResponseWriter, r *http.Request) {
	if !h.vaultAvailable(w) {
		return
	}
	v := h.vault
	v.mu.Lock()
	defer v.mu.Unlock()
	settings, err := v.settings()
	if err != nil {
		vaultFailure(w)
		return
	}
	if v.closed || v.writer == nil || !settings.Enabled || settings.ID == "" {
		writeError(w, 409, "vault_off", "Turn the vault on to rebuild it")
		return
	}
	v.stopWriter()
	failure := h.archive.resetVault(settings.ID, true)
	v.run(settings, false)
	if failure != nil {
		vaultFailure(w)
		return
	}
	v.respond(w, r.Context())
}

// respond answers the status. Hold mu.
func (v *hostVault) respond(w http.ResponseWriter, ctx context.Context) {
	answer, err := v.status(ctx)
	if err != nil {
		vaultFailure(w)
		return
	}
	writeJSON(w, 200, answer)
}

// status reads the settings, the writer's status and the vault's records.
// Hold mu.
func (v *hostVault) status(ctx context.Context) (vaultAnswer, error) {
	settings, err := v.settings()
	if err != nil {
		return vaultAnswer{}, err
	}
	folder := v.folder(settings)
	answer := vaultAnswer{Enabled: settings.Enabled, Folder: folder, DefaultFolder: v.options.DefaultFolder,
		Terminals: settings.terminals(), State: "off", ObsidianVault: vaultObsidianVault(folder)}
	var written time.Time
	if v.writer != nil {
		status := v.writer.status()
		answer.State, answer.Reason, answer.Message = status.State, status.Reason, status.Message
		answer.Pending, answer.Skipped = status.Pending, status.Skipped
		if written = status.LastWriteAt; !written.IsZero() {
			answer.LastWriteAt = archiveTimeText(written.UnixMilli())
		}
	}
	if settings.ID == "" {
		return answer, nil
	}
	archive := v.host.archive
	if answer.Notes, err = archive.vaultNoteCount(ctx, settings.ID); err != nil {
		return answer, err
	}
	record, err := archive.vaultState(ctx, settings.ID)
	switch {
	case err == nil:
		answer.Backfill = vaultBackfillAnswer{Done: record.BackfillDone, Total: record.BackfillTotal}
	case !errors.Is(err, sql.ErrNoRows):
		return answer, err
	}
	answer.Bytes = v.bytes(folder, written, answer.Notes)
	return answer, nil
}

// bytes counts the folder's bytes again after a write, or after
// vaultSizeEvery. Hold mu.
func (v *hostVault) bytes(folder string, written time.Time, notes int64) int64 {
	now := time.Now()
	size := v.size
	if size.folder == folder && size.written.Equal(written) && size.notes == notes && now.Sub(size.at) < vaultSizeEvery {
		return size.bytes
	}
	v.size = vaultCount{folder: folder, written: written, notes: notes, at: now, bytes: vaultFolderBytes(folder)}
	return v.size.bytes
}

// Folders.

// checkFolder cleans a folder chosen for the vault, or says why it cannot be
// one.
func (v *hostVault) checkFolder(folder string) (string, string) {
	if !filepath.IsAbs(folder) || len(folder) > vaultPathLimit || !utf8.ValidString(folder) || strings.IndexFunc(folder, unicode.IsControl) >= 0 {
		return "", "Choose an absolute folder for the vault"
	}
	folder = filepath.Clean(folder)
	resolved := vaultResolvePath(folder)
	if filepath.Dir(resolved) == resolved {
		return "", "The vault needs a folder of its own, not the disk's top folder"
	}
	if home, err := os.UserHomeDir(); err == nil && filepath.IsAbs(home) && resolved == vaultResolvePath(filepath.Clean(home)) {
		return "", "The vault needs a folder of its own, not your home folder"
	}
	if state, err := filepath.Abs(filepath.Dir(v.host.store.Path)); err == nil && vaultWithin(vaultResolvePath(state), resolved) {
		return "", "The vault cannot be in AgentLand's own state folder"
	}
	if info, err := os.Stat(folder); err == nil && !info.IsDir() {
		return "", "That is a file; choose a folder for the vault"
	}
	return folder, ""
}

// vaultResolvePath follows the links of the part of path that exists.
func vaultResolvePath(path string) string {
	rest := []string{}
	for current := path; ; {
		if resolved, err := filepath.EvalSymlinks(current); err == nil {
			return filepath.Join(append([]string{resolved}, rest...)...)
		}
		parent := filepath.Dir(current)
		if parent == current {
			return path
		}
		rest = append([]string{filepath.Base(current)}, rest...)
		current = parent
	}
}

// vaultWithin says whether path is folder or inside it.
func vaultWithin(folder, path string) bool {
	relative, err := filepath.Rel(folder, path)
	return err == nil && (relative == "." || filepath.IsLocal(relative))
}

// vaultEnsureFolder makes the folder when it is missing (0700) and writes
// and removes a file in it, through the folder's root. It says whether it
// made the folder.
func vaultEnsureFolder(folder string) (bool, error) {
	created := false
	info, err := os.Stat(folder)
	switch {
	case err == nil && !info.IsDir():
		return false, &fs.PathError{Op: "open", Path: folder, Err: errors.New("it is a file")}
	case errors.Is(err, fs.ErrNotExist):
		if err := os.MkdirAll(folder, 0o700); err != nil {
			return false, err
		}
		created = true
	case err != nil:
		return false, err
	}
	root, err := os.OpenRoot(folder)
	if err != nil {
		return created, err
	}
	defer root.Close()
	probe := vaultTempPrefix + "probe-" + archiveRandomID(8)
	file, err := root.OpenFile(probe, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return created, err
	}
	err = file.Close()
	if removeErr := root.Remove(probe); err == nil {
		err = removeErr
	}
	return created, err
}

// vaultFolderMarked says whether the folder's marker names the vault id of
// the archive epoch.
func vaultFolderMarked(folder, epoch, id string) bool {
	root, err := os.OpenRoot(folder)
	if err != nil {
		return false
	}
	defer root.Close()
	path := filepath.FromSlash(vaultMarkerPath)
	info, err := root.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > vaultMarkerLimit {
		return false
	}
	data, err := root.ReadFile(path)
	var marker vaultMarker
	return err == nil && json.Unmarshal(data, &marker) == nil && marker.Archive == epoch && marker.Vault == id
}

// vaultObsidianVault finds the Obsidian vault folder is in: folder, or the
// nearest folder above it, that holds a .obsidian folder.
func vaultObsidianVault(folder string) string {
	if folder == "" {
		return ""
	}
	for current := folder; ; {
		if info, err := os.Lstat(filepath.Join(current, ".obsidian")); err == nil && info.IsDir() {
			return current
		}
		parent := filepath.Dir(current)
		if parent == current {
			return ""
		}
		current = parent
	}
}

// vaultFolderBytes adds up the files in the vault's own folders and its
// README, without following links; Notes/ and the user's other files are
// not counted.
func vaultFolderBytes(folder string) int64 {
	root, err := os.OpenRoot(folder)
	if err != nil {
		return 0
	}
	defer root.Close()
	var total int64
	seen := 0
	for _, name := range append([]string{vaultReadmePath}, vaultOwnFolders...) {
		_ = fs.WalkDir(root.FS(), name, func(_ string, entry fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if seen++; seen > vaultSizeLimit {
				return fs.SkipAll
			}
			if entry.Type().IsRegular() {
				if info, err := entry.Info(); err == nil {
					total += info.Size()
				}
			}
			return nil
		})
	}
	return total
}
