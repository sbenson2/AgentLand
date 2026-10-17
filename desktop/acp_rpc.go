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

// One ACP agent process speaking JSON-RPC 2.0 over stdio, one message per
// line (docs/HOST-API.md "ACP chats"). The process runs in its own process
// group so the tools it starts end with it; the host signals only that group,
// and only while its leader is not yet reaped. Lines are bounded at 4 MiB and
// only the last 64 KiB of stderr is kept, for diagnosis.

const (
	acpLineLimit  = 4 << 20
	acpStderrTail = 64 << 10
	acpWriteWait  = 10 * time.Second
	// JSON-RPC error codes the host uses or reads.
	acpMethodNotFound = -32601
	acpAuthRequired   = -32000
)

var errACPProcessGone = errors.New("the agent's process ended")

// acpRPCError is a JSON-RPC error answer: the agent received the request and
// refused it.
type acpRPCError struct {
	Code    int64           `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *acpRPCError) Error() string {
	message, _ := clipText(e.Message, chatShortLimit)
	return "agent error " + strconv.FormatInt(e.Code, 10) + ": " + message
}

// authRequired reports ACP's "Authentication required" (-32000), or an error
// that says so in words.
func (e *acpRPCError) authRequired() bool {
	return e.Code == acpAuthRequired || strings.Contains(strings.ToLower(e.Message), "authentication required")
}

// acpCallError is a request without an answer. sent says the request line
// was written, so the agent may have acted on it.
type acpCallError struct {
	method string
	sent   bool
	err    error
}

func (e *acpCallError) Error() string { return "agent " + e.method + ": " + e.err.Error() }
func (e *acpCallError) Unwrap() error { return e.err }

type acpSpawn struct {
	command    string
	args       []string
	dir        string
	env        []string
	lineLimit  int
	stderrTail int
	// trace, when set, sees every line read ("in") and written ("out").
	trace func(direction string, line []byte)
}

// acpHandler receives what the agent sends on its own, in order, on the
// reading goroutine: notifications, requests the host must answer, and a
// line over the limit.
type acpHandler interface {
	acpNotification(conn *acpConn, method string, params json.RawMessage)
	acpRequest(conn *acpConn, id json.RawMessage, method string, params json.RawMessage)
	acpOversized(conn *acpConn)
}

type acpResponse struct {
	result json.RawMessage
	err    *acpRPCError
}

type acpConn struct {
	cmd     *exec.Cmd
	stdin   *os.File
	stderr  *codexRing
	handler acpHandler
	spec    acpSpawn

	writeMu sync.Mutex

	mu          sync.Mutex
	nextID      int64
	pending     map[int64]chan acpResponse
	stdinClosed bool
	reaped      bool
	oversized   bool

	// exited closes once the process has exited, its output is drained and
	// done has run.
	exited chan struct{}
}

type acpOutgoing struct {
	JSONRPC string `json:"jsonrpc"`
	ID      *int64 `json:"id,omitempty"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

type acpReply struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *acpRPCError    `json:"error,omitempty"`
}

// startACPConn starts the agent. done runs once after the process exited and
// its output was drained, before exited closes.
func startACPConn(spec acpSpawn, handler acpHandler, done func(*acpConn)) (*acpConn, error) {
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		return nil, err
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		stdoutR.Close()
		stdoutW.Close()
		return nil, err
	}
	cmd := exec.Command(spec.command, spec.args...)
	cmd.Dir = spec.dir
	cmd.Env = spec.env
	cmd.Stdin = stdinR
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	cmd.SysProcAttr = claudeProcessAttributes()
	startErr := cmd.Start()
	stdinR.Close()
	stdoutW.Close()
	stderrW.Close()
	if startErr != nil {
		stdinW.Close()
		stdoutR.Close()
		stderrR.Close()
		return nil, startErr
	}
	if spec.lineLimit <= 0 {
		spec.lineLimit = acpLineLimit
	}
	if spec.stderrTail <= 0 {
		spec.stderrTail = acpStderrTail
	}
	c := &acpConn{cmd: cmd, stdin: stdinW, stderr: newCodexRing(spec.stderrTail), handler: handler, spec: spec, pending: map[int64]chan acpResponse{}, exited: make(chan struct{})}
	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		_, _ = io.Copy(c.stderr, stderrR)
	}()
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		c.read(stdoutR)
	}()
	go func() {
		_ = cmd.Wait()
		c.mu.Lock()
		c.reaped = true
		c.mu.Unlock()
		// What the agent started dies with its group.
		claudeReapGroup(cmd.Process.Pid)
		deadline := time.Now().Add(2 * time.Second)
		claudeDrain(readerDone, stdoutR, deadline)
		claudeDrain(stderrDone, stderrR, deadline)
		stdoutR.Close()
		stderrR.Close()
		c.closeStdin()
		c.failPending()
		if done != nil {
			done(c)
		}
		close(c.exited)
	}()
	return c, nil
}

func (c *acpConn) read(stdout io.Reader) {
	reader := newCodexLineReader(stdout, c.spec.lineLimit)
	for {
		line, oversized, err := reader.next()
		if oversized > 0 {
			c.mu.Lock()
			c.oversized = true
			c.mu.Unlock()
			c.handler.acpOversized(c)
			continue
		}
		if err != nil {
			return
		}
		if len(line) == 0 {
			continue
		}
		if c.spec.trace != nil {
			c.spec.trace("in", line)
		}
		var wire struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
			Error  *acpRPCError    `json:"error"`
		}
		if json.Unmarshal(line, &wire) != nil {
			continue
		}
		hasID := len(wire.ID) > 0 && string(wire.ID) != "null"
		switch {
		case wire.Method != "" && hasID:
			c.handler.acpRequest(c, append(json.RawMessage(nil), wire.ID...), wire.Method, append(json.RawMessage(nil), wire.Params...))
		case wire.Method != "":
			c.handler.acpNotification(c, wire.Method, append(json.RawMessage(nil), wire.Params...))
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
				waiting <- acpResponse{result: append(json.RawMessage(nil), wire.Result...), err: wire.Error}
			}
		}
	}
}

// wasOversized reports whether the agent wrote a line over the limit.
func (c *acpConn) wasOversized() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.oversized
}

func (c *acpConn) failPending() {
	c.mu.Lock()
	pending := c.pending
	c.pending = map[int64]chan acpResponse{}
	c.mu.Unlock()
	for _, waiting := range pending {
		close(waiting)
	}
}

// write sends one message on its own line. written reports whether any of it
// reached the pipe.
func (c *acpConn) write(message any) (bool, error) {
	data, err := json.Marshal(message)
	if err != nil {
		return false, err
	}
	data = append(data, '\n')
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.mu.Lock()
	closed := c.stdinClosed || c.reaped
	c.mu.Unlock()
	if closed {
		return false, errACPProcessGone
	}
	// Pipes take deadlines on Unix; elsewhere this is best effort.
	_ = c.stdin.SetWriteDeadline(time.Now().Add(acpWriteWait))
	n, err := c.stdin.Write(data)
	if err != nil {
		return n > 0, fmt.Errorf("%w: %v", errACPProcessGone, err)
	}
	if c.spec.trace != nil {
		c.spec.trace("out", data[:len(data)-1])
	}
	return true, nil
}

func (c *acpConn) notify(method string, params any) error {
	_, err := c.write(acpOutgoing{JSONRPC: "2.0", Method: method, Params: params})
	return err
}

// respond answers one of the agent's requests.
func (c *acpConn) respond(id json.RawMessage, result any) error {
	data, err := json.Marshal(result)
	if err != nil {
		return err
	}
	_, err = c.write(acpReply{JSONRPC: "2.0", ID: id, Result: data})
	return err
}

func (c *acpConn) respondError(id json.RawMessage, code int64, message string) error {
	_, err := c.write(acpReply{JSONRPC: "2.0", ID: id, Error: &acpRPCError{Code: code, Message: message}})
	return err
}

// call sends a request and decodes its result into out. A JSON-RPC error is
// returned as *acpRPCError, no answer as *acpCallError.
func (c *acpConn) call(ctx context.Context, method string, params any, out any) error {
	pending, err := c.request(method, params)
	if err != nil {
		return err
	}
	return pending.wait(ctx, out)
}

// acpPending is a request written to the agent, waiting for its answer.
type acpPending struct {
	conn    *acpConn
	method  string
	id      int64
	waiting chan acpResponse
}

// request writes a request; wait reads its answer. A request that was not
// written whole is an *acpCallError.
func (c *acpConn) request(method string, params any) (*acpPending, error) {
	c.mu.Lock()
	if c.reaped || c.stdinClosed {
		c.mu.Unlock()
		return nil, &acpCallError{method: method, err: errACPProcessGone}
	}
	c.nextID++
	id := c.nextID
	waiting := make(chan acpResponse, 1)
	c.pending[id] = waiting
	c.mu.Unlock()
	written, err := c.write(acpOutgoing{JSONRPC: "2.0", ID: &id, Method: method, Params: params})
	if err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, &acpCallError{method: method, sent: written, err: err}
	}
	return &acpPending{conn: c, method: method, id: id, waiting: waiting}, nil
}

// wait decodes the request's result into out, as call does.
func (p *acpPending) wait(ctx context.Context, out any) error {
	method := p.method
	select {
	case response, open := <-p.waiting:
		if !open {
			return &acpCallError{method: method, sent: true, err: errACPProcessGone}
		}
		if response.err != nil {
			return response.err
		}
		if raw, ok := out.(*json.RawMessage); ok {
			// The caller reads the result itself; null is a result too.
			*raw = response.result
			return nil
		}
		if out != nil {
			if len(response.result) == 0 || string(response.result) == "null" {
				return &acpCallError{method: method, sent: true, err: errors.New("the answer has no result")}
			}
			if err := json.Unmarshal(response.result, out); err != nil {
				return &acpCallError{method: method, sent: true, err: err}
			}
		}
		return nil
	case <-ctx.Done():
		p.conn.mu.Lock()
		delete(p.conn.pending, p.id)
		p.conn.mu.Unlock()
		return &acpCallError{method: method, sent: true, err: ctx.Err()}
	}
}

func (c *acpConn) closeStdin() {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.stdinClosed {
		c.stdinClosed = true
		c.stdin.Close()
	}
}

func (c *acpConn) alive() bool {
	select {
	case <-c.exited:
		return false
	default:
		return true
	}
}

// signal sends SIGTERM or SIGKILL to the process group while its leader is
// not yet reaped, so the group ID cannot belong to anything else.
func (c *acpConn) signal(kill bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.reaped {
		claudeSignalGroup(c.cmd.Process, kill)
	}
}

func (c *acpConn) waitExit(limit time.Duration) bool {
	if limit <= 0 {
		<-c.exited
		return true
	}
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case <-c.exited:
		return true
	case <-timer.C:
		return false
	}
}

// stop ends the process: stdin closes, then after grace SIGTERM goes to the
// group, and after grace again SIGKILL. It returns once the process is gone.
func (c *acpConn) stop(grace time.Duration) {
	if !c.alive() {
		return
	}
	c.closeStdin()
	if c.waitExit(grace) {
		return
	}
	c.signal(false)
	if c.waitExit(grace) {
		return
	}
	c.signal(true)
	c.waitExit(0)
}

// kill ends the process group at once.
func (c *acpConn) kill() {
	c.closeStdin()
	c.signal(true)
}

// terminate ends the process at the host's shutdown: stdin closes and the
// group gets SIGTERM at once, SIGKILL after wait. A write in progress fails
// instead of holding either up, and nothing more is written. It returns once
// the process is gone.
func (c *acpConn) terminate(wait time.Duration) {
	if !c.alive() {
		return
	}
	kill := time.AfterFunc(wait, func() { c.signal(true) })
	defer kill.Stop()
	c.mu.Lock()
	if !c.stdinClosed {
		c.stdinClosed = true
		c.stdin.Close()
	}
	if !c.reaped {
		claudeSignalGroup(c.cmd.Process, false)
	}
	c.mu.Unlock()
	<-c.exited
}

// stderrTail is what the agent wrote to stderr last, for diagnosis only.
func (c *acpConn) stderrTail() string { return c.stderr.tail() }

// ACP's initialize, as the host sends it: protocol version 1 and no client
// capabilities.
func acpInitializeParams() map[string]any {
	return map[string]any{"protocolVersion": 1, "clientCapabilities": map[string]any{"fs": map[string]bool{"readTextFile": false, "writeTextFile": false}, "terminal": false}}
}

// acpAgentCaps is what an agent's initialize answer tells the host.
type acpAgentCaps struct {
	loadSession bool
	image       bool
	authMethods []string // names
}

var errACPProtocolVersion = errors.New("the agent does not speak ACP protocol version 1")

// parseACPInitialize reads an initialize answer: protocolVersion must be 1;
// capabilities and sign-in methods are read leniently, as ACP asks.
func parseACPInitialize(raw json.RawMessage) (acpAgentCaps, error) {
	var answer map[string]json.RawMessage
	if json.Unmarshal(raw, &answer) != nil {
		return acpAgentCaps{}, errACPProtocolVersion
	}
	var version float64
	if json.Unmarshal(answer["protocolVersion"], &version) != nil || version != 1 {
		return acpAgentCaps{}, errACPProtocolVersion
	}
	var caps acpAgentCaps
	var capabilities struct {
		LoadSession        json.RawMessage `json:"loadSession"`
		PromptCapabilities json.RawMessage `json:"promptCapabilities"`
	}
	if json.Unmarshal(answer["agentCapabilities"], &capabilities) == nil {
		_ = json.Unmarshal(capabilities.LoadSession, &caps.loadSession)
		var prompt struct {
			Image json.RawMessage `json:"image"`
		}
		if json.Unmarshal(capabilities.PromptCapabilities, &prompt) == nil {
			_ = json.Unmarshal(prompt.Image, &caps.image)
		}
	}
	var methods []json.RawMessage
	if json.Unmarshal(answer["authMethods"], &methods) == nil {
		for _, raw := range methods {
			var method struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			}
			if json.Unmarshal(raw, &method) != nil {
				continue
			}
			name := strings.TrimSpace(method.Name)
			if name == "" {
				name = strings.TrimSpace(method.ID)
			}
			if name != "" && plainAgentText(name, 100) && len(caps.authMethods) < 8 {
				caps.authMethods = append(caps.authMethods, name)
			}
		}
	}
	return caps, nil
}
