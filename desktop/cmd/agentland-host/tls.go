package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func validCertificateHost(host string) bool {
	if net.ParseIP(host) != nil {
		return true
	}
	if len(host) == 0 || len(host) > 253 {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}
func tlsCommand(args []string) error {
	if len(args) == 0 || args[0] != "init" {
		return errors.New("usage: agentland-host tls init --directory PATH --hosts HOST[,HOST]")
	}
	fs := flag.NewFlagSet("tls init", flag.ContinueOnError)
	dir := fs.String("directory", "", "private certificate directory")
	hosts := fs.String("hosts", "", "DNS names or IP addresses used by your devices, comma separated")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *dir == "" || *hosts == "" {
		return errors.New("directory and hosts are required")
	}
	names := strings.Split(*hosts, ",")
	if len(names) > 20 {
		return errors.New("at most 20 certificate hosts are allowed")
	}
	for i := range names {
		names[i] = strings.TrimSpace(names[i])
		if !validCertificateHost(names[i]) {
			return errors.New("hosts must be DNS names or IP addresses without a scheme, path or port")
		}
	}
	target, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(target, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(target)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("certificate directory must be a real directory")
	}
	certificateFile, keyFile := filepath.Join(target, "server.crt"), filepath.Join(target, "server.key")
	for _, name := range []string{certificateFile, keyFile} {
		if _, err := os.Lstat(name); !errors.Is(err, os.ErrNotExist) {
			return errors.New("certificate or key already exists; choose a new directory to rotate it")
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: names[0], Organization: []string{"AgentLand local host"}}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.Add(365 * 24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true, MaxPathLenZero: true}
	for _, name := range names {
		if ip := net.ParseIP(name); ip != nil {
			template.IPAddresses = append(template.IPAddresses, ip)
		} else {
			template.DNSNames = append(template.DNSNames, name)
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	writeExclusive := func(name string, data []byte, mode os.FileMode) error {
		f, err := os.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
		if err != nil {
			return err
		}
		_, writeErr := f.Write(data)
		syncErr := f.Sync()
		closeErr := f.Close()
		return errors.Join(writeErr, syncErr, closeErr)
	}
	if err = writeExclusive(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey}), 0600); err != nil {
		return err
	}
	if err = writeExclusive(certificateFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0644); err != nil {
		os.Remove(keyFile)
		return err
	}
	fingerprint := sha256.Sum256(der)
	return json.NewEncoder(os.Stdout).Encode(map[string]string{"certificateFile": certificateFile, "keyFile": keyFile, "fingerprint": hex.EncodeToString(fingerprint[:])})
}
