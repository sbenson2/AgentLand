//go:build !windows

package host

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A process killed by a signal saved nothing, so the next process restores
// the total saved before it: Claude Code 2.1.280 restored 0.018 after a
// SIGKILL whose process had reported 0.024. Counting from the newest total
// would leave the next turn out; counting from the saved one is exact.
func TestClaudeCostAfterAKilledProcess(t *testing.T) {
	f := newCostFixture(t)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.0025))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "two", "", 0.0037), step(map[string]any{"do": "killself"}))
	// The process after the kill restores 0.0025, not 0.0037.
	f.script(3, step(map[string]any{"do": "init"}), textTurn("msg_3", "three", "", 0.0036))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	second := f.mustSend(id, "second", map[string]any{"effort": "high"})
	f.waitIdle(id)
	if cost := f.turnCost(id, second.MessageID); cost != 1200 {
		t.Fatalf("second turn: %d", cost)
	}
	waitFor(t, "the killed process to end", func() bool { return !f.live(id) })
	if _, saved, total := f.costRecord(id); !sameCost(saved, 0.0025) || !sameCost(total, 0.0025) {
		t.Fatalf("after the kill: saved %v total %v", saved, total)
	}
	third := f.mustSend(id, "third", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, third.MessageID); cost != 1100 {
		t.Fatalf("first turn after the kill: %d, want 1100", cost)
	}
}

// The host's shutdown ends Claude Code's process group within about a
// second, as it ends ACP agents' (TestACPShutdownEndsAgentsWithinASecond):
// SIGTERM at once, SIGKILL within a second. The Mac app kills the host 2 s
// after asking it to stop.
func TestClaudeShutdownEndsTheProcessGroupWithinASecond(t *testing.T) {
	// The idle stop's grace as the host has it, not the fixture's short one.
	production := func(config *claudeConfig) { config.stopGrace = claudeStopGrace }
	pids := func(f *claudeFixture) (int, int) {
		var record struct{ Pid int }
		data, _ := os.ReadFile(filepath.Join(f.dir, "argv-1.json"))
		json.Unmarshal(data, &record)
		child := 0
		if data, err := os.ReadFile(filepath.Join(f.dir, "child-1.pid")); err == nil {
			child, _ = strconv.Atoi(strings.TrimSpace(string(data)))
		}
		if record.Pid <= 0 {
			t.Fatal("the fake recorded no pid")
		}
		return record.Pid, child
	}
	last := func(chat *claudeChat) ChatMessage {
		chat.mu.Lock()
		defer chat.mu.Unlock()
		all := chat.allLocked()
		return cloneMessage(all[len(all)-1])
	}

	t.Run("SIGKILL within a second", func(t *testing.T) {
		// Claude Code in the middle of a reply, ignoring its input's end and
		// SIGTERM, with a tool process in its group.
		f := newClaudeFixture(t, production)
		f.script(1, step(map[string]any{"do": "init"}), step(map[string]any{"do": "child"}), step(map[string]any{"do": "ignoreTerm"}),
			step(map[string]any{"do": "user", "echo": true}), messageStart("msg_1"),
			claudeEvent(`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`),
			claudeEvent(`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}`),
			step(map[string]any{"do": "hang"}))
		id := f.newChat()
		f.mustSend(id, "work", nil)
		chat := f.chatState(id)
		waitFor(t, "the reply to stream", func() bool {
			message := last(chat)
			return message.Role == "assistant" && len(message.Parts) == 1 && message.Parts[0].Text == "partial"
		})
		agent, child := pids(f)
		endIfLeft(t, agent, child)
		if child == 0 || processGone(child) {
			t.Fatalf("the tool process %d is not running", child)
		}
		began := time.Now()
		f.host.Close()
		closed := time.Since(began)
		gone := untilGone(began.Add(1500*time.Millisecond), agent, child)
		t.Logf("closed in %v, the group gone in %v", closed.Round(time.Millisecond), gone.Sub(began).Round(time.Millisecond))
		if gone.IsZero() {
			t.Fatalf("Claude Code (gone: %v) or its tool (gone: %v) is still running 1.5 s after Close began", processGone(agent), processGone(child))
		}
		if closed > 1500*time.Millisecond {
			t.Fatalf("Close took %v", closed)
		}
		if reply := last(chat); reply.Status != "aborted" || reply.Parts[0].Text != "partial" {
			t.Fatalf("the turn the shutdown ended %+v", reply)
		}
	})

	t.Run("from the start of HTTP shutdown", func(t *testing.T) {
		f := newClaudeFixture(t, production)
		f.script(1, step(map[string]any{"do": "init"}), step(map[string]any{"do": "ignoreTerm"}), textTurn("msg_1", "done", "", 0.001), step(map[string]any{"do": "hang"}))
		id := f.newChat()
		f.mustSend(id, "hi", nil)
		f.waitIdle(id)
		agent, _ := pids(f)
		endIfLeft(t, agent)
		began := time.Now()
		f.host.BeginShutdown()
		gone := untilGone(began.Add(1500*time.Millisecond), agent)
		if gone.IsZero() {
			t.Fatal("Claude Code is still running 1.5 s after shutdown began")
		}
		t.Logf("gone %v after shutdown began", gone.Sub(began).Round(time.Millisecond))
	})
}

// Stopping ends the process group: a tool process the CLI started dies too,
// even when the CLI ignores SIGTERM. Process groups are Unix only.
func TestClaudeStopEndsTheProcessGroup(t *testing.T) {
	f := newClaudeFixture(t, func(config *claudeConfig) { config.stopGrace = 300 * time.Millisecond })
	f.script(0, step(map[string]any{"do": "init"}), step(map[string]any{"do": "child"}), step(map[string]any{"do": "ignoreTerm"}), textTurn("msg_1", "done", "", 0.001), step(map[string]any{"do": "hang"}))
	id := f.newChat()
	f.mustSend(id, "start a tool", nil)
	f.waitIdle(id)
	data, err := os.ReadFile(filepath.Join(f.dir, "child-1.pid"))
	if err != nil {
		t.Fatal(err)
	}
	child, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	if child == 0 || syscall.Kill(child, 0) != nil {
		t.Fatalf("child %d is not running", child)
	}
	began := time.Now()
	if !f.chatState(id).stopIfIdle(false) {
		t.Fatal("the idle process did not stop")
	}
	if took := time.Since(began); took < 600*time.Millisecond {
		t.Fatalf("stopped in %v, before SIGTERM's grace ran out", took)
	}
	waitFor(t, "the tool process to end", func() bool { return errors.Is(syscall.Kill(child, 0), syscall.ESRCH) })
}
