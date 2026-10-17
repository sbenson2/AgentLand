import XCTest
import AgentLandCore
import AgentLandChat
import AgentLandArchive
@testable import AgentLandWorkspace

/// A model double: the names it gives, the inputs it saw, and how many ran at once.
final class FakeNamer: ChatNamer, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    private let otherwise: String?
    private var seen: [ChatNamingInput] = []
    private var running = 0
    private var peak = 0
    private let available: Bool
    private let gate: Gate?

    init(_ answers: [String?] = [], otherwise: String? = "Fix the login redirect", available: Bool = true, gate: Gate? = nil) {
        self.answers = answers; self.otherwise = otherwise; self.available = available; self.gate = gate
    }

    var isAvailable: Bool { available }
    var inputs: [ChatNamingInput] { lock.withLock { seen } }
    var mostAtOnce: Int { lock.withLock { peak } }

    func name(for input: ChatNamingInput) async -> String? {
        let answer = lock.withLock { () -> String? in
            seen.append(input)
            running += 1
            peak = max(peak, running)
            return answers.isEmpty ? otherwise : answers.removeFirst()
        }
        if let gate { await gate.wait() }
        // Long enough that names made at the same time would overlap.
        try? await Task.sleep(for: .milliseconds(2))
        lock.withLock { running -= 1 }
        return answer
    }
}

/// Naming with the device's model: after a finished turn and in the foreground pass; one at a time, at most
/// 20 per foreground period, checked names only, the stale answer taken, and never for a host without
/// `title`, in Low Power Mode, while locked or in the background, or without the model.
@MainActor final class ChatNamingTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []
    private var seq: UInt64 = 0
    private var lowPower = false

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated private static let titleFeature = #"{"interactions":true,"terminal":true,"chatFeatures":["events","title"],"archive":{"version":1,"features":["sync"]}}"#
    nonisolated private static let withoutTitle = #"{"interactions":true,"terminal":true,"chatFeatures":["events"],"archive":{"version":1,"features":["sync"]}}"#

    /// A host that takes names: it answers with the name it was sent, as the device's, for the message it
    /// describes.
    nonisolated private static let echo: ScriptedHost.Handler = { request in
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
        return (200, #"{"title":"\#(body["title"] ?? "")","titleSource":"device","titleBasis":"\#(body["basedOn"] ?? "")"}"#)
    }

    private func host(capabilities: String = titleFeature, title: @escaping ScriptedHost.Handler = echo,
                      sessions: [String: String] = [:]) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p","name":"Project"},{"id":"q","name":"Other"}]}"#) }
        host.on("/v1/chat/options") { _ in (200, #"{"models":[],"defaultModel":"","agents":["build"]}"#) }
        host.on("/v1/chat/title", title)
        host.on("/v1/sessions") { request in (200, sessions[ScriptedHost.query(request)["projectId"] ?? ""] ?? #"{"sessions":[]}"#) }
        return host
    }

    private func attached(_ host: ScriptedHost, namer: FakeNamer) async throws -> WorkspaceModel {
        let suite = "chat-naming-\(UUID())"
        suites.append(suite)
        let model = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        model.naming.namer = namer
        model.naming.lowPowerMode = { [unowned self] in self.lowPower }
        model.naming.now = { Self.now }
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        model.selectProject("p")
        model.naming.foregroundBegan()
        return model
    }

    // MARK: After a finished turn

    nonisolated private static let prompt = "Why does /login loop after a passkey sign-in? " + String(repeating: "x", count: 1_300)
    nonisolated private static let reply = "The session cookie is set for the wrong domain. " + String(repeating: "y", count: 700)
    nonisolated private static func turn(user: String = "u1", assistant: String = "a1") -> String {
        #"[{"id":"\#(user)","role":"user","turnId":"\#(user)","ord":1,"parts":[{"id":"\#(user)p","kind":"text","text":"\#(prompt)"}]},{"id":"\#(assistant)","role":"assistant","turnId":"\#(user)","ord":2,"status":"complete","parts":[{"id":"\#(assistant)p","kind":"text","text":"\#(reply)"}]}]"#
    }

    /// Opens chat `id` and streams it, as its selected and active view would.
    private func streamingChat(_ id: String = "ses_1", in model: WorkspaceModel, host: ScriptedHost,
                               naming: String = "") async -> (WorkspaceTab, ChatSessionStore) {
        let tab = WorkspaceTab(kind: .chat, projectID: "p", resourceID: id, title: "New chat")
        model.open(tab)
        seq = 0
        host.enqueueStream(id, [#"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#,
                                #"{"seq":0,"type":"snapshot","chat":{"id":"\#(id)","title":"Fix login","provider":"opencode"\#(naming)},"messages":\#(Self.turn()),"hasMore":false,"status":{"state":"running"},"interactions":[],"queue":[]}"#])
        let store = model.chatStore(for: tab)
        store.update(ChatSessionStore.Environment(client: model.client, capabilities: model.capabilities, reachable: true,
                                                  connectionEpoch: model.connectionEpoch, active: true, refreshGeneration: nil))
        await waitUntil("the snapshot") { store.hasContent }
        return (tab, store)
    }

    /// Ends a turn on chat `store`'s stream and waits until the store has applied it.
    private func finishTurn(_ host: ScriptedHost, _ store: ChatSessionStore, file: StaticString = #filePath, line: UInt = #line) async {
        seq += 1
        let before = store.activityCount
        host.push(store.identity.sessionID, #"{"seq":\#(seq),"type":"turn.finished","turnId":"u1","outcome":"completed"}"#)
        await waitUntil("the finished turn", timeout: 3, { store.activityCount != before }, file: file, line: line)
    }

    func testAFinishedTurnNamesTheChatForItsNewestMessage() async throws {
        let namer = FakeNamer(["\"Fix the login redirect.\""])
        let host = host()
        let model = try await attached(host, namer: namer)
        let (tab, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        XCTAssertEqual(model.tab(tab.id)?.title, "Fix login")

        await finishTurn(host, store)
        await waitUntil("the name sent") { host.requests("/v1/chat/title").count == 1 }
        await model.naming.settle()
        let input = try XCTUnwrap(namer.inputs.first)
        XCTAssertEqual(input.prompt, String(Self.prompt.prefix(1_200)))
        XCTAssertEqual(input.reply, String(Self.reply.prefix(600)))
        XCTAssertEqual(input.newestMessageID, "a1")
        XCTAssertEqual(host.bodies("/v1/chat/title") as? [[String: String]],
                       [["projectId": "p", "sessionId": "ses_1", "title": "Fix the login redirect", "basedOn": "a1"]])
        XCTAssertEqual(model.tab(tab.id)?.title, "Fix the login redirect", "The host's answer names the tab at once")
        XCTAssertEqual(model.naming.namesThisPeriod, 1)
    }

    func testAChatAlreadyNamedByADeviceForItsNewestMessageIsLeftAlone() async throws {
        let namer = FakeNamer()
        let host = host()
        let model = try await attached(host, namer: namer)
        let (_, store) = await streamingChat(in: model, host: host, naming: #","titleSource":"device","titleBasis":"a1""#)
        defer { store.shutdown() }
        XCTAssertEqual(store.info?.titleSource, .device)
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        await model.naming.settle()
        XCTAssertEqual(namer.inputs, [])
        XCTAssertEqual(host.requests("/v1/chat/title").count, 0)
    }

    func testNothingIsSentToAHostWithoutTheTitleFeature() async throws {
        let namer = FakeNamer()
        let host = host(capabilities: Self.withoutTitle, sessions: ["p": #"{"sessions":[{"id":"ses_1","title":"Fix login","projectId":"p"}]}"#])
        let model = try await attached(host, namer: namer)
        let (_, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        let archive = try await recentArchive(chats: 3)
        model.openArchive({ archive })
        await waitUntil("the copy") { model.archive === archive }
        model.naming.archiveCaughtUp()
        await model.naming.settle()
        XCTAssertEqual(namer.inputs, [], "The model is not asked for a host that takes no names")
        XCTAssertEqual(host.requests("/v1/chat/title").count, 0)
        XCTAssertEqual(host.requests("/v1/sessions").count, 0, "The foreground pass does not start")
        archive.close()
    }

    func testAStaleAnswerIsTakenAndNotRetried() async throws {
        let namer = FakeNamer()
        let host = host(title: { _ in
            (409, #"{"error":{"code":"title_stale","message":"A newer title exists","title":"Tidy imports","titleSource":"device","titleBasis":"a9"}}"#)
        })
        let model = try await attached(host, namer: namer)
        let (tab, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        await finishTurn(host, store)
        await waitUntil("the stale answer") { model.tab(tab.id)?.title == "Tidy imports" }
        await model.naming.settle()
        XCTAssertEqual(host.requests("/v1/chat/title").count, 1)
    }

    func testOtherFailuresAreDroppedQuietlyUntilTheNextTrigger() async throws {
        let namer = FakeNamer()
        let host = host(title: { _ in (502, #"{"error":{"code":"provider_unavailable","message":"The provider is unavailable"}}"#) })
        let model = try await attached(host, namer: namer)
        let (tab, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        await finishTurn(host, store)
        await waitUntil("the refused name") { host.requests("/v1/chat/title").count == 1 }
        await model.naming.settle()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.requests("/v1/chat/title").count, 1, "Not sent again by itself")
        XCTAssertEqual(model.tab(tab.id)?.title, "Fix login")
        XCTAssertNil(store.notice)
        XCTAssertNil(model.sidebar.notice)
        XCTAssertNil(model.creationIssue)

        await finishTurn(host, store)
        await waitUntil("the next trigger's name") { host.requests("/v1/chat/title").count == 2 }
    }

    func testGenericNamesAreNotSent() async throws {
        let namer = FakeNamer(["Chat"])
        let host = host()
        let model = try await attached(host, namer: namer)
        let (_, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        await finishTurn(host, store)
        await waitUntil("the model's answer") { namer.inputs.count == 1 }
        await model.naming.settle()
        XCTAssertEqual(host.requests("/v1/chat/title").count, 0)
        XCTAssertEqual(model.naming.namesThisPeriod, 1, "The model ran")
    }

    func testLowPowerModeTheLockAndTheBackgroundStopNaming() async throws {
        let namer = FakeNamer()
        let host = host()
        let model = try await attached(host, namer: namer)
        let (_, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }

        lowPower = true
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(namer.inputs.count, 0, "Not in Low Power Mode")

        lowPower = false
        model.locked = true
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(namer.inputs.count, 0, "Not while locked")
        model.locked = false

        model.naming.backgroundBegan()
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(namer.inputs.count, 0, "Not in the background")

        // A name under way when the app goes to the background is dropped.
        let gate = Gate()
        let held = FakeNamer(gate: gate)
        model.naming.namer = held
        model.naming.foregroundBegan()
        await finishTurn(host, store)
        await waitUntil("the model running") { held.inputs.count == 1 }
        model.naming.backgroundBegan()
        await gate.open()
        await model.naming.settle()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.requests("/v1/chat/title").count, 0)
    }

    func testWithoutTheModelNothingIsReadOrSent() async throws {
        let namer = FakeNamer(available: false)
        let host = host(sessions: ["p": #"{"sessions":[{"id":"c01","title":"Chat","projectId":"p"}]}"#])
        let model = try await attached(host, namer: namer)
        let (_, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        let archive = try await recentArchive(chats: 1)
        model.openArchive({ archive })
        await waitUntil("the copy") { model.archive === archive }
        model.naming.archiveCaughtUp()
        await model.naming.settle()
        XCTAssertEqual(namer.inputs, [])
        XCTAssertEqual(model.naming.namesThisPeriod, 0)
        XCTAssertEqual(host.requests("/v1/chat/title").count, 0)
        XCTAssertEqual(host.requests("/v1/sessions").count, 0)
        archive.close()
    }

    // MARK: The foreground pass

    nonisolated private static let now = Date(timeIntervalSince1970: 1_790_424_000) // 2026-09-26T12:00:00Z

    private func stamp(daysAgo days: Double) -> String {
        Self.now.addingTimeInterval(-days * 86_400).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func chat(_ id: String, project: String = "p", daysAgo: Double) -> ArchiveChangeItem {
        .chat(ArchiveChatRecord(id: id, projectID: project, title: "Chat \(id)", createdAt: stamp(daysAgo: daysAgo), updatedAt: stamp(daysAgo: daysAgo)))
    }

    private func message(_ id: String, chat: String, _ role: MessageRole, ord: Int64, _ text: String) -> ArchiveChangeItem {
        .message(ArchiveMessageRecord(message: ConversationMessage(id: id, chatID: chat, turnID: role == .user ? id : "", role: role, ord: ord,
                                                                   createdAt: stamp(daysAgo: 1),
                                                                   parts: [ConversationPart(id: id + "p", kind: .text, text: text)])))
    }

    private func page(_ items: [ArchiveChangeItem]) -> ArchiveChangesPage {
        ArchiveChangesPage(epoch: "e1", changes: items.enumerated().map { ArchiveChange(seq: Int64($0.offset + 1), item: $0.element) },
                           cursor: "e1.\(items.count)")
    }

    /// A copy with `chats` chats active in the last day, each with a prompt and a reply.
    private func recentArchive(chats: Int) async throws -> WorkspaceArchive {
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        var items: [ArchiveChangeItem] = []
        for index in 1...chats {
            let id = String(format: "c%02d", index)
            items += [chat(id, daysAgo: Double(index) / 100), message("u-\(id)", chat: id, .user, ord: 1, "Prompt \(id)"),
                      message("a-\(id)", chat: id, .assistant, ord: 2, "Reply \(id)")]
        }
        try await store.apply(page(items))
        return WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
    }

    private final class OnePageFeed: ArchiveChangeFeed, @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [ArchiveChangesPage]
        private let cursor: String
        init(_ page: ArchiveChangesPage) { pages = [page]; cursor = page.cursor }
        func archiveChanges(after: String?, limit: Int, wait: Duration?) async throws -> ArchiveChangesPage {
            lock.withLock { pages.isEmpty ? ArchiveChangesPage(epoch: "e1", changes: [], cursor: cursor) : pages.removeFirst() }
        }
    }

    /// Once the copy catches up in the foreground, its chats of the last 7 days whose title describes an
    /// older message than their newest are named, most recent first; a device's name for the newest
    /// message, a title for a message the copy lacks and chats the host no longer lists are left alone.
    func testTheForegroundPassNamesRecentChatsWhoseTitleIsBehind() async throws {
        let sessions = [
            "p": #"""
            {"sessions":[{"id":"c1","title":"Old","projectId":"p","titleSource":"auto","titleBasis":"u1"},
                         {"id":"c2","title":"Old","projectId":"p"},
                         {"id":"c3","title":"Named","projectId":"p","titleSource":"device","titleBasis":"a3"},
                         {"id":"c4","title":"Auto","projectId":"p","titleSource":"auto","titleBasis":"a4"},
                         {"id":"c5","title":"Ahead","projectId":"p","titleSource":"auto","titleBasis":"a5-later"},
                         {"id":"c6","title":"New chat","projectId":"p","titleSource":"default"},
                         {"id":"c9","title":"Seed only","projectId":"p"}]}
            """#,
            "q": #"{"sessions":[{"id":"c8","title":"Elsewhere","projectId":"q","titleSource":"provider","titleBasis":"u8"}]}"#,
        ]
        let namer = FakeNamer()
        let host = host(sessions: sessions)
        let model = try await attached(host, namer: namer)
        var items: [ArchiveChangeItem] = []
        for (id, days) in [("1", 0.5), ("2", 8.0), ("3", 0.6), ("4", 0.7), ("5", 0.8), ("6", 1.5), ("7", 1.6)] {
            items += [chat("c\(id)", daysAgo: days), message("u\(id)", chat: "c\(id)", .user, ord: 1, "Prompt \(id)"),
                      message("a\(id)", chat: "c\(id)", .assistant, ord: 2, "Reply \(id)")]
        }
        items += [chat("c8", project: "q", daysAgo: 2.5), message("u8", chat: "c8", .user, ord: 1, "Prompt 8"),
                  message("a8", chat: "c8", .assistant, ord: 2, "Reply 8"),
                  chat("c9", daysAgo: 3), message("a9", chat: "c9", .assistant, ord: 1, "A reply with no prompt")]
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(Self.titleFeature.utf8))
        let engine = SyncEngine(store: store, feed: OnePageFeed(page(items)), capabilities: capabilities, followInterval: .milliseconds(50))
        let archive = WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil, engine: engine)
        model.openArchive({ archive })
        await waitUntil("the copy") { model.archive === archive }
        defer { archive.close() }

        archive.setRunning(true)
        await waitUntil("three names", timeout: 5) { host.requests("/v1/chat/title").count == 3 }
        await model.naming.settle()
        XCTAssertEqual(namer.inputs.map(\.newestMessageID), ["a1", "a6", "a8"])
        XCTAssertEqual(namer.inputs.first?.prompt, "Prompt 1")
        XCTAssertEqual(namer.inputs.first?.reply, "Reply 1")
        let bodies = host.bodies("/v1/chat/title")
        XCTAssertEqual(bodies.map { $0["sessionId"] as? String }, ["c1", "c6", "c8"])
        XCTAssertEqual(bodies.map { $0["projectId"] as? String }, ["p", "p", "q"])
        XCTAssertEqual(bodies.map { $0["basedOn"] as? String }, ["a1", "a6", "a8"])

        // Once per foreground period: the copy catching up again names nothing more.
        model.naming.archiveCaughtUp()
        try await Task.sleep(for: .milliseconds(150))
        await model.naming.settle()
        XCTAssertEqual(host.requests("/v1/chat/title").count, 3)

        // The next period passes again.
        model.naming.backgroundBegan()
        model.naming.foregroundBegan()
        await waitUntil("the next period's pass", timeout: 5) { host.requests("/v1/chat/title").count == 6 }
    }

    func testAtMostTwentyNamesInAForegroundPeriodOneAtATime() async throws {
        var listed: [String] = []
        for index in 1...25 { listed.append(String(format: #"{"id":"c%02d","title":"Chat","projectId":"p"}"#, index)) }
        let host = host(sessions: ["p": #"{"sessions":[\#(listed.joined(separator: ","))]}"#])
        let namer = FakeNamer()
        let model = try await attached(host, namer: namer)
        let archive = try await recentArchive(chats: 25)
        model.openArchive({ archive })
        await waitUntil("the copy") { model.archive === archive }
        defer { archive.close() }

        model.naming.archiveCaughtUp()
        await waitUntil("twenty names", timeout: 5) { host.requests("/v1/chat/title").count == 20 }
        await model.naming.settle()
        XCTAssertEqual(namer.inputs.count, 20)
        XCTAssertEqual(namer.mostAtOnce, 1, "One name at a time")
        XCTAssertEqual(model.naming.namesThisPeriod, 20)
        XCTAssertEqual(namer.inputs.first?.newestMessageID, "a-c01", "The most recently active first")

        // The budget is spent: a finished turn names nothing more until the next period.
        let (_, store) = await streamingChat(in: model, host: host)
        defer { store.shutdown() }
        await finishTurn(host, store)
        try await Task.sleep(for: .milliseconds(50))
        await model.naming.settle()
        XCTAssertEqual(namer.inputs.count, 20)
        model.naming.backgroundBegan()
        model.naming.foregroundBegan()
        XCTAssertEqual(model.naming.namesThisPeriod, 0)
    }

    func testUITestRunsNameNothingOnTheDeviceUnlessAsked() {
        XCTAssertFalse(ChatNaming.appNamer(uiTestHooks: true, arguments: ["AgentLand", "-AgentLandUITestsDisableAnimations"]).isAvailable,
                       "UI-test runs keep the host's names")
        let asked = ChatNaming.appNamer(uiTestHooks: true, arguments: ["AgentLand", ChatNaming.uiTestsChatNamingArgument])
        XCTAssertTrue(asked is FoundationModelsChatNamer)
        XCTAssertTrue(ChatNaming.appNamer(uiTestHooks: false, arguments: ["AgentLand"]) is FoundationModelsChatNamer)
    }
}

