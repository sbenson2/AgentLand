#if os(macOS)
import AppKit
import SwiftUI
import AgentLandCore

// The Mac's Settings window, in the style of Safari's (owner, 2026-10-16: "exactly like the safary prefernecs pane"):
// fixed-width panes that size to their content, plain forms with labels beside the controls, footnotes under the
// controls they explain, and long lists as bordered lists with their buttons under them. These are the Mac's own
// presentations of the shared models (`WorkspaceManager`, `AgentsModel`); iPhone and iPad keep `WorkspacesView` and
// `AgentsSettingsPane`.

/// The Settings window's measures, one for every pane.
public enum MacSettingsMetrics {
    /// Every pane's width.
    public static let paneWidth: CGFloat = 640
    /// The margin around a pane's content.
    public static let padding: CGFloat = 20
    /// A bordered list's height inside a pane.
    public static let listHeight: CGFloat = 320
}

/// A small secondary note under the control it explains.
public struct MacSettingsFootnote: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A state a pane shows in place (the host isn't connected, a read failed): one short secondary line with its symbol.
public struct MacSettingsStateLine: View {
    private let text: String
    private let systemImage: String

    public init(_ text: String, systemImage: String = "exclamationmark.triangle") {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// What shows in a bordered list's place while it has no rows (loading, empty, a failed read): the list's own frame,
/// background and border around it.
public struct MacSettingsListBox<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .border(.separator)
    }
}

public extension View {
    /// A change's outcome (`WorkspaceNotice`) on the Mac's Settings: one that failed, or may not have happened (it says
    /// so), in the system's alert, which OK puts away (`dismiss`); a plain success shows only in its row.
    func macSettingsNoticeAlert(_ notice: WorkspaceNotice?, dismiss: @escaping () -> Void) -> some View {
        let shown = notice?.tone == .success ? nil : notice
        return alert(shown?.title ?? "", isPresented: Binding(get: { shown != nil }, set: { if !$0 { dismiss() } }),
                     presenting: shown) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            if let message = notice.message { Text(message) }
        }
    }
}

/// The system's search field (`NSSearchField`): its magnifier, its clear button and its focus ring.
public struct MacSearchField: NSViewRepresentable {
    @Binding private var text: String
    private let prompt: String
    private let identifier: String

    public init(text: Binding<String>, prompt: String, identifier: String) {
        _text = text
        self.prompt = prompt
        self.identifier = identifier
    }

    public func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.setAccessibilityLabel(prompt)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    public func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor public final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        /// The clear button and Return.
        @objc func changed(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}

// MARK: Workspaces

/// Settings → Workspaces on the Mac: the host's workspaces in a bordered list, managed through this Mac's own session,
/// with the same actions as the Workspaces screen on iPhone and iPad (`WorkspacesView`). Double-click opens one; + and −
/// under the list add and remove, and Rename…, Close and Open act on the selected workspace, as its context menu does.
public struct MacWorkspacesSettingsList: View {
    @Environment(WorkspaceModel.self) private var model
    /// Opens a workspace (the Mac shows it in the browser).
    private let openWorkspace: (String) -> Void

    @State private var selection: String?
    @State private var creating = false
    @State private var addingFolder = false

    public init(open: @escaping (String) -> Void) { openWorkspace = open }

    private var manager: WorkspaceManager { model.workspaces }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !manager.canChange {
                MacSettingsStateLine("\(model.hostName) isn’t connected. Workspaces can be opened and closed, but not changed, until it is.",
                                     systemImage: "wifi.slash")
                    .accessibilityIdentifier("workspacesOffline")
            }
            content
                .frame(height: MacSettingsMetrics.listHeight)
            buttons
            MacSettingsFootnote("Each workspace is a folder on \(model.hostName). Closing one closes it on this device; removing one never deletes its files.")
        }
        .task { await manager.refresh() }
        .onChange(of: model.connectionEpoch) { _, _ in Task { await manager.refresh() } }
        .modifier(WorkspaceManagementPresentations(manager: manager, creating: $creating, addingFolder: $addingFolder,
                                                   open: openWorkspace))
        .modifier(MacWorkspaceDialogs(manager: manager, hostName: model.hostName))
        .macSettingsNoticeAlert(manager.notice) { manager.notice = nil }
    }

    @ViewBuilder private var content: some View {
        if model.projects.isEmpty {
            MacSettingsListBox {
                if let issue = model.hostIssue {
                    ContentUnavailableView {
                        Label("Couldn’t Load Workspaces", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(issue)
                    } actions: {
                        Button("Try Again") { Task { await manager.refresh() } }
                    }
                } else if model.loadingProjects || model.client == nil && !model.metadataResolved {
                    ProgressView("Loading Workspaces")
                } else {
                    ContentUnavailableView {
                        Label("No Workspaces", systemImage: "folder.badge.plus")
                    } description: {
                        Text("A workspace is a folder on \(model.hostName). Add one, or make a new one.")
                    } actions: {
                        WorkspaceAddButtons(manager: manager, creating: $creating, addingFolder: $addingFolder)
                            .labelStyle(.titleOnly)
                    }
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(manager.all) { summary in
                MacWorkspaceRow(summary: summary, busy: manager.changing.contains(summary.id))
                    .tag(summary.id)
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            if let summary = summary(ids.first) {
                WorkspaceRowMenuItems(summary: summary, row: Self.row(summary.id), manager: manager, open: openWorkspace)
            }
        } primaryAction: { ids in
            if let id = ids.first { openWorkspace(id) }
        }
        .refreshable { await manager.refresh() }
        .accessibilityIdentifier("workspacesList")
    }

    /// + and − at the leading edge, the selected workspace's actions at the trailing one.
    private var buttons: some View {
        let selected = summary(selection)
        let busy = selected.map { manager.changing.contains($0.id) } ?? true
        return HStack(spacing: 8) {
            if manager.canCreate || manager.canAdd {
                Menu {
                    WorkspaceAddButtons(manager: manager, creating: $creating, addingFolder: $addingFolder)
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!manager.canChange)
                .help("Add a workspace")
                .accessibilityLabel("Add Workspace")
                .accessibilityIdentifier("workspacesAddMenu")
            }
            if manager.canRemove {
                Button {
                    guard let selected else { return }
                    manager.questionRow = Self.row(selected.id)
                    manager.requestRemoval(selected.project)
                } label: {
                    Image(systemName: "minus").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selected == nil || busy || !manager.canChange)
                .help("Remove the selected workspace from AgentLand")
                .accessibilityLabel("Remove from AgentLand…")
                .accessibilityIdentifier("workspacesRemove")
            }
            Spacer()
            if manager.canRename {
                Button("Rename…") { if let selected { manager.requestRename(selected.project) } }
                    .disabled(selected == nil || busy || !manager.canChange)
                    .accessibilityIdentifier("workspacesRename")
            }
            Button("Close") {
                guard let selected else { return }
                manager.questionRow = Self.row(selected.id)
                Task { await manager.requestClose(selected.project) }
            }
            .disabled(selected.map { busy || !($0.openTabs > 0 || $0.isCurrent) } ?? true)
            .accessibilityIdentifier("workspacesClose")
            Button("Open") { if let selected { openWorkspace(selected.id) } }
                .disabled(selected == nil)
                .accessibilityIdentifier("workspacesOpen")
        }
    }

    private func summary(_ id: String?) -> WorkspaceSummary? {
        guard let id else { return nil }
        return manager.all.first { $0.id == id }
    }

    /// The row's name in `WorkspaceManager.questionRow`, as the shared screen names its All Workspaces rows.
    private static func row(_ id: String) -> String { "pickerProject-\(id)" }
}

/// A workspace in the Mac's list: its name, and under it the folder, Git, what runs there and its use here.
private struct MacWorkspaceRow: View {
    let summary: WorkspaceSummary
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: summary.isCurrent ? "folder.fill" : "folder")
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.project.name)
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.project.name)
        .accessibilityValue(WorkspaceRowLabel.spokenDetails(summary))
        .accessibilityAddTraits(summary.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("pickerProject-\(summary.id)")
    }

    private var details: String {
        [summary.folder, summary.project.gitRepository ? "Git" : nil, summary.activity, WorkspaceRowLabel.usage(summary)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Close's and Remove's confirmations and the busy workspace's second question, asked from the pane: on the Mac each is
/// a sheet on the Settings window, whichever row or button asked. Each button acts on the item its dialog presents.
private struct MacWorkspaceDialogs: ViewModifier {
    @Bindable var manager: WorkspaceManager
    let hostName: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog(manager.pendingClose?.title ?? "", isPresented: Binding(get: { manager.pendingClose != nil },
                                                                                        set: { if !$0 { manager.pendingClose = nil } }),
                                titleVisibility: .visible, presenting: manager.pendingClose) { request in
                Button("Close Workspace", role: request.liveTerminals > 0 || request.unsavedEditors > 0 ? .destructive : nil) {
                    Task { await manager.close(request) }
                }
                .accessibilityIdentifier("confirmCloseWorkspace")
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .confirmationDialog("Remove “\(manager.pendingRemoval?.name ?? "")” from AgentLand?",
                                isPresented: Binding(get: { manager.pendingRemoval != nil }, set: { if !$0 { manager.pendingRemoval = nil } }),
                                titleVisibility: .visible, presenting: manager.pendingRemoval) { project in
                Button("Remove from AgentLand", role: .destructive) { Task { await manager.remove(project) } }
                    .accessibilityIdentifier("confirmRemoveWorkspace")
                Button("Cancel", role: .cancel) {}
            } message: { project in
                Text(WorkspaceRowDialogs.removeMessage(folder: manager.folderText(project.directory), hostName: hostName))
            }
            .confirmationDialog(manager.busyRemoval.map(WorkspaceRowDialogs.busyTitle) ?? "",
                                isPresented: Binding(get: { manager.busyRemoval?.canEndTerminals == true },
                                                     set: { if !$0, manager.busyRemoval?.canEndTerminals == true { manager.busyRemoval = nil } }),
                                titleVisibility: .visible, presenting: manager.busyRemoval) { busy in
                Button("End Terminals and Remove", role: .destructive) { Task { await manager.remove(busy.project, endTerminals: true) } }
                    .accessibilityIdentifier("confirmEndTerminalsAndRemove")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Terminals may be open on other devices too. Their programs stop; the folder and its files stay on \(hostName).")
            }
    }
}

// MARK: Agents

/// Settings → Agents on the Mac, on hosts that list their agents (`AgentsModel`): the automatic-update switch, the
/// system's search field and the installed and available agents in a bordered list. Install, Update Now and
/// Uninstall… under the list act on the selected agent, as its context menu does; Uninstall… is offered only for
/// registry agents other than OpenCode, and a download the host cannot check asks first, as on iPhone and iPad.
public struct MacAgentsSettingsList: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var selection: String?

    public init() {}

    private var model: AgentsModel { workspace.agents }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.canConfigureAutomaticUpdates {
                Toggle("Automatically update CLI agents", isOn: Binding(get: { model.automaticUpdates ?? false }, set: { enabled in
                    Task { await model.setAutomaticUpdates(enabled) }
                }))
                .disabled(!model.canChange || model.savingAutomaticUpdates)
                .accessibilityIdentifier("agentsAutomaticUpdates")
                MacSettingsFootnote("AgentLand updates Claude Code, Codex and the other agents, even when their own automatic updates are off. It checks at most once an hour when a terminal starts one, and never keeps a terminal from starting.")
                    .padding(.leading, 20)
                    .padding(.bottom, 4)
            }
            states
            MacSearchField(text: Bindable(model).search, prompt: "Search Agents", identifier: "agentsSearch")
            content
                .frame(height: MacSettingsMetrics.listHeight)
            buttons
            if let catalog = model.catalog, !model.available.isEmpty {
                MacSettingsFootnote(catalog.automaticUpdates == nil
                    ? "From the Agent Client Protocol registry. AgentLand installs them on \(workspace.hostName) and updates them when nothing of theirs is running."
                    : "From the Agent Client Protocol registry. AgentLand installs them on \(workspace.hostName).")
            }
        }
        .macSettingsNoticeAlert(model.notice) { model.notice = nil }
        .modifier(MacAgentDialogs(model: model, hostName: workspace.hostName))
        // Read now, and every few seconds while an install, update or uninstall runs; again after each reconnect.
        .task(id: workspace.paneReadKey) { await model.follow() }
        .onChange(of: workspace.locked) { _, locked in if locked { model.dismissQuestions() } }
        .onDisappear { model.dismissQuestions() }
    }

    /// The host not answering, a read that failed after one that worked, and a registry that couldn't be read.
    @ViewBuilder private var states: some View {
        if model.catalog != nil {
            if !model.canChange {
                MacSettingsStateLine("\(workspace.hostName) isn’t connected. Agents can’t be installed, updated or uninstalled until it is.",
                                     systemImage: "wifi.exclamationmark")
                    .accessibilityIdentifier("agentsOffline")
            } else if let issue = model.loadIssue {
                HStack(alignment: .firstTextBaseline) {
                    MacSettingsStateLine("Couldn’t read the agents again. \(issue)")
                        .accessibilityIdentifier("agentsReadIssue")
                    Spacer()
                    Button("Try Again") { Task { await model.refresh() } }
                        .controlSize(.small)
                        .accessibilityIdentifier("agentsRetry")
                }
            }
        }
        if let registry = model.catalog?.registry, let error = registry.error {
            MacSettingsStateLine("The agent list couldn’t be updated. " + error
                                 + (registry.fetchedAt.map { " Last read " + WorkspaceRowLabel.relative($0) + "." } ?? ""))
                .accessibilityIdentifier("agentsRegistryIssue")
        }
    }

    @ViewBuilder private var content: some View {
        if model.catalog != nil {
            if model.installed.isEmpty && model.available.isEmpty {
                MacSettingsListBox {
                    if model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("No Agents", systemImage: "shippingbox",
                                               description: Text("\(workspace.hostName) lists no agents yet."))
                    } else {
                        ContentUnavailableView.search(text: model.search)
                    }
                }
            } else {
                list
            }
        } else {
            MacSettingsListBox {
                if let issue = model.loadIssue {
                    ContentUnavailableView {
                        Label("Couldn’t Load Agents", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(issue)
                    } actions: {
                        Button("Try Again") { Task { await model.refresh() } }
                    }
                } else if !model.canChange {
                    ContentUnavailableView("\(workspace.hostName) Isn’t Connected", systemImage: "wifi.exclamationmark",
                                           description: Text("Its agents show here once it’s connected."))
                } else {
                    ProgressView("Loading Agents")
                }
            }
        }
    }

    private var list: some View {
        let installed = model.installed
        let available = model.available
        return List(selection: $selection) {
            if !installed.isEmpty {
                Section("Installed") {
                    ForEach(installed) { agent in MacAgentRow(agent: agent, model: model, installed: true).tag(agent.id) }
                }
            }
            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { agent in MacAgentRow(agent: agent, model: model, installed: false).tag(agent.id) }
                }
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            if let agent = agent(ids.first) { menuItems(agent) }
        }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("agentsList")
    }

    /// Install (Try Again after a failed install), Update Now and Uninstall…, each enabled when the selected agent offers it.
    private var buttons: some View {
        let selected = agent(selection)
        return HStack(spacing: 8) {
            Spacer()
            Button(selected?.state == .failed && selected?.isInstalled == false ? "Try Again" : "Install") {
                if let selected { Task { await model.install(selected) } }
            }
            .disabled(selected.map { !offersInstall($0) } ?? true)
            .accessibilityIdentifier("agentInstall")
            Button("Update Now") { if let selected { Task { await model.update(selected) } } }
                .disabled(selected.map { !offers(.updateNow, $0) } ?? true)
                .accessibilityIdentifier("agentUpdateNow")
            Button("Uninstall…") { if let selected { model.requestUninstall(selected) } }
                .disabled(selected.map { !offers(.uninstall, $0) } ?? true)
                .accessibilityIdentifier("agentUninstall")
        }
    }

    @ViewBuilder private func menuItems(_ agent: AgentInfo) -> some View {
        if offersInstall(agent) {
            Button(agent.state == .failed ? "Try Again" : "Install") { Task { await model.install(agent) } }
        }
        if offers(.updateNow, agent) {
            // Once the menu has gone (`MenuAction`): the update disables these items at once.
            Button("Update Now") { MenuAction.afterDismissal { await model.update(agent) } }
        }
        if offers(.uninstall, agent) {
            Divider()
            Button("Uninstall…", role: .destructive) { model.requestUninstall(agent) }
        }
    }

    private func agent(_ id: String?) -> AgentInfo? {
        guard let id else { return nil }
        return model.installed.first { $0.id == id } ?? model.available.first { $0.id == id }
    }

    private func offersInstall(_ agent: AgentInfo) -> Bool {
        !agent.isInstalled && model.canChange && AvailableAgentRow.offersInstall(agent, canInstall: model.canInstall, busy: model.isBusy(agent))
    }

    private func offers(_ action: InstalledAgentRow.Action, _ agent: AgentInfo) -> Bool {
        agent.isInstalled && model.canChange && !model.isBusy(agent)
            && InstalledAgentRow.actions(agent, canInstall: model.canInstall).contains(action)
    }
}

/// An agent in the Mac's list: its icon, name, version and updater (installed) or license and description (available),
/// and what the host is doing with it.
private struct MacAgentRow: View {
    let agent: AgentInfo
    let model: AgentsModel
    let installed: Bool

    var body: some View {
        let pending = model.pendingText(agent)
        HStack(alignment: .top, spacing: 10) {
            AgentIconView(agent: agent, icons: model.icons)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                if installed {
                    secondary(InstalledAgentRow.versionLine(agent))
                } else {
                    if let license = agent.license { secondary(license) }
                    if let description = agent.description { secondary(description).lineLimit(2) }
                    if !agent.supported { secondary(AvailableAgentRow.unsupportedText) }
                }
                status(pending)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
        .accessibilityValue(installed ? InstalledAgentRow.spokenDetails(agent, pending: pending)
                                      : AvailableAgentRow.spokenDetails(agent, pending: pending))
        .accessibilityIdentifier("agentRow-\(agent.id)")
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    /// Installing, updating or uninstalling with a spinner; the last error in red; or when it was last updated.
    @ViewBuilder private func status(_ pending: String?) -> some View {
        if pending != nil || agent.state.isRunning {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(AgentStatusLine.text(agent, pending: pending) ?? "").font(.footnote)
            }
            .accessibilityIdentifier("agentProgress-\(agent.id)")
        } else if let error = agent.lastError {
            Label(AgentStatusLine.text(agent, pending: nil) ?? error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("agentError-\(agent.id)")
        } else if let line = AgentStatusLine.text(agent, pending: nil) {
            secondary(line)
        }
    }
}

/// The question for a download the host cannot check (Install's, or Update Now's), and Uninstall's, asked from the
/// pane: on the Mac each is a sheet on the Settings window. Each button acts on the agent its dialog presents.
private struct MacAgentDialogs: ViewModifier {
    @Bindable var model: AgentsModel
    let hostName: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog(model.pendingUnverified.map { AgentsConfirmationText.unverifiedTitle($0.agent, update: $0.isUpdate) } ?? "",
                                isPresented: Binding(get: { model.pendingUnverified != nil }, set: { if !$0 { model.pendingUnverified = nil } }),
                                titleVisibility: .visible, presenting: model.pendingUnverified) { download in
                Button(download.isUpdate ? "Update" : "Install") { Task { await model.confirmUnverified(download) } }
                    .accessibilityIdentifier(download.isUpdate ? "confirmUpdateUnverified" : "confirmInstallUnverified")
                Button("Cancel", role: .cancel) {}
            } message: { download in
                Text(AgentsConfirmationText.unverifiedMessage(download.agent, hostName: hostName, update: download.isUpdate))
            }
            .confirmationDialog("Uninstall \(model.pendingUninstall?.name ?? "")?",
                                isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } }),
                                titleVisibility: .visible, presenting: model.pendingUninstall) { agent in
                Button("Uninstall", role: .destructive) { Task { await model.uninstall(agent) } }
                    .accessibilityIdentifier("confirmUninstallAgent")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(AgentsConfirmationText.uninstallMessage(hostName: hostName))
            }
    }
}
#endif
