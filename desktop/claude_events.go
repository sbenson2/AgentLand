package host

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// The mapping from Claude Code 2.1.280's stream-json output to the unified
// conversation model. Parts keep the order Claude emitted them in: a part's
// ord is its content block index within the Anthropic message.

type claudeFrame struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype"`
	UUID            string          `json:"uuid"`
	SessionID       string          `json:"session_id"`
	ParentToolUseID *string         `json:"parent_tool_use_id"`
	IsReplay        bool            `json:"isReplay"`
	Message         json.RawMessage `json:"message"`
	Event           json.RawMessage `json:"event"`
	Error           json.RawMessage `json:"error"`
	Aborted         bool            `json:"aborted"`
	// system
	PermissionMode string  `json:"permissionMode"`
	APIKeySource   string  `json:"apiKeySource"`
	State          string  `json:"state"`
	Attempt        int     `json:"attempt"`
	RetryDelayMs   float64 `json:"retry_delay_ms"`
	ErrorStatus    *int    `json:"error_status"`
	// result
	IsError      bool     `json:"is_error"`
	Result       string   `json:"result"`
	Errors       []string `json:"errors"`
	TotalCostUSD float64  `json:"total_cost_usd"`
	// control
	RequestID string          `json:"request_id"`
	Request   json.RawMessage `json:"request"`
}

func (f claudeFrame) subagent() bool {
	return f.ParentToolUseID != nil && *f.ParentToolUseID != ""
}

type claudeUsage struct {
	InputTokens              int64 `json:"input_tokens"`
	OutputTokens             int64 `json:"output_tokens"`
	CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
}

type claudeBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

type claudeAPIMessage struct {
	ID      string        `json:"id"`
	Model   string        `json:"model"`
	Content []claudeBlock `json:"content"`
	Usage   *claudeUsage  `json:"usage"`
}

type claudeStreamEvent struct {
	Type         string           `json:"type"`
	Index        int              `json:"index"`
	Message      claudeAPIMessage `json:"message"`
	ContentBlock claudeBlock      `json:"content_block"`
	Delta        struct {
		Type        string  `json:"type"`
		Text        string  `json:"text"`
		Thinking    string  `json:"thinking"`
		PartialJSON string  `json:"partial_json"`
		StopReason  *string `json:"stop_reason"`
	} `json:"delta"`
	Usage *claudeUsage `json:"usage"`
}

func claudeString(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	return ""
}

func claudeMessageModel(model string) string {
	if model == "" {
		return ""
	}
	value, _ := clipText(model, 128)
	return "claude/" + value
}

// claudeChatUsage folds Anthropic usage into the unified model. later, from a
// message_delta, carries the final output count.
func claudeChatUsage(start, later *claudeUsage, previous *ChatUsage) *ChatUsage {
	if start == nil && later == nil {
		return previous
	}
	usage := ChatUsage{}
	if previous != nil {
		usage = *previous
		usage.CostMicros = previous.CostMicros
	}
	for _, source := range []*claudeUsage{start, later} {
		if source == nil {
			continue
		}
		if source.InputTokens > 0 {
			usage.Input = source.InputTokens
		}
		if source.OutputTokens > 0 {
			usage.Output = source.OutputTokens
		}
		if source.CacheReadInputTokens > 0 {
			usage.CacheRead = source.CacheReadInputTokens
		}
		if source.CacheCreationInputTokens > 0 {
			usage.CacheWrite = source.CacheCreationInputTokens
		}
	}
	return &usage
}

// claudeToolTitle names what a tool acts on, from its input.
func claudeToolTitle(input json.RawMessage) string {
	var fields map[string]json.RawMessage
	if json.Unmarshal(input, &fields) != nil {
		return ""
	}
	for _, key := range []string{"description", "file_path", "path", "notebook_path", "pattern", "url", "query", "command"} {
		if value := claudeString(fields[key]); strings.TrimSpace(value) != "" {
			title, _ := clipText(strings.TrimSpace(value), chatShortLimit)
			return title
		}
	}
	return ""
}

// claudeCompactJSON returns input without insignificant space, bounded.
func claudeCompactJSON(input []byte) (string, bool) {
	var buffer bytes.Buffer
	if json.Compact(&buffer, input) == nil {
		input = buffer.Bytes()
	}
	text := string(input)
	if text == "{}" || text == "null" {
		return "", false
	}
	return boundedToolText(text)
}

// claudeToolResultText joins a tool_result's text; other content is named.
func claudeToolResultText(content json.RawMessage) string {
	if text := claudeString(content); text != "" || len(content) == 0 {
		return text
	}
	var blocks []claudeBlock
	if json.Unmarshal(content, &blocks) != nil {
		return ""
	}
	parts := []string{}
	for _, block := range blocks {
		switch block.Type {
		case "text":
			parts = append(parts, block.Text)
		case "image":
			parts = append(parts, "[image]")
		default:
			parts = append(parts, "["+block.Type+"]")
		}
	}
	return strings.Join(parts, "\n")
}

// claudeErrorCode maps an assistant message's error or a result's subtype.
func claudeErrorCode(kind string) string {
	switch kind {
	case "authentication_failed", "billing_error", "oauth_org_not_allowed":
		return "provider_auth"
	case "rate_limit", "server_error", "invalid_request", "unknown", "api_error", "overloaded":
		return "provider_error"
	case "max_output_tokens":
		return "output_length"
	case "error_max_turns":
		return "max_turns"
	case "error_max_budget_usd":
		return "max_budget"
	default:
		return "agent_error"
	}
}

// handleLine applies one stdout line from proc. A nil line means the output
// broke the protocol: the turn ends and the process is ended.
func (c *claudeChat) handleLine(proc *claudeProcess, line []byte) {
	if line == nil {
		c.mu.Lock()
		if c.proc == proc && c.turn != nil {
			c.turn.protocol = true
		}
		c.mu.Unlock()
		proc.kill()
		return
	}
	var frame claudeFrame
	if json.Unmarshal(line, &frame) != nil {
		return
	}
	var after []func()
	c.mu.Lock()
	if c.proc == proc {
		switch frame.Type {
		case "stream_event":
			if !frame.subagent() {
				c.onStreamEventLocked(frame)
			}
		case "assistant":
			if !frame.subagent() {
				c.onAssistantLocked(frame)
			}
		case "user":
			if !frame.subagent() {
				after = c.onUserLocked(proc, frame)
			}
		case "result":
			after = c.onResultLocked(frame)
		case "system":
			after = c.onSystemLocked(proc, frame)
		case "control_request":
			after = c.onControlRequestLocked(proc, frame)
		case "control_cancel_request":
			c.onControlCancelLocked(frame)
		}
	}
	c.mu.Unlock()
	for _, run := range after {
		run()
	}
}

// noteEntryLocked records the newest transcript entry for the uuid chain.
func (c *claudeChat) noteEntryLocked(uuid string) {
	if uuid == "" {
		return
	}
	c.lastEntry = uuid
}

// activeTurnLocked returns the running turn, starting one for activity
// without a prompt of the host's (a background task waking the agent).
func (c *claudeChat) activeTurnLocked() *claudeTurn {
	if c.turn == nil {
		turn := ""
		for index := len(c.rec.Messages) - 1; index >= 0; index-- {
			if c.rec.Messages[index].Role == "user" {
				turn = c.rec.Messages[index].ID
				break
			}
		}
		c.turn = newClaudeTurn(turn, nil)
		c.state = "busy"
		c.rec.Running = turn
		c.pushStateLocked()
	}
	return c.turn
}

// currentMessageLocked returns the index of the assistant message streaming
// now.
func (c *claudeChat) currentMessageLocked(turn *claudeTurn) int {
	id, ok := turn.apiMessages[turn.current]
	if !ok {
		return -1
	}
	return c.findLocked(id)
}

func claudePartID(messageID string, index int) string {
	return messageID + ":" + strconv.Itoa(index)
}

func partIndex(message *ChatMessage, id string) int {
	for index := range message.Parts {
		if message.Parts[index].ID == id {
			return index
		}
	}
	return -1
}

// putPartLocked inserts or replaces a part in ord order and announces it.
func (c *claudeChat) putPartLocked(messageIndex int, part ChatPart) {
	message := &c.rec.Messages[messageIndex]
	if index := partIndex(message, part.ID); index >= 0 {
		if message.Parts[index] == part {
			return
		}
		message.Parts[index] = part
	} else {
		if len(message.Parts) >= chatPartsPerMessage {
			return
		}
		position := len(message.Parts)
		for position > 0 && message.Parts[position-1].Ord > part.Ord {
			position--
		}
		message.Parts = append(message.Parts, ChatPart{})
		copy(message.Parts[position+1:], message.Parts[position:])
		message.Parts[position] = part
	}
	c.pushPartLocked(message.ID, part)
}

// appendLocked adds streamed text to a text or reasoning part, bounded as
// the hub bounds it.
func (c *claudeChat) appendLocked(messageIndex, index int, delta string) {
	message := &c.rec.Messages[messageIndex]
	part := &message.Parts[index]
	if delta == "" || part.Truncated {
		return
	}
	limit := chatTextLimit
	if part.Kind == "reasoning" {
		limit = chatReasoningLimit
	}
	accepted, cut := clipText(delta, limit-len(part.Text))
	part.Text += accepted
	part.Truncated = cut
	messageID, partID := message.ID, part.ID
	c.push(func(hc *hubChat, touched uint64) {
		hc.appendDelta(messageID, partID, "text", delta, touched)
	})
}

// claudePartStart makes the part a content block starts. It reports false
// for blocks a chat does not show.
func claudePartStart(messageID string, index int, block claudeBlock, now time.Time) (ChatPart, bool) {
	part := ChatPart{ID: claudePartID(messageID, index), Ord: int64(index + 1), Start: chatTimeOf(now)}
	switch block.Type {
	case "text":
		part.Kind = "text"
		part.Text, part.Truncated = clipText(block.Text, chatTextLimit)
	case "thinking":
		part.Kind = "reasoning"
		part.Text, part.Truncated = clipText(block.Thinking, chatReasoningLimit)
	case "tool_use", "server_tool_use", "mcp_tool_use":
		name, _ := clipText(block.Name, 256)
		callID, _ := clipText(block.ID, 256)
		part.Kind = "tool"
		part.Tool = &ChatTool{Name: name, CallID: callID, Status: "pending"}
	default:
		return ChatPart{}, false
	}
	return part, true
}

func (c *claudeChat) onStreamEventLocked(frame claudeFrame) {
	var event claudeStreamEvent
	if json.Unmarshal(frame.Event, &event) != nil {
		return
	}
	turn := c.activeTurnLocked()
	now := time.Now()
	switch event.Type {
	case "message_start":
		if event.Message.ID == "" {
			return
		}
		if c.state != "busy" {
			c.state, c.retry = "busy", nil
			c.pushStateLocked()
		}
		message := c.newAssistantLocked(turn.id, "streaming", now)
		message.Model = claudeMessageModel(event.Message.Model)
		message.Usage = claudeChatUsage(event.Message.Usage, nil, nil)
		turn.apiMessages[event.Message.ID] = message.ID
		turn.current = event.Message.ID
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
	case "content_block_start":
		index := c.currentMessageLocked(turn)
		if index < 0 {
			return
		}
		part, ok := claudePartStart(c.rec.Messages[index].ID, event.Index, event.ContentBlock, now)
		if !ok {
			return
		}
		if part.Tool != nil {
			turn.tools[event.ContentBlock.ID] = claudeToolRef{message: c.rec.Messages[index].ID, part: part.ID}
			turn.inputs[part.ID] = &strings.Builder{}
		}
		c.putPartLocked(index, part)
	case "content_block_delta":
		index := c.currentMessageLocked(turn)
		if index < 0 {
			return
		}
		message := &c.rec.Messages[index]
		partID := claudePartID(message.ID, event.Index)
		position := partIndex(message, partID)
		if position < 0 {
			return
		}
		switch event.Delta.Type {
		case "text_delta":
			if message.Parts[position].Kind == "text" {
				c.appendLocked(index, position, event.Delta.Text)
			}
		case "thinking_delta":
			if message.Parts[position].Kind == "reasoning" {
				c.appendLocked(index, position, event.Delta.Thinking)
			}
		case "input_json_delta":
			if builder := turn.inputs[partID]; builder != nil && builder.Len() <= chatToolFieldLimit {
				builder.WriteString(event.Delta.PartialJSON)
			}
		}
	case "content_block_stop":
		index := c.currentMessageLocked(turn)
		if index < 0 {
			return
		}
		message := &c.rec.Messages[index]
		partID := claudePartID(message.ID, event.Index)
		position := partIndex(message, partID)
		if position < 0 || message.Parts[position].Tool == nil {
			return
		}
		part := message.Parts[position]
		tool := *part.Tool
		if builder := turn.inputs[partID]; builder != nil {
			tool.Input, tool.Truncated = claudeCompactJSON([]byte(builder.String()))
			tool.Title = claudeToolTitle(json.RawMessage(builder.String()))
			delete(turn.inputs, partID)
		}
		if tool.Status == "pending" {
			tool.Status = "running"
		}
		part.Tool = &tool
		c.putPartLocked(index, part)
	case "message_delta":
		index := c.currentMessageLocked(turn)
		if index < 0 {
			return
		}
		message := &c.rec.Messages[index]
		message.Usage = claudeChatUsage(nil, event.Usage, message.Usage)
		if reason := event.Delta.StopReason; reason != nil {
			notice := ""
			switch *reason {
			case "max_tokens", "model_context_window_exceeded":
				notice = "The reply reached the model's output limit."
			case "refusal":
				notice = "The model declined to continue this reply."
			}
			if notice != "" {
				c.putPartLocked(index, ChatPart{ID: claudePartID(message.ID, 10000), Kind: "notice", Ord: 10001, Text: notice, Start: chatTimeOf(now)})
			}
		}
		c.pushHeaderLocked(index)
	case "message_stop":
		index := c.currentMessageLocked(turn)
		if index < 0 {
			return
		}
		message := &c.rec.Messages[index]
		if message.Status == "streaming" {
			message.Status, message.CompletedAt = "complete", chatTimeOf(now)
			c.pushHeaderLocked(index)
		}
	}
}

// onAssistantLocked reconciles a finished content block with what streamed,
// or adds a message that arrived without stream events (an API error).
func (c *claudeChat) onAssistantLocked(frame claudeFrame) {
	c.noteEntryLocked(frame.UUID)
	var body claudeAPIMessage
	if json.Unmarshal(frame.Message, &body) != nil {
		return
	}
	turn := c.activeTurnLocked()
	now := time.Now()
	index := -1
	if id, ok := turn.apiMessages[body.ID]; ok && body.ID != "" {
		index = c.findLocked(id)
	}
	if index < 0 {
		message := c.newAssistantLocked(turn.id, "complete", now)
		message.Model = claudeMessageModel(body.Model)
		message.Usage = claudeChatUsage(body.Usage, nil, nil)
		if body.ID != "" {
			turn.apiMessages[body.ID] = message.ID
		}
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
		index = len(c.rec.Messages) - 1
	}
	if kind := claudeString(frame.Error); kind != "" {
		// A reply that is an API error shows as the message's error.
		texts := []string{}
		for _, block := range body.Content {
			if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
				texts = append(texts, strings.TrimSpace(block.Text))
			}
		}
		text := strings.Join(texts, "\n")
		if text == "" {
			text = chatDefaultError
		}
		text, _ = clipText(text, chatErrorLimit)
		message := &c.rec.Messages[index]
		message.Status, message.Error, message.CompletedAt = "error", &ChatError{Code: claudeErrorCode(kind), Message: text}, chatTimeOf(now)
		c.pushHeaderLocked(index)
		return
	}
	for _, block := range body.Content {
		position := turn.seen[body.ID]
		turn.seen[body.ID]++
		c.reconcileBlockLocked(turn, index, position, block, now)
	}
	message := &c.rec.Messages[index]
	if frame.Aborted && message.Status != "aborted" {
		message.Status, message.CompletedAt = "aborted", chatTimeOf(now)
		c.pushHeaderLocked(index)
	}
}

func (c *claudeChat) reconcileBlockLocked(turn *claudeTurn, index, position int, block claudeBlock, now time.Time) {
	message := &c.rec.Messages[index]
	partID := claudePartID(message.ID, position)
	existing := partIndex(message, partID)
	var part ChatPart
	if existing >= 0 {
		part = message.Parts[existing]
	} else {
		started, ok := claudePartStart(message.ID, position, block, now)
		if !ok {
			return
		}
		part = started
	}
	switch block.Type {
	case "text":
		if part.Kind != "text" {
			return
		}
		if !part.Truncated {
			part.Text, part.Truncated = clipText(block.Text, chatTextLimit)
		}
	case "thinking":
		if part.Kind != "reasoning" {
			return
		}
		if !part.Truncated {
			part.Text, part.Truncated = clipText(block.Thinking, chatReasoningLimit)
		}
	case "tool_use", "server_tool_use", "mcp_tool_use":
		if part.Tool == nil {
			return
		}
		tool := *part.Tool
		if len(block.Input) > 0 {
			tool.Input, tool.Truncated = claudeCompactJSON(block.Input)
			tool.Title = claudeToolTitle(block.Input)
		}
		if tool.Status == "pending" {
			tool.Status = "running"
		}
		part.Tool = &tool
		turn.tools[block.ID] = claudeToolRef{message: message.ID, part: part.ID}
	default:
		return
	}
	c.putPartLocked(index, part)
}

func (c *claudeChat) onUserLocked(proc *claudeProcess, frame claudeFrame) []func() {
	if frame.IsReplay {
		if out := c.outgoing; out != nil && frame.UUID == out.uuid {
			return c.deliveredLocked(proc, out)
		}
		// Output of a control such as set_model; it still is an entry.
		c.noteEntryLocked(frame.UUID)
		return nil
	}
	c.noteEntryLocked(frame.UUID)
	var body struct {
		Content json.RawMessage `json:"content"`
	}
	if json.Unmarshal(frame.Message, &body) != nil {
		return nil
	}
	var blocks []claudeBlock
	if json.Unmarshal(body.Content, &blocks) != nil {
		return nil
	}
	for _, block := range blocks {
		if block.Type == "tool_result" {
			c.toolResultLocked(block)
		}
	}
	return nil
}

// toolResultLocked completes the tool part a tool_result answers.
func (c *claudeChat) toolResultLocked(block claudeBlock) {
	var ref claudeToolRef
	if c.turn != nil {
		ref = c.turn.tools[block.ToolUseID]
	}
	index, position := -1, -1
	if ref.message != "" {
		if index = c.findLocked(ref.message); index >= 0 {
			position = partIndex(&c.rec.Messages[index], ref.part)
		}
	}
	for candidate := len(c.rec.Messages) - 1; position < 0 && candidate >= 0; candidate-- {
		for number, part := range c.rec.Messages[candidate].Parts {
			if part.Tool != nil && part.Tool.CallID == block.ToolUseID {
				index, position = candidate, number
				break
			}
		}
	}
	if position < 0 {
		return
	}
	part := c.rec.Messages[index].Parts[position]
	tool := *part.Tool
	text, cut := boundedToolText(claudeToolResultText(block.Content))
	if block.IsError {
		tool.Status, tool.Error, tool.Output = "error", text, ""
	} else {
		tool.Status, tool.Output = "completed", text
	}
	tool.Truncated = tool.Truncated || cut
	part.Tool = &tool
	part.End = chatTimeOf(time.Now())
	c.putPartLocked(index, part)
}

// deliveredLocked starts the turn of a prompt the CLI replayed: it is now in
// Claude's transcript.
func (c *claudeChat) deliveredLocked(proc *claudeProcess, out *claudeOutgoing) []func() {
	c.outgoing = nil
	// The turn owns the prompt's files from here.
	out.settled = true
	now := time.Now()
	rebuild := false
	if out.commit != "" {
		c.commitRewindLocked(out.commit)
		rebuild = true
	}
	user := ChatMessage{ID: out.uuid, ChatID: c.id, TurnID: out.uuid, Role: "user", Status: "complete", Ord: c.takeOrdLocked(), CreatedAt: chatTimeOf(now), Provider: "claude", Model: "claude/" + claudeModelName(out.settings.model), Parts: []ChatPart{}, createdMs: now.UnixMilli()}
	if out.text != "" {
		text, cut := clipText(out.text, chatTextLimit)
		user.Parts = append(user.Parts, ChatPart{ID: out.uuid + ":0", Kind: "text", Ord: 1, Text: text, Truncated: cut})
	}
	for _, file := range out.files {
		info := AttachmentInfo{Name: file.Name, MIME: file.MIME}
		user.Parts = append(user.Parts, ChatPart{ID: fmt.Sprintf("%s:%d", out.uuid, len(user.Parts)), Kind: "attachment", Ord: int64(len(user.Parts) + 1), Attachment: &info})
	}
	c.rec.Messages = append(c.rec.Messages, user)
	record := claudeTurnRecord{Prompt: out.uuid}
	switch {
	case c.fresh:
		record.First = true
	case !c.rec.Gap:
		record.Before = c.lastEntry
	}
	c.rec.Turns = append(c.rec.Turns, record)
	c.fresh, c.rec.Gap = false, false
	c.noteEntryLocked(out.uuid)
	c.rec.LastEntry = c.lastEntry
	c.rec.Started, c.rec.ForkFrom, c.rec.ForkAt = true, "", ""
	infoChanged := c.rec.Model != out.settings.model || c.rec.Mode != out.settings.mode || c.rec.Effort != out.settings.effort
	c.rec.Model, c.rec.Mode, c.rec.Effort = out.settings.model, out.settings.mode, out.settings.effort
	c.rec.Running = out.uuid
	c.turn = newClaudeTurn(out.uuid, out.finished)
	c.state, c.retry = "busy", nil
	c.used = now
	c.persistLocked()
	if rebuild {
		c.replaceHubLocked()
	} else {
		c.pushMessageLocked(user)
		if infoChanged {
			c.pushInfoLocked()
		}
		c.pushStateLocked()
	}
	out.waiter <- nil
	var after []func()
	if c.abortWait {
		c.abortWait = false
		c.turn.interrupted = true
		after = append(after, func() { c.sendInterrupt(proc) })
	}
	return after
}

// commitRewindLocked drops the rewound messages for good: the process now
// serving the chat resumed without them.
func (c *claudeChat) commitRewindLocked(point string) {
	if index := c.findLocked(point); index >= 0 {
		c.rec.Messages = c.rec.Messages[:index]
	}
	if index, _ := c.rec.turn(point); index >= 0 {
		c.rec.Turns = c.rec.Turns[:index]
	}
	if c.rec.Rewind == point {
		c.rec.Rewind = ""
	}
}

func (c *claudeChat) onResultLocked(frame claudeFrame) []func() {
	if c.turn == nil {
		// A result before any prompt is a startup failure (for example a
		// refused resume); spawn reports it.
		if len(frame.Errors) > 0 {
			c.startFail, _ = clipText(strings.Join(frame.Errors, "\n"), chatErrorLimit)
		}
		return nil
	}
	now := time.Now()
	// total_cost_usd is the session's; a turn costs its rise over what the
	// process started from (claude_cost.go).
	if micros := c.costRiseLocked(frame.TotalCostUSD); micros > 0 {
		for index := len(c.rec.Messages) - 1; index >= 0; index-- {
			message := &c.rec.Messages[index]
			if message.TurnID != c.turn.id || message.Role != "assistant" {
				continue
			}
			usage := ChatUsage{}
			if message.Usage != nil {
				usage = *message.Usage
			}
			total := micros
			if usage.CostMicros != nil {
				total += *usage.CostMicros
			}
			usage.CostMicros = &total
			message.Usage = &usage
			c.pushHeaderLocked(index)
			break
		}
	}
	outcome := "completed"
	switch {
	case c.turn.interrupted:
		outcome = "aborted"
	case frame.IsError:
		outcome = "error"
	}
	text := strings.TrimSpace(strings.Join(frame.Errors, "\n"))
	if text == "" || strings.HasPrefix(text, "[ede_diagnostic]") {
		text = strings.TrimSpace(frame.Result)
	}
	if text == "" {
		text = chatDefaultError
	}
	text, _ = clipText(text, chatErrorLimit)
	return c.finishTurnLocked(outcome, ChatError{Code: claudeErrorCode(frame.Subtype), Message: text}, now)
}

// finishTurnLocked ends the running turn: unfinished replies and tools
// settle, a stopped or failed turn gets a reply that says so when it has
// none, pending requests are gone and the chain records the turn's end.
func (c *claudeChat) finishTurnLocked(outcome string, failure ChatError, now time.Time) []func() {
	turn := c.turn
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
			tool.Status, tool.Error = "error", "The turn ended before this tool finished."
			part.Tool = &tool
			part.End = chatTimeOf(now)
			c.putPartLocked(index, part)
		}
		if message.Status == "streaming" {
			message.Status = "complete"
			if outcome == "aborted" {
				message.Status = "aborted"
			} else if outcome == "error" {
				message.Status, message.Error = "error", &ChatError{Code: failure.Code, Message: failure.Message}
			}
			message.CompletedAt = chatTimeOf(now)
			c.pushHeaderLocked(index)
		}
		aborted = aborted || message.Status == "aborted"
	}
	switch {
	case outcome == "aborted" && !aborted:
		message := c.newAssistantLocked(turn.id, "aborted", now)
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
	case outcome == "error" && (last < 0 || c.rec.Messages[last].Status != "error"):
		message := c.newAssistantLocked(turn.id, "error", now)
		message.Error = &ChatError{Code: failure.Code, Message: failure.Message}
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
	}
	for _, ask := range c.asks {
		id := ask.id
		c.push(func(hc *hubChat, touched uint64) { hc.resolveInteraction(id, "gone", touched) })
	}
	c.asks = nil
	if _, record := c.rec.turn(turn.id); record != nil {
		record.Last = c.lastEntry
	}
	c.rec.LastEntry = c.lastEntry
	c.rec.Running = ""
	c.turn = nil
	c.state, c.retry = "idle", nil
	c.used = now
	c.persistLocked()
	c.pushStateLocked()
	c.armIdleTimerLocked()
	if turn.finished != nil {
		return []func(){turn.finished}
	}
	return nil
}

func (c *claudeChat) onSystemLocked(proc *claudeProcess, frame claudeFrame) []func() {
	switch frame.Subtype {
	case "init":
		// Every chat runs on the Claude subscription only
		// (chat_subscription.go): a process that says it uses an API key is
		// ended at once, and the turn says why.
		if !c.engine.options.apiKeyAllowed && !claudeKeySourceAllowed(frame.APIKeySource) {
			c.keyRefused = true
			return []func(){proc.kill}
		}
		if claudeUUIDPattern.MatchString(frame.SessionID) && frame.SessionID != c.native {
			// A forked session's new ID.
			c.native = frame.SessionID
		}
		c.modeChangedLocked(frame.PermissionMode)
	case "status":
		c.modeChangedLocked(frame.PermissionMode)
	case "api_retry":
		if c.turn == nil {
			return nil
		}
		message := "The provider did not answer; Claude Code is retrying."
		if kind := claudeString(frame.Error); kind != "" {
			message = fmt.Sprintf("The provider answered %q; Claude Code is retrying.", kind)
		}
		if frame.ErrorStatus != nil {
			message = fmt.Sprintf("The provider answered HTTP %d; Claude Code is retrying.", *frame.ErrorStatus)
		}
		next := time.Now().Add(time.Duration(frame.RetryDelayMs * float64(time.Millisecond)))
		c.state = "retry"
		c.retry = &ChatRetry{Attempt: frame.Attempt, NextAt: chatTimeOf(next), Message: message}
		c.pushStateLocked()
	case "session_state_changed":
		if frame.State == "running" && c.turn != nil && c.state == "idle" {
			c.state = "busy"
			c.pushStateLocked()
		}
	case "compact_boundary":
		c.noteEntryLocked(frame.UUID)
		if c.turn == nil {
			return nil
		}
		message := c.newAssistantLocked(c.turn.id, "complete", time.Now())
		message.Parts = []ChatPart{{ID: message.ID + ":0", Kind: "notice", Ord: 1, Text: "The conversation was compacted to fit the model's context."}}
		c.rec.Messages = append(c.rec.Messages, message)
		c.pushMessageLocked(message)
	}
	return nil
}

// modeChangedLocked follows the permission mode Claude Code reports, which
// changes when the user approves leaving plan mode or accepts a mode.
func (c *claudeChat) modeChangedLocked(mode string) {
	if !validClaudeMode(mode) {
		return
	}
	if c.proc != nil {
		c.launched.settings.mode = mode
	}
	if mode != c.rec.Mode {
		c.rec.Mode = mode
		c.pushInfoLocked()
	}
}
