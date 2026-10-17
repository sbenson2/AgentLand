package shellhook

import "io/fs"

// linkCount is 1 on Windows, which has no zsh hook to install.
func linkCount(fs.FileInfo) uint64 { return 1 }
