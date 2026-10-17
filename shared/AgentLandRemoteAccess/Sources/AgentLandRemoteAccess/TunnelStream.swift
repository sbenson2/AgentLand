import Foundation

/// What one read of a stream's receiving side gives.
public enum TunnelStreamRead: Sendable, Equatable {
    case data(Data)
    /// The peer finished its sending side.
    case end
    /// The peer reset its sending side with this code (2: the host refused the connection).
    case reset(UInt64)
    /// The connection is gone (closed, timed out, lost).
    case lost
}

/// One bidirectional stream to the Mac (iroh's `BiStream`), as the bridge uses it. Tests pass fakes.
public protocol TunnelStream: AnyObject, Sendable {
    /// Writes every byte; throws when the peer stopped the stream or the connection is gone.
    func write(_ data: Data) async throws
    /// `SendStream.finish()`.
    func finish() async
    /// `SendStream.reset(errorCode:)`.
    func reset(code: UInt64) async
    /// `RecvStream.read(sizeLimit:)`.
    func read(max: Int) async -> TunnelStreamRead
    /// `RecvStream.stop(errorCode:)`.
    func stop(code: UInt64) async
    /// Returns the peer's code once it stops the sending side, or nil when the sending side is done
    /// without a stop (finished and acknowledged, reset, or the connection gone).
    func stopped() async -> UInt64?
}

/// Opens one stream for each connection the bridge lets through (`Connection.openBi()`).
public protocol TunnelStreamOpening: Sendable {
    func openStream() async throws -> any TunnelStream
}
