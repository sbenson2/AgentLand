//go:build !windows

package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// acpPids are the pids of the n-th start of the fake and of the tool process
// it started (0 when it started none).
func (f *acpFixture) pids(n int) (agent, child int) {
	f.t.Helper()
	var record struct{ Pid int }
	data, err := os.ReadFile(filepath.Join(f.dir, fmt.Sprintf("argv-%d.json", n)))
	if err != nil {
		f.t.Fatalf("start %d: %v", n, err)
	}
	json.Unmarshal(data, &record)
	if data, err := os.ReadFile(filepath.Join(f.dir, fmt.Sprintf("child-%d.pid", n))); err == nil {
		child, _ = strconv.Atoi(strings.TrimSpace(string(data)))
	}
	if record.Pid <= 0 {
		f.t.Fatalf("start %d recorded no pid", n)
	}
	return record.Pid, child
}

func processGone(pid int) bool {
	return errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}

// untilGone waits until every pid is gone or the deadline passes, and
// returns when the last one went (the zero time when one is still there).
func untilGone(deadline time.Time, pids ...int) time.Time {
	for {
		gone := true
		for _, pid := range pids {
			gone = gone && (pid <= 0 || processGone(pid))
		}
		if gone {
			return time.Now()
		}
		if time.Now().After(deadline) {
			return time.Time{}
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// endIfLeft kills what a failed test left running: the fake's processes
// ignore SIGTERM and would otherwise stay for an hour.
func endIfLeft(t *testing.T, pids ...int) {
	t.Cleanup(func() {
		for _, pid := range pids {
			if pid > 0 && !processGone(pid) {
				syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})
}

// Stop that lands after the turn's last check for it but before the prompt
// is written: the prompt still goes out, so session/cancel follows it and
// the agent stops the prompt, instead of running it until the host ends its
// process.
func TestACPStopBeforeThePromptIsWrittenCancelsIt(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, fakeSteps(fakeInit(map[string]any{"promptCapabilities": map[string]any{"image": true}}), fakeNewSession("s-1", nil),
		fakeAwait("session/prompt"), fakeAwait("session/cancel"), fakeReply(map[string]any{"stopReason": "cancelled"}))...)
	session := f.newChat("fake", "")
	chat := f.chat(session.ID)
	// The turn reads the prompt's image after its last check for Stop; a FIFO
	// holds the turn there until the test writes it.
	image := filepath.Join(t.TempDir(), "photo.png")
	if err := syscall.Mkfifo(image, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// A failed test leaves the turn reading; an empty write ends the read.
		if writer, err := os.OpenFile(image, os.O_WRONLY|syscall.O_NONBLOCK, 0); err == nil {
			writer.Close()
		}
	})
	if _, err := chat.send(chatPrompt{text: "look", files: []ChatAttachment{{Name: "photo.png", MIME: "image/png", Path: image}}}); err != nil {
		t.Fatal(err)
	}
	var writer *os.File
	waitFor(t, "the turn to read the image", func() bool {
		// Opening for writing without blocking succeeds once a reader has it
		// open.
		file, err := os.OpenFile(image, os.O_WRONLY|syscall.O_NONBLOCK, 0)
		writer = file
		return err == nil
	})
	if err := chat.interrupt(); err != nil {
		t.Fatal(err)
	}
	writer.Write([]byte("png"))
	writer.Close()
	f.waitIdle(session.ID)
	methods := f.methods(1)
	if len(methods) < 2 || methods[len(methods)-2] != "session/prompt" || methods[len(methods)-1] != "session/cancel" {
		t.Fatalf("methods %v: no session/cancel after the prompt", methods)
	}
	// The agent stopped the prompt itself; its process was not ended for it.
	chat.mu.Lock()
	alive := chat.conn != nil && chat.conn.alive()
	chat.mu.Unlock()
	if !alive {
		t.Fatal("the process was ended instead of the prompt cancelled")
	}
	messages := f.messages(session.ID)
	if last := messages[len(messages)-1]; last.Status != "aborted" {
		t.Fatalf("the stopped turn %+v", last)
	}
}

// The host's shutdown ends every agent's process group within about a
// second, whatever the agent does: the Mac app kills the host 2 s after
// asking it to stop, and a process the host has not ended by then is left
// running. SIGTERM goes at once, with the end of input; SIGKILL follows
// within a second for a group that is still there.
func TestACPShutdownEndsAgentsWithinASecond(t *testing.T) {
	idle := func(extra ...map[string]any) []map[string]any {
		steps := fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}))
		return append(steps, extra...)
	}
	hang := map[string]any{"do": "hang"}
	ignoreTerm := map[string]any{"do": "ignoreTerm"}
	// The idle stop's grace as the host has it, not the fixture's short one.
	production := func(config *acpConfig) { config.stopGrace = acpStopGrace }

	t.Run("SIGTERM at once", func(t *testing.T) {
		// An agent that does not end when its input does, but on SIGTERM.
		f := newACPFixture(t, production)
		f.script(1, idle(hang)...)
		session := f.newChat("fake", "")
		f.mustSend(session.ID, "hi")
		f.waitIdle(session.ID)
		agent, _ := f.pids(1)
		endIfLeft(t, agent)
		began := time.Now()
		f.host.Close()
		took := time.Since(began)
		t.Logf("closed in %v", took.Round(time.Millisecond))
		if !processGone(agent) {
			t.Fatal("the agent outlived Close")
		}
		if took > 300*time.Millisecond {
			t.Fatalf("Close took %v; SIGTERM waited", took)
		}
	})

	t.Run("SIGKILL within a second", func(t *testing.T) {
		// An agent in the middle of a tool that ignores its input's end and
		// SIGTERM, as the tool it started does.
		f := newACPFixture(t, production)
		f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"),
			map[string]any{"do": "child"}, ignoreTerm, fakeText("s-1", "agent_message_chunk", "Working"), hang)...)
		session := f.newChat("fake", "")
		f.mustSend(session.ID, "run the tool")
		waitFor(t, "the tool to run", func() bool {
			messages := f.messages(session.ID)
			return len(messages) == 2 && len(messages[1].Parts) == 1
		})
		agent, child := f.pids(1)
		endIfLeft(t, agent, child)
		if child == 0 || processGone(child) {
			t.Fatalf("the tool process %d is not running", child)
		}
		chat := f.chat(session.ID)
		began := time.Now()
		f.host.Close()
		closed := time.Since(began)
		gone := untilGone(began.Add(1500*time.Millisecond), agent, child)
		t.Logf("closed in %v, the group gone in %v", closed.Round(time.Millisecond), gone.Sub(began).Round(time.Millisecond))
		if gone.IsZero() {
			t.Fatalf("the agent (gone: %v) or its tool (gone: %v) is still running 1.5 s after Close began", processGone(agent), processGone(child))
		}
		if closed > 1500*time.Millisecond {
			t.Fatalf("Close took %v", closed)
		}
		chat.mu.Lock()
		last := cloneMessage(chat.rec.Messages[len(chat.rec.Messages)-1])
		chat.mu.Unlock()
		if last.Status != "aborted" {
			t.Fatalf("the turn the shutdown ended %+v", last)
		}
	})

	t.Run("from the start of HTTP shutdown", func(t *testing.T) {
		// BeginShutdown runs when HTTP shutdown begins, before its drain and
		// before Close: the agents do not wait for either.
		f := newACPFixture(t, production)
		f.script(1, idle(ignoreTerm, hang)...)
		session := f.newChat("fake", "")
		f.mustSend(session.ID, "hi")
		f.waitIdle(session.ID)
		agent, _ := f.pids(1)
		endIfLeft(t, agent)
		began := time.Now()
		f.host.BeginShutdown()
		gone := untilGone(began.Add(1500*time.Millisecond), agent)
		if gone.IsZero() {
			t.Fatal("the agent is still running 1.5 s after shutdown began")
		}
		t.Logf("gone %v after shutdown began", gone.Sub(began).Round(time.Millisecond))
	})
}
