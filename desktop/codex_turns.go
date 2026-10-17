package host

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"time"
)

// codexTurn is one running Codex turn: the user message that started it and
// the assistant messages that stream its items in order. Guarded by
// chats.mu.
type codexTurn struct {
	key       sessionKey
	sessionID string
	userID    string
	settings  codexSettings
	finished  func()

	transport string // "app-server" or "exec"
	conn      *codexConn
	threadID  string
	turnID    string
	delivered bool
	interrupt bool   // the user stopped the turn
	cancel    func() // stops a codex exec run
	done      bool

	messages  []string                // assistant message IDs, in order
	assistant string                  // the one items go to now
	parts     map[string]codexPartRef // by Codex item ID
	reasoning map[string]string       // reasoning item: "summary" or "content"
	plan      string                  // item ID of the plan checklist
	usageBase *codexTokens
	usage     *ChatUsage
	retries   int
	retrying  bool
	lastError string
	lastSave  time.Time
	lossy     bool
}

type codexPartRef struct{ messageID, partID string }

var (
	errCodexChoice    = errors.New("this choice is not offered for the request")
	errCodexNotSent   = errors.New("codex did not receive the message")
	errCodexUncertain = errors.New("codex may have received the message")
)

// codexSend is what a delivery needs besides the turn.
type codexSend struct {
	text        string
	attachments []ChatAttachment
	directory   string
}

func (e *codexEngine) hubLocked() *chatHub { return e.hub }

// prompt starts one turn. It records the user message and returns; delivery
// and streaming run in the background. finished runs once after the turn
// ends when prompt returned nil.
func (e *codexEngine) prompt(project Project, id, messageID, text string, options PromptOptions, attachments []ChatAttachment, finished func()) error {
	// Codex runs only in workspaces: the Chats space's chats are read-only.
	if project.ID == plainChatsProjectID {
		return errChatsSpaceRetired
	}
	c := e.chats
	c.mu.Lock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		c.mu.Unlock()
		return err
	}
	if c.closed {
		c.mu.Unlock()
		return ErrCLIChatUnavailable
	}
	if record.Busy {
		c.mu.Unlock()
		return ErrCLIChatBusy
	}
	settings, ok := record.codexSettings().with(options)
	if !ok {
		c.mu.Unlock()
		return ErrCLIChatUnavailable
	}
	if !e.begin() {
		c.mu.Unlock()
		return ErrCLIChatUnavailable
	}
	previousMessages := append([]Message(nil), record.Messages...)
	previousCodex := cloneCodexRecord(record.Codex)
	previousCreated := cloneCreated(record.Created)
	codex := record.codex()
	previousSettings := record.codexSettings()
	rebuild := false
	if codex.Rewind != "" {
		// Sending replaces the rewound messages: they go now, and Codex drops
		// their turn before the new one starts.
		for index, message := range record.Messages {
			if message.ID != codex.Rewind {
				continue
			}
			codex.PendingRevert = codex.Turns[codex.Rewind]
			for _, dropped := range record.Messages[index:] {
				delete(codex.Unified, dropped.ID)
				delete(codex.Turns, dropped.ID)
				delete(record.Created, dropped.ID)
			}
			record.Messages = record.Messages[:index]
			break
		}
		codex.Rewind = ""
		rebuild = true
	}
	codex.Model, codex.Mode, codex.Effort = settings.model, settings.mode, settings.effort
	now := time.Now()
	user := Message{ID: messageID, Role: "user", Text: text}
	for _, attachment := range attachments {
		user.Attachments = append(user.Attachments, AttachmentInfo{Name: attachment.Name, MIME: attachment.MIME})
	}
	record.Messages = append(record.Messages, user)
	record.Busy = true
	record.UpdatedAt = now
	record.setCreated(user.ID, now)
	if err := c.saveLocked(); err != nil {
		record.Messages, record.Codex, record.Created, record.Busy = previousMessages, previousCodex, previousCreated, false
		c.mu.Unlock()
		e.work.Done()
		return err
	}
	turn := &codexTurn{key: sessionKey{project.ID, id}, sessionID: id, userID: messageID, settings: settings, finished: finished, parts: map[string]codexPartRef{}, reasoning: map[string]string{}, lastSave: now}
	e.turns[id] = turn
	e.hold()
	hub := e.hubLocked()
	if rebuild {
		hub.codexRebuild(turn.key)
	} else {
		hub.codexMessage(turn.key, chatMessageFromLegacy(user, "codex", id, user.ID, int64(len(record.Messages)), now))
	}
	if settings != previousSettings {
		hub.codexInfo(turn.key, settings.modelID(), settings.mode, settings.effort)
	}
	hub.codexState(turn.key, "busy", nil)
	send := codexSend{text: text, attachments: attachments, directory: record.Directory}
	c.mu.Unlock()
	go e.deliver(turn, send)
	return nil
}

func cloneCodexRecord(record *codexChatRecord) *codexChatRecord {
	if record == nil {
		return nil
	}
	copied := *record
	copied.Unified = make(map[string]*ChatMessage, len(record.Unified))
	for id, message := range record.Unified {
		clone := cloneChatMessage(*message)
		copied.Unified[id] = &clone
	}
	copied.Turns = make(map[string]string, len(record.Turns))
	for id, turn := range record.Turns {
		copied.Turns[id] = turn
	}
	if record.TokenTotal != nil {
		total := *record.TokenTotal
		copied.TokenTotal = &total
	}
	return &copied
}

func cloneCreated(created map[string]time.Time) map[string]time.Time {
	if created == nil {
		return nil
	}
	copied := make(map[string]time.Time, len(created))
	for id, at := range created {
		copied[id] = at
	}
	return copied
}

// deliver sends the turn through the app-server, or through codex exec when
// the app-server cannot start.
func (e *codexEngine) deliver(turn *codexTurn, send codexSend) {
	defer e.work.Done()
	if e.config.execOnly {
		e.runExec(turn, send)
		return
	}
	conn, err := e.connection()
	switch {
	case errors.Is(err, errCodexHandshake):
		e.runExec(turn, send)
	case err != nil:
		e.endTurn(turn, "rejected", codexFailure(errCodexNotSent, err))
	default:
		e.runAppServer(conn, turn, send)
	}
}

// codexFailure is the reply error of a turn that could not run.
func codexFailure(kind, cause error) *ChatError {
	reason := ""
	var rpc *codexRPCError
	if errors.As(cause, &rpc) {
		reason, _ = clipText(rpc.Message, chatShortLimit)
	}
	switch {
	case errors.Is(kind, errCodexUncertain):
		return &ChatError{Code: "delivery_uncertain", Message: "Codex stopped before confirming it received this message. Check the chat before sending it again."}
	case reason != "":
		return &ChatError{Code: "agent_error", Message: "Codex did not accept this message: " + reason}
	default:
		return &ChatError{Code: "agent_error", Message: "Codex did not accept this message. Check that Codex works on the Mac."}
	}
}

// runAppServer loads the chat's thread (thread/start or thread/resume),
// removes a rewound turn (thread/revert) and starts the turn. The turn/start
// result or turn/started confirms delivery; an answer that never came after
// the request was written leaves it uncertain, and it is never resent.
func (e *codexEngine) runAppServer(conn *codexConn, turn *codexTurn, send codexSend) {
	c := e.chats
	ctx, cancel := context.WithTimeout(context.Background(), e.config.duration(e.config.callTimeout, 30*time.Second))
	defer cancel()
	c.mu.Lock()
	record := c.records[turn.sessionID]
	if record == nil || turn.done {
		c.mu.Unlock()
		return
	}
	threadID, pendingRevert := record.NativeID, record.codex().PendingRevert
	turn.transport, turn.conn = "app-server", conn
	c.mu.Unlock()
	mode := turn.settings.modeSpec()

	threadID, err := e.loadThread(ctx, conn, turn, threadID, send.directory)
	if err != nil {
		e.endTurn(turn, "rejected", codexFailure(errCodexNotSent, err))
		return
	}
	notice := ""
	if pendingRevert != "" {
		err := conn.call(ctx, "thread/revert", codexParams{"threadId": threadID, "beforeTurnId": pendingRevert}, nil)
		e.noteMissing("thread/revert", err)
		var rpc *codexRPCError
		switch {
		case err == nil:
		case errors.As(err, &rpc) && rpc.methodMissing():
			notice = "Codex could not remove the edited message from its own history; it may still see it."
		default:
			e.endTurn(turn, "rejected", codexFailure(errCodexNotSent, err))
			return
		}
		c.mu.Lock()
		if record := c.records[turn.sessionID]; record != nil {
			record.codex().PendingRevert = ""
			_ = c.saveLocked()
		}
		c.mu.Unlock()
	}
	params := codexParams{"threadId": threadID, "input": codexInput(send.text, send.attachments), "clientUserMessageId": turn.userID}
	if turn.settings.model != "" {
		params["model"] = turn.settings.model
	}
	if turn.settings.effort != "" {
		params["effort"] = turn.settings.effort
	}
	if loaded, _ := conn.loadedMode(threadID); loaded != mode.id {
		// The mode changed since the thread was loaded: override it for this
		// and later turns.
		params["approvalPolicy"], params["approvalsReviewer"] = mode.approval, mode.reviewer
		params["sandboxPolicy"] = map[string]any{"type": mode.sandboxPolicy}
	}
	var result struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	for attempt := 0; ; attempt++ {
		err = conn.call(ctx, "turn/start", params, &result)
		var rpc *codexRPCError
		if attempt > 0 || !errors.As(err, &rpc) || !strings.Contains(rpc.Message, "thread not found") {
			break
		}
		// Codex no longer has the thread loaded. It refused the turn, so
		// nothing ran: load the thread again and start the turn once more.
		conn.unmarkLoaded(threadID)
		if _, err = e.loadThread(ctx, conn, turn, threadID, send.directory); err != nil {
			break
		}
	}
	e.noteMissing("turn/start", err)
	if err != nil {
		var call *codexCallError
		if errors.As(err, &call) && call.sent {
			e.endTurn(turn, "lost", codexFailure(errCodexUncertain, err))
		} else {
			e.endTurn(turn, "rejected", codexFailure(errCodexNotSent, err))
		}
		return
	}
	conn.markLoaded(threadID, mode.id)
	c.mu.Lock()
	record = c.records[turn.sessionID]
	if record != nil && !turn.done {
		e.adoptTurnLocked(record, turn, result.Turn.ID)
		turn.delivered = true
		if notice != "" {
			e.noticeLocked(record, turn, "revert", notice)
		}
	}
	interrupt := turn.interrupt && !turn.done && turn.turnID != ""
	lost := !turn.done && conn.exited()
	var finished func()
	if lost {
		finished = e.finishLocked(record, turn, "lost", nil)
	}
	turnID := turn.turnID
	c.mu.Unlock()
	if finished != nil {
		finished()
	}
	if interrupt {
		_ = conn.call(ctx, "turn/interrupt", codexParams{"threadId": threadID, "turnId": turnID}, nil)
	}
}

// codexInput is turn/start's input: the text (naming attachments Codex
// reads with its tools) and each image as a local image.
func codexInput(text string, attachments []ChatAttachment) []map[string]any {
	images := []ChatAttachment{}
	listed := []ChatAttachment{}
	for _, attachment := range attachments {
		if strings.HasPrefix(attachment.MIME, "image/") {
			images = append(images, attachment)
		} else {
			listed = append(listed, attachment)
		}
	}
	input := []map[string]any{}
	if text := codexPromptText(text, listed, len(images) > 0); text != "" {
		input = append(input, map[string]any{"type": "text", "text": text})
	}
	for _, image := range images {
		input = append(input, map[string]any{"type": "localImage", "path": image.Path})
	}
	return input
}

// codexPromptText adds the host paths of attachments Codex reads with its
// own tools, as one-shot runs did.
func codexPromptText(text string, listed []ChatAttachment, images bool) string {
	if len(listed) > 0 {
		if text != "" {
			text += "\n\n"
		}
		text += "Attached files (read them with your tools):"
		for _, attachment := range listed {
			text += "\n- " + attachment.Path + " (" + attachment.Name + ")"
		}
	}
	if text == "" && images {
		text = "See the attached images."
	}
	return text
}

// loadThread makes the chat's thread loaded in this app-server: a new chat
// starts one; a chat whose thread this process has not loaded resumes it.
func (e *codexEngine) loadThread(ctx context.Context, conn *codexConn, turn *codexTurn, threadID, directory string) (string, error) {
	c := e.chats
	mode := turn.settings.modeSpec()
	if threadID != "" {
		c.mu.Lock()
		e.threads[threadID] = turn.key
		turn.threadID = threadID
		c.mu.Unlock()
		if _, loaded := conn.loadedMode(threadID); loaded {
			return threadID, nil
		}
		e.makeRoom(ctx, conn)
		params := codexModeParams(codexParams{"threadId": threadID, "excludeTurns": true, "cwd": directory}, mode)
		if turn.settings.model != "" {
			params["model"] = turn.settings.model
		}
		if err := conn.call(ctx, "thread/resume", params, nil); err != nil {
			e.noteMissing("thread/resume", err)
			return "", err
		}
		conn.markLoaded(threadID, mode.id)
		return threadID, nil
	}
	e.makeRoom(ctx, conn)
	params := codexModeParams(codexParams{"cwd": directory}, mode)
	if turn.settings.model != "" {
		params["model"] = turn.settings.model
	}
	var result struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	if err := conn.call(ctx, "thread/start", params, &result); err != nil {
		e.noteMissing("thread/start", err)
		return "", err
	}
	if result.Thread.ID == "" {
		return "", &codexRPCError{Code: -32603, Message: "thread/start returned no thread"}
	}
	conn.markLoaded(result.Thread.ID, mode.id)
	c.mu.Lock()
	if record := c.records[turn.sessionID]; record != nil {
		record.NativeID = result.Thread.ID
		_ = c.saveLocked()
	}
	e.threads[result.Thread.ID] = turn.key
	turn.threadID = result.Thread.ID
	c.mu.Unlock()
	return result.Thread.ID, nil
}

// adoptTurnLocked learns the Codex turn ID and remembers it for rewinds.
func (e *codexEngine) adoptTurnLocked(record *cliChatRecord, turn *codexTurn, turnID string) {
	if turnID == "" || turn.turnID != "" {
		return
	}
	turn.turnID = turnID
	codex := record.codex()
	if codex.Turns == nil {
		codex.Turns = map[string]string{}
	}
	codex.Turns[turn.userID] = turnID
}

// endTurn finishes a turn from outside the notification path.
func (e *codexEngine) endTurn(turn *codexTurn, outcome string, failure *ChatError) {
	c := e.chats
	c.mu.Lock()
	finished := e.finishLocked(c.records[turn.sessionID], turn, outcome, failure)
	c.mu.Unlock()
	if finished != nil {
		finished()
	}
}

// assistantLocked returns the message the turn's items go to: created on
// the first item, continued in a new message once one holds
// chatPartsPerMessage parts.
func (e *codexEngine) assistantLocked(record *cliChatRecord, turn *codexTurn) *ChatMessage {
	codex := record.codex()
	if turn.assistant != "" {
		if message := codex.Unified[turn.assistant]; message != nil && len(message.Parts) < chatPartsPerMessage {
			return message
		}
	}
	now := time.Now()
	id := cliMessageID()
	record.Messages = append(record.Messages, Message{ID: id, Role: "assistant"})
	record.setCreated(id, now)
	message := &ChatMessage{ID: id, ChatID: turn.sessionID, TurnID: turn.userID, Role: "assistant", Status: "streaming", Ord: int64(len(record.Messages)), CreatedAt: chatTimeOf(now), Provider: "codex", Model: turn.settings.modelID(), Parts: []ChatPart{}, createdMs: now.UnixMilli()}
	if codex.Unified == nil {
		codex.Unified = map[string]*ChatMessage{}
	}
	codex.Unified[id] = message
	turn.messages = append(turn.messages, id)
	turn.assistant = id
	e.hubLocked().codexMessage(turn.key, cloneChatMessage(*message))
	return message
}

func (e *codexEngine) findPartLocked(record *cliChatRecord, turn *codexTurn, itemID string) (*ChatMessage, int) {
	ref, ok := turn.parts[itemID]
	if !ok {
		return nil, -1
	}
	message := record.codex().Unified[ref.messageID]
	if message == nil {
		return nil, -1
	}
	for index := range message.Parts {
		if message.Parts[index].ID == ref.partID {
			return message, index
		}
	}
	return nil, -1
}

// addPartLocked appends a part for a Codex item to the current assistant
// message; parts keep the order Codex emitted their items in.
func (e *codexEngine) addPartLocked(record *cliChatRecord, turn *codexTurn, itemID string, part ChatPart) (*ChatMessage, int) {
	message := e.assistantLocked(record, turn)
	part.ID = message.ID + ":" + itemID
	part.Ord = int64(len(message.Parts) + 1)
	message.Parts = append(message.Parts, part)
	turn.parts[itemID] = codexPartRef{message.ID, part.ID}
	e.hubLocked().codexPart(turn.key, message.ID, clonePart(part))
	return message, len(message.Parts) - 1
}

// codexChatPart applies the conversation model's size bounds to an item's
// part.
func codexChatPart(spec codexPartSpec) ChatPart {
	part := ChatPart{Kind: spec.kind}
	switch spec.kind {
	case "text":
		part.Text, part.Truncated = clipText(spec.text, chatTextLimit)
	case "reasoning":
		part.Text, part.Truncated = clipText(spec.text, chatReasoningLimit)
	case "notice":
		part.Text, _ = clipText(spec.text, 4<<10)
	case "tool":
		tool := *spec.tool
		var inputCut, outputCut, errorCut bool
		tool.Input, inputCut = boundedToolText(tool.Input)
		tool.Output, outputCut = boundedToolText(tool.Output)
		tool.Error, errorCut = boundedToolText(tool.Error)
		tool.Title, _ = clipText(tool.Title, chatShortLimit)
		tool.Truncated = tool.Truncated || inputCut || outputCut || errorCut
		part.Tool = &tool
	}
	return part
}

// itemLocked applies a started, updated or completed item. A completed item
// replaces what streamed, keeping streamed output Codex does not repeat.
func (e *codexEngine) itemLocked(record *cliChatRecord, turn *codexTurn, item codexItem, at time.Time, completed bool) {
	item.normalize()
	if item.Type == "userMessage" || item.ID == "" {
		return
	}
	spec, ok := codexPart(item)
	if !ok {
		return
	}
	if item.Type == "todoList" {
		turn.plan = item.ID
	}
	part := codexChatPart(spec)
	if completed && part.Tool != nil && (part.Tool.Status == "running" || part.Tool.Status == "pending") {
		part.Tool.Status = "completed"
	}
	message, index := e.findPartLocked(record, turn, item.ID)
	if message == nil {
		part.Start = chatTimeOf(at)
		if completed {
			part.End = chatTimeOf(at)
		}
		message, index = e.addPartLocked(record, turn, item.ID, part)
	} else {
		existing := &message.Parts[index]
		part.ID, part.Ord, part.Start = existing.ID, existing.Ord, existing.Start
		if completed {
			part.End = chatTimeOf(at)
		}
		if part.Tool != nil && existing.Tool != nil && part.Tool.Output == "" && existing.Tool.Output != "" {
			part.Tool.Output = existing.Tool.Output
			part.Tool.Truncated = part.Tool.Truncated || existing.Tool.Truncated
		}
		if (part.Kind == "text" || part.Kind == "reasoning") && part.Text == "" && existing.Text != "" {
			part.Text, part.Truncated = existing.Text, existing.Truncated
		}
		if !reflect.DeepEqual(*existing, part) {
			*existing = part
			e.hubLocked().codexPart(turn.key, message.ID, clonePart(part))
		}
	}
	if completed && len(spec.patch) > 0 {
		patch := ChatPart{Kind: "patch", Text: patchFileList(spec.patch, record.Directory), Start: chatTimeOf(at), End: chatTimeOf(at)}
		if found, _ := e.findPartLocked(record, turn, item.ID+":patch"); found == nil {
			e.addPartLocked(record, turn, item.ID+":patch", patch)
		}
	}
	if completed {
		e.refreshLegacyLocked(record, message)
		e.saveSoonLocked(turn)
	}
}

// deltaLocked appends streamed text to an item's text or tool output.
func (e *codexEngine) deltaLocked(record *cliChatRecord, turn *codexTurn, itemID, kind, delta string) {
	if delta == "" {
		return
	}
	message, index := e.findPartLocked(record, turn, itemID)
	if message == nil {
		part := ChatPart{Kind: kind}
		if kind == "tool" {
			part.Tool = &ChatTool{Name: "Command", CallID: itemID, Status: "running"}
		}
		message, index = e.addPartLocked(record, turn, itemID, part)
	}
	part := &message.Parts[index]
	field, value, limit, truncated := "text", &part.Text, chatTextLimit, &part.Truncated
	switch {
	case part.Kind == "reasoning":
		limit = chatReasoningLimit
	case part.Kind == "tool" && part.Tool != nil:
		field, value, limit, truncated = "output", &part.Tool.Output, chatToolFieldLimit, &part.Tool.Truncated
	case part.Kind != "text":
		return
	}
	offset := len(*value)
	if *truncated && offset >= limit {
		return
	}
	accepted, cut := "", true
	if offset < limit {
		accepted, cut = clipText(delta, limit-offset)
	}
	hub := e.hubLocked()
	if accepted != "" {
		*value += accepted
		hub.codexDelta(turn.key, message.ID, part.ID, field, offset, accepted)
	}
	if cut && !*truncated {
		*truncated = true
		hub.codexPart(turn.key, message.ID, clonePart(*part))
	}
}

// noticeLocked adds a notice part once per key.
func (e *codexEngine) noticeLocked(record *cliChatRecord, turn *codexTurn, key, text string) {
	if text == "" {
		return
	}
	if message, _ := e.findPartLocked(record, turn, "notice-"+key); message != nil {
		return
	}
	part := codexChatPart(codexPartSpec{kind: "notice", text: text})
	part.Start = chatTimeOf(time.Now())
	e.addPartLocked(record, turn, "notice-"+key, part)
}

// planLocked shows Codex's plan as one checklist per turn.
func (e *codexEngine) planLocked(record *cliChatRecord, turn *codexTurn, explanation string, steps []codexPlanStep) {
	if turn.plan == "" {
		turn.plan = "plan"
	}
	tool := codexPlanTool(explanation, steps, turn.plan)
	part := codexChatPart(codexPartSpec{kind: "tool", tool: tool})
	message, index := e.findPartLocked(record, turn, turn.plan)
	if message == nil {
		part.Start = chatTimeOf(time.Now())
		e.addPartLocked(record, turn, turn.plan, part)
		return
	}
	existing := &message.Parts[index]
	part.ID, part.Ord, part.Start = existing.ID, existing.Ord, existing.Start
	if !reflect.DeepEqual(*existing, part) {
		*existing = part
		e.hubLocked().codexPart(turn.key, message.ID, clonePart(part))
	}
}

// usageLocked records the turn's token use: the thread total now, less the
// total before the turn's first model call.
func (e *codexEngine) usageLocked(record *cliChatRecord, turn *codexTurn, total, last codexTokens) {
	if turn.usageBase == nil {
		base := total.minus(last)
		turn.usageBase = &base
	}
	turn.usage = total.minus(*turn.usageBase).usage()
	record.codex().TokenTotal = &total
	if len(turn.messages) == 0 {
		return
	}
	// Usage shows on the turn's first reply message only, so sums stay right.
	if message := record.codex().Unified[turn.messages[0]]; message != nil {
		usage := *turn.usage
		message.Usage = &usage
		e.hubLocked().codexHeader(turn.key, cloneChatMessage(*message))
	}
}

func (e *codexEngine) refreshLegacyLocked(record *cliChatRecord, message *ChatMessage) {
	for index := len(record.Messages) - 1; index >= 0; index-- {
		if record.Messages[index].ID == message.ID {
			record.Messages[index] = codexLegacy(message)
			return
		}
	}
}

// saveSoonLocked writes the record at most every couple of seconds while a
// turn streams; the end of the turn always writes it.
func (e *codexEngine) saveSoonLocked(turn *codexTurn) {
	if time.Since(turn.lastSave) < e.config.duration(e.config.saveEvery, 2*time.Second) {
		return
	}
	turn.lastSave = time.Now()
	_ = e.chats.saveLocked()
}

// finishLocked ends a turn once: its replies get their final status, open
// tools stop, pending requests resolve as gone and the chat is idle again.
// It returns the turn's finished callback for the caller to run unlocked.
func (e *codexEngine) finishLocked(record *cliChatRecord, turn *codexTurn, outcome string, failure *ChatError) func() {
	if turn.done {
		return nil
	}
	turn.done = true
	if e.turns[turn.sessionID] == turn {
		delete(e.turns, turn.sessionID)
	}
	defer e.release()
	hub := e.hubLocked()
	for id, pending := range e.requests {
		if pending.key == turn.key {
			delete(e.requests, id)
			hub.codexResolved(turn.key, id, "gone")
		}
	}
	if record == nil {
		return turn.finished
	}
	if failure == nil && outcome == "failed" {
		message := turn.lastError
		if message == "" {
			message = "Codex could not complete this request."
		}
		failure = &ChatError{Code: "agent_error", Message: message}
	}
	if failure == nil && outcome == "lost" {
		failure = &ChatError{Code: "agent_error", Message: "Codex stopped before this reply completed."}
	}
	if turn.lossy {
		e.noticeLocked(record, turn, "oversized", "Some of Codex's output was too large to show.")
	}
	if len(turn.messages) == 0 && (failure != nil || outcome == "interrupted") {
		e.assistantLocked(record, turn)
	}
	status := "complete"
	switch {
	case outcome == "interrupted":
		status = "aborted"
	case failure != nil:
		status = "error"
	}
	now := time.Now()
	codex := record.codex()
	for position, id := range turn.messages {
		message := codex.Unified[id]
		if message == nil {
			continue
		}
		message.Status, message.CompletedAt = status, chatTimeOf(now)
		if position == len(turn.messages)-1 && failure != nil {
			failed := *failure
			failed.Message, _ = clipText(failed.Message, chatErrorLimit)
			message.Error = &failed
		}
		if position == 0 && turn.usage != nil {
			usage := *turn.usage
			message.Usage = &usage
		}
		for index := range message.Parts {
			tool := message.Parts[index].Tool
			if tool == nil || (tool.Status != "running" && tool.Status != "pending") {
				continue
			}
			if tool.Name == "Plan" && status == "complete" {
				tool.Status = "completed"
			} else {
				tool.Status, tool.Error = "error", "Stopped before it finished."
			}
			if message.Parts[index].End == "" {
				message.Parts[index].End = chatTimeOf(now)
			}
		}
		e.refreshLegacyLocked(record, message)
		hub.codexMessage(turn.key, cloneChatMessage(*message))
	}
	record.Busy = false
	record.UpdatedAt = now
	_ = e.chats.saveLocked()
	hub.codexState(turn.key, "idle", nil)
	return turn.finished
}

// connectionLost ends the turns and requests that lived in a process that
// exited. A turn whose turn/start is still waiting ends when that call fails.
func (e *codexEngine) connectionLost(conn *codexConn) {
	c := e.chats
	c.mu.Lock()
	hub := e.hubLocked()
	for id, pending := range e.requests {
		if pending.conn == conn {
			delete(e.requests, id)
			hub.codexResolved(pending.key, id, "gone")
		}
	}
	callbacks := []func(){}
	for _, turn := range e.turns {
		if turn.conn != conn || !turn.delivered || turn.done {
			continue
		}
		outcome := "lost"
		if turn.interrupt {
			outcome = "interrupted"
		}
		if finished := e.finishLocked(c.records[turn.sessionID], turn, outcome, nil); finished != nil {
			callbacks = append(callbacks, finished)
		}
	}
	c.mu.Unlock()
	for _, finished := range callbacks {
		finished()
	}
}

// codexEvent holds the params of every notification the engine reads.
type codexEvent struct {
	ThreadID      string          `json:"threadId"`
	TurnID        string          `json:"turnId"`
	ItemID        string          `json:"itemId"`
	Delta         string          `json:"delta"`
	SummaryIndex  int64           `json:"summaryIndex"`
	Item          json.RawMessage `json:"item"`
	StartedAtMs   int64           `json:"startedAtMs"`
	CompletedAtMs int64           `json:"completedAtMs"`
	Turn          *struct {
		ID     string          `json:"id"`
		Status string          `json:"status"`
		Error  *codexTurnError `json:"error"`
	} `json:"turn"`
	TokenUsage *struct {
		Total codexTokens `json:"total"`
		Last  codexTokens `json:"last"`
	} `json:"tokenUsage"`
	Error       *codexTurnError   `json:"error"`
	WillRetry   bool              `json:"willRetry"`
	RequestID   json.RawMessage   `json:"requestId"`
	Changes     []codexFileChange `json:"changes"`
	Explanation string            `json:"explanation"`
	Plan        []codexPlanStep   `json:"plan"`
	Message     string            `json:"message"`
	Review      *struct {
		Status    string `json:"status"`
		Rationale string `json:"rationale"`
	} `json:"review"`
	Action *struct {
		Command string `json:"command"`
	} `json:"action"`
}

type codexTurnError struct {
	Message        string          `json:"message"`
	CodexErrorInfo json.RawMessage `json:"codexErrorInfo"`
}

func codexMillis(ms int64) time.Time {
	if ms <= 0 {
		return time.Now()
	}
	return time.UnixMilli(ms)
}

// turnForLocked finds the running turn a notification belongs to. When
// turn/started arrives before turn/start's answer, it tells the engine the
// turn's ID; notifications that name any other turn are stale and ignored.
func (e *codexEngine) turnForLocked(conn *codexConn, threadID, turnID string, started bool) (*codexTurn, *cliChatRecord) {
	key, ok := e.threads[threadID]
	if !ok {
		return nil, nil
	}
	turn := e.turns[key.sessionID]
	if turn == nil || turn.done || turn.conn != conn || turn.threadID != threadID {
		return nil, nil
	}
	record := e.chats.records[turn.sessionID]
	if record == nil {
		return nil, nil
	}
	if turnID != "" {
		if turn.turnID == "" && started {
			e.adoptTurnLocked(record, turn, turnID)
		}
		if turn.turnID != turnID {
			return nil, nil
		}
	}
	return turn, record
}

// codexNotification applies one app-server notification. Unknown methods
// and items are ignored in every mode.
func (e *codexEngine) codexNotification(conn *codexConn, method string, params json.RawMessage) {
	e.touch()
	switch method {
	case "turn/started", "turn/completed", "item/started", "item/completed", "item/agentMessage/delta",
		"item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded", "item/reasoning/textDelta",
		"item/commandExecution/outputDelta", "item/fileChange/outputDelta", "item/fileChange/patchUpdated",
		"turn/plan/updated", "thread/tokenUsage/updated", "error", "serverRequest/resolved",
		"item/autoApprovalReview/completed", "warning", "thread/closed":
	default:
		return
	}
	var event codexEvent
	if json.Unmarshal(params, &event) != nil {
		return
	}
	if event.Turn != nil && event.TurnID == "" {
		event.TurnID = event.Turn.ID
	}
	c := e.chats
	c.mu.Lock()
	var finished func()
	switch method {
	case "thread/closed":
		conn.unmarkLoaded(event.ThreadID)
	case "serverRequest/resolved":
		for id, pending := range e.requests {
			if pending.conn == conn && string(pending.rpcID) == string(event.RequestID) {
				delete(e.requests, id)
				e.hubLocked().codexResolved(pending.key, id, "gone")
			}
		}
	default:
		turn, record := e.turnForLocked(conn, event.ThreadID, event.TurnID, method == "turn/started")
		if turn != nil {
			finished = e.applyLocked(record, turn, method, event)
		}
	}
	c.mu.Unlock()
	if finished != nil {
		finished()
	}
}

func (e *codexEngine) applyLocked(record *cliChatRecord, turn *codexTurn, method string, event codexEvent) func() {
	if turn.retrying && method != "error" && method != "turn/completed" {
		turn.retrying = false
		e.hubLocked().codexState(turn.key, "busy", nil)
	}
	switch method {
	case "turn/started":
		turn.delivered = true
	case "item/started", "item/completed":
		turn.delivered = true
		var item codexItem
		if json.Unmarshal(event.Item, &item) == nil {
			if method == "item/started" {
				e.itemLocked(record, turn, item, codexMillis(event.StartedAtMs), false)
			} else {
				e.itemLocked(record, turn, item, codexMillis(event.CompletedAtMs), true)
			}
		}
	case "item/agentMessage/delta":
		e.deltaLocked(record, turn, event.ItemID, "text", event.Delta)
	case "item/reasoning/summaryPartAdded":
		if turn.reasoning[event.ItemID] == "" {
			turn.reasoning[event.ItemID] = "summary"
		}
		if message, index := e.findPartLocked(record, turn, event.ItemID); message != nil && event.SummaryIndex > 0 && message.Parts[index].Text != "" {
			e.deltaLocked(record, turn, event.ItemID, "reasoning", "\n\n")
		}
	case "item/reasoning/summaryTextDelta":
		if turn.reasoning[event.ItemID] == "" {
			turn.reasoning[event.ItemID] = "summary"
		}
		if turn.reasoning[event.ItemID] == "summary" {
			e.deltaLocked(record, turn, event.ItemID, "reasoning", event.Delta)
		}
	case "item/reasoning/textDelta":
		if turn.reasoning[event.ItemID] == "" {
			turn.reasoning[event.ItemID] = "content"
		}
		if turn.reasoning[event.ItemID] == "content" {
			e.deltaLocked(record, turn, event.ItemID, "reasoning", event.Delta)
		}
	case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
		e.deltaLocked(record, turn, event.ItemID, "tool", event.Delta)
	case "item/fileChange/patchUpdated":
		if message, index := e.findPartLocked(record, turn, event.ItemID); message != nil && message.Parts[index].Tool != nil {
			spec := codexFileChangePart(codexItem{Type: "fileChange", ID: event.ItemID, Status: "inProgress", Changes: event.Changes})
			part := codexChatPart(spec)
			existing := &message.Parts[index]
			part.ID, part.Ord, part.Start = existing.ID, existing.Ord, existing.Start
			part.Tool.Status = existing.Tool.Status
			if !reflect.DeepEqual(*existing, part) {
				*existing = part
				e.hubLocked().codexPart(turn.key, message.ID, clonePart(part))
			}
		}
	case "turn/plan/updated":
		e.planLocked(record, turn, event.Explanation, event.Plan)
	case "thread/tokenUsage/updated":
		if event.TokenUsage != nil {
			e.usageLocked(record, turn, event.TokenUsage.Total, event.TokenUsage.Last)
		}
	case "error":
		if event.Error == nil {
			break
		}
		message, _ := clipText(strings.TrimSpace(event.Error.Message), chatShortLimit)
		if event.WillRetry {
			turn.retries++
			turn.retrying = true
			e.hubLocked().codexState(turn.key, "retry", &ChatRetry{Attempt: turn.retries, Message: message})
		} else {
			turn.lastError = message
		}
	case "item/autoApprovalReview/completed":
		if event.Review == nil {
			break
		}
		action := ""
		if event.Action != nil && event.Action.Command != "" {
			action = ": " + event.Action.Command
		}
		text := ""
		switch event.Review.Status {
		case "approved":
			text = "Auto-review allowed" + action
		case "denied":
			text = "Auto-review denied" + action
		case "timedOut":
			text = "Auto-review timed out" + action
		}
		if text != "" && event.Review.Rationale != "" {
			text += "\n" + event.Review.Rationale
		}
		e.noticeLocked(record, turn, "review-"+cliMessageID()[:8], text)
	case "warning":
		if event.Message != "" {
			e.noticeLocked(record, turn, "warning-"+cliMessageID()[:8], event.Message)
		}
	case "turn/completed":
		if event.Turn == nil {
			break
		}
		outcome := "completed"
		var failure *ChatError
		switch event.Turn.Status {
		case "interrupted":
			outcome = "interrupted"
		case "failed":
			outcome = "failed"
			if event.Turn.Error != nil && strings.TrimSpace(event.Turn.Error.Message) != "" {
				failure = &ChatError{Code: codexErrorCode(event.Turn.Error.CodexErrorInfo), Message: strings.TrimSpace(event.Turn.Error.Message)}
			}
		}
		return e.finishLocked(record, turn, outcome, failure)
	}
	return nil
}

// codexOversized learns that a line was too long to read: the running turns
// of that process may miss an update and say so when they end.
func (e *codexEngine) codexOversized(conn *codexConn, _ int) {
	c := e.chats
	c.mu.Lock()
	for _, turn := range e.turns {
		if turn.conn == conn {
			turn.lossy = true
		}
	}
	c.mu.Unlock()
}
