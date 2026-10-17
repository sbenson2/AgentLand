import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// An ended terminal says when and why it ended, and a Claude Code one offers Resume (docs/HOST-API.md
/// "How terminals end"; the 2026-10-14 terminal that died after an hour said nothing).
@MainActor final class TerminalEndStateTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private let conversation = "0f8fad5b-d9cb-469f-a165-70867728950e"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    /// A host whose terminal `t1` answers `output` (status, body) to every read, and `close` to ending it.
    private func workspace(features: String = #"["title","resume"]"#,
                           close: @escaping @Sendable (URLRequest) -> (Int, String) = { _ in (200, #"{"accepted":true}"#) },
                           output: @escaping @Sendable (URLRequest) -> (Int, String))
        async throws -> (WorkspaceModel, ScriptedHost) {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in
            (200, #"{"interactions":true,"terminal":true,"terminalPrograms":["shell","claude"],"terminalFeatures":\#(features)}"#)
        }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p1","name":"Alpha"}]}"#) }
        host.on("/v1/terminals") { _ in (201, #"{"id":"t2","title":"Claude Code","projectId":"p1","status":"running"}"#) }
        host.on("/v1/terminal/output", output)
        host.on("/v1/terminal/close", close)
        let suite = "terminal-end-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await workspace.refreshProjects()
        workspace.openWorkspace("p1")
        return (workspace, host)
    }

    private func openTerminal(_ workspace: WorkspaceModel, label: String) -> (WorkspaceTab, TerminalSession) {
        let tab = WorkspaceTab.terminal(RemoteTerminal(id: "t1", title: label, projectID: "p1", status: .running, exitCode: nil), projectID: "p1")
        workspace.open(tab)
        return (tab, workspace.terminalSession(for: tab))
    }

    func testAnExitedClaudeTerminalSaysWhyAndResumesItsConversation() async throws {
        let conversation = self.conversation
        let (workspace, host) = try await workspace { _ in
            (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","exitCode":1,"ended":{"reason":"programExited","#
                + #""at":"2026-10-14T11:41:03.000Z","exitCode":1,"program":"claude","conversationId":"\#(conversation)"}}"#)
        }
        let (tab, session) = openTerminal(workspace, label: "Claude Code")
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(session.terminalGone)
        let detail = try XCTUnwrap(session.connectionIssue)
        XCTAssertTrue(detail.hasPrefix("Claude Code exited "), detail)
        XCTAssertTrue(detail.hasSuffix(" with code 1."), detail)
        XCTAssertEqual(session.resumeTarget, .conversation(conversation))
        XCTAssertFalse(session.rendererTakesInput, "Nothing can be typed into an ended terminal: no keyboard or key bar")
        XCTAssertFalse(session.showKeyboard)

        await session.resume()
        await waitUntil("the resumed terminal to take the ended one's place") {
            workspace.tabs.contains { $0.resourceID == "t2" } && !workspace.tabs.contains { $0.id == tab.id }
        }
        // The host still listed the ended terminal: Resume ended it there first.
        let closed = try XCTUnwrap(host.bodies("/v1/terminal/close").first)
        XCTAssertEqual(closed["terminalId"] as? String, "t1")
        XCTAssertEqual(host.bodies("/v1/terminal/close").count, 1)
        let body = try XCTUnwrap(host.bodies("/v1/terminals").last)
        XCTAssertEqual(body["program"] as? String, "claude")
        XCTAssertEqual(body["resume"] as? String, conversation)
        XCTAssertEqual(body["projectId"] as? String, "p1")
    }

    func testAClaudeTerminalWithoutAConversationResumesInClaudesPicker() async throws {
        let (workspace, host) = try await workspace { _ in
            (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","ended":{"reason":"connectionLost","at":"2026-10-14T11:41:03.000Z","program":"claude"}}"#)
        }
        let (_, session) = openTerminal(workspace, label: "Claude Code")
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(session.connectionIssue?.hasPrefix("AgentLand on the Mac lost its connection to it ") == true, session.connectionIssue ?? "")
        XCTAssertEqual(session.resumeTarget, .pick)
        await session.resume()
        await waitUntil("the resumed terminal to open") { workspace.tabs.contains { $0.resourceID == "t2" } }
        XCTAssertEqual(host.bodies("/v1/terminals").last?["resume"] as? String, "pick")
    }

    /// Resume never runs a second Claude Code beside one the host may still have: when ending the old terminal fails
    /// or is uncertain, nothing opens and the ended state says so. One the host already forgot is fine.
    func testResumeOpensNothingWhileTheOldTerminalMayStillRun() async throws {
        let ended = #"{"data":"","cursor":0,"reset":false,"status":"disconnected","ended":{"reason":"connectionLost","at":"2026-10-14T11:41:03.000Z","program":"claude","conversationId":"0f8fad5b-d9cb-469f-a165-70867728950e"}}"#
        let (workspace, host) = try await workspace(close: { _ in (500, #"{"error":{"code":"internal_error","message":"Internal error"}}"#) }) { _ in (200, ended) }
        let (tab, session) = openTerminal(workspace, label: "Claude Code")
        await session.poll(view: UUID(), viewActive: true)
        await session.resume()
        XCTAssertNotNil(session.resumeIssue)
        XCTAssertTrue(host.bodies("/v1/terminals").isEmpty, "No second terminal while the first may still run")
        XCTAssertTrue(workspace.tabs.contains { $0.id == tab.id })

        let (forgot, forgotHost) = try await self.workspace(close: { _ in
            (404, #"{"error":{"code":"terminal_not_found","message":"Terminal not found"}}"#)
        }) { _ in (200, ended) }
        let (_, gone) = openTerminal(forgot, label: "Claude Code")
        await gone.poll(view: UUID(), viewActive: true)
        await gone.resume()
        await waitUntil("the resumed terminal to open") { forgot.tabs.contains { $0.resourceID == "t2" } }
        XCTAssertNil(gone.resumeIssue)
        XCTAssertEqual(forgotHost.bodies("/v1/terminals").last?["resume"] as? String, "0f8fad5b-d9cb-469f-a165-70867728950e")
    }

    func testATerminalTheHostForgotSaysHowItEndedWithoutBlamingARestart() async throws {
        let (workspace, _) = try await workspace { _ in
            (404, #"{"error":{"code":"terminal_not_found","message":"Terminal not found","ended":{"reason":"endedByDevice","at":"2026-10-14T11:41:03.000Z","device":"iPad","program":"shell"}}}"#)
        }
        let (_, session) = openTerminal(workspace, label: "Terminal")
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(session.terminalGone)
        XCTAssertTrue(session.connectionIssue?.hasPrefix("It was ended from iPad ") == true, session.connectionIssue ?? "")
        XCTAssertNil(session.resumeTarget, "Only Claude Code terminals resume")
        XCTAssertTrue(session.howEnded?.reason == .endedByDevice)

        let (older, _) = try await self.workspace(features: #"["title"]"#) { _ in
            (404, #"{"error":{"code":"terminal_not_found","message":"Terminal not found"}}"#)
        }
        let (_, claude) = openTerminal(older, label: "Claude Code")
        await claude.poll(view: UUID(), viewActive: true)
        XCTAssertEqual(claude.connectionIssue, "AgentLand on the Mac no longer has this terminal and didn’t record how it ended.")
        XCTAssertFalse(claude.connectionIssue?.contains("restart") == true)
        XCTAssertNil(claude.resumeTarget, "A host that cannot resume offers no Resume")
    }

    func testKeeperStoppedOffersResume() async throws {
        let (workspace, _) = try await workspace { _ in
            (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","ended":{"reason":"keeperStopped","at":"2026-10-14T11:41:03.000Z","program":"claude","conversationId":"0f8fad5b-d9cb-469f-a165-70867728950e"}}"#)
        }
        let (_, session) = openTerminal(workspace, label: "Claude Code")
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(session.terminalGone)
        XCTAssertEqual(session.resumeTarget, .conversation("0f8fad5b-d9cb-469f-a165-70867728950e"))
    }

    func testAnUnavailableTerminalServiceKeepsPolling() async throws {
        let calls = LockedCounter()
        let (workspace, host) = try await workspace { _ in
            switch calls.next() {
            case 1, 2: (503, #"{"error":{"code":"terminals_unavailable","message":"Terminals are unavailable"}}"#)
            case 3: (200, #"{"data":"b2s=","cursor":2,"reset":false,"status":"running"}"#)
            default: (200, #"{"data":"","cursor":2,"reset":false,"status":"running"}"#)
            }
        }
        let (_, session) = openTerminal(workspace, label: "Terminal")
        let poll = Task { await session.poll(view: UUID(), viewActive: true) }
        await waitUntil("the first 503") { calls.count >= 1 }
        await waitUntil("the issue") { session.connectionIssue == TerminalSession.terminalsUnavailableIssue }
        XCTAssertFalse(session.terminalGone)
        await waitUntil("the data", timeout: 8) { calls.count >= 3 && session.connectionIssue == nil }
        XCTAssertFalse(session.terminalGone)
        XCTAssertEqual(session.packets.count, 1)
        XCTAssertEqual(session.packets.first?.data, Data("ok".utf8))
        let cursors = host.requests("/v1/terminal/output").map { ScriptedHost.query($0)["cursor"] ?? "" }
        XCTAssertEqual(Array(cursors.prefix(3)), ["0", "0", "0"], "The cursor is kept across the 503s")
        XCTAssertEqual(cursors.dropFirst(3).first ?? "2", "2", "After the data the next read starts at its cursor")
        poll.cancel()
    }

    func testEndTextSaysWhenAndWhy() throws {
        let calendar = Calendar(identifier: .gregorian)
        let at = Date(timeIntervalSince1970: 1_791_978_063)
        let sameDay = at.addingTimeInterval(60)
        let nextDay = at.addingTimeInterval(36 * 3600)
        let time = at.formatted(date: .omitted, time: .shortened)
        func text(_ reason: TerminalEnd.Reason?, exit: Int? = nil, device: String? = nil, program: String? = "claude", now: Date = sameDay) -> String {
            TerminalEndText.description(TerminalEnd(reason: reason, at: at, exitCode: exit, device: device, program: program),
                                        label: "Claude Code", gone: false, now: now, calendar: calendar)
        }
        XCTAssertEqual(text(.programExited, exit: 0), "Claude Code exited at \(time).")
        XCTAssertEqual(text(.programExited, exit: 2, program: "shell"), "The shell exited at \(time) with code 2.")
        XCTAssertEqual(text(.endedByDevice, device: "Sam’s iPhone"), "It was ended from Sam’s iPhone at \(time).")
        XCTAssertEqual(text(.workspaceRemoved), "Its workspace was removed from AgentLand at \(time).")
        XCTAssertEqual(text(.hostStopped), "It ended when AgentLand on the Mac stopped at \(time).")
        XCTAssertEqual(text(.hostInterrupted), "It ended when AgentLand on the Mac quit unexpectedly. Its last output was at \(time).")
        XCTAssertEqual(text(.connectionLost), "AgentLand on the Mac lost its connection to it at \(time).")
        XCTAssertEqual(text(.backendEnded), "OpenCode on the Mac closed it at \(time).")
        XCTAssertEqual(text(.keeperStopped), "It ended when the Mac restarted or logged out, or AgentLand's terminal service stopped at \(time).")
        XCTAssertEqual(text(.endedOnMac), "It was ended from AgentLand on the Mac at \(time).")
        XCTAssertEqual(text(.deviceRemoved), "Its device was removed from AgentLand on the Mac at \(time).")
        XCTAssertEqual(text(.keptInTerminal), "It keeps running in Terminal on the Mac; AgentLand stopped following it at \(time).")
        XCTAssertTrue(text(.hostStopped, now: nextDay).hasSuffix(" on \(at.formatted(.dateTime.month(.abbreviated).day())) at \(time)."))
        XCTAssertEqual(text(nil), "Claude Code ended.")
        XCTAssertEqual(TerminalEndText.description(nil, label: "Codex", gone: false), "Codex ended.")
    }
}

/// Counts calls from `@Sendable` host handlers.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}
