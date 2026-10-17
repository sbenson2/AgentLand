package keeper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"sync"
	"time"

	"agentland/host/internal/localsock"
)

// ErrNoCommonProtocol means the keeper refused this build's hello, or chose a
// protocol this build does not speak. Such a keeper is left alone.
var ErrNoCommonProtocol = errors.New("keeper: no protocol version in common")

var errClientClosed = errors.New("keeper: the client was closed")

// RemoteError is a request the keeper refused. Code is one of the Code*
// constants, or a newer one this build does not know.
type RemoteError struct {
	Code    string
	Message string
}

func (e *RemoteError) Error() string { return "keeper: " + e.Code + ": " + e.Message }

// IsNotFound reports whether the keeper said it holds no such terminal.
func IsNotFound(err error) bool { return hasCode(err, CodeNotFound) }

// IsInputStalled reports whether the keeper refused input because the program
// did not take it in time. The terminal still runs.
func IsInputStalled(err error) bool { return hasCode(err, CodeInputStalled) }

func hasCode(err error, code string) bool {
	var remote *RemoteError
	return errors.As(err, &remote) && remote.Code == code
}

func remoteError(e *Error) error {
	if e == nil {
		return nil
	}
	return &RemoteError{Code: e.Code, Message: e.Message}
}

// Client is a control connection to a keeper. Its methods may be called from
// many goroutines at once.
type Client struct {
	conn       net.Conn
	socketPath string
	version    string
	features   []string // from the keeper's hello reply
	writeMu    sync.Mutex

	mu      sync.Mutex
	seq     uint64
	pending map[uint64]chan reply
	err     error // why the connection ended, once it has
	done    chan struct{}
}

// Dial connects to the keeper at socketPath and says hello as version. It
// returns an error wrapping ErrNoCommonProtocol when the keeper refuses that
// hello. A keeper that does not answer within helloWait, or before ctx ends,
// fails the dial without that error.
func Dial(ctx context.Context, socketPath, version string) (*Client, error) {
	conn, answer, err := connect(ctx, socketPath, version, roleControl)
	if err != nil {
		return nil, err
	}
	c := &Client{
		conn:       conn,
		socketPath: socketPath,
		version:    version,
		features:   answer.Features,
		pending:    map[uint64]chan reply{},
		done:       make(chan struct{}),
	}
	go c.readReplies()
	return c, nil
}

// connect dials the socket and exchanges hellos for role. It returns the
// keeper's hello reply.
func connect(ctx context.Context, socketPath, version, role string) (net.Conn, helloReply, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return nil, helloReply{}, err
	}
	var answer helloReply
	err = exchange(ctx, conn, func() error {
		body, err := json.Marshal(hello{Min: ProtocolMin, Max: ProtocolMax, Version: version, Role: role})
		if err != nil {
			return err
		}
		if err := writeFrame(conn, kindHello, body); err != nil {
			return err
		}
		if err := readReplyFrame(conn, &answer); err != nil {
			return fmt.Errorf("keeper hello: %w", err)
		}
		if answer.Error != "" {
			return fmt.Errorf("%w: keeper %s says %s", ErrNoCommonProtocol, answer.Version, answer.Error)
		}
		if answer.Protocol < ProtocolMin || answer.Protocol > ProtocolMax {
			return fmt.Errorf("%w: keeper %s chose protocol %d", ErrNoCommonProtocol, answer.Version, answer.Protocol)
		}
		return nil
	})
	if err != nil {
		conn.Close()
		return nil, helloReply{}, err
	}
	return conn, answer, nil
}

// exchange runs fn, which talks on conn, bounded by helloWait and by ctx.
func exchange(ctx context.Context, conn net.Conn, fn func() error) error {
	deadline := time.Now().Add(helloWait)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	_ = conn.SetDeadline(deadline)
	cut := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		_ = conn.SetDeadline(time.Unix(1, 0)) // unblocks fn at once
		close(cut)
	})
	err := fn()
	if !stop() {
		<-cut
		return ctx.Err()
	}
	if err != nil {
		return err
	}
	return conn.SetDeadline(time.Time{})
}

func readReplyFrame(conn net.Conn, into any) error {
	kind, payload, err := readFrame(conn)
	if err != nil {
		return err
	}
	if kind != kindReply {
		return fmt.Errorf("keeper: a %q frame where a reply belongs", kind)
	}
	return json.Unmarshal(payload, into)
}

func (c *Client) readReplies() {
	for {
		var answer reply
		if err := readReplyFrame(c.conn, &answer); err != nil {
			if errors.Is(err, io.EOF) {
				err = errors.New("the keeper closed the connection")
			}
			c.fail(err)
			return
		}
		c.mu.Lock()
		ch := c.pending[answer.Seq]
		delete(c.pending, answer.Seq)
		c.mu.Unlock()
		if ch != nil {
			ch <- answer // buffered: never blocks
		}
	}
}

// fail ends the connection once, for every caller, with why.
func (c *Client) fail(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return
	}
	if !errors.Is(err, errClientClosed) {
		err = fmt.Errorf("keeper connection: %w", err)
	}
	c.err = err
	close(c.done)
	c.conn.Close()
}

func (c *Client) call(ctx context.Context, req request) (reply, error) {
	answer := make(chan reply, 1)
	c.mu.Lock()
	if c.err != nil {
		err := c.err
		c.mu.Unlock()
		return reply{}, err
	}
	c.seq++
	req.Seq = c.seq
	c.pending[req.Seq] = answer
	c.mu.Unlock()

	if err := c.send(ctx, req); err != nil {
		c.mu.Lock()
		delete(c.pending, req.Seq)
		c.mu.Unlock()
		return reply{}, err
	}
	select {
	case r := <-answer:
		return r, remoteError(r.Error)
	case <-c.done:
		select {
		case r := <-answer:
			return r, remoteError(r.Error)
		default:
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		return reply{}, c.err
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, req.Seq)
		c.mu.Unlock()
		return reply{}, ctx.Err()
	}
}

// send writes one request, giving up when ctx ends. A frame cut short ends
// the connection, since the keeper can no longer read it.
func (c *Client) send(ctx context.Context, req request) error {
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if err := ctx.Err(); err != nil { // nothing written: the connection stays good
		return err
	}
	deadline, _ := ctx.Deadline() // zero means none
	_ = c.conn.SetWriteDeadline(deadline)
	cut := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		_ = c.conn.SetWriteDeadline(time.Unix(1, 0))
		close(cut)
	})
	err = c.writeRequest(body, req.master)
	if !stop() {
		<-cut // the next send sets its own deadline after this one's
	}
	if err != nil && !errors.Is(err, ErrFrameTooLarge) { // too large: nothing was written
		c.fail(err)
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return err
}

// writeRequest writes one request frame, passing master's descriptor with it
// when there is one.
func (c *Client) writeRequest(body []byte, master *os.File) error {
	if master == nil {
		return writeFrame(c.conn, kindRequest, body)
	}
	frame, err := encodeFrame(kindRequest, body)
	if err != nil {
		return err
	}
	unixConn, ok := c.conn.(*net.UnixConn)
	if !ok {
		return errors.New("keeper: passing a descriptor needs a Unix socket")
	}
	return localsock.SendWithFile(unixConn, frame, master)
}

func infoOf(r reply, err error) (Info, error) {
	if err != nil {
		return Info{}, err
	}
	if r.Info == nil {
		return Info{}, errors.New("keeper: a reply without the terminal's info")
	}
	return *r.Info, nil
}

// List returns every terminal the keeper holds, running or finished, in the
// order they were spawned.
func (c *Client) List(ctx context.Context) ([]Info, error) {
	r, err := c.call(ctx, request{Op: opList})
	return r.List, err
}

// Spawn starts a terminal with req's program, size and metadata.
func (c *Client) Spawn(ctx context.Context, req SpawnRequest) (Info, error) {
	return infoOf(c.call(ctx, request{Op: opSpawn, Spawn: &req}))
}

// Input writes data to the terminal's program. On an error, part of it may
// have arrived, so it must not be resent.
func (c *Client) Input(ctx context.Context, id string, data []byte) error {
	_, err := c.call(ctx, request{Op: opInput, ID: id, Data: data})
	return err
}

// Resize sets the terminal's size.
func (c *Client) Resize(ctx context.Context, id string, rows, cols int) error {
	_, err := c.call(ctx, request{Op: opResize, ID: id, Rows: rows, Cols: cols})
	return err
}

// End ends the terminal's program and returns once it has exited.
func (c *Client) End(ctx context.Context, id string) (Info, error) {
	return infoOf(c.call(ctx, request{Op: opEnd, ID: id}))
}

// Forget drops a finished terminal and its output.
func (c *Client) Forget(ctx context.Context, id string) error {
	_, err := c.call(ctx, request{Op: opForget, ID: id})
	return err
}

// SetMeta replaces the terminal's metadata blob.
func (c *Client) SetMeta(ctx context.Context, id string, meta []byte) error {
	_, err := c.call(ctx, request{Op: opSetMeta, ID: id, Meta: meta})
	return err
}

// StopAll ends every terminal; then the keeper exits.
func (c *Client) StopAll(ctx context.Context) error {
	_, err := c.call(ctx, request{Op: opStopAll})
	return err
}

// Features lists what the keeper said it supports in its hello reply, such
// as FeatureAdopt.
func (c *Client) Features() []string { return slices.Clone(c.features) }

// HasFeature reports whether the keeper's hello reply lists name.
func (c *Client) HasFeature(name string) bool { return slices.Contains(c.features, name) }

// Adopt hands the keeper master, the PTY of a program running as req.PID that
// this process started in a session of its own. The descriptor travels with
// the request's frame. From then on the keeper reads the PTY's output and
// writes its input as for a terminal it spawned. The caller keeps its own copy
// of master. Only a keeper with FeatureAdopt knows the request.
//
// master must be OpenPTY's master, or another in non-blocking mode, and must
// stay non-blocking: the mode belongs to the open file the caller's copy and
// the keeper's share. The keeper refuses a master in blocking mode, and one
// switched to it after the adopt would leave the keeper's reads stuck in the
// kernel, so that a release or an end could hang. Never set that mode on the
// caller's copy; reach its descriptor through SyscallConn rather than Fd,
// which switches a file Go made non-blocking back to blocking mode.
func (c *Client) Adopt(ctx context.Context, req AdoptRequest, master *os.File) (Info, error) {
	return infoOf(c.call(ctx, request{Op: opAdopt, Adopt: &req, master: master}))
}

// Release gives an adopted terminal back: the keeper closes its copy of the
// master, stops reading and writing the PTY and forgets the terminal. The
// program keeps running. Its streams end with an exit that says Released.
func (c *Client) Release(ctx context.Context, id string) error {
	_, err := c.call(ctx, request{Op: opRelease, ID: id})
	return err
}

// ReportExit tells the keeper how an adopted terminal's program ended. The
// keeper is not its parent, so it cannot learn that itself.
func (c *Client) ReportExit(ctx context.Context, id string, exit Exit) error {
	_, err := c.call(ctx, request{Op: opReportExit, ID: id, Exit: &exit})
	return err
}

// Done is closed once the connection has ended, by Close or because the
// keeper went away. Calls after that fail.
func (c *Client) Done() <-chan struct{} { return c.done }

// Close ends the connection. Terminals keep running in the keeper.
func (c *Client) Close() error {
	c.fail(errClientClosed)
	return nil
}

// Attach opens a connection that streams the terminal's output from cursor
// from: a reader behind the keeper's ring gets EventSkipped first.
func (c *Client) Attach(ctx context.Context, id string, from uint64) (*Attachment, error) {
	conn, _, err := connect(ctx, c.socketPath, c.version, roleAttach)
	if err != nil {
		return nil, err
	}
	var answer reply
	err = exchange(ctx, conn, func() error {
		body, err := json.Marshal(request{Seq: 1, Op: opAttach, ID: id, Cursor: from})
		if err != nil {
			return err
		}
		if err := writeFrame(conn, kindRequest, body); err != nil {
			return err
		}
		return readReplyFrame(conn, &answer)
	})
	if err == nil {
		err = remoteError(answer.Error)
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return &Attachment{conn: conn}, nil
}

// Attachment is one terminal's output stream. Next is for one goroutine at a
// time; Close may be called from any.
type Attachment struct {
	conn   net.Conn
	exited bool
}

// Next returns the next event, waiting for it. After EventExited it returns
// io.EOF. A stream that ends before then, because the keeper stopped or the
// attachment was closed, returns another error.
func (a *Attachment) Next() (Event, error) {
	if a.exited {
		return Event{}, io.EOF
	}
	kind, payload, err := readFrame(a.conn)
	if err != nil {
		if errors.Is(err, io.EOF) {
			err = fmt.Errorf("keeper: the output stream ended before the program did: %w", io.ErrUnexpectedEOF)
		}
		return Event{}, err
	}
	switch kind {
	case kindData:
		offset, data, err := decodeData(payload)
		if err != nil {
			return Event{}, err
		}
		return Event{Kind: EventData, Offset: offset, Data: data}, nil
	case kindSkipped:
		to, err := decodeSkipped(payload)
		if err != nil {
			return Event{}, err
		}
		return Event{Kind: EventSkipped, SkippedTo: to}, nil
	case kindExited:
		var exit Exit
		if err := json.Unmarshal(payload, &exit); err != nil {
			return Event{}, err
		}
		a.exited = true
		return Event{Kind: EventExited, Exit: &exit}, nil
	}
	return Event{}, fmt.Errorf("keeper: a %q frame in an output stream", kind)
}

// Close ends the stream.
func (a *Attachment) Close() error { return a.conn.Close() }
