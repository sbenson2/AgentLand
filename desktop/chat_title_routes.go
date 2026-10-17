package host

import (
	"errors"
	"math"
	"net/http"
	"strings"
	"unicode/utf8"
)

// Chat names on the host (docs/HOST-API.md "Chat names"): the name each
// Session and the hub show, the free naming after a delivery and
// POST /v1/chat/title. The naming rules are in chat_title.go, the host's
// names in chat_title_store.go.

// nameSession gives a Session the name the host shows, with its source and
// basis: an OpenCode chat's through the host's names (keeping OpenCode's own
// title as providerTitle), a Claude Code or Codex chat's as its registry has
// it.
func (h *Host) nameSession(s *Session) {
	if isCLISessionID(s.ID) {
		name := sessionName(*s)
		s.Title, s.TitleSource, s.TitleBasis = name.Title, name.Source, name.Basis
		return
	}
	s.providerTitle = s.Title
	name := h.titles.resolveOpenCode(s.ID, s.Title)
	s.Title, s.TitleSource, s.TitleBasis = name.Title, name.Source, name.Basis
}

// lockTitle serializes naming one chat: the host's free naming after a
// delivery and POST /v1/chat/title. It is taken after lockSession, never
// before it.
func (h *Host) lockTitle(projectID, sessionID string) func() {
	key := sessionKey{projectID, sessionID}
	h.titleMu.Lock()
	lock := h.titleLocks[key]
	if lock == nil {
		lock = &sessionLock{}
		h.titleLocks[key] = lock
	}
	lock.users++
	h.titleMu.Unlock()
	lock.Lock()
	return func() {
		lock.Unlock()
		h.titleMu.Lock()
		if lock.users--; lock.users == 0 {
			delete(h.titleLocks, key)
		}
		h.titleMu.Unlock()
	}
}

// autoName names a chat from a user message just delivered to it, while
// its title is a placeholder or an earlier auto/device name. messageID is the
// message's ID ("" when the provider gave none: the name then has no basis).
func (h *Host) autoName(p Project, sessionID, text, messageID string) {
	title := freeChatTitle(text)
	if title == "" {
		return
	}
	unlock := h.lockTitle(p.ID, sessionID)
	defer unlock()
	current, err := h.session(p, sessionID)
	if err != nil || (current.TitleSource != titleDefault && current.TitleSource != titleAuto && current.TitleSource != titleDevice) {
		return
	}
	name := chatName{Title: title, Source: titleAuto, Basis: messageID}
	if isCLISessionID(sessionID) {
		if h.cliChats.setChatName(p, sessionID, name) != nil {
			return
		}
		h.titles.setMemory(sessionID, p.ID, name)
	} else {
		// A save that fails keeps the name until the host stops.
		_ = h.titles.setOpenCode(sessionID, p.ID, name, current.providerTitle)
	}
	h.chatRenamed(p, current, name)
}

// autoNameMessage names a chat from a user message a provider delivered
// itself (Claude Code's regenerate), reading the message's text.
func (h *Host) autoNameMessage(p Project, s Session, provider chatProvider, messageID string) {
	messages, _, err := provider.page(p, s, "", math.MaxInt32)
	if err != nil {
		return
	}
	for _, message := range messages {
		if message.ID == messageID && message.Role == "user" {
			h.autoName(p, s.ID, messageText(message), messageID)
			return
		}
	}
}

// messageText is a message's own text: its text parts, without a continued
// chat's seed.
func messageText(message ChatMessage) string {
	var texts []string
	for _, part := range message.Parts {
		if part.Kind == "text" {
			texts = append(texts, part.Text)
		}
	}
	return strings.Join(texts, "\n")
}

// chatRenamed tells every stream of the chat its new name (the capture then
// archives it). A chat the hub does not hold is written to the archive here.
func (h *Host) chatRenamed(p Project, s Session, name chatName) {
	if h.chat.rename(sessionKey{p.ID, s.ID}, name) || h.archive == nil {
		return
	}
	provider := s.Provider
	if provider == "" {
		provider = "opencode"
	}
	capture := &chatCapture{archive: h.archive}
	capture.written(s.ID, h.archive.UpsertChat(ArchiveChat{ID: s.ID, ProjectID: p.ID, Provider: provider, Title: name.Title, TitleSource: name.Source, TitleBasis: name.Basis}))
}

// rename gives a chat the hub holds its new name. It reports whether the hub
// holds the chat; one still loading reads the name as it loads.
func (h *chatHub) rename(key sessionKey, name chatName) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.chats[key]
	if h.closed || c == nil || c.loading || c.removed {
		return false
	}
	c.setName(name)
	return true
}

// chatTitle takes a name a device wrote (POST /v1/chat/title).
func (h *Host) chatTitle(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		Title     string `json:"title"`
		BasedOn   string `json:"basedOn"`
	}
	if !decode(w, r, &in) {
		return
	}
	title := cleanDeviceTitle(in.Title)
	if in.ProjectID == "" || in.SessionID == "" || in.BasedOn == "" || len(in.BasedOn) > 256 || title == "" || utf8.RuneCountInString(title) > deviceTitleCharacters {
		writeError(w, 400, "invalid_request", "A title of 1 to 60 characters and the message it is based on are required")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	provider := h.chatProviderFor(s)
	if provider == nil {
		notFound(w)
		return
	}
	unlock := h.lockTitle(p.ID, s.ID)
	defer unlock()
	// Read again under the lock: an auto name may have come meanwhile.
	current, err := h.session(p, s.ID)
	if err != nil {
		notFound(w)
		return
	}
	based, err := h.messagePosition(p, current, provider, in.BasedOn)
	if errors.Is(err, ErrNotFound) {
		writeError(w, 400, "invalid_request", "basedOn must be a message this chat shows")
		return
	}
	if err != nil {
		internal(w)
		return
	}
	if current.TitleBasis != "" && current.TitleBasis != in.BasedOn {
		basis, err := h.messagePosition(p, current, provider, current.TitleBasis)
		switch {
		case err == nil && basis > based:
			writeJSON(w, 409, map[string]any{"error": map[string]string{"code": "title_stale", "message": "The chat was named after a newer message; name it from the chat as it is now",
				"title": current.Title, "titleSource": current.TitleSource, "titleBasis": current.TitleBasis}})
			return
		case err != nil && !errors.Is(err, ErrNotFound):
			internal(w)
			return
		}
	}
	name := chatName{Title: title, Source: titleDevice, Basis: in.BasedOn}
	if current.Title == name.Title && current.TitleSource == name.Source && current.TitleBasis == name.Basis {
		writeJSON(w, 200, name)
		return
	}
	if isCLISessionID(s.ID) {
		if err := h.cliChats.setChatName(p, s.ID, name); err != nil {
			internal(w)
			return
		}
		h.titles.setMemory(s.ID, p.ID, name)
	} else {
		renamer, ok := h.agent.(sessionRenamer)
		if !ok {
			writeError(w, 502, "provider_unavailable", "OpenCode could not rename this chat; nothing changed")
			return
		}
		// OpenCode's echo of the new title may come before its answer.
		h.titles.beginRename(s.ID, name)
		renamed, err := renamer.RenameSession(p, s.ID, name.Title)
		if err != nil {
			h.titles.endRename(s.ID)
			writeError(w, 502, "provider_unavailable", "OpenCode did not rename this chat; nothing changed")
			return
		}
		if renamed.Title != "" {
			name.Title = renamed.Title
		}
		// OpenCode has the name, so a save that fails keeps it until the
		// host stops.
		_ = h.titles.setOpenCode(s.ID, p.ID, name, current.providerTitle)
		h.titles.endRename(s.ID)
	}
	h.chatRenamed(p, current, name)
	writeJSON(w, 200, name)
}

// messagePosition places a message the chat shows in its order: later
// messages have larger positions. A message the chat does not show (unknown,
// of another chat, or hidden by a rewind) is ErrNotFound.
func (h *Host) messagePosition(p Project, s Session, provider chatProvider, id string) (int64, error) {
	if adapter, ok := h.agent.(*OpenCodeAdapter); ok && !isCLISessionID(s.ID) {
		info, err := adapter.message(p, s.ID, id)
		if err != nil {
			return 0, err
		}
		if info.Role != "user" && info.Role != "assistant" {
			return 0, ErrNotFound
		}
		position := openCodeMessageOrd(info.ID, info.Time.Created)
		if s.RewindMessageID != "" {
			rewind, err := adapter.message(p, s.ID, s.RewindMessageID)
			if err != nil && !errors.Is(err, ErrNotFound) {
				return 0, err
			}
			if err == nil && position >= openCodeMessageOrd(rewind.ID, rewind.Time.Created) {
				return 0, ErrNotFound
			}
		}
		return position, nil
	}
	messages, _, err := provider.page(p, s, "", math.MaxInt32)
	if err != nil {
		return 0, err
	}
	for index, message := range messages {
		if message.ID == id {
			return int64(len(messages) - index), nil
		}
	}
	return 0, ErrNotFound
}
