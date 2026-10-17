//go:build !darwin && !linux

package localsock

import (
	"net"
	"os"
)

// SendWithFile needs macOS or Linux.
func SendWithFile(*net.UnixConn, []byte, *os.File) error { return ErrUnsupported }

// RightsReader reads a connection plainly: no descriptors arrive here.
type RightsReader struct{ conn *net.UnixConn }

func NewRightsReader(conn *net.UnixConn) *RightsReader { return &RightsReader{conn: conn} }

func (r *RightsReader) Read(p []byte) (int, error) { return r.conn.Read(p) }

func (r *RightsReader) TakeFile(string) *os.File { return nil }

func (r *RightsReader) Discard() {}
