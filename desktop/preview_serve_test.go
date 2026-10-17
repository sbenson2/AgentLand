package host

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// testCertificate writes a certificate for 127.0.0.1 and its key, and returns
// a pool that trusts it.
func testCertificate(t *testing.T) (string, string, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "AgentLand test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	certificateFile, keyFile := filepath.Join(directory, "server.crt"), filepath.Join(directory, "server.key")
	if err := os.WriteFile(certificateFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0600); err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(certificate)
	return certificateFile, keyFile, pool
}

func freeLoopbackAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().String()
}

func addressPort(t *testing.T, address string) int {
	t.Helper()
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	var number int
	fmt.Sscan(port, &number)
	return number
}

func TestValidateListenWithPreviews(t *testing.T) {
	tlsOptions := func(preview string) ListenOptions {
		return ListenOptions{Address: "0.0.0.0:9841", CertificateFile: "c", KeyFile: "k", Preview: &PreviewListen{Address: preview}}
	}
	if err := ValidateListen(tlsOptions("0.0.0.0:9842")); err != nil {
		t.Fatal(err)
	}
	for _, preview := range []string{"0.0.0.0:9841", "127.0.0.1:9841", "9842", "0.0.0.0:0", "0.0.0.0:70000", "0.0.0.0:http"} {
		if err := ValidateListen(tlsOptions(preview)); err == nil {
			t.Errorf("accepted preview listener %q", preview)
		}
	}
	development := ListenOptions{Address: "127.0.0.1:9841", DevelopmentHTTP: true, Preview: &PreviewListen{Address: "127.0.0.1:9842"}}
	if err := ValidateListen(development); err == nil || !strings.Contains(err.Error(), "HTTPS") {
		t.Fatalf("previews over development HTTP: %v", err)
	}
	if err := ValidateListen(ListenOptions{Address: "127.0.0.1:9841", Preview: &PreviewListen{Address: "127.0.0.1:9842"}}); err == nil {
		t.Fatal("accepted previews without a certificate")
	}
}

// Both listeners start and stop together. Shutdown ends proxied streams and
// closes WebSockets, which http.Server.Shutdown would not, and then both
// ports are closed.
func TestServeContextRunsAndStopsThePreviewListener(t *testing.T) {
	certificateFile, keyFile, pool := testCertificate(t)
	f := newPreviewFixture(t)
	apiAddress, previewAddress := freeLoopbackAddress(t), freeLoopbackAddress(t)
	f.host.preview.port = addressPort(t, previewAddress)
	f.host.preview.apiPort = addressPort(t, apiAddress)

	ticks := newUpstream(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for {
			if _, err := fmt.Fprint(w, "data: tick\n\n"); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	})
	sockets, _ := echoUpstream(t)
	f.listen(ticks.port, sockets.port)
	streamGrant := f.open(t, f.token, ticks.port)
	socketGrant := f.open(t, f.token, sockets.port)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	served := make(chan error, 1)
	go func() {
		served <- ServeContext(ctx, f.host.Handler(), ListenOptions{
			Address: apiAddress, CertificateFile: certificateFile, KeyFile: keyFile, OnShutdown: f.host.BeginShutdown,
			Preview: &PreviewListen{Address: previewAddress, Handler: f.host.PreviewHandler(), OnShutdown: f.host.StopPreviews},
		})
	}()
	tlsConfig := &tls.Config{RootCAs: pool}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}, Timeout: 10 * time.Second}
	defer client.CloseIdleConnections()
	deadline := time.Now().Add(5 * time.Second)
	for {
		response, err := client.Get("https://" + previewAddress + "/")
		if err == nil {
			response.Body.Close()
			if response.StatusCode != 401 || response.Header.Get("X-AgentLand-Preview-Error") != "preview_session_required" {
				t.Fatalf("preview listener without a cookie: %d", response.StatusCode)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the preview listener did not start:", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	// The API listener serves /v1; the preview listener proxies every path.
	health, err := client.Get("https://" + apiAddress + "/v1/health")
	if err != nil || health.StatusCode != 200 {
		t.Fatalf("API listener: %v", err)
	}
	health.Body.Close()

	request, _ := http.NewRequest("GET", "https://"+previewAddress+"/events", nil)
	request.Header.Set("Cookie", streamGrant.cookie())
	stream, err := (&http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	lines := bufio.NewReader(stream.Body)
	if line, err := lines.ReadString('\n'); err != nil || line != "data: tick\n" {
		t.Fatalf("stream: %q %v", line, err)
	}
	dialer := websocket.Dialer{TLSClientConfig: tlsConfig, HandshakeTimeout: 5 * time.Second}
	socket, _, err := dialer.Dial("wss://"+previewAddress+"/hmr", http.Header{"Cookie": {socketGrant.cookie()}, "Origin": {"https://" + previewAddress}})
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	echo(t, socket, "before shutdown")

	began := time.Now()
	cancel()
	wantClosed(t, "shutdown", socket)
	streamEnded := make(chan error, 1)
	go func() {
		for {
			if _, err := lines.ReadString('\n'); err != nil {
				streamEnded <- err
				return
			}
		}
	}()
	select {
	case <-streamEnded:
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown did not end the proxied stream")
	}
	select {
	case err := <-served:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("ServeContext: %v", err)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("graceful shutdown did not finish")
	}
	if elapsed := time.Since(began); elapsed > 4*time.Second {
		t.Fatalf("shutdown waited on preview connections: %v", elapsed)
	}
	for _, address := range []string{apiAddress, previewAddress} {
		if conn, err := net.DialTimeout("tcp", address, time.Second); err == nil {
			conn.Close()
			t.Errorf("%s still accepts connections", address)
		}
	}
}

// A taken preview port fails the start and releases the API port.
func TestServeContextFailsWhenThePreviewPortIsTaken(t *testing.T) {
	certificateFile, keyFile, _ := testCertificate(t)
	f := newPreviewFixture(t)
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	apiAddress := freeLoopbackAddress(t)
	done := make(chan error, 1)
	go func() {
		done <- ServeContext(context.Background(), f.host.Handler(), ListenOptions{Address: apiAddress, CertificateFile: certificateFile, KeyFile: keyFile, Preview: &PreviewListen{Address: taken.Addr().String(), Handler: f.host.PreviewHandler()}})
	}()
	select {
	case err := <-done:
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("started with a taken preview port: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ServeContext kept running with a taken preview port")
	}
	if conn, err := net.DialTimeout("tcp", apiAddress, time.Second); err == nil {
		conn.Close()
		t.Fatal("the API port stayed open")
	}
	if err := ServeContext(context.Background(), f.host.Handler(), ListenOptions{Address: apiAddress, CertificateFile: certificateFile, KeyFile: keyFile, Preview: &PreviewListen{Address: freeLoopbackAddress(t)}}); err == nil || !strings.Contains(err.Error(), "handler") {
		t.Fatalf("preview listener without a handler: %v", err)
	}
}
