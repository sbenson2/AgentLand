import CryptoKit
import XCTest
import AgentLandCore
import AgentLandDesign
import AgentLandNotifications
import AgentLandRemoteAccess
@testable import AgentLand

// Remote access on the phone (docs/HOST-API.md "Remote access (iroh)"), with fakes for the Mac, the
// phone's tunnel, its key and the iCloud record: no iroh endpoint is bound and no CloudKit container made.

private let macNode = IrohNodeID(hex: String(repeating: "b", count: 64))!
private let newMacNode = IrohNodeID(hex: String(repeating: "c", count: 64))!

/// The device's key, signing with CryptoKit's Ed25519 (iroh's signatures are the same bytes' proofs).
private final class FakeKeys: DeviceNodeKeyProviding, @unchecked Sendable {
    let signing = Curve25519.Signing.PrivateKey()
    var nodeID: IrohNodeID { IrohNodeID(publicKey: signing.publicKey.rawRepresentation)! }
    func deviceKey() -> DeviceNodeKey? {
        let signing = self.signing
        return DeviceNodeKey(nodeID: nodeID, secretKey: signing.rawRepresentation, sign: { try? signing.signature(for: $0) })
    }
    func verifies(_ proof: String, _ purpose: IrohNodeProof.Purpose, binding: String) -> Bool {
        guard let signature = Data(hexString: proof) else { return false }
        return signing.publicKey.isValidSignature(signature, for: IrohNodeProof.message(purpose: purpose, binding: binding, nodeID: nodeID))
    }
}

/// The phone's tunnel: what `open` answers and why a link failed, and what the app asked of it.
private final class FakeTunnel: RemoteAccessTunnelConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var openResult: Result<RemoteAccessBridgeAddress, RemoteAccessTunnelFailure> = .success(RemoteAccessBridgeAddress(port: 50001, secret: "s"))
    private var linkFailure: RemoteAccessTunnelFailure?
    private var routes: [RemoteAccessTunnelRoute] = []
    private var targets: [HostEndpoint] = []
    private var closes = 0

    func answer(_ result: Result<RemoteAccessBridgeAddress, RemoteAccessTunnelFailure>, failure: RemoteAccessTunnelFailure? = nil) {
        lock.withLock { openResult = result; linkFailure = failure }
    }
    var opened: [RemoteAccessTunnelRoute] { lock.withLock { routes } }
    var openedTargets: [HostEndpoint] { lock.withLock { targets } }
    var closed: Int { lock.withLock { closes } }

    func open(_ route: RemoteAccessTunnelRoute, target: HostEndpoint, timeout: Duration) async -> Result<RemoteAccessBridgeAddress, RemoteAccessTunnelFailure> {
        lock.withLock {
            routes.append(route)
            targets.append(target)
            return openResult
        }
    }
    func failure() async -> RemoteAccessTunnelFailure? { lock.withLock { linkFailure } }
    func close() async { lock.withLock { closes += 1 } }
}

private final class FakeRecords: RemoteAccessAddressFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteAccessAddressRecord?
    private var asked: [String] = []
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    func set(_ record: RemoteAccessAddressRecord?) { lock.withLock { value = record } }
    var fetches: [String] { lock.withLock { asked } }
    /// Fetches from now on wait until `release()`, as a slow iCloud does.
    func hold() { lock.withLock { holding = true } }
    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding = false
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }
    func record(hostID: String) async -> RemoteAccessAddressRecord? {
        let wait = lock.withLock { () -> Bool in
            asked.append(hostID)
            return holding
        }
        if wait {
            await withCheckedContinuation { continuation in
                let released = lock.withLock { () -> Bool in
                    guard holding else { return true }
                    held = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }
        return lock.withLock { value }
    }
}

/// The Mac behind every route: which addresses answer, whether the tunnel does, its capabilities, and
/// what reached it.
private final class FakeMac: @unchecked Sendable {
    private let lock = NSLock()
    private var answering: Set<String>
    private var tunnelAnswers = true
    private var remoteAccessJSON: String?
    private var pulseRevision: String?
    private var tunnelPulseError: String?
    private var log: [String] = []
    private var bodies: [String: [Data]] = [:]
    private var pulses: [AsyncThrowingStream<String, Error>.Continuation] = []
    var registeredNode: String?

    init(answering: Set<String>, remoteAccess: String?) {
        self.answering = answering
        remoteAccessJSON = remoteAccess
    }

    func answer(only authorities: Set<String>) { lock.withLock { answering = authorities } }
    func tunnel(answers: Bool) { lock.withLock { tunnelAnswers = answers } }
    func list(remoteAccess: String?) { lock.withLock { remoteAccessJSON = remoteAccess } }
    func pulseAnnounces(revision: String?) { lock.withLock { pulseRevision = revision } }
    func tunnelPulseFails(with code: String?) { lock.withLock { tunnelPulseError = code } }
    func dropPulses() {
        let open = lock.withLock { () -> [AsyncThrowingStream<String, Error>.Continuation] in
            defer { pulses = [] }
            return pulses
        }
        open.forEach { $0.finish(throwing: URLError(.networkConnectionLost)) }
    }
    var requests: [String] { lock.withLock { log } }
    func count(_ path: String, via route: String? = nil) -> Int {
        requests.filter { $0.hasSuffix(" " + path) && (route == nil || $0.hasPrefix(route! + " ")) }.count
    }
    func body(of path: String) -> [String: Any]? {
        lock.withLock { bodies[path]?.last }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var capabilities: String {
        let entry = lock.withLock { remoteAccessJSON }
        return #"{"interactions":false,"terminal":true"# + (entry.map { #","remoteAccess":"# + $0 } ?? "") + "}"
    }

    func transport(_ endpoint: HostEndpoint) -> any APITransport { Route(name: endpoint.authority, mac: self) }
    func tunnelTransport(_ bridge: RemoteAccessBridgeAddress) -> any APITransport { Route(name: "tunnel", mac: self) }

    fileprivate func reach(_ name: String, _ request: URLRequest) -> Bool {
        lock.withLock {
            log.append(name + " " + (request.url?.path ?? ""))
            if let body = request.httpBody, let path = request.url?.path { bodies[path, default: []].append(body) }
            return name == "tunnel" ? tunnelAnswers : answering.contains(name)
        }
    }

    fileprivate func openPulse(tunnel: Bool) -> (AsyncThrowingStream<String, Error>, Int) {
        let (revision, failure) = lock.withLock { (pulseRevision, tunnel ? tunnelPulseError : nil) }
        if let failure {
            let body = #"{"error":{"code":"\#(failure)","message":"refused"}}"#
            return (AsyncThrowingStream { $0.yield(body); $0.finish() }, 403)
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"{"type":"ready","intervalMs":1500}"#)
            if let revision { continuation.yield(#"{"type":"remoteAccess","revision":"\#(revision)"}"#) }
            lock.withLock { pulses.append(continuation) }
        }
        return (stream, 200)
    }

    private struct Route: APITransport {
        let name: String
        let mac: FakeMac

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard mac.reach(name, request) else { throw URLError(.cannotConnectToHost) }
            var status = 200
            let body: String
            switch request.url?.path {
            case "/v1/health": body = #"{"status":"ok","protocolVersion":1}"#
            case "/v1/capabilities": body = mac.capabilities
            case "/v1/projects": body = #"{"projects":[{"id":"p","name":"Project"}]}"#
            case "/v1/remote-access/device":
                let node = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["nodeId"] as? String ?? ""
                mac.registeredNode = node
                body = #"{"nodeId":"\#(node)"}"#
            case "/v1/pair":
                body = #"{"deviceId":"device-1","token":"t"}"#
            default:
                status = 202
                body = #"{"accepted":true}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
            guard mac.reach(name, request) else { throw URLError(.cannotConnectToHost) }
            let (stream, status) = mac.openPulse(tunnel: name == "tunnel")
            return (stream, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@MainActor private func eventually(within seconds: Double = 8, _ condition: @escaping @MainActor () -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "Timed out waiting for the remote access state", file: file, line: line)
}

@MainActor final class RemoteAccessAppTests: XCTestCase {
    private let pin = String(repeating: "ab", count: 32)
    private let address = "https://mac.local:9841"
    private let keys = FakeKeys()
    private let tunnel = FakeTunnel()
    private let records = FakeRecords()
    private var routes: [HostRoute] {
        [HostRoute(kind: "local", host: "mac.local", port: 9841)!,
         HostRoute(kind: "tailscale", host: "mac.tail.ts.net", addresses: ["100.64.0.1"], port: 9841)!]
    }

    private func entry(enabled: Bool = true, node: IrohNodeID = macNode, addresses: [String] = ["1.2.3.4:38842"], relay: String? = nil,
                       sequence: Int = 7, revision: String = "r1", device: IrohNodeID? = nil) -> String {
        var json = #"{"version":1,"revision":"\#(revision)","enabled":\#(enabled),"nodeId":"\#(node.hex)","directAddresses":["#
            + addresses.map { "\"\($0)\"" }.joined(separator: ",") + #"],"fallbackRelay":\#(relay != nil)"#
        if let relay { json += #","relayUrl":"\#(relay)""# }
        json += #","sequence":\#(sequence)"#
        if let device { json += #","deviceNodeId":"\#(device.hex)""# }
        return json + "}"
    }

    private func kept(_ json: String) throws -> RemoteAccessCapabilities {
        try JSONDecoder().decode(RemoteAccessCapabilities.self, from: Data(json.utf8))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "remote-access-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private var tunnelFactoryCalls = 0

    /// A model showing `host` with a client over the fake Mac, as `select` builds it, and the fake tunnel,
    /// key and record.
    private func model(_ host: SavedHost, _ mac: FakeMac, defaults: UserDefaults? = nil) throws -> AppModel {
        let tunnel = self.tunnel
        let model = AppModel(defaults: try defaults ?? self.defaults(), remoteAccess: RemoteAccessServices(
            nodeKeys: keys, makeTunnel: { [weak self] _ in self?.tunnelFactoryCalls += 1; return tunnel }, addressRecords: records))
        model.routeStagger = .milliseconds(20)
        model.routeProbeTimeout = 1
        model.routeRetryDelays = [.milliseconds(100), .milliseconds(200)]
        model.tunnelProbeTimeout = .seconds(2)
        model.hosts = [host]
        model.persistHosts()
        model.select(host)
        let serverAddress = try ServerAddress(validating: host.address)
        let transport = try XCTUnwrap(RoutedTransport(address: serverAddress, certificateSHA256: host.certificateSHA256,
                                                      endpoint: host.lastEndpoint,
                                                      transports: { endpoint, _ in mac.transport(endpoint) },
                                                      tunnelTransports: { bridge, _ in mac.tunnelTransport(bridge) }))
        model.client = APIClient(address: serverAddress, token: "token", transport: transport)
        addTeardownBlock { @MainActor in model.handleScenePhase(.background) }
        return model
    }

    private func host(remoteAccess json: String? = nil, refused: Bool = false) throws -> SavedHost {
        SavedHost(address: address, deviceID: "device-1", name: "Mac", mode: .direct, certificateSHA256: pin, routes: routes,
                  remoteAccess: try json.map(kept), tunnelRefused: refused)
    }

    // MARK: What the device keeps and registers

    /// The kept entry follows what the host lists and is saved with the host; a host that lists none (a
    /// host started without the tunnel socket) leaves it, and the owner's off replaces it.
    func testTheKeptEntryFollowsTheHostAndOutlivesAHostThatListsNone() async throws {
        let defaults = try defaults()
        let mac = FakeMac(answering: ["mac.local:9841"], remoteAccess: entry(device: keys.nodeID))
        let model = try model(try host(), mac, defaults: defaults)
        await model.refreshProjects()
        XCTAssertEqual(model.selectedHost?.remoteAccess, try kept(entry(device: keys.nodeID)))
        let saved = try JSONDecoder().decode([SavedHost].self, from: try XCTUnwrap(defaults.data(forKey: ProductIdentity.connectionsDefaultsKey)))
        XCTAssertEqual(saved.first?.remoteAccess?.nodeID, macNode, "saved with the host")

        mac.list(remoteAccess: nil)
        await model.refreshProjects()
        XCTAssertEqual(model.selectedHost?.remoteAccess?.enabled, true, "a host that lists none leaves the kept entry")

        mac.list(remoteAccess: entry(enabled: false, addresses: [], sequence: 8, revision: "r2", device: keys.nodeID))
        await model.refreshProjects()
        XCTAssertEqual(model.selectedHost?.remoteAccess?.enabled, false, "off from the host is the owner's word")
        XCTAssertEqual(model.selectedHost?.remoteAccess?.sequence, 8)
        XCTAssertEqual(mac.count("/v1/remote-access/device"), 0, "the host has this device's node ID")
    }

    /// A device paired before remote access registers its node ID the next time it connects at home: with
    /// a proof bound to its device ID, once.
    func testADevicePairedBeforeRegistersItsNodeIDAtHome() async throws {
        let mac = FakeMac(answering: ["mac.local:9841"], remoteAccess: entry())
        let model = try model(try host(), mac)
        await model.refreshProjects()
        await eventually { mac.count("/v1/remote-access/device") == 1 && model.selectedHost?.remoteAccess?.deviceNodeID == self.keys.nodeID }
        let body = try XCTUnwrap(mac.body(of: "/v1/remote-access/device"))
        XCTAssertEqual(body["nodeId"] as? String, keys.nodeID.hex)
        XCTAssertTrue(keys.verifies(try XCTUnwrap(body["proof"] as? String), .register, binding: "device-1"))
        mac.list(remoteAccess: entry(device: keys.nodeID))
        await model.refreshProjects()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(mac.count("/v1/remote-access/device"), 1, "registering happens only while the host does not have it")
    }

    /// Through the tunnel the phone reads capabilities (and keeps the entry) but never registers: the host
    /// refuses it there, and registering belongs to a connection at home or over Tailscale.
    func testTheTunnelNeverRegisters() async throws {
        let mac = FakeMac(answering: [], remoteAccess: entry(sequence: 8, revision: "r2"))
        let model = try model(try host(remoteAccess: entry()), mac)
        model.handleScenePhase(.active)
        await eventually { model.activeRoute == .tunnel && model.selectedHost?.remoteAccess?.revision == "r2" }
        XCTAssertGreaterThan(mac.count("/v1/capabilities", via: "tunnel"), 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(mac.count("/v1/remote-access/device"), 0)
    }

    /// Pairing from an invitation that carries remote access sends the node ID with a proof bound to the
    /// code exactly as sent; without it, neither.
    func testPairingGivesTheNodeIDOnlyWhenTheInvitationCarriesRemoteAccess() async throws {
        let model = AppModel(defaults: try defaults(), remoteAccess: RemoteAccessServices(nodeKeys: keys, makeTunnel: { _ in nil },
                                                                                          addressRecords: records))
        let claim = try XCTUnwrap(model.pairingClaim(code: "0012345678"))
        XCTAssertEqual(claim.nodeID, keys.nodeID)
        XCTAssertTrue(keys.verifies(claim.proof, .pair, binding: "0012345678"))
        XCTAssertFalse(keys.verifies(claim.proof, .pair, binding: "0012345679"))
    }

    // MARK: The tunnel in the race

    /// Away from home with no address answering: the tunnel is tried last, dials the Mac's node ID at the
    /// kept addresses, carries the pulse, and is never saved as the address that answered last. Back
    /// home, the addresses answer again and take over as a recovery; the tunnel closes.
    func testTheTunnelIsTriedLastAndCarriesTheConnectionUntilAnAddressAnswers() async throws {
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        model.homewardInterval = .milliseconds(300)
        model.handleScenePhase(.active)
        await eventually { model.connection == .online && model.activeRoute == .tunnel }
        let probes = mac.requests.filter { $0.hasSuffix("/v1/health") }.map { String($0.split(separator: " ")[0]) }
        XCTAssertEqual(Array(probes.prefix(3)), ["mac.local:9841", "mac.tail.ts.net:9841", "100.64.0.1:9841"])
        let firstTunnel = try XCTUnwrap(probes.firstIndex(of: "tunnel"))
        for address in ["mac.local:9841", "mac.tail.ts.net:9841", "100.64.0.1:9841"] {
            XCTAssertLessThan(try XCTUnwrap(probes.firstIndex(of: address)), firstTunnel, "the tunnel after every address")
        }
        XCTAssertEqual(tunnel.opened.first, .dial(nodeID: macNode, directAddresses: ["1.2.3.4:38842"], relayURL: nil))
        XCTAssertEqual(tunnel.openedTargets.first?.authority, "mac.local:9841", "CONNECT names the paired address")
        XCTAssertGreaterThan(mac.count("/v1/pulse", via: "tunnel"), 0, "the pulse runs through the tunnel")
        XCTAssertEqual(model.tunnelState, .connected)
        XCTAssertNil(model.hosts.first?.lastEndpoint, "the tunnel is never the address that answered last")
        let epoch = model.workspace.connectionEpoch

        mac.answer(only: ["mac.local:9841"])
        await eventually { model.activeRoute == .address(HostEndpoint(host: "mac.local", port: 9841)!) && model.connection == .online }
        await eventually { model.workspace.connectionEpoch == epoch + 1 }
        XCTAssertGreaterThan(tunnel.closed, 0, "home again: the phone's endpoint stops")
        XCTAssertEqual(model.tunnelState, .idle)
    }

    /// The owner turned the switch on while the phone was away (its entry says off): once every address
    /// has failed, the phone reads the Mac's address record, and dials it only when it follows a later
    /// report than the entry it keeps.
    func testTheAddressRecordRescuesAnEntryThatSaysOff() async throws {
        records.set(RemoteAccessAddressRecord(nodeID: macNode.hex, directAddresses: ["5.6.7.8:40000"], relayURL: nil, sequence: 8))
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let model = try model(try host(remoteAccess: entry(enabled: false, addresses: [], sequence: 7, device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.connection == .online && model.activeRoute == .tunnel }
        XCTAssertEqual(tunnel.opened.first, .dial(nodeID: macNode, directAddresses: ["5.6.7.8:40000"], relayURL: nil))
        XCTAssertEqual(records.fetches, [NoticeHostID.make(certificateSHA256: pin)!], "fetched once, by the host's notice ID")
    }

    func testARecordThatIsNotNewerOrNamesAnotherKeyIsNotDialed() async throws {
        records.set(RemoteAccessAddressRecord(nodeID: macNode.hex, directAddresses: ["5.6.7.8:40000"], relayURL: nil, sequence: 7))
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let stale = try model(try host(remoteAccess: entry(enabled: false, addresses: [], sequence: 7, device: keys.nodeID)), mac)
        stale.handleScenePhase(.active)
        await eventually { stale.tunnelState == .noRoute }
        XCTAssertEqual(tunnel.opened, [], "a record the Mac has not rewritten changes nothing")
        XCTAssertEqual(records.fetches.count, 1)
        stale.handleScenePhase(.background)

        records.set(RemoteAccessAddressRecord(nodeID: newMacNode.hex, directAddresses: ["5.6.7.8:40000"], relayURL: nil, sequence: 9))
        let moved = try model(try host(remoteAccess: entry(enabled: true, addresses: [], sequence: 7, device: keys.nodeID)), FakeMac(answering: [], remoteAccess: nil))
        moved.handleScenePhase(.active)
        await eventually { moved.tunnelState == .newMacKey }
        XCTAssertEqual(tunnel.opened, [], "a newer record with another node ID is never dialed")
        guard case let .offline(_, detail, _) = moved.connectionStatus else { return XCTFail("offline") }
        XCTAssertEqual(detail, "Connect to Mac at home or over Tailscale once to reach it from anywhere again.")
    }

    /// The gate's 403: the phone stops dialing the tunnel for this saved host, says to connect at home,
    /// and at that connection (the host has its node ID) the tunnel is a candidate again.
    func testNotAdmittedStopsTheTunnelUntilAConnectionAtHome() async throws {
        tunnel.answer(.success(RemoteAccessBridgeAddress(port: 50001, secret: "s")), failure: .notAdmitted)
        let mac = FakeMac(answering: [], remoteAccess: entry(device: keys.nodeID))
        mac.tunnel(answers: false)
        let defaults = try defaults()
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac, defaults: defaults)
        model.handleScenePhase(.active)
        await eventually { model.tunnelState == .notAdmitted && model.connection == .offline(.unreachable) }
        XCTAssertEqual(model.selectedHost?.tunnelRefused, true)
        guard case let .offline(title, detail, _) = model.connectionStatus else { return XCTFail("offline") }
        XCTAssertEqual(title, "Can’t reach Mac")
        XCTAssertEqual(detail, "Away from home, AgentLand connects through Tailscale — check that Tailscale is on. Remote access doesn’t let this device in: connect to Mac at home or over Tailscale to turn it back on, or pair again if Mac removed this device.")
        let saved = try JSONDecoder().decode([SavedHost].self, from: try XCTUnwrap(defaults.data(forKey: ProductIdentity.connectionsDefaultsKey)))
        XCTAssertEqual(saved.first?.tunnelRefused, true, "kept across launches")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(tunnel.opened.count, 1, "not dialed again")

        mac.answer(only: ["mac.local:9841"])
        await eventually { model.connection == .online && model.selectedHost?.tunnelRefused == false }
        XCTAssertEqual(model.tunnelState, .idle, "Settings no longer says the Mac does not admit this device")
        XCTAssertTrue(model.tunnelIsCandidate(model.selectedHost))
    }

    /// A relaunch with the refusal kept: the tunnel is not dialed, and while no address answers the banner
    /// still says why the tunnel is not tried, after the addresses' own advice (the refusal is kept, so it
    /// also shows at home while the Mac sleeps).
    func testAKeptRefusalStillSaysWhyAfterARelaunch() async throws {
        let mac = FakeMac(answering: [], remoteAccess: entry(device: keys.nodeID))
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID), refused: true), mac)
        XCTAssertEqual(model.tunnelState, .notAdmitted)
        model.handleScenePhase(.active)
        await eventually { model.connection == .offline(.unreachable) }
        guard case let .offline(title, detail, _) = model.connectionStatus else { return XCTFail("offline") }
        XCTAssertEqual(title, "Can’t reach Mac")
        XCTAssertEqual(detail, "Away from home, AgentLand connects through Tailscale — check that Tailscale is on. Remote access doesn’t let this device in: connect to Mac at home or over Tailscale to turn it back on, or pair again if Mac removed this device.")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(tunnel.opened.isEmpty, "a kept refusal is not dialed")

        mac.answer(only: ["mac.local:9841"])
        await eventually { model.connection == .online && model.selectedHost?.tunnelRefused == false }
        XCTAssertEqual(model.tunnelState, .idle)
    }

    /// A gate's 503 (the Mac app starting) and a stream the host refused (code 2) say the Mac is not
    /// taking connections; a dial nobody answers says it may be asleep or its address changed. Each is
    /// tried again on the tunnel's own schedule (2 s first), not the addresses'.
    func testOtherFailuresAreTriedAgainOnTheTunnelsSchedule() async throws {
        for (failure, title) in [(RemoteAccessTunnelFailure.unavailable, "Mac isn’t taking connections"),
                                 (.hostRefused, "Mac isn’t taking connections"), (.noAnswer, "Can’t reach Mac")] {
            let tunnel = FakeTunnel()
            tunnel.answer(.failure(failure))
            let mac = FakeMac(answering: [], remoteAccess: nil)
            let model = AppModel(defaults: try defaults(), remoteAccess: RemoteAccessServices(nodeKeys: keys, makeTunnel: { _ in tunnel },
                                                                                              addressRecords: records))
            model.routeStagger = .milliseconds(20)
            model.routeProbeTimeout = 1
            model.routeRetryDelays = [.milliseconds(100)]
            let host = try host(remoteAccess: entry(device: keys.nodeID))
            model.hosts = [host]
            model.select(host)
            let serverAddress = try ServerAddress(validating: address)
            model.client = APIClient(address: serverAddress, token: "token", transport: try XCTUnwrap(RoutedTransport(
                address: serverAddress, certificateSHA256: pin, transports: { endpoint, _ in mac.transport(endpoint) },
                tunnelTransports: { bridge, _ in mac.tunnelTransport(bridge) })))
            model.handleScenePhase(.active)
            await eventually { model.tunnelState == .retrying(failure) }
            guard case let .offline(shown, _, _) = model.connectionStatus else { return XCTFail("offline") }
            XCTAssertEqual(shown, title, "\(failure)")
            XCTAssertEqual(model.selectedHost?.tunnelRefused, false)
            try await Task.sleep(for: .milliseconds(1500))
            XCTAssertEqual(tunnel.opened.count, 1, "\(failure): not on the addresses' schedule")
            await eventually(within: 3) { tunnel.opened.count == 2 }
            model.handleScenePhase(.background)
        }
    }

    /// The phone's endpoint runs only in the foreground: the background closes it, and the foreground
    /// dials again with the same key (one tunnel, made once). With the tunnel gone the connection is down
    /// until it is back: not online and connected with no bridge (typing would go nowhere), but offline
    /// with a banner that says it is reconnecting; its return is a recovery.
    func testTheBackgroundClosesTheTunnelAndTheForegroundDialsAgain() async throws {
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.activeRoute == .tunnel && model.connection == .online }
        let epoch = model.workspace.connectionEpoch
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.background)
        await eventually { self.tunnel.closed == 1 }
        XCTAssertNil(model.client?.routing?.tunnelBridge, "no bridge in the background")
        XCTAssertEqual(model.connection, .offline(.unreachable))
        XCTAssertFalse(model.workspace.reachable, "typing is refused with the offline notice, not sent into no tunnel")
        XCTAssertEqual(model.tunnelState, .reconnecting)
        XCTAssertEqual(model.tunnelStateDescription, "Reconnecting…", "Settings agrees with the banner")
        guard case let .offline(title, detail, _) = model.connectionStatus else { return XCTFail("offline") }
        XCTAssertEqual(title, "Reconnecting to Mac…")
        XCTAssertEqual(detail, "Through remote access. Nothing is sent until the connection is back.")
        tunnel.answer(.success(RemoteAccessBridgeAddress(port: 50002, secret: "t")))
        model.handleScenePhase(.inactive)  // iOS comes back through inactive
        model.handleScenePhase(.active)
        XCTAssertEqual(model.tunnelStateDescription, "Reconnecting…")
        await eventually { model.connection == .online && self.tunnel.opened.count == 2 }
        XCTAssertEqual(model.client?.routing?.tunnelBridge?.port, 50002, "a new bridge, the same route")
        XCTAssertEqual(tunnelFactoryCalls, 1, "one tunnel, with the device's one key")
        XCTAssertEqual(model.tunnelState, .connected)
        XCTAssertEqual(model.workspace.connectionEpoch, epoch + 1, "surfaces resume from their cursors")
    }

    /// The tunnel carried the connection from a newer address record (the kept entry offers no tunnel).
    /// Back from the background, the tunnel's probe first waits for every address to fail and for the
    /// record; all that time Settings says the tunnel is reconnecting, as the banner does, never
    /// "Connected" while nothing is connected.
    func testSettingsSaysReconnectingWhileTheTunnelWaitsForTheRecordAfterTheBackground() async throws {
        records.set(RemoteAccessAddressRecord(nodeID: macNode.hex, directAddresses: ["5.6.7.8:40000"], relayURL: nil, sequence: 8))
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let model = try model(try host(remoteAccess: entry(enabled: false, addresses: [], sequence: 7, device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.connection == .online && model.activeRoute == .tunnel }
        XCTAssertEqual(model.tunnelStateDescription, "Connected")
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.background)

        records.hold()
        model.recordSchedule = RemoteAccessRecordSchedule()  // the next race may fetch the record again
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)
        await eventually { self.records.fetches.count == 2 }
        XCTAssertEqual(tunnel.opened.count, 1, "the probe waits for the record")
        XCTAssertEqual(model.tunnelState, .reconnecting)
        XCTAssertEqual(model.tunnelStateDescription, "Reconnecting…")
        XCTAssertFalse(model.hostReachable)
        guard case let .offline(title, _, _) = model.connectionStatus else { return XCTFail("offline") }
        XCTAssertEqual(title, "Reconnecting to Mac…")

        records.release()
        await eventually { model.connection == .online && self.tunnel.opened.count == 2 }
        XCTAssertEqual(model.tunnelStateDescription, "Connected")
    }

    /// iOS returns from the background through `.inactive` (background, inactive, active). The return
    /// still starts the tunnel's schedule over and reads capabilities once, as the contract says.
    func testAReturnThroughInactiveStartsTheScheduleOverAndReadsCapabilities() async throws {
        let mac = FakeMac(answering: ["mac.local:9841"], remoteAccess: entry(device: keys.nodeID))
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.connection == .online }
        try await Task.sleep(for: .milliseconds(200))
        let before = mac.count("/v1/capabilities")

        _ = model.tunnelBackoff.failed(random: 0)
        _ = model.tunnelBackoff.failed(random: 0)
        model.tunnelNotBefore = .now + .seconds(60)
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.background)
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)
        XCTAssertNil(model.tunnelNotBefore, "the tunnel's schedule starts over")
        XCTAssertEqual(model.tunnelBackoff.failures, 0)
        await eventually { mac.count("/v1/capabilities") == before + 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(mac.count("/v1/capabilities"), before + 1, "read once on the return")

        // Only a trip to the background counts: inactive and back (a system alert) is no return.
        model.tunnelNotBefore = .now + .seconds(60)
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)
        XCTAssertNotNil(model.tunnelNotBefore)
    }

    /// The banner's Retry tries the tunnel at once, not after its backoff (2 s and more here); the
    /// automatic retries keep the tunnel's own schedule.
    func testRetryDialsTheTunnelAtOnce() async throws {
        tunnel.answer(.failure(.unavailable))
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.tunnelState == .retrying(.unavailable) }
        XCTAssertEqual(tunnel.opened.count, 1)
        XCTAssertNotNil(model.tunnelNotBefore)
        model.retryConnection()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(tunnel.opened.count, 1, "an automatic retry waits for the tunnel's schedule")
        model.retryNow()
        await eventually(within: 1) { self.tunnel.opened.count == 2 }
    }

    /// The tunnel carried the connection, then the owner turned the switch off (the kept entry says off,
    /// and no record is newer): the next race has nothing to dial, so the phone's endpoint and bridge
    /// stop instead of running on while no address answers.
    func testNothingToDialClosesTheEndpointAndBridge() async throws {
        let mac = FakeMac(answering: [], remoteAccess: nil)
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.activeRoute == .tunnel && model.connection == .online }
        XCTAssertNotNil(model.client?.routing?.tunnelBridge)
        let hostID = try XCTUnwrap(model.selectedHost?.id)
        model.updateHost(hostID) { $0.remoteAccess = try? self.kept(self.entry(enabled: false, addresses: [], sequence: 8, revision: "r2")) }
        mac.dropPulses()
        await eventually { model.tunnelState == .noRoute }
        await eventually { self.tunnel.closed >= 1 }
        XCTAssertNil(model.client?.routing?.tunnelBridge, "no bridge left listening")
        XCTAssertEqual(tunnel.opened.count, 1)
    }

    /// Another device record holds this device's node ID (the app was reinstalled and paired again): the
    /// host answers 403 `tunnel_device_mismatch` through the tunnel, which the phone takes like the gate's
    /// 403.
    func testATunnelDeviceMismatchStopsTheTunnel() async throws {
        let mac = FakeMac(answering: [], remoteAccess: nil)
        mac.tunnelPulseFails(with: "tunnel_device_mismatch")
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        model.handleScenePhase(.active)
        await eventually { model.tunnelState == .notAdmitted }
        XCTAssertEqual(model.selectedHost?.tunnelRefused, true)
        XCTAssertEqual(model.connection, .offline(.unreachable))
    }

    /// The pulse names the remote-access revision; another than the kept one reads capabilities again.
    func testThePulsesRevisionReadsRemoteAccessAgain() async throws {
        let mac = FakeMac(answering: ["mac.local:9841"], remoteAccess: entry(sequence: 9, revision: "r2", device: keys.nodeID))
        mac.pulseAnnounces(revision: "r2")
        let model = try model(try host(remoteAccess: entry(device: keys.nodeID)), mac)
        let before = mac.count("/v1/capabilities")
        model.handleScenePhase(.active)
        await eventually { model.selectedHost?.remoteAccess?.revision == "r2" }
        XCTAssertGreaterThan(mac.count("/v1/capabilities"), before)
        XCTAssertEqual(model.selectedHost?.remoteAccess?.sequence, 9)
        XCTAssertEqual(tunnel.opened, [], "an address answered; the tunnel was not needed")
    }

    /// A host without a kept node ID (never read remote access) or refused has no tunnel candidate; the
    /// race is the addresses', as before.
    func testNoTunnelWithoutTheMacsNodeID() throws {
        let model = AppModel(defaults: try defaults(), remoteAccess: RemoteAccessServices(nodeKeys: keys, makeTunnel: { [tunnel] _ in tunnel },
                                                                                          addressRecords: records))
        XCTAssertFalse(model.tunnelIsCandidate(try host()))
        XCTAssertFalse(model.tunnelIsCandidate(try host(remoteAccess: entry(device: keys.nodeID), refused: true)))
        XCTAssertTrue(model.tunnelIsCandidate(try host(remoteAccess: entry(enabled: false, addresses: [], device: keys.nodeID))),
                      "a kept node ID: the record may still give a way in")
        let unpinned = SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: nil,
                                 remoteAccess: try kept(entry()))
        XCTAssertFalse(model.tunnelIsCandidate(unpinned))
        let off = AppModel(defaults: try defaults(), remoteAccess: RemoteAccessServices(nodeKeys: keys, makeTunnel: { _ in nil },
                                                                                        addressRecords: records))
        XCTAssertFalse(off.tunnelIsCandidate(try host(remoteAccess: entry(device: keys.nodeID))), "a build whose tunnel is off")
    }

    // MARK: Saved hosts and the record

    func testSavedHostsKeepTheEntryAndRefusalAndLoadWithoutThem() throws {
        let host = try host(remoteAccess: entry(device: keys.nodeID), refused: true)
        let reloaded = try JSONDecoder().decode([SavedHost].self, from: JSONEncoder().encode([host]))
        XCTAssertEqual(reloaded, [host])
        let old = #"[{"address":"https://old.local:9841","deviceID":"d1","name":"Old","mode":"direct","certificateSHA256":"\#(pin)","remoteAccess":{"version":2,"enabled":true},"tunnelRefused":"yes"}]"#
        let loaded = try JSONDecoder().decode([SavedHost].self, from: Data(old.utf8))
        XCTAssertNil(loaded.first?.remoteAccess, "an entry of another version counts as absent")
        XCTAssertEqual(loaded.first?.tunnelRefused, false)
    }

    func testTheRecordsFieldsAreReadAsTheContractNamesThem() {
        let fields: [String: Any] = ["nodeId": macNode.hex, "directAddresses": ["1.2.3.4:38842", "192.168.1.5:38842"],
                                     "relayUrl": "https://use1-1.relay.n0.iroh.link./", "sequence": NSNumber(value: 12), "revision": "r"]
        let record = CloudKitRemoteAccessAddresses.read { fields[$0] }
        XCTAssertEqual(record?.nodeID, macNode)
        XCTAssertEqual(record?.directAddresses, ["1.2.3.4:38842"])
        XCTAssertEqual(record?.relayURL, "https://use1-1.relay.n0.iroh.link./")
        XCTAssertEqual(record?.sequence, 12)
        var local = fields
        local["relayUrl"] = "https://192.168.1.5:3340/"
        XCTAssertNil(CloudKitRemoteAccessAddresses.read { local[$0] }?.relayURL, "a relay on the local network is not taken")
        var unordered = fields
        unordered["sequence"] = nil
        XCTAssertNil(CloudKitRemoteAccessAddresses.read { unordered[$0] }, "no sequence, no record")
        XCTAssertEqual(RemoteAccessServices.live(environment: ["AGENTLAND_REMOTE_ACCESS": "0"]).makeTunnel(keys.deviceKey()!) == nil, true)
    }

    /// A dial nobody answered: without a Tailscale route the banner says the Mac may be asleep or its
    /// address changed; with one, the Tailscale advice stays.
    func testNoAnswerKeepsTheTailscaleAdviceWhenItsRouteIsKnown() throws {
        let model = AppModel(defaults: try defaults(), remoteAccess: RemoteAccessServices(nodeKeys: keys, makeTunnel: { _ in nil },
                                                                                          addressRecords: records))
        model.hosts = [try host(remoteAccess: entry())]
        model.select(model.hosts[0])
        model.tunnelState = .retrying(.noAnswer)
        XCTAssertNil(model.tunnelOfflineStatus(host: "Mac"), "the Tailscale advice")
        let localOnly = SavedHost(address: address, deviceID: "device-1", name: "Mac", mode: .direct, certificateSHA256: pin,
                                  routes: [routes[0]], remoteAccess: try kept(entry()))
        model.hosts = [localOnly]
        model.select(localOnly)
        model.tunnelState = .retrying(.noAnswer)
        guard case let .offline(_, detail, _)? = model.tunnelOfflineStatus(host: "Mac") else { return XCTFail("the tunnel's words") }
        XCTAssertEqual(detail, "The Mac may be asleep or its address changed. Reconnecting… If this keeps up, connect to Mac at home or over Tailscale once.")

        // A kept refusal on a host known only at home: the Mac may simply be asleep, and that comes first.
        model.tunnelState = .notAdmitted
        guard case let .offline(title, refused, _)? = model.tunnelOfflineStatus(host: "Mac") else { return XCTFail("the refusal's words") }
        XCTAssertEqual(title, "Can’t reach Mac")
        XCTAssertEqual(refused, "The Mac may be asleep or on another network. Remote access doesn’t let this device in: connect to Mac at home or over Tailscale to turn it back on, or pair again if Mac removed this device.")
    }

    /// The device's key in its Keychain: made once, the same for every later read and every new store
    /// (another launch), never synchronizable. Uses its own service name and removes it afterwards.
    func testTheDeviceKeyIsMadeOnceAndKeptInTheKeychain() throws {
        let service = "dev.agentland.client.iroh-node-key.tests-\(UUID().uuidString)"
        addTeardownBlock {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        guard let first = KeychainDeviceNodeKeys(service: service).deviceKey() else {
            throw XCTSkip("This simulator's test host has no Keychain access (an unsigned build).")
        }
        XCTAssertEqual(KeychainDeviceNodeKeys(service: service).deviceKey()?.nodeID, first.nodeID, "the same key after a relaunch")
        XCTAssertEqual(first.secretKey.count, 32)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var items: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &items), errSecSuccess)
        let attributes = try XCTUnwrap(items as? [[String: Any]])
        XCTAssertEqual(attributes.count, 1, "one key")
        XCTAssertEqual(attributes.first?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual((attributes.first?[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue, true)
        let claim = try XCTUnwrap(first.claim(.register, binding: "device-1"))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: first.nodeID.publicKey)
        XCTAssertTrue(publicKey.isValidSignature(try XCTUnwrap(Data(hexString: claim.proof)),
                                                 for: IrohNodeProof.message(purpose: .register, binding: "device-1", nodeID: first.nodeID)),
                      "iroh's signature verifies as the host verifies it")
    }

    func testSettingsWordsForTheTunnel() throws {
        let model = AppModel(defaults: try defaults(), remoteAccess: RemoteAccessServices(nodeKeys: keys, makeTunnel: { _ in nil },
                                                                                          addressRecords: records))
        let words: [(TunnelState, String)] = [
            (.idle, "Standing by"), (.connecting, "Connecting…"), (.connected, "Connected"), (.reconnecting, "Reconnecting…"),
            (.retrying(.unavailable), "The Mac isn’t taking connections; trying again soon"),
            (.retrying(.noAnswer), "No answer; trying again soon"),
            (.notAdmitted, "Not admitted by the Mac; connect at home or over Tailscale, or pair again"),
            (.newMacKey, "The Mac has a new key; connect at home or over Tailscale once"),
            (.noRoute, "No way in from outside yet")
        ]
        for (state, text) in words {
            model.tunnelState = state
            XCTAssertEqual(model.tunnelStateDescription, text)
        }
    }

    /// What the Mac reported, as Settings says it: the Mac uses one public relay (never "n0's relays"),
    /// and while it is still picking one the fallback is on without a relay.
    func testSettingsWordsForTheMacsReport() throws {
        let relay = "https://use1-1.relay.n0.iroh.link./"
        let cases: [(String, String)] = [
            (entry(enabled: false, addresses: []), "Off"),
            (entry(), "On"),
            (entry(relay: relay), "On, with a public relay as a fallback"),
            (entry(addresses: [], relay: relay), "On, through a public relay"),
            (entry(addresses: []), "On, no address from outside yet"),
            (#"{"version":1,"enabled":true,"nodeId":"\#(macNode.hex)","directAddresses":["1.2.3.4:38842"],"fallbackRelay":true,"sequence":7}"#,
             "On; the Mac is picking a public relay as a fallback"),
            (#"{"version":1,"enabled":true,"nodeId":"\#(macNode.hex)","directAddresses":[],"fallbackRelay":true,"sequence":7}"#,
             "On, no address from outside yet; the Mac is picking a public relay")
        ]
        for (json, words) in cases {
            XCTAssertEqual(AppModel.remoteAccessWords(try kept(json)), words, json)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
