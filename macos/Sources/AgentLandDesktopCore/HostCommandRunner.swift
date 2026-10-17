import Foundation
import Darwin

public struct CommandOutput: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32
}

public protocol HostCommandRunning: Sendable {
    func run(_ command: HostCommand) throws -> CommandOutput
}

public final class ProcessCommandRunner: HostCommandRunning, @unchecked Sendable {
    private let binaryURL: URL
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let outputLimit: Int

    public init(
        binaryURL: URL = HostBinaryLocator.defaultURL(),
        timeout: TimeInterval = 30,
        terminationGracePeriod: TimeInterval = 2,
        outputLimit: Int = 64 * 1024
    ) {
        self.binaryURL = binaryURL
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.outputLimit = outputLimit
    }

    public func run(_ command: HostCommand) throws -> CommandOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binaryURL
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw DesktopError.processLaunch(error.localizedDescription)
        }
        let outputCollector = BoundedDataCollector(limit: outputLimit)
        let errorCollector = BoundedDataCollector(limit: outputLimit)
        let readerState = ReaderState()
        let readers = DispatchGroup()
        drain(stdout.fileHandleForReading, into: outputCollector, readers: readers, readerState: readerState)
        drain(stderr.fileHandleForReading, into: errorCollector, readers: readers, readerState: readerState)

        guard waitForExit(process, timeout: timeout) else {
            process.terminate()
            if !waitForExit(process, timeout: terminationGracePeriod) {
                kill(process.processIdentifier, SIGKILL)
                guard waitForExit(process, timeout: terminationGracePeriod) else {
                    throw DesktopError.commandTerminationTimedOut
                }
            }
            try finishDraining(readers, handles: [stdout.fileHandleForReading, stderr.fileHandleForReading], readerState: readerState)
            throw DesktopError.commandTimedOut
        }
        try finishDraining(readers, handles: [stdout.fileHandleForReading, stderr.fileHandleForReading], readerState: readerState)
        let output = String(data: outputCollector.data, encoding: .utf8) ?? ""
        let diagnostics = String(data: errorCollector.data, encoding: .utf8) ?? ""
        let result = CommandOutput(standardOutput: output, standardError: diagnostics, exitCode: process.terminationStatus)
        guard result.exitCode == 0 else {
            throw DesktopError.commandFailed(diagnostics.isEmpty ? output : diagnostics)
        }
        return result
    }

    private func drain(_ handle: FileHandle, into collector: BoundedDataCollector, readers: DispatchGroup, readerState: ReaderState) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            do {
                while let chunk = try handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    collector.append(chunk)
                }
            } catch {
                readerState.record(error)
            }
        }
    }

    private func finishDraining(_ readers: DispatchGroup, handles: [FileHandle], readerState: ReaderState) throws {
        if readers.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
            handles.forEach { $0.closeFile() }
            guard readers.wait(timeout: .now() + terminationGracePeriod) == .success else {
                throw DesktopError.commandReaderTimedOut
            }
        }
        if let error = readerState.error {
            throw DesktopError.commandReadFailed(error.localizedDescription)
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()
    init(limit: Int) { self.limit = max(0, limit) }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - storage.count
        if remaining > 0 { storage.append(data.prefix(remaining)) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class ReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; if storedError == nil { storedError = error } }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
}

public struct HostConfiguration: Sendable, Equatable, Codable {
    public let openCodeURL: String
    public let passwordEnvironment: String
    public let projects: [ProjectConfiguration]

    enum CodingKeys: String, CodingKey {
        case openCodeURL = "openCodeUrl"
        case passwordEnvironment = "passwordEnv"
        case projects
    }
}

public struct ManagedDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let status: String
    public let createdAt: String
    public let name: String
    public let isPresent: Bool
    /// Paired and not revoked.
    public var isActive: Bool { status == "active" }
}

public struct GeneratedCertificate: Sendable, Equatable, Codable {
    public let certificateFile: String
    public let keyFile: String
    public let fingerprint: String
}

public enum HostOutputParser {
    public static func configuration(_ output: String) throws -> HostConfiguration {
        do {
            return try JSONDecoder().decode(HostConfiguration.self, from: Data(output.utf8))
        } catch {
            throw DesktopError.commandFailed("The host returned an unreadable configuration response.")
        }
    }

    public static func devices(_ output: String) -> [ManagedDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 4 || fields.count == 5 else { return nil }
            return ManagedDevice(id: String(fields[0]), status: String(fields[1]), createdAt: String(fields[2]),
                                 name: String(fields[3]), isPresent: fields.count == 5 && fields[1] == "active" && fields[4] == "online")
        }
    }

    public static func generatedCertificate(_ output: String) throws -> GeneratedCertificate {
        do {
            return try JSONDecoder().decode(GeneratedCertificate.self, from: Data(output.utf8))
        } catch {
            throw DesktopError.commandFailed("The host returned an unreadable certificate response.")
        }
    }
}
