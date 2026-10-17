import Foundation
import XCTest
@testable import AgentLandDesktopCore

/// OpenCode's data folder across the host's versions (`OpenCodeDataGuard`), in temporary folders: a clone
/// before a version's first start, put back when that version does not start, the newest two of each kept
/// by the order recorded, never by modification time.
final class OpenCodeDataGuardTests: XCTestCase {
    func testAVersionThatNeverStartedGetsASnapshotOfTheDataBeforeItsFirstStart() throws {
        let storage = try Storage()
        defer { storage.cleanUp() }
        try storage.write("chat.db", "before 1.19.0")
        let guardian = storage.guardian
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.19.0"))
        XCTAssertEqual(try storage.read("opencode-data-before-1.19.0/chat.db"), "before 1.19.0")

        // An earlier attempt's snapshot is older than anything that attempt changed: it is kept.
        try storage.write("chat.db", "changed by the attempt")
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.19.0"))
        XCTAssertEqual(try storage.read("opencode-data-before-1.19.0/chat.db"), "before 1.19.0")

        // Once it started, no snapshot is made for it again.
        guardian.noteStarted("1.19.0")
        XCTAssertTrue(guardian.hasStarted("1.19.0"))
        try FileManager.default.removeItem(at: guardian.snapshotFolder("1.19.0"))
        XCTAssertFalse(guardian.snapshotBeforeFirstStart(of: "1.19.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardian.snapshotFolder("1.19.0").path))
        XCTAssertFalse(guardian.snapshotBeforeFirstStart(of: "../escape"), "a version is one folder name")
    }

    /// The newest two snapshots stay, in the order the guard recorded them: modification times that say
    /// otherwise do not matter.
    func testOnlyTheNewestTwoSnapshotsAreKeptByTheRecordedOrder() throws {
        let storage = try Storage()
        defer { storage.cleanUp() }
        try storage.write("chat.db", "data")
        let guardian = storage.guardian
        for version in ["1.18.31", "1.18.32"] { XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: version)) }
        // The first snapshot looks newest on disk, the second oldest.
        try storage.touch(guardian.snapshotFolder("1.18.31"), Date().addingTimeInterval(3600))
        try storage.touch(guardian.snapshotFolder("1.18.32"), Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.18.33"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardian.snapshotFolder("1.18.31").path), "the first recorded goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: guardian.snapshotFolder("1.18.32").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guardian.snapshotFolder("1.18.33").path))
        XCTAssertEqual(guardian.readLedger().snapshots, ["1.18.32", "1.18.33"])
    }

    func testAFailedFirstStartMovesTheDataAsideAndPutsTheSnapshotBack() throws {
        let storage = try Storage()
        defer { storage.cleanUp() }
        try storage.write("chat.db", "old")
        let guardian = storage.guardian
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.19.0"))
        try storage.write("chat.db", "migrated")
        XCTAssertTrue(guardian.restoreAfterFailedFirstStart(of: "1.19.0"))
        XCTAssertEqual(try storage.read("data/chat.db"), "old")
        XCTAssertEqual(try storage.read("opencode-data-after-failed-1.19.0/chat.db"), "migrated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardian.snapshotFolder("1.19.0").path))
        XCTAssertEqual(guardian.readLedger().snapshots, [])
        XCTAssertEqual(guardian.readLedger().afterFailed, ["1.19.0"])
        XCTAssertFalse(guardian.restoreAfterFailedFirstStart(of: "1.19.0"), "no snapshot left to put back")

        // The same version fails its next first start too: what it left last time makes way.
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.19.0"))
        try storage.write("chat.db", "migrated again")
        XCTAssertTrue(guardian.restoreAfterFailedFirstStart(of: "1.19.0"))
        XCTAssertEqual(try storage.read("opencode-data-after-failed-1.19.0/chat.db"), "migrated again")
        XCTAssertEqual(guardian.readLedger().afterFailed, ["1.19.0"])
    }

    /// A version that started here has newer work in its data than its snapshot: it is never rolled back.
    func testAVersionThatStartedIsNeverRolledBack() throws {
        let storage = try Storage()
        defer { storage.cleanUp() }
        try storage.write("chat.db", "old")
        let guardian = storage.guardian
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.19.0"))
        guardian.noteStarted("1.19.0")
        try storage.write("chat.db", "a week of chats")
        XCTAssertFalse(guardian.restoreAfterFailedFirstStart(of: "1.19.0"))
        XCTAssertEqual(try storage.read("data/chat.db"), "a week of chats")
        XCTAssertTrue(FileManager.default.fileExists(atPath: guardian.snapshotFolder("1.19.0").path))
    }

    func testOnlyTheNewestTwoFailedDataFoldersAreKept() throws {
        let storage = try Storage()
        defer { storage.cleanUp() }
        try storage.write("chat.db", "data")
        let guardian = storage.guardian
        for version in ["1.19.0", "1.19.1", "1.19.2"] {
            XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: version))
            try storage.write("chat.db", "left by \(version)")
            try storage.touch(guardian.dataFolder, Date(timeIntervalSince1970: 1_000_000))
            XCTAssertTrue(guardian.restoreAfterFailedFirstStart(of: version))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardian.afterFailedFolder("1.19.0").path), "the first recorded goes")
        XCTAssertEqual(try storage.read("opencode-data-after-failed-1.19.1/chat.db"), "left by 1.19.1")
        XCTAssertEqual(try storage.read("opencode-data-after-failed-1.19.2/chat.db"), "left by 1.19.2")
        XCTAssertEqual(guardian.readLedger().afterFailed, ["1.19.1", "1.19.2"])
    }

    func testAnUnreadableRecordTreatsEveryVersionAsNew() throws {
        let storage = try Storage()
        defer { storage.cleanUp() }
        try storage.write("chat.db", "data")
        let guardian = storage.guardian
        guardian.noteStarted("1.19.0")
        try Data("not json".utf8).write(to: guardian.ledgerURL)
        XCTAssertFalse(guardian.hasStarted("1.19.0"))
        XCTAssertTrue(guardian.snapshotBeforeFirstStart(of: "1.19.0"), "only one more snapshot")
    }
}

/// `<root>/data`, the runtime's data folder, and the guard of `<root>`.
private struct Storage {
    let root: URL
    var guardian: OpenCodeDataGuard { OpenCodeDataGuard(storageRoot: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-data-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("data").appendingPathComponent(name))
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
