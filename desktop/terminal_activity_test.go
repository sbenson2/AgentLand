package host

import (
	"testing"
	"time"
)

// Activity (terminal_activity.go): working, waiting for you, or quiet.

func TestActivityStatus(t *testing.T) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	output := func(data string, when time.Time) func(*terminalActivity) {
		return func(a *terminalActivity) { a.output([]byte(data), when) }
	}
	input := func(when time.Time) func(*terminalActivity) {
		return func(a *terminalActivity) { a.input(when) }
	}
	cases := []struct {
		name   string
		steps  []func(*terminalActivity)
		now    time.Time
		keeper time.Time
		want   string
	}{
		{"nothing yet", nil, at, time.Time{}, "quiet"},
		{"output just now", []func(*terminalActivity){output("building\r\n", at)}, at, time.Time{}, "working"},
		{"output 2 s ago", []func(*terminalActivity){output("building\r\n", at)}, at.Add(2 * time.Second), time.Time{}, "working"},
		{"output 4 s ago", []func(*terminalActivity){output("building\r\n", at)}, at.Add(4 * time.Second), time.Time{}, "quiet"},
		{"a bell", []func(*terminalActivity){output("\a", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"input after a bell", []func(*terminalActivity){output("\a", at), input(at.Add(time.Second))}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"a bell after input", []func(*terminalActivity){input(at), output("\a", at.Add(time.Second))}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"keeper input after a bell", []func(*terminalActivity){output("\a", at)}, at.Add(time.Second), at.Add(time.Second), "working"},
		{"keeper input before a bell", []func(*terminalActivity){output("\a", at)}, at.Add(time.Minute), at.Add(-time.Second), "waiting"},
		{"OSC 9 text", []func(*terminalActivity){output("\x1b]9;Build done\a", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"OSC 777 notify ended by ST", []func(*terminalActivity){output("\x1b]777;notify;Claude;Ready\x1b\\", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"OSC 0 title ended by BEL", []func(*terminalActivity){output("\x1b]0;title\a", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"OSC 777 that is not a notification", []func(*terminalActivity){output("\x1b]777;precmd\a", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"a kitty OSC 99 notification", []func(*terminalActivity){output("\x1b]99;i=1:d=0;Hello\x1b\\", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"OSC 999 is neither", []func(*terminalActivity){output("\x1b]999;Done\a", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"OSC 9 text that starts with a number", []func(*terminalActivity){output("\x1b]9;3 tests failed\a", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"OSC 9;9, the folder a prompt reports", []func(*terminalActivity){output("\x1b]9;9;/Users/me/code\x1b\\", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"OSC 9;1, a ConEmu sleep", []func(*terminalActivity){output("\x1b]9;1;500\a", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"OSC 9;12, a ConEmu prompt mark", []func(*terminalActivity){output("\x1b]9;12\x1b\\", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"an empty OSC 9", []func(*terminalActivity){output("\x1b]9;\a", at)}, at.Add(time.Minute), time.Time{}, "quiet"},
		{"CSI then a bell", []func(*terminalActivity){output("\x1b[2J\a", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
		{"an OSC cut short by another escape", []func(*terminalActivity){output("\x1b]0;title\x1b]9;Done\a", at)}, at.Add(time.Minute), time.Time{}, "waiting"},
	}
	for _, c := range cases {
		var activity terminalActivity
		for _, step := range c.steps {
			step(&activity)
		}
		if got := activity.status(c.now, c.keeper); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

// Claude Code and others report progress with OSC 9;4 while they work; that
// never reads as waiting for you.
func TestProgressOSC9IsNotANotification(t *testing.T) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	var activity terminalActivity
	activity.output([]byte("\x1b]9;4;1;50\a"), at)
	activity.output([]byte("\x1b]9;4;0;\x1b\\"), at)
	if got := activity.status(at.Add(time.Minute), time.Time{}); got == "waiting" {
		t.Fatalf("progress reads as %s", got)
	}
}

func TestANotificationSplitAcrossReadsCounts(t *testing.T) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	var activity terminalActivity
	activity.output([]byte("\x1b]9;Rea"), at)
	if got := activity.status(at.Add(time.Minute), time.Time{}); got == "waiting" {
		t.Fatalf("half a notification reads as %s", got)
	}
	activity.output([]byte("dy\a"), at.Add(time.Second))
	if got := activity.status(at.Add(time.Minute), time.Time{}); got != "waiting" {
		t.Fatalf("a notification split across reads reads as %s", got)
	}
	// So does a kitty notification split in three, its ST too.
	var kitty terminalActivity
	kitty.output([]byte("\x1b]9"), at)
	kitty.output([]byte("9;i=1:d=0;Hel"), at)
	kitty.output([]byte("lo\x1b"), at)
	if got := kitty.status(at.Add(time.Minute), time.Time{}); got == "waiting" {
		t.Fatalf("an unfinished kitty notification reads as %s", got)
	}
	kitty.output([]byte("\\"), at)
	if got := kitty.status(at.Add(time.Minute), time.Time{}); got != "waiting" {
		t.Fatalf("a kitty notification split across reads reads as %s", got)
	}
	// A progress report split the same way is still only progress.
	var progress terminalActivity
	progress.output([]byte("\x1b]9;"), at)
	progress.output([]byte("4;1;50\a"), at)
	if got := progress.status(at.Add(time.Minute), time.Time{}); got == "waiting" {
		t.Fatalf("split progress reads as %s", got)
	}
}

// After a host restart, the restore replays what the keeper holds: it only
// brings the scanner along, so the live end of a sequence the replay cut in
// two is never read as a bare bell.
func TestReplayedOutputPrimesTheActivityScanner(t *testing.T) {
	f := newRoutedFixture(t)
	replayed := map[string]string{"term_progress": "working \x1b]9;4;1;50", "term_title": "\x1b]0;Build", "term_bell": "\a"}
	for id, output := range replayed {
		f.add(id, routedRecord(f.folder(t, id)), output)
	}
	host := f.start(t)
	live := map[string]string{"term_progress": "\a", "term_title": "ing\a"}
	for id, output := range live {
		f.keeper.emit(id, output)
	}
	waitFor(t, "the live output", func() bool {
		for id, output := range live {
			w := request(t, host.Handler(), "GET", "/v1/terminal/output?terminalId="+id+"&cursor=0&wait=0", f.token, nil)
			if w.Code != 200 || decodeBody[terminalOutput](t, w).End != uint64(len(replayed[id])+len(output)) {
				return false
			}
		}
		return true
	})
	w := request(t, host.Handler(), "GET", "/v1/terminals/others", f.token, nil)
	list := decodeBody[struct {
		Terminals []sharedTerminal `json:"terminals"`
	}](t, w).Terminals
	activities := map[string]string{}
	for _, terminal := range list {
		activities[terminal.ID] = terminal.Activity
	}
	if w.Code != 200 || len(activities) != 3 {
		t.Fatalf("others: %d %s", w.Code, w.Body)
	}
	for id, activity := range activities {
		if activity == "waiting" {
			t.Errorf("%s reads as waiting", id)
		}
	}
}

// Typing in the agent's Terminal.app window reaches the program through the
// keeper, not the host: the keeper's input time answers the alert too.
func TestKeeperInputClearsWaiting(t *testing.T) {
	f := newSharedFixture(t)
	info := createTerminalFixture(t, f.host, f.a)
	f.keeper.emit(info.ID, "\a")
	waitFor(t, "the bell", func() bool { return readTerminal(t, f.host, f.b, info.ID, 0).Cursor == 1 })
	if got := f.others(t, f.b)[info.ID].Activity; got != "waiting" {
		t.Fatalf("after a bell: %s", got)
	}
	f.keeper.setLastInput(info.ID, f.clock.Now().Add(time.Second))
	if got := f.others(t, f.b)[info.ID].Activity; got != "quiet" && got != "working" {
		t.Fatalf("after input in the Terminal window: %s", got)
	}
}
