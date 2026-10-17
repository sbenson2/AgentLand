import CloudKit
import XCTest
@testable import AgentLandNotifications

final class NoticeDeepLinkTests: XCTestCase {
    private let hostID = "e5ca42629ea6e9590c843786b42a5d8a"

    /// A push in the form CloudKit delivers a query notification; CloudKit's
    /// own parser reads it (`dbs` 1 is the private database, `p` marks a
    /// pruned payload).
    private func payload(kind: NoticeKind, recordName: String, fields: [String: String], zone: String = "Notices",
                         databaseScope: Int = 1, pruned: Bool = false, subscriptionID: String? = nil) -> [AnyHashable: Any] {
        var ck: [String: Any] = [
            "ce": 2, "cid": "iCloud.dev.agentland", "nid": "8C3B1E7A-0000-4000-8000-000000000001",
            "qry": ["af": fields, "dbs": databaseScope, "fo": 1, "rid": recordName,
                    "sid": subscriptionID ?? NoticeSubscriptionPlan.subscriptionID(for: kind), "zid": zone, "zoid": "_defaultOwner"] as [String: Any]
        ]
        if pruned { ck["p"] = 1 }
        return ["aps": ["alert": ["title-loc-key": kind.titleLocalizationKey, "loc-key": "notice.body",
                                  "loc-args": ["Fix the login · AgentLand"]], "sound": "default"], "ck": ck]
    }

    func testAChatPushOpensTheChatOnItsHost() throws {
        let link = try XCTUnwrap(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFinished, recordName: "\(hostID)-ntc_0123", fields: ["projectId": "workspace", "sessionId": "ses_1"])))
        XCTAssertEqual(link.kind, .turnFinished)
        XCTAssertEqual(link.hostID, hostID)
        XCTAssertEqual(link.recordName, "\(hostID)-ntc_0123")
        XCTAssertEqual(link.projectID, "workspace")
        XCTAssertEqual(link.sessionID, "ses_1")
        XCTAssertTrue(link.isComplete)
        XCTAssertEqual(link.destination, .chat(sessionID: "ses_1"))
    }

    func testApprovalsAndQuestionsLeadToTheirPlaces() throws {
        let approval = try XCTUnwrap(NoticeDeepLink(remoteNotification: payload(
            kind: .approvalNeeded, recordName: "\(hostID)-ntc_1",
            fields: ["projectId": "workspace", "sessionId": "ses_2", "scheduleId": "sch_9"])))
        XCTAssertEqual(approval.destination, .pendingInteraction(sessionID: "ses_2"), "a field from an older Mac is ignored")

        let question = try XCTUnwrap(NoticeDeepLink(remoteNotification: payload(
            kind: .questionNeeded, recordName: "\(hostID)-ntc_2", fields: ["projectId": "workspace", "sessionId": "ses_3"])))
        XCTAssertEqual(question.destination, .pendingInteraction(sessionID: "ses_3"))

        let test = try XCTUnwrap(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFinished, recordName: NoticeRecord.testRecordName(hostID: hostID), fields: ["projectId": "workspace"])))
        XCTAssertEqual(test.destination, .project)
        XCTAssertTrue(test.isComplete)
    }

    func testPrunedOrCutPushesAskForTheRecord() throws {
        let pruned = try XCTUnwrap(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFailed, recordName: "\(hostID)-ntc_5", fields: [:], pruned: true)))
        XCTAssertFalse(pruned.isComplete)
        XCTAssertNil(pruned.projectID)
        XCTAssertEqual(pruned.hostID, hostID, "the record name survives pruning of the fields")
        XCTAssertEqual(pruned.destination, .project)

        let cut = try XCTUnwrap(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFailed, recordName: "\(hostID)-ntc_6",
            fields: ["projectId": "workspace", "sessionId": String(repeating: "s", count: 100)])))
        XCTAssertFalse(cut.isComplete, "CloudKit may have cut a value of 100 characters")

        let noProject = try XCTUnwrap(NoticeDeepLink(kind: .turnFailed, recordName: "\(hostID)-ntc_7",
                                                     fields: ["sessionId": "ses"], isPruned: false))
        XCTAssertFalse(noProject.isComplete)
    }

    func testOtherPushesAreNotNotices() {
        XCTAssertNil(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFinished, recordName: "\(hostID)-ntc_1", fields: ["projectId": "p"], zone: "_defaultZone")))
        XCTAssertNil(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFinished, recordName: "\(hostID)-ntc_1", fields: ["projectId": "p"], databaseScope: 2)),
                     "the public database")
        XCTAssertNil(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFinished, recordName: "\(hostID)-ntc_1", fields: ["projectId": "p"], subscriptionID: "someone.else")))
        XCTAssertNil(NoticeDeepLink(remoteNotification: payload(
            kind: .turnFinished, recordName: "not-a-host", fields: ["projectId": "p"])))
        XCTAssertNil(NoticeDeepLink(remoteNotification: ["aps": ["alert": "Hello"]]))
    }

    func testAFetchedRecordGivesTheWholeLink() {
        let record = NoticeRecord(recordName: "\(hostID)-ntc_8", kind: .turnFailed, hostID: hostID, projectID: "workspace",
                                  projectName: "AgentLand", sessionID: "ses_6", title: "Nightly", createdAt: Date())
        let link = NoticeDeepLink(record: record)
        XCTAssertTrue(link.isComplete)
        XCTAssertEqual(link.destination, .chat(sessionID: "ses_6"))
        XCTAssertEqual(NoticeDeepLink(record: NoticeRecord(record: record.makeRecord())!), link)

        let data = try? JSONEncoder().encode(link)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(NoticeDeepLink.self, from: $0) }, link,
                       "a link can be kept until the app unlocks")
    }
}
