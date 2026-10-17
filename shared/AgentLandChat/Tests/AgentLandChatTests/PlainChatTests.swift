import XCTest
import AgentLandCore
@testable import AgentLandChat

/// Plain chats on the chat screen (docs/HOST-API.md "Plain chats"): a chat of the Chats space takes no mode or
/// effort, has no fork and changes no files, continues only into a plain chat of OpenCode's, keeps its composer on
/// its landing, and shows its tools as plain cards; a memory save can be undone from its card.
@MainActor
final class PlainChatTests: XCTestCase {
    private let plain = ChatSessionStore.Identity(hostID: "h", projectID: "chats", sessionID: "ses_plain", tabID: UUID())
    private let coding = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "ses_code", tabID: UUID())

    /// A host with plain chats and every feature a mode or effort could ride on.
    private let host = CapabilitiesResponse(
        interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
        chatFeatures: ["reasoning", "attachments", "queue", "rewind", "events", "parts", "stop", "regenerate", "continue",
                       "clientMessageId", "fork", "modes", "effort"],
        chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind", "restoreFiles", "fork", "approvals", "modes", "effort"])],
        plainChats: PlainChatsCapability(tools: [.websearch, .fetch, .memory], searchProvider: .exa))

    private func client(_ host: ScriptedHost) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "t", transport: host)
    }

    private func environment(_ client: APIClient, capabilities: CapabilitiesResponse? = nil, reachable: Bool = true) -> ChatSessionStore.Environment {
        ChatSessionStore.Environment(client: client, capabilities: capabilities ?? host, reachable: reachable, connectionEpoch: 0,
                                     active: true, refreshGeneration: nil)
    }

    private func eventually(_ what: String = "condition", within seconds: Double = 3, _ condition: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)", file: file, line: line)
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request?.httpBody)) as? [String: Any])
    }

    private static let ready = #"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#
    private static func snapshot(_ id: String = "ses_plain", messages: String = "[]") -> String {
        #"{"seq":0,"type":"snapshot","chat":{"id":"\#(id)","title":"New chat","provider":"opencode"},"messages":\#(messages),"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#
    }

    /// A turn as the host records it: a web search with its sources, a page read, and a memory save.
    static let searchPart = #"{"id":"a1s","kind":"tool","ord":1,"tool":{"name":"websearch","callId":"call_7","status":"completed","title":"tide times lisbon","input":"{\"query\":\"tide times lisbon\"}","truncated":false,"sources":[{"title":"Lisbon tide table","url":"https://tides.example.com/lisbon"},{"title":"example.org","url":"https://example.org/tides"}]}}"#
    static let fetchPart = #"{"id":"a1f","kind":"tool","ord":2,"tool":{"name":"agentland_fetch","callId":"call_8","status":"completed","title":"Read https://www.tides.example.com/lisbon","input":"{\"url\":\"https://tides.example.com/lisbon\"}","sources":[{"title":"Lisbon tide table","url":"https://www.tides.example.com/lisbon?day=1"}]}}"#
    static let memoryPart = #"{"id":"a1m","kind":"tool","ord":3,"tool":{"name":"agentland_memory_save","callId":"call_9","status":"completed","title":"Prefers metric units","input":"{\"text\":\"Prefers metric units\"}","output":"Saved to memory.","truncated":false,"memory":{"id":"mem_4f2a9c1e","text":"Prefers metric units"}}}"#
    static let turn = #"[{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"u1p","kind":"text","text":"Tides in Lisbon? And I use metric."}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","parts":[\#(searchPart),\#(fetchPart),\#(memoryPart),{"id":"a1x","kind":"text","ord":4,"text":"High tide is at 14:02. I will use metric units."}]}]"#

    nonisolated private static func responder(_ request: URLRequest) throws -> (Int, String) {
        switch (request.url?.path, request.httpMethod) {
        case ("/v1/chat/options", _):
            return (200, #"{"models":[{"id":"anthropic/sonnet","name":"Sonnet","provider":"Anthropic","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"anthropic/sonnet","agents":[]}"#)
        case ("/v1/queue", "POST"):
            return (201, #"{"id":"q1","text":"next","createdAt":"2026-09-27T10:00:00.000Z","status":"queued"}"#)
        case ("/v1/chat/regenerate", _):
            return (202, #"{"accepted":true}"#)
        case ("/v1/chat/continue", _):
            return (201, #"{"id":"ses_next","title":"Units (continued)","projectId":"chats","provider":"opencode","parentSessionId":"ses_plain"}"#)
        default:
            return try ScriptedHost.defaultResponder(request)
        }
    }

    private func loadedStore(_ identity: ChatSessionStore.Identity? = nil, messages: String = "[]",
                             responder: @escaping ScriptedHost.Responder = PlainChatTests.responder) async throws -> (ChatSessionStore, ScriptedHost) {
        let identity = identity ?? plain
        let scripted = ScriptedHost(responder: responder)
        scripted.enqueue([Self.ready, Self.snapshot(identity.sessionID, messages: messages)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted)))
        await eventually("content and options") { store.isResolved(for: nil) }
        return (store, scripted)
    }

    // MARK: No mode, effort, fork or files

    /// A host between the 2026-10-12 subscription change and workspace chats still ran Claude Code and Codex in its Chats
    /// space (it lists them in `generalChats` and no `workspaceChats`): those chats keep their composer there. On later
    /// hosts they are read-only (`WorkspaceChatTests.testChatsSpaceChatIsReadOnly`).
    func testRuntimeConversationCapabilitiesAndEffortAreRespected() async throws {
        let identity = ChatSessionStore.Identity(hostID: "h", projectID: "chats", sessionID: "claude:test", tabID: UUID())
        let scripted = ScriptedHost(responder: Self.responder)
        scripted.enqueue([Self.ready, Self.snapshot(identity.sessionID).replacingOccurrences(of: "\"provider\":\"opencode\"", with: "\"provider\":\"claude\"")])
        let supported = ["attachments", "queue", "rewind", "regenerate", "fork", "effort", "events", "parts"]
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["claude"],
            chatFeatures: supported + ["clientMessageId", "modes"],
            chatProviderInfo: ["claude": ChatProviderInfo(transport: "stream-json", features: supported)],
            plainChats: PlainChatsCapability(providers: [PlainChatProvider(id: "claude", name: "Claude Code", features: supported,
                attachmentTypes: ["image/png", "text/plain", "application/pdf"])]))
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted), capabilities: capabilities))
        defer { store.shutdown() }
        await eventually("conversation options") { store.effortChoices == ["low", "high"] }
        XCTAssertEqual(store.modeChoices, [])
        XCTAssertTrue(store.canFork)
        XCTAssertTrue(store.canSendAttachments)
        XCTAssertTrue(store.canQueue)
        XCTAssertFalse(store.rewindRestoresFiles)
        XCTAssertEqual(store.allowedAttachmentMIMEs, ["image/png", "text/plain", "application/pdf"])
        store.selectEffort("high")
        store.setDraft("A general question")
        await store.send()
        let sent = try body(scripted.requests.last { $0.url?.path == "/v1/messages" && $0.httpMethod == "POST" })
        XCTAssertEqual(sent["effort"] as? String, "high")
        XCTAssertNil(sent["mode"])
        XCTAssertNil(sent["agent"])
    }

    func testCodexRunAgainUsesRewindWithoutRegenerationSupport() async throws {
        let identity = ChatSessionStore.Identity(hostID: "h", projectID: "chats", sessionID: "codex:test", tabID: UUID())
        let scripted = ScriptedHost { request in
            if request.url?.path == "/v1/messages/rewind" { return (200, #"{"rewound":true,"filesRestore":"unavailable"}"#) }
            return try Self.responder(request)
        }
        scripted.enqueue([Self.ready, Self.snapshot(identity.sessionID, messages: Self.turn).replacingOccurrences(of: "\"provider\":\"opencode\"", with: "\"provider\":\"codex\"")])
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["claude", "codex"],
            chatFeatures: ["events", "parts", "rewind", "regenerate"],
            chatProviderInfo: ["codex": ChatProviderInfo(transport: "app-server", features: ["rewind"])],
            plainChats: PlainChatsCapability(providers: [PlainChatProvider(id: "codex", name: "Codex", features: ["events", "rewind"])]))
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted), capabilities: capabilities))
        defer { store.shutdown() }
        await eventually("Codex transcript") { store.canRunAgain }
        await store.runAgain()
        XCTAssertEqual(scripted.requests(to: "/v1/messages/rewind").count, 1)
        XCTAssertEqual(scripted.requests(to: "/v1/messages").filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(scripted.requests(to: "/v1/chat/regenerate").count, 0)
    }

    func testAPlainChatSendsNoModeOrEffortAndHasNoFork() async throws {
        let (store, scripted) = try await loadedStore(messages: Self.turn)
        XCTAssertTrue(store.isPlainChat)
        XCTAssertEqual(store.modeChoices, [], "No mode chip or picker")
        XCTAssertEqual(store.effortChoices, [], "No effort, though the model lists some")
        XCTAssertNil(store.selectedEffort)
        XCTAssertFalse(store.canFork, "Forking a plain chat answers 501")
        XCTAssertFalse(store.rewindRestoresFiles, "A plain chat changes no files")
        XCTAssertTrue(store.canRewind, "Edit and Resend stays")
        XCTAssertFalse(store.canOpenSignInTerminal)

        XCTAssertTrue(store.canRunAgain)
        await store.runAgain()
        let regenerated = try body(scripted.requests(to: "/v1/chat/regenerate").last)
        XCTAssertEqual(regenerated["model"] as? String, "anthropic/sonnet")
        XCTAssertNil(regenerated["mode"])
        XCTAssertNil(regenerated["effort"], "Run Again takes no effort either")

        store.setDraft("Next week too?")
        await store.send()
        let sent = try body(scripted.requests(to: "/v1/messages").last)
        XCTAssertEqual(sent["projectId"] as? String, "chats")
        XCTAssertEqual(sent["model"] as? String, "anthropic/sonnet", "The model chip stays")
        XCTAssertNil(sent["agent"])
        XCTAssertNil(sent["mode"])
        XCTAssertNil(sent["effort"])

        store.setDraft("And tomorrow?")
        await store.queueDraft()
        let queued = try body(scripted.requests(to: "/v1/queue").last)
        XCTAssertEqual(queued["text"] as? String, "And tomorrow?")
        XCTAssertNil(queued["agent"], "A queued message takes no agent either")

        // The same host's workspace chat keeps them.
        let (codingStore, _) = try await loadedStore(coding)
        XCTAssertFalse(codingStore.isPlainChat)
        XCTAssertEqual(codingStore.effortChoices, ["low", "high"])
        XCTAssertTrue(codingStore.canFork)
        XCTAssertTrue(codingStore.rewindRestoresFiles)
    }

    /// The Chats space is the one the host's plain chats name. An older host lists none, and a workspace of its may
    /// be called chats: that workspace's chats keep their modes, efforts and agents.
    func testAnOlderHostsWorkspaceCalledChatsHasNoPlainChats() {
        let store = ChatSessionStore(identity: plain)
        XCTAssertTrue(store.isPlainChat, "Before anything is known, chats is the Chats space archived plain chats keep")
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["events", "parts"])
        store.update(ChatSessionStore.Environment(client: nil, capabilities: older, reachable: true, connectionEpoch: 0, active: false,
                                                  refreshGeneration: nil, workspaceIDs: ["chats", "p"]))
        XCTAssertFalse(store.isPlainChat, "A workspace of the host's")
        store.update(ChatSessionStore.Environment(client: nil, capabilities: older, reachable: true, connectionEpoch: 0, active: false,
                                                  refreshGeneration: nil, workspaceIDs: ["p"]))
        XCTAssertTrue(store.isPlainChat, "A host whose chat agent is not confirmed yet: its plain chats stay plain")
        store.update(ChatSessionStore.Environment(client: nil, capabilities: host, reachable: true, connectionEpoch: 0, active: false,
                                                  refreshGeneration: nil, workspaceIDs: ["p"]))
        XCTAssertTrue(store.isPlainChat)
    }

    func testTheRewindAndDeleteWordingOfAPlainChatSaysNothingAboutFiles() async throws {
        let (store, _) = try await loadedStore(messages: Self.turn)
        XCTAssertFalse(ChatRewindCopy.message(provider: store.provider, restoresFiles: store.rewindRestoresFiles).contains("files"))
        XCTAssertFalse(store.runAgainConfirmation.contains("files"))
        XCTAssertFalse(ChatDeleteCopy.message(hostName: "Studio Mac", plainChat: true).contains("Files"))
        XCTAssertEqual(ChatDeleteCopy.message(hostName: "Studio Mac", plainChat: false),
                       "It’s deleted from the archive on Studio Mac and from this device. Files the agent changed stay as they are.")
    }

    func testTheExportNamesNoWorkspaceAndTheSubtitleTheModel() async throws {
        let (store, _) = try await loadedStore(messages: Self.turn)
        XCTAssertEqual(store.subtitle(workspace: "my-app"), "Sonnet", "The model's name: no agent, no workspace")
        XCTAssertEqual(store.subtitleValue(workspace: "my-app"), "Sonnet")
        XCTAssertFalse(store.markdownExport(workspace: "my-app").contains("my-app"))
        XCTAssertTrue(store.markdownExport(workspace: "my-app").contains("_OpenCode · anthropic/sonnet_"))

        let (codingStore, _) = try await loadedStore(coding)
        XCTAssertEqual(codingStore.subtitle(workspace: "my-app"), "OpenCode · my-app")
        XCTAssertTrue(codingStore.markdownExport(workspace: "my-app").contains("my-app"))
    }

    /// Before the host's models are read the subtitle names the saved model by its ID; with no model known it is
    /// empty, and the header's value is "working" alone while the chat works.
    func testThePlainSubtitleBeforeTheModelIsKnown() async throws {
        XCTAssertEqual(ChatSessionStore(identity: plain, model: "anthropic/claude-sonnet-4-5").subtitle(workspace: "my-app"), "claude-sonnet-4-5")
        XCTAssertEqual(ChatSessionStore(identity: plain).subtitle(workspace: "my-app"), "")

        let scripted = ScriptedHost(responder: { request in
            if request.url?.path == "/v1/chat/options" { return (200, #"{"models":[],"defaultModel":"","agents":[]}"#) }
            return try PlainChatTests.responder(request)
        })
        scripted.enqueue([Self.ready, #"{"seq":0,"type":"snapshot","chat":{"id":"ses_plain","title":"New chat","provider":"opencode"},"messages":\#(Self.turn),"hasMore":false,"status":{"state":"running"},"interactions":[],"queue":[]}"#])
        let store = ChatSessionStore(identity: plain)
        store.update(environment(try client(scripted)))
        defer { store.shutdown() }
        await eventually("the working chat") { store.isResolved(for: nil) && store.isWorking }
        XCTAssertEqual(store.subtitleValue(workspace: "my-app"), "working", "Never “, working”")
    }

    // MARK: Continue

    /// Plain → plain only: OpenCode alone, its models, and no mode or effort; another agent sends nothing.
    func testContinuingAPlainChatOffersOpenCodeAloneAndSendsAModelOnly() async throws {
        let (store, scripted) = try await loadedStore(messages: Self.turn)
        XCTAssertEqual(store.continueProviders, [.opencode])
        let loaded = await store.options(for: .opencode)
        let options = try XCTUnwrap(loaded)
        XCTAssertEqual(options.models.map(\.id), ["anthropic/sonnet"], "The Chats space's models")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(scripted.requests(to: "/v1/chat/options").last?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "projectId" }?.value, "chats")
        let claudeOptions = await store.options(for: .claude)
        XCTAssertNil(claudeOptions, "No other agent's models")
        XCTAssertEqual(ChatContinueSheet.modes(options, provider: .opencode, plain: true), [])
        XCTAssertEqual(ChatContinueSheet.efforts(options, model: "anthropic/sonnet", provider: .opencode, plain: true), [])
        XCTAssertEqual(ChatContinueSheet.initialEffort(options, model: "anthropic/sonnet", provider: .opencode, plain: true), "")
        XCTAssertEqual(ChatContinueSheet.efforts(options, model: "anthropic/sonnet", provider: .opencode), ["low", "high"],
                       "A workspace chat's continue keeps the model's efforts")

        let refused = await store.continueChat(provider: .claude, model: "claude/default", mode: nil, effort: nil)
        XCTAssertFalse(refused)
        XCTAssertTrue(scripted.requests(to: "/v1/chat/continue").isEmpty, "A plain chat never continues into another agent")

        var opened: [Session] = []
        store.callbacks.openChat = { opened.append($0) }
        let created = await store.continueChat(provider: .opencode, model: "anthropic/sonnet", mode: "build", effort: "high")
        XCTAssertTrue(created)
        XCTAssertEqual(opened.map(\.projectID), ["chats"])
        let sent = try body(scripted.requests(to: "/v1/chat/continue").last)
        XCTAssertEqual(sent["projectId"] as? String, "chats")
        XCTAssertEqual(sent["provider"] as? String, "opencode")
        XCTAssertEqual(sent["model"] as? String, "anthropic/sonnet")
        XCTAssertNil(sent["mode"])
        XCTAssertNil(sent["effort"])

        let (codingStore, _) = try await loadedStore(coding)
        XCTAssertEqual(codingStore.continueProviders.map(\.id), ["opencode", "claude", "codex"])
    }

    // MARK: Landing

    /// The landing shows over the composer while the chat is empty, typing included, and goes once a message
    /// is on its way. An agent's chat in a workspace opens the same way (owner, 2026-10-07).
    func testTheLandingShowsUntilTheFirstMessageGoes() async throws {
        let (store, scripted) = try await loadedStore()
        XCTAssertTrue(store.showsLanding)
        store.setDraft("What’s a good")
        XCTAssertTrue(store.showsLanding, "Typing keeps the landing over the composer")
        await store.send()
        XCTAssertEqual(scripted.requests(to: "/v1/messages").count, 1)
        XCTAssertFalse(store.showsLanding, "The message on its way replaces the landing")

        let (codingStore, _) = try await loadedStore(coding)
        XCTAssertFalse(codingStore.isPlainChat)
        XCTAssertTrue(codingStore.showsLanding, "A workspace chat opens like a plain chat")
        codingStore.setDraft("Fix the login redirect")
        XCTAssertTrue(codingStore.showsLanding, "and keeps the landing while typing")
    }

    // MARK: Cards

    func testCardsFromRecordedToolParts() throws {
        let search = try Self.tool(Self.searchPart)
        let searched = ChatPlainToolSummary(search)
        XCTAssertEqual(searched.kind, .webSearch)
        XCTAssertEqual(searched.headline, "Searched the web")
        XCTAssertEqual(searched.detail, "“tide times lisbon”")
        XCTAssertEqual(searched.sources.map(\.title), ["Lisbon tide table", "example.org"])
        XCTAssertEqual(searched.sources.map(\.url.absoluteString), ["https://tides.example.com/lisbon", "https://example.org/tides"])
        XCTAssertEqual(searched.accessibilityLabel, "Searched the web, “tide times lisbon”, 2 sources", "A count: the pages are links of their own")

        let read = ChatPlainToolSummary(try Self.tool(Self.fetchPart))
        XCTAssertEqual(read.kind, .readPage)
        XCTAssertEqual(read.headline, "Read tides.example.com", "The site after redirects, without www.")
        XCTAssertEqual(read.sources.map(\.title), ["Lisbon tide table"])
        XCTAssertEqual(read.accessibilityLabel, "Read tides.example.com, 1 source")

        let saved = ChatPlainToolSummary(try Self.tool(Self.memoryPart))
        XCTAssertEqual(saved.kind, .memorySave)
        XCTAssertEqual(saved.headline, "Memory updated")
        XCTAssertEqual(saved.detail, "Prefers metric units")
        XCTAssertEqual(saved.memory, ChatToolMemory(id: "mem_4f2a9c1e", text: "Prefers metric units"))
        XCTAssertEqual(saved.accessibilityLabel, "Memory updated, Prefers metric units")
        XCTAssertFalse(saved.isProblem)
    }

    func testCardsWhileRunningFailedAndStopped() throws {
        let running = ChatPlainToolSummary(ConversationTool(name: "agentland_fetch", status: .running, input: #"{"url":"https://www.nytimes.com/x"}"#))
        XCTAssertEqual(running.headline, "Reading nytimes.com…")
        XCTAssertTrue(running.state.isActive)
        XCTAssertEqual(ChatPlainToolSummary(ConversationTool(name: "websearch", status: .pending)).headline, "Searching the web…")
        XCTAssertEqual(ChatPlainToolSummary(ConversationTool(name: "agentland_fetch", status: .running)).headline, "Reading a web page…")

        let refused = ChatPlainToolSummary(ConversationTool(name: "agentland_memory_save", status: .error, input: #"{"text":"Likes jazz"}"#,
                                                            error: "Memory is off.\nTurn it on in Settings."))
        XCTAssertEqual(refused.headline, "Memory not updated")
        XCTAssertEqual(refused.detail, "Likes jazz", "What it tried to save")
        XCTAssertEqual(refused.problem, "Memory is off. Turn it on in Settings.")
        XCTAssertNil(refused.memory, "A refused save stored nothing, so there is nothing to undo")
        XCTAssertTrue(refused.isProblem)

        let blocked = ChatPlainToolSummary(ConversationTool(name: "agentland_fetch", status: .error, input: #"{"url":"http://192.168.1.1/"}"#,
                                                            error: "That address is on a private network."))
        XCTAssertEqual(blocked.headline, "Couldn’t read 192.168.1.1")
        XCTAssertEqual(blocked.problem, "That address is on a private network.")

        let stopped = ChatPlainToolSummary(ConversationTool(name: "websearch", status: .running, input: #"{"query":"q"}"#), interrupted: true)
        XCTAssertEqual(stopped.headline, "Web search stopped")

        let forgot = ChatPlainToolSummary(ConversationTool(name: "agentland_memory_forget", status: .completed, title: "Prefers metric units"))
        XCTAssertEqual(forgot.headline, "Removed from memory")
        XCTAssertEqual(forgot.detail, "Prefers metric units", "Without the removed entry, the part's title")
        XCTAssertNil(forgot.memory)

        let invalid = ChatPlainToolSummary(ConversationTool(name: "invalid", status: .completed, output: "\nThe tool bash is not available.\n"))
        XCTAssertEqual(invalid.headline, "Couldn’t use a tool")
        XCTAssertEqual(invalid.problem, "The tool bash is not available.")
        XCTAssertTrue(invalid.isProblem)
    }

    func testToolKindsFromTheirNames() {
        XCTAssertEqual(ChatPlainToolKind(toolName: "websearch"), .webSearch)
        XCTAssertEqual(ChatPlainToolKind(toolName: "web_search"), .webSearch)
        XCTAssertEqual(ChatPlainToolKind(toolName: "agentland_fetch"), .readPage)
        XCTAssertEqual(ChatPlainToolKind(toolName: "agentland/fetch"), .readPage)
        XCTAssertEqual(ChatPlainToolKind(toolName: "mcp__agentland__memory_save"), .memorySave)
        XCTAssertEqual(ChatPlainToolKind(toolName: "agentland_memory_forget"), .memoryForget)
        XCTAssertEqual(ChatPlainToolKind(toolName: "invalid"), .invalid)
        XCTAssertEqual(ChatPlainToolKind(toolName: "webfetch"), .other, "OpenCode's own fetch stays denied; it is not the host's")
        XCTAssertEqual(ChatPlainToolSummary(ConversationTool(name: "calendar", status: .completed)).headline, "Used calendar")
    }

    /// In a plain chat each tool stands alone as its card; a workspace chat groups a run of them.
    func testAPlainReplyListsEachToolOnItsOwn() throws {
        let parts = try [Self.searchPart, Self.fetchPart, Self.memoryPart].map { ChatPartModel(try Self.part($0), messageID: "a1") }
        let plain = ChatReplySegment.make(parts, resolved: [], plain: true)
        XCTAssertEqual(plain.map(\.id), ["a1s", "a1f", "a1m"])
        let grouped = ChatReplySegment.make(parts, resolved: [])
        XCTAssertEqual(grouped.map(\.id), ["group-a1s"])
        XCTAssertEqual(ChatPlainToolCard.identifier(.webSearch), "chatWebSearchCard")
        XCTAssertEqual(ChatPlainToolCard.identifier(.memorySave), "chatMemoryCard")
    }

    // MARK: Memory

    func testUndoRemovesTheSavedMemoryOnceAndSaysSo() async throws {
        let (store, scripted) = try await loadedStore(messages: Self.turn, responder: { request in
            if request.url?.path == "/v1/memory", request.httpMethod == "DELETE" { return (200, #"{"removed":true}"#) }
            return try PlainChatTests.responder(request)
        })
        var spoken: [String] = []
        store.announcer = { spoken.append($0) }
        let memory = try XCTUnwrap(ChatToolMemory(id: "mem_4f2a9c1e", text: "Prefers metric units"))
        XCTAssertTrue(store.offersMemoryUndo)
        await store.undoMemory(memory)
        XCTAssertEqual(store.memoryUndo[memory.id], .undone)
        let deletes = scripted.requests.filter { $0.url?.path == "/v1/memory" && $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(deletes.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "mem_4f2a9c1e")
        XCTAssertEqual(spoken, ["Removed from memory"])

        await store.undoMemory(memory)
        XCTAssertEqual(scripted.requests.filter { $0.httpMethod == "DELETE" }.count, 1, "An undone save is not sent again")
    }

    func testUndoOfAMemoryAlreadyGoneCountsAsUndone() async throws {
        let (store, _) = try await loadedStore(messages: Self.turn, responder: { request in
            if request.url?.path == "/v1/memory", request.httpMethod == "DELETE" {
                return (404, #"{"error":{"code":"not_found","message":"No such entry."}}"#)
            }
            return try PlainChatTests.responder(request)
        })
        let memory = try XCTUnwrap(ChatToolMemory(id: "mem_4f2a9c1e", text: "Prefers metric units"))
        await store.undoMemory(memory)
        XCTAssertEqual(store.memoryUndo[memory.id], .undone)
    }

    /// An undo whose answer was lost is not confirmed: Check reads the memory, and only the person sends again.
    func testAnUnconfirmedUndoIsCheckedNeverSentAgainByItself() async throws {
        let entryListed = LockedValue(true)
        let (store, scripted) = try await loadedStore(messages: Self.turn, responder: { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/v1/memory", "DELETE"): return (502, #"{"error":{"code":"bad_gateway","message":"The answer was lost."}}"#)
            case ("/v1/memory", _):
                let entries = entryListed.value ? #"[{"id":"mem_4f2a9c1e","text":"Prefers metric units"}]"# : "[]"
                return (200, #"{"enabled":true,"entries":\#(entries)}"#)
            default: return try PlainChatTests.responder(request)
            }
        })
        let memory = try XCTUnwrap(ChatToolMemory(id: "mem_4f2a9c1e", text: "Prefers metric units"))
        await store.undoMemory(memory)
        XCTAssertEqual(store.memoryUndo[memory.id], .notConfirmed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scripted.requests.filter { $0.httpMethod == "DELETE" }.count, 1, "Nothing is sent again by itself")

        await store.checkMemoryUndo(memory)
        XCTAssertNil(store.memoryUndo[memory.id], "Still listed: Undo shows again")
        XCTAssertEqual(scripted.requests.filter { $0.httpMethod == "DELETE" }.count, 1, "Check only reads")

        await store.undoMemory(memory)
        XCTAssertEqual(store.memoryUndo[memory.id], .notConfirmed)
        entryListed.value = false
        await store.checkMemoryUndo(memory)
        XCTAssertEqual(store.memoryUndo[memory.id], .undone, "Gone from the list: it was undone")
    }

    func testUndoSendsNothingOfflineOrWithoutTheMemoryTool() async throws {
        let (store, scripted) = try await loadedStore(messages: Self.turn)
        let memory = try XCTUnwrap(ChatToolMemory(id: "mem_4f2a9c1e", text: "Prefers metric units"))
        store.update(environment(try client(scripted), reachable: false))
        await store.undoMemory(memory)
        XCTAssertEqual(store.notice?.message, "Offline · memory wasn’t changed")
        XCTAssertNil(store.memoryUndo[memory.id])

        let withoutMemory = CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["events", "parts"],
                                                 plainChats: PlainChatsCapability(tools: [.websearch]))
        store.update(environment(try client(scripted), capabilities: withoutMemory))
        XCTAssertFalse(store.offersMemoryUndo)
        await store.undoMemory(memory)
        XCTAssertTrue(scripted.requests.filter { $0.url?.path == "/v1/memory" }.isEmpty, "The memory routes need `memory` listed")
    }

    /// A save that arrives on the stream is announced once; saves the snapshot brought are not news.
    func testAMemorySaveArrivingOnTheStreamIsAnnouncedOnce() async throws {
        let scripted = ScriptedHost(responder: Self.responder)
        scripted.enqueue([Self.ready, Self.snapshot(messages: Self.turn)])
        let store = ChatSessionStore(identity: plain)
        var spoken: [String] = []
        store.announcer = { spoken.append($0) }
        store.update(environment(try client(scripted)))
        await eventually("the snapshot") { store.isResolved(for: nil) }
        XCTAssertEqual(spoken, [], "The snapshot's save is not news")
        scripted.push(#"{"seq":1,"type":"message.created","message":{"id":"u2","role":"user","turnId":"u2","ord":3,"parts":[{"id":"u2p","kind":"text","text":"I live in Porto."}]}}"#)
        scripted.push(#"{"seq":2,"type":"message.created","message":{"id":"a2","role":"assistant","turnId":"u2","ord":4,"status":"streaming","parts":[]}}"#)
        scripted.push(#"{"seq":3,"type":"part.created","messageId":"a2","part":{"id":"a2m","kind":"tool","ord":1,"tool":{"name":"agentland_memory_save","status":"running","input":"{\"text\":\"Lives in Porto\"}"}}}"#)
        await eventually("the running save") { store.projection.message("a2")?.part("a2m") != nil }
        XCTAssertEqual(spoken, [], "Nothing is said before the save is done, or for the snapshot's")
        scripted.push(#"{"seq":4,"type":"part.updated","messageId":"a2","part":{"id":"a2m","kind":"tool","ord":1,"tool":{"name":"agentland_memory_save","status":"completed","input":"{\"text\":\"Lives in Porto\"}","memory":{"id":"mem_porto","text":"Lives in Porto"}}}}"#)
        await eventually("the announcement") { spoken == ["Memory updated: Lives in Porto"] }
        scripted.push(#"{"seq":5,"type":"part.created","messageId":"a2","part":{"id":"a2x","kind":"text","ord":2,"text":"Noted."}}"#)
        await eventually("the reply text") { store.projection.message("a2")?.part("a2x") != nil }
        XCTAssertEqual(spoken, ["Memory updated: Lives in Porto"], "Announced once")
    }

    /// A forget as the host records it: the part carries the entry it removed.
    static let forgetPart = #"{"id":"a2f","kind":"tool","ord":1,"tool":{"name":"agentland_memory_forget","callId":"call_10","status":"completed","title":"mem_4f2a9c1e","input":"{\"id\":\"mem_4f2a9c1e\"}","output":"Removed from memory.","memory":{"id":"mem_4f2a9c1e","text":"Prefers metric units"}}}"#

    /// A forget's card shows the entry it removed, as one element with no Undo, and is not announced as a save.
    func testAForgetShowsTheEntryItRemovedWithNoUndo() async throws {
        let forgot = ChatPlainToolSummary(try Self.tool(Self.forgetPart))
        XCTAssertEqual(forgot.kind, .memoryForget)
        XCTAssertEqual(forgot.headline, "Removed from memory")
        XCTAssertEqual(forgot.detail, "Prefers metric units", "The removed entry, not the part's title")
        XCTAssertNil(forgot.memory, "Nothing to undo")
        XCTAssertEqual(forgot.accessibilityLabel, "Removed from memory, Prefers metric units")
        XCTAssertEqual(ChatPlainToolCard.identifier(.memoryForget), "chatMemoryCard")

        // The entry was saved in another chat, so this one has not seen it.
        let scripted = ScriptedHost(responder: Self.responder)
        scripted.enqueue([Self.ready, Self.snapshot()])
        let store = ChatSessionStore(identity: plain)
        var spoken: [String] = []
        store.announcer = { spoken.append($0) }
        store.update(environment(try client(scripted)))
        defer { store.shutdown() }
        await eventually("the snapshot") { store.isResolved(for: nil) }
        scripted.push(#"{"seq":1,"type":"message.created","message":{"id":"u2","role":"user","turnId":"u2","ord":1,"parts":[{"id":"u2p","kind":"text","text":"Forget that I use metric."}]}}"#)
        scripted.push(#"{"seq":2,"type":"message.created","message":{"id":"a2","role":"assistant","turnId":"u2","ord":2,"status":"streaming","parts":[\#(Self.forgetPart)]}}"#)
        scripted.push(#"{"seq":3,"type":"part.created","messageId":"a2","part":{"id":"a2x","kind":"text","ord":2,"text":"Done."}}"#)
        await eventually("the reply text") { store.projection.message("a2")?.part("a2x") != nil }
        XCTAssertEqual(spoken, [], "A forget is not a save")
    }

    // MARK: The chat agent

    /// The host refuses a plain chat's Run Again, continue or send with 503 `agent_unavailable` while it has not
    /// confirmed its `chat` agent: each asks the app to read the capabilities again. Another refusal does not.
    func testARefusalForTheChatAgentAsksForTheCapabilitiesAgain() async throws {
        let code = LockedValue("agent_unavailable")
        let (store, scripted) = try await loadedStore(messages: Self.turn, responder: { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/v1/messages", "POST"), ("/v1/chat/regenerate", _), ("/v1/chat/continue", _):
                return (503, #"{"error":{"code":"\#(code.value)","message":"Not now."}}"#)
            default: return try PlainChatTests.responder(request)
            }
        })
        var stale = 0
        store.callbacks.capabilitiesStale = { stale += 1 }
        await store.runAgain()
        XCTAssertEqual(stale, 1, "Run Again")
        let continued = await store.continueChat(provider: .opencode, model: "anthropic/sonnet", mode: nil, effort: nil)
        XCTAssertFalse(continued)
        XCTAssertEqual(stale, 2, "Continue")
        store.setDraft("Hello")
        await store.send()
        XCTAssertEqual(stale, 3, "Send")
        guard case .notSent? = store.pendingSends.last?.delivery else { return XCTFail("The refused message is not sent") }
        XCTAssertEqual(scripted.requests(to: "/v1/messages").count, 1, "Nothing is sent again by itself")

        code.value = "provider_unavailable"
        store.setDraft("Again")
        await store.send()
        XCTAssertEqual(scripted.requests(to: "/v1/messages").count, 2)
        XCTAssertEqual(stale, 3, "Another refusal changes nothing")
    }

    // MARK: Helpers

    static func tool(_ json: String) throws -> ConversationTool {
        try XCTUnwrap(try part(json).tool)
    }

    static func part(_ json: String) throws -> ConversationPart {
        try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
    }
}

/// A value the host double's responder reads while the test changes it.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
