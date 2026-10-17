import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// Fakes for the tests that restart the host and the managed runtime (`HostRestartTests`,
/// `OpenCodeIdleRestartTests`): nothing here launches a real process or reads the real Keychain.

@MainActor
extension HostController {
    func stopAndWait() async {
        stop()
        await waitForCurrentOperation()
    }
}

/// Waits up to 10 s for `condition`, on the main actor.
@MainActor func waitForCondition(_ what: String = "the condition", _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !(await condition()) {
        guard Date() < deadline else { throw DesktopError.commandFailed("Timed out waiting for \(what).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct RestartFixture {
    let root: URL
    let workspace: URL
    let state: URL
    let suite: String
    let defaults: UserDefaults
    let processes = FakeHostProcesses()
    let runtime = RestartingRuntime()
    let runner: RecordingHostRunner

    /// `withState: false` is a first launch: no host state yet, so the controller is in onboarding.
    init(withState: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-restart-unit-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("Sample", isDirectory: true)
        state = root.appendingPathComponent("host.json")
        suite = "dev.agentland.restart-test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // Only its existence matters: the fake runner answers for the host's state.
        if withState { try Data("{}".utf8).write(to: state) }
        runner = RecordingHostRunner(directory: workspace.path)
    }

    /// A controller whose Connect has started: development HTTP on loopback, so no certificate,
    /// readiness probe or Bonjour record is involved. `agents` stands in for the host's agent catalog and
    /// `installer` for `install-opencode` (these tests never run the host's command).
    @MainActor func connectedController(backoff: RestartBackoff, secrets: any SecretStoring = NoRestartSecrets(),
                                        agents: FakeAgentsFeed? = nil,
                                        terminals: (any HostTerminalsReading)? = nil,
                                        agentsPollInterval: Duration = .seconds(300),
                                        installer: FakeOpenCodeInstaller = FakeOpenCodeInstaller(outcome: .ready(version: "1.18.31")),
                                        failureReportRetry: Duration = .seconds(300),
                                        connect: Bool = true) throws -> HostController {
        let processes = processes
        var makeFeed: (@MainActor (String) -> (any HostAgentsReading)?)?
        if let agents { makeFeed = { _ in agents } }
        var makeTerminals: (@MainActor (String) -> (any HostTerminalsReading)?)?
        if let terminals { makeTerminals = { _ in terminals } }
        let host = HostController(statePath: state.path, runner: runner, secrets: secrets,
            lifecycle: HostLifecycle(processFactory: { processes.make($0) }), preferences: defaults,
            runtime: runtime, openCodeInstaller: installer, restartBackoff: backoff, monitorInterval: .milliseconds(20),
            agentsFeed: makeFeed, agentsPollInterval: agentsPollInterval, failureReportRetry: failureReportRetry,
            terminalsFeed: makeTerminals)
        host.projectDirectory = workspace.path
        host.projectName = "Sample"
        host.projectID = "workspace"
        host.managedOpenCode = true
        host.connectionMode = .developmentHTTP
        host.listenAddress = "127.0.0.1:9"
        if connect { host.start() }
        return host
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Stands in for `agentland-host`: running from launch until the test makes it exit or it is stopped.
final class FakeHostProcess: HostProcess, @unchecked Sendable {
    let command: HostCommand
    private let lock = NSLock()
    private var running = false
    private let exitsAtLaunch: Bool

    init(command: HostCommand, exitsAtLaunch: Bool) {
        self.command = command
        self.exitsAtLaunch = exitsAtLaunch
    }

    var isRunning: Bool { lock.withLock { running } }
    func launch() throws { lock.withLock { running = !exitsAtLaunch } }
    func terminate() { onTerminate?(); exit() }
    var onTerminate: (@Sendable () -> Void)?
    func forceTerminate() { exit() }
    func waitForExit(timeout: TimeInterval) -> Bool { !isRunning }
    func exit() { lock.withLock { running = false } }
}

final class FakeHostProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeHostProcess] = []
    private var dieAtLaunch = false
    /// Called when any host process is asked to terminate (tests record the order against other calls).
    var onTerminate: (@Sendable () -> Void)?

    var exitAtLaunch: Bool {
        get { lock.withLock { dieAtLaunch } }
        set { lock.withLock { dieAtLaunch = newValue } }
    }
    var count: Int { lock.withLock { made.count } }
    var first: FakeHostProcess? { lock.withLock { made.first } }
    var last: FakeHostProcess? { lock.withLock { made.last } }
    subscript(index: Int) -> FakeHostProcess { lock.withLock { made[index] } }

    func make(_ command: HostCommand) -> any HostProcess {
        lock.withLock {
            let process = FakeHostProcess(command: command, exitsAtLaunch: dieAtLaunch)
            process.onTerminate = onTerminate
            made.append(process)
            return process
        }
    }
}

/// The managed runtime: each start listens on the next port with the password it was given, and keeps
/// the provider environment and model it got. It runs the host's OpenCode 1.18.31 until the host
/// "installs" another (`installNewVersion`), which the next start runs, as the real runtime does; one
/// that does not start leaves the previous version running, with the reason, and is no reason to restart
/// again. `unavailable` makes starts find no OpenCode that starts, and `pendingReports` stands in for
/// versions that did not start, until the host hears of them.
actor RestartingRuntime: OpenCodeRuntimeRunning {
    private(set) var starts = 0
    private(set) var passwords: [String] = []
    private(set) var directories: [String] = []
    private(set) var environments: [[String: String]] = []
    private(set) var models: [String?] = []
    private(set) var forgotten = 0
    private var running = false
    private var current = OpenCodeRuntimeReport(source: .managed(ManagedAgentRecord(version: "1.18.31", command: "opencode")),
                                                version: "1.18.31")
    private var installed: (version: String, starts: Bool)?
    private var unavailableReason: String?
    private var lastStartFailed = false
    private var valid = true
    private var pending: [OpenCodeFailureReport] = []

    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL {
        starts += 1
        passwords.append(password)
        directories.append(directory)
        environments.append(providerEnvironment)
        models.append(model)
        if let unavailableReason {
            lastStartFailed = true
            throw ManagedOpenCodeError.unavailable(unavailableReason, short: "it didn’t start")
        }
        lastStartFailed = false
        if let installed {
            current = installed.starts
                ? OpenCodeRuntimeReport(source: .managed(ManagedAgentRecord(version: installed.version, command: "opencode")),
                                        version: installed.version)
                : OpenCodeRuntimeReport(source: .previous(ManagedAgentRecord(version: current.version, command: "opencode")),
                                        version: current.version,
                                        fallbackReason: "OpenCode \(installed.version) didn’t start. AgentLand runs the previous version, \(current.version).")
        }
        installed = nil
        running = true
        return URL(string: "http://127.0.0.1:\(4100 + starts)")!
    }
    func stop() async throws { running = false }
    func isRunning() -> Bool { running }
    /// No provider catalog is read in these tests.
    func endpoint() -> URL? { nil }
    func exit() { running = false }
    func report() -> OpenCodeRuntimeReport? { running ? current : nil }
    /// As the real runtime: a new version while one runs, or one to try while none started last time.
    func restartWouldChangeBinary() -> Bool { (running || lastStartFailed) && installed != nil }
    func installNewVersion(_ version: String, starts: Bool = true) { installed = (version, starts) }
    func hasValidManagedOpenCode() -> Bool { valid }
    func pendingFailureReports() -> [OpenCodeFailureReport] { pending }
    func noteFailureReported(_ report: OpenCodeFailureReport) { pending.removeAll { $0 == report } }
    func forgetFailures() { forgotten += 1 }

    /// Starts find no OpenCode that starts (nil: they start again).
    func setUnavailable(_ reason: String?) { unavailableReason = reason }
    /// Whether the host's current OpenCode passes the checks (a start then gets nothing).
    func setValid(_ value: Bool) { valid = value }
    func setPendingReports(_ reports: [OpenCodeFailureReport]) { pending = reports }
    /// The reports still waiting. (A test's `await runtime.pendingFailureReports()` would pick the protocol
    /// extension's async default over this actor's own method.)
    var reportsWaiting: [OpenCodeFailureReport] { pending }
}

/// `install-opencode`'s stand-in: gives the events the test sets, then its outcome; the test's `onInstall`
/// runs before the outcome (the host "wrote" `current.json`). It can wait for the test to let it finish.
final class FakeOpenCodeInstaller: OpenCodeInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OpenCodeInstallEvent]
    private var outcome: OpenCodeInstallOutcome
    private var calls = 0
    private var held = false
    private var onInstall: (@Sendable () async -> Void)?
    private var statePaths: [String] = []

    init(events: [OpenCodeInstallEvent] = [], outcome: OpenCodeInstallOutcome) {
        self.events = events
        self.outcome = outcome
    }

    var installs: Int { lock.withLock { calls } }
    var states: [String] { lock.withLock { statePaths } }
    func answer(events: [OpenCodeInstallEvent], outcome: OpenCodeInstallOutcome) { lock.withLock { self.events = events; self.outcome = outcome } }
    func hold(_ value: Bool) { lock.withLock { held = value } }
    func whenInstalling(_ body: @escaping @Sendable () async -> Void) { lock.withLock { onInstall = body } }

    func install(statePath: String, progress: @escaping @Sendable (OpenCodeInstallEvent) -> Void) async throws -> OpenCodeInstallOutcome {
        let (events, outcome, body) = lock.withLock { () -> ([OpenCodeInstallEvent], OpenCodeInstallOutcome, (@Sendable () async -> Void)?) in
            calls += 1
            statePaths.append(statePath)
            return (self.events, self.outcome, onInstall)
        }
        for event in events { progress(event) }
        while lock.withLock({ held }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        await body?()
        return outcome
    }
}

/// Answers `config show` with what `config set` last wrote (or what a test set as the host's list,
/// as a device's rename or removal does); records the OpenCode addresses and project lists set.
final class RecordingHostRunner: HostCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var openCodeURL = "http://127.0.0.1:4197"
    private var urls: [String] = []
    /// id, name, directory
    private var projects: [[String]]
    private var projectLists: [[[String]]] = []
    private var hookCalls: [[String]] = []

    /// Where `revoke` and each `terminals hook` are recorded, to order them against the terminal calls.
    var log: TerminalCallLog?

    init(directory: String) { projects = [["workspace", "Sample", directory]] }

    var configuredURLs: [String] { lock.withLock { urls } }
    var configuredProjects: [[[String]]] { lock.withLock { projectLists } }
    /// Every `terminals hook` command's arguments, in order.
    var hooks: [[String]] { lock.withLock { hookCalls } }
    func setProjects(_ value: [[String]]) { lock.withLock { projects = value } }

    func run(_ command: HostCommand) throws -> CommandOutput {
        let arguments = command.arguments
        if arguments.starts(with: ["config", "set"]) || arguments.first == "init", let index = arguments.firstIndex(of: "--opencode-url") {
            let written = arguments.indices.filter { arguments[$0] == "--project" && $0 + 1 < arguments.count }
                .map { arguments[$0 + 1].split(separator: "=", maxSplits: 2).map(String.init) }
            lock.withLock {
                openCodeURL = arguments[index + 1]
                urls.append(openCodeURL)
                projects = written
                projectLists.append(written)
            }
            return CommandOutput(standardOutput: "", standardError: "", exitCode: 0)
        }
        if arguments.starts(with: ["config", "show"]) {
            let configuration: [String: Any] = [
                "openCodeUrl": lock.withLock { openCodeURL }, "passwordEnv": "AGENTLAND_OPENCODE_PASSWORD",
                "projects": lock.withLock { projects }.map { ["id": $0[0], "name": $0[1], "directory": $0[2]] }
            ]
            let data = try JSONSerialization.data(withJSONObject: configuration)
            return CommandOutput(standardOutput: String(decoding: data, as: UTF8.self), standardError: "", exitCode: 0)
        }
        if arguments.first == "revoke" { log?.add("revoke"); return CommandOutput(standardOutput: "", standardError: "", exitCode: 0) }
        if arguments.starts(with: ["terminals", "hook"]), arguments.count > 2 {
            lock.withLock { hookCalls.append(arguments) }
            log?.add("hook " + arguments[2])
            return CommandOutput(standardOutput: "", standardError: "", exitCode: 0)
        }
        if arguments.first == "devices" { return CommandOutput(standardOutput: "", standardError: "", exitCode: 0) }
        throw DesktopError.commandFailed("Unexpected command in the restart tests: \(arguments.first ?? "")")
    }
}

struct NoRestartSecrets: SecretStoring {
    func save(_ secret: String, account: String) throws {}
    func load(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
}

/// The Keychain's stand-in: items by account, in memory.
final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String] = [:]) { self.values = values }

    var items: [String: String] { lock.withLock { values } }
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func load(account: String) throws -> String? { lock.withLock { values[account] } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
}

/// The host's `GET /v1/agents`: answers with the `opencode` entry the test sets, or an error, after an
/// optional delay; counts the requests. It keeps the failed OpenCode versions reported to it
/// (`POST /v1/agents/opencode/failed`), and answers them as the test sets.
final class FakeAgentsFeed: HostAgentsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reply: Result<HostAgentStatus?, ClientError>
    private var asked = 0
    private var wait: Duration = .zero
    private var reported: [OpenCodeFailureReport] = []
    private var reportReply: Result<OpenCodeFailureAnswer, ClientError> = .success(OpenCodeFailureAnswer(rolledBack: true, current: "1.18.31"))

    init(openCode: HostAgentStatus?) { reply = .success(openCode) }

    var requests: Int { lock.withLock { asked } }
    var reports: [OpenCodeFailureReport] { lock.withLock { reported } }
    func answer(_ openCode: HostAgentStatus?) { lock.withLock { reply = .success(openCode) } }
    func fail(_ error: ClientError) { lock.withLock { reply = .failure(error) } }
    func delay(_ duration: Duration) { lock.withLock { wait = duration } }
    func answerReports(_ result: Result<OpenCodeFailureAnswer, ClientError>) { lock.withLock { reportReply = result } }

    func reportOpenCodeFailure(version: String, reason: String) async throws -> OpenCodeFailureAnswer {
        try lock.withLock {
            reported.append(OpenCodeFailureReport(version: version, reason: reason))
            return try reportReply.get()
        }
    }

    func agents() async throws -> HostAgentsCatalog {
        let (reply, wait) = lock.withLock { () -> (Result<HostAgentStatus?, ClientError>, Duration) in
            asked += 1
            return (self.reply, self.wait)
        }
        if wait > .zero { try await Task.sleep(for: wait) }
        return HostAgentsCatalog(agents: try reply.get().map { [$0] } ?? [])
    }
}
