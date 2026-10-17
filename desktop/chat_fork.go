package host

import (
	"errors"
	"net/http"
)

// chatForker is implemented by chat providers that can fork a chat (Codex
// through thread/fork). Others answer 501.
type chatForker interface {
	fork(p Project, s Session, messageID, title string) (Session, error)
}

// forkChat copies a chat into a new one, through messageId's turn or, when
// it is absent, every visible message (POST /v1/chat/fork).
func (h *Host) forkChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		MessageID string `json:"messageId,omitempty"`
		Title     string `json:"title,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.MessageID) > 256 || len(in.Title) > 200 {
		writeError(w, 400, "invalid_request", "The message or title is not valid")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok || h.chatsSpaceReadOnly(w, p, s) {
		return
	}
	forker, ok := h.chatProviderFor(s).(chatForker)
	if !ok {
		writeError(w, 501, "unsupported_operation", "This chat cannot be forked")
		return
	}
	unlock := h.lockSession(p.ID, s.ID)
	defer unlock()
	// Chat names (chat_title.go): a fork made without a title takes its
	// source's name as the host shows it.
	title := in.Title
	if title == "" {
		title = s.Title
	}
	forked, err := forker.fork(p, s, in.MessageID, title)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, 404, "not_found", "Message not found")
	case errors.Is(err, ErrCLIChatBusy):
		writeError(w, 409, "agent_busy", "Wait for the agent to finish before forking the chat")
	case errors.Is(err, errChatUnsupported):
		writeError(w, 501, "unsupported_operation", "This chat cannot be forked here")
	case errors.Is(err, errChatsSpaceRetired):
		writeChatsSpaceRetired(w)
	case err != nil:
		internal(w)
	default:
		forked.ProjectID = p.ID
		forked.Directory = ""
		// Chat names: ... and keeps where that name came from.
		if in.Title == "" && isCLISessionID(forked.ID) {
			name := chatName{Title: s.Title, Source: s.TitleSource, Basis: s.TitleBasis}
			if h.cliChats.setChatName(p, forked.ID, name) == nil {
				forked.Title, forked.TitleSource, forked.TitleBasis = name.Title, name.Source, name.Basis
			}
		}
		h.nameSession(&forked)
		h.recordForkInArchive(p, s, forked)
		writeJSON(w, 201, forked)
	}
}

// recordForkInArchive links a fork to the chat it was copied from, the way
// continue records its source, so the archive keeps the relation even when a
// provider later forgets it.
func (h *Host) recordForkInArchive(p Project, source, forked Session) {
	if h.archive == nil {
		return
	}
	provider := forked.Provider
	if provider == "" {
		provider = source.Provider
	}
	now := h.now()
	capture := &chatCapture{archive: h.archive}
	capture.written(forked.ID, h.archive.UpsertChat(ArchiveChat{ID: forked.ID, ProjectID: p.ID, Provider: provider, Title: forked.Title, TitleSource: forked.TitleSource, TitleBasis: forked.TitleBasis,
		ParentID: source.ID, Relation: "fork", CreatedAt: now, UpdatedAt: now}))
}
