package host

import (
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	attachmentLifetime       = 24 * time.Hour
	attachmentsPerDevice     = 32
	attachmentBytesPerDevice = 64 << 20
	attachmentsPerMessage    = 5
	attachmentNameLimit      = 120
	attachmentUploadTimeout  = 2 * time.Minute
)

type attachmentType struct {
	limit     int64
	extension string
}

// The extension comes from the validated type, never the client's file name;
// agents that read files with their own tools recognize images and PDFs by it.
var attachmentTypes = map[string]attachmentType{
	"image/png":        {10 << 20, ".png"},
	"image/jpeg":       {10 << 20, ".jpg"},
	"image/gif":        {10 << 20, ".gif"},
	"image/webp":       {10 << 20, ".webp"},
	"application/pdf":  {10 << 20, ".pdf"},
	"text/plain":       {2 << 20, ".txt"},
	"text/markdown":    {2 << 20, ".md"},
	"text/csv":         {2 << 20, ".csv"},
	"application/json": {2 << 20, ".json"},
}

var (
	errPromptNotSent          = errors.New("the prompt was not sent")
	errAttachmentUnreadable   = fmt.Errorf("an attachment could not be read: %w", errPromptNotSent)
	errAttachmentsUnsupported = fmt.Errorf("this agent does not accept attachments: %w", errPromptNotSent)
	errOptionsUnsupported     = fmt.Errorf("this agent does not accept model overrides: %w", errPromptNotSent)
	errAttachmentInvalid      = errors.New("invalid attachment")
	errAttachmentTooLarge     = errors.New("attachment is too large")
	errAttachmentEmpty        = errors.New("attachment is empty")
	errAttachmentIncomplete   = errors.New("attachment upload did not complete")
	errAttachmentLimit        = errors.New("too many unsent attachments")
)

// ChatAttachment is an uploaded file claimed for one prompt. Path is a
// host-generated location and is never returned to clients.
type ChatAttachment struct {
	ID   string
	Path string
	Name string
	MIME string
	Size int64
}

const (
	attachmentUnsent = iota
	attachmentSending
	// attachmentInUse files belong to a CLI run that is still reading them.
	attachmentInUse
)

type storedAttachment struct {
	id, projectID, sessionID, owner string
	name, mime, path                string
	size                            int64
	created                         time.Time
	state                           int
}

type attachmentUsage struct {
	count int
	bytes int64
}

// AttachmentStore keeps uploads in one private directory until a prompt uses
// them or they expire. Metadata is process-local: files left by an earlier
// process are removed once they are older than the attachment lifetime.
type AttachmentStore struct {
	mu        sync.Mutex
	directory string
	items     map[string]*storedAttachment
	reserved  map[string]attachmentUsage
	now       func() time.Time
	swept     time.Time
}

func NewAttachmentStore(directory string) (*AttachmentStore, error) {
	directory = filepath.Clean(directory)
	if err := ensureAttachmentDirectory(directory); err != nil {
		return nil, err
	}
	store := &AttachmentStore{directory: directory, items: map[string]*storedAttachment{}, reserved: map[string]attachmentUsage{}, now: time.Now}
	store.sweep()
	return store, nil
}

func ensureAttachmentDirectory(directory string) error {
	if err := ensurePrivateStateDirectory(filepath.Join(directory, "attachment")); err != nil {
		return err
	}
	return os.Chmod(directory, 0700)
}

// attachmentMIME accepts only the listed types, compared without parameters.
func attachmentMIME(header string) (string, attachmentType, bool) {
	value, _, err := mime.ParseMediaType(header)
	if err != nil {
		return "", attachmentType{}, false
	}
	value = strings.ToLower(value)
	kind, ok := attachmentTypes[value]
	return value, kind, ok
}

// attachmentName keeps a display name only; it never becomes a path.
func attachmentName(raw string) string {
	name := raw
	if index := strings.LastIndexAny(name, `/\`); index >= 0 {
		name = name[index+1:]
	}
	name = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == utf8.RuneError {
			return -1
		}
		return r
	}, name)
	name = strings.TrimSpace(name)
	if len(name) > attachmentNameLimit {
		end := attachmentNameLimit
		for end > 0 && !utf8.RuneStart(name[end]) {
			end--
		}
		name = strings.TrimSpace(name[:end])
	}
	if name == "" || name == "." || name == ".." {
		return "attachment"
	}
	return name
}

func (s *AttachmentStore) usageLocked(owner string) attachmentUsage {
	usage := s.reserved[owner]
	for _, item := range s.items {
		if item.owner == owner && item.state != attachmentInUse {
			usage.count++
			usage.bytes += item.size
		}
	}
	return usage
}

func (s *AttachmentStore) expireLocked(now time.Time) {
	for id, item := range s.items {
		if item.state == attachmentUnsent && now.Sub(item.created) >= attachmentLifetime {
			_ = os.Remove(item.path)
			delete(s.items, id)
		}
	}
}

// sweep expires unsent uploads and removes untracked files older than the
// attachment lifetime. It never follows or removes anything but regular files.
func (s *AttachmentStore) sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.swept = now
	s.expireLocked(now)
	entries, err := os.ReadDir(s.directory)
	if err != nil {
		return
	}
	tracked := map[string]bool{}
	for _, item := range s.items {
		tracked[filepath.Base(item.path)] = true
	}
	for _, entry := range entries {
		info, err := entry.Info()
		if tracked[entry.Name()] || err != nil || !info.Mode().IsRegular() || time.Since(info.ModTime()) < attachmentLifetime {
			continue
		}
		_ = os.Remove(filepath.Join(s.directory, entry.Name()))
	}
}

func (s *AttachmentStore) sweepIfDue() {
	s.mu.Lock()
	due := s.now().Sub(s.swept) >= time.Minute
	s.mu.Unlock()
	if due {
		s.sweep()
	}
}

// readTracker distinguishes a failed or oversized upload from a local write error.
type readTracker struct {
	reader io.Reader
	err    error
}

func (r *readTracker) Read(data []byte) (int, error) {
	n, err := r.reader.Read(data)
	if err != nil && err != io.EOF {
		r.err = err
	}
	return n, err
}

// save reserves the upload's declared size (or its type limit) before reading
// so concurrent uploads cannot exceed a device's unsent-attachment bounds.
func (s *AttachmentStore) save(projectID, sessionID, owner, name, mimeType string, body io.Reader, declared int64) (storedAttachment, error) {
	kind := attachmentTypes[mimeType]
	reservation := attachmentUsage{count: 1, bytes: kind.limit}
	if declared > 0 && declared < kind.limit {
		reservation.bytes = declared
	}
	s.mu.Lock()
	s.expireLocked(s.now())
	usage := s.usageLocked(owner)
	if usage.count+reservation.count > attachmentsPerDevice || usage.bytes+reservation.bytes > attachmentBytesPerDevice {
		s.mu.Unlock()
		return storedAttachment{}, errAttachmentLimit
	}
	s.reserved[owner] = attachmentUsage{count: s.reserved[owner].count + reservation.count, bytes: s.reserved[owner].bytes + reservation.bytes}
	s.mu.Unlock()
	release := func() {
		current := s.reserved[owner]
		current.count -= reservation.count
		current.bytes -= reservation.bytes
		if current.count == 0 {
			delete(s.reserved, owner)
		} else {
			s.reserved[owner] = current
		}
	}
	item := storedAttachment{id: "att_" + cliMessageID(), projectID: projectID, sessionID: sessionID, owner: owner, name: name, mime: mimeType, state: attachmentUnsent}
	item.path = filepath.Join(s.directory, item.id+kind.extension)
	err := ensureAttachmentDirectory(s.directory)
	var size int64
	if err == nil {
		size, err = writeAttachmentFile(item.path, body)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	release()
	if err == nil && size == 0 {
		err = errAttachmentEmpty
	}
	if err == nil {
		usage = s.usageLocked(owner)
		if usage.count+1 > attachmentsPerDevice || usage.bytes+size > attachmentBytesPerDevice {
			err = errAttachmentLimit
		}
	}
	if err != nil {
		_ = os.Remove(item.path)
		return storedAttachment{}, err
	}
	item.size = size
	item.created = s.now()
	s.items[item.id] = &item
	return item, nil
}

func writeAttachmentFile(path string, body io.Reader) (int64, error) {
	// O_EXCL refuses an existing name, including a planted symlink.
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return 0, err
	}
	if err = file.Chmod(0600); err != nil {
		file.Close()
		return 0, err
	}
	tracker := &readTracker{reader: body}
	size, err := io.Copy(file, tracker)
	closeErr := file.Close()
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(tracker.err, &tooLarge):
		return 0, errAttachmentTooLarge
	case tracker.err != nil:
		return 0, errAttachmentIncomplete
	case err != nil:
		return 0, err
	}
	return size, closeErr
}

// claim reserves unsent uploads for one prompt. Every ID must belong to the
// same project, chat and device; the error does not say which check failed.
func (s *AttachmentStore) claim(ids []string, projectID, sessionID, owner string) ([]ChatAttachment, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireLocked(s.now())
	if len(ids) > attachmentsPerMessage {
		return nil, errAttachmentInvalid
	}
	files := make([]ChatAttachment, 0, len(ids))
	seen := map[string]bool{}
	for _, id := range ids {
		item := s.items[id]
		if item == nil || seen[id] || item.state != attachmentUnsent || item.projectID != projectID || item.sessionID != sessionID || item.owner != owner {
			return nil, errAttachmentInvalid
		}
		seen[id] = true
		files = append(files, ChatAttachment{ID: id, Path: item.path, Name: item.name, MIME: item.mime, Size: item.size})
	}
	for _, id := range ids {
		s.items[id].state = attachmentSending
	}
	return files, nil
}

func (s *AttachmentStore) setState(files []ChatAttachment, from, to int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, file := range files {
		if item := s.items[file.ID]; item != nil && item.state == from {
			item.state = to
		}
	}
}

// release returns claimed uploads to the sender after a definite failure.
func (s *AttachmentStore) release(files []ChatAttachment) {
	s.setState(files, attachmentSending, attachmentUnsent)
}

// retain keeps delivered files until the CLI run that reads them ends.
func (s *AttachmentStore) retain(files []ChatAttachment) {
	s.setState(files, attachmentSending, attachmentInUse)
}

func (s *AttachmentStore) remove(files []ChatAttachment) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, file := range files {
		if item := s.items[file.ID]; item != nil {
			_ = os.Remove(item.path)
			delete(s.items, file.ID)
		}
	}
}

func (h *Host) uploadAttachment(w http.ResponseWriter, r *http.Request) {
	if h.attachments == nil {
		writeError(w, 501, "unsupported_operation", "This host does not accept attachments")
		return
	}
	query := r.URL.Query()
	project, session, ok := h.chatScoped(w, query.Get("projectId"), query.Get("sessionId"))
	if !ok {
		return
	}
	device, ok := h.authenticate(r)
	if !ok {
		writeError(w, 401, "unauthorized", "Valid bearer authentication is required")
		return
	}
	// The Chats space's Claude Code and Codex chats take nothing new.
	if h.chatsSpaceReadOnly(w, project, session) {
		return
	}
	mimeType, kind, ok := attachmentMIME(r.Header.Get("Content-Type"))
	if !ok {
		writeError(w, 415, "unsupported_attachment", "Attach a PNG, JPEG, GIF, WebP, PDF, plain text, Markdown, CSV or JSON file")
		return
	}
	if r.ContentLength > kind.limit {
		attachmentTooLarge(w, kind)
		return
	}
	if r.ContentLength == 0 {
		writeError(w, 400, "invalid_request", "The attachment is empty")
		return
	}
	// A phone upload can take longer than the listener's ordinary timeouts.
	controller := http.NewResponseController(w)
	_ = controller.SetReadDeadline(time.Now().Add(attachmentUploadTimeout))
	_ = controller.SetWriteDeadline(time.Now().Add(attachmentUploadTimeout + 30*time.Second))
	body := http.MaxBytesReader(w, r.Body, kind.limit)
	stored, err := h.attachments.save(project.ID, session.ID, device.ID, attachmentName(query.Get("name")), mimeType, body, r.ContentLength)
	switch {
	case errors.Is(err, errAttachmentTooLarge):
		attachmentTooLarge(w, kind)
	case errors.Is(err, errAttachmentEmpty):
		writeError(w, 400, "invalid_request", "The attachment is empty")
	case errors.Is(err, errAttachmentIncomplete):
		writeError(w, 400, "invalid_request", "The attachment upload did not complete")
	case errors.Is(err, errAttachmentLimit):
		writeError(w, 429, "attachment_limit", "Send or wait out unsent attachments before adding more (32 files or 64 MiB per device)")
	case err != nil:
		writeError(w, 500, "storage_error", "The host could not store this attachment")
	default:
		writeJSON(w, 201, map[string]any{"id": stored.id, "name": stored.name, "mime": stored.mime, "size": stored.size})
	}
}

func attachmentTooLarge(w http.ResponseWriter, kind attachmentType) {
	writeError(w, 413, "attachment_too_large", fmt.Sprintf("This attachment type is limited to %d MiB", kind.limit>>20))
}
