//go:build !windows

package host

import (
	"golang.org/x/sys/unix"
	"path/filepath"
	"testing"
	"time"
)

func TestFileReadRejectsNamedPipeWithoutBlocking(t *testing.T) {
	h, st, _ := testHost(t)
	token := paired(t, h, st)
	if err := unix.Mkfifo(filepath.Join(mustProject(t, st).Directory, "pipe"), 0600); err != nil {
		t.Fatal(err)
	}
	result := make(chan int, 1)
	go func() { result <- request(t, h.Handler(), "GET", "/v1/file?projectId=p1&path=pipe", token, nil).Code }()
	select {
	case code := <-result:
		if code != 415 {
			t.Fatal(code)
		}
	case <-time.After(300 * time.Millisecond):
		t.Fatal("reading a named pipe blocked the request")
	}
}
