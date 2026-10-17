import XCTest
import AgentLandCore
import AgentLandChat
import AgentLandArchive
@testable import AgentLandWorkspace

/// Tab and sidebar names follow what runs in them: a terminal's program title, else its command, else its
/// label, live from this device's renderer and from the host's list; a chat's current title. Every change
/// is saved with the tabs.
@MainActor final class TabNamesTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    /// What the scripted host answers for `/v1/terminals`; tests change it between reads.
    private final class Listing: @unchecked Sendable {
        private let lock = NSLock()
        private var body = #"{"terminals":[]}"#
        var terminals: String {
            get { lock.withLock { body } }
            set { lock.withLock { body = newValue } }
        }
    }

    nonisolated private static func terminal(_ id: String, label: String, programTitle: String? = nil, command: String? = nil) -> String {
        var fields = [#""id":"\#(id)""#, #""title":"\#(label)""#, #""projectId":"p""#, #""status":"running""#]
        if let programTitle { fields.append(#""programTitle":"\#(programTitle)""#) }
        if let command { fields.append(#""command":"\#(command)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "tab-names-\(name)-\(UUID())"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func host(listing: Listing) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, #"{"interactions":true,"terminal":true}"#) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p","name":"Project"},{"id":"q","name":"Other"}]}"#) }
        host.on("/v1/terminals") { _ in (200, listing.terminals) }
        return host
    }

    private func attached(_ host: ScriptedHost, defaults: UserDefaults) async throws -> WorkspaceModel {
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        model.selectProject("p")
        return model
    }

    // MARK: Terminals

    func testTerminalTabsAndRowsTakeTheNamesTheHostLists() async throws {
        let listing = Listing()
        let defaults = try defaults()
        let model = try await attached(host(listing: listing), defaults: defaults)
        // Saved before names followed their terminal: the title is still the label.
        let opencode = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "t1", title: "OpenCode")
        let shell = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "t2", title: "Terminal")
        let elsewhere = WorkspaceTab(kind: .terminal, projectID: "q", resourceID: "t3", title: "Codex")
        for tab in [opencode, shell, elsewhere] { model.open(tab) }
        model.selectProject("p")

        listing.terminals = #"{"terminals":[\#(Self.terminal("t1", label: "OpenCode", programTitle: "Fix the login redirect")),\#(Self.terminal("t2", label: "Terminal", command: "npm test")),\#(Self.terminal("t9", label: "Claude Code", programTitle: "Tidy imports"))]}"#
        await model.sidebar.refreshTerminals()
        XCTAssertEqual(model.tab(opencode.id)?.title, "Fix the login redirect")
        XCTAssertEqual(model.tab(opencode.id)?.label, "OpenCode", "The label stays for the program's layout rules")
        XCTAssertEqual(model.tab(shell.id)?.title, "npm test")
        XCTAssertEqual(model.tab(elsewhere.id)?.title, "Codex", "Another workspace's list names its own tabs")
        let rows = try XCTUnwrap(model.sidebar.terminals)
        XCTAssertEqual(rows.map(model.terminalName), ["Fix the login redirect", "npm test", "Tidy imports"])

        // Saved: another launch shows the latest names before the host answers.
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.tab(opencode.id)?.title, "Fix the login redirect")
        XCTAssertEqual(restored.tab(opencode.id)?.label, "OpenCode")
        XCTAssertEqual(restored.tab(shell.id)?.title, "npm test")

        // Only the program's own name, or nothing: the command, else the label.
        listing.terminals = #"{"terminals":[\#(Self.terminal("t1", label: "OpenCode", programTitle: "OpenCode", command: "opencode")),\#(Self.terminal("t2", label: "Terminal", command: "-zsh"))]}"#
        await model.sidebar.refreshTerminals()
        XCTAssertEqual(model.tab(opencode.id)?.title, "OpenCode")
        XCTAssertEqual(model.tab(shell.id)?.title, "Terminal")
    }

    func testTerminalsOpenedFromTheListCarryTheirNameAndLabel() async throws {
        let listing = Listing()
        listing.terminals = #"{"terminals":[\#(Self.terminal("t1", label: "Claude Code", programTitle: "✳ Write the release notes"))]}"#
        let model = try await attached(host(listing: listing), defaults: try defaults())
        await model.sidebar.refreshTerminals()
        let listed = try XCTUnwrap(model.sidebar.terminals?.first)
        model.open(.terminal(listed, projectID: "p"))
        XCTAssertEqual(model.currentTab?.title, "Write the release notes")
        XCTAssertEqual(model.currentTab?.label, "Claude Code")
    }

    /// SwiftTerm parses the program's OSC 0 and 2 titles; the tab takes each one, cleaned, at once.
    func testAProgramsWindowTitleNamesItsTabAtOnce() async throws {
        let defaults = try defaults()
        let model = try await attached(host(listing: Listing()), defaults: defaults)
        let tab = WorkspaceTab.terminal(RemoteTerminal(id: "t1", title: "OpenCode", projectID: "p", status: .running, exitCode: nil),
                                        projectID: "p")
        model.open(tab)
        let session = model.terminalSession(for: tab)
        let renderer = session.renderer(for: session.rendererID)

        renderer.feed(text: "\u{1b}]0;OC | Fix the login redirect\u{7}")
        await waitUntil("the OSC 0 title") { model.tab(tab.id)?.title == "Fix the login redirect" }
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.tab(tab.id)?.title, "Fix the login redirect", "The live name is saved")

        renderer.feed(text: "\u{1b}]2;✳ Tidy imports\u{1b}\\")
        await waitUntil("the OSC 2 title") { model.tab(tab.id)?.title == "Tidy imports" }

        session.contextTitleAnswered("Clean up Swift imports", readAt: Date())
        renderer.feed(text: "\u{1b}]2;⠙ Tidy imports\u{7}")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.tab(tab.id)?.title, "Clean up Swift imports", "Repeated spinner titles keep the newer summary")

        // An idle program title keeps the last useful task.
        renderer.feed(text: "\u{1b}]0;OpenCode\u{7}")
        await waitUntil("the retained task") { model.tab(tab.id)?.title == "Clean up Swift imports" }
        XCTAssertEqual(model.tab(tab.id)?.label, "OpenCode")
    }

    /// A device's name stays over the program's later titles, as the host keeps it (docs/HOST-API.md "Contextual
    /// terminal names"), until the host's list says the program named the terminal.
    func testADevicesNameStaysOverTheProgramsLaterTitles() async throws {
        let model = try await attached(host(listing: Listing()), defaults: try defaults())
        let tab = WorkspaceTab.terminal(RemoteTerminal(id: "t1", title: "Claude Code", projectID: "p", status: .running, exitCode: nil),
                                        projectID: "p")
        model.open(tab)
        let session = model.terminalSession(for: tab)
        session.programTitleChanged("✳ Tidy imports")
        XCTAssertEqual(model.tab(tab.id)?.title, "Tidy imports")
        session.contextTitleAnswered("Clean up Swift imports", readAt: Date())
        session.programTitleChanged("✳ Deploying")
        XCTAssertEqual(model.tab(tab.id)?.title, "Clean up Swift imports", "This device's name stays")

        let named = RemoteTerminal(id: "t1", title: "Claude Code", projectID: "p", status: .running, exitCode: nil,
                                   programTitle: "Deploying", contextTitle: "Ship the release", contextTitleSource: .device)
        model.followTerminals([named], projectID: "p", asked: Date())
        session.programTitleChanged("✳ Testing")
        XCTAssertEqual(model.tab(tab.id)?.title, "Ship the release", "Another device's name stays too")

        let programs = RemoteTerminal(id: "t1", title: "Claude Code", projectID: "p", status: .running, exitCode: nil,
                                      programTitle: "Testing", contextTitle: "Testing", contextTitleSource: .program)
        model.followTerminals([programs], projectID: "p", asked: Date())
        XCTAssertEqual(model.tab(tab.id)?.title, "Testing")
        session.programTitleChanged("✳ Linting")
        XCTAssertEqual(model.tab(tab.id)?.title, "Linting", "The program names it again once the host says it does")
    }

    func testAListAskedForBeforeALiveTitleDoesNotUndoIt() async throws {
        let model = try await attached(host(listing: Listing()), defaults: try defaults())
        let listed = RemoteTerminal(id: "t1", title: "Codex", projectID: "p", status: .running, exitCode: nil, programTitle: "Old name")
        let tab = WorkspaceTab.terminal(RemoteTerminal(id: "t1", title: "Codex", projectID: "p", status: .running, exitCode: nil), projectID: "p")
        model.open(tab)
        let session = model.terminalSession(for: tab)
        let asked = Date()
        try await Task.sleep(for: .milliseconds(5))
        session.programTitleChanged("⠋ Review the parser")
        XCTAssertEqual(model.tab(tab.id)?.title, "Review the parser")

        model.followTerminals([listed], projectID: "p", asked: asked)
        XCTAssertEqual(model.tab(tab.id)?.title, "Review the parser", "A list asked for earlier is older than the live title")
        model.followTerminals([listed], projectID: "p", asked: Date())
        XCTAssertEqual(model.tab(tab.id)?.title, "Old name", "A list asked for later is the newest word")
    }

    // MARK: Chats

    nonisolated static let ready = #"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#
    nonisolated static func snapshot(_ id: String, title: String, messages: String = "[]") -> String {
        #"{"seq":0,"type":"snapshot","chat":{"id":"\#(id)","title":"\#(title)","provider":"opencode"},"messages":\#(messages),"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#
    }

    /// Streams chat `tab` as its selected, active view would.
    private func stream(_ tab: WorkspaceTab, in model: WorkspaceModel) -> ChatSessionStore {
        let store = model.chatStore(for: tab)
        store.retryDelays = [.milliseconds(20)]
        store.update(ChatSessionStore.Environment(client: model.client, capabilities: model.capabilities, reachable: true,
                                                  connectionEpoch: model.connectionEpoch, active: true, refreshGeneration: nil))
        return store
    }

    private func chatHost(capabilities: String = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"]}"#) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p","name":"Project"}]}"#) }
        host.on("/v1/chat/options") { _ in (200, #"{"models":[],"defaultModel":"","agents":["build"]}"#) }
        return host
    }

    func testAChatTabFollowsItsStreamWithoutAView() async throws {
        let host = chatHost()
        let defaults = try defaults()
        let model = try await attached(host, defaults: defaults)
        let tab = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "ses_1", title: "New chat")
        model.open(tab)
        host.enqueueStream("ses_1", [Self.ready, Self.snapshot("ses_1", title: "Fix login")])
        let store = stream(tab, in: model)
        defer { store.shutdown() }
        await waitUntil("the snapshot's title") { model.tab(tab.id)?.title == "Fix login" }

        host.push("ses_1", #"{"seq":1,"type":"chat.updated","title":"Explain the cookie loop","titleSource":"auto","titleBasis":"a1"}"#)
        await waitUntil("chat.updated") { model.tab(tab.id)?.title == "Explain the cookie loop" }
        XCTAssertEqual(model.chatName(id: "ses_1", listed: "Fix login"), "Explain the cookie loop", "The sidebar row shows the tab's name")
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.tab(tab.id)?.title, "Explain the cookie loop", "Saved tabs keep the latest title")
    }

    func testChatTabsFollowTheLibraryExceptAChatThatStreams() async throws {
        let host = chatHost(capabilities: #"{"interactions":true,"plainChats":{"projectId":"chats"},"terminal":true,"chatFeatures":["events"],"archive":{"version":1,"features":["sync"]}}"#)
        let defaults = try defaults()
        let model = try await attached(host, defaults: defaults)
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        func chat(_ id: String, _ title: String) -> ArchiveChangeItem {
            .chat(ArchiveChatRecord(id: id, projectID: "chats", title: title, createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:00:00.000Z"))
        }
        let prompt = ArchiveChangeItem.message(ArchiveMessageRecord(message: ConversationMessage(
            id: "u1", chatID: "ses_2", turnID: "u1", role: .user, ord: 1, createdAt: "2026-09-26T10:00:00.000Z",
            parts: [ConversationPart(id: "u1p", kind: .text, text: "Add a CSV export to reports")])))
        let items = [chat("ses_1", "Fix the login loop"), chat("ses_2", "New chat"), prompt, chat("ses_3", "Renamed on the iPad")]
        try await store.apply(ArchiveChangesPage(epoch: "e1", changes: items.enumerated().map { ArchiveChange(seq: Int64($0.offset + 1), item: $0.element) },
                                                 cursor: "e1.4"))
        let archive = WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
        model.openArchive({ archive })
        await waitUntil("the copy to attach") { model.archive === archive }
        XCTAssertTrue(model.sidebar.usesArchive)

        let first = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "ses_1", title: "Chat")
        let second = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "ses_2", title: "New chat")
        let streaming = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "ses_3", title: "Chat")
        for tab in [first, second, streaming] { model.open(tab) }
        host.enqueueStream("ses_3", [Self.ready, Self.snapshot("ses_3", title: "Live title")])
        let live = stream(streaming, in: model)
        defer { live.shutdown() }
        await waitUntil("the streaming chat's title") { model.tab(streaming.id)?.title == "Live title" }

        let following = Task { await model.sidebar.followArchive(projectID: model.selectedProjectID) }
        defer { following.cancel() }
        await waitUntil("the library's names") { model.tab(first.id)?.title == "Fix the login loop" }
        XCTAssertEqual(model.tab(second.id)?.title, "Add a CSV export to reports", "A default title goes by the first prompt")
        XCTAssertEqual(model.tab(streaming.id)?.title, "Live title", "A chat that streams follows its stream")
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.tab(first.id)?.title, "Fix the login loop")
        archive.close()
    }

    func testWithoutACopyTheHostsListNamesChatTabs() async throws {
        let host = chatHost(capabilities: #"{"interactions":true,"terminal":true,"plainChats":{"projectId":"chats"}}"#)
        host.on("/v1/sessions") { _ in
            (200, #"{"sessions":[{"id":"ses_1","title":"Fix login","projectId":"chats"},{"id":"ses_2","title":"New chat","projectId":"chats"}]}"#)
        }
        let model = try await attached(host, defaults: try defaults())
        let first = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "ses_1", title: "Chat")
        let second = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "ses_2", title: "Why does the build fail?")
        for tab in [first, second] { model.open(tab) }
        await model.sidebar.refreshSessions()
        XCTAssertEqual(model.tab(first.id)?.title, "Fix login")
        XCTAssertEqual(model.tab(second.id)?.title, "Why does the build fail?", "A default title never replaces a name")
    }
}
