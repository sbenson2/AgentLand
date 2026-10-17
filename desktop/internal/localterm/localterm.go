// Package localterm is the wire between the host and `agentland-host
// terminals run`, which registers a coding agent typed in Terminal.app as an
// AgentLand terminal (docs/HOST-API.md, "Terminals started in Terminal on the Mac").
//
// The socket is terminals-local.sock beside the keeper's: 0600, this user's,
// and checked per connection, so only this user's own processes reach it. It
// is never bound to TCP or carried through the tunnel, and a shell has no
// session token, so it is the only way to register.
//
// One connection is one registration:
//
//  1. The CLI sends {op: "register"} with the command, its folder, its
//     window size, a Claude Code conversation it chose and its version.
//  2. The host answers {id, meta}, or {error} and hangs up.
//  3. The CLI has the keeper adopt its PTY with that id and meta, then sends
//     {op: "adopted"}, or {op: "cancel"} when it gave up.
//  4. The host follows the terminal and answers {ok: true}.
//
// Each message is one JSON object on one line, at most MaxLine bytes.
package localterm

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
)

// MaxLine bounds one message, without its newline.
const MaxLine = 64 << 10

// ErrLineTooLong is a message over MaxLine.
var ErrLineTooLong = errors.New("the message is longer than 64 KiB")

// SocketPath is where the host for the state at statePath takes
// registrations: terminals-local.sock in the state's folder, beside the
// keeper's terminals.sock.
func SocketPath(statePath string) string {
	return filepath.Join(filepath.Dir(statePath), "terminals-local.sock")
}

// Ops.
const (
	OpRegister = "register"
	OpAdopted  = "adopted"
	OpCancel   = "cancel"
)

// The codes a refusal names.
const (
	CodeDisabled       = "terminal_disabled"
	CodeLimit          = "terminal_limit"
	CodeUnavailable    = "terminals_unavailable"
	CodeVersion        = "version_mismatch"
	CodeUnknownProgram = "program_unknown"
	CodeStopping       = "host_stopping"
	CodeBadRequest     = "invalid_request"
)

// Request is the CLI's message. Register carries the command as typed (its
// name or path), the folder it runs in, the window's size, the Claude Code
// conversation the CLI chose (empty when it chose none) and the CLI's
// version, which must be the host's. Adopted and cancel carry only Op.
//
// Folder must be the caller's own cwd, canonical: on macOS the path
// fcntl(F_GETPATH) gives for "." (symbolic links resolved, each name in its
// true case), elsewhere "." with its symbolic links resolved. It must be
// absolute and clean. The host compares it with the workspaces as a string
// and never opens it, so a folder macOS protects (Downloads, Desktop,
// Documents, an external drive) is never asked for in AgentLand's name.
type Request struct {
	Op             string `json:"op,omitempty"`
	Command        string `json:"command,omitempty"`
	Folder         string `json:"folder,omitempty"`
	Rows           int    `json:"rows,omitempty"`
	Cols           int    `json:"cols,omitempty"`
	ConversationID string `json:"conversationId,omitempty"`
	Version        string `json:"version,omitempty"`
}

// Reply is the host's message: the terminal's id and the record the keeper
// is to hold for it (register), OK (adopted), or why not.
type Reply struct {
	OK    bool   `json:"ok,omitempty"`
	ID    string `json:"id,omitempty"`
	Meta  []byte `json:"meta,omitempty"`
	Error *Error `json:"error,omitempty"`
}

// Error is a refusal: a code above and one sentence for the person.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// WriteLine writes v as one line, in one write.
func WriteLine(w io.Writer, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(data) > MaxLine {
		return ErrLineTooLong
	}
	_, err = w.Write(append(data, '\n'))
	return err
}

// ReadLine reads one line into v. It answers io.EOF when the connection
// ended before a byte, ErrLineTooLong past MaxLine, and
// io.ErrUnexpectedEOF for a line cut short.
func ReadLine(r *bufio.Reader, v any) error {
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		length := len(line) + len(chunk)
		if err == nil {
			length-- // the newline
		}
		if length > MaxLine {
			return ErrLineTooLong
		}
		line = append(line, chunk...)
		switch {
		case err == nil:
			return json.Unmarshal(line[:len(line)-1], v)
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		case errors.Is(err, io.EOF) && len(line) == 0:
			return io.EOF
		case errors.Is(err, io.EOF):
			return io.ErrUnexpectedEOF
		default:
			return err
		}
	}
}
