package host

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// What "always" grants, in words. A permission interaction that offers
// always carries alwaysLabel (and alwaysDetail when there is more to say),
// built by the host from what the provider will actually apply, so a card
// can name it instead of a bare "Always Allow":
//
//   - Claude Code: its permission_suggestions, which always passes back as
//     updatedPermissions (rules and where they are saved, mode switches,
//     extra folders).
//   - Codex: the session approval (acceptForSession), a saved command rule
//     (acceptWithExecpolicyAmendment) or a saved network rule.
//
// Labels never hold secrets: rule text, commands, hosts and folders pass
// through maskAlwaysSecrets, one line each, clipped. A shape the host does
// not know gives a generic label and is logged once.

const (
	alwaysLabelLimit   = 200 // characters
	alwaysDetailLimit  = 300
	alwaysItemLimit    = 60
	alwaysItemsShown   = 3
	alwaysClausesShown = 4
	alwaysLoggedShapes = 64

	claudeAlwaysGeneric = "Allow and apply Claude Code's suggested permission changes"
	codexAlwaysGeneric  = "Allow as Codex offers for later requests"
)

// alwaysLogged remembers the shapes already logged; log receives the note
// (the host's stderr; tests replace it under the lock).
var alwaysLogged = struct {
	sync.Mutex
	seen map[string]bool
	log  func(string)
}{seen: map[string]bool{}, log: func(message string) { os.Stderr.WriteString("agentland-host: " + message + "\n") }}

// noteUnknownAlways logs an unknown shape once per provider and shape. The
// shape names only identifiers (types, destinations), never rule text.
func noteUnknownAlways(provider, shape string) {
	key := provider + "\x00" + shape
	alwaysLogged.Lock()
	seen := alwaysLogged.seen[key] || len(alwaysLogged.seen) >= alwaysLoggedShapes
	if !seen {
		alwaysLogged.seen[key] = true
	}
	log := alwaysLogged.log
	alwaysLogged.Unlock()
	if !seen {
		log(fmt.Sprintf("%s offered an Always choice AgentLand cannot describe (%s); its card shows a generic label", provider, shape))
	}
}

// alwaysIdentifier makes a provider's type or destination name safe to log.
func alwaysIdentifier(value string) string {
	value = strings.Map(func(r rune) rune {
		if r == '_' || r == '-' || r == ':' || r == '.' || unicode.IsLetter(r) || unicode.IsDigit(r) {
			return r
		}
		return -1
	}, value)
	if value == "" {
		return "none"
	}
	return clipRunes(value, 40)
}

// Secrets.

// alwaysSecretKey matches a name that says its value is secret: GITHUB_TOKEN,
// x-api-key, password, client_secret (not "author" or "tokenizer").
const alwaysSecretKey = `[A-Za-z0-9_.-]*?(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|authorization|auth|credential)s?(?:[_-][A-Za-z0-9_-]*)?`

// alwaysSecretValue is the value after such a name: a quoted string, a
// "Bearer <token>" pair or one word.
const alwaysSecretValue = `((?:bearer|basic|token)\s+[^\s"'&;|)]+|"[^"]*"|'[^']*'|[^\s"'&;|)]+)`

var alwaysSecretPatterns = []struct {
	pattern *regexp.Regexp
	replace string
}{
	// user:password@ or token@ in a URL.
	{regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@`), "${1}…@"},
	// key=value and key: value where the key names a secret.
	{regexp.MustCompile(`(?i)(` + alwaysSecretKey + `)(\s*[=:]\s*)` + alwaysSecretValue), "${1}${2}…"},
	// --password value and the like.
	{regexp.MustCompile(`(?i)(--?` + alwaysSecretKey + `)(\s+)` + alwaysSecretValue), "${1}${2}…"},
	// Authorization values on their own.
	{regexp.MustCompile(`(?i)\b(bearer|basic|token)(\s+)[A-Za-z0-9._~+/=-]{8,}`), "${1}${2}…"},
	// Well-known token formats.
	{regexp.MustCompile(`\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})`), "…"},
}

// alwaysOpaque finds long runs that look like keys or hashes (a path's
// slashes end a run).
var alwaysOpaque = regexp.MustCompile(`[A-Za-z0-9+=_-]{32,}`)

// maskAlwaysSecrets replaces what looks like a password, token or key with
// "…".
func maskAlwaysSecrets(text string) string {
	for _, rule := range alwaysSecretPatterns {
		text = rule.pattern.ReplaceAllString(text, rule.replace)
	}
	return alwaysOpaque.ReplaceAllStringFunc(text, func(run string) string {
		letters, digits := false, false
		for _, r := range run {
			letters = letters || unicode.IsLetter(r)
			digits = digits || unicode.IsDigit(r)
		}
		if letters && digits {
			return "…"
		}
		return run
	})
}

// Text.

func clipRunes(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	return string([]rune(text)[:limit-1]) + "…"
}

// alwaysItem is one rule, command, host or folder: secrets masked, on one
// line, and at most alwaysItemLimit characters, keeping its start and end.
func alwaysItem(text string) string {
	text = maskAlwaysSecrets(strings.Join(strings.Fields(strings.ToValidUTF8(text, "")), " "))
	runes := []rune(text)
	if len(runes) <= alwaysItemLimit {
		return text
	}
	head := (alwaysItemLimit - 1) * 2 / 5
	tail := alwaysItemLimit - 1 - head
	return string(runes[:head]) + "…" + string(runes[len(runes)-tail:])
}

// alwaysList names up to alwaysItemsShown items: "a, b and c", "a, b, c and
// 2 more".
func alwaysList(items []string) string {
	shown := make([]string, 0, min(len(items), alwaysItemsShown))
	for _, item := range items[:min(len(items), alwaysItemsShown)] {
		shown = append(shown, alwaysItem(item))
	}
	if rest := len(items) - len(shown); rest > 0 {
		return strings.Join(shown, ", ") + fmt.Sprintf(" and %d more", rest)
	}
	if len(shown) > 1 {
		return strings.Join(shown[:len(shown)-1], ", ") + " and " + shown[len(shown)-1]
	}
	return strings.Join(shown, "")
}

// alwaysSentence joins clauses into one sentence starting with a capital.
func alwaysSentence(clauses []string) string {
	shown := clauses[:min(len(clauses), alwaysClausesShown)]
	text := strings.Join(shown, "; ")
	if rest := len(clauses) - len(shown); rest > 0 {
		text += fmt.Sprintf("; and %d more changes", rest)
	}
	if first, size := utf8.DecodeRuneInString(text); size > 0 {
		text = string(unicode.ToUpper(first)) + text[size:]
	}
	return text
}

func boundedAlways(label, detail string) (string, string) {
	return clipRunes(label, alwaysLabelLimit), clipRunes(detail, alwaysDetailLimit)
}

// Claude Code.

// claudeSuggestion is one entry of permission_suggestions (an Agent SDK
// PermissionUpdate).
type claudeSuggestion struct {
	Type  string `json:"type"`
	Rules []struct {
		ToolName    string `json:"toolName"`
		RuleContent string `json:"ruleContent"`
	} `json:"rules"`
	Behavior    string   `json:"behavior"`
	Destination string   `json:"destination"`
	Mode        string   `json:"mode"`
	Directories []string `json:"directories"`
}

// claudeAlwaysScopes: where each destination applies, in the label.
var claudeAlwaysScopes = map[string]string{
	"session":         "in this chat",
	"cliArg":          "in this chat",
	"localSettings":   "in this project",
	"projectSettings": "in this project",
	"userSettings":    "in all your projects",
}

// claudeAlwaysSaved: where each saving destination writes, for the detail.
var claudeAlwaysSaved = map[string]string{
	"localSettings":   "Saved in this project's .claude/settings.local.json.",
	"projectSettings": "Saved in this project's .claude/settings.json, which others may share.",
	"userSettings":    "Saved in your Claude Code user settings.",
}

// claudeAlways describes what answering always does with these
// suggestions. Every suggestion must be understood; otherwise the label is
// generic.
func claudeAlways(raw json.RawMessage) (string, string) {
	var suggestions []claudeSuggestion
	if json.Unmarshal(raw, &suggestions) != nil || len(suggestions) == 0 {
		noteUnknownAlways("Claude Code", "suggestions that are not a list")
		return boundedAlways(claudeAlwaysGeneric, "")
	}
	clauses, details := []string{}, []string{}
	noted := map[string]bool{}
	chatOnly := false
	for _, suggestion := range suggestions {
		scope, known := claudeAlwaysScopes[suggestion.Destination]
		chat := suggestion.Destination == "session" || suggestion.Destination == "cliArg"
		clause := ""
		switch {
		case !known:
		case suggestion.Type == "addRules" && suggestion.Behavior == "allow" && len(suggestion.Rules) > 0:
			rules := make([]string, 0, len(suggestion.Rules))
			for _, rule := range suggestion.Rules {
				if strings.TrimSpace(rule.ToolName) == "" {
					rules = nil
					break
				}
				text := rule.ToolName
				if rule.RuleContent != "" {
					text += "(" + rule.RuleContent + ")"
				}
				rules = append(rules, text)
			}
			if rules != nil {
				clause = "allow " + alwaysList(rules) + " " + scope
				chatOnly = chatOnly || chat
			}
		case suggestion.Type == "addDirectories" && len(suggestion.Directories) > 0:
			clause = "allow access to " + alwaysList(suggestion.Directories) + " " + scope
			chatOnly = chatOnly || chat
		case suggestion.Type == "setMode":
			if mode, ok := claudeModeNamed(suggestion.Mode); ok {
				// The chat keeps a mode Claude Code switches it to.
				clause = "switch this chat to " + mode.Name
				if !chat {
					clause = "make " + mode.Name + " the default mode " + scope
				}
			}
		}
		if clause == "" {
			noteUnknownAlways("Claude Code", "type="+alwaysIdentifier(suggestion.Type)+" destination="+alwaysIdentifier(suggestion.Destination)+" behavior="+alwaysIdentifier(suggestion.Behavior))
			return boundedAlways(claudeAlwaysGeneric, "")
		}
		clauses = append(clauses, clause)
		if saved := claudeAlwaysSaved[suggestion.Destination]; saved != "" && !noted[saved] {
			noted[saved] = true
			details = append(details, saved)
		}
	}
	if chatOnly {
		details = append(details, fmt.Sprintf("What applies in this chat is not saved; it ends when Claude Code restarts for this chat, for example after %d idle minutes.", int(claudeIdleStop.Minutes())))
	}
	return boundedAlways(alwaysSentence(clauses), strings.Join(details, " "))
}

// Codex.

// codexAlways describes the decision always sends for an approval request
// (method), from the decisions codexRequest offers.
func codexAlways(method string, decision map[string]any) (string, string) {
	session := fmt.Sprintf("Not saved: Codex forgets it when it restarts, for example after %d idle minutes.", int(codexIdleStop.Minutes()))
	saved := "Codex saves this rule in its own settings."
	switch method {
	case "item/fileChange/requestApproval":
		return boundedAlways("Allow changes to these files in this chat", session)
	case "item/permissions/requestApproval":
		return boundedAlways("Allow this access in this chat", session)
	case "item/commandExecution/requestApproval":
		var raw json.RawMessage
		switch value := decision["decision"].(type) {
		case string:
			raw, _ = json.Marshal(value)
		case json.RawMessage:
			raw = value
		}
		var name string
		if json.Unmarshal(raw, &name) == nil {
			if name == "acceptForSession" {
				return boundedAlways("Allow this command in this chat", session)
			}
			noteUnknownAlways("Codex", "decision="+alwaysIdentifier(name))
			return boundedAlways(codexAlwaysGeneric, "")
		}
		var object struct {
			Execpolicy *struct {
				Amendment []string `json:"execpolicy_amendment"`
			} `json:"acceptWithExecpolicyAmendment"`
			Network *struct {
				Amendment struct {
					Host   string `json:"host"`
					Action string `json:"action"`
				} `json:"network_policy_amendment"`
			} `json:"applyNetworkPolicyAmendment"`
		}
		_ = json.Unmarshal(raw, &object)
		switch {
		case object.Execpolicy != nil && len(object.Execpolicy.Amendment) > 0:
			return boundedAlways("Allow commands starting with \""+alwaysItem(strings.Join(object.Execpolicy.Amendment, " "))+"\" in all projects", saved)
		case object.Network != nil && object.Network.Amendment.Action == "allow" && object.Network.Amendment.Host != "":
			return boundedAlways("Allow network access to "+alwaysItem(object.Network.Amendment.Host)+" in all projects", saved)
		}
		noteUnknownAlways("Codex", "decision object")
		return boundedAlways(codexAlwaysGeneric, "")
	}
	noteUnknownAlways("Codex", "request="+alwaysIdentifier(method))
	return boundedAlways(codexAlwaysGeneric, "")
}
