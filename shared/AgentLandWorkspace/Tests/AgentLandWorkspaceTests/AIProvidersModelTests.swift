import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// iPhone and iPad Settings → AI Providers against a scripted host: connected providers first with their
/// model counts, the others under Available, OpenCode not answering, offline, and answers for another host
/// or an older read dropped.
@MainActor final class AIProvidersModelTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated private static let providers = #"""
    {"providers":[{"id":"openrouter","name":"OpenRouter","connected":false,"models":150,"env":["OPENROUTER_API_KEY"]},
                  {"id":"anthropic","name":"Anthropic","connected":true,"models":12,"env":["ANTHROPIC_API_KEY"]},
                  {"id":"zai","name":"Z.AI","connected":false,"models":4},
                  {"id":"deepseek","name":"DeepSeek","connected":true,"models":1,"env":["DEEPSEEK_API_KEY"]},
                  {"id":"local","name":"Local Fixture","connected":true,"models":0}]}
    """#

    private func workspace(_ host: ScriptedHost, capabilities: String = AgentsModelTests.capabilities,
                           name: String = #function) async throws -> WorkspaceModel {
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p1","name":"Alpha"}]}"#) }
        let suite = "providers-model-\(name)-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await workspace.refreshProjects()
        return workspace
    }

    func testConnectedProvidersComeFirstWithTheirModelCountsAndTheOthersAreAvailable() async throws {
        let host = ScriptedHost()
        host.on("/v1/providers") { _ in (200, Self.providers) }
        let workspace = try await workspace(host)
        let model = workspace.aiProviders
        XCTAssertTrue(model.isAvailable)
        await model.refresh()
        XCTAssertEqual(model.connected.map(\.name), ["Anthropic", "DeepSeek", "Local Fixture"], "Connected, by name")
        XCTAssertEqual(model.connected.map(AIProvidersModel.modelCount), ["12 models", "1 model", "No models"])
        XCTAssertEqual(model.available.map(\.name), ["OpenRouter", "Z.AI"], "The others, by name")
        XCTAssertNil(model.issue)

        let older = try await self.workspace(ScriptedHost(), capabilities: #"{"interactions":true,"terminal":true}"#)
        XCTAssertFalse(older.aiProviders.isAvailable, "Hosts without the agent catalog show no providers pane")
    }

    func testOpenCodeNotAnsweringSaysSoAndKeepsWhatWasRead() async throws {
        let host = ScriptedHost()
        let answer = Locked((200, Self.providers))
        host.on("/v1/providers") { _ in answer.current }
        let workspace = try await workspace(host)
        let model = workspace.aiProviders
        await model.refresh()
        answer.current = (503, #"{"error":{"code":"provider_catalog_unavailable","message":"OpenCode did not answer."}}"#)
        await model.refresh()
        XCTAssertEqual(model.issue, "OpenCode isn’t answering on your Mac. Try again once it’s running.")
        XCTAssertEqual(model.connected.count, 3, "What was read stays")
        answer.current = (200, Self.providers)
        await model.refresh()
        XCTAssertNil(model.issue)
    }

    func testNothingIsReadOfflineAndAnswersForAnotherHostOrAnOlderReadAreDropped() async throws {
        let host = ScriptedHost()
        let held = Gate()
        let reached = Gate()
        let holdNext = Locked(false)
        let answer = Locked(Self.providers)
        host.on("/v1/providers") { _ in
            let body = answer.current
            if holdNext.current {
                holdNext.current = false
                await reached.open()
                await held.wait()
            }
            return (200, body)
        }
        let workspace = try await workspace(host)
        let model = workspace.aiProviders

        workspace.reachable = false
        await model.refresh()
        XCTAssertTrue(host.requests("/v1/providers").isEmpty, "Nothing is asked while the host doesn't answer")
        XCTAssertFalse(model.canRead)
        workspace.reachable = true

        // An older read answering after a newer one is dropped.
        holdNext.current = true
        let older = Task { await model.refresh() }
        await arrive(at: reached, "the held read")
        answer.current = #"{"providers":[{"id":"anthropic","name":"Anthropic","connected":true,"models":14}]}"#
        await model.refresh()
        await held.open()
        await older.value
        XCTAssertEqual(model.connected.first?.models, 14, "The newer answer stays")
        XCTAssertTrue(model.available.isEmpty)

        // Another host: the old host's answer is dropped and nothing of it stays.
        let lateHeld = Gate()
        let lateReached = Gate()
        host.on("/v1/providers") { _ in
            await lateReached.open()
            await lateHeld.wait()
            return (200, Self.providers)
        }
        let late = Task { await model.refresh() }
        await arrive(at: lateReached, "the late read")
        workspace.attach(hostID: "other|device-a", identity: ConnectionIdentity(host: "other", deviceID: "device-a"),
                         client: APIClient(address: try ServerAddress(validating: "https://other.local:9841"), token: "t", transport: ScriptedHost()))
        XCTAssertNil(model.providers)
        await lateHeld.open()
        await late.value
        XCTAssertNil(model.providers, "The old host's answer is dropped")
        XCTAssertNil(model.issue)
    }
}
