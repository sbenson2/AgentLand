import Foundation
import AgentLandCore
import AgentLandArchive

/// One resume intent, retained while an older chat asks for a workspace.
public enum WorkspaceResumeTarget: Equatable {
    case tab(WorkspaceTab)
    /// A chat this device's copy shows read-only; `projectID`, when known, is the chat's own (a workspace chat's
    /// workspace, or the Chats space).
    case archivedChat(String, projectID: String? = nil)
    case terminalLog(ArchivedTerminalLog)

    var chatID: String? {
        switch self {
        case let .tab(tab): tab.kind == .chat ? tab.resourceID : nil
        case let .archivedChat(id, _): id
        case .terminalLog: nil
        }
    }
}

extension WorkspaceModel {
    /// A workspace's tab is that workspace's, a workspace chat included (Claude Code and Codex, 2026-10-12). Older chats
    /// of the Chats space have no workspace of their own: this separate association, saved per host and device, is
    /// their UI workspace.
    public func workspaceID(for tab: WorkspaceTab) -> String? {
        isPlainChat(tab) ? chatWorkspaceIDs[tab.resourceID] : tab.projectID
    }

    func rememberChatWorkspace(_ chatID: String, workspaceID: String) {
        guard projects.contains(where: { $0.id == workspaceID }), !isChatsSpace(workspaceID) else { return }
        chatWorkspaceIDs[chatID] = workspaceID
        guard let identity else { return }
        defaults.set(chatWorkspaceIDs, forKey: keys.currentWorkspace + "chatWorkspaces." + identity.storageKey)
    }

    /// Reopens the owner before selecting the session: a workspace chat's or terminal's own workspace, a Chats-space
    /// chat's saved association. Missing associations never inherit whichever workspace happens to be in front; the
    /// shell asks the person to choose for a Chats-space chat and remembers that choice.
    /// An open tab is only selected. Only a launch from a Home tab (its Resume menu, the library) passes
    /// `homeID`: the surface then takes that Home tab's place, as `open(_:replacingHome:)` does.
    public func requestResume(_ target: WorkspaceResumeTarget, replacingHome homeID: UUID? = nil) {
        var target = target
        // A saved chat asked for by its ID alone names its workspace through the library's lists, when they have it.
        if case let .archivedChat(id, nil) = target, let known = sidebar.chat(id)?.projectID ?? sidebar.session(id)?.projectID {
            target = .archivedChat(id, projectID: known)
        }
        if case let .tab(tab) = target, !supportsTab(tab) { return }
        // Until the host's workspace list is known (out of reach at launch), a tab open on this device and owned by a
        // workspace is still selected, as when its workspace is listed: it was restored with it (2026-10-12).
        if homeID == nil, case let .tab(tab) = target, workspaceListPending, workspaceID(for: tab) != nil,
           tabs.contains(where: { $0.id == tab.id }) {
            pendingSessionResume = nil
            selectedTabID = tab.id
            return
        }
        let owner: String?
        switch target {
        case let .tab(tab): owner = workspaceID(for: tab)
        case let .archivedChat(id, projectID):
            owner = projectID.flatMap { isChatsSpace($0) ? nil : $0 } ?? chatWorkspaceIDs[id]
        case let .terminalLog(log): owner = log.projectID
        }
        guard let owner, projects.contains(where: { $0.id == owner }) else {
            if target.chatID != nil, !ownsWorkspace(target) {
                pendingSessionResume = target
                pendingResumeHomeID = homeID
                sessionResumeRequest &+= 1
            } else if case .tab = target {
                creationIssue = "This session’s workspace is no longer available on this Mac."
            } else {
                // Saved output, or a saved chat's copy, runs nothing: it reads the same without its workspace, which
                // stays as it is.
                pendingSessionResume = nil
                resumedArchive = target
            }
            return
        }
        pendingSessionResume = nil
        switch target {
        case let .tab(tab):
            // Switching to an open tab (the sidebar, the menus, ⌘1–9, a notification) changes nothing else.
            if homeID == nil, let existing = tabs.first(where: { $0.id == tab.id || (tab.kind != .home && $0.kind == tab.kind && $0.projectID == tab.projectID && $0.resourceID == tab.resourceID) }) {
                selectedTabID = existing.id
                return
            }
            selectProject(owner)
            open(tab, replacingHome: homeID)
        case .archivedChat, .terminalLog:
            openWorkspace(owner, openFilesIfEmpty: false)
            resumedArchive = target
        }
    }

    /// A workspace chat names its own workspace: it is never asked for one.
    private func ownsWorkspace(_ target: WorkspaceResumeTarget) -> Bool {
        switch target {
        case let .tab(tab): isWorkspaceChat(tab)
        case let .archivedChat(_, projectID): projectID.map { !isChatsSpace($0) } ?? false
        case .terminalLog: true
        }
    }

    func completeSessionResume(in workspaceID: String) {
        guard let target = pendingSessionResume, let chatID = target.chatID,
              projects.contains(where: { $0.id == workspaceID }) else { return }
        rememberChatWorkspace(chatID, workspaceID: workspaceID)
        requestResume(target, replacingHome: pendingResumeHomeID)
    }
}
