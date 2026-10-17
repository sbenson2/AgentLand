import XCTest
import SwiftUI
import UIKit
import AgentLandCore
import AgentLandChat
import AgentLandWorkspace
@testable import AgentLand

/// A host with plain chats (docs/HOST-API.md "Plain chats"): its capabilities, the memory, and a plain chat's
/// stream from fixtures. Nothing reaches the network.
private final class FixturePlainChatsHost: APITransport, @unchecked Sendable {
    static let capabilities = #"""
    {"interactions":true,"terminal":true,"chatProviders":["opencode","claude"],
     "chatFeatures":["reasoning","attachments","queue","rewind","events","parts","stop","regenerate","continue","clientMessageId"],
     "chatProviderInfo":{"opencode":{"transport":"sse","features":["rewind","restoreFiles","approvals"]}},
     "plainChats":{"projectId":"chats","tools":["websearch","fetch","memory"],"searchProvider":"exa",
                   "instructionFiles":["~/AGENTS.md"]}}
    """#

    static let memory = #"""
    {"enabled":true,"entries":[
      {"id":"mem_1","text":"Prefers metric units","createdAt":"2026-09-20T10:00:00.000Z","updatedAt":"2026-09-20T10:00:00.000Z"},
      {"id":"mem_2","text":"Lives in Porto and cycles to work most days, so weather questions are about Porto","createdAt":"2026-09-25T10:00:00.000Z","updatedAt":"2026-09-26T08:00:00.000Z"},
      {"id":"mem_3","text":"Vegetarian","createdAt":"2026-09-27T09:00:00.000Z","updatedAt":"2026-09-27T09:00:00.000Z"}],
     "limits":{"maxEntries":50,"maxTotalChars":2000}}
    """#

    private let lock = NSLock()
    private var memoryBody = FixturePlainChatsHost.memory
    func setMemory(_ body: String) { lock.withLock { memoryBody = body } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body): (Int, String) = switch request.url?.path {
        case "/v1/capabilities": (200, Self.capabilities)
        case "/v1/projects": (200, #"{"projects":[{"id":"p1","name":"Studio"}]}"#)
        case "/v1/memory": (200, lock.withLock { memoryBody })
        case "/v1/chat/options":
            (200, #"{"models":[{"id":"anthropic/sonnet","name":"Sonnet","provider":"Anthropic"}],"defaultModel":"anthropic/sonnet","agents":[]}"#)
        default: (404, #"{"error":{"code":"not_found","message":"Not found"}}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    static let turn = #"""
    [{"id":"u1","role":"user","turnId":"u1","ord":1,"createdAt":"2026-09-27T09:41:00.000Z","parts":[{"id":"u1p","kind":"text","text":"When is high tide in Lisbon tomorrow? And I use metric."}]},
     {"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","createdAt":"2026-09-27T09:41:01.000Z","completedAt":"2026-09-27T09:41:20.000Z","parts":[
       {"id":"a1s","kind":"tool","ord":1,"tool":{"name":"websearch","status":"completed","title":"tide times lisbon","input":"{\"query\":\"tide times lisbon\"}","sources":[{"title":"Lisbon tide table","url":"https://tides.example.com/lisbon"},{"title":"Tagus estuary tides, week ahead","url":"https://example.org/tides"}]}},
       {"id":"a1f","kind":"tool","ord":2,"tool":{"name":"agentland_fetch","status":"completed","input":"{\"url\":\"https://tides.example.com/lisbon\"}","sources":[{"title":"Lisbon tide table","url":"https://www.tides.example.com/lisbon"}]}},
       {"id":"a1m","kind":"tool","ord":3,"tool":{"name":"agentland_memory_save","status":"completed","input":"{\"text\":\"Prefers metric units\"}","memory":{"id":"mem_1","text":"Prefers metric units"}}},
       {"id":"a1x","kind":"text","ord":4,"text":"High tide in Lisbon tomorrow is at **14:02**, about 3.4 m."}]}]
    """#.replacingOccurrences(of: "\n", with: "")

    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#)
        continuation.yield(#"{"seq":0,"type":"snapshot","chat":{"id":"ses_plain","title":"Tides in Lisbon","provider":"opencode"},"messages":\#(Self.turn),"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#)
        return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A plain chat's cards, rendered in the app with a fixture host, in light and dark and at an accessibility text size.
/// iPhone and iPad have no Memory or Chat Tools page since 2026-10-12 (owner: memory "dont need"). With `AGENTLAND_RENDER_DIR` set, the images are written there.
@MainActor final class PlainChatRenderTests: XCTestCase {
    private var suite = ""

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func workspace(_ host: FixturePlainChatsHost) async throws -> WorkspaceModel {
        suite = "plain-chat-render-\(UUID())"
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: "https://studio.local:9841|device", identity: ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device"),
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "t", transport: host))
        workspace.hostName = "Studio Mac"
        await workspace.refreshProjects()
        return workspace
    }

    /// A plain chat's cards on iPhone: a search with its pages, a page read, and a memory save with Undo.
    func testAPlainChatsCardsRender() async throws {
        let host = FixturePlainChatsHost()
        let workspace = try await workspace(host)
        let store = ChatSessionStore(identity: .init(hostID: "render", projectID: "chats", sessionID: "ses_plain", tabID: UUID()))
        store.update(.init(client: workspace.client, capabilities: workspace.capabilities, reachable: true, connectionEpoch: 0, active: true,
                           refreshGeneration: nil))
        let deadline = Date().addingTimeInterval(5)
        while !store.isResolved(for: nil) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.projection.rows.map(\.id), ["user-u1", "reply-u1"])
        XCTAssertTrue(store.offersMemoryUndo)
        for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let screen = ChatScreen(store: store, inputEnabled: true) { EmptyView() }
            try await render(workspace, screen, name: "plain-chat-cards-\(appearance)", style: style, height: 874)
        }
        store.shutdown()
    }

    private func render(_ workspace: WorkspaceModel, _ content: some View, name: String, style: UIUserInterfaceStyle,
                        height: CGFloat = 1300) async throws {
        let controller = UIHostingController(rootView: content.environment(workspace))
        controller.overrideUserInterfaceStyle = style
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        // The pane reads the memory when it shows.
        try await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.height, 0)
        if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"], let data = image.pngData() {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
