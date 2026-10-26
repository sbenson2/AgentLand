package host

import (
	"encoding/json"
	"time"
)

// A Claude Code chat's streaming state, kept in the chats registry
// (<state>.chats.json) under the chat's "claude" key. Replies from before the
// chat streamed stay in the record's legacy messages.
type claudeRecord struct {
	// Model is the CLI model value ("" for the CLI's default), Mode the
	// permission mode and Effort the effort level ("" for the default) the
	// next turn runs with.
	Model  string `json:"model,omitempty"`
	Mode   string `json:"mode,omitempty"`
	Effort string `json:"effort,omitempty"`
	// Parent is the chat this one was forked from. Until the fork's first
	// prompt is delivered, ForkFrom is the Claude session it resumes and
	// ForkAt the transcript entry it keeps up to ("" keeps all of it).
	Parent   string `json:"parent,omitempty"`
	ForkFrom string `json:"forkFrom,omitempty"`
	ForkAt   string `json:"forkAt,omitempty"`
	// Started says the Claude session named by the record's native ID holds
	// a delivered prompt, so the next process resumes it.
	Started bool `json:"started,omitempty"`
	// Messages are the chat's messages since it began streaming, in the
	// unified model and in order.
	Messages []ChatMessage `json:"messages,omitempty"`
	// Turns is the uuid chain: each delivered prompt with the transcript
	// entry just before it and the last entry of its turn.
	Turns []claudeTurnRecord `json:"turns,omitempty"`
	// LastEntry is the newest transcript entry the host has seen; Gap says
	// entries were written that the host did not see (it stopped mid-turn).
	LastEntry string `json:"lastEntry,omitempty"`
	Gap       bool   `json:"gap,omitempty"`
	// Rewind hides this user message and everything after it. The next send
	// drops them for good; a restore shows them again.
	Rewind string `json:"rewind,omitempty"`
	// Running is the turn in progress when the record was saved.
	Running string `json:"running,omitempty"`
	// Cost carried across processes (claude_cost.go): Claude Code restores a
	// session's total_cost_usd on --resume from what it saved when one of the
	// session's processes last exited. CostSession is the session CostSaved
	// is known for ("" while unknown); CostTotal is the newest total a
	// process of the chat reported, which Claude Code saves when that
	// process exits.
	CostSession string  `json:"costSession,omitempty"`
	CostSaved   float64 `json:"costSaved,omitempty"`
	CostTotal   float64 `json:"costTotal,omitempty"`
	// ContinuedIn is the chat this one continued in (chat_continue.go), the
	// newest when it continued more than once, and ContinuedAt when (UTC RFC
	// 3339 with milliseconds).
	ContinuedIn string `json:"continuedIn,omitempty"`
	ContinuedAt string `json:"continuedAt,omitempty"`
}

type claudeTurnRecord struct {
	// Prompt is the user message's ID, which is also its Claude uuid.
	Prompt string `json:"prompt"`
	// Before is the transcript entry the prompt followed; First says the
	// prompt began its session. A turn with neither cannot be dropped.
	Before string `json:"before,omitempty"`
	First  bool   `json:"first,omitempty"`
	// Last is the turn's last transcript entry, a fork point.
	Last string `json:"last,omitempty"`
}

func (r *claudeRecord) turn(prompt string) (int, *claudeTurnRecord) {
	for index := range r.Turns {
		if r.Turns[index].Prompt == prompt {
			return index, &r.Turns[index]
		}
	}
	return -1, nil
}

// claudeUnified is a streamed Claude chat's visible transcript for the
// archive's import (archive_backfill.go): the replies from before it streamed,
// then the streamed messages up to the rewind point.
func (record *cliChatRecord) claudeUnified() []ChatMessage {
	messages := unifiedMessages(record.Messages, "claude", record.Session.ID, func(_ int, message Message) time.Time {
		if created, ok := record.Created[message.ID]; ok {
			return created
		}
		return record.UpdatedAt
	})
	for index := range messages {
		if messages[index].Role == "assistant" && messages[index].Model == "" {
			messages[index].Model = "claude/default"
		}
	}
	var state claudeRecord
	if json.Unmarshal(record.Claude, &state) != nil {
		return messages
	}
	for _, message := range state.Messages {
		if state.Rewind != "" && message.ID == state.Rewind {
			break
		}
		message.ChatID = record.Session.ID
		messages = append(messages, cloneMessage(message))
	}
	return messages
}

// claudeEntry is one read of a Claude chat's registry record.
type claudeEntry struct {
	session   Session
	directory string
	native    string
	legacy    []Message
	created   map[string]time.Time
	updated   time.Time
	state     json.RawMessage
}

func (c *CLIChats) claudeEntry(project Project, id string) (claudeEntry, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return claudeEntry{}, err
	}
	created := make(map[string]time.Time, len(record.Created))
	for key, value := range record.Created {
		created[key] = value
	}
	return claudeEntry{session: record.Session, directory: record.Directory, native: record.NativeID, legacy: append([]Message{}, record.Messages...), created: created, updated: record.UpdatedAt, state: append(json.RawMessage(nil), record.Claude...)}, nil
}

// claudeLegacy returns the replies a Claude chat had before it streamed.
func (c *CLIChats) claudeLegacy(project Project, id string) ([]Message, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return nil, err
	}
	return append([]Message{}, record.Messages...), nil
}

// claudeSave stores a Claude chat's native session ID, encoded state and
// rewind point.
func (c *CLIChats) claudeSave(project Project, id, native string, state json.RawMessage, rewind string, updated time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return err
	}
	previous := *record
	record.NativeID, record.Claude, record.ClaudeRewind, record.UpdatedAt = native, state, rewind, updated
	if err := c.saveLocked(); err != nil {
		*record = previous
		return err
	}
	return nil
}

// claudeCreate adds a Claude chat record (a fork) with its encoded state.
func (c *CLIChats) claudeCreate(project Project, session Session, state json.RawMessage) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ErrCLIChatUnavailable
	}
	if _, exists := c.records[session.ID]; exists {
		return ErrCLIChatUnavailable
	}
	c.records[session.ID] = &cliChatRecord{Session: session, Directory: project.Directory, Messages: []Message{}, UpdatedAt: time.Now(), Claude: state}
	if err := c.saveLocked(); err != nil {
		delete(c.records, session.ID)
		return err
	}
	return nil
}
