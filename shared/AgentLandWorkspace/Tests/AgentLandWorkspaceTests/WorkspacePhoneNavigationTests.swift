import XCTest
import SwiftUI
import AgentLandCore
@testable import AgentLandWorkspace

@MainActor final class WorkspacePhoneNavigationTests: XCTestCase {
    func testClosingLastDocumentAndRestoringBrowserKeepsFilesInTheDrawer() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        let files = WorkspaceTab(kind: .files, projectID: "a", title: "Files")
        var document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        document.editorDirty = true
        model.tabs = [files, document]; model.selectedTabID = document.id
        let navigation = model.phoneNavigation

        model.close(document.id)
        navigation.reconcileSelection(model: model)
        XCTAssertEqual(model.selectedTabID, document.id, "The pending dirty-close confirmation preserves the editor")
        model.discardAndClose()
        navigation.reconcileSelection(model: model)
        XCTAssertNil(model.selectedTabID, "Closing the last document returns to Home")
        XCTAssertEqual(model.tabs.map(\.id), [files.id], "The drawer keeps its retained backing session")

        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        model.tabs.append(terminal)
        model.selectedTabID = files.id
        navigation.reconcileSelection(model: model)
        XCTAssertEqual(model.selectedTabID, terminal.id, "A restored browser falls back to an available working task")
    }

    func testShowHomeDismissesOverlaysAndPreservesWorkspaceTabsAndLiveDraft() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        var document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        document.draft = "Saved unsent notes"; document.editorDirty = true
        let other = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "shell", title: "Shell")
        model.tabs = [document, other]; model.selectedTabID = document.id
        let editor = model.editorSession(for: document)
        editor.content = "Live unsaved notes"
        let navigation = model.phoneNavigation
        navigation.tabSwitcherShown = true

        navigation.showHome(model: model)

        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.selectedProjectID, "a", "Home keeps the workspace in use")
        XCTAssertFalse(navigation.tabSwitcherShown, "Home dismisses the tab menu")
        XCTAssertEqual(model.tabs.map(\.id), [document.id, other.id])
        XCTAssertEqual(model.tab(document.id)?.draft, "Saved unsent notes")
        XCTAssertTrue(model.editorSession(for: document) === editor)
        XCTAssertEqual(editor.content, "Live unsaved notes")
    }

    /// The drawer's task rows (the one place tasks switch, 2026-10-05) leave out its own Files and Git pages and keep
    /// documents and the workspace's other tasks.
    func testDrawerTaskRowsExcludeDrawerBrowsersButKeepDocumentsAndWorkspaceTasks() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home")
        let files = WorkspaceTab(kind: .files, projectID: "a", title: "Files")
        let git = WorkspaceTab(kind: .git, projectID: "a", title: "Git")
        var document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        document.draft = "Kept document"; document.editorDirty = true
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "chat", title: "Chat")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let browser = WorkspaceTab(kind: .browser, projectID: "a", resourceID: "preview", title: "Preview")
        let otherDocument = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "other", title: "Other")
        let tabs = [home, files, git, document, chat, terminal, browser, otherDocument]
        model.tabs = tabs; model.selectedTabID = document.id
        let navigation = model.phoneNavigation

        XCTAssertEqual(navigation.workingTasks(inWorkspace: "a", model: model).map(\.id),
                       [document.id, terminal.id, browser.id], "the task in front keeps its row, checked")
        XCTAssertEqual(navigation.workingTasks(inWorkspace: "b", model: model).map(\.id), [otherDocument.id])
        navigation.showHome(model: model)
        XCTAssertEqual(navigation.workingTasks(inWorkspace: "a", model: model).count, 3)
        XCTAssertEqual(model.tabs, tabs, "the rows never delete legacy browser tabs")
        XCTAssertEqual(model.tab(document.id)?.draft, "Kept document")
    }

    /// Workspace's Files and Git pages are the only sections (owner, 2026-10-11: bottom tabs replace the drawer). The
    /// last one used stays while the app runs; choosing another goes back to its root.
    func testDrawerSectionsAreFilesAndGitAndKeepTheLastOneUsed() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        model.selectedProjectID = "a"
        let navigation = model.phoneNavigation
        XCTAssertEqual(WorkspacePhoneNavigation.DrawerSection.allCases, [.files, .git])
        XCTAssertEqual(WorkspacePhoneNavigation.DrawerSection.allCases.map(\.title), ["Files", "Git"])
        XCTAssertEqual(WorkspacePhoneNavigation.DrawerSection.allCases.map(\.id), ["files", "git"])
        XCTAssertEqual(WorkspacePhoneNavigation.DrawerSection.allCases.map(\.backingKind), [.files, .git])
        XCTAssertEqual(navigation.drawerSection, .files, "Files at first")
        navigation.drawerSection = .files
        navigation.drawerPath = [.file(projectID: "a", path: "notes/todo.txt")]
        XCTAssertEqual(navigation.drawerPath.first?.title, "todo.txt")
        navigation.drawerSection = .git
        XCTAssertTrue(navigation.drawerPath.isEmpty, "Another section starts at its root")
        navigation.drawerPath = [.file(projectID: "a", path: "README.md")]
        navigation.drawerSection = .git
        XCTAssertEqual(navigation.drawerPath.count, 1, "The same section keeps its page")
    }

    /// The tab menu's Workspace row switches the workspace in use (owner, 2026-10-08): its remembered tab comes to the
    /// front, or its Home, and every tab stays.
    func testSwitchingTheWorkspaceShowsItsRememberedTabAndKeepsEveryTab() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta"), Project(id: "c", name: "Gamma")]
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let notes = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "notes", title: "Notes")
        model.tabs = [terminal, notes]; model.selectedProjectID = "a"; model.selectedTabID = terminal.id
        let navigation = model.phoneNavigation
        navigation.switchWorkspace("b", model: model)
        XCTAssertEqual(model.selectedProjectID, "b")
        XCTAssertEqual(model.selectedTabID, notes.id)
        navigation.switchWorkspace("c", model: model)
        XCTAssertEqual(model.selectedProjectID, "c")
        XCTAssertNil(model.selectedTabID, "A workspace with no tabs shows Home")
        XCTAssertEqual(model.tabs.map(\.id), [terminal.id, notes.id])
    }

    /// The file inspector shows text up to its limit; text the host refuses (over 1 MiB, or not UTF-8) or a larger one
    /// can't be previewed, and any other error can be tried again.
    func testFileInspectorPreviewsTextAndRefusesLargeOrBinaryFiles() {
        XCTAssertEqual(FileInspectorPreview(content: "hello\n"), .text("hello\n"))
        XCTAssertEqual(FileInspectorPreview(content: String(repeating: "a", count: FileInspectorPreview.limit)),
                       .text(String(repeating: "a", count: FileInspectorPreview.limit)))
        XCTAssertEqual(FileInspectorPreview(content: String(repeating: "a", count: FileInspectorPreview.limit + 1)), .unpreviewable)
        XCTAssertEqual(FileInspectorPreview(error: ClientError.server(code: "file_too_large", message: "Too large")), .unpreviewable)
        XCTAssertEqual(FileInspectorPreview(error: ClientError.server(code: "unsupported_file", message: "Not text")), .unpreviewable)
        XCTAssertEqual(FileInspectorPreview(error: ClientError.server(code: "file_not_found", message: "Gone")), .failed("Gone"))
    }

    // The header as measured on an iPhone 17 Pro (402 pt wide), in the shell's space (panels-v2's measurements less the
    // 62 pt above the shell): the drawer button's glass, the task button's capsule and the gear's glass.
    private let shell = CGSize(width: 402, height: 778)
    private let drawerButton = CGRect(x: 16.33, y: 5.67, width: 50, height: 50)
    private let taskButton = CGRect(x: 117, y: 4, width: 171.33, height: 53)
    private var headerBottom: CGFloat { [drawerButton, taskButton].map(\.maxY).max()! }

    /// A panel's resting frame for `kind` on this header (the margins as the layer takes them).
    private func panelFrame(_ kind: PhonePanelKind, shell: CGSize? = nil, fit: CGFloat? = nil,
                            maxHeight: CGFloat = 546, fitWidth: CGFloat? = nil) -> CGRect {
        let shell = shell ?? self.shell
        let button = switch kind { case .tabSwitcher: taskButton }
        let margin = drawerButton.minX
        return PhonePanelGeometry.frame(button: button, alignment: kind.alignment,
                                        margin: margin, headerBottom: headerBottom, available: shell,
                                        fit: kind.fillsRoom ? nil : fit, maxHeight: kind.fillsRoom ? .infinity : maxHeight,
                                        fitWidth: fitWidth)
    }

    /// Every header panel rests just below the header (owner's instruction, 2026-10-05: "push the menus below the
    /// header"), `gap` (8 pt) under the buttons' glass, so the buttons stay in view above it.
    func testHeaderPanelsRestBelowTheHeader() {
        XCTAssertEqual(PhonePanelGeometry.gap, 8)
        for kind in PhonePanelKind.allCases {
            let frame = panelFrame(kind, fit: 300)
            XCTAssertEqual(frame.minY, headerBottom + 8, accuracy: 0.01, "\(kind) rests 8 pt below the header")
            for button in [drawerButton, taskButton] {
                XCTAssertFalse(frame.intersects(button), "\(kind) leaves the header's buttons in view")
            }
        }
    }

    func testQuickSwitcherFitsItsRowsBelowTheHeader() {
        let frame = panelFrame(.tabSwitcher, fit: 148, fitWidth: 226)
        XCTAssertEqual(frame.height, 148)
        XCTAssertEqual(frame.minY, headerBottom + PhonePanelGeometry.gap)
        XCTAssertEqual(frame.midX, taskButton.midX, accuracy: 0.01)
        XCTAssertEqual(frame.width, 226)
        let longTitle = panelFrame(.tabSwitcher, fit: 148, fitWidth: 900)
        XCTAssertEqual(longTitle.width, shell.width - 2 * drawerButton.minX, accuracy: 0.01, "No wider than the margins allow")
        XCTAssertFalse(frame.intersects(taskButton))
    }

    /// On a narrow phone and in landscape, each panel stays inside the shell's margins; the centred
    /// task menu moves in from an edge rather than past it.
    func testHeaderPanelsStayOnScreen() {
        let narrow = CGSize(width: 320, height: 500)
        let landscape = CGSize(width: 874, height: 360)
        for kind in PhonePanelKind.allCases {
            for room in [shell, narrow, landscape, CGSize(width: 402, height: 150)] {
                let frame = panelFrame(kind, shell: room, maxHeight: max(240, room.height * 0.7))
                let margin = drawerButton.minX
                XCTAssertGreaterThanOrEqual(frame.minX, margin - 0.01, "\(kind) in \(room)")
                XCTAssertLessThanOrEqual(frame.maxX, room.width - margin + 0.01, "\(kind) in \(room)")
                XCTAssertLessThanOrEqual(frame.maxY, room.height + 0.01, "\(kind) in \(room)")
                XCTAssertGreaterThanOrEqual(frame.height, 0)
            }
        }
        // The task button near an edge: the menu keeps the margin.
        let offCentre = PhonePanelGeometry.frame(button: CGRect(x: 20, y: 4, width: 80, height: 53), alignment: .centred,
                                                 margin: 16.33, headerBottom: 57, available: shell, fit: nil, maxHeight: 546)
        XCTAssertEqual(offCentre.minX, 16.33, accuracy: 0.01)
    }

    /// The task menu fits its rows up to the most a panel may be. It keeps the least height and stays above the keyboard.
    func testHeaderPanelHeightFitsItsContentAboveTheKeyboard() {
        XCTAssertEqual(panelFrame(.tabSwitcher, fit: 300).height, 300, accuracy: 0.01, "The task menu fits its rows")
        XCTAssertEqual(panelFrame(.tabSwitcher).height, 546, accuracy: 0.01, "No taller than a panel may be")
        let keyboard = panelFrame(.tabSwitcher, shell: CGSize(width: 402, height: 420))
        XCTAssertEqual(keyboard.maxY, 420 - PhonePanelGeometry.bottomMargin, accuracy: 0.01, "Above the keyboard")
        let tight = panelFrame(.tabSwitcher, shell: CGSize(width: 402, height: 150))
        XCTAssertLessThanOrEqual(tight.maxY, 150 + 0.01, "Never past the keyboard's top, even below the least height")
    }

    /// The tap-outside region covers the shell but the header's buttons, which stay tappable while a panel is open.
    func testPanelDismissRegionLeavesTheHeaderButtonsInReach() {
        let region = PanelDismissShape(holes: [drawerButton, taskButton]).path(in: CGRect(origin: .zero, size: shell))
        for button in [drawerButton, taskButton] {
            XCTAssertFalse(region.contains(CGPoint(x: button.midX, y: button.midY), eoFill: true), "A tap on a header button reaches it")
        }
        XCTAssertTrue(region.contains(CGPoint(x: 100, y: 30), eoFill: true), "Between the buttons a tap closes the panel")
        XCTAssertTrue(region.contains(CGPoint(x: 200, y: 700), eoFill: true), "Over the content a tap closes the panel")
    }

    /// The drawer's and Settings' buttons wait for a sheet in the way: one that is up goes first, one still going is
    /// waited out, and with none the popover opens at once (the drawer did not open after Resume Work's sheet closed).
    func testHeaderPopoversWaitForASheetOnItsWayOut() {
        let now = Date()
        XCTAssertEqual(WorkspacePhoneNavigation.popoverDelay(sheetShown: true, sheetClosedAt: .distantPast, now: now),
                       WorkspacePhoneNavigation.sheetSettle)
        XCTAssertEqual(WorkspacePhoneNavigation.popoverDelay(sheetShown: false, sheetClosedAt: now.addingTimeInterval(-0.2), now: now)!,
                       WorkspacePhoneNavigation.sheetSettle - 0.2, accuracy: 0.001)
        XCTAssertNil(WorkspacePhoneNavigation.popoverDelay(sheetShown: false, sheetClosedAt: now.addingTimeInterval(-0.6), now: now))
        XCTAssertNil(WorkspacePhoneNavigation.popoverDelay(sheetShown: false, sheetClosedAt: .distantPast, now: now))
    }

    func testDrawerPanesReuseBackingTabsWithoutChangingHomeOrDirtyDocument() throws {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        var document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        document.draft = "Kept notes"; document.editorDirty = true
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        model.tabs = [document, home]; model.selectedTabID = document.id
        let editor = model.editorSession(for: document)
        editor.content = "Live notes"
        let navigation = model.phoneNavigation

        for selection in [nil, document.id, home.id] {
            model.selectedTabID = selection
            navigation.prepare(.files, model: model)
            let files = try XCTUnwrap(model.tabs.first { $0.kind == .files })
            let session = model.filesSession(for: files)
            XCTAssertEqual(model.selectedTabID, selection)
            XCTAssertEqual(model.selectedProjectID, "a")
            XCTAssertEqual(navigation.backingTab(.files, model: model)?.id, files.id)
            navigation.prepare(.git, model: model)
            XCTAssertEqual(model.selectedTabID, selection)
            navigation.prepare(.files, model: model)
            XCTAssertTrue(model.filesSession(for: files) === session)
        }
        XCTAssertEqual(model.tabs.filter { $0.kind == .files }.count, 1)
        XCTAssertEqual(model.tabs.filter { $0.kind == .git }.count, 1)
        XCTAssertNotNil(model.tab(home.id), "drawer browsing never consumes a retained Home tab")
        XCTAssertTrue(model.editorSession(for: document) === editor)
        XCTAssertEqual(editor.content, "Live notes")
        XCTAssertEqual(model.tab(document.id)?.draft, "Kept notes")
        XCTAssertEqual(navigation.workingTasks(inWorkspace: "a", model: model).map(\.id), [document.id])
    }

    func testDrawerBrowsingAtHomeKeepsTheRememberedWorkingTaskForResume() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        let laterTerminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let other = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "other", title: "Other")
        model.tabs = [document, laterTerminal, other]; model.selectedTabID = document.id
        let navigation = model.phoneNavigation
        navigation.showHome(model: model)
        navigation.prepare(.files, model: model)
        navigation.prepare(.git, model: model)
        XCTAssertNil(model.selectedTabID)
        navigation.switchWorkspace("b", model: model)
        navigation.switchWorkspace("a", model: model)
        XCTAssertEqual(model.selectedTabID, document.id, "browsing at Home preserves the remembered task, not merely the last tab")
    }

    func testWorkspaceSwitchNeverPromotesDrawerBrowsers() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        let files = WorkspaceTab(kind: .files, projectID: "b", title: "Files")
        let git = WorkspaceTab(kind: .git, projectID: "b", title: "Git")
        let tabs = [document, files, git]
        model.tabs = tabs; model.selectedTabID = document.id
        let navigation = model.phoneNavigation
        navigation.switchWorkspace("b", model: model)
        XCTAssertNil(model.selectedTabID, "a workspace with only drawer panes has no working task")
        navigation.switchWorkspace("b", model: model)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.tabs, tabs)

        let terminal = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "shell", title: "Shell")
        let laterDocument = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "later", title: "Later")
        model.tabs += [terminal, laterDocument]; model.selectedTabID = files.id
        navigation.switchWorkspace("b", model: model)
        XCTAssertEqual(model.selectedTabID, laterDocument.id, "legacy browser selections fall back to a working task")
        model.selectedTabID = terminal.id
        navigation.switchWorkspace("a", model: model)
        navigation.switchWorkspace("b", model: model)
        XCTAssertEqual(model.selectedTabID, terminal.id, "normal remembered working selections remain authoritative")
    }

    func testEmptyWorkspaceSwitchShowsHomeWithoutCreatingATask() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        var draft = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        draft.draft = "Unsaved notes"; draft.editorDirty = true
        model.tabs = [draft]; model.selectedTabID = draft.id
        let navigation = WorkspacePhoneNavigation()
        navigation.switchWorkspace("b", model: model)
        XCTAssertEqual(model.selectedProjectID, "b")
        XCTAssertNil(model.selectedTabID, "An empty workspace shows Home")
        XCTAssertEqual(model.tabs.map(\.id), [draft.id], "Selecting a workspace never creates a Files task")
        XCTAssertEqual(model.tab(draft.id)?.draft, "Unsaved notes")
        navigation.switchWorkspace("a", model: model)
        navigation.switchWorkspace("b", model: model)
        XCTAssertEqual(model.selectedProjectID, "b")
        XCTAssertNil(model.selectedTabID)
        XCTAssertTrue(model.tabs(inWorkspace: "b").isEmpty)
    }
    /// Close on a workspace row (the Workspaces screen's, 2026-10-06) closes its tabs on this device; the one in use
    /// is in use no more, so Home shows and nothing is made in its place.
    func testClosingTheWorkspaceInUseLeavesHomeWithoutCreatingATask() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let tab = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        let other = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "notes", title: "Notes")
        model.tabs = [tab, other]; model.selectedProjectID = "a"; model.selectedTabID = tab.id
        model.closeWorkspace("a")
        XCTAssertNil(model.selectedProjectID)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.tabs.map(\.id), [other.id], "Only its own tasks close")
    }
    func testUnavailableWorkspaceTasksRemainReachable() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        var orphan = WorkspaceTab(kind: .editor, projectID: "removed", resourceID: "notes", title: "Notes")
        orphan.draft = "Retained draft"; orphan.editorDirty = true
        let current = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "shell", title: "Shell")
        model.tabs = [orphan, current]
        let navigation = WorkspacePhoneNavigation()
        XCTAssertEqual(navigation.unavailableTabs(model).map(\.id), [orphan.id])
        XCTAssertEqual(model.tab(orphan.id)?.draft, "Retained draft")
    }
    func testWorkspaceSwitchRestoresOwnedTab() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let a = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "a-term", title: "Shell")
        let b = WorkspaceTab(kind: .editor, projectID: "b", resourceID: "notes", title: "Notes")
        model.tabs = [a, b]; model.selectedTabID = a.id
        let navigation = WorkspacePhoneNavigation()
        navigation.switchWorkspace("b", model: model)
        XCTAssertEqual(model.selectedTabID, b.id)
        XCTAssertEqual(model.tabs.map(\.id), [a.id, b.id])
    }
    /// The task switcher lists every open workspace with its terminals and chats; choosing another workspace's task
    /// brings that workspace, and a workspace's row shows its Home; nothing closes (owner, 2026-10-22).
    func testSwitcherListsEveryOpenWorkspaceAndSwitchesWithoutClosingAnything() {
        let model = WorkspaceModel()
        let navigation = model.phoneNavigation
        XCTAssertTrue(navigation.switcherSections(model: model).isEmpty)
        navigation.showHome(model: model)
        XCTAssertNil(model.selectedTabID, "Home works even with no workspace")
        model.projects = [Project(id: "a", name: "Alpha"), Project(id: "b", name: "Beta")]
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "s", title: "Shell")
        var document = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes", title: "Notes")
        document.draft = "Unsaved notes"; document.editorDirty = true
        let other = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "other", title: "Other")
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "chat", title: "Chat")
        model.tabs = [terminal, document, other, chat]
        model.rememberChatWorkspace(chat.resourceID, workspaceID: "a")
        model.selectedTabID = terminal.id
        let editor = model.editorSession(for: document)
        editor.content = "Live notes"
        XCTAssertEqual(navigation.switcherSections(model: model).map(\.projectID), ["a", "b"])
        XCTAssertEqual(navigation.switcherSections(model: model).map { $0.tasks.map(\.id) }, [[terminal.id, chat.id], [other.id]])
        navigation.selectSwitcherTask(document.id, model: model)
        XCTAssertEqual(model.selectedTabID, terminal.id, "A file is no row of the switcher")
        navigation.selectSwitcherTask(other.id, model: model)
        XCTAssertEqual(model.selectedTabID, other.id)
        XCTAssertEqual(model.selectedProjectID, "b", "Another workspace's task brings its workspace")
        navigation.showWorkspaceHome("a", model: model)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.selectedProjectID, "a", "A workspace's row shows its Home")
        XCTAssertEqual(model.tabs.map(\.id), [terminal.id, document.id, other.id, chat.id], "Nothing closes")
        XCTAssertEqual(model.tab(document.id)?.draft, "Unsaved notes")
        XCTAssertTrue(model.editorSession(for: document) === editor)
        XCTAssertEqual(editor.content, "Live notes")
        navigation.selectSwitcherTask(chat.id, model: model)
        XCTAssertEqual(model.selectedTabID, chat.id)
        XCTAssertEqual(model.selectedProjectID, "a")
    }

    /// Relaunched with the host out of reach, its workspace list never loads: the switcher still lists the workspace
    /// restored in front with its open tasks, and choosing one selects it (2026-10-12: it listed Home alone). Once the
    /// host answers, its list decides again.
    func testQuickSwitcherListsTheRestoredWorkspacesTasksWhileTheHostIsOutOfReach() async throws {
        let suite = "phone-switcher-offline-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let online = ScriptedHost()
        online.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"},{"id":"b","name":"Blog"}]}"#) }
        let before = try await launch(online, defaults: defaults)
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Shell")
        let notes = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes.md", title: "Notes")
        let second = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty-2", title: "Server")
        let other = WorkspaceTab(kind: .terminal, projectID: "b", resourceID: "other", title: "Other")
        before.tabs = [terminal, notes, second, other]
        before.selectedTabID = terminal.id
        XCTAssertEqual(before.phoneNavigation.switcherSections(model: before).map(\.projectID), ["a", "b"])
        XCTAssertEqual(before.phoneNavigation.switcherSections(model: before).first?.tasks.map(\.id), [terminal.id, second.id])

        let unreachable = ScriptedHost()
        unreachable.on("/v1/projects") { _ in throw URLError(.cannotConnectToHost) }
        unreachable.on("/v1/capabilities") { _ in throw URLError(.cannotConnectToHost) }
        let model = try await launch(unreachable, defaults: defaults)
        let navigation = model.phoneNavigation
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNotNil(model.hostIssue)
        XCTAssertEqual(model.selectedTabID, terminal.id, "The terminal is restored in front")
        XCTAssertEqual(navigation.switcherSections(model: model).map(\.projectID), ["a"])
        XCTAssertEqual(navigation.switcherSections(model: model).first?.tasks.map(\.id), [terminal.id, second.id],
                       "The switcher lists the restored workspace's tasks, not Home alone")
        navigation.selectSwitcherTask(second.id, model: model)
        XCTAssertEqual(model.selectedTabID, second.id, "Choosing a task selects it")
        XCTAssertNil(model.creationIssue)
        XCTAssertNil(model.pendingSessionResume)
        navigation.selectSwitcherTask(other.id, model: model)
        XCTAssertEqual(model.selectedTabID, second.id, "Another workspace's task is not the switcher's until the host answers")
        navigation.showWorkspaceHome("a", model: model)
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(navigation.switcherSections(model: model).first?.tasks.map(\.id), [terminal.id, second.id],
                       "Home keeps the last workspace in use")

        // A host that answers without that workspace: its tasks leave the switcher and Resume says it is gone.
        let answered = ScriptedHost()
        answered.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"b","name":"Blog"}]}"#) }
        let after = try await launch(answered, defaults: defaults)
        let listed = after.phoneNavigation.switcherSections(model: after)
        XCTAssertFalse(listed.contains { $0.projectID == "a" })
        XCTAssertFalse(listed.flatMap(\.tasks).contains { $0.id == terminal.id })
        after.requestResume(.tab(terminal))
        XCTAssertNil(after.selectedTabID)
        XCTAssertNotNil(after.creationIssue)
    }

    /// A launch of the app on this device's saved workspace for one host, its workspace list asked of `host`.
    private func launch(_ host: ScriptedHost, defaults: UserDefaults) async throws -> WorkspaceModel {
        let identity = ConnectionIdentity(host: "https://mac.example", deviceID: "phone")
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: identity.storageKey, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: identity.host), token: "test", transport: host))
        await model.refreshProjects()
        return model
    }

    /// An action that brings a sheet, a question or the keyboard (a chat's Continue with another model, Files' Find)
    /// runs once the header's tab menu has gone; with no header panel open (iPad, Mac) it runs at once.
    func testMenuActionsWaitForTheHeaderPanelToGo() async {
        let model = WorkspaceModel()
        let navigation = model.phoneNavigation
        var ranAtOnce = false
        navigation.afterPanels { ranAtOnce = true }
        XCTAssertTrue(ranAtOnce)

        navigation.closePanels = { action in navigation.dismissPopovers(); action() }
        navigation.tabSwitcherShown = true
        let ran = expectation(description: "runs after the tab menu")
        navigation.afterPanels {
            XCTAssertFalse(navigation.tabSwitcherShown, "the tab menu went first")
            ran.fulfill()
        }
        XCTAssertTrue(navigation.tabSwitcherShown, "the menu goes before the tab menu does")
        await fulfillment(of: [ran], timeout: 2)
    }

    /// Closing the header's popovers closes the task menu; a host change closes it too and starts Workspace's Files and
    /// Git pages again at their root.
    func testDismissingPopoversAndChangingHostResetTheDrawer() {
        let navigation = WorkspacePhoneNavigation()
        navigation.restore(hostKey: "one")
        navigation.tabSwitcherShown = true
        XCTAssertTrue(navigation.popoverShown)
        navigation.dismissPopovers()
        XCTAssertFalse(navigation.tabSwitcherShown)
        XCTAssertFalse(navigation.popoverShown)
        navigation.drawerPath = [.file(projectID: "a", path: "README.md")]
        navigation.tabSwitcherShown = true
        navigation.restore(hostKey: "two")
        XCTAssertFalse(navigation.tabSwitcherShown)
        XCTAssertTrue(navigation.drawerPath.isEmpty, "Another host's Files page starts at its root")
    }

    /// A file opened from Workspace's Files page (its inspector's Open in Workspace, or a new file made there) shows
    /// in front and the header's tab menu goes.
    func testOpeningAFileClosesTheDrawer() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        model.selectProject("a")
        let navigation = model.phoneNavigation
        navigation.tabSwitcherShown = true
        navigation.prepare(.files, model: model)
        XCTAssertNil(model.selectedTabID, "Preparing the Files page leaves Home in front")
        model.openFile(projectID: "a", path: "notes/todo.txt")
        XCTAssertFalse(navigation.tabSwitcherShown)
        XCTAssertEqual(model.currentTab?.kind, .editor)
        XCTAssertEqual(model.currentTab?.title, "todo.txt")
    }

    /// B-3: on iPhone an agent chat's Browse files (which opens a Files tab), Browse Files and Git show the drawer on
    /// that section, at its root; the task in front stays and no Home tab is consumed.
    func testOpeningFilesOrGitOnIPhoneShowsTheDrawerPageAndKeepsTheTaskInFront() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "chat", title: "Chat")
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        model.tabs = [chat, home]; model.selectedTabID = chat.id
        let navigation = model.phoneNavigation
        navigation.drawerHoldsBrowsers = true
        let before = navigation.revealRequest

        navigation.drawerPath = [.file(projectID: "a", path: "README.md")]
        model.open(WorkspaceTab(kind: .files, projectID: "a", title: "Files"))
        XCTAssertEqual(model.selectedTabID, chat.id, "The chat stays in front")
        XCTAssertEqual(navigation.drawerSection, .files)
        XCTAssertTrue(navigation.drawerPath.isEmpty, "The section's root")
        XCTAssertEqual(navigation.revealRequest, before + 1, "The shell is asked to open the drawer")
        XCTAssertNotNil(navigation.backingTab(.files, model: model), "The drawer's Files page has its backing tab")

        model.showGit()
        XCTAssertEqual(model.selectedTabID, chat.id)
        XCTAssertEqual(navigation.drawerSection, .git)
        XCTAssertEqual(navigation.revealRequest, before + 2)

        model.selectedTabID = home.id
        model.showFiles()
        XCTAssertEqual(model.selectedTabID, home.id, "A Home tab is not replaced by Files")
        XCTAssertNotNil(model.tab(home.id))
        XCTAssertEqual(model.tabs.filter { $0.kind == .files }.count, 1)
        XCTAssertEqual(model.tabs.filter { $0.kind == .git }.count, 1)
    }

    /// iPad and the Mac open Files and Git as tabs, as before.
    func testOpeningFilesWithoutThePhoneDrawerOpensATab() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "chat", title: "Chat")
        model.tabs = [chat]; model.selectedTabID = chat.id
        model.showFiles()
        XCTAssertEqual(model.currentTab?.kind, .files)
        XCTAssertEqual(model.phoneNavigation.revealRequest, 0)
    }

    /// On iPhone an empty workspace opens on Home; Files stays a page of the drawer and does not pop up.
    func testOpeningAnEmptyWorkspaceOnIPhoneShowsHome() {
        let model = WorkspaceModel()
        model.projects = [Project(id: "a", name: "Alpha")]
        model.phoneNavigation.drawerHoldsBrowsers = true
        model.openWorkspace("a")
        XCTAssertEqual(model.selectedProjectID, "a")
        XCTAssertNil(model.selectedTabID)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(model.phoneNavigation.revealRequest, 0)
    }
}
