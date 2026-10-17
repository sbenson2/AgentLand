//go:build unix

package keeper

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

// logLimit is the size at which the log moves to path + ".1", replacing it.
var logLimit int64 = 5 << 20

// openLog opens the keeper's lifecycle log for appending: 0600, never through
// a symlink, and only a regular file of this user. An empty path discards.
func openLog(path string) (io.WriteCloser, error) {
	if path == "" {
		return discardLog{}, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("terminal keeper log: %w", err)
	}
	l := &lifecycleLog{path: path, limit: logLimit}
	if err := l.open(); err != nil {
		return nil, err
	}
	return l, nil
}

type discardLog struct{}

func (discardLog) Write(p []byte) (int, error) { return len(p), nil }
func (discardLog) Close() error                { return nil }

// lifecycleLog appends lines to a file and rotates it at limit. Each Write is
// one line, written whole.
type lifecycleLog struct {
	mu    sync.Mutex
	path  string
	limit int64
	file  *os.File
	size  int64
}

func (l *lifecycleLog) open() error {
	f, err := os.OpenFile(l.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return fmt.Errorf("terminal keeper log: %w", err)
	}
	info, err := f.Stat()
	if err == nil {
		err = checkOwnFile(info)
	}
	if err == nil {
		err = f.Chmod(0o600)
	}
	if err != nil {
		f.Close()
		return fmt.Errorf("terminal keeper log %s: %w", l.path, err)
	}
	l.file, l.size = f, info.Size()
	return nil
}

func (l *lifecycleLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return 0, os.ErrClosed
	}
	if l.size > 0 && l.size+int64(len(p)) > l.limit {
		l.file.Close()
		l.file = nil
		// A failed rename keeps the old lines in the reopened file.
		_ = os.Rename(l.path, l.path+".1")
		if err := l.open(); err != nil {
			return 0, err
		}
	}
	n, err := l.file.Write(p)
	l.size += int64(n)
	return n, err
}

func (l *lifecycleLog) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}
