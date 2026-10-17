import AppKit
import SwiftUI
import XCTest
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// Renders the Terminals pane with fake data for the owner's look check. Does nothing unless
/// AGENTLAND_RENDER_DIR names a folder.
final class TerminalsPaneRenderTests: XCTestCase {
    @MainActor
    func testRenderThePane() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"] else { throw XCTSkip("no render folder") }
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let now = Date()
        let feed = FakeTerminalsFeed(running: 1, terminals: [
            HostTerminal(id: "a", deviceId: "d1", deviceName: "Sam’s iPhone", workspace: "tower", program: "zsh",
                         title: "Build the app", status: "running", startedAt: now.addingTimeInterval(-2 * 3600 - 60)),
            HostTerminal(id: "b", deviceId: "d2", deviceName: "Robin’s iPad", workspace: "tower", program: "claude",
                         status: "ended", startedAt: now.addingTimeInterval(-5 * 3600), endedAt: now.addingTimeInterval(-3 * 3600 - 60)),
            HostTerminal(id: "c", deviceId: "d3", deviceName: "Old iPhone", deviceRemoved: true, workspace: "tower",
                         program: "zsh", status: "running", startedAt: now.addingTimeInterval(-26 * 3600))])
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60), terminals: feed)
        try await waitForCondition("running") { host.status == .running && !host.isWorking }
        let follow = Task { await host.followTerminals() }
        try await waitForCondition("the list") { host.terminalList != nil }
        follow.cancel()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: TerminalsSettingsPane().environmentObject(host).frame(width: 640, height: 460))
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/terminals-pane-\(name).png"))
        }
    }
}
