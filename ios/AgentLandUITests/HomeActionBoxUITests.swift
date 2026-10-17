import XCTest
import UIKit

extension FullWorkspaceUITests {
    /// Opt-in check on the paired simulator. Workspace forms are cancelled, and only the two
    /// empty chat tabs created here are closed; no folders or model messages are created.
    func testHomeWorkspaceAndQuickTabs() throws {
        _ = try fixture(for: "chat-providers")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 30))
        attach(app, "home-new-workspace")
        app.buttons["openWorkspace"].tap()
        let workspacePanel = app.descendants(matching: .any)["homeWorkspacePicker"].firstMatch
        XCTAssertTrue(workspacePanel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeWorkspaceCreate"].exists)
        XCTAssertFalse(app.buttons["homeWorkspaceFolder"].exists)
        XCTAssertFalse(app.buttons["homeWorkspacePicker"].exists)
        let existingFolder = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "homeFolder-", "Already a workspace"
        )).firstMatch
        XCTAssertTrue(existingFolder.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["homeFolderOpen"].isEnabled, "Choose a folder before opening a workspace")
        attach(app, "native-workspace-sheet")
        app.buttons["homeWorkspaceCreate"].tap()
        XCTAssertTrue(app.textFields["newWorkspaceName"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["newWorkspaceLocation"].value as? String, "~")
        attach(app, "create-workspace-form")
        app.buttons["newWorkspaceCancel"].tap()
        XCTAssertTrue(workspacePanel.waitForExistence(timeout: 5), "Cancel returns to workspace selection")
        XCTAssertFalse(app.buttons["homeFolderNew"].exists)
        XCTAssertFalse(app.buttons["New Folder"].exists)
        XCTAssertTrue(existingFolder.waitForExistence(timeout: 10))
        let folderName = existingFolder.label
        existingFolder.tap()
        XCTAssertTrue(app.navigationBars[folderName].waitForExistence(timeout: 5))
        let back = app.navigationBars[folderName].buttons.matching(NSPredicate(format: "label IN %@", ["Back", "Home"])).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "iOS provides Back for the pushed folder")
        back.tap()
        XCTAssertTrue(existingFolder.waitForExistence(timeout: 5))
        existingFolder.tap()
        XCTAssertTrue(app.navigationBars[folderName].waitForExistence(timeout: 5))
        app.buttons["homeWorkspaceCreate"].tap()
        XCTAssertTrue(app.textFields["newWorkspaceName"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.buttons["newWorkspaceLocation"].value as? String)?.hasSuffix("/" + folderName) == true,
                      "Creation uses the folder being browsed")
        app.buttons["newWorkspaceCancel"].tap()
        let openReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["homeFolderOpen"])
        XCTAssertEqual(XCTWaiter.wait(for: [openReady], timeout: 5), .completed)
        attach(app, "workspace-folder-selection")
        app.buttons["homeFolderOpen"].tap()
        XCTAssertTrue(workspacePanel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 5))

        var switcherWidth: CGFloat = 0
        func openQuickSwitcher() -> [XCUIElement] {
            let headerFrame = app.buttons["workspaceSwitcher"].frame
            app.buttons["workspaceSwitcher"].tap()
            let home = app.buttons["quickTabHome"]
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            let panel = app.descendants(matching: .any)["phoneHeaderPanel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            // The modal accessibility container covers the shell; the List has the visible menu's frame.
            let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            let belowHeader = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !menu.frame.isNull && menu.frame.minY >= headerFrame.maxY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [belowHeader], timeout: 5), .completed,
                           "The menu opens below its header button")
            switcherWidth = menu.frame.width
            XCTAssertGreaterThanOrEqual(menu.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.maxX)
            let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quickTab-")).allElementsBoundByIndex
            assertQuickTabMenuFitsRows(app, menu: menu, rows: [home] + tabs)
            for tab in tabs { XCTAssertLessThan(home.frame.minY, tab.frame.minY, "Home is always first") }
            XCTAssertFalse(app.buttons["headerWorkspaceNew"].exists)
            XCTAssertFalse(app.buttons["closeCurrentTab"].exists)
            XCTAssertFalse(app.buttons["terminalKeyboard"].exists)
            return tabs
        }
        var known = Set(openQuickSwitcher().map(\.identifier))
        let homeOnlyWidth = known.isEmpty ? switcherWidth : nil
        if let homeOnlyWidth {
            XCTAssertLessThan(homeOnlyWidth, app.frame.width - 60, "A short label gets a compact menu")
        }
        attach(app, "quick-switcher-initial-width")
        app.buttons["quickTabHome"].tap()
        var created: [String] = []
        for provider in ["claude", "codex"] {
            app.buttons["homeNewChat"].tap()
            app.buttons["chatProvider-" + provider].tap()
            XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 20))
            let tabs = openQuickSwitcher()
            if let homeOnlyWidth {
                XCTAssertGreaterThan(switcherWidth, homeOnlyWidth, "Longer labels widen the menu")
            }
            let added = Set(tabs.map(\.identifier)).subtracting(known)
            XCTAssertEqual(added.count, 1)
            let id = try XCTUnwrap(added.first)
            created.append(id)
            known.insert(id)
            attach(app, "quick-switcher-" + provider)
            app.buttons["quickTabHome"].tap()
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 10))
        }
        _ = openQuickSwitcher()
        app.buttons[created[0]].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 10))
        _ = openQuickSwitcher()
        app.buttons[created[1]].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["workspaceDrawerToggle"].tap()
        for id in created {
            let tabID = id.replacingOccurrences(of: "quickTab-", with: "")
            XCTAssertTrue(app.buttons["workspacePickerTab-" + tabID].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["closeDrawerTab-" + tabID].exists)
        }
        attach(app, "drawer-open-tabs-controls")
        for id in created {
            app.buttons["closeDrawerTab-" + id.replacingOccurrences(of: "quickTab-", with: "")].tap()
        }
        app.buttons["workspaceDrawerToggle"].tap()
        _ = openQuickSwitcher()
        if let homeOnlyWidth {
            XCTAssertEqual(switcherWidth, homeOnlyWidth, accuracy: 1, "Closing the tabs shrinks the menu again")
        }
        app.buttons["quickTabHome"].tap()
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 10))

        for (appearance, large) in [("light", false), ("dark", true)] {
            app.terminate()
            app.launchArguments = ["-agentland.appearance", appearance]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 30))
            checkHomeNativeMenus(app, capture: appearance + (large ? "-largest-text" : ""))
            checkNativeHeaderPanels(app, capture: appearance + (large ? "-largest-text" : ""))
        }
    }

    /// Native menus dismiss on a tap outside their system-owned presentation.
    func closeHomeActionBox(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25)).tap()
    }

    func checkHomeNativeMenus(_ app: XCUIApplication, capture: String) {
        for action in ["homeNewTerminal", "homeRecentWork"] {
            let button = app.buttons[action]
            for _ in 0..<4 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable)
            let originalFrame = button.frame
            button.tap()
            let option: XCUIElement
            if action == "homeNewTerminal" {
                option = app.buttons["homeTerminalProgram-shell"]
            } else {
                let choices = app.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "homeResume"
                ))
                XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 8))
                // Workspace subtitles make this a scrolling native menu. Its first
                // accessibility element may be outside the visible portion.
                option = choices.allElementsBoundByIndex.first(where: \.isHittable) ?? choices.firstMatch
            }
            XCTAssertTrue(option.waitForExistence(timeout: 8))
            XCTAssertTrue(option.isHittable)
            XCTAssertGreaterThanOrEqual(option.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(option.frame.maxY, app.frame.maxY)
            XCTAssertFalse(app.descendants(matching: .any)["homeExpandedActionBox"].firstMatch.exists)
            attach(app, "home-native-menu-\(action)-\(capture)")
            if action == "homeRecentWork" {
                let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeResume")).allElementsBoundByIndex.map(\.label)
                attachText(labels.joined(separator: "\n"), "resume-context-" + capture)
            }
            closeHomeActionBox(app)
            XCTAssertTrue(option.waitForNonExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.frame, originalFrame, "The native menu preserves Home's layout")
        }
        XCTAssertTrue(app.buttons["openWorkspace"].isEnabled)
        app.buttons["openWorkspace"].tap()
        let panel = app.descendants(matching: .any)["homeWorkspacePicker"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeWorkspaceCreate"].exists)
        XCTAssertFalse(app.buttons["homeWorkspaceFolder"].exists)
        XCTAssertGreaterThan(panel.frame.width, app.frame.width * 0.8)
        XCTAssertEqual(panel.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertGreaterThan(panel.frame.height, app.frame.height * 0.8, "The native sheet uses the phone's available height")
        XCTAssertGreaterThanOrEqual(panel.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.frame.maxY)
        XCTAssertTrue(app.buttons["homeWorkspacePickerClose"].isHittable)
        XCTAssertTrue(app.buttons["homeWorkspaceCreate"].isHittable)
        attach(app, "native-workspace-sheet-" + capture)
        app.buttons["homeWorkspacePickerClose"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    func checkNativeHeaderPanels(_ app: XCUIApplication, capture: String) {
        for id in ["workspaceDrawerToggle", "workspaceSwitcher", "headerSettings"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let frame = button.frame
            button.tap()
            let panel = app.descendants(matching: .any)["phoneHeaderPanel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            if id == "workspaceSwitcher" {
                XCTAssertTrue(app.buttons["quickTabHome"].waitForExistence(timeout: 5))
                let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                let belowHeader = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !menu.frame.isNull && menu.frame.minY >= frame.maxY
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [belowHeader], timeout: 5), .completed,
                               "Below the header at every text size")
                let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quickTab-")).allElementsBoundByIndex
                assertQuickTabMenuFitsRows(app, menu: menu, rows: [app.buttons["quickTabHome"]] + tabs)
            }
            attach(app, "native-glass-panel-\(id)-\(capture)")
            // The header remains a dismissal target while its panel is modal to VoiceOver.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons[id].isHittable)
        }
    }

    /// The compact list must fit both one row and several without a blank band below them.
    private func assertQuickTabMenuFitsRows(_ app: XCUIApplication, menu: XCUIElement, rows: [XCUIElement],
                                           file: StaticString = #filePath, line: UInt = #line) {
        let first = rows[0]
        let last = rows[rows.count - 1]
        let balancedInsets = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let top = first.frame.minY - menu.frame.minY
            let bottom = menu.frame.maxY - last.frame.maxY
            return top >= 0 && bottom >= 0 && abs(top - bottom) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [balancedInsets], timeout: 5), .completed,
                       "Equal space above and below the menu rows: menu \(menu.frame), first \(first.frame), last \(last.frame)",
                       file: file, line: line)
        for row in rows {
            XCTAssertTrue(row.isHittable, file: file, line: line)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44, file: file, line: line)
        }
    }

    // Keep the harness entry points while replacing the retired custom-box assertions.
    func testPhoneActionBoxes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        for (appearance, large) in [("light", false), ("dark", false), ("light", true)] {
            launch(app, appearance: appearance, largestText: large)
            try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
            showProjects(app)
            checkHomeNativeMenus(app, capture: appearance + (large ? "-largest-text" : ""))
            app.terminate()
        }
    }

    func testHomeBoxClosesWithAnimations() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false, animated: true)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        for round in 0..<3 { checkHomeNativeMenus(app, capture: "animated-\(round)") }
    }
}
