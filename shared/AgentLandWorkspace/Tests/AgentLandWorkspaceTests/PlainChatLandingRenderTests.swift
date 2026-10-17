#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandWorkspace

/// The empty plain chat as the Mac draws it: the tent and "What’s on your mind?" over the composer, dark on
/// slate. With `AGENTLAND_RENDER_DIR` set, the image is written there.
@MainActor final class PlainChatLandingRenderTests: XCTestCase {
    func testTheEmptyPlainChatRendersItsLandingOverTheComposer() async throws {
        _ = NSApplication.shared
        let host = ScriptedHost()
        host.on("/v1/chat/options") { _ in
            (200, #"{"models":[{"id":"anthropic/sonnet","name":"Sonnet","provider":"Anthropic"}],"defaultModel":"anthropic/sonnet","agents":[]}"#)
        }
        host.enqueueStream("ses_plain", [#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#,
                                         #"{"seq":0,"type":"snapshot","chat":{"id":"ses_plain","title":"New chat","provider":"opencode"},"messages":[],"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#])
        let store = ChatSessionStore(identity: .init(hostID: "mac", projectID: "chats", sessionID: "ses_plain", tabID: UUID()))
        let client = APIClient(address: try ServerAddress(validating: "https://mac.example"), token: "t", transport: host)
        store.update(.init(client: client, capabilities: CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["events", "parts"],
                                                                              plainChats: PlainChatsCapability(tools: [.websearch])),
                           reachable: true, connectionEpoch: 0, active: true, refreshGeneration: nil))
        let deadline = Date().addingTimeInterval(5)
        while !store.isResolved(for: nil) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.showsLanding)
        defer { store.shutdown() }

        let size = CGSize(width: 900, height: 820)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: "plain-landing-render-\(UUID())")))
        let screen = ChatScreen(store: store, inputEnabled: true) { PlainChatLanding(animated: false) }
            // As the chat tab shows it: dark on slate while the landing shows, anchored like the opening cover.
            .environment(\.colorScheme, .dark)
            .environment(workspace)
            .environment(\.agentLandArtwork, AgentLandArtworkLayout(windowFrame: CGRect(origin: .zero, size: size), referenceDate: .distantPast))
        try await render(screen, size: size, name: "mac-plain-chat-landing-tent")
    }

    private func render(_ content: some View, size: CGSize, name: String) async throws {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(900))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: representation)
        XCTAssertGreaterThan(representation.pixelsWide, 0)
        if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"],
           let png = representation.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
#endif
