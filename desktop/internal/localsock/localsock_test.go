//go:build darwin || linux

package localsock

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tempFolder(t *testing.T) string {
	t.Helper()
	folder, err := os.MkdirTemp("/private/tmp", "ls-")
	if err != nil {
		t.Skip("no /private/tmp:", err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	return folder
}

func TestListenMakesAPrivateSocket(t *testing.T) {
	path := filepath.Join(tempFolder(t), "a.sock")
	socket, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Errorf("mode %v", info.Mode())
	}
	if socket.Info.Mode()&os.ModeSocket == 0 || !os.SameFile(info, socket.Info) {
		t.Errorf("Info is not the socket: %v", socket.Info.Mode())
	}
	if socket.Path != path {
		t.Errorf("Path %q", socket.Path)
	}
	if owner, ok := ownerOf(info); !ok || owner != os.Getuid() {
		t.Errorf("owner %d", owner)
	}
}

func TestListenRefusesALiveSocket(t *testing.T) {
	path := filepath.Join(tempFolder(t), "a.sock")
	socket, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	if _, err := Listen(path); err == nil || !strings.Contains(err.Error(), "another") {
		t.Fatalf("a live socket: %v", err)
	}
}

func TestListenReplacesAStaleSocket(t *testing.T) {
	path := filepath.Join(tempFolder(t), "a.sock")
	socket, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	socket.Listener.Close()
	again, err := Listen(path)
	if err != nil {
		t.Fatalf("a stale socket: %v", err)
	}
	again.Close()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("Close left the file: %v", err)
	}
}

func TestListenRefusesANonSocket(t *testing.T) {
	path := filepath.Join(tempFolder(t), "a.sock")
	if err := os.WriteFile(path, []byte("state"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(path); err == nil {
		t.Fatal("a regular file was replaced")
	}
	if data, _ := os.ReadFile(path); string(data) != "state" {
		t.Fatal("the file was changed")
	}
}

func TestListenRefusesALongPath(t *testing.T) {
	if _, err := Listen(strings.Repeat("a", MaxPath+1)); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("a long path: %v", err)
	}
}

func TestCloseLeavesAFileThatIsNotItsOwn(t *testing.T) {
	path := filepath.Join(tempFolder(t), "a.sock")
	socket, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	os.Remove(path)
	if err := os.WriteFile(path, []byte("another"), 0600); err != nil {
		t.Fatal(err)
	}
	socket.Close()
	if data, _ := os.ReadFile(path); string(data) != "another" {
		t.Fatal("Close removed a file that is not its socket")
	}
}

func TestSameUserPeerAcceptsThisUser(t *testing.T) {
	path := filepath.Join(tempFolder(t), "a.sock")
	socket, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	client, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	accepted, err := socket.Listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	if err := SameUserPeer(accepted); err != nil {
		t.Fatal(err)
	}
}
