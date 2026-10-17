package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStateRefusesSymlinkParent(t *testing.T) {
	projectDirectory := t.TempDir()
	realDirectory := filepath.Join(t.TempDir(), "real-state-directory")
	if err := os.Mkdir(realDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "state-parent")
	if err := os.Symlink(realDirectory, link); err != nil {
		t.Skipf("symlink creation is unavailable: %v", err)
	}
	path := filepath.Join(link, "host.json")
	err := NewStore(path).Initialize(Config{
		OpenCodeURL: "http://127.0.0.1:4096",
		PasswordEnv: "TEST_PASSWORD",
		Projects:    []Project{{ID: "p", Name: "P", Directory: projectDirectory}},
	})
	if err == nil {
		t.Fatal("state initialization accepted a symlinked parent directory")
	}
	if _, err := os.Lstat(filepath.Join(realDirectory, "host.json")); !os.IsNotExist(err) {
		t.Fatalf("state was written through symlinked parent: %v", err)
	}
}
