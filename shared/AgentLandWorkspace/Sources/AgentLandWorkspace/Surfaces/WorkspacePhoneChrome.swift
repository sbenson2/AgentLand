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

/// The iPhone's task switcher, the title menu of Chat's and Terminal's Home and of every session's page (owner,
/// 2026-10-22; `WorkspacePhoneNavigation.switcherSections`): each open workspace is a section, its name a row with
/// a house that shows its Home, then its open terminals and chats; the open chats no workspace owns come last under
/// "Chats". A checkmark marks where you are. Choosing a row switches workspace when it is another's and never closes
/// anything; its page pushes once the menu has gone (`MenuAction.afterDismissal`).
///
/// The model and the shell's actions are handed over rather than read from the environment, since the menu is drawn in
/// the navigation bar.
struct PhoneTaskSwitcher: View {
    let model: WorkspaceModel
    let shell: WorkspaceShellActions
    /// Where you are: the task in front, or the workspace whose Home shows; nil on a page the switcher doesn't list
    /// (an editor, a browser tab).
    let current: WorkspacePhoneNavigation.SwitcherItem?
    /// Home's: the UI tests' controls, which a session's page keeps in its ••• menu.
    var testControls = false

    var body: some View {
        ForEach(model.phoneNavigation.switcherSections(model: model)) { section in
            if let projectID = section.projectID {
                Section {
                    row(section.title, systemImage: "house", item: .home(projectID: projectID),
                        identifier: "switcherWorkspace-\(projectID)") { shell.showPhoneWorkspaceHome(projectID) }
                    tasks(section.tasks)
                }
            } else {
                Section(section.title) { tasks(section.tasks) }
            }
        }
        if testControls && workspaceUITestHooks {
            Section {
                Button("List VoiceOver elements", systemImage: "list.bullet", action: shell.debugListVoiceOverElements)
                    .accessibilityIdentifier("debugListVoiceOverElements")
                Button("Rebuild surfaces", systemImage: "arrow.triangle.2.circlepath", action: shell.debugRebuildSurfaces)
                    .accessibilityIdentifier("debugRebuildSurfaces")
            }
        }
    }

    private func tasks(_ tabs: [WorkspaceTab]) -> some View {
        ForEach(tabs) { tab in
            row(tab.title, systemImage: tabIcon(tab.kind), item: .task(tab.id), identifier: "quickTab-\(tab.id.uuidString)") {
                model.phoneNavigation.selectSwitcherTask(tab.id, model: model)
            }
        }
    }

    /// A row with the menu's checkmark while it is where you are (a menu's toggle draws it, as a picker's choice).
    private func row(_ title: String, systemImage: String, item: WorkspacePhoneNavigation.SwitcherItem, identifier: String,
                     action: @escaping @MainActor () -> Void) -> some View {
        Toggle(isOn: Binding(get: { current == item }, set: { _ in MenuAction.afterDismissal { action() } })) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// A session's page on iPhone (native-full side build, 2026-10-16): the system navigation bar shows its name, inline,
/// over the task switcher (`PhoneTaskSwitcher`), and a ••• button at its trailing end holds the surface's own actions
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
                .toolbarTitleMenu { PhoneTaskSwitcher(model: model, shell: shell, current: .task(tab.id)) }
                .toolbar {
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
