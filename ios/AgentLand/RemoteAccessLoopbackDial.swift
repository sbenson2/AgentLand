#if DEBUG
import Darwin
import Foundation
import AgentLandCore

/// Debug builds only, for the simulator UI test `testConnectsThroughIrohTunnel`
/// (integration/check-ios-product.py): the Mac side runs on this Mac's loopback, which a report can
/// never carry (direct addresses are global unicast, docs/HOST-API.md "Endpoint report"). The harness
/// reports a global stand-in address and launches the app with
/// `AGENTLAND_UITEST_TUNNEL_LOOPBACK=<reported ip:port>=127.0.0.1:<port>` (pairs separated by commas).
/// The phone's tunnel then dials the loopback port in place of the reported address; it drops every
/// address the list does not name and every relay, so nothing is dialed off this Mac.
///
/// The endpoint runs only in a process the router-ports profile covers (the harness inserts
/// `integration/RouterPortsSandbox` into the app): with the list set and UDP to 1900, 5350 or 5351 not
/// refused with EPERM, there is no tunnel at all.
struct RemoteAccessLoopbackDial: Sendable {
    static let environmentKey = "AGENTLAND_UITEST_TUNNEL_LOOPBACK"

    /// Reported address → loopback address.
    let map: [String: String]

    /// Nil without the variable; an empty map (nothing dialed) when it names anything but loopback targets.
    init?(environment: [String: String]) {
        guard let value = environment[Self.environmentKey] else { return nil }
        var map: [String: String] = [:]
        for pair in value.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, RemoteAccessDirectAddress.isDialable(parts[0]), Self.isLoopback(parts[1]) else {
                map = [:]
                break
            }
            map[parts[0]] = parts[1]
        }
        self.map = map
    }

    /// `127.0.0.1:<port>` or `[::1]:<port>`.
    static func isLoopback(_ address: String) -> Bool {
        for prefix in ["127.0.0.1:", "[::1]:"] where address.hasPrefix(prefix) {
            if let port = UInt16(address.dropFirst(prefix.count)), port > 0 { return true }
        }
        return false
    }

    /// The route with its addresses on loopback and without a relay; `.none` when nothing is left.
    func translate(_ route: RemoteAccessTunnelRoute) -> RemoteAccessTunnelRoute {
        guard case let .dial(nodeID, addresses, _) = route else { return route }
        let loopback = addresses.compactMap { map[$0] }
        return loopback.isEmpty ? .none : .dial(nodeID: nodeID, directAddresses: loopback, relayURL: nil)
    }

    /// The tunnel `inner` makes, dialing only loopback; nil (no tunnel) unless the process is under the
    /// router-ports profile.
    func wrap(_ inner: any RemoteAccessTunnelConnecting) -> (any RemoteAccessTunnelConnecting)? {
        guard !map.isEmpty, Self.routerPortsRefused() else { return nil }
        return LoopbackDialTunnel(inner: inner, dial: self)
    }

    /// Whether a one-byte UDP datagram to 127.0.0.1 on each router port is refused with EPERM.
    static func routerPortsRefused() -> Bool {
        [UInt16(1900), 5350, 5351].allSatisfy { port in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            let sent = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, "x", 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return sent < 0 && errno == EPERM
        }
    }
}

/// The phone's tunnel with its routes moved to loopback.
private final class LoopbackDialTunnel: RemoteAccessTunnelConnecting {
    let inner: any RemoteAccessTunnelConnecting
    let dial: RemoteAccessLoopbackDial

    init(inner: any RemoteAccessTunnelConnecting, dial: RemoteAccessLoopbackDial) {
        self.inner = inner
        self.dial = dial
    }

    func open(_ route: RemoteAccessTunnelRoute, target: HostEndpoint, timeout: Duration) async
        -> Result<RemoteAccessBridgeAddress, RemoteAccessTunnelFailure> {
        let translated = dial.translate(route)
        guard case .dial = translated else { return .failure(.noAnswer) }
        return await inner.open(translated, target: target, timeout: timeout)
    }

    func failure() async -> RemoteAccessTunnelFailure? { await inner.failure() }
    func close() async { await inner.close() }
}
#endif
