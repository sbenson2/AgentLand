import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The tab in front's title-menu items, as its surface last drew them, for its pill's ••• menu in the iPhone's drawer.
struct WorkspaceSurfaceMenu {
    /// The tab the items act on; nil for the permanent Home.
    let tabID: UUID?
    /// The surface has actions of its own (Home has none).
    let hasItems: Bool
    let items: AnyView
}

#if os(iOS)
/// Ends editing in every window of the app's scenes. A popover keeps the input views of whatever had the keyboard
/// when it was presented and gives them back when it closes (`_restoreInputViewsForPresentation`), so the keyboard
/// must be gone before a header popover opens (B-8); the responder chain's resign alone missed a responder.
@MainActor func endEditingInEveryWindow() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        for window in scene.windows { window.endEditing(true) }
    }
}

/// The active terminal's opaque backdrop, shared by the header, safe areas and status-bar appearance.
public struct WorkspacePhoneChromeAppearance {
    public let background: Color
    public let colorScheme: ColorScheme

    init?(paintedBackground: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard paintedBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha == 1,
              red.isFinite, green.isFinite, blue.isFinite else { return nil }
        background = Color(uiColor: paintedBackground)
        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
        let rgb = AgentLandRGB((byte(red) << 16) | (byte(green) << 8) | byte(blue))
        colorScheme = rgb.contrastRatio(with: AgentLandColor.text.dark) > rgb.contrastRatio(with: AgentLandColor.text.light) ? .dark : .light
    }
}

public extension WorkspaceModel {
    /// Home, drawers and ordinary shells follow the saved app palette. A painted terminal continues
    /// its backdrop into phone chrome without changing the saved appearance or another session.
    var phoneChromeAppearance: WorkspacePhoneChromeAppearance? {
        guard WorkspacePlatform.isPhone,
              let tab = currentTab, tab.kind == .terminal,
              let background = terminalSession(for: tab).paintedEdge else { return nil }
        return WorkspacePhoneChromeAppearance(paintedBackground: background)
    }
}

/// The middle of the navigation bar of Chat's and Terminal's Home and of every session's page on iPhone (owner,
/// 2026-10-22): the page's title and a small chevron, as the system's title menu draws them, opening the task switcher
/// (`PhoneTaskSwitcher`) in a popover under it. The keyboard goes first (B-8). The switcher closes on Escape, when the
/// page or the host changes (`WorkspacePhoneNavigation.dismissPopovers()`) and when the app goes to the background.
///
/// The model and the shell's actions are handed over rather than read from the environment, since the title is drawn
/// in the navigation bar.
struct PhoneTaskSwitcherTitle: ToolbarContent {
    let model: WorkspaceModel
    let shell: WorkspaceShellActions
    let title: String
    /// Where you are: the task in front, or the workspace whose Home shows; nil on a page the switcher doesn't list
    /// (an editor, a browser tab).
    let current: WorkspacePhoneNavigation.SwitcherItem?
    /// Home's: the UI tests' controls, which a session's page keeps in its ••• menu.
    var testControls = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            PhoneTaskSwitcherButton(model: model, shell: shell, title: title, current: current, testControls: testControls)
        }
        // The title, not a control on glass, as the system's title menu is.
        .sharedBackgroundVisibility(.hidden)
    }
}

/// `PhoneTaskSwitcherTitle`'s button and the popover it opens.
private struct PhoneTaskSwitcherButton: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: WorkspaceModel
    let shell: WorkspaceShellActions
    let title: String
    let current: WorkspacePhoneNavigation.SwitcherItem?
    let testControls: Bool
    /// This title's popover is up; `WorkspacePhoneNavigation.tabSwitcherShown` says one is, for Escape and the shell.
    @State private var presented = false
    @State private var heightLimit: CGFloat = 480

    var body: some View {
        let navigation = model.phoneNavigation
        Button(action: open) {
            HStack(spacing: AgentLandSpacing.xxSmall) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AgentLandColor.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: AgentLandTapTarget.iOSMinimum)
            .contentShape(Rectangle())
            // A bar's title keeps the bar's size, as the system's does.
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Shows your open workspaces and tasks")
        .accessibilityIdentifier("taskSwitcher")
        .popover(isPresented: $presented) {
            PhoneTaskSwitcher(model: model, shell: shell, current: current, testControls: testControls,
                              heightLimit: heightLimit)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: presented) { _, shown in if !shown { navigation.tabSwitcherShown = false } }
        .onChange(of: navigation.tabSwitcherShown) { _, shown in if !shown { presented = false } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { presented = false } }
    }

    private func open() {
        endEditingInEveryWindow()
        heightLimit = switcherHeightLimit()
        model.phoneNavigation.tabSwitcherShown = true
        presented = true
    }

    /// The switcher grows with its rows up to 60% of the window's height, then scrolls.
    private func switcherHeightLimit() -> CGFloat {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return (window?.bounds.height ?? 800) * 0.6
    }
}

/// The iPhone's task switcher, a popover on the system's glass under the page's title (`PhoneTaskSwitcherTitle`;
/// owner, 2026-10-22; `WorkspacePhoneNavigation.switcherSections`): each open workspace is a row with a house that
/// shows its Home, its open terminals and chats indented under it on a tree line that turns right into each (`├─`,
/// the last `└─`); the open chats no workspace owns come last under a plain "Chats" header. A checkmark marks where you
/// are. Choosing a row switches workspace when it is another's and never closes anything; the popover goes first and
/// the row acts once it has gone, so the page it pushes isn't lost to the dismissal.
struct PhoneTaskSwitcher: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    let shell: WorkspaceShellActions
    let current: WorkspacePhoneNavigation.SwitcherItem?
    let testControls: Bool
    /// The tallest it grows before it scrolls.
    let heightLimit: CGFloat
    /// The chosen row's action, run once the popover has gone.
    @State private var chosen: (@MainActor () -> Void)?

    var body: some View {
        let sections = model.phoneNavigation.switcherSections(model: model)
        ScrollView {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
                ForEach(sections) { section($0) }
                if sections.isEmpty {
                    Text("No workspaces or chats are open.")
                        .font(.body)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .padding(.horizontal, AgentLandSpacing.medium)
                        .agentLandRowHeight()
                }
                if testControls && workspaceUITestHooks { testButtons }
            }
            .padding(.vertical, AgentLandSpacing.xSmall)
        }
        .scrollBounceBehavior(.basedOnSize)
        // As wide as its widest row and no wider (owner, 2026-10-22: "needs to fit the text exactly"); a longer name
        // truncates in the middle.
        .frame(maxWidth: 340)
        .frame(maxHeight: heightLimit)
        .onDisappear {
            let action = chosen
            chosen = nil
            action?()
        }
    }

    @ViewBuilder private func section(_ section: WorkspacePhoneNavigation.SwitcherSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let projectID = section.projectID {
                let item = WorkspacePhoneNavigation.SwitcherItem.home(projectID: projectID)
                Button { choose { shell.showPhoneWorkspaceHome(projectID) } } label: {
                    PhoneSwitcherRow(title: section.title, systemImage: "house", place: .workspace(hasTasks: !section.tasks.isEmpty),
                                     checked: current == item)
                }
                .buttonStyle(PhoneSwitcherRowStyle())
                .accessibilityLabel("\(section.title), Home")
                .accessibilityAddTraits(current == item ? .isSelected : [])
                .accessibilityIdentifier("switcherWorkspace-\(projectID)")
            } else {
                PhoneSwitcherRow(title: section.title, systemImage: "bubble.left.and.bubble.right",
                                 place: .workspace(hasTasks: !section.tasks.isEmpty), secondary: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(section.tasks) { tab in
                let item = WorkspacePhoneNavigation.SwitcherItem.task(tab.id)
                Button { choose { model.phoneNavigation.selectSwitcherTask(tab.id, model: model) } } label: {
                    PhoneSwitcherRow(title: tab.title, systemImage: tabIcon(tab.kind),
                                     place: tab.id == section.tasks.last?.id ? .lastTask : .task, checked: current == item)
                }
                .buttonStyle(PhoneSwitcherRowStyle())
                .accessibilityLabel("\(tab.title), \(tab.kind == .chat ? "Chat" : "Terminal"), in \(section.title)")
                .accessibilityAddTraits(current == item ? .isSelected : [])
                .accessibilityIdentifier("quickTab-\(tab.id.uuidString)")
            }
        }
    }

    /// The UI tests' controls, on Home's switcher only.
    private var testButtons: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Button("List VoiceOver elements") { choose(shell.debugListVoiceOverElements) }
                .accessibilityIdentifier("debugListVoiceOverElements")
            Button("Rebuild surfaces") { choose(shell.debugRebuildSurfaces) }
                .accessibilityIdentifier("debugRebuildSurfaces")
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, AgentLandSpacing.medium)
    }

    /// Closes the popover, then runs `action` once it has gone (`onDisappear`).
    private func choose(_ action: @escaping @MainActor () -> Void) {
        chosen = action
        dismiss()
    }
}

/// A row of the task switcher: an icon and a one-line title, at least 44 pt tall and the panel's width, and a
/// checkmark right after the title while it is where you are. A task's row is indented under its workspace's, on the tree line.
private struct PhoneSwitcherRow: View {
    enum Place {
        /// A workspace's row, or the Chats header; the line starts under its icon when tasks follow.
        case workspace(hasTasks: Bool)
        /// A task with another after it (`├─`).
        case task
        /// Its workspace's last task (`└─`).
        case lastTask
    }

    let title: String
    let systemImage: String
    let place: Place
    var checked = false
    /// The Chats header, which can't be chosen.
    var secondary = false
    /// `AgentLandIconSize.regular`, which the tree line's column follows.
    @ScaledMetric(relativeTo: .body) private var iconSide = AgentLandIconSize.regular.baseSide
    private let inset = AgentLandSpacing.medium
    private let spacing = AgentLandSpacing.small

    private var isTask: Bool {
        if case .workspace = place { false } else { true }
    }

    var body: some View {
        HStack(spacing: spacing) {
            // A task's indent: the column of its workspace's icon, where the line runs.
            if isTask { Color.clear.frame(width: iconSide, height: 1) }
            Image(systemName: systemImage)
                .frame(width: iconSide, height: iconSide)
                .foregroundStyle(secondary ? AgentLandColor.textSecondary : AgentLandColor.text)
                .accessibilityHidden(true)
            Text(title)
                .font(isTask ? .body : .body.weight(.semibold))
                .foregroundStyle(secondary ? AgentLandColor.textSecondary : AgentLandColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
            // Right after the title, not at the panel's edge (owner, 2026-10-22: "too much" space between them).
            if checked {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AgentLandColor.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, inset)
        .agentLandRowHeight()
        .background {
            PhoneSwitcherTreeLine(place: place, column: inset + iconSide / 2, iconSide: iconSide,
                                  turnEnd: inset + iconSide + spacing - AgentLandSpacing.xSmall)
                .stroke(AgentLandColor.glyphTertiary, style: StrokeStyle(lineWidth: 1.5, lineJoin: .miter))
                .flipsForRightToLeftLayoutDirection(true)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// A switcher row's part of the tree line, in the column of its workspace's icon: from under a workspace's icon down
/// to its first task's row; through a task's row, turning 90° right into it at its middle (`├─`), or ending there at
/// the last (`└─`).
private struct PhoneSwitcherTreeLine: Shape {
    let place: PhoneSwitcherRow.Place
    /// The line's x: the middle of the workspace's icon.
    let column: CGFloat
    let iconSide: CGFloat
    /// Where the turn ends, clear of the task's icon (a symbol is drawn a little wider than its frame).
    let turnEnd: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch place {
        case .workspace(hasTasks: false):
            break
        case .workspace(hasTasks: true):
            path.move(to: CGPoint(x: column, y: rect.midY + iconSide / 2 + AgentLandSpacing.xxSmall))
            path.addLine(to: CGPoint(x: column, y: rect.maxY))
        case .task:
            path.move(to: CGPoint(x: column, y: rect.minY))
            path.addLine(to: CGPoint(x: column, y: rect.maxY))
            path.move(to: CGPoint(x: column, y: rect.midY))
            path.addLine(to: CGPoint(x: turnEnd, y: rect.midY))
        case .lastTask:
            path.move(to: CGPoint(x: column, y: rect.minY))
            path.addLine(to: CGPoint(x: column, y: rect.midY))
            path.addLine(to: CGPoint(x: turnEnd, y: rect.midY))
        }
        return path
    }
}

/// A switcher row's button: the panel is no List, so it draws a row's pressed state itself, filled with the separator
/// token's tone while pressed, as the Workspace tab's rows are.
private struct PhoneSwitcherRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { if configuration.isPressed { AgentLandColor.separator.color.opacity(0.6) } }
    }
}

/// A session's page on iPhone (native-full side build, 2026-10-16): the system navigation bar shows its name, inline,
/// with a chevron, and opens the task switcher (`PhoneTaskSwitcherTitle`, owner, 2026-10-22); the name stays the page's
/// navigation title, for Back and VoiceOver. A ••• button at the bar's trailing end holds the surface's own actions
/// (owner, 2026-10-22; `surfaceTitle`'s items: a chat's model, mode, Continue, Pin, Export and Delete; a terminal's
/// keyboard, Paste, Keys and Reconnect; an editor's Save, Reload, Copy and Find), then, last, the way out: a chat's
/// Close Chat closes at once, an editor with unsaved edits asks Close Without Saving or Keep Editing
/// (`TaskCloseConfirmation`), and a terminal's End Terminal (its own items' last, `TerminalTabView`) asks once and
/// ends it on the Mac. The questions point at the ••• button. Home, and a surface whose tab is not a workspace tab (a
/// standalone terminal), are left as they are.
struct PhoneSessionTitle<Items: View>: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.workspaceSurfaceTabID) private var surfaceTabID
    let title: String
    let items: () -> Items

    @ViewBuilder func body(content: Content) -> some View {
        if let tab = surfaceTabID.flatMap(model.tab), tab.kind != .home {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PhoneTaskSwitcherTitle(model: model, shell: shell, title: title, current: .task(tab.id))
                    ToolbarItem(placement: .primaryAction) { actionsMenu(tab) }
                }
        } else {
            content
        }
    }

    @ViewBuilder private func actionsMenu(_ tab: WorkspaceTab) -> some View {
        let menu = Menu { menuItems(tab) } label: { Label("\(title) Actions", systemImage: "ellipsis") }
            .menuOrder(.fixed)
            .accessibilityIdentifier("sessionActions")
            // An editor's Close asks here when it has unsaved edits (source `.header`).
            .modifier(TaskCloseConfirmation(tab: tab, source: .header))
        if tab.kind == .terminal {
            menu.modifier(TerminalEndQuestion(session: model.terminalSession(for: tab),
                                              title: TerminalEndConfirmation.phoneTitle(tab.title),
                                              message: TerminalEndConfirmation.message(tab.sharedFrom, hostName: model.hostName),
                                              phone: true))
        } else {
            menu
        }
    }

    @ViewBuilder private func menuItems(_ tab: WorkspaceTab) -> some View {
        items()
        // A terminal's own items end with End Terminal, its one way out.
        if tab.kind != .terminal {
            Section {
                // The page goes with its tab: the menu has gone first (`MenuAction.afterDismissal`).
                Button(closeTitle(tab), systemImage: "xmark") { MenuAction.afterDismissal { close(tab) } }
                    .disabled(model.sessionOpening || saving(tab))
                    .accessibilityIdentifier("phoneCloseTab")
            }
        }
        if workspaceUITestHooks {
            Section {
                Button("List VoiceOver elements", systemImage: "list.bullet", action: shell.debugListVoiceOverElements)
                    .accessibilityIdentifier("debugListVoiceOverElements")
                Button("Rebuild surfaces", systemImage: "arrow.triangle.2.circlepath", action: shell.debugRebuildSurfaces)
                    .accessibilityIdentifier("debugRebuildSurfaces")
            }
        }
    }

    private func saving(_ tab: WorkspaceTab) -> Bool { tab.kind == .editor && model.editorSession(for: tab).saving }

    private func closeTitle(_ tab: WorkspaceTab) -> String {
        switch tab.kind {
        case .chat: "Close Chat"
        case .editor: "Close File"
        default: "Close Tab"
        }
    }

    private func close(_ tab: WorkspaceTab) {
        endEditingInEveryWindow()
        // An editor with unsaved edits asks on the ••• button (`TaskCloseConfirmation`, source `.header`).
        model.close(tab.id, source: .header)
    }
}

#endif
