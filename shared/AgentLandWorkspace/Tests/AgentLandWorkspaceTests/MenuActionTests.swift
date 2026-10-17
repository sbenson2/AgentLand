import XCTest
@testable import AgentLandWorkspace

/// A menu item whose action changes what its menu shows runs it once the menu has gone (fix-up after native-iOS
/// batch 11: a workspace row's Close disabled its own items while the menu went, and the app stopped).
@MainActor final class MenuActionTests: XCTestCase {
    private final class Log {
        var ran: [String] = []
        var ranAt: ContinuousClock.Instant?
    }

    func testTheActionWaitsForTheMenuToGo() async throws {
        let log = Log()
        let ran = expectation(description: "The action runs")
        let start = ContinuousClock.now
        MenuAction.afterDismissal(waiting: .milliseconds(150)) {
            log.ranAt = .now
            ran.fulfill()
        }
        XCTAssertNil(log.ranAt, "Nothing changes while the menu is still on screen")
        await fulfillment(of: [ran], timeout: 5)
        let ranAt = try XCTUnwrap(log.ranAt)
        XCTAssertGreaterThanOrEqual(ranAt - start, .milliseconds(150), "It runs only after the menu's close")
    }

    func testTheWaitOutlastsAMenusCloseOnIPhoneAndIsNoneOnTheMac() {
        #if os(iOS)
        // A button's menu closes in under 0.1 s; the wait outlasts it without holding the action up for long.
        XCTAssertGreaterThanOrEqual(MenuAction.dismissal, .milliseconds(150))
        XCTAssertLessThanOrEqual(MenuAction.dismissal, .milliseconds(400))
        #else
        // AppKit runs a menu's action once the menu has closed.
        XCTAssertEqual(MenuAction.dismissal, .zero)
        #endif
    }

    func testOnTheMacTheActionStillRunsAfterTheCurrentUpdate() async {
        let log = Log()
        let ran = expectation(description: "The action runs")
        MenuAction.afterDismissal(waiting: .zero) {
            log.ran.append("open")
            ran.fulfill()
        }
        XCTAssertEqual(log.ran, [], "Never inside the button's own action")
        await fulfillment(of: [ran], timeout: 5)
        XCTAssertEqual(log.ran, ["open"])
    }
}
