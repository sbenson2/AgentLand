import Foundation
import XCTest
@testable import AgentLandCore

final class ChatOptionsTests: XCTestCase {
    func testProviderFailureIsReadableAlongsideOlderMessages() throws {
        let failure = try JSONDecoder().decode(ChatMessage.self, from: Data("{\"id\":\"m1\",\"role\":\"assistant\",\"text\":\"\",\"error\":\"Provider rejected the API key\"}".utf8))
        XCTAssertEqual(failure.error, "Provider rejected the API key")
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data("{\"id\":\"m0\",\"role\":\"assistant\",\"text\":\"hello\"}".utf8))
        XCTAssertNil(old.error)
        XCTAssertEqual(old.text, "hello")
    }
    func testPromptOptionsAreExplicitAndLegacyRequestsStayCompatible() async throws {
        let transport = PromptTransport()
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device", transport: transport)
        let legacy = await client.sendMessage(projectID: "p1", sessionID: "s1", text: "hello")
        XCTAssertEqual(legacy, .accepted)
        let selected = await client.sendMessage(projectID: "p1", sessionID: "s1", text: "review", model: "deepseek/chat", agent: "plan")
        XCTAssertEqual(selected, .accepted)
        let bodies = try transport.requests.map { try JSONDecoder().decode([String: String].self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(bodies[0], ["projectId": "p1", "sessionId": "s1", "text": "hello"])
        XCTAssertEqual(bodies[1]["model"], "deepseek/chat")
        XCTAssertEqual(bodies[1]["agent"], "plan")
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer device" })
    }

    func testChatPreferencesRoundTripAndOldTabsRemainReadable() throws {
        let legacy = Data("{\"id\":\"EB6F1155-16B3-4D28-8FD9-18E3D2733F32\",\"kind\":\"chat\",\"projectID\":\"p1\",\"resourceID\":\"s1\",\"title\":\"Chat\",\"draft\":\"keep this\"}".utf8)
        var tab = try JSONDecoder().decode(WorkspaceTab.self, from: legacy)
        XCTAssertNil(tab.chatModelID)
        XCTAssertNil(tab.chatAgent)
        XCTAssertNil(tab.chatModeConfirmed)
        tab.chatModelID = "deepseek/chat"
        tab.chatAgent = "plan"
        tab.chatModeConfirmed = true
        let restored = try JSONDecoder().decode(WorkspaceTab.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(restored, tab)
        XCTAssertEqual(restored.draft, "keep this")
    }
}

private final class PromptTransport: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        return (Data("{\"accepted\":true}".utf8), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
    }
}
