package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"agentland/host/keeper"
)

// The host runs every terminal through a TerminalBackend: AgentLand's
// terminal keeper (desktop/keeper), which holds the PTYs so they outlive the
// host. Tests use an in-memory fake (terminal_fake_test.go).

// TerminalBackend is what the host asks of the terminal keeper.
type TerminalBackend interface {
	// Status says whether a keeper answers: none runs, one runs, or one runs
	// that this build cannot use (a mismatched or hung keeper, left alone).
	Status(ctx context.Context) KeeperStatus
	List(ctx context.Context) ([]keeper.Info, error)
	Spawn(ctx context.Context, request keeper.SpawnRequest) (keeper.Info, error)
	// Attach streams a terminal's output from cursor from.
	Attach(ctx context.Context, id string, from uint64) (TerminalAttachment, error)
	Input(ctx context.Context, id string, data []byte) error
	Resize(ctx context.Context, id string, rows, cols int) error
	// End ends the terminal's program and returns once it has exited.
	End(ctx context.Context, id string) (keeper.Info, error)
	// Forget drops a finished terminal and its output.
	Forget(ctx context.Context, id string) error
	SetMeta(ctx context.Context, id string, meta []byte) error
	// Release gives an adopted terminal back to the process that started it
	// (a routed agent's Terminal.app window): its program keeps running, and
	// its streams end with an exit that says Released.
	Release(ctx context.Context, id string) error
	// Features connects as Spawn does, starting a keeper when none runs, and
	// answers the features its hello listed (keeper.FeatureAdopt).
	Features(ctx context.Context) ([]string, error)
	Close() error // detaches; never ends terminals
}

// TerminalAttachment is one terminal's output stream (keeper.Attachment).
type TerminalAttachment interface {
	Next() (keeper.Event, error)
	Close() error
}

// KeeperStatus is what TerminalBackend.Status found.
type KeeperStatus int

const (
	KeeperNone     KeeperStatus = iota // no keeper runs: its terminals are gone
	KeeperRunning                      // a keeper runs and answers
	KeeperUnusable                     // a keeper runs that this build cannot use
)

// terminalMetaVersion is the highest terminalMeta.V this build reads.
const terminalMetaVersion = 2

// terminalMeta is the host's record of a terminal, kept in the keeper beside
// it (keeper.SpawnRequest.Meta, SetMeta), so a host that starts again knows
// whose it is and what it runs. It never holds output, arguments,
// environment or credentials.
//
// V1 names the terminal's workspace. V2 is for a terminal outside any
// workspace or a routed one (a coding agent typed in Terminal.app that the
// keeper adopted): it names the terminal's folder, and its workspace only
// when it has one. Older hosts leave V2 records alone, so a record that fits
// V1 is written as V1 (version).
type terminalMeta struct {
	V       int    `json:"v"`
	Owner   string `json:"owner"`
	Project string `json:"project"`
	// Folder is where the terminal runs (V2).
	Folder string `json:"folder,omitempty"`
	// Routed says Terminal.app's CLI started the program and the keeper
	// adopted its PTY (V2).
	Routed         bool   `json:"routed,omitempty"`
	Program        string `json:"program"`
	ConversationID string `json:"conversationId,omitempty"`
	Title          string `json:"title"`
	ContextTitle   string `json:"contextTitle,omitempty"`
	// ContextTitleSource is TerminalInfo's; a record without one (an older
	// build's) restores its ContextTitle as the program's.
	ContextTitleSource string    `json:"contextTitleSource,omitempty"`
	LogID              string    `json:"logId,omitempty"`
	Version            string    `json:"version,omitempty"`
	Created            time.Time `json:"created"`
}

// version is the version the record is written as: 1 while it names a
// workspace and is not routed, otherwise 2.
func (m terminalMeta) version() int {
	if m.Project != "" && !m.Routed {
		return 1
	}
	return 2
}

// encode is the record as the keeper keeps it. A V2 record without a folder
// is refused: decodeTerminalMeta would refuse it, and restore would drop the
// terminal, so it is never written.
func (m terminalMeta) encode() ([]byte, error) {
	m.V = m.version()
	if m.V == 2 && m.Folder == "" {
		return nil, errors.New("terminal metadata outside a workspace, or routed, names no folder")
	}
	return json.Marshal(m)
}

// newerTerminalMetaError is a record a newer build wrote: its version is above
// terminalMetaVersion. That build owns it; this one leaves it alone.
type newerTerminalMetaError struct{ version int }

func (e *newerTerminalMetaError) Error() string {
	return fmt.Sprintf("terminal metadata version %d is newer than %d", e.version, terminalMetaVersion)
}

// decodeTerminalMeta reads a record. Its version is read first, so a newer
// build's record is told apart (newerTerminalMetaError) even when the rest of
// it no longer fits this build's fields. The record only gains fields within
// a version, like the wire.
func decodeTerminalMeta(data []byte) (terminalMeta, error) {
	var version struct {
		V int `json:"v"`
	}
	if err := json.Unmarshal(data, &version); err != nil {
		return terminalMeta{}, err
	}
	if version.V > terminalMetaVersion {
		return terminalMeta{}, &newerTerminalMetaError{version: version.V}
	}
	var meta terminalMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return terminalMeta{}, err
	}
	switch {
	case meta.V != 1 && meta.V != 2:
		return terminalMeta{}, fmt.Errorf("terminal metadata version %d is not 1 or 2", meta.V)
	case meta.Owner == "":
		return terminalMeta{}, errors.New("terminal metadata names no owner")
	case meta.V == 1 && meta.Project == "":
		return terminalMeta{}, errors.New("terminal metadata names no workspace")
	case meta.V == 2 && meta.Folder == "":
		return terminalMeta{}, errors.New("terminal metadata names no folder")
	}
	return meta, nil
}

// newTerminalID is a new terminal's ID: "term_" and 16 hex digits, inside
// the keeper's ID rule [A-Za-z0-9._:-]{1,128}.
func newTerminalID() string {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		panic(err)
	}
	return "term_" + hex.EncodeToString(random[:])
}

// Keeper requests the routes make wait at most this long.
const (
	terminalRequestWait = 10 * time.Second // spawn, end, forget: the end sequence takes up to 5 s
	terminalAttachWait  = 3 * time.Second
)

// terminalReattachTries and terminalReattachPause bound re-attaching to a
// keeper that answers after an attachment dropped.
const (
	terminalReattachTries = 3
	terminalReattachPause = 200 * time.Millisecond
)

// Answers for a keeper that cannot be used, for one that cannot start because
// its socket path is too long, and for input the program does not take.
const (
	terminalsUnavailableMessage = "AgentLand's terminal service isn't answering; your terminals are still running."
	terminalPathTooLongMessage  = "AgentLand's terminal service can't start: its socket path is too long."
	terminalInputStalledMessage = "The program in this terminal isn't reading input; nothing was sent."
)
