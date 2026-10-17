import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

final class OnboardingIntegrationTests: XCTestCase {
    @MainActor
    func testFolderSetupPairingReconnectAndSavedConnectionIntent() async throws {
        guard ProcessInfo.processInfo.environment["AGENTLAND_TEST_ONBOARDING"] == "1",
              let runtimePath = ProcessInfo.processInfo.environment["AGENTLAND_OPENCODE_TEST_BINARY"] else {
            throw XCTSkip("Set AGENTLAND_TEST_ONBOARDING=1 and AGENTLAND_OPENCODE_TEST_BINARY for disposable real services")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-setup-live-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("Project=Sample", isDirectory: true)
        let state = root.appendingPathComponent("service/host.json")
        let binary = root.appendingPathComponent("agentland-host")
        let suite = "dev.agentland.onboarding-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let builder = ProcessCommandRunner(binaryURL: URL(fileURLWithPath: "/usr/bin/env"), timeout: 45)
        _ = try await Task.detached {
            try builder.run(HostCommand(arguments: ["go", "-C", repository.appendingPathComponent("desktop").path,
                "build", "-o", binary.path, "./cmd/agentland-host"]))
        }.value
        let runner = ProcessCommandRunner(binaryURL: binary)
        let secrets = OnboardingMemorySecrets()
        // The app bundles no OpenCode: the supplied one goes where the host installs it, so nothing downloads.
        let agents = URL(fileURLWithPath: try XCTUnwrap(HostCommandBuilder.agentsFolderPath(statePath: state.path)))
        try seedManagedOpenCode(URL(fileURLWithPath: runtimePath), agents: agents)
        let runtime = RecordingRuntime(ManagedOpenCodeRuntime(agentsFolder: agents, storageRoot: root.appendingPathComponent("runtime")))
        let lifecycle = HostLifecycle(processFactory: { ProcessHostProcess(command: $0, executableURL: binary) })
        let host = HostController(statePath: state.path, runner: runner, secrets: secrets,
            lifecycle: lifecycle, preferences: defaults, runtime: runtime)
        host.listenAddress = "0.0.0.0:\(try unusedPort())"
        var relaunched: HostController?
        do {
            host.chooseWorkspace(at: workspace)
            await host.waitForCurrentOperation()
            XCTAssertNil(host.errorMessage)
            XCTAssertEqual(host.status, .running)
            XCTAssertEqual(host.onboardingStage, .agents)
            XCTAssertTrue(host.connectionDesired)
            XCTAssertTrue(host.terminalEnabled)
            XCTAssertEqual(host.configuration?.projects.first?.directory, workspace.path)
            XCTAssertEqual(host.configuration?.projects.first?.name, "Project Sample")
            let advertisement = try XCTUnwrap(host.activeAdvertisement)
            let healthy = await HostReadinessProbe.isReady(advertisement)
            XCTAssertTrue(healthy)
            let originalCertificate = host.certificatePath
            let originalCertificateData = try Data(contentsOf: URL(fileURLWithPath: originalCertificate))
            XCTAssertEqual(secrets.accounts, [])
            try await waitUntil { !host.providerIsWorking }
            XCTAssertTrue(host.providerOptions.contains(where: { $0.id == "deepseek" }))
            XCTAssertNil(host.providerMessage)
            let initialPasswordCount = await runtime.passwordCount
            XCTAssertEqual(initialPasswordCount, 1, "The managed runtime and provider catalog share one in-memory password")
            // Saving uses disposable in-memory credentials and performs no model request.
            host.selectProvider("deepseek")
            let providerCanary = "agentland-disposable-key-" + UUID().uuidString
            host.providerAPIKey = providerCanary
            host.saveProvider()
            await host.waitForCurrentOperation()
            try await waitUntil { !host.providerIsWorking }
            XCTAssertNil(host.errorMessage)
            XCTAssertEqual(host.status, .running)
            XCTAssertFalse(host.needsOnboarding)
            XCTAssertTrue(host.providerAPIKey.isEmpty)
            XCTAssertEqual(secrets.accounts, ["provider.deepseek.api-key"])
            let storedPreferences = try XCTUnwrap(defaults.data(forKey: "dev.agentland.desktop.preferences.v1"))
            XCTAssertFalse(String(decoding: storedPreferences, as: UTF8.self).contains(providerCanary))
            XCTAssertFalse(String(decoding: try Data(contentsOf: state), as: UTF8.self).contains(providerCanary))
            let authFile = root.appendingPathComponent("runtime/data/opencode/auth.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: authFile.path), "Credentials must not be persisted through OpenCode auth")

            // A pending pairing and another configured workspace must survive reconnects.
            host.createPairingCode()
            try await waitUntil { !host.isWorking }
            XCTAssertNotNil(host.validInvitation)
            let before = try stateObject(state)
            let pending = try XCTUnwrap(before["pairingCodes"] as? [[String: Any]])
            XCTAssertEqual(pending.count, 1)
            let extra = ProjectConfiguration(id: "other", name: "Other", directory: root.path)
            let allProjects = (host.configuration?.projects ?? []) + [extra]
            let configurationCommand = try HostCommandBuilder.configureCommand(statePath: state.path,
                projects: allProjects, openCodeURL: host.openCodeURL, passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD")
            _ = try await Task.detached { try runner.run(configurationCommand) }.value
            host.saveConfiguration()
            await host.waitForCurrentOperation()
            XCTAssertNil(host.errorMessage)
            XCTAssertEqual(host.status, .running)
            XCTAssertEqual(Set(host.configuration?.projects.map(\.id) ?? []), ["workspace", "other"])
            XCTAssertEqual(host.certificatePath, originalCertificate)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: host.certificatePath)), originalCertificateData)
            let after = try stateObject(state)
            XCTAssertTrue(NSDictionary(dictionary: ["codes": pending]).isEqual(to: ["codes": after["pairingCodes"]!]))
            XCTAssertEqual(host.activeAdvertisement, advertisement)

            // Quit releases both children but remembers Connect; the next app instance resumes.
            let passwordStartsBeforeQuit = await runtime.passwordCount
            try await host.stopForApplicationTermination()
            XCTAssertTrue(host.connectionDesired)
            let stopped = await runtime.isRunning()
            XCTAssertFalse(stopped)
            XCTAssertEqual(host.status, .stopped)
            let next = HostController(statePath: state.path, runner: runner, secrets: secrets,
                lifecycle: lifecycle, preferences: defaults, runtime: runtime)
            relaunched = next
            next.load()
            try await waitUntil { !next.isWorking && next.status == .running }
            XCTAssertNil(next.errorMessage)
            XCTAssertFalse(next.needsOnboarding)
            XCTAssertEqual(next.activeAdvertisement, advertisement)
            let restartedPasswordCount = await runtime.passwordCount
            let usedDistinctPasswords = await runtime.usedDistinctPasswords
            XCTAssertEqual(restartedPasswordCount, passwordStartsBeforeQuit + 1)
            XCTAssertTrue(usedDistinctPasswords, "A completed owned shutdown must discard the managed password")

            // Explicit Disconnect survives another relaunch and never opens pairing.
            next.stop()
            await next.waitForCurrentOperation()
            XCTAssertFalse(next.connectionDesired)
            XCTAssertNil(next.activeAdvertisement)
            let disconnected = HostController(statePath: state.path, runner: runner, secrets: secrets,
                lifecycle: lifecycle, preferences: defaults, runtime: runtime)
            disconnected.load()
            await disconnected.waitForCurrentOperation()
            XCTAssertEqual(disconnected.status, .stopped)
            XCTAssertFalse(disconnected.connectionDesired)
            XCTAssertNil(disconnected.validInvitation)
            let finalRunning = await runtime.isRunning()
            XCTAssertFalse(finalRunning)
        } catch {
            try? await relaunched?.stopForApplicationTermination()
            try? await host.stopForApplicationTermination()
            throw error
        }
    }

    /// `<agents>/opencode/<version>/opencode` and `current.json` as the host writes them: folders 0700, the
    /// program's SHA-256 in the record.
    private func seedManagedOpenCode(_ binary: URL, agents: URL) throws {
        let manager = FileManager.default
        let folder = agents.appendingPathComponent("opencode/1.18.31", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in [agents, agents.appendingPathComponent("opencode"), folder] {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let program = folder.appendingPathComponent("opencode")
        try manager.copyItem(at: binary, to: program)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let digest = SHA256.hash(data: try Data(contentsOf: program)).map { String(format: "%02x", $0) }.joined()
        let record: [String: Any] = ["version": "1.18.31", "command": program.path, "args": ["acp"], "sha256": digest,
                                     "installedAt": "2026-09-27T00:00:00.000Z", "kind": "binary", "name": "OpenCode", "unverified": false]
        let recordURL = agents.appendingPathComponent("opencode/current.json")
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(35)
        while !condition() {
            guard Date() < deadline else { throw DesktopError.commandFailed("The disposable onboarding check timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func stateObject(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    private func unusedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard found == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return UInt16(bigEndian: address.sin_port)
    }
}

private final class OnboardingMemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var accounts: Set<String> { lock.withLock { Set(values.keys) } }
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func load(account: String) throws -> String? { lock.withLock { values[account] } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
}

private actor RecordingRuntime: OpenCodeRuntimeRunning {
    private let wrapped: ManagedOpenCodeRuntime
    private var passwords: [String] = []

    init(_ wrapped: ManagedOpenCodeRuntime) { self.wrapped = wrapped }

    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL {
        passwords.append(password)
        return try await wrapped.start(directory: directory, password: password, providerEnvironment: providerEnvironment, model: model)
    }

    func stop() async throws { try await wrapped.stop() }
    func isRunning() async -> Bool { await wrapped.isRunning() }
    func endpoint() async -> URL? { await wrapped.endpoint() }

    var passwordCount: Int { passwords.count }
    var usedDistinctPasswords: Bool { Set(passwords).count == passwords.count }
}
