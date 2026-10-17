//go:build windows

package host

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

func ensurePrivateStateDirectory(path string) error {
	directory := filepath.Clean(filepath.Dir(path))
	info, err := os.Lstat(directory)
	created := false
	if os.IsNotExist(err) {
		if err = os.MkdirAll(directory, 0700); err != nil {
			return err
		}
		created = true
		info, err = os.Lstat(directory)
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("state directory must be a private, non-reparse directory; use a dedicated AgentLand directory")
	}
	if err := rejectWindowsReparsePoint(directory); err != nil {
		return err
	}
	if created {
		return restrictWindowsPathToCurrentUser(directory)
	}
	if err := requireWindowsCurrentUserDACL(directory); err != nil {
		return fmt.Errorf("state directory must be private; use a dedicated AgentLand directory: %w", err)
	}
	return nil
}

func readPrivateState(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, errors.New("state file must be a regular private file")
	}
	if err := rejectWindowsReparsePoint(path); err != nil {
		return nil, err
	}
	if err := requireWindowsCurrentUserDACL(path); err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}

func writePrivateState(path string, data []byte) error {
	if err := ensurePrivateStateDirectory(path); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err = restrictWindowsPathToCurrentUser(name); err == nil {
		_, err = tmp.Write(data)
	}
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	from, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if err = windows.MoveFileEx(from, to, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH); err != nil {
		return err
	}
	return requireWindowsCurrentUserDACL(path)
}

// lockStateFile takes an exclusive lock on the private file at path without
// waiting (LockState).
func lockStateFile(path string) (func(), error) {
	if err := ensurePrivateStateDirectory(path); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	missing := os.IsNotExist(err)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, errors.New("state lock must be a regular private file")
		}
		if err = rejectWindowsReparsePoint(path); err != nil {
			return nil, err
		}
		if err = requireWindowsCurrentUserDACL(path); err != nil {
			return nil, err
		}
	} else if !missing {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if missing {
		if err = restrictWindowsPathToCurrentUser(path); err != nil {
			f.Close()
			return nil, err
		}
	}
	overlapped := new(windows.Overlapped)
	if err = windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, ^uint32(0), ^uint32(0), overlapped); err != nil {
		f.Close()
		if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			return nil, ErrStateBusy
		}
		return nil, err
	}
	return func() {
		_ = windows.UnlockFileEx(windows.Handle(f.Fd()), 0, ^uint32(0), ^uint32(0), overlapped)
		_ = f.Close()
	}, nil
}

func withPrivateStateLock(path string, fn func() error) error {
	if err := ensurePrivateStateDirectory(path); err != nil {
		return err
	}
	lockPath := path + ".lock"
	info, err := os.Lstat(lockPath)
	lockMissing := os.IsNotExist(err)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return errors.New("state lock must be a regular private file")
		}
		if err = rejectWindowsReparsePoint(lockPath); err != nil {
			return err
		}
		if err = requireWindowsCurrentUserDACL(lockPath); err != nil {
			return err
		}
	} else if !lockMissing {
		return err
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if lockMissing {
		if err = restrictWindowsPathToCurrentUser(lockPath); err != nil {
			return err
		}
	}
	overlapped := new(windows.Overlapped)
	if err = windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK, 0, ^uint32(0), ^uint32(0), overlapped); err != nil {
		return err
	}
	defer windows.UnlockFileEx(windows.Handle(f.Fd()), 0, ^uint32(0), ^uint32(0), overlapped)
	return fn()
}

func rejectWindowsReparsePoint(path string) error {
	attributes, err := windows.GetFileAttributes(windows.StringToUTF16Ptr(path))
	if err != nil {
		return err
	}
	if attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return fmt.Errorf("state path %q must not be a reparse point", path)
	}
	return nil
}

func restrictWindowsPathToCurrentUser(path string) error {
	acl, user, want, err := currentUserOnlyWindowsACL()
	if err != nil {
		return err
	}
	if err = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		return err
	}
	return requireWindowsDACL(path, user, want)
}

func requireWindowsCurrentUserDACL(path string) error {
	_, user, want, err := currentUserOnlyWindowsACL()
	if err != nil {
		return err
	}
	return requireWindowsDACL(path, user, want)
}

func currentUserOnlyWindowsACL() (*windows.ACL, *windows.SID, string, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, nil, "", err
	}
	acl, err := windows.ACLFromEntries([]windows.EXPLICIT_ACCESS{{
		AccessPermissions: windows.GENERIC_ALL,
		AccessMode:        windows.GRANT_ACCESS,
		Trustee: windows.TRUSTEE{
			TrusteeForm:  windows.TRUSTEE_IS_SID,
			TrusteeValue: windows.TrusteeValueFromSID(user.User.Sid),
		},
	}}, nil)
	if err != nil {
		return nil, nil, "", err
	}
	return acl, user.User.Sid, "P(A;;FA;;;" + user.User.Sid.String() + ")", nil
}

func requireWindowsDACL(path string, user *windows.SID, want string) error {
	descriptor, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	if owner == nil || !owner.Equals(user) {
		return fmt.Errorf("state path %q must be owned by the current user", path)
	}
	_, dacl, ok := strings.Cut(descriptor.String(), "D:")
	if !ok || dacl != want {
		return fmt.Errorf("state path %q must have an owner-only protected DACL", path)
	}
	return nil
}

func requireWindowsOwner(path string, want *windows.SID) error {
	descriptor, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	if owner == nil || !owner.Equals(want) {
		return fmt.Errorf("state path %q must be owned by the current user", path)
	}
	return nil
}
