import Foundation
import Security

// The phone's side of remote access (docs/HOST-API.md "Remote access (iroh)", "The two apps": the
// phone's endpoint, its bridge, its routes and the refusals). These are the rules the iPhone and iPad
// app follows around the tunnel; the tunnel itself (the iroh endpoint and the loopback bridge) lives in
// AgentLandRemoteAccess, behind `RemoteAccessTunnelConnecting`, so the app's route logic is tested with
// fakes and never binds an endpoint.

/// One way to the host in the route race: an address of "Routes", or the remote-access tunnel, a
/// candidate of its own kind that is never an address, never saved as `lastEndpoint` and one route
/// whatever port the bridge has.
public enum RouteCandidate: Hashable, Sendable, CustomStringConvertible {
    case address(HostEndpoint)
    case tunnel

    public var address: HostEndpoint? {
        if case let .address(endpoint) = self { endpoint } else { nil }
    }

    public var description: String {
        switch self {
        case let .address(endpoint): endpoint.authority
        case .tunnel: "tunnel"
        }
    }
}

/// Where the phone's bridge listens for one start: 127.0.0.1 at `port`, taking only connections that
/// show `secret` (32 random bytes, base64url without padding, in memory only).
public struct RemoteAccessBridgeAddress: Hashable, Sendable {
    public let port: UInt16
    public let secret: String

    public init(port: UInt16, secret: String) {
        self.port = port; self.secret = secret
    }
}

extension RemoteAccessTunnel.Bridge {
    /// The user name of the bridge's credential (`ProxyConfiguration.applyCredential`).
    public static let username = "agentland"
    /// The longest chunk a bridge copies at once, either way.
    public static let chunkBytes = 64 << 10

    /// A new per-start secret: 32 random bytes, base64url without padding.
    public static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes for the bridge's secret")
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Why the tunnel did not carry a request, as the phone tells it apart ("Refusals").
public enum RemoteAccessTunnelFailure: Error, Hashable, Sendable {
    /// The Mac's gate closed the connection with 403, or a request answered 403
    /// `tunnel_device_mismatch`: the Mac does not admit this device's node ID for this saved host. The
    /// phone stops dialing the tunnel for it until it connects at home or over Tailscale (and registers
    /// there when the host does not have its node ID).
    case notAdmitted
    /// A stream was reset with code 2: the host refused the connection (it is not running, a limit, or it
    /// is stopping). Tried again on the tunnel's schedule.
    case hostRefused
    /// The gate closed the connection with 503: the Mac app is starting or stopping. Tried again on the
    /// tunnel's schedule.
    case unavailable
    /// The dial failed or nothing answered in time (also a refusal before the handshake, from the gate's
    /// limits). Tried again on the tunnel's schedule.
    case noAnswer

    /// The failure an iroh connection's close reason names: the gate's 403 or 503, nothing otherwise.
    public init?(closeReason: String) {
        switch RemoteAccessTunnel.ConnectionCode(closeReason: closeReason) {
        case .notAdmitted?: self = .notAdmitted
        case .unavailable?: self = .unavailable
        case nil: return nil
        }
    }

    /// The phone stops dialing the tunnel for the saved host.
    public var stopsDialing: Bool { self == .notAdmitted }
}

/// When the phone dials the tunnel again after it failed: after 2, 4, 8, 16 and 32 s and then every
/// 60 s, each with up to a quarter more at random, not on the addresses' schedule. A network path
/// change, a return to the foreground or an answer starts it over.
public struct RemoteAccessTunnelBackoff: Hashable, Sendable {
    public static let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60)]
    /// The share of a delay that may be added at random.
    public static let jitter = 0.25

    /// Failures since the schedule last started over.
    public private(set) var failures = 0

    public init() {}

    /// The delay before the next dial after one more failure. `random` is in 0..<1 (tests pass their own).
    public mutating func failed(random: Double = Double.random(in: 0..<1)) -> Duration {
        let base = Self.delays[min(failures, Self.delays.count - 1)]
        failures += 1
        return base + base * (Self.jitter * min(max(random, 0), 1))
    }

    public mutating func reset() { failures = 0 }
}

/// When the phone fetches the Mac's address record: once every address of a race has failed, at most
/// once per race and at most every 30 s ("When the Mac's address changes", Reading it).
public struct RemoteAccessRecordSchedule: Sendable {
    public static let minimumInterval: Duration = .seconds(30)
    private var lastFetch: ContinuousClock.Instant?
    private var lastRace: UUID?

    public init() {}

    /// Whether race `race` may fetch the record now; a yes counts as the fetch.
    public mutating func mayFetch(race: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        guard lastRace != race else { return false }
        if let lastFetch, now - lastFetch < Self.minimumInterval { return false }
        lastFetch = now
        lastRace = race
        return true
    }
}

extension RemoteAccessCapabilities {
    /// What a device keeps after reading capabilities ("What a device keeps"): the entry the host
    /// lists, which is the host's kept report (so `enabled: false` is the owner's word), and the entry
    /// it kept before when the host lists none (a host without the tunnel socket, a read that failed).
    public static func kept(saved: RemoteAccessCapabilities?, listed: RemoteAccessCapabilities?) -> RemoteAccessCapabilities? {
        listed ?? saved
    }
}

/// The phone's tunnel: its iroh endpoint, one connection to the Mac and the loopback bridge
/// (AgentLandRemoteAccess's `IrohPhoneTunnel`; tests pass fakes). It runs only while the phone tries or
/// uses the tunnel in the foreground.
public protocol RemoteAccessTunnelConnecting: AnyObject, Sendable {
    /// Starts the endpoint with the route's relays (again when they differ from the running
    /// endpoint's, `needsEndpointRestart(runningWith:)`), dials the route's node ID within `timeout`
    /// and starts a new bridge whose streams carry connections to `target` (the paired address, which
    /// `CONNECT` names). A connection and bridge from before are closed first.
    func open(_ route: RemoteAccessTunnelRoute, target: HostEndpoint, timeout: Duration) async
        -> Result<RemoteAccessBridgeAddress, RemoteAccessTunnelFailure>
    /// Why the connection behind the current bridge stopped carrying requests, once the phone can tell:
    /// the gate's close code, or a stream the host refused (code 2). Nil while nothing says why.
    func failure() async -> RemoteAccessTunnelFailure?
    /// Closes the bridge, the connection and the endpoint (the app went to the background, or an address
    /// answered). A dial still in flight is dropped when it ends.
    func close() async
}
