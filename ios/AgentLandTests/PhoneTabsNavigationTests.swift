import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

@MainActor final class PhoneTabsNavigationTests: XCTestCase {
    func testLaunchChoicesKeepGeneralChatAndTerminalRoutesSeparate() {
        let providers = ["opencode", "codex", "claude", "other"].map { PlainChatProvider(id: $0, name: $0) }
        let programs: [TerminalProgram] = [.shell, .codex, .opencode, .claude]
        let chats = PhoneLaunchChoice.offered(in: .chat, providers: providers, programs: programs)
        XCTAssertEqual(chats.map(\.title), ["Claude Code", "Codex"])
        XCTAssertEqual(chats.map(\.action), [.chat(.claude), .chat(.codex)])
        let terminals = PhoneLaunchChoice.offered(in: .terminal, providers: providers, programs: programs)
        XCTAssertEqual(terminals.map(\.title), ["Claude Code", "Codex"])
        XCTAssertEqual(terminals.map(\.action), [.terminal(.claude), .terminal(.codex)])
        XCTAssertEqual(PhoneLaunchChoice.offered(in: .chat, providers: [providers[1]], programs: programs).map(\.id), ["codex"])
        XCTAssertEqual(PhoneLaunchChoice.offered(in: .terminal, providers: providers, programs: [.claude]).map(\.id), ["claude"])
        XCTAssertTrue(PhoneLaunchChoice.offered(in: .chat, providers: [], programs: programs).isEmpty)
        XCTAssertTrue(PhoneLaunchChoice.offered(in: .terminal, providers: providers, programs: []).isEmpty)
    }

    func testTentSpacingKeepsArtworkSizesAndTightropeLayout() {
        let input = HomeLauncherLayout.Input(container: CGSize(width: 402, height: 700),
            safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: 0),
            title: CGSize(width: 380, height: 112), scene: CGSize(width: 404, height: 268),
            quipHeight: 24, actions: CGSize(width: 362, height: 64), isAccessibilitySize: true)
        let original = HomeLauncherLayout.phonePlan(input)
        let tent = HomeLauncherLayout.phonePlan(input, compactTent: true)
        XCTAssertEqual(tent.title.size, original.title.size)
        XCTAssertEqual(tent.scene.size, original.scene.size)
        XCTAssertEqual(tent.title.minY, original.title.minY - 8)
        XCTAssertEqual(tent.scene.minY, original.scene.minY - 24)
        XCTAssertEqual(tent.quip.minY - tent.scene.maxY, tent.actions.minY - tent.quip.maxY, accuracy: 0.01)
        XCTAssertEqual(tent.actions, original.actions)
        XCTAssertFalse(tent.allowsScrolling)
        XCTAssertEqual(HomeLauncherLayout.phonePlan(input, compactTent: false), original)
    }

    func testQuickMenuListsOnlyOpenTasksFromTheCurrentWorkspace() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let file = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "chat", title: "Conversation")
        let other = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "other", title: "Other workspace")
        let excluded = [WorkspaceTabKind.home, .files, .git, .browser].map {
            WorkspaceTab(kind: $0, projectID: "a", resourceID: $0.rawValue, title: $0.rawValue)
        }
        let legacyChat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "legacy", title: "Legacy coding chat")
        model.tabs = excluded + [terminal, other, file, chat, legacyChat]
        model.rememberChatWorkspace(chat.resourceID, workspaceID: "a")
        model.selectedTabID = terminal.id
        XCTAssertEqual(model.phoneNavigation.quickTabs(model: model).map(\.id), [terminal.id, file.id, chat.id])
        model.phoneNavigation.selectQuickTab(other.id, model: model)
        XCTAssertEqual(model.selectedTabID, terminal.id)
        model.phoneNavigation.selectQuickTab(nil, model: model)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.currentProject?.id, "a", "Home preserves the workspace in use")
        XCTAssertEqual(model.phoneNavigation.quickTabs(model: model).map(\.id), [terminal.id, file.id, chat.id])
        model.tabs.removeAll { $0.id == file.id }
        XCTAssertEqual(model.phoneNavigation.quickTabs(model: model).map(\.id), [terminal.id, chat.id])
    }

    func testClosingChatPreservesHistoryAndWorkspaceAssociation() throws {
        let (model, host, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "saved-chat", title: "Saved conversation")
        model.rememberChatWorkspace(chat.resourceID, workspaceID: "p")
        model.open(chat)
        model.close(chat.id, source: .header)
        XCTAssertNil(model.tab(chat.id))
        XCTAssertNil(model.pendingCloseTab)
        XCTAssertTrue(host.requests.isEmpty, "Closing a chat never deletes or aborts it on the host")
        XCTAssertEqual(model.workspaceID(for: chat), "p")
        model.requestResume(.tab(chat))
        XCTAssertEqual(model.currentTab?.resourceID, "saved-chat")
        XCTAssertEqual(model.currentProject?.id, "p")
    }

    func testCloseControlKeepsDirtyFileUntilDiscardIsConfirmed() throws {
        let (model, host, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "notes.txt", title: "notes.txt")
        model.open(file)
        model.noteEditorEdit(file.id, "unsaved draft", dirty: true, baseRevision: "original")
        model.close(file.id, source: .header)
        XCTAssertEqual(model.pendingCloseTab?.id, file.id)
        XCTAssertEqual(model.pendingCloseSource, .header, "The header owns its popover, independently of task rows")
        XCTAssertFalse(model.pendingCloseFromRow)
        model.cancelClose()
        XCTAssertEqual(model.tab(file.id)?.draft, "unsaved draft")
        XCTAssertEqual(model.selectedTabID, file.id)
        model.close(file.id, source: .header)
        model.discardAndClose()
        XCTAssertNil(model.tab(file.id))
        XCTAssertTrue(host.requests.isEmpty, "Discarding a local draft does not alter the host file")
    }

    func testCleanFileClosesImmediately() throws {
        let (model, _, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "notes.txt", title: "notes.txt")
        model.open(file)
        model.close(file.id, source: .header)
        XCTAssertNil(model.pendingCloseTab)
        XCTAssertNil(model.tab(file.id))
    }

    func testTerminalClosesOnlyAfterTheHostAcceptsEnd() async throws {
        let (model, host, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "terminal-to-end", title: "Terminal")
        model.open(tab)
        let session = model.terminalSession(for: tab)
        session.setViewActive(true, view: UUID())
        if let ticket = model.presentationTicket {
            model.resolvePresentationOffline()
            XCTAssertTrue(model.completePresentation(ticket))
        }
        XCTAssertTrue(session.inputActive)
        await session.endTerminal()
        XCTAssertNil(model.tab(tab.id))
        XCTAssertEqual(host.requests.map { $0.url?.path }, ["/v1/terminal/close"])
        let request = try XCTUnwrap(host.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["projectId": "p", "terminalId": "terminal-to-end"])
    }

    func testFailedOrUncertainTerminalEndKeepsItsTabAndReportsTheFailure() async throws {
        for status in [403, 503] {
            let (model, host, defaults, suite) = try closeFixture(status: status)
            defer { defaults.removePersistentDomain(forName: suite) }
            let tab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "keep-terminal", title: "Terminal")
            model.open(tab)
            let session = model.terminalSession(for: tab)
            session.setViewActive(true, view: UUID())
            if let ticket = model.presentationTicket {
                model.resolvePresentationOffline()
                XCTAssertTrue(model.completePresentation(ticket))
            }
            await session.endTerminal()
            XCTAssertNotNil(model.tab(tab.id))
            XCTAssertNotNil(session.issue)
            XCTAssertFalse(session.ending)
            XCTAssertEqual(session.inputBlocked, status == 503)
            XCTAssertEqual(host.requests.count, 1)
        }
    }

    private func closeFixture(status: Int = 200) throws -> (WorkspaceModel, TabCloseHost, UserDefaults, String) {
        let suite = "phone-tab-close-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let host = TabCloseHost(status: status)
        let model = WorkspaceModel(defaults: defaults)
        let identity = ConnectionIdentity(host: "https://tab-close.example", deviceID: "test-device")
        let client = APIClient(address: try ServerAddress(validating: "https://tab-close.example"), token: "test-token", transport: host)
        model.attach(hostID: "tab-close-test", identity: identity, client: client)
        model.projects = [Project(id: "p", name: "Workspace")]
        model.selectedProjectID = "p"
        return (model, host, defaults, suite)
    }

}


private final class TabCloseHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let status: Int
    init(status: Int) { self.status = status }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        return (Data(#"{"accepted":true}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
