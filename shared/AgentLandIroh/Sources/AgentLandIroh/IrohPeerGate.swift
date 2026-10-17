import Darwin
import Foundation
@_exported import IrohLib
import Synchronization

/// Accepts an endpoint's incoming connections only from known endpoint IDs.
///
/// iroh completes the QUIC handshake with any key, so a peer's endpoint ID is
/// known only once its connection is established. The gate checks
/// `Connection.remoteId()` against its list and closes every other connection
/// with `refusedCode` before anyone else sees it: nothing is read from a
/// refused connection and no stream is accepted on it. This holds on a direct
/// path and through a relay alike, so a peer that is not admitted always
/// learns it from the code, never from a dial that fails.
///
/// A gate made without a list (`init(endpoint:)`) cannot tell a paired peer
/// from another until `setAllowed` gives it the first one. Until then it
/// closes every connection it completes with `unavailableCode`, which asks the
/// peer to try again, never with `refusedCode`.
///
/// Before a handshake starts:
/// - The peer proves its address with a QUIC retry, so a packet from a spoofed
///   source never gets further.
/// - Handshakes in progress are limited per source (`maxPendingHandshakesPerSource`):
///   a source is an IPv4 address; a global unicast IPv6 /64, or any other IPv6
///   address on its own (unique local ones, such as each Tailscale node's, and
///   link-local ones; see `HandshakeSource`); or for a relayed connection the
///   sender the relay names.
/// - Direct connections also share `maxPendingHandshakes` slots. Relayed
///   connections from senders that are not listed (all of them while the gate
///   has no list) share `maxPendingUnlistedRelayedHandshakes` slots of their
///   own; relayed connections from listed senders use neither. Above a limit
///   the connection is refused (a QUIC refusal without an application code,
///   which the peer sees as a dial that fails).
///
/// A handshake that has not completed within `handshakeTimeout` is dropped in
/// iroh (`Accepting.connectWithTimeout`), which frees its slots. So one internet
/// host holds at most `maxPendingHandshakesPerSource` slots, each for at most
/// `handshakeTimeout`, and cannot fill the shared slots on its own.
///
/// What is left:
/// - Hosts at `maxPendingHandshakes / maxPendingHandshakesPerSource` or more
///   sources (32 with the defaults: many IPv4 addresses, many global IPv6 /64s,
///   which one IPv6 network of /56 or /48 has, or one host on the Mac's own
///   network or overlay that holds many unique local or link-local addresses)
///   that keep starting handshakes and never finish them can keep the shared
///   slots full. While they do, direct connections from paired devices are
///   refused; a paired device still gets in through a relay (dial the relay URL
///   without direct addresses).
/// - Devices behind one source share its slots: one public IPv4 address (a
///   network behind NAT, carrier-grade NAT) or one global /64. A device that
///   shares a source with a stalling host may be refused on its direct path,
///   and when more than `maxPendingHandshakesPerSource` devices of one source
///   handshake at the same moment, the others are refused and must dial again.
/// - Senders a relay names are keys anyone can make, so peers that keep
///   starting relayed handshakes under new keys can keep the unlisted relayed
///   slots full. While they do, a device that is no longer listed and dials
///   through the relay is refused before its handshake and learns that it is
///   not admitted only at a later dial. Listed senders are not affected.
///
/// Use one gate per endpoint and change its list with `setAllowed` when a
/// device is paired or removed. The gate has one accept loop. An `acceptNext()`
/// call through the FFI cannot be cancelled, so the loop stops only when the
/// endpoint closes, or when a connection arrives while no stream from
/// `connections(onRefused:)` is being read (that connection is refused).
/// Closing the endpoint is the way to stop accepting at once.
public final class IrohPeerGate: Sendable {
    /// Application error code sent to a peer whose endpoint ID is not listed.
    public static let refusedCode: Int64 = 403
    /// Application error code sent to a peer the gate cannot hand over now: no
    /// stream from `connections(onRefused:)` is being read to take its
    /// connection, or the gate has no list yet.
    public static let unavailableCode: Int64 = 503
    public static let defaultMaxPendingHandshakes = 64
    public static let defaultMaxPendingHandshakesPerSource = 2
    public static let defaultMaxPendingUnlistedRelayedHandshakes = 8
    public static let defaultHandshakeTimeout: Duration = .seconds(5)

    public let endpoint: Endpoint
    /// Handshakes over direct paths in progress at once, from all sources.
    public let maxPendingHandshakes: Int
    /// Handshakes in progress at once from one source.
    public let maxPendingHandshakesPerSource: Int
    /// Relayed handshakes in progress at once from senders that are not listed
    /// (from every relayed sender while the gate has no list).
    public let maxPendingUnlistedRelayedHandshakes: Int
    /// How long a handshake may take before iroh drops it.
    public let handshakeTimeout: Duration
    private let timeoutMilliseconds: UInt64
    private let state: Mutex<State>

    private struct Listener {
        let id: UInt64
        let continuation: AsyncStream<Connection>.Continuation
        let onRefused: @Sendable (EndpointId) -> Void
    }

    private struct State {
        /// Nil until the first list.
        var allowed: Set<Data>?
        var listener: Listener?
        var nextListenerID: UInt64 = 0
        var loopRunning = false
        var slots: HandshakeSlots
    }

    /// A gate that admits `allowed`.
    ///
    /// - Parameters:
    ///   - endpoint: the endpoint whose incoming connections the gate takes.
    ///   - allowed: the endpoint IDs (32-byte public keys) to accept.
    ///   - maxPendingHandshakes: direct handshakes allowed in progress at once (at least 1).
    ///   - maxPendingHandshakesPerSource: handshakes allowed in progress at once from one
    ///     source (at least 1).
    ///   - maxPendingUnlistedRelayedHandshakes: relayed handshakes allowed in progress at once
    ///     from senders that are not listed (at least 1).
    ///   - handshakeTimeout: how long a handshake may take (at least 1 ms).
    public convenience init(
        endpoint: Endpoint,
        allowed: some Sequence<Data>,
        maxPendingHandshakes: Int = defaultMaxPendingHandshakes,
        maxPendingHandshakesPerSource: Int = defaultMaxPendingHandshakesPerSource,
        maxPendingUnlistedRelayedHandshakes: Int = defaultMaxPendingUnlistedRelayedHandshakes,
        handshakeTimeout: Duration = defaultHandshakeTimeout
    ) {
        self.init(endpoint: endpoint, list: Set(allowed), maxPendingHandshakes: maxPendingHandshakes,
                  maxPendingHandshakesPerSource: maxPendingHandshakesPerSource,
                  maxPendingUnlistedRelayedHandshakes: maxPendingUnlistedRelayedHandshakes, handshakeTimeout: handshakeTimeout)
    }

    /// A gate with no list yet: until `setAllowed` gives it one, every
    /// connection it completes is closed with `unavailableCode`. The parameters
    /// are those of `init(endpoint:allowed:…)`.
    public convenience init(
        endpoint: Endpoint,
        maxPendingHandshakes: Int = defaultMaxPendingHandshakes,
        maxPendingHandshakesPerSource: Int = defaultMaxPendingHandshakesPerSource,
        maxPendingUnlistedRelayedHandshakes: Int = defaultMaxPendingUnlistedRelayedHandshakes,
        handshakeTimeout: Duration = defaultHandshakeTimeout
    ) {
        self.init(endpoint: endpoint, list: nil, maxPendingHandshakes: maxPendingHandshakes,
                  maxPendingHandshakesPerSource: maxPendingHandshakesPerSource,
                  maxPendingUnlistedRelayedHandshakes: maxPendingUnlistedRelayedHandshakes, handshakeTimeout: handshakeTimeout)
    }

    private init(
        endpoint: Endpoint,
        list: Set<Data>?,
        maxPendingHandshakes: Int,
        maxPendingHandshakesPerSource: Int,
        maxPendingUnlistedRelayedHandshakes: Int,
        handshakeTimeout: Duration
    ) {
        precondition(maxPendingHandshakes >= 1, "maxPendingHandshakes must be at least 1")
        precondition(maxPendingHandshakesPerSource >= 1, "maxPendingHandshakesPerSource must be at least 1")
        precondition(maxPendingUnlistedRelayedHandshakes >= 1, "maxPendingUnlistedRelayedHandshakes must be at least 1")
        let (seconds, attoseconds) = handshakeTimeout.components
        precondition(seconds >= 0 && attoseconds >= 0, "handshakeTimeout must not be negative")
        let milliseconds = UInt64(seconds) * 1000 + UInt64(attoseconds / 1_000_000_000_000_000)
        precondition(milliseconds >= 1, "handshakeTimeout must be at least 1 ms")
        self.endpoint = endpoint
        self.maxPendingHandshakes = maxPendingHandshakes
        self.maxPendingHandshakesPerSource = maxPendingHandshakesPerSource
        self.maxPendingUnlistedRelayedHandshakes = maxPendingUnlistedRelayedHandshakes
        self.handshakeTimeout = handshakeTimeout
        timeoutMilliseconds = milliseconds
        state = Mutex(State(allowed: list, slots: HandshakeSlots(
            maxDirect: maxPendingHandshakes, maxPerSource: maxPendingHandshakesPerSource,
            maxUnlistedRelayed: maxPendingUnlistedRelayedHandshakes)))
    }

    /// The endpoint IDs the gate accepts; nil until it has a list.
    public var allowed: Set<Data>? {
        state.withLock { $0.allowed }
    }

    /// Replaces the list (or gives the first one). Handshakes that finish from
    /// now on are checked against it; connections already handed over are not
    /// closed.
    public func setAllowed(_ ids: some Sequence<Data>) {
        let ids = Set(ids)
        state.withLock { $0.allowed = ids }
    }

    public func allows(_ id: EndpointId) -> Bool {
        let bytes = id.toBytes()
        return state.withLock { $0.allowed?.contains(bytes) ?? false }
    }

    /// Handshakes in progress now, direct and relayed.
    public var pendingHandshakes: Int {
        state.withLock { $0.slots.pending }
    }

    /// The connections from allowed peers, until the endpoint is closed or
    /// another call replaces this stream (which then finishes). A connection
    /// that completes while no stream is being read, or while the gate has no
    /// list, is closed with `unavailableCode`. `onRefused` is called with the ID
    /// of each peer refused after its handshake (with `refusedCode`, over a
    /// direct path or a relay).
    ///
    /// Stop reading by cancelling the task that iterates the stream, or by
    /// letting go of the stream: a reader that only leaves its loop while the
    /// stream is still referenced leaves it open, and connections queue in it.
    public func connections(onRefused: @escaping @Sendable (EndpointId) -> Void = { _ in }) -> AsyncStream<Connection> {
        let (stream, continuation) = AsyncStream<Connection>.makeStream()
        let id = state.withLock { state -> UInt64 in
            state.nextListenerID += 1
            return state.nextListenerID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                if state.listener?.id == id { state.listener = nil }
            }
        }
        let (replaced, startLoop) = state.withLock { state -> (Listener?, Bool) in
            let replaced = state.listener
            state.listener = Listener(id: id, continuation: continuation, onRefused: onRefused)
            let start = !state.loopRunning
            state.loopRunning = true
            return (replaced, start)
        }
        replaced?.continuation.finish()
        if startLoop {
            Task { await self.acceptLoop() }
        }
        return stream
    }

    private func acceptLoop() async {
        await withDiscardingTaskGroup { group in
            while true {
                guard let incoming = await endpoint.acceptNext() else {
                    // The endpoint is closed.
                    let listener = state.withLock { state -> Listener? in
                        state.loopRunning = false
                        defer { state.listener = nil }
                        return state.listener
                    }
                    listener?.continuation.finish()
                    return
                }
                let listening = state.withLock { state -> Bool in
                    if state.listener == nil { state.loopRunning = false }
                    return state.listener != nil
                }
                guard listening else {
                    // Nobody reads the connections any more. The next call to
                    // connections(onRefused:) starts the loop again.
                    try? await incoming.refuse()
                    return
                }
                guard let address = try? await incoming.remoteAddr() else {
                    try? await incoming.refuse()
                    continue
                }
                let source = HandshakeSource(address)
                // Address validation: a peer that cannot receive at its source
                // address never gets a handshake. The retried attempt arrives as
                // a new incoming connection with its address validated.
                guard (try? await incoming.remoteAddrValidated()) == true else {
                    try? await incoming.retry()
                    continue
                }
                // The relay authenticated the sender it names. One that is not
                // listed still gets a handshake, from slots of its own, so that
                // it is refused with the gate's code as on a direct path.
                let admitted = state.withLock { state -> HandshakeSlots.Pool? in
                    let pool = HandshakeSlots.Pool(source, allowed: state.allowed)
                    return state.slots.take(source, pool: pool) ? pool : nil
                }
                guard let pool = admitted else {
                    try? await incoming.refuse()
                    continue
                }
                group.addTask { await self.handshake(incoming, from: source, pool: pool) }
            }
        }
    }

    private func handshake(_ incoming: Incoming, from source: HandshakeSource, pool: HandshakeSlots.Pool) async {
        // iroh drops the handshake at the deadline; Swift cannot cancel an FFI call.
        let connection = try? await incoming.accept().connectWithTimeout(timeoutMs: timeoutMilliseconds)
        state.withLock { $0.slots.release(source, pool: pool) }
        guard let connection else {
            return  // a failed or timed-out handshake is not a peer
        }
        let remote = connection.remoteId()
        let remoteBytes = remote.toBytes()
        let (list, listener) = state.withLock { ($0.allowed, $0.listener) }
        guard let list else {
            // No list yet: the peer may be paired, so it is asked to come back, not refused.
            try? connection.close(errorCode: Self.unavailableCode, reason: Data("no peer list yet".utf8))
            return
        }
        guard list.contains(remoteBytes) else {
            try? connection.close(errorCode: Self.refusedCode, reason: Data("not paired".utf8))
            listener?.onRefused(remote)
            return
        }
        guard let listener, case .enqueued = listener.continuation.yield(connection) else {
            try? connection.close(errorCode: Self.unavailableCode, reason: Data("not accepting connections".utf8))
            return
        }
    }
}

/// The gate's handshakes in progress, by source and by pool of slots.
struct HandshakeSlots: Sendable, Equatable {
    /// Which slots a handshake takes besides its source's.
    enum Pool: Sendable, Equatable {
        /// A direct path: the shared slots.
        case direct
        /// Through a relay, from a listed sender: no other slots.
        case listedRelayed
        /// Through a relay, from a sender that is not listed, or from any sender while the gate
        /// has no list: the unlisted relayed slots.
        case unlistedRelayed

        init(_ source: HandshakeSource, allowed: Set<Data>?) {
            guard case .relayed(let sender) = source else {
                self = .direct
                return
            }
            self = allowed?.contains(sender) == true ? .listedRelayed : .unlistedRelayed
        }
    }

    let maxDirect: Int
    let maxPerSource: Int
    let maxUnlistedRelayed: Int
    private(set) var pendingDirect = 0
    private(set) var pendingUnlistedRelayed = 0
    private(set) var pendingBySource: [HandshakeSource: Int] = [:]

    /// Every handshake in progress.
    var pending: Int { pendingBySource.values.reduce(0, +) }

    /// Takes the slots of one handshake; false (nothing taken) when its source or pool is full.
    mutating func take(_ source: HandshakeSource, pool: Pool) -> Bool {
        let fromSource = pendingBySource[source, default: 0]
        guard fromSource < maxPerSource else { return false }
        switch pool {
        case .direct:
            guard pendingDirect < maxDirect else { return false }
            pendingDirect += 1
        case .unlistedRelayed:
            guard pendingUnlistedRelayed < maxUnlistedRelayed else { return false }
            pendingUnlistedRelayed += 1
        case .listedRelayed:
            break
        }
        pendingBySource[source] = fromSource + 1
        return true
    }

    /// Gives back what `take` took for the same source and pool.
    mutating func release(_ source: HandshakeSource, pool: Pool) {
        switch pool {
        case .direct: pendingDirect -= 1
        case .unlistedRelayed: pendingUnlistedRelayed -= 1
        case .listedRelayed: break
        }
        let left = pendingBySource[source, default: 1] - 1
        pendingBySource[source] = left > 0 ? left : nil
    }
}

/// Where a connection attempt comes from, for the gate's per-source limit.
///
/// A source is meant to be one host. For IPv4 that is the address. For IPv6 it
/// is the /64 only for global unicast addresses (2000::/3), where a /64 is one
/// network's link and one host can take any address in it. Every other IPv6
/// address counts on its own:
/// - unique local addresses (fc00::/7): overlays give each node an address out
///   of one shared /64 (every node of a Tailscale tailnet, in
///   fd7a:115c:a1e0::/48, or of a ZeroTier network);
/// - link-local addresses (fe80::/10), which all share fe80::/64;
/// - NAT64 addresses (64:ff9b::/96), one IPv4 host each;
/// - the rest outside 2000::/3.
/// Unique local and link-local addresses are not routed on the internet, and
/// the QUIC retry makes a peer prove it receives at its address, so only a host
/// on the Mac's own network or overlay can use one; such a host can take one
/// source per address it holds, up to the shared slots.
///
/// A Teredo address (2001::/32) is global, but the clients of one Teredo server
/// share a /64; it counts as the IPv4 address it carries, the client's public one.
enum HandshakeSource: Hashable, Sendable {
    /// An IPv4 address (an IPv4-mapped IPv6 address, or the client of a Teredo
    /// address, counts as its IPv4 address).
    case ipv4(UInt32)
    /// A global unicast IPv6 address's /64 prefix (`low` is 0), or any other
    /// IPv6 address whole.
    case ipv6(high: UInt64, low: UInt64)
    /// The sender a relay names for a relayed connection.
    case relayed(Data)
    /// An address that is not an IP address (a custom transport).
    case other(String)

    init(_ address: IncomingAddr) {
        switch address {
        case .ip(let socketAddress):
            self = Self.ip(socketAddress) ?? .other(socketAddress)
        case .relay(_, let endpointId):
            self = .relayed(endpointId.toBytes())
        case .custom(let description):
            self = .other(description)
        }
    }

    /// The source of an `ip:port` or `[ipv6]:port` address as iroh writes it.
    static func ip(_ socketAddress: String) -> HandshakeSource? {
        var host = Substring(socketAddress)
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else { return nil }
            host = host[host.index(after: host.startIndex)..<end]
        } else if let colon = host.lastIndex(of: ":") {
            host = host[..<colon]
        }
        if let zone = host.firstIndex(of: "%") {
            host = host[..<zone]
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, String(host), &v4) == 1 {
            return .ipv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, String(host), &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return .ipv4(bytes[12..<16].reduce(0) { $0 << 8 | UInt32($1) })
        }
        // Teredo, 2001:0::/32: the client's public IPv4 address is the last 32 bits, inverted.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0, bytes[3] == 0 {
            return .ipv4(~bytes[12..<16].reduce(0) { $0 << 8 | UInt32($1) })
        }
        let high = bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
        let low = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
        let globalUnicast = bytes[0] & 0xe0 == 0x20
        return .ipv6(high: high, low: globalUnicast ? 0 : low)
    }
}
