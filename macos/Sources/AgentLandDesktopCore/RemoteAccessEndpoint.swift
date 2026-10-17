import Foundation
import Synchronization
import AgentLandCore
import AgentLandIroh

/// Which relay the Mac endpoint runs with (docs/HOST-API.md "The two apps", The Mac endpoint).
public enum RemoteAccessRelayChoice: Equatable, Sendable {
    /// No relay (`RelayMode.disabled()`): the fallback is off.
    case none
    /// n0's default relays (`RelayMode.defaultMode()`), only until the endpoint has a home relay: the
    /// fallback was just turned on, or its kept relay was unreachable for 10 minutes.
    case pick
    /// The one n0 relay the app kept (`RelayMode.customFromUrls([url])`).
    case pinned(String)
}

public struct RemoteAccessEndpointConfiguration: Sendable {
    /// The Keychain key's 32 bytes.
    public var secretKey: Data
    /// The UDP port it binds on every address (`RemoteAccessPorts.endpointUDP`).
    public var port: UInt16
    public var relay: RemoteAccessRelayChoice
    /// The host's tunnel socket, which each admitted stream is bridged to.
    public var socketPath: String

    public init(secretKey: Data, port: UInt16, relay: RemoteAccessRelayChoice, socketPath: String) {
        self.secretKey = secretKey
        self.port = port
        self.relay = relay
        self.socketPath = socketPath
    }
}

public enum RemoteAccessEndpointEvent: Equatable, Sendable {
    /// The relays the endpoint is connected to now (`watchHomeRelay`).
    case homeRelays([String])
}

/// A running Mac endpoint as the service uses it (iroh's; a fake in tests).
public protocol RemoteAccessEndpointRunning: AnyObject, Sendable {
    var nodeID: IrohNodeID { get }
    /// The node IDs its gate admits (the host's peer list), which also closes the connections of
    /// node IDs no longer listed. The first call gives the gate its first list.
    func setAllowed(_ keys: Set<Data>) async
    /// The external `ip:port` addresses to advertise (the router mapping's), replacing the last ones.
    func setExternalAddresses(_ addresses: [String]) async
    /// Stops accepting at once, closes its connections and their streams' sockets.
    func close() async
}

/// Makes the Mac endpoint; the service's dependency.
public typealias RemoteAccessEndpointBinder = @Sendable (RemoteAccessEndpointConfiguration,
    @escaping @Sendable (RemoteAccessEndpointEvent) -> Void) async throws -> any RemoteAccessEndpointRunning

/// The Mac endpoint (docs/HOST-API.md "The two apps", The Mac endpoint): `presetMinimal()` with the
/// Keychain key, ALPN `agentland/tunnel/1`, `bindPort` on every address, no relay unless the fallback
/// is on (then n0's default relays until it has a home relay, and after that the one kept relay), so
/// nothing is published to n0's DNS. Every connection goes through an `IrohPeerGate` made without a
/// list: until the first `setAllowed` it closes each one it completes with 503, and after it with 403
/// when the node ID is not listed. Each bidirectional stream of an admitted connection is one
/// connection to the host's tunnel socket (`MacTunnelBridge`).
public final class IrohMacEndpoint: RemoteAccessEndpointRunning, @unchecked Sendable {
    public let nodeID: IrohNodeID
    public let endpoint: Endpoint
    private let gate: IrohPeerGate
    private let bridge: MacTunnelBridge
    private let state = Mutex(State())

    private struct State {
        /// Admitted connections by `stableId`, with their node ID's bytes.
        var connections: [UInt64: (remote: Data, connection: Connection)] = [:]
        var external: [String] = []
        var acceptTask: Task<Void, Never>?
        var relayWatch: WatchHandle?
        var closed = false
    }

    /// Binds the endpoint. A port another program holds fails with iroh's `.bind` error.
    public static func bind(_ configuration: RemoteAccessEndpointConfiguration,
                            events: @escaping @Sendable (RemoteAccessEndpointEvent) -> Void) async throws -> IrohMacEndpoint {
        let relayMode: RelayMode
        switch configuration.relay {
        case .none: relayMode = RelayMode.disabled()
        case .pick: relayMode = RelayMode.defaultMode()
        case let .pinned(url): relayMode = try RelayMode.customFromUrls(urls: [url])
        }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            secretKey: configuration.secretKey,
            alpns: [RemoteAccessTunnel.alpn],
            relayMode: relayMode,
            bindPort: configuration.port))
        guard let nodeID = IrohNodeID(publicKey: endpoint.id().toBytes()) else {
            try? await endpoint.close()
            throw RemoteAccessKeyError.unusableKey
        }
        let running = IrohMacEndpoint(endpoint: endpoint, nodeID: nodeID, socketPath: configuration.socketPath)
        running.startAccepting()
        if configuration.relay != .none {
            let watch = endpoint.watchHomeRelay(callback: HomeRelayWatcher(events: events))
            running.state.withLock { $0.relayWatch = watch }
        }
        return running
    }

    private init(endpoint: Endpoint, nodeID: IrohNodeID, socketPath: String) {
        self.endpoint = endpoint
        self.nodeID = nodeID
        gate = IrohPeerGate(endpoint: endpoint)
        bridge = MacTunnelBridge(socketPath: socketPath)
    }

    public func setAllowed(_ keys: Set<Data>) async {
        gate.setAllowed(keys)
        let unlisted = state.withLock { state in
            state.connections.values.filter { !keys.contains($0.remote) }.map(\.connection)
        }
        for connection in unlisted {
            try? connection.close(errorCode: RemoteAccessTunnel.ConnectionCode.notAdmitted.rawValue, reason: Data("not paired".utf8))
        }
    }

    public func setExternalAddresses(_ addresses: [String]) async {
        let previous = state.withLock { state -> [String] in
            defer { state.external = addresses }
            return state.external
        }
        for address in addresses where !previous.contains(address) {
            try? await endpoint.addExternalAddr(addr: address)
        }
        for address in previous where !addresses.contains(address) {
            _ = try? await endpoint.removeExternalAddr(addr: address)
        }
    }

    public func close() async {
        let (first, watch, accepting) = state.withLock { state -> (Bool, WatchHandle?, Task<Void, Never>?) in
            let taken = (!state.closed, state.relayWatch, state.acceptTask)
            state.closed = true
            state.relayWatch = nil
            state.acceptTask = nil
            return taken
        }
        guard first else { return }
        await watch?.stop()
        accepting?.cancel()
        try? await endpoint.close()
    }

    /// The gate's connections, each served until it closes; cancelling ends them all.
    private func startAccepting() {
        let connections = gate.connections()
        let task = Task { [self] in
            await withDiscardingTaskGroup { group in
                for await connection in connections {
                    group.addTask { await self.serve(connection) }
                }
                group.cancelAll()
            }
        }
        state.withLock { $0.acceptTask = task }
    }

    private func serve(_ connection: Connection) async {
        let remote = connection.remoteId().toBytes()
        guard let peer = IrohNodeID(publicKey: remote) else {
            try? connection.close(errorCode: RemoteAccessTunnel.ConnectionCode.notAdmitted.rawValue, reason: Data("not paired".utf8))
            return
        }
        let id = connection.stableId()
        state.withLock { $0.connections[id] = (remote, connection) }
        defer { _ = state.withLock { $0.connections.removeValue(forKey: id) } }
        // A list that arrived while the gate handed this connection over has been applied to the
        // connections registered before it; check this one against it too.
        guard gate.allows(connection.remoteId()) else {
            try? connection.close(errorCode: RemoteAccessTunnel.ConnectionCode.notAdmitted.rawValue, reason: Data("not paired".utf8))
            return
        }
        let bridge = bridge
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { group in
                while let stream = try? await connection.acceptBi() {
                    group.addTask {
                        await bridge.serve(peer: peer, send: IrohTunnelSend(stream.send()), receive: IrohTunnelReceive(stream.recv()))
                    }
                }
                // The connection is gone: every stream on it ends, and its socket closes.
                group.cancelAll()
            }
        } onCancel: {
            try? connection.close(errorCode: RemoteAccessTunnel.ConnectionCode.unavailable.rawValue, reason: Data("closing".utf8))
        }
    }
}

/// Forwards `watchHomeRelay`'s changes.
private final class HomeRelayWatcher: HomeRelayCallback, Sendable {
    let events: @Sendable (RemoteAccessEndpointEvent) -> Void
    init(events: @escaping @Sendable (RemoteAccessEndpointEvent) -> Void) { self.events = events }
    func onChange(relayUrls: [String]) async throws { events(.homeRelays(relayUrls)) }
}
