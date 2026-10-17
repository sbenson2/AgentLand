package host

import "golang.org/x/sys/unix"

// renameatNoReplace uses renameatx_np(RENAME_EXCL), which fails with EEXIST
// instead of replacing an existing entry, including a dangling symlink.
func renameatNoReplace(from int, fromName string, to int, toName string) error {
	err := unix.RenameatxNp(from, fromName, to, toName, unix.RENAME_EXCL)
	if err == unix.ENOTSUP {
		return renameatChecked(from, fromName, to, toName)
	}
	return err
}
