import AgentLandIroh
import CryptoKit
import Foundation
import Synchronization
import XCTest

final class EndpointTests: XCTestCase {
    func testConnectAcceptAndStreamsBothWays() async throws {
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
        let client = try await Endpoint.bind(options: .test())
        let serverAddr = try loopbackAddr(of: server)
        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        let serverSide = Task { () throws -> Data in
            let next = await server.acceptNext()
            let incoming = try XCTUnwrap(next)
            let connection = try await incoming.accept().connect()
            XCTAssertEqual(connection.alpn(), tunnelALPN)
            XCTAssertEqual(connection.remoteId(), client.id())
            // The phone's stream: echo it back.
            let fromClient = try await connection.acceptBi()
            let received = try await fromClient.recv().readToEnd(sizeLimit: 4 << 20)
            try await fromClient.send().writeAll(buf: received)
            try await fromClient.send().finish()
            // The Mac opens one of its own.
            let toClient = try await connection.openBi()
            try await toClient.send().writeAll(buf: Data("from the Mac".utf8))
            try await toClient.send().finish()
            let reply = try await toClient.recv().readToEnd(sizeLimit: 64)
            _ = await connection.closed()
            return reply
        }

        let connection = try await within(10) { try await client.connect(addr: serverAddr, alpn: tunnelALPN) }
        XCTAssertEqual(connection.remoteId(), server.id())
        let stream = try await connection.openBi()
        try await stream.send().writeAll(buf: payload)
        try await stream.send().finish()
        let echoed = try await stream.recv().readToEnd(sizeLimit: 4 << 20)
        XCTAssertEqual(SHA256.hash(data: echoed), SHA256.hash(data: payload))

        let fromServer = try await connection.acceptBi()
        let greeting = try await fromServer.recv().readToEnd(sizeLimit: 64)
        XCTAssertEqual(String(decoding: greeting, as: UTF8.self), "from the Mac")
        try await fromServer.send().writeAll(buf: Data("from the phone".utf8))
        try await fromServer.send().finish()

        try await Task.sleep(for: .milliseconds(100))
        try connection.close(errorCode: 0, reason: Data("done".utf8))
        let reply = try await serverSide.value
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "from the phone")
        try await client.close()
        try await server.close()
    }

    func testPeerGateAcceptsOnlyListedEndpointIds() async throws {
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
        let paired = try await Endpoint.bind(options: .test())
        let stranger = try await Endpoint.bind(options: .test())
        let serverAddr = try loopbackAddr(of: server)
        let gate = IrohPeerGate(endpoint: server, allowed: [paired.id().toBytes()])
        XCTAssertTrue(gate.allows(paired.id()))
        XCTAssertFalse(gate.allows(stranger.id()))

        let refused = Mutex<[Data]>([])
        let accepted = gate.connections { id in refused.withLock { $0.append(id.toBytes()) } }
        let acceptedTask = Task { () -> [Data] in
            var seen: [Data] = []
            for await connection in accepted {
                let stream = try? await connection.acceptBi()
                let data = try? await stream?.recv().readToEnd(sizeLimit: 64)
                try? await stream?.send().writeAll(buf: data ?? Data())
                try? await stream?.send().finish()
                _ = await connection.closed()
                seen.append(connection.remoteId().toBytes() + (data ?? Data()))
                if seen.count == 2 { break }
            }
            return seen
        }

        // The stranger's handshake completes (iroh accepts any key), then the gate closes it.
        let strangerConnection = try await within(10) { try await stranger.connect(addr: serverAddr, alpn: tunnelALPN) }
        let reason = try await within(10) { await strangerConnection.closed() }
        XCTAssertTrue(reason.contains("403"), reason)
        let strangerStream = try? await strangerConnection.openBi()
        XCTAssertNil(strangerStream, "a refused connection opened a stream")
        let condition1 = await eventually(5) { refused.withLock { $0 } == [stranger.id().toBytes()] }
        XCTAssertTrue(condition1)

        let outcome = await dialAndEcho(paired, serverAddr, message: "hello")
        XCTAssertEqual(outcome, .served)

        // Pairing a device changes the list of the running gate; no second gate.
        gate.setAllowed([paired.id().toBytes(), stranger.id().toBytes()])
        XCTAssertTrue(gate.allows(stranger.id()))
        let second = await dialAndEcho(stranger, serverAddr, message: "paired now")
        XCTAssertEqual(second, .served)
        let seen = try await within(10) { await acceptedTask.value }
        XCTAssertEqual(seen, [paired.id().toBytes() + Data("hello".utf8), stranger.id().toBytes() + Data("paired now".utf8)])
        XCTAssertEqual(refused.withLock { $0.count }, 1)

        try await paired.close()
        try await stranger.close()
        try await server.close()
    }

    /// A stream that ends does not leave the gate taking connections that
    /// nobody serves: the next connection is refused at once, and a new stream
    /// from the same gate gets every connection after that. A second gate on
    /// the same endpoint takes over once the first gate's loop, still waiting
    /// in acceptNext, has refused at most one. No dial is left open with
    /// nothing serving it.
    func testPeerGateAfterAStreamEnds() async throws {
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
        let paired = try await Endpoint.bind(options: .test())
        let serverAddr = try loopbackAddr(of: server)
        let gate = IrohPeerGate(endpoint: server, allowed: [paired.id().toBytes()])

        // A stream that serves one connection, then its reader stops.
        let first = serve(gate.connections())
        let firstDial = await dialAndEcho(paired, serverAddr, message: "one")
        XCTAssertEqual(firstDial, .served)
        first.cancel()
        _ = await first.value
        let afterEnd = await dialAndEcho(paired, serverAddr, message: "nobody reads")
        XCTAssertEqual(afterEnd, .refused)

        // The same gate, a new stream: every dial is served.
        let second = serve(gate.connections())
        for index in 0..<4 {
            let outcome = await dialAndEcho(paired, serverAddr, message: "second \(index)")
            XCTAssertEqual(outcome, .served, "dial \(index)")
        }
        second.cancel()
        _ = await second.value

        // A second gate on the same endpoint while the first one's loop waits.
        let other = IrohPeerGate(endpoint: server, allowed: [paired.id().toBytes()])
        let third = serve(other.connections())
        var outcomes: [DialOutcome] = []
        for index in 0..<4 {
            outcomes.append(await dialAndEcho(paired, serverAddr, message: "third \(index)"))
        }
        XCTAssertFalse(outcomes.contains(.timedOut), "\(outcomes)")
        XCTAssertFalse(outcomes.contains(.closedUnserved), "\(outcomes)")
        XCTAssertLessThanOrEqual(outcomes.filter { $0 == .refused }.count, 1, "\(outcomes)")
        XCTAssertEqual(outcomes.last, .served, "\(outcomes)")
        third.cancel()
        _ = await third.value

        try await paired.close()
        try await server.close()
    }

    /// Handshakes in progress are capped: with the only slot taken by a
    /// handshake that never finishes, the next connection is refused at once.
    /// Finished handshakes free their slot.
    func testPeerGateLimitsHandshakesInProgress() async throws {
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
        let paired = try await Endpoint.bind(options: .test())
        let stalled = try await Endpoint.bind(options: .test())
        let serverAddr = try loopbackAddr(of: server)
        let gate = IrohPeerGate(
            endpoint: server,
            allowed: [paired.id().toBytes(), stalled.id().toBytes()],
            maxPendingHandshakes: 1,
            handshakeTimeout: .seconds(60)
        )
        let serving = serve(gate.connections())

        for index in 0..<3 {
            let outcome = await dialAndEcho(paired, serverAddr, message: "in turn \(index)")
            XCTAssertEqual(outcome, .served, "dial \(index)")
        }
        let freed = await eventually(5) { gate.pendingHandshakes == 0 }
        XCTAssertTrue(freed)

        // The proxy passes the server's retry to the client and nothing after it.
        let proxy = try StallingUDPProxy(target: try ipv4Port(of: server), serverDatagrams: 1)
        defer { proxy.stop() }
        let stalledDial = Task { try? await stalled.connect(addr: proxy.addr(of: server), alpn: tunnelALPN) }
        let taken = await eventually(10) { gate.pendingHandshakes == 1 }
        XCTAssertTrue(taken, "the stalled handshake never started")

        let started = Date()
        let outcome = await dialAndEcho(paired, serverAddr, message: "over the limit")
        XCTAssertEqual(outcome, .refused)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(gate.pendingHandshakes, 1)

        try await server.close()
        proxy.stop()
        try await stalled.close()
        _ = try? await within(15) { await stalledDial.value }
        serving.cancel()
        _ = await serving.value
        try await paired.close()
    }

    /// One host cannot take every slot. With two handshakes from 127.0.0.1
    /// stalled, the per-source limit (2) refuses a third dial from 127.0.0.1,
    /// while a dial from ::1, another source, is served; the shared slots (4)
    /// are not full.
    func testPeerGateLimitsHandshakesPerSource() async throws {
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
        let paired = try await Endpoint.bind(options: .test())
        let pairedOverIPv6 = try await Endpoint.bind(options: .test())
        let stalled = [try await Endpoint.bind(options: .test()), try await Endpoint.bind(options: .test())]
        let serverAddr = try loopbackAddr(of: server)
        let serverAddr6 = try loopbackAddr6(of: server)
        let gate = IrohPeerGate(
            endpoint: server,
            allowed: [paired.id().toBytes(), pairedOverIPv6.id().toBytes()],
            maxPendingHandshakes: 4,
            handshakeTimeout: .seconds(60)
        )
        XCTAssertEqual(gate.maxPendingHandshakesPerSource, 2)
        let serving = serve(gate.connections())

        let proxies = try stalled.map { _ in try StallingUDPProxy(target: try ipv4Port(of: server), serverDatagrams: 1) }
        defer { proxies.forEach { $0.stop() } }
        let stalledDials = zip(stalled, proxies).map { endpoint, proxy in
            Task { try? await endpoint.connect(addr: proxy.addr(of: server), alpn: tunnelALPN) }
        }
        let taken = await eventually(10) { gate.pendingHandshakes == 2 }
        XCTAssertTrue(taken, "the stalled handshakes never started")

        let started = Date()
        let sameSource = await dialAndEcho(paired, serverAddr, message: "from 127.0.0.1")
        XCTAssertEqual(sameSource, .refused)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let otherSource = await dialAndEcho(pairedOverIPv6, serverAddr6, message: "from ::1")
        XCTAssertEqual(otherSource, .served)
        XCTAssertEqual(gate.pendingHandshakes, 2)

        try await server.close()
        proxies.forEach { $0.stop() }
        for endpoint in stalled { try await endpoint.close() }
        for dial in stalledDials { _ = try? await within(15) { await dial.value } }
        serving.cancel()
        _ = await serving.value
        try await paired.close()
        try await pairedOverIPv6.close()
    }

    /// A handshake that does not complete within the gate's handshakeTimeout is
    /// dropped and its slot freed. Nothing reaches the server once the proxy
    /// stops, so iroh's idle timeouts (15 s for the path, 30 s for the
    /// connection) are all that ends it otherwise: a gate with a 60 s timeout
    /// still holds its slot 3 s later, and one with a 1 s timeout frees it and
    /// serves the next dial.
    func testPeerGateDropsAHandshakeAtItsDeadline() async throws {
        for timeout in [Duration.seconds(60), .seconds(1)] {
            let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
            let paired = try await Endpoint.bind(options: .test())
            let stalled = try await Endpoint.bind(options: .test())
            let gate = IrohPeerGate(
                endpoint: server,
                allowed: [paired.id().toBytes()],
                maxPendingHandshakes: 1,
                handshakeTimeout: timeout
            )
            let serving = serve(gate.connections())
            let proxy = try StallingUDPProxy(target: try ipv4Port(of: server), serverDatagrams: 1)
            defer { proxy.stop() }
            let stalledDial = Task { try? await stalled.connect(addr: proxy.addr(of: server), alpn: tunnelALPN) }
            let taken = await eventually(10) { gate.pendingHandshakes == 1 }
            XCTAssertTrue(taken, "the stalled handshake never started (\(timeout))")
            let takenAt = Date()
            proxy.stop()

            if timeout == .seconds(60) {
                try await Task.sleep(for: .seconds(3))
                XCTAssertEqual(gate.pendingHandshakes, 1, "without a deadline the handshake stays")
            } else {
                let freed = await eventually(10) { gate.pendingHandshakes == 0 }
                XCTAssertTrue(freed)
                XCTAssertLessThan(Date().timeIntervalSince(takenAt), 2.5)
                let outcome = await dialAndEcho(paired, try loopbackAddr(of: server), message: "after the deadline")
                XCTAssertEqual(outcome, .served)
            }

            try await server.close()
            try await stalled.close()
            _ = try? await within(15) { await stalledDial.value }
            serving.cancel()
            _ = await serving.value
            try await paired.close()
        }
    }

    /// The Mac is reached through its relay; the gate's address validation
    /// (a QUIC retry) and peer check work on a relayed connection too. Before
    /// the gate has a list, a paired device's relayed connection is closed with
    /// 503 (come back), not 403. A relayed sender that is not listed gets its
    /// handshake and is closed with 403, as on a direct path, so a device that
    /// is no longer admitted learns it on the fallback too. Relayed handshakes
    /// of listed senders do not need the shared slots: with the only one held
    /// by a stalled direct handshake, a paired device still gets in through the
    /// relay.
    func testPeerGateOverARelay() async throws {
        let relay = try TestRelay.startHTTP()
        defer { relay.stop() }
        let relayMode = try RelayMode.customFromUrls(urls: [relay.url])
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN], relayMode: relayMode))
        let paired = try await Endpoint.bind(options: .test(relayMode: relayMode))
        // A second device that knows the Mac only by its relay (the first may
        // have learned a direct path during its connection).
        let pairedLater = try await Endpoint.bind(options: .test(relayMode: relayMode))
        let stranger = try await Endpoint.bind(options: .test(relayMode: relayMode))
        let stalled = try await Endpoint.bind(options: .test())
        for endpoint in [server, paired, pairedLater, stranger] {
            try await within(10) { await endpoint.online() }
        }
        let gate = IrohPeerGate(endpoint: server, maxPendingHandshakes: 1, handshakeTimeout: .seconds(60))
        let refused = Mutex<[Data]>([])
        let serving = serve(gate.connections { id in refused.withLock { $0.append(id.toBytes()) } })
        let relayOnly = EndpointAddr(id: server.id(), relayUrl: relay.url, addresses: [])

        let beforeList = try await closeReason(paired, relayOnly)
        XCTAssertTrue(beforeList.contains("503"), beforeList)
        XCTAssertEqual(refused.withLock { $0 }, [], "a gate without a list refused a peer")
        gate.setAllowed([paired.id().toBytes(), pairedLater.id().toBytes()])

        let outcome = await dialAndEcho(paired, relayOnly, message: "through the relay")
        XCTAssertEqual(outcome, .served)

        let strangerReason = try await closeReason(stranger, relayOnly)
        XCTAssertTrue(strangerReason.contains("403"), strangerReason)
        let reported = await eventually(5) { refused.withLock { $0 } == [stranger.id().toBytes()] }
        XCTAssertTrue(reported, "the relayed stranger was not reported as refused")
        XCTAssertEqual(gate.pendingHandshakes, 0)

        let proxy = try StallingUDPProxy(target: try ipv4Port(of: server), serverDatagrams: 1)
        defer { proxy.stop() }
        let stalledDial = Task { try? await stalled.connect(addr: proxy.addr(of: server), alpn: tunnelALPN) }
        let taken = await eventually(10) { gate.pendingHandshakes == 1 }
        XCTAssertTrue(taken, "the stalled handshake never started")
        let whileFull = await dialAndEcho(pairedLater, relayOnly, message: "slots full")
        XCTAssertEqual(whileFull, .served)
        XCTAssertEqual(gate.pendingHandshakes, 1)

        try await server.close()
        proxy.stop()
        try await stalled.close()
        _ = try? await within(15) { await stalledDial.value }
        serving.cancel()
        _ = await serving.value
        try await paired.close()
        try await pairedLater.close()
        try await stranger.close()
    }

    /// A phone reaches a Mac that has only a relay (carrier-grade NAT, the n0
    /// fallback on) only from an endpoint that runs with that relay: iroh dials
    /// through a relay only when the dialing endpoint has it, so the address
    /// record's relay-only route is dialed with `RelayMode.customFromUrls` of
    /// the route's relay (AgentLandCore's `RemoteAccessTunnelRoute`
    /// `endpointRelayURLs`), never with the relay mode of a kept entry whose
    /// fallback is off. Both phones are listed by the gate, so the relay mode
    /// is the only difference.
    func testARelayOnlyAddressNeedsTheRelayInTheDialersRelayMode() async throws {
        let relay = try TestRelay.startHTTP()
        defer { relay.stop() }
        let relayMode = try RelayMode.customFromUrls(urls: [relay.url])
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN], relayMode: relayMode))
        let withoutRelay = try await Endpoint.bind(options: .test())
        let withRelay = try await Endpoint.bind(options: .test(relayMode: relayMode))
        for endpoint in [server, withRelay] {
            try await within(10) { await endpoint.online() }
        }
        let gate = IrohPeerGate(endpoint: server)
        gate.setAllowed([withoutRelay.id().toBytes(), withRelay.id().toBytes()])
        let serving = serve(gate.connections())
        let relayOnly = EndpointAddr(id: server.id(), relayUrl: relay.url, addresses: [])

        let unreached = await dialAndEcho(withoutRelay, relayOnly, message: "no relay")
        XCTAssertNotEqual(unreached, .served, "an endpoint without relays reached a relay-only address")
        let reached = await dialAndEcho(withRelay, relayOnly, message: "the route's relay")
        XCTAssertEqual(reached, .served)

        try await server.close()
        try await withoutRelay.close()
        try await withRelay.close()
        serving.cancel()
        _ = await serving.value
    }

    /// A gate made without a list cannot tell a paired device yet: it closes
    /// what it completes with 503, which asks the device to come back, and
    /// calls nobody refused. An empty list refuses (403); a list with the
    /// device serves it.
    func testPeerGateWithoutAListAsksPeersToComeBack() async throws {
        let server = try await Endpoint.bind(options: .test(alpns: [tunnelALPN]))
        let paired = try await Endpoint.bind(options: .test())
        let serverAddr = try loopbackAddr(of: server)
        let gate = IrohPeerGate(endpoint: server)
        XCTAssertNil(gate.allowed)
        XCTAssertFalse(gate.allows(paired.id()))
        let refused = Mutex<[Data]>([])
        let serving = serve(gate.connections { id in refused.withLock { $0.append(id.toBytes()) } })

        for _ in 0..<2 {
            let reason = try await closeReason(paired, serverAddr)
            XCTAssertTrue(reason.contains("503"), reason)
        }
        XCTAssertEqual(refused.withLock { $0 }, [])

        gate.setAllowed([])
        XCTAssertEqual(gate.allowed, [])
        let emptyList = try await closeReason(paired, serverAddr)
        XCTAssertTrue(emptyList.contains("403"), emptyList)
        let reported = await eventually(5) { refused.withLock { $0 } == [paired.id().toBytes()] }
        XCTAssertTrue(reported)

        gate.setAllowed([paired.id().toBytes()])
        let outcome = await dialAndEcho(paired, serverAddr, message: "listed")
        XCTAssertEqual(outcome, .served)

        serving.cancel()
        _ = await serving.value
        try await paired.close()
        try await server.close()
    }

    func testFixedBindPort() async throws {
        let port = try freePort(SOCK_DGRAM)
        let endpoint = try await Endpoint.bind(options: .test(bindPort: port))
        XCTAssertTrue(endpoint.boundSockets().contains("0.0.0.0:\(port)"), "\(endpoint.boundSockets())")
        do {
            let second = try await Endpoint.bind(options: .test(bindPort: port))
            try await second.close()
            XCTFail("a second endpoint bound the same port")
        } catch let error as IrohError {
            XCTAssertEqual(error.kind(), .bind, error.message())
        }
        try await endpoint.close()

        await assertBindFails(.test(bindPort: 0), kind: .invalidInput)
        var both = EndpointOptions.test(bindPort: port)
        both.bindAddr = "0.0.0.0:\(port)"
        await assertBindFails(both, kind: .invalidInput)
    }

    func testExternalAddressesAreAdvertised() async throws {
        let endpoint = try await Endpoint.bind(options: .test(externalAddrs: ["203.0.113.7:4242"]))
        XCTAssertTrue(endpoint.addr().directAddresses().contains("203.0.113.7:4242"))
        try await endpoint.addExternalAddr(addr: "198.51.100.9:5000")
        let condition2 = await eventually(5) { endpoint.addr().directAddresses().contains("198.51.100.9:5000") }
        XCTAssertTrue(condition2)
        let removed = try await endpoint.removeExternalAddr(addr: "198.51.100.9:5000")
        XCTAssertTrue(removed)
        let condition3 = await eventually(5) { !endpoint.addr().directAddresses().contains("198.51.100.9:5000") }
        XCTAssertTrue(condition3)
        try await endpoint.close()

        await assertBindFails(.test(externalAddrs: ["not an address"]), kind: .invalidInput)
    }

    /// IrohLib 1.1.0 aborted the process here ("there is no reactor running").
    func testWatchAddrFromSwiftDoesNotCrashAndReportsChanges() async throws {
        let endpoint = try await Endpoint.bind(options: .test())
        let addresses = AddressRecorder()
        let addrWatch = endpoint.watchAddr(callback: addresses)
        let relayWatch = endpoint.watchHomeRelay(callback: HomeRelayRecorder())
        let networkWatch = endpoint.watchNetworkChange(callback: NetworkChangeRecorder())
        let secondAddrWatch = endpoint.watchAddr(callback: AddressRecorder())

        try await endpoint.addExternalAddr(addr: "192.0.2.10:7000")
        let condition4 = await eventually(5) { addresses.sawAddress("192.0.2.10:7000") }
        XCTAssertTrue(condition4)

        await addrWatch.stop()
        await secondAddrWatch.stop()
        await relayWatch.stop()
        await networkWatch.stop()
        try await endpoint.close()
    }

    /// IrohLib 1.1.0 aborted the process on the second call.
    func testSetLogLevelMoreThanOnce() {
        setLogLevel(level: .error)
        setLogLevel(level: .warn)
        setLogLevel(level: .error)
        setLogLevel(level: .off)
    }

    func testPresetMinimalHasNoRelaysOrPublishing() async throws {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal()))
        XCTAssertNil(endpoint.addr().relayUrl())
        try await endpoint.close()
    }

    /// Options left unset give the minimal preset, not n0's relays and DNS
    /// (the Rust test test_unset_preset_is_minimal also checks that no
    /// address lookup is configured).
    func testUnsetOptionsUseNoN0Relay() async throws {
        let endpoint = try await Endpoint.bind(options: EndpointOptions())
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(endpoint.addr().relayUrl())
        try await endpoint.close()
    }

    /// The case that ended the process: bindPort refused after bindAddr left
    /// the builder empty, and the next call that cannot throw panicked through
    /// the FFI (`try!`). Calls after bind() did the same.
    func testBuilderSurvivesARefusedBindPortAndUseAfterBind() async throws {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.bindAddr(addr: "127.0.0.1:0")
        XCTAssertThrowsError(try builder.bindPort(port: 45124))
        try builder.relayTlsRoots(roots: .embedded)
        builder.alpns(alpns: [tunnelALPN])
        builder.relayMode(mode: RelayMode.disabled())
        let endpoint = try await builder.bind()
        XCTAssertTrue(endpoint.boundSockets().contains { $0.hasPrefix("127.0.0.1:") }, "\(endpoint.boundSockets())")

        XCTAssertThrowsError(try builder.relayTlsRoots(roots: .embedded))
        XCTAssertThrowsError(try builder.externalAddr(addr: "203.0.113.7:4242"))
        XCTAssertThrowsError(try builder.bindPort(port: 45124))
        builder.applyMinimal()
        builder.alpns(alpns: [])
        builder.relayMode(mode: RelayMode.disabled())
        do {
            let second = try await builder.bind()
            try? await second.close()
            XCTFail("a used builder bound again")
        } catch let error as IrohError {
            XCTAssertEqual(error.kind(), .invalidInput, error.message())
        }
        try await endpoint.close()
    }

    private func assertBindFails(_ options: EndpointOptions, kind: IrohErrorKind, line: UInt = #line) async {
        do {
            let endpoint = try await Endpoint.bind(options: options)
            try? await endpoint.close()
            XCTFail("bind succeeded", line: line)
        } catch let error as IrohError {
            XCTAssertEqual(error.kind(), kind, error.message(), line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }
}

enum DialOutcome: Equatable {
    /// Connected, and the server echoed a message.
    case served
    /// The connection attempt failed (the server refused it).
    case refused
    /// Connected, then closed without the message coming back.
    case closedUnserved
    /// No answer within 10 s.
    case timedOut
}

/// Dials `addr`, sends `message` on a stream and expects it back.
func dialAndEcho(_ client: Endpoint, _ addr: EndpointAddr, message: String) async -> DialOutcome {
    let connection: Connection
    do {
        connection = try await within(10) { try await client.connect(addr: addr, alpn: tunnelALPN) }
    } catch is TimedOut {
        return .timedOut
    } catch {
        return .refused
    }
    defer { try? connection.close(errorCode: 0, reason: Data()) }
    do {
        let echoed = try await within(10) { () throws -> Data in
            let stream = try await connection.openBi()
            try await stream.send().writeAll(buf: Data(message.utf8))
            try await stream.send().finish()
            return try await stream.recv().readToEnd(sizeLimit: 1024)
        }
        return echoed == Data(message.utf8) ? .served : .closedUnserved
    } catch is TimedOut {
        return .timedOut
    } catch {
        return .closedUnserved
    }
}

/// Dials `addr` and waits for the server to close the connection; the close's
/// description (it names the application code).
func closeReason(_ client: Endpoint, _ addr: EndpointAddr) async throws -> String {
    let connection = try await within(10) { try await client.connect(addr: addr, alpn: tunnelALPN) }
    let reason = try await within(10) { await connection.closed() }
    let stream = try? await connection.openBi()
    XCTAssertNil(stream, "a closed connection opened a stream")
    return reason
}

/// Echoes one stream of `connection`, then waits for the peer to close it.
func echoOnce(_ connection: Connection) async {
    guard let stream = try? await connection.acceptBi() else { return }
    let data = (try? await stream.recv().readToEnd(sizeLimit: 1024)) ?? Data()
    try? await stream.send().writeAll(buf: data)
    try? await stream.send().finish()
    _ = await connection.closed()
}

/// Serves every connection of `stream` with `echoOnce` until cancelled.
func serve(_ stream: AsyncStream<Connection>) -> Task<Void, Never> {
    Task {
        await withDiscardingTaskGroup { group in
            for await connection in stream {
                group.addTask { await echoOnce(connection) }
            }
        }
    }
}

final class AddressRecorder: AddrChangeCallback, Sendable {
    private let seen = Mutex<[[String]]>([])

    func onChange(addr: EndpointAddr) async throws {
        let direct = addr.directAddresses()
        seen.withLock { $0.append(direct) }
    }

    func sawAddress(_ address: String) -> Bool {
        seen.withLock { $0.contains { $0.contains(address) } }
    }
}

final class HomeRelayRecorder: HomeRelayCallback, Sendable {
    func onChange(relayUrls: [String]) async throws {}
}

final class NetworkChangeRecorder: NetworkChangeCallback, Sendable {
    func onChange() async throws {}
}
