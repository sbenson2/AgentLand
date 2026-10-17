import Darwin
import Foundation
import XCTest
@testable import AgentLandDesktopCore

/// `agentland-host install-opencode` as the Mac runs it: a stub script stands in for the host and prints the
/// JSON lines of the contract. Nothing downloads.
final class OpenCodeInstallerTests: XCTestCase {
    func testTheLinesOfTheContractAreRead() {
        func parse(_ line: String) -> OpenCodeInstallEvent? { OpenCodeInstallEvent.parse(Data(line.utf8)) }
        XCTAssertEqual(parse(#"{"event":"registry"}"#), .registry)
        XCTAssertEqual(parse(#"{"event":"downloading","version":"1.18.32","received":1024,"total":4096}"#),
                       .downloading(version: "1.18.32", received: 1024, total: 4096))
        XCTAssertEqual(parse(#"{"event":"downloading","version":"1.18.32","received":1024}"#),
                       .downloading(version: "1.18.32", received: 1024, total: nil), "total may be missing")
        XCTAssertEqual(parse(#"{"event":"downloading","version":"1.18.32","received":2.0e3,"total":0}"#),
                       .downloading(version: "1.18.32", received: 2000, total: nil), "a size of 0 is no size")
        XCTAssertEqual(parse(#"{"event":"checking","version":"1.18.32"}"#), .checking(version: "1.18.32"))
        XCTAssertEqual(parse(#"{"event":"ready","version":"1.18.32"}"#), .ready(version: "1.18.32"))
        XCTAssertEqual(parse(#"{"event":"failed","code":"offline","error":"The registry could not be reached."}"#),
                       .failed(code: "offline", error: "The registry could not be reached."))
        XCTAssertEqual(parse(#"{"event":"failed","code":"check_failed","error":"line one\nline two token=abc"}"#),
                       .failed(code: "check_failed", error: "line one line two token=[redacted]"), "one line, secrets redacted")
        XCTAssertEqual(parse(#"{"event":"ready","version":"1.18.32","somethingNew":{"a":1}}"#), .ready(version: "1.18.32"))
        XCTAssertNil(parse(#"{"event":"somethingNew"}"#), "an event this version does not know")
        XCTAssertNil(parse(#"{"event":"downloading","version":"1.18.32","received":-1}"#))
        XCTAssertNil(parse(#"{"event":"ready"}"#), "ready names its version")
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(""))
    }

    func testTheProgressSaysGettingOpenCodeWithTheVersionAndTheShare() {
        var progress = OpenCodeInstallProgress()
        XCTAssertEqual(progress.title, "Getting OpenCode…")
        XCTAssertNil(progress.fraction)
        progress.apply(.downloading(version: "1.18.32", received: 45, total: 100))
        XCTAssertEqual(progress.title, "Getting OpenCode 1.18.32…")
        XCTAssertEqual(progress.fraction, 0.45)
        XCTAssertEqual(progress.menuTitle, "Getting OpenCode 1.18.32… 45%")
        progress.apply(.downloading(version: "1.18.32", received: 50, total: nil))
        XCTAssertNil(progress.fraction, "no bar while the size is unknown")
        XCTAssertEqual(progress.menuTitle, "Getting OpenCode 1.18.32…")
        progress.apply(.checking(version: "1.18.32"))
        XCTAssertEqual(progress.title, "Checking OpenCode 1.18.32…")
        XCTAssertNil(progress.fraction)
    }

    func testFailuresAreSaidPlainly() {
        let offline = OpenCodeInstallFailure(code: "offline", detail: "dial tcp: no route to host")
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.message, "AgentLand needs a network connection to get OpenCode the first time.")
        XCTAssertEqual(offline.shortReason, "no network connection")
        XCTAssertEqual(OpenCodeInstallFailure(code: "registry_unavailable", detail: "").message,
                       "AgentLand couldn’t reach the agent registry to get OpenCode.")
        XCTAssertEqual(OpenCodeInstallFailure(code: "unverified_download", detail: "").message,
                       "The registry’s OpenCode for this Mac has no checksum, so AgentLand didn’t install it.")
        XCTAssertEqual(OpenCodeInstallFailure(code: "unsupported_platform", detail: "").message,
                       "The registry has no OpenCode for this Mac.")
        XCTAssertEqual(OpenCodeInstallFailure(code: "check_failed", detail: "It did not answer /global/health.").message,
                       "The downloaded OpenCode didn’t pass its check: It did not answer /global/health.")
        XCTAssertEqual(OpenCodeInstallFailure(code: "busy", detail: "").message,
                       "Another AgentLand host is running with this Mac’s settings. Quit it, then try again.")
        XCTAssertEqual(OpenCodeInstallFailure(code: "something_new", detail: "It broke.").message, "AgentLand couldn’t get OpenCode: It broke.")
        XCTAssertEqual(OpenCodeInstallFailure(code: "", detail: "").message, "AgentLand couldn’t get OpenCode.")
        XCTAssertNil(OpenCodeInstallFailure(code: "", detail: "").code)
        let unavailable = OpenCodeUnavailability(install: offline)
        XCTAssertEqual(unavailable, OpenCodeUnavailability(message: offline.message, shortReason: "no network connection", offline: true))
    }

    func testTheCommandIsInstallOpenCodeWithTheState() {
        XCTAssertEqual(HostCommandBuilder.installOpenCodeCommand(statePath: "/Users/me/Library/Application Support/agentland/host.json").arguments,
                       ["install-opencode", "--state", "/Users/me/Library/Application Support/agentland/host.json"])
    }

    func testAnInstallThatGetsOpenCodeReportsEachStepInOrder() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        var lines = [#"{"event":"registry"}"#]
        for received in stride(from: 0, through: 4096, by: 256) {
            lines.append(#"{"event":"downloading","version":"1.18.32","received":\#(received),"total":4096}"#)
        }
        lines += [#"{"event":"checking","version":"1.18.32"}"#, #"{"event":"ready","version":"1.18.32"}"#]
        let installer = try stub.installer(printing: lines, exit: 0)
        let events = EventLog()
        let outcome = try await installer.install(statePath: "/tmp/state dir/host.json") { events.add($0) }
        XCTAssertEqual(outcome, .ready(version: "1.18.32"))
        XCTAssertEqual(try stub.arguments(), ["install-opencode", "--state", "/tmp/state dir/host.json"])
        let seen = events.all
        XCTAssertEqual(seen.first, .registry)
        XCTAssertEqual(Array(seen.suffix(2)), [.checking(version: "1.18.32"), .ready(version: "1.18.32")])
        let downloads = seen.compactMap { event -> Int64? in
            if case let .downloading(_, received, _) = event { return received }
            return nil
        }
        XCTAssertEqual(downloads.last, 4096, "the newest download line comes before the check")
        XCTAssertEqual(downloads, downloads.sorted(), "in order")
        XCTAssertLessThan(downloads.count, 17, "download lines that come faster than ten a second are passed on newest only")
    }

    func testOfflineIsAFailureWithItsCode() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        let installer = try stub.installer(printing: [#"{"event":"registry"}"#,
                                                      #"{"event":"failed","code":"offline","error":"The registry could not be reached."}"#], exit: 3)
        let outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        XCTAssertEqual(outcome, .failed(OpenCodeInstallFailure(code: "offline", detail: "The registry could not be reached.")))
    }

    func testAnEndWithoutAnOutcomeLineIsAFailureThatSaysWhatItSaw() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        var installer = try stub.installer(printing: [#"{"event":"registry"}"#], stderr: "flag provided but not defined: -state", exit: 2)
        var outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        XCTAssertEqual(outcome, .failed(OpenCodeInstallFailure(code: nil, detail: "flag provided but not defined: -state")))
        installer = try stub.installer(printing: [#"{"event":"registry"}"#], exit: 0)
        outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        XCTAssertEqual(outcome, .failed(OpenCodeInstallFailure(code: nil, detail: "The host ended without saying OpenCode is ready.")))
        installer = try stub.installer(printing: [#"{"event":"ready","version":"1.18.32"}"#], exit: 1)
        outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        XCTAssertEqual(outcome, .failed(OpenCodeInstallFailure(code: nil, detail: "The host stopped with status 1.")),
                       "ready counts only with status 0")
    }

    func testALineTooLongToReadIsSkipped() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        let long = #"{"event":"checking","version":""# + String(repeating: "x", count: 70_000) + #""}"#
        let installer = try stub.installer(printing: [long, #"{"event":"ready","version":"1.18.32"}"#], exit: 0)
        let events = EventLog()
        let outcome = try await installer.install(statePath: "/tmp/host.json") { events.add($0) }
        XCTAssertEqual(outcome, .ready(version: "1.18.32"))
        XCTAssertEqual(events.all, [.ready(version: "1.18.32")])
    }

    func testAMissingHostIsAFailure() async throws {
        let installer = HostOpenCodeInstaller(binaryURL: URL(fileURLWithPath: "/nonexistent/agentland-host"))
        let outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        guard case let .failed(failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(failure.code)
        XCTAssertTrue(failure.detail.hasPrefix("The AgentLand host could not start:"), failure.detail)
    }

    func testAnInstallThatTakesTooLongIsStopped() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        let installer = try stub.installer(printing: [#"{"event":"registry"}"#], thenSleep: true, exit: 0, timeout: 0.5, grace: 0.3)
        let started = Date()
        let outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(outcome, .failed(OpenCodeInstallFailure(code: nil, detail: "Getting OpenCode took too long, so AgentLand stopped it.")))
        XCTAssertEqual(kill(try stub.pid(), 0), -1, "the command was stopped")
    }

    /// Something the command started keeps its pipes open after it ended: the outcome does not wait for it.
    func testAChildThatKeepsThePipesOpenDoesNotHoldTheOutcome() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        let installer = try stub.installer(printing: [#"{"event":"ready","version":"1.18.32"}"#], leaveChild: true, exit: 0, grace: 0.3)
        let started = Date()
        let outcome = try await installer.install(statePath: "/tmp/host.json") { _ in }
        XCTAssertEqual(outcome, .ready(version: "1.18.32"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let child = try stub.child()
        XCTAssertEqual(kill(child, 0), 0, "the child still holds the pipes")
        kill(child, SIGKILL)
    }

    func testCancellingStopsTheCommand() async throws {
        let stub = try Stub()
        defer { stub.cleanUp() }
        let installer = try stub.installer(printing: [#"{"event":"registry"}"#], thenSleep: true, exit: 0, grace: 0.3)
        let events = EventLog()
        let task = Task { try await installer.install(statePath: "/tmp/host.json") { events.add($0) } }
        let deadline = Date().addingTimeInterval(5)
        while events.all.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(events.all, [.registry])
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled install returned")
        } catch is CancellationError {}
        XCTAssertEqual(kill(try stub.pid(), 0), -1, "the command was stopped")
    }
}

/// A shell script in a temporary folder that stands in for `agentland-host`: it records its arguments and
/// pid, prints the lines, and exits.
private struct Stub {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func installer(printing lines: [String], stderr: String = "", thenSleep: Bool = false, leaveChild: Bool = false,
                   exit status: Int32, timeout: TimeInterval = 30, grace: TimeInterval = 2) throws -> HostOpenCodeInstaller {
        let output = root.appendingPathComponent("lines-\(UUID().uuidString)")
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        var script = "#!/bin/sh\necho $$ > '\(root.path)/pid'\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done > '\(root.path)/arguments'\n"
        script += "cat '\(output.path)'\n"
        if !stderr.isEmpty { script += "echo '\(stderr)' >&2\n" }
        // A child that outlives the command and keeps its stdout and stderr.
        if leaveChild { script += "/bin/sleep 30 &\necho $! > '\(root.path)/child'\n" }
        if thenSleep { script += "exec /bin/sleep 60\n" }
        script += "exit \(status)\n"
        let url = root.appendingPathComponent("agentland-host")
        try? FileManager.default.removeItem(at: url)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return HostOpenCodeInstaller(binaryURL: url, timeout: timeout, terminationGracePeriod: grace)
    }

    func arguments() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func pid() throws -> Int32 {
        try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func child() throws -> Int32 {
        try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// The events an install passed on, in order; they come on the command's reader.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OpenCodeInstallEvent] = []
    func add(_ event: OpenCodeInstallEvent) { lock.withLock { events.append(event) } }
    var all: [OpenCodeInstallEvent] { lock.withLock { events } }
}
