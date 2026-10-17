package host

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// One Claude Code chat: its transcript in the unified model, the uuid chain
// Claude's transcript uses, and the process serving it. Lock order: op, then
// mu, then the chat hub's lock and the registry's. Nothing waits on the
// process (a control answer or its exit) while holding mu, because the
// process's reader needs mu to deliver what it waits for.

type claudeSettings struct {
	model  string // CLI model value; "" is the CLI's default
	mode   string // permission mode
	effort string // effort level; "" is the CLI's default
}

// claudeLaunch is how a process starts. Exactly one of session (a new
// session) and resume is set.
type claudeLaunch struct {
	settings claudeSettings
	session  string // --session-id
	resume   string // --resume
	at       string // --resume-session-at
	drops    string // --resume-drops-turn
	fork     bool   // --fork-session
	addDir   string // --add-dir, the attachments folder
}

// probeArgs start Claude Code as itself: the user's settings, CLAUDE.md,
// MCP servers and tools, asking for permissions in the chat.
func (l claudeLaunch) probeArgs() []string {
	return []string{"-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
		// Bypass permissions is a mode Chat offers (claudeModes): without this
		// flag a running process refuses set_permission_mode into it. It
		// enables nothing by itself; the permission mode decides.
		"--allow-dangerously-skip-permissions",
		"--permission-mode", l.settings.mode}
}

func (l claudeLaunch) args() []string {
	args := l.probeArgs()
	if l.settings.model != "" {
		args = append(args, "--model", l.settings.model)
	}
	if l.settings.effort != "" {
		args = append(args, "--effort", l.settings.effort)
	}
	if l.session != "" {
		args = append(args, "--session-id", l.session)
	} else {
		args = append(args, "--resume", l.resume)
		if l.at != "" {
			args = append(args, "--resume-session-at", l.at)
		}
		if l.drops != "" {
			args = append(args, "--resume-drops-turn", l.drops)
		}
		if l.fork {
			args = append(args, "--fork-session")
		}
	}
	if l.addDir != "" {
		args = append(args, "--add-dir", l.addDir)
	}
	return args
}

func newClaudeUUID() string {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		panic(err)
	}
	data[6] = data[6]&0x0f | 0x40
	data[8] = data[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", data[0:4], data[4:6], data[6:8], data[8:10], data[10:])
}

// claudeOutgoing is a prompt written to the CLI whose echo has not arrived.
type claudeOutgoing struct {
	uuid     string
	text     string
	files    []ChatAttachment
	finished func()
	settings claudeSettings
	waiter   chan error
	// commit is the rewind point this prompt's delivery drops.
	commit string
	// written: the frame reached the CLI's stdin; lost: the process ended
	// before the echo; settled: finished has run or passed to the turn.
	written, lost, settled bool
}

// settleLocked returns the prompt's finished, once, for a prompt that may
// have reached the CLI.
func (out *claudeOutgoing) settleLocked() []func() {
	if out.settled || out.finished == nil {
		return nil
	}
	out.settled = true
	return []func(){out.finished}
}

// claudeTurn is the turn in progress.
type claudeTurn struct {
	id          string // the prompt's user message ID
	interrupted bool   // the user stopped it
	protocol    bool   // the CLI's output broke the protocol
	finished    func()
	apiMessages map[string]string // Anthropic message ID to unified message ID
	current     string            // Anthropic message ID streaming now
	seen        map[string]int    // assistant blocks already reconciled per Anthropic message
	inputs      map[string]*strings.Builder
	tools       map[string]claudeToolRef // tool_use_id to its part
}

type claudeToolRef struct{ message, part string }

func newClaudeTurn(id string, finished func()) *claudeTurn {
	return &claudeTurn{id: id, finished: finished, apiMessages: map[string]string{}, seen: map[string]int{}, inputs: map[string]*strings.Builder{}, tools: map[string]claudeToolRef{}}
}

type claudeChat struct {
	engine  *claudeEngine
	key     sessionKey
	project Project
	id      string

	op sync.Mutex

	mu      sync.Mutex
	title   string
	native  string
	legacy  []ChatMessage
	rec     claudeRecord
	nextOrd int64

	proc      *claudeProcess
	launched  claudeLaunch
	fresh     bool          // proc began a new session and has not delivered a prompt
	plan      *claudeLaunch // session flags for the next process (rewind)
	lastEntry string
	state     string // idle, busy or retry
	retry     *ChatRetry
	turn      *claudeTurn
	outgoing  *claudeOutgoing
	asks      []*claudeAsk
	// The running process's total_cost_usd (claude_cost.go): the newest it
	// reported, what it started from and whether that is known, whether a
	// result came yet, and a fork's source chat and session.
	costSeen   float64
	costBase   float64
	costKnown  bool
	costFirst  bool
	costSource *claudeChat
	costFrom   string
	used       time.Time
	idleTimer  *time.Timer
	startFail  string
	// keyRefused: the process said it uses an API key
	// (chat_subscription.go) and is being ended.
	keyRefused bool
	abortWait  bool // stop was asked while a prompt waited for its echo
	closed     bool
}

func newClaudeChat(engine *claudeEngine, project Project, id string, entry claudeEntry) (*claudeChat, error) {
	c := &claudeChat{engine: engine, key: sessionKey{project.ID, id}, project: project, id: id, title: entry.session.Title, native: entry.native, state: "idle", used: time.Now()}
	c.legacy = unifiedMessages(entry.legacy, "claude", id, func(_ int, message Message) time.Time {
		if created, ok := entry.created[message.ID]; ok {
			return created
		}
		return entry.updated
	})
	for index := range c.legacy {
		if c.legacy[index].Role == "assistant" {
			c.legacy[index].Model = "claude/default"
		}
	}
	if len(entry.state) > 0 {
		if err := json.Unmarshal(entry.state, &c.rec); err != nil {
			return nil, err
		}
	} else if entry.native != "" {
		// A chat from before streaming: its session exists, its entries are
		// unknown.
		c.rec.Started, c.rec.Gap = true, true
	}
	if !validClaudeMode(c.rec.Mode) {
		c.rec.Mode = claudeDefaultMode
	}
	c.costLoadedLocked()
	for _, message := range c.allLocked() {
		c.nextOrd = max(c.nextOrd, message.Ord)
	}
	c.nextOrd++
	c.lastEntry = c.rec.LastEntry
	if c.rec.Running != "" {
		c.recoverLocked()
	}
	return c, nil
}

// recoverLocked finishes a turn the host stopped in the middle of.
func (c *claudeChat) recoverLocked() {
	failure := &ChatError{Code: "agent_exited", Message: "AgentLand stopped before this reply completed."}
	found := false
	for index := range c.rec.Messages {
		message := &c.rec.Messages[index]
		if message.Role != "assistant" || message.TurnID != c.rec.Running || message.Status != "streaming" {
			continue
		}
		message.Status, message.Error = "error", failure
		found = true
	}
	if !found {
		c.rec.Messages = append(c.rec.Messages, c.newAssistantLocked(c.rec.Running, "error", time.Now()))
		c.rec.Messages[len(c.rec.Messages)-1].Error = failure
	}
	c.rec.Running, c.rec.Gap, c.rec.LastEntry = "", true, ""
	c.lastEntry = ""
	c.persistLocked()
}

func (c *claudeChat) takeOrdLocked() int64 {
	ord := c.nextOrd
	c.nextOrd++
	return ord
}

func (c *claudeChat) newAssistantLocked(turn, status string, now time.Time) ChatMessage {
	message := ChatMessage{ID: newClaudeUUID(), ChatID: c.id, TurnID: turn, Role: "assistant", Status: status, Ord: c.takeOrdLocked(), CreatedAt: chatTimeOf(now), Provider: "claude", Model: "claude/" + claudeModelName(c.rec.Model), Parts: []ChatPart{}, createdMs: now.UnixMilli()}
	if status != "streaming" {
		message.CompletedAt = message.CreatedAt
	}
	return message
}

func claudeModelName(model string) string {
	if model == "" {
		return "default"
	}
	return model
}

func (c *claudeChat) persistLocked() {
	state, err := json.Marshal(c.rec)
	if err != nil {
		return
	}
	_ = c.engine.cli.claudeSave(c.project, c.id, c.native, state, c.rec.Rewind, time.Now())
}

// allLocked is the whole transcript; callers copy what they hand out.
func (c *claudeChat) allLocked() []ChatMessage {
	all := make([]ChatMessage, 0, len(c.legacy)+len(c.rec.Messages))
	all = append(all, c.legacy...)
	return append(all, c.rec.Messages...)
}

// visibleLocked leaves out the rewind point and what follows it.
func (c *claudeChat) visibleLocked() []ChatMessage {
	all := c.allLocked()
	if c.rec.Rewind != "" {
		for index, message := range all {
			if message.ID == c.rec.Rewind {
				return all[:index]
			}
		}
	}
	return all
}

// cloneMessage copies a message's parts so later changes do not reach it.
// Tool, usage and error values are replaced, never changed, so sharing them
// is safe.
func cloneMessage(message ChatMessage) ChatMessage {
	message.Parts = append([]ChatPart{}, message.Parts...)
	return message
}

func cloneMessages(messages []ChatMessage) []ChatMessage {
	result := make([]ChatMessage, len(messages))
	for index, message := range messages {
		result[index] = cloneMessage(message)
	}
	return result
}

func (c *claudeChat) findLocked(id string) int {
	for index := len(c.rec.Messages) - 1; index >= 0; index-- {
		if c.rec.Messages[index].ID == id {
			return index
		}
	}
	return -1
}

func (c *claudeChat) infoLocked() ChatInfo {
	info := ChatInfo{ID: c.id, Title: c.title, Provider: "claude", Model: "claude/" + claudeModelName(c.rec.Model), Mode: c.rec.Mode, Effort: c.rec.Effort}
	// Chat names (chat_title.go): the registry has the name as the host
	// last gave it, which may be newer than the title read at load.
	if name, ok := c.engine.cli.storedName(c.id); ok {
		info.Title, info.TitleSource, info.TitleBasis = name.Title, name.Source, name.Basis
	}
	return info
}

func (c *claudeChat) hubStateLocked() string {
	switch {
	case c.turn == nil:
		return "idle"
	case c.state == "retry":
		return "retry"
	default:
		return "busy"
	}
}

func (c *claudeChat) loadLocked(limit int) chatLoad {
	visible := c.visibleLocked()
	start := max(0, len(visible)-limit)
	load := chatLoad{info: c.infoLocked(), rewind: c.rec.Rewind, messages: cloneMessages(visible[start:]), hasOlder: start > 0, state: c.hubStateLocked(), interactions: c.interactionsLocked()}
	if load.state == "retry" && c.retry != nil {
		retry := *c.retry
		load.retry = &retry
	}
	return load
}

func (c *claudeChat) snapshot(limit int, apply func(chatLoad)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	apply(c.loadLocked(limit))
}

// push applies one change to the hub's copy of this chat, if it has one.
func (c *claudeChat) push(apply func(*hubChat, uint64)) {
	c.engine.chatHub().liveUpdate(c.key, apply)
}

func (c *claudeChat) replaceHubLocked() {
	c.engine.chatHub().liveReplace(c.key, c.loadLocked(chatSnapshotMessages))
}

func (c *claudeChat) pushStateLocked() {
	state := c.hubStateLocked()
	var retry *ChatRetry
	if state == "retry" && c.retry != nil {
		copied := *c.retry
		retry = &copied
	}
	c.push(func(hc *hubChat, touched uint64) {
		hc.state, hc.retry = state, retry
		hc.statusTouched = touched
		hc.recomputeStatus()
	})
}

func (c *claudeChat) pushHeaderLocked(index int) {
	header := cloneMessage(c.rec.Messages[index])
	c.push(func(hc *hubChat, touched uint64) {
		if entry, _ := hc.find(header.ID); entry != nil {
			hc.updateHeader(entry, header, touched)
		}
	})
}

func (c *claudeChat) pushPartLocked(messageID string, part ChatPart) {
	c.push(func(hc *hubChat, touched uint64) {
		hc.upsertPart(messageID, part, true, touched)
	})
}

func (c *claudeChat) pushMessageLocked(message ChatMessage) {
	message = cloneMessage(message)
	c.push(func(hc *hubChat, touched uint64) {
		if entry, _ := hc.find(message.ID); entry == nil {
			hc.insertMessage(message, true, touched)
			hc.trim()
		}
	})
}

func (c *claudeChat) pushInfoLocked() {
	info := c.infoLocked()
	c.push(func(hc *hubChat, touched uint64) {
		hc.applyInfo(info)
	})
}

// state is the chat's activity for the host's routes: idle, busy or retry.
func (c *claudeChat) activity() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	switch {
	case c.turn != nil && c.state == "retry":
		return "retry"
	case c.turn != nil || c.outgoing != nil:
		return "busy"
	default:
		return "idle"
	}
}

func (c *claudeChat) idleSince() (time.Time, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.used, c.proc != nil && c.turn == nil && c.outgoing == nil && len(c.asks) == 0
}

func (c *claudeChat) stopIdleTimerLocked() {
	if c.idleTimer != nil {
		c.idleTimer.Stop()
		c.idleTimer = nil
	}
}

func (c *claudeChat) armIdleTimerLocked() {
	c.stopIdleTimerLocked()
	if c.proc == nil || c.closed {
		return
	}
	c.idleTimer = time.AfterFunc(c.engine.options.idleStop, func() { c.stopIfIdle(true) })
}

// stopIfIdle stops the process when nothing is running, being sent or
// waiting for the user.
func (c *claudeChat) stopIfIdle(fromTimer bool) bool {
	if !c.op.TryLock() {
		return false
	}
	defer c.op.Unlock()
	c.mu.Lock()
	proc := c.proc
	idle := proc != nil && c.turn == nil && c.outgoing == nil && len(c.asks) == 0
	if fromTimer && time.Since(c.used) < c.engine.options.idleStop {
		idle = false
	}
	if idle {
		c.stopIdleTimerLocked()
	}
	c.mu.Unlock()
	if !idle {
		return false
	}
	proc.stop(false, c.engine.options.stopGrace)
	return true
}

// closing marks the chat closed at the host's shutdown, before the engine
// ends its process: no process starts from now on, and a running turn
// counts as stopped. Unlike shutdown it does not wait for the chat's
// operations, which end once the process is gone.
func (c *claudeChat) closing() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	c.stopIdleTimerLocked()
	if c.turn != nil {
		c.turn.interrupted = true
	}
}

// shutdown stops the process for good, stopping a running turn first.
func (c *claudeChat) shutdown() {
	c.op.Lock()
	defer c.op.Unlock()
	c.mu.Lock()
	c.closed = true
	c.stopIdleTimerLocked()
	proc := c.proc
	if c.turn != nil {
		c.turn.interrupted = true
	}
	running := c.turn != nil
	c.mu.Unlock()
	if proc != nil {
		proc.stop(running, c.engine.options.stopGrace)
	}
}

// settingsFor merges a prompt's options into the chat's settings.
func (c *claudeChat) settingsFor(options PromptOptions) (claudeSettings, error) {
	c.mu.Lock()
	settings := claudeSettings{model: c.rec.Model, mode: c.rec.Mode, effort: c.rec.Effort}
	c.mu.Unlock()
	if options.Agent != "" && options.Agent != "build" {
		return settings, errClaudeOptions
	}
	if options.Model != "" {
		value, ok := strings.CutPrefix(options.Model, "claude/")
		if !ok || !claudeModelPattern.MatchString(value) {
			return settings, errClaudeOptions
		}
		if value == "default" {
			value = ""
		}
		settings.model = value
	}
	if options.Mode != "" {
		if !validClaudeMode(options.Mode) {
			return settings, errClaudeOptions
		}
		settings.mode = options.Mode
	}
	if options.Effort != "" {
		if !validClaudeEffort(options.Effort) {
			return settings, errClaudeOptions
		}
		settings.effort = options.Effort
	}
	return settings, nil
}

// claudePromptText adds the attachment paths the CLI reads with its tools.
func claudePromptText(text string, files []ChatAttachment) string {
	if len(files) == 0 {
		return text
	}
	if text != "" {
		text += "\n\n"
	}
	text += "Attached files (read them with your tools):"
	for _, file := range files {
		text += "\n- " + file.Path + " (" + file.Name + ")"
	}
	return text
}

// send delivers one prompt. It is delivered when the CLI replays its uuid;
// a process that ends first, or an echo that does not arrive in time, leaves
// the delivery uncertain and nothing is sent again.
func (c *claudeChat) send(prompt chatPrompt) (string, error) {
	// The Chats space's chats are read-only (errChatsSpaceRetired).
	if c.project.ID == plainChatsProjectID {
		return "", errChatsSpaceRetired
	}
	content := []any{map[string]string{"type": "text", "text": claudePromptText(prompt.text, prompt.files)}}
	settings, err := c.settingsFor(prompt.options)
	if err != nil {
		return "", err
	}
	c.op.Lock()
	defer c.op.Unlock()
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return "", fmt.Errorf("%w: %w", ErrCLIChatUnavailable, errPromptNotSent)
	}
	if c.turn != nil || c.outgoing != nil {
		c.mu.Unlock()
		return "", ErrCLIChatBusy
	}
	rewind := c.rec.Rewind
	c.stopIdleTimerLocked()
	c.used = time.Now()
	c.mu.Unlock()
	if rewind != "" {
		if err := c.prepareRewind(rewind); err != nil {
			c.idleAfterFailure()
			return "", err
		}
	}
	addDir := ""
	if len(prompt.files) > 0 {
		addDir = filepath.Dir(prompt.files[0].Path)
	}
	proc, err := c.ensureProcess(settings, addDir)
	if err != nil {
		c.idleAfterFailure()
		return "", err
	}
	// The host may have named the user message already (the archive files it
	// under that ID); the CLI takes it as the prompt's uuid.
	id := prompt.messageID
	if !claudeUUIDPattern.MatchString(id) {
		id = newClaudeUUID()
	}
	out := &claudeOutgoing{uuid: id, text: prompt.text, files: prompt.files, finished: prompt.finished, settings: settings, waiter: make(chan error, 1), commit: rewind}
	c.mu.Lock()
	if c.proc != proc || !proc.alive() {
		c.mu.Unlock()
		return "", errClaudeStart
	}
	c.outgoing = out
	c.mu.Unlock()
	frame := map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": content}, "parent_tool_use_id": nil, "session_id": "", "uuid": out.uuid}
	written, err := proc.write(frame)
	c.mu.Lock()
	out.written = written
	var after []func()
	if written && out.lost {
		// The process ended between the write and now.
		after = out.settleLocked()
	}
	if !written && c.outgoing == out {
		c.outgoing, c.abortWait = nil, false
	}
	c.mu.Unlock()
	for _, run := range after {
		run()
	}
	if err != nil {
		if !written {
			return "", fmt.Errorf("%w: %v", errPromptNotSent, err)
		}
		// A frame cut short breaks the stream; its fate is unknown.
		proc.kill()
		return "", errDeliveryUncertain
	}
	timer := time.NewTimer(c.engine.options.echoWait)
	defer timer.Stop()
	select {
	case err := <-out.waiter:
		if err != nil {
			return "", err
		}
		return out.uuid, nil
	case <-timer.C:
		return "", errDeliveryUncertain
	}
}

func (c *claudeChat) idleAfterFailure() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.turn == nil && c.outgoing == nil {
		c.armIdleTimerLocked()
	}
}

// ensureProcess returns a live process with the wanted settings: it starts
// one, restarts it when the effort or attachments folder changes, and
// switches model and permission mode on a running one.
func (c *claudeChat) ensureProcess(want claudeSettings, addDir string) (*claudeProcess, error) {
	c.mu.Lock()
	proc, launched := c.proc, c.launched
	if c.plan != nil {
		// A rewind needs a process started from the truncated session.
		c.mu.Unlock()
		if proc != nil {
			proc.stop(false, c.engine.options.stopGrace)
		}
		return c.spawn(want, addDir)
	}
	c.mu.Unlock()
	if proc != nil && proc.alive() && (launched.settings.effort != want.effort || (addDir != "" && launched.addDir != addDir)) {
		proc.stop(false, c.engine.options.stopGrace)
	}
	if proc == nil || !proc.alive() {
		return c.spawn(want, addDir)
	}
	if launched.settings.model != want.model {
		request := map[string]any{"subtype": "set_model"}
		if want.model != "" {
			request["model"] = want.model
		}
		if _, err := c.control(proc, request); err != nil {
			return nil, c.controlFailure(err)
		}
		c.mu.Lock()
		if c.proc == proc {
			c.launched.settings.model = want.model
		}
		c.mu.Unlock()
	}
	if launched.settings.mode != want.mode {
		if _, err := c.control(proc, map[string]any{"subtype": "set_permission_mode", "mode": want.mode}); err != nil {
			return nil, c.controlFailure(err)
		}
		c.mu.Lock()
		if c.proc == proc {
			c.launched.settings.mode = want.mode
		}
		c.mu.Unlock()
	}
	return proc, nil
}

func (c *claudeChat) controlFailure(err error) error {
	if errors.Is(err, errClaudeControl) {
		return errClaudeOptions
	}
	return fmt.Errorf("%w: %v", errClaudeStart, err)
}

func (c *claudeChat) control(proc *claudeProcess, request map[string]any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), c.engine.options.controlWait)
	defer cancel()
	return proc.request(ctx, request)
}

// spawn starts a process for the chat and initializes it.
func (c *claudeChat) spawn(want claudeSettings, addDir string) (*claudeProcess, error) {
	// Claude Code runs only in workspaces: nothing starts in the Chats
	// space's folder, whatever asks (a send, a regenerate, a rewind).
	if c.project.ID == plainChatsProjectID {
		return nil, errChatsSpaceRetired
	}
	executable, ok := c.engine.executable()
	if !ok {
		return nil, errClaudeStart
	}
	if err := c.engine.acquire(c); err != nil {
		return nil, err
	}
	// A fork's first process restores its source's saved total; ask the
	// source chat before taking this chat's lock.
	fork := c.forkCost()
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		c.engine.release()
		return nil, fmt.Errorf("%w: %w", ErrCLIChatUnavailable, errPromptNotSent)
	}
	launch := claudeLaunch{}
	lastEntry := c.rec.LastEntry
	switch {
	case c.plan != nil:
		launch = *c.plan
		c.plan = nil
		lastEntry = launch.at
		if launch.session != "" {
			c.native, c.rec.Started = launch.session, false
		}
	case c.rec.ForkFrom != "":
		launch = claudeLaunch{resume: c.rec.ForkFrom, at: c.rec.ForkAt, fork: true}
	case c.rec.Started && c.native != "":
		launch = claudeLaunch{resume: c.native}
	default:
		c.native = newClaudeUUID()
		launch = claudeLaunch{session: c.native}
		lastEntry = ""
	}
	launch.settings, launch.addDir = want, addDir
	spec := claudeSpawn{executable: executable, args: launch.args(), dir: c.project.Directory, env: c.engine.environment(), lineLimit: c.engine.options.lineLimit, stderrTail: c.engine.options.stderrTail, writeWait: 10 * time.Second, trace: c.engine.options.trace}
	if c.engine.options.onSpawn != nil {
		c.engine.options.onSpawn(spec.args)
	}
	c.startFail, c.keyRefused = "", false
	// The reader waits for mu, so no line is handled before proc is known.
	exited := func(proc *claudeProcess) {
		c.engine.untrack(proc)
		c.processExited(proc)
	}
	proc, err := startClaudeProcess(spec, c.handleLine, exited)
	if err != nil {
		c.mu.Unlock()
		c.engine.release()
		return nil, errClaudeStart
	}
	if !c.engine.track(proc) {
		// The host is shutting down; the process's exit gives its slot back.
		c.mu.Unlock()
		proc.terminate(agentShutdownKill)
		return nil, fmt.Errorf("%w: %w", ErrCLIChatUnavailable, errPromptNotSent)
	}
	c.proc, c.launched, c.fresh, c.lastEntry = proc, launch, launch.session != "", lastEntry
	c.costStartLocked(launch, fork)
	c.state, c.retry = "idle", nil
	c.mu.Unlock()
	response, err := c.control(proc, map[string]any{"subtype": "initialize", "hooks": nil})
	if err != nil {
		proc.kill()
		proc.waitExit(c.engine.options.stopGrace)
		return nil, c.startError(proc)
	}
	// Chat runs on the Claude subscription only, in a workspace as in the
	// Chats space: a process that names an API key or another cloud (a
	// project's apiKeyHelper, say) ends before any prompt reaches it.
	if !c.engine.options.apiKeyAllowed && !claudeAccountSubscription(response) {
		proc.kill()
		proc.waitExit(c.engine.options.stopGrace)
		return nil, errClaudeSubscription
	}
	c.engine.rememberModels(executable, response)
	return proc, nil
}

// startError explains why a process did not start. The CLI's own words are
// kept for diagnosis only.
func (c *claudeChat) startError(proc *claudeProcess) error {
	c.mu.Lock()
	reported := c.startFail
	c.mu.Unlock()
	if strings.Contains(reported, "--resume-drops-turn") || strings.Contains(proc.stderr.String(), "Resume rejected by --resume-drops-turn") {
		return errClaudeRewindRefused
	}
	return errClaudeStart
}

// processExited runs once for every process after it ended.
func (c *claudeChat) processExited(proc *claudeProcess) {
	c.engine.release()
	var after []func()
	c.mu.Lock()
	if c.proc == proc {
		c.proc = nil
		c.stopIdleTimerLocked()
		after = c.processEndedLocked(proc)
		if c.costEndedLocked(proc.exitedOnItsOwn()) {
			c.persistLocked()
		}
	}
	c.mu.Unlock()
	for _, run := range after {
		run()
	}
}

// processEndedLocked settles what the process was doing: a prompt without
// its echo is uncertain, a running turn ends and pending requests are gone.
func (c *claudeChat) processEndedLocked(proc *claudeProcess) []func() {
	var after []func()
	if out := c.outgoing; out != nil {
		c.outgoing, c.abortWait = nil, false
		out.lost = true
		if c.keyRefused {
			out.waiter <- errClaudeSubscriptionStopped
		} else {
			out.waiter <- errDeliveryUncertain
		}
		// A prompt not yet written is the sender's to report; one written
		// may have been read, so its files go.
		if out.written {
			after = append(after, out.settleLocked()...)
		}
	}
	if c.turn != nil {
		failure := ChatError{Code: "agent_exited", Message: "Claude Code stopped before this reply completed."}
		outcome := "error"
		switch {
		case c.keyRefused:
			failure = ChatError{Code: "agent_auth_required", Message: "Claude Code reported an API key, so AgentLand stopped it before it replied: Chat uses only your Claude subscription. " + claudeSubscriptionMessage}
		case c.turn.interrupted:
			outcome = "aborted"
		case c.turn.protocol:
			failure = ChatError{Code: "protocol_error", Message: "Claude Code sent output AgentLand could not read, so the reply stopped."}
		}
		after = append(after, c.finishTurnLocked(outcome, failure, time.Now())...)
	}
	c.state, c.retry = "idle", nil
	return after
}

// interrupt stops the running turn. If Claude Code does not answer, its
// process is ended, which ends the turn.
func (c *claudeChat) interrupt() error {
	c.mu.Lock()
	proc, turn := c.proc, c.turn
	if turn == nil {
		if c.outgoing != nil {
			c.abortWait = true
		}
		c.mu.Unlock()
		return nil
	}
	turn.interrupted = true
	c.mu.Unlock()
	if proc != nil {
		c.sendInterrupt(proc)
	}
	return nil
}

func (c *claudeChat) sendInterrupt(proc *claudeProcess) {
	ctx, cancel := context.WithTimeout(context.Background(), min(c.engine.options.controlWait, 5*time.Second))
	_, err := proc.request(ctx, map[string]any{"subtype": "interrupt"})
	cancel()
	if err != nil && proc.alive() {
		proc.kill()
		return
	}
	// The turn should end promptly; if it does not, end the process. A
	// closing engine ends it itself.
	if !c.engine.begin() {
		return
	}
	go func() {
		defer c.engine.work.Done()
		timer := time.NewTimer(10 * time.Second)
		defer timer.Stop()
		select {
		case <-proc.exited:
			return
		case <-timer.C:
		}
		c.mu.Lock()
		stuck := c.proc == proc && c.turn != nil && c.turn.interrupted
		c.mu.Unlock()
		if stuck {
			proc.kill()
		}
	}()
}
