import Foundation
import AgentLandCore
import AgentLandIroh

/// The sending side of a stream as the bridge uses it (iroh's `SendStream`; fakes in tests).
public protocol TunnelStreamSending: Sendable {
    /// Writes all of `data`; throws once the peer stopped the stream or the connection is gone.
    func write(_ data: Data) async throws
    /// `SendStream.finish()`.
    func finish() async throws
    /// `SendStream.reset(errorCode:)`.
    func reset(code: UInt64) async throws
}

/// The receiving side of a stream as the bridge uses it (iroh's `RecvStream`; fakes in tests).
public protocol TunnelStreamReceiving: Sendable {
    /// Up to `maximum` bytes; empty at the stream's end. Throws when the peer reset the stream, it was
    /// stopped here, or the connection is gone.
    func read(maximum: Int) async throws -> Data
    /// `RecvStream.stop(errorCode:)`.
    func stop(code: UInt64) async throws
}

/// One connection to the host's tunnel socket as the bridge uses it (`TunnelSocket`; fakes in tests).
protocol TunnelSocketConnection: Sendable {
    /// Up to `maximum` bytes; nil at the end of file.
    func read(maximum: Int) async throws -> Data?
    /// Writes all of `data`.
    func write(_ data: Data) async throws
    /// `shutdown(SHUT_WR)`.
    func shutdownOutput()
    /// Closes the connection. Idempotent.
    func abort()
}

extension TunnelSocket: TunnelSocketConnection {}

/// Bridges one QUIC stream to one new connection to the host's tunnel socket (docs/HOST-API.md "The
/// two apps", "Streams" and "Ending a stream"): the 84-byte preamble naming the peer iroh verified,
/// then the phone's TLS bytes unchanged both ways, in chunks of at most 64 KiB.
///
/// Each direction ends on its own, by `RemoteAccessTunnel.StreamEnds`: the socket's end of file
/// finishes the stream and the stream's end shuts down the socket's sending side, so the host's last
/// bytes arrive; a failed write stops the stream's receiving side (code 1) and leaves the sending side
/// alone; a failed read resets the sending side unless it has finished; a reset that arrives closes
/// the socket; a stop that arrives makes the bridge read and drop what the host still sends until its
/// end of file. When the host sends nothing before its socket ends, or the socket cannot be reached at
/// all, the stream is reset and stopped with code 2 (refused) instead. A write that fails before the
/// host has sent a byte (the host closed the socket as it refused, and the phone's ClientHello met the
/// closed socket first) waits for the socket's end: nothing read means refused (code 2 both ways),
/// bytes read mean a failed write (code 1).
///
/// iroh's streams hold a lock while a read or write waits, and a stop or reset takes the same lock, so
/// the bridge never waits for a stop or reset it sends: each goes out on its own task and takes effect
/// once the pending call on that side returns.
public struct MacTunnelBridge: Sendable {
    /// The largest chunk read from either side at once.
    public static let chunkBytes = 64 * 1024

    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Bridges until both directions have ended, or until the task is cancelled (the connection or
    /// the endpoint closed), which closes the socket and resets what is still open.
    public func serve(peer: IrohNodeID, send: any TunnelStreamSending, receive: any TunnelStreamReceiving) async {
        let socket: TunnelSocket
        do {
            socket = try TunnelSocket.connect(path: socketPath)
        } catch {
            // The host is not running (or not serving the tunnel): refused.
            let state = StreamState(socket: nil, send: send, receive: receive)
            await state.handle(.hostRefused)
            return
        }
        await Self.bridge(peer: peer, socket: socket, send: send, receive: receive)
    }

    /// Bridges over a connection already made to the tunnel socket.
    static func bridge(peer: IrohNodeID, socket: any TunnelSocketConnection, send: any TunnelStreamSending,
                       receive: any TunnelStreamReceiving) async {
        let state = StreamState(socket: socket, send: send, receive: receive)
        await withTaskCancellationHandler {
            do {
                try await socket.write(RemoteAccessTunnel.preamble(nodeID: peer))
            } catch {
                await state.handle(.hostRefused)
                socket.abort()
                return
            }
            await withDiscardingTaskGroup { group in
                group.addTask { await Self.pumpSocketToStream(socket: socket, send: send, state: state) }
                group.addTask { await Self.pumpStreamToSocket(socket: socket, receive: receive, state: state) }
            }
        } onCancel: {
            socket.abort()
        }
        socket.abort()
    }

    /// The sending direction: the host's bytes into the stream.
    private static func pumpSocketToStream(socket: any TunnelSocketConnection, send: any TunnelStreamSending, state: StreamState) async {
        while true {
            let sending = await state.sending
            guard sending == .open || sending == .dropping else { return }
            let chunk: Data?
            do {
                chunk = try await socket.read(maximum: chunkBytes)
            } catch {
                await state.handle(await state.hostSent ? .socketReadFailed : .hostRefused)
                return
            }
            guard let chunk else {
                await state.handle(await state.hostSent ? .socketEnded : .hostRefused)
                return
            }
            await state.hostSentBytes()
            guard await state.sending == .open else { continue }  // dropping: read to the end, forward nothing
            do {
                try await send.write(chunk)
            } catch {
                // The peer stopped the stream (its write to its socket failed). A connection that is gone
                // ends every stream on it: the endpoint cancels the bridges, which closes the socket.
                await state.handle(.streamStopped(code: RemoteAccessTunnel.StreamCode.aborted.rawValue))
            }
        }
    }

    /// The receiving direction: the phone's bytes into the socket.
    private static func pumpStreamToSocket(socket: any TunnelSocketConnection, receive: any TunnelStreamReceiving, state: StreamState) async {
        while await state.receiving == .open {
            let chunk: Data
            do {
                chunk = try await receive.read(maximum: chunkBytes)
            } catch {
                await state.handle(.streamReset(code: RemoteAccessTunnel.StreamCode.aborted.rawValue))
                return
            }
            if chunk.isEmpty {
                await state.handle(.streamEnded)
                return
            }
            do {
                try await socket.write(chunk)
            } catch {
                await state.socketWriteFailed()
                return
            }
        }
    }
}

/// One stream's ends and the socket it carries; applies `StreamEnds`' actions.
private actor StreamState {
    private var ends = RemoteAccessTunnel.StreamEnds()
    private let socket: (any TunnelSocketConnection)?
    private let send: any TunnelStreamSending
    private let receive: any TunnelStreamReceiving
    /// The host has sent at least one byte on the socket.
    private(set) var hostSent = false
    /// A write to the socket failed before the host sent a byte; what the socket's end shows decides.
    private var writeFailedEarly = false

    init(socket: (any TunnelSocketConnection)?, send: any TunnelStreamSending, receive: any TunnelStreamReceiving) {
        self.socket = socket
        self.send = send
        self.receive = receive
    }

    var sending: RemoteAccessTunnel.StreamEnds.Sending { ends.sending }
    var receiving: RemoteAccessTunnel.StreamEnds.Receiving { ends.receiving }

    /// The host sent bytes: a write that failed before is a failed write (code 1) after all.
    func hostSentBytes() {
        guard !hostSent else { return }
        hostSent = true
        if writeFailedEarly { handle(.socketWriteFailed) }
    }

    /// A write to the socket failed. Before the host sent anything, the host has most likely closed the
    /// socket to refuse the stream: the socket's end then says so (code 2), so the stop waits for it.
    func socketWriteFailed() {
        if hostSent { handle(.socketWriteFailed) } else { writeFailedEarly = true }
    }

    func handle(_ event: RemoteAccessTunnel.StreamEnds.Event) {
        for action in ends.handle(event) {
            switch action {
            case .finishStream:
                let send = send
                Task { try? await send.finish() }
            case let .resetStream(code):
                let send = send
                Task { try? await send.reset(code: code.rawValue) }
            case let .stopStream(code):
                let receive = receive
                Task { try? await receive.stop(code: code.rawValue) }
            case .dropSocketInput:
                break  // the sending direction reads `sending` and drops what it reads
            case .shutdownSocketOutput:
                socket?.shutdownOutput()
            case .abortSocket, .close:
                socket?.abort()
            }
        }
    }
}

/// iroh's `SendStream` for the bridge.
public struct IrohTunnelSend: TunnelStreamSending {
    let stream: SendStream
    public init(_ stream: SendStream) { self.stream = stream }
    public func write(_ data: Data) async throws { try await stream.writeAll(buf: data) }
    public func finish() async throws { try await stream.finish() }
    public func reset(code: UInt64) async throws { try await stream.reset(errorCode: code) }
}

/// iroh's `RecvStream` for the bridge.
public struct IrohTunnelReceive: TunnelStreamReceiving {
    let stream: RecvStream
    public init(_ stream: RecvStream) { self.stream = stream }
    public func read(maximum: Int) async throws -> Data { try await stream.read(sizeLimit: UInt32(maximum)) }
    public func stop(code: UInt64) async throws { try await stream.stop(errorCode: code) }
}
