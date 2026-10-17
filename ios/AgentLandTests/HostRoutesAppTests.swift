import XCTest
import AgentLandCore
import AgentLandDesign
@testable import AgentLand

/// A network of fake endpoints for one host: which addresses answer, the probes and requests each
/// got, and the open pulse streams, which the test can drop.
private final class FakeRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var answering: Set<String>
    /// Addresses whose connections neither answer nor fail until the request's timeout.
    private var hanging: Set<String> = []
    private var log: [String] = []
    private var pulses: [AsyncThrowingStream<String, Error>.Continuation] = []
    let capabilities: String

    init(answering: Set<String>, capabilities: String = #"{"interactions":false,"terminal":true}"#) {
        self.answering = answering
        self.capabilities = capabilities
    }

    func answer(only authorities: Set<String>) { lock.withLock { answering = authorities } }
    func hang(_ authorities: Set<String>) { lock.withLock { hanging = authorities } }
    func probes(of authority: String) -> Int { probes().filter { $0 == authority }.count }
    /// Every open pulse stream breaks, as when the network under it goes away.
    func dropPulses() {
        let open = lock.withLock { () -> [AsyncThrowingStream<String, Error>.Continuation] in
            defer { pulses = [] }
            return pulses
        }
        open.forEach { $0.finish(throwing: URLError(.networkConnectionLost)) }
    }
    var requests: [String] { lock.withLock { log } }
    func probes() -> [String] { requests.filter { $0.hasSuffix("/v1/health") }.map { String($0.split(separator: " ")[0]) } }

    fileprivate func transport(_ endpoint: HostEndpoint) -> any APITransport { Endpoint(endpoint: endpoint, routes: self) }

    fileprivate func receive(_ request: URLRequest, at endpoint: HostEndpoint) async throws -> Bool {
        let hangs = lock.withLock { () -> Bool in
            log.append(endpoint.authority + " " + (request.url?.path ?? ""))
            return hanging.contains(endpoint.authority)
        }
        if hangs {
            try await Task.sleep(for: .seconds(request.timeoutInterval))
            throw URLError(.timedOut)
        }
        return lock.withLock { answering.contains(endpoint.authority) }
    }

    fileprivate func openPulse() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(#"{"type":"ready","intervalMs":1500}"#)
            lock.withLock { pulses.append(continuation) }
        }
    }

    private struct Endpoint: APITransport {
        let endpoint: HostEndpoint
        let routes: FakeRoutes

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard try await routes.receive(request, at: endpoint) else { throw URLError(.cannotConnectToHost) }
            let body = switch request.url?.path {
            case "/v1/health": #"{"status":"ok","protocolVersion":1}"#
            case "/v1/capabilities": routes.capabilities
            case "/v1/projects": #"{"projects":[{"id":"p","name":"Project"}]}"#
            default: #"{"accepted":true}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
            guard try await routes.receive(request, at: endpoint) else { throw URLError(.cannotConnectToHost) }
            return (routes.openPulse(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Waits in real time for monitor loops that sleep between attempts.
@MainActor private func eventually(within seconds: Double = 8, _ condition: @escaping @MainActor () -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "Timed out waiting for connection state", file: file, line: line)
}

@MainActor final class HostRoutesAppTests: XCTestCase {
    private let pin = String(repeating: "ab", count: 32)
    private let address = "https://mac.local:9841"
    private var routes: [HostRoute] {
        [HostRoute(kind: "local", host: "mac.local", port: 9841)!,
         HostRoute(kind: "tailscale", host: "mac.tail.ts.net", addresses: ["100.64.0.1"], port: 9841)!]
    }

    private func defaults() throws -> UserDefaults {
        let suite = "routes-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A model showing `host` with a client over the fake endpoints, as `select` builds it.
    private func model(_ host: SavedHost, _ fake: FakeRoutes, defaults: UserDefaults) throws -> AppModel {
        let model = AppModel(defaults: defaults)
        model.routeStagger = .milliseconds(20)
        model.routeProbeTimeout = 1
        model.routeRetryDelays = [.milliseconds(100), .milliseconds(200)]
        model.hosts = [host]
        // Attaches the workspace; this device has no saved credential here, so the client comes next.
        model.select(host)
        let address = try ServerAddress(validating: host.address)
        let known = HostEndpoint.candidates(primary: try XCTUnwrap(HostEndpoint(address: address)), routes: host.routes)
        let transport = try XCTUnwrap(RoutedTransport(address: address, certificateSHA256: host.certificateSHA256,
                                                      endpoint: host.lastEndpoint.flatMap { known.contains($0) ? $0 : nil },
                                                      transports: { endpoint, _ in fake.transport(endpoint) }))
        model.client = APIClient(address: address, token: "token", transport: transport)
        return model
    }

    func testSavedHostsFromBeforeRoutesAndRoutesThisVersionCannotReadStillLoad() throws {
        let defaults = try defaults()
        let saved = """
        [{"address":"https://old.local:9841","deviceID":"d1","name":"Old","mode":"direct","certificateSHA256":"\(pin)"},
         {"address":"https://new.local:9841","deviceID":"d2","name":"New","mode":"direct","certificateSHA256":"\(pin)",
          "routes":[{"kind":"tailscale","host":"new.tail.ts.net","addresses":["100.64.0.2"],"port":9841},{"kind":"??","port":-1},"x"],
          "lastEndpoint":{"host":"not a host","port":0}}]
        """
        defaults.set(Data(saved.utf8), forKey: ProductIdentity.connectionsDefaultsKey)
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.hosts.map(\.name), ["Old", "New"], "No saved host is lost to an unreadable route")
        XCTAssertEqual(model.hosts[0].routes, [])
        XCTAssertEqual(model.hosts[1].routes.map(\.host), ["new.tail.ts.net"])
        XCTAssertNil(model.hosts[1].lastEndpoint)
        XCTAssertTrue(model.hosts[1].knowsTailscaleRoute)

        var host = model.hosts[1]
        host.lastEndpoint = HostEndpoint(host: "100.64.0.2", port: 9841)
        let reloaded = try JSONDecoder().decode([SavedHost].self, from: JSONEncoder().encode([host]))
        XCTAssertEqual(reloaded, [host], "Routes and the last address that answered are saved with the host")
    }

    func testConnectionFailsOverInOrderRemembersTheWinnerAndFailsBack() async throws {
        let defaults = try defaults()
        let host = SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: pin, routes: routes)
        defaults.set(try JSONEncoder().encode([host]), forKey: ProductIdentity.connectionsDefaultsKey)
        // Away from home: only the Tailscale address answers.
        let fake = FakeRoutes(answering: ["100.64.0.1:9841"])
        let model = try model(host, fake, defaults: defaults)
        model.handleScenePhase(.active)
        await eventually { model.connection == .online }
        XCTAssertEqual(Array(fake.probes().prefix(3)), ["mac.local:9841", "mac.tail.ts.net:9841", "100.64.0.1:9841"],
                       "The address in use first, then the routes in order")
        XCTAssertEqual(model.activeEndpoint?.authority, "100.64.0.1:9841")
        XCTAssertTrue(fake.requests.contains("100.64.0.1:9841 /v1/pulse"), "The pulse runs on the address that answered")
        XCTAssertEqual(model.workspace.connectionEpoch, 1, "Surfaces that failed on the old address reload")
        let saved = try JSONDecoder().decode([SavedHost].self, from: try XCTUnwrap(defaults.data(forKey: ProductIdentity.connectionsDefaultsKey)))
        XCTAssertEqual(saved.first?.lastEndpoint?.authority, "100.64.0.1:9841", "The winner is remembered")
        let next = AppModel.transport(for: try XCTUnwrap(saved.first), address: try ServerAddress(validating: address))
        XCTAssertEqual((next as? RoutedTransport)?.endpoint.authority, "100.64.0.1:9841", "The next launch starts where it worked")

        // Back home with Tailscale off: the Tailscale address stops answering and the pulse breaks.
        fake.answer(only: ["mac.local:9841"])
        fake.dropPulses()
        await eventually { model.connection == .online && model.activeEndpoint?.authority == "mac.local:9841" }
        XCTAssertEqual(model.workspace.connectionEpoch, 2)
        await eventually { model.hosts.first?.lastEndpoint == nil }
        model.handleScenePhase(.background)
    }

    func testNoAnswerAnywhereSaysToCheckTailscaleOnlyWhenItsRouteIsKnown() async throws {
        let fake = FakeRoutes(answering: [])
        let withTailscale = try model(SavedHost(address: address, deviceID: "d", name: "Robin’s Mac mini", mode: .direct,
                                                certificateSHA256: pin, routes: routes), fake, defaults: try defaults())
        withTailscale.handleScenePhase(.active)
        await eventually { withTailscale.connection == .offline(.unreachable) }
        guard case let .offline(title, detail, _) = withTailscale.connectionStatus else { return XCTFail("Offline is shown") }
        XCTAssertEqual(title, "Can’t reach Robin’s Mac mini")
        XCTAssertEqual(detail, "Away from home, AgentLand connects through Tailscale — check that Tailscale is on. Reconnecting…")
        withTailscale.handleScenePhase(.background)

        let localOnly = try model(SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: pin,
                                            routes: [routes[0]]), FakeRoutes(answering: []), defaults: try defaults())
        localOnly.handleScenePhase(.active)
        await eventually { localOnly.connection == .offline(.unreachable) }
        guard case let .offline(_, plain, _) = localOnly.connectionStatus else { return XCTFail("Offline is shown") }
        XCTAssertEqual(plain, "The Mac may be asleep or on another network. Reconnecting…")
        localOnly.handleScenePhase(.background)
    }

    func testAConnectionLearnsTheHostsRoutesForADevicePairedBeforeThem() async throws {
        let defaults = try defaults()
        let advertised = #"{"interactions":false,"terminal":true,"routes":[{"kind":"local","host":"mac.local","port":9841},{"kind":"tailscale","host":"mac.tail.ts.net","addresses":["100.64.0.1"],"port":9841}]}"#
        let host = SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: pin)
        let model = try model(host, FakeRoutes(answering: ["mac.local:9841"], capabilities: advertised), defaults: defaults)
        await model.refreshProjects()
        XCTAssertEqual(model.hosts.first?.routes, routes)
        XCTAssertEqual(model.selectedHost?.routes, routes)
        let saved = try JSONDecoder().decode([SavedHost].self, from: try XCTUnwrap(defaults.data(forKey: ProductIdentity.connectionsDefaultsKey)))
        XCTAssertEqual(saved.first?.routes, routes, "Learned routes are saved with the host")

        // A host paired without a fingerprint uses its one address, so it keeps no routes.
        let unpinned = SavedHost(address: "https://public.example", deviceID: "d", name: "Public", mode: .direct, certificateSHA256: nil)
        model.hosts.append(unpinned)
        model.learnRoutes(routes, hostID: unpinned.id)
        XCTAssertEqual(model.hosts.last?.routes, [])
    }

    /// At home with Tailscale off on the phone and AgentLand stopped on the Mac: the local address is
    /// refused, the Tailscale name does not resolve and its address hangs. The host shows unreachable at
    /// once, surfaces' failures meanwhile do not start the race over, and the Mac is found soon after it
    /// comes back, whatever the hung address does.
    func testTheRaceShowsUnreachableAtOnceIgnoresSurfaceFailuresAndFindsTheMacWhenItReturns() async throws {
        let host = SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: pin, routes: routes)
        let fake = FakeRoutes(answering: [])
        fake.hang(["100.64.0.1:9841"])
        let model = try model(host, fake, defaults: try defaults())
        model.routeProbeTimeout = 30
        model.handleScenePhase(.active)
        await eventually(within: 2) { model.connection == .offline(.unreachable) }
        XCTAssertFalse(model.hostReachable, "Typing is refused while no address answers")
        XCTAssertTrue(model.routeRaceRunning)
        for _ in 0..<5 {
            model.noteConnectionFailure()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fake.probes(of: "100.64.0.1:9841"), 1, "Surface failures did not start the race over")
        XCTAssertGreaterThan(fake.probes(of: "mac.local:9841"), 1, "The refused address is tried again on the schedule")

        fake.answer(only: ["mac.local:9841"])
        await eventually(within: 2) { model.connection == .online }
        XCTAssertFalse(model.routeRaceRunning)
        model.handleScenePhase(.background)
    }

    /// A hung host (B-14): every address takes the connection and never answers, so the projects' read waits out
    /// its 20 s timeout. The opening resolves as soon as the race's probes find no answering address, onto the
    /// offline state, and the host's workspaces load with the next epoch once an address answers.
    func testAHungHostLiftsTheOpeningOnceNoAddressAnswersAndLoadsWhenItReturns() async throws {
        let host = SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: pin, routes: routes)
        let fake = FakeRoutes(answering: [])
        fake.hang(["mac.local:9841", "mac.tail.ts.net:9841", "100.64.0.1:9841"])
        let model = try model(host, fake, defaults: try defaults())
        // Attached with its client, as selecting a host with a saved credential does: its projects are unread.
        model.workspace.attach(hostID: host.id, identity: try XCTUnwrap(model.identity), client: model.client)
        XCTAssertTrue(model.presentationPending, "Selecting the host puts the opening cover up")
        XCTAssertFalse(model.presentationReady, "The opening waits for the host's projects")
        let load = Task { await model.refreshProjects() }
        defer { load.cancel() }
        let started = Date()
        model.handleScenePhase(.active)
        await eventually(within: 4) { model.connection == .offline(.unreachable) }
        XCTAssertFalse(model.workspace.metadataResolved, "The host's projects are still unanswered")
        XCTAssertTrue(model.presentationReady, "No address answers: the offline state resolves the opening")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "Within the race's probes, not the requests' 20 s timeout")

        model.workspace.beginPresentation()
        XCTAssertTrue(model.presentationReady, "An opening begun while still offline resolves at once")

        fake.hang([])
        fake.answer(only: ["mac.local:9841"])
        await eventually { model.connection == .online }
        XCTAssertEqual(model.workspace.connectionEpoch, 1)
        await eventually { model.workspace.metadataResolved && model.workspace.projects.map(\.id) == ["p"] }
        model.handleScenePhase(.background)
    }

    /// A monitor that moved to another address and was stopped before the pulse answered: the next one
    /// starts on that address, and its first answer still starts a new epoch.
    func testMovingToAnotherAddressStartsANewEpochEvenWhenTheMonitorThatMovedWasStopped() async throws {
        let host = SavedHost(address: address, deviceID: "d", name: "Mac", mode: .direct, certificateSHA256: pin, routes: routes)
        let fake = FakeRoutes(answering: ["mac.local:9841"])
        let model = try model(host, fake, defaults: try defaults())
        model.handleScenePhase(.active)
        await eventually { model.connection == .online }
        XCTAssertEqual(model.workspace.connectionEpoch, 0)
        model.handleScenePhase(.background)

        // Leaving home: the old monitor chose Tailscale and stopped before its pulse answered.
        let tailscale = try XCTUnwrap(HostEndpoint(host: "100.64.0.1", port: 9841))
        model.client?.routing?.use(tailscale)
        fake.answer(only: ["100.64.0.1:9841"])
        model.handleScenePhase(.active)
        await eventually { model.workspace.connectionEpoch == 1 }
        XCTAssertEqual(model.connection, .online)
        model.handleScenePhase(.background)
    }

    func testPairingReportsThePairedAddresssErrorUnlessAnotherAddressReachedTheHost() async throws {
        let paired = try XCTUnwrap(HostEndpoint(host: "mac.local", port: 9841))
        let short = try XCTUnwrap(HostEndpoint(host: "mac", port: 9841))
        let tailscale = try XCTUnwrap(HostEndpoint(host: "100.64.0.1", port: 9841))
        var tried: [String] = []
        do {
            _ = try await AppModel.pairing(over: [paired, short, tailscale]) { endpoint in
                tried.append(endpoint?.host ?? "")
                switch endpoint?.host {
                case "mac.local": throw URLError(.cannotConnectToHost)
                case "mac": throw URLError(.cannotFindHost)
                default: throw URLError(.cancelled) // another server there, turned away by the pinned check
                }
            }
            XCTFail("Nothing paired")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost, "The paired address's refusal is what is reported")
        }
        XCTAssertEqual(tried, ["mac.local", "mac", "100.64.0.1"], "No address reached a host, so each was tried")

        tried = []
        do {
            _ = try await AppModel.pairing(over: [paired, tailscale, short]) { endpoint in
                tried.append(endpoint?.host ?? "")
                if endpoint == paired { throw URLError(.cannotConnectToHost) }
                throw ClientError.server(code: "invalid_code", message: "The pairing code is not valid")
            }
            XCTFail("The host refused the code")
        } catch {
            XCTAssertEqual(error as? ClientError, .server(code: "invalid_code", message: "The pairing code is not valid"))
        }
        XCTAssertEqual(tried, ["mac.local", "100.64.0.1"], "A code the host saw is never tried elsewhere")

        let answer = try await AppModel.pairing(over: [paired, tailscale]) { endpoint in
            if endpoint == paired { throw URLError(.cannotFindHost) }
            return try JSONDecoder().decode(PairResponse.self, from: Data(#"{"deviceId":"d1","token":"t"}"#.utf8))
        }
        XCTAssertEqual(answer.deviceID, "d1")
    }
}
