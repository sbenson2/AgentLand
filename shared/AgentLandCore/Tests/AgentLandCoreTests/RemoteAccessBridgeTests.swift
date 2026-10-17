import Foundation
import XCTest
@testable import AgentLandCore

/// The bridges' rules (docs/HOST-API.md "The two apps"): how a stream and its socket end, the phone
/// bridge's waiting room, and where the tunnel dials.
final class RemoteAccessBridgeTests: XCTestCase {
    typealias Ends = RemoteAccessTunnel.StreamEnds

    private func run(_ events: [Ends.Event], _ ends: inout Ends) -> [[Ends.Action]] {
        events.map { ends.handle($0) }
    }

    /// The case that lost the host's last bytes: the host writes its last response (or a GOAWAY, a
    /// close_notify) and closes its socket; the Mac finishes the stream; the phone's bytes still in
    /// flight then fail to write. Only the receiving side is stopped: the finished sending side is
    /// never reset, so QUIC keeps retransmitting the host's last bytes.
    func testAWriteFailureAfterTheSocketsEndNeverResetsTheFinishedSide() {
        var ends = Ends()
        XCTAssertEqual(ends.handle(.socketEnded), [.finishStream])
        XCTAssertEqual(ends.handle(.socketWriteFailed), [.stopStream(.aborted), .close])
        XCTAssertEqual(ends.sending, .finished)
        XCTAssertEqual(ends.receiving, .aborted)
        XCTAssertTrue(ends.closed)
        // And in the other order: the failed write comes first, the socket's buffered bytes and its
        // end after; the sending side still finishes.
        var other = Ends()
        XCTAssertEqual(run([.socketWriteFailed, .socketEnded], &other), [[.stopStream(.aborted)], [.finishStream, .close]])
    }

    /// No action anywhere resets a sending side that has finished.
    func testNoEventResetsAFinishedSendingSide() {
        let later: [Ends.Event] = [.socketReadFailed, .socketWriteFailed, .hostRefused, .streamEnded, .streamReset(code: 1),
                                   .streamReset(code: 2), .streamStopped(code: 1), .socketEnded]
        for first in later {
            for second in later {
                var ends = Ends()
                _ = ends.handle(.socketEnded)
                let actions = run([first, second], &ends).flatMap { $0 }
                XCTAssertFalse(actions.contains { if case .resetStream = $0 { true } else { false } }, "\(first), \(second): \(actions)")
                XCTAssertEqual(ends.sending, .finished)
            }
        }
    }

    func testNormalEndsBothWays() {
        var ends = Ends()
        XCTAssertEqual(ends.handle(.streamEnded), [.shutdownSocketOutput])
        XCTAssertFalse(ends.closed)
        XCTAssertEqual(ends.handle(.socketEnded), [.finishStream, .close])
        var other = Ends()
        XCTAssertEqual(run([.socketEnded, .streamEnded], &other), [[.finishStream], [.shutdownSocketOutput, .close]])
        XCTAssertEqual(other.receiving, .finished)
        XCTAssertEqual(ends.handle(.streamReset(code: 1)), [], "nothing after close")
    }

    /// The peer stopped the sending side (its write to its socket failed): the bridge reads and drops
    /// the socket's input until its end, so it never closes a socket with unread input, and the
    /// other direction still delivers everything and ends normally.
    func testAStopFromThePeerDrainsTheSocketAndKeepsTheOtherDirection() {
        var ends = Ends()
        XCTAssertEqual(ends.handle(.streamStopped(code: 1)), [.dropSocketInput])
        XCTAssertEqual(ends.sending, .dropping)
        XCTAssertEqual(ends.handle(.streamEnded), [.shutdownSocketOutput])
        XCTAssertFalse(ends.closed, "closed with the socket's input unread")
        XCTAssertEqual(ends.handle(.socketEnded), [.close])
        // A stop after the sending side finished changes nothing.
        var finished = Ends()
        XCTAssertEqual(run([.socketEnded, .streamStopped(code: 1), .streamEnded], &finished), [[.finishStream], [], [.shutdownSocketOutput, .close]])
    }

    /// A failed read means the socket is gone: both directions end.
    func testAFailedReadEndsBothDirections() {
        var ends = Ends()
        XCTAssertEqual(ends.handle(.socketReadFailed), [.resetStream(.aborted), .stopStream(.aborted), .close])
        var receivedAll = Ends()
        XCTAssertEqual(run([.streamEnded, .socketReadFailed], &receivedAll), [[.shutdownSocketOutput], [.resetStream(.aborted), .close]])
    }

    /// A reset from the peer aborts the socket, so the socket's other side sees an abort, not an end.
    func testAResetFromThePeerAbortsTheSocket() {
        var ends = Ends()
        XCTAssertEqual(ends.handle(.streamReset(code: 1)), [.resetStream(.aborted), .abortSocket, .close])
        XCTAssertFalse(ends.refusedByHost)
        var finished = Ends()
        XCTAssertEqual(run([.socketEnded, .streamReset(code: 1)], &finished), [[.finishStream], [.abortSocket, .close]])
    }

    /// The host refused (code 2): the Mac resets and stops the stream in place of finishing it; the
    /// phone tells its route logic unless `APIClient` had already ended that connection.
    func testTheHostsRefusal() {
        var mac = Ends()
        XCTAssertEqual(mac.handle(.hostRefused), [.resetStream(.refused), .stopStream(.refused), .close])
        // The Mac sends both; the phone meets them in either order (over iroh the stop usually comes
        // first, as the failed write of APIClient's ClientHello). Either way APIClient had not ended.
        var phone = Ends()
        XCTAssertEqual(run([.streamStopped(code: 2), .streamReset(code: 2)], &phone), [[.dropSocketInput], [.abortSocket, .close]])
        XCTAssertTrue(phone.refusedByHost, "the stop came first; APIClient had not ended its connection")
        var unknownStop = Ends()
        _ = run([.streamStopped(code: 0), .streamReset(code: 2)], &unknownStop)
        XCTAssertTrue(unknownStop.refusedByHost, "a write that failed on the stop, before its code was read")
        var resetFirst = Ends()
        XCTAssertEqual(resetFirst.handle(.streamReset(code: 2)), [.resetStream(.aborted), .abortSocket, .close])
        XCTAssertTrue(resetFirst.refusedByHost)
        var apiClientGone = Ends()
        _ = apiClientGone.handle(.socketEnded)
        _ = apiClientGone.handle(.streamReset(code: 2))
        XCTAssertFalse(apiClientGone.refusedByHost)
    }

    /// A full room makes way for a new connection by closing the one that has waited longest, so
    /// connections that send nothing never keep `APIClient`'s out; one that showed the credential
    /// has left the room and is never closed for room.
    func testTheWaitingRoomClosesTheLongestWaiting() {
        var room = RemoteAccessTunnel.Bridge.WaitingRoom<Int>(capacity: 3)
        XCTAssertEqual(RemoteAccessTunnel.Bridge.WaitingRoom<Int>().capacity, 16)
        XCTAssertNil(room.arrive(1))
        XCTAssertNil(room.arrive(2))
        XCTAssertNil(room.arrive(3))
        // APIClient's connection arrives while another app holds every place.
        XCTAssertEqual(room.arrive(100), 1)
        XCTAssertEqual(room.waiting, [2, 3, 100])
        // The other app reopens the one it lost: it takes the place of its own oldest, not APIClient's.
        XCTAssertEqual(room.arrive(4), 2)
        // APIClient's connection shows the credential and leaves.
        room.leave(100)
        XCTAssertNil(room.arrive(5))
        XCTAssertEqual(room.arrive(6), 3)
        XCTAssertEqual(room.waiting, [4, 5, 6])
        XCTAssertNil(room.arrive(5), "a connection is in the room once")
        XCTAssertEqual(room.waiting, [4, 5, 6])
    }

    func testTheBridgesLimits() {
        XCTAssertEqual(RemoteAccessTunnel.Bridge.maximumStreams, 8)
        XCTAssertEqual(RemoteAccessTunnel.Bridge.maximumStreamsPerMinute, 30)
        XCTAssertEqual(RemoteAccessTunnel.Bridge.maximumWaiting, 16)
        XCTAssertEqual(RemoteAccessTunnel.Bridge.maximumHeadBytes, 4096)
        XCTAssertEqual(RemoteAccessTunnel.Bridge.headTimeout, .milliseconds(250))
    }

    // MARK: - Where the tunnel dials

    private let mac = IrohNodeID(hex: String(repeating: "b", count: 64))!
    private let newKey = IrohNodeID(hex: String(repeating: "c", count: 64))!

    private func record(_ node: IrohNodeID? = nil, addresses: [String] = ["1.2.3.4:38842"], relay: String? = nil,
                        sequence: Int64 = 8) throws -> RemoteAccessAddressRecord {
        try XCTUnwrap(RemoteAccessAddressRecord(nodeID: (node ?? mac).hex, directAddresses: addresses, relayURL: relay, sequence: sequence))
    }

    /// Two phones the kept entry alone left stranded away from home: the owner turned the switch on
    /// while the phone was suspended (its entry still says off), and the Mac's mapping had failed when
    /// the phone last connected (on, no address). Both know the Mac's node ID, so both fetch the record
    /// once every address has failed, and both dial it, since it follows a later report.
    func testTheRecordRescuesAKeptEntryThatDoesNotOfferTheTunnel() throws {
        let switchedOnWhileAway = RemoteAccessCapabilities(enabled: false, nodeID: mac, sequence: 7)
        let mappingFailedThen = RemoteAccessCapabilities(enabled: true, nodeID: mac, sequence: 7)
        for kept in [switchedOnWhileAway, mappingFailedThen] {
            XCTAssertFalse(kept.offersTunnel)
            XCTAssertTrue(kept.fetchesAddressRecord)
            XCTAssertEqual(kept.tunnelRoute(record: nil), .none)
            XCTAssertEqual(kept.tunnelRoute(record: try record()), .dial(nodeID: mac, directAddresses: ["1.2.3.4:38842"], relayURL: nil))
        }
        // A device that never learned the Mac's node ID has nothing to check a record against.
        let noNode = RemoteAccessCapabilities(enabled: true, directAddresses: ["1.2.3.4:38842"])
        XCTAssertFalse(noNode.fetchesAddressRecord)
        XCTAssertEqual(noNode.tunnelRoute(record: try record()), .none)
    }

    func testTheRecordReplacesTheKeptAddressesOnlyForThePinnedNodeID() throws {
        let kept = RemoteAccessCapabilities(enabled: true, nodeID: mac, directAddresses: ["5.6.7.8:38842"], sequence: 7)
        XCTAssertEqual(kept.tunnelRoute(record: nil), .dial(nodeID: mac, directAddresses: ["5.6.7.8:38842"], relayURL: nil))
        XCTAssertEqual(kept.tunnelRoute(record: try record(addresses: ["1.2.3.4:40000"], relay: "https://usw1-1.relay.n0.iroh.link./")),
                       .dial(nodeID: mac, directAddresses: ["1.2.3.4:40000"], relayURL: "https://usw1-1.relay.n0.iroh.link./"))
        XCTAssertEqual(kept.tunnelRoute(record: try record(newKey)), .newMacKey, "a later report named another key")
        XCTAssertEqual(kept.tunnelRoute(record: try record(addresses: [])), .none, "the record says there is no way in")
    }

    /// The record counts only when it follows a later report than the kept entry. A record the Mac has
    /// not rewritten yet (iCloud unavailable after Migration Assistant, CloudKit off, a write still
    /// retrying) names the Mac's old node ID: the phone learned the new one at home and still dials its
    /// kept route instead of asking for another connection at home. A record the Mac has not deleted
    /// yet (the Mac was offline or quit when the owner turned the switch off, the delete still
    /// retrying) never takes the phone to the old address or the relay the owner turned off, once the
    /// phone has learned that the switch is off.
    func testAnOlderRecordNeverOverridesWhatThePhoneLearnedLater() throws {
        let newKeyAtHome = RemoteAccessCapabilities(enabled: true, nodeID: newKey, directAddresses: ["5.6.7.8:38842"], sequence: 9)
        let stale = try record(mac, addresses: ["1.2.3.4:38842"], relay: "https://usw1-1.relay.n0.iroh.link./", sequence: 8)
        XCTAssertEqual(newKeyAtHome.tunnelRoute(record: stale), .dial(nodeID: newKey, directAddresses: ["5.6.7.8:38842"], relayURL: nil))

        let switchedOff = RemoteAccessCapabilities(enabled: false, nodeID: mac, sequence: 9)
        XCTAssertTrue(switchedOff.fetchesAddressRecord)
        XCTAssertEqual(switchedOff.tunnelRoute(record: stale), .none)
        XCTAssertEqual(switchedOff.tunnelRoute(record: stale).endpointRelayURLs, [], "no endpoint, no relay")

        // The record of the very report the phone keeps changes nothing either.
        let same = RemoteAccessCapabilities(enabled: true, nodeID: mac, directAddresses: ["5.6.7.8:38842"], sequence: 8)
        XCTAssertEqual(same.tunnelRoute(record: stale), .dial(nodeID: mac, directAddresses: ["5.6.7.8:38842"], relayURL: nil))
        // An entry from a host that sends no sequence (0) takes any record.
        let unordered = RemoteAccessCapabilities(enabled: false, nodeID: mac)
        XCTAssertEqual(unordered.tunnelRoute(record: stale),
                       .dial(nodeID: mac, directAddresses: ["1.2.3.4:38842"], relayURL: "https://usw1-1.relay.n0.iroh.link./"))
    }

    /// The phone's endpoint takes its relay from the route, not from the kept entry's fallbackRelay: a
    /// Mac behind carrier-grade NAT is reachable only through the n0 fallback, and the owner turned
    /// the switch and the fallback on while the phone was away. The record carries the relay alone.
    /// iroh dials through a relay only from an endpoint that runs with it (AgentLandIroh's
    /// `testARelayOnlyAddressNeedsTheRelayInTheDialersRelayMode`), so the endpoint runs with that relay,
    /// and one already running without it (or with the relay the Mac used before) starts again.
    func testARelayOnlyRecordRunsThePhonesEndpointWithItsRelay() throws {
        let relay = "https://usw1-1.relay.n0.iroh.link./"
        let relayOnly = try record(addresses: [], relay: relay)
        let switchedOnWhileAway = RemoteAccessCapabilities(enabled: false, nodeID: mac, sequence: 7)
        let onWithoutTheFallback = RemoteAccessCapabilities(enabled: true, nodeID: mac, directAddresses: ["5.6.7.8:38842"], sequence: 7)
        for kept in [switchedOnWhileAway, onWithoutTheFallback] {
            XCTAssertFalse(kept.fallbackRelay)
            let route = kept.tunnelRoute(record: relayOnly)
            XCTAssertEqual(route, .dial(nodeID: mac, directAddresses: [], relayURL: relay))
            XCTAssertEqual(route.endpointRelayURLs, [relay])
            XCTAssertTrue(route.needsEndpointRestart(runningWith: []), "an endpoint without relays cannot dial a relay-only route")
            XCTAssertFalse(route.needsEndpointRestart(runningWith: [relay]))
        }
        // The Mac picked another relay: the kept entry has A, the record B.
        let keptA = RemoteAccessCapabilities(enabled: true, nodeID: mac, fallbackRelay: true, relayURL: "https://euw1-1.relay.n0.iroh.link./", sequence: 7)
        let routeB = keptA.tunnelRoute(record: relayOnly)
        XCTAssertEqual(routeB.endpointRelayURLs, [relay])
        XCTAssertTrue(routeB.needsEndpointRestart(runningWith: ["https://euw1-1.relay.n0.iroh.link./"]))
        XCTAssertEqual(keptA.tunnelRoute(record: nil).endpointRelayURLs, ["https://euw1-1.relay.n0.iroh.link./"])
        // A route without a relay runs the endpoint with none, so it talks to no relay the route does not use.
        let direct = keptA.tunnelRoute(record: try record(addresses: ["1.2.3.4:38842"]))
        XCTAssertEqual(direct.endpointRelayURLs, [])
        XCTAssertTrue(direct.needsEndpointRestart(runningWith: ["https://euw1-1.relay.n0.iroh.link./"]))
        XCTAssertFalse(direct.needsEndpointRestart(runningWith: []))
        // Nothing to dial, nothing to restart.
        for nothing in [RemoteAccessTunnelRoute.none, .newMacKey] {
            XCTAssertEqual(nothing.endpointRelayURLs, [])
            XCTAssertFalse(nothing.needsEndpointRestart(runningWith: [relay]))
        }
    }

    /// Whoever can write the owner's private database is not trusted for anything but addresses.
    func testTheRecordKeepsOnlyWhatADeviceMayDial() throws {
        let many = (1...10).map { "1.2.3.\($0):38842" }
        let taken = try record(addresses: ["192.168.0.5:38842", "100.72.3.9:38842", "[fe80::1]:38842", "mac.example:38842"] + many,
                               relay: "https://relay.example/path")
        XCTAssertEqual(taken.directAddresses, Array(many.prefix(8)))
        XCTAssertNil(taken.relayURL)
        XCTAssertNil(RemoteAccessAddressRecord(nodeID: mac.hex.uppercased(), directAddresses: many, relayURL: nil, sequence: 1))
        XCTAssertNil(RemoteAccessAddressRecord(nodeID: "", directAddresses: many, relayURL: nil, sequence: 1))
        // A record whose order a device cannot tell is no record.
        for sequence: Int64? in [nil, 0, -1] {
            XCTAssertNil(RemoteAccessAddressRecord(nodeID: mac.hex, directAddresses: many, relayURL: nil, sequence: sequence))
        }
    }

    /// The host's `validRelayURL`.
    func testRelayURLsOfTheHostsForm() {
        for good in ["https://relay.example", "https://relay.example/", "https://euw1-1.relay.example./", "https://relay.example:8443/",
                     "https://[2001:db8::1]/"] {
            XCTAssertTrue(RemoteAccessCapabilities.isRelayURL(good), good)
        }
        for bad in ["", "http://relay.example/", "https://", "https:///", "https://user@relay.example/", "https://relay.example/x",
                    "https://relay.example/?q", "https://relay.example/#f", "https://relay.example\\", "https://relay .example/",
                    "https://relay.example/\u{7f}", "https://ré.example/", "relay.example", "https://" + String(repeating: "a", count: 250) + ".example"] {
            XCTAssertFalse(RemoteAccessCapabilities.isRelayURL(bad), bad)
        }
    }
}
