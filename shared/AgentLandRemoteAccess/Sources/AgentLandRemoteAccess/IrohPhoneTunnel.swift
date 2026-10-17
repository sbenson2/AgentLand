import AgentLandCore
import AgentLandIroh
import Foundation

/// The phone's tunnel (docs/HOST-API.md "The phone's endpoint", "The phone's bridge"): an iroh endpoint
/// with the device's Keychain key, one connection to the Mac's node ID and a loopback bridge whose
/// streams carry `APIClient`'s connections.
///
/// The app makes it only when the route race tries the tunnel and closes it when the app goes to the
/// background or an address answers; the next `open` binds the endpoint again with the same key. The
/// endpoint is `presetMinimal()` (no n0 DNS, nothing published) with the route's relay alone, or no
/// relay (`RemoteAccessTunnelRoute.endpointRelayURLs`), never iroh's default relays. This iroh has no
/// port mapper, so the phone never asks a router for a mapping.
public actor IrohPhoneTunnel: RemoteAccessTunnelConnecting {
    private let secretKey: Data
    private var endpoint: Endpoint?
    private var endpointRelays: [String] = []
    private var connection: Connection?
    private var bridge: TunnelBridge?
    /// Changes with every `open` and `close`, so a dial that ends late is dropped.
    private var generation = 0
    private var hostRefused = false

    /// `secretKey` is the device's 32-byte iroh secret key (`DeviceNodeKey.secretKey`).
    public init(secretKey: Data) {
        self.secretKey = secretKey
    }

    public func open(_ route: RemoteAccessTunnelRoute, target: HostEndpoint, timeout: Duration) async
        -> Result<RemoteAccessBridgeAddress, RemoteAccessTunnelFailure> {
        generation += 1
        let current = generation
        closeConnection()
        guard case let .dial(nodeID, addresses, relayURL) = route else { return .failure(.noAnswer) }

        if endpoint == nil || route.needsEndpointRestart(runningWith: endpointRelays) {
            if let old = endpoint {
                endpoint = nil
                endpointRelays = []
                try? await old.close()
            }
            let relays = route.endpointRelayURLs
            let options: EndpointOptions
            do {
                options = EndpointOptions(preset: presetMinimal(), secretKey: secretKey, alpns: [RemoteAccessTunnel.alpn],
                                          relayMode: relays.isEmpty ? RelayMode.disabled() : try RelayMode.customFromUrls(urls: relays))
            } catch {
                return .failure(.noAnswer)
            }
            guard let bound = try? await Endpoint.bind(options: options) else { return .failure(.noAnswer) }
            guard current == generation else {
                try? await bound.close()
                return .failure(.noAnswer)
            }
            endpoint = bound
            endpointRelays = relays
        }
        guard let endpoint, let id = try? EndpointId.fromBytes(bytes: nodeID.publicKey) else { return .failure(.noAnswer) }

        let address = EndpointAddr(id: id, relayUrl: relayURL, addresses: addresses)
        // iroh's calls cannot be cancelled from Swift: the dial races a timer, and a late one is closed.
        let dialed = await Self.dial(endpoint, address, timeout: timeout)
        guard current == generation else {
            try? dialed?.close(errorCode: 0, reason: Data())
            return .failure(.noAnswer)
        }
        guard let dialed else { return .failure(.noAnswer) }
        if let reason = dialed.closeReason() {
            return .failure(RemoteAccessTunnelFailure(closeReason: reason) ?? .noAnswer)
        }
        let bridge = TunnelBridge(target: target, opener: IrohStreamOpener(connection: dialed), onHostRefused: { [weak self] in
            Task { await self?.noteHostRefused(generation: current) }
        })
        guard let listening = try? bridge.start() else {
            try? dialed.close(errorCode: 0, reason: Data())
            return .failure(.noAnswer)
        }
        connection = dialed
        self.bridge = bridge
        return .success(listening)
    }

    public func failure() async -> RemoteAccessTunnelFailure? {
        guard let connection else { return nil }
        if let reason = connection.closeReason() { return RemoteAccessTunnelFailure(closeReason: reason) ?? .noAnswer }
        if hostRefused { return .hostRefused }
        // The gate closes right after the handshake; its close may still be on its way.
        let reason = await Self.race(.milliseconds(300)) { await connection.closed() }
        if let reason { return RemoteAccessTunnelFailure(closeReason: reason) ?? .noAnswer }
        return hostRefused ? .hostRefused : nil
    }

    public func close() async {
        generation += 1
        closeConnection()
        if let endpoint {
            self.endpoint = nil
            endpointRelays = []
            try? await endpoint.close()
        }
    }

    /// Whether an endpoint runs now, and with which relays (tests).
    public var runningRelays: [String]? { endpoint == nil ? nil : endpointRelays }

    private func closeConnection() {
        bridge?.stop()
        bridge = nil
        if let connection {
            self.connection = nil
            try? connection.close(errorCode: 0, reason: Data())
        }
        hostRefused = false
    }

    private func noteHostRefused(generation: Int) {
        if generation == self.generation { hostRefused = true }
    }

    /// The connection, or nil when the dial failed or `timeout` passed first; one that completes after
    /// the timeout is closed at once.
    private static func dial(_ endpoint: Endpoint, _ address: EndpointAddr, timeout: Duration) async -> Connection? {
        let settled = Settled<Connection>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Connection?, Never>) in
            settled.start(continuation)
            Task {
                let connection = try? await endpoint.connect(addr: address, alpn: RemoteAccessTunnel.alpn)
                if !settled.finish(connection), let connection { try? connection.close(errorCode: 0, reason: Data()) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                settled.finish(nil)
            }
        }
    }

    /// The value of `operation`, or nil once `timeout` has passed first.
    static func race<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let settled = Settled<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            settled.start(continuation)
            Task { settled.finish(await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                settled.finish(nil)
            }
        }
    }
}

/// Resumes once, with the first value.
private final class Settled<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func start(_ continuation: CheckedContinuation<T?, Never>) { lock.withLock { self.continuation = continuation } }

    /// Whether this value was the first.
    @discardableResult
    func finish(_ value: T?) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
        return pending != nil
    }
}

/// Streams of one iroh connection.
struct IrohStreamOpener: TunnelStreamOpening {
    let connection: Connection

    func openStream() async throws -> any TunnelStream {
        IrohTunnelStream(try await connection.openBi())
    }
}

/// One iroh bidirectional stream as the bridge uses it.
final class IrohTunnelStream: TunnelStream, @unchecked Sendable {
    private let sending: SendStream
    private let receivingSide: RecvStream

    init(_ stream: BiStream) {
        sending = stream.send()
        receivingSide = stream.recv()
    }

    func write(_ data: Data) async throws { try await sending.writeAll(buf: data) }
    func finish() async { try? await sending.finish() }
    func reset(code: UInt64) async { try? await sending.reset(errorCode: code) }
    func stop(code: UInt64) async { try? await receivingSide.stop(errorCode: code) }
    func stopped() async -> UInt64? { (try? await sending.stopped()) ?? nil }

    func read(max: Int) async -> TunnelStreamRead {
        do {
            let data = try await receivingSide.read(sizeLimit: UInt32(max))
            return data.isEmpty ? .end : .data(data)
        } catch {
            if let code = Self.resetCode(in: String(describing: error)) { return .reset(code) }
            let receiving = receivingSide
            let reset = await IrohPhoneTunnel.race(.milliseconds(200)) { (try? await receiving.receivedReset()) ?? nil }
            return reset.map(TunnelStreamRead.reset) ?? .lost
        }
    }

    /// The code of `stream reset by peer: error <n>` in a read's error.
    static func resetCode(in description: String) -> UInt64? {
        guard let range = description.range(of: "stream reset by peer: error ") else { return nil }
        return UInt64(description[range.upperBound...].prefix { $0.isNumber })
    }
}
