import Foundation
import XCTest
@testable import AgentLandCore

/// Terminals from other devices: `GET /v1/terminals/others`, terminals outside any workspace, and whether the
/// host shares terminals at all (`terminalFeatures` lists `shared`).
final class SharedTerminalsTests: XCTestCase {
    /// As the host writes them (`archiveTimeLayout`, "2006-01-02T15:04:05.000Z").
    private let iPadTerminal = """
    {"id":"pty_7","deviceId":"d2","deviceName":"Sam’s iPad","onMac":false,"program":"claude","title":"Claude Code",
     "programTitle":"✳ Fix login","contextTitle":"Fix the login bug","folder":"/Users/wes/Developer/tower",
     "displayFolder":"~/Developer/tower","projectId":"p1","workspace":"tower","routed":false,"status":"running",
     "activity":"working","lastOutputAt":"2026-10-14T11:41:03.250Z","lastActiveAt":"2026-10-14T11:41:03.250Z"}
    """
    private let macAgent = """
    {"id":"pty_8","deviceId":"local-mac","deviceName":"","onMac":true,"program":"codex","title":"Codex",
     "programTitle":"","contextTitle":"","folder":"/Users/wes/notes","displayFolder":"~/notes","projectId":null,
     "workspace":null,"routed":true,"status":"running","activity":"waiting","lastActiveAt":"2026-10-14T11:40:00.000Z"}
    """

    func testSharedTerminalDecodesEveryField() async throws {
        let client = try makeClient(LineTransport(body: Data((#"{"terminals":["# + iPadTerminal + "," + macAgent + "]}").utf8)))
        let terminals = try await client.otherTerminals()
        XCTAssertEqual(terminals.map(\.id), ["pty_7", "pty_8"], "The host's order is kept")
        let iPad = terminals[0]
        XCTAssertEqual(iPad.deviceID, "d2")
        XCTAssertEqual(iPad.deviceName, "Sam’s iPad")
        XCTAssertFalse(iPad.onMac)
        XCTAssertEqual(iPad.program, "claude")
        XCTAssertEqual(iPad.title, "Claude Code")
        XCTAssertEqual(iPad.programTitle, "✳ Fix login")
        XCTAssertEqual(iPad.contextTitle, "Fix the login bug")
        XCTAssertEqual(iPad.folder, "/Users/wes/Developer/tower")
        XCTAssertEqual(iPad.displayFolder, "~/Developer/tower")
        XCTAssertEqual(iPad.projectID, "p1")
        XCTAssertEqual(iPad.workspace, "tower")
        XCTAssertFalse(iPad.routed)
        XCTAssertEqual(iPad.status, .running)
        XCTAssertEqual(iPad.activity, .working)
        XCTAssertEqual(iPad.lastOutputAt, Date(timeIntervalSince1970: 1_791_978_063.25))
        XCTAssertEqual(iPad.lastActiveAt, Date(timeIntervalSince1970: 1_791_978_063.25))

        let mac = terminals[1]
        XCTAssertEqual(mac.deviceID, "local-mac")
        XCTAssertEqual(mac.deviceName, "", "The Mac's own are named by the host's name, not here")
        XCTAssertTrue(mac.onMac)
        XCTAssertTrue(mac.routed)
        XCTAssertEqual(mac.activity, .waiting)
        XCTAssertNil(mac.lastOutputAt, "No output yet")
        XCTAssertEqual(mac.lastActiveAt, Date(timeIntervalSince1970: 1_791_978_000))

        // Opened here, it is a host terminal like this device's own.
        let remote = iPad.remoteTerminal
        XCTAssertEqual(remote.id, "pty_7")
        XCTAssertEqual(remote.title, "Claude Code")
        XCTAssertEqual(remote.projectID, "p1")
        XCTAssertEqual(remote.status, .running)
        XCTAssertEqual(remote.programTitle, "✳ Fix login")
        XCTAssertEqual(remote.contextTitle, "Fix the login bug")
        XCTAssertEqual(remote.displayTitle, "Fix the login bug")
    }

    func testNullProjectIsNone() throws {
        let null = try decode(macAgent)
        XCTAssertNil(null.projectID)
        XCTAssertNil(null.workspace)
        XCTAssertEqual(null.remoteTerminal.projectID, "", "A terminal outside any workspace is projectless")
        let empty = try decode(#"{"id":"pty_9","status":"running","projectId":"","workspace":""}"#)
        XCTAssertNil(empty.projectID)
        XCTAssertNil(empty.workspace)
        let absent = try decode(#"{"id":"pty_9","status":"running"}"#)
        XCTAssertNil(absent.projectID)
        XCTAssertNil(absent.workspace)
    }

    func testUnknownActivityIsQuiet() throws {
        XCTAssertEqual(try decode(#"{"id":"pty_1","status":"running","activity":"thinking"}"#).activity, .quiet)
        XCTAssertEqual(try decode(#"{"id":"pty_1","status":"running","activity":7}"#).activity, .quiet)
        XCTAssertEqual(try decode(#"{"id":"pty_1","status":"running"}"#).activity, .quiet)
        XCTAssertEqual(try decode(#"{"id":"pty_1","status":"running","activity":"waiting"}"#).activity, .waiting)
    }

    func testMissingOptionalsDecode() async throws {
        let bare = try decode(#"{"id":"pty_1","status":"running"}"#)
        XCTAssertEqual(bare.deviceID, "")
        XCTAssertEqual(bare.deviceName, "")
        XCTAssertEqual(bare.program, "")
        XCTAssertEqual(bare.title, "")
        XCTAssertEqual(bare.folder, "")
        XCTAssertEqual(bare.displayFolder, "")
        XCTAssertFalse(bare.onMac)
        XCTAssertFalse(bare.routed)
        XCTAssertNil(bare.programTitle)
        XCTAssertNil(bare.contextTitle)
        XCTAssertNil(bare.lastOutputAt)
        XCTAssertEqual(bare.lastActiveAt, .distantPast)
        // Values this version cannot read count as none; they never cost the terminal.
        let odd = try decode(#"{"id":"pty_2","status":"running","programTitle":3,"lastOutputAt":"yesterday","lastActiveAt":"soon","onMac":"yes"}"#)
        XCTAssertNil(odd.programTitle)
        XCTAssertNil(odd.lastOutputAt)
        XCTAssertEqual(odd.lastActiveAt, .distantPast)
        XCTAssertFalse(odd.onMac)
        // Times without fractional seconds read too.
        XCTAssertEqual(try decode(#"{"id":"pty_3","status":"running","lastActiveAt":"2026-10-14T11:41:03Z"}"#).lastActiveAt,
                       Date(timeIntervalSince1970: 1_791_978_063))
        // A terminal this version cannot read is left out of the list; the others stay.
        let client = try makeClient(LineTransport(body: Data((#"{"terminals":[{"status":"running"},"# + iPadTerminal + #",{"id":"pty_5","status":"paused"}]}"#).utf8)))
        let listed = try await client.otherTerminals()
        XCTAssertEqual(listed.map(\.id), ["pty_7"])
        // A terminal survives being saved and read again.
        let iPad = try decode(iPadTerminal)
        XCTAssertEqual(try JSONDecoder().decode(SharedTerminal.self, from: JSONEncoder().encode(iPad)), iPad)
    }

    func testOtherTerminalsCallsTheRoute() async throws {
        let transport = LineTransport(body: Data(#"{"terminals":[]}"#.utf8))
        let terminals = try await makeClient(transport).otherTerminals()
        XCTAssertEqual(terminals, [])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/terminals/others")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
    }

    func testProjectlessCallsOmitProjectID() async throws {
        let output = LineTransport(body: Data(#"{"data":"","cursor":0,"reset":false,"status":"running"}"#.utf8))
        let reader = try makeClient(output)
        _ = try await reader.terminalOutput(projectID: "", terminalID: "pty_8", cursor: 4, wait: 2)
        _ = try await reader.terminalOutput(projectID: "p1", terminalID: "pty_7", cursor: 0)
        let projectless = try XCTUnwrap(output.requests[0].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        XCTAssertFalse(projectless.contains { $0.name == "projectId" }, "\(projectless)")
        XCTAssertEqual(projectless.first { $0.name == "terminalId" }?.value, "pty_8")
        XCTAssertEqual(projectless.first { $0.name == "cursor" }?.value, "4")
        let inWorkspace = try XCTUnwrap(output.requests[1].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        XCTAssertEqual(inWorkspace.first { $0.name == "projectId" }?.value, "p1")

        let accepted = LineTransport(body: Data(#"{"accepted":true}"#.utf8))
        let writer = try makeClient(accepted)
        for projectID in ["", "p1"] {
            let input = await writer.sendTerminalInput(projectID: projectID, terminalID: "pty_8", data: Data("ls\r".utf8))
            let resize = await writer.resizeTerminal(projectID: projectID, terminalID: "pty_8", rows: 24, cols: 80)
            let title = await writer.nameTerminal(projectID: projectID, terminalID: "pty_8", title: "Notes", basedOn: 3)
            let close = await writer.closeTerminal(projectID: projectID, terminalID: "pty_8")
            XCTAssertEqual([input, resize, title, close], [.accepted, .accepted, .accepted, .accepted])
        }
        let requests = accepted.requests
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/v1/terminal/input", "/v1/terminal/resize", "/v1/terminal/title", "/v1/terminal/close",
                                                            "/v1/terminal/input", "/v1/terminal/resize", "/v1/terminal/title", "/v1/terminal/close"])
        let bodies = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any]) }
        for body in bodies[..<4] {
            XCTAssertNil(body["projectId"], "\(body)")
            XCTAssertEqual(body["terminalId"] as? String, "pty_8")
        }
        for body in bodies[4...] {
            XCTAssertEqual(body["projectId"] as? String, "p1", "\(body)")
        }
    }

    func testCapabilitiesSayWhetherTheHostShares() throws {
        func capabilities(_ json: String) throws -> CapabilitiesResponse {
            try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try capabilities(#"{"interactions":true,"terminal":true,"terminalFeatures":["resume","title","shared"]}"#).sharesTerminals)
        XCTAssertFalse(try capabilities(#"{"interactions":true,"terminal":true,"terminalFeatures":["resume","title"]}"#).sharesTerminals)
        XCTAssertFalse(try capabilities(#"{"interactions":true,"terminal":true}"#).sharesTerminals, "Older hosts share nothing")
        XCTAssertTrue(CapabilitiesResponse(interactions: true, terminal: true, terminalFeatures: ["shared"]).sharesTerminals)
    }

    private func decode(_ json: String) throws -> SharedTerminal {
        try JSONDecoder().decode(SharedTerminal.self, from: Data(json.utf8))
    }

    private func makeClient(_ transport: LineTransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
    }
}
