package host

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
)

type PermissionRequest struct {
	ID         string   `json:"id"`
	SessionID  string   `json:"sessionId"`
	Permission string   `json:"permission"`
	Patterns   []string `json:"patterns"`
	Details    string   `json:"details"`
}

type QuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description"`
}

type QuestionInfo struct {
	Header   string           `json:"header"`
	Question string           `json:"question"`
	Options  []QuestionOption `json:"options"`
	Multiple bool             `json:"multiple"`
	Custom   bool             `json:"custom"`
	// Codex streaming: a secret answer is masked by clients and never stored.
	Secret bool `json:"secret,omitempty"`
}

type QuestionRequest struct {
	ID        string         `json:"id"`
	SessionID string         `json:"sessionId"`
	Questions []QuestionInfo `json:"questions"`
}

type InteractiveAgent interface {
	Permissions(Project) ([]PermissionRequest, error)
	Questions(Project) ([]QuestionRequest, error)
	ReplyPermission(Project, string, string) error
	ReplyQuestion(Project, string, [][]string) error
	RejectQuestion(Project, string) error
}

func (a *OpenCodeAdapter) Permissions(project Project) ([]PermissionRequest, error) {
	var pending []struct {
		ID         string          `json:"id"`
		SessionID  string          `json:"sessionID"`
		Permission string          `json:"permission"`
		Patterns   []string        `json:"patterns"`
		Metadata   json.RawMessage `json:"metadata"`
	}
	if err := a.do("GET", "/permission", project, nil, &pending); err != nil {
		return nil, err
	}
	result := make([]PermissionRequest, 0, len(pending))
	for _, request := range pending {
		patterns := request.Patterns
		if patterns == nil {
			patterns = []string{}
		}
		result = append(result, PermissionRequest{ID: request.ID, SessionID: request.SessionID, Permission: request.Permission, Patterns: patterns, Details: string(request.Metadata)})
	}
	return result, nil
}

func (a *OpenCodeAdapter) Questions(project Project) ([]QuestionRequest, error) {
	var pending []struct {
		ID        string `json:"id"`
		SessionID string `json:"sessionID"`
		Questions []struct {
			Header, Question string
			Options          []QuestionOption
			Multiple         bool
			Custom           *bool
		}
	}
	if err := a.do("GET", "/question", project, nil, &pending); err != nil {
		return nil, err
	}
	result := make([]QuestionRequest, 0, len(pending))
	for _, request := range pending {
		questions := make([]QuestionInfo, 0, len(request.Questions))
		for _, question := range request.Questions {
			options := question.Options
			if options == nil {
				options = []QuestionOption{}
			}
			questions = append(questions, QuestionInfo{Header: question.Header, Question: question.Question, Options: options, Multiple: question.Multiple, Custom: question.Custom == nil || *question.Custom})
		}
		result = append(result, QuestionRequest{ID: request.ID, SessionID: request.SessionID, Questions: questions})
	}
	return result, nil
}

func (a *OpenCodeAdapter) ReplyPermission(project Project, id, reply string) error {
	return a.interactionReply("/permission/"+url.PathEscape(id)+"/reply", project, map[string]string{"reply": reply})
}

func (a *OpenCodeAdapter) ReplyQuestion(project Project, id string, answers [][]string) error {
	return a.interactionReply("/question/"+url.PathEscape(id)+"/reply", project, map[string]any{"answers": answers})
}

func (a *OpenCodeAdapter) RejectQuestion(project Project, id string) error {
	return a.interactionReply("/question/"+url.PathEscape(id)+"/reject", project, nil)
}

func (a *OpenCodeAdapter) interactionReply(path string, project Project, body any) error {
	var accepted bool
	if err := a.do("POST", path, project, body, &accepted); err != nil {
		return err
	}
	if !accepted {
		return errors.New("OpenCode did not accept the interaction reply")
	}
	return nil
}

func (h *Host) interactive(w http.ResponseWriter) (InteractiveAgent, bool) {
	agent, ok := h.agent.(InteractiveAgent)
	if !ok {
		writeError(w, 501, "unsupported_operation", "This host does not support agent interactions")
	}
	return agent, ok
}

func (h *Host) interactions(w http.ResponseWriter, r *http.Request) {
	project, session, ok := h.chatScoped(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("sessionId"))
	if !ok {
		return
	}
	if isCLISessionID(session.ID) {
		// Codex streaming: the host holds a Codex chat's pending requests.
		if provider := h.chatProviderFor(session); isHostInteractions(provider) {
			permissions, questions := provider.(hostInteractions).pendingRequests(project)
			writeJSON(w, 200, map[string]any{"permissions": permissions, "questions": questions})
			return
		}
		writeJSON(w, 200, map[string]any{"permissions": []PermissionRequest{}, "questions": []QuestionRequest{}})
		return
	}
	agent, ok := h.interactive(w)
	if !ok {
		return
	}
	permissions, err := agent.Permissions(project)
	if err != nil {
		internal(w)
		return
	}
	questions, err := agent.Questions(project)
	if err != nil {
		internal(w)
		return
	}
	visiblePermissions := []PermissionRequest{}
	visibleQuestions := []QuestionRequest{}
	for _, permission := range permissions {
		if permission.SessionID == session.ID {
			visiblePermissions = append(visiblePermissions, permission)
		}
	}
	for _, question := range questions {
		if question.SessionID == session.ID {
			visibleQuestions = append(visibleQuestions, question)
		}
	}
	writeJSON(w, 200, map[string]any{"permissions": visiblePermissions, "questions": visibleQuestions})
}

func (h *Host) replyPermission(w http.ResponseWriter, r *http.Request) {
	var input struct {
		ProjectID string `json:"projectId"`
		SessionID string `json:"sessionId"`
		RequestID string `json:"requestId"`
		Reply     string `json:"reply"`
	}
	if !decode(w, r, &input) {
		return
	}
	if input.RequestID == "" || (input.Reply != "once" && input.Reply != "always" && input.Reply != "reject") {
		writeError(w, 400, "invalid_request", "Choose allow once, allow always or deny for a pending permission")
		return
	}
	project, session, ok := h.chatScoped(w, input.ProjectID, input.SessionID)
	if !ok {
		return
	}
	// Codex streaming: the host answers a Codex chat's approvals with one of
	// the choices the interaction offers.
	if provider := h.chatProviderFor(session); isHostInteractions(provider) {
		err := provider.replyPermission(project, input.RequestID, input.Reply)
		if errors.Is(err, errCodexChoice) {
			writeError(w, 400, "invalid_request", "This request does not offer that choice")
			return
		}
		finishInteraction(w, err)
		return
	}
	// OpenCode permissions offer once and reject.
	if input.Reply == "always" {
		writeError(w, 400, "invalid_request", "Choose allow once or deny for a pending permission")
		return
	}
	agent, ok := h.interactive(w)
	if !ok {
		return
	}
	pending, err := agent.Permissions(project)
	if err != nil {
		internal(w)
		return
	}
	for _, permission := range pending {
		if permission.ID == input.RequestID && permission.SessionID == session.ID {
			finishInteraction(w, agent.ReplyPermission(project, input.RequestID, input.Reply))
			return
		}
	}
	interactionMissing(w)
}

func (h *Host) replyQuestion(w http.ResponseWriter, r *http.Request, reject bool) {
	var input struct {
		ProjectID string     `json:"projectId"`
		SessionID string     `json:"sessionId"`
		RequestID string     `json:"requestId"`
		Answers   [][]string `json:"answers,omitempty"`
	}
	if !decode(w, r, &input) {
		return
	}
	if input.RequestID == "" || (reject && input.Answers != nil) {
		writeError(w, 400, "invalid_request", "A pending question is required; cancellation takes no answers")
		return
	}
	project, session, ok := h.chatScoped(w, input.ProjectID, input.SessionID)
	if !ok {
		return
	}
	// Codex streaming: the host answers a Codex chat's questions; answers go
	// to Codex and are never stored.
	if provider := h.chatProviderFor(session); isHostInteractions(provider) {
		_, questions := provider.(hostInteractions).pendingRequests(project)
		for _, question := range questions {
			if question.ID != input.RequestID {
				continue
			}
			switch {
			case reject:
				finishInteraction(w, provider.rejectQuestion(project, input.RequestID))
			case !validAnswers(question.Questions, input.Answers):
				writeError(w, 400, "invalid_request", "Answer every question using its allowed choices or custom text")
			default:
				finishInteraction(w, provider.replyQuestion(project, input.RequestID, input.Answers))
			}
			return
		}
		interactionMissing(w)
		return
	}
	agent, ok := h.interactive(w)
	if !ok {
		return
	}
	pending, err := agent.Questions(project)
	if err != nil {
		internal(w)
		return
	}
	for _, question := range pending {
		if question.ID != input.RequestID || question.SessionID != session.ID {
			continue
		}
		if reject {
			finishInteraction(w, agent.RejectQuestion(project, input.RequestID))
		} else if !validAnswers(question.Questions, input.Answers) {
			writeError(w, 400, "invalid_request", "Answer every question using its allowed choices or custom text")
		} else {
			finishInteraction(w, agent.ReplyQuestion(project, input.RequestID, input.Answers))
		}
		return
	}
	interactionMissing(w)
}

func validAnswers(questions []QuestionInfo, answers [][]string) bool {
	if len(questions) == 0 || len(questions) != len(answers) {
		return false
	}
	for index, question := range questions {
		selected := answers[index]
		if len(selected) == 0 || (!question.Multiple && len(selected) != 1) {
			return false
		}
		seen := map[string]bool{}
		for _, answer := range selected {
			if strings.TrimSpace(answer) == "" || seen[answer] {
				return false
			}
			seen[answer] = true
			if question.Custom {
				continue
			}
			found := false
			for _, option := range question.Options {
				if answer == option.Label {
					found = true
					break
				}
			}
			if !found {
				return false
			}
		}
	}
	return true
}

func interactionMissing(w http.ResponseWriter) {
	writeError(w, 404, "interaction_not_found", "This request is no longer pending in the selected session")
}

func finishInteraction(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrNotFound) {
		interactionMissing(w)
	} else if err != nil {
		internal(w)
	} else {
		writeJSON(w, 200, map[string]bool{"accepted": true})
	}
}
