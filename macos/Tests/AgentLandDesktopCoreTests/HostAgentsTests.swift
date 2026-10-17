import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore

/// `GET /v1/agents` as the Mac reads it (the `opencode` entry's `restartWanted` and `idleForSeconds`), and
/// when the Mac restarts OpenCode on its own. The host is a fake transport.
final class HostAgentsTests: XCTestCase {
    func testTheCatalogDecodesThePlansShapeAndSkipsWhatItCannotRead() throws {
        let json = """
        {"registry": {"fetchedAt": "2026-09-26T20:00:00Z"},
         "agents": [
          {"id": "gemini", "name": "Gemini CLI", "source": "registry", "state": "installed", "installedVersion": "0.61.0",
           "latestVersion": "0.62.0", "chat": true, "terminal": true, "verified": true, "somethingNew": {"a": 1}},
          {"name": "no id"},
          {"id": "opencode", "name": "OpenCode", "source": "registry", "state": "installed", "installedVersion": "1.19.0",
           "restartWanted": true, "idleForSeconds": 734.5},
          {"id": "goose", "idleForSeconds": "soon", "restartWanted": "yes"}
         ]}
        """
        let catalog = try JSONDecoder().decode(HostAgentsCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.agents.map(\.id), ["gemini", "opencode", "goose"], "an entry without an id is skipped")
        XCTAssertEqual(catalog.openCode, HostAgentStatus(id: "opencode", source: "registry", state: "installed",
                                                         installedVersion: "1.19.0", restartWanted: true, idleForSeconds: 734.5))
        XCTAssertNil(catalog.agents[2].idleForSeconds, "a field of the wrong type is dropped, not the entry")
        XCTAssertNil(catalog.agents[2].restartWanted)
        XCTAssertNil(try JSONDecoder().decode(HostAgentsCatalog.self, from: Data("{}".utf8)).openCode)
    }

    func testTheFeedAsksWithTheLocalSessionAndReadsTheAnswer() async throws {
        let transport = FakeAgentsTransport(status: 200, body: #"{"agents":[{"id":"opencode","restartWanted":false,"idleForSeconds":12}]}"#)
        let feed = HostAgentsFeed(baseURL: URL(string: "https://127.0.0.1:9841")!, token: "session-token", transport: transport)
        let catalog = try await feed.agents()
        XCTAssertEqual(catalog.openCode?.idleForSeconds, 12)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://127.0.0.1:9841/v1/agents")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
    }

    func testTheFeedReportsTheHostsRefusalsAndUnreadableAnswers() async throws {
        let base = URL(string: "https://127.0.0.1:9841")!
        let refused = HostAgentsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 404,
            body: #"{"error":{"code":"not_found","message":"No such route."}}"#))
        do { _ = try await refused.agents(); XCTFail("a 404 was read") }
        catch let error as ClientError { XCTAssertEqual(error, .server(code: "not_found", message: "No such route.")) }
        let garbled = HostAgentsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200, body: "not json"))
        do { _ = try await garbled.agents(); XCTFail("garbage was read") }
        catch let error as ClientError { XCTAssertEqual(error, .decoding) }
        let huge = HostAgentsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200,
            body: String(repeating: " ", count: HostAgentsFeed.maximumBytes + 1)))
        do { _ = try await huge.agents(); XCTFail("an oversized answer was read") }
        catch let error as ClientError { XCTAssertEqual(error, .invalidResponse) }
    }

    /// A host from before the catalog (404 `not_found`) and one started with `--no-agents` (501
    /// `agents_unavailable`) have no catalog; other failures are asked again.
    func testAHostWithoutTheCatalogIsToldApartFromOtherFailures() async throws {
        func noCatalog(_ status: Int, _ body: String) async throws -> Bool {
            let feed = HostAgentsFeed(baseURL: URL(string: "https://127.0.0.1:9841")!, token: "t",
                                      transport: FakeAgentsTransport(status: status, body: body))
            do { _ = try await feed.agents() } catch { return HostAgentsFeed.meansNoCatalog(error) }
            throw DesktopError.commandFailed("status \(status) was read as a catalog")
        }
        var answer = try await noCatalog(501, #"{"error":{"code":"agents_unavailable","message":"The agent catalog is off."}}"#)
        XCTAssertTrue(answer, "--no-agents")
        answer = try await noCatalog(501, "")
        XCTAssertTrue(answer)
        answer = try await noCatalog(404, #"{"error":{"code":"not_found","message":"No such route."}}"#)
        XCTAssertTrue(answer, "a host from before the catalog")
        answer = try await noCatalog(404, "")
        XCTAssertTrue(answer)
        answer = try await noCatalog(503, "")
        XCTAssertFalse(answer)
        answer = try await noCatalog(500, #"{"error":{"code":"internal_error","message":"Something failed."}}"#)
        XCTAssertFalse(answer)
        answer = try await noCatalog(200, "not json")
        XCTAssertFalse(answer)
        XCTAssertFalse(HostAgentsFeed.meansNoCatalog(URLError(.timedOut)))
    }

    /// A version that did not start goes to the host with the local session (`POST /v1/agents/opencode/failed`).
    func testAFailedOpenCodeIsReportedWithTheLocalSession() async throws {
        let base = URL(string: "https://127.0.0.1:9841")!
        let transport = FakeAgentsTransport(status: 200, body: #"{"rolledBack":true,"current":"1.18.32"}"#)
        let feed = HostAgentsFeed(baseURL: base, token: "session-token", transport: transport)
        let answer = try await feed.reportOpenCodeFailure(version: "1.18.33", reason: "It stopped before it was ready.")
        XCTAssertEqual(answer, OpenCodeFailureAnswer(rolledBack: true, current: "1.18.32"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://127.0.0.1:9841/v1/agents/opencode/failed")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["version": "1.18.33", "reason": "It stopped before it was ready."])

        let kept = HostAgentsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200, body: #"{"rolledBack":false,"current":""}"#))
        let notRolledBack = try await kept.reportOpenCodeFailure(version: "1.18.33", reason: String(repeating: "x", count: 900))
        XCTAssertEqual(notRolledBack, OpenCodeFailureAnswer(rolledBack: false, current: ""), "no previous version to go back to")

        let refused = HostAgentsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 403,
            body: #"{"error":{"code":"forbidden","message":"Only the Mac's own session."}}"#))
        do { _ = try await refused.reportOpenCodeFailure(version: "1.18.33", reason: "r"); XCTFail("a refusal was read") }
        catch let error as ClientError { XCTAssertEqual(error, .server(code: "forbidden", message: "Only the Mac's own session.")) }
        let older = HostAgentsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 404,
            body: #"{"error":{"code":"not_found","message":"No such route."}}"#))
        do { _ = try await older.reportOpenCodeFailure(version: "1.18.33", reason: "r"); XCTFail("a 404 was read") }
        catch { XCTAssertTrue(HostAgentsFeed.meansNoCatalog(error), "a host without the route never takes the report") }
    }

    func testTheReasonAReportCarriesIsBounded() async throws {
        let transport = FakeAgentsTransport(status: 200, body: #"{"rolledBack":true,"current":"1.18.32"}"#)
        let feed = HostAgentsFeed(baseURL: URL(string: "https://127.0.0.1:9841")!, token: "t", transport: transport)
        _ = try await feed.reportOpenCodeFailure(version: "1.18.33", reason: String(repeating: "x", count: 900))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body["reason"]?.count, 500)
    }

    func testTheRestartDecision() {
        typealias Policy = OpenCodeRestartPolicy
        let wanted = { (idle: Double?) in HostAgentStatus(id: "opencode", restartWanted: true, idleForSeconds: idle) }
        let settled = { (idle: Double?) in HostAgentStatus(id: "opencode", restartWanted: false, idleForSeconds: idle) }

        XCTAssertEqual(Policy.decide(entry: nil, settingsPending: false, binaryWouldChange: false), .nothing)
        XCTAssertEqual(Policy.decide(entry: nil, settingsPending: true, binaryWouldChange: false), .waitForIdle,
                       "a host that does not say how long it has been idle is never idle")
        XCTAssertEqual(Policy.decide(entry: wanted(599), settingsPending: false, binaryWouldChange: true), .waitForIdle)
        XCTAssertEqual(Policy.decide(entry: wanted(600), settingsPending: false, binaryWouldChange: true), .restart([.update]))
        XCTAssertEqual(Policy.decide(entry: wanted(900), settingsPending: false, binaryWouldChange: false), .nothing,
                       "a restart that would run the same OpenCode is no restart")
        XCTAssertEqual(Policy.decide(entry: settled(900), settingsPending: false, binaryWouldChange: true), .nothing,
                       "only the host asks for an update")
        XCTAssertEqual(Policy.decide(entry: settled(900), settingsPending: true, binaryWouldChange: false), .restart([.settings]))
        XCTAssertEqual(Policy.decide(entry: wanted(601), settingsPending: true, binaryWouldChange: true), .restart([.update, .settings]))
        XCTAssertEqual(Policy.decide(entry: wanted(nil), settingsPending: false, binaryWouldChange: true), .waitForIdle)
        XCTAssertEqual(Policy.decide(entry: wanted(.nan), settingsPending: false, binaryWouldChange: true), .waitForIdle)

        // Changed settings restart as soon as nothing runs; a new version alone still waits 10 minutes.
        XCTAssertEqual(Policy.decide(entry: settled(30), settingsPending: true, binaryWouldChange: false), .restart([.settings]))
        XCTAssertEqual(Policy.decide(entry: settled(1), settingsPending: true, binaryWouldChange: false), .restart([.settings]))
        XCTAssertEqual(Policy.decide(entry: settled(0), settingsPending: true, binaryWouldChange: false), .waitForIdle,
                       "something runs: a chat turn, a terminal or a device viewing a chat")
        XCTAssertEqual(Policy.decide(entry: settled(nil), settingsPending: true, binaryWouldChange: false), .waitForIdle)
        XCTAssertEqual(Policy.decide(entry: wanted(30), settingsPending: false, binaryWouldChange: true), .waitForIdle)
        XCTAssertEqual(Policy.decide(entry: wanted(30), settingsPending: true, binaryWouldChange: true), .restart([.update, .settings]),
                       "the restart for settings runs the new version too")
        XCTAssertEqual(Policy.decide(entry: wanted(30), settingsPending: true, binaryWouldChange: false), .restart([.settings]))
        XCTAssertTrue(Policy.isQuiet(settled(1)))
        XCTAssertFalse(Policy.isQuiet(settled(0)))
        XCTAssertFalse(Policy.isQuiet(nil))

        XCTAssertTrue(Policy.shouldCheckBinary(wanted(600)))
        XCTAssertFalse(Policy.shouldCheckBinary(wanted(599)), "the program is read and hashed only when it would matter")
        XCTAssertFalse(Policy.shouldCheckBinary(settled(900)))
        XCTAssertTrue(Policy.shouldCheckBinary(wanted(30), settingsPending: true), "a restart for settings comes now")
        XCTAssertFalse(Policy.shouldCheckBinary(wanted(0), settingsPending: true))
        XCTAssertEqual(Policy.idleSeconds, 600)
        XCTAssertEqual(Policy.pollInterval, .seconds(300))
    }
}

/// Answers every request with one status and body, and keeps the requests.
final class FakeAgentsTransport: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: String
    private var made: [URLRequest] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    var requests: [URLRequest] { lock.withLock { made } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { made.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
