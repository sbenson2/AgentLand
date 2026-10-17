import CloudKit
import XCTest
import AgentLandNotifications
import AgentLandNotificationsTesting

final class InMemoryNoticeDatabaseTests: XCTestCase {
    private func notice(_ name: String, host: String = "h", at date: Date) -> NoticeRecord {
        NoticeRecord(recordName: name, kind: .turnFinished, hostID: host, projectID: "p", projectName: "P", createdAt: date)
    }

    func testRecordsNeedTheZoneAndASecondSaveIsAnUpdate() async throws {
        let database = InMemoryNoticeDatabase()
        let first = try await database.save([notice("h-1", at: Date())])
        guard case let .failure(error)? = first["h-1"] else { return XCTFail("saved without a zone") }
        XCTAssertEqual(NoticeFailure(error), .zoneMissing)

        try await database.createZone()
        let saved = try await database.save([notice("h-1", at: Date()), notice("h-2", at: Date())])
        XCTAssertEqual(saved.count, 2)
        _ = try await database.save([notice("h-1", at: Date())])
        let creations = await database.creations
        let updates = await database.updates
        XCTAssertEqual(creations, ["h-1", "h-2"], "only new names would alert")
        XCTAssertEqual(updates, ["h-1"])
        let batches = await database.saveBatches
        XCTAssertEqual(batches, [["h-1"], ["h-1", "h-2"], ["h-1"]])
    }

    func testScriptedFailuresAndCleanup() async throws {
        let database = InMemoryNoticeDatabase(zoneExists: true)
        await database.failNext(.save, with: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 4.0]))
        do {
            _ = try await database.save([notice("h-1", at: Date())])
            XCTFail("expected the scripted failure")
        } catch {
            XCTAssertEqual(NoticeFailure(error), .retry(after: 4))
        }
        await database.failNextSave(of: "h-2", with: CKError(.invalidArguments))
        let results = try await database.save([notice("h-1", at: Date()), notice("h-2", at: Date())])
        if case .failure = results["h-2"] {} else { XCTFail("h-2 should fail") }
        if case .success = results["h-1"] {} else { XCTFail("h-1 should be saved") }

        let now = Date()
        await database.insert(notice("h-old", at: now.addingTimeInterval(-90_000)))
        await database.insert(notice("h-older", at: now.addingTimeInterval(-100_000)))
        await database.insert(notice("x-old", host: "x", at: now.addingTimeInterval(-90_000)))
        let deleted = try await database.deleteRecords(hostID: "h", createdBefore: now.addingTimeInterval(-86_400), limit: 1)
        XCTAssertEqual(deleted, 1)
        var names = Set(await database.records.keys)
        XCTAssertEqual(names, ["h-1", "h-old", "x-old"], "the oldest first, within the limit, this host only")
        _ = try await database.deleteRecords(hostID: "h", createdBefore: now.addingTimeInterval(-86_400), limit: 10)
        names = Set(await database.records.keys)
        XCTAssertEqual(names, ["h-1", "x-old"])
    }
}
