import XCTest
import Observation
import AgentLandCore
@testable import AgentLandChat

/// A host double: scripted event streams for `GET /v1/chat/events` and a
/// responder for every other route. Streams stay open until cancelled unless
/// a script says otherwise, like the host's.
final class ScriptedHost: APITransport, @unchecked Sendable {
    struct Script { var lines: [String]; var hold = true; var status = 200 }
    typealias Responder = @Sendable (URLRequest) throws -> (Int, String)

    private let lock = NSLock()
    private var scripts: [Script] = []
    private var open: [AsyncThrowingStream<String, Error>.Continuation] = []
    private var eventLog: [URLRequest] = []
    private var requestLog: [URLRequest] = []
    private var cancelled = 0
    private var responder: Responder

    init(responder: @escaping Responder = ScriptedHost.defaultResponder) { self.responder = responder }

    var eventRequests: [URLRequest] { lock.withLock { eventLog } }
    var requests: [URLRequest] { lock.withLock { requestLog } }
    var cancelledStreams: Int { lock.withLock { cancelled } }
    func requests(to path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }

    func enqueue(_ lines: [String], hold: Bool = true, status: Int = 200) {
        lock.withLock { scripts.append(Script(lines: lines, hold: hold, status: status)) }
    }
    func respond(_ responder: @escaping Responder) { lock.withLock { self.responder = responder } }
    /// Sends a line on the newest open stream.
    func push(_ line: String) { _ = lock.withLock { open.last }?.yield(line) }
    func dropStream(_ error: Error = URLError(.networkConnectionLost)) { lock.withLock { open.last }?.finish(throwing: error) }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let responder = lock.withLock { requestLog.append(request); return self.responder }
        let (status, body) = try responder(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let script = lock.withLock { () -> Script in
            eventLog.append(request)
            return scripts.isEmpty ? Script(lines: []) : scripts.removeFirst()
        }
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.lock.withLock { self?.cancelled += 1 } }
        }
        for line in script.lines { continuation.yield(line) }
        if script.hold { lock.withLock { open.append(continuation) } } else { continuation.finish() }
        return (stream, HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: nil, headerFields: nil)!)
    }

    static let defaultResponder: Responder = { request in
        switch request.url?.path {
        case "/v1/chat/options":
            return (200, #"{"models":[{"id":"a/b","name":"Model B","provider":"A"}],"defaultModel":"a/b","agents":["build","plan"]}"#)
        case "/v1/messages" where request.httpMethod == "POST":
            return (202, #"{"accepted":true,"messageId":"msg_sent","turnId":"msg_sent"}"#)
        case "/v1/permissions/reply", "/v1/questions/reply", "/v1/questions/reject":
            return (200, #"{"accepted":true}"#)
        case "/v1/chat/messages":
            return (200, #"{"messages":[],"hasMore":false,"oldestId":""}"#)
        default:
            return (404, #"{"error":{"code":"not_found","message":"Not found"}}"#)
        }
    }
}

@MainActor
final class ChatSessionStoreTests: XCTestCase {
    private let identity = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "s", tabID: UUID())
    private let streaming = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
                                                 chatFeatures: ["reasoning", "queue", "rewind", "events", "parts", "stop", "clientMessageId"],
                                                 chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind", "restoreFiles", "approvals"])])

    private func client(_ host: ScriptedHost) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "t", transport: host)
    }

    private func environment(_ client: APIClient, capabilities: CapabilitiesResponse? = nil, reachable: Bool = true, epoch: Int = 0,
                             active: Bool = true, generation: UUID? = nil) -> ChatSessionStore.Environment {
        ChatSessionStore.Environment(client: client, capabilities: capabilities ?? streaming, reachable: reachable,
                                     connectionEpoch: epoch, active: active, refreshGeneration: generation)
    }

    private func eventually(_ what: String = "condition", within seconds: Double = 3, _ condition: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)", file: file, line: line)
    }

    private func after(_ request: URLRequest?) -> String? {
        URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private static let ready = #"{"seq":0,"type":"ready","cursor":"e1.0","resumed":false}"#
    private static func snapshot(state: String = "idle", messages: String = "[]", provider: String = "opencode") -> String {
        #"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"Fix login","provider":"\#(provider)"},"messages":\#(messages),"hasMore":false,"status":{"state":"\#(state)"},"interactions":[],"queue":[]}"#
    }
    private static let oneTurn = #"[{"id":"u1","role":"user","turnId":"u1","ord":1,"createdAt":"2026-09-24T09:00:00.000Z","parts":[{"id":"up","kind":"text","text":"Why does it loop?"}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","parts":[{"id":"ap","kind":"text","text":"Because of the cookie."}]}]"#

    /// The sent message ("Deploy it") as the host adds it to the chat.
    private static func sentMessage(_ id: String, seq: Int) -> String {
        #"{"seq":\#(seq),"type":"message.created","message":{"id":"\#(id)","role":"user","turnId":"\#(id)","ord":5,"parts":[{"id":"x","kind":"text","text":"Deploy it"}]}}"#
    }

    /// A fast turn as it reaches the store: the host writes its stream at most every 33 ms and the pump hands on at
    /// most one batch per 33 ms, so a turn that runs within that time arrives whole, its start and its end in one
    /// batch, which shows the chat idle again. Pushed together, the lines leave the pump in at most two batches, the
    /// first line alone after a quiet moment and the rest together: `running` and the end are always in one.
    private static func wholeTurn(_ turn: String, from seq: Int, reply: Bool = true, outcome: String = "completed") -> [String] {
        let end = outcome == "completed" ? "idle" : "error"
        let started = [#"{"seq":\#(seq),"type":"turn.started","turnId":"\#(turn)"}"#, #"{"seq":\#(seq + 1),"type":"status","state":"running"}"#]
        let answer = #"{"seq":\#(seq + 2),"type":"message.created","message":{"id":"a2","role":"assistant","turnId":"\#(turn)","ord":6,"status":"complete","parts":[{"id":"y","kind":"text","text":"Deployed."}]}}"#
        let ended = [#"{"seq":\#(seq + 3),"type":"status","state":"\#(end)"}"#,
                     #"{"seq":\#(seq + 4),"type":"turn.finished","turnId":"\#(turn)","outcome":"\#(outcome)"}"#]
        return started + (reply ? [answer] : []) + ended
    }

    func testReadyOnceContentAndOptionsResolveForTheGeneration() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        XCTAssertFalse(store.isResolved(for: nil))
        store.update(environment(try client(host)))
        await eventually("content and options") { store.isResolved(for: nil) }
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.transportKind, .events)
        XCTAssertEqual(store.projection.rows.map(\.id), ["user-u1", "reply-u1"])
        XCTAssertEqual(store.info?.title, "Fix login")
        XCTAssertEqual(store.selectedModelID, "a/b")
        XCTAssertEqual(store.selectedMode, "build")
        // Reload: the old content does not satisfy the new generation until it loads again.
        let generation = UUID()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        store.update(environment(try client(host), generation: generation))
        XCTAssertFalse(store.isResolved(for: generation))
        await eventually("reloaded content") { store.isResolved(for: generation) }
        XCTAssertNil(after(host.eventRequests.last), "A reload asks for a fresh snapshot")
    }

    func testStateSurvivesATabSwitchAndResumesFromTheCursor() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn), #"{"seq":0,"type":"beat","cursor":"e1.0"}"#])
        let store = ChatSessionStore(identity: identity)
        let api = try client(host)
        store.update(environment(api))
        await eventually("snapshot") { store.hasContent }
        host.push(#"{"seq":1,"type":"message.created","message":{"id":"a2","role":"assistant","turnId":"u1","ord":3,"parts":[]}}"#)
        host.push(#"{"seq":2,"type":"beat","cursor":"e1.2"}"#)
        await eventually("second reply message") { store.state.cursor == "e1.2" }

        store.update(environment(api, active: false))
        await eventually("stream closed on leaving the tab") { host.cancelledStreams == 1 }
        XCTAssertEqual(store.projection.rows.count, 2, "Leaving the tab keeps the transcript")
        XCTAssertEqual(host.eventRequests.count, 1)

        host.enqueue([#"{"seq":2,"type":"ready","cursor":"e1.2","resumed":true}"#, #"{"seq":3,"type":"status","state":"running"}"#])
        store.update(environment(api, active: true))
        await eventually("resumed stream") { host.eventRequests.count == 2 }
        XCTAssertEqual(after(host.eventRequests.last), "e1.2")
        await eventually("event after resume") { store.runState == .running }
        XCTAssertEqual(store.projection.rows.count, 2)
    }

    func testOfflinePausesRefusesSendsAndResumesOnTheNextConnectionEpoch() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn), #"{"seq":0,"type":"beat","cursor":"e1.0"}"#])
        let store = ChatSessionStore(identity: identity)
        let api = try client(host)
        store.update(environment(api))
        await eventually("snapshot") { store.state.cursor == "e1.0" }

        store.update(environment(api, reachable: false))
        await eventually("stream paused") { host.cancelledStreams == 1 }
        store.setDraft("hello")
        await store.send()
        XCTAssertEqual(store.notice?.message, "Offline · your draft is kept")
        XCTAssertEqual(store.draft, "hello")
        XCTAssertTrue(host.requests(to: "/v1/messages").isEmpty, "Nothing is queued for later while offline")
        XCTAssertTrue(store.pendingSends.isEmpty)
        XCTAssertEqual(store.projection.rows.count, 2)

        host.enqueue([#"{"seq":0,"type":"ready","cursor":"e1.0","resumed":true}"#])
        store.update(environment(api, reachable: true, epoch: 1))
        await eventually("resumed after recovery") { host.eventRequests.count == 2 }
        XCTAssertEqual(after(host.eventRequests.last), "e1.0")
    }

    /// A host that takes the connection and never answers (B-14): once no address answers, the chat says so at
    /// once instead of a spinner until the load's timeout, and it loads with the next connection epoch.
    func testAChatThatHadNotLoadedWhenTheHostWentAwaySaysSoAtOnceAndLoadsWhenItIsBack() async throws {
        let host = ScriptedHost()
        host.enqueue([])
        let store = ChatSessionStore(identity: identity)
        let api = try client(host)
        store.update(environment(api))
        await eventually("the first load started") { host.eventRequests.count == 1 }
        XCTAssertEqual(store.phase, .loading)

        store.update(environment(api, reachable: false))
        XCTAssertEqual(store.phase, .unavailable(ChatSessionStore.hostAwayMessage), "Said at once, not after the load's timeout")

        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        store.update(environment(api, reachable: true, epoch: 1))
        await eventually("loaded once the host is back") { store.phase == .ready }
        XCTAssertEqual(store.projection.rows.count, 2)
    }

    func testAStreamFailureReportsToTheConnectionLogicAndWaitsBeforeRetrying() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.retryDelays = [.milliseconds(300)]
        var failures = 0
        store.callbacks.connectionFailed = { failures += 1 }
        store.update(environment(try client(host)))
        await eventually("snapshot") { store.hasContent }
        host.dropStream()
        await eventually("failure reported") { failures == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.eventRequests.count, 1, "No tight reconnect loop")
        await eventually("one retry after the pause") { host.eventRequests.count == 2 }
        XCTAssertTrue(store.hasContent)
    }

    func testAnOffsetMismatchReconnectsWithoutACursor() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn), #"{"seq":0,"type":"beat","cursor":"e1.0"}"#])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("snapshot") { store.state.cursor == "e1.0" }
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        host.push(#"{"seq":1,"type":"part.delta","messageId":"a1","partId":"ap","field":"text","offset":99,"delta":"!"}"#)
        await eventually("reconnect") { host.eventRequests.count == 2 }
        XCTAssertNil(after(host.eventRequests.last))
        await eventually("fresh snapshot") { store.projection.message("a1")?.plainText == "Because of the cookie." }
    }

    func testAnUncertainSendIsNeverResentByItself() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        let api = try client(host)
        store.update(environment(api))
        await eventually("ready") { store.isResolved(for: nil) }
        host.respond { request in
            if request.url?.path == "/v1/messages" { throw URLError(.networkConnectionLost) }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertEqual(store.pendingSends.first?.delivery, .notConfirmed)
        XCTAssertEqual(store.draft, "", "The text moved to the unconfirmed bubble")
        let first = try body(try XCTUnwrap(host.requests(to: "/v1/messages").first))
        let clientMessageID = try XCTUnwrap(first["clientMessageId"] as? String)
        XCTAssertTrue((32...64).contains(clientMessageID.count))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.requests(to: "/v1/messages").count, 1, "Never resent automatically")

        // Check: the chat does not have it, so it becomes Not Sent.
        let pending = try XCTUnwrap(store.pendingSends.first)
        await store.checkPending(pending.id)
        guard case .notSent = store.pendingSends.first?.delivery else { return XCTFail("missing after a check means not sent") }
        XCTAssertEqual(host.requests(to: "/v1/messages").count, 1, "Checking only reads")

        // Send Again, explicitly: the same clientMessageId lets the host drop a repeat.
        host.respond(ScriptedHost.defaultResponder)
        await store.sendAgain(pending.id)
        let again = try body(try XCTUnwrap(host.requests(to: "/v1/messages").last))
        XCTAssertEqual(again["clientMessageId"] as? String, clientMessageID)
        XCTAssertEqual(store.pendingSends.first?.delivery, .accepted(messageID: "msg_sent"))
        host.push(#"{"seq":1,"type":"message.created","message":{"id":"msg_sent","role":"user","turnId":"msg_sent","ord":5,"parts":[{"id":"x","kind":"text","text":"Deploy it"}]}}"#)
        await eventually("pending bubble replaced by the real message") { store.pendingSends.isEmpty }
    }

    /// A fast turn can run to its end on the event stream before the send's own response arrives. The
    /// chat then has no turn left to wait for, so it does not keep showing Stop.
    func testATurnThatFinishedBeforeTheSendAnsweredIsNotAwaited() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        host.respond { request in
            if request.url?.path == "/v1/messages", request.httpMethod == "POST" {
                host.push(#"{"seq":1,"type":"status","state":"running"}"#)
                host.push(#"{"seq":2,"type":"message.created","message":{"id":"msg_sent","role":"user","turnId":"msg_sent","ord":5,"parts":[{"id":"x","kind":"text","text":"Deploy it"}]}}"#)
                host.push(#"{"seq":3,"type":"message.created","message":{"id":"a2","role":"assistant","turnId":"msg_sent","ord":6,"status":"complete","parts":[{"id":"y","kind":"text","text":"Deployed."}]}}"#)
                host.push(#"{"seq":4,"type":"status","state":"idle"}"#)
                // The response leaves after the stream delivered the whole turn.
                Thread.sleep(forTimeInterval: 0.5)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertTrue(store.pendingSends.isEmpty, "The sent message is in the transcript")
        XCTAssertFalse(store.isWorking, "The reply is already here: nothing is left to wait for")
    }

    /// The send's response can also come first. A fast turn then reaches the stream whole after it (`wholeTurn`), and
    /// its batch shows the chat idle again, as before it started: the turn it waited for has run all the same.
    func testATurnThatRanWholeAfterTheSendAnsweredEndsTheWait() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertTrue(store.isWorking, "Accepted, and no turn on the stream yet: the chat waits for it")
        host.push(Self.sentMessage("msg_sent", seq: 1))
        await eventually("the sent message") { store.pendingSends.isEmpty }
        XCTAssertTrue(store.isWorking, "The message is in, its turn is not: Stop stays")
        for line in Self.wholeTurn("msg_sent", from: 2) { host.push(line) }
        await eventually("the reply") { store.projection.message("a2") != nil }
        XCTAssertEqual(store.runState, .idle)
        XCTAssertFalse(store.isWorking, "The turn it waited for has run: Send comes back")
    }

    /// The sent message often reaches the stream before the answer does, and its turn after it: until the turn shows,
    /// the chat waits for it.
    func testTheSentMessageAloneBeforeTheAnswerIsNotItsTurn() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        let message = Self.sentMessage("msg_sent", seq: 1)
        host.respond { request in
            if request.url?.path == "/v1/messages", request.httpMethod == "POST" {
                host.push(message)
                Thread.sleep(forTimeInterval: 0.3)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertTrue(store.pendingSends.isEmpty, "The sent message came before the answer")
        XCTAssertTrue(store.isWorking, "Its turn has not shown yet: Stop stays")
    }

    /// A host without the event stream is read once a second. A fast turn can run between two reads, which both show the
    /// chat idle: the sent message's finished reply ends the wait.
    func testAReadThatBringsTheWholeTurnEndsTheWait() async throws {
        let ran = Flag()
        let host = ScriptedHost { request in
            switch request.url?.path {
            case "/v1/messages" where request.httpMethod == "GET":
                let earlier = #"{"id":"u1","role":"user","text":"Why does it loop?"},{"id":"a1","role":"assistant","text":"Because of the cookie."}"#
                let turn = #",{"id":"msg_sent","role":"user","text":"Deploy it"},{"id":"a2","role":"assistant","text":"Deployed."}"#
                return (200, #"{"messages":["# + earlier + (ran.value ? turn : "") + "]}")
            case "/v1/chat/status": return (200, #"{"state":"idle"}"#)
            case "/v1/interactions": return (200, #"{"permissions":[],"questions":[]}"#)
            case "/v1/queue": return (200, #"{"items":[]}"#)
            default: return try ScriptedHost.defaultResponder(request)
            }
        }
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["reasoning", "queue"])
        let store = ChatSessionStore(identity: identity)
        // Read once on opening; the next read below is the refresh's.
        store.pollInterval = .seconds(60)
        store.update(environment(try client(host), capabilities: older))
        await eventually("first read") { store.isResolved(for: nil) }
        XCTAssertEqual(store.transportKind, .polling)
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertTrue(store.isWorking, "Accepted, and the chat not read since: it waits for the turn")
        ran.set()
        store.refreshStatus()
        await eventually("the next read") { store.projection.message("a2") != nil }
        XCTAssertFalse(store.isWorking, "The reply to the sent message is here: nothing is left to wait for")
    }

    /// A host that does not know the sent message's ID answers without it, here once the whole turn has reached the
    /// stream: nothing is left to wait for.
    func testATurnThatRanBeforeAnAnswerWithoutTheMessageIDIsNotAwaited() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        let turn = [Self.sentMessage("u2", seq: 1)] + Self.wholeTurn("u2", from: 2)
        host.respond { request in
            if request.url?.path == "/v1/messages", request.httpMethod == "POST" {
                for line in turn { host.push(line) }
                // The response leaves after the stream delivered the whole turn.
                Thread.sleep(forTimeInterval: 0.5)
                return (202, #"{"accepted":true}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertNotNil(store.projection.message("a2"), "The whole turn came before the answer")
        XCTAssertFalse(store.isWorking, "The turn has run: nothing is left to wait for")
    }

    /// The same answer without the message's ID, before the whole turn this time: the wait ends with the turn.
    func testATurnThatRanWholeAfterAnAnswerWithoutTheMessageIDEndsTheWait() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        host.respond { request in
            if request.url?.path == "/v1/messages", request.httpMethod == "POST" { return (202, #"{"accepted":true}"#) }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertTrue(store.isWorking, "Accepted, and no turn on the stream yet: the chat waits for it")
        for line in [Self.sentMessage("u2", seq: 1)] + Self.wholeTurn("u2", from: 2) { host.push(line) }
        await eventually("the reply") { store.projection.message("a2") != nil }
        XCTAssertFalse(store.isWorking, "The turn it waited for has run: Send comes back")
    }

    /// A turn can fail before its agent replies at all (it could not start): its end brings no reply to find, and the
    /// wait ends with it all the same.
    func testATurnThatFailedWholeBeforeAnyReplyEndsTheWait() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        store.setDraft("Deploy it")
        await store.send()
        XCTAssertTrue(store.isWorking, "Accepted, and no turn on the stream yet: the chat waits for it")
        for line in [Self.sentMessage("msg_sent", seq: 1)] + Self.wholeTurn("msg_sent", from: 2, reply: false, outcome: "error") {
            host.push(line)
        }
        await eventually("the failed turn") { store.runState == .error }
        XCTAssertFalse(store.isWorking, "The turn it waited for has ended")
    }

    /// Run Again's answer names no new message: the turn it starts runs the latest prompt again, under that prompt's
    /// turn ID. A fast one that reaches the stream whole ends the wait as a sent message's does.
    func testRunAgainStopsWaitingOnceItsTurnRanWhole() async throws {
        let host = ScriptedHost { request in
            if request.url?.path == "/v1/chat/regenerate" { return (202, #"{"accepted":true,"messageId":"u1","turnId":"u1"}"#) }
            return try ScriptedHost.defaultResponder(request)
        }
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let regenerating = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"],
                                                chatFeatures: ["events", "parts", "stop", "clientMessageId", "regenerate"])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host), capabilities: regenerating))
        await eventually("ready") { store.isResolved(for: nil) }
        XCTAssertTrue(store.canRunAgain)
        await store.runAgain()
        XCTAssertEqual(host.requests(to: "/v1/chat/regenerate").count, 1)
        XCTAssertTrue(store.isWorking, "Accepted, and no turn on the stream yet: the chat waits for it")
        for line in Self.wholeTurn("u1", from: 1) { host.push(line) }
        await eventually("the new reply") { store.projection.message("a2") != nil }
        XCTAssertFalse(store.isWorking, "The turn it waited for has run: Send comes back")
    }

    func testCheckFindsAMessageThatDidArrive() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        host.respond { request in
            if request.url?.path == "/v1/messages" { throw URLError(.timedOut) }
            if request.url?.path == "/v1/chat/messages" {
                let now = ISO8601DateFormatter().string(from: Date())
                return (200, #"{"messages":[{"id":"u9","role":"user","createdAt":"\#(now)","parts":[{"id":"t","kind":"text","text":"Ship it"}]}],"hasMore":false,"oldestId":"u9"}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Ship it")
        await store.send()
        let pending = try XCTUnwrap(store.pendingSends.first)
        await store.checkPending(pending.id)
        XCTAssertTrue(store.pendingSends.isEmpty, "Found in the chat: it was delivered")
    }

    func testProvablyUndeliveredSendsSayNotSent() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot()])
        let store = ChatSessionStore(identity: identity)
        var failures = 0
        store.callbacks.connectionFailed = { failures += 1 }
        store.update(environment(try client(host)))
        await eventually("ready") { store.isResolved(for: nil) }
        host.respond { request in
            if request.url?.path == "/v1/messages" { throw URLError(.cannotConnectToHost) }
            return try ScriptedHost.defaultResponder(request)
        }
        store.setDraft("Hi")
        await store.send()
        guard case .notSent = store.pendingSends.first?.delivery else { return XCTFail() }
        XCTAssertEqual(failures, 1)
        store.editPending(try XCTUnwrap(store.pendingSends.first).id)
        XCTAssertEqual(store.draft, "Hi")
        XCTAssertTrue(store.pendingSends.isEmpty)
    }

    func testOlderHostsGetNoNewFields() async throws {
        let host = ScriptedHost()
        host.respond { request in
            switch request.url?.path {
            case "/v1/messages" where request.httpMethod == "GET":
                return (200, #"{"messages":[]}"#)
            case "/v1/chat/status": return (200, #"{"state":"idle"}"#)
            case "/v1/interactions": return (200, #"{"permissions":[],"questions":[]}"#)
            case "/v1/queue": return (200, #"{"items":[]}"#)
            case "/v1/messages": return (202, #"{"accepted":true}"#)
            default: return try ScriptedHost.defaultResponder(request)
            }
        }
        let older = CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["reasoning", "queue"])
        let store = ChatSessionStore(identity: identity)
        store.pollInterval = .milliseconds(50)
        store.update(environment(try client(host), capabilities: older))
        await eventually("legacy load") { store.isResolved(for: nil) }
        XCTAssertEqual(store.transportKind, .polling)
        XCTAssertTrue(host.eventRequests.isEmpty, "No stream on a host without events")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(host.requests(to: "/v1/messages").first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "parts" }, "?parts=1 only when advertised")
        store.setDraft("Hello")
        await store.send()
        let sent = try body(try XCTUnwrap(host.requests(to: "/v1/messages").first { $0.httpMethod == "POST" }))
        XCTAssertEqual(Set(sent.keys), ["projectId", "sessionId", "text", "model", "agent"])
    }

    func testNewerHostsGetFieldsTheyAdvertiseForTheChatsProvider() async throws {
        let codex = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "codex:1", tabID: UUID())
        let host = ScriptedHost { request in
            if request.url?.path == "/v1/chat/options" {
                return (200, #"{"models":[{"id":"codex/gpt","name":"GPT","provider":"Codex","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"codex/gpt","agents":["build"],"modes":[{"id":"auto-review","name":"Auto review"},{"id":"ask","name":"Ask"}],"defaultMode":"auto-review"}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        host.enqueue([Self.ready, Self.snapshot(provider: "codex")])
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "codex"],
                                                chatFeatures: ["events", "clientMessageId"],
                                                chatProviderInfo: ["codex": ChatProviderInfo(transport: "app-server", features: ["modes", "effort"])])
        let store = ChatSessionStore(identity: codex)
        XCTAssertEqual(store.provider, .codex)
        store.update(environment(try client(host), capabilities: capabilities))
        await eventually("ready") { store.isResolved(for: nil) }
        XCTAssertEqual(store.modeChoices.map(\.summary), ["Edits on its own", "Asks first"])
        store.selectMode("ask")
        store.setDraft("Plan it")
        await store.send()
        let sent = try body(try XCTUnwrap(host.requests(to: "/v1/messages").first))
        XCTAssertEqual(sent["mode"] as? String, "ask")
        XCTAssertEqual(sent["effort"] as? String, "high")
        XCTAssertNotNil(sent["clientMessageId"])
        XCTAssertNil(sent["agent"], "Codex takes its mode as mode, not as OpenCode's agent")

        // The same store on a host that does not list effort for Codex leaves it out.
        let limited = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "codex"], chatFeatures: ["events"],
                                           chatProviderInfo: ["codex": ChatProviderInfo(transport: "app-server", features: ["modes"])])
        store.update(environment(try client(host), capabilities: limited))
        let request = store.request(text: "x", attachments: [], clientMessageID: "abc")
        XCTAssertNil(request.effort)
        XCTAssertNil(request.clientMessageID)
        XCTAssertEqual(request.mode, "ask")
    }

    func testApprovalCardFlowAgainstAFakeEventStream() async throws {
        let host = ScriptedHost()
        let running = #"[{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"up","kind":"text","text":"Write the proof"}]},{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"streaming","parts":[{"id":"t1","kind":"tool","ord":1,"tool":{"name":"bash","status":"running","input":"{\"command\":\"echo approved > proof.txt\"}"}}]}]"#
        host.enqueue([Self.ready, Self.snapshot(state: "running", messages: running), #"{"seq":0,"type":"turn.started","turnId":"u1"}"#])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("running turn") { store.runState == .running }
        host.push(#"{"seq":1,"type":"turn.started","turnId":"u1"}"#)
        host.push(#"{"seq":2,"type":"interaction.requested","interaction":{"id":"per_1","chatId":"s","kind":"permission","choices":["once","reject"],"permission":{"tool":"bash","title":"echo approved > proof.txt","input":"{\"command\":\"echo approved > proof.txt\"}"}}}"#)
        host.push(#"{"seq":3,"type":"status","state":"waiting"}"#)
        await eventually("approval card") { store.interactions.count == 1 }
        XCTAssertEqual(store.approvalArrivals, 1)
        XCTAssertEqual(store.runState, .waiting)
        let interaction = try XCTUnwrap(store.interactions.first)
        XCTAssertFalse(interaction.offersAlways)

        await store.reply(to: interaction, with: .always)
        XCTAssertTrue(host.requests(to: "/v1/permissions/reply").isEmpty, "Always Allow is sent only when offered")
        await store.reply(to: interaction, with: .once)
        let reply = try body(try XCTUnwrap(host.requests(to: "/v1/permissions/reply").first))
        XCTAssertEqual(reply["reply"] as? String, "once")
        XCTAssertEqual(reply["requestId"] as? String, "per_1")
        XCTAssertEqual(store.interactionDelivery["per_1"], .sent, "The card waits for the stream to report the outcome")

        host.push(#"{"seq":4,"type":"interaction.resolved","id":"per_1","outcome":"once"}"#)
        host.push(#"{"seq":5,"type":"part.updated","messageId":"a1","part":{"id":"t1","kind":"tool","ord":1,"tool":{"name":"bash","status":"completed","output":"(no output)"}}}"#)
        await eventually("resolved") { store.interactions.isEmpty }
        let resolved = try XCTUnwrap(store.projection.latestReply?.resolved.first)
        XCTAssertEqual(resolved.outcome, "once")
        XCTAssertEqual(resolved.afterPartID, "t1")
        XCTAssertNotNil(store.resolvedAt["per_1"])
        XCTAssertNil(store.interactionDelivery["per_1"])
        await eventually("tool finished") { store.projection.message("a1")?.part("t1")?.tool?.status == .completed }
    }

    func testUncertainApprovalRepliesAreReportedNotRepeated() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(state: "waiting"),
                      #"{"seq":1,"type":"interaction.requested","interaction":{"id":"q1","kind":"question","questions":[{"id":"0","text":"Token?","custom":true,"secret":true}]}}"#])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("question") { store.interactions.count == 1 }
        host.respond { request in
            if request.url?.path == "/v1/questions/reply" { throw URLError(.networkConnectionLost) }
            return try ScriptedHost.defaultResponder(request)
        }
        await store.answer(try XCTUnwrap(store.interactions.first), answers: [["s3cret"]])
        XCTAssertEqual(store.interactionDelivery["q1"], .notConfirmed)
        XCTAssertEqual(host.requests(to: "/v1/questions/reply").count, 1)
    }

    func testDeletedChatAndUnsupportedStreams() async throws {
        let host = ScriptedHost()
        host.enqueue([#"{"error":{"code":"not_found","message":"Chat not found"}}"#], hold: false, status: 404)
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("deleted") { store.phase == .deleted }
        XCTAssertTrue(store.isResolved(for: nil) || store.phase == .deleted)

        let fallback = ScriptedHost { request in
            switch request.url?.path {
            case "/v1/messages": return (200, #"{"messages":[{"id":"u1","role":"user","text":"hi"}]}"#)
            case "/v1/chat/status": return (200, #"{"state":"idle"}"#)
            case "/v1/interactions": return (200, #"{"permissions":[],"questions":[]}"#)
            case "/v1/queue": return (200, #"{"items":[]}"#)
            default: return try ScriptedHost.defaultResponder(request)
            }
        }
        fallback.enqueue([#"{"error":{"code":"unsupported_operation","message":"This host cannot stream this chat"}}"#], hold: false, status: 501)
        let legacy = ChatSessionStore(identity: identity)
        legacy.pollInterval = .milliseconds(50)
        legacy.update(environment(try client(fallback)))
        await eventually("polling fallback") { legacy.transportKind == .polling && legacy.hasContent }
        XCTAssertEqual(legacy.projection.rows.map(\.id), ["user-u1"])
    }

    func testARestoredDraftWaitsInTheComposerUnderTheLanding() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, #"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"New chat","provider":"opencode"},"messages":null,"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let store = ChatSessionStore(identity: identity, draft: "Saved before the app closed")
        store.update(environment(try client(host)))
        await eventually("loaded") { store.isResolved(for: nil) }
        XCTAssertTrue(store.showsLanding, "The landing sits over the composer, as in a plain chat")
        XCTAssertEqual(store.draft, "Saved before the app closed", "and the saved draft waits in the composer")
        store.setDraft("")
        XCTAssertTrue(store.composerRevealed, "Clearing it keeps the composer in use")
    }

    func testTheTitleIsTheFirstPromptLineUntilTheHostNamesTheChat() async throws {
        let host = ScriptedHost()
        let untitled = #"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"New chat","provider":"opencode"},"messages":[{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"up","kind":"text","text":"\n  Why does /login loop after I sign in with a passkey on Safari?\nMore detail"}]}],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#
        host.enqueue([Self.ready, untitled])
        let store = ChatSessionStore(identity: identity)
        store.update(environment(try client(host)))
        await eventually("loaded") { store.hasContent }
        XCTAssertEqual(store.displayTitle(fallback: "New chat"), "Why does /login loop after I sign in with a passk…")
        XCTAssertEqual(store.displayTitle(fallback: "New chat").count, 50)
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("Claude Code chat", provider: .claude))
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("New session - 2026-09-24T10:00:00.000Z", provider: .opencode))
        XCTAssertFalse(ChatSessionStore.isDefaultTitle("Fix login", provider: .opencode))
        let named = ChatSessionStore(identity: identity)
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        named.update(environment(try client(host)))
        await eventually("named chat") { named.hasContent }
        XCTAssertEqual(named.displayTitle(fallback: "New chat"), "Fix login", "The host's own title wins")
    }

    /// The app hears the chat's name as the stream brings it (the snapshot, then `chat.updated`), and who
    /// named it for which message.
    func testTheNameFollowsTheSnapshotAndChatUpdated() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        var names: [String] = []
        store.callbacks.nameChanged = { names.append($0) }
        store.update(environment(try client(host)))
        await eventually("snapshot") { store.hasContent }
        XCTAssertEqual(names, ["Fix login"])

        host.push(#"{"seq":1,"type":"chat.updated","title":"Explain the cookie loop","titleSource":"device","titleBasis":"a1"}"#)
        await eventually("renamed") { names.count == 2 }
        XCTAssertEqual(names.last, "Explain the cookie loop")
        XCTAssertEqual(store.info?.titleSource, .device)
        XCTAssertEqual(store.info?.titleBasis, "a1")

        host.push(#"{"seq":2,"type":"chat.updated","model":"a/b"}"#)
        host.push(#"{"seq":3,"type":"chat.updated","title":"Explain the cookie loop"}"#)
        host.push(#"{"seq":4,"type":"beat","cursor":"e1.4"}"#)
        await eventually("the beat") { store.state.cursor == "e1.4" }
        XCTAssertEqual(names.count, 2, "Only a new name is reported")
        XCTAssertEqual(store.info?.titleSource, .device, "An update without the naming keeps it")
        XCTAssertEqual(store.info?.titleBasis, "a1")

        // A source without a basis: the new title has none.
        host.push(#"{"seq":5,"type":"chat.updated","title":"Cookie domains","titleSource":"provider"}"#)
        await eventually("the provider's title") { names.last == "Cookie domains" }
        XCTAssertEqual(store.info?.titleSource, .provider)
        XCTAssertNil(store.info?.titleBasis)

        // A placeholder the host counts as default gives way to the first prompt.
        host.push(#"{"seq":6,"type":"chat.updated","title":"Claude Code","titleSource":"default"}"#)
        await eventually("the first prompt") { names.last == "Why does it loop?" }
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("Claude Code", provider: .opencode))
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("continued chat", provider: .codex))
        XCTAssertTrue(ChatSessionStore.isDefaultTitle("Child session - 2026-09-24T10:00:00.000Z", provider: .opencode))
        XCTAssertFalse(ChatSessionStore.isDefaultTitle("Claude Code review", provider: .claude))
    }

    /// Chat names its agents Claude Code and Codex (2026-10-12 ~20:50): new chats are "Claude Code chat" and "Codex chat",
    /// and the host names untitled ones "Claude Code" and "Codex". Chats saved while Chat said Claude and ChatGPT keep
    /// "Claude chat", "ChatGPT chat", "Claude" and "ChatGPT"; old and new defaults alike give way to the first prompt,
    /// whichever agent the chat has.
    func testOldAndNewProviderDefaultTitlesAreBothPlaceholders() {
        for provider in [AgentProvider.claude, .codex, .opencode, AgentProvider(id: "gemini", name: "Gemini CLI")] {
            for title in ["Claude chat", "ChatGPT chat", "Claude Code chat", "Codex chat", "Claude", "ChatGPT", "Claude Code", "Codex",
                          " chatgpt CHAT "] {
                XCTAssertTrue(ChatSessionStore.isDefaultTitle(title, provider: provider), "\(title) for \(provider.id)")
            }
            XCTAssertTrue(ChatSessionStore.isDefaultTitle(provider.newChatTitle, provider: provider))
            XCTAssertTrue(ChatSessionStore.isDefaultTitle(provider.chatDisplayName, provider: provider))
            XCTAssertTrue(ChatSessionStore.isDefaultTitle(provider.displayName, provider: provider))
        }
        XCTAssertEqual([AgentProvider.claude, .codex].map(\.newChatTitle), ["Claude Code chat", "Codex chat"])
        XCTAssertFalse(ChatSessionStore.isDefaultTitle("ChatGPT review", provider: .codex))
        XCTAssertFalse(ChatSessionStore.isDefaultTitle("Claude chat notes", provider: .claude))
    }

    func testADefaultTitledChatIsNamedByItsFirstPromptWhenItIsSent() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, #"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"New chat","provider":"opencode"},"messages":[],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let store = ChatSessionStore(identity: identity)
        var names: [String] = []
        store.callbacks.nameChanged = { names.append($0) }
        store.update(environment(try client(host)))
        await eventually("loaded") { store.isResolved(for: nil) }
        XCTAssertEqual(names, [], "A default title names nothing")
        store.setDraft("Why does the login loop?\nIt started on Monday.")
        await store.send()
        XCTAssertEqual(names, ["Why does the login loop?"])
    }

    func testFinishedTurnsAreReportedWithTheReplyInTheTranscript() async throws {
        let host = ScriptedHost()
        host.enqueue([Self.ready, Self.snapshot(state: "running", messages: Self.oneTurn)])
        let store = ChatSessionStore(identity: identity)
        var finished: [(ChatTurnOutcome, Int)] = []
        store.callbacks.turnFinished = { outcome in finished.append((outcome, store.state.messages.count)) }
        store.update(environment(try client(host)))
        await eventually("snapshot") { store.hasContent }
        host.push(#"{"seq":1,"type":"message.created","message":{"id":"a2","role":"assistant","turnId":"u1","ord":3,"parts":[{"id":"p2","kind":"text","text":"Fixed."}]}}"#)
        host.push(#"{"seq":2,"type":"turn.finished","turnId":"u1","outcome":"completed"}"#)
        await eventually("the finished turn") { !finished.isEmpty }
        XCTAssertEqual(finished.map(\.0), [ChatTurnOutcome(turnID: "u1", outcome: "completed")])
        XCTAssertEqual(finished.first?.1, 3, "The reply that ended the turn is already in the transcript")
    }

    func testCopyChatAsMarkdownLeavesOutReasoningAndTools() {
        let messages = [
            ConversationMessage(id: "u1", role: .user, parts: [ConversationPart(id: "a", kind: .attachment, attachment: AttachmentRecord(name: "shot.png", mime: "image/png")),
                                                              ConversationPart(id: "t", kind: .text, text: "Why?")]),
            ConversationMessage(id: "a1", role: .assistant, parts: [ConversationPart(id: "r", kind: .reasoning, text: "secret thinking"),
                                                                   ConversationPart(id: "tool", kind: .tool, tool: ConversationTool(name: "bash", status: .completed)),
                                                                   ConversationPart(id: "x", kind: .text, text: "Because.")])
        ]
        let markdown = ChatExport.markdown(title: "Fix login", provider: .claude, model: "claude/default", workspace: "my-app", messages: messages)
        XCTAssertEqual(markdown, "# Fix login\n\n_Claude Code · claude/default · my-app_\n\n**Me**\n\nAttachments: shot.png\nWhy?\n\n**Claude Code**\n\nBecause.\n")
        XCTAssertFalse(markdown.contains("secret"))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

@MainActor
final class ChatProjectionTests: XCTestCase {
    func testADeltaRedrawsOnlyTheStreamingPart() {
        var state = ChatState()
        let parts = [ConversationPart(id: "A", kind: .text, ord: 1, text: "Hello"), ConversationPart(id: "B", kind: .text, ord: 2, text: "Other")]
        _ = ChatReducer.apply(ChatEventEnvelope(seq: 0, event: .ready(cursor: "e.0", resumed: false)), to: &state)
        _ = ChatReducer.apply(ChatEventEnvelope(seq: 0, event: .snapshot(ChatSnapshot(chat: ChatInfo(id: "c"), messages: [
            ConversationMessage(id: "u", turnID: "u", role: .user, ord: 1, parts: [ConversationPart(id: "q", kind: .text, text: "Hi")]),
            ConversationMessage(id: "m", turnID: "u", role: .assistant, status: .streaming, ord: 2, parts: parts)
        ]))), to: &state)
        let projection = ChatProjection()
        projection.sync(state, changes: state.changes)
        state.changes = ChatChanges()
        let a = try! XCTUnwrap(projection.message("m")?.part("A"))
        let b = try! XCTUnwrap(projection.message("m")?.part("B"))
        _ = a.markdownBlocks
        let bChanged = Flag(), rowsChanged = Flag(), partsChanged = Flag(), aChanged = Flag()
        withObservationTracking { _ = b.text; _ = b.tool } onChange: { bChanged.set() }
        withObservationTracking { _ = projection.rows } onChange: { rowsChanged.set() }
        withObservationTracking { _ = projection.message("m")?.parts } onChange: { partsChanged.set() }
        withObservationTracking { _ = a.text } onChange: { aChanged.set() }

        for (seq, word) in [" wide", " world"].enumerated() {
            let offset = state.messages[1].parts[0].text.utf8.count
            _ = ChatReducer.apply(ChatEventEnvelope(seq: UInt64(seq + 1), event: .partDelta(ConversationPartDelta(messageID: "m", partID: "A", field: .text, offset: offset, delta: word))), to: &state)
        }
        projection.sync(state, changes: state.changes)
        XCTAssertTrue(aChanged.value)
        XCTAssertEqual(a.text, "Hello wide world")
        XCTAssertEqual(a.markdownBlocks, [.paragraph("Hello wide world")])
        XCTAssertFalse(bChanged.value, "The other part does not redraw")
        XCTAssertFalse(rowsChanged.value, "The row list does not change")
        XCTAssertFalse(partsChanged.value, "The message's part list does not change")
    }

    func testTurnsGroupIntoRepliesAndSeedsIntoContextRows() {
        var state = ChatState()
        ChatReducer.replace(&state, with: ChatSnapshot(chat: ChatInfo(id: "c"), messages: [
            ConversationMessage(id: "agentland-seed", role: .user, ord: 0, parts: [ConversationPart(id: "s", kind: .context, text: "Seed")]),
            ConversationMessage(id: "u1", turnID: "u1", role: .user, ord: 1),
            ConversationMessage(id: "a1", turnID: "u1", role: .assistant, ord: 2),
            ConversationMessage(id: "a2", turnID: "u1", role: .assistant, ord: 3),
            ConversationMessage(id: "u2", turnID: "u2", role: .user, ord: 4),
            ConversationMessage(id: "a3", turnID: "u2", role: .assistant, ord: 5)
        ], hasMore: true))
        let projection = ChatProjection()
        projection.sync(state, changes: state.changes)
        XCTAssertEqual(projection.rows.map(\.id), ["earlier", "context-agentland-seed", "user-u1", "reply-u1", "user-u2", "reply-u2"])
        guard case let .reply(first) = projection.rows[3], case let .reply(last) = projection.rows[5] else { return XCTFail() }
        XCTAssertEqual(first.messages.map(\.id), ["a1", "a2"], "One reply per turn, across assistant messages")
        XCTAssertFalse(first.isLatest)
        XCTAssertTrue(last.isLatest)
    }
}
