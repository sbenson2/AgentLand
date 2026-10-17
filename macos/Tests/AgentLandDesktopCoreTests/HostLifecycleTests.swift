import XCTest
@testable import AgentLandDesktopCore

private final class RecordingProcess: HostProcess, @unchecked Sendable {
    let launchError: Error?
    private(set) var launchCount = 0
    private(set) var terminateCount = 0
    private(set) var isRunning = false

    init(launchError: Error? = nil) {
        self.launchError = launchError
    }

    func launch() throws {
        launchCount += 1
        if let launchError { throw launchError }
        isRunning = true
    }

    func terminate() {
        terminateCount += 1
        isRunning = false
    }

    func forceTerminate() {
        terminateCount += 1
        isRunning = false
    }

    func waitForExit(timeout: TimeInterval) -> Bool { !isRunning }
}

final class HostLifecycleTests: XCTestCase {
    func testStopTerminatesOnlyTheOwnedRunningHost() async throws {
        let process = RecordingProcess()
        let lifecycle = HostLifecycle(processFactory: { _ in process })
        try await lifecycle.start(HostCommand(arguments: ["serve"]))
        try await lifecycle.stop()

        XCTAssertEqual(process.launchCount, 1)
        XCTAssertEqual(process.terminateCount, 1)
    }

    func testStopWaitsForARealChildToExit() async throws {
        let process = ProcessHostProcess(
            command: HostCommand(arguments: ["-c", "trap 'exit 0' TERM; while :; do sleep 0.1; done"]),
            executableURL: URL(fileURLWithPath: "/bin/sh")
        )
        let lifecycle = HostLifecycle(processFactory: { _ in process })
        try await lifecycle.start(HostCommand(arguments: []))

        try await lifecycle.stop(terminationGracePeriod: 1)

        XCTAssertFalse(process.isRunning)
        let status = await lifecycle.currentStatus
        XCTAssertEqual(status, .stopped)
    }

    func testFailedLaunchReturnsToStoppedWithRedactedError() async {
        let process = RecordingProcess(launchError: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "password=do-not-show"]))
        let lifecycle = HostLifecycle(processFactory: { _ in process })

        do {
            try await lifecycle.start(HostCommand(arguments: ["serve"]))
            XCTFail("expected launch to fail")
        } catch {
            let status = await lifecycle.currentStatus
            XCTAssertEqual(status, .stopped)
            XCTAssertFalse(error.localizedDescription.contains("do-not-show"))
        }
    }
}
