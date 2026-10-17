package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Finding commands on the Mac (docs/HOST-API.md "Agents"): the local agents,
// node, npm and uv are found as the terminal's programs are.

// findCommand finds a command as the terminal's programs are found:
// Homebrew, /usr/local/bin, ~/.local/bin, then PATH, then the folders of
// Node.js and tool version managers (versionManagerFolders).
func findCommand(name string) (string, bool) {
	return findCommandAs(name, os.Getuid())
}

// findCommandAs is findCommand for the user uid: a version manager's folder
// counts only when uid owns it.
func findCommandAs(name string, uid int) (string, bool) {
	if name == "" || strings.ContainsAny(name, "/\\") {
		return "", false
	}
	for _, directory := range []string{"/opt/homebrew/bin", "/usr/local/bin"} {
		candidate := filepath.Join(directory, name)
		if executableFile(candidate) {
			return candidate, true
		}
	}
	home, homeErr := os.UserHomeDir()
	if homeErr == nil {
		candidate := filepath.Join(home, ".local", "bin", name)
		if executableFile(candidate) {
			return candidate, true
		}
	}
	if candidate, err := exec.LookPath(name); err == nil && filepath.IsAbs(candidate) && executableFile(candidate) {
		return candidate, true
	}
	if homeErr != nil || !filepath.IsAbs(home) {
		return "", false
	}
	for _, directory := range versionManagerFolders(home) {
		if !folderOwnedByUser(directory, uid) {
			continue
		}
		candidate := filepath.Join(directory, name)
		if executableFile(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// versionManagerFolders are the folders where Node.js and tool version
// managers keep their commands, in the order they are searched: Volta's,
// asdf's and mise's shims, fnm's default alias (its current folder, then
// the one older versions keep on macOS) and nvm's default version.
func versionManagerFolders(home string) []string {
	folders := []string{
		filepath.Join(home, ".volta", "bin"),
		filepath.Join(home, ".asdf", "shims"),
		filepath.Join(home, ".local", "share", "mise", "shims"),
		filepath.Join(home, ".local", "share", "fnm", "aliases", "default", "bin"),
		filepath.Join(home, "Library", "Application Support", "fnm", "aliases", "default", "bin"),
	}
	if folder, ok := nvmDefaultFolder(home); ok {
		folders = append(folders, folder)
	}
	return folders
}

// folderOwnedByUser reports a folder (links followed) that user uid owns.
func folderOwnedByUser(directory string, uid int) bool {
	info, err := os.Stat(directory)
	return err == nil && info.IsDir() && fileOwnedBy(info, uid)
}

// nvmVersionFolder is the name of a Node.js version folder nvm made.
var nvmVersionFolder = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

// nvmAliasName is a name nvm keeps an alias under (default, lts/iron,
// lts/*): no path can leave ~/.nvm/alias.
var nvmAliasName = regexp.MustCompile(`^(lts/)?[A-Za-z0-9*][A-Za-z0-9._*-]{0,63}$`)

// nvmDefaultFolder is the bin folder of nvm's default Node.js: the version
// ~/.nvm/alias/default names (an alias of another alias, "node" and
// "stable" followed as nvm does), else the highest version installed.
func nvmDefaultFolder(home string) (string, bool) {
	versions := filepath.Join(home, ".nvm", "versions", "node")
	entries, err := os.ReadDir(versions)
	if err != nil {
		return "", false
	}
	var installed []string
	for _, entry := range entries {
		if nvmVersionFolder.MatchString(entry.Name()) {
			installed = append(installed, entry.Name())
		}
	}
	if len(installed) == 0 {
		return "", false
	}
	chosen := nvmResolve(filepath.Join(home, ".nvm", "alias"), "default", installed)
	if chosen == "" {
		chosen = nvmHighest(installed, nil)
	}
	return filepath.Join(versions, chosen, "bin"), true
}

// nvmResolve follows alias name (at most 8 aliases deep) to an installed
// version folder, "" when it names none.
func nvmResolve(aliases, name string, installed []string) string {
	for range 8 {
		if !nvmAliasName.MatchString(name) || strings.Contains(name, "..") {
			return ""
		}
		data, err := os.ReadFile(filepath.Join(aliases, filepath.FromSlash(name)))
		if err != nil || len(data) > 256 {
			return ""
		}
		target, _, _ := strings.Cut(strings.TrimSpace(string(data)), "\n")
		target = strings.TrimSpace(target)
		switch {
		case target == "node" || target == "stable":
			return nvmHighest(installed, nil)
		case nvmVersionPrefix(target) != nil:
			return nvmHighest(installed, nvmVersionPrefix(target))
		}
		name = target
	}
	return ""
}

// nvmVersionPrefix reads "20", "v20.11" or "v20.11.0" as the numbers a
// version must start with; nil for anything else.
func nvmVersionPrefix(text string) []int {
	parts := strings.Split(strings.TrimPrefix(text, "v"), ".")
	if len(parts) > 3 {
		return nil
	}
	numbers := make([]int, 0, len(parts))
	for _, part := range parts {
		number, err := strconv.Atoi(part)
		if err != nil || number < 0 || part == "" || strconv.Itoa(number) != part {
			return nil
		}
		numbers = append(numbers, number)
	}
	return numbers
}

// nvmHighest is the highest installed version that starts with prefix.
func nvmHighest(installed []string, prefix []int) string {
	best, bestNumbers := "", []int(nil)
	for _, name := range installed {
		numbers := nvmVersionPrefix(name)
		if len(numbers) != 3 || len(prefix) > 3 {
			continue
		}
		matches := true
		for index, number := range prefix {
			if numbers[index] != number {
				matches = false
			}
		}
		if !matches {
			continue
		}
		if best == "" || nvmLess(bestNumbers, numbers) {
			best, bestNumbers = name, numbers
		}
	}
	return best
}

func nvmLess(a, b []int) bool {
	for index := range a {
		if a[index] != b[index] {
			return a[index] < b[index]
		}
	}
	return false
}
