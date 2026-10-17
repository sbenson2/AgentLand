import CloudKit
import Foundation
import AgentLandNotifications

/// A `NoticeDatabase` in memory for tests. It follows the real database's
/// rules that matter to callers: records and subscriptions need the zone (else
/// per-item `zoneNotFound`), saving an existing name overwrites it as an update
/// (only a new name counts as a creation, which is what fires a subscription),
/// saving a subscription ID that exists replaces it, deleting one that is gone
/// counts as done, and failures can be scripted per call, per record or per
/// subscription.
public actor InMemoryNoticeDatabase: NoticeDatabase {
    /// The Mac relay's calls, in order.
    public enum Event: Equatable, Sendable {
        case accountStatus
        case createZone
        /// One modify operation with these record names, in order.
        case save([String])
        case delete(hostID: String, before: Date)
    }

    /// The subscriber's calls (iPhone and iPad), in order. Kept apart from
    /// `Event`, which the relay's tests switch over.
    public enum SubscriberEvent: Equatable, Sendable {
        case subscriptionIDs
        /// One modify operation: the IDs saved and deleted, in order.
        case modifySubscriptions(saving: [CKSubscription.ID], deleting: [CKSubscription.ID])
        case record(String)
    }

    public private(set) var records: [String: NoticeRecord] = [:]
    /// Names in the order they were first created: the alerts a device
    /// subscribed to every kind would get.
    public private(set) var creations: [String] = []
    public private(set) var updates: [String] = []
    public private(set) var events: [Event] = []
    public private(set) var subscriberEvents: [SubscriberEvent] = []
    /// The account's subscriptions by ID, as the last save left them.
    public private(set) var subscriptions: [CKSubscription.ID: CKQuerySubscription] = [:]
    public private(set) var zoneExists: Bool
    public var status: NoticeAccountStatus

    private var failNextCalls: [(call: Call, error: any Error)] = []
    private var failNextRecords: [String: any Error] = [:]
    private var failNextSubscriptions: [CKSubscription.ID: any Error] = [:]
    private var saveDelay: Duration?
    private let onEvent: (@Sendable (Event) -> Void)?

    public enum Call: Sendable { case accountStatus, createZone, save, delete, subscriptionIDs, modifySubscriptions, record }

    public init(zoneExists: Bool = false, status: NoticeAccountStatus = .available,
                onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.zoneExists = zoneExists
        self.status = status
        self.onEvent = onEvent
    }

    // MARK: Test controls

    /// The next `call` throws `error` (queued in order).
    public func failNext(_ call: Call, with error: any Error) { failNextCalls.append((call, error)) }
    /// The next save that includes `recordName` reports `error` for it.
    public func failNextSave(of recordName: String, with error: any Error) { failNextRecords[recordName] = error }
    /// The next modify operation that saves or deletes `id` reports `error` for it.
    public func failNextSubscriptionChange(of id: CKSubscription.ID, with error: any Error) { failNextSubscriptions[id] = error }
    public func setStatus(_ status: NoticeAccountStatus) { self.status = status }
    /// As if the owner deleted the app's iCloud data: the zone and its records go.
    public func deleteZone() { zoneExists = false; records = [:] }
    public func insert(_ record: NoticeRecord) { records[record.recordName] = record }
    /// As if another device on the account saved these subscriptions.
    public func insert(_ subscriptions: [CKQuerySubscription]) {
        for subscription in subscriptions { self.subscriptions[subscription.subscriptionID] = subscription }
    }
    /// Makes each save wait this long first (to test stopping mid-write).
    public func setSaveDelay(_ delay: Duration?) { saveDelay = delay }
    public var saveBatches: [[String]] {
        events.compactMap { if case let .save(names) = $0 { names } else { nil } }
    }
    /// The subscription modify operations, in order.
    public var subscriptionChanges: [SubscriberEvent] {
        subscriberEvents.filter { if case .modifySubscriptions = $0 { true } else { false } }
    }
    /// The kinds the account's notice subscriptions cover.
    public var subscribedKinds: Set<NoticeKind> {
        Set(subscriptions.keys.compactMap(NoticeSubscriptionPlan.kind(forSubscriptionID:)))
    }

    // MARK: NoticeDatabase

    public func accountStatus() async throws -> NoticeAccountStatus {
        record(.accountStatus)
        try failIfScripted(.accountStatus)
        return status
    }

    public func createZone() async throws {
        record(.createZone)
        try failIfScripted(.createZone)
        zoneExists = true
    }

    public func save(_ records: [NoticeRecord]) async throws -> [String: Result<Void, any Error>] {
        record(.save(records.map(\.recordName)))
        if let saveDelay { try await Task.sleep(for: saveDelay) }
        try failIfScripted(.save)
        var results: [String: Result<Void, any Error>] = [:]
        for notice in records {
            if let error = failNextRecords.removeValue(forKey: notice.recordName) {
                results[notice.recordName] = .failure(error)
            } else if !zoneExists {
                results[notice.recordName] = .failure(CKError(.zoneNotFound))
            } else {
                if self.records[notice.recordName] == nil { creations.append(notice.recordName) } else { updates.append(notice.recordName) }
                self.records[notice.recordName] = notice
                results[notice.recordName] = .success(())
            }
        }
        return results
    }

    public func deleteRecords(hostID: String, createdBefore date: Date, limit: Int) async throws -> Int {
        record(.delete(hostID: hostID, before: date))
        try failIfScripted(.delete)
        guard zoneExists else { throw CKError(.zoneNotFound) }
        let doomed = records.values.filter { $0.hostID == hostID && $0.createdAt < date }
            .sorted { $0.createdAt < $1.createdAt }.prefix(max(0, limit))
        for notice in doomed { records[notice.recordName] = nil }
        return doomed.count
    }

    public func subscriptionIDs() async throws -> Set<CKSubscription.ID> {
        subscriberEvents.append(.subscriptionIDs)
        try failIfScripted(.subscriptionIDs)
        return Set(subscriptions.keys)
    }

    /// Recorded and scripted as `subscriptionIDs`: both read the account's subscriptions.
    public func subscriptions() async throws -> [NoticeSubscriptionSummary] {
        subscriberEvents.append(.subscriptionIDs)
        try failIfScripted(.subscriptionIDs)
        return subscriptions.values
            .map { NoticeSubscriptionSummary(id: $0.subscriptionID, soundName: $0.notificationInfo?.soundName) }
            .sorted { $0.id < $1.id }
    }

    public func modifySubscriptions(saving subscriptions: [CKQuerySubscription],
                                    deleting ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, any Error>] {
        subscriberEvents.append(.modifySubscriptions(saving: subscriptions.map(\.subscriptionID), deleting: ids))
        try failIfScripted(.modifySubscriptions)
        var results: [CKSubscription.ID: Result<Void, any Error>] = [:]
        for subscription in subscriptions {
            let id = subscription.subscriptionID
            if let error = failNextSubscriptions.removeValue(forKey: id) {
                results[id] = .failure(error)
            } else if subscription.zoneID != nil && !zoneExists {
                results[id] = .failure(CKError(.zoneNotFound))
            } else {
                self.subscriptions[id] = subscription
                results[id] = .success(())
            }
        }
        for id in ids {
            if let error = failNextSubscriptions.removeValue(forKey: id) {
                results[id] = .failure(error)
            } else {
                self.subscriptions[id] = nil
                results[id] = .success(())
            }
        }
        return results
    }

    public func record(named recordName: String) async throws -> NoticeRecord? {
        subscriberEvents.append(.record(recordName))
        try failIfScripted(.record)
        guard zoneExists else { throw CKError(.zoneNotFound) }
        return records[recordName]
    }

    private func record(_ event: Event) {
        events.append(event)
        onEvent?(event)
    }

    private func failIfScripted(_ call: Call) throws {
        guard let index = failNextCalls.firstIndex(where: { $0.call == call }) else { return }
        throw failNextCalls.remove(at: index).error
    }
}
