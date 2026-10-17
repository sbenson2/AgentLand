package host

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"agentland/host/internal/localsock"
	"agentland/host/keeper"
)

// The production TerminalBackend: it talks to the terminal keeper over its
// socket, and starts one (detached) only for the first terminal.

var (
	// errNoKeeper answers a call that needs a keeper when none runs.
	errNoKeeper = errors.New("terminals: no terminal keeper is running")
	// errKeeperUnusable answers a call when a keeper runs that this build
	// cannot use. It is left alone.
	errKeeperUnusable = errors.New("terminals: the terminal keeper cannot be used")
	errBackendClosed  = errors.New("terminals: the keeper connection was closed")
)

// KeeperBackendOptions configures NewKeeperBackend.
type KeeperBackendOptions struct {
	StatePath  string // the host's state file; the keeper's socket and lock sit beside it
	LogPath    string // the keeper's lifecycle log; empty means keeper.DefaultLogPath()
	Executable string // the agentland-host binary a new keeper runs as
	Version    string
	StartWait  time.Duration // how long a new keeper may take to answer; zero means 3 s
}

// NewKeeperBackend is the TerminalBackend that runs terminals in the keeper
// for options.StatePath.
func NewKeeperBackend(options KeeperBackendOptions) TerminalBackend {
	return &keeperBackend{options: options, gate: make(chan struct{}, 1), closing: make(chan struct{}), attachments: map[*keeperAttachment]struct{}{}}
}

type keeperBackend struct {
	options KeeperBackendOptions
	gate    chan struct{} // one token, held while dialing or starting, so Starts never race
	closing chan struct{} // closed by Close

	mu          sync.Mutex
	closed      bool
	client      *keeper.Client
	attachments map[*keeperAttachment]struct{}
}

func (b *keeperBackend) isClosed() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.closed
}

// bound ends ctx when the backend closes.
func (b *keeperBackend) bound(ctx context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(ctx)
	go func() {
		select {
		case <-b.closing:
			cancel()
		case <-ctx.Done():
		}
	}()
	return ctx, cancel
}

// connect returns a live client: the one it has, or a new one dialled (and,
// with start, launched when no keeper runs). Without start it returns
// errNoKeeper when no keeper runs. A socket path too long for a Unix socket
// means none runs; with start it is an error wrapping localsock.ErrTooLong.
func (b *keeperBackend) connect(ctx context.Context, start bool) (*keeper.Client, error) {
	select {
	case b.gate <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-b.gate }()
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil, errBackendClosed
	}
	client := b.client
	b.mu.Unlock()
	if client != nil {
		select {
		case <-client.Done():
		default:
			return client, nil
		}
	}
	socket := keeper.SocketPath(b.options.StatePath)
	if len(socket) > localsock.MaxPath {
		// No keeper can listen there, so none runs, and none can start.
		if !start {
			return nil, errNoKeeper
		}
		return nil, fmt.Errorf("terminals: the keeper's socket: %w (%d bytes, at most %d)", localsock.ErrTooLong, len(socket), localsock.MaxPath)
	}
	client, err := keeper.Dial(ctx, socket, b.options.Version)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if errors.Is(err, keeper.ErrNoCommonProtocol) {
			return nil, errKeeperUnusable
		}
		if !start {
			release, lockErr := keeper.TryLock(b.options.StatePath)
			if lockErr != nil {
				if errors.Is(lockErr, keeper.ErrKeeperRunning) {
					return nil, errKeeperUnusable // a keeper holds the lock but does not answer
				}
				return nil, fmt.Errorf("terminals: check for a keeper: %w", lockErr)
			}
			release()
			return nil, errNoKeeper
		}
		// keeper.Start probes, launches, and launches again while a stopping
		// keeper still holds the lock.
		if err := keeper.Start(ctx, keeper.StartOptions{Executable: b.options.Executable, StatePath: b.options.StatePath, LogPath: b.options.LogPath,
			Version: b.options.Version, Wait: b.options.StartWait}); err != nil {
			if errors.Is(err, keeper.ErrNoCommonProtocol) {
				return nil, errKeeperUnusable
			}
			return nil, err
		}
		if client, err = keeper.Dial(ctx, socket, b.options.Version); err != nil {
			if errors.Is(err, keeper.ErrNoCommonProtocol) {
				return nil, errKeeperUnusable
			}
			return nil, err
		}
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		client.Close()
		return nil, errBackendClosed
	}
	if b.client != nil {
		b.client.Close()
	}
	b.client = client
	b.mu.Unlock()
	return client, nil
}

func (b *keeperBackend) Status(ctx context.Context) KeeperStatus {
	// A cancelled request or a closing backend learned nothing about the
	// keeper: it must not read as "no keeper", which ends every terminal.
	if ctx.Err() != nil || b.isClosed() {
		return KeeperUnusable
	}
	ctx, cancel := b.bound(ctx)
	defer cancel()
	_, err := b.alive(ctx)
	switch {
	case err == nil:
		return KeeperRunning
	case ctx.Err() != nil || b.isClosed():
		return KeeperUnusable
	case errors.Is(err, errNoKeeper):
		return KeeperNone
	}
	return KeeperUnusable
}

// endLeftovers is for a host whose terminal access is off: a keeper running
// for its state is asked to end every terminal and exit (StopAll). It never
// starts a keeper, and leaves one it cannot use alone (an error). found says
// a keeper answered; running is how many of its terminals still ran.
func (b *keeperBackend) endLeftovers(ctx context.Context) (running int, found bool, err error) {
	ctx, cancel := b.bound(ctx)
	defer cancel()
	client, err := b.alive(ctx)
	if errors.Is(err, errNoKeeper) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	infos, err := client.List(ctx)
	if err != nil {
		return 0, true, err
	}
	for _, info := range infos {
		if info.Running {
			running++
		}
	}
	return running, true, client.StopAll(ctx)
}

// alive is connect plus proof: a stored client whose connection has just
// died may not have said so yet, so a round trip must answer. A client that
// fails it is dropped and the keeper is looked for afresh.
func (b *keeperBackend) alive(ctx context.Context) (*keeper.Client, error) {
	for attempt := 0; ; attempt++ {
		client, err := b.connect(ctx, false)
		if err != nil {
			return nil, err
		}
		if _, err = client.List(ctx); err == nil {
			return client, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		b.drop(client)
		if attempt > 0 {
			return nil, err
		}
	}
}

// drop forgets client, which no longer answers.
func (b *keeperBackend) drop(client *keeper.Client) {
	b.mu.Lock()
	if b.client == client {
		b.client = nil
	}
	b.mu.Unlock()
	client.Close()
}

// do runs call on a live client, without starting a keeper.
func (b *keeperBackend) do(ctx context.Context, call func(context.Context, *keeper.Client) error) error {
	ctx, cancel := b.bound(ctx)
	defer cancel()
	client, err := b.connect(ctx, false)
	if err != nil {
		return err
	}
	return call(ctx, client)
}

func (b *keeperBackend) List(ctx context.Context) (infos []keeper.Info, err error) {
	err = b.do(ctx, func(ctx context.Context, c *keeper.Client) (err error) {
		infos, err = c.List(ctx)
		return err
	})
	return infos, err
}

// Spawn starts a keeper when none runs; so does Features.
func (b *keeperBackend) Spawn(ctx context.Context, request keeper.SpawnRequest) (keeper.Info, error) {
	ctx, cancel := b.bound(ctx)
	defer cancel()
	client, err := b.connect(ctx, true)
	if err != nil {
		return keeper.Info{}, err
	}
	return client.Spawn(ctx, request)
}

func (b *keeperBackend) Attach(ctx context.Context, id string, from uint64) (TerminalAttachment, error) {
	var attachment *keeper.Attachment
	err := b.do(ctx, func(ctx context.Context, c *keeper.Client) (err error) {
		attachment, err = c.Attach(ctx, id, from)
		return err
	})
	if err != nil {
		return nil, err
	}
	wrapped := &keeperAttachment{Attachment: attachment, backend: b}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		attachment.Close()
		return nil, errBackendClosed
	}
	b.attachments[wrapped] = struct{}{}
	b.mu.Unlock()
	return wrapped, nil
}

func (b *keeperBackend) Input(ctx context.Context, id string, data []byte) error {
	return b.do(ctx, func(ctx context.Context, c *keeper.Client) error { return c.Input(ctx, id, data) })
}

func (b *keeperBackend) Resize(ctx context.Context, id string, rows, cols int) error {
	return b.do(ctx, func(ctx context.Context, c *keeper.Client) error { return c.Resize(ctx, id, rows, cols) })
}

func (b *keeperBackend) End(ctx context.Context, id string) (info keeper.Info, err error) {
	err = b.do(ctx, func(ctx context.Context, c *keeper.Client) (err error) {
		info, err = c.End(ctx, id)
		return err
	})
	return info, err
}

func (b *keeperBackend) Forget(ctx context.Context, id string) error {
	return b.do(ctx, func(ctx context.Context, c *keeper.Client) error { return c.Forget(ctx, id) })
}

func (b *keeperBackend) SetMeta(ctx context.Context, id string, meta []byte) error {
	return b.do(ctx, func(ctx context.Context, c *keeper.Client) error { return c.SetMeta(ctx, id, meta) })
}

func (b *keeperBackend) Release(ctx context.Context, id string) error {
	return b.do(ctx, func(ctx context.Context, c *keeper.Client) error { return c.Release(ctx, id) })
}

// runningFeatures is the running keeper's hello features. It never starts a
// keeper: errNoKeeper when none runs.
func (b *keeperBackend) runningFeatures(ctx context.Context) ([]string, error) {
	ctx, cancel := b.bound(ctx)
	defer cancel()
	client, err := b.connect(ctx, false)
	if err != nil {
		return nil, err
	}
	return client.Features(), nil
}

// stopIdleKeeper stops the running keeper when it lists no terminal: StopAll
// then ends nothing, and the keeper exits. It waits for the keeper to close
// the connection, so that the next connect finds it gone and starts this
// build's. stopped says the keeper was stopped.
func (b *keeperBackend) stopIdleKeeper(ctx context.Context) (stopped bool, err error) {
	ctx, cancel := b.bound(ctx)
	defer cancel()
	client, err := b.alive(ctx)
	if errors.Is(err, errNoKeeper) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	infos, err := client.List(ctx)
	if err != nil || len(infos) > 0 {
		return false, err
	}
	if err := client.StopAll(ctx); err != nil {
		return false, err
	}
	select {
	case <-client.Done():
	case <-ctx.Done():
	}
	b.drop(client)
	return true, nil
}

// Features, like Spawn, starts a keeper when none runs.
func (b *keeperBackend) Features(ctx context.Context) ([]string, error) {
	ctx, cancel := b.bound(ctx)
	defer cancel()
	client, err := b.connect(ctx, true)
	if err != nil {
		return nil, err
	}
	return client.Features(), nil
}

// Close detaches: it closes the connection and every open output stream.
// Terminals keep running in the keeper.
func (b *keeperBackend) Close() error {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil
	}
	b.closed = true
	close(b.closing)
	client := b.client
	b.client = nil
	attachments := b.attachments
	b.attachments = map[*keeperAttachment]struct{}{}
	b.mu.Unlock()
	if client != nil {
		client.Close()
	}
	for attachment := range attachments {
		attachment.Attachment.Close()
	}
	return nil
}

// keeperAttachment forgets itself from the backend when closed.
type keeperAttachment struct {
	*keeper.Attachment
	backend *keeperBackend
}

func (a *keeperAttachment) Close() error {
	a.backend.mu.Lock()
	delete(a.backend.attachments, a)
	a.backend.mu.Unlock()
	return a.Attachment.Close()
}
