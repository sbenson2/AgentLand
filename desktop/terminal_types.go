package host

import (
	"context"
	"sync"
	"time"
)

type HostOptions struct {
	TerminalEnabled   bool
	LocalSessionToken string
	CLIChats          *CLIChats
	Attachments       *AttachmentStore
	Queue             *PromptQueue

	// Archive (M1 chunk B1): the local copy of chats and terminal output.
	// Nil disables it (serve --no-archive). Host.Close closes it.
	Archive *Archive
	// Project file changes (files_mutate.go). FileUploadLimit caps one
	// POST /v1/files/upload body in bytes; zero means 256 MiB.
	FileUploadLimit int64

	// Web previews (preview.go): nil keeps them off (serve without
	// --enable-preview).
	Preview *PreviewOptions

	// Workspaces (workspaces.go): the folder whose sub-folders devices browse
	// and add (serve --workspace-home); empty means this user's home folder.
	WorkspaceHome string

	// Routes (network_routes.go): the ways devices reach this host, listed
	// in capabilities (serve --advertised-host). Nil lists none.
	Routes *RouteOptions

	// Remote access (remote_access.go, tunnel.go): serve --tunnel-socket.
	// It takes effect only with LocalSessionToken, since the Mac app reports
	// its endpoint and follows the peer list with its local session.
	RemoteAccess bool

	// Chat names (chat_title_store.go): <state>.titles.json, the names the
	// host gave OpenCode chats. Nil keeps them in memory only.
	ChatTitles *ChatTitleStore

	// Agents (agents_catalog.go): the agent catalog, its installs and
	// updates, and ACP chats, kept in <state>.agents. Nil keeps them off
	// (serve --no-agents).
	Agents *AgentOptions

	// Plain chats (plain_chats.go): the Chats space in <state>.chat-home,
	// its OpenCode configuration, the memory (<state>.memory.json) and the
	// tool server's socket (<state>.memory.sock). Nil keeps them off; serve
	// always sets it.
	PlainChats *PlainChatOptions

	// Vault (vault.go, vault_routes.go): the Markdown copy of the archive's
	// chats and terminals, off until this Mac's app turns it on. It needs the
	// archive; nil leaves it out. serve sets it whenever it keeps an archive.
	Vault *VaultOptions

	// OpenCodeHome is the managed OpenCode's root folder (serve
	// --opencode-home): the OpenCode terminals share its config and storage
	// (terminal_launch.go). Empty when the app does not run that OpenCode.
	OpenCodeHome string

	// Terminals (terminal_backend.go) is the terminal keeper the host runs
	// every terminal in. Terminals are on only with TerminalEnabled and a
	// backend. Host.Close detaches from it and never ends its terminals.
	Terminals TerminalBackend
	// TerminalHiddenEnv names variables no terminal sees (serve's
	// --local-session-env), beside the state's OpenCode password variable.
	TerminalHiddenEnv []string
	// Version is this host's build (serve's version). A registration from
	// Terminal.app's CLI names its own, and only the same one is taken
	// (terminal_local.go).
	Version string
}

type TerminalInfo struct {
	UpdateNotice string `json:"updateNotice,omitempty"`
	ID           string `json:"id"`
	Title        string `json:"title"`
	ProjectID    string `json:"projectId"`
	Status       string `json:"status"`
	ExitCode     *int   `json:"exitCode,omitempty"`
	// Terminal titles (terminal_title.go): the title the program set last,
	// cleaned, and on macOS the foreground command while it set none
	// (terminal_command_darwin.go). Both are omitted when there is none.
	ProgramTitle string `json:"programTitle,omitempty"`
	// Latest work description, retained when the program returns to an idle title.
	ContextTitle string `json:"contextTitle,omitempty"`
	// ContextTitleSource says where ContextTitle came from: "program" (its
	// OSC title) or "device" (POST /v1/terminal/title). A device's name stays
	// until a device names the terminal again; omitted without a ContextTitle.
	ContextTitleSource string `json:"contextTitleSource,omitempty"`
	Command            string `json:"command,omitempty"`
	// ConversationID is the Claude Code conversation a "claude" terminal
	// runs (--session-id, or the one it resumed); empty for other programs
	// and for a terminal that continued the folder's latest conversation.
	ConversationID string `json:"conversationId,omitempty"`
	// Ended says how a terminal that is no longer running ended.
	Ended *TerminalEnd `json:"ended,omitempty"`
	// Directory is the terminal's folder: its workspace's at creation, and
	// its record's folder (else its workspace's) once restored.
	Directory string `json:"-"`
	// PID is the PTY's own process, when the backend reports it.
	PID int `json:"-"`
}

// How a terminal ended (docs/HOST-API.md "Terminals"): the reason of its
// TerminalEnd, kept on the live terminal and in the archive's terminal_logs.
const (
	terminalEndProgramExited    = "programExited"    // its program exited (the keeper reported it)
	terminalEndDevice           = "endedByDevice"    // a device ended it (POST /v1/terminal/close)
	terminalEndWorkspaceRemoved = "workspaceRemoved" // its workspace was removed
	terminalEndHostStopped      = "hostStopped"      // the host stopped
	terminalEndKeeperStopped    = "keeperStopped"    // the terminal keeper stopped (restart, logout, a crash)
	terminalEndOnMac            = "endedOnMac"       // ended from AgentLand on the Mac
	terminalEndDeviceRemoved    = "deviceRemoved"    // its device was removed with its terminals
	terminalEndKeptInTerminal   = "keptInTerminal"   // a routed agent was released to its Terminal.app window, where it runs on
	// terminalEndHostInterrupted is only the archive's, and no longer
	// produced: an older host found the log left running at its start and
	// marked it interrupted without a reason.
	terminalEndHostInterrupted = "hostInterrupted"
)

// TerminalEnd is how a terminal ended: why, when, the program's exit code
// when the backend still knew it, the device that ended it, and what a
// device needs to offer Resume (the program, and Claude Code's conversation).
type TerminalEnd struct {
	Reason         string `json:"reason"`
	At             string `json:"at"`
	ExitCode       *int   `json:"exitCode,omitempty"`
	Device         string `json:"device,omitempty"`
	Program        string `json:"program,omitempty"`
	ConversationID string `json:"conversationId,omitempty"`
}

type terminalEntry struct {
	mu      sync.Mutex
	writeMu sync.Mutex
	owner   string
	// project is its workspace; Project{} for a terminal outside any. It
	// changes only when such a terminal joins a workspace (joinWorkspace,
	// which holds the manager's mu and this mu), so read it under either,
	// or through projectID.
	project Project
	info    TerminalInfo
	// meta is the host's record of it in the keeper (terminal_backend.go).
	meta terminalMeta
	// attachment is its output stream from the keeper, under mu; follow
	// reads it, and Host.Close and attachmentLost replace or close it.
	attachment TerminalAttachment
	output     []byte
	start      uint64
	cursor     uint64
	changed    chan struct{}

	// Archive (M1 chunk B1): records this terminal's output, never its
	// input. Set before follow starts, then used only by follow; nil
	// without an archive.
	log *TerminalLog

	// Terminal titles (terminal_title.go): read by follow only; what it
	// finds goes to info.ProgramTitle under mu.
	titles     terminalTitleTracker
	nameCursor uint64 // newest output represented by ContextTitle, under mu
	// rows and cols are the size a device created or last resized it to,
	// under mu; 0 when the host has not seen one (a terminal restored after
	// a restart, a routed agent). The Mac app's naming renders its output at
	// this size (GET /v1/terminals/all).
	rows, cols int
	// renameMu serializes archiveTitle; never taken while holding mu.
	renameMu sync.Mutex
	// The foreground command (terminal_command_darwin.go): the PTY's process
	// and when the host learned it, fixed at creation; command and commandAt
	// hold the last reading, under mu.
	pid       int
	started   time.Time
	command   string
	commandAt time.Time

	// Activity (terminal_activity.go): when output and input last came and
	// when the program last asked for attention, under mu. receive feeds it
	// live output, never what a restore replays.
	activity terminalActivity

	// The keeper's record (terminal_context_title.go): metaDirty says meta
	// changed since it was last written to the keeper, and metaSaving that a
	// writer runs; both under mu.
	metaDirty  bool
	metaSaving bool

	// Agents (agents_activity.go): the program the terminal was opened with
	// ("shell" or an agent's id), fixed at creation, so updates and
	// uninstalls know which terminals are an agent's.
	program string

	// How it ended (terminal_end.go), under mu: ending is the end a host
	// action asked for before it asked the keeper to end it, so the exit
	// that follows is recorded as that action's; endedBy is the device that
	// ended it, for the archive; endedAt is when it ended. following is
	// whether follow still runs for it (set at creation, cleared as follow
	// stops): while it does, follow records its log's end, and afterwards
	// keeperStopped does. done closes when follow returns.
	ending    *terminalEnding
	endedBy   string
	endedAt   time.Time
	following bool
	done      chan struct{}
	clock     func() time.Time
}

type terminalManager struct {
	mu            sync.Mutex
	backend       TerminalBackend
	launcher      *terminalLauncher
	entries       map[string]*terminalEntry
	starting      int
	creating      sync.WaitGroup
	cleanupErrors []error
	closed        bool
	// unusable is set, under mu, when the keeper runs but cannot be used:
	// its terminals stay running, and routes answer terminals_unavailable.
	// retrying is set while the retry loop runs (terminal_restore.go); it
	// runs restore, the host's restoreTerminals, every retryEvery until the
	// keeper can be used again.
	unusable   bool
	retrying   bool
	restore    func(context.Context)
	retryEvery time.Duration
	// reattachQuick is how soon an attachment must fail, without an event,
	// for its re-attach to count as a failed try (follow).
	reattachQuick time.Duration

	// Archive (M1 chunk B1): output followers, so Close can let them flush
	// their logs before the archive closes. Restore's ending of an older
	// host's OpenCode PTYs (endLegacyPTYs) counts too, so it never outlives
	// Close.
	readers sync.WaitGroup

	// command reads a terminal's foreground command (foregroundCommand,
	// terminal_command_darwin.go); routed says pid is a routed agent's
	// job-control leader. Tests replace it.
	command func(pid int, started time.Time, routed bool) string

	// now is the clock finished terminals are cleared by (tests move it).
	now func() time.Time
	// cleared remembers, under mu, for a day, how forgotten terminals ended:
	// closed, cleared after a day or on the Mac (forgetEntry), so every
	// device's next read still learns it (terminal_mac_routes.go); lastClear
	// is when clearFinished last ran from maintenance.
	cleared   map[string]clearedTerminal
	lastClear time.Time

	// stopping is the host's (closed by BeginShutdown) and closing closes in
	// Host.Close, so no re-attach outlasts shutdown.
	stopping <-chan struct{}
	closing  chan struct{}

	// The keeper keep-alive (terminal_keepalive.go): keeperGone wakes it when
	// the keeper stopped (one slot, never blocks); keepAliveDone closes when
	// it has returned, nil when it never ran.
	keeperGone    chan struct{}
	keepAliveDone chan struct{}
}
