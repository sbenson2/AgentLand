package host

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
)

var errChatUnsupported = errors.New("this chat does not support the operation")

// chatPrompt is one message to deliver. finished, when set, runs once after a
// Claude Code or Codex run that accepted the prompt ends.
type chatPrompt struct {
	text     string
	options  PromptOptions
	files    []ChatAttachment
	finished func()

	// Archive (M1 chunk B2): the user message's ID, chosen by the host
	// before delivery and already archived under it (prepareDelivery). A
	// provider that can name the user message uses it and returns it from
	// send; one that cannot returns its own ID, and the archive follows the
	// provider's copy. Empty when the host keeps no archive.
	messageID string
}

// chatLoad is one read of a chat for the hub.
type chatLoad struct {
	info     ChatInfo
	rewind   string
	messages []ChatMessage // oldest first
	hasOlder bool
	// state is the provider's activity: idle, busy or retry.
	state        string
	retry        *ChatRetry
	interactions []ChatInteraction
}

// chatProvider is one agent family behind the chat hub and the chat routes:
// OpenCode through its REST API and event stream, Claude Code and Codex
// through the host's CLI chats.
type chatProvider interface {
	// name is "opencode", "claude" or "codex".
	name() string
	// transport says how the hub learns about changes: "sse" (OpenCode's
	// live event stream), "coarse" (whole messages when a CLI run ends) or ""
	// when this host cannot stream the provider's chats.
	transport() string
	// features lists what this provider's chats support, for capabilities.
	features() []string
	options(p Project, sessionID string) (ChatOptions, error)
	create(p Project, title string) (Session, error)
	// load reads the chat: title, rewind point, the newest limit visible
	// messages (oldest first), activity and pending interactions.
	load(p Project, sessionID string, limit int) (chatLoad, error)
	// page returns up to limit visible messages older than before, newest
	// first, and whether older ones exist. An empty before starts at the newest.
	page(p Project, s Session, before string, limit int) ([]ChatMessage, bool, error)
	// send delivers one prompt and returns the user message's ID when the
	// provider knows it before the message appears.
	send(p Project, s Session, prompt chatPrompt) (string, error)
	interrupt(p Project, sessionID string) error
	replyPermission(p Project, requestID, reply string) error
	replyQuestion(p Project, requestID string, answers [][]string) error
	rejectQuestion(p Project, requestID string) error
	rewind(p Project, sessionID, messageID string) error
	restore(p Project, sessionID string) error
	// Fork arrives with POST /v1/chat/fork.
}

// chatProviderFor returns the provider behind a chat, or nil when this host
// has no provider for it.
func (h *Host) chatProviderFor(s Session) chatProvider {
	if isCLISessionID(s.ID) {
		if h.cliChats == nil {
			return nil
		}
		// ACP chats (acp_provider.go).
		if isACPSessionID(s.ID) {
			return h.cliChats.acpProviderFor(s.ID, s.Provider)
		}
		provider := "claude"
		// Claude Code streaming: Claude chats stream through the Claude engine.
		if isClaudeSessionID(s.ID) && h.cliChats.claude != nil {
			return claudeProvider{engine: h.cliChats.claude, sessionID: s.ID}
		}
		if strings.HasPrefix(s.ID, "codex:") {
			provider = "codex"
			// Codex streaming: Codex chats stream through the Codex engine.
			if h.cliChats.codex != nil {
				return codexProvider{cliProvider: cliProvider{chats: h.cliChats, provider: provider}, engine: h.cliChats.codex, sessionID: s.ID}
			}
		}
		return cliProvider{chats: h.cliChats, provider: provider}
	}
	return openCodeProvider{agent: h.agent, plain: h.plainChats}
}

// messageIDAgent accepts a host-generated ID for the user message.
type messageIDAgent interface{ acceptsMessageID() bool }

func (a *OpenCodeAdapter) acceptsMessageID() bool { return true }

// openCodeProvider runs OpenCode chats. plain, when the host has plain
// chats, is its Chats space: chats there are created with the plain-chat
// rules and every prompt runs the chat agent with the memory's system text.
type openCodeProvider struct {
	agent Agent
	plain *plainChats
}

func (o openCodeProvider) name() string { return "opencode" }

func (o openCodeProvider) transport() string {
	if _, ok := o.agent.(chatEventSource); ok {
		return "sse"
	}
	return ""
}

func (o openCodeProvider) features() []string {
	features := []string{}
	if _, ok := o.agent.(RewindableAgent); ok {
		// OpenCode's revert also restores the files changed after the message.
		features = append(features, "rewind", "restoreFiles")
	}
	if _, ok := o.agent.(InteractiveAgent); ok {
		features = append(features, "approvals", "questions")
	}
	return features
}

func (o openCodeProvider) options(p Project, _ string) (ChatOptions, error) {
	agent, ok := o.agent.(ConfigurableAgent)
	if !ok {
		return ChatOptions{Models: []ChatModel{}, Agents: []string{}}, nil
	}
	return agent.ChatOptions(p)
}

func (o openCodeProvider) create(p Project, title string) (Session, error) {
	if o.plain.isSpace(p) {
		if !o.plain.openCode.Load() {
			return Session{}, errOpenCodeChatOff
		}
		adapter, ok := o.agent.(*OpenCodeAdapter)
		if !ok {
			return Session{}, errPlainChatUnavailable
		}
		return adapter.createSessionWithRules(p, title, plainChatRules())
	}
	return o.agent.CreateSession(p, title)
}

func (o openCodeProvider) load(p Project, sessionID string, limit int) (chatLoad, error) {
	adapter, ok := o.agent.(*OpenCodeAdapter)
	if !ok {
		return o.loadLegacy(p, sessionID, limit)
	}
	session, err := adapter.GetSession(p, sessionID)
	if err != nil {
		return chatLoad{}, err
	}
	if session.ID != sessionID || !sameDirectory(p.Directory, session.Directory) {
		return chatLoad{}, ErrNotFound
	}
	result := chatLoad{info: ChatInfo{ID: sessionID, Title: session.Title, Provider: "opencode"}, rewind: session.RewindMessageID, state: "idle"}
	cursor := ""
	if session.RewindMessageID != "" {
		info, err := adapter.message(p, sessionID, session.RewindMessageID)
		if err != nil {
			return chatLoad{}, err
		}
		cursor = openCodePageCursor(info.ID, int64(info.Time.Created))
	}
	raw, more, err := adapter.messagePage(p, sessionID, limit, cursor)
	if err != nil {
		return chatLoad{}, err
	}
	result.hasOlder = more
	for _, message := range raw {
		if message.Info.Role == "user" || message.Info.Role == "assistant" {
			result.messages = append(result.messages, *messageFromOC(message, p.Directory).Unified)
		}
	}
	result.info.Model, result.info.Mode, result.info.Effort = openCodeChatSettings(raw)
	statuses, err := adapter.sessionStatuses(p)
	if err != nil {
		return chatLoad{}, err
	}
	result.state, result.retry = openCodeState(statuses[sessionID])
	if result.state == "idle" {
		// A reply that never completed in an idle chat was abandoned, for
		// example when OpenCode stopped mid-turn.
		for index := range result.messages {
			if result.messages[index].Status == "streaming" {
				result.messages[index].Status = "aborted"
			}
		}
	}
	if result.interactions, err = o.interactions(p, sessionID); err != nil {
		return chatLoad{}, err
	}
	return result, nil
}

// openCodeChatSettings reads the chat's model, mode (OpenCode agent) and
// effort (model variant) from its newest messages.
func openCodeChatSettings(messages []ocMessage) (model, mode, effort string) {
	for index := len(messages) - 1; index >= 0 && (model == "" || mode == ""); index-- {
		info := messages[index].Info
		switch info.Role {
		case "assistant":
			if model == "" && info.ProviderID != "" && info.ModelID != "" {
				model = info.ProviderID + "/" + info.ModelID
				if effort == "" {
					effort = info.Variant
				}
			}
		case "user":
			// Plain chats take no mode: the chat agent runs every prompt.
			if mode == "" && info.Agent != plainChatAgent {
				mode = info.Agent
			}
			if model == "" && info.Model.ProviderID != "" && info.Model.ModelID != "" {
				model = info.Model.ProviderID + "/" + info.Model.ModelID
				if effort == "" {
					effort = info.Model.Variant
				}
			}
		}
	}
	return model, mode, effort
}

// ocStatus is one entry of OpenCode's GET /session/status and the status of
// a session.status event.
type ocStatus struct {
	Type    string  `json:"type"`
	Attempt float64 `json:"attempt"`
	Message string  `json:"message"`
	Next    float64 `json:"next"`
}

func (a *OpenCodeAdapter) sessionStatuses(p Project) (map[string]ocStatus, error) {
	statuses := map[string]ocStatus{}
	err := a.do("GET", "/session/status", p, nil, &statuses)
	return statuses, err
}

func openCodeState(status ocStatus) (string, *ChatRetry) {
	switch status.Type {
	case "busy":
		return "busy", nil
	case "retry":
		message, _ := clipText(status.Message, chatShortLimit)
		return "retry", &ChatRetry{Attempt: int(status.Attempt), NextAt: chatTime(status.Next), Message: message}
	default:
		return "idle", nil
	}
}

func (o openCodeProvider) interactions(p Project, sessionID string) ([]ChatInteraction, error) {
	agent, ok := o.agent.(InteractiveAgent)
	if !ok {
		return nil, nil
	}
	permissions, err := agent.Permissions(p)
	if err != nil {
		return nil, err
	}
	questions, err := agent.Questions(p)
	if err != nil {
		return nil, err
	}
	var result []ChatInteraction
	now := chatTimeOf(time.Now())
	for _, permission := range permissions {
		if permission.SessionID == sessionID {
			result = append(result, chatPermissionInteraction(permission, now))
		}
	}
	for _, question := range questions {
		if question.SessionID == sessionID {
			result = append(result, chatQuestionInteraction(question, now))
		}
	}
	return result, nil
}

// chatPermissionInteraction maps a pending permission. Only once and reject
// are offered: POST /v1/permissions/reply does not accept always yet.
func chatPermissionInteraction(request PermissionRequest, created string) ChatInteraction {
	title, _ := clipText(strings.Join(request.Patterns, ", "), chatShortLimit)
	var metadata struct {
		Description string `json:"description"`
	}
	_ = json.Unmarshal([]byte(request.Details), &metadata)
	detail, _ := clipText(metadata.Description, chatShortLimit)
	input := ""
	if request.Details != "" && request.Details != "{}" && request.Details != "null" {
		input, _ = clipText(request.Details, 16<<10)
	}
	return ChatInteraction{ID: request.ID, ChatID: request.SessionID, Kind: "permission", CreatedAt: created, Choices: []string{"once", "reject"}, Permission: &ChatPermission{Tool: request.Permission, Title: title, Detail: detail, Input: input}}
}

func chatQuestionInteraction(request QuestionRequest, created string) ChatInteraction {
	result := ChatInteraction{ID: request.ID, ChatID: request.SessionID, Kind: "question", CreatedAt: created, Questions: []ChatQuestion{}}
	for index, question := range request.Questions {
		if index == 16 {
			break
		}
		text, _ := clipText(question.Question, 4<<10)
		header, _ := clipText(question.Header, 256)
		item := ChatQuestion{ID: strconv.Itoa(index), Text: text, Header: header, Options: []ChatQuestionOption{}, Multiple: question.Multiple, Custom: question.Custom}
		for number, option := range question.Options {
			if number == 64 {
				break
			}
			label, _ := clipText(option.Label, 512)
			description, _ := clipText(option.Description, 1<<10)
			item.Options = append(item.Options, ChatQuestionOption{Label: label, Description: description})
		}
		result.Questions = append(result.Questions, item)
	}
	return result
}

// loadLegacy serves agents without paging or part data (test doubles).
func (o openCodeProvider) loadLegacy(p Project, sessionID string, limit int) (chatLoad, error) {
	session, err := o.agent.GetSession(p, sessionID)
	if err != nil {
		return chatLoad{}, err
	}
	items, err := o.agent.Messages(p, sessionID)
	if err != nil {
		return chatLoad{}, err
	}
	messages := unifiedMessages(items, "opencode", sessionID, func(int, Message) time.Time { return time.Time{} })
	result := chatLoad{info: ChatInfo{ID: sessionID, Title: session.Title, Provider: "opencode"}, rewind: session.RewindMessageID, state: "idle"}
	if len(messages) > limit {
		result.hasOlder = true
		messages = messages[len(messages)-limit:]
	}
	result.messages = messages
	if agent, ok := o.agent.(ConfigurableAgent); ok {
		if status, err := agent.ChatStatus(p, sessionID); err == nil && status.State == "busy" {
			result.state = "busy"
		}
	}
	return result, nil
}

func (o openCodeProvider) page(p Project, s Session, before string, limit int) ([]ChatMessage, bool, error) {
	adapter, ok := o.agent.(*OpenCodeAdapter)
	if !ok {
		items, err := o.agent.Messages(p, s.ID)
		if err != nil {
			return nil, false, err
		}
		return pageMessages(unifiedMessages(items, "opencode", s.ID, func(int, Message) time.Time { return time.Time{} }), before, limit)
	}
	// Messages from a rewind point on stay hidden, so paging starts there.
	cursor := ""
	var boundary *ocInfo
	if s.RewindMessageID != "" {
		info, err := adapter.message(p, s.ID, s.RewindMessageID)
		if err != nil {
			return nil, false, err
		}
		boundary = &info
		cursor = openCodePageCursor(info.ID, int64(info.Time.Created))
	}
	if before != "" {
		info, err := adapter.message(p, s.ID, before)
		if err != nil {
			return nil, false, err
		}
		if boundary == nil || info.Time.Created < boundary.Time.Created || (info.Time.Created == boundary.Time.Created && info.ID < boundary.ID) {
			cursor = openCodePageCursor(info.ID, int64(info.Time.Created))
		}
	}
	raw, more, err := adapter.messagePage(p, s.ID, limit, cursor)
	if err != nil {
		return nil, false, err
	}
	result := make([]ChatMessage, 0, len(raw))
	for index := len(raw) - 1; index >= 0; index-- {
		if role := raw[index].Info.Role; role == "user" || role == "assistant" {
			result = append(result, *messageFromOC(raw[index], p.Directory).Unified)
		}
	}
	return result, more, nil
}

// pageMessages pages an in-memory transcript (oldest first) newest first.
func pageMessages(messages []ChatMessage, before string, limit int) ([]ChatMessage, bool, error) {
	end := len(messages)
	if before != "" {
		end = -1
		for index, message := range messages {
			if message.ID == before {
				end = index
				break
			}
		}
		if end < 0 {
			return nil, false, ErrNotFound
		}
	}
	start := max(0, end-limit)
	result := make([]ChatMessage, 0, end-start)
	for index := end - 1; index >= start; index-- {
		result = append(result, messages[index])
	}
	return result, start > 0, nil
}

// send gives OpenCode a host-generated message ID when the adapter takes one,
// so the receipt names the user message before it appears. Every prompt of a
// plain chat, whatever path it comes by (a send, the queue, regenerate, a
// continued chat's first message, an edit after a rewind), runs the chat
// agent with the memory's system text, and none is sent while the chat agent
// is not confirmed.
func (o openCodeProvider) send(p Project, s Session, prompt chatPrompt) (string, error) {
	options := prompt.options
	if o.plain.isSpace(p) {
		if !o.plain.confirmedNow() {
			return "", o.plain.unavailableErr()
		}
		options.Agent, options.Mode, options.Effort = plainChatAgent, "", ""
		options.System = o.plain.memorySystem()
	}
	if agent, ok := o.agent.(messageIDAgent); ok && agent.acceptsMessageID() {
		options.MessageID = prompt.messageID
		if options.MessageID == "" {
			options.MessageID = newOpenCodeMessageID(time.Now())
		}
	}
	var err error
	switch {
	case len(prompt.files) > 0:
		agent, supported := o.agent.(AttachmentAgent)
		if !supported {
			err = errAttachmentsUnsupported
		} else {
			err = agent.PromptAttachments(p, s.ID, prompt.text, options, prompt.files)
		}
	case options.Model != "" || options.Agent != "" || options.MessageID != "" || options.System != "":
		agent, supported := o.agent.(ConfigurableAgent)
		if !supported {
			err = errOptionsUnsupported
		} else {
			err = agent.PromptConfigured(p, s.ID, prompt.text, options)
		}
	default:
		err = o.agent.Prompt(p, s.ID, prompt.text)
	}
	if err != nil {
		return "", err
	}
	return options.MessageID, nil
}

func (o openCodeProvider) interrupt(p Project, sessionID string) error {
	return o.agent.Abort(p, sessionID)
}

func (o openCodeProvider) interactive() (InteractiveAgent, error) {
	agent, ok := o.agent.(InteractiveAgent)
	if !ok {
		return nil, errChatUnsupported
	}
	return agent, nil
}

func (o openCodeProvider) replyPermission(p Project, requestID, reply string) error {
	agent, err := o.interactive()
	if err != nil {
		return err
	}
	return agent.ReplyPermission(p, requestID, reply)
}

func (o openCodeProvider) replyQuestion(p Project, requestID string, answers [][]string) error {
	agent, err := o.interactive()
	if err != nil {
		return err
	}
	return agent.ReplyQuestion(p, requestID, answers)
}

func (o openCodeProvider) rejectQuestion(p Project, requestID string) error {
	agent, err := o.interactive()
	if err != nil {
		return err
	}
	return agent.RejectQuestion(p, requestID)
}

func (o openCodeProvider) rewind(p Project, sessionID, messageID string) error {
	agent, ok := o.agent.(RewindableAgent)
	if !ok {
		return errChatUnsupported
	}
	return agent.Rewind(p, sessionID, messageID)
}

func (o openCodeProvider) restore(p Project, sessionID string) error {
	agent, ok := o.agent.(RewindableAgent)
	if !ok {
		return errChatUnsupported
	}
	return agent.Restore(p, sessionID)
}

// cliProvider wraps the Claude Code and Codex CLI chats. Until they stream,
// the hub sees whole messages: the prompt when it is accepted and the reply
// when the run ends.
type cliProvider struct {
	chats    *CLIChats
	provider string
}

func (c cliProvider) name() string       { return c.provider }
func (c cliProvider) transport() string  { return "coarse" }
func (c cliProvider) features() []string { return []string{} }

func (c cliProvider) options(p Project, sessionID string) (ChatOptions, error) {
	return c.chats.Options(p, sessionID)
}

func (c cliProvider) create(p Project, title string) (Session, error) {
	return c.chats.CreateSession(p, title, c.provider)
}

func (c cliProvider) unified(transcript cliTranscript) []ChatMessage {
	messages := unifiedMessages(transcript.messages, c.provider, transcript.session.ID, func(_ int, message Message) time.Time {
		if created, ok := transcript.created[message.ID]; ok {
			return created
		}
		return transcript.updated
	})
	for index := range messages {
		if messages[index].Role == "assistant" {
			messages[index].Model = c.provider + "/default"
		}
	}
	return messages
}

func (c cliProvider) load(p Project, sessionID string, limit int) (chatLoad, error) {
	transcript, err := c.chats.transcript(p, sessionID)
	if err != nil {
		return chatLoad{}, err
	}
	messages := c.unified(transcript)
	name := sessionName(transcript.session)
	result := chatLoad{info: ChatInfo{ID: sessionID, Title: name.Title, TitleSource: name.Source, TitleBasis: name.Basis, Provider: c.provider, Model: c.provider + "/default"}, state: "idle"}
	if len(messages) > limit {
		result.hasOlder = true
		messages = messages[len(messages)-limit:]
	}
	result.messages = messages
	if transcript.busy {
		result.state = "busy"
	}
	return result, nil
}

func (c cliProvider) page(p Project, s Session, before string, limit int) ([]ChatMessage, bool, error) {
	transcript, err := c.chats.transcript(p, s.ID)
	if err != nil {
		return nil, false, err
	}
	return pageMessages(c.unified(transcript), before, limit)
}

func (c cliProvider) send(p Project, s Session, prompt chatPrompt) (string, error) {
	id := prompt.messageID
	if id == "" {
		id = cliMessageID()
	}
	if err := c.chats.PromptAs(p, s.ID, id, prompt.text, prompt.options, prompt.files, prompt.finished); err != nil {
		return "", err
	}
	return id, nil
}

func (c cliProvider) interrupt(p Project, sessionID string) error { return c.chats.Abort(p, sessionID) }
func (c cliProvider) replyPermission(Project, string, string) error {
	return errChatUnsupported
}
func (c cliProvider) replyQuestion(Project, string, [][]string) error { return errChatUnsupported }
func (c cliProvider) rejectQuestion(Project, string) error            { return errChatUnsupported }
func (c cliProvider) rewind(Project, string, string) error            { return errChatUnsupported }
func (c cliProvider) restore(Project, string) error                   { return errChatUnsupported }
