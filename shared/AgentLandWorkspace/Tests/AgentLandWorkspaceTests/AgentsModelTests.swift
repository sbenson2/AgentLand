import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandWorkspace

/// A value the test changes while the host's handlers read it.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Settings → Agents against a scripted host (docs/AGENT-CATALOG-PLAN.md): the lists, installs with and
/// without a check, the confirmation before an unverified download, following the host while work runs,
/// refusals, and the rules every management screen keeps: refused while offline, never sent again by
/// itself, answers for another host or an older read dropped.
@MainActor final class AgentsModelTests: XCTestCase {
    func testVersionLineSaysWhenAnUpdateWaitsForTerminals() {
        func line(_ waiting: Int?) -> String {
            InstalledAgentRow.versionLine(AgentInfo(id: "codex", name: "Codex", source: .local, state: .installed, installedVersion: "0.159.2",
                                                    autoUpdates: true, supportsUpdates: true, updateWaitingTerminals: waiting))
        }
        XCTAssertEqual(line(nil), "Version 0.159.2 · Updates automatically")
        XCTAssertEqual(line(0), "Version 0.159.2 · Updates automatically")
        XCTAssertEqual(line(1), "Version 0.159.2 · Updates automatically · Update waiting: 1 terminal using it")
        XCTAssertEqual(line(3), "Version 0.159.2 · Updates automatically · Update waiting: 3 terminals using it")
    }

    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated static let capabilities = #"""
    {"interactions":true,"terminal":true,"terminalPrograms":["shell","claude"],"chatProviders":["opencode","claude"],
     "agents":["catalog","install","acp"],
     "agentCatalog":[{"id":"claude","name":"Claude Code","chat":true,"terminal":true},{"id":"opencode","name":"OpenCode","chat":true,"terminal":true}]}
    """#

    nonisolated static func agent(_ id: String, _ name: String, state: String = "notInstalled", source: String = "registry",
                                  version: String? = nil, latest: String? = nil, verified: Bool = true, error: String? = nil,
                                  description: String? = nil, website: String? = nil) -> String {
        var fields = [#""id":"\#(id)""#, #""name":"\#(name)""#, #""state":"\#(state)""#, #""source":"\#(source)""#,
                      #""chat":true"#, #""terminal":true"#, #""verified":\#(verified)"#, #""license":"Apache-2.0""#]
        if let version { fields.append(#""installedVersion":"\#(version)""#) }
        if let latest { fields.append(#""latestVersion":"\#(latest)""#) }
        if let error { fields.append(#""lastError":"\#(error)""#) }
        if let description { fields.append(#""description":"\#(description)""#) }
        if let website { fields.append(#""website":"\#(website)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    nonisolated static func catalog(_ agents: String...) -> String {
        #"{"registry":{"fetchedAt":"2026-09-26T20:00:00Z"},"agents":[\#(agents.joined(separator: ","))]}"#
    }

    nonisolated static let claude = agent("claude", "Claude Code", state: "installed", source: "local", version: "2.1.280")
    nonisolated static let opencode = agent("opencode", "OpenCode", state: "installed", source: "bundled", version: "1.18.31")
    nonisolated static let gemini = agent("gemini", "Gemini CLI", description: "Google's agent in the terminal.")
    nonisolated static let cursor = agent("cursor", "Cursor", verified: false, website: "https://www.cursor.com/cli")

    nonisolated static func refusal(_ code: String, _ message: String = "Refused.") -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private func client(_ host: ScriptedHost) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host)
    }

    /// A workspace attached to `host`, its list and capabilities read from it.
    private func workspace(_ host: ScriptedHost, name: String = #function) async throws -> WorkspaceModel {
        let suite = "agents-model-\(name)-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity, client: try client(host))
        await workspace.refreshProjects()
        XCTAssertNil(workspace.hostIssue)
        workspace.agents.pollInterval = .milliseconds(20)
        return workspace
    }

    /// A host with the agent catalog whose `GET /v1/agents` answers what `agents` holds at the time.
    private func scriptedHost(_ agents: Locked<String>, capabilities: String = capabilities) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p1","name":"Alpha"}]}"#) }
        host.on("/v1/agents") { _ in (200, agents.current) }
        return host
    }

    func testAutomaticUpdateSettingIsHostOwnedAndManualUpdatesRemainAvailable() async throws {
        let local = #"{"id":"codex","name":"Codex","source":"local","state":"installed","autoUpdates":false,"supportsUpdates":true}"#
        let catalog = Locked(#"{"automaticUpdates":false,"agents":[\#(local)]}"#)
        let host = scriptedHost(catalog, capabilities: Self.capabilities.replacingOccurrences(of: #""catalog","install""#, with: #""catalog","updateSettings","install""#))
        host.on("/v1/agents/settings") { _ in
            catalog.current = #"{"automaticUpdates":true,"agents":[\#(local)]}"#
            return (200, #"{"automaticUpdates":true}"#)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        XCTAssertTrue(model.canConfigureAutomaticUpdates)
        XCTAssertEqual(model.automaticUpdates, false)
        let codex = try XCTUnwrap(model.agent("codex"))
        XCTAssertEqual(InstalledAgentRow.actions(codex, canInstall: true), [.updateNow])
        XCTAssertTrue(InstalledAgentRow.versionLine(codex).contains("Automatic updates off"))
        await model.setAutomaticUpdates(true)
        XCTAssertEqual(model.automaticUpdates, true)
        XCTAssertEqual(host.bodies("/v1/agents/settings") as [NSDictionary], [["automaticUpdates": true]])
        let reloaded = try await self.workspace(host)
        await reloaded.agents.refresh()
        XCTAssertEqual(reloaded.agents.automaticUpdates, true)
        workspace.reachable = false
        await model.setAutomaticUpdates(false)
        XCTAssertEqual(host.requests("/v1/agents/settings").count, 1)
        XCTAssertEqual(model.automaticUpdates, true)
    }

    func testOlderHostsDoNotExposeAutomaticUpdateSetting() async throws {
        let workspace = try await workspace(scriptedHost(Locked(Self.catalog(Self.claude))))
        await workspace.agents.refresh()
        XCTAssertFalse(workspace.agents.canConfigureAutomaticUpdates)
        await workspace.agents.setAutomaticUpdates(true)
        XCTAssertNil(workspace.agents.automaticUpdates)
    }

    func testFailedAndUncertainSettingWritesKeepLastHostValueAndNeverReplay() async throws {
        let catalog = Locked(#"{"automaticUpdates":false,"agents":[]}"#)
        let host = scriptedHost(catalog, capabilities: Self.capabilities.replacingOccurrences(of: #""catalog","install""#, with: #""catalog","updateSettings","install""#))
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        host.on("/v1/agents/settings") { _ in (403, Self.refusal("forbidden")) }
        await model.setAutomaticUpdates(true)
        XCTAssertEqual(model.automaticUpdates, false)
        XCTAssertEqual(model.notice?.tone, .error)
        XCTAssertFalse(model.savingAutomaticUpdates)
        host.on("/v1/agents/settings") { _ in throw URLError(.networkConnectionLost) }
        await model.setAutomaticUpdates(true)
        XCTAssertEqual(model.automaticUpdates, false)
        XCTAssertEqual(model.notice?.tone, .warning)
        XCTAssertEqual(host.requests("/v1/agents/settings").count, 2)
        XCTAssertFalse(model.savingAutomaticUpdates)
        catalog.current = #"{"automaticUpdates":true,"agents":[]}"#
        await model.refresh()
        XCTAssertEqual(model.automaticUpdates, true, "Reconnecting reads the actual host choice")
    }

    func testSettingAnswerForPreviousConnectionIsDroppedAndSpinnerCleared() async throws {
        let catalog = Locked(#"{"automaticUpdates":false,"agents":[]}"#)
        let host = scriptedHost(catalog, capabilities: Self.capabilities.replacingOccurrences(of: #""catalog","install""#, with: #""catalog","updateSettings","install""#))
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let reached = Gate(), held = Gate()
        host.on("/v1/agents/settings") { _ in
            await reached.open()
            await held.wait()
            return (200, #"{"automaticUpdates":true}"#)
        }
        let save = Task { await model.setAutomaticUpdates(true) }
        await arrive(at: reached)
        XCTAssertTrue(model.savingAutomaticUpdates)
        workspace.client = try client(ScriptedHost())
        await held.open()
        await save.value
        XCTAssertEqual(model.automaticUpdates, false)
        XCTAssertFalse(model.savingAutomaticUpdates)
        XCTAssertNil(model.notice)
    }

    // MARK: The lists

    func testLocalSelfUpdatingCLIShowsAutomaticUpdatesAndCanUpdateWithoutUninstall() async throws {
        let codex = #"{"id":"codex","name":"Codex","source":"local","state":"installed","installedVersion":"0.159.2","autoUpdates":true,"verified":true,"chat":true,"terminal":true}"#
        let agents = Locked(Self.catalog(codex, Self.claude))
        let host = scriptedHost(agents)
        host.on("/v1/agents/update") { _ in (202, codex) }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let local = try XCTUnwrap(model.agent("codex"))

        XCTAssertEqual(InstalledAgentRow.versionLine(local), "Version 0.159.2 · Updates automatically")
        XCTAssertEqual(InstalledAgentRow.actions(local, canInstall: true), [.updateNow])
        XCTAssertEqual(InstalledAgentRow.actions(local, canInstall: false), [])
        XCTAssertFalse(local.canUninstall)
        await model.update(local)
        XCTAssertEqual(host.bodies("/v1/agents/update") as [NSDictionary], [["id": "codex"]])

        let legacy = try XCTUnwrap(model.agent("claude"))
        XCTAssertEqual(InstalledAgentRow.actions(legacy, canInstall: true), [])
        await model.update(legacy)
        XCTAssertEqual(host.requests("/v1/agents/update").count, 1, "Older hosts never receive a local update")
        await model.uninstall(local)
        XCTAssertTrue(host.requests("/v1/agents/uninstall").isEmpty)
    }

    func testThePaneShowsOnlyForHostsThatListTheirAgentsAndSplitsInstalledFromAvailable() async throws {
        let failed = Self.agent("goose", "Goose", state: "failed", error: "npm was not found.")
        let updating = Self.agent("amp", "Amp", state: "updating", version: "1.0", latest: "1.1")
        let agents = Locked(Self.catalog(Self.gemini, Self.claude, Self.cursor, Self.opencode, failed, updating))
        let workspace = try await workspace(scriptedHost(agents))
        let model = workspace.agents
        XCTAssertTrue(model.isAvailable)
        XCTAssertTrue(model.canInstall)
        await model.refresh()
        XCTAssertEqual(model.installed.map(\.id), ["amp", "claude", "opencode"],
                       "Installed by name: an agent being updated, the Mac's own and an older host's OpenCode from the Mac app")
        XCTAssertEqual(model.available.map(\.id), ["cursor", "gemini", "goose"], "A failed install is still available")
        XCTAssertTrue(model.hasWorkRunning)

        XCTAssertEqual(InstalledAgentRow.versionLine(try XCTUnwrap(model.agent("amp"))), "Version 1.0 (1.1 available) · Updates automatically")
        XCTAssertEqual(InstalledAgentRow.versionLine(try XCTUnwrap(model.agent("claude"))), "Version 2.1.280 · Updated by its own installer")
        XCTAssertEqual(InstalledAgentRow.versionLine(try XCTUnwrap(model.agent("opencode"))), "Version 1.18.31 · Updated by AgentLand")
        XCTAssertEqual(AgentStatusLine.text(try XCTUnwrap(model.agent("amp")), pending: nil), "Updating to 1.1…")
        XCTAssertEqual(AgentStatusLine.text(try XCTUnwrap(model.agent("goose")), pending: nil), "Install failed: npm was not found.")

        model.search = "google"
        XCTAssertEqual(model.available.map(\.id), ["gemini"], "The search reads descriptions too")
        XCTAssertTrue(model.installed.isEmpty)
        model.search = "CLAUDE"
        XCTAssertEqual(model.installed.map(\.id), ["claude"])
        model.search = ""

        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, agents: ["acp"])
        XCTAssertFalse(model.isAvailable, "Without the catalog feature there is no pane")
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, agents: ["catalog"])
        XCTAssertTrue(model.isAvailable)
        XCTAssertFalse(model.canInstall, "Without install the pane only lists")
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true)
        XCTAssertFalse(model.isAvailable, "Hosts without agents show no pane")
    }

    /// The host lists Claude Code and Codex as `local` and `notInstalled` when their commands are not on the
    /// Mac: they are not installed and AgentLand cannot install them, so neither list shows them. A local or
    /// bundled agent is under Installed while its state says it is there, and an agent whose id is longer
    /// than 32 characters (the host takes up to 64) has its row too.
    func testClaudeCodeAndCodexThatTheMacDoesNotHaveAreNotListed() async throws {
        let codex = Self.agent("codex", "Codex", state: "notInstalled", source: "local")
        let missingClaude = Self.agent("claude", "Claude Code", state: "notInstalled", source: "local")
        let takingOver = Self.agent("opencode", "OpenCode", state: "installing", source: "bundled", version: "1.18.31")
        let localGemini = Self.agent("gemini", "Gemini CLI", state: "installed", source: "local", version: "0.61.0")
        let longID = "agent-with-a-name-longer-than-thirty-two"
        let long = Self.agent(longID, "Long Agent", state: "installed", version: "1.0")
        let agents = Locked(Self.catalog(missingClaude, codex, takingOver, localGemini, long, Self.cursor))
        let workspace = try await workspace(scriptedHost(agents))
        let model = workspace.agents
        await model.refresh()
        XCTAssertEqual(model.installed.map(\.id), ["gemini", longID, "opencode"],
                       "Only what is on the Mac: OpenCode while AgentLand takes it over, not the missing CLIs")
        XCTAssertEqual(model.available.map(\.id), ["cursor"], "The Mac's missing CLIs are not offered for install either")

        // Once the Mac has Claude Code, it is listed.
        agents.current = Self.catalog(Self.claude, codex, takingOver, localGemini, long, Self.cursor)
        await model.refresh()
        XCTAssertEqual(model.installed.map(\.id), ["claude", "gemini", longID, "opencode"])
    }

    // MARK: Installing

    func testAnInstallIsSentOnceAndTheHostIsFollowedUntilItFinishes() async throws {
        let agents = Locked(Self.catalog(Self.claude, Self.gemini))
        let capabilities = Locked(Self.capabilities)
        let host = scriptedHost(agents)
        host.on("/v1/capabilities") { _ in (200, capabilities.current) }
        host.on("/v1/agents/install") { _ in
            agents.current = Self.catalog(Self.claude, Self.agent("gemini", "Gemini CLI", state: "installing"))
            return (202, Self.agent("gemini", "Gemini CLI", state: "installing"))
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        let following = Task { await model.follow() }
        defer { following.cancel() }
        await waitUntil("the first read") { model.catalog != nil }
        let capabilityReads = host.requests("/v1/capabilities").count

        await model.install(try XCTUnwrap(model.agent("gemini")))
        XCTAssertEqual(host.bodies("/v1/agents/install") as [NSDictionary], [["id": "gemini"]], "A verified download is sent as it is")
        XCTAssertEqual(model.agent("gemini")?.state, .installing)
        XCTAssertEqual(AgentStatusLine.text(try XCTUnwrap(model.agent("gemini")), pending: nil), "Installing…")
        XCTAssertTrue(model.hasWorkRunning)

        // The host is read again while it works.
        let readsWhileInstalling = host.requests("/v1/agents").count
        await waitUntil("a few reads while it installs") { host.requests("/v1/agents").count >= readsWhileInstalling + 3 }

        // It finishes: New Terminal change, so the capabilities are read again.
        capabilities.current = Self.capabilities.replacingOccurrences(
            of: #"{"id":"opencode","name":"OpenCode","chat":true,"terminal":true}"#,
            with: #"{"id":"opencode","name":"OpenCode","chat":true,"terminal":true},{"id":"gemini","name":"Gemini CLI","chat":true,"terminal":true}"#)
        agents.current = Self.catalog(Self.claude, Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.62.0"))
        await waitUntil("the install to finish") { model.agent("gemini")?.state == .installed }
        XCTAssertEqual(model.notice?.title, "Installed Gemini CLI")
        XCTAssertEqual(model.notice?.message, "It’s in New Terminal.")
        await waitUntil("the capabilities read again") { host.requests("/v1/capabilities").count > capabilityReads }
        await waitUntil("New Terminal to list it") { TerminalProgram.offered(by: workspace.capabilities).contains { $0.id == "gemini" } }
        XCTAssertEqual(TerminalProgram.offered(by: workspace.capabilities).last?.displayName, "Gemini CLI")

        // Nothing runs any more: the host is not read again.
        let settled = host.requests("/v1/agents").count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.requests("/v1/agents").count, settled, "No reads while nothing runs")
        XCTAssertEqual(host.requests("/v1/agents/install").count, 1, "Sent once")
    }

    func testAnUnverifiedDownloadAsksFirstNamingItsWebsiteAndSendsAllowUnverifiedOnlyAfterTheConfirmation() async throws {
        let agents = Locked(Self.catalog(Self.cursor, Self.gemini))
        let host = scriptedHost(agents)
        host.on("/v1/agents/install") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            if body?["allowUnverified"] as? Bool != true, body?["id"] as? String == "gemini" {
                return (400, Self.refusal("unverified_download", "No checksum."))
            }
            return (202, Self.agent(body?["id"] as? String ?? "", "Agent", state: "installing"))
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let cursor = try XCTUnwrap(model.agent("cursor"))

        await model.install(cursor)
        XCTAssertEqual(model.pendingUnverified?.id, "cursor", "An unverified download asks first")
        XCTAssertEqual(model.pendingUnverified?.isUpdate, false)
        XCTAssertTrue(host.requests("/v1/agents/install").isEmpty, "Nothing is sent before the confirmation")
        XCTAssertEqual(model.pendingUnverified?.agent.websiteName, "cursor.com")
        XCTAssertEqual(AgentsConfirmationText.unverifiedTitle(cursor), "Install Cursor from cursor.com?")
        XCTAssertEqual(AgentsConfirmationText.unverifiedMessage(cursor, hostName: workspace.hostName),
                       "The registry lists no checksum for this download, so AgentLand on your Mac can’t check it. Install it only if you trust cursor.com.")
        let unlisted = AgentInfo(id: "odd", name: "Odd", verified: false)
        XCTAssertEqual(AgentsConfirmationText.unverifiedTitle(unlisted), "Install Odd from an unlisted website?")

        // Cancel: nothing is sent.
        model.dismissQuestions()
        XCTAssertNil(model.pendingUnverified)
        XCTAssertTrue(host.requests("/v1/agents/install").isEmpty)

        // Confirmed: sent once, with allowUnverified.
        await model.install(cursor)
        await model.confirmUnverified(try XCTUnwrap(model.pendingUnverified))
        XCTAssertEqual(host.bodies("/v1/agents/install") as [NSDictionary], [["id": "cursor", "allowUnverified": true]])
        XCTAssertNil(model.pendingUnverified)

        // A download the list called verified that the host cannot check after all: asked first as well.
        await model.install(try XCTUnwrap(model.agent("gemini")))
        XCTAssertEqual(model.pendingUnverified?.id, "gemini", "The host's unverified_download asks the person")
        XCTAssertEqual(host.bodies("/v1/agents/install").count, 2, "Not sent again by itself")
        await model.confirmUnverified(try XCTUnwrap(model.pendingUnverified))
        XCTAssertEqual(host.bodies("/v1/agents/install").last as NSDictionary?, ["id": "gemini", "allowUnverified": true])
    }

    /// The registry can move an installed, verified agent to a download without a checksum; the host then
    /// answers Update Now with unverified_download. The pane asks as Install does, naming the website, and
    /// sends the update again with allowUnverified only after the person confirms.
    func testUpdateNowAsksBeforeAnUnverifiedDownloadAndSendsItAgainOnlyAfterTheConfirmation() async throws {
        let installed = Self.agent("cursor", "Cursor", state: "installed", version: "1.0", latest: "1.1", website: "https://www.cursor.com/cli")
        let updating = Self.agent("cursor", "Cursor", state: "updating", version: "1.0", latest: "1.1", website: "https://www.cursor.com/cli")
        let agents = Locked(Self.catalog(installed))
        let host = scriptedHost(agents)
        host.on("/v1/agents/update") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            guard body?["allowUnverified"] as? Bool == true else { return (400, Self.refusal("unverified_download", "No checksum.")) }
            agents.current = Self.catalog(updating)
            return (202, updating)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()

        await model.update(try XCTUnwrap(model.agent("cursor")))
        XCTAssertEqual(host.bodies("/v1/agents/update") as [NSDictionary], [["id": "cursor"]], "Sent as it is first")
        let question = try XCTUnwrap(model.pendingUnverified, "The refusal asks the person")
        XCTAssertEqual(question.agent.id, "cursor")
        XCTAssertTrue(question.isUpdate)
        XCTAssertNil(model.notice, "A question, not an error")
        XCTAssertEqual(AgentsConfirmationText.unverifiedTitle(question.agent, update: true), "Update Cursor from cursor.com?")
        XCTAssertEqual(AgentsConfirmationText.unverifiedMessage(question.agent, hostName: workspace.hostName, update: true),
                       "The registry lists no checksum for this download, so AgentLand on your Mac can’t check it. Update it only if you trust cursor.com.")

        // Cancel: nothing more is sent.
        model.dismissQuestions()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.requests("/v1/agents/update").count, 1, "Not sent again by itself")

        // Confirmed: the update goes again, once, with allowUnverified.
        await model.update(try XCTUnwrap(model.agent("cursor")))
        await model.confirmUnverified(try XCTUnwrap(model.pendingUnverified))
        XCTAssertEqual(host.bodies("/v1/agents/update") as [NSDictionary],
                       [["id": "cursor"], ["id": "cursor"], ["id": "cursor", "allowUnverified": true]])
        XCTAssertNil(model.pendingUnverified)
        XCTAssertEqual(model.agent("cursor")?.state, .updating)
        XCTAssertEqual(host.requests("/v1/agents/install").count, 0, "An update is never sent as an install")
    }

    /// A registry agent with nothing for this Mac (`"supported": false`) is listed as not available for this
    /// Mac with no Install, and never asks about an unverified download it could not install anyway.
    func testAnAgentWithNothingForThisMacOffersNoInstallAndNeverTheUnverifiedQuestion() async throws {
        let windsurf = #"{"id":"windsurf","name":"Windsurf","state":"notInstalled","source":"registry","chat":true,"terminal":false,"verified":false,"supported":false,"website":"https://windsurf.com","license":"Proprietary"}"#
        let agents = Locked(Self.catalog(windsurf, Self.gemini))
        let host = scriptedHost(agents)
        host.on("/v1/agents/install") { _ in (400, Self.refusal("unsupported_platform", "Nothing for darwin-aarch64.")) }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let agent = try XCTUnwrap(model.agent("windsurf"))
        XCTAssertFalse(agent.supported)
        XCTAssertEqual(model.available.map(\.id), ["gemini", "windsurf"], "Still listed, under Available")
        XCTAssertFalse(AvailableAgentRow.offersInstall(agent, canInstall: model.canInstall, busy: model.isBusy(agent)), "No Install")
        XCTAssertTrue(AvailableAgentRow.offersInstall(try XCTUnwrap(model.agent("gemini")), canInstall: model.canInstall, busy: false))
        XCTAssertEqual(AvailableAgentRow.spokenDetails(agent, pending: nil), "License Proprietary, Not available for this Mac")

        await model.install(agent)
        XCTAssertNil(model.pendingUnverified, "Never the unverified download's question")
        XCTAssertTrue(host.requests("/v1/agents/install").isEmpty, "Nothing is sent")
        await model.confirmUnverified(AgentsModel.UnverifiedDownload(agent: agent, isUpdate: false))
        XCTAssertTrue(host.requests("/v1/agents/install").isEmpty)
    }

    // MARK: Updating and uninstalling

    func testUpdateNowAndUninstallAreForAgentsAgentLandKeepsAndUninstallAsksFirst() async throws {
        let installed = Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.61.0", latest: "0.62.0")
        let agents = Locked(Self.catalog(Self.claude, installed))
        let host = scriptedHost(agents)
        host.on("/v1/agents/update") { _ in
            agents.current = Self.catalog(Self.claude, Self.agent("gemini", "Gemini CLI", state: "updating", version: "0.61.0", latest: "0.62.0"))
            return (202, Self.agent("gemini", "Gemini CLI", state: "updating", version: "0.61.0", latest: "0.62.0"))
        }
        host.on("/v1/agents/uninstall") { _ in
            agents.current = Self.catalog(Self.claude, Self.gemini)
            return (202, Self.gemini)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()

        // The Mac's own agents have no actions.
        let claude = try XCTUnwrap(model.agent("claude"))
        await model.update(claude)
        model.requestUninstall(claude)
        XCTAssertNil(model.pendingUninstall)
        XCTAssertTrue(host.requests("/v1/agents/update").isEmpty)

        let gemini = try XCTUnwrap(model.agent("gemini"))
        await model.update(gemini)
        XCTAssertEqual(host.bodies("/v1/agents/update") as [NSDictionary], [["id": "gemini"]])
        XCTAssertEqual(model.agent("gemini")?.state, .updating)

        // The update fails its check: the old version stays and the notice says so.
        let following = Task { await model.follow() }
        defer { following.cancel() }
        agents.current = Self.catalog(Self.claude, Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.61.0", latest: "0.62.0",
                                                              error: "The new version did not answer initialize."))
        await waitUntil("the update to end") { model.agent("gemini")?.state == .installed }
        XCTAssertEqual(model.notice?.title, "Couldn’t update Gemini CLI")
        XCTAssertEqual(model.notice?.message, "The new version did not answer initialize. It keeps its current version.")
        XCTAssertEqual(AgentStatusLine.text(try XCTUnwrap(model.agent("gemini")), pending: nil),
                       "Last update failed: The new version did not answer initialize.")

        // Uninstall asks first; Cancel sends nothing.
        model.requestUninstall(try XCTUnwrap(model.agent("gemini")))
        XCTAssertEqual(model.pendingUninstall?.id, "gemini")
        model.dismissQuestions()
        XCTAssertTrue(host.requests("/v1/agents/uninstall").isEmpty)
        let capabilityReads = host.requests("/v1/capabilities").count
        model.requestUninstall(try XCTUnwrap(model.agent("gemini")))
        await model.uninstall(try XCTUnwrap(model.pendingUninstall))
        XCTAssertEqual(host.bodies("/v1/agents/uninstall") as [NSDictionary], [["id": "gemini"]])
        XCTAssertEqual(model.notice?.title, "Uninstalled Gemini CLI")
        XCTAssertEqual(model.available.map(\.id), ["gemini"])
        await waitUntil("the capabilities read again") { host.requests("/v1/capabilities").count > capabilityReads }
    }

    /// Hosts list OpenCode as a registry agent (the Mac app bundles none): before the host's first install it
    /// is under Available with Install, and each state the host reports shows; once installed its row reads
    /// like every registry agent's, "Updates automatically", with Update Now and no Uninstall.
    func testOpenCodeIsARegistryAgentAvailableBeforeItsFirstInstall() async throws {
        let absent = #"{"id":"opencode","name":"OpenCode","description":"The open source coding agent.","license":"MIT","source":"registry","state":"notInstalled","latestVersion":"1.18.32","chat":true,"terminal":true,"verified":true}"#
        let agents = Locked(Self.catalog(Self.claude, absent))
        let host = scriptedHost(agents)
        host.on("/v1/agents/install") { _ in
            let installing = Self.agent("opencode", "OpenCode", state: "installing", latest: "1.18.32")
            agents.current = Self.catalog(Self.claude, installing)
            return (202, installing)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        let following = Task { await model.follow() }
        defer { following.cancel() }
        await waitUntil("the first read") { model.catalog != nil }

        let before = try XCTUnwrap(model.agent("opencode"))
        XCTAssertEqual(model.available.map(\.id), ["opencode"], "Under Available until the host installs it")
        XCTAssertEqual(model.installed.map(\.id), ["claude"])
        XCTAssertTrue(AvailableAgentRow.offersInstall(before, canInstall: model.canInstall, busy: model.isBusy(before)), "With Install")

        await model.install(before)
        XCTAssertEqual(host.bodies("/v1/agents/install") as [NSDictionary], [["id": "opencode"]])
        XCTAssertEqual(model.available.map(\.id), ["opencode"], "Still under Available while it installs")
        XCTAssertEqual(AgentStatusLine.text(try XCTUnwrap(model.agent("opencode")), pending: nil), "Installing…")

        agents.current = Self.catalog(Self.claude, Self.agent("opencode", "OpenCode", state: "installed", version: "1.18.32", latest: "1.18.32"))
        await waitUntil("the install to finish") { model.agent("opencode")?.state == .installed }
        XCTAssertEqual(model.notice?.title, "Installed OpenCode")
        XCTAssertEqual(model.installed.map(\.id), ["claude", "opencode"])
        XCTAssertTrue(model.available.isEmpty)
        let installed = try XCTUnwrap(model.agent("opencode"))
        XCTAssertEqual(InstalledAgentRow.versionLine(installed), "Version 1.18.32 · Updates automatically")
        XCTAssertEqual(InstalledAgentRow.actions(installed, canInstall: model.canInstall), [.updateNow])

        // A newer version in the registry reads as for any registry agent.
        agents.current = Self.catalog(Self.claude, Self.agent("opencode", "OpenCode", state: "installed", version: "1.18.32", latest: "1.18.33"))
        await model.refresh()
        XCTAssertEqual(InstalledAgentRow.versionLine(try XCTUnwrap(model.agent("opencode"))), "Version 1.18.32 (1.18.33 available) · Updates automatically")

        // A first install that failed shows the host's error under Available, with Install offered again.
        agents.current = Self.catalog(Self.claude, Self.agent("opencode", "OpenCode", state: "failed", latest: "1.18.32",
                                                              error: "The download did not match its checksum."))
        await model.refresh()
        let failed = try XCTUnwrap(model.agent("opencode"))
        XCTAssertEqual(model.available.map(\.id), ["opencode"])
        XCTAssertEqual(AgentStatusLine.text(failed, pending: nil), "Install failed: The download did not match its checksum.")
        XCTAssertTrue(AvailableAgentRow.offersInstall(failed, canInstall: model.canInstall, busy: model.isBusy(failed)))
    }

    /// AgentLand's chats need OpenCode: its row offers Update Now and no Uninstall (the … menu, the context
    /// menu, a swipe and VoiceOver all offer `InstalledAgentRow.actions`), and no uninstall of it is asked
    /// about or sent. A host that refuses an uninstall with `agent_required` anyway gets a plain notice.
    func testOpenCodeOffersUpdateNowButNoUninstall() async throws {
        let opencode = Self.agent("opencode", "OpenCode", state: "installed", version: "1.18.32", latest: "1.18.33")
        let gemini = Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.61.0")
        let agents = Locked(Self.catalog(Self.claude, opencode, gemini))
        let host = scriptedHost(agents)
        host.on("/v1/agents/update") { _ in
            (202, Self.agent("opencode", "OpenCode", state: "updating", version: "1.18.32", latest: "1.18.33"))
        }
        host.on("/v1/agents/uninstall") { _ in (409, Self.refusal("agent_required", "AgentLand's chats need this agent.")) }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let code = try XCTUnwrap(model.agent("opencode"))

        XCTAssertEqual(InstalledAgentRow.actions(code, canInstall: model.canInstall), [.updateNow], "Update Now stays; no Uninstall")
        XCTAssertEqual(InstalledAgentRow.actions(try XCTUnwrap(model.agent("gemini")), canInstall: model.canInstall), [.updateNow, .uninstall])
        XCTAssertEqual(InstalledAgentRow.actions(try XCTUnwrap(model.agent("claude")), canInstall: model.canInstall), [],
                       "The Mac's own agents have none")
        XCTAssertEqual(InstalledAgentRow.actions(code, canInstall: false), [], "Nor does a host that takes no changes")

        model.requestUninstall(code)
        XCTAssertNil(model.pendingUninstall, "No question for OpenCode")
        await model.uninstall(code)
        XCTAssertTrue(host.requests("/v1/agents/uninstall").isEmpty, "Nothing is sent for OpenCode")
        XCTAssertNil(model.notice)

        await model.update(code)
        XCTAssertEqual(host.bodies("/v1/agents/update") as [NSDictionary], [["id": "opencode"]], "Update Now works")

        // The host decides which agents AgentLand needs; its refusal says so plainly and is not sent again.
        await model.uninstall(try XCTUnwrap(model.agent("gemini")))
        XCTAssertEqual(model.notice?.title, "AgentLand needs Gemini CLI, so it can’t be uninstalled.")
        XCTAssertNil(model.notice?.message)
        XCTAssertEqual(model.notice?.tone, .warning)
        XCTAssertNil(model.pendingText(try XCTUnwrap(model.agent("gemini"))), "Nothing is waited for")
        XCTAssertTrue(model.uninstalling.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.requests("/v1/agents/uninstall").count, 1, "Not sent again")
    }

    /// A host that reports `uninstalling`: the row says "Uninstalling…" with its progress, the list is read
    /// every few seconds for as long as the host reports it (the two-minute wait is only for hosts that do
    /// not), and the pane says how it ended. An uninstall another device started is followed the same way.
    func testTheHostsUninstallingStateIsFollowedUntilItEnds() async throws {
        let installed = Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.61.0")
        let removing = Self.agent("gemini", "Gemini CLI", state: "uninstalling", version: "0.61.0")
        let qwen = Self.agent("qwen", "Qwen Code", state: "installed", version: "0.4.0")
        let agents = Locked(Self.catalog(Self.claude, installed, qwen))
        let host = scriptedHost(agents)
        host.on("/v1/agents/uninstall") { _ in
            agents.current = Self.catalog(Self.claude, removing, qwen)
            return (202, removing)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        model.uninstallWait = 0.05
        let following = Task { await model.follow() }
        defer { following.cancel() }
        await waitUntil("the first read") { model.catalog != nil }

        await model.uninstall(try XCTUnwrap(model.agent("gemini")))
        let gemini = try XCTUnwrap(model.agent("gemini"))
        XCTAssertEqual(gemini.state, .uninstalling)
        XCTAssertEqual(AgentStatusLine.text(gemini, pending: model.pendingText(gemini)), "Uninstalling…")
        XCTAssertEqual(model.installed.map(\.id), ["claude", "gemini", "qwen"], "Still under Installed until it is gone")
        XCTAssertTrue(model.available.isEmpty)
        XCTAssertTrue(model.isBusy(gemini), "No other change while it runs")
        XCTAssertTrue(model.hasWorkRunning)

        // Read every few seconds while the host reports it, well past the wait for hosts that do not.
        let reads = host.requests("/v1/agents").count
        await waitUntil("reads while it uninstalls") { host.requests("/v1/agents").count >= reads + 5 }
        XCTAssertNil(model.notice, "Not given up on while the host says it runs")
        XCTAssertEqual(model.agent("gemini")?.state, .uninstalling)

        agents.current = Self.catalog(Self.claude, Self.gemini, qwen)
        await waitUntil("the uninstall to end") { model.notice != nil }
        XCTAssertEqual(model.notice?.title, "Uninstalled Gemini CLI")
        XCTAssertEqual(model.notice?.tone, .success)
        XCTAssertTrue(model.uninstalling.isEmpty)
        XCTAssertEqual(model.available.map(\.id), ["gemini"])
        let settled = host.requests("/v1/agents").count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.requests("/v1/agents").count, settled, "No reads once it has ended")

        // Another device's uninstall: followed while the host reports it, and its failure told.
        model.notice = nil
        agents.current = Self.catalog(Self.claude, Self.gemini, Self.agent("qwen", "Qwen Code", state: "uninstalling", version: "0.4.0"))
        await model.refresh()
        XCTAssertEqual(AgentStatusLine.text(try XCTUnwrap(model.agent("qwen")), pending: nil), "Uninstalling…")
        let others = host.requests("/v1/agents").count
        await waitUntil("reads while it uninstalls") { host.requests("/v1/agents").count >= others + 2 }
        agents.current = Self.catalog(Self.claude, Self.gemini,
                                      Self.agent("qwen", "Qwen Code", state: "installed", version: "0.4.0", error: "The folder is in use."))
        await waitUntil("the failure") { model.notice != nil }
        XCTAssertEqual(model.notice?.title, "Couldn’t uninstall Qwen Code")
        XCTAssertEqual(model.notice?.message, "The folder is in use.")

        // An agent the registry no longer lists leaves the list with its uninstall.
        model.notice = nil
        agents.current = Self.catalog(Self.claude, Self.gemini, Self.agent("amp", "Amp", state: "uninstalling", version: "1.0"))
        await model.refresh()
        agents.current = Self.catalog(Self.claude, Self.gemini)
        await waitUntil("the end") { model.notice != nil }
        XCTAssertEqual(model.notice?.title, "Uninstalled Amp")
        XCTAssertEqual(host.requests("/v1/agents/uninstall").count, 1, "This device sent only its own")
    }

    /// A host from before the `uninstalling` state lists the agent as installed until it is gone.
    func testAnUninstallTheHostDoesInTheBackgroundIsFollowedUntilTheListShowsHowItEnded() async throws {
        let installed = Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.61.0")
        let agents = Locked(Self.catalog(Self.claude, installed, Self.agent("qwen", "Qwen Code", state: "installed", version: "0.4.0"),
                                         Self.agent("amp", "Amp", state: "installed", version: "1.0")))
        let host = scriptedHost(agents)
        // The host takes it and works in the background: the list still has the agent installed.
        host.on("/v1/agents/uninstall") { request in
            let id = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["id"] as? String ?? ""
            return (202, Self.agent(id, id, state: "installed", version: "1.0"))
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        let following = Task { await model.follow() }
        defer { following.cancel() }
        await waitUntil("the first read") { model.catalog != nil }

        await model.uninstall(try XCTUnwrap(model.agent("gemini")))
        XCTAssertNil(model.notice, "Nothing is reported done before the host is")
        XCTAssertEqual(model.pendingText(try XCTUnwrap(model.agent("gemini"))), "Uninstalling…")
        XCTAssertTrue(model.isBusy(try XCTUnwrap(model.agent("gemini"))), "No other change while it runs")
        XCTAssertTrue(model.hasWorkRunning, "The list is read while it runs")
        let reads = host.requests("/v1/agents").count
        await waitUntil("reads while it uninstalls") { host.requests("/v1/agents").count >= reads + 2 }
        agents.current = Self.catalog(Self.claude, Self.gemini, Self.agent("qwen", "Qwen Code", state: "installed", version: "0.4.0"),
                                      Self.agent("amp", "Amp", state: "installed", version: "1.0"))
        await waitUntil("the uninstall to end") { model.notice?.title == "Uninstalled Gemini CLI" }
        XCTAssertNil(model.pendingText(try XCTUnwrap(model.agent("gemini"))))
        XCTAssertEqual(model.available.map(\.id), ["gemini"])

        // One that fails says so with the host's error.
        await model.uninstall(try XCTUnwrap(model.agent("qwen")))
        agents.current = Self.catalog(Self.claude, Self.gemini,
                                      Self.agent("qwen", "Qwen Code", state: "installed", version: "0.4.0", error: "The folder is in use."),
                                      Self.agent("amp", "Amp", state: "installed", version: "1.0"))
        await waitUntil("the failure") { model.notice?.title == "Couldn’t uninstall Qwen Code" }
        XCTAssertEqual(model.notice?.message, "The folder is in use.")

        // One the host never finishes stops being waited for, and says so.
        model.uninstallWait = 0.1
        await model.uninstall(try XCTUnwrap(model.agent("amp")))
        await waitUntil("the wait to end") { model.notice?.title == "Amp may still be uninstalling" }
        XCTAssertFalse(model.hasWorkRunning)
        XCTAssertEqual(host.requests("/v1/agents/uninstall").count, 3, "Each sent once")
    }

    func testACancelledReadIsNotAFailureAndAChangeClearsOnlyItsOwnMarker() async throws {
        let agents = Locked(Self.catalog(Self.gemini))
        let host = scriptedHost(agents)
        let cancelNext = Locked(false)
        host.on("/v1/agents") { _ in
            if cancelNext.current {
                cancelNext.current = false
                throw URLError(.cancelled)
            }
            return (200, agents.current)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        cancelNext.current = true
        await model.refresh()
        XCTAssertNil(model.loadIssue, "The pane went away while it read: nothing failed")

        // The connection changes while an install is on its way (the Mac's host stopping sets no client
        // without attaching another host): its answer is dropped and it is no longer on its way.
        let held = Gate()
        let reached = Gate()
        host.on("/v1/agents/install") { _ in
            await reached.open()
            await held.wait()
            return (202, Self.agent("gemini", "Gemini CLI", state: "installing"))
        }
        let install = Task { await model.install(try! XCTUnwrap(model.agent("gemini"))) }
        await arrive(at: reached, "the install")
        XCTAssertTrue(model.changing.contains("gemini"))
        workspace.client = try client(ScriptedHost())
        await held.open()
        await install.value
        XCTAssertFalse(model.changing.contains("gemini"), "No spinner left behind")
        XCTAssertEqual(model.agent("gemini")?.state, .notInstalled, "The old connection's answer is dropped")
    }

    func testRefusalsSayWhyAndAreNotSentAgain() async throws {
        let installed = Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.61.0")
        let agents = Locked(Self.catalog(installed, Self.agent("zed", "Zed Agent")))
        let host = scriptedHost(agents)
        let answer = Locked((409, Self.refusal("agent_busy", "A chat of it is running.")))
        host.on("/v1/agents/update") { _ in answer.current }
        host.on("/v1/agents/install") { _ in answer.current }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let gemini = try XCTUnwrap(model.agent("gemini"))

        await model.update(gemini)
        XCTAssertEqual(model.notice?.title, "Gemini CLI is in use")
        XCTAssertEqual(model.notice?.message, "A chat or terminal of it is running on your Mac. Try again once it has finished.")

        answer.current = (409, Self.refusal("not_managed", "Updated by its own installer."))
        await model.update(gemini)
        XCTAssertEqual(model.notice?.title, "AgentLand doesn’t update Gemini CLI")

        answer.current = (400, Self.refusal("unsupported_platform", "No build for darwin-aarch64."))
        await model.install(try XCTUnwrap(model.agent("zed")))
        XCTAssertEqual(model.notice?.title, "Zed Agent isn’t available for your Mac")
        XCTAssertEqual(model.notice?.message, "No build for darwin-aarch64.")

        let reads = host.requests("/v1/agents").count
        answer.current = (404, Self.refusal("unknown_agent", "No such agent."))
        await model.install(try XCTUnwrap(model.agent("zed")))
        XCTAssertEqual(model.notice?.title, "Zed Agent is no longer listed")
        XCTAssertEqual(host.requests("/v1/agents").count, reads + 1, "The list is read again")

        answer.current = (403, Self.refusal("forbidden", "Not for this device."))
        await model.install(try XCTUnwrap(model.agent("zed")))
        XCTAssertEqual(model.notice?.title, "Couldn’t install Zed Agent")
        XCTAssertEqual(model.notice?.tone, .error)

        XCTAssertEqual(host.requests("/v1/agents/update").count, 2)
        XCTAssertEqual(host.requests("/v1/agents/install").count, 3, "Each refusal came from one request")
    }

    // MARK: The rules of every management screen

    func testChangesAreRefusedWhileOfflineAndAnUncertainOneIsReportedAndNeverSentAgain() async throws {
        let agents = Locked(Self.catalog(Self.gemini))
        let host = scriptedHost(agents)
        host.on("/v1/agents/install") { _ in throw URLError(.networkConnectionLost) }
        let workspace = try await workspace(host)
        let model = workspace.agents
        await model.refresh()
        let gemini = try XCTUnwrap(model.agent("gemini"))

        workspace.reachable = false
        XCTAssertFalse(model.canChange)
        await model.install(gemini)
        XCTAssertTrue(host.requests("/v1/agents/install").isEmpty, "Nothing is sent while the host doesn't answer")
        XCTAssertEqual(model.notice?.title, "your Mac isn’t connected")
        let reads = host.requests("/v1/agents").count
        await model.refresh()
        XCTAssertEqual(host.requests("/v1/agents").count, reads, "Nor read: what was read stays")
        XCTAssertNotNil(model.catalog)

        workspace.reachable = true
        await model.install(gemini)
        XCTAssertEqual(host.requests("/v1/agents/install").count, 1)
        XCTAssertEqual(model.notice?.title, "Gemini CLI may have been installed")
        XCTAssertEqual(model.notice?.message, "The answer didn’t arrive. The list was read again; check it before trying again.")
        XCTAssertEqual(host.requests("/v1/agents").count, reads + 1, "The list is read again")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.requests("/v1/agents/install").count, 1, "Never sent again by itself")
    }

    func testAnswersForAnotherHostOrAnOlderReadAreDropped() async throws {
        let agents = Locked(Self.catalog(Self.gemini))
        let host = scriptedHost(agents)
        let held = Gate()
        let reached = Gate()
        let holdNext = Locked(false)
        host.on("/v1/agents") { _ in
            let answer = agents.current
            if holdNext.current {
                holdNext.current = false
                await reached.open()
                await held.wait()
            }
            return (200, answer)
        }
        let workspace = try await workspace(host)
        let model = workspace.agents

        // An older read that answers after a newer one is dropped.
        holdNext.current = true
        let older = Task { await model.refresh() }
        await arrive(at: reached, "the held read")
        agents.current = Self.catalog(Self.agent("gemini", "Gemini CLI", state: "installed", version: "0.62.0"))
        await model.refresh()
        XCTAssertEqual(model.agent("gemini")?.state, .installed)
        await held.open()
        await older.value
        XCTAssertEqual(model.agent("gemini")?.state, .installed, "The older answer (not installed) is dropped")

        // A change whose answer arrives after the host changed is dropped too.
        let gateInstall = Gate()
        let installReached = Gate()
        host.on("/v1/agents/install") { _ in
            await installReached.open()
            await gateInstall.wait()
            return (202, Self.agent("zed", "Zed", state: "installing"))
        }
        agents.current = Self.catalog(Self.agent("zed", "Zed"))
        await model.refresh()
        let install = Task { await model.install(try! XCTUnwrap(model.agent("zed"))) }
        await arrive(at: installReached, "the install")
        workspace.attach(hostID: "other|device-a", identity: ConnectionIdentity(host: "other", deviceID: "device-a"), client: try client(ScriptedHost()))
        XCTAssertNil(model.catalog, "Everything goes with the host")
        await gateInstall.open()
        await install.value
        XCTAssertNil(model.catalog, "The old host's answer is dropped")
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.changing.isEmpty)
    }

    // MARK: Icons

    func testIconsComeThroughTheHostOnceEachAndAreDrawnFromTheirSVG() async throws {
        let agents = Locked(Self.catalog(Self.gemini, Self.cursor))
        let host = scriptedHost(agents)
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24"><path fill="currentColor" d="M2 2h20v20H2z"/></svg>"#
        let failNext = Locked(false)
        host.on("/v1/agents/icon") { request in
            if failNext.current {
                failNext.current = false
                throw URLError(.networkConnectionLost)
            }
            return ScriptedHost.query(request)["id"] == "gemini" ? (200, svg) : (404, Self.refusal("unknown_agent", "No icon."))
        }
        let workspace = try await workspace(host)
        let icons = workspace.agents.icons
        await icons.load("gemini")
        await icons.load("gemini")
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 1, "Each icon is read once while the host is attached")
        XCTAssertEqual(host.requests("/v1/agents/icon").first?.url?.host, "studio.local", "Through the host, never the registry's CDN")
        guard case let .vector(icon)? = icons.icon(for: "gemini") else { return XCTFail("The SVG is drawn") }
        XCTAssertEqual(icon.viewBox, CGRect(x: 0, y: 0, width: 24, height: 24))

        await icons.load("cursor")
        guard case .missing? = icons.icon(for: "cursor") else { return XCTFail("No icon: the initial shows") }
        await icons.load("cursor")
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 2, "An answered miss is not asked again")

        // A request that did not reach the host is tried again when a row asks next.
        failNext.current = true
        await icons.load("amp")
        XCTAssertNil(icons.icon(for: "amp"))
        await icons.load("amp")
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 4)

        // So is one cancelled as its row went away (URLSession's URLError.cancelled).
        let cancelNext = Locked(true)
        host.on("/v1/agents/icon") { _ in
            if cancelNext.current {
                cancelNext.current = false
                throw URLError(.cancelled)
            }
            return (200, svg)
        }
        await icons.load("zed")
        XCTAssertNil(icons.icon(for: "zed"), "Not recorded as having no icon")
        await icons.load("zed")
        guard case .vector? = icons.icon(for: "zed") else { return XCTFail("Read again and drawn") }

        // Another host: everything read goes.
        workspace.attach(hostID: "other|device-a", identity: ConnectionIdentity(host: "other", deviceID: "device-a"), client: try client(host))
        XCTAssertNil(icons.icon(for: "gemini"))
    }

    /// Home's Chat and Terminal launchers both show Claude's icon. When the row that asked first goes away while
    /// its read is on the way, the read still arrives for the row that asked meanwhile, without a second request.
    func testAnIconStillArrivesWhenTheRowThatAskedFirstGoesAway() async throws {
        let host = scriptedHost(Locked(Self.catalog(Self.gemini)))
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2h20v20H2z"/></svg>"#
        let reached = Gate(), release = Gate()
        host.on("/v1/agents/icon") { _ in
            await reached.open()
            await release.wait()
            if Task.isCancelled { throw URLError(.cancelled) }
            return (200, svg)
        }
        let workspace = try await workspace(host)
        let icons = workspace.agents.icons
        let first = Task { await icons.load("gemini") }
        await reached.wait()
        let second = Task { await icons.load("gemini") }
        for _ in 0..<5 { await Task.yield() }
        first.cancel()
        await release.open()
        await first.value
        await second.value
        guard case .vector? = icons.icon(for: "gemini") else { return XCTFail("The other row gets the icon") }
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 1, "One read for both rows")
    }

    /// 404 not_found: no icon, final while the host is attached. 503 icon_unavailable: the host could not
    /// fetch it in time, so it is not recorded as missing; it is not asked for again before the wait is over,
    /// and a row that shows it asks again then. The host's Content-Type decides how an icon is read.
    func testAnIconTheHostCouldNotFetchInTimeIsAskedForAgainWhileItsRowShows() async throws {
        let agents = Locked(Self.catalog(Self.gemini, Self.cursor))
        let host = scriptedHost(agents)
        // An SVG whose <svg comes after a long comment, served with its type.
        let comment = "<!-- " + String(repeating: "Exported by an editor. ", count: 80) + "-->"
        let svg = comment + #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="currentColor" d="M2 2h20v20H2z"/></svg>"#
        let unavailable = Locked(true)
        host.headers("/v1/agents/icon", ["Content-Type": "image/svg+xml"])
        host.on("/v1/agents/icon") { request in
            if ScriptedHost.query(request)["id"] == "cursor" { return (404, Self.refusal("not_found", "No icon for this agent")) }
            return unavailable.current ? (503, Self.refusal("icon_unavailable", "The icon could not be fetched in time.")) : (200, svg)
        }
        let workspace = try await workspace(host)
        let icons = workspace.agents.icons
        icons.unavailableRetry = 0.3

        await icons.load("cursor")
        guard case .missing? = icons.icon(for: "cursor") else { return XCTFail("404: no icon, the initial shows") }
        await icons.follow("cursor")
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 1, "Final while the host is attached")

        await icons.load("gemini")
        XCTAssertNil(icons.icon(for: "gemini"), "503: not recorded as missing")
        await icons.load("gemini")
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 2, "Not asked again before the wait is over")

        // A row that shows it asks again once the wait is over, and draws what arrives.
        unavailable.current = false
        let row = Task { await icons.follow("gemini") }
        await waitUntil("the icon") { if case .vector? = icons.icon(for: "gemini") { true } else { false } }
        await row.value
        XCTAssertEqual(host.requests("/v1/agents/icon").count, 3, "Asked once more, after the wait")
    }
}
