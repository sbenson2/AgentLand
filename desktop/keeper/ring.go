// Package keeper holds the terminal keeper's output ring and wire protocol.
package keeper

import "sync"

// RingSize is how much output a terminal's ring keeps, in the keeper and the host alike.
const RingSize = 2 << 20

// ring keeps the last len(buf) bytes of a terminal's output. Cursors count
// bytes since the terminal was spawned.
type ring struct {
	mu    sync.Mutex
	buf   []byte
	total uint64 // bytes ever written
}

func newRing(size int) *ring {
	return &ring{buf: make([]byte, size)}
}

func (r *ring) write(p []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	size := uint64(len(r.buf))
	if size == 0 {
		return
	}
	r.total += uint64(len(p))
	if uint64(len(p)) > size {
		p = p[uint64(len(p))-size:]
	}
	pos := int((r.total - uint64(len(p))) % size)
	n := copy(r.buf[pos:], p)
	copy(r.buf, p[n:])
}

// span returns the cursor of the oldest kept byte and of the next byte to be written.
func (r *ring) span() (start, end uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.spanLocked()
}

func (r *ring) spanLocked() (start, end uint64) {
	if size := uint64(len(r.buf)); r.total > size {
		return r.total - size, r.total
	}
	return 0, r.total
}

// readFrom copies up to max bytes starting at max(cursor, start). at is where
// the data begins. skipped is true when cursor fell behind start.
func (r *ring) readFrom(cursor uint64, max int) (data []byte, at uint64, skipped bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	start, end := r.spanLocked()
	if cursor < start {
		cursor, skipped = start, true
	}
	if cursor > end {
		cursor = end
	}
	n := end - cursor
	if max < 0 {
		max = 0
	}
	if n > uint64(max) {
		n = uint64(max)
	}
	data = make([]byte, n)
	size := uint64(len(r.buf))
	pos := int(cursor % size)
	c := copy(data, r.buf[pos:])
	copy(data[c:], r.buf)
	return data, cursor, skipped
}
