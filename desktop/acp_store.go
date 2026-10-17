package host

import (
	"strings"
	"time"
)

// An ACP chat's state in the chats registry (<state>.chats.json) under the
// record's "acp" key (docs/HOST-API.md "ACP chats"): the agent, its ACP
// session and modes, and the chat's messages in the unified model.

type acpChatRecord struct {
	// Agent is the agent's catalog id, the chat's provider.
	Agent string `json:"agent"`
	// SessionID is the agent's ACP session, from session/new; a new process
	// loads it when the agent can.
	SessionID string `json:"sessionId,omitempty"`
	// Mode is the session's current mode; Modes those the agent listed last.
	Mode  string     `json:"mode,omitempty"`
	Modes []ChatMode `json:"modes,omitempty"`
	// Messages are the chat's messages, oldest first.
	Messages []ChatMessage `json:"messages,omitempty"`
	// Running is the turn in progress when the record was saved.
	Running string `json:"running,omitempty"`
}

// isACPSessionID: an ACP chat's ID is its agent's catalog ID, a colon and 32
// hex digits ("gemini:0f3a…"), as Claude Code's and Codex's chats carry their
// agent ("claude:…", "codex:…"), so the apps know a chat's agent from its ID.
func isACPSessionID(id string) bool {
	agent, rest, ok := strings.Cut(id, ":")
	if !ok || agent == "claude" || agent == "codex" || !agentIDPattern.MatchString(agent) || len(rest) != 32 {
		return false
	}
	for _, r := range rest {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

// acpChatTitle is a new chat's title and its source: the agent's name, or a
// title the chat was created with that only names the agent, is a
// placeholder ("default"); any other title is its creator's ("provider").
func acpChatTitle(title, agentID, agentName string) (string, string) {
	trimmed := strings.TrimSpace(title)
	if trimmed == "" {
		return agentName, titleDefault
	}
	lower := strings.ToLower(trimmed)
	for _, name := range []string{agentName, agentID} {
		name = strings.ToLower(strings.TrimSpace(name))
		if name != "" && (lower == name || lower == name+" chat") {
			return title, titleDefault
		}
	}
	return title, titleSourceFor(title)
}

// CreateACPSession adds an ACP chat of agent to the registry.
func (c *CLIChats) CreateACPSession(project Project, title, agent, agentName string) (Session, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Session{}, ErrCLIChatUnavailable
	}
	id := agent + ":" + cliMessageID()
	title, source := acpChatTitle(title, agent, agentName)
	session := Session{ID: id, Title: title, ProjectID: project.ID, Directory: project.Directory, Provider: agent, TitleSource: source}
	c.records[id] = &cliChatRecord{Session: session, Directory: project.Directory, Messages: []Message{}, UpdatedAt: time.Now(), ACP: &acpChatRecord{Agent: agent}}
	if err := c.saveLocked(); err != nil {
		delete(c.records, id)
		return Session{}, err
	}
	return session, nil
}

// acpEntry is one read of an ACP chat's registry record.
type acpEntry struct {
	session Session
	state   acpChatRecord
}

func (c *CLIChats) acpEntry(project Project, id string) (acpEntry, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil || record.ACP == nil {
		return acpEntry{}, ErrNotFound
	}
	state := *record.ACP
	state.Messages = cloneMessages(state.Messages)
	state.Modes = append([]ChatMode(nil), state.Modes...)
	return acpEntry{session: record.Session, state: state}, nil
}

// acpSave stores a copy of an ACP chat's state: the chat keeps changing its
// own slices under its lock, and parts' tools, usage and errors are replaced,
// never changed, so sharing those is safe.
func (c *CLIChats) acpSave(project Project, id string, state acpChatRecord, updated time.Time) error {
	state.Messages = cloneMessages(state.Messages)
	state.Modes = append([]ChatMode(nil), state.Modes...)
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return err
	}
	previous := *record
	record.ACP, record.UpdatedAt = &state, updated
	if err := c.saveLocked(); err != nil {
		*record = previous
		return err
	}
	return nil
}

// acpUnified is an ACP chat's transcript for the archive's import
// (archive_backfill.go).
func (record *cliChatRecord) acpUnified() []ChatMessage {
	if record.ACP == nil {
		return nil
	}
	messages := make([]ChatMessage, 0, len(record.ACP.Messages))
	for _, message := range record.ACP.Messages {
		message.ChatID = record.Session.ID
		messages = append(messages, cloneMessage(message))
	}
	return messages
}
