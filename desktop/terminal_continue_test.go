//go:build darwin || linux

package host

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentland/host/internal/localterm"
	"agentland/host/internal/termrun"
)

// Continuing a terminal in a new one (terminal_continue.go): `agentland-host
// terminals continue` asks on the private local socket, the host starts Claude
// Code with the prompt in a new terminal for the same device and workspace,
// and the old terminal's end names it.

// continueOn sends one continue to the host's local socket and reads its one
// answer; then the host hangs up.
func continueOn(t *testing.T, path string, request localterm.Request) localterm.Reply {
	t.Helper()
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if request.Op == "" {
		request.Op = localterm.OpContinue
	}
	if err := localterm.WriteLine(conn, request); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	var reply localterm.Reply
	if err := localterm.ReadLine(reader, &reply); err != nil {
		t.Fatalf("reply: %v", err)
	}
	if _, err := reader.ReadByte(); err != io.EOF {
		t.Fatalf("after the answer: %v", err)
	}
	return reply
}

// claudeTerminal is a Claude Code terminal the fixture's device opens in p1,
// titled title, at 30×100.
func claudeTerminal(t *testing.T, host *Host, token, title string) TerminalInfo {
	t.Helper()
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": title, "rows": 30, "cols": 100, "program": "claude"})
	if response.Code != 201 {
		t.Fatalf("create claude: %d %s", response.Code, response.Body)
	}
	return decodeBody[TerminalInfo](t, response)
}

// listedTerminal is the terminal as GET /v1/terminals lists it for token.
func listedTerminal(t *testing.T, host *Host, token, id string) (TerminalInfo, bool) {
	t.Helper()
	response := request(t, host.Handler(), "GET", "/v1/terminals?projectId=p1", token, nil)
	if response.Code != 200 {
		t.Fatalf("list: %d %s", response.Code, response.Body)
	}
	listed := decodeBody[struct {
		Terminals []TerminalInfo `json:"terminals"`
	}](t, response)
	for _, info := range listed.Terminals {
		if info.ID == id {
			return info, true
		}
	}
	return TerminalInfo{}, false
}

func TestContinueStartsClaudeInANewTerminalForTheSameDevice(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	old := claudeTerminal(t, host, f.token, "Plan")
	prompt := `Read HANDOFF.md and go on — "quotes", 'single', $HOME; ünïcode`
	reply := continueOn(t, path, localterm.Request{From: old.ID, Prompt: "  " + prompt + " ", Rows: 40, Cols: 120})
	if reply.Error != nil || reply.ID == "" || reply.ID == old.ID {
		t.Fatalf("reply %+v (%+v)", reply, reply.Error)
	}
	spawn := f.keeper.lastSpawn()
	if spawn.ID != reply.ID || spawn.Path != "/bin/claude" || spawn.Rows != 40 || spawn.Cols != 120 || spawn.Dir != mustProject(t, f.store).Directory {
		t.Fatalf("spawn %+v", spawn)
	}
	// The host's own arguments: a new conversation, then the prompt, trimmed,
	// as one argument.
	if len(spawn.Args) != 3 || spawn.Args[0] != "--session-id" || !conversationIDPattern.MatchString(spawn.Args[1]) || spawn.Args[2] != prompt {
		t.Fatalf("args %q", spawn.Args)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	state, err := filepath.Abs(f.store.Path)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"AGENTLAND_TERMINAL=" + reply.ID, "AGENTLAND_HOST=" + executable, "AGENTLAND_HOST_STATE=" + state}
	if env := spawn.Env; len(env) < 3 || !slices.Equal(env[len(env)-3:], want) {
		t.Fatalf("environment %q", env)
	}
	meta := f.keeper.meta(t, reply.ID)
	if meta.Owner != f.device.ID || meta.Project != "p1" || meta.Program != "claude" || meta.Title != "Plan" || meta.ConversationID != spawn.Args[1] || meta.Routed {
		t.Fatalf("meta %+v", meta)
	}
	// The device lists it beside the old one, which the host never ends.
	if info, ok := listedTerminal(t, host, f.token, reply.ID); !ok || info.Title != "Plan" || info.ConversationID != spawn.Args[1] || info.Status != "running" {
		t.Fatalf("listed %+v %v", info, ok)
	}
	if status := terminalStatus(t, host, f.token, old.ID); status != "running" || len(f.keeper.endedIDs()) != 0 {
		t.Fatalf("old terminal %s, ends %v", status, f.keeper.endedIDs())
	}
	host.terminals.mu.Lock()
	starting := host.terminals.starting
	host.terminals.mu.Unlock()
	if starting != 0 {
		t.Fatalf("starting %d", starting)
	}
}

func TestContinueTakesTheOldTerminalsSizeWhenItHasNone(t *testing.T) {
	f := newRoutedFixture(t)
	restored := terminalMeta{Owner: f.device.ID, Project: "p1", Program: "claude", Title: "Claude Code", Created: time.Now().UTC()}
	f.add("term_restored", restored, "")
	host, path := localHost(t, f, "")
	waitFor(t, "the restored terminal", func() bool { return macEntry(host, "term_restored") != nil })
	old := claudeTerminal(t, host, f.token, "Plan")
	for _, c := range []struct {
		from       string
		rows, cols int
	}{{old.ID, 30, 100}, {"term_restored", 24, 80}} {
		reply := continueOn(t, path, localterm.Request{From: c.from, Prompt: "go on", Rows: 0, Cols: 900})
		if reply.Error != nil {
			t.Fatalf("%s: %+v", c.from, reply.Error)
		}
		if spawn := f.keeper.lastSpawn(); spawn.Rows != c.rows || spawn.Cols != c.cols {
			t.Fatalf("%s: size %d×%d", c.from, spawn.Rows, spawn.Cols)
		}
	}
	if meta := f.keeper.meta(t, f.keeper.latest()); meta.Owner != f.device.ID || meta.Title != "Claude Code" {
		t.Fatalf("meta %+v", meta)
	}
}

func TestAContinuedTerminalsEndNamesTheNewOne(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "")
	old := claudeTerminal(t, host, f.token, "Plan")
	reply := continueOn(t, path, localterm.Request{From: old.ID, Prompt: "go on"})
	if reply.Error != nil {
		t.Fatalf("continue: %+v", reply.Error)
	}
	// The caller ends its own program.
	f.keeper.exit(old.ID, 0)
	output := waitForTerminalEnd(t, host, f.token, old.ID)
	if output.Ended == nil || output.Ended.Reason != terminalEndProgramExited || output.Ended.ContinuedIn != reply.ID {
		t.Fatalf("output's end %+v", output.Ended)
	}
	if info, ok := listedTerminal(t, host, f.token, old.ID); !ok || info.Ended == nil || info.Ended.ContinuedIn != reply.ID {
		t.Fatalf("listed %+v %v", info, ok)
	}
	if body := outputFixture(t, host, f.token, old.ID, 0).Body.String(); !strings.Contains(body, `"continuedIn":"`+reply.ID+`"`) {
		t.Fatalf("output body %s", body)
	}
	// Closed, the host remembers its end, link and all.
	if response := request(t, host.Handler(), "POST", "/v1/terminal/close", f.token, map[string]any{"projectId": "p1", "terminalId": old.ID}); response.Code != 200 {
		t.Fatalf("close: %d %s", response.Code, response.Body)
	}
	response := outputFixture(t, host, f.token, old.ID, 0)
	body := decodeBody[terminalNotFoundBody](t, response)
	if response.Code != 404 || body.Error.Code != "terminal_not_found" || body.Error.Ended == nil || body.Error.Ended.ContinuedIn != reply.ID {
		t.Fatalf("after close: %d %s", response.Code, response.Body)
	}
	// The new terminal's own end names nothing.
	f.keeper.exit(reply.ID, 0)
	if ended := waitForTerminalEnd(t, host, f.token, reply.ID).Ended; ended == nil || ended.ContinuedIn != "" {
		t.Fatalf("new terminal's end %+v", ended)
	}
}

func TestAContinuationRecordedAfterTheEndStillNamesIt(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	ended := claudeTerminal(t, host, token, "Ended")
	fixture.exit(ended.ID, 0)
	waitForTerminalEnd(t, host, token, ended.ID)
	forgotten := claudeTerminal(t, host, token, "Forgotten")
	host.terminals.mu.Lock()
	endedEntry, forgottenEntry := host.terminals.entries[ended.ID], host.terminals.entries[forgotten.ID]
	host.terminals.mu.Unlock()
	if response := request(t, host.Handler(), "POST", "/v1/terminal/close", token, map[string]any{"projectId": "p1", "terminalId": forgotten.ID}); response.Code != 200 {
		t.Fatalf("close: %d %s", response.Code, response.Body)
	}
	host.terminals.recordContinuation(endedEntry, "term_next")
	host.terminals.recordContinuation(forgottenEntry, "term_after")
	if output := readTerminal(t, host, token, ended.ID, 0); output.Ended == nil || output.Ended.ContinuedIn != "term_next" {
		t.Fatalf("ended %+v", output.Ended)
	}
	if end := host.terminals.clearedEnd(forgotten.ID, "p1"); end == nil || end.ContinuedIn != "term_after" || end.Reason != terminalEndDevice {
		t.Fatalf("forgotten %+v", end)
	}
}

func TestContinuePrompt(t *testing.T) {
	for raw, want := range map[string]string{
		"go on":                                  "go on",
		"  read HANDOFF.md  ":                    "read HANDOFF.md",
		"a - b":                                  "a - b",
		"ünïcode “quotes”":                       "ünïcode “quotes”",
		strings.Repeat("x", continuePromptLimit): strings.Repeat("x", continuePromptLimit),
	} {
		if got, ok := continuePrompt(raw); !ok || got != want {
			t.Errorf("%q: %q %v", raw, got, ok)
		}
	}
	for _, raw := range []string{"", "   ", " ", "a\tb", "a\nb", "a\rb", "a\x00b", "a\x1bb", "a\u007fb", "a\u0085b", "\xffbad", "-p", "--help", "  -x", "-",
		strings.Repeat("x", continuePromptLimit+1), strings.Repeat("ü", continuePromptLimit/2) + "x"} {
		if got, ok := continuePrompt(raw); ok {
			t.Errorf("%q accepted as %q", raw, got)
		}
	}
}

func TestContinueRefusals(t *testing.T) {
	cases := []struct {
		name string
		// prepare readies the host and answers the request to send.
		prepare func(t *testing.T, f *routedFixture, host *Host, path string, old TerminalInfo) localterm.Request
		code    string
		message string
	}{
		{name: "version", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			return localterm.Request{From: old.ID, Prompt: "go on", Version: "other"}
		}, code: localterm.CodeVersion},
		{name: "empty prompt", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			return localterm.Request{From: old.ID, Prompt: "  "}
		}, code: localterm.CodeBadRequest},
		{name: "newline", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			return localterm.Request{From: old.ID, Prompt: "go\non"}
		}, code: localterm.CodeBadRequest},
		{name: "tab", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			return localterm.Request{From: old.ID, Prompt: "go\ton"}
		}, code: localterm.CodeBadRequest},
		{name: "option", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			return localterm.Request{From: old.ID, Prompt: " --dangerously-skip-permissions"}
		}, code: localterm.CodeBadRequest},
		{name: "long prompt", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			return localterm.Request{From: old.ID, Prompt: strings.Repeat("x", continuePromptLimit+1)}
		}, code: localterm.CodeBadRequest},
		{name: "no terminal", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, _ TerminalInfo) localterm.Request {
			return localterm.Request{Prompt: "go on"}
		}, code: localterm.CodeNotContinuable},
		{name: "invalid id", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, _ TerminalInfo) localterm.Request {
			return localterm.Request{From: "../term_x", Prompt: "go on"}
		}, code: localterm.CodeNotContinuable},
		{name: "unknown id", prepare: func(_ *testing.T, _ *routedFixture, _ *Host, _ string, _ TerminalInfo) localterm.Request {
			return localterm.Request{From: "term_0123456789abcdef", Prompt: "go on"}
		}, code: localterm.CodeNotContinuable, message: "AgentLand doesn't have this terminal."},
		{name: "ended", prepare: func(t *testing.T, f *routedFixture, host *Host, _ string, old TerminalInfo) localterm.Request {
			f.keeper.exit(old.ID, 0)
			waitForTerminalEnd(t, host, f.token, old.ID)
			return localterm.Request{From: old.ID, Prompt: "go on"}
		}, code: localterm.CodeNotContinuable, message: "This terminal has ended."},
		{name: "shell", prepare: func(t *testing.T, f *routedFixture, host *Host, _ string, _ TerminalInfo) localterm.Request {
			return localterm.Request{From: createTerminalFixture(t, host, f.token).ID, Prompt: "go on"}
		}, code: localterm.CodeNotContinuable, message: "Only a Claude Code terminal can be continued."},
		{name: "routed", prepare: func(t *testing.T, f *routedFixture, _ *Host, path string, _ TerminalInfo) localterm.Request {
			reply, reader, conn := register(t, path, claudeIn(f.folder(t, "code")))
			adopt(f, reply)
			if answer := sendAdopted(t, reader, conn); !answer.OK {
				t.Fatalf("adopted %+v", answer.Error)
			}
			return localterm.Request{From: reply.ID, Prompt: "go on"}
		}, code: localterm.CodeNotContinuable, message: "This terminal was started in Terminal, not by AgentLand."},
		{name: "no claude", prepare: func(_ *testing.T, _ *routedFixture, host *Host, _ string, old TerminalInfo) localterm.Request {
			fakeTerminalPrograms(host, false)
			return localterm.Request{From: old.ID, Prompt: "go on"}
		}, code: localterm.CodeUnknownProgram},
		{name: "unusable", prepare: func(_ *testing.T, _ *routedFixture, host *Host, _ string, old TerminalInfo) localterm.Request {
			host.terminals.setUnusable()
			return localterm.Request{From: old.ID, Prompt: "go on"}
		}, code: localterm.CodeUnavailable},
		{name: "spawn fails", prepare: func(_ *testing.T, f *routedFixture, _ *Host, _ string, old TerminalInfo) localterm.Request {
			f.keeper.setSpawnErr(errors.New("no PTY"))
			return localterm.Request{From: old.ID, Prompt: "go on"}
		}, code: localterm.CodeUnavailable},
		{name: "stopping", prepare: func(_ *testing.T, _ *routedFixture, host *Host, _ string, old TerminalInfo) localterm.Request {
			host.BeginShutdown()
			return localterm.Request{From: old.ID, Prompt: "go on"}
		}, code: localterm.CodeStopping},
		{name: "limit", prepare: func(t *testing.T, f *routedFixture, host *Host, _ string, old TerminalInfo) localterm.Request {
			for index := 1; index < terminalCapacity; index++ {
				createTerminalFixture(t, host, f.token)
			}
			return localterm.Request{From: old.ID, Prompt: "go on"}
		}, code: localterm.CodeLimit},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newRoutedFixture(t)
			host, path := localHost(t, f, "")
			old := claudeTerminal(t, host, f.token, "Plan")
			request := c.prepare(t, f, host, path, old)
			spawns := f.keeper.spawnCount()
			reply := continueOn(t, path, request)
			if reply.Error == nil || reply.Error.Code != c.code || reply.Error.Message == "" || reply.ID != "" || (c.message != "" && reply.Error.Message != c.message) {
				t.Fatalf("reply %+v (%+v)", reply, reply.Error)
			}
			host.terminals.mu.Lock()
			starting := host.terminals.starting
			host.terminals.mu.Unlock()
			if starting != 0 {
				t.Fatalf("starting %d", starting)
			}
			if c.name != "spawn fails" && f.keeper.spawnCount() != spawns {
				t.Fatalf("%d spawns after the refusal", f.keeper.spawnCount()-spawns)
			}
			// Nothing was recorded: the old terminal's end names no other.
			if c.name == "stopping" {
				return
			}
			if entry := macEntry(host, old.ID); entry != nil {
				entry.mu.Lock()
				continued := entry.continuedIn
				entry.mu.Unlock()
				if continued != "" {
					t.Fatalf("continued in %s", continued)
				}
			}
			if c.name == "spawn fails" || c.name == "limit" {
				f.keeper.exit(old.ID, 0)
				if ended := waitForTerminalEnd(t, host, f.token, old.ID).Ended; ended == nil || ended.ContinuedIn != "" {
					t.Fatalf("end %+v", ended)
				}
			}
		})
	}
	t.Run("terminals off", func(t *testing.T) {
		host, _, _, _ := terminalTestHost(t, false)
		reply := continueOn(t, localListener(t, host), localterm.Request{From: "term_0123456789abcdef", Prompt: "go on"})
		if reply.Error == nil || reply.Error.Code != localterm.CodeDisabled {
			t.Fatalf("reply %+v (%+v)", reply, reply.Error)
		}
	})
}

func TestEveryHostTerminalNamesItsHost(t *testing.T) {
	host, store, token, fixture := terminalTestHost(t, true)
	// The host itself runs in another host's terminal.
	host.terminals.launcher.environ = func() []string {
		return []string{"SHELL=/bin/sh", "PATH=/usr/bin:/bin", "AGENTLAND_TERMINAL=term_outer", "AGENTLAND_HOST=/nested/agentland-host", "AGENTLAND_HOST_STATE=/nested/host.json"}
	}
	info := createTerminalFixture(t, host, token)
	state, err := filepath.Abs(store.Path)
	if err != nil {
		t.Fatal(err)
	}
	var marked []string
	for _, item := range fixture.lastSpawn().Env {
		if strings.HasPrefix(item, "AGENTLAND_") {
			marked = append(marked, item)
		}
	}
	if executable, _ := os.Executable(); !slices.Equal(marked, []string{"AGENTLAND_TERMINAL=" + info.ID, "AGENTLAND_HOST=" + executable, "AGENTLAND_HOST_STATE=" + state}) {
		t.Fatalf("environment marks %q", marked)
	}
	env := terminalEnvironmentWithID([]string{"A=1", "AGENTLAND_HOST=/x", "AGENTLAND_HOST_STATE=/y", "AGENTLAND_TERMINAL=term_outer", "B=2"}, "term_new", "/host", "/state.json")
	if !slices.Equal(env, []string{"A=1", "B=2", "AGENTLAND_TERMINAL=term_new", "AGENTLAND_HOST=/host", "AGENTLAND_HOST_STATE=/state.json"}) {
		t.Fatalf("environment %q", env)
	}
}

// The CLI's client (termrun.Continue) against a real host: the new
// terminal's ID alone on stdout, 5 where this terminal can't be continued, 1
// for any other refusal.
func TestContinueCommandAgainstTheHost(t *testing.T) {
	f := newRoutedFixture(t)
	host, path := localHost(t, f, "1.2.3")
	old := claudeTerminal(t, host, f.token, "Plan")
	state := filepath.Join(filepath.Dir(path), "state.json")
	run := func(version, from string) (int, string, string) {
		var stdout, stderr bytes.Buffer
		code := termrun.Continue(termrun.ContinueOptions{StatePath: state, Version: version, From: from, Prompt: "go on", Rows: 33, Cols: 99, Stdout: &stdout, Stderr: &stderr})
		return code, stdout.String(), stderr.String()
	}
	code, stdout, stderr := run("1.2.3", old.ID)
	if code != 0 || stdout != f.keeper.latest()+"\n" || stderr != "" || !strings.HasPrefix(stdout, "term_") {
		t.Fatalf("success: %d %q %q", code, stdout, stderr)
	}
	if spawn := f.keeper.lastSpawn(); spawn.Rows != 33 || spawn.Cols != 99 {
		t.Fatalf("size %d×%d", spawn.Rows, spawn.Cols)
	}
	for _, c := range []struct {
		version, from string
		code          int
	}{
		{"1.2.3", "", termrun.ContinueNotHere},
		{"1.2.3", "term_0123456789abcdef", termrun.ContinueNotHere},
		{"9.9.9", old.ID, termrun.ContinueFailed},
	} {
		code, stdout, stderr := run(c.version, c.from)
		if code != c.code || stdout != "" || stderr == "" {
			t.Errorf("%s from %q: %d %q %q", c.version, c.from, code, stdout, stderr)
		}
	}
	if _, stdout, stderr := run("9.9.9", old.ID); stdout != "" || !strings.Contains(stderr, "different versions") {
		t.Fatalf("the host's message: %q", stderr)
	}
}
