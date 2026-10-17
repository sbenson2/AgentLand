package main

import (
	"runtime"
	"strings"
	"testing"
)

func TestTunnelSocketFlagNeedsTheLocalSessionHTTPSAndTheStateFolder(t *testing.T) {
	state := "/Users/me/Library/Application Support/agentland/host.json"
	socket := "/Users/me/Library/Application Support/agentland/tunnel.sock"
	if err := tunnelSettings(state, "", "", false); err != nil {
		t.Fatalf("without --tunnel-socket nothing is needed: %v", err)
	}
	if err := tunnelSettings(state, socket, "", false); err == nil || !strings.Contains(err.Error(), "--local-session-env") {
		t.Fatalf("without the local session: %v", err)
	}
	if err := tunnelSettings(state, socket, "AGENTLAND_LOCAL_SESSION_TOKEN", true); err == nil || !strings.Contains(err.Error(), "--dev-http") {
		t.Fatalf("with development HTTP: %v", err)
	}
	if err := tunnelSettings(state, "/tmp/tunnel.sock", "AGENTLAND_LOCAL_SESSION_TOKEN", false); err == nil {
		t.Fatal("a socket outside the state folder was accepted")
	}
	err := tunnelSettings(state, socket, "AGENTLAND_LOCAL_SESSION_TOKEN", false)
	if runtime.GOOS == "darwin" || runtime.GOOS == "linux" {
		if err != nil {
			t.Fatal(err)
		}
	} else if err == nil {
		t.Fatal("accepted on a system without the tunnel socket")
	}
}
