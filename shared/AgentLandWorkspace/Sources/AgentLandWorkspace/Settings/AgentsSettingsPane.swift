import SwiftUI
import AgentLandCore
import AgentLandDesign

/// Settings → Agents, for iPhone, iPad and the Mac, on hosts that list their agents (`AgentsModel`). A search
/// field (the system's in the page's navigation bar on iPhone and iPad) over two lists:
/// - **Installed**: name, version, who updates it, the last update or its error, and Update Now for registry
///   agents and local CLIs with a supported self-updater. Uninstall… is offered only for registry agents
///   other than OpenCode (the … menu, context menu, swipe and VoiceOver actions share these rules).
/// - **Available**: name, license, description and Install; OpenCode too, before the host's first install of
///   it. A download the host cannot check asks first, naming the website it comes from; so does Update Now
///   when the registry moved an agent to such a download.
/// Installs, updates and uninstalls show their progress while the host works on them (the list is read every
/// few seconds meanwhile). Icons come through the host.
public struct AgentsSettingsPane: View {
    @Environment(WorkspaceModel.self) private var workspace
    /// iPhone and iPad's Settings → Agents & Providers: the row that opens AI Providers, first in the list.
    private let providersRow: AnyView?

    public init() { providersRow = nil }

    /// With `providersRow` first in the list (iPhone and iPad's Agents & Providers).
    public init<Row: View>(@ViewBuilder providersRow: () -> Row) { self.providersRow = AnyView(providersRow()) }

    private var model: AgentsModel { workspace.agents }

    public var body: some View {
        page
            .groupedPageBackground()
            #if os(macOS)
            .overlay(alignment: .top) { noticeView }
            #endif
            // A failed change in the system's alert on iPhone and iPad; a plain success shows in its row.
            .settingsNoticeAlert(model.notice) { model.notice = nil }
            // Read now, and every few seconds while an install, update or uninstall runs; again after each reconnect.
            .task(id: workspace.paneReadKey) { await model.follow() }
            .onChange(of: workspace.locked) { _, locked in if locked { model.dismissQuestions() } }
            .onDisappear { model.dismissQuestions() }
            .agentLandHaptic(.success, trigger: model.notice) { _, notice in notice?.tone == .success }
            .agentLandHaptic(.warning, trigger: model.notice) { _, notice in notice.map { $0.tone != .success } ?? false }
    }

    /// The lists under the search field: on iPhone and iPad the system's, in the page's navigation bar (it stays shown);
    /// on the Mac the pane's own over the list.
    @ViewBuilder private var page: some View {
        #if os(iOS)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: Bindable(model).search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search Agents")
        #else
        VStack(spacing: 0) {
            AgentsSearchField(text: Bindable(model).search)
                .padding(.horizontal, AgentLandSpacing.medium)
                .padding(.top, AgentLandSpacing.small)
                .padding(.bottom, AgentLandSpacing.xSmall)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let catalog = model.catalog {
            list(catalog)
        } else if let issue = model.loadIssue {
            ContentUnavailable("Couldn’t Load Agents", systemImage: "exclamationmark.triangle", description: issue,
                               actionTitle: "Try Again") { Task { await model.refresh() } }
        } else if !model.canChange {
            ContentUnavailable("\(workspace.hostName) Isn’t Connected", systemImage: "wifi.exclamationmark",
                               description: "Its agents show here once it’s connected.")
        } else {
            ProgressView("Loading Agents")
        }
    }

    private func list(_ catalog: AgentCatalog) -> some View {
        let installed = model.installed
        let available = model.available
        let searching = !model.search.trimmingCharacters(in: .whitespaces).isEmpty
        return List {
            // States in place, as their own sections (2026-10-06).
            if !model.canChange {
                SettingsStatusSection("\(workspace.hostName) isn’t connected", systemImage: "wifi.exclamationmark",
                                      message: "Agents can’t be installed, updated or uninstalled until it is.",
                                      identifier: "agentsOffline")
            } else if let issue = model.loadIssue {
                // The list shown is from the last read that worked.
                SettingsStatusSection("Couldn’t read the agents again", systemImage: "exclamationmark.triangle", message: issue,
                                      identifier: "agentsReadIssue", actionTitle: "Try Again", actionIdentifier: "agentsRetry") {
                    Task { await model.refresh() }
                }
            }
            if let error = catalog.registry?.error {
                SettingsStatusSection("The agent list couldn’t be updated", systemImage: "exclamationmark.triangle",
                                      message: registryMessage(error, fetchedAt: catalog.registry?.fetchedAt),
                                      identifier: "agentsRegistryIssue")
            }
            // A search shows its results first: the providers row and the update switch wait until it is cleared (in
            // the Settings popover above the keyboard, they would push the results out of view).
            if let providersRow, !searching {
                Section {
                    providersRow
                        .listRowFill(.surface)
                } footer: {
                    Text("The model providers OpenCode uses on \(workspace.hostName).")
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            if model.canConfigureAutomaticUpdates, !searching {
                Section {
                    Toggle(isOn: Binding(get: { model.automaticUpdates ?? false }, set: { enabled in
                        Task { await model.setAutomaticUpdates(enabled) }
                    })) {
                        Text("Automatically update CLI agents").agentLandFont(.body)
                    }
                    .listRowFill(.surface)
                    .disabled(!model.canChange || model.savingAutomaticUpdates)
                    .accessibilityIdentifier("agentsAutomaticUpdates")
                } footer: {
                    Text("AgentLand updates Claude Code, Codex and the other agents, even when their own automatic updates are off. It checks at most once an hour when a terminal starts one, and never keeps a terminal from starting.")
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            if !installed.isEmpty {
                Section {
                    ForEach(installed) { agent in
                        InstalledAgentRow(agent: agent, model: model)
                            .modifier(AgentRowDialogs(agent: agent, model: model, hostName: workspace.hostName))
                    }
                } header: {
                    Text("Installed")
                }
            }
            if !available.isEmpty {
                Section {
                    ForEach(available) { agent in
                        AvailableAgentRow(agent: agent, model: model)
                            .modifier(AgentRowDialogs(agent: agent, model: model, hostName: workspace.hostName))
                    }
                } header: {
                    Text("Available")
                } footer: {
                    Text(catalog.automaticUpdates == nil ? "From the Agent Client Protocol registry. AgentLand installs them on \(workspace.hostName) and updates them when nothing of theirs is running." : "From the Agent Client Protocol registry. AgentLand installs them on \(workspace.hostName).")
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            if installed.isEmpty && available.isEmpty {
                Group {
                    if model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailable("No Agents", systemImage: "shippingbox", description: "\(workspace.hostName) lists no agents yet.")
                    } else {
                        ContentUnavailable.search(text: model.search)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .hidesListPageBackground()
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("agentsList")
    }

    private func registryMessage(_ error: String, fetchedAt: Date?) -> String {
        guard let fetchedAt else { return error }
        return error + " Last read " + WorkspaceRowLabel.relative(fetchedAt) + "."
    }

    // MARK: Notice

    #if os(macOS)
    /// The Mac's notice over the page: a confirmation goes away by itself, warnings and errors wait for the person.
    @ViewBuilder private var noticeView: some View {
        if let notice = model.notice {
            InlineNotice(notice.title, message: notice.message, tone: tone(notice.tone), onDismiss: { model.notice = nil },
                         identifiers: .init(text: "agentsNotice", dismiss: "agentsNoticeDismiss"))
                .frame(maxWidth: 520)
                .padding(.horizontal, AgentLandSpacing.small)
                .padding(.top, AgentLandSpacing.xSmall)
                .task(id: notice.id) {
                    // A confirmation goes away by itself; warnings and errors wait for the person.
                    guard notice.tone == .success else { return }
                    try? await Task.sleep(for: .seconds(6))
                    if model.notice?.id == notice.id { model.notice = nil }
                }
        }
    }

    private func tone(_ tone: WorkspaceNotice.Tone) -> InlineNotice.Tone {
        switch tone {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
    #endif
}

// MARK: Search

/// The Mac pane's search field: a text field with its symbol and a clear button, at least the minimum tap
/// target tall. (iPhone and iPad use the system's search field in the page's navigation bar.)
struct AgentsSearchField: View {
    @Binding var text: String
    var prompt = "Search Agents"
    var identifier = "agentsSearch"

    var body: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(AgentLandTypeRole.body.font)
                .foregroundStyle(AgentLandColor.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .agentLandFont(.body)
                .foregroundStyle(AgentLandColor.text)
                .autocorrectionDisabled()
                .workspaceNoAutocapitalization()
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AgentLandTypeRole.body.font)
                        .foregroundStyle(AgentLandColor.glyphTertiary)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, AgentLandSpacing.small)
        .frame(minHeight: AgentLandTapTarget.platformMinimum)
        .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.chip))
        .overlay(AgentLandRadius.shape(AgentLandRadius.chip).strokeBorder(AgentLandColor.separator, lineWidth: 0.5))
    }
}

// MARK: Rows

/// An installed agent: its icon, name and version, who updates it, and the last update or its error; while
/// an update runs, its progress. Supported local CLIs have Update Now. Registry agents also have Uninstall… except OpenCode, which
/// AgentLand's chats need.
struct InstalledAgentRow: View {
    let agent: AgentInfo
    let model: AgentsModel

    /// What the row's … menu, context menu, swipe and VoiceOver actions offer.
    enum Action: Hashable { case updateNow, uninstall }

    /// Updatable agents on hosts that take changes have Update Now, and Uninstall… when AgentLand can remove
    /// them (`AgentInfo.canUninstall`: never OpenCode). Every way into the row offers the same.
    static func actions(_ agent: AgentInfo, canInstall: Bool) -> [Action] {
        guard canInstall, agent.canUpdate else { return [] }
        return agent.canUninstall ? [.updateNow, .uninstall] : [.updateNow]
    }

    private var busy: Bool { model.isBusy(agent) }
    private var actions: [Action] { Self.actions(agent, canInstall: model.canInstall) }

    var body: some View {
        AgentRowLayout(icon: AgentIconView(agent: agent, icons: model.icons), details: details) {
            if !actions.isEmpty { menu }
        }
        .listRowFill(.surface, separator: true)
        .contextMenu { if !actions.isEmpty { menuItems } }
        #if os(iOS)
        // Not a destructive role: the row stays until the person confirms.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.contains(.uninstall) {
                Button { model.requestUninstall(agent) } label: { Label("Uninstall", systemImage: "trash") }
                    .tint(.red)
                    .disabled(busy)
            }
        }
        #endif
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
            Text(agent.name)
                .agentLandFont(.bodyEmphasized)
                .foregroundStyle(AgentLandColor.text)
            Text(Self.versionLine(agent))
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
            AgentStatusLine(agent: agent, pending: model.pendingText(agent))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
        .accessibilityValue(Self.spokenDetails(agent, pending: model.pendingText(agent)))
        .modifier(InstalledAgentAccessibilityActions(agent: agent, model: model, actions: busy ? [] : actions))
        .accessibilityIdentifier("agentRow-\(agent.id)")
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            SettingsMenuLabel()
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(agent.name)")
        .accessibilityIdentifier("agentMenu-\(agent.id)")
    }

    @ViewBuilder private var menuItems: some View {
        // Once the menu has gone (`MenuAction`): the update disables these items at once.
        Button("Update Now", systemImage: "arrow.down.circle") { MenuAction.afterDismissal { await model.update(agent) } }
            .disabled(busy || !model.canChange)
            .accessibilityIdentifier("agentUpdateNow")
        if actions.contains(.uninstall) {
            Divider()
            Button("Uninstall…", systemImage: "trash", role: .destructive) { model.requestUninstall(agent) }
                .disabled(busy || !model.canChange)
                .accessibilityIdentifier("agentUninstall")
        }
    }

    /// "Version 0.61.0 · Updates automatically", with a newer version when the registry has one.
    static func versionLine(_ agent: AgentInfo) -> String {
        var parts: [String] = []
        if let version = agent.installedVersion {
            if let latest = agent.latestVersion, latest != version, agent.isManaged {
                parts.append("Version \(version) (\(latest) available)")
            } else {
                parts.append("Version \(version)")
            }
        }
        parts.append(updater(agent))
        if let waiting = agent.updateWaitingTerminals, waiting > 0 {
            parts.append(waiting == 1 ? "Update waiting: 1 terminal using it" : "Update waiting: \(waiting) terminals using it")
        }
        return parts.joined(separator: " · ")
    }

    /// Who keeps the agent current. Hosts list OpenCode as a registry agent; only an older host's OpenCode
    /// from inside the Mac app is `bundled`.
    static func updater(_ agent: AgentInfo) -> String {
        switch agent.source {
        case .registry: agent.supportsUpdates != nil && !agent.autoUpdates ? "Automatic updates off" : "Updates automatically"
        case .local: agent.autoUpdates ? "Updates automatically" : (agent.supportsUpdates == true ? "Automatic updates off" : "Updated by its own installer")
        case .bundled: "Updated by AgentLand"
        case .other: "Updated outside AgentLand"
        }
    }

    /// What VoiceOver reads after the name.
    static func spokenDetails(_ agent: AgentInfo, pending: String?) -> String {
        [versionLine(agent), AgentStatusLine.text(agent, pending: pending)].compactMap { $0 }.joined(separator: ", ")
    }
}

/// An agent AgentLand can install: its icon, name, license and description, and Install; while it
/// installs, its progress; after a failed install, the host's error. One the registry has nothing for this
/// Mac says so instead of offering Install.
struct AvailableAgentRow: View {
    let agent: AgentInfo
    let model: AgentsModel

    /// What a row of an agent with nothing for this Mac says in place of Install.
    static let unsupportedText = "Not available for this Mac"

    private var busy: Bool { model.isBusy(agent) }

    var body: some View {
        AgentRowLayout(icon: AgentIconView(agent: agent, icons: model.icons), details: details) {
            if Self.offersInstall(agent, canInstall: model.canInstall, busy: busy) { installButton }
        }
        .listRowFill(.surface, separator: true)
    }

    /// Install shows for hosts that take it, while nothing runs for the agent, and only when the registry has
    /// something for this Mac.
    static func offersInstall(_ agent: AgentInfo, canInstall: Bool, busy: Bool) -> Bool {
        canInstall && !busy && agent.supported
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
            Text(agent.name)
                .agentLandFont(.bodyEmphasized)
                .foregroundStyle(AgentLandColor.text)
            if let license = agent.license {
                Text(license)
                    .agentLandFont(.caption)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
            if let description = agent.description {
                Text(description)
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .lineLimit(4)
            }
            if !agent.supported {
                Text(Self.unsupportedText)
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
            AgentStatusLine(agent: agent, pending: model.pendingText(agent))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
        .accessibilityValue(Self.spokenDetails(agent, pending: model.pendingText(agent)))
        .accessibilityIdentifier("agentRow-\(agent.id)")
    }

    private var installButton: some View {
        Button { Task { await model.install(agent) } } label: {
            Text(agent.state == .failed ? "Try Again" : "Install")
                .agentLandFont(.bodyEmphasized)
                .minimumTapTarget()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!model.canChange)
        .fixedSize()
        .accessibilityLabel(agent.state == .failed ? "Try installing \(agent.name) again" : "Install \(agent.name)")
        .accessibilityIdentifier("agentInstall-\(agent.id)")
    }

    static func spokenDetails(_ agent: AgentInfo, pending: String?) -> String {
        [agent.license.map { "License \($0)" }, agent.description, agent.supported ? nil : unsupportedText,
         AgentStatusLine.text(agent, pending: pending)]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// An agent row: its icon, the text beside it and the row's control (the … menu, Install) at the end. At
/// accessibility text sizes the icon and the control share the first line and the text takes the row's
/// whole width under them. The separator starts where the text does.
struct AgentRowLayout<Icon: View, Details: View, Control: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let icon: Icon
    let details: Details
    @ViewBuilder let control: () -> Control

    init(icon: Icon, details: Details, @ViewBuilder control: @escaping () -> Control) {
        self.icon = icon
        self.details = details
        self.control = control
    }

    var body: some View {
        AgentRowArrangement(stacked: typeSize.isAccessibilitySize, spacing: AgentLandSpacing.small,
                            lineSpacing: AgentLandSpacing.xSmall) {
            icon
            details
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            control()
        }
        .padding(.vertical, AgentLandSpacing.xSmall)
        .frame(minHeight: AgentLandTapTarget.platformMinimum)
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }
}

/// Places a row's icon, text and optional control: in one line, top-aligned, the text taking the width
/// between them; or stacked, the icon and the control centered on the first line and the text under them
/// at the full width. The same subviews either way, so each keeps its identity when the text size
/// changes: a stack swapped for another makes new views, which VoiceOver loses and the Dynamic Type audit
/// reports as not growing.
struct AgentRowArrangement: Layout {
    var stacked: Bool
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Frames {
        var icon: CGRect
        var text: CGRect
        var control: CGRect?
        var size: CGSize
    }

    private func frames(width: CGFloat?, subviews: Subviews) -> Frames {
        guard subviews.count >= 2 else { return Frames(icon: .zero, text: .zero, control: nil, size: .zero) }
        let icon = subviews[0].sizeThatFits(.unspecified)
        let control = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : nil
        if stacked {
            let line = max(icon.height, control?.height ?? 0)
            let text = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let rowWidth = width ?? max(icon.width + (control.map { spacing + $0.width } ?? 0), text.width)
            return Frames(icon: CGRect(x: 0, y: (line - icon.height) / 2, width: icon.width, height: icon.height),
                          text: CGRect(x: 0, y: line + lineSpacing, width: rowWidth, height: text.height),
                          control: control.map { CGRect(x: rowWidth - $0.width, y: (line - $0.height) / 2, width: $0.width, height: $0.height) },
                          size: CGSize(width: rowWidth, height: line + lineSpacing + text.height))
        }
        let beside = icon.width + spacing + (control.map { $0.width + spacing } ?? 0)
        let text = subviews[1].sizeThatFits(ProposedViewSize(width: width.map { max($0 - beside, 0) }, height: nil))
        let rowWidth = width ?? beside + text.width
        return Frames(icon: CGRect(origin: .zero, size: icon),
                      text: CGRect(x: icon.width + spacing, y: 0, width: max(rowWidth - beside, 0), height: text.height),
                      control: control.map { CGRect(x: rowWidth - $0.width, y: 0, width: $0.width, height: $0.height) },
                      size: CGSize(width: rowWidth, height: max(icon.height, text.height, control?.height ?? 0)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, subviews: subviews)
        func place(_ index: Int, _ frame: CGRect) {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
        guard subviews.count >= 2 else { return }
        place(0, frames.icon)
        place(1, frames.text)
        if subviews.count > 2, let control = frames.control { place(2, control) }
    }
}

/// What the host is doing with an agent now, or how its last change went: installing, updating or
/// uninstalling with a spinner, the last error in the danger color, or when it was last updated.
struct AgentStatusLine: View {
    let agent: AgentInfo
    /// What this device waits for on the agent (`AgentsModel.pendingText`): its change on its way, or an
    /// uninstall the host is doing.
    let pending: String?

    var body: some View {
        if pending != nil || agent.state.isRunning {
            HStack(spacing: AgentLandSpacing.xxSmall) {
                ProgressView().controlSize(.small)
                Text(Self.text(agent, pending: pending) ?? "")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.text)
            }
            .accessibilityIdentifier("agentProgress-\(agent.id)")
        } else if let error = agent.lastError {
            Label {
                Text(Self.text(agent, pending: nil) ?? error)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            }
            .agentLandFont(.metadata)
            .foregroundStyle(AgentLandColor.danger)
            .accessibilityIdentifier("agentError-\(agent.id)")
        } else if let line = Self.text(agent, pending: nil) {
            Text(line)
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
        }
    }

    /// The status in words, or nil when there is nothing to say.
    static func text(_ agent: AgentInfo, pending: String?) -> String? {
        switch agent.state {
        case .installing: return "Installing…"
        case .updating: return agent.latestVersion.map { "Updating to \($0)…" } ?? "Updating…"
        case .uninstalling: return "Uninstalling…"
        default: break
        }
        if let pending { return pending }
        if let error = agent.lastError {
            return agent.isInstalled ? "Last update failed: \(error)" : "Install failed: \(error)"
        }
        if agent.isInstalled, let updatedAt = agent.updatedAt {
            let action = agent.source == .local && (agent.supportsUpdates ?? agent.autoUpdates) ? "Checked for updates " : "Updated "
            return action + WorkspaceRowLabel.relative(updatedAt)
        }
        return nil
    }
}

/// VoiceOver's actions on an installed agent: what its menu offers, none while a change of it runs.
private struct InstalledAgentAccessibilityActions: ViewModifier {
    let agent: AgentInfo
    let model: AgentsModel
    let actions: [InstalledAgentRow.Action]

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if actions.contains(.updateNow) {
                Button("Update Now") { Task { await model.update(agent) } }
            }
            if actions.contains(.uninstall) {
                Button("Uninstall") { model.requestUninstall(agent) }
            }
        }
    }
}

// MARK: Questions

/// The confirmations' words.
enum AgentsConfirmationText {
    /// The website the agent comes from, as the registry lists it.
    static func source(_ agent: AgentInfo) -> String { agent.websiteName ?? "an unlisted website" }

    /// "Install Cursor from cursor.com?"; for Update Now, "Update Cursor from cursor.com?".
    static func unverifiedTitle(_ agent: AgentInfo, update: Bool = false) -> String {
        "\(update ? "Update" : "Install") \(agent.name) from \(source(agent))?"
    }

    static func unverifiedMessage(_ agent: AgentInfo, hostName: String, update: Bool = false) -> String {
        "The registry lists no checksum for this download, so AgentLand on \(hostName) can’t check it. "
            + "\(update ? "Update" : "Install") it only if you trust \(source(agent))."
    }

    static func uninstallMessage(hostName: String) -> String {
        "AgentLand removes it from \(hostName). You can install it again later."
    }
}

/// The question for a download the host cannot check (Install's, or Update Now's), and Uninstall's, on the agent's
/// row so each points at it (owner, 2026-10-08; `DialogAnchor`); only that agent's row presents them. Each button acts
/// on the agent its dialog presents.
private struct AgentRowDialogs: ViewModifier {
    let agent: AgentInfo
    @Bindable var model: AgentsModel
    let hostName: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog(model.pendingUnverified.map { AgentsConfirmationText.unverifiedTitle($0.agent, update: $0.isUpdate) } ?? "",
                                isPresented: unverifiedShown, titleVisibility: .visible, presenting: model.pendingUnverified) { download in
                Button(download.isUpdate ? "Update" : "Install") { Task { await model.confirmUnverified(download) } }
                    .accessibilityIdentifier(download.isUpdate ? "confirmUpdateUnverified" : "confirmInstallUnverified")
                Button("Cancel", role: .cancel) {}
            } message: { download in
                Text(AgentsConfirmationText.unverifiedMessage(download.agent, hostName: hostName, update: download.isUpdate))
            }
            .confirmationDialog("Uninstall \(model.pendingUninstall?.name ?? "")?", isPresented: uninstallShown, titleVisibility: .visible,
                                presenting: model.pendingUninstall) { agent in
                Button("Uninstall", role: .destructive) { Task { await model.uninstall(agent) } }
                    .accessibilityIdentifier("confirmUninstallAgent")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(AgentsConfirmationText.uninstallMessage(hostName: hostName))
            }
    }

    private var unverifiedShown: Binding<Bool> {
        Binding(get: { model.pendingUnverified?.agent.id == agent.id },
                set: { if !$0, model.pendingUnverified?.agent.id == agent.id { model.pendingUnverified = nil } })
    }
    private var uninstallShown: Binding<Bool> {
        Binding(get: { model.pendingUninstall?.id == agent.id },
                set: { if !$0, model.pendingUninstall?.id == agent.id { model.pendingUninstall = nil } })
    }
}
