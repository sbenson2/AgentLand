import Darwin
import Foundation

/// A PCP server on 127.0.0.1 with an ephemeral port, standing in for the router: `PortMapper` sends its
/// ANNOUNCE and MAP requests here (never to UDP 5351, never off this Mac) and every MAP is granted
/// with the external address given at start, the suggested port and the lifetime asked for. A delete
/// (lifetime 0) is answered as done. Nothing else is spoken: NAT-PMP requests go unanswered.
final class LoopbackRouter: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let external: [UInt8]
    private let started = Date()
    private let lock = NSLock()
    private var stopped = false
    private var granted: [UInt16: UInt32] = [:]

    /// `externalAddress` is an IPv4 address in dotted form.
    init(externalAddress: String) throws {
        var parsed = in_addr()
        guard inet_pton(AF_INET, externalAddress, &parsed) == 1 else { throw POSIXError(.EINVAL) }
        external = withUnsafeBytes(of: parsed.s_addr) { Array($0) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRINUSE) }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let thread = Thread { [self] in serve() }
        thread.name = "LoopbackRouter"
        thread.start()
    }

    /// The internal UDP ports mapped now, with the lifetime granted.
    var mappings: [UInt16: UInt32] { lock.withLock { granted } }

    func stop() { lock.withLock { stopped = true } }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 1100)
        while !lock.withLock({ stopped }) {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &sourceLength) }
                }
            }
            guard count > 0, let answer = answer(to: Array(buffer.prefix(count))) else { continue }
            _ = answer.withUnsafeBytes { bytes in
                withUnsafePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, sourceLength) }
                }
            }
        }
        close(descriptor)
    }

    /// RFC 6887: a 24-byte header (version 2, opcode, lifetime, client address) and, for MAP, the nonce,
    /// protocol, internal port, suggested external port and address.
    private func answer(to request: [UInt8]) -> [UInt8]? {
        guard request.count >= 24, request[0] == 2 else { return nil }
        let opcode = request[1] & 0x7f
        let lifetime = UInt32(request[4]) << 24 | UInt32(request[5]) << 16 | UInt32(request[6]) << 8 | UInt32(request[7])
        let epoch = UInt32(max(0, Date().timeIntervalSince(started))) + 1000
        func header(_ opcode: UInt8, lifetime: UInt32) -> [UInt8] {
            [2, 0x80 | opcode, 0, 0] + Self.bytes(lifetime) + Self.bytes(epoch) + [UInt8](repeating: 0, count: 12)
        }
        switch opcode {
        case 0:
            return header(0, lifetime: 0)
        case 1 where request.count >= 60 && request[36] == 17:
            let internalPort = UInt16(request[40]) << 8 | UInt16(request[41])
            let suggested = UInt16(request[42]) << 8 | UInt16(request[43])
            let externalPort = suggested == 0 ? internalPort : suggested
            lock.withLock {
                if lifetime == 0 { granted[internalPort] = nil } else { granted[internalPort] = lifetime }
            }
            return header(1, lifetime: lifetime) + Array(request[24..<36]) + [17, 0, 0, 0]
                + Self.bytes(internalPort) + Self.bytes(externalPort)
                + [UInt8](repeating: 0, count: 10) + [0xff, 0xff] + external
        default:
            return nil
        }
    }

    private static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}
