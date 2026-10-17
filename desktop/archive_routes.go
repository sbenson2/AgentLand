package host

import (
	"database/sql"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Archive routes (docs/HOST-API.md, "Archive").
//
// Devices read archived chats and terminal logs only for configured projects,
// looked up the same way as every other project-scoped route. A chat or log
// whose project was removed from the configuration stays in the database,
// counts in stats and appears in the local whole-archive export, but every
// other route treats it as absent. The change feed's epoch includes the
// configured project set, so a configuration change makes devices resync:
// they drop chats of removed projects and get them back if a project with the
// same ID is added again.

const (
	archiveSearchTextBytes   = 256
	archiveExportWriteWindow = 30 * time.Second
	// archiveChangesMaxWait bounds GET /v1/archive/changes?wait, like the
	// notices and terminal long-polls.
	archiveChangesMaxWait = 20 * time.Second
	// archiveChangesSlack is added to a long-poll's wait for the connection
	// deadlines (the listener's write timeout is 35 s from the request's start).
	archiveChangesSlack = 35 * time.Second
)

var archiveExportTypes = map[string]struct{ contentType, extension string }{
	"markdown": {"text/markdown; charset=utf-8", ".md"},
	"json":     {"application/json", ".json"},
	"jsonl":    {"application/x-ndjson", ".jsonl"},
}

func (h *Host) archiveAvailable(w http.ResponseWriter) bool {
	if h.archive == nil {
		writeError(w, 501, "archive_unavailable", "This host does not keep an archive")
		return false
	}
	return true
}

func archiveFailure(w http.ResponseWriter) {
	writeError(w, 500, "archive_error", "The archive could not complete the request")
}

// localSession reports whether r carries this Mac's own session token over
// loopback, the only identity allowed on local-only routes.
func (h *Host) localSession(r *http.Request) bool {
	device, ok := h.authenticate(r)
	return ok && device.ID == "local-mac"
}

// configuredProjectIDs lists the projects whose archive entries devices may
// read: the configured workspaces and, on a host with plain chats, the Chats
// space, whether or not OpenCode has the chat agent now, so the feed's epoch
// never changes with OpenCode.
func (h *Host) configuredProjectIDs() ([]string, error) {
	st, err := h.store.Read()
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(st.Config.Projects)+1)
	for _, project := range st.Config.Projects {
		ids = append(ids, project.ID)
	}
	for _, project := range h.plainChatProjects() {
		ids = append(ids, project.ID)
	}
	return ids, nil
}

// archiveLimit parses an optional page size between 1 and maximum.
func archiveLimit(raw string, fallback, maximum int) (int, bool) {
	if raw == "" {
		return fallback, true
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 || value > maximum {
		return 0, false
	}
	return value, true
}

// visibleArchivedChat answers 404 unless the chat is archived and its project
// is configured, or is the Chats space.
func (h *Host) visibleArchivedChat(w http.ResponseWriter, r *http.Request, chatID string) (archiveChatJSON, bool) {
	if chatID != "" && len(chatID) <= archiveIDLimit {
		chat, err := h.archive.ArchivedChat(r.Context(), chatID)
		if err == nil {
			if _, err := h.chatProject(chat.ProjectID); err == nil {
				return chat, true
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			archiveFailure(w)
			return archiveChatJSON{}, false
		}
	}
	writeError(w, 404, "not_found", "Archived chat not found")
	return archiveChatJSON{}, false
}

// visibleTerminalLog answers 404 unless the log exists and its project is
// configured. Every paired device may read a configured project's logs; only
// live terminals are limited to the device that opened them.
func (h *Host) visibleTerminalLog(w http.ResponseWriter, r *http.Request, id string) (archiveTerminalLogJSON, bool) {
	if id != "" && len(id) <= archiveIDLimit {
		log, err := h.archive.ArchivedTerminalLog(r.Context(), id)
		if err == nil {
			if _, err := h.project(log.ProjectID); err == nil {
				return log, true
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			archiveFailure(w)
			return archiveTerminalLogJSON{}, false
		}
	}
	writeError(w, 404, "not_found", "Terminal log not found")
	return archiveTerminalLogJSON{}, false
}

// archiveChanges serves GET /v1/archive/changes?after&limit&wait. With wait
// (0–20000 ms) and nothing after the cursor, it waits for the next change or
// until the host starts stopping, then answers the page as usual.
func (h *Host) archiveChanges(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	limit, ok := archiveLimit(query.Get("limit"), 100, 200)
	if !ok {
		writeError(w, 400, "invalid_request", "Limit must be between 1 and 200")
		return
	}
	wait := time.Duration(0)
	if raw := query.Get("wait"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 || time.Duration(value)*time.Millisecond > archiveChangesMaxWait {
			writeError(w, 400, "invalid_request", "wait must be between 0 and 20000 milliseconds")
			return
		}
		wait = time.Duration(value) * time.Millisecond
	}
	var expired <-chan time.Time
	if wait > 0 {
		// The answer may come after the listener's write timeout, which counts
		// from the request's start: extend the connection's deadlines, as the
		// chat stream does.
		controller := http.NewResponseController(w)
		_ = controller.SetReadDeadline(time.Now().Add(wait + archiveChangesSlack))
		_ = controller.SetWriteDeadline(time.Now().Add(wait + archiveChangesSlack))
		timer := time.NewTimer(wait)
		defer timer.Stop()
		expired = timer.C
	}
	for {
		// Taken before the read, so a change committed in between still wakes it.
		changed := h.archive.changeSignal()
		projects, err := h.configuredProjectIDs()
		if err != nil {
			archiveFailure(w)
			return
		}
		page, err := h.archive.Changes(r.Context(), query.Get("after"), limit, projects)
		if errors.Is(err, errArchiveCursor) {
			writeError(w, 400, "invalid_cursor", "The archive cursor is not valid")
			return
		}
		if err != nil {
			archiveFailure(w)
			return
		}
		if expired == nil || len(page.Changes) > 0 || page.Resync || page.HasMore {
			writeJSON(w, 200, page)
			return
		}
		select {
		case <-changed:
			// A change, perhaps of a project this feed leaves out: read again.
		case <-expired:
			expired = nil
		case <-h.stopping:
			expired = nil
		case <-r.Context().Done():
			return
		}
		if expired == nil {
			writeJSON(w, 200, page)
			return
		}
	}
}

func (h *Host) archiveChat(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	limit, ok := archiveLimit(query.Get("limit"), 50, 50)
	if !ok {
		writeError(w, 400, "invalid_request", "Limit must be between 1 and 50")
		return
	}
	chat, ok := h.visibleArchivedChat(w, r, query.Get("chatId"))
	if !ok {
		return
	}
	page, err := h.archive.ChatPage(r.Context(), chat.ID, query.Get("before"), limit)
	switch {
	case errors.Is(err, errArchiveBefore):
		writeError(w, 400, "invalid_request", "The message to page before is not in this chat")
	case errors.Is(err, sql.ErrNoRows):
		writeError(w, 404, "not_found", "Archived chat not found")
	case err != nil:
		archiveFailure(w)
	default:
		writeJSON(w, 200, page)
	}
}

func (h *Host) archiveSearch(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	search := ArchiveSearch{Text: query.Get("q"), Provider: query.Get("provider"), Cursor: query.Get("cursor")}
	if len(search.Text) > archiveSearchTextBytes {
		writeError(w, 400, "invalid_request", "Search text is limited to 256 bytes")
		return
	}
	if strings.TrimSpace(search.Text) == "" {
		writeError(w, 400, "invalid_request", "Enter text to search for")
		return
	}
	if len(search.Provider) > archiveLabelLimit {
		writeError(w, 400, "invalid_request", "Provider is not valid")
		return
	}
	var ok bool
	if search.Limit, ok = archiveLimit(query.Get("limit"), 20, 50); !ok {
		writeError(w, 400, "invalid_request", "Limit must be between 1 and 50")
		return
	}
	for _, bound := range []struct {
		name  string
		value *time.Time
	}{{"from", &search.From}, {"to", &search.To}} {
		if raw := query.Get(bound.name); raw != "" {
			parsed, err := time.Parse(time.RFC3339, raw)
			if err != nil {
				writeError(w, 400, "invalid_request", "Dates must be RFC 3339 timestamps")
				return
			}
			*bound.value = parsed
		}
	}
	if projectID := query.Get("projectId"); projectID != "" {
		// Plain chats are searched with projectId=chats too.
		project, err := h.chatProject(projectID)
		if err != nil {
			writeError(w, 404, "not_found", "Project not found")
			return
		}
		search.ProjectID = project.ID
	}
	projects, err := h.configuredProjectIDs()
	if err != nil {
		archiveFailure(w)
		return
	}
	page, err := h.archive.Search(r.Context(), search, projects)
	if errors.Is(err, errArchiveCursor) {
		writeError(w, 400, "invalid_cursor", "The search cursor is not valid")
		return
	}
	if err != nil {
		archiveFailure(w)
		return
	}
	writeJSON(w, 200, page)
}

// archiveDeadlineWriter extends the connection's write deadline as a long
// export makes progress, at most once a second.
type archiveDeadlineWriter struct {
	writer     io.Writer
	controller *http.ResponseController
	extended   time.Time
}

func (d *archiveDeadlineWriter) Write(data []byte) (int, error) {
	if now := time.Now(); now.Sub(d.extended) >= time.Second {
		d.extended = now
		_ = d.controller.SetWriteDeadline(now.Add(archiveExportWriteWindow))
	}
	return d.writer.Write(data)
}

// archiveFilename keeps letters, digits, '-' and '_' from a title.
func archiveFilename(title, fallback string) string {
	var name strings.Builder
	dash := false
	for _, r := range title {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_':
			name.WriteRune(r)
			dash = false
		case !dash && name.Len() > 0:
			name.WriteByte('-')
			dash = true
		}
		if name.Len() >= 60 {
			break
		}
	}
	result := strings.Trim(name.String(), "-")
	if result == "" {
		return fallback
	}
	return result
}

func (h *Host) archiveExport(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	format := query.Get("format")
	if format == "" {
		format = "markdown"
	}
	kind, known := archiveExportTypes[format]
	if !known {
		writeError(w, 400, "invalid_request", "Choose markdown, json or jsonl")
		return
	}
	chatID := query.Get("chatId")
	var filename string
	if chatID == "" {
		if format != "jsonl" {
			writeError(w, 400, "invalid_request", "Choose a chat to export as Markdown or JSON")
			return
		}
		if !h.localSession(r) {
			writeError(w, 403, "local_only", "Only this Mac's AgentLand app can export the whole archive")
			return
		}
		filename = "agentland-archive-" + h.now().UTC().Format("2006-01-02") + kind.extension
	} else {
		chat, ok := h.visibleArchivedChat(w, r, chatID)
		if !ok {
			return
		}
		filename = archiveFilename(chat.Title, "chat") + kind.extension
	}
	w.Header().Set("Content-Type", kind.contentType)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": filename}))
	w.WriteHeader(200)
	writer := &archiveDeadlineWriter{writer: w, controller: http.NewResponseController(w)}
	if err := h.archive.Export(r.Context(), writer, chatID, format); err != nil {
		// The status is already sent; end the response so the client sees a
		// broken transfer, never a complete-looking partial file.
		panic(http.ErrAbortHandler)
	}
}

func (h *Host) archiveTerminalLogs(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	limit, ok := archiveLimit(query.Get("limit"), 100, 200)
	if !ok {
		writeError(w, 400, "invalid_request", "Limit must be between 1 and 200")
		return
	}
	projectID := query.Get("projectId")
	if projectID != "" {
		project, err := h.project(projectID)
		if err != nil {
			writeError(w, 404, "not_found", "Project not found")
			return
		}
		projectID = project.ID
	}
	projects, err := h.configuredProjectIDs()
	if err != nil {
		archiveFailure(w)
		return
	}
	page, err := h.archive.TerminalLogs(r.Context(), projectID, projects, query.Get("after"), limit)
	if errors.Is(err, errArchiveCursor) {
		writeError(w, 400, "invalid_cursor", "The terminal log cursor is not valid")
		return
	}
	if err != nil {
		archiveFailure(w)
		return
	}
	writeJSON(w, 200, page)
}

type archiveTerminalRangeJSON struct {
	// Data is base64 for raw reads and a string for text reads.
	Data   any    `json:"data"`
	Offset int64  `json:"offset"`
	Next   int64  `json:"next"`
	EOF    bool   `json:"eof"`
	Size   int64  `json:"size"`
	Status string `json:"status"`
}

func (h *Host) archiveTerminalLog(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	var offset int64
	if raw := query.Get("offset"); raw != "" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value < 0 {
			writeError(w, 400, "invalid_request", "Offset must be a nonnegative number of bytes")
			return
		}
		offset = value
	}
	length, ok := archiveLimit(query.Get("length"), 256<<10, terminalLogRangeLimit)
	if !ok {
		writeError(w, 400, "invalid_request", "Length must be between 1 and 1048576 bytes")
		return
	}
	format := query.Get("format")
	if format == "" {
		format = "raw"
	}
	if format != "raw" && format != "text" {
		writeError(w, 400, "invalid_request", "Choose raw or text")
		return
	}
	log, ok := h.visibleTerminalLog(w, r, query.Get("id"))
	if !ok {
		return
	}
	read, err := h.archive.ReadTerminalLog(log, offset, length)
	switch {
	case errors.Is(err, errArchiveRange):
		writeError(w, 400, "invalid_range", "The offset is past the end of the terminal log")
		return
	case errors.Is(err, ErrNotFound):
		writeError(w, 404, "not_found", "Terminal log not found")
		return
	case err != nil:
		archiveFailure(w)
		return
	}
	body := archiveTerminalRangeJSON{Data: read.Data, Offset: read.Offset, Next: read.Next, EOF: read.EOF, Size: read.Size, Status: read.Status}
	if format == "text" {
		text, consumed := terminalText(read.Data, read.EOF)
		body.Data, body.Next = string(text), offset+int64(consumed)
		body.EOF = read.EOF && consumed == len(read.Data)
	}
	writeJSON(w, 200, body)
}

func (h *Host) archiveDelete(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Kind string `json:"kind"`
		ID   string `json:"id"`
	}
	if !decode(w, r, &input) || !h.archiveAvailable(w) {
		return
	}
	var err error
	switch input.Kind {
	case "chat":
		if _, ok := h.visibleArchivedChat(w, r, input.ID); !ok {
			return
		}
		err = h.archive.DeleteChat(input.ID)
		// Continue (M1 chunk B2): a deleted chat's seed is gone too.
		h.chat.forgetSeed(input.ID)
	case "terminalLog":
		if _, ok := h.visibleTerminalLog(w, r, input.ID); !ok {
			return
		}
		err = h.archive.DeleteTerminalLog(input.ID)
	default:
		writeError(w, 400, "invalid_request", "Choose chat or terminalLog")
		return
	}
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, 404, "not_found", "Archive entry not found")
	case errors.Is(err, errArchiveLogActive):
		writeError(w, 409, "terminal_running", "End the terminal before deleting its log")
	case err != nil:
		archiveFailure(w)
	default:
		writeJSON(w, 200, map[string]bool{"deleted": true})
	}
}

func (h *Host) archiveStats(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	projects, err := h.configuredProjectIDs()
	if err != nil {
		archiveFailure(w)
		return
	}
	stats, err := h.archive.Stats(r.Context(), projects)
	if err != nil {
		archiveFailure(w)
		return
	}
	// Archive backfill (M1 chunk B2): the job's state.
	stats.BackfillState = h.backfill.status()
	writeJSON(w, 200, stats)
}
