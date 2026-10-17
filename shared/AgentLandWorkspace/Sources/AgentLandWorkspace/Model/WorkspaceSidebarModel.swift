import Foundation
import Observation
import AgentLandCore
import AgentLandChat
import AgentLandArchive

/// What the sidebar lists: the chat library (this device's archive, or the host's chats when it keeps none): the
/// current workspace's Claude Code and Codex chats and the Chats space's older chats, whatever workspace is open; the
/// host's terminals; and how many files Git sees changed. Results carry the client and workspace they were asked for; a
/// late answer for another is dropped.
@MainActor @Observable public final class WorkspaceSidebarModel {
    /// Chats the sidebar shows besides the pinned ones, in each list; the rest are in the archive.
    public static let recentLimit = 25

    @ObservationIgnored weak var workspace: WorkspaceModel?

    /// The workspace's Claude Code and Codex chats in this device's copy, most recent activity first. Other agents'
    /// chats there stay saved but are not listed.
    public private(set) var archivedChats: [ArchivedChat] = []
    /// Plain chats (the host's Chats space) in this device's copy, most recent activity first: listed with or
    /// without a workspace open, before the workspace's agent chats.
    public private(set) var plainChats: [ArchivedChat] = []
    /// Whether both lists were read for the current workspace (or for none).
    public private(set) var archiveLoaded = false
    /// Titles from the first prompt, for chats the host still calls by a default title ("New chat").
    public private(set) var promptTitles: [String: String] = [:]
    /// The Claude Code and Codex chats the host has for the workspace; nil until read.
    public private(set) var liveSessions: [Session]?
    public private(set) var libraryIssue: String?
    /// The host's plain chats; nil until read, and while the host offers none.
    public private(set) var plainLiveSessions: [Session]?
    public private(set) var plainLibraryIssue: String?
    /// The host's terminals in the workspace; nil until read.
    public private(set) var terminals: [RemoteTerminal]?
    public private(set) var terminalsIssue: String?
    public private(set) var resumeTerminals: [RemoteTerminal] = []
    public private(set) var resumeTerminalLogs: [ArchivedTerminalLog] = []
    /// Changed files over the workspace's repositories; nil until read or without a repository.
    public private(set) var gitChanges: Int?
    /// A chat waiting for the person to confirm deleting it.
    public var pendingDelete: ArchivedChat?
    /// Whether the chat's row in the library asked `pendingDelete`'s question: its dialog then points at that row
    /// (owner, 2026-10-08); otherwise (a title menu, the task menu) the shell asks it under the title menu.
    public private(set) var pendingDeleteFromRow = false

    /// Asks to delete a chat, from its library row or from elsewhere.
    public func requestDelete(_ chat: ArchivedChat, fromRow: Bool = false) {
        pendingDeleteFromRow = fromRow
        pendingDelete = chat
    }
    /// Why the last pin or delete did not happen.
    public var notice: String?
    public private(set) var deleting: Set<String> = []

    public init() {}

    /// Forgets everything: the host changed.
    public func reset() {
        archivedChats = []
        plainChats = []
        archiveLoaded = false
        promptTitles = [:]
        liveSessions = nil
        libraryIssue = nil
        plainLiveSessions = nil
        plainLibraryIssue = nil
        terminals = nil
        terminalsIssue = nil
        resumeTerminals = []
        resumeTerminalLogs = []
        gitChanges = nil
        pendingDelete = nil
        notice = nil
        deleting = []
    }

    // MARK: Chat library

    /// The library comes from this device's archive when the host keeps one it can copy.
    public var usesArchive: Bool {
        workspace?.archive != nil && workspace?.capabilities?.supportsArchive(.sync) == true
    }

    /// The workspace's pinned agent chats, then its most recent ones.
    public var shownChats: [ArchivedChat] { Self.shown(archivedChats) }

    /// The shown agent chats as the library groups them: Pinned, Today, Yesterday, This Week, then by month.
    public var libraryGroups: [ChatLibraryGroup] { ChatLibrary.groups(shownChats) }

    /// More agent chats than the sidebar shows; the archive lists them all.
    public var hasMoreChats: Bool { archivedChats.filter { !$0.pinned }.count > Self.recentLimit }

    /// Pinned plain chats, then the most recent ones.
    public var shownPlainChats: [ArchivedChat] { Self.shown(plainChats) }

    /// The shown plain chats as the library groups them, which the library lists first.
    public var plainLibraryGroups: [ChatLibraryGroup] { ChatLibrary.groups(shownPlainChats) }

    /// More plain chats than the sidebar shows; the archive lists them all.
    public var hasMorePlainChats: Bool { plainChats.filter { !$0.pinned }.count > Self.recentLimit }

    /// Every chat of this device's copy the library knows now: the plain chats first, then the workspace's.
    public var allChats: [ArchivedChat] { plainChats + archivedChats }

    /// Chat's library, as the sidebar's Chats section lists it: the workspace's chats and the Chats space's older
    /// ones together, most recent activity first.
    public var libraryChats: [ArchivedChat] { (archivedChats + plainChats).sorted { $0.updatedAt > $1.updatedAt } }

    /// Pinned chats of the library, then the most recent ones.
    public var shownLibraryChats: [ArchivedChat] { Self.shown(libraryChats) }

    /// The shown library chats as the library groups them: Pinned, Today, Yesterday, This Week, then by month.
    public var chatLibraryGroups: [ChatLibraryGroup] { ChatLibrary.groups(shownLibraryChats) }

    /// More library chats than the sidebar shows; the archive lists them all.
    public var hasMoreLibraryChats: Bool { libraryChats.filter { !$0.pinned }.count > Self.recentLimit }

    /// The host's chats as the library lists them without a copy on this device: the workspace's, then the plain ones.
    public var liveLibrarySessions: [Session]? {
        guard liveSessions != nil || plainLiveSessions != nil else { return nil }
        return (liveSessions ?? []) + (plainLiveSessions ?? [])
    }

    /// A chat of the library by its ID, plain or the workspace's.
    public func chat(_ id: String) -> ArchivedChat? { allChats.first { $0.id == id } }

    /// A chat the host listed by its ID, plain or the workspace's.
    public func session(_ id: String) -> Session? {
        plainLiveSessions?.first { $0.id == id } ?? liveSessions?.first { $0.id == id }
    }

    /// The Chats section shows while the host offers Chat, or while there are chats to list: the workspace's, or older
    /// ones saved in this device's archive.
    public var showsPlainChats: Bool { workspace?.offersPlainChats == true || !plainChats.isEmpty || !archivedChats.isEmpty }

    /// Whether the sidebar has a row for `chatID`: among the library chats it shows.
    public func listsChat(_ chatID: String) -> Bool {
        if usesArchive { return shownLibraryChats.contains { $0.id == chatID } }
        return liveLibrarySessions?.prefix(Self.recentLimit).contains { $0.id == chatID } == true
    }

    private static func shown(_ chats: [ArchivedChat]) -> [ArchivedChat] {
        chats.filter(\.pinned) + chats.filter { !$0.pinned }.prefix(recentLimit)
    }

    /// The chat's name in the library: its title, or its first prompt while the host still calls it by a
    /// default title.
    public func title(for chat: ArchivedChat) -> String { promptTitles[chat.id] ?? chat.displayTitle }

    /// What Delete's confirmation says for `chat`: a plain chat changes no files, so its has no file sentence.
    public func deleteMessage(for chat: ArchivedChat) -> String {
        ChatDeleteCopy.message(hostName: workspace?.hostName ?? "your Mac", plainChat: workspace?.isChatsSpace(chat.projectID) == true)
    }

    /// A prompt's first line, cut to 50 characters, as a chat's title.
    static func promptTitle(_ prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 50 ? String(line.prefix(49)) + "…" : line
    }

    /// Whether the host still has `chatID` as a live chat: a plain chat among the Chats space's sessions, any
    /// other among the workspace's. `projectID`, when the caller knows it, says which; otherwise the lists do.
    /// Unknown (not read yet, unreachable, a host that offers no plain chats now, or another workspace's chat) counts
    /// as live: the chat tab then shows this device's copy and its own state.
    public func isLive(_ chatID: String, projectID: String? = nil) -> Bool {
        let plain = projectID.map { workspace?.isChatsSpace($0) == true }
            ?? (plainChats.contains { $0.id == chatID } || plainLiveSessions?.contains { $0.id == chatID } == true)
        if !plain, let projectID, projectID != workspace?.selectedProjectID { return true }
        guard let sessions = plain ? plainLiveSessions : liveSessions else { return true }
        return sessions.contains { $0.id == chatID }
    }

    /// Reads the plain chats and the workspace's chats from this device's copy, again whenever the sync engine
    /// commits, until the calling task is cancelled. Plain chats are read with no workspace open too.
    public func followArchive(projectID: String?) async {
        guard let store = workspace?.archive?.store else { return }
        await reloadArchive(store: store, projectID: projectID)
        for await _ in await store.changes() {
            guard !Task.isCancelled else { return }
            await reloadArchive(store: store, projectID: projectID)
        }
    }

    private func reloadArchive(store: ArchiveStore, projectID: String?) async {
        // An older host's workspace called `chats` is no Chats space: its chats are that workspace's.
        let space = workspace?.chatsSpaceID
        var plain: [ArchivedChat] = []
        if let space { plain = (try? await store.chats(ArchiveChatFilter(projectID: space))) ?? [] }
        var chats: [ArchivedChat] = []
        if let projectID, projectID != space {
            chats = ((try? await store.chats(ArchiveChatFilter(projectID: projectID))) ?? []).filter { WorkspaceModel.isChatAgent($0.provider) }
        }
        let logs = (try? await store.terminalLogs()) ?? []
        // A chat still called "New chat" (or its agent's default, "Gemini CLI chat" with the host's name for
        // an agent it lists) goes by its first prompt, as it does in its tab.
        let capabilities = workspace?.capabilities
        let unnamed = Set((plain + chats).filter {
            ChatSessionStore.isDefaultTitle($0.title, provider: AgentProvider.named($0.provider, by: capabilities))
        }.map(\.id))
        let prompts = (try? await store.firstPrompts(chatIDs: unnamed)) ?? [:]
        guard !Task.isCancelled, workspace?.archive?.store === store, workspace?.selectedProjectID == projectID,
              workspace?.chatsSpaceID == space else { return }
        let titles = prompts.compactMapValues(Self.promptTitle)
        // Only real changes reach the views: a list rebuilt for nothing closes a menu a row holds open.
        if promptTitles != titles { promptTitles = titles }
        if plainChats != plain { plainChats = plain }
        if resumeTerminalLogs != logs { resumeTerminalLogs = logs }
        if archivedChats != chats { archivedChats = chats }
        if !archiveLoaded { archiveLoaded = true }
        // Open chats go by the library's names, as their rows do.
        workspace?.followChatNames(Self.names(of: plain + chats, prompts: titles, capabilities: capabilities))
    }

    /// The library's names of `chats`: a chat's title, or its first prompt while its title is a default.
    static func names(of chats: [ArchivedChat], prompts: [String: String], capabilities: CapabilitiesResponse?) -> [String: String] {
        var names: [String: String] = [:]
        for chat in chats {
            let title = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prompt = prompts[chat.id] { names[chat.id] = prompt }
            else if !ChatSessionStore.isDefaultTitle(title, provider: AgentProvider.named(chat.provider, by: capabilities)) {
                names[chat.id] = title
            }
        }
        return names
    }

    /// The host's titles of `sessions`, default titles left out.
    static func names(of sessions: [Session], capabilities: CapabilitiesResponse?) -> [String: String] {
        var names: [String: String] = [:]
        for session in sessions where session.titleSource != .default {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ChatSessionStore.isDefaultTitle(title, provider: AgentProvider.named(session.provider, by: capabilities)) {
                names[session.id] = title
            }
        }
        return names
    }

    /// The host's plain chats and the workspace's chats: the library itself for hosts without an archive,
    /// and which archived chats are still live for the others.
    public func refreshSessions() async {
        async let plain: Void = refreshPlainSessions()
        async let own: Void = refreshWorkspaceSessions()
        _ = await (plain, own)
    }

    /// The host's plain chats, while it offers them (`capabilities.plainChats`), whatever workspace is open.
    public func refreshPlainSessions() async {
        guard let workspace, let client = workspace.client, let plainChats = workspace.capabilities?.plainChats else {
            if plainLiveSessions != nil { plainLiveSessions = nil }
            return
        }
        do {
            let sessions = try await client.sessions(projectID: plainChats.projectID)
            guard !Task.isCancelled, workspace.client === client else { return }
            if plainLiveSessions != sessions { plainLiveSessions = sessions }
            if plainLibraryIssue != nil { plainLibraryIssue = nil }
            if !usesArchive { workspace.followChatNames(Self.names(of: sessions, capabilities: workspace.capabilities)) }
        } catch {
            guard !Task.isCancelled, workspace.client === client else { return }
            if plainLibraryIssue != error.localizedDescription { plainLibraryIssue = error.localizedDescription }
        }
    }

    /// The host's Claude Code and Codex chats of the workspace.
    private func refreshWorkspaceSessions() async {
        guard let workspace, let client = workspace.client, let projectID = workspace.selectedProjectID,
              !workspace.isChatsSpace(projectID) else {
            if liveSessions != nil { liveSessions = nil }
            return
        }
        do {
            let sessions = try await client.sessions(projectID: projectID).filter { WorkspaceModel.isChatAgent($0.provider) }
            guard current(client, projectID) else { return }
            if liveSessions != sessions { liveSessions = sessions }
            if libraryIssue != nil { libraryIssue = nil }
            // Without a copy on this device the host's list is the library: open chats go by its titles.
            if !usesArchive { workspace.followChatNames(Self.names(of: sessions, capabilities: workspace.capabilities)) }
        } catch {
            guard current(client, projectID), !Task.isCancelled else { return }
            if libraryIssue != error.localizedDescription { libraryIssue = error.localizedDescription }
        }
    }

    // MARK: Terminals and Git

    /// The host's terminals of the workspace. Its open terminal tabs take the names the list gives.
    public func refreshTerminals() async {
        guard let workspace, workspace.capabilities?.terminal == true, let client = workspace.client,
              let projectID = workspace.selectedProjectID else {
            if terminals != nil { terminals = nil }
            return
        }
        do {
            let asked = Date()
            let found = try await client.terminals(projectID: projectID)
            guard current(client, projectID) else { return }
            if terminals != found { terminals = found }
            resumeTerminals = resumeTerminals.filter { $0.projectID != projectID } + found
            if terminalsIssue != nil { terminalsIssue = nil }
            workspace.followTerminals(found, projectID: projectID, asked: asked)
        } catch {
            guard current(client, projectID), !Task.isCancelled else { return }
            if terminalsIssue != error.localizedDescription { terminalsIssue = error.localizedDescription }
        }
    }

    /// Resume is host-wide: a closed workspace must not hide its still-running terminals.
    public func refreshResumeTerminals() async {
        guard let workspace, let client = workspace.client, workspace.reachable,
              workspace.capabilities?.terminal == true else { return }
        let hostID = workspace.hostID
        let projects = workspace.projects
        var found: [RemoteTerminal] = []
        for project in projects {
            guard !Task.isCancelled, workspace.client === client, workspace.hostID == hostID else { return }
            do { found += try await client.terminals(projectID: project.id) }
            catch { found += resumeTerminals.filter { $0.projectID == project.id } }
        }
        guard !Task.isCancelled, workspace.client === client, workspace.hostID == hostID else { return }
        resumeTerminals = found
    }

    /// Counts changed files over the workspace's repositories.
    public func refreshGit() async {
        guard let workspace, let client = workspace.client, let projectID = workspace.selectedProjectID else {
            if gitChanges != nil { gitChanges = nil }
            return
        }
        do {
            var count = 0
            let repositories = try await client.gitRepositories(projectID: projectID)
            for repository in repositories {
                count += try await client.gitStatus(projectID: projectID, repository: repository.path).changes.count
            }
            guard current(client, projectID) else { return }
            let changes: Int? = repositories.isEmpty ? nil : count
            if gitChanges != changes { gitChanges = changes }
        } catch {
            // The badge is a hint; the Git view shows what went wrong.
            guard current(client, projectID), !Task.isCancelled else { return }
            if gitChanges != nil { gitChanges = nil }
        }
    }

    /// Everything the sidebar reads from the host.
    public func refresh() async {
        async let sessions: Void = refreshSessions()
        async let terminals: Void = refreshTerminals()
        async let git: Void = refreshGit()
        _ = await (sessions, terminals, git)
    }

    private func current(_ client: APIClient, _ projectID: String) -> Bool {
        !Task.isCancelled && workspace?.client === client && workspace?.selectedProjectID == projectID
    }

    // MARK: Pins and deletes

    /// Pins are this device's own; they never go to the host.
    public func setPinned(_ pinned: Bool, chatID: String) async {
        guard let store = workspace?.archive?.store else { return }
        do { try await store.setPinned(pinned, chatID: chatID) } catch {
            notice = "The pin could not be saved on this device. \(error.localizedDescription)"
        }
    }

    /// Deleting needs the host: the archive on the Mac is the original.
    public var canDelete: Bool {
        guard let workspace else { return false }
        return usesArchive && workspace.reachable && workspace.client != nil
    }

    /// Deletes the chat on the host after the person confirmed it. This device drops its copy, its
    /// opened attachments and its tab only when the host answers that it deleted it.
    public func confirmDelete(_ chat: ArchivedChat) async {
        pendingDelete = nil
        guard canDelete, let workspace, let client = workspace.client, let archive = workspace.archive else {
            notice = "You’re offline, so nothing was deleted."
            return
        }
        deleting.insert(chat.id)
        defer { deleting.remove(chat.id) }
        switch await client.archiveDelete(.chat, id: chat.id) {
        case .deleted:
            try? await archive.store.deleteChat(id: chat.id)
            await archive.attachments?.remove(chatID: chat.id)
            guard workspace.client === client else { return }
            workspace.closeChat(sessionID: chat.id)
            liveSessions?.removeAll { $0.id == chat.id }
            plainLiveSessions?.removeAll { $0.id == chat.id }
        case .uncertain:
            notice = "Your Mac may have deleted “\(chat.displayTitle)”. It stays here until your Mac confirms."
        case let .failed(error):
            notice = "“\(chat.displayTitle)” wasn’t deleted. \(error.localizedDescription)"
        }
    }
}
