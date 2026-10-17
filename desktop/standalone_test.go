package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultStatePathUsesAgentLandNamespace(t *testing.T) {
	configDirectory, err := os.UserConfigDir()
	if err != nil {
		t.Skip("user config directory is unavailable")
	}
	want := filepath.Join(configDirectory, "agentland", "host.json")
	if got := DefaultStatePath(); got != want {
		t.Fatalf("default state path = %q, want %q", got, want)
	}
}
