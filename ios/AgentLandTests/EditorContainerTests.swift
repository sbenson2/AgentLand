import XCTest
import UIKit
@testable import AgentLandWorkspace

@MainActor final class EditorContainerTests: XCTestCase {
    /// UIKit's restore after the task switcher asks the text view that had the keyboard to take it again,
    /// after the model already chose another tab. The editor refuses then, and lets go of a keyboard it still
    /// holds, so nothing is left over Home (B-8, the editor's case).
    func testAnEditorWhoseTabTakesNoInputRefusesTheKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 600))
        let editor = EditorContainer(frame: window.bounds)
        window.addSubview(editor)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(editor.applyDocument("Hello from AgentLand.\n", generation: UUID(), preservingSelection: false))
        editor.setActive(true)

        var takesInput = true
        editor.takesInput = { takesInput }
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        takesInput = false
        XCTAssertFalse(editor.textView.canBecomeFirstResponder)
        XCTAssertFalse(editor.textView.becomeFirstResponder(), "Another tab was chosen: no keyboard")
        XCTAssertFalse(editor.textView.isFirstResponder, "and the keyboard it held is given up")
        takesInput = true
        XCTAssertTrue(editor.textView.becomeFirstResponder(), "Back on its tab, it takes the keyboard again")
    }

    func testCurrentDocumentGenerationRejectsStaleBindingSnapshot() {
        let editor = EditorContainer(frame: CGRect(x: 0, y: 0, width: 402, height: 600))
        let generation = UUID()

        XCTAssertTrue(editor.applyDocument("Hello from AgentLand.\n",
                                           generation: generation,
                                           preservingSelection: false))
        editor.setActive(true)
        editor.textView.selectedRange = NSRange(location: editor.textView.textStorage.length,
                                                 length: 0)
        editor.textView.insertText("Saved")
        let selectionAfterTyping = editor.textView.selectedRange

        // SwiftUI can render a binding snapshot emitted by an earlier delegate
        // callback after UIKit has already accepted additional characters.
        XCTAssertFalse(editor.applyDocument("Hello from AgentLand.\nSa",
                                            generation: generation,
                                            preservingSelection: true))
        editor.setActive(true)
        XCTAssertEqual(editor.textView.text, "Hello from AgentLand.\nSaved")
        XCTAssertEqual(editor.textView.selectedRange, selectionAfterTyping)
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "Hello from AgentLand.\n")
    }

    func testNewDocumentGenerationReplacesTextAndKeepsTypedUndoWorking() {
        let editor = EditorContainer(frame: CGRect(x: 0, y: 0, width: 402, height: 600))
        XCTAssertTrue(editor.applyDocument("Hello from AgentLand.\n",
                                           generation: UUID(),
                                           preservingSelection: false))
        editor.textView.selectedRange = NSRange(location: 6, length: 4)
        XCTAssertTrue(editor.applyDocument("short",
                                           generation: UUID(),
                                           preservingSelection: true))
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 5, length: 0))

        editor.setActive(true)
        editor.textView.insertText("!")
        XCTAssertEqual(editor.textView.text, "short!")
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.text, "short")
    }

    /// The editor never wraps: a line longer than the view stays one line and scrolls sideways, at the
    /// default and the largest text size.
    func testLongLinesDoNotWrap() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        let editor = EditorContainer(frame: window.bounds)
        window.addSubview(editor)
        window.isHidden = false
        defer { window.isHidden = true }
        let line = "Saved from full iPhone flow 59c0d346 and more text on the same line"
        editor.applyDocument(line + "\nsecond\n", generation: UUID(), preservingSelection: false)
        editor.setActive(true)
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            editor.traitOverrides.preferredContentSizeCategory = category
            editor.setNeedsLayout()
            editor.layoutIfNeeded()
            // The gutter draws line numbers with the layout manager, as it does on screen.
            editor.subviews.forEach { $0.setNeedsDisplay() }
            window.layoutIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let textView = editor.textView
            textView.layoutIfNeeded()
            let start = textView.caretRect(for: textView.beginningOfDocument)
            let lineEnd = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: (line as NSString).length))
            let end = textView.caretRect(for: lineEnd)
            XCTAssertEqual(end.midY, start.midY, accuracy: 1, "The long line stays one line at \(category.rawValue)")
            XCTAssertGreaterThan(end.maxX, textView.bounds.width, "It runs past the view at \(category.rawValue)")
            XCTAssertGreaterThan(textView.contentSize.width, textView.bounds.width, "It scrolls sideways at \(category.rawValue)")
        }
    }
}
