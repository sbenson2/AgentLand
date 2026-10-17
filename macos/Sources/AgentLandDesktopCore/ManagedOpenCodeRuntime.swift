import Foundation
import Darwin

public enum ManagedOpenCodeError: LocalizedError, Sendable {
    case invalidDirectory
    case missingPassword
    case invalidProviderEnvironment
    case invalidModel
    case alreadyRunning
    case alreadyStarting
    /// The program could not be run at all.
    case couldNotRun(String)
    case startupFailed(String)
    case startupTimedOut(String)
    case interrupted
    case stopTimedOut
    /// No OpenCode started: the host has none that passes the checks, or the versions it keeps did not
    /// start. `short` is a few words for the menu.
    case unavailable(String, short: String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "Choose an existing project directory."
        case .missingPassword: "Set an OpenCode server password before starting."
        case .invalidProviderEnvironment: "The provider credential name is invalid."
        case .invalidModel: "Choose a provider and model in provider/model format."
        case .alreadyRunning: "Stop OpenCode before changing its provider or model."
        case .alreadyStarting: "OpenCode is already starting."
        case let .couldNotRun(message): "OpenCode could not start: \(message)"
        case let .startupFailed(message): "OpenCode could not start: \(message)"
        case let .startupTimedOut(message): "OpenCode did not become ready in time. \(message)"
        case .interrupted: "OpenCode startup was stopped."
        case .stopTimedOut: "OpenCode did not stop after a bounded shutdown attempt."
        case let .unavailable(reason, _): reason
        }
    }
}

extension ManagedOpenCodeError {
    /// The program did not become ready: it could not be run, exited, or did not answer in time.
    var isStartupFailure: Bool {
        switch self {
        case .couldNotRun, .startupFailed, .startupTimedOut: true
        default: false
        }
    }
}

/// What the managed runtime runs (Settings → AI Providers).
public struct OpenCodeRuntimeReport: Equatable, Sendable {
    public let source: OpenCodeBinaryChoice.Source
    /// The version the running OpenCode reports (`/global/health`).
    public let version: String
    /// Why the previous version runs: the current one did not start, or cannot be used.
    public let fallbackReason: String?

    public init(source: OpenCodeBinaryChoice.Source, version: String, fallbackReason: String? = nil) {
        self.source = source
        self.version = version
        self.fallbackReason = fallbackReason
    }
}

/// Runs one OpenCode server at a time for the Mac app: the host's managed OpenCode, when it passes
/// `OpenCodeBinaryLocator`'s checks. The app bundles none. When the current version does not start, the
/// previous version the host keeps (`current.json`'s `previous`, checked the same way) starts at once:
///
/// - One that exits or cannot be run counts as not starting at once. One that does not answer within
///   `startupTimeout` gets one more start (a first start on real data may migrate it): the next start in
///   this launch tries it again, and a second timeout counts.
/// - A version that counts is remembered (`managed-opencode-failure.json` in the storage folder) and not run
///   again, as the current or as the previous version, while the host keeps it. The host hears about it once
///   it runs (`pendingFailureReports()`), goes back to its previous version and records why.
/// - It is remembered only when the previous version then starts, since otherwise the fault is not shown to
///   be the version's. With no previous version that starts, no OpenCode runs (`unavailable`), and later
///   starts (Connect, the next launch, Try Again) try again; nothing restarts on its own.
/// - Before a version's first start on this Mac the data folder is cloned, and it is put back when that
///   version does not start and the previous one runs (`OpenCodeDataGuard`).
public actor ManagedOpenCodeRuntime {
    private struct Owned {
        let id: UUID
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
        let output: RuntimeOutput
        let port: UInt16
        var readyEndpoint: URL?
    }

    /// A version that did not start while the previous one then did, when, why, and whether the host heard.
    struct Failure: Codable, Equatable {
        let record: ManagedAgentRecord
        let failedAt: Date
        var reason: String?
        var reported: Bool?
    }

    /// How long a start may take to answer its health check: the host's own check allows 30 s
    /// (docs/HOST-API.md "Installs").
    public static let defaultStartupTimeout: TimeInterval = 30
    /// Starts in a row that a version which does not answer in time gets before it counts as not starting.
    static let slowStartAttempts = 2
    /// The service the managed OpenCode's web search sends queries to (`OPENCODE_WEBSEARCH_PROVIDER`), which the
    /// host names to devices (`serve --websearch-provider`, docs/HOST-API.md "Plain chats").
    public static let webSearchProvider = "exa"

    private let binaries: OpenCodeBinaryLocator
    private let storageRoot: URL
    private let dataGuard: OpenCodeDataGuard
    private let startupTimeout: TimeInterval
    /// Where OpenCode's output goes (`opencode.log`); nil keeps only the bounded capture for diagnostics.
    private let logFolder: URL?
    private var owned: Owned?
    /// What runs, once it is ready.
    private var running: OpenCodeRuntimeReport?
    /// The current version that did not answer in time, and how many starts in a row, in this launch.
    private var slowStarts: (record: ManagedAgentRecord, count: Int)?
    /// The programs the last start tried (`ManagedAgentRecord.identity`), and whether none of them started.
    private var attempted: Set<String> = []
    private var lastStartUnavailable = false

    public static func defaultStorageRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentLand/OpenCode", isDirectory: true)
    }

    /// `agentsFolder` is the host's `<state>.agents`, whose `opencode/current.json` names the OpenCode each
    /// start runs (nil: none can run). `startupTimeout` bounds each start.
    public init(agentsFolder: URL? = nil,
                storageRoot: URL = ManagedOpenCodeRuntime.defaultStorageRoot(),
                startupTimeout: TimeInterval = ManagedOpenCodeRuntime.defaultStartupTimeout,
                logFolder: URL? = nil) {
        self.logFolder = logFolder
        self.binaries = OpenCodeBinaryLocator(agentsFolder: agentsFolder)
        self.storageRoot = storageRoot
        self.dataGuard = OpenCodeDataGuard(storageRoot: storageRoot)
        self.startupTimeout = max(0.1, startupTimeout)
    }

    var failureURL: URL { storageRoot.appendingPathComponent("managed-opencode-failure.json") }

    deinit {
        if let owned, owned.process.isRunning {
            owned.process.terminate()
            if !Self.waitForExit(owned.process, timeout: 2) {
                kill(owned.process.processIdentifier, SIGKILL)
                _ = Self.waitForExit(owned.process, timeout: 2)
            }
        }
    }

    public func start(directory: String, password: String,
                      providerEnvironment: [String: String] = [:], model: String? = nil) async throws -> URL {
        if let owned {
            if owned.readyEndpoint != nil, owned.process.isRunning { throw ManagedOpenCodeError.alreadyRunning }
            if owned.process.isRunning { throw ManagedOpenCodeError.alreadyStarting }
            self.owned = nil
        }
        try Task.checkCancellation()
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory),
              (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ManagedOpenCodeError.invalidDirectory
        }
        guard !password.isEmpty else { throw ManagedOpenCodeError.missingPassword }
        guard providerEnvironment.keys.allSatisfy(Self.supportsProviderEnvironmentKey) else {
            throw ManagedOpenCodeError.invalidProviderEnvironment
        }
        if let model, (model.isEmpty || !model.contains("/") || model.contains(where: \.isWhitespace)) {
            throw ManagedOpenCodeError.invalidModel
        }
        try prepareStorage(model: model)
        let settings = LaunchSettings(directory: directory, password: password, providerEnvironment: providerEnvironment, model: model)
        attempted = []
        lastStartUnavailable = false
        let failed = currentFailure()?.record
        let plan = binaries.plan(skipping: failed)
        guard let first = plan.first else {
            throw unavailable(plan.why ?? ManagedOpenCodeRejection.notInstalled.description, short: notUsedReason())
        }
        let prefix = plan.why.map { $0 + " " } ?? ""
        guard case let .managed(record) = first.source else {
            // The current version did not start last time, or fails the checks: the previous one alone.
            let previous = first.source.record.version
            do {
                return try await attempt(first, fallbackReason: "\(prefix)AgentLand runs the previous version, \(previous).", settings)
            } catch let error as ManagedOpenCodeError where error.isStartupFailure {
                throw unavailable("\(prefix)The previous version, \(previous), didn’t start either. \(error.localizedDescription)",
                                  short: "it didn’t start")
            }
        }
        do {
            let endpoint = try await attempt(first, fallbackReason: nil, settings)
            slowStarts = nil
            return endpoint
        } catch let error as ManagedOpenCodeError where error.isStartupFailure {
            return try await fallBack(from: record, after: error, to: plan.fallback, settings)
        }
    }

    /// The current version did not start: the previous one starts at once, on the data as it was before the
    /// current one's first start. The current one counts as not starting when it exited or could not be run,
    /// or at its second timeout in this launch; it is remembered and reported only when the previous one
    /// then starts.
    private func fallBack(from record: ManagedAgentRecord, after error: ManagedOpenCodeError,
                          to fallback: OpenCodeBinaryChoice?, _ settings: LaunchSettings) async throws -> URL {
        var timedOut = false
        if case .startupTimedOut = error { timedOut = true }
        let count = timedOut ? (slowStarts.map { $0.record == record ? $0.count : 0 } ?? 0) + 1 : Self.slowStartAttempts
        let counts = count >= Self.slowStartAttempts
        slowStarts = counts ? nil : (record, count)
        let version = record.version
        let why = timedOut ? "OpenCode \(version) didn’t start in time\(count > 1 ? " again" : "")." : "OpenCode \(version) didn’t start."
        guard let fallback else {
            throw unavailable("\(why) \(error.localizedDescription)", short: "it didn’t start")
        }
        // The previous version gets the data as it was before this version's first start.
        dataGuard.restoreAfterFailedFirstStart(of: version)
        let previous = fallback.source.record.version
        let retry = counts ? "" : " AgentLand tries \(version) once more when OpenCode next restarts."
        do {
            let endpoint = try await attempt(fallback, fallbackReason:
                redact("\(why) AgentLand runs the previous version, \(previous).\(retry) \(error.localizedDescription)"), settings)
            if counts {
                let reason: String
                switch error {
                case .startupTimedOut:
                    let seconds = Int(startupTimeout.rounded())
                    reason = "It did not answer within \(seconds == 1 ? "1 second" : "\(seconds) seconds"), twice."
                case .couldNotRun: reason = "It could not be run."
                default: reason = "It stopped before it was ready."
                }
                rememberFailure(record, reason: reason)
            }
            return endpoint
        } catch let second as ManagedOpenCodeError where second.isStartupFailure {
            throw unavailable("\(why) The previous version, \(previous), didn’t start either. \(second.localizedDescription)",
                              short: "it didn’t start")
        }
    }

    /// Starts `choice`, cloning the data folder first when that version has never started on this Mac.
    private func attempt(_ choice: OpenCodeBinaryChoice, fallbackReason: String?, _ settings: LaunchSettings) async throws -> URL {
        let record = choice.source.record
        attempted.insert(record.identity)
        dataGuard.snapshotBeforeFirstStart(of: record.version)
        let endpoint = try await launch(choice.executableURL, source: choice.source, fallbackReason: fallbackReason,
                                        timeout: startupTimeout, settings)
        dataGuard.noteStarted(record.version)
        return endpoint
    }

    /// No OpenCode started in this start.
    private func unavailable(_ reason: String, short: String) -> ManagedOpenCodeError {
        lastStartUnavailable = true
        return .unavailable(redact(reason), short: short)
    }

    /// The menu's words when no version was tried.
    private func notUsedReason() -> String {
        switch binaries.managedExecutable() {
        case .failure(.notInstalled): "it isn’t installed"
        case .failure: "it didn’t pass AgentLand’s checks"
        case .success: "it didn’t start last time"
        }
    }

    private struct LaunchSettings {
        let directory: String
        let password: String
        let providerEnvironment: [String: String]
        let model: String?
    }

    public func stop() async throws {
        lastStartUnavailable = false
        try stopOwned()
    }

    public func isRunning() -> Bool {
        guard let owned, owned.process.isRunning else { return false }
        return owned.readyEndpoint != nil
    }

    public func endpoint() -> URL? {
        guard let owned, owned.process.isRunning else { return nil }
        return owned.readyEndpoint
    }

    /// What runs now: the host's current OpenCode or its previous version, the version it reports, and why
    /// the previous one runs. Nil while nothing is ready.
    public func report() -> OpenCodeRuntimeReport? {
        isRunning() ? running : nil
    }

    /// Whether the host's current OpenCode passes the checks, so a start needs nothing downloaded.
    public func hasValidManagedOpenCode() -> Bool {
        if case .success = binaries.managedExecutable() { return true }
        return false
    }

    /// Whether a start now would run another program than the one running: the host installed a version that
    /// passes the checks and is not remembered as not starting. While nothing runs because the last start
    /// found nothing that started: whether a start now would try a program that start did not. A version
    /// that fails the checks or did not start never takes the running one down, and none is restarted for
    /// again and again.
    public func restartWouldChangeBinary() -> Bool {
        guard let next = binaries.plan(skipping: currentFailure()?.record).first else { return false }
        if isRunning(), let running { return running.source.record.identity != next.source.record.identity }
        return owned == nil && lastStartUnavailable && !attempted.contains(next.source.record.identity)
    }

    // MARK: The versions that did not start

    /// The version that did not start while the previous one then did, and that the host has not heard about.
    public func pendingFailureReports() -> [OpenCodeFailureReport] {
        guard let failure = readFailure(), failure.reported != true else { return [] }
        return [OpenCodeFailureReport(version: failure.record.version, reason: failure.reason ?? "It did not start.")]
    }

    /// The host answered `report`.
    public func noteFailureReported(_ report: OpenCodeFailureReport) {
        guard var failure = readFailure(), failure.record.version == report.version, failure.reported != true else { return }
        failure.reported = true
        writeFailure(failure)
    }

    /// Try Again: every version the host keeps is tried again.
    public func forgetFailures() {
        forgetFailure()
        slowStarts = nil
    }

    /// Starts `executable` and waits until it answers its health check, within `timeout`.
    /// A child that fails is stopped before this returns.
    private func launch(_ executable: URL, source: OpenCodeBinaryChoice.Source, fallbackReason: String?,
                        timeout: TimeInterval, _ settings: LaunchSettings) async throws -> URL {
        try Task.checkCancellation()
        let password = settings.password
        let providerEnvironment = settings.providerEnvironment
        let port = try Self.reserveLoopbackPort()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let output = RuntimeOutput(expectedListener: "opencode server listening on http://127.0.0.1:\(port)")
        process.executableURL = executable
        // OpenCode's own log lines (sessions created and removed, location services booted) go to its output, and
        // from there to opencode.log, so a terminal's end can be read afterwards.
        process.arguments = ["serve", "--pure", "--hostname", "127.0.0.1", "--port", String(port), "--print-logs", "--log-level", "INFO"]
        process.currentDirectoryURL = URL(fileURLWithPath: settings.directory, isDirectory: true)
        process.environment = makeEnvironment(password: password, providerEnvironment: providerEnvironment, model: settings.model)
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw ManagedOpenCodeError.couldNotRun(redact(error.localizedDescription)) }
        let id = UUID()
        owned = Owned(id: id, process: process, stdout: stdout, stderr: stderr, output: output, port: port)
        if let logFolder {
            let log = ChildProcessLog(folder: logFolder, name: "opencode", secrets: [password] + Array(providerEnvironment.values))
            log.started("opencode \(source.record.version)", pid: process.processIdentifier)
            Self.drain(stdout.fileHandleForReading, into: output, log: log)
            Self.drain(stderr.fileHandleForReading, into: output, log: log)
        } else {
            Self.drain(stdout.fileHandleForReading, into: output)
            Self.drain(stderr.fileHandleForReading, into: output)
        }
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let client = OpenCodeHTTPClient(endpoint: endpoint, password: password)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                guard let current = owned, current.id == id else { throw ManagedOpenCodeError.interrupted }
                if !process.isRunning {
                    throw ManagedOpenCodeError.startupFailed(Self.diagnostic(output: output, secrets: [password] + Array(providerEnvironment.values)))
                }
                if output.listenerReported, let version = try? await client.healthyVersion() {
                    try Task.checkCancellation()
                    guard var current = owned, current.id == id, process.isRunning else {
                        throw ManagedOpenCodeError.interrupted
                    }
                    current.readyEndpoint = endpoint
                    owned = current
                    running = OpenCodeRuntimeReport(source: source, version: version, fallbackReason: fallbackReason)
                    return endpoint
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ManagedOpenCodeError.startupTimedOut(Self.diagnostic(output: output, secrets: [password] + Array(providerEnvironment.values)))
        } catch {
            if owned?.id == id { try stopOwned() }
            throw error
        }
    }

    private func stopOwned() throws {
        guard let current = owned else { return }
        owned?.readyEndpoint = nil
        running = nil
        if current.process.isRunning { current.process.terminate() }
        if !Self.waitForExit(current.process, timeout: 2) {
            kill(current.process.processIdentifier, SIGKILL)
            guard Self.waitForExit(current.process, timeout: 2) else { throw ManagedOpenCodeError.stopTimedOut }
        }
        owned = nil
    }

    // MARK: The failure file

    func readFailure() -> Failure? {
        guard let info = OpenCodeBinaryLocator.status(failureURL.path), OpenCodeBinaryLocator.isType(info, S_IFREG),
              let data = OpenCodeBinaryLocator.read(failureURL.path, matching: info, limit: OpenCodeBinaryLocator.maximumRecordBytes) else {
            return nil
        }
        return try? Self.failureDecoder.decode(Failure.self, from: data)
    }

    /// The remembered version, while the host keeps it as its current or its previous version; forgotten
    /// once the host keeps it no more.
    private func currentFailure() -> Failure? {
        guard let failure = readFailure() else { return nil }
        if case let .success(records) = binaries.records(), records.current != failure.record, records.previous != failure.record {
            forgetFailure()
            return nil
        }
        return failure
    }

    private func rememberFailure(_ record: ManagedAgentRecord, reason: String) {
        writeFailure(Failure(record: record, failedAt: Date(), reason: reason, reported: false))
    }

    private func writeFailure(_ failure: Failure) {
        guard let data = try? Self.failureEncoder.encode(failure) else { return }
        try? data.write(to: failureURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: failureURL.path)
    }

    private func forgetFailure() { try? FileManager.default.removeItem(at: failureURL) }

    private static let failureEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let failureDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func prepareStorage(model: String?) throws {
        let manager = FileManager.default
        for name in ["", "config", "config/opencode", "data", "cache", "state"] {
            let directory = name.isEmpty ? storageRoot : storageRoot.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        var configuration: [String: Any] = ["autoupdate": false]
        if let model { configuration["model"] = model }
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let file = storageRoot.appendingPathComponent("config/opencode/opencode.json")
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func makeEnvironment(password: String, providerEnvironment: [String: String], model: String?) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH", "TERM"] {
            environment[key] = inherited[key]
        }
        for (key, value) in inherited where key.hasPrefix("LC_") { environment[key] = value }
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        environment["XDG_CONFIG_HOME"] = storageRoot.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = storageRoot.appendingPathComponent("data").path
        environment["XDG_CACHE_HOME"] = storageRoot.appendingPathComponent("cache").path
        environment["XDG_STATE_HOME"] = storageRoot.appendingPathComponent("state").path
        environment["OPENCODE_CONFIG_DIR"] = storageRoot.appendingPathComponent("config/opencode").path
        environment["OPENCODE_CONFIG"] = storageRoot.appendingPathComponent("config/opencode/opencode.json").path
        environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        environment["OPENCODE_SERVER_PASSWORD"] = password
        // Plain chats' web search (docs/HOST-API.md "Plain chats"): OpenCode's websearch on Exa, without a key. It is
        // OpenCode-wide, so a workspace's OpenCode chats can search too.
        environment["OPENCODE_ENABLE_EXA"] = "1"
        environment["OPENCODE_WEBSEARCH_PROVIDER"] = Self.webSearchProvider
        if let model {
            let data = try! JSONSerialization.data(withJSONObject: ["model": model])
            environment["OPENCODE_CONFIG_CONTENT"] = String(data: data, encoding: .utf8)
        }
        environment.merge(providerEnvironment) { _, supplied in supplied }
        return environment
    }

    public static func supportsProviderEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil else { return false }
        if key == "OPENCODE_API_KEY" { return true }
        guard key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN") else { return false }
        return !["DYLD_", "LD_", "BUN_", "NODE_", "PYTHON_", "RUBY_", "JAVA_", "PERL_",
                 "GIT_", "SSH_", "XDG_", "OPENCODE_"].contains { key.hasPrefix($0) }
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ManagedOpenCodeError.startupFailed("Could not reserve a loopback port.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw ManagedOpenCodeError.startupFailed("Could not reserve a loopback port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard found == 0 else { throw ManagedOpenCodeError.startupFailed("Could not inspect the reserved port.") }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func drain(_ handle: FileHandle, into output: RuntimeOutput, log: ChildProcessLog? = nil) {
        output.readerStarted()
        if let log {
            log.drain(handle, also: { output.append($0) }, finished: { output.readerFinished() })
            return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { output.readerFinished() }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                output.append(chunk)
            }
        }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }

    private static func diagnostic(output: RuntimeOutput, secrets: [String]) -> String {
        output.waitForReaders(timeout: 0.5)
        var value = output.text
        for secret in secrets where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[redacted]")
            value = value.replacingOccurrences(of: Data(secret.utf8).base64EncodedString(), with: "[redacted]")
        }
        if let password = secrets.first, !password.isEmpty {
            value = value.replacingOccurrences(of: Data("opencode:\(password)".utf8).base64EncodedString(), with: "[redacted]")
        }
        return redact(value, limit: 1000)
    }
}

private final class RuntimeOutput: @unchecked Sendable {
    private let expectedListener: String
    private let lock = NSLock()
    private let readers = DispatchGroup()
    private var data = Data()
    private var scanTail = Data()
    private var sawListener = false

    init(expectedListener: String) { self.expectedListener = expectedListener }

    func readerStarted() { readers.enter() }
    func readerFinished() { readers.leave() }
    func waitForReaders(timeout: TimeInterval) { _ = readers.wait(timeout: .now() + timeout) }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if !sawListener {
            let combined = scanTail + chunk
            sawListener = String(decoding: combined, as: UTF8.self).contains(expectedListener)
            scanTail = Data(combined.suffix(expectedListener.utf8.count))
        }
        data.append(chunk)
        if data.count > 16 * 1024 { data.removeFirst(data.count - 16 * 1024) }
    }

    var listenerReported: Bool {
        lock.lock(); defer { lock.unlock() }
        return sawListener
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
