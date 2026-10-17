import XCTest
import AgentLandCore
@testable import AgentLandChat

/// A device copy that counts its reads.
private final class SavedTranscripts: ChatTranscriptCache, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: ChatSnapshot]
    private var readLog: [String] = []
    init(_ snapshots: [String: ChatSnapshot]) { self.snapshots = snapshots }
    var reads: [String] { lock.withLock { readLog } }
    func cachedTranscript(projectID: String, sessionID: String) async -> ChatSnapshot? {
        lock.withLock {
            readLog.append(projectID + "/" + sessionID)
            return snapshots[sessionID]
        }
    }
}

@MainActor
final class ChatTranscriptCacheTests: XCTestCase {
    private let identity = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "s", tabID: UUID())
    private let streaming = CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["events", "parts", "clientMessageId"])
    private let saved = ChatSnapshot(chat: ChatInfo(id: "s", title: "Fix login", provider: "opencode"), messages: [
        ConversationMessage(id: "u1", chatID: "s", turnID: "u1", role: .user, ord: 1, parts: [ConversationPart(id: "t", kind: .text, text: "Why does it loop?")]),
        ConversationMessage(id: "a1", chatID: "s", turnID: "u1", role: .assistant, ord: 2, parts: [ConversationPart(id: "r", kind: .text, text: "The cookie.")])
    ], status: ChatStatusInfo(state: .unknown))

    private func environment(_ host: ScriptedHost, reachable: Bool = true) throws -> ChatSessionStore.Environment {
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "t", transport: host)
        return ChatSessionStore.Environment(client: client, capabilities: streaming, reachable: reachable, connectionEpoch: 0, active: true,
                                            refreshGeneration: nil)
    }

    private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)", file: file, line: line)
    }

    func testTheSavedCopyShowsBeforeTheFirstNetworkLoadAndTheHostReplacesIt() async throws {
        let host = ScriptedHost()
        host.enqueue([])  // the stream opens and stays silent for now
        let cache = SavedTranscripts(["s": saved])
        let store = ChatSessionStore(identity: identity, transcriptCache: cache)
        store.update(try environment(host))
        await eventually("saved transcript") { store.projection.rows.count == 2 }
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.info?.title, "Fix login")
        XCTAssertEqual(cache.reads, ["p/s"])
        XCTAssertEqual(host.eventRequests.count, 1, "The network load starts after the saved copy is read")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(host.eventRequests.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "after" }, "A saved copy is not a stream position: the host sends a snapshot")

        host.push(#"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#)
        host.push(#"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"Fix the login loop","provider":"opencode"},"messages":[{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"t","kind":"text","text":"Why does it loop?"}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"parts":[{"id":"r","kind":"text","text":"The cookie."}]},{"id":"u2","role":"user","turnId":"u2","ord":3,"parts":[{"id":"t2","kind":"text","text":"Fix it"}]}],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#)
        await eventually("host snapshot") { store.projection.rows.count == 3 }
        XCTAssertEqual(store.info?.title, "Fix the login loop")
        XCTAssertEqual(store.runState, .idle)

        // Restarting the stream never reads the saved copy again.
        host.enqueue([])
        store.refreshStatus()
        await eventually("second stream") { host.eventRequests.count == 2 }
        XCTAssertEqual(cache.reads.count, 1)
    }

    func testAChatOpenedOfflineShowsTheSavedCopyInsteadOfAnError() async throws {
        let host = ScriptedHost()
        host.enqueue([#"{"error":{"code":"unavailable","message":"The host is not reachable"}}"#], hold: false, status: 503)
        let store = ChatSessionStore(identity: identity, transcriptCache: SavedTranscripts(["s": saved]))
        store.retryDelays = [.seconds(30)]
        store.update(try environment(host, reachable: false))
        await eventually("saved transcript") { store.projection.rows.count == 2 }
        await eventually("the one network attempt") { host.eventRequests.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.phase, .ready, "The saved copy is content, not an error")
        XCTAssertTrue(store.isResolved(for: nil) || store.hasContent)
        store.setDraft("Try again")
        await store.send()
        XCTAssertEqual(store.notice?.message, "Offline · your draft is kept")
        XCTAssertTrue(host.requests(to: "/v1/messages").isEmpty)
    }

    func testAChatTheDeviceHasNotSavedLoadsAsBefore() async throws {
        let host = ScriptedHost()
        host.enqueue([#"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#,
                      #"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"New chat","provider":"opencode"},"messages":[],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let cache = SavedTranscripts([:])
        let store = ChatSessionStore(identity: identity, transcriptCache: cache)
        store.update(try environment(host))
        await eventually("host snapshot") { store.isResolved(for: nil) }
        XCTAssertEqual(cache.reads, ["p/s"])
        XCTAssertTrue(store.showsLanding)
    }
}
