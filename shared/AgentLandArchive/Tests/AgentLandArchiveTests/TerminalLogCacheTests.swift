import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandArchive

/// A host serving one log's bytes in ranges, as `terminal-log` does.
final class LogHost: TerminalLogFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var content: Data
    private var state: String
    private var log: [(offset: Int64, length: Int, format: ArchiveTerminalLogFormat)] = []
    var offline = false

    init(_ content: Data, status: String = "exited") {
        self.content = content
        state = status
    }

    var requests: [(offset: Int64, length: Int, format: ArchiveTerminalLogFormat)] { lock.withLock { log } }
    func write(_ more: Data) { lock.withLock { content.append(more) } }
    func end() { lock.withLock { state = "exited" } }

    func archiveTerminalLog(id: String, offset: Int64, length: Int, format: ArchiveTerminalLogFormat) async throws -> ArchiveTerminalLogRange {
        let (content, status, offline) = lock.withLock { () -> (Data, String, Bool) in
            log.append((offset, length, format))
            return (self.content, state, self.offline)
        }
        if offline { throw URLError(.notConnectedToInternet) }
        let start = Int(min(offset, Int64(content.count)))
        let end = min(content.count, start + length)
        var data = content.subdata(in: start..<end)
        if format == .text {
            data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1B}[31m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: "").utf8)
        }
        return ArchiveTerminalLogRange(data: data, offset: offset, next: Int64(end), eof: status != "running" && end >= content.count,
                                       size: Int64(content.count), status: status)
    }
}

/// A clock that moves one second per reading.
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    func tick() -> Date { lock.withLock { current = current.addingTimeInterval(1); return current } }
}

final class TerminalLogCacheTests: XCTestCase {
    private func log(_ id: String = "t1", bytes: Int, status: String = "exited", gap: Int64 = 0) -> ArchivedTerminalLog {
        ArchivedTerminalLog(id: id, projectID: "p1", title: "Build", program: "shell", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                            status: status, exitCode: status == "running" ? nil : 0, bytes: Int64(bytes), gapBytes: gap)
    }

    private func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(65 + $0 % 26) }) }

    func testRangesAreFetchedOnceThenServedFromTheDevice() async throws {
        let folder = try TemporaryFolder()
        let cache = try TerminalLogCache(location: folder.location("logs"), chunkLength: 16)
        let host = LogHost(bytes(40))
        let entry = log(bytes: 40)
        let first = try await cache.chunk(of: entry, at: 0, format: .raw, fetcher: host)
        XCTAssertFalse(first.fromCache)
        XCTAssertEqual(first.data, bytes(16))
        XCTAssertEqual(first.next, 16)
        let again = try await cache.chunk(of: entry, at: 0, format: .raw, fetcher: host)
        XCTAssertTrue(again.fromCache)
        XCTAssertEqual(again.data, first.data)
        XCTAssertEqual(again.next, 16)
        XCTAssertEqual(host.requests.count, 1)
        XCTAssertEqual(host.requests.first?.length, 16)

        // Offline: saved ranges still load, others say so.
        let offline = try await cache.chunk(of: entry, at: 0, format: .raw, fetcher: nil)
        XCTAssertTrue(offline.fromCache)
        do {
            _ = try await cache.chunk(of: entry, at: 32, format: .raw, fetcher: nil)
            XCTFail("Nothing saved there")
        } catch {
            XCTAssertEqual(error as? TerminalLogCacheError, .notSaved)
        }
        // The last range of an ended log is final and kept, as is its text.
        let tail = try await cache.chunk(of: entry, at: 32, format: .raw, fetcher: host)
        XCTAssertTrue(tail.eof)
        let tailSaved = await cache.contains(entry, at: 32, format: .raw)
        XCTAssertTrue(tailSaved)
        _ = try await cache.chunk(of: entry, at: 0, format: .text, fetcher: host)
        let textSaved = await cache.contains(entry, at: 0, format: .text)
        XCTAssertTrue(textSaved)
    }

    func testARunningLogsUnfinishedTailIsNotKept() async throws {
        let folder = try TemporaryFolder()
        let cache = try TerminalLogCache(location: folder.location("logs"), chunkLength: 16)
        let host = LogHost(bytes(24), status: "running")
        let entry = log(bytes: 24, status: "running")
        _ = try await cache.chunk(of: entry, at: 0, format: .raw, fetcher: host)
        let fullSaved = await cache.contains(entry, at: 0, format: .raw)
        XCTAssertTrue(fullSaved, "A full raw range cannot change")
        let tail = try await cache.chunk(of: entry, at: 16, format: .raw, fetcher: host)
        XCTAssertEqual(tail.data.count, 8)
        XCTAssertFalse(tail.eof)
        let tailSaved = await cache.contains(entry, at: 16, format: .raw)
        XCTAssertFalse(tailSaved, "The running tail grows")
        _ = try await cache.chunk(of: entry, at: 0, format: .text, fetcher: host)
        let textSaved = await cache.contains(entry, at: 0, format: .text)
        XCTAssertFalse(textSaved, "Text of a running log may still change where the range ends")
        host.write(bytes(8))
        let grown = try await cache.chunk(of: entry, at: 16, format: .raw, fetcher: host)
        XCTAssertEqual(grown.data.count, 16)
    }

    func testTheLeastRecentlyUsedRangesGoFirst() async throws {
        let folder = try TemporaryFolder()
        let ticker = Ticker()
        let location = folder.location("logs")
        let probe = try TerminalLogCache(location: folder.location("probe"), chunkLength: 16, now: { ticker.tick() })
        let host = LogHost(bytes(80))
        let entry = log(bytes: 80)
        _ = try await probe.chunk(of: entry, at: 0, format: .raw, fetcher: host)
        let fileSize = await probe.usedBytes
        XCTAssertGreaterThan(fileSize, 16)

        // Room for three ranges (headers differ by a few bytes), not four.
        let capacity = fileSize * 3 + 8
        let cache = try TerminalLogCache(location: location, capacity: capacity, chunkLength: 16, now: { ticker.tick() })
        for offset in [0, 16, 32] as [Int64] { _ = try await cache.chunk(of: entry, at: offset, format: .raw, fetcher: host) }
        // Reading the first range again makes the second the least recently used.
        let reread = try await cache.chunk(of: entry, at: 0, format: .raw, fetcher: host)
        XCTAssertTrue(reread.fromCache)
        _ = try await cache.chunk(of: entry, at: 48, format: .raw, fetcher: host)
        var kept: [Int64] = []
        for offset in [0, 16, 32, 48] as [Int64] where await cache.contains(entry, at: offset, format: .raw) { kept.append(offset) }
        XCTAssertEqual(kept, [0, 32, 48])
        let used = await cache.usedBytes
        XCTAssertLessThanOrEqual(used, capacity)

        // A relaunch finds the same ranges, ordered by when they were last used.
        let relaunched = try TerminalLogCache(location: location, capacity: capacity, chunkLength: 16, now: { ticker.tick() })
        let relaunchedUsed = await relaunched.usedBytes
        XCTAssertEqual(relaunchedUsed, used)
        let saved = try await relaunched.chunk(of: entry, at: 32, format: .raw, fetcher: nil)
        XCTAssertTrue(saved.fromCache)
        _ = try await relaunched.chunk(of: entry, at: 64, format: .raw, fetcher: host)
        let evicted = await relaunched.contains(entry, at: 0, format: .raw)
        XCTAssertFalse(evicted, "After the relaunch the range at 0 was the least recently used")

        await relaunched.remove(entry)
        let emptied = await relaunched.usedBytes
        XCTAssertEqual(emptied, 0)
    }

    @MainActor
    func testTheViewerShowsTheNewestWindowAndPagesBack() async throws {
        let folder = try TemporaryFolder()
        let cache = try TerminalLogCache(location: folder.location("logs"), chunkLength: 16)
        let content = bytes(80)
        let host = LogHost(content)
        let model = TerminalLogViewerModel(log: log(bytes: 80), cache: cache, fetcher: host, windowLength: 32)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.windowStart, 48)
        XCTAssertEqual(model.windowEnd, 80)
        XCTAssertEqual(model.feed.chunks.reduce(Data(), +), content.subdata(in: 48..<80))
        XCTAssertTrue(model.reachedEnd)
        XCTAssertTrue(model.canShowEarlier)
        XCTAssertFalse(model.canShowLater)
        let generation = model.feed.generation

        await model.showEarlier()
        XCTAssertEqual(model.windowStart, 16)
        XCTAssertEqual(model.windowEnd, 48)
        XCTAssertGreaterThan(model.feed.generation, generation, "A new window replays into a fresh terminal")
        XCTAssertEqual(model.feed.chunks.reduce(Data(), +), content.subdata(in: 16..<48))
        XCTAssertTrue(model.canShowLater)

        await model.setMode(.text)
        XCTAssertEqual(model.text, String(decoding: content.subdata(in: 16..<48), as: UTF8.self))
        XCTAssertEqual(host.requests.last?.format, .text)
    }

    @MainActor
    func testTheViewerReadsARunningLogAsItGrowsAndSaysWhenOffline() async throws {
        let folder = try TemporaryFolder()
        let cache = try TerminalLogCache(location: folder.location("logs"), chunkLength: 16)
        let host = LogHost(Data("\u{1B}[31mred\u{1B}[0m\n".utf8), status: "running")
        let model = TerminalLogViewerModel(log: log(bytes: 13, status: "running"), cache: cache, fetcher: host, windowLength: 32)
        await model.load()
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.reachedEnd)
        XCTAssertEqual(model.windowEnd, 13)
        host.write(Data("more\n".utf8))
        host.end()
        await model.refresh()
        XCTAssertEqual(model.windowEnd, 18)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(String(decoding: model.feed.chunks.reduce(Data(), +), as: UTF8.self), "\u{1B}[31mred\u{1B}[0m\nmore\n")

        let offline = TerminalLogViewerModel(log: log("t2", bytes: 13), cache: cache, fetcher: nil)
        await offline.load()
        XCTAssertEqual(offline.phase, .failed(TerminalLogCacheError.notSaved.errorDescription!))
    }
}
