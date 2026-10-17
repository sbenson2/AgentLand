//go:build darwin || linux

// Package localsock binds the private Unix sockets AgentLand's processes use
// to talk to each other on one machine: 0600, this user's, never reachable by
// another user at any moment, and checked per connection with SameUserPeer.
package localsock

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// MaxPath fits sun_path on macOS (104 bytes with its NUL). The socket is bound
// first in a private folder whose path is 11 bytes longer than the folder of
// the final path.
const MaxPath = 103

// Errors Listen wraps, so callers can word them for their own socket.
var (
	ErrNotSocket = errors.New("exists and is not a socket")
	ErrInUse     = errors.New("another process serves the socket")
	ErrTooLong   = errors.New("the socket path is too long for a Unix socket")
)

// ErrUnsupported is what Listen returns where Unix sockets with peer
// credentials are not available.
var ErrUnsupported = errors.New("local sockets need macOS or Linux")

// Socket is a bound private socket.
type Socket struct {
	Listener net.Listener
	Path     string
	Info     os.FileInfo
}

// Listen binds a socket at path. It binds in a new private folder beside path,
// sets the socket to 0600, checks that it belongs to this user and only then
// moves it to path. A stale socket at path is replaced; a live one, or
// anything that is not a socket, is refused.
func Listen(path string) (*Socket, error) {
	if len(path) > MaxPath {
		return nil, fmt.Errorf("%w: %s", ErrTooLong, path)
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode().Type() != os.ModeSocket {
			return nil, fmt.Errorf("%s %w; remove it", path, ErrNotSocket)
		}
		if conn, err := net.DialTimeout("unix", path, time.Second); err == nil {
			conn.Close()
			return nil, fmt.Errorf("%w %s", ErrInUse, path)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	private, err := privateBindFolder(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(private)
	temporary := filepath.Join(private, "s")
	if len(temporary) > MaxPath {
		return nil, fmt.Errorf("%w: the folder of %s", ErrTooLong, path)
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: temporary, Net: "unix"})
	if err != nil {
		return nil, err
	}
	// The file moves; the socket removes its own file when it stops.
	listener.SetUnlinkOnClose(false)
	fail := func(err error) (*Socket, error) {
		listener.Close()
		return nil, err
	}
	if err := os.Chmod(temporary, 0600); err != nil {
		return fail(err)
	}
	bound, err := os.Lstat(temporary)
	if err != nil {
		return fail(err)
	}
	if owner, ok := ownerOf(bound); !ok || owner != os.Getuid() || bound.Mode().Perm() != 0600 || bound.Mode().Type() != os.ModeSocket {
		return fail(errors.New("the socket is not a private socket of this user"))
	}
	if err := os.Rename(temporary, path); err != nil {
		return fail(err)
	}
	placed, err := os.Lstat(path)
	if err != nil || !os.SameFile(placed, bound) {
		return fail(errors.New("the socket changed while it was put in place"))
	}
	return &Socket{Listener: listener, Path: path, Info: placed}, nil
}

// Close stops the listener and deletes the socket file if it is still this
// socket's.
func (s *Socket) Close() error {
	err := s.Listener.Close()
	if s.Info != nil {
		if info, statErr := os.Lstat(s.Path); statErr == nil && os.SameFile(info, s.Info) {
			_ = os.Remove(s.Path)
		}
	}
	return err
}

func ownerOf(info os.FileInfo) (int, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return -1, false
	}
	return int(stat.Uid), true
}

// privateBindFolder makes a new folder, 0700, with a short name in directory.
func privateBindFolder(directory string) (string, error) {
	for range 16 {
		var suffix [3]byte
		if _, err := rand.Read(suffix[:]); err != nil {
			return "", err
		}
		folder := filepath.Join(directory, ".t"+hex.EncodeToString(suffix[:]))
		err := os.Mkdir(folder, 0700)
		if err == nil {
			return folder, os.Chmod(folder, 0700)
		}
		if !errors.Is(err, fs.ErrExist) {
			return "", err
		}
	}
	return "", errors.New("could not make a private folder for the socket")
}

// SameUserPeer refuses a connection unless the kernel reports that the
// connecting process runs as this user.
func SameUserPeer(conn net.Conn) error {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return errors.New("not a Unix socket connection")
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return err
	}
	uid, credentialErr := -1, error(nil)
	if err := raw.Control(func(fd uintptr) { uid, credentialErr = peerUID(int(fd)) }); err != nil {
		return err
	}
	if credentialErr != nil {
		return credentialErr
	}
	if uid != os.Getuid() {
		return errors.New("the connecting process runs as another user")
	}
	return nil
}
