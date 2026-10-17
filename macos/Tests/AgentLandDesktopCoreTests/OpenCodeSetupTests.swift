import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The app bundles no OpenCode: a start gets the host's managed one first when it has none (`install-opencode`,
/// with its progress shown), starts the host without OpenCode when none is available (with why and Try
/// Again), and tells the host about a version that did not start. The runtime, the command, the host
/// process and the host's catalog are fakes.
final class OpenCodeSetupTests: XCTestCase {
    /// The app's runtime answers `HostController` with its own methods, not the protocol's defaults (which
    /// say "valid" and "nothing to report").
    func testTheAppsRuntimeAnswersThroughTheProtocol() async throws {
        let fixture = try AgentsFixture(createAgents: false)
        defer { fixture.cleanUp() }
        let storage = fixture.root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let failure = """
        {"failedAt": "2026-09-27T00:00:00Z", "reason": "It stopped before it was ready.", "reported": false,
         "record": {"version": "1.19.0", "command": "/nowhere/opencode", "sha256": "\(AgentsFixture.anyDigest)"}}
        """
        try Data(failure.utf8).write(to: storage.appendingPathComponent("managed-opencode-failure.json"))
        let runtime: any OpenCodeRuntimeRunning = ManagedOpenCodeRuntime(agentsFolder: fixture.agents, storageRoot: storage)
        let valid = await runtime.hasValidManagedOpenCode()
        XCTAssertFalse(valid, "nothing is installed: a start gets OpenCode first")
        let report = OpenCodeFailureReport(version: "1.19.0", reason: "It stopped before it was ready.")
        var pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [report])
        await runtime.noteFailureReported(report)
        pending = await runtime.pendingFailureReports()
        XCTAssertEqual(pending, [])
        await runtime.forgetFailures()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("managed-opencode-failure.json").path))
    }

    /// The owner's Mac already has a valid managed OpenCode: it starts as before, and nothing downloads.
    @MainActor
    func testNothingDownloadsWhenAValidManagedOpenCodeExists() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let installer = FakeOpenCodeInstaller(outcome: .ready(version: "1.18.32"))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), installer: installer)
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(installer.installs, 0)
        let starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1)
        XCTAssertNil(host.openCodeInstall)
        XCTAssertNil(host.openCodeUnavailable)
        XCTAssertEqual(host.openCodeReport?.version, "1.18.31")
        await host.stopAndWait()
    }

    /// Without a valid managed OpenCode, the start gets one before OpenCode and the host start (the host's
    /// command takes the state only while no host serves it), showing "Getting OpenCode…" with the version
    /// and the download's share.
    @MainActor
    func testAStartWithoutOpenCodeGetsItFirstAndShowsItsProgress() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        await fixture.runtime.setValid(false)
        let installer = FakeOpenCodeInstaller(events: [.registry, .downloading(version: "1.18.32", received: 45, total: 100)],
                                              outcome: .ready(version: "1.18.32"))
        installer.hold(true)
        let runtime = fixture.runtime
        installer.whenInstalling { await runtime.setValid(true) }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), installer: installer)
        try await waitForCondition("the download's progress") { host.openCodeInstall?.fraction != nil }
        XCTAssertEqual(host.openCodeInstall?.title, "Getting OpenCode 1.18.32…")
        XCTAssertEqual(host.openCodeInstall?.fraction, 0.45)
        XCTAssertEqual(host.openCodeInstall?.menuTitle, "Getting OpenCode 1.18.32… 45%")
        XCTAssertEqual(host.setupProgress, "Getting OpenCode 1.18.32…")
        XCTAssertEqual(host.status, .starting)
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 0, "OpenCode starts once it is there")
        XCTAssertEqual(fixture.processes.count, 0, "the host starts after the command")
        XCTAssertEqual(installer.states, [fixture.state.path])

        installer.hold(false)
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(fixture.processes.count, 1)
        XCTAssertNil(host.openCodeInstall)
        XCTAssertNil(host.openCodeUnavailable)
        XCTAssertNil(host.setupProgress)
        XCTAssertEqual(installer.installs, 1)
        await host.stopAndWait()
    }

    /// Offline at the first start: the host still starts, so devices keep terminals and files; the reason
    /// shows plainly, nothing restarts on its own, and Try Again gets OpenCode and starts it.
    @MainActor
    func testOfflineLeavesTheHostRunningWithoutOpenCodeUntilTryAgain() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        await fixture.runtime.setValid(false)
        await fixture.runtime.setUnavailable("The host has not installed OpenCode.")
        let installer = FakeOpenCodeInstaller(events: [.registry], outcome: .failed(OpenCodeInstallFailure(
            code: "offline", detail: "The registry could not be reached.")))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), installer: installer)
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(fixture.processes.count, 1, "the host runs")
        XCTAssertNil(host.errorMessage, "the host itself is fine")
        XCTAssertEqual(fixture.processes.first?.command.arguments.contains("--websearch-provider"), false,
                       "without the app's OpenCode the host does not know the search service")
        let unavailable = try XCTUnwrap(host.openCodeUnavailable)
        XCTAssertEqual(unavailable.message, "AgentLand needs a network connection to get OpenCode the first time.")
        XCTAssertTrue(unavailable.offline)
        XCTAssertEqual(MenuBarControls.unavailableText(unavailable), "OpenCode isn’t available: no network connection")
        XCTAssertNil(host.openCodeReport)
        XCTAssertNil(host.openCodeInstall)
        XCTAssertEqual(fixture.runner.configuredURLs, ["http://127.0.0.1:4197"], "the host keeps the OpenCode address it had")

        // A host that runs without OpenCode is not restarted for it.
        host.startMonitoring()
        try await Task.sleep(for: .milliseconds(300))
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(fixture.processes.count, 1)
        XCTAssertEqual(installer.installs, 1)

        // Back online: Try Again stops the host, gets OpenCode, and starts both.
        let runtime = fixture.runtime
        installer.answer(events: [.registry, .checking(version: "1.18.32")], outcome: .ready(version: "1.18.32"))
        installer.whenInstalling {
            await runtime.setValid(true)
            await runtime.setUnavailable(nil)
        }
        host.retryOpenCode()
        try await waitForCondition("Try Again") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(installer.installs, 2)
        XCTAssertEqual(fixture.processes.count, 2)
        XCTAssertFalse(fixture.processes[0].isRunning, "the host was stopped for the command")
        XCTAssertNil(host.openCodeUnavailable)
        XCTAssertEqual(host.openCodeReport?.version, "1.18.31")
        let forgotten = await fixture.runtime.forgotten
        XCTAssertEqual(forgotten, 1, "Try Again tries every version the host keeps again")
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2)
        await host.stopAndWait()
        XCTAssertNil(host.openCodeUnavailable, "nothing runs, so nothing is said")
    }

    /// First launch without OpenCode (owner, 2026-10-17: setup shows Claude Code and Codex, not API keys): once the host
    /// runs, setup moves on to Claude Code and Codex, whose sign-ins come from the host, never from OpenCode; Settings and
    /// the menu keep saying why OpenCode is missing, and Try Again comes back to the same step once it runs.
    @MainActor
    func testOnboardingShowsTheAgentsStepWithoutOpenCode() async throws {
        let fixture = try RestartFixture(withState: false)
        defer { fixture.cleanUp() }
        await fixture.runtime.setValid(false)
        await fixture.runtime.setUnavailable("The host has not installed OpenCode.")
        let installer = FakeOpenCodeInstaller(outcome: .failed(OpenCodeInstallFailure(code: "offline", detail: "")))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), installer: installer,
                                                   connect: false)
        XCTAssertTrue(host.needsOnboarding)
        host.start()
        XCTAssertEqual(host.onboardingStage, .preparing)
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(host.onboardingStage, .agents, "Chat's sign-ins don't need OpenCode")
        XCTAssertEqual(host.openCodeUnavailable?.message, "AgentLand needs a network connection to get OpenCode the first time.")

        let runtime = fixture.runtime
        installer.answer(events: [], outcome: .ready(version: "1.18.32"))
        installer.whenInstalling {
            await runtime.setValid(true)
            await runtime.setUnavailable(nil)
        }
        host.retryOpenCode()
        try await waitForCondition("Try Again") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(host.onboardingStage, .agents)
        XCTAssertNil(host.openCodeUnavailable)
        await host.stopAndWait()
    }

    /// With OpenCode running, the same step follows the automatic setup; Continue goes on to pairing without finishing
    /// setup, which the pairing step finishes (a device pairs, or Pair Later).
    @MainActor
    func testOnboardingShowsTheAgentsStepWithOpenCodeAndContinuesToPairing() async throws {
        let fixture = try RestartFixture(withState: false)
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), connect: false)
        host.continueToPairing()
        XCTAssertEqual(host.onboardingStage, .folder, "only the agents step goes on to pairing")
        host.start()
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertNil(host.openCodeUnavailable)
        XCTAssertEqual(host.onboardingStage, .agents)
        XCTAssertTrue(host.needsOnboarding)

        host.continueToPairing()
        XCTAssertEqual(host.onboardingStage, .ready)
        XCTAssertTrue(host.needsOnboarding, "setup finishes in the pairing step")
        host.finishOnboarding()
        XCTAssertFalse(host.needsOnboarding)
        XCTAssertEqual(host.onboardingStage, .ready)
        await host.stopAndWait()
    }

    /// Offline at the first launch, the owner can go on with files and terminals.
    @MainActor
    func testOnboardingCanFinishWithoutOpenCode() async throws {
        let fixture = try RestartFixture(withState: false)
        defer { fixture.cleanUp() }
        await fixture.runtime.setValid(false)
        await fixture.runtime.setUnavailable("The host has not installed OpenCode.")
        let installer = FakeOpenCodeInstaller(outcome: .failed(OpenCodeInstallFailure(code: "offline", detail: "")))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), installer: installer,
                                                   connect: false)
        host.start()
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        host.finishOnboarding()
        XCTAssertFalse(host.needsOnboarding)
        XCTAssertEqual(host.onboardingStage, .ready)
        XCTAssertNotNil(host.openCodeUnavailable, "Settings and the menu keep saying why")
        await host.stopAndWait()
    }

    /// OpenCode was not available; the host installs one later (its own start installs a missing one): the
    /// idle rule starts it, the way a new version is started.
    @MainActor
    func testOpenCodeStartsOnItsOwnOnceTheHostInstallsOne() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        await fixture.runtime.setUnavailable("OpenCode 1.18.32 didn’t start.")
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 900))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60),
                                                   agents: agents, agentsPollInterval: .milliseconds(30))
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(host.openCodeUnavailable, OpenCodeUnavailability(message: "OpenCode 1.18.32 didn’t start.", shortReason: "it didn’t start"))
        try await waitForCondition("a few polls") { agents.requests >= 3 }
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1, "the same programs are not tried again on their own")

        await fixture.runtime.setUnavailable(nil)
        await fixture.runtime.installNewVersion("1.18.33")
        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        XCTAssertNil(host.openCodeUnavailable)
        XCTAssertEqual(host.openCodeReport?.version, "1.18.33")
        XCTAssertTrue(host.openCodeActivity?.hasSuffix(" to run OpenCode 1.18.33 from the host, after 15 minutes with nothing running.") == true,
                      host.openCodeActivity ?? "no activity")
        let asked = agents.requests
        try await waitForCondition("more polls") { agents.requests >= asked + 3 }
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2)
        await host.stopAndWait()
    }

    /// A host busy with another change of OpenCode (409 `agent_busy`) takes the report on a later try while it
    /// runs, without waiting for the next start; the tries stop with the host.
    @MainActor
    func testAReportTheHostWasTooBusyForIsSentAgainWhileItRuns() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let report = OpenCodeFailureReport(version: "1.18.33", reason: "It stopped before it was ready.")
        await fixture.runtime.setPendingReports([report])
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: false, idleForSeconds: 0))
        agents.answerReports(.failure(.server(code: "agent_busy", message: "OpenCode is changing.")))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), agents: agents,
                                                   failureReportRetry: .milliseconds(100))
        try await waitForCondition("the first report") { agents.reports == [report] }
        agents.answerReports(.success(OpenCodeFailureAnswer(rolledBack: true, current: "1.18.32")))
        try await waitForCondition("the report taken") { await fixture.runtime.reportsWaiting.isEmpty }
        XCTAssertEqual(agents.reports, [report, report], "sent again once, while the host ran")

        // A host that never takes it is asked a bounded number of times, then the report waits.
        await fixture.runtime.setPendingReports([report])
        agents.answerReports(.failure(.server(code: "agent_busy", message: "OpenCode is changing.")))
        await host.stopAndWait()
        host.start()
        try await waitForCondition("every try") { agents.reports.count == 2 + HostController.failureReportAttempts }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(agents.reports.count, 2 + HostController.failureReportAttempts)
        let pending = await fixture.runtime.reportsWaiting
        XCTAssertEqual(pending, [report], "it waits for the next start")
        await host.stopAndWait()
    }

    /// A version that did not start is reported once the host runs, so the host goes back to the version it
    /// keeps and records why; a report the host did not take is sent again at the next start.
    @MainActor
    func testAVersionThatDidNotStartIsReportedOnceTheHostRuns() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let report = OpenCodeFailureReport(version: "1.18.33", reason: "It stopped before it was ready.")
        await fixture.runtime.setPendingReports([report])
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: false, idleForSeconds: 0))
        agents.answerReports(.failure(.unexpectedStatus(503)))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), agents: agents)
        try await waitForCondition("the report") { agents.reports == [report] }
        try await Task.sleep(for: .milliseconds(100))
        var pending = await fixture.runtime.reportsWaiting
        XCTAssertEqual(pending, [report], "the host did not take it")

        agents.answerReports(.success(OpenCodeFailureAnswer(rolledBack: true, current: "1.18.32")))
        await host.stopAndWait()
        host.start()
        try await waitForCondition("the report again") { agents.reports == [report, report] }
        try await waitForCondition("the report taken") { await fixture.runtime.reportsWaiting.isEmpty }

        // Once taken, it is not sent again.
        await host.stopAndWait()
        host.start()
        try await waitForCondition("the next start") { host.status == .running && !host.isWorking }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(agents.reports.count, 2)

        // A host without the route never takes it: it is not sent again.
        await fixture.runtime.setPendingReports([report])
        agents.answerReports(.failure(.server(code: "not_found", message: "No such route.")))
        await host.stopAndWait()
        host.start()
        try await waitForCondition("the last report") { await fixture.runtime.reportsWaiting.isEmpty }
        XCTAssertEqual(agents.reports.count, 3)
        pending = await fixture.runtime.reportsWaiting
        XCTAssertEqual(pending, [])
        await host.stopAndWait()
    }
}
