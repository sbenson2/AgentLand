package host

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

// `agentland-host install-opencode` (docs/HOST-API.md "install-opencode").
// The Mac app ships no OpenCode, so it runs this before it starts OpenCode,
// on a first launch and whenever the managed OpenCode is missing or damaged.
// It holds the state's lock (LockState) and makes sure a valid managed
// OpenCode is there, through the catalog's own install path, reporting how
// it goes as one JSON object per line.

// InstallOpenCodeOptions are install-opencode's settings.
type InstallOpenCodeOptions struct {
	// StatePath is the host's state file (host.json); OpenCode goes into
	// <StatePath>.agents/opencode.
	StatePath string
	// Version names the host in the registry's User-Agent.
	Version string
	// Output gets the events, one JSON object per line.
	Output io.Writer
	// configure adjusts the catalog before it is used (tests: a fake
	// registry).
	configure func(*agentCatalog)
}

// installEvent is one line of install-opencode's output.
type installEvent struct {
	Event    string `json:"event"`
	Version  string `json:"version,omitempty"`
	Received *int64 `json:"received,omitempty"`
	Total    *int64 `json:"total,omitempty"`
	Code     string `json:"code,omitempty"`
	Error    string `json:"error,omitempty"`
}

// installEvents writes install-opencode's events. It is the catalog's
// installObserver.
type installEvents struct {
	mu    sync.Mutex
	out   io.Writer
	homes []string
}

func (e *installEvents) write(event installEvent) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	_, _ = e.out.Write(append(data, '\n'))
}

func (e *installEvents) readingRegistry() { e.write(installEvent{Event: "registry"}) }

func (e *installEvents) downloading(version string, received, total int64) {
	event := installEvent{Event: "downloading", Version: version, Received: &received}
	if total >= 0 {
		event.Total = &total
	}
	e.write(event)
}

func (e *installEvents) checking(version string) {
	e.write(installEvent{Event: "checking", Version: version})
}

// fail writes the failed event, with paths under the home folder as ~/…,
// and returns the error the command exits with.
func (e *installEvents) fail(code, message string) error {
	e.mu.Lock()
	homes := e.homes
	e.mu.Unlock()
	message, _ = clipText(withoutHomes(message, homes), 1000)
	e.write(installEvent{Event: "failed", Code: code, Error: message})
	return &openCodeFailure{code: code, message: message}
}

// InstallOpenCodeRefused writes install-opencode's failed event for a
// command line it cannot run, and returns its error.
func InstallOpenCodeRefused(output io.Writer, code, message string) error {
	events := &installEvents{out: output, homes: (&agentCatalog{}).homeFolders()}
	return events.fail(code, message)
}

// InstallOpenCode makes sure <state>.agents/opencode holds a valid managed
// OpenCode. With one that passes every check (managedOpenCode, the Mac
// app's checks with its sha256), it reports ready at once and downloads
// nothing. Otherwise it reads the registry and installs the registry's
// OpenCode through the catalog's install path (installOpenCode: a binary
// checked by sha256 only, then OpenCode's check, then current.json), with
// the catalog's time limits and its clean environment for the check. It
// fails at once when another process holds the state's lock. Its events:
//
//	{"event":"registry"}
//	{"event":"downloading","version":"1.18.32","received":N,"total":M}
//	{"event":"checking","version":"1.18.32"}
//	{"event":"ready","version":"1.18.32"}
//	{"event":"failed","code":"…","error":"…"}
//
// The error it returns (nil after ready) is the failed event's.
func InstallOpenCode(ctx context.Context, options InstallOpenCodeOptions) error {
	events := &installEvents{out: options.Output, homes: (&agentCatalog{}).homeFolders()}
	if options.StatePath == "" {
		return events.fail("invalid_arguments", "--state names no state file.")
	}
	release, err := LockState(options.StatePath)
	switch {
	case errors.Is(err, ErrStateBusy):
		return events.fail("busy", "Another AgentLand host or install-opencode is using this state; quit it and try again.")
	case err != nil:
		return events.fail("storage_error", "The state's lock could not be taken: "+err.Error())
	}
	defer release()
	catalog := newAgentCatalog(nil, options.StatePath, AgentOptions{Version: options.Version})
	defer catalog.close()
	catalog.noIcons, catalog.observer = true, events
	if options.configure != nil {
		options.configure(catalog)
	}
	events.mu.Lock()
	events.homes = catalog.homeFolders()
	events.mu.Unlock()
	// What an install stopped midway left: its download and check folders.
	_ = catalog.store.pruneLeftovers("opencode")
	version, err := catalog.ensureOpenCode(ctx)
	var failure *openCodeFailure
	switch {
	case err == nil:
		events.write(installEvent{Event: "ready", Version: version})
		return nil
	case ctx.Err() != nil:
		return events.fail("cancelled", "The install was stopped before it finished.")
	case errors.As(err, &failure):
		return events.fail(failure.code, failure.message)
	}
	return events.fail("storage_error", err.Error())
}
