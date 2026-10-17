import XCTest
@testable import AgentLandWorkspace

final class TerminalWheelScrollTests: XCTestCase {
    func testOneStepPerRowOfTravelKeepingTheRemainder() throws {
        var wheel = TerminalWheelScroll()
        XCTAssertNil(wheel.steps(forTravel: 10, rowHeight: 16), "Less than a row sends nothing")
        let first = try XCTUnwrap(wheel.steps(forTravel: 10, rowHeight: 16))
        XCTAssertEqual(first.direction, .up)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(wheel.remainder, 4, accuracy: 0.001)
        let second = try XCTUnwrap(wheel.steps(forTravel: 44, rowHeight: 16))
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(wheel.remainder, 0, accuracy: 0.001)
    }

    func testDraggingDownTurnsTheWheelUpAndUpTurnsItDown() throws {
        var wheel = TerminalWheelScroll()
        XCTAssertEqual(try XCTUnwrap(wheel.steps(forTravel: 20, rowHeight: 16)).direction, .up, "A drag down shows earlier lines")
        wheel.reset()
        XCTAssertEqual(try XCTUnwrap(wheel.steps(forTravel: -20, rowHeight: 16)).direction, .down)
    }

    func testReversingUsesUpTheRemainderFirst() {
        var wheel = TerminalWheelScroll()
        XCTAssertNil(wheel.steps(forTravel: 12, rowHeight: 16))
        XCTAssertNil(wheel.steps(forTravel: -20, rowHeight: 16), "12 down then 20 up is 8 up: less than a row")
        XCTAssertEqual(wheel.remainder, -8, accuracy: 0.001)
    }

    func testAFastMoveSendsAtMostEightSteps() throws {
        var wheel = TerminalWheelScroll()
        let step = try XCTUnwrap(wheel.steps(forTravel: 16 * 40, rowHeight: 16))
        XCTAssertEqual(step.count, TerminalWheelScroll.maximumStepsPerMove)
        XCTAssertEqual(wheel.remainder, 0, accuracy: 0.001, "The rest is dropped, not banked for later")
    }

    func testNoRowHeightOrTravelSendsNothing() {
        var wheel = TerminalWheelScroll()
        XCTAssertNil(wheel.steps(forTravel: 100, rowHeight: 0))
        XCTAssertNil(wheel.steps(forTravel: .nan, rowHeight: 16))
        XCTAssertNil(wheel.steps(forTravel: .infinity, rowHeight: 16))
        XCTAssertEqual(wheel.remainder, 0)
    }

    func testCoastingSlowsAndStops() throws {
        let frame: TimeInterval = 1.0 / 60
        let slower = try XCTUnwrap(TerminalWheelScroll.coast(1000, elapsed: frame))
        XCTAssertLessThan(slower, 1000)
        XCTAssertGreaterThan(slower, 900)
        XCTAssertLessThan(try XCTUnwrap(TerminalWheelScroll.coast(-1000, elapsed: frame)), -900, "Both directions slow the same way")
        XCTAssertNil(TerminalWheelScroll.coast(61, elapsed: frame), "Below the stop speed the coast ends")
        XCTAssertNil(TerminalWheelScroll.coast(1000, elapsed: 0))
        var speed: CGFloat? = 3000
        var frames = 0
        while let current = speed, frames < 10_000 {
            speed = TerminalWheelScroll.coast(current, elapsed: frame)
            frames += 1
        }
        XCTAssertLessThan(frames, 200, "A hard flick coasts for about three seconds at most")
    }
}
