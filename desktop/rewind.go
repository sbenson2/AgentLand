package host

import (
	"errors"
	"net/http"
)

// rewindable returns what rewinds the chat and whether its files come back:
// "immediate" for OpenCode, which reverts them with the messages.
func (h *Host) rewindable(w http.ResponseWriter, s Session) (RewindableAgent, string, bool) {
	// Codex streaming: a Codex chat rewinds through its provider; files stay.
	// Claude Code streaming: so does a Claude chat; files return on the next
	// send.
	if provider, ok := h.chatProviderFor(s).(interface {
		chatProvider
		filesRestore() string
	}); ok {
		return providerRewinder{provider}, provider.filesRestore(), true
	}
	agent, ok := h.agent.(RewindableAgent)
	if isCLISessionID(s.ID) || !ok {
		writeError(w, 400, "unsupported_operation", "Only OpenCode, Claude Code and Codex chats can be rewound")
		return nil, "", false
	}
	return agent, "immediate", true
}

// rewindChat hides the latest user message and everything after it so the
// client can edit and resend it. The chat must be idle with an empty queue:
// a queued message was written after the turn that is being replaced.
func (h *Host) rewindChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		MessageID string `json:"messageId"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.MessageID == "" || len(in.MessageID) > 256 {
		writeError(w, 400, "invalid_request", "A message is required")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	// A read-only chat is not rewound (it could not be sent again); a
	// rewound one can still be restored.
	if !ok || h.chatsSpaceReadOnly(w, p, s) {
		return
	}
	agent, files, ok := h.rewindable(w, s)
	if !ok {
		return
	}
	unlock := h.lockSession(p.ID, s.ID)
	defer unlock()
	state, err := h.chatState(p, s.ID)
	if err != nil {
		internal(w)
		return
	}
	if state != "idle" {
		writeError(w, 409, "agent_busy", "Wait for the agent to finish before editing a message")
		return
	}
	if h.queue != nil && h.queue.count(sessionKey{p.ID, s.ID}) > 0 {
		writeError(w, 409, "queue_not_empty", "Remove the queued messages before editing a message")
		return
	}
	// Read the revert point again now that no other chat operation can run.
	if s, err = h.session(p, s.ID); err != nil {
		rewindFailure(w, err)
		return
	}
	items, err := h.transcript(p, s)
	if err != nil {
		internal(w)
		return
	}
	latest := ""
	for _, item := range items {
		if item.Role == "user" {
			latest = item.ID
		}
	}
	if latest == "" || latest != in.MessageID {
		writeError(w, 400, "invalid_request", "Only the latest message can be edited")
		return
	}
	if err := agent.Rewind(p, s.ID, in.MessageID); err != nil {
		rewindFailure(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"rewound": true, "filesRestore": files})
}

func (h *Host) restoreChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
	}
	if !decode(w, r, &in) {
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	agent, files, ok := h.rewindable(w, s)
	if !ok {
		return
	}
	unlock := h.lockSession(p.ID, s.ID)
	defer unlock()
	if err := agent.Restore(p, s.ID); err != nil {
		rewindFailure(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"restored": true, "filesRestore": files})
}

func rewindFailure(w http.ResponseWriter, err error) {
	var status openCodeStatusError
	switch {
	case errors.Is(err, ErrNotFound):
		notFound(w)
	// Codex streaming: turns Codex never reported cannot be edited.
	case errors.Is(err, errChatUnsupported):
		writeError(w, 400, "unsupported_operation", "This message cannot be edited")
	case errors.Is(err, ErrCLIChatBusy):
		writeError(w, 409, "agent_busy", "Wait for the agent to finish before editing a message")
	case errors.As(err, &status) && status.status == 409:
		writeError(w, 409, "agent_busy", "Wait for the agent to finish before editing a message")
	default:
		internal(w)
	}
}
