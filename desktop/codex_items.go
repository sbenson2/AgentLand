package host

import (
	"encoding/json"
	"fmt"
	"strings"
)

// codexItem is one Codex thread item in the fields AgentLand shows. The
// app-server's camelCase items and codex exec's snake_case items decode into
// the same struct; normalize maps the exec names onto the app-server ones.
type codexItem struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Text      string          `json:"text"`
	Summary   []string        `json:"summary"`
	Content   json.RawMessage `json:"content"`
	ClientID  string          `json:"clientId"`
	Questions []struct {
		Title   string   `json:"title"`
		Options []string `json:"options"`
	} `json:"questions"`

	Command              string                     `json:"command"`
	CommandActions       []struct{ Command string } `json:"commandActions"`
	AggregatedOutput     *string                    `json:"aggregatedOutput"`
	AggregatedOutputExec *string                    `json:"aggregated_output"`
	ExitCode             *int64                     `json:"exitCode"`
	ExitCodeExec         *int64                     `json:"exit_code"`
	Status               string                     `json:"status"`

	Changes []codexFileChange `json:"changes"`

	Server       string          `json:"server"`
	Tool         string          `json:"tool"`
	Namespace    string          `json:"namespace"`
	Arguments    json.RawMessage `json:"arguments"`
	Result       json.RawMessage `json:"result"`
	Error        json.RawMessage `json:"error"`
	Message      string          `json:"message"`
	ContentItems json.RawMessage `json:"contentItems"`

	Query         string          `json:"query"`
	Action        json.RawMessage `json:"action"`
	Path          string          `json:"path"`
	RevisedPrompt string          `json:"revisedPrompt"`
	SavedPath     string          `json:"savedPath"`
	Prompt        string          `json:"prompt"`
	Review        string          `json:"review"`
	Items         []struct {
		Text      string `json:"text"`
		Completed bool   `json:"completed"`
	} `json:"items"`
}

type codexFileChange struct {
	Path string          `json:"path"`
	Kind json.RawMessage `json:"kind"`
	Diff string          `json:"diff"`
}

// kind is "add", "delete" or "update": an object in the app-server, a string
// in codex exec.
func (c codexFileChange) kind() string {
	var name string
	if json.Unmarshal(c.Kind, &name) == nil {
		return name
	}
	var object struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal(c.Kind, &object)
	return object.Type
}

var codexExecItemTypes = map[string]string{
	"agent_message":     "agentMessage",
	"command_execution": "commandExecution",
	"file_change":       "fileChange",
	"mcp_tool_call":     "mcpToolCall",
	"web_search":        "webSearch",
	"todo_list":         "todoList",
	"collab_tool_call":  "collabAgentToolCall",
	"error":             "execError",
}

var codexExecStatuses = map[string]string{"in_progress": "inProgress"}

// normalize maps codex exec's item names onto the app-server's.
func (item *codexItem) normalize() {
	if name, ok := codexExecItemTypes[item.Type]; ok {
		item.Type = name
	}
	if status, ok := codexExecStatuses[item.Status]; ok {
		item.Status = status
	}
	if item.AggregatedOutput == nil {
		item.AggregatedOutput = item.AggregatedOutputExec
	}
	if item.ExitCode == nil {
		item.ExitCode = item.ExitCodeExec
	}
}

// codexPartSpec is what one item contributes to the assistant message: a
// part of one kind and, for a finished file change, the list of files.
type codexPartSpec struct {
	kind  string // text, reasoning, tool or notice
	text  string
	tool  *ChatTool
	patch []string
}

// codexToolStatus maps Codex item statuses to the conversation model's.
func codexToolStatus(status string) string {
	switch status {
	case "completed", "approved":
		return "completed"
	case "failed", "declined", "denied", "timedOut", "aborted":
		return "error"
	case "pending":
		return "pending"
	default:
		return "running"
	}
}

// codexPart maps one item. It reports false for items a chat does not show
// (the user's own message, hooks, raw call output and sub-agent activity).
func codexPart(item codexItem) (codexPartSpec, bool) {
	switch item.Type {
	case "agentMessage", "plan":
		return codexPartSpec{kind: "text", text: codexMessageText(item)}, true
	case "reasoning":
		return codexPartSpec{kind: "reasoning", text: codexReasoningText(item)}, true
	case "commandExecution":
		return codexPartSpec{kind: "tool", tool: codexCommandTool(item)}, true
	case "fileChange":
		return codexFileChangePart(item), true
	case "mcpToolCall":
		name := item.Tool
		if item.Server != "" {
			name = item.Server + "." + item.Tool
		}
		tool := &ChatTool{Name: name, CallID: item.ID, Status: codexToolStatus(item.Status), Input: codexJSONText(item.Arguments), Output: codexMCPResult(item.Result)}
		tool.Error = codexErrorMessage(item.Error)
		if tool.Error != "" {
			tool.Status = "error"
		}
		return codexPartSpec{kind: "tool", tool: tool}, true
	case "dynamicToolCall":
		name := item.Tool
		if item.Namespace != "" {
			name = item.Namespace + "." + item.Tool
		}
		return codexPartSpec{kind: "tool", tool: &ChatTool{Name: name, CallID: item.ID, Status: codexToolStatus(item.Status), Input: codexJSONText(item.Arguments), Output: codexContentText(item.ContentItems)}}, true
	case "webSearch":
		return codexPartSpec{kind: "tool", tool: &ChatTool{Name: "WebSearch", CallID: item.ID, Status: "running", Title: item.Query, Input: codexWebSearchInput(item)}}, true
	case "imageView":
		return codexPartSpec{kind: "tool", tool: &ChatTool{Name: "ViewImage", CallID: item.ID, Status: "completed", Input: item.Path}}, true
	case "imageGeneration":
		return codexPartSpec{kind: "tool", tool: &ChatTool{Name: "ImageGeneration", CallID: item.ID, Status: codexToolStatus(item.Status), Input: item.RevisedPrompt, Output: item.SavedPath}}, true
	case "collabAgentToolCall":
		return codexPartSpec{kind: "tool", tool: &ChatTool{Name: "Agent", CallID: item.ID, Status: codexToolStatus(item.Status), Title: item.Tool, Input: item.Prompt}}, true
	case "contextCompaction":
		return codexPartSpec{kind: "notice", text: "The conversation was compacted to fit the model's context."}, true
	case "enteredReviewMode":
		return codexPartSpec{kind: "notice", text: "Review started: " + item.Review}, true
	case "exitedReviewMode":
		return codexPartSpec{kind: "notice", text: "Review finished."}, true
	case "todoList":
		steps := make([]codexPlanStep, 0, len(item.Items))
		for _, step := range item.Items {
			status := "pending"
			if step.Completed {
				status = "completed"
			}
			steps = append(steps, codexPlanStep{Step: step.Text, Status: status})
		}
		return codexPartSpec{kind: "tool", tool: codexPlanTool("", steps, item.ID)}, true
	case "execError":
		return codexPartSpec{kind: "notice", text: item.Message}, true
	}
	return codexPartSpec{}, false
}

// codexMessageText is an agent message's text, with any questions it asks
// for a reply (request_user_input_async) listed after it.
func codexMessageText(item codexItem) string {
	if len(item.Questions) == 0 {
		return item.Text
	}
	var text strings.Builder
	text.WriteString(item.Text)
	if item.Text != "" {
		text.WriteString("\n\n")
	}
	for index, question := range item.Questions {
		fmt.Fprintf(&text, "%d. %s", index+1, question.Title)
		if len(question.Options) > 0 {
			text.WriteString(" (" + strings.Join(question.Options, " / ") + ")")
		}
		text.WriteString("\n")
	}
	return strings.TrimSuffix(text.String(), "\n")
}

// codexReasoningText shows the reasoning summary, or the raw reasoning text
// when a model gives no summary.
func codexReasoningText(item codexItem) string {
	if len(item.Summary) > 0 {
		return strings.Join(item.Summary, "\n\n")
	}
	var content []string
	if json.Unmarshal(item.Content, &content) == nil && len(content) > 0 {
		return strings.Join(content, "\n\n")
	}
	return item.Text
}

func codexCommandTool(item codexItem) *ChatTool {
	tool := &ChatTool{Name: "Command", CallID: item.ID, Status: codexToolStatus(item.Status), Title: codexCommandTitle(item), Input: item.Command}
	if item.AggregatedOutput != nil {
		tool.Output = *item.AggregatedOutput
	}
	switch item.Status {
	case "failed":
		tool.Error = "The command failed."
		if item.ExitCode != nil {
			tool.Error = fmt.Sprintf("The command exited with code %d.", *item.ExitCode)
		}
	case "declined":
		tool.Error = "The command was declined."
	}
	return tool
}

// codexCommandTitle prefers Codex's parsed commands over the shell wrapper
// ("/bin/zsh -lc '…'").
func codexCommandTitle(item codexItem) string {
	parts := []string{}
	for _, action := range item.CommandActions {
		if action.Command != "" {
			parts = append(parts, action.Command)
		}
	}
	if len(parts) > 0 {
		return strings.Join(parts, " && ")
	}
	return item.Command
}

func codexFileChangePart(item codexItem) codexPartSpec {
	paths := make([]string, 0, len(item.Changes))
	lines := make([]string, 0, len(item.Changes))
	diffs := make([]string, 0, len(item.Changes))
	for _, change := range item.Changes {
		paths = append(paths, change.Path)
		lines = append(lines, change.kind()+" "+change.Path)
		if change.Diff != "" {
			diffs = append(diffs, change.Diff)
		}
	}
	title := "Edit files"
	if len(paths) == 1 {
		title = "Edit " + paths[0]
	} else if len(paths) > 1 {
		title = fmt.Sprintf("Edit %d files", len(paths))
	}
	tool := &ChatTool{Name: "Edit", CallID: item.ID, Status: codexToolStatus(item.Status), Title: title, Input: strings.Join(lines, "\n"), Output: strings.Join(diffs, "\n")}
	switch item.Status {
	case "failed":
		tool.Error = "The change could not be applied."
	case "declined":
		tool.Error = "The change was declined."
	}
	spec := codexPartSpec{kind: "tool", tool: tool}
	if item.Status == "completed" && len(paths) > 0 {
		spec.patch = paths
	}
	return spec
}

type codexPlanStep struct {
	Step   string `json:"step"`
	Status string `json:"status"`
}

// codexPlanTool shows Codex's plan as a checklist tool, like OpenCode's todo
// tool: [x] done, [~] in progress, [ ] pending.
func codexPlanTool(explanation string, steps []codexPlanStep, callID string) *ChatTool {
	lines := make([]string, 0, len(steps))
	for _, step := range steps {
		mark := "[ ]"
		switch step.Status {
		case "completed":
			mark = "[x]"
		case "inProgress":
			mark = "[~]"
		}
		lines = append(lines, mark+" "+step.Step)
	}
	return &ChatTool{Name: "Plan", CallID: callID, Status: "running", Title: "Plan", Input: explanation, Output: strings.Join(lines, "\n")}
}

func codexWebSearchInput(item codexItem) string {
	var action struct {
		Type    string   `json:"type"`
		Query   string   `json:"query"`
		Queries []string `json:"queries"`
		URL     string   `json:"url"`
		Pattern string   `json:"pattern"`
	}
	_ = json.Unmarshal(item.Action, &action)
	switch {
	case action.URL != "" && action.Pattern != "":
		return action.Pattern + " in " + action.URL
	case action.URL != "":
		return action.URL
	case len(action.Queries) > 0:
		return strings.Join(action.Queries, "\n")
	case action.Query != "":
		return action.Query
	}
	return item.Query
}

// codexJSONText shows a JSON value as compact text; empty for null.
func codexJSONText(raw json.RawMessage) string {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" || trimmed == "{}" {
		return ""
	}
	return trimmed
}

func codexErrorMessage(raw json.RawMessage) string {
	var failure struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &failure) == nil {
		return failure.Message
	}
	return ""
}

// codexMCPResult joins the text content of an MCP result; other content is
// shown as JSON.
func codexMCPResult(raw json.RawMessage) string {
	var result struct {
		Content json.RawMessage `json:"content"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return ""
	}
	return codexContentText(result.Content)
}

func codexContentText(raw json.RawMessage) string {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil {
		return codexJSONText(raw)
	}
	texts := make([]string, 0, len(items))
	for _, item := range items {
		var text struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(item, &text) == nil && text.Text != "" {
			texts = append(texts, text.Text)
		} else {
			texts = append(texts, codexJSONText(item))
		}
	}
	return strings.Join(texts, "\n")
}

// codexTokens is a Codex token breakdown: camelCase in the app-server,
// snake_case in codex exec.
type codexTokens struct {
	TotalTokens           int64 `json:"totalTokens"`
	InputTokens           int64 `json:"inputTokens"`
	CachedInputTokens     int64 `json:"cachedInputTokens"`
	CacheWriteInputTokens int64 `json:"cacheWriteInputTokens"`
	OutputTokens          int64 `json:"outputTokens"`
	ReasoningOutputTokens int64 `json:"reasoningOutputTokens"`
}

type codexExecTokens struct {
	InputTokens           int64 `json:"input_tokens"`
	CachedInputTokens     int64 `json:"cached_input_tokens"`
	CacheWriteInputTokens int64 `json:"cache_write_input_tokens"`
	OutputTokens          int64 `json:"output_tokens"`
	ReasoningOutputTokens int64 `json:"reasoning_output_tokens"`
}

func (t codexExecTokens) tokens() codexTokens {
	return codexTokens{TotalTokens: t.InputTokens + t.OutputTokens, InputTokens: t.InputTokens, CachedInputTokens: t.CachedInputTokens, CacheWriteInputTokens: t.CacheWriteInputTokens, OutputTokens: t.OutputTokens, ReasoningOutputTokens: t.ReasoningOutputTokens}
}

func (t codexTokens) minus(base codexTokens) codexTokens {
	return codexTokens{TotalTokens: t.TotalTokens - base.TotalTokens, InputTokens: t.InputTokens - base.InputTokens, CachedInputTokens: t.CachedInputTokens - base.CachedInputTokens, CacheWriteInputTokens: t.CacheWriteInputTokens - base.CacheWriteInputTokens, OutputTokens: t.OutputTokens - base.OutputTokens, ReasoningOutputTokens: t.ReasoningOutputTokens - base.ReasoningOutputTokens}
}

// usage maps Codex's counts to the conversation model's: input without the
// cached part, output without the reasoning part.
func (t codexTokens) usage() *ChatUsage {
	nonNegative := func(value int64) int64 { return max(value, 0) }
	return &ChatUsage{Input: nonNegative(t.InputTokens - t.CachedInputTokens), Output: nonNegative(t.OutputTokens - t.ReasoningOutputTokens), Reasoning: nonNegative(t.ReasoningOutputTokens), CacheRead: nonNegative(t.CachedInputTokens), CacheWrite: nonNegative(t.CacheWriteInputTokens)}
}

// codexErrorCode maps Codex's error info to the stable codes of
// docs/HOST-API.md.
func codexErrorCode(info json.RawMessage) string {
	var name string
	if json.Unmarshal(info, &name) != nil {
		var object map[string]json.RawMessage
		if json.Unmarshal(info, &object) != nil {
			return "agent_error"
		}
		for key := range object {
			name = key
		}
	}
	switch name {
	case "unauthorized":
		return "provider_auth"
	case "contextWindowExceeded":
		return "context_overflow"
	case "cyberPolicy", "misalignmentPolicyViolation":
		return "content_filter"
	case "usageLimitExceeded", "rateLimitExceeded", "serverOverloaded", "internalServerError", "badRequest", "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts":
		return "provider_error"
	}
	return "agent_error"
}
