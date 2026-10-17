package host

import (
	"bytes"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Terminal titles (docs/HOST-API.md "Terminals"): programs name their
// terminal with OSC 0 or OSC 2 (ESC ] 0 ; text BEL, or the same ended by ST,
// ESC \). terminalTitleTracker reads them from the output as it arrives,
// keeping its place across packets, and cleanTerminalTitle turns one into
// the programTitle clients show. The apps port cleanTerminalTitle's rules.

const (
	// terminalTitleLimit bounds one title's raw bytes; a longer one is
	// ignored and the previous title stays.
	terminalTitleLimit = 1024
	// terminalTitleCharacters bounds a cleaned title, "…" included.
	terminalTitleCharacters = 80
)

type terminalTitleState uint8

const (
	titleGround     terminalTitleState = iota
	titleEscape                        // ESC seen
	titleNumber                        // ESC ] and the digits of Ps so far
	titleText                          // collecting an OSC 0 or 2 title
	titleTextEscape                    // ESC inside a title: ST, or it is abandoned
	titleSkip                          // another OSC, or a title too long: skip to its end
	titleSkipEscape                    // ESC while skipping
)

// titleNumberDigits bounds Ps; an OSC with more digits is skipped.
const titleNumberDigits = 4

// terminalTitleTracker follows one terminal's output. Only the terminal's
// output reader uses it. It keeps fixed buffers, so reading output allocates
// nothing; a packet that completes titles costs one string for the last one.
type terminalTitleTracker struct {
	state     terminalTitleState
	number    int
	digits    int
	oversized bool
	length    int
	buffer    [terminalTitleLimit]byte
	lastLen   int
	last      [terminalTitleLimit]byte
	// names are what count as the terminal's own name besides the common
	// ones (its program, the program's label and its creation title).
	names []string
}

// titleStops are the bytes that end or abandon an OSC string: BEL, ESC, CAN
// and SUB.
const titleStops = "\x07\x1b\x18\x1a"

// oscIntroducer starts an operating system command; titleBracketMisses is
// how many "]" without an ESC before them a search passes over before it
// looks for the pair instead.
var oscIntroducer = []byte("\x1b]")

const titleBracketMisses = 16

// feed reads one packet of output. It returns the cleaned title of the last
// OSC 0 or 2 sequence the packet completed, and whether it completed one; a
// cleaned title may be empty, which clears the terminal's title.
func (t *terminalTitleTracker) feed(data []byte) (string, bool) {
	completed := false
	for i := 0; i < len(data); {
		switch t.state {
		case titleGround:
			// Outside a sequence only ESC ] matters. Terminal output is full
			// of other escapes (colors, cursor moves) but seldom holds "]",
			// so the search is for "]" with an ESC before it; output full of
			// "]" (code) switches to searching for the pair itself. The byte
			// before i is never such an ESC: every state that returns here
			// has just passed over a byte that is not one. An ESC that ends
			// the packet may start an OSC in the next.
			found, misses := -1, 0
			for from := i; from < len(data); {
				if misses == titleBracketMisses {
					if next := bytes.Index(data[from:], oscIntroducer); next >= 0 {
						found = from + next + 1
					}
					break
				}
				next := bytes.IndexByte(data[from:], ']')
				if next < 0 {
					break
				}
				if at := from + next; at > i && data[at-1] == 0x1b {
					found = at
					break
				}
				misses++
				from += next + 1
			}
			if found < 0 {
				if data[len(data)-1] == 0x1b {
					t.state = titleEscape
				}
				i = len(data)
				continue
			}
			i = found + 1
			t.state, t.number, t.digits = titleNumber, 0, 0
		case titleEscape:
			switch data[i] {
			case ']':
				t.state, t.number, t.digits = titleNumber, 0, 0
			case 0x1b:
				// Another ESC starts the sequence again.
			default:
				t.state = titleGround
			}
			i++
		case titleNumber:
			b := data[i]
			i++
			switch {
			case b >= '0' && b <= '9':
				if t.digits < titleNumberDigits {
					t.number = t.number*10 + int(b-'0')
				}
				t.digits++
			case b == ';':
				if t.digits > 0 && t.digits <= titleNumberDigits && (t.number == 0 || t.number == 2) {
					t.state, t.length, t.oversized = titleText, 0, false
				} else {
					t.state = titleSkip
				}
			case b == 0x1b:
				t.state = titleSkipEscape
			case b == 0x07 || b == 0x18 || b == 0x1a:
				t.state = titleGround
			default:
				t.state = titleSkip
			}
		case titleText:
			run := data[i:]
			end := bytes.IndexAny(run, titleStops)
			if end < 0 {
				end = len(run)
			}
			if !t.oversized {
				if t.length+end > terminalTitleLimit {
					t.oversized = true
				} else {
					t.length += copy(t.buffer[t.length:], run[:end])
				}
			}
			i += end
			if i == len(data) {
				continue
			}
			b := data[i]
			i++
			switch b {
			case 0x07:
				completed = t.finish() || completed
				t.state = titleGround
			case 0x1b:
				t.state = titleTextEscape
			default:
				// CAN or SUB abandons the title.
				t.state = titleGround
			}
		case titleTextEscape:
			if data[i] == '\\' {
				i++
				completed = t.finish() || completed
				t.state = titleGround
				continue
			}
			// Any other ESC abandons the title and starts a new sequence.
			t.state = titleEscape
		case titleSkip:
			end := bytes.IndexAny(data[i:], titleStops)
			if end < 0 {
				i = len(data)
				continue
			}
			i += end
			if data[i] == 0x1b {
				t.state = titleSkipEscape
			} else {
				t.state = titleGround
			}
			i++
		case titleSkipEscape:
			if data[i] == '\\' {
				i++
				t.state = titleGround
				continue
			}
			t.state = titleEscape
		}
	}
	if !completed {
		return "", false
	}
	return cleanTerminalTitle(string(t.last[:t.lastLen]), t.names...), true
}

// finish keeps a complete title unless it was too long.
func (t *terminalTitleTracker) finish() bool {
	if t.oversized {
		return false
	}
	t.lastLen = copy(t.last[:], t.buffer[:t.length])
	return true
}

// terminalProgramLabels are the names the apps give each terminal program.
var terminalProgramLabels = map[string]string{"shell": "Shell", "opencode": "OpenCode", "claude": "Claude Code", "codex": "Codex"}

// terminalGenericNames are a terminal's own names beside the common ones:
// its program, the program's label and the title it was created with.
func terminalGenericNames(program, title string) []string {
	names := []string{program}
	if label := terminalProgramLabels[program]; label != "" {
		names = append(names, label)
	}
	if title != "" {
		names = append(names, title)
	}
	return names
}

// terminalCommonNames are program names that say nothing about the work.
var terminalCommonNames = []string{"opencode", "claude", "claude code", "codex", "zsh", "-zsh", "bash", "-bash", "sh", "fish", "login"}

// cleanTerminalTitle turns a title a program set into what clients show, or
// "" when it says nothing but a program's name. names are the terminal's own
// names (terminalGenericNames). The rules, in order (characters are Unicode
// scalar values):
//
//  1. control characters are dropped, runs of white space become one space,
//     and the ends are trimmed;
//  2. a leading "OC | " (OpenCode inside a session) is removed, and a title
//     that is only "OC |" becomes empty;
//  3. a leading run of characters that are neither letters nor decimal
//     digits is removed (Claude Code's status glyphs, braille spinners);
//  4. a leading "user@host:" shell prefix is removed, keeping what follows;
//  5. a title over 80 characters is cut to 79, trailing white space removed,
//     and "…" added;
//  6. an empty title, or one that is only a program's name (compared
//     ignoring case), is no title.
func cleanTerminalTitle(raw string, names ...string) string {
	title := collapseTitleSpace(raw)
	if title == "OC |" {
		title = ""
	}
	title = strings.TrimPrefix(title, "OC | ")
	title = strings.TrimLeftFunc(title, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	if prefix := shellTitlePrefix(title); prefix > 0 {
		title = strings.TrimSpace(title[prefix:])
	}
	title = capCharacters(title, terminalTitleCharacters)
	if title == "" {
		return ""
	}
	for _, list := range [][]string{terminalCommonNames, names} {
		for _, name := range list {
			if strings.EqualFold(title, name) {
				return ""
			}
		}
	}
	return title
}

// collapseTitleSpace drops control characters (Unicode Cc) and invalid
// UTF-8, turns each run of white space into one space and trims the ends.
func collapseTitleSpace(raw string) string {
	var out strings.Builder
	out.Grow(len(raw))
	space := false
	for index := 0; index < len(raw); {
		r, size := utf8.DecodeRuneInString(raw[index:])
		index += size
		switch {
		case r == utf8.RuneError && size <= 1:
			continue
		case unicode.IsSpace(r):
			space = true
			continue
		case unicode.IsControl(r):
			continue
		}
		if space && out.Len() > 0 {
			out.WriteByte(' ')
		}
		space = false
		out.WriteRune(r)
	}
	return out.String()
}

// shellTitlePrefix returns the length of a leading "user@host:" prefix: one
// "@" between two non-empty parts, no spaces, then ":". It returns 0 when
// the title has none.
func shellTitlePrefix(title string) int {
	colon := strings.IndexByte(title, ':')
	if colon <= 0 {
		return 0
	}
	prefix := title[:colon]
	at := strings.IndexByte(prefix, '@')
	if at <= 0 || at == len(prefix)-1 || strings.ContainsAny(prefix[at+1:], "@") || strings.ContainsFunc(prefix, unicode.IsSpace) {
		return 0
	}
	return colon + 1
}

// capCharacters cuts text over limit characters to limit-1, removes the
// white space that ends it and adds "…".
func capCharacters(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	cut, count := 0, 0
	for index := range text {
		if count == limit-1 {
			cut = index
			break
		}
		count++
	}
	return strings.TrimRightFunc(text[:cut], unicode.IsSpace) + "…"
}
