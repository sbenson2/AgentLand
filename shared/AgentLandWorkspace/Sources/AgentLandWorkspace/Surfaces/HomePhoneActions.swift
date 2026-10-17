import Foundation
import AgentLandCore
import AgentLandArchive

/// Home's presentation choices carry the same typed provider, program and workspace identities used
/// by the workspace shell. No session or folder is created by this presentation policy.
enum HomePhoneActions {
    enum Action: String, CaseIterable, Identifiable {
        case newChat, newTerminal, newWorkspace, resumeWorkspace
        var id: String { rawValue }
        /// One line at ordinary text sizes (owner's request, 2026-10-04): the menu lists the available choices.
        var title: String {
            switch self {
            case .newChat: "Chat"
            case .newTerminal: "Terminal"
            case .newWorkspace: "Workspaces"
            case .resumeWorkspace: "Resume"
            }
        }
        var hint: String {
            switch self {
            case .newChat: "Shows the chats you can start."
            case .newTerminal: "Shows the terminals you can open."
            case .newWorkspace: "Creates or opens a workspace on your Mac."
            case .resumeWorkspace: "Shows the chats and terminals you closed, to open them again."
            }
        }
        var symbol: String {
            switch self {
            case .newChat: "bubble.left.and.bubble.right"
            case .newTerminal: "terminal"
            case .newWorkspace: "folder"
            case .resumeWorkspace: "clock.arrow.circlepath"
            }
        }
        var identifier: String {
            switch self {
            case .newChat: "homeNewChat"
            case .newTerminal: "homeNewTerminal"
            case .newWorkspace: "openWorkspace"
            case .resumeWorkspace: "homeRecentWork"
            }
        }
    }

    enum Destination: Equatable {
        case standaloneChat
        case terminal(TerminalProgram)
        /// Home's native workspace selection sheet.
        case workspacePicker
        case createWorkspace
        case workspace(String)
        /// A chat closed on this device, by its ID on the host: its tab opens again (or the archive's copy shows).
        case recentChat(String)
        /// A terminal still running on the host with no tab open, by its ID: its tab opens again.
        case recentTerminal(String)
    }

    struct Choice: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String? = nil
        var symbol: String
        var destination: Destination
        /// The agent whose registry icon the row shows instead of `symbol`, once the host has served it.
        var agentID: String? = nil
    }

    /// The most recent chats and terminals the Resume menu lists.
    static let recentLimit = 5

    /// Resume's chats and terminals (owner, 2026-10-08: "the recent terminals that were open and the recent chats that
    /// were open … so a user can pick them to keep going in case they close them by accident"): the most recent chats
    /// with no tab open on this device (the plain chats and the workspace in use's, from the device's copy, else the
    /// host's lists), then the workspace's terminals still running on the host with no tab open; no headings (owner,
    /// 2026-10-08), each row's symbol tells them apart.
    @MainActor static func recentChoices(model: WorkspaceModel) -> [Choice] {
        let sidebar = model.sidebar
        let openChats = Set(model.tabs.filter { $0.kind == .chat && model.workspaceID(for: $0) != nil }.map(\.resourceID))
        let openTerminals = Set(model.tabs.filter { $0.kind == .terminal }.map(\.resourceID))
        func workspaceName(_ id: String?) -> String {
            guard let id else { return "Workspace not assigned" }
            return model.projects.first { $0.id == id }?.name ?? "Workspace unavailable"
        }
        var choices: [Choice] = []
        if sidebar.usesArchive {
            let chats = sidebar.allChats.filter { model.isChatShown($0.id, projectID: $0.projectID, provider: $0.provider) && !openChats.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
            choices += chats.prefix(recentLimit).map { chat in
                return Choice(id: "homeResumeChat-\(chat.id)", title: model.chatName(id: chat.id, listed: sidebar.title(for: chat)),
                              detail: workspaceName(model.isChatsSpace(chat.projectID) ? model.chatWorkspaceIDs[chat.id] : chat.projectID),
                              symbol: Action.newChat.symbol, destination: .recentChat(chat.id))
            }
        } else {
            let sessions = ((sidebar.liveSessions ?? []) + (sidebar.plainLiveSessions ?? [])).filter { !openChats.contains($0.id) }
            choices += sessions.prefix(recentLimit).map { session in
                return Choice(id: "homeResumeChat-\(session.id)", title: model.chatName(id: session.id, listed: session.title),
                              detail: workspaceName(model.isChatsSpace(session.projectID) ? model.chatWorkspaceIDs[session.id] : session.projectID),
                              symbol: Action.newChat.symbol, destination: .recentChat(session.id))
            }
        }
        let terminals = (sidebar.resumeTerminals.isEmpty ? (sidebar.terminals ?? []) : sidebar.resumeTerminals).filter { $0.status == .running && !openTerminals.contains($0.id) }
        choices += terminals.prefix(recentLimit).map {
            Choice(id: "homeResumeTerminal-\($0.id)", title: model.terminalName($0),
                   detail: workspaceName($0.projectID), symbol: Action.newTerminal.symbol,
                   destination: .recentTerminal($0.id))
        }
        let liveIDs = Set(terminals.map(\.id))
        choices += sidebar.resumeTerminalLogs.filter { !openTerminals.contains($0.id) && !liveIDs.contains($0.id) }
            .prefix(recentLimit).map { log in
                Choice(id: "homeResumeTerminal-\(log.id)", title: log.displayTitle,
                       detail: workspaceName(log.projectID),
                       symbol: Action.newTerminal.symbol, destination: .recentTerminal(log.id))
            }
        return choices
    }

    /// - Parameter recent: Resume's chats and terminals (`recentChoices(model:)`), which it lists first.
    static func choices(for action: Action, capabilities: CapabilitiesResponse?, recent: [Choice] = []) -> [Choice] {
        switch action {
        case .newChat:
            var choices: [Choice] = []
            if capabilities?.workspaceChats?.providers.isEmpty == false {
                choices.append(.init(id: "homeNewChatStandalone", title: "New Chat", symbol: action.symbol, destination: .standaloneChat))
            }
            return choices
        case .newTerminal:
            return TerminalProgram.offered(by: capabilities).map {
                .init(id: "homeTerminalProgram-\($0.id)", title: $0.displayName, symbol: action.symbol, destination: .terminal($0),
                      agentID: $0 == .shell ? nil : $0.id)
            }
        case .newWorkspace:
            var choices: [Choice] = []
            if capabilities?.supportsProjects(.create) == true && capabilities?.supportsProjects(.browse) == true {
                choices.append(.init(id: "homeWorkspaceCreate", title: "Create Workspace…", symbol: "folder.badge.plus", destination: .createWorkspace))
            }
            return choices
        case .resumeWorkspace:
            // Only what was closed (owner, 2026-10-08: Search History, the archive, Terminal Logs and the workspaces
            // went; the Workspaces screen is in Settings).
            return recent
        }
    }
}
