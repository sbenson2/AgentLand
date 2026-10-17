import Foundation
import XCTest
@testable import AgentLandCore

final class ConnectionContractTests: XCTestCase {
    func testPulseParsesTheHostStreamAndIgnoresUnknownLines() async throws {
        let transport = LineTransport(status: 200, lines: [
            "{\"type\":\"ready\",\"intervalMs\":1500}", "{\"type\":\"beat\"}", "{\"type\":\"later-kind\"}",
            "not json", "{\"type\":\"stopping\"}"
        ])
        let client = try makeClient(transport)
        var events: [HostPulseEvent] = []
        for try await event in try await client.pulse(idleTimeout: 4) { events.append(event) }
        XCTAssertEqual(events, [.ready(interval: 1.5), .beat, .stopping])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/pulse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertEqual(request.timeoutInterval, 4, "The stream's idle limit is what detects a silent host")
    }

    func testPulseFromAnOlderHostReportsTheMissingRoute() async throws {
        let transport = LineTransport(status: 404, lines: ["{\"error\":{\"code\":\"not_found\",\"message\":\"Route not found\"}}"])
        let client = try makeClient(transport)
        do {
            _ = try await client.pulse()
            XCTFail("A missing pulse route must be reported")
        } catch {
            XCTAssertEqual(error as? ClientError, .server(code: "not_found", message: "Route not found"))
        }
    }

    func testTerminalOutputLongPollAsksTheHostToWaitAndOutlastsIt() async throws {
        let transport = LineTransport(status: 200, lines: [], body: Data("{\"data\":\"\",\"cursor\":3,\"reset\":false,\"status\":\"running\"}".utf8))
        let client = try makeClient(transport)
        _ = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 3, wait: 15)
        let request = try XCTUnwrap(transport.requests.first)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "wait" }?.value, "15000")
        XCTAssertGreaterThan(request.timeoutInterval, 15, "The client must not time out before the host's wait ends")
        _ = try await client.terminalOutput(projectID: "p1", terminalID: "t1", cursor: 3)
        let legacy = URLComponents(url: try XCTUnwrap(transport.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(legacy.first { $0.name == "wait" })
    }

    func testRefusedConnectionsAreNotSentButLostOnesStayUncertain() async throws {
        for code in [URLError.Code.cannotConnectToHost, .notConnectedToInternet, .cannotFindHost, .secureConnectionFailed] {
            let client = try makeClient(LineTransport(error: URLError(code)))
            let outcome = await client.sendTerminalInput(projectID: "p1", terminalID: "t1", data: Data("a".utf8))
            XCTAssertEqual(outcome, .failed(.unreachable), "\(code) never reaches the host")
        }
        for code in [URLError.Code.networkConnectionLost, .timedOut, .cancelled] {
            let client = try makeClient(LineTransport(error: URLError(code)))
            let outcome = await client.sendMessage(projectID: "p1", sessionID: "s1", text: "hello")
            XCTAssertEqual(outcome, .uncertain, "\(code) may have reached the host")
        }
        XCTAssertTrue(ClientError.isConnectionFailure(URLError(.timedOut)))
        XCTAssertTrue(ClientError.isConnectionFailure(ClientError.unreachable))
        XCTAssertFalse(ClientError.isConnectionFailure(ClientError.server(code: "not_found", message: "Missing")))
    }

    private func makeClient(_ transport: LineTransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
    }
}

final class LineTransport: APITransport, @unchecked Sendable {
    private let status: Int
    private let lineValues: [String]
    private let body: Data
    private let error: Error?
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    init(status: Int = 200, lines: [String] = [], body: Data = Data(), error: Error? = nil) {
        self.status = status; lineValues = lines; self.body = body; self.error = error
    }
    var requests: [URLRequest] { lock.withLock { storage } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storage.append(request) }
        if let error { throw error }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        lock.withLock { storage.append(request) }
        if let error { throw error }
        let values = lineValues
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
        return (stream, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
