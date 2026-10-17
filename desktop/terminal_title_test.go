package host

import (
	"bytes"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCleanTerminalTitle(t *testing.T) {
	long := strings.Repeat("abcdefghij", 9) // 90 characters
	wide := strings.Repeat("é", 85)
	cases := []struct {
		name, raw, want string
		names           []string
	}{
		{"plain", "Fix the login redirect", "Fix the login redirect", nil},
		{"opencode session", "OC | Fix the login redirect", "Fix the login redirect", nil},
		{"opencode session cut by OpenCode", "OC | Terminal scrolling on iPhone does n…", "Terminal scrolling on iPhone does n…", nil},
		{"opencode home", "OpenCode", "", nil},
		{"opencode prefix only", "OC | ", "", nil},
		{"claude topic", "✳ Terminal scrolling", "Terminal scrolling", nil},
		{"claude other glyphs", "✻ Reading files", "Reading files", nil},
		{"claude glyph six", "✶ Writing tests", "Writing tests", nil},
		{"claude glyph cross", "✢ Planning", "Planning", nil},
		{"middle dot", "· Thinking", "Thinking", nil},
		{"asterisk", "* Compacting", "Compacting", nil},
		{"braille spinner", "⠙ Building", "Building", nil},
		{"braille run", "⠋⠙⠹ Deploying app", "Deploying app", nil},
		{"claude idle", "✳ Claude Code", "", nil},
		{"claude bare", "Claude", "", nil},
		{"claude lowercase", "claude code", "", nil},
		{"codex", "codex", "", nil},
		{"login shell", "-zsh", "", nil},
		{"bash", "bash", "", nil},
		{"login bash", "-bash", "", nil},
		{"sh", "sh", "", nil},
		{"fish", "fish", "", nil},
		{"login", "login", "", nil},
		{"shell prefix", "s@robins-mac-mini:~/Developer/AgentLand", "~/Developer/AgentLand", nil},
		{"shell prefix with space", "wes@mini: ~/src", "~/src", nil},
		{"shell prefix only", "s@mini:", "", nil},
		{"shell prefix and command", "s@mini: vim notes.md", "vim notes.md", nil},
		{"colon without user", "Error: build failed", "Error: build failed", nil},
		{"two at signs", "a@b@c: x", "a@b@c: x", nil},
		{"space before at", "see me@host: now", "see me@host: now", nil},
		{"control characters", "Fix\x01 the\x7f build\u0085now", "Fix the build now", nil},
		{"collapse white space", "  Fix \t the\n\nbuild  ", "Fix the build", nil},
		{"invalid utf8 dropped", "Fix\xff the build", "Fix the build", nil},
		{"letters kept", "日本語のタイトル", "日本語のタイトル", nil},
		{"digits kept", "2 files changed", "2 files changed", nil},
		{"emoji stripped", "🚀 Deploy", "Deploy", nil},
		{"only glyphs", "✳ ⠙ *", "", nil},
		{"empty", "", "", nil},
		{"spaces", "   ", "", nil},
		{"cap at 80", long, long[:79] + "…", nil},
		{"cap keeps characters whole", wide, strings.Repeat("é", 79) + "…", nil},
		{"cap trims trailing space", strings.Repeat("a", 78) + " bcd" + strings.Repeat("e", 10), strings.Repeat("a", 78) + "…", nil},
		{"exactly 80", strings.Repeat("x", 80), strings.Repeat("x", 80), nil},
		{"program label", "Shell", "", []string{"shell", "Shell", "Terminal"}},
		{"program name", "shell", "", []string{"shell", "Shell", "Terminal"}},
		{"creation title", "terminal", "", []string{"shell", "Shell", "Terminal"}},
		{"not generic", "Terminal scrolling", "Terminal scrolling", []string{"shell", "Shell", "Terminal"}},
		{"generic after prefix", "OC | OpenCode", "", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := cleanTerminalTitle(c.raw, c.names...); got != c.want {
				t.Fatalf("cleanTerminalTitle(%q) = %q, want %q", c.raw, got, c.want)
			}
		})
	}
}

// feedTitles feeds chunks in order and returns every title a chunk reported.
func feedTitles(tracker *terminalTitleTracker, chunks ...string) []string {
	var titles []string
	for _, chunk := range chunks {
		if title, changed := tracker.feed([]byte(chunk)); changed {
			titles = append(titles, title)
		}
	}
	return titles
}

func TestTerminalTitleTrackerReadsOSCTitles(t *testing.T) {
	cases := []struct {
		name   string
		chunks []string
		want   []string
	}{
		{"bel", []string{"\x1b]0;OC | Fix login\x07"}, []string{"Fix login"}},
		{"st", []string{"\x1b]2;✳ Fix login\x1b\\"}, []string{"Fix login"}},
		{"osc 1 icon name ignored", []string{"\x1b]1;Icon\x07"}, nil},
		{"other osc ignored", []string{"\x1b]52;c;SGVsbG8=\x07\x1b]7;file://mini/Users/s\x07\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\"}, nil},
		{"leading zero", []string{"\x1b]00;Title\x07"}, []string{"Title"}},
		{"no text", []string{"\x1b]2\x07"}, nil},
		{"empty title clears", []string{"\x1b]2;\x07"}, []string{""}},
		{"generic clears", []string{"\x1b]0;OpenCode\x07"}, []string{""}},
		{"split in the escape", []string{"out\x1b", "]0;Split\x07"}, []string{"Split"}},
		{"split after bracket", []string{"\x1b]", "2;Split\x07"}, []string{"Split"}},
		{"split in the number", []string{"\x1b]0", ";Split\x07"}, []string{"Split"}},
		{"split in the text", []string{"\x1b]0;Spl", "it title\x07"}, []string{"Split title"}},
		{"split before st", []string{"\x1b]0;Split\x1b", "\\"}, []string{"Split"}},
		{"split byte by byte", strings.Split("\x1b]0;One by one\x07", ""), []string{"One by one"}},
		{"split utf8", []string{"\x1b]0;Caf\xc3", "\xa9 time\x07"}, []string{"Café time"}},
		{"interleaved with output", []string{"\x1b[32mgreen\x1b[0m\r\nls\r\n\x1b]0;First\x07more output\x1b[2J\x1b]2;Second\x1b\\tail"}, []string{"Second"}},
		{"one per chunk", []string{"a\x1b]0;First\x07b", "c\x1b]0;Second\x07d"}, []string{"First", "Second"}},
		{"csi is not osc", []string{"\x1b[0;Not a title\x07"}, nil},
		{"esc esc bracket", []string{"\x1b\x1b]0;After double escape\x07"}, []string{"After double escape"}},
		{"esc abandons the title", []string{"\x1b]0;Lost\x1b[31mred\x07"}, nil},
		{"esc starts a new osc", []string{"\x1b]0;Lost\x1b]0;Kept\x07"}, []string{"Kept"}},
		{"can abandons", []string{"\x1b]0;Lost\x18 text\x07"}, nil},
		{"sub abandons", []string{"\x1b]0;Lost\x1a text\x07"}, nil},
		{"skip ends at st", []string{"\x1b]52;c;abc\x1b\\\x1b]0;Next\x07"}, []string{"Next"}},
		{"skip esc starts a new sequence", []string{"\x1b]52;c;abc\x1b]0;Next\x07"}, []string{"Next"}},
		{"bel in ground ignored", []string{"\x07bell\x1b]0;Title\x07"}, []string{"Title"}},
		{"brackets in text", []string{"values[i] = items[j]]\x1b[1m]\x1b]0;Title\x07[0]"}, []string{"Title"}},
		{"bracket after st is text", []string{"\x1b\\]0;Not a title\x07"}, nil},
		{"bracket starting a packet is text", []string{"plain", "]0;Not a title\x07"}, nil},
		{"bracket after a finished title", []string{"\x1b]0;One\x07]0;Not a title\x07"}, []string{"One"}},
		{"escape ends a packet", []string{"\x1b]0;One\x07\x1b", "[31mred"}, []string{"One"}},
		{"c1 osc not read", []string{"\xc2\x9d0;Not read\xc2\x9c"}, nil},
		{"long number skipped", []string{"\x1b]00000;Title\x07"}, nil},
		{"unterminated keeps nothing", []string{"\x1b]0;Never ends"}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var tracker terminalTitleTracker
			got := feedTitles(&tracker, c.chunks...)
			if len(got) != len(c.want) {
				t.Fatalf("titles %q, want %q", got, c.want)
			}
			for index := range got {
				if got[index] != c.want[index] {
					t.Fatalf("titles %q, want %q", got, c.want)
				}
			}
		})
	}
}

func TestTerminalTitleTrackerIgnoresOversizedTitles(t *testing.T) {
	var tracker terminalTitleTracker
	exact := strings.Repeat("a", terminalTitleLimit)
	if got := feedTitles(&tracker, "\x1b]0;"+exact+"\x07"); len(got) != 1 || got[0] != exact[:79]+"…" {
		t.Fatalf("a title of exactly %d bytes: %q", terminalTitleLimit, got)
	}
	over := strings.Repeat("b", terminalTitleLimit+1)
	if got := feedTitles(&tracker, "\x1b]0;"+over+"\x07"); len(got) != 0 {
		t.Fatalf("an oversized title was taken: %q", got)
	}
	// Split across chunks, and followed by a title that fits.
	if got := feedTitles(&tracker, "\x1b]2;"+over[:600], over[600:]+"\x1b\\", "\x1b]0;Fits\x07"); len(got) != 1 || got[0] != "Fits" {
		t.Fatalf("after an oversized title: %q", got)
	}
	// A huge payload of another OSC (a clipboard copy) is skipped whole.
	payload := strings.Repeat("QUJD", 1<<18)
	if got := feedTitles(&tracker, "\x1b]52;c;"+payload[:1<<19], payload[1<<19:]+"\x07\x1b]0;After\x07"); len(got) != 1 || got[0] != "After" {
		t.Fatalf("after a large OSC 52: %q", got)
	}
}

func TestTerminalTitleTrackerComparesWithItsProgram(t *testing.T) {
	tracker := terminalTitleTracker{names: terminalGenericNames("shell", "Terminal")}
	if got := feedTitles(&tracker, "\x1b]0;Terminal\x07", "\x1b]0;Shell\x07", "\x1b]0;s@mini:~\x07"); len(got) != 3 || got[0] != "" || got[1] != "" || got[2] != "~" {
		t.Fatalf("shell titles: %q", got)
	}
	tracker = terminalTitleTracker{names: terminalGenericNames("claude", "Fix login")}
	if got := feedTitles(&tracker, "\x1b]0;✳ Fix login\x07"); len(got) != 1 || got[0] != "" {
		t.Fatalf("the terminal's own title counts as generic: %q", got)
	}
}

// terminalStreamSample is terminal output as an agent's TUI and a shell write
// it: colors, cursor moves, text and a title now and then.
func terminalStreamSample(size int, titles bool) []byte {
	var sample bytes.Buffer
	for line := 0; sample.Len() < size; line++ {
		sample.WriteString("\x1b[38;5;244m")
		sample.WriteString("src/components/Terminal.swift:42: ")
		sample.WriteString("\x1b[0m\x1b[1mwarning\x1b[0m: the view reads its session while it renders\r\n")
		sample.WriteString("\x1b[2K\x1b[1G\x1b[?25l⠙ Building 42/180\x1b[?25h")
		if titles && line%64 == 0 {
			sample.WriteString("\x1b]0;✳ Fix terminal scrolling\x07")
		}
	}
	return sample.Bytes()[:size]
}

func TestTerminalTitleTrackerAllocatesNothingWithoutTitles(t *testing.T) {
	chunk := terminalStreamSample(64<<10, false)
	var tracker terminalTitleTracker
	allocations := testing.AllocsPerRun(20, func() {
		if _, changed := tracker.feed(chunk); changed {
			t.Fatal("a title in output that has none")
		}
	})
	if allocations != 0 {
		t.Fatalf("%.1f allocations per 64 KiB chunk without titles", allocations)
	}
	// Titles cost one string per chunk that completes any, whatever their count.
	titled := terminalStreamSample(64<<10, true)
	allocations = testing.AllocsPerRun(20, func() { tracker.feed(titled) })
	if allocations > 3 {
		t.Fatalf("%.1f allocations per 64 KiB chunk with titles", allocations)
	}
}

func TestTerminalTitleTrackerLargeStream(t *testing.T) {
	// 64 MiB in 64 KiB packets, the most one read returns, with a title at the end.
	stream := terminalStreamSample(64<<20, false)
	stream = append(stream, "\x1b]2;OC | Last title\x1b\\"...)
	var tracker terminalTitleTracker
	last, seen := "", 0
	for start := 0; start < len(stream); start += 64 << 10 {
		end := min(len(stream), start+64<<10)
		if title, changed := tracker.feed(stream[start:end]); changed {
			last, seen = title, seen+1
		}
	}
	if seen != 1 || last != "Last title" {
		t.Fatalf("titles seen %d, last %q", seen, last)
	}
}

// BenchmarkTerminalOutputCopy is what follow already does with every
// packet, for comparison with the title tracker below.
func BenchmarkTerminalOutputCopy(b *testing.B) {
	chunk := terminalStreamSample(64<<10, true)
	output := make([]byte, 0, 2<<20)
	b.SetBytes(int64(len(chunk)))
	b.ReportAllocs()
	for b.Loop() {
		output = append(output[:0], chunk...)
	}
}

func BenchmarkTerminalTitleTracker(b *testing.B) {
	chunk := terminalStreamSample(64<<10, true)
	var tracker terminalTitleTracker
	b.SetBytes(int64(len(chunk)))
	b.ReportAllocs()
	for b.Loop() {
		tracker.feed(chunk)
	}
}

func BenchmarkTerminalTitleTrackerNoTitles(b *testing.B) {
	chunk := terminalStreamSample(64<<10, false)
	var tracker terminalTitleTracker
	b.SetBytes(int64(len(chunk)))
	b.ReportAllocs()
	for b.Loop() {
		tracker.feed(chunk)
	}
}

// BenchmarkTerminalTitleTrackerBrackets is the tracker's worst ordinary
// case: colored code full of "]", each one checked.
func BenchmarkTerminalTitleTrackerBrackets(b *testing.B) {
	var sample bytes.Buffer
	for sample.Len() < 64<<10 {
		sample.WriteString("\x1b[36mfor\x1b[0m i := range items[1:] { out[i] = items[i][0] }\r\n")
	}
	chunk := sample.Bytes()[:64<<10]
	var tracker terminalTitleTracker
	b.SetBytes(int64(len(chunk)))
	b.ReportAllocs()
	for b.Loop() {
		tracker.feed(chunk)
	}
}

func listTerminalsFixture(t *testing.T, host *Host, token string) ([]TerminalInfo, string) {
	t.Helper()
	response := request(t, host.Handler(), "GET", "/v1/terminals?projectId=p1", token, nil)
	if response.Code != 200 {
		t.Fatalf("list terminals: %d %s", response.Code, response.Body.String())
	}
	var body struct{ Terminals []TerminalInfo }
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body.Terminals, response.Body.String()
}

func TestTerminalListShowsTheProgramTitle(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if response.Code != 201 || strings.Contains(response.Body.String(), "programTitle") || strings.Contains(response.Body.String(), "command") {
		t.Fatalf("create answer: %d %s", response.Code, response.Body.String())
	}
	var info TerminalInfo
	json.Unmarshal(response.Body.Bytes(), &info)
	// A title split across packets, among ordinary output.
	packets := []string{"\x1b[32mready\x1b[0m\r\n\x1b]0;OC | Fix", " the login redirect\x07$ "}
	for _, packet := range packets {
		fixture.emit(fixture.latest(), packet)
	}
	waitFor(t, "the program's title", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return len(list) == 1 && list[0].ProgramTitle == "Fix the login redirect"
	})
	// The output itself is unchanged.
	output := outputFixture(t, host, token, info.ID, 0)
	var read terminalOutput
	json.Unmarshal(output.Body.Bytes(), &read)
	if string(read.Data) != strings.Join(packets, "") {
		t.Fatalf("output changed: %q", read.Data)
	}
	// A new title replaces it; a generic one clears it.
	fixture.emit(fixture.latest(), "\x1b]2;✳ Terminal scrolling\x1b\\")
	waitFor(t, "the next title", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ProgramTitle == "Terminal scrolling"
	})
	fixture.emit(fixture.latest(), "\x1b]0;OpenCode\x07")
	waitFor(t, "the title cleared", func() bool {
		list, body := listTerminalsFixture(t, host, token)
		return list[0].ProgramTitle == "" && !strings.Contains(body, "programTitle")
	})
	// The terminal's own creation title counts as generic.
	fixture.emit(fixture.latest(), "\x1b]0;Fix it\x07\x1b]0;Shell\x07")
	fixture.emit(fixture.latest(), "done")
	waitFor(t, "the last packet", func() bool {
		var read terminalOutput
		json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &read)
		return strings.HasSuffix(string(read.Data), "done")
	})
	if list, _ := listTerminalsFixture(t, host, token); list[0].ProgramTitle != "" {
		t.Fatalf("the terminal's own name became its title: %q", list[0].ProgramTitle)
	}
}

func TestTerminalListReadsTheForegroundCommandAtMostEveryTwoSeconds(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	fixture.pid = 4242
	clock := &testClock{now: time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)}
	host.now = clock.Now
	var mu sync.Mutex
	var reads []int
	command := "vim notes.md"
	host.terminals.command = func(pid int, started time.Time, _ bool) string {
		mu.Lock()
		defer mu.Unlock()
		if started.IsZero() {
			t.Error("the terminal's start is unknown")
		}
		reads = append(reads, pid)
		return command
	}
	readCount := func() int { mu.Lock(); defer mu.Unlock(); return len(reads) }
	setCommand := func(value string) { mu.Lock(); command = value; mu.Unlock() }
	response := request(t, host.Handler(), "POST", "/v1/terminals", token, map[string]any{"projectId": "p1", "title": "Shell", "rows": 24, "cols": 80})
	if response.Code != 201 || strings.Contains(response.Body.String(), "command") || readCount() != 0 {
		t.Fatalf("the create answer read a command: %d %s reads=%d", response.Code, response.Body.String(), readCount())
	}
	if list, _ := listTerminalsFixture(t, host, token); list[0].Command != "vim notes.md" || readCount() != 1 || reads[0] != 4242 {
		t.Fatalf("first list: %+v reads=%v", list, reads)
	}
	// Within 2 s the last reading is answered.
	setCommand("less log.txt")
	clock.Advance(1999 * time.Millisecond)
	if list, _ := listTerminalsFixture(t, host, token); list[0].Command != "vim notes.md" || readCount() != 1 {
		t.Fatalf("list within 2 s: %+v reads=%d", list, readCount())
	}
	clock.Advance(time.Millisecond)
	if list, _ := listTerminalsFixture(t, host, token); list[0].Command != "less log.txt" || readCount() != 2 {
		t.Fatalf("list after 2 s: %+v reads=%d", list, readCount())
	}
	// The shell back in front: no command.
	setCommand("")
	clock.Advance(2 * time.Second)
	if list, body := listTerminalsFixture(t, host, token); list[0].Command != "" || strings.Contains(body, "command") || readCount() != 3 {
		t.Fatalf("shell in front: %s reads=%d", body, readCount())
	}
	// A title from the program: no command, and none is read.
	setCommand("vim notes.md")
	fixture.emit(fixture.latest(), "\x1b]0;✳ Editing notes\x07")
	waitFor(t, "the title", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ProgramTitle == "Editing notes"
	})
	clock.Advance(3 * time.Second)
	if list, _ := listTerminalsFixture(t, host, token); list[0].Command != "" || readCount() != 3 {
		t.Fatalf("with a title: %+v reads=%d", list, readCount())
	}
	// Cleared again, the command comes back.
	fixture.emit(fixture.latest(), "\x1b]0;\x07")
	waitFor(t, "the command again", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].ProgramTitle == "" && list[0].Command == "vim notes.md"
	})
	// An ended terminal lists no command and reads none.
	fixture.exit(fixture.latest(), 0)
	waitFor(t, "the terminal ended", func() bool {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0].Status == "exited"
	})
	before := readCount()
	clock.Advance(3 * time.Second)
	if list, _ := listTerminalsFixture(t, host, token); list[0].Command != "" || readCount() != before {
		t.Fatalf("an ended terminal: %+v reads=%d", list, readCount())
	}
}

func TestTerminalWithoutAProcessIDReadsNoCommand(t *testing.T) {
	host, _, token, _ := terminalTestHost(t, true)
	reads := 0
	host.terminals.command = func(int, time.Time, bool) string { reads++; return "sleep 30" }
	createTerminalFixture(t, host, token)
	if list, _ := listTerminalsFixture(t, host, token); list[0].Command != "" || reads != 0 {
		t.Fatalf("no process ID: %+v reads=%d", list, reads)
	}
}

// The program's title names the terminal until a device does. A device's name
// then stays: the program's later titles change only its programTitle, and
// only a title that replaced the description makes older names stale.
func TestAProgramsTitleNeverReplacesADevicesName(t *testing.T) {
	host, _, token, fixture := terminalTestHost(t, true)
	info := createTerminalFixture(t, host, token)
	cursor := func() uint64 {
		var read terminalOutput
		json.Unmarshal(outputFixture(t, host, token, info.ID, 0).Body.Bytes(), &read)
		return read.Cursor
	}
	name := func(title string, basedOn uint64) int {
		t.Helper()
		return request(t, host.Handler(), "POST", "/v1/terminal/title", token,
			map[string]any{"projectId": "p1", "terminalId": info.ID, "title": title, "basedOn": basedOn}).Code
	}
	listed := func() TerminalInfo {
		list, _ := listTerminalsFixture(t, host, token)
		return list[0]
	}
	fixture.emit(fixture.latest(), "ready\r\n")
	waitFor(t, "output", func() bool { return cursor() > 0 })
	before := cursor()
	fixture.emit(fixture.latest(), "\x1b]2;Fix the login redirect\x07")
	waitFor(t, "the program's title", func() bool { return listed().ContextTitle == "Fix the login redirect" })
	if got := listed(); got.ContextTitleSource != "program" {
		t.Fatalf("source %q", got.ContextTitleSource)
	}
	if code := name("Older device name", before); code != 409 {
		t.Fatalf("a name older than the program's title: %d", code)
	}
	named := cursor()
	if code := name("Repair Safari login", named); code != 200 {
		t.Fatalf("name: %d", code)
	}
	fixture.emit(fixture.latest(), "\x1b]2;Deploying\x07")
	waitFor(t, "the program's next title", func() bool { return listed().ProgramTitle == "Deploying" })
	if got := listed(); got.ContextTitle != "Repair Safari login" || got.ContextTitleSource != "device" {
		t.Fatalf("the program's title replaced the device's name: %+v", got)
	}
	// The title replaced nothing, so a name of the same output is still current.
	if code := name("Repair the Safari login", named); code != 200 {
		t.Fatalf("a device naming it again: %d", code)
	}
	if got := listed(); got.ContextTitle != "Repair the Safari login" || got.ProgramTitle != "Deploying" {
		t.Fatalf("listed %+v", got)
	}
}
