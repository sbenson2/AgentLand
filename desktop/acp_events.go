package host

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"time"
)

// The mapping from ACP's session/update and session/request_permission to
// the unified conversation model (docs/HOST-API.md "ACP chats"). Each turn
// has one reply, continued in another message of the same turn at 256 parts.

// acpUpdate holds the members of every session/update kind the host maps.
// Pointers and raw members tell "absent" from "empty": a tool_call_update
// replaces only what it carries.
type acpUpdate struct {
	SessionUpdate string          `json:"sessionUpdate"`
	Content       json.RawMessage `json:"content"`
	ToolCallID    string          `json:"toolCallId"`
	Title         *string         `json:"title"`
	Kind          *string         `json:"kind"`
	Status        *string         `json:"status"`
	Locations     json.RawMessage `json:"locations"`
	RawInput      json.RawMessage `json:"rawInput"`
	RawOutput     json.RawMessage `json:"rawOutput"`
	Entries       []struct {
		Content string `json:"content"`
		Status  string `json:"status"`
	} `json:"entries"`
	CurrentModeID string `json:"currentModeId"`
}

// present reports a member that is there and not null.
func present(raw json.RawMessage) bool {
	return len(raw) > 0 && string(raw) != "null"
}

// acpNotification applies what the agent sends on its own.
func (c *acpChat) acpNotification(conn *acpConn, method string, params json.RawMessage) {
	if method != "session/update" {
		return
	}
	var body struct {
		SessionID string    `json:"sessionId"`
		Update    acpUpdate `json:"update"`
	}
	if json.Unmarshal(params, &body) != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != conn || c.loading || (c.session != "" && body.SessionID != c.session) {
		return
	}
	c.applyUpdateLocked(body.Update)
}

// acpRequest answers what the agent asks of the host. Only permission
// requests are served; no client capabilities are advertised, so fs/*,
// terminal/* and the rest get "method not found".
func (c *acpChat) acpRequest(conn *acpConn, id json.RawMessage, method string, params json.RawMessage) {
	if method == "session/request_permission" {
		c.permissionRequest(conn, id, params)
		return
	}
	go func() { _ = conn.respondError(id, acpMethodNotFound, "Method not found") }()
}

// acpOversized: a line over the limit breaks the protocol; the process is
// ended, which ends the turn with protocol_error.
func (c *acpChat) acpOversized(conn *acpConn) {
	conn.kill()
}

func (c *acpChat) applyUpdateLocked(update acpUpdate) {
	if update.SessionUpdate == "current_mode_update" {
		mode := update.CurrentModeID
		if mode != "" && plainAgentText(mode, 64) && mode != c.rec.Mode {
			c.rec.Mode = mode
			c.persistLocked()
			c.pushInfoLocked()
		}
		return
	}
	turn := c.turn
	if turn == nil {
		return
	}
	switch update.SessionUpdate {
	case "agent_message_chunk":
		c.chunkLocked(turn, "text", acpContentText(update.Content))
	case "agent_thought_chunk":
		c.chunkLocked(turn, "reasoning", acpContentText(update.Content))
	case "tool_call", "tool_call_update":
		c.toolLocked(turn, update)
	case "plan":
		c.planLocked(turn, update)
	}
}

// acpContentText is one content block as text: its text, or a short
// placeholder for anything else.
func acpContentText(raw json.RawMessage) string {
	var block struct {
		Type     string `json:"type"`
		Text     string `json:"text"`
		URI      string `json:"uri"`
		Resource struct {
			URI string `json:"uri"`
		} `json:"resource"`
	}
	if json.Unmarshal(raw, &block) != nil {
		return ""
	}
	switch block.Type {
	case "text":
		return block.Text
	case "image":
		return "[image]"
	case "audio":
		return "[audio]"
	case "resource_link", "resource":
		uri := block.URI
		if uri == "" {
			uri = block.Resource.URI
		}
		uri, _ = clipText(uri, 512)
		return "[resource " + uri + "]"
	}
	return ""
}

// replyLocked returns the index of the turn's reply, starting one (or the
// next, at 256 parts) when needed.
func (c *acpChat) replyLocked(turn *acpTurn) int {
	if turn.reply != "" {
		if index := c.findLocked(turn.reply); index >= 0 && len(c.rec.Messages[index].Parts) < chatPartsPerMessage {
			return index
		}
	}
	message := c.newReplyLocked(turn.id, "streaming", time.Now())
	c.rec.Messages = append(c.rec.Messages, message)
	turn.reply, turn.lastKind, turn.lastPart = message.ID, "", ""
	c.pushMessageLocked(message)
	return len(c.rec.Messages) - 1
}

// addPartLocked appends a part to the turn's reply and returns where it is.
func (c *acpChat) addPartLocked(turn *acpTurn, part ChatPart) (int, ChatPart) {
	index := c.replyLocked(turn)
	message := &c.rec.Messages[index]
	part.Ord = int64(len(message.Parts) + 1)
	part.ID = message.ID + ":" + itoa(len(message.Parts))
	if part.Start == "" {
		part.Start = chatTimeOf(time.Now())
	}
	message.Parts = append(message.Parts, part)
	c.pushPartLocked(message.ID, part)
	return index, part
}

// putPartLocked replaces a part of a message and announces it.
func (c *acpChat) putPartLocked(index int, part ChatPart) {
	message := &c.rec.Messages[index]
	if position := partIndex(message, part.ID); position >= 0 {
		if message.Parts[position] == part {
			return
		}
		message.Parts[position] = part
		c.pushPartLocked(message.ID, part)
	}
}

// noticeLocked adds a notice to the turn's reply.
func (c *acpChat) noticeLocked(turn *acpTurn, text string) {
	c.addPartLocked(turn, ChatPart{Kind: "notice", Text: text})
	turn.lastKind, turn.lastPart = "notice", ""
}

// chunkLocked adds streamed text to the reply: to the last part when it is
// of the same kind, else to a new part.
func (c *acpChat) chunkLocked(turn *acpTurn, kind, text string) {
	if text == "" {
		return
	}
	limit := chatTextLimit
	if kind == "reasoning" {
		limit = chatReasoningLimit
	}
	if turn.lastKind == kind && turn.lastPart != "" {
		if index := c.findLocked(turn.reply); index >= 0 {
			message := &c.rec.Messages[index]
			if position := partIndex(message, turn.lastPart); position >= 0 {
				part := &message.Parts[position]
				if part.Truncated {
					return
				}
				accepted, cut := clipText(text, limit-len(part.Text))
				part.Text += accepted
				part.Truncated = cut
				messageID, partID := message.ID, part.ID
				c.push(func(hc *hubChat, touched uint64) {
					hc.appendDelta(messageID, partID, "text", text, touched)
				})
				return
			}
		}
	}
	initial, cut := clipText(text, limit)
	_, part := c.addPartLocked(turn, ChatPart{Kind: kind, Text: initial, Truncated: cut})
	turn.lastKind, turn.lastPart = kind, part.ID
}

// acpToolKinds are ACP's tool kinds; a tool part is named after its kind.
var acpToolKinds = map[string]bool{"read": true, "edit": true, "delete": true, "move": true, "search": true, "execute": true, "think": true, "fetch": true, "switch_mode": true, "other": true}

func acpToolStatus(status string) string {
	switch status {
	case "pending":
		return "pending"
	case "completed":
		return "completed"
	case "failed":
		return "error"
	}
	return "running"
}

// acpShownPath is a path as the chat shows it: relative inside the
// workspace, else its name alone.
func acpShownPath(root, path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	name := path
	if filepath.IsAbs(path) {
		if relative, err := filepath.Rel(root, path); err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			name = relative
		} else {
			name = filepath.Base(path)
		}
	}
	name, _ = clipText(filepath.ToSlash(name), chatShortLimit)
	return name
}

type acpLocation struct {
	Path string `json:"path"`
	Line *int64 `json:"line,omitempty"`
}

func (c *acpChat) locations(raw json.RawMessage) []acpLocation {
	var items []struct {
		Path string `json:"path"`
		Line *int64 `json:"line"`
	}
	if json.Unmarshal(raw, &items) != nil {
		return nil
	}
	result := []acpLocation{}
	for _, item := range items {
		if len(result) == 20 {
			break
		}
		if shown := acpShownPath(c.project.Directory, item.Path); shown != "" {
			result = append(result, acpLocation{Path: shown, Line: item.Line})
		}
	}
	return result
}

// toolContentText is a tool's content as text: text blocks, diffs as unified
// diffs of the changed lines, terminals by name.
func (c *acpChat) toolContentText(raw json.RawMessage) string {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil {
		return ""
	}
	var texts []string
	for _, item := range items {
		var content struct {
			Type    string          `json:"type"`
			Content json.RawMessage `json:"content"`
			Path    string          `json:"path"`
			OldText *string         `json:"oldText"`
			NewText string          `json:"newText"`
		}
		if json.Unmarshal(item, &content) != nil {
			continue
		}
		switch content.Type {
		case "content":
			if text := acpContentText(content.Content); text != "" {
				texts = append(texts, text)
			}
		case "diff":
			texts = append(texts, acpDiffText(acpShownPath(c.project.Directory, content.Path), content.OldText, content.NewText))
		case "terminal":
			texts = append(texts, "[terminal]")
		}
	}
	return strings.Join(texts, "\n")
}

// acpDiffText shows a diff as a unified diff of the lines that changed: the
// lines both texts share at the start and the end are left out, but for up
// to three of context.
func acpDiffText(path string, oldText *string, newText string) string {
	var builder strings.Builder
	builder.WriteString("--- " + path + "\n+++ " + path + "\n")
	var oldLines []string
	if oldText != nil && *oldText != "" {
		oldLines = strings.Split(*oldText, "\n")
	}
	newLines := []string{}
	if newText != "" {
		newLines = strings.Split(newText, "\n")
	}
	prefix := 0
	for prefix < len(oldLines) && prefix < len(newLines) && oldLines[prefix] == newLines[prefix] {
		prefix++
	}
	suffix := 0
	for suffix < len(oldLines)-prefix && suffix < len(newLines)-prefix && oldLines[len(oldLines)-1-suffix] == newLines[len(newLines)-1-suffix] {
		suffix++
	}
	start := max(0, prefix-3)
	oldEnd, newEnd := len(oldLines)-suffix, len(newLines)-suffix
	contextEnd := min(len(newLines), newEnd+3)
	builder.WriteString("@@\n")
	for _, line := range newLines[start:prefix] {
		builder.WriteString(" " + line + "\n")
	}
	for _, line := range oldLines[prefix:oldEnd] {
		builder.WriteString("-" + line + "\n")
	}
	for _, line := range newLines[prefix:newEnd] {
		builder.WriteString("+" + line + "\n")
	}
	for _, line := range newLines[newEnd:contextEnd] {
		builder.WriteString(" " + line + "\n")
	}
	return strings.TrimSuffix(builder.String(), "\n")
}

// acpRawText is a raw member as text: a string as it is, anything else as
// compact JSON.
func acpRawText(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	var buffer bytes.Buffer
	if json.Compact(&buffer, raw) == nil {
		return buffer.String()
	}
	return string(raw)
}

// toolLocked applies tool_call and tool_call_update: a tool part per
// toolCallId, each update replacing only the members it carries.
func (c *acpChat) toolLocked(turn *acpTurn, update acpUpdate) {
	callID, _ := clipText(strings.TrimSpace(update.ToolCallID), 256)
	if callID == "" {
		return
	}
	state := turn.tools[callID]
	index, position := -1, -1
	if state != nil {
		if index = c.findLocked(state.message); index >= 0 {
			position = partIndex(&c.rec.Messages[index], state.part)
		}
	}
	var part ChatPart
	if position < 0 {
		var created ChatPart
		index, created = c.addPartLocked(turn, ChatPart{Kind: "tool", Tool: &ChatTool{Name: "other", CallID: callID, Status: "pending"}})
		state = &acpToolState{message: c.rec.Messages[index].ID, part: created.ID}
		turn.tools[callID] = state
		part = created
	} else {
		part = c.rec.Messages[index].Parts[position]
	}
	turn.lastKind, turn.lastPart = "tool", ""
	tool := *part.Tool
	if update.Kind != nil && acpToolKinds[*update.Kind] {
		tool.Name = *update.Kind
	}
	if update.Title != nil {
		tool.Title, _ = clipText(strings.TrimSpace(*update.Title), chatShortLimit)
	}
	if update.Status != nil {
		tool.Status = acpToolStatus(*update.Status)
	}
	inputCut, outputCut := false, false
	if present(update.RawInput) {
		tool.Input, inputCut = claudeCompactJSON(update.RawInput)
		state.hasInput = tool.Input != ""
	}
	if present(update.Locations) && !state.hasInput {
		if locations := c.locations(update.Locations); len(locations) > 0 {
			encoded, _ := json.Marshal(map[string]any{"locations": locations})
			tool.Input, inputCut = boundedToolText(string(encoded))
		}
	}
	output, hasOutput := "", false
	if update.Content != nil && present(update.Content) {
		output, hasOutput = c.toolContentText(update.Content), true
		state.hasContent = true
	}
	if !hasOutput && !state.hasContent && present(update.RawOutput) {
		output, hasOutput = acpRawText(update.RawOutput), true
	}
	if hasOutput {
		output, outputCut = boundedToolText(output)
		tool.Output, tool.Error = output, ""
	}
	if tool.Status == "error" {
		if tool.Error == "" {
			tool.Error, tool.Output = tool.Output, ""
		}
		if tool.Error == "" {
			tool.Error = "The tool failed."
		}
	}
	tool.Truncated = tool.Truncated || inputCut || outputCut
	part.Tool = &tool
	if (tool.Status == "completed" || tool.Status == "error") && part.End == "" {
		part.End = chatTimeOf(time.Now())
	}
	c.putPartLocked(index, part)
}

// planLocked shows the agent's plan as one checklist per turn, as Codex's.
func (c *acpChat) planLocked(turn *acpTurn, update acpUpdate) {
	steps := make([]codexPlanStep, 0, min(len(update.Entries), 100))
	for _, entry := range update.Entries {
		if len(steps) == 100 {
			break
		}
		text, _ := clipText(strings.TrimSpace(entry.Content), chatShortLimit)
		status := entry.Status
		if status == "in_progress" {
			status = "inProgress"
		}
		steps = append(steps, codexPlanStep{Step: text, Status: status})
	}
	tool := codexPlanTool("", steps, "plan")
	turn.lastKind, turn.lastPart = "plan", ""
	if turn.plan != "" {
		for index := len(c.rec.Messages) - 1; index >= 0; index-- {
			message := &c.rec.Messages[index]
			if position := partIndex(message, turn.plan); position >= 0 {
				part := message.Parts[position]
				part.Tool = tool
				c.putPartLocked(index, part)
				return
			}
		}
	}
	_, part := c.addPartLocked(turn, ChatPart{Kind: "tool", Tool: tool})
	turn.plan = part.ID
}

// acpPermissionOption is one choice the agent offers.
type acpPermissionOption struct {
	OptionID string `json:"optionId"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
}

// permissionRequest holds session/request_permission as an approval: the
// agent's allow_once, allow_always and reject options as once, always and
// reject. It is answered when the user replies, or cancelled. A request that
// comes once the turn was stopped (it crossed session/cancel on the wire) is
// answered cancelled at once and shows nothing.
func (c *acpChat) permissionRequest(conn *acpConn, rpcID json.RawMessage, params json.RawMessage) {
	var request struct {
		SessionID string                `json:"sessionId"`
		ToolCall  acpUpdate             `json:"toolCall"`
		Options   []acpPermissionOption `json:"options"`
	}
	cancel := func() {
		go func() { _ = conn.respond(rpcID, map[string]any{"outcome": map[string]string{"outcome": "cancelled"}}) }()
	}
	if json.Unmarshal(params, &request) != nil {
		go func() { _ = conn.respondError(rpcID, -32602, "Invalid params") }()
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	turn := c.turn
	if c.conn != conn || turn == nil || turn.interrupted || c.closed || len(c.asks) >= chatInteractionsLimit {
		cancel()
		return
	}
	choices := []string{}
	options := map[string]string{}
	alwaysName := ""
	for _, kind := range []struct{ choice, first, second string }{{"once", "allow_once", ""}, {"always", "allow_always", ""}, {"reject", "reject_once", "reject_always"}} {
		for _, wanted := range []string{kind.first, kind.second} {
			if wanted == "" || options[kind.choice] != "" {
				continue
			}
			for _, option := range request.Options {
				if option.Kind == wanted && option.OptionID != "" && len(option.OptionID) <= 256 {
					options[kind.choice] = option.OptionID
					if kind.choice == "always" {
						alwaysName = strings.TrimSpace(option.Name)
					}
					break
				}
			}
		}
		if options[kind.choice] != "" || kind.choice == "reject" {
			choices = append(choices, kind.choice)
		}
	}
	name := c.engine.agentName(c.agent)
	permission := ChatPermission{Tool: "other"}
	if request.ToolCall.Kind != nil && acpToolKinds[*request.ToolCall.Kind] {
		permission.Tool = *request.ToolCall.Kind
	}
	callID := strings.TrimSpace(request.ToolCall.ToolCallID)
	if request.ToolCall.Title != nil {
		permission.Title, _ = clipText(strings.TrimSpace(*request.ToolCall.Title), chatShortLimit)
	}
	// What the request leaves out comes from the tool it is about.
	if state := turn.tools[callID]; state != nil {
		if index := c.findLocked(state.message); index >= 0 {
			if position := partIndex(&c.rec.Messages[index], state.part); position >= 0 {
				tool := c.rec.Messages[index].Parts[position].Tool
				if permission.Title == "" {
					permission.Title = tool.Title
				}
				if request.ToolCall.Kind == nil && acpToolKinds[tool.Name] {
					permission.Tool = tool.Name
				}
			}
		}
	}
	if permission.Title == "" {
		permission.Title = name + " asks to use a tool"
	}
	if present(request.ToolCall.Locations) {
		paths := []string{}
		for _, location := range c.locations(request.ToolCall.Locations) {
			paths = append(paths, location.Path)
		}
		permission.Detail, _ = clipText(strings.Join(paths, ", "), chatShortLimit)
	}
	if present(request.ToolCall.RawInput) {
		input, _ := claudeCompactJSON(request.ToolCall.RawInput)
		permission.Input, _ = clipText(input, 16<<10)
	}
	ask := &acpAsk{id: "acp-" + cliMessageID(), rpcID: rpcID, conn: conn, options: options, toolCallID: callID}
	ask.interaction = ChatInteraction{ID: ask.id, ChatID: c.id, Kind: "permission", CreatedAt: chatTimeOf(time.Now()), Choices: choices, Permission: &permission}
	if options["always"] != "" {
		label := alwaysName
		if label == "" || !plainAgentText(label, 200) {
			label = "Allow always"
		}
		ask.interaction.AlwaysLabel = label
		ask.interaction.AlwaysDetail, _ = clipText(name+" decides what this allows and for how long.", 300)
	}
	c.asks = append(c.asks, ask)
	// The tool the request is about shows it waits.
	if callID != "" {
		update := request.ToolCall
		pending := "pending"
		update.Status = &pending
		c.toolLocked(turn, update)
	}
	interaction := ask.interaction
	c.push(func(hc *hubChat, touched uint64) { hc.upsertInteraction(interaction, touched) })
}

// replyPermission answers an approval: the agent's option for once, always
// or reject, or cancelled when it offered no reject option.
func (c *acpChat) replyPermission(id, reply string) error {
	c.mu.Lock()
	var ask *acpAsk
	for index, candidate := range c.asks {
		if candidate.id == id {
			ask = candidate
			c.asks = append(c.asks[:index], c.asks[index+1:]...)
			break
		}
	}
	if ask == nil {
		c.mu.Unlock()
		return ErrNotFound
	}
	offered := false
	for _, choice := range ask.interaction.Choices {
		offered = offered || choice == reply
	}
	if !offered {
		c.asks = append(c.asks, ask)
		c.mu.Unlock()
		return errCodexChoice
	}
	if reply != "reject" && c.turn != nil && ask.toolCallID != "" {
		running := "in_progress"
		c.toolLocked(c.turn, acpUpdate{ToolCallID: ask.toolCallID, Status: &running})
	}
	c.push(func(hc *hubChat, touched uint64) { hc.resolveInteraction(id, reply, touched) })
	c.mu.Unlock()
	outcome := map[string]string{"outcome": "cancelled"}
	if optionID := ask.options[reply]; optionID != "" {
		outcome = map[string]string{"outcome": "selected", "optionId": optionID}
	}
	return ask.conn.respond(ask.rpcID, map[string]any{"outcome": outcome})
}

// pendingRequests lists the chat's approvals in the legacy interaction shape.
func (c *acpChat) pendingRequests() ([]PermissionRequest, []QuestionRequest) {
	c.mu.Lock()
	defer c.mu.Unlock()
	permissions := []PermissionRequest{}
	for _, ask := range c.asks {
		permission := ask.interaction.Permission
		patterns := []string{}
		if permission.Title != "" {
			patterns = append(patterns, permission.Title)
		}
		details, _ := json.Marshal(map[string]string{"description": permission.Detail, "input": permission.Input})
		permissions = append(permissions, PermissionRequest{ID: ask.id, SessionID: c.id, Permission: permission.Tool, Patterns: patterns, Details: string(details)})
	}
	return permissions, []QuestionRequest{}
}
