//go:build !windows

package host

import (
	"os"
	"syscall"
)

// agentFolderOwned reports a folder of the user the host runs as.
func agentFolderOwned(info os.FileInfo) bool {
	return fileOwnedBy(info, os.Getuid())
}

// fileOwnedBy reports a file or folder that user uid owns.
func fileOwnedBy(info os.FileInfo, uid int) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == uid
}

// privateAgentFolderAt reports a real folder (not a link) of this user's
// that no one else can open, as the Mac app requires of the managed
// OpenCode's folders.
func privateAgentFolderAt(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 && agentFolderOwned(info) && info.Mode().Perm()&0o077 == 0
}

// changedOnlyByUser reports a file of this user's that group and others
// cannot write.
func changedOnlyByUser(info os.FileInfo) bool {
	return agentFolderOwned(info) && info.Mode().Perm()&0o022 == 0
}

// runnableByOwner reports a file its owner may run.
func runnableByOwner(info os.FileInfo) bool { return info.Mode().Perm()&0o100 != 0 }
