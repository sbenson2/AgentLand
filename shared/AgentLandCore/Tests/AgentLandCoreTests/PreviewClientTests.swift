import Foundation
import XCTest
@testable import AgentLandCore

/// The preview routes (docs/HOST-API.md, "Preview (browser tab)") through the production URLSession path.
final class PreviewClientTests: XCTestCase {
    private func client(_ address: String = "https://mac.example:9841") throws -> APIClient {
        APIClient(address: try ServerAddress(validating: address), token: "device-token", transport: ArchiveStubTransport())
    }

    private static let secret = "q2VwX0Qm1Yw9s8Q3Jc4oZtS7hHn5aR0vL6pUe2dGk1I"

    func testPortsListProcessNamesOnly() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/preview/ports")
            return (200, Data(#"{"ports":[{"port":3000,"address":"*","process":"node"},{"port":5173,"address":"127.0.0.1","process":""},{"port":8000,"address":"::1"}]}"#.utf8))
        }
        let ports = try await client().previewPorts()
        XCTAssertEqual(ports, [PreviewPort(port: 3000, address: "*", process: "node"), PreviewPort(port: 5173, address: "127.0.0.1"),
                               PreviewPort(port: 8000, address: "::1")])
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token",
                       "The API is the only place the device token goes")

        ArchiveStubProtocol.install { _, _ in (403, Data(#"{"error":{"code":"preview_disabled","message":"Enable web previews explicitly on your AgentLand host"}}"#.utf8)) }
        do {
            _ = try await client().previewPorts()
            XCTFail("a host without previews must refuse")
        } catch let error as ClientError {
            XCTAssertEqual(error, .server(code: "preview_disabled", message: "Enable web previews explicitly on your AgentLand host"))
        }
    }

    func testCreatingASessionReturnsAGrantWhoseSecretStaysOutOfDescriptions() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/preview/sessions")
            return (201, Data(#"{"sessionId":"4f1c","previewPort":9842,"cookie":{"name":"__Host-agentland-preview","value":"\#(Self.secret)","maxAgeSeconds":43200}}"#.utf8))
        }
        let outcome = await (try client()).createPreviewSession(port: 5173)
        guard case let .created(grant) = outcome else { return XCTFail("\(outcome)") }
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Int], ["port": 5173])
        XCTAssertEqual(grant.sessionID, "4f1c")
        XCTAssertEqual(grant.previewPort, 9842)
        XCTAssertEqual(grant.cookie.value, Self.secret)
        XCTAssertEqual(grant.cookie.maxAgeSeconds, 43_200)

        var dumped = ""
        dump(grant, to: &dumped)
        for text in [String(describing: grant), String(reflecting: grant), String(describing: grant.cookie), dumped, "\(outcome)"] {
            XCTAssertFalse(text.contains(Self.secret), "The secret never reaches a description: \(text)")
        }
    }

    func testCreateReportsTheHostsReasonsAndUncertainOutcomes() async throws {
        let api = try client()
        let refusals = [
            (403, "preview_disabled", "Enable web previews explicitly on your AgentLand host"),
            (404, "port_not_listening", "Nothing on this computer is listening on that port"),
            (403, "port_not_allowed", "AgentLand does not open this port in web previews"),
            (429, "preview_session_limit", "Close a web preview before opening another"),
            (403, "preview_unavailable", "This Mac opens its own ports directly; web previews are for paired devices"),
        ]
        for (status, code, message) in refusals {
            ArchiveStubProtocol.install { _, _ in (status, Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)) }
            let outcome = await api.createPreviewSession(port: 22)
            XCTAssertEqual(outcome, .failed(.server(code: code, message: message)), code)
        }
        ArchiveStubProtocol.install { _, _ in throw URLError(.timedOut) }
        let timedOut = await api.createPreviewSession(port: 5173)
        XCTAssertEqual(timedOut, .uncertain)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotFindHost) }
        let unreachable = await api.createPreviewSession(port: 5173)
        XCTAssertEqual(unreachable, .failed(.unreachable))
    }

    func testSessionsListAndRevoke() async throws {
        ArchiveStubProtocol.install { request, _ in
            switch request.url?.path {
            case "/v1/preview/sessions":
                return (200, Data(#"{"sessions":[{"sessionId":"4f1c","port":5173,"createdAt":"2026-09-24T10:00:00.000Z","lastUsedAt":"2026-09-24T10:05:00.000Z","expiresAt":"2026-09-24T22:00:00.000Z"}]}"#.utf8))
            case "/v1/preview/sessions/revoke":
                return (200, Data(#"{"revoked":true}"#.utf8))
            default:
                return (404, Data(#"{"error":{"code":"not_found","message":"Not found"}}"#.utf8))
            }
        }
        let api = try client()
        let sessions = try await api.previewSessions()
        XCTAssertEqual(sessions.map(\.port), [5173])
        XCTAssertEqual(sessions.first?.expiresAt?.timeIntervalSince(try XCTUnwrap(sessions.first?.createdAt)), 43_200)
        let revoked = await api.revokePreviewSession(id: "4f1c")
        XCTAssertEqual(revoked, .revoked)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(ArchiveStubProtocol.requests.last?.body)) as? [String: String],
                       ["sessionId": "4f1c"])

        ArchiveStubProtocol.install { _, _ in (404, Data(#"{"error":{"code":"preview_session_not_found","message":"Preview session not found for this device"}}"#.utf8)) }
        let gone = await api.revokePreviewSession(id: "4f1c")
        XCTAssertEqual(gone, .failed(.server(code: "preview_session_not_found", message: "Preview session not found for this device")))
    }

    /// The cookie belongs to the preview origin's host only, and follows the contract's attributes.
    func testCookieIsHostOnlySecureHttpOnlyAndStrict() throws {
        let grant = PreviewSessionGrant(sessionID: "4f1c", previewPort: 9842, cookie: PreviewCookie(value: Self.secret))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cookie = try XCTUnwrap(grant.httpCookie(for: try XCTUnwrap(URL(string: "https://Mac.Example:9842/")), now: now))
        XCTAssertEqual(cookie.name, "__Host-agentland-preview")
        XCTAssertEqual(cookie.value, Self.secret)
        XCTAssertEqual(cookie.domain, "mac.example", "No leading dot: a host-only cookie")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSitePolicy, .sameSiteStrict)
        XCTAssertEqual(cookie.expiresDate, now.addingTimeInterval(43_200))
        XCTAssertFalse(cookie.isSessionOnly)
        XCTAssertNil(grant.httpCookie(for: try XCTUnwrap(URL(string: "http://mac.example:9842/"))), "Never for a plain-http origin")
        let loopback = try XCTUnwrap(grant.httpCookie(for: try XCTUnwrap(URL(string: "https://[::1]:9842/"))))
        XCTAssertEqual(loopback.domain, "::1")
    }

    func testPreviewOriginIsTheHostWithThePreviewPortAndNoPath() throws {
        XCTAssertEqual(try ServerAddress(validating: "https://mac.example:9841").previewOrigin(port: 9842)?.absoluteString, "https://mac.example:9842/")
        XCTAssertEqual(try ServerAddress(validating: "https://mac.example/agentland").previewOrigin(port: 9842)?.absoluteString, "https://mac.example:9842/")
        XCTAssertEqual(try ServerAddress(validating: "https://100.101.102.103:9841").previewOrigin(port: 9842)?.absoluteString, "https://100.101.102.103:9842/")
        XCTAssertEqual(try ServerAddress(validating: "https://[::1]:9841").previewOrigin(port: 9842)?.absoluteString, "https://[::1]:9842/")
        XCTAssertNil(try ServerAddress(validating: "https://mac.example:9841").previewOrigin(port: 0))
        XCTAssertNil(try ServerAddress(validating: "https://mac.example:9841").previewOrigin(port: 70_000))
    }

    func testCapabilitiesNameTheListenersSchemeAndFeatures() throws {
        let current = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true,"preview":{"port":9842,"scheme":"https","features":["revokeAll","later"]}}"#.utf8))
        XCTAssertEqual(current.preview, PreviewCapabilities(port: 9842, scheme: "https", features: ["revokeAll", "later"]))
        XCTAssertTrue(current.preview?.supports(.revokeAll) == true)
        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true,"preview":{"port":9842}}"#.utf8))
        XCTAssertEqual(older.preview, PreviewCapabilities(port: 9842))
        XCTAssertNil(older.preview?.scheme)
        XCTAssertFalse(older.preview?.supports(.revokeAll) ?? true, "Hosts before preview.features take no all")
        XCTAssertEqual(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: try JSONEncoder().encode(current)), current)
    }

    /// The origin is the advertised scheme and port with the host name this device connected to.
    func testPreviewOriginTakesTheAdvertisedScheme() throws {
        let address = try ServerAddress(validating: "https://mac.example:9841")
        XCTAssertEqual(address.previewOrigin(port: 9842, scheme: "https")?.absoluteString, "https://mac.example:9842/")
        XCTAssertEqual(address.previewOrigin(port: 9842, scheme: "HTTPS")?.absoluteString, "https://mac.example:9842/")
        XCTAssertEqual(address.previewOrigin(port: 9842, scheme: nil)?.absoluteString, "https://mac.example:9842/", "An older host's is the address's")
        XCTAssertNil(address.previewOrigin(port: 9842, scheme: "http"), "Only secure origins")
        XCTAssertNil(address.previewOrigin(port: 0, scheme: "https"))
        let tailnet = try ServerAddress(validating: "https://studio.tail0000.ts.net/agentland")
        XCTAssertEqual(tailnet.previewOrigin(PreviewCapabilities(port: 9443, scheme: "https"))?.absoluteString, "https://studio.tail0000.ts.net:9443/",
                       "The name this device connected to, never another")
    }

    func testRevokeAllEndsThisDevicesSessions() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/preview/sessions/revoke")
            return (200, Data(#"{"revoked":true,"count":3}"#.utf8))
        }
        let api = try client()
        let outcome = await api.revokeAllPreviewSessions()
        XCTAssertEqual(outcome, .revoked)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(ArchiveStubProtocol.requests.last?.body)) as? [String: Bool], ["all": true])

        ArchiveStubProtocol.install { _, _ in (400, Data(#"{"error":{"code":"invalid_request","message":"Invalid JSON request"}}"#.utf8)) }
        let older = await api.revokeAllPreviewSessions()
        XCTAssertEqual(older, .failed(.server(code: "invalid_request", message: "Invalid JSON request")))
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        let lost = await api.revokeAllPreviewSessions()
        XCTAssertEqual(lost, .uncertain)
        XCTAssertEqual(ArchiveStubProtocol.requests.count, 1, "Nothing is sent again")
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await api.revokeAllPreviewSessions()
        XCTAssertEqual(unreachable, .failed(.unreachable))
    }

    func testTheClientsCertificateCheckIsTheTransports() throws {
        let address = try ServerAddress(validating: "https://mac.example:9841")
        let pinned = APIClient(address: address, token: "t", transport: URLSessionTransport(expectedHost: "mac.example", certificateSHA256: String(repeating: "ab", count: 32)))
        XCTAssertNotNil(pinned.serverTrust)
        XCTAssertEqual(pinned.serverTrust?.evaluate(authenticationMethod: NSURLAuthenticationMethodServerTrust, host: "mac.example", serverTrust: nil).0,
                       .cancelAuthenticationChallenge, "A pinned client refuses a challenge without the pinned certificate")
        XCTAssertNil(APIClient(address: address, token: "t", transport: ArchiveStubTransport()).serverTrust)
    }
}
