import CryptoKit
import Darwin
import Foundation

/// A version in the host's record of the OpenCode it installed and checked, `<state>.agents/opencode/current.json`
/// (docs/AGENT-CATALOG-PLAN.md "Installs", "OpenCode"): the current one, or the one it keeps for going back
/// (`previous`). `args` are the agent's ACP arguments; the Mac app does not use them, since it runs
/// `opencode serve`.
public struct ManagedAgentRecord: Codable, Equatable, Sendable {
    public var version: String
    /// The program: an absolute path, or a path relative to the version's folder
    /// (`opencode/<version>/`) or to the agent's folder (`opencode/`).
    public var command: String
    public var args: [String]?
    public var sha256: String?
    public var installedAt: String?

    public init(version: String, command: String, args: [String]? = nil, sha256: String? = nil, installedAt: String? = nil) {
        self.version = version
        self.command = command
        self.args = args
        self.sha256 = sha256
        self.installedAt = installedAt
    }

    /// The program this record names: its version and its SHA-256, whichever of `current` or `previous`
    /// the host lists it as.
    public var identity: String { "\(version)|\(sha256?.lowercased() ?? "")" }
}

/// `current.json` as the Mac reads it: the current version, and the previous one the host keeps (nil when it
/// keeps none, or when that entry does not decode).
public struct ManagedOpenCodeRecords: Equatable, Sendable {
    public let current: ManagedAgentRecord
    public let previous: ManagedAgentRecord?

    public init(current: ManagedAgentRecord, previous: ManagedAgentRecord? = nil) {
        self.current = current
        self.previous = previous
    }
}

extension ManagedOpenCodeRecords: Decodable {
    private enum CodingKeys: String, CodingKey { case previous }

    public init(from decoder: any Decoder) throws {
        current = try ManagedAgentRecord(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previous = try? container.decodeIfPresent(ManagedAgentRecord.self, forKey: .previous)
    }
}

/// One OpenCode a start can run: the host's current managed one, or the previous version it keeps. Either
/// passed every check.
public struct OpenCodeBinaryChoice: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The host's current OpenCode (`current.json`).
        case managed(ManagedAgentRecord)
        /// The version the host keeps for going back (`current.json`'s `previous`). It runs when the
        /// current one did not start, or cannot be used.
        case previous(ManagedAgentRecord)

        public var record: ManagedAgentRecord {
            switch self {
            case let .managed(record), let .previous(record): record
            }
        }
    }

    public let executableURL: URL
    public let source: Source

    public init(executableURL: URL, source: Source) {
        self.executableURL = executableURL
        self.source = source
    }
}

/// What a start runs: the current version with the previous one to fall back on, the previous version
/// alone, or nothing, and why.
public struct OpenCodeLaunchPlan: Equatable, Sendable {
    /// What the start tries first; nil when no OpenCode passes the checks.
    public let first: OpenCodeBinaryChoice?
    /// The previous version, tried when `first` is the current one and it does not start.
    public let fallback: OpenCodeBinaryChoice?
    /// Why the current version is not tried: it did not start last time, or it fails the checks. Nil when
    /// `first` is the current one.
    public let why: String?

    public init(first: OpenCodeBinaryChoice?, fallback: OpenCodeBinaryChoice?, why: String?) {
        self.first = first
        self.fallback = fallback
        self.why = why
    }
}

/// The host's OpenCode after every check: the program to run and its record.
public struct ManagedOpenCodeExecutable: Equatable, Sendable {
    public let executable: URL
    public let record: ManagedAgentRecord
}

/// Why a version of the host's OpenCode is not used. `notInstalled` is the usual case until the host installs one.
public enum ManagedOpenCodeRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case notInstalled
    case unreadableRecord
    case invalidRecord(String)
    case missingExecutable
    case outsideFolder
    /// A folder on the way (relative to the agents folder) is a link, belongs to someone else, or
    /// other users can open it.
    case notPrivate(String)
    case notExecutable
    case tooLarge
    case checksumMismatch

    public var description: String {
        switch self {
        case .notInstalled: "The host has not installed OpenCode."
        case .unreadableRecord: "The host's OpenCode record (current.json) could not be read."
        case let .invalidRecord(detail): "The host's OpenCode record is not valid: \(detail)."
        case .missingExecutable: "The host's OpenCode is missing from its folder."
        case .outsideFolder: "The host's OpenCode record points outside its folder."
        case let .notPrivate(path): "The folder \(path) is not private to this user (it must be 0700 and yours, not a link)."
        case .notExecutable: "The host's OpenCode is not a program that only this user can change."
        case .tooLarge: "The host's OpenCode is larger than 1 GiB."
        case .checksumMismatch: "The host's OpenCode does not match the SHA-256 in its record."
        }
    }
}

/// Chooses the OpenCode each start runs (docs/AGENT-CATALOG-PLAN.md "OpenCode"): the host's managed one from
/// `<agents>/opencode/current.json`, or the previous version the record keeps, each only when all of these
/// hold. The app bundles no OpenCode; with neither, no OpenCode runs.
///
/// - The record is a regular file of this user's, at most 64 KiB, that other users cannot change. The
///   version run has a version that is one folder name, a command and a 64-digit hex `sha256` (the host
///   records it for every OpenCode it installs, so a version without one is refused).
/// - The command resolves (links followed) to a regular file inside `<agents>/opencode`, owned by
///   this user, executable, and not writable by group or others. A link that leads out is refused.
/// - The agents folder, `opencode/` and every folder down to the program are real folders of this
///   user's with mode 0700 (no group or other bits), as the host makes them.
/// - The program's SHA-256 matches the version's `sha256`.
public struct OpenCodeBinaryLocator: Sendable {
    public static let maximumExecutableBytes: Int64 = 1 << 30
    static let maximumRecordBytes = 64 * 1024

    /// `<state>.agents` (`HostCommandBuilder.agentsFolderPath(statePath:)`); nil when the state path gives none.
    public let agentsFolder: URL?

    public init(agentsFolder: URL?) {
        self.agentsFolder = agentsFolder
    }

    /// What a start runs now. `failed` is a version that did not start while the previous one then did; it
    /// is not run, as the current version or as the previous one, while the host keeps it.
    public func plan(skipping failed: ManagedAgentRecord? = nil) -> OpenCodeLaunchPlan {
        let records: ManagedOpenCodeRecords
        switch self.records() {
        case let .success(found): records = found
        case let .failure(rejection): return OpenCodeLaunchPlan(first: nil, fallback: nil, why: rejection.description)
        }
        let previous = records.previous.flatMap { record -> OpenCodeBinaryChoice? in
            guard record != failed, case let .success(found) = executable(for: record) else { return nil }
            return OpenCodeBinaryChoice(executableURL: found.executable, source: .previous(found.record))
        }
        let why: String
        switch executable(for: records.current) {
        case let .success(found) where found.record == failed:
            why = "OpenCode \(found.record.version) didn’t start last time."
        case let .success(found):
            return OpenCodeLaunchPlan(first: OpenCodeBinaryChoice(executableURL: found.executable, source: .managed(found.record)),
                                      fallback: previous, why: nil)
        case let .failure(rejection):
            why = rejection.description
        }
        return OpenCodeLaunchPlan(first: previous, fallback: nil, why: why)
    }

    /// The host's current OpenCode after every check, or why it cannot be used.
    public func managedExecutable() -> Result<ManagedOpenCodeExecutable, ManagedOpenCodeRejection> {
        records().flatMap { executable(for: $0.current) }
    }

    /// The previous version the host keeps, after the same checks; `.notInstalled` when it keeps none.
    public func previousExecutable() -> Result<ManagedOpenCodeExecutable, ManagedOpenCodeRejection> {
        records().flatMap { found in found.previous.map(executable(for:)) ?? .failure(.notInstalled) }
    }

    /// `current.json`, read only when it and the folders above it are the host's own.
    public func records() -> Result<ManagedOpenCodeRecords, ManagedOpenCodeRejection> {
        guard let agentsFolder else { return .failure(.notInstalled) }
        let agents = agentsFolder.standardizedFileURL.path
        let folder = agents + "/opencode"
        let recordPath = folder + "/current.json"
        guard let recordInfo = Self.status(recordPath) else {
            return .failure(errno == ENOENT || errno == ENOTDIR ? .notInstalled : .unreadableRecord)
        }
        let agentsName = (agents as NSString).lastPathComponent
        guard Self.isPrivateFolder(agents) else { return .failure(.notPrivate(agentsName)) }
        guard Self.isPrivateFolder(folder) else { return .failure(.notPrivate(agentsName + "/opencode")) }
        guard Self.isType(recordInfo, S_IFREG), recordInfo.st_uid == getuid(), recordInfo.st_mode & 0o022 == 0 else {
            return .failure(.invalidRecord("it is not a file that only this user can change"))
        }
        guard recordInfo.st_size <= Self.maximumRecordBytes,
              let data = Self.read(recordPath, matching: recordInfo, limit: Self.maximumRecordBytes) else {
            return .failure(.unreadableRecord)
        }
        do { return .success(try JSONDecoder().decode(ManagedOpenCodeRecords.self, from: data)) }
        catch { return .failure(.invalidRecord("it is not the expected JSON")) }
    }

    /// `record`'s program after every check: the program to run, or why it cannot be.
    public func executable(for record: ManagedAgentRecord) -> Result<ManagedOpenCodeExecutable, ManagedOpenCodeRejection> {
        guard let agentsFolder else { return .failure(.notInstalled) }
        if let problem = Self.problem(with: record) { return .failure(.invalidRecord(problem)) }
        let agents = agentsFolder.standardizedFileURL.path
        let folder = agents + "/opencode"
        let agentsName = (agents as NSString).lastPathComponent
        guard Self.isPrivateFolder(agents) else { return .failure(.notPrivate(agentsName)) }
        guard Self.isPrivateFolder(folder) else { return .failure(.notPrivate(agentsName + "/opencode")) }

        let candidates = record.command.hasPrefix("/")
            ? [record.command]
            : [folder + "/" + record.version + "/" + record.command, folder + "/" + record.command]
        guard let command = candidates.first(where: { Self.status($0) != nil }),
              let resolved = Self.canonicalPath(command), let root = Self.canonicalPath(folder) else {
            return .failure(.missingExecutable)
        }
        guard resolved.hasPrefix(root + "/") else { return .failure(.outsideFolder) }
        // Every folder between `opencode/` and the program is the host's own.
        var current = root
        var relative = agentsName + "/opencode"
        for component in resolved.dropFirst(root.count + 1).split(separator: "/").dropLast() {
            current += "/" + component
            relative += "/" + component
            guard Self.isPrivateFolder(current) else { return .failure(.notPrivate(relative)) }
        }
        guard let info = Self.status(resolved), Self.isType(info, S_IFREG), info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_mode & 0o100 != 0 else {
            return .failure(.notExecutable)
        }
        guard Int64(info.st_size) <= Self.maximumExecutableBytes else { return .failure(.tooLarge) }
        // `problem(with:)` refused a record without one.
        guard let expected = record.sha256, let digest = Self.sha256(of: resolved, matching: info),
              digest == expected.lowercased() else {
            return .failure(.checksumMismatch)
        }
        return .success(ManagedOpenCodeExecutable(executable: URL(fileURLWithPath: resolved), record: record))
    }

    // MARK: Checks

    /// What is wrong with the record's fields, or nil.
    static func problem(with record: ManagedAgentRecord) -> String? {
        func hasControl(_ value: String) -> Bool {
            value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        let version = record.version
        guard (1...128).contains(version.utf8.count), version != ".", version != "..", !version.contains("/"),
              !hasControl(version) else { return "its version is not a folder name" }
        guard (1...4096).contains(record.command.utf8.count), !hasControl(record.command) else {
            return "it has no usable command"
        }
        guard let digest = record.sha256 else { return "it has no sha256" }
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            return "its sha256 is not 64 hex digits"
        }
        return nil
    }

    /// `lstat`: never follows the last component.
    static func status(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    static func isType(_ info: stat, _ type: mode_t) -> Bool { info.st_mode & S_IFMT == type }

    /// A real folder (not a link) of this user's that no one else can open.
    static func isPrivateFolder(_ path: String) -> Bool {
        guard let info = status(path) else { return false }
        return isType(info, S_IFDIR) && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The file at `path`, only if it is still the file `info` describes, at most `limit` bytes.
    static func read(_ path: String, matching info: stat, limit: Int) -> Data? {
        var result = Data()
        let complete = withOpenFile(path, matching: info) { descriptor in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; return false }
                if count == 0 { return true }
                result.append(contentsOf: buffer[0..<count])
                if result.count > limit { return false }
            }
        }
        return complete == true ? result : nil
    }

    /// The SHA-256 of the file at `path` in lowercase hex, only if it is still the file `info` describes.
    static func sha256(of path: String, matching info: stat) -> String? {
        var hasher = SHA256()
        let complete = withOpenFile(path, matching: info) { descriptor in
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var total: Int64 = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; return false }
                if count == 0 { return true }
                total += Int64(count)
                if total > maximumExecutableBytes { return false }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            }
        }
        guard complete == true else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func withOpenFile(_ path: String, matching info: stat, _ body: (Int32) -> Bool) -> Bool? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { return nil }
        return body(descriptor)
    }
}
