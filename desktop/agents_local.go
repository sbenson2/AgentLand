package host

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Agents already on the Mac (docs/HOST-API.md "Agents"): the known CLIs,
// found like the terminal's programs, with the id each has in the catalog.
// OpenCode is not one: its entry is always the registry's managed install
// (agents_opencode.go).

type localAgentSpec struct {
	program string // the command's name
	id      string // its catalog id
	name    string
	// acp: it runs chats through ACP with the registry's arguments for its
	// id. claude and codex chat through AgentLand's own adapters.
	acp bool
}

var localAgentSpecs = []localAgentSpec{
	{program: "claude", id: "claude", name: "Claude Code"},
	{program: "codex", id: "codex", name: "Codex"},
	{program: "gemini", id: "gemini", name: "Gemini CLI", acp: true},
	{program: "qwen", id: "qwen-code", name: "Qwen Code", acp: true},
	{program: "goose", id: "goose", name: "goose", acp: true},
	{program: "copilot", id: "github-copilot-cli", name: "GitHub Copilot", acp: true},
	{program: "cursor-agent", id: "cursor", name: "Cursor", acp: true},
	{program: "kimi", id: "kimi", name: "Kimi CLI", acp: true},
	{program: "droid", id: "factory-droid", name: "Factory Droid", acp: true},
	{program: "amp", id: "amp", name: "Amp"},
	{program: "vibe", id: "vibe", name: "Mistral Vibe"},
}

// RoutedAgentPrograms is every command the zsh hook routes into `terminals
// run` (internal/shellhook): the local agents' commands, then opencode, each
// one the host takes a registration of (routedProgram).
func RoutedAgentPrograms() []string {
	programs := make([]string, 0, len(localAgentSpecs)+1)
	for _, spec := range localAgentSpecs {
		programs = append(programs, spec.program)
	}
	return append(programs, "opencode")
}

func localAgentSpecFor(id string) (localAgentSpec, bool) {
	for _, spec := range localAgentSpecs {
		if spec.id == id {
			return spec, true
		}
	}
	return localAgentSpec{}, false
}

// agentVersionWord finds the first version-like word of a --version output.
var agentVersionWord = regexp.MustCompile(`(?:^|[^0-9A-Za-z.])v?([0-9]+\.[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z][0-9A-Za-z.-]*)?)`)

func parseAgentVersion(output string) string {
	match := agentVersionWord.FindStringSubmatch(output)
	if match == nil {
		return ""
	}
	version, _ := clipText(match[1], 64)
	if !agentVersionPattern.MatchString(version) {
		return ""
	}
	return version
}

// installerKeepsVariable: installers and --version runs keep only these of
// the owner's variables.
func installerKeepsVariable(name string) bool {
	switch name {
	case "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG":
		return true
	}
	return false
}

// runAgentVersion runs `<path> --version` for at most 5 s with a clean
// environment and reads the first version-like word of its first 4 KiB.
func runAgentVersion(path string, base []string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, path, "--version")
	command.Env = agentEnvironment(base, installerKeepsVariable, "", nil)
	if home, err := os.UserHomeDir(); err == nil {
		command.Dir = home
	}
	command.SysProcAttr = claudeProcessAttributes()
	command.Cancel = func() error {
		claudeSignalGroup(command.Process, true)
		return nil
	}
	command.WaitDelay = time.Second
	output := &agentHead{limit: 4 << 10}
	command.Stdout, command.Stderr = output, output
	if command.Run() != nil && len(output.data) == 0 {
		return ""
	}
	return parseAgentVersion(string(output.data))
}

// agentHead keeps the first limit bytes written to it and drops the rest
// without failing the writer.
type agentHead struct {
	mu    sync.Mutex
	limit int
	data  []byte
}

func (h *agentHead) Write(p []byte) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if room := h.limit - len(h.data); room > 0 {
		h.data = append(h.data, p[:min(room, len(p))]...)
	}
	return len(p), nil
}

func (h *agentHead) String() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return string(h.data)
}

// agentVersionEntry caches one command's version by its file.
type agentVersionEntry struct {
	identity executableIdentity
	version  string
}

// executableIdentity follows a command symlink and retains the target's file
// identity. It changes for an atomic replacement or symlink retarget, and its
// metadata changes for an in-place rewrite.
type executableIdentity struct {
	resolved string
	info     os.FileInfo
}

func identifyExecutable(path string) (executableIdentity, bool) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return executableIdentity{}, false
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0o111 == 0 {
		return executableIdentity{}, false
	}
	return executableIdentity{resolved: resolved, info: info}, true
}

func (i executableIdentity) same(other executableIdentity) bool {
	return i.info != nil && other.info != nil && i.resolved == other.resolved &&
		os.SameFile(i.info, other.info) && i.info.Size() == other.info.Size() &&
		i.info.ModTime().Equal(other.info.ModTime())
}

type localUpdaterEntry struct {
	identity  executableIdentity
	supported bool
}

func nativeSelfUpdater(id string) bool { return id == "codex" || id == "claude" }

// updaterKeepsVariable is deliberately smaller than an agent's runtime
// environment. HOME and locale preserve the CLI's update channel and
// preferences; Claude Code's documented opt-out remains effective.
func updaterKeepsVariable(name string) bool {
	if installerKeepsVariable(name) {
		return true
	}
	switch name {
	case "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_AUTOUPDATER":
		return true
	}
	return false
}

// localUpdaterSupported checks an exact installed command with `update
// --help`, which neither CLI treats as a model request. Results are cached by
// the resolved executable's identity, never merely by its command name.
func (c *agentCatalog) localUpdaterSupported(id, path string) bool {
	supported, _ := c.localUpdaterSupportedContext(c.ctx, id, path)
	return supported
}
func (c *agentCatalog) localUpdaterSupportedContext(parent context.Context, id, path string) (bool, error) {
	if !nativeSelfUpdater(id) || path == "" {
		return false, nil
	}
	if id == "claude" && c.localUpdaterDisabled() {
		return false, nil
	}
	identity, ok := identifyExecutable(path)
	if !ok {
		return false, nil
	}
	select {
	case c.updaterGate <- struct{}{}:
	case <-parent.Done():
		return false, parent.Err()
	}
	defer func() { <-c.updaterGate }()
	c.updaterMu.Lock()
	if cached, ok := c.updaters[path]; ok && cached.identity.same(identity) {
		c.updaterMu.Unlock()
		return cached.supported, nil
	}
	c.updaterMu.Unlock()
	ctx, cancel := context.WithTimeout(parent, c.localUpdateHelpWait)
	defer cancel()
	output, err := c.runLocalUpdaterCommand(ctx, path, true)
	usageCommand := "update"
	if id == "claude" {
		usageCommand = `update(?:\|upgrade)?`
	}
	want := regexp.MustCompile(`(?mi)^usage:\s*` + regexp.QuoteMeta(id) + `\s+` + usageCommand + `(?:\s|$)`)
	supported := err == nil && want.MatchString(output)
	if parent.Err() != nil {
		return false, parent.Err()
	}
	c.updaterMu.Lock()
	defer c.updaterMu.Unlock()
	if len(c.updaters) > 16 {
		c.updaters = map[string]localUpdaterEntry{}
	}
	c.updaters[path] = localUpdaterEntry{identity: identity, supported: supported}
	return supported, nil
}

// runLocalUpdater runs only the already-probed native updater. Its caller is
// responsible for the support check and the catalog's operation lock.
func (c *agentCatalog) runLocalUpdater(ctx context.Context, id, path string) error {
	if !nativeSelfUpdater(id) {
		return errNotManaged
	}
	wait := c.localUpdateWait
	if wait <= 0 {
		wait = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	_, err := c.runLocalUpdaterCommand(ctx, path, false)
	return err
}

func (c *agentCatalog) runLocalUpdaterCommand(ctx context.Context, path string, help bool) (string, error) {
	args := []string{"update"}
	if help {
		args = append(args, "--help")
	}
	command := exec.CommandContext(ctx, path, args...)
	command.Env = agentEnvironment(c.baseEnv, updaterKeepsVariable, "", nil)
	if home, err := os.UserHomeDir(); err == nil {
		command.Dir = home
	}
	command.SysProcAttr = claudeProcessAttributes()
	command.Cancel = func() error {
		claudeSignalGroup(command.Process, true)
		return nil
	}
	command.WaitDelay = time.Second
	// Capture is bounded so a broken updater cannot consume host memory. Help
	// is inspected internally; no output is exposed or persisted because it
	// may name credentials, paths or account details.
	output := &agentHead{limit: 4 << 10}
	command.Stdout, command.Stderr = output, output
	err := command.Run()
	if ctx.Err() != nil {
		return output.String(), ctx.Err()
	}
	if err == nil {
		return output.String(), nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return output.String(), localUpdaterError(fmt.Sprintf("the updater failed (exit %d)", exit.ExitCode()))
	}
	return output.String(), localUpdaterError("the updater could not be started")
}

// localUpdaterError is why a native updater failed, in the host's own words
// (never its output), so the update log can name it.
type localUpdaterError string

func (e localUpdaterError) Error() string { return string(e) }

func (c *agentCatalog) localUpdaterDisabled() bool {
	base := c.baseEnv
	if base == nil {
		base = os.Environ()
	}
	for _, item := range base {
		name, value, _ := strings.Cut(item, "=")
		if name != "DISABLE_AUTOUPDATER" && name != "CLAUDE_CODE_DISABLE_AUTOUPDATER" {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "", "0", "false", "no", "off":
		default:
			return true
		}
	}
	return false
}

// updatesBesideRunning reports whether the agent's updates leave the files of
// a running terminal alone: a registry install keeps each version in its own
// folder, and Claude's native installer links the command into a "versions"
// folder, where each release is its own file. Codex and any other command
// update in place, so a running terminal makes them wait.
func (c *agentCatalog) updatesBesideRunning(id string) bool {
	if id != "claude" && id != "codex" {
		current, _ := c.store.readCurrent(id)
		return current != nil
	}
	path, ok := c.terminalProgramPath(id)
	if !ok {
		return false
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return false
	}
	target, err := os.Readlink(path)
	if err != nil {
		return false
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(path), target)
	}
	return filepath.Base(filepath.Dir(target)) == "versions"
}

// terminalProgramPath is the command a terminal of program would run: the
// launcher's own resolution, else the catalog's lookup.
func (c *agentCatalog) terminalProgramPath(program string) (string, bool) {
	if c.host != nil && c.host.terminals != nil && c.host.terminals.launcher != nil {
		if path, ok := c.host.terminals.launcher.resolveProgram(program); ok {
			return path, true
		}
	}
	return c.lookup(program)
}
