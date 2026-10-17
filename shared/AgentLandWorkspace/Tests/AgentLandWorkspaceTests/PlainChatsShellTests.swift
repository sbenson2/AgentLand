import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandArchive
@testable import AgentLandWorkspace

/// Chat opens Claude Code and Codex chats in the selected workspace (2026-10-12); other agents' workspace chats stay
/// saved but hidden, and the Chats space's older chats stay readable.
@MainActor final class PlainChatsShellTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "plain-shell-\(name)-\(UUID())"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    nonisolated static let plainCapabilities = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"],"archive":{"version":1,"features":["sync"]},"plainChats":{"projectId":"chats","tools":["websearch","fetch","memory"]},"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":["events"]},{"id":"codex","name":"Codex","tools":[],"features":["events"]}]}}"#
    nonisolated static let olderCapabilities = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"],"archive":{"version":1,"features":["sync"]}}"#

    private func attached(capabilities: String = PlainChatsShellTests.plainCapabilities, projects: String = #"[{"id":"a","name":"App"}]"#,
                          name: String = #function) async throws -> (WorkspaceModel, ScriptedHost) {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":\#(projects)}"#) }
        let model = WorkspaceModel(defaults: try defaults(name))
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        return (model, host)
    }

    /// What the commands ran, in order.
    private func recordingShell(_ calls: @escaping (String) -> Void) -> WorkspaceCommandShell {
        var shell = WorkspaceCommandShell()
        shell.withWorkspace = { action in calls("withWorkspace"); action() }
        shell.create = { kind, _, provider in calls("create \(kind) \(provider.id)") }
        shell.newPlainChat = { calls("newPlainChat") }
        shell.chooseProvider = { calls("chooseProvider") }
        return shell
    }

    func testOtherAgentsWorkspaceTabsStaySavedButDisappearFromNavigation() async throws {
        let (model, _) = try await attached()
        var legacy = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "coding", title: "Old OpenCode conversation")
        legacy.draft = "Unsent text"
        let acp = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "gemini:old", title: "An ACP agent's chat")
        let claude = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "claude:work", title: "Fix the login loop")
        let general = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "general", title: "Dinner ideas")
        model.tabs = [legacy, acp, claude, general]
        model.selectedTabID = legacy.id
        await model.refreshProjects()
        XCTAssertNil(model.selectedTabID, "A hidden agent's chat cannot become the active surface after restore")
        XCTAssertFalse(model.workspaceTabs.contains { $0.id == legacy.id || $0.id == acp.id })
        XCTAssertEqual(model.tab(legacy.id)?.draft, "Unsent text", "Hiding does not delete saved data")
        model.selectProject("a")
        XCTAssertEqual(model.workspaceTabs.map(\.id), [claude.id, general.id], "Claude Code chats are the workspace's tabs")
        model.selectedTabID = claude.id
        await model.refreshProjects()
        XCTAssertEqual(model.selectedTabID, claude.id)
        XCTAssertTrue(model.supportsTab(claude))
        XCTAssertFalse(model.supportsTab(acp))
    }

    func testOpeningAChatRejectsOtherAgentsWorkspaceSessions() async throws {
        let (model, _) = try await attached()
        model.openChat(Session(id: "old", title: "Old coding conversation", projectID: "a"))
        model.openChat(Session(id: "gemini:old", title: "An ACP agent's chat", projectID: "a", provider: "gemini"))
        XCTAssertTrue(model.tabs.isEmpty)
        model.openChat(Session(id: "general", title: "Dinner ideas", projectID: "chats"))
        XCTAssertNotNil(model.pendingSessionResume, "A legacy general chat first needs a workspace")
        XCTAssertNil(model.currentTab)
        model.completeSessionResume(in: "a")
        XCTAssertEqual(model.currentTab?.resourceID, "general")
        XCTAssertEqual(model.selectedProjectID, "a")

        // A Codex chat opens in its own workspace, without asking.
        model.selectedProjectID = nil
        model.openChat(Session(id: "codex:work", title: "Ship it", projectID: "a", provider: "codex"))
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertEqual(model.currentTab?.resourceID, "codex:work")
        XCTAssertEqual(model.selectedProjectID, "a")
    }

    // MARK: Commands

    func testNewChatStartsAPlainChatWithOrWithoutAWorkspace() async throws {
        let (model, _) = try await attached()
        XCTAssertTrue(model.offersPlainChats)
        XCTAssertNil(model.selectedProjectID)
        var calls: [String] = []
        var actions = WorkspaceCommandActions.make(model: model, shell: recordingShell { calls.append($0) })
        XCTAssertTrue(actions.offersPlainChats, "The host offers Chat (workspaceChats)")
        actions.newChat?()
        actions.newChatWith?()
        XCTAssertEqual(calls, ["newPlainChat"], "No workspace asked for a plain chat")

        model.openWorkspace("a")
        calls = []
        actions = WorkspaceCommandActions.make(model: model, shell: recordingShell { calls.append($0) })
        actions.newChat?()
        XCTAssertEqual(calls, ["newPlainChat"], "A workspace open changes nothing")

        // A host with Chat and no workspaces yet: New Chat still (the shell asks for a workspace), nothing else that needs one.
        let (empty, _) = try await attached(projects: "[]", name: "empty")
        actions = WorkspaceCommandActions.make(model: empty, shell: WorkspaceCommandShell())
        XCTAssertNotNil(actions.newChat)
        XCTAssertNil(actions.newChatWith)
        XCTAssertNil(actions.newHomeTab)
        XCTAssertNil(actions.newTerminal)
    }

    func testAHostWithoutGeneralChatDoesNotFallBackToCodingChat() async throws {
        let (model, _) = try await attached(capabilities: Self.olderCapabilities)
        XCTAssertFalse(model.offersPlainChats)
        var calls: [String] = []
        let actions = WorkspaceCommandActions.make(model: model, shell: recordingShell { calls.append($0) })
        XCTAssertFalse(actions.offersPlainChats, "No general-purpose Chat capability")
        actions.newChat?()
        XCTAssertEqual(calls, [])

        let (empty, _) = try await attached(capabilities: Self.olderCapabilities, projects: "[]", name: "empty")
        XCTAssertNil(WorkspaceCommandActions.make(model: empty, shell: WorkspaceCommandShell()).newChat, "No workspaces, no chat")
    }

    // MARK: The library

    private func archive(_ items: [(id: String, project: String, title: String)]) async throws -> WorkspaceArchive {
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        let changes = items.enumerated().map { index, chat in
            ArchiveChange(seq: Int64(index + 1), item: .chat(ArchiveChatRecord(id: chat.id, projectID: chat.project,
                                                                               provider: ChatSessionStore.provider(forSession: chat.id).id, title: chat.title,
                                                                               createdAt: "2026-09-27T10:00:0\(index).000Z",
                                                                               updatedAt: "2026-09-27T10:00:0\(index).000Z")))
        }
        try await store.apply(ArchiveChangesPage(epoch: "e1", changes: changes, cursor: "e1.\(items.count)"))
        return WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
    }

    /// The plain chats get a section of their own while the host offers them, and while this device's copy has
    /// some; the sidebar has a row for each chat it shows, plain or the workspace's.
    func testThePlainChatsHaveTheirOwnSectionWhileOfferedOrKept() async throws {
        let (model, _) = try await attached()
        XCTAssertTrue(model.sidebar.showsPlainChats, "Offered: shown, New Chat first, before any chat is made")

        let (older, _) = try await attached(capabilities: Self.olderCapabilities, name: "older")
        XCTAssertFalse(older.sidebar.showsPlainChats, "Not offered and none kept: the library as before")

        let archive = try await archive([("ses_plain", "chats", "Tides"), ("ses_app", "a", "Fix the login loop"),
                                          ("claude:app", "a", "Fix it with Claude Code")])
        defer { archive.close() }
        older.openArchive({ archive })
        await waitUntil("the copy to attach") { older.archive === archive }
        older.selectProject("a")
        let following = Task { await older.sidebar.followArchive(projectID: "a") }
        await waitUntil("the lists") { !older.sidebar.plainChats.isEmpty }
        following.cancel()
        XCTAssertTrue(older.sidebar.showsPlainChats, "Plain chats this device keeps are still listed, and can be read")
        XCTAssertTrue(older.sidebar.listsChat("ses_plain"))
        XCTAssertTrue(older.sidebar.listsChat("claude:app"), "The workspace's Claude Code chats are listed")
        XCTAssertFalse(older.sidebar.listsChat("ses_app"), "Its OpenCode chats are not")
        XCTAssertFalse(older.sidebar.listsChat("ses_elsewhere"))
    }

    /// Hosts that keep no archive this device copies list their sessions: the Chats space's and the workspace's.
    func testTheHostsListsNameTheChatsTheSidebarShows() async throws {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"],"plainChats":{"projectId":"chats","tools":["memory"]}}"#) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"}]}"#) }
        host.on("/v1/sessions") { request in
            if ScriptedHost.query(request)["projectId"] == "chats" {
                return (200, #"{"sessions":[{"id":"ses_plain","title":"Tides","projectId":"chats"}]}"#)
            }
            return (200, #"{"sessions":[{"id":"claude:app","title":"Fix the login loop","projectId":"a","provider":"claude"},{"id":"ses_app","title":"OpenCode","projectId":"a"}]}"#)
        }
        let model = WorkspaceModel(defaults: try defaults())
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        model.selectProject("a")
        await model.sidebar.refreshSessions()
        XCTAssertFalse(model.sidebar.usesArchive)
        XCTAssertEqual(model.sidebar.session("ses_plain")?.projectID, "chats")
        XCTAssertEqual(model.sidebar.session("claude:app")?.projectID, "a")
        XCTAssertNil(model.sidebar.session("ses_app"), "Other agents' workspace chats are not listed")
        XCTAssertNil(model.sidebar.session("ses_elsewhere"))
        XCTAssertTrue(model.sidebar.listsChat("ses_plain"))
        XCTAssertTrue(model.sidebar.listsChat("claude:app"))
        XCTAssertFalse(model.sidebar.listsChat("ses_app"))
        XCTAssertFalse(model.sidebar.listsChat("ses_elsewhere"))
    }

    // MARK: Offline

    /// New Chat is one tap from Home: offline it sends nothing and says so at once, as the composer does, for a new
    /// terminal and a Continue draft too. Back online, it goes.
    func testANewChatOfflineIsRefusedAtOnce() async throws {
        let (model, host) = try await attached()
        host.on("/v1/sessions") { request in
            request.httpMethod == "POST"
                ? (201, #"{"id":"claude:new","title":"Claude Code chat","projectId":"a","provider":"claude"}"#)
                : (200, #"{"sessions":[]}"#)
        }
        model.selectProject("a")
        model.reachable = false
        model.newPlainChat()
        XCTAssertEqual(model.creationIssue, "Offline · no chat was started")
        XCTAssertFalse(model.creating)
        model.openWorkspace("a")
        model.create(.terminal)
        XCTAssertEqual(model.creationIssue, "Offline · no terminal was started")
        model.creationIssue = nil
        model.openDraft(ContinueDraft(projectID: "chats", sourceChatID: "ses_old", provider: "opencode", model: nil, mode: nil,
                                      effort: nil, title: "Tides (continued)", text: "Go on.", attachment: nil))
        XCTAssertEqual(model.creationIssue, "Offline · no chat was started")
        XCTAssertTrue(host.requests("/v1/sessions").filter { $0.httpMethod == "POST" }.isEmpty, "Nothing was sent")
        XCTAssertTrue(host.requests("/v1/terminals").isEmpty)

        model.reachable = true
        model.newPlainChat()
        await waitUntil("the new chat") { model.currentTab?.resourceID == "claude:new" }
        XCTAssertNil(model.creationIssue)
    }

    // MARK: An older host

    /// An older host lists no plain chats and may have a workspace called chats: it stays a workspace, whose chats
    /// are listed and made with it, with any agent, and whose tab shows its workspace line.
    func testAnOlderHostsWorkspaceCalledChatsStaysAWorkspace() async throws {
        let (model, host) = try await attached(capabilities: Self.olderCapabilities,
                                               projects: #"[{"id":"chats","name":"Chats"},{"id":"a","name":"App"}]"#)
        host.on("/v1/sessions") { request in
            request.httpMethod == "POST"
                ? (201, #"{"id":"ses_new","title":"New chat","projectId":"chats","provider":"claude"}"#)
                : (200, #"{"sessions":[]}"#)
        }
        XCTAssertNil(model.chatsSpaceID)
        XCTAssertFalse(model.isChatsSpace("chats"))
        XCTAssertFalse(model.sidebar.showsPlainChats)

        model.openWorkspace("chats")
        XCTAssertEqual(model.selectedProjectID, "chats")
        model.create(.chat, provider: .claude)
        XCTAssertFalse(model.creating)
        XCTAssertTrue(host.bodies("/v1/sessions").isEmpty, "A workspace named chats does not enable general-purpose Chat")
        XCTAssertEqual(workspaceLine(model), "Workspace: Chats")
    }

    // MARK: The workspace line

    func testAPlainChatInFrontHasNoWorkspaceLine() throws {
        let model = WorkspaceModel(defaults: try defaults())
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "a", name: "App")]
        XCTAssertEqual(workspaceLine(model), "No workspace open")
        let plain = WorkspaceTab(kind: .chat, projectID: PlainChatsCapability.chatsProjectID, resourceID: "ses_plain", title: "Tides")
        model.open(plain)
        XCTAssertNil(workspaceLine(model), "A plain chat belongs to no workspace")

        model.openWorkspace("a")
        XCTAssertEqual(workspaceLine(model), "Workspace: App")
        model.selectedTabID = plain.id
        XCTAssertNil(workspaceLine(model), "Not even with a workspace open")
        model.selectedTabID = nil
        XCTAssertEqual(workspaceLine(model), "Workspace: App", "Home keeps it")
    }
}
