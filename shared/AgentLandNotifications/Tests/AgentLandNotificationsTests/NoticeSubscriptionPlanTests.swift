import CloudKit
import XCTest
@testable import AgentLandNotifications

final class NoticeSubscriptionPlanTests: XCTestCase {
    func testOneCreationOnlySubscriptionPerKindInTheNoticesZone() throws {
        let subscriptions = NoticeSubscriptionPlan().subscriptions()
        XCTAssertEqual(subscriptions.count, NoticeKind.allCases.count)
        for (subscription, kind) in zip(subscriptions, NoticeKind.allCases) {
            XCTAssertEqual(subscription.subscriptionID, "agentland.notice.\(kind.rawValue)")
            XCTAssertEqual(subscription.recordType, "Notice")
            XCTAssertEqual(subscription.predicate, NSPredicate(format: "kind == %@", kind.rawValue))
            XCTAssertEqual(subscription.querySubscriptionOptions, [.firesOnRecordCreation])
            XCTAssertEqual(subscription.zoneID?.zoneName, "Notices")
            XCTAssertEqual(subscription.zoneID?.ownerName, CKCurrentUserDefaultName)
            XCTAssertEqual(NoticeSubscriptionPlan.kind(forSubscriptionID: subscription.subscriptionID), kind)

            let info = try XCTUnwrap(subscription.notificationInfo)
            XCTAssertEqual(info.titleLocalizationKey, kind.titleLocalizationKey)
            XCTAssertNil(info.titleLocalizationArgs)
            XCTAssertEqual(info.alertLocalizationKey, "notice.body")
            XCTAssertEqual(info.alertLocalizationArgs, ["alertBody"])
            XCTAssertNil(info.alertBody, "the localization key replaces a fixed body")
            XCTAssertEqual(info.soundName, "default", "without a sound, badge or body CloudKit sends a silent, low-priority push")
            XCTAssertEqual(info.desiredKeys, ["projectId", "sessionId"])
            XCTAssertLessThanOrEqual(info.desiredKeys?.count ?? 0, 3, "CloudKit allows at most three desired keys")
            XCTAssertFalse(info.shouldSendContentAvailable)
            XCTAssertFalse(info.shouldBadge)
        }
    }

    func testEveryFieldTheSubscriptionsNameIsOnTheRecord() throws {
        let record = NoticeRecord(recordName: "h-1", kind: .questionNeeded, hostID: "h", projectID: "p", projectName: "P",
                                  sessionID: "s", title: "T", createdAt: Date()).makeRecord()
        let info = NoticeSubscriptionPlan.notificationInfo(for: .questionNeeded)
        for field in (info.desiredKeys ?? []) + (info.alertLocalizationArgs ?? []) {
            XCTAssertNotNil(record[field], field)
        }
        // The body the alert shows is always present, whatever else is left out.
        let bare = NoticeRecord(recordName: "h-2", kind: .turnFinished, hostID: "h", projectID: "p", projectName: "P",
                                createdAt: Date()).makeRecord()
        XCTAssertEqual(bare["alertBody"] as? String, "P")
    }

    func testTurnedOffKindsAreNotSubscribedAndAreListedForDeletion() {
        let plan = NoticeSubscriptionPlan(enabledKinds: [.questionNeeded, .turnFinished, .turnFinished])
        XCTAssertEqual(plan.enabledKinds, [.turnFinished, .questionNeeded], "kept in catalog order, without repeats")
        XCTAssertEqual(plan.subscriptions().map(\.subscriptionID),
                       ["agentland.notice.chat.turn.finished", "agentland.notice.chat.question.needed"])
        XCTAssertEqual(plan.subscriptionIDsToDelete, ["agentland.notice.chat.turn.failed", "agentland.notice.chat.approval.needed",
                                                      "agentland.notice.schedule.run.finished",
                                                      "agentland.notice.schedule.run.budget_exceeded",
                                                      "agentland.notice.schedule.run.failed"],
                       "the kinds turned off, then the retired scheduled-run subscriptions")
        XCTAssertEqual(NoticeSubscriptionPlan(enabledKinds: []).subscriptions().count, 0)
        XCTAssertEqual(NoticeSubscriptionPlan().subscriptionIDsToDelete, NoticeSubscriptionPlan.retiredSubscriptionIDs,
                       "every kind on still deletes the retired subscriptions")
    }

    func testTheSoundOffPlaysTheBundledSilentSoundSoTheAlertStillShows() throws {
        let plan = NoticeSubscriptionPlan(enabledKinds: [.turnFinished, .questionNeeded], sound: false)
        for subscription in plan.subscriptions() {
            let info = try XCTUnwrap(subscription.notificationInfo)
            XCTAssertEqual(info.soundName, "agentland-silent.caf", "a sound name is always set: without one the push is silent")
            XCTAssertEqual(info.alertLocalizationKey, "notice.body")
            XCTAssertFalse(info.shouldBadge)
        }
        XCTAssertFalse(NoticeSubscriptionPlan.playsSound(NoticeSubscriptionPlan.silentSoundName))
        XCTAssertTrue(NoticeSubscriptionPlan.playsSound("default"))
        XCTAssertTrue(NoticeSubscriptionPlan().sound, "on unless asked")
    }

    func testSubscriptionIDsMapBackToKindsOnly() {
        XCTAssertNil(NoticeSubscriptionPlan.kind(forSubscriptionID: "agentland.notice.chat.unknown"))
        XCTAssertNil(NoticeSubscriptionPlan.kind(forSubscriptionID: "other.chat.turn.finished"))
        XCTAssertEqual(NoticeSubscriptionPlan.kind(forSubscriptionID: "agentland.notice.chat.question.needed"), .questionNeeded)
        for retired in NoticeSubscriptionPlan.retiredSubscriptionIDs {
            XCTAssertNil(NoticeSubscriptionPlan.kind(forSubscriptionID: retired), retired)
        }
        XCTAssertEqual(NoticeSubscriptionPlan.version, 2)
    }
}
