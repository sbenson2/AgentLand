#if DEBUG
import XCTest
import AgentLandCore
@testable import AgentLand

/// The simulator UI test's loopback dial (`RemoteAccessLoopbackDial`, debug builds only): it moves only
/// the addresses its list names, only to loopback, and never keeps a relay.
final class RemoteAccessLoopbackDialTests: XCTestCase {
    private let node = IrohNodeID(hex: String(repeating: "b", count: 64))!

    func testWithoutTheVariableThereIsNoLoopbackDial() {
        XCTAssertNil(RemoteAccessLoopbackDial(environment: [:]))
    }

    func testTheListMovesOnlyTheAddressesItNamesToLoopback() throws {
        let dial = try XCTUnwrap(RemoteAccessLoopbackDial(environment: [
            RemoteAccessLoopbackDial.environmentKey: "192.88.99.1:50123=127.0.0.1:50123,[2a00:1450::1]:38842=[::1]:38842"]))
        XCTAssertEqual(dial.translate(.dial(nodeID: node, directAddresses: ["192.88.99.1:50123", "8.8.8.8:1"],
                                            relayURL: "https://relay.n0.iroh.link/")),
                       .dial(nodeID: node, directAddresses: ["127.0.0.1:50123"], relayURL: nil))
        XCTAssertEqual(dial.translate(.dial(nodeID: node, directAddresses: ["[2a00:1450::1]:38842"], relayURL: nil)),
                       .dial(nodeID: node, directAddresses: ["[::1]:38842"], relayURL: nil))
        XCTAssertEqual(dial.translate(.dial(nodeID: node, directAddresses: ["8.8.8.8:1"], relayURL: "https://relay.n0.iroh.link/")), .none,
                       "an address the list does not name, and a relay, are never dialed")
        XCTAssertEqual(dial.translate(.newMacKey), .newMacKey)
    }

    func testTargetsOtherThanLoopbackEmptyTheList() throws {
        for value in ["192.88.99.1:50123=192.168.1.20:50123", "192.88.99.1:50123=localhost:50123", "10.0.0.1:1=127.0.0.1:1",
                      "192.88.99.1:50123=127.0.0.1:0", "garbage"] {
            let dial = try XCTUnwrap(RemoteAccessLoopbackDial(environment: [RemoteAccessLoopbackDial.environmentKey: value]))
            XCTAssertTrue(dial.map.isEmpty, value)
            XCTAssertEqual(dial.translate(.dial(nodeID: node, directAddresses: ["192.88.99.1:50123"], relayURL: nil)), .none, value)
        }
    }
}
#endif
