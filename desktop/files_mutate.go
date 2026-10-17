package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Project file changes: move, mkdir, upload and delete. Every change reaches
// its files through the project's os.Root and renames or links single names
// inside directories opened through that root, so a symlink swapped into a
// path cannot redirect it outside the project. Changes hold filesMu, which
// serializes them with editor saves; an upload holds it only to publish its
// finished file, not while the body arrives.

const (
	defaultFileUploadLimit = 256 << 20
	uploadsPerDevice       = 2
	// An upload is refused when it would leave less than this much free space.
	uploadFreeSpaceReserve = 1 << 30
	// The read deadline allows the base time plus one second per this many
	// bytes, so a large file on a slow connection still completes.
	uploadBaseTimeout = 2 * time.Minute
	uploadMinimumRate = 256 << 10
	// nameAttempts bounds how many "name 2", "name 3" … candidates are tried.
	nameAttempts = 1000
)

var (
	errTrashUnavailable = errors.New("the trash is unavailable")

	// defaultTrashDirectory locates the Trash for new hosts. Tests replace it
	// so they never touch the owner's Trash.
	defaultTrashDirectory = userTrashDirectory
	// defaultGitUserConfig is the global Git configuration read for commit
	// identity and signing; "" means the user's own. Tests replace it.
	defaultGitUserConfig = ""
)

// renameFunc renames fromName in fromDir to toName in toDir and fails with an
// error matching os.ErrExist instead of replacing an existing entry.
type renameFunc func(fromDir *os.File, fromName string, toDir *os.File, toName string) error

// hostMutations is the state behind the file and Git change routes
// (files_mutate.go, files_search.go and git_mutate.go). The function fields
// are seams that tests replace.
type hostMutations struct {
	uploadLimit int64
	search      searchLimits

	mu       sync.Mutex
	uploads  map[string]int             // device ID → uploads in progress
	searches map[string]*activeSearch   // device ID → its running search
	gitLocks map[string]*repositoryLock // repository top level → lock

	trashDirectory  func() (string, error)
	renameNoReplace renameFunc
	freeSpace       func(*os.File) (uint64, error)
	searchHook      func(context.Context) // runs before each file is searched

	gitUserConfig    string
	gitLockWait      time.Duration
	gitTimeout       time.Duration
	gitCommitTimeout time.Duration
}

func (m *hostMutations) configure(options HostOptions) {
	m.uploadLimit = options.FileUploadLimit
	if m.uploadLimit <= 0 {
		m.uploadLimit = defaultFileUploadLimit
	}
	m.search = defaultSearchLimits
	m.uploads = map[string]int{}
	m.searches = map[string]*activeSearch{}
	m.gitLocks = map[string]*repositoryLock{}
	m.trashDirectory = defaultTrashDirectory
	m.renameNoReplace = renameNoReplace
	m.freeSpace = freeSpace
	m.gitUserConfig = defaultGitUserConfig
	m.gitLockWait = 5 * time.Second
	m.gitTimeout = 30 * time.Second
	m.gitCommitTimeout = 60 * time.Second
}

// fileCapabilities lists the file changes this host supports. Only macOS has
// a Trash the host can move items into.
func fileCapabilities() []string {
	if runtime.GOOS == "darwin" {
		return []string{"move", "mkdir", "upload", "trash", "delete", "search"}
	}
	return []string{"move", "mkdir", "upload", "delete", "search"}
}

func userTrashDirectory() (string, error) {
	if runtime.GOOS != "darwin" {
		return "", errTrashUnavailable
	}
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return "", errTrashUnavailable
	}
	return filepath.Join(home, ".Trash"), nil
}

// writeErrorWith writes the standard error body with extra fields beside
// code and message, such as suggestedName.
func writeErrorWith(w http.ResponseWriter, status int, code, message string, extra map[string]any) {
	body := map[string]any{"code": code, "message": message}
	for key, value := range extra {
		body[key] = value
	}
	writeJSON(w, status, map[string]any{"error": body})
}

func invalidMutationPath(w http.ResponseWriter) {
	writeError(w, 400, "invalid_path", "Choose a relative path inside the project, not the project folder itself")
}

// mutationFailure maps a failed change; not-found and other refusals keep the
// answers of the read routes.
func mutationFailure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, syscall.ENOSPC):
		insufficientStorage(w)
	case errors.Is(err, syscall.ENAMETOOLONG):
		writeError(w, 400, "invalid_path", "The name is too long")
	default:
		fileFailure(w, err)
	}
}

func insufficientStorage(w http.ResponseWriter) {
	writeError(w, 507, "insufficient_storage", "The Mac needs at least 1 GiB of free space left after this change")
}

// alternativeName returns the n-th replacement (n ≥ 1) for a name that is
// taken: "name 2", "name 3" …, before a file's extension ("photo 2.jpg"), and
// continuing from a number the name already ends with ("photo 3.jpg").
func alternativeName(name string, n int, isDirectory bool) string {
	stem, extension := name, ""
	if !isDirectory {
		if ext := path.Ext(name); ext != name {
			stem, extension = name[:len(name)-len(ext)], ext
		}
	}
	first := 2
	if index := strings.LastIndexByte(stem, ' '); index > 0 {
		digits := stem[index+1:]
		if number, err := strconv.Atoi(digits); err == nil && number >= 2 && strconv.Itoa(number) == digits {
			stem, first = stem[:index], number+1
		}
	}
	return stem + " " + strconv.Itoa(first+n-1) + extension
}

// suggestName offers a free name beside name. It is advice for the client,
// not a reservation.
func suggestName(root *os.Root, name string, isDirectory bool) string {
	directory, base := filepath.Dir(name), filepath.Base(name)
	for n := 1; n <= nameAttempts; n++ {
		candidate := alternativeName(base, n, isDirectory)
		if _, err := root.Lstat(filepath.Join(directory, candidate)); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
	return ""
}

// fileTaken answers 409 file_exists with a suggested free name.
func fileTaken(w http.ResponseWriter, root *os.Root, name string, isDirectory bool, message string) {
	extra := map[string]any{}
	if suggestion := suggestName(root, name, isDirectory); suggestion != "" {
		extra["suggestedName"] = suggestion
	}
	writeErrorWith(w, 409, "file_exists", message, extra)
}

func changedEntry(name string, info os.FileInfo) fileEntry {
	return fileEntry{Name: filepath.Base(name), Path: filepath.ToSlash(name), IsDirectory: info.IsDir(), Size: info.Size()}
}

// movesIntoItself reports whether to lies below from. Confinement
// comes from os.Root and the kernel also refuses such a rename; this check
// only gives every platform the same clear answer.
func movesIntoItself(from, to string) bool {
	from, to = filepath.ToSlash(from), filepath.ToSlash(to)
	return strings.HasPrefix(to, from+"/")
}

func (h *Host) moveFile(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		From      string `json:"from"`
		To        string `json:"to"`
	}
	if !decode(w, r, &in) {
		return
	}
	from, fromErr := filePath(in.From, false)
	to, toErr := filePath(in.To, false)
	if fromErr != nil || toErr != nil {
		invalidMutationPath(w)
		return
	}
	if movesIntoItself(from, to) {
		writeError(w, 400, "invalid_move", "A folder can't be moved into itself")
		return
	}
	root := h.fileRoot(w, in.ProjectID)
	if root == nil {
		return
	}
	defer root.Close()
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	info, err := root.Lstat(from)
	if err != nil {
		fileFailure(w, err)
		return
	}
	const taken = "An item with that name already exists; choose another name"
	if from == to {
		fileTaken(w, root, to, info.IsDir(), taken)
		return
	}
	err = h.renameInRoot(root, from, to)
	switch {
	case err == nil:
	case errors.Is(err, os.ErrExist):
		fileTaken(w, root, to, info.IsDir(), taken)
		return
	case errors.Is(err, syscall.EINVAL):
		writeError(w, 400, "invalid_move", "A folder can't be moved into itself")
		return
	case errors.Is(err, syscall.EXDEV):
		writeError(w, 409, "cross_volume", "Items can't be moved to another volume here")
		return
	default:
		mutationFailure(w, err)
		return
	}
	if moved, err := root.Lstat(to); err == nil {
		info = moved
	}
	writeJSON(w, 200, changedEntry(to, info))
}

func (h *Host) makeDirectory(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		Path      string `json:"path"`
	}
	if !decode(w, r, &in) {
		return
	}
	name, err := filePath(in.Path, false)
	if err != nil {
		invalidMutationPath(w)
		return
	}
	root := h.fileRoot(w, in.ProjectID)
	if root == nil {
		return
	}
	defer root.Close()
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	parent, err := root.OpenRoot(filepath.Dir(name))
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer parent.Close()
	// mkdirat never follows a symlink at the final name; any entry there fails.
	if err := parent.Mkdir(filepath.Base(name), 0o755); err != nil {
		if errors.Is(err, os.ErrExist) {
			fileTaken(w, root, name, true, "A file or folder with that name already exists")
			return
		}
		mutationFailure(w, err)
		return
	}
	writeJSON(w, 201, fileEntry{Name: filepath.Base(name), Path: filepath.ToSlash(name), IsDirectory: true})
}

// admitUpload allows at most uploadsPerDevice uploads per device at once.
func (m *hostMutations) admitUpload(device string) (func(), bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.uploads[device] >= uploadsPerDevice {
		return nil, false
	}
	m.uploads[device]++
	return func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.uploads[device]--; m.uploads[device] <= 0 {
			delete(m.uploads, device)
		}
	}, true
}

func uploadTooLarge(w http.ResponseWriter, limit int64) {
	writeError(w, 413, "file_too_large", fmt.Sprintf("Uploads are limited to %d MiB", limit>>20))
}

// uploadFile stores the raw request body as a new file. It is written to an
// exclusive temporary name beside the target, synced, then published with a
// hard link that fails when the name is taken, so an upload never replaces
// anything. Volumes without hard links publish with an exclusive rename.
func (h *Host) uploadFile(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	name, err := filePath(query.Get("path"), false)
	if err != nil {
		invalidMutationPath(w)
		return
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	if r.ContentLength < 0 {
		writeError(w, 411, "length_required", "Send the file with a Content-Length")
		return
	}
	limit := h.mutations.uploadLimit
	if r.ContentLength > limit {
		uploadTooLarge(w, limit)
		return
	}
	root := h.fileRoot(w, query.Get("projectId"))
	if root == nil {
		return
	}
	defer root.Close()
	finish, admitted := h.mutations.admitUpload(device.ID)
	if !admitted {
		writeError(w, 429, "upload_limit", "Wait for this device's other uploads to finish (2 at a time)")
		return
	}
	defer finish()
	parent, err := root.OpenRoot(filepath.Dir(name))
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer parent.Close()
	base := filepath.Base(name)
	const taken = "A file with that name already exists; the upload did not replace it"
	// Refuse a taken name before receiving the body. The link below is the check
	// that counts.
	if _, err := parent.Lstat(base); err == nil {
		fileTaken(w, root, name, false, taken)
		return
	} else if !errors.Is(err, os.ErrNotExist) {
		fileFailure(w, err)
		return
	}
	if directory, err := openDirectory(parent, "."); err == nil {
		free, statErr := h.mutations.freeSpace(directory)
		directory.Close()
		if statErr == nil && (free < uploadFreeSpaceReserve || uint64(r.ContentLength) > free-uploadFreeSpaceReserve) {
			insufficientStorage(w)
			return
		}
	}
	// A large file from a phone can take longer than the listener's timeouts.
	timeout := uploadBaseTimeout + time.Duration(r.ContentLength/uploadMinimumRate)*time.Second
	controller := http.NewResponseController(w)
	_ = controller.SetReadDeadline(time.Now().Add(timeout))
	_ = controller.SetWriteDeadline(time.Now().Add(timeout + 30*time.Second))
	temp, err := temporaryName(".agentland-upload-")
	if err != nil {
		writeError(w, 500, "upload_failed", "Could not prepare the upload")
		return
	}
	// 0644 is further limited by the process umask.
	file, err := parent.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		mutationFailure(w, err)
		return
	}
	defer parent.Remove(temp)
	tracker := &readTracker{reader: http.MaxBytesReader(w, r.Body, limit)}
	written, copyErr := io.Copy(file, tracker)
	var syncErr error
	if copyErr == nil {
		syncErr = file.Sync()
	}
	closeErr := file.Close()
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(tracker.err, &tooLarge):
		uploadTooLarge(w, limit)
		return
	case tracker.err != nil || (copyErr == nil && written != r.ContentLength):
		writeError(w, 400, "upload_incomplete", "The upload did not complete; nothing was saved")
		return
	case copyErr != nil || syncErr != nil || closeErr != nil:
		if err := errors.Join(copyErr, syncErr, closeErr); errors.Is(err, syscall.ENOSPC) {
			insufficientStorage(w)
		} else {
			writeError(w, 500, "upload_failed", "The file could not be written")
		}
		return
	}
	h.filesMu.Lock()
	err = parent.Link(temp, base)
	if err != nil && !errors.Is(err, os.ErrExist) {
		err = h.renameInRoot(parent, temp, base)
	}
	h.filesMu.Unlock()
	switch {
	case errors.Is(err, os.ErrExist):
		fileTaken(w, root, name, false, taken)
	case err != nil:
		mutationFailure(w, err)
	default:
		writeJSON(w, 201, fileEntry{Name: base, Path: filepath.ToSlash(name), Size: written})
	}
}

func temporaryName(prefix string) (string, error) {
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	return prefix + hex.EncodeToString(random), nil
}

// deleteFile moves an item to the Trash, or removes it with an explicit,
// confirmed permanent delete. The project folder itself is never a valid path.
func (h *Host) deleteFile(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID   string `json:"projectId"`
		Path        string `json:"path"`
		Permanent   bool   `json:"permanent,omitempty"`
		ConfirmPath string `json:"confirmPath,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	name, err := filePath(in.Path, false)
	if err != nil {
		invalidMutationPath(w)
		return
	}
	if in.Permanent && in.ConfirmPath != in.Path {
		writeError(w, 400, "confirmation_required", "Confirm the exact path to delete it permanently")
		return
	}
	root := h.fileRoot(w, in.ProjectID)
	if root == nil {
		return
	}
	defer root.Close()
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	info, err := root.Lstat(name)
	if err != nil {
		fileFailure(w, err)
		return
	}
	if in.Permanent {
		// RemoveAll removes a symlink itself and never follows one while descending.
		if err := root.RemoveAll(name); err != nil {
			writeError(w, 500, "delete_failed", "Some items could not be deleted")
			return
		}
		writeJSON(w, 200, map[string]any{"path": filepath.ToSlash(name), "trashed": false})
		return
	}
	parent, err := openDirectory(root, filepath.Dir(name))
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer parent.Close()
	trashName, err := h.moveToTrash(parent, filepath.Base(name), info.IsDir())
	switch {
	case errors.Is(err, errTrashUnavailable):
		writeErrorWith(w, 409, "trash_unavailable", "This item can't be moved to the Trash; it can be deleted permanently instead", map[string]any{"permanentDeleteAllowed": true})
	case err != nil:
		mutationFailure(w, err)
	default:
		writeJSON(w, 200, map[string]any{"path": filepath.ToSlash(name), "trashed": true, "trashName": trashName})
	}
}

// moveToTrash renames base out of parent into the user's Trash without
// replacing anything there, taking "name 2", "name 3" … when the name is used.
// Finder's Put Back does not know about items moved this way.
func (h *Host) moveToTrash(parent *os.File, base string, isDirectory bool) (string, error) {
	location, err := h.mutations.trashDirectory()
	if err != nil {
		return "", errTrashUnavailable
	}
	trash, err := openTrash(location)
	if err != nil {
		return "", errTrashUnavailable
	}
	defer trash.Close()
	for n := 0; n <= nameAttempts; n++ {
		candidate := base
		if n > 0 {
			candidate = alternativeName(base, n, isDirectory)
		}
		err := h.mutations.renameNoReplace(parent, base, trash, candidate)
		switch {
		case err == nil:
			return candidate, nil
		case errors.Is(err, os.ErrExist):
			continue
		case errors.Is(err, syscall.EXDEV), errors.Is(err, syscall.EPERM), errors.Is(err, syscall.EACCES):
			// Another volume, or no permission to use the Trash (for example
			// without access to it under macOS privacy protection).
			return "", errTrashUnavailable
		default:
			return "", err
		}
	}
	return "", errTrashUnavailable
}
