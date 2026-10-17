package host

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

// One Claude Code process speaking the Agent SDK stream-json protocol: JSON
// frames on stdin, one JSON object per stdout line. The process runs in its
// own process group so its tools die with it; the host signals only that
// group, never processes found by name.

var (
	errClaudeProcessGone = errors.New("the Claude Code process ended")
	errClaudeLineTooLong = errors.New("Claude Code wrote an output line over the host's limit")
	errClaudeControl     = errors.New("Claude Code refused the control request")
)

// claudeTail keeps the last bytes written to it. Claude Code's stderr goes
// here for diagnosis; it is never shown to users.
type claudeTail struct {
	mu    sync.Mutex
	limit int
	data  []byte
	total int64
}

func (t *claudeTail) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.total += int64(len(p))
	if len(p) >= t.limit {
		t.data = append(t.data[:0], p[len(p)-t.limit:]...)
		return len(p), nil
	}
	if drop := len(t.data) + len(p) - t.limit; drop > 0 {
		t.data = append(t.data[:0], t.data[drop:]...)
	}
	t.data = append(t.data, p...)
	return len(p), nil
}

func (t *claudeTail) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.data)
}

func (t *claudeTail) size() (int, int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.data), t.total
}

// claudeControlResult is the answer to a control request the host sent.
type claudeControlResult struct {
	response json.RawMessage
	err      error
}

type claudeSpawn struct {
	executable string
	args       []string
	dir        string
	env        []string
	lineLimit  int
	stderrTail int
	// writeWait bounds one stdin write where the platform supports deadlines.
	writeWait time.Duration
	// trace, when set, sees every line read ("in") and written ("out").
	trace func(direction string, line []byte)
}

type claudeProcess struct {
	cmd    *exec.Cmd
	stdin  *os.File
	stdout *os.File
	errOut *os.File
	stderr *claudeTail
	spec   claudeSpawn

	writeMu sync.Mutex

	mu          sync.Mutex
	pending     map[string]chan claudeControlResult
	counter     uint64
	stdinClosed bool
	reaped      bool
	exitErr     error
	// protocolErr is set when the output broke the protocol (an oversized
	// line); the chat ends its turn with it.
	protocolErr error

	// exited closes once the process has exited and its output is drained.
	exited chan struct{}
}

// startClaudeProcess starts the CLI. handle receives every stdout line that
// is not the answer to one of the host's control requests, in order, from
// one goroutine. done runs once after the process exited and its output was
// drained.
func startClaudeProcess(spec claudeSpawn, handle func(*claudeProcess, []byte), done func(*claudeProcess)) (*claudeProcess, error) {
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
	cmd := exec.Command(spec.executable, spec.args...)
	cmd.Dir = spec.dir
	cmd.Env = spec.env
	cmd.Stdin = stdinR
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	cmd.SysProcAttr = claudeProcessAttributes()
	startErr := cmd.Start()
	// The child holds its own copies of these ends.
	stdinR.Close()
	stdoutW.Close()
	stderrW.Close()
	if startErr != nil {
		stdinW.Close()
		stdoutR.Close()
		stderrR.Close()
		return nil, startErr
	}
	limit := spec.stderrTail
	if limit <= 0 {
		limit = 64 << 10
	}
	p := &claudeProcess{cmd: cmd, stdin: stdinW, stdout: stdoutR, errOut: stderrR, stderr: &claudeTail{limit: limit}, spec: spec, pending: map[string]chan claudeControlResult{}, exited: make(chan struct{})}
	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		_, _ = io.Copy(p.stderr, stderrR)
	}()
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		p.read(handle)
	}()
	go func() {
		waitErr := cmd.Wait()
		p.mu.Lock()
		p.reaped = true
		p.exitErr = waitErr
		p.mu.Unlock()
		// Tools the CLI started die with its group.
		claudeReapGroup(cmd.Process.Pid)
		// A process that left the group can still hold the pipes open; stop
		// reading after a short grace instead of waiting on it forever.
		deadline := time.Now().Add(2 * time.Second)
		claudeDrain(readerDone, stdoutR, deadline)
		claudeDrain(stderrDone, stderrR, deadline)
		stdoutR.Close()
		stderrR.Close()
		p.closeStdin()
		p.failPending(errClaudeProcessGone)
		// done runs first, so whoever waits for the exit sees its effects.
		if done != nil {
			done(p)
		}
		close(p.exited)
	}()
	return p, nil
}

// claudeDrain waits for a pipe reader to finish, closing the pipe at the
// deadline so a reader held by an escaped process ends too.
func claudeDrain(done <-chan struct{}, pipe *os.File, deadline time.Time) {
	timer := time.NewTimer(max(time.Until(deadline), 0))
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
		pipe.Close()
		<-done
	}
}

func (p *claudeProcess) pid() int { return p.cmd.Process.Pid }

// read splits stdout into lines of at most lineLimit bytes. A longer line
// is a protocol error: the rest of it is skipped and the chat is told.
func (p *claudeProcess) read(handle func(*claudeProcess, []byte)) {
	reader := bufio.NewReaderSize(p.stdout, 64<<10)
	limit := p.spec.lineLimit
	if limit <= 0 {
		limit = 32 << 20
	}
	var line []byte
	skipping := false
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(chunk) > 0 {
			switch {
			case skipping:
			case len(line)+len(chunk) > limit+1:
				skipping = true
				line = nil
				p.mu.Lock()
				if p.protocolErr == nil {
					p.protocolErr = errClaudeLineTooLong
				}
				p.mu.Unlock()
				handle(p, nil)
			default:
				line = append(line, chunk...)
			}
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if !skipping && len(line) > 0 {
			trimmed := bytes.TrimRight(line, "\r\n")
			if p.spec.trace != nil && len(trimmed) > 0 {
				p.spec.trace("in", trimmed)
			}
			if len(bytes.TrimSpace(trimmed)) > 0 && !p.route(trimmed) {
				handle(p, trimmed)
			}
		}
		line = line[:0]
		if cap(line) > 1<<20 {
			line = nil
		}
		skipping = false
		if err != nil {
			return
		}
	}
}

// route delivers a control_response to the request that waits for it.
func (p *claudeProcess) route(line []byte) bool {
	if !bytes.Contains(line, []byte(`"control_response"`)) {
		return false
	}
	var frame struct {
		Type     string `json:"type"`
		Response struct {
			Subtype   string          `json:"subtype"`
			RequestID string          `json:"request_id"`
			Response  json.RawMessage `json:"response"`
			Error     string          `json:"error"`
		} `json:"response"`
	}
	if json.Unmarshal(line, &frame) != nil || frame.Type != "control_response" {
		return false
	}
	p.mu.Lock()
	waiter := p.pending[frame.Response.RequestID]
	delete(p.pending, frame.Response.RequestID)
	p.mu.Unlock()
	if waiter == nil {
		return true
	}
	if frame.Response.Subtype == "success" {
		waiter <- claudeControlResult{response: frame.Response.Response}
	} else {
		message, _ := clipText(frame.Response.Error, chatShortLimit)
		waiter <- claudeControlResult{err: fmt.Errorf("%w: %s", errClaudeControl, message)}
	}
	return true
}

func (p *claudeProcess) failPending(err error) {
	p.mu.Lock()
	pending := p.pending
	p.pending = map[string]chan claudeControlResult{}
	p.mu.Unlock()
	for _, waiter := range pending {
		waiter <- claudeControlResult{err: err}
	}
}

// write sends one JSON frame on its own line. written reports whether any of
// it reached the pipe.
func (p *claudeProcess) write(frame any) (written bool, err error) {
	data, err := json.Marshal(frame)
	if err != nil {
		return false, err
	}
	data = append(data, '\n')
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.mu.Lock()
	closed := p.stdinClosed || p.reaped
	p.mu.Unlock()
	if closed {
		return false, errClaudeProcessGone
	}
	if p.spec.writeWait > 0 {
		// Pipes support deadlines on Unix; elsewhere this is best effort.
		_ = p.stdin.SetWriteDeadline(time.Now().Add(p.spec.writeWait))
	}
	n, err := p.stdin.Write(data)
	if err != nil {
		return n > 0, fmt.Errorf("%w: %v", errClaudeProcessGone, err)
	}
	if p.spec.trace != nil {
		p.spec.trace("out", data[:len(data)-1])
	}
	return true, nil
}

// request sends a control request and waits for its answer.
func (p *claudeProcess) request(ctx context.Context, body map[string]any) (json.RawMessage, error) {
	p.mu.Lock()
	if p.reaped {
		p.mu.Unlock()
		return nil, errClaudeProcessGone
	}
	p.counter++
	id := "al-" + strconv.FormatUint(p.counter, 10)
	waiter := make(chan claudeControlResult, 1)
	p.pending[id] = waiter
	p.mu.Unlock()
	if _, err := p.write(map[string]any{"type": "control_request", "request_id": id, "request": body}); err != nil {
		p.mu.Lock()
		delete(p.pending, id)
		p.mu.Unlock()
		return nil, err
	}
	select {
	case result := <-waiter:
		return result.response, result.err
	case <-ctx.Done():
		p.mu.Lock()
		delete(p.pending, id)
		p.mu.Unlock()
		return nil, ctx.Err()
	case <-p.exited:
		select {
		case result := <-waiter:
			return result.response, result.err
		default:
		}
		return nil, errClaudeProcessGone
	}
}

// respond answers a control request the CLI sent.
func (p *claudeProcess) respond(requestID string, response any) error {
	_, err := p.write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": requestID, "response": response}})
	return err
}

func (p *claudeProcess) respondError(requestID, message string) error {
	_, err := p.write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "error", "request_id": requestID, "error": message}})
	return err
}

func (p *claudeProcess) closeStdin() {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.stdinClosed {
		p.stdinClosed = true
		p.stdin.Close()
	}
}

// exitedOnItsOwn reports whether the process exited rather than being killed
// by a signal, so its exit handlers ran (Claude Code saves the session's cost
// then). It is meant for the done callback, after the process was reaped; an
// unknown state counts as exited.
func (p *claudeProcess) exitedOnItsOwn() bool {
	state := p.cmd.ProcessState
	return state == nil || state.Exited()
}

func (p *claudeProcess) alive() bool {
	select {
	case <-p.exited:
		return false
	default:
		return true
	}
}

// signal sends SIGTERM or SIGKILL to the process group while its leader is
// not yet reaped, so the group ID cannot belong to anything else.
func (p *claudeProcess) signal(kill bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.reaped {
		claudeSignalGroup(p.cmd.Process, kill)
	}
}

func (p *claudeProcess) waitExit(limit time.Duration) bool {
	if limit <= 0 {
		<-p.exited
		return true
	}
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case <-p.exited:
		return true
	case <-timer.C:
		return false
	}
}

// stop ends the process: interrupt a running turn, close stdin, then after
// grace SIGTERM the group, and after grace again SIGKILL it.
func (p *claudeProcess) stop(interrupt bool, grace time.Duration) {
	if !p.alive() {
		return
	}
	if interrupt {
		ctx, cancel := context.WithTimeout(context.Background(), min(grace, 2*time.Second))
		_, _ = p.request(ctx, map[string]any{"subtype": "interrupt"})
		cancel()
	}
	p.closeStdin()
	if p.waitExit(grace) {
		return
	}
	p.signal(false)
	if p.waitExit(grace) {
		return
	}
	p.signal(true)
	p.waitExit(0)
}

// kill ends the process group at once, for protocol failures.
func (p *claudeProcess) kill() {
	p.closeStdin()
	p.signal(true)
}

// terminate ends the process at the host's shutdown: stdin closes and the
// group gets SIGTERM at once, SIGKILL after wait. A write in progress fails
// instead of holding either up, and nothing more is written. It returns once
// the process is gone.
func (p *claudeProcess) terminate(wait time.Duration) {
	if !p.alive() {
		return
	}
	kill := time.AfterFunc(wait, func() { p.signal(true) })
	defer kill.Stop()
	p.mu.Lock()
	if !p.stdinClosed {
		p.stdinClosed = true
		p.stdin.Close()
	}
	if !p.reaped {
		claudeSignalGroup(p.cmd.Process, false)
	}
	p.mu.Unlock()
	<-p.exited
}
