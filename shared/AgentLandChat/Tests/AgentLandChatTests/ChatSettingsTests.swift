import XCTest
import AgentLandCore
@testable import AgentLandChat

/// Settings → Chat: long pastes as attachments and tool details that start open. Their defaults keep the chat as
/// it was.
@MainActor
final class ChatSettingsTests: XCTestCase {
    private let identity = ChatSessionStore.Identity(hostID: "h", projectID: "p", sessionID: "s", tabID: UUID())
    private let withAttachments = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"], chatFeatures: ["attachments", "events", "parts"])

    private func makeStore(capabilities: CapabilitiesResponse) throws -> (ChatSessionStore, ScriptedHost) {
        let host = ScriptedHost { request in
            switch request.url?.path {
            case "/v1/attachments": return (201, #"{"id":"att_1","name":"Pasted text.txt","mime":"text/plain","size":10}"#)
            default: return try ScriptedHost.defaultResponder(request)
            }
        }
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "t", transport: host)
        let store = ChatSessionStore(identity: identity, draft: "Look at this: ")
        store.update(ChatSessionStore.Environment(client: client, capabilities: capabilities, reachable: true, connectionEpoch: 0,
                                                  active: false, refreshGeneration: nil))
        return (store, host)
    }

    private static let log = (1...20).map { "line \($0) of the build log" }.joined(separator: "\n")

    func testDefaultsKeepTheChatAsItWas() {
        XCTAssertFalse(ChatSettings.expandDetailsDefault)
        XCTAssertTrue(ChatSettings.sendHapticDefault)
        XCTAssertFalse(ChatSettings.longPasteAsFileDefault)
    }

    func testALongPasteBecomesATextFileWhenTheSettingIsOn() throws {
        let (store, _) = try makeStore(capabilities: withAttachments)
        store.editDraft("Look at this: " + Self.log, longPastesAsFiles: true)
        XCTAssertEqual(store.draft, "Look at this: ", "the draft keeps what was typed")
        XCTAssertEqual(store.attachments.items.map(\.name), [ChatLongPaste.fileName])

        // Typing goes on as usual.
        store.editDraft("Look at this: x", longPastesAsFiles: true)
        XCTAssertEqual(store.draft, "Look at this: x")
        XCTAssertEqual(store.attachments.items.count, 1)
    }

    func testShortPastesTheSettingOffAndHostsWithoutAttachmentsKeepTheText() throws {
        let (store, _) = try makeStore(capabilities: withAttachments)
        store.editDraft("Look at this: two\nlines", longPastesAsFiles: true)
        XCTAssertEqual(store.draft, "Look at this: two\nlines", "a short paste stays in the message")
        store.editDraft("Look at this: two\nlines" + Self.log, longPastesAsFiles: false)
        XCTAssertTrue(store.draft.hasSuffix(Self.log), "off: the paste goes into the message")
        XCTAssertTrue(store.attachments.items.isEmpty)

        let (plain, _) = try makeStore(capabilities: CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"], chatFeatures: ["events"]))
        plain.editDraft("Look at this: " + Self.log, longPastesAsFiles: true)
        XCTAssertTrue(plain.draft.hasSuffix(Self.log), "a host that takes no attachments keeps it in the message")
        XCTAssertTrue(plain.attachments.items.isEmpty)
    }

    func testTheThresholdIsALongMessage() {
        XCTAssertFalse(ChatLongPaste.isLong((1...12).map(String.init).joined(separator: "\n")), "12 lines show in full")
        XCTAssertTrue(ChatLongPaste.isLong((1...13).map(String.init).joined(separator: "\n")), "13 lines collapse")
        XCTAssertFalse(ChatLongPaste.isLong(String(repeating: "a", count: 999)))
        XCTAssertTrue(ChatLongPaste.isLong(String(repeating: "a", count: 1_000)))
    }

    func testTheInsertionIsWhatOneEditPutIn() {
        XCTAssertEqual(ChatLongPaste.insertion(from: "ab", to: "aXYb")?.inserted, "XY")
        XCTAssertEqual(ChatLongPaste.insertion(from: "ab", to: "aXYb")?.remainder, "ab")
        XCTAssertEqual(ChatLongPaste.insertion(from: "", to: "pasted")?.inserted, "pasted")
        XCTAssertEqual(ChatLongPaste.insertion(from: "aaa", to: "aaaa")?.inserted, "a")
        XCTAssertNil(ChatLongPaste.insertion(from: "abc", to: "ab"), "a deletion inserts nothing")
    }

    func testDetailsStartAsTheSettingSaysUntilToggled() {
        let store = ChatSessionStore(identity: identity)
        XCTAssertFalse(store.isExpanded("tool-1"), "closed by default")
        XCTAssertTrue(store.isExpanded("tool-1", byDefault: true), "open with Expand tool details")
        store.toggleExpanded("tool-1")
        XCTAssertTrue(store.isExpanded("tool-1"))
        XCTAssertFalse(store.isExpanded("tool-1", byDefault: true), "the person closed it")
        store.toggleExpanded("tool-1")
        XCTAssertTrue(store.isExpanded("tool-1", byDefault: true))
    }
}
