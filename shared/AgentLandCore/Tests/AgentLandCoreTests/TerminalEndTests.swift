import Foundation
import XCTest
@testable import AgentLandCore

/// How terminals end (docs/HOST-API.md "How terminals end").
final class TerminalEndTests: XCTestCase {
    func testOutputCarriesHowTheTerminalEnded() async throws {
        let body = """
        {"data":"","cursor":9,"end":9,"reset":false,"status":"exited","exitCode":1,
         "ended":{"reason":"programExited","at":"2026-10-14T11:41:03.000Z","exitCode":1,"program":"claude",
                  "conversationId":"0F8FAD5B-D9CB-469F-A165-70867728950E"}}
        """
        let client = try makeClient(LineTransport(status: 200, lines: [], body: Data(body.utf8)))
        let output = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 9)
        let ended = try XCTUnwrap(output.ended)
        XCTAssertEqual(ended.reason, .programExited)
        XCTAssertEqual(ended.exitCode, 1)
        XCTAssertEqual(ended.program, "claude")
        XCTAssertEqual(ended.conversationID, "0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertEqual(ended.at, Date(timeIntervalSince1970: 1_791_978_063))
    }

    func testAnEndThisVersionCannotReadCostsNothing() async throws {
        let body = """
        {"data":"","cursor":0,"reset":false,"status":"exited",
         "ended":{"reason":"aNewReason","at":"yesterday","exitCode":"x","device":7,"conversationId":"--print"}}
        """
        let client = try makeClient(LineTransport(status: 200, lines: [], body: Data(body.utf8)))
        let output = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
        XCTAssertEqual(output.status, .exited)
        let ended = try XCTUnwrap(output.ended)
        XCTAssertNil(ended.reason)
        XCTAssertNil(ended.at)
        XCTAssertNil(ended.exitCode)
        XCTAssertNil(ended.device)
        XCTAssertNil(ended.conversationID, "Only a UUID can be resumed")
        // Older hosts send no end.
        let older = try makeClient(LineTransport(status: 200, lines: [], body: Data(#"{"data":"","cursor":0,"reset":false,"status":"exited"}"#.utf8)))
        let plain = try await older.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
        XCTAssertNil(plain.ended)
    }

    func testABackendEndIsItsOwnReason() async throws {
        let body = #"{"data":"","cursor":0,"reset":false,"status":"exited","ended":{"reason":"backendEnded","at":"2026-10-14T11:41:03.000Z","program":"claude"}}"#
        let client = try makeClient(LineTransport(status: 200, lines: [], body: Data(body.utf8)))
        let output = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
        let ended = try XCTUnwrap(output.ended)
        XCTAssertEqual(ended.reason, .backendEnded)
        XCTAssertNil(ended.exitCode)
    }

    func testNewEndReasonsDecode() async throws {
        for (raw, reason) in [("keeperStopped", TerminalEnd.Reason.keeperStopped), ("endedOnMac", .endedOnMac), ("deviceRemoved", .deviceRemoved)] {
            let body = #"{"data":"","cursor":0,"reset":false,"status":"exited","ended":{"reason":""# + raw + #"","at":"2026-10-14T11:41:03.000Z"}}"#
            let client = try makeClient(LineTransport(status: 200, lines: [], body: Data(body.utf8)))
            let output = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
            XCTAssertEqual(output.ended?.reason, reason)
        }
    }

    func testKeptInTerminalReasonDecodes() async throws {
        let body = #"{"data":"","cursor":0,"reset":false,"status":"exited","ended":{"reason":"keptInTerminal","at":"2026-10-14T11:41:03.000Z","program":"claude"}}"#
        let client = try makeClient(LineTransport(status: 200, lines: [], body: Data(body.utf8)))
        let output = try await client.terminalOutput(projectID: "", terminalID: "t1", cursor: 0)
        XCTAssertEqual(output.ended?.reason, .keptInTerminal)
        XCTAssertEqual(output.ended?.at, Date(timeIntervalSince1970: 1_791_978_063))
        let saved = try JSONEncoder().encode(try XCTUnwrap(output.ended))
        XCTAssertEqual(try JSONDecoder().decode(TerminalEnd.self, from: saved).reason, .keptInTerminal)
    }

    func testATerminalTheHostForgotSaysHowItEnded() async throws {
        let body = """
        {"error":{"code":"terminal_not_found","message":"Terminal not found",
                  "ended":{"reason":"endedByDevice","at":"2026-10-14T11:41:03.000Z","device":"Sam’s iPhone","program":"shell"}}}
        """
        let client = try makeClient(LineTransport(status: 404, lines: [], body: Data(body.utf8)))
        do {
            _ = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
            XCTFail("A forgotten terminal must be reported")
        } catch let gone as TerminalGoneError {
            XCTAssertEqual(gone.ended?.reason, .endedByDevice)
            XCTAssertEqual(gone.ended?.device, "Sam’s iPhone")
        }
        // Without a record, the same error with no end; another 404 stays the server's error.
        let bare = try makeClient(LineTransport(status: 404, lines: [], body: Data(#"{"error":{"code":"terminal_not_found","message":"Gone"}}"#.utf8)))
        do {
            _ = try await bare.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
            XCTFail("A forgotten terminal must be reported")
        } catch {
            XCTAssertEqual(error as? TerminalGoneError, TerminalGoneError(ended: nil))
        }
        let project = try makeClient(LineTransport(status: 404, lines: [], body: Data(#"{"error":{"code":"not_found","message":"Missing"}}"#.utf8)))
        do {
            _ = try await project.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 0)
            XCTFail("A missing project must be reported")
        } catch {
            XCTAssertEqual(error as? ClientError, .server(code: "not_found", message: "Missing"))
        }
    }

    func testResumeSendsOnlyTheConversationOrPick() async throws {
        let created = Data(#"{"id":"pty_2","title":"Claude Code","projectId":"p1","status":"running","conversationId":"0f8fad5b-d9cb-469f-a165-70867728950e"}"#.utf8)
        let transport = LineTransport(status: 201, lines: [], body: created)
        let client = try makeClient(transport)
        guard case let .created(terminal) = await client.createTerminal(projectID: "p1", title: "Claude Code", rows: 24, cols: 80, program: "claude",
                                                                        resume: .conversation("0f8fad5b-d9cb-469f-a165-70867728950e")) else {
            return XCTFail("The terminal was not created")
        }
        XCTAssertEqual(terminal.conversationID, "0f8fad5b-d9cb-469f-a165-70867728950e")
        _ = await client.createTerminal(projectID: "p1", title: "Claude Code", rows: 24, cols: 80, program: "claude", resume: .pick)
        _ = await client.createTerminal(projectID: "p1", title: "Terminal", rows: 24, cols: 80)
        let bodies = try transport.requests.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any] }
        XCTAssertEqual(bodies[0]?["resume"] as? String, "0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertEqual(bodies[1]?["resume"] as? String, "pick")
        XCTAssertNil(bodies[2]?["resume"], "A new terminal sends no resume")
        XCTAssertEqual(TerminalResume.validConversation("0F8FAD5B-D9CB-469F-A165-70867728950E"), "0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertNil(TerminalResume.validConversation("pick --print"))
    }

    private func makeClient(_ transport: LineTransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
    }
}
