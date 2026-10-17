import CloudKit
import Foundation
import Synchronization
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore

/// The Mac's remote access with fakes: a fake endpoint binder, the host's two routes, the address
/// record's database, and `FakeRouter` on loopback for the mapping (docs/HOST-API.md "Routes for the
/// Mac app (local-only)", "The Mac app reports", "The Mac switches", "When the Mac's address changes").
final class RemoteAccessServiceTests: XCTestCase {
    private var harnesses: [Harness] = []

    override func tearDown() async throws {
        for harness in harnesses { await harness.service.shutdown() }
        harnesses = []
    }

    final class Harness: @unchecked Sendable {
        let keyStore = SwitchableKeyStore()
        let binder: FakeBinder
        let router: FakeRouter
        let database = FakeAddressDatabase()
        let session = FakeHostSession()
        let clock = TestClock()
        /// With `heldClock`, the service's clock instead of `clock`: its sleeps last until released.
        let held: HeldClock?
        let records: URL
        let saved = Locked<RemoteAccessService.Settings?>(nil)
        let status = Locked(RemoteAccessService.Status())
        /// The fakes as a service's dependencies (a controller test makes its own service with them).
        let dependencies: RemoteAccessService.Dependencies
        let service: RemoteAccessService
        let hostID = "0123456789abcdef0123456789abcdef"

        init(settings: RemoteAccessService.Settings = .init(), routerMode: FakeRouter.Mode = .pcp, heldClock: Bool = false) throws {
            binder = FakeBinder()
            held = heldClock ? HeldClock() : nil
            router = try FakeRouter(mode: routerMode)
            router.externalAddressBytes = RemoteAccessMappingTests.globalAddress
            records = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-service-\(UUID().uuidString)/port-mappings.json")
            let port = router.port, records = records
            let clock: any NoticeRelayClock = held ?? clock
            var dependencies: RemoteAccessService.Dependencies = RemoteAccessService.Dependencies(
                socketPath: "/nonexistent/tunnel.sock", keyStore: keyStore, bindEndpoint: binder.binder,
                makeMapping: { plan, onChange in
                    RemoteAccessMapping(request: try! RemoteAccessPorts.endpointMapping(), gateway: { "192.168.1.1" },
                                        hardwareAddress: { _ in "aa:bb:cc:00:00:01" },
                                        makeMapper: { _ in
                                            var configuration = try PortMapper.Configuration(gateway: "127.0.0.1", recordsFile: records)
                                            configuration.serverPort = port
                                            configuration.attemptTimeouts = [0.05, 0.1]
                                            configuration.releaseTimeouts = [0.05, 0.1]
                                            return PortMapper(configuration: configuration)
                                        },
                                        plan: plan, clock: clock, onChange: onChange)
                },
                recordDatabase: database, clock: clock)
            dependencies.bindRetryDelays = [15, 30]
            dependencies.keyRetryDelays = [600, 3600]
            self.dependencies = dependencies
            let saved = saved, status = status
            service = RemoteAccessService(settings: settings, dependencies: dependencies,
                                          save: { value in saved.set(value) },
                                          onStatus: { value in status.set(value) })
        }

        var nodeID: IrohNodeID { keyStore.node }
        var current: RemoteAccessService.Status { status.value }
        var settings: RemoteAccessService.Settings? { saved.value }

        deinit {
            router.stop()
            try? FileManager.default.removeItem(at: records.deletingLastPathComponent())
        }
    }

    private func harness(settings: RemoteAccessService.Settings = .init(), routerMode: FakeRouter.Mode = .pcp,
                         heldClock: Bool = false) throws -> Harness {
        let harness = try Harness(settings: settings, routerMode: routerMode, heldClock: heldClock)
        harnesses.append(harness)
        return harness
    }

    private func waitFor(_ message: String = "condition", timeout: TimeInterval = 5, _ condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(message)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Every host start is reported with the Mac's node ID, also with the switch off, so devices learn
    /// it; nothing is bound or mapped.
    func testAHostStartReportsTheNodeIDWhileTheSwitchIsOff() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        try await waitFor { h.session.reports.count == 1 }
        XCTAssertEqual(h.session.reports, [.off(nodeID: h.nodeID)])
        XCTAssertTrue(h.binder.endpoints.isEmpty)
        XCTAssertTrue(h.router.requests.isEmpty)
        XCTAssertEqual(h.database.calls, [], "no record while the switch is off and none was written")
    }

    /// On: the endpoint binds UDP 38842 with no relay, the port is mapped, and `enabled: true` is
    /// reported once the attempt finished, with the mapping's global address, which the endpoint also
    /// advertises; the host's answer goes to the address record.
    func testTurningOnMapsThenReportsAndWritesTheRecord() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor("the report with the address") { h.session.reports.count == 2 }
        let endpoint = try XCTUnwrap(h.binder.current)
        XCTAssertEqual(endpoint.configuration.port, 38842)
        XCTAssertEqual(endpoint.configuration.relay, RemoteAccessRelayChoice.none)
        XCTAssertEqual(h.session.reports.last, .on(nodeID: h.nodeID, udpPort: 38842, directAddresses: ["81.2.69.160:38842"]))
        XCTAssertEqual(h.router.mappings, [.udp: [38842: 38842]])
        try await waitFor { endpoint.externalAddresses == ["81.2.69.160:38842"] }
        try await waitFor("the record") { h.database.records[h.hostID] != nil }
        let record = try XCTUnwrap(h.database.records[h.hostID])
        XCTAssertEqual(record.nodeID, h.nodeID)
        XCTAssertEqual(record.directAddresses, ["81.2.69.160:38842"])
        XCTAssertEqual(record.revision, "r2")
        XCTAssertEqual(record.sequence, 2)
        XCTAssertNil(record.relayURL)
        XCTAssertEqual(h.settings?.recordHostID, h.hostID)
        XCTAssertEqual(h.current.endpoint, .running)
        XCTAssertEqual(h.current.mapping.state, .mapped)
    }

    /// A report with `enabled: true` never goes out while the mapping attempt runs: the first comes
    /// once a router that does not answer has timed out, without addresses.
    func testTheReportWaitsForTheMappingAttempt() async throws {
        let h = try harness(routerMode: .silent)
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        try await waitFor { h.session.reports.count == 1 }
        await h.service.setEnabled(true)
        try await waitFor { h.binder.current != nil }
        XCTAssertEqual(h.session.reports.count, 1, "nothing while the attempt runs")
        try await waitFor("the report after the attempt") { h.session.reports.count == 2 }
        XCTAssertEqual(h.session.reports.last, .on(nodeID: h.nodeID, udpPort: 38842))
        guard case .notMapped(.failed(.noResponse)) = h.current.mapping.state else { return XCTFail("\(h.current.mapping.state)") }
    }

    /// Off: `enabled: false` is reported, the mapping is deleted on the router, the record is deleted
    /// and the endpoint closed.
    func testTurningOffReportsRemovesTheMappingDeletesTheRecordAndClosesTheEndpoint() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor { h.database.records[h.hostID] != nil }
        let endpoint = try XCTUnwrap(h.binder.current)

        await h.service.setEnabled(false)
        try await waitFor { h.session.reports.last == .off(nodeID: h.nodeID) }
        XCTAssertEqual(h.router.mappings, [:])
        XCTAssertTrue(endpoint.isClosed)
        try await waitFor("the delete") { h.database.calls.last == .delete(h.hostID) }
        XCTAssertNil(h.database.records[h.hostID])
        try await waitFor { h.settings?.recordHostID == nil }
        XCTAssertNil(h.settings?.plan.lastMapping, "turning off forgets the last mapping")
        XCTAssertEqual(h.current.endpoint, .off)
    }

    /// Quit removes the mapping and closes the endpoint without a report: the host keeps the last one,
    /// so devices keep their way back.
    func testQuitRemovesTheMappingAndClosesTheEndpointWithoutAReport() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor { h.session.reports.count == 2 }
        let endpoint = try XCTUnwrap(h.binder.current)
        await h.service.shutdown()
        XCTAssertEqual(h.router.mappings, [:])
        XCTAssertTrue(endpoint.isClosed)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.session.reports.count, 2, "no report on Quit")
        XCTAssertEqual(h.settings?.enabled, true, "the switch stays on for the next launch")
    }

    /// Another program holds UDP 38842: nothing is mapped, the report says on without addresses or
    /// relay, and the bind is tried again after 15 s (at once after a network change).
    func testAPortInUseIsReportedWithoutAddressesAndNothingIsMapped() async throws {
        // A held clock: the bind's retry waits until the network change instead of 5 ms, so the status read
        // below is the failed bind's, not a retry's `.starting`.
        let h = try harness(heldClock: true)
        let clock = try XCTUnwrap(h.held)
        h.binder.fail(with: RemoteAccessEndpointError.portInUse(38842))
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor { h.session.reports.count == 2 }
        XCTAssertEqual(h.session.reports.last, .on(nodeID: h.nodeID, udpPort: 38842))
        XCTAssertEqual(h.current.endpoint, .portInUse)
        try await waitFor("the bind's retry") { clock.sleeps == [15] }
        XCTAssertTrue(h.router.requests.isEmpty, "a port another program holds is never mapped")

        h.binder.fail(with: nil)
        await h.service.networkChanged()
        try await waitFor { h.current.endpoint == .running && h.current.mapping.state == .mapped }
        try await waitFor { h.session.reports.last == .on(nodeID: h.nodeID, udpPort: 38842, directAddresses: ["81.2.69.160:38842"]) }
    }

    /// The gate gets the host's list at once after each endpoint start (the first request has no
    /// `after`), then follows it with waiting requests; an endpoint started again gets a fresh one.
    func testTheGateFollowsThePeersRoute() async throws {
        let h = try harness()
        let phone = IrohNodeID.random(), tablet = IrohNodeID.random()
        h.session.setPeers([phone])
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        let endpoint = try await { () async throws -> FakeEndpoint in
            try await waitFor { h.binder.current != nil }
            return try XCTUnwrap(h.binder.current)
        }()
        try await waitFor("the first list") { endpoint.allowedLists.first == [phone.publicKey] }
        let first = try XCTUnwrap(h.session.peerRequests.first)
        XCTAssertNil(first.after)
        XCTAssertNil(first.wait)
        try await waitFor("the waiting request") { h.session.peerRequests.count >= 2 }
        XCTAssertEqual(h.session.peerRequests[1].after, "v2")
        XCTAssertEqual(h.session.peerRequests[1].wait, 20)

        h.session.setPeers([phone, tablet])
        try await waitFor("the new list") { endpoint.allowedLists.last == [phone.publicKey, tablet.publicKey] }

        // The fallback starts the endpoint again: its new gate gets the list from a request without `after`.
        let requests = h.session.peerRequests.count
        await h.service.setFallback(true)
        try await waitFor { h.binder.endpoints.count == 2 }
        let restarted = try XCTUnwrap(h.binder.current)
        try await waitFor { restarted.allowedLists.first == [phone.publicKey, tablet.publicKey] }
        XCTAssertNil(h.session.peerRequests[requests...].first?.after)
        XCTAssertTrue(endpoint.isClosed)
    }

    /// The fallback runs with n0's relays only until the endpoint has a home relay, then with that one
    /// relay, kept in the settings and reported; after 10 minutes without it the endpoint picks again.
    func testTheFallbackKeepsOneRelayAndPicksAgainWhenItStaysUnreachable() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor { h.session.reports.count == 2 }
        await h.service.setFallback(true)
        try await waitFor { h.binder.relays.last == .pick }
        try await waitFor { h.session.reports.last?.fallbackRelay == true }
        XCTAssertNil(h.session.reports.last?.relayURL, "no relay reported before one is picked")

        let relay = "https://use1-1.relay.n0.example./"
        h.binder.current?.events(.homeRelays([relay]))
        try await waitFor("the pinned relay") { h.binder.relays.last == .pinned(relay) }
        try await waitFor { h.session.reports.last?.relayURL == relay }
        XCTAssertEqual(h.settings?.pinnedRelay, relay)
        XCTAssertEqual(h.session.reports.last?.directAddresses, ["81.2.69.160:38842"], "the mapping outlives the restart")
        try await waitFor { h.database.records[h.hostID]?.relayURL == relay }

        // Connected to it: nothing changes. Unreachable for 10 minutes: pick again.
        let pinned = try XCTUnwrap(h.binder.current)
        pinned.events(.homeRelays([relay]))
        pinned.events(.homeRelays([]))
        try await waitFor("the new pick") { h.binder.relays.last == .pick }
        XCTAssertTrue(h.clock.sleeps.contains(600))
        XCTAssertNil(h.settings?.pinnedRelay)

        // Off again: no relay at all.
        await h.service.setFallback(false)
        try await waitFor { h.binder.relays.last == RemoteAccessRelayChoice.none }
        try await waitFor { h.session.reports.last?.fallbackRelay == false }
    }

    /// A launch with the switch off deletes the record a Mac that was offline when the switch went
    /// off may have left, and removes what an earlier run left on the router.
    func testALaunchWithTheSwitchOffCleansUp() async throws {
        var settings = RemoteAccessService.Settings()
        settings.recordHostID = "fedcba9876543210fedcba9876543210"
        let h = try harness(settings: settings)
        var crashed: PortMapper? = {
            var configuration = try! PortMapper.Configuration(gateway: "127.0.0.1", recordsFile: h.records)
            configuration.serverPort = h.router.port
            return PortMapper(configuration: configuration)
        }()
        _ = try await crashed?.map(try RemoteAccessPorts.endpointMapping())
        crashed = nil
        XCTAssertEqual(h.router.mappings, [.udp: [38842: 38842]])

        await h.service.activate()
        XCTAssertEqual(h.router.mappings, [:], "the leftover mapping is deleted at launch")
        try await waitFor { h.database.calls == [.delete("fedcba9876543210fedcba9876543210")] }
        try await waitFor { h.settings?.recordHostID == nil }
        XCTAssertTrue(h.binder.endpoints.isEmpty)
    }

    /// The endpoint's key is read from the Keychain once and kept in memory: an endpoint that starts
    /// again (for the fallback, then for the relay it picked) never asks the Keychain again, so a Keychain
    /// that would refuse now changes nothing, and the mapping stays through the restarts.
    func testTheKeyIsReadOnceAndKeptForRestarts() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor { h.current.mapping.state == .mapped }
        XCTAssertEqual(h.keyStore.reads, 1, "read once, at launch for the node ID the reports carry")
        let first = try XCTUnwrap(h.binder.current)

        h.keyStore.fail(true)
        await h.service.setFallback(true)
        XCTAssertTrue(first.isClosed)
        try await waitFor { h.binder.endpoints.count == 2 && h.current.endpoint == .running }
        let relay = "https://use1-1.relay.n0.example./"
        h.binder.current?.events(.homeRelays([relay]))
        try await waitFor("the pinned relay") { h.binder.relays.last == .pinned(relay) && h.current.endpoint == .running }
        XCTAssertEqual(h.binder.endpoints.map(\.nodeID), Array(repeating: h.nodeID, count: 3), "the same key each time")
        XCTAssertEqual(h.keyStore.reads, 1, "never read again")
        XCTAssertEqual(h.current.mapping.state, .mapped)
        XCTAssertEqual(h.router.mappings, [.udp: [38842: 38842]])
    }

    /// The Keychain does not give the key (the owner denied the access prompt an ad-hoc build brings up):
    /// a launch with the switch on asks once, nothing is bound or mapped, and the key is read again after
    /// 10 minutes and then every hour, not on the bind's schedule (which would bring the prompt back within
    /// seconds), and at once after a network change, whose delays start over. Once given, the endpoint
    /// starts and the port is mapped.
    func testAKeyTheKeychainDoesNotGiveIsReadAgainOnASlowerSchedule() async throws {
        var settings = RemoteAccessService.Settings()
        settings.enabled = true
        let h = try harness(settings: settings, heldClock: true)
        let clock = try XCTUnwrap(h.held)
        h.keyStore.fail(true)
        await h.service.activate()
        guard case .failed = h.current.endpoint else { return XCTFail("\(h.current.endpoint)") }
        XCTAssertEqual(h.keyStore.reads, 1, "a launch asks the Keychain once")
        XCTAssertTrue(h.binder.endpoints.isEmpty)
        XCTAssertEqual(h.router.mappings, [:])
        try await waitFor("the first wait") { clock.sleeps == [600] }

        clock.releaseAll()
        try await waitFor("the second wait") { clock.sleeps == [600, 3600] }
        XCTAssertEqual(h.keyStore.reads, 2)
        clock.releaseAll()
        try await waitFor("the third wait") { clock.sleeps == [600, 3600, 3600] }
        XCTAssertEqual(h.keyStore.reads, 3)

        await h.service.networkChanged()
        XCTAssertEqual(h.keyStore.reads, 4, "at once after a network change")
        try await waitFor("the delays started over") { clock.sleeps == [600, 3600, 3600, 600] }

        h.keyStore.fail(false)
        clock.releaseAll()
        try await waitFor("the endpoint and the mapping") { h.current.endpoint == .running && h.current.mapping.state == .mapped }
        XCTAssertEqual(h.keyStore.reads, 5)
        XCTAssertEqual(h.router.mappings, [.udp: [38842: 38842]])
    }

    /// The launch's read is denied, and the owner allows the second prompt, which the host's start brings
    /// up right after: the endpoint starts and the port is mapped at once, not at the key's next timed read
    /// (10 minutes away, or an hour), and the host never hears "on" without the mapping attempt's addresses.
    func testAKeyTheKeychainGivesAtAHostStartStartsTheEndpointAtOnce() async throws {
        var settings = RemoteAccessService.Settings()
        settings.enabled = true
        let h = try harness(settings: settings, heldClock: true)
        let clock = try XCTUnwrap(h.held)
        h.keyStore.fail(true)
        await h.service.activate()
        guard case .failed = h.current.endpoint else { return XCTFail("\(h.current.endpoint)") }
        try await waitFor("the key's timed read") { clock.sleeps == [600] }

        h.keyStore.fail(false)
        await h.service.hostStarted(h.session, hostID: h.hostID)
        try await waitFor("the endpoint and the mapping") { h.current.endpoint == .running && h.current.mapping.state == .mapped }
        XCTAssertEqual(h.keyStore.reads, 2, "the host start's read, kept for the endpoint")
        XCTAssertEqual(h.binder.endpoints.count, 1)
        XCTAssertEqual(h.router.mappings, [.udp: [38842: 38842]])
        try await waitFor("the report") { !h.session.reports.isEmpty }
        XCTAssertEqual(h.session.reports, [.on(nodeID: h.nodeID, udpPort: 38842, directAddresses: ["81.2.69.160:38842"])],
                       "reported once the mapping attempt finished, never before")

        // The timed read was cancelled with the start: releasing the clock starts nothing more.
        clock.releaseAll()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(clock.sleeps, [600])
        XCTAssertEqual(h.binder.endpoints.count, 1)
        XCTAssertEqual(h.keyStore.reads, 2)
    }

    /// In local development HTTP the host has no tunnel socket: with the switch on, the endpoint is
    /// closed and the mapping deleted, without a report (the switch stays on); trusted HTTPS again
    /// starts both. A launch in development HTTP binds and maps nothing.
    func testTheEndpointAndMappingFollowWhetherTheHostCarriesTheTunnel() async throws {
        let h = try harness()
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        await h.service.setEnabled(true)
        try await waitFor { h.session.reports.count == 2 }
        let endpoint = try XCTUnwrap(h.binder.current)

        await h.service.setTunnelServed(false)
        XCTAssertTrue(endpoint.isClosed)
        XCTAssertEqual(h.router.mappings, [:])
        XCTAssertEqual(h.current.endpoint, .off)
        XCTAssertFalse(h.current.tunnelServed)
        XCTAssertTrue(h.current.enabled, "the switch keeps its setting")
        XCTAssertEqual(h.settings?.enabled, true)
        await h.service.networkChanged()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.binder.endpoints.count, 1, "nothing binds meanwhile")
        XCTAssertEqual(h.session.reports.count, 2, "no report: devices keep the last one")

        await h.service.setTunnelServed(true)
        try await waitFor { h.current.endpoint == .running && h.current.mapping.state == .mapped }
        XCTAssertEqual(h.binder.endpoints.count, 2)
        XCTAssertEqual(h.router.mappings, [.udp: [38842: 38842]])

        var settings = RemoteAccessService.Settings()
        settings.enabled = true
        let later = try harness(settings: settings)
        await later.service.setTunnelServed(false)
        await later.service.activate()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(later.binder.endpoints.isEmpty)
        XCTAssertTrue(later.router.requests.isEmpty)
    }

    /// A report the host did not take is sent again.
    func testAFailedReportIsSentAgain() async throws {
        let h = try harness()
        h.session.failNextReports(1)
        await h.service.activate()
        await h.service.hostStarted(h.session, hostID: h.hostID)
        try await waitFor { h.session.reports.count == 2 }
        XCTAssertEqual(h.session.reports, [.off(nodeID: h.nodeID), .off(nodeID: h.nodeID)])
        XCTAssertNotNil(h.current.reported)
        XCTAssertNil(h.current.reportProblem)
    }
}

/// The peer feed alone: the first request answered at once, the next ones waiting after its version,
/// and 1 s after an error.
final class RemoteAccessPeerFeedTests: XCTestCase {
    func testFirstAtOnceThenWaitingAndOneSecondAfterAnError() async throws {
        let session = FakeHostSession()
        let phone = IrohNodeID.random()
        session.setPeers([phone])
        let applied = Mutex<[Set<Data>]>([])
        let failures = Mutex(1)
        let clock = TestClock()
        let feed = Task {
            await RemoteAccessPeerFeed.run(fetch: { after, wait in
                if after != nil, failures.withLock({ count in defer { count -= 1 }; return count > 0 }) {
                    throw ClientError.unexpectedStatus(500)
                }
                return try await session.peers(after: after, wait: wait)
            }, apply: { peers in applied.withLock { $0.append(peers.allowedKeys) } }, clock: clock)
        }
        defer { feed.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while session.peerRequests.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(applied.withLock { $0 }, [[phone.publicKey]])
        XCTAssertNil(session.peerRequests[0].after)
        XCTAssertEqual(session.peerRequests[1].after, "v2")
        XCTAssertEqual(session.peerRequests[1].wait, 20)
        XCTAssertEqual(clock.sleeps, [1], "1 s after the error")
        session.setPeers([])
        while applied.withLock({ $0.count }) < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(applied.withLock { $0 }.last, [])
    }
}
