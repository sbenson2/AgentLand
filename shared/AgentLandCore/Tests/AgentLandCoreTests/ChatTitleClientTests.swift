import Foundation
import XCTest
@testable import AgentLandCore

/// Chat names: who named a chat and for which message, in the sessions list, the snapshot and
/// `chat.updated`, and `POST /v1/chat/title` with its answers.
final class ChatTitleClientTests: XCTestCase {
    private final class Host: APITransport, @unchecked Sendable {
        private let result: Result<(Data, Int), Error>
        private let lock = NSLock()
        private var storage: [URLRequest] = []
        init(_ body: String, status: Int) { result = .success((Data(body.utf8), status)) }
        init(error: Error) { result = .failure(error) }
        var requests: [URLRequest] { lock.withLock { storage } }
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { storage.append(request) }
            let (data, status) = try result.get()
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func client(_ host: Host) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: host)
    }

    private func name(_ host: Host) async throws -> ChatTitleOutcome {
        try await client(host).nameChat(projectID: "p", sessionID: "claude:s1", title: "Fix the login redirect", basedOn: "msg_9")
    }

    // MARK: Titles the apps send

    /// The host refuses titles over 200 bytes of UTF-8, and an agent's name of 100 characters is up to 400
    /// bytes outside Latin scripts: a longer title is cut to fit, at a character (grapheme cluster)
    /// boundary, so no letter, accent or emoji is split.
    func testTitlesAreCutToTheHostsByteLimitAtACharacterBoundary() {
        XCTAssertEqual(HostTitle.maximumBytes, 200)
        let latin = String(repeating: "a", count: 200)
        XCTAssertEqual(HostTitle.clipped(latin), latin, "200 bytes fit whole")
        XCTAssertEqual(HostTitle.clipped(latin + "b"), latin)
        XCTAssertEqual(HostTitle.clipped("Gemini CLI chat"), "Gemini CLI chat")
        XCTAssertEqual(HostTitle.clipped(""), "")

        let name = String(repeating: "月", count: 100)
        XCTAssertEqual(name.utf8.count, 300)
        XCTAssertEqual(HostTitle.clipped(name), String(repeating: "月", count: 66), "198 bytes: a 67th character would make 201")
        // Characters of several code points stay whole: a family emoji (25 bytes), a flag (8), a letter with its
        // accent written apart (3).
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.utf8.count, 25)
        XCTAssertEqual(HostTitle.clipped(String(repeating: family, count: 9)), String(repeating: family, count: 8))
        XCTAssertEqual(HostTitle.clipped("a" + String(repeating: family, count: 8)), "a" + String(repeating: family, count: 7))
        XCTAssertEqual(HostTitle.clipped(String(repeating: "e\u{301}", count: 70)), String(repeating: "e\u{301}", count: 66))
        for title in [name, String(repeating: family, count: 9), String(repeating: "🇯🇵", count: 30), String(repeating: "e\u{301}", count: 70)] {
            let clipped = HostTitle.clipped(title)
            XCTAssertLessThanOrEqual(clipped.utf8.count, HostTitle.maximumBytes)
            XCTAssertTrue(title.hasPrefix(clipped))
            let next = title[title.index(title.startIndex, offsetBy: clipped.count)]
            XCTAssertGreaterThan(clipped.utf8.count + next.utf8.count, HostTitle.maximumBytes, "The next character would not fit")
        }
    }

    /// Every chat and terminal is made with a title the host takes: create, fork and continue cut theirs.
    func testChatsAndTerminalsAreMadeWithTitlesTheHostTakes() async throws {
        let name = String(repeating: "月", count: 100)
        let fitting = String(repeating: "月", count: 66)
        ArchiveStubProtocol.install { request, _ in
            request.url?.path == "/v1/terminals"
                ? (201, Data(#"{"id":"t1","title":"\#(fitting)","projectId":"p","status":"running"}"#.utf8))
                : (201, Data(#"{"id":"kimi:2","title":"\#(fitting)","projectId":"p","provider":"kimi"}"#.utf8))
        }
        let api = APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
        _ = try await api.createSession(projectID: "p", title: name, provider: "kimi")
        _ = await api.createTerminal(projectID: "p", title: name, rows: 24, cols: 80, program: "kimi")
        _ = await api.forkChat(projectID: "p", sessionID: "kimi:1", messageID: nil, title: name + " (fork)")
        _ = await api.continueChat(ChatContinueRequest(projectID: "p", sourceSessionID: "kimi:1", provider: "kimi", title: name))
        _ = try await api.createSession(projectID: "p", title: "Gemini CLI chat", provider: "gemini")
        let sent = ArchiveStubProtocol.requests
        XCTAssertEqual(sent.map { $0.request.url?.path }, ["/v1/sessions", "/v1/terminals", "/v1/chat/fork", "/v1/chat/continue", "/v1/sessions"])
        let titles = try sent.map { entry in
            try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(entry.body)) as? [String: Any])["title"] as? String
        }
        XCTAssertEqual(titles, [fitting, fitting, fitting, fitting, "Gemini CLI chat"], "Cut to 198 bytes; a title that fits goes whole")
    }

    // MARK: Decoding

    func testFeatureAndChatInfoFieldsDecode() throws {
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self,
                                                      from: Data(#"{"interactions":true,"terminal":true,"chatFeatures":["events","title"]}"#.utf8))
        XCTAssertTrue(capabilities.supports(.title))
        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true,"chatFeatures":["events"]}"#.utf8))
        XCTAssertFalse(older.supports(.title))

        let snapshot = try ChatEventEnvelope.decode(line: #"{"seq":3,"type":"snapshot","chat":{"id":"s","title":"Fix login","provider":"claude","titleSource":"device","titleBasis":"msg_4"},"messages":[],"status":{"state":"idle"}}"#)
        guard case let .snapshot(value) = snapshot.event else { return XCTFail("Expected a snapshot") }
        XCTAssertEqual(value.chat.titleSource, .device)
        XCTAssertEqual(value.chat.titleBasis, "msg_4")

        let update = try ChatEventEnvelope.decode(line: #"{"seq":4,"type":"chat.updated","title":"Tidy imports","titleSource":"auto","titleBasis":"msg_5"}"#)
        XCTAssertEqual(update.event, .chatUpdated(ChatInfoUpdate(title: "Tidy imports", titleSource: .auto, titleBasis: "msg_5")))
        let plain = try ChatEventEnvelope.decode(line: #"{"seq":5,"type":"chat.updated","model":"a/b"}"#)
        XCTAssertEqual(plain.event, .chatUpdated(ChatInfoUpdate(model: "a/b")))
    }

    /// A chat that went on in another names it and when (`continuedIn`, `continuedAt`); an ID that is not one counts as
    /// none, and takes its time with it.
    func testContinuationDecodesInTheSnapshotAndChatUpdated() throws {
        let snapshot = try ChatEventEnvelope.decode(line: #"{"seq":3,"type":"snapshot","chat":{"id":"claude:a","title":"Fix login","provider":"claude","continuedIn":"claude:b","continuedAt":"2026-10-26T08:45:00.123Z"},"messages":[],"status":{"state":"idle"}}"#)
        guard case let .snapshot(value) = snapshot.event else { return XCTFail("Expected a snapshot") }
        XCTAssertEqual(value.chat.continuedIn, "claude:b")
        XCTAssertEqual(value.chat.continuedAt, "2026-10-26T08:45:00.123Z")
        XCTAssertEqual(value.chat.continuedDate, try Date("2026-10-26T08:45:00.123Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))

        let update = try ChatEventEnvelope.decode(line: #"{"seq":4,"type":"chat.updated","continuedIn":"claude:b","continuedAt":"2026-10-26T08:45:00Z"}"#)
        XCTAssertEqual(update.event, .chatUpdated(ChatInfoUpdate(continuedIn: "claude:b", continuedAt: "2026-10-26T08:45:00Z")))

        for bad in [#""../b""#, #""""#, "42", "\"\(String(repeating: "a", count: 129))\""] {
            let decoded = try ChatEventEnvelope.decode(line: #"{"seq":5,"type":"chat.updated","title":"T","continuedIn":\#(bad),"continuedAt":"2026-10-26T08:45:00Z"}"#)
            XCTAssertEqual(decoded.event, .chatUpdated(ChatInfoUpdate(title: "T")), bad)
        }
        let info = try JSONDecoder().decode(ChatInfo.self, from: JSONEncoder().encode(value.chat))
        XCTAssertEqual(info, value.chat, "A saved copy keeps it")
    }

    func testSessionsListCarriesTheNamingWhenTheHostSendsIt() throws {
        let json = #"""
        {"sessions":[{"id":"a","title":"New chat","projectId":"p"},
                     {"id":"b","title":"Fix login","projectId":"p","provider":"claude","titleSource":"provider","titleBasis":"m2"},
                     {"id":"c","title":"Tidy","projectId":"p","titleSource":"summary","titleBasis":""},
                     {"id":"d","title":"Odd","projectId":"p","titleSource":7,"titleBasis":["x"]}]}
        """#
        let sessions = try ProtocolDecoder.decode(SessionsResponse.self, from: Data(json.utf8)).sessions
        XCTAssertEqual(sessions.map(\.titleSource), [nil, .provider, ChatTitleSource(rawValue: "summary"), nil])
        XCTAssertEqual(sessions.map(\.titleBasis), [nil, "m2", nil, nil])
    }

    // MARK: Naming

    func testNamingSendsTheFourFieldsAndReadsTheAnswer() async throws {
        let host = Host(#"{"title":"Fix the login redirect","titleSource":"device","titleBasis":"msg_9"}"#, status: 200)
        let outcome = try await name(host)
        XCTAssertEqual(outcome, .named(ChatTitleAnswer(title: "Fix the login redirect", titleSource: .device, titleBasis: "msg_9")))
        let request = try XCTUnwrap(host.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/chat/title")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["projectId": "p", "sessionId": "claude:s1", "title": "Fix the login redirect", "basedOn": "msg_9"])
    }

    func testStaleAnswerCarriesTheHostsCurrentTitle() async throws {
        let inside = Host(#"{"error":{"code":"title_stale","message":"A newer title exists","title":"Tidy imports","titleSource":"device","titleBasis":"msg_12"}}"#, status: 409)
        let outcome = try await name(inside)
        XCTAssertEqual(outcome, .stale(ChatTitleAnswer(title: "Tidy imports", titleSource: .device, titleBasis: "msg_12")))
        XCTAssertEqual(inside.requests.count, 1, "Nothing is sent again")

        let beside = Host(#"{"error":{"code":"title_stale","message":"A newer title exists"},"title":"Tidy imports","titleSource":"auto","titleBasis":"msg_12"}"#, status: 409)
        let besideOutcome = try await name(beside)
        XCTAssertEqual(besideOutcome, .stale(ChatTitleAnswer(title: "Tidy imports", titleSource: .auto, titleBasis: "msg_12")))

        let bare = Host(#"{"error":{"code":"title_stale","message":"A newer title exists"}}"#, status: 409)
        let bareOutcome = try await name(bare)
        XCTAssertEqual(bareOutcome, .stale(nil))
    }

    func testRefusalsFail() async throws {
        for (status, code) in [(400, "invalid_request"), (404, "not_found"), (502, "provider_unavailable")] {
            let host = Host(#"{"error":{"code":"\#(code)","message":"No"}}"#, status: status)
            let outcome = try await name(host)
            XCTAssertEqual(outcome, .failed(.server(code: code, message: "No")), code)
        }
        let otherConflict = Host(#"{"error":{"code":"agent_busy","message":"Busy"}}"#, status: 409)
        let conflictOutcome = try await name(otherConflict)
        XCTAssertEqual(conflictOutcome, .failed(.server(code: "agent_busy", message: "Busy")))
    }

    func testTransportFailures() async throws {
        let unreachable = try await name(Host(error: URLError(.cannotConnectToHost)))
        XCTAssertEqual(unreachable, .failed(.unreachable))
        let lost = try await name(Host(error: URLError(.networkConnectionLost)))
        XCTAssertEqual(lost, .uncertain)
        let unreadable = try await name(Host(#"{"nope":true}"#, status: 200))
        XCTAssertEqual(unreadable, .uncertain)
    }
}
