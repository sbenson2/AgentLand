import CloudKit
import XCTest
@testable import AgentLandNotifications

final class NoticeCloudKitTests: XCTestCase {
    private let signed: (String) -> Any? = { key in
        switch key {
        case "com.apple.developer.icloud-container-identifiers": ["iCloud.dev.agentland"]
        case "com.apple.developer.icloud-services": ["CloudKit"]
        default: nil
        }
    }

    func testCloudKitNeedsTheEntitlementsAndNoOptOut() {
        XCTAssertNil(NoticeCloudKit.unavailability(environment: [:], entitlement: signed))
        XCTAssertNil(NoticeCloudKit.unavailability(environment: ["AGENTLAND_CLOUDKIT": "1"], entitlement: signed))
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: ["AGENTLAND_CLOUDKIT": "0"], entitlement: signed), .turnedOff)
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: [:], entitlement: { _ in nil }), .notSignedForICloud)
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: [:], entitlement: { key in
            key == "com.apple.developer.icloud-container-identifiers" ? ["iCloud.dev.other"] : ["CloudKit"]
        }), .notSignedForICloud)
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: [:], entitlement: { key in
            key == "com.apple.developer.icloud-container-identifiers" ? ["iCloud.dev.agentland"] : ["CloudDocuments"]
        }), .notSignedForICloud)
    }

    func testThisTestProcessIsNotSignedForICloudSoNoContainerIsMade() {
        // swift test runs unsigned for iCloud: the real check must say so, and
        // makeDatabase must not call CKContainer(identifier:), which would trap.
        XCTAssertNil(NoticeCloudKit.currentEntitlement("com.apple.developer.icloud-container-identifiers"))
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: [:]), .notSignedForICloud)
        XCTAssertNil(NoticeCloudKit.makeDatabase(environment: [:]))
        XCTAssertNil(NoticeCloudKit.makeDatabase(environment: ["AGENTLAND_CLOUDKIT": "0"]))
    }

    func testFailuresAreClassifiedForTheRelay() {
        XCTAssertEqual(NoticeFailure(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.5])), .retry(after: 7.5))
        XCTAssertEqual(NoticeFailure(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 3])), .retry(after: 3))
        XCTAssertEqual(NoticeFailure(CKError(.serviceUnavailable)), .retry(after: nil))
        XCTAssertEqual(NoticeFailure(CKError(.networkFailure)), .retry(after: nil))
        XCTAssertEqual(NoticeFailure(URLError(.timedOut)), .retry(after: nil))
        XCTAssertEqual(NoticeFailure(CKError(.zoneNotFound)), .zoneMissing)
        XCTAssertEqual(NoticeFailure(CKError(.userDeletedZone)), .zoneMissing)
        XCTAssertEqual(NoticeFailure(CKError(.notAuthenticated)), .account)
        XCTAssertEqual(NoticeFailure(CKError(.accountTemporarilyUnavailable)), .account)
        XCTAssertEqual(NoticeFailure(CKError(.quotaExceeded)), .quotaExceeded)
        XCTAssertEqual(NoticeFailure(CKError(.serverRecordChanged)), .alreadySaved)
        XCTAssertEqual(NoticeFailure(CKError(.invalidArguments)), .rejected)
        XCTAssertEqual(NoticeFailure(CKError(.serverRejectedRequest)), .rejected)
    }

    func testRetryAfterIsReadFromPartialFailuresToo() {
        let id = CKRecord.ID(recordName: "a", zoneID: NoticeRecord.zoneID)
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [id: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 12.0])]
        ])
        XCTAssertEqual(partial.noticeRetryAfter, 12)
        XCTAssertEqual(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 2.5]).noticeRetryAfter, 2.5)
        XCTAssertNil(CKError(.networkFailure).noticeRetryAfter)
        XCTAssertNil(URLError(.timedOut).noticeRetryAfter)
    }

    func testAccountStatusesMap() {
        XCTAssertEqual(NoticeAccountStatus(.available), .available)
        XCTAssertEqual(NoticeAccountStatus(.noAccount), .noAccount)
        XCTAssertEqual(NoticeAccountStatus(.restricted), .restricted)
        XCTAssertEqual(NoticeAccountStatus(.temporarilyUnavailable), .temporarilyUnavailable)
        XCTAssertEqual(NoticeAccountStatus(.couldNotDetermine), .couldNotDetermine)
    }
}
