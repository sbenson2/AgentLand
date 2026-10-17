//go:build darwin

package keeper

import (
	"errors"
	"fmt"
	"time"

	"golang.org/x/sys/unix"
)

// ttyProcesses lists the processes whose controlling terminal is dev.
func ttyProcesses(dev uint64) ([]int, error) {
	procs, err := unix.SysctlKinfoProcSlice("kern.proc.tty", int(dev))
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, len(procs))
	for _, p := range procs {
		pids = append(pids, int(p.Proc.P_pid))
	}
	return pids, nil
}

// processStart returns when the kernel started pid.
func processStart(pid int) (time.Time, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return time.Time{}, err
	}
	if int(info.Proc.P_pid) != pid {
		return time.Time{}, fmt.Errorf("keeper: no process %d", pid)
	}
	sec, nsec := info.Proc.P_starttime.Unix()
	return time.Unix(sec, nsec), nil
}

// liveProcessStart returns when pid started, while it runs (a zombie has
// ended): with the pid, it names one process.
func liveProcessStart(pid int) (time.Time, bool) {
	const zombie = 5 // SZOMB, sys/proc.h
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(info.Proc.P_pid) != pid || info.Proc.P_stat == zombie {
		return time.Time{}, false
	}
	sec, nsec := info.Proc.P_starttime.Unix()
	return time.Unix(sec, nsec), true
}

// processExited returns a channel that is closed once pid has exited. It
// watches with kqueue, so pid need not be this process's child. A pid that is
// already gone gives a closed channel. The watch lasts until pid exits.
func processExited(pid int) (<-chan struct{}, error) {
	kq, err := unix.Kqueue()
	if err != nil {
		return nil, fmt.Errorf("keeper: kqueue: %w", err)
	}
	unix.CloseOnExec(kq)
	var change unix.Kevent_t
	unix.SetKevent(&change, pid, unix.EVFILT_PROC, unix.EV_ADD|unix.EV_ONESHOT)
	change.Fflags = unix.NOTE_EXIT
	done := make(chan struct{})
	if _, err := unix.Kevent(kq, []unix.Kevent_t{change}, nil, nil); err != nil {
		unix.Close(kq)
		if errors.Is(err, unix.ESRCH) {
			close(done)
			return done, nil
		}
		return nil, fmt.Errorf("keeper: watch process %d: %w", pid, err)
	}
	go func() {
		defer close(done)
		defer unix.Close(kq)
		events := make([]unix.Kevent_t, 1)
		for {
			n, err := unix.Kevent(kq, nil, events, nil)
			if err == unix.EINTR {
				continue
			}
			if err != nil || n > 0 {
				return
			}
		}
	}()
	return done, nil
}
