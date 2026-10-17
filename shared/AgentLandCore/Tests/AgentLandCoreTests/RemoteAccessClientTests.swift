import CryptoKit
import Foundation
import XCTest
@testable import AgentLandCore

/// Remote access (docs/HOST-API.md, "Remote access (iroh)"): node IDs, proofs, the tunnel preamble,
/// `capabilities.remoteAccess` and the routes, through the production URLSession path.
final class RemoteAccessClientTests: XCTestCase {
    /// The Ed25519 key of seed 00 01 … 1f, and its proofs as the Go host's tests check them
    /// (`TestNodeProofCrossLanguageVector`).
    private static let vectorNode = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
    private static let vectorPairProof = "f44713a67909e6ff5cfcaa1eb6af9d58a72b48d583e08c4bda9998e8820c7d8b91f88bb40aeeaf0f14354952217463de56c79edf2b8864d506827a1c1abca40b"
    private static let vectorRegisterProof = "3d2c1c5c1712258597954c7749de7ef20dcefc0f0b8f89ced84816af6a763ed87272ee7b0fe5aba8c0218f9d9cb4bd6c4fd17d0706f8579dbb473d7a8c350404"

    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    private func node(_ hex: String = RemoteAccessClientTests.vectorNode) throws -> IrohNodeID { try XCTUnwrap(IrohNodeID(hex: hex)) }

    private func json(_ body: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
    }

    func testNodeIDsAreLowerCaseHexOfTheKey() throws {
        let id = try node()
        XCTAssertEqual(id.publicKey.count, 32)
        XCTAssertEqual(IrohNodeID(publicKey: id.publicKey), id)
        XCTAssertEqual(id.description, Self.vectorNode)
        for bad in ["", String(Self.vectorNode.dropLast()), Self.vectorNode + "0", Self.vectorNode.uppercased(), String(repeating: "g", count: 64),
                    "k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8"] {
            XCTAssertNil(IrohNodeID(hex: bad), bad)
        }
        XCTAssertNil(IrohNodeID(publicKey: Data(repeating: 1, count: 31)))
        XCTAssertEqual(try JSONDecoder().decode(IrohNodeID.self, from: Data("\"\(Self.vectorNode)\"".utf8)), id)
        XCTAssertThrowsError(try JSONDecoder().decode(IrohNodeID.self, from: Data("\"\(Self.vectorNode.uppercased())\"".utf8)))
    }

    /// Keys no private key backs, as the Go host's `weakNodeKeys` lists them: the eight points of
    /// small order (each y with both signs of x) and their non-canonical encodings. The host refuses
    /// them (`TestNodeProofRefusesKeysNoDeviceHolds`); so does every node ID here.
    func testNodeIDsRefuseKeysNoDeviceHolds() throws {
        let ys = ["0100000000000000000000000000000000000000000000000000000000000000",
                  "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
                  "0000000000000000000000000000000000000000000000000000000000000000",
                  "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
                  "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
                  "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
                  "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"]
        for y in ys {
            for weak in [y, String(y.dropLast(2)) + String(format: "%02x", UInt8(y.suffix(2), radix: 16)! | 0x80)] {
                XCTAssertNil(IrohNodeID(hex: weak), weak)
                XCTAssertNil(IrohNodeID(publicKey: try XCTUnwrap(hexData(weak))), weak)
                XCTAssertThrowsError(try JSONDecoder().decode(IrohNodeID.self, from: Data("\"\(weak)\"".utf8)), weak)
            }
        }
        // Every encoding at or above p is refused.
        for low in 0xed...0xff {
            for top in [0x7f, 0xff] as [UInt8] {
                XCTAssertNil(IrohNodeID(publicKey: Data([UInt8(low)] + [UInt8](repeating: 0xff, count: 30) + [top])))
            }
        }
        XCTAssertNotNil(IrohNodeID(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
    }

    /// The message bytes are the host's: a proof the Go host verifies for this message verifies here
    /// with CryptoKit's Ed25519, and so would one signed by iroh's `SecretKey.sign(message:)`.
    func testProofMessagesMatchTheHostsBytes() throws {
        let id = try node()
        let message = IrohNodeProof.message(purpose: .register, binding: "9c1e44d0a7b2c35f8e016d42", nodeID: id)
        XCTAssertEqual(String(decoding: message, as: UTF8.self), "agentland-iroh-node/1\nregister\n9c1e44d0a7b2c35f8e016d42\n" + Self.vectorNode)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: id.publicKey)
        let pair = IrohNodeProof.message(purpose: .pair, binding: "0012345678", nodeID: id)
        XCTAssertTrue(key.isValidSignature(try XCTUnwrap(hexData(Self.vectorPairProof)), for: pair))
        XCTAssertTrue(key.isValidSignature(try XCTUnwrap(hexData(Self.vectorRegisterProof)), for: message))
        XCTAssertFalse(key.isValidSignature(try XCTUnwrap(hexData(Self.vectorPairProof)), for: message), "A proof is bound to its purpose")

        // A signature becomes the claim's proof as 128 lowercase hex characters.
        let signer = Curve25519.Signing.PrivateKey()
        let own = try XCTUnwrap(IrohNodeID(publicKey: signer.publicKey.rawRepresentation))
        let claim = try XCTUnwrap(IrohNodeClaim(nodeID: own, signature: signer.signature(for: IrohNodeProof.message(purpose: .pair, binding: "0012345678", nodeID: own))))
        XCTAssertEqual(claim.proof.count, 128)
        XCTAssertEqual(claim.proof, claim.proof.lowercased())
        XCTAssertNil(IrohNodeClaim(nodeID: own, signature: Data(repeating: 0, count: 63)))
        XCTAssertNil(IrohNodeClaim(nodeID: own, proof: Self.vectorPairProof.uppercased()))
        XCTAssertNotNil(IrohNodeClaim(nodeID: own, proof: Self.vectorPairProof))
    }

    func testTunnelPreambleIsTheExactLine() throws {
        let preamble = RemoteAccessTunnel.preamble(nodeID: try node())
        XCTAssertEqual(preamble.count, RemoteAccessTunnel.preambleLength)
        XCTAssertEqual(String(decoding: preamble, as: UTF8.self), "agentland-tunnel/1 " + Self.vectorNode + "\n")
        XCTAssertEqual(RemoteAccessTunnel.alpn, Data("agentland/tunnel/1".utf8))
        // The contract's codes (docs/HOST-API.md, "The two apps"); IrohPeerGate uses 403 and 503.
        XCTAssertEqual(RemoteAccessTunnel.StreamCode.aborted.rawValue, 1)
        XCTAssertEqual(RemoteAccessTunnel.StreamCode.refused.rawValue, 2)
        XCTAssertEqual(RemoteAccessTunnel.ConnectionCode.notAdmitted.rawValue, 403)
        XCTAssertEqual(RemoteAccessTunnel.ConnectionCode.unavailable.rawValue, 503)
    }

    func testCapabilitiesReadRemoteAccessOfVersionOneOnly() throws {
        let mac = String(repeating: "b", count: 64)
        let base = #"{"interactions":false,"terminal":false,"chatProviders":["opencode"],"chatFeatures":[]"#
        let full = base + #","remoteAccess":{"version":1,"revision":"5d41402abc4b2a76b9719d911017c592","enabled":true,"nodeId":"\#(mac)","directAddresses":["1.2.3.4:38842","[2a01:4f8::7]:38842","192.168.0.5:38842"],"fallbackRelay":true,"relayUrl":"https://euw1-1.relay.n0.iroh.link./","sequence":7,"deviceNodeId":"\#(Self.vectorNode)"}}"#
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(full.utf8))
        let remote = try XCTUnwrap(capabilities.remoteAccess)
        XCTAssertTrue(capabilities.supportsRemoteAccess)
        XCTAssertEqual(remote, RemoteAccessCapabilities(revision: "5d41402abc4b2a76b9719d911017c592", enabled: true, nodeID: try node(mac), directAddresses: ["1.2.3.4:38842", "[2a01:4f8::7]:38842"],
                                                         fallbackRelay: true, relayURL: "https://euw1-1.relay.n0.iroh.link./", sequence: 7, deviceNodeID: try node()))
        XCTAssertTrue(remote.offersTunnel)
        XCTAssertFalse(remote.needsRegistration(of: try node()))
        XCTAssertTrue(remote.needsRegistration(of: try node(String(repeating: "c", count: 64))))
        // Round trip through the app's own encoding (saved capabilities).
        let again = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: JSONEncoder().encode(capabilities))
        XCTAssertEqual(again.remoteAccess, remote)

        // Before a report: off, no node ID; this device has registered nothing.
        let before = base + #","remoteAccess":{"version":1,"enabled":false,"directAddresses":[],"fallbackRelay":false}}"#
        let off = try XCTUnwrap(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(before.utf8)).remoteAccess)
        XCTAssertFalse(off.offersTunnel)
        XCTAssertEqual(off.sequence, 0, "a host that sends no sequence")
        let negative = base + #","remoteAccess":{"version":1,"enabled":false,"directAddresses":[],"fallbackRelay":false,"sequence":-3}}"#
        XCTAssertEqual(try XCTUnwrap(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(negative.utf8)).remoteAccess).sequence, 0)
        XCTAssertTrue(off.needsRegistration(of: try node()))
        // On, but with neither a direct address nor the fallback's relay: nothing to dial.
        let unmapped = base + #","remoteAccess":{"version":1,"enabled":true,"nodeId":"\#(mac)","directAddresses":[],"fallbackRelay":false}}"#
        XCTAssertFalse(try XCTUnwrap(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(unmapped.utf8)).remoteAccess).offersTunnel)
        let privateOnly = base + #","remoteAccess":{"version":1,"enabled":true,"nodeId":"\#(mac)","directAddresses":["192.168.0.5:38842","100.72.3.9:38842"],"fallbackRelay":false}}"#
        let inner = try XCTUnwrap(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(privateOnly.utf8)).remoteAccess)
        XCTAssertEqual(inner.directAddresses, [])
        XCTAssertFalse(inner.offersTunnel)
        let relayed = base + #","remoteAccess":{"version":1,"enabled":true,"nodeId":"\#(mac)","directAddresses":[],"fallbackRelay":true,"relayUrl":"https://euw1-1.relay.n0.iroh.link./"}}"#
        XCTAssertTrue(try XCTUnwrap(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(relayed.utf8)).remoteAccess).offersTunnel)
        // A relay without the fallback is not used.
        let stray = base + #","remoteAccess":{"version":1,"enabled":true,"nodeId":"\#(mac)","directAddresses":[],"fallbackRelay":false,"relayUrl":"https://relay.example"}}"#
        XCTAssertNil(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(stray.utf8)).remoteAccess?.relayURL)

        // Hosts without it, a later version and an unreadable entry: no remote access; the rest reads.
        for body in [base + "}", base + #","remoteAccess":{"version":2,"enabled":true}}"#,
                     base + #","remoteAccess":{"version":1,"enabled":true,"nodeId":"\#(mac.uppercased())"}}"#,
                     base + #","remoteAccess":"on"}"#] {
            let decoded = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(body.utf8))
            XCTAssertNil(decoded.remoteAccess, body)
            XCTAssertFalse(decoded.supportsRemoteAccess)
            XCTAssertEqual(decoded.chatProviders, ["opencode"])
        }
    }

    /// The Go host's `nonGlobalAddresses`, refused there in a report and never dialed here.
    func testOnlyGlobalDirectAddressesAreDialable() {
        let refused = ["0.0.0.0:38842", "0.1.2.3:38842", "10.0.0.5:38842", "172.16.0.1:38842", "172.31.255.255:38842", "192.168.0.5:38842",
                       "100.64.0.1:38842", "100.72.3.9:38842", "100.127.255.255:38842", "127.0.0.1:38842", "169.254.1.1:38842",
                       "192.0.0.2:38842", "192.0.2.1:38842", "198.51.100.7:38842", "203.0.113.7:38842", "198.18.0.1:38842",
                       "198.19.255.255:38842", "224.0.0.1:38842", "240.0.0.1:38842", "255.255.255.255:38842",
                       "[::]:38842", "[::1]:38842", "[::1.2.3.4]:38842", "[::ffff:192.168.0.5]:38842", "[64:ff9b::102:304]:38842", "[100::1]:38842",
                       "[fd7a:115c:a1e0::1]:38842", "[fc00::1]:38842", "[fe80::1]:38842", "[ff02::1]:38842",
                       "[2001::1]:38842", "[2001:2::1]:38842", "[2001:db8::7]:38842", "[3fff::1]:38842",
                       // Not ip:port.
                       "1.2.3.4", "1.2.3.4:0", "1.2.3.4:65536", "1.2.3.4:+1", "2a01:4f8::7:38842", "[2a01:4f8::7%en0]:38842", "[2a01:4f8::7]",
                       "mac.example:38842", "1.2.3:38842", ""]
        for address in refused {
            XCTAssertFalse(RemoteAccessDirectAddress.isDialable(address), address)
        }
        for address in ["8.8.8.8:1", "1.2.3.4:38842", "100.63.255.255:38842", "100.128.0.1:38842", "172.32.0.1:38842", "198.20.0.1:38842",
                        "[2a01:4f8::7]:38842", "[2001:200::1]:38842", "[2002:c000:204::1]:38842", "[3fff:1000::1]:38842", "[::ffff:1.2.3.4]:65535"] {
            XCTAssertTrue(RemoteAccessDirectAddress.isDialable(address), address)
        }
    }

    func testPairingSendsTheNodeOnlyWhenGiven() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/pair")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Pairing is not authenticated")
            return (200, Data(#"{"token":"new-token","deviceId":"9c1e44d0a7b2c35f8e016d42"}"#.utf8))
        }
        _ = try await client().pair(code: "0012345678", deviceName: "Phone", node: nil)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["code": "0012345678", "deviceName": "Phone"])
        let claim = try XCTUnwrap(IrohNodeClaim(nodeID: try node(), proof: Self.vectorPairProof))
        let answer = try await client().pair(code: "0012345678", deviceName: "Phone", node: claim)
        XCTAssertEqual(answer.deviceID, "9c1e44d0a7b2c35f8e016d42")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String],
                       ["code": "0012345678", "deviceName": "Phone", "irohNodeId": Self.vectorNode, "irohNodeProof": Self.vectorPairProof])
    }

    /// Pairing again (docs/HOST-API.md, "Pairing again"): the token this device holds for the host goes as the
    /// bearer token and the body stays as it was, so a host before pairing again ignores it; never this client's
    /// own token, and nothing that is not a plain token.
    func testPairingAgainSendsThePreviousTokenAsTheBearerOnly() async throws {
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"token":"new-token","deviceId":"9c1e44d0a7b2c35f8e016d42"}"#.utf8)) }
        let claim = try XCTUnwrap(IrohNodeClaim(nodeID: try node(), proof: Self.vectorPairProof))
        let answer = try await client().pair(code: "0012345678", deviceName: "Phone", node: claim, previousToken: "OLDTOKEN234567")
        XCTAssertEqual(answer.deviceID, "9c1e44d0a7b2c35f8e016d42")
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer OLDTOKEN234567")
        XCTAssertEqual(try json(sent.body) as? [String: String],
                       ["code": "0012345678", "deviceName": "Phone", "irohNodeId": Self.vectorNode, "irohNodeProof": Self.vectorPairProof])
        _ = try await client().pair(code: "0012345678", deviceName: "Phone", node: nil, previousToken: "OLDTOKEN234567")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["code": "0012345678", "deviceName": "Phone"])
        for unsent in [nil, "", "two words", "line\nbreak", String(repeating: "A", count: 257)] {
            _ = try await client().pair(code: "0012345678", deviceName: "Phone", node: nil, previousToken: unsent)
            XCTAssertNil(ArchiveStubProtocol.requests.last?.request.value(forHTTPHeaderField: "Authorization"), "\(String(describing: unsent))")
        }
    }

    func testRegisteringSendsTheClaimAndReportsTheHostsReasons() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/remote-access/device")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            return (200, Data(#"{"nodeId":"\#(Self.vectorNode)"}"#.utf8))
        }
        let claim = try XCTUnwrap(IrohNodeClaim(nodeID: try node(), proof: Self.vectorRegisterProof))
        let registered = try await client().registerIrohNode(claim)
        XCTAssertEqual(registered, try node())
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["nodeId": Self.vectorNode, "proof": Self.vectorRegisterProof])

        for (status, code) in [(403, "tunnel_refused"), (400, "invalid_node_proof"), (409, "node_id_in_use"), (501, "remote_access_unavailable")] {
            ArchiveStubProtocol.install { _, _ in (status, Data(#"{"error":{"code":"\#(code)","message":"No"}}"#.utf8)) }
            do {
                _ = try await client().registerIrohNode(claim)
                XCTFail("\(code) must be reported")
            } catch let error as ClientError {
                XCTAssertEqual(error, .server(code: code, message: "No"))
            }
        }
    }

    func testMacRoutesLongPollThePeersAndReportTheEndpoint() async throws {
        let mac = try node(String(repeating: "b", count: 64))
        ArchiveStubProtocol.install { request, _ in
            if request.url?.path == "/v1/remote-access/peers" {
                return (200, Data(#"{"version":"5d41402abc4b2a76b9719d911017c592","peers":[{"deviceId":"d1","nodeId":"\#(Self.vectorNode)"}]}"#.utf8))
            }
            return (200, Data(#"{"version":1,"enabled":true,"nodeId":"\#(mac.hex)","directAddresses":["1.2.3.4:38842"],"fallbackRelay":false,"sequence":4}"#.utf8))
        }
        let peers = try await client().remoteAccessPeers(after: "older", wait: 20)
        XCTAssertEqual(peers.version, "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(peers.peers.map(\.deviceID), ["d1"])
        XCTAssertEqual(peers.allowedKeys, [try node().publicKey])
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)
        let query = URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "after" }?.value, "older")
        XCTAssertEqual(query.first { $0.name == "wait" }?.value, "20000")
        XCTAssertGreaterThan(sent.timeoutInterval, 20, "The client must outlast the host's wait")
        _ = try await client().remoteAccessPeers(wait: 90)
        let clamped = URLComponents(url: try XCTUnwrap(ArchiveStubProtocol.requests.last?.request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(clamped.first { $0.name == "wait" }?.value, "20000")
        XCTAssertNil(clamped.first { $0.name == "after" })

        let advertised = try await client().reportRemoteAccessEndpoint(.on(nodeID: mac, udpPort: 38842, directAddresses: ["1.2.3.4:38842"]))
        XCTAssertEqual(advertised.nodeID, mac)
        XCTAssertEqual(advertised.sequence, 4, "the Mac writes the answer's sequence into the address record")
        let on = try json(ArchiveStubProtocol.requests.last?.body)
        XCTAssertEqual(on as NSDictionary, ["enabled": true, "nodeId": mac.hex, "udpPort": 38842, "directAddresses": ["1.2.3.4:38842"]] as NSDictionary)
        _ = try await client().reportRemoteAccessEndpoint(.on(nodeID: mac, udpPort: 38842, fallbackRelay: true, relayURL: "https://relay.example"))
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary,
                       ["enabled": true, "nodeId": mac.hex, "udpPort": 38842, "fallbackRelay": true, "relayUrl": "https://relay.example"] as NSDictionary)
        // Off sends only what the rules allow.
        var off = RemoteAccessEndpointReport.off(nodeID: mac, udpPort: 38842)
        off.directAddresses = ["1.2.3.4:38842"]
        off.fallbackRelay = true
        off.relayURL = "https://relay.example"
        _ = try await client().reportRemoteAccessEndpoint(off)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["enabled": false, "nodeId": mac.hex, "udpPort": 38842] as NSDictionary)
        _ = try await client().reportRemoteAccessEndpoint(.off())
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as NSDictionary, ["enabled": false] as NSDictionary)

        // No device with a node ID: the host answers an empty list (never null), which reads.
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"version":"e3b0c44298fc1c149afbf4c8996fb924","peers":[]}"#.utf8)) }
        let none = try await client().remoteAccessPeers()
        XCTAssertEqual(none.peers, [])
        XCTAssertEqual(none.allowedKeys, [])
    }

    private func hexData(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
