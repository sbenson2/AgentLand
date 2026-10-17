package host

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// serveHTTP1 serves handler on a loopback listener with the given timeouts.
func serveHTTP1(t *testing.T, handler http.Handler, server *http.Server) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server.Handler = handler
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	return "http://" + listener.Addr().String()
}

// streamToTheEnd reads one chat event stream over HTTP/1.1 until the server
// closes it and returns the line types it saw.
func streamToTheEnd(t *testing.T, base, token string) ([]string, time.Duration, error) {
	t.Helper()
	transport := &http.Transport{ForceAttemptHTTP2: false, TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{}}
	defer transport.CloseIdleConnections()
	request, _ := http.NewRequest("GET", base+"/v1/chat/events?projectId=p1&sessionId=s1", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	started := time.Now()
	response, err := (&http.Client{Transport: transport}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || response.ProtoMajor != 1 {
		t.Fatalf("stream: %d over HTTP/%d", response.StatusCode, response.ProtoMajor)
	}
	var types []string
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 64<<10), 256<<10)
	for scanner.Scan() {
		var line struct{ Type string }
		json.Unmarshal(scanner.Bytes(), &line)
		types = append(types, line.Type)
	}
	return types, time.Since(started), scanner.Err()
}

// The listener's timeouts, scaled down so the test takes seconds: a stream
// that lives five times longer than the write timeout still ends with its end
// line. The control run shows the same timeouts do cut a stream that does not
// extend its deadlines, so the test cannot pass by accident.
func TestChatStreamsOutliveTheServerTimeoutsOverHTTP1(t *testing.T) {
	f := newChatFixture(t)
	f.host.chatStreamFor, f.host.chatBeatEvery, f.host.chatWriteWait = 1500*time.Millisecond, 100*time.Millisecond, time.Second
	scaled := serverTimeouts{readHeader: 300 * time.Millisecond, read: 300 * time.Millisecond, write: 300 * time.Millisecond, idle: 5 * time.Second}
	base := serveHTTP1(t, f.host.Handler(), newHTTPServer(nil, "", scaled))
	types, elapsed, err := streamToTheEnd(t, base, f.token)
	if err != nil || len(types) < 10 || types[0] != "ready" || types[1] != "snapshot" || types[len(types)-1] != "end" || elapsed < 1500*time.Millisecond {
		t.Fatalf("stream under %v write timeout: %v after %v (%v)", scaled.write, strings.Join(types, ","), elapsed, err)
	}
	f.host.chatExtendDeadlines = false
	types, elapsed, _ = streamToTheEnd(t, base, f.token)
	if len(types) == 0 || types[len(types)-1] == "end" || elapsed > time.Second {
		t.Fatalf("without extended deadlines the stream was not cut: %v after %v", strings.Join(types, ","), elapsed)
	}
}

// This exercises the real NewHTTPServer (20 s read, 35 s write timeouts)
// with a 40 s stream. It is opt-in because it takes 40 s; the scaled test
// above covers the same path in every run.
func TestChatStreamsOutliveTheRealServerTimeouts(t *testing.T) {
	if os.Getenv("AGENTLAND_TEST_SLOW") == "" {
		t.Skip("set AGENTLAND_TEST_SLOW=1 to hold a 40 s stream under the listener's real 20 s read and 35 s write timeouts")
	}
	f := newChatFixture(t)
	f.host.chatStreamFor = 40 * time.Second
	base := serveHTTP1(t, f.host.Handler(), NewHTTPServer(nil, ""))
	types, elapsed, err := streamToTheEnd(t, base, f.token)
	beats := strings.Count(strings.Join(types, ","), "beat")
	if err != nil || types[len(types)-1] != "end" || elapsed < 40*time.Second || beats < 3 {
		t.Fatalf("40 s stream: %v after %v (%v)", strings.Join(types, ","), elapsed, err)
	}
	t.Logf("HTTP/1.1 stream lasted %v under ReadTimeout %v and WriteTimeout %v: %s", elapsed.Round(time.Millisecond), listenerTimeouts.read, listenerTimeouts.write, strings.Join(types, ","))
}
