import AppKit
import SwiftUI
import AgentLandDesktopCore

/// Quick actions in the system menu; setup and detailed controls stay in windows.
struct MenuBarControls: View {
    @EnvironmentObject private var host: HostController
    @EnvironmentObject private var navigation: DesktopNavigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var menuOpen = false
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
        Text(statusText)
        // Getting OpenCode during a start (a menu holds no bar: the share is in the line), or why none is
        // available while the host runs without it.
        if let install = host.openCodeInstall {
            Text(install.menuTitle)
        } else if let unavailable = host.openCodeUnavailable {
            Text(Self.unavailableText(unavailable))
            Button("Try Again") { host.retryOpenCode() }
                .disabled(host.isWorking)
        }
        if host.errorMessage != nil { Text("Open Settings to see the error") }
        if host.status == .running {
            Text("Active devices")
            let names = host.devices.filter(\.isPresent).map(\.name)
            if names.isEmpty { Text("No active devices") }
            else {
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    Text(name)
                }
            }
        }
        Divider()

        if host.needsOnboarding {
            Button("Set Up AgentLand…", action: showSetup)
        } else {
            Button(host.status == .stopped ? "Start Server" : "Stop Server") {
                if host.status == .stopped { host.start() } else { host.stop() }
            }
            .disabled(host.isWorking)

            Button("Pair a Device…", action: openPairing)
                .disabled(host.status != .running || host.isWorking)
        }

        Divider()
        Button(host.isOpeningWeb ? "Opening AgentLand…" : "Open AgentLand") { host.openWebWorkspace() }
            .disabled(host.needsOnboarding || host.isOpeningWeb)
        Button("Settings…", action: showSettings)
        Divider()
        Button("Quit AgentLand Server") { HostController.shared.quitDeliberately() }
        }
        .onAppear {
            menuOpen = true
            if host.status == .running { host.refreshDevices(showActivity: false) }
        }
        .onDisappear { menuOpen = false }
        .onReceive(refreshTimer) { _ in
            if menuOpen && host.status == .running { host.refreshDevices(showActivity: false) }
        }
    }

    /// "OpenCode isn’t available: no network connection".
    static func unavailableText(_ unavailable: OpenCodeUnavailability) -> String {
        "OpenCode isn’t available: \(unavailable.shortReason)"
    }

    private var statusText: String {
        let name = host.projectName.isEmpty ? "Workspace" : host.projectName
        return switch host.status {
        case .running: "Connected to \(name)"
        case .starting: "Connecting to \(name)…"
        case .stopped: "Disconnected from \(name)"
        }
    }

    private func showSetup() {
        openWindow(id: SetupWindowView.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pairing can open without constructing a desktop workspace.
    private func openPairing() {
        host.createPairingCode()
        openWindow(id: "pairing")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Settings window, during setup too. The app has no Dock icon, so it comes forward first.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}
