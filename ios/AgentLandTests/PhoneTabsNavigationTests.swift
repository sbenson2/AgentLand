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

    /// The task switcher (owner, 2026-10-22): every workspace open on this device, the one in use first and the others
    /// as the Workspaces screen lists them, each with its open terminals and chats, then the chats no workspace owns.
    func testSwitcherListsEveryOpenWorkspaceWithItsTerminalsAndChats() throws {
        let (model, _, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        // As the iPhone shell sets it: Files and Git are Workspace's pages, never tasks.
        model.phoneNavigation.drawerHoldsBrowsers = true
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta"), Project(id: "c", name: "Gamma"),
                          Project(id: "d", name: "Delta")]
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let codingChat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "claude:session", title: "Claude Code")
        let hiddenChat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "legacy", title: "Legacy coding chat")
        let movedChat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "moved", title: "Conversation")
        let loneChat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "lone", title: "Lone conversation")
        let excluded = [WorkspaceTabKind.home, .files, .git, .browser, .editor].map {
            WorkspaceTab(kind: $0, projectID: "a", resourceID: $0.rawValue, title: $0.rawValue)
        }
        let server = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "server", title: "Server")
        let notes = WorkspaceTab(kind: .editor, projectID: "c", resourceID: "notes", title: "Notes")
        let files = WorkspaceTab(kind: .files, projectID: "d", title: "Files")
        model.tabs = excluded + [terminal, codingChat, hiddenChat, movedChat, loneChat, server, notes, files]
        model.rememberChatWorkspace(movedChat.resourceID, workspaceID: "a")
        // Used in turn: Gamma, Alpha, then Beta, in use now.
        for id in ["c", "a", "b"] { model.selectProject(id) }

        let navigation = model.phoneNavigation
        let sections = navigation.switcherSections(model: model)
        XCTAssertEqual(sections.map(\.projectID), ["b", "a", "c", nil],
                       "The workspace in use, then the others by last use; Delta has only Files and is not open")
        XCTAssertEqual(sections.dropLast().map(\.projectID), model.workspaces.open.map { Optional($0.id) },
                       "The Workspaces screen's open workspaces, in its order")
        XCTAssertEqual(sections.map(\.title), ["Beta", "Alpha", "Gamma", "Chats"])
        XCTAssertEqual(sections[0].tasks.map(\.id), [server.id])
        XCTAssertEqual(sections[1].tasks.map(\.id), [terminal.id, codingChat.id, movedChat.id],
                       "Terminals and chats only: no editor, browser, Files, Git, Home or hidden coding chat")
        XCTAssertTrue(sections[2].tasks.isEmpty, "An open workspace with no terminal or chat still has its row")
        XCTAssertEqual(sections[3].tasks.map(\.id), [loneChat.id], "A chat no workspace owns is listed under Chats")

        model.closeWorkspace("c")
        XCTAssertEqual(navigation.switcherSections(model: model).map(\.projectID), ["b", "a", nil],
                       "A workspace closed on this device leaves the switcher")
    }

    /// A task row opens that terminal or chat, its workspace becoming the one in use, on its own bottom tab; nothing
    /// closes, and a row the switcher doesn't list (an editor) does nothing.
    func testChoosingASwitcherTaskBringsItsWorkspaceAndItsOwnTab() throws {
        let (model, host, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.phoneNavigation.drawerHoldsBrowsers = true
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let chat = WorkspaceTab(kind: .chat, projectID: "b", resourceID: "codex:review", title: "Review")
        let editor = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "notes", title: "Notes")
        model.tabs = [terminal, chat, editor]
        model.selectedTabID = editor.id
        let navigation = model.phoneNavigation

        navigation.selectSwitcherTask(terminal.id, model: model)
        XCTAssertEqual(model.selectedTabID, terminal.id)
        XCTAssertEqual(model.currentProject?.id, "a", "Another workspace's terminal brings its workspace")
        XCTAssertEqual(PhoneTabDestination.hosting(try XCTUnwrap(model.currentTab).kind), .terminal)
        navigation.selectSwitcherTask(chat.id, model: model)
        XCTAssertEqual(model.selectedTabID, chat.id)
        XCTAssertEqual(model.currentProject?.id, "b")
        XCTAssertEqual(PhoneTabDestination.hosting(try XCTUnwrap(model.currentTab).kind), .chat)
        navigation.selectSwitcherTask(editor.id, model: model)
        XCTAssertEqual(model.selectedTabID, chat.id, "An editor is no row of the switcher")
        XCTAssertEqual(model.tabs.map(\.id), [terminal.id, chat.id, editor.id], "Switching closes nothing")
        XCTAssertTrue(host.requests.isEmpty, "Switching ends nothing on the host")
    }

    /// The switcher's task in another workspace, on the other tab: the stack left behind keeps the old workspace's page
    /// until it is in front again, so no stack changes as its tab leaves the screen (owner, 2026-10-23: "switching from
    /// a chat to terminal in another workspace or vice versa makes the chat or terminal screen go black").
    func testAStackLeftBehindKeepsItsPageUntilItIsInFrontAgain() throws {
        let (model, _, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.phoneNavigation.drawerHoldsBrowsers = true
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "codex:review", title: "Review")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "server", title: "Server")
        let other = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        model.tabs = [chat, terminal, other]
        model.selectedTabID = chat.id
        let navigation = model.phoneNavigation

        navigation.selectSwitcherTask(terminal.id, model: model)
        XCTAssertEqual(model.currentProject?.id, "b")
        XCTAssertTrue(navigation.stackKeepsPage(terminal.id, inFront: true, model: model), "The task in front")
        XCTAssertTrue(navigation.stackKeepsPage(chat.id, inFront: false, model: model),
                      "Chat's stack, on its way out, keeps Alpha's chat")
        XCTAssertFalse(navigation.stackKeepsPage(other.id, inFront: true, model: model),
                       "Terminal's stack in front keeps only Beta's pages")
        XCTAssertFalse(navigation.stackKeepsPage(chat.id, inFront: true, model: model),
                       "Chat chosen again from the tab bar shows Beta's Home")
        model.tabs = [terminal, other]
        XCTAssertTrue(navigation.stackKeepsPage(chat.id, inFront: false, model: model),
                      "A closed task's page stays on a stack that isn't in front")
        XCTAssertFalse(navigation.stackKeepsPage(chat.id, inFront: true, model: model), "and goes once it is")
    }

    /// A workspace's row shows its Home, with it the workspace in use; every tab stays open and its session goes on.
    func testChoosingASwitcherWorkspaceShowsItsHomeWithEveryTabOpen() throws {
        let (model, host, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.phoneNavigation.drawerHoldsBrowsers = true
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let other = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "server", title: "Server")
        model.tabs = [terminal, other]
        model.selectedTabID = terminal.id
        let session = model.terminalSession(for: terminal)
        let navigation = model.phoneNavigation

        navigation.showWorkspaceHome("b", model: model)
        XCTAssertNil(model.selectedTabID, "Home in front")
        XCTAssertEqual(model.currentProject?.id, "b")
        XCTAssertEqual(navigation.switcherWorkspaceID(model: model), "b", "Its Home row is where you are")
        XCTAssertEqual(model.tabs.map(\.id), [terminal.id, other.id], "No tab closes")
        XCTAssertTrue(model.terminalSession(for: terminal) === session, "The other workspace's terminal goes on")
        XCTAssertTrue(host.requests.isEmpty, "Nothing ends on the host")
        XCTAssertEqual(navigation.switcherSections(model: model).map(\.projectID), ["b", "a"])

        navigation.showWorkspaceHome("a", model: model)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.currentProject?.id, "a", "The workspace's own Home, not its last task")
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

    /// End Terminal ends a terminal another device opened as well (owner, 2026-10-22: "always end it on the mac since
    /// the remote app controls"; from 2026-10-15 such a tab closed and left it running): it asks once, saying where it
    /// runs, and the tab closes once the host has ended it.
    func testEndTerminalEndsATerminalOfAnotherDeviceToo() async throws {
        let (model, host, defaults, suite) = try closeFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        var tab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "shared-terminal", title: "Claude Code")
        tab.sharedFrom = SharedOrigin(deviceName: "iPad", onMac: false, routed: false)
        model.open(tab)
        let session = model.terminalSession(for: tab)
        session.setViewActive(true, view: UUID())
        if let ticket = model.presentationTicket {
            model.resolvePresentationOffline()
            XCTAssertTrue(model.completePresentation(ticket))
        }
        XCTAssertEqual(TerminalEndConfirmation.phoneTitle(tab.title), "End “Claude Code”?")
        XCTAssertEqual(TerminalEndConfirmation.message(tab.sharedFrom, hostName: model.hostName),
                       "It's open on another iPad. Ending it stops the program.")
        model.perform(.end, onTerminal: tab.id)
        XCTAssertTrue(session.showEndConfirmation, "End Terminal asks first, whoever opened the terminal")
        await session.endTerminal()
        XCTAssertNil(model.tab(tab.id))
        XCTAssertEqual(host.requests.map { $0.url?.path }, ["/v1/terminal/close"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(host.requests.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["projectId": "p", "terminalId": "shared-terminal"])
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

    /// The task switcher opens once the keyboard has gone (owner, 2026-10-23: "showing black screens"): with no
    /// keyboard going down, at once; with one going down, when it has gone, and once only.
    func testSwitcherWaitsForTheKeyboardToGo() {
        var opened = 0
        KeyboardDepartureWatch().wait(limit: 5) { opened += 1 }
        XCTAssertEqual(opened, 1, "No keyboard on its way down: the switcher opens at once")

        let watch = KeyboardDepartureWatch()
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        watch.wait(limit: 5) { opened += 1 }
        XCTAssertEqual(opened, 1, "The switcher waits while the keyboard goes down")
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(opened, 2, "The switcher opens once the keyboard has gone")
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(opened, 2, "It opens once")
    }

    /// A keyboard that never says it has gone holds the switcher back no longer than the limit.
    func testSwitcherOpensAfterTheLimitWithoutTheKeyboardsWord() {
        let opened = expectation(description: "opened")
        let watch = KeyboardDepartureWatch()
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        watch.wait(limit: 0.1) { opened.fulfill() }
        wait(for: [opened], timeout: 2)
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
