import Foundation
import Observation
import SwiftUI
import AgentLandCore

/// The iPhone's task switcher (the panel under the page's title, `switcherSections`) and the Files and Git pages that
/// Workspace opens (owner, 2026-10-11: bottom tabs replace the left drawer).
@MainActor @Observable final class WorkspacePhoneNavigation {
    /// Files and Git browse the current workspace.
    enum DrawerSection: String, Hashable, CaseIterable, Identifiable {
        /// The workspace in use's file tree.
        case files
        /// The workspace in use's repository: history and commit.
        case git
        var id: String { rawValue }
        var title: String {
            switch self {
            case .files: "Files"
            case .git: "Git"
            }
        }
    }
    /// A page pushed over a drawer section, inside the same panel.
    enum DrawerPage: Hashable {
        /// A file of the Files section, read-only, with Open in Workspace (owner's request, 2026-10-06: "click to
        /// inspect a file and open it in workspace").
        case file(projectID: String, path: String)
        /// A commit of the Git section's History, or a stash, with the files it changed (native-iOS batch 9, GI-8), read
        /// through the Git tab `tabID`'s session.
        case savedChange(tabID: UUID, hash: String, stash: Bool, title: String)
        var title: String {
            switch self {
            case let .file(_, path): path.split(separator: "/").last.map(String.init) ?? path
            case let .savedChange(_, _, _, title): title
            }
        }
    }
    /// The task switcher's popover is up (`PhoneTaskSwitcherTitle`); `dismissPopovers()` closes it.
    var tabSwitcherShown = false
    /// The views that show a standalone terminal's screen (`StandaloneTerminalView`, pushed from the Workspace tab): that
    /// screen is an open session surface, so the bottom tab bar hides while one shows (2026-10-11: "Only open session
    /// surfaces hide the bar"). By view, since a screen built again in place appears before the old one goes.
    private(set) var standaloneScreens: Set<UUID> = []
    /// The last section used for this app lifetime, Files at first. Another section starts at its root.
    var drawerSection: DrawerSection = .files {
        didSet { if drawerSection != oldValue { drawerPath = [] } }
    }
    /// The pages pushed in the drawer; they go when the drawer does.
    var drawerPath: [DrawerPage] = []
    /// The iPhone shell is up: Files and Git are sections of its drawer, never tasks, so opening one shows the drawer on
    /// that section (`reveal`). Set by the phone shell; iPad and Mac open them as tabs.
    @ObservationIgnored var drawerHoldsBrowsers = false
    /// Bumped when the drawer should open on `drawerSection` (`reveal`); the shell opens the panel.
    private(set) var revealRequest = 0
    /// `prepare` is making a backing tab, which must not be revealed again.
    @ObservationIgnored private var preparing = false
    /// The current surface's title-menu items, as it last drew them: its pill's ••• menu in the drawer shows them
    /// (`tabActions(for:model:)`). Not observed, since a surface writes it while it draws.
    @ObservationIgnored var surfaceMenu: WorkspaceSurfaceMenu?
    /// Closes the header's panels and runs an action once they have gone (the shell's `closePhonePopovers(then:)`).
    @ObservationIgnored var closePanels: ((@escaping @MainActor () -> Void) -> Void)?
    @ObservationIgnored private var hostKey: String?
    init() {}

    /// The header's panel is open.
    var popoverShown: Bool { tabSwitcherShown }

    /// A standalone terminal's screen shows.
    var standaloneTerminalShown: Bool { !standaloneScreens.isEmpty }

    /// Records whether the view `view` shows a standalone terminal's screen.
    func standaloneScreen(_ view: UUID, shown: Bool) {
        if shown { standaloneScreens.insert(view) } else { standaloneScreens.remove(view) }
    }

    /// How long a sheet takes to go before a popover can be presented.
    nonisolated static let sheetSettle: TimeInterval = 0.6
    /// How long the drawer or Settings must wait for a sheet in the way: UIKit refuses a popover while a sheet is up
    /// or still on its way out, and the popover's binding then resets, so the button's tap did nothing (a tap on the
    /// drawer's button just after closing Resume Work's sheet, 2026-10-05). Nil when no sheet is in the way.
    nonisolated static func popoverDelay(sheetShown: Bool, sheetClosedAt: Date, now: Date = Date()) -> TimeInterval? {
        if sheetShown { return sheetSettle }
        let since = now.timeIntervalSince(sheetClosedAt)
        return since >= 0 && since < sheetSettle ? sheetSettle - since : nil
    }

    /// A host change starts the drawer again at its root. The device's hidden workspaces of before 2026-10-06
    /// (`agentland.phone.closedWorkspaces.<host>`) are no longer read; Close and Remove are the Workspaces screen's
    /// (Settings → This Mac → Workspaces).
    func restore(hostKey: String?) {
        guard self.hostKey != hostKey else { return }
        self.hostKey = hostKey; tabSwitcherShown = false; drawerPath = []
    }
    /// Closes every header panel.
    func dismissPopovers() {
        tabSwitcherShown = false
    }
    func showHome(model: WorkspaceModel) {
        dismissPopovers()
        model.selectedTabID = nil
    }

    // MARK: Task switcher

    /// One section of the iPhone's task switcher: an open workspace, whose name is a row of its own (a section's header
    /// can't be chosen) that shows its Home, then its open terminals and chats; or, last, the open chats of the Chats
    /// space that belong to no workspace, under a plain "Chats" header.
    struct SwitcherSection: Identifiable, Equatable {
        /// The workspace; nil for the Chats space's chats.
        let projectID: String?
        /// The workspace's name ("Home" until the host's list names it), or "Chats".
        let title: String
        let tasks: [WorkspaceTab]
        var id: String { projectID.map { "workspace-\($0)" } ?? "chats" }
    }

    /// What the switcher marks as where you are: the task in front, or a workspace's Home while its launcher shows.
    enum SwitcherItem: Hashable {
        case home(projectID: String)
        case task(UUID)
    }

    /// The task switcher of Chat's and Terminal's Home and of every session's page on iPhone (owner, 2026-10-22: switching
    /// between terminals of different projects took Home, Workspace, a workspace and the way back). Every workspace open
    /// on this device, as the Workspaces screen lists them (`WorkspaceManager.open`: the one in use first, then by last
    /// use; a closed workspace has no tabs here and is not listed), each with its open terminals and chats; then the
    /// Chats space's chats that no workspace owns. Until the host's workspace list is known (`workspaceListPending`),
    /// the workspace restored on this device stands for the list (2026-10-12).
    func switcherSections(model: WorkspaceModel) -> [SwitcherSection] {
        var sections: [SwitcherSection]
        if model.workspaceListPending {
            sections = switcherWorkspaceID(model: model).map {
                [SwitcherSection(projectID: $0, title: "Home", tasks: switcherTasks(inWorkspace: $0, model: model))]
            } ?? []
        } else {
            sections = model.workspaces.open.filter { !model.isChatsSpace($0.id) }.map {
                SwitcherSection(projectID: $0.id, title: $0.project.name, tasks: switcherTasks(inWorkspace: $0.id, model: model))
            }
        }
        let unowned = model.tabs.filter { model.isPlainChat($0) && model.workspaceID(for: $0) == nil }
        if !unowned.isEmpty { sections.append(SwitcherSection(projectID: nil, title: "Chats", tasks: unowned)) }
        return sections
    }

    /// A workspace's task rows: its open terminals and chats, in the order they opened (owner, 2026-10-22: "terminals and
    /// chats"). Editors, browser tabs, Files and Git, and hidden coding chats are not listed.
    func switcherTasks(inWorkspace id: String, model: WorkspaceModel) -> [WorkspaceTab] {
        workingTasks(inWorkspace: id, model: model).filter { $0.kind == .chat || $0.kind == .terminal }
    }

    /// The workspace in use, the switcher's first; the stacks keep only its pages. Until the host's workspace list is
    /// known (the host out of reach at launch, `workspaceListPending`), the workspace restored on this device stands for
    /// it: the selected tab's, else the last one in use (2026-10-12: the switcher listed Home alone with a task in front).
    func switcherWorkspaceID(model: WorkspaceModel) -> String? {
        if let project = model.currentProject { return project.id }
        return model.workspaceListPending ? model.selectedProjectID : nil
    }

    /// A task row: that terminal or chat in front, its own workspace becoming the one in use when it is another's; the
    /// shell shows a chat on Chat and a terminal on Terminal. A row the switcher no longer lists does nothing.
    func selectSwitcherTask(_ id: UUID, model: WorkspaceModel) {
        guard let tab = switcherSections(model: model).lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        model.requestResume(.tab(tab))
    }

    /// Whether a stack keeps the page of the task `id`. The stack in front (`inFront`) keeps an open task's page while it
    /// is the task in front or one of the workspace in use's (the stacks keep only its pages). Chat's or Terminal's
    /// stack that isn't in front keeps every page until it is (the shell's `switchPhoneTab`): emptied while its tab was
    /// off screen or leaving it (the switcher's task in another workspace, on the other tab), the stack showed the next
    /// page pushed on it black under its name, with the tab bar (owner, 2026-10-23).
    func stackKeepsPage(_ id: UUID, inFront: Bool, model: WorkspaceModel) -> Bool {
        guard inFront else { return true }
        guard model.tab(id) != nil else { return false }
        if id == model.selectedTabID { return true }
        guard let workspace = switcherWorkspaceID(model: model) else { return false }
        return workingTasks(inWorkspace: workspace, model: model).contains { $0.id == id }
    }

    /// A workspace's row: its Home, with it the workspace in use. Nothing closes or ends; each task stays open in the
    /// switcher (while the host's list is unknown, the workspace stays as it is).
    func showWorkspaceHome(_ id: String, model: WorkspaceModel) {
        model.selectProject(id)
        showHome(model: model)
    }

    /// The items of `tab`'s ••• menu on its pill in the drawer (owner, 2026-10-08: the tab's own actions moved there
    /// from the header's menu): only the tab in front has its surface mounted, so only its pill offers them, once its
    /// surface has drawn them; nil for any other tab and for a surface with no actions of its own.
    func tabActions(for tab: WorkspaceTab, model: WorkspaceModel) -> AnyView? {
        guard model.selectedTabID == tab.id, let menu = surfaceMenu, menu.tabID == tab.id, menu.hasItems else { return nil }
        return menu.items
    }
    /// Runs an action chosen from the tab's ••• menu in the drawer once that menu and then the drawer have gone, so the
    /// sheet, question or keyboard it brings is not under the drawer; at once when no header panel is open (iPad, Mac).
    func afterPanels(_ action: @escaping @MainActor () -> Void) {
        guard popoverShown, let closePanels else { action(); return }
        MenuAction.afterDismissal { closePanels(action) }
    }
    /// The workspace whose Files and Git the drawer shows: the one in use, never the Chats space.
    func drawerProject(model: WorkspaceModel) -> Project? {
        model.currentProject.flatMap { model.isChatsSpace($0.id) ? nil : $0 }
    }
    /// Shared tab closing/restoration can select a backing browser. On a phone it stays in the drawer.
    func reconcileSelection(model: WorkspaceModel) {
        guard let selected = model.currentTab, selected.kind == .files || selected.kind == .git else { return }
        model.selectedTabID = workingTasks(inWorkspace: selected.projectID, model: model).last?.id
    }
    func workingTasks(inWorkspace id: String, model: WorkspaceModel) -> [WorkspaceTab] {
        model.tabs(inWorkspace: id).filter { model.supportsTab($0) && isWorkingTask($0) }
    }
    func isWorkingTask(_ tab: WorkspaceTab) -> Bool {
        switch tab.kind {
        case .home, .files, .git: false
        default: true
        }
    }
    /// Gets the current workspace's Files or Git backing tab ready for its page, without changing the task
    /// in front or the workspace's remembered task.
    func prepare(_ section: DrawerSection, model: WorkspaceModel) {
        let kind = section.backingKind
        guard let project = drawerProject(model: model) else { return }
        guard !model.tabs.contains(where: { $0.projectID == project.id && $0.kind == kind }) else { return }
        let previousTabID = model.selectedTabID
        let previousProjectID = model.selectedProjectID
        let rememberedTaskID: UUID?
        if let tab = model.currentTab, tab.projectID == project.id, isWorkingTask(tab) {
            rememberedTaskID = tab.id
        } else {
            // Read the model's authoritative remembered selection before preparing a pane overwrites
            // it. This also keeps a retained Home tab from being consumed by showFiles/showGit.
            openWorkingWorkspace(project.id, model: model)
            rememberedTaskID = model.selectedTabID
        }
        preparing = true
        defer { preparing = false }
        if kind == .files { model.showFiles() }
        else { model.showGit() }
        if let rememberedTaskID { model.selectedTabID = rememberedTaskID }
        model.selectedProjectID = previousProjectID
        model.selectedTabID = previousTabID
    }
    /// Whether opening `tab` should show the drawer's section instead (`reveal`): a Files or Git tab on iPhone, other
    /// than the backing tab `prepare` is making.
    func revealsInsteadOfOpening(_ tab: WorkspaceTab) -> Bool {
        drawerHoldsBrowsers && !preparing && (tab.kind == .files || tab.kind == .git)
    }

    /// Shows the drawer on its Files or Git section for `projectID` (an agent chat's Browse files, the shell's Browse
    /// Files and Git, a folder from Resume Work's search), leaving the task in front as it was. The backing tab is made
    /// if missing; the shell opens the drawer when `revealRequest` changes.
    func reveal(_ section: DrawerSection, projectID: String, model: WorkspaceModel) {
        if model.selectedProjectID != projectID, model.projects.contains(where: { $0.id == projectID }) {
            switchWorkspace(projectID, model: model)
        }
        prepare(section, model: model)
        drawerSection = section
        drawerPath = []
        revealRequest &+= 1
    }

    /// The backing tab a drawer section shows in the current workspace: Files or Git.
    func backingTab(_ section: DrawerSection, model: WorkspaceModel) -> WorkspaceTab? {
        guard let projectID = model.selectedProjectID else { return nil }
        return model.tabs.first { $0.projectID == projectID && $0.kind == section.backingKind }
    }
    private func openWorkingWorkspace(_ id: String, model: WorkspaceModel) {
        model.openWorkspace(id, openFilesIfEmpty: false)
        if let tab = model.currentTab, tab.projectID == id, !isWorkingTask(tab) {
            model.selectedTabID = workingTasks(inWorkspace: id, model: model).last?.id
        }
    }
    /// Makes `id` the workspace in use with its remembered task in front (or Home when it has none).
    func switchWorkspace(_ id: String, model: WorkspaceModel) {
        openWorkingWorkspace(id, model: model)
    }
    /// The host's workspaces, excluding the Chats API space.
    func visibleProjects(_ model: WorkspaceModel) -> [Project] {
        model.projects.filter { !model.isChatsSpace($0.id) }
    }
    func unavailableTabs(_ model: WorkspaceModel) -> [WorkspaceTab] {
        WorkspaceNavigation.groups(model: model).unavailableTabs.filter(isWorkingTask)
    }
}

extension WorkspacePhoneNavigation.DrawerSection {
    /// The workspace tab that backs the page.
    var backingKind: WorkspaceTabKind {
        switch self {
        case .files: .files
        case .git: .git
        }
    }
}
