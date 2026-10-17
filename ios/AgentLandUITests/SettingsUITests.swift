import XCTest

/// Settings, restructured (2026-10-04) and shown in the gear's popover (2026-10-05): every page in light, dark, the
/// largest standard text size and the largest accessibility size, for review, and Forget… on the saved host, which
/// returns to pairing. Opt-in (`integration/check-ios-product.py --tests testSettingsScreenshots`).
extension FullWorkspaceUITests {
    func testSettingsScreenshots() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        let runs: [(appearance: String, size: String?, name: String)] = [
            ("light", nil, "light"), ("dark", nil, "dark"),
            ("light", "UICTContentSizeCategoryXXXL", "light-xxxl"),
            ("light", "UICTContentSizeCategoryAccessibilityXXXL", "light-largest")
        ]
        for (index, run) in runs.enumerated() {
            app.terminate()
            app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                                   "-agentland.appearance", run.appearance, "-AgentLandFixedQuip", fixedQuip]
            if let size = run.size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launch()
            try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true && index == 0)
            // The workspace chosen once stays chosen; Settings needs none, and opens from any screen.
            if index == 0 { showProjects(app) }
            openSettings(app)
            XCTAssertTrue(app.descendants(matching: .any)["settingsStatus"].firstMatch.waitForExistence(timeout: 8),
                          "Settings opens with the host's status")
            attach(app, "settings-root-" + run.name)
            if run.size != nil { scrollAndAttach(app, "settings-root-" + run.name) }
            for page in ["Connection", "Agents & Providers", "Plain Chats", "Appearance", "Chat", "Terminal", "Notifications",
                         "Privacy & Security", "About AgentLand"] {
                guard settingsRow(app, page, timeout: 3) != nil else { continue }
                openSettingsPage(app, page)
                Thread.sleep(forTimeInterval: 0.6)
                let slug = page.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
                attach(app, "settings-\(slug)-\(run.name)")
                scrollAndAttach(app, "settings-\(slug)-\(run.name)")
                goBack(app)
                XCTAssertTrue(settingsListShows(app, within: 5), "Back returns to Settings' list")
            }
            closeSettings(app)
        }

        // Forget…: the system's confirmation, then pairing (at the default text size).
        app.terminate()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: false)
        openSettings(app)
        openSettingsPage(app, "Connection")
        let menu = app.buttons["connectionSavedHostMenu"].firstMatch
        let popover = app.otherElements["settingsDrawer"].firstMatch
        for _ in 0..<4 where !menu.isHittable { popover.swipeUp() }
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Each saved host has its menu")
        menu.tap()
        let forget = app.buttons["connectionForget"].firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        forget.tap()
        let confirm = app.buttons["connectionConfirmForget"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Forgetting asks first")
        attach(app, "settings-connection-forget-confirmation")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Pair with your Mac"].waitForExistence(timeout: 10),
                      "Forgetting the host in use returns to pairing")
        XCTAssertFalse(app.buttons["workspaceSwitcher"].exists)
        attach(app, "settings-forgotten-pairing")
    }

    /// Scrolls the Settings popover's page down a screen at a time (at most three) and attaches each, so a long page
    /// is seen whole.
    private func scrollAndAttach(_ app: XCUIApplication, _ name: String) {
        let popover = app.otherElements["settingsDrawer"].firstMatch
        guard popover.exists else { return }
        for step in 1...3 {
            let before = app.screenshot().pngRepresentation
            popover.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
            if app.screenshot().pngRepresentation == before { break }
            attach(app, "\(name)-more\(step)")
        }
        // Back to the top, where the rows the test taps next are.
        for _ in 0..<4 { popover.swipeDown() }
    }
}
