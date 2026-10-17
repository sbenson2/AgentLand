package host

import (
	"context"
	"errors"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// The Codex engine runs Codex chats as a streaming provider: one shared
// `codex app-server` per host, started on first use, speaking JSON-RPC over
// stdio (codex_rpc.go). When that server cannot start, prompts run through a
// streamed `codex exec --json` instead (codex_exec.go), without approvals.
//
// Codex 0.156.x, 0.162.0 and every later 0.x release are the tested ranges
// (TestCodexContract confirmed 0.162.1 on 2026-10-12; 0.163.0's app-server
// schema, compared with 0.162.1's on 2026-10-16, only gained methods and
// fields) and run in full mode, as Chat's version rule accepts them
// (codexVersionFrom162). Any other version
// runs in compatibility mode: unknown notifications and items are ignored
// (as in full mode) and a method Codex does not know disables the feature
// that needs it, which capabilities then leave out. Experimental API is negotiated for the general-chat profile’s
// empty environment list; coding sessions keep their existing parameters.

// codexEngineConfig holds the engine's paths and timing. Production uses the
// zero value; tests point it at a fake codex and shorten the timing.
type codexEngineConfig struct {
	// executable returns the codex binary; nil resolves "codex" the way
	// terminals do.
	executable func() (string, bool)
	// prefixArgs go before the subcommand (a test helper process), configArgs
	// after it for app-server and exec alike (-c overrides in contract tests).
	prefixArgs []string
	configArgs []string
	// env is added to the filtered host environment.
	env []string
	// dir is the app-server's working directory; threads set their own cwd.
	dir string
	// execOnly skips the app-server (tests of the exec fallback).
	execOnly bool

	backoff      []time.Duration
	stableAfter  time.Duration
	idleStop     time.Duration
	idleCheck    time.Duration
	startTimeout time.Duration
	callTimeout  time.Duration
	fallbackFor  time.Duration
	execLimit    time.Duration
	saveEvery    time.Duration
	maxThreads   int
	lineLimit    int
	// log receives diagnostics (a crash's stderr tail, compatibility mode);
	// nil writes them to the host's stderr.
	log func(string)
}

func (c codexEngineConfig) logf(message string) {
	if c.log != nil {
		c.log(message)
		return
	}
	os.Stderr.WriteString("agentland-host: " + message + "\n")
}

// codexEngineRunner is implemented by CLI chat runners whose Codex chats run
// through the Codex engine instead of Run.
type codexEngineRunner interface {
	codexEngineConfig() codexEngineConfig
}

// codexEngineConfig makes the host's own runner stream Codex chats.
func (HostCLIChatRunner) codexEngineConfig() codexEngineConfig { return codexEngineConfig{} }

func (c codexEngineConfig) resolve() (string, bool) {
	if c.executable != nil {
		return c.executable()
	}
	return executableForProgram("codex")
}

func (c codexEngineConfig) processDir() string {
	if c.dir != "" {
		return c.dir
	}
	if home, err := os.UserHomeDir(); err == nil {
		return home
	}
	return os.TempDir()
}

func (c codexEngineConfig) duration(value, fallback time.Duration) time.Duration {
	if value > 0 {
		return value
	}
	return fallback
}

func (c codexEngineConfig) backoffAt(crashes int) time.Duration {
	steps := c.backoff
	if len(steps) == 0 {
		steps = []time.Duration{time.Second, 5 * time.Second, 30 * time.Second}
	}
	return steps[min(crashes, len(steps)-1)]
}

func (c codexEngineConfig) lineLimitOrDefault() int {
	if c.lineLimit > 0 {
		return c.lineLimit
	}
	return codexLineLimit
}

func (c codexEngineConfig) startTimeoutOrDefault() time.Duration {
	return c.duration(c.startTimeout, 15*time.Second)
}

func (c codexEngineConfig) maxThreadsOrDefault() int {
	if c.maxThreads > 0 {
		return c.maxThreads
	}
	return 16
}

// codexTestedVersion reports whether a Codex version is in the range the
// adapter was verified against (full mode). It only decides whether the
// engine logs that it runs in compatibility mode.
func codexTestedVersion(version string) bool {
	return strings.HasPrefix(version, "0.156.") || codexVersionFrom162(version)
}

// Codex approval presets offered as chat modes. Ask, a new chat's mode
// (owner, 2026-10-12), asks the user in the chat for what the
// workspace-write sandbox does not allow. Auto-review is today's
// `codex exec --approve-for-me`: the same sandbox, with commands that need
// more reviewed by Codex's own reviewer instead of the user. codex exec has
// no one to ask, so there auto-review is the default (codexExecDefaultMode).
const (
	codexDefaultMode     = "ask"
	codexExecDefaultMode = "auto-review"
)

// codexIdleStop is how long the shared app-server may sit idle before the
// host stops it (Codex forgets its chats' session approvals then).
const codexIdleStop = 15 * time.Minute

type codexMode struct {
	id, name      string
	sandbox       string // thread/start, thread/resume and thread/fork
	sandboxPolicy string // turn/start
	approval      string
	reviewer      string
	// execConfig is the codex exec configuration; exec cannot ask the user.
	execConfig []string
}

var codexModes = []codexMode{
	{id: "ask", name: "Ask", sandbox: "workspace-write", sandboxPolicy: "workspaceWrite", approval: "on-request", reviewer: "user", execConfig: []string{`sandbox_mode="workspace-write"`, `approval_policy="on-request"`, `approvals_reviewer="auto_review"`}},
	{id: "auto-review", name: "Auto-review", sandbox: "workspace-write", sandboxPolicy: "workspaceWrite", approval: "on-request", reviewer: "auto_review", execConfig: []string{`sandbox_mode="workspace-write"`, `approval_policy="on-request"`, `approvals_reviewer="auto_review"`}},
	{id: "read-only", name: "Read only", sandbox: "read-only", sandboxPolicy: "readOnly", approval: "on-request", reviewer: "user", execConfig: []string{`sandbox_mode="read-only"`, `approval_policy="never"`}},
	{id: "full-access", name: "Full access", sandbox: "danger-full-access", sandboxPolicy: "dangerFullAccess", approval: "never", reviewer: "user", execConfig: []string{`sandbox_mode="danger-full-access"`, `approval_policy="never"`}},
}

func codexModeByID(id string) (codexMode, bool) {
	for _, mode := range codexModes {
		if mode.id == id {
			return mode, true
		}
	}
	return codexMode{}, false
}

// codexSettings are a chat's Codex model, mode and reasoning effort.
type codexSettings struct {
	model  string // Codex model slug; empty uses Codex's configured default
	mode   string
	effort string // empty uses the model's default
}

func (record *cliChatRecord) codexSettings() codexSettings {
	settings := codexSettings{mode: codexDefaultMode}
	if record.Codex != nil {
		settings.model, settings.effort = record.Codex.Model, record.Codex.Effort
		if _, ok := codexModeByID(record.Codex.Mode); ok {
			settings.mode = record.Codex.Mode
		}
	}
	return settings
}

func (s codexSettings) modeSpec() codexMode {
	mode, ok := codexModeByID(s.mode)
	if !ok {
		mode, _ = codexModeByID(codexDefaultMode)
	}
	return mode
}

// modelID is the conversation model's model ID, "codex/<slug>".
func (s codexSettings) modelID() string {
	if s.model == "" {
		return "codex/default"
	}
	return "codex/" + s.model
}

var codexEffortPattern = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)

// with applies a prompt's model, mode and effort; an empty field keeps the
// chat's setting. It reports false for values the chat cannot use.
func (s codexSettings) with(options PromptOptions) (codexSettings, bool) {
	if options.Agent != "" && options.Agent != "build" {
		return s, false
	}
	switch {
	case options.Model == "":
	case options.Model == "codex/default":
		s.model = ""
	case strings.HasPrefix(options.Model, "codex/") && validPromptOptions(PromptOptions{Model: options.Model}):
		s.model = strings.TrimPrefix(options.Model, "codex/")
	default:
		return s, false
	}
	if options.Mode != "" {
		if _, ok := codexModeByID(options.Mode); !ok {
			return s, false
		}
		s.mode = options.Mode
	}
	if options.Effort != "" {
		if !codexEffortPattern.MatchString(options.Effort) {
			return s, false
		}
		s.effort = options.Effort
	}
	return s, true
}

// codexModel is one entry of model/list.
type codexModel struct {
	ID                        string `json:"id"`
	Model                     string `json:"model"`
	DisplayName               string `json:"displayName"`
	Hidden                    bool   `json:"hidden"`
	DefaultReasoningEffort    string `json:"defaultReasoningEffort"`
	SupportedReasoningEfforts []struct {
		ReasoningEffort string `json:"reasoningEffort"`
	} `json:"supportedReasoningEfforts"`
}

// codexLoaded is a thread loaded in one app-server process.
type codexLoaded struct {
	used time.Time
	mode string // the mode the thread was started or resumed with
}

// codexEngine runs the Codex chats of one CLIChats. Chat state (turns,
// threads, pending requests, records) is guarded by chats.mu; the connection
// state below by mu. Code holding chats.mu may call the hub, never Codex.
type codexEngine struct {
	chats  *CLIChats
	config codexEngineConfig
	hub    *chatHub // set by the host; guarded by chats.mu

	mu            sync.Mutex
	conn          *codexConn
	starting      chan struct{}
	crashes       int
	nextStart     time.Time
	fallbackUntil time.Time
	version       string
	missing       map[string]bool
	lastActive    time.Time
	busy          int
	closed        bool
	closing       chan struct{}
	closeOnce     sync.Once
	janitor       bool
	work          sync.WaitGroup

	turns    map[string]*codexTurn    // by session ID
	threads  map[string]sessionKey    // by Codex thread ID
	requests map[string]*codexPending // by interaction ID
}

func newCodexEngine(chats *CLIChats, config codexEngineConfig) *codexEngine {
	return &codexEngine{chats: chats, config: config, missing: map[string]bool{}, closing: make(chan struct{}), turns: map[string]*codexTurn{}, threads: map[string]sessionKey{}, requests: map[string]*codexPending{}}
}

// begin registers work that close waits for; false once the engine closed.
func (e *codexEngine) begin() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return false
	}
	e.work.Add(1)
	return true
}

// hold and release count what keeps the app-server from stopping when idle:
// running turns and calls in flight.
func (e *codexEngine) hold() {
	e.mu.Lock()
	e.busy++
	e.lastActive = time.Now()
	e.mu.Unlock()
}

func (e *codexEngine) release() {
	e.mu.Lock()
	e.busy--
	e.lastActive = time.Now()
	e.mu.Unlock()
}

func (e *codexEngine) touch() {
	e.mu.Lock()
	e.lastActive = time.Now()
	e.mu.Unlock()
}

// noteMissing disables the feature behind a method Codex does not know.
func (e *codexEngine) noteMissing(method string, err error) {
	var rpc *codexRPCError
	if errors.As(err, &rpc) && rpc.methodMissing() {
		e.mu.Lock()
		e.missing[method] = true
		e.mu.Unlock()
	}
}

func (e *codexEngine) lacks(method string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.missing[method]
}

func (e *codexEngine) execTransport() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.execTransportLocked()
}

func (e *codexEngine) execTransportLocked() bool {
	return e.config.execOnly || time.Now().Before(e.fallbackUntil) || e.missing["turn/start"] || e.missing["thread/start"]
}

// connection returns the running app-server, starting it when needed. A
// start after a crash waits out the backoff (1, 5, then 30 s). A failed
// handshake returns errCodexHandshake and sends prompts to codex exec for a
// while.
func (e *codexEngine) connection() (*codexConn, error) {
	e.mu.Lock()
	for {
		switch {
		case e.closed:
			e.mu.Unlock()
			return nil, errCodexStopped
		case e.conn != nil && !e.conn.exited():
			conn := e.conn
			e.lastActive = time.Now()
			e.mu.Unlock()
			return conn, nil
		case e.starting != nil:
			wait := e.starting
			e.mu.Unlock()
			<-wait
			e.mu.Lock()
			continue
		case e.execTransportLocked():
			e.mu.Unlock()
			return nil, errCodexHandshake
		}
		starting := make(chan struct{})
		e.starting = starting
		delay := time.Until(e.nextStart)
		e.mu.Unlock()
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-timer.C:
			case <-e.closing:
			}
			timer.Stop()
		}
		conn, err := startCodexConn(e.config, e)
		e.mu.Lock()
		close(starting)
		e.starting = nil
		if err != nil {
			e.fallbackUntil = time.Now().Add(e.config.duration(e.config.fallbackFor, 10*time.Minute))
			e.mu.Unlock()
			return nil, err
		}
		if e.closed {
			e.mu.Unlock()
			conn.stop(time.Second)
			return nil, errCodexStopped
		}
		if conn.version != e.version {
			// Another Codex version may know other methods.
			e.missing = map[string]bool{}
		}
		e.conn, e.version, e.lastActive = conn, conn.version, time.Now()
		if !codexTestedVersion(conn.version) {
			e.config.logf("Codex " + conn.version + " is outside the tested 0.156.x and 0.162 and later 0.x ranges; running in compatibility mode")
		}
		if !e.janitor {
			e.janitor = true
			e.work.Add(1)
			go e.runJanitor()
		}
	}
}

// runJanitor stops the app-server after it has been idle for 15 minutes.
func (e *codexEngine) runJanitor() {
	defer e.work.Done()
	ticker := time.NewTicker(e.config.duration(e.config.idleCheck, time.Minute))
	defer ticker.Stop()
	for {
		select {
		case <-e.closing:
			return
		case <-ticker.C:
		}
		e.mu.Lock()
		conn := e.conn
		idle := conn != nil && e.busy == 0 && time.Since(e.lastActive) >= e.config.duration(e.config.idleStop, codexIdleStop)
		replaced := conn != nil && e.busy == 0 && e.executableReplaced(conn)
		if idle || replaced {
			e.conn = nil
		}
		e.mu.Unlock()
		if idle || replaced {
			conn.stop(2 * time.Second)
		}
	}
}

func (e *codexEngine) executableReplaced(conn *codexConn) bool {
	path, ok := e.config.resolve()
	if !ok {
		return false
	}
	current, ok := identifyExecutable(path)
	return ok && conn.binary.info != nil && !conn.binary.same(current)
}

// stopIfIdle retires the current app-server at a safe boundary. The next
// Codex operation starts the newly installed binary and resumes its thread.
func (e *codexEngine) stopIfIdle() bool {
	e.mu.Lock()
	conn := e.conn
	idle := conn != nil && e.busy == 0
	if idle {
		e.conn = nil
	}
	e.mu.Unlock()
	if idle {
		conn.stop(2 * time.Second)
	}
	return idle
}

// codexStarted records a new app-server for the next host: the executable
// exactly as it was run (acp_leftovers.go).
func (e *codexEngine) codexStarted(conn *codexConn) {
	e.chats.processes.add(conn, executableRecord(conn.command.Process, conn.command.Path))
}

// codexEnded forgets an app-server that was reaped, before a stop or the
// shutdown that waits for it goes on.
func (e *codexEngine) codexEnded(conn *codexConn) {
	e.chats.processes.remove(conn)
}

// codexClosed learns that an app-server exited. A crash delays the next
// start; every turn and request that lived in that process ends.
func (e *codexEngine) codexClosed(conn *codexConn, crashed bool) {
	if !conn.wasReady() {
		// The handshake failed; startCodexConn reports that.
		return
	}
	e.mu.Lock()
	if e.conn == conn {
		e.conn = nil
	}
	if crashed {
		if time.Since(conn.started) >= e.config.duration(e.config.stableAfter, time.Minute) {
			e.crashes = 0
		}
		e.nextStart = time.Now().Add(e.config.backoffAt(e.crashes))
		e.crashes++
		message := "codex app-server exited unexpectedly"
		if tail := strings.TrimSpace(conn.stderr.tail()); tail != "" {
			message += ": " + lastLines(tail, 2<<10)
		}
		e.config.logf(message)
	}
	e.mu.Unlock()
	e.connectionLost(conn)
}

func lastLines(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	text = text[len(text)-limit:]
	if index := strings.IndexByte(text, '\n'); index >= 0 {
		text = text[index+1:]
	}
	return text
}

// capability describes Codex for GET /v1/capabilities: the transport in use
// and the features that work there. Before the first start the app-server is
// assumed.
func (e *codexEngine) capability() *chatProviderEntry {
	e.mu.Lock()
	defer e.mu.Unlock()
	entry := &chatProviderEntry{Version: e.version, Transport: "app-server", Features: []string{}}
	if e.execTransportLocked() {
		entry.Transport = "exec"
	} else {
		if !e.missing["thread/revert"] {
			entry.Features = append(entry.Features, "rewind")
		}
		if !e.missing["thread/fork"] {
			entry.Features = append(entry.Features, "fork")
		}
		entry.Features = append(entry.Features, "approvals")
	}
	entry.Features = append(entry.Features, "modes", "effort")
	return entry
}

// chatOptions lists Codex's models (model/list, with their reasoning
// efforts) and the approval modes.
func (e *codexEngine) chatOptions() ChatOptions {
	result := ChatOptions{Models: []ChatModel{{ID: "codex/default", Name: "Default", Provider: chatProviderNames["codex"]}}, DefaultModel: "codex/default", Agents: []string{"build"}, Modes: []ChatMode{}, DefaultMode: codexDefaultMode}
	exec := e.execTransport()
	if exec {
		result.DefaultMode = codexExecDefaultMode
	}
	for _, mode := range codexModes {
		if exec && mode.id == "ask" {
			continue // codex exec has no one to ask
		}
		result.Modes = append(result.Modes, ChatMode{ID: mode.id, Name: mode.name})
	}
	for _, model := range e.models() {
		slug := model.Model
		if slug == "" {
			slug = model.ID
		}
		id := "codex/" + slug
		if model.Hidden || !validPromptOptions(PromptOptions{Model: id}) {
			continue
		}
		name, _ := clipText(model.DisplayName, 200)
		if name == "" {
			name = slug
		}
		entry := ChatModel{ID: id, Name: name, Provider: chatProviderNames["codex"], DefaultEffort: model.DefaultReasoningEffort}
		for _, effort := range model.SupportedReasoningEfforts {
			if codexEffortPattern.MatchString(effort.ReasoningEffort) {
				entry.Efforts = append(entry.Efforts, effort.ReasoningEffort)
			}
		}
		if !codexEffortPattern.MatchString(entry.DefaultEffort) {
			entry.DefaultEffort = ""
		}
		result.Models = append(result.Models, entry)
	}
	return result
}

// models reads model/list once per app-server process and keeps it for ten
// minutes. Without an app-server only the default model is offered.
func (e *codexEngine) models() []codexModel {
	if e.execTransport() || e.lacks("model/list") {
		return nil
	}
	conn, err := e.connection()
	if err != nil {
		return nil
	}
	conn.mu.Lock()
	if conn.models != nil && time.Since(conn.modelsAt) < 10*time.Minute {
		models := conn.models
		conn.mu.Unlock()
		return models
	}
	conn.mu.Unlock()
	e.hold()
	defer e.release()
	ctx, cancel := context.WithTimeout(context.Background(), e.config.duration(e.config.callTimeout, 20*time.Second))
	defer cancel()
	models := []codexModel{}
	cursor := ""
	for page := 0; page < 5; page++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var result struct {
			Data       []codexModel `json:"data"`
			NextCursor *string      `json:"nextCursor"`
		}
		if err := conn.call(ctx, "model/list", params, &result); err != nil {
			e.noteMissing("model/list", err)
			return models
		}
		models = append(models, result.Data...)
		if result.NextCursor == nil || *result.NextCursor == "" || len(models) >= 200 {
			break
		}
		cursor = *result.NextCursor
	}
	conn.mu.Lock()
	conn.models, conn.modelsAt = models, time.Now()
	conn.mu.Unlock()
	return models
}

// loadedMode reports whether a thread is loaded in this process and the mode
// it was loaded with.
func (c *codexConn) loadedMode(threadID string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry := c.loaded[threadID]
	if entry == nil {
		return "", false
	}
	entry.used = time.Now()
	return entry.mode, true
}

func (c *codexConn) markLoaded(threadID, mode string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.loaded[threadID] = &codexLoaded{used: time.Now(), mode: mode}
}

func (c *codexConn) unmarkLoaded(threadID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.loaded, threadID)
}

// makeRoom keeps at most maxThreads threads loaded: it unsubscribes the
// least recently used thread that has no running turn.
func (e *codexEngine) makeRoom(ctx context.Context, conn *codexConn) {
	e.chats.mu.Lock()
	running := map[string]bool{}
	for _, turn := range e.turns {
		running[turn.threadID] = true
	}
	e.chats.mu.Unlock()
	limit := e.config.maxThreadsOrDefault()
	for {
		conn.mu.Lock()
		if len(conn.loaded) < limit {
			conn.mu.Unlock()
			return
		}
		victim := ""
		var oldest time.Time
		for threadID, entry := range conn.loaded {
			if !running[threadID] && (victim == "" || entry.used.Before(oldest)) {
				victim, oldest = threadID, entry.used
			}
		}
		if victim == "" {
			conn.mu.Unlock()
			return
		}
		delete(conn.loaded, victim)
		conn.mu.Unlock()
		if e.lacks("thread/unsubscribe") {
			continue
		}
		if err := conn.call(ctx, "thread/unsubscribe", map[string]any{"threadId": victim}, nil); err != nil {
			e.noteMissing("thread/unsubscribe", err)
		}
	}
}

// close stops the app-server and every codex exec run for good and waits
// for their turns to end. It runs when the host shuts down
// (CLIChats.stopAgents, from BeginShutdown and again from Close): the
// app-server's group ends within agentShutdownKill, like Claude Code's and
// the ACP agents'. It runs once; another call waits for the first, app-server
// included, as the Claude Code and ACP engines' do.
func (e *codexEngine) close() {
	e.closeOnce.Do(func() {
		e.mu.Lock()
		e.closed = true
		close(e.closing)
		conn := e.conn
		e.conn = nil
		e.mu.Unlock()
		if conn != nil {
			conn.terminate(agentShutdownKill)
		}
		e.chats.mu.Lock()
		for _, turn := range e.turns {
			if turn.cancel != nil {
				turn.cancel()
			}
		}
		e.chats.mu.Unlock()
		e.work.Wait()
	})
}

// codexParams is a JSON-RPC params object built by the engine.
type codexParams = map[string]any

func codexModeParams(params codexParams, mode codexMode) codexParams {
	params["approvalPolicy"] = mode.approval
	params["approvalsReviewer"] = mode.reviewer
	params["sandbox"] = mode.sandbox
	return params
}
