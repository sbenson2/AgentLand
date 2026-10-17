package host

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The Codex app-server speaks JSON-RPC over stdio, one message per line.
// Codex 0.156.1 omits the "jsonrpc" member; the host sends messages without
// it and accepts them either way.

var (
	errCodexStopped   = errors.New("codex app-server stopped")
	errCodexHandshake = errors.New("codex app-server did not start")
)

// codexRPCError is a JSON-RPC error answer: Codex received the request and
// refused it.
type codexRPCError struct {
	Code    int64  `json:"code"`
	Message string `json:"message"`
}

func (e *codexRPCError) Error() string {
	return "codex: " + e.Message + " (" + strconv.FormatInt(e.Code, 10) + ")"
}

// methodMissing reports that Codex does not know the method. Codex 0.156.1
// answers an unknown method with -32600 "unknown variant" rather than -32601.
func (e *codexRPCError) methodMissing() bool {
	return e.Code == -32601 || (e.Code == -32600 && strings.Contains(e.Message, "unknown variant"))
}

// codexCallError is a request that got no answer. sent says the request line
// was written, so Codex may have acted on it.
type codexCallError struct {
	method string
	sent   bool
	err    error
}

func (e *codexCallError) Error() string {
	return "codex " + e.method + ": " + e.err.Error()
}

func (e *codexCallError) Unwrap() error { return e.err }

// codexWire is any message on the wire. A request has an id and a method, a
// notification only a method, a response an id with a result or an error.
type codexWire struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *codexRPCError  `json:"error,omitempty"`
}

type codexOutgoing struct {
	ID     *int64 `json:"id,omitempty"`
	Method string `json:"method"`
	Params any    `json:"params,omitempty"`
}

type codexReply struct {
	ID     json.RawMessage `json:"id"`
	Result any             `json:"result,omitempty"`
	Error  *codexRPCError  `json:"error,omitempty"`
}

type codexResponse struct {
	result json.RawMessage
	err    *codexRPCError
}

// codexHandler receives what Codex sends on its own: notifications in order
// on the reading goroutine, requests the host must answer, skipped oversized
// lines and the end of the connection.
type codexHandler interface {
	// codexStarted learns of the process as soon as it started, before the
	// handshake; codexEnded once it was reaped, before anyone waiting for its
	// end hears of it (stop, terminate), whatever the handshake did.
	codexStarted(conn *codexConn)
	codexEnded(conn *codexConn)
	codexNotification(conn *codexConn, method string, params json.RawMessage)
	codexRequest(conn *codexConn, id json.RawMessage, method string, params json.RawMessage)
	codexOversized(conn *codexConn, size int)
	codexClosed(conn *codexConn, crashed bool)
}

// codexConn is one running codex app-server process.
type codexConn struct {
	command *exec.Cmd
	binary  executableIdentity
	stdin   io.WriteCloser
	stderr  *codexRing
	handler codexHandler
	started time.Time

	writeMu sync.Mutex
	mu      sync.Mutex
	nextID  int64
	pending map[int64]chan codexResponse
	closed  bool
	stopped bool // the host stopped it; an exit is not a crash
	done    chan struct{}

	// Set by the handshake; ready once it completed (guarded by mu).
	version   string
	userAgent string
	ready     bool

	// Threads loaded in this process, guarded by mu (codex_engine.go).
	loaded map[string]*codexLoaded
	// Model catalog read from this process, guarded by mu.
	models   []codexModel
	modelsAt time.Time
}

// startCodexConn starts codex app-server and completes the initialize
// handshake. The process runs in its own process group with a filtered
// environment; stdout lines are bounded and stderr keeps its last 64 KiB.
func startCodexConn(config codexEngineConfig, handler codexHandler) (*codexConn, error) {
	executable, ok := config.resolve()
	if !ok {
		return nil, fmt.Errorf("%w: codex is not installed", errCodexHandshake)
	}
	identity, _ := identifyExecutable(executable)
	args := append(append(append(append([]string{}, config.prefixArgs...), "app-server"), codexChatLoginArgs...), config.configArgs...)
	command := exec.Command(executable, args...)
	command.Dir = config.processDir()
	command.Env = codexEnvironment(config.env)
	codexProcessGroup(command)
	conn := &codexConn{command: command, binary: identity, stderr: newCodexRing(codexStderrRing), handler: handler, pending: map[int64]chan codexResponse{}, done: make(chan struct{}), loaded: map[string]*codexLoaded{}}
	command.Stderr = conn.stderr
	command.WaitDelay = 2 * time.Second
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errCodexHandshake, err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errCodexHandshake, err)
	}
	if err := command.Start(); err != nil {
		return nil, fmt.Errorf("%w: %v", errCodexHandshake, err)
	}
	conn.stdin = stdin
	conn.started = time.Now()
	handler.codexStarted(conn)
	go conn.read(stdout, config.lineLimitOrDefault())
	ctx, cancel := context.WithTimeout(context.Background(), config.startTimeoutOrDefault())
	defer cancel()
	var initialized struct {
		UserAgent string `json:"userAgent"`
	}
	params := map[string]any{"clientInfo": map[string]any{"name": "agentland_host", "title": "AgentLand", "version": codexClientVersion}, "capabilities": map[string]any{"experimentalApi": true}}
	if err := conn.call(ctx, "initialize", params, &initialized); err != nil {
		conn.stop(time.Second)
		return nil, fmt.Errorf("%w: %v", errCodexHandshake, err)
	}
	if err := conn.notify("initialized", nil); err != nil {
		conn.stop(time.Second)
		return nil, fmt.Errorf("%w: %v", errCodexHandshake, err)
	}
	conn.mu.Lock()
	conn.userAgent = initialized.UserAgent
	conn.version = codexVersionFromUserAgent(initialized.UserAgent)
	conn.ready = true
	conn.mu.Unlock()
	return conn, nil
}

// wasReady reports whether the handshake completed; an exit before it is a
// failed start, not a crash.
func (c *codexConn) wasReady() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ready
}

// codexClientVersion is sent as clientInfo.version in the handshake.
const codexClientVersion = "0.1.0"

// codexVersionFromUserAgent reads the Codex version from the initialize
// userAgent, "<client name>/<codex version> (<platform>) ...".
func codexVersionFromUserAgent(agent string) string {
	_, rest, ok := strings.Cut(agent, "/")
	if !ok {
		return ""
	}
	end := strings.IndexAny(rest, " ;()")
	if end >= 0 {
		rest = rest[:end]
	}
	if len(rest) > 64 {
		return ""
	}
	return rest
}

// codexEnvironment is the host's environment without AgentLand's own and
// OpenCode's server variables or an API key (chat_subscription.go: chats run
// on the ChatGPT subscription), plus extra entries (later ones win).
func codexEnvironment(extra []string) []string {
	environment := []string{}
	for _, item := range withoutChatAPIKeys(os.Environ()) {
		name, _, _ := strings.Cut(item, "=")
		if strings.HasPrefix(name, "AGENTLAND_") || strings.HasPrefix(name, "OPENCODE_SERVER_") {
			continue
		}
		environment = append(environment, item)
	}
	return append(environment, extra...)
}

func (c *codexConn) read(stdout io.Reader, limit int) {
	reader := newCodexLineReader(stdout, limit)
	for {
		line, oversized, err := reader.next()
		if oversized > 0 {
			c.handler.codexOversized(c, oversized)
			continue
		}
		if err != nil {
			break
		}
		var wire codexWire
		if len(line) == 0 || json.Unmarshal(line, &wire) != nil {
			continue
		}
		hasID := len(wire.ID) > 0 && string(wire.ID) != "null"
		switch {
		case wire.Method != "" && hasID:
			c.handler.codexRequest(c, append(json.RawMessage(nil), wire.ID...), wire.Method, wire.Params)
		case wire.Method != "":
			c.handler.codexNotification(c, wire.Method, wire.Params)
		case hasID:
			id, err := strconv.ParseInt(string(wire.ID), 10, 64)
			if err != nil {
				continue
			}
			c.mu.Lock()
			waiting := c.pending[id]
			delete(c.pending, id)
			c.mu.Unlock()
			if waiting != nil {
				waiting <- codexResponse{result: wire.Result, err: wire.Error}
			}
		}
	}
	// Stdout ended: the process exited or is exiting. Reap it, fail every
	// waiting call and report whether the host asked it to stop.
	_ = c.command.Wait()
	c.mu.Lock()
	c.closed = true
	crashed := !c.stopped
	for id, waiting := range c.pending {
		close(waiting)
		delete(c.pending, id)
	}
	c.mu.Unlock()
	// The commands Codex started may still hold the group.
	codexKillGroup(c.command)
	c.handler.codexEnded(c)
	close(c.done)
	c.handler.codexClosed(c, crashed)
}

func (c *codexConn) write(message any) error {
	line, err := json.Marshal(message)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err = c.stdin.Write(append(line, '\n'))
	return err
}

func (c *codexConn) notify(method string, params any) error {
	return c.write(codexOutgoing{Method: method, Params: params})
}

// respond answers one of Codex's requests.
func (c *codexConn) respond(id json.RawMessage, result any) error {
	if result == nil {
		result = map[string]any{}
	}
	return c.write(codexReply{ID: id, Result: result})
}

func (c *codexConn) respondError(id json.RawMessage, code int64, message string) error {
	return c.write(codexReply{ID: id, Error: &codexRPCError{Code: code, Message: message}})
}

// call sends a request and decodes its result into out. A JSON-RPC error is
// returned as *codexRPCError; no answer as *codexCallError.
func (c *codexConn) call(ctx context.Context, method string, params any, out any) error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return &codexCallError{method: method, err: errCodexStopped}
	}
	c.nextID++
	id := c.nextID
	waiting := make(chan codexResponse, 1)
	c.pending[id] = waiting
	c.mu.Unlock()
	if params == nil {
		params = map[string]any{}
	}
	if err := c.write(codexOutgoing{ID: &id, Method: method, Params: params}); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return &codexCallError{method: method, err: err}
	}
	select {
	case response, open := <-waiting:
		if !open {
			return &codexCallError{method: method, sent: true, err: errCodexStopped}
		}
		if response.err != nil {
			return response.err
		}
		if out != nil && len(response.result) > 0 {
			if err := json.Unmarshal(response.result, out); err != nil {
				return &codexCallError{method: method, sent: true, err: err}
			}
		}
		return nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return &codexCallError{method: method, sent: true, err: ctx.Err()}
	}
}

// stop ends the process: stdin closes first (the app-server exits on end of
// input), then the group is terminated and finally killed.
func (c *codexConn) stop(grace time.Duration) {
	c.mu.Lock()
	c.stopped = true
	c.mu.Unlock()
	_ = c.stdin.Close()
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-c.done:
		return
	case <-timer.C:
	}
	codexTerminateGroup(c.command)
	timer.Reset(grace)
	select {
	case <-c.done:
		return
	case <-timer.C:
	}
	codexKillGroup(c.command)
	<-c.done
}

// terminate ends the app-server when the host shuts down: its input closes
// and its process group gets SIGTERM at once, then SIGKILL after kill. The
// Mac app kills the host 2 s after asking it to stop, and a group still
// running then is left behind.
func (c *codexConn) terminate(kill time.Duration) {
	c.mu.Lock()
	c.stopped = true
	c.mu.Unlock()
	_ = c.stdin.Close()
	codexTerminateGroup(c.command)
	timer := time.NewTimer(kill)
	defer timer.Stop()
	select {
	case <-c.done:
		return
	case <-timer.C:
	}
	codexKillGroup(c.command)
	<-c.done
}

func (c *codexConn) exited() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}
