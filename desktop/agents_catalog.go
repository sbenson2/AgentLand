package host

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"maps"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// The agent catalog (docs/HOST-API.md "Agents"): the registry's agents, the
// agents already on the Mac and the managed installs, with their state. It
// installs, updates and uninstalls (agents_install.go), updates on its own
// (agents_update.go) and tells the ACP engine and the terminals how each
// agent runs.

// AgentOptions turns the catalog on (serve does unless --no-agents).
type AgentOptions struct {
	// Version names the host in the User-Agent of its registry requests.
	Version string
}

type agentCatalog struct {
	host        *Host
	store       agentStore
	fetcher     *agentFetcher
	registryURL string
	platform    string
	started     time.Time

	// Seams, set before start: how commands are found and their versions
	// read, the environment's base, and the timings.
	lookup                                 func(program string) (string, bool)
	versionOf                              func(path string) string
	baseEnv                                []string
	checkWait, openCodeWait, installWait   time.Duration
	localUpdateHelpWait, localUpdateWait   time.Duration
	terminalUpdateWait, launchUpdateEvery  time.Duration
	firstRun, every, idlePoll, sampleEvery time.Duration
	jitter                                 func() time.Duration
	registryWait, iconWait, registryStale  time.Duration
	attemptGap                             time.Duration
	openCodeCheck                          func(ctx context.Context, command, version string) error
	now                                    func() time.Time
	agentBusyFor                           func(id string) bool
	anythingRunsFor                        func() bool
	runningOpenCode                        func() string
	checkACPFor                            func(ctx context.Context, id string, current agentCurrent) error
	unpackLimits                           agentUnpackLimits
	archiveLimit                           int64
	iconLimit                              int64
	// observer hears how installs go (install-opencode's events); noIcons
	// fetches no icons after a registry read. Both are for install-opencode.
	observer installObserver
	noIcons  bool
	// logf writes the update log's lines (agents_terminal.go logUpdate);
	// nil is the host's log.
	logf func(format string, args ...any)

	mu     sync.Mutex
	agents []registryAgent // the registry's entries, sorted by id
	// byID is agents by catalog id (claude-acp and codex-acp under claude
	// and codex) and iconURLs their icons by registry id; both are made anew
	// with agents and never changed.
	byID        map[string]registryAgent
	iconURLs    map[string]string
	document    []byte
	etag        string
	fetchedAt   time.Time
	fetchErr    string
	lastAttempt time.Time
	fetching    *agentRegistryFetch
	ops         map[string]*agentOp
	// deferred: agents whose automatic update waited for running terminals.
	deferred map[string]bool
	versions map[string]agentVersionEntry
	iconBusy map[string]*iconFetch
	lastBusy time.Time
	closed   bool

	// automaticAttempts: when each agent's last automatic update (before a
	// launch, or the background run's) started, for the hourly rule
	// (agents_terminal.go). Kept in memory, under mu: a host start may update
	// once more.
	automaticAttempts map[string]time.Time

	// updaterMu guards the capability cache for the owner's local Codex and
	// Claude Code installs. A probe is bounded, but serializing the two rare
	// probes also ensures one executable identity is never checked twice.
	updaterGate chan struct{}
	updaterMu   sync.Mutex
	updaters    map[string]localUpdaterEntry

	// iconMu orders the writes into .icons; iconBytes is what they hold, -1
	// until read.
	iconMu    sync.Mutex
	iconBytes int64

	ctx    context.Context
	cancel context.CancelFunc
	work   sync.WaitGroup
}

type agentRegistryFetch struct {
	done chan struct{}
	err  error
}

type agentOp struct {
	kind string // install, update, uninstall, rollback or launch
	done chan struct{}
	err  error
	// stop ends a native or automatic update's context (beginUpdate) with its
	// cause, so a launch can stop an update that rewrites the agent in place
	// (errStoppedForLaunch); nil for other changes.
	stop context.CancelCauseFunc
}

func newAgentCatalog(host *Host, statePath string, options AgentOptions) *agentCatalog {
	ctx, cancel := context.WithCancel(context.Background())
	c := &agentCatalog{host: host, store: agentStore{root: statePath + ".agents"}, fetcher: newAgentFetcher(nil, options.Version), registryURL: agentRegistryURL, platform: agentPlatform(), started: time.Now(),
		lookup:    findCommand,
		checkWait: 20 * time.Second, openCodeWait: 30 * time.Second, installWait: 10 * time.Minute,
		terminalUpdateWait: 30 * time.Second, launchUpdateEvery: time.Hour, localUpdateHelpWait: 5 * time.Second, localUpdateWait: 10 * time.Minute,
		firstRun: 2 * time.Minute, every: 24 * time.Hour, idlePoll: time.Minute, sampleEvery: 15 * time.Second,
		registryWait: 10 * time.Second, iconWait: 5 * time.Second, registryStale: time.Hour, attemptGap: time.Minute,
		now: time.Now, unpackLimits: defaultAgentUnpackLimits, archiveLimit: agentArchiveLimit, iconLimit: agentIconCacheLimit,
		ops: map[string]*agentOp{}, deferred: map[string]bool{}, automaticAttempts: map[string]time.Time{}, versions: map[string]agentVersionEntry{}, iconBusy: map[string]*iconFetch{}, iconBytes: -1, updaters: map[string]localUpdaterEntry{}, updaterGate: make(chan struct{}, 1), ctx: ctx, cancel: cancel}
	c.setAgents(nil)
	c.jitter = func() time.Duration {
		var random [8]byte
		_, _ = rand.Read(random[:])
		return time.Duration(binary.LittleEndian.Uint64(random[:]) % uint64(time.Hour))
	}
	c.versionOf = func(path string) string { return runAgentVersion(path, c.baseEnv) }
	c.lastBusy = c.started
	c.loadRegistry()
	return c
}

// start begins the automatic updates and, for the Mac's own session, the
// activity samples behind idleForSeconds. With no valid managed OpenCode,
// the registry's is installed at once (agents_opencode.go).
func (c *agentCatalog) start() {
	if c == nil {
		return
	}
	c.cleanLeftovers()
	// Off the start's path: the check reads the whole program for its
	// sha256.
	c.background(func() { _, _ = c.ensureOpenCode(c.ctx) })
	c.work.Add(1)
	go c.runUpdater()
	if c.host != nil && c.host.localSessionToken != "" {
		c.work.Add(1)
		go c.runSampler()
	}
}

// close cancels installs, checks and runs and waits for them.
func (c *agentCatalog) close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	c.cancel()
	c.work.Wait()
}

// background runs fn on its own goroutine unless the catalog is closing.
func (c *agentCatalog) background(fn func()) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return false
	}
	c.work.Add(1)
	go func() {
		defer c.work.Done()
		fn()
	}()
	return true
}

// cleanLeftovers removes what an install that stopped with the host left:
// every folder of a managed agent but its current and previous versions.
// OpenCode keeps every version: the one the Mac app runs may be older than
// its previous (its folder is kept until OpenCode restarts), and at start the
// host cannot ask it yet.
func (c *agentCatalog) cleanLeftovers() {
	for _, id := range c.store.agentIDs() {
		current, err := c.store.readCurrent(id)
		if err != nil {
			continue
		}
		if _, holdAll := c.host.pruneHold(id); holdAll {
			continue
		}
		if current == nil {
			_ = c.store.prune(id)
			continue
		}
		if id == "opencode" {
			_ = c.store.pruneLeftovers(id)
			continue
		}
		held, _ := c.host.pruneHold(id)
		keep := append([]string{current.Version}, held...)
		if current.Previous != nil {
			keep = append(keep, current.Previous.Version)
		}
		_ = c.store.prune(id, keep...)
	}
}

// The registry.

func (c *agentCatalog) loadRegistry() {
	cache, err := c.store.readRegistry()
	if err != nil {
		return
	}
	agents, err := parseRegistry(cache.Document)
	if err != nil {
		return
	}
	fetched, _ := time.Parse(time.RFC3339Nano, cache.FetchedAt)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setAgents(agents)
	c.document, c.etag, c.fetchedAt = cache.Document, cache.ETag, fetched
}

// setAgents takes a registry's entries and indexes them, with c.mu held (or
// before the catalog is shared).
func (c *agentCatalog) setAgents(agents []registryAgent) {
	byID := make(map[string]registryAgent, len(agents))
	icons := map[string]string{}
	for _, agent := range agents {
		// claude and claude-acp are both claude; the -acp entry wins.
		id := nativeAgentID(agent.ID)
		if _, seen := byID[id]; !seen || strings.HasSuffix(agent.ID, "-acp") {
			byID[id] = agent
		}
		if agent.Icon != "" {
			icons[agent.ID] = agent.Icon
		}
	}
	c.agents, c.byID, c.iconURLs = agents, byID, icons
}

// agentFetchMessage words a failed registry read for registry.error.
func agentFetchMessage(err error) string {
	var network net.Error
	switch {
	case errors.Is(err, errRegistryFormat):
		return "The registry is not in a format this host reads."
	case errors.Is(err, errAgentTooLarge):
		return "The registry is larger than 4 MiB."
	case errors.Is(err, errAgentBadStatus):
		message, _ := clipText(err.Error(), 200)
		return "The registry did not answer: " + message + "."
	case errors.As(err, &network), errors.Is(err, context.DeadlineExceeded):
		return "The registry could not be reached."
	}
	return "The registry could not be read."
}

// refresh reads the registry once; calls meanwhile wait for the same read.
func (c *agentCatalog) refresh(ctx context.Context) error {
	c.mu.Lock()
	if c.fetching != nil {
		fetching := c.fetching
		c.mu.Unlock()
		select {
		case <-fetching.done:
			return fetching.err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	fetching := &agentRegistryFetch{done: make(chan struct{})}
	c.fetching = fetching
	c.lastAttempt = c.now()
	etag := c.etag
	if len(c.document) == 0 {
		etag = ""
	}
	c.mu.Unlock()
	data, newETag, notModified, err := c.fetcher.fetchRegistry(ctx, c.registryURL, etag)
	var agents []registryAgent
	if err == nil && !notModified {
		agents, err = parseRegistry(data)
	}
	now := c.now()
	c.mu.Lock()
	c.fetching = nil
	fetching.err = err
	close(fetching.done)
	if err != nil {
		c.fetchErr = agentFetchMessage(err)
		c.mu.Unlock()
		return err
	}
	c.fetchErr, c.fetchedAt = "", now
	if !notModified {
		c.setAgents(agents)
		c.document, c.etag = data, newETag
	}
	cache := agentRegistryCache{ETag: c.etag, FetchedAt: now.UTC().Format(time.RFC3339Nano), Document: c.document}
	c.mu.Unlock()
	if len(cache.Document) > 0 {
		if err := c.store.ensureRoot(); err == nil {
			_ = c.store.writeRegistry(cache)
		}
	}
	if !c.noIcons {
		c.background(c.prefetchIcons)
	}
	return nil
}

// ensureRegistry reads the registry for GET /v1/agents: waiting up to 10 s
// when the host has none, in the background when its copy is over an hour
// old. After a failed read it waits a minute before trying again.
func (c *agentCatalog) ensureRegistry(ctx context.Context) {
	c.mu.Lock()
	empty := len(c.document) == 0
	stale := c.now().Sub(c.fetchedAt) > c.registryStale
	recent := !c.lastAttempt.IsZero() && c.now().Sub(c.lastAttempt) < c.attemptGap
	c.mu.Unlock()
	if !stale || recent {
		return
	}
	done := make(chan struct{})
	if !c.background(func() {
		defer close(done)
		_ = c.refresh(c.ctx)
	}) || !empty {
		return
	}
	timer := time.NewTimer(c.registryWait)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	case <-ctx.Done():
	}
}

// registryEntry is the registry's entry for a catalog id: claude-acp and
// codex-acp for claude and codex.
func (c *agentCatalog) registryEntry(id string) (registryAgent, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	agent, ok := c.byID[id]
	return agent, ok
}

// The catalog's entries.

// agentJSON is one Agent of GET /v1/agents. Supported is false only for a
// registry agent not installed that offers nothing for this Mac, and absent
// otherwise.
type agentJSON struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Description      string `json:"description,omitempty"`
	Website          string `json:"website,omitempty"`
	License          string `json:"license,omitempty"`
	Source           string `json:"source"`
	State            string `json:"state"`
	InstalledVersion string `json:"installedVersion,omitempty"`
	LatestVersion    string `json:"latestVersion,omitempty"`
	PreviousVersion  string `json:"previousVersion,omitempty"`
	UpdatedAt        string `json:"updatedAt,omitempty"`
	LastError        string `json:"lastError,omitempty"`
	SupportsUpdates  bool   `json:"supportsUpdates,omitempty"`
	AutoUpdates      bool   `json:"autoUpdates,omitempty"`
	Chat             bool   `json:"chat"`
	Terminal         bool   `json:"terminal"`
	Verified         bool   `json:"verified"`
	Supported        *bool  `json:"supported,omitempty"`
	RestartWanted    *bool  `json:"restartWanted,omitempty"`
	IdleForSeconds   *int64 `json:"idleForSeconds,omitempty"`
	// UpdateWaitingTerminals counts the running terminals an automatic update
	// waits for (an in-place updater only).
	UpdateWaitingTerminals int `json:"updateWaitingTerminals,omitempty"`
}

// agentView is an entry with what the host keeps to itself.
type agentView struct {
	agentJSON
	current *agentCurrent
	local   string // the command found on the Mac
	usable  bool   // installed or local: it can run now
	acp     bool   // its chats run through ACP
}

// agentCatalogEntry is one agent of capabilities.agentCatalog.
type agentCatalogEntry struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Chat     bool   `json:"chat"`
	Terminal bool   `json:"terminal"`
}

// localVersion is the version of the command at path, cached by the file;
// read (running it when need be) only when read is true.
func (c *agentCatalog) localVersion(path, program string, read bool) string {
	identity, ok := identifyExecutable(path)
	if !ok {
		return ""
	}
	c.mu.Lock()
	entry, cached := c.versions[path]
	c.mu.Unlock()
	if cached && entry.identity.same(identity) {
		return entry.version
	}
	if !read {
		return ""
	}
	version := ""
	if program == "claude" {
		version = claudeVersionFromPath(path)
	} else {
		version = c.versionOf(path)
	}
	c.mu.Lock()
	if len(c.versions) > 64 {
		c.versions = map[string]agentVersionEntry{}
	}
	c.versions[path] = agentVersionEntry{identity: identity, version: version}
	c.mu.Unlock()
	return version
}

// views assembles the catalog. With readVersions it runs --version on the
// local commands it has no version for (in parallel, 5 s each).
func (c *agentCatalog) views(readVersions bool) []agentView {
	c.mu.Lock()
	agents, byID := c.agents, c.byID
	ops := map[string]string{}
	for id, op := range c.ops {
		ops[id] = op.kind
	}
	deferred := maps.Clone(c.deferred)
	c.mu.Unlock()
	// Claude Code, Codex and OpenCode are always listed.
	ids := map[string]bool{"claude": true, "codex": true, "opencode": true}
	for _, agent := range agents {
		ids[nativeAgentID(agent.ID)] = true
	}
	currents := map[string]*agentCurrent{}
	damaged := map[string]bool{}
	statuses := map[string]agentStatus{}
	homes := c.homeFolders()
	for _, id := range c.store.agentIDs() {
		if nativeAgentID(id) != id {
			continue
		}
		var current *agentCurrent
		if id != "claude" && id != "codex" {
			var err error
			current, err = c.store.readCurrent(id)
			if err != nil {
				damaged[id] = true
			}
			if current != nil {
				currents[id] = current
			}
		}
		if status := c.store.readStatus(id); status.LastError != "" || status.UpdatedAt != "" {
			// A status written by an earlier host may still hold such paths.
			status.LastError = withoutHomes(status.LastError, homes)
			statuses[id] = status
		}
		if current != nil || statuses[id].LastError != "" || statuses[id].UpdatedAt != "" || damaged[id] {
			ids[id] = true
		}
	}
	for id := range ops {
		ids[id] = true
	}
	locals := map[string]string{}
	for _, spec := range localAgentSpecs {
		if path, ok := c.lookup(spec.program); ok {
			locals[spec.id] = path
			ids[spec.id] = true
		}
	}
	// Versions of the local commands, read at once.
	type versionJob struct{ id, path, program string }
	var jobs []versionJob
	for _, spec := range localAgentSpecs {
		if path := locals[spec.id]; path != "" {
			jobs = append(jobs, versionJob{spec.id, path, spec.program})
		}
	}
	versions := make([]string, len(jobs))
	var group sync.WaitGroup
	for index, job := range jobs {
		group.Add(1)
		go func() {
			defer group.Done()
			versions[index] = c.localVersion(job.path, job.program, readVersions)
		}()
	}
	group.Wait()
	localVersions := map[string]string{}
	for index, job := range jobs {
		localVersions[job.id] = versions[index]
	}
	localUpdaters := map[string]bool{}
	if readVersions {
		var updateJobs []versionJob
		for _, job := range jobs {
			if nativeSelfUpdater(job.id) {
				updateJobs = append(updateJobs, job)
			}
		}
		var updateGroup sync.WaitGroup
		var updateMu sync.Mutex
		for _, job := range updateJobs {
			updateGroup.Add(1)
			go func() {
				defer updateGroup.Done()
				supported := c.localUpdaterSupported(job.id, job.path)
				updateMu.Lock()
				localUpdaters[job.id] = supported
				updateMu.Unlock()
			}()
		}
		updateGroup.Wait()
	}
	views := make([]agentView, 0, len(ids))
	for id := range ids {
		var entry *registryAgent
		if registry, inRegistry := byID[id]; inRegistry {
			entry = &registry
		}
		view := c.view(id, entry, currents[id], damaged[id], statuses[id], ops[id], locals[id], localVersions[id], localUpdaters[id])
		if view.ID != "" {
			if deferred[id] {
				// No running terminal left: nothing waits any more.
				if view.UpdateWaitingTerminals = len(c.host.runningTerminalVersions(id)); view.UpdateWaitingTerminals == 0 {
					c.undefer(id)
				}
			}
			views = append(views, view)
		}
	}
	sort.Slice(views, func(i, j int) bool {
		left, right := strings.ToLower(views[i].Name), strings.ToLower(views[j].Name)
		if left != right {
			return left < right
		}
		return views[i].ID < views[j].ID
	})
	return views
}

// view is one agent's entry; an empty ID leaves it out.
func (c *agentCatalog) view(id string, registry *registryAgent, current *agentCurrent, damaged bool, status agentStatus, op, local, localVersion string, localAutoUpdates bool) agentView {
	view := agentView{agentJSON: agentJSON{ID: id, Verified: true}, current: current, local: local}
	spec, known := localAgentSpecFor(id)
	var dist *agentDistribution
	if registry != nil {
		if chosen, ok := registry.choose(c.platform); ok {
			dist = &chosen
		}
	}
	switch {
	case id == "claude" || id == "codex":
		view.Name, view.Source = spec.name, "local"
		if local != "" {
			view.usable, view.Terminal, view.InstalledVersion = true, true, localVersion
			view.Chat = c.host != nil && c.host.cliChats != nil && c.host.cliChats.available(id)
			view.SupportsUpdates = localAutoUpdates
			view.AutoUpdates = localAutoUpdates && c.automaticUpdates()
		}
		view.LastError, view.UpdatedAt = status.LastError, status.UpdatedAt
		switch {
		case op == "update":
			view.State = "updating"
		case view.usable:
			view.State = "installed"
		default:
			view.State = "notInstalled"
		}
		return view
	case id == "opencode":
		// Always a registry agent: the managed install, or none yet.
		view.Name, view.Chat, view.Source = "OpenCode", true, "registry"
		if current != nil {
			view.usable = true
		} else if registry != nil {
			view.Verified = dist != nil && dist.Verified
			view.Supported = supportedBy(dist)
		}
		view.Terminal = view.usable
	default:
		switch {
		case current != nil:
			view.Source, view.usable, view.acp = "registry", true, true
			view.Terminal = len(current.Args) > 0
		case local != "":
			view.Source, view.usable, view.Terminal, view.InstalledVersion = "local", true, true, localVersion
			view.acp = spec.acp && dist != nil
			view.Chat = view.acp
		case registry != nil:
			view.Source, view.Chat = "registry", true
			view.Terminal = dist != nil && len(dist.args()) > 0
			view.Verified = dist != nil && dist.Verified
			view.Supported = supportedBy(dist)
		case current == nil && (status.LastError != "" || op != "" || damaged):
			view.Source, view.Chat = "registry", true
		default:
			return agentView{}
		}
		if current != nil {
			view.Chat = true
		}
		switch {
		case current != nil:
			view.Name = current.Name
		case registry != nil:
			view.Name = registry.Name
		case known:
			view.Name = spec.name
		}
		if view.Name == "" {
			view.Name = id
		}
	}
	if registry != nil {
		view.Description, view.Website, view.License, view.LatestVersion = registry.Description, registry.Website, registry.License, registry.Version
		if id == "opencode" && registry.Name != "" {
			view.Name = registry.Name
		}
	}
	if current != nil {
		view.InstalledVersion, view.UpdatedAt = current.Version, current.InstalledAt
		view.SupportsUpdates = true
		view.AutoUpdates = c.automaticUpdates()
		if sameAgentVersion(view.LatestVersion, current.Version) {
			// One version, as its folder is: no update is offered.
			view.LatestVersion = current.Version
		}
		view.Verified = !current.Unverified
		if current.Previous != nil {
			view.PreviousVersion = current.Previous.Version
		}
	}
	view.LastError = status.LastError
	if damaged && current == nil && view.LastError == "" {
		view.LastError = "The installed files are missing or damaged; install it again."
	}
	switch {
	case op == "install" && current == nil:
		view.State = "installing"
	case op == "update" || (op == "install" && current != nil):
		view.State = "updating"
	case op == "uninstall":
		view.State = "uninstalling"
	case view.usable:
		view.State = "installed"
	case view.LastError != "" && view.Source == "registry":
		view.State = "failed"
	default:
		view.State = "notInstalled"
	}
	return view
}

// supportedBy is agentJSON.Supported for a registry agent not installed:
// false when the registry offers nothing for this Mac, else absent.
func supportedBy(dist *agentDistribution) *bool {
	if dist != nil {
		return nil
	}
	supported := false
	return &supported
}

// agent is one agent's view, when the catalog lists it.
func (c *agentCatalog) agent(id string, readVersions bool) (agentView, bool) {
	for _, view := range c.views(readVersions) {
		if view.ID == id {
			return view, true
		}
	}
	return agentView{}, false
}

// agentName names an agent for its chats and notices.
func (c *agentCatalog) agentName(id string) string {
	if c == nil {
		return id
	}
	if current, _ := c.store.readCurrent(id); current != nil && current.Name != "" {
		return current.Name
	}
	if registry, ok := c.registryEntry(id); ok {
		return registry.Name
	}
	if spec, ok := localAgentSpecFor(id); ok {
		return spec.name
	}
	return id
}

// capabilityLists are capabilities.agentCatalog and the ids of the ACP chat
// agents and of the agents with a terminal command other than AgentLand's
// own (which the host lists as before).
func (c *agentCatalog) capabilityLists() ([]agentCatalogEntry, []string, []string, map[string]string) {
	views := c.views(false)
	catalog := []agentCatalogEntry{}
	var chats, terminals []string
	versions := map[string]string{}
	var native []agentCatalogEntry
	for _, view := range views {
		if !view.usable {
			continue
		}
		entry := agentCatalogEntry{ID: view.ID, Name: view.Name, Chat: view.Chat, Terminal: view.Terminal}
		if nativeAgent(view.ID) {
			native = append(native, entry)
			continue
		}
		catalog = append(catalog, entry)
		if view.acp {
			chats = append(chats, view.ID)
			versions[view.ID] = view.InstalledVersion
		}
		if view.Terminal {
			terminals = append(terminals, view.ID)
		}
	}
	order := map[string]int{"opencode": 0, "claude": 1, "codex": 2}
	sort.Slice(native, func(i, j int) bool { return order[native[i].ID] < order[native[j].ID] })
	return append(native, catalog...), chats, terminals, versions
}

// acpLaunch says how an agent's ACP chats start (acpAgentSource): a managed
// install's current.json, or a local command marked ACP with the registry's
// arguments and environment for its id.
func (c *agentCatalog) acpLaunch(id string) (acpLaunchSpec, bool) {
	if c == nil || nativeAgent(id) || !agentIDPattern.MatchString(id) {
		return acpLaunchSpec{}, false
	}
	if current, _ := c.store.readCurrent(id); current != nil {
		launch := acpLaunchSpec{name: current.Name, command: current.Command, args: append([]string(nil), current.Args...), env: current.Env}
		if launch.name == "" {
			launch.name = c.agentName(id)
		}
		if current.Kind == "npx" {
			launch.pathPrefix = acpNodeFolder(c.lookup)
		}
		return launch, true
	}
	spec, ok := localAgentSpecFor(id)
	if !ok || !spec.acp {
		return acpLaunchSpec{}, false
	}
	path, found := c.lookup(spec.program)
	if !found {
		return acpLaunchSpec{}, false
	}
	registry, ok := c.registryEntry(id)
	if !ok {
		return acpLaunchSpec{}, false
	}
	dist, ok := registry.choose(c.platform)
	if !ok {
		return acpLaunchSpec{}, false
	}
	launch := acpLaunchSpec{name: registry.Name, command: path, args: append([]string(nil), dist.args()...), env: dist.env()}
	if dist.Kind == "npx" {
		launch.pathPrefix = acpNodeFolder(c.lookup)
	}
	return launch, true
}

// ocTerminalLaunch is what an agent's terminal runs: its command, arguments
// and the variables it adds (terminal_launch.go).
type ocTerminalLaunch struct {
	Command string
	Args    []string
	Env     map[string]string
}

// terminalLaunch is the command a terminal of agent id runs: a registry
// install's command without its ACP arguments (only when the distribution
// has some), or the local command. AgentLand's own agents are started by the
// OpenCode adapter as before.
func (c *agentCatalog) terminalLaunch(id string) (*ocTerminalLaunch, bool) {
	if c == nil || nativeAgent(id) || !agentIDPattern.MatchString(id) {
		return nil, false
	}
	if current, _ := c.store.readCurrent(id); current != nil {
		if len(current.Args) == 0 {
			return nil, false
		}
		launch := &ocTerminalLaunch{Command: current.Command, Env: map[string]string{}}
		for name, value := range current.Env {
			launch.Env[name] = value
		}
		if current.Kind == "npx" {
			if node := acpNodeFolder(c.lookup); node != "" {
				launch.Env["PATH"] = node + string(os.PathListSeparator) + os.Getenv("PATH")
			}
		}
		if len(launch.Env) == 0 {
			launch.Env = nil
		}
		return launch, true
	}
	spec, ok := localAgentSpecFor(id)
	if !ok {
		return nil, false
	}
	path, found := c.lookup(spec.program)
	if !found {
		return nil, false
	}
	return &ocTerminalLaunch{Command: path}, true
}

// openCodeCommand is the managed OpenCode's command, when one is current.
func (c *agentCatalog) openCodeCommand() (string, bool) {
	if c == nil {
		return "", false
	}
	current, _ := c.store.readCurrent("opencode")
	if current == nil {
		return "", false
	}
	return current.Command, true
}

// Icons.

// iconRegistryID is the registry id whose icon an agent shows.
func (c *agentCatalog) iconRegistryID(id string) string {
	if registry, ok := c.registryEntry(id); ok {
		return registry.ID
	}
	return id
}

func (c *agentCatalog) readIcon(registryID string) ([]byte, string) {
	for _, kind := range []string{"svg", "png"} {
		if data, err := readPrivateState(filepath.Join(c.store.iconDir(), registryID+"."+kind)); err == nil && agentIconKind(data) == kind {
			return data, kind
		}
	}
	return nil, ""
}

// iconOutcome is how an icon read ended.
type iconOutcome int

const (
	iconKept iconOutcome = iota
	// iconNone: there is none to keep (no address, a file refused by size or
	// kind, a 4xx answer, a full cache).
	iconNone
	// iconUnavailable: it could not be read now; a later read may work.
	iconUnavailable
)

// iconFetch is one agent's icon read; outcome is set before done closes.
type iconFetch struct {
	done    chan struct{}
	outcome iconOutcome
}

// fetchIcon reads and keeps one agent's icon, one read per agent at a time:
// a call during another read of it waits for that read and has its outcome.
func (c *agentCatalog) fetchIcon(ctx context.Context, registryID string) iconOutcome {
	c.mu.Lock()
	if busy := c.iconBusy[registryID]; busy != nil {
		c.mu.Unlock()
		select {
		case <-busy.done:
			return busy.outcome
		case <-ctx.Done():
			return iconUnavailable
		}
	}
	fetch := &iconFetch{done: make(chan struct{}), outcome: iconUnavailable}
	c.iconBusy[registryID] = fetch
	address := c.iconURLs[registryID]
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.iconBusy, registryID)
		c.mu.Unlock()
		close(fetch.done)
	}()
	if address == "" || c.iconCacheFull() {
		fetch.outcome = iconNone
		return fetch.outcome
	}
	data, kind, err := c.fetcher.fetchIcon(ctx, address)
	switch {
	case err == nil:
		fetch.outcome = c.keepIcon(registryID, kind, data)
	case iconGone(err):
		fetch.outcome = iconNone
	}
	return fetch.outcome
}

// iconUsage is what .icons holds, read once and then followed; with iconMu
// held.
func (c *agentCatalog) iconUsage() int64 {
	if c.iconBytes >= 0 {
		return c.iconBytes
	}
	var total int64
	entries, _ := os.ReadDir(c.store.iconDir())
	for _, entry := range entries {
		if info, err := entry.Info(); err == nil && info.Mode().IsRegular() {
			total += info.Size()
		}
	}
	c.iconBytes = total
	return total
}

// iconCacheFull reports .icons at its limit: nothing more is fetched.
func (c *agentCatalog) iconCacheFull() bool {
	c.iconMu.Lock()
	defer c.iconMu.Unlock()
	return c.iconUsage() >= c.iconLimit
}

// keepIcon writes an icon into .icons, in place of the agent's other kind,
// unless the cache would then hold more than iconLimit bytes.
func (c *agentCatalog) keepIcon(registryID, kind string, data []byte) iconOutcome {
	c.iconMu.Lock()
	defer c.iconMu.Unlock()
	used := c.iconUsage()
	for _, other := range []string{"svg", "png"} {
		if info, err := os.Lstat(filepath.Join(c.store.iconDir(), registryID+"."+other)); err == nil {
			used -= info.Size()
		}
	}
	if used+int64(len(data)) > c.iconLimit {
		return iconNone
	}
	if ensurePrivateStateDirectory(filepath.Join(c.store.iconDir(), "x")) != nil {
		return iconUnavailable
	}
	c.iconBytes = -1
	for _, other := range []string{"svg", "png"} {
		if other != kind {
			_ = os.Remove(filepath.Join(c.store.iconDir(), registryID+"."+other))
		}
	}
	if writePrivateState(filepath.Join(c.store.iconDir(), registryID+"."+kind), data) != nil {
		return iconUnavailable
	}
	c.iconBytes = used + int64(len(data))
	return iconKept
}

// pruneIcons removes the icons of ids the registry no longer lists, and
// anything else in .icons.
func (c *agentCatalog) pruneIcons(listed map[string]bool) {
	c.iconMu.Lock()
	defer c.iconMu.Unlock()
	entries, err := os.ReadDir(c.store.iconDir())
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		// Registry ids may hold dots: the kind follows the last.
		if dot := strings.LastIndex(name, "."); dot > 0 && listed[name[:dot]] && (name[dot+1:] == "svg" || name[dot+1:] == "png") && entry.Type().IsRegular() {
			continue
		}
		_ = os.RemoveAll(filepath.Join(c.store.iconDir(), name))
	}
	c.iconBytes = -1
}

// prefetchIcons removes the icons of agents the registry no longer lists,
// then reads the icons the host does not have yet, one at a time.
func (c *agentCatalog) prefetchIcons() {
	c.mu.Lock()
	var ids []string
	listed := map[string]bool{}
	for _, agent := range c.agents {
		listed[agent.ID] = true
		if agent.Icon != "" {
			ids = append(ids, agent.ID)
		}
	}
	c.mu.Unlock()
	c.pruneIcons(listed)
	for _, id := range ids {
		if c.ctx.Err() != nil {
			return
		}
		if data, _ := c.readIcon(id); data == nil {
			c.fetchIcon(c.ctx, id)
		}
	}
}

// icon answers an agent's kept icon, reading it (up to iconWait, 5 s) when
// the host has none: iconNone when there is none to give, iconUnavailable
// when it could not be read in time (a read not finished goes on).
func (c *agentCatalog) icon(ctx context.Context, id string) ([]byte, string, iconOutcome) {
	if !agentIDPattern.MatchString(id) {
		return nil, "", iconNone
	}
	registryID := c.iconRegistryID(id)
	if data, kind := c.readIcon(registryID); data != nil {
		return data, kind, iconKept
	}
	wait, cancel := context.WithTimeout(ctx, c.iconWait)
	defer cancel()
	result := make(chan iconOutcome, 1)
	if !c.background(func() { result <- c.fetchIcon(c.ctx, registryID) }) {
		return nil, "", iconUnavailable
	}
	select {
	case outcome := <-result:
		if outcome != iconKept {
			return nil, "", outcome
		}
	case <-wait.Done():
		return nil, "", iconUnavailable
	}
	if data, kind := c.readIcon(registryID); data != nil {
		return data, kind, iconKept
	}
	return nil, "", iconUnavailable
}
