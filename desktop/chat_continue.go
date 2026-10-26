package host

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"
	"unicode/utf8"

	"agentland/host/internal/localterm"
)

// Continuing a chat in a new one (docs/HOST-API.md, "Continuing a chat in a
// new one"). The owner's handoff ends a Claude Code session and goes on in a
// fresh one; owner, 2026-10-26: "handoff needs to work in the chat screen
// too". Run by a Claude Code chat's tool, `agentland-host chats continue --
// <prompt>` asks this host, on the private local socket (terminal_local.go),
// to start a new Claude Code chat in the same workspace with the old chat's
// title, model, effort and mode, and the prompt as its first message. The old
// chat then names the new one (ChatInfo.ContinuedIn, kept in its record), so
// a tab that shows it follows; it stays in history and usable, with its
// reply stopped and its process ended to free its slot.
//
// Every Claude Code chat's process names its chat and its host
// (claudeEngine.chatEnvironment). Only this user's own processes reach the
// local socket, so only they can send a prompt; the prompt is never logged.
// Codex chats share one app-server process and are not continued.

const (
	// chatContinueTurnWait is how long the old chat's turn, which ran the
	// command, has to end on its own once the command has its answer; then
	// it is stopped as Stop does (Host.chatContinueWait).
	chatContinueTurnWait = 10 * time.Second
	// chatContinueStopWait bounds the wait for a stopped turn to end:
	// Claude Code's answer to the interrupt, and the 10 s after which the
	// engine ends a process whose turn goes on (sendInterrupt).
	chatContinueStopWait = 20 * time.Second
	// chatContinueCheckWait bounds a check of the sign-ins made for a
	// continue, within the command's 60 s.
	chatContinueCheckWait = 10 * time.Second
	// chatContinuePoll is how often the close-out looks at the old turn.
	chatContinuePoll = 50 * time.Millisecond
)

// continueLocalChat starts a new Claude Code chat in place of the request's
// (Chat), with the request's prompt as its first message, and answers the
// new chat's ID and the old chat's close-out (closeOutChat), which the caller
// runs once it has answered. The refusals come in this order: Claude Code
// chats unavailable, another version, a prompt that is not one
// (continuePrompt), a chat that cannot be continued (continuableChat),
// Claude Code not ready for Chat (subscriptions only), then whatever
// creating the chat or sending its prompt answers (continueChatRefusal). On
// a refusal nothing is recorded, and a new chat already made is removed.
func (h *Host) continueLocalChat(request localterm.Request) (string, func(), *localterm.Error) {
	if h.cliChats == nil || h.cliChats.claude == nil {
		return "", nil, localRefusal(localterm.CodeUnavailable, "AgentLand's Claude Code chats aren't available on this Mac.")
	}
	if request.Version != h.version {
		return "", nil, localRefusal(localterm.CodeVersion, "This command and the AgentLand host running now are different versions.")
	}
	prompt, ok := continuePrompt(request.Prompt)
	if !ok {
		return "", nil, localRefusal(localterm.CodeBadRequest, fmt.Sprintf("The prompt must be one line of text, at most %d bytes, not starting with \"-\".", continuePromptLimit))
	}
	p, old, chat, refusal := h.continuableChat(request.Chat)
	if refusal != nil {
		return "", nil, refusal
	}
	if refusal := h.continueChatReady(); refusal != nil {
		return "", nil, refusal
	}
	// The turn that ran the command, which the close-out waits for.
	turn := chat.runningTurn()
	// Same title, kept: the creator's ("provider"), which free naming never
	// replaces (owner's choice, "Same title").
	s, err := h.createCLIChat(p, chatName{Title: old.Title, Source: titleProvider}, "claude", chat.continueOptions())
	if err != nil {
		if s.ID != "" {
			h.removeNewChat(p, s.ID)
		}
		return "", nil, h.continueChatRefusal(err)
	}
	// The first message, as a device's send delivers it, from no device and
	// without attachments.
	unlock := h.lockSession(p.ID, s.ID)
	_, err = h.deliverPrompt(p, s, prompt, PromptOptions{}, nil)
	unlock()
	if err != nil {
		h.removeNewChat(p, s.ID)
		return "", nil, h.continueChatRefusal(err)
	}
	chat.recordContinuation(s.ID, h.now())
	log.Printf("chats: continued id=%s in id=%s workspace=%s", old.ID, s.ID, p.ID)
	return s.ID, func() { h.closeOutChat(p, old, chat, turn) }, nil
}

// continuableChat is the chat a continue names, with its workspace and the
// engine's state for it, when the host can continue it: a Claude Code chat
// the host has, in a workspace it still has (not a plain chat of the Chats
// space), and not deleted from the archive.
func (h *Host) continuableChat(id string) (Project, Session, *claudeChat, *localterm.Error) {
	refuse := func(message string) (Project, Session, *claudeChat, *localterm.Error) {
		return Project{}, Session{}, nil, localRefusal(localterm.CodeChatNotContinuable, message)
	}
	switch {
	case id == "" || len(id) > archiveIDLimit || !utf8.ValidString(id):
		return refuse("This isn't an AgentLand chat.")
	case !isClaudeSessionID(id):
		return refuse("Only a Claude Code chat can be continued.")
	}
	projectID, ok := h.cliChats.chatProjectID(id)
	switch {
	case !ok:
		return refuse("AgentLand doesn't have this chat.")
	case projectID == plainChatsProjectID:
		return refuse("This chat isn't in a workspace.")
	}
	p, err := h.project(projectID)
	if err != nil {
		return refuse("This chat's workspace was removed.")
	}
	s, err := h.session(p, id)
	if err != nil {
		return refuse("AgentLand doesn't have this chat.")
	}
	if h.archive != nil {
		if deleted, err := h.archive.chatDeletedRead(context.Background(), id); err == nil && deleted {
			return refuse("This chat was deleted.")
		}
	}
	chat, err := h.cliChats.claude.chat(p, id)
	if errors.Is(err, ErrCLIChatUnavailable) {
		return Project{}, Session{}, nil, h.continueChatRefusal(err)
	}
	if err != nil {
		return refuse("AgentLand doesn't have this chat.")
	}
	return p, s, chat, nil
}

// continueChatReady refuses a continue while Claude Code cannot run Chat:
// Chat runs on subscriptions only (chatProviderReady), and a continue
// creates a chat and sends to it.
func (h *Host) continueChatReady() *localterm.Error {
	if h.plainChats == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), chatContinueCheckWait)
	defer cancel()
	ready, auth := h.cliProviderCheck(ctx, "claude")
	switch {
	case ready:
		return nil
	case auth != nil:
		return localRefusal(localterm.CodeUnavailable, auth.Message)
	}
	return localRefusal(localterm.CodeUnavailable, chatProviderNames["claude"]+" cannot run Chat now. Check its installation and sign-in on the Mac.")
}

// continueChatRefusal is a failure to create the new chat or send its
// prompt as the local socket's refusal, as close as its codes come to what
// POST /v1/sessions and POST /v1/messages answer.
func (h *Host) continueChatRefusal(err error) *localterm.Error {
	select {
	case <-h.stopping:
		return localRefusal(localterm.CodeStopping, "AgentLand's host is stopping.")
	default:
	}
	switch {
	case errors.Is(err, errClaudeCapacity):
		return localRefusal(localterm.CodeLimit, fmt.Sprintf("AgentLand has %d Claude Code chats working; try again when one finishes.", h.cliChats.claude.options.maxLive))
	case errors.Is(err, errClaudeSubscription), errors.Is(err, errClaudeSubscriptionStopped):
		return localRefusal(localterm.CodeUnavailable, "Claude Code reported an API key, so AgentLand stopped the new chat: Chat uses only your Claude subscription. "+claudeSubscriptionMessage)
	case errors.Is(err, errDeliveryUncertain):
		return localRefusal(localterm.CodeUnavailable, "Claude Code didn't confirm the prompt in time, so AgentLand removed the new chat.")
	}
	return localRefusal(localterm.CodeUnavailable, "AgentLand could not start the new chat.")
}

// removeNewChat removes a continue's new chat that did not get its prompt,
// which no device was told about: its process, if one started, ends, and
// the registry, the hub and the archive forget it.
func (h *Host) removeNewChat(p Project, id string) {
	h.cliChats.claude.forget(id)
	h.cliChats.removeRecord(id)
	// The hub reads the chat again, finds it gone and drops it.
	h.cliChats.notify(p.ID, id)
	if h.archive != nil {
		_ = h.archive.DeleteChat(id)
	}
}

// closeOutChat ends the old chat's part once the command has its answer: the
// turn that ran it has chatContinueWait to end on its own, else it is stopped
// as POST /v1/abort does; then the chat's process stops, freeing its slot
// (the next send starts one again). A turn that began since, because someone
// sent to the old chat, is left alone. It ends early when the host closes.
func (h *Host) closeOutChat(p Project, old Session, chat *claudeChat, turn string) {
	if !chat.engine.begin() {
		return
	}
	defer chat.engine.work.Done()
	if !h.awaitChatTurn(chat, turn, h.chatContinueWait) {
		h.chat.interrupted(sessionKey{p.ID, old.ID})
		if provider := h.chatProviderFor(old); provider != nil {
			_ = provider.interrupt(p, old.ID)
		}
		h.awaitChatTurn(chat, turn, chatContinueStopWait)
	}
	chat.stopAfterContinue(turn)
}

// awaitChatTurn waits up to wait for the chat's turn (its prompt's ID) to be
// over and reports whether it is. It is over, too, once the chat or the host
// is closing.
func (h *Host) awaitChatTurn(chat *claudeChat, turn string, wait time.Duration) bool {
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	poll := time.NewTicker(chatContinuePoll)
	defer poll.Stop()
	for chat.turnRunning(turn) {
		select {
		case <-deadline.C:
			return false
		case <-h.stopping:
			return true
		case <-poll.C:
		}
	}
	return true
}

// runningTurn is the running turn's prompt ID, "" when none runs.
func (c *claudeChat) runningTurn() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.turn == nil {
		return ""
	}
	return c.turn.id
}

// turnRunning reports whether the turn whose prompt is turn still runs in
// an open chat.
func (c *claudeChat) turnRunning(turn string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.closed && turn != "" && c.turn != nil && c.turn.id == turn
}

// continueOptions are the chat's model, mode and effort as a new chat's
// settings: a continue keeps them (owner's choice, no asking again).
func (c *claudeChat) continueOptions() PromptOptions {
	c.mu.Lock()
	defer c.mu.Unlock()
	options := PromptOptions{Mode: c.rec.Mode, Effort: c.rec.Effort}
	if c.rec.Model != "" {
		options.Model = "claude/" + c.rec.Model
	}
	return options
}

// recordContinuation records that the chat continued in chat id at at: in
// its record, so it outlives the host, and at once for anyone following it
// (chat.updated).
func (c *claudeChat) recordContinuation(id string, at time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rec.ContinuedIn, c.rec.ContinuedAt = id, chatTimeOf(at)
	c.persistLocked()
	c.pushInfoLocked()
}

// stopAfterContinue stops the chat's process to free its slot after a
// continue: when it is idle, or still runs turn, which then ends as stopped.
// A turn that began since keeps its process, and so does a chat in use (a
// send, a rewind) at this moment. The chat stays usable: its next send
// starts a process again.
func (c *claudeChat) stopAfterContinue(turn string) {
	if !c.op.TryLock() {
		return
	}
	defer c.op.Unlock()
	c.mu.Lock()
	proc := c.proc
	stuck := turn != "" && c.turn != nil && c.turn.id == turn
	idle := c.turn == nil && c.outgoing == nil && len(c.asks) == 0
	stop := proc != nil && (stuck || idle)
	if stop {
		c.stopIdleTimerLocked()
	}
	if stuck {
		c.turn.interrupted = true
	}
	c.mu.Unlock()
	if stop {
		proc.stop(stuck, c.engine.options.stopGrace)
	}
}

// forget ends and drops the engine's state for chat id, which is being
// removed (removeNewChat).
func (e *claudeEngine) forget(id string) {
	e.mu.Lock()
	chat := e.chats[id]
	delete(e.chats, id)
	e.mu.Unlock()
	if chat != nil {
		chat.shutdown()
	}
}

// chatProjectID is the workspace (or the Chats space) the registry has a
// Claude Code or Codex chat in.
func (c *CLIChats) chatProjectID(id string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record := c.records[id]
	if record == nil {
		return "", false
	}
	return record.Session.ProjectID, true
}

// removeRecord drops a chat from the registry (removeNewChat).
func (c *CLIChats) removeRecord(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.records[id]; !ok {
		return
	}
	delete(c.records, id)
	if err := c.saveLocked(); err != nil {
		log.Printf("chats: id=%s was removed, but the chats registry could not be saved: %v", id, err)
	}
}
