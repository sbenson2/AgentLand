//go:build !windows

package host

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStateAllowsNonWritableExistingParent(t *testing.T) {
	projectDirectory := t.TempDir()
	stateDirectory := filepath.Join(t.TempDir(), "existing-state-directory")
	if err := os.Mkdir(stateDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(stateDirectory, 0755); err != nil {
		t.Fatal(err)
	}
	err := NewStore(filepath.Join(stateDirectory, "host.json")).Initialize(Config{
		OpenCodeURL: "http://127.0.0.1:4096",
		PasswordEnv: "TEST_PASSWORD",
		Projects:    []Project{{ID: "p", Name: "P", Directory: projectDirectory}},
	})
	if err != nil {
		t.Fatalf("non-writable existing state directory error = %v", err)
	}
}

func TestStateRefusesWritableExistingParent(t *testing.T) {
	projectDirectory := t.TempDir()
	stateDirectory := filepath.Join(t.TempDir(), "writable-state-directory")
	if err := os.Mkdir(stateDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(stateDirectory, 0777); err != nil {
		t.Fatal(err)
	}
	err := NewStore(filepath.Join(stateDirectory, "host.json")).Initialize(Config{
		OpenCodeURL: "http://127.0.0.1:4096",
		PasswordEnv: "TEST_PASSWORD",
		Projects:    []Project{{ID: "p", Name: "P", Directory: projectDirectory}},
	})
	if err == nil || !strings.Contains(err.Error(), "dedicated AgentLand directory") {
		t.Fatalf("writable existing state directory error = %v", err)
	}
}
