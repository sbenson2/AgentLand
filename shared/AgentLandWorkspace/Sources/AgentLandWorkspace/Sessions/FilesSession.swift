import Foundation
import Observation
import AgentLandCore

public enum FileSortField: String, CaseIterable, Sendable {
    case name
    case size
    case modified

    public var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Date Modified"
        }
    }
    public var icon: String {
        switch self {
        case .name: "textformat"
        case .size: "number"
        case .modified: "calendar"
        }
    }
}

/// What a finished, refused or unconfirmed change says, shown as the surface's notice.
public struct FilesNotice: Equatable, Identifiable, Sendable {
    public enum Tone: Equatable, Sendable { case success, warning, error }
    public let id: UUID
    public let title: String
    public let message: String?
    public let tone: Tone

    public init(_ title: String, message: String? = nil, tone: Tone) {
        id = UUID(); self.title = title; self.message = message; self.tone = tone
    }
}

/// A rename, move or new folder the host refused because the name is taken. Keep Both makes the
/// change again with the host's suggested free name.
public struct FileNameConflict: Identifiable, Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case rename(FileEntry)
        case move(FileEntry, folder: String)
        case newFolder(parent: String)
    }
    public let id: UUID
    public let change: Change
    /// The name that is taken.
    public let name: String
    public let suggestedName: String?

    public init(change: Change, name: String, suggestedName: String?) {
        id = UUID(); self.change = change; self.name = name; self.suggestedName = suggestedName
    }
}

/// A Files tab's browser: the folder shown, its listing and expanded folders, the sort, a file name
/// being typed, the changes made from it (rename, move, new folder, Trash and permanent delete),
/// its uploads and its search. Requests carry the folder, host, tab and refresh generation they were
/// made for, and a result that no longer matches is dropped. A change re-reads the folder.
@MainActor @Observable public final class FilesSession: WorkspaceSession {
    public struct TreeItem: Identifiable, Hashable, Sendable {
        public let entry: FileEntry
        public let depth: Int
        public var id: String { entry.path }
    }

    public struct Breadcrumb: Identifiable, Hashable, Sendable {
        public let name: String
        public let path: String
        public var id: String { path }
    }

    public let tabID: UUID
    public let projectID: String

    public private(set) var path = ""
    public private(set) var entries: [FileEntry] = [] { didSet { noteModifiedTimes() } }
    public private(set) var loading = false
    public var issue: String?
    public private(set) var expanded: Set<String> = []
    public private(set) var children: [String: [FileEntry]] = [:] { didSet { noteModifiedTimes() } }
    /// Whether the listing names when items changed (the iPad table shows the column only then, and
    /// the sort menus offer Date Modified). Set only when it changes: the menus read it, and a menu
    /// that is made again while open loses a tap on its items, so a refresh must not remake them.
    public private(set) var hasModifiedTimes = false
    public var showHidden = false
    public private(set) var sortField: FileSortField = .name
    public private(set) var sortAscending = true
    /// The New File alert shows (FI-6); its dismissal sets this back and keeps the typed name for Create.
    public var showNewFile = false
    public var newFileName = ""

    // MARK: Changes

    /// The last change's result.
    public var notice: FilesNotice?
    /// Paths with a change in flight; their rows show it and take no other change meanwhile.
    public internal(set) var changing: Set<String> = []
    /// Bumped after every change the host confirmed, for the success haptic.
    public private(set) var confirmedChanges = 0
    /// The item waiting for the person to confirm moving it to the Trash.
    public var pendingTrash: FileEntry?
    /// The item waiting for the person to confirm deleting it for good (the confirmation names its path).
    public var pendingPermanentDelete: FileEntry?
    /// A change refused because its name is taken, waiting for Keep Both or Cancel.
    public var nameConflict: FileNameConflict?
    /// The item being renamed, and the name typed for it.
    public var renaming: FileEntry?
    public var renameText = ""
    /// A new folder being named in the current folder.
    public var creatingFolder = false
    public var newFolderName = ""
    /// The item the Move sheet is choosing a folder for.
    public var moving: FileEntry?

    /// The uploads started from this tab.
    public let uploads: FileUploadQueue
    /// The search over this tab's folder: names, or contents on hosts that search them.
    public let search: FilesSearchModel

    @ObservationIgnored weak var workspace: WorkspaceModel?
    @ObservationIgnored private var browserRequestID = UUID()
    @ObservationIgnored private var childRequestIDs: [String: UUID] = [:]
    @ObservationIgnored private var firstLoadResolved = false
    @ObservationIgnored private var resolvedRefreshGeneration: UUID?
    /// The folder and refresh generation the listing last resolved for.
    @ObservationIgnored private var resolvedIdentity: String?
    /// The connection epoch the listing last resolved in.
    @ObservationIgnored private var resolvedConnectionEpoch: Int?

    public init(tab: WorkspaceTab, workspace: WorkspaceModel) {
        tabID = tab.id
        projectID = tab.projectID
        self.workspace = workspace
        uploads = FileUploadQueue()
        search = FilesSearchModel()
        uploads.session = self
        search.session = self
    }

    public func end() {
        browserRequestID = UUID()
        childRequestIDs.removeAll()
        uploads.end()
        search.end()
    }

    /// Identifies what the listing shows: the folder and the tab's refresh generation.
    public var loadIdentity: String {
        "\(path)|\(workspace?.tabRefreshGeneration[tabID]?.uuidString ?? "initial")"
    }

    /// The folder's items, and those of its expanded folders under them, in the sort order.
    public var flattenedEntries: [TreeItem] { flatten(entries, depth: 0) }

    public var breadcrumbs: [Breadcrumb] {
        var current = ""
        return path.split(separator: "/").map { component in
            current = current.isEmpty ? String(component) : current + "/" + component
            return Breadcrumb(name: String(component), path: current)
        }
    }

    private func noteModifiedTimes() {
        let named = entries.contains { $0.modifiedAt != nil } || children.values.contains { $0.contains { $0.modifiedAt != nil } }
        if named != hasModifiedTimes { hasModifiedTimes = named }
    }

    private func flatten(_ source: [FileEntry], depth: Int) -> [TreeItem] {
        sorted(source).flatMap { entry -> [TreeItem] in
            guard showHidden || !entry.name.hasPrefix(".") else { return [] }
            let descendants = entry.isDirectory && expanded.contains(entry.path) ? flatten(children[entry.path] ?? [], depth: depth + 1) : []
            return [TreeItem(entry: entry, depth: depth)] + descendants
        }
    }

    public func sort(by field: FileSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
    }

    /// Sets the order as a table's column headers choose it.
    public func setSort(_ field: FileSortField, ascending: Bool) {
        sortField = field
        sortAscending = ascending
    }

    /// What the host offers for this tab.
    public func supports(_ feature: FileFeature) -> Bool { workspace?.capabilities?.supportsFiles(feature) == true }

    // MARK: Navigation

    public func navigate(to newPath: String) {
        guard newPath != path else { return }
        browserRequestID = UUID()
        childRequestIDs.removeAll()
        path = newPath
        entries = []
        children = [:]
        expanded = []
        issue = nil
        loading = true
        cancelNewFile()
    }

    public func toggle(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
            childRequestIDs[entry.path] = UUID()
        } else {
            expanded.insert(entry.path)
            if children[entry.path] == nil {
                Task { await loadChildren(entry.path) }
            }
        }
    }

    /// Opens a file in an editor tab, or a folder here.
    public func open(_ entry: FileEntry) {
        if entry.isDirectory {
            navigate(to: entry.path)
        } else {
            workspace?.openFile(projectID: projectID, path: entry.path)
        }
    }

    // MARK: New file

    public func beginNewFile() {
        newFileName = ""
        showNewFile = true
    }

    public func cancelNewFile() {
        newFileName = ""
        showNewFile = false
    }

    /// Opens an editor for the typed name in the current folder. Returns false when the name is not
    /// usable, with the reason in `notice` (the New File alert has gone by then).
    @discardableResult
    public func openNewFile() -> Bool {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            cancelNewFile()
            notice = FilesNotice("That name can’t be used", message: "Enter a file name without slashes.", tone: .warning)
            return false
        }
        let relative = path.isEmpty ? name : path + "/" + name
        cancelNewFile()
        // Made from the iPhone drawer's Files page, the new file's editor shows in front: the drawer goes.
        workspace?.phoneNavigation.dismissPopovers()
        workspace?.open(WorkspaceTab(kind: .editor, projectID: projectID, resourceID: relative, title: name))
        return true
    }

    // MARK: Loading

    /// Lists the folder unless this folder and refresh generation already resolved, so a rebuilt view
    /// does not list it again.
    public func loadIfNeeded() async {
        // A listing that failed is read again once the host has come back (a new connection epoch), also when
        // the Files view was not on screen at that moment to see it come back.
        let failedBeforeRecovery = issue != nil && resolvedConnectionEpoch != workspace?.connectionEpoch
        if resolvedIdentity == loadIdentity, firstLoadResolved, !loading, !failedBeforeRecovery {
            reportPresentationIfReady()
            return
        }
        await refreshVisibleTree()
    }

    public func refreshVisibleTree() async {
        guard let workspace else { return }
        let refreshGeneration = workspace.tabRefreshGeneration[tabID]
        guard let client = workspace.client else {
            loading = false
            issue = "The host is unavailable."
            firstLoadResolved = true
            resolvedRefreshGeneration = refreshGeneration
            reportPresentationIfReady()
            return
        }
        let hostID = workspace.hostID
        let requestedPath = path
        let identity = loadIdentity
        let expandedPaths = visibleExpandedPaths(in: entries)
        let requestID = UUID()
        browserRequestID = requestID
        childRequestIDs.removeAll()
        loading = true
        issue = nil

        defer {
            if requestIsCurrent(requestID, path: requestedPath, hostID: hostID, refreshGeneration: refreshGeneration) {
                loading = false
                firstLoadResolved = true
                resolvedRefreshGeneration = refreshGeneration
                resolvedIdentity = identity
                resolvedConnectionEpoch = workspace.connectionEpoch
                reportPresentationIfReady()
            }
        }

        do {
            let result = try await client.files(projectID: projectID, path: requestedPath)
            guard requestIsCurrent(requestID, path: requestedPath, hostID: hostID, refreshGeneration: refreshGeneration) else { return }
            entries = result
            loading = false
            firstLoadResolved = true
            resolvedRefreshGeneration = refreshGeneration
            resolvedIdentity = identity
            reportPresentationIfReady()

            for expandedPath in expandedPaths where expanded.contains(expandedPath) {
                // A folder renamed or trashed meanwhile is no longer expanded.
                guard entryExists(expandedPath) else {
                    expanded.remove(expandedPath)
                    children[expandedPath] = nil
                    continue
                }
                let refreshedChildren = try await client.files(projectID: projectID, path: expandedPath)
                guard requestIsCurrent(requestID, path: requestedPath, hostID: hostID, refreshGeneration: refreshGeneration) else { return }
                children[expandedPath] = refreshedChildren
            }
        } catch {
            guard requestIsCurrent(requestID, path: requestedPath, hostID: hostID, refreshGeneration: refreshGeneration) else { return }
            issue = error.localizedDescription
        }
    }

    private func entryExists(_ path: String) -> Bool {
        entries.contains { $0.path == path } || children.values.contains { $0.contains { $0.path == path } }
    }

    private func loadChildren(_ childPath: String) async {
        guard let workspace, let client = workspace.client else { return }
        let hostID = workspace.hostID
        let refreshGeneration = workspace.tabRefreshGeneration[tabID]
        let parentRequestID = browserRequestID
        let requestID = UUID()
        childRequestIDs[childPath] = requestID

        do {
            let result = try await client.files(projectID: projectID, path: childPath)
            guard !Task.isCancelled,
                  expanded.contains(childPath),
                  childRequestIDs[childPath] == requestID,
                  browserRequestID == parentRequestID,
                  workspace.isCurrent(hostID: hostID, tabID: tabID),
                  workspace.tabRefreshGeneration[tabID] == refreshGeneration else { return }
            children[childPath] = result
        } catch {
            guard !Task.isCancelled,
                  childRequestIDs[childPath] == requestID,
                  browserRequestID == parentRequestID,
                  workspace.isCurrent(hostID: hostID, tabID: tabID),
                  workspace.tabRefreshGeneration[tabID] == refreshGeneration else { return }
            issue = error.localizedDescription
        }
    }

    private func requestIsCurrent(_ requestID: UUID, path requestedPath: String, hostID: String?, refreshGeneration: UUID?) -> Bool {
        guard let workspace else { return false }
        return !Task.isCancelled &&
            browserRequestID == requestID &&
            path == requestedPath &&
            workspace.isCurrent(hostID: hostID, tabID: tabID) &&
            workspace.tabRefreshGeneration[tabID] == refreshGeneration
    }

    /// Readiness for the current opening, once this refresh generation resolved.
    public func reportPresentationIfReady() {
        guard let workspace, firstLoadResolved, !loading,
              resolvedRefreshGeneration == workspace.tabRefreshGeneration[tabID],
              let ticket = workspace.presentationRequest(for: tabID) else { return }
        workspace.reportPresentationReady(ticket)
    }

    private func visibleExpandedPaths(in source: [FileEntry]) -> [String] {
        sorted(source).flatMap { entry -> [String] in
            guard entry.isDirectory, expanded.contains(entry.path), showHidden || !entry.name.hasPrefix(".") else { return [] }
            return [entry.path] + visibleExpandedPaths(in: children[entry.path] ?? [])
        }
    }

    func sorted(_ source: [FileEntry]) -> [FileEntry] {
        source.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch sortField {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.size == rhs.size {
                    comparison = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    comparison = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            case .modified:
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (left?, right?) where left != right: comparison = left < right ? .orderedAscending : .orderedDescending
                case (nil, _?): comparison = .orderedAscending
                case (_?, nil): comparison = .orderedDescending
                default: comparison = lhs.name.localizedStandardCompare(rhs.name)
                }
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    // MARK: Changes: shared

    /// The host to change things on, or nil with the offline notice.
    func changeClient() -> (client: APIClient, hostID: String?)? {
        guard let workspace else { return nil }
        guard workspace.reachable, let client = workspace.client else {
            notice = FilesNotice("You’re offline, so nothing was changed.", tone: .warning)
            return nil
        }
        return (client, workspace.hostID)
    }

    /// True while this tab is still open on `hostID`: a change's result is for it.
    func stillCurrent(_ hostID: String?) -> Bool {
        workspace?.isCurrent(hostID: hostID, tabID: tabID) ?? false
    }

    func noteConfirmedChange() {
        confirmedChanges &+= 1
        search.invalidateNames()
    }

    /// Why `name` can't be used for an item, or nil. The host refuses `/`, `\`, `:` and NUL, `.` and
    /// `..`, and paths over 1024 bytes.
    nonisolated static func nameProblem(_ name: String, in folder: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name == "." || name == ".." { return "“\(name)” can’t be used as a name." }
        if name.contains(where: { "/\\:".contains($0) || $0 == "\0" }) { return "Use a name without “/”, “\\” or “:”." }
        if join(folder, name).utf8.count > 1024 { return "That name makes the path too long." }
        return nil
    }

    nonisolated static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

    nonisolated static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    nonisolated static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
