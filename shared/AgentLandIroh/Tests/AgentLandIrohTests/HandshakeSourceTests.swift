@testable import AgentLandIroh
import XCTest

/// The sources IrohPeerGate limits handshakes by.
final class HandshakeSourceTests: XCTestCase {
    func testIPv4AddressesAreSourcesWhateverThePort() throws {
        let source = try XCTUnwrap(HandshakeSource.ip("203.0.113.7:4242"))
        XCTAssertEqual(source, .ipv4(0xCB00_7107))
        XCTAssertEqual(HandshakeSource.ip("203.0.113.7:9"), source)
        XCTAssertNotEqual(HandshakeSource.ip("203.0.113.8:4242"), source)
        // An IPv4-mapped IPv6 address is its IPv4 address.
        XCTAssertEqual(HandshakeSource.ip("[::ffff:203.0.113.7]:1"), source)
        XCTAssertEqual(HandshakeSlots.Pool(source, allowed: []), .direct)
    }

    func testGlobalIPv6AddressesCountByTheirSlash64() throws {
        let source = try XCTUnwrap(HandshakeSource.ip("[2001:db8:1:2::5]:4242"))
        XCTAssertEqual(HandshakeSource.ip("[2001:db8:1:2:ffff:1:2:3]:1"), source)
        XCTAssertNotEqual(HandshakeSource.ip("[2001:db8:1:3::5]:4242"), source)
        XCTAssertEqual(HandshakeSource.ip("[2a01:4f8:c0c:1234::1]:1"), HandshakeSource.ip("[2a01:4f8:c0c:1234:a:b:c:d]:2"))
        XCTAssertEqual(HandshakeSource.ip("[3fff:1::7]:1"), HandshakeSource.ip("[3fff:1::8]:1"))
        XCTAssertNotEqual(HandshakeSource.ip("[::1]:4242"), HandshakeSource.ip("127.0.0.1:4242"))
    }

    /// Addresses whose /64 many hosts share count one by one.
    func testOtherIPv6AddressesCountOnTheirOwn() throws {
        // Tailscale gives every node of a tailnet an address in one /64
        // (fd7a:115c:a1e0:ab12:4843:cd96:6200::/104 on older tailnets,
        // fd7a:115c:a1e0::/96 on newer ones).
        let tailnet = [
            "[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]:41641",
            "[fd7a:115c:a1e0:ab12:4843:cd96:6201:17]:41641",
            "[fd7a:115c:a1e0:ab12:4843:cd96:627f:ffff]:7",
            "[fd7a:115c:a1e0::1a2b:3c4d]:9",
            "[fd7a:115c:a1e0::5e6f:7081]:9",
        ].compactMap(HandshakeSource.ip)
        XCTAssertEqual(tailnet.count, 5)
        XCTAssertEqual(Set(tailnet).count, 5, "tailnet nodes share a source")
        // One node is one source whatever the port.
        XCTAssertEqual(HandshakeSource.ip("[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]:1"), tailnet[0])
        XCTAssertTrue(tailnet.allSatisfy { HandshakeSlots.Pool($0, allowed: nil) == .direct })
        // ZeroTier in RFC 4193 mode: fd, the 64-bit network ID, 99:93, the 40-bit node ID.
        XCTAssertNotEqual(
            HandshakeSource.ip("[fd80:56c2:e21c:0:199:9312:3456:789a]:9993"),
            HandshakeSource.ip("[fd80:56c2:e21c:0:199:93ab:cdef:123]:9993")
        )
        // Link-local addresses share fe80::/64; the zone does not matter.
        XCTAssertNotEqual(HandshakeSource.ip("[fe80::1%4]:5"), HandshakeSource.ip("[fe80::2%4]:5"))
        XCTAssertEqual(HandshakeSource.ip("[fe80::1%4]:5"), HandshakeSource.ip("[fe80::1%7]:6"))
        // NAT64: each IPv4 host behind 64:ff9b::/96 is its own source.
        XCTAssertNotEqual(HandshakeSource.ip("[64:ff9b::203.0.113.7]:1"), HandshakeSource.ip("[64:ff9b::203.0.113.8]:1"))
        XCTAssertEqual(HandshakeSource.ip("[64:ff9b::203.0.113.7]:1"), HandshakeSource.ip("[64:ff9b::cb00:7107]:2"))
    }

    /// A Teredo address carries its client's public IPv4 address, inverted, in
    /// its last 32 bits; clients of one Teredo server share a /64.
    func testTeredoAddressesCountAsTheirClientsIPv4Address() throws {
        // RFC 4380's example: server 65.54.227.120, client 192.0.2.45 at port 40000.
        let teredo = try XCTUnwrap(HandshakeSource.ip("[2001:0:4136:e378:8000:63bf:3fff:fdd2]:1"))
        XCTAssertEqual(teredo, .ipv4(0xC000_022D))
        XCTAssertEqual(teredo, HandshakeSource.ip("192.0.2.45:40000"))
        XCTAssertNotEqual(HandshakeSource.ip("[2001:0:4136:e378:8000:63bf:3fff:fdd1]:1"), teredo)
    }

    func testOtherAddresses() async throws {
        XCTAssertNil(HandshakeSource.ip("not an address"))
        XCTAssertEqual(HandshakeSource(.ip(addr: "nonsense")), .other("nonsense"))
        XCTAssertEqual(HandshakeSource(.custom(description: "transport")), .other("transport"))
        let endpoint = try await Endpoint.bind(options: .test())
        let relayed = HandshakeSource(.relay(url: "http://127.0.0.1:1/", endpointId: endpoint.id()))
        XCTAssertEqual(relayed, .relayed(endpoint.id().toBytes()))
        // A relayed sender takes the unlisted relayed slots unless the list names it.
        XCTAssertEqual(HandshakeSlots.Pool(relayed, allowed: [endpoint.id().toBytes()]), .listedRelayed)
        XCTAssertEqual(HandshakeSlots.Pool(relayed, allowed: []), .unlistedRelayed)
        XCTAssertEqual(HandshakeSlots.Pool(relayed, allowed: nil), .unlistedRelayed, "no list yet")
        try await endpoint.close()
    }
}

/// The slots IrohPeerGate counts handshakes in progress by.
final class HandshakeSlotsTests: XCTestCase {
    private func sender(_ byte: UInt8) -> HandshakeSource { .relayed(Data(repeating: byte, count: 32)) }

    /// Relayed senders that are not listed get handshakes (so the gate can
    /// refuse them with its code) only from slots of their own: filling them
    /// holds up neither direct handshakes nor listed relayed senders, and they
    /// never take the direct slots.
    func testUnlistedRelayedSendersHaveSlotsOfTheirOwn() {
        var slots = HandshakeSlots(maxDirect: 1, maxPerSource: 2, maxUnlistedRelayed: 2)
        XCTAssertTrue(slots.take(sender(1), pool: .unlistedRelayed))
        XCTAssertTrue(slots.take(sender(2), pool: .unlistedRelayed))
        XCTAssertFalse(slots.take(sender(3), pool: .unlistedRelayed), "a new key does not get past the pool")
        XCTAssertEqual(slots.pendingUnlistedRelayed, 2)

        XCTAssertTrue(slots.take(.ipv4(0x0A00_0001), pool: .direct))
        XCTAssertFalse(slots.take(.ipv4(0x0A00_0002), pool: .direct), "the direct slots are full")
        XCTAssertTrue(slots.take(sender(9), pool: .listedRelayed))
        XCTAssertTrue(slots.take(sender(9), pool: .listedRelayed))
        XCTAssertFalse(slots.take(sender(9), pool: .listedRelayed), "a listed sender keeps its per-source limit")
        XCTAssertEqual(slots.pending, 5)
        XCTAssertEqual(slots.pendingDirect, 1)

        slots.release(sender(1), pool: .unlistedRelayed)
        XCTAssertTrue(slots.take(sender(3), pool: .unlistedRelayed))
        slots.release(.ipv4(0x0A00_0001), pool: .direct)
        XCTAssertTrue(slots.take(.ipv4(0x0A00_0002), pool: .direct))
        for source in [sender(2), sender(3)] { slots.release(source, pool: .unlistedRelayed) }
        slots.release(.ipv4(0x0A00_0002), pool: .direct)
        for _ in 0..<2 { slots.release(sender(9), pool: .listedRelayed) }
        XCTAssertEqual(slots, HandshakeSlots(maxDirect: 1, maxPerSource: 2, maxUnlistedRelayed: 2))
    }

    /// One relayed sender that is not listed holds at most its source's slots.
    func testOneUnlistedSenderHoldsAtMostItsSourceSlots() {
        var slots = HandshakeSlots(maxDirect: 64, maxPerSource: 2, maxUnlistedRelayed: 8)
        XCTAssertTrue(slots.take(sender(1), pool: .unlistedRelayed))
        XCTAssertTrue(slots.take(sender(1), pool: .unlistedRelayed))
        XCTAssertFalse(slots.take(sender(1), pool: .unlistedRelayed))
        XCTAssertEqual(slots.pendingUnlistedRelayed, 2)
        XCTAssertTrue(slots.take(sender(2), pool: .unlistedRelayed))
    }
}
