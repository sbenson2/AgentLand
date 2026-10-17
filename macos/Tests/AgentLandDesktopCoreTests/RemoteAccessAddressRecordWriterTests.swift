import CloudKit
import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore

/// The address record's writes and deletes against an in-memory database with virtual time
/// (docs/HOST-API.md "When the Mac's address changes", The record).
final class RemoteAccessAddressRecordWriterTests: XCTestCase {
    private let node = IrohNodeID.random()

    private func contents(_ revision: String, sequence: Int64, addresses: [String] = ["81.2.69.160:38842"],
                          relay: String? = nil) -> RemoteAccessAddressRecordContents {
        RemoteAccessAddressRecordContents(hostID: "0123456789abcdef0123456789abcdef", nodeID: node, directAddresses: addresses,
                                          relayURL: relay, revision: revision, sequence: sequence)
    }

    /// The record follows the host's answer; the same revision again is not written twice.
    func testWritesTheAnswerAndSkipsARevisionItHas() async throws {
        let database = FakeAddressDatabase()
        let writer = RemoteAccessAddressRecordWriter(database: database, clock: TestClock())
        let answer = RemoteAccessCapabilities(revision: "rev-7", enabled: true, nodeID: node, directAddresses: ["81.2.69.160:38842"],
                                              fallbackRelay: true, relayURL: "https://relay.example.net/", sequence: 7)
        let first = try XCTUnwrap(RemoteAccessAddressRecordContents(hostID: "0123456789abcdef0123456789abcdef", answer: answer))
        XCTAssertEqual(first.relayURL, "https://relay.example.net/")
        XCTAssertEqual(first.sequence, 7)
        await writer.write(first)
        await writer.settle(timeout: .seconds(2))
        await writer.write(first)
        await writer.settle(timeout: .seconds(2))
        XCTAssertEqual(database.calls, [.save(first)])
        XCTAssertEqual(database.records[first.hostID], first)

        // An answer with the switch off, or without a revision, is no record.
        XCTAssertNil(RemoteAccessAddressRecordContents(hostID: "h", answer: RemoteAccessCapabilities(revision: "r", enabled: false, nodeID: node)))
        XCTAssertNil(RemoteAccessAddressRecordContents(hostID: "h", answer: RemoteAccessCapabilities(enabled: true, nodeID: node)))
    }

    /// A failed write is retried with the notice relay's backoff (2, 4 … s; CloudKit's retryAfter
    /// when it gives one) until it succeeds.
    func testAFailedWriteIsRetriedWithTheNoticeRelaysBackoff() async throws {
        let database = FakeAddressDatabase()
        let clock = TestClock()
        let writer = RemoteAccessAddressRecordWriter(database: database, clock: clock)
        database.failNext([CKError(.networkFailure), CKError(.networkUnavailable),
                           CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 30])])
        let record = contents("r1", sequence: 1)
        await writer.write(record)
        await writer.settle(timeout: .seconds(5))
        XCTAssertEqual(database.calls, Array(repeating: .save(record), count: 4))
        XCTAssertEqual(clock.sleeps, [2, 4, 30])
        XCTAssertEqual(database.records[record.hostID], record)
    }

    /// The switch goes off while a write waits for its retry: the write is dropped and the delete goes
    /// out at once; nothing is written after the delete.
    func testAPendingWriteIsDroppedWhenTheSwitchGoesOff() async throws {
        let database = FakeAddressDatabase()
        let clock = HeldClock()
        let writer = RemoteAccessAddressRecordWriter(database: database, clock: clock)
        database.failNext([CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 3600])])
        let record = contents("r1", sequence: 1)
        await writer.write(record)
        try await waitFor { clock.sleeps == [3600] }
        await writer.delete(hostID: record.hostID)
        await writer.settle(timeout: .seconds(5))
        XCTAssertEqual(database.calls, [.save(record), .delete(record.hostID)])
        XCTAssertNil(database.records[record.hostID])
    }

    /// A write in flight finishes before the delete that follows it is sent, so the delete is the last
    /// word.
    func testAWriteInFlightFinishesBeforeTheDelete() async throws {
        let database = FakeAddressDatabase()
        let writer = RemoteAccessAddressRecordWriter(database: database, clock: TestClock())
        database.holdNext()
        let record = contents("r1", sequence: 1)
        await writer.write(record)
        try await waitFor { database.isHolding }
        await writer.delete(hostID: record.hostID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(database.calls, [.save(record)], "nothing is sent while a change is in flight")
        database.release()
        await writer.settle(timeout: .seconds(5))
        XCTAssertEqual(database.calls, [.save(record), .delete(record.hostID)])
        XCTAssertNil(database.records[record.hostID])
    }

    /// Only the latest wanted change counts: writes that came while one was in flight collapse into the
    /// newest.
    func testOnlyTheLatestWriteIsSent() async throws {
        let database = FakeAddressDatabase()
        let writer = RemoteAccessAddressRecordWriter(database: database, clock: TestClock())
        database.holdNext()
        let first = contents("r1", sequence: 1), second = contents("r2", sequence: 2), third = contents("r3", sequence: 3)
        await writer.write(first)
        try await waitFor { database.isHolding }
        await writer.write(second)
        await writer.write(third)
        database.release()
        await writer.settle(timeout: .seconds(5))
        XCTAssertEqual(database.calls, [.save(first), .save(third)])
    }

    /// iCloud not signed in: checked again after a minute, then the change goes out.
    func testAnUnavailableAccountIsCheckedAgainAfterAMinute() async throws {
        let database = FakeAddressDatabase()
        database.setAccount(.noAccount)
        let clock = TestClock()
        let writer = RemoteAccessAddressRecordWriter(database: database, clock: clock)
        await writer.delete(hostID: "0123456789abcdef0123456789abcdef")
        try await waitFor { clock.sleeps.count >= 1 }
        XCTAssertEqual(clock.sleeps.first, 60)
        database.setAccount(.available)
        await writer.settle(timeout: .seconds(5))
        XCTAssertEqual(database.calls, [.delete("0123456789abcdef0123456789abcdef")])
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
