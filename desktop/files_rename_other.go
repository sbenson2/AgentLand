//go:build !darwin && !linux && !windows

package host

// Other Unix systems have no portable no-replace rename; the checked rename
// runs under filesMu.
func renameatNoReplace(from int, fromName string, to int, toName string) error {
	return renameatChecked(from, fromName, to, toName)
}
