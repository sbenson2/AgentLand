import Foundation
import XCTest
@testable import AgentLandCore

/// The chat event stream and the chat routes of docs/HOST-API.md, decoded from
/// lines the real host produced (captured from `GET /v1/chat/events` against a
/// disposable OpenCode and the local fixture model).
final class ChatStreamContractTests: XCTestCase {
    func testRealHostLinesDecode() throws {
        let lines = [
            #"{"seq":0,"type":"ready","cursor":"5fdf0572930bd75d.0","resumed":false}"#,
            #"{"seq":0,"type":"snapshot","chat":{"id":"ses_1","title":"probe","provider":"opencode"},"messages":null,"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#,
            #"{"seq":1,"type":"message.created","message":{"id":"msg_u","chatId":"ses_1","turnId":"msg_u","role":"user","status":"complete","ord":7332831517720577,"createdAt":"2026-09-24T09:27:49.756Z","provider":"opencode","model":"agentland-test/fixture-model","parts":[]}}"#,
            #"{"seq":2,"type":"chat.updated","model":"agentland-test/fixture-model","mode":"build"}"#,
            #"{"seq":3,"type":"part.created","messageId":"msg_u","part":{"id":"prt_1","kind":"text","ord":14482123259905,"text":"AGENTLAND_STREAM go"}}"#,
            #"{"seq":4,"type":"turn.started","turnId":"msg_u"}"#,
            #"{"seq":5,"type":"status","state":"running"}"#,
            #"{"seq":8,"type":"part.delta","messageId":"msg_a","partId":"prt_2","field":"text","offset":0,"delta":"Streaming "}"#,
            #"{"seq":9,"type":"interaction.requested","interaction":{"id":"per_1","chatId":"ses_1","kind":"permission","createdAt":"2026-09-24T09:28:08.466Z","choices":["once","reject"],"permission":{"tool":"bash","title":"echo approved > approval-proof.txt","detail":"","input":"{\"command\":\"echo approved\"}"}}}"#,
            #"{"seq":11,"type":"interaction.resolved","id":"per_1","outcome":"once"}"#,
            #"{"seq":14,"type":"message.updated","messageId":"msg_a","status":"complete","completedAt":"2026-09-24T09:28:09.497Z"}"#,
            #"{"seq":21,"type":"turn.finished","turnId":"msg_u","outcome":"completed"}"#,
            #"{"seq":21,"type":"beat","cursor":"02557ef88641b29b.21"}"#,
            #"{"seq":21,"type":"stopping"}"#,
            #"{"seq":22,"type":"a.future.kind","whatever":1}"#
        ]
        let envelopes = try lines.map(ChatEventEnvelope.decode(line:))
        XCTAssertEqual(envelopes[0], ChatEventEnvelope(seq: 0, event: .ready(cursor: "5fdf0572930bd75d.0", resumed: false)))
        guard case let .snapshot(snapshot) = envelopes[1].event else { return XCTFail("snapshot") }
        XCTAssertEqual(snapshot.messages, [], "A host sends null for an empty chat")
        XCTAssertEqual(snapshot.status.state, .idle)
        XCTAssertEqual(snapshot.chat, ChatInfo(id: "ses_1", title: "probe", provider: "opencode"))
        guard case let .messageCreated(user) = envelopes[2].event else { return XCTFail("message.created") }
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.ord, 7332831517720577)
        XCTAssertEqual(envelopes[3].event, .chatUpdated(ChatInfoUpdate(model: "agentland-test/fixture-model", mode: "build")))
        XCTAssertEqual(envelopes[5].event, .turnStarted(turnID: "msg_u"))
        XCTAssertEqual(envelopes[6].event, .status(ChatStatusInfo(state: .running)))
        XCTAssertEqual(envelopes[7].event, .partDelta(ConversationPartDelta(messageID: "msg_a", partID: "prt_2", field: .text, offset: 0, delta: "Streaming ")))
        guard case let .interactionRequested(permission) = envelopes[8].event else { return XCTFail("interaction") }
        XCTAssertEqual(permission.kind, .permission)
        XCTAssertFalse(permission.offersAlways)
        XCTAssertEqual(permission.permission?.tool, "bash")
        XCTAssertEqual(envelopes[9].event, .interactionResolved(id: "per_1", outcome: "once"))
        XCTAssertEqual(envelopes[10].event, .messageUpdated(ConversationMessageUpdate(messageID: "msg_a", status: .complete, completedAt: "2026-09-24T09:28:09.497Z")))
        XCTAssertEqual(envelopes[11].event, .turnFinished(turnID: "msg_u", outcome: "completed", usage: nil))
        XCTAssertEqual(envelopes[12].event, .beat(cursor: "02557ef88641b29b.21"))
        XCTAssertEqual(envelopes[13].event, .stopping)
        XCTAssertEqual(envelopes[14].event, .unknown(type: "a.future.kind"), "New line types are ignored, not fatal")
    }

    func testToleratesUnknownValuesAndMissingFields() throws {
        let message = try ChatEventEnvelope.decode(line: #"{"seq":3,"type":"message.created","message":{"id":"m","role":"assistant","status":"thinking","parts":[{"id":"p","kind":"hologram"},{"id":"t","kind":"tool","tool":{"name":"bash","status":"queued"}}]}}"#)
        guard case let .messageCreated(value) = message.event else { return XCTFail() }
        XCTAssertEqual(value.status, .complete)
        XCTAssertEqual(value.parts[0].kind, .other("hologram"))
        XCTAssertEqual(value.parts[1].tool?.status, .running)
        let snapshot = try ChatEventEnvelope.decode(line: #"{"seq":1,"type":"snapshot","chat":{"id":"c"},"status":{"state":"dreaming"},"queue":[{"id":"q","text":"t","createdAt":"x","status":"parked"}],"rewind":{"messageId":"m9"}}"#)
        guard case let .snapshot(value) = snapshot.event else { return XCTFail() }
        XCTAssertEqual(value.status.state, .unknown)
        XCTAssertEqual(value.queue.first?.status, .queued)
        XCTAssertEqual(value.rewind, RewindState(messageID: "m9"))
        XCTAssertEqual(value.interactions, [])
        XCTAssertThrowsError(try ChatEventEnvelope.decode(line: "not json"))
        XCTAssertThrowsError(try ChatEventEnvelope.decode(line: #"{"seq":2,"type":"part.delta","messageId":"m"}"#),
                             "A known type without its required fields is an error, not silently empty")
        let worded = try ChatEventEnvelope.decode(line: #"{"seq":5,"type":"interaction.requested","interaction":{"id":"p1","kind":"permission","choices":["once","always","reject"],"alwaysLabel":"Allow Bash(npm test *) in this project","alwaysDetail":"Saved in this project's .claude/settings.local.json.","permission":{"tool":"Bash","title":"Run the tests","detail":""}}}"#)
        guard case let .interactionRequested(always) = worded.event else { return XCTFail() }
        XCTAssertTrue(always.offersAlways)
        XCTAssertEqual(always.alwaysLabel, "Allow Bash(npm test *) in this project")
        XCTAssertEqual(always.alwaysDetail, "Saved in this project's .claude/settings.local.json.")
        let question = try ChatEventEnvelope.decode(line: #"{"seq":4,"type":"interaction.requested","interaction":{"id":"q1","kind":"question","choices":null,"questions":[{"id":"0","text":"Token?","options":null,"custom":true,"secret":true}]}}"#)
        guard case let .interactionRequested(value) = question.event else { return XCTFail() }
        XCTAssertNil(value.alwaysLabel)
        XCTAssertEqual(value.questions.first?.secret, true)
        XCTAssertEqual(value.questions.first?.options, [])
    }

    func testCursorEpoch() {
        XCTAssertEqual(ChatCursor("5fdf0572930bd75d.21").epoch, "5fdf0572930bd75d")
        XCTAssertEqual(ChatCursor("odd").epoch, "odd")
    }

    func testLineSplitterBoundsEachLine() throws {
        var splitter = BoundedLineSplitter(limit: 8)
        var lines: [String] = []
        for byte in Array("abc\r\n12345678\nx".utf8) { if let line = try splitter.append(byte) { lines.append(line) } }
        XCTAssertEqual(lines, ["abc", "12345678"], "A line of exactly the limit is accepted; CRLF is trimmed")
        XCTAssertEqual(splitter.finish(), "x")
        var tight = BoundedLineSplitter(limit: 4)
        XCTAssertThrowsError(try Array("12345".utf8).forEach { _ = try tight.append($0) })
    }

    func testChatEventsAskForTheStreamWithACursorAndA256KiBLineLimit() async throws {
        let big = String(repeating: "x", count: 200 << 10)
        let transport = StreamTransport(status: 200, lines: [#"{"seq":0,"type":"ready","cursor":"e.0","resumed":true}"#, big])
        let client = try makeClient(transport)
        var received: [String] = []
        for try await line in try await client.chatEventLines(projectID: "p", sessionID: "s", after: "e.7") { received.append(line) }
        XCTAssertEqual(received.count, 2, "Lines up to 256 KiB pass")
        XCTAssertEqual(transport.limits, [256 << 10])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/chat/events")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "after" }?.value, "e.7")
        XCTAssertEqual(query.first { $0.name == "sessionId" }?.value, "s")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson")
        XCTAssertGreaterThan(request.timeoutInterval, 10, "Longer than the host's 10 s beat")

        let fresh = StreamTransport(status: 200, lines: [])
        _ = try await makeClient(fresh).chatEventLines(projectID: "p", sessionID: "s", after: nil)
        let freshQuery = URLComponents(url: try XCTUnwrap(fresh.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(freshQuery.first { $0.name == "after" }, "No cursor asks for a snapshot")

        let tooLong = StreamTransport(status: 200, lines: [String(repeating: "y", count: (256 << 10) + 1)])
        do {
            for try await _ in try await makeClient(tooLong).chatEventLines(projectID: "p", sessionID: "s", after: nil) {}
            XCTFail("A line past 256 KiB must fail the stream")
        } catch {
            XCTAssertEqual(error as? ClientError, .invalidResponse)
        }
    }

    func testChatEventsReportTheHostsRefusal() async throws {
        let transport = StreamTransport(status: 501, lines: [#"{"error":{"code":"unsupported_operation","message":"This host cannot stream this chat"}}"#])
        do {
            _ = try await makeClient(transport).chatEventLines(projectID: "p", sessionID: "s", after: nil)
            XCTFail("A refusal must be reported")
        } catch {
            XCTAssertEqual(error as? ClientError, .server(code: "unsupported_operation", message: "This host cannot stream this chat"))
        }
    }

    func testSendCarriesNewFieldsOnlyWhenSet() async throws {
        let transport = StreamTransport(status: 202, body: #"{"accepted":true,"messageId":"msg_1","turnId":"msg_1"}"#)
        let client = try makeClient(transport)
        let plain = await client.sendChatMessage(ChatSendRequest(projectID: "p", sessionID: "s", text: "hi"))
        XCTAssertEqual(plain, .accepted(ChatSendReceipt(accepted: true, messageID: "msg_1", turnID: "msg_1")))
        let body = try json(transport.requests[0])
        XCTAssertEqual(Set(body.keys), ["projectId", "sessionId", "text"], "An older host rejects fields it does not know")
        _ = await client.sendChatMessage(ChatSendRequest(projectID: "p", sessionID: "codex:1", text: "go", model: "codex/gpt", agent: nil,
                                                         attachments: ["att"], clientMessageID: String(repeating: "a", count: 32),
                                                         mode: "ask", effort: "high"))
        let full = try json(transport.requests[1])
        XCTAssertEqual(full["clientMessageId"] as? String, String(repeating: "a", count: 32))
        XCTAssertEqual(full["mode"] as? String, "ask")
        XCTAssertEqual(full["effort"] as? String, "high")
        XCTAssertEqual(full["attachments"] as? [String], ["att"])
        XCTAssertNil(full["agent"])
    }

    func testSendOutcomesNeverRetry() async throws {
        let lost = StreamTransport(error: URLError(.networkConnectionLost))
        let lostOutcome = try await makeClient(lost).sendChatMessage(ChatSendRequest(projectID: "p", sessionID: "s", text: "x"))
        XCTAssertEqual(lostOutcome, .uncertain)
        XCTAssertEqual(lost.requests.count, 1)
        let refused = StreamTransport(error: URLError(.cannotConnectToHost))
        let refusedOutcome = try await makeClient(refused).sendChatMessage(ChatSendRequest(projectID: "p", sessionID: "s", text: "x"))
        XCTAssertEqual(refusedOutcome, .failed(.unreachable))
        let repeatUncertain = StreamTransport(status: 409, body: #"{"error":{"code":"delivery_uncertain","message":"An earlier send with this ID may have reached the agent"}}"#)
        let repeatOutcome = try await makeClient(repeatUncertain).sendChatMessage(
            ChatSendRequest(projectID: "p", sessionID: "s", text: "x", clientMessageID: String(repeating: "b", count: 32)))
        XCTAssertEqual(repeatOutcome, .uncertain)
        let duplicate = StreamTransport(status: 202, body: #"{"accepted":true,"messageId":"msg_1","duplicate":true}"#)
        let duplicateOutcome = try await makeClient(duplicate).sendChatMessage(ChatSendRequest(projectID: "p", sessionID: "s", text: "x"))
        guard case let .accepted(receipt) = duplicateOutcome else { return XCTFail() }
        XCTAssertTrue(receipt.duplicate)
        let invalid = StreamTransport(status: 400, body: #"{"error":{"code":"invalid_request","message":"Text is required"}}"#)
        let invalidOutcome = try await makeClient(invalid).sendChatMessage(ChatSendRequest(projectID: "p", sessionID: "s", text: ""))
        XCTAssertEqual(invalidOutcome, .failed(.server(code: "invalid_request", message: "Text is required")))
    }

    func testForkContinueRegenerateAndRewindRoutes() async throws {
        let forked = StreamTransport(status: 201, body: #"{"id":"codex:2","title":"Plan (fork)","projectId":"p","provider":"codex","parentSessionId":"codex:1"}"#)
        let fork = try await makeClient(forked).forkChat(projectID: "p", sessionID: "codex:1", messageID: "m1", title: "Plan (fork)")
        XCTAssertEqual(fork, .created(Session(id: "codex:2", title: "Plan (fork)", projectID: "p", provider: "codex", parentSessionID: "codex:1")))
        XCTAssertEqual(forked.requests[0].url?.path, "/v1/chat/fork")
        XCTAssertEqual(try json(forked.requests[0])["messageId"] as? String, "m1")

        let continued = StreamTransport(status: 201, body: #"{"id":"ses_9","title":"Plan (continued)","projectId":"p","provider":"opencode","parentSessionId":"codex:1","seed":{"included":3,"omitted":0,"chars":900}}"#)
        let result = try await makeClient(continued).continueChat(ChatContinueRequest(projectID: "p", sourceSessionID: "codex:1", provider: "opencode", model: "a/b"))
        guard case let .created(session) = result else { return XCTFail() }
        XCTAssertEqual(session.parentSessionID, "codex:1")
        let continueBody = try json(continued.requests[0])
        XCTAssertEqual(Set(continueBody.keys), ["projectId", "sourceSessionId", "provider", "model"])
        XCTAssertEqual(continued.requests[0].url?.path, "/v1/chat/continue")

        // throughMessageId goes out only when set (hosts that list continueThrough).
        let through = StreamTransport(status: 201, body: #"{"id":"ses_10","title":"Plan (continued)","projectId":"p","provider":"opencode","parentSessionId":"codex:1","seed":{"included":2,"omitted":0,"chars":400}}"#)
        _ = try await makeClient(through).continueChat(ChatContinueRequest(projectID: "p", sourceSessionID: "codex:1", provider: "opencode", throughMessageID: "m7"))
        let throughBody = try json(through.requests[0])
        XCTAssertEqual(Set(throughBody.keys), ["projectId", "sourceSessionId", "provider", "throughMessageId"])
        XCTAssertEqual(throughBody["throughMessageId"] as? String, "m7")
        let unset = StreamTransport(status: 201, body: #"{"id":"ses_11","title":"Plan (continued)","projectId":"p","provider":"opencode","parentSessionId":"codex:1","seed":{"included":2,"omitted":0,"chars":400}}"#)
        _ = try await makeClient(unset).continueChat(ChatContinueRequest(projectID: "p", sourceSessionID: "codex:1", provider: "opencode", throughMessageID: ""))
        XCTAssertEqual(Set(try json(unset.requests[0]).keys), ["projectId", "sourceSessionId", "provider"])

        let lost = StreamTransport(error: URLError(.timedOut))
        let lostFork = try await makeClient(lost).forkChat(projectID: "p", sessionID: "s", messageID: nil, title: nil)
        XCTAssertEqual(lostFork, .uncertain, "A fork whose answer never came may exist; it is reported, not retried")

        let regenerated = StreamTransport(status: 202, body: "")
        let regenerateOutcome = try await makeClient(regenerated).regenerateChat(projectID: "p", sessionID: "s")
        XCTAssertEqual(regenerateOutcome, .accepted)
        XCTAssertEqual(Set(try json(regenerated.requests[0]).keys), ["projectId", "sessionId"])
        let busy = StreamTransport(status: 409, body: #"{"error":{"code":"agent_busy","message":"Wait"}}"#)
        let busyOutcome = try await makeClient(busy).regenerateChat(projectID: "p", sessionID: "s")
        XCTAssertEqual(busyOutcome, .failed(.server(code: "agent_busy", message: "Wait")))

        let rewound = StreamTransport(status: 200, body: #"{"rewound":true,"filesRestore":"immediate"}"#)
        let rewindOutcome = try await makeClient(rewound).rewindChat(projectID: "p", sessionID: "s", messageID: "m")
        XCTAssertEqual(rewindOutcome, .accepted(.immediate))
        let older = StreamTransport(status: 200, body: #"{"restored":true}"#)
        let restoreOutcome = try await makeClient(older).restoreChat(projectID: "p", sessionID: "s")
        XCTAssertEqual(restoreOutcome, .accepted(nil))
    }

    func testPagesAndOptions() async throws {
        let page = StreamTransport(status: 200, body: #"{"messages":[{"id":"m2","role":"assistant","parts":[{"id":"p","kind":"text","text":"hi"}]},{"id":"m1","role":"user"}],"hasMore":true,"oldestId":"m1"}"#)
        let loaded = try await makeClient(page).chatMessagesPage(projectID: "p", sessionID: "s", before: "m3")
        XCTAssertEqual(loaded.messages.map(\.id), ["m2", "m1"])
        XCTAssertTrue(loaded.hasMore)
        XCTAssertEqual(loaded.oldestID, "m1")
        let query = URLComponents(url: try XCTUnwrap(page.requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "before" }?.value, "m3")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")

        let options = StreamTransport(status: 200, body: #"{"models":[{"id":"codex/default","name":"Default","provider":"Codex"},{"id":"codex/gpt","name":"GPT","provider":"Codex","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"codex/default","agents":["build"],"modes":[{"id":"auto-review","name":"Auto review"},{"id":"ask","name":"Ask"}],"defaultMode":"auto-review"}"#)
        let decoded = try await makeClient(options).chatOptions(projectID: "p", provider: "codex")
        XCTAssertEqual(decoded.models[1].efforts, ["low", "high"])
        XCTAssertEqual(decoded.modes?.map(\.id), ["auto-review", "ask"])
        XCTAssertEqual(decoded.defaultMode, "auto-review")
        let optionQuery = URLComponents(url: try XCTUnwrap(options.requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(optionQuery.first { $0.name == "provider" }?.value, "codex")
        let old = try ProtocolDecoder.decode(ChatOptionsResponse.self, from: Data(#"{"models":[{"id":"a/b","name":"B","provider":"A"}],"defaultModel":"a/b","agents":["build","plan"]}"#.utf8))
        XCTAssertNil(old.modes)
        XCTAssertNil(old.models[0].efforts)
    }

    func testCapabilitiesGateProviderFeatures() throws {
        let json = #"{"interactions":true,"terminal":true,"chatFeatures":["events","clientMessageId","continue"],"chatProviderInfo":{"opencode":{"transport":"sse","features":["rewind","restoreFiles","approvals"]},"codex":{"version":"0.156.1","transport":"app-server","features":["fork","modes","effort"]}}}"#
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(json.utf8))
        XCTAssertTrue(capabilities.supports(.events))
        XCTAssertTrue(capabilities.supports(.continue))
        XCTAssertFalse(capabilities.supports(.regenerate))
        XCTAssertTrue(capabilities.supports(.rewind, provider: "opencode"))
        XCTAssertFalse(capabilities.supports(.fork, provider: "opencode"))
        XCTAssertTrue(capabilities.supports(.modes, provider: "codex"))
        XCTAssertEqual(capabilities.chatProviderInfo?["codex"]?.version, "0.156.1")
        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":false,"chatFeatures":["queue"]}"#.utf8))
        XCTAssertNil(older.chatProviderInfo)
        XCTAssertFalse(older.supports(.effort, provider: "codex"))
    }

    func testLegacyTranscriptBecomesTheUnifiedModel() throws {
        let json = #"""
        {"messages":[{"id":"u1","role":"user","text":"look","attachments":[{"name":"shot.png","mime":"image/png"}]},
                     {"id":"a1","role":"assistant","text":"done","reasoning":[{"text":"checking","durationMs":1500}],
                      "tools":[{"id":"t1","callId":"c1","name":"read","status":"completed","title":"a.swift","input":"{}","output":"ok","error":"","truncated":false}]},
                     {"id":"a2","role":"assistant","text":"x","parts":[{"id":"p2","kind":"text","text":"x"},{"id":"p1","kind":"tool","tool":{"name":"bash","status":"running"}}],
                      "createdAt":"2026-09-24T09:28:09.499Z","model":"a/b"}]}
        """#
        let transcript = try ProtocolDecoder.decode(MessagesResponse.self, from: Data(json.utf8))
        let user = ConversationMessage(legacy: transcript.messages[0], chatID: "s", turnID: "u1", ord: 1, provider: "opencode", streaming: false)
        XCTAssertEqual(user.parts.map(\.kind), [.text, .attachment])
        let reply = ConversationMessage(legacy: transcript.messages[1], chatID: "s", turnID: "u1", ord: 2, provider: "opencode", streaming: true)
        XCTAssertEqual(reply.parts.map(\.kind), [.reasoning, .tool, .text])
        XCTAssertEqual(reply.parts[0].durationMs, 1500)
        XCTAssertEqual(reply.parts[1].id, "t1")
        XCTAssertEqual(reply.status, .streaming)
        XCTAssertEqual(reply.turnID, "u1")
        let ordered = ConversationMessage(legacy: transcript.messages[2], chatID: "s", turnID: "u1", ord: 3, provider: "opencode", streaming: false)
        XCTAssertEqual(ordered.parts.map(\.id), ["p2", "p1"], "?parts=1 keeps the host's order")
        XCTAssertEqual(ordered.model, "a/b")
        XCTAssertEqual(ChatTime.date(ordered.createdAt)?.timeIntervalSince1970 ?? 0, 1790242089.499, accuracy: 0.001)
    }

    private func makeClient(_ transport: StreamTransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

/// Serves one response for every request; streams its lines through the
/// transport's own line bound, as a real transport would.
private final class StreamTransport: APITransport, @unchecked Sendable {
    private let status: Int
    private let lineValues: [String]
    private let body: Data
    private let error: Error?
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    private var limitStorage: [Int] = []

    init(status: Int = 200, lines: [String] = [], body: String = "", error: Error? = nil) {
        self.status = status; lineValues = lines; self.body = Data(body.utf8); self.error = error
    }
    var requests: [URLRequest] { lock.withLock { storage } }
    var limits: [Int] { lock.withLock { limitStorage } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storage.append(request) }
        if let error { throw error }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        lock.withLock { storage.append(request); limitStorage.append(maxLineBytes) }
        if let error { throw error }
        let values = lineValues
        let stream = AsyncThrowingStream<String, Error> { continuation in
            var splitter = BoundedLineSplitter(limit: maxLineBytes)
            do {
                for byte in values.joined(separator: "\n").utf8 {
                    if let line = try splitter.append(byte) { continuation.yield(line) }
                }
                if let line = splitter.finish() { continuation.yield(line) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        return (stream, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
