import XCTest
import UIKit

/// Home's platform launchers and quip, the native header, and the workspace and Settings panels. They
/// run through integration/check-ios-product.py like the rest of `FullWorkspaceUITests`, whose fixture
/// and helpers they share.
extension FullWorkspaceUITests {
    /// Home's actions in reading order, two to a row.
    static let homeCapsules = [("homeNewChat", "New Chat"), ("homeNewTerminal", "New Terminal"), ("homeBrowseFiles", "Browse Files"),
                               ("homeRecentWork", "Resume Work"), ("openWorkspace", "Open Workspace"), ("homeSettings", "Settings")]
    /// The iPhone Home's launchers since the bottom tabs (owner, 2026-10-11): the Chat destination's Claude and ChatGPT,
    /// and the Terminal destination's Claude Code and Codex, as the fixture's host advertises them. They start the real
    /// agents, so tests only measure them.
    static let phoneHomeActions = [("phoneChatProvider-claude", "Claude"), ("phoneChatProvider-codex", "ChatGPT")]
    static let phoneTerminalLaunchers = [("phoneTerminalProgram-claude", "Claude Code"), ("phoneTerminalProgram-codex", "Codex")]
    var expectedHomeActions: [(String, String)] {
        UIDevice.current.userInterfaceIdiom == .phone ? Self.phoneHomeActions : Self.homeCapsules
    }

    // MARK: Home

    /// Home keeps the iPhone destination's two 64 pt launchers or the six 48 pt iPad actions in a 12 pt grid. Ordinary
    /// Home never scrolls; accessibility text may scroll the launcher. The iPhone's Home is the Chat and Terminal
    /// destinations (bottom tabs, 2026-10-11): their launchers are checked in place, never tapped.
    func testHomeCapsulesAndQuip() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        assertHomeCapsules(app)
        attach(app, "home-before-layout-assertions")
        assertHomeTitle(app)
        let beforeSwipe = expectedHomeActions.map { app.buttons[$0.0].frame }
        app.swipeUp()
        for (index, frame) in beforeSwipe.enumerated() {
            XCTAssertEqual(app.buttons[expectedHomeActions[index].0].frame.minY, frame.minY, accuracy: 1,
                           "Ordinary Home does not scroll or bounce")
        }
        let quip = app.staticTexts["homeQuip"]
        let oneLine = quip.frame.height
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertLessThan(oneLine, 40, "The phone quip uses the smaller approved type size")
        }
        attach(app, "home-capsules-light")

        // On iPad, Home's Settings covers the launcher from the bottom (the iPhone's Settings is a bottom tab).
        if UIDevice.current.userInterfaceIdiom != .phone {
            app.buttons["homeSettings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8), "Home's Settings opens Settings")
            assertBottomSettingsDrawer(app)
            XCTAssertFalse(app.buttons["homeNewChat"].isHittable, "Home is covered by Settings")
            attach(app, "home-settings")
            closeSettings(app)
            XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            // The old Home's New Terminal and Resume menus are gone on iPhone: the Terminal destination is the same Home
            // with Claude Code and Codex in place of Claude and ChatGPT, and Resume Work is ⇧⌘F. Its title, quip and
            // launchers are checked there too.
            showPhoneTab(app, "Terminal")
            for (identifier, title) in Self.phoneTerminalLaunchers {
                let launcher = app.buttons[identifier]
                XCTAssertTrue(launcher.waitForExistence(timeout: 5), "The Terminal destination has \(identifier)")
                XCTAssertEqual(launcher.label, title)
                XCTAssertGreaterThanOrEqual(launcher.frame.height, 44, "\(identifier) keeps the native touch target")
            }
            XCTAssertFalse(app.buttons["phoneTerminalProgram-shell"].exists, "No Shell launcher (owner's choice, 2026-10-11)")
            XCTAssertEqual(app.staticTexts["homeQuip"].label, fixedQuip, "The Terminal destination keeps Home's quip")
            assertHomeTitle(app)
            attach(app, "home-terminal-destination")
            showPhoneTab(app, "Chat")
        }

        // A long quip stops at two lines, still between the tent and the actions; VoiceOver reads it whole.
        let longQuip = "Juggling three pull requests while the ringmaster rewrites the big top in a language nobody on the crew has heard of before today"
        app.terminate()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light", "-AgentLandFixedQuip", longQuip]
        app.launch()
        XCTAssertTrue(workspaceHeader(app).waitForExistence(timeout: 20))
        showProjects(app)
        XCTAssertTrue(quip.waitForExistence(timeout: 5))
        XCTAssertEqual(quip.label, longQuip)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertGreaterThan(quip.frame.height, 20, "The smaller quip remains readable across two lines")
            XCTAssertLessThan(quip.frame.height, 90, "The two-line quip stays bounded across its available fonts")
        } else {
            XCTAssertGreaterThan(quip.frame.height, oneLine * 1.5, "The quip wraps onto a second line")
            XCTAssertLessThan(quip.frame.height, oneLine * 2.5, "…and stops there")
        }
        XCTAssertLessThan(quip.frame.maxY, app.buttons[expectedHomeActions[0].0].frame.minY)
        attach(app, "home-long-quip")

        // The largest text sizes use one column and may scroll the launcher when it exceeds the viewport.
        app.terminate()
        launch(app, appearance: "light", largestText: true)
        XCTAssertTrue(workspaceHeader(app).waitForExistence(timeout: 20))
        showProjects(app)
        let frames = expectedHomeActions.map { identifier, _ -> CGRect in
            let capsule = app.buttons[identifier]
            XCTAssertTrue(capsule.waitForExistence(timeout: 10), identifier)
            return capsule.frame
        }
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 1, "One column at the largest sizes")
            XCTAssertEqual(frame.width, frames[0].width, accuracy: 1)
            if index > 0 { XCTAssertEqual(frame.minY - frames[index - 1].maxY, 12, accuracy: 1, "12 pt apart") }
        }
        let last = app.buttons[expectedHomeActions.last!.0]
        let beforeScroll = last.frame.minY
        app.swipeUp()
        if frames.last!.maxY <= app.frame.maxY - 32 {
            XCTAssertEqual(last.frame.minY, beforeScroll, accuracy: 1,
                           "Accessibility Home stays fixed when its expanded content still fits")
        } else {
            XCTAssertLessThan(last.frame.minY, beforeScroll,
                              "Accessibility Home may scroll only when its expanded content exceeds the viewport")
        }
        attach(app, "home-capsules-largest-text")
    }

    /// Home's actions stay readable, evenly sized and above the safe-area clearance.
    func assertHomeCapsules(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        var frames: [CGRect] = []
        for (identifier, title) in expectedHomeActions {
            let capsule = app.buttons[identifier]
            XCTAssertTrue(capsule.waitForExistence(timeout: 10), "Home has \(identifier)", file: file, line: line)
            XCTAssertEqual(capsule.label, title, file: file, line: line)
            frames.append(capsule.frame)
        }
        guard frames.count == expectedHomeActions.count else { return }
        for ((identifier, _), frame) in zip(expectedHomeActions, frames) {
            XCTAssertGreaterThanOrEqual(frame.height, 44,
                                        "\(identifier) preserves the native control touch target", file: file, line: line)
            XCTAssertEqual(frame.width, frames[0].width, accuracy: 1, "\(identifier) is as wide as the others", file: file, line: line)
            XCTAssertEqual(frame.height, frames[0].height, accuracy: 1, "\(identifier) is as tall as the others", file: file, line: line)
        }
        for row in 0..<(frames.count / 2) {
            let left = frames[2 * row], right = frames[2 * row + 1]
            XCTAssertEqual(left.minY, right.minY, accuracy: 1, "Row \(row + 1) lines up", file: file, line: line)
            XCTAssertEqual(right.minX - left.maxX, 12, accuracy: 1, "12 pt apart across", file: file, line: line)
            if row > 0 {
                XCTAssertEqual(left.minY - frames[2 * row - 2].maxY, 12, accuracy: 1, "12 pt apart down", file: file, line: line)
            }
        }
        XCTAssertGreaterThanOrEqual(app.frame.maxY - frames.last!.maxY, 32,
                                    "Home leaves at least 32 pt below its launcher", file: file, line: line)
    }

    // MARK: The bar

    /// The centered workspace switcher is the one map of Home, workspaces and retained tabs. Surface actions
    /// remain in the trailing title menu; the old Show Sidebar button is absent. iPad only: the iPhone's header and tab
    /// menu are PhoneBottomTabsUITests'.
    func testNativeBarButtons() throws {
        if UIDevice.current.userInterfaceIdiom == .phone {
            throw XCTSkip("The iPhone's header and tab menu are covered by PhoneBottomTabsUITests")
        }
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(switcher.frame.midX - app.frame.midX), 24, "The workspace map is centered")
        XCTAssertFalse(app.buttons["showSidebar"].exists, "The old sidebar control is gone")
        attach(app, "bar-home-light")

        // A workspace tab appears in the map after opening Files.
        browseFilesFromHome(app)
        XCTAssertTrue(app.buttons["file-hello.txt"].waitForExistence(timeout: 15))
        let title = app.buttons["fileActions"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Files retains its trailing title actions")
        switcher.tap()
        XCTAssertTrue(app.buttons["workspacePickerHome"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspacePickerProject-fixture"].exists)
        XCTAssertGreaterThan(workspacePickerTabs(app).count, 0,
                             "The picker lists retained workspace tabs")
        app.buttons["workspacePickerHome"].tap()
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 5))

        // Standalone chats share that map too.
        app.buttons["homeNewChat"].tap()
        let newChat = app.buttons["homeNewChatStandalone"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].waitForExistence(timeout: 15))
        switcher.tap()
        XCTAssertGreaterThan(workspacePickerTabs(app).count, 0,
                             "The picker lists the standalone chat")
        app.buttons["workspacePickerClose"].tap()

        showProjects(app)
        browseFilesFromHome(app)
        attach(app, "bar-files-light")
        title.tap()
        XCTAssertTrue(app.buttons["closeCurrentTab"].waitForExistence(timeout: 5), "The title opens its menu")
        attach(app, "bar-files-title-menu")
        // Below the menu, above the Files search field: the tap only puts the menu away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["closeCurrentTab"].waitForNonExistence(timeout: 5))

    }

    // MARK: The Settings drawer

    /// iPad retains its searchable history and bottom Settings drawer. iPad only: the iPhone's left drawer was removed
    /// with the bottom tabs (owner, 2026-10-11).
    func testDrawerSearchAndSettings() throws {
        if UIDevice.current.userInterfaceIdiom == .phone {
            throw XCTSkip("The iPhone has no drawer; its Settings is a bottom tab")
        }
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)

        // Resume Work reaches the existing searchable history without exposing Home beneath it.
        openSidebar(app)
        let field = app.searchFields["Chats, Files and Tabs"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        endSidebarSearch(app)
        XCTAssertTrue(app.buttons["resumeWorkClose"].exists)
        XCTAssertFalse(app.buttons["homeNewChat"].isHittable, "Resume Work covers Home")
        attach(app, "resume-work")
        app.buttons["resumeWorkClose"].tap()
        XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))

        app.buttons["homeSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        assertBottomSettingsDrawer(app)
        XCTAssertFalse(app.buttons["homeNewChat"].isHittable, "Home is unavailable behind Settings")
        let reached = Set(reachableElements(app).map(\.name))
        XCTAssertTrue(reached.contains("settingsClose") && reached.contains("Appearance"), "VoiceOver reaches Settings: \(reached)")
        XCTAssertFalse(reached.contains("homeNewChat"), "VoiceOver cannot reach Home behind Settings")
        attach(app, "settings-drawer")

        openSettingsPage(app, "Appearance")
        assertBottomSettingsDrawer(app)
        attach(app, "settings-drawer-appearance")
        closeSettings(app)
        XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))

        // The dimmed area closes the root settings drawer too.
        app.buttons["homeSettings"].tap()
        XCTAssertTrue(app.otherElements["settingsDrawer"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.08)).tap()
        XCTAssertTrue(app.otherElements["settingsDrawer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeNewChat"].isHittable)
    }
}
