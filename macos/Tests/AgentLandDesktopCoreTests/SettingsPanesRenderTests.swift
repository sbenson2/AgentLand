import AppKit
import SwiftUI
import XCTest
import AgentLandCore
import AgentLandWorkspace
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// Renders every Settings pane with fake data, in light and dark, at the window's width and the height the pane asks
/// for, for the owner's look check, and lists each pane's height in `heights.txt`. Does nothing unless
/// AGENTLAND_RENDER_DIR names a folder.
final class SettingsPanesRenderTests: XCTestCase {
    @MainActor
    func testRenderEveryPane() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"] else { throw XCTSkip("no render folder") }
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let now = Date()
        let feed = FakeTerminalsFeed(running: 1, terminals: [
            HostTerminal(id: "a", deviceId: "d1", deviceName: "Sam’s iPhone", workspace: "tower", program: "zsh",
                         title: "Build the app", status: "running", startedAt: now.addingTimeInterval(-2 * 3600 - 60)),
            HostTerminal(id: "b", deviceId: "d2", deviceName: "Robin’s iPad", workspace: "tower", program: "claude",
                         status: "ended", startedAt: now.addingTimeInterval(-5 * 3600), endedAt: now.addingTimeInterval(-3 * 3600 - 60))])
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60), terminals: feed)
        try await waitForCondition("running") { host.status == .running && !host.isWorking }

        let suite = "SettingsPanesRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceModel(defaults: defaults, keys: .desktop)
        model.capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"""
            {"interactions":true,"terminal":true,
             "projects":{"version":1,"features":["details","browse","create","add","rename","remove"]},
             "workspaceChats":{"version":1,
              "providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[],
                "auth":{"kind":"subscription","label":"Claude subscription"}}],
              "unavailableProviders":[{"id":"codex","name":"Codex","tools":[],"features":[],
                "auth":{"kind":"apiKey","label":"API key","reason":"subscription_required",
                        "message":"Codex is signed in with an API key. Sign in with your ChatGPT subscription (codex login)."}}]}}
            """#.utf8))
        model.projects = [Project(id: "tower", name: "tower", directory: NSHomeDirectory() + "/Developer/tower", gitRepository: true),
                          Project(id: "notes", name: "Notes", directory: NSHomeDirectory() + "/Documents/Notes")]

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var heights: [String] = []
        for pane in MacSettingsPane.allCases {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = NSHostingView(rootView: MacSettingsPaneView(pane: pane).macSettingsPane()
                    .background(.background)
                    .environmentObject(host)
                    .environment(model))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MacSettingsMetrics.paneWidth, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                try await Task.sleep(for: .milliseconds(500))
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                window.setContentSize(size)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory + "/settings-\(pane.rawValue)-\(name).png"))
                if name == "light" { heights.append("\(pane.title): \(Int(size.width)) × \(Int(size.height))") }
            }
        }
        try heights.joined(separator: "\n").write(toFile: directory + "/heights.txt", atomically: true, encoding: .utf8)
    }
}
