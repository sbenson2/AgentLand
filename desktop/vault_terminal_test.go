package host

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"time"
)

func vaultTestTerminalLog() archiveTerminalLogJSON {
	code := int64(0)
	return archiveTerminalLogJSON{ID: "tl_7hq2ab", ProjectID: "agentland-3f2a", Title: "shell", Program: "zsh",
		StartedAt: vaultAt(0), EndedAt: vaultAt(8 * time.Minute), Status: "exited", ExitCode: &code}
}

func vaultTestTerminalNames() vaultTerminalNames {
	return vaultTerminalNames{Base: "Terminals/AgentLand/2026-10-12 1432 shell (7hq2ab)", WorkspaceName: "AgentLand",
		WorkspaceFolder: "AgentLand", Location: vaultTestZone}
}

// vaultTerminalOutput renders output as a one-part terminal note and returns
// what follows its title.
func vaultTerminalOutput(t *testing.T, output string) string {
	t.Helper()
	model := newVaultTerminal()
	model.write([]byte(output))
	parts := model.render(vaultTestTerminalLog(), vaultTestTerminalNames())
	if len(parts) != 1 {
		t.Fatalf("%d parts", len(parts))
	}
	_, body, found := strings.Cut(parts[0].Text, "\n---\n# shell\n")
	if !found {
		t.Fatalf("no title:\n%s", parts[0].Text)
	}
	return body
}

func TestVaultTerminalCollapsesCarriageReturns(t *testing.T) {
	output := "Downloading  10%\rDownloading  55%\rDownloading 100%\r\n" +
		"12345\rab\r\n" +
		"spinner |\b/\b-\b\\\b \r\n" +
		"a\tb\tc\r\n" +
		"\x1b[1;31mred\x1b[0m done\r\n" +
		"\x1b[2K\rcleared\r\n" +
		"export API_TOKEN=hunter2hunter2\r\n"
	want := "\n```\nDownloading 100%\nab345\nspinner\na       b       c\nred done\ncleared\nexport API_TOKEN=…\n```\n"
	if body := vaultTerminalOutput(t, output); body != want {
		t.Fatalf("body\n%q\nwant\n%q", body, want)
	}
}

func TestVaultTerminalEditsWithinWindow(t *testing.T) {
	for _, test := range []struct{ name, output, want string }{
		{"progress lines redrawn in place", "a 10%\r\nb 10%\r\n\x1b[2Aa 90%\x1b[K\r\nb 90%\x1b[K\r\n", "a 90%\nb 90%"},
		{"erase below", "one\r\ntwo\r\nthree\r\n\x1b[2A\x1b[Jfour\r\n", "one\nfour"},
		{"columns", "abcdef\x1b[3Gx\x1b[2Cy\x1b[4Dz\r\n", "abzdey"},
		{"erase to the cursor", "hello world\x1b[6D\x1b[1K!\r\n", "     !world"},
		{"erase the line", "gone\x1b[2Kkept\r\n", "    kept"},
		{"cursor down stops at the last line", "x\r\ny\x1b[5A\x1b[9B!\r\n", "x\ny!"},
		{"clearing the screen keeps the transcript", "before\r\n\x1b[H\x1b[2J\x1b[3Jafter\r\n", "before\nafter"},
	} {
		want := "\n```\n" + test.want + "\n```\n"
		if body := vaultTerminalOutput(t, test.output); body != want {
			t.Errorf("%s: body\n%q\nwant\n%q", test.name, body, want)
		}
	}

	// Lines that left the 200-line window are final: the cursor stops at the
	// window's first line.
	var output, want strings.Builder
	for line := 1; line <= 250; line++ {
		fmt.Fprintf(&output, "line %d\r\n", line)
		switch {
		case line == 52:
			want.WriteString("TOP\n")
		default:
			fmt.Fprintf(&want, "line %d\n", line)
		}
	}
	output.WriteString("\x1b[300ATOP\x1b[K\x1b[300B\rend\r\n")
	want.WriteString("end\n")
	if body := vaultTerminalOutput(t, output.String()); body != "\n```\n"+want.String()+"```\n" {
		t.Fatalf("window edit\n%s", body)
	}
}

func TestVaultTerminalSummarizesAltScreen(t *testing.T) {
	output := "$ vim notes.txt\r\n" +
		"\x1b[?1049h\x1b[H\x1b[2J~\r\n~\r\n-- INSERT --\x1b[1;1Hsecret screen\x1b[?1049l" +
		"$ ls\r\na  b\r\n" +
		// Two full-screen runs with nothing between them read as one.
		"\x1b[?1049hfirst\x1b[?1049l\x1b[?47hsecond\x1b[?47l"
	want := "\n```\n$ vim notes.txt\n```\n\n_(full-screen program)_\n\n```\n$ ls\na  b\n```\n\n_(full-screen program)_\n"
	body := vaultTerminalOutput(t, output)
	if body != want {
		t.Fatalf("body\n%q\nwant\n%q", body, want)
	}
	for _, hidden := range []string{"INSERT", "secret", "first", "second"} {
		if strings.Contains(body, hidden) {
			t.Fatalf("full-screen output %q in the note", hidden)
		}
	}
}

func TestVaultTerminalOSC133Blocks(t *testing.T) {
	prompt := "\x1b]133;A\x07~/dev % \x1b]133;B\x07"
	output := "Last login: Mon Oct 12\r\n" +
		prompt + "ls\r\n\x1b]133;C\x07a.txt  b.txt\r\n\x1b]133;D;0\x07" +
		// zsh marks a missing final newline, then clears the mark.
		"%" + strings.Repeat(" ", 20) + "\r \r" +
		prompt + "gti\b\b\bgit status --short\r\n\x1b]133;C\x1b\\ M desktop/vault.go\r\n\x1b]133;D;1\x1b\\" +
		prompt + "export API_TOKEN=hunter2hunter2\r\n\x1b]133;C\x07\x1b]133;D;0\x07" +
		// An empty line runs nothing.
		prompt + "\r\n" + prompt + "vim x\r\n\x1b]133;C\x07\x1b[?1049hscreen\x1b[?1049l\x1b]133;D;0\x07" +
		prompt + "sleep 5\r\n\x1b]133;C\x07zzz\r\n" // still running
	want := "\n```\nLast login: Mon Oct 12\n```\n" +
		"\n```\n$ ls\na.txt  b.txt\n```\n\n_Exit code 0_\n" +
		"\n```\n$ git status --short\n M desktop/vault.go\n```\n\n_Exit code 1_\n" +
		"\n```\n$ export API_TOKEN=…\n```\n\n_Exit code 0_\n" +
		"\n```\n$ vim x\n```\n\n_(full-screen program)_\n\n_Exit code 0_\n" +
		"\n```\n$ sleep 5\nzzz\n```\n"
	body := vaultTerminalOutput(t, output)
	if body != want {
		t.Fatalf("body\n%s\nwant\n%s", body, want)
	}
	if strings.Contains(body, "~/dev") || strings.Contains(body, "%") {
		t.Fatalf("prompt text in the note:\n%s", body)
	}

	// Without marks the whole session is one block.
	plain := vaultTerminalOutput(t, "~/dev % ls\r\na.txt\r\n~/dev % false\r\n~/dev % ")
	if plain != "\n```\n~/dev % ls\na.txt\n~/dev % false\n~/dev %\n```\n" {
		t.Fatalf("unmarked session\n%q", plain)
	}

	model := newVaultTerminal()
	model.write([]byte(output))
	parts := model.render(vaultTestTerminalLog(), vaultTestTerminalNames())
	fields := vaultFrontmatter(t, parts[0].Text)
	for key, value := range map[string]string{
		"agentland-id": `"terminal/tl_7hq2ab"`, "type": `"terminal"`, "title": `"shell"`, "program": `"zsh"`,
		"workspace": `"[[Workspaces/AgentLand|AgentLand]]"`, "workspace-id": `"agentland-3f2a"`,
		"started": `"2026-10-12T14:32:05-07:00"`, "ended": `"2026-10-12T14:40:05-07:00"`, "status": `"exited"`,
		"exit-code": "0", "tags": `["agentland/terminal","agentland/workspace/agentland"]`,
	} {
		if fields[key] != value {
			t.Errorf("%s: %s, want %s", key, fields[key], value)
		}
	}
	if _, found := fields["parts"]; found || parts[0].Path != vaultTestTerminalNames().Base+".md" {
		t.Fatalf("one-part note %+v %s", fields, parts[0].Path)
	}
}

// vaultTerminalSession is output with every case the model handles: escapes,
// marks, full-screen runs, UTF-8 (valid, invalid and C1), CRs, a long title
// and more lines than the window holds.
func vaultTerminalSession() string {
	var session strings.Builder
	session.WriteString("Last login\r\n\x1b]0;" + strings.Repeat("title ", 1000) + "\x07")
	prompt := "\x1b]133;A\x1b\\~ % \x1b]133;B\x1b\\"
	for command := 0; command < 30; command++ {
		fmt.Fprintf(&session, "%secho %d héllo → 日本語 🎉\r\n\x1b]133;C\x07", prompt, command)
		for line := 0; line < 15; line++ {
			fmt.Fprintf(&session, "\x1b[3%dm%02d\x1b[0m 10%%\r%02d 100%% caf\xc3\xa9 \xff\xe2\x82 \xc2\x85 tab\tend\r\n", line%8, line, line)
		}
		session.WriteString("p 1\r\np 2\r\n\x1b[2Ap 3\x1b[K\r\n\x1b[J\x1b[12\x01x\x1bM\x1b(B")
		if command%7 == 3 {
			session.WriteString("\x1b[?1049hscreen\r\nmore\x1b[?1049l")
		}
		fmt.Fprintf(&session, "\x1b]133;D;%d\x07%%   \r \r", command%3)
	}
	// Then an unmarked shell inside, so the window scrolls.
	for line := 0; line < 260; line++ {
		fmt.Fprintf(&session, "row %03d\r\n", line)
	}
	session.WriteString("\x1b[250Atop\x1b[250B\rbottom €")
	return session.String()
}

func TestVaultTerminalChunkingMatchesOneShot(t *testing.T) {
	session := []byte(vaultTerminalSession())
	for _, limits := range []struct{ part, kept int }{{vaultPartLimit, vaultTerminalParts - 1}, {2 << 10, 3}} {
		oneShot := newVaultTerminal()
		oneShot.partLimit, oneShot.keptParts = limits.part, limits.kept
		oneShot.write(session)
		want := oneShot.render(vaultTestTerminalLog(), vaultTestTerminalNames())
		if limits.kept == 3 && len(want) != 4 {
			t.Fatalf("small limits give %d parts", len(want))
		}
		for seed := int64(1); seed <= 12; seed++ {
			random := rand.New(rand.NewSource(seed))
			chunked := newVaultTerminal()
			chunked.partLimit, chunked.keptParts = limits.part, limits.kept
			for rest := session; len(rest) > 0; {
				size := min(len(rest), 1+random.Intn(24))
				if random.Intn(10) == 0 {
					size = min(len(rest), 1+random.Intn(4096))
				}
				chunked.write(rest[:size])
				rest = rest[size:]
				if random.Intn(40) == 0 {
					chunked.render(vaultTestTerminalLog(), vaultTestTerminalNames()) // rendering changes nothing
				}
			}
			if chunked.offset() != int64(len(session)) {
				t.Fatalf("offset %d of %d", chunked.offset(), len(session))
			}
			got := chunked.render(vaultTestTerminalLog(), vaultTestTerminalNames())
			if fmt.Sprint(got) != fmt.Sprint(want) {
				for index := range min(len(got), len(want)) {
					if got[index].Text != want[index].Text {
						t.Fatalf("seed %d limits %v part %d differs:\n%s\n---- one shot ----\n%s", seed, limits, index+1, got[index].Text, want[index].Text)
					}
				}
				t.Fatalf("seed %d: %d parts, one shot %d", seed, len(got), len(want))
			}
		}
	}
}

func TestVaultTerminalCapsParts(t *testing.T) {
	if model := newVaultTerminal(); model.partLimit != vaultPartLimit || model.keptParts != 7 || vaultTerminalParts != 8 {
		t.Fatalf("limits %d %d", model.partLimit, model.keptParts)
	}
	lines := func(count int) string {
		var output strings.Builder
		for line := range count {
			fmt.Fprintf(&output, "line %04d %s\r\n", line, strings.Repeat("x", 50))
		}
		return output.String()
	}
	names := vaultTestTerminalNames()
	// line counts the lines of the form "line NNNN" in a part.
	numbers := func(text string) []int {
		found := []int{}
		for _, line := range strings.Split(text, "\n") {
			var number int
			if _, err := fmt.Sscanf(line, "line %04d", &number); err == nil {
				found = append(found, number)
			}
		}
		return found
	}

	// Under the cap every line is kept, in order, across linked parts.
	small := newVaultTerminal()
	small.partLimit = 1 << 10
	small.write([]byte(lines(40)))
	parts := small.render(vaultTestTerminalLog(), names)
	if len(parts) != 3 {
		t.Fatalf("%d parts for 40 lines", len(parts))
	}
	next := 0
	for index, part := range parts {
		for _, number := range numbers(part.Text) {
			if number != next {
				t.Fatalf("part %d has line %d, want %d", index+1, number, next)
			}
			next++
		}
		if strings.Contains(part.Text, "skipped") {
			t.Fatalf("part %d skips:\n%s", index+1, part.Text)
		}
	}
	if next != 40 {
		t.Fatalf("%d lines kept", next)
	}

	// Past it, the first seven parts are kept whole and the eighth holds the
	// newest lines after a note of what was skipped.
	large := newVaultTerminal()
	large.partLimit = 1 << 10
	large.write([]byte(lines(400)))
	parts = large.render(vaultTestTerminalLog(), names)
	if len(parts) != 8 {
		t.Fatalf("%d parts for 400 lines", len(parts))
	}
	next = 0
	for index, part := range parts[:7] {
		for _, number := range numbers(part.Text) {
			if number != next {
				t.Fatalf("part %d has line %d, want %d", index+1, number, next)
			}
			next++
		}
		if len(part.Text) > 2<<10 {
			t.Fatalf("part %d is %d bytes", index+1, len(part.Text))
		}
	}
	tail := numbers(parts[7].Text)
	if len(tail) == 0 || tail[len(tail)-1] != 399 || tail[0] <= next {
		t.Fatalf("tail lines %v after %d", tail, next)
	}
	for index, number := range tail {
		if number != tail[0]+index {
			t.Fatalf("tail lines %v", tail)
		}
	}
	if !strings.Contains(parts[7].Text, "\n_16 KB skipped; full log in AgentLand._\n") {
		t.Fatalf("tail\n%s", parts[7].Text)
	}
	for index, part := range parts {
		number := index + 1
		if want := vaultPartBase(names.Base, number) + ".md"; part.Path != want || part.Part != number {
			t.Fatalf("part %d at %s (%d)", number, part.Path, part.Part)
		}
		fields := vaultFrontmatter(t, part.Text)
		if fields["part"] != fmt.Sprint(number) || fields["parts"] != "8" {
			t.Fatalf("part %d frontmatter %v", number, fields)
		}
		if number > 1 && !strings.Contains(part.Text, fmt.Sprintf("# shell (part %d)\n\nContinued from [[%s|part %d]]\n", number, vaultPartBase(names.Base, number-1), number-1)) {
			t.Fatalf("part %d does not link back:\n%s", number, part.Text)
		}
		if number < 8 && !strings.HasSuffix(part.Text, fmt.Sprintf("\nContinued in [[%s|part %d]]\n", vaultPartBase(names.Base, number+1), number+1)) {
			t.Fatalf("part %d does not link on:\n%s", number, part.Text)
		}
	}
}
