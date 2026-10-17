import XCTest
import AgentLandCore
@testable import AgentLandDesktop

/// The This Mac row says whether devices can reach this Mac away from home, from the routes its
/// host lists and what it last read of Tailscale (docs/HOST-API.md, "Routes").
final class ThisMacRoutesTests: XCTestCase {
    func testTheRowNamesTheTailscaleRouteOrSaysWhatKeepsItAway() throws {
        let local = try XCTUnwrap(HostRoute(kind: "local", host: "robins-mac-mini.local", port: 9841))
        let tailscale = try XCTUnwrap(HostRoute(kind: "tailscale", host: "robins-mac-mini.tail1a2b3c.ts.net",
                                                addresses: ["100.88.12.34"], port: 9841))
        XCTAssertEqual(ThisMacStatusRow.reach([local, tailscale], tailscale: "running"),
                       "Also reachable through Tailscale (robins-mac-mini.tail1a2b3c.ts.net)")
        XCTAssertEqual(ThisMacStatusRow.reach([local], tailscale: "off"),
                       "Only on this network — turn on Tailscale on this Mac to use AgentLand away from home")
        XCTAssertEqual(ThisMacStatusRow.reach([local], tailscale: nil),
                       "Only on this network — turn on Tailscale on this Mac to use AgentLand away from home",
                       "A host that does not say keeps the plain advice")
        XCTAssertEqual(ThisMacStatusRow.reach([local], tailscale: "notFound"),
                       "Only on this network — install Tailscale on this Mac to use AgentLand away from home")
        XCTAssertEqual(ThisMacStatusRow.reach([local], tailscale: "notListening", listener: "192.168.1.20:9841"),
                       "Only on this network — Tailscale is on, but AgentLand listens only on 192.168.1.20:9841. Listen on 0.0.0.0 (Settings → Advanced → Listen address) to use it away from home")
        XCTAssertEqual(ThisMacStatusRow.reach([local], tailscale: "unknown"),
                       "Only on this network for now — AgentLand couldn’t read Tailscale’s status on this Mac and tries again every 5 minutes")
    }
}
