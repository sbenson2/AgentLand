import XCTest
@testable import AgentLandWorkspace

/// Settings is one bottom drawer on every platform. Its sizing is derived from the available frame instead of
/// changing presentation when the window crosses a size-class boundary.
final class SettingsPlacementTests: XCTestCase {
    func testTheDrawerUsesEightyPercentOfAvailableHeightAndCapsItsWidth() {
        XCTAssertEqual(WorkspaceSettingsDrawerMetrics.height(available: 1000), 800)
        XCTAssertEqual(WorkspaceSettingsDrawerMetrics.height(available: 375), 300)
        XCTAssertEqual(WorkspaceSettingsDrawerMetrics.width(available: 390), 390)
        XCTAssertEqual(WorkspaceSettingsDrawerMetrics.width(available: 900), 640)
    }
}
