package main

import (
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	host "agentland/host"
)

func TestPairCommandCreatesHashedSingleUseNumericPIN(t *testing.T) {
	state := filepath.Join(t.TempDir(), "host.json")
	if err := run([]string{"init", "--state", state, "--project", "project=Project=" + t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	original := os.Stdout
	os.Stdout = writer
	err = run([]string{"pair", "--pin", "--state", state})
	os.Stdout = original
	writer.Close()
	if err != nil {
		t.Fatalf("numeric PIN command: %v", err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	pin := strings.TrimSpace(string(output))
	if !regexp.MustCompile(`^[0-9]{10}$`).MatchString(pin) {
		t.Fatal("expected a ten-digit numeric PIN")
	}
	data, err := os.ReadFile(state)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), pin) {
		t.Fatal("pairing PIN was stored in plaintext")
	}
	store := host.NewStore(state)
	if _, _, err := store.RedeemPairingCode(pin, "Phone"); err != nil {
		t.Fatal("could not redeem fresh numeric PIN:", err)
	}
	if _, _, err := store.RedeemPairingCode(pin, "Other phone"); err == nil {
		t.Fatal("numeric PIN was reusable")
	}
}
