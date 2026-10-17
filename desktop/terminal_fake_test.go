package host

import (
	"context"
	"errors"
	"io"
	"slices"
	"sync"
	"testing"
	"time"

	"agentland/host/keeper"
)

// fakeTerminals is an in-memory terminal keeper (TerminalBackend). Tests drive
// its terminals with emit, skip and exit, and read what the host asked of it.
type fakeTerminals struct {
	mu          sync.Mutex
	changed     *sync.Cond
	status      KeeperStatus
	terminals   map[string]*fakeTerminal
	order       []string
	attachments []*fakeAttachment
	closed      int

	spawns     []keeper.SpawnRequest
	ends       []string
	forgets    []string
	releases   []string
	attaches   []attachCall
	inputs     []inputCall
	dimensions [2]int

	inputErr error
	endErr   error
	// forgetErr fails every Forget with it.
	forgetErr error
	// forgetBlock, when set, makes Forget wait for it to close or its context to end.
	forgetBlock chan struct{}
	// spawnErr fails every Spawn with it.
	spawnErr error
	// featuresErr fails every Features with it; featuresCount counts them.
	featuresErr   error
	featuresCount int
	// attachErr fails every Attach with it, and the keeper reads as gone
	// (KeeperNone) from then on, as a keeper that crashed does.
	attachErr error
	// broken fails every attachment's next event, as a keeper that drops
	// each stream at once does (breakStreams).
	broken bool
	// held is, per terminal, how many of its newest bytes its streams do not
	// deliver yet, as a stalled stream does (holdBack).
	held map[string]uint64
	// pid is the process ID spawned terminals report (0: none).
	pid int
	// spawnEntered, when set, closes as the next spawn begins, which then
	// waits for spawnRelease.
	spawnEntered, spawnRelease chan struct{}
	// endBlock, when set, makes every End wait for it to close, ignoring its
	// context, as a keeper that hangs does.
	endBlock chan struct{}
	// beforeSpawn sees each spawn request before it is answered.
	beforeSpawn func(keeper.SpawnRequest)
	// hangStatus and hangList make Status and List wait for their context to
	// end, as a keeper that takes the connection but never answers does.
	hangStatus, hangList bool
	// features is what Features answers, the keeper's hello features
	// (setFeatures).
	features []string
	// idleStops counts stopIdleKeeper's stops; idleStopErr fails them.
	idleStops   int
	idleStopErr error
	// beforeAttach and beforeSetMeta, when set, see each attach or record
	// write before it is answered, outside the fake's lock.
	beforeAttach, beforeSetMeta func(id string)
}

type fakeTerminal struct {
	info   keeper.Info
	output []byte // the bytes from info.Start to info.Cursor
}

type attachCall struct {
	id   string
	from uint64
}

type inputCall struct {
	id   string
	data []byte
}

type fakeAttachment struct {
	fake   *fakeTerminals
	id     string
	pos    uint64
	closed bool
	exited bool
}

func newFakeTerminals() *fakeTerminals {
	f := &fakeTerminals{status: KeeperRunning, terminals: map[string]*fakeTerminal{}, features: []string{keeper.FeatureAdopt}}
	f.changed = sync.NewCond(&f.mu)
	return f
}

func fakeKeeperError(code string) error { return &keeper.RemoteError{Code: code, Message: code} }

func (t *fakeTerminal) copy() keeper.Info {
	info := t.info
	info.Meta = slices.Clone(t.info.Meta)
	return info
}

func (f *fakeTerminals) Status(ctx context.Context) KeeperStatus {
	f.mu.Lock()
	hang := f.hangStatus
	f.mu.Unlock()
	if hang {
		<-ctx.Done()
		return KeeperUnusable
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.status
}

func (f *fakeTerminals) List(ctx context.Context) ([]keeper.Info, error) {
	f.mu.Lock()
	hang := f.hangList
	f.mu.Unlock()
	if hang {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	list := make([]keeper.Info, 0, len(f.order))
	for _, id := range f.order {
		list = append(list, f.terminals[id].copy())
	}
	return list, nil
}

func (f *fakeTerminals) Spawn(_ context.Context, request keeper.SpawnRequest) (keeper.Info, error) {
	f.mu.Lock()
	entered, release, before := f.spawnEntered, f.spawnRelease, f.beforeSpawn
	f.spawnEntered = nil
	f.mu.Unlock()
	if before != nil {
		before(request)
	}
	if entered != nil {
		close(entered)
		<-release
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.spawnErr != nil {
		return keeper.Info{}, f.spawnErr
	}
	request.Meta = slices.Clone(request.Meta)
	f.spawns = append(f.spawns, request)
	if _, exists := f.terminals[request.ID]; exists {
		return keeper.Info{}, fakeKeeperError(keeper.CodeExists)
	}
	f.dimensions = [2]int{request.Rows, request.Cols}
	terminal := &fakeTerminal{info: keeper.Info{ID: request.ID, PID: f.pid, Started: time.Now(), Running: true, Meta: request.Meta}}
	f.terminals[request.ID] = terminal
	f.order = append(f.order, request.ID)
	return terminal.copy(), nil
}

func (f *fakeTerminals) Attach(_ context.Context, id string, from uint64) (TerminalAttachment, error) {
	f.mu.Lock()
	before := f.beforeAttach
	f.mu.Unlock()
	if before != nil {
		before(id)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.attaches = append(f.attaches, attachCall{id, from})
	if f.attachErr != nil {
		f.status = KeeperNone
		return nil, f.attachErr
	}
	if f.terminals[id] == nil {
		return nil, fakeKeeperError(keeper.CodeNotFound)
	}
	attachment := &fakeAttachment{fake: f, id: id, pos: from}
	f.attachments = append(f.attachments, attachment)
	return attachment, nil
}

func (f *fakeTerminals) Input(_ context.Context, id string, data []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.inputErr != nil {
		return f.inputErr
	}
	terminal := f.terminals[id]
	switch {
	case terminal == nil:
		return fakeKeeperError(keeper.CodeNotFound)
	case !terminal.info.Running:
		return fakeKeeperError(keeper.CodeNotRunning)
	}
	f.inputs = append(f.inputs, inputCall{id, slices.Clone(data)})
	return nil
}

func (f *fakeTerminals) Resize(_ context.Context, id string, rows, cols int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.terminals[id] == nil {
		return fakeKeeperError(keeper.CodeNotFound)
	}
	f.dimensions = [2]int{rows, cols}
	return nil
}

func (f *fakeTerminals) End(_ context.Context, id string) (keeper.Info, error) {
	f.mu.Lock()
	if block := f.endBlock; block != nil {
		f.mu.Unlock()
		<-block
		f.mu.Lock()
	}
	defer f.mu.Unlock()
	f.ends = append(f.ends, id)
	if f.endErr != nil {
		return keeper.Info{}, f.endErr
	}
	terminal := f.terminals[id]
	if terminal == nil {
		return keeper.Info{}, fakeKeeperError(keeper.CodeNotFound)
	}
	if terminal.info.Running {
		terminal.info.Running = false
		terminal.info.Exit = &keeper.Exit{Signal: "SIGHUP", At: time.Now()}
		f.changed.Broadcast()
	}
	return terminal.copy(), nil
}

func (f *fakeTerminals) Forget(ctx context.Context, id string) error {
	f.mu.Lock()
	if block := f.forgetBlock; block != nil {
		f.mu.Unlock()
		select {
		case <-block:
		case <-ctx.Done():
			return ctx.Err()
		}
		f.mu.Lock()
	}
	defer f.mu.Unlock()
	if f.forgetErr != nil {
		return f.forgetErr
	}
	f.forgets = append(f.forgets, id)
	terminal := f.terminals[id]
	switch {
	case terminal == nil:
		return fakeKeeperError(keeper.CodeNotFound)
	case terminal.info.Running:
		return fakeKeeperError(keeper.CodeRunning)
	}
	delete(f.terminals, id)
	f.order = slices.DeleteFunc(f.order, func(other string) bool { return other == id })
	for _, attachment := range f.attachments {
		if attachment.id == id {
			attachment.closed = true
		}
	}
	f.changed.Broadcast()
	return nil
}

// Release gives an adopted terminal back to the process that started it: its
// streams end with an exit that says Released, and its program goes on.
func (f *fakeTerminals) Release(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.releases = append(f.releases, id)
	terminal := f.terminals[id]
	switch {
	case terminal == nil:
		return fakeKeeperError(keeper.CodeNotFound)
	case !terminal.info.Adopted:
		return fakeKeeperError(keeper.CodeNotAdopted)
	}
	if terminal.info.Running {
		terminal.info.Running = false
		terminal.info.Exit = &keeper.Exit{At: time.Now(), Released: true}
		f.changed.Broadcast()
	}
	return nil
}

func (f *fakeTerminals) Features(context.Context) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.featuresCount++
	if f.featuresErr != nil {
		return nil, f.featuresErr
	}
	return slices.Clone(f.features), nil
}

// setFeaturesErr fails every Features with err, as a keeper that cannot
// start does.
func (f *fakeTerminals) setFeaturesErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.featuresErr = err
}

// featuresCalls is how many times Features was called: each one may start a
// keeper.
func (f *fakeTerminals) featuresCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.featuresCount
}

func (f *fakeTerminals) setFeatures(features []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.features = features
}

// runningFeatures answers the running keeper's features, as
// keeperBackend.runningFeatures does, without starting one.
func (f *fakeTerminals) runningFeatures(context.Context) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.status != KeeperRunning {
		return nil, errNoKeeper
	}
	return slices.Clone(f.features), nil
}

// stopIdleKeeper stops a keeper that holds no terminal, as
// keeperBackend.stopIdleKeeper does: none runs then, and the next one
// started is this build's, with adopt.
func (f *fakeTerminals) stopIdleKeeper(context.Context) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.status != KeeperRunning || len(f.order) > 0 {
		return false, nil
	}
	if f.idleStopErr != nil {
		return false, f.idleStopErr
	}
	f.idleStops++
	f.status = KeeperNone
	f.features = []string{keeper.FeatureAdopt}
	return true, nil
}

// idleStopCalls is how many keepers stopIdleKeeper stopped.
func (f *fakeTerminals) idleStopCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.idleStops
}

func (f *fakeTerminals) SetMeta(_ context.Context, id string, meta []byte) error {
	f.mu.Lock()
	before := f.beforeSetMeta
	f.mu.Unlock()
	if before != nil {
		before(id)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	terminal := f.terminals[id]
	if terminal == nil {
		return fakeKeeperError(keeper.CodeNotFound)
	}
	terminal.info.Meta = slices.Clone(meta)
	return nil
}

func (f *fakeTerminals) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed++
	for _, attachment := range f.attachments {
		attachment.closed = true
	}
	f.changed.Broadcast()
	return nil
}

func (a *fakeAttachment) Next() (keeper.Event, error) {
	f := a.fake
	f.mu.Lock()
	defer f.mu.Unlock()
	for {
		if a.closed {
			return keeper.Event{}, errors.New("fake keeper: the attachment was closed")
		}
		if f.broken {
			return keeper.Event{}, errors.New("fake keeper: the stream broke")
		}
		if a.exited {
			return keeper.Event{}, io.EOF
		}
		terminal := f.terminals[a.id]
		held := f.held[a.id]
		switch {
		case terminal == nil:
			return keeper.Event{}, errors.New("fake keeper: the terminal was forgotten")
		case a.pos < terminal.info.Start:
			a.pos = terminal.info.Start
			return keeper.Event{Kind: keeper.EventSkipped, SkippedTo: a.pos}, nil
		case a.pos+held < terminal.info.Cursor:
			offset := a.pos
			a.pos = terminal.info.Cursor - held
			return keeper.Event{Kind: keeper.EventData, Offset: offset, Data: slices.Clone(terminal.output[offset-terminal.info.Start : a.pos-terminal.info.Start])}, nil
		case held == 0 && !terminal.info.Running && terminal.info.Exit != nil:
			a.exited = true
			exit := *terminal.info.Exit
			return keeper.Event{Kind: keeper.EventExited, Exit: &exit}, nil
		}
		f.changed.Wait()
	}
}

func (a *fakeAttachment) Close() error {
	a.fake.mu.Lock()
	defer a.fake.mu.Unlock()
	a.closed = true
	a.fake.changed.Broadcast()
	return nil
}

// emit is output from the terminal's program.
func (f *fakeTerminals) emit(id string, data string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	terminal := f.terminals[id]
	terminal.output = append(terminal.output, data...)
	terminal.info.Cursor += uint64(len(data))
	f.changed.Broadcast()
}

// skip drops the terminal's output before to, as a full ring does.
func (f *fakeTerminals) skip(id string, to uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	terminal := f.terminals[id]
	terminal.output = nil
	terminal.info.Start, terminal.info.Cursor = to, to
	f.changed.Broadcast()
}

// exit is the terminal's program exiting with code.
func (f *fakeTerminals) exit(id string, code int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	terminal := f.terminals[id]
	terminal.info.Running = false
	terminal.info.Exit = &keeper.Exit{Code: &code, At: time.Now()}
	f.changed.Broadcast()
}

// exitByKeeper is the keeper ending the terminal as it stops (end-all).
func (f *fakeTerminals) exitByKeeper(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	terminal := f.terminals[id]
	terminal.info.Running = false
	terminal.info.Exit = &keeper.Exit{Signal: "SIGHUP", At: time.Now(), ByKeeper: true}
	f.changed.Broadcast()
}

// holdBack stalls the terminal's streams before its newest n bytes, until
// unhold.
func (f *fakeTerminals) holdBack(id string, n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.held == nil {
		f.held = map[string]uint64{}
	}
	f.held[id] = uint64(n)
}

// unhold lets the terminal's streams deliver what holdBack held.
func (f *fakeTerminals) unhold(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.held, id)
	f.changed.Broadcast()
}

func (f *fakeTerminals) setSpawnErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.spawnErr = err
}

func (f *fakeTerminals) setStatus(status KeeperStatus) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
}

func (f *fakeTerminals) setInputErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.inputErr = err
}

// dropAttachments ends the open attachments of the terminals named, or every
// one, as a lost connection does.
func (f *fakeTerminals) dropAttachments(ids ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, attachment := range f.attachments {
		if len(ids) == 0 || slices.Contains(ids, attachment.id) {
			attachment.closed = true
		}
	}
	f.changed.Broadcast()
}

// breakStreams makes every attachment, open or later, fail on its next
// event: the keeper accepts each attach and drops the stream at once.
func (f *fakeTerminals) breakStreams() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.broken = true
	f.changed.Broadcast()
}

// addRunning is a terminal the keeper already holds, as after a restart.
func (f *fakeTerminals) addRunning(info keeper.Info, output string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	info.Running = true
	info.Cursor = info.Start + uint64(len(output))
	f.terminals[info.ID] = &fakeTerminal{info: info, output: []byte(output)}
	f.order = append(f.order, info.ID)
}

func (f *fakeTerminals) spawnCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.spawns)
}

func (f *fakeTerminals) lastSpawn() keeper.SpawnRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.spawns[len(f.spawns)-1]
}

// latest is the ID of the terminal spawned last.
func (f *fakeTerminals) latest() string { return f.lastSpawn().ID }

func (f *fakeTerminals) endedIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.ends)
}

func (f *fakeTerminals) forgottenIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.forgets)
}

func (f *fakeTerminals) releasedIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.releases)
}

func (f *fakeTerminals) attachCalls() []attachCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.attaches)
}

func (f *fakeTerminals) openAttachments() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	open := 0
	for _, attachment := range f.attachments {
		if !attachment.closed {
			open++
		}
	}
	return open
}

// input is everything the terminal's program was sent.
func (f *fakeTerminals) input(id string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var all []byte
	for _, call := range f.inputs {
		if call.id == id {
			all = append(all, call.data...)
		}
	}
	return string(all)
}

func (f *fakeTerminals) size() [2]int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.dimensions
}

// meta is the host's record of the terminal, as the keeper holds it now.
func (f *fakeTerminals) meta(t *testing.T, id string) terminalMeta {
	t.Helper()
	f.mu.Lock()
	terminal := f.terminals[id]
	var blob []byte
	if terminal != nil {
		blob = slices.Clone(terminal.info.Meta)
	}
	f.mu.Unlock()
	meta, err := decodeTerminalMeta(blob)
	if err != nil {
		t.Fatalf("terminal %s metadata %q: %v", id, blob, err)
	}
	return meta
}

// terminalFixture is a chat agent with an in-memory terminal keeper.
type terminalFixture struct {
	*fakeAgent
	*fakeTerminals
}

func newTerminalFixture(agent *fakeAgent) *terminalFixture {
	return &terminalFixture{fakeAgent: agent, fakeTerminals: newFakeTerminals()}
}

// Close is the keeper's (the chat agent has none).
func (f *terminalFixture) Close() error { return f.fakeTerminals.Close() }

// fakeTerminalPrograms gives the host's launcher a fixed environment and
// finds opencode, claude and codex at /bin/<name>; with none set, it finds
// none of them.
func fakeTerminalPrograms(host *Host, found bool) {
	launcher := host.terminals.launcher
	launcher.environ = func() []string { return []string{"SHELL=/bin/sh", "PATH=/usr/bin:/bin", "USER=agentland-test"} }
	launcher.resolve = func(name string) (string, bool) {
		if !found {
			return "", false
		}
		return "/bin/" + name, true
	}
	launcher.openCode = func() (string, string, string) { return "http://127.0.0.1:4096", "opencode", "fixture-password" }
}

func terminalTestHost(t *testing.T, enabled bool) (*Host, *Store, string, *terminalFixture) {
	t.Helper()
	_, store, base := testHost(t)
	fixture := newTerminalFixture(base)
	host := NewWithOptions(store, fixture, HostOptions{TerminalEnabled: enabled, Terminals: fixture.fakeTerminals})
	if host.terminals != nil {
		fakeTerminalPrograms(host, true)
	}
	t.Cleanup(func() { host.Close() })
	return host, store, paired(t, host, store), fixture
}

// setLastInput is input that reached the terminal's program at at without the
// host, as typing in its Terminal.app window does (keeper.Info.LastInput).
func (f *fakeTerminals) setLastInput(id string, at time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if terminal := f.terminals[id]; terminal != nil {
		terminal.info.LastInput = at
	}
}

func (f *fakeTerminals) setAttachErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.attachErr = err
}
