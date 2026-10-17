package termrun

import (
	"regexp"
	"slices"
	"testing"
)

func TestClaudeGetsASessionIDUnlessOneIsPicked(t *testing.T) {
	newID := func() string { return "0f8fad5b-d9cb-469f-a165-70867728950e" }
	out, id := withClaudeSession("claude", nil, newID)
	if id != newID() || !slices.Equal(out, []string{"--session-id", newID()}) {
		t.Fatalf("no arguments: %q, %q", out, id)
	}
	out, id = withClaudeSession("/opt/homebrew/bin/claude", []string{"fix it"}, newID)
	if id != newID() || !slices.Equal(out, []string{"--session-id", newID(), "fix it"}) {
		t.Fatalf("a prompt: %q, %q", out, id)
	}
	// A subcommand only counts first; later it is a word of the prompt.
	out, id = withClaudeSession("claude", []string{"fix", "logs"}, newID)
	if id != newID() || !slices.Equal(out, []string{"--session-id", newID(), "fix", "logs"}) {
		t.Fatalf("a prompt with a subcommand's word: %q, %q", out, id)
	}
	for _, args := range [][]string{
		{"--resume"}, {"-r", "x"}, {"--continue"}, {"-c"}, {"--session-id", "x"}, {"--session-id=x"},
		{"--model", "opus", "--resume"},
		// Claude Code 2.1.301 picks or manages the session itself here.
		{"--from-pr"}, {"--from-pr", "12"}, {"--from-pr=12"}, {"--teleport"}, {"--teleport=abc"},
		{"--cloud", "fix it"}, {"--cloud=abc"},
		{"--bg", "fix it"}, {"--model", "opus", "--background"},
		// Its subcommands start no conversation of their own.
		{"agents"}, {"attach", "x"}, {"logs", "x"}, {"stop", "x"}, {"kill", "x"}, {"rm", "x"},
		{"respawn", "--all"}, {"purge"}, {"auth", "login"}, {"auto-mode", "config"}, {"import", "codex"},
		{"gateway"}, {"ultrareview"}, {"plugin", "list"}, {"plugins"}, {"mcp", "list"}, {"update"}, {"help"},
	} {
		out, id := withClaudeSession("claude", args, newID)
		if id != "" || !slices.Equal(out, args) {
			t.Errorf("%q became %q with id %q", args, out, id)
		}
	}
	if out, id := withClaudeSession("codex", []string{"a"}, newID); id != "" || !slices.Equal(out, []string{"a"}) {
		t.Errorf("codex: %q, %q", out, id)
	}
}

// The id is a conversation id the host accepts (conversationIDPattern).
func TestNewSessionIDsAreLowercaseUUIDs(t *testing.T) {
	pattern := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	first, second := newSessionID(), newSessionID()
	if !pattern.MatchString(first) || !pattern.MatchString(second) || first == second {
		t.Fatalf("ids %q, %q", first, second)
	}
}

func TestFallbackLines(t *testing.T) {
	for code, want := range map[string]string{
		codeNoHost:              "AgentLand isn't running — started claude normally.",
		"slow_host":             "AgentLand didn't answer in time — started claude normally.",
		"terminal_disabled":     "AgentLand's terminal access is off — started claude normally.",
		"terminal_limit":        "AgentLand has 16 terminals open — started claude normally.",
		"terminals_unavailable": "AgentLand's terminal service isn't available — started claude normally.",
		"version_mismatch":      "AgentLand's terminal service isn't available — started claude normally.",
		codeNoKeeper:            "AgentLand's terminal service isn't available — started claude normally.",
		"program_unknown":       "AgentLand couldn't take this terminal — started claude normally.",
		"":                      "AgentLand couldn't take this terminal — started claude normally.",
	} {
		if got := fallbackLine(code, "claude"); got != want {
			t.Errorf("%q: %q, want %q", code, got, want)
		}
	}
	if got := fallbackLine(codeNoHost, "/usr/local/bin/codex"); got != "AgentLand isn't running — started codex normally." {
		t.Errorf("a path: %q", got)
	}
}
