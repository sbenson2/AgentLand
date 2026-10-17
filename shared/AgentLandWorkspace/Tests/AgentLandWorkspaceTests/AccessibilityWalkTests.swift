import CoreGraphics
import XCTest
@testable import AgentLandWorkspace

/// The UI-test walk of what VoiceOver reaches writes every element's frame; an element without a place on screen
/// must not end the app (run 1791399122: `CGRect.null` from the iPhone drawer's Files page).
final class AccessibilityWalkTests: XCTestCase {
    func testFramesAreWholePoints() {
        XCTAssertEqual(walkFrameText(CGRect(x: 16.7, y: -3.2, width: 343.9, height: 44)), "16,-3,343,44")
    }

    func testAFrameWithNoPlaceIsNull() {
        XCTAssertEqual(walkFrameText(.null), "null")
        XCTAssertEqual(walkFrameText(.infinite), "null")
        XCTAssertEqual(walkFrameText(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)), "null")
        XCTAssertEqual(walkFrameText(CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 10)), "null")
    }
}
