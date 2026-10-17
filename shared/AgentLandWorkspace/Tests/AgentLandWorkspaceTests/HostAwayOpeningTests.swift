import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// A host that answers on no address (a wedged Mac, a dead relay, a paused process): the opening cover
/// lifts as soon as the connection knows, onto the offline state, instead of waiting out the surfaces'
/// request timeouts (B-14). Recovery follows the connection epoch as before.
@MainActor final class HostAwayOpeningTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func workspace(_ host: ScriptedHost) throws -> WorkspaceModel {
        let suite = "host-away-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        return workspace
    }

    func testAHostThatAnswersOnNoAddressResolvesTheOpeningWithoutItsMetadata() throws {
        let workspace = try workspace(ScriptedHost())
        // The host's projects never answered: the opening waits for them while the connection is unproven.
        XCTAssertFalse(workspace.metadataResolved)
        let ticket = try XCTUnwrap(workspace.presentationTicket)
        XCTAssertFalse(workspace.presentationReady, "A host not yet proven away is waited for")

        workspace.reachable = false
        workspace.resolvePresentationOffline()
        XCTAssertTrue(workspace.presentationReady, "No address answers: the offline state is the opening's resolved state")
        XCTAssertTrue(workspace.completePresentation(ticket))

        workspace.beginPresentation()
        XCTAssertTrue(workspace.presentationReady, "An opening begun while still offline resolves at once too")
        XCTAssertTrue(workspace.completePresentation(try XCTUnwrap(workspace.presentationTicket)))

        workspace.reachable = true
        workspace.beginPresentation()
        XCTAssertFalse(workspace.presentationReady, "Back online, an opening waits for what it shows again")
        workspace.resolvePresentationOffline()
        workspace.beginPresentation()
        XCTAssertFalse(workspace.presentationReady, "A new opening forgets the last one's offline resolution")
    }

    func testOfflineResolutionNeedsAnOpening() throws {
        let workspace = try workspace(ScriptedHost())
        XCTAssertFalse(workspace.completePresentation(try XCTUnwrap(workspace.presentationTicket)), "Nothing resolved yet")
        workspace.reachable = false
        workspace.resolvePresentationOffline()
        XCTAssertTrue(workspace.completePresentation(try XCTUnwrap(workspace.presentationTicket)))
        workspace.resolvePresentationOffline()
        XCTAssertNil(workspace.presentationTicket, "No opening, nothing to resolve")
        XCTAssertFalse(workspace.presentationReady)
    }

    func testATerminalThatHadNotReadWhenTheHostWentAwaySaysSoAtOnceAndReadsWhenItIsBack() async throws {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, #"{"interactions":true,"terminal":true,"terminalPrograms":["shell"]}"#) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p1","name":"Alpha"}]}"#) }
        let output = Data("ready\r\n".utf8).base64EncodedString()
        // The output once from the start; a read from its end finds the terminal exited, so the read ends.
        host.on("/v1/terminal/output") { request in
            ScriptedHost.query(request)["cursor"] == "0"
                ? (200, #"{"data":"\#(output)","cursor":7,"reset":false,"status":"running"}"#)
                : (200, #"{"data":"","cursor":7,"reset":false,"status":"exited","exitCode":0}"#)
        }
        let workspace = try workspace(host)
        await workspace.refreshProjects()
        workspace.openWorkspace("p1")
        let tab = WorkspaceTab.terminal(RemoteTerminal(id: "t1", title: "Shell", projectID: "p1", status: .running, exitCode: nil),
                                        projectID: "p1")
        workspace.open(tab)
        workspace.beginPresentation()
        let session = workspace.terminalSession(for: tab)

        workspace.reachable = false
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertEqual(session.connectionIssue, TerminalSession.hostAwayIssue, "Said at once, not after the read's timeout")
        XCTAssertTrue(host.requests("/v1/terminal/output").isEmpty, "Nothing is asked of a host that answers on no address")
        XCTAssertTrue(workspace.presentationReady, "The terminal's offline state resolves its opening")

        workspace.reachable = true
        workspace.connectionEpoch += 1
        await session.poll(view: UUID(), viewActive: true)
        XCTAssertNotEqual(session.connectionIssue, TerminalSession.hostAwayIssue, "Back online, the terminal reads and the offline state goes")
        // The fixture's terminal exits at its end, which now shows as ended ("How terminals end").
        XCTAssertTrue(session.terminalGone)
        XCTAssertEqual(host.requests("/v1/terminal/output").count, 2, "Read from the start, then to the end")
        XCTAssertEqual(session.packets.count, 1)
    }
}
