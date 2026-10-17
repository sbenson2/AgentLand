package host

import (
	"bufio"
	"errors"
	"io"
	"sync"
)

// Bounds for reading Codex output. A line is one JSON-RPC message or one exec
// event; a longer line is skipped, never buffered whole.
const (
	codexLineLimit  = 8 << 20
	codexStderrRing = 64 << 10
)

// codexLineReader reads newline-terminated lines of at most limit bytes. A
// longer line is skipped to its end and reported by size, so one huge event
// neither stops the stream nor holds unbounded memory.
type codexLineReader struct {
	reader *bufio.Reader
	limit  int
	buffer []byte
	err    error
}

func newCodexLineReader(source io.Reader, limit int) *codexLineReader {
	return &codexLineReader{reader: bufio.NewReaderSize(source, 64<<10), limit: limit}
}

// next returns the next line without its line ending. A skipped line returns
// a nil line and its size. The line is valid until the next call.
func (r *codexLineReader) next() ([]byte, int, error) {
	if r.err != nil {
		return nil, 0, r.err
	}
	if cap(r.buffer) > 1<<20 {
		// Do not keep a large line's buffer between lines.
		r.buffer = nil
	}
	r.buffer = r.buffer[:0]
	skipped := 0
	for {
		chunk, err := r.reader.ReadSlice('\n')
		if skipped > 0 || len(r.buffer)+len(chunk) > r.limit+2 {
			if skipped == 0 {
				skipped = len(r.buffer)
				r.buffer = r.buffer[:0]
			}
			skipped += len(chunk)
		} else {
			r.buffer = append(r.buffer, chunk...)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if err != nil {
			// A final line without a newline is returned before the error.
			r.err = err
			if skipped > 0 {
				return nil, skipped, nil
			}
			if len(r.buffer) > 0 {
				return trimLineEnd(r.buffer), 0, nil
			}
			return nil, 0, err
		}
		if skipped > 0 {
			return nil, skipped, nil
		}
		return trimLineEnd(r.buffer), 0, nil
	}
}

func trimLineEnd(line []byte) []byte {
	if n := len(line); n > 0 && line[n-1] == '\n' {
		line = line[:n-1]
	}
	if n := len(line); n > 0 && line[n-1] == '\r' {
		line = line[:n-1]
	}
	return line
}

// codexRing keeps the last size bytes written to it: a process's stderr, for
// diagnostics only.
type codexRing struct {
	mu   sync.Mutex
	size int
	data []byte
}

func newCodexRing(size int) *codexRing { return &codexRing{size: size} }

func (r *codexRing) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(p) >= r.size {
		r.data = append(r.data[:0], p[len(p)-r.size:]...)
		return len(p), nil
	}
	r.data = append(r.data, p...)
	if len(r.data) > 2*r.size {
		r.data = append(r.data[:0], r.data[len(r.data)-r.size:]...)
	}
	return len(p), nil
}

// tail returns the retained bytes, at most size.
func (r *codexRing) tail() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.data) > r.size {
		return string(r.data[len(r.data)-r.size:])
	}
	return string(r.data)
}
