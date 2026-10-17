//go:build !darwin

package host

import "time"

// foregroundCommand is macOS only (terminal_command_darwin.go); elsewhere a
// terminal lists no command.
func foregroundCommand(int, time.Time, bool) string { return "" }
