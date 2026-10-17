import AppKit
import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandWorkspace

// Started by the entry point in macos/App/AgentLandMain.swift.
public struct AgentLandDesktopApp: App {
    @StateObject private var host = HostController.shared
    @StateObject private var navigation = DesktopNavigation()
    @NSApplicationDelegateAdaptor(AgentLandAppDelegate.self) private var appDelegate
    /// The workspace follows this Mac's host for as long as the app runs, with or without a window.
    private let workspace = DesktopWorkspace.shared

    public init() {}

    public var body: some Scene {
        // Setup alone: the first launch and the menu's Set Up AgentLand… open it; it closes once setup is done.
        Window("Set Up AgentLand", id: SetupWindowView.id) {
            SetupWindowView()
                .environmentObject(host)
                // Setup's Claude Code and Codex step reads Chat's sign-ins from the workspace's capabilities.
                .environment(workspace.model)
        }
        .defaultSize(width: 760, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            ServerCommands(host: host)
        }

        // The native Settings window (⌘, and the app menu's Settings… come with the scene), in the style of
        // Safari's: one toolbar tab per pane, titled with the pane in front, sized to it (2026-10-16).
        Settings {
            MacSettingsView()
                .environmentObject(host)
                .environment(workspace.model)
        }

        Window("Pair a Device", id: "pairing") {
            PairingSheet().environmentObject(host)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarControls()
                .environmentObject(host)
                .environmentObject(navigation)
        } label: {
            ServerMenuLabel(host: host, navigation: navigation)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct ServerMenuLabel: View {
    @ObservedObject var host: HostController
    @ObservedObject var navigation: DesktopNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: AgentLandMenuBarIcon.image)
            .accessibilityLabel("AgentLand")
            .task {
                if host.needsOnboarding {
                    openWindow(id: SetupWindowView.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // After setup, a host that runs with no paired device opens the Pair a Device window with its pairing QR
            // code, once per launch (QR-only pairing, 2026-10-16). Done or a device pairing closes it.
            .task(id: host.status) {
                guard host.status == .running, !host.needsOnboarding, !navigation.autoPairingChecked else { return }
                guard let devices = await host.readDevices(), !Task.isCancelled,
                      host.status == .running, host.activeAdvertisement != nil, !navigation.autoPairingChecked else { return }
                navigation.autoPairingChecked = true
                guard !devices.contains(where: \.isActive) else { return }
                host.createPairingCode()
                openWindow(id: "pairing")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

private struct ServerCommands: Commands {
    @ObservedObject var host: HostController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open AgentLand") { host.openWebWorkspace() }
                .disabled(host.needsOnboarding || host.isOpeningWeb)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Close Window") { NSApp.keyWindow?.close() }.keyboardShortcut("q")
            Button("Quit AgentLand Server") { HostController.shared.quitDeliberately() }
        }
    }
}
