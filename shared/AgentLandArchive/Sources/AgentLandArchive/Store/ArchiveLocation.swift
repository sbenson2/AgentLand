import CryptoKit
import Foundation
import AgentLandCore

/// Where one host's files live on this device. Each paired host (host address
/// and device credential, the key `WorkspacePersistence` stores tabs under)
/// gets its own folder, named by a hash of that key.
public struct ArchiveLocation: Hashable, Sendable {
    /// `ConnectionIdentity.storageKey` of the host.
    public let hostKey: String
    /// The host's folder. It holds this host's files and nothing else.
    public let directory: URL

    public init(hostKey: String, directory: URL) {
        self.hostKey = hostKey
        self.directory = directory
    }

    public var databaseURL: URL { directory.appending(path: "archive.sqlite", directoryHint: .notDirectory) }

    /// Application Support/<bundle id>/Archive/<hash of the host key>.
    public static func archive(for identity: ConnectionIdentity) throws -> ArchiveLocation {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return archive(hostKey: identity.storageKey, root: root.appending(path: appFolder, directoryHint: .isDirectory))
    }

    /// Caches/<bundle id>/TerminalLogs/<hash of the host key>: purgeable by the system.
    public static func terminalLogCache(for identity: ConnectionIdentity) throws -> ArchiveLocation {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return terminalLogCache(hostKey: identity.storageKey, root: root.appending(path: appFolder, directoryHint: .isDirectory))
    }

    /// Caches/<bundle id>/Attachments/<hash of the host key>: purgeable by the system.
    public static func attachmentCache(for identity: ConnectionIdentity) throws -> ArchiveLocation {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return attachmentCache(hostKey: identity.storageKey, root: root.appending(path: appFolder, directoryHint: .isDirectory))
    }

    static func attachmentCache(hostKey: String, root: URL) -> ArchiveLocation {
        ArchiveLocation(hostKey: hostKey, directory: root.appending(path: "Attachments", directoryHint: .isDirectory)
            .appending(path: folderName(for: hostKey), directoryHint: .isDirectory))
    }

    static func archive(hostKey: String, root: URL) -> ArchiveLocation {
        ArchiveLocation(hostKey: hostKey, directory: root.appending(path: "Archive", directoryHint: .isDirectory)
            .appending(path: folderName(for: hostKey), directoryHint: .isDirectory))
    }

    static func terminalLogCache(hostKey: String, root: URL) -> ArchiveLocation {
        ArchiveLocation(hostKey: hostKey, directory: root.appending(path: "TerminalLogs", directoryHint: .isDirectory)
            .appending(path: folderName(for: hostKey), directoryHint: .isDirectory))
    }

    /// Deletes everything this device keeps of `identity`'s host: its archive's database folder, and its
    /// terminal-log and attachment caches. Close the store and stop its engine first. Folders that are
    /// not there are skipped; the first other failure is thrown after every folder was tried.
    public static func removeDeviceCopy(for identity: ConnectionIdentity) throws {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        try removeDeviceCopy(hostKey: identity.storageKey,
                             supportRoot: support.appending(path: appFolder, directoryHint: .isDirectory),
                             cachesRoot: caches.appending(path: appFolder, directoryHint: .isDirectory))
    }

    static func removeDeviceCopy(hostKey: String, supportRoot: URL, cachesRoot: URL) throws {
        let folders = [archive(hostKey: hostKey, root: supportRoot), terminalLogCache(hostKey: hostKey, root: cachesRoot),
                       attachmentCache(hostKey: hostKey, root: cachesRoot)].map(\.directory)
        var failure: (any Error)?
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// A SHA-256 of the key, so folder names say nothing about the host.
    static func folderName(for hostKey: String) -> String {
        SHA256.hash(data: Data(hostKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static var appFolder: String { Bundle.main.bundleIdentifier ?? "dev.agentland" }

    /// Creates the folder, protected until the device is first unlocked
    /// (iOS) and excluded from backups: it mirrors the host, which keeps the
    /// original.
    func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.protect(directory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
    }

    /// New files inherit their folder's class; existing ones get it explicitly.
    static func protect(_ url: URL) throws {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }

    /// Whether backups skip the folder.
    var isExcludedFromBackup: Bool {
        (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}
