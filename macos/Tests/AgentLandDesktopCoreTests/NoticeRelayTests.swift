import CloudKit
import Foundation
import XCTest
import AgentLandCore
import AgentLandNotifications
import AgentLandNotificationsTesting
@testable import AgentLandDesktopCore

/// The relay against a fake host behind URLProtocol and the in-memory
/// CloudKit database, with virtual time.
final class NoticeRelayTests: XCTestCase {
    func testLongPollWritesAPageInOneBatchAndAcknowledgesAfterWriting() async throws {
        let f = RelayFixture()
        f.host.issue(count: 2) { f.notice($0, session: "ses_\($0)") }
        let relay = f.relay()
        await relay.start()
        await eventually("two notices written and acknowledged") { await f.database.creations.count == 2 && f.host.acknowledged == 2 }
        await eventually("the next long-poll") { f.host.heldCount == 1 }
        await relay.stop()

        let polls = f.host.polls
        XCTAssertEqual(polls.count, 2)
        XCTAssertNil(polls[0].query["after"], "the first poll starts after the acknowledged notices")
        XCTAssertEqual(polls[1].query["after"], "00000000000000e1.2")
        XCTAssertEqual(polls.map { $0.query["wait"] }, ["20000", "20000"])
        XCTAssertEqual(Set(f.host.requests.map(\.authorization)), ["Bearer local-session-token"])
        XCTAssertEqual(f.host.acks, [2])
        let batches = await f.database.saveBatches
        XCTAssertEqual(batches, [[f.name(1), f.name(2)]])
        XCTAssertEqual(f.timeline.all, ["account", "zone", "delete", "poll -", "save 1,2", "ack 2", "poll 00000000000000e1.2"])

        let record = try await XCTUnwrapAsync(await f.database.records[f.name(1)])
        XCTAssertEqual(record.recordName, "\(f.hostID)-ntc_1")
        XCTAssertEqual(record.kind, .turnFinished)
        XCTAssertEqual(record.hostID, f.hostID)
        XCTAssertEqual(record.projectID, "workspace")
        XCTAssertEqual(record.projectName, "AgentLand")
        XCTAssertEqual(record.sessionID, "ses_1")
        XCTAssertEqual(record.title, "Fix the login")
        XCTAssertEqual(record.alertBody, "Fix the login · AgentLand")
        XCTAssertEqual(record.createdAt.timeIntervalSince1970, f.clock.now().addingTimeInterval(-5).timeIntervalSince1970, accuracy: 0.001)
        let status = await relay.status
        XCTAssertEqual(status.written, 2)
        XCTAssertEqual(status.phase, .stopped)
    }

    func testEachPageIsOneModifyOperation() async {
        let f = RelayFixture()
        f.host.issue(count: 5) { f.notice($0) }
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 5 }
        var batches = await f.database.saveBatches
        XCTAssertEqual(batches.map(\.count), [5])

        // The host pages at 100; each page is one batch and one acknowledgement.
        f.host.issue(count: 150) { f.notice($0) }
        await eventually { f.host.acknowledged == 155 }
        await relay.stop()
        batches = await f.database.saveBatches
        XCTAssertEqual(batches.map(\.count), [5, 100, 50])
        XCTAssertEqual(f.host.acks, [5, 105, 155])
    }

    func testRetryAfterIsHonoredAndNothingIsAcknowledgedBeforeTheWrite() async {
        let f = RelayFixture()
        await f.database.failNext(.save, with: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0]))
        f.host.issue { f.notice($0) }
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 1 }
        await relay.stop()

        XCTAssertEqual(f.clock.sleeps.first, 7, "waits exactly as long as CloudKit asked")
        XCTAssertEqual(f.timeline.all.prefix(8), ["account", "zone", "delete", "poll -", "save 1", "poll -", "save 1", "ack 1"])
        let creations = await f.database.creations
        XCTAssertEqual(creations, [f.name(1)], "the retry does not add a second record")
    }

    func testStaleUnknownAndEarlierNoticesAreDroppedButAcknowledged() async {
        let f = RelayFixture()
        f.host.issue { f.notice($0, age: 11 * 60) }                    // older than 10 minutes
        f.host.issue { f.notice($0, kind: "chat.something.new") }       // a kind this app does not know
        f.host.issue { f.notice($0, age: 120) }                         // before sending was turned on
        f.host.issue { f.notice($0, age: 30) }
        let relay = f.relay(NoticeRelay.Settings(notBefore: f.clock.now().addingTimeInterval(-60)))
        await relay.start()
        await eventually { f.host.acknowledged == 4 }
        await relay.stop()

        let creations = await f.database.creations
        XCTAssertEqual(creations, [f.name(4)])
        let status = await relay.status
        XCTAssertEqual(status.dropped, 3)
        XCTAssertEqual(status.written, 1)
        XCTAssertEqual(f.host.acks, [4])
    }

    func testAFailedRecordStopsTheAcknowledgementThereAndIsRetried() async {
        let f = RelayFixture()
        f.host.issue(count: 3) { f.notice($0) }
        await f.database.failNextSave(of: f.name(2), with: CKError(.zoneBusy))
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 3 }
        await relay.stop()

        XCTAssertEqual(f.host.acks, [1, 3], "only the notice before the failed one, then the rest")
        XCTAssertEqual(Array(f.timeline.all.prefix(9)),
                       ["account", "zone", "delete", "poll -", "save 1,2,3", "ack 1", "poll -", "save 2,3", "ack 3"])
        let creations = await f.database.creations
        let updates = await f.database.updates
        XCTAssertEqual(creations, [f.name(1), f.name(3), f.name(2)], "every notice alerts once")
        XCTAssertEqual(updates, [f.name(3)])
        XCTAssertEqual(f.clock.sleeps.first, 2, "a failure without retryAfter backs off")
    }

    func testARecordCloudKitRejectsIsDroppedNotRetried() async {
        let f = RelayFixture()
        f.host.issue(count: 2) { f.notice($0) }
        await f.database.failNextSave(of: f.name(1), with: CKError(.invalidArguments))
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 2 }
        await relay.stop()
        let batches = await f.database.saveBatches
        XCTAssertEqual(batches, [[f.name(1), f.name(2)]])
        let status = await relay.status
        XCTAssertEqual(status.dropped, 1)
        XCTAssertEqual(status.written, 1)
    }

    func testResyncAfterTheHostStartsOverWritesTheNewNoticesUnderNewNames() async {
        let f = RelayFixture()
        f.host.issue(count: 2) { f.notice($0, id: "ntc_a\($0)") }
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 2 && f.host.heldCount == 1 }

        // The host restarts without an archive: its long-poll breaks, a new
        // epoch numbers notices from 1 again.
        f.host.restartWithoutArchive()
        await eventually("a poll after the restart") { f.host.polls.count == 3 && f.host.heldCount == 1 }
        f.host.issue(count: 2) { f.notice($0, id: "ntc_b\($0)") }
        await eventually { f.host.acks.count == 2 }
        await eventually { f.host.heldCount == 1 }
        await relay.stop()

        XCTAssertEqual(f.host.polls[2].query["after"], "00000000000000e1.2", "the old cursor, answered with resync")
        XCTAssertEqual(f.host.polls.last?.query["after"], "00000000000000e2.2")
        XCTAssertEqual(f.host.acks, [2, 2], "the second acknowledgement is in the new epoch")
        let creations = await f.database.creations
        XCTAssertEqual(creations, ["ntc_a1", "ntc_a2", "ntc_b1", "ntc_b2"].map { "\(f.hostID)-\($0)" },
                       "seq 1 and 2 of the new epoch do not overwrite the old records")
    }

    func testHourlyCleanupDeletesOnlyThisHostsRecordsOlderThanADay() async {
        let f = RelayFixture()
        let start = f.clock.now()
        func seeded(_ name: String, host: String, age: TimeInterval) -> NoticeRecord {
            NoticeRecord(recordName: name, kind: .turnFinished, hostID: host, projectID: "workspace", projectName: "AgentLand",
                         createdAt: start.addingTimeInterval(-age))
        }
        await f.database.insert(seeded("\(f.hostID)-old", host: f.hostID, age: 25 * 3600))
        await f.database.insert(seeded("\(f.hostID)-recent", host: f.hostID, age: 3600))
        await f.database.insert(seeded("other-old", host: "0123456789abcdef0123456789abcdef", age: 25 * 3600))
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.heldCount == 1 }
        var names = Set(await f.database.records.keys)
        XCTAssertEqual(names, ["\(f.hostID)-recent", "other-old"])

        // Half an hour later: no cleanup yet.
        f.clock.advance(by: 30 * 60)
        f.host.issue { f.notice($0) }
        await eventually { f.host.acknowledged == 1 && f.host.heldCount == 1 }
        var deletes = await f.deletes
        XCTAssertEqual(deletes.count, 1)

        // Past the hour: the next turn of the loop cleans up again.
        f.clock.advance(by: 31 * 60)
        f.host.issue { f.notice($0) }
        await eventually { f.host.acknowledged == 2 && f.host.heldCount == 1 }
        await relay.stop()
        deletes = await f.deletes
        XCTAssertEqual(deletes.map(\.hostID), [f.hostID, f.hostID])
        XCTAssertEqual(deletes.map(\.before), [start.addingTimeInterval(-86_400), start.addingTimeInterval(61 * 60 - 86_400)])
        names = Set(await f.database.records.keys)
        XCTAssertEqual(names, ["\(f.hostID)-recent", "other-old", f.name(1), f.name(2)])
        let status = await relay.status
        XCTAssertEqual(status.lastCleanupAt, start.addingTimeInterval(61 * 60))
    }

    func testACleanupFailureIsReportedAndRelayingGoesOn() async {
        let f = RelayFixture()
        // Before the schema is applied, CloudKit refuses the cleanup query.
        await f.database.failNext(.delete, with: CKError(.invalidArguments))
        f.host.issue { f.notice($0) }
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 1 }
        var status = await relay.status
        XCTAssertNotNil(status.cleanupProblem)
        XCTAssertNil(status.lastCleanupAt)

        f.clock.advance(by: 3601)
        f.host.issue { f.notice($0) }
        await eventually { f.host.acknowledged == 2 }
        await relay.stop()
        status = await relay.status
        XCTAssertNil(status.cleanupProblem, "the next hour's cleanup worked")
        XCTAssertEqual(status.written, 2)
    }

    func testTitlesThatMayHoldContentAreLeftOutWhenTitlesAreOff() async throws {
        let f = RelayFixture()
        f.host.issue { f.notice($0, title: "Rotate the prod keys", mayContainContent: true) }
        f.host.issue { f.notice($0, title: "Nightly tests", mayContainContent: false) }
        let relay = f.relay(NoticeRelay.Settings(includeTitles: false))
        await relay.start()
        await eventually { f.host.acknowledged == 2 }

        let hidden = try await XCTUnwrapAsync(await f.database.records[f.name(1)])
        XCTAssertNil(hidden.title)
        XCTAssertEqual(hidden.alertBody, "AgentLand")
        let marked = try await XCTUnwrapAsync(await f.database.records[f.name(2)])
        XCTAssertEqual(marked.title, "Nightly tests", "a title the host marks as not chat content is kept")
        XCTAssertEqual(marked.alertBody, "Nightly tests · AgentLand")

        await relay.setIncludeTitles(true)
        f.host.issue { f.notice($0, title: "Fix the login", mayContainContent: true) }
        await eventually { f.host.acknowledged == 3 }
        await relay.stop()
        let shown = try await XCTUnwrapAsync(await f.database.records[f.name(3)])
        XCTAssertEqual(shown.title, "Fix the login")
    }

    func testStopEndsTheLongPollAtOnceAndTheRelayNeverStartsAgain() async throws {
        let f = RelayFixture()
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.heldCount == 1 }
        let started = Date()
        await relay.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        await eventually("the held request is cancelled") { f.host.cancelled == 1 }
        let requests = f.host.requests.count
        await relay.start()
        f.host.issue { f.notice($0) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.host.requests.count, requests, "no request after stopping")
        let creations = await f.database.creations
        XCTAssertTrue(creations.isEmpty)
        let status = await relay.status
        XCTAssertEqual(status.phase, .stopped)
    }

    func testStopDoesNotWaitForAWriteThatIgnoresCancellation() async {
        let f = RelayFixture()
        let slow = StubbornDatabase(inner: f.database, delay: 3)
        f.host.issue { f.notice($0) }
        let relay = NoticeRelay(hostID: f.hostID, feed: f.feed, database: slow, clock: f.clock)
        await relay.start()
        await eventually { slow.saving }
        let started = Date()
        await relay.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.6, "Quit is never held up by CloudKit")
    }

    func testHostErrorsBackOffExponentially() async {
        let f = RelayFixture()
        f.host.failNextPoll(status: 500)
        f.host.failNextPoll(status: 500)
        f.host.failNextPoll(status: 500)
        f.host.issue { f.notice($0) }
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 1 && f.host.heldCount == 1 }
        await relay.stop()
        XCTAssertEqual(f.clock.sleeps, [2, 4, 8], "never a hot loop")
        XCTAssertEqual(f.host.polls.count, 5, "three failures, the page, the next long-poll")
        let creations = await f.database.creations
        XCTAssertEqual(creations, [f.name(1)])
    }

    func testAHostThatAnswersAtOnceWithNothingIsNotAskedInATightLoop() async throws {
        let f = RelayFixture()
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.heldCount == 1 }
        f.host.beginStopping()
        try await Task.sleep(for: .milliseconds(300))
        await relay.stop()
        let polls = f.host.polls.count
        XCTAssertGreaterThan(polls, 1)
        XCTAssertTrue([polls - 1, polls].contains(f.clock.sleeps.count), "a pause after each empty answer")
        XCTAssertEqual(Set(f.clock.sleeps), [1])
        XCTAssertLessThan(polls, 80, "5 ms of real time per virtual second at most, never a spin")
    }

    func testNoticesUnavailableWaitsTenMinutes() async {
        let f = RelayFixture(feedOverride: ScriptedFeed(pollError: ClientError.server(code: "notices_unavailable", message: "no")))
        let relay = f.relay()
        await relay.start()
        await eventually { !f.clock.sleeps.isEmpty }
        let status = await relay.status
        await relay.stop()
        XCTAssertEqual(Set(f.clock.sleeps), [600], "asks again every ten minutes")
        if case let .waiting(problem, _) = status.phase { XCTAssertEqual(problem, .hostWithoutNotices) } else { XCTFail("\(status.phase)") }
    }

    func testNoICloudAccountPausesWithoutPollingUntilItComesBack() async {
        let f = RelayFixture()
        await f.database.setStatus(.noAccount)
        f.host.issue { f.notice($0, age: 1) }
        let relay = f.relay()
        await relay.start()
        await eventually { f.clock.sleeps.count >= 1 }
        let status = await relay.status
        if case let .waiting(problem, _) = status.phase { XCTAssertEqual(problem, .account(.noAccount)) } else { XCTFail("\(status.phase)") }
        XCTAssertEqual(f.clock.sleeps.first, 60)
        XCTAssertTrue(f.host.polls.isEmpty, "the host is not read while iCloud is unavailable")

        await f.database.setStatus(.available)
        await eventually { f.host.acknowledged == 1 }
        await relay.stop()
    }

    func testAZoneTheOwnerDeletedIsCreatedAgain() async {
        let f = RelayFixture()
        f.host.issue { f.notice($0) }
        let relay = f.relay()
        await relay.start()
        await eventually { f.host.acknowledged == 1 && f.host.heldCount == 1 }
        await f.database.deleteZone()
        f.host.issue { f.notice($0) }
        await eventually { f.host.acknowledged == 2 }
        await relay.stop()
        XCTAssertEqual(f.timeline.all.filter { $0 == "zone" }.count, 2)
        let names = Set(await f.database.records.keys)
        XCTAssertEqual(names, [f.name(2)])
    }

    func testTheFeedReadsTheHostsNoticePage() throws {
        let json = """
        {"notices":[{"seq":7,"id":"ntc_0a","kind":"schedule.run.failed","projectId":"workspace","projectName":"AgentLand",
          "sessionId":"ses_1","scheduleId":"sch_1","runId":"run_1","title":"Nightly","mayContainContent":false,
          "createdAt":"2026-09-24T10:00:00.123Z"},
         {"seq":8,"id":"ntc_0b","kind":"chat.turn.finished","projectId":"workspace","projectName":"AgentLand","title":"",
          "mayContainContent":false,"createdAt":"2026-09-24T10:00:01Z","future":1}],
         "cursor":"00000000000000e1.8","hasMore":true,"resync":false}
        """
        let page = try JSONDecoder().decode(HostNoticePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.cursor, "00000000000000e1.8")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.notices.map(\.seq), [7, 8])
        XCTAssertEqual(page.notices[0].sessionID, "ses_1", "an older host's scheduleId and runId are ignored")
        XCTAssertFalse(page.notices[0].mayContainContent)
        XCTAssertEqual(page.notices[0].createdDate?.timeIntervalSince1970 ?? 0, 1_790_244_000.123, accuracy: 0.001)
        XCTAssertNil(page.notices[1].sessionID)
        XCTAssertEqual(page.notices[1].createdDate?.timeIntervalSince1970, 1_790_244_001)
    }
}

// MARK: Fixture

private struct RelayFixture {
    let hostID = "e5ca42629ea6e9590c843786b42a5d8a"
    let timeline = Timeline()
    let host: FakeNoticeHost
    let database: InMemoryNoticeDatabase
    let clock = TestClock()
    let feed: any NoticeFeed

    init(feedOverride: (any NoticeFeed)? = nil) {
        host = FakeNoticeHost(timeline: timeline)
        let timeline = timeline
        let prefix = "\(hostID)-ntc_"
        database = InMemoryNoticeDatabase(zoneExists: true, onEvent: { event in
            switch event {
            case .accountStatus: timeline.add("account")
            case .createZone: timeline.add("zone")
            case let .save(names): timeline.add("save " + names.map { $0.replacingOccurrences(of: prefix, with: "") }.joined(separator: ","))
            case .delete: timeline.add("delete")
            }
        })
        feed = feedOverride ?? HostNoticeFeed(baseURL: host.baseURL, token: "local-session-token", transport: FakeHostTransport())
    }

    func relay(_ settings: NoticeRelay.Settings = NoticeRelay.Settings()) -> NoticeRelay {
        NoticeRelay(hostID: hostID, feed: feed, database: database, settings: settings, clock: clock)
    }

    func name(_ seq: Int64) -> String { "\(hostID)-ntc_\(seq)" }

    var deletes: [(hostID: String, before: Date)] {
        get async {
            await database.events.compactMap { if case let .delete(hostID, before) = $0 { (hostID, before) } else { nil } }
        }
    }

    func notice(_ seq: Int64, id: String? = nil, kind: String = "chat.turn.finished", age: TimeInterval = 5,
                session: String? = "ses_1", title: String = "Fix the login", mayContainContent: Bool = true) -> HostNotice {
        HostNotice(seq: seq, id: id ?? "ntc_\(seq)", kind: kind, projectID: "workspace", projectName: "AgentLand",
                   sessionID: session, title: title, mayContainContent: mayContainContent,
                   createdAt: noticeTime(clock.now().addingTimeInterval(-age)))
    }
}

/// A feed that always fails its poll with one error.
private struct ScriptedFeed: NoticeFeed {
    let pollError: any Error
    func notices(after cursor: String?, waitMilliseconds: Int) async throws -> HostNoticePage { throw pollError }
    func acknowledge(through seq: Int64) async throws {}
}

/// Saves after a delay that ignores cancellation, like a CloudKit call that
/// finishes its request anyway.
private final class StubbornDatabase: NoticeDatabase, @unchecked Sendable {
    let inner: InMemoryNoticeDatabase
    let delay: TimeInterval
    private let lock = NSLock()
    private var isSaving = false
    var saving: Bool { lock.withLock { isSaving } }

    init(inner: InMemoryNoticeDatabase, delay: TimeInterval) { self.inner = inner; self.delay = delay }

    func accountStatus() async throws -> NoticeAccountStatus { try await inner.accountStatus() }
    func createZone() async throws { try await inner.createZone() }
    func deleteRecords(hostID: String, createdBefore date: Date, limit: Int) async throws -> Int {
        try await inner.deleteRecords(hostID: hostID, createdBefore: date, limit: limit)
    }
    func save(_ records: [NoticeRecord]) async throws -> [String: Result<Void, any Error>] {
        lock.withLock { isSaving = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
        }
        return try await inner.save(records)
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
