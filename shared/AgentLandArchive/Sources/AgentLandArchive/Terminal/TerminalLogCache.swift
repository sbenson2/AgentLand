import CryptoKit
import Foundation
import AgentLandCore

/// Reads terminal log ranges from the host: `GET /v1/archive/terminal-log`.
public protocol TerminalLogFetching: Sendable {
    func archiveTerminalLog(id: String, offset: Int64, length: Int, format: ArchiveTerminalLogFormat) async throws -> ArchiveTerminalLogRange
}

extension APIClient: TerminalLogFetching {}

/// One range of a terminal log as the viewer uses it.
public struct TerminalLogChunk: Equatable, Sendable {
    public var data: Data
    public var offset: Int64
    /// The raw offset after this range (for text, what the text covers).
    public var next: Int64
    public var eof: Bool
    public var size: Int64
    public var status: String
    /// Served from this device without asking the host.
    public var fromCache: Bool

    public init(data: Data, offset: Int64, next: Int64, eof: Bool, size: Int64, status: String, fromCache: Bool = false) {
        self.data = data; self.offset = offset; self.next = next; self.eof = eof; self.size = size; self.status = status
        self.fromCache = fromCache
    }
}

public enum TerminalLogCacheError: Error, Equatable, LocalizedError {
    /// The range is not on this device and there is no host to ask.
    case notSaved

    public var errorDescription: String? {
        switch self {
        case .notSaved: "This part of the log isn’t saved on this device. Connect to your Mac to load it."
        }
    }
}

/// Terminal log ranges kept on disk, per host, least recently used first out
/// once they pass `capacity` (256 MiB). Ranges are fetched only when a viewer
/// asks for them. A range is kept only once it can no longer change: the
/// terminal has ended, or it is a full raw range.
public actor TerminalLogCache {
    public static let defaultCapacity: Int64 = 256 << 20

    public nonisolated let directory: URL
    public nonisolated let capacity: Int64
    /// The range size requested from the host (at most 1 MiB).
    public nonisolated let chunkLength: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<ArchiveTerminalLogRange, Error>] = [:]
    public private(set) var usedBytes: Int64 = 0

    private struct Entry {
        var size: Int64
        var lastUsed: Date
    }

    private struct Header: Codable {
        let offset: Int64
        let next: Int64
        let eof: Bool
        let size: Int64
        let status: String
    }

    /// The cache for one paired host, in Caches (the system may purge it).
    public static func open(for identity: ConnectionIdentity) throws -> TerminalLogCache {
        try TerminalLogCache(location: ArchiveLocation.terminalLogCache(for: identity))
    }

    public init(location: ArchiveLocation, capacity: Int64 = TerminalLogCache.defaultCapacity,
                chunkLength: Int = ArchiveTerminalLogRange.maxLength, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try location.prepare()
        directory = location.directory
        self.capacity = max(capacity, 1)
        self.chunkLength = min(max(chunkLength, 1), ArchiveTerminalLogRange.maxLength)
        self.now = now
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for file in files where file.pathExtension == "chunk" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            entries[file.deletingPathExtension().lastPathComponent] = Entry(size: size, lastUsed: values?.contentModificationDate ?? .distantPast)
            usedBytes += size
        }
    }

    /// The range of `log` starting at `offset`, from this device when saved,
    /// otherwise from the host (`fetcher`), then saved when it can no longer change.
    public func chunk(of log: ArchivedTerminalLog, at offset: Int64, format: ArchiveTerminalLogFormat,
                      fetcher: (any TerminalLogFetching)?) async throws -> TerminalLogChunk {
        let key = Self.key(log: log, offset: offset, format: format, length: chunkLength)
        if let saved = read(key) {
            touch(key)
            return saved
        }
        let task: Task<ArchiveTerminalLogRange, Error>
        if let running = inFlight[key] {
            task = running
        } else {
            guard let fetcher else { throw TerminalLogCacheError.notSaved }
            let length = chunkLength
            task = Task { try await fetcher.archiveTerminalLog(id: log.id, offset: offset, length: length, format: format) }
            inFlight[key] = task
        }
        let range: ArchiveTerminalLogRange
        do {
            range = try await task.value
            inFlight[key] = nil
        } catch {
            inFlight[key] = nil
            throw error
        }
        let chunk = TerminalLogChunk(data: range.data, offset: range.offset, next: range.next, eof: range.eof, size: range.size, status: range.status)
        let settled = range.status != "running" || (format == .raw && range.data.count == chunkLength)
        if settled, entries[key] == nil { save(chunk, key: key) }
        return chunk
    }

    /// Whether a range is saved on this device.
    public func contains(_ log: ArchivedTerminalLog, at offset: Int64, format: ArchiveTerminalLogFormat) -> Bool {
        entries[Self.key(log: log, offset: offset, format: format, length: chunkLength)] != nil
    }

    /// Drops every saved range of a log (after it was deleted).
    public func remove(_ log: ArchivedTerminalLog) {
        let prefix = Self.logPrefix(log)
        for key in entries.keys where key.hasPrefix(prefix) { evict(key) }
    }

    public func removeAll() {
        for key in Array(entries.keys) { evict(key) }
    }

    // MARK: Files

    private func url(_ key: String) -> URL { directory.appending(path: key + ".chunk", directoryHint: .notDirectory) }

    private func read(_ key: String) -> TerminalLogChunk? {
        guard entries[key] != nil else { return nil }
        guard let file = try? Data(contentsOf: url(key)), file.count >= 4 else {
            evict(key)
            return nil
        }
        let length = Int(file.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard file.count >= 4 + length,
              let header = try? JSONDecoder().decode(Header.self, from: file.subdata(in: 4..<(4 + length))) else {
            evict(key)
            return nil
        }
        return TerminalLogChunk(data: file.subdata(in: (4 + length)..<file.count), offset: header.offset, next: header.next, eof: header.eof,
                                size: header.size, status: header.status, fromCache: true)
    }

    private func save(_ chunk: TerminalLogChunk, key: String) {
        guard let header = try? JSONEncoder().encode(Header(offset: chunk.offset, next: chunk.next, eof: chunk.eof, size: chunk.size, status: chunk.status)) else { return }
        var file = Data()
        let length = UInt32(header.count)
        file.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        file.append(header)
        file.append(chunk.data)
        let size = Int64(file.count)
        guard size <= capacity else { return }
        do {
            try file.write(to: url(key), options: .atomic)
        } catch {
            return
        }
        let used = now()
        try? FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: url(key).path)
        entries[key] = Entry(size: size, lastUsed: used)
        usedBytes += size
        while usedBytes > capacity, let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            evict(oldest)
        }
    }

    private func touch(_ key: String) {
        let used = now()
        entries[key]?.lastUsed = used
        try? FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: url(key).path)
    }

    private func evict(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        usedBytes -= entry.size
        try? FileManager.default.removeItem(at: url(key))
    }

    /// Hashed names: a log's ranges share a prefix, so they can be dropped together.
    static func key(log: ArchivedTerminalLog, offset: Int64, format: ArchiveTerminalLogFormat, length: Int) -> String {
        logPrefix(log) + "-" + hash("\(format.rawValue)\u{1F}\(offset)\u{1F}\(length)")
    }

    private static func logPrefix(_ log: ArchivedTerminalLog) -> String {
        hash(log.id + "\u{1F}" + String(ArchiveTime.milliseconds(log.startedAt)))
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
