import Foundation
import Observation
import AgentLandCore

/// A notice on the Workspaces screen after an action.
public struct WorkspaceNotice: Identifiable, Hashable, Sendable {
    public enum Tone: Hashable, Sendable { case success, warning, error }

    public let id = UUID()
    public let title: String
    public let message: String?
    public let tone: Tone

    public init(_ title: String, message: String? = nil, tone: Tone) {
        self.title = title
        self.message = message
        self.tone = tone
    }
}

/// One workspace as the Workspaces screen lists it.
public struct WorkspaceSummary: Identifiable, Hashable, Sendable {
    public let project: Project
    /// Its folder with the home folder shown as `~`; nil from hosts without details.
    public let folder: String?
    /// Its tabs open on this device.
    public let openTabs: Int
    /// The workspace in use on this device.
    public let isCurrent: Bool
    /// When it was last the workspace in use on this device.
    public let lastUsed: Date?
    /// Open on this device: used here and not closed here since (`WorkspaceManager.summary`).
    public let isOpen: Bool

    public var id: String { project.id }

    /// "2 chats running · 1 terminal", from what the host counts on every device; nil when nothing runs.
    public var activity: String? {
        guard let activity = project.activity else { return nil }
        var parts: [String] = []
        if activity.busyChats > 0 { parts.append(activity.busyChats == 1 ? "1 chat running" : "\(activity.busyChats) chats running") }
        if activity.terminals > 0 { parts.append(activity.terminals == 1 ? "1 terminal" : "\(activity.terminals) terminals") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Close's question: the tabs that close on this device and the terminals this device opened there.
public struct WorkspaceCloseRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let project: Project
    public let tabs: Int
    /// Editors among the tabs with changes not saved to the host.
    public let unsavedEditors: Int
    /// This device's terminals in the workspace, as the host lists them (a device sees only its own).
    public let terminals: [RemoteTerminal]

    public init(project: Project, tabs: Int, unsavedEditors: Int = 0, terminals: [RemoteTerminal] = []) {
        self.project = project
        self.tabs = tabs
        self.unsavedEditors = unsavedEditors
        self.terminals = terminals
    }

    /// The terminals that still run; closing the others only tidies the host's list.
    public var liveTerminals: Int { terminals.filter { $0.status != .exited }.count }

    public var title: String { "Close \(project.name)?" }

    /// "Its 3 tabs close on this device and its 2 terminals end."
    public var message: String {
        let tabPart = tabs == 0 ? nil : tabs == 1 ? "its 1 tab closes on this device" : "its \(tabs) tabs close on this device"
        let terminalPart = liveTerminals == 0 ? nil : liveTerminals == 1 ? "its 1 terminal ends" : "its \(liveTerminals) terminals end"
        var sentences: [String] = []
        switch (tabPart, terminalPart) {
        case let (tabs?, terminals?): sentences.append(Self.capitalized("\(tabs) and \(terminals)."))
        case let (tabs?, nil): sentences.append(Self.capitalized(tabs + "."))
        case let (nil, terminals?): sentences.append(Self.capitalized(terminals + "."))
        case (nil, nil): break
        }
        if unsavedEditors > 0 {
            sentences.append(unsavedEditors == 1 ? "Unsaved changes in 1 file are discarded." : "Unsaved changes in \(unsavedEditors) files are discarded.")
        }
        return sentences.isEmpty ? "This workspace closes on this device." : sentences.joined(separator: " ")
    }

    private static func capitalized(_ sentence: String) -> String { sentence.prefix(1).uppercased() + sentence.dropFirst() }
}

/// Remove, after the host answered that work runs in the workspace.
public struct WorkspaceBusyRemoval: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let project: Project
    public let busyChats: Int
    public let terminals: Int

    public init(project: Project, busyChats: Int, terminals: Int) {
        self.project = project
        self.busyChats = busyChats
        self.terminals = terminals
    }

    /// Only terminals keep it: they can be ended and the workspace removed. A running chat turn refuses.
    public var canEndTerminals: Bool { busyChats == 0 }
}

/// How adding or creating a workspace ended, for the sheet that asked.
public enum WorkspaceAddResult: Equatable, Sendable {
    /// The workspace to open: the new one, or the one the folder already is.
    case open(String)
    /// Nothing was made; the sheet stays and says why.
    case problem(String)
    /// Not confirmed either way: the list was read again, and the screen's notice says so.
    case unconfirmed
    /// The host changed meanwhile; the answer no longer applies.
    case dropped
}

/// The Workspaces screen's state and actions on the attached host: the list with each workspace's
/// folder, Git badge, activity and last use on this device; Close (this device's tabs and the terminals
/// it opened there), Rename, Remove, Add Folder and New Workspace through the routes the host lists in
/// `capabilities.projects` (docs/HOST-API.md, "Workspaces").
///
/// Every request captures the host and client it was made for; an answer for another is dropped,
/// success or failure. Changes need the host now and are never sent again by themselves: an outcome
/// the host did not confirm is reported, and the list is read again.
@MainActor @Observable public final class WorkspaceManager {
    public var notice: WorkspaceNotice?
    /// Close's question, once this device's terminals there are known.
    public var pendingClose: WorkspaceCloseRequest?
    /// Remove's first question.
    public var pendingRemoval: Project?
    /// Remove's second question, after the host answered that work runs in the workspace.
    public var busyRemoval: WorkspaceBusyRemoval?
    /// The row that asked Close's or Remove's question (`WorkspaceRowDialogs`): its dialog points at that row, and the
    /// Workspaces screen, which lists an open workspace twice, asks it only once.
    public var questionRow: String?
    /// The workspace whose name the rename field edits.
    public var renaming: Project?
    public var renameText = ""
    /// Workspaces with a change or a question on its way to the host.
    public private(set) var changing: Set<String> = []
    /// Adding or creating a workspace is on its way.
    public private(set) var adding = false
    /// The Mac user's home folder, once a folder listing named it; folders show under `~`.
    public private(set) var homePath: String?

    @ObservationIgnored public private(set) weak var workspace: WorkspaceModel?
    @ObservationIgnored private var homeHostID: String?

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    // MARK: What the host offers

    /// The host lists its workspaces with their details: the Workspaces screen replaces the plain
    /// picker. Hosts without it keep the picker.
    public var isAvailable: Bool { supports(.details) }

    public func supports(_ feature: ProjectFeature) -> Bool { workspace?.capabilities?.supportsProjects(feature) == true }

    /// New Workspace: a name, a folder to make it in (from the folder browser) and Git.
    public var canCreate: Bool { supports(.create) && supports(.browse) }
    /// Add Folder: a folder chosen with the folder browser.
    public var canAdd: Bool { supports(.add) && supports(.browse) }
    public var canRename: Bool { supports(.rename) }
    public var canRemove: Bool { supports(.remove) }
    /// The host answers now; changes are refused otherwise.
    public var canChange: Bool { workspace?.client != nil && workspace?.reachable == true }

    private var hostName: String { workspace?.hostName ?? "your Mac" }

    // MARK: Rows

    /// Every workspace, by name.
    public var all: [WorkspaceSummary] {
        guard let workspace else { return [] }
        return workspace.projects.map(summary)
            .sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
    }

    /// The workspaces open on this device (`WorkspaceSummary.isOpen`), the Open list and the iPhone's task switcher:
    /// the one in use first, then by last use.
    public var open: [WorkspaceSummary] {
        all.filter(\.isOpen).sorted { left, right in
            if left.isCurrent != right.isCurrent { return left.isCurrent }
            return (left.lastUsed ?? .distantPast) > (right.lastUsed ?? .distantPast)
        }
    }

    /// One workspace's row: its folder, open tabs, whether it is in use, its last use here and whether it is open here.
    /// Open means used on this device (tabs here, in use, or in use before) and not closed here since: ending or
    /// closing its last task leaves it open with nothing in it; only Close closes it, until it is in use again
    /// (owner, 2026-10-23: after ending one workspace's last terminal and switching away, the switcher dropped it).
    func summary(_ project: Project) -> WorkspaceSummary {
        let workspace = self.workspace
        let openTabs = presentedTabs(inWorkspace: project.id).count
        let isCurrent = workspace?.selectedProjectID == project.id
        let lastUsed = workspace?.lastUsed[project.id]
        let closed = workspace?.closedWorkspaceIDs.contains(project.id) ?? true
        return WorkspaceSummary(project: project, folder: folderText(project.directory), openTabs: openTabs,
                                isCurrent: isCurrent, lastUsed: lastUsed,
                                isOpen: openTabs > 0 || isCurrent || (lastUsed != nil && !closed))
    }

    /// On iPhone, Files and Git live in the drawer's sections, not in its list of open tabs.
    private func presentedTabs(inWorkspace id: String) -> [WorkspaceTab] {
        guard let workspace else { return [] }
        if workspace.phoneNavigation.drawerHoldsBrowsers {
            return workspace.phoneNavigation.workingTasks(inWorkspace: id, model: workspace)
        }
        return workspace.tabs(inWorkspace: id).filter(workspace.supportsTab)
    }

    /// `directory` with the home folder shown as `~`. Before a listing named the home folder, a folder
    /// under `/Users/<name>` is shown under `~`, as it is on nearly every Mac.
    public func folderText(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        if let home = homePath, !home.isEmpty {
            if directory == home { return "~" }
            if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
            return directory
        }
        let parts = directory.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0].isEmpty, parts[1] == "Users", !parts[2].isEmpty, parts[2] != "Shared" {
            return (["~"] + parts.dropFirst(3)).joined(separator: "/")
        }
        return directory
    }

    // MARK: Loading

    /// Reads the host's workspaces again, and the home folder once per host; then the terminals of the other devices
    /// ("On <device>"), which name their workspaces.
    public func refresh() async {
        guard let workspace, let client = workspace.client else { return }
        let hostID = workspace.hostID
        if supports(.browse), homeHostID != hostID || homePath == nil {
            async let listing = try? client.folders()
            await workspace.refreshProjects()
            if let listing = await listing, workspace.hostID == hostID, workspace.client === client { learnHome(from: listing) }
        } else {
            await workspace.refreshProjects()
        }
        guard workspace.hostID == hostID, workspace.client === client else { return }
        await workspace.others.refresh()
    }

    /// Keeps the home folder a listing names (its own path, shown as `~`, or the root shown as `~`).
    func learnHome(from listing: FolderListing) {
        guard let workspace else { return }
        if listing.displayPath == "~" {
            homePath = listing.path
        } else if listing.displayPath.hasPrefix("~/") {
            let below = listing.displayPath.dropFirst(1)
            guard listing.path.hasSuffix(below) else { return }
            homePath = String(listing.path.dropLast(below.count))
        } else {
            return
        }
        homeHostID = workspace.hostID
    }

    /// Everything pending goes with the host.
    func reset() {
        notice = nil
        pendingClose = nil
        pendingRemoval = nil
        busyRemoval = nil
        questionRow = nil
        renaming = nil
        renameText = ""
        changing = []
        adding = false
        homePath = nil
        homeHostID = nil
    }

    /// The questions close (the lock, the opening cover, the sheet going away).
    public func dismissQuestions() {
        pendingClose = nil
        pendingRemoval = nil
        busyRemoval = nil
        questionRow = nil
        renaming = nil
    }

    // MARK: Requests

    /// What a request was made for: the host and the client connection.
    private struct Stamp {
        let hostID: String?
        let client: APIClient
    }

    private func stamp() -> Stamp? {
        guard let workspace, let client = workspace.client else { return nil }
        return Stamp(hostID: workspace.hostID, client: client)
    }

    private func isCurrent(_ stamp: Stamp) -> Bool {
        workspace?.hostID == stamp.hostID && workspace?.client === stamp.client
    }

    /// The host, when it answers now; otherwise the notice says nothing was changed.
    private func changeStamp() -> Stamp? {
        guard canChange, let stamp = stamp() else {
            notice = WorkspaceNotice("\(hostName) isn’t connected", message: "Nothing was changed. Try again once it’s connected.",
                                     tone: .warning)
            return nil
        }
        return stamp
    }

    private func project(_ id: String) -> Project? { workspace?.projects.first { $0.id == id } }

    // MARK: Close

    /// Close asks first how many tabs close here and which of this device's terminals end; the host
    /// lists them (a device sees only its own).
    public func requestClose(_ project: Project) async {
        guard let workspace, !changing.contains(project.id) else { return }
        let tabs = presentedTabs(inWorkspace: project.id)
        let unsaved = tabs.filter { $0.kind == .editor && $0.editorDirty }.count
        var terminals: [RemoteTerminal] = []
        if workspace.capabilities?.terminal == true {
            guard let stamp = changeStamp() else { return }
            changing.insert(project.id)
            let listed: Result<[RemoteTerminal], Error>
            do { listed = .success(try await stamp.client.terminals(projectID: project.id)) } catch { listed = .failure(error) }
            guard isCurrent(stamp) else { return }
            changing.remove(project.id)
            switch listed {
            case let .success(value): terminals = Self.ownTerminals(value, inWorkspace: project.id, of: workspace)
            case let .failure(error):
                if error is CancellationError { return }
                notice = WorkspaceNotice("Couldn’t check \(project.name)’s terminals", message: error.localizedDescription, tone: .error)
                return
            }
        }
        pendingClose = WorkspaceCloseRequest(project: project, tabs: tabs.count, unsavedEditors: unsaved, terminals: terminals)
    }

    /// Closes the workspace on this device: its tabs close (a workspace in use no longer is), then each
    /// terminal this device opened there ends through `POST /v1/terminal/close`. Chats are kept.
    public func close(_ request: WorkspaceCloseRequest) async {
        pendingClose = nil
        guard let workspace else { return }
        let id = request.project.id
        let stamp = self.stamp()
        // Before its tabs close: the terminals they follow from other devices are never ended here.
        let shared = Set(workspace.tabs(inWorkspace: id).filter { $0.sharedFrom != nil }.map(\.resourceID))
        workspace.closeWorkspace(id)
        guard !request.terminals.isEmpty else { return }
        guard let stamp, canChange else {
            notice = WorkspaceNotice("\(request.project.name)’s terminals are still running",
                                     message: "\(hostName) isn’t connected, so they weren’t ended.", tone: .warning)
            return
        }
        changing.insert(id)
        // Listed again: a terminal opened since the question ends too.
        var terminals = request.terminals
        if let fresh = try? await stamp.client.terminals(projectID: id) { terminals = fresh.filter { !shared.contains($0.id) } }
        var unconfirmed = 0
        for terminal in terminals {
            switch await stamp.client.closeTerminal(projectID: id, terminalID: terminal.id) {
            case .accepted: continue
            // Already gone from the host's list: ended.
            case .failed(.server(code: "terminal_not_found", _)): continue
            default: unconfirmed += 1
            }
        }
        guard isCurrent(stamp) else { return }
        changing.remove(id)
        if unconfirmed > 0 {
            notice = WorkspaceNotice(unconfirmed == 1 ? "A terminal in \(request.project.name) may still be running"
                                                      : "\(unconfirmed) terminals in \(request.project.name) may still be running",
                                     message: "Ending wasn’t confirmed. Open the workspace to check its terminals.", tone: .warning)
        }
    }

    /// The terminals of `id` that Close ends: the ones the host lists, except any a tab here follows from another device
    /// or the Mac (`sharedFrom`), which closing its tab only stops following.
    private static func ownTerminals(_ terminals: [RemoteTerminal], inWorkspace id: String, of workspace: WorkspaceModel) -> [RemoteTerminal] {
        let shared = Set(workspace.tabs(inWorkspace: id).filter { $0.sharedFrom != nil }.map(\.resourceID))
        return terminals.filter { !shared.contains($0.id) }
    }

    // MARK: Rename

    public func requestRename(_ project: Project) {
        renameText = project.name
        renaming = project
    }

    /// Changes only the display name, on every device.
    public func rename(_ project: Project, to raw: String) async {
        renaming = nil
        if let problem = WorkspaceNaming.problem(name: raw) {
            notice = WorkspaceNotice("Couldn’t rename \(project.name)", message: problem, tone: .error)
            return
        }
        guard let name = WorkspaceNaming.displayName(raw), name != project.name else { return }
        guard canRename, let stamp = changeStamp() else { return }
        changing.insert(project.id)
        let outcome = await stamp.client.renameProject(id: project.id, name: name)
        guard isCurrent(stamp), let workspace else { return }
        changing.remove(project.id)
        switch outcome {
        case let .done(renamed):
            if let index = workspace.projects.firstIndex(where: { $0.id == project.id }) {
                workspace.projects[index] = renamed.id == project.id ? renamed : Project(id: project.id, name: name, directory: project.directory,
                                                                                        gitRepository: project.gitRepository, activity: project.activity)
            }
        case let .failed(error):
            notice = WorkspaceNotice("Couldn’t rename \(project.name)", message: error.localizedDescription, tone: .error)
        default:
            notice = WorkspaceNotice("\(project.name) may have been renamed",
                                     message: "The answer didn’t arrive. The list was read again; check it before trying again.", tone: .warning)
            await refresh()
        }
    }

    // MARK: Remove

    public func requestRemoval(_ project: Project) {
        busyRemoval = nil
        pendingRemoval = project
    }

    /// Takes the workspace out of the host's list; its folder and files stay. Its tabs on this device
    /// close. When work runs in it the host refuses, and the second question offers to end its
    /// terminals first (`endTerminals`).
    public func remove(_ project: Project, endTerminals: Bool = false) async {
        pendingRemoval = nil
        busyRemoval = nil
        guard canRemove, !changing.contains(project.id), let stamp = changeStamp() else { return }
        changing.insert(project.id)
        let outcome = await stamp.client.removeProject(id: project.id, endTerminals: endTerminals)
        guard isCurrent(stamp), let workspace else { return }
        changing.remove(project.id)
        switch outcome {
        case .removed:
            workspace.forgetWorkspace(project.id)
            notice = removedNotice(project)
            await refresh()
        case let .busy(busyChats, terminals):
            busyRemoval = WorkspaceBusyRemoval(project: project, busyChats: busyChats, terminals: terminals)
        case .lastWorkspace:
            notice = WorkspaceNotice("\(project.name) is the only workspace",
                                     message: "\(hostName) keeps at least one workspace. Add another, then remove this one.", tone: .warning)
        case let .failed(error):
            notice = WorkspaceNotice("Couldn’t remove \(project.name)", message: error.localizedDescription, tone: .error)
        case .uncertain:
            await refresh()
            guard isCurrent(stamp) else { return }
            if workspace.metadataResolved, workspace.hostIssue == nil, !workspace.projects.contains(where: { $0.id == project.id }) {
                workspace.forgetWorkspace(project.id)
                notice = removedNotice(project)
            } else {
                notice = WorkspaceNotice("\(project.name) may not have been removed",
                                         message: "The answer didn’t arrive. The list was read again; check it before trying again.",
                                         tone: .warning)
            }
        }
    }

    private func removedNotice(_ project: Project) -> WorkspaceNotice {
        WorkspaceNotice("Removed \(project.name)", message: "Its folder and files are still on \(hostName).", tone: .success)
    }

    // MARK: Add and create

    /// Makes `directory` a workspace. A folder that already is one opens that workspace.
    public func add(directory: String) async -> WorkspaceAddResult {
        guard canAdd else { return .problem("\(hostName) doesn’t add folders as workspaces.") }
        guard let stamp = changeStamp() else { return .problem("\(hostName) isn’t connected. Nothing was changed.") }
        adding = true
        defer { adding = false }
        let outcome = await stamp.client.addProject(directory: directory)
        guard isCurrent(stamp) else { return .dropped }
        switch outcome {
        case let .done(project):
            await refresh(keeping: project, stamp: stamp)
            return .open(project.id)
        case let .alreadyWorkspace(projectID):
            await refresh()
            guard isCurrent(stamp) else { return .dropped }
            if let id = projectID ?? workspaceID(at: directory), project(id) != nil { return .open(id) }
            return .problem("That folder is already a workspace.")
        case let .failed(error):
            return .problem(error.localizedDescription)
        case .alreadyExists, .gitFailed, .uncertain:
            return await settle(directory: directory, stamp: stamp, name: (directory as NSString).lastPathComponent, made: "added")
        }
    }

    /// Makes the folder `name` in `parentDirectory` (a Git repository with `git`) and adds it.
    public func create(parentDirectory: String, name raw: String, git: Bool) async -> WorkspaceAddResult {
        guard canCreate else { return .problem("\(hostName) doesn’t make new workspaces.") }
        if let problem = WorkspaceNaming.problem(folder: raw) { return .problem(problem) }
        guard let name = WorkspaceNaming.folderName(raw) else { return .problem("Enter a name.") }
        guard let stamp = changeStamp() else { return .problem("\(hostName) isn’t connected. Nothing was changed.") }
        adding = true
        defer { adding = false }
        let outcome = await stamp.client.createProject(parentDirectory: parentDirectory, name: name, git: git)
        guard isCurrent(stamp) else { return .dropped }
        let directory = parentDirectory.hasSuffix("/") ? parentDirectory + name : parentDirectory + "/" + name
        switch outcome {
        case let .done(project):
            await refresh(keeping: project, stamp: stamp)
            return .open(project.id)
        case .alreadyExists:
            return .problem("“\(name)” is already in \(folderText(parentDirectory) ?? parentDirectory). Choose another name.")
        case let .gitFailed(projectID, message):
            await refresh()
            guard isCurrent(stamp) else { return .dropped }
            guard let id = projectID.flatMap({ self.project($0)?.id }) ?? workspaceID(at: directory) else {
                notice = WorkspaceNotice("\(name) was made, but not as a Git repository", message: message, tone: .warning)
                return .unconfirmed
            }
            notice = WorkspaceNotice("\(name) was made without Git", message: "Git couldn’t start a repository in it: \(message)", tone: .warning)
            return .open(id)
        case let .failed(error):
            return .problem(error.localizedDescription)
        case .alreadyWorkspace, .uncertain:
            return await settle(directory: directory, stamp: stamp, name: name, made: "made")
        }
    }

    /// An add or create the host did not confirm: the list is read again, and a workspace for the folder
    /// there opens.
    private func settle(directory: String, stamp: Stamp, name: String, made: String) async -> WorkspaceAddResult {
        await refresh()
        guard isCurrent(stamp) else { return .dropped }
        if let id = workspaceID(at: directory) { return .open(id) }
        notice = WorkspaceNotice("\(name) may not have been \(made)",
                                 message: "The answer didn’t arrive. The list was read again; check it before trying again.", tone: .warning)
        return .unconfirmed
    }

    /// Reads the list again; the workspace the host answered with is listed even if that read fails.
    private func refresh(keeping project: Project, stamp: Stamp) async {
        await refresh()
        guard isCurrent(stamp), let workspace, !workspace.projects.contains(where: { $0.id == project.id }) else { return }
        workspace.projects.append(project)
    }

    /// The workspace whose folder is `directory`.
    func workspaceID(at directory: String) -> String? {
        let target = Self.standardized(directory)
        return workspace?.projects.first { $0.directory.map(Self.standardized) == target }?.id
    }

    private static func standardized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Folders

    /// The default folder for New Workspace and Add Folder: the home folder's Developer folder when the
    /// listing offers it, else the home folder.
    public static func defaultFolder(in home: FolderListing) -> String {
        home.roots.first { $0.path == home.path + "/Developer" }?.path
            ?? home.folders.first { $0.path == home.path + "/Developer" }?.path
            ?? home.path
    }
}

/// One folder browser's listing: the folder shown, its sub-folders and whether dot folders show. A
/// newer request replaces an older one; an answer for an older one, or for another host, is dropped.
@MainActor @Observable final class FolderBrowserModel {
    private(set) var listing: FolderListing?
    private(set) var loading = false
    private(set) var issue: String?
    /// Dot folders show (`hidden=1`).
    var showHidden = false

    @ObservationIgnored private weak var workspaces: WorkspaceManager?
    @ObservationIgnored private var token = UUID()

    init(workspaces: WorkspaceManager) {
        self.workspaces = workspaces
    }

    /// Shows `path` (the home folder when nil).
    func open(_ path: String?) async {
        guard let workspace = workspaces?.workspace, let client = workspace.client else {
            issue = "The host isn’t connected."
            loading = false
            return
        }
        let request = UUID()
        token = request
        let hostID = workspace.hostID
        loading = true
        issue = nil
        let result: Result<FolderListing, Error>
        do { result = .success(try await client.folders(path: path, includeHidden: showHidden)) } catch { result = .failure(error) }
        guard token == request, workspace.hostID == hostID, workspace.client === client else { return }
        loading = false
        switch result {
        case let .success(value):
            listing = value
            workspaces?.learnHome(from: value)
        case let .failure(error):
            if error is CancellationError { return }
            issue = error.localizedDescription
        }
    }

    /// Lists the folder shown again (after Show Hidden Folders changes).
    func reload() async { await open(listing?.path) }

    /// The path's steps from the home folder (`~`, `Developer`, `AgentLand`), each with the folder it
    /// opens; one step for a folder outside the home folder's display.
    var breadcrumb: [(name: String, path: String)] {
        guard let listing else { return [] }
        let names = listing.displayPath.split(separator: "/").map(String.init)
        let components = listing.path.split(separator: "/").map(String.init)
        guard !names.isEmpty, names.count <= components.count else { return [(listing.displayPath, listing.path)] }
        return names.indices.map { index in
            let kept = components.count - (names.count - 1 - index)
            return (names[index], "/" + components.prefix(kept).joined(separator: "/"))
        }
    }
}
