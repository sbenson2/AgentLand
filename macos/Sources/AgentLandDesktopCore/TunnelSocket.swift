import Darwin
import Foundation

/// One connection to the host's tunnel socket (a Unix domain socket in the state folder), read and
/// written without holding a thread: the descriptor is nonblocking, and a read or write that would
/// block waits for the kernel's readiness (a one-shot dispatch source), so the bridge's streams need
/// no thread each. `SO_NOSIGPIPE` turns a write to a closed peer into `EPIPE`.
///
/// `abort()` closes the descriptor once no wait is in progress; every read and write after it, and
/// every wait it interrupts, fails with `TunnelSocketError.closed`.
public final class TunnelSocket: @unchecked Sendable {
    /// Unix socket paths hold at most this many bytes (`sun_path` less its terminating zero).
    public static let maximumPathBytes = 103

    private let descriptor: Int32
    /// Serializes every use of the descriptor and the state below.
    private let queue = DispatchQueue(label: "dev.agentland.tunnel-socket")
    private var waits: [ObjectIdentifier: any DispatchSourceProtocol] = [:]
    private var closeRequested = false
    private var closed = false

    /// Connects to the socket at `path`. A socket nobody listens on fails at once (`ECONNREFUSED`),
    /// as does a missing one (`ENOENT`).
    public static func connect(path: String) throws -> TunnelSocket {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumPathBytes else { throw TunnelSocketError.connect(ENAMETOOLONG) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelSocketError.connect(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw TunnelSocketError.connect(failure)
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return TunnelSocket(descriptor: fd)
    }

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if !closed { Darwin.close(descriptor) }
    }

    /// Up to `maximum` bytes; nil at the end of file.
    public func read(maximum: Int) async throws -> Data? {
        precondition(maximum > 0)
        while true {
            let result = queue.sync { () -> IOResult in
                guard !closeRequested else { return .failed(TunnelSocketError.closed) }
                var buffer = [UInt8](repeating: 0, count: maximum)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, maximum) }
                if count > 0 { return .data(Data(buffer.prefix(count))) }
                if count == 0 { return .end }
                let failure = errno
                if failure == EAGAIN || failure == EINTR { return .wouldBlock }
                return .failed(TunnelSocketError.read(failure))
            }
            switch result {
            case let .data(data): return data
            case .end: return nil
            case .wouldBlock: try await wait(readable: true)
            case let .failed(error): throw error
            case .wrote: preconditionFailure()
            }
        }
    }

    /// Writes all of `data`, waiting while the socket's buffer is full.
    public func write(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let start = offset
            let result = queue.sync { () -> IOResult in
                guard !closeRequested else { return .failed(TunnelSocketError.closed) }
                let count = data.withUnsafeBytes { raw in
                    Darwin.write(descriptor, raw.baseAddress! + start, raw.count - start)
                }
                if count >= 0 { return .wrote(count) }
                let failure = errno
                if failure == EAGAIN || failure == EINTR { return .wouldBlock }
                return .failed(TunnelSocketError.write(failure))
            }
            switch result {
            case let .wrote(count): offset += count
            case .wouldBlock: try await wait(readable: false)
            case let .failed(error): throw error
            case .data, .end: preconditionFailure()
            }
        }
    }

    /// `shutdown(SHUT_WR)`: the host reads its end of file; reading goes on.
    public func shutdownOutput() {
        queue.sync {
            guard !closeRequested else { return }
            _ = Darwin.shutdown(descriptor, SHUT_WR)
        }
    }

    /// Closes the socket (at once, or once the waits it interrupts have ended). Idempotent.
    public func abort() {
        queue.async { [self] in
            guard !closeRequested else { return }
            closeRequested = true
            for wait in waits.values { wait.cancel() }
            closeIfIdle()
        }
    }

    /// Whether `abort()` has run (tests).
    var isClosed: Bool { queue.sync { closed } }

    private enum IOResult {
        case data(Data)
        case end
        case wrote(Int)
        case wouldBlock
        case failed(any Error)
    }

    /// Waits until the descriptor is readable (or writable), or `abort()` interrupts.
    private func wait(readable: Bool) async throws {
        let interrupted: Bool = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closeRequested else {
                    continuation.resume(returning: true)
                    return
                }
                let source: any DispatchSourceProtocol
                if readable {
                    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                } else {
                    source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                }
                let id = ObjectIdentifier(source)
                source.setEventHandler { source.cancel() }
                source.setCancelHandler { [self] in
                    waits[id] = nil
                    continuation.resume(returning: closeRequested)
                    closeIfIdle()
                }
                waits[id] = source
                source.activate()
            }
        }
        if interrupted { throw TunnelSocketError.closed }
    }

    /// On `queue`: the descriptor is closed only after every source watching it was cancelled.
    private func closeIfIdle() {
        guard closeRequested, !closed, waits.isEmpty else { return }
        closed = true
        Darwin.close(descriptor)
    }
}

public enum TunnelSocketError: Error, Equatable {
    case connect(Int32)
    case read(Int32)
    case write(Int32)
    case closed
}
