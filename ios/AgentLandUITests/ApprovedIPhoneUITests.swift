import XCTest
import UIKit

/// The approved iPhone concept exercised against the harness's disposable HTTPS host.
extension FullWorkspaceUITests {
    // MARK: The bottom tabs (owner decision, 2026-10-11)

    /// The iPhone's native bottom bar: Chat, Terminal, Workspace and Settings. It hides while a session (a chat, a
    /// terminal, an editor, the Browser) is in front.
    func phoneTabBar(_ app: XCUIApplication) -> XCUIElement { app.tabBars.firstMatch }

    /// The system's alerts. XCUITest lists whatever is modal for VoiceOver as an alert, so `app.alerts` also holds
    /// the iPhone header's open panel (the tab menu) and Home's open box: those are left out, by their identifiers and
    /// by the OK or Cancel button every system alert of the app has.
    func systemAlerts(_ app: XCUIApplication) -> XCUIElementQuery {
        app.alerts
            .matching(NSPredicate(format: "NOT (identifier IN %@)", ["phoneHeaderPanel", "homeExpandedActionBox"]))
            .containing(NSPredicate(format: "elementType == %@ AND (label IN %@ OR identifier IN %@)",
                                    NSNumber(value: XCUIElement.ElementType.button.rawValue),
                                    ["OK", "Cancel"], ["OK", "Cancel"]))
    }

    /// The system's alert in front, if one shows (`systemAlerts`).
    func systemAlert(_ app: XCUIApplication) -> XCUIElement { systemAlerts(app).firstMatch }

    /// Stages `path` in the Workspace tab's Git page the way a person does: its row's trailing swipe, then Stage
    /// (GI-6, native-iOS batch 9). The swipe's button carries `gitStage-<path>`; its label is Stage.
    func swipeToStageGitFile(_ app: XCUIApplication, _ tree: XCUIElement, _ path: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let row = tree.buttons["gitChange-changes-" + path]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(path) is under Unstaged", file: file, line: line)
        row.swipeLeft()
        let stage = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "gitStage-" + path, "Stage")).firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 5), "The swipe offers Stage", file: file, line: line)
        stage.tap()
    }

    /// A section header of the Git page: the list's own, its title and count one element carrying
    /// `gitTreeSection-<key>`, of whatever type the system gives it.
    func gitSectionHeader(_ app: XCUIApplication, _ key: String) -> XCUIElement {
        app.descendants(matching: .any)["gitTreeSection-" + key].firstMatch
    }

    /// Puts away Resume Work's sheet (⇧⌘F), the one sheet tests leave open over the shell.
    func closePhoneSheets(_ app: XCUIApplication) {
        let resumeClose = app.buttons["resumeWorkClose"].firstMatch
        if resumeClose.exists {
            resumeClose.tap()
            _ = resumeClose.waitForNonExistence(timeout: 5)
        }
    }

    /// Returns Home: the header switcher's Home row, which keeps every task open and the workspace in use. Home's
    /// Chat launcher shows with the bottom bar.
    func showPhoneHome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        closePhoneSheets(app)
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(waitUntilHittable(switcher, timeout: 10), "The header's switcher is in reach", file: file, line: line)
        switcher.tap()
        let home = app.buttons["quickTabHome"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), "The switcher lists Home", file: file, line: line)
        home.tap()
        XCTAssertTrue(phoneTabBar(app).waitForExistence(timeout: 5), "Home shows the bottom bar", file: file, line: line)
    }

    /// Shows a root destination of the bottom bar: "Chat", "Terminal", "Workspace" or "Settings". With a session in
    /// front (the bar hides) Home comes back first. Chat and Terminal are Home's launchers for the workspace in use.
    func showPhoneTab(_ app: XCUIApplication, _ destination: String, file: StaticString = #filePath, line: UInt = #line) {
        closePhoneSheets(app)
        let bar = phoneTabBar(app)
        if !(bar.exists && bar.isHittable) { showPhoneHome(app, file: file, line: line) }
        let button = bar.buttons[destination]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "The bottom bar has \(destination)", file: file, line: line)
        // A second tap on the selected tab is left out: after one, the simulator dropped the next key commands (⌘N,
        // runs 1791770878 and 1791771449).
        if !button.isSelected { button.tap() }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "\(destination) is in front", file: file, line: line)
    }

    /// Whether Home's artwork launcher (the Chat or Terminal destination) is in front.
    func phoneHomeShown(_ app: XCUIApplication) -> Bool {
        phoneTabBar(app).exists && app.descendants(matching: .any)["homeWordmark"].firstMatch.exists
    }

    /// Home's mark for "Home is in front": iPad's New Chat, the iPhone's title (its launchers are the host's agents).
    func homeMark(_ app: XCUIApplication) -> XCUIElement {
        UIDevice.current.userInterfaceIdiom == .phone ? app.descendants(matching: .any)["homeWordmark"].firstMatch
            : app.buttons["homeNewChat"]
    }

    /// Makes `id` the workspace in use: Workspace → Manage Workspaces → its row; the Workspaces screen goes.
    func choosePhoneWorkspace(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        showPhoneTab(app, "Workspace", file: file, line: line)
        let back = app.buttons["phoneBackToWorkspace"]
        if back.exists { back.tap(); _ = back.waitForNonExistence(timeout: 3) }
        let manage = app.buttons["Manage Workspaces"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), "Workspace offers Manage Workspaces", file: file, line: line)
        for _ in 0..<4 where !manage.isHittable { app.collectionViews.firstMatch.swipeUp() }
        manage.tap()
        let row = app.buttons["pickerProject-" + id].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Manage Workspaces lists \(id)", file: file, line: line)
        row.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Choosing \(id) puts the Workspaces screen away", file: file, line: line)
    }

    /// Opens the Workspace tab's Files or Git page (`files` or `git`) for the workspace in use, at its root.
    func openPhoneWorkspacePage(_ app: XCUIApplication, _ page: String, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["phoneBackToWorkspace"]
        let explorer = app.descendants(matching: .any)["workspaceExplorer"].firstMatch
        showPhoneTab(app, "Workspace", file: file, line: line)
        if back.exists { back.tap(); _ = back.waitForNonExistence(timeout: 3) }
        let row = app.buttons[page == "git" ? "phoneGit" : "phoneFiles"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Workspace offers \(page)", file: file, line: line)
        row.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 8), "\(page) opens its page", file: file, line: line)
        // Back from a file's inspector to the page's root.
        let inner = explorer.navigationBars.buttons["BackButton"].firstMatch
        if inner.exists { inner.tap(); _ = inner.waitForNonExistence(timeout: 3) }
    }

    /// Switches to an open task with the header switcher's row whose label holds `title` (the menu lists the workspace
    /// in use's open chats, terminals and files after Home). With several, the last is the newest.
    func switchPhoneTask(_ app: XCUIApplication, titled title: String, file: StaticString = #filePath, line: UInt = #line) {
        closePhoneSheets(app)
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(waitUntilHittable(switcher, timeout: 10), "The header's switcher is in reach", file: file, line: line)
        switcher.tap()
        XCTAssertTrue(app.buttons["quickTabHome"].waitForExistence(timeout: 5), "The switcher opens", file: file, line: line)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "quickTab-", title))
        let row = rows.element(boundBy: max(0, rows.count - 1))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The switcher lists the open task \(title)", file: file, line: line)
        row.tap()
        XCTAssertTrue(app.buttons["quickTabHome"].waitForNonExistence(timeout: 5), "Choosing a task closes the menu", file: file, line: line)
    }

    /// The open task rows of the header switcher, `quickTab-<uuid>` (Home's row is `quickTabHome`).
    func phoneTaskRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quickTab-"))
    }

    /// Closes the task in front with the header's X: a running terminal asks before it ends (End Terminal), an editor
    /// with edits asks too (Close Without Saving when `discard`).
    func closePhoneTask(_ app: XCUIApplication, discard: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["phoneCloseTab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The task in front has its X", file: file, line: line)
        XCTAssertTrue(waitUntilHittable(close, timeout: 10), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in close.isEnabled }, object: nil)
        _ = XCTWaiter.wait(for: [enabled], timeout: 10)
        let terminal = close.label == "Close Terminal"
        close.tap()
        if terminal {
            let end = app.buttons["phoneConfirmEndTerminal"].firstMatch
            if end.waitForExistence(timeout: 3) { end.tap() }
        } else if discard {
            let discardChanges = app.buttons["discardChanges"].firstMatch
            if discardChanges.waitForExistence(timeout: 1.5) { discardChanges.tap() }
        }
    }

    /// A hardware-keyboard command the simulator may drop: after touches it loses key commands until another key
    /// arrives (`connectHardwareKeyboard`, testKeyboardCommands), so after two lost tries ⌘0 goes first. ⌘0 returns
    /// the text to the system's size, which the tests' launch arguments set, so it changes nothing.
    func pressKeyCommand(_ app: XCUIApplication, _ key: String, _ flags: XCUIElement.KeyModifierFlags,
                         until done: () -> Bool) -> Bool {
        if press(app, key, flags, attempts: 2, until: done) { return true }
        print("pressKeyCommand: \(key) was lost twice; ⌘0 first")
        app.typeKey("0", modifierFlags: .command)
        return press(app, key, flags, attempts: 3, until: done)
    }

    /// Taps one of Home's UI-test session starters (`debugNewShellTerminal`, `debugNewChat`): two tiny clear buttons
    /// that run exactly what ⌥⌘T and ⌘N run, in UI-test runs only. The simulator dropped ⌥⌘T on iPhone five times in a
    /// row after touches, ⌘0 first or not (runs 1791772962 and 1791773306), and ⌘N now and then; a tap is not lost.
    /// `started` is checked before a second tap, so a slow start never makes two sessions.
    func tapPhoneSessionStarter(_ app: XCUIApplication, _ identifier: String, until started: () -> Bool,
                                file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let starter = app.buttons[identifier].firstMatch
        XCTAssertTrue(starter.waitForExistence(timeout: 5), "Home has the UI tests' \(identifier)", file: file, line: line)
        for _ in 0..<2 {
            guard starter.exists else { break }
            print("tapPhoneSessionStarter: \(identifier) at \(starter.frame), hittable \(starter.isHittable), \(starter.value ?? "")")
            starter.tap()
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if started() { return true }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
            if starter.exists { print("tapPhoneSessionStarter: nothing started; \(starter.value ?? "")") }
        }
        return started()
    }

    /// Starts a chat with the fixture's OpenCode in the workspace in use, as ⌘N does (`tapPhoneSessionStarter`). With
    /// several providers the Chat provider dialog asks, and OpenCode is chosen. Home's direct Claude and ChatGPT
    /// buttons would start the real agents, so tests never tap them.
    func newPhoneChat(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        showProjects(app)
        let choice = app.buttons["chatProvider-opencode"].firstMatch
        let draft = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(tapPhoneSessionStarter(app, "debugNewChat", until: { choice.exists || draft.exists }, file: file, line: line),
                      "A new chat starts", file: file, line: line)
        if choice.exists { choice.tap() }
        XCTAssertTrue(draft.waitForExistence(timeout: 20), "The OpenCode chat opens", file: file, line: line)
    }

    /// Starts a shell terminal on iPhone in the workspace in use, as ⌥⌘T does (`tapPhoneSessionStarter`): Home's
    /// Terminal launcher offers only Claude Code and Codex (owner's choice, 2026-10-11), which tests never start.
    func newPhoneTerminal(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        showProjects(app)
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(tapPhoneSessionStarter(app, "debugNewShellTerminal", until: { canvas.exists || !self.phoneTabBar(app).exists },
                                             file: file, line: line),
                      "A shell terminal starts", file: file, line: line)
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "The shell terminal opens", file: file, line: line)
    }

    /// Opens a file in the editor from its row: on iPhone the Files page's row shows the file read-only first (owner's
    /// request, 2026-10-06), and its Open in Workspace opens the editor.
    func openFileFromRow(_ app: XCUIApplication, _ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        row.tap()
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let open = app.buttons["fileInspectorOpen"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8), "The file's inspector offers Open in Workspace", file: file, line: line)
        open.tap()
    }

    /// Resume Work on iPhone, a sheet opened with ⇧⌘F, its search focused (no on-screen button since the bottom tabs).
    func openPhoneResumeWork(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.searchFields["Chats, Files and Tabs"]
        if field.exists { return }
        // The simulator loses a key command after touches now and then (`press`).
        XCTAssertTrue(pressKeyCommand(app, "f", [.command, .shift]) { field.exists }, "Resume Work opens", file: file, line: line)
    }

    // MARK: The removed drawer, for the exploratory sessions only

    // ExploratoryUITests' and ExploratoryCombinations' sessions still drive the left drawer the bottom tabs replaced
    // (2026-10-11); they skip until they move to the tabs (`sessionsFollowBottomTabs`). These keep them compiling, and
    // a step that still reaches for the drawer fails instead of passing by doing nothing.

    func phoneDrawer(_ app: XCUIApplication) -> XCUIElement { app.segmentedControls["drawerSections"].firstMatch }

    /// Never true on the bottom tabs: the drawer's sections control is gone (`workspaceExplorer` is now the Workspace
    /// tab's Files and Git page).
    func phoneDrawerShown(_ app: XCUIApplication) -> Bool { phoneDrawer(app).exists }

    @discardableResult
    func revealInDrawer(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        XCTFail("The iPhone has no drawer since the bottom tabs (2026-10-11): \(element)")
        return element
    }

    func drawerSectionSegment(_ app: XCUIApplication, _ section: String) -> XCUIElement {
        app.buttons["drawerSection-" + section].firstMatch
    }

    func drawerWorkspaceRow(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.buttons["drawerWorkspace-" + id].firstMatch }

    func drawerWorkspaceExpander(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.buttons["drawerWorkspaceExpand-" + id].firstMatch }

    func findInDrawerGroups(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTFail("The iPhone has no drawer groups since the bottom tabs (2026-10-11): \(element)")
    }

    /// The exploratory sessions' "drawer": Workspace's list.
    func openPhoneDrawer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        showPhoneTab(app, "Workspace", file: file, line: line)
    }

    func revealInTaskMenu(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTFail("The iPhone's tab menu has no per-task actions since the bottom tabs (2026-10-11): \(element)")
    }

    // MARK: Shake-down regressions (2026-10-05)

    /// Ends a focused search with the button beside its field (Cancel or Close, whatever the bar shows).
    private func endPhoneSearch(_ app: XCUIApplication, field: XCUIElement) {
        guard field.exists else { return }
        for label in ["Cancel", "Close"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                .first { $0.isHittable && abs($0.frame.midY - field.frame.midY) < 30 }
            if let button { button.tap(); return }
        }
    }

    /// Asserts the keyboard is up and `element` sits above it, in sight.
    private func assertAboveKeyboard(_ app: XCUIApplication, _ element: XCUIElement, _ what: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The keyboard is up for \(what)", file: file, line: line)
        XCTAssertTrue(element.exists, what, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, keyboard.frame.minY + 1, "\(what) sits above the keyboard", file: file, line: line)
    }

    /// A new agent chat opens on the plain chat's landing, with no tiles (2026-10-07; B-3's Browse files tile went with
    /// them); B-11 and B-18: Resume Work's search sits above the keyboard in its sheet (the drawer has had no Resume
    /// Work page since 2026-10-06; Home's Resume box opens it since 2026-10-07); and its Terminal Logs and New Browser
    /// Tab open what they say.
    /// Run with `--enable-preview` for New Browser Tab.
    func testPhoneDrawerRoutes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        // A terminal, so Resume Work lists its Terminals section and Terminal Logs.
        newPhoneTerminal(app)
        newPhoneChat(app)
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20),
                      "A new agent chat opens on the plain chat's landing")
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.exists, "…over its composer")
        XCTAssertFalse(app.buttons["chatBrowseFiles"].exists, "…with no tiles")
        attach(app, "agent-chat-landing")

        // B-11, the sheet: Resume work opens with its search focused, and the field is in sight above the keyboard.
        openPhoneResumeWork(app)
        let sheetField = app.searchFields["Chats, Files and Tabs"]
        XCTAssertTrue(sheetField.waitForExistence(timeout: 8))
        assertAboveKeyboard(app, sheetField, "Resume Work's search in its sheet")
        attach(app, "b11-resume-sheet-search")
        endPhoneSearch(app, field: sheetField)
        app.buttons["resumeWorkClose"].tap()
        XCTAssertTrue(sheetField.waitForNonExistence(timeout: 5))

        // B-18: Terminal Logs opens the archive's terminal logs once Resume Work's sheet has gone.
        openPhoneResumeWork(app)
        let logs = sidebarItem(app, "sidebarTerminalLogs")
        if sidebarLists(app, logs) {
            logs.tap()
            XCTAssertTrue(app.descendants(matching: .any)["archiveList"].firstMatch.waitForExistence(timeout: 10),
                          "Terminal Logs opens the archive")
            attach(app, "b18-terminal-logs")
            let done = app.buttons["archiveDone"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
        } else {
            XCTFail("Resume Work lists Terminal Logs for the open terminal")
        }

        // B-18: New Browser Tab opens the Browser in front (the harness's --enable-preview).
        openPhoneResumeWork(app)
        let browser = sidebarItem(app, "sidebarNewBrowserTab")
        if sidebarLists(app, browser) {
            browser.tap()
            XCTAssertTrue(app.searchFields["Chats, Files and Tabs"].waitForNonExistence(timeout: 5), "Resume Work's sheet goes")
            XCTAssertTrue(app.descendants(matching: .any)["browserAddress"].firstMatch.waitForExistence(timeout: 15)
                          || app.descendants(matching: .any)["browserStartPage"].firstMatch.exists,
                          "New Browser Tab shows the Browser")
            attach(app, "b18-new-browser-tab")
        } else {
            XCTFail("Resume Work offers New Browser Tab on a host with previews (run with --enable-preview)")
        }
    }

    /// B-8 and B-12: opening the header's tab menu takes the keyboard away and putting it away never brings the
    /// keyboard back; in landscape with the keyboard up the header makes way and the editor keeps room for its text.
    func testPhoneKeyboardStaysWithItsSurface() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        openPhoneWorkspacePage(app, "files")
        let document = app.buttons["drawerFile-hello.txt"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))
        openFileFromRow(app, document)
        let editor = app.textViews["fileEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let keyboard = app.keyboards.firstMatch

        // B-8: the tab menu, opened and put away, leaves no keyboard behind. (Its Copy File went with the menu's
        // per-task actions: the menu lists only Home and the open tasks, owner's decision, 2026-10-11.)
        editor.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.buttons["workspaceSwitcher"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Opening the tab menu puts the keyboard away")
        let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "The tab menu opens")
        // A tap outside the menu, below it and clear of the editor's text, puts it away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5), "A tap outside puts the tab menu away")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(keyboard.exists, "Putting the tab menu away does not bring the editor's keyboard back")
        attach(app, "b8-after-task-menu")

        // B-12: landscape with the keyboard up.
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        Thread.sleep(forTimeInterval: 1)
        editor.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        attach(app, "b12-landscape-keyboard")
        // With the simulator's hardware keyboard connected (XCUITest's typing connects it now and then) the keyboard
        // element sits below the screen and nothing covers the editor, so there is nothing for the header to make way
        // for: only an on-screen keyboard is B-12's case. Simulator: I/O > Keyboard > Connect Hardware Keyboard off.
        if !keyboard.frame.intersection(app.frame).isEmpty {
            XCTAssertFalse(app.buttons["workspaceSwitcher"].exists, "The header makes way while the keyboard is up in landscape")
        } else {
            XCTContext.runActivity(named: "B-12's header not checked: no software keyboard on screen (hardware keyboard connected)") { _ in }
        }
        XCTAssertGreaterThanOrEqual(editor.frame.height, 44, "The editor keeps room for its text")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["workspaceSwitcher"].waitForExistence(timeout: 5), "In portrait the header is back")
    }

    /// B-7 and B-20 on the bottom tabs: Workspace → Files reads again when the host comes back, without Retry; a
    /// refusal on Workspace → Git (switching branches with changes present) shows in sight, not at the top of the list.
    func testPhoneWorkspaceRecoveryAndRefusal() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)

        // B-7: the Files page opened while the host is away, kept open while it comes back.
        try hostControl(fixture, "stop")
        XCTAssertTrue(app.descendants(matching: .any)["connectionBanner"].firstMatch.waitForExistence(timeout: 30))
        openPhoneWorkspacePage(app, "files")
        XCTAssertTrue(app.descendants(matching: .any)["filesIssue"].firstMatch.waitForExistence(timeout: 20),
                      "The Files page says it could not read the folder")
        attach(app, "b7-files-offline")
        try hostControl(fixture, "start")
        XCTAssertTrue(app.buttons["drawerFile-hello.txt"].waitForExistence(timeout: 60),
                      "The Files page reads the folder again once the host is back, without Retry")
        attach(app, "b7-files-recovered")

        // B-20: a refused branch switch far down the repository page shows its reason in sight.
        openPhoneWorkspacePage(app, "git")
        let tree = app.descendants(matching: .any)["gitTree"].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: 15))
        XCTAssertTrue(tree.buttons["gitChange-changes-README.md"].waitForExistence(timeout: 20))
        // Branches starts folded.
        let branches = gitSectionHeader(app, "branches")
        for _ in 0..<8 where !branches.isHittable { tree.swipeUp() }
        XCTAssertTrue(branches.isHittable)
        branches.tap()
        // New Branch… asks for the name in an alert (GI-3), whose field has the keyboard.
        let newBranch = app.buttons["gitNewBranch"].firstMatch
        XCTAssertTrue(newBranch.waitForExistence(timeout: 5), "Branches unfolds with New Branch…")
        for _ in 0..<8 where !newBranch.isHittable { tree.swipeUp() }
        XCTAssertTrue(newBranch.isHittable)
        newBranch.tap()
        let naming = systemAlert(app)
        let name = naming.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "New Branch… asks for the name")
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { name.tap() }
        name.typeText("phone-branch")
        attach(app, "b20-new-branch-alert")
        naming.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "gitCreateBranch", "Create")).firstMatch.tap()
        XCTAssertTrue(naming.waitForNonExistence(timeout: 5), "Create puts the alert away")
        let branch = app.buttons["gitBranch-phone-branch"].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 15), "The new branch is listed")
        // The create's success shows only in the list (GI-2, 2026-10-06); a refusal is the system's alert, in sight
        // wherever the person scrolled to.
        let alert = systemAlert(app)
        XCTAssertFalse(alert.exists, "Creating the branch is not refused")
        for _ in 0..<3 where !branch.isHittable { tree.swipeUp() }
        branch.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "The switch is refused with its reason")
        XCTAssertTrue(alert.isHittable, "The reason is in sight where the person is")
        attach(app, "b20-refusal-in-sight")
        alert.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "OK puts the refusal away")
        XCTAssertTrue(phoneTabBar(app).exists, "Files and Git keep the bottom bar")
    }
}
