import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandArchive

/// A clock whose sleeps end only when the test says so. Its time moves only
/// when the test passes some.
final class ManualClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var log: [Duration] = []
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var elapsed: TimeInterval = 0

    var requested: [Duration] { lock.withLock { log } }
    var waiting: Int { lock.withLock { pending.count } }

    func now() -> Date { lock.withLock { start.addingTimeInterval(elapsed) } }
    func pass(seconds: TimeInterval) { lock.withLock { elapsed += seconds } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    log.append(duration)
                    pending.append((id, continuation))
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
                return pending.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest sleep.
    func advance() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst().continuation }
        next?.resume()
    }
}

/// A change feed answering from a script: pages or errors, in order; once
/// the script runs out it keeps answering with an empty last page.
final class ScriptedFeed: ArchiveChangeFeed, @unchecked Sendable {
    enum Answer { case page(ArchiveChangesPage), failure(Error) }
    private let lock = NSLock()
    private var answers: [Answer]
    private var cursors: [String?] = []
    private var waits: [Duration?] = []

    init(_ answers: [Answer]) { self.answers = answers }

    var requestedCursors: [String?] { lock.withLock { cursors } }
    var requestedWaits: [Duration?] { lock.withLock { waits } }
    var calls: Int { lock.withLock { cursors.count } }
    func add(_ answer: Answer) { lock.withLock { answers.append(answer) } }

    func archiveChanges(after cursor: String?, limit: Int, wait: Duration?) async throws -> ArchiveChangesPage {
        let answer = lock.withLock { () -> Answer in
            cursors.append(cursor)
            waits.append(wait)
            return answers.isEmpty ? .page(ArchiveChangesPage(epoch: "e1", changes: [], cursor: cursor ?? "e1.0")) : answers.removeFirst()
        }
        switch answer {
        case let .page(page): return page
        case let .failure(error): throw error
        }
    }
}

/// A host that long-polls: a request with `wait` holds until the test queues
/// an answer or the request is cancelled. Requests without `wait` answer at
/// once, with an empty page at their cursor when nothing is queued.
final class LongPollFeed: ArchiveChangeFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ScriptedFeed.Answer]
    private var log: [(cursor: String?, wait: Duration?)] = []
    private var held = 0
    private var cancelled = 0

    init(_ answers: [ScriptedFeed.Answer] = []) { self.answers = answers }

    var requests: [(cursor: String?, wait: Duration?)] { lock.withLock { log } }
    /// Long-polls waiting for an answer now.
    var holding: Int { lock.withLock { held } }
    var cancellations: Int { lock.withLock { cancelled } }
    func add(_ answer: ScriptedFeed.Answer) { lock.withLock { answers.append(answer) } }

    private func take() -> ScriptedFeed.Answer? { lock.withLock { answers.isEmpty ? nil : answers.removeFirst() } }

    func archiveChanges(after cursor: String?, limit: Int, wait: Duration?) async throws -> ArchiveChangesPage {
        lock.withLock { log.append((cursor, wait)) }
        var answer = take()
        if answer == nil, wait != nil {
            lock.withLock { held += 1 }
            defer { lock.withLock { held -= 1 } }
            do {
                while answer == nil {
                    try await Task.sleep(for: .milliseconds(2))
                    answer = take()
                }
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
        }
        switch answer ?? .page(ArchiveChangesPage(epoch: "e1", changes: [], cursor: cursor ?? "e1.0")) {
        case let .page(page): return page
        case let .failure(error): throw error
        }
    }
}

final class SyncEngineTests: XCTestCase {
    private let syncing = CapabilitiesResponse(interactions: true, terminal: true, archive: ArchiveCapabilities(features: ["sync", "search"]))
    private let longPolling = CapabilitiesResponse(interactions: true, terminal: true, archive: ArchiveCapabilities(features: ["sync", "search", "changesWait"]))

    private func waitFor(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let met = await condition()
        XCTAssertTrue(met, "Timed out waiting for \(what)", file: file, line: line)
    }

    func testFollowsPagesUntilTheHostHasNoMoreThenWaitsTheInterval() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = ScriptedFeed([
            .page(Fixture.page([Fixture.chat("ses_1")], cursor: "e1.1", hasMore: true)),
            .page(Fixture.page([Fixture.message("u1", chat: "ses_1", ord: 1, text: "one")], cursor: "e1.2", hasMore: true, firstSeq: 2)),
            .page(Fixture.page([Fixture.log("t1")], cursor: "e1.3", firstSeq: 3))
        ])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock, followInterval: .seconds(30))
        await engine.start()
        await waitFor("the follow wait") { clock.waiting == 1 }
        XCTAssertEqual(feed.requestedCursors, [nil, "e1.1", "e1.2"])
        XCTAssertEqual(feed.requestedWaits, [nil, nil, nil], "A host without changesWait never gets wait")
        XCTAssertEqual(clock.requested, [.seconds(30)])
        let status = await engine.status
        XCTAssertEqual(status.phase, .upToDate)
        XCTAssertEqual(status.pagesApplied, 3)
        XCTAssertEqual(status.changesApplied, 3)
        let state = try await store.syncState()
        XCTAssertEqual(state.cursor, "e1.3")

        // After the interval it asks again from the stored cursor.
        clock.advance()
        await waitFor("the next pass") { feed.calls == 4 }
        XCTAssertEqual(feed.requestedCursors.last, "e1.3")
        await engine.stop()
        let stopped = await engine.status.phase
        XCTAssertEqual(stopped, .stopped)
    }

    // MARK: Long-polls (hosts that list changesWait)

    func testCaughtUpItLongPollsInsteadOfTheTimer() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = LongPollFeed([.page(Fixture.starter)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: longPolling, clock: clock, followInterval: .seconds(30))
        await engine.start()
        await waitFor("the long-poll") { feed.holding == 1 }
        XCTAssertEqual(feed.requests.map(\.cursor), [nil, "e1.6"])
        XCTAssertEqual(feed.requests.map(\.wait), [nil, .seconds(20)], "The first pass asks without waiting")
        XCTAssertTrue(clock.requested.isEmpty, "No 30 s timer")
        var phase = await engine.status.phase
        XCTAssertEqual(phase, .upToDate, "A waiting request is not syncing")

        // A change answers the waiting request; the engine applies it and waits again.
        feed.add(.page(Fixture.page([Fixture.chat("ses_3")], cursor: "e1.7", firstSeq: 7)))
        await waitFor("the change") { (try? await store.chat(id: "ses_3")) != nil }
        await waitFor("the next long-poll") { feed.holding == 1 && feed.requests.count == 3 }
        XCTAssertEqual(feed.requests.last?.cursor, "e1.7")
        XCTAssertEqual(feed.requests.last?.wait, .seconds(20))
        XCTAssertTrue(clock.requested.isEmpty)

        // A wait that ends with nothing asks again at once.
        clock.pass(seconds: 20)
        feed.add(.page(Fixture.page([], cursor: "e1.7")))
        await waitFor("the long-poll after an empty answer") { feed.holding == 1 && feed.requests.count == 4 }
        XCTAssertTrue(clock.requested.isEmpty, "A full wait needs no gap")
        let state = try await store.syncState()
        XCTAssertEqual(state.cursor, "e1.7")

        // Stop ends the waiting request; start asks without waiting first.
        await engine.stop()
        await waitFor("the long-poll cancelled") { feed.cancellations == 1 && feed.holding == 0 }
        phase = await engine.status.phase
        XCTAssertEqual(phase, .stopped)
        await engine.start()
        await waitFor("the long-poll after a start") { feed.holding == 1 && feed.requests.count == 6 }
        XCTAssertEqual(feed.requests.suffix(2).map(\.wait), [nil, .seconds(20)])
        await engine.stop()
    }

    func testAnEarlyEmptyAnswerWaitsTheMinimumGap() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = LongPollFeed([.page(Fixture.starter)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: longPolling, clock: clock)
        await engine.start()
        await waitFor("the long-poll") { feed.holding == 1 }
        // A host that is stopping answers at once with nothing.
        feed.add(.page(Fixture.page([], cursor: "e1.6")))
        await waitFor("the gap") { clock.waiting == 1 }
        XCTAssertEqual(clock.requested, [SyncEngine.minimumPollGap])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(feed.requests.count, 2, "Nothing is asked during the gap")
        clock.advance()
        await waitFor("the next long-poll") { feed.holding == 1 && feed.requests.count == 3 }
        XCTAssertEqual(feed.requests.last?.wait, .seconds(20))
        await engine.stop()
    }

    func testAFailedLongPollBacksOffThenAsksWithoutWaiting() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = LongPollFeed([.page(Fixture.starter)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: longPolling, clock: clock)
        await engine.start()
        await waitFor("the long-poll") { feed.holding == 1 }
        feed.add(.failure(URLError(.networkConnectionLost)))
        await waitFor("the backoff") { clock.waiting == 1 }
        XCTAssertEqual(clock.requested, [.seconds(1)])
        let phase = await engine.status.phase
        XCTAssertEqual(phase, .waiting(attempt: 1, delay: .seconds(1)))
        clock.advance()
        await waitFor("a plain pass, then the long-poll") { feed.holding == 1 && feed.requests.count == 4 }
        XCTAssertEqual(feed.requests.map(\.wait), [nil, .seconds(20), nil, .seconds(20)])
        let recovered = await engine.status.phase
        XCTAssertEqual(recovered, .upToDate)
        await engine.stop()
    }

    func testResumeAsksAgainInsteadOfAWaitingLongPoll() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = LongPollFeed([.page(Fixture.starter)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: longPolling, clock: clock)
        await engine.start()
        await waitFor("the long-poll") { feed.holding == 1 }
        // The connection came back: the waiting request may hang on the old one.
        await engine.resume(connectionEpoch: 1)
        await waitFor("asked again at once") { feed.cancellations == 1 && feed.holding == 1 && feed.requests.count == 4 }
        XCTAssertEqual(feed.requests.map(\.wait), [nil, .seconds(20), nil, .seconds(20)])
        // So does syncNow.
        await engine.syncNow()
        await waitFor("asked again") { feed.cancellations == 2 && feed.holding == 1 && feed.requests.count == 6 }
        XCTAssertTrue(clock.requested.isEmpty)
        await engine.stop()
    }

    func testFailuresBackOffUpToAMinuteAndNeverLoopHot() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = ScriptedFeed(Array(repeating: .failure(URLError(.timedOut)), count: 8) + [.page(Fixture.starter)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock, followInterval: .seconds(30))
        await engine.start()
        let expected: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60)]
        for (attempt, delay) in expected.enumerated() {
            await waitFor("backoff \(attempt + 1)") { clock.waiting == 1 && clock.requested.count == attempt + 1 }
            XCTAssertEqual(clock.requested.last, delay)
            XCTAssertEqual(feed.calls, attempt + 1, "One request per attempt")
            let phase = await engine.status.phase
            XCTAssertEqual(phase, .waiting(attempt: attempt + 1, delay: delay))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(feed.calls, attempt + 1, "Nothing is sent while it waits")
            clock.advance()
        }
        await waitFor("caught up") { await engine.status.phase == .upToDate }
        XCTAssertEqual(clock.requested.last, .seconds(30))
        let error = await engine.status.lastError
        XCTAssertNil(error)
        await engine.stop()
    }

    func testANewConnectionEpochSkipsTheBackoffAndResetsIt() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = ScriptedFeed(Array(repeating: .failure(URLError(.networkConnectionLost)), count: 4))
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock)
        await engine.start()
        for attempt in 1...3 {
            await waitFor("backoff \(attempt)") { clock.requested.count == attempt && clock.waiting == 1 }
            if attempt < 3 { clock.advance() }
        }
        XCTAssertEqual(clock.requested.last, .seconds(4))
        await engine.resume(connectionEpoch: 1)
        await waitFor("woken at once") { feed.calls == 4 }
        await waitFor("the next backoff") { clock.requested.count == 4 }
        XCTAssertEqual(clock.requested.last, .seconds(1), "Recovery starts the backoff over")
        // The same epoch again does nothing.
        await engine.resume(connectionEpoch: 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(feed.calls, 4)
        await engine.stop()
    }

    func testARefusedDeviceStopsAndReports() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = ScriptedFeed([.failure(ClientError.server(code: "unauthorized", message: "Valid bearer authentication is required"))])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock)
        var updates: [SyncEngine.Status.Phase] = []
        let stream = await engine.statusUpdates()
        let collector = Task {
            for await status in stream {
                updates.append(status.phase)
                if status.phase == .refused { return updates }
            }
            return updates
        }
        await engine.start()
        let phases = await collector.value
        XCTAssertEqual(phases.first, .stopped)
        XCTAssertEqual(phases.last, .refused)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(feed.calls, 1)
        XCTAssertTrue(clock.requested.isEmpty, "No retry after 401")
        let error = await engine.status.lastError
        XCTAssertEqual(error, "Valid bearer authentication is required")
        // Resume does not restart a refused device; new credentials do.
        await engine.resume(connectionEpoch: 7)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(feed.calls, 1)
        let fresh = ScriptedFeed([.page(Fixture.starter)])
        await engine.update(feed: fresh, capabilities: syncing)
        await waitFor("new credentials sync") { fresh.calls == 1 }
        await engine.stop()

        XCTAssertEqual(SyncEngine.classify(ClientError.unexpectedStatus(403)), .refused(ClientError.unexpectedStatus(403).localizedDescription))
        XCTAssertEqual(SyncEngine.classify(ClientError.server(code: "origin_rejected", message: "no")), .refused("no"))
        XCTAssertEqual(SyncEngine.classify(ClientError.server(code: "archive_unavailable", message: "no")), .unavailable)
        XCTAssertEqual(SyncEngine.classify(URLError(.timedOut)), .retry)
    }

    func testRunsOnlyForHostsThatAdvertiseSync() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = ScriptedFeed([])
        let without = CapabilitiesResponse(interactions: true, terminal: true, archive: ArchiveCapabilities(features: ["search"]))
        let engine = SyncEngine(store: store, feed: feed, capabilities: without, clock: ManualClock())
        await engine.start()
        let phase = await engine.status.phase
        XCTAssertEqual(phase, .unavailable)
        XCTAssertEqual(feed.calls, 0)
        let older = SyncEngine(store: store, feed: feed, capabilities: CapabilitiesResponse(interactions: true, terminal: true), clock: ManualClock())
        await older.start()
        XCTAssertEqual(feed.calls, 0)
    }

    func testStopKeepsTheCursorAndStartContinuesFromIt() async throws {
        let store = try ArchiveStore.inMemory()
        let feed = ScriptedFeed([.page(Fixture.starter)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock)
        await engine.start()
        await waitFor("caught up") { await engine.status.phase == .upToDate }
        await engine.stop()
        XCTAssertEqual(clock.waiting, 0, "Stopping ends the wait")
        feed.add(.page(Fixture.page([Fixture.chat("ses_3")], cursor: "e1.7", firstSeq: 7)))
        await engine.start()
        await waitFor("second pass") { feed.calls == 2 }
        XCTAssertEqual(feed.requestedCursors, [nil, "e1.6"])
        await waitFor("applied") { (try? await store.chat(id: "ses_3")) != nil }
        await engine.stop()
    }

    func testAResyncPageClearsTheCopyAndARefusedCursorStartsOver() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.starter)
        let feed = ScriptedFeed([
            .failure(ClientError.server(code: "invalid_cursor", message: "The archive cursor is not valid")),
            .page(Fixture.page([Fixture.chat("ses_new", title: "Only this")], cursor: "e2.1", epoch: "e2", resync: true))
        ])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock)
        await engine.start()
        await waitFor("caught up") { await engine.status.phase == .upToDate }
        XCTAssertEqual(feed.requestedCursors, ["e1.6", nil], "A refused cursor starts over from the beginning")
        let chats = try await store.chats()
        XCTAssertEqual(chats.map(\.id), ["ses_new"])
        XCTAssertEqual(clock.requested, [.seconds(30)], "Starting over is not a failure to wait out")
        await engine.stop()
    }

    func testAPageThatClaimsMoreButDoesNotMoveEndsThePass() async throws {
        let store = try ArchiveStore.inMemory()
        let stuck = ArchiveChangesPage(epoch: "e1", changes: [], cursor: "e1.0", hasMore: true)
        let feed = ScriptedFeed([.page(Fixture.page([Fixture.chat("a")], cursor: "e1.0", hasMore: true)), .page(stuck), .page(stuck), .page(stuck)])
        let clock = ManualClock()
        let engine = SyncEngine(store: store, feed: feed, capabilities: syncing, clock: clock)
        await engine.start()
        await waitFor("the follow wait") { clock.waiting == 1 }
        XCTAssertEqual(feed.calls, 2, "An empty page at the same cursor ends the pass instead of looping")
        await engine.stop()
    }
}
