//go:build !darwin && !linux

// Package localsock binds private Unix sockets; it needs macOS or Linux.
package localsock

import (
	"errors"
	"net"
	"os"
)

const MaxPath = 103

var (
	ErrNotSocket   = errors.New("exists and is not a socket")
	ErrInUse       = errors.New("another process serves the socket")
	ErrTooLong     = errors.New("the socket path is too long for a Unix socket")
	ErrUnsupported = errors.New("local sockets need macOS or Linux")
)

type Socket struct {
	Listener net.Listener
	Path     string
	Info     os.FileInfo
}

func Listen(string) (*Socket, error) { return nil, ErrUnsupported }

func (s *Socket) Close() error { return ErrUnsupported }

func SameUserPeer(net.Conn) error { return ErrUnsupported }
