import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore

/// The Mac's bridge against a fake tunnel socket host (a Unix socket the test drives) and fake stream
/// sides: docs/HOST-API.md "The two apps", "Streams" and "Ending a stream".
final class MacTunnelBridgeTests: XCTestCase {
    private let peer = IrohNodeID.random()

    private func start(_ host: FakeSocketHost, send: FakeSendSide, receive: FakeReceiveSide) -> Task<Void, Never> {
        let bridge = MacTunnelBridge(socketPath: host.path)
        let peer = peer
        return Task { await bridge.serve(peer: peer, send: send, receive: receive) }
    }

    /// The preamble names the peer in exactly 84 bytes, the phone's bytes follow unchanged, and a
    /// normal end each way finishes the stream and shuts down the socket's sending side, so the host's
    /// last bytes after the phone's end arrive and the stream is finished, never reset.
    func testPreambleThenBytesBothWaysAndNormalEnds() async throws {
        let host = try FakeSocketHost()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = start(host, send: send, receive: receive)
        let connection = try await host.accept()

        let preamble = try await connection.read(RemoteAccessTunnel.preambleLength)
        XCTAssertEqual(preamble, RemoteAccessTunnel.preamble(nodeID: peer))
        XCTAssertEqual(preamble.count, 84)
        XCTAssertEqual(String(decoding: preamble, as: UTF8.self), "agentland-tunnel/1 \(peer.hex)\n")

        receive.send(Data("ClientHello".utf8))
        receive.send(Data(" and a request".utf8))
        receive.end()
        // The phone's end is the host's end of file (SHUT_WR), after its bytes.
        let fromPhone = try await connection.readToEnd()
        XCTAssertEqual(String(decoding: fromPhone, as: UTF8.self), "ClientHello and a request")

        // The host answers after the phone's end and closes: every byte arrives, then the finish.
        let response = Data((0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let wrote = await connection.write(response)
        XCTAssertTrue(wrote)
        // As the Go host ends a connection: close(). (On macOS a peer's shutdown(SHUT_RDWR) after this
        // side's SHUT_WR is never reported as an end of file, not even by read(); the host never does it.)
        connection.close()
        await bridging.value

        XCTAssertEqual(send.data, response)
        XCTAssertEqual(send.calls.last, .finish)
        XCTAssertFalse(send.calls.contains { if case .reset = $0 { return true } else { return false } })
        XCTAssertEqual(receive.stopCodes, [], "a stream that ended normally is not stopped")
        // Never a whole body at once: chunks of at most 64 KiB.
        for case let .write(count) in send.calls {
            XCTAssertLessThanOrEqual(count, MacTunnelBridge.chunkBytes)
        }
    }

    /// The host closes before sending a byte (it refused the preamble or a limit): the stream is reset
    /// and stopped with code 2, never finished.
    func testAHostThatSendsNothingIsARefusal() async throws {
        let host = try FakeSocketHost()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = start(host, send: send, receive: receive)
        let connection = try await host.accept()
        _ = try await connection.read(RemoteAccessTunnel.preambleLength)
        connection.close()
        await bridging.value
        try await eventually { send.calls == [.reset(2)] && receive.stopCodes == [2] }
        XCTAssertEqual(send.calls, [.reset(2)])
        XCTAssertEqual(receive.stopCodes, [2])
    }

    /// The host closes before sending a byte, and the phone's ClientHello meets the closed socket before
    /// the bridge reads its end (a refusal at accept, a host that is stopping): still refused, code 2
    /// both ways, never a stop with code 1.
    func testAWriteThatFailsBeforeTheHostSentAByteIsARefusal() async throws {
        let socket = ScriptedSocket()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = Task { [peer] in await MacTunnelBridge.bridge(peer: peer, socket: socket, send: send, receive: receive) }
        try await eventually { socket.writes == 1 }  // the preamble
        socket.failWrites()
        receive.send(Data("ClientHello".utf8))
        try await eventually { socket.writeFailures == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(receive.stopCodes, [], "nothing is stopped before the socket's end says why")
        socket.end()
        await bridging.value
        XCTAssertEqual(send.calls, [.reset(2)])
        XCTAssertEqual(receive.stopCodes, [2])
    }

    /// The same failed write after the host has sent bytes is a failed write: the receiving side stops
    /// with code 1, and the sending side ends with the socket's own end.
    func testAWriteThatFailsAfterTheHostSentBytesStopsWithCodeOne() async throws {
        let socket = ScriptedSocket()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = Task { [peer] in await MacTunnelBridge.bridge(peer: peer, socket: socket, send: send, receive: receive) }
        try await eventually { socket.writes == 1 }
        socket.deliver(Data("ServerHello".utf8))
        try await eventually { send.data == Data("ServerHello".utf8) }
        socket.failWrites()
        receive.send(Data("Finished".utf8))
        try await eventually { receive.stopCodes == [1] }
        socket.end()
        await bridging.value
        XCTAssertEqual(receive.stopCodes, [1])
        XCTAssertEqual(send.calls.last, .finish)
    }

    /// No socket at the path (the host is not running): refused, code 2 both ways.
    func testNoSocketIsARefusal() async throws {
        let bridge = MacTunnelBridge(socketPath: NSTemporaryDirectory() + "al-missing-\(UUID().uuidString.prefix(6)).sock")
        let send = FakeSendSide(), receive = FakeReceiveSide()
        await bridge.serve(peer: peer, send: send, receive: receive)
        try await eventually { send.calls == [.reset(2)] && receive.stopCodes == [2] }
    }

    /// The host sends its last bytes and closes its socket while the phone still sends: the stream's
    /// sending side is finished (those bytes arrive), and the phone's next bytes, which the closed socket
    /// cannot take, stop the receiving side with code 1 without resetting the finished side.
    func testAFailedWriteStopsReceivingAndLeavesAFinishedSendingSide() async throws {
        let host = try FakeSocketHost()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = start(host, send: send, receive: receive)
        let connection = try await host.accept()
        _ = try await connection.read(RemoteAccessTunnel.preambleLength)
        receive.send(Data("request".utf8))
        _ = try await connection.read(7)
        await connection.write(Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nbye".utf8))
        connection.close()
        try await eventually { send.calls.last == .finish }
        // The phone's WINDOW_UPDATE or close_notify reaches a socket that is gone.
        for _ in 0..<20 { receive.send(Data(repeating: 1, count: 1024)) }
        await bridging.value
        XCTAssertEqual(receive.stopCodes, [1])
        XCTAssertEqual(send.calls.last, .finish)
        XCTAssertFalse(send.calls.contains(.reset(1)), "a finished sending side is never reset")
        XCTAssertTrue(String(decoding: send.data, as: UTF8.self).hasSuffix("bye"))
    }

    /// A reset that arrives aborts the socket (the host sees it closed) and resets the sending side
    /// with code 1.
    func testAResetAbortsTheSocket() async throws {
        let host = try FakeSocketHost()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = start(host, send: send, receive: receive)
        let connection = try await host.accept()
        _ = try await connection.read(RemoteAccessTunnel.preambleLength)
        await connection.write(Data("hello".utf8))
        try await eventually { send.data.count == 5 }
        receive.reset()
        let rest = try await connection.readToEnd()
        XCTAssertEqual(rest, Data(), "the socket is closed, not left open")
        await bridging.value
        XCTAssertEqual(send.calls.last, .reset(1))
    }

    /// The peer stopped the stream's sending side (its write to its socket failed): the bridge reads
    /// what the host still sends and drops it until the host's end of file, never closing the socket
    /// with unread input, and the other direction goes on to its own end.
    func testAStopThatArrivesDropsTheHostsBytesUntilItsEnd() async throws {
        let host = try FakeSocketHost()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = start(host, send: send, receive: receive)
        let connection = try await host.accept()
        _ = try await connection.read(RemoteAccessTunnel.preambleLength)
        send.stop()
        await connection.write(Data("dropped".utf8))
        // The host can keep writing: the socket is read, not closed.
        for _ in 0..<64 {
            let wrote = await connection.write(Data(repeating: 2, count: 16 * 1024))
            XCTAssertTrue(wrote)
        }
        // The phone's bytes still reach the host.
        receive.send(Data("still here".utf8))
        let fromPhone = try await connection.read(10)
        XCTAssertEqual(String(decoding: fromPhone, as: UTF8.self), "still here")
        receive.end()
        connection.shutdownOutput()
        await bridging.value
        XCTAssertEqual(send.calls, [], "nothing forwarded, finished or reset after the stop")
        XCTAssertEqual(receive.stopCodes, [])
    }

    /// Cancelling the bridge (its connection or the endpoint closed) closes the socket.
    func testCancellingClosesTheSocket() async throws {
        let host = try FakeSocketHost()
        let send = FakeSendSide(), receive = FakeReceiveSide()
        let bridging = start(host, send: send, receive: receive)
        let connection = try await host.accept()
        _ = try await connection.read(RemoteAccessTunnel.preambleLength)
        await connection.write(Data("x".utf8))
        try await eventually { send.data.count == 1 }
        bridging.cancel()
        let rest = try await connection.readToEnd()
        XCTAssertEqual(rest, Data())
        receive.end()
        await bridging.value
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A tunnel socket connection the test drives: reads wait for what the test delivers or its end, and
/// writes fail once told to (`EPIPE`, as a write to a socket the host closed does).
private final class ScriptedSocket: TunnelSocketConnection, @unchecked Sendable {
    private enum Item { case data(Data), end }
    private struct State {
        var items: [Item] = []
        var reader: CheckedContinuation<Item, Never>?
        var writes = 0
        var writeFailures = 0
        var failing = false
        var aborted = false
    }
    private let lock = NSLock()
    private var state = State()

    var writes: Int { lock.withLock { state.writes } }
    var writeFailures: Int { lock.withLock { state.writeFailures } }
    func failWrites() { lock.withLock { state.failing = true } }
    func deliver(_ data: Data) { give(.data(data)) }
    func end() { give(.end) }

    private func give(_ item: Item) {
        let reader = lock.withLock { () -> CheckedContinuation<Item, Never>? in
            guard let reader = state.reader else {
                state.items.append(item)
                return nil
            }
            state.reader = nil
            return reader
        }
        reader?.resume(returning: item)
    }

    func read(maximum: Int) async throws -> Data? {
        let item = await withCheckedContinuation { (continuation: CheckedContinuation<Item, Never>) in
            let ready = lock.withLock { () -> Item? in
                if !state.items.isEmpty { return state.items.removeFirst() }
                if state.aborted { return .end }
                state.reader = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch item {
        case let .data(data): return data
        case .end: return nil
        }
    }

    func write(_ data: Data) async throws {
        try lock.withLock {
            if state.failing {
                state.writeFailures += 1
                throw TunnelSocketError.write(EPIPE)
            }
            state.writes += 1
        }
    }

    func shutdownOutput() {}

    func abort() {
        let reader = lock.withLock { () -> CheckedContinuation<Item, Never>? in
            state.aborted = true
            defer { state.reader = nil }
            return state.reader
        }
        reader?.resume(returning: .end)
    }
}
