//go:build darwin || linux

package localsock

import (
	"encoding/binary"
	"errors"
	"net"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

// maxRights is the most descriptors one read takes in. It is more than either
// kernel puts in one message (macOS refuses a send of over 254, Linux of over
// 253), and a read stops at the next message's descriptors. So a read is
// never cut short: macOS installs every descriptor of a cut-short message but
// hands over the numbers of only those that fit, and the rest stay open.
const maxRights = 256

// SendWithFile writes data to conn and passes f's descriptor with its first
// byte (SCM_RIGHTS). The receiver gets its own descriptor for the same open
// file. The descriptor is read through SyscallConn, which never changes f's
// blocking mode, as Fd can: that mode belongs to the open file both sides
// share.
func SendWithFile(conn *net.UnixConn, data []byte, f *os.File) error {
	raw, err := f.SyscallConn()
	if err != nil {
		return err
	}
	var n int
	var sendErr error
	err = raw.Control(func(fd uintptr) {
		rights := unix.UnixRights(int(fd))
		var oobn int
		n, oobn, sendErr = conn.WriteMsgUnix(data, rights, nil)
		if sendErr == nil && oobn != len(rights) {
			sendErr = errors.New("localsock: the descriptor was not sent")
		}
	})
	if err == nil {
		err = sendErr
	}
	for err == nil && n < len(data) {
		var m int
		m, err = conn.Write(data[n:])
		n += m
	}
	return err
}

// RightsReader reads a Unix connection's bytes and keeps the descriptors
// that arrive with them until they are taken or discarded. It is for one
// goroutine at a time.
type RightsReader struct {
	conn *net.UnixConn
	oob  []byte
	fds  []int // arrived and not yet taken, in order
}

// NewRightsReader reads conn.
func NewRightsReader(conn *net.UnixConn) *RightsReader {
	return newRightsReader(conn, maxRights)
}

// newRightsReader takes in at most fds descriptors a read.
func newRightsReader(conn *net.UnixConn, fds int) *RightsReader {
	return &RightsReader{conn: conn, oob: make([]byte, unix.CmsgSpace(fds*4))}
}

// Read reads bytes into p and keeps any descriptors that came with them. A
// read the kernel cut short, or control data that does not parse, is an
// error: every descriptor it brought that can be found is closed, and so is
// every one kept so far.
func (r *RightsReader) Read(p []byte) (int, error) {
	n, oobn, flags, _, err := r.conn.ReadMsgUnix(p, r.oob)
	oob := r.oob[:oobn]
	var oobErr error
	switch {
	case flags&unix.MSG_CTRUNC != 0:
		closeRights(oob)
		r.Discard()
		oobErr = errors.New("localsock: more descriptors arrived than a read takes")
	case oobn > 0:
		oobErr = r.keep(oob)
	}
	if err == nil {
		err = oobErr
	}
	return n, err
}

// keep queues the descriptors in oob. When oob does not parse, it closes
// them instead and queues none.
func (r *RightsReader) keep(oob []byte) error {
	messages, err := unix.ParseSocketControlMessage(oob)
	var arrived []int
	for i := 0; err == nil && i < len(messages); i++ {
		m := &messages[i]
		if m.Header.Level != unix.SOL_SOCKET || m.Header.Type != unix.SCM_RIGHTS {
			continue
		}
		var fds []int
		fds, err = unix.ParseUnixRights(m)
		arrived = append(arrived, fds...)
	}
	if err != nil {
		closeRights(oob)
		return err
	}
	for _, fd := range arrived {
		unix.CloseOnExec(fd)
	}
	r.fds = append(r.fds, arrived...)
	return nil
}

// closeRights closes the descriptors in oob's SCM_RIGHTS messages, including
// those of a message the kernel cut short. macOS leaves such a message's
// length as it would have been, so the parser refuses the message, yet the
// descriptors that fit are open in this process.
func closeRights(oob []byte) {
	for len(oob) >= unix.SizeofCmsghdr {
		var h unix.Cmsghdr
		copy(unsafe.Slice((*byte)(unsafe.Pointer(&h)), unix.SizeofCmsghdr), oob)
		size := int(h.Len)
		if size < unix.CmsgLen(0) {
			return
		}
		if h.Level == unix.SOL_SOCKET && h.Type == unix.SCM_RIGHTS && len(oob) > unix.CmsgLen(0) {
			for data := oob[unix.CmsgLen(0):min(size, len(oob))]; len(data) >= 4; data = data[4:] {
				_ = unix.Close(int(int32(binary.NativeEndian.Uint32(data))))
			}
		}
		next := unix.CmsgSpace(size - unix.CmsgLen(0))
		if next >= len(oob) {
			return
		}
		oob = oob[next:]
	}
}

// TakeFile returns the first descriptor that arrived and was not yet taken,
// as a file called name, or nil when none did. The caller owns it.
func (r *RightsReader) TakeFile(name string) *os.File {
	if len(r.fds) == 0 {
		return nil
	}
	fd := r.fds[0]
	r.fds = r.fds[1:]
	return os.NewFile(uintptr(fd), name)
}

// Discard closes every descriptor that arrived and was not taken.
func (r *RightsReader) Discard() {
	for _, fd := range r.fds {
		_ = unix.Close(fd)
	}
	r.fds = nil
}
