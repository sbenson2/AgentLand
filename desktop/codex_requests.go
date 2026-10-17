package host

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Requests Codex waits on: approvals become permission interactions and
// questions become question interactions, answered through the host.

// codexPending is a request Codex waits on: an approval or a question. Its
// interaction ID is what devices answer.
type codexPending struct {
	id          string
	conn        *codexConn
	rpcID       json.RawMessage
	key         sessionKey
	kind        string // permission or question
	interaction ChatInteraction
	decisions   map[string]any // permission reply → result sent to Codex
	legacy      PermissionRequest
	questions   []codexQuestion
}

// codexQuestion is one question of item/tool/requestUserInput. isOther
// allows a free answer; isSecret asks clients to mask it.
type codexQuestion struct {
	ID       string                `json:"id"`
	Header   string                `json:"header"`
	Question string                `json:"question"`
	IsOther  bool                  `json:"isOther"`
	IsSecret bool                  `json:"isSecret"`
	Options  []codexQuestionOption `json:"options"`
	info     QuestionInfo
}

type codexQuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description"`
}

// codexRequest takes a request Codex waits on. Approvals and questions
// become interactions; anything else, or a request for a turn this host is
// not running, is refused at once so Codex never waits for an answer.
func (e *codexEngine) codexRequest(conn *codexConn, id json.RawMessage, method string, params json.RawMessage) {
	e.touch()
	switch method {
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput":
		if e.addRequest(conn, id, method, params) {
			return
		}
	}
	go conn.respondError(id, -32601, "AgentLand does not handle "+method)
}

func (e *codexEngine) addRequest(conn *codexConn, id json.RawMessage, method string, params json.RawMessage) bool {
	var base struct {
		ThreadID  string `json:"threadId"`
		TurnID    string `json:"turnId"`
		ItemID    string `json:"itemId"`
		Reason    string `json:"reason"`
		Command   string `json:"command"`
		Cwd       string `json:"cwd"`
		GrantRoot string `json:"grantRoot"`
		Actions   []struct {
			Command string `json:"command"`
		} `json:"commandActions"`
		Available   []json.RawMessage `json:"availableDecisions"`
		Permissions json.RawMessage   `json:"permissions"`
		Questions   []codexQuestion   `json:"questions"`
	}
	if json.Unmarshal(params, &base) != nil {
		return false
	}
	c := e.chats
	c.mu.Lock()
	defer c.mu.Unlock()
	turn, record := e.turnForLocked(conn, base.ThreadID, base.TurnID, false)
	if turn == nil {
		return false
	}
	now := time.Now()
	pending := &codexPending{id: "codex_" + cliMessageID(), conn: conn, rpcID: id, key: turn.key}
	interaction := ChatInteraction{ID: pending.id, ChatID: turn.sessionID, CreatedAt: chatTimeOf(now)}
	reason, _ := clipText(strings.TrimSpace(base.Reason), chatShortLimit)
	switch method {
	case "item/commandExecution/requestApproval":
		title := base.Command
		if len(base.Actions) > 0 {
			commands := []string{}
			for _, action := range base.Actions {
				if action.Command != "" {
					commands = append(commands, action.Command)
				}
			}
			if len(commands) > 0 {
				title = strings.Join(commands, " && ")
			}
		}
		pending.decisions = codexCommandDecisions(base.Available)
		interaction.Permission = &ChatPermission{Tool: "Command", Title: title, Detail: reason, Input: base.Command}
		pending.legacy = PermissionRequest{Permission: "command", Patterns: []string{title}}
	case "item/fileChange/requestApproval":
		title, input := "Edit files", base.GrantRoot
		if message, index := e.findPartLocked(record, turn, base.ItemID); message != nil && message.Parts[index].Tool != nil {
			title, input = message.Parts[index].Tool.Title, message.Parts[index].Tool.Input
		}
		pending.decisions = map[string]any{"once": map[string]any{"decision": "accept"}, "always": map[string]any{"decision": "acceptForSession"}, "reject": map[string]any{"decision": "decline"}}
		interaction.Permission = &ChatPermission{Tool: "Edit", Title: title, Detail: reason, Input: input}
		pending.legacy = PermissionRequest{Permission: "edit", Patterns: []string{title}}
	case "item/permissions/requestApproval":
		requested := base.Permissions
		if len(requested) == 0 || string(requested) == "null" {
			requested = json.RawMessage("{}")
		}
		pending.decisions = map[string]any{
			"once":   map[string]any{"permissions": requested, "scope": "turn"},
			"always": map[string]any{"permissions": requested, "scope": "session"},
			"reject": map[string]any{"permissions": map[string]any{}, "scope": "turn"},
		}
		interaction.Permission = &ChatPermission{Tool: "Permissions", Title: "Allow more access", Detail: reason, Input: codexJSONText(requested)}
		pending.legacy = PermissionRequest{Permission: "permissions", Patterns: []string{codexJSONText(requested)}}
	case "item/tool/requestUserInput":
		if len(base.Questions) == 0 {
			return false
		}
		pending.kind = "question"
		interaction.Kind = "question"
		interaction.Questions = []ChatQuestion{}
		for index, question := range base.Questions {
			if index == 16 {
				break
			}
			text, _ := clipText(question.Question, 4<<10)
			header, _ := clipText(question.Header, 256)
			item := ChatQuestion{ID: fmt.Sprint(index), Text: text, Header: header, Options: []ChatQuestionOption{}, Custom: question.IsOther || len(question.Options) == 0, Secret: question.IsSecret}
			info := QuestionInfo{Header: header, Question: text, Options: []QuestionOption{}, Custom: item.Custom, Secret: question.IsSecret}
			for number, option := range question.Options {
				if number == 64 {
					break
				}
				label, _ := clipText(option.Label, 512)
				description, _ := clipText(option.Description, 1<<10)
				item.Options = append(item.Options, ChatQuestionOption{Label: label, Description: description})
				info.Options = append(info.Options, QuestionOption{Label: label, Description: description})
			}
			question.info = info
			interaction.Questions = append(interaction.Questions, item)
			pending.questions = append(pending.questions, question)
		}
	}
	if pending.kind == "" {
		pending.kind = "permission"
		interaction.Kind = "permission"
		for _, choice := range []string{"once", "always", "reject"} {
			if _, ok := pending.decisions[choice]; ok {
				interaction.Choices = append(interaction.Choices, choice)
			}
		}
		if always, ok := pending.decisions["always"].(map[string]any); ok {
			interaction.AlwaysLabel, interaction.AlwaysDetail = codexAlways(method, always)
		}
		if interaction.Permission.Title == "" {
			interaction.Permission.Title = interaction.Permission.Tool
		}
		interaction.Permission.Title, _ = clipText(interaction.Permission.Title, chatShortLimit)
		interaction.Permission.Input, _ = clipText(interaction.Permission.Input, 16<<10)
		pending.legacy.ID, pending.legacy.SessionID = pending.id, turn.sessionID
		details, _ := json.Marshal(map[string]string{"description": reason})
		pending.legacy.Details = string(details)
	}
	pending.interaction = interaction
	e.requests[pending.id] = pending
	e.hubLocked().codexInteraction(turn.key, interaction)
	return true
}

// codexCommandDecisions offers exactly the decisions Codex lists in
// availableDecisions: accept is once; acceptForSession, or else a saved
// command rule (acceptWithExecpolicyAmendment), is always; decline, or else
// cancel (which also stops the turn), is reject. Without the list Codex's
// usual three are offered.
func codexCommandDecisions(available []json.RawMessage) map[string]any {
	if len(available) == 0 {
		return map[string]any{"once": map[string]any{"decision": "accept"}, "always": map[string]any{"decision": "acceptForSession"}, "reject": map[string]any{"decision": "decline"}}
	}
	candidates := map[string]json.RawMessage{}
	for _, raw := range available {
		var name string
		if json.Unmarshal(raw, &name) == nil {
			if _, seen := candidates[name]; !seen {
				candidates[name] = raw
			}
			continue
		}
		var object map[string]json.RawMessage
		if json.Unmarshal(raw, &object) != nil {
			continue
		}
		for key, value := range object {
			if key == "applyNetworkPolicyAmendment" {
				var amendment struct {
					Amendment struct {
						Action string `json:"action"`
					} `json:"network_policy_amendment"`
				}
				_ = json.Unmarshal(value, &amendment)
				key += ":" + amendment.Amendment.Action
			}
			if _, seen := candidates[key]; !seen {
				candidates[key] = raw
			}
		}
	}
	decisions := map[string]any{}
	pick := func(choice string, names ...string) {
		for _, name := range names {
			if raw, ok := candidates[name]; ok {
				decisions[choice] = map[string]any{"decision": raw}
				return
			}
		}
	}
	pick("once", "accept")
	pick("always", "acceptForSession", "acceptWithExecpolicyAmendment", "applyNetworkPolicyAmendment:allow")
	pick("reject", "decline", "cancel", "applyNetworkPolicyAmendment:deny")
	return decisions
}

// replyPermission answers an approval with one of the choices it offers.
func (e *codexEngine) replyPermission(project Project, sessionID, requestID, reply string) error {
	c := e.chats
	c.mu.Lock()
	pending := e.requests[requestID]
	if pending == nil || pending.kind != "permission" || pending.key != (sessionKey{project.ID, sessionID}) {
		c.mu.Unlock()
		return ErrNotFound
	}
	result, ok := pending.decisions[reply]
	if !ok {
		c.mu.Unlock()
		return errCodexChoice
	}
	delete(e.requests, requestID)
	e.hubLocked().codexResolved(pending.key, requestID, reply)
	c.mu.Unlock()
	// A write that fails means the process is gone; its turn ends with it.
	_ = pending.conn.respond(pending.rpcID, result)
	return nil
}

// replyQuestion answers each question in order. Answers are passed to Codex
// and never stored, so secret answers stay out of the transcript and state.
func (e *codexEngine) replyQuestion(project Project, sessionID, requestID string, answers [][]string, reject bool) error {
	c := e.chats
	c.mu.Lock()
	pending := e.requests[requestID]
	if pending == nil || pending.kind != "question" || pending.key != (sessionKey{project.ID, sessionID}) {
		c.mu.Unlock()
		return ErrNotFound
	}
	result := map[string]any{"answers": map[string]any{}}
	outcome := "rejected"
	if !reject {
		if len(answers) != len(pending.questions) {
			c.mu.Unlock()
			return errCodexChoice
		}
		byID := map[string]any{}
		for index, question := range pending.questions {
			byID[question.ID] = map[string]any{"answers": answers[index]}
		}
		result = map[string]any{"answers": byID}
		outcome = "answered"
	}
	delete(e.requests, requestID)
	e.hubLocked().codexResolved(pending.key, requestID, outcome)
	c.mu.Unlock()
	_ = pending.conn.respond(pending.rpcID, result)
	return nil
}

// pendingRequests lists a chat's waiting approvals and questions in the
// legacy GET /v1/interactions shape.
func (e *codexEngine) pendingRequests(project Project, sessionID string) ([]PermissionRequest, []QuestionRequest) {
	c := e.chats
	c.mu.Lock()
	defer c.mu.Unlock()
	permissions := []PermissionRequest{}
	questions := []QuestionRequest{}
	key := sessionKey{project.ID, sessionID}
	for _, pending := range e.orderedRequestsLocked(key) {
		switch pending.kind {
		case "permission":
			permissions = append(permissions, pending.legacy)
		case "question":
			request := QuestionRequest{ID: pending.id, SessionID: sessionID, Questions: []QuestionInfo{}}
			for _, question := range pending.questions {
				request.Questions = append(request.Questions, question.info)
			}
			questions = append(questions, request)
		}
	}
	return permissions, questions
}

func (e *codexEngine) orderedRequestsLocked(key sessionKey) []*codexPending {
	result := []*codexPending{}
	for _, pending := range e.requests {
		if pending.key == key {
			result = append(result, pending)
		}
	}
	for i := 1; i < len(result); i++ {
		for j := i; j > 0 && result[j].interaction.CreatedAt < result[j-1].interaction.CreatedAt; j-- {
			result[j], result[j-1] = result[j-1], result[j]
		}
	}
	return result
}
