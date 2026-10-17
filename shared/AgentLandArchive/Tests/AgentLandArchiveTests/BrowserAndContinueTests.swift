import Foundation
import XCTest
import AgentLandChat
import AgentLandCore
@testable import AgentLandArchive

/// A host answering archive routes from a closure, recording what it got.
final class ArchiveHost: APITransport, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) throws -> (Int, String)
    private let lock = NSLock()
    private var responder: Responder
    private var log: [URLRequest] = []

    init(_ responder: @escaping Responder) { self.responder = responder }

    func respond(_ responder: @escaping Responder) { lock.withLock { self.responder = responder } }
    func requests(to path: String) -> [URLRequest] { lock.withLock { log.filter { $0.url?.path == path } } }
    func body(_ request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let responder = lock.withLock { log.append(request); return self.responder }
        let (status, body) = try responder(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var client: APIClient { APIClient(address: try! ServerAddress(validating: "https://mac.example"), token: "t", transport: self) }
}

@MainActor
final class BrowserAndContinueTests: XCTestCase {
    private let online = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
                                              chatFeatures: ["events", "attachments", "continue"],
                                              chatProviderInfo: ["codex": ChatProviderInfo(transport: "app-server", features: ["modes", "effort"])],
                                              archive: ArchiveCapabilities(features: ["sync", "search", "export", "terminalLogs", "continue"]))

    private func environment(_ host: ArchiveHost?, capabilities: CapabilitiesResponse? = nil, reachable: Bool = true) -> ArchiveEnvironment {
        ArchiveEnvironment(client: host?.client, capabilities: capabilities ?? online, reachable: reachable, hostName: "Studio Mac",
                           workspaces: ["p1": "web-app"])
    }

    private func loadedStore() async throws -> ArchiveStore {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.starter)
        return store
    }

    func testChatArchiveListsClaudeCodeAndCodexWorkspaceChatsAndHidesOtherAgents() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.page([
            Fixture.chat("general", project: "chats", provider: "opencode", title: "Dinner"),
            Fixture.chat("claude:work", project: "p1", provider: "claude", title: "Fix login", updated: "2026-09-23T12:06:00.000Z"),
            Fixture.chat("coding", project: "p1", provider: "opencode", title: "Old code"),
            Fixture.chat("gemini:try", project: "p1", provider: "gemini", title: "Tried it"),
            Fixture.message("m1", chat: "general", ord: 1, text: "shared question"),
            Fixture.message("m2", chat: "coding", ord: 1, text: "shared question"),
            Fixture.message("m3", chat: "claude:work", ord: 1, text: "shared question"),
            Fixture.log("terminal")
        ], cursor: "e1.5"))
        var environment = environment(nil, reachable: false)
        environment.chatAgents = ["claude", "codex"]
        let browser = ArchiveBrowserModel(store: store, environment: environment)
        await browser.reload()
        XCTAssertEqual(Set(browser.chats.map(\.id)), ["general", "claude:work"])
        XCTAssertEqual(browser.logs.map(\.id), ["terminal"])
        XCTAssertTrue(browser.suggestedTokens.contains(.workspace(id: "p1", name: "web-app")), "Workspace chats can be narrowed by workspace")
        browser.searchText = "shared"
        await browser.search()
        XCTAssertEqual(Set(browser.hits.map(\.chatID)), ["general", "claude:work"])
        let hidden = ArchivedChatModel(chatID: "coding", store: store, environment: environment)
        await hidden.load()
        XCTAssertEqual(hidden.phase, .missing)
        let shown = ArchivedChatModel(chatID: "claude:work", store: store, environment: environment)
        await shown.load()
        XCTAssertEqual(shown.phase, .ready)
        let saved = try await store.chat(id: "coding")
        XCTAssertNotNil(saved, "Hidden chats stay saved")
        XCTAssertTrue(environment.showsChat("codex:next", projectID: "p1", provider: nil), "The ID names the agent of an uncopied chat")
        XCTAssertFalse(environment.showsChat("ses_1", projectID: "p1", provider: nil))
    }

    // MARK: Delete

    func testDeleteLeavesThisDeviceOnlyAfterTheHostConfirms() async throws {
        let store = try await loadedStore()
        let host = ArchiveHost { _ in throw URLError(.networkConnectionLost) }
        let model = ArchiveBrowserModel(store: store, environment: environment(host))
        await model.reload()
        let chat = try XCTUnwrap(model.chats.first { $0.id == "ses_1" })

        // Asking only opens the dialog.
        model.requestDelete(chat)
        XCTAssertEqual(model.pendingDelete, chat)
        XCTAssertTrue(host.requests(to: "/v1/archive/delete").isEmpty, "Nothing is sent before the person confirms")

        // A lost connection may have deleted it: keep it and say so.
        await model.confirmDelete(chat)
        XCTAssertNil(model.pendingDelete)
        XCTAssertEqual(host.requests(to: "/v1/archive/delete").count, 1)
        XCTAssertEqual(host.body(try XCTUnwrap(host.requests(to: "/v1/archive/delete").first)) as? [String: String], ["kind": "chat", "id": "ses_1"])
        let kept = try await store.chat(id: "ses_1")
        XCTAssertNotNil(kept)
        XCTAssertEqual(model.notice, "Studio Mac may have deleted “Fix the login loop”. It stays here until your Mac confirms.")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(host.requests(to: "/v1/archive/delete").count, 1, "Never retried by itself")

        // A refusal keeps it too.
        host.respond { _ in (500, #"{"error":{"code":"archive_error","message":"The archive could not complete the request"}}"#) }
        await model.confirmDelete(chat)
        let stillKept = try await store.chat(id: "ses_1")
        XCTAssertNotNil(stillKept)
        XCTAssertEqual(model.notice, "“Fix the login loop” wasn’t deleted. The archive could not complete the request")

        // Confirmed: now it leaves this device, messages and all.
        host.respond { _ in (200, #"{"deleted":true}"#) }
        await model.confirmDelete(chat)
        let gone = try await store.chat(id: "ses_1")
        XCTAssertNil(gone)
        XCTAssertFalse(model.chats.contains { $0.id == "ses_1" })
        let messages = try await store.allMessages(chatID: "ses_1")
        XCTAssertTrue(messages.isEmpty)

        // Offline nothing is sent.
        let offline = ArchiveBrowserModel(store: store, environment: environment(host, reachable: false))
        await offline.reload()
        XCTAssertFalse(offline.canDelete)
        await offline.confirmDelete(try XCTUnwrap(offline.chats.first))
        XCTAssertEqual(offline.notice, "You’re offline, so nothing was deleted.")
        XCTAssertEqual(host.requests(to: "/v1/archive/delete").count, 3)
    }

    func testDeletingARunningTerminalLogIsRefusedAndKept() async throws {
        let store = try await loadedStore()
        let host = ArchiveHost { _ in (409, #"{"error":{"code":"terminal_running","message":"End the terminal before deleting its log"}}"#) }
        let model = ArchiveBrowserModel(store: store, environment: environment(host))
        await model.reload()
        let log = try XCTUnwrap(model.logs.first)
        await model.confirmDelete(log)
        let kept = try await store.terminalLog(id: log.id)
        XCTAssertNotNil(kept)
        XCTAssertEqual(model.notice, "“Build” wasn’t deleted. End the terminal before deleting its log")
        host.respond { _ in (200, #"{"deleted":true}"#) }
        await model.confirmDelete(log)
        let gone = try await store.terminalLog(id: log.id)
        XCTAssertNil(gone)
    }

    // MARK: Search

    func testSearchAsksTheHostOnlineAndThisDeviceOffline() async throws {
        let store = try await loadedStore()
        let host = ArchiveHost { request in
            guard request.url?.path == "/v1/archive/search" else { return (404, #"{"error":{"code":"not_found","message":"no"}}"#) }
            return (200, #"{"results":[{"chatId":"ses_1","messageId":"a1","projectId":"p1","title":"Fix the login loop","role":"assistant","createdAt":"2026-09-23T12:01:00.000Z","snippet":"the session \u0002cookie\u0003 is set"},{"chatId":"ses_host_only","messageId":"m9","projectId":"p1","title":"Only on the Mac","role":"user","createdAt":"2026-09-20T12:01:00.000Z","snippet":"\u0002cookie\u0003 jar"}],"nextCursor":"s.20"}"#)
        }
        let model = ArchiveBrowserModel(store: store, environment: environment(host))
        model.searchText = "cookie"
        model.tokens = [.provider("claude")]
        await model.search()
        XCTAssertEqual(model.hitsSource, .host(name: "Studio Mac"))
        XCTAssertEqual(model.hits.map(\.messageID), ["a1", "m9"])
        XCTAssertEqual(model.hits.first?.provider, "claude", "The provider comes from this device's copy")
        XCTAssertNil(model.hits.last?.provider, "Not copied yet: no provider to show")
        XCTAssertTrue(model.canLoadMoreHits)
        let sent = try XCTUnwrap(host.requests(to: "/v1/archive/search").first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["q"], "cookie*")
        XCTAssertEqual(query["provider"], "claude")

        // Offline: this device's copy answers, and says so.
        let offline = ArchiveBrowserModel(store: store, environment: environment(host, reachable: false))
        offline.searchText = "cookie"
        await offline.search()
        XCTAssertEqual(offline.hitsSource, .device)
        XCTAssertEqual(offline.hits.map(\.messageID), ["a1"])
        XCTAssertEqual(host.requests(to: "/v1/archive/search").count, 1)

        // A host that fails falls back to this device with a note.
        host.respond { _ in throw URLError(.timedOut) }
        let failing = ArchiveBrowserModel(store: store, environment: environment(host))
        failing.searchText = "redirect"
        await failing.search()
        XCTAssertEqual(failing.hitsSource, .device)
        XCTAssertEqual(failing.hits.map(\.messageID), ["a1"])
        XCTAssertEqual(failing.notice, "Studio Mac couldn’t search, so these results are from this device.")

        // Titles match at once, on this device.
        XCTAssertTrue(failing.titleMatches.isEmpty)
        failing.searchText = "login"
        await failing.search()
        XCTAssertEqual(failing.titleMatches.map(\.id), ["ses_1"])
    }

    func testSearchUsesTheProviderTheHostNames() async throws {
        let store = try await loadedStore()
        let host = ArchiveHost { _ in
            (200, #"{"results":[{"chatId":"ses_1","messageId":"a1","projectId":"p1","provider":"opencode","title":"Fix the login loop","role":"assistant","createdAt":"2026-09-23T12:01:00.000Z","snippet":"\u0002cookie\u0003"},{"chatId":"ses_host_only","messageId":"m9","projectId":"p1","provider":"codex","title":"Only on the Mac","role":"user","createdAt":"2026-09-20T12:01:00.000Z","snippet":"\u0002cookie\u0003 jar"},{"chatId":"ses_1","messageId":"u1","projectId":"p1","provider":"","title":"Fix the login loop","role":"user","createdAt":"2026-09-23T12:00:00.000Z","snippet":"\u0002cookie\u0003"}]}"#)
        }
        let model = ArchiveBrowserModel(store: store, environment: environment(host))
        model.searchText = "cookie"
        await model.search()
        XCTAssertEqual(model.hits.map(\.messageID), ["a1", "m9", "u1"])
        XCTAssertEqual(model.hits[0].provider, "opencode", "The host's provider wins over this device's copy (claude)")
        XCTAssertEqual(model.hits[1].provider, "codex", "A chat this device has not copied still shows its agent")
        XCTAssertEqual(model.hits[2].provider, "claude", "An empty provider falls back to this device's copy")
    }

    func testChipsFilterTheLibraryAndPinsComeFirst() async throws {
        let store = try await loadedStore()
        let model = ArchiveBrowserModel(store: store, environment: environment(nil, reachable: false))
        model.now = { ChatTime.date("2026-09-23T18:00:00.000Z")! }
        model.calendar = Calendar(identifier: .gregorian)
        model.calendar.timeZone = TimeZone(identifier: "UTC")!
        await model.reload()
        XCTAssertEqual(model.groups.map(\.title), ["Today", "Yesterday"])
        await model.setPinned(true, for: try XCTUnwrap(model.chats.last))
        XCTAssertEqual(model.groups.first?.title, "Pinned")
        XCTAssertEqual(model.groups.first?.chats.map(\.id), ["ses_2"])
        model.tokens = [.provider("claude")]
        await model.reload()
        XCTAssertEqual(model.chats.map(\.id), ["ses_1"])
        XCTAssertEqual(model.suggestedTokens.filter { $0.kind == .provider }, [], "One chip of a kind at a time")
        model.tokens = [.provider("claude"), .provider("codex")]
        XCTAssertEqual(model.tokens, [.provider("codex")])
        model.scope = .terminals
        model.tokens = [.workspace(id: "p2", name: "other")]
        XCTAssertTrue(model.visibleLogs.isEmpty)
        model.tokens = []
        model.searchText = "build"
        XCTAssertEqual(model.visibleLogs.map(\.id), ["t1"])
    }

    // MARK: Continue with…

    private func loginChat(_ store: ArchiveStore) async throws -> ArchivedChat {
        try await store.apply(Fixture.page([
            Fixture.message("a2", chat: "ses_1", role: .assistant, ord: 3, text: "", created: "2026-09-23T12:02:00.000Z",
                            extraParts: [ConversationPart(id: "r", kind: .reasoning, text: "private thinking"),
                                         ConversationPart(id: "t", kind: .tool, tool: ConversationTool(name: "bash", status: .completed, title: "npm test",
                                                                                                   input: "{\"command\":\"npm test\"}"))],
                            model: "claude/opus"),
            Fixture.message("u3", chat: "ses_1", ord: 4, text: "Now fix staging", created: "2026-09-23T12:03:00.000Z"),
            Fixture.message("a3", chat: "ses_1", role: .assistant, ord: 5, text: "Rewound reply", created: "2026-09-23T12:04:00.000Z", hidden: true)
        ], cursor: "e1.9", firstSeq: 7))
        let chat = try await store.chat(id: "ses_1")
        return try XCTUnwrap(chat)
    }

    func testTheSeedPreviewFollowsTheHostsRules() async throws {
        let store = try await loadedStore()
        let chat = try await loginChat(store)
        let messages = try await store.allMessages(chatID: chat.id, includeHidden: true)
        let seed = ContinueSeed.build(chat: chat, messages: messages)
        XCTAssertEqual(seed.included, 4)
        XCTAssertEqual(seed.omitted, 0)
        XCTAssertTrue(seed.text.hasPrefix("Context from an earlier chat, \"Fix the login loop\" (claude, claude/opus)"))
        XCTAssertTrue(seed.text.hasSuffix("End of the earlier chat. The new message follows."))
        XCTAssertTrue(seed.text.contains("### User · 2026-09-23 12:00 UTC\nWhy does the login page loop after a passkey sign-in?"))
        XCTAssertTrue(seed.text.contains("### Assistant (claude/opus) · 2026-09-23 12:02 UTC\n[Tool bash: npm test (completed)]"))
        XCTAssertFalse(seed.text.contains("private thinking"), "Reasoning is left out")
        XCTAssertFalse(seed.text.contains("Rewound reply"), "Rewound messages are left out")
        XCTAssertEqual(seed.characters, seed.text.unicodeScalars.count)
        XCTAssertEqual(seed.estimatedTokens, (seed.characters + 3) / 4)

        // A cut-off stops after that message.
        let through = ContinueSeed.build(chat: chat, messages: messages, through: "a1")
        XCTAssertEqual(through.included, 2)
        XCTAssertFalse(through.text.contains("Now fix staging"))

        // A small budget keeps the first message and the newest that fit, and says what was left out.
        var long: [ArchivedMessage] = [ArchivedMessage(message: ConversationMessage(id: "first", chatID: "c", role: .user, ord: 1,
                                                                                       parts: [ConversationPart(id: "f", kind: .text, text: "The very first question")]))]
        for index in 2...40 {
            long.append(ArchivedMessage(message: ConversationMessage(id: "m\(index)", chatID: "c", role: index % 2 == 0 ? .assistant : .user, ord: Int64(index),
                                                                     parts: [ConversationPart(id: "t", kind: .text, text: String(repeating: "word ", count: 60) + "\(index)")])))
        }
        let small = ContinueSeed.build(chat: chat, messages: long, budget: 2_000)
        XCTAssertTrue(small.blocks.first?.contains("The very first question") == true)
        XCTAssertGreaterThan(small.omitted, 0)
        XCTAssertTrue(small.blocks.contains("[\(small.omitted) messages in between are left out.]"))
        XCTAssertTrue(small.blocks.last?.hasSuffix("40") == true, "The newest message is kept")
        XCTAssertLessThanOrEqual(small.characters, 2_000 + 10)
        XCTAssertEqual(small.included + small.omitted, 40)
    }

    func testContinueSendsTheCutOffOnlyToHostsThatTakeIt() async throws {
        let store = try await loadedStore()
        let chat = try await loginChat(store)
        let host = ArchiveHost { request in
            switch request.url?.path {
            case "/v1/chat/options":
                return (200, #"{"models":[{"id":"codex/gpt-5","name":"GPT-5","provider":"Codex","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"codex/gpt-5","agents":["build"],"modes":[{"id":"auto-review","name":"Auto review"},{"id":"ask","name":"Ask"}],"defaultMode":"auto-review"}"#)
            case "/v1/chat/continue":
                return (201, #"{"id":"codex:9","title":"Fix the login loop (continued)","projectId":"p1","provider":"codex","parentSessionId":"ses_1","seed":{"included":4,"omitted":0,"chars":900}}"#)
            default:
                return (404, #"{"error":{"code":"not_found","message":"no"}}"#)
            }
        }
        let model = ContinueChatModel(chat: chat, store: store, environment: environment(host))
        await model.load()
        XCTAssertEqual(model.provider, .opencode, "Another agent than the chat's own is offered first")
        await model.select(.codex)
        XCTAssertEqual(model.model, "codex/gpt-5")
        XCTAssertEqual(model.mode, "auto-review")
        XCTAssertEqual(model.effort, "high")
        XCTAssertTrue(model.hostContinues)
        XCTAssertFalse(model.offersCutoff, "No throughMessageId without continueThrough")
        model.cutoffMessageID = "a1"
        let created = await model.submit()
        XCTAssertEqual(created, .chat(Session(id: "codex:9", title: "Fix the login loop (continued)", projectID: "p1", provider: "codex", parentSessionID: "ses_1")))
        let first = host.body(try XCTUnwrap(host.requests(to: "/v1/chat/continue").first))
        XCTAssertNil(first["throughMessageId"])
        XCTAssertNil(first["contextChars"], "The default size is the host's own")
        XCTAssertEqual(first["model"] as? String, "codex/gpt-5")
        XCTAssertEqual(first["mode"] as? String, "auto-review")
        XCTAssertEqual(first["effort"] as? String, "high")
        XCTAssertEqual(first["sourceSessionId"] as? String, "ses_1")

        // A host that advertises continueThrough gets the cut-off and the chosen size.
        let through = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "codex"],
                                           chatFeatures: ["continue", "continueThrough"],
                                           archive: ArchiveCapabilities(features: ["sync", "continue", "continueThrough"]))
        let precise = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: through))
        await precise.load()
        XCTAssertTrue(precise.offersCutoff)
        XCTAssertEqual(precise.cutoffChoices.map(\.id), ["u1", "a1", "a2", "u3"])
        precise.cutoffMessageID = "a1"
        precise.contextChars = 16_000
        _ = await precise.submit()
        let second = host.body(try XCTUnwrap(host.requests(to: "/v1/chat/continue").last))
        XCTAssertEqual(second["throughMessageId"] as? String, "a1")
        XCTAssertEqual(second["contextChars"] as? Int, 16_000)
        XCTAssertNil(second["effort"], "Effort only for providers that list it")

        // Uncertain: reported, never repeated.
        host.respond { _ in throw URLError(.networkConnectionLost) }
        let uncertain = await precise.submit()
        XCTAssertNil(uncertain)
        XCTAssertEqual(precise.notice, "Your Mac may have created the new chat. Check your chats before trying again.")
        XCTAssertEqual(host.requests(to: "/v1/chat/continue").count, 3)
    }

    /// An ACP agent's new chat takes `<id>/default` or no model, and no mode or effort (docs/HOST-API.md
    /// "Continue with another model"): once the host has learned the agent's modes they are still not
    /// offered, and neither the host nor a draft gets them.
    func testContinuingWithAnACPAgentSendsNoModeOrEffortAndOffersNoModePicker() async throws {
        let store = try await loadedStore()
        let chat = try await loginChat(store)
        let host = ArchiveHost { request in
            switch request.url?.path {
            case "/v1/chat/options":
                return (200, #"{"models":[{"id":"gemini/default","name":"Default","provider":"Gemini CLI"}],"defaultModel":"gemini/default","agents":["build"],"modes":[{"id":"default","name":"Default"},{"id":"yolo","name":"YOLO"}],"defaultMode":"default"}"#)
            case "/v1/chat/continue":
                return (201, #"{"id":"gemini:9","title":"Fix the login loop (continued)","projectId":"p1","provider":"gemini","parentSessionId":"ses_1","seed":{"included":4,"omitted":0,"chars":900}}"#)
            default:
                return (404, #"{"error":{"code":"not_found","message":"no"}}"#)
            }
        }
        let catalog = [AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true)].compactMap { $0 }
        let acp = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex", "gemini"],
                                       chatFeatures: ["events", "attachments", "continue", "modes"],
                                       chatProviderInfo: ["gemini": ChatProviderInfo(transport: "acp", features: ["approvals", "modes"])],
                                       archive: ArchiveCapabilities(features: ["sync", "continue"]),
                                       agents: ["catalog", "install", "acp"], agentCatalog: catalog)
        let model = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: acp))
        await model.load()
        await model.select(id: "gemini")
        XCTAssertEqual(model.provider.displayName, "Gemini CLI")
        XCTAssertEqual(model.model, "gemini/default")
        XCTAssertTrue(model.modeChoices.isEmpty, "No mode picker for an ACP agent")
        XCTAssertEqual(model.mode, "")
        XCTAssertTrue(model.effortChoices.isEmpty)
        model.mode = "yolo"
        model.effort = "high"
        guard case let .chat(session)? = await model.submit() else { return XCTFail("The host continues the chat") }
        XCTAssertEqual(session.id, "gemini:9")
        let body = host.body(try XCTUnwrap(host.requests(to: "/v1/chat/continue").last))
        XCTAssertEqual(body["provider"] as? String, "gemini")
        XCTAssertEqual(body["model"] as? String, "gemini/default")
        XCTAssertNil(body["mode"], "A mode the host would refuse is never sent")
        XCTAssertNil(body["effort"])

        // A host without Continue gets a draft for the new chat, without them too.
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "gemini"], chatFeatures: [],
                                         agents: ["catalog", "acp"], agentCatalog: catalog)
        let drafting = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: older))
        await drafting.load()
        await drafting.select(id: "gemini")
        drafting.mode = "yolo"
        guard case let .draft(draft)? = await drafting.submit() else { return XCTFail("a draft") }
        XCTAssertEqual(draft.provider, "gemini")
        XCTAssertEqual(draft.model, "gemini/default")
        XCTAssertNil(draft.mode)
        XCTAssertNil(draft.effort)
    }

    /// A plain chat continues only into another plain chat (docs/HOST-API.md "Plain chats"): OpenCode alone with the
    /// Chats space's models, no agent, mode or effort to choose, and none sent, to the host or in a draft. A
    /// workspace's chat keeps every agent.
    func testAPlainChatContinuesIntoAPlainChatOnly() async throws {
        let store = try await loadedStore()
        let workspaceChat = try await loginChat(store)
        var chat = workspaceChat
        chat.projectID = PlainChatsCapability.chatsProjectID
        chat.provider = "opencode"
        let host = ArchiveHost { request in
            switch request.url?.path {
            case "/v1/chat/options":
                return (200, #"{"models":[{"id":"anthropic/sonnet","name":"Sonnet","provider":"Anthropic","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"anthropic/sonnet","agents":[]}"#)
            case "/v1/chat/continue":
                return (201, #"{"id":"ses_9","title":"Fix the login loop (continued)","projectId":"chats","provider":"opencode","parentSessionId":"ses_1"}"#)
            default:
                return (404, #"{"error":{"code":"not_found","message":"no"}}"#)
            }
        }
        let plain = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
                                         chatFeatures: ["events", "attachments", "continue", "modes", "effort"],
                                         chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["modes", "effort"])],
                                         archive: ArchiveCapabilities(features: ["sync", "continue"]),
                                         plainChats: PlainChatsCapability(tools: [.websearch, .fetch, .memory]))
        let model = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: plain))
        XCTAssertTrue(model.isPlainChat)
        XCTAssertEqual(model.providers, [.opencode], "Never Claude Code, Codex or an ACP agent")
        XCTAssertEqual(model.provider, .opencode)
        await model.load()
        XCTAssertEqual(model.model, "anthropic/sonnet")
        let options = try XCTUnwrap(host.requests(to: "/v1/chat/options").last)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(options.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "projectId" }?.value,
                       "chats", "The Chats space's models")
        XCTAssertTrue(model.modeChoices.isEmpty)
        XCTAssertTrue(model.effortChoices.isEmpty, "Though the model lists efforts")
        await model.select(id: "claude")
        XCTAssertEqual(model.provider, .opencode, "No other agent can be chosen")
        model.mode = "build"
        model.effort = "high"
        guard case let .chat(session)? = await model.submit() else { return XCTFail("The host continues the chat") }
        XCTAssertEqual(session.projectID, "chats")
        let body = host.body(try XCTUnwrap(host.requests(to: "/v1/chat/continue").last))
        XCTAssertEqual(body["projectId"] as? String, "chats")
        XCTAssertEqual(body["provider"] as? String, "opencode")
        XCTAssertEqual(body["model"] as? String, "anthropic/sonnet")
        XCTAssertNil(body["mode"])
        XCTAssertNil(body["effort"])

        // A host without Continue gets a draft for a new plain chat, without them too.
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude"], chatFeatures: [],
                                         plainChats: PlainChatsCapability())
        let drafting = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: older))
        await drafting.load()
        drafting.mode = "build"
        guard case let .draft(draft)? = await drafting.submit() else { return XCTFail("a draft") }
        XCTAssertEqual(draft.projectID, "chats")
        XCTAssertEqual(draft.provider, "opencode")
        XCTAssertNil(draft.mode)
        XCTAssertNil(draft.effort)

        let other = ContinueChatModel(chat: workspaceChat, store: store, environment: environment(host, capabilities: plain))
        XCTAssertFalse(other.isPlainChat)
        XCTAssertEqual(other.providers.map(\.id), ["opencode", "claude", "codex"])

        // An older host lists no plain chats, and a workspace of its may be called chats: its chats are that
        // workspace's, and continue as they always did.
        let noPlainChats = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
                                                chatFeatures: ["events", "continue", "modes", "effort"])
        let olderHost = ArchiveEnvironment(client: host.client, capabilities: noPlainChats, reachable: true, hostName: "Studio Mac",
                                           workspaces: ["chats": "Chats", "p1": "web-app"])
        XCTAssertFalse(olderHost.isChatsSpace("chats"))
        let workspaceNamedChats = ContinueChatModel(chat: chat, store: store, environment: olderHost)
        XCTAssertFalse(workspaceNamedChats.isPlainChat)
        XCTAssertEqual(workspaceNamedChats.providers.map(\.id), ["opencode", "claude", "codex"])
        XCTAssertTrue(environment(host, capabilities: noPlainChats).isChatsSpace("chats"),
                      "Without such a workspace chats is the Chats space still, as archived plain chats keep it")
    }

    /// The browser calls the Chats space "Chats"; an export or a continued chat's context of a plain chat names no
    /// workspace, as the chat tab's own export. An older host's workspace called chats keeps its name everywhere.
    func testThePlainChatsSpaceIsCalledChatsAndExportsNameNoWorkspace() async throws {
        let store = try await loadedStore()
        let plain = CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["events"], plainChats: PlainChatsCapability())
        let model = ArchiveBrowserModel(store: store, environment: environment(nil, capabilities: plain))
        XCTAssertEqual(model.workspaceName("chats"), "Chats")
        XCTAssertNil(model.exportedWorkspace("chats"))
        XCTAssertEqual(model.workspaceName("p1"), "web-app")
        XCTAssertEqual(model.exportedWorkspace("p1"), "web-app")

        let older = ArchiveEnvironment(client: nil, capabilities: online, reachable: true, hostName: "Studio Mac",
                                       workspaces: ["chats": "chats-site", "p1": "web-app"])
        let olderModel = ArchiveBrowserModel(store: store, environment: older)
        XCTAssertEqual(olderModel.workspaceName("chats"), "chats-site")
        XCTAssertEqual(olderModel.exportedWorkspace("chats"), "chats-site")
    }

    /// A draft's chat is made with "<title> (continued)", cut to the host's 200 bytes at a character: a title
    /// in another script takes up to four bytes a character.
    func testADraftsTitleFitsTheHostsLimit() async throws {
        let store = try await loadedStore()
        var chat = try await loginChat(store)
        chat.title = String(repeating: "月", count: 100)
        let host = ArchiveHost { _ in (404, #"{"error":{"code":"not_found","message":"no"}}"#) }
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"], chatFeatures: [])
        let model = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: older))
        await model.load()
        guard case let .draft(draft)? = await model.submit() else { return XCTFail("a draft") }
        XCTAssertEqual(draft.title, String(repeating: "月", count: 66), "198 bytes, cut at a character")
    }

    func testHostsWithoutContinueGetADraftThatIsNeverSent() async throws {
        let store = try await loadedStore()
        let chat = try await loginChat(store)
        let host = ArchiveHost { _ in (404, #"{"error":{"code":"not_found","message":"no"}}"#) }
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "codex"], chatFeatures: ["attachments"])
        let model = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: older), workspaceName: "web-app")
        await model.load()
        XCTAssertFalse(model.hostContinues)
        XCTAssertTrue(model.offersCutoff, "The draft is built here, so the cut-off always works")
        model.cutoffMessageID = "a1"
        guard case let .draft(draft)? = await model.submit() else { return XCTFail("a draft") }
        XCTAssertEqual(draft.provider, "opencode")
        XCTAssertEqual(draft.projectID, "p1")
        XCTAssertEqual(draft.sourceChatID, "ses_1")
        XCTAssertEqual(draft.title, "Fix the login loop (continued)")
        XCTAssertEqual(draft.text, "The attached file is an earlier chat, “Fix the login loop”, with Claude Code. Continue from where it ends.")
        let attachment = try XCTUnwrap(draft.attachment)
        XCTAssertEqual(attachment.mime, "text/markdown")
        XCTAssertEqual(attachment.name, "Fix-the-login-loop.md")
        let markdown = String(decoding: attachment.data, as: UTF8.self)
        XCTAssertTrue(markdown.hasPrefix("# Fix the login loop\n\n_Earlier chat with Claude Code (claude/opus) in web-app."))
        XCTAssertTrue(markdown.contains("wrong domain"))
        XCTAssertFalse(markdown.contains("Now fix staging"), "The cut-off applies")
        XCTAssertTrue(host.requests(to: "/v1/messages").isEmpty, "Nothing is sent")
        XCTAssertTrue(host.requests(to: "/v1/chat/continue").isEmpty)

        // Without attachments the transcript goes into the draft itself.
        let noFiles = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"], chatFeatures: [])
        let inline = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: noFiles))
        await inline.load()
        guard case let .draft(plain)? = await inline.submit() else { return XCTFail("a draft") }
        XCTAssertNil(plain.attachment)
        XCTAssertTrue(plain.text.hasPrefix("Here is an earlier chat, “Fix the login loop”, with Claude Code. Continue from where it ends.\n\nContext from an earlier chat"))

        // Offline: nothing to continue with.
        let offline = ContinueChatModel(chat: chat, store: store, environment: environment(host, capabilities: older, reachable: false))
        await offline.load()
        XCTAssertFalse(offline.canContinue)
        let refused = await offline.submit()
        XCTAssertNil(refused)
        XCTAssertEqual(offline.notice, "Connect to your Mac to continue this chat.")
    }

    // MARK: Export

    func testExportUsesTheHostAndFallsBackToThisDevice() async throws {
        let store = try await loadedStore()
        let saved = try await store.chat(id: "ses_1")
        let chat = try XCTUnwrap(saved)
        let host = ArchiveHost { request in
            request.url?.path == "/v1/archive/export" ? (200, "# From the Mac\n") : (404, "{}")
        }
        let fromHost = try await ArchiveChatExport(chat: chat, format: .markdown, client: host.client, store: store).data()
        XCTAssertEqual(String(decoding: fromHost, as: UTF8.self), "# From the Mac\n")
        host.respond { _ in throw URLError(.notConnectedToInternet) }
        let markdown = try await ArchiveChatExport(chat: chat, format: .markdown, client: host.client, store: store, workspace: "web-app").data()
        XCTAssertEqual(String(decoding: markdown, as: UTF8.self).components(separatedBy: "\n").prefix(3).joined(separator: "\n"),
                       "# Fix the login loop\n\n_Claude Code · claude/opus · web-app_")
        let json = try await ArchiveChatExport(chat: chat, format: .json, client: nil, store: store).data()
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual((decoded["chat"] as? [String: Any])?["id"] as? String, "ses_1")
        XCTAssertEqual((decoded["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(ArchiveChatExport(chat: chat, format: .json, client: nil, store: store).fileName, "Fix-the-login-loop.json")
    }
}
