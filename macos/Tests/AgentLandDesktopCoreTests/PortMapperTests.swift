import Darwin
import Foundation
import XCTest
@testable import AgentLandDesktopCore

/// PCP and NAT-PMP against `FakeRouter` on loopback. Every mapper here is configured with
/// 127.0.0.1 and the fake's own port; nothing is sent to a real router.
final class PortMapperTests: XCTestCase {
    private var routers: [FakeRouter] = []
    private var folders: [URL] = []

    override func tearDown() {
        routers.forEach { $0.stop() }
        routers = []
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }

    /// A records file in a new temporary folder (the folder itself is created by the mapper).
    private func recordsFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-mappings-\(UUID().uuidString)")
        folders.append(folder)
        return folder.appendingPathComponent("records/port-mappings.json")
    }

    private func savedRecords(_ url: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }

    private func router(_ mode: FakeRouter.Mode = .pcp) throws -> FakeRouter {
        let router = try FakeRouter(mode: mode)
        routers.append(router)
        return router
    }

    private func mapper(for router: FakeRouter, epochCheck: TimeInterval = 300, retry: TimeInterval = 60,
                        timeouts: [TimeInterval] = [0.1, 0.2, 0.4], lifetime: UInt32 = 7200, records: URL? = nil) throws -> PortMapper {
        var configuration = try PortMapper.Configuration(gateway: "127.0.0.1", recordsFile: records ?? recordsFile())
        configuration.serverPort = router.port
        configuration.requestedLifetime = lifetime
        configuration.attemptTimeouts = timeouts
        configuration.releaseTimeouts = [0.1, 0.2]
        configuration.epochCheckInterval = epochCheck
        configuration.renewalRetryInterval = retry
        return PortMapper(configuration: configuration)
    }

    private let endpoint = try! RemoteAccessPorts.endpointMapping()
    /// A second mapping, TCP: the mapper keeps any number of them (remote access asks for the
    /// endpoint's UDP port only).
    private let second = try! PortMappingRequest(.tcp, internalPort: 38841)

    func testPCPMapsAUDPAndATCPPortForTwoHours() async throws {
        let router = try router()
        let mapper = try mapper(for: router)
        let udp = try await mapper.map(endpoint)
        let tcp = try await mapper.map(second)

        XCTAssertEqual(udp.method, .pcp)
        XCTAssertEqual(udp.externalPort, 38842)
        XCTAssertEqual(tcp.externalPort, 38841)
        XCTAssertEqual(udp.lifetime, 7200)
        XCTAssertEqual(udp.externalAddress?.description, "203.0.113.7")
        let requests = router.mapRequests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.length, 60, "a MAP request is a 24-byte header and a 36-byte payload")
            XCTAssertEqual(request.lifetime, 7200)
            XCTAssertEqual(request.clientAddress, [UInt8](repeating: 0, count: 10) + [0xff, 0xff, 127, 0, 0, 1],
                           "the client address is this socket's, IPv4-mapped")
            XCTAssertEqual(request.nonce?.count, 12)
        }
        XCTAssertEqual(requests.map(\.transport), [.udp, .tcp])
        XCTAssertEqual(requests.map(\.internalPort), [38842, 38841])
        XCTAssertNotEqual(requests[0].nonce, requests[1].nonce)
        XCTAssertEqual(router.mappings[.udp], [38842: 38842])
        XCTAssertEqual(router.mappings[.tcp], [38841: 38841])
        let method = await mapper.method
        XCTAssertEqual(method, .pcp)
        await mapper.stop()
    }

    func testAnotherGrantedPortIsKeptAndRenewedAtHalfLife() async throws {
        let router = try router()
        router.grantedLifetime = 2
        router.grantedPortOffset = 1000
        let mapper = try mapper(for: router)
        let events = EventLog(mapper)

        let mapping = try await mapper.map(endpoint)
        XCTAssertEqual(mapping.externalPort, 39842, "the router's port, not the one asked for")
        XCTAssertEqual(mapping.lifetime, 2)
        try await eventually(timeout: 4) { router.mapRequests.count == 2 }
        let first = router.mapRequests[0]
        let renewal = router.mapRequests[1]
        let elapsed = renewal.receivedAt - first.receivedAt
        XCTAssertGreaterThan(elapsed, 0.8, "renewed at half of the 2 s lifetime")
        XCTAssertLessThan(elapsed, 1.8)
        XCTAssertEqual(renewal.nonce, first.nonce, "a renewal keeps the mapping's nonce")
        XCTAssertEqual(renewal.suggestedPort, 39842, "a renewal asks for the port it was granted")
        XCTAssertEqual(renewal.lifetime, 7200, "every renewal asks for the full lifetime again")
        try await eventually { events.mapped.count >= 2 }
        XCTAssertFalse(events.all.contains { if case .externalPortChanged = $0 { true } else { false } })
        await mapper.stop()
    }

    func testARenewalGrantedAnotherPortIsReported() async throws {
        let router = try router()
        router.grantedLifetime = 2
        let mapper = try mapper(for: router)
        let events = EventLog(mapper)
        _ = try await mapper.map(endpoint)
        // The router loses the mapping and hands out another port.
        router.restart()
        router.grantedPortOffset = 7
        try await eventually(timeout: 4) {
            events.all.contains(.externalPortChanged(self.endpoint, from: 38842, to: 38849))
        }
        let current = await mapper.mappings
        XCTAssertEqual(current.first?.externalPort, 38849)
        await mapper.stop()
    }

    func testARouterRestartIsNoticedFromItsEpochAndEveryMappingIsMadeAgain() async throws {
        let router = try router()
        let mapper = try mapper(for: router, epochCheck: 0.3)
        let events = EventLog(mapper)
        _ = try await mapper.map(endpoint)
        _ = try await mapper.map(second)
        try await eventually { router.requests.contains { $0.opcode == PCPWire.announceOpcode && $0.transport == nil } }
        XCTAssertFalse(events.all.contains(.gatewayRestarted), "a steady epoch is not a restart")
        XCTAssertEqual(router.requests.first { $0.opcode == 0 }?.length, 24, "ANNOUNCE is a bare header")

        router.restart()
        XCTAssertNil(router.mappings[.udp])
        try await eventually(timeout: 4) {
            router.mappings[.udp] == [38842: 38842] && router.mappings[.tcp] == [38841: 38841]
        }
        XCTAssertTrue(events.all.contains(.gatewayRestarted))
        // Both were made again long before their half-life (an hour).
        XCTAssertEqual(router.mapRequests.count, 4)
        await mapper.stop()
    }

    func testStopDeletesEveryMappingWithLifetimeZero() async throws {
        let router = try router()
        let records = recordsFile()
        let mapper = try mapper(for: router, records: records)
        let events = EventLog(mapper)
        _ = try await mapper.map(endpoint)
        _ = try await mapper.map(second)
        let made = router.mapRequests
        XCTAssertEqual(try savedRecords(records).count, 2, "each mapping is recorded while it may exist")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: records.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: records.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)

        let confirmed = await mapper.unmap(second)
        XCTAssertTrue(confirmed)
        XCTAssertNil(router.mappings[.tcp])
        XCTAssertEqual(router.mappings[.udp], [38842: 38842])
        let unconfirmed = await mapper.stop()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertEqual(try savedRecords(records).count, 0, "a confirmed delete forgets the record")

        XCTAssertTrue(router.mappings.isEmpty, "no mapping stays behind on the router")
        let deletes = router.mapRequests.dropFirst(2)
        XCTAssertEqual(deletes.count, 2)
        XCTAssertTrue(deletes.allSatisfy { $0.lifetime == 0 })
        XCTAssertEqual(deletes.map(\.nonce), [made[1].nonce, made[0].nonce], "each delete carries its mapping's nonce")
        XCTAssertEqual(deletes.map(\.transport), [.tcp, .udp])
        let remaining = await mapper.mappings
        XCTAssertTrue(remaining.isEmpty)
        try await eventually { events.all.filter { if case .removed = $0 { true } else { false } }.count == 2 }
        // Nothing is renewed after a stop.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(router.mapRequests.count, 4)
    }

    func testTheExternalAddressQuery() async throws {
        let router = try router()
        let mapper = try mapper(for: router)
        let address = try await mapper.externalAddress()
        XCTAssertEqual(address.description, "203.0.113.7")
        XCTAssertEqual(router.requests.last?.method, .natPMP)
        XCTAssertEqual(router.requests.last?.length, 2, "NAT-PMP's address request is two bytes")
        XCTAssertTrue(router.mappings.isEmpty, "the query maps nothing")
    }

    func testANATPMPOnlyRouterIsUsedWithNATPMP() async throws {
        let router = try router(.natPMPOnly)
        let mapper = try mapper(for: router)
        let mapping = try await mapper.map(endpoint)
        XCTAssertEqual(mapping.method, .natPMP)
        XCTAssertEqual(mapping.externalPort, 38842)
        XCTAssertEqual(mapping.lifetime, 7200)
        XCTAssertEqual(mapping.externalAddress?.description, "203.0.113.7")
        XCTAssertEqual(router.requests.first?.method, .pcp, "PCP is tried first")
        let map = try XCTUnwrap(router.mapRequests.first)
        XCTAssertEqual(map.method, .natPMP)
        XCTAssertEqual(map.length, 12)
        XCTAssertEqual(map.opcode, 1, "UDP")
        XCTAssertEqual(map.lifetime, 7200)
        _ = try await mapper.map(second)
        XCTAssertEqual(router.mapRequests.last?.opcode, 2, "TCP")
        let pcpAttempts = router.requests.filter { $0.method == .pcp }.count
        XCTAssertEqual(pcpAttempts, 1, "once NAT-PMP is settled, PCP is not tried again")

        await mapper.stop()
        let deletes = router.mapRequests.suffix(2)
        XCTAssertTrue(deletes.allSatisfy { $0.lifetime == 0 && $0.suggestedPort == 0 }, "RFC 6886 §3.4 delete")
        XCTAssertTrue(router.mappings.isEmpty)
    }

    func testARefusalIsReportedAndNotHeld() async throws {
        let router = try router()
        router.refuse(.tcp, code: 8)
        let records = recordsFile()
        let mapper = try mapper(for: router, records: records)
        _ = try await mapper.map(endpoint)
        do {
            _ = try await mapper.map(second)
            XCTFail("the router refused TCP")
        } catch let error as PortMappingError {
            XCTAssertEqual(error, .refused(method: .pcp, code: 8))
            XCTAssertEqual(error.localizedDescription, "The router refused the mapping: no resources.")
        }
        let held = await mapper.mappings
        XCTAssertEqual(held.map(\.request), [endpoint])
        XCTAssertEqual(try savedRecords(records).map { $0["transport"] as? String }, ["udp"], "a refused mapping is not kept on record")
        await mapper.stop()
    }

    // MARK: - What a run leaves behind

    func testMappingsLeftByACrashedRunAreDeletedWithTheirSavedNoncesAtTheNextStart() async throws {
        let router = try router()
        let records = recordsFile()
        var crashed: PortMapper? = try mapper(for: router, records: records)
        _ = try await crashed?.map(endpoint)
        _ = try await crashed?.map(second)
        let made = router.mapRequests
        crashed = nil // no stop: as if the app crashed or was force quit
        XCTAssertEqual(router.mappings.count, 2)

        let next = try mapper(for: router, records: records)
        let events = EventLog(next)
        let leftovers = await next.leftovers
        XCTAssertEqual(Set(leftovers), [endpoint, second])
        let unconfirmed = try await next.removeLeftovers()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertTrue(router.mappings.isEmpty, "the router accepted the deletes: they carry the nonces the mappings were made with")
        let deletes = router.mapRequests.dropFirst(2)
        XCTAssertTrue(deletes.allSatisfy { $0.lifetime == 0 })
        XCTAssertEqual(Set(deletes.compactMap(\.nonce)), Set(made.compactMap(\.nonce)))
        XCTAssertEqual(try savedRecords(records).count, 0)
        try await eventually { events.all.filter { if case .removed = $0 { true } else { false } }.count == 2 }
    }

    func testAMappingLeftByACrashedRunIsTakenOverWithItsNonce() async throws {
        let router = try router()
        let records = recordsFile()
        var crashed: PortMapper? = try mapper(for: router, records: records)
        _ = try await crashed?.map(endpoint)
        crashed = nil

        let next = try mapper(for: router, records: records)
        let mapping = try await next.map(endpoint)
        XCTAssertEqual(mapping.externalPort, 38842)
        XCTAssertEqual(router.mapRequests[1].nonce, router.mapRequests[0].nonce, "the saved nonce, which the router accepts")
        await next.stop()
        XCTAssertTrue(router.mappings.isEmpty)
    }

    func testAMappingWithAnUnknownNonceIsReportedAsPossiblyLeftBehind() async throws {
        let router = try router()
        let first = try mapper(for: router)
        _ = try await first.map(endpoint)

        // Another run with no record of it (another records file) gets RFC 6887's NOT_AUTHORIZED.
        let other = try mapper(for: router)
        do {
            _ = try await other.map(endpoint)
            XCTFail("the router holds the port for another nonce")
        } catch let error as PortMappingError {
            guard case let .notAuthorized(retryAfter) = error else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(retryAfter, 7000)
            XCTAssertEqual(error.localizedDescription, "The router refused the mapping: not authorized. It may still hold a mapping of this port that an earlier run of AgentLand made; that one ends within 120 minutes.")
        }
        await first.stop()
    }

    func testADeleteTheRouterDoesNotConfirmIsReportedAndKeptForLater() async throws {
        let router = try router()
        let records = recordsFile()
        let mapper = try mapper(for: router, records: records)
        let events = EventLog(mapper)
        _ = try await mapper.map(endpoint)
        _ = try await mapper.map(second)
        router.mode = .silent
        let unconfirmed = await mapper.stop()
        XCTAssertEqual(unconfirmed, [second, endpoint])
        try await eventually {
            events.all.filter { if case .removalUnconfirmed = $0 { true } else { false } }.count == 2
        }
        XCTAssertFalse(events.all.contains { if case .removed = $0 { true } else { false } }, "nothing is reported removed")
        XCTAssertEqual(router.mappings.count, 2)
        XCTAssertEqual(try savedRecords(records).count, 2)

        router.mode = .pcp
        let later = try self.mapper(for: router, records: records)
        let stillUnconfirmed = try await later.removeLeftovers()
        XCTAssertEqual(stillUnconfirmed, [])
        XCTAssertTrue(router.mappings.isEmpty)
        XCTAssertEqual(try savedRecords(records).count, 0)
    }

    func testStopWaitsForARenewalInFlight() async throws {
        let router = try router()
        router.grantedLifetime = 2
        let mapper = try mapper(for: router)
        _ = try await mapper.map(endpoint)
        // The renewal's first two transmissions are lost; its third arrives 0.3 s later.
        router.dropMapRequests(2)
        try await eventually(timeout: 4) { router.mapRequests.count >= 2 }
        let unconfirmed = await mapper.stop()
        let stopped = PortMapper.now()
        XCTAssertEqual(unconfirmed, [])
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(router.mapRequests.contains { $0.lifetime > 0 && $0.receivedAt > stopped },
                       "no mapping request reaches the router after stop returns")
        XCTAssertTrue(router.mappings.isEmpty)
        XCTAssertEqual(router.mapRequests.last?.lifetime, 0)
    }

    // MARK: - Granted ports

    func testAMappingGrantedAnotherPortIsStillHeldAndNeverALeftover() async throws {
        let router = try router()
        router.grantedPortOffset = 5
        let records = recordsFile()
        let mapper = try mapper(for: router, records: records)
        let mapping = try await mapper.map(second)
        XCTAssertEqual(mapping.externalPort, 38846, "the router granted another port than 38841")
        let saved = try XCTUnwrap(try savedRecords(records).first)
        XCTAssertEqual(saved["requestedPort"] as? Int, 38841, "the record keeps the port asked for")
        XCTAssertEqual(saved["externalPort"] as? Int, 38846, "and the port granted")

        let leftovers = await mapper.leftovers
        XCTAssertEqual(leftovers, [], "a mapping this mapper holds is not a leftover, whatever port was granted")
        let unconfirmed = try await mapper.removeLeftovers()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertEqual(router.mapRequests.count, 1, "nothing was deleted")
        XCTAssertEqual(router.mappings[.tcp], [38841: 38846])
        XCTAssertEqual(try savedRecords(records).count, 1)

        // The router knows one mapping per transport and internal port.
        do {
            _ = try await mapper.map(try PortMappingRequest(.tcp, internalPort: 38841, externalPort: 40000))
            XCTFail("the internal port is already mapped")
        } catch let error as PortMappingError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(router.mapRequests.count, 1)
        await mapper.stop()
        XCTAssertTrue(router.mappings.isEmpty)
    }

    func testALeftoverGrantedAnotherPortIsReportedAsRequestedAndDeleted() async throws {
        let router = try router()
        router.grantedPortOffset = 5
        let records = recordsFile()
        var crashed: PortMapper? = try mapper(for: router, records: records)
        _ = try await crashed?.map(second)
        crashed = nil

        let next = try mapper(for: router, records: records)
        let leftovers = await next.leftovers
        XCTAssertEqual(leftovers, [second], "the request as it was made, with the port asked for")
        let unconfirmed = try await next.removeLeftovers()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertTrue(router.mappings.isEmpty)
        XCTAssertEqual(router.mapRequests.last?.suggestedPort, 38846, "the delete names the port the router granted")
        XCTAssertEqual(try savedRecords(records).count, 0)
    }

    // MARK: - Who owns the records

    func testASecondMapperNeverTouchesTheMappingsALiveMapperKeeps() async throws {
        let router = try router()
        let records = recordsFile()
        let first = try mapper(for: router, records: records)
        _ = try await first.map(endpoint)
        _ = try await first.map(second)
        let sent = router.requests.count
        let written = try Data(contentsOf: records)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: records.deletingPathExtension().appendingPathExtension("lock").path)[.posixPermissions] as? Int, 0o600)

        // Another copy of AgentLand, at launch and when remote access is turned on there.
        let second = try mapper(for: router, records: records)
        let leftovers = await second.leftovers
        XCTAssertEqual(leftovers, [], "what a live mapper keeps is not a leftover")
        do {
            _ = try await second.removeLeftovers()
            XCTFail("the first mapper owns the records")
        } catch {
            XCTAssertEqual(error as? PortMappingError, .ownedElsewhere)
            XCTAssertEqual(error.localizedDescription, "Another copy of AgentLand is managing this Mac's router mappings. Quit it first.")
        }
        do {
            _ = try await second.map(endpoint)
            XCTFail("the first mapper owns the records")
        } catch {
            XCTAssertEqual(error as? PortMappingError, .ownedElsewhere)
        }
        XCTAssertEqual(router.requests.count, sent, "the second mapper sent nothing to the router")
        XCTAssertEqual(router.mappings[.udp], [38842: 38842])
        XCTAssertEqual(router.mappings[.tcp], [38841: 38841])
        XCTAssertEqual(try Data(contentsOf: records), written, "and changed no record")

        // Once the first has stopped, the second owns the records.
        let unconfirmed = await first.stop()
        XCTAssertEqual(unconfirmed, [])
        let left = try await second.removeLeftovers()
        XCTAssertEqual(left, [])
        _ = try await second.map(endpoint)
        do {
            _ = try await first.map(endpoint)
            XCTFail("now the second mapper owns the records")
        } catch {
            XCTAssertEqual(error as? PortMappingError, .ownedElsewhere)
        }
        await second.stop()
        XCTAssertTrue(router.mappings.isEmpty)
    }

    func testRecordsLockedByAnotherProcessAreLeftAlone() async throws {
        let router = try router()
        let records = recordsFile()
        var crashed: PortMapper? = try mapper(for: router, records: records)
        _ = try await crashed?.map(endpoint)
        crashed = nil
        let sent = router.requests.count

        // Another copy of AgentLand holds the lock: a separate process, as a second app would be.
        let lockFile = records.deletingPathExtension().appendingPathExtension("lock")
        let holder = Process()
        let output = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", """
            import fcntl, sys, time
            f = open(sys.argv[1], 'a')
            for _ in range(100):
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(0.05)
            else:
                print('busy', flush=True)
                sys.exit(1)
            print('locked', flush=True)
            time.sleep(60)
            """, lockFile.path]
        holder.standardOutput = output
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let line = output.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "locked")

        let next = try mapper(for: router, records: records)
        do {
            _ = try await next.removeLeftovers()
            XCTFail("another process owns the records")
        } catch {
            XCTAssertEqual(error as? PortMappingError, .ownedElsewhere)
        }
        do {
            _ = try await next.map(second)
            XCTFail("another process owns the records")
        } catch {
            XCTAssertEqual(error as? PortMappingError, .ownedElsewhere)
        }
        XCTAssertEqual(router.requests.count, sent)
        XCTAssertEqual(router.mappings[.udp], [38842: 38842])

        holder.terminate()
        holder.waitUntilExit()
        let unconfirmed = try await next.removeLeftovers()
        XCTAssertEqual(unconfirmed, [])
        XCTAssertTrue(router.mappings.isEmpty, "the leftover is deleted once its records are free")
    }

    func testAMapperMadeAfterANetworkChangeKeepsTheOldMappersRecords() async throws {
        let old = try router(), new = try router()
        let records = recordsFile()
        let oldMapper = try mapper(for: old, records: records)
        _ = try await oldMapper.map(endpoint)
        let oldNonce = try XCTUnwrap(try savedRecords(records).first?["nonce"] as? String)
        // The old network is gone: its router no longer answers, so the delete is not confirmed.
        old.mode = .silent
        let newMapper = try mapper(for: new, records: records)
        let stopping = Task { await oldMapper.stop() }
        do {
            _ = try await newMapper.map(second)
            XCTFail("the old mapper still owns the records while it stops")
        } catch {
            XCTAssertEqual(error as? PortMappingError, .ownedElsewhere)
        }
        XCTAssertTrue(new.requests.isEmpty)
        let unconfirmed = await stopping.value
        XCTAssertEqual(unconfirmed, [endpoint])

        _ = try await newMapper.map(second)
        let saved = try savedRecords(records)
        XCTAssertEqual(Set(saved.compactMap { $0["transport"] as? String }), ["udp", "tcp"],
                       "the new mapper's record is added to the old one's, not written over it")
        XCTAssertEqual(saved.first { $0["transport"] as? String == "udp" }?["nonce"] as? String, oldNonce,
                       "the unconfirmed mapping keeps its nonce for a later delete")
        await newMapper.stop()
        XCTAssertEqual(try savedRecords(records).compactMap { $0["transport"] as? String }, ["udp"])
    }

    // MARK: - Renewals and their records

    func testARenewalIsRecordedBeforeItIsSent() async throws {
        let router = try router()
        let records = recordsFile()
        var first: PortMapper? = try mapper(for: router, lifetime: 4, records: records)
        _ = try await first?.map(endpoint)
        // The router applies the renewal (due at half of 4 s) and every retransmission, but no answer arrives.
        router.loseAnswers(100)
        try await eventually(timeout: 5) { router.mapRequests.count >= 2 }
        XCTAssertEqual(router.mapRequests[1].lifetime, 4)
        let recorded = try XCTUnwrap((try savedRecords(records).first?["expiresAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)))
        try await eventually { router.mapRequests.count >= 4 } // the last retransmission
        let routerKeeps = try XCTUnwrap(router.remainingLifetime(.udp, internalPort: 38842))
        XCTAssertGreaterThanOrEqual(recorded.timeIntervalSinceNow, routerKeeps,
                                    "the record lasts as long as the mapping the renewal extended")

        // The app ends before any answer (a crash). Past the lifetime recorded at `map`, the next run
        // still has the nonce the router's mapping was renewed with, so it can take it over.
        first = nil
        router.loseAnswers(0)
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertNotNil(router.remainingLifetime(.udp, internalPort: 38842), "the renewed mapping still lasts")
        let next = try mapper(for: router, lifetime: 4, records: records)
        let mapping = try await next.map(endpoint)
        XCTAssertEqual(mapping.externalPort, 38842, "taken over, not refused with NOT_AUTHORIZED")
        await next.stop()
        XCTAssertTrue(router.mappings.isEmpty)
    }

    func testARenewalThatCannotBeRecordedIsNotSent() async throws {
        let router = try router()
        let records = recordsFile()
        let mapper = try mapper(for: router, lifetime: 2, records: records)
        let events = EventLog(mapper)
        _ = try await mapper.map(endpoint)
        // The records file can no longer be replaced: a folder with a file in it stands at its path.
        try FileManager.default.removeItem(at: records)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
        try Data().write(to: records.appendingPathComponent("occupied"))
        try await eventually(timeout: 4) {
            events.all.contains { if case .renewalFailed(_, .records) = $0 { true } else { false } }
        }
        XCTAssertEqual(router.mapRequests.count, 1, "a renewal that could not be recorded was not sent")
        await mapper.stop()
        XCTAssertTrue(router.mappings.isEmpty)
    }

    // MARK: - Router kinds

    func testNoAnswerFailsWithinTheRetransmissions() async throws {
        let router = try router(.silent)
        let records = recordsFile()
        let mapper = try mapper(for: router, timeouts: [0.05, 0.1], records: records)
        let started = Date()
        do {
            _ = try await mapper.map(endpoint)
            XCTFail("nothing answers")
        } catch let error as PortMappingError {
            XCTAssertEqual(error, .noResponse)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(router.datagramsReceived, 4, "PCP twice, then NAT-PMP twice")
        let held = await mapper.mappings
        XCTAssertTrue(held.isEmpty)
        XCTAssertEqual(try savedRecords(records).count, 1, "without an answer the router may have made it: the record stays")
    }

    func testAPCPOnlyRoutersExternalAddressComesFromItsMapAnswer() async throws {
        let router = try router(.pcpOnly)
        let mapper = try mapper(for: router, timeouts: [0.5, 1])
        let started = Date()
        do {
            _ = try await mapper.externalAddress()
            XCTFail("no mapping has given the address yet")
        } catch let error as PortMappingError {
            XCTAssertEqual(error, .unsupportedVersion)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4, "PCP's UNSUPP_VERSION answer ends the query at once")

        _ = try await mapper.map(endpoint)
        let method = await mapper.method
        XCTAssertEqual(method, .pcp)
        let queries = router.requests.filter { $0.method == .natPMP }.count
        let address = try await mapper.externalAddress()
        XCTAssertEqual(address.description, "203.0.113.7")
        XCTAssertEqual(router.requests.filter { $0.method == .natPMP }.count, queries, "the MAP answer's address, with no NAT-PMP query")
        await mapper.stop()
    }

    func testANATPMPRouterRestartIsNoticedAndEveryMappingIsMadeAgain() async throws {
        let router = try router(.natPMPOnly)
        let mapper = try mapper(for: router, epochCheck: 0.3)
        let events = EventLog(mapper)
        _ = try await mapper.map(endpoint)
        _ = try await mapper.map(second)
        try await eventually { router.requests.filter { $0.method == .natPMP && $0.opcode == 0 }.count >= 2 }
        XCTAssertFalse(events.all.contains(.gatewayRestarted), "a steady epoch is not a restart")

        router.restart()
        XCTAssertTrue(router.mappings.isEmpty)
        try await eventually(timeout: 4) {
            router.mappings[.udp] == [38842: 38842] && router.mappings[.tcp] == [38841: 38841]
        }
        XCTAssertTrue(events.all.contains(.gatewayRestarted))
        XCTAssertTrue(router.mapRequests.suffix(2).allSatisfy { $0.method == .natPMP && $0.lifetime == 7200 })
        await mapper.stop()
        XCTAssertTrue(router.mappings.isEmpty)
    }

    func testAnswersThatAreNotForTheRequestAreSkipped() async throws {
        let router = try router()
        router.sendStrayAnswerFirst()
        let mapper = try mapper(for: router)
        let mapping = try await mapper.map(endpoint)
        XCTAssertEqual(mapping.externalPort, 38842, "the answer with another nonce was not taken")
        XCTAssertEqual(router.mapRequests.count, 1)
        await mapper.stop()
    }

    func testRequestsAndGatewaysThatAreRefusedBeforeSending() throws {
        XCTAssertThrowsError(try PortMappingRequest(.udp, internalPort: 41641))
        XCTAssertThrowsError(try PortMappingRequest(.udp, internalPort: 38842, externalPort: 41641))
        XCTAssertThrowsError(try PortMappingRequest(.tcp, internalPort: 0))
        XCTAssertThrowsError(try PortMapper.Configuration(gateway: "8.8.8.8", recordsFile: nil), "only this network's router")
        XCTAssertThrowsError(try PortMapper.Configuration(gateway: "192.168.1", recordsFile: nil))
        XCTAssertNoThrow(try PortMapper.Configuration(gateway: "192.168.1.1", recordsFile: nil))
        XCTAssertNoThrow(try PortMapper.Configuration(gateway: "10.0.0.1", recordsFile: nil))
    }

    func testEpochRules() {
        var natPMP = EpochTracker()
        XCTAssertFalse(natPMP.observe(1000, at: 50, method: .natPMP))
        XCTAssertFalse(natPMP.observe(1100, at: 150, method: .natPMP))
        XCTAssertFalse(natPMP.observe(1187, at: 250, method: .natPMP), "7/8 of the elapsed time is enough")
        XCTAssertTrue(natPMP.observe(40, at: 300, method: .natPMP), "the epoch went back")
        var pcp = EpochTracker()
        XCTAssertFalse(pcp.observe(5000, at: 10, method: .pcp))
        XCTAssertFalse(pcp.observe(5300, at: 310, method: .pcp))
        XCTAssertTrue(pcp.observe(5301, at: 610, method: .pcp), "the router's clock stood still: it restarted")
        XCTAssertTrue(pcp.observe(1, at: 611, method: .pcp))
    }

    func testTheDefaultRouteIsReadFromTheRoutingTable() throws {
        let header = MemoryLayout<rt_msghdr>.size
        func message(flags: Int32, destination: [UInt8], gateway: [UInt8], mask: [UInt8]) -> [UInt8] {
            func socketAddress(_ bytes: [UInt8]) -> [UInt8] { [16, UInt8(AF_INET), 0, 0] + bytes + [UInt8](repeating: 0, count: 8) }
            let addresses = socketAddress(destination) + socketAddress(gateway) + mask
            var route = rt_msghdr()
            route.rtm_msglen = UInt16(header + addresses.count)
            route.rtm_flags = flags
            route.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK
            return withUnsafeBytes(of: &route) { Array($0) } + addresses
        }
        let scoped = message(flags: RTF_UP | RTF_GATEWAY | Int32(RTF_IFSCOPE), destination: [0, 0, 0, 0],
                             gateway: [10, 0, 0, 1], mask: [0, 0, 0, 0])
        let network = message(flags: RTF_UP | RTF_GATEWAY, destination: [10, 1, 0, 0],
                              gateway: [192, 168, 1, 254], mask: [8, UInt8(AF_INET), 0, 0, 255, 255, 0, 0])
        let primary = message(flags: RTF_UP | RTF_GATEWAY, destination: [0, 0, 0, 0],
                              gateway: [192, 168, 1, 1], mask: [0, 0, 0, 0])
        XCTAssertEqual(DefaultGateway.defaultRoute(inRoutingMessages: scoped + network + primary)?.description, "192.168.1.1")
        XCTAssertNil(DefaultGateway.defaultRoute(inRoutingMessages: scoped + network))
        // Reading this Mac's table sends nothing; whatever it finds is a private address.
        if let live = DefaultGateway.ipv4() { XCTAssertTrue(live.isPrivate) }
    }

    /// The router's link-layer address tells it from another router at the same gateway address
    /// (`RemoteAccessMappingPlan.Router`). It comes from the ARP table: an entry's destination is the
    /// IPv4 address and its gateway a `sockaddr_dl`, whose address follows the interface name.
    func testTheRoutersLinkLayerAddressIsReadFromTheARPTable() throws {
        let header = MemoryLayout<rt_msghdr>.size
        func entry(_ ip: [UInt8], name: [UInt8] = [], link: [UInt8]) -> [UInt8] {
            let destination: [UInt8] = [16, UInt8(AF_INET), 0, 0] + ip + [UInt8](repeating: 0, count: 8)
            var linkAddress: [UInt8] = [0, UInt8(AF_LINK), 4, 0, 6, UInt8(name.count), UInt8(link.count), 0] + name + link
            linkAddress[0] = UInt8(max(20, linkAddress.count))
            linkAddress += [UInt8](repeating: 0, count: (Int(linkAddress[0]) + 3) & ~3 - linkAddress.count)
            var route = rt_msghdr()
            route.rtm_msglen = UInt16(header + destination.count + linkAddress.count)
            route.rtm_flags = RTF_UP | RTF_HOST | RTF_LLINFO
            route.rtm_addrs = RTA_DST | RTA_GATEWAY
            return withUnsafeBytes(of: &route) { Array($0) } + destination + linkAddress
        }
        let router = try XCTUnwrap(IPv4Address("192.168.1.1"))
        let incomplete = entry([192, 168, 1, 1], link: [])
        let other = entry([192, 168, 1, 20], link: [0x0e, 0, 0, 0, 0, 0x14])
        let named = entry([192, 168, 1, 1], name: Array("en0".utf8), link: [0xA0, 0xB1, 0xC2, 0xD3, 0xE4, 0xF5])
        XCTAssertEqual(DefaultGateway.hardwareAddress(of: router, inRoutingMessages: incomplete + other + named), "a0:b1:c2:d3:e4:f5")
        XCTAssertEqual(DefaultGateway.hardwareAddress(of: router, inRoutingMessages: entry([192, 168, 1, 1], link: [0xA0, 0xB1, 0xC2, 0xD3, 0xE4, 0xF5])),
                       "a0:b1:c2:d3:e4:f5")
        XCTAssertNil(DefaultGateway.hardwareAddress(of: router, inRoutingMessages: incomplete + other), "no complete entry")
        XCTAssertNil(DefaultGateway.hardwareAddress(of: router, inRoutingMessages: entry([192, 168, 1, 1], link: [0, 0, 0, 0, 0, 0])))
        // Reading this Mac's ARP table sends nothing; an entry it finds for the router is six pairs.
        if let gateway = DefaultGateway.ipv4(), let live = DefaultGateway.hardwareAddress(of: gateway) {
            XCTAssertNotNil(live.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression))
        }
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { throw PortMappingError.noResponse }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Collects a mapper's events as they come.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PortMappingEvent] = []
    private var task: Task<Void, Never>?

    init(_ mapper: PortMapper) {
        let stream = mapper.events
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ event: PortMappingEvent) { lock.withLock { events.append(event) } }
    var all: [PortMappingEvent] { lock.withLock { events } }
    var mapped: [PortMapping] { all.compactMap { if case let .mapped(mapping) = $0 { mapping } else { nil } } }
}
