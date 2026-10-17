import Foundation
import Observation
import SwiftUI
import AgentLandCore

/// The iPhone's quick tab switcher (a glass panel below the header's center button) and the Files and Git pages
/// that Workspace opens (owner, 2026-10-11: bottom tabs replace the left drawer).
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
    /// Home is separate; only open chat, terminal and file tasks in this workspace follow it.
    func quickTabs(model: WorkspaceModel) -> [WorkspaceTab] {
        guard let id = switcherWorkspaceID(model: model) else { return [] }
        return workingTasks(inWorkspace: id, model: model).filter {
            switch $0.kind {
            case .chat, .terminal, .editor: true
            default: false
            }
        }
    }
    /// The workspace whose tasks the switcher lists: the one in use. Until the host's workspace list is known (the
    /// host out of reach at launch, `workspaceListPending`), the workspace restored on this device stands for it: the
    /// selected tab's, else the last one in use (2026-10-12: the switcher listed Home alone with a task in front).
    func switcherWorkspaceID(model: WorkspaceModel) -> String? {
        if let project = model.currentProject { return project.id }
        return model.workspaceListPending ? model.selectedProjectID : nil
    }

    func selectQuickTab(_ id: UUID?, model: WorkspaceModel) {
        guard let id else { showHome(model: model); return }
        guard let tab = quickTabs(model: model).first(where: { $0.id == id }) else { return }
        model.requestResume(.tab(tab))
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
