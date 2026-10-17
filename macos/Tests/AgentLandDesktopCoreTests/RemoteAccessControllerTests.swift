import Foundation
import XCTest
import AgentLandCore
import AgentLandPairing
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The Mac app's hold on remote access (`RemoteAccessController` and `HostController`), with the
/// service's fakes (`RemoteAccessServiceTests.Harness`: a fake endpoint binder, `FakeRouter` on loopback,
/// the host's routes and the record's database): Quit, the connection mode and pairing
/// (docs/HOST-API.md "The Mac switches", "Pairing with a node ID").
@MainActor
final class RemoteAccessControllerTests: XCTestCase {
    private var cleanups: [() async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
    }

    /// A controller whose service runs on the harness's fakes (or `dependencies` made from them).
    private func controller(_ harness: RemoteAccessServiceTests.Harness,
                            dependencies: RemoteAccessService.Dependencies? = nil) throws -> (RemoteAccessController, UserDefaults, String) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("al-rac-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "dev.agentland.remote-access-controller-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let dependencies = dependencies ?? harness.dependencies
        let controller = RemoteAccessController(statePath: folder.appendingPathComponent("host.json").path, preferences: defaults,
                                                makeService: { settings, _, save, publish in
            RemoteAccessService(settings: settings, dependencies: dependencies, save: save, onStatus: publish)
        })
        cleanups.append {
            await controller.shutdown()
            await harness.service.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        return (controller, defaults, folder.appendingPathComponent("host.json").path)
    }

    private func until(_ message: String = "condition", timeout: TimeInterval = 5, _ condition: () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(message)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The switch turned off with the host stopped, and Quit at once: Quit still waits, so the mapping's
    /// delete runs before the app ends instead of leaving the port open on the router.
    func testQuitWaitsForATurnOffThatIsStillDeletingTheMapping() async throws {
        let harness = try RemoteAccessServiceTests.Harness()
        let (remoteAccess, defaults, statePath) = try controller(harness)
        remoteAccess.activate()
        remoteAccess.setEnabled(true)
        try await until("the mapping") { remoteAccess.status.mapping.state == .mapped }
        XCTAssertEqual(harness.router.mappings, [.udp: [38842: 38842]])

        let host = HostController(statePath: statePath, runner: NoCommands(), secrets: NoSecrets(), preferences: defaults,
                                  runtime: StoppedRuntime(), remoteAccess: remoteAccess)
        XCTAssertEqual(host.status, .stopped)
        remoteAccess.setEnabled(false)
        XCTAssertFalse(remoteAccess.status.enabled)
        XCTAssertTrue(remoteAccess.needsShutdown, "the turn-off is still deleting the mapping")
        XCTAssertTrue(host.requiresShutdown, "Quit waits although the host is stopped")

        try await host.stopForApplicationTermination()
        XCTAssertEqual(harness.router.mappings, [:], "the delete ran before Quit went on")
        XCTAssertTrue(harness.router.mapRequests.contains { $0.lifetime == 0 })
        try await until("nothing left to wait for") { !remoteAccess.needsShutdown }
    }

    /// A Quit whose stop fails is cancelled: remote access was not shut down, so it keeps running as the
    /// switch says, and the switch still works.
    func testAQuitThatFailsLeavesRemoteAccessRunning() async throws {
        let harness = try RemoteAccessServiceTests.Harness()
        let (remoteAccess, defaults, statePath) = try controller(harness)
        remoteAccess.activate()
        remoteAccess.setEnabled(true)
        try await until("the mapping") { remoteAccess.status.mapping.state == .mapped }
        let host = HostController(statePath: statePath, runner: NoCommands(), secrets: NoSecrets(), preferences: defaults,
                                  runtime: StoppedRuntime(stopFails: true), remoteAccess: remoteAccess)

        do {
            try await host.stopForApplicationTermination()
            XCTFail("the runtime's stop fails")
        } catch {}
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(remoteAccess.status.endpoint, .running)
        XCTAssertEqual(harness.router.mappings, [.udp: [38842: 38842]], "the mapping stays while the switch is on")
        XCTAssertTrue(remoteAccess.needsShutdown)

        remoteAccess.setEnabled(false)
        try await until("the switch turned off") { remoteAccess.status.endpoint == .off && harness.router.mappings.isEmpty }
    }

    /// Local development HTTP carries no tunnel: the controller follows the host's connection mode, so
    /// the endpoint and the mapping stop there with the switch still on, and start again with trusted
    /// HTTPS.
    func testTheConnectionModeStopsAndStartsRemoteAccess() async throws {
        let harness = try RemoteAccessServiceTests.Harness()
        let (remoteAccess, defaults, statePath) = try controller(harness)
        let host = HostController(statePath: statePath, runner: NoCommands(), secrets: NoSecrets(), preferences: defaults,
                                  runtime: StoppedRuntime(), remoteAccess: remoteAccess)
        remoteAccess.activate()
        remoteAccess.setEnabled(true)
        try await until("the mapping") { remoteAccess.status.mapping.state == .mapped }

        host.connectionMode = .developmentHTTP
        try await until("stopped") { remoteAccess.status.endpoint == .off && harness.router.mappings.isEmpty }
        XCTAssertTrue(remoteAccess.status.enabled)
        XCTAssertFalse(remoteAccess.status.tunnelServed)
        XCTAssertEqual(remoteAccess.status.summary().title, RemoteAccessSummary.needsHTTPSTitle)

        host.connectionMode = .trustedHTTPS
        try await until("running again") { remoteAccess.status.endpoint == .running && remoteAccess.status.mapping.state == .mapped }
        XCTAssertEqual(harness.router.mappings, [.udp: [38842: 38842]])
    }

    /// Development HTTP and straight back while the service is still busy with an earlier call (the
    /// fallback's restart, waiting for the endpoint's close): meanwhile the service publishes a status from
    /// outside its queue (a mapping event) that still says trusted HTTPS. The flip back must not be dropped
    /// for matching that stale value, or the service would end in development HTTP with the picker on
    /// trusted HTTPS: the endpoint closed, the mapping deleted and the row saying "Off while the connection
    /// is Local development HTTP".
    func testDevelopmentHTTPAndStraightBackWhileTheServiceIsBusy() async throws {
        let harness = try RemoteAccessServiceTests.Harness()
        let mappingEvents = Locked<(@Sendable (RemoteAccessMapping.Outcome, RemoteAccessMappingPlan) -> Void)?>(nil)
        var dependencies = harness.dependencies
        let makeMapping = dependencies.makeMapping
        dependencies.makeMapping = { plan, onChange in
            mappingEvents.set(onChange)
            return makeMapping(plan, onChange)
        }
        let (remoteAccess, defaults, _) = try controller(harness, dependencies: dependencies)
        remoteAccess.activate()
        remoteAccess.setEnabled(true)
        try await until("the mapping") { remoteAccess.status.endpoint == .running && remoteAccess.status.mapping.state == .mapped }

        harness.binder.closes.hold()
        remoteAccess.setFallback(true)
        try await until("the restart waiting for the endpoint's close") { harness.binder.closes.waiting == 1 }
        remoteAccess.setTunnelServed(false)
        XCTAssertFalse(remoteAccess.status.tunnelServed)
        let publish = try XCTUnwrap(mappingEvents.value)
        publish(remoteAccess.status.mapping, RemoteAccessController.readSettings(defaults).plan)
        try await until("a status published before the service took the change") { remoteAccess.status.tunnelServed }
        remoteAccess.setTunnelServed(true)
        harness.binder.closes.release()

        // The fallback's restart binds and publishes running and mapped (the mapping stays through a
        // restart) before the service runs the two flips, and the controller already says trusted HTTPS:
        // that status would match the wait below while the first flip deletes the mapping. Every call has
        // returned only once the service has run both flips, and their statuses reach the main actor before
        // the count does.
        try await until("the service ran every call") { remoteAccess.callsInProgress == 0 }
        try await until("running again with trusted HTTPS") {
            remoteAccess.status.tunnelServed && remoteAccess.status.endpoint == .running && remoteAccess.status.mapping.state == .mapped
        }
        XCTAssertEqual(harness.router.mappings, [.udp: [38842: 38842]])
        XCTAssertEqual(remoteAccess.status.summary().tone, .reachable)
    }

    /// A host that lists `remoteAccess` takes node IDs at pairing: its QR invitation carries
    /// `remoteAccess` version 1, so the phone sends its node ID and proof; a host that does not list it
    /// gets an invitation without it.
    func testTheInvitationCarriesRemoteAccessWhenTheHostListsIt() throws {
        let advertisement = try HostAdvertisement(name: "Mac", address: "https://mac.local:9841",
                                                  certificateSHA256: String(repeating: "ab", count: 32))
        let with = try HostController.invitation(advertisement: advertisement, code: "0012345678", requestedAt: Date(),
                                                 routes: nil, remoteAccess: true)
        XCTAssertTrue(with.acceptsIrohNodeID)
        XCTAssertTrue(try PairingInvitation.parse(try with.encoded()).acceptsIrohNodeID, "carried in the QR code")
        let without = try HostController.invitation(advertisement: advertisement, code: "0012345678", requestedAt: Date(),
                                                    routes: nil, remoteAccess: false)
        XCTAssertFalse(without.acceptsIrohNodeID)
        XCTAssertFalse(try PairingInvitation.parse(try without.encoded()).acceptsIrohNodeID)
    }

    /// What the Mac keeps of the running host's capabilities says whether it takes node IDs.
    func testTheHostsCapabilitiesSayWhetherItTakesNodeIDs() throws {
        let suite = "dev.agentland.capabilities-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = HostController(statePath: NSTemporaryDirectory() + "al-none/host.json", runner: NoCommands(), secrets: NoSecrets(),
                                  preferences: defaults, runtime: StoppedRuntime())
        let base = #"{"interactions":false,"terminal":true"#
        host.noteCapabilities(try JSONDecoder().decode(CapabilitiesResponse.self, from: Data((base + "}").utf8)))
        XCTAssertFalse(host.advertisedRemoteAccess)
        let listed = base + #","remoteAccess":{"version":1,"enabled":false,"directAddresses":[],"fallbackRelay":false,"sequence":0}}"#
        host.noteCapabilities(try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(listed.utf8)))
        XCTAssertTrue(host.advertisedRemoteAccess)
    }
}

private struct NoCommands: HostCommandRunning {
    func run(_ command: HostCommand) throws -> CommandOutput {
        throw DesktopError.commandFailed("No commands in the remote access controller tests.")
    }
}

private struct NoSecrets: SecretStoring {
    func save(_ secret: String, account: String) throws {}
    func load(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
}

/// A managed runtime that is not running; its stop can fail, as a runtime that does not end in time does.
private struct StoppedRuntime: OpenCodeRuntimeRunning {
    var stopFails = false
    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL {
        throw DesktopError.commandFailed("Not started in these tests.")
    }
    func stop() async throws {
        if stopFails { throw DesktopError.commandFailed("The runtime did not stop.") }
    }
    func isRunning() async -> Bool { false }
    func endpoint() async -> URL? { nil }
}
