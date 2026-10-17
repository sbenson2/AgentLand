import CloudKit
import Foundation

/// The iCloud account state CloudKit reports for this device.
public enum NoticeAccountStatus: String, Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    public init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        default: self = .couldNotDetermine
        }
    }
}

/// The few CloudKit calls notices need, over the `Notices` zone of the
/// private database. `CloudKitNoticeDatabase` is the real one;
/// `InMemoryNoticeDatabase` (AgentLandNotificationsTesting) is for tests, which
/// never touch CloudKit.
///
/// The Mac writes and cleans up records; iPhone and iPad keep the account's
/// subscriptions and read a record when a push left values out.
///
/// Errors are CloudKit's (`CKError`) or the transport's; `NoticeFailure`
/// classifies them.
public protocol NoticeDatabase: Sendable {
    /// `CKContainer.accountStatus()`.
    func accountStatus() async throws -> NoticeAccountStatus
    /// Creates the `Notices` zone; saving an existing zone changes nothing.
    func createZone() async throws
    /// Saves the records in one modify operation, not atomically, with the
    /// `.allKeys` policy: a record whose name exists is overwritten, which is
    /// an update, not a new record. Throws when the whole request fails;
    /// otherwise returns each record's outcome by record name.
    func save(_ records: [NoticeRecord]) async throws -> [String: Result<Void, any Error>]
    /// Deletes up to `limit` records whose `hostId` is `hostID` and whose
    /// `createdAt` is before `date`, and returns how many it deleted.
    func deleteRecords(hostID: String, createdBefore date: Date, limit: Int) async throws -> Int

    /// The IDs of the account's subscriptions in the private database, of
    /// every app on the container (`NoticeSubscriptionPlan.kind(forSubscriptionID:)`
    /// picks out the notices').
    func subscriptionIDs() async throws -> Set<CKSubscription.ID>
    /// The account's subscriptions in the private database, of every app on the container, each with the
    /// sound its alerts play. The notices' groups and their sound are read from them.
    func subscriptions() async throws -> [NoticeSubscriptionSummary]
    /// Saves `subscriptions` and deletes the subscriptions `ids` names, in one
    /// modify operation, not atomically. Saving an ID that exists replaces
    /// that subscription; deleting one that does not exist counts as done.
    /// Throws when the whole request fails; otherwise returns each ID's
    /// outcome. Subscriptions belong to the iCloud account, so the change
    /// reaches every device signed in to it.
    func modifySubscriptions(saving subscriptions: [CKQuerySubscription],
                             deleting ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, any Error>]
    /// The notice record named `recordName` in the `Notices` zone, or nil when
    /// it no longer exists (the Mac deletes its records after 24 hours).
    func record(named recordName: String) async throws -> NoticeRecord?
}

/// One of the account's subscriptions, as `NoticeDatabase.subscriptions()` reads it.
public struct NoticeSubscriptionSummary: Equatable, Sendable {
    public let id: CKSubscription.ID
    /// The notification's `soundName`; nil when it has none.
    public let soundName: String?

    public init(id: CKSubscription.ID, soundName: String?) {
        self.id = id
        self.soundName = soundName
    }
}

/// A call the database does not offer.
public struct NoticeDatabaseUnsupported: Error, Equatable, Sendable {
    public let call: String
}

/// The subscriber's calls for databases that only write notices, such as the
/// Mac relay's test doubles: they throw `NoticeDatabaseUnsupported`.
public extension NoticeDatabase {
    func subscriptionIDs() async throws -> Set<CKSubscription.ID> {
        throw NoticeDatabaseUnsupported(call: "subscriptionIDs")
    }

    /// For a database that lists only IDs: each subscription's sound is unknown (nil), which counts as on.
    func subscriptions() async throws -> [NoticeSubscriptionSummary] {
        try await subscriptionIDs().map { NoticeSubscriptionSummary(id: $0, soundName: nil) }
    }

    func modifySubscriptions(saving subscriptions: [CKQuerySubscription],
                             deleting ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, any Error>] {
        throw NoticeDatabaseUnsupported(call: "modifySubscriptions")
    }

    func record(named recordName: String) async throws -> NoticeRecord? {
        throw NoticeDatabaseUnsupported(call: "record(named:)")
    }
}

/// What to do about a failed CloudKit call or record.
public enum NoticeFailure: Equatable, Sendable {
    /// Try again later; after the server's `retryAfterSeconds` when it gave one.
    case retry(after: TimeInterval?)
    /// The `Notices` zone is gone (never made, or the owner deleted the app's
    /// data): create it again, then retry.
    case zoneMissing
    /// The iCloud account cannot be used now: check the account status again.
    case account
    /// The owner's iCloud storage is full.
    case quotaExceeded
    /// The server accepted the record already (it exists).
    case alreadySaved
    /// The server refuses this record for good; retrying cannot help.
    case rejected

    public init(_ error: any Error) {
        if error is NoticeDatabaseUnsupported { self = .rejected; return }
        guard let error = error as? CKError else { self = .retry(after: nil); return }
        switch error.code {
        case .zoneNotFound, .userDeletedZone:
            self = .zoneMissing
        case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted, .permissionFailure,
             .badContainer, .missingEntitlement:
            self = .account
        case .quotaExceeded:
            self = .quotaExceeded
        case .serverRecordChanged:
            self = .alreadySaved
        case .invalidArguments, .serverRejectedRequest, .constraintViolation, .unknownItem, .referenceViolation,
             .assetFileNotFound, .assetNotAvailable, .incompatibleVersion, .limitExceeded:
            self = .rejected
        default:
            self = .retry(after: error.noticeRetryAfter)
        }
    }
}

public extension Error {
    /// CloudKit's `CKErrorRetryAfterKey`, also from a partial failure's
    /// items: the longest wait any of them asks for.
    var noticeRetryAfter: TimeInterval? {
        guard let error = self as? CKError else { return nil }
        func seconds(_ error: CKError) -> TimeInterval? {
            (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? error.retryAfterSeconds
        }
        let items = (error.partialErrorsByItemID ?? [:]).values.compactMap { ($0 as? CKError).flatMap(seconds) }
        return ([seconds(error)].compactMap { $0 } + items).max()
    }
}
