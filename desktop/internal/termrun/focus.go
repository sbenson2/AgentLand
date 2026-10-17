package termrun

import (
	"bytes"
	"slices"
)

// The window's focus events, and the mode that asks for them (DEC private
// mode 1004).
const (
	focusInEvent  = "\x1b[I"
	focusOutEvent = "\x1b[O"
	focusOn       = "\x1b[?1004h"
	focusOff      = "\x1b[?1004l"
)

// maxModeSequence bounds a mode sequence carried from one read of output to
// the next. A longer one is not a mode the filter tracks.
const maxModeSequence = 64

// focusFilter keeps focus reporting on in the CLI's own window while passing
// the window's focus events to the program only when the program asked for
// them itself. The CLI turns reporting on so that it learns when the person
// is back at the window, and sends the window's size then (the size rule:
// the most recently active viewer wins).
//
// input sees what the window types; output sees what the program writes.
// They are for one goroutine each, under the caller's lock.
type focusFilter struct {
	// wanted says the program turned focus reporting on itself.
	wanted bool
	// pending is a partial escape at the end of a read of input, held for
	// the next read (or flush).
	pending []byte
	// tail is a partial mode sequence at the end of a read of output.
	tail []byte
	// disabled says a sequence turning reporting off passed through to the
	// window since the caller last cleared it: the window stopped
	// reporting, so the CLI turns it on again.
	disabled bool
}

// input strips the focus events ESC[I and ESC[O from what the window typed
// unless the program wants them, and reports a focus-in. An ESC or ESC[ that
// ends p is held for the next read, since it may begin an event; flush gives
// it up when no more input follows.
func (f *focusFilter) input(p []byte) (out []byte, focusIn bool) {
	data := p
	if len(f.pending) > 0 {
		data = append(f.pending, p...)
		f.pending = nil
	}
	if f.wanted {
		return slices.Clone(data), bytes.Contains(data, []byte(focusInEvent))
	}
	out = make([]byte, 0, len(data))
	for len(data) > 0 {
		i := bytes.IndexByte(data, 0x1b)
		if i < 0 {
			out = append(out, data...)
			break
		}
		out = append(out, data[:i]...)
		rest := data[i:]
		switch {
		case bytes.HasPrefix(rest, []byte(focusInEvent)):
			focusIn = true
			data = rest[len(focusInEvent):]
		case bytes.HasPrefix(rest, []byte(focusOutEvent)):
			data = rest[len(focusOutEvent):]
		case len(rest) == 1 || (len(rest) == 2 && rest[1] == '['):
			f.pending = slices.Clone(rest)
			data = nil
		default:
			out = append(out, 0x1b)
			data = rest[1:]
		}
	}
	return out, focusIn
}

// flush gives up the partial escape input held: no more input followed it,
// so it is the person's own key.
func (f *focusFilter) flush() []byte {
	held := f.pending
	f.pending = nil
	return held
}

// output follows the program's own focus mode in what it writes, across
// reads: CSI ? … 1004 … h turns it on, and CSI ? … 1004 … l off.
func (f *focusFilter) output(p []byte) {
	data := p
	if len(f.tail) > 0 {
		data = append(f.tail, p...)
		f.tail = nil
	}
	for {
		i := bytes.IndexByte(data, 0x1b)
		if i < 0 {
			return
		}
		data = data[i:]
		n, complete := f.mode(data)
		if !complete {
			if len(data) <= maxModeSequence {
				f.tail = slices.Clone(data)
			}
			return
		}
		data = data[n:]
	}
}

// mode reads the sequence at the start of b, which starts with ESC. It
// returns how many bytes it took, or complete false when b ends inside a
// mode sequence.
func (f *focusFilter) mode(b []byte) (n int, complete bool) {
	if len(b) < 3 {
		if len(b) == 2 && b[1] != '[' {
			return 1, true
		}
		return 0, false
	}
	if b[1] != '[' || b[2] != '?' {
		return 1, true
	}
	end := 3
	for end < len(b) && (b[end] == ';' || ('0' <= b[end] && b[end] <= '9')) {
		end++
	}
	if end == len(b) {
		return 0, false
	}
	switch b[end] {
	case 'h', 'l':
	default:
		return end, true
	}
	for _, param := range bytes.Split(b[3:end], []byte{';'}) {
		if string(param) == "1004" {
			f.wanted = b[end] == 'h'
			if !f.wanted {
				f.disabled = true
			}
		}
	}
	return end + 1, true
}
