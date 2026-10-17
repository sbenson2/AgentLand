//go:build windows

package host

import (
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsStateAndLockUseOnlyCurrentUserDACL(t *testing.T) {
	projectDirectory := t.TempDir()
	directory := filepath.Join(t.TempDir(), "state-directory")
	path := filepath.Join(directory, "host.json")
	if err := NewStore(path).Initialize(Config{
		OpenCodeURL: "http://127.0.0.1:4096",
		PasswordEnv: "TEST_PASSWORD",
		Projects:    []Project{{ID: "p", Name: "P", Directory: projectDirectory}},
	}); err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	want := "P(A;;FA;;;" + user.User.Sid.String() + ")"
	for _, file := range []string{directory, path, path + ".lock"} {
		descriptor, err := windows.GetNamedSecurityInfo(file, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatalf("read DACL %q: %v", file, err)
		}
		sddl := descriptor.String()
		_, dacl, ok := strings.Cut(sddl, "D:")
		if !ok || dacl != want {
			t.Fatalf("DACL %q = %q, want %q", file, dacl, want)
		}
		if err := requireWindowsOwner(file, user.User.Sid); err != nil {
			t.Fatalf("owner %q is not the current user: %v", file, err)
		}
	}
}

func TestWindowsOwnerCheckRejectsAnotherSID(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	other, err := windows.StringToSid("S-1-5-18") // LocalSystem cannot own a normal user's temp file.
	if err != nil {
		t.Fatal(err)
	}
	if user.User.Sid.Equals(other) {
		t.Skip("test requires a non-LocalSystem user")
	}
	if err := requireWindowsOwner(t.TempDir(), other); err == nil {
		t.Fatal("accepted a state directory with another account as owner")
	}
}
