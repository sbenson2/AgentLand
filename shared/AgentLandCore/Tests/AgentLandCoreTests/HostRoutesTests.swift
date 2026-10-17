import CryptoKit
import Foundation
import Security
import XCTest
@testable import AgentLandCore

final class HostRoutesTests: XCTestCase {
    private let pin = String(repeating: "ab", count: 32)

    // MARK: Decoding and keeping routes

    func testCapabilitiesReadTheRoutesThisVersionCanUseAndIgnoreTheRest() throws {
        let body = """
        {"interactions":false,"terminal":true,"routes":[
          {"kind":"local","host":"Robins-Mac-mini.local.","port":9841},
          {"kind":"tailscale","host":"robins-mac-mini.tail1a2b3c.ts.net","addresses":["100.88.12.34","not-an-ip","FD7A:115C:A1E0::1","100.88.12.34"],"port":9841},
          {"kind":"relay","host":"https://relay.example","port":443},
          {"kind":"local","host":"mac.local","port":0},
          {"kind":"local","port":9841},
          "a string",
          {"kind":"future","host":"10.0.0.2","port":9841,"extra":{"nested":true}}
        ]}
        """
        let capabilities = try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(body.utf8))
        let routes = try XCTUnwrap(capabilities.routes)
        XCTAssertEqual(routes.map(\.kind), ["local", "tailscale", "future"])
        XCTAssertEqual(routes.first?.host, "robins-mac-mini.local", "Names are kept in lower case without the trailing dot")
        XCTAssertEqual(routes[1].addresses, ["100.88.12.34", "fd7a:115c:a1e0::1"], "Only IP addresses, once each")
        XCTAssertTrue(routes[1].isTailscale)

        let without = try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(#"{"interactions":false,"terminal":true}"#.utf8))
        XCTAssertNil(without.routes, "Hosts before routes list none")
        let unreadable = try JSONDecoder().decode(CapabilitiesResponse.self,
                                                  from: Data(#"{"interactions":false,"terminal":true,"routes":{"kind":"local"}}"#.utf8))
        XCTAssertNil(unreadable.routes, "Routes this version cannot read cost nothing else")
        XCTAssertTrue(unreadable.terminal)
    }

    func testRoutesRoundTripAndAreBounded() throws {
        let many = (0..<12).map { index in
            [String: Any](dictionaryLiteral: ("kind", "local"), ("host", "mac\(index).local"), ("port", 9841))
        }
        let data = try JSONSerialization.data(withJSONObject: ["interactions": false, "terminal": true, "routes": many])
        XCTAssertEqual(try JSONDecoder().decode(CapabilitiesResponse.self, from: data).routes?.count, HostRoute.maximumRoutes)

        let route = try XCTUnwrap(HostRoute(kind: "tailscale", host: "mac.tail.ts.net", addresses: ["100.64.0.1"], port: 9841))
        let encoded = try JSONEncoder().encode([route, try XCTUnwrap(HostRoute(kind: "local", host: "mac.local", port: 9841))])
        XCTAssertEqual(try JSONDecoder().decode([HostRoute].self, from: encoded).map(\.host), ["mac.tail.ts.net", "mac.local"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(#""addresses":[]"#), "A route without addresses leaves them out")
    }

    func testAConnectionLearnsTheHostsRoutesAndKeepsAKnownTailscaleRoute() throws {
        let local = try XCTUnwrap(HostRoute(kind: "local", host: "mac.local", port: 9841))
        let tailscale = try XCTUnwrap(HostRoute(kind: "tailscale", host: "mac.tail.ts.net", addresses: ["100.64.0.1"], port: 9841))
        let moved = try XCTUnwrap(HostRoute(kind: "tailscale", host: "mac.other.ts.net", addresses: ["100.64.0.9"], port: 9841))
        XCTAssertEqual(HostRoute.merged(saved: [], advertised: [local, tailscale]), [local, tailscale], "A device paired before routes learns them")
        XCTAssertEqual(HostRoute.merged(saved: [local, tailscale], advertised: [local]), [local, tailscale],
                       "Tailscale briefly off on the Mac does not make the device forget the way in")
        XCTAssertEqual(HostRoute.merged(saved: [local, tailscale], advertised: [local, moved]), [local, moved], "A route of the same kind is replaced")
    }

    func testCandidatesTryTheLastWorkingRouteFirstThenThePairedAddress() throws {
        let primary = try XCTUnwrap(HostEndpoint(address: ServerAddress(validating: "https://Robins-Mac-mini.local:9841")))
        XCTAssertEqual(primary.host, "robins-mac-mini.local")
        let routes = [try XCTUnwrap(HostRoute(kind: "local", host: "robins-mac-mini.local", port: 9841)),
                      try XCTUnwrap(HostRoute(kind: "tailscale", host: "mac.tail.ts.net", addresses: ["100.64.0.1", "fd7a::1"], port: 9841))]
        XCTAssertEqual(HostEndpoint.candidates(primary: primary, routes: routes).map(\.authority),
                       ["robins-mac-mini.local:9841", "mac.tail.ts.net:9841", "100.64.0.1:9841", "[fd7a::1]:9841", "robins-mac-mini:9841"])
        let tailscaleIP = try XCTUnwrap(HostEndpoint(host: "100.64.0.1", port: 9841))
        XCTAssertEqual(HostEndpoint.candidates(primary: primary, routes: routes, preferred: tailscaleIP).map(\.authority),
                       ["100.64.0.1:9841", "robins-mac-mini.local:9841", "mac.tail.ts.net:9841", "[fd7a::1]:9841", "robins-mac-mini:9841"])
        // Paired before routes existed: the paired name's short form, which MagicDNS resolves while
        // Tailscale is on, is the one other address to try.
        XCTAssertEqual(HostEndpoint.candidates(primary: primary, routes: []).map(\.authority),
                       ["robins-mac-mini.local:9841", "robins-mac-mini:9841"])
        for other in ["https://studio.example.com:9841", "https://localhost:9841", "https://mac.lan.local:9841"] {
            let endpoint = try XCTUnwrap(HostEndpoint(address: ServerAddress(validating: other)))
            XCTAssertEqual(HostEndpoint.candidates(primary: endpoint, routes: []), [endpoint], other)
        }
        let forgotten = try XCTUnwrap(HostEndpoint(host: "10.0.0.9", port: 9841))
        XCTAssertEqual(HostEndpoint.candidates(primary: primary, routes: routes, preferred: forgotten).first, primary,
                       "A remembered route the host no longer lists is not tried")
    }

    // MARK: The race

    func testTheRaceKeepsTheFirstAnswerAndNeverWaitsOnARouteThatFailed() async {
        let started = StartLog()
        // The last route that worked answers: nothing else is tried.
        let quick = await RouteRace.first(["last", "other"], stagger: .milliseconds(200)) { name in
            started.add(name)
            return name == "last"
        }
        XCTAssertEqual(quick, "last")
        XCTAssertEqual(started.names, ["last"])

        // It fails at once: the next starts without waiting for its turn.
        started.reset()
        let clock = ContinuousClock()
        let begun = clock.now
        let failover = await RouteRace.first(["dead", "tailscale"], stagger: .seconds(5)) { name in
            started.add(name)
            return name == "tailscale"
        }
        XCTAssertEqual(failover, "tailscale")
        XCTAssertLessThan(clock.now - begun, .seconds(2))
        XCTAssertEqual(started.names, ["dead", "tailscale"])

        // It hangs: the next starts after the stagger and wins; the hung probe is cancelled.
        started.reset()
        let cancelled = StartLog()
        let hung = await RouteRace.first(["hung", "tailscale"], stagger: .milliseconds(50)) { name in
            started.add(name)
            if name == "hung" {
                do { try await Task.sleep(for: .seconds(10)) } catch { cancelled.add(name) }
                return false
            }
            return true
        }
        XCTAssertEqual(hung, "tailscale")
        XCTAssertEqual(cancelled.names, ["hung"])

        let none = await RouteRace.first(["a", "b", "c"], stagger: .milliseconds(20)) { _ in false }
        XCTAssertNil(none)
        let empty = await RouteRace.first([String](), probe: { _ in true })
        XCTAssertNil(empty)
    }

    func testARetryingRaceReportsTheFailureAtOnceAndFindsAHostThatComesBackDespiteAHungAddress() async {
        // At home, the Mac's app stopped: its local address is refused, the Tailscale name does not
        // resolve and the Tailscale address hangs until its timeout. Then the app starts again.
        let comesBack = ContinuousClock().now + .milliseconds(300)
        let failures = StartLog()
        let started = StartLog()
        let clock = ContinuousClock()
        let begun = clock.now
        let winner = await RouteRace.first(["local", "name", "hung"], stagger: .milliseconds(20),
                                           retryAfter: [.milliseconds(50), .milliseconds(100)],
                                           failed: { index in failures.add(String(index)) }) { name in
            started.add(name)
            switch name {
            case "hung":
                try? await Task.sleep(for: .seconds(5))
                return false
            case "local": return ContinuousClock().now >= comesBack
            default: return false
            }
        }
        XCTAssertEqual(winner, "local")
        XCTAssertLessThan(clock.now - begun, .seconds(2), "The hung address never held up the one that came back")
        XCTAssertEqual(failures.names.first, "0", "The address in use is reported as failed before anything else")
        XCTAssertEqual(started.names.filter { $0 == "hung" }.count, 1)
        XCTAssertGreaterThan(started.names.filter { $0 == "local" }.count, 1, "The failed address is probed again on the schedule")

        // Nothing answers: the race goes on until its task is cancelled.
        let endless = Task { await RouteRace.first(["a", "b"], stagger: .milliseconds(10), retryAfter: [.milliseconds(20)]) { _ in false } }
        try? await Task.sleep(for: .milliseconds(200))
        endless.cancel()
        let ended = await endless.value
        XCTAssertNil(ended)
    }

    func testCapabilitiesReadWhatTheHostLastReadOfTailscale() throws {
        let body = #"{"interactions":false,"terminal":true,"routes":[{"kind":"local","host":"mac.local","port":9841}],"tailscale":"notListening"}"#
        XCTAssertEqual(try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(body.utf8)).tailscale, "notListening")
        let odd = #"{"interactions":false,"terminal":true,"tailscale":{"state":1}}"#
        XCTAssertNil(try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(odd.utf8)).tailscale)
    }

    // MARK: The routed transport

    func testOnlyPinnedHostsAtTheirRootRoute() throws {
        let address = try ServerAddress(validating: "https://mac.local:9841")
        XCTAssertNil(RoutedTransport(address: address, certificateSHA256: nil), "A publicly trusted host keeps its one address")
        XCTAssertNil(RoutedTransport(address: address, certificateSHA256: "abc"))
        XCTAssertNil(RoutedTransport(address: try ServerAddress(validating: "https://proxy.example/agentland"), certificateSHA256: pin))
        XCTAssertNotNil(RoutedTransport(address: address, certificateSHA256: pin.uppercased()))
    }

    func testRequestsGoToTheChosenEndpointWithTheirPathAndQuery() async throws {
        let transport = try routed()
        let api = APIClient(address: try ServerAddress(validating: "https://mac.local:9841"), token: "device-token", transport: transport)
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"projects":[]}"#.utf8)) }
        _ = try await api.projects()
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.url?.absoluteString, "https://mac.local:9841/v1/projects")

        transport.use(try XCTUnwrap(HostEndpoint(host: "100.64.0.1", port: 9841)))
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"sessions":[]}"#.utf8)) }
        _ = try await api.sessions(projectID: "p 1")
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        XCTAssertEqual(sent.url?.absoluteString, "https://100.64.0.1:9841/v1/sessions?projectId=p%201")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")

        transport.use(try XCTUnwrap(HostEndpoint(host: "[FD7A::1]", port: 9841)))
        _ = try await api.sessions(projectID: "p")
        XCTAssertEqual(ArchiveStubProtocol.requests.last?.request.url?.absoluteString, "https://[fd7a::1]:9841/v1/sessions?projectId=p")
    }

    func testAReadLostToTheOldRouteGoesOnceToTheNewOneButASendNeverDoes() async throws {
        let transport = try routed()
        let api = APIClient(address: try ServerAddress(validating: "https://mac.local:9841"), token: "device-token", transport: transport)
        let tailscale = try XCTUnwrap(HostEndpoint(host: "100.64.0.1", port: 9841))
        // The request on the local name fails while the app moves to Tailscale.
        ArchiveStubProtocol.install { request, _ in
            if request.url?.host == "mac.local" {
                transport.use(tailscale)
                throw URLError(.networkConnectionLost)
            }
            return (200, Data(#"{"projects":[{"id":"p","name":"Project"}]}"#.utf8))
        }
        let projects = try await api.projects()
        XCTAssertEqual(projects.map(\.id), ["p"])
        XCTAssertEqual(ArchiveStubProtocol.requests.map { $0.request.url?.host ?? "" }, ["mac.local", "100.64.0.1"])

        transport.use(transport.primary)
        ArchiveStubProtocol.install { request, _ in
            if request.url?.host == "mac.local" {
                transport.use(tailscale)
                throw URLError(.networkConnectionLost)
            }
            return (202, Data(#"{"accepted":true}"#.utf8))
        }
        let outcome = await api.sendMessage(projectID: "p", sessionID: "s", text: "hello")
        XCTAssertEqual(outcome, .uncertain, "A send whose connection was lost stays uncertain")
        XCTAssertEqual(ArchiveStubProtocol.requests.count, 1, "and is never sent again by itself")

        // A read that failed on the route still chosen is not repeated either.
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await api.projects()
            XCTFail("An unreachable route is reported")
        } catch {}
        XCTAssertEqual(ArchiveStubProtocol.requests.count, 1)
    }

    func testProbeAsksForHealthAtOneEndpoint() async throws {
        let transport = try routed()
        let tailscale = try XCTUnwrap(HostEndpoint(host: "mac.tail.ts.net", port: 9841))
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://mac.tail.ts.net:9841/v1/health")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The probe carries no credential")
            return (200, Data(#"{"status":"ok","protocolVersion":1}"#.utf8))
        }
        let answered = await transport.probe(tailscale, timeout: 2)
        XCTAssertTrue(answered)
        XCTAssertEqual(transport.endpoint, transport.primary, "Probing does not move the requests")
        ArchiveStubProtocol.install { _, _ in (503, Data()) }
        let refused = await transport.probe(tailscale, timeout: 2)
        XCTAssertFalse(refused)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotFindHost) }
        let missing = await transport.probe(tailscale, timeout: 2)
        XCTAssertFalse(missing)
    }

    func testEveryEndpointPinsThePairedCertificateAndValidatesThePairedName() throws {
        // The test certificate names `localhost`; the device paired at https://localhost:9841.
        let certificate = TestCertificate.localhost
        let fingerprint = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        let transport = try XCTUnwrap(RoutedTransport(address: try ServerAddress(validating: "https://localhost:9841"), certificateSHA256: fingerprint))
        let alternate = try XCTUnwrap(HostEndpoint(host: "127.0.0.1", port: 9841))
        let method = NSURLAuthenticationMethodServerTrust

        let routedTrust = transport.serverTrust(for: alternate)
        XCTAssertEqual(routedTrust.evaluate(authenticationMethod: method, host: "127.0.0.1", serverTrust: try trust(certificate)).0, .useCredential,
                       "The paired certificate is accepted at another address, validated for the paired name")
        XCTAssertEqual(routedTrust.evaluate(authenticationMethod: method, host: "10.0.0.5", serverTrust: try trust(certificate)).0,
                       .cancelAuthenticationChallenge, "A challenge from another address than the endpoint's is refused")

        let other = String(fingerprint.dropLast()) + (fingerprint.last == "0" ? "1" : "0")
        let wrongPin = try XCTUnwrap(RoutedTransport(address: try ServerAddress(validating: "https://localhost:9841"), certificateSHA256: other))
        XCTAssertEqual(wrongPin.serverTrust(for: alternate).evaluate(authenticationMethod: method, host: "127.0.0.1",
                                                                               serverTrust: try trust(certificate)).0,
                       .cancelAuthenticationChallenge, "Another certificate at the alternate address is refused")

        let renamed = try XCTUnwrap(RoutedTransport(address: try ServerAddress(validating: "https://studio.local:9841"), certificateSHA256: fingerprint))
        XCTAssertEqual(renamed.serverTrust(for: alternate).evaluate(authenticationMethod: method, host: "127.0.0.1",
                                                                              serverTrust: try trust(certificate)).0,
                       .cancelAuthenticationChallenge, "The certificate must name the host the device paired with")

        let ipv6 = try XCTUnwrap(HostEndpoint(host: "::1", port: 9841))
        XCTAssertEqual(transport.serverTrust(for: ipv6).evaluate(authenticationMethod: method, host: "[::1]", serverTrust: try trust(certificate)).0,
                       .useCredential, "An IPv6 endpoint matches its challenge with or without brackets")
    }

    // MARK: Helpers

    private func routed() throws -> RoutedTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveStubProtocol.self]
        return try XCTUnwrap(RoutedTransport(address: try ServerAddress(validating: "https://mac.local:9841"), certificateSHA256: pin,
                                             transports: { endpoint, _ in
            URLSessionTransport(expectedHost: endpoint.host, certificateSHA256: nil, validatedCertificateHost: nil, configuration: configuration)
        }))
    }

    private func trust(_ certificate: Data) throws -> SecTrust {
        let value = try XCTUnwrap(SecCertificateCreateWithData(nil, certificate as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(value, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let created = try XCTUnwrap(trust)
        // 2027-01-01, inside the certificate's validity.
        XCTAssertEqual(SecTrustSetVerifyDate(created, Date(timeIntervalSince1970: 1_798_761_600) as CFDate), errSecSuccess)
        return created
    }
}

/// The throwaway `localhost` certificate of `PinnedTrustEvaluatorTests`.
enum TestCertificate {
    static let localhost = Data(base64Encoded: """
        MIIB7zCCAZWgAwIBAgIUHuut2nEbc+wxdsAhztAYld/P/uwwCgYIKoZIzj0EAwIwLTESMBAGA1UEAwwJbG9jYWxob3N0MRcw\
        FQYDVQQKDA5BZ2VudExhbmQgdGVzdDAeFw0yNjA5MDEwMDAwMDBaFw0yNzA5MDEwMDAwMDBaMC0xEjAQBgNVBAMMCWxvY2Fs\
        aG9zdDEXMBUGA1UECgwOQWdlbnRMYW5kIHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASmO5voPxaWj78tIv4il9mp\
        z9HvdDEUWeP2KjqI9mgvP9HdiVRp61l35gdsMfX5kgJPm/WgcZhEhd1CY0LbW78lo4GSMIGPMB0GA1UdDgQWBBQhJoMfOhsc\
        piATSWsF6peqsZZ21jAfBgNVHSMEGDAWgBQhJoMfOhscpiATSWsF6peqsZZ21jAUBgNVHREEDTALgglsb2NhbGhvc3QwEwYD\
        VR0lBAwwCgYIKwYBBQUHAwEwDgYDVR0PAQH/BAQDAgKEMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYIKoZIzj0EAwIDSAAwRQIg\
        cNiqlkkPpQ/2oBT4r2u9kQt/lWJOCTyeccdPlyOCauICIQDUIiOmHmvpVQLWR0KHLQc/ybj/s4WvdStI77LHZgze+Q==
        """)!
}

private final class StartLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ name: String) { lock.withLock { values.append(name) } }
    func reset() { lock.withLock { values = [] } }
    var names: [String] { lock.withLock { values } }
}
