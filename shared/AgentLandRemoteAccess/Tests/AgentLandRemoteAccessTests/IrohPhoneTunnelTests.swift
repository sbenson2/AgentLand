import AgentLandCore
import AgentLandIroh
import CryptoKit
import Foundation
import XCTest
@testable import AgentLandRemoteAccess

/// The phone's tunnel over real iroh endpoints on loopback, with no relay and no router: run these only
/// under shared/AgentLandIroh/Tests/router-ports-denied.sb (see README.md). A stand-in for the Mac admits
/// node IDs with `IrohPeerGate` and bridges each stream to an HTTPS server standing in for the host.
final class IrohPhoneTunnelTests: XCTestCase {
    private let target = HostEndpoint(host: "mac.local", port: 9841)!

    private func phoneKey() throws -> DeviceNodeKey {
        try XCTUnwrap(DeviceNodeKey(secretKey: SecretKey.generate().toBytes()))
    }

    private func probe(_ address: RemoteAccessBridgeAddress, pin: String) async throws -> Bool {
        let routed = try XCTUnwrap(RoutedTransport(address: try ServerAddress(validating: "https://mac.local:9841"), certificateSHA256: pin))
        routed.attachTunnel(address)
        return await routed.probeTunnel(timeout: 10)
    }

    /// The whole way: the phone's endpoint (its Keychain key, no relay) dials the Mac's node ID at its
    /// direct address, the bridge lets URLSession's CONNECT through, and the pinned TLS reaches the host.
    /// Closed (the background) and opened again (the foreground), it binds again with the same key.
    func testThePhoneReachesTheHostThroughItsTunnelWithItsKey() async throws {
        let server = try await TLSTestServer(name: "mac.local")
        defer { server.stop() }
        let key = try phoneKey()
        let mac = try await MacStandIn(allowed: [key.nodeID.publicKey], behavior: .forward(server.port))
        let tunnel = IrohPhoneTunnel(secretKey: key.secretKey)

        let opened = await tunnel.open(mac.route(), target: target, timeout: .seconds(10))
        let address = try opened.get()
        let running = await tunnel.runningRelays
        XCTAssertEqual(running, [], "no relay on a route without one")
        let answered = try await probe(address, pin: server.certificateSHA256)
        XCTAssertTrue(answered)
        XCTAssertEqual(server.paths, ["/v1/health"])
        XCTAssertEqual(mac.remoteIDs, [key.nodeID.publicKey], "the Mac saw the phone's own node ID")
        let noFailure = await tunnel.failure()
        XCTAssertNil(noFailure)

        await tunnel.close()
        let closedRelays = await tunnel.runningRelays
        XCTAssertNil(closedRelays, "no endpoint in the background")
        let stale = try await probe(address, pin: server.certificateSHA256)
        XCTAssertFalse(stale, "the bridge of the last start is gone")

        let again = try await tunnel.open(mac.route(), target: target, timeout: .seconds(10)).get()
        XCTAssertNotEqual(again.secret, address.secret, "a new secret for each start")
        let answeredAgain = try await probe(again, pin: server.certificateSHA256)
        XCTAssertTrue(answeredAgain)
        XCTAssertEqual(mac.remoteIDs, [key.nodeID.publicKey, key.nodeID.publicKey], "bound again with the same key")
        await tunnel.close()
        await mac.close()
    }

    /// The endpoint runs with the route's relay alone, or none: a route that brings a relay starts it
    /// again with that relay, and one without starts it again with none. (The relay here is a closed port
    /// on 127.0.0.1, so nothing leaves the Mac; the direct address still carries the connection.)
    func testTheEndpointRunsWithTheRoutesRelayOnly() async throws {
        let server = try await TLSTestServer(name: "mac.local")
        defer { server.stop() }
        let key = try phoneKey()
        let mac = try await MacStandIn(allowed: [key.nodeID.publicKey], behavior: .forward(server.port))
        let tunnel = IrohPhoneTunnel(secretKey: key.secretKey)
        guard case let .dial(node, addresses, _) = mac.route() else { return XCTFail("a route") }
        let relay = "https://127.0.0.1:9/"

        let withRelay = try await tunnel.open(.dial(nodeID: node, directAddresses: addresses, relayURL: relay), target: target,
                                              timeout: .seconds(10)).get()
        let relays = await tunnel.runningRelays
        XCTAssertEqual(relays, [relay])
        let answered = try await probe(withRelay, pin: server.certificateSHA256)
        XCTAssertTrue(answered)

        let direct = try await tunnel.open(mac.route(), target: target, timeout: .seconds(10)).get()
        let none = await tunnel.runningRelays
        XCTAssertEqual(none, [], "a route without a relay runs the endpoint with none")
        let answeredDirect = try await probe(direct, pin: server.certificateSHA256)
        XCTAssertTrue(answeredDirect)
        await tunnel.close()
        await mac.close()
    }

    /// What the gate answers tells the route logic what to do: 403 (not paired) stops dialing, 503 (no
    /// peer list yet) and a stream the host refused (code 2) are tried again later.
    func testTheMacsRefusalsTellThePhoneWhatHappened() async throws {
        let server = try await TLSTestServer(name: "mac.local")
        defer { server.stop() }
        let key = try phoneKey()

        let notPaired = try await MacStandIn(allowed: [], behavior: .forward(server.port))
        let refusedTunnel = IrohPhoneTunnel(secretKey: key.secretKey)
        if case let .success(address) = await refusedTunnel.open(notPaired.route(), target: target, timeout: .seconds(10)) {
            let answered = try await probe(address, pin: server.certificateSHA256)
            XCTAssertFalse(answered)
        }
        let notAdmitted = await refusedTunnel.failure()
        XCTAssertEqual(notAdmitted, .notAdmitted)
        await refusedTunnel.close()
        await notPaired.close()

        let starting = try await MacStandIn(allowed: nil, behavior: .forward(server.port))
        let waitingTunnel = IrohPhoneTunnel(secretKey: key.secretKey)
        if case let .success(address) = await waitingTunnel.open(starting.route(), target: target, timeout: .seconds(10)) {
            let answered = try await probe(address, pin: server.certificateSHA256)
            XCTAssertFalse(answered)
        }
        let unavailable = await waitingTunnel.failure()
        XCTAssertEqual(unavailable, .unavailable)
        await waitingTunnel.close()
        await starting.close()

        let hostDown = try await MacStandIn(allowed: [key.nodeID.publicKey], behavior: .refuse)
        let downTunnel = IrohPhoneTunnel(secretKey: key.secretKey)
        let address = try await downTunnel.open(hostDown.route(), target: target, timeout: .seconds(10)).get()
        let answered = try await probe(address, pin: server.certificateSHA256)
        XCTAssertFalse(answered)
        let refused = await downTunnel.failure()
        XCTAssertEqual(refused, .hostRefused)
        await downTunnel.close()
        await hostDown.close()
        XCTAssertTrue(server.paths.isEmpty, "none of these reached the host")
    }

    /// The handshake succeeds only with the Mac that holds the node ID the phone learned; nothing else is
    /// a way in, and a dial nobody answers fails within its time.
    func testOnlyTheLearnedNodeIDIsReached() async throws {
        let key = try phoneKey()
        let mac = try await MacStandIn(allowed: [key.nodeID.publicKey], behavior: .refuse)
        let tunnel = IrohPhoneTunnel(secretKey: key.secretKey)
        let impostorID = try XCTUnwrap(IrohNodeID(publicKey: SecretKey.generate().public().toBytes()))
        let wrongKey = await tunnel.open(.dial(nodeID: impostorID, directAddresses: [mac.address], relayURL: nil), target: target,
                                         timeout: .seconds(5))
        XCTAssertEqual(wrongKey, .failure(.noAnswer))
        XCTAssertEqual(mac.remoteIDs, [], "the gate never handed over a connection")

        let silent = try await MacStandIn(allowed: [], behavior: .refuse)
        let silentAddress = silent.address
        await silent.close()
        let start = ContinuousClock.now
        let nobody = await tunnel.open(.dial(nodeID: impostorID, directAddresses: [silentAddress], relayURL: nil), target: target,
                                       timeout: .seconds(2))
        XCTAssertEqual(nobody, .failure(.noAnswer))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(4))
        let nothing = await tunnel.open(.none, target: target, timeout: .seconds(2))
        XCTAssertEqual(nothing, .failure(.noAnswer))
        await tunnel.close()
        await mac.close()
    }

    /// The device's key signs as the Go host verifies: the host's cross-language vector (seed 00…1f)
    /// gives the same node ID and the same proofs through iroh's `SecretKey`.
    func testTheDeviceKeySignsTheHostsVector() throws {
        let key = try XCTUnwrap(DeviceNodeKey(secretKey: Data(0..<32)))
        XCTAssertEqual(key.nodeID.hex, "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
        XCTAssertEqual(key.claim(.pair, binding: "0012345678")?.proof,
                       "f44713a67909e6ff5cfcaa1eb6af9d58a72b48d583e08c4bda9998e8820c7d8b91f88bb40aeeaf0f14354952217463de56c79edf2b8864d506827a1c1abca40b")
        XCTAssertEqual(key.claim(.register, binding: "9c1e44d0a7b2c35f8e016d42")?.proof,
                       "3d2c1c5c1712258597954c7749de7ef20dcefc0f0b8f89ced84816af6a763ed87272ee7b0fe5aba8c0218f9d9cb4bd6c4fd17d0706f8579dbb473d7a8c350404")
        XCTAssertNil(DeviceNodeKey(secretKey: Data(repeating: 1, count: 31)))
        let made = try phoneKey()
        let claim = try XCTUnwrap(made.claim(.register, binding: "d1"))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: made.nodeID.publicKey)
        XCTAssertTrue(publicKey.isValidSignature(try XCTUnwrap(Data(hex: claim.proof)),
                                                 for: IrohNodeProof.message(purpose: .register, binding: "d1", nodeID: made.nodeID)))
    }

    func testReadErrorsNameTheirResetCode() {
        XCTAssertEqual(IrohTunnelStream.resetCode(in: "stream reset by peer: error 2"), 2)
        XCTAssertEqual(IrohTunnelStream.resetCode(in: "IrohError(stream reset by peer: error 1)"), 1)
        XCTAssertNil(IrohTunnelStream.resetCode(in: "connection lost"))
    }
}

/// The Mac's side for these tests: an endpoint with `IrohPeerGate` (a list, or none yet) that bridges
/// each stream of an admitted connection to a TCP port, or refuses it as a host that is not running
/// (reset and stop with code 2).
final class MacStandIn: @unchecked Sendable {
    enum Behavior { case forward(UInt16), refuse }

    let endpoint: Endpoint
    let gate: IrohPeerGate
    let address: String
    private let behavior: Behavior
    private let seen = Locked<[Data]>([])
    private var serving: Task<Void, Never>?

    var remoteIDs: [Data] { seen.withLock { $0 } }

    init(allowed: Set<Data>?, behavior: Behavior) async throws {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), alpns: [RemoteAccessTunnel.alpn],
                                                                        relayMode: RelayMode.disabled()))
        self.endpoint = endpoint
        gate = allowed.map { IrohPeerGate(endpoint: endpoint, allowed: $0) } ?? IrohPeerGate(endpoint: endpoint)
        let port = try XCTUnwrap(endpoint.boundSockets().first { $0.hasPrefix("0.0.0.0:") }?.split(separator: ":").last)
        address = "127.0.0.1:\(port)"
        self.behavior = behavior
        let connections = gate.connections()
        let seen = self.seen
        serving = Task {
            for await connection in connections {
                seen.withLock { $0.append(connection.remoteId().toBytes()) }
                Task { await Self.serve(connection, behavior) }
            }
        }
    }

    func route() -> RemoteAccessTunnelRoute {
        .dial(nodeID: IrohNodeID(publicKey: endpoint.id().toBytes())!, directAddresses: [address], relayURL: nil)
    }

    func close() async {
        serving?.cancel()
        try? await endpoint.close()
    }

    private static func serve(_ connection: Connection, _ behavior: Behavior) async {
        while let stream = try? await connection.acceptBi() {
            Task { await bridge(stream, behavior) }
        }
    }

    private static func bridge(_ stream: BiStream, _ behavior: Behavior) async {
        let send = stream.send(), receive = stream.recv()
        guard case let .forward(port) = behavior, let socket = try? await LoopbackSocket.connect(port: port) else {
            try? await send.reset(errorCode: RemoteAccessTunnel.StreamCode.refused.rawValue)
            try? await receive.stop(errorCode: RemoteAccessTunnel.StreamCode.refused.rawValue)
            return
        }
        async let up: Void = {
            while let data = try? await receive.read(sizeLimit: 65536), !data.isEmpty {
                guard (try? await socket.write(data)) != nil else { break }
            }
            socket.shutdownOutput()
        }()
        async let down: Void = {
            while let data = try? await socket.read(max: 65536), !data.isEmpty {
                guard (try? await send.writeAll(buf: data)) != nil else { break }
            }
            try? await send.finish()
        }()
        _ = await (up, down)
        socket.close()
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
