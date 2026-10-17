package host

import (
	"errors"
	"net/http"
	"strings"
	"time"
)

// chatRegenerator is implemented by chat providers that drop a chat's latest
// turn and send its prompt again in one step (Claude Code). OpenCode chats
// regenerate through their revert and a new prompt.
type chatRegenerator interface {
	regenerate(p Project, s Session, options PromptOptions) (string, error)
}

// regenerateChat drops the latest turn and sends its prompt again
// (POST /v1/chat/regenerate). The prompt's text is sent; attachments are
// not kept, so a prompt that had them cannot be regenerated.
func (h *Host) regenerateChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		Model     string `json:"model,omitempty"`
		Mode      string `json:"mode,omitempty"`
		Effort    string `json:"effort,omitempty"`
	}
	if !decode(w, r, &in) {
		return
	}
	options := PromptOptions{Model: in.Model}
	if !validPromptOptions(options) || len(in.Mode) > 64 || len(in.Effort) > 64 {
		writeError(w, 400, "invalid_request", "Choose a valid model, mode and effort")
		return
	}
	p, s, ok := h.chatScoped(w, in.ProjectID, in.SessionID)
	if !ok {
		return
	}
	// Plain chats: the chat agent runs the prompt again, once it is confirmed.
	if h.isPlainChat(p) && plainChatOptionsRefused(w, in.Mode) {
		return
	}
	// Subscriptions only, for every Claude Code and Codex chat.
	if !h.chatProviderReady(w, r, p, sessionProvider(s)) {
		return
	}
	regenerator, provides := h.chatProviderFor(s).(chatRegenerator)
	if _, rewindable := h.agent.(RewindableAgent); !provides && (isCLISessionID(s.ID) || !rewindable) {
		writeError(w, 501, "unsupported_operation", "This chat cannot be regenerated")
		return
	}
	if isClaudeSessionID(s.ID) {
		// Starting a process and waiting for the prompt's echo may outlast
		// the listener's write timeout.
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(claudeSendWait))
	}
	unlock := h.lockSession(p.ID, s.ID)
	defer unlock()
	state, err := h.chatState(p, s.ID)
	if err != nil {
		rewindFailure(w, err)
		return
	}
	if state != "idle" {
		writeError(w, 409, "agent_busy", "Wait for the agent to finish before regenerating")
		return
	}
	if h.queue != nil && h.queue.count(sessionKey{p.ID, s.ID}) > 0 {
		writeError(w, 409, "queue_not_empty", "Remove the queued messages before regenerating")
		return
	}
	var id string
	if provides {
		options.Mode, options.Effort = in.Mode, in.Effort
		id, err = regenerator.regenerate(p, s, options)
		// Chat names (chat_title.go): the prompt sent again may name the
		// chat, as any delivered message does; OpenCode's regenerate sends
		// through deliverPrompt, which names it there.
		if err == nil && id != "" {
			h.autoNameMessage(p, s, h.chatProviderFor(s), id)
		}
	} else {
		id, err = h.regenerateOpenCode(p, s, options, in.Mode, in.Effort)
	}
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, 400, "invalid_request", "This chat has no message to regenerate")
	case errors.Is(err, errChatUnsupported):
		writeError(w, 400, "unsupported_operation", "This message cannot be regenerated")
	case errors.Is(err, errRegenerateAttachments):
		writeError(w, 409, "regenerate_unavailable", "The message had attachments, which are not kept; send it again with them")
	case err != nil:
		promptFailure(w, err)
	default:
		writeJSON(w, 202, sendReceipt{Accepted: true, MessageID: id, TurnID: id})
	}
}

// regenerateOpenCode reverts an OpenCode chat to its latest prompt, unless it
// is already rewound there, and sends that prompt again.
func (h *Host) regenerateOpenCode(p Project, s Session, options PromptOptions, mode, effort string) (string, error) {
	agent, ok := h.agent.(RewindableAgent)
	if isCLISessionID(s.ID) || !ok {
		return "", errChatUnsupported
	}
	if effort != "" {
		return "", errOptionsUnsupported
	}
	options.Agent = mode
	if !validPromptOptions(options) {
		return "", errOptionsUnsupported
	}
	items, err := h.agent.Messages(p, s.ID)
	if err != nil {
		return "", err
	}
	target := s.RewindMessageID
	if target == "" {
		for _, item := range items {
			if item.Role == "user" {
				target = item.ID
			}
		}
	}
	var prompt *Message
	for index := range items {
		if items[index].ID == target {
			prompt = &items[index]
		}
	}
	if prompt == nil {
		return "", ErrNotFound
	}
	if len(prompt.Attachments) > 0 {
		return "", errRegenerateAttachments
	}
	if strings.TrimSpace(prompt.Text) == "" {
		return "", errChatUnsupported
	}
	if s.RewindMessageID == "" {
		if err := agent.Rewind(p, s.ID, target); err != nil {
			return "", err
		}
		if s, err = h.session(p, s.ID); err != nil {
			return "", err
		}
	}
	return h.deliverPrompt(p, s, prompt.Text, options, nil)
}
