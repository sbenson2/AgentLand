package keeper

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

// MaxFrame is the most a frame may carry: its kind byte plus its payload.
const MaxFrame = 1 << 20

// MaxMeta is the largest metadata blob a terminal may hold.
const MaxMeta = 16 << 10

const (
	kindHello   = 'H'
	kindRequest = 'Q'
	kindReply   = 'R'
	kindData    = 'D'
	kindSkipped = 'S'
	kindExited  = 'X'
)

// ProtocolMin and ProtocolMax are the protocol versions this build speaks.
const ProtocolMin, ProtocolMax = 1, 1

// ErrFrameTooLarge means a frame's length is 0 or above MaxFrame.
var ErrFrameTooLarge = errors.New("keeper: frame length out of range")

// writeFrame writes one frame in a single Write.
func writeFrame(w io.Writer, kind byte, payload []byte) error {
	buf, err := encodeFrame(kind, payload)
	if err != nil {
		return err
	}
	_, err = w.Write(buf)
	return err
}

// encodeFrame builds a frame: a big-endian uint32 length (kind and payload),
// the kind, then the payload.
func encodeFrame(kind byte, payload []byte) ([]byte, error) {
	if len(payload) >= MaxFrame {
		return nil, ErrFrameTooLarge
	}
	buf := make([]byte, 5+len(payload))
	binary.BigEndian.PutUint32(buf, uint32(1+len(payload)))
	buf[4] = kind
	copy(buf[5:], payload)
	return buf, nil
}

// readFrame reads one frame. It checks the length before allocating.
func readFrame(r io.Reader) (byte, []byte, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return 0, nil, err // io.EOF only when no byte arrived
	}
	n := binary.BigEndian.Uint32(head[:])
	if n == 0 || n > MaxFrame {
		return 0, nil, ErrFrameTooLarge
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return 0, nil, err
	}
	return body[0], body[1:], nil
}

// encodeData builds a data payload: an 8-byte big-endian offset, then the bytes.
func encodeData(offset uint64, p []byte) []byte {
	out := make([]byte, 8+len(p))
	binary.BigEndian.PutUint64(out, offset)
	copy(out[8:], p)
	return out
}

func decodeData(b []byte) (uint64, []byte, error) {
	if len(b) < 8 {
		return 0, nil, errors.New("keeper: short data payload")
	}
	return binary.BigEndian.Uint64(b), b[8:], nil
}

// encodeSkipped builds a skipped payload: the 8-byte big-endian cursor the stream resumes at.
func encodeSkipped(to uint64) []byte {
	return binary.BigEndian.AppendUint64(nil, to)
}

func decodeSkipped(b []byte) (uint64, error) {
	if len(b) != 8 {
		return 0, errors.New("keeper: bad skipped payload")
	}
	return binary.BigEndian.Uint64(b), nil
}

// helloWait is how long a connection has to complete its hello: the client
// to send it, and the keeper to answer.
var helloWait = 5 * time.Second

// Connection roles a hello names.
const (
	roleControl = "control" // requests and replies
	roleAttach  = "attach"  // one attach request, then a terminal's output
)

type hello struct {
	Min     int    `json:"min"`
	Max     int    `json:"max"`
	Version string `json:"version"`
	Role    string `json:"role"` // roleControl or roleAttach
}

// FeatureAdopt is the hello feature of a keeper that adopts PTYs other
// processes opened, and releases them.
const FeatureAdopt = "adopt"

type helloReply struct {
	Protocol int      `json:"protocol"`
	Version  string   `json:"version"`
	Features []string `json:"features"`
	Error    string   `json:"error,omitempty"`
}

// chooseProtocol returns the highest version both sides speak.
func chooseProtocol(theirs hello, min, max int) (int, bool) {
	hi := min2(theirs.Max, max)
	if lo := max2(theirs.Min, min); hi < lo || hi <= 0 {
		return 0, false
	}
	return hi, true
}

func min2(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max2(a, b int) int {
	if a > b {
		return a
	}
	return b
}

type request struct {
	Seq    uint64        `json:"seq"`
	Op     string        `json:"op"`
	ID     string        `json:"id,omitempty"`
	Cursor uint64        `json:"cursor,omitempty"`
	Spawn  *SpawnRequest `json:"spawn,omitempty"`
	Data   []byte        `json:"data,omitempty"`
	Rows   int           `json:"rows,omitempty"`
	Cols   int           `json:"cols,omitempty"`
	Meta   []byte        `json:"meta,omitempty"`
	Adopt  *AdoptRequest `json:"adopt,omitempty"`
	Exit   *Exit         `json:"exit,omitempty"`

	// master is the PTY master an adopt passes beside its frame, never in it.
	master *os.File
}

// Request ops.
const (
	opList    = "list"
	opSpawn   = "spawn"
	opInput   = "input"
	opResize  = "resize"
	opEnd     = "end"
	opForget  = "forget"
	opSetMeta = "setMeta"
	opStopAll = "stopAll"
	opAttach  = "attach"

	opAdopt      = "adopt"
	opRelease    = "release"
	opReportExit = "reportExit"
)

var requestOps = map[string]bool{
	opList: true, opSpawn: true, opInput: true, opResize: true, opEnd: true,
	opForget: true, opSetMeta: true, opStopAll: true, opAttach: true,
	opAdopt: true, opRelease: true, opReportExit: true,
}

// decodeRequest parses a request payload and rejects unknown ops and oversized metadata.
func decodeRequest(b []byte) (request, error) {
	var req request
	if err := json.Unmarshal(b, &req); err != nil {
		return request{}, err
	}
	if !requestOps[req.Op] {
		return request{}, fmt.Errorf("keeper: unknown op %q", req.Op)
	}
	if len(req.Meta) > MaxMeta || (req.Spawn != nil && len(req.Spawn.Meta) > MaxMeta) ||
		(req.Adopt != nil && len(req.Adopt.Meta) > MaxMeta) {
		return request{}, errors.New("keeper: metadata too large")
	}
	return req, nil
}

type reply struct {
	Seq   uint64 `json:"seq"`
	Error *Error `json:"error,omitempty"`
	Info  *Info  `json:"info,omitempty"`
	List  []Info `json:"list,omitempty"`
}

// Error codes a reply may carry. New codes may be added; a client treats an
// unknown one as a plain failure.
const (
	CodeNotFound     = "not_found"     // no terminal has the ID
	CodeExists       = "exists"        // spawn: the ID is taken
	CodeLimit        = "limit"         // spawn: the keeper holds its most terminals
	CodeRunning      = "running"       // forget: the terminal still runs
	CodeNotRunning   = "not_running"   // input, resize: the terminal has finished
	CodeInputStalled = "input_stalled" // input: the program did not take it in time
	CodeStartFailed  = "start_failed"  // spawn: the program could not be started
	CodeBadRequest   = "bad_request"   // the request is malformed or too large
	CodeStopping     = "stopping"      // the keeper is shutting down
	CodeNotAdopted   = "not_adopted"   // release, reportExit: the keeper started that terminal
)

// Error is a reply's failure: a code from the list above and a message.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

type SpawnRequest struct {
	ID   string   `json:"id"`
	Dir  string   `json:"dir"`
	Path string   `json:"path"`
	Args []string `json:"args,omitempty"`
	Env  []string `json:"env,omitempty"`
	Rows int      `json:"rows"`
	Cols int      `json:"cols"`
	Meta []byte   `json:"meta,omitempty"`
}

// AdoptRequest asks the keeper to take over the PTY whose master travels with
// the request. PID is the program running on it, which another process
// started. A size of 0 leaves the PTY's size alone.
type AdoptRequest struct {
	ID   string `json:"id"`
	PID  int    `json:"pid"`
	Rows int    `json:"rows"`
	Cols int    `json:"cols"`
	Meta []byte `json:"meta,omitempty"`
}

type Info struct {
	ID      string    `json:"id"`
	PID     int       `json:"pid"`
	Started time.Time `json:"started"`
	Running bool      `json:"running"`
	Exit    *Exit     `json:"exit,omitempty"`
	Start   uint64    `json:"start"`
	Cursor  uint64    `json:"cursor"`
	Meta    []byte    `json:"meta,omitempty"`
	// Adopted says another process started the program and passed its PTY.
	Adopted bool `json:"adopted,omitempty"`
	// LastInput is when input last reached the program; zero before any.
	LastInput time.Time `json:"lastInput,omitzero"`
}

// Exit says how a terminal's program ended. Signal is unix.SignalName, e.g. "SIGTERM".
// ByKeeper says the keeper ended it as it stopped (end-all, `terminals stop`,
// its own shutdown), never a client's end of that one terminal. Released says
// the keeper gave an adopted terminal back while its program still ran.
type Exit struct {
	Code     *int      `json:"code,omitempty"`
	Signal   string    `json:"signal,omitempty"`
	At       time.Time `json:"at"`
	ByKeeper bool      `json:"byKeeper,omitempty"`
	Released bool      `json:"released,omitempty"`
}
