import AppKit
import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandDesktopCore
import AgentLandWorkspace

/// The Mac's Settings panes, in the window's tab order. The raw values are the saved choice
/// (`agentland.desktop.settingsPane`), kept as they were; Memory and Chat Tools are gone, so a choice saved for either
/// opens General.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case general, workspace, agents, vault, devices, terminals, remoteAccess, notifications, provider, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .workspace: "Workspaces"
        case .agents: "Agents"
        case .vault: "Vault"
        case .devices: "Devices"
        case .terminals: "Terminals"
        case .remoteAccess: "Remote Access"
        case .notifications: "Notifications"
        // Chat runs Claude Code and Codex on the Claude and ChatGPT subscriptions (owner's decisions, 2026-10-12);
        // API keys come later.
        case .provider: "API Keys (Later)"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .workspace: "folder"
        case .agents: "shippingbox"
        case .vault: "books.vertical"
        case .devices: "ipad.and.iphone"
        case .terminals: "terminal"
        case .remoteAccess: "network"
        case .notifications: "bell.badge"
        case .provider: "key"
        case .advanced: "gearshape.2"
        }
    }
}

/// A text setting a pane edits: its label and the `HostController` value, which saves it in the
/// app's preferences as it always has.
struct HostTextSetting: Identifiable {
    let title: String
    let keyPath: ReferenceWritableKeyPath<HostController, String>
    var id: String { title }
}

/// A switch a pane edits, saved like the text settings.
struct HostToggleSetting: Identifiable {
    let title: String
    let keyPath: ReferenceWritableKeyPath<HostController, Bool>
    var id: String { title }
}

/// The settings the panes edit, one list per pane, in the order they show them.
@MainActor enum MacSettings {
    static let folder = HostTextSetting(title: "Folder", keyPath: \.projectDirectory)
    static let name = HostTextSetting(title: "Name", keyPath: \.projectName)
    static let identifier = HostTextSetting(title: "Identifier", keyPath: \.projectID)
    static let openCodeURL = HostTextSetting(title: "External OpenCode URL", keyPath: \.openCodeURL)
    static let hostname = HostTextSetting(title: "Hostname or IP", keyPath: \.advertisedHost)
    static let certificate = HostTextSetting(title: "Certificate file", keyPath: \.certificatePath)
    static let key = HostTextSetting(title: "Private key file", keyPath: \.keyPath)
    static let listener = HostTextSetting(title: "Listen address", keyPath: \.listenAddress)
    static let managedRuntime = HostToggleSetting(title: "Manage OpenCode automatically", keyPath: \.managedOpenCode)
    static let terminals = HostToggleSetting(title: "Allow paired devices to open terminal sessions", keyPath: \.terminalEnabled)
    /// Coding agents typed in Terminal open in AgentLand; its switch runs `terminals hook` (`TerminalRoutingToggle`).
    static let terminalRouting = HostToggleSetting(title: "Open coding agents from Terminal in AgentLand",
                                                   keyPath: \.terminalRoutingEnabled)

    /// Workspaces: the default workspace folder, its name and identifier.
    static let workspace = [folder, name, identifier]
    /// Advanced: an existing local OpenCode service and how devices reach this Mac.
    static let advancedText = [openCodeURL, hostname, certificate, key, listener]
    static let advancedToggles = [managedRuntime]
    /// Terminals, above the list: terminal access, and the routing switch right under it, which needs it.
    static let terminalToggles = [terminals, terminalRouting]
}

/// The Settings window (⌘,), in the style of Safari's: a toolbar tab for each pane, the window titled with the pane in
/// front and sized to it. Its fields edit `HostController`, which keeps the one desired-connection state and saves the
/// same preferences and Keychain items as before; closing the window never stops the server.
struct MacSettingsView: View {
    @EnvironmentObject private var host: HostController
    @AppStorage("agentland.desktop.settingsPane") private var pane = MacSettingsPane.general

    var body: some View {
        TabView(selection: $pane) {
            ForEach(MacSettingsPane.allCases) { item in
                Tab(item.title, systemImage: item.systemImage, value: item) {
                    MacSettingsPaneView(pane: item)
                        .macSettingsPane()
                }
                .accessibilityIdentifier("macSettingsPane-\(item.rawValue)")
            }
        }
        .onAppear {
            host.refreshLifecycleStatus()
            host.refreshDevices(showActivity: false)
        }
    }
}

/// One pane's content.
struct MacSettingsPaneView: View {
    @EnvironmentObject private var host: HostController
    let pane: MacSettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .workspace: WorkspaceSettingsPane()
        case .agents: MacAgentsSettingsPane()
        // The Markdown copy of the archive the host keeps in a folder (docs/HOST-API.md "Vault").
        case .vault: VaultSettingsPane()
        case .devices: DevicesSettingsPane()
        case .terminals: TerminalsSettingsPane()
        case .remoteAccess: RemoteAccessSettingsPane(remoteAccess: host.remoteAccess)
        case .notifications: NotificationsSettingsPane()
        case .provider: ProviderSettingsPane()
        case .advanced: AdvancedSettingsPane()
        }
    }
}

extension View {
    /// The first row of a group after the first in a pane's form: the space Safari leaves between its groups.
    func macSettingsGroupStart() -> some View {
        padding(.top, 12)
    }

    /// A Settings pane: the window's one width, its margins, and the height its content needs.
    func macSettingsPane() -> some View {
        padding(MacSettingsMetrics.padding)
            .frame(width: MacSettingsMetrics.paneWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Panes

/// Agents: Chat's sign-ins over the Mac's list of agents. Chat runs Claude Code and Codex in the workspace on the
/// Claude and ChatGPT subscriptions this Mac is signed in to (owner's decisions, 2026-10-12), so Settings says which
/// sign-in each uses and, for one Chat cannot use, what to do (`capabilities.workspaceChats`; iPhone and iPad show the
/// same in Settings → Chat). Nothing shows there while the host runs no Chat (not running yet, or an older host).
/// Opening the pane has the host check the sign-ins at once (`checkChatSignIns`), and an agent that isn't signed in
/// has Sign In… (`ChatSignInWatch`, owner 2026-10-17), whose watch ends when the pane goes away.
struct MacAgentsSettingsPane: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var watch = ChatSignInWatch()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MacChatSignIns(signIns: Self.signIns(workspace), icons: workspace.agents.icons,
                           signIn: watch.state, startSignIn: { row in
                               watch.signIn(row) { [workspace] in await OnboardingAgents.check(workspace) }
                           })
            MacAgentsSettingsList()
        }
        .task(id: workspace.paneReadKey) { await workspace.checkChatSignIns() }
        .onDisappear { watch.stop() }
    }

    /// The sign-ins the host lists for Chat, from the capabilities the workspace last read.
    static func signIns(_ workspace: WorkspaceModel) -> PlainChatSignIns {
        PlainChatSignIns(workspace.capabilities?.workspaceChats)
    }
}

/// Chat's sign-ins above the agents: each provider with its sign-in, then those signed in otherwise with the host's
/// words on what to do and the command that signs them in, and the subscriptions rule under them. The rows are setup's
/// too (`MacChatSignInRow`, its Claude Code and Codex step), with Sign In… when the pane passes `startSignIn`; nothing
/// when the host names none.
struct MacChatSignIns: View {
    let signIns: PlainChatSignIns
    let icons: AgentIconStore
    var signIn: (String) -> MacChatSignInRow.SignIn = { _ in .idle }
    var startSignIn: ((PlainChatSignIns.Row) -> Void)?

    var body: some View {
        if !signIns.rows.isEmpty {
            Form {
                LabeledContent(MacChatSignIns.title + ":") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(signIns.rows) { row in
                            MacChatSignInRow(row: row, icons: icons, signIn: signIn(row.id),
                                             startSignIn: startSignIn.map { start in { start(row) } })
                        }
                        MacSettingsFootnote(PlainChatSignIns.footer)
                    }
                }
            }
            .formStyle(.columns)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("macChatSignIns")
        }
    }

    static let title = "Chat"
}

/// Workspaces: the host's workspaces, managed live through this Mac's own session, the same actions as the Workspaces
/// screen on iPhone and iPad, in the Mac's own list (`MacWorkspacesSettingsList`), once the host advertises it. Before
/// that (an older host, or none running yet since launch) it edits the one default workspace folder, and Save
/// reconnects through the host's command line.
private struct WorkspaceSettingsPane: View {
    @EnvironmentObject private var host: HostController
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        if workspace.workspaces.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                if let error = host.errorMessage { SettingsErrorText(message: error) }
                MacWorkspacesSettingsList(open: { id in
                    // The native window manages the server; work opens in the browser.
                    workspace.openWorkspace(id)
                    host.openWebWorkspace()
                })
            }
        } else {
            defaultWorkspaceForm
        }
    }

    private var defaultWorkspaceForm: some View {
        Form {
            SettingsHostError()
            Section {
                HostFileField(setting: MacSettings.folder, choose: host.chooseProjectDirectory)
                HostTextField(setting: MacSettings.name)
                HostTextField(setting: MacSettings.identifier)
            }
            SaveConfigurationSection()
        }
        .formStyle(.columns)
        .disabled(host.isWorking)
    }
}

/// Devices: the paired phones and tablets in a list, whether each is using AgentLand now, Revoke… for the selected
/// one, Refresh, and Pair a Device…, which opens the pairing window.
private struct DevicesSettingsPane: View {
    @EnvironmentObject private var host: HostController
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?
    @State private var revoking: ManagedDevice?
    /// Terminals still running that the device started, read when Revoke… is chosen.
    @State private var revokingTerminals = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = host.errorMessage { SettingsErrorText(message: error) }
            Group {
                if host.devices.isEmpty {
                    MacSettingsListBox {
                        ContentUnavailableView("No Paired Devices", systemImage: "ipad.and.iphone",
                                               description: Text("Pair a phone or tablet to see it here."))
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(host.devices) { device in row(device).tag(device.id) }
                    }
                    .listStyle(.bordered)
                    .alternatingRowBackgrounds()
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let device = device(ids.first), device.isActive {
                            Button("Revoke…", role: .destructive) { askRevoke(device) }
                                .disabled(host.isWorking)
                        }
                    }
                }
            }
            .frame(height: MacSettingsMetrics.listHeight)
            HStack(spacing: 8) {
                Button("Revoke…") { if let device = device(selection) { askRevoke(device) } }
                    .disabled(device(selection)?.isActive != true || host.isWorking)
                    .accessibilityIdentifier("devicesRevoke")
                Spacer()
                Button("Refresh") { host.refreshDevices() }
                    .disabled(host.isWorking || !host.hasState)
                Button("Pair a Device…") {
                    host.createPairingCode()
                    openWindow(id: "pairing")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .disabled(host.status != .running || host.activeAdvertisement == nil || host.isWorking)
            }
            if let notice = host.revokeNotice {
                MacSettingsStateLine("Some terminals are still running. \(notice)")
            }
        }
        .onAppear { host.refreshDevices(showActivity: false) }
        .confirmationDialog("Revoke “\(revoking?.name ?? "")”?", isPresented: revokeShown, titleVisibility: .visible,
                            presenting: revoking) { device in
            if revokingTerminals > 0 {
                Button("Revoke and End Terminals", role: .destructive) { host.revoke(device, endingTerminals: true) }
                    .keyboardShortcut(.defaultAction)
                Button("Revoke and Keep Running") { host.revoke(device, endingTerminals: false) }
            } else {
                Button("Revoke", role: .destructive) { host.revoke(device, endingTerminals: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DevicesText.revokeMessage(count: revokingTerminals))
        }
    }

    private func device(_ id: String?) -> ManagedDevice? {
        guard let id else { return nil }
        return host.devices.first { $0.id == id }
    }

    private func askRevoke(_ device: ManagedDevice) {
        Task {
            revokingTerminals = await host.runningTerminals(forDevice: device.id)
            revoking = device
        }
    }

    private func row(_ device: ManagedDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                Text("\(device.status == "active" ? (device.isPresent ? "Using AgentLand" : "Not currently using") : "Revoked") · Paired \(device.createdAt)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var revokeShown: Binding<Bool> {
        Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })
    }
}

/// Notifications: iCloud's state, the two switches and a test notification.
private struct NotificationsSettingsPane: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        Form {
            NotificationSettingsSection(notifications: host.notifications) {
                host.notifications.sendTestNotification(certificateSHA256: host.activeAdvertisement?.certificateSHA256 ?? host.certificateFingerprint,
                                                        projectID: host.projectID, projectName: host.projectName)
            }
        }
        .formStyle(.columns)
    }
}

/// Advanced: an existing local OpenCode service (the external-loopback mode existing setups use), how devices reach
/// this Mac, and a local certificate. Terminal access and its routing switch are in Terminals.
private struct AdvancedSettingsPane: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        Form {
            SettingsHostError()
            Section {
                LabeledContent("OpenCode:") {
                    HostToggle(setting: MacSettings.managedRuntime)
                }
                MacSettingsFootnote(AdvancedText.openCode)
                HostTextField(setting: MacSettings.openCodeURL)
                SecureField("External OpenCode password:", text: $host.openCodePassword, prompt: Text(""))
            }
            Section {
                Picker("Connection:", selection: $host.connectionMode) {
                    Text("Local development HTTP").tag(HostController.ConnectionMode.developmentHTTP)
                    Text("Trusted HTTPS").tag(HostController.ConnectionMode.trustedHTTPS)
                }
                .pickerStyle(.radioGroup)
                .macSettingsGroupStart()
                HostTextField(setting: MacSettings.hostname)
                HostFileField(setting: MacSettings.certificate, choose: host.chooseCertificate)
                HostFileField(setting: MacSettings.key, choose: host.chooseKey)
                HostTextField(setting: MacSettings.listener)
                Button("Generate Local Certificate") { host.generateCertificate() }
                    .disabled(host.isWorking || host.advertisedHost.isEmpty)
            }
            SaveConfigurationSection()
        }
        .formStyle(.columns)
        .disabled(host.isWorking)
    }
}

/// The Devices pane's words, apart from the view so the tests read them.
enum DevicesText {
    static func revokeMessage(count: Int) -> String {
        let base = "It can no longer reach this Mac until it pairs again."
        guard count > 0 else { return base }
        let started = count == 1 ? "1 terminal started from it is still running." : "\(count) terminals started from it are still running."
        return base + " " + started + " Nobody can open them once the device is removed."
    }
}

/// The Advanced pane's words, apart from the view so the tests read them.
enum AdvancedText {
    /// Above the OpenCode switch: what AgentLand does with it on, and when to turn it off.
    static let endTerminalsTitle = "End running terminals?"
    /// `count` is nil when the host could not say how many run; `routed` how many of them are agents typed in
    /// Terminal, which keep running there.
    static func endTerminalsMessage(_ count: Int?, routed: Int = 0) -> String {
        let message: String
        if let count {
            message = count == 1 ? "Turning this off ends the 1 terminal running on this Mac."
                                 : "Turning this off ends the \(count) terminals running on this Mac."
        } else {
            message = "Turning this off ends every terminal running on this Mac."
        }
        return routed > 0 ? message + " " + agentsKeepRunning : message
    }
    static let endTerminals = "End Terminals"
    static let openCode = "AgentLand gets OpenCode through its host and keeps it up to date. Turn off “Manage OpenCode automatically” only to use an OpenCode service you run yourself."

    // Coding agents from Terminal.
    static let routingFootnote = "Typing claude, codex, opencode or another coding agent in Terminal starts it inside AgentLand, so you can keep going from your other devices. Takes effect in new Terminal windows."
    static let routingNeedsTerminals = "Turn on terminal access first."
    static let routingPaused = "Paused while terminal access is off."
    static let routingWaitsForTerminals = "Starts once the terminals open now have ended (an older AgentLand runs them)."

    /// The note under the routing switch about its state, if any: terminal access off (the switch can't turn on, or is
    /// on and paused), or a keeper from an older AgentLand still holding terminals while the switch is on. A keeper
    /// that doesn't say (`adopts` missing) shows nothing.
    static func routingNote(terminalAccess: Bool, routing: Bool, keeper: KeeperState?) -> String? {
        if !terminalAccess { return routing ? routingPaused : routingNeedsTerminals }
        if routing, keeper?.state == "running", keeper?.adopts == false { return routingWaitsForTerminals }
        return nil
    }
    static func routingZshOnly(_ shell: String) -> String { "Your shell is \(shell); this works only in zsh." }
    static let routingIssueTitle = "Couldn’t change your shell setup"
    /// The Quit question's sentence, from its one source.
    static let agentsKeepRunning = QuitText.agentsKeepRunning

    /// `routingZshOnly` for a login shell other than zsh; nil for zsh or when it isn't known.
    static func routingShellNote(loginShell: String?) -> String? {
        guard let loginShell, !loginShell.isEmpty else { return nil }
        let name = (loginShell as NSString).lastPathComponent
        return name.isEmpty || name == "zsh" ? nil : routingZshOnly(name)
    }

    /// This user's login shell: the user database's, else `$SHELL`; nil when neither says.
    static func loginShell(userDatabase: () -> String? = AdvancedText.userDatabaseShell,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let shell = userDatabase(), !shell.isEmpty { return shell }
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return nil
    }

    static func userDatabaseShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }
}

// MARK: Parts

/// A text field bound to `HostController`, its title the label beside it.
struct HostTextField: View {
    @EnvironmentObject private var host: HostController
    let setting: HostTextSetting

    var body: some View {
        TextField(setting.title + ":", text: $host[dynamicMember: setting.keyPath], prompt: Text(""))
    }
}

/// A path field bound to `HostController` with Choose… beside it, under one label.
struct HostFileField: View {
    @EnvironmentObject private var host: HostController
    let setting: HostTextSetting
    let choose: () -> Void

    var body: some View {
        LabeledContent(setting.title + ":") {
            HStack(spacing: 8) {
                TextField(setting.title, text: $host[dynamicMember: setting.keyPath], prompt: Text(""))
                    .labelsHidden()
                Button("Choose…", action: choose)
            }
        }
    }
}

/// A switch bound to `HostController`.
struct HostToggle: View {
    @EnvironmentObject private var host: HostController
    let setting: HostToggleSetting

    var body: some View {
        Toggle(setting.title, isOn: $host[dynamicMember: setting.keyPath])
    }
}

/// Saves the workspace and connection settings: with the managed runtime this reconnects; an
/// external service's password goes to Keychain.
private struct SaveConfigurationSection: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button(host.managedOpenCode ? "Save Workspace and Reconnect" : "Save External Configuration") { host.saveConfiguration() }
                    .disabled(host.isWorking)
            }
            .macSettingsGroupStart()
        }
    }
}

/// The host's last error at the top of a pane that acts on it: a short line in place.
struct SettingsHostError: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        if let error = host.errorMessage {
            Section { SettingsErrorText(message: error) }
        }
    }
}

/// An error in place: a short line with its symbol, in the system's red.
struct SettingsErrorText: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A status light in the system's colours: green when running or reachable, orange while working or when it needs
/// attention, red when offline, grey when off.
struct MacStatusLight: View {
    let status: StatusDot.Status

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        switch status {
        case .online: AnyShapeStyle(Color.green)
        case .working, .attention: AnyShapeStyle(Color.orange)
        case .offline: AnyShapeStyle(Color.red)
        case .idle: AnyShapeStyle(.tertiary)
        }
    }
}

/// The host's state in words, with its symbol (onboarding's header).
struct StatusBadge: View {
    let status: HostStatus
    var body: some View { Label(label, systemImage: icon).font(.caption).foregroundStyle(color) }
    private var label: String { switch status { case .stopped: return "Stopped"; case .starting: return "Starting"; case .running: return "Running" } }
    private var icon: String { status == .running ? "circle.fill" : "circle" }
    private var color: AgentLandColor { status == .running ? .success : status == .starting ? .warning : .textSecondary }
}
