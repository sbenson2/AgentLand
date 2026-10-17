package host

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
)

// Claude Code asks through can_use_tool control requests (it runs with
// --permission-prompt-tool stdio; without it every request is denied). The
// host holds them as interactions: AskUserQuestion becomes a question,
// everything else (ExitPlanMode with its plan included) a permission.
//
// A plan approval's detail is the plan. Claude Code 2.1.296 replaces
// ExitPlanMode's input with the plan file it had the model write in plan
// mode ({"plan": <the file>, "planFilePath": …}) and drops a plan the model
// put in the call itself, so without a plan file the request's input is {}.
// The plan is then taken from the model's own tool call (the tool part's
// input, as older versions sent it), and failing both the card says the
// plan was not sent (claudePlanNotSent).

type claudeToolRequest struct {
	Subtype               string          `json:"subtype"`
	ToolName              string          `json:"tool_name"`
	DisplayName           string          `json:"display_name"`
	Input                 json.RawMessage `json:"input"`
	Description           string          `json:"description"`
	Title                 string          `json:"title"`
	PermissionSuggestions json.RawMessage `json:"permission_suggestions"`
	BlockedPath           string          `json:"blocked_path"`
	DecisionReason        string          `json:"decision_reason"`
	ToolUseID             string          `json:"tool_use_id"`
}

// claudeAsk is one pending can_use_tool request. Answers are passed on and
// never kept.
type claudeAsk struct {
	id          string
	proc        *claudeProcess
	interaction ChatInteraction
	input       json.RawMessage
	suggestions json.RawMessage
	toolUseID   string
	tool        string
	question    bool
	questions   []QuestionInfo
	texts       []string
}

func claudeHasSuggestions(raw json.RawMessage) bool {
	var suggestions []json.RawMessage
	return json.Unmarshal(raw, &suggestions) == nil && len(suggestions) > 0
}

// claudeQuestions reads AskUserQuestion's 1-4 questions.
func claudeQuestions(input json.RawMessage) ([]QuestionInfo, []string, bool) {
	var body struct {
		Questions []struct {
			Question string `json:"question"`
			Header   string `json:"header"`
			Options  []struct {
				Label       string `json:"label"`
				Description string `json:"description"`
			} `json:"options"`
			MultiSelect bool `json:"multiSelect"`
		} `json:"questions"`
	}
	if json.Unmarshal(input, &body) != nil || len(body.Questions) == 0 || len(body.Questions) > 4 {
		return nil, nil, false
	}
	questions := make([]QuestionInfo, 0, len(body.Questions))
	texts := make([]string, 0, len(body.Questions))
	for _, question := range body.Questions {
		if strings.TrimSpace(question.Question) == "" {
			return nil, nil, false
		}
		text, _ := clipText(question.Question, 4<<10)
		header, _ := clipText(question.Header, 256)
		info := QuestionInfo{Question: text, Header: header, Options: []QuestionOption{}, Multiple: question.MultiSelect, Custom: true}
		for index, option := range question.Options {
			if index == 16 {
				break
			}
			label, _ := clipText(option.Label, 512)
			description, _ := clipText(option.Description, 1<<10)
			info.Options = append(info.Options, QuestionOption{Label: label, Description: description})
		}
		questions = append(questions, info)
		// Answers are keyed by the full question text.
		texts = append(texts, question.Question)
	}
	return questions, texts, true
}

func newClaudeAsk(chatID, id string, request claudeToolRequest, proc *claudeProcess, now time.Time) *claudeAsk {
	ask := &claudeAsk{id: id, proc: proc, input: request.Input, suggestions: request.PermissionSuggestions, toolUseID: request.ToolUseID, tool: request.ToolName}
	if len(ask.input) == 0 || string(ask.input) == "null" {
		ask.input = json.RawMessage("{}")
	}
	created := chatTimeOf(now)
	if request.ToolName == "AskUserQuestion" {
		if questions, texts, ok := claudeQuestions(request.Input); ok {
			ask.question, ask.questions, ask.texts = true, questions, texts
			interaction := ChatInteraction{ID: id, ChatID: chatID, Kind: "question", CreatedAt: created, Questions: []ChatQuestion{}}
			for index, question := range questions {
				item := ChatQuestion{ID: strconv.Itoa(index), Text: question.Question, Header: question.Header, Options: []ChatQuestionOption{}, Multiple: question.Multiple, Custom: true}
				for _, option := range question.Options {
					item.Options = append(item.Options, ChatQuestionOption{Label: option.Label, Description: option.Description})
				}
				interaction.Questions = append(interaction.Questions, item)
			}
			ask.interaction = interaction
			return ask
		}
	}
	tool, _ := clipText(request.ToolName, 256)
	permission := ChatPermission{Tool: tool}
	if request.ToolName == "ExitPlanMode" {
		var input struct {
			Plan string `json:"plan"`
		}
		_ = json.Unmarshal(request.Input, &input)
		permission.Title = "Leave plan mode and start on this plan?"
		permission.Detail, _ = clipText(input.Plan, 16<<10)
	} else {
		title := request.Title
		for _, candidate := range []string{request.Description, claudeToolTitle(request.Input), request.DisplayName, request.ToolName} {
			if strings.TrimSpace(title) == "" {
				title = candidate
			}
		}
		permission.Title, _ = clipText(strings.TrimSpace(title), chatShortLimit)
		detail := strings.TrimSpace(request.DecisionReason)
		if detail == "" && request.BlockedPath != "" {
			detail = "Path: " + request.BlockedPath
		}
		permission.Detail, _ = clipText(detail, chatShortLimit)
		if input, _ := claudeCompactJSON(request.Input); input != "" {
			permission.Input, _ = clipText(input, 16<<10)
		}
	}
	ask.interaction = ChatInteraction{ID: id, ChatID: chatID, Kind: "permission", CreatedAt: created, Choices: []string{"once", "reject"}, Permission: &permission}
	if claudeHasSuggestions(request.PermissionSuggestions) {
		// Always passes the suggestions back; the label says what they do.
		ask.interaction.Choices = []string{"once", "always", "reject"}
		ask.interaction.AlwaysLabel, ask.interaction.AlwaysDetail = claudeAlways(request.PermissionSuggestions)
	}
	return ask
}

func (c *claudeChat) onControlRequestLocked(proc *claudeProcess, frame claudeFrame) []func() {
	id := frame.RequestID
	var request claudeToolRequest
	if json.Unmarshal(frame.Request, &request) != nil || id == "" {
		if id == "" {
			return nil
		}
		return []func(){func() { _ = proc.respondError(id, "AgentLand could not read this request") }}
	}
	if request.Subtype != "can_use_tool" {
		subtype, _ := clipText(request.Subtype, 64)
		return []func(){func() { _ = proc.respondError(id, "AgentLand does not handle "+subtype+" requests") }}
	}
	for _, existing := range c.asks {
		if existing.id == id {
			return nil
		}
	}
	if len(c.asks) >= chatInteractionsLimit {
		return []func(){func() {
			_ = proc.respond(id, map[string]any{"behavior": "deny", "message": "Too many requests are waiting for the user."})
		}}
	}
	c.activeTurnLocked()
	ask := newClaudeAsk(c.id, id, request, proc, time.Now())
	if permission := ask.interaction.Permission; permission != nil && ask.tool == "ExitPlanMode" && strings.TrimSpace(permission.Detail) == "" {
		permission.Detail = c.toolCallPlanLocked(ask.toolUseID)
	}
	c.asks = append(c.asks, ask)
	c.setToolStatusLocked(ask.toolUseID, "pending")
	interaction := ask.interaction
	c.push(func(hc *hubChat, touched uint64) { hc.upsertInteraction(interaction, touched) })
	c.persistLocked()
	return nil
}

func (c *claudeChat) onControlCancelLocked(frame claudeFrame) {
	if c.removeAskLocked(frame.RequestID) != nil {
		id := frame.RequestID
		c.push(func(hc *hubChat, touched uint64) { hc.resolveInteraction(id, "gone", touched) })
	}
}

func (c *claudeChat) removeAskLocked(id string) *claudeAsk {
	for index, ask := range c.asks {
		if ask.id == id {
			c.asks = append(c.asks[:index], c.asks[index+1:]...)
			return ask
		}
	}
	return nil
}

// setToolStatusLocked shows a tool waiting for approval or running.
func (c *claudeChat) setToolStatusLocked(toolUseID, status string) {
	if toolUseID == "" || c.turn == nil {
		return
	}
	ref, ok := c.turn.tools[toolUseID]
	if !ok {
		return
	}
	index := c.findLocked(ref.message)
	if index < 0 {
		return
	}
	position := partIndex(&c.rec.Messages[index], ref.part)
	if position < 0 {
		return
	}
	part := c.rec.Messages[index].Parts[position]
	if part.Tool == nil || part.Tool.Status == status || part.Tool.Status == "completed" || part.Tool.Status == "error" {
		return
	}
	tool := *part.Tool
	tool.Status = status
	part.Tool = &tool
	c.putPartLocked(index, part)
}

// claudePlanNotSent is a plan approval's detail when Claude Code sent no plan
// with it, neither from a plan file nor in the model's call.
const claudePlanNotSent = "Claude Code did not send the plan with this request. Read it in the chat above before you approve."

// toolCallPlanLocked is the plan the model gave ExitPlanMode in its tool
// call toolUseID (the tool part's input), else claudePlanNotSent.
func (c *claudeChat) toolCallPlanLocked(toolUseID string) string {
	if toolUseID == "" || c.turn == nil {
		return claudePlanNotSent
	}
	ref, ok := c.turn.tools[toolUseID]
	if !ok {
		return claudePlanNotSent
	}
	index := c.findLocked(ref.message)
	if index < 0 {
		return claudePlanNotSent
	}
	position := partIndex(&c.rec.Messages[index], ref.part)
	if position < 0 || c.rec.Messages[index].Parts[position].Tool == nil {
		return claudePlanNotSent
	}
	var input struct {
		Plan string `json:"plan"`
	}
	if json.Unmarshal([]byte(c.rec.Messages[index].Parts[position].Tool.Input), &input) != nil || strings.TrimSpace(input.Plan) == "" {
		return claudePlanNotSent
	}
	plan, _ := clipText(input.Plan, 16<<10)
	return plan
}

func (c *claudeChat) interactionsLocked() []ChatInteraction {
	result := make([]ChatInteraction, 0, len(c.asks))
	for _, ask := range c.asks {
		result = append(result, ask.interaction)
	}
	return result
}

// pendingRequests lists the chat's requests in the legacy interaction shape.
func (c *claudeChat) pendingRequests() ([]PermissionRequest, []QuestionRequest) {
	c.mu.Lock()
	defer c.mu.Unlock()
	permissions, questions := []PermissionRequest{}, []QuestionRequest{}
	for _, ask := range c.asks {
		if ask.question {
			questions = append(questions, QuestionRequest{ID: ask.id, SessionID: c.id, Questions: append([]QuestionInfo(nil), ask.questions...)})
			continue
		}
		permission := ask.interaction.Permission
		patterns := []string{}
		if permission.Title != "" {
			patterns = append(patterns, permission.Title)
		}
		details, _ := json.Marshal(map[string]string{"description": permission.Detail, "input": permission.Input})
		permissions = append(permissions, PermissionRequest{ID: ask.id, SessionID: c.id, Permission: permission.Tool, Patterns: patterns, Details: string(details)})
	}
	return permissions, questions
}

// replyPermission answers a permission with once, always (the suggested
// rules, when Claude offered them) or reject.
func (c *claudeChat) replyPermission(id, reply string) error {
	c.mu.Lock()
	ask := c.askLocked(id)
	if ask == nil || ask.question {
		c.mu.Unlock()
		return ErrNotFound
	}
	offered := false
	for _, choice := range ask.interaction.Choices {
		offered = offered || choice == reply
	}
	if !offered {
		c.mu.Unlock()
		return errCodexChoice
	}
	var response map[string]any
	switch reply {
	case "once":
		response = map[string]any{"behavior": "allow", "updatedInput": ask.input}
	case "always":
		response = map[string]any{"behavior": "allow", "updatedInput": ask.input, "updatedPermissions": ask.suggestions}
	default:
		response = map[string]any{"behavior": "deny", "message": "The user denied this request."}
	}
	c.removeAskLocked(id)
	if reply != "reject" {
		c.setToolStatusLocked(ask.toolUseID, "running")
	}
	c.push(func(hc *hubChat, touched uint64) { hc.resolveInteraction(id, reply, touched) })
	c.mu.Unlock()
	return ask.proc.respond(id, response)
}

// replyQuestion passes the answers on as AskUserQuestion's answers: the
// question text to the chosen labels, several joined with ", ".
func (c *claudeChat) replyQuestion(id string, answers [][]string, reject bool) error {
	c.mu.Lock()
	ask := c.askLocked(id)
	if ask == nil || !ask.question {
		c.mu.Unlock()
		return ErrNotFound
	}
	var response map[string]any
	outcome := "rejected"
	if reject {
		response = map[string]any{"behavior": "deny", "message": "The user declined to answer."}
	} else {
		if !validAnswers(ask.questions, answers) {
			c.mu.Unlock()
			return errCodexChoice
		}
		chosen := map[string]string{}
		for index, text := range ask.texts {
			chosen[text] = strings.Join(answers[index], ", ")
		}
		var input map[string]json.RawMessage
		if json.Unmarshal(ask.input, &input) != nil || input == nil {
			input = map[string]json.RawMessage{}
		}
		encoded, _ := json.Marshal(chosen)
		input["answers"] = encoded
		response = map[string]any{"behavior": "allow", "updatedInput": input}
		outcome = "answered"
	}
	c.removeAskLocked(id)
	c.push(func(hc *hubChat, touched uint64) { hc.resolveInteraction(id, outcome, touched) })
	c.mu.Unlock()
	return ask.proc.respond(id, response)
}

func (c *claudeChat) askLocked(id string) *claudeAsk {
	for _, ask := range c.asks {
		if ask.id == id {
			return ask
		}
	}
	return nil
}
