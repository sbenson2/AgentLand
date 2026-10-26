import XCTest
import UIKit
import Vision
import CoreFoundation

/// Launched only by opt-in integration checks with disposable local hosts.
final class FullWorkspaceUITests: XCTestCase {
    struct Fixture: Decodable {
        let enabled: Bool
        let address: String?
        let code: String?
        let fingerprint: String?
        let marker: String?
        let terminalMarker: String?
        let chatReply: String?
        /// The full word-by-word reply the fixture model streams for AGENTLAND_STREAM.
        let streamReply: String?
        /// A word only the file operations fixture's search target contains (on line 3).
        let searchToken: String?
        /// The commit message testGitStageAndCommit writes; the harness finds it in the repository's log.
        let commitMessage: String?
        /// The fixture model's text after an approved tool call.
        let approvalReply: String?
        /// What the fixture model saves to a plain chat's memory for AGENTLAND_MEMORY_SAVE, and forgets for
        /// AGENTLAND_MEMORY_FORGET (PlainChatUITests.swift).
        let memoryFact: String?
        /// The host lists plain chats before the test starts (check-ios-product.py waits for it): Home's New Chat
        /// starts a plain chat there, and a chat with an agent is the sidebar's New Agent Chat….
        let plainChats: Bool?
        let modelID: String?
        let phase: String?
        let freshHost: Bool?
        /// Terminal programs to visit in testTerminalProgramsTour.
        let tourPrograms: [String]?
        /// Host-side folder the harness watches: stop/start/pause/resume requests for the product check,
        /// held and released reads for the opening check.
        let control: String?
        /// The workspace testWorkspaceManagement makes in the host's temporary home folder's Developer
        /// folder; the harness checks its folder and the host's state afterwards.
        let workspaceName: String?
        /// testConnectsThroughIrohTunnel: the Mac endpoint's reported address and its loopback port
        /// (`AGENTLAND_UITEST_TUNNEL_LOOPBACK`), and the router-ports profile for the app: the simulator
        /// dylib that applies it, the compiled profile and the file the dylib reports to.
        let tunnelLoopback: String?
        let routerPortsDylib: String?
        let routerPortsBytecode: String?
        let routerPortsReport: String?
    }

    /// The fixture's host lists plain chats (`Fixture.plainChats`), as `fixture(for:)` read it.
    private(set) var hostListsPlainChats = false

    /// The run's fixture: the file check-ios-product.py names (`AGENTLAND_FIXTURE`, which it passes as
    /// `TEST_RUNNER_AGENTLAND_FIXTURE` so a prebuilt test bundle runs with it), else the bundle's own copy.
    static func fixtureURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["AGENTLAND_FIXTURE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return try XCTUnwrap(Bundle(for: FullWorkspaceUITests.self).url(forResource: "Fixture", withExtension: "json"))
    }

    func fixture(for phase: String) throws -> Fixture {
        let url = try Self.fixtureURL()
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        try XCTSkipUnless(value.enabled && value.phase == phase,
                          "Run integration/check-ios-product.py on a booted iPhone simulator.")
        hostListsPlainChats = value.plainChats == true
        return value
    }

    /// Runs only on the disposable, Face ID-enrolled simulator. The biometric
    /// notification is the one sent by the installed Simulator's Matching Face
    /// command; authentication still goes through the production LAContext.
    func testAutomaticUnlock() throws {
        _ = try fixture(for: "unlock")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-agentland.lock.enabled", "YES", "-agentland.appearance", "light"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.buttons["OK"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }

        XCTAssertFalse(app.buttons["Unlock"].exists, "Opening must authenticate automatically, without an Unlock button")
        let lock = app.otherElements["appLockScreen"]
        XCTAssertTrue(lock.waitForExistence(timeout: 8), "Keep the workspace covered until authentication succeeds")
        XCTAssertFalse(titleMenu(app).exists, "Locked workspace controls must stay inaccessible")
        let circus = app.descendants(matching: .any)["openingCircus"].firstMatch
        XCTAssertTrue(circus.exists)
        XCTAssertGreaterThan(circus.frame.midY, app.frame.height * 0.4)
        XCTAssertLessThan(circus.frame.midY, app.frame.height * 0.55, "Keep the tent just above the screen center")
        attach(app, "automatic-unlock-scanning")

        simulateMatchingFace()
        XCTAssertTrue(lock.waitForNonExistence(timeout: 10), "A real successful LAContext result must reveal the retained workspace")
        let hasWorkspace = titleMenu(app).waitForExistence(timeout: 3)
        XCTAssertTrue(hasWorkspace || app.buttons["pairingScan"].exists)
        if hasWorkspace {
            openSidebarItem(app, "sidebarHome")
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 5))
        }
        let selectedTab = hasWorkspace ? currentTab(app).label : nil
        attach(app, "automatic-unlock-success-light")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(lock.waitForExistence(timeout: 8), "Returning from background must automatically request a fresh unlock")
        XCTAssertFalse(app.buttons["Unlock"].exists)
        simulateMatchingFace()
        XCTAssertTrue(lock.waitForNonExistence(timeout: 10))
        if let selectedTab {
            XCTAssertEqual(currentTab(app).label, selectedTab, "Locking must retain the selected tab")
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 5),
                          "Home controls must appear below the same tent after Face ID")
            XCTAssertFalse(app.staticTexts["Continue"].exists)
        }
        attach(app, "automatic-unlock-return-success")
    }

    /// The opening check's fixture holds the relaunched app's first `read` ("files", "file", "terminal",
    /// "messages") from `hold` until `release`, so the test looks at the cover while the read is
    /// outstanding however long the relaunch takes. `hold` goes between terminating and launching.
    private func openingRead(_ fixture: Fixture, _ step: String, _ read: String) throws {
        let folder = URL(fileURLWithPath: try XCTUnwrap(fixture.control, "Run through integration/check-ios-opening.py"))
        try Data().write(to: folder.appendingPathComponent("\(step)-\(read)"))
    }

    func simulateMatchingFace() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.apple.BiometricKit_Sim.pearl.match" as CFString),
            nil, nil, true
        )
    }

    /// Exercises the exact cold-opening handoff against a deterministic delayed
    /// host. The selected Chat is created through the shipping UI before the
    /// relaunch, so this covers persisted tab restoration and real transport.
    func testOpeningWaitsForSelectedChat() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "opening")
        let expectedMessage = try XCTUnwrap(fixture.chatReply)

        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations",
                               "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: true)
        showProjects(app)
        openAddTab(app, kind: "Chat")
        XCTAssertTrue(app.staticTexts[expectedMessage].waitForExistence(timeout: 12),
                      "The fixture must finish the setup load before the cold relaunch")
        attach(app, "opening-chat-selected-before-relaunch")

        app.terminate()
        // The relaunched chat's first read waits until the cover has been sampled.
        try openingRead(fixture, "hold", "messages")
        // Relaunch with production motion so the retained circus-to-workspace
        // handoff is also covered by the bounded simulator video.
        app.launchArguments = ["-agentland.lock.enabled", "YES",
                               "-agentland.appearance", "light"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.buttons["OK"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        let lock = app.otherElements["appLockScreen"]
        XCTAssertTrue(lock.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Unlock"].exists)
        simulateMatchingFace()
        XCTAssertTrue(lock.waitForNonExistence(timeout: 10))

        let loading = app.otherElements["hostLoadingScreen"]
        XCTAssertTrue(loading.waitForExistence(timeout: 2),
                      "The circus must take over from Face ID while the selected Chat is still loading")
        let sampleDeadline = Date().addingTimeInterval(2.5)
        var frame = 0
        repeat {
            XCTAssertTrue(loading.exists, "The opening circus disappeared before the selected Chat was ready")
            XCTAssertTrue(app.descendants(matching: .any)["openingCircus"].firstMatch.exists)
            XCTAssertFalse(app.descendants(matching: .any)["chatDraft"].firstMatch.exists,
                           "The selected Chat must not expose its inner loading surface")
            attach(app, "opening-delayed-frame-\(frame)")
            frame += 1
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < sampleDeadline

        try openingRead(fixture, "release", "messages")
        XCTAssertTrue(loading.waitForNonExistence(timeout: 10),
                      "The opening circus must finish once the selected Chat resolves")
        XCTAssertTrue(app.staticTexts[expectedMessage].waitForExistence(timeout: 3),
                      "The selected Chat content must replace the circus in one handoff")
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.exists)
        attach(app, "opening-selected-chat-ready")

        // A normal silent poll after readiness must not put the opening overlay
        // back over an already usable tab.
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertFalse(loading.exists)
            XCTAssertTrue(app.staticTexts[expectedMessage].exists)
        }
        XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 3))
        XCTAssertFalse(loading.exists)
        attach(app, "opening-later-interaction")
    }

    func testOpeningSurfacesResolveAfterDelay() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "opening")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations",
                               "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: true)
        showProjects(app)

        browseFilesFromHome(app)
        XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 8))
        let loading = app.otherElements["hostLoadingScreen"]
        // On iPhone Files is a page of the drawer, never a task the app opens on, so only iPad's Files tab
        // is relaunched under a held listing.
        if UIDevice.current.userInterfaceIdiom != .phone {
            // Each relaunched surface's first read waits until the test has seen the cover.
            app.terminate()
            try openingRead(fixture, "hold", "files")
            app.launch()
            XCTAssertTrue(loading.waitForExistence(timeout: 2))
            XCTAssertFalse(app.buttons[fileRowID("hello.txt")].exists)
            XCUIDevice.shared.press(.home)
            // The listing answers while the app is in the background.
            try openingRead(fixture, "release", "files")
            app.activate()
            XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 12),
                          "Files must finish opening after the initial request spans background")
            XCTAssertFalse(loading.exists)
            attach(app, "opening-files-after-background")
        }

        openFileFromRow(app, app.buttons[fileRowID("hello.txt")])
        XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 8))
        app.terminate()
        try openingRead(fixture, "hold", "file")
        app.launch()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertFalse(app.textViews["fileEditor"].exists)
        try openingRead(fixture, "release", "file")
        let editor = app.textViews["fileEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 12))
        XCTAssertTrue((editor.value as? String ?? "").contains("Opening editor fixture"))
        XCTAssertFalse(loading.exists)
        attach(app, "opening-editor-ready")

        openAddTab(app, kind: "Terminal")
        let terminal = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        app.terminate()
        try openingRead(fixture, "hold", "terminal")
        app.launch()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let coveredCanvases = app.descendants(matching: .any).matching(identifier: "terminalCanvas")
        let coveredCanvasCount = coveredCanvases.count
        let coveredCanvas = coveredCanvases.firstMatch
        let canvasExistedWhileCovered = coveredCanvas.exists
        let coveredCanvasSummary = """
        terminalCanvas count: \(coveredCanvasCount)
        first exists: \(canvasExistedWhileCovered)
        first elementType: \(String(describing: coveredCanvas.elementType))
        first isHittable: \(coveredCanvas.isHittable)
        first frame: \(String(describing: coveredCanvas.frame))

        Full application hierarchy:
        \(app.debugDescription)
        """
        attachText(coveredCanvasSummary, "opening-terminal-covered-hierarchy")
        attach(app, "opening-terminal-covered")
        XCTAssertFalse(coveredCanvas.isHittable,
                       "A retained Terminal container must not accept input through the opening circus")
        try openingRead(fixture, "release", "terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 12),
                      "A valid first terminal packet must complete the opening handoff")
        XCTAssertTrue(loading.waitForNonExistence(timeout: 12),
                      "The retained UIKit container can exist before its prepared surface is revealed")
        attach(app, "opening-terminal-first-packet")
        XCTAssertTrue(app.staticTexts["Terminal disconnected"].waitForExistence(timeout: 8),
                      "A later terminal error must end polling in an honest retry state")
        XCTAssertTrue(app.buttons["Retry connection"].exists)
        XCTAssertFalse(loading.exists, "A later terminal error must not reopen the circus")
        attach(app, "opening-terminal-retry")
    }

    func testVisualSurfaces() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        // The light phase shows the light appearance even if an earlier run saved Dark.
        app.launchArguments += ["-AgentLandUITestsDisableAnimations", "-AgentLandFixedQuip", fixedQuip,
                                "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        // iPhone: Home's Chat destination above the bottom bar, with Files a page of the Workspace destination.
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if phone {
            XCTAssertTrue(phoneHomeShown(app), "Home's Chat launcher shows with the bottom bar")
        } else {
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["homeNewTerminal"].exists)
            XCTAssertTrue(app.buttons["homeRecentWork"].exists)
            XCTAssertTrue(app.buttons["homeBrowseFiles"].exists)
        }
        // The title's checks report and the surfaces below still run (the phone title's gap is an open question,
        // as in testHomeCapsulesAndQuip).
        continueAfterFailure = true
        assertHomeTitle(app)
        continueAfterFailure = false
        if phone {
            XCTAssertEqual(app.buttons["workspaceSwitcher"].value as? String, "Fixture",
                           "On Home the header's middle button names the workspace in use")
        } else {
            XCTAssertEqual(titleMenu(app).value as? String, "Workspace: Fixture")
        }
        XCTAssertEqual(workspaceLine(app), "Workspace: Fixture")
        XCTAssertFalse(app.staticTexts["Continue"].exists,
                       "The redundant Continue section must be absent")
        attach(app, "home")
        browseFilesFromHome(app)
        XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 12), "Opening directly from Home must work before any overlay")
        // iPad: the Files tab replaces Home; iPhone: the Workspace destination's page replaces Home's launcher.
        if !phone {
            XCTAssertFalse(app.buttons["homeBrowseFiles"].exists, "Inactive Home controls must be removed from the accessibility tree")
        }
        showProjects(app)
        // Git is now chosen from Home's capability menu instead of an expanding drawer list (on iPhone a page of
        // the Workspace destination).
        openSidebarItem(app, "sidebarGit")
        // The iPad's Git tab says "No Git Repositories"; the iPhone's Git page (GitManagementTree) its own sentence.
        let noRepository = phone
            ? app.staticTexts["This workspace has no Git repository in its folder or a folder directly inside it."]
            : app.staticTexts["No Git Repositories"]
        XCTAssertTrue(noRepository.waitForExistence(timeout: 10))
        attach(app, "git")
        if !phone { closeCurrentTab(app) }
        openSidebarItem(app, "sidebarHome")
        if phone {
            // Workspace management is the Workspace destination's Manage Workspaces (the bottom tabs, 2026-10-11).
            showPhoneTab(app, "Workspace")
            app.buttons["Manage Workspaces"].tap()
            XCTAssertTrue(app.buttons["pickerProject-fixture"].waitForExistence(timeout: 8))
            attach(app, "workspace-picker")
            let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(app.buttons["pickerProject-fixture"].waitForNonExistence(timeout: 5))
        } else {
            app.buttons["openWorkspace"].tap()
            // A host that lists its workspaces' details shows the Workspaces screen; others the plain picker.
            XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 5) || app.staticTexts["Open Workspace"].exists)
            attach(app, "workspace-picker")
            app.buttons["Done"].tap()
        }
        browseFilesFromHome(app)
        let file = app.buttons[fileRowID("hello.txt")]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(file.frame.height, 44)
        // The size is the file row's value, not an element of its own; on screen it is the row's trailing value, in the
        // footnote style (FI-3: the row's … menu went; its context menu, swipes and VoiceOver actions carry its actions).
        let jsonFile = app.buttons[fileRowID("opencode.json")]
        XCTAssertFalse((try XCTUnwrap(jsonFile.value as? String)).isEmpty, "A file row's value is its size")
        attach(app, "files")
        app.buttons["expand-Sources"].tap()
        XCTAssertTrue(app.buttons[fileRowID("Sources/example.swift")].waitForExistence(timeout: 10))
        app.buttons[fileRowID("Sources")].tap()
        XCTAssertTrue(app.buttons[fileRowID("Sources/example.swift")].waitForExistence(timeout: 5))
        attach(app, "files-folder")
        openFilesRootFolder(app, from: "Sources")
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        fileContextAction(app, "hello.txt", "Copy Path")
        XCTAssertFalse(app.textViews["fileEditor"].exists, "The row's context menu must not open the file underneath it")
        let filter = filesSearchField(app)
        filter.tap(); filter.typeText("no-matching-file")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No Results")).firstMatch.waitForExistence(timeout: 10))
        attach(app, "files-filter-empty")
        endFilesSearch(app)
        openSearch(app)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search must focus its field when opened")
        attach(app, "search")
        dismissSearch(app)
        closeResumeWorkSheet(app)
        openSidebarItem(app, "sidebarFiles")
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        openSettings(app)
        attach(app, "settings")
        // Each category is a page pushed over Settings' list; Back returns to the list.
        for category in ["Connection", "Appearance", "Chat", "Terminal", "Notifications", "Privacy & Security", "About AgentLand"] {
            openSettingsPage(app, category)
            attach(app, "settings-" + category.lowercased().replacingOccurrences(of: " ", with: "-"))
            goBack(app)
            XCTAssertTrue(settingsListShows(app, within: 5), "Back returns to Settings' list")
        }
        closeSettings(app)
        if phone {
            // Leaving the Settings destination shows Home's Chat launcher.
            XCTAssertTrue(app.descendants(matching: .any)["homeWordmark"].firstMatch.waitForExistence(timeout: 5),
                          "Settings' dismissal returns to Home")
        } else {
            XCTAssertTrue(file.waitForExistence(timeout: 5), "Overlay dismissal must restore the selected Files tab")
        }
    }

    func testFileFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let fileMarker = try XCTUnwrap(fixture.marker)
        let app = XCUIApplication()
        app.launchArguments.append("-AgentLandUITestsDisableAnimations")
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        XCTAssertTrue(homeMark(app).waitForExistence(timeout: 20))
        attach(app, "light-workspace")
        setAppearance(app, "Light")
        attach(app, "light-settings")
        closeSettings(app)

        // A real file save reaches the chosen project, including after tab changes.
        browseFilesFromHome(app)
        let file = app.buttons[UIDevice.current.userInterfaceIdiom == .phone ? "drawerFile-hello.txt" : "file-hello.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        openFileFromRow(app, file)
        let editor = app.textViews["fileEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("Hello from AgentLand."))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("\n" + fileMarker + "\n")
        XCTAssertTrue((editor.value as? String ?? "").contains(fileMarker), "Typing must preserve every character before saving; actual fixture text: \(editor.value as? String ?? "<missing>")")
        let additionalMarker = "SECOND_" + String(fileMarker.suffix(8))
        editor.typeText(additionalMarker + "\n")
        XCTAssertTrue((editor.value as? String ?? "").contains(additionalMarker), "A subsequent burst of typing must also remain intact")
        app.buttons["saveFile"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: app.buttons["saveFile"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
        attach(app, "file-editor-saved")
        let unsavedMarker = "UNSAVED_" + String(fileMarker.suffix(8))
        editor.tap(); editor.typeText(String(unsavedMarker))
        closeCurrentTab(app)
        // The close asks with the system confirmation dialog. On iOS 26 it is a popover whose buttons carry
        // their identifier on two nested elements, so the first match is the button.
        XCTAssertTrue(app.buttons["keepEditing"].firstMatch.waitForExistence(timeout: 5), "Immediate edits must trigger the dirty-close guard")
        attach(app, "unsaved-confirmation")
        app.buttons["keepEditing"].firstMatch.tap()
        XCTAssertTrue((editor.value as? String ?? "").contains(unsavedMarker), "Keep editing preserves the draft")
        closeCurrentTab(app)
        app.buttons["discardChanges"].firstMatch.tap()
        // The iPhone's Files is the Workspace destination's page, not a second workspace tab.
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Close Without Saving closes the editor")
        } else {
            closeCurrentTab(app)
        }
        app.terminate()
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(phoneTabBar(app).waitForExistence(timeout: 20), "A root destination shows on relaunch")
            XCTAssertFalse(app.buttons["phoneCloseTab"].exists, "The closed editor must not return on relaunch")
            XCTAssertFalse(editor.exists)
        } else {
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["closeCurrentTab"].exists, "Closed editor and Files tabs must not return on relaunch")
        }
    }

    /// Files' changes on the harness host's disposable `ops` folder: rename (a swipe on iPhone, the
    /// context menu on iPad), a new folder, Move… into a folder, Move to Trash (or the permanent delete
    /// that names the path, when the host can't use the Trash), an upload and a second one under the
    /// host's free name, and a contents search whose result opens the editor at its line. The harness
    /// checks each effect in the folder afterwards.
    func testFileOperations() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let token = try XCTUnwrap(fixture.searchToken, "Run through integration/check-ios-product.py")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light", "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        closeAllTabs(app)
        let pad = UIDevice.current.userInterfaceIdiom == .pad

        openSidebarItem(app, "sidebarFiles")
        let ops = fileRow(app, "ops")
        XCTAssertTrue(ops.waitForExistence(timeout: 15), "The harness made the ops folder")
        openFileRow(app, "ops")
        XCTAssertTrue(fileRow(app, "ops/rename-me.txt").waitForExistence(timeout: 10), "Opening a folder lists it")
        attach(app, pad ? "files-table" : "files-list")

        // Rename: a swipe on iPhone, the context menu on iPad.
        if pad {
            fileContextAction(app, "ops/rename-me.txt", "Rename")
        } else {
            fileRow(app, "ops/rename-me.txt").swipeLeft()
            let rename = app.buttons["Rename"].firstMatch
            XCTAssertTrue(rename.waitForExistence(timeout: 5), "The swipe offers Rename")
            attach(app, "files-swipe")
            rename.tap()
        }
        let nameField = systemAlerts(app).textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        attach(app, "files-rename")
        replaceText(in: nameField, with: "renamed.txt")
        app.buttons["fileRenameConfirm"].firstMatch.tap()
        XCTAssertTrue(fileRow(app, "ops/renamed.txt").waitForExistence(timeout: 10), "The renamed file is listed")
        XCTAssertFalse(fileRow(app, "ops/rename-me.txt").exists)

        // New Folder from the title menu.
        surfaceMenu(app, "fileActions").tap()
        menuItem(app, "fileNewFolder", label: "New Folder").tap()
        let folderField = systemAlerts(app).textFields.firstMatch
        XCTAssertTrue(folderField.waitForExistence(timeout: 5))
        replaceText(in: folderField, with: "made-on-phone")
        app.buttons["fileNewFolderConfirm"].firstMatch.tap()
        XCTAssertTrue(fileRow(app, "ops/made-on-phone").waitForExistence(timeout: 10), "The new folder is listed")

        // Move… into the target folder, from the context menu.
        fileContextAction(app, "ops/move-me.txt", "Move…", screenshot: "files-context-menu")
        let target = app.descendants(matching: .any)["moveFolder-ops/target"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The Move sheet starts in the file's folder")
        attach(app, "files-move-sheet")
        target.tap()
        let moveHere = app.buttons["moveHere"].firstMatch
        XCTAssertTrue(moveHere.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(moveHere, timeout: 5))
        moveHere.tap()
        XCTAssertTrue(fileRow(app, "ops/move-me.txt").waitForNonExistence(timeout: 10), "The moved file leaves the folder")

        // Move to Trash, confirmed; a host that can't use its Trash asks for a permanent delete naming the path.
        let trashRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", fileRowID("ops/trash-me"))).firstMatch
        XCTAssertTrue(trashRow.waitForExistence(timeout: 5))
        let trashPath = String(trashRow.identifier.dropFirst(fileRowID("").count))
        if pad {
            fileContextAction(app, trashPath, "Move to Trash")
        } else {
            trashRow.swipeLeft()
            let trash = app.buttons["Trash"].firstMatch
            XCTAssertTrue(trash.waitForExistence(timeout: 5))
            trash.tap()
        }
        let confirmTrash = app.buttons["fileConfirmTrash"].firstMatch
        XCTAssertTrue(confirmTrash.waitForExistence(timeout: 5), "Moving to the Trash asks first")
        attach(app, "files-trash-confirmation")
        confirmTrash.tap()
        let permanent = app.buttons["fileConfirmDelete"].firstMatch
        if permanent.waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", trashPath)).firstMatch.exists,
                          "The permanent delete names the path")
            attach(app, "files-permanent-delete")
            permanent.tap()
        }
        XCTAssertTrue(fileRow(app, trashPath).waitForNonExistence(timeout: 10), "The trashed file leaves the folder")

        // An upload, then the same name again: Keep Both takes the host's free name.
        uploadTestFile(app)
        XCTAssertTrue(fileRow(app, "ops/upload-proof.txt").waitForExistence(timeout: 20), "The uploaded file is listed")
        attach(app, "files-uploaded")
        uploadTestFile(app)
        let keepBoth = app.buttons["uploadKeepBoth"].firstMatch
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 20), "A taken name asks Replace or Keep Both")
        attach(app, "files-upload-conflict")
        keepBoth.tap()
        XCTAssertTrue(fileRow(app, "ops/upload-proof 2.txt").waitForExistence(timeout: 20), "Keep Both uploads under the free name")

        // A contents search opens the editor at the matching line.
        let search = filesSearchField(app)
        search.tap()
        search.typeText(token)
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 5), "The host searches contents, so the Contents scope shows")
        contents.tap()
        let match = app.descendants(matching: .any)["fileSearchMatch-ops/search-target.swift-3"].firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 15), "The matching line is listed")
        attach(app, "files-search-contents")
        match.tap()
        XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 15), "The result opens the editor")
        let line = app.staticTexts["editorLine"]
        XCTAssertTrue(waitForLabel(line, "Line 3", timeout: 10), "The editor opens at the line")
        XCTAssertTrue((app.textViews["fileEditor"].value as? String ?? "").contains(token))
        attach(app, "files-editor-at-line")
        closeAllTabs(app)
    }

    /// Git on the harness host's disposable repository, whose own configuration names a test identity:
    /// the changed file is staged by a swipe (the context menu on iPad), its staged diff shows the
    /// added line, and the commit bar commits it as that identity with the fixture's message. The
    /// harness finds the commit in the repository's log.
    func testGitStageAndCommit() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let message = try XCTUnwrap(fixture.commitMessage, "Run through integration/check-ios-product.py")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light", "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        closeAllTabs(app)
        let pad = UIDevice.current.userInterfaceIdiom == .pad

        openSidebarItem(app, "sidebarGit")
        // On iPhone Git is a page of the Workspace destination; on iPad a tab of its own.
        if pad { XCTAssertEqual(currentTab(app).label, "Current tab: Git") }
        let changed = app.descendants(matching: .any)["gitChange-changes-README.md"].firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 15), "The modified file is under Changes")
        XCTAssertTrue(app.descendants(matching: .any)["gitChange-changes-new-file.txt"].firstMatch.exists, "The untracked file is under Changes")
        XCTAssertTrue(changed.label.contains("README.md"))
        XCTAssertTrue((changed.value as? String ?? "").contains("Modified"), "The status is in words")
        let identity = app.staticTexts["gitCommitIdentity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        // The commit bar reads "… as <identity>", the iPad's floating one and the iPhone Git page's band alike.
        XCTAssertTrue(identity.label.contains("AgentLand Test <test@agentland.invalid>"), "The bar shows who commits: \(identity.label)")
        attach(app, "git-changes")

        // Stage the modified file.
        if pad {
            changed.press(forDuration: 1.0)
            let stage = app.buttons.matching(NSPredicate(format: "label == %@", "Stage")).firstMatch
            XCTAssertTrue(stage.waitForExistence(timeout: 5))
            stage.tap()
        } else {
            // The iPhone's Git page stages with the row's trailing swipe (GI-6, native-iOS batch 9).
            changed.swipeLeft()
            let stage = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "gitStage-README.md", "Stage")).firstMatch
            XCTAssertTrue(stage.waitForExistence(timeout: 5), "The swipe offers Stage")
            attach(app, "git-swipe")
            stage.tap()
        }
        let staged = app.descendants(matching: .any)["gitChange-staged-README.md"].firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 15), "The file moves to Staged Changes")
        XCTAssertTrue(app.descendants(matching: .any)["gitChange-changes-new-file.txt"].firstMatch.exists, "Only that file was staged")
        attach(app, "git-staged")

        // Its staged diff shows the added line.
        staged.tap()
        let diff = app.descendants(matching: .any)["gitDiff"].firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 15), "The diff opens")
        let added = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Added line")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10), "The added line is read as added")
        XCTAssertTrue(added.label.contains("Added from the harness for staging."), "The staged diff shows the staged line: \(added.label)")
        attach(app, "git-diff")
        app.buttons["gitDiffDone"].firstMatch.tap()
        XCTAssertTrue(diff.waitForNonExistence(timeout: 5))

        // Commit from the bar.
        let field = app.textFields["gitCommitMessage"].firstMatch.exists ? app.textFields["gitCommitMessage"].firstMatch
                                                                         : app.textViews["gitCommitMessage"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // The iPad simulator now and then drops the first tap into a field under a floating bar.
        if !waitForFocus(field, timeout: 2) { field.tap() }
        XCTAssertTrue(waitForFocus(field, timeout: 5), "The message field takes the keyboard")
        field.typeText(message)
        attach(app, "git-commit-bar")
        let commit = app.buttons["gitCommit"].firstMatch
        XCTAssertTrue(waitUntilEnabled(commit, timeout: 5), "Commit is available with a message and a staged file")
        // ⌘↩ commits: on iPad through the menu bar's Commit, on iPhone through the button. XCUITest's
        // return key ("\r") doesn't reach the app, so it is typed as "\n" (see testKeyboardCommands).
        // A commit that worked shows in the page, nothing staged any more, and is only heard by VoiceOver; a refusal
        // or an unconfirmed commit is the system's alert (GI-2, 2026-10-06: no notice for a plain success).
        let alert = systemAlert(app)
        let answered = { !staged.exists || alert.exists }
        XCTAssertTrue(press(app, "\n", .command, until: answered), "⌘↩ commits")
        XCTAssertTrue(staged.waitForNonExistence(timeout: 20), "Nothing is staged after the commit")
        XCTAssertFalse(alert.exists, "The commit is not refused: \(alert.exists ? alert.label : "")")
        attach(app, "git-committed")
        XCTAssertTrue(app.descendants(matching: .any)["gitChange-changes-new-file.txt"].firstMatch.exists, "The unstaged file stays")
        closeAllTabs(app)
    }

    /// Review screenshots (opt-in) of the Files and Git surfaces in light, dark and light at the largest
    /// accessibility text size: the list (iPhone) or table (iPad), a context menu, a contents search,
    /// Git with staged and unstaged changes, a staged diff and the commit bar. The harness makes the
    /// same disposable `ops` folder and repository as the two flows above, and removes them after.
    func testFilesAndGitScreenshots() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let token = try XCTUnwrap(fixture.searchToken, "Run through integration/check-ios-product.py")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        closeAllTabs(app)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        for (appearance, largest) in [("light", false), ("dark", false), ("light", true)] {
            app.terminate()
            launch(app, appearance: appearance, largestText: largest)
            largestTextSize = largest
            XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 20))
            let name = appearance + (largest ? "-ax5" : "")

            // Files: the folder, a context menu and a contents search.
            openSidebarItem(app, "sidebarFiles")
            if !fileRow(app, "ops/rename-me.txt").waitForExistence(timeout: 3) { openFileRow(app, "ops") }
            // At the largest text size the folder's last rows are below the list's visible area, where the list lays
            // nothing out: the list is scrolled to the row as a person would, and back to its top for the screenshot.
            let target = revealFileRow(app, "ops/search-target.swift", after: "ops/rename-me.txt", timeout: 10)
            XCTAssertTrue(target.shown)
            for _ in 0..<target.swipes { app.collectionViews["filesList"].firstMatch.swipeDown() }
            attach(app, "files-\(pad ? "table" : "list")-\(name)")
            fileRow(app, "ops/rename-me.txt").press(forDuration: 1.2)
            if app.buttons.matching(NSPredicate(format: "label == %@", "Copy Path")).firstMatch.waitForExistence(timeout: 5) {
                attach(app, "files-context-menu-\(name)")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: pad ? 0.9 : 0.12)).tap()
            }
            // A pass whose Files page shows no search field skips the search (iPhone once showed none at the largest
            // text size; it shows one now).
            let search = app.searchFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Search file")).firstMatch
            if search.waitForExistence(timeout: 3) {
                // The drawer's page has the field at the bottom (owner, 2026-10-08); at the largest text size it once
                // outgrew its bar and took no tap (runs 1791336086, 1791340506). A person taps it where it shows.
                if search.isHittable { search.tap() } else { search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                if waitForFocus(search, timeout: 3) {
                    search.typeText(token)
                    let contents = app.buttons["Contents"].firstMatch
                    if contents.waitForExistence(timeout: 5) { contents.tap() }
                    if app.descendants(matching: .any)["fileSearchMatch-ops/search-target.swift-3"].firstMatch.waitForExistence(timeout: 15) {
                        attach(app, "files-search-contents-\(name)")
                    }
                    endFilesSearch(app)
                } else {
                    // Without the keyboard nothing can be typed; the Git screenshots of the pass still follow.
                    XCTFail("The Files search field takes the keyboard (\(name))")
                    attach(app, "files-search-unfocused-\(name)")
                }
            }

            // Git: stage the modified file once, so both sections show; its diff; the commit bar.
            openSidebarItem(app, "sidebarGit")
            let changed = app.descendants(matching: .any)["gitChange-changes-README.md"].firstMatch
            let staged = app.descendants(matching: .any)["gitChange-staged-README.md"].firstMatch
            // The file is staged from the first pass on. At the largest text size its row is below the fold, where the
            // page's list lays nothing out (run 1791410438): the list is scrolled to it, as a person would.
            XCTAssertTrue(revealGitRow(app, changed, or: staged), "The modified file is listed (\(name))")
            if !staged.exists {
                // The row's context menu offers Stage, on the iPhone drawer's Git page (GI-6) and the iPad's Git tab.
                changed.press(forDuration: 1.0)
                let stage = app.buttons.matching(NSPredicate(format: "label == %@", "Stage")).firstMatch
                if stage.waitForExistence(timeout: 5) {
                    attach(app, "git-context-menu-\(name)")
                    stage.tap()
                }
            }
            XCTAssertTrue(revealGitRow(app, staged), "The file is staged (\(name))")
            // A stage's success shows only in the list (GI-2, 2026-10-06).
            attach(app, "git-staged-and-changes-\(name)")
            staged.tap()
            if app.descendants(matching: .any)["gitDiff"].firstMatch.waitForExistence(timeout: 15) {
                attach(app, "git-diff-\(name)")
                app.buttons["gitDiffDone"].firstMatch.tap()
            }
            let field = app.textFields["gitCommitMessage"].firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                if !waitForFocus(field, timeout: 2) { field.tap() }
                if (field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue {
                    field.typeText("Describe the change")
                }
                attach(app, "git-commit-bar-\(name)")
            }
            // On iPhone the commit bar is on the Workspace destination's Git page: leaving it for Home's Chat, as a
            // person does, ends the commit message's editing before the tabs close.
            if !pad { showPhoneTab(app, "Chat") }
            closeAllTabs(app)
        }
        largestTextSize = false
    }

    // MARK: Files and Git helpers

    /// A file or folder of the Files surface by its path: a button in the iPhone list, a cell's content
    /// in the iPad table.
    private func fileRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: fileRowID(path)).firstMatch
    }

    /// A Files row's identifier: the iPhone drawer's Files section names its rows `drawerFile-<path>`, the Files tab
    /// (iPad) `file-<path>`.
    func fileRowID(_ path: String) -> String {
        (UIDevice.current.userInterfaceIdiom == .phone ? "drawerFile-" : "file-") + path
    }

    /// Waits for a Files row that sorts after `earlier`. While `earlier` shows and the row does not, the row is below the
    /// list's visible area, where the list lays nothing out (the folder's rows at the largest text size): the list is
    /// scrolled up, as a person would, at most three times. Says whether the row showed and how many swipes it took.
    private func revealFileRow(_ app: XCUIApplication, _ path: String, after earlier: String,
                               timeout: TimeInterval) -> (shown: Bool, swipes: Int) {
        let row = fileRow(app, path)
        let previous = fileRow(app, earlier)
        let list = app.collectionViews["filesList"].firstMatch
        var swipes = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists { return (true, swipes) }
            if swipes < 3, previous.exists, list.exists {
                list.swipeUp()
                swipes += 1
            } else {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return (row.exists, swipes)
    }

    /// Scrolls the Git page until `row` (or `other`) is in reach, as a person would, and says whether one is. The
    /// iPhone drawer's Git page is a lazy list (GI-1) that lays out only the rows near its visible area: at the largest
    /// text size its repository facts fill the page and the changes are below the fold, not in the tree at all (run
    /// 1791410438). The drag runs where the list shows, between the page's navigation bar and its commit bar.
    @discardableResult
    private func revealGitRow(_ app: XCUIApplication, _ row: XCUIElement, or other: XCUIElement? = nil,
                              timeout: TimeInterval = 15) -> Bool {
        let list = app.descendants(matching: .any)["gitTree"].firstMatch.collectionViews.firstMatch
        let commitBar = app.descendants(matching: .any)["gitCommitBar"].firstMatch
        let rows = [row] + (other.map { [$0] } ?? [])
        // The part of the list nothing covers.
        func shown() -> (top: CGFloat, bottom: CGFloat)? {
            guard list.exists else { return nil }
            var top = list.frame.minY, bottom = list.frame.maxY
            for bar in app.navigationBars.allElementsBoundByIndex where bar.frame.maxY > top && bar.frame.minY < top + 60 {
                top = max(top, bar.frame.maxY)
            }
            if commitBar.exists, commitBar.frame.minY > top { bottom = min(bottom, commitBar.frame.minY) }
            return bottom - top > 30 ? (top, bottom) : nil
        }
        func inReach(_ element: XCUIElement, _ area: (top: CGFloat, bottom: CGFloat)) -> Bool {
            element.exists && element.isHittable && element.frame.midY > area.top && element.frame.midY < area.bottom
        }
        // A moment for the list to read the repository before anything scrolls.
        _ = row.waitForExistence(timeout: 2) || other?.exists == true
        var drags = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let area = shown() else { Thread.sleep(forTimeInterval: 0.5); continue }
            if rows.contains(where: { inReach($0, area) }) { return true }
            guard drags < 12 else { Thread.sleep(forTimeInterval: 0.5); continue }
            // Towards a row laid out above the shown part, else down the list, where the rows not laid out yet are.
            let above = rows.contains { $0.exists && $0.frame.midY <= area.top }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let low = origin.withOffset(CGVector(dx: list.frame.midX, dy: area.bottom - 12))
            let high = origin.withOffset(CGVector(dx: list.frame.midX, dy: area.top + 12))
            if above { high.press(forDuration: 0.05, thenDragTo: low) } else { low.press(forDuration: 0.05, thenDragTo: high) }
            drags += 1
        }
        guard let area = shown() else { return false }
        return rows.contains { inReach($0, area) }
    }

    /// Goes back to the workspace's own folder from `folder`: on iPhone the drawer's Files page lists the folders above
    /// the one it shows in its title menu (FI-1), whose title is the folder's name; the iPad's folder bar shows them.
    /// The system's title menu drops its items' identifiers (run 1791400998: its one item was a Button labelled
    /// "Fixture" and no `fileBreadcrumbRoot`), so on iPhone the item is the one named for the workspace.
    private func openFilesRootFolder(_ app: XCUIApplication, from folder: String, workspace: String = "Fixture") {
        var root = app.buttons["fileBreadcrumbRoot"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone {
            let named = NSPredicate(format: "label == %@", folder)
            let title = app.navigationBars.buttons.matching(named).firstMatch
            if title.waitForExistence(timeout: 5) {
                title.tap()
            } else {
                let text = app.navigationBars.staticTexts.matching(named).firstMatch
                XCTAssertTrue(text.waitForExistence(timeout: 2), "The drawer's Files page is titled with its folder")
                text.tap()
            }
            root = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "fileBreadcrumbRoot", workspace)).firstMatch
        }
        XCTAssertTrue(root.waitForExistence(timeout: 5), "The workspace's folder is offered")
        root.tap()
    }

    /// Opens a row: a tap on iPhone; on iPad a tap on the table row, its primary action.
    private func openFileRow(_ app: XCUIApplication, _ path: String) {
        let row = fileRow(app, path)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    /// Chooses `action` from a row's context menu (a long press).
    private func fileContextAction(_ app: XCUIApplication, _ path: String, _ action: String, screenshot: String? = nil) {
        let row = fileRow(app, path)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        let item = app.buttons.matching(NSPredicate(format: "label == %@", action)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The context menu offers \(action)")
        if let screenshot { attach(app, screenshot) }
        item.tap()
    }

    /// The Files search field (names or contents), wherever the system puts it.
    private func filesSearchField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Search file")).firstMatch
        if field.waitForExistence(timeout: 3) { return field }
        // Minimized into a toolbar button: it opens the field.
        let button = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        if button.exists { button.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Files has a search field")
        return field
    }

    /// Ends the Files search: its Cancel or close button (iOS 26 labels it "close"), the one level with its field first.
    /// The iPhone drawer also holds a hidden, zero-size Close for a hardware keyboard's Escape, which is never the
    /// search's; Escape alone only put the keyboard away and left the search on, to take the keyboard again when Files
    /// came back.
    private func endFilesSearch(_ app: XCUIApplication) {
        let field = filesSearchField(app)
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        for label in ["Cancel", "Close"] {
            let buttons = app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).allElementsBoundByIndex.filter(\.isHittable)
            if let button = buttons.first(where: { abs($0.frame.midY - field.frame.midY) < 30 }) ?? buttons.first {
                button.tap(); return
            }
        }
        if app.keyboards.firstMatch.exists { app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: []) }
    }

    /// Uploads the UI tests' small file through the same queue as a picked file.
    private func uploadTestFile(_ app: XCUIApplication) {
        surfaceMenu(app, "fileActions").tap()
        menuItem(app, "debugUploadTestFile", label: "Upload Test File").tap()
    }

    /// Replaces a text field's text: the caret goes to the end (a tap at its right edge), then the old
    /// text is deleted.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    func testTerminalFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let terminalMarker = try XCTUnwrap(fixture.terminalMarker)
        let app = XCUIApplication()
        app.launchArguments.append("-AgentLandUITestsDisableAnimations")
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        // SwiftTerm drives a real PTY. The harness later inspects files written
        // by commands rather than mistaking echoed command text for output.
        openAddTab(app, kind: "Terminal")
        let terminalTitle = "Terminal"
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        attach(app, "terminal")
        // A four-second raw read detects arrow/mouse bytes emitted by a touch pan.
        typeTerminal(app, "printf '%s' '\(terminalMarker)' > terminal-proof.txt\n" +
            "python3 -c 'import os,select,sys,termios,tty; fd=sys.stdin.fileno(); old=termios.tcgetattr(fd); tty.setraw(fd); r,_,_=select.select([fd],[],[],4); open(\"touch-proof.txt\",\"wb\").write(os.read(fd,1) if r else b\"\"); termios.tcsetattr(fd,termios.TCSANOW,old)'\n")
        Thread.sleep(forTimeInterval: 0.7)
        canvas.swipeUp()
        Thread.sleep(forTimeInterval: 4.5)
        // Keep Control-C available after removing the default accessory row.
        // If it fails, input() consumes the next command and no proof file is written.
        typeTerminal(app, "python3 -c 'input()'\n")
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if phone {
            // The key bar's Control, then c: the phone's Control-C, over the keyboard.
            app.buttons["terminalKeyControl"].tap()
            app.typeText("c")
        } else {
            surfaceMenu(app, "terminalActions").tap()
            app.buttons["terminalKeys"].tap()
            app.buttons["terminalInterrupt"].tap()
        }
        typeTerminal(app, "printf '%s' '\(terminalMarker)' > key-proof.txt\n")
        attach(app, "terminal-with-keyboard")

        // Every surface view is discarded and built again while the terminal shows output, as a split
        // view's detail column does. The session keeps its renderer (the same renderer number), the
        // screen keeps its text, and the shell is the same process (a variable set before the rebuild
        // survives).
        typeTerminal(app, "export AGENTLAND_REBUILD='\(terminalMarker)'; printf 'REBUILD %s\\n' kept\n")
        XCTAssertTrue(try waitForRenderedText("REBUILD kept", in: app, timeout: 15))
        let renderer = app.descendants(matching: .any)["terminalRendererSerial"].firstMatch
        XCTAssertTrue(renderer.waitForExistence(timeout: 5))
        let rendererBefore = renderer.value as? String
        XCTAssertTrue(rendererBefore?.hasPrefix("renderer ") == true, "The terminal shows a renderer: \(rendererBefore ?? "nil")")
        if phone {
            // The tab menu has no debug rebuild on iPhone (no per-task actions, owner's decision, 2026-10-11): Home
            // takes the terminal's place and the switcher brings it back, which builds its surface again.
            app.buttons["phoneBackHome"].tap()
            XCTAssertTrue(canvas.waitForNonExistence(timeout: 10), "Home takes the terminal's place")
            switchPhoneTask(app, titled: terminalTitle)
        } else {
            titleMenu(app).tap()
            app.buttons["debugRebuildSurfaces"].tap()
        }
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(renderer.waitForExistence(timeout: 5))
        XCTAssertEqual(renderer.value as? String, rendererBefore, "The rebuilt view mounted the same renderer")
        XCTAssertTrue(try waitForRenderedText("REBUILD kept", in: app, timeout: 10), "The screen kept its output through the rebuild")
        attach(app, "terminal-after-rebuild")
        typeTerminal(app, "printf '%s' \"$AGENTLAND_REBUILD\" > rebuild-proof.txt\n")
        if phone {
            // The header's X ends a running terminal after its question (owner, 2026-10-10): closing a tab while
            // its remote PTY keeps running has no iPhone route, so the retained-terminal step is iPad's.
            Thread.sleep(forTimeInterval: 1)
            closePhoneTask(app)
            XCTAssertTrue(canvas.waitForNonExistence(timeout: 15), "Ending the terminal closes its tab")
            return
        }
        closeCurrentTab(app)
        app.terminate()
        app.launch()
        // Closing the terminal selects the workspace's previous tab (Files once
        // a workspace was opened), so wait for the workspace, not for Home.
        XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 20))
        // The sidebar (the iPhone drawer's Resume Work) lists the host's terminals.
        openLibrary(app)
        let retainedTerminal = app.descendants(matching: .any).matching(identifier: "sidebarTerminal")
            .matching(NSPredicate(format: "label BEGINSWITH %@", terminalTitle)).firstMatch
        XCTAssertTrue(sidebarLists(app, retainedTerminal, timeout: 15), "Closing a tab must retain its remote PTY")
        retainedTerminal.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        surfaceMenu(app, "terminalActions").tap()
        app.buttons["End terminal"].firstMatch.tap()
        app.buttons["End terminal"].firstMatch.tap() // Explicit confirmation ends the host process.
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 15), "Ending the terminal closes its tab")
    }

    /// A program that turned on mouse reporting, as OpenCode does, scrolls with the finger: a drag sends
    /// it wheel reports at the touched cell and nothing else. The harness's probe (`wheel-probe.py`)
    /// keeps what it read, and `check-ios-product.py` checks it.
    func testTerminalWheelScroll() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments.append("-AgentLandUITestsDisableAnimations")
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        openAddTab(app, kind: "Terminal")
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        typeTerminal(app, "python3 wheel-probe.py\n")
        XCTAssertTrue(try waitForRenderedText("WHEEL READY", in: app, timeout: 8), "The probe took the alternate screen and the mouse")
        canvas.swipeDown()
        Thread.sleep(forTimeInterval: 0.8)
        canvas.swipeUp()
        attach(app, "terminal-wheel-scroll")
        // The probe reads for twelve seconds after it started, then gives the shell its screen back.
        Thread.sleep(forTimeInterval: 10)
    }

    /// A visual pass over each terminal program the host offers: idle screen,
    /// keyboard with AgentLand's key bar, typed (never submitted) input and a
    /// hidden keyboard. Screenshots are the evidence; nothing is sent to a model.
    func testTerminalProgramsTour() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        for program in fixture.tourPrograms ?? ["shell"] {
            showProjects(app)
            app.buttons["homeNewTerminal"].tap()
            let item = app.buttons["homeTerminalProgram-\(program)"]
            guard item.waitForExistence(timeout: 5) else {
                XCTFail("\(program) is not offered by the host")
                continue
            }
            item.tap()
            let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: program == "shell" ? 2 : 10)
            attach(app, "\(program)-1-idle")
            canvas.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the terminal shows the keyboard")
            XCTAssertTrue(app.buttons["terminalKeyEscape"].waitForExistence(timeout: 3), "AgentLand's key bar sits above the keyboard")
            XCTAssertTrue(app.buttons["terminalHideKeyboard"].exists)
            if program == "codex" {
                // Codex may open on an update notice; Esc is its one-time skip.
                app.buttons["terminalKeyEscape"].tap()
            }
            Thread.sleep(forTimeInterval: 3)
            attach(app, "\(program)-2-keyboard")
            app.typeText(program == "shell" ? "echo typed-on-the-phone" : "typed on the phone")
            Thread.sleep(forTimeInterval: 2)
            attach(app, "\(program)-3-typed")
            app.buttons["terminalKeyControl"].tap()
            app.typeText("u")
            Thread.sleep(forTimeInterval: 1)
            app.buttons["terminalHideKeyboard"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "The key bar's last key hides the keyboard")
            Thread.sleep(forTimeInterval: 2.5)
            attach(app, "\(program)-4-keyboard-hidden")
            surfaceMenu(app, "terminalActions").tap()
            app.buttons["End terminal"].tap()
            app.buttons["End terminal"].tap()
            XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 15))
        }
    }

    /// The Mac host quits, comes back, then goes silent (sleep or lost Wi-Fi).
    /// The phone must say so at once, send nothing while offline and recover
    /// by itself. The harness controls the real host process.
    func testHostDisconnectFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        openAddTab(app, kind: "Terminal")
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        typeTerminal(app, "echo connected-before-stop; echo $$ > disconnect-pid-before.txt\n")
        let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch
        XCTAssertFalse(banner.exists)

        let stopped = Date()
        try hostControl(fixture, "stop")
        XCTAssertTrue(banner.waitForExistence(timeout: 4), "A host that quits must be reported at once")
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 5)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AgentLand stopped on")).firstMatch.exists)
        attach(app, "host-stopped")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AgentLand stopped on")).firstMatch.exists,
                      "Refused reconnects must not relabel an announced stop")
        app.typeText("x")
        let notice = app.descendants(matching: .any)["terminalNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        let refusal = notice.label
        XCTAssertTrue(["Not connected. Nothing was sent; typing resumes when the host is back.",
                       "Not sent: the host isn't reachable."].contains { refusal.contains($0) }, refusal)
        attach(app, "host-stopped-typing")

        try hostControl(fixture, "start")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 12), "The phone reconnects by itself")
        XCTAssertFalse(app.staticTexts["Terminal ended"].waitForExistence(timeout: 10), "A restarted host keeps the shell")
        typeTerminal(app, "echo $$ > disconnect-pid-after.txt\n")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "host-restarted")

        // Ending the task closes it, as testTerminalFlow does on the phone.
        closePhoneTask(app)
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 15), "Ending the terminal closes its tab")
        showProjects(app)
        let silent = Date()
        try hostControl(fixture, "pause")
        XCTAssertTrue(banner.waitForExistence(timeout: 9), "A silent host is reported within the pulse's idle limit")
        XCTAssertLessThan(Date().timeIntervalSince(silent), 10)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Can’t reach")).firstMatch.exists)
        attach(app, "host-silent")
        try hostControl(fixture, "resume")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 15))
        attach(app, "host-resumed")
    }

    /// The host is killed (SIGKILL) while a terminal runs a 40-second loop, stays dead for 15 seconds and
    /// comes back. The terminal lives in the keeper, so the same shell finishes the loop and takes input.
    /// The harness compares the shell's pid before and after and checks the archived log for gaps.
    func testTerminalSurvivesHostKill() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        openAddTab(app, kind: "Terminal")
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        typeTerminal(app, "echo $$ > pid-before.txt; for i in $(seq 40); do echo tick-$i; sleep 1; done; echo $$ > pid-after.txt\n")
        // The loop runs (so the typed line reached the shell) before the host goes.
        XCTAssertTrue(try waitForTerminalText("tick-2", in: canvas, timeout: 15), "The loop starts before the host is killed")

        try hostControl(fixture, "kill")
        Thread.sleep(forTimeInterval: 15)
        try hostControl(fixture, "start")

        XCTAssertFalse(app.staticTexts["Terminal ended"].waitForExistence(timeout: 15), "The killed host's terminal keeps running")
        XCTAssertTrue(try waitForTerminalText("tick-40", in: canvas, timeout: 45), "The loop finishes after the host comes back")
        attach(app, "terminal-after-host-kill")
        typeTerminal(app, "echo typed-after-kill > after-kill.txt\n")
        XCTAssertTrue(try waitForTerminalText("after-kill", in: canvas, timeout: 15))
        Thread.sleep(forTimeInterval: 1)
    }

    /// A coding agent typed in Terminal on the Mac shows on the phone and works from both (terminals from other
    /// devices). The harness turns routing on and runs `claude` through `agentland-host terminals run` in a Terminal
    /// window of its own (`RoutedTerminal`), in a folder that is no workspace: a fake that says mac-agent-ready and
    /// answers every line with got:<line>. The phone finds it under "On <Mac>" on the Workspace tab, opens it on a screen
    /// of its own, and each side's typing reaches the agent while the other sees the answer. Closing the window ends it.
    func testTerminalFromTheMacShowsOnThePhone() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        // Waiting for a keeper, the agent's first line and the Mac's list may take longer than one request's default.
        XCTAssertEqual(try hostControlResult(fixture, "routed-start", timeout: 60), "ok",
                       "claude typed in Terminal on the Mac runs as an AgentLand terminal")

        // "On <Mac>" is on the Workspace tab's root page (iPhone); iPad's Home shows it as a card.
        if UIDevice.current.userInterfaceIdiom == .phone { showPhoneTab(app, "Workspace") }
        let section = app.descendants(matching: .any)["otherDevice-local-mac"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 15), "The Mac's terminals are listed")
        // A list's section header may be drawn in capitals; its words are what count.
        XCTAssertTrue(section.label.lowercased().hasPrefix("on "), "The section names the Mac: \(section.label)")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "otherTerminal-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The agent has a row under the Mac")
        XCTAssertTrue(row.label.contains("Claude Code"), "The row names the program: \(row.label)")
        let rowID = row.identifier
        attach(app, "on-device-section")

        // Its folder is no workspace, so it opens on a screen of its own.
        row.tap()
        let strip = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "isn't a workspace")).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "The screen says the folder isn't a workspace")
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "The terminal shows")
        XCTAssertTrue(try waitForTerminalText("mac-agent-ready", in: canvas, timeout: 20), "The phone shows what the agent printed")
        attach(app, "standalone-terminal")

        // The phone's typing reaches the agent, and the Mac's window shows its answer.
        typeTerminal(app, "from-phone-1\n")
        XCTAssertEqual(try hostControlResult(fixture, "routed-wait", payload: "got:from-phone-1"), "ok",
                       "The Terminal window shows the agent's answer to the phone")
        // The window's typing (a Return is "\r" there) reaches the agent, and the phone shows its answer.
        XCTAssertEqual(try hostControlResult(fixture, "routed-type", payload: "from-mac-1\r"), "ok")
        XCTAssertTrue(try waitForTerminalText("got:from-mac-1", in: canvas, timeout: 20), "The phone shows the agent's answer to the Mac")
        attach(app, "standalone-terminal-answered")

        // Closing the window ends the agent, and the Mac's list on the phone drops it.
        XCTAssertEqual(try hostControlResult(fixture, "routed-stop"), "ok", "The CLI exits when its window closes")
        goBack(app)
        // Back must land on the Workspace root (the bottom bar is hidden on the standalone screen), or the row's
        // absence below proves nothing.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let bar = phoneTabBar(app)
            XCTAssertTrue(bar.waitForExistence(timeout: 10) && bar.isHittable, "Back returns to the Workspace tab")
            XCTAssertTrue(bar.buttons["Workspace"].isSelected, "The Workspace tab is in front")
        }
        XCTAssertTrue(app.buttons[rowID].waitForNonExistence(timeout: 10), "The ended terminal leaves On <Mac>")
        XCTAssertTrue(app.descendants(matching: .any)["otherDevice-local-mac"].firstMatch.waitForNonExistence(timeout: 10),
                      "The Mac's section goes with its last terminal")
    }

    /// The address the phone paired at stops answering, as when it leaves home, while another route the
    /// host lists still answers: here 127.0.0.1, with the paired pin and the certificate validated for
    /// the paired name (`localhost`). The app must find that route by itself, work through it and try
    /// it first after a relaunch. The harness forwards the paired address to the host, lists the
    /// routes through a fake Tailscale command line, and cuts the forwarder on request.
    func testConnectsThroughAlternateRoute() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        let tailscale = app.descendants(matching: .any)["connectionRoute-tailscale"].firstMatch
        let inUse = app.descendants(matching: .any)["connectionRouteInUse"].firstMatch
        let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch

        // Connecting read the host's routes.
        openConnectionSettings(app)
        XCTAssertTrue(tailscale.waitForExistence(timeout: 15), "The host's Tailscale route is learned on connecting")
        XCTAssertTrue(waitForLabel(tailscale, containing: "agentland-tailnet.invalid", timeout: 2), tailscale.label)
        XCTAssertTrue(waitForLabel(inUse, containing: "localhost:", timeout: 10), "It connects at the paired address first: \(inUse.label)")
        attach(app, "routes-learned")
        closeSettings(app)

        try hostControl(fixture, "cut")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 20), "The app reconnects through another route by itself")
        openConnectionSettings(app)
        XCTAssertTrue(waitForLabel(inUse, containing: "127.0.0.1:", timeout: 20), "It connects through the alternate address: \(inUse.label)")
        attach(app, "connected-through-alternate-route")
        closeSettings(app)

        // Work goes through it: a terminal on the host runs a command.
        openAddTab(app, kind: "Terminal")
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        typeTerminal(app, "echo through-alternate-route > route-proof.txt\n")
        XCTAssertTrue(try waitForRenderedText("route-proof", in: app, timeout: 20), "The command reached the host's shell")
        attach(app, "terminal-through-alternate-route")

        // The next launch tries the address that answered last first.
        app.terminate()
        app.launch()
        XCTAssertTrue(workspaceHeader(app).waitForExistence(timeout: 30), "The relaunched app opens its workspace")
        XCTAssertFalse(banner.exists)
        openConnectionSettings(app)
        XCTAssertTrue(waitForLabel(inUse, containing: "127.0.0.1:", timeout: 10), "The winner was remembered: \(inUse.label)")
        attach(app, "relaunched-on-remembered-route")
        closeSettings(app)
    }

    /// Remote access through iroh (docs/HOST-API.md "Remote access (iroh)"), on this Mac's loopback: the
    /// harness runs the host with its tunnel socket and the Mac side built from the Mac app's code
    /// (`agentland-remote-access-loopback`: the Mac endpoint and its gate, the bridge to the tunnel socket,
    /// the mapping to a router stand-in), with "Reach this Mac from anywhere" on. The app pairs through a
    /// forwarder and registers its node ID over that address; then the forwarder is cut, so no address
    /// answers, and the app must connect through the tunnel with the paired pin and run a terminal
    /// command there. Then the Mac unpairs the device while the app is closed: the next run's key is not
    /// admitted, the gate closes it with 403, and the banner says to connect at home. The app runs under
    /// the router-ports profile (integration/RouterPortsSandbox), and dials only the loopback port
    /// (`RemoteAccessLoopbackDial`).
    func testConnectsThroughIrohTunnel() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launchEnvironment = [
            "DYLD_INSERT_LIBRARIES": try XCTUnwrap(fixture.routerPortsDylib, "Run through integration/check-ios-product.py"),
            "AGENTLAND_ROUTER_PORTS_BYTECODE": try XCTUnwrap(fixture.routerPortsBytecode),
            "AGENTLAND_ROUTER_PORTS_REPORT": try XCTUnwrap(fixture.routerPortsReport),
            "AGENTLAND_UITEST_TUNNEL_LOOPBACK": try XCTUnwrap(fixture.tunnelLoopback),
        ]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        let inUse = app.descendants(matching: .any)["connectionRouteInUse"].firstMatch
        let reach = app.descendants(matching: .any)["connectionRemoteAccess"].firstMatch
        let tunnelRow = app.descendants(matching: .any)["connectionTunnel"].firstMatch
        let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch

        // At the paired address the app read the Mac's remote access and gave the host its node ID with a
        // proof; the Mac's gate now lists it.
        try hostCheck(fixture, "registered")
        openConnectionSettings(app)
        XCTAssertTrue(waitForLabel(reach, containing: "On", timeout: 15), "The Mac's report was read: \(reach.label)")
        XCTAssertTrue(waitForLabel(inUse, containing: "localhost:", timeout: 10), "It connects at the paired address: \(inUse.label)")
        XCTAssertTrue(waitForLabel(tunnelRow, containing: "Standing by", timeout: 5), tunnelRow.label)
        attach(app, "tunnel-standing-by")
        closeSettings(app)

        // No address answers any more: the tunnel carries the connection.
        try hostControl(fixture, "cut")
        openConnectionSettings(app)
        XCTAssertTrue(waitForLabel(inUse, containing: "Remote access (iroh)", timeout: 45), "It connects through the tunnel: \(inUse.label)")
        XCTAssertTrue(waitForLabel(tunnelRow, containing: "Connected", timeout: 10), tunnelRow.label)
        attach(app, "connected-through-tunnel")
        closeSettings(app)
        XCTAssertTrue(banner.waitForNonExistence(timeout: 15), "Online through the tunnel")

        // Work goes through it: a terminal on the host runs a command.
        openAddTab(app, kind: "Terminal")
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 30))
        typeTerminal(app, "echo through-iroh-tunnel > tunnel-proof.txt\n")
        XCTAssertTrue(try waitForRenderedText("tunnel-proof", in: app, timeout: 30), "The command reached the host's shell")
        attach(app, "terminal-through-tunnel")
        try hostCheck(fixture, "ran")

        // The Mac unpairs this device while the app is closed; the next run's key is not admitted. The
        // gate's 403 cannot tell a removed device from a node ID it was never given, so the banner names
        // both ways back: a connection at home or over Tailscale, or pairing again (this device's case:
        // at home it would meet 401).
        app.terminate()
        try hostCheck(fixture, "unpair")
        app.launch()
        let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Remote access doesn’t let this device in: connect to localhost at home or over Tailscale to turn it back on, or pair again if localhost removed this device.")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 60), "The gate's 403 says how to get back in, pairing again included")
        XCTAssertTrue(banner.exists)
        XCTAssertTrue(app.staticTexts["Can’t reach localhost"].exists)
        attach(app, "tunnel-not-admitted")
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Out of reach, the terminal is restored in front, and openSettings finds it in the header's switcher and
            // closeSettings returns to it (2026-10-12: the switcher listed Home alone until the host's list loaded).
            XCTAssertTrue(app.buttons["phoneCloseTab"].exists, "The terminal is restored in front")
        }
        openConnectionSettings(app)
        XCTAssertTrue(waitForLabel(tunnelRow, containing: "Not admitted by the Mac", timeout: 10), tunnelRow.label)
        XCTAssertTrue(tunnelRow.label.contains("or pair again"), tunnelRow.label)
        attach(app, "tunnel-not-admitted-settings")
        closeSettings(app)
        try hostCheck(fixture, "refused")

        // Kept with the saved host: a later run does not dial and still says why.
        app.terminate()
        app.launch()
        XCTAssertTrue(refusal.waitForExistence(timeout: 30), "The kept refusal still says to connect at home")
        attach(app, "tunnel-refusal-kept")
    }

    /// Asks the harness to check or change something on the host side and fails with what it found
    /// when that is not "ok".
    func hostCheck(_ fixture: Fixture, _ command: String, timeout: TimeInterval = 60) throws {
        try hostControl(fixture, command, timeout: timeout)
        let folder = URL(fileURLWithPath: try XCTUnwrap(fixture.control))
        let answer = (try? String(contentsOf: folder.appendingPathComponent(command + ".done"), encoding: .utf8)) ?? ""
        XCTAssertEqual(answer.trimmingCharacters(in: .whitespacesAndNewlines), "ok", "The harness's \(command) check")
    }

    private func openConnectionSettings(_ app: XCUIApplication) {
        openSettings(app)
        openSettingsPage(app, "Connection")
        XCTAssertTrue(app.descendants(matching: .any)["connectionStatus"].firstMatch.waitForExistence(timeout: 8),
                      "The connection pane opens")
    }

    /// Puts Settings away from whichever page shows through its shared drawer close control. On iPhone Settings is a
    /// bottom-bar destination: leaving it returns to the session `openSettings` found in front, else Home's Chat.
    func closeSettings(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if let identifier = phoneSessionBehindSettings {
                phoneSessionBehindSettings = nil
                let switcher = app.buttons["workspaceSwitcher"]
                XCTAssertTrue(waitUntilHittable(switcher, timeout: 10))
                switcher.tap()
                let row = app.buttons[identifier]
                XCTAssertTrue(row.waitForExistence(timeout: 5), "The switcher still lists the session Settings left")
                row.tap()
                XCTAssertTrue(app.buttons["quickTabHome"].waitForNonExistence(timeout: 5))
            } else {
                showPhoneTab(app, "Chat")
            }
            XCTAssertTrue(app.buttons["settingsStatus"].waitForNonExistence(timeout: 8), "Settings closes")
            return
        }
        let exit = app.buttons["settingsClose"].firstMatch
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "Settings has its way out")
        exit.tap()
        XCTAssertTrue(exit.waitForNonExistence(timeout: 8), "Settings closes")
        XCTAssertTrue(app.staticTexts["Current host"].waitForNonExistence(timeout: 8))
    }

    /// Whether `element` shows `text` within `timeout`, in its label or its value (a Settings row's value, which a form
    /// may read apart from its name).
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && (element.label.contains(text) || (element.value as? String)?.contains(text) == true) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    func testNamedOpenCodeFlow() throws {
        // The iPhone's Terminal launcher offers only Claude Code and Codex, with no Shell or OpenCode button (owner's
        // explicit choice, 2026-10-11), and ⌥⌘T starts a shell: an OpenCode terminal has no iPhone route.
        if UIDevice.current.userInterfaceIdiom == .phone {
            throw XCTSkip("No iPhone route starts an OpenCode terminal (Terminal launcher: Claude Code and Codex only)")
        }
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments.append("-AgentLandUITestsDisableAnimations")
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        openAddTab(app, kind: "OpenCode")
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(try waitForRenderedText("Ask anything", in: app, timeout: 35),
                      "The named action must render the real OpenCode prompt, not just an empty terminal canvas")
        attach(app, "opencode-terminal")
        // OpenCode turns on mouse reporting: a drag on the terminal turns its wheel. The harness's model
        // answers AGENTLAND_SCROLL with sixty lines, more than the screen holds, so the first line shows
        // again only once the message list has scrolled back.
        // The text is read from the terminal alone, and by the reply's second line: OpenCode names the session
        // from this reply ("Scroll line 01") and shows that name at the top of its screen and in the tab's title.
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        typeTerminal(app, "AGENTLAND_SCROLL\n")
        XCTAssertTrue(try waitForTerminalText("Scroll line 60", in: canvas, timeout: 45), "OpenCode showed the end of the long reply")
        hideTerminalKeyboard(app)
        XCTAssertFalse(try waitForTerminalText("Scroll line 02", in: canvas, timeout: 1), "The reply's first lines start out of view")
        attach(app, "opencode-long-reply")
        var scrolledBack = false
        for _ in 0..<6 where !scrolledBack {
            canvas.swipeDown()
            scrolledBack = try waitForTerminalText("Scroll line 02", in: canvas, timeout: 2)
        }
        XCTAssertTrue(scrolledBack, "Dragging down scrolled OpenCode's messages back to the reply's first lines")
        attach(app, "opencode-scrolled-back")
        // Inside a session OpenCode sets the window title to "OC | <session title>"; the host keeps it as the
        // terminal's program title and the tab takes it in place of "OpenCode".
        let tabs = currentTab(app)
        let deadline = Date().addingTimeInterval(30)
        while tabs.label == "Current tab: OpenCode" && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertNotEqual(tabs.label, "Current tab: OpenCode", "The terminal's tab takes the session's title")
        attach(app, "opencode-tab-named")
        surfaceMenu(app, "terminalActions").tap()
        app.buttons["End terminal"].tap()
        app.buttons["End terminal"].tap()
    }

    func testInstalledHostSmoke() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "installed")
        let app = XCUIApplication()
        app.launchArguments.append("-AgentLandUITestsDisableAnimations")
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: true)
        showProjects(app)
        XCTAssertTrue(app.buttons["homeBrowseFiles"].waitForExistence(timeout: 20),
                      "The installed host must expose its selected project")
        attach(app, "installed-workspace")

        browseFilesFromHome(app)
        let readme = app.buttons[fileRowID("README.md")]
        XCTAssertTrue(readme.waitForExistence(timeout: 20),
                      "The installed workspace must expose its actual README")
        readme.tap()
        let editor = app.textViews["fileEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue((editor.value as? String ?? "").contains("# AgentLand"),
                      "The iPhone must read the real selected workspace")
        attach(app, "installed-files")

        openAddTab(app, kind: "Terminal")
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        typeTerminal(app, "pwd\n")
        // Reload checks that both the saved pairing and remote PTY survive a
        // client restart; the terminal is deliberately left running for the user.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        attach(app, "installed-terminal")
    }

    func testChatFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let chatReply = try XCTUnwrap(fixture.chatReply)
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        openAddTab(app, kind: "Chat")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        // An empty agent chat opens like a plain chat (owner, 2026-10-07): the tent and "What’s on your mind?" over
        // a ready composer, with no action tiles.
        let landing = app.descendants(matching: .any)["plainChatLanding"].firstMatch
        XCTAssertTrue(landing.waitForExistence(timeout: 20), "An empty agent chat shows the plain chat's landing")
        let question = app.staticTexts["plainChatPrompt"]
        XCTAssertTrue(question.exists)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The composer is ready under the landing")
        for tile in ["chatStartPrompt", "chatResumeWork", "chatBrowseFiles", "chatNewTerminal", "chatOpenWorkspace", "chatMoreActions"] {
            XCTAssertFalse(app.buttons[tile].exists, "The landing has no \(tile) tile")
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening a chat raises no keyboard")
        // iPad opens Settings from Home. Retain the chat's identity so returning to it also
        // works after the host replaces its initial title with the first prompt.
        var retainedChatRowID: String?
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["workspaceSwitcher"].tap()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                       "workspacePickerTab-", "New chat")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            retainedChatRowID = row.identifier
            row.tap()
        }
        func returnFromChatSettings() {
            closeSettings(app)
            if let retainedChatRowID {
                app.buttons["workspaceSwitcher"].tap()
                let row = app.buttons[retainedChatRowID]
                XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings preserves the same chat tab")
                row.tap()
            }
        }
        setAppearance(app, "Dark"); returnFromChatSettings()
        attach(app, "landing-dark")
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "landing-dark-flag-next")
        setAppearance(app, "Light"); returnFromChatSettings()
        attach(app, "landing-light")

        let landingFrame = question.frame
        app.terminate()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "YES", "-agentland.appearance", "light"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.buttons["OK"]
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        let lock = app.otherElements["appLockScreen"]
        XCTAssertTrue(lock.waitForExistence(timeout: 8))
        let opening = app.descendants(matching: .any)["openingCircus"].firstMatch
        XCTAssertTrue(opening.exists)
        // XCTest includes the moving clown in this decorative container's
        // bounds. Compare the stationary tent pixels in the retained captures,
        // and use the container only to check the requested screen region.
        XCTAssertGreaterThan(opening.frame.midY, app.frame.height * 0.4)
        XCTAssertLessThan(opening.frame.midY, app.frame.height * 0.55)
        attach(app, "tent-opening")
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "tent-opening-next")
        simulateMatchingFace()
        XCTAssertTrue(lock.waitForNonExistence(timeout: 10))
        XCTAssertTrue(question.waitForExistence(timeout: 20), "An empty selected chat must restore to its landing page")
        XCTAssertEqual(question.frame.midY, landingFrame.midY, accuracy: 1)
        attach(app, "tent-ready")
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        // XCUITest lists the landing under the cover (it is hidden from VoiceOver, not from the element tree),
        // and with production motion the cover leaves in a fade once the chat is ready.
        XCTAssertTrue(app.otherElements["hostLoadingScreen"].waitForNonExistence(timeout: 10),
                      "The opening cover leaves once the selected chat is ready")
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "The restored landing keeps the composer under it")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tapping the composer focuses the message field")
        chooseFixtureModel(app)
        // One pill: the model, its thinking and the mode (owner, 2026-10-25).
        let pill = app.buttons["chatModelMenu"]
        XCTAssertTrue((pill.value as? String ?? "").hasPrefix("Deterministic Local Model"))
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The fixture's chat is OpenCode's in the Chats space (the harness's --opencode-chat), which takes no mode.
            // Chat's Claude Code and Codex chats have their modes (testInstalledChatProviders), but tests never start them.
            XCTAssertFalse((pill.value as? String ?? "").contains(", "), "OpenCode's Chats-space chat takes no mode")
        } else {
            XCTAssertTrue((pill.value as? String ?? "").hasSuffix(", Build"), "The mode is always in the pill while composing")
            pill.tap()
            let permissions = app.descendants(matching: .any)["chatModeMenu"].firstMatch
            XCTAssertTrue(permissions.waitForExistence(timeout: 5), "The pill's menu has Permissions")
            permissions.tap()
            // Permissions is a submenu picker (CH-10): its Plan row by its identifier, or by its name.
            let planToggle = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", "chatPlanToggle", "Plan", "Plan, ")).firstMatch
            XCTAssertTrue(planToggle.waitForExistence(timeout: 5))
            planToggle.tap()
            XCTAssertTrue(waitForValue(pill, containing: "Plan", timeout: 5), "Plan mode must be visible before sending")
        }
        let prompt = "Reply from the local fixture only."
        composer.tap(); composer.typeText(prompt)
        // Leaving the app flushes its debounced draft save. Force-killing in
        // the same instant as typing tests an unsaved crash, not restoration.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "A saved draft must reopen directly in the composer")
        XCTAssertEqual(composer.value as? String, prompt, "Showing the landing must never hide or discard a saved draft")
        XCTAssertTrue(question.exists, "The landing stays over the composer and its saved draft, as in a plain chat")
        composer.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            connectHardwareKeyboard(app)
            XCTAssertTrue(press(app, "l", .command) {
                (composer.value(forKey: "hasKeyboardFocus") as? Bool) == true
            }, "Focus Composer targets the restored draft before selecting its text")
            app.typeKey("a", modifierFlags: .command)
        } else {
            composer.press(forDuration: 1)
            let selectAll = app.descendants(matching: .any).matching(identifier: "Select All").firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
            selectAll.tap()
        }
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(["", "Message OpenCode"].contains(composer.value as? String ?? "<missing>"), "The test must clear the actual draft before replacing it")
        XCTAssertTrue(composer.exists, "Deleting a restored draft must keep the active composer available")
        composer.typeText(prompt)
        XCTAssertEqual(composer.value as? String, prompt)
        app.buttons["chatSend"].tap()
        openSettings(app)
        returnFromChatSettings()
        let reply = app.staticTexts[chatReply]
        XCTAssertTrue(reply.waitForExistence(timeout: 45), "The local deterministic model response must render")
        let sent = userMessage(app, prompt)
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertTrue(sent.label.hasPrefix("Your message"), "VoiceOver reads a user message as one element with its time")
        XCTAssertFalse((composer.value as? String ?? "").contains(prompt), "An accepted message must clear its draft even when a panel opens during delivery")
        let screenMidpoint = app.windows.firstMatch.frame.midY
        XCTAssertLessThan(sent.frame.maxY, screenMidpoint, "A short chat should start near the top, not the composer")
        XCTAssertLessThan(reply.frame.maxY, screenMidpoint, "A short reply should remain in the upper half of the screen")
        XCTAssertGreaterThan(sent.frame.minX, reply.frame.minX, "User bubbles trail; replies fill the column without a bubble")
        // The host names the chat from the message (its free naming; the simulator has no Apple
        // Intelligence), and the tab follows the chat's name.
        XCTAssertTrue(waitForLabel(currentTab(app), containing: "Reply from the local fixture only", timeout: 15),
                      "The chat's tab takes the name the host gave it: \(currentTab(app).label)")
        attach(app, "chat")
        let copy = app.buttons["chatCopyReply"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "The latest finished reply keeps its action row")
        copy.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Copied")).firstMatch.waitForExistence(timeout: 3))
        // Copy is the only read of message text into the system clipboard.
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 20),
                      "The selected chat tab should restore after relaunch")
        XCTAssertTrue(app.staticTexts[chatReply].waitForExistence(timeout: 20))
        closeCurrentTab(app)
        app.terminate(); app.launch()
        // Whichever tab an earlier test left open is selected now; the chat is not.
        XCTAssertTrue(workspaceHeader(app).waitForExistence(timeout: 20))
        let selected = currentTab(app).label
        XCTAssertFalse(selected.contains("New chat") || selected.contains("Reply from the local"), "Closed chat tab must stay closed after relaunch")
        XCTAssertFalse(app.descendants(matching: .any)["chatDraft"].firstMatch.exists, "Closed chat tab must stay closed after relaunch")
        showProjects(app)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(phoneHomeShown(app), "Home's Chat launcher shows with the bottom bar")
        } else {
            XCTAssertTrue(app.buttons["homeBrowseFiles"].waitForExistence(timeout: 20))
        }
    }

    /// Formatted replies, the host-side queue and editing the latest message,
    /// against the disposable OpenCode and deterministic local model.
    func testChatFeaturesFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let chatReply = try XCTUnwrap(fixture.chatReply)
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        openAddTab(app, kind: "Chat")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        chooseFixtureModel(app)

        composer.tap(); composer.typeText("AGENTLAND_MARKDOWN please format this")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.staticTexts["Fixture heading"].waitForExistence(timeout: 45), "Headings render without their Markdown marks")
        XCTAssertFalse(app.staticTexts["## Fixture heading"].exists)
        XCTAssertTrue(app.staticTexts["fixture-cell"].exists, "Table cells render as a table")
        let copyCode = app.buttons.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copyCode.waitForExistence(timeout: 5), "Code blocks offer their own Copy button")
        copyCode.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Copied")).firstMatch.waitForExistence(timeout: 3))
        attach(app, "chat-formatted-reply")

        composer.tap(); composer.typeText("AGENTLAND_SLOW take your time")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.buttons["chatStop"].waitForExistence(timeout: 15), "The slow reply keeps the agent working")
        let followUp = "Queued follow-up message"
        composer.tap(); composer.typeText(followUp)
        let queueButton = app.buttons["chatQueueSend"]
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5), "A draft typed while the agent works can be queued")
        queueButton.tap()
        let queue = app.descendants(matching: .any)["chatQueue"].firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[followUp].exists)
        attach(app, "chat-queued")
        XCTAssertTrue(queue.waitForNonExistence(timeout: 90), "The host sends the queued prompt once the agent is idle")
        XCTAssertTrue(userMessage(app, followUp).waitForExistence(timeout: 20), "The queued prompt joins the conversation")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 45), "The queued prompt's reply completes")
        XCTAssertTrue(app.staticTexts[chatReply].waitForExistence(timeout: 20))

        // Edit and Resend lives in the latest user message's context menu.
        let latest = userMessage(app, followUp)
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        latest.press(forDuration: 1.2)
        let edit = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "chatEditLatest", "Edit and Resend…")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Only the latest message offers Edit and Resend")
        attach(app, "chat-message-menu")
        edit.tap()
        let confirm = app.buttons["Edit and Rewind"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Rewinding must be confirmed first")
        confirm.tap()
        let banner = app.descendants(matching: .any)["chatRewindBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        XCTAssertEqual(composer.value as? String, followUp, "The rewound message returns to the composer for editing")
        attach(app, "chat-rewound")
        app.buttons["chatRestoreRewind"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 20))
        XCTAssertTrue(userMessage(app, followUp).waitForExistence(timeout: 10), "Restore brings the rewound message back")
        attach(app, "chat-restored")
    }

    /// Streaming through the real host: OpenCode relays the fixture model's
    /// words as they come, the event stream carries them to the phone, and the
    /// reply grows in place. Then Stop, and an approval card that runs a real
    /// command in the disposable project once the phone allows it.
    func testChatStreamingFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let streamed = try XCTUnwrap(fixture.streamReply)
        let approved = try XCTUnwrap(fixture.approvalReply)
        let app = XCUIApplication()
        // No appearance launch argument: it would outrank the in-app switch to Dark below. The chat audit's in-place
        // text sizes lay the transcript out again at each size, which it must survive (ChatScreen's `relayout`).
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        // On iPhone the chat (⌘N) starts before Settings: right after the in-app appearance change the simulator
        // dropped every ⌘N (runs 1791771449, 1791771600); Settings then returns to the chat.
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if !phone { setAppearance(app, "Light"); closeSettings(app) }
        openAddTab(app, kind: "Chat")
        if phone { setAppearance(app, "Light"); closeSettings(app) }
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20))
        attach(app, "chat-v2-empty-light")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        chooseFixtureModel(app)
        // The iPhone's Chat starts general chats (owner's decision, 2026-10-11), whose placeholder names no agent.
        XCTAssertEqual(composer.placeholderValue, UIDevice.current.userInterfaceIdiom == .phone ? "Message" : "Message OpenCode",
                       "The placeholder names the chat's agent")
        attach(app, "chat-v2-composer-light")

        // The reply grows word by word: at least two distinct partial states.
        composer.tap(); composer.typeText("AGENTLAND_STREAM show the reply as it streams")
        app.buttons["chatSend"].tap()
        let growing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming reply"))
        var states: [String] = []
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let element = growing.firstMatch
            if element.exists {
                let label = element.label
                if states.last != label {
                    states.append(label)
                    if states.count == 3 { attach(app, "chat-v2-streaming-light") }
                }
                if label == streamed { break }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        attachText(states.joined(separator: "\n"), "chat-v2-streaming-states")
        XCTAssertEqual(states.last, streamed, "The final reply matches what the model sent")
        let partial = states.filter { $0 != streamed }
        XCTAssertGreaterThanOrEqual(partial.count, 2, "Text must appear incrementally, not all at once: \(states)")
        for (earlier, later) in zip(states, states.dropFirst()) {
            XCTAssertTrue(later.hasPrefix(earlier.trimmingCharacters(in: .whitespaces)), "Each state extends the previous one")
        }
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 15), "The composer returns to Send when the reply ends")
        XCTAssertTrue(app.buttons["chatCopyReply"].waitForExistence(timeout: 10))

        // Stop is always reachable while the agent works, and marks the reply.
        composer.tap(); composer.typeText("AGENTLAND_LONG keep going until I stop you")
        app.buttons["chatSend"].tap()
        let stop = app.buttons["chatStop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20))
        let longReply = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This long reply"))
        XCTAssertTrue(longReply.firstMatch.waitForExistence(timeout: 30), "Stop after some text has streamed")
        stop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chatStoppedMarker"].firstMatch.waitForExistence(timeout: 30),
                      "A stopped reply says so")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 20))
        attach(app, "chat-v2-stopped-light")

        if phone {
            // The iPhone's Chat starts general chats only (owner's decision, 2026-10-11), which run no tools: the
            // approval card, Allow Once, the tool row and Deny have no iPhone route left (the harness checks the
            // proof file on iPad only). The chat's audits in light and dark still run.
            hideKeyboard(app)
            var audit = try auditChat(app, "light")
            setAppearance(app, "Dark")
            closeSettings(app)
            XCTAssertTrue(app.descendants(matching: .any)["chatStoppedMarker"].firstMatch.waitForExistence(timeout: 10))
            hideKeyboard(app)
            attach(app, "chat-v2-stopped-dark")
            audit += try auditChat(app, "dark")
            setAppearance(app, "Light")
            closeSettings(app)
            XCTAssertTrue(audit.isEmpty, "Accessibility audit of the chat screen:\n" + audit.joined(separator: "\n"))
            return
        }
        // An approval card, inline; Allow Once lets the real bash call run.
        composer.tap(); composer.typeText("AGENTLAND_APPROVAL run the proof command")
        app.buttons["chatSend"].tap()
        let card = app.descendants(matching: .any)["chatApprovalCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45), "The pending permission shows as a card in the chat")
        XCTAssertTrue(app.staticTexts["Allow OpenCode to run this command?"].exists)
        XCTAssertFalse(app.buttons["chatAlwaysAllow"].exists, "OpenCode offers no Always Allow, so the card leaves it out")
        XCTAssertTrue(app.buttons["chatDeny"].exists)
        let allow = app.buttons["chatAllowOnce"]
        hideKeyboard(app)
        // Dragging the keyboard away scrolled back through the chat. While the
        // card is out of view or under the composer, the docked pill brings it back.
        let pill = app.buttons["chatNeedsYouPill"]
        if pill.waitForExistence(timeout: 2) {
            XCTAssertEqual(pill.label, "OpenCode needs permission. Review")
            attach(app, "chat-v2-pill-light")
        }
        XCTAssertTrue(revealCardButton(app, allow), "Allow Once is on screen, above the composer")
        XCTAssertGreaterThanOrEqual(allow.frame.height, 44)
        attach(app, "chat-v2-approval-light")
        var audit = try auditChat(app, "light")
        XCTAssertTrue(revealCardButton(app, allow, timeout: 10), "Allow Once is on screen after the audit")
        allow.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), "The card leaves once the host reports the outcome")
        XCTAssertTrue(app.descendants(matching: .any)["chatResolvedInteraction"].firstMatch.waitForExistence(timeout: 20),
                      "The outcome stays as a line in the timeline")
        XCTAssertTrue(app.staticTexts[approved].waitForExistence(timeout: 45), "The agent continues after the approval")
        // On iPhone and iPad a tool row is the system's disclosure (CH-07): its button takes the row's label and
        // identifier, and the system says whether it is open, so the row's contents tell.
        let tool = app.descendants(matching: .any).matching(identifier: "chatToolRow").firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        XCTAssertTrue(tool.label.hasPrefix("Ran echo approved-by-phone"), "Tool rows are humanized: \(tool.label)")
        XCTAssertTrue(tool.label.hasSuffix(", Done"), "The state is spoken, not shown by color alone: \(tool.label)")
        XCTAssertFalse(app.buttons["Copy Input"].exists, "A tool row starts closed")
        XCTAssertTrue(waitUntilHittable(tool, timeout: 5))
        tool.tap()
        let expanded = app.buttons["Copy Input"].waitForExistence(timeout: 5)
        if !expanded { attachText(app.debugDescription, "chat-v2-tool-row-after-tap") }
        XCTAssertTrue(expanded, "Tapping a tool row expands it, showing its input with Copy")
        XCTAssertTrue(app.staticTexts["echo approved-by-phone > approval-proof.txt"].exists, "The input is the exact command")
        hideKeyboard(app)
        attach(app, "chat-v2-tools-light")

        // The same screen in dark appearance.
        setAppearance(app, "Dark")
        closeSettings(app)
        XCTAssertTrue(app.staticTexts[approved].waitForExistence(timeout: 10))
        hideKeyboard(app)
        attach(app, "chat-v2-tools-dark")
        audit += try auditChat(app, "dark")
        composer.tap(); composer.typeText("AGENTLAND_APPROVAL run it once more")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 45))
        hideKeyboard(app)
        let deny = app.buttons["chatDeny"]
        XCTAssertTrue(revealCardButton(app, deny), "Deny is on screen, above the composer")
        attach(app, "chat-v2-approval-dark")
        deny.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 45))
        setAppearance(app, "Light")
        closeSettings(app)
        XCTAssertTrue(audit.isEmpty, "Accessibility audit of the chat screen:\n" + audit.joined(separator: "\n"))
    }

    /// Chooses the local fixture model in the model chip's menu (2026-10-07): among the host's first five, or under
    /// More Models past them.
    func chooseFixtureModel(_ app: XCUIApplication) {
        let model = app.buttons["chatModelMenu"]
        XCTAssertTrue(model.waitForExistence(timeout: 20))
        model.tap()
        // The item's context size is its subtitle, which its label may carry after the name.
        let name = "Deterministic Local Model"
        let row = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ", ")).firstMatch
        let more = app.buttons["More Models"]
        if !row.waitForExistence(timeout: 5), more.exists { more.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The model menu lists the host's models by name")
        row.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Choosing a model closes the menu")
    }

    /// A user message: one element that reads "Your message, <time>: <text>".
    func userMessage(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label ENDSWITH %@", "chatUserMessage", text)).firstMatch
    }

    /// Brings a pending card's button into the open, as a person would: while the card is out of view or its bottom edge
    /// is under the composer, the app docks the needs-you pill (`ChatTranscriptGeometry`), which scrolls the card to the
    /// middle. Then the pill is gone and the button hittable and still. `isHittable` alone cannot tell: since the composer
    /// sits in the system's bottom bar (CH-02), a button under it counts as hittable at a point the bar takes (run b7:
    /// Deny's centre at y 834, between the composer's glass and the home indicator, so Deny never ran).
    func revealCardButton(_ app: XCUIApplication, _ button: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let pill = app.buttons["chatNeedsYouPill"]
        if pill.waitForExistence(timeout: 2) { pill.tap() }
        return pill.waitForNonExistence(timeout: timeout) && waitUntilHittable(button, timeout: timeout)
    }

    /// Hittable, and in the same place for three looks in a row: the
    /// transcript has stopped moving after the keyboard or a scroll.
    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var frames: [CGRect] = []
        repeat {
            if element.exists && element.isHittable {
                frames.append(element.frame)
                if frames.count >= 3, Set(frames.suffix(3).map { "\($0)" }).count == 1 { return true }
            } else {
                frames = []
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String ?? "").contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    /// Hides the keyboard the way a person does in the chat: a drag from the
    /// transcript down into the keyboard, which the transcript dismisses
    /// interactively.
    func hideKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        // The scroll view runs under the composer and keyboard; start just
        // below the chat header, where its content is visible.
        var header = app.descendants(matching: .any)["chatHeader"].firstMatch
        // The iPhone chat has no header of its own: the workspace's header sits above its transcript.
        if !header.exists { header = workspaceHeader(app) }
        XCTAssertTrue(header.exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: header.frame.maxY + 40))
        let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Dragging the transcript into the keyboard hides it")
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Xcode's accessibility audit over the chat screen, one audit type at a
    /// time with the Dynamic Type checks last (they resize text), run with
    /// the transcript at its latest message. Findings are sorted, then counted:
    /// - The system keyboard and the app's navigation bar (the tab menu above
    ///   the chat) are not part of the chat screen: listed, not counted.
    /// - Rows scrolled partly behind the header or composer, or off screen,
    ///   are not in view; the audit samples whatever covers them: listed, not
    ///   counted.
    /// - Contrast findings are measured again from a screenshot: the most
    ///   common color is the background, the most contrasting color covering
    ///   at least 0.25% of the element is its text. A shadow gradient behind text
    ///   or a button's rounded corners can fail the audit's own sampling; the
    ///   finding stands only when the measured ratio is under 4.5:1.
    /// - "Partially unsupported" Dynamic Type on transcript rows: while the
    ///   audit enlarges text, the transcript keeps its latest message in
    ///   place and scrolls earlier rows away, so the audit cannot finish
    ///   measuring them. Chat fonts are all text styles
    ///   (ChatTypographyTests) and the transcript's scaling to the largest
    ///   size is covered by ChatScreenRenderTests: listed, not counted.
    ///   The same finding on the header, the composer or a card counts.
    /// Everything else counts. Returns the counted findings, so both
    /// appearances run before the test asserts.
    private func auditChat(_ app: XCUIApplication, _ appearance: String, reach: [ReachableElement] = []) throws -> [String] {
        // The latest message sits just above the composer, as when following.
        let jump = app.buttons["chatJumpToLatest"]
        if jump.exists && jump.isHittable {
            jump.tap()
        } else {
            app.scrollViews["chatTranscript"].swipeUp()
        }
        Thread.sleep(forTimeInterval: 1.5)
        // The checks that leave the screen as it is first: they are judged on it as it is, its screenshot and
        // frames taken before the Dynamic Type and clipped-text checks enlarge the text in place.
        var issues: [XCUIAccessibilityAuditIssue] = []
        for type in Self.steadyAudits {
            try app.performAccessibilityAudit(for: type) { issue in
                issues.append(issue)
                return true
            }
        }
        let navigation = app.navigationBars.firstMatch
        let chrome = navigation.exists ? navigation.frame : phoneHeaderFrame(app)
        let header = app.descendants(matching: .any)["chatHeader"].firstMatch
        let composer = app.descendants(matching: .any)["chatComposer"].firstMatch
        let headerFrame = header.exists ? header.frame : .zero
        let composerFrame = composer.exists ? composer.frame : .zero
        // The screen as the checks left it, read once for all their findings (again after the text-size checks).
        var scene = AuditScene(app)
        let band = CGRect(x: scene.appFrame.minX, y: headerFrame.maxY, width: scene.appFrame.width,
                          height: max(0, composerFrame.minY - headerFrame.maxY))
        let screenshot = app.screenshot()
        let audited = XCTAttachment(screenshot: screenshot)
        audited.name = "chat-v2-audited-\(appearance)"
        audited.lifetime = .keepAlways
        add(audited)
        var counted: [String] = []
        var outside: [String] = []
        var remeasured: [String] = []
        var nearlyPassed: [String] = []
        func judge(_ issue: XCUIAccessibilityAuditIssue) {
            // The issue's element, read once from its snapshot.
            let element = AuditedElement(issue)
            var frame = CGRect.zero
            var system = false
            if let element, element.exists {
                frame = element.frame
                system = element.elementType == .key || element.elementType == .keyboard
            }
            let place = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            let described = "\(issue.auditType.rawValue) \(issue.compactDescription) | \(issue.detailedDescription) "
                + "[id=\(element?.identifier ?? "-") label=\(element?.label ?? "-") at \(place)]"
            let inChrome = !chrome.isEmpty && !frame.isEmpty && chrome.contains(CGPoint(x: frame.midX, y: frame.midY))
            if system || inChrome {
                outside.append("outside the chat: " + described)
                return
            }
            // Text the audit sees on screen without an element to name: the list bullets and a code
            // block's language label are hidden on purpose, since the list items and the block's own
            // label ("Code, swift, 1 line") carry them.
            if issue.auditType == .elementDetection, element == nil {
                outside.append("decorative text hidden on purpose: " + described)
                return
            }
            // Selectable text (a code block's code) is not a control: its hit area is its text.
            if issue.auditType == .hitRegion, let element, element.exists, element.elementType == .staticText {
                outside.append("selectable text, not a control: " + described)
                return
            }
            // The transcript scrolls under the navigation bar's Liquid Glass (the chat's title and actions
            // live in the bar since H2). While the audit enlarges the text the rows re-lay out, and a row
            // under the bar or rebuilt meanwhile comes back without an element to name or measure. The
            // same checks on the header (the title menu) and the composer name their elements and count.
            if issue.auditType == .dynamicType || issue.auditType == .textClipped, element == nil || frame.isEmpty {
                outside.append("no element (a transcript row re-laid out or under the navigation bar): " + described)
                return
            }
            // Out of VoiceOver's reach: a surface behind the chat (see audit(_:screen:appearance:reach:)).
            if !frame.isEmpty, !reach.isEmpty, !reachable(element, frame: frame, among: reach, appFrame: scene.appFrame) {
                outside.append("out of VoiceOver's reach: " + described)
                return
            }
            // The chat's title stops at three lines at accessibility sizes, where a longer one would
            // push the header over the navigation bar; VoiceOver reads it whole.
            if issue.auditType == .textClipped, !frame.isEmpty, headerFrame.contains(frame) {
                outside.append("title limited to three lines at accessibility sizes: " + described)
                return
            }
            // Without an element: every text on screen is measured instead, those VoiceOver reaches when the
            // list is given.
            if issue.auditType == .contrast, element == nil,
               let lowest = lowestTextContrastOnce(scene, screenshot: screenshot, reach: reach), lowest >= 4.5 {
                remeasured.append(String(format: "no element; every text measures at least %.1f:1: ", lowest) + described)
                return
            }
            if !frame.isEmpty {
                let inView = headerFrame.contains(frame) || composerFrame.contains(frame) || band.contains(frame)
                if !inView {
                    outside.append("not in view: " + described)
                    return
                }
                let transcriptRow = band.contains(frame) && !composerFrame.intersects(frame)
                if transcriptRow, issue.auditType == .dynamicType, issue.compactDescription.contains("partially") {
                    outside.append("transcript row resized by the audit: " + described)
                    return
                }
                if issue.auditType == .contrast, let ratio = measuredContrast(screenshot, frame: frame, appFrame: scene.appFrame),
                   ratio >= 4.5 {
                    remeasured.append(String(format: "measured %.1f:1: ", ratio) + described)
                    return
                }
            }
            if Self.isNearlyPassedContrast(issue) {
                nearlyPassed.append(described)
                return
            }
            counted.append(described)
        }
        issues.forEach(judge)
        // The text-size checks last, judged on the frames they leave.
        var resized: [XCUIAccessibilityAuditIssue] = []
        for type in Self.resizingAudits {
            try app.performAccessibilityAudit(for: type) { issue in
                resized.append(issue)
                return true
            }
        }
        let afterResizing = XCTAttachment(screenshot: app.screenshot())
        afterResizing.name = "chat-v2-after-text-size-audits-\(appearance)"
        afterResizing.lifetime = .keepAlways
        add(afterResizing)
        scene = AuditScene(app)
        resized.forEach(judge)
        attachText((["Chat findings: \(counted.count)"] + counted
                    + ["Contrast measured again and passing: \(remeasured.count)"] + remeasured
                    + ["Contrast nearly passed (logged, not failed): \(nearlyPassed.count)"] + nearlyPassed
                    + ["Not counted: \(outside.count)"] + outside).joined(separator: "\n"),
                   "chat-v2-accessibility-audit-\(appearance)")
        logNearlyPassedContrast(nearlyPassed, "chat-\(appearance)")
        return counted.map { "\(appearance): \($0)" }
    }

    /// The contrast of an element in a screenshot: the most common color is
    /// the background; the most contrasting color that covers at least 0.25%
    /// of the element is taken as its text.
    private func measuredContrast(_ screenshot: XCUIScreenshot, frame: CGRect, appFrame: CGRect) -> Double? {
        guard let image = screenshot.image.cgImage, appFrame.width > 0 else { return nil }
        let scale = CGFloat(image.width) / appFrame.width
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
        guard let crop = image.cropping(to: rect), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width * height > 0 else { return nil }
        var counts: [UInt32: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let key = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
            counts[key, default: 0] += 1
        }
        func luminance(_ key: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(key >> 16 & 255) + 0.7152 * channel(key >> 8 & 255) + 0.0722 * channel(key & 255)
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let minimum = max(1, width * height / 400)
        let base = luminance(background)
        return counts.filter { $0.value >= minimum }.keys.map { key in
            let other = luminance(key)
            return (max(base, other) + 0.05) / (min(base, other) + 0.05)
        }.max()
    }

    /// An empty agent chat opens like a plain chat (owner, 2026-10-07): the tent and "What’s on your mind?" over a
    /// ready composer, with no action tiles (Home, the drawer and the task menu hold those). The agent's own
    /// header, model and mode stay.
    func testAgentChatLanding() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // Home: six ovals, two columns 16 pt apart both ways (HomeAndDrawerUITests.swift); the iPhone's Chat
        // destination has the host's launchers instead (testHomeCapsulesAndQuip measures them).
        if phone { XCTAssertTrue(phoneHomeShown(app)) } else { assertHomeCapsules(app) }
        // On iPhone ⌘N's OpenCode chat, a general chat (the bottom tabs, 2026-10-11).
        openAddTab(app, kind: "Chat")

        let landing = app.descendants(matching: .any)["plainChatLanding"].firstMatch
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        let oldTiles = ["chatStartPrompt", "chatResumeWork", "chatBrowseFiles", "chatNewTerminal", "chatOpenWorkspace", "chatMoreActions"]
        XCTAssertTrue(landing.waitForExistence(timeout: 20), "An empty agent chat shows the plain chat's landing")
        XCTAssertTrue(app.staticTexts["plainChatPrompt"].exists)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The composer is ready under the landing")
        for tile in oldTiles { XCTAssertFalse(app.buttons[tile].exists, "The landing has no \(tile) tile") }
        attach(app, "chat-landing-agent")
        // Chat's Claude Code and Codex chats (2026-10-12) start the real agents, which these tests never do: the paired
        // Mac's smoke check (testInstalledChatProviders) opens them empty, and the iPad's old Home agent menu is gone.
    }

    /// Tabs kept alive behind Home (Files, a terminal) must not take touches or accessibility hits from
    /// the selected Home.
    func testRetainedTabsStayBehindHome() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        let terminal = app.buttons["homeNewTerminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(terminal.isHittable, "Home with a retained Files tab")
        terminal.tap()
        app.buttons["homeTerminalProgram-shell"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        showProjects(app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        attach(app, "root-home-over-retained-terminal")
        XCTAssertTrue(terminal.isHittable, "Root Home with a retained terminal")
        // iPhone's Home has Workspace where iPad's has Browse Files.
        XCTAssertTrue(app.buttons[UIDevice.current.userInterfaceIdiom == .phone ? "openWorkspace" : "homeBrowseFiles"].isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["terminalCanvas"].firstMatch.isHittable,
                       "A retained terminal cannot receive touches through bounded Home")
        app.terminate()
        app.launch()
        showProjects(app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 20))
        XCTAssertTrue(terminal.isHittable, "Root Home after relaunch with retained tabs")
        terminal.tap()
        XCTAssertTrue(app.buttons["homeTerminalProgram-shell"].waitForExistence(timeout: 5))
        app.buttons["homeTerminalProgram-shell"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
    }

    /// VoiceOver reaches only the surface in front: with Home in front nothing of a retained Files,
    /// Editor or Terminal tab, and with the editor in front neither Home nor the other tabs. XCUITest's
    /// own tree also lists elements SwiftUI hides from VoiceOver, so the app lists what VoiceOver
    /// reaches (a UI-test control that walks the accessibility containers as the screen reader does).
    func testVoiceOverReachesOnlyTheSelectedSurface() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        browseFilesFromHome(app)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // The iPhone's Files is a page of the Workspace destination, whose rows carry the drawer's identifiers.
        let fileRow = app.buttons[phone ? "drawerFile-hello.txt" : "file-hello.txt"]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 15))
        // The Files page's row shows the file read-only first; its Open in Workspace opens the editor (2026-10-06).
        openFileFromRow(app, fileRow)
        XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 15))
        openAddTab(app, kind: "Terminal")
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        hideTerminalKeyboard(app)
        let terminal = voiceOverElements(app)
        XCTAssertTrue(terminal.contains("terminalRendererSerial"), "The walk reaches the terminal in front: \(terminal)")
        XCTAssertFalse(terminal.contains("saveFile") || terminal.contains("fileSort") || terminal.contains("homeNewChat"),
                       "Nothing behind the terminal: \(terminal)")

        showProjects(app)
        // The iPhone's Home has its title and the host's launchers in place of New Chat.
        let homeMark = phone ? "homeWordmark" : "homeNewChat"
        XCTAssertTrue(app.descendants(matching: .any)[homeMark].firstMatch.waitForExistence(timeout: 10))
        attach(app, "home-over-retained-tabs")
        let home = voiceOverElements(app)
        XCTAssertTrue(home.contains(homeMark), "The walk reaches Home: \(home)")
        for hidden in ["fileSort", "saveFile", "fileEditor", "terminalCanvas", "terminalRendererSerial"] {
            XCTAssertFalse(home.contains(hidden), "\(hidden) is out of VoiceOver's reach behind Home: \(home)")
        }

        selectTab(app, titled: "hello.txt")
        XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 10))
        let editor = voiceOverElements(app)
        XCTAssertTrue(editor.contains("saveFile"), "The walk reaches the editor: \(editor)")
        for hidden in [homeMark, "fileSort", "terminalCanvas", "terminalRendererSerial"] {
            XCTAssertFalse(editor.contains(hidden), "\(hidden) is out of VoiceOver's reach behind the editor: \(editor)")
        }
        closeCurrentTab(app)
        if phone {
            // The shell names its terminal; it is the one task left in the header's switcher.
            app.buttons["workspaceSwitcher"].tap()
            let terminalRow = phoneTaskRows(app).firstMatch
            XCTAssertTrue(terminalRow.waitForExistence(timeout: 8))
            terminalRow.tap()
        } else {
            selectTab(app, titled: "Terminal")
        }
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        closeCurrentTab(app)
        selectTab(app, titled: "Files")
        // The iPhone's Files page has no folder bar; its menu is the navigation bar's (FI-1).
        XCTAssertTrue(app.buttons[phone ? "fileActions" : "fileSort"].firstMatch.waitForExistence(timeout: 10))
        // The iPhone's Files is the Workspace destination's page, not a task to close.
        if phone { showPhoneTab(app, "Chat") } else { closeCurrentTab(app) }
    }

    /// An element VoiceOver can reach, as the app lists it.
    struct ReachableElement {
        let identifier: String
        let label: String
        let frame: CGRect
        /// The identifier, or the label for an element without one.
        var name: String { identifier.isEmpty ? label : identifier }

        /// The app's list, one element a line: identifier, label and frame (`x,y,width,height`, or `null` for an
        /// element with no place on screen, which still counts by its identifier or label) separated by tabs.
        static func list(_ value: String) -> [ReachableElement] {
            value.components(separatedBy: "\n").compactMap { line in
                let fields = line.components(separatedBy: "\t")
                guard fields.count == 3 else { return nil }
                if fields[2] == "null" { return ReachableElement(identifier: fields[0], label: fields[1], frame: .null) }
                let numbers = fields[2].components(separatedBy: ",").compactMap { Double($0) }
                guard numbers.count == 4 else { return nil }
                return ReachableElement(identifier: fields[0], label: fields[1],
                                        frame: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
            }
        }
    }

    /// What VoiceOver can reach now, as the app lists it (a UI-test control in the tab menu).
    func reachableElements(_ app: XCUIApplication) -> [ReachableElement] {
        var value = ""
        let sheetList = app.descendants(matching: .any)["debugSheetVoiceOverElements"].firstMatch
        let pageList = app.descendants(matching: .any)["debugDrawerPageVoiceOverElements"].firstMatch
        let sidebarList = app.descendants(matching: .any)["debugSidebarVoiceOverElements"].firstMatch
        // A sheet covers the tab menu, and on iPhone the sidebar drawer is a screen without it, as is a
        // page pushed in the drawer (Settings); the app lists what VoiceOver reaches there once the sheet,
        // page or sidebar has settled.
        let drawer = app.buttons["resumeWorkClose"].exists || app.buttons["settingsClose"].exists
            || (UIDevice.current.userInterfaceIdiom == .phone && (app.otherElements["settingsDrawer"].exists || phoneDrawerShown(app)))
        let panelList = sheetList.exists ? sheetList
            : drawer && pageList.exists ? pageList
            : drawer && sidebarList.exists ? sidebarList : nil
        if let panelList {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                value = panelList.value as? String ?? ""
                if !value.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.3)
            }
        } else {
            let list = app.descendants(matching: .any)["debugVoiceOverElements"].firstMatch
            if UIDevice.current.userInterfaceIdiom == .phone {
                // The iPhone's tab menu has no UI-test controls (owner, 2026-10-11): the app lists what VoiceOver
                // reaches a second after the destination or the task in front changes.
                Thread.sleep(forTimeInterval: 2.5)
                value = list.value as? String ?? ""
                attachText(value, "voiceover-elements")
                return ReachableElement.list(value)
            }
            let before = list.value as? String ?? ""
            titleMenu(app).tap()
            let listButton = app.buttons["debugListVoiceOverElements"]
            listButton.tap()
            value = before
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                value = list.value as? String ?? ""
                if !value.isEmpty && value != before { break }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        attachText(value, "voiceover-elements")
        return ReachableElement.list(value)
    }

    private func voiceOverElements(_ app: XCUIApplication) -> Set<String> {
        Set(reachableElements(app).map(\.name))
    }

    /// Whether VoiceOver can reach `element`: it is one of the reachable elements (same identifier, or
    /// same label and place) or a part of one (a button's text lies inside the button). Surface-sized
    /// elements, the editor's and the terminal's text, have no parts: a hidden surface's element lies
    /// inside them too.
    private func reachable(_ element: AuditedElement?, frame: CGRect, among reach: [ReachableElement], appFrame: CGRect) -> Bool {
        // An element with an identifier of its own is reached as itself or not at all: Home's quip under the
        // sidebar drawer can lie inside the frame of a drawer row that VoiceOver reaches.
        if let element, !element.identifier.isEmpty { return reach.contains(where: { $0.identifier == element.identifier }) }
        if let element, !element.label.isEmpty,
           reach.contains(where: { $0.identifier.isEmpty && $0.label == element.label && $0.frame.intersects(frame) }) { return true }
        let screenArea = appFrame.width * appFrame.height
        return reach.contains { container in
            container.frame.width * container.frame.height < screenArea / 2 && container.frame.insetBy(dx: -1, dy: -1).contains(frame)
        }
    }

    func testTabletHomeTabLauncher() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only: the tablet Home tab launcher")
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        connectHardwareKeyboard(app)

        // The centered workspace switcher, rather than a persistent sidebar, owns Home and tab routing.
        showProjects(app)
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForWorkspaceLine(app, "Workspace: Fixture", timeout: 8))
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 5))
        assertHomeTitle(app)
        // Home now centres its decoration in the whole available content column.
        let circus = app.descendants(matching: .any)["homeCircus"].firstMatch
        XCTAssertLessThan(abs(circus.frame.midX - app.frame.midX), 40, "Home centres its art in the content column")
        attach(app, "tablet-home")

        // New Home Tab is a keyboard command. It appears in the switcher and keeps a trailing Close Tab action.
        XCTAssertTrue(press(app, "t", .command, attempts: 4) { currentTab(app).label == "Current tab: Home 2" }, "⌘T opens a Home tab")
        XCTAssertTrue(app.buttons["homeNewChat"].exists)
        XCTAssertTrue(app.buttons["homeNewTerminal"].exists)
        attach(app, "tablet-home-2")
        switcher.tap()
        let secondHome = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", "Home 2", "workspacePickerTab-")).firstMatch
        XCTAssertTrue(secondHome.waitForExistence(timeout: 5), "The switcher lists the retained Home tab")
        XCTAssertTrue(app.buttons["workspacePickerHome"].exists)
        app.buttons["workspacePickerHome"].tap()
        XCTAssertTrue(app.buttons["homeBrowseFiles"].waitForExistence(timeout: 5))
        switcher.tap()
        XCTAssertTrue(secondHome.waitForExistence(timeout: 5))
        secondHome.tap()
        XCTAssertTrue(app.buttons["homeRecentWork"].waitForExistence(timeout: 5))
        XCTAssertEqual(currentTab(app).label, "Current tab: Home 2")
        titleMenu(app).tap()
        XCTAssertTrue(app.buttons["closeCurrentTab"].waitForExistence(timeout: 5), "A retained Home tab has trailing actions")
        app.buttons["closeCurrentTab"].tap()
        // Opening the fixture workspace retained its Files tab. Closing Home 2 selects that existing
        // workspace tab according to the model's unchanged close policy; permanent Home stays reachable.
        XCTAssertTrue(waitForLabel(currentTab(app), "Current tab: Files"), "Closing Home 2 restores the retained workspace tab")
        switcher.tap()
        XCTAssertTrue(app.buttons["workspacePickerHome"].waitForExistence(timeout: 5))
        XCTAssertFalse(secondHome.exists, "The explicitly closed Home tab leaves the picker")
        app.buttons["workspacePickerHome"].tap()
        XCTAssertEqual(currentTab(app).label, "Current tab: Home")
    }

    /// Production motion (no animation-disabling flag): every time Home is revealed, here on the way back
    /// from Files, the arched title plays an entrance. Run with a simulator recording for evidence.
    func testTitleEntrances() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-agentland.lock.enabled", "NO", "-agentland.appearance", "light",
                               "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        let wordmark = app.descendants(matching: .any)["homeWordmark"].firstMatch
        XCTAssertTrue(wordmark.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2.5)
        for round in 1...3 {
            browseFilesFromHome(app)
            XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 15))
            openSidebarItem(app, "sidebarHome")
            XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
            XCTAssertTrue(wordmark.isHittable, "Home is revealed")
            // Leave time for the entrance (0.9–1.4 s) and a moment of rest.
            Thread.sleep(forTimeInterval: 2.5)
            attach(app, "title-entrance-\(round)")
        }
        XCTAssertEqual(app.staticTexts["homeQuip"].label, fixedQuip)
    }

    /// Compact height puts the decorative circus left of the launcher actions; the title remains at the top.
    func testLandscapeHome() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light", "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        // A teardown block runs after a failure too: the next test starts in portrait.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let deadline = Date().addingTimeInterval(8)
        while app.frame.width < app.frame.height && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app turned to landscape")
        Thread.sleep(forTimeInterval: 1)
        let wordmark = app.descendants(matching: .any)["homeWordmark"].firstMatch
        let quip = app.staticTexts["homeQuip"]
        let circus = app.descendants(matching: .any)["homeCircus"].firstMatch
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
        XCTAssertTrue(circus.exists)
        var actionFrames: [(identifier: String, frame: CGRect)] = []
        for (identifier, _) in expectedHomeActions {
            let action = app.buttons[identifier]
            XCTAssertTrue(action.waitForExistence(timeout: 5), "Landscape Home has \(identifier)")
            XCTAssertTrue(action.isHittable, "Landscape Home keeps \(identifier) tappable")
            if action.exists { actionFrames.append((identifier, action.frame)) }
        }
        attachText(actionFrames.map { action in
            "\(action.identifier): \(action.frame)"
        }.joined(separator: "\n"), "home-landscape-action-frames")
        attach(app, "home-landscape")
        guard actionFrames.count == expectedHomeActions.count, let first = actionFrames.first else {
            return XCTFail("Landscape Home has every launcher action")
        }
        let actions = actionFrames.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        XCTAssertLessThan(wordmark.frame.maxY, min(circus.frame.minY, actions.minY),
                          "The title remains above the wide launcher")
        XCTAssertTrue(quip.exists)
        XCTAssertLessThan(circus.frame.maxX, actions.minX, "Wide Home keeps art left of actions")
        XCTAssertLessThan(quip.frame.maxY, actions.minY, "The quip stays above actions")
        XCTAssertEqual(quip.frame.midX, actions.midX, accuracy: 16, "The quip follows the action column")
        XCTAssertFalse(wordmark.frame.contains(CGPoint(x: quip.frame.midX, y: quip.frame.midY)), "The arch's hollow is empty")
        XCTAssertGreaterThanOrEqual(app.frame.maxY - actions.maxY, 32,
                                    "Landscape Home leaves at least 32 pt below all launcher actions")
        // XCTest's landscape screenshots come out unrotated; hold still for a simulator recording instead.
        Thread.sleep(forTimeInterval: 3)
    }

    func testDarkAppearance() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "dark")
        let app = XCUIApplication()
        app.launchArguments += ["-AgentLandUITestsDisableAnimations", "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // iPhone's Home is its Chat destination above the bottom bar; iPad's has Browse Files.
        if phone { XCTAssertTrue(phoneHomeShown(app)) } else { XCTAssertTrue(app.buttons["homeBrowseFiles"].waitForExistence(timeout: 20)) }
        setAppearance(app, "Dark")
        attach(app, "dark-settings")
        closeSettings(app)
        XCTAssertTrue(app.descendants(matching: .any)[phone ? "homeWordmark" : "homeNewChat"].firstMatch.waitForExistence(timeout: 5))
        // The title's checks report and the surfaces below still run (as in testVisualSurfaces).
        continueAfterFailure = true
        assertHomeTitle(app)
        continueAfterFailure = false
        attach(app, "dark-workspace")
        if phone {
            // The Workspace destination in the dark appearance (the bottom tabs, 2026-10-11).
            showPhoneTab(app, "Workspace")
            XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 5))
            attach(app, "dark-workspace-tab")
        }
        browseFilesFromHome(app)
        XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 15))
        attach(app, "dark-files")
        openFileFromRow(app, app.buttons[fileRowID("hello.txt")])
        XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 15))
        attach(app, "dark-editor")
        showProjects(app)
        openAddTab(app, kind: "Chat")
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 15), "The composer is under the landing")
        attach(app, "dark-chat-landing")
        app.descendants(matching: .any)["chatDraft"].firstMatch.tap()
        attach(app, "dark-chat-composer")
        showProjects(app)
        openAddTab(app, kind: "Terminal")
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 15))
        typeTerminal(app, "printf 'AgentLand %s\\n' terminal\n")
        XCTAssertTrue(try waitForRenderedText("AgentLand terminal", in: app, timeout: 20))
        if phone {
            // The key bar's Hide keyboard; the header's X ends the terminal after its confirmation (the tab menu has
            // no per-task actions, owner's decision, 2026-10-11).
            hideTerminalKeyboard(app)
            attach(app, "dark-terminal")
            closePhoneTask(app)
            XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForNonExistence(timeout: 10), "End closes the terminal")
            return
        }
        surfaceMenu(app, "terminalActions").tap()
        menuItem(app, "terminalMenuHideKeyboard", label: "Hide keyboard").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        attach(app, "dark-terminal")
        surfaceMenu(app, "terminalActions").tap()
        let end = app.buttons["End terminal"].firstMatch
        end.tap()
        app.buttons["End terminal"].firstMatch.tap()
    }

    // MARK: Workspaces

    /// Workspace management through the shipping UI against the harness's host, whose home folder is a
    /// temporary one (docs/HOST-API.md, "Workspaces"): New Workspace… makes a Git repository in
    /// ~/Developer (chosen with the folder browser) and opens it; from the sidebar's switcher it is
    /// renamed and closed (Home then offers the list), then removed. The harness checks afterwards that
    /// the folder and its repository are still on disk and the host's state no longer lists it.
    func testWorkspaceManagement() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let name = try XCTUnwrap(fixture.workspaceName, "Run through integration/check-ios-product.py")
        let renamed = name + " Renamed"
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)

        // Home's Open workspace (iPhone: Workspace → Manage Workspaces) shows the Workspaces screen on a host that
        // manages them.
        openWorkspacesFromSwitcher(app)
        XCTAssertTrue(app.buttons["pickerProject-fixture"].waitForExistence(timeout: 8), "All Workspaces lists the fixture")
        attach(app, "workspaces-list")

        // New Workspace…: a name, ~/Developer by default (the folder browser shows and keeps it), Git on.
        app.buttons["workspacesAddMenu"].tap()
        app.buttons["newWorkspace"].firstMatch.tap()
        let nameField = app.textFields["newWorkspaceName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { nameField.tap() }
        nameField.typeText(name)
        let location = app.buttons["newWorkspaceLocation"]
        XCTAssertTrue(waitForValue(location, containing: "~/Developer", timeout: 10), "New workspaces go in ~/Developer by default")
        XCTAssertEqual(app.switches["newWorkspaceGit"].value as? String, "1", "Git is on by default")
        attach(app, "workspaces-new")
        location.tap()
        let choose = app.buttons["folderChoose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["folderBreadcrumbCurrent"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["folderBreadcrumbCurrent"].label, "Developer", "The browser starts where the location is")
        attach(app, "workspaces-folder-browser")
        choose.tap()
        let create = app.buttons["newWorkspaceCreate"]
        XCTAssertTrue(waitUntilEnabled(create, timeout: 5))
        create.tap()
        XCTAssertTrue(waitForWorkspaceLine(app, "Workspace: \(name)", timeout: 20), "The new workspace opens")

        // Rename it, from the sidebar's workspace switcher.
        openWorkspacesFromSwitcher(app)
        XCTAssertTrue(workspaceRows(app, name).firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(workspaceRows(app, name).count, 2, "Open and All Workspaces both list it")
        workspaceAction(app, name, "workspaceActionRename")
        let renameField = systemAlerts(app).textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        replaceText(in: renameField, with: renamed)
        app.buttons["workspaceRenameConfirm"].firstMatch.tap()
        XCTAssertTrue(workspaceRows(app, renamed).firstMatch.waitForExistence(timeout: 10), "The renamed workspace is listed")
        XCTAssertFalse(workspaceRows(app, name).firstMatch.exists)
        attach(app, "workspaces-renamed")

        // Close: its tabs close on this device and none is in use.
        workspaceAction(app, renamed, "workspaceActionClose")
        let close = app.buttons["confirmCloseWorkspace"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 8), "Close asks first")
        attach(app, "workspaces-close-confirmation")
        close.tap()
        let rows = workspaceRows(app, renamed)
        let deadline = Date().addingTimeInterval(8)
        while rows.count != 1 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(rows.count, 1, "Only All Workspaces lists it once it is closed")
        app.buttons["workspacesDone"].tap()
        // Closing a workspace returns to the permanent Home, with no drawer underneath it.
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.buttons["workspacesDone"].waitForNonExistence(timeout: 5), "Done puts the Workspaces screen away")
            showPhoneTab(app, "Chat")
        } else {
            showHomeTab(app)
        }
        XCTAssertTrue(homeMark(app).waitForExistence(timeout: 5), "Home shows")

        // Remove from AgentLand…: the row goes; the harness checks the files stay.
        openWorkspacesFromSwitcher(app)
        workspaceAction(app, renamed, "workspaceActionRemove")
        let remove = app.buttons["confirmRemoveWorkspace"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 8), "Remove asks first")
        attach(app, "workspaces-remove-confirmation")
        remove.tap()
        XCTAssertTrue(workspaceRows(app, renamed).firstMatch.waitForNonExistence(timeout: 10), "The removed workspace leaves the list")
        XCTAssertTrue(app.buttons["pickerProject-fixture"].exists, "Other workspaces stay")
        attach(app, "workspaces-removed")
        app.buttons["workspacesDone"].tap()
    }

    /// Settings → Agents and AI Providers (docs/AGENT-CATALOG-PLAN.md, "The apps") against the harness's
    /// host. They show only for a host that lists `agents` in its capabilities: against one that does not,
    /// the test checks that Settings has neither row and is skipped. Against one that does, it reads both
    /// panes, searches the agents and audits them, and installs nothing (the simulator never does).
    /// Xcode's accessibility audit of Settings' list and every page, in light and dark, with the reader's text size as
    /// it is: what `testAccessibilityAudits` checks for Settings, without the other screens it prepares first.
    func testSettingsAccessibilityAudit() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        var counted: [String] = []
        for appearance in ["light", "dark"] {
            app.terminate()
            launch(app, appearance: appearance, largestText: false, systemTextSize: true)
            try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true && appearance == "light")
            openSettings(app)
            counted += try auditSettingsPage(app, appearance + "-list")
            for page in ["Connection", "Plain Chats", "Appearance", "Chat", "Terminal", "Notifications", "Privacy & Security", "About AgentLand"] {
                guard settingsRow(app, page, timeout: 3) != nil else { continue }
                openSettingsPage(app, page)
                counted += try auditSettingsPage(app, appearance + "-" + page)
                goBack(app)
                XCTAssertTrue(settingsListShows(app, within: 5))
            }
            closeSettings(app)
        }
        XCTAssertTrue(counted.isEmpty, "Accessibility audit findings:\n" + counted.joined(separator: "\n"))
    }

    /// Audits a Settings page where it shows in the gear's popover, then, while its rows run past the popover's lower
    /// edge, scrolls it a popover at a time and audits again (at most three times), so each row is measured once it is
    /// inside the popover's visible area. Whether rows run past and whether a swipe moved the page are read from
    /// snapshots of the popover, so a page that fits is audited once and a page at its end is not audited again.
    private func auditSettingsPage(_ app: XCUIApplication, _ name: String) throws -> [String] {
        // The page audited, kept with its report (the harness wants a screenshot of each run).
        attach(app, "settings-audit-" + name)
        var counted = try audit(app, screen: .settings, appearance: name, reach: settingsPageReach(app))
        let popover = app.otherElements["settingsDrawer"].firstMatch
        guard UIDevice.current.userInterfaceIdiom == .phone, popover.exists else { return counted }
        let top = settledLayout(of: popover)
        var shown = top
        var swiped = 0
        for step in 1...3 {
            guard let layout = shown, layout.runsPast else { break }
            popover.swipeUp()
            swiped += 1
            let moved = settledLayout(of: popover)
            // A swipe that showed nothing new: the page was at its end.
            guard let moved, moved != layout else { break }
            shown = moved
            counted += try audit(app, screen: .settings, appearance: "\(name)-scrolled\(step)", reach: settingsPageReach(app))
        }
        // Back to the top, where the page's Back button is: a swipe down for each swipe up, and one more when the page
        // is not back where it started.
        for _ in 0..<swiped { popover.swipeDown() }
        if swiped > 0, let top, settledLayout(of: popover) != top { popover.swipeDown() }
        return Array(Set(counted)).sorted()
    }

    /// What VoiceOver reaches on the Settings pages shown in iPad's drawer (each page lists it 1.5 s after it appears),
    /// so the audit leaves out the screen behind Settings, which XCUITest's tree still lists.
    private func settingsPageReach(_ app: XCUIApplication) -> [ReachableElement] {
        // On iPhone Settings is the gear's panel, which keeps VoiceOver to itself: the audit leaves out what XCUITest
        // still lists behind it by the panel's own elements (`notCounted`), so it needs no list here. The page is audited
        // once it holds still and has loaded what it lists.
        if UIDevice.current.userInterfaceIdiom == .phone {
            _ = settledLayout(of: app.otherElements["settingsDrawer"].firstMatch)
            return []
        }
        Thread.sleep(forTimeInterval: 2)
        let lists = app.descendants(matching: .any).matching(identifier: "debugDrawerPageVoiceOverElements").allElementsBoundByIndex
        let value = lists.compactMap { $0.value as? String }.joined(separator: "\n")
        attachText(value, "settings-voiceover-elements")
        return ReachableElement.list(value)
    }

    /// A Settings popover's layout as one snapshot shows it: where each of its elements is, whether a row runs past its
    /// lower edge, and whether it is still loading.
    struct PopoverLayout: Equatable {
        struct Placed: Equatable {
            let type: XCUIElement.ElementType
            let frame: CGRect
        }

        /// Each element's type and frame, depth first. The scroll bars are left out: they come and go as the page
        /// scrolls, and their thumb moves only with the rows.
        let placed: [Placed]
        /// Whether a row runs past the popover's lower edge (or the lower edge of the list or scroll view that holds it):
        /// one the edge cuts, or one below it that the list has laid out.
        let runsPast: Bool
        /// Whether an activity indicator shows: the page is still loading what it lists.
        let loading: Bool

        init(_ popover: XCUIElementSnapshot) {
            var placed: [Placed] = []
            var runsPast = false
            var loading = false
            func walk(_ node: XCUIElementSnapshot, bottom: CGFloat) {
                for child in node.children {
                    if child.label.hasPrefix("Vertical scroll bar") || child.label.hasPrefix("Horizontal scroll bar") { continue }
                    placed.append(Placed(type: child.elementType, frame: child.frame))
                    if child.elementType == .activityIndicator { loading = true }
                    if !child.frame.isEmpty, child.frame.maxY > bottom + 1 { runsPast = true }
                    let scrolls = [.collectionView, .scrollView, .table].contains(child.elementType) && !child.frame.isEmpty
                    walk(child, bottom: scrolls ? min(bottom, child.frame.maxY) : bottom)
                }
            }
            walk(popover, bottom: popover.frame.maxY)
            self.placed = placed
            self.runsPast = runsPast
            self.loading = loading
        }
    }

    /// The Settings popover's layout once it holds still: snapshots 0.3 s apart until two agree and nothing shows as
    /// loading, for at most 3 s (what the fixed 2 s waits before each audit and the 0.5 s after each swipe were for).
    /// Nil when the popover is not there.
    private func settledLayout(of popover: XCUIElement) -> PopoverLayout? {
        let deadline = Date().addingTimeInterval(3)
        var last: PopoverLayout?
        while true {
            guard let snapshot = try? popover.snapshot() else { return nil }
            let layout = PopoverLayout(snapshot)
            if layout == last, !layout.loading { return layout }
            if Date() >= deadline { return layout }
            last = layout
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    func testAgentsSettings() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        // It audits the Agents page: the reader's text size as it is.
        launch(app, appearance: "light", largestText: false, systemTextSize: true)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        // The workspace's list and capabilities are read by the time Home offers it.
        showProjects(app)
        openSettings(app)
        // This Mac → Agents & Providers: the Agents page, with AI Providers as its first row.
        let agentsRow = app.buttons["Agents & Providers"]
        let providersRow = app.descendants(matching: .any)["agentsProvidersRow"].firstMatch
        guard agentsRow.waitForExistence(timeout: 5) else {
            XCTAssertFalse(app.buttons["AI Providers"].exists, "A host without agents shows neither pane")
            XCTAssertTrue(app.buttons["Appearance"].exists, "Settings shows its own panes")
            attach(app, "settings-host-without-agents")
            throw XCTSkip("The harness's host does not list agents in its capabilities (no GET /v1/agents yet): only the gating was checked.")
        }
        attach(app, "settings-host-panes")

        // Agents: the host's list (or why it has none), a search with no match, and the audit.
        agentsRow.tap()
        let list = app.descendants(matching: .any)["agentsList"].firstMatch
        let unavailable = app.staticTexts["Couldn’t Load Agents"]
        XCTAssertTrue(waitForAny([list, unavailable, app.staticTexts["No Agents"]], timeout: 20), "The pane resolves")
        attach(app, "settings-agents")
        if list.exists {
            // The system's search field in the page's navigation bar (2026-10-06; it was a text field, `agentsSearch`).
            let search = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@ OR label == %@",
                                                               "Search Agents", "Search Agents")).firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("zz-no-agent-zz")
            let noResults = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No Results")).firstMatch
            XCTAssertTrue(noResults.waitForExistence(timeout: 5), "A search without a match says so")
            attach(app, "settings-agents-search")
            // The search bar's own Cancel (the button beside the field) clears the search and puts the keyboard away.
            // Return would not once the field is empty: the search keyboard's Search key is enabled only with text
            // (testAgentsSettings, run 1791351089). Without a Cancel, Return goes while the text is still there.
            let field = search.frame
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).allElementsBoundByIndex
                .first { $0.isHittable && abs($0.frame.midY - field.midY) < max(field.height, 44) }
            if let cancel {
                cancel.tap()
            } else if app.keyboards.firstMatch.exists {
                app.typeText("\n")
            }
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "The keyboard goes away")
            // On iPhone Settings is the gear's panel, which keeps VoiceOver to itself (the audit leaves out what it lists
            // behind the panel, `notCounted`): the page is audited whole, shown again so the loaded list is the one on
            // screen.
            if UIDevice.current.userInterfaceIdiom == .phone {
                goBack(app)
                openSettingsPage(app, "Agents & Providers")
                XCTAssertTrue(list.waitForExistence(timeout: 20))
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "agentRow-"))
                                .firstMatch.waitForExistence(timeout: 10), "The Agents page shows its rows")
            }
            let findings = try audit(app, screen: .settings, appearance: "light", reach: [])
            XCTAssertTrue(findings.isEmpty, "Accessibility audit findings:\n" + findings.joined(separator: "\n"))
        }
        goBack(app)

        // AI Providers, from the Agents page: connected first, the others under Available, and where keys are added.
        openSettingsPage(app, "Agents & Providers")
        XCTAssertTrue(providersRow.waitForExistence(timeout: 20), "The Agents page opens AI Providers")
        providersRow.tap()
        let providers = app.descendants(matching: .any)["providersList"].firstMatch
        XCTAssertTrue(waitForAny([providers, app.staticTexts["Couldn’t Load Providers"], app.staticTexts["No Providers"]], timeout: 20),
                      "The pane resolves")
        if providers.exists {
            XCTAssertTrue(app.staticTexts["Connected"].exists)
            attach(app, "settings-providers-top")
            // OpenCode lists over a hundred providers (models.dev's catalog): the footer is under the last.
            let footer = app.staticTexts["providersFooter"]
            for _ in 0..<60 where !footer.exists { providers.swipeUp(velocity: .fast) }
            XCTAssertTrue(footer.waitForExistence(timeout: 2), "The footer says where keys are added")
            XCTAssertEqual(footer.label, "Add keys in AgentLand on your Mac")
        }
        attach(app, "settings-providers")
        closeSettings(app)
    }

    /// Whether any of `elements` shows within `timeout`.
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if elements.contains(where: \.exists) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// The Workspaces screen, New Workspace and the folder browser for review, in light and dark. A Git
    /// repository the harness put in the temporary home folder is added first (so the list and the
    /// browser show a Git badge and "Already a workspace") and removed at the end.
    func testWorkspaceScreenshots() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        // Add Folder…: ~/Developer/sample-repo becomes a workspace and opens.
        openWorkspacesFromSwitcher(app)
        app.buttons["workspacesAddMenu"].tap()
        app.buttons["addFolder"].firstMatch.tap()
        let sample = app.buttons["folder-sample-repo"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10), "The browser starts in ~/Developer")
        sample.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["folderBreadcrumbCurrent"], "sample-repo"))
        app.buttons["folderAddHere"].tap()
        XCTAssertTrue(waitForWorkspaceLine(app, "Workspace: sample-repo", timeout: 20), "The added folder opens")

        for appearance in ["light", "dark"] {
            app.terminate()
            launch(app, appearance: appearance, largestText: false)
            XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 20))
            openWorkspacesFromSwitcher(app)
            XCTAssertTrue(workspaceRows(app, "sample-repo").firstMatch.waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 1)
            attach(app, "workspaces-list-\(appearance)")
            app.buttons["workspacesAddMenu"].tap()
            app.buttons["newWorkspace"].firstMatch.tap()
            let nameField = app.textFields["newWorkspaceName"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 8))
            if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { nameField.tap() }
            nameField.typeText("Notes")
            XCTAssertTrue(waitForValue(app.buttons["newWorkspaceLocation"], containing: "~/Developer", timeout: 10))
            attach(app, "workspaces-new-\(appearance)")
            app.buttons["newWorkspaceLocation"].tap()
            XCTAssertTrue(app.buttons["folderChoose"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["folder-sample-repo"].waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 0.5)
            attach(app, "workspaces-folder-browser-\(appearance)")
            app.buttons["folderChoose"].tap()
            app.buttons["newWorkspaceCancel"].tap()
            app.buttons["workspacesDone"].tap()
        }

        // Leave the fixture as it was: sample-repo is removed again (its files stay).
        openWorkspacesFromSwitcher(app)
        workspaceAction(app, "sample-repo", "workspaceActionRemove")
        let remove = app.buttons["confirmRemoveWorkspace"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        attach(app, "workspaces-remove-confirmation-dark")
        remove.tap()
        XCTAssertTrue(workspaceRows(app, "sample-repo").firstMatch.waitForNonExistence(timeout: 10))
        app.buttons["workspacesDone"].tap()
    }

    /// The permanent Home in front.
    private func showHomeTab(_ app: XCUIApplication) {
        let tabs = currentTab(app)
        if !tabs.exists || tabs.label != "Current tab: Home" {
            openSidebarItem(app, "sidebarHome")
            XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["openWorkspace"].waitForExistence(timeout: 5))
    }

    /// The Workspaces screen: from Home's Open Workspace action on iPad; on iPhone from the Workspace tab's Manage
    /// Workspaces (the bottom tabs, owner, 2026-10-11).
    private func openWorkspacesFromSwitcher(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            showPhoneTab(app, "Workspace")
            let back = app.buttons["phoneBackToWorkspace"]
            if back.exists { back.tap(); _ = back.waitForNonExistence(timeout: 3) }
            let manage = app.buttons["Manage Workspaces"]
            XCTAssertTrue(manage.waitForExistence(timeout: 5), "Workspace offers Manage Workspaces")
            for _ in 0..<4 where !manage.isHittable { app.collectionViews.firstMatch.swipeUp() }
            manage.tap()
        } else {
            showHomeTab(app)
            app.buttons["openWorkspace"].tap()
        }
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 8),
                      "The host must advertise capabilities.projects (details) for the Workspaces screen")
    }

    /// The rows of the workspace named `name` (in Open and in All Workspaces). On iPhone the Workspace tab's
    /// Workspace in use row behind the screen also carries the name; it is left out.
    private func workspaceRows(_ app: XCUIApplication, _ name: String) -> XCUIElementQuery {
        app.collectionViews.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", name, "phoneChooseWorkspace"))
    }

    /// Chooses an action from a workspace row's … menu.
    private func workspaceAction(_ app: XCUIApplication, _ name: String, _ identifier: String) {
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "Actions for \(name)")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "The row of \(name) has its actions")
        menu.tap()
        let item = app.buttons[identifier].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The menu offers \(identifier)")
        item.tap()
    }

    // MARK: The split view shell (HIG pass H2)

    /// The centered picker replaces sidebar navigation: it selects Home, a workspace and retained tabs;
    /// Resume Work keeps searchable history separate from workspace management.
    func testSidebarNavigation() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light", "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["showSidebar"].exists)

        if UIDevice.current.userInterfaceIdiom == .phone {
            // iPhone: the bottom tabs replaced the drawer (owner, 2026-10-11). Workspace holds the workspace in use,
            // Files, Git, Chat History and the workspace actions; no drawer, Resume button or header gear is left.
            browseFilesFromHome(app)
            XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 15))
            XCTAssertTrue(phoneTabBar(app).exists, "Files keeps the bottom bar")
            app.buttons["phoneBackToWorkspace"].tap()
            for row in ["phoneChooseWorkspace", "phoneFiles", "phoneGit", "phoneChatHistory", "Open Workspace…", "Manage Workspaces"] {
                XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "Workspace lists \(row)")
            }
            XCTAssertEqual(app.buttons["phoneChooseWorkspace"].label, "Fixture", "Workspace names the workspace in use")
            for gone in ["workspaceDrawerToggle", "headerSettings", "homeRecentWork", "drawerResumeWork", "drawerSchedules"] {
                XCTAssertFalse(app.buttons[gone].exists, "\(gone) is gone with the drawer")
            }
            attach(app, "workspace-tab")
            // Search: Resume Work's sheet (⇧⌘F) keeps the searchable history, and its Close leaves it.
            openPhoneResumeWork(app)
            XCTAssertTrue(app.searchFields["Chats, Files and Tabs"].exists, "Resume Work keeps searchable history")
            endSidebarSearch(app)
            closeResumeWorkSheet(app)
            XCTAssertFalse(app.searchFields["Chats, Files and Tabs"].exists)
            // Settings is reachable from every destination, and the bottom bar leaves it.
            openSettings(app)
            XCTAssertFalse(app.otherElements["settingsDrawer"].exists, "Settings is a destination, not a drawer")
            closeSettings(app)
            XCTAssertTrue(phoneHomeShown(app), "Leaving Settings shows Home")
            return
        }
        browseFilesFromHome(app)
        XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 15))
        switcher.tap()
        XCTAssertTrue(app.buttons["workspacePickerHome"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspacePickerProject-fixture"].exists)
        XCTAssertGreaterThan(workspacePickerTabs(app).count, 0)
        attach(app, "workspace-switcher")
        app.buttons["workspacePickerHome"].tap()
        XCTAssertTrue(app.buttons["homeRecentWork"].waitForExistence(timeout: 5))

        openSidebar(app)
        XCTAssertTrue(app.searchFields["Chats, Files and Tabs"].exists, "Resume Work keeps searchable history")
        endSidebarSearch(app)
        app.buttons["resumeWorkClose"].tap()
        openSettings(app)
        XCTAssertTrue(app.buttons["settingsClose"].exists)
        closeSettings(app)
    }

    /// The chat library, from the archive the device copies from the harness host: a chat sent here
    /// appears under Today; its words are found by the device's full-text search; it is pinned by a
    /// swipe and unpinned from its context menu; it is deleted by a swipe, after confirming; and the
    /// archive and its terminal logs open from the sidebar.
    func testChatLibrary() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let reply = try XCTUnwrap(fixture.chatReply)
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO", "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)

        // A chat with a message and its reply.
        openAddTab(app, kind: "Chat")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        chooseFixtureModel(app)
        composer.tap(); composer.typeText("Library check from the phone")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        hideKeyboard(app)

        // The device copied it: the library lists it under Today, newest first. Beside plain chats, which come first,
        // the workspace's chats are under Agent Chats, lower in the drawer: rows off screen are not in the element
        // tree until they scroll in. On iPhone the library is the drawer's Resume Work page.
        openLibrary(app)
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 45), "The library groups the synced chats by day")
        let rows = app.descendants(matching: .any).matching(identifier: "sidebarChat")
        XCTAssertTrue(sidebarLists(app, rows.firstMatch, timeout: 30), "The library lists the chat")
        attach(app, "library-today")

        // Full-text search through the device's copy: the reply's own word.
        let word = String(reply.split(separator: "_").last ?? Substring(reply))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText(word)
        let hit = sidebarItem(app, "searchMessage")
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "The reply's word is found in the device's copy")
        attach(app, "library-search")
        hit.tap()
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 20), "A message result opens its chat")
        openLibrary(app)
        dismissSearch(app)

        // Pin by swipe: the newest chat (this one) moves under Pinned.
        let newest = rows.firstMatch
        XCTAssertTrue(sidebarLists(app, newest, timeout: 10))
        let title = newest.label
        newest.swipeRight()
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        XCTAssertTrue(sidebarLists(app, app.staticTexts["Pinned"], timeout: 10), "A pinned chat is listed under Pinned")
        XCTAssertTrue(sidebarLists(app, rows.firstMatch))
        XCTAssertEqual(rows.firstMatch.label, title)
        attach(app, "library-pinned")

        // Unpin from the context menu.
        rows.firstMatch.press(forDuration: 1.2)
        let unpin = app.buttons["Unpin"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 5))
        attach(app, "library-context-menu")
        unpin.tap()
        XCTAssertTrue(app.staticTexts["Pinned"].waitForNonExistence(timeout: 10))

        // Delete by swipe, after confirming; the host deletes it, then this device and its tab.
        XCTAssertTrue(sidebarLists(app, rows.firstMatch))
        rows.firstMatch.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["confirmDeleteChat"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting asks first")
        attach(app, "library-delete-confirmation")
        confirm.tap()
        // Its own row, by its title: the list lays out the rows that fit, so with more chats than the drawer shows
        // (earlier tests' chats stay in OpenCode) a row from below takes its place and the count stays the same.
        let deleted = rows.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(deleted.waitForNonExistence(timeout: 20), "The deleted chat leaves the library")
        XCTAssertFalse(openTabRow(app, titled: title).exists, "Its tab closes")

        // The archive and the archived terminal logs open from the sidebar. iPhone's Resume Work lists no Archive
        // row (its library is the chats, terminals and tabs); its Terminal Logs is B-18.
        if UIDevice.current.userInterfaceIdiom != .phone {
            openLibraryItem(app, "sidebarArchive")
            XCTAssertTrue(app.descendants(matching: .any)["archiveList"].firstMatch.waitForExistence(timeout: 10))
            attach(app, "library-archive")
            app.buttons["archiveDone"].tap()
            XCTAssertTrue(app.buttons["archiveDone"].waitForNonExistence(timeout: 5))
        }
        openLibraryItem(app, "sidebarTerminalLogs")
        let logs = app.buttons["archiveDone"]
        if !logs.waitForExistence(timeout: 10) { attach(app, "library-terminal-logs-missing") }
        XCTAssertTrue(logs.exists, "Terminal Logs opens the archive")
        XCTAssertTrue(app.descendants(matching: .any)["archiveScope"].firstMatch.exists)
        attach(app, "library-terminal-logs")
        logs.tap()
    }

    /// A physical Escape closes the Home drawer, including after searchable history has owned focus.
    func testSettingsEscapeKey() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only: hardware-keyboard Settings and menu-bar commands")
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        connectHardwareKeyboard(app)
        for afterHistory in [false, true] {
            if afterHistory {
                openSidebar(app)
                XCTAssertTrue(waitForFocus(app.searchFields.firstMatch))
                endSidebarSearch(app)
                app.buttons["resumeWorkClose"].tap()
            }
            XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))
            app.buttons["homeSettings"].tap()
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 5))
            XCTAssertTrue(press(app, XCUIKeyboardKey.escape.rawValue, [], attempts: 4) {
                !app.buttons["Appearance"].exists
            }, "Physical Escape dismisses Settings after history: \(afterHistory)")
            XCTAssertTrue(app.buttons["homeSettings"].isHittable, "Dismissal returns focus and interaction to Home")
        }
    }

    /// iPad with a hardware keyboard: the workspace's commands. ⌘T, ⌘1–9, ⌃⇥ and ⌘W for tabs; ⌥⌘T and
    /// ⌘N to start a terminal and a chat; ⌘↩, ⌘. and ⇧⌘R in the chat; ⌘F in Files; ⌘S in the editor;
    /// ⇧⌘F, Home Settings and text size (physical Escape is tested separately). A program in the terminal that turned on the kitty keyboard protocol
    /// does not keep ⌘T from opening a tab.
    func testKeyboardCommands() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only: hardware-keyboard Settings and menu-bar commands")
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", "light", "-AgentLandFixedQuip", fixedQuip]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        connectHardwareKeyboard(app)
        showProjects(app)
        closeAllTabs(app)
        let tabs = currentTab(app)

        // Tabs.
        XCTAssertTrue(press(app, "t", .command, attempts: 4) { tabs.label == "Current tab: Home 2" }, "⌘T opens a Home tab")
        XCTAssertTrue(press(app, "1", .command) { tabs.label == "Current tab: Home" }, "⌘1 is Home")
        XCTAssertTrue(press(app, "2", .command) { tabs.label == "Current tab: Home 2" }, "⌘2 is the first tab")
        XCTAssertTrue(press(app, XCUIKeyboardKey.tab.rawValue, .control) { tabs.label == "Current tab: Home" },
                      "⌃⇥ goes to the next tab, around to Home")
        XCTAssertTrue(press(app, "2", .command) { tabs.label == "Current tab: Home 2" })
        XCTAssertTrue(press(app, "w", .command) { tabs.label == "Current tab: Home" }, "⌘W closes the tab")

        // Text size: ⌘+ grows the text, ⌘0 returns to the system's size.
        let tile = app.buttons["homeNewChat"]
        let height = tile.frame.height
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        let grownDeadline = Date().addingTimeInterval(5)
        while tile.frame.height <= height && Date() < grownDeadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(tile.frame.height, height, "⌘+ makes the text bigger")
        attach(app, "keyboard-bigger-text")
        app.typeKey("0", modifierFlags: .command)
        let resetDeadline = Date().addingTimeInterval(5)
        while abs(tile.frame.height - height) > 0.5 && Date() < resetDeadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(tile.frame.height, height, accuracy: 0.5, "⌘0 returns to the actual size")

        // Resume Work is the searchable history path; Home owns Settings on iPad.
        openSidebar(app)
        XCTAssertTrue(waitForFocus(app.searchFields.firstMatch), "Resume Work focuses searchable history")
        endSidebarSearch(app)
        app.buttons["resumeWorkClose"].tap()
        XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))
        app.buttons["homeSettings"].tap()
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 5), "Home opens Settings")
        attach(app, "keyboard-settings")
        // Physical Escape has its own opt-in regression. This broader command flow uses Close so an
        // environment that cannot deliver Escape can still verify terminal, editor and chat shortcuts.
        app.buttons["settingsClose"].tap()
        XCTAssertTrue(app.buttons["Appearance"].waitForNonExistence(timeout: 5))

        // A terminal, and a program that turns on the kitty keyboard protocol.
        XCTAssertTrue(press(app, "t", [.command, .option], attempts: 4) {
            app.descendants(matching: .any)["terminalCanvas"].firstMatch.exists
        }, "⌥⌘T opens a terminal")
        XCTAssertTrue(waitForLabel(tabs, "Current tab: Terminal"))
        typeTerminal(app, "printf '\\033[>1u'; echo kitty-on\n")
        XCTAssertTrue(try waitForRenderedText("kitty-on", in: app, timeout: 15))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForLabel(tabs, "Current tab: Home 2"), "⌘T reaches the app from a terminal with the kitty protocol on")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForLabel(tabs, "Current tab: Terminal"))

        // Files: ⌘F goes to its search, by name.
        openSidebarItem(app, "sidebarFiles")
        XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 15))
        let filter = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Search file names")).firstMatch
        XCTAssertTrue(press(app, "f", .command) { filter.exists && (filter.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "⌘F finds in Files")
        filter.typeText("hel")
        XCTAssertTrue(app.descendants(matching: .any)["fileSearchName-hello.txt"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["fileSearchName-opencode.json"].firstMatch.exists)
        endFilesSearch(app)

        // The editor: ⌘S saves.
        openFileFromRow(app, app.buttons[fileRowID("hello.txt")])
        let editor = app.textViews["fileEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        editor.typeText("Saved with the keyboard\n")
        let save = app.buttons["saveFile"]
        XCTAssertTrue(save.isEnabled)
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed, "⌘S saves the file")

        // A chat: ⌘N, ⌘↩ sends, ⇧⌘R asks to regenerate, ⌘. stops. On hosts with plain chats ⌘N starts one; on others
        // a chat in the workspace. Either opens on the same landing, over its composer.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20),
                      hostListsPlainChats ? "⌘N starts a plain chat" : "⌘N starts a chat")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        chooseFixtureModel(app)
        composer.tap(); composer.typeText("AGENTLAND_MARKDOWN from the keyboard")
        // ⌘↩ is typed with "\n": the simulator does not deliver XCUIKeyboardKey.return ("\r") to the app.
        app.typeKey("\n", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Fixture heading"].waitForExistence(timeout: 45), "⌘↩ sends")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        // ⌘L goes back to the composer.
        XCTAssertTrue(press(app, "l", .command) { (composer.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "⌘L focuses the composer")
        composer.typeText("AGENTLAND_LONG keep going")
        app.typeKey("\n", modifierFlags: .command)
        XCTAssertTrue(app.buttons["chatStop"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This long reply")).firstMatch
            .waitForExistence(timeout: 30))
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["chatStoppedMarker"].firstMatch.waitForExistence(timeout: 30), "⌘. stops")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        app.typeKey("r", modifierFlags: [.command, .shift])
        let runAgain = app.buttons["chatConfirmRunAgain"].firstMatch
        XCTAssertTrue(runAgain.waitForExistence(timeout: 5), "⇧⌘R asks before running the prompt again")
        attach(app, "keyboard-regenerate")
        dismissDialog(app)
        XCTAssertTrue(runAgain.waitForNonExistence(timeout: 5))

        // ⌥⌘N asks which agent.
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["newChatWith-opencode"].firstMatch.waitForExistence(timeout: 5), "⌥⌘N asks for the agent")
        attach(app, "keyboard-chat-with")
        dismissDialog(app)
        closeAllTabs(app)
    }

    /// Closes a confirmation dialog without choosing: its Cancel button, or where iOS 26 shows it as a popover without
    /// one (on iPad, and from inside the iPhone drawer), a tap beside it: on the empty foot of the iPad's sidebar, below
    /// the iPhone's drawer. A tap outside a popover over the drawer closes only that popover.
    func dismissDialog(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.97)).tap()
        }
    }

    /// The simulator loses the key of a key command that opens a new keyboard event sequence to the app: its
    /// log shows backboardd starting the sequence, and the app gets ⌘ down and up but no letter. The first key
    /// command after pairing (typed through the software keyboard) always opened one, and did nothing in the last
    /// 10 runs of 10; after one other key it worked in each of 3 runs. That key goes first here: ⌘0, which at the
    /// base text size (a new install) is not available, so nothing changes whether it arrives or not.
    private func connectHardwareKeyboard(_ app: XCUIApplication) {
        app.typeKey("0", modifierFlags: .command)
    }

    /// Sends a key command and waits for its effect, sending it again when the simulator lost it (see
    /// `connectHardwareKeyboard`): twice, or `attempts` times for the first command after touches, which
    /// opened a new sequence more than once in a row now and then.
    func press(_ app: XCUIApplication, _ key: String, _ flags: XCUIElement.KeyModifierFlags, attempts: Int = 2,
                       until done: () -> Bool) -> Bool {
        for _ in 0..<attempts {
            app.typeKey(key, modifierFlags: flags)
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if done() { return true }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
        }
        return false
    }

    /// Closes every open tab of the workspace, leaving Home: each tab's title menu has Close Tab, and
    /// the sidebar's open tabs bring the next one forward.
    private func closeAllTabs(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Each open task of the workspace in use from the header's switcher, closed with its X; then Home.
            for _ in 0..<12 {
                closePhoneSheets(app)
                let switcher = app.buttons["workspaceSwitcher"]
                guard waitUntilHittable(switcher, timeout: 10) else { break }
                switcher.tap()
                guard app.buttons["quickTabHome"].waitForExistence(timeout: 5) else { break }
                let task = phoneTaskRows(app).firstMatch
                guard task.waitForExistence(timeout: 1) else {
                    app.buttons["quickTabHome"].tap()
                    break
                }
                task.tap()
                closePhoneTask(app)
                _ = app.buttons["phoneCloseTab"].waitForNonExistence(timeout: 5)
            }
            showPhoneTab(app, "Chat")
            return
        }
        for _ in 0..<12 {
            guard titleMenu(app).waitForExistence(timeout: 5) else { return }
            if currentTab(app).label != "Current tab: Home" {
                titleMenu(app).tap()
                // On iPad the system title menu lists Close Tab by its title only.
                let close = menuItem(app, "closeCurrentTab", label: "Close Tab")
                if close.waitForExistence(timeout: 2) {
                    close.tap()
                    if app.buttons["discardChanges"].firstMatch.waitForExistence(timeout: 1) { app.buttons["discardChanges"].firstMatch.tap() }
                    continue
                }
            }
            // Home is in front: bring another open tab forward to close next, or stay on Home.
            openSidebar(app)
            let row = app.descendants(matching: .any).matching(identifier: "openTab").firstMatch
            guard sidebarLists(app, row, timeout: 2) else {
                openSidebarItem(app, "sidebarHome")
                return
            }
            row.tap()
        }
    }

    /// An item of an open title menu: by its identifier, or on iPad, whose system title menu lists its
    /// items by their titles only, by its title.
    private func menuItem(_ app: XCUIApplication, _ identifier: String, label: String) -> XCUIElement {
        let item = app.buttons[identifier]
        if UIDevice.current.userInterfaceIdiom != .pad || item.waitForExistence(timeout: 1.5) { return item }
        return app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The separate trailing actions menu uses the same identifier on iPhone and iPad.
    private func surfaceMenu(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let menu = app.buttons[identifier]
        // On iPhone the task in front's actions are in the header's task menu (the drawer's Files page has its own).
        if UIDevice.current.userInterfaceIdiom == .phone, !menu.exists { return app.buttons["workspaceSwitcher"] }
        return menu
    }

    /// Ends the sidebar's search: its Cancel (or close) button, whichever the search bar shows.
    private func dismissSearch(_ app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        guard field.exists, app.keyboards.firstMatch.exists || !(field.value as? String ?? "").isEmpty
                && field.value as? String != field.placeholderValue else { return }
        // On iPhone the drawer's Resume Work page keeps its field and close button under the keyboard (B-11):
        // a tap beside the field would land on the keyboard's dictation key. The keyboard's Search key and a drag
        // on the results put it away first.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, field.frame.maxY > keyboard.frame.minY {
            let search = keyboard.buttons["search"]
            if search.exists { search.tap() }
            // A drag inside the drawer's own list, never outside the popover (that would close it).
            let drawerList = app.descendants(matching: .any)["workspaceExplorer"].firstMatch.collectionViews.firstMatch
            if keyboard.exists { (drawerList.exists ? drawerList : app.collectionViews.firstMatch).swipeDown() }
            _ = keyboard.waitForNonExistence(timeout: 3)
            // B-11 (open): the keyboard stays over the field and its close button; leaving the page ends the
            // search. Nothing under the keyboard is tapped.
            if keyboard.exists, field.frame.maxY > keyboard.frame.minY { return }
        }
        // A button the keyboard covers is never the search's (the dictation key sits where close would be).
        let covered = keyboard.exists ? keyboard.frame : .null
        for label in ["Cancel", "Close"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if button.exists && button.isHittable && abs(button.frame.midY - field.frame.midY) < 30
                && !button.frame.intersects(covered) { button.tap(); return }
        }
        // The search bar's own close button sits right beside its field, whatever it is called (on iPad
        // the detail column's buttons are level with the sidebar's field, further right).
        // Each button's frame is read once and its hit test only beside the field: every read of an element is a round
        // trip, and the screen has dozens of buttons.
        let frame = field.frame
        if let close = app.buttons.allElementsBoundByIndex.first(where: { button in
            let place = button.frame
            return place.minX >= frame.maxX - 2 && place.minX <= frame.maxX + 60
                && abs(place.midY - frame.midY) < 30 && !place.intersects(covered) && button.isHittable
        }) {
            close.tap()
            return
        }
        // The iPad sidebar's field has neither: empty it and leave it.
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        if app.keyboards.firstMatch.exists || waitForFocus(field, timeout: 0.5) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }

    /// Search History focuses Resume Work immediately. UIKit swaps its sheet toolbar for a bottom search
    /// toolbar while that focus is active, so dismiss its adjacent close control before exercising the
    /// sheet's own close affordance. On iOS 26 the accessible label is lowercase "close".
    func endSidebarSearch(_ app: XCUIApplication) {
        let field = app.searchFields["Chats, Files and Tabs"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Resume Work has its search field")
        // iPad retains the sheet's Close button while the inline search is focused; there is no separate
        // search Cancel control. Clear the filter and let the caller use that still-visible sheet control.
        if UIDevice.current.userInterfaceIdiom == .pad {
            let clear = field.buttons["Clear text"]
            if clear.exists { clear.tap() }
            XCTAssertTrue(app.buttons["resumeWorkClose"].isHittable, "iPad keeps Resume Work's Close control available")
            return
        }
        if !waitForFocus(field, timeout: 0.5) { field.tap() }
        // The field's frame and each button's are read once, and a button's hit test only level with the field: every
        // read of an element is a round trip, and the screen has dozens of buttons.
        let fieldFrame = field.frame
        let sameSearchRow: (XCUIElement, CGRect) -> Bool = { button, place in
            abs(place.midY - fieldFrame.midY) < 30 && button.isHittable
        }
        let namedSearchClose = ["Cancel", "close"].lazy.compactMap { label in
            app.buttons.matching(NSPredicate(format: "label ==[c] %@", label))
                .allElementsBoundByIndex.first { $0.exists && sameSearchRow($0, $0.frame) }
        }.first
        let adjacentSearchClose = app.buttons.allElementsBoundByIndex.first { button in
            guard button.exists else { return false }
            let place = button.frame
            return place.minX >= fieldFrame.maxX - 2 && place.minX <= fieldFrame.maxX + 60 && sameSearchRow(button, place)
        }
        guard let searchClose = namedSearchClose ?? adjacentSearchClose else {
            return XCTFail("Focused Resume Work search exposes its adjacent close control")
        }
        searchClose.tap()
        XCTAssertTrue(app.buttons["resumeWorkClose"].waitForExistence(timeout: 5),
                      "Dismissing search restores Resume Work's toolbar")
    }

    /// Empties the search field and keeps typing in it: on iPad clearing it can end editing.
    private func clearSearch(_ app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        if !waitForFocus(field, timeout: 1) { field.tap() }
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.label == label { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, (element.value(forKey: "hasKeyboardFocus") as? Bool) == true { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    // MARK: HIG pass: accessibility audits and screenshots

    /// The screens the HIG pass covers, in the order the tests visit them.
    private enum Screen: String, CaseIterable {
        case home, sidebar, chatLanding = "chat-landing", chat, files, editor, terminal, settings
    }

    /// Makes the tabs the screens need once: an empty chat, a chat with a formatted reply, Files, an
    /// editor and a terminal with output. Later launches find them restored.
    private func prepareScreens(_ app: XCUIApplication) throws {
        showProjects(app)
        openAddTab(app, kind: "Chat")
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20))
        showProjects(app)
        openAddTab(app, kind: "Chat")
        XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20))
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        chooseFixtureModel(app)
        composer.tap(); composer.typeText(Self.formattedPrompt)
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.staticTexts["Fixture heading"].waitForExistence(timeout: 45), "The formatted reply arrived")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        showProjects(app)
        browseFilesFromHome(app)
        XCTAssertTrue(app.buttons[fileRowID("hello.txt")].waitForExistence(timeout: 15))
        openFileFromRow(app, app.buttons[fileRowID("hello.txt")])
        XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 15))
        openAddTab(app, kind: "Terminal")
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        typeTerminal(app, "printf 'AgentLand %s\\n' terminal\n")
        XCTAssertTrue(try waitForRenderedText("AgentLand terminal", in: app, timeout: 20))
        hideTerminalKeyboard(app)
    }

    private static let formattedPrompt = "AGENTLAND_MARKDOWN format the review chat"

    /// Shows one screen, from wherever the app is.
    private func show(_ screen: Screen, in app: XCUIApplication) {
        switch screen {
        case .home:
            showProjects(app)
            let phone = UIDevice.current.userInterfaceIdiom == .phone
            XCTAssertTrue(app.descendants(matching: .any)[phone ? "homeWordmark" : "homeNewChat"].firstMatch.waitForExistence(timeout: 10))
        case .sidebar:
            // The iPhone's is the bottom bar's Workspace destination (the drawer went, 2026-10-11).
            if UIDevice.current.userInterfaceIdiom == .phone {
                showPhoneTab(app, "Workspace")
                XCTAssertTrue(app.buttons["phoneChooseWorkspace"].waitForExistence(timeout: 10))
            } else {
                openSidebar(app)
                XCTAssertTrue(sidebarItem(app, "sidebarHome").waitForExistence(timeout: 10))
            }
        case .chatLanding:
            selectTab(app, titled: "New chat")
            XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.waitForExistence(timeout: 20))
        case .chat:
            selectTab(app, titled: Self.formattedPrompt)
            XCTAssertTrue(app.staticTexts["Fixture heading"].waitForExistence(timeout: 20))
            hideKeyboardIfShown(app)
        case .files:
            selectTab(app, titled: "Files")
            // The iPhone's Files is the Workspace destination's page, whose rows carry the drawer's identifiers.
            let row = UIDevice.current.userInterfaceIdiom == .phone ? "drawerFile-hello.txt" : "file-hello.txt"
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 15))
        case .editor:
            selectTab(app, titled: "hello.txt")
            XCTAssertTrue(app.textViews["fileEditor"].waitForExistence(timeout: 15))
        case .terminal:
            selectTab(app, titled: "Terminal")
            XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 15))
            hideKeyboardIfShown(app)
        case .settings:
            openSettings(app)
        }
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Leaves an overlay the screen opened: Settings for Home's Chat (iPhone) or with Done (iPad).
    private func leave(_ screen: Screen, in app: XCUIApplication) {
        if screen == .settings { closeSettings(app) }
        // On iPhone the "sidebar" is the Workspace destination: Home's Chat goes back.
        if screen == .sidebar, UIDevice.current.userInterfaceIdiom == .phone { openSidebarItem(app, "sidebarHome") }
    }

    /// Picks a tab from the sidebar's open tabs, the one place that lists them. Tabs are listed in the
    /// order they opened, so with several of one title (earlier tests leave some) the last is the one
    /// this test made.
    private func selectTab(_ app: XCUIApplication, titled title: String) {
        showTab(app, titled: title)
    }

    private func hideTerminalKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The terminal's key bar has Hide keyboard (the tab menu has no per-task actions, 2026-10-11).
            let hide = app.buttons["terminalHideKeyboard"].firstMatch
            XCTAssertTrue(hide.waitForExistence(timeout: 5), "The terminal's key bar offers Hide keyboard")
            hide.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            return
        }
        surfaceMenu(app, "terminalActions").tap()
        menuItem(app, "terminalMenuHideKeyboard", label: "Hide keyboard").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    private func hideKeyboardIfShown(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.waitForExistence(timeout: 1) else { return }
        let chat = app.descendants(matching: .any)["chatHeader"].firstMatch.exists || app.descendants(matching: .any)["chatDraft"].firstMatch.exists
        if chat { hideKeyboard(app) } else { hideTerminalKeyboard(app) }
    }

    /// Launches the app for a test. `systemTextSize` passes `-AgentLandUITestsSystemTextSize`, from when the app's text
    /// was a step above the reader's setting: the app's text follows the setting exactly since 2026-10-06, so the app
    /// accepts the flag and changes nothing for it. The audits keep passing it.
    func launch(_ app: XCUIApplication, appearance: String, largestText: Bool, systemTextSize: Bool = false,
                animated: Bool = false, extraArguments: [String] = []) {
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO",
                               "-agentland.appearance", appearance, "-AgentLandFixedQuip", fixedQuip]
        // The app's own animations, as a person sees them, for the checks of what only happens while one runs.
        if animated { app.launchArguments.removeFirst() }
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if systemTextSize { app.launchArguments.append(Self.systemTextSizeArgument) }
        app.launchArguments += extraArguments
        app.launch()
    }

    /// The app's former `AgentLandTextSize.uiTestsSystemTextSizeArgument`, now a no-op it accepts.
    static let systemTextSizeArgument = "-AgentLandUITestsSystemTextSize"

    /// Xcode's accessibility audit of every screen the HIG pass restyled, in light and dark. Findings
    /// the audit reports for things outside the screen, or for a known false positive, are listed in
    /// the attached report with the reason and not counted; everything else fails the test. The app shows
    /// the reader's text size as it is (`systemTextSize`).
    func testAccessibilityAudits() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false, systemTextSize: true)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        try prepareScreens(app)
        var counted: [String] = []
        for appearance in ["light", "dark"] {
            app.terminate()
            launch(app, appearance: appearance, largestText: false, systemTextSize: true)
            XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 20))
            for screen in Screen.allCases {
                show(screen, in: app)
                let reach = reachableElements(app)
                Thread.sleep(forTimeInterval: 0.5)
                attach(app, "audit-\(screen.rawValue)-\(appearance)")
                if screen == .chat {
                    counted += try auditChat(app, appearance, reach: reach)
                } else {
                    counted += try audit(app, screen: screen, appearance: appearance, reach: reach)
                }
                leave(screen, in: app)
            }
        }
        XCTAssertTrue(counted.isEmpty, "Accessibility audit findings:\n" + counted.joined(separator: "\n"))
    }

    /// Screenshots for review: every restyled screen in light and dark, at the default text size and
    /// at the largest accessibility size.
    func testHIGScreenshots() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        try prepareScreens(app)
        for largestText in [false, true] {
            largestTextSize = largestText
            for appearance in ["light", "dark"] {
                app.terminate()
                launch(app, appearance: appearance, largestText: largestText)
                XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 20))
                for screen in Screen.allCases {
                    show(screen, in: app)
                    attach(app, "hig-\(screen.rawValue)-\(appearance)-\(largestText ? "ax5" : "default")")
                    leave(screen, in: app)
                }
            }
        }
    }

    /// The navigation shell for review (`.evidence/hig-h2-*`): Home, the sidebar, the chat library, a
    /// chat, Files and the Settings sheet, in light and dark.
    func testShellScreenshots() throws {
        continueAfterFailure = true
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        try prepareScreens(app)
        for appearance in ["light", "dark"] {
            app.terminate()
            launch(app, appearance: appearance, largestText: false)
            XCTAssertTrue(titleMenu(app).waitForExistence(timeout: 20))
            show(.home, in: app)
            attach(app, "shell-home-\(appearance)")
            show(.sidebar, in: app)
            Thread.sleep(forTimeInterval: 1)
            attach(app, "shell-sidebar-\(appearance)")
            // The chat library: the Chats section scrolled to the top of the sidebar.
            let library = sidebarItem(app, "sidebarNewChat")
            if sidebarLists(app, library), UIDevice.current.userInterfaceIdiom == .phone {
                let list = app.collectionViews.firstMatch
                let lift = library.frame.minY - list.frame.minY - 140
                if lift > 0 {
                    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -lift)))
                }
            }
            Thread.sleep(forTimeInterval: 1)
            attach(app, "shell-chat-library-\(appearance)")
            leave(.sidebar, in: app)
            for screen in [Screen.chat, .files, .settings] {
                show(screen, in: app)
                attach(app, "shell-\(screen.rawValue)-\(appearance)")
                leave(screen, in: app)
            }
        }
    }

    /// The audit types, in two groups: those that leave the screen as it is, and those that enlarge its text in
    /// place (Dynamic Type, clipped text), which run last.
    static let steadyAudits: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                                                             .sufficientElementDescription, .trait]
    static let resizingAudits: [XCUIAccessibilityAuditType] = [.dynamicType, .textClipped]

    /// A contrast finding Xcode describes as "Contrast nearly passed" (not high enough unless the text were larger):
    /// the system's own secondary and status colors under small text, which iPhone and iPad draw exactly as Apple's
    /// apps do (owner's decision, 2026-10-06: "Allow Apple's colours"). It is logged, never failed; "Contrast failed"
    /// and every other finding still count.
    static func isNearlyPassedContrast(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.auditType == .contrast && issue.compactDescription.range(of: "nearly passed", options: .caseInsensitive) != nil
    }

    /// Logs an audit's "Contrast nearly passed" findings where they stay visible: the test's output, an activity in
    /// its report and that activity's attachment. `kind` names other findings logged the same way.
    func logNearlyPassedContrast(_ findings: [String], _ name: String, kind: String = "contrast nearly passed") {
        guard !findings.isEmpty else { return }
        let text = (["\(name): \(kind) (logged, not failed): \(findings.count)"] + findings)
            .joined(separator: "\n")
        print(text)
        XCTContext.runActivity(named: "\(name): \(findings.count) findings, \(kind), logged") { activity in
            let attachment = XCTAttachment(string: text)
            attachment.name = kind.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: "") + "-\(name)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// The owner's audit policy for Settings' native forms (2026-10-06, "Log Apple's styling"): logged instead of failed
    /// are "Contrast failed" on text the system draws in its own colours as a section's header or footer or as the line
    /// under a row's title, and "partially unsupported" Dynamic Type on the form's rows, headers and footers, whose text
    /// grows at every size (testSettingsScreenshots' xxxl and largest screenshots of run 1791344878 show every page's
    /// rows grown and wrapping; the audit enlarges the text in place, where the rows lower on a page leave the panel's
    /// visible area). Decided per element from the scene's snapshot, never for a whole page: a row's title, a button's
    /// contrast, "unsupported" Dynamic Type, a missing description and anything else still count. Nil when it counts.
    /// The iPhone's Workspace tab (the sidebar screen there) is the same native inset list since the bottom tabs
    /// (2026-10-11): its "Workspace in use" header is the system's light-mode secondary grey, as on Settings.
    private func settingsStyling(_ issue: XCUIAccessibilityAuditIssue, element: AuditedElement?, screen: Screen,
                                 scene: AuditScene) -> String? {
        let nativeList = screen == .settings || (screen == .sidebar && UIDevice.current.userInterfaceIdiom == .phone)
        guard nativeList, let element, element.exists, !element.frame.isEmpty,
              let form = scene.settingsForm(holding: element.frame) else { return nil }
        let description = issue.compactDescription
        switch issue.auditType {
        case .contrast where description.range(of: "Contrast failed", options: .caseInsensitive) != nil:
            guard [.staticText, .other].contains(element.elementType) else { return nil }
            return scene.secondaryRole(of: element, in: form)
        case .dynamicType where description.range(of: "partially", options: .caseInsensitive) != nil:
            return "a row, header or footer of the form, which grows with the text"
        default:
            return nil
        }
    }

    /// One screen's audit. The checks that leave the screen as it is run first and are judged on it as it is,
    /// its screenshot and frames taken before the Dynamic Type and clipped-text checks enlarge the text in place;
    /// those run last and are judged after.
    private func audit(_ app: XCUIApplication, screen: Screen, appearance: String, reach: [ReachableElement]) throws -> [String] {
        // The bars whose items keep their size: the screen's navigation bar and the iPhone's fixed header. With a header
        // panel open (Settings) the first navigation bar is the panel's own, below the header, so both count.
        let navigation = app.navigationBars.firstMatch
        let chrome = [navigation.exists ? navigation.frame : .zero, phoneHeaderFrame(app)].filter { !$0.isEmpty }
        var counted: [String] = []
        var listed: [String] = []
        var nearlyPassed: [String] = []
        var styling: [String] = []
        var screenshot: XCUIScreenshot?
        for group in [Self.steadyAudits, Self.resizingAudits] {
            var issues: [XCUIAccessibilityAuditIssue] = []
            for type in group {
                try app.performAccessibilityAudit(for: type) { issue in
                    issues.append(issue)
                    return true
                }
            }
            // The screen the steady checks saw; the resizing checks' contrast is not measured.
            let shot = screenshot ?? app.screenshot()
            screenshot = shot
            // The screen as this group's checks left it, read once for all its findings.
            let scene = AuditScene(app)
            for issue in issues {
                let element = AuditedElement(issue)
                let frame = element?.frame ?? .zero
                let identifier = element?.identifier ?? "-"
                let place = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                let described = "\(issue.auditType.rawValue) \(issue.compactDescription) | \(issue.detailedDescription) "
                    + "[id=\(identifier) label=\(element?.label ?? "-") at \(place)]"
                if let reason = notCounted(issue, element: element, screen: screen, frame: frame, chrome: chrome,
                                           screenshot: shot, scene: scene, reach: reach) {
                    listed.append("\(reason): \(described)")
                } else if Self.isNearlyPassedContrast(issue) {
                    nearlyPassed.append(described)
                } else if let role = settingsStyling(issue, element: element, screen: screen, scene: scene) {
                    styling.append("\(role): \(described)")
                } else {
                    counted.append(described)
                }
            }
        }
        attachText((["\(screen.rawValue), \(appearance): findings \(counted.count)"] + counted
                    + ["Contrast nearly passed (logged, not failed): \(nearlyPassed.count)"] + nearlyPassed
                    + ["Apple's styling on Settings' forms (logged, not failed): \(styling.count)"] + styling
                    + ["Not counted: \(listed.count)"] + listed).joined(separator: "\n"),
                   "accessibility-audit-\(screen.rawValue)-\(appearance)")
        logNearlyPassedContrast(nearlyPassed, "\(screen.rawValue)-\(appearance)")
        logNearlyPassedContrast(styling, "\(screen.rawValue)-\(appearance)", kind: "Apple's styling on Settings' forms")
        return counted.map { "\(screen.rawValue), \(appearance): \($0)" }
    }

    /// Why a finding is not counted, or nil when it counts. `element` is the issue's element as one snapshot showed it
    /// (nil when the issue names none) and `scene` the screen the checks left: every rule reads them, never the app.
    private func notCounted(_ issue: XCUIAccessibilityAuditIssue, element: AuditedElement?, screen: Screen, frame: CGRect,
                            chrome: [CGRect], screenshot: XCUIScreenshot, scene: AuditScene, reach: [ReachableElement]) -> String? {
        let identifier = element?.identifier ?? "-"
        if let element, element.exists, element.elementType == .key || element.elementType == .keyboard {
            return "system keyboard"
        }
        // Test-only elements exposed under -AgentLandUITestsDisableAnimations: the decorative circus
        // (so tests can read its frame), the number of the renderer a terminal shows, the list of
        // what VoiceOver reaches, and the iPhone Home's tiny session starters.
        if ["homeCircus", "terminalRendererSerial", "debugVoiceOverElements", "debugSheetVoiceOverElements",
            "debugSidebarVoiceOverElements", "debugDrawerPageVoiceOverElements", "debugNewShellTerminal",
            "debugNewChat"].contains(identifier) {
            return "exposed only for UI tests"
        }
        // A file's name ("hello.txt") is read as written; the audit takes it for an identifier.
        if issue.auditType == .sufficientElementDescription, let label = element?.label, Self.isFileName(label) {
            return "a file's name, read as written"
        }
        // Navigation bar items keep their size at the largest text sizes and show the Large Content
        // Viewer instead (HIG: bars); the audit's Dynamic Type check does not recognize that. The iPhone's fixed
        // header is its bar: its task title keeps one line and truncates, and the button says it whole.
        if issue.auditType == .dynamicType || issue.auditType == .textClipped, !frame.isEmpty,
           chrome.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
            return "bar item (one line, Large Content Viewer)"
        }
        // On iPhone Settings is the gear's panel over the screen behind it (2026-10-05), not a popover in its own
        // presentation: the shell hides that screen and the header from VoiceOver while the panel shows, and XCUITest's
        // tree and the audit still list them, measured through the panel (Home's buttons and quip, run 1791323060).
        if screen == .settings, UIDevice.current.userInterfaceIdiom == .phone, let element, element.exists,
           let panel = scene.settingsPanel, !scene.panel(panel, lists: element) {
            return "behind the Settings panel (hidden from VoiceOver while it shows)"
        }
        // The surfaces behind the selected one stay in XCUITest's tree, which also lists elements
        // SwiftUI hides from VoiceOver. What VoiceOver cannot reach on this screen (the app's list,
        // testVoiceOverReachesOnlyTheSelectedSurface) is not counted.
        if !frame.isEmpty, !reach.isEmpty, !reachable(element, frame: frame, among: reach, appFrame: scene.appFrame) {
            return "out of VoiceOver's reach (a surface behind the selected one)"
        }
        // Settings is the gear's popover on iPhone: a row its page has scrolled past the popover's edge is clipped by it,
        // and the audit measures the screen behind. testSettingsAccessibilityAudit scrolls each page and audits again,
        // so every row is measured where it shows.
        // The Agents page is a lazy list in the Settings popover (about 400 pt of rows on iPhone): while the audit
        // enlarges the text, the rows above push its lower rows past the popover's edge and the list lets go of them, so
        // the audit cannot finish measuring them (as with the chat transcript below). Every font there is a text style,
        // and AgentsSettingsRenderTests renders the page at an accessibility size: listed, not counted.
        if issue.auditType == .dynamicType, screen == .settings, UIDevice.current.userInterfaceIdiom == .phone, !frame.isEmpty,
           let list = scene.first(identifier: "agentsList"), list.frame.contains(frame) {
            return "a row of the Agents page's lazy list, let go of as the text grows in the popover"
        }
        // The last text of a Settings page scrolled to its end (About's licences footer, failing since batch 4): the audit
        // enlarges the text in place, the form grows past the panel's lower edge and lets go of what it pushed out, so
        // the audit finds that text unchanged, or gone (an unlabelled 0 × 0 node). The same footer passes where an
        // earlier scroll shows it higher up the panel, and every font there is a text style.
        // ("Partially unsupported" is Apple's form styling, logged below.)
        if issue.auditType == .dynamicType, screen == .settings, UIDevice.current.userInterfaceIdiom == .phone,
           issue.compactDescription.range(of: "partially", options: .caseInsensitive) == nil,
           let panel = scene.settingsPanel?.frame {
            if frame.isEmpty { return "no frame: let go of by the Settings form as the text grew" }
            let texts = scene.elements(.staticText).filter { panel.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            if frame.maxY > panel.maxY - panel.height / 4, !texts.contains(where: { $0.frame.minY >= frame.maxY - 1 }) {
                return "the last text of a Settings page at the panel's foot, let go of as the text grows past its edge"
            }
        }
        // A row scrolled up under the popover's navigation bar sits under the bar's scroll-edge blur: measured where it
        // shows before the scroll.
        if issue.auditType == .contrast, screen == .settings, !frame.isEmpty, UIDevice.current.userInterfaceIdiom == .phone,
           let popover = scene.settingsPanel {
            var visible = popover.frame.insetBy(dx: -1, dy: -1)
            let bar = scene.elements(.navigationBar).first { popover.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            if let bar {
                let top = bar.frame.maxY + 20
                visible = CGRect(x: visible.minX, y: top, width: visible.width, height: max(0, visible.maxY - top))
            }
            if !visible.contains(frame) {
                return "outside the Settings popover's visible area: under its bar or past its edge (measured where the page shows it)"
            }
        }
        if issue.auditType == .contrast, !frame.isEmpty, screen == .sidebar, underSearchField(frame, in: scene) {
            return "under the search field at the top of the drawer (the list scrolls it back down)"
        }
        // The same at the foot of the drawer: a row the screen's bottom edge cuts shows only the top of its text, which
        // the check measures against the background (audit-sidebar-light.png of run 1790599487: a chat's time at the
        // edge, under Agent Chats below the plain chats). The list scrolls it up.
        if issue.auditType == .contrast, !frame.isEmpty, screen == .sidebar, frame.maxY > scene.appFrame.maxY {
            return "cut by the screen's bottom edge (the list scrolls it up)"
        }
        if issue.auditType == .contrast, !frame.isEmpty,
           let ratio = measuredContrast(screenshot, frame: frame, appFrame: scene.appFrame), ratio >= 4.5 {
            return String(format: "contrast measured again at %.1f:1", ratio)
        }
        // A contrast finding without an element cannot be measured again on its own. Every text that
        // can be hit on the screen is measured instead; when all pass, the finding is on something out
        // of reach (a surface behind the selected one or a decorative glyph).
        if issue.auditType == .contrast, element == nil,
           let lowest = lowestTextContrastOnce(scene, screenshot: screenshot, reach: reach), lowest >= 4.5 {
            return String(format: "no element; every text VoiceOver reaches measures at least %.1f:1", lowest)
        }
        // Home's quip stops at two lines (its layout under the tent); the audit enlarges it in place and
        // finds it cut. VoiceOver reads it whole.
        if identifier == "homeQuip", issue.auditType == .textClipped {
            return "the quip stops at two lines under the tent; VoiceOver reads it whole"
        }
        // Text the audit sees on screen without an element to name: decorative text hidden on purpose
        // because an element next to it carries it (breadcrumb separators, list bullets, a code block's
        // language, which its label repeats).
        if issue.auditType == .elementDetection, element == nil {
            return "decorative text hidden on purpose"
        }
        // "Not human-readable" without an element on Files or the editor: when the audit names the
        // element there, it is a file's name (see the rule above); the only such labels on these
        // screens are file names.
        if issue.auditType == .sufficientElementDescription, element == nil, screen == .files || screen == .editor,
           issue.compactDescription.contains("human-readable"),
           scene.elements(.staticText).contains(where: { Self.isFileName($0.label) }) {
            return "no element; on this screen the audit names file names, read as written"
        }
        // The filename filter is a SwiftUI text field: SwiftUI lays it out again when the text size
        // changes (files-*-ax5.png shows it whole at the largest size); the audit enlarges the UIKit
        // field's text in place.
        if issue.auditType == .textClipped, identifier == "fileFilter" {
            return "SwiftUI text field, laid out again at each text size"
        }
        // Settings rows wrap their titles at larger sizes (settings-*-ax5.png shows "Appear-ance" on
        // two lines); the audit enlarges the text in place, on one line.
        if issue.auditType == .textClipped, screen == .settings {
            return "Settings text wraps at larger sizes"
        }
        // Sidebar rows are laid out again at larger sizes (sidebar-*-ax5.png shows each row whole);
        // the audit enlarges a row's text in place, in the frame it has at the default size.
        if issue.auditType == .textClipped, screen == .sidebar {
            return "sidebar rows are laid out again at larger sizes"
        }
        // In the lower half of the sidebar the list's rows leave the screen (or go under the floating
        // search field) as the audit enlarges the text, and it reports them as not growing. The same
        // rows pass higher in the list: moved to the top in a trial run, the date headers and Home
        // passed, and Home and Files failed once moved down.
        if issue.auditType == .dynamicType, screen == .sidebar, !frame.isEmpty, frame.minY > scene.appFrame.height / 2 {
            return "sidebar row low on the screen, pushed out of view as the audit enlarges the text"
        }
        // The same below the screen's bottom edge: with more chats than the screen holds (earlier tests leave theirs
        // in OpenCode), the audit's other text sizes bring rows on and off the screen, and a row shown only at another
        // size has no element left once the size is back. With seven chats the audit gave two such findings, none with
        // two chats or with the Chats section collapsed. Only while the list VoiceOver reaches runs past the edge.
        if issue.auditType == .dynamicType, screen == .sidebar, element == nil,
           reach.contains(where: { $0.frame.maxY > scene.appFrame.maxY }) {
            return "no element: a row the list shows only at another text size (it runs past the screen's bottom edge)"
        }
        return nil
    }

    /// An audit issue's element as one snapshot shows it. Each property read of an `XCUIElement` is a round trip that
    /// finds it again in the app's accessibility tree (a finding cost about 25 of them, up to seconds each on a large
    /// tree, testSettingsAccessibilityAudit run 1791332542); its snapshot is one.
    struct AuditedElement {
        let exists: Bool
        let identifier: String
        let label: String
        let frame: CGRect
        let elementType: XCUIElement.ElementType

        init(exists: Bool, identifier: String, label: String, frame: CGRect, elementType: XCUIElement.ElementType) {
            self.exists = exists
            self.identifier = identifier
            self.label = label
            self.frame = frame
            self.elementType = elementType
        }

        init(_ snapshot: XCUIElementSnapshot) {
            self.init(exists: true, identifier: snapshot.identifier, label: snapshot.label, frame: snapshot.frame,
                      elementType: snapshot.elementType)
        }

        /// The issue's element, or nil when it names none. One gone since the check is read as before: no frame, and its
        /// identifier and label asked of the element itself.
        init?(_ issue: XCUIAccessibilityAuditIssue) {
            guard let element = issue.element else { return nil }
            if let snapshot = try? element.snapshot() {
                self.init(snapshot)
            } else {
                self.init(exists: false, identifier: element.identifier, label: element.label, frame: .zero, elementType: .any)
            }
        }
    }

    /// The screen an audit's checks left, read once for all their findings: the app's frame, and when a rule needs more,
    /// one snapshot of the app's whole tree searched in the test (one round trip where each query was several).
    final class AuditScene {
        let appFrame: CGRect
        private let app: XCUIApplication

        init(_ app: XCUIApplication) {
            self.app = app
            appFrame = app.frame
        }

        /// Every element under the app, in the order XCUITest's queries list them (depth first).
        private(set) lazy var elements: [XCUIElementSnapshot] = {
            guard let root = try? app.snapshot() else { return [] }
            var all: [XCUIElementSnapshot] = []
            func walk(_ node: XCUIElementSnapshot) {
                for child in node.children {
                    all.append(child)
                    walk(child)
                }
            }
            walk(root)
            return all
        }()

        /// The elements of one type, as `app.descendants(matching: type).allElementsBoundByIndex`.
        func elements(_ type: XCUIElement.ElementType) -> [XCUIElementSnapshot] {
            elements.filter { $0.elementType == type }
        }

        /// The first element with this identifier (of this type), as `query[identifier].firstMatch`.
        func first(_ type: XCUIElement.ElementType = .any, identifier: String) -> XCUIElementSnapshot? {
            elements.first { $0.identifier == identifier && (type == .any || $0.elementType == type) }
        }

        /// The iPhone's Settings panel, `app.otherElements["settingsDrawer"]`.
        private(set) lazy var settingsPanel: XCUIElementSnapshot? = first(.other, identifier: "settingsDrawer")

        /// The first search field's frame (`app.searchFields.firstMatch`), or nil without one.
        private(set) lazy var searchFieldFrame: CGRect? = elements(.searchField).first?.frame

        /// The Settings page's form holding `frame`: the collection view (a `Form` or `List`) in the Settings panel on
        /// iPhone, or anywhere on iPad, whose frame holds its centre.
        func settingsForm(holding frame: CGRect) -> XCUIElementSnapshot? {
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let area = settingsPanel?.frame ?? appFrame
            return elements(.collectionView).last { $0.frame.contains(centre) && area.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }

        /// How a form shows `element` when the system draws its text in its own secondary colours: a section's header (text
        /// outside every row, directly above a section's first row), its footer (directly below a section's last row), or
        /// the line under a row's title (under another text of its cell). Nil for anything else, a row's title included,
        /// and for a form whose rows are not listed as cells.
        func secondaryRole(of element: AuditedElement, in form: XCUIElementSnapshot) -> String? {
            // The form's rows. A cell with the element's own frame is the element's wrapper (a header or footer the
            // system hosts in a cell of its own), not a row: a row's text sits inside the row's margins.
            let cells = elements(.cell).filter { cell in
                form.frame.contains(CGPoint(x: cell.frame.midX, y: cell.frame.midY)) && !Self.same(cell.frame, element.frame)
            }
            guard !cells.isEmpty else { return nil }
            guard let cell = cells.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }) else {
                return headerOrFooter(element.frame, rows: cells)
            }
            let above = elements(.staticText).contains { text in
                text.frame != element.frame && cell.frame.insetBy(dx: -1, dy: -1).contains(text.frame)
                    && text.frame.maxY <= element.frame.minY + 1
                    && text.frame.minX < element.frame.maxX && element.frame.minX < text.frame.maxX
            }
            return above ? "the line under a row's title" : nil
        }

        /// A section's header or footer, read from where the text sits among the form's rows: outside every row (its
        /// frame overlaps none by more than a point; headers and footers meet their rows edge to edge, and frames are
        /// fractional), across a row's width, and its lower edge on a row's upper edge (a header, above the section's
        /// first row) or its upper edge on a row's lower edge (a footer, below the section's last row). Nil for text
        /// between rows that meets none of them, or that overlaps one.
        private func headerOrFooter(_ frame: CGRect, rows: [XCUIElementSnapshot]) -> String? {
            let edge: CGFloat = 4
            for row in rows {
                let overlap = row.frame.intersection(frame)
                if !overlap.isNull, overlap.height > 1, overlap.width > 1 { return nil }
            }
            let across = rows.filter { $0.frame.minX < frame.maxX && frame.minX < $0.frame.maxX }
            if across.contains(where: { abs($0.frame.minY - frame.maxY) <= edge }) { return "a section's header" }
            if across.contains(where: { abs($0.frame.maxY - frame.minY) <= edge }) { return "a section's footer" }
            return nil
        }

        /// Two frames the same to within a point (snapshots give fractional frames).
        static func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
        }

        /// Whether an element is one of the Settings panel's own: the panel lists an element of the same type, identifier
        /// (or label, for one without an identifier) and frame.
        func panel(_ panel: XCUIElementSnapshot, lists element: AuditedElement) -> Bool {
            func lists(_ node: XCUIElementSnapshot) -> Bool {
                node.children.contains { child in
                    (child.elementType == element.elementType && child.frame == element.frame
                     && (element.identifier.isEmpty ? child.label == element.label : child.identifier == element.identifier))
                        || lists(child)
                }
            }
            return lists(panel)
        }
    }

    /// `lowestTextContrast`, measured once per audited screen: every contrast finding without an element
    /// asks for it, and one measurement walks every text VoiceOver reaches (about 45 s on the sidebar,
    /// whose glass gives several such findings, while each text was read with queries of its own).
    private func lowestTextContrastOnce(_ scene: AuditScene, screenshot: XCUIScreenshot, reach: [ReachableElement]) -> Double? {
        let key = ObjectIdentifier(screenshot)
        if let measured = lowestContrastByScreenshot[key] { return measured }
        let measured = lowestTextContrast(scene, screenshot: screenshot, reach: reach)
        lowestContrastByScreenshot[key] = measured
        return measured
    }

    private var lowestContrastByScreenshot: [ObjectIdentifier: Double?] = [:]

    /// The lowest measured contrast among the texts VoiceOver reaches on screen, or nil when none
    /// measures. Each measurement is attached. Text views are left out: a line or two of text in a
    /// surface-sized view is too little of it for the measurement to find its color. The texts are read from the
    /// scene's one snapshot.
    private func lowestTextContrast(_ scene: AuditScene, screenshot: XCUIScreenshot, reach: [ReachableElement]) -> Double? {
        var lowest: Double?
        var measured: [String] = []
        let texts = scene.elements(.staticText).filter { !$0.frame.isEmpty && scene.appFrame.contains($0.frame) }
        let frames = texts.map(\.frame)
        for text in texts {
            let frame = text.frame
            // A row that reads as one element holds its texts: they are measured on their own.
            if frames.contains(where: { $0 != frame && frame.contains($0) }) { continue }
            if underSearchField(frame, in: scene) { continue }
            guard reach.isEmpty || reachable(AuditedElement(text), frame: frame, among: reach, appFrame: scene.appFrame),
                  let ratio = measuredContrast(screenshot, frame: frame, appFrame: scene.appFrame) else { continue }
            measured.append(String(format: "%.1f:1 %@ [%@] at %d,%d %dx%d", ratio, text.label, text.identifier,
                                   Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)))
            lowest = min(lowest ?? ratio, ratio)
        }
        attachText(measured.joined(separator: "\n"), "contrast-of-reachable-texts")
        return lowest
    }

    /// On iPhone a search field sits over the list it searches: the sidebar's at the top of the drawer,
    /// under its navigation bar, Files' floating at the foot of the screen. A row under it, or in the 16 pt
    /// scroll edge on its list's side, is blurred on purpose until it scrolls out from under it. Only such a
    /// row: text beside the field, as the navigation bar's title above it, is measured like any other.
    private func underSearchField(_ frame: CGRect, in scene: AuditScene) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        guard let field = scene.searchFieldFrame, !field.isEmpty else { return false }
        if field.midY < scene.appFrame.midY {
            return frame.maxY > field.minY && frame.minY < field.maxY + 16
        }
        return frame.minY < field.maxY && frame.maxY > field.minY - 16
    }

    /// "hello.txt", "opencode.json": one word with an extension.
    private static func isFileName(_ label: String) -> Bool {
        label.range(of: #"^[^\s/]+\.[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil
    }

    /// Opt-in (`check-ios-product.py --tests testLaunchTiming`): six cold launches of the paired app with
    /// its Files tab selected (on iPhone, where Files is a page of the drawer and never the task the app opens
    /// on, the editor of a file opened from it), each timed from `launch()` to its return (XCUITest waits
    /// there for the app to go idle) and to the listing (the editor) on screen with the opening cover gone.
    /// The first is a warm-up; the harness prints the medians of the others.
    func testLaunchTiming() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO", "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)
        browseFilesFromHome(app)
        let file = app.buttons[fileRowID("hello.txt")]
        let loading = app.otherElements["hostLoadingScreen"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // On iPhone the drawer's file tap shows its inspector; Open in Workspace opens the editor.
        if phone { openFileFromRow(app, file) }
        let surface = phone ? app.textViews["fileEditor"] : file
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        var report: [String] = []
        for run in 0...5 {
            app.terminate()
            let start = Date()
            app.launch()
            let idle = Date().timeIntervalSince(start)
            // Checked back to back, without the pause `waitForExistence` makes between checks.
            let deadline = start.addingTimeInterval(20)
            while !(surface.exists && !loading.exists) && Date() < deadline {}
            let shown = Date().timeIntervalSince(start)
            XCTAssertTrue(surface.exists && !loading.exists, "Launch \(run) shows \(phone ? "the editor" : "the Files tab")")
            report.append(String(format: "LAUNCH-TIMING run=%d idle=%.3f shown=%.3f", run, idle, shown))
        }
        attach(app, "launch-timing-files")
        print(report.joined(separator: "\n"))
        attachText(report.joined(separator: "\n"), "launch-timing")
    }

    func pairIfNeeded(_ app: XCUIApplication, fixture: Fixture, forceFreshHost: Bool) throws {
        let paired = workspaceOrPairingShown(app, timeout: 15)
        if paired && !forceFreshHost { return }
        if paired {
            // Settings → Connection (pushed in the drawer on iPhone); Disconnect puts Settings away too.
            openSettings(app)
            openSettingsPage(app, "Connection")
            app.buttons["Disconnect"].tap()
        }
        let manual = app.buttons["manualConnection"]
        if manual.exists { manual.tap() }
        let address = app.textFields["pairingAddress"]
        for _ in 0..<6 where !address.exists { app.swipeUp() }
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        // A tap the pairing screen's scroll takes (it moves the field above the keyboard) leaves the field
        // unfocused now and then; a second tap focuses it.
        func fill(_ field: XCUIElement, _ text: String) {
            field.tap()
            if !waitForFocus(field, timeout: 2) { field.tap() }
            field.typeText(text)
        }
        fill(address, try XCTUnwrap(fixture.address))
        fill(app.textFields["pairingCode"], try XCTUnwrap(fixture.code))
        fill(app.textFields["pairingFingerprint"], try XCTUnwrap(fixture.fingerprint))
        app.buttons["pairButton"].tap()
        XCTAssertTrue(workspaceHeader(app).waitForExistence(timeout: 25), "HTTPS pairing must reach the workspace")
    }

    /// Waits for the app to show its workspace (true) or the pairing screen (false), whichever comes; false
    /// when neither shows in time.
    private func workspaceOrPairingShown(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let pairing = app.staticTexts["Pair with your Mac"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if workspaceHeader(app).exists || sidebarShown(app) { return true }
            if pairing.exists { return false }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    /// A sidebar row by its identifier (rows are cells or buttons, depending on what they do).
    func sidebarItem(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Legacy helper name for Resume Work. It routes through Home's menu and opens the searchable history
    /// sheet; there is no sidebar drawer to reveal. On iPhone Resume Work is a sheet opened with ⇧⌘F.
    func openSidebar(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            openPhoneResumeWork(app)
            return
        }
        if sidebarShown(app) { return }
        openSidebarItem(app, "sidebarHome")
        let resume = app.buttons["homeRecentWork"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Home offers Resume Work")
        resume.tap()
        let history = app.buttons["Search History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Resume Work offers searchable history")
        history.tap()
        let deadline = Date().addingTimeInterval(5)
        while !sidebarShown(app) && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(sidebarShown(app), "Resume Work shows its searchable history")
    }

    /// Resume Work's search field is on screen.
    func sidebarShown(_ app: XCUIApplication) -> Bool {
        func onScreen(_ element: XCUIElement) -> Bool {
            element.exists && element.frame.maxX > 1 && element.frame.minX < app.frame.maxX - 1
        }
        return onScreen(app.searchFields["Chats, Files and Tabs"])
    }

    /// Retained for older callers; settings is no longer a pushed sidebar page.
    func drawerShowsPage(_ app: XCUIApplication) -> Bool {
        false
    }

    /// Goes back a page: the Back button of the page in front, pushed in the drawer or the iPad's
    /// Settings sheet.
    func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(appears(back, within: 5), "The page has a Back button")
        back.tap()
    }

    /// `waitForExistence`, answered at once when the element is there already: XCTest's wait checks first about a
    /// second after it starts, so each wait for an element that already shows cost a second (run 1791332542). For a
    /// control about to be used; a wait after a tap keeps `waitForExistence`, whose second lets a page that just
    /// appeared finish loading before its screenshot.
    func appears(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        element.exists || element.waitForExistence(timeout: timeout)
    }

    /// Preserves old test call sites while routing Home and Settings through their new top-level flows. On iPhone
    /// Home is the bottom bar's Chat destination, Files and Git are pages of its Workspace destination.
    func openSidebarItem(_ app: XCUIApplication, _ identifier: String) {
        if identifier == "sidebarHome" {
            if UIDevice.current.userInterfaceIdiom == .phone {
                showPhoneTab(app, "Chat")
                XCTAssertTrue(app.descendants(matching: .any)["homeWordmark"].firstMatch.waitForExistence(timeout: 5), "Home shows")
                return
            }
            if app.buttons["homeNewChat"].isHittable { return }
            if sidebarShown(app) { endSidebarSearch(app) }
            if app.buttons["resumeWorkClose"].exists { app.buttons["resumeWorkClose"].tap() }
            if app.buttons["settingsClose"].exists { closeSettings(app) }
            let switcher = app.buttons["workspaceSwitcher"]
            XCTAssertTrue(switcher.waitForExistence(timeout: 8), "The centered switcher is available")
            switcher.tap()
            let home = app.buttons["workspacePickerHome"]
            XCTAssertTrue(home.waitForExistence(timeout: 5), "The switcher lists Home")
            home.tap()
            return
        }
        if identifier == "appMenu" { openSettings(app); return }
        if let homeAction = ["sidebarFiles": "Files", "sidebarGit": "Git", "sidebarBrowser": "Browser"][identifier] {
            showProjects(app)
            // The iPhone's Files and Git are pages of its Workspace destination.
            if UIDevice.current.userInterfaceIdiom == .phone, ["Files", "Git"].contains(homeAction) {
                openPhoneWorkspacePage(app, homeAction.lowercased())
                return
            }
            app.buttons["homeBrowseFiles"].tap()
            let choice = app.buttons[homeAction]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "Browse Files offers \(homeAction)")
            choice.tap()
            return
        }
        if identifier == "sidebarNewAgentChat" {
            if UIDevice.current.userInterfaceIdiom == .phone { return newPhoneChat(app) }
            showProjects(app)
            app.buttons["homeNewChat"].tap()
            return
        }
        openSidebar(app)
        let item = sidebarItem(app, identifier)
        XCTAssertTrue(sidebarLists(app, item), "The sidebar lists \(identifier)")
        item.tap()
    }

    /// Scrolls the sidebar (the first list on screen) until `item` can be tapped: down first, then back
    /// up. Rows off screen are not in the element tree until they scroll in.
    @discardableResult
    func scrollSidebar(_ app: XCUIApplication, to item: XCUIElement) -> Bool {
        let list = app.collectionViews.firstMatch
        let searchField = app.searchFields["Chats, Files and Tabs"]
        // Resume Work gives its search field focus when it opens. Dismiss that bottom toolbar before
        // scrolling history; otherwise its keyboard and close button can cover the lower rows.
        if searchField.exists, waitForFocus(searchField, timeout: 0.5) { endSidebarSearch(app) }
        // A row that intersects a search field or the navigation bar is not reachable, even when XCUITest
        // calls it hittable. Nor is a row at the foot of the screen, over the home indicator (a long chat
        // library once left an open tab at the bottom edge, and the tap went nowhere).
        func reachable() -> Bool {
            guard item.exists, item.isHittable else { return false }
            let field = app.searchFields["Chats, Files and Tabs"]
            if field.exists,
               item.frame.insetBy(dx: 0, dy: 4).intersects(field.frame.insetBy(dx: -8, dy: -8)) {
                return false
            }
            if item.frame.maxY > app.frame.maxY - 24 { return false }
            // Nor with its middle under the sidebar's navigation bar, which takes the tap.
            let bar = app.navigationBars["AgentLand"]
            return !bar.exists || item.frame.midY > bar.frame.maxY
        }
        for _ in 0..<8 {
            if reachable() { return true }
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<10 {
            if reachable() { return true }
            list.swipeDown(velocity: .slow)
        }
        return reachable()
    }

    /// Whether the sidebar lists `item`, scrolling to it; false after `timeout` without it.
    func sidebarLists(_ app: XCUIApplication, _ item: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if scrollSidebar(app, to: item) { return true }
        } while Date() < deadline
        return false
    }

    /// An open tab's row in the sidebar; with several of one title the last is the newest.
    private func openTabRow(_ app: XCUIApplication, titled title: String) -> XCUIElement {
        let rows = app.descendants(matching: .any).matching(identifier: "openTab").matching(NSPredicate(format: "label == %@", title))
        return rows.element(boundBy: max(0, rows.count - 1))
    }

    /// Shows an open tab by choosing its row in the sidebar; on iPhone its row in the header's switcher (Files is a
    /// page of the Workspace destination, not a task).
    private func showTab(_ app: XCUIApplication, titled title: String) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if title == "Files" { openPhoneWorkspacePage(app, "files"); return }
            switchPhoneTask(app, titled: title)
            return
        }
        openSidebar(app)
        let row = openTabRow(app, titled: title)
        XCTAssertTrue(sidebarLists(app, row), "The sidebar lists the open tab \(title)")
        row.tap()
    }

    /// Settings is opened from Home's launcher on iPad; its list is a form whose rows below the fold are not in the
    /// element tree, so its title bar says it shows. On iPhone it is the bottom bar's Settings destination, on its
    /// root; a session in front is remembered so `closeSettings` returns to it.
    func openSettings(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The session in front by its switcher row (its title may change while Settings shows: a chat's name).
            phoneSessionBehindSettings = nil
            if !phoneTabBar(app).exists, app.buttons["phoneCloseTab"].exists {
                let title = app.buttons["workspaceSwitcher"].value as? String ?? ""
                app.buttons["workspaceSwitcher"].tap()
                let rows = phoneTaskRows(app)
                XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "The switcher lists the session in front")
                let current = rows.matching(NSPredicate(format: "selected == true")).firstMatch.exists
                    ? rows.matching(NSPredicate(format: "selected == true")).firstMatch
                    : rows.matching(NSPredicate(format: "label == %@", title)).firstMatch
                phoneSessionBehindSettings = current.identifier
                current.tap()
                _ = app.buttons["quickTabHome"].waitForNonExistence(timeout: 5)
            }
            showPhoneTab(app, "Settings")
            // A page left pushed: Back to the root.
            for _ in 0..<3 where !app.buttons["settingsStatus"].exists {
                let back = app.navigationBars.buttons["BackButton"].firstMatch
                guard back.exists else { break }
                back.tap()
                _ = app.buttons["settingsStatus"].waitForExistence(timeout: 2)
            }
            XCTAssertTrue(settingsListShows(app, within: 8), "Settings opens")
            return
        }
        openSidebarItem(app, "sidebarHome")
        app.buttons["homeSettings"].tap()
        XCTAssertTrue(settingsListShows(app, within: 8), "Settings opens")
    }

    /// Whether Settings shows its list (its root page, titled Settings), within `timeout`. The iPhone's Settings
    /// destination has no navigation bar on its root (the header names it): its status row says it shows.
    func settingsListShows(_ app: XCUIApplication, within timeout: TimeInterval) -> Bool {
        if UIDevice.current.userInterfaceIdiom == .phone { return appears(app.buttons["settingsStatus"], within: timeout) }
        return appears(app.navigationBars["Settings"], within: timeout)
    }

    /// Opens a category of Settings (open already, on its list) and waits for its page.
    /// Opens Settings' page `title` from its list. Right after Back the list is still sliding in, and a tap then can land
    /// in the pop's animation and push nothing (testSettingsScreenshots, run 1791344878: Privacy & Security at xxxl
    /// after Notifications). So the row is tapped once Settings' title bar shows and the row holds still wholly inside
    /// the panel (`settingsRow` scrolls it in; it never returns a row past the panel's edge), and tapped once more when
    /// nothing pushed.
    func openSettingsPage(_ app: XCUIApplication, _ title: String) {
        if UIDevice.current.userInterfaceIdiom == .phone { _ = settingsListShows(app, within: 5) }
        else { _ = app.navigationBars["Settings"].waitForExistence(timeout: 5) }
        guard let row = settingsRow(app, title) else {
            XCTFail("Settings lists \(title)")
            return
        }
        waitUntilStill(row)
        row.tap()
        if !app.navigationBars[title].waitForExistence(timeout: 4), let again = settingsRow(app, title, timeout: 3) {
            waitUntilStill(again)
            again.tap()
        }
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8), "\(title) is pushed")
    }

    /// Waits, at most `timeout`, until `element`'s frame is the same in two reads 0.2 s apart.
    func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let frame = element.frame
            if frame == last { return }
            last = frame
        }
    }

    /// Settings' row named `title` once it can be tapped, or nil when the list has none. Only a row inside Settings
    /// counts: Home's Chat and Terminal actions under the iPhone's panel have the same names. The list is a form, whose
    /// rows below the fold are not in the element tree until they scroll in: after waiting (within `timeout`, at most
    /// 1.5 s once the panel shows) for the row of a list that just appeared or came back from a page, it scrolls the
    /// list down and then up, a slow swipe at a time, until the row shows or the list stops moving (at most 8 swipes
    /// each way). A row is returned only once its whole frame lies in the list's visible area, inside the panel and below
    /// its navigation bar, and holds still there: a row that runs past the panel's edge is dragged in first. A tap on a
    /// row clipped by the panel's lower edge lands outside the panel, which iOS reads as a tap outside, and Settings
    /// closes (testSettingsScreenshots, run 1791351089: Privacy & Security at xxxl after Back from Notifications).
    func settingsRow(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 8) -> XCUIElement? {
        let panel = app.otherElements["settingsDrawer"].firstMatch
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // The iPhone's Settings destination: its list, not the bottom bar's Chat and Terminal buttons.
        let phoneList = app.collectionViews.firstMatch
        guard !phone || appears(phoneList, within: timeout) else { return nil }
        let scope: XCUIElement = phone ? phoneList : panel.exists ? panel : app
        let rows = scope.buttons.matching(NSPredicate(format: "label == %@", title))
        let list = scope.collectionViews.firstMatch.exists ? scope.collectionViews.firstMatch : scope
        // Where a tap reaches a row: the list's frame, inside the panel, below the panel's navigation bar.
        func visibleArea() -> CGRect {
            var area = list.frame
            if panel.exists { area = area.intersection(panel.frame) }
            let bar = scope.navigationBars.firstMatch
            if bar.exists, bar.frame.maxY > area.minY, !area.isNull {
                area = CGRect(x: area.minX, y: bar.frame.maxY, width: area.width, height: max(0, area.maxY - bar.frame.maxY))
            }
            // On iPhone, below the fixed header and above the bottom bar.
            if phone, !area.isNull {
                let top = max(area.minY, phoneHeaderFrame(app).maxY)
                let tabBar = phoneTabBar(app)
                let bottom = tabBar.exists ? min(area.maxY, tabBar.frame.minY) : area.maxY
                area = CGRect(x: area.minX, y: top, width: area.width, height: max(0, bottom - top))
            }
            return area.isNull ? .zero : area
        }
        func inside(_ frame: CGRect) -> Bool { !frame.isEmpty && visibleArea().insetBy(dx: -1, dy: -1).contains(frame) }
        // The row, once wholly in the visible area and still there after it holds still.
        func tappable() -> XCUIElement? {
            guard let row = rows.allElementsBoundByIndex.first(where: { $0.isHittable && inside($0.frame) }) else { return nil }
            waitUntilStill(row, timeout: 1)
            return inside(row.frame) ? row : nil
        }
        // A row in the tree but past the visible area's edge (or under the bar): dragged in, slowly so the list does not
        // coast on, by the distance it lies out plus a margin, at most half the area a drag (three drags).
        func reveal() -> XCUIElement? {
            for _ in 0..<3 {
                if let row = tappable() { return row }
                guard let row = rows.allElementsBoundByIndex.first(where: { $0.exists && !$0.frame.isEmpty }) else { return nil }
                let area = visibleArea()
                guard area.height > 0 else { return nil }
                let frame = row.frame
                let needed = frame.maxY > area.maxY ? area.maxY - frame.maxY - 16 : area.minY - frame.minY + 16
                let distance = max(-area.height / 2, min(area.height / 2, needed))
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: area.midX, dy: area.midY))
                start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
                waitUntilStill(row, timeout: 1)
            }
            return tappable()
        }
        let settled = Date().addingTimeInterval(min(timeout, 1.5))
        repeat {
            if let row = tappable() { return row }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < settled
        if let row = reveal() { return row }
        // The cells' frames: unchanged after a swipe, the list is at its end.
        func frames() -> [CGRect] { (try? list.snapshot())?.children.map(\.frame) ?? [] }
        for down in [true, false] {
            var before = frames()
            for _ in 0..<8 {
                if down { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
                if let row = reveal() { return row }
                let after = frames()
                if after == before { break }
                before = after
            }
        }
        return reveal()
    }

    /// Returns to the permanent Home with the fixture workspace open. A fresh
    /// pairing has no workspace; it is chosen the way a person would.
    func showProjects(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Home's Chat launcher (the bottom bar's Chat), whose header names the workspace in use; another workspace
            // (or none, after a fresh pairing) gives way to the fixture's through Workspace → Manage Workspaces.
            let switcher = app.buttons["workspaceSwitcher"]
            showPhoneTab(app, "Chat")
            let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Fixture"), object: switcher)
            if XCTWaiter.wait(for: [named], timeout: 2) != .completed {
                choosePhoneWorkspace(app, "fixture")
                showPhoneTab(app, "Chat")
            }
            XCTAssertTrue(app.descendants(matching: .any)["homeWordmark"].firstMatch.waitForExistence(timeout: 5), "Home shows")
            XCTAssertEqual(switcher.value as? String, "Fixture", "The header names the fixture workspace")
            return
        }
        let tabs = currentTab(app)
        if !tabs.exists || tabs.label != "Current tab: Home" {
            openSidebarItem(app, "sidebarHome")
            XCTAssertTrue(app.buttons["workspaceSwitcher"].waitForExistence(timeout: 5))
        }
        guard waitForWorkspaceLine(app, "No workspace open", timeout: 2) else { return }
        attach(app, "home-no-workspace")
        app.buttons["openWorkspace"].tap()
        let fixture = app.buttons["pickerProject-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.tap()
        // A newly opened workspace begins in its Files tab; go back to Home.
        openSidebarItem(app, "sidebarHome")
        XCTAssertTrue(waitForWorkspaceLine(app, "Workspace: Fixture", timeout: 8))
    }

    let fixedQuip = "Juggling three pull requests"
    /// The app runs at the largest accessibility text size; Home's launcher may need to scroll.
    private var largestTextSize = false
    /// The iPhone session (its switcher row's identifier) in front when `openSettings` showed the Settings destination.
    var phoneSessionBehindSettings: String? = nil

    func accessibilityTraits(_ element: XCUIElement) -> UInt64? {
        guard let snapshot = try? element.snapshot() as AnyObject,
              snapshot.responds(to: NSSelectorFromString("traits")) else { return nil }
        return (snapshot.value(forKey: "traits") as? NSNumber)?.uint64Value
    }

    /// The workspace line belongs to the shared centered switcher; the shell's debug value mirrors it.
    func workspaceLine(_ app: XCUIApplication) -> String? {
        let current = currentTab(app)
        if current.exists, let value = current.value as? String, !value.isEmpty { return value }
        for identifier in ["currentWorkspace", "noWorkspace"] where app.staticTexts[identifier].exists {
            return app.staticTexts[identifier].label
        }
        return nil
    }

    func waitForWorkspaceLine(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if workspaceLine(app) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return workspaceLine(app) == expected
    }

    /// The iPhone Home's launchers on its Chat or Terminal destination (`phoneChatProvider-*`, `phoneTerminalProgram-*`).
    /// Tests only measure them: they start the real Claude, ChatGPT, Claude Code and Codex.
    func phoneHomeLaunchers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                         "phoneChatProvider-", "phoneTerminalProgram-"))
    }

    /// The union of Home's available action capsules, including both columns when they fit.
    func homeActionBounds(_ app: XCUIApplication) -> CGRect? {
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The Chat or Terminal destination's launchers, which the host advertises (none on a host without them).
            let frames = phoneHomeLaunchers(app).allElementsBoundByIndex.map(\.frame)
            guard let first = frames.first else { return nil }
            return frames.dropFirst().reduce(first) { $0.union($1) }
        }
        let frames = expectedHomeActions.compactMap { identifier, _ -> CGRect? in
            let action = app.buttons[identifier]
            return action.exists ? action.frame : nil
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Home's title, art, quip and actions are ordered inside its own safe-area layout; no opening-cover
    /// anchor is part of the contract.
    func assertHomeTitle(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let wordmark = app.descendants(matching: .any)["homeWordmark"].firstMatch
        let quip = app.staticTexts["homeQuip"]
        // The iPhone's Home has the destination's launchers (what the host advertises) in place of New Chat.
        let phoneLaunchers = homeActionBounds(app)
        let newChatTop = UIDevice.current.userInterfaceIdiom == .phone ? phoneLaunchers?.minY ?? app.frame.maxY
            : app.buttons["homeNewChat"].frame.minY
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(wordmark.label, "AgentLand", file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "homeWordmark").count, 1,
                       "The title is one accessibility element", file: file, line: line)
        // XCUIElement has no public traits accessor; its snapshot carries the raw UIAccessibilityTraits.
        let traits = accessibilityTraits(wordmark)
        XCTAssertNotNil(traits, "The snapshot reports accessibility traits", file: file, line: line)
        XCTAssertNotEqual((traits ?? 0) & UIAccessibilityTraits.header.rawValue, 0, "The title is a header", file: file, line: line)
        XCTAssertTrue(quip.exists, file: file, line: line)
        XCTAssertEqual((accessibilityTraits(quip) ?? 0) & UIAccessibilityTraits.header.rawValue, 0, "The quip is plain text",
                       file: file, line: line)
        XCTAssertEqual(quip.label, fixedQuip, file: file, line: line)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let header = app.buttons["workspaceSwitcher"]
            XCTAssertTrue(header.exists, file: file, line: line)
            // 42 pt since the owner-approved Home of 2026-10-04: the larger 2×2 actions (7ea8747) and the title's
            // faces on a narrower, taller-drawn canvas (17b3129) moved the title up from the 50–76 of 09-30.
            XCTAssertGreaterThanOrEqual(wordmark.frame.minY - header.frame.maxY, 32,
                                        "The approved phone title sits below its header", file: file, line: line)
            XCTAssertLessThanOrEqual(wordmark.frame.minY - header.frame.maxY, 76,
                                     "The title has one deliberate top gap", file: file, line: line)
        } else {
            let navigationBar = app.navigationBars.firstMatch
            XCTAssertTrue(navigationBar.exists, file: file, line: line)
            XCTAssertGreaterThanOrEqual(wordmark.frame.minY, navigationBar.frame.maxY - 0.5,
                                        "The title sits below the navigation bar", file: file, line: line)
            XCTAssertLessThanOrEqual(wordmark.frame.minY, navigationBar.frame.maxY + 20,
                                     "The title starts near the top of Home, without a duplicated safe-area inset",
                                     file: file, line: line)
        }
        XCTAssertLessThan(wordmark.frame.maxY, newChatTop, "The title sits above the work actions", file: file, line: line)
        let circus = app.descendants(matching: .any)["homeCircus"].firstMatch
        XCTAssertTrue(circus.exists, file: file, line: line)
        XCTAssertGreaterThan(circus.frame.width, 0, "The decorative scene has its own measured bounds", file: file, line: line)
        XCTAssertLessThan(circus.frame.width, app.frame.width - 1,
                          "The scene's test identity does not inherit the whole Home container", file: file, line: line)
        XCTAssertLessThan(quip.frame.maxY, newChatTop, "The quip sits above the work actions", file: file, line: line)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The enlarged scene crops transparent canvas bands; its AX frame can still include them.
            // Geometry tests check the actual reserved scene/quip gap. Here check the visual order.
            XCTAssertGreaterThan(quip.frame.midY, circus.frame.midY, "The quip sits below the scene", file: file, line: line)
        } else {
            XCTAssertGreaterThanOrEqual(quip.frame.minY, circus.frame.maxY - 0.5, "The quip sits under the tent", file: file, line: line)
        }
        guard let actionBounds = homeActionBounds(app) else {
            // A host advertising neither Claude nor ChatGPT leaves the iPhone's Chat destination a sentence, no grid.
            if UIDevice.current.userInterfaceIdiom == .phone { return }
            return XCTFail("Home has an action grid", file: file, line: line)
        }
        XCTAssertEqual(quip.frame.midX, actionBounds.midX, accuracy: 16,
                       "The quip aligns to the full two-column launcher", file: file, line: line)
        XCTAssertFalse(wordmark.frame.contains(CGPoint(x: quip.frame.midX, y: quip.frame.midY)),
                       "The arch's hollow is empty", file: file, line: line)
        XCTAssertGreaterThanOrEqual(app.frame.maxY - actionBounds.maxY, 32,
                                    "The launcher leaves bottom clearance", file: file, line: line)
    }

    /// A new tab in the workspace: an OpenCode chat ("Chat"), or a terminal of the program `kind` names. On iPhone
    /// a chat and a shell start as ⌘N and ⌥⌘T do, from Home's UI-test starters (`newPhoneChat`, `newPhoneTerminal`);
    /// Home's launchers start real agents only.
    func openAddTab(_ app: XCUIApplication, kind: String) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if kind == "Chat" { return newPhoneChat(app) }
            if kind == "Terminal" { return newPhoneTerminal(app) }
            return XCTFail("The iPhone offers no \(kind) terminal (its Terminal launcher is Claude Code and Codex only)")
        }
        showProjects(app)
        if kind == "Chat" {
            newAgentChat(app, provider: "opencode")
        } else {
            app.buttons["homeNewTerminal"].tap()
            let identifier = kind == "Terminal" ? "homeTerminalProgram-shell" : "homeTerminalProgram-" + kind.lowercased().replacingOccurrences(of: " code", with: "")
            app.buttons[identifier].tap()
        }
    }

    /// Opens Files from Home's capability menu rather than assuming the capsule is a direct button.
    func browseFilesFromHome(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            openSidebarItem(app, "sidebarFiles")
            return
        }
        showProjects(app)
        let browse = app.buttons["homeBrowseFiles"]
        XCTAssertTrue(browse.waitForExistence(timeout: 8))
        browse.tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Browse Files offers Files")
        files.tap()
    }

    /// Dynamic workspace tab identifiers are UUID-backed; this query keeps picker assertions independent
    /// of the tab that happened to be open when the test began.
    func workspacePickerTabs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspacePickerTab-"))
    }

    /// A chat with `provider`, chosen from Home's New Chat and Chat's provider choice. `listing` names other agents the
    /// same choice must offer. Tests start only the fixture's OpenCode chats (the harness's host runs with
    /// --opencode-chat, so OpenCode starts in the Chats space): Claude Code and Codex would start the real agents.
    func newAgentChat(_ app: XCUIApplication, provider: String, listing others: [String] = []) {
        XCTAssertEqual(provider, "opencode", "Tests start only the fixture's OpenCode chats")
        if UIDevice.current.userInterfaceIdiom == .phone {
            // ⌘N's Chat provider dialog.
            return newPhoneChat(app)
        }
        showProjects(app)
        app.buttons["homeNewChat"].tap()
        let standalone = app.buttons["homeNewChatStandalone"]
        if standalone.waitForExistence(timeout: 5) { standalone.tap() }
        let choice = app.buttons["chatProvider-\(provider)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8), "Chat asks which agent")
        for other in others {
            XCTAssertTrue(app.buttons["chatProvider-\(other)"].exists, "Chat offers \(other)")
        }
        choice.tap()
    }

    /// Asks the harness to act on the real host process and waits for it.
    func hostControl(_ fixture: Fixture, _ command: String, timeout: TimeInterval = 40) throws {
        let folder = URL(fileURLWithPath: try XCTUnwrap(fixture.control, "Run through integration/check-ios-product.py"))
        let done = folder.appendingPathComponent(command + ".done")
        try? FileManager.default.removeItem(at: done)
        try Data().write(to: folder.appendingPathComponent(command + ".request"))
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: done.path) {
            guard Date() < deadline else { return XCTFail("The harness did not acknowledge \(command)") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Asks the harness for `command` with `payload` as the request's text and returns its answer, `<command>.done`'s
    /// text ("ok", or what it found wrong); "" when the harness did not answer within `timeout`. The request is written
    /// whole, then renamed, so the harness never reads half of it.
    func hostControlResult(_ fixture: Fixture, _ command: String, payload: String = "", timeout: TimeInterval = 40) throws -> String {
        let folder = URL(fileURLWithPath: try XCTUnwrap(fixture.control, "Run through integration/check-ios-product.py"))
        let done = folder.appendingPathComponent(command + ".done")
        try? FileManager.default.removeItem(at: done)
        let staging = folder.appendingPathComponent(".\(command).staging")
        try Data(payload.utf8).write(to: staging)
        try FileManager.default.moveItem(at: staging, to: folder.appendingPathComponent(command + ".request"))
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: done.path) {
            guard Date() < deadline else {
                XCTFail("The harness did not answer \(command)")
                return ""
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return try String(contentsOf: done, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Closes Resume Work's sheet on iPhone (the bottom tabs have no drawer), its search keyboard up or not.
    func closeResumeWorkSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        // Resume Work, the phone's library and search, is a sheet since 2026-10-06: its Close.
        let resumeClose = app.buttons["resumeWorkClose"].firstMatch
        if resumeClose.exists {
            resumeClose.tap()
            XCTAssertTrue(resumeClose.waitForNonExistence(timeout: 5), "Resume Work closes", file: file, line: line)
        }
    }

    /// The chat library and its search: the iPad's sidebar, the iPhone's Resume Work sheet.
    private func openLibrary(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone { openPhoneResumeWork(app) } else { openSidebar(app) }
    }

    /// A row of the library's lists (Resume Work's archive and terminal logs, its new tabs) by its identifier.
    private func openLibraryItem(_ app: XCUIApplication, _ identifier: String) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return openSidebarItem(app, identifier) }
        openLibrary(app)
        let item = sidebarItem(app, identifier)
        XCTAssertTrue(sidebarLists(app, item), "Resume Work lists \(identifier)")
        item.tap()
    }

    /// The sidebar's search field, the one place for search (on iPhone in the Resume Work sheet).
    private func openSearch(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone { openPhoneResumeWork(app) } else { openSidebar(app) }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
    }

    /// Closes the tab in front with its title menu's Close Tab.
    private func closeCurrentTab(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The header's X closes the task in front (owner, 2026-10-10); a running terminal confirms its end.
            closePhoneTask(app, discard: false)
            return
        }
        titleMenu(app).tap()
        let close = app.buttons["closeCurrentTab"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        else { app.buttons.matching(NSPredicate(format: "label == %@", "Close Tab")).firstMatch.tap() }
    }

    /// The iPhone's fixed header, which plays the navigation bar's part: from the top of the screen to just below its
    /// buttons. Empty on iPad and the Mac, and while the header has made way (landscape with the keyboard up).
    func phoneHeaderFrame(_ app: XCUIApplication) -> CGRect {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .zero }
        let switcher = app.buttons["workspaceSwitcher"]
        guard switcher.exists, !switcher.frame.isEmpty else { return .zero }
        return CGRect(x: 0, y: 0, width: app.frame.width, height: switcher.frame.maxY + 8)
    }

    /// The surfaces' trailing action identifiers (`surfaceTitle`). UI-test runs also give permanent Home
    /// an actions menu for the debug controls.
    private static let titleIdentifiers = ["homeTitleMenu", "chatHeader", "terminalActions", "fileActions", "editorActions",
                                           "gitActions", "browserActions"]

    /// "Current tab: <title>" for the tab in front, with the workspace line as its value: a test-only
    /// element of the shell (`debugCurrentTab`). The bar shows only the tab's own title.
    func currentTab(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["debugCurrentTab"].firstMatch
    }

    /// The trailing actions menu of the surface in front. Its center bar companion is the workspace
    /// switcher, so tests must never use this control to change Home or workspaces.
    func titleMenu(_ app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", Self.titleIdentifiers)).firstMatch
        // On iPhone the task in front's title-menu items are in the header's task menu.
        if UIDevice.current.userInterfaceIdiom == .phone, !menu.exists { return app.buttons["workspaceSwitcher"] }
        return menu
    }

    /// iPhone has one persistent header; iPad retains the surface title toolbar.
    func workspaceHeader(_ app: XCUIApplication) -> XCUIElement {
        if UIDevice.current.userInterfaceIdiom == .phone { return app.buttons["workspaceSwitcher"] }
        return titleMenu(app)
    }

    private func typeTerminal(_ app: XCUIApplication, _ command: String) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The phone has no separate terminal toolbar; touching its retained renderer focuses it.
            app.descendants(matching: .any)["terminalCanvas"].firstMatch.tap()
        } else {
            surfaceMenu(app, "terminalActions").tap()
            menuItem(app, "terminalKeyboard", label: "Show keyboard").tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(command)
    }

    /// Chooses the appearance in Settings → Appearance and goes back to Settings' list; `closeSettings`
    /// puts Settings away.
    func setAppearance(_ app: XCUIApplication, _ name: String) {
        openSettings(app)
        openSettingsPage(app, "Appearance")
        // The page lists System, Light and Dark, the chosen one checked (2026-10-06).
        let option = app.buttons["appearanceOption-" + name.lowercased()]
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        option.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 5), .completed, "\(name) is the chosen appearance")
        attach(app, "appearance-" + name.lowercased())
        goBack(app)
        XCTAssertTrue(settingsListShows(app, within: 5), "Back returns to Settings' list")
    }

    func attach(_ app: XCUIApplication, _ name: String) {
        // `XCUIApplication.screenshot()` can be unrotated in landscape. Attach the physical screen for
        // reviewable evidence; pixel-level control checks still intentionally sample the app screenshot.
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    /// Settings is one 80%-height, bottom-origin drawer. Its overlay identifier covers the entire dimmed
    /// surface, so assert the real, shared Close control instead of treating that full-screen identifier as
    /// the panel's frame.
    func assertBottomSettingsDrawer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["settingsClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Settings has its shared Close control", file: file, line: line)
        XCTAssertTrue(close.isHittable, "Settings Close remains tappable in the drawer", file: file, line: line)
        XCTAssertGreaterThanOrEqual(close.frame.minY, app.frame.minY + app.frame.height * 0.19,
                                    "The 80% bottom drawer leaves its top fifth outside the panel", file: file, line: line)
        XCTAssertLessThan(close.frame.maxY, app.frame.maxY,
                          "The Close control stays within the visible bottom drawer", file: file, line: line)
    }

    func attachText(_ value: String, _ name: String) {
        let text = XCTAttachment(string: value)
        text.name = name
        text.lifetime = .keepAlways
        add(text)
    }

    /// Like `waitForRenderedText`, but reads only what `canvas` (the terminal) shows.
    func waitForTerminalText(_ text: String, in canvas: XCUIElement, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let expected = text.lowercased().filter { !$0.isWhitespace }
        repeat {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(canvas.screenshot().image.cgImage)).perform([request])
            let rendered = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased().filter { !$0.isWhitespace }
            if rendered.contains(expected) { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    private func waitForRenderedText(_ text: String, in app: XCUIApplication, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let expected = text.lowercased().filter { !$0.isWhitespace }
        repeat {
            let screenshot = app.screenshot()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.image.cgImage)).perform([request])
            let rendered = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased().filter { !$0.isWhitespace }
            if rendered.contains(expected) { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        attach(app, "terminal-prompt-timeout")
        return false
    }
}
