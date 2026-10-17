package host

// codexProvider serves Codex chats through the Codex engine: streamed
// messages, approvals and questions held by the host, rewind, fork, models
// and modes. Sending still goes through CLIChats.PromptAs, which hands Codex
// chats to the engine.
type codexProvider struct {
	cliProvider
	engine    *codexEngine
	sessionID string
}

func (c codexProvider) transport() string  { return c.engine.capability().Transport }
func (c codexProvider) features() []string { return c.engine.capability().Features }

func (c codexProvider) load(p Project, sessionID string, limit int) (chatLoad, error) {
	return c.engine.load(p, sessionID, limit)
}

func (c codexProvider) page(p Project, s Session, before string, limit int) ([]ChatMessage, bool, error) {
	return c.engine.page(p, s.ID, before, limit)
}

func (c codexProvider) interrupt(p Project, sessionID string) error {
	return c.engine.interrupt(p, sessionID)
}

func (c codexProvider) replyPermission(p Project, requestID, reply string) error {
	return c.engine.replyPermission(p, c.sessionID, requestID, reply)
}

func (c codexProvider) replyQuestion(p Project, requestID string, answers [][]string) error {
	return c.engine.replyQuestion(p, c.sessionID, requestID, answers, false)
}

func (c codexProvider) rejectQuestion(p Project, requestID string) error {
	return c.engine.replyQuestion(p, c.sessionID, requestID, nil, true)
}

func (c codexProvider) rewind(p Project, sessionID, messageID string) error {
	return c.engine.rewind(p, sessionID, messageID)
}

func (c codexProvider) restore(p Project, sessionID string) error {
	return c.engine.restore(p, sessionID)
}

// filesRestore: Codex's thread/revert changes only the conversation.
func (c codexProvider) filesRestore() string { return "unavailable" }

func (c codexProvider) pendingRequests(p Project) ([]PermissionRequest, []QuestionRequest) {
	return c.engine.pendingRequests(p, c.sessionID)
}

func (c codexProvider) fork(p Project, s Session, messageID, title string) (Session, error) {
	return c.engine.fork(p, s, messageID, title)
}

// providerRewinder lets the rewind routes rewind a chat through its
// provider.
type providerRewinder struct{ provider chatProvider }

func (r providerRewinder) Rewind(p Project, sessionID, messageID string) error {
	return r.provider.rewind(p, sessionID, messageID)
}

func (r providerRewinder) Restore(p Project, sessionID string) error {
	return r.provider.restore(p, sessionID)
}

// hostInteractions is implemented by chat providers whose pending approvals
// and questions the host holds (Codex through its app-server), for the
// legacy interaction routes.
type hostInteractions interface {
	pendingRequests(p Project) ([]PermissionRequest, []QuestionRequest)
}

func isHostInteractions(provider chatProvider) bool {
	_, ok := provider.(hostInteractions)
	return ok
}

// setHub gives the Codex engine the chat hub it mirrors changes to.
func (c *CLIChats) setHub(hub *chatHub) {
	if c == nil || c.codex == nil {
		return
	}
	c.mu.Lock()
	c.codex.hub = hub
	c.mu.Unlock()
}

// codexOptions lists a Codex chat's models and modes, or those a new Codex
// chat can use when session is empty.
func (c *CLIChats) codexOptions(project Project, sessionID string) (ChatOptions, bool, error) {
	if c == nil || c.codex == nil {
		return ChatOptions{}, false, nil
	}
	if sessionID != "" {
		if _, err := c.GetSession(project, sessionID); err != nil {
			return ChatOptions{}, true, err
		}
	}
	return c.codex.chatOptions(), true, nil
}
