import Foundation
import XCTest
@testable import AgentLandDesktopCore

final class ProcessCommandRunnerTests: XCTestCase {
    func testDrainsLargeStandardOutputAndErrorBeforeChildExit() throws {
        let runner = ProcessCommandRunner(
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 3,
            outputLimit: 300_000
        )
        let command = HostCommand(arguments: ["-c", "head -c 131072 /dev/zero | tr '\\0' o; head -c 131072 /dev/zero | tr '\\0' e >&2"])

        let output = try runner.run(command)

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.standardOutput.count, 131_072)
        XCTAssertEqual(output.standardError.count, 131_072)
    }

    func testTimeoutKillsTheOwnedChildProcess() throws {
        let runner = ProcessCommandRunner(binaryURL: URL(fileURLWithPath: "/bin/sh"), timeout: 0.1, terminationGracePeriod: 0.1)
        let started = Date()

        XCTAssertThrowsError(try runner.run(HostCommand(arguments: ["-c", "trap '' TERM; while :; do :; done"]))) { error in
            XCTAssertEqual(error as? DesktopError, .commandTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTruncatesLargeActualOutputWithoutChangingExitStatus() throws {
        let runner = ProcessCommandRunner(
            binaryURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 3,
            outputLimit: 4096
        )

        let output = try runner.run(HostCommand(arguments: ["-c", "head -c 1048576 /dev/zero | tr '\\0' x"]))

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.standardOutput.count, 4096)
        XCTAssertEqual(output.standardError, "")
    }
}
