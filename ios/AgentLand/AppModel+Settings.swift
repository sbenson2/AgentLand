import Foundation
import AgentLandCore

/// What Settings says about the selected host's connection: one honest status and one name for the route in use
/// (never the pairing's `ConnectionMode` beside a route that contradicts it).
extension AppModel {
    /// Where requests go now: the route the race chose, or, for a host known at one address only, that address.
    var routeInUse: RouteCandidate? {
        if let activeRoute { return activeRoute }
        guard let host = selectedHost, let address = try? ServerAddress(validating: host.address) else { return nil }
        return HostEndpoint(address: address).map(RouteCandidate.address)
    }

    /// The connection in a word or two: "Connected", "Connecting…", "Offline" and why.
    var connectionStateName: String {
        switch connection {
        case .checking: "Connecting…"
        case .online: "Connected"
        case .offline(.noNetwork): "No network"
        case .offline(.hostStopped): "Mac app stopped"
        case .offline(.unreachable): tunnelState == .reconnecting ? "Reconnecting…" : "Offline"
        case .offline(.notPaired): "Needs pairing again"
        }
    }

    /// The status line under the host's name at the top of Settings: the state, and the route while it carries the
    /// connection ("Connected · Local network").
    var connectionSummary: String {
        guard let host = selectedHost else { return connectionStateName }
        guard hostReachable, let route = routeInUse else { return connectionStateName }
        return connectionStateName + " · " + Self.routeName(of: route, host: host)
    }

    /// The route's name: the kind of the route the address belongs to ("Local network", "Tailscale"), "Remote access
    /// (iroh)" through the tunnel, and for an address no route lists, what its name says, else "Paired address".
    static func routeName(of route: RouteCandidate, host: SavedHost) -> String {
        switch route {
        case .tunnel:
            return "Remote access (iroh)"
        case let .address(endpoint):
            if let known = host.routes.first(where: { $0.endpoints.contains(endpoint) }) { return routeTitle(known.kind) }
            if endpoint.host.hasSuffix(".local") { return routeTitle(HostRoute.local) }
            if endpoint.host.hasSuffix(".ts.net") || isTailscaleAddress(endpoint.host) { return routeTitle(HostRoute.tailscale) }
            return "Paired address"
        }
    }

    static func routeTitle(_ kind: String) -> String {
        switch kind {
        case HostRoute.local: "Local network"
        case HostRoute.tailscale: "Tailscale"
        default: kind.capitalized
        }
    }

    /// Tailscale's addresses: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func isTailscaleAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, host.split(separator: ".").count == 4 { return octets[0] == 100 && (64...127).contains(octets[1]) }
        return host.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }
}
