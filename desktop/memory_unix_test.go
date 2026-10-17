//go:build darwin || linux

package host

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The memory socket (memory.go): the tool server's saves and forgets reach
// the host over a 0600 Unix socket in the state folder that refuses other
// users' processes by the kernel's peer credentials.

func TestMemorySocketSavesAndForgets(t *testing.T) {
	f := newPlainChatFixture(t, HostOptions{})
	path := memorySocketPath(f.store.Path)
	if filepath.Dir(path) != filepath.Dir(f.store.Path) {
		t.Fatalf("the memory socket %s is not in the state folder", path)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Type() != os.ModeSocket || info.Mode().Perm() != 0600 || int(info.Sys().(*syscall.Stat_t).Uid) != os.Getuid() {
		t.Fatalf("socket %v %v", info.Mode(), err)
	}
	answer, err := callMemorySocket(t.Context(), path, memorySocketRequest{Op: "save", Text: "Prefers\nmetric units"})
	if err != nil || answer.Error != "" || answer.Entry == nil || answer.Entry.Text != "Prefers metric units" {
		t.Fatalf("save: %+v %v", answer, err)
	}
	if list := f.host.plainChats.memory.list(); len(list.Entries) != 1 || list.Entries[0].ID != answer.Entry.ID {
		t.Fatalf("the host keeps %+v", list)
	}
	forgot, err := callMemorySocket(t.Context(), path, memorySocketRequest{Op: "forget", ID: answer.Entry.ID})
	if err != nil || forgot.Entry == nil || forgot.Entry.ID != answer.Entry.ID || len(f.host.plainChats.memory.list().Entries) != 0 {
		t.Fatalf("forget: %+v %v", forgot, err)
	}
	// The model is told why memory refused.
	for _, check := range []struct {
		request memorySocketRequest
		words   string
	}{
		{memorySocketRequest{Op: "forget", ID: "mem_missing"}, "No memory entry has that id."},
		{memorySocketRequest{Op: "save", Text: " "}, "nothing to save"},
		{memorySocketRequest{Op: "drop"}, "could not be saved"},
	} {
		answer, err := callMemorySocket(t.Context(), path, check.request)
		if err != nil || answer.Entry != nil || !strings.Contains(answer.Error, check.words) {
			t.Fatalf("%+v: %+v %v", check.request, answer, err)
		}
	}
	f.host.plainChats.memory.setEnabled(false)
	if answer, _ := callMemorySocket(t.Context(), path, memorySocketRequest{Op: "save", Text: "x"}); !strings.HasPrefix(answer.Error, "Memory is off.") {
		t.Fatalf("a save while off: %+v", answer)
	}
	// The host removes its socket when it closes.
	f.host.Close()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket after close: %v", err)
	}
}

func TestMemorySocketRefusesAnotherUsersProcesses(t *testing.T) {
	folder := plainStateFolder(t)
	store, err := openMemoryStore(filepath.Join(folder, "host.json.memory.json"))
	if err != nil {
		t.Fatal(err)
	}
	path := memorySocketPath(filepath.Join(folder, "host.json"))
	socket, err := bindMemorySocket(path, store)
	if err != nil {
		t.Fatal(err)
	}
	checked := make(chan struct{}, 1)
	socket.socket.checkPeer = func(conn net.Conn) error {
		if err := sameUserPeer(conn); err != nil {
			t.Errorf("this user's own process was refused: %v", err)
		}
		checked <- struct{}{}
		return errors.New("another user")
	}
	socket.start()
	defer socket.close()
	answer, err := callMemorySocket(t.Context(), path, memorySocketRequest{Op: "save", Text: "Prefers metric units"})
	<-checked
	if err == nil || answer.Entry != nil {
		t.Fatalf("a connection from another user was answered: %+v", answer)
	}
	if len(store.list().Entries) != 0 {
		t.Fatal("a connection from another user saved an entry")
	}
}

func TestMemorySocketTakesTheTunnelSocketsSafeguards(t *testing.T) {
	folder := plainStateFolder(t)
	store, err := openMemoryStore(filepath.Join(folder, "host.json.memory.json"))
	if err != nil {
		t.Fatal(err)
	}
	// A path too long for a Unix socket is refused.
	long := filepath.Join(folder, strings.Repeat("a", 120)+".memory.sock")
	if _, err := listenMemorySocket(long, store); err == nil {
		t.Fatal("a path too long for a socket was bound")
	}
	// A live socket at the path belongs to another host.
	path := filepath.Join(folder, "host.json.memory.sock")
	first, err := listenMemorySocket(path, store)
	if err != nil {
		t.Fatal(err)
	}
	defer first.close()
	if _, err := listenMemorySocket(path, store); err == nil {
		t.Fatal("a live memory socket was replaced")
	}
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
}
