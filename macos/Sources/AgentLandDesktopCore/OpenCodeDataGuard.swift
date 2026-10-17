import Foundation

/// Keeps OpenCode's data safe across the host's managed versions. Every version runs with the same data
/// folder, the isolated XDG data folder the runtime gives OpenCode (`<storage>/data`). A newer OpenCode may
/// migrate it on its first start; when that version then does not start and the previous one runs instead,
/// the previous one gets the data as it was before.
///
/// - Before the first start of a version that has never started on this Mac, the data folder is cloned into
///   `opencode-data-before-<version>` (on APFS a clone shares the blocks until a file changes). An existing
///   snapshot of that version is kept: it is older than anything the version's earlier attempts changed.
/// - When that version does not start and the previous one will, the data folder moves aside to
///   `opencode-data-after-failed-<version>` and the snapshot moves back into place.
/// - The newest 2 of each kind are kept, in the order `opencode-versions.json` records them, never by
///   modification time. It also records the versions that started.
public struct OpenCodeDataGuard: Sendable {
    public static let keptCopies = 2
    static let keptStartedVersions = 64
    static let maximumLedgerBytes = 256 * 1024

    public let storageRoot: URL

    public init(storageRoot: URL) { self.storageRoot = storageRoot }

    public var dataFolder: URL { storageRoot.appendingPathComponent("data", isDirectory: true) }
    public func snapshotFolder(_ version: String) -> URL {
        storageRoot.appendingPathComponent("opencode-data-before-\(version)", isDirectory: true)
    }
    public func afterFailedFolder(_ version: String) -> URL {
        storageRoot.appendingPathComponent("opencode-data-after-failed-\(version)", isDirectory: true)
    }
    var ledgerURL: URL { storageRoot.appendingPathComponent("opencode-versions.json") }

    /// What the guard recorded, in order.
    struct Ledger: Codable, Equatable {
        var started: [String] = []
        var snapshots: [String] = []
        var afterFailed: [String] = []
    }

    public func hasStarted(_ version: String) -> Bool { readLedger().started.contains(version) }

    /// Before a start of `version`: when it has never started on this Mac, clones the data folder into its
    /// snapshot, unless one is there already. Returns whether a snapshot of it exists afterwards.
    @discardableResult
    public func snapshotBeforeFirstStart(of version: String) -> Bool {
        guard Self.isFolderName(version) else { return false }
        var ledger = readLedger()
        guard !ledger.started.contains(version) else { return false }
        let snapshot = snapshotFolder(version)
        if Self.isFolder(snapshot) {
            if !ledger.snapshots.contains(version) {
                ledger.snapshots.append(version)
                trim(&ledger.snapshots, folder: snapshotFolder)
                writeLedger(ledger)
            }
            return true
        }
        guard Self.isFolder(dataFolder) else { return false }
        // Recorded before the copy, so a copy the app never finished is trimmed like the others.
        ledger.snapshots.removeAll { $0 == version }
        ledger.snapshots.append(version)
        writeLedger(ledger)
        do {
            try FileManager.default.copyItem(at: dataFolder, to: snapshot)
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            ledger.snapshots.removeAll { $0 == version }
            writeLedger(ledger)
            return false
        }
        trim(&ledger.snapshots, folder: snapshotFolder)
        writeLedger(ledger)
        return true
    }

    /// After `version` started and answered: it never needs its data put back.
    public func noteStarted(_ version: String) {
        guard Self.isFolderName(version) else { return }
        var ledger = readLedger()
        guard !ledger.started.contains(version) else { return }
        ledger.started.append(version)
        if ledger.started.count > Self.keptStartedVersions {
            ledger.started.removeFirst(ledger.started.count - Self.keptStartedVersions)
        }
        writeLedger(ledger)
    }

    /// `version` did not start and the previous version starts next: when `version` never started here and
    /// its snapshot exists, the data folder moves aside to `opencode-data-after-failed-<version>` and the
    /// snapshot moves back into place. Returns whether it did.
    @discardableResult
    public func restoreAfterFailedFirstStart(of version: String) -> Bool {
        guard Self.isFolderName(version) else { return false }
        var ledger = readLedger()
        let snapshot = snapshotFolder(version)
        guard !ledger.started.contains(version), Self.isFolder(snapshot) else { return false }
        let manager = FileManager.default
        let aside = afterFailedFolder(version)
        if manager.fileExists(atPath: aside.path) {
            // What this version left the last time it did not start.
            guard (try? manager.removeItem(at: aside)) != nil else { return false }
        }
        let hadData = manager.fileExists(atPath: dataFolder.path)
        if hadData {
            guard (try? manager.moveItem(at: dataFolder, to: aside)) != nil else { return false }
        }
        do {
            try manager.moveItem(at: snapshot, to: dataFolder)
        } catch {
            // Keep the data as it was rather than start with none.
            if hadData { try? manager.moveItem(at: aside, to: dataFolder) }
            return false
        }
        ledger.snapshots.removeAll { $0 == version }
        if hadData {
            ledger.afterFailed.removeAll { $0 == version }
            ledger.afterFailed.append(version)
            trim(&ledger.afterFailed, folder: afterFailedFolder)
        }
        writeLedger(ledger)
        return true
    }

    /// Removes the oldest recorded copies past `keptCopies`, oldest first by the recorded order.
    private func trim(_ versions: inout [String], folder: (String) -> URL) {
        while versions.count > Self.keptCopies {
            let oldest = versions.removeFirst()
            try? FileManager.default.removeItem(at: folder(oldest))
        }
    }

    func readLedger() -> Ledger {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: ledgerURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumLedgerBytes,
              let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
            // Nothing readable: every version looks new, which only means more snapshots.
            return Ledger()
        }
        return ledger
    }

    private func writeLedger(_ ledger: Ledger) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: ledgerURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }

    /// A version the host names its folder by: one path component.
    static func isFolderName(_ version: String) -> Bool {
        !version.isEmpty && version != "." && version != ".." && !version.contains("/") && !version.contains("\0")
            && version.utf8.count <= 128
    }

    static func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
