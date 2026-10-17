import CloudKit
import CryptoKit
import Foundation

/// One notice as a CloudKit record: record type `Notice` in the custom zone
/// `Notices` of the owner's private database in container
/// `iCloud.dev.agentland`.
///
/// Fields (all strings except `createdAt`):
///
/// | Field | |
/// |---|---|
/// | `kind` | a `NoticeKind` raw value; queryable, the subscriptions filter on it |
/// | `hostId` | `NoticeHostID` of the Mac's host; queryable, for the Mac's cleanup |
/// | `projectId`, `projectName` | the project |
/// | `sessionId` | present when the notice names a chat |
/// | `title` | the chat's title; absent when there is none or "Include chat titles" left it out |
/// | `createdAt` | when the host issued the notice (date); queryable and sortable, for the cleanup |
/// | `alertBody` | the alert body the Mac composed (`NoticeAlertText.body`), at most 100 characters |
///
/// A record never holds message text or a credential. CloudKit builds the
/// alert on its servers from `alertBody`, so these fields cannot use CloudKit's
/// encrypted values; "Include chat titles" is the control for what reaches
/// them.
///
/// Record names are deterministic, `<hostId>-<notice id>`, so writing a notice
/// again (a retry, or the host serving it again after a restart) updates the
/// same record instead of adding one, and the creation-only subscriptions do
/// not alert twice. The host's notice `id` is used rather than its `seq`,
/// because `seq` starts over when the host's notice epoch changes (a new
/// archive, or a restart of a host that keeps notices in memory) and would
/// then name a different notice. The test notice is `<hostId>-test-<uuid>`.
public struct NoticeRecord: Equatable, Sendable {
    public static let containerIdentifier = "iCloud.dev.agentland"
    public static let recordType: CKRecord.RecordType = "Notice"
    public static let zoneName = "Notices"
    public static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }
    /// Titles and project names longer than this many UTF-16 units are cut.
    public static let textLimit = 200

    public enum Field {
        public static let kind: CKRecord.FieldKey = "kind"
        public static let hostID: CKRecord.FieldKey = "hostId"
        public static let projectID: CKRecord.FieldKey = "projectId"
        public static let projectName: CKRecord.FieldKey = "projectName"
        public static let sessionID: CKRecord.FieldKey = "sessionId"
        public static let title: CKRecord.FieldKey = "title"
        public static let createdAt: CKRecord.FieldKey = "createdAt"
        public static let alertBody: CKRecord.FieldKey = "alertBody"
    }

    public var recordName: String
    public var kind: NoticeKind
    public var hostID: String
    public var projectID: String
    public var projectName: String
    public var sessionID: String?
    public var title: String?
    public var createdAt: Date
    public var alertBody: String

    /// A record for one notice. `title` and `projectName` become single lines
    /// of at most `textLimit` UTF-16 units; an empty title or ID counts as
    /// none, and an empty project name falls back to the project ID.
    public init(recordName: String, kind: NoticeKind, hostID: String, projectID: String, projectName: String,
                sessionID: String? = nil, title: String? = nil, createdAt: Date) {
        let name = NoticeAlertText.truncated(NoticeAlertText.singleLine(projectName), limit: Self.textLimit)
        let title = title.map { NoticeAlertText.truncated(NoticeAlertText.singleLine($0), limit: Self.textLimit) }
        self.recordName = recordName
        self.kind = kind
        self.hostID = hostID
        self.projectID = projectID
        self.projectName = name.isEmpty ? projectID : name
        self.sessionID = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        self.createdAt = createdAt
        self.alertBody = NoticeAlertText.body(title: self.title, projectName: self.projectName)
    }

    /// `<hostId>-<notice id>`. An ID that is not 1–100 characters of
    /// `A–Z a–z 0–9 _ . -` is replaced by a hash of it, so the name stays
    /// ASCII and short whatever the host sends.
    public static func recordName(hostID: String, noticeID: String) -> String {
        let allowed = noticeID.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 46 || byte == 45
        }
        guard allowed, (1...100).contains(noticeID.utf8.count) else {
            let digest = SHA256.hash(data: Data(noticeID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            return "\(hostID)-h\(digest)"
        }
        return "\(hostID)-\(noticeID)"
    }

    /// The name of a test notice: `<hostId>-test-<uuid>`.
    public static func testRecordName(hostID: String, id: UUID = UUID()) -> String {
        "\(hostID)-test-\(id.uuidString.lowercased())"
    }

    /// The `hostId` a record name starts with, when it has the right form.
    public static func hostID(fromRecordName recordName: String) -> String? {
        guard let dash = recordName.firstIndex(of: "-") else { return nil }
        let prefix = recordName[..<dash]
        return NoticeHostID.isValid(prefix) && recordName.index(after: dash) < recordName.endIndex ? String(prefix) : nil
    }

    /// The CloudKit record. Absent optional fields are left out.
    public func makeRecord(zoneID: CKRecordZone.ID = NoticeRecord.zoneID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        record[Field.kind] = kind.rawValue
        record[Field.hostID] = hostID
        record[Field.projectID] = projectID
        record[Field.projectName] = projectName
        if let sessionID { record[Field.sessionID] = sessionID }
        if let title { record[Field.title] = title }
        record[Field.createdAt] = createdAt
        record[Field.alertBody] = alertBody
        return record
    }

    /// Reads a fetched `Notice` record; nil for another type, an unknown kind
    /// or missing required fields. `alertBody` is kept as stored.
    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
              let kind = (record[Field.kind] as? String).flatMap(NoticeKind.init(rawValue:)),
              let hostID = record[Field.hostID] as? String,
              let projectID = record[Field.projectID] as? String,
              let createdAt = record[Field.createdAt] as? Date else { return nil }
        self.init(recordName: record.recordID.recordName, kind: kind, hostID: hostID, projectID: projectID,
                  projectName: record[Field.projectName] as? String ?? "", sessionID: record[Field.sessionID] as? String,
                  title: record[Field.title] as? String, createdAt: createdAt)
        if let stored = record[Field.alertBody] as? String { alertBody = stored }
    }
}
