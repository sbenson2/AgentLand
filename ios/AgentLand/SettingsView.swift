import SwiftUI
import UIKit
import CoreHaptics
import AgentLandCore
import AgentLandBranding
import AgentLandDesign
import AgentLandWorkspace

/// Settings on iPhone and iPad. Every fact and action has one home:
/// - the status at the top: the host, whether it answers and the route in use; it opens Connection;
/// - This Mac (the selected host): Connection; Agents & Providers and Plain Chats when the host offers them (workspaces
///   are managed in the header's workspace menu, owner, 2026-10-08);
/// - App: Appearance, Chat, Terminal, Apple Intelligence, Notifications, Privacy & Security;
/// - About: the version, this device, what's new and every licence.
/// Each category is a page pushed in the container's navigation stack; the workspace package provides the shared
/// panes and the app adds what only it owns: the connection, saved hosts and pairing, device unlock, the privacy
/// cover and this device's copy of the host's chats.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkspaceModel.self) private var workspace
    /// Puts Settings away.
    let onClose: () -> Void

    /// The selected host's own pages, each only when the host offers it.
    private var hostItems: [SettingsDetail] {
        var items: [SettingsDetail] = [.connection]
        if workspace.agents.isAvailable || workspace.aiProviders.isAvailable { items.append(.agents) }
        // No Chat Memory & Tools page: Chat is Claude Code and Codex with their own tools, and memory went (owner,
        // 2026-10-12: "dont need"). The host's saved memory file stays on the Mac, untouched.
        return items
    }

    var body: some View {
        categories
            // iPhone: the Settings tab's root, with the system bar and a large title as the Settings app's.
            .workspaceSettingsRoot("Settings")
            .navigationDestination(for: SettingsDetail.self) { detail in
                detailView(detail)
                    .workspaceSettingsPage(detail.title)
                    .toolbar(.visible, for: .navigationBar)
            }
    }

    /// A grouped form, as the Settings app is: the status first, then a section for each group of pages.
    private var categories: some View {
        AgentLandForm {
            if let host = model.selectedHost {
                Section { SettingsStatusHeader(host: host) }
            }
            categoryGroup("This Mac", items: hostItems)
            categoryGroup("App", items: [.appearance, .chat, .terminal, .appleIntelligence, .notifications, .privacy])
            categoryGroup("About", items: [.about])
        }
        .settingsForm()
        .contentMargins(.top, AgentLandSpacing.xSmall, for: .scrollContent)
    }

    private func categoryGroup(_ title: String, items: [SettingsDetail]) -> some View {
        Section(title) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    ActionRowLabel(item.title, systemImage: item.icon)
                }
                .accessibilityLabel(item.title)
            }
        }
    }

    @ViewBuilder private func detailView(_ value: SettingsDetail) -> some View {
        switch value {
        case .connection: ConnectionSettingsView(onClose: onClose)
        case .agents:
            if workspace.agents.isAvailable {
                AgentsSettingsPane {
                    if workspace.aiProviders.isAvailable { ProvidersRow() }
                }
            } else {
                AIProvidersSettingsPane()
            }
        case .providers: AIProvidersSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .chat: ChatSettingsPane(offersHaptics: Self.offersHaptics)
        case .terminal: TerminalSettingsPane(offersHaptics: Self.offersHaptics)
        case .appleIntelligence: AppleIntelligenceSettingsPane(device: UIDevice.current.model)
        case .notifications: NotificationsSettingsPane()
        case .privacy: PrivacySecuritySettingsView()
        case .about: AboutSettingsPane()
        }
    }

    /// iPhone plays haptics; iPad has none, so the haptic settings are absent there.
    static let offersHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
}

/// A page of Settings.
enum SettingsDetail: String, Identifiable, Hashable {
    case connection, agents, providers, appearance, chat, terminal, appleIntelligence, notifications, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: "Connection"
        case .agents: "Agents & Providers"
        case .providers: "AI Providers"
        case .appearance: "Appearance"
        case .chat: "Chat"
        case .terminal: "Terminal"
        case .appleIntelligence: "Apple Intelligence"
        case .notifications: "Notifications"
        case .privacy: "Privacy & Security"
        case .about: "About AgentLand"
        }
    }
    var icon: String {
        switch self {
        case .connection: "network"
        case .agents: "shippingbox"
        case .providers: "key"
        case .appearance: "paintpalette"
        case .chat: "bubble.left.and.bubble.right"
        case .terminal: "terminal"
        case .appleIntelligence: "apple.intelligence"
        case .notifications: "bell.badge"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// The top of Settings, a row of its own like the account at the top of the Settings app: the host's name, whether it
/// answers (the status dot) and through which route. It opens Connection.
private struct SettingsStatusHeader: View {
    @Environment(AppModel.self) private var model
    let host: SavedHost

    var body: some View {
        NavigationLink(value: SettingsDetail.connection) {
            Label {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text(host.name).agentLandFont(.heading3)
                    Text("\(Text(Image(systemName: "circle.fill")).font(AgentLandTypeRole.caption2.font).foregroundStyle(dotColor)) \(model.connectionSummary)")
                        .agentLandFont(.secondary)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            } icon: {
                Image(systemName: "desktopcomputer").rowIconStyle()
            }
        }
        .accessibilityLabel(host.name)
        .accessibilityValue(model.connectionSummary)
        .accessibilityHint("Opens Connection")
        .accessibilityIdentifier("settingsStatus")
    }

    private var dotColor: AgentLandColor {
        switch model.connection {
        case .online: .success
        case .checking: .warning
        case .offline: .danger
        }
    }
}

/// The Agents page's row that opens AI Providers, with how many are connected once they were read.
private struct ProvidersRow: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        NavigationLink(value: SettingsDetail.providers) {
            LabeledContent {
                if let detail { Text(detail) }
            } label: {
                ActionRowLabel("AI Providers", systemImage: SettingsDetail.providers.icon)
            }
        }
        .accessibilityIdentifier("agentsProvidersRow")
        .task(id: workspace.paneReadKey) { await workspace.aiProviders.refresh() }
    }

    private var detail: String? {
        guard workspace.aiProviders.providers != nil else { return nil }
        let count = workspace.aiProviders.connected.count
        return count == 1 ? "1 connected" : "\(count) connected"
    }
}

// MARK: Connection

/// This Mac → Connection: the current host (its status, the route in use and Disconnect), its routes and remote
/// access, the saved hosts (each can be forgotten), and pairing another host.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var showPair = false
    @State private var forgetting: SavedHost?
    private let device = UIDevice.current.model

    var body: some View {
        AgentLandForm {
            if let host = model.selectedHost {
                Section {
                    LabeledContent("Name", value: host.name)
                        .accessibilityElement(children: .combine)
                    LabeledContent("Status", value: model.connectionStateName)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("connectionStatus")
                    if let route = model.routeInUse {
                        LabeledContent(model.hostReachable ? "Connected through" : "Last tried", value: routeDescription(route, host: host))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("connectionRouteInUse")
                    }
                    // Not destructive: the host stays saved. On iPhone in the label colour (native-full side build).
                    Button { model.disconnect(); onClose() } label: { ActionRowLabel("Disconnect") }
                } header: {
                    Text("Current host")
                } footer: {
                    Text("Disconnecting leaves \(host.name) saved; choose it again under Saved hosts.")
                }
                if host.certificateSHA256 != nil { routes(host) }
            }
            Section("Saved hosts") {
                ForEach(model.hosts) { host in
                    SavedHostRow(host: host, selected: model.selectedHost?.id == host.id,
                                 select: { model.select(host); onClose() }, forget: { forgetting = host })
                        // Forget's question points at this host's row (owner, 2026-10-08).
                        .confirmationDialog(forgetting.map { "Forget \($0.name)?" } ?? "", isPresented: forgetShown(host), titleVisibility: .visible,
                                            presenting: forgetting) { host in
                            Button("Forget", role: .destructive) {
                                let selected = model.selectedHost?.id == host.id
                                model.forget(host)
                                if selected { onClose() }
                            }
                            .accessibilityIdentifier("connectionConfirmForget")
                            Button("Cancel", role: .cancel) {}
                        } message: { host in
                            Text("This \(device) deletes its sign-in, tabs and drafts, and its copy of the chats and terminal logs for \(host.name). To remove this \(device) from the Mac too, revoke it there in Settings → Devices.")
                        }
                }
            }
            Section {
                Button { showPair = true } label: { ActionRowLabel("Pair Another Host…", systemImage: "plus") }
                    .accessibilityIdentifier("connectionPair")
            }
        }
        .settingsForm()
        .sheet(isPresented: $showPair) { PairingView().agentLandSheetPage() }
        .onChange(of: model.locked) { _, locked in if locked { showPair = false; forgetting = nil } }
    }

    /// Whether this host's row asks Forget's question: only the row of the host asked about presents it.
    private func forgetShown(_ host: SavedHost) -> Binding<Bool> {
        Binding(get: { forgetting?.id == host.id }, set: { if !$0, forgetting?.id == host.id { forgetting = nil } })
    }

    /// "Local network · studio.local:9841", or the tunnel's name alone.
    private func routeDescription(_ route: RouteCandidate, host: SavedHost) -> String {
        let name = AppModel.routeName(of: route, host: host)
        guard let address = route.address else { return name }
        return name + " · " + address.authority
    }

    /// The host's routes (docs/HOST-API.md, "Routes"). Every route uses the certificate this device paired with.
    @ViewBuilder private func routes(_ host: SavedHost) -> some View {
        // With no routes yet, the section is its footer alone.
        Section {
            ForEach(Array(host.routes.enumerated()), id: \.offset) { _, route in
                LabeledContent {
                    Text(([route.host] + route.addresses).joined(separator: "\n"))
                        .monospaced()
                        .textSelection(.enabled)
                } label: {
                    Text(AppModel.routeTitle(route.kind))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connectionRoute-\(route.kind)")
            }
        } header: {
            if !host.routes.isEmpty { Text("Routes") }
        } footer: {
            Text(host.knowsTailscaleRoute
                 ? "Away from home, AgentLand connects through Tailscale while it is on on this device and the Mac. Every route uses the certificate this device paired with."
                 : "Only this network so far. Turn on Tailscale on the Mac and connect once here; AgentLand then connects through it away from home too.")
                .accessibilityIdentifier("connectionRoutesNote")
        }
        if let entry = host.remoteAccess { remoteAccess(host, entry) }
    }

    /// The remote-access tunnel (docs/HOST-API.md "Remote access (iroh)"): what the Mac reported and where the tunnel
    /// stands. It is tried only when no address answers.
    private func remoteAccess(_ host: SavedHost, _ entry: RemoteAccessCapabilities) -> some View {
        Section {
            LabeledContent("Reach this Mac from anywhere", value: AppModel.remoteAccessWords(entry))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connectionRemoteAccess")
            LabeledContent("Tunnel", value: host.tunnelRefused && model.tunnelState != .notAdmitted
                           ? AppModel.notAdmittedDescription : model.tunnelStateDescription)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connectionTunnel")
        } header: {
            Text("Remote access")
        } footer: {
            Text("When no address answers, AgentLand connects to the Mac directly through iroh, end to end encrypted, with the certificate this device paired with. It is turned on in AgentLand on the Mac.")
                .accessibilityIdentifier("connectionRemoteAccessNote")
        }
    }
}

/// A saved host: its name and address, the accent's checkmark on the one in use; a tap uses it, and its menu, its
/// context menu and a swipe forget it.
private struct SavedHostRow: View {
    let host: SavedHost
    let selected: Bool
    let select: () -> Void
    let forget: () -> Void

    var body: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Button(action: select) {
                HStack(spacing: AgentLandSpacing.small) {
                    VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                        Text(host.name).foregroundStyle(AgentLandColor.text)
                        Text(host.address).agentLandFont(.secondary).foregroundStyle(AgentLandColor.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityActions { Button("Forget…", action: forget) }
            .accessibilityIdentifier("connectionSavedHost")
            Menu {
                Button("Forget…", systemImage: "trash", role: .destructive, action: forget)
                    .accessibilityIdentifier("connectionForget")
            } label: {
                SettingsMenuLabel()
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .accessibilityLabel("Actions for \(host.name)")
            .accessibilityIdentifier("connectionSavedHostMenu")
        }
        .contextMenu { Button("Forget…", systemImage: "trash", role: .destructive, action: forget) }
        // Not a destructive role: the row stays until the person confirms.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: forget) { Label("Forget…", systemImage: "trash") }.tint(.red)
        }
    }
}

// MARK: Privacy & Security

/// App → Privacy & Security: device unlock, hiding AgentLand in the app switcher, and this device's copy of the
/// selected host's chats and terminal logs.
struct PrivacySecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyCover.settingKey) private var hidesInSwitcher = PrivacyCover.settingDefault
    @State private var confirmingClear = false
    @State private var clearing = false
    /// Why clearing the copy failed, for the system's alert; a clear that worked shows nothing more.
    @State private var clearFailure: String?
    private let device = UIDevice.current.model

    var body: some View {
        AgentLandForm {
            Section("Device unlock") {
                // On while Face ID or the passcode confirms it (the switch shows the choice being confirmed); off
                // again after a cancel or a failure.
                SettingsToggleRow("Require device unlock",
                                  detail: "Use Face ID, Touch ID or your passcode when you return to AgentLand.",
                                  isOn: Binding(get: { model.lockEnabled || model.confirmingLock }, set: { model.enableLock($0) }))
                    .disabled(model.confirmingLock)
                    .accessibilityIdentifier("privacyDeviceUnlock")
            }
            Section("App switcher") {
                SettingsToggleRow("Hide content in the app switcher",
                                  detail: "AgentLand shows its cover while you switch apps or another screen is over it.",
                                  isOn: $hidesInSwitcher)
                    .accessibilityIdentifier("privacyHideInAppSwitcher")
            }
            if let host = model.selectedHost {
                Section {
                    // In the accent, as the Settings app's Clear History: its confirmation asks with the destructive role.
                    Button { confirmingClear = true } label: { ActionRowLabel("Clear Cached Chats and Terminal Logs…") }
                        .disabled(clearing)
                        .accessibilityIdentifier("privacyClearCopy")
                        // Its question points at this button (owner, 2026-10-08).
                        .confirmationDialog("Clear cached chats and terminal logs?", isPresented: $confirmingClear, titleVisibility: .visible) {
                            Button("Clear", role: .destructive) { clear() }
                                .accessibilityIdentifier("privacyConfirmClear")
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This \(device) deletes its copy of \(model.selectedHost?.name ?? "the host")’s chats, terminal logs and their attachments, then copies them again. Your drafts and pins stay, and nothing changes on the Mac.")
                        }
                    if clearing {
                        LabeledContent("Clearing…") { ProgressView() }
                            .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("This \(device)’s copy")
                } footer: {
                    Text("This \(device) keeps a copy of the chats and terminal logs so they open quickly and offline. Clearing it copies them again from \(host.name); drafts and pins stay. To forget the Mac altogether, use Connection.")
                }
            }
        }
        .settingsForm()
        // Failures that need the person, in the system's alerts (2026-10-06): device unlock that stays off, a copy that
        // wasn't cleared. A clear that worked shows nothing more: the copy fills again by itself.
        .alert("Device Unlock Is Off", isPresented: Binding(get: { model.lockSettingMessage != nil },
                                                            set: { if !$0 { model.clearLockSettingMessage() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lockSettingMessage ?? "")
        }
        .alert("Couldn’t Clear the Copy", isPresented: Binding(get: { clearFailure != nil }, set: { if !$0 { clearFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clearFailure ?? "")
        }
        .onChange(of: model.locked) { _, locked in if locked { confirmingClear = false } }
    }

    private func clear() {
        clearing = true
        clearFailure = nil
        Task {
            let failure = await model.clearDeviceCopy()
            clearing = false
            clearFailure = failure
        }
    }
}
