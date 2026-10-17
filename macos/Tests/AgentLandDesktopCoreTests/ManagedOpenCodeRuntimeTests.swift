import Foundation
import Darwin
import XCTest
@testable import AgentLandDesktopCore

/// The managed runtime runs the host's OpenCode (the app bundles none): stand-in programs in a host-made
/// agents folder that exec a fake OpenCode server. Nothing here contacts a real OpenCode, unless opted in.
final class ManagedOpenCodeRuntimeTests: XCTestCase {
    func testWithoutAManagedOpenCodeNothingStarts() async throws {
        let fixture = try AgentsFixture(createAgents: false)
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("storage"))
        do {
            _ = try await runtime.start(directory: workspace.path, password: "example-secret")
            XCTFail("nothing is installed and nothing is bundled")
        } catch let ManagedOpenCodeError.unavailable(reason, short) {
            XCTAssertEqual(reason, "The host has not installed OpenCode.")
            XCTAssertEqual(short, "it isn’t installed")
        }
        let running = await runtime.isRunning()
        let endpoint = await runtime.endpoint()
        XCTAssertFalse(running)
        XCTAssertNil(endpoint)
        var wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "nothing to run")
        let valid = await runtime.hasValidManagedOpenCode()
        XCTAssertFalse(valid, "a start gets one first")

        // The host installs one while nothing runs: a start now would run it.
        _ = try fixture.privateFolder(fixture.agents)
        _ = try fixture.privateFolder(fixture.openCode)
        try fixture.writeRecord(try fixture.installRecord(version: "1.19.0"))
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertTrue(wouldChange)
        let nowValid = await runtime.hasValidManagedOpenCode()
        XCTAssertTrue(nowValid)
    }

    func testReadyRuntimeOwnsChildAndStopsIt() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        let endpoint = try await runtime.start(directory: workspace.path, password: "example-secret")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        let running = await runtime.isRunning()
        let reportedEndpoint = await runtime.endpoint()
        XCTAssertTrue(running)
        XCTAssertEqual(reportedEndpoint, endpoint)
        let options = try await OpenCodeProviderClient(endpoint: endpoint, password: "example-secret").providers(directory: workspace.path)
        XCTAssertEqual(options.first?.id, "anthropic")
        XCTAssertEqual(options.first?.environmentKeys, ["ANTHROPIC_API_KEY"])
        XCTAssertEqual(options.first?.models.first?.id, "claude-test")
        XCTAssertEqual(options.first?.defaultModelID, "claude-test")
        XCTAssertTrue(options.first?.isConnected == true)
        try await runtime.stop()
        let stopped = await runtime.isRunning()
        let clearedEndpoint = await runtime.endpoint()
        XCTAssertFalse(stopped)
        XCTAssertNil(clearedEndpoint)
        let pid = try Int32(String(contentsOf: workspace.appendingPathComponent("server.pid"), encoding: .utf8))!
        XCTAssertEqual(kill(pid, 0), -1, "The child process must exit on stop")
    }

    func testSecondStartDoesNotSilentlyIgnoreNewProviderCredentials() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        do {
            _ = try await runtime.start(directory: workspace.path, password: "secret",
                                        providerEnvironment: ["ANTHROPIC_API_KEY": "next-credential"])
            XCTFail("A second start silently ignored new credentials")
        } catch ManagedOpenCodeError.alreadyRunning { }
        try await runtime.stop()
    }

    func testProviderClientRejectsNonLoopbackAndRedirect() async throws {
        let remote = OpenCodeProviderClient(endpoint: URL(string: "http://example.com:4096")!, password: "secret")
        do { _ = try await remote.providers(directory: "/tmp"); XCTFail("remote origin accepted") } catch { }
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("redirect"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        let endpoint = try await runtime.start(directory: workspace.path, password: "secret")
        do { _ = try await OpenCodeProviderClient(endpoint: endpoint, password: "secret").providers(directory: workspace.path); XCTFail("redirect accepted") } catch { }
        try await runtime.stop()
    }

    func testFailedHealthKillsChild() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("unhealthy"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture, timeout: 1)
        do { _ = try await runtime.start(directory: workspace.path, password: "secret"); XCTFail("unhealthy server accepted") } catch { }
        let running = await runtime.isRunning()
        let endpoint = await runtime.endpoint()
        XCTAssertFalse(running)
        XCTAssertNil(endpoint)
        let pid = try Int32(String(contentsOf: workspace.appendingPathComponent("server.pid"), encoding: .utf8))!
        XCTAssertEqual(kill(pid, 0), -1, "Failed readiness must stop the child")
    }

    func testCancelledStartupStopsChild() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("unhealthy"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture, timeout: 5)
        let start = Task { try await runtime.start(directory: workspace.path, password: "secret") }
        try await Task.sleep(for: .milliseconds(400))
        start.cancel()
        do { _ = try await start.value; XCTFail("cancelled startup returned") } catch { }
        let running = await runtime.isRunning()
        XCTAssertFalse(running)
        let pid = try Int32(String(contentsOf: workspace.appendingPathComponent("server.pid"), encoding: .utf8))!
        XCTAssertEqual(kill(pid, 0), -1, "Cancellation must stop the child")
    }

    func testStopDuringStartupStopsChild() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("unhealthy"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture, timeout: 5)
        let start = Task { try await runtime.start(directory: workspace.path, password: "secret") }
        try await Task.sleep(for: .milliseconds(400))
        try await runtime.stop()
        do { _ = try await start.value; XCTFail("stopped startup returned") } catch { }
        let endpoint = await runtime.endpoint()
        XCTAssertNil(endpoint)
        let pid = try Int32(String(contentsOf: workspace.appendingPathComponent("server.pid"), encoding: .utf8))!
        XCTAssertEqual(kill(pid, 0), -1, "Stop during startup must stop the child")
    }

    func testUnexpectedChildExitClearsReadyEndpoint() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        let pid = try Int32(String(contentsOf: workspace.appendingPathComponent("server.pid"), encoding: .utf8))!
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        for _ in 0..<20 {
            if !(await runtime.isRunning()) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let endpoint = await runtime.endpoint()
        XCTAssertNil(endpoint)
        try await runtime.stop()
    }

    func testLargeStartupOutputStillFindsListenerAndDrainsPipes() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("noisy"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture, timeout: 2)
        let endpoint = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        try await runtime.stop()
    }

    func testStopEscalatesWhenChildIgnoresTermination() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("stubborn"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        let pid = try Int32(String(contentsOf: workspace.appendingPathComponent("server.pid"), encoding: .utf8))!
        try await runtime.stop()
        XCTAssertEqual(kill(pid, 0), -1, "A stubborn child must be killed after the grace period")
    }

    func testStartupFailureRedactsPasswordAndProviderCredential() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("leak"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        do {
            _ = try await runtime.start(directory: workspace.path, password: "server-test-secret",
                                        providerEnvironment: ["ANTHROPIC_API_KEY": "provider-test-secret"])
            XCTFail("failing child accepted")
        } catch {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("server-test-secret"))
            XCTAssertFalse(description.contains("provider-test-secret"))
            XCTAssertTrue(description.contains("[redacted]"))
        }
    }

    func testRejectsProcessControlEnvironmentNames() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("state"))
        for key in ["DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "BUN_AUTH_TOKEN", "OPENCODE_CONFIG", "XDG_CONFIG_HOME", "PATH", "UNRELATED"] {
            do {
                _ = try await runtime.start(directory: workspace.path, password: "secret", providerEnvironment: [key: "value"])
                XCTFail("Accepted \(key)")
            } catch ManagedOpenCodeError.invalidProviderEnvironment { }
        }
    }

    func testProviderCredentialEnvironmentIsIsolatedAndKeepsUsefulPATH() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let oldKey = getenv("OPENAI_API_KEY").map { String(cString: $0) }
        setenv("OPENAI_API_KEY", "owner-key-must-not-import", 1)
        defer {
            if let oldKey { setenv("OPENAI_API_KEY", oldKey, 1) }
            else { unsetenv("OPENAI_API_KEY") }
        }
        let state = fixture.root.appendingPathComponent("state")
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture, storage: state)
        _ = try await runtime.start(directory: workspace.path, password: "secret",
                                    providerEnvironment: ["OPENCODE_API_KEY": "zen-test-key"], model: "opencode/test-model")
        try await runtime.stop()
        let data = try Data(contentsOf: workspace.appendingPathComponent("environment.json"))
        let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(observed["OPENCODE_API_KEY"], "zen-test-key")
        XCTAssertNil(observed["OPENAI_API_KEY"])
        XCTAssertEqual(observed["HOME"], ProcessInfo.processInfo.environment["HOME"])
        XCTAssertEqual(observed["XDG_CONFIG_HOME"], state.appendingPathComponent("config").path)
        XCTAssertEqual(observed["OPENCODE_CONFIG_DIR"], state.appendingPathComponent("config/opencode").path)
        for component in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            XCTAssertTrue((observed["PATH"] ?? "").split(separator: ":").contains(Substring(component)))
        }
        let config = try Data(contentsOf: state.appendingPathComponent("config/opencode/opencode.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "opencode/test-model")
    }

    /// Plain chats' web search: the managed OpenCode runs with Exa's search on, the service the host names to
    /// devices, and a provider's environment cannot change it.
    func testManagedOpenCodeSearchesTheWebWithExa() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = try serving(fakeServer(in: fixture.root), in: fixture)
        for key in ["OPENCODE_ENABLE_EXA", "OPENCODE_WEBSEARCH_PROVIDER"] {
            do {
                _ = try await runtime.start(directory: workspace.path, password: "secret", providerEnvironment: [key: "parallel"])
                XCTFail("A provider's environment set \(key)")
            } catch ManagedOpenCodeError.invalidProviderEnvironment { }
        }
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        try await runtime.stop()
        let data = try Data(contentsOf: workspace.appendingPathComponent("environment.json"))
        let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(observed["OPENCODE_ENABLE_EXA"], "1")
        XCTAssertEqual(observed["OPENCODE_WEBSEARCH_PROVIDER"], "exa")
        XCTAssertEqual(ManagedOpenCodeRuntime.webSearchProvider, "exa")
    }

    /// The real program, copied into a host-made agents folder with its SHA-256 in `current.json`, runs as
    /// the managed OpenCode with disposable state and lists its providers. No prompt is sent.
    func testInstalledOpenCodeWithDisposableState() async throws {
        guard let binary = ProcessInfo.processInfo.environment["AGENTLAND_TEST_MANAGED_OPENCODE"] else {
            throw XCTSkip("Set AGENTLAND_TEST_MANAGED_OPENCODE to opt in to the real OpenCode server test")
        }
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.installCopy(of: URL(fileURLWithPath: binary), version: "1.18.31")
        try fixture.writeRecord(record)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("state"),
                                             startupTimeout: 20)
        let endpoint = try await runtime.start(directory: workspace.path, password: "disposable-test-secret")
        do {
            let providers = try await OpenCodeProviderClient(endpoint: endpoint, password: "disposable-test-secret").providers(directory: workspace.path)
            XCTAssertFalse(providers.isEmpty)
            XCTAssertTrue(providers.contains { !$0.models.isEmpty })
            XCTAssertEqual(providers.first { $0.id == "openai" }?.isConnected, false,
                           "The disposable profile must not import inherited or owner OpenAI credentials")
            // Settings → AI Providers reads every provider with its models.dev variables.
            XCTAssertGreaterThan(providers.count, 20)
            XCTAssertEqual(providers.first { $0.id == "openai" }?.keyVariable, "OPENAI_API_KEY")
            XCTAssertEqual(providers.first { $0.id == "anthropic" }?.keyVariable, "ANTHROPIC_API_KEY")
            XCTAssertGreaterThan(providers.filter { $0.keyVariable != nil }.count, 20)
            let rows = OpenCodeProviderList.rows(catalog: providers, savedKeys: [:], search: "")
            XCTAssertEqual(rows.inUse.count + rows.available.count, providers.count)
        } catch {
            try await runtime.stop()
            throw error
        }
        try await runtime.stop()
        let cleared = await runtime.endpoint()
        XCTAssertNil(cleared)
    }

    // MARK: The host's managed OpenCode

    /// The real program runs as the managed OpenCode with disposable state, and says so. No prompt is sent.
    func testTheRealOpenCodeRunsAsTheHostsManagedOne() async throws {
        guard let binary = ProcessInfo.processInfo.environment["AGENTLAND_TEST_MANAGED_OPENCODE"] else {
            throw XCTSkip("Set AGENTLAND_TEST_MANAGED_OPENCODE to opt in to the real OpenCode server test")
        }
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        var record = try fixture.installCopy(of: URL(fileURLWithPath: binary), version: "1.18.31")
        record = ManagedAgentRecord(version: record.version, command: "opencode", args: ["acp"], sha256: record.sha256,
                                    installedAt: "2026-09-26T20:00:00Z")
        try fixture.writeRecord(record)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("state"),
                                             startupTimeout: 20)
        let endpoint = try await runtime.start(directory: workspace.path, password: "disposable-test-secret")
        do {
            let report = await runtime.report()
            XCTAssertEqual(report, OpenCodeRuntimeReport(source: .managed(record), version: "1.18.31"))
            let providers = try await OpenCodeProviderClient(endpoint: endpoint, password: "disposable-test-secret").providers(directory: workspace.path)
            XCTAssertFalse(providers.isEmpty)
        } catch {
            try await runtime.stop()
            throw error
        }
        try await runtime.stop()
    }

    func testTheHostsOpenCodeRunsWhenItPassesItsChecks() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        let record = try fixture.installRecord(version: "1.19.0", script: launches.script("managed", then: server))
        try fixture.writeRecord(record)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("storage"))
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        let report = await runtime.report()
        XCTAssertEqual(report, OpenCodeRuntimeReport(source: .managed(record), version: "test"))
        XCTAssertEqual(launches.names, ["managed"])
        let wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "it runs what the host installed")
        let pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [])
        try await runtime.stop()
        let stopped = await runtime.report()
        XCTAssertNil(stopped)
    }

    /// The current version exits: the previous one starts at once. The failed version is remembered and the
    /// host hears about it; it is not tried again as the current or as the previous version while the host
    /// keeps it, and nothing asks for a restart again and again.
    func testAVersionThatDoesNotStartFallsBackToThePreviousOneAndTheHostHearsOfIt() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        let previous = try fixture.installRecord(version: "1.18.32", script: launches.script("1.18.32", then: server),
                                                 installedAt: "2026-09-26T20:00:00Z")
        let broken = try fixture.installRecord(version: "1.19.0", script: launches.script("1.19.0", then: nil),
                                               installedAt: "2026-09-27T20:00:00Z")
        try fixture.writeRecords(current: broken, previous: previous)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let storage = fixture.root.appendingPathComponent("storage")
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage)

        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.0", "1.18.32"], "the previous version starts at once for this start")
        let report = await runtime.report()
        let fellBack = try XCTUnwrap(report)
        XCTAssertEqual(fellBack.source, .previous(previous))
        XCTAssertTrue(fellBack.fallbackReason?.hasPrefix("OpenCode 1.19.0 didn’t start. AgentLand runs the previous version, 1.18.32. OpenCode could not start") == true,
                      fellBack.fallbackReason ?? "no reason")
        let remembered = await runtime.readFailure()
        XCTAssertEqual(remembered?.record, broken)
        var pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [OpenCodeFailureReport(version: "1.19.0", reason: "It stopped before it was ready.")])
        var wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "the version that failed is no reason to restart")
        await runtime.noteFailureReported(pending[0])
        pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [], "reported once")

        // Before the host goes back, the next start skips it: no second wait for a program that does not start.
        try await runtime.stop()
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.0", "1.18.32", "1.18.32"])
        let skipped = await runtime.report()
        XCTAssertEqual(skipped?.fallbackReason, "OpenCode 1.19.0 didn’t start last time. AgentLand runs the previous version, 1.18.32.")

        // The host went back: 1.18.32 is current and 1.19.0 its previous version. The same program runs, so
        // nothing restarts, and the version that failed is no fallback.
        try fixture.writeRecords(current: previous, previous: broken)
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "the program running is the host's current one now")
        try await runtime.stop()
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names.last, "1.18.32")
        let current = await runtime.report()
        XCTAssertEqual(current, OpenCodeRuntimeReport(source: .managed(previous), version: "test"))
        // The next launch keeps skipping it: the failure file keeps it while the host keeps it.
        let relaunched = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage)
        let keptFailure = await relaunched.readFailure()
        XCTAssertEqual(keptFailure?.record, broken)

        // The host installs another version: it is wanted, the next start runs it, and the old failure goes.
        let fixed = try fixture.installRecord(version: "1.19.1", script: launches.script("1.19.1", then: server),
                                              installedAt: "2026-09-28T20:00:00Z")
        try fixture.writeRecords(current: fixed, previous: previous)
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertTrue(wouldChange)
        try await runtime.stop()
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names.last, "1.19.1")
        let upgraded = await runtime.report()
        XCTAssertEqual(upgraded?.source, .managed(fixed))
        let forgotten = await runtime.readFailure()
        XCTAssertNil(forgotten, "the host keeps 1.19.0 no more")
        try await runtime.stop()
    }

    func testAVersionThatHangsIsStoppedBeforeThePreviousOneStarts() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        let pidFile = fixture.root.appendingPathComponent("managed.pid")
        let hanging = "#!/bin/sh\necho 1.19.0 >> '\(launches.log.path)'\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 60\n"
        let previous = try fixture.installRecord(version: "1.18.32", script: launches.script("1.18.32", then: server))
        try fixture.writeRecords(current: try fixture.installRecord(version: "1.19.0", script: hanging), previous: previous)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("storage"),
                                             startupTimeout: 1)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.0", "1.18.32"])
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "the new version was stopped before the previous one started")
        let report = await runtime.report()
        XCTAssertEqual(report?.source, .previous(previous))
        try await runtime.stop()
    }

    /// A version that does not answer in time is no verdict on the program at first (a first start on real
    /// data may migrate it): the next start tries it once more; a second timeout counts, like an exit.
    func testAVersionThatIsTooSlowGetsOneMoreStartThenCounts() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        // The same program and record hang while `slow` exists, and serve once it is gone.
        let slow = fixture.root.appendingPathComponent("slow")
        try Data().write(to: slow)
        let script = "#!/bin/sh\necho 1.19.1 >> '\(launches.log.path)'\nif [ -e '\(slow.path)' ]; then exec /bin/sleep 60; fi\nexec '\(server.path)' \"$@\"\n"
        let record = try fixture.installRecord(version: "1.19.1", script: script)
        let previous = try fixture.installRecord(version: "1.18.32", script: launches.script("1.18.32", then: server))
        try fixture.writeRecords(current: record, previous: previous)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let storage = fixture.root.appendingPathComponent("storage")
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage, startupTimeout: 1)

        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.1", "1.18.32"], "the previous version starts at once for this start")
        var report = await runtime.report()
        XCTAssertEqual(report?.source, .previous(previous))
        XCTAssertTrue(report?.fallbackReason?.hasPrefix("OpenCode 1.19.1 didn’t start in time. AgentLand runs the previous version, 1.18.32. AgentLand tries 1.19.1 once more when OpenCode next restarts.") == true,
                      report?.fallbackReason ?? "no reason")
        var remembered = await runtime.readFailure()
        XCTAssertNil(remembered, "a first timeout is not written to the failure file")
        var wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertTrue(wouldChange, "it gets one more start")

        try await runtime.stop()
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.1", "1.18.32", "1.19.1", "1.18.32"])
        report = await runtime.report()
        XCTAssertTrue(report?.fallbackReason?.hasPrefix("OpenCode 1.19.1 didn’t start in time again. AgentLand runs the previous version, 1.18.32. OpenCode did not become ready") == true,
                      report?.fallbackReason ?? "no reason")
        remembered = await runtime.readFailure()
        XCTAssertEqual(remembered?.record, record, "a second timeout counts")
        let pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [OpenCodeFailureReport(version: "1.19.1", reason: "It did not answer within 1 second, twice.")])
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "no restart again and again")

        // Later starts run the previous version without waiting.
        try await runtime.stop()
        try FileManager.default.removeItem(at: slow)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names.last, "1.18.32")
        XCTAssertEqual(launches.names.count, 5)

        // Try Again forgets it: the next start tries it, and this time it answers.
        await runtime.forgetFailures()
        try await runtime.stop()
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names.last, "1.19.1")
        report = await runtime.report()
        XCTAssertEqual(report, OpenCodeRuntimeReport(source: .managed(record), version: "test"))
        try await runtime.stop()
    }

    func testNothingIsRememberedWhenThePreviousVersionDoesNotStartEither() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        try fixture.writeRecords(current: try fixture.installRecord(version: "1.19.0", script: launches.script("1.19.0", then: nil)),
                                 previous: try fixture.installRecord(version: "1.18.32", script: launches.script("1.18.32", then: nil)))
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("storage"))
        do {
            _ = try await runtime.start(directory: workspace.path, password: "secret")
            XCTFail("neither version starts")
        } catch let ManagedOpenCodeError.unavailable(reason, short) {
            XCTAssertTrue(reason.hasPrefix("OpenCode 1.19.0 didn’t start. The previous version, 1.18.32, didn’t start either."), reason)
            XCTAssertEqual(short, "it didn’t start")
        }
        XCTAssertEqual(launches.names, ["1.19.0", "1.18.32"])
        let remembered = await runtime.readFailure()
        XCTAssertNil(remembered, "the fault is not shown to be the new version's")
        let pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [])
        let running = await runtime.isRunning()
        XCTAssertFalse(running)
        let wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "a restart would try the same programs again")
        // A later start (Connect, the next launch, Try Again) tries again.
        do { _ = try await runtime.start(directory: workspace.path, password: "secret"); XCTFail("still broken") } catch {}
        XCTAssertEqual(launches.names, ["1.19.0", "1.18.32", "1.19.0", "1.18.32"])
    }

    func testWithoutAPreviousVersionAVersionThatDoesNotStartLeavesNoOpenCode() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        try fixture.writeRecord(try fixture.installRecord(version: "1.19.0", script: launches.script("1.19.0", then: nil)))
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("storage"))
        do {
            _ = try await runtime.start(directory: workspace.path, password: "secret")
            XCTFail("nothing to fall back on")
        } catch let ManagedOpenCodeError.unavailable(reason, short) {
            XCTAssertTrue(reason.hasPrefix("OpenCode 1.19.0 didn’t start. OpenCode could not start"), reason)
            XCTAssertEqual(short, "it didn’t start")
        }
        let remembered = await runtime.readFailure()
        XCTAssertNil(remembered)
        var wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "the version that did not start is no reason to restart")

        // The host installs another version while nothing runs: a start would run it.
        try fixture.writeRecords(current: try fixture.installRecord(version: "1.19.1", script: launches.script("1.19.1", then: server)),
                                 previous: nil)
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertTrue(wouldChange)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.0", "1.19.1"])
        try await runtime.stop()
    }

    func testAHostVersionThatFailsItsChecksIsNoReasonToRestart() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        let running = try fixture.installRecord(version: "1.18.32", script: launches.script("1.18.32", then: server))
        try fixture.writeRecord(running)
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: fixture.root.appendingPathComponent("storage"))
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        let program = try fixture.install(version: "1.19.0", script: launches.script("1.19.0", then: server))
        try fixture.writeRecords(current: ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: AgentsFixture.anyDigest),
                                 previous: running)
        var wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "a program that does not match its record never replaces the running one")
        let next = ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: try fixture.digest(program))
        try fixture.writeRecords(current: next, previous: running)
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertTrue(wouldChange)
        try await runtime.stop()
        wouldChange = await runtime.restartWouldChangeBinary()
        XCTAssertFalse(wouldChange, "nothing runs, so nothing restarts")
    }

    // MARK: OpenCode's data across versions

    /// A version that has never started migrates the data and exits: the previous version gets the data as it
    /// was, and what the new one left is kept aside.
    func testThePreviousVersionGetsTheDataAsItWasBeforeTheNewOnesFirstStart() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        let storage = fixture.root.appendingPathComponent("storage")
        let data = storage.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: data.appendingPathComponent("chat.db"))
        let seen = fixture.root.appendingPathComponent("seen-by-previous")
        let migrating = "#!/bin/sh\necho 1.19.0 >> '\(launches.log.path)'\nprintf migrated > \"$XDG_DATA_HOME/chat.db\"\nexit 1\n"
        let reading = "#!/bin/sh\necho 1.18.32 >> '\(launches.log.path)'\ncat \"$XDG_DATA_HOME/chat.db\" > '\(seen.path)'\nexec '\(server.path)' \"$@\"\n"
        try fixture.writeRecords(current: try fixture.installRecord(version: "1.19.0", script: migrating),
                                 previous: try fixture.installRecord(version: "1.18.32", script: reading))
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.0", "1.18.32"])
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), "old", "the previous version read the data as it was")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("chat.db"), encoding: .utf8), "old")
        let aside = storage.appendingPathComponent("opencode-data-after-failed-1.19.0/chat.db")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "migrated", "what the new version left is kept aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("opencode-data-before-1.19.0").path),
                       "its snapshot went back into place")
        let guardian = OpenCodeDataGuard(storageRoot: storage)
        XCTAssertTrue(guardian.hasStarted("1.18.32"))
        XCTAssertFalse(guardian.hasStarted("1.19.0"))
        try await runtime.stop()
    }

    /// A version that started on this Mac before is never rolled back: its data has the owner's newer work.
    func testAVersionThatStartedBeforeKeepsItsDataWhenItFailsLater() async throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let launches = Launches(fixture.root)
        let server = try fakeServer(in: fixture.root)
        let storage = fixture.root.appendingPathComponent("storage")
        let fails = fixture.root.appendingPathComponent("fails")
        let script = "#!/bin/sh\necho 1.19.0 >> '\(launches.log.path)'\necho work >> \"$XDG_DATA_HOME/touched\"\nif [ -e '\(fails.path)' ]; then exit 1; fi\nexec '\(server.path)' \"$@\"\n"
        try fixture.writeRecords(current: try fixture.installRecord(version: "1.19.0", script: script),
                                 previous: try fixture.installRecord(version: "1.18.32", script: launches.script("1.18.32", then: server)))
        let workspace = try fixture.privateFolder(fixture.root.appendingPathComponent("workspace"))
        let runtime = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertTrue(OpenCodeDataGuard(storageRoot: storage).hasStarted("1.19.0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appendingPathComponent("opencode-data-before-1.19.0").path),
                      "the snapshot from before its first start stays")
        try await runtime.stop()

        try Data().write(to: fails)
        _ = try await runtime.start(directory: workspace.path, password: "secret")
        XCTAssertEqual(launches.names, ["1.19.0", "1.19.0", "1.18.32"])
        XCTAssertEqual(try String(contentsOf: storage.appendingPathComponent("data/touched"), encoding: .utf8), "work\nwork\n",
                       "the data is not rolled back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("opencode-data-after-failed-1.19.0").path))
        try await runtime.stop()
    }

    // MARK: Helpers

    /// A runtime whose host has one managed OpenCode, a stand-in in the agents folder that runs `server`.
    private func serving(_ server: URL, in fixture: AgentsFixture, timeout: TimeInterval = 30,
                         storage: URL? = nil) throws -> ManagedOpenCodeRuntime {
        let record = try fixture.installRecord(version: "1.19.0", script: "#!/bin/sh\nexec '\(server.path)' \"$@\"\n")
        try fixture.writeRecord(record)
        return ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage ?? fixture.root.appendingPathComponent("storage"),
                                      startupTimeout: timeout)
    }

    private func fakeServer(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fake-opencode")
        let script = #"""
        #!/usr/bin/python3
        import base64, http.server, json, os, signal, sys
        port = int(sys.argv[sys.argv.index('--port') + 1])
        secret = os.environ['OPENCODE_SERVER_PASSWORD']
        if os.getcwd().endswith('leak'):
            print('password=' + secret + ' token=' + os.environ['ANTHROPIC_API_KEY'], file=sys.stderr, flush=True)
            sys.exit(1)
        if os.getcwd().endswith('noisy'):
            print('x' * 131072, file=sys.stderr, flush=True)
        if os.getcwd().endswith('stubborn'):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        envkeys = ('OPENCODE_API_KEY', 'OPENAI_API_KEY', 'HOME', 'XDG_CONFIG_HOME', 'OPENCODE_CONFIG_DIR', 'PATH',
                   'OPENCODE_ENABLE_EXA', 'OPENCODE_WEBSEARCH_PROVIDER')
        with open('environment.json', 'w') as out:
            json.dump({key: os.environ[key] for key in envkeys if key in os.environ}, out)
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                good = self.headers.get('Authorization') == 'Basic ' + base64.b64encode(('opencode:' + secret).encode()).decode()
                if not good:
                    self.send_response(401); self.end_headers(); return
                if self.path == '/global/health':
                    body = {'healthy': not os.getcwd().endswith('unhealthy'), 'version': 'test'}
                elif self.path == '/provider':
                    if os.getcwd().endswith('redirect'):
                        self.send_response(302); self.send_header('Location', 'http://example.com/steal'); self.end_headers(); return
                    if os.path.realpath(self.headers.get('X-OpenCode-Directory', '')) != os.getcwd():
                        self.send_response(400); self.end_headers(); return
                    body = {'all':[{'id':'anthropic','name':'Anthropic','env':['ANTHROPIC_API_KEY'],'models':{'claude-test':{'id':'claude-test','name':'Claude Test'}}}], 'default':{'anthropic':'claude-test'}, 'connected':['anthropic']}
                else:
                    self.send_response(404); self.end_headers(); return
                data = json.dumps(body).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        server = http.server.HTTPServer(('127.0.0.1', port), Handler)
        open('server.pid', 'w').write(str(os.getpid()))
        print('opencode server listening on http://127.0.0.1:' + str(port), flush=True)
        server.serve_forever()
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// Which program each start ran: every stand-in adds its name to `launches.log`, then runs the fake
/// server (or exits 1 without one).
private struct Launches {
    let root: URL
    let log: URL

    init(_ root: URL) {
        self.root = root
        log = root.appendingPathComponent("launches.log")
    }

    var names: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func script(_ name: String, then server: URL?) -> String {
        "#!/bin/sh\necho \(name) >> '\(log.path)'\n" + (server.map { "exec '\($0.path)' \"$@\"\n" } ?? "exit 1\n")
    }
}

extension AgentsFixture {
    /// Copies a real OpenCode into `opencode/<version>/opencode` and returns its record with the absolute
    /// command and the copy's SHA-256.
    func installCopy(of binary: URL, version: String) throws -> ManagedAgentRecord {
        let folder = try privateFolder(openCode.appendingPathComponent(version))
        let program = folder.appendingPathComponent("opencode")
        try FileManager.default.copyItem(at: binary, to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        return ManagedAgentRecord(version: version, command: program.path, args: ["acp"], sha256: try digest(program),
                                  installedAt: "2026-09-26T20:00:00Z")
    }
}
