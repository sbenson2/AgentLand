//go:build !darwin

package host

// Only macOS reads a process's start time here, which telling a leftover
// agent from a process that took its pid needs; elsewhere nothing is
// recorded or ended (acp_leftovers.go).

func acpProcessStart(int) (int64, bool) { return 0, false }

func acpEndLeftover(acpProcessRecord, string) bool { return false }
