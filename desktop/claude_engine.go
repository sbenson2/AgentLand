package host

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Claude Code chats that stream: one long-lived `claude -p` process per chat
// speaking the Agent SDK stream-json protocol (claude_chat.go), started when
// the chat is used and stopped when it idles.

// claudeConfig tunes the Claude engine. The zero value, which the host's own
// runner supplies, uses the defaults; the fields are for tests.
type claudeConfig struct {
	// executable finds the claude binary; nil uses the host's program search.
	executable func() (string, bool)
	// env is appended to each process's environment (tests and the opt-in
	// contract check point the CLI at a fake model API with it).
	env []string
	// maxLive bounds live processes; idleStop stops an idle process;
	// stopGrace is each wait of the shutdown sequence.
	maxLive   int
	idleStop  time.Duration
	stopGrace time.Duration
	// initWait bounds the initialize request, echoWait the wait for a
	// prompt's replayed echo, controlWait other control requests.
	initWait, echoWait, controlWait time.Duration
	// lineLimit bounds one stdout line, stderrTail the stderr kept.
	lineLimit, stderrTail int
	// modelsFor is how long the models from initialize are reused.
	modelsFor time.Duration
	// baseEnv replaces the host's environment as the base the stream-json
	// settings and env go on (the contract check isolates the CLI with it).
	baseEnv []string
	// onSpawn and trace let tests record each start's arguments and the
	// protocol lines ("in" from the CLI, "out" to it).
	onSpawn func(args []string)
	trace   func(direction string, line []byte)
	// apiKeyAllowed lets chats run on an API key: only the opt-in contract
	// check, which points the CLI at a fake model API with a fake key. Serve
	// never sets it (chat_subscription.go).
	apiKeyAllowed bool
}

// claudeSessionMarkers tie a process to a parent Claude Code session (a host
// started from a Claude Code terminal has them); the chats' own processes
// must not inherit them.
var claudeSessionMarkers = map[string]bool{"CLAUDECODE": true, "CLAUDE_PID": true, "CLAUDE_CODE_SESSION_ID": true, "CLAUDE_CODE_CHILD_SESSION": true, "CLAUDE_CODE_MESSAGING_SOCKET": true, "CLAUDE_CODE_MESSAGING_TOKEN": true, "CLAUDE_CODE_SESSION_ATTENDED": true, "CLAUDE_CODE_ENTRYPOINT": true, "CLAUDE_CODE_EXECPATH": true}

const (
	claudeMaxLive     = 6
	claudeIdleStop    = 10 * time.Minute
	claudeStopGrace   = 5 * time.Second
	claudeInitWait    = 30 * time.Second
	claudeEchoWait    = 30 * time.Second
	claudeControlWait = 30 * time.Second
	claudeLineLimit   = 32 << 20
	claudeStderrTail  = 64 << 10
	claudeModelsFor   = 30 * time.Minute
	// claudeSendWait is the write deadline of a send's response: starting a
	// process, restoring files and waiting for the echo can outlast the
	// listener's write timeout.
	claudeSendWait = 3 * time.Minute
)

var (
	errDeliveryUncertain     = errors.New("the agent may have received the message")
	errClaudeCapacity        = fmt.Errorf("too many Claude Code chats are running: %w", errPromptNotSent)
	errClaudeStart           = fmt.Errorf("Claude Code did not start: %w", errPromptNotSent)
	errClaudeOptions         = fmt.Errorf("%w: %w", ErrCLIChatUnavailable, errPromptNotSent)
	errClaudeRewindRefused   = fmt.Errorf("Claude Code refused to drop the rewound messages: %w", errPromptNotSent)
	errClaudeFilesNotRewound = fmt.Errorf("Claude Code could not restore the files: %w", errPromptNotSent)
	errClaudeNotRewindable   = errors.New("this message cannot be rewound")
)

// claudeModes are the permission modes Chat offers (owner, 2026-10-12): Ask
// (Claude Code's default mode, which asks in the chat), Accept edits, Plan,
// Auto and Bypass permissions. Every process starts able to enter bypass
// (claudeLaunch.probeArgs), so a running chat switches to it.
var claudeModes = []ChatMode{{ID: "default", Name: "Ask"}, {ID: "acceptEdits", Name: "Accept edits"}, {ID: "plan", Name: "Plan"}, {ID: "auto", Name: "Auto"}, {ID: "bypassPermissions", Name: "Bypass permissions"}}

// claudeKeptModes are modes Chat no longer offers but still takes, so a chat
// that has one keeps it: Don't ask (offered until 2026-10-12).
var claudeKeptModes = []ChatMode{{ID: "dontAsk", Name: "Don't ask"}}

// claudeDefaultMode is a new chat's mode: Ask (owner, 2026-10-12).
const claudeDefaultMode = "default"

var claudeEfforts = []string{"low", "medium", "high", "xhigh", "max"}

// claudeModelPattern accepts the CLI's model values and aliases ("default",
// "opus[1m]", "claude-sonnet-5"): no spaces, never an option.
var claudeModelPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@\[\]-]{0,127}$`)

var claudeUUIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func validClaudeMode(mode string) bool {
	_, ok := claudeModeNamed(mode)
	return ok
}

// claudeModeNamed is the mode Chat takes with this id, offered or kept.
func claudeModeNamed(id string) (ChatMode, bool) {
	for _, known := range append(slices.Clone(claudeModes), claudeKeptModes...) {
		if known.ID == id {
			return known, true
		}
	}
	return ChatMode{}, false
}

func validClaudeEffort(effort string) bool {
	for _, known := range claudeEfforts {
		if known == effort {
			return true
		}
	}
	return false
}

// claudeModelInfo is one model from the initialize response.
type claudeModelInfo struct {
	Value                 string   `json:"value"`
	DisplayName           string   `json:"displayName"`
	SupportsEffort        bool     `json:"supportsEffort"`
	SupportedEffortLevels []string `json:"supportedEffortLevels"`
}

// claudeEngineRunner is implemented by CLI chat runners whose Claude Code
// chats stream through the Claude engine instead of one-shot runs.
type claudeEngineRunner interface {
	claudeEngineConfig() claudeConfig
}

// claudeEngineConfig makes the host's own runner stream Claude Code chats.
func (HostCLIChatRunner) claudeEngineConfig() claudeConfig { return claudeConfig{} }

type claudeEngine struct {
	cli *CLIChats
	hub atomic.Pointer[chatHub] // set once the host exists (setClaudeHub)
	// host is the host's own program and state file, which each chat's
	// process names (chatEnvironment); set once the host exists
	// (setClaudeHost).
	host    atomic.Pointer[claudeHostNames]
	options claudeConfig
	slots   chan struct{}

	mu     sync.Mutex
	chats  map[string]*claudeChat
	procs  map[*claudeProcess]bool // every Claude Code process until it is reaped
	closed bool

	cacheMu  sync.Mutex
	models   []claudeModelInfo
	modelKey string
	modelAt  time.Time
	versions map[string]string

	probeMu sync.Mutex
	work    sync.WaitGroup

	closeOnce sync.Once
}

func newClaudeEngine(cli *CLIChats, options claudeConfig) *claudeEngine {
	defaults := claudeConfig{maxLive: claudeMaxLive, idleStop: claudeIdleStop, stopGrace: claudeStopGrace, initWait: claudeInitWait, echoWait: claudeEchoWait, controlWait: claudeControlWait, lineLimit: claudeLineLimit, stderrTail: claudeStderrTail, modelsFor: claudeModelsFor}
	if options.executable == nil {
		options.executable = func() (string, bool) { return executableForProgram("claude") }
	}
	for _, pair := range []struct {
		value    *time.Duration
		fallback time.Duration
	}{{&options.idleStop, defaults.idleStop}, {&options.stopGrace, defaults.stopGrace}, {&options.initWait, defaults.initWait}, {&options.echoWait, defaults.echoWait}, {&options.controlWait, defaults.controlWait}, {&options.modelsFor, defaults.modelsFor}} {
		if *pair.value <= 0 {
			*pair.value = pair.fallback
		}
	}
	if options.maxLive <= 0 {
		options.maxLive = defaults.maxLive
	}
	if options.lineLimit <= 0 {
		options.lineLimit = defaults.lineLimit
	}
	if options.stderrTail <= 0 {
		options.stderrTail = defaults.stderrTail
	}
	return &claudeEngine{cli: cli, options: options, slots: make(chan struct{}, options.maxLive), chats: map[string]*claudeChat{}, procs: map[*claudeProcess]bool{}, versions: map[string]string{}}
}

// track keeps a started process for the shutdown, whichever chat, stop or
// probe holds it then. It is false once the engine is closed: the caller
// ends the process.
func (e *claudeEngine) track(proc *claudeProcess) bool {
	// The record for the next host: the executable exactly as it was run
	// (acp_leftovers.go).
	record := executableRecord(proc.cmd.Process, proc.cmd.Path)
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return false
	}
	// A process that ended before it was tracked is dropped here.
	var ended []*claudeProcess
	for other := range e.procs {
		if !other.alive() {
			delete(e.procs, other)
			ended = append(ended, other)
		}
	}
	e.procs[proc] = true
	e.mu.Unlock()
	for _, other := range ended {
		e.processes().remove(other)
	}
	e.processes().add(proc, record)
	return true
}

func (e *claudeEngine) untrack(proc *claudeProcess) {
	e.mu.Lock()
	delete(e.procs, proc)
	e.mu.Unlock()
	e.processes().remove(proc)
}

// processes are the host's records of the agent processes it runs.
func (e *claudeEngine) processes() *agentProcesses {
	if e.cli == nil {
		return nil
	}
	return e.cli.processes
}

// begin counts one of the engine's goroutines, which close waits for. It is
// false once the engine is closed.
func (e *claudeEngine) begin() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return false
	}
	e.work.Add(1)
	return true
}

// setClaudeHub gives the Claude engine the chat hub it pushes changes to.
func (c *CLIChats) setClaudeHub(hub *chatHub) {
	if c == nil || c.claude == nil {
		return
	}
	c.claude.hub.Store(hub)
}

func (e *claudeEngine) chatHub() *chatHub { return e.hub.Load() }

// claudeHostNames are the host's own program and state file (hostNames).
type claudeHostNames struct{ executable, state string }

// setClaudeHost gives the Claude engine the host's names, which every chat's
// process carries (chatEnvironment).
func (c *CLIChats) setClaudeHost(executable, state string) {
	if c == nil || c.claude == nil {
		return
	}
	c.claude.host.Store(&claudeHostNames{executable: executable, state: state})
}

func (e *claudeEngine) executable() (string, bool) {
	return e.options.executable()
}

func (e *claudeEngine) available() bool {
	_, ok := e.executable()
	return ok
}

// environment is the host's environment without AgentLand's and OpenCode's
// secrets, a parent Claude Code session's markers or an API key
// (chat_subscription.go: chats run on the Claude subscription), plus the
// stream-json settings and any test additions (later entries win).
func (e *claudeEngine) environment() []string {
	base := e.options.baseEnv
	if base == nil {
		base = os.Environ()
	}
	result := []string{}
	for _, item := range withoutChatAPIKeys(base) {
		name, _, _ := strings.Cut(item, "=")
		if strings.HasPrefix(name, "AGENTLAND_") || strings.HasPrefix(name, "OPENCODE_SERVER_") || claudeSessionMarkers[name] {
			continue
		}
		result = append(result, item)
	}
	result = append(result, "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true", "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1", "CLAUDE_CODE_STARTUP_FAILURE_RESULTS=1")
	return append(result, e.options.env...)
}

// chatEnvironment is environment for chat id's process, naming the chat
// (AGENTLAND_CHAT=<id>) and, once known, the host that runs it
// (AGENTLAND_HOST, AGENTLAND_HOST_STATE), in place of any inherited: so
// `agentland-host chats continue`, run by the chat's tools, reaches that host
// and names the chat (chat_continue.go).
func (e *claudeEngine) chatEnvironment(id string) []string {
	var names claudeHostNames
	if known := e.host.Load(); known != nil {
		names = *known
	}
	return environmentNaming(e.environment(), "AGENTLAND_CHAT", id, names.executable, names.state)
}

// chat returns the engine's state for a Claude chat, reading it from the
// registry the first time.
func (e *claudeEngine) chat(project Project, id string) (*claudeChat, error) {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return nil, ErrCLIChatUnavailable
	}
	if existing := e.chats[id]; existing != nil {
		e.mu.Unlock()
		if !sameDirectory(existing.project.Directory, project.Directory) || existing.project.ID != project.ID {
			return nil, ErrNotFound
		}
		return existing, nil
	}
	e.mu.Unlock()
	entry, err := e.cli.claudeEntry(project, id)
	if err != nil {
		return nil, err
	}
	loaded, err := newClaudeChat(e, project, id, entry)
	if err != nil {
		return nil, err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return nil, ErrCLIChatUnavailable
	}
	if existing := e.chats[id]; existing != nil {
		return existing, nil
	}
	e.chats[id] = loaded
	return loaded, nil
}

// acquire takes a live-process slot for c, stopping the idle process used
// least recently when all are taken.
func (e *claudeEngine) acquire(c *claudeChat) error {
	for attempt := 0; ; attempt++ {
		select {
		case e.slots <- struct{}{}:
			return nil
		default:
		}
		if attempt >= 2 || !e.evictIdle(c) {
			return errClaudeCapacity
		}
		// The stopped process gives its slot back as it exits.
		timer := time.NewTimer(e.options.stopGrace*2 + time.Second)
		select {
		case e.slots <- struct{}{}:
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

func (e *claudeEngine) release() { <-e.slots }

// evictIdle stops the least recently used process that is not working and
// has nothing pending.
func (e *claudeEngine) evictIdle(except *claudeChat) bool {
	e.mu.Lock()
	candidates := make([]*claudeChat, 0, len(e.chats))
	for _, chat := range e.chats {
		if chat != except {
			candidates = append(candidates, chat)
		}
	}
	e.mu.Unlock()
	for len(candidates) > 0 {
		oldest := -1
		var oldestUse time.Time
		for index, chat := range candidates {
			used, idle := chat.idleSince()
			if idle && (oldest < 0 || used.Before(oldestUse)) {
				oldest, oldestUse = index, used
			}
		}
		if oldest < 0 {
			return false
		}
		victim := candidates[oldest]
		if victim.stopIfIdle(false) {
			return true
		}
		candidates = append(candidates[:oldest], candidates[oldest+1:]...)
	}
	return false
}

func (e *claudeEngine) stopIdle() {
	e.mu.Lock()
	chats := make([]*claudeChat, 0, len(e.chats))
	for _, chat := range e.chats {
		chats = append(chats, chat)
	}
	e.mu.Unlock()
	for _, chat := range chats {
		chat.stopIfIdle(false)
	}
}

// close ends the chats for good and every Claude Code process at once: stdin
// closes and each process group gets SIGTERM, then SIGKILL after
// agentShutdownKill. It then waits for the chats' operations, which end once
// their processes are gone, and the engine's goroutines. It runs once;
// another call waits for the first.
func (e *claudeEngine) close() {
	e.closeOnce.Do(func() {
		e.mu.Lock()
		e.closed = true
		chats := make([]*claudeChat, 0, len(e.chats))
		for _, chat := range e.chats {
			chats = append(chats, chat)
		}
		e.mu.Unlock()
		// No process starts from a closing chat, and none is tracked after
		// closed is set: its starter ends it.
		for _, chat := range chats {
			chat.closing()
		}
		e.mu.Lock()
		procs := make([]*claudeProcess, 0, len(e.procs))
		for proc := range e.procs {
			procs = append(procs, proc)
		}
		e.mu.Unlock()
		var group sync.WaitGroup
		for _, proc := range procs {
			group.Add(1)
			go func() {
				defer group.Done()
				proc.terminate(agentShutdownKill)
			}()
		}
		group.Wait()
		for _, chat := range chats {
			group.Add(1)
			go func() {
				defer group.Done()
				chat.shutdown()
			}()
		}
		group.Wait()
		e.work.Wait()
	})
}

// binaryKey identifies the installed CLI by path and modification time.
func claudeBinaryKey(path string) string {
	info, err := os.Stat(path)
	if err != nil {
		return path
	}
	return path + "@" + info.ModTime().UTC().Format(time.RFC3339Nano)
}

// rememberModels caches the models an initialize response listed.
func (e *claudeEngine) rememberModels(executable string, response json.RawMessage) {
	var body struct {
		Models []claudeModelInfo `json:"models"`
	}
	if json.Unmarshal(response, &body) != nil || len(body.Models) == 0 {
		return
	}
	models := make([]claudeModelInfo, 0, min(len(body.Models), 64))
	for _, model := range body.Models {
		if len(models) == 64 {
			break
		}
		if !claudeModelPattern.MatchString(model.Value) || len(model.DisplayName) > 200 {
			continue
		}
		levels := []string{}
		for _, level := range model.SupportedEffortLevels {
			if validClaudeEffort(level) {
				levels = append(levels, level)
			}
		}
		model.SupportedEffortLevels = levels
		models = append(models, model)
	}
	e.cacheMu.Lock()
	e.models, e.modelKey, e.modelAt = models, claudeBinaryKey(executable), time.Now()
	e.cacheMu.Unlock()
}

func (e *claudeEngine) cachedModels(executable string) ([]claudeModelInfo, bool) {
	e.cacheMu.Lock()
	defer e.cacheMu.Unlock()
	if e.modelKey != claudeBinaryKey(executable) || time.Since(e.modelAt) > e.options.modelsFor {
		return nil, false
	}
	return append([]claudeModelInfo(nil), e.models...), true
}

// chatOptions lists models (from initialize, probed once when no process has
// run recently), permission modes and efforts.
func (e *claudeEngine) chatOptions(project Project) ChatOptions {
	result := ChatOptions{Models: []ChatModel{}, DefaultModel: "claude/default", Agents: []string{"build"}, Modes: claudeModes, DefaultMode: claudeDefaultMode}
	executable, ok := e.executable()
	var models []claudeModelInfo
	if ok {
		// No process starts in the Chats space's folder (errChatsSpaceRetired).
		if models, ok = e.cachedModels(executable); !ok && project.ID != plainChatsProjectID {
			e.probeModels(project, executable)
			models, _ = e.cachedModels(executable)
		}
	}
	for _, model := range models {
		name := model.DisplayName
		if name == "" {
			name = model.Value
		}
		entry := ChatModel{ID: "claude/" + model.Value, Name: name, Provider: chatProviderNames["claude"]}
		if model.SupportsEffort {
			entry.Efforts = model.SupportedEffortLevels
		}
		result.Models = append(result.Models, entry)
	}
	if len(result.Models) == 0 {
		result.Models = append(result.Models, ChatModel{ID: "claude/default", Name: "Default", Provider: chatProviderNames["claude"], Efforts: claudeEfforts})
	}
	return result
}

// probeModels starts a process in the project only to initialize it: that
// lists the models and makes no model request.
func (e *claudeEngine) probeModels(project Project, executable string) {
	e.probeMu.Lock()
	defer e.probeMu.Unlock()
	if _, ok := e.cachedModels(executable); ok {
		return
	}
	select {
	case e.slots <- struct{}{}:
	default:
		return
	}
	released := false
	release := func() {
		if !released {
			released = true
			e.release()
		}
	}
	defer release()
	launch := claudeLaunch{settings: claudeSettings{mode: "default"}}
	if e.options.onSpawn != nil {
		e.options.onSpawn(launch.probeArgs())
	}
	process, err := startClaudeProcess(claudeSpawn{executable: executable, args: launch.probeArgs(), dir: project.Directory, env: e.environment(), lineLimit: e.options.lineLimit, stderrTail: e.options.stderrTail, writeWait: 10 * time.Second, trace: e.options.trace}, func(*claudeProcess, []byte) {}, e.untrack)
	if err != nil {
		return
	}
	if !e.track(process) {
		process.terminate(agentShutdownKill)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), e.options.initWait)
	response, err := process.request(ctx, map[string]any{"subtype": "initialize", "hooks": nil})
	cancel()
	if err == nil {
		e.rememberModels(executable, response)
	}
	process.stop(false, e.options.stopGrace)
}

var claudeVersionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]{1,24})?$`)

// version reads the CLI's version from its resolved path: a versioned file
// name (~/.local/share/claude/versions/2.1.280) or the npm package beside it.
// The binary is never run for it.
func (e *claudeEngine) version() string {
	executable, ok := e.executable()
	if !ok {
		return ""
	}
	key := claudeBinaryKey(executable)
	e.cacheMu.Lock()
	cached, known := e.versions[key]
	e.cacheMu.Unlock()
	if known {
		return cached
	}
	version := claudeVersionFromPath(executable)
	e.cacheMu.Lock()
	if len(e.versions) > 16 {
		e.versions = map[string]string{}
	}
	e.versions[key] = version
	e.cacheMu.Unlock()
	return version
}

func claudeVersionFromPath(executable string) string {
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return ""
	}
	if base := filepath.Base(resolved); claudeVersionPattern.MatchString(base) {
		return base
	}
	for directory, step := filepath.Dir(resolved), 0; step < 2; directory, step = filepath.Dir(directory), step+1 {
		file, err := os.Open(filepath.Join(directory, "package.json"))
		if err != nil {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(file, 64<<10))
		file.Close()
		if err != nil {
			return ""
		}
		var manifest struct{ Name, Version string }
		if json.Unmarshal(data, &manifest) == nil && manifest.Name == "@anthropic-ai/claude-code" && claudeVersionPattern.MatchString(manifest.Version) {
			return manifest.Version
		}
		return ""
	}
	return ""
}
