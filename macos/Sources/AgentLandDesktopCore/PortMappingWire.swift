import Foundation

/// The transport a router mapping forwards.
public enum MappedTransport: String, Sendable, Hashable, CaseIterable {
    case udp
    case tcp

    /// IANA protocol number, as PCP carries it.
    var protocolNumber: UInt8 { self == .udp ? 17 : 6 }
    /// NAT-PMP's mapping opcode.
    var natPMPOpcode: UInt8 { self == .udp ? 1 : 2 }
}

/// One port the Mac asks its router to forward.
public struct PortMappingRequest: Sendable, Hashable, CustomStringConvertible {
    /// Tailscale's WireGuard port. AgentLand never maps it: Tailscale maps it itself.
    public static let tailscalePort: UInt16 = 41641

    public let transport: MappedTransport
    public let internalPort: UInt16
    /// The external port asked for; the router may grant another one.
    public let externalPort: UInt16

    public init(_ transport: MappedTransport, internalPort: UInt16, externalPort: UInt16? = nil) throws {
        let external = externalPort ?? internalPort
        guard internalPort != 0, external != 0 else { throw PortMappingError.invalidRequest("A mapping needs a port.") }
        guard internalPort != Self.tailscalePort, external != Self.tailscalePort else {
            throw PortMappingError.invalidRequest("Port \(Self.tailscalePort) belongs to Tailscale.")
        }
        self.transport = transport
        self.internalPort = internalPort
        self.externalPort = external
    }

    public var description: String { "\(transport.rawValue.uppercased()) \(internalPort)" }
}

public enum PortMappingError: LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case invalidGateway(String)
    /// Nothing answered after every retransmission.
    case noResponse
    /// The router speaks neither PCP nor NAT-PMP in a way this client understands.
    case unsupportedVersion
    /// The router answered with a result code other than success.
    case refused(method: PortMapper.Method, code: UInt16)
    /// PCP's NOT_AUTHORIZED, with the lifetime the router gave the refusal: among other reasons, the
    /// router holds a mapping of this port made with another nonce (RFC 6887 §11.3).
    case notAuthorized(retryAfter: UInt32)
    case malformedResponse
    case socket(String)
    /// The mapping could not be recorded, so it was not requested.
    case records(String)
    /// Another mapper holds the records' lock: another copy of AgentLand, or in this app a mapper
    /// that was not stopped yet. Its mappings are left alone.
    case ownedElsewhere

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message): message
        case let .invalidGateway(address): "\(address) is not a router address this Mac can ask for a mapping."
        case .noResponse: "The router did not answer a port mapping request (PCP or NAT-PMP may be off)."
        case .unsupportedVersion: "The router does not support PCP or NAT-PMP."
        case let .refused(method, code): "The router refused the mapping: \(Self.describe(method: method, code: code))."
        case let .notAuthorized(retryAfter) where retryAfter > 0:
            "The router refused the mapping: not authorized. It may still hold a mapping of this port that an earlier run of AgentLand made; that one ends within \(Self.minutes(retryAfter))."
        case .notAuthorized: "The router refused the mapping: not authorized."
        case .malformedResponse: "The router's answer could not be read."
        case let .socket(message): "The port mapping request could not be sent: \(message)"
        case let .records(message): "The port mapping could not be recorded, so it was not requested: \(message)"
        case .ownedElsewhere: "Another copy of AgentLand is managing this Mac's router mappings. Quit it first."
        }
    }

    static func minutes(_ seconds: UInt32) -> String {
        let minutes = (Int(seconds) + 59) / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func describe(method: PortMapper.Method, code: UInt16) -> String {
        switch method {
        case .natPMP:
            switch code {
            case 1: return "unsupported version"
            case 2: return "not authorized or refused"
            case 3: return "network failure"
            case 4: return "out of resources"
            case 5: return "unsupported opcode"
            default: return "result code \(code)"
            }
        case .pcp:
            switch code {
            case 1: return "unsupported version"
            case 2: return "not authorized"
            case 3: return "malformed request"
            case 4: return "unsupported opcode"
            case 5: return "unsupported option"
            case 6: return "malformed option"
            case 7: return "network failure"
            case 8: return "no resources"
            case 9: return "unsupported protocol"
            case 10: return "user quota exceeded"
            case 11: return "cannot provide the external port"
            case 12: return "address mismatch"
            case 13: return "excessive remote peers"
            default: return "result code \(code)"
            }
        }
    }
}

/// An IPv4 address in network byte order.
public struct IPv4Address: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        self.bytes = bytes
    }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 4)
        self.bytes = bytes
    }

    public static let any = IPv4Address(bytes: [0, 0, 0, 0])

    public var description: String { bytes.map(String.init).joined(separator: ".") }

    public var isLoopback: Bool { bytes[0] == 127 }
    /// RFC 1918 private ranges, where a home router's LAN address lives.
    public var isPrivate: Bool {
        bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
    }

    /// `::ffff:a.b.c.d`, how PCP carries an IPv4 address.
    var mappedIPv6: [UInt8] { [UInt8](repeating: 0, count: 10) + [0xff, 0xff] + bytes }

    init?(mappedIPv6 raw: ArraySlice<UInt8>) {
        let value = Array(raw)
        guard value.count == 16, value[0..<10].allSatisfy({ $0 == 0 }), value[10] == 0xff, value[11] == 0xff else { return nil }
        self.init(bytes: Array(value[12..<16]))
    }
}

// MARK: - NAT-PMP (RFC 6886)

enum NATPMPWire {
    static let version: UInt8 = 0

    static func externalAddressRequest() -> [UInt8] { [version, 0] }

    /// A mapping request; lifetime 0 with external port 0 deletes the mapping (RFC 6886 §3.4).
    static func mapRequest(_ transport: MappedTransport, internalPort: UInt16, suggestedExternalPort: UInt16,
                           lifetime: UInt32) -> [UInt8] {
        [version, transport.natPMPOpcode, 0, 0] + bigEndian(internalPort) + bigEndian(suggestedExternalPort) + bigEndian(lifetime)
    }

    struct ExternalAddress: Equatable {
        let epoch: UInt32
        let address: IPv4Address
    }

    struct Mapping: Equatable {
        let epoch: UInt32
        let internalPort: UInt16
        let externalPort: UInt16
        let lifetime: UInt32
    }

    /// Nil when the datagram is not an answer to this request; throws for an answer that refuses.
    /// A PCP-only router answers this version-0 request in PCP's format, with UNSUPP_VERSION.
    static func parseExternalAddress(_ data: [UInt8]) throws -> ExternalAddress? {
        if data.count >= 4, data[0] == PCPWire.version, data[1] == 0x80, data[3] == 1 { throw PortMappingError.unsupportedVersion }
        guard data.count >= 4, data[0] == version, data[1] == 128 else { return nil }
        let code = readUInt16(data, 2)
        guard code == 0 else { throw code == 1 ? PortMappingError.unsupportedVersion : PortMappingError.refused(method: .natPMP, code: code) }
        guard data.count >= 12 else { throw PortMappingError.malformedResponse }
        return ExternalAddress(epoch: readUInt32(data, 4), address: IPv4Address(bytes: Array(data[8..<12])))
    }

    static func parseMap(_ data: [UInt8], transport: MappedTransport, internalPort: UInt16) throws -> Mapping? {
        guard data.count >= 4, data[0] == version, data[1] == 128 + transport.natPMPOpcode else { return nil }
        let code = readUInt16(data, 2)
        if code != 0 {
            // Error answers may stop after the epoch; they still name the opcode.
            if data.count >= 10, readUInt16(data, 8) != internalPort { return nil }
            throw code == 1 ? PortMappingError.unsupportedVersion : PortMappingError.refused(method: .natPMP, code: code)
        }
        guard data.count >= 16 else { throw PortMappingError.malformedResponse }
        guard readUInt16(data, 8) == internalPort else { return nil }
        return Mapping(epoch: readUInt32(data, 4), internalPort: internalPort,
                       externalPort: readUInt16(data, 10), lifetime: readUInt32(data, 12))
    }
}

// MARK: - PCP (RFC 6887)

enum PCPWire {
    static let version: UInt8 = 2
    static let announceOpcode: UInt8 = 0
    static let mapOpcode: UInt8 = 1
    static let headerLength = 24
    static let mapLength = 60

    static func header(opcode: UInt8, lifetime: UInt32, client: IPv4Address) -> [UInt8] {
        [version, opcode, 0, 0] + bigEndian(lifetime) + client.mappedIPv6
    }

    /// ANNOUNCE asks only for the server's epoch.
    static func announceRequest(client: IPv4Address) -> [UInt8] {
        header(opcode: announceOpcode, lifetime: 0, client: client)
    }

    /// A MAP request; lifetime 0 with the same nonce deletes the mapping (RFC 6887 §15).
    static func mapRequest(nonce: [UInt8], transport: MappedTransport, internalPort: UInt16, suggestedExternalPort: UInt16,
                           suggestedExternalAddress: IPv4Address, lifetime: UInt32, client: IPv4Address) -> [UInt8] {
        precondition(nonce.count == 12)
        return header(opcode: mapOpcode, lifetime: lifetime, client: client)
            + nonce + [transport.protocolNumber, 0, 0, 0]
            + bigEndian(internalPort) + bigEndian(suggestedExternalPort) + suggestedExternalAddress.mappedIPv6
    }

    struct Announce: Equatable { let epoch: UInt32 }

    struct Mapping: Equatable {
        let epoch: UInt32
        let lifetime: UInt32
        let externalPort: UInt16
        let externalAddress: IPv4Address?
    }

    /// A NAT-PMP-only router answers a PCP request with its own UNSUPP_VERSION (version 0, result 1).
    private static func natPMPVersionAnswer(_ data: [UInt8]) throws {
        if data.count >= 4, data[0] == NATPMPWire.version, data[1] >= 128 {
            throw readUInt16(data, 2) == 1 ? PortMappingError.unsupportedVersion : PortMappingError.malformedResponse
        }
    }

    static func parseAnnounce(_ data: [UInt8]) throws -> Announce? {
        try natPMPVersionAnswer(data)
        guard data.count >= headerLength, data[0] == version, data[1] == 0x80 | announceOpcode else { return nil }
        let code = UInt16(data[3])
        guard code == 0 else { throw code == 1 ? PortMappingError.unsupportedVersion : PortMappingError.refused(method: .pcp, code: code) }
        return Announce(epoch: readUInt32(data, 8))
    }

    static func parseMap(_ data: [UInt8], nonce: [UInt8], transport: MappedTransport, internalPort: UInt16) throws -> Mapping? {
        try natPMPVersionAnswer(data)
        guard data.count >= headerLength, data[0] == version, data[1] == 0x80 | mapOpcode else { return nil }
        let code = UInt16(data[3])
        if data.count >= mapLength {
            // Answers carry the request's nonce, protocol and internal port; others are not ours.
            guard Array(data[24..<36]) == nonce, data[36] == transport.protocolNumber,
                  readUInt16(data, 40) == internalPort else { return nil }
        } else if code == 0 {
            throw PortMappingError.malformedResponse
        }
        switch code {
        case 0: break
        case 1: throw PortMappingError.unsupportedVersion
        case 2: throw PortMappingError.notAuthorized(retryAfter: readUInt32(data, 4))
        default: throw PortMappingError.refused(method: .pcp, code: code)
        }
        return Mapping(epoch: readUInt32(data, 8), lifetime: readUInt32(data, 4), externalPort: readUInt16(data, 42),
                       externalAddress: IPv4Address(mappedIPv6: data[44..<60]))
    }
}

func bigEndian(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}
func readUInt16(_ data: [UInt8], _ offset: Int) -> UInt16 { UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
func readUInt32(_ data: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}
