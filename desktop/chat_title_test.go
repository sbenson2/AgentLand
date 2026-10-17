package host

import (
	"strings"
	"testing"
)

func TestFreeChatTitle(t *testing.T) {
	cases := []struct{ name, text, want string }{
		{"owner's prompt", "save it, first lets check terminal interaction and make sure the user can strool in the terminal correctly. i test ed opencode and i couldnt scrool up and down in the terminal.", "Check terminal interaction and make sure the…"},
		{"question", "can you fix the login redirect on safari?", "Fix the login redirect on safari"},
		{"typos", "pls fix teh buld its broken again", "Fix teh buld its broken again"},
		{"run-on lowercase", "ok so now i want to add a dark mode toggle to the settings screen and also make the tab bar translucent", "Add a dark mode toggle to the settings screen…"},
		{"stacked fillers", "Hey, hi. OK so just maybe look at why the tests hang", "Look at why the tests hang"},
		{"curly apostrophe", "I’d like to rename the workspace picker", "Rename the workspace picker"},
		{"would like", "I would like to see the archive sorted by date", "See the archive sorted by date"},
		{"go ahead", "go ahead and merge the branch into main", "Merge the branch into main"},
		{"we need to", "we need to handle the offline banner", "Handle the offline banner"},
		{"let us", "let us try the other approach again", "Try the other approach again"},
		{"make sure leading", "make sure the tests still pass", "The tests still pass"},
		{"fillers only lead", "fix the bug and then run tests", "Fix the bug and then run tests"},
		{"yes", "yes", ""},
		{"continue", "continue", ""},
		{"status", "status?", ""},
		{"keep going", "keep going", ""},
		{"yes keep going", "yes, keep going", ""},
		{"ok", "ok", ""},
		{"too few long words", "do it on a PR", ""},
		{"empty", "", ""},
		{"code only", "```go\nfunc main() {}\n```", ""},
		{"code dropped", "why does this fail?\n```\npanic: assignment to entry in nil map\n```\nit happens on startup", "Why does this fail"},
		{"unclosed code", "```\nthe build fails with this error text", ""},
		{"tilde fence", "~~~\nnot the name here at all\n~~~\nrename the terminal tabs please", "Rename the terminal tabs please"},
		{"inline code", "rename `parseTitle` to cleanTitle", "Rename parseTitle to cleanTitle"},
		{"url", "look at https://github.com/example/agentland/pull/12 and fix the review comments", "Look at github.com and fix the review comments"},
		{"url at sentence end", "the page https://example.com/docs/setup. is broken", "The page example.com"},
		{"www url", "check www.apple.com/ios for the new rules", "Check www.apple.com for the new rules"},
		{"file url", "open file:///Users/me/notes/plan.md and summarize it", "Open plan.md and summarize it"},
		{"absolute path", "update /Users/me/Developer/AgentLand/desktop/host.go to handle titles", "Update host.go to handle titles"},
		{"relative path", "in desktop/chat_hub.go the title is lost", "In chat_hub.go the title is lost"},
		{"dot path", "why does ./scripts/build-host.sh fail here", "Why does build-host.sh fail here"},
		{"home path", "read ~/notes/todo.md and plan the week", "Read todo.md and plan the week"},
		{"quoted path", "fix \"src/app/main.ts\" now please", "Fix \"main.ts\" now please"},
		{"not a path", "tests and/or docs need updates", "Tests and/or docs need updates"},
		{"folder without extension", "clean up src/lib before the release", "Clean up src/lib before the release"},
		{"list mark", "- fix the parser\n- add tests", "Fix the parser"},
		{"numbered list", "1. fix the parser crash", "Fix the parser crash"},
		{"heading", "## Terminal scrolling broken on iPad", "Terminal scrolling broken on iPad"},
		{"trailing colon", "fix this error:\n```\npanic\n```", "Fix this error"},
		{"first word with capitals", "iOS build fails on launch", "iOS build fails on launch"},
		{"first letter not a letter", "3 tests fail after the merge", "3 tests fail after the merge"},
		{"semicolons", "ok; yes; update the readme for the host", "Update the readme for the host"},
		{"exclamation", "stop! revert the last commit now", "Revert the last commit now"},
		{"ellipsis", "hmm… the sidebar flickers when scrolling", "The sidebar flickers when scrolling"},
		{"one long word", strings.Repeat("a", 60) + " bbb ccc", strings.Repeat("A", 1) + strings.Repeat("a", 46) + "…"},
		{"cut at a boundary", "Make the terminal tab names describe what was most recently worked on", "Make the terminal tab names describe what was…"},
		{"exactly 48", "abcd efgh ijkl mnop qrst uvwx yzab cdef ghij klm", "Abcd efgh ijkl mnop qrst uvwx yzab cdef ghij klm"},
		{"49 cut to the boundary", "abcd efgh ijkl mnop qrst uvwx yzab cdef ghij klmn", "Abcd efgh ijkl mnop qrst uvwx yzab cdef ghij…"},
		{"no words of three letters", "a b c d e f", ""},
		{"crlf", "ok\r\nplease rename the chat tabs", "Rename the chat tabs"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := freeChatTitle(c.text)
			if got != c.want {
				t.Fatalf("freeChatTitle(%q) = %q, want %q", c.text, got, c.want)
			}
			if count := len([]rune(got)); count > 48 {
				t.Fatalf("%d characters", count)
			}
		})
	}
}

func TestCleanDeviceTitle(t *testing.T) {
	cases := []struct{ name, raw, want string }{
		{"plain", "Fix login redirect", "Fix login redirect"},
		{"straight quotes", `"Fix login redirect"`, "Fix login redirect"},
		{"curly quotes", "“Fix login redirect”", "Fix login redirect"},
		{"single quotes", "'Fix login'", "Fix login"},
		{"mixed quotes", "\"Fix login”", "Fix login"},
		{"nested quotes", "\"'Fix login'\"", "Fix login"},
		{"guillemets", "«Fix login»", "Fix login"},
		{"backticks", "`Fix login`", "Fix login"},
		{"trailing period", "Fix the login redirect.", "Fix the login redirect"},
		{"quoted with period", "\"Fix the login redirect.\"", "Fix the login redirect"},
		{"period after quotes", "\"Fix the login redirect\".", "Fix the login redirect"},
		{"ellipsis kept", "Fix the login...", "Fix the login..."},
		{"unicode ellipsis kept", "Fix the login…", "Fix the login…"},
		{"control characters", "Fix\x00 the\tlogin\nredirect\x7f", "Fix the login redirect"},
		{"white space", "   Fix   the  login   ", "Fix the login"},
		{"leading quote only", "'90s music player", "'90s music player"},
		{"inner quotes kept", `Fix "login" flow`, `Fix "login" flow`},
		{"only quotes", `""`, ""},
		{"only a period", ".", ""},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := cleanDeviceTitle(c.raw); got != c.want {
				t.Fatalf("cleanDeviceTitle(%q) = %q, want %q", c.raw, got, c.want)
			}
		})
	}
}

func TestChatTitleSources(t *testing.T) {
	defaults := []string{"", "  ", "New chat", "new chat", " NEW CHAT ", "OpenCode chat", "Claude Code chat", "Codex chat", "Claude Code", "Claude", "Codex", "OpenCode", "Continued chat",
		"Claude chat", "ChatGPT chat", "ChatGPT", " chatgpt CHAT ",
		"New session - 2026-09-26T10:00:00.000Z", "Child session - 2026-09-26T10:00:00.123Z"}
	for _, title := range defaults {
		if got := titleSourceFor(title); got != "default" {
			t.Errorf("titleSourceFor(%q) = %q, want default", title, got)
		}
	}
	providers := []string{"Fix login redirect", "New session", "New session - yesterday", "new session - 2026-09-26T10:00:00.000Z", "New session - 2026-09-26T10:00:00Z", "Fixture", "Nightly dependency check", "Codex review", "ChatGPT review", "Claude chat notes"}
	for _, title := range providers {
		if got := titleSourceFor(title); got != "provider" {
			t.Errorf("titleSourceFor(%q) = %q, want provider", title, got)
		}
	}
}
