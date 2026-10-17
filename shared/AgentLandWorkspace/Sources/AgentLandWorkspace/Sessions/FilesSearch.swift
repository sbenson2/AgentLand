import Foundation
import Observation
import AgentLandCore

/// What the Files search looks at.
public enum FileSearchScope: String, CaseIterable, Hashable, Sendable {
    /// File and folder names under the folder shown.
    case names
    /// Lines of text files, on hosts that list `search` in `capabilities.files`.
    case contents

    public var title: String { self == .names ? "Names" : "Contents" }
}

/// The search of a Files tab: names under the folder it shows (a bounded walk, kept until the folder,
/// the host or a reload changes it) or, on hosts that search file contents, matching lines. Each run
/// carries the query, scope, folder, host and refresh generation it was made for; results for
/// anything else are dropped.
@MainActor @Observable public final class FilesSearchModel {
    public static let maximumFolders = 80
    public static let maximumEntries = 10_000
    public static let maximumNameResults = 200
    /// Contents searches start at two characters: one matches most lines of most files.
    public static let minimumContentQuery = 2

    /// The search field's text.
    public var text = ""
    public var scope: FileSearchScope = .names
    /// Whether the search field is up (⌘F brings it up).
    public var isPresented = false

    public private(set) var names: [FileEntry] = []
    public private(set) var contents: [FileSearchResult] = []
    /// Why a contents search stopped early.
    public private(set) var limit: FileSearchLimit?
    public private(set) var searching = false
    /// Why the search could not run, in words.
    public private(set) var issue: String?
    /// The name walk stopped at its limits, so deeper names are missing.
    public private(set) var namesIncomplete = false
    /// The run the results are for; until it matches `key` the results are still coming.
    public private(set) var resultsKey: String?
    /// Bumped when the folder changed through this tab, so the results are made again.
    public private(set) var revision = 0

    @ObservationIgnored weak var session: FilesSession?
    @ObservationIgnored private var nameIndex: NameIndex?

    private struct NameIndex {
        let client: ObjectIdentifier
        let folder: String
        let refresh: UUID?
        let hidden: Bool
        let entries: [FileEntry]
        let incomplete: Bool
    }

    init() {}

    public var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isActive: Bool { !query.isEmpty }

    /// Contents search is offered only by hosts that list it.
    public var offersContents: Bool { session?.supports(.search) == true }

    /// The scope a run uses: Names on hosts without contents search.
    public var effectiveScope: FileSearchScope { offersContents ? scope : .names }

    /// Identifies a run: the query, scope, folder, host, refresh generation and hidden files.
    public var key: String {
        guard let session else { return "" }
        let client = session.workspace?.client.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        let refresh = session.workspace?.tabRefreshGeneration[session.tabID]?.uuidString ?? "initial"
        return "\(effectiveScope.rawValue)|\(query)|\(session.path)|\(client)|\(refresh)|\(session.showHidden)|\(revision)"
    }

    /// Whether the results shown are for the current query.
    public var resultsCurrent: Bool { resultsKey == key && !searching }

    /// Runs the current query. The view debounces typing and cancels the previous run.
    public func run() async {
        guard let session, let workspace = session.workspace else { return }
        let key = self.key
        let query = self.query
        guard !query.isEmpty else {
            clear()
            return
        }
        guard let client = workspace.client, workspace.reachable else {
            names = []; contents = []; limit = nil
            issue = "You’re offline. Search works again once your Mac is reachable."
            resultsKey = key
            return
        }
        let folder = session.path
        let hostID = workspace.hostID
        searching = true
        issue = nil
        defer { if self.key == key { searching = false } }
        switch effectiveScope {
        case .names:
            let (entries, incomplete) = await namedEntries(client: client, folder: folder, session: session)
            guard current(key, hostID) else { return }
            names = Array(entries.filter { matches($0.name, query) }.prefix(Self.maximumNameResults))
            namesIncomplete = incomplete
            contents = []
            limit = nil
            resultsKey = key
        case .contents:
            guard query.count >= Self.minimumContentQuery else {
                contents = []; names = []; limit = nil
                issue = "Type at least \(Self.minimumContentQuery) characters to search file contents."
                resultsKey = key
                return
            }
            let options = FileSearchOptions(query: query, path: folder)
            guard options.isValid else {
                contents = []; names = []; limit = nil
                issue = "Search for up to 512 characters on one line."
                resultsKey = key
                return
            }
            do {
                let found = try await client.searchFiles(projectID: session.projectID, options: options)
                guard current(key, hostID) else { return }
                contents = found.results
                limit = found.limit
                names = []
                resultsKey = key
            } catch let ClientError.server(code, _) where code == "search_superseded" {
                // A newer search from this device replaced this one; its answer is the one to show.
                return
            } catch {
                guard current(key, hostID) else { return }
                contents = []
                limit = nil
                issue = error.localizedDescription
                resultsKey = key
            }
        }
    }

    private func current(_ key: String, _ hostID: String?) -> Bool {
        guard !Task.isCancelled, let session else { return false }
        return self.key == key && session.stillCurrent(hostID)
    }

    func matches(_ value: String, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { value.localizedStandardContains($0) }
    }

    public func clear() {
        names = []
        contents = []
        limit = nil
        issue = nil
        namesIncomplete = false
        resultsKey = key
    }

    /// Forgets the walked names and runs the search again, as after a change in the folder.
    public func invalidateNames() {
        nameIndex = nil
        revision &+= 1
    }

    /// The names under `folder`, walked once and kept for the folder, host, refresh generation and
    /// hidden-files choice. Generated and vendored folders are not entered.
    private func namedEntries(client: APIClient, folder: String, session: FilesSession) async -> ([FileEntry], Bool) {
        let clientID = ObjectIdentifier(client)
        let refresh = session.workspace?.tabRefreshGeneration[session.tabID]
        let hidden = session.showHidden
        if let index = nameIndex, index.client == clientID, index.folder == folder, index.refresh == refresh, index.hidden == hidden {
            return (index.entries, index.incomplete)
        }
        var entries: [FileEntry] = []
        var folders = [folder]
        var visited = 0
        var incomplete = false
        while !folders.isEmpty {
            if visited >= Self.maximumFolders || entries.count >= Self.maximumEntries { incomplete = true; break }
            let next = folders.removeFirst()
            visited += 1
            guard let listed = try? await client.files(projectID: session.projectID, path: next) else { continue }
            guard !Task.isCancelled else { return (entries, true) }
            for entry in listed where hidden || !entry.name.hasPrefix(".") {
                entries.append(entry)
                if entry.isDirectory && !WorkspaceSearchModel.skippedFolders.contains(entry.name) { folders.append(entry.path) }
            }
        }
        if !Task.isCancelled {
            nameIndex = NameIndex(client: clientID, folder: folder, refresh: refresh, hidden: hidden, entries: entries, incomplete: incomplete)
        }
        return (entries, incomplete)
    }

    func end() {
        nameIndex = nil
        names = []
        contents = []
    }
}
