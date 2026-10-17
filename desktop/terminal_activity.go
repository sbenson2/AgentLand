package host

import (
	"bytes"
	"time"
)

// Activity (GET /v1/terminals/others, terminal_shared.go): what a terminal is
// doing, for the devices that did not open it. The host notes when output and
// input last came, and when the program last asked for attention with a bell,
// an OSC 9 notification, a kitty OSC 99 notification or an OSC 777 notify.

// terminalWorkingWithin is how recent output must be for a terminal to read
// as working.
const terminalWorkingWithin = 3 * time.Second

// terminalActivity is a terminal's activity, under its entry's mu. lastInput
// is input sent through this host; the keeper also knows input that reached
// the program another way (its Terminal.app window), which status is given.
type terminalActivity struct {
	lastOutput, lastInput, alertAt time.Time
	scan                           activityScanner
}

// output notes output that arrived at now, and an alert in it.
func (a *terminalActivity) output(data []byte, now time.Time) {
	a.lastOutput = now
	if a.scan.feed(data) {
		a.alertAt = now
	}
}

// input notes input sent to the program at now.
func (a *terminalActivity) input(now time.Time) { a.lastInput = now }

// status is "waiting" (for you) when the program asked for attention after the
// latest input, the host's or keeperInput; else "working" while output came
// within terminalWorkingWithin of now; else "quiet".
func (a terminalActivity) status(now, keeperInput time.Time) string {
	input := a.lastInput
	if keeperInput.After(input) {
		input = keeperInput
	}
	switch {
	case a.alertAt.After(input):
		return "waiting"
	case !a.lastOutput.IsZero() && now.Sub(a.lastOutput) < terminalWorkingWithin:
		return "working"
	}
	return "quiet"
}

// activityScanner finds alerts in a terminal's output: a bell, an OSC 9
// notification with free text, a kitty OSC 99 notification or an OSC 777
// notify. An OSC 9 that names a ConEmu command by number (9;4 progress, which
// Claude Code and others send while they work, 9;9 the folder some prompts
// report, 9;1, 9;12…) is none. Its state carries across reads, so a sequence
// split between two reads counts; a restore's replay only moves it along
// (terminalEntry.receive). A BEL that ends an OSC is never a bell. It keeps
// only the first bytes of an OSC, however long.
type activityScanner struct {
	state   activityState
	num     [4]byte // the OSC's number
	numLen  int
	body    [8]byte // the start of the OSC's text, after its number
	bodyLen int
}

type activityState uint8

const (
	activityGround    activityState = iota
	activityEscape                  // after ESC
	activityOSC                     // after ESC ], in the OSC's number
	activityBody                    // in the OSC's text
	activityOSCEscape               // after ESC inside an OSC: ST, or another sequence
)

const (
	controlBEL = 0x07
	controlESC = 0x1b
)

// feed reads data and says whether it held an alert.
func (s *activityScanner) feed(data []byte) bool {
	alert := false
	for _, c := range data {
		if s.step(c) {
			alert = true
		}
	}
	return alert
}

func (s *activityScanner) step(c byte) bool {
	switch s.state {
	case activityGround:
		switch c {
		case controlBEL:
			return true
		case controlESC:
			s.state = activityEscape
		}
	case activityEscape:
		s.escape(c)
	case activityOSC:
		switch {
		case c >= '0' && c <= '9' && s.numLen < len(s.num):
			s.num[s.numLen] = c
			s.numLen++
		case c == ';':
			s.state = activityBody
		case c == controlBEL:
			return s.finish()
		case c == controlESC:
			s.state = activityOSCEscape
		default:
			s.state = activityBody
			s.keep(c)
		}
	case activityBody:
		switch c {
		case controlBEL:
			return s.finish()
		case controlESC:
			s.state = activityOSCEscape
		default:
			s.keep(c)
		}
	case activityOSCEscape:
		alert := s.finish()
		if c != '\\' {
			// Another sequence cut the OSC short: the byte begins it.
			s.escape(c)
		}
		return alert
	}
	return false
}

// escape reads the byte after an ESC: ] begins an OSC, anything else returns
// to plain output.
func (s *activityScanner) escape(c byte) {
	if c == ']' {
		s.state, s.numLen, s.bodyLen = activityOSC, 0, 0
		return
	}
	s.state = activityGround
}

// keep keeps an OSC's text while it holds fewer than len(body) bytes.
func (s *activityScanner) keep(c byte) {
	if s.bodyLen < len(s.body) {
		s.body[s.bodyLen] = c
		s.bodyLen++
	}
}

// finish ends an OSC and says whether it was a notification.
func (s *activityScanner) finish() bool {
	s.state = activityGround
	number, body := s.num[:s.numLen], s.body[:s.bodyLen]
	switch {
	case bytes.Equal(number, []byte("9")):
		return len(body) > 0 && !conEmuCommand(body)
	case bytes.Equal(number, []byte("99")):
		return true
	case bytes.Equal(number, []byte("777")):
		return bytes.HasPrefix(body, []byte("notify;"))
	}
	return false
}

// conEmuCommand is whether an OSC 9's text (as far as it was kept) starts
// with a ConEmu command's number: digits up to a ';' or its end, as in 9;4;1;50
// or 9;12.
func conEmuCommand(body []byte) bool {
	digits := 0
	for digits < len(body) && body[digits] >= '0' && body[digits] <= '9' {
		digits++
	}
	return digits > 0 && (digits == len(body) || body[digits] == ';')
}
