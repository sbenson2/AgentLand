import AppKit
import SwiftUI
import AgentLandBranding
import AgentLandCore
import AgentLandDesign
import AgentLandDesktopCore
import AgentLandWorkspace

/// Settings → General: This Mac (whether its server runs, where devices reach it, Connect or Disconnect, Pair a Device…
/// and Open AgentLand: the controls the old window's header held), Apple Intelligence, opening at login (only after
/// the person turns it on) and the version.
struct GeneralSettingsPane: View {
    @StateObject private var loginItem = LoginItemController()
    /// Settings → Apple Intelligence (`AppleIntelligence`): Home's quips, chat names and every terminal's name
    /// (`HostTerminalNaming`), which follows the switch at once.
    @AppStorage(AppleIntelligence.settingKey) private var appleIntelligence = AppleIntelligence.settingDefault
    @State private var availability = AppleIntelligence.Availability.available

    static let appleIntelligenceDetail = "Writes Home’s quips and names chats and every terminal on this Mac, including other devices’ terminals and agents started in Terminal. Names are made on this Mac; terminal output never leaves it."

    var body: some View {
        Form {
            Section {
                ThisMacStatusRow()
            }
            Section {
                LabeledContent("Apple Intelligence:") {
                    Toggle("Use Apple Intelligence", isOn: $appleIntelligence)
                        .accessibilityIdentifier("settingsAppleIntelligence")
                }
                .macSettingsGroupStart()
                MacSettingsFootnote(Self.appleIntelligenceDetail)
                // The switch keeps its choice while the model can't run; this says why, in place.
                if let status = AppleIntelligence.unavailableText(availability, device: "Mac") {
                    Label {
                        Text("\(status.title). \(status.message)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settingsAppleIntelligenceStatus")
                }
            }
            Section {
                Toggle("Open AgentLand when you log in", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .macSettingsGroupStart()
                if loginItem.requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        MacSettingsFootnote("macOS needs approval in Login Items.")
                        Button("Open Login Items") { loginItem.openLoginItems() }
                            .controlSize(.small)
                    }
                }
            }
            Section {
                LabeledContent("Version:", value: agentLandAppVersion)
                    .macSettingsGroupStart()
            }
        }
        .formStyle(.columns)
        .onAppear { loginItem.refresh() }
        // Whether the model can run changes outside AgentLand (System Settings, a download): read while the pane
        // shows, off the main actor.
        .task {
            while !Task.isCancelled {
                availability = await Task.detached(priority: .utility) { AppleIntelligence.availability }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // A change macOS refused needs the person: the system's alert.
        .alert("Couldn’t Change Open at Login", isPresented: Binding(get: { loginItem.message != nil },
                                                                     set: { if !$0 { loginItem.dismissMessage() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginItem.message ?? "")
        }
    }
}

/// "This Mac" at the top of General: whether its host runs and where devices reach it, with Connect or Disconnect,
/// Pair a Device… and Open AgentLand, the same controls as the menu-bar tent. While setup isn't done it offers the
/// Setup window instead.
struct ThisMacStatusRow: View {
    @EnvironmentObject private var host: HostController
    @Environment(\.openWindow) private var openWindow

    /// Rows of General's form: the status beside its label, and what goes with it under it (long text in rows of its
    /// own, so it wraps in the form's column).
    var body: some View {
        LabeledContent("This Mac:") {
            HStack(spacing: 6) {
                MacStatusLight(status: dotStatus)
                Text(statusTitle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This Mac, \(statusTitle)")
            .accessibilityValue(address ?? "")
            .accessibilityIdentifier("thisMacStatus")
        }
        if let address {
            Text(address)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(address)
                .accessibilityHidden(true)
        }
        if host.status == .running, let routes = host.advertisedRoutes {
            ThisMacReachText(routes: routes, tailscale: host.advertisedTailscale, listener: host.activeListenAddress,
                             remoteAccess: host.remoteAccess)
        }
        if host.needsOnboarding {
            MacSettingsFootnote("Finish setting up AgentLand to start its server.")
        }
        buttons
        if let error = host.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("thisMacError")
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if host.needsOnboarding {
                Button("Set Up AgentLand…") {
                    openWindow(id: SetupWindowView.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                Button(host.status == .stopped ? "Connect" : "Disconnect") {
                    if host.status == .stopped { host.start() } else { host.stop() }
                }
                .disabled(host.isWorking)
                .accessibilityIdentifier("thisMacConnection")
                Button("Pair a Device…") {
                    host.createPairingCode()
                    openWindow(id: "pairing")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .disabled(host.status != .running || host.activeAdvertisement == nil || host.isWorking)
                .accessibilityIdentifier("thisMacPair")
            }
            Button(host.isOpeningWeb ? "Opening…" : "Open AgentLand") { host.openWebWorkspace() }
                .disabled(host.needsOnboarding || host.isOpeningWeb)
                .accessibilityIdentifier("thisMacOpen")
        }
    }

    private var dotStatus: StatusDot.Status {
        switch host.status {
        case .running: .online
        case .starting: .working
        case .stopped: host.errorMessage == nil ? .idle : .attention
        }
    }

    private var statusTitle: String {
        switch host.status {
        case .running: "Running"
        case .starting: "Starting…"
        case .stopped: "Stopped"
        }
    }

    /// Where paired devices reach this Mac while its host runs.
    private var address: String? {
        guard host.status == .running else { return nil }
        return host.activeAdvertisement?.address ?? host.activeListenAddress
    }

    /// The row's words for the host's routes and what it last read of Tailscale (docs/HOST-API.md,
    /// "Routes"). Without a Tailscale route it says why, so the owner knows what to change.
    static func reach(_ routes: [HostRoute], tailscale state: String?, listener: String? = nil) -> String {
        if let tailscale = routes.first(where: \.isTailscale) {
            return "Also reachable through Tailscale (\(tailscale.host))"
        }
        switch state {
        case "notListening":
            return "Only on this network — Tailscale is on, but AgentLand listens only on \(listener ?? "one address"). Listen on 0.0.0.0 (Settings → Advanced → Listen address) to use it away from home"
        case "notFound":
            return "Only on this network — install Tailscale on this Mac to use AgentLand away from home"
        case "unknown":
            return "Only on this network for now — AgentLand couldn’t read Tailscale’s status on this Mac and tries again every 5 minutes"
        default:
            return "Only on this network — turn on Tailscale on this Mac to use AgentLand away from home"
        }
    }
}

/// Whether devices can reach this Mac away from home, as its host's routes say. With remote access
/// on, its own status (Settings → Remote Access) says how devices reach the Mac, so only a Tailscale route is added
/// here, never the advice to turn Tailscale on.
private struct ThisMacReachText: View {
    let routes: [HostRoute]
    let tailscale: String?
    let listener: String?
    @ObservedObject var remoteAccess: RemoteAccessController

    var body: some View {
        if !remoteAccess.status.enabled || routes.contains(where: \.isTailscale) {
            MacSettingsFootnote(ThisMacStatusRow.reach(routes, tailscale: tailscale, listener: listener))
                .textSelection(.enabled)
                .accessibilityIdentifier("thisMacRoutes")
        }
    }
}
