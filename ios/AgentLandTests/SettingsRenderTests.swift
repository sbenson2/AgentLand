import XCTest
import SwiftUI
import UIKit
import AgentLandCore
import AgentLandDesign
import AgentLandWorkspace
@testable import AgentLand

/// A host with Chat (Claude Code and Codex in its workspaces) and a Chats space, from fixtures. Nothing reaches the network.
private final class SettingsFixtureHost: APITransport, @unchecked Sendable {
    static let capabilities = #"""
    {"interactions":true,"terminal":true,"chatProviders":["opencode"],
     "chatFeatures":["attachments","events","parts"],
     "plainChats":{"projectId":"chats","tools":["websearch","fetch","memory"],"searchProvider":"exa","instructionFiles":["~/AGENTS.md"]},
     "workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":["events"],
                       "auth":{"kind":"subscription","label":"Claude subscription"}}],
                       "unavailableProviders":[{"id":"codex","name":"Codex","tools":[],"features":[],
                       "auth":{"kind":"signedOut","label":"Not signed in","reason":"subscription_required",
                               "message":"Codex isn’t signed in. Sign in to Codex with your ChatGPT subscription (codex login)."}}]}}
    """#

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body): (Int, String) = switch request.url?.path {
        case "/v1/capabilities": (200, Self.capabilities)
        case "/v1/projects": (200, #"{"projects":[{"id":"p1","name":"Studio"}]}"#)
        case "/v1/memory":
            (200, #"{"enabled":true,"entries":[{"id":"mem_1","text":"Prefers metric units","createdAt":"2026-09-20T10:00:00.000Z","updatedAt":"2026-09-20T10:00:00.000Z"},{"id":"mem_2","text":"Lives in Porto and cycles to work most days","createdAt":"2026-09-25T10:00:00.000Z","updatedAt":"2026-09-26T08:00:00.000Z"}],"limits":{"maxEntries":50,"maxTotalChars":2000}}"#)
        case "/v1/chat/options":
            (200, #"{"models":[{"id":"anthropic/claude-sonnet-4-5","name":"Claude Sonnet 4.5","provider":"Anthropic"},{"id":"openai/gpt-5","name":"GPT-5","provider":"OpenAI"},{"id":"openai/gpt-5-mini","name":"GPT-5 mini","provider":"OpenAI"}],"defaultModel":"anthropic/claude-sonnet-4-5","agents":[]}"#)
        default: (404, #"{"error":{"code":"not_found","message":"Not found"}}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Every Settings page at the popover's width (360 pt) and the SE's (375 pt), in light and dark and at the largest
/// text size, with a long Mac name and a long Tailscale address. The images are attached to the result (and written
/// to `AGENTLAND_RENDER_DIR` when it is set), for review.
@MainActor final class SettingsRenderTests: XCTestCase {
    private var suite = ""

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private let host = SavedHost(address: "https://robins-mac-studio-in-the-back-office.local:9841", deviceID: "device",
                                 name: "Robin’s Mac Studio in the Back Office", mode: .direct,
                                 certificateSHA256: String(repeating: "ab", count: 32),
                                 routes: [HostRoute(kind: HostRoute.local, host: "robins-mac-studio-in-the-back-office.local", port: 9841)!,
                                          HostRoute(kind: HostRoute.tailscale, host: "robins-mac-studio-in-the-back-office.tail1a2b3c.ts.net",
                                                    addresses: ["100.101.102.103", "fd7a:115c:a1e0::1234:5678"], port: 9841)!],
                                 remoteAccess: RemoteAccessCapabilities(enabled: true, directAddresses: ["203.0.113.7:38842"]))

    private func model() async throws -> AppModel {
        suite = "settings-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let other = SavedHost(address: "https://home-mini.local:9841", deviceID: "device-2", name: "Home mini", mode: .direct, certificateSHA256: nil)
        let model = AppModel(defaults: defaults, deviceCopyRemover: { _ in })
        model.hosts = [host, other]
        model.selectedHost = host
        model.workspace.attach(hostID: host.id, identity: ConnectionIdentity(host: host.address, deviceID: host.deviceID),
                               client: APIClient(address: try ServerAddress(validating: host.address), token: "t", transport: SettingsFixtureHost()))
        model.workspace.hostName = host.name
        await model.workspace.refreshProjects()
        return model
    }

    func testEverySettingsPageRendersAtThePopoversAndTheSEsWidth() async throws {
        let model = try await model()
        XCTAssertTrue(model.workspace.offersPlainChats)
        let pages: [(String, String, AnyView)] = [
            ("root", "Settings", AnyView(SettingsView(onClose: {}))),
            ("connection", "Connection", AnyView(ConnectionSettingsView(onClose: {}))),
            ("appearance", "Appearance", AnyView(AppearanceSettingsPane())),
            ("chat", "Chat", AnyView(ChatSettingsPane(offersHaptics: true))),
            ("terminal", "Terminal", AnyView(TerminalSettingsPane(offersHaptics: true))),
            ("notifications", "Notifications", AnyView(NotificationsSettingsPane())),
            ("privacy", "Privacy & Security", AnyView(PrivacySecuritySettingsView())),
            ("about", "About AgentLand", AnyView(AboutSettingsPane()))
        ]
        for (name, title, page) in pages {
            for width in [360.0, 375.0] {
                for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                    try await render(model, page, title: title, name: "\(name)-\(Int(width))-\(appearance)", width: width, style: style)
                }
                try await render(model, page, title: title, name: "\(name)-\(Int(width))-largest", width: width, style: .light,
                                 typeSize: .accessibility5)
            }
        }
        // The terminal with its own size chosen, and Chat's model list.
        UserDefaults(suiteName: suite)?.set(18.0, forKey: TerminalSettings.fontSizeKey)
        try await render(model, AnyView(TerminalSettingsPane(offersHaptics: true).defaultAppStorage(UserDefaults(suiteName: suite)!)),
                         title: "Terminal", name: "terminal-chosen-size-360-light", width: 360, style: .light)
    }

    private func render(_ model: AppModel, _ page: AnyView, title: String, name: String, width: CGFloat, style: UIUserInterfaceStyle,
                        typeSize: DynamicTypeSize = .large) async throws {
        let content = NavigationStack { page.workspaceSettingsPage(title) }
            .environment(model)
            .environment(model.workspace)
            .environment(\.dynamicTypeSize, typeSize)
        let controller = UIHostingController(rootView: content)
        controller.overrideUserInterfaceStyle = style
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: typeSize.isAccessibilitySize ? 2600 : 1400)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(700))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.height, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = "settings-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"], let data = image.pngData() {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-" + name + ".png"))
        }
    }
}
