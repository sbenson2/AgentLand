import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandWorkspace

/// New Chat and New Terminal list the host's `agentCatalog` with its names, make chats and terminals of
/// those agents by id, and a chat's sign-in notice opens its agent in a terminal of the chat's workspace
/// (docs/AGENT-CATALOG-PLAN.md, "The apps").
@MainActor final class DynamicAgentsTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated private static let capabilities = #"""
    {"interactions":true,"terminal":true,"terminalPrograms":["shell","opencode","claude","gemini"],
     "chatProviders":["opencode","claude","gemini","goose"],
     "chatFeatures":["events","parts","stop","clientMessageId"],
     "chatProviderInfo":{"opencode":{"transport":"sse","features":["rewind"]},"claude":{"transport":"stream-json","features":[]},
                         "gemini":{"transport":"acp","features":["approvals"]},"goose":{"transport":"acp","features":["approvals"]}},
     "agents":["catalog","install","acp"],
     "agentCatalog":[{"id":"opencode","name":"OpenCode","chat":true,"terminal":true},
                     {"id":"claude","name":"Claude Code","chat":true,"terminal":true},
                     {"id":"gemini","name":"Gemini CLI","chat":true,"terminal":true},
                     {"id":"goose","name":"Goose","chat":true,"terminal":false}]}
    """#

    nonisolated private static func title(of request: URLRequest) -> String {
        ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["title"] as? String ?? ""
    }

    private func workspace(_ host: ScriptedHost) async throws -> WorkspaceModel {
        host.on("/v1/capabilities") { _ in (200, Self.capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p1","name":"Alpha"}]}"#) }
        host.on("/v1/sessions") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let provider = body?["provider"] as? String ?? "opencode"
            return (201, #"{"id":"\#(provider):s1","title":"\#(body?["title"] as? String ?? "")","projectId":"p1","provider":"\#(provider)"}"#)
        }
        host.on("/v1/terminals") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            return (201, #"{"id":"t1","title":"\#(body?["title"] as? String ?? "")","projectId":"p1","status":"running"}"#)
        }
        let suite = "dynamic-agents-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await workspace.refreshProjects()
        workspace.openWorkspace("p1")
        return workspace
    }

    /// Hosts before 2026-10-17 refused a terminal whose update failed (`agent_update_failed`, `agent_update_timeout`);
    /// newer hosts start the installed version with an `updateNotice`, but the refusal is still understood.
    func testPreparationRefusalDoesNotCreateTabAndUncertainDeliveryStillAsksToCheckHistory() async throws {
        for code in ["agent_update_failed", "agent_update_timeout"] {
            let host = ScriptedHost()
            let workspace = try await workspace(host)
            host.on("/v1/terminals") { _ in (409, #"{"error":{"code":"\#(code)","message":"No terminal was created"}}"#) }
            workspace.create(.terminal, program: .opencode)
            await waitUntil("the refusal") { !workspace.creating }
            XCTAssertFalse(workspace.tabs.contains { $0.kind == .terminal })
            XCTAssertTrue(workspace.creationIssue?.contains("No terminal was created") == true)
            XCTAssertTrue(workspace.creationIssue?.contains("switch off automatic updates") == true)
            XCTAssertEqual(host.requests("/v1/terminals").count, 1)
        }
        let host = ScriptedHost()
        let workspace = try await workspace(host)
        host.on("/v1/terminals") { _ in throw URLError(.timedOut) }
        workspace.create(.terminal, program: .opencode)
        await waitUntil("the uncertain answer") { !workspace.creating }
        XCTAssertTrue(workspace.creationIssue?.contains("may have opened") == true)
        XCTAssertEqual(host.requests("/v1/terminals").count, 1)
    }

    /// The host's definite refusals (its cap, a socket path too long, a terminal service that isn't answering, an agent
    /// being installed or removed) say no terminal was created, in the host's words, once, without sending the owner to
    /// Search.
    func testDefiniteCreateRefusalsSayNoTerminalWasCreated() async throws {
        let cap = "16 terminals are open on this Mac across all your devices, including finished ones that haven't been closed. Close one, or end or clear one in AgentLand on the Mac (Settings → Terminals)."
        for (status, code, message) in [(429, "terminal_limit", cap),
                                        (503, "terminal_path_too_long", "AgentLand's terminal service can't start: its socket path is too long."),
                                        (503, "terminals_unavailable", "AgentLand's terminal service isn't answering; your terminals are still running."),
                                        (409, "agent_busy", "This agent is being installed, removed or restored; try again when that ends.")] {
            let host = ScriptedHost()
            let workspace = try await workspace(host)
            host.on("/v1/terminals") { _ in (status, #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#) }
            workspace.create(.terminal, program: .shell)
            await waitUntil("the refusal") { !workspace.creating }
            XCTAssertFalse(workspace.tabs.contains { $0.kind == .terminal })
            XCTAssertEqual(workspace.creationIssue, "No terminal was created. " + message, code)
            XCTAssertEqual(host.requests("/v1/terminals").count, 1)
        }
    }

    func testPreparationNoticeBelongsToNewTerminalSessionAndReturningDoesNotRecreateIt() async throws {
        let host = ScriptedHost()
        let workspace = try await workspace(host)
        host.on("/v1/terminals") { _ in (201, #"{"id":"t1","title":"OpenCode","projectId":"p1","status":"running","updateNotice":"Update deferred while another session is running."}"#) }
        workspace.create(.terminal, program: .opencode)
        await waitUntil("the terminal") { workspace.currentTab?.kind == .terminal }
        let tab = try XCTUnwrap(workspace.currentTab)
        let session = workspace.terminalSession(for: tab)
        XCTAssertEqual(session.issue, "Update deferred while another session is running.")
        host.on("/v1/terminal/output") { _ in (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","exitCode":0}"#) }
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertEqual(session.issue, "Update deferred while another session is running.", "Initial output keeps the preparation notice")
        workspace.openWorkspace("p1")
        workspace.open(tab)
        XCTAssertTrue(workspace.terminalSession(for: tab) === session)
        XCTAssertEqual(host.requests("/v1/terminals").count, 1)
    }

    /// Chat is Claude Code and Codex in the workspace, and only on hosts that list `workspaceChats`; every other agent is
    /// a terminal program.
    func testOtherAgentsAreAvailableOnlyAsTerminals() async throws {
        let host = ScriptedHost()
        let workspace = try await workspace(host)
        let chats = AgentProvider.offered(by: workspace.capabilities)
        XCTAssertEqual(chats.map(\.displayName), ["OpenCode", "Claude Code", "Gemini CLI", "Goose"])
        let terminals = TerminalProgram.offered(by: workspace.capabilities)
        XCTAssertEqual(terminals.map(\.displayName), ["Shell", "OpenCode", "Claude Code", "Gemini CLI"],
                       "An agent without a terminal program is not in New Terminal")

        workspace.create(.chat, provider: chats[2])
        XCTAssertFalse(workspace.creating)
        XCTAssertTrue(host.requests("/v1/sessions").isEmpty, "An ACP agent's chat cannot be made")
        workspace.create(.chat, provider: chats[1])
        workspace.newPlainChat(provider: .claude)
        XCTAssertFalse(workspace.creating)
        XCTAssertTrue(host.requests("/v1/sessions").isEmpty, "Without workspaceChats not even Claude Code's: no fallback")

        workspace.create(.terminal, program: terminals[3])
        await waitUntil("the terminal to open") { workspace.currentTab?.kind == .terminal }
        let terminal = try XCTUnwrap(host.bodies("/v1/terminals").last)
        XCTAssertEqual(terminal["program"] as? String, "gemini", "The program is sent by its name, never a command")
        XCTAssertEqual(terminal["title"] as? String, "Gemini CLI")
    }

    /// The host refuses titles over 200 bytes (desktop/host.go, terminal.go). An agent whose 100-character name
    /// is in another script (300 bytes) still gets its chats and terminals: the chat is made without a title,
    /// so the host names it after its agent as a default title, and the terminal's title is the name cut to
    /// fit at a character.
    func testAnAgentWithALongNameInAnotherScriptStillMakesTerminals() async throws {
        let name = String(repeating: "月", count: 100)
        let host = ScriptedHost()
        let workspace = try await workspace(host)
        host.on("/v1/capabilities") { _ in
            (200, #"""
            {"interactions":true,"terminal":true,"terminalPrograms":["shell","kimi"],"chatProviders":["opencode","kimi"],
             "chatProviderInfo":{"kimi":{"transport":"acp","features":["approvals"]}},"agents":["catalog","install","acp"],
             "agentCatalog":[{"id":"kimi","name":"\#(name)","chat":true,"terminal":true}]}
            """#)
        }
        // As the host: longer titles are refused, and a chat made without one is named after its agent.
        let tooLong = #"{"error":{"code":"invalid_request","message":"Title is too long"}}"#
        host.on("/v1/sessions") { request in
            let sent = Self.title(of: request)
            guard sent.utf8.count <= 200 else { return (400, tooLong) }
            return (201, #"{"id":"kimi:s1","title":"\#(sent.isEmpty ? name : sent)","titleSource":"default","projectId":"p1","provider":"kimi"}"#)
        }
        host.on("/v1/terminals") { request in
            let sent = Self.title(of: request)
            guard sent.utf8.count <= 200 else { return (400, tooLong) }
            return (201, #"{"id":"t1","title":"\#(sent)","projectId":"p1","status":"running"}"#)
        }
        await workspace.refreshProjects()
        let kimi = try XCTUnwrap(AgentProvider.offered(by: workspace.capabilities).first { $0.id == "kimi" })
        XCTAssertEqual(kimi.displayName, name)

        workspace.create(.chat, provider: kimi)
        XCTAssertFalse(workspace.creating)
        XCTAssertTrue(host.requests("/v1/sessions").isEmpty)

        let program = try XCTUnwrap(TerminalProgram.offered(by: workspace.capabilities).first { $0.id == "kimi" })
        workspace.create(.terminal, program: program)
        await waitUntil("the terminal to open") { workspace.currentTab?.kind == .terminal }
        XCTAssertNil(workspace.creationIssue)
        XCTAssertEqual(host.bodies("/v1/terminals").last?["title"] as? String, String(repeating: "月", count: 66),
                       "The name cut to 198 bytes, at a character")
    }

    func testAChatsIDNamesItsAgentAndItsDefaultTitleIsKnownByTheHostsName() async throws {
        XCTAssertEqual(ChatSessionStore.provider(forSession: "ses_abc123"), .opencode, "OpenCode's own chats have no prefix")
        XCTAssertEqual(ChatSessionStore.provider(forSession: "claude:9f1"), .claude)
        XCTAssertEqual(ChatSessionStore.provider(forSession: "codex:thread-1"), .codex)
        XCTAssertEqual(ChatSessionStore.provider(forSession: "gemini:5e2").id, "gemini", "An ACP agent's chat")
        XCTAssertEqual(ChatSessionStore.provider(forSession: "not a token:5e2"), .opencode)
        // The host takes ids of up to 64 characters: a chat of one past 32 is still its agent's, not OpenCode's.
        let long = "agent-with-a-name-longer-than-thirty-two"
        XCTAssertEqual(ChatSessionStore.provider(forSession: long + ":5e2").id, long)
        XCTAssertEqual(ChatSessionStore.provider(forSession: String(repeating: "a", count: 64) + ":5e2").id, String(repeating: "a", count: 64))
        XCTAssertEqual(ChatSessionStore.provider(forSession: String(repeating: "a", count: 65) + ":5e2"), .opencode)

        let host = ScriptedHost()
        let workspace = try await workspace(host)
        let tab = WorkspaceTab(kind: .chat, projectID: "p1", resourceID: "gemini:s7", title: "Gemini CLI chat")
        workspace.open(tab)
        XCTAssertEqual(workspace.chatStore(for: tab).provider.displayName, "Gemini CLI", "Named from the start, before any snapshot")

        // The library goes by the first prompt while a chat has its agent's default title, the host's name too.
        let gemini = AgentProvider.named("gemini", by: workspace.capabilities)
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("Gemini CLI chat", provider: gemini))
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("Gemini CLI", provider: gemini))
        XCTAssertFalse(ChatSessionStore.isDefaultTitle("Fix the login bug", provider: gemini))
        let sessions = [Session(id: "gemini:s7", title: "Gemini CLI chat", projectID: "p1", provider: "gemini"),
                        Session(id: "gemini:s8", title: "Fix the login bug", projectID: "p1", provider: "gemini")]
        XCTAssertEqual(WorkspaceSidebarModel.names(of: sessions, capabilities: workspace.capabilities), ["gemini:s8": "Fix the login bug"],
                       "A default title is not a name")
    }

    func testTheSignInNoticesOpenInTerminalOpensTheAgentInTheChatsWorkspace() async throws {
        let host = ScriptedHost()
        let workspace = try await workspace(host)
        let tab = WorkspaceTab(kind: .chat, projectID: "p1", resourceID: "gemini:s9", title: "Gemini CLI chat")
        workspace.open(tab)
        let store = workspace.chatStore(for: tab)
        store.update(ChatSessionStore.Environment(client: workspace.client, capabilities: workspace.capabilities, reachable: true,
                                                  connectionEpoch: 0, active: false, refreshGeneration: nil))
        // The workspace does not know this chat's agent until its snapshot: say so through its catalog name.
        XCTAssertEqual(AgentProvider.named("gemini", by: workspace.capabilities).terminalProgram(offeredBy: workspace.capabilities)?.id, "gemini")
        XCTAssertNotNil(store.callbacks.openTerminal, "The workspace opens the terminal")

        store.callbacks.openTerminal?(TerminalProgram.named("gemini", by: workspace.capabilities))
        await waitUntil("the terminal to open") { workspace.currentTab?.kind == .terminal }
        let terminal = try XCTUnwrap(host.bodies("/v1/terminals").last)
        XCTAssertEqual(terminal["program"] as? String, "gemini")
        XCTAssertEqual(terminal["projectId"] as? String, "p1", "In the chat's workspace")
        XCTAssertTrue(workspace.tabs.contains { $0.id == tab.id }, "The chat stays open")
    }
}
