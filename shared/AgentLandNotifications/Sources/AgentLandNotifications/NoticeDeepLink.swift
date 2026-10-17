import CloudKit
import Foundation

/// Where a tapped notice leads: which host (by `NoticeHostID`), project and
/// chat.
///
/// From a push, the kind comes from the subscription ID, the host from the
/// record name and the rest from the subscription's `desiredKeys` (`projectId`,
/// `sessionId`). CloudKit may prune a push or cut a value past 100 characters;
/// then `isComplete` is false and the app fetches the record (`recordName` in
/// the `Notices` zone of the private database) and uses `init(record:)`.
public struct NoticeDeepLink: Equatable, Sendable, Codable {
    public enum Destination: Equatable, Sendable {
        /// A finished or failed reply: open the chat.
        case chat(sessionID: String)
        /// An approval or question: open the chat at its pending card.
        case pendingInteraction(sessionID: String)
        /// Nothing more specific: open the host's project (the test notice).
        case project
    }

    public var kind: NoticeKind
    public var hostID: String
    public var recordName: String
    public var projectID: String?
    public var sessionID: String?
    /// False when values may be missing or cut; fetch the record then.
    public var isComplete: Bool

    public var destination: Destination {
        switch kind {
        case .turnFinished, .turnFailed:
            if let sessionID { return .chat(sessionID: sessionID) }
        case .approvalNeeded, .questionNeeded:
            if let sessionID { return .pendingInteraction(sessionID: sessionID) }
        }
        return .project
    }

    /// From a notice record fetched from CloudKit: always complete.
    public init(record: NoticeRecord) {
        kind = record.kind
        hostID = record.hostID
        recordName = record.recordName
        projectID = record.projectID
        sessionID = record.sessionID
        isComplete = true
    }

    /// From a push's `userInfo`; nil unless it is one of these subscriptions'
    /// notices in the private database's `Notices` zone.
    public init?(remoteNotification userInfo: [AnyHashable: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return nil }
        self.init(notification: notification)
    }

    public init?(notification: CKNotification) {
        guard let query = notification as? CKQueryNotification, query.databaseScope == .private,
              let recordID = query.recordID, recordID.zoneID.zoneName == NoticeRecord.zoneName,
              let subscriptionID = query.subscriptionID,
              let kind = NoticeSubscriptionPlan.kind(forSubscriptionID: subscriptionID) else { return nil }
        self.init(kind: kind, recordName: recordID.recordName, fields: query.recordFields ?? [:], isPruned: query.isPruned)
    }

    /// The pure part of the push parser.
    init?(kind: NoticeKind, recordName: String, fields: [String: Any], isPruned: Bool) {
        guard let hostID = NoticeRecord.hostID(fromRecordName: recordName) else { return nil }
        func value(_ key: CKRecord.FieldKey) -> String? {
            guard let value = fields[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        self.kind = kind
        self.hostID = hostID
        self.recordName = recordName
        projectID = value(NoticeRecord.Field.projectID)
        sessionID = value(NoticeRecord.Field.sessionID)
        let values = [projectID, sessionID].compactMap { $0 }
        isComplete = !isPruned && projectID != nil && values.allSatisfy { $0.utf16.count < NoticeAlertText.pushValueLimit }
    }
}
