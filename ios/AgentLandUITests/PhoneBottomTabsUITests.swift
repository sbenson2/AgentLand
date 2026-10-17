import XCTest

extension FullWorkspaceUITests {
    /// Uses the app's existing pairing. Starts empty sessions; never sends a prompt or command.
    func testPhoneAgentLaunchers() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "phone-launchers")
        let navigationOnly = fixture.marker == "navigation-only"
        let app = XCUIApplication()
        app.launchEnvironment["AGENTLAND_CLOUDKIT"] = "0"
        app.launchEnvironment["AGENTLAND_REMOTE_ACCESS"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["workspaceSwitcher"].waitForExistence(timeout: 25))
        addTeardownBlock {
            if app.state == .runningForeground {
                self.attachText(app.debugDescription, "phone-launchers-final-tree")
                self.attach(app, "phone-launchers-final")
            }
        }
        let bar = app.tabBars.firstMatch
        func home() {
            let switcher = app.buttons["workspaceSwitcher"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in switcher.isHittable }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                           "Wait for sheets and session transitions to release the header")
            switcher.tap()
            let row = app.buttons["quickTabHome"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["homeWordmark"].waitForExistence(timeout: 5))
            XCTAssertTrue(bar.buttons["Chat"].isSelected)
        }
        home()
        XCTAssertEqual(bar.buttons.allElementsBoundByIndex.map(\.label), ["Chat", "Terminal", "Workspace", "Settings"])
        // Chat's launchers name the agents themselves (2026-10-12): Claude Code and Codex, in the workspace.
        for (id, title) in [("claude", "Claude Code"), ("codex", "Codex")] {
            let button = app.buttons["phoneChatProvider-" + id]
            if !navigationOnly || button.exists { XCTAssertEqual(button.label, title) }
        }
        attach(app, "phone-agent-chat-home")
        bar.buttons["Terminal"].tap()
        for (id, title) in [("claude", "Claude Code"), ("codex", "Codex")] {
            XCTAssertEqual(app.buttons["phoneTerminalProgram-" + id].label, title)
        }
        XCTAssertFalse(app.buttons["phoneTerminalProgram-shell"].exists)
        XCTAssertFalse(app.buttons["phoneTerminalProgram-opencode"].exists)
        attach(app, "phone-agent-terminal-home")

        bar.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settingsStatus"].waitForExistence(timeout: 10))
        XCTAssertTrue(bar.exists, "Root destinations keep the bottom bar")
        bar.buttons["Chat"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.buttons["Workspace"].tap()
        XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(bar.exists)
        app.buttons["Manage Workspaces"].tap()
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pickerProject-'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10), "Use an existing workspace on the paired Mac")
        project.tap()
        XCTAssertTrue(project.waitForNonExistence(timeout: 10))
        home()

        // A follow-up navigation pass reuses the sessions created by the launch pass.
        // Host-advertised provider availability can change independently of Home navigation.
        if !navigationOnly {
            for provider in ["claude", "codex"] {
                app.buttons["phoneChatProvider-" + provider].tap()
                let draft = app.descendants(matching: .any)["chatDraft"].firstMatch
                XCTAssertTrue(draft.waitForExistence(timeout: 30), "A direct provider button starts a chat in the workspace")
                XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
                attach(app, "phone-agent-chat-" + provider)
                app.buttons["phoneBackHome"].tap()
                XCTAssertTrue(bar.waitForExistence(timeout: 5))
            }
            for program in ["claude", "codex"] {
                bar.buttons["Terminal"].tap()
                app.buttons["phoneTerminalProgram-" + program].tap()
                let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
                XCTAssertTrue(canvas.waitForExistence(timeout: 30), "A direct program button starts its terminal")
                XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
                attach(app, "phone-agent-terminal-" + program)
                home()
            }
        }
        app.buttons["workspaceSwitcher"].tap()
        let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
        let tasks = menu.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quickTab-'")).allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(tasks.count, 4, "Both chats and both terminals remain open")
        try XCTUnwrap(tasks.first).tap()
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "Resuming from the top menu also hides the bottom bar")
        home()
    }

    func testPhoneHomeSwitcher() throws {
        continueAfterFailure = false
        _ = try fixture(for: "phone-menu")
        let app = XCUIApplication()
        app.launchEnvironment["AGENTLAND_CLOUDKIT"] = "0"
        app.launchEnvironment["AGENTLAND_REMOTE_ACCESS"] = "0"
        app.launch()
        addTeardownBlock {
            if app.state == .runningForeground {
                self.attachText(app.debugDescription, "phone-inline-final-tree")
                self.attach(app, "phone-inline-final")
            }
        }
        let header = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(header.waitForExistence(timeout: 25), "Keep the existing Mac pairing")
        header.tap()
        let initialHome = app.buttons["quickTabHome"]
        XCTAssertTrue(initialHome.waitForExistence(timeout: 5))
        initialHome.tap()
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let headerFrame = header.frame
        let barFrame = bar.frame
        let workspaceName = try XCTUnwrap(header.value as? String)
        attach(app, "phone-inline-home-before-tabs")
        attachText(app.debugDescription, "phone-inline-home-before-tabs-tree")
        for launcher in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'phoneChatProvider-'")).allElementsBoundByIndex {
            XCTAssertLessThanOrEqual(launcher.frame.maxY, bar.frame.minY, "The native bar must be clear before tapping it")
        }
        for destination in ["Chat", "Terminal", "Workspace", "Settings"] {
            bar.buttons[destination].tap()
            let expectedTitle = ["Workspace", "Settings"].contains(destination) ? destination : workspaceName
            XCTAssertEqual(header.value as? String, expectedTitle)
            XCTAssertEqual(header.frame.midY, headerFrame.midY, accuracy: 1)
            XCTAssertEqual(bar.frame.minY, barFrame.minY, accuracy: 1)
            XCTAssertEqual(bar.frame.height, barFrame.height, accuracy: 1)
            XCTAssertFalse(app.buttons["phoneBackHome"].exists, "Root content stays in the shared shell")
            XCTAssertFalse(app.descendants(matching: .any)["sessionOpeningLoader"].firstMatch.exists)
            if destination == "Workspace" {
                XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["homeWordmark"].exists)
            } else if destination == "Settings" {
                XCTAssertTrue(app.buttons["settingsStatus"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["homeWordmark"].exists)
                XCTAssertFalse(app.navigationBars["Settings"].exists, "The fixed header supplies the root title")
                app.buttons["Appearance"].tap()
                XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
                XCTAssertEqual(header.value as? String, "Settings")
                XCTAssertTrue(bar.buttons["Chat"].isHittable)
                bar.buttons["Chat"].tap()
                bar.buttons["Settings"].tap()
                XCTAssertTrue(app.buttons["settingsStatus"].waitForExistence(timeout: 5), "Reenter at the Settings root")
            } else {
                XCTAssertTrue(app.staticTexts["homeWordmark"].exists)
                let prefix = destination == "Chat" ? "phoneChatProvider-" : "phoneTerminalProgram-"
                for launcher in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex {
                    XCTAssertLessThanOrEqual(launcher.frame.maxY, bar.frame.minY, "Content must leave the native bar's touch area clear")
                }
            }
            attach(app, "phone-inline-" + destination.lowercased())
            app.buttons["workspaceSwitcher"].tap()
            let home = app.buttons["quickTabHome"]
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            XCTAssertEqual(home.label, "Home")
            let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
            let rows = menu.buttons.allElementsBoundByIndex
            XCTAssertEqual(rows.first?.identifier, "quickTabHome")
            XCTAssertTrue(rows.allSatisfy { $0.identifier == "quickTabHome" || $0.identifier.hasPrefix("quickTab-") },
                          "The menu contains Home and task rows, never bottom navigation destinations")
            if destination == "Workspace" || destination == "Settings" { XCTAssertFalse(home.isSelected) }
            attach(app, "phone-home-menu-from-\(destination.lowercased())")
            home.tap()
            XCTAssertTrue(app.staticTexts["homeWordmark"].waitForExistence(timeout: 5))
            XCTAssertTrue(bar.buttons["Chat"].isSelected)
        }
        header.tap()
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quickTab-'")).firstMatch
        XCTAssertTrue(task.exists, "Reuse an existing task without launching or sending anything")
        let taskTitle = task.label
        task.tap()
        XCTAssertEqual(header.value as? String, taskTitle)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "Session surfaces retain their full work area")
        header.tap()
        app.buttons["quickTabHome"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(header.value as? String, workspaceName)
        attach(app, "phone-inline-home-final")
    }

    /// Read-only tour of the bottom tabs on the existing pairing: never starts a session, sends anything or
    /// changes a setting. Provider and program buttons are only recorded, never tapped.
    func testPhoneTabsPairedSmoke() throws {
        continueAfterFailure = false
        _ = try fixture(for: "phone-smoke")
        let app = XCUIApplication()
        app.launchEnvironment["AGENTLAND_CLOUDKIT"] = "0"
        app.launchEnvironment["AGENTLAND_REMOTE_ACCESS"] = "0"
        app.launch()
        addTeardownBlock {
            if app.state == .runningForeground {
                self.attachText(app.debugDescription, "smoke-final-tree")
                self.attach(app, "smoke-final")
            }
        }
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 25), "Keep the existing Mac pairing")
        let bar = app.tabBars.firstMatch
        let wordmark = app.staticTexts["homeWordmark"]
        if !bar.waitForExistence(timeout: 3) {
            // A session was left in front; return Home without touching it.
            switcher.tap()
            let home = app.buttons["quickTabHome"]
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            home.tap()
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(bar.buttons.allElementsBoundByIndex.map(\.label), ["Chat", "Terminal", "Workspace", "Settings"])
        XCTAssertFalse(app.descendants(matching: .any)["workspaceDrawerToggle"].firstMatch.exists, "The drawer is gone")
        XCTAssertFalse(app.descendants(matching: .any)["homeRecentWork"].firstMatch.exists)
        XCTAssertEqual(app.searchFields.count, 0)

        func record(_ prefix: String, _ name: String) {
            let found = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
            let summary = found.isEmpty ? "none found" : found.map { "\($0.identifier) = \($0.label)" }.joined(separator: "\n")
            XCTContext.runActivity(named: "\(name): \(summary.replacingOccurrences(of: "\n", with: "; "))") { _ in }
            attachText(summary, name)
        }

        // Chat
        bar.buttons["Chat"].tap()
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
        record("phoneChatProvider-", "smoke-chat-providers")
        attach(app, "smoke-chat-home")

        // Terminal
        bar.buttons["Terminal"].tap()
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
        record("phoneTerminalProgram-", "smoke-terminal-programs")
        attach(app, "smoke-terminal-home")

        // Top switcher
        switcher.tap()
        let home = app.buttons["quickTabHome"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
        XCTAssertEqual(menu.buttons.allElementsBoundByIndex.first?.identifier, "quickTabHome")
        attach(app, "smoke-switcher")
        home.tap()
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.buttons["Chat"].isSelected)

        // Workspace, with its Files and Git pages
        bar.buttons["Workspace"].tap()
        XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 5))
        attach(app, "smoke-workspace")
        for (row, shot) in [("phoneFiles", "smoke-files"), ("phoneGit", "smoke-git")] {
            app.buttons[row].tap()
            let back = app.buttons["phoneBackToWorkspace"]
            XCTAssertTrue(back.waitForExistence(timeout: 10), "\(row) opens its page")
            XCTAssertTrue(bar.exists, "\(row) keeps the bottom bar")
            attach(app, shot)
            back.tap()
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "Back returns to the Workspace list")
        }

        // Settings, looking at Appearance without changing it
        bar.buttons["Settings"].tap()
        let status = app.buttons["settingsStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (status.value as? String)?.contains("Connected") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 20), .completed,
                       "Settings reports Connected, not \(String(describing: status.value))")
        XCTContext.runActivity(named: "settingsStatus: \(status.label) — \(String(describing: status.value))") { _ in }
        attach(app, "smoke-settings")
        app.buttons["Appearance"].firstMatch.tap()
        let appearance = app.navigationBars["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        attach(app, "smoke-appearance")
        appearance.buttons.firstMatch.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5), "Back returns to the Settings root")

        bar.buttons["Chat"].tap()
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
    }

    /// Close/reopen a saved chat; inspect and cancel End on an existing terminal.
    /// Destructive terminal success/failure paths use the in-memory transport in unit tests.
    func testPhoneCloseAndHistory() throws {
        continueAfterFailure = false
        _ = try fixture(for: "phone-menu")
        let app = XCUIApplication()
        app.launchEnvironment["AGENTLAND_CLOUDKIT"] = "0"
        app.launchEnvironment["AGENTLAND_REMOTE_ACCESS"] = "0"
        app.launch()
        addTeardownBlock {
            if app.state == .runningForeground {
                self.attachText(app.debugDescription, "phone-close-final-tree")
                self.attach(app, "phone-close-final")
            }
        }
        let header = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(header.waitForExistence(timeout: 25))
        header.tap()
        let tasks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quickTab-'"))
        let ids = tasks.allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(ids.isEmpty)
        var closedID: String?
        var chatTitle: String?
        for id in ids {
            app.buttons[id].tap()
            let close = app.buttons["phoneCloseTab"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            if close.label == "Close Chat" {
                closedID = id
                chatTitle = header.value as? String
                XCTAssertGreaterThan(close.frame.midX, header.frame.maxX)
                XCTAssertEqual(close.frame.midY, header.frame.midY, accuracy: 3)
                let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in close.isEnabled }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
                attach(app, "phone-close-chat-button")
                close.tap()
                XCTAssertEqual(app.alerts.count, 0)
                header.tap()
                XCTAssertFalse(app.buttons[id].exists, "Closing removes this chat from the open-tab picker")
                break
            }
            header.tap()
        }
        XCTAssertNotNil(closedID, "Use one of the already-open general chats")
        app.buttons["quickTabHome"].tap()
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["phoneCloseTab"].exists)
        bar.buttons["Workspace"].tap()
        app.buttons["phoneChatHistory"].tap()
        XCTAssertTrue(app.navigationBars["Chat History"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.segmentedControls["archiveScope"].exists)
        attach(app, "phone-chat-history")
        let title = try XCTUnwrap(chatTitle)
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText(title)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'archiveChatRow' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Closed chats remain in history")
        row.tap()
        XCTAssertTrue(app.buttons["phoneCloseTab"].waitForExistence(timeout: 10))
        XCTAssertEqual(header.value as? String, title)
        XCTAssertEqual(app.buttons["phoneCloseTab"].label, "Close Chat")
        attach(app, "phone-chat-reopened")

        header.tap()
        let remaining = tasks.allElementsBoundByIndex.map(\.identifier)
        var inspectedTerminal = false
        for id in remaining {
            app.buttons[id].tap()
            let close = app.buttons["phoneCloseTab"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            if close.label == "Close Terminal" {
                let terminalTitle = header.value as? String
                let buttonFrame = close.frame
                close.tap()
                let keep = app.buttons["phoneKeepTerminal"].firstMatch
                XCTAssertTrue(keep.waitForExistence(timeout: 5))
                let end = app.buttons["phoneConfirmEndTerminal"].firstMatch
                XCTAssertTrue(end.exists)
                XCTAssertLessThan(end.frame.midY, app.frame.midY, "The warning opens near the header X")
                XCTAssertGreaterThan(end.frame.minY, buttonFrame.maxY)
                XCTAssertTrue(app.staticTexts["This stops the terminal session on your Mac. Unsaved work may be lost."].exists)
                attach(app, "phone-terminal-end-warning")
                keep.tap()
                XCTAssertEqual(header.value as? String, terminalTitle)
                XCTAssertTrue(close.exists)
                inspectedTerminal = true
                header.tap()
                break
            }
            header.tap()
        }
        XCTAssertTrue(inspectedTerminal, "Inspect a saved terminal without ending any real process")
        app.buttons["quickTabHome"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
    }

    /// Opt-in owner pairing; uses the normal UI and leaves the app connected.
    func testPairPhoneToMac() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "phone-pair")
        let app = XCUIApplication()
        app.launchEnvironment["AGENTLAND_CLOUDKIT"] = "0"
        app.launchEnvironment["AGENTLAND_REMOTE_ACCESS"] = "0"
        app.launch()
        // `freshHost` (pair-test-iphone.py) disconnects a pairing left from another host before pairing again.
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))

        // A second launch proves the app retained its own host and device token.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25))
        app.tabBars.buttons["Settings"].tap()
        let status = app.buttons["settingsStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let connected = NSPredicate(format: "value CONTAINS 'Connected'")
        expectation(for: connected, evaluatedWith: status)
        waitForExpectations(timeout: 20)
        attach(app, "phone-connected-to-mac")
        app.tabBars.buttons["Chat"].tap()
    }

    /// The bottom tabs against the harness's disposable host: the four destinations, Workspace's folder sheet and
    /// Manage Workspaces, Settings' root and Appearance, an OpenCode chat (as ⌘N starts one) with the fixture's reply and
    /// a shell terminal (as ⌥⌘T) with its proof file, both kept open while the header's switcher moves between them and Home, and
    /// the destinations again in Dark at the largest text size. Home's Claude, ChatGPT, Claude Code and Codex buttons
    /// are only recorded: they start the real agents.
    func testPhoneBottomTabs() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        let bar = phoneTabBar(app)
        if !bar.waitForExistence(timeout: 15) { showPhoneHome(app) }
        XCTAssertEqual(bar.buttons.allElementsBoundByIndex.map(\.label), ["Chat", "Terminal", "Workspace", "Settings"])
        XCTAssertFalse(app.buttons["workspaceDrawerToggle"].exists)
        XCTAssertFalse(app.buttons["homeRecentWork"].exists)
        XCTAssertEqual(app.searchFields.count, 0)
        XCTAssertLessThanOrEqual(bar.frame.maxY, app.frame.maxY, "Keep the native tab bar within the window at system spacing")

        // Workspace: the folder sheet, then Manage Workspaces → the fixture.
        bar.buttons["Workspace"].tap()
        XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workspaceSwitcher"].value as? String, "Workspace")
        attach(app, "phone-workspace-light")
        app.buttons["phoneChooseWorkspace"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        attach(app, "phone-workspace-picker")
        // The native folder sheet has a Close button.
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        choosePhoneWorkspace(app, "fixture")

        // Home's launchers: what the host advertises, recorded and never tapped.
        showPhoneTab(app, "Chat")
        XCTAssertTrue(app.staticTexts["homeWordmark"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workspaceSwitcher"].value as? String, "Fixture", "Home's header names the workspace in use")
        let chatLaunchers = phoneHomeLaunchers(app).allElementsBoundByIndex.map(\.identifier)
        attach(app, "phone-chat-light")
        bar.buttons["Terminal"].tap()
        XCTAssertTrue(app.staticTexts["homeWordmark"].waitForExistence(timeout: 5))
        let terminalLaunchers = phoneHomeLaunchers(app).allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(app.buttons["phoneTerminalProgram-shell"].exists, "No Shell button (owner's choice)")
        XCTAssertFalse(app.buttons["phoneTerminalProgram-opencode"].exists, "No OpenCode button (owner's choice)")
        attachText("Chat: \(chatLaunchers)\nTerminal: \(terminalLaunchers)", "phone-home-launchers")
        XCTContext.runActivity(named: "Home launchers — Chat: \(chatLaunchers); Terminal: \(terminalLaunchers)") { _ in }
        attach(app, "phone-terminal-light")

        // Settings: its root has no navigation bar (the header names it); Appearance is pushed with its own.
        bar.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settingsStatus"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Settings"].exists, "The fixed header supplies the root title")
        XCTAssertEqual(app.buttons["workspaceSwitcher"].value as? String, "Settings")
        let appearance = app.buttons["Appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(bar.exists, "Settings' pages keep the bottom bar")
        attach(app, "phone-settings-light")

        // A chat with the fixture's OpenCode (as ⌘N starts one): the bar hides while it is in front.
        newPhoneChat(app)
        attachText(app.debugDescription, "phone-chat-opening-tree")
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "A session hides the bottom bar")
        let newTitle = app.buttons["workspaceSwitcher"].value as? String
        XCTAssertEqual(app.buttons["phoneCloseTab"].label, "Close Chat")
        let draft = app.descendants(matching: .any)["chatDraft"].firstMatch
        draft.tap()
        draft.typeText("Hello from the bottom tab navigation test")
        app.buttons["chatSend"].tap()
        let reply = try XCTUnwrap(fixture.chatReply)
        let response = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", reply)).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 45), "Chat must use the real host and deterministic local model")
        attach(app, "phone-chat-response")
        // The host names the chat from its first message; the header follows.
        let switcher = app.buttons["workspaceSwitcher"]
        let renamed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (switcher.value as? String) != newTitle }, object: nil)
        _ = XCTWaiter.wait(for: [renamed], timeout: 15)
        let chatTitle = try XCTUnwrap(switcher.value as? String)
        hideKeyboard(app)
        app.buttons["phoneBackHome"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "Home returns with the bar")
        XCTAssertTrue(bar.buttons["Chat"].isSelected)

        // A shell terminal (as ⌥⌘T starts one) writes its proof file on the host.
        newPhoneTerminal(app)
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        let terminalTitle = try XCTUnwrap(app.buttons["workspaceSwitcher"].value as? String)
        XCTAssertEqual(app.buttons["phoneCloseTab"].label, "Close Terminal")
        canvas.tap()
        canvas.typeText("printf 'phone tabs %s\\n' 'terminal ready' > phone-tabs-terminal-proof.txt; cat phone-tabs-terminal-proof.txt\n")
        XCTAssertTrue(try waitForTerminalText("phone tabs terminal ready", in: canvas, timeout: 15))
        attach(app, "phone-terminal-output")
        if app.buttons["terminalHideKeyboard"].exists { app.buttons["terminalHideKeyboard"].tap() }

        // The header's switcher lists Home first, then both open sessions, and returns to each as it was.
        app.buttons["workspaceSwitcher"].tap()
        let home = app.buttons["quickTabHome"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertEqual(home.label, "Home")
        let menu = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
        let rows = menu.buttons.allElementsBoundByIndex
        XCTAssertEqual(rows.first?.identifier, "quickTabHome")
        XCTAssertTrue(rows.allSatisfy { $0.identifier == "quickTabHome" || $0.identifier.hasPrefix("quickTab-") },
                      "The menu lists Home and open tasks only")
        let labels = rows.map(\.label)
        XCTAssertTrue(labels.contains(chatTitle) && labels.contains(terminalTitle), "Both sessions stay open: \(labels)")
        attach(app, "phone-top-switcher")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 5))
        switchPhoneTask(app, titled: chatTitle)
        XCTAssertTrue(response.waitForExistence(timeout: 8), "The chat keeps its reply")
        XCTAssertEqual(app.buttons["workspaceSwitcher"].value as? String, chatTitle)
        switchPhoneTask(app, titled: terminalTitle)
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        XCTAssertTrue(try waitForTerminalText("phone tabs terminal ready", in: canvas, timeout: 8), "The terminal keeps its output")
        app.buttons["phoneBackHome"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["homeWordmark"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workspaceSwitcher"].value as? String, "Fixture")
        XCTAssertEqual(app.searchFields.count, 0)

        // Dark at the largest text size: every destination again.
        app.terminate()
        launch(app, appearance: "dark", largestText: true)
        XCTAssertTrue(app.buttons["workspaceSwitcher"].waitForExistence(timeout: 25))
        if !bar.waitForExistence(timeout: 3) { showPhoneHome(app) }
        bar.buttons["Chat"].tap()
        XCTAssertTrue(app.staticTexts["homeWordmark"].waitForExistence(timeout: 5))
        attach(app, "phone-chat-dark-largest")
        bar.buttons["Workspace"].tap()
        XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 5))
        attach(app, "phone-workspace-dark-largest")
        bar.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settingsStatus"].waitForExistence(timeout: 5))
        attach(app, "phone-settings-dark-largest")
        app.terminate()
    }

    /// The session loader (the circus loader on the art's backdrop, from a new session's request until its surface is
    /// on screen) covers the whole iPhone screen: nothing of the shell shows at the bottom, and the header's switcher
    /// is under it and out of reach (owner, 2026-10-12: "the bottom of the screen shows through a bit and i can still
    /// see the switcher"). `-AgentLandSessionOpeningPreview` (Debug builds) holds the loader up over a paired Home.
    func testPhoneSessionLoaderCoversScreen() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        let bar = phoneTabBar(app)
        if !bar.waitForExistence(timeout: 15) { showPhoneHome(app) }
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(waitUntilHittable(switcher, timeout: 10), "Home's header is in reach before the loader")
        let loader = app.descendants(matching: .any)["sessionOpeningLoader"].firstMatch
        XCTAssertFalse(loader.exists)
        attach(app, "phone-home-before-loader")

        for appearance in ["light", "dark"] {
            app.terminate()
            launch(app, appearance: appearance, largestText: false, extraArguments: ["-AgentLandSessionOpeningPreview"])
            XCTAssertTrue(loader.waitForExistence(timeout: 25), "The held loader is on screen")
            // The loader pops in over about a third of a second.
            Thread.sleep(forTimeInterval: 1)
            attach(app, "phone-session-loader-\(appearance)")
            attachText(app.debugDescription, "phone-session-loader-\(appearance)-tree")
            let screen = app.windows.firstMatch.frame
            let cover = loader.frame
            XCTAssertEqual(cover.minX, screen.minX, accuracy: 1, "The loader reaches the left edge")
            XCTAssertEqual(cover.maxX, screen.maxX, accuracy: 1, "The loader reaches the right edge")
            XCTAssertEqual(cover.minY, screen.minY, accuracy: 1, "The loader covers the header (\(cover) on \(screen))")
            XCTAssertEqual(cover.maxY, screen.maxY, accuracy: 1, "The loader covers the bottom (\(cover) on \(screen))")
            // XCUITest lists elements SwiftUI hides from VoiceOver: the app's own walk says what VoiceOver reaches.
            let reach = reachableElements(app)
            XCTAssertTrue(reach.contains { $0.identifier == "sessionOpeningLoader" }, "VoiceOver reads the loader")
            XCTAssertFalse(reach.contains { $0.identifier == "workspaceSwitcher" }, "VoiceOver does not reach the switcher")
            for destination in ["Chat", "Terminal", "Workspace", "Settings"] {
                XCTAssertFalse(reach.contains { $0.label == destination }, "VoiceOver does not reach the bar's \(destination)")
            }
            XCTAssertFalse(switcher.exists && switcher.isEnabled, "The switcher is out of reach under the loader")
            // Taps where the switcher and the bar's Terminal are land on the loader: no menu, no other tab.
            let selected = bar.buttons["Chat"].exists && bar.buttons["Chat"].isSelected
            if switcher.exists { switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            XCTAssertFalse(app.buttons["quickTabHome"].waitForExistence(timeout: 2), "The switcher's menu stays closed")
            if bar.buttons["Terminal"].exists {
                bar.buttons["Terminal"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 1)
                XCTAssertFalse(bar.buttons["Terminal"].isSelected, "The bar under the loader takes no tap")
                XCTAssertEqual(bar.buttons["Chat"].isSelected, selected)
            }
            XCTAssertTrue(loader.exists, "The loader stays up")
        }
        app.terminate()
    }
}
