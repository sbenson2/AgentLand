import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandWorkspace

/// The host's capabilities read again when the pulse names another plain chats revision or a plain chat finds the
/// host's `chat` agent gone (docs/HOST-API.md "Plain chats").
@MainActor final class PlainChatsCapabilitiesTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "capabilities-\(name)-\(UUID())"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Chat (`workspaceChats`) and the Chats space, whose older chats stay readable.
    nonisolated static let withPlainChats = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"],"plainChats":{"projectId":"chats","tools":["memory"]},"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[]}]}}"#
    nonisolated static let withoutPlainChats = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"]}"#

    /// A host whose capabilities the test changes between reads, counting them.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var body = PlainChatsCapabilitiesTests.withoutPlainChats
        private var reads = 0
        private var failing = false
        var capabilities: String {
            get { lock.withLock { body } }
            set { lock.withLock { body = newValue } }
        }
        var fails: Bool {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }
        var count: Int { lock.withLock { reads } }
        func read() throws -> (Int, String) {
            try lock.withLock {
                reads += 1
                if failing { throw URLError(.networkConnectionLost) }
                return (200, body)
            }
        }
    }

    private func attached(_ answers: Answers, defaults: UserDefaults) async throws -> (WorkspaceModel, ScriptedHost) {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in try answers.read() }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"}]}"#) }
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        return (model, host)
    }

    // MARK: Capabilities

    func testCapabilitiesAreReadAgainForTheAttachedHostOnly() async throws {
        let answers = Answers()
        let (model, _) = try await attached(answers, defaults: try defaults())
        XCTAssertFalse(model.offersPlainChats)
        answers.capabilities = Self.withPlainChats
        let read = await model.refreshCapabilities()
        XCTAssertTrue(read)
        XCTAssertTrue(model.offersPlainChats, "The host's answer is the workspace's now")

        // An answer that arrives after another host was attached is dropped.
        let gate = Gate()
        let slow = ScriptedHost()
        slow.on("/v1/capabilities") { _ in
            await gate.wait()
            return (200, PlainChatsCapabilitiesTests.withPlainChats)
        }
        slow.on("/v1/projects") { _ in (200, #"{"projects":[]}"#) }
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "t", transport: slow))
        let reading = Task { await model.refreshCapabilities() }
        await waitUntil("the read") { !slow.requests("/v1/capabilities").isEmpty }
        model.attach(hostID: "https://other.example|device-b", identity: ConnectionIdentity(host: "https://other.example", deviceID: "device-b"),
                     client: nil)
        await gate.open()
        let late = await reading.value
        XCTAssertFalse(late)
        XCTAssertNil(model.capabilities, "Another host's capabilities never reach this one")
    }

    /// A read started earlier that answers later (the one attaching makes with the projects, say) never undoes
    /// the answer of a read started after it; without a newer answer, it applies.
    func testAnOlderCapabilitiesReadNeverUndoesANewerOne() async throws {
        let gate = Gate()
        let answers = Answers()
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in
            // The first read waits and answers as the host was then, without plain chats.
            if answers.count == 0 {
                _ = try answers.read()
                await gate.wait()
                return (200, PlainChatsCapabilitiesTests.withoutPlainChats)
            }
            answers.capabilities = PlainChatsCapabilitiesTests.withPlainChats
            return try answers.read()
        }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"}]}"#) }
        let model = WorkspaceModel(defaults: try defaults())
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        let projects = Task { await model.refreshProjects() }
        await waitUntil("the first read") { answers.count == 1 }
        let newer = await model.refreshCapabilities()
        XCTAssertTrue(newer)
        XCTAssertTrue(model.offersPlainChats)
        await gate.open()
        await projects.value
        XCTAssertEqual(model.projects.map(\.id), ["a"])
        XCTAssertTrue(model.offersPlainChats, "The older read's answer does not undo the newer one")

        // Without a newer answer an older read applies: the next attach's read does.
        let (other, _) = try await attached(Answers(), defaults: try defaults("other"))
        XCTAssertNotNil(other.capabilities)
    }

    /// Another revision reads the capabilities once; the same one again does not; a read that failed leaves the
    /// revision unread, so the line after the pulse's next `ready` reads them again.
    func testThePulsesPlainChatsRevisionReadsTheCapabilitiesAgain() async throws {
        let answers = Answers()
        let (model, _) = try await attached(answers, defaults: try defaults())
        let before = answers.count
        answers.capabilities = Self.withPlainChats
        model.notePlainChatsRevision("r1")
        await waitUntil("the read") { model.offersPlainChats }
        XCTAssertEqual(answers.count, before + 1)
        model.notePlainChatsRevision("r1")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(answers.count, before + 1, "The revision read already is not read again")

        answers.capabilities = Self.withoutPlainChats
        model.notePlainChatsRevision("r2")
        await waitUntil("plain chats gone") { !model.offersPlainChats }
        XCTAssertEqual(answers.count, before + 2)

        answers.fails = true
        answers.capabilities = Self.withPlainChats
        model.notePlainChatsRevision("r3")
        await waitUntil("the failed read") { answers.count == before + 3 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.offersPlainChats, "A failed read keeps what was read before")
        answers.fails = false
        model.notePlainChatsRevision("r3")
        await waitUntil("the read again") { model.offersPlainChats }

        // Another host starts from no revision: its first line reads its capabilities.
        let (other, _) = try await attached(answers, defaults: try defaults("other"))
        let counted = answers.count
        other.notePlainChatsRevision("r3")
        await waitUntil("the other host's read") { answers.count == counted + 1 }
    }

    /// A plain chat's send the host refuses with 503 `agent_unavailable` sends nothing again and reads the
    /// capabilities, which no longer list plain chats.
    func testASendTheHostRefusesForItsChatAgentReadsTheCapabilitiesAgain() async throws {
        let answers = Answers()
        answers.capabilities = Self.withPlainChats
        let (model, host) = try await attached(answers, defaults: try defaults())
        XCTAssertTrue(model.offersPlainChats)
        host.on("/v1/chat/options") { _ in (200, #"{"models":[],"defaultModel":"","agents":[]}"#) }
        host.on("/v1/messages") { _ in (503, #"{"error":{"code":"agent_unavailable","message":"OpenCode isn’t ready."}}"#) }
        host.enqueueStream("ses_plain", [#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#,
                                         #"{"seq":0,"type":"snapshot","chat":{"id":"ses_plain","title":"New chat","provider":"opencode"},"messages":[],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let tab = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "ses_plain", title: "New chat")
        model.open(tab)
        let store = model.chatStore(for: tab)
        store.update(ChatSessionStore.Environment(client: model.client, capabilities: model.capabilities, reachable: true, connectionEpoch: 0,
                                                  active: true, refreshGeneration: nil))
        defer { store.shutdown() }
        await waitUntil("the chat") { store.isResolved(for: nil) }
        let before = answers.count
        answers.capabilities = Self.withoutPlainChats
        store.setDraft("Hello")
        await store.send()
        guard case .notSent? = store.pendingSends.first?.delivery else { return XCTFail("Refused: not sent") }
        await waitUntil("the capabilities read again") { !model.offersPlainChats }
        XCTAssertEqual(answers.count, before + 1)
        XCTAssertEqual(host.requests("/v1/messages").count, 1, "Nothing is sent again")
    }

    func testANewPlainChatTheHostRefusesSaysChatsArentReady() async throws {
        let answers = Answers()
        answers.capabilities = Self.withPlainChats
        let (model, host) = try await attached(answers, defaults: try defaults())
        model.hostName = "Studio Mac"
        host.on("/v1/sessions") { _ in (503, #"{"error":{"code":"agent_unavailable","message":"OpenCode isn’t ready."}}"#) }
        let before = answers.count
        model.selectProject("a")
        model.newPlainChat()
        await waitUntil("the refusal") { model.creationIssue != nil }
        XCTAssertEqual(model.creationIssue, "Chats aren’t ready on Studio Mac yet. Nothing was started; try again in a moment.")
        await waitUntil("the capabilities read again") { answers.count == before + 1 }
        XCTAssertNil(model.currentTab)

        // A refused sign-in says what the host says, and that nothing started.
        host.on("/v1/sessions") { _ in (400, #"{"error":{"code":"agent_auth_required","message":"Claude Code is signed in with an API key. Sign in with your Claude subscription (claude /login)."}}"#) }
        model.creationIssue = nil
        model.newPlainChat()
        await waitUntil("the sign-in refusal") { model.creationIssue != nil }
        XCTAssertEqual(model.creationIssue, "Claude Code is signed in with an API key. Sign in with your Claude subscription (claude /login). Nothing was started.")
        XCTAssertNil(model.currentTab)
    }
}
