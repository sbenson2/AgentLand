//go:build !(darwin || linux)

package termrun

import "os"

// WindowSize is 0, 0: AgentLand terminals need macOS.
func WindowSize(...*os.File) (rows, cols int) { return 0, 0 }
