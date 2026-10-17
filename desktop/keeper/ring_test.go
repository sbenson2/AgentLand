package keeper

import (
	"bytes"
	"testing"
)

func TestRingKeepsTheLastTwoMiB(t *testing.T) {
	pattern := make([]byte, 3<<20)
	for i := range pattern {
		pattern[i] = byte(i * 7 >> 3)
	}
	r := newRing(RingSize)
	for off := 0; off < len(pattern); off += 100000 {
		end := min(off+100000, len(pattern))
		r.write(pattern[off:end])
	}
	if s, e := r.span(); s != 1<<20 || e != 3<<20 {
		t.Fatalf("span = (%d, %d)", s, e)
	}
	data, at, skipped := r.readFrom(0, 64<<10)
	if !skipped || at != 1<<20 {
		t.Fatalf("skipped=%v at=%d", skipped, at)
	}
	if !bytes.Equal(data, pattern[1<<20:1<<20+64<<10]) {
		t.Fatal("data differs from the pattern")
	}
}

func TestRingReadsFromACursorInside(t *testing.T) {
	r := newRing(RingSize)
	r.write([]byte("hello world"))
	data, at, skipped := r.readFrom(6, 100)
	if string(data) != "world" || at != 6 || skipped {
		t.Fatalf("got %q %d %v", data, at, skipped)
	}
	data, _, skipped = r.readFrom(11, 100)
	if len(data) != 0 || skipped {
		t.Fatalf("got %q %v", data, skipped)
	}
}

func TestRingOneWriteLargerThanTheRing(t *testing.T) {
	r := newRing(8)
	r.write([]byte("0123456789abcdef"))
	if s, e := r.span(); s != 8 || e != 16 {
		t.Fatalf("span = (%d, %d)", s, e)
	}
	data, at, skipped := r.readFrom(0, 100)
	if string(data) != "89abcdef" || at != 8 || !skipped {
		t.Fatalf("got %q %d %v", data, at, skipped)
	}
}
