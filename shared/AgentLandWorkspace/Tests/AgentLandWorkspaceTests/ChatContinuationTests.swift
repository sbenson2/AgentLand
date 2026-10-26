import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandWorkspace

/// A Claude Code chat that went on in another (the handoff skill, `ChatInfo.continuedIn`) hands its tab to that chat
/// in place, with its settings, as a terminal's does (owner, 2026-10-26: "handoff needs to work in the chat screen to").
@MainActor final class ChatContinuationTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://test.example", deviceID: "device-a")
    private let hostID = "https://test.example|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func makeWorkspace(_ name: String = #function) throws -> WorkspaceModel {
        let suite = "chat-continuation-tests-\(name)-\(UUID())"
        suites.append(suite)
        let model = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        model.attach(hostID: hostID, identity: identity, client: nil)
        return model
    }

    private func chatTab(_ id: String) -> WorkspaceTab {
        var tab = WorkspaceTab(kind: .chat, projectID: "p", resourceID: id, title: "Fix login")
        tab.chatModelID = "claude/opus"
        tab.chatAgent = "bypassPermissions"
        tab.chatEffort = "high"
        tab.chatModeConfirmed = true
        return tab
    }

    /// The same tab, still selected, now on the new chat, with the model, mode, effort and confirmed mode it had: the
    /// new chat's store starts with them and never asks about the mode again.
    func testTheTabFollowsTheNewChatWithItsSettings() throws {
        let model = try makeWorkspace()
        let tab = chatTab("claude:old")
        model.open(tab)
        let old = model.chatStore(for: tab)
        XCTAssertNotNil(old.callbacks.continued, "The workspace listens for the chat going on")

        model.followChatContinuation(of: tab.id, from: "claude:old", to: "claude:new")

        let followed = try XCTUnwrap(model.tabs.first { $0.id == tab.id })
        XCTAssertEqual(followed.resourceID, "claude:new")
        XCTAssertEqual(model.tabs.filter { $0.kind == .chat }.count, 1, "The same tab, not a second one")
        XCTAssertEqual(model.selectedTabID, tab.id)
        XCTAssertEqual(followed.title, "Fix login", "The new chat has the same title")
        let store = model.chatStore(for: followed)
        XCTAssertFalse(store === old)
        XCTAssertEqual(store.identity.sessionID, "claude:new")
        XCTAssertEqual(store.selectedModelID, "claude/opus")
        XCTAssertEqual(store.selectedMode, "bypassPermissions")
        XCTAssertEqual(store.selectedEffort, "high")
        XCTAssertTrue(store.unattendedModeConfirmed)
    }

    /// Nothing moves once the tab shows another chat or closed, nor when another tab already shows the new chat.
    func testATabThatMovedOnOrAnotherTabWithTheNewChatStays() throws {
        let model = try makeWorkspace()
        let tab = chatTab("claude:old")
        model.open(tab)
        model.followChatContinuation(of: tab.id, from: "claude:other", to: "claude:new")
        XCTAssertEqual(model.tabs.first { $0.id == tab.id }?.resourceID, "claude:old", "The tab shows another chat now")

        let open = chatTab("claude:new")
        model.open(open)
        model.followChatContinuation(of: tab.id, from: "claude:old", to: "claude:new")
        XCTAssertEqual(model.tabs.first { $0.id == tab.id }?.resourceID, "claude:old", "Another tab already shows the new chat")

        model.followChatContinuation(of: UUID(), from: "claude:old", to: "claude:next")
        XCTAssertEqual(model.tabs.map(\.resourceID).sorted(), ["claude:new", "claude:old"])
    }
}
