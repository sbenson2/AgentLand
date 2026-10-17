import Foundation
import Darwin

public enum HostStatus: Sendable, Equatable {
    case stopped
    case starting
    case running
}

public protocol HostProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func launch() throws
    func terminate()
    func forceTerminate()
    func waitForExit(timeout: TimeInterval) -> Bool
}

public actor HostLifecycle {
    public typealias ProcessFactory = @Sendable (HostCommand) -> any HostProcess

    private let processFactory: ProcessFactory
    private var ownedProcess: (any HostProcess)?
    public private(set) var currentStatus: HostStatus = .stopped

    /// The default runs the bundled host, its output in `~/Library/Logs/AgentLand/host.log` with the command's
    /// environment (the service password and session token) redacted.
    public init(processFactory: @escaping ProcessFactory = { command in
        ProcessHostProcess(command: command, log: ChildProcessLog(name: "host", secrets: Array(command.environment.values)))
    }) {
        self.processFactory = processFactory
    }

    public func start(_ command: HostCommand) throws {
        guard ownedProcess == nil else { return }
        currentStatus = .starting
        let process = processFactory(command)
        do {
            try process.launch()
            ownedProcess = process
            currentStatus = process.isRunning ? .running : .stopped
        } catch {
            currentStatus = .stopped
            throw DesktopError.processLaunch(error.localizedDescription)
        }
    }

    public func stop(terminationGracePeriod: TimeInterval = 2) async throws {
        guard let process = ownedProcess else { return }
        process.terminate()
        if !process.waitForExit(timeout: terminationGracePeriod) {
            process.forceTerminate()
            guard process.waitForExit(timeout: terminationGracePeriod) else {
                currentStatus = .running
                throw DesktopError.hostStopTimedOut
            }
        }
        ownedProcess = nil
        currentStatus = .stopped
    }

    public func refreshStatus() {
        if let ownedProcess, !ownedProcess.isRunning {
            self.ownedProcess = nil
            currentStatus = .stopped
        }
    }
}

public final class ProcessHostProcess: HostProcess, @unchecked Sendable {
    private let process = Process()
    private let log: ChildProcessLog?
    private let output: Pipe?

    /// With `log`, the host's output (stdout and stderr) goes there; without, nowhere.
    public init(command: HostCommand, executableURL: URL = HostBinaryLocator.defaultURL(), log: ChildProcessLog? = nil) {
        self.log = log
        process.executableURL = executableURL
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        if log != nil {
            let pipe = Pipe()
            output = pipe
            process.standardOutput = pipe
            process.standardError = pipe
        } else {
            output = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
    }

    public var isRunning: Bool { process.isRunning }
    public func launch() throws {
        try process.run()
        if let log, let output {
            log.started("agentland-host", pid: process.processIdentifier)
            log.drain(output.fileHandleForReading)
        }
    }
    public func terminate() { if process.isRunning { process.terminate() } }
    public func forceTerminate() { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    public func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }
}

public enum HostBinaryLocator {
    public static func defaultURL(bundle: Bundle = .main) -> URL {
        if let executable = bundle.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("agentland-host")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        if let bundled = bundle.url(forResource: "agentland-host", withExtension: nil) { return bundled }
        return URL(fileURLWithPath: "/usr/local/bin/agentland-host")
    }
}

public enum DesktopError: LocalizedError, Equatable {
    case processLaunch(String)
    case commandFailed(String)
    case commandTimedOut
    case commandTerminationTimedOut
    case commandReaderTimedOut
    case commandReadFailed(String)
    case hostStopTimedOut
    case secretUnavailable

    public var errorDescription: String? {
        switch self {
        case let .processLaunch(message): "The host could not start: \(redact(message))"
        case let .commandFailed(message): "The host command failed: \(redact(message))"
        case .commandTimedOut: "The host command exceeded its time limit and was stopped."
        case .commandTerminationTimedOut: "The host command could not be stopped after a bounded shutdown attempt."
        case .commandReaderTimedOut: "The host command output stream did not close after a bounded wait."
        case let .commandReadFailed(message): "The host command output could not be read: \(redact(message))"
        case .hostStopTimedOut: "The host did not stop after a bounded shutdown attempt."
        case .secretUnavailable: "Set the OpenCode password before starting the host."
        }
    }
}

public func redact(_ message: String, limit: Int = 500) -> String {
    let normalized = message.replacingOccurrences(of: "(?i)(password|token|secret)\\s*[=:]\\s*[^\\s,]+", with: "$1=[redacted]", options: .regularExpression)
    let bounded = String(normalized.prefix(limit))
    return bounded.isEmpty ? "No diagnostic was provided." : bounded
}
