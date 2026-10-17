import SwiftUI
import AgentLandCore
import AgentLandDesign

/// A tab kind's symbol in the workspace switcher, Resume Work and the title menus.
func tabIcon(_ kind: WorkspaceTabKind) -> String {
    switch kind {
    case .home: "house"
    case .chat: "bubble.left.and.bubble.right"
    case .terminal: "terminal"
    case .files: "folder"
    case .editor: "doc.text"
    case .browser: "globe"
    case .git: "arrow.triangle.branch"
    }
}

/// "Workspace: X" once a workspace is open, "No workspace open" while the host has some to choose; none under a
/// plain chat, which belongs to no workspace.
@MainActor func workspaceLine(_ model: WorkspaceModel) -> String? {
    if let tab = model.currentTab, model.isPlainChat(tab) { return nil }
    if let project = model.currentProject { return "Workspace: \(project.name)" }
    return model.projects.isEmpty ? nil : "No workspace open"
}

/// The identifier of the workspace line: `currentWorkspace`, or `noWorkspace` before one is chosen.
@MainActor func workspaceLineIdentifier(_ model: WorkspaceModel) -> String {
    model.currentProject == nil ? "noWorkspace" : "currentWorkspace"
}

/// What the shell does for its surfaces: sheets, search, creation and navigation. The surfaces and
/// Resume Work call it; the shell owns the state behind it.
struct WorkspaceShellActions {
    /// Opens the complete Home / Chats / workspaces / tabs picker from the centered bar control.
    var openNavigator: @MainActor () -> Void = {}
    var openPicker: @MainActor () -> Void = {}
    var createWorkspace: @MainActor () -> Void = {}
    var openHomeWorkspacePicker: @MainActor () -> Void = {}
    var showSettings: @MainActor () -> Void = {}
    var showGit: @MainActor () -> Void = {}
    var showArchive: @MainActor (_ terminals: Bool) -> Void = { _ in }
    /// Brings up searchable Resume Work history.
    var focusSearch: @MainActor () -> Void = {}
    /// Opens a chat or terminal of the library as Resume Work does: its tab again, or the archive's copy of a chat.
    var openRecent: @MainActor (SidebarItem) -> Void = { _ in }
    /// Runs the action once a workspace is open, asking for one first when none is.
    var withWorkspace: @MainActor (_ action: @escaping @MainActor () -> Void) -> Void = { $0() }
    var newTerminal: @MainActor (TerminalProgram) -> Void = { _ in }
    /// Starts a general-purpose chat after asking for a workspace when none is open.
    var startNewChat: @MainActor () -> Void = {}
    /// Starts Chat with a provider chosen from a native launch menu.
    var newPlainChat: @MainActor (AgentProvider) -> Void = { _ in }
    /// A new terminal, asking which program when the host offers more than one.
    var chooseNewTerminal: @MainActor () -> Void = {}
    var browseFiles: @MainActor () -> Void = {}
    /// A new browser tab, on hosts that serve previews.
    var newBrowserTab: @MainActor () -> Void = {}
    /// Compatibility hook for navigation callers; the full-width shell already shows its detail.
    var showDetail: @MainActor () -> Void = {}
    /// UI-test runs only (`workspaceUITestHooks`): list what VoiceOver reaches, and build every surface
    /// view again. Both are the last items of the title menu there.
    var debugListVoiceOverElements: @MainActor () -> Void = {}
    var debugRebuildSurfaces: @MainActor () -> Void = {}
}

private struct WorkspaceSurfaceTabIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The tab a mounted surface shows (nil for the permanent Home), set by the shell where it mounts the surface.
    var workspaceSurfaceTabID: UUID? {
        get { self[WorkspaceSurfaceTabIDKey.self] }
        set { self[WorkspaceSurfaceTabIDKey.self] = newValue }
    }
}

private struct WorkspaceShellActionsKey: EnvironmentKey {
    static var defaultValue: WorkspaceShellActions { WorkspaceShellActions() }
}

extension EnvironmentValues {
    var workspaceShell: WorkspaceShellActions {
        get { self[WorkspaceShellActionsKey.self] }
        set { self[WorkspaceShellActionsKey.self] = newValue }
    }
}

extension View {
    /// The shared centered workspace switcher and the trailing menu for the surface in front. The trailing
    /// menu contains only current-tab actions and Close Tab; the permanent Home has no menu.
    func surfaceTitle<Items: View>(_ title: String, systemImage: String, identifier: String, value: String? = nil,
                                   hasActions: Bool = true, @ViewBuilder menu: @escaping () -> Items) -> some View {
        modifier(SurfaceTitleModifier(title: title, systemImage: systemImage, identifier: identifier, value: value,
                                      hasActions: hasActions, items: menu))
    }
}

private struct SurfaceTitleModifier<Items: View>: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.workspaceObscured) private var obscured
    @Environment(\.workspaceSurfaceTabID) private var surfaceTabID
    let title: String
    let systemImage: String
    let identifier: String
    let value: String?
    let hasActions: Bool
    let items: () -> Items
    private var showsActions: Bool { hasActions || model.currentTab != nil || workspaceUITestHooks }
    /// Native window toolbars sit outside the workspace content's accessibility subtree, so they must
    /// carry the modal and opening state themselves.
    private var toolbarUnavailable: Bool { obscured || model.locked || model.presentationPending }

    @ViewBuilder func body(content: Content) -> some View {
        if WorkspacePlatform.isPhone {
            // A session's page on iPhone: its name in the system bar, its actions and Close in the title menu.
            #if os(iOS)
            content.modifier(PhoneSessionTitle(title: title, items: items))
            #else
            content
            #endif
        } else {
        content
            .navigationTitle("")
            .workspaceInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    WorkspaceSwitcherControl(title: title, systemImage: systemImage, value: value,
                                             workspaceLine: workspaceLine(model), action: shell.openNavigator)
                        .disabled(toolbarUnavailable)
                        .accessibilityHidden(toolbarUnavailable)
                }
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) { actionsMenu }
                #else
                ToolbarItem(placement: .topBarTrailing) { actionsMenu }
                    .sharedBackgroundVisibility(.hidden)
                #endif
            }
    }
    }

    /// The surface's actions, then Close Tab for an open tab (the permanent Home never closes), then the
    /// UI tests' controls in their runs.
    @ViewBuilder private var menuItems: some View {
        items()
        if let tab = model.currentTab {
            Divider()
            Button { model.close(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
                .accessibilityIdentifier("closeCurrentTab")
        }
        if workspaceUITestHooks {
            Divider()
            Button("List VoiceOver elements", systemImage: "list.bullet", action: shell.debugListVoiceOverElements)
                .accessibilityIdentifier("debugListVoiceOverElements")
            Button("Rebuild surfaces", systemImage: "arrow.triangle.2.circlepath", action: shell.debugRebuildSurfaces)
                .accessibilityIdentifier("debugRebuildSurfaces")
        }
    }

    @ViewBuilder private var actionsMenu: some View {
        if showsActions {
            Menu { menuItems } label: {
                toolbarIcon("ellipsis.circle", label: "\(title) Actions")
            }
            .menuOrder(.fixed)
            .accessibilityLabel("\(title) Actions")
            .accessibilityIdentifier(identifier)
            .disabled(toolbarUnavailable)
            .accessibilityHidden(toolbarUnavailable)
        }
    }
}

/// The single navigation control shared by Home and every work surface.
private struct WorkspaceSwitcherControl: View {
    let title: String
    let systemImage: String
    let value: String?
    let workspaceLine: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
                    Text(title).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AgentLandColor.glyphTertiary)
                        .accessibilityHidden(true)
                }
                if let workspaceLine {
                    Text(workspaceLine).font(.caption2).foregroundStyle(AgentLandColor.textSecondary).lineLimit(1)
                }
            }
            .foregroundStyle(AgentLandColor.text)
            .padding(.horizontal, AgentLandSpacing.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open workspace switcher")
        .accessibilityValue([title, value, workspaceLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("workspaceSwitcher")
    }
}

/// The close button on every Settings page in the bottom drawer.
struct SettingsCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { toolbarIcon("xmark", label: "Close Settings") }
            // The overlay's own navigation stack needs a native cancel action even when no field is
            // first responder. WorkspaceTabKeys still gives Escape priority while a field has focus.
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Settings")
            .accessibilityIdentifier("settingsClose")
    }
}

// MARK: Settings pages

/// Where the app's Settings shows, which gives each of its pages its way out.
enum WorkspaceSettingsExit {
    /// The shared bottom drawer: Close is available on every pushed page.
    case overlay(close: @MainActor () -> Void)
}

private struct WorkspaceSettingsExitKey: EnvironmentKey {
    static var defaultValue: WorkspaceSettingsExit? { nil }
}

extension EnvironmentValues {
    var workspaceSettingsExit: WorkspaceSettingsExit? {
        get { self[WorkspaceSettingsExitKey.self] }
        set { self[WorkspaceSettingsExitKey.self] = newValue }
    }
}

public extension View {
    /// A page of the app's Settings (its list or one of its categories, each pushed): its title in the
    /// navigation bar over the shared drawer material. In UI-test runs it also lists what VoiceOver reaches.
    func workspaceSettingsPage(_ title: String) -> some View {
        modifier(WorkspaceSettingsPage(title: title, largeOnPhone: false))
    }

    /// Settings' own list: on iPhone, the Settings tab's root, with a large title as the Settings app's; elsewhere as
    /// any page of Settings.
    func workspaceSettingsRoot(_ title: String) -> some View {
        modifier(WorkspaceSettingsPage(title: title, largeOnPhone: true))
    }
}

private struct WorkspaceSettingsPage: ViewModifier {
    @Environment(\.workspaceSettingsExit) private var exit
    let title: String
    let largeOnPhone: Bool
    @State private var voiceOverElements = ""

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(largeOnPhone && WorkspacePlatform.isPhone ? .large : .inline)
            // The drawer supplies the tinted material; navigation pages stay clear over it. On iPhone the Settings tab's
            // pages are on the canvas, as every tab's page is.
            .containerBackground(WorkspacePlatform.isPhone ? AnyShapeStyle(AgentLandColor.canvas) : AnyShapeStyle(Color.clear),
                                 for: .navigation)
            .overlay(alignment: .topLeading) { voiceOverList }
            .task { await listVoiceOverElements() }
        #else
        content
            .navigationTitle(title)
            .workspaceInlineNavigationTitle()
            .overlay(alignment: .topLeading) { voiceOverList }
            .task { await listVoiceOverElements() }
        #endif
    }

    private var inDrawer: Bool {
        if case .overlay = exit { true } else { false }
    }

    /// UI tests read what VoiceOver reaches on a page pushed in the drawer, once it has settled.
    @ViewBuilder private var voiceOverList: some View {
        if workspaceUITestHooks && inDrawer {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("VoiceOver elements on the drawer's page")
                .accessibilityValue(voiceOverElements)
                .accessibilityIdentifier("debugDrawerPageVoiceOverElements")
        }
    }

    private func listVoiceOverElements() async {
        guard workspaceUITestHooks && inDrawer else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        voiceOverElements = reachableAccessibilityElements().joined(separator: "\n")
    }
}

/// A bar button's symbol. Bar items keep their size at the largest text sizes and show the Large
/// Content Viewer instead. In the Mac's window toolbar the system sizes the item; its label names it in
/// Customize Toolbar and for VoiceOver.
func toolbarIcon(_ name: String, label: String) -> some View {
    #if os(iOS)
    Image(systemName: name)
        .font(.body)
        .foregroundStyle(AgentLandColor.text)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: name) }
    #else
    Label(label, systemImage: name)
    #endif
}
