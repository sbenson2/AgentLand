import Darwin
import Foundation

/// One line of `agentland-host install-opencode`'s output: the host prints one JSON object per line while it
/// makes sure a valid managed OpenCode is current (it reads the registry, downloads the registry's OpenCode,
/// checks it and writes `current.json`).
public enum OpenCodeInstallEvent: Equatable, Sendable {
    /// Reading the registry.
    case registry
    /// Downloading `version`: `received` bytes of `total` (nil when the host does not know the size).
    case downloading(version: String, received: Int64, total: Int64?)
    /// Running OpenCode's check on `version`.
    case checking(version: String)
    /// `version` is current and passed its check; the command then ends with status 0.
    case ready(version: String)
    /// The host could not make OpenCode ready: `code` (`offline`, `registry_unavailable`,
    /// `unverified_download`, `unsupported_platform`, `check_failed`, `busy`, …) and its words.
    case failed(code: String, error: String)

    /// Reads one line. Nil for an empty line, one that is not a JSON object with an `event`, or an event
    /// this version does not know.
    public static func parse(_ line: Data) -> OpenCodeInstallEvent? {
        guard !line.isEmpty, let fields = try? JSONDecoder().decode(Fields.self, from: line) else { return nil }
        let version = fields.version.map { cleaned($0, limit: 64) }.flatMap { $0.isEmpty ? nil : $0 }
        switch fields.event {
        case "registry":
            return .registry
        case "downloading":
            guard let version, let received = fields.received else { return nil }
            return .downloading(version: version, received: received, total: fields.total.flatMap { $0 > 0 ? $0 : nil })
        case "checking":
            return version.map { .checking(version: $0) }
        case "ready":
            return version.map { .ready(version: $0) }
        case "failed":
            return .failed(code: cleaned(fields.code ?? "", limit: 64), error: redact(cleaned(fields.error ?? "", limit: 600), limit: 600))
        default:
            return nil
        }
    }

    /// The host's text on one line, without control characters, at most `limit` characters.
    static func cleaned(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    /// A line's fields; a field of the wrong type reads as absent.
    private struct Fields: Decodable {
        let event: String
        let version: String?
        let received: Int64?
        let total: Int64?
        let code: String?
        let error: String?

        enum CodingKeys: String, CodingKey { case event, version, received, total, code, error }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = try container.decode(String.self, forKey: .event)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
            received = Self.count(container, .received)
            total = Self.count(container, .total)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
            error = try? container.decodeIfPresent(String.self, forKey: .error)
        }

        /// A byte count: a whole, finite, non-negative JSON number.
        private static func count(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
            guard let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite, value >= 0,
                  value < 9.0e18 else { return nil }
            return Int64(value)
        }
    }
}

/// Why `install-opencode` did not make OpenCode ready, with the owner's words for it.
public struct OpenCodeInstallFailure: Error, Equatable, Sendable {
    /// The host's code; nil when it gave none (it did not run, stopped without a `failed` line, took too long).
    public let code: String?
    /// The host's words, or what AgentLand saw.
    public let detail: String

    public init(code: String?, detail: String) {
        self.code = code.flatMap { $0.isEmpty ? nil : $0 }
        self.detail = detail
    }

    public var isOffline: Bool { code == "offline" }

    /// What went wrong, in plain words (Settings → AI Providers, onboarding).
    public var message: String {
        switch code {
        case "offline":
            return "AgentLand needs a network connection to get OpenCode the first time."
        case "registry_unavailable":
            return "AgentLand couldn’t reach the agent registry to get OpenCode."
        case "unverified_download":
            return "The registry’s OpenCode for this Mac has no checksum, so AgentLand didn’t install it."
        case "unsupported_platform":
            return "The registry has no OpenCode for this Mac."
        case "check_failed":
            return detail.isEmpty ? "The downloaded OpenCode didn’t pass its check."
                : "The downloaded OpenCode didn’t pass its check: \(detail)"
        case "busy":
            return "Another AgentLand host is running with this Mac’s settings. Quit it, then try again."
        default:
            return detail.isEmpty ? "AgentLand couldn’t get OpenCode." : "AgentLand couldn’t get OpenCode: \(detail)"
        }
    }

    /// A few words for the menu, after "OpenCode isn’t available: ".
    public var shortReason: String {
        switch code {
        case "offline": "no network connection"
        case "registry_unavailable": "the agent registry isn’t answering"
        case "unverified_download": "its download has no checksum"
        case "unsupported_platform": "none for this Mac"
        case "check_failed": "it didn’t pass its check"
        case "busy": "another AgentLand host is running"
        default: "AgentLand couldn’t get it"
        }
    }
}

public enum OpenCodeInstallOutcome: Equatable, Sendable {
    /// A valid managed OpenCode `version` is current.
    case ready(version: String)
    case failed(OpenCodeInstallFailure)
}

/// Gets the host's managed OpenCode when a start has none (`install-opencode`).
public protocol OpenCodeInstalling: Sendable {
    /// Runs until the host says OpenCode is ready or why not. `progress` gets each event in order, on a
    /// background queue. Cancelling the task stops the command; it then throws `CancellationError`.
    func install(statePath: String, progress: @escaping @Sendable (OpenCodeInstallEvent) -> Void) async throws -> OpenCodeInstallOutcome
}

/// What a start shows while it gets OpenCode: "Getting OpenCode…" with the version, and the download's
/// share when the host knows its size.
public struct OpenCodeInstallProgress: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case registry, downloading, checking }

    public private(set) var step: Step = .registry
    public private(set) var version: String?
    public private(set) var received: Int64 = 0
    public private(set) var total: Int64?

    public init() {}

    public mutating func apply(_ event: OpenCodeInstallEvent) {
        switch event {
        case .registry:
            step = .registry
        case let .downloading(version, received, total):
            step = .downloading
            self.version = version
            self.received = received
            self.total = total
        case let .checking(version):
            step = .checking
            self.version = version
        case .ready, .failed:
            break
        }
    }

    /// The download's share, 0…1, while the host knows its size.
    public var fraction: Double? {
        guard step == .downloading, let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// "Getting OpenCode…", "Getting OpenCode 1.18.32…", "Checking OpenCode 1.18.32…".
    public var title: String {
        switch step {
        case .registry: "Getting OpenCode…"
        case .downloading: version.map { "Getting OpenCode \($0)…" } ?? "Getting OpenCode…"
        case .checking: version.map { "Checking OpenCode \($0)…" } ?? "Checking OpenCode…"
        }
    }

    /// The menu's line, which cannot hold a bar: the title and the share ("Getting OpenCode 1.18.32… 45%").
    public var menuTitle: String {
        guard let fraction else { return title }
        return "\(title) \(Int((fraction * 100).rounded(.down)))%"
    }
}

/// Why no OpenCode runs while the host does (Settings → AI Providers, the menu, onboarding): AgentLand
/// could not get it, or the versions the host keeps did not start.
public struct OpenCodeUnavailability: Equatable, Sendable {
    /// The reason, in full.
    public let message: String
    /// A few words for the menu, after "OpenCode isn’t available: ".
    public let shortReason: String
    /// The Mac had no network connection when it tried to get OpenCode.
    public let offline: Bool

    public init(message: String, shortReason: String, offline: Bool = false) {
        self.message = message
        self.shortReason = shortReason
        self.offline = offline
    }

    /// `install-opencode` did not make OpenCode ready.
    public init(install failure: OpenCodeInstallFailure) {
        self.init(message: failure.message, shortReason: failure.shortReason, offline: failure.isOffline)
    }

    /// The host has OpenCode, but none that passes the checks started (`ManagedOpenCodeError.unavailable`).
    public init(notStarted reason: String) {
        self.init(message: reason, shortReason: "it didn’t start")
    }
}

/// Runs `agentland-host install-opencode --state <state>` (the host the app bundles) and reads its progress.
/// It is bounded like the other host commands: `timeout` (the host's own download limit is 30 minutes),
/// then SIGTERM and, `terminationGracePeriod` later, SIGKILL; a cancelled task stops it the same way.
public struct HostOpenCodeInstaller: OpenCodeInstalling {
    public static let defaultTimeout: TimeInterval = 40 * 60
    /// A progress line longer than this is not read.
    static let maximumLineBytes = 64 * 1024

    private let binaryURL: URL
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval

    public init(binaryURL: URL = HostBinaryLocator.defaultURL(), timeout: TimeInterval = HostOpenCodeInstaller.defaultTimeout,
                terminationGracePeriod: TimeInterval = 5) {
        self.binaryURL = binaryURL
        self.timeout = max(0.1, timeout)
        self.terminationGracePeriod = max(0.1, terminationGracePeriod)
    }

    public func install(statePath: String, progress: @escaping @Sendable (OpenCodeInstallEvent) -> Void) async throws -> OpenCodeInstallOutcome {
        try Task.checkCancellation()
        let run = InstallRun(binaryURL: binaryURL, arguments: HostCommandBuilder.installOpenCodeCommand(statePath: statePath).arguments,
                             timeout: timeout, grace: terminationGracePeriod, progress: progress)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run.run()) }
            }
        } onCancel: {
            run.cancel()
        }
        guard let outcome else { throw CancellationError() }
        return outcome
    }
}

/// One run of the command: the process, its output and how it ended.
private final class InstallRun: @unchecked Sendable {
    private let binaryURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let grace: TimeInterval
    private let progress: @Sendable (OpenCodeInstallEvent) -> Void
    private let lock = NSLock()
    private var cancelled = false
    /// Set when the command ended but something it started still holds the pipes: the readers stop.
    private var readersStopped = false
    /// The last `ready` or `failed` line.
    private var outcomeEvent: OpenCodeInstallEvent?
    private var diagnostics = Data()

    init(binaryURL: URL, arguments: [String], timeout: TimeInterval, grace: TimeInterval,
         progress: @escaping @Sendable (OpenCodeInstallEvent) -> Void) {
        self.binaryURL = binaryURL
        self.arguments = arguments
        self.timeout = timeout
        self.grace = grace
        self.progress = progress
    }

    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs the command to its end, blocking; nil when it was cancelled.
    func run() -> OpenCodeInstallOutcome? {
        if isCancelled { return nil }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binaryURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return .failed(OpenCodeInstallFailure(code: nil, detail: redact("The AgentLand host could not start: \(error.localizedDescription)")))
        }
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { readers.leave() }
            readLines(stdout.fileHandleForReading)
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { readers.leave() }
            readChunks(stderr.fileHandleForReading) { chunk in
                lock.withLock {
                    diagnostics.append(chunk)
                    if diagnostics.count > 16 * 1024 { diagnostics.removeFirst(diagnostics.count - 16 * 1024) }
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var stopAsked: Date?
        var killed = false
        while process.isRunning {
            let now = Date()
            if stopAsked == nil, isCancelled || now >= deadline {
                timedOut = !isCancelled
                process.terminate()
                stopAsked = now
            }
            if let asked = stopAsked, !killed, now.timeIntervalSince(asked) >= grace {
                kill(process.processIdentifier, SIGKILL)
                killed = true
            }
            if let asked = stopAsked, now.timeIntervalSince(asked) >= grace * 2 + 5 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if readers.wait(timeout: .now() + grace) == .timedOut {
            // Something the host started keeps the pipes open: stop reading them.
            lock.withLock { readersStopped = true }
            _ = readers.wait(timeout: .now() + grace)
        }
        if isCancelled { return nil }
        if timedOut {
            let minutes = Int((timeout / 60).rounded())
            return .failed(OpenCodeInstallFailure(code: nil, detail: minutes >= 1
                ? "Getting OpenCode took longer than \(minutes) minutes, so AgentLand stopped it."
                : "Getting OpenCode took too long, so AgentLand stopped it."))
        }
        let status = process.isRunning ? -1 : process.terminationStatus
        switch lock.withLock({ outcomeEvent }) {
        case let .failed(code, error)?:
            return .failed(OpenCodeInstallFailure(code: code, detail: error))
        case let .ready(version)? where status == 0:
            return .ready(version: version)
        default:
            let words = lock.withLock { String(decoding: diagnostics, as: UTF8.self) }
                .split(whereSeparator: \.isNewline).last.map { OpenCodeInstallEvent.cleaned(String($0), limit: 600) } ?? ""
            let detail = !words.isEmpty ? words
                : status == 0 ? "The host ended without saying OpenCode is ready." : "The host stopped with status \(status)."
            return .failed(OpenCodeInstallFailure(code: nil, detail: redact(detail, limit: 600)))
        }
    }

    /// Reads the progress lines as they come and passes each event on. Download lines are passed on at most
    /// ten times a second; the newest waiting one goes before any other event and at the end.
    private func readLines(_ handle: FileHandle) {
        var buffer = Data()
        var skipping = false
        var waitingDownload: OpenCodeInstallEvent?
        var lastDownload = Date.distantPast
        func deliver(_ event: OpenCodeInstallEvent) {
            if case .downloading = event {
                let now = Date()
                if now.timeIntervalSince(lastDownload) < 0.1 { waitingDownload = event; return }
                lastDownload = now
                waitingDownload = nil
            } else if let waiting = waitingDownload {
                waitingDownload = nil
                progress(waiting)
            }
            switch event {
            case .ready, .failed: lock.withLock { outcomeEvent = event }
            default: break
            }
            progress(event)
        }
        func take(_ line: Data) {
            if let event = OpenCodeInstallEvent.parse(line) { deliver(event) }
        }
        readChunks(handle) { chunk in
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if skipping { skipping = false; continue }
                if line.count > HostOpenCodeInstaller.maximumLineBytes { continue }
                take(Data(line))
            }
            if buffer.count > HostOpenCodeInstaller.maximumLineBytes {
                buffer.removeAll()
                skipping = true
            }
        }
        if !skipping, !buffer.isEmpty { take(buffer) }
        if let waiting = waitingDownload { progress(waiting) }
    }

    /// Passes on what `handle` gives as it comes, until its end or until the readers are stopped. The handle
    /// is never closed under a read: `availableData` would raise then, and `read(upToCount:)` waits for the
    /// whole count on a pipe.
    private func readChunks(_ handle: FileHandle, _ body: (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while !lock.withLock({ readersStopped }) {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; return }
            if ready == 0 { continue }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            if count == 0 { return }
            body(Data(bytes[0..<count]))
        }
    }
}
