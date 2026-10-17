import XCTest

/// Exercises the shipping UI and HTTPS transport against a disposable real host.
/// Run through integration/check-ios-workspace.py; ordinary test runs skip it.
final class HostWorkspaceUITests: XCTestCase {
    private struct Fixture: Decodable {
        var enabled: Bool
        var address: String?
        var code: String?
        var fingerprint: String?
        var marker: String?
        var discoveryName: String?
    }

    func testPairEditCloseAndRelaunch() throws {
        continueAfterFailure = false
        let bundle = Bundle(for: HostWorkspaceUITests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "Fixture", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        try XCTSkipUnless(fixture.enabled, "Run integration/check-ios-workspace.py to provide an isolated HTTPS host.")
        let address = try XCTUnwrap(fixture.address)
        let code = try XCTUnwrap(fixture.code)
        let fingerprint = try XCTUnwrap(fixture.fingerprint)
        let marker = try XCTUnwrap(fixture.marker)
        let app = XCUIApplication()
        app.launch()

        // Preserve saved hosts and tabs. The centered workspace picker reaches Home; Settings starts from
        // Home's launcher instead of a sidebar footer.
        let switcher = app.buttons["workspaceSwitcher"]
        // The workspace of a saved host (its opening can take a while when the host is gone) or pairing.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !switcher.exists, !app.buttons["manualConnection"].exists,
              !app.textFields["pairingAddress"].exists {
            Thread.sleep(forTimeInterval: 0.3)
        }
        if switcher.exists {
            if UIDevice.current.userInterfaceIdiom == .phone {
                // The iPhone's Settings is the header's gear, on every task.
                app.buttons["headerSettings"].tap()
            } else {
                switcher.tap()
                let home = app.buttons["workspacePickerHome"]
                XCTAssertTrue(home.waitForExistence(timeout: 5), "The picker includes Home")
                home.tap()
                let settings = app.buttons["homeSettings"]
                XCTAssertTrue(settings.waitForExistence(timeout: 8), "Home exposes Settings")
                settings.tap()
            }
            app.buttons["Connection"].tap()
            app.buttons["Disconnect"].tap()
            XCTAssertTrue(app.staticTexts["Connect to your host"].waitForExistence(timeout: 10), "Disconnect shows pairing")
        }
        if let discoveryName = fixture.discoveryName {
            let row = app.buttons["nearbyHost-" + discoveryName]
            XCTAssertTrue(row.waitForExistence(timeout: 20), "The shipping browser must discover the real Bonjour fixture.")
            row.tap()
            let pinField = app.secureTextFields["nearbyPairingPIN"]
            XCTAssertTrue(pinField.waitForExistence(timeout: 5))
            pinField.tap()
            pinField.typeText(code)
            XCTAssertFalse(app.buttons["nearbyPairButton"].isEnabled, "A discovered fingerprint must not be trusted automatically.")
            XCTAssertTrue(app.staticTexts[fingerprint].exists, "The complete fingerprint must be available for comparison.")
            let confirmation = app.switches["nearbyFingerprintConfirmed"]
            confirmation.tap()
            // SwiftUI exposes the complete multiline row as the switch frame.
            // Its center can land on the label after XCTest scrolls it onscreen.
            if confirmation.value as? String == "0" {
                confirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            XCTAssertEqual(confirmation.value as? String, "1")
            attach(app, name: "AgentLand-fingerprint-confirmed")
            XCTAssertTrue(app.buttons["nearbyPairButton"].isEnabled, "A complete PIN and explicit fingerprint confirmation must enable pairing.")
            app.buttons["nearbyPairButton"].tap()
        } else {
            let manual = app.buttons["manualConnection"]
            if manual.exists { manual.tap() }
            // The address is entered in place, under the nearby and saved hosts.
            let addressField = app.textFields["pairingAddress"]
            for _ in 0..<6 where !addressField.exists { app.swipeUp() }
            XCTAssertTrue(addressField.waitForExistence(timeout: 10))
            addressField.tap()
            addressField.typeText(address)
            let codeField = app.textFields["pairingCode"]
            codeField.tap()
            codeField.typeText(code)
            let pinField = app.textFields["pairingFingerprint"]
            pinField.tap()
            pinField.typeText(fingerprint)
            app.buttons["pairButton"].tap()
        }

        // iPhone: Home's four actions, with Files a page of the header's drawer; iPad: Home's Browse Files.
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let files = app.buttons["homeBrowseFiles"]
        let home = app.buttons["homeNewChat"]
        let connected = (phone ? home : files).waitForExistence(timeout: 20)
        attach(app, name: "AgentLand-pairing-result")
        XCTAssertTrue(connected, "Pairing must reach the configured project.")
        let file = app.buttons[phone ? "drawerFile-hello.txt" : "file-hello.txt"]
        if phone {
            // No workspace is assumed after pairing: the drawer's workspace row chooses it (its Home shows and the
            // drawer closes, 2026-10-06), then the drawer's Files section.
            app.buttons["workspaceDrawerToggle"].tap()
            let explorer = app.descendants(matching: .any)["workspaceExplorer"].firstMatch
            let fixtureWorkspace = app.buttons["drawerWorkspace-fixture"]
            XCTAssertTrue(fixtureWorkspace.waitForExistence(timeout: 10), "The drawer lists the fixture workspace")
            fixtureWorkspace.tap()
            XCTAssertTrue(explorer.waitForNonExistence(timeout: 5), "Choosing the workspace closes the drawer")
            app.buttons["workspaceDrawerToggle"].tap()
            XCTAssertTrue(explorer.waitForExistence(timeout: 5))
            let filesSection = app.buttons["drawerSection-files"].exists ? app.buttons["drawerSection-files"].firstMatch
                : app.segmentedControls["drawerSections"].buttons["Files"].firstMatch
            XCTAssertTrue(filesSection.waitForExistence(timeout: 5), "The drawer offers Files")
            filesSection.tap()
        } else {
            files.tap()
            let filesMenuItem = app.buttons["Files"]
            XCTAssertTrue(filesMenuItem.waitForExistence(timeout: 5), "Browse Files opens its menu")
            filesMenuItem.tap()
            // No workspace is assumed after pairing: Browse Files asks for one first, then shows its files.
            let fixtureWorkspace = app.buttons["pickerProject-fixture"]
            if fixtureWorkspace.waitForExistence(timeout: 5) { fixtureWorkspace.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        file.tap()
        if phone {
            // The drawer shows the file read-only first; Open in Workspace opens the editor (2026-10-06).
            let open = app.buttons["fileInspectorOpen"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 10), "The file's inspector offers Open in Workspace")
            open.tap()
        }
        let editor = app.textViews["fileEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("Hello from AgentLand."))
        editor.tap()
        editor.typeText("\n" + marker + "\n")
        XCTAssertTrue((editor.value as? String ?? "").contains(marker), "Draft persistence must not move the cursor or corrupt typed text.")
        let save = app.buttons["saveFile"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false AND label == 'Save'"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        attach(app, name: "AgentLand-file-saved")

        // Each tab closes from its title menu's Close Tab (the tab switcher is gone); on iPhone the editor is
        // the one task (Files is the drawer's page) and closing it leaves Home.
        closeCurrentTab(app, titled: "hello.txt")
        if phone {
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["workspaceSwitcher"].isEnabled, "No task is left but Home")
        } else {
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            closeCurrentTab(app, titled: "Files")
            XCTAssertTrue(files.waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        XCTAssertTrue((phone ? home : files).waitForExistence(timeout: 15))
        if phone {
            XCTAssertFalse(app.buttons["workspaceSwitcher"].isEnabled, "Explicitly closed tasks must stay closed after relaunch.")
        } else {
            XCTAssertFalse(app.buttons["closeCurrentTab"].exists, "Explicitly closed tabs must stay closed after relaunch.")
        }
        attach(app, name: "AgentLand-tabs-closed-after-relaunch")
    }

    /// Closes the tab in front with its title menu's Close Tab: on iPhone Close Task, the last of the task's
    /// actions in the header's task menu; on iPad the system title menu, which carries the tab's title.
    private func closeCurrentTab(_ app: XCUIApplication, titled title: String) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.buttons["workspaceSwitcher"].tap()
            let close = app.buttons["closeCurrentTab"].firstMatch
            let list = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
            if list.waitForExistence(timeout: 5) {
                for _ in 0..<6 where !(close.exists && close.isHittable) { list.swipeUp() }
            }
            XCTAssertTrue(close.waitForExistence(timeout: 5), "The task menu offers Close Task")
            close.tap()
            return
        }
        let identifiers = ["chatHeader", "terminalActions", "fileActions", "editorActions", "gitActions", "browserActions"]
        let phone = app.buttons.matching(NSPredicate(format: "identifier IN %@", identifiers)).firstMatch
        let menu = phone.waitForExistence(timeout: 5) ? phone : app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        menu.tap()
        let close = app.buttons["closeCurrentTab"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        else { app.buttons.matching(NSPredicate(format: "label == %@", "Close Tab")).firstMatch.tap() }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
