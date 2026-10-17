package shellhook

import (
	"regexp"
	"slices"
	"strings"
)

// subcommands are, per agent command, the first arguments that start no
// interactive session (an update, a login, a server), so the hook runs them
// as they are. Every agent also has help, version and completion (the
// script adds those). An agent without an entry has only those.
//
// Claude Code's are those of 2.1.301's help, and the older config and
// migrate-installer; agents and attach open its own background sessions,
// which Claude Code runs, not AgentLand (Subcommands keeps AgentLand from
// giving any of them a session id).
var subcommands = map[string]string{
	"claude": "update upgrade mcp doctor config install migrate-installer setup-token plugin plugins " +
		"auth auto-mode agents attach logs stop kill rm respawn purge import gateway ultrareview",
	"codex":        "exec e login logout mcp mcp-server app-server proto completion debug apply a sandbox",
	"gemini":       "mcp extensions",
	"qwen":         "mcp extensions",
	"goose":        "run configure info update mcp",
	"cursor-agent": "update upgrade login logout status mcp",
	"droid":        "exec",
	"amp":          "update login logout mcp tools threads",
	"opencode":     "run serve web acp mcp models stats export import github upgrade uninstall auth agent debug",
}

// flags are, per agent command, more arguments that start no interactive
// session, besides those every agent shares (the script's _agentland_flags):
// Claude Code's --bg starts a background session and returns at once.
var flags = map[string]string{
	"claude": "--bg --background",
}

// Subcommands is every first argument of program's that the hook runs as
// it is, and that starts no conversation of the program's own: its own
// subcommands, and help, version and completion.
func Subcommands(program string) []string {
	return append(strings.Fields(subcommands[program]), "help", "version", "completion")
}

// commandName is a program the script may define a function for: a plain
// command name, since it is written into the script's code.
var commandName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

// Script is the hook file's zsh: it defines one function per program in
// programs that is installed and not already a function, which runs
// `<executable> terminals run --state <statePath> -- <name> <args>` when all
// four of the spec's conditions hold (switchFile reads "on"; stdin, stdout
// and stderr are terminals, so no redirect is ever routed; no
// AGENTLAND_TERMINAL; no non-interactive argument), and the real command
// otherwise. Functions are defined with `function NAME {…; }`, which zsh
// allows when NAME is also an alias (`NAME() {…}` it refuses); the ";" lets
// the brace close also under the user's `setopt ignore_close_braces`.
func Script(executable, statePath, switchFile string, programs []string) string {
	var names, table, own []string
	for _, program := range programs {
		if !commandName.MatchString(program) || slices.Contains(names, program) {
			continue
		}
		names = append(names, program)
		if words := subcommands[program]; words != "" {
			table = append(table, program, quote(words))
		}
		if words := flags[program]; words != "" {
			own = append(own, program, quote(words))
		}
	}
	var b strings.Builder
	b.WriteString("# AgentLand: coding agents from Terminal. Written by AgentLand; it rewrites this file.\n")
	b.WriteString("typeset -g _agentland_bin=" + quote(executable) + " _agentland_state=" + quote(statePath) + " _agentland_switch=" + quote(switchFile) + "\n")
	b.WriteString("typeset -ga _agentland_flags=(-p --print --prompt -x --execute --version -v -V --help -h)\n")
	b.WriteString("typeset -gA _agentland_subcommands=(" + strings.Join(table, " ") + ")\n")
	b.WriteString("typeset -gA _agentland_own_flags=(" + strings.Join(own, " ") + ")\n")
	b.WriteString(`_agentland_route() {
  emulate -L zsh
  local name=$1 arg; shift
  if [[ -n ${AGENTLAND_TERMINAL-} || ! -t 0 || ! -t 1 || ! -t 2 || ! -x $_agentland_bin || ! -r $_agentland_switch ]] ||
     [[ "$(<$_agentland_switch)" != on ]]; then command "$name" "$@"; return; fi
  local -a own; own=(${=_agentland_own_flags[$name]-})
  for arg in "$@"; do
    [[ $arg == -- ]] && break
    if (( ${_agentland_flags[(Ie)$arg]} || ${own[(Ie)$arg]} )) || [[ $arg == (--print|--prompt)=* ]]; then
      command "$name" "$@"; return
    fi
  done
  if [[ -n ${1-} && " ${_agentland_subcommands[$name]-} help version completion " == *" $1 "* ]]; then
    command "$name" "$@"; return
  fi
  "$_agentland_bin" terminals run --state "$_agentland_state" -- "$name" "$@"
}
`)
	b.WriteString("for _agentland_name in " + strings.Join(names, " ") + "; do\n")
	b.WriteString(`  (( $+commands[$_agentland_name] && ! $+functions[$_agentland_name] )) &&
    eval "function ${_agentland_name} { _agentland_route ${_agentland_name} \"\$@\"; }"
done
unset _agentland_name
`)
	return b.String()
}

// quote is s as one zsh word: in single quotes, where a single quote in s
// closes the quotes, is escaped with a backslash and opens them again.
func quote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
