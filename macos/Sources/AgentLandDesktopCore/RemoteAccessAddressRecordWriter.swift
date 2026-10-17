import CloudKit
import Foundation
import AgentLandCore
import AgentLandNotifications

/// What the Mac writes into its address record (docs/HOST-API.md "When the Mac's address changes"):
/// the report the host answered, in the fields a device reads.
public struct RemoteAccessAddressRecordContents: Equatable, Sendable {
    /// The record's name: the host's `hostId` (`NoticeHostID` of its certificate fingerprint).
    public var hostID: String
    public var nodeID: IrohNodeID
    public var directAddresses: [String]
    /// Only with the fallback.
    public var relayURL: String?
    /// The report's `revision`.
    public var revision: String
    /// The `sequence` of the host's answer to that report.
    public var sequence: Int64

    public init(hostID: String, nodeID: IrohNodeID, directAddresses: [String], relayURL: String?, revision: String, sequence: Int64) {
        self.hostID = hostID
        self.nodeID = nodeID
        self.directAddresses = directAddresses
        self.relayURL = relayURL
        self.revision = revision
        self.sequence = sequence
    }

    /// The record for the host's answer to a report with `enabled: true`; nil when the answer is not
    /// one (no node ID or no revision).
    public init?(hostID: String, answer: RemoteAccessCapabilities) {
        guard answer.enabled, let nodeID = answer.nodeID, let revision = answer.revision else { return nil }
        self.init(hostID: hostID, nodeID: nodeID, directAddresses: answer.directAddresses,
                  relayURL: answer.fallbackRelay ? answer.relayURL : nil, revision: revision, sequence: answer.sequence)
    }
}

/// The CloudKit calls the address record needs, in zone `RemoteAccess` of the private database of
/// `iCloud.dev.agentland`. `CloudKitRemoteAccessAddressDatabase` is the real one; tests use a fake.
public protocol RemoteAccessAddressDatabase: Sendable {
    func accountStatus() async throws -> NoticeAccountStatus
    /// Creates the zone; saving an existing zone changes nothing.
    func createZone() async throws
    /// Saves the record, replacing the one of that name.
    func save(_ contents: RemoteAccessAddressRecordContents) async throws
    /// Deletes the record of that name; one that is not there (nor its zone) counts as deleted.
    func delete(hostID: String) async throws
}

/// Keeps the Mac's address record in the owner's iCloud in step with its remote access
/// (docs/HOST-API.md "When the Mac's address changes", The record):
/// - it writes after every report with `enabled: true` whose revision differs from the record's
///   (`write`), and deletes the record when the switch goes off and, at each launch while it is off,
///   any record left for its host (`delete`);
/// - one change at a time goes to iCloud, and only the latest wanted one counts: a failed write or
///   delete is retried with the notice relay's backoff until it succeeds or something newer is
///   wanted; a newer change drops one waiting for its retry at once, and a change in flight finishes
///   (or fails) before the next one is sent, so no write lands after the delete that followed it;
/// - it never holds up the report to the host, which does not wait for it.
public actor RemoteAccessAddressRecordWriter {
    public enum Change: Equatable, Sendable {
        case write(RemoteAccessAddressRecordContents)
        case delete(hostID: String)
    }

    public struct Status: Equatable, Sendable {
        /// The last change iCloud took, and when.
        public var done: Change?
        public var doneAt: Date?
        /// Why the change waiting for its retry failed.
        public var problem: String?
        public var retryAt: Date?

        public init() {}
    }

    private let database: any RemoteAccessAddressDatabase
    private let clock: any NoticeRelayClock
    private let onStatus: @Sendable (Status) -> Void
    private var wanted: Change?
    /// The revision iCloud holds for each host's record as far as this run knows.
    private var written: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var waiting: Task<Void, any Error>?
    private var ready = false
    private var ended = false
    public private(set) var status = Status() { didSet { if status != oldValue { onStatus(status) } } }

    public init(database: any RemoteAccessAddressDatabase, clock: any NoticeRelayClock = SystemNoticeRelayClock(),
                onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.database = database
        self.clock = clock
        self.onStatus = onStatus
    }

    /// A report with `enabled: true` was answered: write its record unless iCloud has that revision.
    public func write(_ contents: RemoteAccessAddressRecordContents) {
        if written[contents.hostID] == contents.revision, wanted == nil { return }
        want(.write(contents))
    }

    /// The switch went off (or is off at launch): delete the host's record.
    public func delete(hostID: String) {
        want(.delete(hostID: hostID))
    }

    /// The change not yet done, if any (tests).
    public var pending: Change? { wanted }

    /// Stops at once: a call in flight is left to finish on its own, and nothing more is sent.
    public func stop() {
        ended = true
        wanted = nil
        waiting?.cancel()
        task?.cancel()
        task = nil
    }

    /// Waits until nothing is wanted, or `timeout` (tests, and Quit's bounded wait).
    public func settle(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while wanted != nil || task != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func want(_ change: Change) {
        guard !ended else { return }
        wanted = change
        // A change waiting for its retry is dropped: the loop goes on with the newest at once.
        waiting?.cancel()
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    private func run() async {
        var attempt = 0
        while let change = wanted, !ended {
            do {
                try await perform(change)
                attempt = 0
                if case let .write(contents) = change { written[contents.hostID] = contents.revision }
                if case let .delete(hostID) = change { written[hostID] = nil }
                status.done = change
                status.doneAt = clock.now()
                status.problem = nil
                status.retryAt = nil
                if wanted == change { wanted = nil }
            } catch {
                guard !ended else { break }
                if wanted != change { attempt = 0; continue }  // something newer is wanted: send it now
                attempt += 1
                let delay = backoff(after: error, attempt: attempt)
                status.problem = NoticeRelay.describe(error)
                status.retryAt = clock.now().addingTimeInterval(delay)
                let clock = clock
                let wait = Task { try await clock.sleep(for: .milliseconds(Int64(delay * 1000))) }
                waiting = wait
                _ = try? await wait.value
                waiting = nil
            }
        }
        task = nil
    }

    private func perform(_ change: Change) async throws {
        if !ready {
            let account = try await database.accountStatus()
            guard account == .available else { throw AccountUnavailable(status: account) }
            try await database.createZone()
            ready = true
        }
        do {
            switch change {
            case let .write(contents): try await database.save(contents)
            case let .delete(hostID): try await database.delete(hostID: hostID)
            }
        } catch {
            switch NoticeFailure(error) {
            case .zoneMissing, .account: ready = false
            default: break
            }
            throw error
        }
    }

    /// The notice relay's backoff (`NoticeRelay`): CloudKit's `retryAfterSeconds` when it gives one
    /// (at most an hour), the account checked again after a minute, a full iCloud after 15 minutes,
    /// otherwise 2, 4, 8 … seconds up to 5 minutes.
    func backoff(after error: any Error, attempt: Int) -> TimeInterval {
        let exponential = min(pow(2, Double(min(attempt, 16))), NoticeRelay.cloudBackoffLimit)
        if error is AccountUnavailable { return NoticeRelay.accountRecheck }
        switch NoticeFailure(error) {
        case let .retry(after?): return min(max(after, 1), NoticeRelay.retryAfterLimit)
        case .account: return NoticeRelay.accountRecheck
        case .quotaExceeded: return NoticeRelay.quotaRecheck
        case .retry(nil), .zoneMissing, .alreadySaved, .rejected: return exponential
        }
    }

    struct AccountUnavailable: LocalizedError {
        let status: NoticeAccountStatus
        var errorDescription: String? { "iCloud is not available (\(status.rawValue))." }
    }
}

/// `RemoteAccessAddressDatabase` over the private database of `iCloud.dev.agentland`. Make it only
/// through `make()`, which checks the entitlement and `AGENTLAND_CLOUDKIT=0` as the notices do
/// (`NoticeCloudKit`): `CKContainer(identifier:)` stops a process that lacks the entitlement.
public final class CloudKitRemoteAccessAddressDatabase: RemoteAccessAddressDatabase, @unchecked Sendable {
    public static let zoneID = CKRecordZone.ID(zoneName: RemoteAccessAddressRecord.zoneName)

    public enum Field {
        public static let nodeID = "nodeId"
        public static let directAddresses = "directAddresses"
        public static let relayURL = "relayUrl"
        public static let revision = "revision"
        public static let sequence = "sequence"
    }

    private let container: CKContainer
    private let database: CKDatabase

    private init(container: CKContainer) {
        self.container = container
        database = container.privateCloudDatabase
    }

    /// The real database, or nil when `NoticeCloudKit.unavailability()` says this process must not use
    /// CloudKit. Only then is `CKContainer(identifier:)` called.
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> CloudKitRemoteAccessAddressDatabase? {
        guard NoticeCloudKit.unavailability(environment: environment) == nil else { return nil }
        return CloudKitRemoteAccessAddressDatabase(container: CKContainer(identifier: NoticeRecord.containerIdentifier))
    }

    public func accountStatus() async throws -> NoticeAccountStatus {
        NoticeAccountStatus(try await container.accountStatus())
    }

    public func createZone() async throws {
        let (saved, _) = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        if case let .failure(error)? = saved[Self.zoneID] { throw error }
    }

    /// The fields are encrypted values (`CKRecord.encryptedValues`), so iCloud's servers do not read
    /// the Mac's address. A field without a value is removed from the record.
    public func save(_ contents: RemoteAccessAddressRecordContents) async throws {
        let id = CKRecord.ID(recordName: contents.hostID, zoneID: Self.zoneID)
        let record = CKRecord(recordType: RemoteAccessAddressRecord.recordType, recordID: id)
        record.encryptedValues[Field.nodeID] = contents.nodeID.hex
        record.encryptedValues[Field.directAddresses] = contents.directAddresses.isEmpty ? nil : contents.directAddresses
        record.encryptedValues[Field.relayURL] = contents.relayURL
        record.encryptedValues[Field.revision] = contents.revision
        record.encryptedValues[Field.sequence] = contents.sequence
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        if case let .failure(error)? = saved[id] { throw error }
    }

    public func delete(hostID: String) async throws {
        let id = CKRecord.ID(recordName: hostID, zoneID: Self.zoneID)
        do {
            let (_, deleted) = try await database.modifyRecords(saving: [], deleting: [id], savePolicy: .allKeys, atomically: true)
            if case let .failure(error)? = deleted[id] { throw error }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return
        } catch let error as CKError where error.code == .partialFailure {
            let items = (error.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }
            if !items.isEmpty, items.allSatisfy({ $0.code == .unknownItem || $0.code == .zoneNotFound }) { return }
            throw error
        }
    }
}
