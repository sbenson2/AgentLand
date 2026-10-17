import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// The centered workspace switcher is the complete map of retained work: Home, standalone chats, then every
/// workspace and every tab it owns. It must not inherit the old sidebar's current-workspace filtering.
@MainActor final class WorkspaceNavigationTests: XCTestCase {
    func testNavigationGroupsEveryOpenTabByItsOwner() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "chats", name: "Chats"), Project(id: "b", name: "Beta")]
        model.capabilities = try? JSONDecoder().decode(
            CapabilitiesResponse.self,
            from: Data(#"{"interactions":true,"terminal":true,"plainChats":{"projectId":"chats"}}"#.utf8)
        )
        let plain = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "plain", title: "Dinner ideas")
        let agentChat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "agent", title: "Fix login")
        let files = WorkspaceTab(kind: .files, projectID: "a", title: "Files")
        let editor = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "README.md", title: "README.md")
        let git = WorkspaceTab(kind: .git, projectID: "a", title: "Git")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "term", title: "Tests")
        let browser = WorkspaceTab(kind: .browser, projectID: "b", resourceID: "3000", title: "Preview")
        let extraHome = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        let unavailable = WorkspaceTab(kind: .editor, projectID: "removed", resourceID: "kept.txt", title: "kept.txt")
        model.tabs = [plain, agentChat, files, editor, git, terminal, browser, extraHome, unavailable]

        let groups = WorkspaceNavigation.groups(model: model)

        XCTAssertEqual(groups.standaloneChats.map(\.id), [plain.id])
        XCTAssertNotNil(model.tab(agentChat.id), "Hiding the removed feature preserves its saved data")
        XCTAssertEqual(groups.workspaces.map(\.project.id), ["a", "b"])
        XCTAssertEqual(groups.workspaces[0].tabs.map(\.id), [files.id, editor.id, git.id, extraHome.id])
        XCTAssertEqual(groups.workspaces[1].tabs.map(\.id), [terminal.id, browser.id])
        XCTAssertEqual(groups.unavailableTabs.map(\.id), [unavailable.id], "no retained tab becomes inaccessible")
    }
}
