import CloudKit
import XCTest
@testable import AgentLandNotifications
import AgentLandNotificationsTesting

/// The subscriber's database calls: subscriptions and reading a record.
final class NoticeSubscriptionDatabaseTests: XCTestCase {
    private let hostID = "e5ca42629ea6e9590c843786b42a5d8a"

    func testSubscriptionsNeedTheZoneReplaceByIDAndDeletingAGoneOneIsDone() async throws {
        let database = InMemoryNoticeDatabase()
        let plan = NoticeSubscriptionPlan(enabledKinds: NoticeGroup.replies.kinds)
        let withoutZone = try await database.modifySubscriptions(saving: plan.subscriptions(), deleting: [])
        for id in plan.subscriptions().map(\.subscriptionID) {
            guard case let .failure(error)? = withoutZone[id] else { return XCTFail("\(id) saved without its zone") }
            XCTAssertEqual(NoticeFailure(error), .zoneMissing)
        }

        try await database.createZone()
        let saved = try await database.modifySubscriptions(saving: plan.subscriptions(), deleting: plan.subscriptionIDsToDelete)
        XCTAssertEqual(saved.count, NoticeKind.allCases.count + NoticeSubscriptionPlan.retiredSubscriptionIDs.count,
                       "one outcome per saved and deleted ID")
        XCTAssertTrue(saved.values.allSatisfy { if case .success = $0 { true } else { false } },
                      "deleting subscriptions that never existed counts as done")
        var kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, [.turnFinished, .turnFailed])

        // Saving an existing ID replaces the subscription.
        let replacement = NoticeSubscriptionPlan(enabledKinds: [.turnFinished]).subscriptions()[0]
        let info = replacement.notificationInfo
        info?.soundName = "other"
        replacement.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [replacement], deleting: [NoticeSubscriptionPlan.subscriptionID(for: .turnFailed)])
        kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, [.turnFinished])
        let stored = await database.subscriptions[NoticeSubscriptionPlan.subscriptionID(for: .turnFinished)]
        XCTAssertEqual(stored?.notificationInfo?.soundName, "other")
        let ids = try await database.subscriptionIDs()
        XCTAssertEqual(ids, [NoticeSubscriptionPlan.subscriptionID(for: .turnFinished)])

        let relayEvents = await database.events
        XCTAssertEqual(relayEvents, [.createZone], "subscriber calls stay out of the relay's events")
        let changes = await database.subscriptionChanges
        XCTAssertEqual(changes.count, 3)
    }

    func testScriptedSubscriptionFailures() async throws {
        let database = InMemoryNoticeDatabase(zoneExists: true)
        let id = NoticeSubscriptionPlan.subscriptionID(for: .approvalNeeded)
        await database.failNextSubscriptionChange(of: id, with: CKError(.invalidArguments))
        let results = try await database.modifySubscriptions(saving: NoticeSubscriptionPlan(enabledKinds: NoticeGroup.approvals.kinds).subscriptions(),
                                                             deleting: [])
        guard case let .failure(error)? = results[id] else { return XCTFail("expected the scripted failure") }
        XCTAssertEqual(NoticeFailure(error), .rejected)
        if case .success = results[NoticeSubscriptionPlan.subscriptionID(for: .questionNeeded)] {} else { XCTFail("the other one is saved") }

        await database.failNext(.modifySubscriptions, with: CKError(.networkUnavailable))
        do {
            _ = try await database.modifySubscriptions(saving: [], deleting: [id])
            XCTFail("expected the scripted failure")
        } catch {
            XCTAssertEqual(NoticeFailure(error), .retry(after: nil))
        }
        await database.failNext(.subscriptionIDs, with: CKError(.notAuthenticated))
        do {
            _ = try await database.subscriptionIDs()
            XCTFail("expected the scripted failure")
        } catch {
            XCTAssertEqual(NoticeFailure(error), .account)
        }
    }

    func testReadingARecord() async throws {
        let database = InMemoryNoticeDatabase()
        let name = "\(hostID)-ntc_1"
        do {
            _ = try await database.record(named: name)
            XCTFail("a missing zone is an error")
        } catch {
            XCTAssertEqual(NoticeFailure(error), .zoneMissing)
        }
        try await database.createZone()
        let missing = try await database.record(named: name)
        XCTAssertNil(missing, "a deleted record reads as nil")
        let record = NoticeRecord(recordName: name, kind: .questionNeeded, hostID: hostID, projectID: "p", projectName: "P",
                                  sessionID: "s", createdAt: Date())
        await database.insert(record)
        let read = try await database.record(named: name)
        XCTAssertEqual(read, record)
        let events = await database.subscriberEvents
        XCTAssertEqual(events, [.record(name), .record(name), .record(name)])
    }

    func testCloudKitAnswersBecomeOneOutcomePerID() {
        let saved = "agentland.notice.chat.turn.finished"
        let gone = "agentland.notice.chat.turn.failed"
        let refused = "agentland.notice.chat.approval.needed"
        let missing = "agentland.notice.chat.question.needed"
        let results = CloudKitNoticeDatabase.subscriptionResults(
            saved: [saved: .success(())],
            deleted: [gone: .failure(CKError(.unknownItem)), refused: .failure(CKError(.permissionFailure))],
            requested: [saved, gone, refused, missing])
        if case .success = results[saved] {} else { XCTFail("saved") }
        if case .success = results[gone] {} else { XCTFail("deleting a gone subscription is done") }
        guard case let .failure(error)? = results[refused] else { return XCTFail("refused") }
        XCTAssertEqual(NoticeFailure(error), .account)
        guard case .failure? = results[missing] else { return XCTFail("an ID the answer leaves out was not changed") }
        XCTAssertEqual(results.count, 4)
    }

    func testWriteOnlyDatabasesRefuseTheSubscriberCalls() async {
        struct WriteOnly: NoticeDatabase {
            func accountStatus() async throws -> NoticeAccountStatus { .available }
            func createZone() async throws {}
            func save(_ records: [NoticeRecord]) async throws -> [String: Result<Void, any Error>] { [:] }
            func deleteRecords(hostID: String, createdBefore date: Date, limit: Int) async throws -> Int { 0 }
        }
        do {
            _ = try await WriteOnly().subscriptionIDs()
            XCTFail("expected NoticeDatabaseUnsupported")
        } catch {
            XCTAssertEqual(error as? NoticeDatabaseUnsupported, NoticeDatabaseUnsupported(call: "subscriptionIDs"))
            XCTAssertEqual(NoticeFailure(error), .rejected)
        }
        do {
            _ = try await WriteOnly().record(named: "x")
            XCTFail("expected NoticeDatabaseUnsupported")
        } catch {
            XCTAssertTrue(error is NoticeDatabaseUnsupported)
        }
    }

    func testGroupsCoverEveryKindOnce() {
        XCTAssertEqual(NoticeGroup.allCases.flatMap(\.kinds).sorted { $0.rawValue < $1.rawValue },
                       NoticeKind.allCases.sorted { $0.rawValue < $1.rawValue })
        for kind in NoticeKind.allCases { XCTAssertTrue(NoticeGroup(kind: kind).kinds.contains(kind)) }
        XCTAssertEqual(NoticeGroup.groups(of: [.turnFailed, .questionNeeded]), [.replies, .approvals],
                       "a group partly on counts as on")
        XCTAssertEqual(NoticeGroup.kinds(of: [.approvals, .replies]),
                       [.turnFinished, .turnFailed, .approvalNeeded, .questionNeeded])
        XCTAssertEqual(NoticeGroup.kinds(of: []), [])
    }
}
