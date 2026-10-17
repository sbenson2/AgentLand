import XCTest
import AgentLandCore
import AgentLandChat
import AgentLandArchive
@testable import AgentLandWorkspace

/// A host that never answers: every request fails as a refused connection.
private final class UnreachableHost: APITransport, @unchecked Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cannotConnectToHost) }
}

/// Answers the routes the workspace's sessions use and counts the requests per path.
private final class CountingHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        lock.withLock { counts[path, default: 0] += 1 }
        let body: String
        switch path {
        case "/v1/files": body = #"{"entries":[{"name":"hello.txt","path":"hello.txt","isDirectory":false,"size":6}]}"#
        case "/v1/file": body = #"{"path":"hello.txt","content":"hello\n","revision":"r1"}"#
        case "/v1/projects": body = #"{"projects":[{"id":"p","name":"Project"}]}"#
        default: body = #"{"accepted":true}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class WorkspaceModelTests: XCTestCase {
    private func makeWorkspace(_ name: String = #function) throws -> (WorkspaceModel, UserDefaults, String) {
        let suite = "workspace-tests-\(name)-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (WorkspaceModel(defaults: defaults), defaults, suite)
    }

    private let identity = ConnectionIdentity(host: "https://test.example", deviceID: "device-a")
    private let hostID = "https://test.example|device-a"

    private func client(_ transport: APITransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: transport)
    }

    // MARK: Tabs and selection

    func testHomeTabsAreIndependentAndClosingOneKeepsTheOther() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WorkspaceTab(kind: .home, projectID: "p", title: "Home 2")
        let second = WorkspaceTab(kind: .home, projectID: "p", title: "Home 3")

        model.open(first)
        model.open(second)
        XCTAssertEqual(model.tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedTabID, second.id)
        model.close(second.id)
        XCTAssertEqual(model.tabs.map(\.id), [first.id])
        XCTAssertEqual(model.selectedTabID, first.id)
    }

    func testOpeningWorkspaceSkipsHomeTabs() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.projects = [Project(id: "p", name: "Project")]
        model.selectedProjectID = "p"
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        model.open(files)
        model.openHomeTab()
        XCTAssertEqual(model.currentTab?.kind, .home)
        model.openWorkspace("p")
        XCTAssertEqual(model.selectedTabID, files.id, "Opening a workspace should resume the last working tab")

        model.close(files.id)
        model.openHomeTab()
        model.openWorkspace("p")
        XCTAssertEqual(model.currentTab?.kind, .files, "A workspace with only Home tabs should open Files")
    }

    func testWorkspaceSwitchRemembersItsOwnTabAndRestoresItsProject() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "a", name: "A"), Project(id: "b", name: "B")]
        model.openWorkspace("a")
        XCTAssertEqual(model.currentTab?.kind, .files)
        // Coding-chat tabs are hidden from the product; use a supported workspace task.
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "terminal", title: "Terminal")
        model.open(terminal)
        model.openWorkspace("b")
        XCTAssertEqual(model.currentTab?.projectID, "b")
        XCTAssertEqual(model.currentTab?.kind, .files)
        model.openWorkspace("a")
        XCTAssertEqual(model.selectedTabID, terminal.id)
        XCTAssertEqual(model.selectedProjectID, "a")
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.selectedTabID, terminal.id)
        XCTAssertEqual(restored.selectedProjectID, "a")
    }

    func testClosingTabStaysInItsWorkspaceAndDoesNotResurrectClosedTab() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.projects = [Project(id: "a", name: "A"), Project(id: "b", name: "B")]
        let files = WorkspaceTab(kind: .files, projectID: "a", title: "Files")
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "chat", title: "Chat")
        let other = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "pty", title: "Terminal")
        model.open(files); model.open(chat); model.open(other)
        model.selectedTabID = chat.id
        XCTAssertEqual(model.selectedProjectID, "a")
        model.close(chat.id)
        XCTAssertEqual(model.selectedTabID, files.id)
        model.openWorkspace("b"); model.openWorkspace("a")
        XCTAssertEqual(model.selectedTabID, files.id)
        XCTAssertFalse(model.tabs.contains { $0.id == chat.id })
    }

    /// The tab commands: drag reorder of the workspace's tabs, Close Other Tabs, ⌘1–9 and ⌃⇥.
    func testTabCommandsReorderCloseOthersAndStepThroughTabs() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "p", name: "P"), Project(id: "q", name: "Q")]
        let other = WorkspaceTab(kind: .files, projectID: "q", title: "Files")
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "pty", title: "Terminal")
        let chat = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "ses", title: "Chat")
        for tab in [other, files, terminal, chat] { model.open(tab) }
        XCTAssertEqual(model.selectedProjectID, "p")

        // Moving the chat first reorders this workspace's tabs; the other workspace's tab keeps its slot.
        model.moveWorkspaceTabs(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(model.workspaceTabs.map(\.id), [chat.id, files.id, terminal.id])
        XCTAssertEqual(model.tabs.first?.id, other.id)
        model.moveWorkspaceTabs(fromOffsets: [7], toOffset: 0)
        XCTAssertEqual(model.workspaceTabs.map(\.id), [chat.id, files.id, terminal.id], "An offset out of range changes nothing")

        // ⌘1 is Home, ⌘2… the tabs in order, ⌘9 the last one.
        model.selectTab(number: 1)
        XCTAssertNil(model.selectedTabID)
        model.selectTab(number: 2)
        XCTAssertEqual(model.selectedTabID, chat.id)
        model.selectTab(number: 9)
        XCTAssertEqual(model.selectedTabID, terminal.id)
        model.selectTab(number: 6)
        XCTAssertEqual(model.selectedTabID, terminal.id, "A number past the last tab changes nothing")

        // ⌃⇥ wraps from the last tab to Home; ⌃⇧⇥ goes back.
        model.selectAdjacentTab(forward: true)
        XCTAssertNil(model.selectedTabID)
        model.selectAdjacentTab(forward: true)
        XCTAssertEqual(model.selectedTabID, chat.id)
        model.selectAdjacentTab(forward: false)
        XCTAssertNil(model.selectedTabID)

        // Close Other Tabs keeps the tab it was asked from and an editor with unsaved changes.
        let editor = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "a.txt", title: "a.txt")
        model.open(editor)
        model.noteEditorEdit(editor.id, "unsaved", dirty: true, baseRevision: "r1")
        let terminalSession = model.terminalSession(for: terminal)
        model.selectedTabID = terminal.id
        model.closeOtherTabs(keeping: files.id)
        XCTAssertEqual(model.workspaceTabs.map(\.id), [files.id, editor.id])
        XCTAssertTrue(model.tabs.contains { $0.id == other.id }, "Another workspace's tabs stay")
        XCTAssertNil(model.sessions.existing(terminal.id), "A closed tab's session ends")
        XCTAssertFalse(terminalSession.active)
        XCTAssertTrue(model.workspaceTabs.contains { $0.id == model.selectedTabID }, "A closed selection moves to a tab that stays")
    }

    /// A surface built again in place: the new view appears before the old one disappears. The
    /// terminal keeps reading and taking input, and the workspace still counts a view on its tab.
    func testARebuiltSurfaceKeepsItsTabActive() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        let terminal = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "pty", title: "Terminal")
        model.open(terminal)
        let session = model.terminalSession(for: terminal)
        let old = UUID(), new = UUID()

        session.setViewActive(true, view: old)
        XCTAssertTrue(session.active)
        session.setViewActive(true, view: new)
        session.setViewActive(false, view: old)
        XCTAssertTrue(session.active, "The old view leaving does not stop the terminal the new view shows")
        session.setViewActive(false, view: new)
        XCTAssertFalse(session.active)

        XCTAssertTrue(model.surfaceView(old, of: terminal.id, shown: true))
        XCTAssertTrue(model.surfaceView(new, of: terminal.id, shown: true))
        XCTAssertTrue(model.surfaceView(old, of: terminal.id, shown: false), "The new view still shows the tab")
        XCTAssertFalse(model.surfaceView(new, of: terminal.id, shown: false))
    }

    func testEditorDraftRetainsOriginalRevisionAcrossRelaunch() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        let tab = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "a.txt", title: "a.txt")
        model.open(tab)
        model.updateEditorDraft(tab.id, "draft", dirty: true, baseRevision: "old-revision")
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.tabs.first?.draft, "draft")
        XCTAssertEqual(restored.tabs.first?.editorBaseRevision, "old-revision")
        XCTAssertEqual(restored.tabs.first?.editorDirty, true)
    }

    func testDirtyEditorCloseWaitsForDiscardAndKeepsImmediateEdit() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        let editor = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "a.txt", title: "a.txt")
        model.open(editor)

        model.noteEditorEdit(editor.id, "last keystrokes", dirty: true, baseRevision: "revision-a")
        model.close(editor.id)

        XCTAssertEqual(model.pendingCloseTab?.id, editor.id)
        XCTAssertEqual(model.tabs.first?.draft, "last keystrokes")
        XCTAssertTrue(model.tabs.first?.editorDirty == true)

        model.cancelClose()
        XCTAssertNil(model.pendingCloseTab)
        XCTAssertEqual(model.tabs.first?.draft, "last keystrokes")

        model.close(editor.id)
        model.discardAndClose()
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.pendingCloseTab)
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertTrue(restored.tabs.isEmpty)
    }

    func testSelectedTabRestoresForTheSameHostIdentity() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        model.open(chat)
        model.open(files)
        model.selectedTabID = chat.id

        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)

        XCTAssertEqual(restored.tabs.map(\.id), [chat.id, files.id])
        XCTAssertEqual(restored.selectedTabID, chat.id)
    }

    func testLaunchingFromAHomeTabReplacesThatTabInPlace() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.projects = [Project(id: "p", name: "Project")]
        model.selectedProjectID = "p"
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        model.open(chat)
        model.openHomeTab()
        let home = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(home.kind, .home)

        let terminal = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "t", title: "Terminal")
        model.open(terminal)
        XCTAssertEqual(model.tabs.map(\.id), [chat.id, terminal.id], "The terminal takes the Home tab's place")
        XCTAssertEqual(model.selectedTabID, terminal.id)

        model.openHomeTab()
        let second = try XCTUnwrap(model.currentTab)
        model.openHomeTab()
        XCTAssertEqual(model.tabs.filter { $0.kind == .home }.count, 2, "Adding a Home from a Home adds a tab")
        let third = try XCTUnwrap(model.currentTab)
        model.open(WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat"))
        XCTAssertEqual(model.selectedTabID, chat.id, "An already open surface is shown, not duplicated")
        XCTAssertFalse(model.tabs.contains { $0.id == third.id }, "The Home that asked for it is spent")
        XCTAssertTrue(model.tabs.contains { $0.id == second.id })

        model.selectedTabID = nil
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        model.open(files)
        XCTAssertEqual(model.tabs.last?.id, files.id, "The permanent Home is never replaced")
        XCTAssertTrue(model.tabs.contains { $0.id == second.id })

        model.selectedTabID = second.id
        let launcher = model.launchingHomeTabID
        model.selectedTabID = chat.id
        let late = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "late", title: "Late")
        model.open(late, replacingHome: launcher)
        XCTAssertFalse(model.tabs.contains { $0.id == second.id }, "An asynchronous launch replaces the Home it started from")
        XCTAssertEqual(model.selectedTabID, late.id)
    }

    func testDetachingKeepsTheSavedTabsAndForgettingRemovesThem() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(model.hostIssue, nil)
        XCTAssertTrue(model.metadataResolved, "Without a client the workspace resolves at once")
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        model.open(files)
        model.detach()
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.hostID)
        model.attach(hostID: hostID, identity: identity, client: nil, issue: "This host needs to be paired again.")
        XCTAssertEqual(model.tabs.map(\.id), [files.id], "Leaving a host does not delete its tabs")
        XCTAssertEqual(model.hostIssue, "This host needs to be paired again.")
        model.detach()
        model.forgetSavedState(for: identity)
        model.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    // MARK: Session registry

    /// Sessions belong to the workspace, not to the views: looking one up again (a tab switch, a lock,
    /// a rebuilt view) returns the same object; closing the tab or changing host ends it.
    func testSessionsLiveUntilTheirTabClosesOrTheHostChanges() throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        var chatTab = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "ses_1", title: "Fix login", draft: "half-typed")
        chatTab.chatModelID = "a/b"
        chatTab.chatAgent = "plan"
        let terminalTab = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "pty", title: "Terminal")
        let editorTab = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "a.txt", title: "a.txt")
        let filesTab = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        for tab in [chatTab, terminalTab, editorTab, filesTab] { model.open(tab) }

        let store = model.chatStore(for: chatTab)
        let terminal = model.terminalSession(for: terminalTab)
        let editor = model.editorSession(for: editorTab)
        let files = model.filesSession(for: filesTab)
        XCTAssertEqual(model.sessions.count, 4)
        XCTAssertEqual(store.draft, "half-typed", "A saved draft comes back in the composer")
        XCTAssertEqual(store.selectedModelID, "a/b")
        XCTAssertEqual(store.selectedMode, "plan")

        store.setDraft("still typing")
        model.selectedTabID = filesTab.id
        model.locked = true
        model.selectedTabID = chatTab.id
        model.locked = false
        XCTAssertTrue(model.chatStore(for: chatTab) === store, "Switching tabs and locking keep the chat store")
        XCTAssertTrue(model.terminalSession(for: terminalTab) === terminal)
        XCTAssertTrue(model.editorSession(for: editorTab) === editor)
        XCTAssertTrue(model.filesSession(for: filesTab) === files)
        XCTAssertEqual(model.chatStore(for: chatTab).draft, "still typing")
        store.flushDraft()
        XCTAssertEqual(model.tab(chatTab.id)?.draft, "still typing", "Drafts are saved with the tab")

        model.close(terminalTab.id)
        XCTAssertNil(model.sessions.existing(terminalTab.id), "Closing the tab ends its session")
        XCTAssertFalse(terminal.active, "An ended terminal session stops reading and sending")
        XCTAssertTrue(model.chatStore(for: chatTab) === store, "Other tabs keep theirs")

        model.close(chatTab.id)
        XCTAssertNil(model.existingChatStore(chatTab.id))
        let reopened = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "ses_2", title: "Other")
        model.open(reopened)
        let other = model.chatStore(for: reopened)
        XCTAssertFalse(other === store)

        model.attach(hostID: "https://other.example|device-b", identity: ConnectionIdentity(host: "https://other.example", deviceID: "device-b"), client: nil)
        XCTAssertEqual(model.sessions.count, 0, "Changing host ends every session")
        XCTAssertNil(model.existingChatStore(reopened.id))
    }

    /// A rebuilt Files or Editor view asks its session to load again; a listing or document already
    /// resolved for the same refresh generation is not fetched twice.
    func testRebuiltSurfacesDoNotReloadResolvedContent() async throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = CountingHost()
        model.attach(hostID: hostID, identity: identity, client: try client(host))
        let filesTab = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        let editorTab = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "hello.txt", title: "hello.txt")
        model.open(filesTab)
        model.open(editorTab)

        let files = model.filesSession(for: filesTab)
        await files.loadIfNeeded()
        await model.filesSession(for: filesTab).loadIfNeeded()
        XCTAssertEqual(files.entries.map(\.path), ["hello.txt"])
        XCTAssertEqual(host.count("/v1/files"), 1, "The same folder and generation are listed once")

        let editor = model.editorSession(for: editorTab)
        await editor.loadIfNeeded()
        editor.content = "hello\nmore"
        await model.editorSession(for: editorTab).loadIfNeeded()
        XCTAssertEqual(host.count("/v1/file"), 1, "The same document generation is fetched once")
        XCTAssertEqual(editor.content, "hello\nmore", "A rebuilt editor keeps the typed text")

        model.reloadTab(editorTab.id)
        await editor.loadIfNeeded()
        XCTAssertEqual(host.count("/v1/file"), 2, "Reload starts a new generation, which fetches again")
    }

    // MARK: The device's copy

    /// A copy holding one chat with one message, as the change feed fills it.
    private func savedChatStore() async throws -> ArchiveStore {
        let store = try ArchiveStore.inMemory(hostKey: identity.storageKey)
        let time = "2026-09-24T12:00:00.000Z"
        let chat = ArchiveChatRecord(id: "s", projectID: "p", provider: "opencode", title: "Saved chat", model: nil, parentID: nil,
                                     relation: nil, createdAt: time, updatedAt: time)
        let message = ConversationMessage(id: "m", chatID: "s", turnID: "m", role: .user, status: .complete, ord: 1, createdAt: time,
                                          provider: "opencode", model: nil,
                                          parts: [ConversationPart(id: "m-text", kind: .text, ord: 0, text: "Saved on this device")])
        try await store.apply(ArchiveChangesPage(epoch: "e1", resync: false,
                                                 changes: [ArchiveChange(seq: 1, item: .chat(chat)),
                                                           ArchiveChange(seq: 2, item: .message(ArchiveMessageRecord(message: message, hidden: false)))],
                                                 cursor: "e1.2", hasMore: false))
        return store
    }

    /// Attaching a host does not wait for its copy to open. A chat made while the copy opens shows its
    /// saved transcript once the copy has opened (the host never answers here), and the copy attaches then.
    func testAChatMadeWhileTheCopyOpensReadsItOnceOpen() async throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try await savedChatStore()
        let client = try client(UnreachableHost())
        model.attach(hostID: hostID, identity: identity, client: client)
        let gate = Gate()
        var opened: [WorkspaceArchive] = []
        model.openArchive({
            await gate.wait()
            return WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
        }, opened: { opened.append($0) })
        XCTAssertNil(model.archive, "The host is attached before its copy opens")

        let tab = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        model.open(tab)
        let chat = model.chatStore(for: tab)
        chat.update(ChatSessionStore.Environment(client: client, capabilities: nil, reachable: true, connectionEpoch: 0, active: true,
                                                 refreshGeneration: nil))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(chat.hasContent, "The saved transcript waits for the copy to open")

        await gate.open()
        let deadline = Date().addingTimeInterval(3)
        while !chat.hasContent, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(chat.hasContent, "The chat shows the copy's transcript once the copy has opened")
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(model.archive === opened.first, "The opened copy is the workspace's")
        chat.shutdown()
    }

    /// A copy that opens after another host (or none) was attached is not attached.
    func testACopyThatOpensAfterTheHostChangedIsDropped() async throws {
        let (model, defaults, suite) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try await savedChatStore()
        model.attach(hostID: hostID, identity: identity, client: try client(UnreachableHost()))
        let gate = Gate()
        var opened = 0
        var made: WorkspaceArchive?
        model.openArchive({
            await gate.wait()
            made = WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
            return made
        }, opened: { _ in opened += 1 })

        model.attach(hostID: "https://other.example|device-b", identity: ConnectionIdentity(host: "https://other.example", deviceID: "device-b"),
                     client: nil)
        await gate.open()
        let deadline = Date().addingTimeInterval(1)
        while made == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(made, "The copy finished opening")
        XCTAssertNil(model.archive, "A copy of the previous host is not attached")
        XCTAssertEqual(opened, 0)
    }
}
