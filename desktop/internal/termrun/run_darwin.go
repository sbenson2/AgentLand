//go:build darwin

package termrun

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"agentland/host/internal/localterm"
	"agentland/host/keeper"

	"golang.org/x/sys/unix"
)

// setupWait bounds registering with the host and dialing the keeper: past it
// the real command starts as usual.
const setupWait = time.Second

// inputWait bounds one chunk of typing reaching the keeper. It outlasts the
// keeper's own wait for the program to take a chunk (10 s, keeper/terminal.go
// inputWait), so that the keeper's verdict on a chunk always comes first. A
// variable so that tests can shorten it.
var inputWait = 12 * time.Second

const (
	adoptWait       = 5 * time.Second // the keeper's adopt and the window's attach
	resizeWait      = 2 * time.Second
	releaseWait     = 2 * time.Second
	reportWait      = 2 * time.Second // the program's exit reaching the keeper
	endWait         = 6 * time.Second // the keeper hanging up the program's session
	remoteDrainWait = 3 * time.Second // the keeper's last output, after the exit
	localDrainWait  = 2 * time.Second // the PTY's last output, after the exit
	hangUpTermAt    = 2 * time.Second // without a keeper: SIGTERM after SIGHUP
	hangUpKillAt    = 5 * time.Second // and SIGKILL
	stopWait        = time.Second     // a pump stopping once told
	sayWait         = time.Second     // a line to the host
	chunkSize       = 32 << 10        // one read of typing, or of the PTY's output
	// escapeWait is how long a lone ESC waits for the rest of a focus event
	// before it reaches the program as the person's own key.
	escapeWait = 25 * time.Millisecond
	// The agent's last output reaches the window before its job suspends:
	// output quiet for suspendQuiet, or at most suspendSettle.
	suspendQuiet  = 50 * time.Millisecond
	suspendSettle = 300 * time.Millisecond
	// suspendCheck: a suspend not followed by SIGCONT this soon never
	// happened (the shell's job could not stop), and the job goes on.
	suspendCheck = 250 * time.Millisecond
)

const ctrlZ = 0x1a

// RunStatus runs the command o names as an AgentLand terminal and returns how
// it ended, once the window is restored, or replaces this process with the
// command when AgentLand cannot take it (anything missing before the program
// starts). See the package documentation.
func RunStatus(o Options) Status {
	path, err := lookPath(o.Name, o.Env, o.Dir)
	if err != nil {
		say(o.Stderr, o.Name+": command not found\n")
		return Status{Code: 127}
	}
	argv := append([]string{o.Name}, o.Args...)
	if !isTerminal(o.Stdin) || !isTerminal(o.Stdout) || nested(o.Env) {
		return Status{Code: execCommand(o, path, argv)}
	}
	// Claude's conversation is chosen before registering: the host records it.
	args, conversation := withClaudeSession(o.Name, o.Args, newSessionID)
	rows, cols, err := keeper.Size(o.Stdin)
	if err != nil || rows <= 0 || cols <= 0 {
		rows, cols = 0, 0
	}
	reg, code := register(o, rows, cols, conversation)
	if reg == nil {
		printFallback(o.Stderr, code, o.Name)
		return Status{Code: execCommand(o, path, argv)}
	}
	// Anything of AgentLand's own that fails now still comes before the
	// program starts: the command runs as usual.
	fallBack := func(closers ...io.Closer) Status {
		for _, c := range closers {
			c.Close()
		}
		reg.say(localterm.OpCancel)
		reg.keeper.Close()
		printFallback(o.Stderr, "", o.Name)
		return Status{Code: execCommand(o, path, argv)}
	}
	self, err := os.Executable()
	if err != nil {
		return fallBack()
	}
	master, slave, err := keeper.OpenPTY()
	if err != nil {
		return fallBack()
	}
	link, leaderEnd, err := leaderLink()
	if err != nil {
		return fallBack(master, slave)
	}
	if rows > 0 && cols > 0 {
		_ = keeper.SetSize(master, rows, cols)
	}
	signals := o.Signals
	if signals == nil {
		caught := make(chan os.Signal, 32)
		signal.Notify(caught, syscall.SIGWINCH, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT, syscall.SIGQUIT, syscall.SIGCONT)
		defer signal.Stop(caught)
		signals = caught
	}
	// The leader (lead_darwin.go) leads the PTY's session and runs the
	// program in it. os.StartProcess passes the environment as it is.
	env := append(withoutVariable(o.Env, terminalVariable), terminalVariable+"="+reg.id)
	leaderArgs := append([]string{self, "terminals", LeadCommand, "--", path, o.Name}, args...)
	proc, err := os.StartProcess(self, leaderArgs, &os.ProcAttr{
		Dir:   o.Dir,
		Env:   env,
		Files: []*os.File{slave, slave, slave, leaderEnd},
		Sys:   &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0},
	})
	slave.Close()
	leaderEnd.Close()
	if err != nil {
		return fallBack(master, link)
	}
	defer master.Close()
	defer link.Close()
	s := &session{
		o: o, id: reg.id, proc: proc, master: master, link: link,
		exited: make(chan struct{}), linkDone: make(chan struct{}), outDone: make(chan struct{}), inDone: make(chan struct{}),
		suspendAsked: make(chan struct{}, 1), resizeKick: make(chan struct{}, 1), stopResizer: make(chan struct{}),
	}
	go s.wait()
	go s.readLink()
	s.adopt(reg, rows, cols)
	return s.drive(signals)
}

// leaderLink is the link between Run and the leader: a connected pair of
// Unix sockets, Run's end and the leader's.
func leaderLink() (net.Conn, *os.File, error) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		return nil, nil, err
	}
	unix.CloseOnExec(fds[0])
	unix.CloseOnExec(fds[1])
	ours := os.NewFile(uintptr(fds[0]), "agentland-link")
	conn, err := net.FileConn(ours)
	ours.Close()
	if err != nil {
		unix.Close(fds[1])
		return nil, nil, err
	}
	return conn, os.NewFile(uintptr(fds[1]), "agentland-link"), nil
}

// session is one program Run started, through its leader, on its PTY, from
// the adopt on.
type session struct {
	o      Options
	id     string
	proc   *os.Process // the leader, which mirrors the program
	state  *os.ProcessState
	master *os.File // the CLI's own copy, for pumping when the keeper is gone
	link   net.Conn // to the leader
	ctl    *keeper.Client
	att    *keeper.Attachment
	in     *ttyInput
	// adopted says the keeper took the PTY.
	adopted bool

	exited       chan struct{} // closed once the leader was waited for
	linkDone     chan struct{} // closed once the leader's link has ended
	outDone      chan struct{}
	inDone       chan struct{}
	suspendAsked chan struct{}
	resizeKick   chan struct{}
	stopResizer  chan struct{}

	// inputLocal says typing goes to the master; outputLocal that the
	// program's output is read from it. Both start false when the keeper
	// has the terminal.
	inputLocal, outputLocal atomic.Bool
	finishing               atomic.Bool
	lastOutput              atomic.Int64 // unix nanoseconds
	// endedBy is the signal that ended the agent, as the leader said.
	endedBy atomic.Int32

	mu     sync.Mutex // focus
	focus  focusFilter
	sizeMu sync.Mutex

	ttyMu     sync.Mutex // restore
	restore   func()
	leaveOnce sync.Once
	hangUp    sync.Once
}

func (s *session) wait() {
	s.state, _ = s.proc.Wait()
	close(s.exited)
}

// readLink takes the leader's messages: it asks the window's job to
// suspend, and says which signal ended the agent.
func (s *session) readLink() {
	defer close(s.linkDone)
	buf := make([]byte, 64)
	endedNext := false // the next byte is the signal that ended the agent
	for {
		n, err := s.link.Read(buf)
		for _, b := range buf[:n] {
			switch {
			case endedNext:
				s.endedBy.Store(int32(b))
				endedNext = false
			case b == leaderEnded:
				endedNext = true
			case b == leaderSuspend:
				select {
				case s.suspendAsked <- struct{}{}:
				default:
				}
			}
		}
		if err != nil {
			return
		}
	}
}

func (s *session) tellLeader(message byte) {
	_ = s.link.SetWriteDeadline(time.Now().Add(linkWait))
	_, _ = s.link.Write([]byte{message})
}

// adopt hands the PTY to the keeper (step 5). Refused, the CLI pumps the
// PTY itself for the whole session. The host hears "adopted" or "cancel" and
// the connection closes; whatever it answers, the window carries on.
func (s *session) adopt(reg *registration, rows, cols int) {
	ctx, cancel := context.WithTimeout(context.Background(), adoptWait)
	_, err := reg.keeper.Adopt(ctx, keeper.AdoptRequest{ID: s.id, PID: s.proc.Pid, Rows: rows, Cols: cols, Meta: reg.meta}, s.master)
	cancel()
	if err != nil {
		var refused *keeper.RemoteError
		if !errors.As(err, &refused) {
			// The request may have arrived: never let the keeper and the
			// CLI both read the PTY.
			releaseQuietly(s.o, reg.keeper, s.id)
		}
		reg.say(localterm.OpCancel)
		reg.keeper.Close()
		s.inputLocal.Store(true)
		s.outputLocal.Store(true)
		return
	}
	reg.say(localterm.OpAdopted)
	s.ctl = reg.keeper
	s.adopted = true
}

// drive runs the window until the program exits (steps 6 to 11).
func (s *session) drive(signals <-chan os.Signal) Status {
	defer func() {
		panicked := recover()
		s.leave()
		if panicked != nil {
			panic(panicked)
		}
	}()
	s.enterRaw()
	if s.ctl != nil {
		ctx, cancel := context.WithTimeout(context.Background(), adoptWait)
		att, err := s.ctl.Attach(ctx, s.id, 0)
		cancel()
		if err != nil {
			releaseQuietly(s.o, s.ctl, s.id)
			s.ctl.Close()
			s.ctl = nil
			s.inputLocal.Store(true)
			s.outputLocal.Store(true)
		} else {
			s.att = att
		}
	}
	in, err := newTTYInput(s.o.Stdin)
	if err == nil {
		s.in = in
		defer in.close()
		go s.pumpInput()
	} else {
		close(s.inDone)
	}
	go s.pumpOutput()
	go s.resizer()

	var controlDone <-chan struct{}
	if s.ctl != nil {
		controlDone = s.ctl.Done()
	}
	suspended := false
	var suspendChecked <-chan time.Time
	for {
		select {
		case <-s.exited:
			return s.finish()
		case <-controlDone:
			// The keeper never saw what is typed from now on: it goes to
			// the PTY. The output stream ends on its own if the keeper went
			// away, and the output then follows.
			controlDone = nil
			s.inputLocal.Store(true)
		case <-s.suspendAsked:
			if !suspended && !s.finishing.Load() {
				s.suspend()
				suspended = true
				suspendChecked = time.After(suspendCheck)
			}
		case <-suspendChecked:
			suspendChecked = nil
			if suspended { // no SIGCONT: the job never stopped
				s.resumeWindow()
				suspended = false
			}
		case sig := <-signals:
			// Nothing here waits on the keeper, so a burst of resizes never
			// fills the channel and a SIGHUP is never dropped.
			switch sig {
			case syscall.SIGWINCH:
				s.kickResize()
			case syscall.SIGHUP:
				s.startHangUp()
			case syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT:
				s.signalLeader(sig.(syscall.Signal))
			case syscall.SIGCONT:
				if suspended {
					s.resumeWindow()
					suspended = false
				}
			}
		}
	}
}

// enterRaw puts the window in raw mode, keeping the settings it had then,
// and turns its focus reporting on.
func (s *session) enterRaw() {
	if restore, err := makeRaw(s.o.Stdin); err == nil {
		s.ttyMu.Lock()
		s.restore = restore
		s.ttyMu.Unlock()
	}
	s.write([]byte(focusOn)) // the CLI's own: the program has not asked
}

// leaveRaw turns the window's focus reporting off and gives it back its
// settings.
func (s *session) leaveRaw() {
	s.write([]byte(focusOff))
	s.ttyMu.Lock()
	restore := s.restore
	s.ttyMu.Unlock()
	if restore != nil {
		restore()
	}
}

// leave is leaveRaw once, on every way out.
func (s *session) leave() { s.leaveOnce.Do(s.leaveRaw) }

// guard restores the window when a pump panics, then panics on.
func (s *session) guard() {
	if panicked := recover(); panicked != nil {
		s.leave()
		panic(panicked)
	}
}

// suspend passes a Ctrl-Z typed in this window to the shell, once the leader
// says the agent stopped for it: the agent's last output reaches the window,
// the window gets its settings back, and the job this process is part of
// stops (SIGTSTP to its process group, as vim does), so the shell shows it
// suspended, a wrapper script around the CLI included. The leader and the
// agent lead a session of their own, outside that group. The shell's fg
// continues the job (resumeWindow).
func (s *session) suspend() {
	deadline := time.Now().Add(suspendSettle)
	for time.Now().Before(deadline) && time.Since(time.Unix(0, s.lastOutput.Load())) < suspendQuiet {
		time.Sleep(10 * time.Millisecond)
	}
	s.leaveRaw()
	if s.o.suspend != nil {
		s.o.suspend()
		return
	}
	_ = unix.Kill(0, unix.SIGTSTP) // returns once continued
}

// resumeWindow takes the window back after the shell continued the job:
// raw mode, focus reporting and its size, then the agent continues.
func (s *session) resumeWindow() {
	s.enterRaw()
	s.kickResize()
	s.tellLeader(leaderContinue)
}

func (s *session) controlAlive() bool {
	if s.ctl == nil {
		return false
	}
	select {
	case <-s.ctl.Done():
		return false
	default:
		return true
	}
}

// keeperHolds says the keeper still has the terminal: it took it, and has
// neither given it back nor been seen to go away.
func (s *session) keeperHolds() bool {
	return s.adopted && !s.outputLocal.Load()
}

// keeperControl is a control connection to the keeper: the CLI's own while
// it lasts, else a new one. done closes a new one.
func (s *session) keeperControl(ctx context.Context) (c *keeper.Client, done func(), err error) {
	if s.controlAlive() {
		return s.ctl, func() {}, nil
	}
	c, err = keeper.Dial(ctx, keeper.SocketPath(s.o.StatePath), s.o.Version)
	if err != nil {
		return nil, nil, err
	}
	return c, func() { c.Close() }, nil
}

// write writes to the window. A window that is gone takes nothing, and the
// pumps carry on.
func (s *session) write(p []byte) { _, _ = s.o.Stdout.Write(p) }

// show writes the program's output to the window and follows its focus
// mode. When the program turned focus reporting off, the CLI turns it on
// again after it: the program still gets no focus events.
func (s *session) show(p []byte) {
	s.lastOutput.Store(time.Now().UnixNano())
	s.write(p)
	s.mu.Lock()
	s.focus.output(p)
	resend := s.focus.disabled
	s.focus.disabled = false
	s.mu.Unlock()
	if resend {
		s.write([]byte(focusOn))
	}
}

// pumpOutput shows the keeper's stream of the program's output (remote
// mode), then, if the stream ends without the program's exit, the PTY's own
// output (local mode).
func (s *session) pumpOutput() {
	defer close(s.outDone)
	defer s.guard()
	if s.att != nil {
		exited, released := s.followStream()
		if exited || s.finishing.Load() {
			return
		}
		if !released {
			// The stream broke: have the keeper give the PTY back, over a
			// new connection if need be, before reading it here.
			releaseQuietly(s.o, s.ctl, s.id)
		}
		s.inputLocal.Store(true)
		s.outputLocal.Store(true)
	}
	buf := make([]byte, chunkSize)
	for {
		n, err := s.master.Read(buf)
		if n > 0 {
			s.show(buf[:n])
		}
		if err != nil {
			return
		}
	}
}

// followStream shows the attach stream until it ends: with the program's
// exit, with the keeper giving the terminal back, or broken.
func (s *session) followStream() (exited, released bool) {
	for {
		ev, err := s.att.Next()
		if err != nil {
			return false, false
		}
		switch ev.Kind {
		case keeper.EventData:
			s.show(ev.Data)
		case keeper.EventExited:
			if ev.Exit != nil && ev.Exit.Released {
				return false, true
			}
			return true, false
		}
	}
}

// pumpInput sends what the window types to the program, in chunks, without
// the focus events the program did not ask for. The window hanging up ends
// the program, as a SIGHUP does.
func (s *session) pumpInput() {
	defer close(s.inDone)
	defer s.guard()
	buf := make([]byte, chunkSize)
	for {
		timeout := time.Duration(-1)
		s.mu.Lock()
		if len(s.focus.pending) > 0 {
			timeout = escapeWait
		}
		s.mu.Unlock()
		n, err := s.in.read(buf, timeout)
		var data []byte
		focusIn := false
		switch {
		case errors.Is(err, errReadTimeout):
			s.mu.Lock()
			data = s.focus.flush()
			s.mu.Unlock()
		case errors.Is(err, io.EOF), errors.Is(err, unix.EIO), errors.Is(err, unix.ENXIO):
			s.startHangUp()
			return
		case err != nil:
			return // stopped
		default:
			s.mu.Lock()
			data, focusIn = s.focus.input(buf[:n])
			s.mu.Unlock()
		}
		if focusIn || len(data) > 0 {
			s.syncSize()
		}
		if len(data) == 0 {
			continue
		}
		if bytes.IndexByte(data, ctrlZ) >= 0 {
			s.tellLeader(leaderCtrlZ) // before the agent can see it
		}
		s.send(data)
	}
}

// send gives the program what was typed: through the keeper while it has
// the terminal, else straight to the PTY. A chunk goes to the PTY only when
// the keeper certainly never took it: the connection had already ended, or
// the keeper holds no such terminal. Otherwise the chunk is the keeper's,
// taken, dropped as stalled, or perhaps written: it is never sent twice.
func (s *session) send(data []byte) {
	if !s.inputLocal.Load() && s.ctl != nil {
		if s.controlAlive() {
			ctx, cancel := context.WithTimeout(context.Background(), inputWait)
			err := s.ctl.Input(ctx, s.id, data)
			cancel()
			if !keeper.IsNotFound(err) {
				return
			}
		}
		s.inputLocal.Store(true)
	}
	_, _ = s.master.Write(data)
}

// kickResize has the resizer sync the size, coalescing a burst.
func (s *session) kickResize() {
	select {
	case s.resizeKick <- struct{}{}:
	default:
	}
}

func (s *session) resizer() {
	defer s.guard()
	for {
		select {
		case <-s.stopResizer:
			return
		case <-s.resizeKick:
			s.syncSize()
		}
	}
}

// syncSize gives the PTY the window's size when another viewer changed it.
func (s *session) syncSize() {
	s.sizeMu.Lock()
	defer s.sizeMu.Unlock()
	rows, cols, err := keeper.Size(s.o.Stdin)
	if err != nil || rows <= 0 || cols <= 0 {
		return
	}
	ptyRows, ptyCols, err := keeper.Size(s.master)
	if err != nil || (ptyRows == rows && ptyCols == cols) {
		return
	}
	if !s.inputLocal.Load() && s.ctl != nil {
		ctx, cancel := context.WithTimeout(context.Background(), resizeWait)
		err := s.ctl.Resize(ctx, s.id, rows, cols)
		cancel()
		if err == nil {
			return
		}
	}
	_ = keeper.SetSize(s.master, rows, cols)
}

// signalLeader sends sig to the leader while it is still this process's
// unreaped child, so that its pid is its own. The leader passes it on to
// the program's group.
func (s *session) signalLeader(sig syscall.Signal) {
	select {
	case <-s.exited:
		return
	default:
	}
	_ = unix.Kill(-s.proc.Pid, sig)
}

// signalForeground sends sig to the terminal's foreground group, the
// program's, while the leader still runs: a leader killed outright passes
// nothing on.
func (s *session) signalForeground(sig syscall.Signal) {
	select {
	case <-s.exited:
		return
	default:
	}
	var group int
	if err := control(s.master, func(fd int) { group, _ = unix.IoctlGetInt(fd, unix.TIOCGPGRP) }); err == nil && group > 1 && group != s.proc.Pid {
		_ = unix.Kill(-group, sig)
	}
}

func (s *session) startHangUp() { s.hangUp.Do(func() { go s.endProgram() }) }

// endProgram ends the program because its window closed, as Terminal would:
// the keeper hangs up its session, or without one the CLI does (SIGHUP, then
// SIGTERM at 2 s and SIGKILL at 5 s).
func (s *session) endProgram() {
	defer s.guard()
	if s.keeperHolds() {
		ctx, cancel := context.WithTimeout(context.Background(), endWait)
		if c, done, err := s.keeperControl(ctx); err == nil {
			_, _ = c.End(ctx, s.id)
			done()
		}
		cancel()
	}
	began := time.Now()
	for _, step := range []struct {
		at  time.Duration
		sig syscall.Signal
	}{{0, syscall.SIGHUP}, {hangUpTermAt, syscall.SIGTERM}, {hangUpKillAt, syscall.SIGKILL}} {
		timer := time.NewTimer(time.Until(began.Add(step.at)))
		select {
		case <-s.exited:
			timer.Stop()
			return
		case <-timer.C:
		}
		if step.sig == syscall.SIGKILL {
			s.signalForeground(step.sig)
		}
		s.signalLeader(step.sig)
	}
}

// finish reports the exit to the keeper, shows the rest of the output, stops
// the pumps and returns the program's status (step 10).
func (s *session) finish() Status {
	state := s.state
	sig := s.agentSignal()
	if s.keeperHolds() {
		ctx, cancel := context.WithTimeout(context.Background(), reportWait)
		if c, done, err := s.keeperControl(ctx); err == nil {
			_ = c.ReportExit(ctx, s.id, exitOf(state, sig))
			done()
		}
		cancel()
	}
	s.finishing.Store(true)
	close(s.stopResizer)
	drain := remoteDrainWait
	if s.outputLocal.Load() {
		drain = localDrainWait
	}
	_ = s.master.SetReadDeadline(time.Now().Add(drain))
	timer := time.NewTimer(drain)
	select {
	case <-s.outDone:
	case <-timer.C:
		if s.att != nil {
			s.att.Close()
		}
		select {
		case <-s.outDone:
		case <-time.After(stopWait):
		}
	}
	timer.Stop()
	if s.in != nil {
		s.in.stop()
	}
	_ = s.master.SetWriteDeadline(time.Now())
	if s.ctl != nil {
		s.ctl.Close() // wakes an input or resize waiting on the keeper
	}
	select {
	case <-s.inDone:
	case <-time.After(stopWait):
	}
	if s.att != nil {
		s.att.Close()
	}
	return Status{Code: exitStatus(state), Signal: sig}
}

// agentSignal is the signal that ended the agent, which the leader tells
// over the link before it exits with 128 plus it, or 0. The leader's end of
// the link closes as it exits, so all it said arrives soon after.
func (s *session) agentSignal() syscall.Signal {
	select {
	case <-s.linkDone:
	case <-time.After(stopWait):
	}
	sig := syscall.Signal(s.endedBy.Load())
	if sig <= 0 || s.state == nil || s.state.ExitCode() != 128+int(sig) {
		return 0
	}
	return sig
}

// exitOf is how the program ended, as the keeper records it: its code, or
// the signal that ended it (the agent's, sig, or the leader's own).
func exitOf(state *os.ProcessState, sig syscall.Signal) keeper.Exit {
	exit := keeper.Exit{At: time.Now()}
	if sig != 0 {
		exit.Signal = unix.SignalName(sig)
		return exit
	}
	if state == nil {
		return exit
	}
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		exit.Signal = unix.SignalName(status.Signal())
		return exit
	}
	code := state.ExitCode()
	exit.Code = &code
	return exit
}

// exitStatus is the status a shell gives the program: its code, or 128 plus
// the signal that ended it.
func exitStatus(state *os.ProcessState) int {
	if state == nil {
		return 1
	}
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	return state.ExitCode()
}

// Exit ends this process as s says: by the signal that ended the agent, so
// that the shell reports the death as it would have without AgentLand
// ("zsh: abort", "segmentation fault"), else with the code. Call it once
// the window is restored, which RunStatus has done by its return.
func Exit(s Status) {
	if s.Signal != 0 {
		dieBy(s.Signal)
	}
	os.Exit(s.Code)
}

// dieBy ends this process by sig with its default action, as the agent
// ended. The agent already left whatever a crash leaves; the CLI adds no
// core of its own (its core limit goes to zero first), though macOS may
// write a crash report naming it. Go's runtime would turn some signals
// (SIGQUIT, SIGABRT, SIGSEGV) into a traceback on the terminal and ignore
// others (SIGUSR1, SIGPIPE), so sig's action is set to SIG_DFL with
// sigaction(2) before the process sends it to itself. It returns only if
// the process lives on, which then exits with 128+sig, never 0.
func dieBy(sig syscall.Signal) {
	_ = unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{})
	if err := defaultAction(sig); err != nil {
		return
	}
	_ = syscall.Kill(os.Getpid(), sig)
	time.Sleep(time.Second) // delivered to another thread, it may land just after
}

// defaultAction sets sig's action to SIG_DFL: sigaction(2) with a zeroed
// struct __sigaction (the handler SIG_DFL, no trampoline, mask or flags).
func defaultAction(sig syscall.Signal) error {
	var action struct {
		handler uintptr
		tramp   uintptr
		mask    uint32
		flags   int32
	}
	// The pointer is converted in the call's argument list (unsafe.Pointer
	// rule 4).
	if _, _, errno := unix.Syscall(unix.SYS_SIGACTION, uintptr(sig), uintptr(unsafe.Pointer(&action)), 0); errno != 0 {
		return errno
	}
	return nil
}

// registration is the host's answer to a register: the terminal's ID and
// record, with the keeper dialed to take it.
type registration struct {
	conn   net.Conn
	id     string
	meta   []byte
	keeper *keeper.Client
}

// say sends the registration's second line, adopted or cancel, and hangs up.
// Whatever the host answers, if anything, the window carries on.
func (r *registration) say(op string) {
	_ = r.conn.SetWriteDeadline(time.Now().Add(sayWait))
	_ = localterm.WriteLine(r.conn, localterm.Request{Op: op})
	r.conn.Close()
}

// register asks the host to take the terminal and dials the keeper, both
// within setupWait (step 3). On any failure it cancels what it registered
// and returns why, as a code for fallbackLine: a host that did not answer
// within setupWait is slow, not gone.
func register(o Options, rows, cols int, conversation string) (*registration, string) {
	ctx, cancel := context.WithTimeout(context.Background(), setupWait)
	defer cancel()
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", localterm.SocketPath(o.StatePath))
	if err != nil {
		return nil, hostCode(err)
	}
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	request := localterm.Request{
		Op: localterm.OpRegister, Command: o.Name, Folder: canonicalFolder(o.Dir),
		Rows: rows, Cols: cols, ConversationID: conversation, Version: o.Version,
	}
	var reply localterm.Reply
	err = localterm.WriteLine(conn, request)
	if err == nil {
		err = localterm.ReadLine(bufio.NewReader(conn), &reply)
	}
	switch {
	case err != nil:
		conn.Close()
		return nil, hostCode(err)
	case reply.Error != nil:
		conn.Close()
		return nil, reply.Error.Code
	case reply.ID == "":
		conn.Close()
		return nil, ""
	}
	reg := &registration{conn: conn, id: reply.ID, meta: reply.Meta}
	client, err := keeper.Dial(ctx, keeper.SocketPath(o.StatePath), o.Version)
	if err != nil || !client.HasFeature(keeper.FeatureAdopt) {
		if client != nil {
			client.Close()
		}
		reg.say(localterm.OpCancel)
		return nil, codeNoKeeper
	}
	_ = conn.SetDeadline(time.Time{})
	reg.keeper = client
	return reg, ""
}

// releaseQuietly has the keeper give the terminal back, if it has it, so
// that only the CLI reads its PTY. A dead control connection is replaced.
func releaseQuietly(o Options, client *keeper.Client, id string) {
	ctx, cancel := context.WithTimeout(context.Background(), releaseWait)
	defer cancel()
	alive := client != nil
	if alive {
		select {
		case <-client.Done():
			alive = false
		default:
		}
	}
	if !alive {
		fresh, err := keeper.Dial(ctx, keeper.SocketPath(o.StatePath), o.Version)
		if err != nil {
			return
		}
		defer fresh.Close()
		client = fresh
	}
	_ = client.Release(ctx, id)
}

// canonicalFolder is dir as the file system names it: symbolic links
// resolved and each name in its true case (fcntl F_GETPATH), as the host
// compares it with its workspaces. The CLI reads it, as part of the
// Terminal.app window; the host never opens it.
func canonicalFolder(dir string) string {
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return filepath.Clean(dir)
	}
	defer unix.Close(fd)
	var buffer [unix.PathMax]byte
	if _, _, errno := unix.Syscall(unix.SYS_FCNTL, uintptr(fd), unix.F_GETPATH, uintptr(unsafe.Pointer(&buffer[0]))); errno != 0 {
		return filepath.Clean(dir)
	}
	return filepath.Clean(unix.ByteSliceToString(buffer[:]))
}

// lookPath finds name as the caller's shell would: a name with a slash as it
// is (from dir when relative), any other in env's PATH.
func lookPath(name string, env []string, dir string) (string, error) {
	if name == "" {
		return "", os.ErrNotExist
	}
	if strings.Contains(name, "/") {
		path := name
		if !filepath.IsAbs(path) {
			path = filepath.Join(dir, path)
		}
		if executable(path) {
			return path, nil
		}
		return "", os.ErrNotExist
	}
	for _, folder := range filepath.SplitList(variable(env, "PATH")) {
		if folder == "" {
			folder = "."
		}
		if !filepath.IsAbs(folder) {
			folder = filepath.Join(dir, folder)
		}
		if path := filepath.Join(folder, name); executable(path) {
			return path, nil
		}
	}
	return "", os.ErrNotExist
}

func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

// variable is the value of key in env, the first if it is set twice, as
// getenv reads it.
func variable(env []string, key string) string {
	for _, kv := range env {
		if value, ok := strings.CutPrefix(kv, key+"="); ok {
			return value
		}
	}
	return ""
}

// nested says the command was typed inside an AgentLand terminal, which
// already reaches every device: it is not routed again.
func nested(env []string) bool { return variable(env, terminalVariable) != "" }

func withoutVariable(env []string, key string) []string {
	return slices.DeleteFunc(slices.Clone(env), func(kv string) bool { return strings.HasPrefix(kv, key+"=") })
}

// execCommand replaces this process with the command, unchanged: the
// caller's own arguments and environment.
func execCommand(o Options, path string, argv []string) int {
	run := o.Exec
	if run == nil {
		run = syscall.Exec
	}
	err := run(path, argv, o.Env)
	if err == nil {
		return 0
	}
	say(o.Stderr, shellError(o.Name, err)+"\n")
	if errors.Is(err, syscall.ENOENT) {
		return 127
	}
	return 126
}

// shellError says why the command could not start, as a shell would.
func shellError(name string, err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return name + ": " + errno.Error()
	}
	return name + ": " + err.Error()
}

// printFallback writes fallbackLine dimmed, only to a terminal.
func printFallback(stderr *os.File, code, name string) {
	if isTerminal(stderr) {
		say(stderr, "\x1b[2m"+fallbackLine(code, name)+"\x1b[0m\n")
	}
}
