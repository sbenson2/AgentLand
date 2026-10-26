import XCTest
import AgentLandCore
@testable import AgentLandChat

/// Chat is Claude Code and Codex in the selected workspace (owner, 2026-10-12): their own permission modes, Ask
/// first; Bypass permissions and Full access ask once per chat before it first runs that way; Claude Code and Codex
/// chats left in the Chats space are read-only and continue into a workspace; memory is gone from them.
@MainActor
final class WorkspaceChatTests: XCTestCase {
    private let claudeChat = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "claude:c1", tabID: UUID())
    private let codexChat = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "codex:x1", tabID: UUID())
    private let legacyChat = ChatSessionStore.Identity(hostID: "h", projectID: "chats", sessionID: "claude:old", tabID: UUID())

    private static let claudeFeatures = ["events", "parts", "stop", "clientMessageId", "title", "attachments", "queue", "effort",
                                         "rewind", "fork", "regenerate", "approvals", "questions", "modes", "restoreFiles"]
    private static let codexFeatures = ["events", "parts", "stop", "clientMessageId", "title", "attachments", "queue", "effort",
                                        "rewind", "fork", "approvals", "questions", "modes"]

    /// A host as plan step 1 recorded it: `workspaceChats` with both providers, `generalChats` without any, and no
    /// `chatProviderInfo` or `events` in `chatFeatures` (its OpenCode does not stream).
    private let host = CapabilitiesResponse(
        interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
        chatFeatures: ["reasoning", "attachments", "queue", "rewind", "parts", "stop", "continue", "continueThrough", "clientMessageId",
                       "regenerate", "fork", "modes", "effort", "title"],
        plainChats: PlainChatsCapability(providers: []),
        workspaceChats: WorkspaceChatsCapability(providers: [
            PlainChatProvider(id: "claude", name: "Claude Code", features: WorkspaceChatTests.claudeFeatures,
                              auth: PlainChatAuth(kind: "subscription", label: "Claude subscription")),
            PlainChatProvider(id: "codex", name: "Codex", features: WorkspaceChatTests.codexFeatures,
                              auth: PlainChatAuth(kind: "subscription", label: "ChatGPT subscription"))]))

    nonisolated private static let claudeOptions = #"{"models":[{"id":"claude/default","name":"Default","provider":"Claude Code"},{"id":"claude/opus","name":"Opus","provider":"Claude Code","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"claude/default","agents":["build"],"modes":[{"id":"default","name":"Ask"},{"id":"acceptEdits","name":"Accept edits"},{"id":"plan","name":"Plan"},{"id":"auto","name":"Auto"},{"id":"bypassPermissions","name":"Bypass permissions"}],"defaultMode":"default"}"#
    nonisolated private static let codexOptions = #"{"models":[{"id":"codex/default","name":"Default","provider":"Codex"}],"defaultModel":"codex/default","agents":["build"],"modes":[{"id":"ask","name":"Ask"},{"id":"auto-review","name":"Auto-review"},{"id":"read-only","name":"Read only"},{"id":"full-access","name":"Full access"}],"defaultMode":"ask"}"#
    nonisolated static let retired = #"{"error":{"code":"agent_unavailable","message":"Chat now runs in your workspaces; this chat stays readable."}}"#

    nonisolated private static func responder(_ request: URLRequest) throws -> (Int, String) {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        switch (request.url?.path, request.httpMethod) {
        case ("/v1/chat/options", _):
            if value("projectId") == "chats" { return (503, retired) }
            let provider = value("provider") ?? value("sessionId")?.split(separator: ":").first.map(String.init)
            return (200, provider == "codex" ? codexOptions : claudeOptions)
        case ("/v1/messages", "POST"):
            return (202, #"{"accepted":true,"messageId":"msg_sent","turnId":"msg_sent"}"#)
        case ("/v1/chat/continue", _):
            return (201, #"{"id":"claude:next","title":"Units (continued)","projectId":"p","provider":"claude","parentSessionId":"claude:old","seed":{"included":2,"omitted":0,"chars":120}}"#)
        default:
            return try ScriptedHost.defaultResponder(request)
        }
    }

    private static let ready = #"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#
    private static func snapshot(_ identity: ChatSessionStore.Identity, mode: String? = nil, messages: String = "[]") -> String {
        let provider = String(identity.sessionID.split(separator: ":")[0])
        let mode = mode.map { #","mode":"\#($0)""# } ?? ""
        return #"{"seq":0,"type":"snapshot","chat":{"id":"\#(identity.sessionID)","title":"New chat","provider":"\#(provider)"\#(mode)},"messages":\#(messages),"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#
    }
    private static let turn = #"[{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"u1p","kind":"text","text":"Tides in Lisbon? And I use metric."}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","parts":[\#(PlainChatTests.memoryPart),{"id":"a1x","kind":"text","ord":4,"text":"High tide is at 14:02."}]}]"#

    private func environment(_ client: APIClient?, capabilities: CapabilitiesResponse? = nil,
                             continueWorkspace: ChatWorkspace? = nil) -> ChatSessionStore.Environment {
        ChatSessionStore.Environment(client: client, capabilities: capabilities ?? host, reachable: true, connectionEpoch: 0, active: true,
                                     refreshGeneration: nil, workspaceIDs: ["p"], continueWorkspace: continueWorkspace)
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

    private func loaded(_ identity: ChatSessionStore.Identity, mode: String? = nil, savedMode: String? = nil, messages: String = "[]",
                        continueWorkspace: ChatWorkspace? = nil) async throws -> (ChatSessionStore, ScriptedHost) {
        let scripted = ScriptedHost(responder: Self.responder)
        scripted.enqueue([Self.ready, Self.snapshot(identity, mode: mode, messages: messages)])
        let store = ChatSessionStore(identity: identity, mode: savedMode)
        store.update(environment(APIClient(address: try ServerAddress(validating: "https://host.example"), token: "t", transport: scripted),
                                 continueWorkspace: continueWorkspace))
        await eventually("content and options") { store.isResolved(for: nil) }
        return (store, scripted)
    }

    private func sentMode(_ store: ChatSessionStore, _ scripted: ScriptedHost, _ text: String) async throws -> String? {
        store.setDraft(text)
        await store.send()
        return try body(scripted.requests(to: "/v1/messages").last { $0.httpMethod == "POST" })["mode"] as? String
    }

    // MARK: Modes

    func testClaudeWorkspaceChatOffersItsModes() async throws {
        let (store, scripted) = try await loaded(claudeChat)
        defer { store.shutdown() }
        XCTAssertFalse(store.isPlainChat)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.transportKind, .events, "Its provider entry lists events, though the host's chatFeatures do not")
        XCTAssertEqual(store.modeChoices.map(\.id), ["default", "acceptEdits", "plan", "auto", "bypassPermissions"])
        XCTAssertEqual(store.modeChoices.map(\.name), ["Ask", "Accept edits", "Plan", "Auto", "Bypass permissions"])
        XCTAssertEqual(store.modeChoices.map(\.summary), ["Asks first", "Edits without asking", "Plans only", "Asks only when risky",
                                                          "Runs without asking"])
        XCTAssertEqual(store.modeChoices.map(\.symbol), ["hand.raised", "pencil", "list.bullet", "checkmark.shield", "bolt"])
        XCTAssertEqual(store.modeChoices.map { $0.confirmation != nil }, [false, false, false, false, true])
        XCTAssertEqual(store.selectedModeChoice?.id, "default", "A new chat starts in Ask")
        XCTAssertNil(store.flaggedMode, "The pill shows no mode while it asks first")

        // Its features come from its workspace entry: no chatProviderInfo here.
        XCTAssertTrue(store.canFork)
        XCTAssertTrue(store.canRewind)
        XCTAssertTrue(store.rewindRestoresFiles)
        XCTAssertFalse(store.offersMemoryUndo)
        XCTAssertNil(store.allowedAttachmentMIMEs)

        let asked = try await sentMode(store, scripted, "Look at the tests")
        XCTAssertEqual(asked, "default")
        store.selectMode("acceptEdits")
        XCTAssertNil(store.modeQuestion, "Only Bypass permissions asks")
        XCTAssertEqual(store.flaggedMode?.symbol, "pencil", "The pill shows a mode that doesn't ask first")
        let acceptingEdits = try await sentMode(store, scripted, "Fix them")
        XCTAssertEqual(acceptingEdits, "acceptEdits")
    }

    func testCodexWorkspaceChatOffersItsModes() async throws {
        let (store, scripted) = try await loaded(codexChat)
        defer { store.shutdown() }
        XCTAssertEqual(store.modeChoices.map(\.name), ["Ask", "Auto-review", "Read only", "Full access"])
        XCTAssertEqual(store.modeChoices.map(\.summary), ["Asks first", "Edits on its own", "Reads only", "Runs without asking"])
        XCTAssertEqual(store.modeChoices.map(\.symbol), ["hand.raised", "pencil", "eye", "bolt"])
        XCTAssertEqual(store.modeChoices.map { $0.confirmation != nil }, [false, false, false, true])
        XCTAssertEqual(store.selectedModeChoice?.id, "ask")
        XCTAssertNil(store.flaggedMode, "Codex's Ask asks first too")
        XCTAssertFalse(store.rewindRestoresFiles, "Codex's entry lists no restoreFiles")
        let codexMode = try await sentMode(store, scripted, "Hi")
        XCTAssertEqual(codexMode, "ask")
    }

    /// Bypass permissions (Claude Code) and Full access (Codex) ask once per chat (owner, 2026-10-12 ~21:10), on the
    /// control that chose it; later switches in that chat do not, and nothing is sent in that mode before the answer.
    func testBypassAsksFirst() async throws {
        let (store, scripted) = try await loaded(claudeChat)
        defer { store.shutdown() }
        var confirmations = 0
        store.callbacks.modeConfirmed = { confirmations += 1 }
        var saved: [String?] = []
        store.callbacks.persistOptions = { _, mode, _ in saved.append(mode) }

        store.selectMode("bypassPermissions", from: .titleMenu)
        let question = try XCTUnwrap(store.modeQuestion)
        XCTAssertEqual(question.origin, .titleMenu)
        XCTAssertEqual(question.choice.id, "bypassPermissions")
        let copy = try XCTUnwrap(question.choice.confirmation)
        XCTAssertEqual(copy.title, "Switch this chat to Bypass permissions?")
        XCTAssertEqual(copy.action, "Bypass Permissions")
        XCTAssertTrue(copy.message.contains("Claude Code"))
        XCTAssertEqual(store.selectedModeChoice?.id, "default", "Nothing changes before the answer")
        let beforeTheAnswer = try await sentMode(store, scripted, "Still asking?")
        XCTAssertEqual(beforeTheAnswer, "default")

        // Cancel leaves the mode as it was, and the next attempt asks again.
        store.cancelModeQuestion()
        XCTAssertNil(store.modeQuestion)
        XCTAssertFalse(store.unattendedModeConfirmed)
        store.selectMode("bypassPermissions")
        XCTAssertEqual(store.modeQuestion?.origin, .composer)

        // The answer acts on the choice it was asked about, even after the question was cleared (a dialog's dismissal
        // can come first).
        store.cancelModeQuestion()
        store.confirmMode(question.choice)
        XCTAssertTrue(store.unattendedModeConfirmed)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(store.selectedModeChoice?.id, "bypassPermissions")
        XCTAssertEqual(saved.last, "bypassPermissions")
        let confirmed = try await sentMode(store, scripted, "Go")
        XCTAssertEqual(confirmed, "bypassPermissions")

        // Later switches in the same chat don't ask.
        store.selectMode("plan")
        store.selectMode("bypassPermissions")
        XCTAssertNil(store.modeQuestion)
        XCTAssertEqual(store.selectedModeChoice?.id, "bypassPermissions")
        XCTAssertEqual(confirmations, 1)

        // Codex's Full access asks the same way.
        let (codex, _) = try await loaded(codexChat)
        defer { codex.shutdown() }
        codex.selectMode("full-access")
        XCTAssertEqual(codex.modeQuestion?.choice.id, "full-access")
        XCTAssertEqual(codex.modeQuestion?.choice.confirmation?.action, "Allow Full Access")
        XCTAssertEqual(codex.selectedModeChoice?.id, "ask")

        // A chat saved in Bypass permissions was confirmed before: it doesn't ask again.
        let (reopened, _) = try await loaded(claudeChat, savedMode: "bypassPermissions")
        defer { reopened.shutdown() }
        XCTAssertTrue(reopened.unattendedModeConfirmed)
        XCTAssertEqual(reopened.selectedModeChoice?.id, "bypassPermissions")
        let (remembered, _) = try await loaded(claudeChat)
        defer { remembered.shutdown() }
        XCTAssertFalse(remembered.unattendedModeConfirmed)
        let kept = ChatSessionStore(identity: claudeChat, unattendedModeConfirmed: true)
        XCTAssertTrue(kept.unattendedModeConfirmed, "The app keeps the answer with the chat")
    }

    /// The host follows Claude Code's own mode changes (leaving Plan once the plan is approved returns to the mode
    /// before it), and so does the chat: the next message keeps that mode instead of entering Plan again. A return to
    /// Bypass permissions in a chat that confirmed it asks nothing; one this device never confirmed is not taken up.
    func testTheChatFollowsTheModeTheHostReturnsTo() async throws {
        let (store, scripted) = try await loaded(claudeChat, mode: "default")
        defer { store.shutdown() }
        store.selectMode("bypassPermissions")
        store.confirmMode(try XCTUnwrap(store.modeQuestion).choice)
        store.selectMode("plan")
        scripted.push(#"{"seq":1,"type":"chat.updated","mode":"plan"}"#)
        scripted.push(#"{"seq":2,"type":"chat.updated","mode":"bypassPermissions"}"#)
        await eventually("the plan approved") { store.selectedModeChoice?.id == "bypassPermissions" }
        XCTAssertNil(store.modeQuestion, "No second confirmation")
        let afterThePlan = try await sentMode(store, scripted, "Carry on")
        XCTAssertEqual(afterThePlan, "bypassPermissions")

        let (other, otherHost) = try await loaded(claudeChat, mode: "default")
        defer { other.shutdown() }
        other.selectMode("plan")
        otherHost.push(#"{"seq":1,"type":"chat.updated","mode":"plan"}"#)
        otherHost.push(#"{"seq":2,"type":"chat.updated","mode":"acceptEdits"}"#)
        await eventually("the plan approved") { other.selectedModeChoice?.id == "acceptEdits" }
        otherHost.push(#"{"seq":3,"type":"chat.updated","mode":"bypassPermissions"}"#)
        otherHost.push(#"{"seq":4,"type":"chat.updated","title":"Plan done"}"#)
        await eventually("the later update") { other.info?.title == "Plan done" }
        XCTAssertEqual(other.selectedModeChoice?.id, "acceptEdits", "Never Bypass without this device's confirmation")
        XCTAssertNil(other.modeQuestion)
        XCTAssertFalse(other.unattendedModeConfirmed)
    }

    /// Continue never starts a chat in Bypass permissions or Full access: the new chat asks for itself.
    func testContinueOffersNoModeThatAsksFirst() async throws {
        let options = try ProtocolDecoder.decode(ChatOptionsResponse.self, from: Data(Self.claudeOptions.utf8))
        XCTAssertEqual(ChatContinueSheet.modes(options, provider: .claude), ["default", "acceptEdits", "plan", "auto"])
        let (store, scripted) = try await loaded(claudeChat, messages: Self.turn)
        defer { store.shutdown() }
        let loaded = await store.options(for: .claude)
        XCTAssertEqual(loaded?.modes?.count, 5, "The host's own options, not a stub")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(scripted.requests(to: "/v1/chat/options").last?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "provider" }?.value, "claude")
        _ = await store.continueChat(provider: .claude, model: "claude/default", mode: "bypassPermissions", effort: nil)
        XCTAssertNil(try body(scripted.requests(to: "/v1/chat/continue").last)["mode"])
    }

    // MARK: Chats-space chats

    /// A Claude Code or Codex chat left in the Chats space stays readable: no composer, no sends or other requests that
    /// would start its agent, a notice saying why, and Continue in the workspace in use, which sends nothing.
    func testChatsSpaceChatIsReadOnly() async throws {
        let workspace = ChatWorkspace(id: "p", name: "my-app")
        let (store, scripted) = try await loaded(legacyChat, messages: Self.turn, continueWorkspace: workspace)
        defer { store.shutdown() }
        XCTAssertTrue(store.isPlainChat)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.transportKind, .events, "It streams as Claude Code's workspace chats do")
        XCTAssertEqual(ChatSessionStore.readOnlyNotice, "Chat now runs in your workspaces; this chat stays readable.")
        XCTAssertTrue(scripted.requests(to: "/v1/chat/options").isEmpty, "Its options are refused there: none are asked for")
        XCTAssertEqual(store.modeChoices, [])
        for (name, offered) in [("canQueue", store.canQueue), ("canRewind", store.canRewind), ("canEditLatest", store.canEditLatest),
                                ("canRunAgain", store.canRunAgain), ("canFork", store.canFork),
                                ("canSendAttachments", store.canSendAttachments), ("offersMemoryUndo", store.offersMemoryUndo)] {
            XCTAssertFalse(offered, name)
        }
        store.setDraft("One more?")
        XCTAssertFalse(store.sendEnabled)
        await store.send()
        await store.runAgain()
        XCTAssertTrue(scripted.requests(to: "/v1/messages").filter { $0.httpMethod == "POST" }.isEmpty)
        XCTAssertTrue(scripted.requests(to: "/v1/chat/regenerate").isEmpty)
        XCTAssertEqual(store.draft, "One more?", "The draft is kept")

        // Continue in my-app: Claude Code and Codex, the workspace's options, the chat as context, nothing sent.
        XCTAssertTrue(store.canContinue)
        XCTAssertEqual(store.continueWorkspace, workspace)
        XCTAssertEqual(store.continueProviders, [.claude, .codex])
        let options = await store.options(for: .codex)
        XCTAssertEqual(options?.defaultMode, "ask")
        let asked = try XCTUnwrap(URLComponents(url: try XCTUnwrap(scripted.requests(to: "/v1/chat/options").last?.url),
                                                resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(asked.first { $0.name == "projectId" }?.value, "p")
        XCTAssertEqual(asked.first { $0.name == "provider" }?.value, "codex")
        var opened: [Session] = []
        store.callbacks.openChat = { opened.append($0) }
        let created = await store.continueChat(provider: .claude, model: "claude/default", mode: "default", effort: nil)
        XCTAssertTrue(created)
        XCTAssertEqual(opened.map(\.projectID), ["p"])
        let sent = try body(scripted.requests(to: "/v1/chat/continue").last)
        XCTAssertEqual(sent["projectId"] as? String, "p")
        XCTAssertEqual(sent["sourceSessionId"] as? String, "claude:old")
        XCTAssertEqual(sent["provider"] as? String, "claude")
        XCTAssertEqual(sent["mode"] as? String, "default")
        XCTAssertTrue(scripted.requests(to: "/v1/messages").filter { $0.httpMethod == "POST" }.isEmpty, "Continue sends nothing")

        // An old memory card keeps its text; Undo is gone with the memory feature.
        await store.undoMemory(try XCTUnwrap(ChatToolMemory(id: "mem_4f2a9c1e", text: "Prefers metric units")))
        XCTAssertTrue(scripted.requests(to: "/v1/memory").isEmpty)
    }

    func testChatsSpaceChatsWithoutAWorkspaceOrOnOlderHosts() async throws {
        // No workspace in use: the notice alone, and Continue sends nothing.
        let (store, scripted) = try await loaded(legacyChat, messages: Self.turn)
        defer { store.shutdown() }
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNil(store.continueWorkspace)
        let options = await store.options(for: .claude)
        XCTAssertNil(options)
        let created = await store.continueChat(provider: .claude, model: nil, mode: nil, effort: nil)
        XCTAssertFalse(created)
        XCTAssertTrue(scripted.requests(to: "/v1/chat/continue").isEmpty)

        // A host before workspace chats still runs its Chats-space Claude chats; and a Chats-space chat of a provider
        // the host still offers there (OpenCode with --opencode-chat) is not read-only.
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["claude"], chatFeatures: ["events", "parts"],
                                         plainChats: PlainChatsCapability(providers: [PlainChatProvider(id: "claude", name: "Claude Code", features: ["events"])]))
        let old = ChatSessionStore(identity: legacyChat)
        old.update(environment(nil, capabilities: older))
        XCTAssertFalse(old.isReadOnly)
        let openCodeHost = CapabilitiesResponse(interactions: true, terminal: true, plainChats: PlainChatsCapability(
            tools: [.memory], providers: [PlainChatProvider(id: "opencode", name: "OpenCode", tools: ["memory"], features: ["events"])]),
            workspaceChats: host.workspaceChats)
        let openCode = ChatSessionStore(identity: ChatSessionStore.Identity(hostID: "h", projectID: "chats", sessionID: "ses_1", tabID: UUID()))
        openCode.update(environment(nil, capabilities: openCodeHost))
        XCTAssertFalse(openCode.isReadOnly)
        XCTAssertTrue(openCode.offersMemoryUndo, "OpenCode's own chat agent keeps its memory")
        let retiredOpenCode = ChatSessionStore(identity: ChatSessionStore.Identity(hostID: "h", projectID: "chats", sessionID: "ses_2", tabID: UUID()))
        retiredOpenCode.update(environment(nil))
        XCTAssertTrue(retiredOpenCode.isReadOnly, "Without --opencode-chat its OpenCode chats are read-only too")
    }
}
