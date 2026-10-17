#if os(iOS)
import XCTest
import UIKit
@testable import AgentLandWorkspace

/// Workspace keys on the window's root view controller, ahead of the focus system and focused fields.
@MainActor
final class WorkspaceTabKeysTests: XCTestCase {
    private func windowWithKeys() -> (UIWindow, UIViewController, WorkspaceTabKeys.KeysView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let keys = WorkspaceTabKeys.KeysView()
        root.view.addSubview(keys)
        return (window, root, keys)
    }

    private func command(_ root: UIViewController, _ modifiers: UIKeyModifierFlags) -> UIKeyCommand? {
        root.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == modifiers }
    }

    private func escapeCommand(_ root: UIViewController) -> UIKeyCommand? {
        root.keyCommands?.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty }
    }

    func testTheTabKeysAskForPriorityOverTheFocusSystemWhileTheirActionsAreThere() {
        let (window, root, keys) = windowWithKeys()
        var moves: [String] = []
        keys.nextTab = { moves.append("next") }
        keys.sync()

        let next = command(root, .control)
        XCTAssertEqual(next?.wantsPriorityOverSystemBehavior, true, "⌃⇥ goes ahead of the focus system's Tab")
        XCTAssertEqual(next?.attributes.contains(.hidden), true, "The menu bar's Next Tab shows the shortcut")
        XCTAssertNil(command(root, [.control, .shift]), "No previous tab: no ⌃⇧⇥")

        root.agentLandNextTab(nil)
        XCTAssertEqual(moves, ["next"])

        keys.previousTab = { moves.append("previous") }
        keys.sync()
        XCTAssertEqual(command(root, [.control, .shift])?.wantsPriorityOverSystemBehavior, true)
        root.agentLandPreviousTab(nil)
        XCTAssertEqual(moves, ["next", "previous"])

        keys.nextTab = nil
        keys.previousTab = nil
        keys.sync()
        XCTAssertNil(command(root, .control), "Without the action the key goes on as before")
        XCTAssertNil(command(root, [.control, .shift]))
        _ = window
    }

    func testEscapeClosesSettingsAheadOfAFocusedFieldOnlyWhileTheDrawerIsOpen() {
        let (window, root, keys) = windowWithKeys()
        var closes = 0
        keys.escape = { closes += 1 }
        keys.sync()

        let escape = escapeCommand(root)
        XCTAssertEqual(escape?.wantsPriorityOverSystemBehavior, true,
                       "Escape closes the drawer even when a settings field has focus")
        XCTAssertEqual(escape?.attributes.contains(.hidden), true)
        let field = UITextField()
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        keys.sync()
        XCTAssertTrue(field.isFirstResponder, "SwiftUI updates must not steal focus from a Settings field")
        let action = #selector(UIViewController.agentLandCloseSettings(_:))
        let target = field.target(forAction: action, withSender: escape)
        XCTAssertTrue((target as? UIViewController) === root,
                      "The focused field routes Escape to the priority window command")
        _ = (target as? NSObject)?.perform(action, with: escape)
        XCTAssertEqual(closes, 1)

        keys.escape = nil
        keys.sync()
        XCTAssertNil(escapeCommand(root), "Without the drawer, Escape retains its usual focused-field behavior")
        _ = window
    }

    func testEscapeHasAFirstResponderWhenSettingsOpensWithoutAFocusedField() {
        let (window, _, keys) = windowWithKeys()
        window.makeKeyAndVisible()
        var closes = 0
        keys.escape = { closes += 1 }
        keys.sync()

        XCTAssertTrue(keys.isFirstResponder,
                      "A physical Escape needs a responder when Settings has no focused field")
        let command = keys.keyCommands?.first {
            $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty
        }
        guard let command, let action = command.action else {
            return XCTFail("The modal responder exposes an Escape command and action")
        }
        let target = keys.target(forAction: action, withSender: command)
        XCTAssertTrue((target as? WorkspaceTabKeys.KeysView) === keys,
                      "The active responder owns the physical Escape command")
        _ = (target as? NSObject)?.perform(action, with: command)
        XCTAssertEqual(closes, 1)

        keys.escape = nil
        keys.sync()
        XCTAssertFalse(keys.isFirstResponder, "Closing Settings releases the temporary responder")
    }

    func testAViewThatLeavesItsWindowTakesTheKeysAway() {
        let (window, root, keys) = windowWithKeys()
        keys.nextTab = {}
        keys.previousTab = {}
        keys.escape = {}
        keys.sync()
        XCTAssertEqual(root.keyCommands?.count, 3)

        keys.removeFromSuperview()
        XCTAssertEqual(root.keyCommands?.count ?? 0, 0)
        _ = window
    }
}
#endif
