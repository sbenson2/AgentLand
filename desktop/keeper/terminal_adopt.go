//go:build darwin

package keeper

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"slices"
	"time"

	"golang.org/x/sys/unix"
)

// exitReportWait is how long an adopted terminal waits, from when its
// program's exit was seen, for the program's parent to report how it ended.
var exitReportWait = 2 * time.Second

var (
	errNotOnTerminal  = errors.New("the program isn't running on that terminal")
	errNotLeader      = errors.New("the program doesn't lead its own session")
	errBlockingMaster = errors.New("the master is in blocking mode: pass OpenPTY's master and keep it non-blocking")
)

// adoptTerminal takes over a PTY whose master another process opened and
// passed, with req.PID running on it: from then on the keeper reads its
// output and writes its input as for a terminal it started. It owns master
// from the call on, and closes it on failure.
func adoptTerminal(req AdoptRequest, master *os.File, now func() time.Time) (*terminal, error) {
	if now == nil {
		now = time.Now
	}
	fail := func(err error) (*terminal, error) {
		master.Close()
		return nil, err
	}
	if err := requirePollable(master); err != nil {
		return fail(err)
	}
	dev, err := ptyDevice(master)
	if err != nil {
		return fail(fmt.Errorf("not a terminal's master: %w", err))
	}
	pids, err := ttyProcesses(dev)
	if err != nil {
		return fail(err)
	}
	if req.PID <= 1 || !slices.Contains(pids, req.PID) {
		return fail(errNotOnTerminal)
	}
	// end signals the program's process group by its pid.
	if sid, err := unix.Getsid(req.PID); err != nil || sid != req.PID {
		return fail(errNotLeader)
	}
	if req.Rows > 0 && req.Cols > 0 {
		if err := SetSize(master, req.Rows, req.Cols); err != nil {
			return fail(err)
		}
	}
	programExited, err := processExited(req.PID)
	if err != nil {
		return fail(err)
	}
	started, err := processStart(req.PID)
	if err != nil {
		started = now()
	}
	t := &terminal{
		id:       req.ID,
		pid:      req.PID,
		started:  started,
		meta:     bytes.Clone(req.Meta),
		dev:      dev,
		master:   master,
		ring:     newRing(RingSize),
		now:      now,
		adopted:  true,
		inputs:   make(chan inputChunk, inputQueue),
		drained:  make(chan struct{}),
		exited:   make(chan struct{}),
		exitSeen: make(chan struct{}),
		changed:  make(chan struct{}),
	}
	go t.drain()
	go t.writeInputs()
	go t.watchAdopted(programExited, exitReportWait)
	return t, nil
}

// requirePollable refuses a master that is in blocking mode, or that Go's
// poller does not watch. Closing such a master would not wake a read waiting
// on it, so the release or the end that closes it could hang. The mode belongs
// to the open file the keeper shares with the sender, so the keeper checks it
// and never sets it. OpenPTY's master is non-blocking.
func requirePollable(master *os.File) error {
	raw, err := master.SyscallConn()
	if err != nil {
		return err
	}
	flags, flagsErr := 0, error(nil)
	if err := raw.Control(func(fd uintptr) { flags, flagsErr = unix.FcntlInt(fd, unix.F_GETFL, 0) }); err != nil {
		return err
	}
	if flagsErr != nil {
		return flagsErr
	}
	if flags&unix.O_NONBLOCK == 0 || master.SetDeadline(time.Time{}) != nil {
		return errBlockingMaster
	}
	return nil
}

// watchAdopted waits for the adopted program to exit, as the kernel sees it
// or as its parent reports it. Then it ends the terminal as watch does. The
// keeper is not the program's parent, so how the program ended is known only
// from a report: it waits up to reportWait from the exit for one. A release
// ends the watch.
func (t *terminal) watchAdopted(programExited <-chan struct{}, reportWait time.Duration) {
	select {
	case <-programExited:
	case <-t.exitSeen:
	case <-t.exited:
		return
	}
	reportBy := time.Now().Add(reportWait)
	t.sigMu.Lock()
	t.reaped = true // its parent may reap it at any moment
	t.sigMu.Unlock()
	t.signalTTY(unix.SIGHUP)
	drainTimer := time.NewTimer(exitDrainWait)
	select {
	case <-t.drained:
	case <-drainTimer.C:
	}
	drainTimer.Stop()
	reportTimer := time.NewTimer(time.Until(reportBy))
	select {
	case <-t.exitSeen:
	case <-t.exited:
	case <-reportTimer.C:
	}
	reportTimer.Stop()
	t.closeMaster()
	<-t.drained
	t.finishWith(func() Exit { // under t.mu: a report either lands before or is refused
		if t.reported != nil {
			return *t.reported
		}
		return Exit{At: t.now()}
	})
}

// release gives an adopted terminal back: the keeper closes its copy of the
// master and stops reading and writing the PTY. The program runs on with the
// copies others hold. Readers get every byte already read, then an exit that
// says Released. A finished terminal is left as it is. No signal reaches the
// program from the keeper after release begins.
func (t *terminal) release() Info {
	t.sigMu.Lock()
	t.released = true
	t.sigMu.Unlock()
	t.closeMaster()
	<-t.drained
	t.finish(Exit{At: t.now(), Released: true})
	return t.info()
}

// reportExit records how the adopted program ended, as the process that
// reaped it says. The first report wakes watchAdopted.
func (t *terminal) reportExit(exit Exit) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.exit != nil {
		return errNotRunning
	}
	if exit.At.IsZero() {
		exit.At = t.now()
	}
	first := t.reported == nil
	t.reported = &Exit{Code: exit.Code, Signal: exit.Signal, At: exit.At}
	if first {
		close(t.exitSeen)
	}
	return nil
}

// adopt takes over the PTY master that came with an adopt request. A refused
// master is closed.
func (s *server) adopt(req *AdoptRequest, master *os.File) (*Info, *Error) {
	if master == nil {
		return nil, badRequest("adopt needs the terminal's master passed with its request")
	}
	refuse := func(e *Error) (*Info, *Error) {
		master.Close()
		return nil, e
	}
	if req == nil {
		return refuse(badRequest("adopt needs its request"))
	}
	if !validID(req.ID) {
		return refuse(badID())
	}
	s.spawnMu.Lock()
	defer s.spawnMu.Unlock()
	if refusal := s.refuseNew(req.ID); refusal != nil {
		return refuse(refusal)
	}
	// adoptTerminal refuses what is not a PTY master.
	if dev, err := ptyDevice(master); err == nil && s.holdsDevice(dev) {
		return refuse(badRequest("another terminal holds that PTY"))
	}
	t, err := adoptTerminal(*req, master, s.options.Now)
	if err != nil {
		return nil, badRequest(err.Error())
	}
	if !s.add(t, "adopt") {
		t.release()
		return nil, &Error{Code: CodeStopping, Message: "the keeper is stopping"}
	}
	info := t.info()
	return &info, nil
}

// holdsDevice reports whether one of the keeper's terminals still has the
// master of the PTY dev open. Adopting that PTY again would split its output
// between two readers.
func (s *server) holdsDevice(dev uint64) bool {
	s.mu.Lock()
	all := make([]*terminal, 0, len(s.terminals))
	for _, e := range s.terminals {
		all = append(all, e.t)
	}
	s.mu.Unlock()
	return slices.ContainsFunc(all, func(t *terminal) bool { return t.holds(dev) })
}

func (s *server) findAdopted(id string) (*terminal, *Error) {
	t, refusal := s.find(id)
	if refusal != nil {
		return nil, refusal
	}
	if !t.adopted {
		return nil, &Error{Code: CodeNotAdopted, Message: fmt.Sprintf("the keeper started terminal %q", id)}
	}
	return t, nil
}

func (s *server) release(id string) *Error {
	t, refusal := s.findAdopted(id)
	if refusal != nil {
		return refusal
	}
	s.releaseTerminal(t)
	return nil
}

// releaseTerminal releases an adopted terminal and drops it from the keeper.
func (s *server) releaseTerminal(t *terminal) {
	running := t.info().Running
	t.release()
	s.mu.Lock()
	if e := s.terminals[t.id]; e != nil && e.t == t {
		delete(s.terminals, t.id)
	}
	s.mu.Unlock()
	s.poke()
	if running {
		s.logTerminal("release", t, nil)
	}
}

func (s *server) reportExit(id string, exit *Exit) *Error {
	if exit == nil {
		return badRequest("reportExit needs the exit")
	}
	t, refusal := s.findAdopted(id)
	if refusal != nil {
		return refusal
	}
	return s.terminalError(t.reportExit(*exit))
}
