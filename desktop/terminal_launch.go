package host

import (
	"context"
	"errors"
	"maps"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// What a terminal runs, and the environment it runs in (design, "Programs and
// environment"). A terminal is the person's own: their login shell with their
// own environment, minus what AgentLand and its agents put there. Devices name
// a program, never a command; this file turns the name into one.

// terminalCommand is what the keeper starts: the program, its arguments, its
// complete environment (never nil: exec reads nil as "inherit everything"),
// and, for catalog agents, the installed version.
type terminalCommand struct {
	Path    string
	Args    []string
	Env     []string
	Version string
}

// terminalLauncher decides what each program name runs.
type terminalLauncher struct {
	// resolve finds the Mac's own opencode, claude or codex.
	resolve func(name string) (string, bool)
	// openCode is the host's OpenCode server: the URL the TUI attaches to and
	// its basic-auth credentials.
	openCode func() (url, user, password string)
	// openCodeHome is the managed OpenCode's root (serve --opencode-home).
	openCodeHome string
	// privateFolders hold AgentLand's own XDG folders, which no terminal sees.
	privateFolders []string
	// environ is the host's environment, os.Environ in production.
	environ func() []string
	// hidden names variables of environ no terminal sees: the state's
	// OpenCode password variable and serve's local session variable, which
	// may be named outside AGENTLAND_ and OPENCODE_.
	hidden func() []string
	agents *agentCatalog
}

// newHostTerminalLauncher is the host's launcher: the Mac's own programs, the
// user's environment without AgentLand's secrets, and the host's OpenCode
// for its TUI. newHost adds the agent catalog.
func newHostTerminalLauncher(store *Store, agent Agent, options HostOptions) *terminalLauncher {
	launcher := &terminalLauncher{resolve: executableForProgram, openCodeHome: options.OpenCodeHome, environ: os.Environ}
	if adapter, ok := agent.(*OpenCodeAdapter); ok {
		launcher.openCode = adapter.attachTarget
	}
	if home, err := os.UserHomeDir(); err == nil {
		launcher.privateFolders = append(launcher.privateFolders, filepath.Join(home, "Library", "Application Support", "AgentLand"))
	}
	if state, err := filepath.Abs(store.Path); err == nil {
		launcher.privateFolders = append(launcher.privateFolders, filepath.Dir(state))
	}
	hidden := slices.Clone(options.TerminalHiddenEnv)
	launcher.hidden = func() []string {
		names := slices.Clone(hidden)
		if state, err := store.Read(); err == nil && state.Config.PasswordEnv != "" {
			names = append(names, state.Config.PasswordEnv)
		}
		return names
	}
	return launcher
}

// defaultPathFolders are appended to PATH so a terminal started from a
// launchd-minimal environment still finds Homebrew's tools.
const defaultPathFolders = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

func (l *terminalLauncher) resolveProgram(name string) (string, bool) {
	if name == "opencode" {
		if command, ok := l.agents.openCodeCommand(); ok {
			return command, true
		}
	}
	if l.resolve == nil {
		return "", false
	}
	return l.resolve(name)
}

// programs is capabilities.terminalPrograms: the shell, the Mac's own
// opencode, claude and codex, then every usable catalog agent with a terminal.
func (l *terminalLauncher) programs() []string {
	programs := []string{"shell"}
	for _, name := range []string{"opencode", "claude", "codex"} {
		if _, ok := l.resolveProgram(name); ok {
			programs = append(programs, name)
		}
	}
	if l.agents == nil {
		return programs
	}
	_, _, terminals, _ := l.agents.capabilityLists()
	for _, id := range terminals {
		if !slices.Contains(programs, id) {
			programs = append(programs, id)
		}
	}
	return programs
}

// environment is the host's environment without the hidden variables.
func (l *terminalLauncher) environment() []string {
	if l.environ == nil {
		return nil
	}
	environment := slices.Clone(l.environ())
	if l.hidden == nil {
		return environment
	}
	hidden := l.hidden()
	return slices.DeleteFunc(environment, func(item string) bool {
		name, _, _ := strings.Cut(item, "=")
		return name != "" && slices.Contains(hidden, name)
	})
}

// command is what program runs for project. conversation matters for claude
// only.
func (l *terminalLauncher) command(project Project, program string, conversation *terminalConversation) (terminalCommand, error) {
	switch program {
	case "shell":
		shell := loginShell(l.environment(), dsclShell)
		return terminalCommand{Path: shell, Args: []string{"-l"}, Env: terminalEnvironment(l.environment(), l.privateFolders, nil)}, nil
	case "claude", "codex":
		path, ok := l.resolveProgram(program)
		if !ok {
			return terminalCommand{}, errors.New("terminal program is unavailable")
		}
		command := terminalCommand{Path: path, Env: terminalEnvironment(l.environment(), l.privateFolders, nil)}
		if program == "claude" && conversation != nil {
			command.Args = claudeConversationArgs(*conversation)
		}
		return command, nil
	case "opencode":
		path, ok := l.resolveProgram(program)
		if !ok || l.openCode == nil {
			return terminalCommand{}, errors.New("terminal program is unavailable")
		}
		url, user, password := l.openCode()
		extra := openCodeTUIEnvironment(user, password, l.openCodeHome)
		command := terminalCommand{Path: path, Args: []string{"attach", url, "--dir", project.Directory},
			Env: terminalEnvironment(l.environment(), l.privateFolders, extra)}
		// The managed install's version, so pruning keeps the folder this
		// terminal runs from.
		if l.agents != nil {
			if current, _ := l.agents.store.readCurrent("opencode"); current != nil {
				command.Version = current.Version
			}
		}
		return command, nil
	}
	launch, ok := l.agents.terminalLaunch(program)
	if !ok {
		return terminalCommand{}, errors.New("unsupported terminal program")
	}
	// An npx agent's PATH prefix (its Node folder) goes in front of the PATH
	// computed from the host's environment, not in place of it.
	extra, prefix := launch.Env, ""
	if _, has := extra["PATH"]; has {
		extra = maps.Clone(extra)
		delete(extra, "PATH")
		prefix = acpNodeFolder(l.agents.lookup)
	}
	command := terminalCommand{Path: launch.Command, Args: launch.Args, Env: terminalEnvironment(l.environment(), l.privateFolders, extra)}
	if prefix != "" {
		for i, item := range command.Env {
			if value, ok := strings.CutPrefix(item, "PATH="); ok {
				folders := slices.DeleteFunc(strings.Split(value, ":"), func(folder string) bool { return folder == prefix })
				command.Env[i] = "PATH=" + strings.Join(append([]string{prefix}, folders...), ":")
			}
		}
	}
	if current, _ := l.agents.store.readCurrent(program); current != nil {
		command.Version = current.Version
	} else {
		// Cached by the file, so a terminal start does not run --version each time.
		command.Version = l.agents.localVersion(launch.Command, program, true)
	}
	return command, nil
}

// terminalEnvironment is base as the person's own terminal sees it. It drops
// AgentLand's and OpenCode's variables, Claude Code's session markers, the
// chat API keys, any XDG folder inside privateFolders, and TERM; it appends
// the standard tool folders to PATH, sets TERM, and applies extra last. It
// never returns nil.
func terminalEnvironment(base []string, privateFolders []string, extra map[string]string) []string {
	result := make([]string, 0, len(base)+len(extra)+2)
	path, hasPath := "", false
	for _, item := range base {
		name, value, _ := strings.Cut(item, "=")
		switch {
		case strings.HasPrefix(name, "AGENTLAND_"), strings.HasPrefix(name, "OPENCODE_"),
			claudeSessionMarkers[name], chatAPIKeyVariables[name], name == "TERM":
			continue
		case strings.HasPrefix(name, "XDG_") && insidePrivateFolder(value, privateFolders):
			continue
		case name == "PATH":
			path, hasPath = value, true
			continue
		}
		result = append(result, item)
	}
	folders := []string{}
	if hasPath && path != "" {
		folders = strings.Split(path, ":")
	}
	for _, folder := range strings.Split(defaultPathFolders, ":") {
		if !slices.Contains(folders, folder) {
			folders = append(folders, folder)
		}
	}
	result = append(result, "PATH="+strings.Join(folders, ":"), "TERM=xterm-256color")
	for name, value := range extra {
		prefix := name + "="
		result = slices.DeleteFunc(result, func(item string) bool { return strings.HasPrefix(item, prefix) })
		result = append(result, prefix+value)
	}
	return result
}

// insidePrivateFolder reports whether value, cleaned, is one of folders or
// inside one (case-insensitive: the Mac's volumes are).
func insidePrivateFolder(value string, folders []string) bool {
	if value == "" {
		return false
	}
	value = strings.ToLower(filepath.Clean(value))
	for _, folder := range folders {
		if folder == "" {
			continue
		}
		folder = strings.ToLower(filepath.Clean(folder))
		if value == folder || strings.HasPrefix(value, folder+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// openCodeTUIEnvironment is what the OpenCode terminal adds: the server's
// credentials (read from the environment, never from arguments) and, for the
// managed OpenCode, the six variables that point the TUI at the same config
// and storage as the server. The managed config carries "autoupdate": false
// and the model, and the TUI shares the server's storage, so all six are
// needed. They are folder paths, not secrets.
func openCodeTUIEnvironment(user, password, home string) map[string]string {
	environment := map[string]string{"OPENCODE_SERVER_USERNAME": user, "OPENCODE_SERVER_PASSWORD": password}
	if home != "" {
		config := filepath.Join(home, "config")
		environment["XDG_CONFIG_HOME"] = config
		environment["XDG_DATA_HOME"] = filepath.Join(home, "data")
		environment["XDG_CACHE_HOME"] = filepath.Join(home, "cache")
		environment["XDG_STATE_HOME"] = filepath.Join(home, "state")
		environment["OPENCODE_CONFIG_DIR"] = filepath.Join(config, "opencode")
		environment["OPENCODE_CONFIG"] = filepath.Join(config, "opencode", "opencode.json")
	}
	return environment
}

// loginShell is $SHELL when it is absolute and executable; otherwise what
// lookup says the user's shell is (dsclShell in production); otherwise zsh.
func loginShell(environ []string, lookup func(user string) string) string {
	name := ""
	for _, item := range environ {
		if value, ok := strings.CutPrefix(item, "SHELL="); ok {
			if executableFile(value) {
				return value
			}
		} else if value, ok := strings.CutPrefix(item, "USER="); ok {
			name = value
		}
	}
	if name == "" {
		if current, err := user.Current(); err == nil {
			name = current.Username
		}
	}
	if lookup != nil && name != "" {
		if shell := lookup(name); executableFile(shell) {
			return shell
		}
	}
	return "/bin/zsh"
}

// executableForProgram finds the Mac's own opencode, claude or codex. The
// OpenCode terminals use the managed OpenCode first when the host keeps the
// agent catalog (resolveProgram); the Mac app ships no OpenCode of its own.
func executableForProgram(name string) (string, bool) {
	if name != "opencode" && name != "claude" && name != "codex" {
		return "", false
	}
	return findCommand(name)
}

func executableFile(candidate string) bool {
	if !filepath.IsAbs(candidate) {
		return false
	}
	info, err := os.Stat(candidate)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0
}

// dsclShell reads the user's shell from the directory service.
func dsclShell(name string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "dscl", ".", "-read", "/Users/"+name, "UserShell").Output()
	if err != nil {
		return ""
	}
	_, shell, _ := strings.Cut(strings.TrimSpace(string(out)), "UserShell:")
	return strings.TrimSpace(shell)
}
