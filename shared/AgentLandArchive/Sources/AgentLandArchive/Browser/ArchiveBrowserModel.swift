import Foundation
import Observation
import AgentLandCore

/// What the archive browser lists.
public enum ArchiveScope: String, CaseIterable, Identifiable, Sendable {
    case chats, terminals
    public var id: String { rawValue }
    public var label: String { self == .chats ? "Chats" : "Terminals" }
}

/// Where full-text results came from.
public enum ArchiveSearchSource: Equatable, Sendable {
    /// The host searched its archive.
    case host(name: String)
    /// This device searched its copy (offline, or the host could not be asked).
    case device
}

/// The archive browser's state: the chat library and terminal logs from this
/// device's copy, search (the host's when online, this device's otherwise),
/// pins, and deletes that leave this device only after the host confirms.
@MainActor @Observable
public final class ArchiveBrowserModel {
    public let store: ArchiveStore
    public private(set) var environment: ArchiveEnvironment
    public var scope: ArchiveScope = .chats
    public var searchText = ""
    public var tokens: [ArchiveSearchToken] = [] {
        didSet {
            let normalized = ArchiveSearchToken.normalized(tokens)
            if normalized != tokens { tokens = normalized }
        }
    }

    public private(set) var chats: [ArchivedChat] = []
    public private(set) var logs: [ArchivedTerminalLog] = []
    public private(set) var projectIDs: [String] = []
    public private(set) var providers: [String] = []
    public private(set) var loaded = false
    /// Chats whose title matches the search, found at once on this device.
    public private(set) var titleMatches: [ArchivedChat] = []
    /// Messages that match the search.
    public private(set) var hits: [ArchiveSearchHit] = []
    public private(set) var hitsSource: ArchiveSearchSource?
    public private(set) var searching = false
    public private(set) var canLoadMoreHits = false
    public private(set) var notice: String?
    /// Waiting for the person to confirm in a dialog.
    public var pendingDelete: ArchivedChat?
    public var pendingLogDelete: ArchivedTerminalLog?
    public private(set) var deleting: Set<String> = []

    var now: @Sendable () -> Date = { Date() }
    var calendar = Calendar.current
    @ObservationIgnored private var searchToken = UUID()
    @ObservationIgnored private var hostCursor: String?
    @ObservationIgnored private var localOffset = 0
    @ObservationIgnored private var hitChats: [String: ArchivedChat] = [:]

    public init(store: ArchiveStore, environment: ArchiveEnvironment) {
        self.store = store
        self.environment = environment
    }

    public func update(_ environment: ArchiveEnvironment) { self.environment = environment }

    // MARK: Lists

    public var query: ArchiveSearchQuery { ArchiveSearchQuery(text: searchText, tokens: tokens, now: now(), calendar: calendar) }

    /// The chat library with the search chips applied, grouped by date.
    public var groups: [ChatLibraryGroup] { ChatLibrary.groups(chats, now: now(), calendar: calendar) }

    /// Terminal logs with the workspace and date chips and the search text applied.
    public var visibleLogs: [ArchivedTerminalLog] {
        let query = query
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        return logs.filter { log in
            (query.projectID == nil || log.projectID == query.projectID)
                && (query.from.map { log.startedAt >= $0 } ?? true) && (query.to.map { log.startedAt < $0 } ?? true)
                && words.allSatisfy { word in
                    log.displayTitle.localizedStandardContains(word) || log.programName.localizedStandardContains(word)
                        || workspaceName(log.projectID).localizedStandardContains(word)
                }
        }
    }

    /// Reads the lists from this device's copy.
    public func reload() async {
        do {
            chats = try await store.chats(query.chatFilter).filter { environment.showsChat($0.id, projectID: $0.projectID, provider: $0.provider) }
            logs = try await store.terminalLogs()
            let facets = try await store.facets()
            projectIDs = facets.projectIDs
            providers = environment.chatAgents != nil ? Array(Set(chats.map(\.provider))).sorted() : facets.providers
            titleMatches = query.hasText ? chats.filter { query.titleMatches($0.displayTitle) } : []
            loaded = true
        } catch {
            notice = "The archive on this device could not be read. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Reloads whenever the copy changes (the sync engine commits a page),
    /// until the calling task is cancelled.
    public func follow() async {
        await reload()
        for await _ in await store.changes() {
            await reload()
        }
    }

    /// A workspace's name as rows and chips show it; the host's Chats space is "Chats", as its notices name it.
    public func workspaceName(_ projectID: String) -> String {
        environment.isChatsSpace(projectID) ? "Chats" : environment.workspaces[projectID] ?? projectID
    }

    /// The workspace an export or a continued chat's context names: none for a plain chat, which belongs to no
    /// workspace, as its tab's own export.
    public func exportedWorkspace(_ projectID: String) -> String? {
        environment.isChatsSpace(projectID) ? nil : workspaceName(projectID)
    }

    /// Chips to offer: every provider and workspace in the copy, and the date ranges.
    public var suggestedTokens: [ArchiveSearchToken] {
        let chosen = Set(tokens.map(\.kind))
        var suggestions: [ArchiveSearchToken] = []
        if scope == .chats, !chosen.contains(.provider) { suggestions += providers.map { .provider($0) } }
        if !chosen.contains(.workspace) { suggestions += projectIDs.map { .workspace(id: $0, name: workspaceName($0)) } }
        if !chosen.contains(.dateRange) { suggestions += ArchiveDateRange.allCases.map { .dateRange($0) } }
        return suggestions
    }

    // MARK: Search

    /// Runs the current search: title matches at once, then message matches
    /// from the host when it can be asked and from this device otherwise.
    public func search() async {
        let query = query
        let token = UUID()
        searchToken = token
        await reload()
        guard query.hasText else {
            hits = []
            hitsSource = nil
            canLoadMoreHits = false
            searching = false
            return
        }
        searching = true
        hostCursor = nil
        localOffset = 0
        hitChats = [:]
        let (found, source, more) = await fetchHits(query, first: true)
        guard token == searchToken else { return }
        hits = found
        hitsSource = source
        canLoadMoreHits = more
        searching = false
    }

    public func loadMoreHits() async {
        guard canLoadMoreHits, !searching else { return }
        let token = searchToken
        searching = true
        let (found, _, more) = await fetchHits(query, first: false)
        guard token == searchToken else { return }
        hits += found.filter { hit in !hits.contains { $0.id == hit.id } }
        canLoadMoreHits = more
        searching = false
    }

    private func fetchHits(_ query: ArchiveSearchQuery, first: Bool) async -> ([ArchiveSearchHit], ArchiveSearchSource, Bool) {
        let pageSize = 20
        let useHost = environment.online && environment.capabilities?.supportsArchive(.search) == true
            && (first || hitsSource != .device)
        if useHost, let client = environment.client, let request = query.hostRequest(limit: pageSize, cursor: first ? nil : hostCursor) {
            do {
                let page = try await client.archiveSearch(request)
                hostCursor = page.nextCursor
                // Hosts name each result's provider; for older ones this
                // device's copy of the chat knows it.
                let unnamed = Set(page.results.filter { $0.provider == nil }.map(\.chatID)).subtracting(hitChats.keys)
                if !unnamed.isEmpty {
                    for (id, chat) in (try? await store.chats(ids: unnamed)) ?? [:] { hitChats[id] = chat }
                }
                let found = page.results.filter { environment.showsChat($0.chatID, projectID: $0.projectID, provider: $0.provider ?? hitChats[$0.chatID]?.provider) }.map { result in
                    ArchiveSearchHit(chatID: result.chatID, messageID: result.messageID, projectID: result.projectID, title: result.title,
                                     provider: result.provider ?? hitChats[result.chatID]?.provider, role: MessageRole(rawValue: result.role),
                                     createdAt: ChatTime.date(result.createdAt), snippet: result.snippet)
                }
                return (found, .host(name: environment.hostName), page.nextCursor != nil)
            } catch is CancellationError {
                return ([], .host(name: environment.hostName), false)
            } catch {
                if first {
                    notice = "\(environment.hostName) couldn’t search, so these results are from this device."
                }
            }
        }
        let page = (try? await store.search(query, limit: pageSize, offset: first ? 0 : localOffset)) ?? []
        localOffset = (first ? 0 : localOffset) + page.count
        let found = page.filter { environment.showsChat($0.chatID, projectID: $0.projectID, provider: $0.provider) }
        return (found, .device, page.count == pageSize)
    }

    public func dismissNotice() { notice = nil }

    // MARK: Pins and deletes

    public func setPinned(_ pinned: Bool, for chat: ArchivedChat) async {
        try? await store.setPinned(pinned, chatID: chat.id)
        await reload()
    }

    /// Deleting needs the host: the archive on the Mac is the original.
    public var canDelete: Bool { environment.online }

    /// Asks for confirmation first (the view shows the dialog).
    public func requestDelete(_ chat: ArchivedChat) { pendingDelete = chat }
    public func requestDelete(_ log: ArchivedTerminalLog) { pendingLogDelete = log }

    /// Deletes on the host; this device drops its copy (and the chat's opened
    /// attachments) only when the host confirms. An uncertain answer keeps it,
    /// and the next sync settles it.
    public func confirmDelete(_ chat: ArchivedChat, attachments: AttachmentCache? = nil) async {
        pendingDelete = nil
        guard canDelete, let client = environment.client else {
            notice = "You’re offline, so nothing was deleted."
            return
        }
        deleting.insert(chat.id)
        defer { deleting.remove(chat.id) }
        switch await client.archiveDelete(.chat, id: chat.id) {
        case .deleted:
            try? await store.deleteChat(id: chat.id)
            await attachments?.remove(chatID: chat.id)
            hits.removeAll { $0.chatID == chat.id }
            await reload()
        case .uncertain:
            notice = "\(environment.hostName) may have deleted “\(chat.displayTitle)”. It stays here until your Mac confirms."
        case let .failed(error):
            notice = "“\(chat.displayTitle)” wasn’t deleted. \(error.localizedDescription)"
        }
    }

    public func confirmDelete(_ log: ArchivedTerminalLog, cache: TerminalLogCache? = nil) async {
        pendingLogDelete = nil
        guard canDelete, let client = environment.client else {
            notice = "You’re offline, so nothing was deleted."
            return
        }
        deleting.insert(log.id)
        defer { deleting.remove(log.id) }
        switch await client.archiveDelete(.terminalLog, id: log.id) {
        case .deleted:
            try? await store.deleteTerminalLog(id: log.id)
            await cache?.remove(log)
            await reload()
        case .uncertain:
            notice = "\(environment.hostName) may have deleted “\(log.displayTitle)”. It stays here until your Mac confirms."
        case let .failed(error):
            notice = "“\(log.displayTitle)” wasn’t deleted. \(error.localizedDescription)"
        }
    }

    /// "Synced 12:03", "Syncing…", or why it is not.
    public var syncCaption: String? {
        guard let sync = environment.sync else { return nil }
        switch sync.phase {
        case .syncing: return "Updating from \(environment.hostName)…"
        case .refused: return "\(environment.hostName) no longer accepts this device. Pair again to update this copy."
        case .unavailable: return "\(environment.hostName) doesn’t keep an archive this device can copy."
        case .waiting, .stopped, .upToDate:
            guard let at = sync.lastSyncedAt else { return "Not updated yet." }
            return "Updated \(at.formatted(date: .omitted, time: .shortened))"
        }
    }
}
