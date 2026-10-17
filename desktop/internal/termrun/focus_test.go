package termrun

import "testing"

func TestFocusEventsAreStrippedUnlessTheProgramAsked(t *testing.T) {
	var f focusFilter
	out, focusIn := f.input([]byte("a\x1b[Ib"))
	if string(out) != "ab" || !focusIn {
		t.Fatalf("focus-in: %q, %v", out, focusIn)
	}
	if out, focusIn := f.input([]byte("\x1b[Oc")); string(out) != "c" || focusIn {
		t.Fatalf("focus-out: %q, %v", out, focusIn)
	}
	// An escape split across reads is held for the next one.
	if out, focusIn := f.input([]byte("x\x1b[")); string(out) != "x" || focusIn {
		t.Fatalf("first half: %q, %v", out, focusIn)
	}
	if out, focusIn := f.input([]byte("I")); string(out) != "" || !focusIn {
		t.Fatalf("second half: %q, %v", out, focusIn)
	}
	if out, _ := f.input([]byte("\x1b")); string(out) != "" {
		t.Fatalf("a lone escape: %q", out)
	}
	if out, _ := f.input([]byte("[A")); string(out) != "\x1b[A" {
		t.Fatalf("an arrow key split after its escape: %q", out)
	}
	// A lone escape key goes on when no more input follows.
	f.input([]byte("\x1b"))
	if held := f.flush(); string(held) != "\x1b" {
		t.Fatalf("flushed %q", held)
	}
	if out, _ := f.input([]byte("\x1b\x1b[I")); string(out) != "\x1b" {
		t.Fatalf("escape, then focus-in: %q", out)
	}

	// The program asks for focus events, across reads: they pass through.
	f.output([]byte("hello \x1b[?10"))
	if f.wanted {
		t.Fatal("wanted before the sequence completed")
	}
	f.output([]byte("04h"))
	if !f.wanted {
		t.Fatal("not wanted after ESC[?1004h")
	}
	if out, focusIn := f.input([]byte("a\x1b[Ib\x1b[O")); string(out) != "a\x1b[Ib\x1b[O" || !focusIn {
		t.Fatalf("wanted: %q, %v", out, focusIn)
	}
	f.output([]byte("\x1b[?1004l"))
	if f.wanted || !f.disabled {
		t.Fatalf("after ESC[?1004l: wanted %v, disabled %v", f.wanted, f.disabled)
	}
	if out, _ := f.input([]byte("\x1b[I")); string(out) != "" {
		t.Fatalf("after the program stopped asking: %q", out)
	}
}

// Modes set together (ESC[?1004;2004h) count, and other modes don't.
func TestFocusModeInACombinedSequence(t *testing.T) {
	var f focusFilter
	f.output([]byte("\x1b[?2004h\x1b[?1h"))
	if f.wanted {
		t.Fatal("other modes turned focus on")
	}
	f.output([]byte("\x1b[?2004;1004h"))
	if !f.wanted {
		t.Fatal("a combined sequence did not turn focus on")
	}
	f.output([]byte("\x1b[?10040l\x1b[1004l"))
	if !f.wanted {
		t.Fatal("look-alike sequences turned focus off")
	}
	f.output([]byte("\x1b[?1004;25l"))
	if f.wanted {
		t.Fatal("a combined reset left focus on")
	}
}
