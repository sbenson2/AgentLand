import Foundation
import XCTest
import AgentLandCore
import AgentLandPairing
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// OpenCode and the host restart on their own only while the host says nothing runs: for changed provider
/// keys at once, for a new managed OpenCode once nothing has run for 10 minutes, the way an exited child is
/// restarted. The host's catalog, the runtime, the host process and the Keychain are fakes.
final class OpenCodeIdleRestartTests: XCTestCase {
    @MainActor
    func testAnIdleHostWithANewOpenCodeRestartsBothInTheWorkspaceItListsNow() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 734))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60),
                                                   agents: agents, agentsPollInterval: .milliseconds(50))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(host.openCodeReport?.version, "1.18.31")
        // The host asks, but a start would run the same OpenCode: nothing restarts.
        try await waitForCondition("a few polls") { agents.requests >= 3 }
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1)

        // A phone renamed the workspace; then the host installs a new OpenCode.
        fixture.runner.setProjects([["workspace", "Renamed", fixture.workspace.path]])
        await fixture.runtime.installNewVersion("1.19.0")
        try await waitForCondition("the restart") {
            await fixture.runtime.starts == 2 && fixture.processes.count == 2 && host.status == .running && !host.isWorking
        }
        XCTAssertFalse(fixture.processes[0].isRunning, "the old host was stopped first")
        XCTAssertEqual(fixture.runner.configuredProjects.last, [["workspace", "Renamed", fixture.workspace.path]],
                       "the host's list is written back as it is, so the rename stays")
        XCTAssertEqual(host.projectName, "Renamed")
        XCTAssertNil(host.errorMessage)
        XCTAssertEqual(host.openCodeReport?.version, "1.19.0")
        let activity = try XCTUnwrap(host.openCodeActivity)
        XCTAssertTrue(activity.hasPrefix("Restarted OpenCode at "), activity)
        XCTAssertTrue(activity.hasSuffix(" to run OpenCode 1.19.0 from the host, after 12 minutes with nothing running."), activity)
        XCTAssertTrue(host.connectionDesired)

        // The host still says so for a while; a start would change nothing, so nothing loops.
        let asked = agents.requests
        try await waitForCondition("more polls") { agents.requests >= asked + 3 }
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(fixture.processes.count, 2)
        await host.stopAndWait()
    }

    @MainActor
    func testANewOpenCodeThatDoesNotStartIsTriedOnceAndSaysSo() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 900))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60),
                                                   agents: agents, agentsPollInterval: .milliseconds(30))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        await fixture.runtime.installNewVersion("1.19.0", starts: false)
        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(host.openCodeReport?.source, .previous(ManagedAgentRecord(version: "1.18.31", command: "opencode")))
        XCTAssertEqual(host.openCodeReport?.fallbackReason, "OpenCode 1.19.0 didn’t start. AgentLand runs the previous version, 1.18.31.")
        XCTAssertEqual(AIProvidersText.running(host.openCodeReport), "OpenCode 1.18.31, the host’s previous version")
        XCTAssertTrue(host.openCodeActivity?.hasSuffix(" to try the host's new OpenCode, after 15 minutes with nothing running.") == true,
                      host.openCodeActivity ?? "no activity")
        let asked = agents.requests
        try await waitForCondition("more polls") { agents.requests >= asked + 3 }
        let starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2, "the host still asks, but the version that failed is not tried again")
        await host.stopAndWait()
    }

    /// A restart clears the pairing code, which a phone may be scanning: restarts on their own wait while
    /// one is shown, and the next poll after it is gone restarts.
    @MainActor
    func testARestartWaitsWhileAPairingCodeIsShown() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 900))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60),
                                                   agents: agents, agentsPollInterval: .milliseconds(30))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        let advertisement = try HostAdvertisement(name: "Test Mac", address: "https://test-mac.local:9841",
                                                  certificateSHA256: String(repeating: "ab", count: 32))
        host.showPairing(try PairingInvitation(advertisement: advertisement, code: "PAIRCODE1234", expiresAt: Date().addingTimeInterval(3)))
        XCTAssertNotNil(host.validInvitation)
        await fixture.runtime.installNewVersion("1.19.0")
        let asked = agents.requests
        try await waitForCondition("a few polls") { agents.requests >= asked + 4 }
        let startsWhileShown = await fixture.runtime.starts
        XCTAssertNotNil(host.validInvitation, "the code was on screen for those polls")
        XCTAssertEqual(startsWhileShown, 1, "no restart while the code is shown")
        XCTAssertEqual(fixture.processes.count, 1)
        XCTAssertEqual(host.pairingCode, "PAIRCODE1234")

        // Once it has expired, the next poll restarts.
        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        XCTAssertNil(host.validInvitation)
        XCTAssertEqual(host.openCodeReport?.version, "1.19.0")
        await host.stopAndWait()
    }

    @MainActor
    func testABusyHostKeepsOpenCodeRunningUntilItHasBeenIdleTenMinutes() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 599))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60),
                                                   agents: agents, agentsPollInterval: .milliseconds(30))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        await fixture.runtime.installNewVersion("1.19.0")
        try await waitForCondition("a few polls") { agents.requests >= 4 }
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1, "something ran in the last 10 minutes")
        agents.answer(HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 600))
        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2)
        await host.stopAndWait()
    }

    @MainActor
    func testANewKeyGoesToTheKeychainAndReachesOpenCodeAtOnceWhenTheHostIsIdle() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let secrets = MemorySecretStore()
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: false, idleForSeconds: 900))
        // No poll comes in the test's time: only the check right after the change can restart.
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), secrets: secrets,
                                                   agents: agents, agentsPollInterval: .seconds(3600))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        var environments = await fixture.runtime.environments
        XCTAssertEqual(environments, [[:]])

        let canary = "sk-test-\(UUID().uuidString)"
        try host.saveProviderKey("  \(canary)\n", providerID: "openai", variable: "OPENAI_API_KEY")
        XCTAssertEqual(secrets.items, ["provider.openai.api-key": canary], "saved the way provider keys always were, trimmed")
        XCTAssertEqual(host.savedProviderKeys, ["openai": "OPENAI_API_KEY"])
        let preferences = try XCTUnwrap(fixture.defaults.data(forKey: "dev.agentland.desktop.preferences.v1"))
        XCTAssertFalse(String(decoding: preferences, as: UTF8.self).contains(canary), "never in the preferences")
        XCTAssertTrue(String(decoding: preferences, as: UTF8.self).contains("OPENAI_API_KEY"))
        XCTAssertTrue(host.openCodeSettingsPending)

        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        environments = await fixture.runtime.environments
        XCTAssertEqual(environments.last, ["OPENAI_API_KEY": canary])
        XCTAssertFalse(host.openCodeSettingsPending)
        XCTAssertTrue(host.openCodeActivity?.hasSuffix(" to apply changed provider settings, after 15 minutes with nothing running.") == true,
                      host.openCodeActivity ?? "no activity")
        XCTAssertFalse((host.errorMessage ?? "").contains(canary))
        await host.stopAndWait()
    }

    @MainActor
    func testKeyChangesWaitWhileSomethingRunsAndRemoveKeyDeletesTheItem() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let secrets = MemorySecretStore()
        // A chat turn, a terminal or a device viewing a chat.
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: false, idleForSeconds: 0))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), secrets: secrets,
                                                   agents: agents, agentsPollInterval: .milliseconds(30))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        try host.saveProviderKey("first-key", providerID: "openai", variable: "OPENAI_API_KEY")
        try await waitForCondition("a few polls") { agents.requests >= 4 }
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(host.openCodeSettingsPending)

        try host.removeProviderKey(providerID: "openai")
        XCTAssertEqual(secrets.items, [:], "Remove Key deletes the Keychain item")
        XCTAssertEqual(host.savedProviderKeys, [:])
        XCTAssertTrue(host.openCodeSettingsPending, "the running OpenCode still has the key until it restarts")

        // Nothing runs now: the change applies at once, without the 10 minutes a new version waits for.
        agents.answer(HostAgentStatus(id: "opencode", restartWanted: false, idleForSeconds: 20))
        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        let environments = await fixture.runtime.environments
        XCTAssertEqual(environments.last, [:])
        XCTAssertFalse(host.openCodeSettingsPending)
        XCTAssertTrue(host.openCodeActivity?.hasSuffix(" to apply changed provider settings while nothing was running.") == true,
                      host.openCodeActivity ?? "no activity")
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2)
        await host.stopAndWait()
    }

    /// Every start runs the newest OpenCode, so a restart for changed settings brings a new version the
    /// host installed with it, and says so.
    @MainActor
    func testARestartForChangedSettingsRunsTheHostsNewOpenCodeToo() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 45))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), secrets: MemorySecretStore(),
                                                   agents: agents, agentsPollInterval: .milliseconds(30))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        await fixture.runtime.installNewVersion("1.19.0")
        try await waitForCondition("a few polls") { agents.requests >= 4 }
        var starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1, "a new version alone waits for 10 idle minutes")

        try host.saveProviderKey("key", providerID: "openai", variable: "OPENAI_API_KEY")
        try await waitForCondition("the restart") { await fixture.runtime.starts == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(host.openCodeReport?.version, "1.19.0")
        XCTAssertTrue(host.openCodeActivity?.hasSuffix(" to run OpenCode 1.19.0 from the host and apply changed provider settings while nothing was running.") == true,
                      host.openCodeActivity ?? "no activity")
        starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 2)
        await host.stopAndWait()
    }

    /// A host from before the catalog, and one started with `--no-agents` (501 `agents_unavailable`).
    @MainActor
    func testAHostThatDoesNotReportIdlenessNeverRestartsOnItsOwn() async throws {
        for failure in [ClientError.unexpectedStatus(404), .server(code: "not_found", message: "No such route."),
                        .server(code: "agents_unavailable", message: "The agent catalog is off."), .unexpectedStatus(501)] {
            let fixture = try RestartFixture()
            defer { fixture.cleanUp() }
            let agents = FakeAgentsFeed(openCode: nil)
            agents.fail(failure)
            let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), secrets: MemorySecretStore(),
                                                       agents: agents, agentsPollInterval: .milliseconds(30))
            try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
            try host.saveProviderKey("key", providerID: "openai", variable: "OPENAI_API_KEY")
            try await waitForCondition("a few polls") { agents.requests >= 4 }
            XCTAssertEqual(host.hostReportsIdle, false, "\(failure)")
            XCTAssertTrue(host.openCodeSettingsPending, "it applies at the next start")
            let starts = await fixture.runtime.starts
            XCTAssertEqual(starts, 1, "\(failure)")
            await host.stopAndWait()
            XCTAssertFalse(host.openCodeSettingsPending, "nothing runs: the next start applies it")
        }
    }

    /// In development HTTP the app reads no catalog (it has no pinned session), so nothing restarts on
    /// its own: that counts as a host that does not report idleness, and the pane promises no restart.
    @MainActor
    func testWithoutTheHostsCatalogChangesWaitForTheNextStart() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), secrets: MemorySecretStore())
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(host.hostReportsIdle, false)
        try host.saveProviderKey("key", providerID: "openai", variable: "OPENAI_API_KEY")
        XCTAssertTrue(host.openCodeSettingsPending)
        let notes = AIProvidersText.notes(report: host.openCodeReport, pending: host.openCodeSettingsPending,
                                          hostReportsIdle: host.hostReportsIdle, activity: host.openCodeActivity)
        XCTAssertEqual(notes.first?.hasPrefix("Your changes apply when AgentLand next starts the host."), true, notes.first ?? "no note")
        XCTAssertFalse(AIProvidersText.restartRule(hostReportsIdle: host.hostReportsIdle).contains("as soon as"))

        // A restart after the host exits starts it the same way.
        host.startMonitoring()
        fixture.processes.last?.exit()
        try await waitForCondition("the restart") { fixture.processes.count == 2 && host.status == .running && !host.isWorking }
        XCTAssertEqual(host.hostReportsIdle, false)
        await host.stopAndWait()
        XCTAssertNil(host.hostReportsIdle, "nothing runs")
    }

    @MainActor
    func testAnAnswerThatArrivesAfterDisconnectRestartsNothing() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let agents = FakeAgentsFeed(openCode: HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: 900))
        agents.delay(.milliseconds(300))
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60),
                                                   agents: agents, agentsPollInterval: .milliseconds(20))
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        await fixture.runtime.installNewVersion("1.19.0")
        try await waitForCondition("a question in flight") { agents.requests >= 1 }
        await host.stopAndWait()
        try await Task.sleep(for: .milliseconds(500))
        let starts = await fixture.runtime.starts
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(fixture.processes.count, 1)
        XCTAssertEqual(host.status, .stopped)
        XCTAssertFalse(host.connectionDesired)
    }

    /// The single-provider settings keep their Keychain item and still reach OpenCode; keys for other
    /// providers join them, one value per variable.
    @MainActor
    func testTheExistingProviderKeyStillAppliesAndKeysShareNoVariable() async throws {
        let fixture = try RestartFixture()
        defer { fixture.cleanUp() }
        let legacy: [String: Any] = [
            "projectDirectory": fixture.workspace.path, "projectName": "Sample", "projectID": "workspace",
            "openCodeURL": "http://127.0.0.1:4197", "listenAddress": "127.0.0.1:9", "terminalEnabled": true,
            "connectionMode": "developmentHTTP", "certificatePath": "", "keyPath": "", "advertisedHost": "mac.local",
            "managedOpenCode": true, "providerID": "deepseek", "modelID": "deepseek-chat",
            "providerCredentialNames": ["deepseek": "DEEPSEEK_API_KEY", "tampered": "PATH"]
        ]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "dev.agentland.desktop.preferences.v1")
        let secrets = MemorySecretStore(["provider.deepseek.api-key": "legacy-key", "provider.tampered.api-key": "/tmp/evil"])
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [0.05], limit: 3, window: 60), secrets: secrets)
        try await waitForCondition("the first start") { host.status == .running && !host.isWorking }
        var environments = await fixture.runtime.environments
        let models = await fixture.runtime.models
        XCTAssertEqual(environments.last, ["DEEPSEEK_API_KEY": "legacy-key"], "a name AgentLand may not set never reaches OpenCode")
        XCTAssertEqual(models.last, "deepseek/deepseek-chat")
        XCTAssertEqual(host.savedProviderKeys, ["deepseek": "DEEPSEEK_API_KEY"])
        XCTAssertEqual(host.defaultModel?.providerID, "deepseek")

        try host.saveProviderKey("copilot-key", providerID: "github-copilot", variable: "GITHUB_TOKEN")
        XCTAssertEqual(host.providersSharingKey(variable: "GITHUB_TOKEN", with: "github-models"), ["github-copilot"])
        // Nothing is deleted unless the owner saw it named: a save that does not name Copilot's key saves nothing.
        XCTAssertThrowsError(try host.saveProviderKey("models-key", providerID: "github-models", variable: "GITHUB_TOKEN")) {
            XCTAssertEqual($0 as? ProviderKeyError, .replacedKeysChanged("GITHUB_TOKEN"))
        }
        XCTAssertEqual(secrets.items["provider.github-copilot.api-key"], "copilot-key", "nothing was deleted")
        XCTAssertNil(secrets.items["provider.github-models.api-key"], "nor saved")
        XCTAssertEqual(host.savedProviderKeys, ["deepseek": "DEEPSEEK_API_KEY", "github-copilot": "GITHUB_TOKEN"])
        try host.saveProviderKey("models-key", providerID: "github-models", variable: "GITHUB_TOKEN", replacing: ["github-copilot"])
        XCTAssertEqual(host.savedProviderKeys, ["deepseek": "DEEPSEEK_API_KEY", "github-models": "GITHUB_TOKEN"])
        XCTAssertNil(secrets.items["provider.github-copilot.api-key"], "OpenCode reads one GITHUB_TOKEN: the other key goes")
        XCTAssertEqual(secrets.items["provider.deepseek.api-key"], "legacy-key", "the existing item is unchanged")

        XCTAssertThrowsError(try host.saveProviderKey("x", providerID: "sneaky", variable: "DYLD_INSERT_LIBRARIES_TOKEN"))
        XCTAssertThrowsError(try host.saveProviderKey("x", providerID: "sneaky", variable: "PATH"))
        XCTAssertThrowsError(try host.saveProviderKey("   ", providerID: "openai", variable: "OPENAI_API_KEY")) {
            XCTAssertEqual($0 as? ProviderKeyError, .empty)
        }
        XCTAssertThrowsError(try host.saveProviderKey("two\nlines", providerID: "openai", variable: "OPENAI_API_KEY")) {
            XCTAssertEqual($0 as? ProviderKeyError, .unusable)
        }
        XCTAssertNil(secrets.items["provider.sneaky.api-key"])
        XCTAssertNil(secrets.items["provider.openai.api-key"])

        // Nothing restarts here (no catalog of the host's), so a Connect applies the keys.
        host.setDefaultModel(providerID: "github-models", modelID: "gpt-test")
        XCTAssertTrue(host.openCodeSettingsPending)
        await host.stopAndWait()
        host.start()
        try await waitForCondition("the next start") { host.status == .running && !host.isWorking }
        environments = await fixture.runtime.environments
        XCTAssertEqual(environments.last, ["DEEPSEEK_API_KEY": "legacy-key", "GITHUB_TOKEN": "models-key"])
        let lastModel = await fixture.runtime.models.last
        XCTAssertEqual(lastModel, "github-models/gpt-test")

        host.managedOpenCode = false
        XCTAssertThrowsError(try host.saveProviderKey("x", providerID: "openai", variable: "OPENAI_API_KEY")) {
            XCTAssertEqual($0 as? ProviderKeyError, .externalOpenCode)
        }
        host.managedOpenCode = true
        await host.stopAndWait()
    }
}
