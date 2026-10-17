import Foundation
import XCTest
@testable import AgentLandCore

final class ChatFeatureContractTests: XCTestCase {
    func testOlderHostMessagesAndCapabilitiesDecodeWithoutNewFields() throws {
        let message = try ProtocolDecoder.decode(ChatMessage.self, from: Data(#"{"id":"m1","role":"assistant","text":"hi"}"#.utf8))
        XCTAssertEqual(message.reasoning, [])
        XCTAssertEqual(message.attachments, [])
        let transcript = try ProtocolDecoder.decode(MessagesResponse.self, from: Data(#"{"messages":[]}"#.utf8))
        XCTAssertNil(transcript.rewind)
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":false}"#.utf8))
        XCTAssertFalse(capabilities.supports(.queue), "An older host keeps the original chat surface")
    }

    /// Schedules were removed (2026-10-06): a host from before still lists them, and its capabilities
    /// decode as they did, with the entry ignored.
    func testOlderHostsSchedulesEntryIsIgnored() throws {
        let json = #"{"interactions":true,"terminal":true,"chatFeatures":["queue"],"presence":["views"],"#
            + #""schedules":{"version":1,"budget":["claude"],"features":["fieldErrors","runPages","get","runNowChat"]}}"#
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(json.utf8))
        XCTAssertTrue(capabilities.supports(.queue))
        XCTAssertEqual(capabilities.presence, ["views"])
        let refusal = try ProtocolDecoder.decode(APIErrorEnvelope.self, from: Data(#"{"error":{"code":"invalid_request","message":"No","field":"cadence.at"}}"#.utf8))
        XCTAssertEqual(refusal.error.code, "invalid_request")
    }

    func testNewMessageFieldsRewindAndFeaturesDecode() throws {
        let json = #"""
        {"messages":[{"id":"m1","role":"user","text":"look","attachments":[{"name":"shot.png","mime":"image/png"}]},
                     {"id":"m2","role":"assistant","text":"done","reasoning":[{"text":"checking","durationMs":1500},{"text":"more"}]}],
         "rewind":{"messageId":"msg_7"}}
        """#
        let transcript = try ProtocolDecoder.decode(MessagesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(transcript.messages[0].attachments, [AttachmentRecord(name: "shot.png", mime: "image/png")])
        XCTAssertTrue(transcript.messages[0].attachments[0].isImage)
        XCTAssertEqual(transcript.messages[1].reasoning, [ReasoningRecord(text: "checking", durationMs: 1500), ReasoningRecord(text: "more")])
        XCTAssertEqual(transcript.rewind, RewindState(messageID: "msg_7"))
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true,"chatFeatures":["queue","rewind"]}"#.utf8))
        XCTAssertTrue(capabilities.supports(.queue))
        XCTAssertFalse(capabilities.supports(.attachments))
    }

    func testSendIncludesAttachmentIDsOnlyWhenPresent() async throws {
        let transport = ContractTransport(body: #"{"accepted":true}"#, status: 202)
        let client = try makeClient(transport)
        _ = await client.sendMessage(projectID: "p", sessionID: "s", text: "hi")
        _ = await client.sendMessage(projectID: "p", sessionID: "s", text: "", attachments: ["att_1", "att_2"])
        let plain = try json(transport.requests[0])
        XCTAssertNil(plain["attachments"], "Hosts reject unknown or empty fields they do not expect")
        XCTAssertNil(plain["model"])
        let withFiles = try json(transport.requests[1])
        XCTAssertEqual(withFiles["attachments"] as? [String], ["att_1", "att_2"])
        XCTAssertEqual(withFiles["text"] as? String, "")
    }

    func testUploadSendsRawBytesWithTypeAndScopedQuery() async throws {
        let transport = ContractTransport(body: #"{"id":"att_1","name":"a.png","mime":"image/png","size":3}"#, status: 201)
        let client = try makeClient(transport)
        let uploaded = try await client.uploadAttachment(projectID: "p", sessionID: "s", name: "a b.png", mime: "image/png", data: Data([1, 2, 3]))
        XCTAssertEqual(uploaded, UploadedAttachment(id: "att_1", name: "a.png", mime: "image/png", size: 3))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/attachments")
        XCTAssertEqual(request.httpBody, Data([1, 2, 3]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "projectId" }?.value, "p")
        XCTAssertEqual(query.first { $0.name == "sessionId" }?.value, "s")
        XCTAssertEqual(query.first { $0.name == "name" }?.value, "a b.png")
    }

    func testUncertainQueueDeliveryIsNotRetried() async throws {
        let transport = ContractTransport(error: URLError(.networkConnectionLost))
        let client = try makeClient(transport)
        let outcome = await client.enqueue(projectID: "p", sessionID: "s", text: "next", model: "", agent: "plan")
        XCTAssertEqual(outcome, .uncertain)
        XCTAssertEqual(transport.requests.count, 1)
        let body = try json(transport.requests[0])
        XCTAssertEqual(body["agent"] as? String, "plan")
        XCTAssertNil(body["model"], "An empty model means the host default")
        XCTAssertNil(body["attachments"], "Queued prompts carry text only")
    }

    func testQueueRewindAndRestoreUseDocumentedRoutes() async throws {
        let removed = ContractTransport(body: #"{"removed":true}"#, status: 200)
        let removal = try await makeClient(removed).removeQueued(projectID: "p", sessionID: "s", itemID: "q_1")
        XCTAssertEqual(removal, .accepted)
        XCTAssertEqual(removed.requests[0].url?.path, "/v1/queue/remove")
        XCTAssertEqual(try json(removed.requests[0])["itemId"] as? String, "q_1")

        let rewound = ContractTransport(body: #"{"rewound":true}"#, status: 200)
        let rewind = try await makeClient(rewound).rewind(projectID: "p", sessionID: "s", messageID: "msg_1")
        XCTAssertEqual(rewind, .accepted)
        XCTAssertEqual(rewound.requests[0].url?.path, "/v1/messages/rewind")
        XCTAssertEqual(try json(rewound.requests[0])["messageId"] as? String, "msg_1")

        let busy = ContractTransport(body: #"{"error":{"code":"agent_busy","message":"The Mac agent is still working"}}"#, status: 409)
        let refused = try await makeClient(busy).rewind(projectID: "p", sessionID: "s", messageID: "msg_1")
        XCTAssertEqual(refused, .failed(.server(code: "agent_busy", message: "The Mac agent is still working")))

        let restored = ContractTransport(body: #"{"restored":true}"#, status: 200)
        let restore = try await makeClient(restored).restoreRewind(projectID: "p", sessionID: "s")
        XCTAssertEqual(restore, .accepted)
        XCTAssertEqual(restored.requests[0].url?.path, "/v1/messages/restore")

        let listed = ContractTransport(body: #"{"items":[{"id":"q_1","text":"next","createdAt":"2026-09-23T22:00:00Z","status":"failed","error":"Could not start"}]}"#, status: 200)
        let items = try await makeClient(listed).queue(projectID: "p", sessionID: "s")
        XCTAssertEqual(items.first?.status, .failed)
        XCTAssertEqual(items.first?.error, "Could not start")
        XCTAssertEqual(listed.requests[0].url?.path, "/v1/queue")
    }

    private func makeClient(_ transport: ContractTransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

private final class ContractTransport: APITransport, @unchecked Sendable {
    private let result: Result<(Data, Int), Error>
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    init(body: String, status: Int) { result = .success((Data(body.utf8), status)) }
    init(error: Error) { result = .failure(error) }
    var requests: [URLRequest] { lock.withLock { storage } }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storage.append(request) }
        let (data, status) = try result.get()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
