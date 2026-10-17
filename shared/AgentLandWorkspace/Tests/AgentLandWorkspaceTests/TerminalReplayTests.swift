import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// A terminal's history is read again from the start by a new renderer: after a relaunch, after its tab
/// closed and opened again, or after the host reset its output. The queries in it (cursor position,
/// device attributes, mode reports) were answered when they were first drawn; answering them again
/// sends the replies to the shell long after the program that asked stopped waiting, and the shell
/// reads them as typing (`;2R1R65;20;1c12;2$y` before the next command).
@MainActor final class TerminalReplayTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    /// Output with a cursor position query in the middle, as a prompt theme or a TUI sends one.
    nonisolated private static let history = Data("ready \u{1b}[6n done\r\n".utf8)

    /// A host whose terminal `t1` holds `history`; a read from its end finds the terminal exited.
    private func workspace(end: UInt64? = UInt64(history.count)) async throws -> (WorkspaceModel, ScriptedHost) {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, #"{"interactions":true,"terminal":true,"terminalPrograms":["shell"]}"#) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p1","name":"Alpha"}]}"#) }
        host.on("/v1/terminals") { _ in (201, #"{"id":"t1","title":"Shell","projectId":"p1","status":"running"}"#) }
        let endField = end.map { #","end":\#($0)"# } ?? ""
        host.on("/v1/terminal/output") { request in
            let history = Self.history
            if ScriptedHost.query(request)["cursor"] == "0" {
                return (200, #"{"data":"\#(history.base64EncodedString())","cursor":\#(history.count)\#(endField),"reset":false,"status":"running"}"#)
            }
            return (200, #"{"data":"","cursor":\#(history.count)\#(endField),"reset":false,"status":"exited","exitCode":0}"#)
        }
        let suite = "terminal-replay-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await workspace.refreshProjects()
        workspace.openWorkspace("p1")
        return (workspace, host)
    }

    private func restoredTab() -> WorkspaceTab {
        .terminal(RemoteTerminal(id: "t1", title: "Shell", projectID: "p1", status: .running, exitCode: nil), projectID: "p1")
    }

    /// The packets a session reads, recorded as the renderer would take them.
    private func read(_ session: TerminalSession) async -> [TerminalPacket] {
        await session.poll(view: UUID(), viewActive: true)
        return session.packets
    }

    func testHistoryOfATerminalFromAnEarlierRunIsDrawnWithoutAnsweringItsQueries() async throws {
        let (workspace, _) = try await workspace()
        let tab = restoredTab()
        workspace.open(tab)
        let packets = await read(workspace.terminalSession(for: tab))
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.answeredPrefix, Self.history.count, "Everything the host held at the first read was answered before")
    }

    func testATerminalMadeInThisRunAnswersItsFirstOutput() async throws {
        let (workspace, _) = try await workspace()
        workspace.create(.terminal, program: .shell)
        await waitUntil("the new terminal") { workspace.currentTab?.kind == .terminal }
        let tab = try XCTUnwrap(workspace.currentTab)
        let packets = await read(workspace.terminalSession(for: tab))
        XCTAssertEqual(packets.first?.answeredPrefix, 0, "A new shell waits for the answers to its first queries")

        // The tab closes and the terminal opens again in a new session of this run: the first one answered.
        workspace.close(tab.id)
        let again = restoredTab()
        workspace.open(again)
        let replayed = await read(workspace.terminalSession(for: again))
        XCTAssertEqual(replayed.first?.answeredPrefix, Self.history.count)
    }

    func testAnOlderHostWithoutAnEndLeavesHistoryAnswered() async throws {
        let (workspace, _) = try await workspace(end: nil)
        let tab = restoredTab()
        workspace.open(tab)
        let packets = await read(workspace.terminalSession(for: tab))
        XCTAssertEqual(packets.first?.answeredPrefix, 0, "Without the host's end nothing is held back")
    }

    func testAPacketIsAnsweredOnlyAfterItsAnsweredPrefix() {
        XCTAssertEqual(TerminalPacket(data: Data("abc".utf8), answeredPrefix: 9).answeredPrefix, 3)
        XCTAssertEqual(TerminalPacket(data: Data("abc".utf8), answeredPrefix: -1).answeredPrefix, 0)
    }

    #if os(macOS)
    /// The renderer draws the answered part of a packet without replying to its queries, and answers
    /// the same query in output it has not drawn before.
    func testTheRendererDrawsAnsweredOutputWithoutReplying() async {
        var replies: [Data] = []
        let link = TerminalRendererLink(send: { _ in }, sendProtocolReply: { replies.append($0) }, resize: { _, _ in })
        let view = TerminalRenderer.makeRenderer(link: link)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)

        view.feed(TerminalPacket(data: Self.history, answeredPrefix: Self.history.count))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(replies.isEmpty, "A replayed cursor query is not answered again")
        XCTAssertTrue(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true).contains("ready") == true,
                      "The replayed output is still drawn")

        view.feed(TerminalPacket(data: Self.history, answeredPrefix: 0))
        await waitUntil("the reply to a new query") { !replies.isEmpty }
        XCTAssertEqual(replies.first.map { String(decoding: $0, as: UTF8.self) }.map { $0.hasSuffix("R") }, true)
    }
    #endif
}
