import Foundation
import XCTest
@testable import AgentLandPairing

final class PairingTests: XCTestCase {
    private let fingerprint = String(repeating: "ab", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testQRCodeCarriesTheExactAddressPinAndSingleUseCode() throws {
        let host = try HostAdvertisement(name: "Studio Mac", address: "https://studio.local:9841/", certificateSHA256: fingerprint.uppercased())
        let invitation = try PairingInvitation(advertisement: host, code: "0012345678", expiresAt: now.addingTimeInterval(600))
        let decoded = try PairingInvitation.parse(invitation.encoded(), now: now)
        XCTAssertEqual(decoded.advertisement.name, "Studio Mac")
        XCTAssertEqual(decoded.advertisement.address, "https://studio.local:9841")
        XCTAssertEqual(decoded.advertisement.certificateSHA256, fingerprint)
        XCTAssertEqual(decoded.code, "0012345678")
        XCTAssertEqual(decoded.expiresAt, Date(timeIntervalSince1970: 1_800_000_600))
    }

    func testDiscoveryContainsNoPairingSecretAndCannotDowngradeHTTPS() throws {
        let host = try HostAdvertisement(name: "Mac", address: "https://studio.local:9841", certificateSHA256: fingerprint)
        XCTAssertEqual(Set(host.txtRecord.keys), ["v", "url", "fp"])
        XCTAssertEqual(try HostAdvertisement(name: "Mac", txtRecord: host.txtRecord), host)
        for address in ["http://studio.local:9841", "https://secret@studio.local", "https://studio.local/?code=secret", "https://studio.local/#secret", "https://studio.local/v1/pair", "https://localhost:9841", "https://127.0.0.1:9841", "https://0.0.0.0:9841", "https://[::1]:9841", "https://studio.local:0", "https://studio.local:70000"] {
            XCTAssertThrowsError(try HostAdvertisement(name: "Mac", address: address, certificateSHA256: fingerprint), address)
        }
    }

    func testDiscoveryRejectsUnversionedMalformedOrOversizedRecords() throws {
        let good: [String: Data] = ["v": Data("1".utf8), "url": Data("https://studio.local:9841".utf8), "fp": Data(fingerprint.utf8)]
        for key in ["v", "url", "fp"] {
            var bad = good; bad.removeValue(forKey: key)
            XCTAssertThrowsError(try HostAdvertisement(name: "Mac", txtRecord: bad))
        }
        for fp in ["", "abc", String(repeating: "é", count: 64), String(repeating: "g", count: 64)] {
            var bad = good; bad["fp"] = Data(fp.utf8)
            XCTAssertThrowsError(try HostAdvertisement(name: "Mac", txtRecord: bad))
        }
        var future = good; future["v"] = Data("2".utf8)
        XCTAssertThrowsError(try HostAdvertisement(name: "Mac", txtRecord: future))
        var huge = good; huge["extra"] = Data(repeating: 65, count: 4096)
        XCTAssertThrowsError(try HostAdvertisement(name: "Mac", txtRecord: huge))
        XCTAssertThrowsError(try HostAdvertisement(name: "Mac\nAnother host", address: "https://studio.local", certificateSHA256: fingerprint))
    }

    func testExpiredAndImplausiblyLongLivedQRInvitationsAreRejected() throws {
        let host = try HostAdvertisement(name: "Mac", address: "https://studio.local", certificateSHA256: fingerprint)
        for expiry in [now, now.addingTimeInterval(-1), now.addingTimeInterval(86_400)] {
            let invitation = try PairingInvitation(advertisement: host, code: "1234567890", expiresAt: expiry)
            XCTAssertThrowsError(try PairingInvitation.parse(invitation.encoded(), now: now))
        }
    }

    func testScannerRejectsUnrelatedURLsDuplicateFieldsAndUntrustedPayloads() throws {
        for input in ["https://example.com", "agentland://pair?data=x&data=y", "agentland://pair?data=x#fragment", "agentland://other?data=x", "agentland://pair?data=" + String(repeating: "A", count: 4097)] {
            XCTAssertThrowsError(try PairingInvitation.parse(input, now: now))
        }
        let wire: [String: Any] = ["version": 1, "name": "Mac", "address": "http://studio.local:9841", "certificateSHA256": fingerprint, "code": "1234567890", "expiresAt": 1_800_000_600]
        let data = try JSONSerialization.data(withJSONObject: wire).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try PairingInvitation.parse("agentland://pair?data=" + data, now: now))
    }

    func testQRCodeCarriesTheHostsRoutes() throws {
        let host = try HostAdvertisement(name: "Mac mini", address: "https://robins-mac-mini.local:9841", certificateSHA256: fingerprint)
        let routes = [try PairingRoute(kind: "local", host: "Robins-Mac-mini.local.", port: 9841),
                      try PairingRoute(kind: "tailscale", host: "robins-mac-mini.tail1a2b3c.ts.net",
                                       addresses: ["100.88.12.34", "[FD7A:115C:A1E0::1]"], port: 9841)]
        let invitation = try PairingInvitation(advertisement: host, code: "0012345678", expiresAt: now.addingTimeInterval(600), routes: routes)
        let decoded = try PairingInvitation.parse(invitation.encoded(), now: now)
        XCTAssertEqual(decoded.routes.map(\.host), ["robins-mac-mini.local", "robins-mac-mini.tail1a2b3c.ts.net"])
        XCTAssertEqual(decoded.routes.last?.addresses, ["100.88.12.34", "fd7a:115c:a1e0::1"])
        XCTAssertEqual(decoded.routes.map(\.kind), ["local", "tailscale"])
        XCTAssertEqual(decoded, try PairingInvitation.parse(invitation.encoded(), now: now))
        // Without routes the payload is what it was before them.
        let plain = try PairingInvitation(advertisement: host, code: "0012345678", expiresAt: now.addingTimeInterval(600))
        XCTAssertFalse(try payload(plain.encoded()).keys.contains("routes"))
    }

    func testInvitationsBeforeRoutesAndRoutesOfALaterVersionStillPair() throws {
        let base: [String: Any] = ["version": 1, "name": "Mac", "address": "https://studio.local:9841", "certificateSHA256": fingerprint,
                                   "code": "1234567890", "expiresAt": 1_800_000_600]
        XCTAssertEqual(try PairingInvitation.parse(link(base), now: now).routes, [])
        var later = base
        later["routes"] = ["version": 2, "items": [["via": "relay", "endpoint": ["x": 1]]]]
        let parsed = try PairingInvitation.parse(link(later), now: now)
        XCTAssertEqual(parsed.routes, [], "Routes this version cannot read are left out")
        XCTAssertEqual(parsed.advertisement.address, "https://studio.local:9841")
    }

    func testMalformedOrOversizedRoutesAreRejected() throws {
        let base: [String: Any] = ["version": 1, "name": "Mac", "address": "https://studio.local:9841", "certificateSHA256": fingerprint,
                                   "code": "1234567890", "expiresAt": 1_800_000_600]
        let good: [String: Any] = ["kind": "tailscale", "host": "studio.example.ts.net", "addresses": ["100.64.0.1"], "port": 9841]
        var bad: [[String: Any]] = []
        for (key, value) in [("host", "https://studio.local" as Any), ("host", "studio local"), ("host", ""), ("port", 0), ("port", 70000),
                             ("kind", "Tailscale"), ("addresses", ["studio.local"]), ("addresses", ["fe80::1%en0"]),
                             ("addresses", Array(repeating: "100.64.0.1", count: 5))] {
            var route = good; route[key] = value; bad.append(route)
        }
        for route in bad {
            var invitation = base
            invitation["routes"] = ["version": 1, "items": [route]]
            XCTAssertThrowsError(try PairingInvitation.parse(link(invitation), now: now), "\(route)")
        }
        var tooMany = base
        tooMany["routes"] = ["version": 1, "items": Array(repeating: good, count: 5)]
        XCTAssertThrowsError(try PairingInvitation.parse(link(tooMany), now: now))
        var fine = base
        fine["routes"] = ["version": 1, "items": [good]]
        XCTAssertEqual(try PairingInvitation.parse(link(fine), now: now).routes.first?.addresses, ["100.64.0.1"])
    }

    func testQRCodeSaysWhenTheHostTakesTheDevicesNodeID() throws {
        let host = try HostAdvertisement(name: "Mac mini", address: "https://robins-mac-mini.local:9841", certificateSHA256: fingerprint)
        let invitation = try PairingInvitation(advertisement: host, code: "0012345678", expiresAt: now.addingTimeInterval(600),
                                               remoteAccess: PairingRemoteAccess())
        let decoded = try PairingInvitation.parse(invitation.encoded(), now: now)
        XCTAssertEqual(decoded.remoteAccess, PairingRemoteAccess())
        XCTAssertTrue(decoded.acceptsIrohNodeID)
        XCTAssertEqual(try payload(invitation.encoded())["remoteAccess"] as? [String: Int], ["version": 1])
        XCTAssertEqual(decoded, invitation)
        // Without it the payload is what it was before remote access, and nothing is sent at pairing.
        let plain = try PairingInvitation(advertisement: host, code: "0012345678", expiresAt: now.addingTimeInterval(600))
        XCTAssertFalse(try payload(plain.encoded()).keys.contains("remoteAccess"))
        XCTAssertFalse(try PairingInvitation.parse(plain.encoded(), now: now).acceptsIrohNodeID)
    }

    func testRemoteAccessOfALaterVersionIsLeftOutAndTheInvitationStillPairs() throws {
        let base: [String: Any] = ["version": 1, "name": "Mac", "address": "https://studio.local:9841", "certificateSHA256": fingerprint,
                                   "code": "1234567890", "expiresAt": 1_800_000_600]
        var later = base
        later["remoteAccess"] = ["version": 2, "nodeId": String(repeating: "a", count: 64)]
        let parsed = try PairingInvitation.parse(link(later), now: now)
        XCTAssertNil(parsed.remoteAccess)
        XCTAssertFalse(parsed.acceptsIrohNodeID)
        XCTAssertEqual(parsed.code, "1234567890")
        var current = base
        current["remoteAccess"] = ["version": 1, "later": true]
        XCTAssertTrue(try PairingInvitation.parse(link(current), now: now).acceptsIrohNodeID, "Members a later app adds are ignored")
        for malformed: Any in [["version": "1"], ["later": true], "1", 1] {
            var bad = base
            bad["remoteAccess"] = malformed
            XCTAssertThrowsError(try PairingInvitation.parse(link(bad), now: now), "\(malformed)")
        }
    }

    private func link(_ wire: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: wire).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "agentland://pair?data=" + data
    }

    private func payload(_ link: String) throws -> [String: Any] {
        var encoded = String(link.dropFirst("agentland://pair?data=".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as? [String: Any])
    }
}
