import XCTest
@testable import AgentLandCore

@MainActor final class TerminalPollDeliveryTests: XCTestCase {
    func testLateOutputFromPreviousGenerationIsDiscarded() async throws {
        var generation = 0
        var pending: CheckedContinuation<Int, Error>?
        let requestStarted = expectation(description: "request started")
        let task = Task {
            await TerminalPollDelivery.fetch(isCurrent: { generation == 0 }) {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    requestStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        generation = 1
        pending?.resume(returning: 42)
        let result = await task.value
        XCTAssertNil(result, "A completed old poll must not deliver terminal output")
    }

    func testLateFailureFromPreviousGenerationIsDiscarded() async throws {
        var generation = 0
        var pending: CheckedContinuation<Int, Error>?
        let requestStarted = expectation(description: "request started")
        let task = Task {
            await TerminalPollDelivery.fetch(isCurrent: { generation == 0 }) {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    requestStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        generation = 1
        pending?.resume(throwing: URLError(.timedOut))
        let result = await task.value
        XCTAssertNil(result, "An old failure must not replace the current tab's status")
    }

    func testClosedTabDiscardsLateOutput() async throws {
        var tabExists = true
        var pending: CheckedContinuation<Int, Error>?
        let requestStarted = expectation(description: "request started")
        let task = Task {
            await TerminalPollDelivery.fetch(isCurrent: { tabExists }) {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    requestStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        tabExists = false
        pending?.resume(returning: 42)
        let result = await task.value
        XCTAssertNil(result, "Closing a retained terminal tab must invalidate its pending response")
    }

    func testCurrentOutputAndFailureAreDelivered() async {
        let output = await TerminalPollDelivery.fetch(isCurrent: { true }) { 42 }
        if case .success(let value)? = output { XCTAssertEqual(value, 42) }
        else { XCTFail("Current output should be delivered") }

        let failure: Result<Int, Error>? = await TerminalPollDelivery.fetch(isCurrent: { true }) {
            throw URLError(.timedOut)
        }
        if case .failure(let error)? = failure { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        else { XCTFail("A current failure should be shown for retry") }
    }

    func testCancelledPollDiscardsLateOutput() async throws {
        var pending: CheckedContinuation<Int, Error>?
        let requestStarted = expectation(description: "request started")
        let task = Task {
            await TerminalPollDelivery.fetch(isCurrent: { true }) {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    requestStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        task.cancel()
        pending?.resume(returning: 42)
        let result = await task.value
        XCTAssertNil(result, "Cancellation must win if the transport completes anyway")
    }

    func testTouchPanCannotSendTerminalInputButProtocolRepliesAndWheelReportsCanPass() {
        XCTAssertFalse(TerminalTouchInputPolicy.shouldForward(isTouchPan: true, isProtocolReply: false))
        XCTAssertFalse(TerminalTouchInputPolicy.shouldForward(isTouchPan: true, isProtocolReply: false, isWheelReport: false))
        XCTAssertTrue(TerminalTouchInputPolicy.shouldForward(isTouchPan: true, isProtocolReply: true))
        XCTAssertTrue(TerminalTouchInputPolicy.shouldForward(isTouchPan: true, isProtocolReply: false, isWheelReport: true))
        XCTAssertTrue(TerminalTouchInputPolicy.shouldForward(isTouchPan: false, isProtocolReply: false))
    }
}
