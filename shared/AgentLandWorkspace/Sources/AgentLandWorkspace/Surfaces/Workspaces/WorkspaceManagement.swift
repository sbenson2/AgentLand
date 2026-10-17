import SwiftUI
import AgentLandCore
import AgentLandDesign

// The Workspaces screen's row actions, add buttons, questions, sheets and notice, shared with the iPhone drawer's
// Workspace section (owner's request, 2026-10-06: "shows workspace tab tree and management (swipe to remove)"), so
// both offer the same actions with one implementation.

/// A workspace row's actions as menu items: Open, Rename…, Close (for a workspace open here) and Remove from
/// AgentLand…, those the host offers. Each runs once the menu has gone (`MenuAction`): Close marks the workspace busy
/// at once, which disables these items, and a menu rewritten on its way out stopped the app (fix-up after batch 11).
struct WorkspaceRowMenuItems: View {
    let summary: WorkspaceSummary
    /// The row's identifier: Close's and Remove's questions point at it (`WorkspaceRowDialogs`).
    let row: String
    let manager: WorkspaceManager
    let open: (String) -> Void

    var body: some View {
        let busy = manager.changing.contains(summary.id)
        Button("Open", systemImage: "arrow.right.circle") { MenuAction.afterDismissal { open(summary.id) } }
            .accessibilityIdentifier("workspaceActionOpen")
        if manager.canRename {
            Button("Rename…", systemImage: "pencil") { MenuAction.afterDismissal { manager.requestRename(summary.project) } }
                .disabled(busy || !manager.canChange)
                .accessibilityIdentifier("workspaceActionRename")
        }
        if summary.openTabs > 0 || summary.isCurrent {
            Button("Close", systemImage: "xmark.circle") { MenuAction.afterDismissal { manager.questionRow = row; await manager.requestClose(summary.project) } }
                .disabled(busy)
                .accessibilityIdentifier("workspaceActionClose")
        }
        if manager.canRemove {
            Divider()
            Button("Remove from AgentLand…", systemImage: "minus.circle", role: .destructive) {
                MenuAction.afterDismissal { manager.questionRow = row; manager.requestRemoval(summary.project) }
            }
            .disabled(busy || !manager.canChange)
            .accessibilityIdentifier("workspaceActionRemove")
        }
    }
}

/// A workspace row's swipes on iPhone and iPad: Remove and Close trailing, Rename leading. Not destructive roles: the
/// row stays until the person confirms. Only one row shows its swipes at a time, so their identifiers name the action
/// alone, as the menu items' do.
struct WorkspaceRowSwipeActions: ViewModifier {
    let summary: WorkspaceSummary
    let row: String
    let manager: WorkspaceManager

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if manager.canRemove {
                    Button { manager.questionRow = row; manager.requestRemoval(summary.project) } label: { Label("Remove", systemImage: "minus.circle") }
                        // The system's colours, as Mail's and Files' swipes (WS-8); not the destructive role, which
                        // would take the row away before the confirmation.
                        .tint(.red)
                        .accessibilityIdentifier("workspaceSwipeRemove")
                }
                if summary.openTabs > 0 || summary.isCurrent {
                    Button { manager.questionRow = row; Task { await manager.requestClose(summary.project) } } label: { Label("Close", systemImage: "xmark.circle") }
                        .tint(.gray)
                        .accessibilityIdentifier("workspaceSwipeClose")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if manager.canRename {
                    Button { manager.requestRename(summary.project) } label: { Label("Rename", systemImage: "pencil") }
                        .tint(.accentColor)
                        .accessibilityIdentifier("workspaceSwipeRename")
                }
            }
        #else
        content
        #endif
    }
}

/// VoiceOver's actions on a row: what its swipes and menus offer.
struct WorkspaceRowAccessibilityActions: ViewModifier {
    let summary: WorkspaceSummary
    let row: String
    let manager: WorkspaceManager

    func body(content: Content) -> some View {
        // Only the actions that apply: Close for a workspace open here, the others with their feature.
        content.accessibilityActions {
            if manager.canRename {
                Button("Rename") { manager.requestRename(summary.project) }
            }
            if summary.openTabs > 0 || summary.isCurrent {
                Button("Close") { manager.questionRow = row; Task { await manager.requestClose(summary.project) } }
            }
            if manager.canRemove {
                Button("Remove from AgentLand") { manager.questionRow = row; manager.requestRemoval(summary.project) }
            }
        }
    }
}

/// New Workspace… and Add Folder…, those the host offers; each shows its sheet (`WorkspaceManagementPresentations`).
struct WorkspaceAddButtons: View {
    let manager: WorkspaceManager
    @Binding var creating: Bool
    @Binding var addingFolder: Bool

    var body: some View {
        if manager.canCreate {
            Button("New Workspace…", systemImage: "folder.badge.plus") { creating = true }
                .accessibilityIdentifier("newWorkspace")
        }
        if manager.canAdd {
            Button("Add Folder…", systemImage: "folder") { addingFolder = true }
                .accessibilityIdentifier("addFolder")
        }
    }
}

/// The manager's last result, the native way (`noticePresentation`, WS-5): on iPhone and iPad a failed or
/// unconfirmed change (which says so) in the system's alert, and a success only heard by VoiceOver (the list and the
/// haptic show it); on the Mac over the top of the list, a confirmation going away by itself.
struct WorkspaceManagerNotice: View {
    let manager: WorkspaceManager

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .noticePresentation(manager.notice.map { NoticeContent(id: $0.id, $0.title, message: $0.message, tone: tone($0.tone)) },
                                identifiers: .init(text: "workspacesNotice", dismiss: "workspacesNoticeDismiss"),
                                successDuration: .seconds(6), dismiss: { manager.notice = nil })
    }

    private func tone(_ tone: WorkspaceNotice.Tone) -> InlineNotice.Tone {
        switch tone {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

/// What the workspace actions present beyond each row's confirmations (`WorkspaceRowDialogs`): the alert for a chat
/// still running in a workspace being removed, Rename's field, the New Workspace and Add Folder sheets (a made or
/// added workspace is opened with `open`), and the haptics of the manager's results. The questions close when the view
/// goes.
struct WorkspaceManagementPresentations: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    let manager: WorkspaceManager
    @Binding var creating: Bool
    @Binding var addingFolder: Bool
    let open: (String) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(WorkspacesDialogs(manager: manager, hostName: model.hostName))
            .sheet(isPresented: $creating) {
                NewWorkspaceSheet(created: { id in
                    creating = false
                    open(id)
                })
                .workspaceSheetFrame(minWidth: 480, minHeight: 420)
                .environment(model)
                .agentLandSheetPage()
            }
            .sheet(isPresented: $addingFolder) {
                NavigationStack {
                    FolderBrowserView(mode: .add, start: nil, cancel: { addingFolder = false }, finish: { result in
                        addingFolder = false
                        if case let .open(id) = result { open(id) }
                    })
                }
                .workspaceSheetFrame(minWidth: 480, minHeight: 460)
                .environment(model)
                .agentLandSheetPage()
            }
            .onDisappear { manager.dismissQuestions() }
            .agentLandHaptic(.success, trigger: manager.notice) { _, notice in notice?.tone == .success }
            .agentLandHaptic(.warning, trigger: manager.notice) { _, notice in notice.map { $0.tone != .success } ?? false }
    }
}

/// The questions about a workspace that are not about one row: the alert for a chat that still runs in a workspace
/// being removed, and Rename's field. Both are system alerts, centred on the screen. Close's and Remove's
/// confirmations are each row's (`WorkspaceRowDialogs`).
struct WorkspacesDialogs: ViewModifier {
    @Bindable var manager: WorkspaceManager
    let hostName: String

    func body(content: Content) -> some View {
        content
            .alert(busyTitle, isPresented: chatRunningShown, presenting: manager.busyRemoval) { _ in
                Button("OK", role: .cancel) {}
            } message: { busy in
                Text("Wait for the chat to finish, or stop it, then remove the workspace."
                     + (busy.terminals > 0 ? " Its terminals keep running until then." : ""))
            }
            .alert("Rename Workspace", isPresented: renameShown, presenting: manager.renaming) { project in
                TextField("Name", text: $manager.renameText)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("workspaceRenameField")
                Button("Rename") { let name = manager.renameText; Task { await manager.rename(project, to: name) } }
                    .accessibilityIdentifier("workspaceRenameConfirm")
                Button("Cancel", role: .cancel) {}
            } message: { project in
                Text("Enter a new name for “\(project.name)”. Its folder keeps its name.")
            }
    }

    private var busyTitle: String { manager.busyRemoval.map(WorkspaceRowDialogs.busyTitle) ?? "" }

    private var chatRunningShown: Binding<Bool> {
        Binding(get: { manager.busyRemoval.map { !$0.canEndTerminals } ?? false }, set: { if !$0 { manager.busyRemoval = nil } })
    }
    private var renameShown: Binding<Bool> {
        Binding(get: { manager.renaming != nil }, set: { if !$0 { manager.renaming = nil } })
    }
}

/// Close's and Remove's confirmations and the busy workspace's second question, on the workspace's row, so each points
/// at the row it acts on (owner, 2026-10-08; `DialogAnchor`). They present only on the row that asked
/// (`WorkspaceManager.questionRow`), never once per row, and each button acts on the item its dialog presents.
struct WorkspaceRowDialogs: ViewModifier {
    let summary: WorkspaceSummary
    /// The row's identifier, as its actions name it in `questionRow`.
    let row: String
    @Bindable var manager: WorkspaceManager
    let hostName: String
    var closeAction: ((WorkspaceCloseRequest) -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .confirmationDialog(manager.pendingClose?.title ?? "", isPresented: closeShown, titleVisibility: .visible,
                                presenting: manager.pendingClose) { request in
                Button("Close Workspace", role: request.liveTerminals > 0 || request.unsavedEditors > 0 ? .destructive : nil) {
                    if let closeAction { closeAction(request) }
                    else { Task { await manager.close(request) } }
                }
                .accessibilityIdentifier("confirmCloseWorkspace")
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .confirmationDialog(removeTitle, isPresented: removeShown, titleVisibility: .visible, presenting: manager.pendingRemoval) { project in
                Button("Remove from AgentLand", role: .destructive) { Task { await manager.remove(project) } }
                    .accessibilityIdentifier("confirmRemoveWorkspace")
                Button("Cancel", role: .cancel) {}
            } message: { project in
                Text(removeMessage(project))
            }
            .confirmationDialog(busyTitle, isPresented: endTerminalsShown, titleVisibility: .visible, presenting: manager.busyRemoval) { busy in
                Button("End Terminals and Remove", role: .destructive) { Task { await manager.remove(busy.project, endTerminals: true) } }
                    .accessibilityIdentifier("confirmEndTerminalsAndRemove")
                Button("Cancel", role: .cancel) {}
            } message: { busy in
                Text("Terminals may be open on other devices too. Their programs stop; the folder and its files stay on \(hostName).")
            }
    }

    /// The question is this row's: about its workspace, and asked from it.
    private func asks(_ projectID: String?) -> Bool {
        projectID == summary.id && manager.questionRow == row
    }

    private var removeTitle: String { "Remove “\(manager.pendingRemoval?.name ?? "")” from AgentLand?" }

    private func removeMessage(_ project: Project) -> String {
        Self.removeMessage(folder: manager.folderText(project.directory), hostName: hostName)
    }

    /// Remove's message; `folder` is the workspace's folder as the rows show it (the Mac's Settings asks it too).
    static func removeMessage(folder: String?, hostName: String) -> String {
        let folder = folder.map { "The folder \($0)" } ?? "Its folder"
        return "\(folder) and its files stay on \(hostName); nothing is deleted. Its tabs on this device close. "
            + "Its chats are kept and come back if you add the folder again."
    }

    private var busyTitle: String { manager.busyRemoval.map(Self.busyTitle) ?? "" }

    static func busyTitle(_ busy: WorkspaceBusyRemoval) -> String {
        if busy.busyChats > 0 { return busy.busyChats == 1 ? "A chat is running in \(busy.project.name)" : "\(busy.busyChats) chats are running in \(busy.project.name)" }
        switch busy.terminals {
        case 0: return "\(busy.project.name) is in use"
        case 1: return "\(busy.project.name) has 1 terminal running"
        default: return "\(busy.project.name) has \(busy.terminals) terminals running"
        }
    }

    private var closeShown: Binding<Bool> {
        Binding(get: { asks(manager.pendingClose?.project.id) }, set: { if !$0, asks(manager.pendingClose?.project.id) { manager.pendingClose = nil } })
    }
    private var removeShown: Binding<Bool> {
        Binding(get: { asks(manager.pendingRemoval?.id) }, set: { if !$0, asks(manager.pendingRemoval?.id) { manager.pendingRemoval = nil } })
    }
    private var endTerminalsShown: Binding<Bool> {
        Binding(get: { manager.busyRemoval?.canEndTerminals == true && asks(manager.busyRemoval?.project.id) },
                set: { if !$0, asks(manager.busyRemoval?.project.id) { manager.busyRemoval = nil } })
    }
}
