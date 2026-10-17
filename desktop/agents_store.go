package host

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The catalog's files (docs/HOST-API.md "Installs, updates and uninstalls"):
// <state>.agents (0700) holds the registry's last good copy, the icons and a
// folder per managed agent with its versions, current.json and status.json.

type agentStore struct{ root string }

func (s agentStore) registryPath() string { return filepath.Join(s.root, "registry.json") }
func (s agentStore) iconDir() string      { return filepath.Join(s.root, ".icons") }
func (s agentStore) agentDir(id string) string {
	return filepath.Join(s.root, id)
}
func (s agentStore) versionDir(id, version string) string {
	return filepath.Join(s.root, id, version)
}
func (s agentStore) currentPath(id string) string { return filepath.Join(s.root, id, "current.json") }
func (s agentStore) statusPath(id string) string  { return filepath.Join(s.root, id, "status.json") }
func (s agentStore) failedPath(id string) string  { return filepath.Join(s.root, id, "failed.json") }

// agentCurrent is current.json: the version in use and how to run it, with
// the version kept for going back.
type agentCurrent struct {
	Version     string            `json:"version"`
	Command     string            `json:"command"`
	Args        []string          `json:"args"`
	SHA256      string            `json:"sha256,omitempty"`
	InstalledAt string            `json:"installedAt"`
	Kind        string            `json:"kind"`
	Name        string            `json:"name,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
	Unverified  bool              `json:"unverified"`
	Previous    *agentCurrent     `json:"previous,omitempty"`
}

// agentStatus is status.json: the last failure, kept across restarts.
type agentStatus struct {
	LastError string `json:"lastError,omitempty"`
	At        string `json:"at,omitempty"`
	UpdatedAt string `json:"updatedAt,omitempty"`
}

// agentFailed is failed.json: a version the Mac app said did not start,
// which automatic updates skip until the registry offers another.
type agentFailed struct {
	Version string `json:"version"`
	At      string `json:"at,omitempty"`
}

// agentRegistryCache is registry.json: the last good document with its ETag.
type agentRegistryCache struct {
	ETag      string          `json:"etag,omitempty"`
	FetchedAt string          `json:"fetchedAt,omitempty"`
	Document  json.RawMessage `json:"document"`
}

func (s agentStore) ensureRoot() error {
	// ensurePrivateStateDirectory makes the parent of the path it is given.
	if err := ensurePrivateStateDirectory(filepath.Join(s.root, "x")); err != nil {
		return err
	}
	return privateAgentFolder(s.root)
}

// privateAgentFolder makes a folder of the agents' 0700 when it is a folder
// of this user's and not a link (the Mac app trusts a managed OpenCode only
// under folders that are); anything else is an error.
func privateAgentFolder(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || !agentFolderOwned(info) {
		return errors.New("an agents folder is not a private folder of this user")
	}
	if info.Mode().Perm() != 0o700 {
		return os.Chmod(path, 0o700)
	}
	return nil
}

func (s agentStore) readRegistry() (agentRegistryCache, error) {
	data, err := readPrivateState(s.registryPath())
	if err != nil {
		return agentRegistryCache{}, err
	}
	var cache agentRegistryCache
	if err := json.Unmarshal(data, &cache); err != nil {
		return agentRegistryCache{}, err
	}
	return cache, nil
}

func (s agentStore) writeRegistry(cache agentRegistryCache) error {
	data, err := json.Marshal(cache)
	if err != nil {
		return err
	}
	return writePrivateState(s.registryPath(), append(data, '\n'))
}

// validCurrent checks a current.json record read back: its version, its
// kind and a command inside its version's folder that still exists.
func (s agentStore) validCurrent(id string, current *agentCurrent) bool {
	if current == nil || !validAgentVersion(current.Version) || (current.Kind != "binary" && current.Kind != "npx" && current.Kind != "uvx") || !filepath.IsAbs(current.Command) {
		return false
	}
	relative, err := filepath.Rel(s.versionDir(id, current.Version), current.Command)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return false
	}
	info, err := os.Stat(current.Command)
	return err == nil && info.Mode().IsRegular()
}

// readCurrent answers the agent's current.json, or nil when it has none. A
// previous version whose files are gone is dropped.
func (s agentStore) readCurrent(id string) (*agentCurrent, error) {
	data, err := readPrivateState(s.currentPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var current agentCurrent
	if err := json.Unmarshal(data, &current); err != nil {
		return nil, err
	}
	if !s.validCurrent(id, &current) {
		return nil, errors.New("the installed files are missing or damaged")
	}
	if current.Previous != nil && !s.validCurrent(id, current.Previous) {
		current.Previous = nil
	}
	if current.Previous != nil {
		current.Previous.Previous = nil
	}
	if current.Args == nil {
		current.Args = []string{}
	}
	return &current, nil
}

func (s agentStore) writeCurrent(id string, current agentCurrent) error {
	if current.Args == nil {
		current.Args = []string{}
	}
	if current.Previous != nil {
		previous := *current.Previous
		previous.Previous = nil
		if previous.Args == nil {
			previous.Args = []string{}
		}
		current.Previous = &previous
	}
	data, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return err
	}
	return writePrivateState(s.currentPath(id), append(data, '\n'))
}

func (s agentStore) readStatus(id string) agentStatus {
	data, err := readPrivateState(s.statusPath(id))
	if err != nil {
		return agentStatus{}
	}
	var status agentStatus
	_ = json.Unmarshal(data, &status)
	return status
}

// setStatus keeps lastError for the agent; "" removes it.
func (s agentStore) setStatus(id, lastError string, now time.Time) error {
	if lastError == "" {
		err := os.Remove(s.statusPath(id))
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	data, err := json.Marshal(agentStatus{LastError: lastError, At: chatTimeOf(now)})
	if err != nil {
		return err
	}
	return writePrivateState(s.statusPath(id), append(data, '\n'))
}

// setLocalUpdateStatus records the last successful native self-update and
// the latest failure independently. A later failure does not erase when the
// updater last succeeded; a success clears the failure.
func (s agentStore) setLocalUpdateStatus(id string, updateErr error, now time.Time) error {
	if err := s.ensureAgentDir(id); err != nil {
		return err
	}
	status := s.readStatus(id)
	if updateErr == nil {
		status.LastError, status.At, status.UpdatedAt = "", "", chatTimeOf(now)
	} else {
		status.LastError, status.At = updateErr.Error(), chatTimeOf(now)
	}
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	return writePrivateState(s.statusPath(id), append(data, '\n'))
}

// readFailed is the version failed.json names, "" when there is none.
func (s agentStore) readFailed(id string) string {
	data, err := readPrivateState(s.failedPath(id))
	if err != nil {
		return ""
	}
	var failed agentFailed
	if json.Unmarshal(data, &failed) != nil || !validAgentVersion(failed.Version) {
		return ""
	}
	return failed.Version
}

// setFailed remembers version as one that did not start; "" forgets it.
func (s agentStore) setFailed(id, version string, now time.Time) error {
	if version == "" {
		err := os.Remove(s.failedPath(id))
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	data, err := json.Marshal(agentFailed{Version: version, At: chatTimeOf(now)})
	if err != nil {
		return err
	}
	return writePrivateState(s.failedPath(id), append(data, '\n'))
}

// agentIDs lists the folders of agents that have one (installed, failed or
// being installed).
func (s agentStore) agentIDs() []string {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return nil
	}
	var ids []string
	for _, entry := range entries {
		if entry.IsDir() && agentIDPattern.MatchString(entry.Name()) {
			ids = append(ids, entry.Name())
		}
	}
	sort.Strings(ids)
	return ids
}

// sameAgentVersion compares versions as their folders are named: macOS
// compares names without case, so 1.0.0-RC1 and 1.0.0-rc1 are one folder,
// and one version.
func sameAgentVersion(a, b string) bool { return strings.EqualFold(a, b) }

// prune removes every version folder and leftover of the agent except the
// versions named in keep (compared without case), current.json, status.json
// and failed.json.
func (s agentStore) prune(id string, keep ...string) error {
	entries, err := os.ReadDir(s.agentDir(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	kept := map[string]bool{"current.json": true, "status.json": true, "failed.json": true}
	for _, version := range keep {
		if version != "" {
			kept[strings.ToLower(version)] = true
		}
	}
	var failures []error
	for _, entry := range entries {
		if kept[strings.ToLower(entry.Name())] {
			continue
		}
		if err := os.RemoveAll(filepath.Join(s.agentDir(id), entry.Name())); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

// pruneLeftovers removes what an interrupted change left in the agent's
// folder that is no version: downloads, checks and temporary files, whose
// names start with ".".
func (s agentStore) pruneLeftovers(id string) error {
	entries, err := os.ReadDir(s.agentDir(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var failures []error
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".") {
			if err := os.RemoveAll(filepath.Join(s.agentDir(id), entry.Name())); err != nil {
				failures = append(failures, err)
			}
		}
	}
	return errors.Join(failures...)
}

func (s agentStore) removeAgent(id string) error {
	return os.RemoveAll(s.agentDir(id))
}

// ensureAgentDir makes the agent's folder (0700) inside the root.
func (s agentStore) ensureAgentDir(id string) error {
	if err := s.ensureRoot(); err != nil {
		return err
	}
	if err := ensurePrivateStateDirectory(filepath.Join(s.agentDir(id), "x")); err != nil {
		return err
	}
	return privateAgentFolder(s.agentDir(id))
}
