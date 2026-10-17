import XCTest
import AgentLandCore
@testable import AgentLandChat

/// ACP chats in the one chat screen (docs/AGENT-CATALOG-PLAN.md, "ACP chats"): the agent's name comes from
/// the host's catalog, features only from its provider info, and `agent_auth_required` becomes the sign-in
/// notice with Open in Terminal for the agent's terminal program.
@MainActor
final class ChatSignInTests: XCTestCase {
    private let identity = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "gemini:1", tabID: UUID())

    /// A host that streams Gemini CLI chats over ACP, with no rewind or fork for them, and a terminal program.
    private let host = CapabilitiesResponse(
        interactions: true, terminal: true, terminalPrograms: ["shell", "gemini"], chatProviders: ["opencode", "gemini", "quiet"],
        chatFeatures: ["events", "parts", "stop", "rewind", "fork", "regenerate", "clientMessageId"],
        chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind", "restoreFiles", "fork", "approvals"]),
                           "gemini": ChatProviderInfo(transport: "acp", features: ["approvals"]),
                           "quiet": ChatProviderInfo(transport: "acp", features: ["approvals", "rewind", "fork"])],
        agents: ["catalog", "install", "acp"],
        agentCatalog: [AgentCatalogEntry(id: "gemini", name: "Gemini CLI", chat: true, terminal: true),
                       AgentCatalogEntry(id: "quiet", name: "Quiet Agent", chat: true, terminal: false)].compactMap { $0 })

    private func client(_ host: ScriptedHost) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "t", transport: host)
    }

    private func environment(_ client: APIClient, capabilities: CapabilitiesResponse? = nil) -> ChatSessionStore.Environment {
        ChatSessionStore.Environment(client: client, capabilities: capabilities ?? host, reachable: true, connectionEpoch: 0,
                                     active: true, refreshGeneration: nil)
    }

    private func eventually(_ what: String = "condition", within seconds: Double = 3, _ condition: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)", file: file, line: line)
    }

    private static let ready = #"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#
    private static func snapshot(provider: String = "gemini", messages: String = "[]", state: String = "idle") -> String {
        #"{"seq":0,"type":"snapshot","chat":{"id":"gemini:1","title":"Gemini CLI chat","titleSource":"default","provider":"\#(provider)"},"messages":\#(messages),"hasMore":false,"status":{"state":"\#(state)"},"interactions":[],"queue":[]}"#
    }
    private static let firstTurn = #"{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"up","kind":"text","text":"Fix the build"}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"error","error":{"code":"agent_auth_required","message":"Gemini CLI needs a sign-in: Log in with Google, or use a Gemini API key."},"parts":[]}"#
    private static let secondTurn = #"{"id":"u2","role":"user","turnId":"u2","ord":3,"parts":[{"id":"u2p","kind":"text","text":"Try again"}]},{"id":"a2","role":"assistant","turnId":"u2","ord":4,"status":"error","error":{"code":"agent_auth_required","message":"Still not signed in."},"parts":[]}"#
    private static let failedTurn = "[" + firstTurn + "]"

    nonisolated private static func signInRefusal(_ request: URLRequest) throws -> (Int, String) {
        if request.url?.path == "/v1/messages", request.httpMethod == "POST" {
            return (401, #"{"error":{"code":"agent_auth_required","message":"Sign in with: Log in with Google; Gemini API key."}}"#)
        }
        return try ScriptedHost.defaultResponder(request)
    }

    // MARK: Continue with Another Model

    /// An ACP agent's new chat takes `<id>/default` or no model and no mode or effort (docs/HOST-API.md
    /// "Continue with another model"): the sheet offers neither picker for it, even when the host has
    /// learned the agent's modes, and the store never sends them. AgentLand's own agents keep theirs.
    func testContinuingWithAnACPAgentSendsNoModeOrEffort() async throws {
        let listedModes = ChatOptionsResponse(models: [AgentModelOption(id: "gemini/default", name: "Default", provider: "Gemini CLI")],
                                              defaultModel: "gemini/default", agents: ["build"],
                                              modes: [ChatModeOption(id: "default", name: "Default"), ChatModeOption(id: "yolo", name: "YOLO")],
                                              defaultMode: "default")
        let gemini = AgentProvider(id: "gemini", name: "Gemini CLI")
        XCTAssertEqual(ChatContinueSheet.modes(listedModes, provider: gemini), [], "No mode picker for an ACP agent")
        XCTAssertEqual(ChatContinueSheet.initialMode(listedModes, provider: gemini), "")
        XCTAssertEqual(ChatContinueSheet.efforts(listedModes, model: "gemini/default", provider: gemini), [])
        let codexOptions = ChatOptionsResponse(models: [AgentModelOption(id: "codex/gpt", name: "GPT", provider: "Codex", efforts: ["low", "high"],
                                                                         defaultEffort: "high")],
                                               defaultModel: "codex/gpt", agents: ["build"],
                                               modes: [ChatModeOption(id: "auto-review", name: "Auto review"), ChatModeOption(id: "ask", name: "Ask")],
                                               defaultMode: "auto-review")
        XCTAssertEqual(ChatContinueSheet.modes(codexOptions, provider: .codex), ["auto-review", "ask"])
        XCTAssertEqual(ChatContinueSheet.initialMode(codexOptions, provider: .codex), "auto-review")
        XCTAssertEqual(ChatContinueSheet.efforts(codexOptions, model: "codex/gpt", provider: .codex), ["low", "high"])
        XCTAssertEqual(ChatContinueSheet.initialEffort(codexOptions, model: "codex/gpt", provider: .codex), "high")

        let scripted = ScriptedHost { request in
            if request.url?.path == "/v1/chat/continue" {
                return (201, #"{"id":"gemini:9","title":"Gemini CLI chat (continued)","projectId":"p","provider":"gemini","parentSessionId":"gemini:1","seed":{"included":2,"omitted":0,"chars":80}}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        let continuing = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "codex", "gemini"],
                                              chatFeatures: ["continue"], agents: ["catalog", "install", "acp"], agentCatalog: host.agentCatalog)
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted), capabilities: continuing))
        var opened: [String] = []
        store.callbacks.openChat = { opened.append($0.id) }
        func sent() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(scripted.requests(to: "/v1/chat/continue").last?.httpBody)) as? [String: Any])
        }

        let created = await store.continueChat(provider: gemini, model: "gemini/default", mode: "yolo", effort: "high")
        XCTAssertTrue(created)
        XCTAssertEqual(opened, ["gemini:9"])
        var body = try sent()
        XCTAssertEqual(body["provider"] as? String, "gemini")
        XCTAssertEqual(body["model"] as? String, "gemini/default")
        XCTAssertNil(body["mode"], "No mode for an ACP agent")
        XCTAssertNil(body["effort"], "No effort for an ACP agent")

        _ = await store.continueChat(provider: gemini, model: "anthropic/claude", mode: nil, effort: nil)
        body = try sent()
        XCTAssertNil(body["model"], "Only <id>/default is a model an ACP agent takes")

        _ = await store.continueChat(provider: .codex, model: "codex/gpt", mode: "ask", effort: "high")
        body = try sent()
        XCTAssertEqual(body["mode"] as? String, "ask", "AgentLand's own agents keep their mode")
        XCTAssertEqual(body["effort"] as? String, "high")
    }

    // MARK: Fork

    /// A fork is made with its chat's title and " (fork)", cut to the host's 200 bytes at a character: a title
    /// in another script takes up to four bytes a character.
    func testAForksTitleFitsTheHostsLimit() async throws {
        let title = String(repeating: "月", count: 100)
        let scripted = ScriptedHost { request in
            if request.url?.path == "/v1/chat/fork" {
                return (201, #"{"id":"quiet:2","title":"Forked","projectId":"p","provider":"quiet"}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        scripted.enqueue([Self.ready, #"{"seq":0,"type":"snapshot","chat":{"id":"quiet:1","title":"\#(title)","titleSource":"device","provider":"quiet"},"messages":[],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let store = ChatSessionStore(identity: .init(hostID: "h", projectID: "p", sessionID: "quiet:1", tabID: UUID()))
        store.update(environment(try client(scripted)))
        await eventually("the snapshot") { store.info?.title == title }
        XCTAssertTrue(store.canFork)
        var opened: [String] = []
        store.callbacks.openChat = { opened.append($0.id) }

        await store.fork(from: nil)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(scripted.requests(to: "/v1/chat/fork").last?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["title"] as? String, String(repeating: "月", count: 66), "198 bytes, cut at a character")
        XCTAssertEqual(opened, ["quiet:2"])
    }

    // MARK: The agent in the chat screen

    func testTheAgentIsNamedByTheHostsCatalogAndOffersOnlyTheFeaturesItsInfoLists() async throws {
        let scripted = ScriptedHost()
        scripted.enqueue([Self.ready, Self.snapshot()])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted)))
        await eventually("the snapshot") { store.provider.id == "gemini" }
        XCTAssertEqual(store.provider.displayName, "Gemini CLI", "The snapshot's provider takes the catalog's name")
        XCTAssertFalse(store.canRewind, "No rewind for an ACP agent that does not list it")
        XCTAssertFalse(store.canFork, "No fork either")
        XCTAssertFalse(store.rewindRestoresFiles)
        XCTAssertTrue(store.effortChoices.isEmpty)

        // A host that lists them for the agent gets them.
        let quiet = ChatSessionStore(identity: .init(hostID: "h", projectID: "p", sessionID: "quiet:1", tabID: UUID()))
        let other = ScriptedHost()
        other.enqueue([Self.ready, Self.snapshot(provider: "quiet")])
        quiet.update(environment(try client(other)))
        await eventually("the snapshot") { quiet.provider.id == "quiet" }
        XCTAssertEqual(quiet.provider.displayName, "Quiet Agent")
        XCTAssertTrue(quiet.canRewind)
        XCTAssertTrue(quiet.canFork)
    }

    func testRunAgainForAnACPAgentOnlyWhenItsInfoListsRegenerate() async throws {
        // The host lists `regenerate` because one of its agents can; an ACP agent's chat offers Run Again only
        // when its own info lists it (it has no rewind to fall back on).
        let done = #"[{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"up","kind":"text","text":"Hi"}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","parts":[{"id":"ap","kind":"text","text":"Hello"}]}]"#
        let scripted = ScriptedHost()
        scripted.enqueue([Self.ready, Self.snapshot(messages: done)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted)))
        await eventually("the snapshot") { store.provider.id == "gemini" && store.latestUserMessageID != nil }
        XCTAssertTrue(host.supports(.regenerate))
        XCTAssertFalse(store.canRunAgain, "No Run Again the host would refuse")

        let listed = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "gemini"],
                                          chatFeatures: ["events", "regenerate"],
                                          chatProviderInfo: ["gemini": ChatProviderInfo(transport: "acp", features: ["regenerate"])],
                                          agents: ["catalog"], agentCatalog: host.agentCatalog)
        store.update(environment(try client(scripted), capabilities: listed))
        XCTAssertTrue(store.canRunAgain, "Listed for the agent: offered")
        XCTAssertEqual(store.runAgainConfirmation, "The latest reply is replaced by a new one.")
    }

    func testANameArrivingWithLaterCapabilitiesRenamesTheAgent() async throws {
        let scripted = ScriptedHost()
        scripted.enqueue([Self.ready, Self.snapshot()])
        let store = ChatSessionStore(identity: identity)
        let bare = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "gemini"], chatFeatures: ["events"],
                                        chatProviderInfo: ["gemini": ChatProviderInfo(transport: "acp", features: [])])
        store.update(environment(try client(scripted), capabilities: bare))
        await eventually("the snapshot") { store.provider.id == "gemini" }
        XCTAssertEqual(store.provider.displayName, "gemini", "Without the catalog it goes by its id")
        store.update(environment(try client(scripted)))
        XCTAssertEqual(store.provider.displayName, "Gemini CLI", "The catalog's name once the host lists it")
        store.update(environment(try client(scripted), capabilities: bare))
        XCTAssertEqual(store.provider.displayName, "Gemini CLI", "A catalog without it keeps the name the chat has")
    }

    // MARK: Sign-in

    func testARefusedSendShowsTheSignInNoticeAndOpenInTerminalOpensTheAgentsProgram() async throws {
        let scripted = ScriptedHost(responder: Self.signInRefusal)
        scripted.enqueue([Self.ready, Self.snapshot()])
        let store = ChatSessionStore(identity: identity)
        var opened: [TerminalProgram] = []
        store.callbacks.openTerminal = { opened.append($0) }
        store.update(environment(try client(scripted)))
        await eventually("ready") { store.isResolved(for: nil) }
        XCTAssertNil(store.signIn)

        store.setDraft("Fix the build")
        await store.send()
        let signIn = try XCTUnwrap(store.signIn, "The refusal asks for a sign-in")
        XCTAssertEqual(signIn.detail, "Sign in with: Log in with Google; Gemini API key.", "The host's words, with its ways to sign in")
        XCTAssertEqual(ChatSignInNotice.title(provider: store.provider),
                       "Sign in to Gemini CLI: open it in a terminal and follow its sign-in")
        guard case .notSent = store.pendingSends.first?.delivery else { return XCTFail("The message was not sent") }
        XCTAssertEqual(scripted.requests(to: "/v1/messages").count, 1, "Nothing is sent again by itself")

        XCTAssertEqual(store.signInProgram?.id, "gemini")
        XCTAssertTrue(store.canOpenSignInTerminal)
        store.openSignInTerminal()
        XCTAssertEqual(opened.map(\.id), ["gemini"], "Open in Terminal starts the agent's own terminal program")
        XCTAssertEqual(opened.first?.displayName, "Gemini CLI")

        // Signed in, a send goes through and the notice goes.
        scripted.respond(ScriptedHost.defaultResponder)
        store.setDraft("Now fix it")
        await store.send()
        XCTAssertNil(store.signIn)
    }

    func testAFailedReplyShowsTheNoticeUntilDismissedOrANewerTurnStarts() async throws {
        let scripted = ScriptedHost()
        scripted.enqueue([Self.ready, Self.snapshot(messages: Self.failedTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted)))
        await eventually("the notice") { store.signIn != nil }
        XCTAssertEqual(store.signIn?.detail, "Gemini CLI needs a sign-in: Log in with Google, or use a Gemini API key.")
        let copy = ChatErrorCopy.category(try XCTUnwrap(store.projection.latestReply?.error), provider: store.provider)
        XCTAssertEqual(copy.title, "Sign In to Gemini CLI")
        XCTAssertEqual(copy.guidance, "Open it in a terminal and follow its sign-in, then choose Run Again.")

        store.dismissSignIn()
        XCTAssertNil(store.signIn)
        // The same failed reply read again (a reconnect's snapshot) does not bring it back.
        scripted.push(Self.snapshot(messages: Self.failedTurn).replacingOccurrences(of: #""seq":0"#, with: #""seq":5"#))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.signIn, "Dismissed for that reply")

        // A newer prompt starts another turn: its reply alone says whether a sign-in is still needed.
        let asked = "[" + Self.firstTurn + "," + #"{"id":"u2","role":"user","turnId":"u2","ord":3,"parts":[{"id":"u2p","kind":"text","text":"Try again"}]}"# + "]"
        scripted.push(Self.snapshot(messages: asked, state: "running").replacingOccurrences(of: #""seq":0"#, with: #""seq":7"#))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.signIn, "Nothing to show while the newer turn has no reply")
        scripted.push(Self.snapshot(messages: "[" + Self.firstTurn + "," + Self.secondTurn + "]").replacingOccurrences(of: #""seq":0"#, with: #""seq":9"#))
        await eventually("the newer reply's notice") { store.signIn?.detail == "Still not signed in." }
    }

    func testAnAgentWithoutATerminalProgramGetsTheNoticeWithoutOpenInTerminal() async throws {
        let quietIdentity = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "quiet:1", tabID: UUID())
        let scripted = ScriptedHost { request in
            if request.url?.path == "/v1/chat/options" {
                return (401, #"{"error":{"code":"agent_auth_required","message":"Quiet Agent needs a sign-in."}}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        scripted.enqueue([Self.ready, Self.snapshot(provider: "quiet")])
        let store = ChatSessionStore(identity: quietIdentity)
        store.callbacks.openTerminal = { _ in XCTFail("No program to open") }
        store.update(environment(try client(scripted)))
        await eventually("the notice from the options") { store.signIn != nil }
        XCTAssertEqual(store.provider.displayName, "Quiet Agent")
        XCTAssertNil(store.signInProgram)
        XCTAssertFalse(store.canOpenSignInTerminal, "Open in Terminal only for an agent with a terminal program")
        store.openSignInTerminal()
    }

    func testOtherFailuresDoNotAskForASignIn() async throws {
        let scripted = ScriptedHost { request in
            if request.url?.path == "/v1/messages", request.httpMethod == "POST" {
                return (409, #"{"error":{"code":"agent_busy","message":"Busy."}}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        scripted.enqueue([Self.ready, Self.snapshot()])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(scripted)))
        await eventually("ready") { store.isResolved(for: nil) }
        store.setDraft("Hello")
        await store.send()
        XCTAssertNil(store.signIn)
        XCTAssertFalse(store.canOpenSignInTerminal, "No callback set, and no notice")
    }
}
