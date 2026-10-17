import Foundation
import Darwin

/// The router of this Mac's own network: the IPv4 default route's gateway, read from the routing
/// table (it sends nothing). Only an unscoped default route through a private (RFC 1918) address
/// counts, so a VPN's or another interface's scoped route is never taken for the home router.
public enum DefaultGateway {
    public static func ipv4() -> IPv4Address? {
        routingMessages(flags: RTF_GATEWAY).flatMap(defaultRoute(inRoutingMessages:))
    }

    /// The link-layer (MAC) address this Mac's ARP table holds for `address` (the router, once
    /// something has been sent to it), as six lowercase hexadecimal pairs joined by colons; nil when
    /// the table has no complete entry for it. It reads the table (`arp -a` reads the same) and
    /// sends nothing.
    public static func hardwareAddress(of address: IPv4Address) -> String? {
        routingMessages(flags: RTF_LLINFO).flatMap { hardwareAddress(of: address, inRoutingMessages: $0) }
    }

    /// A `NET_RT_FLAGS` dump of the IPv4 routes with `flags`.
    private static func routingMessages(flags: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            size += 512 // routes can appear between the two calls
            var buffer = [UInt8](repeating: 0, count: size)
            let read = buffer.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
            if read == 0 { return Array(buffer.prefix(size)) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    /// Parses a `NET_RT_FLAGS` dump: routing messages, each followed by the socket addresses its
    /// `rtm_addrs` bits name, every one padded to four bytes.
    static func defaultRoute(inRoutingMessages data: [UInt8]) -> IPv4Address? {
        for (header, addresses) in routes(inRoutingMessages: data) {
            guard header.rtm_flags & RTF_GATEWAY != 0, header.rtm_flags & Int32(RTF_IFSCOPE) == 0 else { continue }
            guard let destination = addresses[RTA_DST], isIPv4(destination), ipv4(destination) == .any,
                  let gateway = addresses[RTA_GATEWAY], isIPv4(gateway), let address = ipv4(gateway), address.isPrivate else { continue }
            // A default route's netmask is empty or all zeros.
            if let mask = addresses[RTA_NETMASK], mask.count > 4, mask[4...].contains(where: { $0 != 0 }) { continue }
            return address
        }
        return nil
    }

    /// Parses an `RTF_LLINFO` dump (the ARP table): each entry's destination is the IPv4 address and
    /// its gateway a link-layer socket address (`sockaddr_dl`), whose address follows the interface
    /// name. An incomplete entry has no address.
    static func hardwareAddress(of address: IPv4Address, inRoutingMessages data: [UInt8]) -> String? {
        for (_, addresses) in routes(inRoutingMessages: data) {
            guard let destination = addresses[RTA_DST], isIPv4(destination), ipv4(destination) == address,
                  let link = addresses[RTA_GATEWAY], link.count >= 8, link[1] == UInt8(AF_LINK) else { continue }
            let nameLength = Int(link[5]), addressLength = Int(link[6])
            guard addressLength == 6, 8 + nameLength + addressLength <= link.count else { continue }
            let bytes = link[(8 + nameLength)..<(8 + nameLength + addressLength)]
            guard bytes.contains(where: { $0 != 0 }) else { continue }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }

    /// Each routing message's header and the socket addresses that follow it, by `RTA_` bit.
    private static func routes(inRoutingMessages data: [UInt8]) -> [(rt_msghdr, [Int32: [UInt8]])] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var routes: [(rt_msghdr, [Int32: [UInt8]])] = []
        var offset = 0
        while offset + headerSize <= data.count {
            let header = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= data.count else { break }
            var addresses: [Int32: [UInt8]] = [:]
            var cursor = offset + headerSize
            // Addresses follow in bit order; RTA_DST, RTA_GATEWAY and RTA_NETMASK are the lowest three.
            for bit in [RTA_DST, RTA_GATEWAY, RTA_NETMASK] where header.rtm_addrs & bit != 0 {
                guard cursor < offset + length else { break }
                let socketLength = Int(data[cursor])
                let padded = socketLength == 0 ? 4 : (socketLength + 3) & ~3
                guard cursor + max(socketLength, 1) <= offset + length else { break }
                addresses[bit] = Array(data[cursor..<min(cursor + max(socketLength, 2), offset + length)])
                cursor += padded
            }
            routes.append((header, addresses))
            offset += length
        }
        return routes
    }

    private static func isIPv4(_ socketAddress: [UInt8]) -> Bool {
        socketAddress.count >= 8 && socketAddress[1] == UInt8(AF_INET)
    }

    private static func ipv4(_ socketAddress: [UInt8]) -> IPv4Address? {
        guard socketAddress.count >= 8 else { return nil }
        return IPv4Address(bytes: Array(socketAddress[4..<8]))
    }
}
