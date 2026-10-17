import Foundation
import Synchronization
import XCTest
@testable import AgentLandCore

/// The phone's rules around the tunnel (docs/HOST-API.md "Remote access (iroh)"): which relays it
/// dials, the gate's close codes, the tunnel's schedule, the record's schedule, the kept entry, the
/// pulse's remote-access line, the tunnel as a route of its own in the race and in the transport.
final class RemoteAccessPhoneTests: XCTestCase {
    private let mac = IrohNodeID(hex: String(repeating: "b", count: 64))!

    // MARK: Relays a device dials

    /// A relay's host follows the rule of direct addresses: a global unicast address or a public DNS
    /// name. Anything on the network the phone is on, or a name that resolves there, is refused.
    func testADeviceDialsOnlyRelaysOnPublicHosts() {
        for good in ["https://use1-1.relay.n0.iroh.link./", "https://euw1-1.relay.n0.iroh.link", "https://relay.example.com/",
                     "https://1.2.3.4/", "https://[2a01:4f8::7]:443/", "https://relay.n0.iroh.link:8443/"] {
            XCTAssertTrue(RemoteAccessCapabilities.isDialableRelayURL(good), good)
        }
        for bad in ["https://127.0.0.1/", "https://127.0.0.1:3340/", "https://[::1]/", "https://192.168.1.1/", "https://10.0.0.1:8443/",
                    "https://172.20.0.1/", "https://169.254.1.1/", "https://[fe80::1]/", "https://[fd7a:115c:a1e0::1]/", "https://100.64.0.1/",
                    "https://[::ffff:192.168.1.1]/", "https://0.0.0.0/", "https://224.0.0.1/", "https://[2001:db8::1]/", "https://203.0.113.7/",
                    "https://localhost/", "https://relay.localhost/", "https://mac.local/", "https://mac.local./", "https://relay/",
                    "https://127.1/", "https://0x7f.1/", "https://2130706433/", "https://relay.internal/", "https://router.home.arpa/",
                    "https://abc.onion/", "https://1.0.0.127.in-addr.arpa/", "https://relay.example./", "https://relay.test/",
                    "https://relay.invalid/", "https://x.alt/", "http://relay.n0.iroh.link/", "https://relay.n0.iroh.link:0/",
                    "https://relay.n0.iroh.link/path", "https://-relay.link/", "https://relay..link/"] {
            XCTAssertFalse(RemoteAccessCapabilities.isDialableRelayURL(bad), bad)
        }
    }

    /// The low finding: the address record's relay was taken whatever its host. Whoever can write the
    /// owner's iCloud could point the phone's endpoint at a relay on the network it is on. Now a relay
    /// on a loopback, private or link-local host is dropped, from the record and from capabilities.
    func testTheRecordAndCapabilitiesDropARelayOnTheLocalNetwork() throws {
        for local in ["https://127.0.0.1:3340/", "https://192.168.1.10/", "https://[fe80::1]/", "https://mac.local./", "https://localhost:443/"] {
            let record = try XCTUnwrap(RemoteAccessAddressRecord(nodeID: mac.hex, directAddresses: [], relayURL: local, sequence: 9))
            XCTAssertNil(record.relayURL, local)
            let kept = RemoteAccessCapabilities(enabled: false, nodeID: mac, sequence: 8)
            XCTAssertEqual(kept.tunnelRoute(record: record), .none, "a record with nothing a device dials is no way in: \(local)")

            let json = #"{"version":1,"enabled":true,"nodeId":"\#(mac.hex)","directAddresses":[],"fallbackRelay":true,"relayUrl":"\#(local)","sequence":3}"#
            let entry = try JSONDecoder().decode(RemoteAccessCapabilities.self, from: Data(json.utf8))
            XCTAssertNil(entry.relayURL, local)
            XCTAssertFalse(entry.offersTunnel, local)
        }
        let publicRelay = "https://use1-1.relay.n0.iroh.link./"
        let record = try XCTUnwrap(RemoteAccessAddressRecord(nodeID: mac.hex, directAddresses: [], relayURL: publicRelay, sequence: 9))
        XCTAssertEqual(record.relayURL, publicRelay)
    }

    /// A public DNS name can resolve to an address on the phone's network (or be a relay whoever wrote
    /// the record runs), so the address record gives only one of n0's relays, the only relays the Mac's
    /// fallback uses; capabilities, the Mac's own word over a pinned connection, keep the wider rule.
    func testTheRecordTakesOnlyOneOfN0sRelays() throws {
        for n0 in ["https://use1-1.relay.n0.iroh.link./", "https://usw1-1.relay.n0.iroh.link", "https://euc1-1.relay.n0.iroh.link./",
                   "https://aps1-1.relay.n0.iroh.link:443/", "https://USE1-1.Relay.N0.Iroh.Link./"] {
            XCTAssertTrue(RemoteAccessCapabilities.isN0RelayURL(n0), n0)
            XCTAssertEqual(try XCTUnwrap(RemoteAccessAddressRecord(nodeID: mac.hex, directAddresses: [], relayURL: n0, sequence: 9)).relayURL, n0)
        }
        for other in ["https://relay.example.com/", "https://x.attacker.net:3340/", "https://rebind.attacker.net/",
                      "https://use1-1.relay.n0.iroh.link:8443/", "https://relay.n0.iroh.link/", "https://a.b.relay.n0.iroh.link/",
                      "https://use1-1.relay.n0.iroh.link.attacker.net/", "https://evilrelay.n0.iroh.link/",
                      "https://use1-1.staging-relay.n0.iroh.link./", "http://use1-1.relay.n0.iroh.link/", "https://use1-1.relay.n0.iroh.link/x",
                      "https://1.2.3.4/"] {
            XCTAssertFalse(RemoteAccessCapabilities.isN0RelayURL(other), other)
            let record = try XCTUnwrap(RemoteAccessAddressRecord(nodeID: mac.hex, directAddresses: [], relayURL: other, sequence: 9))
            XCTAssertNil(record.relayURL, other)
            // The kept entry's node ID and an older sequence: the record would otherwise be dialed.
            let kept = RemoteAccessCapabilities(enabled: false, nodeID: mac, sequence: 8)
            XCTAssertEqual(kept.tunnelRoute(record: record), .none, other)
        }
        let json = #"{"version":1,"enabled":true,"nodeId":"\#(mac.hex)","directAddresses":[],"fallbackRelay":true,"relayUrl":"https://relay.example.com/","sequence":3}"#
        let listed = try JSONDecoder().decode(RemoteAccessCapabilities.self, from: Data(json.utf8))
        XCTAssertEqual(listed.relayURL, "https://relay.example.com/", "the Mac's own word keeps a public relay")
    }

    // MARK: The gate's answers

    func testCloseReasonsNameTheGatesCodes() {
        XCTAssertEqual(RemoteAccessTunnelFailure(closeReason: "closed by peer: not paired (code 403)"), .notAdmitted)
        XCTAssertEqual(RemoteAccessTunnelFailure(closeReason: "closed by peer: 403"), .notAdmitted)
        XCTAssertEqual(RemoteAccessTunnelFailure(closeReason: "closed by peer: no peer list yet (code 503)"), .unavailable)
        XCTAssertEqual(RemoteAccessTunnelFailure(closeReason: "closed by peer: 503"), .unavailable)
        for other in ["closed by peer: 0", "closed by peer: bye (code 1)", "closed by peer: (code 403", "closed by peer: x (code 4a)",
                      "timed out", "reset by peer", "closed", "aborted by peer: the cryptographic handshake failed: error 42",
                      "the connection was closed locally: 403", ""] {
            XCTAssertNil(RemoteAccessTunnelFailure(closeReason: other), other)
        }
        XCTAssertTrue(RemoteAccessTunnelFailure.notAdmitted.stopsDialing)
        for backOff in [RemoteAccessTunnelFailure.hostRefused, .unavailable, .noAnswer] { XCTAssertFalse(backOff.stopsDialing) }
    }

    // MARK: Schedules

    func testTheTunnelIsTriedAgainOnItsOwnSchedule() {
        var backoff = RemoteAccessTunnelBackoff()
        let plain = (0..<8).map { _ in backoff.failed(random: 0) }
        XCTAssertEqual(plain, [2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
        backoff.reset()
        XCTAssertEqual(backoff.failures, 0)
        let most = backoff.failed(random: 0.999_999)
        XCTAssertGreaterThan(most, .seconds(2))
        XCTAssertLessThanOrEqual(most, .milliseconds(2500), "at most a quarter more")
        backoff.reset()
        for _ in 0..<6 { _ = backoff.failed(random: 0.5) }
        XCTAssertEqual(backoff.failed(random: 1), .seconds(75))
    }

    func testTheRecordIsFetchedOncePerRaceAndAtMostEvery30Seconds() {
        var schedule = RemoteAccessRecordSchedule()
        let start = ContinuousClock.now
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertTrue(schedule.mayFetch(race: first, now: start))
        XCTAssertFalse(schedule.mayFetch(race: first, now: start + .seconds(60)), "once per race")
        XCTAssertFalse(schedule.mayFetch(race: second, now: start + .seconds(29)), "at most every 30 s")
        XCTAssertTrue(schedule.mayFetch(race: second, now: start + .seconds(30)))
        XCTAssertFalse(schedule.mayFetch(race: third, now: start + .seconds(31)))
    }

    /// The kept entry is the host's word, never replaced by a read that has none: a host started without
    /// the tunnel socket, or a capabilities read that failed. `enabled: false` from the host replaces it:
    /// the host keeps the last report across restarts, so off is the owner's word, not a passing state.
    func testTheKeptEntryIsReplacedOnlyByAnEntryTheHostLists() {
        let on = RemoteAccessCapabilities(revision: "a", enabled: true, nodeID: mac, directAddresses: ["1.2.3.4:38842"], sequence: 4)
        XCTAssertEqual(RemoteAccessCapabilities.kept(saved: on, listed: nil), on)
        let off = RemoteAccessCapabilities(revision: "b", enabled: false, nodeID: mac, sequence: 5)
        XCTAssertEqual(RemoteAccessCapabilities.kept(saved: on, listed: off), off)
        XCTAssertEqual(RemoteAccessCapabilities.kept(saved: nil, listed: nil), nil)
    }

    // MARK: The pulse

    func testThePulseNamesTheRemoteAccessRevision() async throws {
        let transport = LineTransport(status: 200, lines: [
            #"{"type":"ready","intervalMs":1500}"#, #"{"type":"remoteAccess","revision":"5d41402abc4b2a76b9719d911017c592"}"#,
            #"{"type":"remoteAccess"}"#, #"{"type":"remoteAccess","revision":""}"#,
            #"{"type":"remoteAccess","revision":"\#(String(repeating: "r", count: 65))"}"#, #"{"type":"remoteAccess","revision":7}"#,
            #"{"type":"beat"}"#
        ])
        let client = APIClient(address: try ServerAddress(validating: "https://mac.local:9841"), token: "device-token", transport: transport)
        var events: [HostPulseEvent] = []
        for try await event in try await client.pulse(idleTimeout: 4) { events.append(event) }
        XCTAssertEqual(events, [.ready(interval: 1.5), .remoteAccess(revision: "5d41402abc4b2a76b9719d911017c592"), .beat])
    }

    // MARK: The race

    /// The tunnel keeps a schedule of its own in the race: the addresses retry every few hundred
    /// milliseconds, the tunnel only when its closure says so, and a refusal (nil) takes it out of the
    /// race while the addresses go on.
    func testEachCandidateKeepsItsOwnRetrySchedule() async {
        let probes = Probes()
        let endless = Task {
            await RouteRace.first(["address", "tunnel"], stagger: .milliseconds(10), retryDelay: { index, _ in
                index == 0 ? .milliseconds(20) : nil
            }) { name in
                await probes.note(name)
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
        endless.cancel()
        _ = await endless.value
        let counts = await probes.counts
        XCTAssertEqual(counts["tunnel"], 1, "a refused tunnel is not tried again in this race")
        XCTAssertGreaterThan(counts["address", default: 0], 5, "while the addresses are")

        // With nothing left to try, the race ends.
        let none = await RouteRace.first(["address", "tunnel"], stagger: .milliseconds(10), retryDelay: { _, failures in
            failures < 2 ? .milliseconds(10) : nil
        }) { _ in false }
        XCTAssertNil(none)

        // The last candidate starts once every one before it has failed, and wins.
        let winner = await RouteRace.first(["a", "b", "tunnel"], stagger: .seconds(30), retryDelay: { _, _ in .milliseconds(10) }) { name in
            name == "tunnel"
        }
        XCTAssertEqual(winner, "tunnel")
    }

    // MARK: The transport

    /// Through the tunnel, requests keep the paired address and go through the bridge's transport; the
    /// tunnel is not an address, so the address a race tries first stays the one before it. A read lost
    /// while the app moves between the tunnel and an address goes once to the new route.
    func testTheTunnelCarriesRequestsToThePairedAddressThroughItsBridge() async throws {
        let pin = String(repeating: "ab", count: 32)
        let log = RequestLog()
        let tailscale = try XCTUnwrap(HostEndpoint(host: "100.64.0.1", port: 9841))
        let transport = try XCTUnwrap(RoutedTransport(
            address: try ServerAddress(validating: "https://mac.local:9841"), certificateSHA256: pin, endpoint: tailscale,
            transports: { endpoint, _ in RecordingTransport(name: endpoint.authority, log: log) },
            tunnelTransports: { bridge, trust in
                log.trusts.withLock { $0.append(trust) }
                return RecordingTransport(name: "bridge:\(bridge.port)", log: log)
            }))
        let api = APIClient(address: try ServerAddress(validating: "https://mac.local:9841"), token: "device-token", transport: transport)

        transport.useTunnel()
        XCTAssertEqual(transport.route, .tunnel)
        do {
            _ = try await api.projects()
            XCTFail("No bridge, nothing sent")
        } catch {
            XCTAssertEqual(error as? ClientError, .unreachable)
        }

        transport.attachTunnel(RemoteAccessBridgeAddress(port: 50001, secret: "s"))
        _ = try await api.projects()
        XCTAssertEqual(log.entries.last, "bridge:50001 https://mac.local:9841/v1/projects")
        XCTAssertEqual(transport.endpoint, tailscale, "the tunnel is never the address a race tries first")
        let answered = await transport.probeTunnel(timeout: 2)
        XCTAssertTrue(answered)
        XCTAssertEqual(log.entries.last, "bridge:50001 https://mac.local:9841/v1/health")

        // A new bridge start (the foreground again): a new transport, the same route.
        transport.attachTunnel(RemoteAccessBridgeAddress(port: 50002, secret: "t"))
        _ = try await api.projects()
        XCTAssertEqual(log.entries.last, "bridge:50002 https://mac.local:9841/v1/projects")
        XCTAssertEqual(log.trusts.withLock { $0.count }, 2)
        let trust = try XCTUnwrap(log.trusts.withLock { $0.first })
        XCTAssertEqual(trust.evaluate(authenticationMethod: NSURLAuthenticationMethodServerTrust, host: "127.0.0.1", serverTrust: nil).0,
                       .cancelAuthenticationChallenge, "TLS through the bridge is checked as at the paired address, never at loopback")

        // A read lost on the tunnel while the app moves to an address goes once more there.
        log.failNext(on: "bridge:50002") { transport.use(tailscale) }
        _ = try await api.projects()
        XCTAssertEqual(Array(log.entries.suffix(2)), ["bridge:50002 https://mac.local:9841/v1/projects", "100.64.0.1:9841 https://100.64.0.1:9841/v1/projects"])
        // A send never does.
        transport.useTunnel()
        log.failNext(on: "bridge:50002") { transport.use(tailscale) }
        let outcome = await api.sendMessage(projectID: "p", sessionID: "s", text: "hi")
        XCTAssertEqual(outcome, .uncertain)
        XCTAssertEqual(log.entries.last, "bridge:50002 https://mac.local:9841/v1/messages")

        transport.useTunnel()
        transport.detachTunnel()
        XCTAssertNil(transport.tunnelBridge)
        let lost = await transport.probeTunnel(timeout: 1)
        XCTAssertFalse(lost)
    }
}

private actor Probes {
    var counts: [String: Int] = [:]
    func note(_ name: String) { counts[name, default: 0] += 1 }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var failing: (name: String, then: @Sendable () -> Void)?
    let trusts = Mutex<[PinnedTrustEvaluator]>([])

    var entries: [String] { lock.withLock { log } }
    func failNext(on name: String, then: @escaping @Sendable () -> Void) { lock.withLock { failing = (name, then) } }

    func record(_ name: String, _ request: URLRequest) throws {
        let fail = lock.withLock { () -> (@Sendable () -> Void)? in
            log.append(name + " " + (request.url?.absoluteString ?? ""))
            guard let failing, failing.name == name else { return nil }
            self.failing = nil
            return failing.then
        }
        if let fail {
            fail()
            throw URLError(.networkConnectionLost)
        }
    }
}

private struct RecordingTransport: APITransport {
    let name: String
    let log: RequestLog

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try log.record(name, request)
        let body = switch request.url?.path {
        case "/v1/health": #"{"status":"ok","protocolVersion":1}"#
        case "/v1/projects": #"{"projects":[]}"#
        default: #"{"accepted":true}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/v1/messages" ? 202 : 200,
                                                 httpVersion: nil, headerFields: nil)!)
    }
}
