package host

import (
	"context"
	"errors"
	"fmt"
	"log"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"agentland/host/internal/localterm"
)

// Continuing a terminal in a new one (docs/HOST-API.md, "Continuing a
// terminal in a new one"). The owner's handoff ends a Claude Code session and
// goes on in a fresh one: typed in an AgentLand terminal, `agentland-host
// terminals continue -- <prompt>` asks this host, on the private local socket
// (terminal_local.go), to start Claude Code with the prompt in a new terminal
// of the same workspace, for the same device. The caller then ends its own
// program; the host never ends it. Once the new terminal runs, the old one's
// end names it (TerminalEnd.ContinuedIn), so a device's tab switches to it in
// place.
//
// The host builds the arguments: Claude Code's new conversation
// (claudeConversationArgs), then the prompt as one final argument. Only this
// user's own processes reach the local socket, so only they can send a
// prompt; devices still never send arguments or commands. The prompt is never
// logged.
//
// continuedIn lives in the host's memory only: the archive does not store
// it, so a host that starts again between the continue and the old
// terminal's end loses the link.

// continuePromptLimit bounds a continue's prompt, in bytes.
const continuePromptLimit = 4096

// localContinueWait bounds a continue's update preparation, which may take
// up to terminalUpdateWait (30 s) as for a device's new terminal, so that
// with the start after it (the keeper's spawn and record, each within
// terminalRequestWait, and its attach) the answer comes within the CLI's 60 s.
const localContinueWait = 35 * time.Second

// localTerminalID is the keeper's rule for a terminal's ID ([A-Za-z0-9._:-],
// 1 to 128 bytes), which every terminal the host follows meets.
var localTerminalID = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)

// continueTerminal starts Claude Code with the request's prompt in a new
// terminal in place of the request's (From) and answers the new terminal's
// ID. The refusals come in this order: terminal access off, another version,
// a prompt that is not one (continuePrompt), a terminal that cannot be
// continued (continuableTerminal), Claude Code or the keeper unavailable, and
// then whatever startTerminal answers (a host that is stopping, the
// 16-terminal cap). The new terminal is the old one's owner's, in its
// workspace, under its creation title, at the request's size when it is
// valid, else the old terminal's when the host knows it, else 24×80. Only on
// success does the old terminal learn where it continued (continuedIn).
func (h *Host) continueTerminal(request localterm.Request) (string, *localterm.Error) {
	if h.terminals == nil {
		return "", localRefusal(localterm.CodeDisabled, "AgentLand's terminal access is off.")
	}
	if request.Version != h.version {
		return "", localRefusal(localterm.CodeVersion, "This command and the AgentLand host running now are different versions.")
	}
	prompt, ok := continuePrompt(request.Prompt)
	if !ok {
		return "", localRefusal(localterm.CodeBadRequest, fmt.Sprintf("The prompt must be one line of text, at most %d bytes, not starting with \"-\".", continuePromptLimit))
	}
	old, refusal := h.continuableTerminal(request.From)
	if refusal != nil {
		return "", refusal
	}
	old.mu.Lock()
	owner, title, rows, cols := old.owner, old.meta.Title, old.rows, old.cols
	if title == "" {
		title = old.info.Title
	}
	workspace := old.project.ID
	old.mu.Unlock()
	if title == "" {
		title = "Terminal"
	}
	if workspace == "" {
		return "", localRefusal(localterm.CodeNotContinuable, "This terminal isn't in a workspace.")
	}
	project, err := h.project(workspace)
	if err != nil {
		return "", localRefusal(localterm.CodeNotContinuable, "This terminal's workspace is gone.")
	}
	switch {
	case validTerminalSize(request.Rows, request.Cols):
		rows, cols = request.Rows, request.Cols
	case !validTerminalSize(rows, cols):
		rows, cols = 24, 80
	}
	if !h.hasTerminalProgram("claude") {
		return "", localRefusal(localterm.CodeUnknownProgram, "Claude Code isn't available to AgentLand's terminals on this Mac.")
	}
	if h.terminals.isUnusable() {
		return "", localRefusal(localterm.CodeUnavailable, terminalsUnavailableMessage)
	}
	// The agent's update preparation runs as for a device's new terminal: an
	// update that fails or is slow never refuses.
	ctx, cancel := context.WithTimeout(context.Background(), localContinueWait)
	defer cancel()
	release, updateNotice, err := h.agents.prepareTerminal(ctx, "claude")
	if err != nil {
		return "", h.continuePrepareRefusal(ctx, err)
	}
	defer release()
	conversation := terminalConversation{ID: newClaudeUUID()}
	info, err := h.startTerminal(terminalStart{owner: owner, project: project, title: title, program: "claude", conversation: &conversation,
		after: []string{prompt}, rows: rows, cols: cols, updateNotice: updateNotice})
	if err != nil {
		return "", continueStartRefusal(err)
	}
	log.Printf("terminals: created id=%s workspace=%s program=claude device=%s continued from=%s", info.ID, project.ID, owner, request.From)
	h.terminals.recordContinuation(old, info.ID)
	return info.ID, nil
}

// continuePrompt is a continue's prompt as the new Claude Code gets it, its
// white space trimmed, when it is one: valid UTF-8 of at most
// continuePromptLimit bytes without any control character (Unicode Cc, tab
// and newline included), and once trimmed neither empty nor starting with
// "-", so claude never reads it as an option.
func continuePrompt(raw string) (string, bool) {
	if len(raw) > continuePromptLimit || !utf8.ValidString(raw) || strings.IndexFunc(raw, func(r rune) bool { return unicode.Is(unicode.Cc, r) }) >= 0 {
		return "", false
	}
	prompt := strings.TrimSpace(raw)
	if prompt == "" || strings.HasPrefix(prompt, "-") {
		return "", false
	}
	return prompt, true
}

// continuableTerminal is the terminal a continue names when the host can
// continue it: an AgentLand terminal the host follows, running, started by
// the host (not an agent typed in Terminal.app, which is the person's own
// window) and running Claude Code.
func (h *Host) continuableTerminal(from string) (*terminalEntry, *localterm.Error) {
	if !localTerminalID.MatchString(from) {
		return nil, localRefusal(localterm.CodeNotContinuable, "This isn't an AgentLand terminal.")
	}
	h.terminals.mu.Lock()
	entry := h.terminals.entries[from]
	h.terminals.mu.Unlock()
	if entry == nil {
		return nil, localRefusal(localterm.CodeNotContinuable, "AgentLand doesn't have this terminal.")
	}
	entry.mu.Lock()
	running, routed, program := entry.info.Status == "running", entry.meta.Routed, entry.program
	entry.mu.Unlock()
	switch {
	case !running:
		return nil, localRefusal(localterm.CodeNotContinuable, "This terminal has ended.")
	case routed:
		return nil, localRefusal(localterm.CodeNotContinuable, "This terminal was started in Terminal, not by AgentLand.")
	case program != "claude":
		return nil, localRefusal(localterm.CodeNotContinuable, "Only a Claude Code terminal can be continued.")
	}
	return entry, nil
}

// continuePrepareRefusal is a failed update preparation's refusal, as close
// as the local socket's codes come to createTerminal's answer.
func (h *Host) continuePrepareRefusal(ctx context.Context, err error) *localterm.Error {
	stopping := false
	select {
	case <-h.stopping:
		stopping = true
	default:
	}
	switch {
	case errors.Is(err, errAgentChangeBusy):
		return localRefusal(localterm.CodeUnavailable, "Claude Code is being installed, removed or restored; try again when that ends.")
	case stopping || (ctx.Err() == nil && errors.Is(err, context.Canceled)):
		return localRefusal(localterm.CodeStopping, "AgentLand's host is stopping.")
	case ctx.Err() != nil:
		return localRefusal(localterm.CodeUnavailable, "AgentLand took too long to start the new terminal.")
	}
	log.Printf("terminals: could not prepare a continued terminal program=claude")
	return localRefusal(localterm.CodeUnavailable, "AgentLand could not start the new terminal.")
}

// continueStartRefusal is startTerminal's failure as the local socket's
// refusal: the code closest to what createTerminal answers.
func continueStartRefusal(err error) *localterm.Error {
	switch {
	case errors.Is(err, errTerminalStartStopping), errors.Is(err, errHostStopping):
		return localRefusal(localterm.CodeStopping, "AgentLand's host is stopping.")
	case errors.Is(err, errTerminalLimit):
		return localRefusal(localterm.CodeLimit, fmt.Sprintf("AgentLand has %d terminals open.", terminalCapacity))
	case errors.Is(err, errTerminalProgramUnavailable):
		return localRefusal(localterm.CodeUnknownProgram, "Claude Code isn't available to AgentLand's terminals on this Mac.")
	case errors.Is(err, errTerminalsUnusable):
		return localRefusal(localterm.CodeUnavailable, terminalsUnavailableMessage)
	case errors.Is(err, errTerminalPathTooLong):
		return localRefusal(localterm.CodeUnavailable, terminalPathTooLongMessage)
	case errors.Is(err, errTerminalNotListed):
		return localRefusal(localterm.CodeNotContinuable, "This terminal's workspace was removed.")
	}
	return localRefusal(localterm.CodeUnavailable, "AgentLand could not start the new terminal.")
}

// recordContinuation records that entry goes on in the terminal id: every
// end recorded from now on names it, an end already recorded (the program
// exited meanwhile) is replaced by one that does, and so is the end the host
// remembers when the terminal was already forgotten (forgetEntry). manager.mu
// is taken before entry.mu, as rememberLocked does.
func (manager *terminalManager) recordContinuation(entry *terminalEntry, id string) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	entry.mu.Lock()
	entry.continuedIn = id
	if entry.info.Ended != nil {
		// A copy: answers already given hold the old one.
		end := *entry.info.Ended
		end.ContinuedIn = id
		entry.info.Ended = &end
		entry.notifyLocked()
	}
	from := entry.info.ID
	entry.mu.Unlock()
	if cleared, ok := manager.cleared[from]; ok && manager.entries[from] != entry && cleared.end != nil {
		end := *cleared.end
		end.ContinuedIn = id
		cleared.end = &end
		manager.cleared[from] = cleared
	}
}
