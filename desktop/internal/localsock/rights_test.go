//go:build darwin || linux

package localsock

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// unixPair returns the two ends of a connected Unix socket.
func unixPair(t *testing.T) (client, server *net.UnixConn) {
	t.Helper()
	addr := &net.UnixAddr{Name: filepath.Join(tempFolder(t), "r.sock"), Net: "unix"}
	listener, err := net.ListenUnix("unix", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err = net.DialUnix("unix", nil, addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	server, err = listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { server.Close() })
	return client, server
}

func TestAFileCrossesTheSocket(t *testing.T) {
	client, server := unixPair(t)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	payload := bytes.Repeat([]byte("frame-"), 1000)
	if err := SendWithFile(client, payload, w); err != nil {
		t.Fatal(err)
	}
	w.Close() // only the received copy is left

	reader := NewRightsReader(server)
	defer reader.Discard()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(reader, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("the payload changed on the way")
	}
	received := reader.TakeFile("pipe")
	if received == nil {
		t.Fatal("no file arrived")
	}
	if again := reader.TakeFile("pipe"); again != nil {
		t.Fatal("one file was taken twice")
	}
	if _, err := received.Write([]byte("ok")); err != nil {
		t.Fatal(err)
	}
	received.Close()
	all, err := io.ReadAll(r)
	if err != nil || string(all) != "ok" {
		t.Fatalf("read %q, %v", all, err)
	}
}

// A descriptor nobody takes is closed by Discard: the pipe's last write end
// goes, so its read end sees EOF.
func TestUntakenFilesAreClosed(t *testing.T) {
	client, server := unixPair(t)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if err := SendWithFile(client, []byte("x"), w); err != nil {
		t.Fatal(err)
	}
	w.Close()

	reader := NewRightsReader(server)
	if _, err := io.ReadFull(reader, make([]byte, 1)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 1)
	_ = r.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	if _, err := r.Read(buf); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("before Discard the received copy should keep the pipe open: %v", err)
	}
	reader.Discard()
	_ = r.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := r.Read(buf); err != io.EOF {
		t.Fatalf("after Discard: %v, want EOF", err)
	}
	if f := reader.TakeFile("pipe"); f != nil {
		t.Fatal("a discarded file was taken")
	}
}

// openFDs counts this process's open descriptors.
func openFDs() int {
	n := 0
	for fd := 0; fd < 4096; fd++ {
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err == nil {
			n++
		}
	}
	return n
}

// sendCopies sends count copies of w's descriptor in one message, then closes
// w, so only the copies in flight hold the pipe open.
func sendCopies(t *testing.T, conn *net.UnixConn, w *os.File, count int) {
	t.Helper()
	fds := make([]int, count)
	raw, err := w.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var sendErr error
	if err := raw.Control(func(fd uintptr) {
		for i := range fds {
			fds[i] = int(fd)
		}
		_, _, sendErr = conn.WriteMsgUnix([]byte("x"), unix.UnixRights(fds...), nil)
	}); err != nil {
		t.Fatal(err)
	}
	if sendErr != nil {
		t.Fatal(sendErr)
	}
	w.Close()
}

// A read the kernel cut short is an error, and every descriptor it brought
// whose number arrived is closed. macOS also installs the ones that did not
// fit, without their numbers; nothing can close those, which is why the real
// reader's buffer takes more than one message can carry.
func TestACutShortReadClosesWhatArrived(t *testing.T) {
	const capacity, sent = 4, 6
	client, server := unixPair(t)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	sendCopies(t, client, w, sent)
	before := openFDs()
	reader := newRightsReader(server, capacity)
	if _, err := reader.Read(make([]byte, 1)); err == nil {
		t.Fatal("a cut-short read was not an error")
	}
	if left := openFDs() - before; left > sent-capacity {
		t.Fatalf("%d received descriptors are still open; at most the %d that did not fit may be", left, sent-capacity)
	}
	if f := reader.TakeFile("pipe"); f != nil {
		t.Fatal("a file from a cut-short read was kept")
	}
}

func TestTheMostDescriptorsOneMessageCarriesFit(t *testing.T) {
	const sent = 253 // Linux's most; macOS takes 254
	client, server := unixPair(t)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	sendCopies(t, client, w, sent)
	before := openFDs()
	reader := NewRightsReader(server)
	if _, err := reader.Read(make([]byte, 1)); err != nil {
		t.Fatal(err)
	}
	if got := openFDs() - before; got != sent {
		t.Fatalf("%d descriptors arrived, want %d", got, sent)
	}
	reader.Discard()
	_ = r.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := r.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("after Discard: %v, want EOF", err)
	}
	if left := openFDs() - before; left != 0 {
		t.Fatalf("%d descriptors left open", left)
	}
}
