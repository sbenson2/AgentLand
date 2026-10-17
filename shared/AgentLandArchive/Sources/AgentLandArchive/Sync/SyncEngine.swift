import Foundation
import AgentLandCore

/// Where changes come from: the host's `GET /v1/archive/changes`.
public protocol ArchiveChangeFeed: Sendable {
    /// `wait` long-polls: with nothing after the cursor the host answers when
    /// a change comes or the wait ends. The engine passes it only to hosts
    /// that list `changesWait`.
    func archiveChanges(after cursor: String?, limit: Int, wait: Duration?) async throws -> ArchiveChangesPage
}

extension APIClient: ArchiveChangeFeed {}

/// Time for the engine's waits; tests inject one they control.
public protocol SyncClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Copies the host's archive into this device's `ArchiveStore` by following
/// `GET /v1/archive/changes` page by page until `hasMore` is false. Then it
/// asks again with a 20 s long-poll (`wait`) on hosts that list `changesWait`,
/// which the host answers as soon as something changes, and after
/// `followInterval` on other hosts. Each page commits with its cursor, so a
/// stop or a crash resumes where the last committed page ended.
///
/// The app model drives it and it never watches app state itself: `start()`
/// while the app is in the foreground, unlocked and the host is reachable,
/// `stop()` otherwise, and `resume(connectionEpoch:)` when the connection
/// comes back. It runs only for hosts that advertise `archive` with `sync`.
/// Failures back off (1, 2, 4 … 60 s); 401/403 stops it and reports `.refused`.
public actor SyncEngine {
    public struct Status: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            /// Not running: never started, or stopped by the app.
            case stopped
            /// The host does not keep an archive this device can copy.
            case unavailable
            /// Reading and applying pages.
            case syncing
            /// Caught up; the next pass comes after the follow interval or on resume.
            case upToDate
            /// A pass failed; the next one waits `delay`.
            case waiting(attempt: Int, delay: Duration)
            /// The host refused this device (401 or 403). It stays stopped until
            /// the app gives it new credentials with `update(feed:capabilities:)`.
            case refused
        }

        public var phase: Phase = .stopped
        public var lastSyncedAt: Date?
        /// The last failure, safe to show.
        public var lastError: String?
        public var pagesApplied = 0
        public var changesApplied = 0
        /// Changes this version could not read, skipped.
        public var unreadableChanges = 0
    }

    public static let defaultBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60)]
    /// The long-poll's wait on hosts that list `changesWait`.
    public static let changesWait: Duration = .seconds(20)
    /// A long-poll that comes back empty sooner than this (a host that is
    /// stopping answers at once) waits out the rest before the next request,
    /// so the engine never asks in a tight loop.
    public static let minimumPollGap: Duration = .seconds(1)

    public let store: ArchiveStore
    private var feed: (any ArchiveChangeFeed)?
    private var capabilities: CapabilitiesResponse?
    private let clock: any SyncClock
    private let followInterval: Duration
    private let backoff: [Duration]
    private let pageLimit: Int

    public private(set) var status = Status()
    private var wanted = false
    /// The host refused these credentials; only new ones start it again.
    private var refused = false
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    /// The generation whose long-poll is waiting on the host, if one is.
    private var pollingGeneration: Int?
    private var generation = 0
    private var failures = 0
    private var startedOver = false
    private var connectionEpoch: Int?
    private var observers: [UUID: AsyncStream<Status>.Continuation] = [:]

    public init(store: ArchiveStore, feed: (any ArchiveChangeFeed)?, capabilities: CapabilitiesResponse?,
                clock: any SyncClock = SystemSyncClock(), followInterval: Duration = .seconds(30),
                backoff: [Duration] = SyncEngine.defaultBackoff, pageLimit: Int = APIClient.archiveChangesPageLimit) {
        self.store = store
        self.feed = feed
        self.capabilities = capabilities
        self.clock = clock
        self.followInterval = followInterval
        self.backoff = backoff.isEmpty ? SyncEngine.defaultBackoff : backoff
        self.pageLimit = pageLimit
    }

    /// Whether the host advertises archive sync.
    public var isSupported: Bool { capabilities?.supportsArchive(.sync) == true }

    /// Whether the host takes `wait` on the change feed.
    private var longPolls: Bool { capabilities?.supportsArchive(.changesWait) == true }

    /// Starts following the host's changes, if it offers them.
    public func start() {
        wanted = true
        guard loop == nil else { return }
        launch()
    }

    /// Stops following. The cursor stays, so the next start continues from it.
    public func stop() {
        wanted = false
        cancelLoop()
        if !refused { status.phase = .stopped }
        broadcast()
    }

    /// The connection came back: a new `connectionEpoch` syncs at once,
    /// without waiting out a backoff or a long-poll sent over the old
    /// connection. The same epoch again changes nothing.
    public func resume(connectionEpoch: Int) {
        guard connectionEpoch != self.connectionEpoch else { return }
        self.connectionEpoch = connectionEpoch
        failures = 0
        wake()
    }

    /// Syncs now instead of at the next interval or the end of a long-poll
    /// (for example on pull to refresh).
    public func syncNow() { wake() }

    /// A new client (a restarted host or a new pairing) or new capabilities.
    /// A running engine starts over with them, from its stored cursor.
    public func update(feed: (any ArchiveChangeFeed)?, capabilities: CapabilitiesResponse?) {
        self.feed = feed
        self.capabilities = capabilities
        refused = false
        guard wanted else { return }
        cancelLoop()
        failures = 0
        launch()
    }

    /// The current status first, then every change.
    public func statusUpdates() -> AsyncStream<Status> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(status)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    // MARK: Loop

    private func wake() {
        guard wanted, !refused else { return }
        if loop == nil {
            launch()
        } else if pollingGeneration == generation {
            // A long-poll may wait on a connection that is gone: ask again now.
            cancelLoop()
            launch()
        } else {
            sleeper?.cancel()
        }
    }

    private func launch() {
        guard !refused else { return }
        guard isSupported, feed != nil else {
            status.phase = .unavailable
            broadcast()
            return
        }
        generation += 1
        let generation = generation
        loop = Task { [weak self] in await self?.run(generation) }
    }

    private func cancelLoop() {
        generation += 1
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
    }

    private func run(_ generation: Int) async {
        defer { if generation == self.generation { loop = nil } }
        // Caught up: the next pass may long-poll. A pass after a start, a
        // wake or a failure asks without waiting first.
        var caughtUp = false
        while !Task.isCancelled, generation == self.generation {
            do {
                let early = try await drain(generation, waiting: caughtUp && longPolls)
                failures = 0
                startedOver = false
                status.phase = .upToDate
                status.lastError = nil
                broadcast()
                if longPolls {
                    caughtUp = true
                    if early { await pause(Self.minimumPollGap) }
                } else {
                    await pause(followInterval)
                }
            } catch {
                caughtUp = false
                guard !Task.isCancelled, generation == self.generation, !(error is CancellationError) else { return }
                switch Self.classify(error) {
                case let .refused(message):
                    refused = true
                    status.phase = .refused
                    status.lastError = message
                    broadcast()
                    return
                case .unavailable:
                    status.phase = .unavailable
                    broadcast()
                    return
                case .startOver where !startedOver:
                    // The host no longer knows the cursor: copy everything again.
                    startedOver = true
                    do { try await store.startOver() } catch { await retry(after: error) }
                case .startOver:
                    await retry(after: error)
                case .retry:
                    await retry(after: error)
                }
            }
        }
    }

    private func retry(after error: Error) async {
        failures += 1
        let delay = backoff[min(failures, backoff.count) - 1]
        status.phase = .waiting(attempt: failures, delay: delay)
        status.lastError = Self.message(error)
        broadcast()
        await pause(delay)
    }

    /// Reads pages until the host has no more, committing each with its
    /// cursor. With `waiting` the first request long-polls, and the status
    /// stays up to date until changes arrive. Returns whether that long-poll
    /// came back empty sooner than `minimumPollGap`.
    private func drain(_ generation: Int, waiting: Bool) async throws -> Bool {
        guard let feed else { throw CancellationError() }
        if !waiting {
            status.phase = .syncing
            broadcast()
        }
        var cursor = try await store.syncState().cursor
        var wait = waiting ? Self.changesWait : nil
        while true {
            try Task.checkCancellation()
            let asked = clock.now()
            pollingGeneration = wait == nil ? nil : generation
            let page: ArchiveChangesPage
            do {
                page = try await feed.archiveChanges(after: cursor, limit: pageLimit, wait: wait)
            } catch {
                if pollingGeneration == generation { pollingGeneration = nil }
                throw error
            }
            if pollingGeneration == generation { pollingGeneration = nil }
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            let empty = page.changes.isEmpty && !page.resync
            if wait != nil, !empty || page.hasMore {
                status.phase = .syncing
                broadcast()
            }
            let result = try await store.apply(page, at: clock.now())
            status.pagesApplied += 1
            status.changesApplied += result.applied
            status.unreadableChanges += result.unreadable
            status.lastSyncedAt = clock.now()
            broadcast()
            let next = page.cursor.isEmpty ? nil : page.cursor
            // A page that claims more but neither moves the cursor nor carries
            // changes would loop; treat it as the end.
            let moved = next != cursor || !page.changes.isEmpty
            cursor = next
            let early = wait != nil && empty && !page.hasMore
                && clock.now().timeIntervalSince(asked) < Self.minimumPollGap.timeInterval
            wait = nil
            guard page.hasMore, moved else { return early }
        }
    }

    /// Waits, or returns early when woken.
    private func pause(_ duration: Duration) async {
        let clock = clock
        let task = Task { try await clock.sleep(for: duration) }
        sleeper = task
        _ = try? await task.value
        if sleeper == task { sleeper = nil }
    }

    private func broadcast() {
        for continuation in observers.values { continuation.yield(status) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    // MARK: Failures

    enum Failure: Equatable {
        case refused(String)
        case unavailable
        case startOver
        case retry
    }

    static func classify(_ error: Error) -> Failure {
        guard let error = error as? ClientError else { return .retry }
        switch error {
        case let .server(code, message):
            switch code {
            case "unauthorized", "forbidden", "origin_rejected", "local_only": return .refused(message)
            case "archive_unavailable": return .unavailable
            case "invalid_cursor": return .startOver
            default: return .retry
            }
        case .unexpectedStatus(401), .unexpectedStatus(403): return .refused(error.localizedDescription)
        case .unexpectedStatus(501): return .unavailable
        default: return .retry
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
