// Package shellhook installs and removes the zsh hook behind "Open coding
// agents from Terminal in AgentLand" (docs/HOST-API.md, "Terminals started in
// Terminal on the Mac"): a hook script, a switch file the script reads at every command,
// and one marked block in ~/.zshrc that sources the script.
//
// The hook folder is shell/ beside the host's state (0700): agentland.zsh,
// the script, and routing, the switch ("on"), both 0600. The block is the
// only change to the user's shell setup, and Off takes it away leaving the
// file as it was.
package shellhook

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// The lines that mark AgentLand's block in ~/.zshrc.
const (
	StartMarker = "# >>> AgentLand: coding agents from Terminal >>>"
	EndMarker   = "# <<< AgentLand: coding agents from Terminal <<<"
)

// Options says where the hook lives and what it runs.
type Options struct {
	StatePath  string // the host's state file; the hook folder sits beside it
	Executable string // the agentland-host binary the hook runs
	Home       string // the home folder whose .zshrc gets the block; "" means os.UserHomeDir()
	Programs   []string
}

// Status is what Get finds. Block is "present", "absent" or "damaged".
type Status struct {
	On    bool   `json:"on"`
	Block string `json:"block"`
	Zshrc string `json:"zshrc"`
}

// DamagedBlockError is a .zshrc whose markers are not one start followed by
// one end. .zshrc and the hook script are left as they are then (Off and
// Pause still turn routing off): the user removes the lines by hand.
type DamagedBlockError struct{ Path string }

func (e *DamagedBlockError) Error() string {
	return "AgentLand's block in " + e.Path + ` is damaged. Remove the lines from "` + StartMarker + `" to "` + EndMarker + `" by hand, then try again.`
}

// Paths is the hook folder for the host state at statePath, the hook script
// in it, and the switch file.
func Paths(statePath string) (dir, hook, state string) {
	dir = filepath.Join(filepath.Dir(statePath), "shell")
	return dir, filepath.Join(dir, "agentland.zsh"), filepath.Join(dir, "routing")
}

// newlinePath records that On ended the user's last line with a newline
// before its block: it holds the path of the file On changed. It survives
// Pause, and Off removes that newline again and then this file.
func newlinePath(statePath string) string {
	dir, _, _ := Paths(statePath)
	return filepath.Join(dir, "zshrc-newline")
}

// createdPath records that On made .zshrc, which did not exist: it holds
// the path of the file On made. It survives Pause, and Off deletes that file
// when only the block was in it, and then this file. A .zshrc On did not
// make is never deleted.
func createdPath(statePath string) string {
	dir, _, _ := Paths(statePath)
	return filepath.Join(dir, "zshrc-created")
}

// recorded says the record at path holds target.
func recorded(path, target string) bool {
	data, err := os.ReadFile(path)
	return err == nil && strings.TrimSuffix(string(data), "\n") == target
}

// SwitchOn says the switch file for statePath reads "on".
func SwitchOn(statePath string) bool {
	_, _, state := Paths(statePath)
	data, err := os.ReadFile(state)
	return err == nil && strings.TrimRight(string(data), "\n") == "on"
}

// On writes the hook script and the switch ("on"), and adds the block to
// .zshrc, or rewrites it in place when it is there. The first time it
// changes a .zshrc it keeps a copy of it beside it. A damaged block or a
// hard-linked .zshrc changes nothing.
func On(o Options) error {
	if o.StatePath == "" || o.Executable == "" {
		return errors.New("the hook needs the host's state and executable")
	}
	statePath, err := filepath.Abs(o.StatePath)
	if err != nil {
		return err
	}
	executable, err := filepath.Abs(o.Executable)
	if err != nil {
		return err
	}
	z, err := readZshrc(o.Home)
	if err != nil {
		return err
	}
	lines, block, err := z.block()
	if err != nil {
		return err
	}
	if err := z.refuseHardLink(); err != nil {
		return err
	}
	dir, hook, state := Paths(statePath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	if err := writeFile(hook, []byte(Script(executable, statePath, state, o.Programs)), 0o600); err != nil {
		return err
	}
	text := blockText(hook)
	var content string
	if block.present {
		content = strings.Join(lines[:block.start], "") + text + strings.Join(lines[block.end+1:], "")
	} else {
		content = string(z.content)
		added := false
		if content != "" {
			if !strings.HasSuffix(content, "\n") {
				content += "\n"
				added = true
			}
			content += "\n"
		}
		content += text
		// The newline, and a file On makes, are on record before the file
		// has them.
		for _, r := range []struct {
			path string
			keep bool
		}{{newlinePath(statePath), added}, {createdPath(statePath), !z.exists}} {
			if r.keep {
				if err := writeFile(r.path, []byte(z.target+"\n"), 0o600); err != nil {
					return err
				}
			} else if err := removeFile(r.path); err != nil {
				return err
			}
		}
		if z.exists {
			if err := z.backUp(); err != nil {
				return err
			}
		}
	}
	if !z.exists || content != string(z.content) {
		if err := z.write([]byte(content)); err != nil {
			return err
		}
	}
	return writeFile(state, []byte("on\n"), 0o600)
}

// Off turns routing off at once, takes the block out of .zshrc (also when
// the user edited inside it), and removes the hook folder. A damaged block
// doesn't keep routing on: Off removes the switch, leaves .zshrc and the
// hook script as they are, and reports the block. A .zshrc that can't be
// read or written (or is hard-linked) doesn't either: Off removes the switch
// first and the hook script as well, and then reports that file; what On
// recorded about it stays for a later Off.
func Off(o Options) error {
	if o.StatePath == "" {
		return errNoState
	}
	z, zshrcErr := readZshrc(o.Home)
	var lines []string
	var block blockAt
	var damaged error
	if zshrcErr == nil {
		lines, block, damaged = z.block()
	}
	dir, hook, state := Paths(o.StatePath)
	if err := removeFile(state); err != nil {
		return errors.Join(err, zshrcErr, damaged)
	}
	if damaged != nil {
		return damaged
	}
	if zshrcErr == nil && block.present {
		zshrcErr = z.removeBlock(lines, block, o.StatePath)
	}
	errs := []error{zshrcErr}
	removals := []string{hook}
	if zshrcErr == nil {
		removals = append(removals, newlinePath(o.StatePath), createdPath(o.StatePath))
	}
	for _, path := range removals {
		errs = append(errs, removeFile(path))
	}
	// The folder goes once empty; anything else left in it stays.
	if entries, err := os.ReadDir(dir); err == nil && len(entries) == 0 {
		errs = append(errs, removeFile(dir))
	}
	return errors.Join(errs...)
}

// removeBlock writes .zshrc without the block, as it was before On: without
// the newline On added to end the user's last line, when nothing was added
// below the block since, and deleted when On made it and only the block
// was in it. A hard-linked .zshrc is left as it is.
func (z *zshrc) removeBlock(lines []string, block blockAt, statePath string) error {
	if err := z.refuseHardLink(); err != nil {
		return err
	}
	start := block.start
	if start > 0 && lines[start-1] == "\n" {
		start--
	}
	atEnd := block.end == len(lines)-1
	content := strings.Join(lines[:start], "") + strings.Join(lines[block.end+1:], "")
	if atEnd && strings.HasSuffix(content, "\n") && recorded(newlinePath(statePath), z.target) {
		content = strings.TrimSuffix(content, "\n")
	}
	if content == "" && recorded(createdPath(statePath), z.target) {
		return removeFile(z.target)
	}
	return z.write([]byte(content))
}

// Pause turns routing off and keeps the block and the hook script, for
// when terminal access is off: turning it on again is On. It leaves .zshrc
// alone, so neither a damaged block nor a .zshrc that can't be read keeps
// routing on; a damaged block is reported once the switch is off.
func Pause(o Options) error {
	if o.StatePath == "" {
		return errNoState
	}
	_, _, state := Paths(o.StatePath)
	var damaged error
	if z, err := readZshrc(o.Home); err == nil {
		_, _, damaged = z.block()
	}
	if err := removeFile(state); err != nil {
		return errors.Join(err, damaged)
	}
	return damaged
}

// Get reads the switch and the block.
func Get(o Options) (Status, error) {
	if o.StatePath == "" {
		return Status{}, errNoState
	}
	z, err := readZshrc(o.Home)
	if err != nil {
		return Status{}, err
	}
	status := Status{On: SwitchOn(o.StatePath), Block: "absent", Zshrc: z.path}
	_, block, err := z.block()
	var damaged *DamagedBlockError
	switch {
	case errors.As(err, &damaged):
		status.Block = "damaged"
	case err != nil:
		return Status{}, err
	case block.present:
		status.Block = "present"
	}
	return status, nil
}

// blockText is the block for the hook script at hook. Its `if` leaves $?
// at 0 when the script is gone, so the first prompt shows no error.
func blockText(hook string) string {
	return StartMarker + "\n" +
		"# Added by AgentLand (Settings → Advanced). Turn the switch off there to remove it.\n" +
		"if [[ -r " + quote(hook) + " ]]; then source " + quote(hook) + "; fi\n" +
		EndMarker + "\n"
}

// zshrc is <Home>/.zshrc as read: target is the file that holds it (the
// path, or what its link leads to), with its mode and hard link count when
// it exists.
type zshrc struct {
	path, target string
	exists       bool
	mode         fs.FileMode
	links        uint64
	content      []byte
}

func readZshrc(home string) (*zshrc, error) {
	if home == "" {
		var err error
		if home, err = os.UserHomeDir(); err != nil {
			return nil, err
		}
	}
	path := filepath.Join(home, ".zshrc")
	z := &zshrc{path: path, target: path}
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return z, nil
	}
	if err != nil {
		return nil, err
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		if z.target, err = filepath.EvalSymlinks(path); err != nil {
			return nil, fmt.Errorf("%s is a link AgentLand cannot follow: %w", path, err)
		}
		if info, err = os.Stat(z.target); err != nil {
			return nil, err
		}
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	if z.content, err = os.ReadFile(z.target); err != nil {
		return nil, err
	}
	z.exists, z.mode, z.links = true, info.Mode().Perm(), linkCount(info)
	return z, nil
}

// refuseHardLink refuses a target with another hard link (some dotfile
// managers link .zshrc so): the temp file and rename every change goes
// through would give it a file of its own and leave the other link with
// the old one.
func (z *zshrc) refuseHardLink() error {
	if z.links > 1 {
		return fmt.Errorf("%s is a hard link, which AgentLand's change would break. Replace it with a symbolic link or a copy, then try again.", z.target)
	}
	return nil
}

// blockAt is where the block is: its start and end markers' lines.
type blockAt struct {
	present    bool
	start, end int
}

// block splits the file into lines, each with its newline, and finds the
// block: none, one start followed by one end, or damaged (an error).
func (z *zshrc) block() ([]string, blockAt, error) {
	lines := strings.SplitAfter(string(z.content), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	var starts, ends []int
	for index, line := range lines {
		switch strings.TrimSpace(line) {
		case StartMarker:
			starts = append(starts, index)
		case EndMarker:
			ends = append(ends, index)
		}
	}
	switch {
	case len(starts) == 0 && len(ends) == 0:
		return lines, blockAt{}, nil
	case len(starts) == 1 && len(ends) == 1 && starts[0] < ends[0]:
		return lines, blockAt{present: true, start: starts[0], end: ends[0]}, nil
	}
	return nil, blockAt{}, &DamagedBlockError{Path: z.path}
}

func (z *zshrc) backupPath() string { return z.path + ".agentland-backup" }

// backUp keeps the file's content beside it, once: an earlier copy stays.
func (z *zshrc) backUp() error {
	f, err := os.OpenFile(z.backupPath(), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, fs.ErrExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := f.Write(z.content); err != nil {
		f.Close()
		os.Remove(z.backupPath())
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(z.backupPath())
		return err
	}
	return nil
}

// write replaces the file's content, through a temp file beside its target,
// keeping its mode; a new file is 0644.
func (z *zshrc) write(content []byte) error {
	mode := fs.FileMode(0o644)
	if z.exists {
		mode = z.mode
	}
	return writeFile(z.target, content, mode)
}

// writeFile writes path whole or not at all: a temp file in its folder,
// renamed over it.
func writeFile(path string, data []byte, mode fs.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".agentland-*")
	if err != nil {
		return err
	}
	temp := f.Name()
	fail := func(err error) error {
		f.Close()
		os.Remove(temp)
		return err
	}
	if _, err := f.Write(data); err != nil {
		return fail(err)
	}
	if err := f.Chmod(mode); err != nil {
		return fail(err)
	}
	if err := f.Sync(); err != nil {
		return fail(err)
	}
	if err := f.Close(); err != nil {
		os.Remove(temp)
		return err
	}
	if err := os.Rename(temp, path); err != nil {
		os.Remove(temp)
		return err
	}
	return nil
}

func removeFile(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// errNoState is a call without the host's state, whose folder holds the hook.
var errNoState = errors.New("the hook needs the host's state")
