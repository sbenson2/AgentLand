import Foundation
import XCTest
@testable import AgentLandCore

/// Answers requests from a handler the test sets, through a real `URLSession`,
/// so query encoding, headers and bodies are the ones production sends.
final class ArchiveStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (Int, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var log: [(URLRequest, Data?)] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler; log = [] }
    }
    static var requests: [(request: URLRequest, body: Data?)] { lock.withLock { log.map { ($0.0, $0.1) } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log.append((request, body))
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// `APITransport` over a `URLSession` whose only protocol is the stub.
final class ArchiveStubTransport: APITransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveStubProtocol.self]
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, http)
    }
}

final class ArchiveClientTests: XCTestCase {
    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testCapabilitiesDecodeTheArchiveEntry() throws {
        let full = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: json(#"{"interactions":true,"terminal":true,"chatFeatures":["events","continue"],"archive":{"version":1,"features":["sync","search","export","terminalLogs","continue"]}}"#))
        XCTAssertEqual(full.archive, ArchiveCapabilities(version: 1, features: ["sync", "search", "export", "terminalLogs", "continue"]))
        XCTAssertTrue(full.supportsArchive(.sync))
        XCTAssertTrue(full.supportsArchive(.continue))
        XCTAssertFalse(full.continuesThroughMessage)
        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: json(#"{"interactions":true,"terminal":true}"#))
        XCTAssertNil(older.archive)
        XCTAssertFalse(older.supportsArchive(.sync))
        let odd = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: json(#"{"interactions":true,"terminal":true,"archive":"yes"}"#))
        XCTAssertNil(odd.archive, "An archive entry this version cannot read counts as none")
        let through = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: json(#"{"interactions":true,"terminal":true,"chatFeatures":["continue","continueThrough"]}"#))
        XCTAssertTrue(through.continuesThroughMessage)
    }

    func testChangesPagesDecodeEveryEntityAndSkipWhatTheyCannotRead() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/archive/changes")
            return (200, Data(#"""
            {"epoch":"e1-0a1b2c3d","resync":false,"cursor":"e1-0a1b2c3d.9","hasMore":true,"changes":[
             {"seq":1,"entity":"chat","op":"upsert","payload":{"id":"ses_1","projectId":"p1","provider":"claude","title":"Fix login","model":"claude/opus","parentId":"","createdAt":"2026-09-23T12:00:00.000Z","updatedAt":"2026-09-23T12:05:00.000Z"}},
             {"seq":2,"entity":"message","op":"upsert","payload":{"id":"m1","chatId":"ses_1","turnId":"m1","role":"user","status":"complete","ord":1,"createdAt":"2026-09-23T12:00:00.000Z","provider":"claude","parts":[{"id":"p","kind":"text","ord":0,"text":"Why does it loop?"},{"id":"a","kind":"attachment","ord":1,"attachment":{"name":"shot.png","mime":"image/png","size":10,"sha256":"ab"}}]}},
             {"seq":3,"entity":"message","op":"upsert","payload":{"id":"m2","chatId":"ses_1","role":"assistant","status":"complete","ord":2,"createdAt":"2026-09-23T12:00:01.000Z","provider":"claude","hidden":true,"parts":[]}},
             {"seq":4,"entity":"terminalLog","op":"upsert","payload":{"id":"t1","projectId":"p1","title":"Terminal","program":"shell","startedAt":"2026-09-23T11:00:00.000Z","status":"running","bytes":2048,"gapBytes":0}},
             {"seq":5,"entity":"message","op":"delete","payload":{"id":"m0","chatId":"ses_1"}},
             {"seq":6,"entity":"chat","op":"delete","payload":{"id":"ses_0"}},
             {"seq":7,"entity":"terminalLog","op":"delete","payload":{"id":"t0"}},
             {"seq":8,"entity":"hologram","op":"upsert","payload":{"id":"h"}},
             {"seq":9,"entity":"message","op":"delete","payload":{"id":"m9"}}
            ]}
            """#.utf8))
        }
        let page = try await client().archiveChanges(after: "e1-0a1b2c3d.0")
        let request = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        XCTAssertEqual(query(request), ["after": "e1-0a1b2c3d.0", "limit": "200"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertEqual(page.epoch, "e1-0a1b2c3d")
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.resync)
        XCTAssertEqual(page.changes.map(\.seq), Array(1...9))
        guard case let .chat(chat) = page.changes[0].item else { return XCTFail("chat") }
        XCTAssertEqual(chat.provider, "claude")
        XCTAssertNil(chat.parentID, "An empty parent is no parent")
        guard case let .message(user) = page.changes[1].item else { return XCTFail("message") }
        XCTAssertEqual(user.message.chatID, "ses_1")
        XCTAssertEqual(user.message.parts.last?.attachment, AttachmentRecord(name: "shot.png", mime: "image/png", size: 10, sha256: "ab"))
        XCTAssertFalse(user.hidden)
        guard case let .message(hidden) = page.changes[2].item else { return XCTFail("hidden message") }
        XCTAssertTrue(hidden.hidden)
        guard case let .terminalLog(log) = page.changes[3].item else { return XCTFail("log") }
        XCTAssertEqual(log.status, "running")
        XCTAssertEqual(log.bytes, 2048)
        XCTAssertEqual(page.changes[4].item, .messageDeleted(id: "m0", chatID: "ses_1"))
        XCTAssertEqual(page.changes[5].item, .chatDeleted(id: "ses_0"))
        XCTAssertEqual(page.changes[6].item, .terminalLogDeleted(id: "t0"))
        XCTAssertEqual(page.changes[7].item, .unreadable(entity: "hologram", op: "upsert"))
        XCTAssertEqual(page.changes[8].item, .unreadable(entity: "message", op: "delete"), "A message tombstone needs its chat")

        _ = try await client().archiveChanges(after: nil, limit: 999)
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["limit": "200"], "No cursor starts from the beginning")
    }

    func testChangesSendWaitOnlyWhenGiven() async throws {
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"epoch":"e1","resync":false,"cursor":"e1.4","hasMore":false,"changes":[]}"#.utf8)) }
        let api = try client()
        _ = try await api.archiveChanges(after: "e1.4")
        let plain = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        XCTAssertEqual(query(plain), ["after": "e1.4", "limit": "200"], "No wait unless asked: older hosts do not take it")
        XCTAssertEqual(plain.timeoutInterval, 60)
        _ = try await api.archiveChanges(after: "e1.4", wait: .seconds(20))
        let waited = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        XCTAssertEqual(query(waited), ["after": "e1.4", "limit": "200", "wait": "20000"])
        XCTAssertEqual(waited.timeoutInterval, 80, "The request outlives the wait")
        _ = try await api.archiveChanges(after: "e1.4", wait: .seconds(90))
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))["wait"], "20000", "Clamped to what the host takes")
        _ = try await api.archiveChanges(after: "e1.4", wait: .milliseconds(1500))
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))["wait"], "1500")
        _ = try await api.archiveChanges(after: "e1.4", wait: .zero)
        XCTAssertNil(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))["wait"])

        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: json(#"{"interactions":true,"terminal":true,"archive":{"version":1,"features":["sync","changesWait"]}}"#))
        XCTAssertTrue(capabilities.supportsArchive(.changesWait))
        XCTAssertFalse(CapabilitiesResponse(interactions: true, terminal: true, archive: ArchiveCapabilities(features: ["sync"])).supportsArchive(.changesWait))
    }

    func testChatPagesSearchAndTerminalLogListing() async throws {
        ArchiveStubProtocol.install { request, _ in
            switch request.url?.path {
            case "/v1/archive/chat" where request.url?.query?.contains("chatId=gone") == false:
                return (200, Data(#"{"chat":{"id":"ses_1","projectId":"p1","provider":"opencode","title":"T","createdAt":"2026-09-23T12:00:00.000Z","updatedAt":"2026-09-23T12:00:00.000Z"},"messages":[{"id":"m1","chatId":"ses_1","role":"user","ord":1,"parts":[]}],"hasMore":true,"oldestId":"m1"}"#.utf8))
            case "/v1/archive/search":
                return (200, Data(#"{"results":[{"chatId":"ses_1","messageId":"m1","projectId":"p1","provider":"claude","title":"T","role":"user","createdAt":"2026-09-23T12:00:00.000Z","snippet":"a \u0002cookie\u0003 loop"},{"chatId":"ses_2","messageId":"m2","projectId":"p1","title":"U","role":"user","createdAt":"2026-09-23T12:00:00.000Z","snippet":"\u0002cookie\u0003"}],"nextCursor":"s.20"}"#.utf8))
            case "/v1/archive/terminal-logs":
                return (200, Data(#"{"logs":[{"id":"t1","projectId":"p1","title":"Build","program":"shell","startedAt":"2026-09-23T11:00:00.000Z","endedAt":"2026-09-23T11:05:00.000Z","status":"exited","exitCode":0,"bytes":10,"gapBytes":4}]}"#.utf8))
            default:
                return (404, Data(#"{"error":{"code":"not_found","message":"Not found"}}"#.utf8))
            }
        }
        let api = try client()
        let page = try await api.archiveChat(chatID: "ses_1", before: "m9", limit: 80)
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["chatId": "ses_1", "before": "m9", "limit": "50"])
        XCTAssertEqual(page.oldestID, "m1")
        XCTAssertTrue(page.hasMore)

        let long = String(repeating: "é", count: 200)
        let from = Date(timeIntervalSince1970: 1_790_000_000), to = from.addingTimeInterval(86_400)
        let results = try await api.archiveSearch(ArchiveSearchRequest(text: long, projectID: "p1", provider: "claude", from: from, to: to,
                                                                       limit: 500, cursor: "s.20"))
        let search = query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))
        XCTAssertEqual(search["q"]?.utf8.count, 256, "q is cut to 256 bytes on a character boundary")
        XCTAssertEqual(search["projectId"], "p1")
        XCTAssertEqual(search["provider"], "claude")
        XCTAssertEqual(search["from"], "2026-09-21T14:13:20Z")
        XCTAssertEqual(search["to"], "2026-09-22T14:13:20Z")
        XCTAssertEqual(search["limit"], "50")
        XCTAssertEqual(search["cursor"], "s.20")
        XCTAssertEqual(results.results.first?.snippet, "a \u{2}cookie\u{3} loop")
        XCTAssertEqual(results.results.map(\.provider), ["claude", nil], "Hosts before provider leave it out")
        XCTAssertEqual(results.nextCursor, "s.20")

        let logs = try await api.archiveTerminalLogs(projectID: "p1")
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["projectId": "p1", "limit": "100"])
        XCTAssertEqual(logs.logs.first?.exitCode, 0)
        XCTAssertEqual(logs.logs.first?.gapBytes, 4)
        XCTAssertNil(logs.nextCursor)

        do {
            _ = try await api.archiveChat(chatID: "gone")
            XCTFail("404 must throw")
        } catch let error as ClientError {
            XCTAssertEqual(error, .server(code: "not_found", message: "Not found"))
        }
    }

    func testTerminalLogRangesDecodeRawAndText() async throws {
        let raw = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x68, 0x69, 0x0A])
        ArchiveStubProtocol.install { request, _ in
            let format = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value
            if format == "text" {
                return (200, Data(#"{"data":"hi\n","offset":0,"next":8,"eof":true,"size":8,"status":"exited"}"#.utf8))
            }
            return (200, Data(#"{"data":"\#(raw.base64EncodedString())","offset":0,"next":8,"eof":false,"size":8,"status":"running"}"#.utf8))
        }
        let api = try client()
        let bytes = try await api.archiveTerminalLog(id: "t1", offset: 0, length: 5 << 20)
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)),
                       ["id": "t1", "offset": "0", "length": "1048576", "format": "raw"], "Ranges are at most 1 MiB")
        XCTAssertEqual(bytes, ArchiveTerminalLogRange(data: raw, offset: 0, next: 8, eof: false, size: 8, status: "running"))
        let text = try await api.archiveTerminalLog(id: "t1", offset: 0, format: .text)
        XCTAssertEqual(String(decoding: text.data, as: UTF8.self), "hi\n")
        XCTAssertTrue(text.eof)

        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"data":"not base64!","offset":0,"next":3,"eof":false,"size":3,"status":"running"}"#.utf8)) }
        do {
            _ = try await api.archiveTerminalLog(id: "t1", offset: 0)
            XCTFail("undecodable bytes must throw")
        } catch let error as ClientError {
            XCTAssertEqual(error, .decoding)
        }
    }

    func testExportReturnsTheFileBytes() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/archive/export")
            return (200, Data("# Fix login\n".utf8))
        }
        let data = try await client().archiveExport(chatID: "ses_1", format: .markdown)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "# Fix login\n")
        let request = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        XCTAssertEqual(query(request), ["chatId": "ses_1", "format": "markdown"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
    }

    func testAttachmentBytesComeFromTheBlobRoute() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/archive/blob")
            if request.url?.query?.contains("name=gone") == true {
                return (404, Data(#"{"error":{"code":"attachment_not_archived","message":"This attachment's bytes were not archived"}}"#.utf8))
            }
            return (200, Data("picture bytes".utf8))
        }
        let api = try client()
        let data = try await api.archiveAttachment(chatID: "ses_1", messageID: "m1", name: "screen shot.png")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "picture bytes")
        let request = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        XCTAssertEqual(query(request), ["chatId": "ses_1", "messageId": "m1", "name": "screen shot.png"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        _ = try await api.archiveAttachment(chatID: "ses_1", messageID: "m1", name: "notes.txt", sha256: String(repeating: "ab", count: 32))
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))["sha256"], String(repeating: "ab", count: 32))
        do {
            _ = try await api.archiveAttachment(chatID: "ses_1", messageID: "m1", name: "gone")
            XCTFail("a name-only attachment must throw")
        } catch let error as ClientError {
            XCTAssertEqual(error, .server(code: "attachment_not_archived", message: "This attachment's bytes were not archived"))
        }

        // Archived parts carry size and SHA-256; live chats carry neither, and old copies decode as before.
        let archived = try ProtocolDecoder.decode(AttachmentRecord.self, from: json(#"{"name":"a.png","mime":"image/png","size":12,"sha256":"cd"}"#))
        XCTAssertEqual(archived, AttachmentRecord(name: "a.png", mime: "image/png", size: 12, sha256: "cd"))
        let live = try ProtocolDecoder.decode(AttachmentRecord.self, from: json(#"{"name":"a.png","mime":"image/png"}"#))
        XCTAssertNil(live.size)
        XCTAssertNil(live.sha256)
        let encoded = String(decoding: try JSONEncoder().encode(live), as: UTF8.self)
        XCTAssertFalse(encoded.contains("size") || encoded.contains("sha256"), "No new keys for records without them")
        XCTAssertTrue(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: json(#"{"interactions":true,"terminal":true,"archive":{"features":["blobs"]}}"#)).supportsArchive(.blobs))
    }

    func testDeleteReportsOnlyAConfirmedDeletion() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"deleted":true}"#.utf8)) }
        let deleted = await api.archiveDelete(.chat, id: "ses_1")
        XCTAssertEqual(deleted, .deleted)
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: String], ["kind": "chat", "id": "ses_1"])

        ArchiveStubProtocol.install { _, _ in (409, Data(#"{"error":{"code":"terminal_running","message":"End the terminal before deleting its log"}}"#.utf8)) }
        let running = await api.archiveDelete(.terminalLog, id: "t1")
        XCTAssertEqual(running, .failed(.server(code: "terminal_running", message: "End the terminal before deleting its log")))

        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        let lost = await api.archiveDelete(.chat, id: "ses_1")
        XCTAssertEqual(lost, .uncertain, "A lost connection may have deleted it")

        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await api.archiveDelete(.chat, id: "ses_1")
        XCTAssertEqual(unreachable, .failed(.unreachable))

        ArchiveStubProtocol.install { _, _ in (500, Data(#"{"error":{"code":"archive_error","message":"The archive could not complete the request"}}"#.utf8)) }
        let failed = await api.archiveDelete(.chat, id: "ses_1")
        XCTAssertEqual(failed, .failed(.server(code: "archive_error", message: "The archive could not complete the request")))
    }

    func testContinueSendsContextSizeAndCutOffOnlyWhenSet() async throws {
        ArchiveStubProtocol.install { _, _ in
            (201, Data(#"{"id":"ses_2","title":"Fix login (continued)","projectId":"p1","provider":"codex","parentSessionId":"ses_1","seed":{"included":3,"omitted":1,"chars":900}}"#.utf8))
        }
        let api = try client()
        let plain = await api.continueChat(ChatContinueRequest(projectID: "p1", sourceSessionID: "ses_1", provider: "codex"))
        XCTAssertEqual(plain, .created(Session(id: "ses_2", title: "Fix login (continued)", projectID: "p1", provider: "codex", parentSessionID: "ses_1")))
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ArchiveStubProtocol.requests.last?.body)) as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["projectId", "sourceSessionId", "provider"], "Older hosts reject unknown fields")

        _ = await api.continueChat(ChatContinueRequest(projectID: "p1", sourceSessionID: "ses_1", provider: "codex", model: "codex/gpt",
                                                       throughMessageID: "m7", contextChars: 999_999))
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ArchiveStubProtocol.requests.last?.body)) as? [String: Any])
        XCTAssertEqual(second["contextChars"] as? Int, 200_000, "Clamped to what the host accepts")
        XCTAssertEqual(second["throughMessageId"] as? String, "m7")
        XCTAssertEqual(second["model"] as? String, "codex/gpt")
    }
}
