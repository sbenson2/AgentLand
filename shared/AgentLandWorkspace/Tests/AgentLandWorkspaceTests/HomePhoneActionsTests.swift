import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

final class HomePhoneActionsTests: XCTestCase {
    func testChatChoicesFollowTheHostAndIncludeStandaloneOnlyWhenOffered() throws {
        let capabilities = try decode(#"{"interactions":true,"terminal":true,"chatProviders":["codex"],"workspaceChats":{"version":1,"providers":[{"id":"codex","name":"Codex","tools":[],"features":[]}]}}"#)
        let choices = HomePhoneActions.choices(for: .newChat, capabilities: capabilities)
        XCTAssertEqual(choices.map(\.destination), [.standaloneChat])
        XCTAssertTrue(HomePhoneActions.choices(for: .newChat, capabilities: try decode(#"{"interactions":true,"terminal":true,"chatProviders":["codex"],"plainChats":{"projectId":"chats"}}"#)).isEmpty,
                      "No Chat without workspaceChats: no Chats-space fallback")
    }

    func testTerminalChoicesNeverInventAnUnavailableProgram() throws {
        let capabilities = try decode(#"{"interactions":true,"terminal":true,"terminalPrograms":["claude"]}"#)
        XCTAssertEqual(HomePhoneActions.choices(for: .newTerminal, capabilities: capabilities).map(\.destination), [.terminal(.shell), .terminal(.claude)])
        XCTAssertTrue(HomePhoneActions.choices(for: .newTerminal, capabilities: try decode(#"{"interactions":true,"terminal":false}"#)).isEmpty)
    }

    func testWorkspacePanelOffersOnlySupportedCreationAlongsideItsWorkspaceRows() throws {
        let capabilities = try decode(#"{"interactions":true,"terminal":true,"projects":{"version":1,"features":["details","create","browse"]}}"#)
        XCTAssertEqual(HomePhoneActions.choices(for: .newWorkspace, capabilities: capabilities).map(\.destination), [.createWorkspace])
        XCTAssertTrue(HomePhoneActions.choices(for: .newWorkspace, capabilities: try decode(#"{"interactions":true,"terminal":true}"#)).isEmpty, "An older host gets its workspace rows without unsupported creation")
    }

    /// Resume (owner, 2026-10-08): only the chats and terminals closed on this device, with no headings; no
    /// Search History, archive, workspaces or Workspaces screen.
    func testResumeListsOnlyWhatWasClosed() throws {
        let everything = try decode(#"{"interactions":true,"terminal":true,"archive":{"version":1,"features":["sync","terminalLogs"]},"projects":{"version":1,"features":["details"]}}"#)
        let recent: [HomePhoneActions.Choice] = [
            .init(id: "homeResumeChat-a", title: "A", symbol: "bubble.left.and.bubble.right", destination: .recentChat("a")),
            .init(id: "homeResumeTerminal-t", title: "zsh", symbol: "terminal", destination: .recentTerminal("t")),
        ]
        let choices = HomePhoneActions.choices(for: .resumeWorkspace, capabilities: everything, recent: recent)
        XCTAssertEqual(choices, recent)
        XCTAssertTrue(HomePhoneActions.choices(for: .resumeWorkspace, capabilities: everything).isEmpty)
    }

    func testAgentRowsNameTheirAgentForItsIcon() throws {
        let capabilities = try decode(#"{"interactions":true,"terminal":true,"chatProviders":["codex"],"terminalPrograms":["claude"],"workspaceChats":{"version":1,"providers":[{"id":"codex","name":"Codex","tools":[],"features":[]}]}}"#)
        XCTAssertEqual(HomePhoneActions.choices(for: .newChat, capabilities: capabilities).map(\.agentID), [nil])
        XCTAssertEqual(HomePhoneActions.choices(for: .newTerminal, capabilities: capabilities).map(\.agentID), [nil, "claude"])
    }

    func testHomeLabelsAndIdentifiers() {
        XCTAssertEqual(HomePhoneActions.Action.allCases.map(\.title), ["Chat", "Terminal", "Workspaces", "Resume"])
        XCTAssertEqual(HomePhoneActions.Action.allCases.map(\.identifier), ["homeNewChat", "homeNewTerminal", "openWorkspace", "homeRecentWork"])
    }

    private func decode(_ json: String) throws -> CapabilitiesResponse {
        try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(json.utf8))
    }
}
