package host

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Port discovery for web previews. A platform scan (lsof on macOS, /proc/net
// on Linux, nothing elsewhere) lists the TCP sockets this user's processes
// listen on; filterPreviewPorts keeps those the proxy can reach over loopback
// and drops the ports AgentLand never proxies. The parsers here build on
// every platform so their tests run everywhere.

// previewScanTimeout bounds one platform scan; tests shorten it.
var previewScanTimeout = 3 * time.Second

const (
	previewScanOutputCap = 256 << 10
	// previewPortsLimit bounds the answer of GET /v1/preview/ports.
	previewPortsLimit     = 256
	previewProcessNameMax = 64
	// Linux: the /proc/net tables read, and how far the search for the
	// process holding each listening socket goes.
	procNetTableLimit   = 16 << 20
	procOwnerProcesses  = 4096
	procOwnerLinks      = 65536
	procCommandNameSize = 256
)

// previewDefaultExcludedPorts are SSH, printing (CUPS), the Docker API and
// common databases and search servers. Discovery hides them and sessions
// refuse them unless the host allows them (PreviewOptions.AllowPorts).
var previewDefaultExcludedPorts = []int{22, 631, 2375, 2376, 3306, 5432, 6379, 9200, 27017}

// PreviewPort is one entry of GET /v1/preview/ports. Address is "127.0.0.1",
// "::1" or "*" (every address); Process is the executable name only, never a
// command line, and is left out when unknown.
type PreviewPort struct {
	Port    int    `json:"port"`
	Address string `json:"address"`
	Process string `json:"process,omitempty"`
}

// portListener is one listening socket from a platform scan.
type portListener struct {
	ip      net.IP // IPv6unspecified for lsof's "*"
	port    int
	process string
	pid     int
}

// previewAddress names the addresses a preview can reach: the proxy dials
// 127.0.0.1 and then ::1, so a socket bound to another address (including
// other 127.x addresses) cannot be previewed. A higher rank names more
// addresses.
func previewAddress(ip net.IP) (string, int) {
	switch {
	case ip == nil:
		return "", 0
	case ip.IsUnspecified():
		return "*", 3
	case ip.Equal(net.IPv4(127, 0, 0, 1)):
		return "127.0.0.1", 2
	case ip.Equal(net.IPv6loopback):
		return "::1", 1
	}
	return "", 0
}

// filterPreviewPorts keeps one entry per port a preview can reach, drops
// excluded ports and sockets of this host process, and sorts by port.
func filterPreviewPorts(found []portListener, excluded map[int]bool, ownPID int) []PreviewPort {
	type choice struct {
		rank  int
		entry PreviewPort
	}
	best := map[int]choice{}
	for _, listener := range found {
		if listener.port < 1 || listener.port > 65535 || excluded[listener.port] || (ownPID > 0 && listener.pid == ownPID) {
			continue
		}
		address, rank := previewAddress(listener.ip)
		if rank == 0 {
			continue
		}
		current, seen := best[listener.port]
		if seen && (current.rank > rank || (current.rank == rank && (current.entry.Process != "" || listener.process == ""))) {
			continue
		}
		best[listener.port] = choice{rank, PreviewPort{Port: listener.port, Address: address, Process: listener.process}}
	}
	ports := make([]PreviewPort, 0, len(best))
	for _, chosen := range best {
		ports = append(ports, chosen.entry)
	}
	sort.Slice(ports, func(i, j int) bool { return ports[i].Port < ports[j].Port })
	if len(ports) > previewPortsLimit {
		ports = ports[:previewPortsLimit]
	}
	return ports
}

// cleanProcessName keeps an executable name only: the last path element,
// without control characters, at most previewProcessNameMax bytes of valid
// UTF-8.
func cleanProcessName(name string) string {
	name = strings.ToValidUTF8(name, "")
	if index := strings.LastIndexByte(name, '/'); index >= 0 {
		name = name[index+1:]
	}
	name = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, name))
	for len(name) > previewProcessNameMax {
		_, size := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-size]
	}
	return name
}

// loopbackURLPort is the port of a configured loopback URL such as the
// OpenCode server's, or 0 when it has none.
func loopbackURLPort(raw string) int {
	u, err := url.Parse(raw)
	if err != nil {
		return 0
	}
	port := u.Port()
	if port == "" {
		switch u.Scheme {
		case "http":
			return 80
		case "https":
			return 443
		}
		return 0
	}
	number, err := strconv.Atoi(port)
	if err != nil {
		return 0
	}
	return number
}

// macOS: lsof field output.

// lsofListeners runs lsof for uid's listening TCP sockets, bounded by
// previewScanTimeout and previewScanOutputCap. lsof exits 1 when nothing
// matches; its output, if any, is still used then.
func lsofListeners(ctx context.Context, program string, uid int) ([]portListener, error) {
	ctx, cancel := context.WithTimeout(ctx, previewScanTimeout)
	defer cancel()
	output := &cappedOutput{limit: previewScanOutputCap}
	command := exec.CommandContext(ctx, program, "-nP", "-w", "-a", "-iTCP", "-sTCP:LISTEN", "-u", strconv.Itoa(uid), "-F", "pcn")
	command.Env = []string{"LC_ALL=C"}
	command.Stdout = output
	command.WaitDelay = time.Second
	err := command.Run()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("lsof did not finish within %v", previewScanTimeout)
	}
	var exit *exec.ExitError
	if err != nil && !(errors.As(err, &exit) && exit.ExitCode() == 1) {
		return nil, fmt.Errorf("lsof: %w", err)
	}
	data := output.data
	if output.truncated {
		// Only whole lines: a cut "n127.0.0.1:517" would name another port.
		data = data[:bytes.LastIndexByte(data, '\n')+1]
	}
	return parseLsofListeners(data), nil
}

// cappedOutput keeps the first limit bytes written to it and accepts, but
// drops, the rest, so the writing process is never blocked.
type cappedOutput struct {
	data      []byte
	limit     int
	truncated bool
}

func (c *cappedOutput) Write(p []byte) (int, error) {
	room := c.limit - len(c.data)
	if room < len(p) {
		c.truncated = true
		if room > 0 {
			c.data = append(c.data, p[:room]...)
		}
		return len(p), nil
	}
	c.data = append(c.data, p...)
	return len(p), nil
}

// parseLsofListeners reads lsof field output (-F pcn): a "p<pid>" line starts
// each process, "c<name>" names it and each "n<address>:<port>" line is one
// listening socket. Other fields, such as the file descriptor ("f"), are
// ignored.
func parseLsofListeners(output []byte) []portListener {
	var found []portListener
	pid, process := 0, ""
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			continue
		}
		value := line[1:]
		switch line[0] {
		case 'p':
			pid, process = 0, ""
			if number, err := strconv.Atoi(value); err == nil && number > 0 {
				pid = number
			}
		case 'c':
			process = cleanProcessName(value)
		case 'n':
			if ip, port, ok := parseLsofAddress(value); ok {
				found = append(found, portListener{ip: ip, port: port, process: process, pid: pid})
			}
		}
	}
	return found
}

// parseLsofAddress reads "*:3000", "127.0.0.1:5173" or "[::1]:8080".
func parseLsofAddress(name string) (net.IP, int, bool) {
	if strings.Contains(name, "->") {
		return nil, 0, false
	}
	host, portText, err := net.SplitHostPort(name)
	if err != nil {
		return nil, 0, false
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, 0, false
	}
	if host == "*" {
		return net.IPv6unspecified, port, true
	}
	host, _, _ = strings.Cut(host, "%")
	ip := net.ParseIP(host)
	if ip == nil {
		return nil, 0, false
	}
	return ip, port, true
}

// Linux: /proc/net/tcp and /proc/net/tcp6.

// procListeners reads uid's listening sockets from root/net/tcp and tcp6 and,
// best effort, the process holding each. A missing tcp6 table means IPv6 is
// off.
func procListeners(ctx context.Context, root string, uid int) ([]portListener, error) {
	var sockets []procSocket
	for _, table := range []string{"tcp", "tcp6"} {
		found, err := readProcNetTable(filepath.Join(root, "net", table), uid)
		if err != nil {
			if table == "tcp6" && errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return nil, err
		}
		sockets = append(sockets, found...)
	}
	inodes := map[uint64]bool{}
	for _, socket := range sockets {
		if socket.inode != 0 {
			inodes[socket.inode] = true
		}
	}
	owners := procSocketOwners(ctx, root, inodes)
	found := make([]portListener, 0, len(sockets))
	for _, socket := range sockets {
		owner := owners[socket.inode]
		found = append(found, portListener{ip: socket.ip, port: socket.port, process: owner.name, pid: owner.pid})
	}
	return found, nil
}

func readProcNetTable(path string, uid int) ([]procSocket, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return parseProcNetTCP(io.LimitReader(file, procNetTableLimit), uid, binary.NativeEndian)
}

// procSocket is one listening socket from /proc/net/tcp or tcp6.
type procSocket struct {
	ip    net.IP
	port  int
	inode uint64
}

// parseProcNetTCP returns the listening sockets (state 0A) owned by uid. The
// kernel prints each 32-bit word of an address as a number in its own byte
// order, which order gives; ports are printed in host order.
func parseProcNetTCP(r io.Reader, uid int, order binary.ByteOrder) ([]procSocket, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 4096), 64<<10)
	var found []procSocket
	header := true
	for scanner.Scan() {
		if header {
			header = false
			continue
		}
		fields := strings.Fields(scanner.Text())
		if len(fields) < 10 || fields[3] != "0A" {
			continue
		}
		if owner, err := strconv.Atoi(fields[7]); err != nil || owner != uid {
			continue
		}
		ip, port, ok := parseProcAddress(fields[1], order)
		if !ok {
			continue
		}
		inode, _ := strconv.ParseUint(fields[9], 10, 64)
		found = append(found, procSocket{ip: ip, port: port, inode: inode})
	}
	return found, scanner.Err()
}

func parseProcAddress(text string, order binary.ByteOrder) (net.IP, int, bool) {
	hexIP, hexPort, ok := strings.Cut(text, ":")
	if !ok {
		return nil, 0, false
	}
	port, err := strconv.ParseUint(hexPort, 16, 16)
	if err != nil || port == 0 {
		return nil, 0, false
	}
	raw, err := hex.DecodeString(hexIP)
	if err != nil || (len(raw) != net.IPv4len && len(raw) != net.IPv6len) {
		return nil, 0, false
	}
	ip := make(net.IP, len(raw))
	for i := 0; i < len(raw); i += 4 {
		order.PutUint32(ip[i:], binary.BigEndian.Uint32(raw[i:]))
	}
	return ip, int(port), true
}

type procOwner struct {
	pid  int
	name string
}

// procSocketOwners finds the process holding each socket inode through the
// root/<pid>/fd links it may read (only this user's processes), bounded by
// procOwnerProcesses, procOwnerLinks and ctx.
func procSocketOwners(ctx context.Context, root string, inodes map[uint64]bool) map[uint64]procOwner {
	owners := map[uint64]procOwner{}
	if len(inodes) == 0 {
		return owners
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return owners
	}
	processes, links := 0, 0
	for _, entry := range entries {
		if len(owners) == len(inodes) || processes >= procOwnerProcesses || links >= procOwnerLinks || ctx.Err() != nil {
			break
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		processes++
		directory := filepath.Join(root, entry.Name(), "fd")
		descriptors, err := os.ReadDir(directory)
		if err != nil {
			continue
		}
		name := ""
		for _, descriptor := range descriptors {
			if links++; links > procOwnerLinks {
				break
			}
			target, err := os.Readlink(filepath.Join(directory, descriptor.Name()))
			if err != nil || !strings.HasPrefix(target, "socket:[") || !strings.HasSuffix(target, "]") {
				continue
			}
			inode, err := strconv.ParseUint(target[len("socket:["):len(target)-1], 10, 64)
			if err != nil || !inodes[inode] {
				continue
			}
			if _, known := owners[inode]; known {
				continue
			}
			if name == "" {
				name = procCommandName(filepath.Join(root, entry.Name(), "comm"))
			}
			owners[inode] = procOwner{pid: pid, name: name}
		}
	}
	return owners
}

func procCommandName(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	data, _ := io.ReadAll(io.LimitReader(file, procCommandNameSize))
	return cleanProcessName(string(data))
}
