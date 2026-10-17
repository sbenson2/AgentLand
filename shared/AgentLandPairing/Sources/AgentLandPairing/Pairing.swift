import Foundation

public enum PairingError: Error, LocalizedError, Equatable, Sendable {
    case invalidAdvertisement
    case invalidInvitation
    case unsupportedVersion
    case expired

    public var errorDescription: String? {
        switch self {
        case .invalidAdvertisement: "This computer did not provide valid HTTPS connection details."
        case .invalidInvitation: "This is not a valid AgentLand pairing QR code."
        case .unsupportedVersion: "This pairing format needs a newer version of AgentLand."
        case .expired: "This pairing code has expired or the device clock is incorrect. Create a new code on your computer."
        }
    }
}

/// Bonjour finds a candidate. Its advertised fingerprint is not proof of identity:
/// compare it with the computer, or obtain it out of band by scanning its QR code.
public struct HostAdvertisement: Hashable, Sendable {
    public static let serviceType = "_agentland._tcp."
    public static let serviceDomain = "local."
    public let name: String
    public let address: String
    public let certificateSHA256: String
    public init(name: String, address: String, certificateSHA256: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = certificateSHA256.lowercased()
        guard !name.isEmpty, name.utf8.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              address.utf8.count <= 240,
              var url = URLComponents(string: address), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              host.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || [45, 46, 58, 91, 93].contains($0) }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.port.map({ (1...65535).contains($0) }) ?? true
        else { throw PairingError.invalidAdvertisement }
        let unbracketedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard unbracketedHost != "localhost", !unbracketedHost.hasSuffix(".localhost"),
              !unbracketedHost.hasPrefix("127."), !unbracketedHost.hasPrefix("::ffff:127."),
              !["0.0.0.0", "::", "::1", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1"].contains(unbracketedHost)
        else { throw PairingError.invalidAdvertisement }
        url.scheme = "https"; url.host = host; url.path = ""
        guard let canonical = url.url?.absoluteString else { throw PairingError.invalidAdvertisement }
        self.name = name
        self.address = canonical
        self.certificateSHA256 = fingerprint
    }

    public init(name: String, txtRecord: [String: Data]) throws {
        guard txtRecord.count <= 12,
              txtRecord.reduce(0, { $0 + $1.key.utf8.count + $1.value.count }) <= 1024,
              let version = txtRecord["v"].flatMap({ String(data: $0, encoding: .utf8) }),
              let address = txtRecord["url"].flatMap({ String(data: $0, encoding: .utf8) }),
              let fingerprint = txtRecord["fp"].flatMap({ String(data: $0, encoding: .utf8) })
        else { throw PairingError.invalidAdvertisement }
        guard version == "1" else { throw PairingError.unsupportedVersion }
        try self.init(name: name, address: address, certificateSHA256: fingerprint)
    }

    /// Public connection hints only. Codes and device credentials never enter DNS.
    public var txtRecord: [String: Data] {
        ["v": Data("1".utf8), "url": Data(address.utf8), "fp": Data(certificateSHA256.utf8)]
    }
}

/// Another way to reach the host than the invitation's address, as the host lists it in
/// `capabilities.routes` (docs/HOST-API.md, "Routes"): its local name, or its Tailscale name and
/// addresses. A route is only a way in: the device still pins the invitation's certificate and
/// validates it for the invitation's host name on every route.
public struct PairingRoute: Hashable, Sendable {
    /// At most this many routes travel in one invitation, each with at most `maximumAddresses`.
    public static let maximumRoutes = 4
    public static let maximumAddresses = 4

    /// "local", "tailscale", or a later kind this version keeps but does not name.
    public let kind: String
    /// A DNS name in lower case without a trailing dot, or an IP address.
    public let host: String
    /// IP addresses of the same route.
    public let addresses: [String]
    public let port: Int

    public init(kind: String, host: String, addresses: [String] = [], port: Int) throws {
        guard (1...16).contains(kind.utf8.count), kind.utf8.allSatisfy({ (97...122).contains($0) }),
              let host = Self.normalizedHost(host),
              addresses.count <= Self.maximumAddresses,
              (1...65535).contains(port)
        else { throw PairingError.invalidInvitation }
        var normalized: [String] = []
        for address in addresses {
            guard let value = Self.normalizedHost(address), Self.isIPAddress(value) else { throw PairingError.invalidInvitation }
            if !normalized.contains(value) { normalized.append(value) }
        }
        self.kind = kind
        self.host = host
        self.addresses = normalized
        self.port = port
    }

    /// A DNS name (lower case, no trailing dot, letters, digits and hyphens in each label) or an IP
    /// address without brackets; nil for anything else.
    public static func normalizedHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if isIPAddress(host) { return host }
        if host.hasSuffix(".") { host.removeLast() }
        guard (1...253).contains(host.utf8.count) else { return nil }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 })
            else { return nil }
        }
        return host
    }

    static func isIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 45, !value.contains("%") else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

/// That the host takes the device's iroh node ID when it pairs (docs/HOST-API.md, "Pairing with a
/// node ID"). The Mac app adds it to invitations when its host lists `remoteAccess` in capabilities.
public struct PairingRemoteAccess: Hashable, Sendable {
    /// The only version this app reads and writes; another version is left out when read.
    public static let currentVersion = 1
    public let version: Int
    public init() { version = Self.currentVersion }
}

public struct PairingInvitation: Equatable, Sendable {
    public let advertisement: HostAdvertisement
    public let code: String
    public let expiresAt: Date
    /// The host's other routes (`PairingRoute`), empty from hosts and invitations before them.
    public let routes: [PairingRoute]
    /// Set when the host takes `irohNodeId` and `irohNodeProof` in `POST /v1/pair`; nil for hosts and
    /// invitations before remote access, and for a later version of it.
    public let remoteAccess: PairingRemoteAccess?
    /// A device sends its node ID and proof with the pairing only when this is true.
    public var acceptsIrohNodeID: Bool { remoteAccess?.version == PairingRemoteAccess.currentVersion }

    public init(advertisement: HostAdvertisement, code: String, expiresAt: Date, routes: [PairingRoute] = [],
                remoteAccess: PairingRemoteAccess? = nil) throws {
        guard (10...64).contains(code.utf8.count),
              code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970 > 0,
              expiresAt.timeIntervalSince1970 < 4_102_444_800,
              routes.count <= PairingRoute.maximumRoutes
        else { throw PairingError.invalidInvitation }
        self.advertisement = advertisement
        self.code = code
        self.expiresAt = Date(timeIntervalSince1970: floor(expiresAt.timeIntervalSince1970))
        self.routes = routes
        self.remoteAccess = remoteAccess
    }

    public func encoded() throws -> String {
        let wireRoutes = routes.isEmpty ? nil : WireRoutes(version: WireRoutes.currentVersion, items: routes.map {
            WireRoute(kind: $0.kind, host: $0.host, addresses: $0.addresses.isEmpty ? nil : $0.addresses, port: $0.port)
        })
        let payload = WireInvitation(version: 1, name: advertisement.name, address: advertisement.address,
                                     certificateSHA256: advertisement.certificateSHA256, code: code,
                                     expiresAt: Int64(expiresAt.timeIntervalSince1970), routes: wireRoutes,
                                     remoteAccess: remoteAccess.map { WireRemoteAccess(version: $0.version) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "agentland://pair?data=" + encoded
    }

    public static func parse(_ text: String, now: Date = Date()) throws -> PairingInvitation {
        guard text.utf8.count <= 4096,
              let url = URLComponents(string: text), url.scheme == "agentland", url.host == "pair",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, items.count == 1, items[0].name == "data",
              let encoded = items[0].value, !encoded.isEmpty,
              encoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { throw PairingError.invalidInvitation }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let wire = try? JSONDecoder().decode(WireInvitation.self, from: data)
        else { throw PairingError.invalidInvitation }
        guard wire.version == 1 else { throw PairingError.unsupportedVersion }
        let expiry = Date(timeIntervalSince1970: Double(wire.expiresAt))
        guard now < expiry, expiry.timeIntervalSince(now) <= 15 * 60 else { throw PairingError.expired }
        let host = try HostAdvertisement(name: wire.name, address: wire.address, certificateSHA256: wire.certificateSHA256)
        // Routes of a later version are left out; the invitation still works through its address.
        guard (wire.routes?.items?.count ?? 0) <= PairingRoute.maximumRoutes else { throw PairingError.invalidInvitation }
        let routes = try (wire.routes?.items ?? []).map {
            try PairingRoute(kind: $0.kind, host: $0.host, addresses: $0.addresses ?? [], port: $0.port)
        }
        // Remote access of a later version is left out; the device then pairs without its node ID.
        let remoteAccess = wire.remoteAccess?.version == PairingRemoteAccess.currentVersion ? PairingRemoteAccess() : nil
        return try PairingInvitation(advertisement: host, code: wire.code, expiresAt: expiry, routes: routes, remoteAccess: remoteAccess)
    }
}

private struct WireInvitation: Codable {
    let version: Int
    let name: String
    let address: String
    let certificateSHA256: String
    let code: String
    let expiresAt: Int64
    /// Added with routes; invitations before them have none, and apps before them ignore it.
    let routes: WireRoutes?
    /// Added with remote access: `{"version": 1}`. Absent otherwise, so an invitation without it is
    /// byte for byte what it was; apps before it ignore it.
    let remoteAccess: WireRemoteAccess?
}

/// `remoteAccess` in the invitation. Members a later version adds are ignored.
private struct WireRemoteAccess: Codable {
    let version: Int
}

/// `routes` in the invitation: `{"version": 1, "items": [{kind, host, addresses?, port}]}`. Items of
/// another version are not read, so a later layout never breaks this version's pairing.
private struct WireRoutes: Codable {
    static let currentVersion = 1
    let version: Int
    let items: [WireRoute]?

    init(version: Int, items: [WireRoute]) { self.version = version; self.items = items }

    enum CodingKeys: String, CodingKey { case version, items }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        items = version == Self.currentVersion ? try container.decodeIfPresent([WireRoute].self, forKey: .items) : nil
    }
}

private struct WireRoute: Codable {
    let kind: String
    let host: String
    let addresses: [String]?
    let port: Int
}
