//go:build darwin

package keeper

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Timings tests may shorten.
var (
	// inputWait is how long a chunk of input may wait to be taken by the program.
	inputWait = 10 * time.Second
	// hangUpWait is when end follows its hang-up with SIGTERM.
	hangUpWait = 2 * time.Second
	// killWait is when end kills whatever is left.
	killWait = 5 * time.Second
	// exitDrainWait is how long output is still read after the program exits.
	exitDrainWait = 2 * time.Second
)

const (
	drainChunk = 32 << 10 // bytes read from the PTY at a time
	inputQueue = 64       // chunks of input waiting for the writer
	eventMax   = 64 << 10 // most bytes one data event carries
)

var (
	errInputStalled = errors.New("keeper: the program did not take its input in time")
	errNotRunning   = errors.New("keeper: the terminal is not running")
)

// terminal is one program running in its own PTY and session.
type terminal struct {
	id      string
	pid     int // also the process group and session ID
	started time.Time
	meta    []byte
	dev     uint64    // the PTY slave's device
	cmd     *exec.Cmd // nil when adopted
	master  *os.File
	ring    *ring
	now     func() time.Time
	// adopted says another process started the program and passed its PTY's
	// master: the keeper cannot wait for it, and gives it back on release.
	adopted bool

	inputs     chan inputChunk
	drained    chan struct{} // closed when output reading stops
	exited     chan struct{} // closed once exit is recorded
	exitSeen   chan struct{} // adopted: closed by the first reported exit
	finishOnce sync.Once

	mu        sync.Mutex
	changed   chan struct{} // closed and replaced when output or the exit arrives
	exit      *Exit
	lastInput time.Time // when input last reached the program
	reported  *Exit     // adopted: how the program's parent says it ended
	// byKeeper is set when the keeper's end-all ends the terminal, so its
	// exit says so (Exit.ByKeeper).
	byKeeper bool

	// sigMu orders every signal against giving up the number it is sent by.
	// The PTY's number is ours only while the master is open: macOS hands the
	// slot to the next PTY opened anywhere once it closes. The process group's
	// number is ours while the program is unreaped, and after that only while
	// the group has members; once seen empty it may be anyone's.
	sigMu        sync.Mutex
	masterClosed bool
	reaped       bool
	groupGone    bool
	released     bool // adopted and given back: nothing of it is the keeper's to signal
	// ending is, for an adopted terminal being ended, every process seen on
	// its PTY while the master was open, by pid and start time: the program
	// may run what it starts in other process groups (`terminals run`'s
	// job-control leader runs the agent so), which the program's own group
	// number never reaches, and the PTY's number is not the keeper's once
	// the master closes.
	ending map[int]time.Time
}

type inputChunk struct {
	data     []byte
	deadline time.Time
	done     chan error
}

// startTerminal runs req's program in a new PTY, in its own session with the
// PTY as its controlling terminal.
func startTerminal(req SpawnRequest, now func() time.Time) (*terminal, error) {
	if now == nil {
		now = time.Now
	}
	master, slave, err := OpenPTY()
	if err != nil {
		return nil, err
	}
	defer slave.Close() // the program holds its own copies
	if req.Rows > 0 && req.Cols > 0 {
		if err := SetSize(master, req.Rows, req.Cols); err != nil {
			master.Close()
			return nil, err
		}
	}
	var st unix.Stat_t
	if err := unix.Fstat(int(slave.Fd()), &st); err != nil {
		master.Close()
		return nil, err
	}
	cmd := &exec.Cmd{
		Path:        req.Path,
		Args:        append([]string{req.Path}, req.Args...),
		Dir:         req.Dir,
		Env:         req.Env,
		Stdin:       slave,
		Stdout:      slave,
		Stderr:      slave,
		SysProcAttr: &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0},
	}
	if err := cmd.Start(); err != nil {
		master.Close()
		return nil, err
	}
	pid := cmd.Process.Pid
	started, err := processStart(pid) // the program cannot be reaped before watch runs
	if err != nil {
		started = now()
	}
	t := &terminal{
		id:      req.ID,
		pid:     pid,
		started: started,
		meta:    bytes.Clone(req.Meta),
		dev:     uint64(uint32(st.Rdev)),
		cmd:     cmd,
		master:  master,
		ring:    newRing(RingSize),
		now:     now,
		inputs:  make(chan inputChunk, inputQueue),
		drained: make(chan struct{}),
		exited:  make(chan struct{}),
		changed: make(chan struct{}),
	}
	go t.drain()
	go t.watch()
	go t.writeInputs()
	return t, nil
}

func (t *terminal) info() Info {
	t.mu.Lock()
	defer t.mu.Unlock()
	start, end := t.ring.span() // final once exit is set: nothing is written after it
	info := Info{
		ID:        t.id,
		PID:       t.pid,
		Started:   t.started,
		Running:   t.exit == nil,
		Start:     start,
		Cursor:    end,
		Meta:      t.meta,
		Adopted:   t.adopted,
		LastInput: t.lastInput,
	}
	if t.exit != nil {
		exit := *t.exit
		info.Exit = &exit
	}
	return info
}

// setMeta replaces the terminal's metadata blob.
func (t *terminal) setMeta(meta []byte) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.meta = bytes.Clone(meta)
}

// wakeLocked tells waiting readers something changed. t.mu must be held.
func (t *terminal) wakeLocked() {
	close(t.changed)
	t.changed = make(chan struct{})
}

// drain reads the PTY into the ring until it ends. It never waits on a reader.
// Its first EOF or EIO ends it for good, even if the program still runs: a
// program that closes every copy of the PTY and later reopens /dev/tty
// blocks once the PTY's buffer fills. That is rare.
func (t *terminal) drain() {
	defer close(t.drained)
	buf := make([]byte, drainChunk)
	for {
		n, err := t.master.Read(buf)
		if n > 0 {
			t.ring.write(buf[:n])
			t.mu.Lock()
			t.wakeLocked()
			t.mu.Unlock()
		}
		if err != nil {
			return // EOF, EIO once the PTY's other side is gone, or the master closed
		}
	}
}

// watch waits for the program, hangs up what it left on the PTY, reads its
// last output, then records the exit.
func (t *terminal) watch() {
	_ = t.cmd.Wait() // how the program ended is in ProcessState
	t.sigMu.Lock()
	t.reaped = true
	t.sigMu.Unlock()
	exit := exitOf(t.cmd.ProcessState, t.now())
	t.signalTTY(unix.SIGHUP)
	timer := time.NewTimer(exitDrainWait)
	select {
	case <-t.drained:
	case <-timer.C:
	}
	timer.Stop()
	t.closeMaster()
	<-t.drained
	t.finish(exit)
}

// closeMaster closes the keeper's copy of the master, which wakes a read
// still waiting. No signal is sent by the PTY's number after it.
func (t *terminal) closeMaster() {
	t.sigMu.Lock()
	defer t.sigMu.Unlock()
	if !t.masterClosed {
		t.masterClosed = true
		t.master.Close()
	}
}

// finish records the exit, wakes readers and closes exited. Only its first
// call counts.
func (t *terminal) finish(exit Exit) { t.finishWith(func() Exit { return exit }) }

// finishWith is finish with the exit that build returns. build runs with t.mu
// held, so what it reads cannot change before the exit is recorded.
func (t *terminal) finishWith(build func() Exit) {
	t.finishOnce.Do(func() {
		t.mu.Lock()
		exit := build()
		exit.ByKeeper = t.byKeeper
		t.exit = &exit
		t.wakeLocked()
		t.mu.Unlock()
		close(t.exited)
	})
}

func exitOf(state *os.ProcessState, at time.Time) Exit {
	exit := Exit{At: at}
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

// input queues data for the program. It fails with errInputStalled when the
// program has not taken all of it within inputWait, and with errNotRunning
// once the terminal has finished. Neither error means nothing arrived:
//   - a stalled chunk may already have delivered a prefix; the rest is
//     dropped, never written late;
//   - after ctx ends, input returns ctx.Err() but a queued chunk may still
//     be written.
//
// So a caller must not resend input after an error. Input that arrived is
// recorded as the terminal's last input.
func (t *terminal) input(ctx context.Context, data []byte) (err error) {
	defer func() {
		if err == nil {
			t.mu.Lock()
			t.lastInput = time.Now()
			t.mu.Unlock()
		}
	}()
	chunk := inputChunk{data: bytes.Clone(data), deadline: time.Now().Add(inputWait), done: make(chan error, 1)}
	timer := time.NewTimer(inputWait)
	defer timer.Stop()
	select {
	case t.inputs <- chunk:
	case <-timer.C:
		return errInputStalled
	case <-t.exited:
		return errNotRunning
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case err := <-chunk.done:
		return err
	case <-t.exited:
		select {
		case err := <-chunk.done:
			return err
		default:
			return errNotRunning
		}
	case <-ctx.Done():
		return ctx.Err()
	}
}

// writeInputs writes queued input in order. Each chunk's deadline bounds its write.
func (t *terminal) writeInputs() {
	for {
		select {
		case <-t.exited:
			return
		case chunk := <-t.inputs:
			chunk.done <- t.writeInput(chunk)
		}
	}
}

func (t *terminal) writeInput(chunk inputChunk) error {
	err := t.master.SetWriteDeadline(chunk.deadline)
	if err == nil {
		_, err = t.master.Write(chunk.data)
	}
	switch {
	case err == nil:
		return nil
	case errors.Is(err, os.ErrDeadlineExceeded):
		return errInputStalled
	case errors.Is(err, unix.EIO), t.closedMaster(err):
		return errNotRunning
	}
	return err
}

func (t *terminal) resize(rows, cols int) error {
	select {
	case <-t.exited:
		return errNotRunning
	default:
	}
	err := SetSize(t.master, rows, cols)
	if err != nil && t.closedMaster(err) {
		return errNotRunning
	}
	return err
}

// closedMaster reports whether err came from the master being closed. Not
// every os.File method wraps that error as os.ErrClosed, so the flag decides.
func (t *terminal) closedMaster(err error) bool {
	t.sigMu.Lock()
	defer t.sigMu.Unlock()
	return t.masterClosed || errors.Is(err, os.ErrClosed)
}

// endingByKeeper marks a terminal the keeper's end-all is about to end, so
// its exit says the keeper ended it. One that already exited keeps its exit.
func (t *terminal) endingByKeeper() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.exit == nil {
		t.byKeeper = true
	}
}

// end hangs up the program's session, sends SIGTERM at hangUpWait and
// SIGKILL at killWait, and returns once the program has exited. It stops
// early when the program has exited and its process group is empty. A
// terminal that had already finished is left alone. Jobs the user moved out
// of the session or process group (nohup, disown) may survive, as they do
// when a Terminal.app window closes.
func (t *terminal) end() Info {
	select {
	case <-t.exited:
		return t.info()
	default:
	}
	began := time.Now()
	t.signalSession(unix.SIGHUP)
	if t.settle(began.Add(hangUpWait)) {
		return t.info()
	}
	t.signalSession(unix.SIGTERM)
	if t.settle(began.Add(killWait)) {
		return t.info()
	}
	t.signalSession(unix.SIGKILL)
	<-t.exited
	return t.info()
}

// settle waits until the exit is recorded and the process group is empty,
// and for an adopted terminal no process seen on its PTY is left. It returns
// false at deadline.
func (t *terminal) settle(deadline time.Time) bool {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-t.exited:
	case <-timer.C:
		return false
	}
	for {
		t.sigMu.Lock()
		gone := t.groupGoneLocked() && t.endingGoneLocked()
		t.sigMu.Unlock()
		if gone {
			return true
		}
		select {
		case <-timer.C:
			return false
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// signalSession signals every process on the PTY and the program's process
// group, each only while its number is still ours. An adopted terminal's
// processes seen on the PTY are signalled too, each while it is still the
// same process, so the hang-up goes on after the program and its master
// are gone.
func (t *terminal) signalSession(sig unix.Signal) {
	t.signalTTY(sig)
	t.sigMu.Lock()
	defer t.sigMu.Unlock()
	if t.adopted && !t.released {
		t.noteEndingLocked()
		for pid := range t.ending {
			_ = unix.Kill(pid, sig)
		}
	}
	if !t.groupGoneLocked() {
		_ = unix.Kill(-t.pid, sig)
	}
}

// noteEndingLocked adds the processes on the PTY to t.ending while the
// master is open, and drops the ones that ended or whose pid another
// process took. t.sigMu must be held.
func (t *terminal) noteEndingLocked() {
	if t.ending == nil {
		t.ending = map[int]time.Time{}
	}
	if !t.masterClosed {
		if pids, err := ttyProcesses(t.dev); err == nil {
			for _, pid := range pids {
				if _, known := t.ending[pid]; !known && pid > 1 {
					if started, ok := liveProcessStart(pid); ok {
						t.ending[pid] = started
					}
				}
			}
		}
	}
	for pid, started := range t.ending {
		if now, ok := liveProcessStart(pid); !ok || !now.Equal(started) {
			delete(t.ending, pid)
		}
	}
}

// endingGoneLocked reports whether no process seen on an adopted terminal's
// PTY is left. It is true for a terminal the keeper started, and for one it
// gave back. t.sigMu must be held.
func (t *terminal) endingGoneLocked() bool {
	if !t.adopted || t.released {
		return true
	}
	t.noteEndingLocked()
	return len(t.ending) == 0
}

// groupGoneLocked reports whether the process group's number may no longer be
// ours: the program was reaped and the group was seen empty, or the keeper
// released it. Once seen empty it stays gone. While the program is unreaped,
// its pid, and with it the group number, cannot be handed out again. t.sigMu
// must be held.
func (t *terminal) groupGoneLocked() bool {
	if t.released {
		return true
	}
	if t.reaped && !t.groupGone && unix.Kill(-t.pid, 0) != nil {
		t.groupGone = true // ESRCH, or EPERM for a group that is not ours
	}
	return t.groupGone
}

// signalTTY signals the processes on the PTY while the master is open and
// the terminal is not released. Once the master closes, the PTY's number may
// belong to another terminal.
func (t *terminal) signalTTY(sig unix.Signal) {
	t.sigMu.Lock()
	defer t.sigMu.Unlock()
	if t.masterClosed || t.released {
		return
	}
	pids, err := ttyProcesses(t.dev)
	if err != nil {
		return
	}
	for _, pid := range pids {
		if pid > 1 {
			_ = unix.Kill(pid, sig)
		}
	}
}

// holds reports whether t still has the master of the PTY dev open.
func (t *terminal) holds(dev uint64) bool {
	t.sigMu.Lock()
	defer t.sigMu.Unlock()
	return !t.masterClosed && t.dev == dev
}

// reader follows a terminal's output from a cursor.
type reader struct {
	t        *terminal
	cursor   uint64
	exitSent bool
}

// subscribe returns a reader that starts at from.
func (t *terminal) subscribe(from uint64) *reader {
	return &reader{t: t, cursor: from}
}

// next returns the next event, waiting for one. A reader behind the ring gets
// EventSkipped first. After EventExited it returns io.EOF.
func (r *reader) next(ctx context.Context) (Event, error) {
	for {
		r.t.mu.Lock()
		wake, exit := r.t.changed, r.t.exit
		r.t.mu.Unlock()
		data, at, skipped := r.t.ring.readFrom(r.cursor, eventMax)
		if skipped {
			r.cursor = at
			return Event{Kind: EventSkipped, SkippedTo: at}, nil
		}
		r.cursor = at + uint64(len(data))
		if len(data) > 0 {
			return Event{Kind: EventData, Offset: at, Data: data}, nil
		}
		if exit != nil {
			if r.exitSent {
				return Event{}, io.EOF
			}
			r.exitSent = true
			copied := *exit
			return Event{Kind: EventExited, Exit: &copied}, nil
		}
		select {
		case <-wake:
		case <-ctx.Done():
			return Event{}, ctx.Err()
		}
	}
}
