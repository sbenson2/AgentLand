import XCTest
import UIKit

/// Plain chats against the harness's host and its fixture model (docs/HOST-API.md "Plain chats"). They run
/// through integration/check-ios-product.py like the rest of `FullWorkspaceUITests`, whose fixture and helpers
/// they share; the fixture model calls the memory tools for AGENTLAND_MEMORY_SAVE and AGENTLAND_MEMORY_FORGET, and
/// never a real model or search service.
extension FullWorkspaceUITests {
    /// Real animations and real creation on the paired Mac. The recording checks the loader handoff;
    /// no model requests or terminal commands are sent, and only this test's tabs are closed.
    func testAnimatedSessionOpening() throws {
        _ = try fixture(for: "chat-providers")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        func endTestTerminal() {
            app.buttons["workspaceDrawerToggle"].tap()
            let selected = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND selected == true", "workspacePickerTab-"
            )).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            let tabID = selected.identifier.replacingOccurrences(of: "workspacePickerTab-", with: "")
            app.buttons["drawerTabActions-" + tabID].tap()
            let end = app.buttons["End terminal"].firstMatch
            XCTAssertTrue(end.waitForExistence(timeout: 5))
            end.tap()
            XCTAssertTrue(app.buttons["End terminal"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["End terminal"].firstMatch.tap()
        }
        // Explicit recovery only for a recording interrupted while its own new shell was selected.
        if ProcessInfo.processInfo.environment["AGENTLAND_OPENING_CLEANUP"] == "1" {
            XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 30))
            endTestTerminal()
        }
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 30))

        // Chat is Claude Code and Codex in the workspace (2026-10-12); the paired Mac never offers OpenCode in Chat.
        for provider in ["claude", "codex"] {
            app.buttons["homeNewChat"].tap()
            app.buttons["chatProvider-" + provider].tap()
            XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["chatModelMenu"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.exists)
            attach(app, "animated-opening-" + provider)
            app.buttons["workspaceDrawerToggle"].tap()
            let selected = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND selected == true", "workspacePickerTab-"
            )).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            let tabID = selected.identifier.replacingOccurrences(of: "workspacePickerTab-", with: "")
            app.buttons["closeDrawerTab-" + tabID].tap()
            app.buttons["workspaceDrawerToggle"].tap()
            XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 10))
        }
        app.buttons["homeNewTerminal"].tap()
        app.buttons["homeTerminalProgram-shell"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 20))
        attach(app, "animated-opening-terminal")
        endTestTerminal()
        XCTAssertTrue(app.buttons["homeNewChat"].waitForExistence(timeout: 10))
    }

    /// Opt-in smoke check against the already paired Mac. Creates empty chats only;
    /// it preserves pairing and closes each test tab without sending a model request.
    func testInstalledChatProviders() throws {
        _ = try fixture(for: "chat-providers")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations"]
        app.launch()
        XCTAssertTrue(app.buttons["workspaceDrawerToggle"].waitForExistence(timeout: 30))
        let home = app.buttons["homeNewChat"]
        func closeEmptyChat() {
            XCTAssertTrue(app.descendants(matching: .any)["plainChatLanding"].firstMatch.exists,
                          "Only an empty chat from this smoke check may be closed")
            app.buttons["workspaceDrawerToggle"].tap()
            let selected = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND selected == true", "workspacePickerTab-"
            )).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            let tabID = selected.identifier.replacingOccurrences(of: "workspacePickerTab-", with: "")
            app.buttons["closeDrawerTab-" + tabID].tap()
            app.buttons["workspaceDrawerToggle"].tap()
        }
        // A stopped run may leave its empty test chat selected. Never close a transcript.
        if !home.exists { closeEmptyChat() }
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        checkHomeNativeMenus(app, capture: "installed")
        checkNativeHeaderPanels(app, capture: "installed")

        for provider in ["claude", "codex"] {
            app.buttons["homeNewChat"].tap()
            attachText(app.debugDescription, "provider-menu-accessibility-" + provider)
            for offered in ["claude", "codex"] {
                XCTAssertTrue(app.buttons["chatProvider-" + offered].waitForExistence(timeout: 10),
                              "The installed host offers \(offered)")
            }
            XCTAssertFalse(app.buttons["chatProvider-opencode"].exists, "OpenCode is not Chat's on the Mac app's host")
            attach(app, "chat-providers-\(provider)")
            app.buttons["chatProvider-" + provider].tap()
            XCTAssertTrue(app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 20))
            // One pill holds the model, its thinking and the agent's own modes (owner, 2026-10-25).
            let model = app.buttons["chatModelMenu"].firstMatch
            XCTAssertTrue(model.waitForExistence(timeout: 10))
            XCTAssertTrue((model.value as? String ?? "").hasSuffix(", Ask"), "A new chat starts in Ask")
            XCTAssertNotNil(workspaceLine(app), "The chat runs in the workspace, and says which")
            XCTAssertTrue(model.isEnabled, "The provider offers its model choices")
            app.buttons["chatOptions"].tap()
            XCTAssertTrue(app.buttons["chatAttachPhotos"].waitForExistence(timeout: 5), "The provider offers photos")
            XCTAssertTrue(app.buttons["chatAttachFiles"].exists, "The provider offers files")
            attach(app, "chat-provider-attachments-\(provider)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            attach(app, "chat-provider-landing-\(provider)")

            closeEmptyChat()
            XCTAssertTrue(home.waitForExistence(timeout: 10))
        }
        for (appearance, large) in [("light", false), ("dark", true)] {
            app.terminate()
            app.launchArguments = ["-agentland.appearance", appearance]
            if large {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(home.waitForExistence(timeout: 30))
            checkHomeNativeMenus(app, capture: appearance + (large ? "-largest-text" : ""))
            if !large { checkNativeHeaderPanels(app, capture: appearance) }
        }
    }

    /// With no workspace open: Home's New Chat starts a plain chat, whose landing sits over its composer, with no
    /// workspace line and the model in its header; the fixture model answers. A memory save shows "Memory
    /// updated" with what was saved, and its Undo removes it on the host. Resume Work lists the plain chat under
    /// Chats; Home's New Chat starts another, where a forget shows "Removed from
    /// memory" with the entry it removed, and no Undo. The harness checks afterwards that the host's memory kept
    /// neither entry.
    func testPlainChatFlow() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let reply = try XCTUnwrap(fixture.chatReply)
        let fact = try XCTUnwrap(fixture.memoryFact, "Run through integration/check-ios-product.py")
        try XCTSkipUnless(hostListsPlainChats, "The harness's host lists plain chats before each test")
        let app = XCUIApplication()
        app.launchArguments = ["-AgentLandUITestsDisableAnimations", "-agentland.lock.enabled", "NO", "-agentland.appearance", "light"]
        app.launch()
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        XCTAssertTrue(waitForWorkspaceLine(app, "No workspace open", timeout: 20), "A fresh install opens no workspace")

        // The harness's host runs with --opencode-chat, so Chat offers OpenCode in the Chats space beside Claude Code and
        // Codex in the workspace (2026-10-12); these tests start only the fixture's OpenCode chats, never the real agents:
        // ⌘N's provider dialog with OpenCode on iPhone, Home's New Chat and the same choice on iPad.
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let homeNewChat = app.buttons["homeNewChat"]
        if phone {
            newPhoneChat(app)
        } else {
            XCTAssertTrue(homeNewChat.waitForExistence(timeout: 10))
            homeNewChat.tap()
            let standalone = app.buttons["homeNewChatStandalone"]
            XCTAssertTrue(standalone.waitForExistence(timeout: 5), "Home's menu offers a new chat")
            standalone.tap()
            let opencode = app.buttons["chatProvider-opencode"]
            XCTAssertTrue(opencode.waitForExistence(timeout: 5), "Chat asks which agent")
            opencode.tap()
        }
        let landing = app.descendants(matching: .any)["plainChatLanding"].firstMatch
        XCTAssertTrue(landing.waitForExistence(timeout: 20), "New Chat opens a plain chat")
        XCTAssertTrue(app.staticTexts["plainChatPrompt"].exists)
        XCTAssertNil(workspaceLine(app), "A plain chat has no workspace line")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The composer is under the landing")
        XCTAssertEqual(composer.placeholderValue, "Message")
        XCTAssertFalse((app.buttons["chatModelMenu"].value as? String ?? "").contains(", "),
                       "OpenCode's Chats-space chat (--opencode-chat) takes no mode; Claude Code's and Codex's do")
        attach(app, "plain-landing")

        chooseFixtureModel(app)
        send(app, "Hello from a plain chat")
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 45), "The fixture model answers")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        XCTAssertFalse(landing.exists, "The landing gives way to the conversation")
        // The centered switcher carries the current title and model; the trailing menu holds tab actions.
        let header = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let headerValue = header.value as? String ?? ""
        if UIDevice.current.userInterfaceIdiom == .phone {
            // iPhone's header names the space and the task; the composer's model chip names the model: its label is
            // what it does ("Choose Model"), its value and text the model chosen.
            let model = app.buttons["chatModelMenu"].firstMatch
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            XCTAssertTrue((model.value as? String ?? "").contains("Deterministic Local Model"), "The composer names the selected model")
        } else {
            XCTAssertTrue(headerValue.contains("Deterministic Local Model"), "The switcher names the selected model")
        }
        XCTAssertFalse(headerValue.contains("Workspace:"), "A standalone chat names no workspace")
        XCTAssertNil(workspaceLine(app))
        attach(app, "plain-reply")

        // A memory save: "Memory updated" with what was saved; Undo, under it, removes it on the host.
        send(app, "AGENTLAND_MEMORY_SAVE remember this")
        let saved = memoryCard(app, "Memory updated, \(fact)")
        XCTAssertTrue(saved.waitForExistence(timeout: 45), "The save shows what was saved")
        XCTAssertTrue(app.staticTexts["I will remember that."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        hideKeyboard(app)
        XCTAssertEqual(saved.value as? String ?? "", "")
        attach(app, "plain-memory-updated")
        let undo = app.buttons["chatMemoryUndo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is a button of its own under the card")
        XCTAssertEqual(undo.label, "Undo")
        undo.tap()
        XCTAssertTrue(wait(20) { (saved.value as? String) == "Removed from memory" }, "Undo removes the entry on the host")
        XCTAssertFalse(undo.exists, "An undone save offers Undo no more")
        attach(app, "plain-memory-undone")

        // On iPad Resume Work lists the plain chat under Chats, naming no agent. On iPhone Workspace → Chat History
        // lists it (the bottom tabs, 2026-10-11).
        if phone {
            showPhoneTab(app, "Workspace")
            app.buttons["phoneChatHistory"].tap()
            XCTAssertTrue(app.navigationBars["Chat History"].waitForExistence(timeout: 8))
            let chatRow = app.descendants(matching: .any).matching(identifier: "archiveChatRow").firstMatch
            XCTAssertTrue(chatRow.waitForExistence(timeout: 20), "Chat History lists the plain chat")
            attach(app, "plain-chat-history")
            let done = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "archiveDone", ["Done", "Close"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(app.navigationBars["Chat History"].waitForNonExistence(timeout: 5))
        } else {
            openSidebar(app)
            let row = app.descendants(matching: .any).matching(identifier: "sidebarChat").firstMatch
            XCTAssertTrue(sidebarLists(app, row, timeout: 45), "The plain chat is in the library with no workspace open")
            XCTAssertFalse((row.value as? String ?? "").contains("OpenCode"), "A plain chat's row names no agent")
            XCTAssertFalse(sidebarItem(app, "sidebarNewAgentChat").exists)
            attach(app, "plain-resume-work-library")
            app.buttons["resumeWorkClose"].tap()
        }
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        if phone {
            newPhoneChat(app)
        } else {
            switcher.tap()
            app.buttons["workspacePickerHome"].tap()
            homeNewChat.tap()
            let anotherStandalone = app.buttons["homeNewChatStandalone"]
            XCTAssertTrue(anotherStandalone.waitForExistence(timeout: 5))
            anotherStandalone.tap()
            let opencode = app.buttons["chatProvider-opencode"]
            XCTAssertTrue(opencode.waitForExistence(timeout: 5))
            opencode.tap()
        }
        XCTAssertTrue(landing.waitForExistence(timeout: 20), "Home's New Chat starts another plain chat")
        XCTAssertNil(workspaceLine(app))

        // A forget: "Removed from memory" with the entry it removed, and no Undo.
        send(app, "AGENTLAND_MEMORY_SAVE remember this again")
        XCTAssertTrue(memoryCard(app, "Memory updated, \(fact)").waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["I will remember that."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        send(app, "AGENTLAND_MEMORY_FORGET forget that")
        let removed = memoryCard(app, "Removed from memory, \(fact)")
        XCTAssertTrue(removed.waitForExistence(timeout: 45), "The forget shows the entry it removed")
        XCTAssertTrue(app.staticTexts["I have forgotten that."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 30))
        hideKeyboard(app)
        XCTAssertEqual(removed.value as? String ?? "", "", "A forget offers no Undo")
        XCTAssertEqual(app.buttons.matching(identifier: "chatMemoryUndo").count, 1, "The save's Undo alone: none for the forget")
        attach(app, "plain-memory-forgotten")
    }

    // MARK: Helpers

    /// Types `text` in the composer and sends it.
    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["chatSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    /// A memory card's summary (one element: its headline and what it saved or removed) by its label.
    private func memoryCard(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "chatMemoryCard", label)).firstMatch
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        return condition()
    }
}
