import XCTest
import UIKit

/// The app's text follows the reader's setting exactly (2026-10-06). A change of the setting with a chat open lays
/// the chat out again at every step. The harness changes the simulator's Text Size as Settings or Control Center would
/// (its `text-*` controls). Part of `FullWorkspaceUITests`, whose fixture and helpers it shares.
extension FullWorkspaceUITests {
    /// A chat with a reply taller than the screen, waiting on an approval: the keyboard dragged away over it (the app froze
    /// there, its transcript laid out again without end, while the transcript's rows were scroll targets), then Text Size
    /// changes that keep its rows and its card on screen: large to xxLarge, xxLarge to xxxLarge and back, back to large,
    /// and a sweep through every size and back.
    func testChatKeepsItsRowsAcrossTextSizes() throws {
        continueAfterFailure = false
        let fixture = try fixture(for: "light")
        let app = XCUIApplication()
        launch(app, appearance: "light", largestText: false)
        try pairIfNeeded(app, fixture: fixture, forceFreshHost: fixture.freshHost == true)
        showProjects(app)

        openAddTab(app, kind: "Chat")
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        chooseFixtureModel(app)
        // A reply of sixty lines, taller than the screen, then the approval at the end.
        composer.tap(); composer.typeText("AGENTLAND_SCROLL make the text size chat tall")
        app.buttons["chatSend"].tap()
        // The reply has ended when its last line is in (the chat follows it; the prompt far above is no longer laid
        // out) and the composer shows Send again.
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Scroll line 60")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 45), "The sixty-line reply is in the chat")
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 45), "The reply finished")
        XCTAssertGreaterThan(reply.frame.height, app.frame.height, "The reply is taller than the screen")
        composer.tap(); composer.typeText("AGENTLAND_APPROVAL run the proof command")
        app.buttons["chatSend"].tap()
        let card = app.descendants(matching: .any)["chatApprovalCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45), "The pending permission shows as a card in the chat")
        // Dragging the chat into the keyboard hides it; with this reply on screen the app froze there before.
        hideKeyboard(app)
        // Hiding the keyboard drags the chat off its end: scroll back down to it, as a reader would, so the chat
        // follows its latest row, the card.
        let transcript = app.scrollViews["chatTranscript"]
        for _ in 0..<3 { transcript.swipeUp() }
        let allow = app.buttons["chatAllowOnce"], deny = app.buttons["chatDeny"], pill = app.buttons["chatNeedsYouPill"]
        XCTAssertTrue(waitUntilHittable(deny, timeout: 5), "The card is on screen")
        XCTAssertTrue(pill.waitForNonExistence(timeout: 5), "The whole card is in view: no pill asks to review it")
        attach(app, "chat-text-large")

        // Then Control Center's slider dragged to the largest size and back, one size after another without a pause.
        for (control, size) in [("text-xxl", "xxLarge"), ("text-xxxl", "xxxLarge"), ("text-xxl", "xxLarge again"),
                                ("text-large", "large"), ("text-sweep", "large after a sweep")] {
            try hostCheck(fixture, control)
            // Settled: the change reaches the app and the chat lays out again.
            Thread.sleep(forTimeInterval: 2)
            attach(app, "chat-\(control)-\(size.replacingOccurrences(of: " ", with: "-"))")
            // A blank transcript has no rows at all: the card at its end is gone with them.
            XCTAssertTrue(waitUntilHittable(allow, timeout: 5), "The transcript keeps its rows and the card at \(size)")
            XCTAssertTrue(deny.isHittable, "The whole card shows at \(size)")
            XCTAssertFalse(pill.exists, "The chat still follows its latest row, the card, at \(size)")
        }

        deny.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), "The card leaves once the host reports the outcome")
    }
}
