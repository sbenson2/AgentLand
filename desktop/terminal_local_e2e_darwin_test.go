//go:build darwin

package host

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"agentland/host/internal/localterm"
	"agentland/host/internal/termrun"
	"agentland/host/keeper"
)

// This test binary is also the job-control leader termrun.Run starts as
// `<this binary> terminals _lead -- …`, as agentland-host is.
func init() {
	if len(os.Args) > 2 && os.Args[1] == "terminals" && os.Args[2] == termrun.LeadCommand {
		os.Exit(termrun.Lead(os.Args[3:]))
	}
}

// e2eWindow stands in for a Terminal.app window: `terminals run` gets the
// slave, the test reads and types on the master.
type e2eWindow struct {
	master, slave *os.File
	mu            sync.Mutex
	out           []byte
	done          chan struct{}
}

func newE2EWindow(t *testing.T) *e2eWindow {
	t.Helper()
	master, slave, err := keeper.OpenPTY()
	if err != nil {
		t.Fatal(err)
	}
	if err := keeper.SetSize(slave, 24, 80); err != nil {
		t.Fatal(err)
	}
	w := &e2eWindow{master: master, slave: slave, done: make(chan struct{})}
	go func() {
		defer close(w.done)
		buf := make([]byte, 32<<10)
		for {
			n, err := master.Read(buf)
			w.mu.Lock()
			w.out = append(w.out, buf[:n]...)
			w.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() {
		master.Close()
		<-w.done
		slave.Close()
	})
	return w
}

func (w *e2eWindow) waitFor(t *testing.T, pattern string) []string {
	t.Helper()
	re := regexp.MustCompile(pattern)
	deadline := time.Now().Add(15 * time.Second)
	for {
		w.mu.Lock()
		out := string(w.out)
		w.mu.Unlock()
		if match := re.FindStringSubmatch(out); match != nil {
			return match
		}
		if time.Now().After(deadline) {
			t.Fatalf("the window never showed %s; it shows %q", pattern, out)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (w *e2eWindow) typeText(t *testing.T, text string) {
	t.Helper()
	if _, err := w.master.Write([]byte(text)); err != nil {
		t.Fatal(err)
	}
}

// Claude typed in Terminal.app, through the real host and keeper: a paired
// device reads it and types into it, and the window keeps working after the
// host stops.
func TestRunThroughTheRealHostAndKeeper(t *testing.T) {
	dir := shortTempDir(t)
	statePath := filepath.Join(dir, "state.json")
	store := NewStore(statePath)
	if err := store.Initialize(Config{Projects: []Project{{ID: "p1", Name: "Project", Directory: t.TempDir()}}, OpenCodeURL: "http://127.0.0.1:4096", PasswordEnv: "TEST_PASSWORD"}); err != nil {
		t.Fatal(err)
	}
	binary := hostBinary(t)
	backend := NewKeeperBackend(KeeperBackendOptions{StatePath: statePath, LogPath: filepath.Join(dir, "terminals.log"), Executable: binary, Version: "test"})
	t.Cleanup(func() {
		exec.Command(binary, "terminals", "stop", "--state", statePath).Run()
	})
	host := NewWithOptions(store, &fakeAgent{}, HostOptions{TerminalEnabled: true, Terminals: backend, Version: "test"})
	t.Cleanup(func() { host.Close() })
	local, err := host.ListenLocalTerminals(localterm.SocketPath(statePath))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { local.Close() })
	token := paired(t, host, store)
	// A keeper already runs, as the host keeps one while routing is on: the
	// CLI's 1 s budget never covers starting one.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if _, err := backend.Features(ctx); err != nil {
		t.Fatal(err)
	}

	bin := t.TempDir()
	script := "#!/bin/sh\nstty -echo\necho \"first:$AGENTLAND_TERMINAL\"\nwhile IFS= read -r l; do [ \"$l\" = bye ] && exit 4; echo \"got:$l\"; done\n"
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	var env []string
	for _, kv := range os.Environ() {
		// This test may itself run inside an AgentLand terminal.
		if !strings.HasPrefix(kv, "AGENTLAND_TERMINAL=") && !strings.HasPrefix(kv, "PATH=") {
			env = append(env, kv)
		}
	}
	env = append(env, "PATH="+bin+":/usr/bin:/bin")
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := newE2EWindow(t)
	signals := make(chan os.Signal, 2)
	finished := make(chan struct{})
	var code int
	go func() {
		defer close(finished)
		code = termrun.Run(termrun.Options{
			StatePath: statePath, Version: "test", Name: "claude",
			Stdin: w.slave, Stdout: w.slave, Stderr: w.slave,
			Env: env, Dir: folder, Signals: signals,
		})
	}()
	t.Cleanup(func() {
		select {
		case <-finished:
		default:
			signals <- syscall.SIGHUP
			select {
			case <-finished:
			case <-time.After(15 * time.Second):
				t.Error("terminals run never returned")
			}
		}
	})
	id := w.waitFor(t, `first:(term_[0-9a-f]+)\r\n`)[1]

	// The device reads the agent with no workspace, and types into it.
	deadline := time.Now().Add(15 * time.Second)
	for {
		response := request(t, host.Handler(), "GET", fmt.Sprintf("/v1/terminal/output?terminalId=%s&cursor=0&wait=0", id), token, nil)
		if response.Code == 200 && strings.Contains(string(decodeBody[terminalOutput](t, response).Data), "first:"+id) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the device never read the agent: %d %s", response.Code, response.Body)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if response := request(t, host.Handler(), "POST", "/v1/terminal/input", token, map[string]any{"terminalId": id, "data": []byte("phone\n")}); response.Code != 200 && response.Code != 204 {
		t.Fatalf("input: %d %s", response.Code, response.Body)
	}
	w.waitFor(t, `got:phone\r\n`)

	// The window talks to the keeper itself, so it outlives the host.
	if err := local.Close(); err != nil {
		t.Fatal(err)
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	w.typeText(t, "after\r")
	w.waitFor(t, `got:after\r\n`)
	w.typeText(t, "bye\r")
	select {
	case <-finished:
		if code != 4 {
			t.Fatalf("terminals run returned %d, want 4", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("terminals run still runs after the agent exited")
	}
}
