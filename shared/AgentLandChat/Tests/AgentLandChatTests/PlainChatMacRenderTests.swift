#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import AgentLandCore
@testable import AgentLandChat

/// A plain chat on the Mac, as the shared ChatScreen draws it: its tool cards (a search with its pages, a page read,
/// a memory save with Undo), and the empty chat's landing over the composer. With `AGENTLAND_RENDER_DIR` set, the
/// images are written there.
@MainActor final class PlainChatMacRenderTests: XCTestCase {
    private let capabilities = CapabilitiesResponse(
        interactions: true, terminal: true, chatProviders: ["opencode"],
        chatFeatures: ["reasoning", "attachments", "queue", "rewind", "events", "parts", "stop", "regenerate", "continue", "clientMessageId"],
        chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind", "restoreFiles", "approvals"])],
        plainChats: PlainChatsCapability(tools: [.websearch, .fetch, .memory], searchProvider: .exa))

    private func store(messages: String) async throws -> ChatSessionStore {
        let host = ScriptedHost { request in
            if request.url?.path == "/v1/chat/options" {
                return (200, #"{"models":[{"id":"anthropic/sonnet","name":"Sonnet","provider":"Anthropic"}],"defaultModel":"anthropic/sonnet","agents":[]}"#)
            }
            return try ScriptedHost.defaultResponder(request)
        }
        host.enqueue([#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#,
                      #"{"seq":0,"type":"snapshot","chat":{"id":"ses_plain","title":"Tides in Lisbon","provider":"opencode"},"messages":\#(messages),"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let store = ChatSessionStore(identity: .init(hostID: "mac", projectID: "chats", sessionID: "ses_plain", tabID: UUID()))
        let client = APIClient(address: try ServerAddress(validating: "https://mac.example"), token: "t", transport: host)
        store.update(.init(client: client, capabilities: capabilities, reachable: true, connectionEpoch: 0, active: true, refreshGeneration: nil))
        let deadline = Date().addingTimeInterval(5)
        while !store.isResolved(for: nil) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isResolved(for: nil))
        return store
    }

    private func render(_ store: ChatSessionStore, name: String) async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let screen = ChatScreen(store: store, inputEnabled: true) {
                Text("What’s on your mind?").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            let view = NSHostingView(rootView: screen)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 820), styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(900))
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("no bitmap") }
            view.cacheDisplay(in: view.bounds, to: representation)
            XCTAssertGreaterThan(representation.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"],
               let png = representation.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let file = name + (appearance == .aqua ? "-light.png" : "-dark.png")
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
            }
            window.orderOut(nil)
        }
    }

    func testTheCardsRenderInBothAppearances() async throws {
        let store = try await store(messages: PlainChatTests.turn)
        XCTAssertEqual(store.projection.rows.map(\.id), ["user-u1", "reply-u1"])
        try await render(store, name: "mac-plain-chat-cards")
    }

    func testTheEmptyChatShowsItsLandingOverTheComposer() async throws {
        let store = try await store(messages: "[]")
        XCTAssertTrue(store.showsLanding, "The screen keeps the composer under the landing")
        try await render(store, name: "mac-plain-chat-landing")
    }
}
#endif
