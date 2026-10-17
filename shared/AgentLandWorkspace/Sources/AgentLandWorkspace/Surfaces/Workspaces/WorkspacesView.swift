import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The Workspaces screen, for hosts that list their workspaces' details (`WorkspaceManager.isAvailable`):
/// **Open** (the workspaces with tabs on this device, the one in use first) and **All Workspaces**. A row
/// shows the name, the folder under `~`, a Git badge, what runs there and when it was last used on this
/// device. Open, Rename…, Close and Remove from AgentLand… are on each row: a tap opens it; the context
/// menu, the row's … menu, swipes on iPhone and iPad and VoiceOver's actions carry the rest. New
/// Workspace… and Add Folder… are in the toolbar (at the foot on the Mac). Hosts without the feature
/// keep the plain picker.
public struct WorkspacesView: View {
    @Environment(WorkspaceModel.self) private var model
    /// Opens a workspace: the shell shows it (and closes its sheet).
    private let openWorkspace: (String) -> Void
    /// The sheet's Done; nil where the screen is not a sheet (the Mac's Settings).
    private let done: (() -> Void)?

    @State private var creating = false
    @State private var addingFolder = false

    /// - Parameters:
    ///   - open: shows the workspace with that ID. The screen has opened nothing itself.
    ///   - done: closes the screen when it is a sheet.
    public init(open: @escaping (String) -> Void, done: (() -> Void)? = nil) {
        openWorkspace = open
        self.done = done
    }

    private var manager: WorkspaceManager { model.workspaces }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .groupedPageBackground()
            .overlay(alignment: .top) { WorkspaceManagerNotice(manager: manager) }
            .navigationTitle("Workspaces")
            .workspaceInlineNavigationTitle()
            .toolbar { toolbar }
            #if os(macOS)
            .safeAreaInset(edge: .bottom) { macFooter }
            #endif
            .task { await manager.refresh() }
            .onChange(of: model.connectionEpoch) { _, _ in Task { await manager.refresh() } }
            .modifier(WorkspaceManagementPresentations(manager: manager, creating: $creating, addingFolder: $addingFolder,
                                                       open: openWorkspace))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.projects.isEmpty {
            if let issue = model.hostIssue {
                ContentUnavailable("Couldn’t Load Workspaces", systemImage: "exclamationmark.triangle", description: issue,
                                   actionTitle: "Try Again") { Task { await manager.refresh() } }
            } else if model.loadingProjects || model.client == nil && !model.metadataResolved {
                #if os(iOS)
                ProgressView("Loading Workspaces")
                #else
                ProgressView { Text("Loading Workspaces").agentLandFont(.secondary) }
                    .foregroundStyle(AgentLandColor.textSecondary)
                #endif
            } else {
                ContentUnavailable("No Workspaces", systemImage: "folder.badge.plus",
                                   description: "A workspace is a folder on \(model.hostName). Add one, or make a new one.") {
                    if manager.canCreate { Button("New Workspace…") { creating = true }.buttonStyle(.agentLandPrimary) }
                    if manager.canAdd { Button("Add Folder…") { addingFolder = true } }
                }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !manager.canChange {
                // Offline: the state in place, its own section (WS-5); the Mac keeps its notice.
                #if os(iOS)
                SettingsStatusSection("\(model.hostName) isn’t connected", systemImage: "wifi.slash",
                                      message: "Workspaces can be opened and closed, but not changed, until it is.",
                                      identifier: "workspacesOffline")
                #else
                InlineNotice("\(model.hostName) isn’t connected", message: "Workspaces can be opened and closed, but not changed, until it is.",
                             tone: .warning, identifiers: .init(text: "workspacesOffline"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                #endif
            }
            let open = manager.open
            if !open.isEmpty {
                Section {
                    ForEach(open) { summary in row(summary, identifier: "workspaceOpenRow-\(summary.id)") }
                } header: {
                    Text("Open")
                }
            }
            Section {
                ForEach(manager.all) { summary in row(summary, identifier: "pickerProject-\(summary.id)") }
            } header: {
                Text("All Workspaces")
            } footer: {
                // The system's footer on iPhone and iPad (WS-9).
                Text("Each workspace is a folder on \(model.hostName). Closing one closes it on this device; removing one never deletes its files.")
                    #if os(macOS)
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    #endif
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .hidesListPageBackground()
        .refreshable { await manager.refresh() }
        .accessibilityIdentifier("workspacesList")
    }

    /// One workspace's row: a tap opens it; its other actions are in the context menu, the … menu, the
    /// swipes and VoiceOver's actions.
    private func row(_ summary: WorkspaceSummary, identifier: String) -> some View {
        let busy = manager.changing.contains(summary.id)
        return HStack(spacing: 0) {
            Button { openWorkspace(summary.id) } label: {
                WorkspaceRowLabel(summary: summary, busy: busy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .workspaceRowHover()
            // On the button itself (no element around it), so it stays a button with these.
            .accessibilityLabel(summary.project.name)
            .accessibilityValue(WorkspaceRowLabel.spokenDetails(summary))
            .accessibilityHint("Opens the workspace.")
            .accessibilityAddTraits(summary.isCurrent ? .isSelected : [])
            .modifier(WorkspaceRowAccessibilityActions(summary: summary, row: identifier, manager: manager))
            .accessibilityIdentifier(identifier)

            // A row menu as Settings draws one: `ellipsis.circle` in the accent on iPhone and iPad (WS-7).
            Menu {
                WorkspaceRowMenuItems(summary: summary, row: identifier, manager: manager, open: openWorkspace)
            } label: {
                SettingsMenuLabel()
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(summary.project.name)")
            .accessibilityIdentifier("workspaceMenu-\(identifier)")
        }
        .listRowFill(.surface, separator: true)
        .contextMenu { WorkspaceRowMenuItems(summary: summary, row: identifier, manager: manager, open: openWorkspace) }
        .modifier(WorkspaceRowSwipeActions(summary: summary, row: identifier, manager: manager))
        // Close's and Remove's questions point at this row when it asked them (an open workspace is listed twice).
        .modifier(WorkspaceRowDialogs(summary: summary, row: identifier, manager: manager, hostName: model.hostName))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let done {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: done).accessibilityIdentifier("workspacesDone")
            }
        }
        #if os(iOS)
        if manager.canCreate || manager.canAdd {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    addButtons
                } label: {
                    Label("Add Workspace", systemImage: "plus")
                }
                .disabled(!manager.canChange)
                .accessibilityIdentifier("workspacesAddMenu")
            }
        }
        #endif
    }

    private var addButtons: some View {
        WorkspaceAddButtons(manager: manager, creating: $creating, addingFolder: $addingFolder)
    }

    #if os(macOS)
    /// On the Mac the actions sit under the list, as in the other Settings panes.
    @ViewBuilder private var macFooter: some View {
        if manager.canCreate || manager.canAdd {
            HStack(spacing: AgentLandSpacing.xSmall) {
                Spacer()
                addButtons.labelStyle(.titleOnly)
            }
            .disabled(!manager.canChange)
            .padding(AgentLandSpacing.small)
            .groupedPageBackground()
            .workspaceHairline(.top)
        }
    }
    #endif
}

// MARK: Row

/// A workspace row's text: the name with a Git badge, the folder, what runs there, and its use on this
/// device.
struct WorkspaceRowLabel: View {
    let summary: WorkspaceSummary
    let busy: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small) {
            Image(systemName: summary.isCurrent ? "folder.fill" : "folder")
                .font(AgentLandTypeRole.body.font)
                .foregroundStyle(AgentLandColor.tint)
                .agentLandIconFrame(.regular)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.xSmall) {
                    Text(summary.project.name)
                        .agentLandFont(.bodyEmphasized)
                        .foregroundStyle(AgentLandColor.text)
                        .multilineTextAlignment(.leading)
                    if summary.project.gitRepository { Badge("Git") }
                }
                if let folder = summary.folder {
                    Text(folder)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let activity = summary.activity {
                    Label(activity, systemImage: "circle.fill")
                        .labelStyle(WorkspaceActivityLabelStyle())
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.text)
                }
                if let usage = Self.usage(summary) {
                    Text(usage)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else if summary.isCurrent {
                Image(systemName: "checkmark")
                    .font(AgentLandTypeRole.body.font.weight(.semibold))
                    .foregroundStyle(AgentLandColor.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, AgentLandSpacing.xSmall)
        .frame(minHeight: AgentLandTapTarget.platformMinimum)
    }

    /// "In use · 3 tabs open", "Last used yesterday", or nil for a workspace never used here.
    static func usage(_ summary: WorkspaceSummary, now: Date = Date()) -> String? {
        var parts: [String] = []
        if summary.isCurrent {
            parts.append("In use")
        } else if let lastUsed = summary.lastUsed {
            parts.append("Last used " + relative(lastUsed, now: now))
        }
        if summary.openTabs > 0 { parts.append(summary.openTabs == 1 ? "1 tab open" : "\(summary.openTabs) tabs open") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// What VoiceOver reads after the name: the folder, Git, activity and use.
    static func spokenDetails(_ summary: WorkspaceSummary) -> String {
        [summary.folder, summary.project.gitRepository ? "Git repository" : nil, summary.activity, usage(summary)]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// The activity line's small dot in the success color, then its words.
private struct WorkspaceActivityLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.xxSmall) {
            configuration.icon
                .font(AgentLandTypeRole.caption2.font)
                .foregroundStyle(AgentLandColor.success)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
