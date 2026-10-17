package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

// The check a new version passes before it becomes current (docs/HOST-API.md
// "Installs, updates and uninstalls"): ACP initialize for ACP agents, and a
// throwaway `opencode serve` for OpenCode. No session is made and no model is
// called.

// acpCheckHandler answers what an agent sends during the check: nothing is
// served.
type acpCheckHandler struct{}

func (acpCheckHandler) acpNotification(*acpConn, string, json.RawMessage) {}
func (acpCheckHandler) acpRequest(conn *acpConn, id json.RawMessage, _ string, _ json.RawMessage) {
	go func() { _ = conn.respondError(id, acpMethodNotFound, "Method not found") }()
}
func (acpCheckHandler) acpOversized(conn *acpConn) { conn.kill() }

// checkACPInitialize starts the agent and sends initialize: protocol version
// 1 within wait passes.
func checkACPInitialize(ctx context.Context, launch acpLaunchSpec, dir string, env []string, wait time.Duration) error {
	conn, err := startACPConn(acpSpawn{command: launch.command, args: launch.args, dir: dir, env: env}, acpCheckHandler{}, nil)
	if err != nil {
		return errors.New("The new version did not start.")
	}
	defer conn.stop(2 * time.Second)
	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	var raw json.RawMessage
	err = conn.call(ctx, "initialize", acpInitializeParams(), &raw)
	var rpc *acpRPCError
	switch {
	case errors.As(err, &rpc):
		message, _ := clipText(rpc.Message, 200)
		return fmt.Errorf("The new version refused initialize: %s.", message)
	case errors.Is(err, context.DeadlineExceeded):
		return fmt.Errorf("The new version did not answer initialize within %d seconds.", int(wait/time.Second))
	case ctx.Err() != nil:
		return ctx.Err()
	case err != nil:
		return errors.New("The new version ended before it answered initialize.")
	}
	if _, err := parseACPInitialize(raw); err != nil {
		return errors.New("The new version does not speak ACP protocol version 1.")
	}
	return nil
}

// freeLoopbackPort asks the system for a free port on 127.0.0.1.
func freeLoopbackPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

// checkOpenCode starts `opencode serve` on a free loopback port with
// throwaway folders and a random password, and asks it for its health and
// version, its sessions and its providers.
func checkOpenCode(ctx context.Context, command, version string, wait time.Duration, base []string, scratch string) error {
	root, err := os.MkdirTemp(scratch, ".check-")
	if err != nil {
		return errors.New("The check's folders could not be made.")
	}
	defer os.RemoveAll(root)
	folders := map[string]string{}
	for _, name := range []string{"home", "config", "data", "state", "cache", "tmp", "project"} {
		folders[name] = filepath.Join(root, name)
		if err := os.Mkdir(folders[name], 0o700); err != nil {
			return errors.New("The check's folders could not be made.")
		}
	}
	port, err := freeLoopbackPort()
	if err != nil {
		return errors.New("No loopback port was free for the check.")
	}
	var secret [24]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return err
	}
	password := hex.EncodeToString(secret[:])
	env := agentEnvironment(base, func(name string) bool { return name == "PATH" || name == "USER" || name == "LANG" }, "", map[string]string{
		"HOME": folders["home"], "OPENCODE_TEST_HOME": folders["home"], "XDG_CONFIG_HOME": folders["config"], "XDG_DATA_HOME": folders["data"],
		"XDG_STATE_HOME": folders["state"], "XDG_CACHE_HOME": folders["cache"], "TMPDIR": folders["tmp"],
		"OPENCODE_SERVER_PASSWORD": password, "OPENCODE_DISABLE_AUTOUPDATE": "true", "SHELL": "/bin/sh",
	})
	ctx, cancel := context.WithTimeout(ctx, wait+15*time.Second)
	defer cancel()
	process := exec.Command(command, "serve", "--pure", "--hostname", "127.0.0.1", "--port", strconv.Itoa(port))
	process.Dir = folders["project"]
	process.Env = env
	process.SysProcAttr = claudeProcessAttributes()
	output := newCodexRing(16 << 10)
	process.Stdout, process.Stderr = output, output
	// A process that left the group (its own session) keeps the output pipes
	// open after the group is ended: 2 s after OpenCode exits they are closed,
	// so the check never waits for it.
	process.WaitDelay = 2 * time.Second
	if err := process.Start(); err != nil {
		return errors.New("The new OpenCode did not start.")
	}
	exited := make(chan struct{})
	go func() {
		_ = process.Wait()
		close(exited)
	}()
	defer func() {
		// The group is signalled only while its leader is not reaped.
		select {
		case <-exited:
		default:
			claudeSignalGroup(process.Process, false)
			select {
			case <-exited:
			case <-time.After(3 * time.Second):
				claudeSignalGroup(process.Process, true)
				<-exited
			}
		}
		claudeReapGroup(process.Process.Pid)
	}()
	address := "http://127.0.0.1:" + strconv.Itoa(port)
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(route string, out any) error {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, address+route, nil)
		if err != nil {
			return err
		}
		request.SetBasicAuth("opencode", password)
		request.Header.Set("X-OpenCode-Directory", folders["project"])
		response, err := client.Do(request)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
			return fmt.Errorf("HTTP %d", response.StatusCode)
		}
		return json.NewDecoder(io.LimitReader(response.Body, 64<<20)).Decode(out)
	}
	deadline := time.Now().Add(wait)
	var health struct {
		Healthy bool   `json:"healthy"`
		Version string `json:"version"`
	}
	for {
		select {
		case <-exited:
			return errors.New("The new OpenCode stopped before it answered.")
		default:
		}
		if err := get("/global/health", &health); err == nil && health.Healthy {
			break
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			if ctx.Err() != nil && !errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return ctx.Err()
			}
			return fmt.Errorf("The new OpenCode did not answer within %d seconds.", int(wait/time.Second))
		}
		select {
		case <-time.After(200 * time.Millisecond):
		case <-ctx.Done():
		}
	}
	if health.Version != version {
		reported, _ := clipText(health.Version, 64)
		return fmt.Errorf("The new OpenCode reported version %q, not %q.", reported, version)
	}
	var sessions []json.RawMessage
	if err := get("/session", &sessions); err != nil {
		return errors.New("The new OpenCode did not list its sessions.")
	}
	var providers struct {
		All []json.RawMessage `json:"all"`
	}
	if err := get("/provider", &providers); err != nil || providers.All == nil {
		return errors.New("The new OpenCode did not list its providers.")
	}
	return nil
}
