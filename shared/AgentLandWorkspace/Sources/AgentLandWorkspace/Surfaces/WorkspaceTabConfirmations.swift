import SwiftUI
import AgentLandCore
import AgentLandArchive
import AgentLandDesign

// The workspace's questions about a tab or a chat: closing an editor with unsaved changes, and deleting a chat. Each
// points at what it acts on (owner, 2026-10-08; `DialogAnchor`): a question a row asked (a drawer task's Close, a
// library chat's Delete) is that row's; one asked from the title menu, the task menu or a keyboard command is the
// shell's, on an anchor under the title menu. Each button acts on the item its dialog presents.

/// The questions no row on screen asks. The shell asks them on a `DialogAnchor` under the title menu; on iPhone, while
/// the drawer's panel is open, the drawer asks them instead (on an anchor at its top), since a presentation behind it
/// cannot show.
struct WorkspaceTabConfirmations: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    let enabled: Bool
    /// The drawer's task rows are on screen and ask their own Close (`TaskCloseConfirmation`).
    var closeRowsShown = false
    /// The library's rows are on screen and ask their own Delete (`ChatDeleteConfirmation`).
    var deleteRowsShown = false

    func body(content: Content) -> some View {
        content
            .closeTabConfirmation(model, isPresented: closeConfirmationShown)
            .deleteChatConfirmation(model, isPresented: deleteShown)
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { enabled && model.sidebar.pendingDelete != nil && !(deleteRowsShown && model.sidebar.pendingDeleteFromRow) },
                set: { if !$0 { model.sidebar.pendingDelete = nil } })
    }

    private var closeConfirmationShown: Binding<Bool> {
        Binding(get: { enabled && model.pendingCloseTab != nil && model.pendingCloseSource != .header && !(closeRowsShown && model.pendingCloseFromRow) },
                set: { shown in if !shown { model.cancelClose() } })
    }
}

/// A task row or the iPhone header's Close control owns its dirty-file confirmation.
/// Only the control for the tab that asked presents it.
struct TaskCloseConfirmation: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    let tab: WorkspaceTab
    var source: WorkspaceTabCloseSource = .row

    func body(content: Content) -> some View {
        content.closeTabConfirmation(model, isPresented: Binding(
            get: { asks },
            set: { shown in if !shown, asks { model.cancelClose() } }))
    }

    private var asks: Bool { model.pendingCloseSource == source && model.pendingCloseTab?.id == tab.id }
}

/// A library chat's Delete, pointing at its row; only the row that asked presents it.
struct ChatDeleteConfirmation: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    let chat: ArchivedChat

    func body(content: Content) -> some View {
        content.deleteChatConfirmation(model, isPresented: Binding(
            get: { asks },
            set: { if !$0, asks { model.sidebar.pendingDelete = nil } }))
    }

    private var asks: Bool { model.sidebar.pendingDeleteFromRow && model.sidebar.pendingDelete?.id == chat.id }
}

private extension View {
    func closeTabConfirmation(_ model: WorkspaceModel, isPresented: Binding<Bool>) -> some View {
        confirmationDialog("Unsaved changes", isPresented: isPresented, titleVisibility: .visible,
                           presenting: model.pendingCloseTab) { tab in
            Button("Close Without Saving", role: .destructive) { model.discardAndClose() }
                .accessibilityIdentifier("discardChanges")
            // Not a cancel role: the dialog may be shown as a popover, which leaves out a
            // cancel button, and keeping the edits must always be a visible choice.
            Button("Keep Editing") { model.cancelClose() }
                .accessibilityIdentifier("keepEditing")
        } message: { tab in
            Text("Close \(tab.title) without saving?")
        }
    }

    func deleteChatConfirmation(_ model: WorkspaceModel, isPresented: Binding<Bool>) -> some View {
        confirmationDialog("Delete “\(model.sidebar.pendingDelete.map(model.sidebar.title(for:)) ?? "")”?", isPresented: isPresented,
                           titleVisibility: .visible, presenting: model.sidebar.pendingDelete) { chat in
            Button("Delete", role: .destructive) { Task { await model.sidebar.confirmDelete(chat) } }
                .accessibilityIdentifier("confirmDeleteChat")
            Button("Cancel", role: .cancel) {}
        } message: { chat in
            Text(model.sidebar.deleteMessage(for: chat))
        }
    }
}
