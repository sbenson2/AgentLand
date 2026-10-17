package host

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

// lsofGolden is `lsof -nP -w -a -iTCP -sTCP:LISTEN -u <uid> -F pcn` output as
// macOS prints it, with the odd cases discovery must survive.
const lsofGolden = `p631
cControlCenter
f9
n*:7000
f10
n*:7000
p766
cPlex Media Server
f59
n*:32400
f60
n127.0.0.1:32401
p821
cnode
f3
n[::1]:5173
f4
n127.0.0.1:5173
p831
cPython
f7
n127.0.0.2:8000
f8
n192.168.1.8:8001
f9
n[fe80::1%lo0]:8002
f10
n127.0.0.1:8003->127.0.0.1:50000
f11
nlocalhost:8004
f12
n127.0.0.1:0
p900
c/usr/local/bin/ruby` + "\x07" + `
f5
n[::ffff:127.0.0.1]:4000
pbad
cghost
f1
n127.0.0.1:4001
`

func TestParseLsofListenersGolden(t *testing.T) {
	found := parseLsofListeners([]byte(lsofGolden))
	type row struct {
		IP      string
		Port    int
		Process string
		PID     int
	}
	var got []row
	for _, listener := range found {
		got = append(got, row{listener.ip.String(), listener.port, listener.process, listener.pid})
	}
	want := []row{
		{"::", 7000, "ControlCenter", 631},
		{"::", 7000, "ControlCenter", 631},
		{"::", 32400, "Plex Media Server", 766},
		{"127.0.0.1", 32401, "Plex Media Server", 766},
		{"::1", 5173, "node", 821},
		{"127.0.0.1", 5173, "node", 821},
		{"127.0.0.2", 8000, "Python", 831},
		{"192.168.1.8", 8001, "Python", 831},
		{"fe80::1", 8002, "Python", 831},
		{"127.0.0.1", 4000, "ruby", 900},
		{"127.0.0.1", 4001, "ghost", 0},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parsed\n%v\nwant\n%v", got, want)
	}
}

func TestFilterPreviewPortsKeepsReachableAllowedPorts(t *testing.T) {
	found := parseLsofListeners([]byte(lsofGolden))
	found = append(found,
		portListener{ip: net.IPv4(127, 0, 0, 1), port: 9841, process: "agentland-host", pid: 777},
		portListener{ip: net.IPv4(127, 0, 0, 1), port: 6000, process: "self", pid: 4242},
		portListener{ip: net.IPv4zero, port: 3000, pid: 1},
		portListener{ip: net.IPv4(127, 0, 0, 1), port: 3000, process: "later", pid: 2},
		portListener{ip: net.IPv6unspecified, port: 3000, process: "next", pid: 3},
		portListener{ip: net.IPv4(127, 0, 0, 1), port: 5432, process: "postgres", pid: 5},
	)
	excluded := map[int]bool{9841: true, 5432: true, 7000: true}
	got := filterPreviewPorts(found, excluded, 4242)
	want := []PreviewPort{
		// The widest address wins; at the same rank a named process does.
		{Port: 3000, Address: "*", Process: "next"},
		{Port: 4000, Address: "127.0.0.1", Process: "ruby"},
		{Port: 4001, Address: "127.0.0.1", Process: "ghost"},
		{Port: 5173, Address: "127.0.0.1", Process: "node"},
		{Port: 32400, Address: "*", Process: "Plex Media Server"},
		{Port: 32401, Address: "127.0.0.1", Process: "Plex Media Server"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("filtered\n%+v\nwant\n%+v", got, want)
	}
	if empty := filterPreviewPorts(nil, nil, 0); empty == nil || len(empty) != 0 {
		t.Fatalf("no listeners must be an empty list, got %#v", empty)
	}
	var many []portListener
	for port := 1; port <= previewPortsLimit+10; port++ {
		many = append(many, portListener{ip: net.IPv4(127, 0, 0, 1), port: 20000 + port})
	}
	if bounded := filterPreviewPorts(many, nil, 0); len(bounded) != previewPortsLimit || bounded[0].Port != 20001 {
		t.Fatalf("bounded list has %d entries starting at %d", len(bounded), bounded[0].Port)
	}
}

func TestCleanProcessNameKeepsTheExecutableNameOnly(t *testing.T) {
	cases := map[string]string{
		"node":                                 "node",
		"/Applications/Tool.app/Contents/tool": "tool",
		"bad\x00name\x1b[31m":                  "badname[31m",
		"  spaced  ":                           "spaced",
		"invalid\xffutf8":                      "invalidutf8",
		strings.Repeat("é", 40):                strings.Repeat("é", 32),
	}
	for input, want := range cases {
		if got := cleanProcessName(input); got != want {
			t.Errorf("cleanProcessName(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestLoopbackURLPort(t *testing.T) {
	cases := map[string]int{"http://127.0.0.1:4197": 4197, "http://localhost": 80, "https://localhost": 443, "http://[::1]:4096/": 4096, "ftp://x": 0, "::": 0, "http://127.0.0.1:x": 0}
	for raw, want := range cases {
		if got := loopbackURLPort(raw); got != want {
			t.Errorf("loopbackURLPort(%q) = %d, want %d", raw, got, want)
		}
	}
}

// procTCPGolden and procTCP6Golden are /proc/net/tcp and tcp6 as a
// little-endian Linux kernel prints them.
const procTCPGolden = `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11111 1 0000000000000000 100 0 0 10 0
   1: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22222 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 33333 1 0000000000000000 100 0 0 10 0
   3: 0100007F:1435 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 44444 1 0000000000000000 20 4 30 10 -1
   4: 0200007F:1F41 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 55555 1 0000000000000000 100 0 0 10 0
   5: garbage
`

const procTCP6Golden = `  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 66666 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000000000000:0FA0 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 77777 1 0000000000000000 100 0 0 10 0
   2: 0000000000000000FFFF00000100007F:0FA1 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 88888 1 0000000000000000 100 0 0 10 0
`

func TestParseProcNetTCPGolden(t *testing.T) {
	type row struct {
		IP    string
		Port  int
		Inode uint64
	}
	collect := func(table string) []row {
		sockets, err := parseProcNetTCP(strings.NewReader(table), 1000, binary.LittleEndian)
		if err != nil {
			t.Fatal(err)
		}
		var rows []row
		for _, socket := range sockets {
			rows = append(rows, row{socket.ip.String(), socket.port, socket.inode})
		}
		return rows
	}
	want := []row{{"127.0.0.1", 5173, 11111}, {"0.0.0.0", 3000, 22222}, {"127.0.0.2", 8001, 55555}}
	if got := collect(procTCPGolden); !reflect.DeepEqual(got, want) {
		t.Errorf("tcp: %v, want %v", got, want)
	}
	want6 := []row{{"::1", 8080, 66666}, {"::", 4000, 77777}, {"127.0.0.1", 4001, 88888}}
	if got := collect(procTCP6Golden); !reflect.DeepEqual(got, want6) {
		t.Errorf("tcp6: %v, want %v", got, want6)
	}
	// A big-endian kernel prints the same address the other way round.
	sockets, err := parseProcNetTCP(strings.NewReader("header\n 0: 7F000001:1435 00000000:0000 0A 0:0 0:0 0 1000 0 9 1\n"), 1000, binary.BigEndian)
	if err != nil || len(sockets) != 1 || !sockets[0].ip.Equal(net.IPv4(127, 0, 0, 1)) || sockets[0].port != 5173 {
		t.Errorf("big-endian: %v %v", sockets, err)
	}
}

func TestProcListenersFindTheirProcesses(t *testing.T) {
	root := t.TempDir()
	write := func(name, content string) {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	link := func(name, target string) {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
	}
	write("net/tcp", procTCPGolden)
	write("net/tcp6", procTCP6Golden)
	write("321/comm", "node\n")
	link("321/fd/0", "/dev/null")
	link("321/fd/7", "socket:[11111]")
	link("321/fd/8", "socket:[66666]")
	write("654/comm", "python3\n")
	link("654/fd/3", "socket:[22222]")
	link("654/fd/4", "pipe:[99]")
	write("self/comm", "ignored")
	found, err := procListeners(context.Background(), root, 1000)
	if err != nil {
		t.Fatal(err)
	}
	got := map[int]portListener{}
	for _, listener := range found {
		got[listener.port] = listener
	}
	if got[5173].process != "node" || got[5173].pid != 321 || got[8080].process != "node" || got[3000].process != "python3" || got[3000].pid != 654 {
		t.Fatalf("owners: %+v", got)
	}
	if got[4000].process != "" || got[4000].pid != 0 {
		t.Fatalf("a socket without a readable owner must have no process: %+v", got[4000])
	}
	if err := os.Remove(filepath.Join(root, "net/tcp6")); err != nil {
		t.Fatal(err)
	}
	if found, err := procListeners(context.Background(), root, 1000); err != nil || len(found) != 3 {
		t.Fatalf("without IPv6: %d %v", len(found), err)
	}
	if _, err := procListeners(context.Background(), t.TempDir(), 1000); err == nil {
		t.Fatal("a missing tcp table must fail")
	}
}

// fakeLsof writes a script that prints output and exits with status.
func fakeLsof(t *testing.T, script string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("uses a shell script")
	}
	path := filepath.Join(t.TempDir(), "lsof")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script), 0700); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLsofListenersRunsBoundedAndAcceptsNoMatches(t *testing.T) {
	arguments := filepath.Join(t.TempDir(), "arguments")
	program := fakeLsof(t, fmt.Sprintf("echo \"$@\" > %q\nprintf 'p12\\ncnode\\nn127.0.0.1:5173\\n'\nexit 1\n", arguments))
	found, err := lsofListeners(context.Background(), program, 501)
	if err != nil || len(found) != 1 || found[0].port != 5173 || found[0].process != "node" || found[0].pid != 12 {
		t.Fatalf("exit status 1 with output: %+v %v", found, err)
	}
	recorded, _ := os.ReadFile(arguments)
	if strings.TrimSpace(string(recorded)) != "-nP -w -a -iTCP -sTCP:LISTEN -u 501 -F pcn" {
		t.Fatalf("arguments %q", recorded)
	}
	if found, err := lsofListeners(context.Background(), fakeLsof(t, "exit 1\n"), 501); err != nil || len(found) != 0 {
		t.Fatalf("no listeners: %+v %v", found, err)
	}
	if _, err := lsofListeners(context.Background(), fakeLsof(t, "exit 2\n"), 501); err == nil {
		t.Fatal("a failing lsof was accepted")
	}

	// Output beyond the cap is dropped at a line boundary.
	var output strings.Builder
	for port := 1; output.Len() <= previewScanOutputCap+4096; port++ {
		fmt.Fprintf(&output, "p%d\ncnode\nn127.0.0.1:%d\n", port, port%60000+1)
	}
	data := filepath.Join(t.TempDir(), "output")
	if err := os.WriteFile(data, []byte(output.String()), 0600); err != nil {
		t.Fatal(err)
	}
	found, err = lsofListeners(context.Background(), fakeLsof(t, fmt.Sprintf("/bin/cat %q\n", data)), 501)
	if err != nil || len(found) == 0 {
		t.Fatalf("capped output: %v", err)
	}
	complete := parseLsofListeners([]byte(output.String()))
	if len(found) >= len(complete) || !reflect.DeepEqual(found, complete[:len(found)]) {
		t.Fatalf("capped output kept %d of %d listeners or changed them", len(found), len(complete))
	}

	original := previewScanTimeout
	previewScanTimeout = 200 * time.Millisecond
	defer func() { previewScanTimeout = original }()
	began := time.Now()
	if _, err := lsofListeners(context.Background(), fakeLsof(t, "exec /bin/sleep 10\n"), 501); err == nil || time.Since(began) > 3*time.Second {
		t.Fatalf("a hanging lsof: %v after %v", err, time.Since(began))
	}
}

// The real platform scan finds a loopback listener of this process.
func TestPlatformListenersFindThisProcessListening(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("no port discovery on " + runtime.GOOS)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	found, err := platformListeners(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range found {
		if entry.port == port && entry.ip.Equal(net.IPv4(127, 0, 0, 1)) {
			if entry.pid != os.Getpid() && entry.pid != 0 {
				t.Fatalf("port %d belongs to pid %d, not this test (%d)", port, entry.pid, os.Getpid())
			}
			if entry.process == "" && runtime.GOOS == "darwin" {
				t.Fatal("lsof named no process")
			}
			if strings.Contains(entry.process, "/") {
				t.Fatalf("process %q is not an executable name", entry.process)
			}
			// This host's own sockets are never offered.
			if entry.pid == os.Getpid() {
				for _, offered := range filterPreviewPorts(found, nil, os.Getpid()) {
					if offered.Port == port {
						t.Fatalf("own listener offered: %+v", offered)
					}
				}
			}
			return
		}
	}
	t.Fatalf("port %d not found among %d listeners", port, len(found))
}
