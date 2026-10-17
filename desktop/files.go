package host

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

const maxTextFile = 1 << 20

type fileEntry struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	IsDirectory bool   `json:"isDirectory"`
	Size        int64  `json:"size"`
}
type fileDocument struct {
	Path     string `json:"path"`
	Content  string `json:"content"`
	Revision string `json:"revision"`
}

func filePath(value string, directory bool) (string, error) {
	if directory && value == "" {
		return ".", nil
	}
	if len(value) > 1024 || !fs.ValidPath(value) || strings.ContainsAny(value, "\\:\x00") || (!directory && value == ".") {
		return "", errors.New("invalid relative path")
	}
	return filepath.Localize(value)
}
func (h *Host) fileRoot(w http.ResponseWriter, id string) *os.Root {
	project, err := h.project(id)
	if err != nil {
		notFound(w)
		return nil
	}
	root, err := os.OpenRoot(project.Directory)
	if err != nil {
		writeError(w, 503, "project_unavailable", "The project directory is unavailable")
		return nil
	}
	return root
}
func fileFailure(w http.ResponseWriter, err error) {
	if errors.Is(err, os.ErrNotExist) {
		writeError(w, 404, "file_not_found", "The file no longer exists")
		return
	}
	writeError(w, 403, "file_unavailable", "The path is unavailable or outside the selected project")
}
func (h *Host) listFiles(w http.ResponseWriter, r *http.Request) {
	name, err := filePath(r.URL.Query().Get("path"), true)
	if err != nil {
		writeError(w, 400, "invalid_path", "Choose a relative project path")
		return
	}
	root := h.fileRoot(w, r.URL.Query().Get("projectId"))
	if root == nil {
		return
	}
	defer root.Close()
	dir, err := openProjectFile(root, name)
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer dir.Close()
	entries, err := dir.ReadDir(5001)
	if err != nil && !errors.Is(err, io.EOF) {
		fileFailure(w, err)
		return
	}
	if len(entries) > 5000 {
		writeError(w, 413, "directory_too_large", "This directory has too many entries to display")
		return
	}
	out := []fileEntry{}
	for _, entry := range entries {
		if entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		info, err := entry.Info()
		if err != nil || (!info.IsDir() && !info.Mode().IsRegular()) {
			continue
		}
		out = append(out, fileEntry{entry.Name(), path.Join(filepath.ToSlash(name), entry.Name()), entry.IsDir(), info.Size()})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsDirectory != out[j].IsDirectory {
			return out[i].IsDirectory
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	writeJSON(w, 200, map[string]any{"entries": out})
}
func textDocument(root *os.Root, name string) (fileDocument, os.FileMode, error) {
	file, err := openProjectFile(root, name)
	if err != nil {
		return fileDocument{}, 0, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return fileDocument{}, 0, err
	}
	if !info.Mode().IsRegular() {
		return fileDocument{}, 0, errBinary
	}
	if info.Size() > maxTextFile {
		return fileDocument{}, 0, errLarge
	}
	data, err := io.ReadAll(io.LimitReader(file, maxTextFile+1))
	if err != nil {
		return fileDocument{}, 0, err
	}
	if len(data) > maxTextFile {
		return fileDocument{}, 0, errLarge
	}
	if !utf8.Valid(data) || bytes.ContainsRune(data, 0) {
		return fileDocument{}, 0, errBinary
	}
	return fileDocument{filepath.ToSlash(name), string(data), fileRevision(data)}, info.Mode().Perm(), nil
}

var errLarge = errors.New("file too large")
var errBinary = errors.New("not a text file")

func fileRevision(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func documentFailure(w http.ResponseWriter, err error) {
	if errors.Is(err, errLarge) {
		writeError(w, 413, "file_too_large", "Text editing supports files up to 1 MiB")
		return
	}
	if errors.Is(err, errBinary) {
		writeError(w, 415, "unsupported_file", "This file is not supported UTF-8 text")
		return
	}
	fileFailure(w, err)
}
func (h *Host) readFile(w http.ResponseWriter, r *http.Request) {
	name, err := filePath(r.URL.Query().Get("path"), false)
	if err != nil {
		writeError(w, 400, "invalid_path", "Choose a relative project file")
		return
	}
	root := h.fileRoot(w, r.URL.Query().Get("projectId"))
	if root == nil {
		return
	}
	defer root.Close()
	doc, _, err := textDocument(root, name)
	if err != nil {
		documentFailure(w, err)
		return
	}
	writeJSON(w, 200, doc)
}
func (h *Host) saveFile(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		Path      string `json:"path"`
		Content   string `json:"content"`
		Revision  string `json:"revision"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 6*maxTextFile+4096)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&in); err != nil {
		writeError(w, 400, "invalid_request", "Invalid file request")
		return
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		writeError(w, 400, "invalid_request", "Only one JSON value is allowed")
		return
	}
	name, err := filePath(in.Path, false)
	if err != nil {
		writeError(w, 400, "invalid_path", "Choose a relative project file")
		return
	}
	if len(in.Content) > maxTextFile {
		documentFailure(w, errLarge)
		return
	}
	if !utf8.ValidString(in.Content) || strings.ContainsRune(in.Content, 0) {
		documentFailure(w, errBinary)
		return
	}
	root := h.fileRoot(w, in.ProjectID)
	if root == nil {
		return
	}
	defer root.Close()
	// Anchor the parent directory as well as the project: renaming a parent symlink
	// during save must never redirect the write outside the approved project.
	parent, err := root.OpenRoot(filepath.Dir(name))
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer parent.Close()
	base := filepath.Base(name)
	h.filesMu.Lock()
	defer h.filesMu.Unlock()
	info, err := parent.Lstat(base)
	if err == nil && !info.Mode().IsRegular() {
		documentFailure(w, errBinary)
		return
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		fileFailure(w, err)
		return
	}
	current, mode, err := textDocument(parent, base)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		documentFailure(w, err)
		return
	}
	if current.Revision != in.Revision {
		writeError(w, 409, "file_conflict", "The file changed. Reload and compare before saving again")
		return
	}
	if mode == 0 {
		mode = 0600
	}
	random := make([]byte, 16)
	if _, err = rand.Read(random); err != nil {
		writeError(w, 500, "save_failed", "Could not prepare the save")
		return
	}
	temp := ".agentland-save-" + hex.EncodeToString(random)
	file, err := parent.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		fileFailure(w, err)
		return
	}
	defer parent.Remove(temp)
	_, writeErr := io.WriteString(file, in.Content)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err = errors.Join(writeErr, syncErr, closeErr); err != nil {
		writeError(w, 500, "save_failed", "The file could not be saved")
		return
	}
	// Detect edits by other tools before replacement. Other AgentLand saves are
	// serialized; external tools cannot participate in an atomic compare-and-swap.
	latest, _, err := textDocument(parent, base)
	if (err != nil && !errors.Is(err, os.ErrNotExist)) || latest.Revision != in.Revision {
		writeError(w, 409, "file_conflict", "The file changed while saving. Reload and compare")
		return
	}
	if err = parent.Rename(temp, base); err != nil {
		writeError(w, 500, "save_failed", "The file could not be replaced")
		return
	}
	writeJSON(w, 200, fileDocument{in.Path, in.Content, fileRevision([]byte(in.Content))})
}
