package host

import (
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"unicode"
)

type ChatModel struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Provider      string `json:"provider"`
	ContextWindow int    `json:"contextWindow,omitempty"`

	// Reasoning efforts (Codex model/list), when the model lists them.
	Efforts       []string `json:"efforts,omitempty"`
	DefaultEffort string   `json:"defaultEffort,omitempty"`
}
type ChatOptions struct {
	Models       []ChatModel `json:"models"`
	DefaultModel string      `json:"defaultModel"`
	Agents       []string    `json:"agents"`

	// Chat modes (Codex's approval presets), when the provider has them.
	Modes       []ChatMode `json:"modes,omitempty"`
	DefaultMode string     `json:"defaultMode,omitempty"`
}

// ChatMode is one mode a chat can run in.
type ChatMode struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type PromptOptions struct {
	Model string `json:"model,omitempty"`
	Agent string `json:"agent,omitempty"`
	// MessageID is the host-generated ID for the user message. OpenCode
	// stores the prompt under it, so a send can be matched to its message.
	MessageID string `json:"-"`

	// Codex streaming: a mode and reasoning effort for this and later turns.
	Mode   string `json:"-"`
	Effort string `json:"-"`

	// Plain chats (plain_chats.go): the system text OpenCode adds to this
	// prompt (the memory's entries). Only openCodeProvider.send sets it, with
	// the chat agent, for a plain chat.
	System string `json:"-"`
}
type ChatStatus struct {
	State string `json:"state"`
}
type ConfigurableAgent interface {
	ChatOptions(Project) (ChatOptions, error)
	ChatStatus(Project, string) (ChatStatus, error)
	PromptConfigured(Project, string, string, PromptOptions) error
}

func validPromptOptions(options PromptOptions) bool {
	if options.Agent != "" && options.Agent != "build" && options.Agent != "plan" {
		return false
	}
	if options.Model == "" {
		return true
	}
	if len(options.Model) > 512 || strings.IndexFunc(options.Model, unicode.IsSpace) >= 0 || strings.IndexFunc(options.Model, unicode.IsControl) >= 0 {
		return false
	}
	provider, model, ok := strings.Cut(options.Model, "/")
	return ok && provider != "" && model != ""
}

// validSendOptions is what OpenCode is sent: a device's options, which
// validPromptOptions checks, or the chat agent that openCodeProvider.send
// gives every plain-chat prompt. Devices can never choose the chat agent.
func validSendOptions(options PromptOptions) bool {
	if options.Agent == plainChatAgent {
		options.Agent = ""
	}
	return validPromptOptions(options)
}

func (a *OpenCodeAdapter) ChatOptions(p Project) (ChatOptions, error) {
	var catalog struct {
		All []struct {
			ID, Name string
			Models   map[string]struct {
				ID, Name string
				Limit    struct{ Context int }
			}
		}
		Connected []string
	}
	// The upstream catalog is ~6 MiB; expose only connected model display fields.
	if err := a.doLimited("GET", "/provider", p, nil, &catalog, 12<<20); err != nil {
		return ChatOptions{}, err
	}
	connected := map[string]bool{}
	for _, id := range catalog.Connected {
		connected[id] = true
	}
	result := ChatOptions{Models: []ChatModel{}, Agents: []string{"build", "plan"}}
	for _, provider := range catalog.All {
		if !connected[provider.ID] {
			continue
		}
		for _, model := range provider.Models {
			id := provider.ID + "/" + model.ID
			if !validPromptOptions(PromptOptions{Model: id}) || len(model.Name) > 200 || len(provider.Name) > 200 {
				continue
			}
			result.Models = append(result.Models, ChatModel{ID: id, Name: model.Name, Provider: provider.Name, ContextWindow: model.Limit.Context})
		}
	}
	sort.Slice(result.Models, func(i, j int) bool {
		if result.Models[i].Provider == result.Models[j].Provider {
			return result.Models[i].Name < result.Models[j].Name
		}
		return result.Models[i].Provider < result.Models[j].Provider
	})
	var config struct{ Model string }
	if err := a.do("GET", "/config", p, nil, &config); err != nil {
		return ChatOptions{}, err
	}
	for _, model := range result.Models {
		if model.ID == config.Model {
			result.DefaultModel = model.ID
			break
		}
	}
	if result.DefaultModel == "" && len(result.Models) > 0 {
		result.DefaultModel = result.Models[0].ID
	}
	return result, nil
}
func (a *OpenCodeAdapter) ChatStatus(p Project, id string) (ChatStatus, error) {
	var statuses map[string]struct{ Type string }
	if err := a.do("GET", "/session/status", p, nil, &statuses); err != nil {
		return ChatStatus{}, err
	}
	state := statuses[id].Type
	if state == "" {
		state = "idle"
	}
	if state != "idle" && state != "busy" && state != "retry" {
		state = "unknown"
	}
	return ChatStatus{State: state}, nil
}
func (a *OpenCodeAdapter) PromptConfigured(p Project, id, text string, options PromptOptions) error {
	if !validSendOptions(options) {
		return errors.New("invalid prompt options")
	}
	body := map[string]any{"parts": []any{map[string]string{"type": "text", "text": text}}}
	if options.MessageID != "" {
		body["messageID"] = options.MessageID
	}
	if options.Model != "" {
		provider, model, _ := strings.Cut(options.Model, "/")
		body["model"] = map[string]string{"providerID": provider, "modelID": model}
	}
	if options.Agent != "" {
		body["agent"] = options.Agent
	}
	// Plain chats: OpenCode 1.18.31's prompt system text.
	if options.System != "" {
		body["system"] = options.System
	}
	return a.do("POST", "/session/"+url.PathEscape(id)+"/prompt_async", p, body, nil)
}
func (h *Host) chatOptions(w http.ResponseWriter, r *http.Request) {
	p, err := h.chatProject(r.URL.Query().Get("projectId"))
	if err != nil {
		notFound(w)
		return
	}
	// Plain chats select the same runtime as their session, without coding modes.
	if h.isPlainChat(p) {
		provider := r.URL.Query().Get("provider")
		if provider == "" {
			provider = "opencode"
		}
		id := r.URL.Query().Get("sessionId")
		if id != "" {
			session, err := h.session(p, id)
			if err != nil {
				notFound(w)
				return
			}
			provider = session.Provider
			if provider == "" {
				provider = "opencode"
			}
		}
		// Only OpenCode's chat agent still runs here: plainProviderReady
		// refuses the space's read-only Claude Code and Codex chats.
		if provider != "opencode" {
			h.plainProviderReady(w, r, provider)
			return
		}
		result := ChatOptions{Models: []ChatModel{}}
		if agent, ok := h.agent.(ConfigurableAgent); ok {
			result, err = agent.ChatOptions(p)
			if err != nil {
				internal(w)
				return
			}
		}
		result.Agents, result.Modes, result.DefaultMode = []string{}, nil, ""
		writeJSON(w, 200, result)
		return
	}
	// Subscriptions only, for every Claude Code and Codex chat: a new
	// chat's provider, or the chat's own.
	provider := r.URL.Query().Get("provider")
	if id := r.URL.Query().Get("sessionId"); id != "" {
		provider = cliChatProvider(id)
	}
	if !h.chatProviderReady(w, r, p, provider) {
		return
	}
	// Codex streaming: ?provider=codex lists what a new Codex chat can use.
	if r.URL.Query().Get("provider") == "codex" && r.URL.Query().Get("sessionId") == "" {
		if result, ok, _ := h.cliChats.codexOptions(p, ""); ok {
			writeJSON(w, 200, result)
			return
		}
	}
	// Claude Code streaming: ?provider=claude lists what a new Claude chat
	// can use (models from initialize, permission modes, efforts).
	if r.URL.Query().Get("provider") == "claude" && r.URL.Query().Get("sessionId") == "" && h.cliChats != nil && h.cliChats.claude != nil {
		writeJSON(w, 200, h.cliChats.claude.chatOptions(p))
		return
	}
	// ACP chats: ?provider=<agent> lists what a new chat of that agent takes.
	if provider := r.URL.Query().Get("provider"); provider != "" && r.URL.Query().Get("sessionId") == "" && h.cliChats != nil && h.cliChats.acp.offers(provider) {
		writeJSON(w, 200, h.cliChats.acp.newChatOptions(provider))
		return
	}
	if id := r.URL.Query().Get("sessionId"); isCLISessionID(id) {
		if h.cliChats == nil {
			notFound(w)
			return
		}
		result, err := h.cliChats.Options(p, id)
		if err != nil {
			notFound(w)
			return
		}
		writeJSON(w, 200, result)
		return
	}
	agent, ok := h.agent.(ConfigurableAgent)
	if !ok {
		writeJSON(w, 200, ChatOptions{Models: []ChatModel{}, Agents: []string{}})
		return
	}
	result, err := agent.ChatOptions(p)
	if err != nil {
		internal(w)
		return
	}
	writeJSON(w, 200, result)
}
func (h *Host) chatStatus(w http.ResponseWriter, r *http.Request) {
	p, s, ok := h.chatScoped(w, r.URL.Query().Get("projectId"), r.URL.Query().Get("sessionId"))
	if !ok {
		return
	}
	if isCLISessionID(s.ID) {
		result, err := h.cliChats.Status(p, s.ID)
		if err != nil {
			internal(w)
			return
		}
		writeJSON(w, 200, result)
		return
	}
	agent, ok := h.agent.(ConfigurableAgent)
	if !ok {
		writeJSON(w, 200, ChatStatus{State: "unknown"})
		return
	}
	result, err := agent.ChatStatus(p, s.ID)
	if err != nil {
		internal(w)
		return
	}
	writeJSON(w, 200, result)
}
