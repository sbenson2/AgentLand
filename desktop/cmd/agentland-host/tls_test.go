package main

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func TestTLSInitializationCreatesHostBoundCertificateWithoutReplacingKeys(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	args := []string{"tls", "init", "--directory", dir, "--hosts", "localhost,127.0.0.1"}
	if err := run(args); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "server.crt"))
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		t.Fatal("missing certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	if _, err := cert.Verify(x509.VerifyOptions{DNSName: "localhost", Roots: roots}); err != nil {
		t.Fatal(err)
	}
	if _, err := cert.Verify(x509.VerifyOptions{DNSName: "127.0.0.1", Roots: roots}); err != nil {
		t.Fatal(err)
	}
	if _, err := cert.Verify(x509.VerifyOptions{DNSName: "wrong.example", Roots: roots}); err == nil {
		t.Fatal("wrong hostname accepted")
	}
	key, err := os.ReadFile(filepath.Join(dir, "server.key"))
	if err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(filepath.Join(dir, "server.key"))
	if info.Mode().Perm() != 0600 {
		t.Fatal("private key permissions")
	}
	if err := run(args); err == nil {
		t.Fatal("existing certificate replaced")
	}
	after, _ := os.ReadFile(filepath.Join(dir, "server.key"))
	if string(after) != string(key) {
		t.Fatal("key changed")
	}
	if err := run([]string{"tls", "init", "--directory", filepath.Join(t.TempDir(), "bad"), "--hosts", "https://bad/path"}); err == nil {
		t.Fatal("invalid hostname accepted")
	}
}
