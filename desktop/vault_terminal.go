package host

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Terminal notes. A terminal's log is its raw output; the note shows what the
// terminal showed. Output passes through a line model: CR, LF, backspace, tab
// and the cursor and erase sequences (CSI A, B, C, D, G, K and J) edit the
// newest 200 lines, the window, and a line that leaves the window is final.
// Other escape sequences are dropped, as stripTerminalText drops them. A
// full-screen program (the alternate screen) becomes one
// "_(full-screen program)_" line. When the shell marks its prompts (OSC 133
// A, B, C and D), each command is a fenced block that starts with
// "$ command", followed by its exit code, and prompts are left out; otherwise
// the session is one fenced block. Text is masked (maskVaultSecrets).
//
// A note's parts are about 1 MiB, split between lines. Only the first seven
// parts and the newest 1 MiB are kept: the eighth part says how much was
// skipped (the archive keeps the whole log), so a model holds at most about
// 8 MiB however long the terminal runs.
//
// The model is fed the log's bytes in order, in chunks of any size, and
// renders its note at any point: the result never depends on where chunks
// were cut, and rendering changes nothing.

const (
	// vaultTerminalWindow is how many of the newest lines output can still
	// change.
	vaultTerminalWindow = 200
	// vaultTerminalParts is the most parts a terminal note has.
	vaultTerminalParts = 8
	// vaultTerminalLineLimit is the most characters a line keeps; a longer
	// one ends in "…".
	vaultTerminalLineLimit = 8 << 10
	// A CSI sequence's parameters and an OSC string's start are read up to
	// these lengths; the rest of a longer one is ignored.
	vaultTerminalParamLimit = 32
	vaultTerminalOSCLimit   = 128
	vaultFullScreen         = "_(full-screen program)_"
)

// vaultTerminalNames is what a terminal's note shows that its log does not
// hold.
type vaultTerminalNames struct {
	// Base is the note's path without ".md", fixed when it was first
	// written.
	Base string
	// WorkspaceName is the workspace's current name; WorkspaceFolder its
	// folder under Terminals/ and the name of its hub.
	WorkspaceName   string
	WorkspaceFolder string
	// Location is the zone times are shown in (time.Local when nil).
	Location *time.Location
}

// The escape parser's states, which follow terminalEscapeEnd's grammar.
const (
	termGround       = iota
	termEscape       // after ESC
	termIntermediate // after ESC and an intermediate byte
	termCSI          // in a control sequence
	termString       // in an OSC, DCS, SOS, PM or APC string
	termStringEscape // after ESC inside a string
)

// vaultTermSection is the part of a command a line belongs to, as the shell's
// OSC 133 marks say.
type vaultTermSection int

const (
	termPlain   vaultTermSection = iota // before any mark: shown
	termPrompt                          // after A: left out
	termCommand                         // after B: becomes the block's command
	termOutput                          // after C: shown
	termBetween                         // after D, until the next prompt: left out
)

// vaultTermItem is one final piece of a note: a line, the start of a command
// (its text), a command's end (its exit code, if known) or a full-screen
// program.
type vaultTermItem struct {
	kind   byte
	text   string
	masked bool
}

const (
	termItemLine byte = iota
	termItemCommand
	termItemExit
	termItemFullScreen
)

// size is about the bytes an item takes in a note.
func (item vaultTermItem) size() int {
	return len(item.text) + 1
}

type vaultTermLine struct {
	text []rune
	cut  bool // characters past vaultTerminalLineLimit were dropped
}

// vaultTermPages holds the final items: the first parts whole, then the
// newest items in the tail, which drops its oldest once it is full.
type vaultTermPages struct {
	parts    [][]vaultTermItem
	size     int // bytes in the last of parts
	tail     []vaultTermItem
	tailSize int
	skipped  int64
}

// vaultTerminal is a terminal's note, built from its output.
type vaultTerminal struct {
	partLimit int // bytes in a part
	keptParts int // parts kept whole before the tail

	state   int
	str     byte   // the kind of string: ']' is OSC
	params  []byte // a CSI's parameters or the start of an OSC string
	long    bool   // params were cut
	pending []byte // the first bytes of a UTF-8 character

	lines    []vaultTermLine // the window
	row, col int
	alt      bool

	section    vaultTermSection
	commandRow int // where the command starts, after mark B
	commandCol int

	pages vaultTermPages
	fed   int64
}

func newVaultTerminal() *vaultTerminal {
	return &vaultTerminal{partLimit: vaultPartLimit, keptParts: vaultTerminalParts - 1, lines: []vaultTermLine{{}}}
}

// offset is how many bytes of output the model has been fed.
func (t *vaultTerminal) offset() int64 {
	return t.fed
}

// write feeds the next bytes of output.
func (t *vaultTerminal) write(data []byte) {
	t.fed += int64(len(data))
	for _, b := range data {
		t.byte(b)
	}
}

func (t *vaultTerminal) byte(b byte) {
	switch t.state {
	case termEscape:
		t.state = termGround
		switch {
		case b == '[':
			t.state, t.params, t.long = termCSI, t.params[:0], false
		case b == ']' || b == 'P' || b == 'X' || b == '^' || b == '_':
			t.state, t.str, t.params, t.long = termString, b, t.params[:0], false
		case b >= 0x20 && b <= 0x2f:
			t.state = termIntermediate
		case b >= 0x30 && b <= 0x7e:
		default:
			t.ground(b) // the sequence ended before b
		}
	case termIntermediate:
		switch {
		case b >= 0x20 && b <= 0x2f:
		case b >= 0x30 && b <= 0x7e:
			t.state = termGround
		default:
			t.state = termGround
			t.ground(b)
		}
	case termCSI:
		switch {
		case b >= 0x40 && b <= 0x7e:
			t.state = termGround
			t.csi(b)
		case b >= 0x20 && b <= 0x3f:
			t.collect(b, vaultTerminalParamLimit)
		default:
			t.state = termGround
			t.ground(b)
		}
	case termString:
		switch b {
		case 0x07:
			t.state = termGround
			t.endString()
		case 0x1b:
			t.state = termStringEscape
		default:
			t.collect(b, vaultTerminalOSCLimit)
		}
	case termStringEscape:
		t.state = termGround
		t.endString()
		if b != '\\' {
			// The string ended before the ESC, which starts the next
			// sequence.
			t.state = termEscape
			t.byte(b)
		}
	default:
		t.ground(b)
	}
}

func (t *vaultTerminal) collect(b byte, limit int) {
	if len(t.params) < limit {
		t.params = append(t.params, b)
	} else {
		t.long = true
	}
}

// ground handles a byte outside escape sequences. As in stripTerminalText,
// invalid UTF-8 becomes U+FFFD and C0 controls other than those the model
// follows, DEL and C1 code points are dropped.
func (t *vaultTerminal) ground(b byte) {
	if len(t.pending) > 0 || b >= 0x80 {
		t.pending = append(t.pending, b)
		if !utf8.FullRune(t.pending) {
			return
		}
		r, size := utf8.DecodeRune(t.pending)
		var rest [utf8.UTFMax]byte
		count := copy(rest[:], t.pending[size:])
		t.pending = t.pending[:0]
		switch {
		case r == utf8.RuneError && size == 1:
			t.put(utf8.RuneError)
		case r >= 0x80 && r <= 0x9f:
		default:
			t.put(r)
		}
		// The bytes after an invalid one are read again.
		for _, next := range rest[:count] {
			t.byte(next)
		}
		return
	}
	switch {
	case b == 0x1b:
		t.state = termEscape
	case b == '\r':
		t.col = 0
	case b == '\n':
		t.lineFeed()
	case b == '\b':
		t.col = max(t.col-1, 0)
	case b == '\t':
		t.col = min((t.col/8+1)*8, vaultTerminalLineLimit)
	case b < 0x20 || b == 0x7f:
	default:
		t.put(rune(b))
	}
}

// put writes a character at the cursor, over what is there.
func (t *vaultTerminal) put(r rune) {
	if t.alt {
		return
	}
	line := &t.lines[t.row]
	switch {
	case t.col >= vaultTerminalLineLimit:
		line.cut = true
		return
	case t.col < len(line.text):
		line.text[t.col] = r
	default:
		for len(line.text) < t.col {
			line.text = append(line.text, ' ')
		}
		line.text = append(line.text, r)
	}
	t.col++
}

// lineFeed moves to the start of the next line (output reaches the log with
// its newlines as CR LF, so a lone LF is read the same way). Past the last
// line it adds one, and the window's first line becomes final once the
// window is full.
func (t *vaultTerminal) lineFeed() {
	if t.alt {
		return
	}
	t.row, t.col = t.row+1, 0
	if t.row < len(t.lines) {
		return
	}
	t.lines = append(t.lines, vaultTermLine{})
	if len(t.lines) > vaultTerminalWindow {
		t.commit(&t.pages, t.lines[0])
		t.lines[0] = vaultTermLine{}
		t.lines = t.lines[1:]
		t.row--
		if t.commandRow--; t.commandRow < 0 {
			t.commandRow, t.commandCol = 0, 0
		}
	}
}

// csi follows a control sequence: the cursor and erase sequences, and the
// alternate screen; the rest change nothing the note shows.
func (t *vaultTerminal) csi(final byte) {
	params := string(t.params)
	if t.long {
		return
	}
	if modes, private := strings.CutPrefix(params, "?"); private {
		if final == 'h' || final == 'l' {
			for _, mode := range strings.Split(modes, ";") {
				if mode == "1049" || mode == "1047" || mode == "47" {
					t.fullScreen(final == 'h')
					return
				}
			}
		}
		return
	}
	if t.alt || strings.Trim(params, "0123456789;") != "" {
		return
	}
	first, _, _ := strings.Cut(params, ";")
	n, _ := strconv.Atoi(first)
	n = min(max(n, 0), vaultTerminalLineLimit)
	move := max(n, 1)
	switch final {
	case 'A':
		t.row = max(t.row-move, 0)
	case 'B':
		t.row = min(t.row+move, len(t.lines)-1)
	case 'C':
		t.col = min(t.col+move, vaultTerminalLineLimit)
	case 'D':
		t.col = max(t.col-move, 0)
	case 'G':
		t.col = min(move-1, vaultTerminalLineLimit)
	case 'K':
		t.eraseLine(n)
	case 'J':
		// Erasing below the cursor drops the window's lines below it.
		// Clearing the whole screen keeps the transcript: what was on the
		// screen was output all the same.
		switch n {
		case 0:
			t.eraseLine(0)
			clear(t.lines[t.row+1:])
			t.lines = t.lines[:t.row+1]
		case 1:
			t.eraseLine(1)
		}
	}
}

func (t *vaultTerminal) eraseLine(mode int) {
	line := &t.lines[t.row]
	switch mode {
	case 0:
		if t.col < len(line.text) {
			line.text = line.text[:t.col]
		}
		if t.col < vaultTerminalLineLimit {
			line.cut = false
		}
	case 1:
		for index := 0; index <= t.col && index < len(line.text); index++ {
			line.text[index] = ' '
		}
	case 2:
		line.text, line.cut = line.text[:0], false
	}
}

// fullScreen enters or leaves the alternate screen. Its output is not read;
// entering it from shown output adds the full-screen line.
func (t *vaultTerminal) fullScreen(enter bool) {
	if !enter || t.alt {
		t.alt = enter
		return
	}
	t.alt = true
	if t.section == termPlain || t.section == termOutput {
		t.endSection()
		t.add(&t.pages, vaultTermItem{kind: termItemFullScreen})
	}
}

// endString follows an OSC 133 mark; other strings change nothing.
func (t *vaultTerminal) endString() {
	if t.str != ']' || t.alt {
		return
	}
	mark, found := strings.CutPrefix(string(t.params), "133;")
	if !found {
		return
	}
	fields := strings.Split(mark, ";")
	switch fields[0] {
	case "A": // a prompt starts
		t.endSection()
		t.section = termPrompt
	case "B": // the command line starts
		if t.section != termPrompt {
			t.endSection()
		}
		t.section, t.commandRow, t.commandCol = termCommand, t.row, t.col
	case "C": // the command runs
		if t.section == termOutput {
			return
		}
		command := ""
		if t.section == termCommand {
			command = t.commandText()
		}
		t.endSection()
		t.add(&t.pages, vaultTermItem{kind: termItemCommand, text: command})
		t.section = termOutput
	case "D": // the command finished, with its exit code if known
		output := t.section == termOutput
		t.endSection()
		if output {
			code := ""
			if len(fields) > 1 {
				if _, err := strconv.Atoi(fields[1]); err == nil {
					code = fields[1]
				}
			}
			t.add(&t.pages, vaultTermItem{kind: termItemExit, text: code})
		}
		t.section = termBetween
	}
}

// commandText is what was typed after mark B.
func (t *vaultTerminal) commandText() string {
	lines := []string{}
	for row := t.commandRow; row < len(t.lines); row++ {
		text := t.lines[row].text
		if row == t.commandRow {
			text = text[min(t.commandCol, len(text)):]
		}
		lines = append(lines, string(text))
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

// endSection makes the window final: its lines are shown or left out by the
// section they belong to, and a new window starts at the cursor's column.
func (t *vaultTerminal) endSection() {
	for _, line := range t.lines {
		t.commit(&t.pages, line)
	}
	clear(t.lines)
	t.lines, t.row = append(t.lines[:0], vaultTermLine{}), 0
}

// commit adds a final line to pages when its section is shown.
func (t *vaultTerminal) commit(pages *vaultTermPages, line vaultTermLine) {
	if t.section != termPlain && t.section != termOutput {
		return
	}
	text := strings.TrimRight(string(line.text), " ")
	if line.cut {
		text += "…"
	}
	t.add(pages, vaultTermItem{kind: termItemLine, text: text})
}

// add places an item: in the last kept part until it holds partLimit bytes,
// then in a new part, and once keptParts are full, in the tail. Items in kept
// parts are masked now; the tail's are masked when rendered, since most of
// them are dropped.
func (t *vaultTerminal) add(pages *vaultTermPages, item vaultTermItem) {
	if pages.tail == nil && (len(pages.parts) == 0 || pages.size < t.partLimit || len(pages.parts) < t.keptParts) {
		if len(pages.parts) == 0 || pages.size >= t.partLimit {
			pages.parts, pages.size = append(pages.parts, nil), 0
		}
		item = item.mask()
		last := len(pages.parts) - 1
		pages.parts[last] = append(pages.parts[last], item)
		pages.size += item.size()
		return
	}
	pages.tail = append(pages.tail, item)
	pages.tailSize += item.size()
	for pages.tailSize > t.partLimit && len(pages.tail) > 1 {
		pages.tailSize -= pages.tail[0].size()
		pages.skipped += int64(pages.tail[0].size())
		pages.tail[0] = vaultTermItem{}
		pages.tail = pages.tail[1:]
	}
}

func (item vaultTermItem) mask() vaultTermItem {
	if !item.masked && (item.kind == termItemLine || item.kind == termItemCommand) {
		item.text = maskVaultSecrets(item.text)
	}
	item.masked = true
	return item
}

// render renders the note as it stands: the final items, then the window's
// lines as if they were final.
func (t *vaultTerminal) render(log archiveTerminalLogJSON, names vaultTerminalNames) []notePart {
	pages := t.pages
	pages.parts = slices.Clone(pages.parts)
	if last := len(pages.parts) - 1; last >= 0 {
		pages.parts[last] = slices.Clip(pages.parts[last])
	}
	pages.tail = slices.Clip(pages.tail)
	for _, line := range t.lines {
		t.commit(&pages, line)
	}

	bodies := []string{}
	for _, items := range pages.parts {
		bodies = append(bodies, vaultTerminalBody(items))
	}
	if len(pages.tail) > 0 {
		body := vaultTerminalBody(pages.tail)
		if pages.skipped > 0 {
			body = fmt.Sprintf("\n_%s skipped; full log in AgentLand._\n", vaultSize(pages.skipped)) + body
		}
		bodies = append(bodies, body)
	}
	if len(bodies) == 0 {
		bodies = []string{""}
	}

	location := names.Location
	if location == nil {
		location = time.Local
	}
	title := vaultTerminalTitle(log)
	parts := make([]notePart, len(bodies))
	for index, body := range bodies {
		number := index + 1
		var out strings.Builder
		writeVaultFrontmatter(&out, vaultTerminalFields(log, names, location, title, number, len(bodies)))
		if number == 1 {
			fmt.Fprintf(&out, "# %s\n", title)
			if log.GapBytes > 0 {
				fmt.Fprintf(&out, "\n_%s of output was not recorded._\n", vaultSize(log.GapBytes))
			}
		} else {
			fmt.Fprintf(&out, "# %s (part %d)\n\nContinued from [[%s|part %d]]\n", title, number, vaultPartBase(names.Base, number-1), number-1)
		}
		out.WriteString(body)
		if number < len(bodies) {
			fmt.Fprintf(&out, "\nContinued in [[%s|part %d]]\n", vaultPartBase(names.Base, number+1), number+1)
		}
		parts[index] = notePart{Part: number, Path: vaultPartBase(names.Base, number) + ".md", Text: out.String()}
	}
	return parts
}

// vaultTerminalTitle is a terminal note's title: the terminal's title,
// else its program, else "Terminal".
func vaultTerminalTitle(log archiveTerminalLogJSON) string {
	title := vaultLine(maskVaultSecrets(log.Title))
	if title == "" {
		title = vaultLine(log.Program)
	}
	if title == "" {
		title = "Terminal"
	}
	return title
}

func vaultTerminalFields(log archiveTerminalLogJSON, names vaultTerminalNames, location *time.Location, title string, part, parts int) []vaultField {
	localTime := func(text string) string {
		t, err := time.Parse(archiveTimeLayout, text)
		if err != nil {
			return ""
		}
		return t.In(location).Format(time.RFC3339)
	}
	fields := []vaultField{{"agentland-id", "terminal/" + log.ID}, {"type", "terminal"}, {"title", title}}
	if program := vaultLine(log.Program); program != "" {
		fields = append(fields, vaultField{"program", program})
	}
	if names.WorkspaceFolder != "" {
		workspace := vaultLinkText(names.WorkspaceName)
		if workspace == "" {
			workspace = names.WorkspaceFolder
		}
		fields = append(fields, vaultField{"workspace", "[[Workspaces/" + names.WorkspaceFolder + "|" + workspace + "]]"})
	}
	fields = append(fields, vaultField{"workspace-id", log.ProjectID}, vaultField{"started", localTime(log.StartedAt)})
	if log.EndedAt != "" {
		fields = append(fields, vaultField{"ended", localTime(log.EndedAt)})
	}
	fields = append(fields, vaultField{"status", log.Status})
	if log.ExitCode != nil {
		fields = append(fields, vaultField{"exit-code", *log.ExitCode})
	}
	if parts > 1 {
		fields = append(fields, vaultField{"part", part}, vaultField{"parts", parts})
	}
	tags := []string{"agentland/terminal"}
	if tag := vaultTag(names.WorkspaceFolder); tag != "" {
		tags = append(tags, "agentland/workspace/"+tag)
	}
	return append(fields, vaultField{"tags", tags})
}

// vaultTerminalBody writes items as Markdown: lines in fenced blocks, a
// command's block starting with "$ command", exit codes and full-screen runs
// between blocks (two full-screen runs in a row read as one).
func vaultTerminalBody(items []vaultTermItem) string {
	var out strings.Builder
	fence := []string{}
	fullScreen := false
	flush := func() {
		text := strings.Trim(strings.Join(fence, "\n"), "\n")
		fence = fence[:0]
		if strings.TrimSpace(text) != "" {
			out.WriteString("\n" + markdownFence(text))
			fullScreen = false
		}
	}
	for _, item := range items {
		item = item.mask()
		switch item.kind {
		case termItemLine:
			fence = append(fence, item.text)
		case termItemCommand:
			flush()
			if item.text != "" {
				fence = append(fence, "$ "+item.text)
			}
		case termItemExit:
			flush()
			if item.text != "" {
				fmt.Fprintf(&out, "\n_Exit code %s_\n", item.text)
				fullScreen = false
			}
		case termItemFullScreen:
			flush()
			if !fullScreen {
				out.WriteString("\n" + vaultFullScreen + "\n")
				fullScreen = true
			}
		}
	}
	flush()
	return out.String()
}

// vaultSize shows a byte count in decimal units, as the Finder does.
func vaultSize(bytes int64) string {
	switch {
	case bytes >= 1_000_000:
		return fmt.Sprintf("%.1f MB", float64(bytes)/1e6)
	case bytes >= 1_000:
		return fmt.Sprintf("%d KB", (bytes+500)/1_000)
	}
	return fmt.Sprintf("%d bytes", bytes)
}
