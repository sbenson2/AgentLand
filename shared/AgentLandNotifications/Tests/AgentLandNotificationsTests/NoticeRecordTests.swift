import CloudKit
import XCTest
@testable import AgentLandNotifications

final class NoticeRecordTests: XCTestCase {
    private let fingerprint = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    private let createdAt = Date(timeIntervalSince1970: 1_790_000_000.123)

    func testHostIDIsAStableHashOfTheFingerprint() throws {
        let hostID = try XCTUnwrap(NoticeHostID.make(certificateSHA256: fingerprint))
        XCTAssertEqual(hostID.count, 32)
        XCTAssertTrue(NoticeHostID.isValid(hostID))
        // Separators and case do not matter, so iOS can use its pinned value as stored.
        let colons = stride(from: 0, to: 64, by: 2).map { index -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: index)
            return String(fingerprint[start..<fingerprint.index(start, offsetBy: 2)])
        }.joined(separator: ":").uppercased()
        XCTAssertEqual(NoticeHostID.make(certificateSHA256: colons), hostID)
        // A fixed vector, so the Mac and iOS never drift apart.
        // (Python: hashlib.sha256(b"agentland.notice.host.v1:" + fp).hexdigest()[:32])
        XCTAssertEqual(hostID, "e5ca42629ea6e9590c843786b42a5d8a")
        XCTAssertFalse(hostID.contains(String(fingerprint.prefix(12))), "the fingerprint itself is not in the name")
        XCTAssertNil(NoticeHostID.make(certificateSHA256: "abc"))
        XCTAssertNil(NoticeHostID.make(certificateSHA256: String(repeating: "g", count: 64)))
        XCTAssertNotEqual(NoticeHostID.make(certificateSHA256: String(repeating: "a", count: 64)), hostID)
    }

    func testRecordNamesAreDeterministicAndCarryTheHost() throws {
        let hostID = try XCTUnwrap(NoticeHostID.make(certificateSHA256: fingerprint))
        let name = NoticeRecord.recordName(hostID: hostID, noticeID: "ntc_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(name, "\(hostID)-ntc_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(NoticeRecord.recordName(hostID: hostID, noticeID: "ntc_0123456789abcdef0123456789abcdef"), name)
        XCTAssertEqual(NoticeRecord.hostID(fromRecordName: name), hostID)

        // IDs outside the safe alphabet or too long become a hash, still deterministic.
        let odd = NoticeRecord.recordName(hostID: hostID, noticeID: "ntc/../é")
        XCTAssertTrue(odd.hasPrefix("\(hostID)-h"))
        XCTAssertEqual(odd.count, 32 + 2 + 32)
        XCTAssertEqual(NoticeRecord.recordName(hostID: hostID, noticeID: "ntc/../é"), odd)
        XCTAssertTrue(NoticeRecord.recordName(hostID: hostID, noticeID: String(repeating: "a", count: 101)).hasPrefix("\(hostID)-h"))
        XCTAssertTrue(NoticeRecord.recordName(hostID: hostID, noticeID: "").hasPrefix("\(hostID)-h"))

        let test = NoticeRecord.testRecordName(hostID: hostID, id: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!)
        XCTAssertEqual(test, "\(hostID)-test-3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        XCTAssertEqual(NoticeRecord.hostID(fromRecordName: test), hostID)

        XCTAssertNil(NoticeRecord.hostID(fromRecordName: "no-host-here"))
        XCTAssertNil(NoticeRecord.hostID(fromRecordName: hostID))
        XCTAssertNil(NoticeRecord.hostID(fromRecordName: "\(hostID)-"))
    }

    func testCloudKitRecordHasEveryFieldAndLeavesOutAbsentOnes() throws {
        let hostID = try XCTUnwrap(NoticeHostID.make(certificateSHA256: fingerprint))
        let notice = NoticeRecord(recordName: "\(hostID)-ntc_1", kind: .approvalNeeded, hostID: hostID, projectID: "workspace",
                                  projectName: "AgentLand", sessionID: "ses_1", title: "Fix the login", createdAt: createdAt)
        let record = notice.makeRecord()
        XCTAssertEqual(record.recordType, "Notice")
        XCTAssertEqual(record.recordID.recordName, "\(hostID)-ntc_1")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "Notices")
        XCTAssertEqual(record.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
        XCTAssertEqual(Set(record.allKeys()), ["kind", "hostId", "projectId", "projectName", "sessionId", "title", "createdAt",
                                               "alertBody"])
        XCTAssertEqual(record["kind"] as? String, "chat.approval.needed")
        XCTAssertEqual(record["hostId"] as? String, hostID)
        XCTAssertEqual(record["createdAt"] as? Date, createdAt)
        XCTAssertEqual(record["alertBody"] as? String, "Fix the login · AgentLand")
        XCTAssertEqual(NoticeRecord(record: record), notice)

        let bare = NoticeRecord(recordName: "\(hostID)-ntc_2", kind: .turnFinished, hostID: hostID, projectID: "workspace",
                                projectName: "AgentLand", sessionID: "", title: nil, createdAt: createdAt)
        let bareRecord = bare.makeRecord()
        XCTAssertEqual(Set(bareRecord.allKeys()), ["kind", "hostId", "projectId", "projectName", "createdAt", "alertBody"])
        XCTAssertEqual(bareRecord["alertBody"] as? String, "AgentLand")
        XCTAssertEqual(NoticeRecord(record: bareRecord), bare)
    }

    func testReadingRefusesOtherTypesAndUnknownKinds() {
        let zone = NoticeRecord.zoneID
        let other = CKRecord(recordType: "Other", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        XCTAssertNil(NoticeRecord(record: other))
        let unknown = CKRecord(recordType: "Notice", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        unknown["kind"] = "chat.something.new"
        unknown["hostId"] = "h"
        unknown["projectId"] = "p"
        unknown["createdAt"] = createdAt
        XCTAssertNil(NoticeRecord(record: unknown))
        unknown["kind"] = "schedule.run.finished"
        XCTAssertNil(NoticeRecord(record: unknown), "scheduled-run notices were removed on 2026-10-06")
        unknown["kind"] = "chat.turn.failed"
        XCTAssertNotNil(NoticeRecord(record: unknown))
        unknown["createdAt"] = nil
        XCTAssertNil(NoticeRecord(record: unknown))
    }

    func testTextIsOneBoundedLineAndEmptyValuesCountAsNone() {
        let notice = NoticeRecord(recordName: "n", kind: .turnFinished, hostID: "h", projectID: "workspace", projectName: "  \n ",
                                  sessionID: "", title: "Line one\nline\ttwo\u{0}", createdAt: createdAt)
        XCTAssertEqual(notice.projectName, "workspace", "an empty name falls back to the project ID")
        XCTAssertEqual(notice.title, "Line one line two")
        XCTAssertNil(notice.sessionID)

        let long = NoticeRecord(recordName: "n", kind: .turnFinished, hostID: "h", projectID: "p", projectName: "P",
                                title: String(repeating: "t", count: 500), createdAt: createdAt)
        XCTAssertEqual(long.title?.utf16.count, NoticeRecord.textLimit)
        XCTAssertEqual(long.title?.last, "…")
        XCTAssertLessThanOrEqual(long.alertBody.utf16.count, NoticeAlertText.pushValueLimit)

        let blank = NoticeRecord(recordName: "n", kind: .turnFinished, hostID: "h", projectID: "p", projectName: "P",
                                 title: " \n", createdAt: createdAt)
        XCTAssertNil(blank.title)
        XCTAssertEqual(blank.alertBody, "P")
    }
}
