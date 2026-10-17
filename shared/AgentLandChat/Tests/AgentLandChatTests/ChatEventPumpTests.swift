import XCTest
import AgentLandCore
@testable import AgentLandChat

final class ChatEventPumpTests: XCTestCase {
    private func delta(_ seq: Int, offset: Int, _ text: String, part: String = "p") -> String {
        #"{"seq":\#(seq),"type":"part.delta","messageId":"m","partId":"\#(part)","field":"text","offset":\#(offset),"delta":"\#(text)"}"#
    }

    private func collect(_ pump: ChatEventPump) async -> (batches: [[ChatEventEnvelope]], end: String) {
        var batches: [[ChatEventEnvelope]] = []
        for await output in pump.outputs {
            switch output {
            case let .events(batch): batches.append(batch)
            case .finished: return (batches, "finished")
            case let .failed(error): return (batches, "failed \(error)")
            }
        }
        return (batches, "closed")
    }

    func testABurstOfDeltasArrivesAsFewCoalescedBatches() async {
        var lines: [String] = []
        var offset = 0
        for index in 1...300 {
            lines.append(delta(index, offset: offset, "w\(index) "))
            offset += "w\(index) ".utf8.count
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        let pump = ChatEventPump()
        await pump.start(stream)
        let (batches, end) = await collect(pump)
        XCTAssertEqual(end, "finished")
        XCTAssertLessThanOrEqual(batches.count, 3, "300 deltas read at once leave in at most a few frames")
        let events = batches.flatMap { $0 }
        guard case let .partDelta(merged) = events.last?.event else { return XCTFail("merged delta") }
        XCTAssertEqual(events.last?.seq, 300, "A merged delta carries the seq of the last delta it absorbed")
        var text = ""
        for event in events { if case let .partDelta(value) = event.event { text += value.delta } }
        XCTAssertEqual(text, (1...300).map { "w\($0) " }.joined())
        XCTAssertEqual(merged.offset + merged.delta.utf8.count, offset)
    }

    func testDeltasOfDifferentPartsOrNonContiguousOffsetsStaySeparate() async {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(delta(1, offset: 0, "a", part: "p"))
            continuation.yield(delta(2, offset: 0, "b", part: "q"))
            continuation.yield(delta(3, offset: 1, "c", part: "q"))
            continuation.yield(delta(4, offset: 9, "d", part: "q"))
            continuation.finish()
        }
        let pump = ChatEventPump()
        await pump.start(stream)
        let events = await collect(pump).batches.flatMap { $0 }
        XCTAssertEqual(events.map(\.seq), [1, 3, 4])
    }

    func testBatchesAreSpacedAtMostThirtyPerSecond() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let lines = (1...40).map { delta($0, offset: $0 - 1, "x") }
        Task {
            for line in lines {
                continuation.yield(line)
                try? await Task.sleep(for: .milliseconds(5))
            }
            continuation.finish()
        }
        let pump = ChatEventPump()
        await pump.start(stream)
        var times: [ContinuousClock.Instant] = []
        for await output in pump.outputs {
            if case .events = output { times.append(ContinuousClock.now) }
        }
        XCTAssertLessThan(times.count, 40, "Deltas arriving every 5 ms are joined")
        // The last batch leaves when the stream ends, whenever that is.
        let paced = Array(times.dropLast())
        for (earlier, later) in zip(paced, paced.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, .milliseconds(25), "One batch per frame at most (with scheduling slack)")
        }
    }

    func testControlLinesLeaveAtOnceAndBadLinesAreSkipped() async {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#)
            continuation.yield("not json")
            continuation.yield("")
            continuation.yield(#"{"seq":0,"type":"snapshot","chat":{"id":"c"},"messages":null,"status":{"state":"idle"}}"#)
            continuation.yield(#"{"seq":1,"type":"status","state":"running"}"#)
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
        let pump = ChatEventPump()
        await pump.start(stream)
        let (batches, end) = await collect(pump)
        XCTAssertTrue(end.hasPrefix("failed"), "A broken connection is reported after the events read before it")
        XCTAssertEqual(batches.flatMap { $0 }.map(\.seq), [0, 0, 1])
        let skipped = await pump.skippedLines
        XCTAssertEqual(skipped, 1)
    }

    func testStopEndsTheStream() async {
        let cancelled = expectation(description: "the connection is cancelled")
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#)
            continuation.onTermination = { _ in cancelled.fulfill() }
        }
        let pump = ChatEventPump()
        await pump.start(stream)
        var iterator = pump.outputs.makeAsyncIterator()
        _ = await iterator.next()
        await pump.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        let next = await iterator.next()
        XCTAssertNil(next)
    }
}
