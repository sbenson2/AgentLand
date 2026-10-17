package host

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Installs, updates and uninstalls (docs/HOST-API.md "Installs, updates and
// uninstalls"): each registry install lives in <state>.agents/<id>/<version>/
// beside the current one until it passed its check; current.json then names
// it and keeps the one before as previous.

var (
	errUnknownAgent        = errors.New("unknown agent")
	errAgentChangeBusy     = errors.New("the agent is busy")
	errNotManaged          = errors.New("the agent is not managed by AgentLand")
	errUnsupportedPlatform = errors.New("nothing the registry offers runs on this Mac")
	errUnverifiedDownload  = errors.New("the download has no checksum")
)

// requestInstall starts installing id (POST /v1/agents/install).
func (c *agentCatalog) requestInstall(id string, allowUnverified bool) (agentView, error) {
	return c.requestChange("install", id, allowUnverified)
}

func (c *agentCatalog) requestUpdate(id string, allowUnverified bool) (agentView, error) {
	return c.requestChange("update", id, allowUnverified)
}

func (c *agentCatalog) requestUninstall(id string) (agentView, error) {
	return c.requestChange("uninstall", id, false)
}

// knownAgent reports an id the catalog lists.
func (c *agentCatalog) knownAgent(id string) (agentView, bool) {
	if c == nil || !agentIDPattern.MatchString(id) {
		return agentView{}, false
	}
	return c.agent(id, false)
}

func (c *agentCatalog) requestChange(kind, id string, allowUnverified bool) (agentView, error) {
	view, known := c.knownAgent(id)
	if !known {
		return agentView{}, errUnknownAgent
	}
	if id == "claude" || id == "codex" {
		if kind != "update" || !view.usable || !c.localUpdaterSupported(id, view.local) {
			return view, errNotManaged
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return view, errAgentChangeBusy
		}
		if op := c.ops[id]; op != nil {
			c.mu.Unlock()
			if op.kind == "update" {
				view.State = "updating"
				return view, nil
			}
			return view, errAgentChangeBusy
		}
		c.mu.Unlock()
		if c.busyForUpdate(id) {
			return view, errAgentChangeBusy
		}
		op, updateCtx, err := c.beginUpdate(id)
		if err != nil {
			return view, err
		}
		if c.busyForUpdate(id) {
			c.endOp(id, op)
			return view, errAgentChangeBusy
		}
		if !c.background(func() {
			outcome := c.localUpdate(updateCtx, id, view.local)
			op.err = outcome.err
			c.endOp(id, op)
			c.logUpdate(id, "manual", outcome)
		}) {
			c.endOp(id, op)
			return view, errAgentChangeBusy
		}
		view.State = "updating"
		view.AutoUpdates = c.automaticUpdates()
		return view, nil
	}
	if id == "opencode" && kind == "uninstall" {
		return view, errAgentRequired
	}
	current := view.current
	// Installing an agent installed at another version updates it, by the
	// update's rules: refused while the agent is busy.
	if kind == "install" && current != nil {
		kind = "update"
	}
	registry, inRegistry := c.registryEntry(id)
	if current == nil && (view.Source == "local" || view.Source == "bundled") && kind != "install" {
		return view, errNotManaged
	}
	if kind == "install" && !inRegistry {
		if view.Source == "local" || view.Source == "bundled" {
			return view, errNotManaged
		}
		return view, errUnknownAgent
	}
	var dist agentDistribution
	if kind != "uninstall" && inRegistry {
		var ok bool
		if dist, ok = registry.choose(c.platform); !ok {
			if kind == "install" || (current != nil && !sameAgentVersion(current.Version, registry.Version)) {
				return view, errUnsupportedPlatform
			}
		}
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return view, errAgentChangeBusy
	}
	if op := c.ops[id]; op != nil {
		c.mu.Unlock()
		if op.kind == kind && kind != "uninstall" {
			return view, nil
		}
		return view, errAgentChangeBusy
	}
	c.mu.Unlock()
	switch kind {
	case "install":
		if !dist.Verified && !allowUnverified {
			return view, errUnverifiedDownload
		}
	case "update":
		if current == nil || !inRegistry || sameAgentVersion(current.Version, registry.Version) {
			return view, nil
		}
		if c.busyForUpdate(id) {
			return view, errAgentChangeBusy
		}
		if !dist.Verified && !current.Unverified && !allowUnverified {
			return view, errUnverifiedDownload
		}
	case "uninstall":
		if current == nil && view.LastError == "" {
			if _, err := os.Stat(c.store.agentDir(id)); errors.Is(err, os.ErrNotExist) {
				return view, nil
			}
		}
		if c.busy(id) {
			return view, errAgentChangeBusy
		}
	}
	op, err := c.beginOp(id, kind)
	if err != nil {
		return view, err
	}
	if kind != "install" && ((kind == "update" && c.busyForUpdate(id)) || (kind == "uninstall" && c.busy(id))) {
		c.endOp(id, op)
		return view, errAgentChangeBusy
	}
	unverified := !dist.Verified && (allowUnverified || (current != nil && current.Unverified))
	c.background(func() {
		switch kind {
		case "uninstall":
			c.uninstall(id)
			c.endOp(id, op)
		default:
			op.err = c.installVersion(c.ctx, id, registry, dist, unverified)
			c.endOp(id, op)
			if kind == "update" {
				outcome := updateOutcome{before: current.Version, after: registry.Version, err: op.err}
				if op.err != nil {
					outcome.after = current.Version
				}
				c.logUpdate(id, "manual", outcome)
			}
		}
	})
	view.State = map[string]string{"install": "installing", "update": "updating", "uninstall": "uninstalling"}[kind]
	return view, nil
}

// beginOp claims the agent for one change at a time.
func (c *agentCatalog) beginOp(id, kind string) (*agentOp, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.ops[id] != nil {
		return nil, errAgentChangeBusy
	}
	op := &agentOp{kind: kind, done: make(chan struct{})}
	c.ops[id] = op
	return op, nil
}

// beginUpdate claims the agent for a native or automatic update that a
// launch may stop (agents_terminal.go): its context ends with the catalog or
// at op.stop.
func (c *agentCatalog) beginUpdate(id string) (*agentOp, context.Context, error) {
	ctx, stop := context.WithCancelCause(c.ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.ops[id] != nil {
		stop(nil)
		return nil, nil, errAgentChangeBusy
	}
	op := &agentOp{kind: "update", done: make(chan struct{}), stop: stop}
	c.ops[id] = op
	return op, ctx, nil
}

func (c *agentCatalog) endOp(id string, op *agentOp) {
	c.mu.Lock()
	if c.ops[id] == op {
		delete(c.ops, id)
	}
	c.mu.Unlock()
	if op.stop != nil {
		op.stop(nil)
	}
	close(op.done)
}

// busy reports one of the agent's chat turns or terminals running.
func (c *agentCatalog) busy(id string) bool {
	if c.agentBusyFor != nil {
		return c.agentBusyFor(id)
	}
	if c.host == nil {
		return false
	}
	return c.host.agentBusy(id)
}

// busyForUpdate is busy for an update: an agent that installs each version
// beside the old one does not wait for its terminals.
func (c *agentCatalog) busyForUpdate(id string) bool {
	switch {
	case c.agentBusyFor != nil:
		return c.agentBusyFor(id)
	case c.host != nil:
		return c.host.agentBusyForUpdate(id)
	}
	return false
}

// automaticBusy is busyForUpdate for an automatic update the caller has
// already found due and possible. One skipped for running terminals is
// remembered (deferred) so the catalog can say so.
func (c *agentCatalog) automaticBusy(id string) bool {
	busy := c.busyForUpdate(id)
	if busy {
		c.markDeferred(id)
	}
	return busy
}

// markDeferred remembers an update waiting for the agent's running terminals.
func (c *agentCatalog) markDeferred(id string) {
	if c.host != nil && !c.updatesBesideRunning(id) && len(c.host.runningTerminalVersions(id)) > 0 {
		c.mu.Lock()
		c.deferred[id] = true
		c.mu.Unlock()
	}
}

// updateDue reports an automatic update that would run if the agent were
// idle: a local CLI whose updater is supported, or a registry agent with a
// different version.
func (c *agentCatalog) updateDue(ctx context.Context, id string) bool {
	if id == "claude" || id == "codex" {
		spec, _ := localAgentSpecFor(id)
		path, ok := c.lookup(spec.program)
		if !ok {
			return false
		}
		supported, err := c.localUpdaterSupportedContext(ctx, id, path)
		return err == nil && supported
	}
	current, _ := c.store.readCurrent(id)
	registry, ok := c.registryEntry(id)
	return current != nil && ok && !sameAgentVersion(registry.Version, current.Version)
}

// undefer forgets that an update waited for terminals.
func (c *agentCatalog) undefer(id string) {
	c.mu.Lock()
	delete(c.deferred, id)
	c.mu.Unlock()
}

// uninstall stops the agent's idle chat processes and removes its folder.
func (c *agentCatalog) uninstall(id string) {
	if c.host != nil && c.host.cliChats != nil {
		c.host.cliChats.acp.stopAgent(id)
	}
	if err := c.store.removeAgent(id); err != nil {
		_ = c.store.setStatus(id, "The agent's files could not all be removed.", c.now())
	}
}

// The steps of an install whose failure agentInstallError names.
const (
	stepStorage  = "storage"  // the agent's folders or its record
	stepDownload = "download" // the download, its checksum, the archive or the installer
	stepCheck    = "check"    // the new version's check
)

// agentInstallError is a failed install, update or check: the step that
// failed and what lastError says, keeping the error behind it (a network
// failure, for one).
type agentInstallError struct {
	step    string
	message string
	cause   error
}

func (e *agentInstallError) Error() string { return e.message }
func (e *agentInstallError) Unwrap() error { return e.cause }

// causedError is a message for the owner that keeps the error behind it.
type causedError struct {
	message string
	cause   error
}

func (e causedError) Error() string { return e.message }
func (e causedError) Unwrap() error { return e.cause }

// failInstall records why an install, update or check failed, with paths
// under the home folder written as ~; a stop of the host records nothing.
func (c *agentCatalog) failInstall(ctx context.Context, id, step string, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	message, _ := clipText(withoutHomes(err.Error(), c.homeFolders()), 1000)
	_ = c.store.setStatus(id, message, c.now())
	return &agentInstallError{step: step, message: message, cause: err}
}

// installVersion installs registry's version of id beside the current one,
// checks it, and makes it current, keeping the one before as previous. On
// failure the new folder goes and lastError says why. Versions are compared
// without case, as their folders are: the current version is never installed
// again, and the previous one is made current again rather than installed
// over, so neither folder is ever removed here.
func (c *agentCatalog) installVersion(ctx context.Context, id string, registry registryAgent, dist agentDistribution, unverified bool) error {
	if err := c.store.ensureAgentDir(id); err != nil {
		return c.failInstall(ctx, id, stepStorage, causedError{"The agent's folder could not be made.", err})
	}
	previous, _ := c.store.readCurrent(id)
	if previous != nil && sameAgentVersion(previous.Version, registry.Version) {
		return nil
	}
	if previous != nil && previous.Previous != nil && sameAgentVersion(previous.Previous.Version, registry.Version) {
		return c.restorePrevious(ctx, id, *previous)
	}
	// Only a leftover of an earlier attempt can have this name.
	folder := c.store.versionDir(id, registry.Version)
	if err := os.RemoveAll(folder); err != nil {
		return c.failInstall(ctx, id, stepStorage, causedError{"An earlier folder of this version could not be removed.", err})
	}
	if err := os.Mkdir(folder, 0o700); err != nil || os.Chmod(folder, 0o700) != nil {
		return c.failInstall(ctx, id, stepStorage, causedError{"The version's folder could not be made.", err})
	}
	step := stepDownload
	current, err := c.installInto(ctx, id, registry, dist, folder)
	if err == nil {
		current.Version, current.Name, current.Unverified = registry.Version, registry.Name, unverified
		step = stepCheck
		err = c.check(ctx, id, current)
	}
	if err != nil {
		_ = os.RemoveAll(folder)
		return c.failInstall(ctx, id, step, err)
	}
	current.InstalledAt = chatTimeOf(c.now())
	if previous != nil {
		kept := *previous
		kept.Previous = nil
		current.Previous = &kept
	}
	if err := c.makeCurrent(ctx, id, current); err != nil {
		_ = os.RemoveAll(folder)
		return c.failInstall(ctx, id, stepStorage, causedError{"The install record could not be saved.", err})
	}
	return nil
}

// restorePrevious makes the version kept for going back current again, when
// the registry names it: it is checked as a new version is, and the current
// one is kept as previous. Nothing is downloaded and no folder is removed
// before the switch.
func (c *agentCatalog) restorePrevious(ctx context.Context, id string, current agentCurrent) error {
	back := *current.Previous
	back.Previous = nil
	if err := c.check(ctx, id, back); err != nil {
		return c.failInstall(ctx, id, stepCheck, err)
	}
	kept := current
	kept.Previous = nil
	back.Previous = &kept
	back.InstalledAt = chatTimeOf(c.now())
	if err := c.makeCurrent(ctx, id, back); err != nil {
		return c.failInstall(ctx, id, stepStorage, causedError{"The install record could not be saved.", err})
	}
	return nil
}

// makeCurrent records current in current.json, then removes the folders it
// no longer keeps and clears lastError. OpenCode also keeps the version the
// host's OpenCode runs until the Mac app restarts it.
func (c *agentCatalog) makeCurrent(ctx context.Context, id string, current agentCurrent) error {
	if err := c.store.writeCurrent(id, current); err != nil {
		return err
	}
	keep := []string{current.Version}
	if current.Previous != nil {
		keep = append(keep, current.Previous.Version)
	}
	// A running terminal keeps the version it runs.
	held, holdAll := c.host.pruneHold(id)
	keep = append(keep, held...)
	c.undefer(id)
	if id == "opencode" {
		keep = append(keep, c.runningOpenCodeVersion(ctx))
	}
	if !holdAll {
		_ = c.store.prune(id, keep...)
	}
	_ = c.store.setStatus(id, "", c.now())
	return nil
}

// installInto puts the distribution into folder and says how to run it.
func (c *agentCatalog) installInto(ctx context.Context, id string, registry registryAgent, dist agentDistribution, folder string) (agentCurrent, error) {
	switch dist.Kind {
	case "binary":
		return c.installBinary(ctx, id, registry.Version, dist.Binary, folder)
	case "npx":
		return c.installNPM(ctx, dist.Package, folder)
	case "uvx":
		return c.installUV(ctx, dist.Package, folder)
	}
	return agentCurrent{}, errUnsupportedPlatform
}

func randomSuffix() string {
	var random [8]byte
	_, _ = rand.Read(random[:])
	return hex.EncodeToString(random[:])
}

func (c *agentCatalog) installBinary(ctx context.Context, id, version string, binary registryBinary, folder string) (agentCurrent, error) {
	archive := filepath.Join(c.store.agentDir(id), ".download-"+randomSuffix())
	defer os.Remove(archive)
	var progress func(received, total int64)
	if c.observer != nil {
		progress = func(received, total int64) { c.observer.downloading(version, received, total) }
	}
	sum, err := c.fetcher.download(ctx, binary.Archive, archive, c.archiveLimit, progress)
	switch {
	case errors.Is(err, errAgentTooLarge):
		return agentCurrent{}, fmt.Errorf("The download is larger than %d MiB.", c.archiveLimit>>20)
	case errors.Is(err, errAgentNotHTTPS):
		return agentCurrent{}, errors.New("The download was sent to an address that is not https.")
	case errors.Is(err, errAgentBadStatus):
		message, _ := clipText(err.Error(), 200)
		return agentCurrent{}, errors.New("The download failed: " + message + ".")
	case err != nil:
		return agentCurrent{}, causedError{"The download could not be completed.", err}
	}
	if binary.SHA256 != "" && sum != binary.SHA256 {
		return agentCurrent{}, errors.New("The download's SHA-256 does not match the registry's; nothing was unpacked.")
	}
	if err := unpackAgentArchive(archive, binary.Format, folder, c.unpackLimits); err != nil {
		message, _ := clipText(err.Error(), 300)
		return agentCurrent{}, errors.New("The archive was refused: " + message + ".")
	}
	command, err := resolveAgentCmd(folder, binary.Cmd)
	if err != nil {
		return agentCurrent{}, errors.New("The download does not hold its command: " + err.Error() + ".")
	}
	fileSum, err := fileSHA256(command)
	if err != nil {
		return agentCurrent{}, errors.New("The command could not be read.")
	}
	return agentCurrent{Command: command, Args: append([]string{}, binary.Args...), SHA256: fileSum, Kind: "binary", Env: binary.Env}, nil
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// runInstaller runs npm or uv in folder with a clean environment and a time
// limit; the last 4 KiB of what it said explain a failure.
func (c *agentCatalog) runInstaller(ctx context.Context, tool, folder, pathPrefix string, extra map[string]string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, c.installWait)
	defer cancel()
	command := exec.CommandContext(ctx, tool, args...)
	command.Dir = folder
	command.Env = agentEnvironment(c.baseEnv, installerKeepsVariable, pathPrefix, extra)
	command.SysProcAttr = claudeProcessAttributes()
	command.Cancel = func() error {
		claudeSignalGroup(command.Process, true)
		return nil
	}
	command.WaitDelay = 5 * time.Second
	output := newCodexRing(4 << 10)
	command.Stdout, command.Stderr = output, output
	err := command.Run()
	if ctx.Err() != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("%s did not finish within %d minutes.", filepath.Base(tool), int(c.installWait/time.Minute))
		}
		return ctx.Err()
	}
	if err != nil {
		return fmt.Errorf("%s failed: %s", filepath.Base(tool), installerFailure(output.tail()))
	}
	return nil
}

// installerFailure is the line that says why npm or uv failed, cut to 300
// characters: npm's first error line that gives a reason, else the last line
// the tool wrote other than npm's notice of its log file.
func installerFailure(output string) string {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	for _, line := range lines {
		if reason, ok := npmErrorReason(line); ok {
			reason, _ = clipText(reason, 300)
			return reason
		}
	}
	for index := len(lines) - 1; index >= 0; index-- {
		if line := strings.TrimSpace(lines[index]); line != "" && !npmLogNotice(line) {
			line, _ = clipText(line, 300)
			return line
		}
	}
	return "no output"
}

// npmErrorReason is the text of an npm error line ("npm error …", "npm ERR!
// …" before npm 7) that gives a reason: not the lines naming the error's
// code, errno, syscall, path, dest or file, not a bare status, and not the
// notice of npm's log file or its path.
func npmErrorReason(line string) (string, bool) {
	line = strings.TrimSpace(line)
	var text string
	switch {
	case strings.HasPrefix(line, "npm error "):
		text = strings.TrimSpace(strings.TrimPrefix(line, "npm error "))
	case strings.HasPrefix(line, "npm ERR! "):
		text = strings.TrimSpace(strings.TrimPrefix(line, "npm ERR! "))
	default:
		return "", false
	}
	word, _, _ := strings.Cut(text, " ")
	switch word {
	case "", "code", "errno", "syscall", "path", "dest", "file":
		return "", false
	}
	if _, err := strconv.Atoi(text); err == nil || npmLogNotice(text) || filepath.IsAbs(text) {
		return "", false
	}
	return text, true
}

// npmLogNotice is npm's line about its log file, which only names a path.
func npmLogNotice(text string) bool {
	return strings.Contains(text, "A complete log of this run can be found in") || strings.Contains(text, "Log files were not written")
}

// homeFolders are the home folders whose paths are written as ~ in what
// devices read: this user's, and the HOME the installers run with.
func (c *agentCatalog) homeFolders() []string {
	var homes []string
	add := func(home string) {
		if home == "" || !filepath.IsAbs(home) {
			return
		}
		home = filepath.Clean(home)
		if home == string(filepath.Separator) || slices.Contains(homes, home) {
			return
		}
		homes = append(homes, home)
	}
	if home, err := os.UserHomeDir(); err == nil {
		add(home)
	}
	for _, item := range c.baseEnv {
		if name, value, _ := strings.Cut(item, "="); name == "HOME" {
			add(value)
		}
	}
	// A home inside another is replaced first.
	sort.Slice(homes, func(i, j int) bool { return len(homes[i]) > len(homes[j]) })
	return homes
}

// withoutHomes writes every path under one of homes as ~/…, so a host path
// under the Mac user's home never reaches a device in lastError.
func withoutHomes(text string, homes []string) string {
	for _, home := range homes {
		var out strings.Builder
		start := 0
		for {
			found := strings.Index(text[start:], home)
			if found < 0 {
				out.WriteString(text[start:])
				break
			}
			index, end := start+found, start+found+len(home)
			whole := (index == 0 || !pathNameByte(text[index-1])) && (end == len(text) || text[end] == '/' || !pathNameByte(text[end]))
			out.WriteString(text[start:index])
			if whole {
				out.WriteString("~")
			} else {
				out.WriteString(home)
			}
			start = end
		}
		text = out.String()
	}
	return text
}

// pathNameByte continues a file name: a home followed or preceded by one is
// part of another name.
func pathNameByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '.' || b == '_' || b == '-' || b >= 0x80
}

var agentBinName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

// npmMainBin is the package's main bin: its only one, or the one named like
// the package without its scope.
func npmMainBin(packageName string, raw json.RawMessage) (string, bool) {
	unscoped := packageName
	if index := strings.LastIndex(unscoped, "/"); index >= 0 {
		unscoped = unscoped[index+1:]
	}
	var single string
	if json.Unmarshal(raw, &single) == nil && single != "" {
		return unscoped, agentBinName.MatchString(unscoped)
	}
	var bins map[string]string
	if json.Unmarshal(raw, &bins) != nil || len(bins) == 0 {
		return "", false
	}
	names := make([]string, 0, len(bins))
	for name := range bins {
		if agentBinName.MatchString(name) && name != "." && name != ".." {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	switch {
	case len(names) == 1:
		return names[0], true
	case len(names) == 0:
		return "", false
	}
	for _, name := range names {
		if name == unscoped {
			return name, true
		}
	}
	return "", false
}

func (c *agentCatalog) installNPM(ctx context.Context, pkg registryPackage, folder string) (agentCurrent, error) {
	npm, ok := c.lookup("npm")
	if !ok {
		return agentCurrent{}, errors.New("npm (Node.js) was not found on this Mac; install Node.js and try again.")
	}
	node := acpNodeFolder(c.lookup)
	if node == "" {
		node = filepath.Dir(npm)
	}
	prefix := filepath.Dir(npm)
	if node != prefix {
		prefix = node + string(os.PathListSeparator) + prefix
	}
	if err := c.runInstaller(ctx, npm, folder, prefix, nil, "install", "--prefix", folder, "--no-audit", "--no-fund", pkg.Package); err != nil {
		return agentCurrent{}, err
	}
	manifest, err := os.ReadFile(filepath.Join(folder, "node_modules", filepath.FromSlash(pkg.Name), "package.json"))
	if err != nil {
		return agentCurrent{}, errors.New("npm did not install the package.")
	}
	var fields struct {
		Bin json.RawMessage `json:"bin"`
	}
	_ = json.Unmarshal(manifest, &fields)
	bin, ok := npmMainBin(pkg.Name, fields.Bin)
	if !ok {
		return agentCurrent{}, errors.New("The package names no command to run.")
	}
	command := filepath.Join(folder, "node_modules", ".bin", bin)
	if info, err := os.Stat(command); err != nil || !info.Mode().IsRegular() {
		return agentCurrent{}, errors.New("npm did not install the package's command.")
	}
	return agentCurrent{Command: command, Args: append([]string{}, pkg.Args...), Kind: "npx", Env: pkg.Env}, nil
}

// normalPythonName compares Python package and script names.
func normalPythonName(name string) string {
	return strings.NewReplacer("_", "-", ".", "-").Replace(strings.ToLower(name))
}

func (c *agentCatalog) installUV(ctx context.Context, pkg registryPackage, folder string) (agentCurrent, error) {
	uv, ok := c.lookup("uv")
	if !ok {
		return agentCurrent{}, errors.New("uv was not found on this Mac; install uv and try again.")
	}
	tools, bins := filepath.Join(folder, "tools"), filepath.Join(folder, "bin")
	extra := map[string]string{"UV_TOOL_DIR": tools, "UV_TOOL_BIN_DIR": bins}
	if err := c.runInstaller(ctx, uv, folder, filepath.Dir(uv), extra, "tool", "install", pkg.Package); err != nil {
		return agentCurrent{}, err
	}
	entries, err := os.ReadDir(bins)
	if err != nil {
		return agentCurrent{}, errors.New("uv did not install the tool's command.")
	}
	var names []string
	for _, entry := range entries {
		info, err := os.Stat(filepath.Join(bins, entry.Name()))
		if err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 && agentBinName.MatchString(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	chosen := ""
	switch {
	case len(names) == 1:
		chosen = names[0]
	default:
		for _, name := range names {
			if normalPythonName(name) == normalPythonName(pkg.Name) {
				chosen = name
			}
		}
	}
	if chosen == "" {
		return agentCurrent{}, errors.New("The tool names no single command to run.")
	}
	return agentCurrent{Command: filepath.Join(bins, chosen), Args: append([]string{}, pkg.Args...), Kind: "uvx", Env: pkg.Env}, nil
}

// check starts the new version before it becomes current: ACP initialize,
// or OpenCode's stronger check.
func (c *agentCatalog) check(ctx context.Context, id string, current agentCurrent) error {
	if id == "opencode" {
		if c.observer != nil {
			c.observer.checking(current.Version)
		}
		if c.openCodeCheck != nil {
			return c.openCodeCheck(ctx, current.Command, current.Version)
		}
		return checkOpenCode(ctx, current.Command, current.Version, c.openCodeWait, c.baseEnv, c.store.agentDir(id))
	}
	if c.checkACPFor != nil {
		return c.checkACPFor(ctx, id, current)
	}
	launch := acpLaunchSpec{name: current.Name, command: current.Command, args: current.Args, env: current.Env}
	if current.Kind == "npx" {
		launch.pathPrefix = acpNodeFolder(c.lookup)
	}
	return checkACPInitialize(ctx, launch, filepath.Dir(current.Command), agentEnvironment(c.baseEnv, acpKeepsVariable, launch.pathPrefix, launch.env), c.checkWait)
}
