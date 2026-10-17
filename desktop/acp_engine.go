package host

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ACP chats (docs/HOST-API.md "ACP chats"): chats of agents that speak the
// Agent Client Protocol, one process per chat (acp_chat.go), kept in the
// chats registry like Claude Code and Codex chats. The engine runs nothing
// until the host gives it the agent catalog, which says how each agent runs.

// acpAgentSource resolves an agent's id to how it runs (agents_catalog.go).
type acpAgentSource interface {
	acpLaunch(id string) (acpLaunchSpec, bool)
	agentName(id string) string
}

// acpLaunchSpec is how one agent's chats start.
type acpLaunchSpec struct {
	name    string
	command string
	args    []string
	env     map[string]string
	// pathPrefix goes first in PATH (node's folder for npm installs).
	pathPrefix string
}

// acpConfig tunes the engine; the zero value uses the defaults. The fields
// are for tests.
type acpConfig struct {
	initWait, sessionWait, controlWait, cancelWait, idleStop, stopGrace time.Duration
	lineLimit, stderrTail                                               int
	// baseEnv replaces the host's environment as the base the owner's PATH,
	// HOME and the like are taken from.
	baseEnv []string
	trace   func(direction string, line []byte)
}

const (
	acpInitWait    = 30 * time.Second
	acpSessionWait = 60 * time.Second
	acpControlWait = 30 * time.Second
	acpCancelWait  = 10 * time.Second
	acpIdleStop    = 10 * time.Minute
	acpStopGrace   = 5 * time.Second
)

var errACPUnavailable = errors.New("this agent is not installed or cannot run now")

type acpEngine struct {
	cli     *CLIChats
	hub     atomic.Pointer[chatHub]
	source  atomic.Pointer[acpSourceBox]
	options acpConfig

	mu    sync.Mutex
	chats map[string]*acpChat
	modes map[string][]ChatMode // the modes each agent listed last
	// conns holds every agent process until it is reaped; the host's
	// records of them are cli.processes (acp_leftovers.go).
	conns  map[*acpConn]bool
	closed bool
	work   sync.WaitGroup

	closeOnce sync.Once
}

type acpSourceBox struct{ source acpAgentSource }

func newACPEngine(cli *CLIChats, options acpConfig) *acpEngine {
	for _, pair := range []struct {
		value    *time.Duration
		fallback time.Duration
	}{{&options.initWait, acpInitWait}, {&options.sessionWait, acpSessionWait}, {&options.controlWait, acpControlWait}, {&options.cancelWait, acpCancelWait}, {&options.idleStop, acpIdleStop}, {&options.stopGrace, acpStopGrace}} {
		if *pair.value <= 0 {
			*pair.value = pair.fallback
		}
	}
	if options.lineLimit <= 0 {
		options.lineLimit = acpLineLimit
	}
	if options.stderrTail <= 0 {
		options.stderrTail = acpStderrTail
	}
	return &acpEngine{cli: cli, options: options, chats: map[string]*acpChat{}, modes: map[string][]ChatMode{}, conns: map[*acpConn]bool{}}
}

// processes are the host's records of the agent processes it runs, for the
// next host (acp_leftovers.go).
func (e *acpEngine) processes() *agentProcesses {
	if e.cli == nil {
		return nil
	}
	return e.cli.processes
}

// track keeps a started process for the shutdown, whichever chat or stop
// holds it then, and records it for the next host with its command. It is
// false once the engine is closed: the caller ends the process.
func (e *acpEngine) track(conn *acpConn) bool {
	record := processRecord(conn.cmd.Process)
	record.Command = conn.cmd.Path
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return false
	}
	// A process that ended before it was tracked is dropped here.
	var ended []*acpConn
	for other := range e.conns {
		if !other.alive() {
			delete(e.conns, other)
			ended = append(ended, other)
		}
	}
	e.conns[conn] = true
	e.mu.Unlock()
	for _, other := range ended {
		e.processes().remove(other)
	}
	e.processes().add(conn, record)
	return true
}

func (e *acpEngine) untrack(conn *acpConn) {
	e.mu.Lock()
	delete(e.conns, conn)
	e.mu.Unlock()
	e.processes().remove(conn)
}

// setACPAgents gives the ACP engine the catalog and the hub it pushes to.
func (c *CLIChats) setACPAgents(source acpAgentSource, hub *chatHub) {
	if c == nil || c.acp == nil {
		return
	}
	if source != nil {
		c.acp.source.Store(&acpSourceBox{source: source})
	}
	c.acp.hub.Store(hub)
}

func (e *acpEngine) chatHub() *chatHub { return e.hub.Load() }

// launch says how agent's chats start now, when it is usable.
func (e *acpEngine) launch(agent string) (acpLaunchSpec, bool) {
	box := e.source.Load()
	if box == nil || box.source == nil {
		return acpLaunchSpec{}, false
	}
	return box.source.acpLaunch(agent)
}

// offers reports whether agent can run ACP chats now.
func (e *acpEngine) offers(agent string) bool {
	_, ok := e.launch(agent)
	return ok
}

func (e *acpEngine) agentName(agent string) string {
	if box := e.source.Load(); box != nil && box.source != nil {
		if name := box.source.agentName(agent); name != "" {
			return name
		}
	}
	return agent
}

// acpEnvironmentNames are the owner's variables an agent keeps: nothing of
// AgentLand's, no OpenCode password, no provider key.
func acpKeepsVariable(name string) bool {
	switch name {
	case "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG":
		return true
	}
	return strings.HasPrefix(name, "LC_")
}

// agentEnvironment is a clean environment: the variables keep allows from
// base (nil: the host's), PATH with prefix first, then extra (later entries
// win).
func agentEnvironment(base []string, keep func(string) bool, prefix string, extra map[string]string) []string {
	if base == nil {
		base = os.Environ()
	}
	result := []string{}
	path := ""
	for _, item := range base {
		name, value, _ := strings.Cut(item, "=")
		if !keep(name) {
			continue
		}
		if name == "PATH" {
			path = value
			continue
		}
		result = append(result, item)
	}
	if prefix != "" {
		if path == "" {
			path = prefix
		} else {
			path = prefix + string(os.PathListSeparator) + path
		}
	}
	if path == "" {
		path = "/usr/bin:/bin:/usr/sbin:/sbin"
	}
	result = append(result, "PATH="+path)
	names := make([]string, 0, len(extra))
	for name := range extra {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		result = append(result, name+"="+extra[name])
	}
	return result
}

// environment is an agent process's environment.
func (e *acpEngine) environment(launch acpLaunchSpec) []string {
	return agentEnvironment(e.options.baseEnv, acpKeepsVariable, launch.pathPrefix, launch.env)
}

// chat returns the engine's state for an ACP chat, reading it from the
// registry the first time.
func (e *acpEngine) chat(project Project, id string) (*acpChat, error) {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return nil, ErrCLIChatUnavailable
	}
	if existing := e.chats[id]; existing != nil {
		e.mu.Unlock()
		if existing.project.ID != project.ID || !sameDirectory(existing.project.Directory, project.Directory) {
			return nil, ErrNotFound
		}
		return existing, nil
	}
	e.mu.Unlock()
	entry, err := e.cli.acpEntry(project, id)
	if err != nil {
		return nil, err
	}
	loaded := newACPChat(e, project, id, entry)
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

// loaded lists the chats the engine holds.
func (e *acpEngine) loaded() []*acpChat {
	e.mu.Lock()
	defer e.mu.Unlock()
	chats := make([]*acpChat, 0, len(e.chats))
	for _, chat := range e.chats {
		chats = append(chats, chat)
	}
	return chats
}

// create adds a chat of agent in project (POST /v1/sessions).
func (e *acpEngine) create(project Project, title, agent string) (Session, error) {
	if !e.offers(agent) {
		return Session{}, errACPUnavailable
	}
	return e.cli.CreateACPSession(project, title, agent, e.agentName(agent))
}

// agentBusy reports whether one of agent's chats runs a turn or waits for an
// approval.
func (e *acpEngine) agentBusy(agent string) bool {
	for _, chat := range e.loaded() {
		if chat.agent == agent && chat.working() {
			return true
		}
	}
	return false
}

// busyIn counts a project's ACP chats with a turn running.
func (e *acpEngine) busyIn(project Project) int {
	count := 0
	for _, chat := range e.loaded() {
		if chat.project.ID == project.ID && chat.working() {
			count++
		}
	}
	return count
}

// anyBusy reports whether any ACP chat runs a turn or waits for an approval.
func (e *acpEngine) anyBusy() bool {
	for _, chat := range e.loaded() {
		if chat.working() {
			return true
		}
	}
	return false
}

// stopAgent stops the idle processes of agent's chats (before an uninstall
// removes its files).
func (e *acpEngine) stopAgent(agent string) {
	for _, chat := range e.loaded() {
		if chat.agent == agent {
			chat.stopIfIdle(false)
		}
	}
}

func (e *acpEngine) rememberModes(agent string, modes []ChatMode) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(modes) > 0 {
		e.modes[agent] = append([]ChatMode(nil), modes...)
	}
}

// newChatOptions lists what a new chat of agent takes
// (GET /v1/chat/options?provider=).
func (e *acpEngine) newChatOptions(agent string) ChatOptions {
	e.mu.Lock()
	modes := append([]ChatMode(nil), e.modes[agent]...)
	e.mu.Unlock()
	return acpChatOptions(agent, e.agentName(agent), modes, "")
}

func acpChatOptions(agent, name string, modes []ChatMode, current string) ChatOptions {
	model := agent + "/default"
	options := ChatOptions{Models: []ChatModel{{ID: model, Name: "Default", Provider: name}}, DefaultModel: model, Agents: []string{"build"}, Modes: modes, DefaultMode: current}
	if len(modes) == 0 {
		options.Modes, options.DefaultMode = nil, ""
	}
	return options
}

func (e *acpEngine) chatOptions(project Project, id string) (ChatOptions, error) {
	chat, err := e.chat(project, id)
	if err != nil {
		return ChatOptions{}, err
	}
	chat.mu.Lock()
	defer chat.mu.Unlock()
	return acpChatOptions(chat.agent, e.agentName(chat.agent), append([]ChatMode(nil), chat.rec.Modes...), chat.rec.Mode), nil
}

func (e *acpEngine) status(project Project, id string) (ChatStatus, error) {
	chat, err := e.chat(project, id)
	if err != nil {
		return ChatStatus{}, err
	}
	if chat.working() {
		return ChatStatus{State: "busy"}, nil
	}
	return ChatStatus{State: "idle"}, nil
}

// legacyTranscript is an ACP chat in the legacy GET /v1/messages shape.
func (e *acpEngine) legacyTranscript(project Project, id string) ([]Message, error) {
	chat, err := e.chat(project, id)
	if err != nil {
		return nil, err
	}
	chat.mu.Lock()
	messages := cloneMessages(chat.rec.Messages)
	chat.mu.Unlock()
	result := make([]Message, 0, len(messages))
	for _, message := range messages {
		result = append(result, claudeLegacyMessage(message))
	}
	return result, nil
}

// close ends the chats for good and every agent process at once: stdin
// closes and each process group gets SIGTERM, then SIGKILL after
// agentShutdownKill. It waits for the processes and the turns to end. It
// runs once; another call waits for the first.
func (e *acpEngine) close() {
	if e == nil {
		return
	}
	e.closeOnce.Do(func() {
		e.mu.Lock()
		e.closed = true
		chats := make([]*acpChat, 0, len(e.chats))
		for _, chat := range e.chats {
			chats = append(chats, chat)
		}
		e.mu.Unlock()
		for _, chat := range chats {
			chat.shutdown()
		}
		// No process is tracked after closed is set: its starter ends it.
		e.mu.Lock()
		conns := make([]*acpConn, 0, len(e.conns))
		for conn := range e.conns {
			conns = append(conns, conn)
		}
		e.mu.Unlock()
		var group sync.WaitGroup
		for _, conn := range conns {
			group.Add(1)
			go func() {
				defer group.Done()
				conn.terminate(agentShutdownKill)
			}()
		}
		group.Wait()
		e.work.Wait()
	})
}

// acpNodeFolder is the folder of the node an npm-installed agent runs with,
// found like the terminal's programs; "" when none is found.
func acpNodeFolder(lookup func(string) (string, bool)) string {
	if lookup == nil {
		lookup = findCommand
	}
	if node, ok := lookup("node"); ok {
		return filepath.Dir(node)
	}
	return ""
}

// acpAgentError is a failure that ends a turn with an error reply.
type acpAgentError struct {
	code        string
	message     string
	authMethods []string
}

func (e *acpAgentError) Error() string { return e.code + ": " + e.message }

func acpFailure(code, format string, args ...any) *acpAgentError {
	message, _ := clipText(fmt.Sprintf(format, args...), chatErrorLimit)
	return &acpAgentError{code: code, message: message}
}
