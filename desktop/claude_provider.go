package host

import (
	"strings"
	"time"
)

// claudeProvider serves Claude Code chats through the Claude engine: one
// stream-json process per chat, live parts, approvals and questions held by
// the host, rewind with file restore on the next send, regenerate and fork.
type claudeProvider struct {
	engine    *claudeEngine
	sessionID string
}

func isClaudeSessionID(id string) bool { return strings.HasPrefix(id, "claude:") }

func (c claudeProvider) name() string      { return "claude" }
func (c claudeProvider) transport() string { return "stream-json" }

// features lists what Claude chats support. modes and effort follow the
// contract's rule that clients send mode and effort only to providers that
// list them.
func (c claudeProvider) features() []string {
	return []string{"rewind", "restoreFiles", "fork", "approvals", "questions", "modes", "effort"}
}

func (c claudeProvider) chat(p Project, sessionID string) (*claudeChat, error) {
	return c.engine.chat(p, sessionID)
}

func (c claudeProvider) options(p Project, sessionID string) (ChatOptions, error) {
	if sessionID != "" {
		if _, err := c.chat(p, sessionID); err != nil {
			return ChatOptions{}, err
		}
	}
	return c.engine.chatOptions(p), nil
}

func (c claudeProvider) create(p Project, title string) (Session, error) {
	return c.engine.cli.CreateSession(p, title, "claude")
}

func (c claudeProvider) snapshot(p Project, sessionID string, limit int, apply func(chatLoad)) error {
	chat, err := c.chat(p, sessionID)
	if err != nil {
		return err
	}
	chat.snapshot(limit, apply)
	return nil
}

func (c claudeProvider) load(p Project, sessionID string, limit int) (chatLoad, error) {
	var load chatLoad
	err := c.snapshot(p, sessionID, limit, func(read chatLoad) { load = read })
	return load, err
}

func (c claudeProvider) page(p Project, s Session, before string, limit int) ([]ChatMessage, bool, error) {
	chat, err := c.chat(p, s.ID)
	if err != nil {
		return nil, false, err
	}
	return chat.page(before, limit)
}

// newMessageID names a user message before it is sent (messageIDMaker): the
// archive files the message under it, and the CLI takes it as the prompt's
// uuid, so every copy shares one ID.
func (c claudeProvider) newMessageID(time.Time) string { return newClaudeUUID() }

func (c claudeProvider) send(p Project, s Session, prompt chatPrompt) (string, error) {
	chat, err := c.chat(p, s.ID)
	if err != nil {
		return "", err
	}
	return chat.send(prompt)
}

func (c claudeProvider) interrupt(p Project, sessionID string) error {
	chat, err := c.chat(p, sessionID)
	if err != nil {
		return err
	}
	return chat.interrupt()
}

func (c claudeProvider) replyPermission(p Project, requestID, reply string) error {
	chat, err := c.chat(p, c.sessionID)
	if err != nil {
		return err
	}
	return chat.replyPermission(requestID, reply)
}

func (c claudeProvider) replyQuestion(p Project, requestID string, answers [][]string) error {
	chat, err := c.chat(p, c.sessionID)
	if err != nil {
		return err
	}
	return chat.replyQuestion(requestID, answers, false)
}

func (c claudeProvider) rejectQuestion(p Project, requestID string) error {
	chat, err := c.chat(p, c.sessionID)
	if err != nil {
		return err
	}
	return chat.replyQuestion(requestID, nil, true)
}

func (c claudeProvider) rewind(p Project, sessionID, messageID string) error {
	chat, err := c.chat(p, sessionID)
	if err != nil {
		return err
	}
	return chat.rewind(messageID)
}

func (c claudeProvider) restore(p Project, sessionID string) error {
	chat, err := c.chat(p, sessionID)
	if err != nil {
		return err
	}
	return chat.restore()
}

// filesRestore: Claude Code puts files back on the next send (rewind_files).
func (c claudeProvider) filesRestore() string { return "onSend" }

// pendingRequests serves GET /v1/interactions (hostInteractions).
func (c claudeProvider) pendingRequests(p Project) ([]PermissionRequest, []QuestionRequest) {
	chat, err := c.chat(p, c.sessionID)
	if err != nil {
		return []PermissionRequest{}, []QuestionRequest{}
	}
	return chat.pendingRequests()
}

// fork serves POST /v1/chat/fork (chatForker).
func (c claudeProvider) fork(p Project, s Session, messageID, title string) (Session, error) {
	chat, err := c.chat(p, s.ID)
	if err != nil {
		return Session{}, err
	}
	return c.engine.fork(p, chat, messageID, title)
}

// regenerate serves POST /v1/chat/regenerate (chatRegenerator).
func (c claudeProvider) regenerate(p Project, s Session, options PromptOptions) (string, error) {
	chat, err := c.chat(p, s.ID)
	if err != nil {
		return "", err
	}
	return chat.regenerate(options)
}

// Routing from CLIChats for Claude chats the engine runs (cli_chat.go).

func (e *claudeEngine) legacyTranscript(project Project, id string) ([]Message, error) {
	chat, err := e.chat(project, id)
	if err != nil {
		return nil, err
	}
	legacy, err := e.cli.claudeLegacy(project, id)
	if err != nil {
		return nil, err
	}
	return chat.legacyTranscript(legacy), nil
}

// configure sets a new chat's model, mode and effort (POST /v1/sessions).
func (e *claudeEngine) configure(project Project, id string, options PromptOptions) error {
	chat, err := e.chat(project, id)
	if err != nil {
		return err
	}
	settings, err := chat.settingsFor(options)
	if err != nil {
		return err
	}
	chat.mu.Lock()
	defer chat.mu.Unlock()
	chat.rec.Model, chat.rec.Mode, chat.rec.Effort = settings.model, settings.mode, settings.effort
	chat.persistLocked()
	chat.pushInfoLocked()
	return nil
}

// claudeValidOptions checks a model, mode and effort without a chat.
func claudeValidOptions(options PromptOptions) bool {
	_, err := (&claudeChat{rec: claudeRecord{Mode: claudeDefaultMode}}).settingsFor(options)
	return err == nil
}

func (e *claudeEngine) status(project Project, id string) (ChatStatus, error) {
	chat, err := e.chat(project, id)
	if err != nil {
		return ChatStatus{}, err
	}
	return ChatStatus{State: chat.activity()}, nil
}
