//go:build !darwin

package host

import (
	"errors"
	"os"
	"path/filepath"
)

// canonicalFolder is the folder's path with its symbolic links resolved (on
// macOS also in its true case, terminal_canonical_darwin.go). A path that is
// not a folder, or is gone, is an error. The host reads only its workspaces'
// folders this way, never a registration's (terminalFolderJoiner).
func canonicalFolder(path string) (string, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("not a folder")
	}
	return resolved, nil
}
