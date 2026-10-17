import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// `NoticeDatabase` over the private database of `iCloud.dev.agentland`.
///
/// Create it through `NoticeCloudKit.makeDatabase()`: `CKContainer(identifier:)`
/// stops the process when the app lacks the iCloud entitlement.
public final class CloudKitNoticeDatabase: NoticeDatabase, @unchecked Sendable {
    /// Records per query page and per delete request.
    static let batchLimit = 200
    private let container: CKContainer
    private let database: CKDatabase
    public let zoneID: CKRecordZone.ID

    public init(container: CKContainer, zoneID: CKRecordZone.ID = NoticeRecord.zoneID) {
        self.container = container
        database = container.privateCloudDatabase
        self.zoneID = zoneID
    }

    public func accountStatus() async throws -> NoticeAccountStatus {
        NoticeAccountStatus(try await container.accountStatus())
    }

    public func createZone() async throws {
        let (saved, _) = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        if case let .failure(error)? = saved[zoneID] { throw error }
    }

    public func save(_ records: [NoticeRecord]) async throws -> [String: Result<Void, any Error>] {
        guard !records.isEmpty else { return [:] }
        let (saved, _) = try await database.modifyRecords(saving: records.map { $0.makeRecord(zoneID: zoneID) }, deleting: [],
                                                          savePolicy: .allKeys, atomically: false)
        var results: [String: Result<Void, any Error>] = [:]
        for (id, result) in saved {
            switch result {
            case .success: results[id.recordName] = .success(())
            case let .failure(error): results[id.recordName] = .failure(error)
            }
        }
        // A record the server's answer leaves out was not saved.
        for record in records where results[record.recordName] == nil {
            results[record.recordName] = .failure(CKError(.internalError))
        }
        return results
    }

    public func deleteRecords(hostID: String, createdBefore date: Date, limit: Int) async throws -> Int {
        guard limit > 0 else { return 0 }
        let predicate = NSPredicate(format: "%K == %@ AND %K < %@", NoticeRecord.Field.hostID, hostID,
                                    NoticeRecord.Field.createdAt, date as NSDate)
        let query = CKQuery(recordType: NoticeRecord.recordType, predicate: predicate)
        var ids: [CKRecord.ID] = []
        var page = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: [],
                                              resultsLimit: min(limit, Self.batchLimit))
        ids += page.matchResults.map(\.0)
        while let cursor = page.queryCursor, ids.count < limit {
            page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [],
                                              resultsLimit: min(limit - ids.count, Self.batchLimit))
            ids += page.matchResults.map(\.0)
        }
        var deleted = 0
        for start in stride(from: 0, to: ids.count, by: Self.batchLimit) {
            let batch = Array(ids[start..<min(start + Self.batchLimit, ids.count)])
            let (_, results) = try await database.modifyRecords(saving: [], deleting: batch, savePolicy: .allKeys, atomically: false)
            for result in results.values {
                switch result {
                case .success: deleted += 1
                case let .failure(error) where (error as? CKError)?.code == .unknownItem: deleted += 1
                case .failure: continue
                }
            }
        }
        return deleted
    }

    public func subscriptionIDs() async throws -> Set<CKSubscription.ID> {
        Set(try await database.allSubscriptions().map(\.subscriptionID))
    }

    public func subscriptions() async throws -> [NoticeSubscriptionSummary] {
        try await database.allSubscriptions().map {
            NoticeSubscriptionSummary(id: $0.subscriptionID, soundName: $0.notificationInfo?.soundName)
        }
    }

    public func modifySubscriptions(saving subscriptions: [CKQuerySubscription],
                                    deleting ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, any Error>] {
        guard !subscriptions.isEmpty || !ids.isEmpty else { return [:] }
        let (saved, deleted) = try await database.modifySubscriptions(saving: subscriptions, deleting: ids)
        return Self.subscriptionResults(saved: saved.mapValues { $0.map { _ in () } }, deleted: deleted,
                                        requested: subscriptions.map(\.subscriptionID) + ids)
    }

    /// Each requested ID's outcome from CloudKit's answer: deleting a
    /// subscription that is already gone (`unknownItem`) counts as done, and an
    /// ID the answer leaves out was not changed.
    static func subscriptionResults(saved: [CKSubscription.ID: Result<Void, any Error>],
                                    deleted: [CKSubscription.ID: Result<Void, any Error>],
                                    requested: [CKSubscription.ID]) -> [CKSubscription.ID: Result<Void, any Error>] {
        var results = saved
        for (id, result) in deleted {
            if case let .failure(error) = result, (error as? CKError)?.code != .unknownItem {
                results[id] = .failure(error)
            } else {
                results[id] = .success(())
            }
        }
        for id in requested where results[id] == nil { results[id] = .failure(CKError(.internalError)) }
        return results
    }

    public func record(named recordName: String) async throws -> NoticeRecord? {
        do {
            return NoticeRecord(record: try await database.record(for: CKRecord.ID(recordName: recordName, zoneID: zoneID)))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}

/// Whether this process may use CloudKit, and the database when it may.
public enum NoticeCloudKit {
    /// `AGENTLAND_CLOUDKIT=0` keeps CloudKit off (UI tests, local runs).
    public static let environmentSwitch = "AGENTLAND_CLOUDKIT"
    static let containerEntitlement = "com.apple.developer.icloud-container-identifiers"
    static let servicesEntitlement = "com.apple.developer.icloud-services"

    public enum Unavailable: Equatable, Sendable {
        /// `AGENTLAND_CLOUDKIT=0` is set.
        case turnedOff
        /// The signed app lacks the iCloud container entitlement (an ad-hoc
        /// build, or `swift test`).
        case notSignedForICloud
    }

    /// Why this process must not use CloudKit, or nil when it may. On macOS
    /// the app's own entitlements are read with `SecTaskCopyValueForEntitlement`;
    /// on an iOS device, the grants of its embedded provisioning profile.
    public static func unavailability(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      entitlement: (String) -> Any? = currentEntitlement) -> Unavailable? {
        if environment[environmentSwitch] == "0" { return .turnedOff }
        let containers = entitlement(containerEntitlement) as? [String] ?? []
        let services = entitlement(servicesEntitlement) as? [String] ?? []
        guard containers.contains(NoticeRecord.containerIdentifier), services.contains("CloudKit") else {
            return .notSignedForICloud
        }
        return nil
    }

    /// The real database, or nil when `unavailability()` is not nil. Only
    /// then is `CKContainer(identifier:)` called.
    public static func makeDatabase(environment: [String: String] = ProcessInfo.processInfo.environment) -> CloudKitNoticeDatabase? {
        guard unavailability(environment: environment) == nil else { return nil }
        return CloudKitNoticeDatabase(container: CKContainer(identifier: NoticeRecord.containerIdentifier))
    }

    /// The value of one of this process's entitlements.
    public static func currentEntitlement(_ key: String) -> Any? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        #elseif targetEnvironment(simulator)
        // Simulator builds are signed with the entitlements file as written.
        switch key {
        case containerEntitlement: return [NoticeRecord.containerIdentifier]
        case servicesEntitlement: return ["CloudKit"]
        default: return nil
        }
        #else
        // iOS has no public call for a process's own entitlements. A device build carries its
        // provisioning profile, and CloudKit refuses (the app would stop) unless that profile grants
        // the container, so the profile's grant is the check: a build signed while the App ID had no
        // container assigned reads as not signed for iCloud instead of ending in CKContainer.
        return provisionedGrant(key, in: provisionedEntitlements())
        #endif
    }

    /// One grant of a provisioning profile as the app's entitlement would read. Profiles grant the
    /// iCloud services as the wildcard "*", which allows CloudKit.
    static func provisionedGrant(_ key: String, in entitlements: [String: Any]) -> Any? {
        let value = entitlements[key]
        if key == servicesEntitlement, value as? String == "*" { return ["CloudKit", "CloudDocuments"] }
        return value
    }

    /// The entitlements granted by the app's embedded provisioning profile (empty when there is none).
    static func provisionedEntitlements(bundle: Bundle = .main) -> [String: Any] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return provisionedEntitlements(profile: data)
    }

    /// The `Entitlements` of a provisioning profile: the property list inside its CMS envelope.
    static func provisionedEntitlements(profile data: Data) -> [String: Any] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                      format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [:] }
        return entitlements
    }
}
