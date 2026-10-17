//go:build darwin

package termrun

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"agentland/host/keeper"

	"golang.org/x/sys/unix"
)

const (
	attachDialWait = 5 * time.Second
	// attachResizeAfter: the first keystroke after this long without one
	// sends the window's size first, in case another viewer resized.
	attachResizeAfter = time.Second
)

// Attach opens the terminal o.ID that the keeper runs in this window and
// returns how its program ended. It never ends the terminal: a closed
// window (SIGHUP) leaves it running. When the keeper goes away it prints one
// line and returns 1.
func Attach(o AttachOptions) int {
	ctx, cancel := context.WithTimeout(context.Background(), attachDialWait)
	defer cancel()
	client, err := keeper.Dial(ctx, keeper.SocketPath(o.StatePath), o.Version)
	if err != nil {
		say(o.Stderr, "AgentLand's terminal service isn't running.\n")
		return 1
	}
	defer client.Close()
	att, err := client.Attach(ctx, o.ID, 0)
	if keeper.IsNotFound(err) {
		say(o.Stderr, "No running terminal "+o.ID+".\n")
		return 1
	}
	if err != nil {
		say(o.Stderr, "AgentLand's terminal service isn't running.\n")
		return 1
	}
	defer att.Close()
	signals := o.Signals
	if signals == nil {
		caught := make(chan os.Signal, 8)
		signal.Notify(caught, syscall.SIGWINCH, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT, syscall.SIGQUIT)
		defer signal.Stop(caught)
		signals = caught
	}
	v := &viewer{o: o, ctl: client, att: att, ended: make(chan streamEnd, 1), inDone: make(chan struct{})}
	return v.drive(signals)
}

// viewer is one window attached to a terminal.
type viewer struct {
	o   AttachOptions
	ctl *keeper.Client
	att *keeper.Attachment
	in  *ttyInput

	ended  chan streamEnd
	inDone chan struct{}

	mu        sync.Mutex // focus
	focus     focusFilter
	sizeMu    sync.Mutex
	lastInput time.Time // the input pump's

	leaveOnce sync.Once
	restore   func()
}

// streamEnd is how the output stream ended: with the program's exit, or
// not (the keeper gave the terminal back or went away).
type streamEnd struct {
	exited bool
	code   int
}

func (v *viewer) drive(signals <-chan os.Signal) int {
	defer func() {
		panicked := recover()
		v.leave()
		if panicked != nil {
			panic(panicked)
		}
	}()
	if restore, err := makeRaw(v.o.Stdin); err == nil {
		v.restore = restore
	}
	v.write([]byte(focusOn))
	v.resize()
	if in, err := newTTYInput(v.o.Stdin); err == nil {
		v.in = in
		defer in.close()
		go v.pumpInput()
	} else {
		close(v.inDone)
	}
	go v.pumpOutput()
	for {
		select {
		case end := <-v.ended:
			v.stopInput()
			if !end.exited {
				v.leave()
				say(v.o.Stderr, "AgentLand's terminal service stopped; this window is no longer connected.\n")
				return 1
			}
			return end.code
		case sig := <-signals:
			switch sig {
			case syscall.SIGWINCH:
				v.resize()
			case syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT:
				// The window closed, or this process was told to go: the
				// terminal runs on.
				v.stopInput()
				return 128 + int(sig.(syscall.Signal))
			}
		}
	}
}

func (v *viewer) leave() {
	v.leaveOnce.Do(func() {
		v.write([]byte(focusOff))
		if v.restore != nil {
			v.restore()
		}
	})
}

func (v *viewer) guard() {
	if panicked := recover(); panicked != nil {
		v.leave()
		panic(panicked)
	}
}

func (v *viewer) write(p []byte) { _, _ = v.o.Stdout.Write(p) }

func (v *viewer) stopInput() {
	if v.in != nil {
		v.in.stop()
	}
	select {
	case <-v.inDone:
	case <-time.After(stopWait):
	}
}

func (v *viewer) pumpOutput() {
	defer v.guard()
	for {
		ev, err := v.att.Next()
		if err != nil {
			v.ended <- streamEnd{}
			return
		}
		switch ev.Kind {
		case keeper.EventData:
			v.write(ev.Data)
			v.mu.Lock()
			v.focus.output(ev.Data)
			resend := v.focus.disabled
			v.focus.disabled = false
			v.mu.Unlock()
			if resend {
				v.write([]byte(focusOn))
			}
		case keeper.EventExited:
			if ev.Exit != nil && ev.Exit.Released {
				v.ended <- streamEnd{}
			} else {
				v.ended <- streamEnd{exited: true, code: exitCodeOf(ev.Exit)}
			}
			return
		}
	}
}

func (v *viewer) pumpInput() {
	defer close(v.inDone)
	defer v.guard()
	buf := make([]byte, chunkSize)
	for {
		timeout := time.Duration(-1)
		v.mu.Lock()
		if len(v.focus.pending) > 0 {
			timeout = escapeWait
		}
		v.mu.Unlock()
		n, err := v.in.read(buf, timeout)
		var data []byte
		focusIn := false
		switch {
		case errors.Is(err, errReadTimeout):
			v.mu.Lock()
			data = v.focus.flush()
			v.mu.Unlock()
		case err != nil:
			return
		default:
			v.mu.Lock()
			data, focusIn = v.focus.input(buf[:n])
			v.mu.Unlock()
		}
		typed := len(data) > 0
		if focusIn || (typed && time.Since(v.lastInput) >= attachResizeAfter) {
			v.resize()
		}
		if !typed {
			continue
		}
		v.lastInput = time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), inputWait)
		_ = v.ctl.Input(ctx, v.o.ID, data) // a stalled chunk is dropped; a gone keeper ends the stream
		cancel()
	}
}

// resize gives the terminal this window's size.
func (v *viewer) resize() {
	v.sizeMu.Lock()
	defer v.sizeMu.Unlock()
	rows, cols, err := keeper.Size(v.o.Stdin)
	if err != nil || rows <= 0 || cols <= 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), resizeWait)
	defer cancel()
	_ = v.ctl.Resize(ctx, v.o.ID, rows, cols)
}

// exitCodeOf is the status a shell gives a program that ended as exit says.
func exitCodeOf(exit *keeper.Exit) int {
	switch {
	case exit == nil:
		return 1
	case exit.Code != nil:
		return *exit.Code
	case exit.Signal != "":
		if sig := unix.SignalNum(exit.Signal); sig != 0 {
			return 128 + int(sig)
		}
	}
	return 1
}
