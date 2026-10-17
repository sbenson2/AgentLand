package host

import (
	"log"
	"net/http"
	"unicode/utf8"

	"agentland/host/keeper"
)

// Where a terminal's description came from (TerminalInfo.ContextTitleSource).
const (
	contextFromProgram = "program"
	contextFromDevice  = "device"
)

// Any paired device can name any terminal (terminal_shared.go). A cursor
// prevents a delayed model result from replacing a description of newer work.
// A device's name stays until a device names the terminal again: the
// program's later titles change only its programTitle (follow). No terminal
// input is read.
func (h *Host) terminalContextTitle(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID  string `json:"projectId"`
		TerminalID string `json:"terminalId"`
		Title      string `json:"title"`
		BasedOn    uint64 `json:"basedOn"`
	}
	if !decode(w, r, &in) {
		return
	}
	title := cleanDeviceTitle(in.Title)
	if title == "" || utf8.RuneCountInString(title) > deviceTitleCharacters || in.BasedOn == 0 {
		writeError(w, 400, "invalid_request", "A title of 1 to 60 characters and an output cursor are required")
		return
	}
	project, _, ok := h.terminalRequest(w, r, in.ProjectID)
	if !ok {
		return
	}
	entry := h.terminalEntry(w, project, in.TerminalID)
	if entry == nil {
		return
	}
	entry.mu.Lock()
	if in.BasedOn > entry.cursor {
		entry.mu.Unlock()
		writeError(w, 400, "invalid_request", "The cursor is beyond this terminal's output")
		return
	}
	if in.BasedOn < entry.nameCursor {
		entry.mu.Unlock()
		writeError(w, 409, "title_stale", "The terminal already has a name from newer output")
		return
	}
	entry.info.ContextTitle = title
	entry.info.ContextTitleSource = contextFromDevice
	entry.nameCursor = in.BasedOn
	entry.mu.Unlock()
	entry.archiveTitle()
	h.terminals.saveContextTitle(entry)
	writeJSON(w, 200, map[string]bool{"accepted": true})
}

// archiveTitle gives the archive the terminal's current description. It
// runs outside mu: a full archive queue can make it wait, and the
// terminal's output and routes must not wait with it. Renames run one at a
// time and each reads the newest description, so the archive keeps the
// latest one whichever order they finish in.
func (e *terminalEntry) archiveTitle() {
	e.renameMu.Lock()
	defer e.renameMu.Unlock()
	e.mu.Lock()
	title := e.info.ContextTitle
	e.mu.Unlock()
	e.log.Rename(title)
}

// saveContextTitle writes the terminal's description, and where it came
// from, into its record in the keeper, so a host that starts again restores
// both. A writer does it in the background, newest last, and only logs a
// failure: output and routes never wait for the keeper here.
func (manager *terminalManager) saveContextTitle(entry *terminalEntry) {
	entry.mu.Lock()
	if entry.meta.ContextTitle == entry.info.ContextTitle && entry.meta.ContextTitleSource == entry.info.ContextTitleSource {
		entry.mu.Unlock()
		return
	}
	entry.meta.ContextTitle, entry.meta.ContextTitleSource = entry.info.ContextTitle, entry.info.ContextTitleSource
	entry.mu.Unlock()
	manager.saveMeta(entry)
}

// saveMeta has the background writer write the entry's record as it is now
// (joinWorkspace and saveContextTitle change it first).
func (manager *terminalManager) saveMeta(entry *terminalEntry) {
	entry.mu.Lock()
	entry.metaDirty = true
	start := !entry.metaSaving
	entry.metaSaving = true
	entry.mu.Unlock()
	if start {
		go manager.writeMeta(entry)
	}
}

// writeMeta writes the entry's record to the keeper until no newer one waits.
func (manager *terminalManager) writeMeta(entry *terminalEntry) {
	for {
		entry.mu.Lock()
		if !entry.metaDirty {
			entry.metaSaving = false
			entry.mu.Unlock()
			return
		}
		entry.metaDirty = false
		id := entry.info.ID
		record, err := entry.meta.encode()
		entry.mu.Unlock()
		if err != nil {
			log.Printf("terminals: could not record id=%s in the terminal service: %v", id, err)
			continue
		}
		ctx, cancel := manager.requestContext(terminalRequestWait)
		err = manager.backend.SetMeta(ctx, id, record)
		cancel()
		if err != nil && !keeper.IsNotFound(err) && !manager.isClosed() {
			log.Printf("terminals: could not record id=%s's description in the terminal service: %v", id, err)
		}
	}
}
