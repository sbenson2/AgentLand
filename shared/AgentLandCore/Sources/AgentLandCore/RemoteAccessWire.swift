import Foundation

// Remote access (docs/HOST-API.md, "Remote access (iroh)"): a paired device reaches its Mac from
// anywhere through iroh. The Mac app admits only paired devices' node IDs and bridges each stream to
// the host's tunnel socket, where requests are never the Mac's own. This file holds what both apps
// and the host agree on: node IDs, the proof a device signs with its iroh key, the tunnel's ALPN and
// preamble, `capabilities.remoteAccess`, and the routes. It does not link iroh: the apps sign with
// `SecretKey.sign(message:)` and pass the signature in.

/// An iroh node ID as the host writes it: the 32-byte Ed25519 public key in 64 lowercase
/// hexadecimal characters (the hex of `EndpointId.toBytes()`, never its description).
///
/// Keys that no private key backs are refused, as the host refuses them: a non-canonical encoding
/// (y at or above p = 2^255 − 19) and the eight points of small order, for which a cofactorless
/// Ed25519 check takes a signature made without any key.
public struct IrohNodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 32
    public let hex: String

    /// Nil unless `hex` is exactly 64 lowercase hexadecimal characters of a key a device can hold.
    public init?(hex: String) {
        guard Self.isLowerHex(hex, length: 2 * Self.byteCount) else { return nil }
        self.hex = hex
        guard Self.isStrongKey(publicKey) else { return nil }
    }

    /// The node ID of a 32-byte public key (`EndpointId.toBytes()`).
    public init?(publicKey: Data) {
        guard publicKey.count == Self.byteCount, Self.isStrongKey(publicKey) else { return nil }
        hex = publicKey.map { String(format: "%02x", $0) }.joined()
    }

    /// The y coordinates (little-endian, sign bit clear) of Ed25519's points of small order: 1 (the
    /// identity), p − 1 (order 2), 0 (order 4) and the two y of order 8. The host's `smallOrderY`.
    static let smallOrderY: [[UInt8]] = [
        [0x01] + [UInt8](repeating: 0, count: 31),
        [0xec] + [UInt8](repeating: 0xff, count: 30) + [0x7f],
        [UInt8](repeating: 0, count: 32),
        [0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
         0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05],
        [0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
         0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a],
    ]

    /// Whether 32 bytes could be a device's Ed25519 public key: y canonical and the point not of small
    /// order (a point off the curve fails any signature check on its own).
    static func isStrongKey(_ key: Data) -> Bool {
        guard key.count == byteCount else { return false }
        var y = [UInt8](key)
        y[31] &= 0x7f
        // Below p, compared from the most significant byte: 7f ff … ff ed.
        var below = false
        for index in stride(from: 31, through: 0, by: -1) {
            let limb: UInt8 = index == 31 ? 0x7f : (index == 0 ? 0xed : 0xff)
            if y[index] != limb {
                below = y[index] < limb
                break
            }
        }
        return below && !smallOrderY.contains(y)
    }

    public var description: String { hex }

    /// The 32 bytes of the public key (`EndpointId.fromBytes(bytes:)`).
    public var publicKey: Data {
        var bytes = Data(capacity: Self.byteCount)
        var high: UInt8?
        for character in hex.utf8 {
            let value = character <= 57 ? character - 48 : character - 87
            if let first = high {
                bytes.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = IrohNodeID(hex: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a node ID")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    static func isLowerHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The message a device signs with its iroh secret key (`SecretKey.sign(message:)`, Ed25519) to show
/// the host that it holds the key of the node ID it gives: four lines joined by a line feed, without
/// a final one.
public enum IrohNodeProof {
    public static let domain = "agentland-iroh-node/1"

    public enum Purpose: String, Sendable {
        /// `POST /v1/pair`; the binding is the pairing code exactly as sent in `code`.
        case pair
        /// `POST /v1/remote-access/device`; the binding is the device's `deviceId`.
        case register
    }

    public static func message(purpose: Purpose, binding: String, nodeID: IrohNodeID) -> Data {
        Data([domain, purpose.rawValue, binding, nodeID.hex].joined(separator: "\n").utf8)
    }
}

/// A node ID with its proof, as a device sends it: the proof is the 64-byte signature in 128
/// lowercase hexadecimal characters.
public struct IrohNodeClaim: Hashable, Sendable {
    public let nodeID: IrohNodeID
    public let proof: String

    /// `signature` is the 64 bytes `SecretKey.sign(message:).toBytes()` returns.
    public init?(nodeID: IrohNodeID, signature: Data) {
        guard signature.count == 64 else { return nil }
        self.nodeID = nodeID
        proof = signature.map { String(format: "%02x", $0) }.joined()
    }

    public init?(nodeID: IrohNodeID, proof: String) {
        guard IrohNodeID.isLowerHex(proof, length: 128) else { return nil }
        self.nodeID = nodeID
        self.proof = proof
    }
}

/// What the Mac app's bridge and the phone agree on for each stream.
public enum RemoteAccessTunnel {
    /// The ALPN both endpoints use.
    public static let alpn = Data("agentland/tunnel/1".utf8)
    /// The preamble's length: `agentland-tunnel/1`, a space, the node ID, a line feed.
    public static let preambleLength = 84

    /// The exact bytes the Mac app writes to the tunnel socket before the phone's TLS bytes, naming
    /// the node ID iroh verified (`Connection.remoteId()`).
    public static func preamble(nodeID: IrohNodeID) -> Data {
        Data(("agentland-tunnel/1 " + nodeID.hex + "\n").utf8)
    }

    /// Codes of a stream's reset and stop (`SendStream.reset`, `RecvStream.stop`). A stream that ends
    /// normally is finished, never reset, so the host's last bytes arrive.
    public enum StreamCode: UInt64, Sendable {
        /// A read or write failed on the other side's socket.
        case aborted = 1
        /// The host closed the tunnel connection before sending a byte (it refused the preamble or a
        /// limit, or is stopping), or the Mac could not reach the tunnel socket.
        case refused = 2
    }

    /// Application codes of the Mac's `IrohPeerGate` when it closes a connection (its `refusedCode`
    /// and `unavailableCode`).
    public enum ConnectionCode: Int64, Sendable {
        /// The node ID is not admitted: not a paired device's, or no longer.
        case notAdmitted = 403
        /// The Mac app is not taking connections now.
        case unavailable = 503

        /// The code of a connection the peer closed, from iroh's `Connection.closed()` or
        /// `closeReason()`: `closed by peer: <reason> (code <n>)`, or `closed by peer: <n>` without a
        /// reason. Nil for any other end (a timeout, a reset, this side's own close) and other codes.
        public init?(closeReason: String) {
            let prefix = "closed by peer: "
            guard closeReason.hasPrefix(prefix) else { return nil }
            let rest = closeReason.dropFirst(prefix.count)
            var digits = Substring(rest)
            if rest.hasSuffix(")"), let open = rest.range(of: " (code ", options: .backwards) {
                digits = rest[open.upperBound..<rest.index(before: rest.endIndex)]
            }
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  let value = Int64(digits) else { return nil }
            self.init(rawValue: value)
        }
    }
}

/// A direct address of the Mac (`ip:port`, an IPv6 address in brackets), as the host advertises it.
/// A device dials one only when its IP is global unicast, the host's own rule (`globalUnicast` in
/// desktop/remote_access.go): never a private, shared (carrier-grade NAT, Tailscale), loopback,
/// link-local, multicast, documentation, benchmarking or reserved address, which it could not reach
/// from outside (or would find someone else at).
public enum RemoteAccessDirectAddress {
    /// Whether `value` is `ip:port` with a global unicast IP and a port of 1–65535.
    public static func isDialable(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64, !value.contains("%"), let colon = value.lastIndex(of: ":") else { return false }
        let port = value[value.index(after: colon)...]
        guard (1...5).contains(port.count), port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber),
              let number = Int(port), (1...65535).contains(number) else { return false }
        let host = value[..<colon]
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), host.count > 2 else { return false }
            var address = in6_addr()
            let parsed = String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &address) }
            guard parsed == 1 else { return false }
            return isGlobal(ipv6: withUnsafeBytes(of: address) { [UInt8]($0) })
        }
        var address = in_addr()
        guard !host.contains(":"), String(host).withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        return isGlobal(ipv4: withUnsafeBytes(of: address) { [UInt8]($0) })
    }

    static func isGlobal(ipv4 b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (224..., _, _): return false  // this network, private, loopback, multicast and reserved
        case (100, 64...127, _): return false  // shared address space: carrier-grade NAT, Tailscale
        case (169, 254, _), (192, 168, _), (172, 16...31, _): return false  // link-local, private
        case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113): return false  // IETF protocol assignments, documentation
        case (198, 18...19, _): return false  // benchmarking
        default: return true
        }
    }

    static func isGlobal(ipv6 b: [UInt8]) -> Bool {
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return isGlobal(ipv4: Array(b[12..<16])) }
        guard b[0] & 0xe0 == 0x20 else { return false }  // 2000::/3
        if b[0] == 0x20, b[1] == 0x01, b[2] & 0xfe == 0 { return false }  // 2001::/23: Teredo, benchmarking, ORCHID
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false }  // 2001:db8::/32, documentation
        if b[0] == 0x3f, b[1] == 0xff, b[2] & 0xf0 == 0 { return false }  // 3fff::/20, documentation
        return true
    }
}

/// `capabilities.remoteAccess`: present when the host serves the tunnel socket.
public struct RemoteAccessCapabilities: Codable, Hashable, Sendable {
    /// The only version this client reads; an entry of another version counts as absent.
    public static let supportedVersion = 1
    /// At most this many direct addresses are kept.
    public static let maximumDirectAddresses = 8

    public var version: Int
    /// Opaque; changes whenever anything a device reads here changes (the pulse's `remoteAccess` line
    /// names the current one). Nil from a host that sends none.
    public var revision: String?
    /// The Mac app's last report: "Reach this Mac from anywhere" is on.
    public var enabled: Bool
    /// The Mac endpoint's node ID, once the Mac app has reported one.
    public var nodeID: IrohNodeID?
    /// External `ip:port` addresses of the Mac's router mapping (IPv6 in brackets).
    public var directAddresses: [String]
    /// The opt-in fallback through n0's public relays is on.
    public var fallbackRelay: Bool
    /// The Mac endpoint's home relay, only with `fallbackRelay`.
    public var relayURL: String?
    /// Orders the host's reports: it grows with each report that changes what a device sees here and
    /// never goes back. The Mac's address record carries the sequence of the report it follows, so a
    /// device takes the record only when it is newer than this entry (`tunnelRoute(record:)`). 0 before
    /// the first report and from a host that sends none.
    public var sequence: Int64
    /// The calling device's registered node ID; nil when it has none and for the Mac's own session.
    public var deviceNodeID: IrohNodeID?

    public init(version: Int = supportedVersion, revision: String? = nil, enabled: Bool = false, nodeID: IrohNodeID? = nil, directAddresses: [String] = [],
                fallbackRelay: Bool = false, relayURL: String? = nil, sequence: Int64 = 0, deviceNodeID: IrohNodeID? = nil) {
        self.version = version; self.revision = revision; self.enabled = enabled; self.nodeID = nodeID; self.directAddresses = directAddresses
        self.fallbackRelay = fallbackRelay; self.relayURL = relayURL; self.sequence = sequence; self.deviceNodeID = deviceNodeID
    }

    enum CodingKeys: String, CodingKey {
        case version, revision, enabled, directAddresses, fallbackRelay, sequence
        case nodeID = "nodeId", relayURL = "relayUrl", deviceNodeID = "deviceNodeId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        revision = (try? container.decodeIfPresent(String.self, forKey: .revision)).flatMap { $0.flatMap { (1...64).contains($0.utf8.count) ? $0 : nil } }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        nodeID = try container.decodeIfPresent(IrohNodeID.self, forKey: .nodeID)
        directAddresses = Array(((try? container.decodeIfPresent([String].self, forKey: .directAddresses)) ?? [])
            .filter(RemoteAccessDirectAddress.isDialable).prefix(Self.maximumDirectAddresses))
        fallbackRelay = try container.decodeIfPresent(Bool.self, forKey: .fallbackRelay) ?? false
        let relay = fallbackRelay ? try container.decodeIfPresent(String.self, forKey: .relayURL) : nil
        relayURL = relay.flatMap { Self.isDialableRelayURL($0) ? $0 : nil }
        sequence = max(0, (try? container.decodeIfPresent(Int64.self, forKey: .sequence)) ?? 0)
        deviceNodeID = try container.decodeIfPresent(IrohNodeID.self, forKey: .deviceNodeID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(nodeID, forKey: .nodeID)
        try container.encode(directAddresses, forKey: .directAddresses)
        try container.encode(fallbackRelay, forKey: .fallbackRelay)
        try container.encodeIfPresent(relayURL, forKey: .relayURL)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(deviceNodeID, forKey: .deviceNodeID)
    }

    /// Reads the entry when it is of the supported version; nil when absent, of another version or
    /// unreadable.
    public static func decodeSupported<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> RemoteAccessCapabilities? {
        guard let entry = (try? container.decodeIfPresent(RemoteAccessCapabilities.self, forKey: key)) ?? nil,
              entry.version == supportedVersion else { return nil }
        return entry
    }

    /// A device registers its node ID when the host does not have it (reached over a route other
    /// than the tunnel; never through it).
    public func needsRegistration(of own: IrohNodeID) -> Bool { deviceNodeID != own }

    /// Whether the tunnel is a way to this host now: remote access is on, the Mac's node ID is known and
    /// there is a way to reach its endpoint, a direct address or the fallback's relay. Remote access
    /// that is on with neither (the router made no mapping, or only one to a non-public address) is
    /// not dialed.
    public var offersTunnel: Bool { enabled && nodeID != nil && (!directAddresses.isEmpty || relayURL != nil) }

    /// Whether a device whose every address has failed in a race fetches the Mac's address record:
    /// whenever this kept entry has the Mac's node ID, whatever else it says. A record newer than this
    /// entry is the Mac's later word (the owner turned the switch on while the device was away, or the
    /// Mac's mapping had failed when it last connected), so this entry saying off or giving no address
    /// is no reason to skip it.
    public var fetchesAddressRecord: Bool { nodeID != nil }

    /// Where the tunnel dials. A fetched `record` (nil when there is none or none was fetched) counts
    /// only when it is newer than this entry (a higher `sequence`); then it replaces this entry: its
    /// addresses and relay when it names this entry's node ID (the one learned over a pinned
    /// connection), `.newMacKey` when it names another (the Mac has a new key), `.none` when it gives
    /// neither an address nor a relay. Otherwise this entry decides, as without a record: its own
    /// addresses and relay when it `offersTunnel`. So a record the Mac could not update or delete yet
    /// (iCloud unavailable, a write or delete still retrying) never overrides what the device learned
    /// later over a pinned connection: that the switch is off, or the Mac's new node ID.
    public func tunnelRoute(record: RemoteAccessAddressRecord?) -> RemoteAccessTunnelRoute {
        guard let nodeID else { return .none }
        if let record, record.sequence > sequence {
            guard record.nodeID == nodeID else { return .newMacKey }
            guard !record.directAddresses.isEmpty || record.relayURL != nil else { return .none }
            return .dial(nodeID: nodeID, directAddresses: record.directAddresses, relayURL: record.relayURL)
        }
        guard offersTunnel else { return .none }
        return .dial(nodeID: nodeID, directAddresses: directAddresses, relayURL: relayURL)
    }

    /// The host's form of `relayUrl`: an `https` URL with a host, without user, query or fragment, its
    /// path empty or `/`, at most 256 bytes of printable ASCII (`validRelayURL` in the host).
    public static func isRelayURL(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) && !"#?@\\".unicodeScalars.contains($0) }),
              let components = URLComponents(string: value) else { return false }
        return components.scheme == "https" && !(components.host ?? "").isEmpty && components.user == nil
            && components.password == nil && components.query == nil && components.fragment == nil
            && (components.path.isEmpty || components.path == "/")
    }

    /// A relay a device dials: the host's form (`isRelayURL`), https only, with a host a device can
    /// reach from anywhere, the rule of direct addresses: a global unicast IP address
    /// (`RemoteAccessDirectAddress.isDialable`'s rule) or a public DNS name, and a port of 1–65535 when
    /// one is given. Never loopback, private, shared, link-local or documentation addresses,
    /// `localhost`, a single label, a last label that does not start with a letter (so no numeric forms
    /// such as `127.1` or `0x7f.1` that resolvers read as addresses) or a special-use name (`.local`,
    /// `.localhost`, `.test`, `.invalid`, `.example`, `.internal`, `.home.arpa`, `.onion`, `.alt`,
    /// `.arpa`). Devices read `relayUrl` in capabilities (the Mac's word, over a pinned connection) this
    /// way. A DNS name can still resolve to any address, so the address record, which whoever can write
    /// the owner's iCloud can write, gives only one of n0's relays (`isN0RelayURL`).
    public static func isDialableRelayURL(_ value: String) -> Bool {
        guard isRelayURL(value), let components = URLComponents(string: value), var host = components.percentEncodedHost,
              !host.isEmpty else { return false }
        if let port = components.port, !(1...65535).contains(port) { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            var address = in6_addr()
            guard !host.contains("%"), host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
            return RemoteAccessDirectAddress.isGlobal(ipv6: withUnsafeBytes(of: address) { [UInt8]($0) })
        }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return RemoteAccessDirectAddress.isGlobal(ipv4: withUnsafeBytes(of: v4) { [UInt8]($0) })
        }
        return RemoteAccessRelayHost.isPublicName(host)
    }
}

extension RemoteAccessCapabilities {
    /// n0's public relays: `https://<one label>.relay.n0.iroh.link` (iroh 1.2's default relays,
    /// `use1-1`, `usw1-1`, `euc1-1` and `aps1-1`), with or without the final dot, on port 443. They are
    /// the only relays the Mac's fallback uses (`RelayMode.defaultMode()` until it has a home relay, then
    /// that one relay), so the only ones the address record may name.
    public static let n0RelayDomain = "relay.n0.iroh.link"

    /// A relay a device takes from the address record: one of n0's (`n0RelayDomain`), in the host's form
    /// (`isRelayURL`). n0 answers for those names, so whoever can write the record cannot point a phone's
    /// endpoint at a host of their choosing (one on the phone's network, or a relay they run).
    public static func isN0RelayURL(_ value: String) -> Bool {
        guard isDialableRelayURL(value), let components = URLComponents(string: value), var host = components.host?.lowercased(),
              components.port == nil || components.port == 443 else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.hasSuffix("." + n0RelayDomain) else { return false }
        let label = host.dropLast(n0RelayDomain.count + 1)
        return !label.isEmpty && !label.contains(".")
    }
}

/// The DNS names a device takes for a relay (`RemoteAccessCapabilities.isDialableRelayURL`).
enum RemoteAccessRelayHost {
    /// Special-use names (RFC 6761, 6762, 7686, 8375, 9476, and `.internal`) that never name a public
    /// relay.
    static let specialUseSuffixes = ["localhost", "local", "test", "invalid", "example", "internal", "home.arpa", "onion", "alt", "arpa"]

    static func isPublicName(_ value: String) -> Bool {
        var name = value.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard (1...253).contains(name.utf8.count) else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }), let last = labels.last?.utf8.first, (97...122).contains(last) else { return false }
        return !specialUseSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }
}

/// The Mac's address record in the owner's private CloudKit database (docs/HOST-API.md "When the Mac's
/// address changes"), as far as a device takes anything from it: the node ID it names, direct
/// addresses that `RemoteAccessDirectAddress.isDialable` takes (at most 8), a relay URL that is one of
/// n0's relays (`RemoteAccessCapabilities.isN0RelayURL`, the only relays the Mac's fallback uses) and the
/// sequence of the report it follows. Nothing else in it counts, and a device never keeps it as the
/// host's entry.
public struct RemoteAccessAddressRecord: Hashable, Sendable {
    /// Zone `RemoteAccess` of the private database of `iCloud.dev.agentland`; the record's name is the
    /// host's `hostId`.
    public static let zoneName = "RemoteAccess"
    public static let recordType = "RemoteAccessAddress"

    public let nodeID: IrohNodeID
    public let directAddresses: [String]
    public let relayURL: String?
    /// The `sequence` of the host's report the record follows (`RemoteAccessCapabilities.sequence`).
    public let sequence: Int64

    /// The record's `nodeId`, `directAddresses`, `relayUrl` and `sequence` fields. Nil when `nodeId` is
    /// not a node ID or `sequence` is missing or below 1: such a record is no record, since a device
    /// cannot tell whether it is newer than what it keeps.
    public init?(nodeID: String, directAddresses: [String], relayURL: String?, sequence: Int64?) {
        guard let node = IrohNodeID(hex: nodeID), let sequence, sequence >= 1 else { return nil }
        self.nodeID = node
        self.sequence = sequence
        self.directAddresses = Array(directAddresses.filter(RemoteAccessDirectAddress.isDialable)
            .prefix(RemoteAccessCapabilities.maximumDirectAddresses))
        self.relayURL = relayURL.flatMap { RemoteAccessCapabilities.isN0RelayURL($0) ? $0 : nil }
    }
}

/// Where a device dials the tunnel (`RemoteAccessCapabilities.tunnelRoute(record:)`).
public enum RemoteAccessTunnelRoute: Hashable, Sendable {
    /// `EndpointAddr(id: nodeID, relayUrl: relayURL, addresses: directAddresses)`, from an endpoint
    /// that runs with `endpointRelayURLs`.
    case dial(nodeID: IrohNodeID, directAddresses: [String], relayURL: String?)
    /// An address record newer than the kept entry names another node ID than the one learned over a
    /// pinned connection: the Mac has a new key. Nothing is dialed, and the offline banner asks for one
    /// connection at home or over Tailscale.
    case newMacKey
    /// There is no way to the Mac's endpoint.
    case none

    /// The relays the phone's endpoint runs with to dial this route: the route's relay alone
    /// (`RelayMode.customFromUrls([relayURL])`), or none (`RelayMode.disabled()`). They come from the
    /// route, never from the kept entry's `fallbackRelay`: iroh dials through a relay only when the
    /// dialing endpoint runs with it, so a relay-only route from the address record (the Mac behind
    /// carrier-grade NAT, the fallback turned on while the phone was away) is reached only this way;
    /// and without a relay on the route the endpoint talks to none.
    public var endpointRelayURLs: [String] {
        guard case let .dial(_, _, relayURL?) = self else { return [] }
        return [relayURL]
    }

    /// Whether the phone's endpoint, running with the relays `running`, must start again with
    /// `endpointRelayURLs` before it dials this route (the Mac picked another relay, the record brought
    /// one, or the route has none). A route that dials nothing needs no endpoint.
    public func needsEndpointRestart(runningWith running: [String]) -> Bool {
        guard case .dial = self else { return false }
        return running != endpointRelayURLs
    }
}

public extension CapabilitiesResponse {
    /// Hosts that list `remoteAccess` take `POST /v1/remote-access/device`.
    var supportsRemoteAccess: Bool { remoteAccess != nil }
}

/// The Mac endpoint's report (`POST /v1/remote-access/endpoint`, local-only). The report replaces
/// the last one as a whole; members the rules leave out while off are never sent.
public struct RemoteAccessEndpointReport: Encodable, Hashable, Sendable {
    public var enabled: Bool
    public var nodeID: IrohNodeID?
    public var udpPort: UInt16?
    public var directAddresses: [String]
    public var fallbackRelay: Bool
    public var relayURL: String?

    /// On: the node ID and bound UDP port are required.
    public static func on(nodeID: IrohNodeID, udpPort: UInt16, directAddresses: [String] = [], fallbackRelay: Bool = false,
                          relayURL: String? = nil) -> RemoteAccessEndpointReport {
        RemoteAccessEndpointReport(enabled: true, nodeID: nodeID, udpPort: udpPort, directAddresses: directAddresses,
                                   fallbackRelay: fallbackRelay, relayURL: fallbackRelay ? relayURL : nil)
    }

    /// Off: devices may still learn the Mac's node ID.
    public static func off(nodeID: IrohNodeID? = nil, udpPort: UInt16? = nil) -> RemoteAccessEndpointReport {
        RemoteAccessEndpointReport(enabled: false, nodeID: nodeID, udpPort: udpPort, directAddresses: [], fallbackRelay: false, relayURL: nil)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, udpPort, directAddresses, fallbackRelay
        case nodeID = "nodeId", relayURL = "relayUrl"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(nodeID, forKey: .nodeID)
        try container.encodeIfPresent(udpPort, forKey: .udpPort)
        if enabled && !directAddresses.isEmpty { try container.encode(directAddresses, forKey: .directAddresses) }
        if enabled && fallbackRelay {
            try container.encode(true, forKey: .fallbackRelay)
            try container.encodeIfPresent(relayURL, forKey: .relayURL)
        }
    }
}

/// `GET /v1/remote-access/peers`' answer: the node IDs the Mac's gate admits.
public struct RemoteAccessPeers: Decodable, Hashable, Sendable {
    public struct Peer: Decodable, Hashable, Sendable {
        public var deviceID: String
        public var nodeID: IrohNodeID
        enum CodingKeys: String, CodingKey { case deviceID = "deviceId", nodeID = "nodeId" }
    }
    /// Opaque; the same list has the same version.
    public var version: String
    public var peers: [Peer]

    /// The 32-byte public keys for `IrohPeerGate.setAllowed`.
    public var allowedKeys: Set<Data> { Set(peers.map(\.nodeID.publicKey)) }
}

extension APIClient {
    /// The longest wait the peers route takes.
    public static let remoteAccessPeersMaxWait: TimeInterval = 20

    /// `POST /v1/pair` with the device's node ID and a proof for purpose `pair` (binding: `code`).
    /// Send a claim only when the QR invitation carries `remoteAccess` version 1; without one this is
    /// `pair(code:deviceName:)`.
    ///
    /// `previousToken` is the token this device holds for the same host (the same certificate
    /// fingerprint and address), to pair again over its own record (docs/HOST-API.md, "Pairing again"):
    /// it travels as the request's bearer token, which this public route ignores on hosts before pairing
    /// again, so the body stays as it was. A host that takes it answers that record's device ID, and the
    /// token stops working; any other answer is a new record. A token that is not a plain token is not sent.
    public func pair(code: String, deviceName: String, node: IrohNodeClaim?, previousToken: String? = nil) async throws -> PairResponse {
        var body = ["code": code, "deviceName": deviceName]
        if let node { body["irohNodeId"] = node.nodeID.hex; body["irohNodeProof"] = node.proof }
        return try await post("/v1/pair", body: body, authenticated: false,
                              bearer: previousToken.flatMap { Self.isPlainToken($0) ? $0 : nil }, expected: 200)
    }

    /// A token as hosts issue them: base32 letters and digits, at most 256 of them (the host ignores longer).
    static func isPlainToken(_ token: String) -> Bool {
        (1...256).contains(token.utf8.count) && token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// `POST /v1/remote-access/device`: registers this device's node ID with a proof for purpose
    /// `register` (binding: the device ID). Only over a route other than the tunnel, and only to hosts
    /// that list `remoteAccess`. Registering the same node ID again changes nothing.
    public func registerIrohNode(_ claim: IrohNodeClaim) async throws -> IrohNodeID {
        let answer: RegisteredNode = try await post("/v1/remote-access/device", body: ["nodeId": claim.nodeID.hex, "proof": claim.proof],
                                                    expected: 200)
        return answer.nodeID
    }

    /// `GET /v1/remote-access/peers` (the Mac's own session): with `after` equal to the current version
    /// and a `wait`, the host answers when the list changes or the wait passes.
    public func remoteAccessPeers(after version: String? = nil, wait: TimeInterval? = nil) async throws -> RemoteAccessPeers {
        var query: [URLQueryItem] = []
        if let version, !version.isEmpty { query.append(URLQueryItem(name: "after", value: version)) }
        var timeout: TimeInterval = 20
        if let wait {
            let clamped = min(max(0, wait), Self.remoteAccessPeersMaxWait)
            query.append(URLQueryItem(name: "wait", value: String(Int(clamped * 1000))))
            timeout = clamped + 10
        }
        return try await get("/v1/remote-access/peers", query: query, timeout: timeout)
    }

    /// `POST /v1/remote-access/endpoint` (the Mac's own session): the endpoint's state, which devices
    /// then see in `capabilities.remoteAccess`.
    public func reportRemoteAccessEndpoint(_ report: RemoteAccessEndpointReport) async throws -> RemoteAccessCapabilities {
        try await post("/v1/remote-access/endpoint", body: report, expected: 200)
    }

    private struct RegisteredNode: Decodable {
        let nodeID: IrohNodeID
        enum CodingKeys: String, CodingKey { case nodeID = "nodeId" }
    }
}
