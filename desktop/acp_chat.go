package host

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// One ACP chat: its transcript in the unified model and the process serving
// it (docs/HOST-API.md "ACP chats"). A send records the user message and
// answers at once; the turn then runs on its own goroutine, which starts the
// process and the session when needed and ends with the answer to
// session/prompt. Lock order: mu, then the chat hub's lock and the
// registry's. Nothing waits on the process while holding mu, because the
// process's reader needs mu to deliver what it waits for.

// acpTurn is the turn in progress.
type acpTurn struct {
	id          string // the user message's ID
	interrupted bool   // the user stopped it
	// prompted is set once session/prompt is written: Stop's session/cancel
	// goes after it, never before, where the agent would ignore it.
	prompted bool
	finished func()
	done     chan struct{}
	// reply is the assistant message streaming now; lastKind and lastPart the
	// part text chunks go on ("" starts a new one).
	reply    string
	lastKind string
	lastPart string
	tools    map[string]*acpToolState // by toolCallId
	plan     string                   // the plan's part ID
	notice   string                   // a notice the reply starts with
}

// acpToolState is what the host knows of one tool call across its updates.
type acpToolState struct {
	message, part string
	hasInput      bool
	hasContent    bool
}

// acpAsk is one pending session/request_permission.
type acpAsk struct {
	id          string
	rpcID       json.RawMessage
	conn        *acpConn
	interaction ChatInteraction
	options     map[string]string // choice → optionId ("" answers cancelled)
	toolCallID  string
}

type acpChat struct {
	engine  *acpEngine
	key     sessionKey
	project Project
	id      string
	agent   string

	mu        sync.Mutex
	rec       acpChatRecord
	nextOrd   int64
	conn      *acpConn
	caps      acpAgentCaps
	session   string // the ACP session conn serves ("" until made or loaded)
	loading   bool   // session/load is replaying: its updates are not shown
	turn      *acpTurn
	asks      []*acpAsk
	used      time.Time
	idleTimer *time.Timer
	closed    bool
}

func newACPChat(engine *acpEngine, project Project, id string, entry acpEntry) *acpChat {
	c := &acpChat{engine: engine, key: sessionKey{project.ID, id}, project: project, id: id, agent: entry.state.Agent, rec: entry.state, used: time.Now()}
	if c.agent == "" {
		c.agent = entry.session.Provider
		c.rec.Agent = c.agent
	}
	for _, message := range c.rec.Messages {
		c.nextOrd = max(c.nextOrd, message.Ord)
	}
	c.nextOrd++
	if c.rec.Running != "" {
		c.recoverLocked()
	}
	return c
}

// recoverLocked finishes a turn the host stopped in the middle of.
func (c *acpChat) recoverLocked() {
	failure := &ChatError{Code: "agent_exited", Message: "AgentLand stopped before this reply completed."}
	found := false
	now := chatTimeOf(time.Now())
	for index := range c.rec.Messages {
		message := &c.rec.Messages[index]
		if message.Role != "assistant" || message.TurnID != c.rec.Running || message.Status != "streaming" {
			continue
		}
		message.Status, message.Error, message.CompletedAt = "error", failure, now
		found = true
	}
	if !found {
		message := c.newReplyLocked(c.rec.Running, "error", time.Now())
		message.Error = failure
		c.rec.Messages = append(c.rec.Messages, message)
	}
	c.rec.Running = ""
	c.persistLocked()
}

func (c *acpChat) takeOrdLocked() int64 {
	ord := c.nextOrd
	c.nextOrd++
	return ord
}

func (c *acpChat) model() string { return c.agent + "/default" }

func (c *acpChat) newReplyLocked(turn, status string, now time.Time) ChatMessage {
	message := ChatMessage{ID: cliMessageID(), ChatID: c.id, TurnID: turn, Role: "assistant", Status: status, Ord: c.takeOrdLocked(), CreatedAt: chatTimeOf(now), Provider: c.agent, Model: c.model(), Parts: []ChatPart{}, createdMs: now.UnixMilli()}
	if status != "streaming" {
		message.CompletedAt = message.CreatedAt
	}
	return message
}

func (c *acpChat) persistLocked() {
	_ = c.engine.cli.acpSave(c.project, c.id, c.rec, time.Now())
}

func (c *acpChat) findLocked(id string) int {
	for index := len(c.rec.Messages) - 1; index >= 0; index-- {
		if c.rec.Messages[index].ID == id {
			return index
		}
	}
	return -1
}

func (c *acpChat) infoLocked() ChatInfo {
	info := ChatInfo{ID: c.id, Provider: c.agent, Model: c.model(), Mode: c.rec.Mode}
	if name, ok := c.engine.cli.storedName(c.id); ok {
		info.Title, info.TitleSource, info.TitleBasis = name.Title, name.Source, name.Basis
	}
	return info
}

func (c *acpChat) hubStateLocked() string {
	if c.turn != nil {
		return "busy"
	}
	return "idle"
}

func (c *acpChat) interactionsLocked() []ChatInteraction {
	result := make([]ChatInteraction, 0, len(c.asks))
	for _, ask := range c.asks {
		result = append(result, ask.interaction)
	}
	return result
}

func (c *acpChat) loadLocked(limit int) chatLoad {
	start := max(0, len(c.rec.Messages)-limit)
	return chatLoad{info: c.infoLocked(), messages: cloneMessages(c.rec.Messages[start:]), hasOlder: start > 0, state: c.hubStateLocked(), interactions: c.interactionsLocked()}
}

func (c *acpChat) snapshot(limit int, apply func(chatLoad)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	apply(c.loadLocked(limit))
}

func (c *acpChat) page(before string, limit int) ([]ChatMessage, bool, error) {
	c.mu.Lock()
	messages := cloneMessages(c.rec.Messages)
	c.mu.Unlock()
	return pageMessages(messages, before, limit)
}

// push applies one change to the hub's copy of this chat, if it has one.
func (c *acpChat) push(apply func(*hubChat, uint64)) {
	c.engine.chatHub().liveUpdate(c.key, apply)
}

func (c *acpChat) pushStateLocked() {
	state := c.hubStateLocked()
	c.push(func(hc *hubChat, touched uint64) {
		hc.state, hc.retry = state, nil
		hc.statusTouched = touched
		hc.recomputeStatus()
	})
}

func (c *acpChat) pushHeaderLocked(index int) {
	header := cloneMessage(c.rec.Messages[index])
	c.push(func(hc *hubChat, touched uint64) {
		if entry, _ := hc.find(header.ID); entry != nil {
			hc.updateHeader(entry, header, touched)
		}
	})
}

func (c *acpChat) pushPartLocked(messageID string, part ChatPart) {
	c.push(func(hc *hubChat, touched uint64) {
		hc.upsertPart(messageID, part, true, touched)
	})
}

func (c *acpChat) pushMessageLocked(message ChatMessage) {
	message = cloneMessage(message)
	c.push(func(hc *hubChat, touched uint64) {
		if entry, _ := hc.find(message.ID); entry == nil {
			hc.insertMessage(message, true, touched)
			hc.trim()
		}
	})
}

func (c *acpChat) pushInfoLocked() {
	info := c.infoLocked()
	c.push(func(hc *hubChat, touched uint64) {
		hc.applyInfo(info)
	})
}

// working reports a turn running or an approval waiting.
func (c *acpChat) working() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.turn != nil || len(c.asks) > 0
}

// modeFor checks a send's options: no effort, the agent's default model, and
// a mode only from those the chat lists.
func (c *acpChat) modeFor(options PromptOptions) (string, error) {
	if options.Effort != "" {
		return "", errOptionsUnsupported
	}
	if (options.Model != "" && options.Model != c.model()) || (options.Agent != "" && options.Agent != "build") {
		return "", ErrCLIChatUnavailable
	}
	if options.Mode == "" {
		return "", nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.rec.Modes) == 0 {
		return "", errOptionsUnsupported
	}
	for _, mode := range c.rec.Modes {
		if mode.ID == options.Mode {
			return mode.ID, nil
		}
	}
	return "", ErrCLIChatUnavailable
}

// send records the user message and starts its turn. It answers before the
// agent is contacted; what happens next shows in the chat.
func (c *acpChat) send(prompt chatPrompt) (string, error) {
	launch, ok := c.engine.launch(c.agent)
	if !ok {
		return "", errACPUnavailable
	}
	mode, err := c.modeFor(prompt.options)
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return "", errACPUnavailable
	}
	if c.turn != nil {
		c.mu.Unlock()
		return "", ErrCLIChatBusy
	}
	id := prompt.messageID
	if id == "" || len(id) > 128 || !utf8.ValidString(id) {
		id = cliMessageID()
	}
	now := time.Now()
	user := ChatMessage{ID: id, ChatID: c.id, TurnID: id, Role: "user", Status: "complete", Ord: c.takeOrdLocked(), CreatedAt: chatTimeOf(now), Provider: c.agent, Model: c.model(), Parts: []ChatPart{}, createdMs: now.UnixMilli()}
	if prompt.text != "" {
		text, cut := clipText(prompt.text, chatTextLimit)
		user.Parts = append(user.Parts, ChatPart{ID: id + ":0", Kind: "text", Ord: 1, Text: text, Truncated: cut})
	}
	for _, file := range prompt.files {
		info := AttachmentInfo{Name: file.Name, MIME: file.MIME}
		user.Parts = append(user.Parts, ChatPart{ID: id + ":" + itoa(len(user.Parts)), Kind: "attachment", Ord: int64(len(user.Parts) + 1), Attachment: &info})
	}
	c.rec.Messages = append(c.rec.Messages, user)
	c.rec.Running = id
	turn := &acpTurn{id: id, finished: prompt.finished, done: make(chan struct{}), tools: map[string]*acpToolState{}}
	c.turn = turn
	c.used = now
	c.stopIdleTimerLocked()
	c.persistLocked()
	c.pushMessageLocked(user)
	c.pushStateLocked()
	// Counted under the lock: the engine's close marks every chat closed
	// under it before it waits, so it waits for this turn.
	c.engine.work.Add(1)
	c.mu.Unlock()
	go func() {
		defer c.engine.work.Done()
		c.runTurn(turn, launch, prompt, mode)
	}()
	return id, nil
}

func itoa(value int) string { return strconv.Itoa(value) }

// runTurn starts what the turn needs and sends the prompt; the answer to
// session/prompt, or a failure, ends the turn.
func (c *acpChat) runTurn(turn *acpTurn, launch acpLaunchSpec, prompt chatPrompt, mode string) {
	conn, caps, err := c.ensureProcess(launch)
	if err != nil {
		c.finishTurn(turn, "", c.turnError(err, nil, launch.name, caps))
		return
	}
	if c.stopped(turn) {
		c.finishTurn(turn, "", nil)
		return
	}
	session, err := c.ensureSession(conn, caps, turn, launch)
	if err == nil && mode != "" {
		err = c.setMode(conn, session, mode, launch.name)
	}
	if err != nil {
		c.finishTurn(turn, "", c.turnError(err, conn, launch.name, caps))
		return
	}
	if c.stopped(turn) {
		c.finishTurn(turn, "", nil)
		return
	}
	blocks := acpPromptBlocks(prompt, caps)
	var answer struct {
		StopReason string `json:"stopReason"`
	}
	pending, err := conn.request("session/prompt", map[string]any{"sessionId": session, "prompt": blocks})
	if err == nil {
		c.mu.Lock()
		turn.prompted = true
		stopped := turn.interrupted || c.closed
		c.mu.Unlock()
		if stopped {
			// Stop came after the check above and left its cancel to the
			// prompt.
			_ = conn.notify("session/cancel", map[string]any{"sessionId": session})
		}
		err = pending.wait(context.Background(), &answer)
	}
	if signInRefused(err) {
		c.dropProcess(conn)
	}
	c.finishTurn(turn, answer.StopReason, c.turnError(err, conn, launch.name, caps))
}

// signInRefused reports ACP's "Authentication required" answer. An agent may
// read its sign-in only when it starts, so the chat ends the process that
// refused: the next send starts one that sees the sign-in the owner made
// meanwhile.
func signInRefused(err error) bool {
	var rpc *acpRPCError
	return errors.As(err, &rpc) && rpc.authRequired()
}

// stopped reports whether the user stopped the turn.
func (c *acpChat) stopped(turn *acpTurn) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return turn.interrupted || c.closed
}

// turnError turns a failed call into the reply's error.
func (c *acpChat) turnError(err error, conn *acpConn, name string, caps acpAgentCaps) error {
	var rpc *acpRPCError
	var failure *acpAgentError
	switch {
	case err == nil:
		return nil
	case errors.As(err, &failure):
		return failure
	case errors.As(err, &rpc) && rpc.authRequired():
		return acpAuthFailure(name, caps)
	case errors.As(err, &rpc):
		message := strings.TrimSpace(rpc.Message)
		if message == "" {
			message = name + " could not complete this request."
		}
		return acpFailure("agent_error", "%s", message)
	case conn != nil && conn.wasOversized():
		return acpFailure("protocol_error", "%s sent output AgentLand could not read, so the reply stopped.", name)
	}
	return acpFailure("agent_exited", "%s stopped before this reply completed.", name)
}

func acpAuthFailure(name string, caps acpAgentCaps) *acpAgentError {
	failure := &acpAgentError{code: "agent_auth_required", authMethods: append([]string(nil), caps.authMethods...)}
	if len(caps.authMethods) > 0 {
		failure.message = name + " needs you to sign in (" + strings.Join(caps.authMethods, ", ") + "). Open it in a terminal to sign in, then send again."
	} else {
		failure.message = name + " needs you to sign in. Open it in a terminal to sign in, then send again."
	}
	failure.message, _ = clipText(failure.message, chatErrorLimit)
	return failure
}

// ensureProcess returns the chat's live process, starting and initializing
// one when there is none.
func (c *acpChat) ensureProcess(launch acpLaunchSpec) (*acpConn, acpAgentCaps, error) {
	c.mu.Lock()
	if c.conn != nil && c.conn.alive() {
		conn, caps := c.conn, c.caps
		c.mu.Unlock()
		return conn, caps, nil
	}
	c.mu.Unlock()
	options := c.engine.options
	exited := func(conn *acpConn) {
		c.engine.untrack(conn)
		c.processExited(conn)
	}
	conn, err := startACPConn(acpSpawn{command: launch.command, args: launch.args, dir: c.project.Directory, env: c.engine.environment(launch), lineLimit: options.lineLimit, stderrTail: options.stderrTail, trace: options.trace}, c, exited)
	if err != nil {
		return nil, acpAgentCaps{}, acpFailure("agent_exited", "%s did not start.", launch.name)
	}
	stopping := !c.engine.track(conn)
	c.mu.Lock()
	if stopping || c.closed {
		c.mu.Unlock()
		conn.terminate(agentShutdownKill)
		return nil, acpAgentCaps{}, acpFailure("agent_exited", "AgentLand stopped before this reply completed.")
	}
	c.conn, c.session, c.caps = conn, "", acpAgentCaps{}
	c.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), options.initWait)
	var raw json.RawMessage
	err = conn.call(ctx, "initialize", acpInitializeParams(), &raw)
	cancel()
	var caps acpAgentCaps
	if err == nil {
		caps, err = parseACPInitialize(raw)
		if err != nil {
			c.dropProcess(conn)
			return nil, acpAgentCaps{}, acpFailure("protocol_error", "%s does not speak ACP protocol version 1.", launch.name)
		}
	}
	if err != nil {
		c.dropProcess(conn)
		if conn.wasOversized() {
			return nil, acpAgentCaps{}, acpFailure("protocol_error", "%s sent output AgentLand could not read, so the reply stopped.", launch.name)
		}
		return nil, acpAgentCaps{}, acpFailure("agent_exited", "%s did not start.", launch.name)
	}
	c.mu.Lock()
	if c.conn == conn {
		c.caps = caps
	}
	c.mu.Unlock()
	return conn, caps, nil
}

// acpModes reads a session's modes ({currentModeId, availableModes}).
func acpModes(raw json.RawMessage) ([]ChatMode, string, bool) {
	var state struct {
		CurrentModeID  string `json:"currentModeId"`
		AvailableModes []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"availableModes"`
	}
	if len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &state) != nil {
		return nil, "", false
	}
	modes := []ChatMode{}
	for _, mode := range state.AvailableModes {
		if mode.ID == "" || len(mode.ID) > 64 || !plainAgentText(mode.ID, 64) || len(modes) == 32 {
			continue
		}
		name := strings.TrimSpace(mode.Name)
		if name == "" || !plainAgentText(name, 100) {
			name = mode.ID
		}
		modes = append(modes, ChatMode{ID: mode.ID, Name: name})
	}
	current := state.CurrentModeID
	if !plainAgentText(current, 64) {
		current = ""
	}
	return modes, current, true
}

// ensureSession makes the process's ACP session: session/load of the chat's
// session when the agent can, else session/new.
func (c *acpChat) ensureSession(conn *acpConn, caps acpAgentCaps, turn *acpTurn, launch acpLaunchSpec) (string, error) {
	c.mu.Lock()
	if c.conn == conn && c.session != "" {
		session := c.session
		c.mu.Unlock()
		return session, nil
	}
	stored := c.rec.SessionID
	c.mu.Unlock()
	options := c.engine.options
	var answer struct {
		SessionID string          `json:"sessionId"`
		Modes     json.RawMessage `json:"modes"`
	}
	session, notice := "", ""
	if stored != "" && caps.loadSession {
		c.mu.Lock()
		c.loading = true
		c.mu.Unlock()
		ctx, cancel := context.WithTimeout(context.Background(), options.sessionWait)
		var raw json.RawMessage
		err := conn.call(ctx, "session/load", map[string]any{"sessionId": stored, "cwd": c.project.Directory, "mcpServers": []any{}}, &raw)
		cancel()
		c.mu.Lock()
		c.loading = false
		c.mu.Unlock()
		var rpc *acpRPCError
		switch {
		case err == nil:
			session = stored
			_ = json.Unmarshal(raw, &answer)
		case signInRefused(err):
			c.dropProcess(conn)
			return "", acpAuthFailure(launch.name, caps)
		case errors.As(err, &rpc):
			notice = "The agent started a new session and does not remember the earlier messages."
		default:
			if errors.Is(err, context.DeadlineExceeded) {
				c.dropProcess(conn)
				return "", acpFailure("agent_exited", "%s did not answer.", launch.name)
			}
			return "", err
		}
	} else if stored != "" {
		notice = "The agent started a new session and does not remember the earlier messages."
	}
	if session == "" {
		ctx, cancel := context.WithTimeout(context.Background(), options.sessionWait)
		err := conn.call(ctx, "session/new", map[string]any{"cwd": c.project.Directory, "mcpServers": []any{}}, &answer)
		cancel()
		switch {
		case signInRefused(err):
			c.dropProcess(conn)
			return "", acpAuthFailure(launch.name, caps)
		case errors.Is(err, context.DeadlineExceeded):
			c.dropProcess(conn)
			return "", acpFailure("agent_exited", "%s did not answer.", launch.name)
		case err != nil:
			return "", err
		}
		if answer.SessionID == "" || len(answer.SessionID) > 256 || !utf8.ValidString(answer.SessionID) {
			c.dropProcess(conn)
			return "", acpFailure("protocol_error", "%s did not name its session.", launch.name)
		}
		session = answer.SessionID
	}
	modes, current, listed := acpModes(answer.Modes)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == conn {
		c.session = session
	}
	c.rec.SessionID = session
	infoChanged := false
	if listed {
		c.rec.Modes = modes
		if current != "" && current != c.rec.Mode {
			c.rec.Mode, infoChanged = current, true
		}
		c.engine.rememberModes(c.agent, modes)
	}
	if notice != "" && c.turn == turn {
		turn.notice = notice
		c.noticeLocked(turn, notice)
	}
	c.persistLocked()
	if infoChanged {
		c.pushInfoLocked()
	}
	return session, nil
}

// setMode switches the session's mode before a prompt that asked for one.
// An agent that does not answer is ended, as in the handshake.
func (c *acpChat) setMode(conn *acpConn, session, mode, name string) error {
	c.mu.Lock()
	current := c.rec.Mode
	c.mu.Unlock()
	if mode == current {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.engine.options.controlWait)
	err := conn.call(ctx, "session/set_mode", map[string]any{"sessionId": session, "modeId": mode}, nil)
	cancel()
	if errors.Is(err, context.DeadlineExceeded) {
		c.dropProcess(conn)
		return acpFailure("agent_exited", "%s did not answer.", name)
	}
	var rpc *acpRPCError
	if errors.As(err, &rpc) {
		message := strings.TrimSpace(rpc.Message)
		if message == "" {
			message = "The agent did not switch to that mode."
		}
		return acpFailure("agent_error", "%s", message)
	}
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.rec.Mode != mode {
		c.rec.Mode = mode
		c.persistLocked()
		c.pushInfoLocked()
	}
	return nil
}

// acpPromptBlocks is the prompt as ACP content: the text, image blocks for
// images when the agent takes them, and the other attachments named with
// their host paths for the agent's own tools.
func acpPromptBlocks(prompt chatPrompt, caps acpAgentCaps) []map[string]any {
	blocks := []map[string]any{}
	var named []ChatAttachment
	var images []map[string]any
	for _, file := range prompt.files {
		switch file.MIME {
		case "image/png", "image/jpeg", "image/gif", "image/webp":
			if caps.image {
				if data, err := os.ReadFile(file.Path); err == nil {
					images = append(images, map[string]any{"type": "image", "mimeType": file.MIME, "data": base64.StdEncoding.EncodeToString(data)})
					continue
				}
			}
		}
		named = append(named, file)
	}
	text := claudePromptText(prompt.text, named)
	if text == "" && len(images) > 0 {
		text = "See the attached images."
	}
	blocks = append(blocks, map[string]any{"type": "text", "text": text})
	return append(blocks, images...)
}

// dropProcess ends a process that failed to start its work, so the next send
// starts a new one instead of meeting it while it dies.
func (c *acpChat) dropProcess(conn *acpConn) {
	c.mu.Lock()
	if c.conn == conn {
		c.conn, c.session, c.caps = nil, "", acpAgentCaps{}
	}
	c.mu.Unlock()
	conn.kill()
}

// processExited runs once for every process after it ended.
func (c *acpChat) processExited(conn *acpConn) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == conn {
		c.conn, c.session, c.caps = nil, "", acpAgentCaps{}
		c.stopIdleTimerLocked()
	}
}

// finishTurn ends the running turn: with stopReason from the agent's answer,
// or with failure. Unfinished replies and tools settle, pending approvals are
// cancelled and gone.
func (c *acpChat) finishTurn(turn *acpTurn, stopReason string, failure error) {
	c.mu.Lock()
	if c.turn != turn {
		c.mu.Unlock()
		return
	}
	now := time.Now()
	outcome := "completed"
	var agentErr *acpAgentError
	switch {
	case turn.interrupted || c.closed || stopReason == "cancelled":
		outcome = "aborted"
	case failure != nil:
		outcome = "error"
		if !errors.As(failure, &agentErr) {
			agentErr = acpFailure("agent_exited", "%s stopped before this reply completed.", c.engine.agentName(c.agent))
		}
	}
	if outcome == "completed" {
		notice := ""
		switch stopReason {
		case "max_tokens":
			notice = "The reply reached the model's output limit."
		case "max_turn_requests":
			notice = "The agent reached its limit of model requests for this turn."
		case "refusal":
			notice = "The model declined to continue this reply."
		}
		if notice != "" {
			c.noticeLocked(turn, notice)
		}
	}
	last, aborted := -1, false
	for index := range c.rec.Messages {
		message := &c.rec.Messages[index]
		if message.Role != "assistant" || message.TurnID != turn.id {
			continue
		}
		last = index
		for _, part := range append([]ChatPart(nil), message.Parts...) {
			if part.Tool == nil || (part.Tool.Status != "pending" && part.Tool.Status != "running") {
				continue
			}
			tool := *part.Tool
			if tool.Name == "Plan" && outcome == "completed" {
				tool.Status = "completed"
			} else {
				tool.Status, tool.Error = "error", "The turn ended before this tool finished."
			}
			part.Tool = &tool
			part.End = chatTimeOf(now)
			c.putPartLocked(index, part)
		}
		if message.Status == "streaming" {
			message.Status = "complete"
			switch outcome {
			case "aborted":
				message.Status = "aborted"
			case "error":
				message.Status, message.Error = "error", agentErr.chatError()
			}
			message.CompletedAt = chatTimeOf(now)
			c.pushHeaderLocked(index)
		}
		aborted = aborted || message.Status == "aborted"
	}
	switch {
	case outcome == "aborted" && !aborted:
		message := c.newReplyLocked(turn.id, "aborted", now)
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
	case outcome == "error" && (last < 0 || c.rec.Messages[last].Status != "error"):
		message := c.newReplyLocked(turn.id, "error", now)
		message.Error = agentErr.chatError()
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
	}
	asks := c.takeAsksLocked()
	c.rec.Running = ""
	c.turn = nil
	c.used = now
	c.persistLocked()
	c.pushStateLocked()
	c.armIdleTimerLocked()
	close(turn.done)
	c.mu.Unlock()
	acpCancelAsks(asks)
	if turn.finished != nil {
		turn.finished()
	}
}

func (e *acpAgentError) chatError() *ChatError {
	if e == nil {
		return &ChatError{Code: "agent_exited", Message: "The agent stopped before this reply completed."}
	}
	return &ChatError{Code: e.code, Message: e.message, AuthMethods: e.authMethods}
}

// takeAsksLocked removes the pending approvals, resolving them gone.
func (c *acpChat) takeAsksLocked() []*acpAsk {
	asks := c.asks
	c.asks = nil
	for _, ask := range asks {
		id := ask.id
		c.push(func(hc *hubChat, touched uint64) { hc.resolveInteraction(id, "gone", touched) })
	}
	return asks
}

// acpCancelAsks answers approvals nobody will answer: cancelled.
func acpCancelAsks(asks []*acpAsk) {
	for _, ask := range asks {
		_ = ask.conn.respond(ask.rpcID, map[string]any{"outcome": map[string]string{"outcome": "cancelled"}})
	}
}

// interrupt stops the running turn (POST /v1/abort): session/cancel, pending
// approvals cancelled. Before the prompt is written the turn ends at its next
// check, or sends the cancel after the prompt itself. A turn that has not
// ended 10 s later ends with its process.
func (c *acpChat) interrupt() error {
	c.mu.Lock()
	turn := c.turn
	if turn == nil {
		c.mu.Unlock()
		return nil
	}
	turn.interrupted = true
	conn, session, prompted := c.conn, c.session, turn.prompted
	asks := c.takeAsksLocked()
	// Counted under the lock, as the turn is (send).
	c.engine.work.Add(1)
	c.mu.Unlock()
	acpCancelAsks(asks)
	if prompted && conn != nil && session != "" {
		_ = conn.notify("session/cancel", map[string]any{"sessionId": session})
	}
	go func() {
		defer c.engine.work.Done()
		timer := time.NewTimer(c.engine.options.cancelWait)
		defer timer.Stop()
		select {
		case <-turn.done:
			return
		case <-timer.C:
		}
		c.mu.Lock()
		stuck := c.turn == turn
		current := c.conn
		c.mu.Unlock()
		if stuck && current != nil {
			current.kill()
		}
	}()
	return nil
}

func (c *acpChat) stopIdleTimerLocked() {
	if c.idleTimer != nil {
		c.idleTimer.Stop()
		c.idleTimer = nil
	}
}

func (c *acpChat) armIdleTimerLocked() {
	c.stopIdleTimerLocked()
	if c.conn == nil || c.closed {
		return
	}
	c.idleTimer = time.AfterFunc(c.engine.options.idleStop, func() { c.stopIfIdle(true) })
}

// stopIfIdle stops the process when no turn runs and no approval waits.
func (c *acpChat) stopIfIdle(fromTimer bool) bool {
	c.mu.Lock()
	conn := c.conn
	idle := conn != nil && c.turn == nil && len(c.asks) == 0
	if fromTimer && time.Since(c.used) < c.engine.options.idleStop {
		idle = false
	}
	if idle {
		c.stopIdleTimerLocked()
		// A send from now on starts a new process.
		c.conn, c.session, c.caps = nil, "", acpAgentCaps{}
	}
	c.mu.Unlock()
	if !idle {
		return false
	}
	conn.stop(c.engine.options.stopGrace)
	return true
}

// shutdown ends the chat for good at the host's shutdown: a running turn
// counts as stopped and pending approvals are gone. Nothing is written to the
// process, which the engine ends at once (close); the turn ends with it.
func (c *acpChat) shutdown() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	c.stopIdleTimerLocked()
	if c.turn != nil {
		c.turn.interrupted = true
	}
	c.takeAsksLocked()
}
