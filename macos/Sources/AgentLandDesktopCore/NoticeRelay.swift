import Foundation
import Synchronization
import AgentLandCore
import AgentLandNotifications

/// Time for the relay; tests move it by hand.
public protocol NoticeRelayClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemNoticeRelayClock: NoticeRelayClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Turns the host's notices into CloudKit records in the owner's private
/// database, where iPhone and iPad subscriptions turn them into alerts.
///
/// While it runs (the owner's app starts it only while its managed host runs,
/// sending is on and CloudKit is available) it:
/// - checks the iCloud account and creates the `Notices` zone,
/// - long-polls `GET /v1/notices?after&wait=20000` with the app's local session,
/// - writes each page's notices in one modify operation, under deterministic
///   record names, so a retry updates instead of adding a record,
/// - drops notices older than 10 minutes, of unknown kinds, or from before
///   sending was turned on, instead of alerting late,
/// - acknowledges (`POST /v1/notices/ack`) only notices written or dropped
///   on purpose, in order: after a failure it starts again after the last
///   acknowledged notice,
/// - honors CloudKit's `retryAfterSeconds` and backs off on other errors,
/// - deletes this host's records older than 24 hours once an hour.
///
/// Stopping cancels the loop and never waits more than a second for it.
public actor NoticeRelay {
    public struct Settings: Equatable, Sendable {
        /// Off: a title that may contain chat content is left out.
        public var includeTitles: Bool
        /// Notices issued before this are dropped (sending was just turned on).
        public var notBefore: Date?

        public init(includeTitles: Bool = true, notBefore: Date? = nil) {
            self.includeTitles = includeTitles
            self.notBefore = notBefore
        }
    }

    public enum Problem: Equatable, Sendable {
        /// The host's notice feed failed.
        case host(String)
        /// This host keeps no notices (or is older than notices).
        case hostWithoutNotices
        /// The iCloud account cannot be used now.
        case account(NoticeAccountStatus)
        /// The owner's iCloud storage is full.
        case quotaExceeded
        /// Another CloudKit failure.
        case iCloud(String)
    }

    public enum Phase: Equatable, Sendable {
        case stopped
        case running
        /// Backing off after a problem until the date.
        case waiting(Problem, until: Date)
    }

    public struct Status: Equatable, Sendable {
        public var phase: Phase = .stopped
        /// Notices written since the relay started.
        public var written = 0
        /// Notices dropped on purpose since the relay started.
        public var dropped = 0
        public var lastWrittenAt: Date?
        public var lastCleanupAt: Date?
        /// Why the last cleanup failed; cleared by the next one that works.
        public var cleanupProblem: String?

        public init() {}
    }

    public static let staleAfter: TimeInterval = 10 * 60
    public static let retention: TimeInterval = 24 * 60 * 60
    public static let cleanupInterval: TimeInterval = 60 * 60
    public static let cleanupLimit = 1_000
    public static let pollWaitMilliseconds = 20_000
    static let accountRecheck: TimeInterval = 60
    static let quotaRecheck: TimeInterval = 15 * 60
    static let missingFeedRecheck: TimeInterval = 10 * 60
    static let hostBackoffLimit: TimeInterval = 60
    static let cloudBackoffLimit: TimeInterval = 5 * 60
    static let retryAfterLimit: TimeInterval = 60 * 60
    static let emptyAnswerPause: TimeInterval = 1
    static let stopWait: Duration = .seconds(1)

    private let hostID: String
    private let feed: any NoticeFeed
    private let database: any NoticeDatabase
    private let clock: any NoticeRelayClock
    private let onStatus: @Sendable (Status) -> Void
    private var settings: Settings
    private var task: Task<Void, Never>?
    private var ended = false
    private var cursor: String?
    private var accountReady = false
    private var zoneReady = false
    private var nextCleanup: Date?
    public private(set) var status = Status() { didSet { if status != oldValue { onStatus(status) } } }

    public init(hostID: String, feed: any NoticeFeed, database: any NoticeDatabase, settings: Settings = Settings(),
                clock: any NoticeRelayClock = SystemNoticeRelayClock(), onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.hostID = hostID
        self.feed = feed
        self.database = database
        self.settings = settings
        self.clock = clock
        self.onStatus = onStatus
    }

    /// Starts the loop once; a relay that was stopped never starts again.
    public func start() {
        guard task == nil, !ended else { return }
        status.phase = .running
        task = Task { await self.run() }
    }

    /// Cancels the loop and waits at most a second for it: an HTTP request
    /// or CloudKit call in flight never holds up Quit or Disconnect.
    public func stop() async {
        ended = true
        guard let task else { return }
        self.task = nil
        task.cancel()
        await Self.wait(for: task, atMost: Self.stopWait)
        status.phase = .stopped
    }

    public func setIncludeTitles(_ include: Bool) { settings.includeTitles = include }

    // MARK: Loop

    private enum Failure: Error {
        case feed(any Error)
        case account(NoticeAccountStatus)
        case cloud(any Error)
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await prepare()
                await cleanUpIfDue()
                try Task.checkCancellation()
                let asked = clock.now()
                let page: HostNoticePage
                do { page = try await feed.notices(after: cursor, waitMilliseconds: Self.pollWaitMilliseconds) }
                catch { throw Failure.feed(error) }
                try Task.checkCancellation()
                try await relay(page)
                attempt = 0
                if !Task.isCancelled, status.phase != .running { status.phase = .running }
                // A host that is stopping answers at once with nothing instead
                // of waiting; do not ask again in a tight loop.
                if page.notices.isEmpty, clock.now().timeIntervalSince(asked) < Self.emptyAnswerPause {
                    try await clock.sleep(for: .seconds(Self.emptyAnswerPause))
                }
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                attempt += 1
                let (delay, problem) = backoff(after: error, attempt: attempt)
                status.phase = .waiting(problem, until: clock.now().addingTimeInterval(delay))
                do { try await clock.sleep(for: .milliseconds(Int64(delay * 1000))) } catch { break }
            }
        }
    }

    private func prepare() async throws {
        if !accountReady {
            let account: NoticeAccountStatus
            do { account = try await database.accountStatus() } catch { throw Failure.cloud(error) }
            guard account == .available else { throw Failure.account(account) }
            accountReady = true
        }
        if !zoneReady {
            do { try await database.createZone() } catch { throw Failure.cloud(error) }
            zoneReady = true
        }
    }

    /// Writes a page and acknowledges what was written or dropped.
    private func relay(_ page: HostNoticePage) async throws {
        let now = clock.now()
        var pending: [(seq: Int64, record: NoticeRecord)] = []
        var dropped = 0
        for notice in page.notices {
            if let record = record(for: notice, now: now) { pending.append((notice.seq, record)) } else { dropped += 1 }
        }
        var failed: [Int64: any Error] = [:]
        var written = 0
        if !pending.isEmpty {
            let results: [String: Result<Void, any Error>]
            do { results = try await database.save(pending.map(\.record)) } catch { throw Failure.cloud(error) }
            for (seq, record) in pending {
                switch results[record.recordName] {
                case .success?: written += 1
                case let .failure(error)?:
                    switch NoticeFailure(error) {
                    case .alreadySaved: written += 1
                    case .rejected: dropped += 1 // it can never be written
                    default: failed[seq] = error
                    }
                case nil: failed[seq] = MissingResult()
                }
            }
        }
        status.written += written
        status.dropped += dropped
        if written > 0 { status.lastWrittenAt = now }

        // Acknowledge the notices before the first that failed.
        let firstFailure = page.notices.first { failed[$0.seq] != nil }?.seq
        let handled = page.notices.map(\.seq).filter { firstFailure == nil || $0 < firstFailure! }
        if let through = handled.max() {
            // A lost acknowledgement only means the host serves those notices
            // again, and writing them again updates the same records.
            try? await feed.acknowledge(through: through)
        }
        guard let firstFailure, let error = failed[firstFailure] else {
            cursor = page.cursor
            return
        }
        // Start again after the acknowledged notices.
        cursor = nil
        let failures = Array(failed.values)
        if let retryAfter = failures.compactMap(\.noticeRetryAfter).max() {
            throw Failure.cloud(RetryAfter(seconds: retryAfter, underlying: error))
        }
        if let missingZone = failures.first(where: { NoticeFailure($0) == .zoneMissing }) { throw Failure.cloud(missingZone) }
        if let account = failures.first(where: { NoticeFailure($0) == .account }) { throw Failure.cloud(account) }
        throw Failure.cloud(error)
    }

    /// The record for a notice, or nil to drop it.
    private func record(for notice: HostNotice, now: Date) -> NoticeRecord? {
        guard let kind = NoticeKind(rawValue: notice.kind), !notice.projectID.isEmpty,
              let created = notice.createdDate, now.timeIntervalSince(created) <= Self.staleAfter else { return nil }
        if let notBefore = settings.notBefore, created < notBefore { return nil }
        let title = settings.includeTitles || !notice.mayContainContent ? notice.title : nil
        return NoticeRecord(recordName: NoticeRecord.recordName(hostID: hostID, noticeID: notice.id), kind: kind, hostID: hostID,
                            projectID: notice.projectID, projectName: notice.projectName, sessionID: notice.sessionID,
                            title: title, createdAt: created)
    }

    private func cleanUpIfDue() async {
        let now = clock.now()
        if let nextCleanup, now < nextCleanup { return }
        nextCleanup = now.addingTimeInterval(Self.cleanupInterval)
        do {
            _ = try await database.deleteRecords(hostID: hostID, createdBefore: now.addingTimeInterval(-Self.retention),
                                                 limit: Self.cleanupLimit)
            status.lastCleanupAt = now
            status.cleanupProblem = nil
        } catch {
            guard !Task.isCancelled else { return }
            if NoticeFailure(error) == .zoneMissing { zoneReady = false }
            status.cleanupProblem = Self.describe(error)
        }
    }

    /// How long to wait after a failure, and why.
    private func backoff(after error: any Error, attempt: Int) -> (TimeInterval, Problem) {
        let exponential = { (limit: TimeInterval) in min(pow(2, Double(min(attempt, 16))), limit) }
        switch error {
        case let Failure.account(status):
            accountReady = false
            return (Self.accountRecheck, .account(status))
        case let Failure.feed(error):
            if case let .server(code, _)? = error as? ClientError, code == "notices_unavailable" || code == "not_found" {
                return (Self.missingFeedRecheck, .hostWithoutNotices)
            }
            if case .unexpectedStatus(404)? = error as? ClientError { return (Self.missingFeedRecheck, .hostWithoutNotices) }
            return (exponential(Self.hostBackoffLimit), .host(Self.describe(error)))
        case let Failure.cloud(error):
            if let retry = error as? RetryAfter {
                return (min(max(retry.seconds, 1), Self.retryAfterLimit), .iCloud(Self.describe(retry.underlying)))
            }
            switch NoticeFailure(error) {
            case let .retry(after?):
                return (min(max(after, 1), Self.retryAfterLimit), .iCloud(Self.describe(error)))
            case .zoneMissing:
                zoneReady = false
                return (exponential(Self.cloudBackoffLimit), .iCloud(Self.describe(error)))
            case .account:
                accountReady = false
                return (Self.accountRecheck, .account(.couldNotDetermine))
            case .quotaExceeded:
                return (Self.quotaRecheck, .quotaExceeded)
            case .retry(nil), .alreadySaved, .rejected:
                return (exponential(Self.cloudBackoffLimit), .iCloud(Self.describe(error)))
            }
        default:
            return (exponential(Self.cloudBackoffLimit), .iCloud(Self.describe(error)))
        }
    }

    private struct RetryAfter: Error {
        let seconds: TimeInterval
        let underlying: any Error
    }

    /// The server's answer did not mention a record; it was not saved.
    private struct MissingResult: Error {}

    static func describe(_ error: any Error) -> String {
        redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, limit: 300)
    }

    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await task.value; if once.claim() { continuation.resume() } }
            Task { try? await Task.sleep(for: limit); if once.claim() { continuation.resume() } }
        }
    }

    private final class Once: Sendable {
        private let claimed = Mutex(false)
        /// True the first time only.
        func claim() -> Bool { claimed.withLock { done in defer { done = true }; return !done } }
    }
}

public extension NoticeRelay {
    /// Writes the notice "Send Test Notification" sends: kind
    /// `chat.turn.finished`, titled "Test from AgentLand", in the project.
    static func sendTestNotice(database: any NoticeDatabase, hostID: String, projectID: String, projectName: String,
                               now: Date = Date()) async throws {
        let account = try await database.accountStatus()
        guard account == .available else { throw TestNoticeError.account(account) }
        try await database.createZone()
        let record = NoticeRecord(recordName: NoticeRecord.testRecordName(hostID: hostID), kind: .turnFinished, hostID: hostID,
                                  projectID: projectID, projectName: projectName, title: NoticeAlertText.testTitle, createdAt: now)
        let results = try await database.save([record])
        if case let .failure(error)? = results[record.recordName] { throw error }
    }

    enum TestNoticeError: Error, Equatable { case account(NoticeAccountStatus) }
}
