import XCTest
import SwiftUI
import UIKit
import AgentLandCore
import AgentLandWorkspace
@testable import AgentLand

/// A host that answers the agent catalog's routes from fixtures: every state an agent can be in, icons
/// drawn for these tests (no registry artwork), and the providers. Nothing reaches the network.
private final class FixtureAgentsHost: APITransport, @unchecked Sendable {
    static let capabilities = #"""
    {"interactions":true,"terminal":true,"terminalPrograms":["shell","opencode","claude","gemini"],
     "chatProviders":["opencode","claude","gemini"],"agents":["catalog","install","acp","updateSettings"],
     "agentCatalog":[{"id":"opencode","name":"OpenCode","chat":true,"terminal":true},{"id":"claude","name":"Claude Code","chat":true,"terminal":true},
                     {"id":"gemini","name":"Gemini CLI","chat":true,"terminal":true}]}
    """#

    static let catalog = #"""
    {"automaticUpdates":false,"registry":{"fetchedAt":"2026-09-26T20:00:00Z"},
     "agents":[
      {"id":"opencode","name":"OpenCode","source":"registry","supportsUpdates":true,"autoUpdates":false,"state":"installed","installedVersion":"1.18.32","latestVersion":"1.18.33",
       "updatedAt":"2026-09-27T04:09:42Z","license":"MIT","chat":true,"terminal":true,"verified":true},
      {"id":"claude","name":"Claude Code","source":"local","state":"installed","installedVersion":"2.1.280","autoUpdates":false,"supportsUpdates":true,"chat":true,"terminal":true,"verified":true},
      {"id":"codex","name":"Codex","source":"local","state":"notInstalled","chat":false,"terminal":false,"verified":true},
      {"id":"gemini","name":"Gemini CLI","source":"registry","supportsUpdates":true,"autoUpdates":false,"state":"installed","installedVersion":"0.61.0","latestVersion":"0.62.0",
       "updatedAt":"2026-09-26T08:00:00Z","license":"Apache-2.0","chat":true,"terminal":true,"verified":true},
      {"id":"goose","name":"Goose","source":"registry","state":"updating","installedVersion":"1.9.0","latestVersion":"1.10.0",
       "license":"Apache-2.0","chat":true,"terminal":true,"verified":true},
      {"id":"qwen","name":"Qwen Code","source":"registry","supportsUpdates":true,"autoUpdates":false,"state":"installed","installedVersion":"0.4.0","latestVersion":"0.5.0",
       "lastError":"The new version did not answer initialize.","license":"Apache-2.0","chat":true,"terminal":true,"verified":true},
      {"id":"factory-droid","name":"Factory Droid","source":"registry","state":"uninstalling","installedVersion":"0.22.0",
       "license":"Proprietary","chat":true,"terminal":true,"verified":true},
      {"id":"amp","name":"Amp","description":"A coding agent for your terminal and editor.","source":"registry","state":"installing",
       "license":"Proprietary","chat":true,"terminal":true,"verified":true},
      {"id":"cursor","name":"Cursor","description":"Cursor's agent on the command line.","website":"https://www.cursor.com/cli",
       "source":"registry","state":"notInstalled","license":"Proprietary","chat":true,"terminal":true,"verified":false},
      {"id":"kimi","name":"Kimi CLI","description":"An agent that reads and edits your project, asks before it runs commands, and keeps a plan of what it is doing.",
       "source":"registry","state":"failed","lastError":"uv was not found on the Mac.","license":"MIT","chat":true,"terminal":true,"verified":true},
      {"id":"zed-agent","name":"Zed Agent","description":"Builds only for Linux and Windows.","source":"registry","state":"notInstalled",
       "license":"Apache-2.0","chat":true,"terminal":false,"verified":false,"supported":false}
     ]}
    """#

    static let providers = #"""
    {"providers":[{"id":"anthropic","name":"Anthropic","connected":true,"models":12,"env":["ANTHROPIC_API_KEY"]},
                  {"id":"deepseek","name":"DeepSeek","connected":true,"models":2},
                  {"id":"openrouter","name":"OpenRouter","connected":false,"models":150},
                  {"id":"ollama","name":"Ollama","connected":false,"models":0},
                  {"id":"openai","name":"OpenAI","connected":false,"models":40}]}
    """#

    /// Simple shapes in the registry's style: one color, `currentColor`.
    static func icon(_ id: String) -> String? {
        switch id {
        case "gemini": #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="currentColor" d="M12 1l3 8 8 3-8 3-3 8-3-8-8-3 8-3z"/></svg>"#
        case "goose": #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><rect x="8" y="8" width="8" height="8" rx="2" fill="currentColor"/></svg>"#
        case "cursor": #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill-rule="evenodd" fill="currentColor" d="M13 14H3V2h10zM10.5 4.4h-5v7.2h5z"/></svg>"#
        case "amp": #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="currentColor" d="M4 20a8 8 0 0 1 16 0h-4a4 4 0 0 0-8 0z"/></svg>"#
        default: nil
        }
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let (status, body): (Int, String) = switch request.url?.path {
        case "/v1/capabilities": (200, Self.capabilities)
        case "/v1/projects": (200, #"{"projects":[{"id":"p1","name":"Studio"}]}"#)
        case "/v1/agents": (200, Self.catalog)
        case "/v1/agents/icon":
            Self.icon(query.first { $0.name == "id" }?.value ?? "").map { (200, $0) }
                ?? (404, #"{"error":{"code":"not_found","message":"No icon."}}"#)
        case "/v1/providers": (200, Self.providers)
        default: (404, #"{"error":{"code":"not_found","message":"Not found"}}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Settings → Agents and AI Providers rendered in the app with a fixture host, in light and dark and at an
/// accessibility text size. With `AGENTLAND_RENDER_DIR` set, the images are written there.
@MainActor final class AgentsSettingsRenderTests: XCTestCase {
    private var suite = ""

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func workspace() async throws -> WorkspaceModel {
        suite = "agents-render-\(UUID())"
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: "https://studio.local:9841|device", identity: ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device"),
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "t",
                                           transport: FixtureAgentsHost()))
        workspace.hostName = "Studio Mac"
        await workspace.refreshProjects()
        return workspace
    }

    func testTheAgentsPaneRendersEveryState() async throws {
        let workspace = try await workspace()
        XCTAssertTrue(workspace.agents.isAvailable)
        await workspace.agents.refresh()
        XCTAssertTrue(workspace.agents.canConfigureAutomaticUpdates)
        XCTAssertEqual(workspace.agents.automaticUpdates, false)
        XCTAssertEqual(workspace.agents.installed.map(\.id), ["claude", "factory-droid", "gemini", "goose", "opencode", "qwen"])
        XCTAssertEqual(workspace.agents.agent("factory-droid")?.state, .uninstalling, "Shown as uninstalling, with its progress")
        XCTAssertEqual(workspace.agents.agent("opencode")?.isManaged, true, "OpenCode as a registry agent, as hosts list it")
        XCTAssertEqual(workspace.agents.agent("opencode")?.canUninstall, false, "Update Now only: AgentLand's chats need it")
        XCTAssertEqual(workspace.agents.agent("claude")?.canUpdate, true, "The host supports its native self-updater")
        XCTAssertEqual(workspace.agents.agent("claude")?.canUninstall, false, "Its installation remains local")
        XCTAssertEqual(workspace.agents.available.map(\.id), ["amp", "cursor", "kimi", "zed-agent"])
        XCTAssertEqual(workspace.agents.agent("zed-agent")?.supported, false, "Shown as not available for this Mac, without Install")
        try await render(workspace, AgentsSettingsPane(), name: "agents-light", style: .light)
        guard case .vector? = workspace.agents.icons.icon(for: "gemini") else { return XCTFail("The host's icon is drawn") }
        guard case .missing? = workspace.agents.icons.icon(for: "claude") else { return XCTFail("Without an icon, the initial") }
        try await render(workspace, AgentsSettingsPane(), name: "agents-dark", style: .dark)
        try await render(workspace, AgentsSettingsPane().environment(\.dynamicTypeSize, .accessibility3), name: "agents-ax3", style: .light)
        workspace.agents.search = "project"
        try await render(workspace, AgentsSettingsPane(), name: "agents-search", style: .light)
        workspace.agents.search = "zz-none"
        try await render(workspace, AgentsSettingsPane(), name: "agents-search-empty", style: .light)
        workspace.agents.search = ""
        workspace.reachable = false
        try await render(workspace, AgentsSettingsPane(), name: "agents-offline", style: .light)
    }

    func testTheProvidersPaneRenders() async throws {
        let workspace = try await workspace()
        XCTAssertTrue(workspace.aiProviders.isAvailable)
        try await render(workspace, AIProvidersSettingsPane(), name: "providers-light", style: .light)
        XCTAssertEqual(workspace.aiProviders.connected.map(\.name), ["Anthropic", "DeepSeek"])
        try await render(workspace, AIProvidersSettingsPane(), name: "providers-dark", style: .dark)
        try await render(workspace, AIProvidersSettingsPane().environment(\.dynamicTypeSize, .accessibility3), name: "providers-ax3", style: .light)
    }

    private func render(_ workspace: WorkspaceModel, _ content: some View, name: String, style: UIUserInterfaceStyle) async throws {
        // In a navigation stack, as Settings shows it: the Agents page's search field is the system's, in its bar.
        let controller = UIHostingController(rootView: NavigationStack { content }.environment(workspace))
        controller.overrideUserInterfaceStyle = style
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 1300)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        // The pane reads the list and its icons when it shows.
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
