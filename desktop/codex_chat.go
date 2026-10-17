package host

import (
	"context"
	"errors"
	"time"
)

// Chat operations on Codex chats: stop, reads for the hub, rewind,
// restore and fork.

// interrupt stops a running turn: turn/interrupt with its thread and turn,
// or ending the codex exec process. A stop before Codex confirmed the turn
// is sent as soon as it does.
func (e *codexEngine) interrupt(project Project, id string) error {
	c := e.chats
	c.mu.Lock()
	if _, err := c.recordLocked(project, id); err != nil {
		c.mu.Unlock()
		return err
	}
	turn := e.turns[id]
	if turn == nil || turn.done {
		c.mu.Unlock()
		return nil
	}
	turn.interrupt = true
	cancel, conn, threadID, turnID := turn.cancel, turn.conn, turn.threadID, turn.turnID
	c.mu.Unlock()
	if cancel != nil {
		cancel()
		return nil
	}
	if conn == nil || turnID == "" {
		return nil
	}
	e.hold()
	defer e.release()
	ctx, done := context.WithTimeout(context.Background(), 10*time.Second)
	defer done()
	err := conn.call(ctx, "turn/interrupt", codexParams{"threadId": threadID, "turnId": turnID}, nil)
	var rpc *codexRPCError
	var call *codexCallError
	switch {
	case err == nil, errors.As(err, &rpc):
		// Codex answered; an error means the turn had already ended.
		return nil
	case errors.As(err, &call) && errors.Is(call.err, errCodexStopped):
		return nil
	}
	return err
}

// load reads a Codex chat for the hub: visible messages (before a rewind
// point), settings, activity and pending interactions.
func (e *codexEngine) load(project Project, sessionID string, limit int) (chatLoad, error) {
	c := e.chats
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, sessionID)
	if err != nil {
		return chatLoad{}, err
	}
	settings := record.codexSettings()
	name := sessionName(record.Session)
	result := chatLoad{info: ChatInfo{ID: sessionID, Title: name.Title, TitleSource: name.Source, TitleBasis: name.Basis, Provider: "codex", Model: settings.modelID(), Mode: settings.mode, Effort: settings.effort}, rewind: record.codexRewind(), state: "idle"}
	messages := record.codexUnified()
	if record.Busy {
		result.state = "busy"
		if turn := e.turns[sessionID]; turn != nil && turn.retrying {
			result.state = "retry"
		}
	} else {
		for index := range messages {
			if messages[index].Status == "streaming" {
				messages[index].Status = "aborted"
			}
		}
	}
	if len(messages) > limit {
		result.hasOlder = true
		messages = messages[len(messages)-limit:]
	}
	result.messages = messages
	for _, pending := range e.orderedRequestsLocked(sessionKey{project.ID, sessionID}) {
		result.interactions = append(result.interactions, pending.interaction)
	}
	return result, nil
}

func (e *codexEngine) page(project Project, sessionID, before string, limit int) ([]ChatMessage, bool, error) {
	c := e.chats
	c.mu.Lock()
	record, err := c.recordLocked(project, sessionID)
	if err != nil {
		c.mu.Unlock()
		return nil, false, err
	}
	messages := record.codexUnified()
	c.mu.Unlock()
	return pageMessages(messages, before, limit)
}

// rewind hides the latest user message and its reply until a restore; the
// next send drops them and removes their turn from Codex's history. Files
// are not restored: thread/revert changes only the conversation.
func (e *codexEngine) rewind(project Project, sessionID, messageID string) error {
	if e.execTransport() || e.lacks("thread/revert") {
		return errChatUnsupported
	}
	c := e.chats
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, sessionID)
	if err != nil {
		return err
	}
	if record.Busy {
		return ErrCLIChatBusy
	}
	codex := record.codex()
	if codex.Turns[messageID] == "" {
		return errChatUnsupported
	}
	previous := codex.Rewind
	codex.Rewind = messageID
	if err := c.saveLocked(); err != nil {
		codex.Rewind = previous
		return err
	}
	e.hubLocked().codexRebuild(sessionKey{project.ID, sessionID})
	return nil
}

func (e *codexEngine) restore(project Project, sessionID string) error {
	c := e.chats
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, sessionID)
	if err != nil {
		return err
	}
	if record.codexRewind() == "" {
		return nil
	}
	previous := record.Codex.Rewind
	record.Codex.Rewind = ""
	if err := c.saveLocked(); err != nil {
		record.Codex.Rewind = previous
		return err
	}
	e.hubLocked().codexRebuild(sessionKey{project.ID, sessionID})
	return nil
}

// fork copies a chat into a new one through the turn of messageID (or all
// visible messages): thread/fork with lastTurnId gives the new chat its own
// Codex thread holding the same history.
func (e *codexEngine) fork(project Project, session Session, messageID, title string) (Session, error) {
	// Codex runs only in workspaces: the Chats space's chats are read-only.
	if project.ID == plainChatsProjectID {
		return Session{}, errChatsSpaceRetired
	}
	c := e.chats
	c.mu.Lock()
	record, err := c.recordLocked(project, session.ID)
	if err != nil {
		c.mu.Unlock()
		return Session{}, err
	}
	if record.Busy {
		c.mu.Unlock()
		return Session{}, ErrCLIChatBusy
	}
	visible := record.codexUnified()
	cut := len(visible)
	turnUser := ""
	if messageID != "" {
		index := -1
		for position, message := range visible {
			if message.ID == messageID {
				index = position
				break
			}
		}
		if index < 0 {
			c.mu.Unlock()
			return Session{}, ErrNotFound
		}
		turnUser = visible[index].TurnID
		cut = index + 1
		for cut < len(visible) && visible[cut].Role != "user" && visible[cut].TurnID == turnUser {
			cut++
		}
	} else {
		for index := len(visible) - 1; index >= 0; index-- {
			if visible[index].Role == "user" {
				turnUser = visible[index].TurnID
				break
			}
		}
	}
	codex := record.codex()
	codexTurnID := ""
	if turnUser != "" {
		codexTurnID = codex.Turns[turnUser]
		if codexTurnID == "" && record.NativeID != "" {
			c.mu.Unlock()
			return Session{}, errChatUnsupported
		}
	}
	threadID, directory, settings := record.NativeID, record.Directory, record.codexSettings()
	if title == "" {
		title = record.Session.Title
	}
	copied := &cliChatRecord{Session: Session{Title: title, ProjectID: project.ID, Directory: record.Directory, Provider: "codex"}, Directory: record.Directory, Messages: []Message{}, Created: map[string]time.Time{}, Codex: &codexChatRecord{Model: settings.model, Mode: settings.mode, Effort: settings.effort, Unified: map[string]*ChatMessage{}, Turns: map[string]string{}, Parent: session.ID}}
	for _, message := range record.visibleMessages()[:cut] {
		message.Unified = nil
		copied.Messages = append(copied.Messages, message)
		if created, ok := record.Created[message.ID]; ok {
			copied.Created[message.ID] = created
		}
		if unified := codex.Unified[message.ID]; unified != nil {
			clone := cloneChatMessage(*unified)
			copied.Codex.Unified[message.ID] = &clone
		}
		if turn := codex.Turns[message.ID]; turn != "" {
			copied.Codex.Turns[message.ID] = turn
		}
	}
	c.mu.Unlock()

	newThread := ""
	if threadID != "" && codexTurnID != "" {
		if e.execTransport() || e.lacks("thread/fork") {
			return Session{}, errChatUnsupported
		}
		conn, err := e.connection()
		if err != nil {
			return Session{}, errChatUnsupported
		}
		e.hold()
		ctx, cancel := context.WithTimeout(context.Background(), e.config.duration(e.config.callTimeout, 30*time.Second))
		mode := settings.modeSpec()
		params := codexModeParams(codexParams{"threadId": threadID, "lastTurnId": codexTurnID, "excludeTurns": true, "cwd": directory}, mode)
		if settings.model != "" {
			params["model"] = settings.model
		}
		var result struct {
			Thread struct {
				ID string `json:"id"`
			} `json:"thread"`
		}
		err = conn.call(ctx, "thread/fork", params, &result)
		cancel()
		e.release()
		if err != nil {
			e.noteMissing("thread/fork", err)
			if e.lacks("thread/fork") {
				return Session{}, errChatUnsupported
			}
			return Session{}, err
		}
		newThread = result.Thread.ID
		conn.markLoaded(newThread, mode.id)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Session{}, ErrCLIChatUnavailable
	}
	id := "codex:" + cliMessageID()
	copied.Session.ID = id
	copied.NativeID = newThread
	copied.UpdatedAt = time.Now()
	for _, message := range copied.Codex.Unified {
		message.ChatID = id
	}
	c.records[id] = copied
	if err := c.saveLocked(); err != nil {
		delete(c.records, id)
		return Session{}, err
	}
	if newThread != "" {
		e.threads[newThread] = sessionKey{project.ID, id}
	}
	result := copied.Session
	result.ParentSessionID = session.ID
	return result, nil
}
