package termrun

import (
	"crypto/rand"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"agentland/host/internal/shellhook"
)

// claudePicks are Claude Code's flags (as of 2.1.301) that pick the
// conversation, or leave it to Claude Code: resume, continue, a session id
// of the user's own, a PR's or a teleported session, a cloud session, and
// a background session, which manages its own id. Each also counts as
// "--flag=value".
var claudePicks = []string{
	"--resume", "-r", "--continue", "-c", "--session-id", "--from-pr", "--teleport", "--cloud",
	"--bg", "--background",
}

// withClaudeSession has Claude Code start the conversation id it returns, so
// that AgentLand can find and resume that conversation later. A command that
// is not claude, that starts with one of its subcommands (the hook's list,
// which an older hook script may still have routed), or that picks its own
// conversation (claudePicks) keeps its arguments, and the id is empty.
func withClaudeSession(name string, args []string, newID func() string) (out []string, id string) {
	if filepath.Base(name) != "claude" {
		return args, ""
	}
	if len(args) > 0 && slices.Contains(shellhook.Subcommands("claude"), args[0]) {
		return args, ""
	}
	for _, arg := range args {
		flag, _, _ := strings.Cut(arg, "=")
		if slices.Contains(claudePicks, flag) {
			return args, ""
		}
	}
	id = newID()
	return append([]string{"--session-id", id}, args...), id
}

// newSessionID is a random version 4 UUID in lowercase, as Claude Code's
// --session-id takes and the host accepts.
func newSessionID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
