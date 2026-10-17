package host

import (
	"encoding/json"
	"math"
	"testing"
	"time"
)

// newCostFixture gives the fake CLI time to exit on its own when its input
// closes (the race detector slows it): a process the host has to signal
// counts as one that saved nothing, which these tests do not script.
func newCostFixture(t *testing.T) *claudeFixture {
	t.Helper()
	return newClaudeFixture(t, func(config *claudeConfig) { config.stopGrace = 10 * time.Second })
}

// turnCost is the cost the chat recorded for a turn's reply, or -1 when it
// recorded none.
func (f *claudeFixture) turnCost(id, turn string) int64 {
	f.t.Helper()
	chat := f.chatState(id)
	chat.mu.Lock()
	defer chat.mu.Unlock()
	for index := len(chat.rec.Messages) - 1; index >= 0; index-- {
		message := chat.rec.Messages[index]
		if message.TurnID != turn || message.Role != "assistant" {
			continue
		}
		if message.Usage == nil || message.Usage.CostMicros == nil {
			return -1
		}
		return *message.Usage.CostMicros
	}
	f.t.Fatalf("no reply for turn %s", turn)
	return 0
}

// costRecord reads what the chat carries across processes.
func (f *claudeFixture) costRecord(id string) (session string, saved, total float64) {
	chat := f.chatState(id)
	chat.mu.Lock()
	defer chat.mu.Unlock()
	return chat.rec.CostSession, chat.rec.CostSaved, chat.rec.CostTotal
}

// stopProcess stops the chat's idle process the way the idle timer does: its
// input closes and it exits on its own.
func (f *claudeFixture) stopProcess(id string) {
	f.t.Helper()
	chat := f.chatState(id)
	if !chat.stopIfIdle(false) {
		f.t.Fatal("the process was not idle")
	}
	waitFor(f.t, "the process to end", func() bool { return !f.live(id) })
}

func sameCost(a, b float64) bool { return math.Abs(a-b) < 1e-12 }

// Claude Code's total_cost_usd is the session's: after --resume the first
// result includes what the session spent before. A restart between turns
// (here an effort change) must not count that again.
func TestClaudeCostCarriesAcrossProcessRestarts(t *testing.T) {
	f := newCostFixture(t)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.0025))
	// The resumed process reports the session's total: 0.0025 restored.
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "two", "", 0.0037), textTurn("msg_3", "three", "", 0.005))
	f.script(3, step(map[string]any{"do": "init"}), textTurn("msg_4", "four", "", 0.0061))
	id := f.newChat()
	first := f.mustSend(id, "first", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, first.MessageID); cost != 2500 {
		t.Fatalf("first turn: %d", cost)
	}
	second := f.mustSend(id, "second", map[string]any{"effort": "high"})
	f.waitIdle(id)
	session := argValue(f.argv(1), "--session-id")
	if argValue(f.argv(2), "--resume") != session {
		t.Fatalf("second start: %v", f.argv(2))
	}
	if cost := f.turnCost(id, second.MessageID); cost != 1200 {
		t.Fatalf("first turn after the restart: %d, want 1200 (not the session's 3700)", cost)
	}
	third := f.mustSend(id, "third", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, third.MessageID); cost != 1300 {
		t.Fatalf("next turn in the same process: %d", cost)
	}
	if got, saved, total := f.costRecord(id); got != session || !sameCost(saved, 0.0025) || !sameCost(total, 0.005) {
		t.Fatalf("carried while it runs: %q %v %v", got, saved, total)
	}
	// An idle stop: the process exits on its own and Claude Code saves 0.005.
	f.stopProcess(id)
	if got, saved, total := f.costRecord(id); got != session || !sameCost(saved, 0.005) || !sameCost(total, 0.005) {
		t.Fatalf("carried after the idle stop: %q %v %v", got, saved, total)
	}
	fourth := f.mustSend(id, "fourth", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, fourth.MessageID); cost != 1100 {
		t.Fatalf("first turn after the idle stop: %d", cost)
	}
	// The registry keeps it for the next host.
	entry, err := f.chats.claudeEntry(f.project, id)
	if err != nil {
		t.Fatal(err)
	}
	var record claudeRecord
	if err := json.Unmarshal(entry.state, &record); err != nil || record.CostSession != session || !sameCost(record.CostTotal, 0.0061) {
		t.Fatalf("saved record: %+v %v", record, err)
	}
}

// A host that stopped without seeing its Claude process end (it crashed, or
// was stopped with it) assumes the process saved its newest total: Claude
// Code does when its input closes.
func TestClaudeCostAfterTheHostRestarted(t *testing.T) {
	f := newCostFixture(t)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.004))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "two", "", 0.0047))
	id := f.newChat()
	f.mustSend(id, "first", nil)
	f.waitIdle(id)
	f.stopProcess(id)
	// What a host that died mid-process leaves: the newest total above the
	// saved one.
	chat := f.chatState(id)
	chat.mu.Lock()
	chat.rec.CostSaved, chat.rec.CostTotal = 0.001, 0.004
	chat.persistLocked()
	chat.mu.Unlock()
	f.chats.claude.mu.Lock()
	delete(f.chats.claude.chats, id)
	f.chats.claude.mu.Unlock()
	if _, saved, total := f.costRecord(id); !sameCost(saved, 0.004) || !sameCost(total, 0.004) {
		t.Fatalf("loaded: saved %v total %v", saved, total)
	}
	second := f.mustSend(id, "second", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, second.MessageID); cost != 700 {
		t.Fatalf("first turn after the host restarted: %d", cost)
	}
}

// A fork's first process restores its source session's saved total (not the
// running total of a source process that has not exited); the fork's first
// turn counts only its own cost.
func TestClaudeForkCostStartsFromTheSourcesSavedTotal(t *testing.T) {
	f := newCostFixture(t)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "entry-1", 0.0025))
	// A fork while the source's process still runs: the session has saved
	// nothing yet, so the fork starts at 0.
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_2", "in the fork", "", 0.0009))
	// A fork after the source's process exited and saved 0.0025.
	f.script(3, step(map[string]any{"do": "init"}), textTurn("msg_3", "in the second fork", "", 0.0034))
	source := f.newChat()
	f.mustSend(source, "first", nil)
	f.waitIdle(source)
	fork := func(title string) string {
		w := f.call("POST", "/v1/chat/fork", map[string]string{"projectId": "p1", "sessionId": source, "title": title})
		if w.Code != 201 {
			t.Fatalf("fork: %d %s", w.Code, w.Body)
		}
		var session Session
		json.Unmarshal(w.Body.Bytes(), &session)
		return session.ID
	}
	live := fork("While it runs")
	turn := f.mustSend(live, "in the fork", nil)
	f.waitIdle(live)
	if args := f.argv(2); argValue(args, "--resume") != argValue(f.argv(1), "--session-id") || args[len(args)-1] != "--fork-session" {
		t.Fatalf("fork start: %v", args)
	}
	if cost := f.turnCost(live, turn.MessageID); cost != 900 {
		t.Fatalf("fork of a running source: %d", cost)
	}
	forkSession, saved, total := f.costRecord(live)
	if forkSession == "" || forkSession == argValue(f.argv(1), "--session-id") || saved != 0 || !sameCost(total, 0.0009) {
		t.Fatalf("fork carries %q %v %v", forkSession, saved, total)
	}
	f.stopProcess(source)
	later := fork("After it saved")
	turn = f.mustSend(later, "in the second fork", nil)
	f.waitIdle(later)
	if cost := f.turnCost(later, turn.MessageID); cost != 900 {
		t.Fatalf("fork of a source that saved 0.0025: %d, want 900", cost)
	}
}

// A chat from before the host carried totals: what Claude Code restores is
// unknown, so the first turn of its next process counts nothing, later ones
// their rise, and after that process exits the chat's total is known.
func TestClaudeCostOfAChatWithoutACarriedTotal(t *testing.T) {
	f := newCostFixture(t)
	f.script(1, step(map[string]any{"do": "init"}), textTurn("msg_1", "one", "", 0.01), textTurn("msg_2", "two", "", 0.0115))
	f.script(2, step(map[string]any{"do": "init"}), textTurn("msg_3", "three", "", 0.012))
	id := f.newChat()
	native := newClaudeUUID()
	state, _ := json.Marshal(claudeRecord{Mode: "auto", Started: true})
	if err := f.chats.claudeSave(f.project, id, native, state, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	f.chats.claude.mu.Lock()
	delete(f.chats.claude.chats, id)
	f.chats.claude.mu.Unlock()
	first := f.mustSend(id, "first", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, first.MessageID); cost != -1 {
		t.Fatalf("first turn with an unknown restored total: %d, want none", cost)
	}
	second := f.mustSend(id, "second", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, second.MessageID); cost != 1500 {
		t.Fatalf("second turn: %d", cost)
	}
	if session, _, _ := f.costRecord(id); session != "" {
		t.Fatalf("known before the process saved: %q", session)
	}
	f.stopProcess(id)
	if session, saved, _ := f.costRecord(id); session != native || !sameCost(saved, 0.0115) {
		t.Fatalf("after the process saved: %q %v", session, saved)
	}
	third := f.mustSend(id, "third", nil)
	f.waitIdle(id)
	if cost := f.turnCost(id, third.MessageID); cost != 500 {
		t.Fatalf("third turn: %d", cost)
	}
}

// The arithmetic on its own: a new session, a known resume, a total that is
// lower than what was restored, and a total that starts over in a process.
func TestClaudeCostRises(t *testing.T) {
	c := &claudeChat{native: "S"}
	c.costStartLocked(claudeLaunch{session: "S"}, claudeForkCost{})
	for _, step := range []struct {
		total float64
		want  int64
	}{{0.001, 1000}, {0.0035, 2500}, {0.0035, 0}, {0.0004, 400}, {math.NaN(), 0}, {-1, 0}} {
		if got := c.costRiseLocked(step.total); got != step.want {
			t.Fatalf("new session, total %v: %d, want %d", step.total, got, step.want)
		}
	}
	if !c.costEndedLocked(true) || c.rec.CostSession != "S" || !sameCost(c.rec.CostSaved, 0.0004) {
		t.Fatalf("after a clean exit: %+v", c.rec)
	}
	c.costStartLocked(claudeLaunch{resume: "S"}, claudeForkCost{})
	if got := c.costRiseLocked(0.0003); got != 0 {
		t.Fatalf("a total below what was restored: %d", got)
	}
	if got := c.costRiseLocked(0.0010); got != 700 {
		t.Fatalf("after it: %d", got)
	}
	if !c.costEndedLocked(false) || !sameCost(c.rec.CostTotal, 0.0004) {
		t.Fatalf("after a kill the saved total stays: %+v", c.rec)
	}
	c.costStartLocked(claudeLaunch{resume: "other"}, claudeForkCost{})
	if c.costKnown || c.rec.CostSession != "" {
		t.Fatalf("another session is unknown: %+v", c.rec)
	}
}
