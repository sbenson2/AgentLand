import Foundation
import Observation
import AgentLandCore
import AgentLandArchive

/// The sidebar's search over the current workspace and the plain chats: chats by title and, through this
/// device's archive, by what was said in them; files by name and, on hosts that search file contents, by
/// what they contain; open tabs, the host's terminals and the workspaces.
///
/// File names come from walking the workspace's folders once per search session (at most
/// `maximumFolders` folders and `maximumEntries` entries, hidden and generated folders skipped); the
/// walk is kept until the workspace, the client or a reload changes it.
@MainActor @Observable public final class WorkspaceSearchModel {
    public static let maximumFolders = 80
    public static let maximumEntries = 10_000
    /// Folders the walk never enters: generated, vendored or too large to be worth listing.
    static let skippedFolders: Set<String> = ["node_modules", "DerivedData", "Pods", "Carthage", "__pycache__"]

    public var query = ""
    /// Messages in this device's copy that match, best first.
    public private(set) var messageHits: [ArchiveSearchHit] = []
    /// Files and folders whose name matches.
    public private(set) var fileNames: [FileEntry] = []
    /// Lines of text files that match, from the host.
    public private(set) var fileContents: [FileSearchResult] = []
    public private(set) var searchingFiles = false
    public private(set) var searchingMessages = false
    /// Why file contents could not be searched.
    public private(set) var filesIssue: String?
    /// The name walk stopped at its limits, so names deeper in the workspace are not listed.
    public private(set) var namesIncomplete = false
    /// The query the results are for; until it matches `text` the results are still coming.
    public private(set) var resultsText = ""

    @ObservationIgnored weak var workspace: WorkspaceModel?
    @ObservationIgnored private var names: NameIndex?

    private struct NameIndex {
        let client: ObjectIdentifier
        let projectID: String
        let refresh: Int
        let entries: [FileEntry]
        let incomplete: Bool
    }

    public init() {}

    /// The trimmed query; empty means the sidebar shows its lists.
    public var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isActive: Bool { !text.isEmpty }

    func matches(_ value: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { value.localizedStandardContains($0) }
    }

    /// Forgets the walked names, as after a reload or on another host.
    public func reset() {
        names = nil
        messageHits = []
        fileNames = []
        fileContents = []
        filesIssue = nil
        namesIncomplete = false
    }

    /// Bumped to walk the folders again (Refresh in the sidebar).
    @ObservationIgnored public private(set) var namesGeneration = 0
    public func invalidateNames() { namesGeneration &+= 1; names = nil }

    /// Runs the current query. The caller debounces typing and cancels the previous run.
    public func search() async {
        let text = self.text
        guard !text.isEmpty, let workspace else {
            messageHits = []
            fileNames = []
            fileContents = []
            filesIssue = nil
            return
        }
        async let messages: Void = searchMessages(text, workspace: workspace)
        async let files: Void = searchFiles(text, workspace: workspace)
        _ = await (messages, files)
        if !Task.isCancelled, text == self.text { resultsText = text }
    }

    /// Whether the results are for the current query.
    public var resultsCurrent: Bool { resultsText == text && !searchingFiles && !searchingMessages }

    // MARK: Messages

    /// Messages that match: with a workspace open, its Claude Code and Codex chats' and the Chats space's older chats'
    /// (on hosts with a Chats space), best first in each and taken in turn; with none open, the Chats space's.
    private func searchMessages(_ text: String, workspace: WorkspaceModel) async {
        guard workspace.sidebar.usesArchive, let store = workspace.archive?.store else {
            messageHits = []
            return
        }
        searchingMessages = true
        defer { searchingMessages = false }
        let limit = Self.messageLimit
        let space = workspace.chatsSpaceID
        var hits: [ArchiveSearchHit]
        if let projectID = workspace.selectedProjectID, projectID != space {
            async let plain = Self.hits(text, in: space, store: store, limit: limit)
            let own = await Self.hits(text, in: projectID, store: store, limit: limit)
                .filter { workspace.isChatShown($0.chatID, projectID: $0.projectID) }
            hits = Self.alternate(await plain, own, limit: limit)
        } else {
            hits = await Self.hits(text, in: space, store: store, limit: limit)
        }
        guard !Task.isCancelled, text == self.text else { return }
        messageHits = hits
    }

    /// The most message matches listed.
    static let messageLimit = 30

    /// Matches in the chats of `projectID`, best first; none without one.
    private static func hits(_ text: String, in projectID: String?, store: ArchiveStore, limit: Int) async -> [ArchiveSearchHit] {
        guard let projectID else { return [] }
        return (try? await store.search(ArchiveSearchQuery(text: text, projectID: projectID), limit: limit)) ?? []
    }

    /// Two lists, each best first, as one: one of each in turn, the first list's first, at most `limit`. Their
    /// rankings are not comparable, so neither list pushes the other out.
    static func alternate<T>(_ first: [T], _ second: [T], limit: Int) -> [T] {
        var result: [T] = []
        var index = 0
        while result.count < limit && (index < first.count || index < second.count) {
            if index < first.count { result.append(first[index]) }
            if index < second.count, result.count < limit { result.append(second[index]) }
            index += 1
        }
        return result
    }

    // MARK: Files

    private func searchFiles(_ text: String, workspace: WorkspaceModel) async {
        guard let client = workspace.client, let projectID = workspace.selectedProjectID, workspace.reachable else {
            fileNames = []
            fileContents = []
            return
        }
        searchingFiles = true
        defer { searchingFiles = false }
        filesIssue = nil
        async let named: [FileEntry] = namedEntries(client: client, projectID: projectID)
        async let contents: FileSearchResponse? = contentMatches(text, client: client, projectID: projectID,
                                                                 searches: workspace.capabilities?.supportsFiles(.search) == true)
        let (entries, found) = await (named, contents)
        guard !Task.isCancelled, text == self.text, workspace.client === client, workspace.selectedProjectID == projectID else { return }
        fileNames = entries.filter { matches($0.name) }.prefix(50).map { $0 }
        fileContents = found?.results ?? []
    }

    private func contentMatches(_ text: String, client: APIClient, projectID: String, searches: Bool) async -> FileSearchResponse? {
        // One character matches most lines of most files; the host searches from two.
        guard searches, text.count >= 2 else { return nil }
        do {
            return try await client.searchFiles(projectID: projectID, query: text)
        } catch let ClientError.server(code, _) where code == "search_superseded" {
            return nil
        } catch {
            if !Task.isCancelled { filesIssue = error.localizedDescription }
            return nil
        }
    }

    /// The workspace's files and folders by name, walked once and kept.
    private func namedEntries(client: APIClient, projectID: String) async -> [FileEntry] {
        let clientID = ObjectIdentifier(client)
        if let names, names.client == clientID, names.projectID == projectID, names.refresh == namesGeneration {
            namesIncomplete = names.incomplete
            return names.entries
        }
        let generation = namesGeneration
        var entries: [FileEntry] = []
        var folders = [""]
        var visited = 0
        var incomplete = false
        while !folders.isEmpty {
            if visited >= Self.maximumFolders || entries.count >= Self.maximumEntries { incomplete = true; break }
            let folder = folders.removeFirst()
            visited += 1
            guard let listed = try? await client.files(projectID: projectID, path: folder) else { continue }
            guard !Task.isCancelled else { return entries }
            for entry in listed where !entry.name.hasPrefix(".") {
                entries.append(entry)
                if entry.isDirectory && !Self.skippedFolders.contains(entry.name) { folders.append(entry.path) }
            }
        }
        if !Task.isCancelled {
            names = NameIndex(client: clientID, projectID: projectID, refresh: generation, entries: entries, incomplete: incomplete)
            namesIncomplete = incomplete
        }
        return entries
    }
}
