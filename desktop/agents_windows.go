//go:build windows

package host

import "os"

// agentFolderOwned: on Windows the state folder's access list is what keeps
// it private (state_windows.go), so a folder there counts as the user's.
func agentFolderOwned(os.FileInfo) bool { return true }

// fileOwnedBy: Windows has no owner ids here; the folders searched are the
// user's profile's.
func fileOwnedBy(os.FileInfo, int) bool { return true }

// privateAgentFolderAt: a real folder, not a link; the state folder's access
// list keeps it private.
func privateAgentFolderAt(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0
}

// changedOnlyByUser and runnableByOwner: Windows keeps no such mode bits.
func changedOnlyByUser(os.FileInfo) bool { return true }
func runnableByOwner(os.FileInfo) bool   { return true }
