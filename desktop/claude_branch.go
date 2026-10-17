package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Rewind, restore, regenerate and fork for Claude Code chats. A rewind only
// hides messages and restores nothing yet (filesRestore "onSend"): the next
// send asks Claude Code to put the files back (rewind_files, a dry run
// first) and then resumes the session without the dropped turn
// (--resume-session-at the entry before it, --resume-drops-turn its prompt),
// or starts a new session when the dropped turn was the first.

var errRegenerateAttachments = errors.New("the message had attachments, which are not kept")

// latestUserLocked is the newest visible user message.
func (c *claudeChat) latestUserLocked() (ChatMessage, bool) {
	visible := c.visibleLocked()
	for index := len(visible) - 1; index >= 0; index-- {
		if visible[index].Role == "user" {
			return visible[index], true
		}
	}
	return ChatMessage{}, false
}

// droppableLocked reports whether the turn a user message began can be
// dropped from Claude's transcript.
func (c *claudeChat) droppableLocked(messageID string) bool {
	_, record := c.rec.turn(messageID)
	return record != nil && (record.First || record.Before != "")
}

// rewind hides the latest user message and everything after it.
func (c *claudeChat) rewind(messageID string) error {
	c.op.Lock()
	defer c.op.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.turn != nil || c.outgoing != nil {
		return ErrCLIChatBusy
	}
	latest, ok := c.latestUserLocked()
	if !ok || latest.ID != messageID {
		return ErrNotFound
	}
	if !c.droppableLocked(messageID) {
		return errChatUnsupported
	}
	c.rec.Rewind, c.plan = messageID, nil
	c.persistLocked()
	c.replaceHubLocked()
	return nil
}

// restore shows the hidden messages again.
func (c *claudeChat) restore() error {
	c.op.Lock()
	defer c.op.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.turn != nil || c.outgoing != nil {
		return ErrCLIChatBusy
	}
	if c.rec.Rewind == "" {
		return nil
	}
	c.rec.Rewind, c.plan = "", nil
	c.persistLocked()
	c.replaceHubLocked()
	return nil
}

// prepareRewind puts the files back and plans the next process so it
// resumes without the rewound turn. The caller holds op.
func (c *claudeChat) prepareRewind(point string) error {
	c.mu.Lock()
	// A plan left by a failed attempt must not start the process that puts
	// the files back.
	c.plan = nil
	_, record := c.rec.turn(point)
	if record == nil || (!record.First && record.Before == "") {
		c.mu.Unlock()
		return fmt.Errorf("%w: %w", errClaudeNotRewindable, errPromptNotSent)
	}
	first, before := record.First, record.Before
	started, native := c.rec.Started, c.native
	settings := claudeSettings{model: c.rec.Model, mode: c.rec.Mode, effort: c.rec.Effort}
	c.mu.Unlock()
	if started && native != "" {
		proc, err := c.ensureProcess(settings, "")
		if err != nil {
			return err
		}
		dry, err := c.control(proc, map[string]any{"subtype": "rewind_files", "user_message_id": point, "dry_run": true})
		var check struct {
			CanRewind bool `json:"canRewind"`
		}
		if err == nil && json.Unmarshal(dry, &check) == nil && check.CanRewind {
			if _, err := c.control(proc, map[string]any{"subtype": "rewind_files", "user_message_id": point}); err != nil {
				return errClaudeFilesNotRewound
			}
		}
		proc.stop(false, c.engine.options.stopGrace)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if first || !started || native == "" {
		c.plan = &claudeLaunch{session: newClaudeUUID()}
	} else {
		c.plan = &claudeLaunch{resume: native, at: before, drops: point}
	}
	return nil
}

// regenerate drops the latest turn and sends its prompt again.
func (c *claudeChat) regenerate(options PromptOptions) (string, error) {
	c.op.Lock()
	c.mu.Lock()
	if c.turn != nil || c.outgoing != nil {
		c.mu.Unlock()
		c.op.Unlock()
		return "", ErrCLIChatBusy
	}
	target := c.rec.Rewind
	if target == "" {
		latest, ok := c.latestUserLocked()
		if !ok {
			c.mu.Unlock()
			c.op.Unlock()
			return "", ErrNotFound
		}
		target = latest.ID
	}
	index := c.findLocked(target)
	if index < 0 || !c.droppableLocked(target) {
		c.mu.Unlock()
		c.op.Unlock()
		return "", errChatUnsupported
	}
	texts := []string{}
	for _, part := range c.rec.Messages[index].Parts {
		switch part.Kind {
		case "attachment":
			c.mu.Unlock()
			c.op.Unlock()
			return "", errRegenerateAttachments
		case "text":
			texts = append(texts, part.Text)
		}
	}
	previous := c.rec.Rewind
	if previous != target {
		c.rec.Rewind, c.plan = target, nil
		c.persistLocked()
		c.replaceHubLocked()
	}
	c.mu.Unlock()
	c.op.Unlock()
	id, err := c.send(chatPrompt{text: strings.Join(texts, "\n\n"), options: options})
	if err != nil && errors.Is(err, errPromptNotSent) && previous != target {
		// Nothing was sent: show the chat as it was.
		c.mu.Lock()
		if c.rec.Rewind == target && c.turn == nil && c.outgoing == nil {
			c.rec.Rewind = previous
			c.persistLocked()
			c.replaceHubLocked()
		}
		c.mu.Unlock()
	}
	return id, err
}

// forkPoint returns the messages a fork keeps and the transcript entry it
// resumes up to: through messageID's turn, or every visible message.
func (c *claudeChat) forkPoint(messageID string) ([]ChatMessage, string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	visible := c.visibleLocked()
	if messageID == "" {
		if c.turn != nil || c.outgoing != nil {
			return nil, "", ErrCLIChatBusy
		}
		at := c.lastEntry
		if c.rec.Rewind != "" {
			if _, record := c.rec.turn(c.rec.Rewind); record != nil {
				at = record.Before
			}
		}
		return cloneMessages(visible), at, nil
	}
	chosen := -1
	for index, message := range visible {
		if message.ID == messageID {
			chosen = index
			break
		}
	}
	if chosen < 0 {
		return nil, "", ErrNotFound
	}
	turn := visible[chosen].TurnID
	if c.turn != nil && turn == c.turn.id {
		return nil, "", ErrCLIChatBusy
	}
	_, record := c.rec.turn(turn)
	if record == nil || record.Last == "" {
		return nil, "", errChatUnsupported
	}
	end := chosen
	for index := chosen + 1; index < len(visible) && visible[index].TurnID == turn; index++ {
		end = index
	}
	return cloneMessages(visible[:end+1]), record.Last, nil
}

// fork creates a Claude chat that resumes this one's session up to the fork
// point (--resume, --fork-session, --resume-session-at) on its first prompt.
func (e *claudeEngine) fork(project Project, source *claudeChat, messageID, title string) (Session, error) {
	// Claude Code runs only in workspaces: the Chats space's chats are
	// read-only.
	if project.ID == plainChatsProjectID {
		return Session{}, errChatsSpaceRetired
	}
	messages, at, err := source.forkPoint(messageID)
	if err != nil {
		return Session{}, err
	}
	source.mu.Lock()
	record := claudeRecord{Model: source.rec.Model, Mode: source.rec.Mode, Effort: source.rec.Effort, Parent: source.id, Messages: messages}
	// A fork of an empty chat starts a new session; otherwise its first
	// process forks the source session at the fork point.
	if source.rec.Started && source.native != "" && len(messages) > 0 {
		record.ForkFrom, record.ForkAt, record.LastEntry = source.native, at, at
		record.Gap = at == ""
	}
	if title == "" {
		title = source.title
	}
	source.mu.Unlock()
	session := Session{ID: "claude:" + cliMessageID(), Title: title, ProjectID: project.ID, Directory: project.Directory, Provider: "claude", ParentSessionID: source.id}
	for index := range record.Messages {
		record.Messages[index].ChatID = session.ID
	}
	state, err := json.Marshal(record)
	if err != nil {
		return Session{}, err
	}
	if err := e.cli.claudeCreate(project, session, state); err != nil {
		return Session{}, err
	}
	return session, nil
}

// legacyTranscript is GET /v1/messages for the chat: the replies from
// before it streamed as they were stored, then the streamed ones, each with
// its parts for ?parts=1.
func (c *claudeChat) legacyTranscript(legacy []Message) []Message {
	c.mu.Lock()
	visible := cloneMessages(c.visibleLocked())
	legacyCount := len(c.legacy)
	c.mu.Unlock()
	result := make([]Message, 0, len(visible))
	for index, message := range visible {
		unified := message
		if index < legacyCount && index < len(legacy) {
			item := legacy[index]
			item.Unified = &unified
			result = append(result, item)
			continue
		}
		result = append(result, claudeLegacyMessage(unified))
	}
	return result
}

// claudeLegacyMessage is a streamed message in the legacy shape.
func claudeLegacyMessage(message ChatMessage) Message {
	result := Message{ID: message.ID, Role: message.Role, Unified: &message}
	texts := []string{}
	for _, part := range message.Parts {
		switch part.Kind {
		case "text":
			texts = append(texts, part.Text)
		case "reasoning":
			result.Reasoning = append(result.Reasoning, ReasoningPart{Text: part.Text})
		case "tool":
			tool := part.Tool
			result.Tools = append(result.Tools, ToolCall{ID: part.ID, CallID: tool.CallID, Name: tool.Name, Status: tool.Status, Title: tool.Title, Input: tool.Input, Output: tool.Output, Error: tool.Error, Truncated: tool.Truncated})
		case "attachment":
			result.Attachments = append(result.Attachments, *part.Attachment)
		}
	}
	result.Text = strings.Join(texts, "\n\n")
	if message.Status == "error" && message.Error != nil {
		result.Error = message.Error.Message
	}
	return result
}

// page returns up to limit visible messages older than before, newest
// first.
func (c *claudeChat) page(before string, limit int) ([]ChatMessage, bool, error) {
	c.mu.Lock()
	visible := cloneMessages(c.visibleLocked())
	c.mu.Unlock()
	return pageMessages(visible, before, limit)
}
