#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import AgentLandCore
@testable import AgentLandChat

/// Renders the shared ChatScreen in a real AppKit window, as the Mac app
/// hosts it. With `AGENTLAND_RENDER_DIR` set, the images are written there.
@MainActor final class ChatScreenMacRenderTests: XCTestCase {
    static let conversation = #"""
    {"seq":0,"type":"snapshot","chat":{"id":"ses_mac","title":"Fix login redirect","provider":"opencode","model":"agentland-test/fixture-model","mode":"build"},"messages":[
     {"id":"u1","role":"user","turnId":"u1","ord":1,"createdAt":"2026-09-24T09:41:00.000Z","parts":[{"id":"u1p","kind":"text","text":"Why does /login loop after I sign in?"}]},
     {"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","createdAt":"2026-09-24T09:41:01.000Z","completedAt":"2026-09-24T09:41:20.000Z","parts":[
       {"id":"a1r","kind":"reasoning","ord":1,"text":"The cookie is written after the redirect.","start":"2026-09-24T09:41:01.000Z","end":"2026-09-24T09:41:13.000Z"},
       {"id":"a1t1","kind":"tool","ord":2,"tool":{"name":"read","status":"completed","input":"{\"filePath\":\"/p/Sources/LoginView.swift\"}"}},
       {"id":"a1t2","kind":"tool","ord":3,"tool":{"name":"bash","status":"completed","input":"{\"command\":\"npm test\"}","output":"12 passing"}},
       {"id":"a1x","kind":"text","ord":4,"text":"The redirect loops because the **session cookie** is set after the redirect response.\n\n```swift\nresponse.setCookie(session)\nreturn redirect(to: next)\n```\n\nMove `setCookie` before the redirect."}]},
     {"id":"u2","role":"user","turnId":"u2","ord":3,"createdAt":"2026-09-24T09:42:00.000Z","parts":[{"id":"u2p","kind":"text","text":"Please apply the fix and run the tests."}]},
     {"id":"a2","role":"assistant","turnId":"u2","ord":4,"status":"streaming","createdAt":"2026-09-24T09:42:01.000Z","parts":[
       {"id":"a2t","kind":"tool","ord":1,"tool":{"name":"bash","status":"running","input":"{\"command\":\"npm test -- --watch=false\"}"}},
       {"id":"a2x","kind":"text","ord":2,"text":"I moved the cookie before the redirect and I am running the tests"}]}
    ],"hasMore":false,"status":{"state":"waiting"},"interactions":[
     {"id":"per_mac","chatId":"ses_mac","kind":"permission","createdAt":"2026-09-24T09:42:03.000Z","choices":["once","always","reject"],"permission":{"tool":"bash","title":"npm test -- --watch=false","input":"{\"command\":\"npm test -- --watch=false\"}"}}
    ],"queue":[]}
    """#.replacingOccurrences(of: "\n", with: "")

    func testMacRenderOfTheSharedChatScreen() async throws {
        let host = ScriptedHost()
        host.enqueue([#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#, Self.conversation])
        let store = ChatSessionStore(identity: .init(hostID: "mac", projectID: "fixture", sessionID: "ses_mac", tabID: UUID()))
        let client = APIClient(address: try ServerAddress(validating: "https://mac.example"), token: "t", transport: host)
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
                                                chatFeatures: ["reasoning", "attachments", "queue", "rewind", "events", "parts", "stop", "continue", "clientMessageId"],
                                                chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind", "restoreFiles", "approvals"])])
        store.update(.init(client: client, capabilities: capabilities, reachable: true, connectionEpoch: 0, active: true, refreshGeneration: nil))
        let deadline = Date().addingTimeInterval(5)
        while !(store.hasContent && store.isResolved(for: nil)) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.hasContent)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: ChatScreen(store: store, inputEnabled: true) { EmptyView() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820), styleMask: [.titled, .closable, .resizable],
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
                let name = appearance == .aqua ? "mac-chat-light.png" : "mac-chat-dark.png"
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            window.orderOut(nil)
        }
    }
}
#endif
