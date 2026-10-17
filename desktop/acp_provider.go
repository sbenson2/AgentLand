package host

import "time"

// acpProvider serves ACP chats (docs/HOST-API.md "ACP chats"): live parts
// pushed from each chat's process, approvals held by the host, modes; no
// rewind, regenerate, fork or questions in this round.
type acpProvider struct {
	engine    *acpEngine
	sessionID string
	agent     string
}

func (a acpProvider) name() string      { return a.agent }
func (a acpProvider) transport() string { return "acp" }

// features: approvals, and modes (session/set_mode) for chats whose agent
// lists them.
func (a acpProvider) features() []string { return []string{"approvals", "modes"} }

func (a acpProvider) options(p Project, sessionID string) (ChatOptions, error) {
	if sessionID == "" {
		return a.engine.newChatOptions(a.agent), nil
	}
	return a.engine.chatOptions(p, sessionID)
}

func (a acpProvider) create(p Project, title string) (Session, error) {
	return a.engine.create(p, title, a.agent)
}

func (a acpProvider) snapshot(p Project, sessionID string, limit int, apply func(chatLoad)) error {
	chat, err := a.engine.chat(p, sessionID)
	if err != nil {
		return err
	}
	chat.snapshot(limit, apply)
	return nil
}

func (a acpProvider) load(p Project, sessionID string, limit int) (chatLoad, error) {
	var load chatLoad
	err := a.snapshot(p, sessionID, limit, func(read chatLoad) { load = read })
	return load, err
}

func (a acpProvider) page(p Project, s Session, before string, limit int) ([]ChatMessage, bool, error) {
	chat, err := a.engine.chat(p, s.ID)
	if err != nil {
		return nil, false, err
	}
	return chat.page(before, limit)
}

// newMessageID names the user message before it is sent (messageIDMaker),
// so the archive's copy and the chat's are one.
func (a acpProvider) newMessageID(time.Time) string { return cliMessageID() }

func (a acpProvider) send(p Project, s Session, prompt chatPrompt) (string, error) {
	chat, err := a.engine.chat(p, s.ID)
	if err != nil {
		return "", err
	}
	return chat.send(prompt)
}

func (a acpProvider) interrupt(p Project, sessionID string) error {
	chat, err := a.engine.chat(p, sessionID)
	if err != nil {
		return err
	}
	return chat.interrupt()
}

func (a acpProvider) replyPermission(p Project, requestID, reply string) error {
	chat, err := a.engine.chat(p, a.sessionID)
	if err != nil {
		return err
	}
	return chat.replyPermission(requestID, reply)
}

// ACP agents ask no questions the host shows.
func (a acpProvider) replyQuestion(Project, string, [][]string) error { return ErrNotFound }
func (a acpProvider) rejectQuestion(Project, string) error            { return ErrNotFound }
func (a acpProvider) rewind(Project, string, string) error            { return errChatUnsupported }
func (a acpProvider) restore(Project, string) error                   { return errChatUnsupported }

// pendingRequests serves GET /v1/interactions (hostInteractions).
func (a acpProvider) pendingRequests(p Project) ([]PermissionRequest, []QuestionRequest) {
	chat, err := a.engine.chat(p, a.sessionID)
	if err != nil {
		return []PermissionRequest{}, []QuestionRequest{}
	}
	return chat.pendingRequests()
}

// acpProviderFor is the provider of an ACP chat, or of new chats of agent.
func (c *CLIChats) acpProviderFor(sessionID, agent string) chatProvider {
	if c == nil || c.acp == nil {
		return nil
	}
	if agent == "" && sessionID != "" {
		c.mu.Lock()
		if record := c.records[sessionID]; record != nil {
			agent = record.Session.Provider
		}
		c.mu.Unlock()
	}
	if agent == "" {
		return nil
	}
	return acpProvider{engine: c.acp, sessionID: sessionID, agent: agent}
}
