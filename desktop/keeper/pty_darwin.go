//go:build darwin

package keeper

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// OpenPTY opens a new pseudo-terminal. The master is non-blocking and
// registered with Go's poller, so closing it wakes a pending read or write.
// The slave is a plain blocking file for the program's stdio.
func OpenPTY() (master, slave *os.File, err error) {
	fd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, &os.PathError{Op: "open", Path: "/dev/ptmx", Err: err}
	}
	if err := ptyIoctl(fd, unix.TIOCPTYGRANT, 0); err != nil {
		unix.Close(fd)
		return nil, nil, fmt.Errorf("keeper: grant pty: %w", err)
	}
	if err := ptyIoctl(fd, unix.TIOCPTYUNLK, 0); err != nil {
		unix.Close(fd)
		return nil, nil, fmt.Errorf("keeper: unlock pty: %w", err)
	}
	slaveName, err := slaveNameOf(fd)
	if err != nil {
		unix.Close(fd)
		return nil, nil, err
	}
	if err := unix.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		return nil, nil, fmt.Errorf("keeper: pty non-blocking: %w", err)
	}
	master = os.NewFile(uintptr(fd), "/dev/ptmx")
	// A file outside the poller refuses deadlines; its reads could not be woken.
	if err := master.SetDeadline(time.Time{}); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("keeper: pty is not pollable: %w", err)
	}
	sfd, err := unix.Open(slaveName, unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		master.Close()
		return nil, nil, &os.PathError{Op: "open", Path: slaveName, Err: err}
	}
	return master, os.NewFile(uintptr(sfd), slaveName), nil
}

// slaveNameOf returns the path of the slave of the PTY master fd. It fails
// for anything but a PTY master.
func slaveNameOf(fd int) (string, error) {
	var name [128]byte
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uintptr(unix.TIOCPTYGNAME), uintptr(unsafe.Pointer(&name[0]))); errno != 0 {
		return "", fmt.Errorf("keeper: pty name: %w", errno)
	}
	slaveName := string(name[:max(bytes.IndexByte(name[:], 0), 0)])
	if slaveName == "" {
		return "", errors.New("keeper: pty has no name")
	}
	return slaveName, nil
}

// ptyDevice returns the device of master's slave: the controlling terminal
// of the programs running on it. It fails for anything but a PTY master.
func ptyDevice(master *os.File) (uint64, error) {
	raw, err := master.SyscallConn()
	if err != nil {
		return 0, err
	}
	var name string
	var nameErr error
	if err := raw.Control(func(fd uintptr) { name, nameErr = slaveNameOf(int(fd)) }); err != nil {
		return 0, err
	}
	if nameErr != nil {
		return 0, nameErr
	}
	var st unix.Stat_t
	if err := unix.Stat(name, &st); err != nil {
		return 0, &os.PathError{Op: "stat", Path: name, Err: err}
	}
	return uint64(uint32(st.Rdev)), nil
}

func ptyIoctl(fd int, req uint, arg uintptr) error {
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uintptr(req), arg); errno != 0 {
		return errno
	}
	return nil
}

// SetSize sets a terminal's rows and columns. The kernel tells the foreground
// process group with SIGWINCH.
func SetSize(f *os.File, rows, cols int) error {
	if rows <= 0 || cols <= 0 || rows > 0xffff || cols > 0xffff {
		return fmt.Errorf("keeper: bad terminal size %dx%d", rows, cols)
	}
	raw, err := f.SyscallConn()
	if err != nil {
		return err
	}
	var ioctlErr error
	if err := raw.Control(func(fd uintptr) {
		ioctlErr = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &unix.Winsize{Row: uint16(rows), Col: uint16(cols)})
	}); err != nil {
		return err
	}
	return ioctlErr
}

// Size returns a terminal's rows and columns.
func Size(f *os.File) (rows, cols int, err error) {
	raw, err := f.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var size *unix.Winsize
	var ioctlErr error
	if err := raw.Control(func(fd uintptr) {
		size, ioctlErr = unix.IoctlGetWinsize(int(fd), unix.TIOCGWINSZ)
	}); err != nil {
		return 0, 0, err
	}
	if ioctlErr != nil {
		return 0, 0, ioctlErr
	}
	return int(size.Row), int(size.Col), nil
}
