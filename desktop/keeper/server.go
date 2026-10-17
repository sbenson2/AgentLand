//go:build darwin

package keeper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"agentland/host/internal/localsock"
)

const (
	// endAllWait bounds how long shutting down waits for terminals to end.
	endAllWait = 10 * time.Second
	// maxIDLength is the longest terminal ID a spawn may use.
	maxIDLength = 128
)

// Serve runs the terminal keeper for the host state at options.StatePath. It
// returns ErrKeeperRunning when another keeper serves that state. Otherwise it
// serves until it has been idle for options.IdleAfter, a client asks it to
// stop all, or ctx ends. It ends any terminals still running and returns nil.
func Serve(ctx context.Context, options ServeOptions) error {
	options = options.withDefaults()
	// The keeper outlives the session that started it and writes to peers
	// that may leave. It catches SIGHUP and SIGPIPE rather than ignoring
	// them: an ignored signal stays ignored in every program it starts, and
	// those would then survive the hang-up that ends a terminal.
	caught := make(chan os.Signal, 1)
	signal.Notify(caught, syscall.SIGHUP, syscall.SIGPIPE)
	defer signal.Stop(caught)

	release, err := TryLock(options.StatePath)
	if err != nil {
		return err
	}
	defer release() // last: the socket is gone before another keeper may start
	logFile, err := openLog(options.LogPath)
	if err != nil {
		return err
	}
	defer logFile.Close()
	socket, err := localsock.Listen(SocketPath(options.StatePath))
	if err != nil {
		return fmt.Errorf("terminal keeper socket: %w", err)
	}
	defer socket.Close()
	return newServer(options, logFile).run(ctx, socket)
}

type server struct {
	options   ServeOptions
	helloWait time.Duration
	log       io.Writer

	ctx    context.Context // ends when the keeper shuts down
	cancel context.CancelFunc
	wg     sync.WaitGroup

	changed  chan struct{} // a terminal or connection came or went
	stopped  chan struct{} // closed once a stopAll has been answered
	stopOnce sync.Once
	done     chan struct{} // closed when shutdown stops waiting for exits

	spawnMu sync.Mutex // one spawn at a time, so its checks still hold when it adds

	mu        sync.Mutex
	terminals map[string]*entry
	added     uint64
	conns     map[net.Conn]struct{}
	stopping  bool // no new terminals
	closing   bool // no new connections
}

type entry struct {
	t     *terminal
	order uint64 // spawn order, for List
}

func newServer(options ServeOptions, log io.Writer) *server {
	ctx, cancel := context.WithCancel(context.Background())
	return &server{
		options:   options,
		helloWait: helloWait,
		log:       log,
		ctx:       ctx,
		cancel:    cancel,
		changed:   make(chan struct{}, 1),
		stopped:   make(chan struct{}),
		done:      make(chan struct{}),
		terminals: map[string]*entry{},
		conns:     map[net.Conn]struct{}{},
	}
}

func (s *server) run(ctx context.Context, socket *localsock.Socket) error {
	s.logKeeper("keeper-start")
	s.wg.Add(1)
	go s.accept(socket.Listener)
	reason := s.waitForExit(ctx)

	s.mu.Lock()
	s.stopping, s.closing = true, true
	s.mu.Unlock()
	socket.Close()
	s.endAll() // nothing is left to end after a stopAll or when idle
	s.cancel()
	s.mu.Lock()
	for conn := range s.conns {
		conn.Close()
	}
	s.mu.Unlock()
	close(s.done)
	s.wg.Wait()
	s.logKeeper(reason)
	return nil
}

// waitForExit returns why the keeper should stop: ctx ended, a stopAll was
// answered, or it held no terminals and no connections for IdleAfter.
func (s *server) waitForExit(ctx context.Context) string {
	idle := time.NewTimer(s.options.IdleAfter)
	defer idle.Stop()
	for {
		idle.Reset(s.options.IdleAfter)
		var idleFor <-chan time.Time
		s.mu.Lock()
		if s.idleLocked() {
			idleFor = idle.C
		}
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return "keeper-stop"
		case <-s.stopped:
			return "keeper-stop-all"
		case <-s.changed:
		case <-idleFor:
			s.mu.Lock()
			if s.idleLocked() {
				s.stopping, s.closing = true, true
				s.mu.Unlock()
				return "keeper-idle"
			}
			s.mu.Unlock()
		}
	}
}

// idleLocked reports whether the keeper holds no terminals, running or
// finished, and no connections. s.mu must be held.
func (s *server) idleLocked() bool {
	return len(s.terminals) == 0 && len(s.conns) == 0
}

// poke tells waitForExit that what idleness depends on changed.
func (s *server) poke() {
	select {
	case s.changed <- struct{}{}:
	default:
	}
}

func (s *server) accept(listener net.Listener) {
	defer s.wg.Done()
	for {
		conn, err := listener.Accept()
		if errors.Is(err, net.ErrClosed) {
			return
		}
		if err != nil { // out of file descriptors, say: let some close
			time.Sleep(50 * time.Millisecond)
			continue
		}
		s.mu.Lock()
		closing := s.closing
		if !closing {
			s.conns[conn] = struct{}{}
		}
		s.mu.Unlock()
		if closing {
			conn.Close()
			continue
		}
		s.poke()
		s.wg.Add(1)
		go s.serveConn(conn)
	}
}

func (s *server) serveConn(conn net.Conn) {
	defer s.wg.Done()
	defer func() {
		conn.Close()
		s.mu.Lock()
		delete(s.conns, conn)
		s.mu.Unlock()
		s.poke()
	}()
	if localsock.SameUserPeer(conn) != nil {
		return
	}
	switch s.greet(conn) {
	case roleControl:
		s.serveControl(conn)
	case roleAttach:
		s.serveAttach(conn)
	}
}

// greet reads the client's hello within helloWait and answers it. It returns
// the client's role, or "" when the connection is to be dropped. A client
// with no protocol in common gets an error and touches nothing.
func (s *server) greet(conn net.Conn) string {
	_ = conn.SetDeadline(time.Now().Add(s.helloWait))
	kind, payload, err := readFrame(conn)
	if err != nil || kind != kindHello {
		return ""
	}
	var theirs hello
	answer := helloReply{Version: s.options.Version, Features: []string{FeatureAdopt}}
	if err := json.Unmarshal(payload, &theirs); err != nil {
		answer.Error = "bad hello: " + err.Error()
	} else if v, ok := chooseProtocol(theirs, ProtocolMin, ProtocolMax); !ok {
		answer.Error = fmt.Sprintf("no common protocol: this keeper speaks %d to %d, the client %d to %d",
			ProtocolMin, ProtocolMax, theirs.Min, theirs.Max)
	} else if theirs.Role != roleControl && theirs.Role != roleAttach {
		answer.Error = fmt.Sprintf("unknown role %q", theirs.Role)
	} else {
		answer.Protocol = v
	}
	body, err := json.Marshal(answer)
	if err != nil || writeFrame(conn, kindReply, body) != nil || answer.Error != "" {
		return ""
	}
	_ = conn.SetDeadline(time.Time{})
	return theirs.Role
}

// serveControl answers requests until the client leaves. Each request runs on
// its own, so a stalled input or a slow end holds up nothing else. An adopt
// takes the descriptor that came with its frame; any other is closed.
func (s *server) serveControl(conn net.Conn) {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return // SameUserPeer admits Unix connections only
	}
	frames := localsock.NewRightsReader(unixConn)
	defer frames.Discard()
	var writeMu sync.Mutex
	send := func(answer reply) {
		writeMu.Lock()
		defer writeMu.Unlock()
		if err := writeReply(conn, answer); errors.Is(err, ErrFrameTooLarge) {
			_ = writeReply(conn, reply{Seq: answer.Seq, Error: &Error{Code: CodeBadRequest, Message: "the reply is too large for a frame"}})
		}
	}
	for {
		kind, payload, err := readFrame(frames)
		if err != nil || kind != kindRequest {
			return
		}
		req, err := decodeRequest(payload)
		if err == nil && req.Op == opAdopt {
			req.master = frames.TakeFile("pty")
		}
		frames.Discard()
		if err != nil {
			send(reply{Seq: seqOf(payload), Error: &Error{Code: CodeBadRequest, Message: err.Error()}})
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			send(s.handle(req))
			if req.Op == opStopAll {
				s.stopOnce.Do(func() { close(s.stopped) })
			}
		}()
	}
}

func writeReply(conn net.Conn, answer reply) error {
	body, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	return writeFrame(conn, kindReply, body)
}

// seqOf finds the seq of a request that failed to decode, so its refusal
// reaches the caller.
func seqOf(payload []byte) uint64 {
	var probe struct {
		Seq uint64 `json:"seq"`
	}
	_ = json.Unmarshal(payload, &probe)
	return probe.Seq
}

func (s *server) handle(req request) reply {
	answer := reply{Seq: req.Seq}
	switch req.Op {
	case opList:
		answer.List = s.list()
	case opSpawn:
		answer.Info, answer.Error = s.spawn(req.Spawn)
	case opInput:
		answer.Error = s.input(req.ID, req.Data)
	case opResize:
		answer.Error = s.resize(req.ID, req.Rows, req.Cols)
	case opEnd:
		answer.Info, answer.Error = s.end(req.ID)
	case opForget:
		answer.Error = s.forget(req.ID)
	case opSetMeta:
		answer.Error = s.setMeta(req.ID, req.Meta)
	case opStopAll:
		s.endAll()
	case opAdopt:
		answer.Info, answer.Error = s.adopt(req.Adopt, req.master)
	case opRelease:
		answer.Error = s.release(req.ID)
	case opReportExit:
		answer.Error = s.reportExit(req.ID, req.Exit)
	default:
		answer.Error = badRequest(req.Op + " is not a control request")
	}
	return answer
}

func badRequest(message string) *Error {
	return &Error{Code: CodeBadRequest, Message: message}
}

func (s *server) find(id string) (*terminal, *Error) {
	s.mu.Lock()
	e := s.terminals[id]
	s.mu.Unlock()
	if e == nil {
		return nil, &Error{Code: CodeNotFound, Message: fmt.Sprintf("no terminal %q", id)}
	}
	return e.t, nil
}

func (s *server) list() []Info {
	s.mu.Lock()
	entries := make([]*entry, 0, len(s.terminals))
	for _, e := range s.terminals {
		entries = append(entries, e)
	}
	s.mu.Unlock()
	sort.Slice(entries, func(i, j int) bool { return entries[i].order < entries[j].order })
	infos := make([]Info, len(entries))
	for i, e := range entries {
		infos[i] = e.t.info()
	}
	return infos
}

func (s *server) spawn(req *SpawnRequest) (*Info, *Error) {
	if req == nil {
		return nil, badRequest("spawn needs its request")
	}
	if !validID(req.ID) {
		return nil, badID()
	}
	s.spawnMu.Lock()
	defer s.spawnMu.Unlock()
	if refusal := s.refuseNew(req.ID); refusal != nil {
		return nil, refusal
	}
	t, err := startTerminal(*req, s.options.Now)
	if err != nil {
		return nil, &Error{Code: CodeStartFailed, Message: err.Error()}
	}
	if !s.add(t, "spawn") {
		t.end()
		return nil, &Error{Code: CodeStopping, Message: "the keeper is stopping"}
	}
	info := t.info()
	return &info, nil
}

func badID() *Error {
	return badRequest(fmt.Sprintf("a terminal ID is 1 to %d letters, digits, '.', '_', ':' or '-'", maxIDLength))
}

// refuseNew says why no terminal may be added as id now, or returns nil.
// s.spawnMu must be held, so the answer still holds when the terminal is added.
func (s *server) refuseNew(id string) *Error {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.stopping:
		return &Error{Code: CodeStopping, Message: "the keeper is stopping"}
	case s.terminals[id] != nil:
		return &Error{Code: CodeExists, Message: fmt.Sprintf("terminal %q exists", id)}
	case len(s.terminals) >= s.options.MaxTerminals:
		return &Error{Code: CodeLimit, Message: fmt.Sprintf("the keeper holds its most terminals, %d", s.options.MaxTerminals)}
	}
	return nil
}

// add lists a new terminal, logs event and watches for its exit. It refuses
// once shutdown has begun, since shutdown has already listed what to end; the
// caller then ends or releases the terminal.
func (s *server) add(t *terminal, event string) bool {
	s.mu.Lock()
	if s.stopping {
		s.mu.Unlock()
		return false
	}
	s.added++
	s.terminals[t.id] = &entry{t: t, order: s.added}
	s.mu.Unlock()
	s.poke()
	s.logTerminal(event, t, nil)
	s.wg.Add(1)
	go s.watchExit(t)
	return true
}

func validID(id string) bool {
	if id == "" || len(id) > maxIDLength {
		return false
	}
	for i := 0; i < len(id); i++ {
		switch c := id[i]; {
		case 'a' <= c && c <= 'z', 'A' <= c && c <= 'Z', '0' <= c && c <= '9', c == '.', c == '_', c == ':', c == '-':
		default:
			return false
		}
	}
	return true
}

// watchExit logs the terminal's exit; a release logs itself. Shutdown stops it
// waiting for one that never comes.
func (s *server) watchExit(t *terminal) {
	defer s.wg.Done()
	select {
	case <-t.exited:
	case <-s.done:
		select {
		case <-t.exited:
		default:
			return
		}
	}
	if exit := t.info().Exit; exit == nil || !exit.Released {
		s.logTerminal("exit", t, exit)
	}
}

func (s *server) input(id string, data []byte) *Error {
	t, refusal := s.find(id)
	if refusal != nil {
		return refusal
	}
	return s.terminalError(t.input(s.ctx, data))
}

func (s *server) resize(id string, rows, cols int) *Error {
	t, refusal := s.find(id)
	if refusal != nil {
		return refusal
	}
	if rows <= 0 || cols <= 0 || rows > 0xffff || cols > 0xffff {
		return badRequest(fmt.Sprintf("bad terminal size %dx%d", rows, cols))
	}
	return s.terminalError(t.resize(rows, cols))
}

// terminalError turns a terminal's input or resize error into a reply's.
func (s *server) terminalError(err error) *Error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, errInputStalled):
		return &Error{Code: CodeInputStalled, Message: err.Error()}
	case errors.Is(err, errNotRunning):
		return &Error{Code: CodeNotRunning, Message: err.Error()}
	case s.ctx.Err() != nil:
		return &Error{Code: CodeStopping, Message: "the keeper is stopping"}
	}
	return badRequest(err.Error())
}

func (s *server) end(id string) (*Info, *Error) {
	t, refusal := s.find(id)
	if refusal != nil {
		return nil, refusal
	}
	info := s.endTerminal(t)
	return &info, nil
}

func (s *server) endTerminal(t *terminal) Info {
	if t.info().Running {
		s.logTerminal("end", t, nil)
	}
	return t.end()
}

// endAll stops new terminals, ends every terminal the keeper started and
// releases every adopted one, all at once. It waits at most endAllWait.
func (s *server) endAll() {
	s.mu.Lock()
	s.stopping = true
	all := make([]*terminal, 0, len(s.terminals))
	for _, e := range s.terminals {
		all = append(all, e.t)
	}
	s.mu.Unlock()
	var wg sync.WaitGroup
	for _, t := range all {
		wg.Add(1)
		if t.adopted {
			go func() {
				defer wg.Done()
				s.releaseTerminal(t)
			}()
			continue
		}
		t.endingByKeeper()
		go func() {
			defer wg.Done()
			s.endTerminal(t)
		}()
	}
	ended := make(chan struct{})
	go func() {
		wg.Wait()
		close(ended)
	}()
	timer := time.NewTimer(endAllWait)
	defer timer.Stop()
	select {
	case <-ended:
	case <-timer.C:
	}
}

func (s *server) forget(id string) *Error {
	s.mu.Lock()
	e := s.terminals[id]
	switch {
	case e == nil:
		s.mu.Unlock()
		return &Error{Code: CodeNotFound, Message: fmt.Sprintf("no terminal %q", id)}
	case e.t.info().Running:
		s.mu.Unlock()
		return &Error{Code: CodeRunning, Message: fmt.Sprintf("terminal %q is running", id)}
	}
	delete(s.terminals, id)
	s.mu.Unlock()
	s.poke()
	s.logTerminal("forget", e.t, nil)
	return nil
}

func (s *server) setMeta(id string, meta []byte) *Error {
	t, refusal := s.find(id)
	if refusal != nil {
		return refusal
	}
	t.setMeta(meta)
	return nil
}

// serveAttach takes one attach request, then streams the terminal's output
// from its cursor until the program has exited, the client leaves or the
// keeper stops.
func (s *server) serveAttach(conn net.Conn) {
	_ = conn.SetDeadline(time.Now().Add(s.helloWait))
	kind, payload, err := readFrame(conn)
	if err != nil || kind != kindRequest {
		return
	}
	req, err := decodeRequest(payload)
	if err != nil {
		_ = writeReply(conn, reply{Seq: seqOf(payload), Error: badRequest(err.Error())})
		return
	}
	if req.Op != opAttach {
		_ = writeReply(conn, reply{Seq: req.Seq, Error: badRequest("an attach connection takes one attach request")})
		return
	}
	t, refusal := s.find(req.ID)
	if refusal != nil {
		_ = writeReply(conn, reply{Seq: req.Seq, Error: refusal})
		return
	}
	info := t.info()
	if writeReply(conn, reply{Seq: req.Seq, Info: &info}) != nil {
		return
	}
	_ = conn.SetDeadline(time.Time{})

	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	s.wg.Add(1)
	go func() { // the client sends nothing more; a read returns when it leaves
		defer s.wg.Done()
		defer cancel()
		_, _ = conn.Read(make([]byte, 1))
	}()
	r := t.subscribe(req.Cursor)
	for {
		ev, err := r.next(ctx)
		if err != nil {
			return // io.EOF after EventExited, or the stream was cancelled
		}
		switch ev.Kind {
		case EventData:
			err = writeFrame(conn, kindData, encodeData(ev.Offset, ev.Data))
		case EventSkipped:
			err = writeFrame(conn, kindSkipped, encodeSkipped(ev.SkippedTo))
		case EventExited:
			var body []byte
			if body, err = json.Marshal(ev.Exit); err == nil {
				err = writeFrame(conn, kindExited, body)
			}
		}
		if err != nil {
			return
		}
	}
}

// logTerminal writes one lifecycle line: the time, the event, the terminal's
// ID and pid, and how it exited. Never contents, arguments or environment.
func (s *server) logTerminal(event string, t *terminal, exit *Exit) {
	line := s.options.Now().Format(time.RFC3339) + " " + event + " id=" + t.id + " pid=" + strconv.Itoa(t.pid)
	if exit != nil {
		if exit.Code != nil {
			line += " code=" + strconv.Itoa(*exit.Code)
		} else if exit.Signal != "" {
			line += " signal=" + exit.Signal
		}
	}
	_, _ = io.WriteString(s.log, line+"\n")
}

// logKeeper writes a lifecycle line about the keeper itself.
func (s *server) logKeeper(event string) {
	_, _ = io.WriteString(s.log, s.options.Now().Format(time.RFC3339)+" "+event+" pid="+strconv.Itoa(os.Getpid())+"\n")
}
