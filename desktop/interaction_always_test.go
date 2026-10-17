package host

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"
)

// captureAlwaysLog records the unknown-shape notes of one test and resets
// the log-once memory around it.
func captureAlwaysLog(t *testing.T) func() []string {
	t.Helper()
	var mu sync.Mutex
	var lines []string
	alwaysLogged.Lock()
	previous := alwaysLogged.log
	alwaysLogged.log = func(message string) {
		mu.Lock()
		lines = append(lines, message)
		mu.Unlock()
	}
	alwaysLogged.seen = map[string]bool{}
	alwaysLogged.Unlock()
	t.Cleanup(func() {
		alwaysLogged.Lock()
		alwaysLogged.log, alwaysLogged.seen = previous, map[string]bool{}
		alwaysLogged.Unlock()
	})
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), lines...)
	}
}

const chatOnlyDetail = "What applies in this chat is not saved; it ends when Claude Code restarts for this chat, for example after 10 idle minutes."

// Golden labels for the permission_suggestions Claude Code 2.1.280 sent in
// the zero-credit probes (Bash, Write in and outside the project, Read
// outside it, WebFetch, a compound command, the contract check's touch),
// and the other destinations the Agent SDK defines.
func TestClaudeAlwaysLabels(t *testing.T) {
	logged := captureAlwaysLog(t)
	for _, test := range []struct {
		name, suggestions, label, detail string
	}{
		{"bash rule", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test *"}],"behavior":"allow","destination":"localSettings"}]`,
			"Allow Bash(npm test *) in this project", "Saved in this project's .claude/settings.local.json."},
		{"compound command", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm run *"},{"toolName":"Bash","ruleContent":"npm test *"}],"behavior":"allow","destination":"localSettings"}]`,
			"Allow Bash(npm run *) and Bash(npm test *) in this project", "Saved in this project's .claude/settings.local.json."},
		{"write in the project", `[{"type":"setMode","mode":"acceptEdits","destination":"session"}]`,
			"Switch this chat to Accept edits", ""},
		{"bypass", `[{"type":"setMode","mode":"bypassPermissions","destination":"session"}]`,
			"Switch this chat to Bypass permissions", ""},
		{"a mode Chat keeps but no longer offers", `[{"type":"setMode","mode":"dontAsk","destination":"session"}]`,
			"Switch this chat to Don't ask", ""},
		{"write outside the project", `[{"type":"setMode","mode":"acceptEdits","destination":"session"},{"type":"addDirectories","directories":["/Users/me/outside"],"destination":"session"}]`,
			"Switch this chat to Accept edits; allow access to /Users/me/outside in this chat", chatOnlyDetail},
		{"read outside the project", `[{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//private/tmp/outside/**"}],"behavior":"allow","destination":"session"}]`,
			"Allow Read(//private/tmp/outside/**) in this chat", chatOnlyDetail},
		{"web fetch", `[{"type":"addRules","destination":"localSettings","rules":[{"toolName":"WebFetch","ruleContent":"domain:example.com"}],"behavior":"allow"}]`,
			"Allow WebFetch(domain:example.com) in this project", "Saved in this project's .claude/settings.local.json."},
		{"command outside the project", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"cd /tmp && ls -la"}],"behavior":"allow","destination":"localSettings"},{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//private/tmp/**"}],"behavior":"allow","destination":"session"}]`,
			"Allow Bash(cd /tmp && ls -la) in this project; allow Read(//private/tmp/**) in this chat", "Saved in this project's .claude/settings.local.json. " + chatOnlyDetail},
		{"contract check", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch made-by-contract.txt"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/private/var/folders/3v/0lk2lspx7nl4sjylsnxswr4r0000gn/T/TestClaudeContract3555406925/001/project"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]`,
			"Allow Bash(touch made-by-contract.txt) in this project; allow access to /private/var/folders/3v…ClaudeContract3555406925/001/project in this chat; switch this chat to Accept edits", "Saved in this project's .claude/settings.local.json. " + chatOnlyDetail},
		{"tool without content", `[{"type":"addRules","rules":[{"toolName":"mcp__docs__search"}],"behavior":"allow","destination":"projectSettings"}]`,
			"Allow mcp__docs__search in this project", "Saved in this project's .claude/settings.json, which others may share."},
		{"user settings", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git status *"}],"behavior":"allow","destination":"userSettings"},{"type":"setMode","mode":"plan","destination":"userSettings"}]`,
			"Allow Bash(git status *) in all your projects; make Plan the default mode in all your projects", "Saved in your Claude Code user settings."},
		{"many rules", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"a *"},{"toolName":"Bash","ruleContent":"b *"},{"toolName":"Bash","ruleContent":"c *"},{"toolName":"Bash","ruleContent":"d *"},{"toolName":"Bash","ruleContent":"e *"}],"behavior":"allow","destination":"cliArg"}]`,
			"Allow Bash(a *), Bash(b *), Bash(c *) and 2 more in this chat", chatOnlyDetail},
		{"many changes", `[` + strings.Repeat(`{"type":"setMode","mode":"auto","destination":"session"},`, 5) + `{"type":"setMode","mode":"auto","destination":"session"}]`,
			"Switch this chat to Auto; switch this chat to Auto; switch this chat to Auto; switch this chat to Auto; and 2 more changes", ""},
		{"secrets", `[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"curl -H 'Authorization: Bearer abcdefghijkl1234' https://me:hunter2@example.com/x"},{"toolName":"Bash","ruleContent":"GITHUB_TOKEN=ghp_0123456789abcdefghijABCDEFGHIJ npm publish"}],"behavior":"allow","destination":"localSettings"}]`,
			"Allow Bash(curl -H 'Authorization: …' https://…@example.com/x) and Bash(GITHUB_TOKEN=… npm publish) in this project", "Saved in this project's .claude/settings.local.json."},
	} {
		label, detail := claudeAlways(json.RawMessage(test.suggestions))
		if label != test.label || detail != test.detail {
			t.Errorf("%s:\n got %q\n     %q\nwant %q\n     %q", test.name, label, detail, test.label, test.detail)
		}
	}
	if lines := logged(); len(lines) != 0 {
		t.Fatalf("known shapes were logged: %q", lines)
	}
}

// A shape the host does not know gives the generic label, logged once per
// shape and without its content.
func TestClaudeAlwaysUnknownShapes(t *testing.T) {
	logged := captureAlwaysLog(t)
	for _, suggestions := range []string{
		`[{"type":"replaceRules","rules":[{"toolName":"Bash","ruleContent":"SECRET-RULE"}],"behavior":"allow","destination":"localSettings"}]`,
		`[{"type":"replaceRules","rules":[{"toolName":"Bash","ruleContent":"SECRET-RULE"}],"behavior":"allow","destination":"localSettings"}]`,
		`[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"x"}],"behavior":"deny","destination":"localSettings"}]`,
		`[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"x"}],"behavior":"allow","destination":"flagSettings"}]`,
		`[{"type":"setMode","mode":"manual","destination":"session"}]`,
		`[{"type":"addRules","rules":[{"ruleContent":"no tool"}],"behavior":"allow","destination":"session"}]`,
		`[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"fine"}],"behavior":"allow","destination":"session"},{"type":"removeDirectories","directories":["/x"],"destination":"session"}]`,
		`{"type":"setMode"}`,
	} {
		if label, detail := claudeAlways(json.RawMessage(suggestions)); label != claudeAlwaysGeneric || detail != "" {
			t.Errorf("%s: %q %q", suggestions, label, detail)
		}
	}
	lines := logged()
	if len(lines) != 7 {
		t.Fatalf("each unknown shape is logged once: %q", lines)
	}
	for _, line := range lines {
		if strings.Contains(line, "SECRET-RULE") || strings.Contains(line, "/x") || !strings.Contains(line, "Claude Code offered an Always choice AgentLand cannot describe") {
			t.Fatalf("log line %q", line)
		}
	}
	if !strings.Contains(lines[0], "type=replaceRules destination=localSettings behavior=allow") {
		t.Fatalf("shape: %q", lines[0])
	}
}

// Labels stay short whatever the provider sends: one line, masked, clipped.
func TestAlwaysLabelsAreBounded(t *testing.T) {
	captureAlwaysLog(t)
	huge := strings.Repeat("cat <<EOF\nline of a file\nEOF\n", 500)
	rules := []map[string]string{}
	for index := 0; index < 3; index++ {
		rules = append(rules, map[string]string{"toolName": "Bash", "ruleContent": huge})
	}
	suggestion, _ := json.Marshal([]any{
		map[string]any{"type": "addRules", "rules": rules, "behavior": "allow", "destination": "localSettings"},
		map[string]any{"type": "addDirectories", "directories": []string{"/" + strings.Repeat("deep/", 400)}, "destination": "session"},
		map[string]any{"type": "addRules", "rules": rules, "behavior": "allow", "destination": "userSettings"},
	})
	label, detail := claudeAlways(suggestion)
	if utf8.RuneCountInString(label) > alwaysLabelLimit || utf8.RuneCountInString(detail) > alwaysDetailLimit || strings.Contains(label, "\n") || strings.Count(label, "line of a file") > 6 {
		t.Fatalf("label %d characters, detail %d: %q", utf8.RuneCountInString(label), utf8.RuneCountInString(detail), label)
	}
	if got := alwaysItem("git show 0123456789abcdef0123456789abcdef01234567"); got != "git show …" {
		t.Fatalf("hash: %q", got)
	}
	if got := alwaysItem("npm run build:prod -- --author=someone --token=abc123def"); got != "npm run build:prod -- --author=someone --token=…" {
		t.Fatalf("flags: %q", got)
	}
}

// Codex: the session approval, a saved command rule or a saved network rule.
func TestCodexAlwaysLabels(t *testing.T) {
	logged := captureAlwaysLog(t)
	session := "Not saved: Codex forgets it when it restarts, for example after 15 idle minutes."
	saved := "Codex saves this rule in its own settings."
	command := func(available string) map[string]any {
		var list []json.RawMessage
		json.Unmarshal([]byte(available), &list)
		always, _ := codexCommandDecisions(list)["always"].(map[string]any)
		return always
	}
	for _, test := range []struct {
		name, method  string
		decision      map[string]any
		label, detail string
	}{
		{"command for the session", "item/commandExecution/requestApproval", command(`["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","x"]}},"decline","cancel"]`),
			"Allow this command in this chat", session},
		{"command without a list", "item/commandExecution/requestApproval", command(``), "Allow this command in this chat", session},
		{"saved command rule", "item/commandExecution/requestApproval", command(`["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["npm","test"]}},"cancel"]`),
			`Allow commands starting with "npm test" in all projects`, saved},
		{"saved network rule", "item/commandExecution/requestApproval", command(`[{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"registry.npmjs.org","action":"allow"}}},"decline"]`),
			"Allow network access to registry.npmjs.org in all projects", saved},
		{"file changes", "item/fileChange/requestApproval", map[string]any{"decision": "acceptForSession"}, "Allow changes to these files in this chat", session},
		{"more access", "item/permissions/requestApproval", map[string]any{"permissions": json.RawMessage(`{"network":{"enabled":true}}`), "scope": "session"}, "Allow this access in this chat", session},
	} {
		label, detail := codexAlways(test.method, test.decision)
		if label != test.label || detail != test.detail {
			t.Errorf("%s:\n got %q %q\nwant %q %q", test.name, label, detail, test.label, test.detail)
		}
	}
	if lines := logged(); len(lines) != 0 {
		t.Fatalf("known shapes were logged: %q", lines)
	}
	if label, detail := codexAlways("item/commandExecution/requestApproval", map[string]any{"decision": json.RawMessage(`{"somethingNew":{}}`)}); label != codexAlwaysGeneric || detail != "" || len(logged()) != 1 {
		t.Fatalf("unknown decision: %q %q %q", label, detail, logged())
	}
}

// OpenCode permissions do not offer always in AgentLand, so they carry no
// label, whatever patterns OpenCode would allow.
func TestOpenCodePermissionsCarryNoAlwaysLabel(t *testing.T) {
	interaction := chatPermissionInteraction(PermissionRequest{ID: "per_1", SessionID: "s1", Permission: "bash", Patterns: []string{"git status"}, Details: `{"description":"Inspect"}`}, "2026-09-24T12:00:00.000Z")
	if strings.Join(interaction.Choices, ",") != "once,reject" || interaction.AlwaysLabel != "" || interaction.AlwaysDetail != "" {
		t.Fatalf("interaction: %+v", interaction)
	}
	if line := string(marshalJSONLine(interaction)); strings.Contains(line, "always") {
		t.Fatalf("encoded: %s", line)
	}
}
