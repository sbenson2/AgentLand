import Foundation
import XCTest
@testable import AgentLandCore

/// The owner's memory (docs/HOST-API.md "Memory"): `GET /v1/memory`, and the delete a "Memory updated" card's Undo
/// sends with its refusals, through a real `URLSession` answered by the stub protocol, so methods and queries are the
/// ones production sends.
final class MemoryClientTests: XCTestCase {
    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    private static func refusal(_ code: String, _ message: String = "Refused") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    // MARK: Reading

    func testTheListReadsTheContractsExample() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/memory")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            // As docs/HOST-API.md prints it.
            return (200, Data(#"""
            {"enabled": true,
             "entries": [{"id": "mem_4f2a9c1e", "text": "Prefers metric units",
                          "createdAt": "2026-09-27T18:04:11.000Z", "updatedAt": "2026-09-27T18:04:11.000Z"}],
             "limits": {"maxEntries": 50, "maxTotalChars": 2000}}
            """#.utf8))
        }
        let list = try await (try client()).memory()
        let saved = try XCTUnwrap(ChatTime.date("2026-09-27T18:04:11.000Z"))
        XCTAssertEqual(list, MemoryList(enabled: true, entries: [MemoryEntry(id: "mem_4f2a9c1e", text: "Prefers metric units",
                                                                             createdAt: saved, updatedAt: saved)]))
        XCTAssertEqual(list.limits, MemoryLimits(maxEntries: 50, maxTotalChars: 2_000))
        XCTAssertEqual(list.limits, .contract)
    }

    func testEntriesItCannotReadAreLeftOutAndTheRestIsReadLeniently() async throws {
        let longID = String(repeating: "m", count: MemoryEntry.maximumIDBytes + 1)
        ArchiveStubProtocol.install { _, _ in
            (200, Data(#"""
            {"enabled": false, "later": 1,
             "entries": [{"id": "mem_1", "text": "Prefers\n tea", "createdAt": "yesterday", "source": "model"},
                         {"text": "No id"}, {"id": "", "text": "Empty id"}, {"id": "\#(longID)", "text": "Long id"},
                         {"id": 7, "text": "Number id"}, {"id": "mem_2"}, "mem_3", null,
                         {"id": "mem_1", "text": "Second copy"},
                         {"id": "mem_4", "text": "Likes  quiet\tmornings", "updatedAt": "2026-09-27T18:05:00Z"}],
             "limits": {"maxEntries": -1, "maxTotalChars": "many"}}
            """#.utf8))
        }
        let list = try await (try client()).memory()
        XCTAssertFalse(list.enabled)
        XCTAssertEqual(list.entries.map(\.id), ["mem_1", "mem_4"], "Entries without a readable ID or text, and repeats, are left out")
        XCTAssertEqual(list.entries.map(\.text), ["Prefers tea", "Likes quiet mornings"], "Text is one line")
        XCTAssertNil(list.entries[0].createdAt, "A time this version cannot read is unknown")
        XCTAssertEqual(list.entries[1].updatedAt, ChatTime.date("2026-09-27T18:05:00Z"))
        XCTAssertEqual(list.limits, .contract, "Limits it cannot read are the contract's")

        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"enabled":true,"entries":[]}"#.utf8)) }
        let empty = try await (try client()).memory()
        XCTAssertEqual(empty, MemoryList(enabled: true), "Missing limits are the contract's")
    }

    func testAListWithoutEnabledOrEntriesCannotBeRead() async throws {
        for body in [#"{"entries":[]}"#, #"{"enabled":true}"#, #"{"enabled":"yes","entries":[]}"#, #"{"enabled":true,"entries":{}}"#] {
            ArchiveStubProtocol.install { _, _ in (200, Data(body.utf8)) }
            do {
                _ = try await (try client()).memory()
                XCTFail("Not an answer this version can read: \(body)")
            } catch {
                XCTAssertEqual(error as? ClientError, .decoding, body)
            }
        }
    }

    func testAHostWithoutAMemoryStoreSaysSo() async throws {
        ArchiveStubProtocol.install { _, _ in (503, Self.refusal("memory_unavailable", "Memory is not available on this Mac.")) }
        do {
            _ = try await (try client()).memory()
            XCTFail("503 throws")
        } catch let error as ClientError {
            XCTAssertEqual(error, .server(code: "memory_unavailable", message: "Memory is not available on this Mac."))
        }
    }

    // MARK: Changes

    func testADeleteSendsTheContractsMethodAndQuery() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"removed":true}"#.utf8)) }
        let removed = await api.deleteMemory(id: "mem_4f2a9c1e")
        XCTAssertEqual(removed, .removed)
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "DELETE")
        XCTAssertEqual(sent.request.url?.path, "/v1/memory")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(sent.request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "id", value: "mem_4f2a9c1e")])
        XCTAssertTrue(sent.body?.isEmpty ?? true, "A delete sends no body")

        // An ID the host could not have given is never sent.
        ArchiveStubProtocol.install { _, _ in XCTFail("An invalid ID is never sent"); return (200, Data()) }
        let empty = await api.deleteMemory(id: "")
        XCTAssertEqual(empty, .failed(.invalidResponse))
        let long = await api.deleteMemory(id: String(repeating: "m", count: MemoryEntry.maximumIDBytes + 1))
        XCTAssertEqual(long, .failed(.invalidResponse))
    }

    func testRefusalsAreNamedByTheirCodeAndStatus() async throws {
        let api = try client()
        let cases: [(Int, String, MemoryRefusal)] = [
            (404, "not_found", .notFound), (400, "memory_limit", .overLimit), (503, "memory_unavailable", .unavailable),
        ]
        for (status, code, reason) in cases {
            XCTAssertEqual(reason.status, status)
            ArchiveStubProtocol.install { _, _ in (status, Self.refusal(code, "Words for \(code).")) }
            let removed = await api.deleteMemory(id: "mem_1")
            XCTAssertEqual(removed, .refused(reason, message: "Words for \(code)."), code)
        }

        // A known code with another status is not that refusal.
        ArchiveStubProtocol.install { _, _ in (409, Self.refusal("not_found", "Odd.")) }
        var outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .failed(.server(code: "not_found", message: "Odd.")))
        // Other refusals changed nothing: a request the host could not take, and a change it could not save.
        ArchiveStubProtocol.install { _, _ in (400, Self.refusal("invalid_request", "ID is missing.")) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .failed(.server(code: "invalid_request", message: "ID is missing.")))
        ArchiveStubProtocol.install { _, _ in (500, Self.refusal(MemoryErrorCode.storage, "Not saved.")) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .failed(.server(code: "storage_error", message: "Not saved.")))
        // Another server error may have made the change.
        ArchiveStubProtocol.install { _, _ in (500, Self.refusal("internal", "It broke.")) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in (502, Data()) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .uncertain)
    }

    func testLostAnswersAreUncertainAndUndeliveredRequestsFail() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        var outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .uncertain, "A lost connection may have delivered it")
        ArchiveStubProtocol.install { _, _ in throw URLError(.timedOut) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .failed(.unreachable), "Provably not sent")

        // The host made the change, but its answer cannot be read: what it keeps now is unknown.
        ArchiveStubProtocol.install { _, _ in (200, Data("done".utf8)) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"removed":false}"#.utf8)) }
        outcome = await api.deleteMemory(id: "mem_1")
        XCTAssertEqual(outcome, .uncertain)
    }

    func testUndoRemovesTheEntryASaveNamed() async throws {
        // A save's tool part names its entry; Undo deletes that ID, and a 404 means it is gone already.
        let part = try ProtocolDecoder.decode(ConversationTool.self, from: Data(#"""
        {"name":"agentland_memory_save","callId":"c","status":"completed","memory":{"id":"mem_9","text":"Prefers tea"}}
        """#.utf8))
        let memory = try XCTUnwrap(part.memory)
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "mem_9")
            return (404, Self.refusal("not_found", "No memory entry has that ID."))
        }
        let undo = await (try client()).deleteMemory(id: memory.id)
        XCTAssertEqual(undo, .refused(.notFound, message: "No memory entry has that ID."))
    }
}
