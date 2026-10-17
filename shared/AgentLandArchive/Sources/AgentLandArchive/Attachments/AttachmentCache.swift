import CoreTransferable
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import AgentLandCore

/// Reads an archived attachment's bytes from the host: `GET /v1/archive/blob`.
public protocol AttachmentFetching: Sendable {
    func archiveAttachment(chatID: String, messageID: String, name: String, sha256: String?) async throws -> Data
}

extension APIClient: AttachmentFetching {}

public enum AttachmentCacheError: Error, Equatable, LocalizedError {
    /// The file is not on this device and there is no host to ask.
    case notSaved
    /// The host kept only the file's name (its capture was paused, or it came
    /// from an OpenCode backfill).
    case notArchived

    public var errorDescription: String? {
        switch self {
        case .notSaved: "This file isn’t saved on this device. Connect to your Mac to open it."
        case .notArchived: "Your Mac kept only this file’s name, not its contents."
        }
    }
}

/// Attachment files fetched from the host when someone opens one, kept per
/// host in Caches (the system may purge it) and dropped least recently used
/// first once they pass `capacity` (256 MiB). Each file keeps its own name,
/// so Quick Look and the share sheet show it. The archive itself keeps only
/// attachment names; this cache is separate from the terminal log cache.
public actor AttachmentCache {
    public static let defaultCapacity: Int64 = 256 << 20

    public nonisolated let directory: URL
    public nonisolated let capacity: Int64
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    public private(set) var usedBytes: Int64 = 0

    private struct Entry {
        var file: URL
        var size: Int64
        var lastUsed: Date
    }

    /// The cache for one paired host.
    public static func open(for identity: ConnectionIdentity) throws -> AttachmentCache {
        try AttachmentCache(location: ArchiveLocation.attachmentCache(for: identity))
    }

    public init(location: ArchiveLocation, capacity: Int64 = AttachmentCache.defaultCapacity,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        try location.prepare()
        directory = location.directory
        self.capacity = max(capacity, 1)
        self.now = now
        // Each entry is a folder named by its key, holding the one file.
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for folder in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            guard files.count == 1, let file = files.first, let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                // A write cut short, or something that is not an entry.
                try? manager.removeItem(at: folder)
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            // Under the same folder URL as new entries (not a resolved path).
            let saved = directory.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
                .appending(path: file.lastPathComponent, directoryHint: .notDirectory)
            entries[folder.lastPathComponent] = Entry(file: saved, size: size, lastUsed: values.contentModificationDate ?? .distantPast)
            usedBytes += size
        }
    }

    /// The attachment's file on this device, fetched from the host first when
    /// it is not saved yet.
    public func file(for attachment: AttachmentRecord, chatID: String, messageID: String,
                     fetcher: (any AttachmentFetching)?) async throws -> URL {
        let key = Self.key(attachment, chatID: chatID, messageID: messageID)
        if let saved = savedFile(key) { return saved }
        let task: Task<Data, Error>
        if let running = inFlight[key] {
            task = running
        } else {
            guard let fetcher else { throw AttachmentCacheError.notSaved }
            let name = attachment.name, sha256 = attachment.sha256
            task = Task { try await fetcher.archiveAttachment(chatID: chatID, messageID: messageID, name: name, sha256: sha256) }
            inFlight[key] = task
        }
        let data: Data
        do {
            data = try await task.value
            inFlight[key] = nil
        } catch let ClientError.server(code, _) where code == "attachment_not_archived" {
            inFlight[key] = nil
            throw AttachmentCacheError.notArchived
        } catch {
            inFlight[key] = nil
            throw error
        }
        // Someone who asked at the same time may have saved it already.
        if let saved = savedFile(key) { return saved }
        return try save(data, name: attachment.name, key: key)
    }

    /// Whether the attachment is saved on this device.
    public func contains(_ attachment: AttachmentRecord, chatID: String, messageID: String) -> Bool {
        entries[Self.key(attachment, chatID: chatID, messageID: messageID)] != nil
    }

    /// Drops every saved file of a chat (after it was deleted).
    public func remove(chatID: String) {
        let prefix = Self.chatPrefix(chatID)
        for key in entries.keys where key.hasPrefix(prefix) { evict(key) }
    }

    public func removeAll() {
        for key in Array(entries.keys) { evict(key) }
    }

    // MARK: Files

    private func savedFile(_ key: String) -> URL? {
        guard let entry = entries[key] else { return nil }
        guard FileManager.default.fileExists(atPath: entry.file.path) else {
            evict(key)
            return nil
        }
        let used = now()
        entries[key]?.lastUsed = used
        try? FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: entry.file.path)
        return entry.file
    }

    private func save(_ data: Data, name: String, key: String) throws -> URL {
        let manager = FileManager.default
        let folder = directory.appending(path: key, directoryHint: .isDirectory)
        let file = folder.appending(path: Self.fileName(name), directoryHint: .notDirectory)
        try? manager.removeItem(at: folder)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try ArchiveLocation.protect(file)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        let used = now()
        try? manager.setAttributes([.modificationDate: used], ofItemAtPath: file.path)
        let size = Int64(data.count)
        entries[key] = Entry(file: file, size: size, lastUsed: used)
        usedBytes += size
        while usedBytes > capacity, let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            evict(oldest)
        }
        return file
    }

    private func evict(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        usedBytes -= entry.size
        try? FileManager.default.removeItem(at: entry.file.deletingLastPathComponent())
    }

    /// Hashed names: a chat's files share a prefix, so they can be dropped together.
    static func key(_ attachment: AttachmentRecord, chatID: String, messageID: String) -> String {
        chatPrefix(chatID) + "-" + hash([messageID, attachment.name, attachment.sha256 ?? ""].joined(separator: "\u{1F}"))
    }

    private static func chatPrefix(_ chatID: String) -> String { hash(chatID) }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The attachment's name as a file name: no folders, no leading dot, at
    /// most 120 characters with its extension kept.
    static func fileName(_ name: String) -> String {
        var cleaned = String(name.map { character -> Character in
            character == "/" || character == ":" || character == "\\" || character.isNewline || character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
                ? "-" : character
        }).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 16 ? 120 : 119 - ext.count
            cleaned = String(cleaned.prefix(keep)) + (ext.isEmpty || ext.count > 16 ? "" : "." + ext)
        }
        return cleaned.isEmpty ? "Attachment" : cleaned
    }
}

/// An archived attachment for the share sheet: its file from this device, or
/// fetched from the host when it is not saved yet.
public struct ArchivedAttachmentFile: Transferable, Sendable {
    public let attachment: AttachmentRecord
    public let chatID: String
    public let messageID: String
    private let cache: AttachmentCache
    private let fetcher: (any AttachmentFetching)?

    public init(attachment: AttachmentRecord, chatID: String, messageID: String, cache: AttachmentCache, fetcher: (any AttachmentFetching)?) {
        self.attachment = attachment
        self.chatID = chatID
        self.messageID = messageID
        self.cache = cache
        self.fetcher = fetcher
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(try await file.cache.file(for: file.attachment, chatID: file.chatID, messageID: file.messageID, fetcher: file.fetcher))
        }
    }
}
