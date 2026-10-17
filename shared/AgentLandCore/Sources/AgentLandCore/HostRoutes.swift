import Foundation

// Routes (docs/HOST-API.md, "Routes"): the ways a device reaches the host it paired with. The
// host lists them in `capabilities.routes`, QR invitations carry them, and the app keeps them with
// the saved host. Every route keeps the paired certificate fingerprint and validates the
// certificate for the paired host name; a route is a way in, never another identity.

/// One way to reach a paired host, as the host lists it.
public struct HostRoute: Codable, Hashable, Sendable {
    /// At most this many routes are kept for a host, each with at most `maximumAddresses`.
    public static let maximumRoutes = 8
    public static let maximumAddresses = 4
    public static let local = "local"
    public static let tailscale = "tailscale"

    /// "local", "tailscale", or a later kind this version keeps without naming it.
    public let kind: String
    /// A DNS name in lower case without a trailing dot, or an IP address without brackets.
    public let host: String
    /// IP addresses of the same route (Tailscale's), tried after `host`.
    public let addresses: [String]
    public let port: Int

    /// Nil unless every part is well formed; addresses that are not IP addresses are left out.
    public init?(kind: String, host: String, addresses: [String] = [], port: Int) {
        guard (1...16).contains(kind.utf8.count), kind.utf8.allSatisfy({ (97...122).contains($0) }),
              let host = HostEndpoint.normalizedHost(host), (1...65535).contains(port) else { return nil }
        var kept: [String] = []
        for address in addresses {
            guard let value = HostEndpoint.normalizedHost(address), HostEndpoint.isIPAddress(value), !kept.contains(value) else { continue }
            kept.append(value)
            if kept.count == Self.maximumAddresses { break }
        }
        self.kind = kind; self.host = host; self.addresses = kept; self.port = port
    }

    public var isTailscale: Bool { kind == Self.tailscale }

    /// Where this route can be reached: its host, then its addresses.
    public var endpoints: [HostEndpoint] {
        ([host] + addresses).compactMap { HostEndpoint(host: $0, port: port) }
    }

    enum CodingKeys: String, CodingKey { case kind, host, addresses, port }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let route = HostRoute(kind: try container.decode(String.self, forKey: .kind),
                                    host: try container.decode(String.self, forKey: .host),
                                    addresses: (try? container.decodeIfPresent([String].self, forKey: .addresses)) ?? [],
                                    port: try container.decode(Int.self, forKey: .port))
        else { throw DecodingError.dataCorruptedError(forKey: .host, in: container, debugDescription: "Not a usable route") }
        self = route
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(host, forKey: .host)
        if !addresses.isEmpty { try container.encode(addresses, forKey: .addresses) }
        try container.encode(port, forKey: .port)
    }

    /// Reads a list of routes, leaving out entries this version cannot read and keeping at most
    /// `maximumRoutes`; nil when the key is absent or is not a list.
    public static func decodeList<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> [HostRoute]? {
        guard container.contains(key), var list = try? container.nestedUnkeyedContainer(forKey: key) else { return nil }
        var routes: [HostRoute] = []
        while !list.isAtEnd && routes.count < maximumRoutes {
            if let route = try? list.decode(HostRoute.self) {
                routes.append(route)
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        return routes
    }

    /// What a device keeps after a successful connection: the routes the host lists now, then the
    /// kinds it kept before that the host did not list this time (a Tailscale route stays known while
    /// Tailscale is briefly off on the host). Every route is still checked with the paired pin.
    public static func merged(saved: [HostRoute], advertised: [HostRoute]) -> [HostRoute] {
        var result = Array(advertised.prefix(maximumRoutes))
        for route in saved where result.count < maximumRoutes && !result.contains(where: { $0.kind == route.kind }) {
            result.append(route)
        }
        return result
    }

    private struct Discarded: Decodable {}
}

/// One address to reach a host at: a DNS name or IP address, and a port, over HTTPS.
public struct HostEndpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    /// A DNS name in lower case without a trailing dot, or an IP address without brackets.
    public let host: String
    public let port: Int

    public init?(host: String, port: Int) {
        guard let host = Self.normalizedHost(host), (1...65535).contains(port) else { return nil }
        self.host = host; self.port = port
    }

    /// The address a host was paired at, without its path.
    public init?(address: ServerAddress) {
        guard let host = address.url.host(percentEncoded: false) else { return nil }
        self.init(host: host, port: address.url.port ?? 443)
    }

    public init(from decoder: Decoder) throws {
        struct Wire: Decodable { let host: String; let port: Int }
        let wire = try Wire(from: decoder)
        guard let endpoint = HostEndpoint(host: wire.host, port: wire.port) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a usable endpoint"))
        }
        self = endpoint
    }

    public var isIPAddress: Bool { Self.isIPAddress(host) }
    /// `host:port`, with an IPv6 address in brackets.
    public var authority: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
    public var description: String { authority }
    public var baseURL: URL { URL(string: "https://" + authority)! }

    /// A DNS name (letters, digits and hyphens in each label, lower case, no trailing dot) or an IP
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

    /// The addresses to try for a host paired at `primary`: `preferred` first (the last that worked,
    /// when it is still one of them), then the paired address, then each route's host and addresses.
    ///
    /// Last comes the short form of a paired `.local` name (`robins-mac-mini` for
    /// `robins-mac-mini.local`): with Tailscale on, its MagicDNS search domain resolves it to the
    /// Mac's Tailscale address, so a device paired before routes existed reaches the Mac away from home
    /// before it has learned them. Like every candidate it must present the paired certificate.
    public static func candidates(primary: HostEndpoint, routes: [HostRoute], preferred: HostEndpoint? = nil) -> [HostEndpoint] {
        var all = [primary]
        var more = routes.flatMap(\.endpoints)
        if primary.host.hasSuffix(".local"), let short = HostEndpoint(host: String(primary.host.dropLast(".local".count)), port: primary.port),
           !short.host.contains("."), !short.isIPAddress {
            more.append(short)
        }
        for endpoint in more where !all.contains(endpoint) { all.append(endpoint) }
        if let preferred, let index = all.firstIndex(of: preferred), index > 0 {
            all.remove(at: index)
            all.insert(preferred, at: 0)
        }
        return all
    }
}

/// Tries addresses of one host in order and keeps the first that answers.
public enum RouteRace {
    private enum Event: Sendable { case answer(Int, Bool), tick(Int), again(Int) }

    /// The first of `candidates` whose probe answers. The first starts at once and each next one
    /// `stagger` later, or at once when every probe in flight has failed. Probes still running when
    /// one answers are cancelled.
    ///
    /// Without `retryAfter` the race ends with nil once every candidate has failed. With it, a
    /// candidate that failed is probed again after its next delay (the last one repeats), so the race
    /// goes on until one answers or the calling task is cancelled: a hung candidate never holds up the
    /// others, and a host that comes back is found on the retry schedule. `failed` hears of each failed
    /// probe (by index) before the race goes on.
    public static func first<Candidate: Sendable>(_ candidates: [Candidate], stagger: Duration = .milliseconds(250),
                                                  retryAfter: [Duration]? = nil,
                                                  failed: (@Sendable (Int) async -> Void)? = nil,
                                                  probe: @escaping @Sendable (Candidate) async -> Bool) async -> Candidate? {
        let retries = retryAfter.flatMap { $0.isEmpty ? nil : $0 }
        return await first(candidates, stagger: stagger, retryDelay: { _, failures in
            retries.map { $0[min(failures - 1, $0.count - 1)] }
        }, failed: failed, probe: probe)
    }

    /// The same race with a schedule of its own for each candidate: after the `failures`-th failure of
    /// the candidate at `index`, `retryDelay` gives the delay before it is probed again, or nil when it
    /// is not tried again in this race (the remote-access tunnel after a refusal, or with nothing to
    /// dial). The race ends with nil once every candidate has started and none is in flight or waiting
    /// to be tried again.
    public static func first<Candidate: Sendable>(_ candidates: [Candidate], stagger: Duration = .milliseconds(250),
                                                  retryDelay: @escaping @Sendable (_ index: Int, _ failures: Int) async -> Duration?,
                                                  failed: (@Sendable (Int) async -> Void)? = nil,
                                                  probe: @escaping @Sendable (Candidate) async -> Bool) async -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: Event.self) { group in
            var next = 0, inFlight = 0, tick = 0, waiting = 0
            var attempts = Array(repeating: 0, count: candidates.count)
            func launch(_ index: Int, _ group: inout TaskGroup<Event>) {
                inFlight += 1
                group.addTask { .answer(index, await probe(candidates[index])) }
            }
            func start(_ group: inout TaskGroup<Event>) {
                let index = next
                next += 1
                launch(index, &group)
                if next < candidates.count {
                    tick += 1
                    let id = tick
                    group.addTask {
                        try? await Task.sleep(for: stagger)
                        return .tick(id)
                    }
                }
            }
            start(&group)
            while let event = await group.next() {
                switch event {
                case let .answer(index, answered):
                    inFlight -= 1
                    if answered {
                        group.cancelAll()
                        return candidates[index]
                    }
                    guard !Task.isCancelled else { continue }
                    await failed?(index)
                    attempts[index] += 1
                    if let delay = await retryDelay(index, attempts[index]) {
                        waiting += 1
                        group.addTask {
                            try? await Task.sleep(for: delay)
                            return .again(index)
                        }
                    }
                    if inFlight == 0 {
                        if next < candidates.count {
                            start(&group)
                        } else if waiting == 0 {
                            group.cancelAll()
                            return nil
                        }
                    }
                case let .tick(id):
                    if id == tick, next < candidates.count, !Task.isCancelled { start(&group) }
                case let .again(index):
                    waiting -= 1
                    if !Task.isCancelled { launch(index, &group) }
                }
            }
            return nil
        }
    }
}

/// The transport of one paired host that can reach it over several routes. Every request goes where
/// the app's connection logic chose (`use(_:)` for an address, `useTunnel()` for the remote-access
/// tunnel); each endpoint has its own pinned session that checks the paired fingerprint and validates
/// the certificate for the paired host name, the way the Mac reaches its own host over loopback. Only a
/// host paired with a fingerprint and at an address without a path routes; the others keep
/// `URLSessionTransport`.
///
/// The tunnel's requests keep the paired address: they go through the phone's bridge, an HTTP CONNECT
/// proxy on loopback, which the session of each bridge start is configured with (`attachTunnel(_:)`),
/// and their TLS is checked as at the paired address (docs/HOST-API.md "The phone's bridge").
///
/// A read (GET) that failed on its connection after the app moved to another route is sent once more
/// there; nothing else is ever sent again, so a send stays uncertain exactly as before.
public final class RoutedTransport: APITransport, @unchecked Sendable {
    /// Makes the transport of one endpoint; tests pass their own.
    public typealias EndpointTransports = @Sendable (_ endpoint: HostEndpoint, _ trust: PinnedTrustEvaluator) -> any APITransport
    /// Makes the tunnel's transport for one start of the phone's bridge; tests pass their own.
    public typealias TunnelTransports = @Sendable (_ bridge: RemoteAccessBridgeAddress, _ trust: PinnedTrustEvaluator) -> any APITransport

    /// The endpoint the host was paired at.
    public let primary: HostEndpoint
    private let pairedBase: String
    private let pairedName: String
    private let fingerprint: String
    private let makeTransport: EndpointTransports
    private let makeTunnelTransport: TunnelTransports
    private let lock = NSLock()
    private var current: RouteCandidate
    private var lastAddress: HostEndpoint
    private var sessions: [HostEndpoint: any APITransport] = [:]
    private var tunnel: (bridge: RemoteAccessBridgeAddress, transport: any APITransport)?

    /// Nil for a host paired without a fingerprint or at an address with a path. `endpoint` is where
    /// requests go first (the paired address when nil). `transports` and `tunnelTransports` are for
    /// tests; by default each endpoint gets a `URLSessionTransport` pinned as `serverTrust(for:)`
    /// describes, and each bridge start one through that bridge, pinned as `tunnelTrust` describes.
    public init?(address: ServerAddress, certificateSHA256: String?, endpoint: HostEndpoint? = nil,
                 transports: EndpointTransports? = nil, tunnelTransports: TunnelTransports? = nil) {
        let pin = certificateSHA256?.lowercased().filter(\.isHexDigit) ?? ""
        guard pin.count == 64, address.url.path.isEmpty || address.url.path == "/",
              let primary = HostEndpoint(address: address), let name = address.url.host(percentEncoded: false)
        else { return nil }
        self.primary = primary
        pairedBase = address.url.absoluteString.hasSuffix("/") ? String(address.url.absoluteString.dropLast()) : address.url.absoluteString
        pairedName = name
        fingerprint = pin
        makeTransport = transports ?? { endpoint, trust in
            URLSessionTransport(expectedHost: endpoint.host, certificateSHA256: pin, validatedCertificateHost: name)
        }
        let pairedHost = primary.host
        makeTunnelTransport = tunnelTransports ?? { bridge, _ in
            URLSessionTransport(expectedHost: pairedHost, certificateSHA256: pin, validatedCertificateHost: name, bridge: bridge)
        }
        lastAddress = endpoint ?? primary
        current = .address(lastAddress)
    }

    /// Where requests go now: an address, or the tunnel.
    public var route: RouteCandidate { lock.withLock { current } }

    /// The address requests go to, or while the tunnel carries them, the address that carried them
    /// before (the one a race tries first).
    public var endpoint: HostEndpoint { lock.withLock { lastAddress } }

    /// Sends every later request to `endpoint`. Requests already sent finish where they went.
    public func use(_ endpoint: HostEndpoint) {
        lock.withLock {
            current = .address(endpoint)
            lastAddress = endpoint
        }
    }

    /// The certificate check at one endpoint: the challenge must come from `endpoint.host`, and the
    /// certificate must have the paired fingerprint and be valid for the name the host was paired at.
    public func serverTrust(for endpoint: HostEndpoint) -> PinnedTrustEvaluator {
        PinnedTrustEvaluator(expectedHost: endpoint.host, certificateSHA256: fingerprint, validatedCertificateHost: pairedName)
    }

    /// The certificate check through the tunnel: requests name the paired address, so the challenge
    /// comes from the paired host, with the paired fingerprint, validated for the paired name.
    public var tunnelTrust: PinnedTrustEvaluator { serverTrust(for: primary) }

    /// The transport of one endpoint, made once.
    public func transport(for endpoint: HostEndpoint) -> any APITransport {
        let trust = serverTrust(for: endpoint)
        return lock.withLock {
            if let existing = sessions[endpoint] { return existing }
            let made = makeTransport(endpoint, trust)
            sessions[endpoint] = made
            return made
        }
    }

    // MARK: The tunnel

    /// The bridge the tunnel's requests go through now, if any.
    public var tunnelBridge: RemoteAccessBridgeAddress? { lock.withLock { tunnel?.bridge } }

    /// Makes the tunnel's transport for a new start of the phone's bridge (a new port and secret), in
    /// place of the one before. Requests go through it once `useTunnel()` is called.
    @discardableResult
    public func attachTunnel(_ bridge: RemoteAccessBridgeAddress) -> any APITransport {
        let trust = tunnelTrust
        return lock.withLock {
            if let tunnel, tunnel.bridge == bridge { return tunnel.transport }
            let made = makeTunnelTransport(bridge, trust)
            tunnel = (bridge, made)
            return made
        }
    }

    /// Sends every later request through the tunnel's current bridge.
    public func useTunnel() { lock.withLock { current = .tunnel } }

    /// Lets go of the bridge's transport (the tunnel was closed). Requests still routed to the tunnel
    /// fail as never sent until the app chooses a route again.
    public func detachTunnel() { lock.withLock { tunnel = nil } }

    /// Whether the host answers `GET /v1/health` within `timeout` through the tunnel's current bridge.
    public func probeTunnel(timeout: TimeInterval) async -> Bool {
        guard let transport = lock.withLock({ tunnel?.transport }) else { return false }
        return await Self.health(primary.baseURL, over: transport, timeout: timeout)
    }

    // MARK: Requests

    /// Whether the host answers `GET /v1/health` at `endpoint` within `timeout`, through the pinned
    /// session: an answer there comes from the paired host.
    public func probe(_ endpoint: HostEndpoint, timeout: TimeInterval) async -> Bool {
        await Self.health(endpoint.baseURL, over: transport(for: endpoint), timeout: timeout)
    }

    private static func health(_ base: URL, over transport: any APITransport, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: base.appending(path: "/v1/health"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        guard let (data, response) = try? await transport.execute(request), response.statusCode == 200,
              let health = try? JSONDecoder().decode(HealthResponse.self, from: data) else { return false }
        return health.status == "ok"
    }

    /// `request` addressed to `endpoint`: the paired address's scheme and authority are replaced; the
    /// path and query stay. A request for another origin is left as it is.
    func request(_ request: URLRequest, to endpoint: HostEndpoint) -> URLRequest {
        guard endpoint != primary, let url = request.url?.absoluteString, url.hasPrefix(pairedBase),
              let routed = URL(string: "https://" + endpoint.authority + url.dropFirst(pairedBase.count)) else { return request }
        var copy = request
        copy.url = routed
        return copy
    }

    /// The route, its transport and the request as it goes there. Through the tunnel the request keeps
    /// the paired address; with no bridge attached it fails as never sent.
    private func prepare(_ original: URLRequest, route: RouteCandidate? = nil) -> (RouteCandidate, any APITransport, URLRequest) {
        let route = route ?? self.route
        switch route {
        case let .address(endpoint):
            return (route, transport(for: endpoint), request(original, to: endpoint))
        case .tunnel:
            let transport: any APITransport = lock.withLock { tunnel?.transport } ?? NoTunnelTransport()
            return (route, transport, original)
        }
    }

    /// A read that failed on its connection while the app moved to another route goes once more to the
    /// new one. Sends and cancellations never do.
    private func retry(_ original: URLRequest, sentOn route: RouteCandidate, after error: Error) -> (any APITransport, URLRequest)? {
        guard (original.httpMethod ?? "GET") == "GET", !(error is CancellationError),
              ClientError.isConnectionFailure(error) else { return nil }
        let now = self.route
        guard now != route else { return nil }
        let (_, transport, request) = prepare(original, route: now)
        return (transport, request)
    }

    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (route, transport, routed) = prepare(request)
        do {
            return try await transport.execute(routed)
        } catch {
            guard let (again, retried) = retry(request, sentOn: route, after: error) else { throw error }
            return try await again.execute(retried)
        }
    }

    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        try await lines(request, maxLineBytes: 16 << 10)
    }

    public func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (route, transport, routed) = prepare(request)
        do {
            return try await transport.lines(routed, maxLineBytes: maxLineBytes)
        } catch {
            guard let (again, retried) = retry(request, sentOn: route, after: error) else { throw error }
            return try await again.lines(retried, maxLineBytes: maxLineBytes)
        }
    }

    public func upload(_ request: URLRequest, fromFile file: URL,
                       progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let (_, transport, routed) = prepare(request)
        return try await transport.upload(routed, fromFile: file, progress: progress)
    }
}

/// The tunnel with no bridge: nothing is sent.
private struct NoTunnelTransport: APITransport {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ClientError.unreachable }
    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) { throw ClientError.unreachable }
    func upload(_ request: URLRequest, fromFile file: URL,
                progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        throw ClientError.unreachable
    }
}

extension APIClient {
    /// The routes of this client's host, when its transport can use more than one.
    public var routing: RoutedTransport? { transport as? RoutedTransport }
}
