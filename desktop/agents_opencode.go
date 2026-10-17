package host

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
)

// OpenCode (docs/HOST-API.md "OpenCode"). Owner's decision, 2026-09-27: the
// Mac app ships no OpenCode of its own and runs the managed one in
// <state>.agents/opencode. OpenCode's catalog entry is always a registry
// agent. While no managed OpenCode is valid, the host installs the
// registry's at once: when serve starts (no 2-minute wait and no idle wait,
// since nothing of OpenCode's can run yet), at each automatic update run
// until it has one, and in `agentland-host install-opencode`. Installed so is
// only a binary checked by the registry's sha256; any other download waits
// for the owner's Install, with lastError. Once installed, OpenCode updates
// as every registry agent does. It cannot be uninstalled: AgentLand's chats
// need it.

var (
	errOpenCodeMissing = errors.New("no managed OpenCode is installed")
	errAgentRequired   = errors.New("AgentLand needs this agent")
)

// openCodeReasonLimit bounds the Mac app's words on why OpenCode did not
// start (POST /v1/agents/opencode/failed).
const openCodeReasonLimit = 600

// The Mac app's limits on current.json and on the program it runs.
const (
	openCodeRecordLimit  = 64 << 10
	openCodeProgramLimit = 1 << 30
)

// managedOpenCode is the managed OpenCode when opencode/current.json passes
// the catalog's checks (readCurrent) and the Mac app's (its
// OpenCodeBinaryLocator): the agents folder, opencode/ and every folder down
// to the program are real folders of this user's that no one else can open;
// the record is a regular file of this user's that no one else can change,
// at most 64 KiB, with a sha256; the command resolves, links followed, to a
// regular executable file inside opencode/ that is this user's and that no
// one else can change, at most 1 GiB, whose SHA-256 is the record's. The
// error says why not: errOpenCodeMissing when there is no record.
func (s agentStore) managedOpenCode() (*agentCurrent, error) {
	const id = "opencode"
	record, err := os.Lstat(s.currentPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, errOpenCodeMissing
	}
	if err != nil {
		return nil, errors.New("its record could not be read")
	}
	for _, folder := range []string{s.root, s.agentDir(id)} {
		if !privateAgentFolderAt(folder) {
			return nil, errors.New("a folder of it is not private to this user")
		}
	}
	if !record.Mode().IsRegular() || !changedOnlyByUser(record) || record.Size() > openCodeRecordLimit {
		return nil, errors.New("its record is not a file only this user can change")
	}
	current, err := s.readCurrent(id)
	if err != nil || current == nil {
		return nil, errors.New("its record or its files are missing or damaged")
	}
	if err := s.openCodeProgramProblem(*current); err != nil {
		return nil, err
	}
	return current, nil
}

// openCodeProgramProblem checks the program an OpenCode record names, as
// the Mac app does: the record has a sha256; its command resolves, links
// followed, to a regular executable file inside opencode/, of this user's
// that no one else can change, at most 1 GiB, whose SHA-256 is the
// record's; every folder on the way is a private folder of this user's.
func (s agentStore) openCodeProgramProblem(record agentCurrent) error {
	const id = "opencode"
	sum := strings.ToLower(record.SHA256)
	if !validSHA256(sum) {
		return errors.New("its record has no sha256")
	}
	root, err := filepath.EvalSymlinks(s.agentDir(id))
	if err != nil {
		return errors.New("its folder could not be read")
	}
	program, err := filepath.EvalSymlinks(record.Command)
	if err != nil {
		return errors.New("its program is missing")
	}
	relative, err := filepath.Rel(root, program)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || filepath.IsAbs(relative) {
		return errors.New("its program is outside its folder")
	}
	folder := root
	parts := strings.Split(relative, string(filepath.Separator))
	for _, part := range parts[:len(parts)-1] {
		folder = filepath.Join(folder, part)
		if !privateAgentFolderAt(folder) {
			return errors.New("a folder of it is not private to this user")
		}
	}
	info, err := os.Lstat(program)
	if err != nil || !info.Mode().IsRegular() || !changedOnlyByUser(info) || !runnableByOwner(info) {
		return errors.New("its program is not one only this user can change")
	}
	if info.Size() > openCodeProgramLimit {
		return errors.New("its program is larger than 1 GiB")
	}
	if got, err := sameFileSHA256(program, info); err != nil || got != sum {
		return errors.New("its program does not match the sha256 in its record")
	}
	return nil
}

// sameFileSHA256 is the SHA-256 of the file at path, only when it is still
// the file info describes.
func sameFileSHA256(path string, info os.FileInfo) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(opened, info) {
		return "", errors.New("the file changed while it was read")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, io.LimitReader(file, openCodeProgramLimit+1)); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// openCodeFailure is why the registry's OpenCode was not installed, with the
// code install-opencode reports (docs/HOST-API.md "install-opencode").
type openCodeFailure struct {
	code, message string
}

func (f *openCodeFailure) Error() string { return f.message }

// networkUnreachable reports a failure to reach a server at all: its name
// did not resolve, a connection failed or broke, or it did not answer in
// time.
func networkUnreachable(err error) bool {
	var dns *net.DNSError
	var operation *net.OpError
	var timeout interface{ Timeout() bool }
	return errors.As(err, &dns) || errors.As(err, &operation) || errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &timeout) && timeout.Timeout())
}

// registryFailure words a registry read that failed with no copy kept.
func registryFailure(err error) *openCodeFailure {
	if networkUnreachable(err) {
		return &openCodeFailure{code: "offline", message: "The registry could not be reached; check this Mac's connection to the internet."}
	}
	return &openCodeFailure{code: "registry_unavailable", message: agentFetchMessage(err)}
}

// hasRegistry reports a registry document the catalog can install from.
func (c *agentCatalog) hasRegistry() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.document) > 0
}

// installObserver hears how an install goes; install-opencode reports it.
type installObserver interface {
	readingRegistry()
	downloading(version string, received, total int64)
	checking(version string)
}

// ensureOpenCode makes sure a managed OpenCode is valid: it answers the
// version of the one there is, or reads the registry and installs the
// registry's OpenCode (installOpenCode).
func (c *agentCatalog) ensureOpenCode(ctx context.Context) (string, error) {
	if current, err := c.store.managedOpenCode(); err == nil {
		return current.Version, nil
	}
	if c.observer != nil {
		c.observer.readingRegistry()
	}
	return c.installOpenCode(ctx, c.refresh(ctx))
}

// installOpenCode installs the registry's OpenCode unless a managed one is
// valid, from the registry the catalog holds (read just before, with
// readErr): a binary checked by the registry's sha256 only, through
// Install's path (installVersion: the download, OpenCode's check, then
// current.json). A record that fails the checks is replaced. A failure other
// than another change of OpenCode running or the host stopping is kept as
// OpenCode's lastError.
func (c *agentCatalog) installOpenCode(ctx context.Context, readErr error) (string, error) {
	const id = "opencode"
	if current, err := c.store.managedOpenCode(); err == nil {
		return current.Version, nil
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if !c.hasRegistry() {
		failure := &openCodeFailure{code: "registry_unavailable", message: "The registry has not been read yet."}
		if readErr != nil {
			failure = registryFailure(readErr)
		}
		return "", c.refuseOpenCode(failure)
	}
	registry, ok := c.registryEntry(id)
	if !ok {
		return "", c.refuseOpenCode(&openCodeFailure{code: "registry_unavailable", message: "The registry lists no OpenCode."})
	}
	dist, ok := registry.choose(c.platform)
	switch {
	case !ok:
		return "", c.refuseOpenCode(&openCodeFailure{code: "unsupported_platform", message: "OpenCode " + registry.Version + " offers nothing that runs on this Mac."})
	case dist.Kind != "binary" || !dist.Verified:
		return "", c.refuseOpenCode(&openCodeFailure{code: "unverified_download", message: "OpenCode " + registry.Version + " has no checksum in the registry; install it by hand to accept it."})
	}
	op, err := c.beginOp(id, "install")
	if err != nil {
		return "", &openCodeFailure{code: "busy", message: "OpenCode is being changed now; try again when that ends."}
	}
	defer c.endOp(id, op)
	current, problem := c.store.managedOpenCode()
	switch {
	case problem == nil:
		// Another change installed it meanwhile.
		return current.Version, nil
	case !errors.Is(problem, errOpenCodeMissing):
		// A record that fails the checks is set aside, so the registry's
		// version installs afresh (installVersion keeps a current version).
		if err := os.Remove(c.store.currentPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", c.refuseOpenCode(&openCodeFailure{code: "storage_error", message: "The damaged OpenCode record could not be replaced."})
		}
	}
	if err := c.installVersion(ctx, id, registry, dist, false); err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", openCodeInstallFailure(err)
	}
	current, err = c.store.managedOpenCode()
	if err != nil {
		return "", c.refuseOpenCode(&openCodeFailure{code: "storage_error", message: "The installed OpenCode does not pass the checks: " + err.Error() + "."})
	}
	return current.Version, nil
}

// refuseOpenCode keeps failure as OpenCode's lastError and returns it.
func (c *agentCatalog) refuseOpenCode(failure *openCodeFailure) error {
	if c.store.ensureAgentDir("opencode") == nil {
		_ = c.store.setStatus("opencode", failure.message, c.now())
	}
	return failure
}

// openCodeFailedResult answers POST /v1/agents/opencode/failed.
type openCodeFailedResult struct {
	RolledBack bool   `json:"rolledBack"`
	Current    string `json:"current"`
}

// openCodeDidNotStart takes the Mac app's word that the managed OpenCode at
// version did not start on this Mac, for reason. When version is the
// current one: it goes back to the previous version when that one is kept
// and intact (its program passes the Mac app's checks, sha256 included),
// remembers version so automatic updates skip it until the registry offers
// another (failed.json), and says so in lastError. Another version changes
// nothing. errAgentChangeBusy while another change of OpenCode runs.
func (c *agentCatalog) openCodeDidNotStart(version, reason string) (openCodeFailedResult, error) {
	const id = "opencode"
	current, _ := c.store.readCurrent(id)
	if current == nil || !sameAgentVersion(current.Version, version) {
		return openCodeFailedResult{Current: versionOf(current)}, nil
	}
	op, err := c.beginOp(id, "rollback")
	if err != nil {
		return openCodeFailedResult{Current: current.Version}, errAgentChangeBusy
	}
	defer c.endOp(id, op)
	current, _ = c.store.readCurrent(id)
	if current == nil || !sameAgentVersion(current.Version, version) {
		return openCodeFailedResult{Current: versionOf(current)}, nil
	}
	if err := c.store.setFailed(id, current.Version, c.now()); err != nil {
		return openCodeFailedResult{Current: current.Version}, err
	}
	message := "OpenCode " + current.Version + " did not start on this Mac"
	if reason = strings.TrimRight(oneLine(withoutHomes(reason, c.homeFolders())), ". "); reason != "" {
		message += ": " + reason
	}
	result := openCodeFailedResult{Current: current.Version}
	if previous := current.Previous; previous != nil && c.store.openCodeProgramProblem(*previous) == nil {
		back := *previous
		back.Previous = nil
		if err := c.store.writeCurrent(id, back); err == nil {
			result = openCodeFailedResult{RolledBack: true, Current: back.Version}
			message += ". Back to " + back.Version
		}
	}
	message, _ = clipText(message+".", 1000)
	_ = c.store.setStatus(id, message, c.now())
	return result, nil
}

// versionOf is the record's version, "" without one.
func versionOf(record *agentCurrent) string {
	if record == nil {
		return ""
	}
	return record.Version
}

// oneLine turns control characters (line breaks among them) into spaces.
func oneLine(text string) string {
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, text))
}

// skipsOpenCode reports whether automatic updates skip the registry's
// OpenCode version: one the Mac app said did not start. Once the registry
// offers another version, the one remembered is forgotten.
func (c *agentCatalog) skipsOpenCode(version string) bool {
	failed := c.store.readFailed("opencode")
	if failed == "" {
		return false
	}
	if sameAgentVersion(failed, version) {
		return true
	}
	_ = c.store.setFailed("opencode", "", c.now())
	return false
}

// openCodeInstallFailure gives a failed installVersion its code: the step
// that failed, and offline when the download could not reach its server.
// installVersion kept its lastError.
func openCodeInstallFailure(err error) *openCodeFailure {
	var install *agentInstallError
	if !errors.As(err, &install) {
		return &openCodeFailure{code: "storage_error", message: err.Error()}
	}
	switch {
	case install.step == stepCheck:
		return &openCodeFailure{code: "check_failed", message: install.message}
	case install.step == stepDownload && networkUnreachable(err):
		return &openCodeFailure{code: "offline", message: install.message}
	case install.step == stepDownload:
		return &openCodeFailure{code: "download_failed", message: install.message}
	}
	return &openCodeFailure{code: "storage_error", message: install.message}
}
