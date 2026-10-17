import Foundation
import Darwin
import XCTest
@testable import AgentLandDesktopCore

/// The host's and OpenCode's output in ~/Library/Logs/AgentLand (2026-10-14: a terminal died with nothing on record).
final class ChildProcessLogTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("child-log-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.appendingPathComponent("Logs/AgentLand", isDirectory: true)
    }

    private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testLinesAreWrittenWholeWithSecretsRedactedAndOnlyThisUserCanReadThem() throws {
        let folder = try folder()
        let log = ChildProcessLog(folder: folder, name: "opencode", secrets: ["s3cret-password"])
        log.append(Data("INFO service=server creating session id=pty_1\nAuthorization: Basic \(Data("opencode:s3cret-password".utf8).base64EncodedString())".utf8))
        XCTAssertFalse(text(log.url).contains("Authorization"), "An unfinished line waits for its end")
        log.append(Data(" more\nthe password s3cret-pass".utf8))
        log.append(Data("word was here\n".utf8))
        let written = text(log.url)
        XCTAssertTrue(written.contains("creating session id=pty_1\n"))
        XCTAssertTrue(written.contains("Authorization: Basic [redacted] more\n"))
        XCTAssertTrue(written.contains("the password [redacted] was here\n"), "A secret split across reads is still redacted")
        XCTAssertFalse(written.contains("s3cret"))
        let file = try FileManager.default.attributesOfItem(atPath: log.url.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// A line too long to wait for is cut into 64 KiB pieces; a secret that straddles a cut is still redacted, wherever
    /// it falls and however the reads split it.
    func testASecretAcrossALongLinesCutIsRedacted() throws {
        let folder = try folder()
        let secret = "s3cret-password"
        for offset in [-40, -15, -8, -1, 0, 1, 7, 14, 40] {
            let log = ChildProcessLog(folder: folder, name: "cut\(offset + 100)", secrets: [secret])
            let output = Data((String(repeating: "a", count: ChildProcessLog.lineLimit + offset) + secret
                + String(repeating: "b", count: ChildProcessLog.lineLimit + 100) + secret + "c\n").utf8)
            for start in stride(from: 0, to: output.count, by: 4093) {
                log.append(output.subdata(in: start..<min(output.count, start + 4093)))
            }
            let written = text(log.url)
            XCTAssertFalse(written.contains("s3cret"), "offset \(offset)")
            XCTAssertFalse(written.contains("password"), "offset \(offset)")
            XCTAssertEqual(written.components(separatedBy: "[redacted]").count, 3, "offset \(offset)")
            XCTAssertTrue(written.hasSuffix("[redacted]c\n"), "offset \(offset)")
            // Every piece but the line's last is at most 64 KiB.
            let pieces = written.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            XCTAssertGreaterThan(pieces.count, 1, "A long line is written in pieces")
            XCTAssertTrue(pieces.dropLast().allSatisfy { $0.utf8.count <= ChildProcessLog.lineLimit }, "offset \(offset)")
        }
    }

    /// Each stream keeps its own unfinished line: stderr's whole line never lands inside stdout's half line.
    func testStreamsDoNotShareALine() throws {
        let folder = try folder()
        let log = ChildProcessLog(folder: folder, name: "opencode")
        log.append(Data("INFO creating ".utf8), stream: 1)
        log.append(Data("WARN disk is full\nWARN half".utf8), stream: 2)
        log.append(Data("session id=pty_1\n".utf8), stream: 1)
        log.flush()
        XCTAssertEqual(text(log.url), "WARN disk is full\nINFO creating session id=pty_1\nWARN half\n")
    }

    func testAFullLogMovesToItsOneOlderCopy() throws {
        let folder = try folder()
        let log = ChildProcessLog(folder: folder, name: "host", limit: 1024)
        let line = String(repeating: "a", count: 99) + "\n"
        for _ in 0..<10 { log.append(Data(line.utf8)) }
        XCTAssertEqual(text(log.url).count, 1000)
        log.append(Data(("b" + line.dropFirst()).utf8))
        let older = URL(fileURLWithPath: log.url.path + ".1")
        XCTAssertEqual(text(older).count, 1000, "The full log is kept once")
        XCTAssertTrue(text(log.url).hasPrefix("b"))
        for _ in 0..<11 { log.append(Data(("c" + line.dropFirst()).utf8)) }
        XCTAssertTrue(text(older).hasPrefix("b"), "Only one older copy is kept")
        XCTAssertLessThanOrEqual(text(log.url).count, 1024)
        // A log left full by an earlier run moves aside before the next line.
        let next = ChildProcessLog(folder: folder, name: "host", limit: 150)
        next.append(Data("d\n".utf8))
        XCTAssertEqual(text(next.url), "d\n")
    }

    func testTheChildsOutputIsReadToItsEnd() throws {
        let folder = try folder()
        let log = ChildProcessLog(folder: folder, name: "host")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo terminals: created id=pty_1; echo oops >&2; printf tail"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        log.started("agentland-host", pid: process.processIdentifier)
        let done = expectation(description: "drained")
        log.drain(pipe.fileHandleForReading, finished: { done.fulfill() })
        wait(for: [done], timeout: 10)
        let written = text(log.url)
        XCTAssertTrue(written.contains("AgentLand started agentland-host (pid \(process.processIdentifier))"))
        XCTAssertTrue(written.contains("terminals: created id=pty_1\n"))
        XCTAssertTrue(written.contains("oops\n"))
        XCTAssertTrue(written.hasSuffix("tail\n"), "The last unfinished line is written when the output ends")
    }
}
