import AgentLandCore
import Foundation
import Synchronization
import XCTest
@testable import AgentLandRemoteAccess

/// The phone's bridge (docs/HOST-API.md "The phone's bridge") with streams the test provides: no iroh
/// endpoint runs here. Everything stays on 127.0.0.1.
final class TunnelBridgeTests: XCTestCase {
    private let target = HostEndpoint(host: "mac.local", port: 9841)!

    private func connectHead(_ secret: String? = nil, target: String = "mac.local:9841") -> String {
        var head = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let secret { head += "Proxy-Authorization: Basic \(basic(secret))\r\n" }
        return head + "\r\n"
    }

    /// An authorized connection, the way URLSession makes one: a head without the credential, the 407,
    /// then the head with it.
    private func authorized(_ address: RemoteAccessBridgeAddress) async throws -> RawClient {
        let client = try await RawClient(port: address.port)
        try await client.send(connectHead())
        let refused = await client.readHead()
        XCTAssertEqual(refused?.hasPrefix("HTTP/1.1 407 "), true)
        try await client.send(connectHead(address.secret))
        let accepted = await client.readHead()
        XCTAssertEqual(accepted, "HTTP/1.1 200 Connection Established\r\n\r\n")
        return client
    }

    // MARK: APIClient through the bridge

    /// URLSession through the bridge, as `APIClient`'s tunnel transport makes it: `ProxyConfiguration`
    /// with the bridge's credential, requests to the paired address, the TLS inside checked against the
    /// paired certificate and name. Here each stream is a TCP connection to an HTTPS server standing in
    /// for the host.
    func testAPIClientReachesTheHostThroughTheBridgeWithThePinnedCertificate() async throws {
        let server = try await TLSTestServer(name: "mac.local")
        defer { server.stop() }
        let opener = LoopbackOpener(port: server.port)
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        XCTAssertEqual(address.secret.count, 43, "32 random bytes, base64url without padding")
        XCTAssertNil(address.secret.first { "+/=".contains($0) })

        let paired = try ServerAddress(validating: "https://mac.local:9841")
        let routed = try XCTUnwrap(RoutedTransport(address: paired, certificateSHA256: server.certificateSHA256))
        routed.attachTunnel(address)
        routed.useTunnel()
        let answered = await routed.probeTunnel(timeout: 5)
        XCTAssertTrue(answered)
        let api = APIClient(address: paired, token: "device-token", transport: routed)
        let health = try await api.health(timeout: 5)
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(server.paths, ["/v1/health", "/v1/health"])
        XCTAssertEqual(opener.opened.withLock { $0 }, 2, "one stream for each connection the bridge let through")

        // Another certificate behind the tunnel is refused by the pinned check.
        let otherPin = String(repeating: "0", count: 64)
        let impostor = try XCTUnwrap(RoutedTransport(address: paired, certificateSHA256: otherPin))
        impostor.attachTunnel(address)
        let refusedPin = await impostor.probeTunnel(timeout: 5)
        XCTAssertFalse(refusedPin)
        // A certificate for another name, pinned: refused as well.
        let renamed = try XCTUnwrap(RoutedTransport(address: try ServerAddress(validating: "https://studio.local:9841"),
                                                    certificateSHA256: server.certificateSHA256))
        renamed.attachTunnel(address)
        let refusedName = await renamed.probeTunnel(timeout: 5)
        XCTAssertFalse(refusedName, "a CONNECT for another name is refused, and TLS is validated for the paired name")
        XCTAssertEqual(server.paths.count, 2, "no request reached the host through a check that failed")

        // Without the bridge's secret nothing is let through.
        let opened = opener.opened.withLock { $0 }
        let stranger = try XCTUnwrap(RoutedTransport(address: paired, certificateSHA256: server.certificateSHA256))
        stranger.attachTunnel(RemoteAccessBridgeAddress(port: address.port, secret: RemoteAccessTunnel.Bridge.makeSecret()))
        let refusedSecret = await stranger.probeTunnel(timeout: 5)
        XCTAssertFalse(refusedSecret)
        XCTAssertEqual(opener.opened.withLock { $0 }, opened, "no stream for a connection without the credential")
    }

    // MARK: Heads

    func testAStreamOpensOnlyAfterThe407AndTheCredential() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        let client = try await RawClient(port: address.port)
        try await client.send(connectHead())
        let challenge = await client.readHead()
        XCTAssertEqual(challenge, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"agentland\"\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(opener.streams.isEmpty, "nothing reaches the Mac before the credential")
        try await client.send(connectHead(address.secret))
        let established = await client.readHead()
        XCTAssertEqual(established, "HTTP/1.1 200 Connection Established\r\n\r\n")
        XCTAssertEqual(opener.streams.count, 1)
        XCTAssertEqual(bridge.waitingCount, 0, "a connection that showed the credential no longer waits")

        // A connection that shows the credential at once (URLSession may send it again) gets its stream too.
        let preemptive = try await RawClient(port: address.port)
        try await preemptive.send(connectHead(address.secret))
        let direct = await preemptive.readHead()
        XCTAssertEqual(direct, "HTTP/1.1 200 Connection Established\r\n\r\n")
        XCTAssertEqual(opener.streams.count, 2)
    }

    func testAnyOtherHeadClosesTheConnectionAndOpensNoStream() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        let secret = address.secret
        let firstHeads = [
            ("another target", connectHead(target: "evil.example:443")),
            ("the Mac's address instead of its name", connectHead(target: "192.168.1.5:9841")),
            ("another port", connectHead(target: "mac.local:22")),
            ("another method", "GET http://mac.local:9841/v1/health HTTP/1.1\r\nHost: mac.local:9841\r\n\r\n"),
            ("HTTP/1.0", "CONNECT mac.local:9841 HTTP/1.0\r\n\r\n"),
            ("a wrong credential", connectHead(RemoteAccessTunnel.Bridge.makeSecret())),
            ("another user", "CONNECT mac.local:9841 HTTP/1.1\r\nProxy-Authorization: Basic \(Data("root:\(secret)".utf8).base64EncodedString())\r\n\r\n"),
            ("two credentials", "CONNECT mac.local:9841 HTTP/1.1\r\nProxy-Authorization: Basic \(basic(secret))\r\nProxy-Authorization: Basic \(basic(secret))\r\n\r\n"),
            ("another scheme", "CONNECT mac.local:9841 HTTP/1.1\r\nProxy-Authorization: Bearer \(secret)\r\n\r\n"),
            ("a header without a colon", "CONNECT mac.local:9841 HTTP/1.1\r\nweird\r\n\r\n"),
            ("a head over 4 KiB", "CONNECT mac.local:9841 HTTP/1.1\r\nX-Padding: \(String(repeating: "a", count: 4100))\r\n\r\n"),
            ("a control byte", "CONNECT mac.local:9841 HTTP/1.1\r\nX: \u{1}\r\n\r\n")
        ]
        for (name, head) in firstHeads {
            let client = try await RawClient(port: address.port)
            try? await client.send(head)
            let answer = await client.readAll()
            XCTAssertTrue(answer.closed, name)
            XCTAssertTrue(answer.data.isEmpty, "\(name): \(String(decoding: answer.data, as: UTF8.self))")
        }
        let secondHeads = [
            ("still no credential", connectHead()),
            ("a wrong credential", connectHead(RemoteAccessTunnel.Bridge.makeSecret())),
            ("another target", connectHead(secret, target: "mac.local:22"))
        ]
        for (name, head) in secondHeads {
            let client = try await RawClient(port: address.port)
            try await client.send(connectHead())
            let challenge = await client.readHead()
            XCTAssertEqual(challenge?.hasPrefix("HTTP/1.1 407 "), true, name)
            try? await client.send(head)
            let answer = await client.readAll()
            XCTAssertTrue(answer.closed, name)
            XCTAssertTrue(answer.data.isEmpty, name)
        }
        XCTAssertTrue(opener.streams.isEmpty, "none of these reached the Mac")
    }

    /// Each head has 250 ms: the first after the connection opens, the second after the 407.
    func testAHeadThatComesLateClosesTheConnection() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()

        let silent = try await RawClient(port: address.port)
        let start = Date()
        let dropped = await silent.readAll(within: 3)
        XCTAssertTrue(dropped.closed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)

        let slow = try await RawClient(port: address.port)
        try await slow.send("CONNECT mac.local:9841 HTTP/1.1\r\n")
        try await Task.sleep(for: .milliseconds(400))
        try? await slow.send("\r\n")
        let slowAnswer = await slow.readAll()
        XCTAssertTrue(slowAnswer.closed)
        XCTAssertTrue(slowAnswer.data.isEmpty)

        let lateCredential = try await RawClient(port: address.port)
        try await lateCredential.send(connectHead())
        _ = await lateCredential.readHead()
        try await Task.sleep(for: .milliseconds(400))
        try? await lateCredential.send(connectHead(address.secret))
        let late = await lateCredential.readAll()
        XCTAssertTrue(late.closed)
        XCTAssertTrue(late.data.isEmpty)
        XCTAssertTrue(opener.streams.isEmpty)
    }

    /// Another app holding connections open cannot keep `APIClient`'s out: a connection that arrives
    /// while 16 wait closes the one that has waited longest, and one that showed the credential is never
    /// closed for room.
    func testAFullWaitingRoomClosesTheLongestWaitingConnection() async throws {
        let opener = ScriptedOpener()
        var limits = TunnelBridge.Limits()
        limits.headTimeout = .seconds(20)
        let bridge = TunnelBridge(target: target, opener: opener, limits: limits)
        defer { bridge.stop() }
        let address = try bridge.start()
        let inside = try await authorized(address)

        var idle: [RawClient] = []
        for _ in 0..<16 { idle.append(try await RawClient(port: address.port)) }
        let full = await eventually { bridge.waitingCount == 16 }
        XCTAssertTrue(full)
        let newcomer = try await authorized(address)
        let evicted = await idle[0].readAll(within: 2)
        XCTAssertTrue(evicted.closed, "the longest-waiting connection made room")
        let stillWaiting = await idle[1].next(within: 0.3)
        XCTAssertNil(stillWaiting, "the next one still waits")
        XCTAssertEqual(opener.streams.count, 2)

        // The connections that showed the credential still carry bytes both ways.
        for (client, stream) in zip([inside, newcomer], opener.streams) {
            try await client.send("ping")
            let arrived = await eventually { stream.written == Data("ping".utf8) }
            XCTAssertTrue(arrived)
            stream.receive(.data(Data("pong".utf8)))
            let back = await client.next(within: 2)
            XCTAssertEqual(back, .data(Data("pong".utf8)))
        }
    }

    /// At most 8 streams at once and 30 in any minute, half the host's limits for one device.
    func testStreamsAreLimitedAtOnceAndPerMinute() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        var open: [RawClient] = []
        for _ in 0..<8 { open.append(try await authorized(address)) }
        let ninth = try await RawClient(port: address.port)
        try await ninth.send(connectHead(address.secret))
        let refused = await ninth.readAll()
        XCTAssertEqual(String(decoding: refused.data, as: UTF8.self),
                       "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(refused.closed)
        XCTAssertEqual(opener.streams.count, 8, "no stream above the limit")

        // One ends both ways; its place is free again.
        opener.streams[0].receive(.end)
        open[0].socket.shutdownOutput()
        let ended = await open[0].readAll()
        XCTAssertTrue(ended.closed)
        let freed = await eventually {
            guard let client = try? await RawClient(port: address.port), (try? await client.send(connectHead(address.secret))) != nil else { return false }
            return await client.readHead() == "HTTP/1.1 200 Connection Established\r\n\r\n"
        }
        XCTAssertTrue(freed)

        var perMinute = TunnelBridge.Limits()
        perMinute.maximumStreamsPerMinute = 3
        perMinute.minute = .seconds(1)
        let counted = TunnelBridge(target: target, opener: ScriptedOpener(), limits: perMinute)
        defer { counted.stop() }
        let countedAddress = try counted.start()
        for _ in 0..<3 { _ = try await authorized(countedAddress) }
        let fourth = try await RawClient(port: countedAddress.port)
        try await fourth.send(connectHead(countedAddress.secret))
        let fourthAnswer = await fourth.readHead()
        XCTAssertEqual(fourthAnswer?.hasPrefix("HTTP/1.1 503 "), true)
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await authorized(countedAddress)
        XCTAssertEqual(counted.streamsOpened, 4)
    }

    /// The connection is refused when the stream cannot be opened (the Mac closed the connection).
    func testAStreamThatCannotOpenAnswers503() async throws {
        let opener = ScriptedOpener()
        opener.fails = true
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        let client = try await RawClient(port: address.port)
        try await client.send(connectHead(address.secret))
        let answer = await client.readAll()
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self).components(separatedBy: "\r\n").first, "HTTP/1.1 503 Service Unavailable")
        XCTAssertTrue(answer.closed)
    }

    // MARK: How a stream ends

    /// Each direction ends on its own: the Mac's end of stream is a FIN after its last bytes, and
    /// `APIClient`'s FIN finishes the stream, never a reset.
    func testNormalEndsDeliverTheLastBytesBothWays() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        let client = try await authorized(address)
        let stream = try XCTUnwrap(opener.streams.first)
        stream.receive(.data(Data("the host's last response".utf8)))
        stream.receive(.end)
        let answer = await client.readAll()
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), "the host's last response")
        XCTAssertTrue(answer.closed)
        XCTAssertFalse(answer.reset, "a FIN, not a reset")
        try await client.send("close_notify")
        client.socket.shutdownOutput()
        let finished = await eventually { stream.calls.last == .finish }
        XCTAssertTrue(finished)
        XCTAssertEqual(stream.written, Data("close_notify".utf8))
        XCTAssertFalse(stream.calls.contains { if case .reset = $0 { true } else { false } })
    }

    /// The host refused the connection (a reset with code 2) while `APIClient` still used it: the
    /// connection is aborted and the route logic hears of it once. After `APIClient` ended its side, it
    /// does not.
    func testTheHostsRefusalAbortsTheConnectionAndIsReported() async throws {
        let opener = ScriptedOpener()
        let refusals = Locked(0)
        let bridge = TunnelBridge(target: target, opener: opener, onHostRefused: { refusals.withLock { $0 += 1 } })
        defer { bridge.stop() }
        let address = try bridge.start()
        let client = try await authorized(address)
        let stream = try XCTUnwrap(opener.streams.first)
        stream.receive(.reset(RemoteAccessTunnel.StreamCode.refused.rawValue))
        let answer = await client.readAll()
        XCTAssertTrue(answer.closed)
        XCTAssertTrue(answer.reset, "APIClient's connection is reset")
        let reported = await eventually { refusals.withLock { $0 } == 1 }
        XCTAssertTrue(reported)
        let resetSent = await eventually { stream.calls.contains(.reset(RemoteAccessTunnel.StreamCode.aborted.rawValue)) }
        XCTAssertTrue(resetSent)

        let done = try await authorized(address)
        let second = try XCTUnwrap(opener.streams.last)
        done.socket.shutdownOutput()
        let finished = await eventually { second.calls.contains(.finish) }
        XCTAssertTrue(finished)
        second.receive(.reset(RemoteAccessTunnel.StreamCode.refused.rawValue))
        _ = await done.readAll()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(refusals.withLock { $0 }, 1, "APIClient had ended that connection")
    }

    /// The Mac stopped the stream (its write to the host's socket failed): the bridge drops what
    /// `APIClient` still sends until its end, never resets, and the Mac's last bytes still arrive.
    func testAStopFromTheMacDrainsTheSocketAndKeepsTheOtherDirection() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        let client = try await authorized(address)
        let stream = try XCTUnwrap(opener.streams.first)
        stream.peerStops(code: 1)
        try await Task.sleep(for: .milliseconds(50))
        try await client.send("a WINDOW_UPDATE the host will never read")
        stream.receive(.data(Data("GOAWAY".utf8)))
        stream.receive(.end)
        let answer = await client.readAll()
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), "GOAWAY")
        XCTAssertFalse(answer.reset)
        client.socket.shutdownOutput()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stream.written, Data(), "nothing forwarded after the stop")
        XCTAssertFalse(stream.calls.contains { if case .reset = $0 { true } else { false } })
    }

    /// `APIClient`'s connection was reset: the stream is reset and stopped with code 1.
    func testAConnectionResetByAPIClientAbortsBothDirections() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        defer { bridge.stop() }
        let address = try bridge.start()
        let client = try await authorized(address)
        let stream = try XCTUnwrap(opener.streams.first)
        client.socket.abort()
        let aborted = await eventually {
            stream.calls.contains(.reset(RemoteAccessTunnel.StreamCode.aborted.rawValue))
                && stream.calls.contains(.stop(RemoteAccessTunnel.StreamCode.aborted.rawValue))
        }
        XCTAssertTrue(aborted)
    }

    func testStoppingTheBridgeEndsEveryConnectionAndTheListener() async throws {
        let opener = ScriptedOpener()
        let bridge = TunnelBridge(target: target, opener: opener)
        let address = try bridge.start()
        let client = try await authorized(address)
        bridge.stop()
        let answer = await client.readAll()
        XCTAssertTrue(answer.closed)
        let refused = await eventually { (try? await RawClient(port: address.port)) == nil }
        XCTAssertTrue(refused, "nothing listens after the stop")
    }

    func testHeadParsing() {
        let secret = "s3cret"
        XCTAssertEqual(TunnelBridge.verdict(of: Data(connectHead(secret).utf8), target: target, secret: secret), .authorized)
        XCTAssertEqual(TunnelBridge.verdict(of: Data("CONNECT MAC.LOCAL:9841 HTTP/1.1\r\nproxy-authorization: basic \(basic(secret))\r\n\r\n".utf8),
                                            target: target, secret: secret), .authorized, "names and schemes in any case")
        XCTAssertEqual(TunnelBridge.verdict(of: Data(connectHead().utf8), target: target, secret: secret), .noCredential)
        let v6 = HostEndpoint(host: "fd7a::1", port: 9841)!
        XCTAssertEqual(TunnelBridge.verdict(of: Data(connectHead(secret, target: "[fd7a::1]:9841").utf8), target: v6, secret: secret), .authorized)
        XCTAssertEqual(TunnelBridge.verdict(of: Data(connectHead(secret, target: "fd7a::1:9841").utf8), target: v6, secret: secret), .refused)
        XCTAssertEqual(TunnelBridge.verdict(of: Data("CONNECT mac.local:9841 HTTP/1.1\r\n\r\n".utf8).dropLast(2), target: target, secret: secret), .refused)
        XCTAssertTrue(TunnelBridge.constantTimeEqual(Data("abc".utf8), Data("abc".utf8)))
        XCTAssertFalse(TunnelBridge.constantTimeEqual(Data("abc".utf8), Data("abd".utf8)))
        XCTAssertFalse(TunnelBridge.constantTimeEqual(Data("abc".utf8), Data("abcd".utf8)))
    }
}
