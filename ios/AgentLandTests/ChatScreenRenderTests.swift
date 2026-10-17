import XCTest
import SwiftUI
import UIKit
import AgentLandCore
import AgentLandChat

/// A host double for the chat screen: one scripted event stream and fixed
/// answers for the other routes.
private final class RenderHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]
    private var open: AsyncThrowingStream<String, Error>.Continuation?
    init(lines: [String]) { self.lines = lines }

    func push(_ line: String) { _ = lock.withLock { open }?.yield(line) }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url?.path {
        case "/v1/chat/options":
            body = #"{"models":[{"id":"agentland-test/fixture-model","name":"Deterministic Local Model","provider":"AgentLand Local Fixture","contextWindow":8192}],"defaultModel":"agentland-test/fixture-model","agents":["build","plan"]}"#
        default:
            body = #"{"accepted":true}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let script = lock.withLock { () -> [String] in
            open = continuation
            defer { lines = [] }
            return lines
        }
        for line in script { continuation.yield(line) }
        return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Renders the shared ChatScreen at phone and tablet sizes, in light and
/// dark, with the states a person sees: a streaming reply, tool rows, an
/// approval card. With `AGENTLAND_RENDER_DIR` set, the images are written
/// there as evidence.
@MainActor final class ChatScreenRenderTests: XCTestCase {
    private static let ready = #"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#
    private static let conversation = #"""
    {"seq":0,"type":"snapshot","chat":{"id":"ses_render","title":"Fix login redirect","provider":"opencode","model":"agentland-test/fixture-model","mode":"build"},"messages":[
     {"id":"u1","role":"user","turnId":"u1","ord":1,"createdAt":"2026-09-24T09:41:00.000Z","parts":[{"id":"u1p","kind":"text","text":"Why does /login loop after I sign in?"}]},
     {"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","createdAt":"2026-09-24T09:41:01.000Z","completedAt":"2026-09-24T09:41:20.000Z","model":"agentland-test/fixture-model","parts":[
       {"id":"a1r","kind":"reasoning","ord":1,"text":"The cookie is written after the redirect.","start":"2026-09-24T09:41:01.000Z","end":"2026-09-24T09:41:13.000Z"},
       {"id":"a1t1","kind":"tool","ord":2,"tool":{"name":"read","status":"completed","input":"{\"filePath\":\"/p/Sources/LoginView.swift\"}","output":"struct LoginView {}"}},
       {"id":"a1t2","kind":"tool","ord":3,"tool":{"name":"bash","status":"completed","input":"{\"command\":\"npm test\"}","output":"12 passing"}},
       {"id":"a1x","kind":"text","ord":4,"text":"The redirect loops because the **session cookie** is set after the redirect response.\n\n```swift\nresponse.setCookie(session)\nreturn redirect(to: next)\n```\n\nMove `setCookie` before the redirect."}]},
     {"id":"u2","role":"user","turnId":"u2","ord":3,"createdAt":"2026-09-24T09:42:00.000Z","parts":[{"id":"u2p","kind":"text","text":"Please apply the fix and run the tests."}]},
     {"id":"a2","role":"assistant","turnId":"u2","ord":4,"status":"streaming","createdAt":"2026-09-24T09:42:01.000Z","parts":[
       {"id":"a2t","kind":"tool","ord":1,"start":"2026-09-24T09:42:02.000Z","tool":{"name":"bash","status":"running","input":"{\"command\":\"npm test -- --watch=false\"}"}},
       {"id":"a2x","kind":"text","ord":2,"text":"I moved the cookie before the redirect and I am running the"}]}
    ],"hasMore":false,"status":{"state":"waiting"},"interactions":[
     {"id":"per_render","chatId":"ses_render","kind":"permission","createdAt":"2026-09-24T09:42:03.000Z","choices":["once","reject"],"permission":{"tool":"bash","title":"npm test -- --watch=false","detail":"","input":"{\"command\":\"npm test -- --watch=false\"}"}}
    ],"queue":[]}
    """#.replacingOccurrences(of: "\n", with: "")

    private func makeStore(_ lines: [String]) throws -> (ChatSessionStore, RenderHost) {
        let host = RenderHost(lines: lines)
        let client = APIClient(address: try ServerAddress(validating: "https://render.example"), token: "t", transport: host)
        let store = ChatSessionStore(identity: .init(hostID: "render", projectID: "fixture", sessionID: "ses_render", tabID: UUID()))
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode", "claude", "codex"],
                                                chatFeatures: ["reasoning", "attachments", "queue", "rewind", "events", "parts", "stop", "continue", "clientMessageId"],
                                                chatProviderInfo: ["opencode": ChatProviderInfo(transport: "sse", features: ["rewind", "restoreFiles", "approvals", "questions"])])
        store.update(.init(client: client, capabilities: capabilities, reachable: true, connectionEpoch: 0, active: true, refreshGeneration: nil))
        return (store, host)
    }

    private func settle(_ condition: () -> Bool, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Hosts the screen in a window of the given size and appearance, lets it
    /// lay out, and returns the rendered image and the window.
    private func render(_ store: ChatSessionStore, size: CGSize, style: UIUserInterfaceStyle, regular: Bool,
                        name: String) async throws -> (UIImage, UIWindow) {
        let screen = ChatScreen(store: store, inputEnabled: true) { EmptyView() }
        let controller = UIHostingController(rootView: screen)
        controller.overrideUserInterfaceStyle = style
        controller.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        try await Task.sleep(for: .milliseconds(900))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"], let data = image.pngData() {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        return (image, window)
    }

    func testTranscriptRendersOnPhoneAndTabletInBothAppearances() async throws {
        let (store, host) = try makeStore([Self.ready, Self.conversation])
        await settle { store.hasContent && store.isResolved(for: nil) }
        XCTAssertEqual(store.projection.rows.count, 4)
        for (name, size, regular) in [("iphone", CGSize(width: 402, height: 874), false), ("ipad", CGSize(width: 1032, height: 1376), true)] {
            for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                let (image, window) = try await render(store, size: size, style: style, regular: regular, name: "chat-render-\(name)-\(appearance)")
                XCTAssertEqual(image.size, size, "\(name) \(appearance) renders at its window size")
                window.isHidden = true
            }
        }
        // A delta grows only the streaming text.
        host.push(#"{"seq":1,"type":"part.delta","messageId":"a2","partId":"a2x","field":"text","offset":59,"delta":" tests now."}"#)
        await settle { store.projection.message("a2")?.part("a2x")?.text.hasSuffix("tests now.") == true }
        XCTAssertEqual(store.projection.message("a2")?.part("a2x")?.text, "I moved the cookie before the redirect and I am running the tests now.")
    }

    /// Changing the text size while the chat is open scales every row and
    /// never moves the column sideways.
    func testTextSizeChangesKeepTheColumnInPlace() async throws {
        let (store, host) = try makeStore([Self.ready, Self.conversation])
        await settle { store.hasContent && store.isResolved(for: nil) }
        let (_, window) = try await render(store, size: CGSize(width: 402, height: 874), style: .light, regular: false, name: "chat-render-size-before")
        let controller = try XCTUnwrap(window.rootViewController)
        // Streaming activity keeps the transcript scrolled to its latest row.
        host.push(#"{"seq":1,"type":"part.delta","messageId":"a2","partId":"a2x","field":"text","offset":59,"delta":" tests now."}"#)
        await settle { store.projection.message("a2")?.part("a2x")?.text.hasSuffix("tests now.") == true }
        try await Task.sleep(for: .milliseconds(500))
        func transcript() -> UIScrollView? {
            var found: [UIScrollView] = []
            func walk(_ view: UIView) {
                if let scroll = view as? UIScrollView { found.append(scroll) }
                view.subviews.forEach(walk)
            }
            walk(window)
            return found.max { $0.bounds.height < $1.bounds.height }
        }
        let resting = try XCTUnwrap(transcript()).contentOffset.x
        var heights: [UIContentSizeCategory: CGFloat] = [:]
        for category in [UIContentSizeCategory.accessibilityExtraExtraExtraLarge, .extraSmall, .large] {
            controller.traitOverrides.preferredContentSizeCategory = category
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(700))
            let scroll = try XCTUnwrap(transcript())
            XCTAssertEqual(scroll.contentOffset.x, resting, accuracy: 0.5, "After \(category.rawValue) the column stays in place")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 0.5, "No sideways scrolling range")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"], let data = image.pngData() {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("chat-render-size-\(category.rawValue).png"))
            }
            XCTAssertTrue(try marginsAreEmpty(image), "After \(category.rawValue) nothing is drawn in the margins beside the column")
            heights[category] = scroll.contentSize.height
        }
        // Every row scales: the transcript is several times taller at the largest size.
        let largest = try XCTUnwrap(heights[.accessibilityExtraExtraExtraLarge]), standard = try XCTUnwrap(heights[.large])
        XCTAssertGreaterThan(largest, standard * 2.5, "Transcript text follows the text size: \(heights)")
        window.isHidden = true
    }

    /// True when the 10 pt strips at both sides of the transcript (the middle
    /// of the screen, clear of header and composer) hold only the background.
    private func marginsAreEmpty(_ image: UIImage) throws -> Bool {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = CGFloat(width) / image.size.width
        let strip = Int(10 * scale)
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
        }
        let reference = pixel(1, height * 2 / 5)
        for y in stride(from: height * 2 / 5, to: height * 7 / 10, by: 2) {
            for x in Array(0..<strip) + Array((width - strip)..<width) {
                let value = pixel(x, y)
                if abs(value.0 - reference.0) > 6 || abs(value.1 - reference.1) > 6 || abs(value.2 - reference.2) > 6 { return false }
            }
        }
        return true
    }

    /// The path a new chat takes: empty with the landing over the composer,
    /// the composer in use, then the first exchange arriving over the stream.
    func testRowsAppearInAChatThatStartedEmpty() async throws {
        let empty = #"{"seq":0,"type":"snapshot","chat":{"id":"ses_render","title":"New chat","provider":"opencode"},"messages":null,"hasMore":false,"status":{"state":"idle"},"interactions":[],"queue":[]}"#
        let (store, host) = try makeStore([Self.ready, empty])
        await settle { store.isResolved(for: nil) }
        XCTAssertTrue(store.showsLanding)
        store.requestComposerFocus()
        for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let (_, window) = try await render(store, size: CGSize(width: 402, height: 874), style: style, regular: false,
                                               name: "chat-render-new-empty-\(appearance)")
            window.isHidden = true
        }
        for line in [
            #"{"seq":1,"type":"message.created","message":{"id":"u1","chatId":"ses_render","turnId":"u1","role":"user","status":"complete","ord":1,"createdAt":"2026-09-24T09:41:00.000Z","provider":"opencode","parts":[]}}"#,
            #"{"seq":2,"type":"part.created","messageId":"u1","part":{"id":"u1p","kind":"text","ord":1,"text":"AGENTLAND_STREAM show the reply as it streams"}}"#,
            #"{"seq":3,"type":"turn.started","turnId":"u1"}"#,
            #"{"seq":4,"type":"status","state":"running"}"#,
            #"{"seq":5,"type":"message.created","message":{"id":"a1","chatId":"ses_render","turnId":"u1","role":"assistant","status":"streaming","ord":2,"createdAt":"2026-09-24T09:41:01.000Z","provider":"opencode","parts":[]}}"#,
            #"{"seq":6,"type":"part.created","messageId":"a1","part":{"id":"a1x","kind":"text","ord":1}}"#,
            #"{"seq":7,"type":"part.delta","messageId":"a1","partId":"a1x","field":"text","offset":0,"delta":"Streaming reply from"}"#
        ] { host.push(line) }
        await settle { store.projection.message("a1")?.part("a1x")?.text == "Streaming reply from" }
        XCTAssertEqual(store.projection.rows.map(\.id), ["user-u1", "reply-u1"])
        for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let (_, window) = try await render(store, size: CGSize(width: 402, height: 874), style: style, regular: false,
                                               name: "chat-render-new-streaming-\(appearance)")
            window.isHidden = true
        }
    }
}
