import Foundation
import Synchronization
import XCTest
@testable import AgentLandDesktopCore

/// The mapping's lifecycle against `FakeRouter` on loopback (docs/HOST-API.md "The Mac app reports",
/// "The Mac switches"): only UDP 38842 is mapped, the report's addresses follow
/// `RemoteAccessMappingPlan`, a new router's mapper starts only after the old one let go, and what a
/// crash left is deleted at launch. Nothing is sent to a real router.
final class RemoteAccessMappingTests: XCTestCase {
    private var routers: [FakeRouter] = []
    private var folders: [URL] = []

    override func tearDown() {
        routers.forEach { $0.stop() }
        routers = []
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }

    /// A global unicast external address; it only travels inside the fake router's answers.
    static let globalAddress: [UInt8] = [81, 2, 69, 160]

    private func router(_ mode: FakeRouter.Mode = .pcp, external: [UInt8] = globalAddress) throws -> FakeRouter {
        let router = try FakeRouter(mode: mode)
        router.externalAddressBytes = external
        routers.append(router)
        return router
    }

    private func recordsFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-remote-mapping-\(UUID().uuidString)")
        folders.append(folder)
        return folder.appendingPathComponent("port-mappings.json")
    }

    /// Mappers for the fake routers, named by the gateway addresses the test's network uses (or by the
    /// gateway and link-layer address, "192.168.1.1 aa:bb:cc:00:00:02", for routers that share one).
    /// Every mapper's records name the router's link-layer address as the app's do.
    private func mapperFactory(_ routers: [String: FakeRouter], records: URL, renewalRetry: TimeInterval = 60)
        -> @Sendable (RemoteAccessMapping.Router) throws -> PortMapper {
        let ports = routers.mapValues(\.port)
        return { router in
            var configuration = try PortMapper.Configuration(gateway: "127.0.0.1", recordsFile: records)
            configuration.serverPort = ports["\(router.gateway) \(router.hardwareAddress ?? "")"] ?? ports[router.gateway]!
            configuration.routerHardwareAddress = router.hardwareAddress
            configuration.attemptTimeouts = [0.05, 0.1]
            configuration.releaseTimeouts = [0.05, 0.1]
            configuration.renewalRetryInterval = renewalRetry
            return PortMapper(configuration: configuration)
        }
    }

    private final class Network: @unchecked Sendable {
        let gateway = Mutex<String?>("192.168.1.1")
        let hardware = Mutex<String?>("aa:bb:cc:00:00:01")
    }

    private final class Outcomes: @unchecked Sendable {
        private let all = Mutex<[RemoteAccessMapping.Outcome]>([])
        private let plans = Mutex<[RemoteAccessMappingPlan]>([])
        func add(_ outcome: RemoteAccessMapping.Outcome, _ plan: RemoteAccessMappingPlan) {
            all.withLock { $0.append(outcome) }
            plans.withLock { $0.append(plan) }
        }
        var last: RemoteAccessMapping.Outcome? { all.withLock { $0.last } }
        var lastPlan: RemoteAccessMappingPlan? { plans.withLock { $0.last } }
        var count: Int { all.withLock { $0.count } }
    }

    private func mapping(network: Network, factory: @escaping @Sendable (RemoteAccessMapping.Router) throws -> PortMapper,
                         plan: RemoteAccessMappingPlan = RemoteAccessMappingPlan(), clock: TestClock = TestClock(),
                         outcomes: Outcomes) -> RemoteAccessMapping {
        RemoteAccessMapping(request: try! RemoteAccessPorts.endpointMapping(),
                            gateway: { network.gateway.withLock { $0 } },
                            hardwareAddress: { _ in network.hardware.withLock { $0 } },
                            makeMapper: factory, plan: plan, clock: clock,
                            onChange: { outcomes.add($0, $1) })
    }

    private struct NotSettled: Error {}

    /// The last outcome once it has settled and meets `condition`, within `timeout` seconds.
    private func settled(_ outcomes: Outcomes, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                         where condition: @escaping (RemoteAccessMapping.Outcome) -> Bool = { _ in true })
        async throws -> RemoteAccessMapping.Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let last = outcomes.last, last.settled, condition(last) { return last }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("no such outcome within \(timeout) s; last: \(String(describing: outcomes.last))", file: file, line: line)
        throw NotSettled()
    }

    /// Only the endpoint's UDP port is asked for; a global external address is the report's address,
    /// and stop deletes the mapping on the router.
    func testMapsTheEndpointsUDPPortOnlyAndReportsAGlobalAddress() async throws {
        let router = try router()
        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: recordsFile()), outcomes: outcomes)
        await mapping.start()
        let outcome = try await settled(outcomes)
        XCTAssertEqual(outcome.state, .mapped)
        XCTAssertEqual(outcome.directAddresses, ["81.2.69.160:38842"])
        XCTAssertEqual(outcome.externalAddress, "81.2.69.160:38842")
        XCTAssertEqual(router.mappings, [.udp: [38842: 38842]])
        XCTAssertTrue(router.mapRequests.allSatisfy { $0.transport == .udp && $0.internalPort == 38842 }, "\(router.mapRequests)")
        let kept = try XCTUnwrap(outcomes.lastPlan?.lastMapping)
        XCTAssertEqual(kept.router, RemoteAccessMappingPlan.Router(gateway: "192.168.1.1", hardwareAddress: "aa:bb:cc:00:00:01"))

        await mapping.stop()
        XCTAssertEqual(router.mappings, [:], "stop deletes the mapping on the router")
        XCTAssertEqual(outcomes.last?.state, .idle)
    }

    /// Behind another router or carrier-grade NAT the external address is not global unicast: mapped,
    /// but no address to report.
    func testANonGlobalExternalAddressIsNotReported() async throws {
        let router = try router(external: [100, 64, 3, 9])
        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: recordsFile()), outcomes: outcomes)
        await mapping.start()
        let outcome = try await settled(outcomes)
        XCTAssertEqual(outcome.state, .mapped)
        XCTAssertEqual(outcome.externalAddress, "100.64.3.9:38842")
        XCTAssertEqual(outcome.directAddresses, [])
        await mapping.stop()
    }

    /// A router that does not answer: the attempt settles without a mapping (so the report can go
    /// out), and it is tried again on the plan's schedule until the router answers.
    func testASilentRouterSettlesAndIsTriedAgain() async throws {
        let router = try router(.silent)
        let network = Network(), outcomes = Outcomes(), clock = TestClock()
        let mapping = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: recordsFile()),
                              clock: clock, outcomes: outcomes)
        await mapping.start()
        let failed = try await settled(outcomes)
        XCTAssertEqual(failed.state, .notMapped(.failed(.noResponse)))
        XCTAssertEqual(failed.directAddresses, [])
        router.mode = .pcp
        let mapped = try await settled(outcomes, timeout: 15) { $0.state == .mapped }
        XCTAssertEqual(mapped.directAddresses, ["81.2.69.160:38842"])
        XCTAssertEqual(clock.sleeps.first, 15, "the first retry comes after 15 s")
        await mapping.stop()
    }

    /// A router that refuses has not opened the port: nothing to report.
    func testARefusalReportsNoAddress() async throws {
        let router = try router()
        router.refuse(.udp, code: 2)
        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: recordsFile()), outcomes: outcomes)
        await mapping.start()
        let outcome = try await settled(outcomes)
        guard case .notMapped(.failed) = outcome.state else { return XCTFail("\(outcome.state)") }
        XCTAssertEqual(outcome.directAddresses, [])
        await mapping.stop()
    }

    /// After a relaunch the last mapping's addresses are reported while the router does not answer,
    /// only on the same router (its link-layer address) and only until the lease ends.
    func testTheLastMappingIsKeptOnlyOnTheSameRouterWhileItsLeaseLasts() async throws {
        let router = try router()
        let records = recordsFile()
        let network = Network(), outcomes = Outcomes(), clock = TestClock()
        let first = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: records), clock: clock, outcomes: outcomes)
        await first.start()
        _ = try await settled(outcomes) { $0.state == .mapped }
        await first.stop()
        let plan = try XCTUnwrap(outcomes.lastPlan)
        XCTAssertNotNil(plan.lastMapping)

        // The next launch: the router does not answer this time.
        router.mode = .silent
        let relaunch = Outcomes()
        let second = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: records),
                             plan: plan, clock: clock, outcomes: relaunch)
        await second.start()
        let kept = try await settled(relaunch)
        XCTAssertEqual(kept.directAddresses, ["81.2.69.160:38842"])
        XCTAssertEqual(kept.keptUntil, plan.lastMapping?.expiresAt)
        await second.stop()

        // Another router at the same address: none.
        network.hardware.withLock { $0 = "aa:bb:cc:00:00:02" }
        let other = Outcomes()
        let third = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: records),
                            plan: plan, clock: clock, outcomes: other)
        await third.start()
        let none = try await settled(other)
        XCTAssertEqual(none.directAddresses, [])
        XCTAssertNil(none.keptUntil)
        await third.stop()
    }

    /// A network change to another router: the old mapper deletes its mapping and lets go of the
    /// records before the new one maps (one mapper at a time owns them).
    func testANetworkChangeStopsTheOldMapperBeforeTheNewOneMaps() async throws {
        let home = try router(), office = try router()
        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: mapperFactory(["192.168.1.1": home, "10.0.0.1": office], records: recordsFile()),
                              outcomes: outcomes)
        await mapping.start()
        _ = try await settled(outcomes) { $0.state == .mapped }
        XCTAssertEqual(home.mappings, [.udp: [38842: 38842]])

        network.gateway.withLock { $0 = "10.0.0.1" }
        network.hardware.withLock { $0 = "aa:bb:cc:00:00:09" }
        await mapping.networkChanged()
        let moved = try await settled(outcomes) { $0.state == .mapped && $0.directAddresses == ["81.2.69.160:38842"] }
        XCTAssertEqual(moved.state, .mapped)
        XCTAssertEqual(home.mappings, [:], "the old router's mapping was deleted first")
        XCTAssertEqual(office.mappings, [.udp: [38842: 38842]])
        await mapping.stop()
        XCTAssertEqual(office.mappings, [:])
    }

    /// Another router answers at the same gateway address (the Mac joined another network with the same
    /// default): the old mapping is let go of without a delete, which would reach the new router, and
    /// its record stays; the new router's mapping gets a record of its own. Back on the first router,
    /// the next launch deletes the mapping left there.
    func testAnotherRouterAtTheSameAddressNeverGetsTheOldMappingsDelete() async throws {
        let home = try router(), away = try router()
        let records = recordsFile()
        let factory = mapperFactory(["192.168.1.1 aa:bb:cc:00:00:01": home, "192.168.1.1 aa:bb:cc:00:00:02": away], records: records)
        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: factory, outcomes: outcomes)
        await mapping.start()
        _ = try await settled(outcomes) { $0.state == .mapped }
        XCTAssertEqual(home.mappings, [.udp: [38842: 38842]])

        network.hardware.withLock { $0 = "aa:bb:cc:00:00:02" }
        await mapping.networkChanged()
        _ = try await settled(outcomes) { $0.state == .mapped }
        XCTAssertEqual(away.mappings, [.udp: [38842: 38842]])
        let deletes = (home.mapRequests + away.mapRequests).filter { $0.lifetime == 0 }
        XCTAssertEqual(deletes, [], "no delete for the first router's mapping went to the router now at its address")
        let homeNonce = try XCTUnwrap(home.mapRequests.first?.nonce)
        XCTAssertNotEqual(away.mapRequests.first?.nonce, homeNonce, "the new router's mapping is not the old one's record")
        XCTAssertEqual(try recordedRouters(records), ["aa:bb:cc:00:00:01", "aa:bb:cc:00:00:02"], "a record for each router")

        // The switch goes off on the second network: only its router gets a delete, and the first router's record stays.
        await mapping.stopAndForget()
        XCTAssertEqual(away.mappings, [:])
        XCTAssertTrue(away.mapRequests.filter { $0.lifetime == 0 }.allSatisfy { $0.nonce != homeNonce })
        XCTAssertEqual(home.mappings, [.udp: [38842: 38842]])
        XCTAssertEqual(try recordedRouters(records), ["aa:bb:cc:00:00:01"])

        // Home again, the next launch: the mapping left on the first router is deleted with its nonce.
        network.hardware.withLock { $0 = "aa:bb:cc:00:00:01" }
        let relaunch = self.mapping(network: network, factory: factory, outcomes: Outcomes())
        let unconfirmed = try await relaunch.removeLeftovers()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertEqual(home.mappings, [:])
        XCTAssertEqual(home.mapRequests.last?.lifetime, 0)
        XCTAssertEqual(home.mapRequests.last?.nonce, homeNonce)
        XCTAssertEqual(try recordedRouters(records), [])
    }

    /// The link-layer addresses of the routers the records file names, sorted.
    private func recordedRouters(_ records: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: records.path) else { return [] }
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: records)) as? [[String: Any]])
        return entries.compactMap { $0["hardwareAddress"] as? String }.sorted()
    }

    /// At launch, whether or not the switch is on: what a run that ended without deleting left on this
    /// router is deleted.
    func testRemoveLeftoversDeletesWhatACrashLeft() async throws {
        let router = try router()
        let records = recordsFile()
        let factory = mapperFactory(["192.168.1.1": router], records: records)
        var crashed: PortMapper? = try factory(RemoteAccessMapping.Router(gateway: "192.168.1.1", hardwareAddress: "aa:bb:cc:00:00:01"))
        _ = try await crashed?.map(try RemoteAccessPorts.endpointMapping())
        crashed = nil  // ends without deleting, like a force quit
        XCTAssertEqual(router.mappings, [.udp: [38842: 38842]])

        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: factory, outcomes: outcomes)
        let unconfirmed = try await mapping.removeLeftovers()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertEqual(router.mappings, [:])
    }

    /// A held mapping whose renewals failed until its lease ended is reported without addresses, and
    /// with them again once a renewal works.
    func testAnExpiredMappingIsReportedWithoutAddressesUntilARenewalWorks() async throws {
        let router = try router()
        router.grantedLifetime = 2
        let network = Network(), outcomes = Outcomes()
        let mapping = mapping(network: network, factory: mapperFactory(["192.168.1.1": router], records: recordsFile(), renewalRetry: 0.5),
                              outcomes: outcomes)
        await mapping.start()
        _ = try await settled(outcomes) { $0.state == .mapped }
        router.mode = .silent
        let expired = try await settled(outcomes, timeout: 8) { $0.state == .expired }
        XCTAssertEqual(expired.directAddresses, [])
        router.mode = .pcp
        let renewed = try await settled(outcomes, timeout: 8) { $0.state == .mapped }
        XCTAssertEqual(renewed.directAddresses, ["81.2.69.160:38842"])
        await mapping.stop()
    }
}
