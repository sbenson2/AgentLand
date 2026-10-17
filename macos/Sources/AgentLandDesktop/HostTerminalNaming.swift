import Foundation
import AgentLandBranding
import AgentLandChat
import AgentLandCore
import AgentLandDesktopCore
import AgentLandWorkspace

/// What `HostTerminalNaming` reads and sends with this Mac's local session; tests give their own.
protocol TerminalNamingHost: Sendable {
    /// Every terminal on the host, all devices' and this Mac's (`GET /v1/terminals/all`).
    func terminals() async throws -> [HostTerminal]
    /// The terminal's output from `cursor`, at once (`GET /v1/terminal/output`, at most 64 KB a read).
    func output(projectID: String, terminalID: String, cursor: UInt64) async throws -> TerminalOutput
    /// `POST /v1/terminal/title`.
    func name(projectID: String, terminalID: String, title: String, basedOn: UInt64) async -> SendOutcome
}

/// The local session's routes: the Mac-only list, and the output and naming routes every paired device has.
struct LocalTerminalNamingHost: TerminalNamingHost {
    let feed: any HostTerminalsReading
    let client: APIClient

    func terminals() async throws -> [HostTerminal] { try await feed.list().terminals }

    func output(projectID: String, terminalID: String, cursor: UInt64) async throws -> TerminalOutput {
        try await client.terminalOutput(projectID: projectID, terminalID: terminalID, cursor: cursor, wait: 0)
    }

    func name(projectID: String, terminalID: String, title: String, basedOn: UInt64) async -> SendOutcome {
        await client.nameTerminal(projectID: projectID, terminalID: terminalID, title: title, basedOn: basedOn)
    }
}

/// Names every terminal on this Mac's host with Apple's on-device model (owner, 2026-10-16: "yes, all that and the
/// later option too as a toggle featuer"): every device's terminals, this Mac's own and the agents typed in Terminal,
/// whether or not a device shows them. `HostController` owns it; it runs only once the app activated it at launch (so
/// controllers in tests never ask a model), while the host runs, Settings → General's Apple Intelligence is on, the
/// model can run and Low Power Mode is off.
///
/// Every 15 s it lists the host's terminals. For each running one whose output moved since its screen was last read,
/// it renders the newest 256 KB of output at the terminal's size (`TerminalOutputScreen`); when that terminal's
/// schedule says so (`TerminalNamingSchedule`, as on devices) it names the screen (`TerminalContextNamer`) and sends a
/// name the terminal doesn't have yet with `POST /v1/terminal/title`, based on the cursor the output was read to.
/// Terminals go one at a time, so the model runs at most once at a time. A `title_stale` answer (a device named newer
/// output) is taken and a failure waits for new output: nothing is sent again. It never types into or resizes a
/// terminal, and the output goes nowhere but the model on this Mac.
@MainActor final class HostTerminalNaming {
    nonisolated static let interval: Duration = .seconds(15)
    /// The output a screen is rendered from: its newest bytes, at most.
    nonisolated static let outputRead: UInt64 = 256 << 10
    /// Reads of up to 64 KB for one screen, a few more than the window takes, for output written meanwhile.
    nonisolated static let readsPerScreen = 8

    /// One terminal's naming: its schedule, and the output's end when its screen was last read to a decision (named,
    /// or nothing new to name).
    private struct Tracked {
        var schedule = TerminalNamingSchedule()
        var readTo: UInt64?
    }

    /// The model, through Settings → Apple Intelligence (`AppleIntelligence`). Tests give a fake.
    var namer: any ChatNamer
    /// Tests give their own.
    var lowPowerMode: @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var now: @MainActor () -> Date = { Date() }

    private let preferences: UserDefaults
    private let interval: Duration
    private var activated = false
    private var host: (any TerminalNamingHost)?
    private var loop: Task<Void, Never>?
    /// Changes whenever naming stops: work begun before drops its results.
    private var generation = 0
    private var tracked: [String: Tracked] = [:]
    private var settingObserver: NSObjectProtocol?

    init(preferences: UserDefaults = .standard, namer: (any ChatNamer)? = nil, interval: Duration = HostTerminalNaming.interval) {
        self.preferences = preferences
        self.interval = interval
        // The apps' namer, which reads the switch in the standard preferences, as `preferences` are outside tests.
        self.namer = namer ?? FoundationModelsChatNamer()
    }

    /// Whether the 15-second passes run (tests).
    var isRunning: Bool { loop != nil }

    // MARK: The app's lifecycle

    /// At launch: from now on naming follows the host and the switch.
    func activate() {
        guard !activated else { return }
        activated = true
        settingObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                 object: preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingChanged() }
        }
        start()
    }

    /// The host started with this local session: its terminals are named from the next pass.
    func hostStarted(_ host: any TerminalNamingHost) {
        stop()
        tracked = [:]
        self.host = host
        start()
    }

    /// The host stopped: naming stops at once, and its terminals' schedules go.
    func hostStopped() {
        stop()
        host = nil
        tracked = [:]
    }

    /// Settings → Apple Intelligence changed (any preference did): off stops naming at once, dropping what a model
    /// call under way answers; on starts it again.
    func settingChanged() {
        if !AppleIntelligence.isOn(preferences) { stop() } else { start() }
    }

    private func start() {
        guard activated, loop == nil, let host, AppleIntelligence.isOn(preferences) else { return }
        let generation = self.generation
        let interval = self.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.generation == generation else { return }
                await self.pass(host, generation: generation)
            }
        }
    }

    private func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    // MARK: A pass

    /// One pass over the host's terminals now (tests; the loop runs one every 15 s).
    func passNow() async {
        guard let host else { return }
        await pass(host, generation: generation)
    }

    /// Naming may go on: the same host and switch, and not in Low Power Mode.
    private func current(_ generation: Int) -> Bool {
        generation == self.generation && AppleIntelligence.isOn(preferences) && !lowPowerMode()
    }

    private func pass(_ host: any TerminalNamingHost, generation: Int) async {
        guard current(generation) else { return }
        // Without the model nothing is read from the host. Asked off the main actor, as chat naming asks it.
        let namer = self.namer
        guard await Task.detached(priority: .utility, operation: { namer.isAvailable }).value,
              current(generation), let terminals = try? await host.terminals(), current(generation) else { return }
        let running = terminals.filter { $0.status == TerminalStatus.running.rawValue }
        let ids = Set(running.map(\.id))
        // Ended terminals' schedules go.
        tracked = tracked.filter { ids.contains($0.key) }
        for terminal in running {
            guard current(generation) else { return }
            await consider(terminal, host: host, generation: generation)
        }
    }

    private func consider(_ terminal: HostTerminal, host: any TerminalNamingHost, generation: Int) async {
        // No new output since the screen was last read to a decision (a host before naming lists no cursor).
        guard terminal.cursor > 0, terminal.cursor != tracked[terminal.id]?.readTo,
              let read = try? await Self.read(terminal, from: host), current(generation) else { return }
        let lines = await Task.detached(priority: .utility) {
            TerminalOutputScreen.lines(of: read.data, columns: terminal.cols, rows: terminal.rows)
        }.value
        guard current(generation) else { return }
        let screen = TerminalScreen(lines: lines)
        let at = now()
        var entry = tracked[terminal.id] ?? Tracked()
        switch entry.schedule.due(screen, now: at) {
        case .no:
            entry.readTo = read.cursor
            tracked[terminal.id] = entry
            return
        case .after:
            // Output changed sooner than the model may be asked again: the screen is read again next pass.
            return
        case .now:
            entry.schedule.asked(screen, at: at)
            entry.readTo = read.cursor
            tracked[terminal.id] = entry
        }
        // Its own name, which the model keeps while it fits: a device's (this Mac's included), not its program's title
        // or its creation label.
        let shown = terminal.title.isEmpty ? nil : terminal.title
        let current = terminal.contextTitleSource == "device" ? shown : nil
        let naming = TerminalContextNamer(namer: namer)
        let model = Task.detached(priority: .utility) { await naming.name(for: screen, current: current) }
        let title = await withTaskCancellationHandler { await model.value } onCancel: { model.cancel() }
        // The name it shows already: sending it would change nothing.
        guard self.current(generation), let title, !TerminalNameRules.sameName(title, shown) else { return }
        // Accepted, or `title_stale` (a device named newer output, which the host keeps); a failure waits for the
        // terminal's next output. Nothing is sent again.
        _ = await host.name(projectID: terminal.projectId, terminalID: terminal.id, title: title, basedOn: read.cursor)
    }

    /// The newest `outputRead` bytes of `terminal`'s output, up to at least the end its listing gave, and the cursor
    /// after them; nil when the reads did not get there.
    nonisolated static func read(_ terminal: HostTerminal, from host: any TerminalNamingHost) async throws -> (data: Data, cursor: UInt64)? {
        var cursor = terminal.cursor > outputRead ? terminal.cursor - outputRead : 0
        var data = Data()
        for _ in 0..<readsPerScreen {
            let output = try await host.output(projectID: terminal.projectId, terminalID: terminal.id, cursor: cursor)
            // The host no longer holds `cursor` (or never did): it answered from its oldest byte.
            if output.reset { data.removeAll() }
            guard let bytes = output.decodedData else { return nil }
            data.append(bytes)
            guard output.cursor > cursor || output.reset else { break }
            cursor = output.cursor
            if cursor >= terminal.cursor { break }
        }
        guard cursor >= terminal.cursor, !data.isEmpty else { return nil }
        return (data.count > Int(outputRead) ? Data(data.suffix(Int(outputRead))) : data, cursor)
    }
}
