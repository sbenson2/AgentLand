package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// Agents left running by a host that was killed. Such a host never ends its
// agents, and one that ignores the end of its input keeps running. So the
// host records every agent process it starts (ACP agents, Claude Code,
// Codex's app-server and its exec runs), by pid and the kernel's start time,
// in <state>.acp-processes.json, and the next host ends each one that is
// certainly that process and whose host is gone: the same pid and start time
// (to the microsecond), the leader of its own process group, adopted by
// launchd, this user's, and running what the host ran:
//
//   - an ACP agent: an executable inside the agents folder, or node running a
//     script inside it (npm installs run as node; a record that names the
//     agent's command requires that very script);
//   - Claude Code or Codex: exactly the executable the host ran, as the kernel
//     reports it (the path the host passed to exec).
//
// Its whole group gets SIGKILL. Only macOS reads start times here; elsewhere
// the records stay empty and nothing is ended. Nothing the host did not start
// is ended.

// acpProcessRecord is one agent process the host started.
type acpProcessRecord struct {
	Pid int `json:"pid"`
	// Start is the kernel's start time, in microseconds since 1970.
	Start int64 `json:"start"`
	// Command is an ACP agent's command as the host started it: for an npm
	// install, the script node runs. Records of older hosts have none.
	Command string `json:"command,omitempty"`
	// Executable is set for Claude Code and Codex: the absolute path the host
	// ran. Only a process whose executable is that path is ended.
	Executable string `json:"executable,omitempty"`
}

// processRecord is the record of a process the host just started (its pid
// and start time), or an empty one when its start time cannot be read.
func processRecord(process *os.Process) acpProcessRecord {
	if process == nil {
		return acpProcessRecord{}
	}
	start, ok := acpProcessStart(process.Pid)
	if !ok {
		return acpProcessRecord{}
	}
	return acpProcessRecord{Pid: process.Pid, Start: start}
}

// executableRecord is the record of a Claude Code or Codex process the host
// started from path, or an empty one when path is not absolute.
func executableRecord(process *os.Process, path string) acpProcessRecord {
	if !filepath.IsAbs(path) {
		return acpProcessRecord{}
	}
	record := processRecord(process)
	record.Executable = path
	return record
}

// agentProcesses keeps the records of the agent processes running now, for
// the next host.
type agentProcesses struct {
	mu      sync.Mutex
	path    string
	running map[any]acpProcessRecord
	writeMu sync.Mutex // one records write at a time
}

func newAgentProcesses() *agentProcesses {
	return &agentProcesses{running: map[any]acpProcessRecord{}}
}

// add records a process under key; one whose start time could not be read
// is not recorded.
func (p *agentProcesses) add(key any, record acpProcessRecord) {
	if p == nil || record.Pid <= 0 {
		return
	}
	p.mu.Lock()
	p.running[key] = record
	p.mu.Unlock()
	p.save()
}

// remove forgets the process under key once it has ended.
func (p *agentProcesses) remove(key any) {
	if p == nil {
		return
	}
	p.mu.Lock()
	_, had := p.running[key]
	delete(p.running, key)
	p.mu.Unlock()
	if had {
		p.save()
	}
}

// keep ends the leftovers the records in path name (ACP agents' by the
// agents folder), then records this host's processes there.
func (p *agentProcesses) keep(path, agents string) {
	var records []acpProcessRecord
	if data, err := readPrivateState(path); err == nil {
		_ = json.Unmarshal(data, &records)
	}
	for _, record := range records {
		acpEndLeftover(record, agents)
	}
	p.mu.Lock()
	p.path = path
	p.mu.Unlock()
	p.save()
}

// save writes the records of the processes running now.
func (p *agentProcesses) save() {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.mu.Lock()
	path := p.path
	records := make([]acpProcessRecord, 0, len(p.running))
	for _, record := range p.running {
		records = append(records, record)
	}
	p.mu.Unlock()
	if path == "" {
		return
	}
	sort.Slice(records, func(i, j int) bool { return records[i].Pid < records[j].Pid })
	data, _ := json.Marshal(records)
	_ = writePrivateState(path, append(data, '\n'))
}
