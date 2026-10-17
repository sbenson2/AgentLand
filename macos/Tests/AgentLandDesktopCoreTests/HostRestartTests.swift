import Foundation
import XCTest
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The host and the managed runtime are started again when they exit on their own while the
/// connection is wanted, with a bounded backoff; nothing here launches a real process.
final class HostRestartTests: XCTestCase {
    func testBackoffWaitsLongerEachTimeAndGivesUpPastTheLimit() {
        var backoff = RestartBackoff(delays: [1, 2, 4], limit: 3, window: 600)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(backoff.recordFailure(at: start), .retry(after: 1))
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(5)), .retry(after: 2))
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(10)), .retry(after: 4))
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(15)), .giveUp(failures: 4))
        backoff.reset()
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(20)), .retry(after: 1))
    }

    func testFailuresOutsideTheWindowNoLongerCount() {
        var backoff = RestartBackoff(delays: [1, 30], limit: 2, window: 600)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(backoff.recordFailure(at: start), .retry(after: 1))
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(60)), .retry(after: 30), "the last delay repeats")
        // A crash a day is restarted every time.
        XCTAssertEqual(backoff.recordFailure(at: start.addingTimeInterval(86_400)), .retry(after: 1))
        XCTAssertEqual(backoff.failures.count, 1)
        XCTAssertEqual(RestartBackoff().windowDescription, "10 minutes")
        XCTAssertEqual(RestartBackoff(window: 90).windowDescription, "90 seconds")
    }

    func testTheDefaultBackoffWaitsUpToSixteenSecondsAndStopsAtTheSixthFailure() {
        var backoff = RestartBackoff()
        let start = Date(timeIntervalSince1970: 1_000)
        let decisions = (0..<6).map { backoff.recordFailure(at: start.addingTimeInterval(Double($0) * 10)) }
        XCTAssertEqual(decisions, [.retry(after: 1), .retry(after: 2), .retry(after: 4), .retry(after: 8), .retry(after: 16),
                                   .giveUp(failures: 6)], "as the README says; no delay is listed that is never used")
        XCTAssertEqual(backoff.delays.count, backoff.limit)
    }

    @MainActor
    func testAnExitedHostIsStartedAgainAloneWithTheSameRuntime() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        XCTAssertEqual(fixture.processes.count, 1)
        host.startMonitoring()

        fixture.processes.last?.exit()
        try await waitUntil { fixture.processes.count == 2 && host.status == .running && !host.isWorking }
        let runtimeStarts = await fixture.runtime.starts
        XCTAssertEqual(runtimeStarts, 1, "OpenCode keeps running, and with it its sessions")
        XCTAssertTrue(host.connectionDesired)
        XCTAssertNil(host.errorMessage)
        let first = try XCTUnwrap(fixture.processes.first?.command)
        let second = try XCTUnwrap(fixture.processes.last?.command)
        XCTAssertEqual(first.arguments, second.arguments)
        // The app runs the OpenCode the host uses, with Exa's search, so the host names the service to devices.
        let provider = try XCTUnwrap(first.arguments.firstIndex(of: "--websearch-provider"))
        XCTAssertEqual(first.arguments[provider + 1], ManagedOpenCodeRuntime.webSearchProvider)
        XCTAssertEqual(first.environment["AGENTLAND_OPENCODE_PASSWORD"], second.environment["AGENTLAND_OPENCODE_PASSWORD"])
        XCTAssertNotEqual(first.environment["AGENTLAND_LOCAL_SESSION_TOKEN"], second.environment["AGENTLAND_LOCAL_SESSION_TOKEN"],
                          "a restarted host has a new local session")
        XCTAssertEqual(fixture.runner.configuredURLs.count, 1, "a host-only restart leaves the configuration alone")
        await host.stopAndWait()
    }

    @MainActor
    func testAnExitedRuntimeIsStartedAgainWithTheHostOnItsNewAddress() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        host.startMonitoring()

        await fixture.runtime.exit()
        try await waitUntil {
            fixture.processes.count == 2 && host.status == .running && !host.isWorking
        }
        let runtimeStarts = await fixture.runtime.starts
        let passwords = await fixture.runtime.passwords
        XCTAssertEqual(runtimeStarts, 2)
        XCTAssertFalse(fixture.processes[0].isRunning, "the old host was stopped before the new one started")
        XCTAssertEqual(fixture.runner.configuredURLs, ["http://127.0.0.1:4101", "http://127.0.0.1:4102"])
        XCTAssertNotEqual(passwords[0], passwords[1], "both stopped, so the managed password was discarded")
        XCTAssertEqual(fixture.processes[1].command.environment["AGENTLAND_OPENCODE_PASSWORD"], passwords[1])
        XCTAssertNil(host.errorMessage)
        await host.stopAndWait()
    }

    @MainActor
    func testAHostThatKeepsExitingStopsEverythingAndShowsTheError() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 2, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        host.startMonitoring()

        fixture.processes.exitAtLaunch = true
        fixture.processes.last?.exit()
        try await waitUntil { host.errorMessage != nil && !host.isWorking && host.status == .stopped }
        // One exit and two failed attempts: the third failure in the window is past the limit of two.
        XCTAssertEqual(fixture.processes.count, 3)
        XCTAssertEqual(host.errorMessage, DesktopError.commandFailed(
            "The local service stopped 3 times in 60 seconds. Last error: The host command failed: The local host stopped during startup. Choose Connect to start it again.").localizedDescription,
            "the last attempt's error is kept")
        let runtimeRunning = await fixture.runtime.isRunning()
        XCTAssertFalse(runtimeRunning, "everything owned stops")
        XCTAssertTrue(host.connectionDesired, "the next launch or Connect starts it again")
        XCTAssertFalse(host.requiresShutdown)

        // Nothing loops on after giving up.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.processes.count, 3)

        // Connect starts afresh with a new count.
        fixture.processes.exitAtLaunch = false
        host.start()
        await host.waitForCurrentOperation()
        XCTAssertEqual(host.status, .running)
        XCTAssertNil(host.errorMessage)
        await host.stopAndWait()
    }

    @MainActor
    func testARestartKeepsAWorkspaceRenamedOnTheHost() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        host.startMonitoring()

        // A phone renames the workspace through the host while it runs; the Mac's window has not read the list.
        fixture.runner.setProjects([["workspace", "Renamed", fixture.workspace.path]])
        await fixture.runtime.exit()
        try await waitUntil { fixture.processes.count == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(fixture.runner.configuredProjects.last, [["workspace", "Renamed", fixture.workspace.path]],
                       "the host's list is written back as it is, not the name captured at Connect")
        XCTAssertEqual(host.projectName, "Renamed", "the saved default follows the host")
        XCTAssertNil(host.errorMessage)
        await host.stopAndWait()
    }

    @MainActor
    func testARestartNeverAddsBackAWorkspaceRemovedOnTheHost() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        fixture.runner.setProjects([["workspace", "Sample", fixture.workspace.path], ["other", "Other", other.path]])
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        host.startMonitoring()

        // A phone removes the default workspace.
        fixture.runner.setProjects([["other", "Other", other.path]])
        await fixture.runtime.exit()
        try await waitUntil { fixture.processes.count == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(fixture.runner.configuredProjects.last, [["other", "Other", other.path]], "the removed workspace stays removed")
        let directories = await fixture.runtime.directories
        XCTAssertEqual(directories, [fixture.workspace.path, other.path], "OpenCode starts again in the workspace that is left")
        XCTAssertEqual(host.projectID, "other")
        XCTAssertEqual(host.projectDirectory, other.path)
        XCTAssertNil(host.errorMessage)
        await host.stopAndWait()
    }

    @MainActor
    func testDisconnectDuringTheBackoffCancelsTheRestart() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        host.startMonitoring()

        fixture.processes.last?.exit()
        try await waitUntil { host.status == .starting }
        XCTAssertTrue(host.requiresShutdown, "Quit waits for a pending restart")
        XCTAssertFalse(host.isWorking, "Disconnect stays available while the restart waits")
        host.stop()
        await host.waitForCurrentOperation()
        XCTAssertEqual(host.status, .stopped)
        XCTAssertFalse(host.connectionDesired)
        XCTAssertNil(host.errorMessage)
        let runtimeRunning = await fixture.runtime.isRunning()
        XCTAssertFalse(runtimeRunning)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.processes.count, 1, "the cancelled restart launched nothing")
    }

    @MainActor
    func testQuitDuringTheBackoffStopsBothAndKeepsTheConnectionWanted() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60))
        try await waitUntil { host.status == .running && !host.isWorking }
        host.startMonitoring()

        fixture.processes.last?.exit()
        try await waitUntil { host.status == .starting }
        let started = Date()
        try await host.stopForApplicationTermination()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a pending restart never holds up Quit")
        XCTAssertEqual(host.status, .stopped)
        XCTAssertTrue(host.connectionDesired)
        XCTAssertFalse(host.requiresShutdown)
        XCTAssertEqual(fixture.processes.count, 1)
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) {
            guard Date() < deadline else { throw DesktopError.commandFailed("The restart check timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
