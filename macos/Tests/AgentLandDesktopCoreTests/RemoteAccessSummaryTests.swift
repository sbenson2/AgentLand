import Foundation
import XCTest
@testable import AgentLandDesktopCore

/// What the switch's row says (docs/HOST-API.md "The Mac switches"): off, mapping, reachable at an
/// address, relay fallback, and why the mapping failed.
final class RemoteAccessSummaryTests: XCTestCase {
    private func status(_ configure: (inout RemoteAccessService.Status) -> Void) -> RemoteAccessService.Status {
        var status = RemoteAccessService.Status()
        status.enabled = true
        status.endpoint = .running
        status.mapping.settled = true
        configure(&status)
        return status
    }

    func testOffMappingAndReachable() {
        XCTAssertEqual(RemoteAccessService.Status().summary().title, "Off")
        let mapping = status { $0.mapping.state = .attempting; $0.mapping.settled = false }.summary()
        XCTAssertEqual(mapping.title, "Opening port 38842 on the router…")
        XCTAssertEqual(mapping.tone, .working)
        let reachable = status {
            $0.mapping.state = .mapped
            $0.mapping.directAddresses = ["81.2.69.160:38842"]
        }.summary()
        XCTAssertEqual(reachable.title, "Reachable at 81.2.69.160:38842")
        XCTAssertEqual(reachable.tone, .reachable)
    }

    func testNoDirectAddressSaysWhyAndOffersTheRelay() {
        let cgnat = status {
            $0.mapping.state = .mapped
            $0.mapping.externalAddress = "100.64.3.9:38842"
        }.summary()
        XCTAssertEqual(cgnat.tone, .attention)
        XCTAssertTrue(cgnat.detail?.contains("(100.64.3.9) is not a public one") == true, cgnat.detail ?? "")
        XCTAssertTrue(cgnat.detail?.contains("Your network does not let other networks reach this Mac directly.") == true)
        XCTAssertTrue(cgnat.detail?.contains("Turn on “Use a public relay if a direct connection fails” to reach it anyway.") == true)

        let silent = status { $0.mapping.state = .notMapped(.failed(.noResponse)) }.summary()
        XCTAssertEqual(silent.title, "The port mapping failed")
        XCTAssertTrue(silent.detail?.contains("The router did not answer a port mapping request") == true, silent.detail ?? "")

        let viaRelay = status {
            $0.fallback = true
            $0.relay = .using("https://use1-1.relay.n0.example./")
            $0.mapping.state = .notMapped(.failed(.refused(method: .pcp, code: 2)))
        }.summary()
        XCTAssertEqual(viaRelay.title, "Reachable through a public relay (use1-1.relay.n0.example)")
        XCTAssertEqual(viaRelay.tone, .reachable)
    }

    func testKeptAddressesAndPortInUse() {
        let lease = Date(timeIntervalSince1970: 1_790_003_600)
        let kept = status {
            $0.mapping.state = .notMapped(.failed(.noResponse))
            $0.mapping.directAddresses = ["81.2.69.160:38842"]
            $0.mapping.keptUntil = lease
        }.summary()
        XCTAssertEqual(kept.title, "Reachable at 81.2.69.160:38842")
        XCTAssertTrue(kept.detail?.hasPrefix("The router did not open the port this time. AgentLand keeps trying, and devices keep the last address until the mapping's lease ends") == true)
        XCTAssertTrue(kept.detail?.contains("(at most 2 hours)") == true)

        let inUse = status { $0.endpoint = .portInUse }.summary()
        XCTAssertEqual(inUse.title, "UDP port 38842 is in use")
        XCTAssertEqual(inUse.tone, .attention)
    }

    /// The kept relay unreachable: the time left is an upper bound rounded up, so the last minute says 1
    /// min, never 0, and it follows the time it is asked at (the views ask again every few seconds).
    func testTheRelayCountdownRoundsUpAndFollowsTheTime() {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let unreachable = status {
            $0.fallback = true
            $0.relay = .unreachable("https://use1-1.relay.n0.iroh.link./", since: since)
            $0.mapping.state = .mapped
            $0.mapping.directAddresses = ["81.2.69.160:38842"]
        }
        func sentence(after seconds: TimeInterval) -> String? { unreachable.summary(now: since.addingTimeInterval(seconds)).detail }
        XCTAssertEqual(sentence(after: 0),
                       "The public relay use1-1.relay.n0.iroh.link is not reachable; AgentLand picks another within 10 min if it stays that way.")
        XCTAssertTrue(sentence(after: 61)?.contains("within 9 min") == true, sentence(after: 61) ?? "")
        XCTAssertTrue(sentence(after: 545)?.contains("within 1 min") == true, sentence(after: 545) ?? "")
        XCTAssertTrue(sentence(after: 599)?.contains("within 1 min") == true, "the last minute never says 0")
        XCTAssertTrue(sentence(after: 900)?.contains("within 1 min") == true, "the pick is due")
    }

    /// The switch on while the host's connection mode is development HTTP: nothing runs, and the row
    /// says why and what to change.
    func testDevelopmentHTTPSaysTheSwitchWaitsForTrustedHTTPS() {
        let waiting = status { $0.tunnelServed = false; $0.endpoint = .off }.summary()
        XCTAssertEqual(waiting.title, "Off while the connection is Local development HTTP")
        XCTAssertEqual(waiting.tone, .attention)
        XCTAssertTrue(waiting.detail?.contains("“Trusted HTTPS” (Settings → Advanced → Connection)") == true, waiting.detail ?? "")
        var off = RemoteAccessService.Status()
        off.tunnelServed = false
        XCTAssertEqual(off.summary().title, "Off", "the switch off says off")
    }
}
