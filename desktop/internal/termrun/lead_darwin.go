//go:build darwin

package termrun

import (
	"errors"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// The job-control leader.
//
// Why it exists: the agent needs a session of its own, with the PTY as its
// controlling terminal, for the keeper to adopt it. Run's own process stays
// in the shell's session, with the Terminal.app window. A process group with
// no member whose parent is in the same session but another group is
// orphaned, and the kernel discards SIGTSTP, SIGTTIN and SIGTTOU sent to an
// orphaned group. An agent started straight in that new session was such a
// group, so Ctrl-Z never stopped it: neither the ^Z the line discipline turns
// into SIGTSTP, nor Claude Code's own kill(0, SIGTSTP) after it has torn its
// screen down, which then waits forever for a SIGCONT.
//
// So Run starts this leader instead (`agentland-host terminals _lead -- …`):
// it leads the session and owns the PTY as its controlling terminal, and it
// is the pid the keeper adopts. It starts the agent in a process group of its
// own, in the terminal's foreground, and waits for it, stops included. The
// group has a parent in its session, so Ctrl-Z really stops it. Then:
//   - a stop that follows a Ctrl-Z typed in the window within ctrlZWindow is
//     the person's: the leader tells Run, which gives the window back to the
//     shell and stops itself, so the shell shows the job suspended, as with
//     the switch off. When the shell continues it, Run tells the leader,
//     which puts the agent's group back in the foreground and continues it;
//   - any other stop (Ctrl-Z typed on the phone, SIGSTOP from elsewhere) is
//     undone at once, so nothing at a distance can strand the agent.
//
// The leader forwards the hang-ups and ends Run and the keeper send it to the
// agent's group, and exits with the agent's code, or with 128 plus the
// signal that ended it, which it tells Run first: Run ends by that signal
// itself once it has restored the window (Exit), so the shell reports the
// agent's death. The agent runs with the leader's environment, folder and
// terminal, which are the caller's own; argv[0] is the caller's.

// The leader's link with Run: fd 3 in the leader, one byte per message.
const (
	leaderCtrlZ    = 'z' // Run → leader: the window typed Ctrl-Z
	leaderSuspend  = 's' // leader → Run: the agent stopped for it; suspend the window's job
	leaderContinue = 'c' // Run → leader: the window's job continues; continue the agent
	leaderEnded    = 'x' // leader → Run: the next byte is the signal that ended the agent
)

const (
	// ctrlZWindow: a stop this soon after the window's Ctrl-Z is the
	// person's suspend.
	ctrlZWindow = 2 * time.Second
	// ctrlZGrace is how long a stop waits for a Ctrl-Z message still on
	// its way from Run.
	ctrlZGrace = 100 * time.Millisecond
	linkWait   = 100 * time.Millisecond // a message to Run
)

// Lead is the job-control leader: `terminals _lead -- <path> <argv0>
// [args…]` runs path with that argv as described above and returns its
// status.
func Lead(args []string) int {
	if len(args) < 3 || args[0] != "--" {
		say(os.Stderr, "agentland-host: terminals "+LeadCommand+" is started by terminals run\n")
		return 2
	}
	path, argv := args[1], args[2:]
	link := linkFromRun()
	caught := make(chan os.Signal, 16)
	signal.Notify(caught, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT, syscall.SIGQUIT)
	// os.StartProcess, unlike os/exec, passes the environment as it is.
	agent, err := os.StartProcess(path, argv, &os.ProcAttr{
		Env:   os.Environ(),
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
		Sys:   &syscall.SysProcAttr{Foreground: true, Ctty: 0},
	})
	if err != nil {
		say(os.Stderr, shellError(argv[0], err)+"\n")
		if errors.Is(err, syscall.ENOENT) {
			return 127
		}
		return 126
	}
	// The leader now runs in the background of its terminal; putting the
	// agent's group back in the foreground must not stop it. The agent
	// started before this, so it does not inherit the ignored signal.
	signal.Ignore(syscall.SIGTTOU)
	l := &leader{pid: agent.Pid, link: link, caught: caught}
	if link != nil {
		l.messages = readLink(link)
	}
	return l.run()
}

// linkFromRun takes fd 3, Run's end of the link, and closes the descriptor
// itself so that the agent never inherits it. Without one there is no link:
// a descriptor 3 that is not a socket is someone else's and is left alone.
func linkFromRun() net.Conn {
	var st unix.Stat_t
	if err := unix.Fstat(3, &st); err != nil || st.Mode&unix.S_IFMT != unix.S_IFSOCK {
		return nil
	}
	f := os.NewFile(3, "agentland-link")
	if f == nil {
		return nil
	}
	defer f.Close()
	conn, err := net.FileConn(f) // its own copy, closed on exec
	if err != nil {
		return nil
	}
	return conn
}

func readLink(conn net.Conn) <-chan byte {
	messages := make(chan byte, 64)
	go func() {
		defer close(messages)
		buf := make([]byte, 64)
		for {
			n, err := conn.Read(buf)
			for _, b := range buf[:n] {
				messages <- b
			}
			if err != nil {
				return
			}
		}
	}()
	return messages
}

type leader struct {
	pid      int // the agent, which leads its own process group
	link     net.Conn
	messages <-chan byte // nil once Run is gone
	caught   chan os.Signal
	lastZ    time.Time
}

func (l *leader) run() int {
	statuses := make(chan syscall.WaitStatus)
	go func() {
		defer close(statuses)
		for {
			var status syscall.WaitStatus
			_, err := syscall.Wait4(l.pid, &status, syscall.WUNTRACED, nil)
			if err == syscall.EINTR {
				continue
			}
			if err != nil {
				return
			}
			statuses <- status
			if status.Exited() || status.Signaled() {
				return
			}
		}
	}()
	stopped := false    // the agent is stopped
	waitingRun := false // for Run to continue it
	for {
		select {
		case status, ok := <-statuses:
			switch {
			case !ok:
				return 1
			case status.Exited():
				return status.ExitStatus()
			case status.Signaled():
				if l.link != nil {
					_ = l.link.SetWriteDeadline(time.Now().Add(linkWait))
					_, _ = l.link.Write([]byte{leaderEnded, byte(status.Signal())})
				}
				return 128 + int(status.Signal())
			case status.Stopped():
				stopped = true
				if l.windowAsked() && l.tell(leaderSuspend) {
					l.lastZ = time.Time{}
					waitingRun = true
					continue
				}
				l.resume()
				stopped = false
			}
		case message, ok := <-l.messages:
			if !ok {
				l.messages = nil
				if waitingRun { // Run is gone: nothing will continue it
					l.resume()
					stopped, waitingRun = false, false
				}
				continue
			}
			switch message {
			case leaderCtrlZ:
				l.lastZ = time.Now()
			case leaderContinue:
				if waitingRun {
					l.resume()
					stopped, waitingRun = false, false
				}
			}
		case sig := <-l.caught:
			_ = syscall.Kill(-l.pid, sig.(syscall.Signal))
			if stopped { // a stopped agent acts on it once continued
				_ = syscall.Kill(-l.pid, syscall.SIGCONT)
				stopped = false
			}
		}
	}
}

// windowAsked says whether the window typed Ctrl-Z just before the agent
// stopped, waiting ctrlZGrace for a message still on its way.
func (l *leader) windowAsked() bool {
	if l.messages == nil {
		return false
	}
	if !l.lastZ.IsZero() && time.Since(l.lastZ) <= ctrlZWindow {
		return true
	}
	timer := time.NewTimer(ctrlZGrace)
	defer timer.Stop()
	for {
		select {
		case message, ok := <-l.messages:
			if !ok {
				l.messages = nil
				return false
			}
			if message == leaderCtrlZ {
				l.lastZ = time.Now()
				return true
			}
		case <-timer.C:
			return false
		}
	}
}

func (l *leader) tell(message byte) bool {
	_ = l.link.SetWriteDeadline(time.Now().Add(linkWait))
	_, err := l.link.Write([]byte{message})
	return err == nil
}

// resume puts the agent's group back in the terminal's foreground and
// continues it.
func (l *leader) resume() {
	_ = control(os.Stdin, func(fd int) { _ = unix.IoctlSetPointerInt(fd, unix.TIOCSPGRP, l.pid) })
	_ = syscall.Kill(-l.pid, syscall.SIGCONT)
}
