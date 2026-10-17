//go:build darwin

package host

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// An agent a killed host left running (the test binary, re-executed): it
// leads its own process group, as the host starts agents, with a tool in
// it, and ignores SIGTERM and the end of its input. It records its pid in
// AGENTLAND_FAKE_LEFTOVER and its tool's next to it.
func init() {
	if os.Getenv("AGENTLAND_FAKE_AGENT") != "acp-leftover" {
		return
	}
	syscall.Setpgid(0, 0)
	signal.Ignore(syscall.SIGTERM)
	marker := os.Getenv("AGENTLAND_FAKE_LEFTOVER")
	self, _ := os.Executable()
	child := exec.Command(self)
	child.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=acp-child", "AGENTLAND_FAKE_CHILD_PID="+marker+".child")
	if child.Start() != nil {
		os.Exit(7)
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(marker + ".child"); err == nil {
			break
		}
	}
	os.WriteFile(marker, []byte(fmt.Sprint(os.Getpid())), 0o600)
	time.Sleep(time.Hour)
	os.Exit(0)
}

// placeAgent puts the test binary at path, as an agent's executable in the
// agents folder.
func placeAgent(t *testing.T, path string) {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if os.Link(self, path) == nil {
		return
	}
	source, err := os.Open(self)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	target, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}

func readPid(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

func parentOf(pid int) int {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return -1
	}
	return int(info.Eproc.Ppid)
}

// startLeftover starts program with args as an agent whose host is gone: the
// shell that started it exits, so launchd adopts it.
func startLeftover(t *testing.T, program string, args ...string) (pid, child int) {
	t.Helper()
	marker := filepath.Join(t.TempDir(), "leftover.pid")
	shell := exec.Command("/bin/sh", append([]string{"-c", `"$0" "$@" &`, program}, args...)...)
	shell.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=acp-leftover", "AGENTLAND_FAKE_LEFTOVER="+marker)
	if err := shell.Run(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the leftover to start", func() bool { pid = readPid(marker); return pid > 0 })
	child = readPid(marker + ".child")
	endIfLeft(t, pid, child)
	waitFor(t, "launchd to adopt the leftover", func() bool { return parentOf(pid) == 1 })
	return pid, child
}

// The next host ends only what is certainly an agent a lost host left: the
// same process (pid and start time), leading its own group, adopted by
// launchd, and running an executable inside the agents folder. Then its
// whole group ends.
func TestACPLeftoverIsOnlyAnAgentOfALostHost(t *testing.T) {
	agents := filepath.Join(t.TempDir(), "host.json.agents")
	program := filepath.Join(agents, "fake", "1.0.0", "agent")
	placeAgent(t, program)
	pid, child := startLeftover(t, program)
	start, ok := acpProcessStart(pid)
	if !ok || start <= 0 {
		t.Fatalf("no start time for %d", pid)
	}
	// A process of this host's (its parent is alive), otherwise the same.
	marker := filepath.Join(t.TempDir(), "own.pid")
	own := exec.Command(program)
	own.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=acp-leftover", "AGENTLAND_FAKE_LEFTOVER="+marker)
	if err := own.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Kill(-own.Process.Pid, syscall.SIGKILL); own.Wait() })
	waitFor(t, "the host's own agent to start", func() bool { return readPid(marker) > 0 })
	ownStart, _ := acpProcessStart(own.Process.Pid)
	// A tool whose agent ended: launchd adopted it, but it leads no group.
	leader, tool := startLeftover(t, program)
	syscall.Kill(leader, syscall.SIGKILL)
	waitFor(t, "launchd to adopt the tool", func() bool { return parentOf(tool) == 1 })
	toolStart, _ := acpProcessStart(tool)
	for name, test := range map[string]struct {
		record acpProcessRecord
		agents string
	}{
		"another start time":        {acpProcessRecord{Pid: pid, Start: start + 1}, agents},
		"outside the agents folder": {acpProcessRecord{Pid: pid, Start: start}, t.TempDir()},
		"a live host's":             {acpProcessRecord{Pid: own.Process.Pid, Start: ownStart}, agents},
		"no group of its own":       {acpProcessRecord{Pid: tool, Start: toolStart}, agents},
		"no such process":           {acpProcessRecord{Pid: 99999, Start: start}, agents},
	} {
		if acpEndLeftover(test.record, test.agents) {
			t.Errorf("%s: ended", name)
		}
	}
	if processGone(pid) || processGone(child) || processGone(own.Process.Pid) || processGone(tool) {
		t.Fatal("a process ended that is not a leftover")
	}
	if !acpEndLeftover(acpProcessRecord{Pid: pid, Start: start}, agents) {
		t.Fatal("the leftover was not ended")
	}
	if untilGone(time.Now().Add(2*time.Second), pid, child).IsZero() {
		t.Fatalf("the leftover (gone: %v) or its tool (gone: %v) is still running", processGone(pid), processGone(child))
	}
}

// The engine records each agent process it starts for the next host, and
// forgets it when the process ends.
func TestACPRecordsItsAgentsForTheNextHost(t *testing.T) {
	f := newACPFixture(t, nil)
	f.script(1, fakeSteps(fakeInit(map[string]any{}), fakeNewSession("s-1", nil), fakeAwait("session/prompt"), fakeReply(map[string]any{"stopReason": "end_turn"}))...)
	records := func() []acpProcessRecord {
		var list []acpProcessRecord
		data, err := readPrivateState(f.store.Path + ".acp-processes.json")
		if err != nil {
			t.Fatalf("the records: %v", err)
		}
		if err := json.Unmarshal(data, &list); err != nil {
			t.Fatalf("the records: %v", err)
		}
		return list
	}
	session := f.newChat("fake", "")
	f.mustSend(session.ID, "hi")
	f.waitIdle(session.ID)
	agent, _ := f.pids(1)
	start, ok := acpProcessStart(agent)
	if !ok {
		t.Fatal("the agent is not running")
	}
	command := filepath.Join(f.host.agents.store.versionDir("fake", "1.0.0"), "agent")
	if got := records(); !reflect.DeepEqual(got, []acpProcessRecord{{Pid: agent, Start: start, Command: command}}) {
		t.Fatalf("records %+v, want pid %d started %d running %s", got, agent, start, command)
	}
	if !f.chat(session.ID).stopIfIdle(false) {
		t.Fatal("the process was not idle")
	}
	waitFor(t, "the record to go", func() bool { return len(records()) == 0 })
}

// A host that starts ends the agents the records of a killed host name.
func TestACPNextHostEndsLeftovers(t *testing.T) {
	f := newACPFixture(t, nil)
	program := filepath.Join(f.host.agents.store.root, "leftover", "1.0.0", "agent")
	placeAgent(t, program)
	pid, child := startLeftover(t, program)
	start, _ := acpProcessStart(pid)
	data, _ := json.Marshal([]acpProcessRecord{{Pid: pid, Start: start}})
	if err := writePrivateState(f.store.Path+".acp-processes.json", data); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(f.store.Path+".chats.json", acpTestRunner{})
	if err != nil {
		t.Fatal(err)
	}
	next := newHost(f.store, f.host.agent, HostOptions{CLIChats: chats, Agents: &AgentOptions{Version: "test"}})
	quietAgents(next.agents, nil, nil, nil)
	t.Cleanup(func() {
		next.Close()
		next.agents.close()
	})
	if untilGone(time.Now().Add(2*time.Second), pid, child).IsZero() {
		t.Fatalf("the leftover (gone: %v) or its tool (gone: %v) is still running", processGone(pid), processGone(child))
	}
	data, err = readPrivateState(f.store.Path + ".acp-processes.json")
	if err != nil || strings.TrimSpace(string(data)) != "[]" {
		t.Fatalf("the records after the start: %q %v", data, err)
	}
}

// npm installs run as node with their script inside the agents folder: the
// next host ends such a leftover only when the executable is node and its
// script is inside the agents folder (the recorded command, when the record
// has one), with every other check as for binaries.
func TestACPLeftoverOfAnNPMAgentRunsAsNode(t *testing.T) {
	agents := filepath.Join(t.TempDir(), "host.json.agents")
	script := filepath.Join(agents, "gemini", "0.61.0", "node_modules", ".bin", "gemini")
	other := filepath.Join(agents, "qwen-code", "0.1.0", "node_modules", ".bin", "qwen")
	for _, path := range []string{script, other} {
		writeScript(t, path, "exit 0\n")
	}
	bin := t.TempDir()
	node := filepath.Join(bin, "node")
	placeAgent(t, node)
	notNode := filepath.Join(bin, "nodejs")
	placeAgent(t, notNode)
	outside := writeScript(t, filepath.Join(t.TempDir(), "gemini"), "exit 0\n")
	record := func(pid int, command string) acpProcessRecord {
		t.Helper()
		start, ok := acpProcessStart(pid)
		if !ok {
			t.Fatalf("no start time for %d", pid)
		}
		return acpProcessRecord{Pid: pid, Start: start, Command: command}
	}
	first, firstTool := startLeftover(t, node, script, "--acp")
	second, secondTool := startLeftover(t, node, script, "--acp")
	elsewhere, elsewhereTool := startLeftover(t, node, outside, "--acp")
	renamed, renamedTool := startLeftover(t, notNode, script, "--acp")
	for name, test := range map[string]struct {
		record acpProcessRecord
		agents string
	}{
		"another agent's command":       {record(first, other), agents},
		"another agents folder":         {record(first, script), t.TempDir()},
		"a script outside the folder":   {record(elsewhere, ""), agents},
		"an executable that is no node": {record(renamed, script), agents},
		"another start time":            {acpProcessRecord{Pid: first, Start: record(first, "").Start + 1, Command: script}, agents},
		"a record of Claude Code":       {acpProcessRecord{Pid: first, Start: record(first, "").Start, Executable: node + "x"}, agents},
	} {
		if acpEndLeftover(test.record, test.agents) {
			t.Errorf("%s: ended", name)
		}
	}
	for _, pid := range []int{first, firstTool, second, secondTool, elsewhere, elsewhereTool, renamed, renamedTool} {
		if processGone(pid) {
			t.Fatalf("%d ended, and it is not a leftover", pid)
		}
	}
	// The record names the agent's script; an older host's record names none.
	if !acpEndLeftover(record(first, script), agents) || !acpEndLeftover(record(second, ""), agents) {
		t.Fatal("an npm agent's leftover was not ended")
	}
	if untilGone(time.Now().Add(2*time.Second), first, firstTool, second, secondTool).IsZero() {
		t.Fatal("a leftover or its tool is still running")
	}
}

// Claude Code and Codex processes the host started are recorded with the
// executable the host ran; the next host ends such a leftover only when the
// kernel reports exactly that executable, with every other check as for ACP
// agents, and with or without the agent catalog.
func TestLeftoverOfClaudeCodeOrCodexIsItsExactExecutable(t *testing.T) {
	bin := t.TempDir()
	claude := filepath.Join(bin, "claude")
	placeAgent(t, claude)
	link := filepath.Join(bin, "claude-link")
	if err := os.Symlink(claude, link); err != nil {
		t.Fatal(err)
	}
	pid, tool := startLeftover(t, claude)
	start, _ := acpProcessStart(pid)
	// A process of this host's (its parent is alive), otherwise the same.
	marker := filepath.Join(t.TempDir(), "own.pid")
	own := exec.Command(claude)
	own.Env = append(os.Environ(), "AGENTLAND_FAKE_AGENT=acp-leftover", "AGENTLAND_FAKE_LEFTOVER="+marker)
	if err := own.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Kill(-own.Process.Pid, syscall.SIGKILL); own.Wait() })
	waitFor(t, "the host's own Claude Code to start", func() bool { return readPid(marker) > 0 })
	ownStart, _ := acpProcessStart(own.Process.Pid)
	// The agents folder is elsewhere: the ACP rules never match these.
	agents := t.TempDir()
	for name, test := range map[string]acpProcessRecord{
		"another path to the same program": {Pid: pid, Start: start, Executable: link},
		"another spelling of the path":     {Pid: pid, Start: start, Executable: filepath.Join(bin, ".", "claude") + "/"},
		"a relative path":                  {Pid: pid, Start: start, Executable: "claude"},
		"another start time":               {Pid: pid, Start: start + 1, Executable: claude},
		"a live host's":                    {Pid: own.Process.Pid, Start: ownStart, Executable: claude},
		"an ACP record":                    {Pid: pid, Start: start},
	} {
		if acpEndLeftover(test, agents) {
			t.Errorf("%s: ended", name)
		}
	}
	if processGone(pid) || processGone(tool) || processGone(own.Process.Pid) {
		t.Fatal("a process ended that is not a leftover")
	}
	if !acpEndLeftover(acpProcessRecord{Pid: pid, Start: start, Executable: claude}, "") {
		t.Fatal("the leftover was not ended")
	}
	if untilGone(time.Now().Add(2*time.Second), pid, tool).IsZero() {
		t.Fatal("the leftover or its tool is still running")
	}
}

// The Claude Code and Codex engines record each process they start, with
// the executable they ran, and forget it once it ended.
func TestClaudeAndCodexRecordTheirProcesses(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	records := func(path string) []acpProcessRecord {
		t.Helper()
		var list []acpProcessRecord
		data, err := readPrivateState(path)
		if err != nil {
			t.Fatalf("the records: %v", err)
		}
		if err := json.Unmarshal(data, &list); err != nil {
			t.Fatalf("the records: %v", err)
		}
		return list
	}
	recorded := func(path string, pid int) bool {
		for _, record := range records(path) {
			if record.Pid == pid {
				return true
			}
		}
		return false
	}
	// wantRecord checks the record of a running process.
	wantRecord := func(path string, pid int) {
		t.Helper()
		start, ok := acpProcessStart(pid)
		if !ok {
			t.Fatalf("%d is not running", pid)
		}
		want := acpProcessRecord{Pid: pid, Start: start, Executable: self}
		for _, record := range records(path) {
			if record == want {
				return
			}
		}
		t.Fatalf("no record %+v in %+v", want, records(path))
	}
	t.Run("Claude Code", func(t *testing.T) {
		f := newClaudeFixture(t, nil)
		f.script(0, step(map[string]any{"do": "init"}), textTurn("msg_1", "done", "", 0.001))
		id := f.newChat()
		f.mustSend(id, "hello", nil)
		f.waitIdle(id)
		var argv struct{ Pid int }
		data, _ := os.ReadFile(filepath.Join(f.dir, "argv-1.json"))
		json.Unmarshal(data, &argv)
		if argv.Pid <= 0 {
			t.Fatal("the fake recorded no pid")
		}
		path := f.store.Path + ".acp-processes.json"
		wantRecord(path, argv.Pid)
		if !f.chatState(id).stopIfIdle(false) {
			t.Fatal("the idle process did not stop")
		}
		waitFor(t, "its record to go", func() bool { return !recorded(path, argv.Pid) })
	})
	t.Run("Codex", func(t *testing.T) {
		fake := newCodexFake(t)
		f := newCodexFixture(t, fake)
		id := f.newChat()
		f.send(id, "hello", nil)
		f.idle(id)
		pid := 0
		for _, entry := range fake.log() {
			if entry.Start != 0 {
				pid = entry.Start
			}
		}
		if pid <= 0 {
			t.Fatal("the fake app-server did not start")
		}
		path := f.store.Path + ".acp-processes.json"
		wantRecord(path, pid)
		f.host.BeginShutdown()
		waitFor(t, "its record to go", func() bool { return !recorded(path, pid) })
	})
}

// A host that starts ends a Claude Code or Codex process a killed host left,
// by its record, also without the agent catalog.
func TestNextHostEndsALeftoverClaudeCode(t *testing.T) {
	_, store, agent := testHost(t)
	claude := filepath.Join(t.TempDir(), "bin", "claude")
	placeAgent(t, claude)
	pid, tool := startLeftover(t, claude)
	start, _ := acpProcessStart(pid)
	data, _ := json.Marshal([]acpProcessRecord{{Pid: pid, Start: start, Executable: claude}})
	if err := writePrivateState(store.Path+".acp-processes.json", data); err != nil {
		t.Fatal(err)
	}
	chats, err := NewCLIChats(store.Path+".chats.json", &fakeCLIChatRunner{})
	if err != nil {
		t.Fatal(err)
	}
	next := newHost(store, agent, HostOptions{CLIChats: chats})
	t.Cleanup(func() { next.Close() })
	if untilGone(time.Now().Add(2*time.Second), pid, tool).IsZero() {
		t.Fatalf("the leftover (gone: %v) or its tool (gone: %v) is still running", processGone(pid), processGone(tool))
	}
	data, err = readPrivateState(store.Path + ".acp-processes.json")
	if err != nil || strings.TrimSpace(string(data)) != "[]" {
		t.Fatalf("the records after the start: %q %v", data, err)
	}
}
