import Foundation
import Observation
import AgentLandCore

/// What a Git change says, shown as the surface's notice.
public struct GitNotice: Equatable, Identifiable, Sendable {
    public enum Tone: Equatable, Sendable { case success, warning, error }
    public let id: UUID
    public let title: String
    public let message: String?
    public let tone: Tone

    public init(_ title: String, message: String? = nil, tone: Tone) {
        id = UUID(); self.title = title; self.message = message; self.tone = tone
    }
}

/// A file's diff the person asked to see.
public struct GitDiffRequest: Identifiable, Hashable, Sendable {
    public let row: GitSession.Row
    public let repository: String
    public var id: String { repository + "|" + row.id }
}

/// A Git tab: the workspace's repositories, the chosen one's branch and changes (Staged Changes,
/// Changes and merge conflicts, each file's status in words), staging, the commit identity and the
/// commit itself. Each read and change captures the host, tab, repository and refresh generation it
/// was made for, and a late answer for anything else is dropped. Nothing is sent while offline, a
/// change whose answer was lost is reported and never sent again, and every change reads the status
/// again.
@MainActor @Observable public final class GitSession: WorkspaceSession {
    /// One line of the list: a change as it stands in the index (Staged Changes), in the working tree
    /// (Changes) or unmerged (Merge Conflicts). A file changed in both shows in both.
    public struct Row: Identifiable, Hashable, Sendable {
        public enum Area: String, Sendable { case conflicts, staged, changes }
        public let area: Area
        public let change: GitChange

        public var id: String { area.rawValue + "|" + change.path }
        public var path: String { change.path }
        /// The file's name, or a folder's name with its slash.
        public var name: String {
            let trimmed = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
            let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
            return change.path.hasSuffix("/") ? last + "/" : last
        }
        /// The folder the file is in, relative to the repository; empty at its top.
        public var folder: String {
            let trimmed = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
            guard let slash = trimmed.lastIndex(of: "/") else { return "" }
            return String(trimmed[..<slash])
        }
        /// The status letter this row shows.
        public var letter: String {
            switch area {
            case .staged: change.index
            case .changes: change.untracked ? "U" : change.worktree
            case .conflicts: "!"
            }
        }
        /// The status in words.
        public var words: String { GitWords.status(of: self) }
        /// What its diff compares: the index for a staged change, the working tree against the index
        /// for an unstaged one, the working tree against HEAD for a conflict.
        public var diffBase: GitDiffBase {
            switch area {
            case .staged: .staged
            case .changes: .index
            case .conflicts: .head
            }
        }
        /// An untracked folder: its diff is empty until it is staged.
        public var isFolder: Bool { change.path.hasSuffix("/") }
    }

    public let tabID: UUID
    public let projectID: String

    public private(set) var repositories: [GitRepository] = []
    public private(set) var repository: GitRepository?
    public private(set) var status: GitStatusResponse?
    /// Who a commit is made as; nil on hosts without `identity` or until read.
    public private(set) var identity: GitIdentity?
    public private(set) var loading = false
    /// Why the repositories or the status could not be read.
    public private(set) var loadIssue: String?
    public var notice: GitNotice?
    /// Paths with a stage or unstage in flight.
    public private(set) var busyPaths: Set<String> = []
    public private(set) var committing = false
    /// Bumped by each commit the host confirmed: the success haptic.
    public private(set) var commits = 0
    public private(set) var lastCommit: GitCommitReceipt?
    public private(set) var branches: [GitBranch] = []
    public private(set) var history: [GitHistoryCommit] = []
    public private(set) var historyCursor: String?
    public private(set) var remotes: [GitRemote] = []
    public private(set) var stashes: [GitStash] = []
    public private(set) var managementIssue: String?
    public private(set) var managing = false
    public private(set) var loadingHistory = false
    public private(set) var commitFiles: [String: GitCommitFiles] = [:]
    public private(set) var detailIssues: [String: String] = [:]
    public private(set) var loadingDetails: Set<String> = []
    public var savedDiff: GitSavedDiffRequest?
    public var newBranchName = ""
    public var stashMessage = ""
    public var stashIncludeUntracked = false
    /// The diff sheet.
    public var diff: GitDiffRequest?
    /// The commit message being written. It is kept with the tab.
    public var message = "" {
        didSet { if message != oldValue { scheduleDraftSave() } }
    }

    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var firstLoadResolved = false
    @ObservationIgnored private var resolvedRefreshGeneration: UUID?
    /// The connection epoch the last read resolved in.
    @ObservationIgnored private var resolvedConnectionEpoch: Int?
    @ObservationIgnored private var draftTask: Task<Void, Never>?

    public init(tab: WorkspaceTab, workspace: WorkspaceModel) {
        tabID = tab.id
        projectID = tab.projectID
        self.workspace = workspace
        message = tab.draft
    }

    public func end() {
        loadID = UUID()
        savedDiff = nil
        draftTask?.cancel()
        draftTask = nil
    }

    // MARK: What the host offers

    public func supports(_ feature: GitFeature) -> Bool { workspace?.capabilities?.supportsGit(feature) == true }
    public var canStage: Bool { supports(.stage) }
    public var canUnstage: Bool { supports(.unstage) }
    public var reachable: Bool { workspace?.reachable ?? false }

    // MARK: Rows

    public var conflictRows: [Row] {
        (status?.changes ?? []).filter(\.conflicted).map { Row(area: .conflicts, change: $0) }
    }
    public var stagedRows: [Row] {
        (status?.changes ?? []).filter { !$0.conflicted && !$0.untracked && !$0.index.isEmpty && $0.index != "?" }
            .map { Row(area: .staged, change: $0) }
    }
    public var changeRows: [Row] {
        (status?.changes ?? []).filter { !$0.conflicted && ($0.untracked || !$0.worktree.isEmpty) }
            .map { Row(area: .changes, change: $0) }
    }
    /// The working tree matches HEAD.
    public var isClean: Bool { status != nil && (status?.changes.isEmpty ?? true) }

    // MARK: Loading

    /// Reads the repositories and the status unless this refresh generation already resolved, so a
    /// rebuilt view does not read them again.
    public func loadIfNeeded() async {
        guard let workspace else { return }
        // A read that failed is tried again once the host has come back (a new connection epoch), also when
        // the Git pane was not on screen at that moment to see it come back.
        let failedBeforeRecovery = (loadIssue != nil || managementIssue != nil) && resolvedConnectionEpoch != workspace.connectionEpoch
        if firstLoadResolved, !loading, resolvedRefreshGeneration == workspace.tabRefreshGeneration[tabID], !failedBeforeRecovery {
            reportPresentationIfReady()
            return
        }
        await load()
    }

    /// Reads the workspace's repositories, keeps the chosen one when it is still there, and reads its
    /// status and commit identity.
    public func load() async {
        guard let workspace else { return }
        let refreshGeneration = workspace.tabRefreshGeneration[tabID]
        guard let client = workspace.client else {
            loading = false
            loadIssue = "The host is unavailable."
            resolve(refreshGeneration)
            return
        }
        let hostID = workspace.hostID
        let id = UUID()
        loadID = id
        loading = true
        loadIssue = nil
        defer {
            if current(id, hostID, refreshGeneration) {
                loading = false
                resolve(refreshGeneration)
            }
        }
        do {
            let found = try await client.gitRepositories(projectID: projectID)
            guard current(id, hostID, refreshGeneration) else { return }
            repositories = found
            let chosen = found.first { $0.path == repository?.path } ?? found.first
            if chosen?.path != repository?.path { status = nil; identity = nil; resetManagement() }
            repository = chosen
            guard let chosen else {
                status = nil
                identity = nil
                return
            }
            try await readStatus(client: client, repository: chosen, id: id, hostID: hostID, refreshGeneration: refreshGeneration)
        } catch {
            guard current(id, hostID, refreshGeneration) else { return }
            loadIssue = error.localizedDescription
        }
    }

    /// Shows another repository of the workspace.
    public func select(_ chosen: GitRepository) async {
        guard chosen.path != repository?.path else { return }
        repository = chosen
        status = nil
        identity = nil
        diff = nil
        resetManagement()
        await refreshStatus()
    }

    /// Reads the chosen repository's status (and identity) again.
    public func refreshStatus() async {
        guard let workspace, let client = workspace.client, let repository else { return }
        let refreshGeneration = workspace.tabRefreshGeneration[tabID]
        let hostID = workspace.hostID
        let id = UUID()
        loadID = id
        loading = true
        defer { if current(id, hostID, refreshGeneration) { loading = false; resolve(refreshGeneration) } }
        do {
            try await readStatus(client: client, repository: repository, id: id, hostID: hostID, refreshGeneration: refreshGeneration)
            if current(id, hostID, refreshGeneration) { loadIssue = nil }
        } catch {
            guard current(id, hostID, refreshGeneration) else { return }
            loadIssue = error.localizedDescription
        }
    }

    private func readStatus(client: APIClient, repository: GitRepository, id: UUID, hostID: String?, refreshGeneration: UUID?) async throws {
        async let identityRead: GitIdentity? = supports(.identity) ? try? client.gitIdentity(projectID: projectID, repository: repository.path) : nil
        let read = try await client.gitStatus(projectID: projectID, repository: repository.path, allUntracked: supports(.untrackedFiles))
        let who = await identityRead
        guard current(id, hostID, refreshGeneration), self.repository?.path == repository.path else { return }
        let changed = status.map { $0 != read } ?? false
        status = read
        identity = who
        // The sidebar's count covers every repository of the workspace; read it again when this one moved.
        if changed { Task { await workspace?.sidebar.refreshGit() } }
        await readManagement(client: client, repository: repository, id: id, hostID: hostID, refreshGeneration: refreshGeneration)
    }

    private func current(_ id: UUID, _ hostID: String?, _ refreshGeneration: UUID?) -> Bool {
        guard let workspace else { return false }
        return !Task.isCancelled && loadID == id && workspace.isCurrent(hostID: hostID, tabID: tabID)
            && workspace.tabRefreshGeneration[tabID] == refreshGeneration
    }

    private func resolve(_ refreshGeneration: UUID?) {
        firstLoadResolved = true
        resolvedRefreshGeneration = refreshGeneration
        resolvedConnectionEpoch = workspace?.connectionEpoch
        reportPresentationIfReady()
    }

    /// Readiness for the current opening, once this refresh generation resolved.
    public func reportPresentationIfReady() {
        guard let workspace, firstLoadResolved, !loading,
              resolvedRefreshGeneration == workspace.tabRefreshGeneration[tabID],
              let ticket = workspace.presentationRequest(for: tabID) else { return }
        workspace.reportPresentationReady(ticket)
    }

    // MARK: Staging

    public func stage(_ rows: [Row]) async {
        await changeIndex(rows, staging: true)
    }

    public func unstage(_ rows: [Row]) async {
        await changeIndex(rows, staging: false)
    }

    /// Stage All: everything under Changes (conflicts stay until the person marks them).
    public func stageAll() async { await stage(changeRows) }
    public func unstageAll() async { await unstage(stagedRows) }

    private func changeIndex(_ rows: [Row], staging: Bool) async {
        guard !rows.isEmpty, !isMutating, staging ? canStage : canUnstage, let repository else { return }
        guard let (client, hostID) = changeClient() else { return }
        // Unstaging a rename takes both of its paths.
        var files: [String] = []
        for row in rows {
            if !files.contains(row.path) { files.append(row.path) }
            if !staging, let original = row.change.originalPath, !files.contains(original) { files.append(original) }
        }
        let paths = Set(rows.map(\.path))
        busyPaths.formUnion(paths)
        defer { busyPaths.subtract(paths) }
        var outcome: GitChangeOutcome<Int> = .done(0)
        // The host takes 500 paths at a time; stop at the first batch that doesn't go through.
        for start in stride(from: 0, to: files.count, by: 500) {
            let batch = Array(files[start..<min(start + 500, files.count)])
            outcome = staging ? await client.gitStage(projectID: projectID, repository: repository.path, files: batch)
                              : await client.gitUnstage(projectID: projectID, repository: repository.path, files: batch)
            guard case .done = outcome else { break }
        }
        guard workspace?.isCurrent(hostID: hostID, tabID: tabID) == true, self.repository?.path == repository.path else { return }
        switch outcome {
        case .done:
            let count = rows.count
            let noun = count == 1 ? "“\(rows[0].name)”" : "\(count) files"
            notice = GitNotice(staging ? "Staged \(noun)" : "Unstaged \(noun)", tone: .success)
        case let .refused(refusal):
            let words = GitWords.refusal(refusal)
            notice = GitNotice(words.title, message: words.message, tone: .error)
        case let .failed(error):
            notice = GitNotice(staging ? "Not staged" : "Not unstaged", message: error.localizedDescription, tone: .error)
        case let .uncertain(timedOut):
            notice = GitNotice(staging ? "Staging not confirmed" : "Unstaging not confirmed",
                               message: GitWords.unconfirmed(timedOut: timedOut), tone: .warning)
        }
        // Read what the index holds now, whatever the answer was.
        await refreshStatus()
    }

    // MARK: Committing

    public static let messageLimit = 16 << 10

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether a commit may be made as the bar shows it: something staged, a message, a known
    /// identity (on hosts that report one), the host reachable and the commit route offered.
    public var canCommit: Bool { commitBlocker == nil && !isMutating }

    /// Why Commit is unavailable, in words; nil when it is available.
    public var commitBlocker: String? {
        guard supports(.commit) else { return "This host doesn’t make commits." }
        guard reachable else { return "You’re offline." }
        guard !stagedRows.isEmpty else { return "Stage changes to commit them." }
        guard conflictRows.isEmpty else { return "Resolve the merge conflicts first." }
        if supports(.identity) {
            guard let identity else { return "Reading the commit identity…" }
            guard identity.isComplete else { return GitWords.identityMissing }
        }
        guard !trimmedMessage.isEmpty else { return "Write a commit message." }
        guard message.utf8.count <= Self.messageLimit else { return "Commit messages are limited to 16 KB." }
        return nil
    }

    /// Commits what is staged with the message, as the identity the bar shows. An answer that was
    /// lost, or a Git timeout, keeps the message and says to check the log: the commit may exist.
    public func commit() async {
        guard canCommit, let repository else { return }
        guard let (client, hostID) = changeClient() else { return }
        let sent = message
        committing = true
        let author = supports(.identity) ? identity : nil
        let outcome = await client.gitCommit(projectID: projectID, repository: repository.path, message: sent, author: author)
        committing = false
        guard workspace?.isCurrent(hostID: hostID, tabID: tabID) == true, self.repository?.path == repository.path else { return }
        switch outcome {
        case let .done(receipt):
            lastCommit = receipt
            commits &+= 1
            if message == sent { message = "" }
            notice = GitNotice(receipt.commit.isEmpty ? "Committed" : "Committed \(receipt.shortHash)",
                               message: receipt.hooksSkipped ? "Commit hooks don’t run from AgentLand." : nil, tone: .success)
        case let .refused(refusal):
            let words = GitWords.refusal(refusal)
            notice = GitNotice(words.title, message: words.message, tone: .error)
        case let .failed(error):
            notice = GitNotice("Not committed", message: error.localizedDescription, tone: .error)
        case let .uncertain(timedOut):
            notice = GitNotice("Commit not confirmed", message: GitWords.unconfirmed(timedOut: timedOut), tone: .warning)
        }
        await refreshStatus()
    }

    // MARK: Shared

    private func changeClient() -> (APIClient, String?)? {
        guard let workspace else { return nil }
        guard workspace.reachable, let client = workspace.client else {
            notice = GitNotice("You’re offline, so nothing was changed.", tone: .warning)
            return nil
        }
        return (client, workspace.hostID)
    }

    /// The message is kept with the tab shortly after typing stops, so it outlives the app.
    private func scheduleDraftSave() {
        draftTask?.cancel()
        let tabID = self.tabID
        draftTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.workspace?.updateDraft(tabID, self.message)
        }
    }

    /// The diff of a row, in a sheet.
    public func showDiff(_ row: Row) {
        guard let repository else { return }
        diff = GitDiffRequest(row: row, repository: repository.path)
    }

    /// What a diff of `row` asks the host for: the staged or unstaged changes where the host offers
    /// them, the working tree against HEAD otherwise.
    public func diffBase(for row: Row) -> GitDiffBase {
        switch row.diffBase {
        case .staged: supports(.stagedDiff) ? .staged : .head
        case .index: supports(.unstagedDiff) ? .index : .head
        case .head: .head
        }
    }

    /// Reads one file's diff for the sheet.
    public func loadDiff(_ request: GitDiffRequest) async throws -> GitDiffResponse {
        guard let workspace, let client = workspace.client else { throw ClientError.unreachable }
        return try await client.gitDiff(projectID: projectID, repository: request.repository, file: request.row.path,
                                         base: diffBase(for: request.row))
    }

    // MARK: Management tree

    public var isMutating: Bool { managing || committing || !busyPaths.isEmpty }
    public var unstagedRows: [Row] { changeRows.filter { !$0.change.untracked } }
    public var untrackedRows: [Row] { changeRows.filter { $0.change.untracked } }
    public var canSaveStash: Bool {
        supports(.stashes) && reachable && !isMutating && conflictRows.isEmpty
            && (!stagedRows.isEmpty || !unstagedRows.isEmpty || (stashIncludeUntracked && !untrackedRows.isEmpty))
    }

    private func resetManagement() {
        branches = []; history = []; historyCursor = nil; remotes = []; stashes = []
        managementIssue = nil; commitFiles = [:]; detailIssues = [:]; loadingDetails = []
        savedDiff = nil
    }

    private func readManagement(client: APIClient, repository: GitRepository, id: UUID, hostID: String?, refreshGeneration: UUID?) async {
        async let branchRead: [GitBranch]? = supports(.branches) ? try? client.gitBranches(projectID: projectID, repository: repository.path) : nil
        async let historyRead: GitHistoryPage? = supports(.history) ? try? client.gitHistory(projectID: projectID, repository: repository.path) : nil
        async let remoteRead: [GitRemote]? = supports(.remotes) ? try? client.gitRemotes(projectID: projectID, repository: repository.path) : nil
        async let stashRead: [GitStash]? = supports(.stashes) ? try? client.gitStashes(projectID: projectID, repository: repository.path) : nil
        let (newBranches, newHistory, newRemotes, newStashes) = await (branchRead, historyRead, remoteRead, stashRead)
        guard current(id, hostID, refreshGeneration), self.repository?.path == repository.path else { return }
        if let newBranches { branches = newBranches }
        if let newHistory { history = newHistory.commits; historyCursor = newHistory.nextCursor }
        if let newRemotes { remotes = newRemotes }
        if let newStashes { stashes = newStashes }
        let failed = (supports(.branches) && newBranches == nil) || (supports(.history) && newHistory == nil)
            || (supports(.remotes) && newRemotes == nil) || (supports(.stashes) && newStashes == nil)
        managementIssue = failed ? "Some Git sections could not be read. Refresh to try again." : nil
    }

    public func loadMoreHistory() async {
        guard supports(.history), !loadingHistory, let cursor = historyCursor, !cursor.isEmpty,
              let workspace, let client = workspace.client, let repository else { return }
        let hostID = workspace.hostID, generation = workspace.tabRefreshGeneration[tabID], id = loadID
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let page = try await client.gitHistory(projectID: projectID, repository: repository.path, cursor: cursor)
            guard current(id, hostID, generation), self.repository?.path == repository.path else { return }
            let known = Set(history.map(\.hash))
            history.append(contentsOf: page.commits.filter { !known.contains($0.hash) })
            historyCursor = page.nextCursor
        } catch {
            guard current(id, hostID, generation) else { return }
            managementIssue = error.localizedDescription
        }
    }

    public func loadFiles(commit hash: String, stash: Bool = false) async {
        let key = (stash ? "stash|" : "commit|") + hash
        guard commitFiles[key] == nil, !loadingDetails.contains(key),
              let workspace, let client = workspace.client, let repository else { return }
        let hostID = workspace.hostID, generation = workspace.tabRefreshGeneration[tabID], id = loadID
        loadingDetails.insert(key); detailIssues[key] = nil
        defer { loadingDetails.remove(key) }
        do {
            let detail = try await client.gitCommitFiles(projectID: projectID, repository: repository.path, commit: hash, stash: stash)
            guard current(id, hostID, generation), self.repository?.path == repository.path else { return }
            commitFiles[key] = detail
        } catch {
            guard current(id, hostID, generation) else { return }
            detailIssues[key] = error.localizedDescription
        }
    }

    public func showSavedDiff(commit hash: String, file: GitCommitFile, stash: Bool = false) {
        guard let repository else { return }
        savedDiff = GitSavedDiffRequest(repository: repository.path, commit: hash, file: file.path, stash: stash)
    }

    public func loadSavedDiff(_ request: GitSavedDiffRequest) async throws -> GitDiffResponse {
        guard let workspace, let client = workspace.client else { throw ClientError.unreachable }
        return try await client.gitCommitDiff(projectID: projectID, repository: request.repository, commit: request.commit, file: request.file, stash: request.stash)
    }

    public func createBranch(_ name: String) async {
        guard supports(.branches) else { return }
        let made = await managementChange("Created branch") { client, path in
            await client.gitBranch(projectID: self.projectID, repository: path, action: .create, name: name)
        }
        // The field is for the next branch: the one made is in the list now.
        if made, newBranchName.trimmingCharacters(in: .whitespacesAndNewlines) == name { newBranchName = "" }
    }
    public func switchBranch(_ name: String) async {
        guard supports(.branches) else { return }
        await managementChange("Switched branch") { client, path in
            await client.gitBranch(projectID: self.projectID, repository: path, action: .switch, name: name)
        }
    }
    public func trackBranch(_ source: String, name: String) async {
        guard supports(.branches) else { return }
        await managementChange("Checked out remote branch") { client, path in
            await client.gitBranch(projectID: self.projectID, repository: path, action: .track, name: name, source: source)
        }
    }
    public func deleteBranch(_ name: String) async {
        guard supports(.branches) else { return }
        await managementChange("Deleted branch") { client, path in
            await client.gitBranch(projectID: self.projectID, repository: path, action: .delete, name: name)
        }
    }
    public func remote(_ remote: GitRemote, action: GitRemoteAction) async {
        guard supports(.remotes), remote.supported else { return }
        let title = switch action { case .fetch: "Fetched"; case .pull: "Pulled"; case .push: "Pushed" }
        await managementChange(title) { client, path in
            await client.gitRemote(projectID: self.projectID, repository: path, action: action, remote: remote.name)
        }
    }
    public func saveStash() async {
        guard canSaveStash else { return }
        let message = stashMessage, include = stashIncludeUntracked
        await managementChange("Saved stash") { client, path in
            await client.gitStash(projectID: self.projectID, repository: path, action: .save, message: message, includeUntracked: include)
        }
    }
    public func applyStash(_ stash: GitStash) async {
        guard supports(.stashes) else { return }
        await managementChange("Applied stash") { client, path in
            await client.gitStash(projectID: self.projectID, repository: path, action: .apply, hash: stash.hash)
        }
    }
    public func dropStash(_ stash: GitStash) async {
        guard supports(.stashes) else { return }
        await managementChange("Dropped stash") { client, path in
            await client.gitStash(projectID: self.projectID, repository: path, action: .drop, hash: stash.hash)
        }
    }
    public func discard(_ row: Row) async {
        guard supports(.discard), row.area == .changes, !row.change.untracked, !row.isFolder else { return }
        await managementChange("Discarded unstaged changes") { client, path in
            await client.gitDiscard(projectID: self.projectID, repository: path, files: [row.path], confirmed: true)
        }
    }

    /// Runs a branch, remote or stash change and says how it went; true when the host made it.
    @discardableResult
    private func managementChange(_ title: String, request: (APIClient, String) async -> GitChangeOutcome<GitManagementReceipt>) async -> Bool {
        guard !isMutating, let repository, let workspace, let (client, hostID) = changeClient() else { return false }
        let generation = workspace.tabRefreshGeneration[tabID]
        managing = true
        let outcome = await request(client, repository.path)
        managing = false
        guard workspace.isCurrent(hostID: hostID, tabID: tabID), workspace.tabRefreshGeneration[tabID] == generation,
              self.repository?.path == repository.path else { return false }
        var made = false
        switch outcome {
        case .done: notice = GitNotice(title, tone: .success); made = true
        case let .refused(refusal):
            let words = GitWords.refusal(refusal)
            notice = GitNotice(words.title, message: words.message, tone: .error)
        case let .failed(error): notice = GitNotice("Git operation failed", message: error.localizedDescription, tone: .error)
        case let .uncertain(timedOut): notice = GitNotice("Git operation not confirmed", message: GitWords.unconfirmed(timedOut: timedOut), tone: .warning)
        }
        await refreshStatus()
        return made
    }
}

public struct GitSavedDiffRequest: Identifiable, Hashable, Sendable {
    public let repository: String
    public let commit: String
    public let file: String
    public let stash: Bool
    public var id: String { repository + "|" + commit + "|" + file + "|" + String(stash) }
}

/// Git's states and refusals in plain words.
public enum GitWords {
    public static let identityMissing = "No commit name and email are set. Set user.name and user.email for this repository on your Mac."

    public static func status(of row: GitSession.Row) -> String {
        let change = row.change
        switch row.area {
        case .conflicts:
            switch change.status {
            case "DD": return "Both deleted"
            case "AU": return "Added by us"
            case "UD": return "Deleted by them"
            case "UA": return "Added by them"
            case "DU": return "Deleted by us"
            case "AA": return "Both added"
            default: return "Both modified"
            }
        case .staged:
            return letter(change.index, original: change.originalPath)
        case .changes:
            if change.untracked { return row.isFolder ? "Untracked folder" : "Untracked" }
            return letter(change.worktree, original: change.originalPath)
        }
    }

    static func letter(_ letter: String, original: String?) -> String {
        switch letter {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": original.map { "Renamed from \($0)" } ?? "Renamed"
        case "C": original.map { "Copied from \($0)" } ?? "Copied"
        case "T": "Type changed"
        case "U": "Unmerged"
        case "?": "Untracked"
        default: "Changed"
        }
    }

    public static func refusal(_ refusal: GitRefusal) -> (title: String, message: String?) {
        switch refusal {
        case .identityMissing:
            ("No commit identity", identityMissing)
        case .signingRequired:
            ("Signed commits are required", "This repository or your Git settings require GPG-signed commits, which AgentLand doesn’t make. Commit on your Mac.")
        case .filterUnsupported:
            ("Git filters require the Mac", "This operation would run a Git filter such as Git LFS. Manage these files on your Mac.")
        case .busy:
            ("Git is busy", "Another Git command is running in this repository. Try again in a moment.")
        case .indexLocked:
            ("Git’s index is locked", "If no other Git command is running on your Mac, remove .git/index.lock, then try again.")
        case .nothingToCommit:
            ("Nothing to commit", "Stage changes before committing.")
        case .conflict:
            ("Merge conflicts", "Resolve the merge conflicts, then stage the files.")
        case .pathInvalid:
            ("A file wasn’t found", "It may have been moved, deleted or ignored. The list was read again.")
        case .failed:
            ("Git couldn’t finish", "Check the repository on your Mac and refresh Git before trying again.")
        case let .other(_, message):
            ("Git refused", message)
        }
    }

    public static func unconfirmed(timedOut: Bool) -> String {
        timedOut ? "Git didn’t finish in time. It may have run — check the log before trying again."
                 : "The operation wasn’t confirmed. It may have run — refresh Git and check the log before trying again."
    }
}
