import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AgentLandDesktopCore

/// Which of the host's managed OpenCode versions a start runs (`<state>.agents/opencode/current.json`: the
/// current one and the `previous` one it keeps). The app bundles none. Everything happens in a temporary
/// folder; no OpenCode runs.
final class ManagedOpenCodeBinaryTests: XCTestCase {
    func testTheAgentsFolderFollowsTheHostsStatePath() {
        XCTAssertEqual(HostCommandBuilder.agentsFolderPath(statePath: "/Users/me/Library/Application Support/agentland/host.json"),
                       "/Users/me/Library/Application Support/agentland/host.json.agents")
        XCTAssertNil(HostCommandBuilder.agentsFolderPath(statePath: "relative/host.json"))
    }

    func testAValidManagedOpenCodeIsChosen() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        let record = ManagedAgentRecord(version: "1.19.0", command: program.path, args: ["acp"],
                                        sha256: try fixture.digest(program), installedAt: "2026-09-26T20:00:00Z")
        try fixture.writeRecord(record)
        let plan = fixture.locator.plan()
        XCTAssertEqual(plan.first?.source, .managed(record))
        XCTAssertEqual(plan.first?.executableURL.path, try XCTUnwrap(OpenCodeBinaryLocator.canonicalPath(program.path)))
        XCTAssertNil(plan.fallback, "the record keeps no previous version")
        XCTAssertNil(plan.why)
    }

    func testACommandRelativeToItsFolderIsChosen() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let digest = try fixture.digest(fixture.install(version: "1.19.0"))
        let record = ManagedAgentRecord(version: "1.19.0", command: "opencode", sha256: digest)
        try fixture.writeRecord(record)
        XCTAssertEqual(fixture.locator.plan().first?.source, .managed(record), "relative to the version's folder")
        let fromAgentFolder = ManagedAgentRecord(version: "1.19.0", command: "1.19.0/opencode", sha256: digest)
        try fixture.writeRecord(fromAgentFolder)
        XCTAssertEqual(fixture.locator.plan().first?.source, .managed(fromAgentFolder), "or to the agent's folder")
    }

    /// The host records the SHA-256 of every OpenCode it installs (docs/HOST-API.md "Installs"), so a
    /// record without one never runs unchecked.
    func testARecordWithoutAChecksumIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path, installedAt: "2026-09-26T20:00:00Z"))
        fixture.assertNothingRuns(because: .invalidRecord("it has no sha256"))
        XCTAssertEqual(fixture.locator.plan().why, "The host's OpenCode record is not valid: it has no sha256.")
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: "opencode"))
        fixture.assertNothingRuns(because: .invalidRecord("it has no sha256"), "a relative command too")
    }

    /// Nothing is bundled: without a record no OpenCode can run, and the plan says the host has none.
    func testWithoutARecordNothingRuns() throws {
        let fixture = try AgentsFixture(createAgents: false)
        defer { fixture.cleanUp() }
        fixture.assertNothingRuns(because: .notInstalled)
        XCTAssertEqual(OpenCodeBinaryLocator(agentsFolder: nil).plan(),
                       OpenCodeLaunchPlan(first: nil, fallback: nil, why: ManagedOpenCodeRejection.notInstalled.description),
                       "no agents folder at all")
    }

    func testAProgramOutsideTheFolderIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let outside = try fixture.program(at: fixture.root.appendingPathComponent("elsewhere/opencode"))
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: outside.path, sha256: try fixture.digest(outside)))
        fixture.assertNothingRuns(because: .outsideFolder)
        _ = try fixture.install(version: "1.19.0")
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: "../../../elsewhere/opencode", sha256: try fixture.digest(outside)))
        fixture.assertNothingRuns(because: .outsideFolder, "a relative path that climbs out")
    }

    func testALinkThatLeadsOutOfTheFolderIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let outside = try fixture.program(at: fixture.root.appendingPathComponent("elsewhere/opencode"))
        let version = try fixture.privateFolder(fixture.openCode.appendingPathComponent("1.19.0"))
        let link = version.appendingPathComponent("opencode")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: link.path, sha256: try fixture.digest(outside)))
        fixture.assertNothingRuns(because: .outsideFolder)
    }

    func testALinkThatStaysInsideIsFollowed() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        let link = fixture.openCode.appendingPathComponent("1.19.0/opencode-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: program)
        let record = ManagedAgentRecord(version: "1.19.0", command: link.path, sha256: try fixture.digest(program))
        try fixture.writeRecord(record)
        let first = try XCTUnwrap(fixture.locator.plan().first)
        XCTAssertEqual(first.source, .managed(record))
        XCTAssertEqual(first.executableURL.path, OpenCodeBinaryLocator.canonicalPath(program.path), "the link's target runs")
    }

    func testAChecksumMismatchIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        let other = SHA256.hash(data: Data("something else".utf8)).map { String(format: "%02x", $0) }.joined()
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: other))
        fixture.assertNothingRuns(because: .checksumMismatch)
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: try fixture.digest(program).uppercased()))
        XCTAssertEqual(fixture.locator.plan().first?.executableURL.path, OpenCodeBinaryLocator.canonicalPath(program.path),
                       "the digest's case does not matter")
    }

    func testAMissingProgramIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.privateFolder(fixture.openCode.appendingPathComponent("1.19.0"))
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: "opencode", sha256: AgentsFixture.anyDigest))
        fixture.assertNothingRuns(because: .missingExecutable)
    }

    func testFoldersOtherUsersCanOpenAreRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: try fixture.digest(program)))
        let version = fixture.openCode.appendingPathComponent("1.19.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: version.path)
        fixture.assertNothingRuns(because: .notPrivate(fixture.agents.lastPathComponent + "/opencode/1.19.0"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: version.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: fixture.agents.path)
        fixture.assertNothingRuns(because: .notPrivate(fixture.agents.lastPathComponent))
    }

    func testAProgramOthersCanChangeOrNoOneCanRunIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: try fixture.digest(program)))
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: program.path)
        fixture.assertNothingRuns(because: .notExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: program.path)
        fixture.assertNothingRuns(because: .notExecutable)
    }

    func testARecordOthersCanChangeOrThatIsMalformedIsRefused() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let program = try fixture.install(version: "1.19.0")
        try fixture.writeRecord(ManagedAgentRecord(version: "../1.19.0", command: program.path))
        fixture.assertNothingRuns(because: .invalidRecord("its version is not a folder name"))
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path, sha256: "not-hex"))
        fixture.assertNothingRuns(because: .invalidRecord("its sha256 is not 64 hex digits"))
        try Data("{\"version\": 1".utf8).write(to: fixture.recordURL)
        fixture.assertNothingRuns(because: .invalidRecord("it is not the expected JSON"))
        try fixture.writeRecord(ManagedAgentRecord(version: "1.19.0", command: program.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.recordURL.path)
        fixture.assertNothingRuns(because: .invalidRecord("it is not a file that only this user can change"))
    }

    // MARK: The previous version

    /// The host keeps the version before the current one; it is the fallback when the current one does
    /// not start, and it is read the way the host writes it.
    func testThePreviousVersionIsTheFallback() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let previous = try fixture.installRecord(version: "1.18.32", installedAt: "2026-09-26T20:00:00Z")
        let current = try fixture.installRecord(version: "1.18.33", installedAt: "2026-09-27T20:00:00Z")
        try fixture.writeRecords(current: current, previous: previous)
        let plan = fixture.locator.plan()
        XCTAssertEqual(plan.first?.source, .managed(current))
        XCTAssertEqual(plan.fallback?.source, .previous(previous))
        XCTAssertEqual(plan.fallback?.executableURL.path, OpenCodeBinaryLocator.canonicalPath(
            fixture.openCode.appendingPathComponent("1.18.32/opencode").path))
        XCTAssertEqual(try fixture.locator.previousExecutable().get().record, previous)

        // The host's own form of the file: `kind`, `name`, `env`, `unverified` and a nested `previous`.
        let hostWritten = """
        {"version": "1.18.33", "command": "\(current.command)", "args": ["acp"], "sha256": "\(current.sha256!)",
         "installedAt": "2026-09-27T20:00:00.000Z", "kind": "binary", "name": "OpenCode", "unverified": false,
         "previous": {"version": "1.18.32", "command": "\(previous.command)", "args": ["acp"], "sha256": "\(previous.sha256!)",
                      "installedAt": "2026-09-26T20:00:00.000Z", "kind": "binary", "unverified": false}}
        """
        try Data(hostWritten.utf8).write(to: fixture.recordURL)
        let records = try fixture.locator.records().get()
        XCTAssertEqual(records.current.version, "1.18.33")
        XCTAssertEqual(records.previous?.version, "1.18.32")
        XCTAssertEqual(fixture.locator.plan().fallback?.source.record.version, "1.18.32")
    }

    /// The previous version passes exactly the checks the current one does.
    func testThePreviousVersionIsCheckedLikeTheCurrentOne() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let current = try fixture.installRecord(version: "1.18.33")
        let outside = try fixture.program(at: fixture.root.appendingPathComponent("elsewhere/opencode"))
        let program = try fixture.install(version: "1.18.32")
        let digest = try fixture.digest(program)
        func assertNoFallback(_ previous: ManagedAgentRecord, because rejection: ManagedOpenCodeRejection, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
            try fixture.writeRecords(current: current, previous: previous)
            let plan = fixture.locator.plan()
            XCTAssertEqual(plan.first?.source, .managed(current), message, file: file, line: line)
            XCTAssertNil(plan.fallback, message, file: file, line: line)
            if case let .failure(found) = fixture.locator.previousExecutable() {
                XCTAssertEqual(found, rejection, message, file: file, line: line)
            } else {
                XCTFail("the previous version was accepted: \(message)", file: file, line: line)
            }
        }
        try assertNoFallback(ManagedAgentRecord(version: "1.18.32", command: outside.path, sha256: try fixture.digest(outside)),
                             because: .outsideFolder, "a program outside the folder")
        try assertNoFallback(ManagedAgentRecord(version: "1.18.32", command: program.path, sha256: AgentsFixture.anyDigest),
                             because: .checksumMismatch, "a checksum that does not match")
        try assertNoFallback(ManagedAgentRecord(version: "1.18.32", command: program.path),
                             because: .invalidRecord("it has no sha256"), "no checksum")
        let link = fixture.openCode.appendingPathComponent("1.18.32/opencode-out")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try assertNoFallback(ManagedAgentRecord(version: "1.18.32", command: link.path, sha256: try fixture.digest(outside)),
                             because: .outsideFolder, "a link that leads out")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.deletingLastPathComponent().path)
        try assertNoFallback(ManagedAgentRecord(version: "1.18.32", command: program.path, sha256: digest),
                             because: .notPrivate(fixture.agents.lastPathComponent + "/opencode/1.18.32"), "a folder others can open")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: program.path)
        try assertNoFallback(ManagedAgentRecord(version: "1.18.32", command: program.path, sha256: digest),
                             because: .notExecutable, "a program others can change")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let valid = ManagedAgentRecord(version: "1.18.32", command: program.path, sha256: digest)
        try fixture.writeRecords(current: current, previous: valid)
        XCTAssertEqual(fixture.locator.plan().fallback?.source, .previous(valid), "once it passes, it is the fallback")
    }

    /// A current version that fails the checks leaves the previous one to run first, and says why.
    func testWhenTheCurrentVersionFailsTheChecksThePreviousOneRuns() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let previous = try fixture.installRecord(version: "1.18.32")
        let program = try fixture.install(version: "1.18.33")
        try fixture.writeRecords(current: ManagedAgentRecord(version: "1.18.33", command: program.path, sha256: AgentsFixture.anyDigest),
                                 previous: previous)
        let plan = fixture.locator.plan()
        XCTAssertEqual(plan.first?.source, .previous(previous))
        XCTAssertNil(plan.fallback)
        XCTAssertEqual(plan.why, ManagedOpenCodeRejection.checksumMismatch.description)
    }

    /// A version that did not start (while the previous one then did) is not run while the host keeps it:
    /// not as the current version, and not as the previous one after the host went back to the version before.
    func testTheVersionThatDidNotStartIsNotRunAsCurrentOrPrevious() throws {
        let fixture = try AgentsFixture()
        defer { fixture.cleanUp() }
        let older = try fixture.installRecord(version: "1.18.32", installedAt: "2026-09-26T20:00:00Z")
        let failed = try fixture.installRecord(version: "1.18.33", installedAt: "2026-09-27T20:00:00Z")
        try fixture.writeRecords(current: failed, previous: older)
        var plan = fixture.locator.plan(skipping: failed)
        XCTAssertEqual(plan.first?.source, .previous(older))
        XCTAssertNil(plan.fallback)
        XCTAssertEqual(plan.why, "OpenCode 1.18.33 didn’t start last time.")

        // The host went back: the failed version is its previous one now, and no fallback.
        try fixture.writeRecords(current: older, previous: failed)
        plan = fixture.locator.plan(skipping: failed)
        XCTAssertEqual(plan.first?.source, .managed(older))
        XCTAssertNil(plan.fallback, "the version that did not start is no fallback")

        // Without a previous version, nothing runs.
        try fixture.writeRecords(current: failed, previous: nil)
        plan = fixture.locator.plan(skipping: failed)
        XCTAssertNil(plan.first)
        XCTAssertEqual(plan.why, "OpenCode 1.18.33 didn’t start last time.")

        // The host installs another version: it runs.
        let next = try fixture.installRecord(version: "1.18.34", installedAt: "2026-09-28T20:00:00Z")
        try fixture.writeRecords(current: next, previous: failed)
        plan = fixture.locator.plan(skipping: failed)
        XCTAssertEqual(plan.first?.source, .managed(next))
        XCTAssertNil(plan.fallback)
    }
}

/// `<root>/state/host.json.agents/opencode/…`, made the way the host makes it: folders 0700, the record
/// 0600, programs 0700.
struct AgentsFixture {
    let root: URL
    let agents: URL
    let openCode: URL
    var recordURL: URL { openCode.appendingPathComponent("current.json") }
    var locator: OpenCodeBinaryLocator { OpenCodeBinaryLocator(agentsFolder: agents) }

    init(createAgents: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-agents-\(UUID().uuidString)")
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        agents = URL(fileURLWithPath: try XCTUnwrap(HostCommandBuilder.agentsFolderPath(statePath: state.appendingPathComponent("host.json").path)))
        openCode = agents.appendingPathComponent("opencode", isDirectory: true)
        if createAgents {
            _ = try privateFolder(agents)
            _ = try privateFolder(openCode)
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func privateFolder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// `opencode/<version>/opencode`.
    func install(version: String, script: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        try program(at: privateFolder(openCode.appendingPathComponent(version)).appendingPathComponent("opencode"), script: script)
    }

    func program(at url: URL, script: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        try privateFolder(url.deletingLastPathComponent())
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Installs `opencode/<version>/opencode` and returns its record as the host writes it: the absolute
    /// command and the program's SHA-256.
    func installRecord(version: String, script: String = "#!/bin/sh\nexit 0\n", installedAt: String? = nil) throws -> ManagedAgentRecord {
        let program = try install(version: version, script: script)
        return ManagedAgentRecord(version: version, command: program.path, sha256: try digest(program), installedAt: installedAt)
    }

    /// A well-formed SHA-256 for records whose program is never hashed.
    static let anyDigest = String(repeating: "0", count: 64)

    func writeRecord(_ record: ManagedAgentRecord) throws {
        try JSONEncoder().encode(record).write(to: recordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    /// `current.json` with the version the host keeps for going back.
    func writeRecords(current: ManagedAgentRecord, previous: ManagedAgentRecord?) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        if let previous { object["previous"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) }
        try JSONSerialization.data(withJSONObject: object).write(to: recordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// No OpenCode passes the checks: the plan runs nothing, and says why.
    func assertNothingRuns(because rejection: ManagedOpenCodeRejection, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        let plan = locator.plan()
        XCTAssertNil(plan.first, message, file: file, line: line)
        XCTAssertNil(plan.fallback, message, file: file, line: line)
        XCTAssertEqual(plan.why, rejection.description, message, file: file, line: line)
        if case let .failure(found) = locator.managedExecutable() {
            XCTAssertEqual(found, rejection, message, file: file, line: line)
        } else {
            XCTFail("the managed OpenCode was accepted. \(message)", file: file, line: line)
        }
    }
}
