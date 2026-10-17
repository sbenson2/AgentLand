import Foundation
import XCTest
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

final class OnboardingControllerTests: XCTestCase {
    @MainActor
    func testInvalidWorkspaceDoesNotCreateCredentialsOrStartServices() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        let host = fixture.controller()
        host.chooseWorkspace(at: fixture.root.appendingPathComponent("missing"))
        await host.waitForCurrentOperation()
        XCTAssertEqual(host.onboardingStage, .folder)
        XCTAssertEqual(host.status, .stopped)
        XCTAssertNotNil(host.errorMessage)
        XCTAssertEqual(fixture.secrets.saveCount, 0)
        XCTAssertEqual(fixture.runner.count, 0)
        XCTAssertFalse(host.connectionDesired)
    }

    @MainActor
    func testLegacySettingsPreserveExternalRuntimeAndStayDisconnected() throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        try Data("existing host state".utf8).write(to: fixture.state)
        let legacy: [String: Any] = [
            "projectDirectory": fixture.root.path, "projectName": "Existing", "projectID": "old",
            "openCodeURL": "http://127.0.0.1:4197", "listenAddress": "0.0.0.0:9900",
            "terminalEnabled": false, "connectionMode": "trustedHTTPS",
            "certificatePath": "/old/cert", "keyPath": "/old/key", "advertisedHost": "old.local"
        ]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "dev.agentland.desktop.preferences.v1")
        let host = fixture.controller()
        XCTAssertFalse(host.managedOpenCode)
        XCTAssertFalse(host.connectionDesired)
        XCTAssertFalse(host.needsOnboarding)
        XCTAssertEqual(host.projectID, "old")
        XCTAssertEqual(host.listenAddress, "0.0.0.0:9900")
        XCTAssertEqual(host.certificatePath, "/old/cert")
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertEqual(fixture.runner.count, 0)
    }

    @MainActor
    func testExternalLoopbackConfigurationStillStoresItsExplicitPassword() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        try Data("existing host state".utf8).write(to: fixture.state)
        let legacy: [String: Any] = [
            "projectDirectory": fixture.root.path, "projectName": "Existing", "projectID": "old",
            "openCodeURL": "http://127.0.0.1:4197", "listenAddress": "0.0.0.0:9900",
            "terminalEnabled": false, "connectionMode": "trustedHTTPS",
            "certificatePath": "/old/cert", "keyPath": "/old/key", "advertisedHost": "old.local",
            "managedOpenCode": false
        ]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "dev.agentland.desktop.preferences.v1")
        let host = fixture.controller()
        host.openCodePassword = "external-test-password"
        host.saveConfiguration()
        await host.waitForCurrentOperation()
        XCTAssertEqual(try fixture.secrets.load(account: "opencode.password"), "external-test-password")
        XCTAssertEqual(fixture.secrets.saveCount, 1)
    }

    @MainActor
    func testStoppingDuringCertificatePreparationPreventsLateRuntimeLaunch() async throws {
        let fixture = try SetupFixture()
        defer { fixture.cleanUp() }
        let host = fixture.controller()
        host.chooseWorkspace(at: fixture.root)
        for _ in 0..<100 where fixture.runner.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.runner.count, 1)
        host.stop()
        await host.waitForCurrentOperation()
        let launches = await fixture.runtime.startCount
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(host.status, .stopped)
        XCTAssertFalse(host.connectionDesired)
        XCTAssertFalse(host.isWorking)
        XCTAssertNil(host.errorMessage, "Cancelled setup must not show a stale failure")
        XCTAssertNil(host.activeAdvertisement)
    }
}

private struct SetupFixture {
    let root: URL
    let state: URL
    let suite: String
    let defaults: UserDefaults
    let secrets = SetupSecrets()
    let runner = SetupRunner()
    let runtime = SetupRuntime()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-onboarding-unit-\(UUID().uuidString)")
        state = root.appendingPathComponent("host.json")
        suite = "dev.agentland.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @MainActor func controller() -> HostController {
        HostController(statePath: state.path, runner: runner, secrets: secrets, preferences: defaults, runtime: runtime)
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

private final class SetupSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var saves = 0
    var saveCount: Int { lock.withLock { saves } }
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret; saves += 1 } }
    func load(account: String) throws -> String? { lock.withLock { values[account] } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
}

private final class SetupRunner: HostCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run(_ command: HostCommand) throws -> CommandOutput {
        lock.withLock { calls += 1 }
        Thread.sleep(forTimeInterval: 0.2)
        return CommandOutput(standardOutput: "{\"certificateFile\":\"/disposable/cert\",\"keyFile\":\"/disposable/key\",\"fingerprint\":\"fake\"}", standardError: "", exitCode: 0)
    }
}

private actor SetupRuntime: OpenCodeRuntimeRunning {
    private(set) var startCount = 0
    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL {
        startCount += 1
        throw DesktopError.commandFailed("This runtime must not start in these tests.")
    }
    func stop() async throws {}
    func isRunning() -> Bool { false }
    func endpoint() -> URL? { nil }
}
