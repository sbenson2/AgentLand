import AgentLandIroh
import Foundation
import XCTest

/// The Mac's own relay has no publicly trusted certificate. iroh trusts only the
/// Mozilla roots by default; `relayTlsRoots: .custom` trusts exactly the given
/// certificates (our private CA, or the relay's own self-signed certificate), and
/// `.embeddedPlus` trusts the Mozilla roots and them, for an endpoint that also
/// uses n0's relays as a fallback. (That the Mozilla roots still work with
/// `.embeddedPlus` is checked in Rust, `test_relay_tls_roots_trust`: no relay on
/// loopback has a publicly trusted certificate.)
///
/// These tests need the iroh-relay binary; without it they fail (see TestRelay).
final class RelayTLSTests: XCTestCase {
    private var certificates: TestCertificates!
    private var relays: [TestRelay] = []

    override func setUp() async throws {
        _ = try TestRelay.requireBinary()
        certificates = try TestCertificates.make()
    }

    override func tearDown() async throws {
        relays.forEach { $0.stop() }
        relays = []
        certificates?.remove()
    }

    func testRelayIssuedByPrivateCAIsTrustedOnlyWhenTheCAIsPinned() async throws {
        let relay = try TestRelay.startHTTPS(certificate: certificates.issuedCertificate, key: certificates.issuedKey)
        relays.append(relay)

        try await assertNeverOnline(relay, roots: nil)  // iroh's default: Mozilla roots
        try await assertNeverOnline(relay, roots: .embedded)
        try await assertNeverOnline(relay, roots: .custom(certs: [certificates.otherCADER]))
        try await assertNeverOnline(relay, roots: .custom(certs: [certificates.selfSignedDER]))
        try await assertRelayCarriesAConnection(relay, roots: .custom(certs: [certificates.caDER]))
    }

    func testEmbeddedPlusTrustsOurCAAndNoOtherPrivateCA() async throws {
        let relay = try TestRelay.startHTTPS(certificate: certificates.issuedCertificate, key: certificates.issuedKey)
        relays.append(relay)

        try await assertNeverOnline(relay, roots: .embeddedPlus(certs: [certificates.otherCADER]))
        try await assertRelayCarriesAConnection(relay, roots: .embeddedPlus(certs: [certificates.caDER]))
    }

    func testSelfSignedRelayIsTrustedOnlyWhenItsCertificateIsPinned() async throws {
        let relay = try TestRelay.startHTTPS(certificate: certificates.selfSignedCertificate, key: certificates.selfSignedKey)
        relays.append(relay)

        try await assertNeverOnline(relay, roots: nil)
        try await assertNeverOnline(relay, roots: .custom(certs: [certificates.caDER]))
        try await assertRelayCarriesAConnection(relay, roots: .custom(certs: [certificates.selfSignedDER]))
    }

    func testUnusableRootsFailTheBind() async throws {
        for roots in [
            RelayTlsRoots.custom(certs: []),
            .custom(certs: [Data("not a certificate".utf8)]),
            .embeddedPlus(certs: []),
            .embeddedPlus(certs: [Data("not a certificate".utf8)])
        ] {
            do {
                let endpoint = try await Endpoint.bind(options: .test(relayTlsRoots: roots))
                try? await endpoint.close()
                XCTFail("bind succeeded with \(roots)")
            } catch let error as IrohError {
                XCTAssertEqual(error.kind(), .invalidInput, error.message())
            }
        }
    }

    /// Not trusted: the endpoint refuses the relay's certificate (the relay logs
    /// the client's "unknown CA" alert) and never gets its home relay. A trusted
    /// endpoint gets it in about 3 s on loopback; this waits 6 s.
    private func assertNeverOnline(_ relay: TestRelay, roots: RelayTlsRoots?, line: UInt = #line) async throws {
        let alertsBefore = relay.unknownCAAlerts
        let endpoint = try await Endpoint.bind(options: .test(
            relayMode: RelayMode.customFromUrls(urls: [relay.url]),
            relayTlsRoots: roots
        ))
        let refused = await eventually(10) { relay.unknownCAAlerts > alertsBefore }
        XCTAssertTrue(refused, "the relay saw no certificate refusal with \(String(describing: roots))", line: line)
        do {
            try await within(6) { await endpoint.online() }
            XCTFail("online through \(relay.url) with \(String(describing: roots))", line: line)
        } catch is TimedOut {}
        XCTAssertNil(endpoint.addr().relayUrl(), line: line)
        try await endpoint.close()
    }

    /// Trusted: both endpoints get the relay as home relay, and a dial that knows
    /// only the server's ID and relay URL (no IP addresses) reaches it.
    private func assertRelayCarriesAConnection(_ relay: TestRelay, roots: RelayTlsRoots, line: UInt = #line) async throws {
        let alertsBefore = relay.unknownCAAlerts
        let options = try EndpointOptions.test(
            alpns: [tunnelALPN],
            relayMode: RelayMode.customFromUrls(urls: [relay.url]),
            relayTlsRoots: roots
        )
        let server = try await Endpoint.bind(options: options)
        let client = try await Endpoint.bind(options: .test(
            relayMode: RelayMode.customFromUrls(urls: [relay.url]),
            relayTlsRoots: roots
        ))
        try await within(10) { await server.online() }
        try await within(10) { await client.online() }
        XCTAssertEqual(server.addr().relayUrl().map(normalized), normalized(relay.url), line: line)

        let serverSide = Task { () throws -> Void in
            let next = await server.acceptNext()
            let incoming = try XCTUnwrap(next)
            let connection = try await incoming.accept().connect()
            let stream = try await connection.acceptBi()
            let data = try await stream.recv().readToEnd(sizeLimit: 1024)
            try await stream.send().writeAll(buf: data)
            try await stream.send().finish()
            _ = await connection.closed()
        }
        let relayOnly = EndpointAddr(id: server.id(), relayUrl: relay.url, addresses: [])
        let connection = try await within(10) { try await client.connect(addr: relayOnly, alpn: tunnelALPN) }
        let stream = try await connection.openBi()
        try await stream.send().writeAll(buf: Data("through our relay".utf8))
        try await stream.send().finish()
        let echoed = try await stream.recv().readToEnd(sizeLimit: 1024)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "through our relay", line: line)
        XCTAssertTrue(connection.paths().contains { $0.isRelay }, "\(connection.paths())", line: line)
        XCTAssertEqual(relay.unknownCAAlerts, alertsBefore, "a trusted endpoint refused the relay", line: line)

        try connection.close(errorCode: 0, reason: Data())
        try await within(10) { try await serverSide.value }
        try await client.close()
        try await server.close()
    }

    private func normalized(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}
