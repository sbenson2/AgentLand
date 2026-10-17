package host

import "golang.org/x/sys/unix"

// renameatNoReplace uses renameat2(RENAME_NOREPLACE). Kernels or file systems
// without it answer ENOSYS or EINVAL and get the checked fallback; a folder
// moved into itself still fails there with EINVAL.
func renameatNoReplace(from int, fromName string, to int, toName string) error {
	err := unix.Renameat2(from, fromName, to, toName, unix.RENAME_NOREPLACE)
	if err == unix.ENOSYS || err == unix.EINVAL {
		return renameatChecked(from, fromName, to, toName)
	}
	return err
}
