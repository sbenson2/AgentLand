package host

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

var ErrCLIChatBusy = errors.New("the agent is still working")
var ErrCLIChatUnavailable = errors.New("the selected Mac agent is unavailable")

func isCLISessionID(id string) bool {
	return strings.HasPrefix(id, "claude:") || strings.HasPrefix(id, "codex:") || isACPSessionID(id)
}

type CLIChatResult struct {
	NativeID string
	Text     string
}

// CLIChatRunner runs one prompt. Attachments are host files the CLI reads with
// its own tools; the caller removes them after the run.
type CLIChatRunner interface {
	Available() []string
	Run(context.Context, string, string, string, string, []ChatAttachment) (CLIChatResult, error)
}

type cliChatRecord struct {
	Session   Session   `json:"session"`
	Directory string    `json:"directory"`
	NativeID  string    `json:"nativeId,omitempty"`
	Messages  []Message `json:"messages"`
	UpdatedAt time.Time `json:"updatedAt"`
	Busy      bool      `json:"busy,omitempty"`
	// Created holds each message's creation time by message ID. Records
	// written before it existed have none; their messages use UpdatedAt.
	Created map[string]time.Time `json:"created,omitempty"`

	// Codex streaming (codex_record.go): settings, streamed parts and the
	// rewind state of a Codex chat.
	Codex *codexChatRecord `json:"codex,omitempty"`

	// Claude Code streaming (claude_store.go): the chat's settings, fork
	// parent, uuid chain, rewind point and streamed messages, encoded there,
	// and the rewind point again for cheap session reads.
	Claude       json.RawMessage `json:"claude,omitempty"`
	ClaudeRewind string          `json:"claudeRewind,omitempty"`

	// ACP chats (acp_store.go): the agent, its ACP session and modes and the
	// chat's messages.
	ACP *acpChatRecord `json:"acp,omitempty"`
}

// CLIChats keeps only AgentLand-created CLI conversations. Native CLI session
// IDs and the transcript survive host restarts; prompts are never retried.
type CLIChats struct {
	mu      sync.Mutex
	path    string
	runner  CLIChatRunner
	records map[string]*cliChatRecord
	// jobs stop the one-shot runs: with errHostShutdown at the host's
	// shutdown, else with no cause (oneshot.go). None starts once
	// runsStopped is set (stopOneShots).
	jobs        map[string]context.CancelCauseFunc
	wait        sync.WaitGroup
	closed      bool
	runsStopped bool
	// observer learns that a chat's transcript or status changed. It is
	// called without mu held.
	observer func(projectID, sessionID string)

	// Codex streaming (codex_engine.go): the engine that runs Codex chats
	// when the runner provides one; nil keeps them one-shot runs.
	codex *codexEngine

	// Claude Code streaming (claude_engine.go): the engine that runs Claude
	// chats when the runner provides one; nil keeps them one-shot runs.
	claude *claudeEngine

	// ACP chats (acp_engine.go): the engine that runs chats of ACP agents.
	// It runs nothing until the host gives it the agent catalog.
	acp *acpEngine

	// processes records the agent processes the engines start, so the next
	// host ends those a killed host left running (acp_leftovers.go).
	processes *agentProcesses
}

func NewCLIChats(path string, runner CLIChatRunner) (*CLIChats, error) {
	c := &CLIChats{path: path, runner: runner, records: map[string]*cliChatRecord{}, jobs: map[string]context.CancelCauseFunc{}, processes: newAgentProcesses()}
	// Codex streaming (codex_engine.go).
	if engineRunner, ok := runner.(codexEngineRunner); ok {
		c.codex = newCodexEngine(c, engineRunner.codexEngineConfig())
	}
	// Claude Code streaming (claude_engine.go).
	if engineRunner, ok := runner.(claudeEngineRunner); ok {
		c.claude = newClaudeEngine(c, engineRunner.claudeEngineConfig())
	}
	// ACP chats (acp_engine.go).
	c.acp = newACPEngine(c, acpConfig{})
	data, err := readPrivateState(path)
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &c.records); err != nil {
		return nil, err
	}
	recovered := false
	for _, record := range c.records {
		if record.Busy {
			record.Busy = false
			message := Message{ID: cliMessageID(), Role: "assistant", Error: "The Mac agent stopped before this reply completed."}
			record.Messages = append(record.Messages, message)
			record.setCreated(message.ID, time.Now())
			recovered = true
		}
	}
	if recovered {
		if err := c.saveLocked(); err != nil {
			return nil, err
		}
	}
	return c, nil
}

func cliMessageID() string {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data[:])
}

func (c *CLIChats) Available() []string {
	if c == nil {
		return nil
	}
	return c.runner.Available()
}

func (record *cliChatRecord) setCreated(id string, at time.Time) {
	if record.Created == nil {
		record.Created = map[string]time.Time{}
	}
	record.Created[id] = at.UTC()
}

// setObserver registers the one function told about transcript and status
// changes (the chat hub).
func (c *CLIChats) setObserver(observer func(projectID, sessionID string)) {
	c.mu.Lock()
	c.observer = observer
	c.mu.Unlock()
}

func (c *CLIChats) notify(projectID, sessionID string) {
	c.mu.Lock()
	observer := c.observer
	c.mu.Unlock()
	if observer != nil {
		observer(projectID, sessionID)
	}
}

// cliTranscript is one consistent read of a chat for the chat hub.
type cliTranscript struct {
	session  Session
	messages []Message
	created  map[string]time.Time
	updated  time.Time
	busy     bool
}

func (c *CLIChats) transcript(project Project, id string) (cliTranscript, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return cliTranscript{}, err
	}
	created := make(map[string]time.Time, len(record.Created))
	for key, value := range record.Created {
		created[key] = value
	}
	return cliTranscript{session: record.Session, messages: append([]Message{}, record.Messages...), created: created, updated: record.UpdatedAt, busy: record.Busy}, nil
}

func (c *CLIChats) available(provider string) bool {
	for _, item := range c.Available() {
		if item == provider {
			return true
		}
	}
	return false
}

// nativeAgentBusy reports a native Claude Code or Codex turn in flight.
// The agent catalog uses it to keep a self-update away from active chats.
func (c *CLIChats) nativeAgentBusy(provider string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, record := range c.records {
		if record.Session.Provider == provider && record.Busy {
			return true
		}
	}
	return false
}

// adoptUpdatedAgent stops only idle processes after their executable was
// replaced. Chat records and native thread/session IDs remain in CLIChats and
// are resumed by the next process.
func (c *CLIChats) adoptUpdatedAgent(provider string) {
	switch provider {
	case "codex":
		if c.codex != nil {
			c.codex.stopIfIdle()
		}
	case "claude":
		if c.claude != nil {
			c.claude.stopIdle()
		}
	}
}

func (c *CLIChats) saveLocked() error {
	data, err := json.Marshal(c.records)
	if err != nil {
		return err
	}
	return writePrivateState(c.path, append(data, '\n'))
}

func (c *CLIChats) CreateSession(project Project, title, provider string) (Session, error) {
	if provider != "claude" && provider != "codex" {
		return Session{}, ErrCLIChatUnavailable
	}
	if !c.available(provider) {
		return Session{}, ErrCLIChatUnavailable
	}
	// Claude Code and Codex chats are made only in workspaces since
	// 2026-10-12; the Chats space keeps its older ones readable.
	if project.ID == plainChatsProjectID {
		return Session{}, errChatsSpaceRetired
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Session{}, ErrCLIChatUnavailable
	}
	id := provider + ":" + cliMessageID()
	if title == "" {
		title = chatProviderNames[provider]
	}
	// Chat names (chat_title.go): a placeholder is "default"; a title the
	// chat was created with is its creator's, like a provider's own.
	session := Session{ID: id, Title: title, ProjectID: project.ID, Directory: project.Directory, Provider: provider, TitleSource: titleSourceFor(title)}
	c.records[id] = &cliChatRecord{Session: session, Directory: project.Directory, Messages: []Message{}, UpdatedAt: time.Now()}
	if err := c.saveLocked(); err != nil {
		delete(c.records, id)
		return Session{}, err
	}
	return session, nil
}

// setChatName stores a chat's name with its source and basis (chat names,
// chat_title.go). The chat's activity time is unchanged, so a rename never
// reorders the chat list.
func (c *CLIChats) setChatName(project Project, id string, name chatName) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return err
	}
	previous := record.Session
	record.Session.Title, record.Session.TitleSource, record.Session.TitleBasis = name.Title, name.Source, name.Basis
	if err := c.saveLocked(); err != nil {
		record.Session = previous
		return err
	}
	return nil
}

// storedName is a chat's name as the registry has it, its source worked out
// for records from before sources were kept.
func (c *CLIChats) storedName(id string) (chatName, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record := c.records[id]
	if record == nil {
		return chatName{}, false
	}
	return sessionName(record.Session), true
}

// sessionName is a Claude Code or Codex chat's stored name.
func sessionName(session Session) chatName {
	if session.TitleSource == "" {
		return chatName{Title: session.Title, Source: titleSourceFor(session.Title)}
	}
	return chatName{Title: session.Title, Source: session.TitleSource, Basis: session.TitleBasis}
}

func (c *CLIChats) recordLocked(project Project, id string) (*cliChatRecord, error) {
	record := c.records[id]
	if record == nil || record.Session.ProjectID != project.ID || !sameDirectory(record.Directory, project.Directory) {
		return nil, ErrNotFound
	}
	return record, nil
}

func (c *CLIChats) GetSession(project Project, id string) (Session, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return Session{}, err
	}
	session := record.Session
	session.Directory = record.Directory
	// Codex streaming: a rewound Codex chat hides its latest turn.
	session.RewindMessageID = record.codexRewind()
	// Claude Code streaming: so does a rewound Claude chat.
	if record.Claude != nil {
		session.RewindMessageID = record.ClaudeRewind
	}
	return session, nil
}

func (c *CLIChats) ListSessions(project Project) []Session {
	c.mu.Lock()
	defer c.mu.Unlock()
	type entry struct {
		session Session
		updated time.Time
	}
	items := []entry{}
	for id := range c.records {
		if record, err := c.recordLocked(project, id); err == nil {
			session := record.Session
			session.Directory = record.Directory
			items = append(items, entry{session, record.UpdatedAt})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].updated.After(items[j].updated) })
	result := make([]Session, len(items))
	for i, item := range items {
		result[i] = item.session
	}
	return result
}

func (c *CLIChats) Messages(project Project, id string) ([]Message, error) {
	// Claude Code streaming: the engine holds a Claude chat's transcript.
	if c.claude != nil && isClaudeSessionID(id) {
		return c.claude.legacyTranscript(project, id)
	}
	// ACP chats: so does the ACP engine.
	if isACPSessionID(id) {
		return c.acp.legacyTranscript(project, id)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return nil, err
	}
	// Codex streaming: messages from a rewind point on stay hidden, and
	// streamed messages carry their parts.
	return record.visibleMessages(), nil
}

func (c *CLIChats) Status(project Project, id string) (ChatStatus, error) {
	// Claude Code streaming: the engine knows whether a turn runs.
	if c.claude != nil && isClaudeSessionID(id) {
		return c.claude.status(project, id)
	}
	// ACP chats: so does the ACP engine.
	if isACPSessionID(id) {
		return c.acp.status(project, id)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		return ChatStatus{}, err
	}
	if record.Busy {
		return ChatStatus{State: "busy"}, nil
	}
	return ChatStatus{State: "idle"}, nil
}

func (c *CLIChats) Options(project Project, id string) (ChatOptions, error) {
	session, err := c.GetSession(project, id)
	if err != nil {
		return ChatOptions{}, err
	}
	// Codex streaming: Codex's models (model/list) and approval modes.
	if session.Provider == "codex" && c.codex != nil {
		return c.codex.chatOptions(), nil
	}
	// Claude Code streaming: models from initialize, permission modes, efforts.
	if session.Provider == "claude" && c.claude != nil {
		return c.claude.chatOptions(project), nil
	}
	// ACP chats: the agent's default model and the modes it listed.
	if isACPSessionID(id) {
		return c.acp.chatOptions(project, id)
	}
	name := chatProviderNames[session.Provider]
	model := session.Provider + "/default"
	return ChatOptions{Models: []ChatModel{{ID: model, Name: "Default", Provider: name}}, DefaultModel: model, Agents: []string{"build"}}, nil
}

func cliOptionsSupported(provider string, options PromptOptions) bool {
	return (options.Model == "" || options.Model == provider+"/default") && (options.Agent == "" || options.Agent == "build")
}

// Prompt starts one run. When it returns nil, finished (if any) is called
// exactly once after the run ends; on an error the run never started.
func (c *CLIChats) Prompt(project Project, id, text string, options PromptOptions, attachments []ChatAttachment, finished func()) error {
	return c.PromptAs(project, id, cliMessageID(), text, options, attachments, finished)
}

// PromptAs is Prompt with the user message's ID chosen by the caller, so the
// host can return it in the send receipt.
func (c *CLIChats) PromptAs(project Project, id, messageID, text string, options PromptOptions, attachments []ChatAttachment, finished func()) error {
	// The Chats space's chats are read-only (errChatsSpaceRetired).
	if project.ID == plainChatsProjectID {
		return errChatsSpaceRetired
	}
	c.mu.Lock()
	record, err := c.recordLocked(project, id)
	if err != nil {
		c.mu.Unlock()
		return err
	}
	// Codex streaming: Codex chats run through the Codex engine.
	if record.Session.Provider == "codex" && c.codex != nil {
		c.mu.Unlock()
		return c.codex.prompt(project, id, messageID, text, options, attachments, finished)
	}
	// Claude Code streaming: Claude chats send through their provider
	// (claude_provider.go), never as a one-shot run beside their process.
	// ACP chats likewise (acp_provider.go).
	if (record.Session.Provider == "claude" && c.claude != nil) || isACPSessionID(id) {
		c.mu.Unlock()
		return fmt.Errorf("%w: %w", ErrCLIChatUnavailable, errPromptNotSent)
	}
	if c.closed || c.runsStopped {
		c.mu.Unlock()
		return ErrCLIChatUnavailable
	}
	if record.Busy {
		c.mu.Unlock()
		return ErrCLIChatBusy
	}
	if !cliOptionsSupported(record.Session.Provider, options) {
		c.mu.Unlock()
		return ErrCLIChatUnavailable
	}
	previous := append([]Message{}, record.Messages...)
	user := Message{ID: messageID, Role: "user", Text: text}
	for _, attachment := range attachments {
		user.Attachments = append(user.Attachments, AttachmentInfo{Name: attachment.Name, MIME: attachment.MIME})
	}
	record.Messages = append(record.Messages, user)
	record.Busy = true
	record.UpdatedAt = time.Now()
	record.setCreated(user.ID, record.UpdatedAt)
	if err := c.saveLocked(); err != nil {
		record.Messages = previous
		record.Busy = false
		delete(record.Created, user.ID)
		c.mu.Unlock()
		return err
	}
	base, stop := context.WithCancelCause(context.Background())
	ctx, cancel := context.WithTimeout(base, 10*time.Minute)
	c.jobs[id] = stop
	provider, directory, nativeID, projectID := record.Session.Provider, record.Directory, record.NativeID, record.Session.ProjectID
	c.wait.Add(1)
	c.mu.Unlock()
	c.notify(projectID, id)
	go func() {
		defer c.wait.Done()
		if finished != nil {
			defer finished()
		}
		result, runErr := c.runner.Run(ctx, provider, directory, nativeID, text, attachments)
		cancel()
		stop(nil)
		c.mu.Lock()
		delete(c.jobs, id)
		if current := c.records[id]; current != nil {
			current.Busy = false
			current.UpdatedAt = time.Now()
			message := Message{ID: cliMessageID(), Role: "assistant"}
			if runErr != nil {
				message.Error = provider + " could not complete this request. Check its sign-in and permissions on the Mac."
			}
			if runErr == nil {
				current.NativeID = result.NativeID
				message.Text = result.Text
				if len(message.Text) > 128<<10 {
					message.Text = message.Text[:128<<10] + "\n[Output truncated]"
				}
			}
			current.Messages = append(current.Messages, message)
			current.setCreated(message.ID, current.UpdatedAt)
			_ = c.saveLocked()
		}
		c.mu.Unlock()
		c.notify(projectID, id)
	}()
	return nil
}

func (c *CLIChats) Abort(project Project, id string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, err := c.recordLocked(project, id); err != nil {
		return err
	}
	if stop := c.jobs[id]; stop != nil {
		stop(nil)
	}
	return nil
}

// stopOneShots ends the chats' one-shot runs for good: each run's group
// gets SIGTERM at once and SIGKILL after agentShutdownKill (oneshot.go), and
// no run starts after it.
func (c *CLIChats) stopOneShots() {
	c.mu.Lock()
	c.runsStopped = true
	for _, stop := range c.jobs {
		stop(errHostShutdown)
	}
	c.mu.Unlock()
}

func (c *CLIChats) Close() {
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	c.stopOneShots()
	// The agents' processes end in parallel with the rest.
	agents := make(chan struct{})
	go func() {
		defer close(agents)
		c.stopAgents()
	}()
	c.wait.Wait()
	<-agents
}

// agentShutdownKill is how long an agent's process group has between
// SIGTERM and SIGKILL when the host shuts down: the Mac app kills the host
// 2 s after asking it to stop, and an agent still running then is left
// behind.
const agentShutdownKill = time.Second

// stopAgents ends the Claude Code, Codex and ACP chats for good and their
// agents' processes: stdin closes and every process group gets SIGTERM at
// once, then SIGKILL after agentShutdownKill; so do the one-shot runs. The
// host starts this when HTTP shutdown begins (BeginShutdown), not after the
// drain. It returns once the processes are gone; later calls wait for the
// first.
func (c *CLIChats) stopAgents() {
	c.stopOneShots()
	var group sync.WaitGroup
	// Claude Code streaming: stop every Claude process.
	if c.claude != nil {
		group.Add(1)
		go func() {
			defer group.Done()
			c.claude.close()
		}()
	}
	// Codex streaming: stop the app-server and codex exec runs.
	if c.codex != nil {
		group.Add(1)
		go func() {
			defer group.Done()
			c.codex.close()
		}()
	}
	// ACP chats: stop every agent process.
	c.acp.close()
	group.Wait()
}

type HostCLIChatRunner struct{}

func (HostCLIChatRunner) Available() []string {
	result := []string{}
	for _, name := range []string{"claude", "codex"} {
		if _, ok := executableForProgram(name); ok {
			result = append(result, name)
		}
	}
	return result
}

func (HostCLIChatRunner) Run(ctx context.Context, provider, directory, nativeID, prompt string, attachments []ChatAttachment) (CLIChatResult, error) {
	executable, ok := executableForProgram(provider)
	if !ok {
		return CLIChatResult{}, ErrCLIChatUnavailable
	}
	return runCLIOneShot(ctx, executable, provider, directory, nativeID, prompt, attachments)
}

// runCLIOneShot runs one `claude -p` or `codex exec` prompt with executable,
// in a process group of its own (oneshot.go): when ctx ends, the group gets
// SIGTERM at once and SIGKILL after oneShotGraceFor(ctx); what is left of it
// ends when the run does.
func runCLIOneShot(ctx context.Context, executable, provider, directory, nativeID, prompt string, attachments []ChatAttachment) (CLIChatResult, error) {
	invocation, err := cliChatInvocation(provider, directory, nativeID, prompt, attachments)
	if err != nil {
		return CLIChatResult{}, err
	}
	command := exec.Command(executable, invocation.args...)
	command.Dir = directory
	command.Stdin = strings.NewReader(invocation.input)
	command.Env = oneShotEnvironment()
	output := &cappedGitOutput{limit: 4 << 20}
	command.Stdout = output
	command.Stderr = &cappedGitOutput{limit: 16 << 10}
	command.SysProcAttr = claudeProcessAttributes()
	// Output a tool of the run still holds after the run ended is cut then.
	command.WaitDelay = oneShotStopGrace
	if err := ctx.Err(); err != nil {
		return CLIChatResult{}, err
	}
	if err := command.Start(); err != nil {
		return CLIChatResult{}, err
	}
	group := newOneShotGroup(command.Process)
	finished := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			group.stop(oneShotGraceFor(ctx))
		case <-finished:
		}
	}()
	err = command.Wait()
	close(finished)
	group.ended()
	if ctx.Err() != nil {
		return CLIChatResult{}, ctx.Err()
	}
	if err != nil {
		return CLIChatResult{}, err
	}
	return parseCLIChatOutput(provider, invocation.nativeID, output.Bytes())
}

// oneShotEnvironment is the host's environment without AgentLand's own and
// OpenCode's server variables or an API key: chats run on the subscription
// (chat_subscription.go).
func oneShotEnvironment() []string {
	environment := []string{}
	for _, item := range withoutChatAPIKeys(os.Environ()) {
		name, _, _ := strings.Cut(item, "=")
		if strings.HasPrefix(name, "AGENTLAND_") || strings.HasPrefix(name, "OPENCODE_SERVER_") {
			continue
		}
		environment = append(environment, item)
	}
	return environment
}

type cliInvocation struct {
	args     []string
	input    string
	nativeID string
}

// cliChatInvocation uses fixed arguments plus host-generated attachment paths.
// Multi-value flags are followed by another flag so no later argument (or the
// "-" stdin marker) can be taken as an extra attachment.
func cliChatInvocation(provider, directory, nativeID, prompt string, attachments []ChatAttachment) (cliInvocation, error) {
	var args []string
	listed := attachments
	switch provider {
	case "claude":
		args = []string{"-p"}
		added := map[string]bool{}
		for _, attachment := range attachments {
			if folder := filepath.Dir(attachment.Path); !added[folder] {
				added[folder] = true
				args = append(args, "--add-dir", folder)
			}
		}
		args = append(args, "--output-format", "json", "--permission-mode", "auto")
		if nativeID == "" {
			newID := cliMessageID()
			nativeID = fmt.Sprintf("%s-%s-%s-%s-%s", newID[:8], newID[8:12], newID[12:16], newID[16:20], newID[20:])
			args = append(args, "--session-id", nativeID)
		} else {
			args = append(args, "--resume", nativeID)
		}
	case "codex":
		// Codex argv (codex_exec.go): a resumed run keeps the sandbox and
		// approvals of a new one, and Codex 0.156.1 refuses --sandbox with
		// --approve-for-me.
		args, listed = codexExecArgs(directory, nativeID, attachments, codexSettings{mode: codexDefaultMode}, nil)
	default:
		return cliInvocation{}, ErrCLIChatUnavailable
	}
	input := prompt
	if len(listed) > 0 {
		if input != "" {
			input += "\n\n"
		}
		input += "Attached files (read them with your tools):"
		for _, attachment := range listed {
			input += "\n- " + attachment.Path + " (" + attachment.Name + ")"
		}
	}
	if input == "" && len(attachments) > 0 {
		input = "See the attached images."
	}
	return cliInvocation{args: args, input: input, nativeID: nativeID}, nil
}

func parseCLIChatOutput(provider, nativeID string, output []byte) (CLIChatResult, error) {
	if provider == "claude" {
		var payload struct {
			Result    string `json:"result"`
			SessionID string `json:"session_id"`
			IsError   bool   `json:"is_error"`
		}
		if err := json.Unmarshal(output, &payload); err != nil {
			return CLIChatResult{}, err
		}
		if payload.IsError || payload.Result == "" {
			return CLIChatResult{}, errors.New("Claude did not return a reply")
		}
		if payload.SessionID != "" {
			nativeID = payload.SessionID
		}
		return CLIChatResult{NativeID: nativeID, Text: payload.Result}, nil
	}
	result := CLIChatResult{NativeID: nativeID}
	if provider != "codex" {
		return CLIChatResult{}, ErrCLIChatUnavailable
	}
	scanner := bufio.NewScanner(bytes.NewReader(output))
	scanner.Buffer(make([]byte, 64<<10), 4<<20)
	for scanner.Scan() {
		var event struct {
			Type     string `json:"type"`
			ThreadID string `json:"thread_id"`
			Item     struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"item"`
		}
		if json.Unmarshal(scanner.Bytes(), &event) != nil {
			continue
		}
		if event.Type == "thread.started" && event.ThreadID != "" {
			result.NativeID = event.ThreadID
		}
		if event.Type == "item.completed" && event.Item.Type == "agent_message" {
			result.Text = event.Item.Text
		}
	}
	if err := scanner.Err(); err != nil {
		return CLIChatResult{}, err
	}
	if result.NativeID == "" || result.Text == "" {
		return CLIChatResult{}, errors.New("Codex did not return a session and reply")
	}
	return result, nil
}
