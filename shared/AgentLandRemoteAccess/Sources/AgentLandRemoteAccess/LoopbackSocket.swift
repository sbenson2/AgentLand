import Darwin
import Foundation

/// Why a socket call did not complete.
enum LoopbackSocketError: Error, Equatable {
    /// This side closed or aborted the socket.
    case closed
    /// The system refused the call (`errno`).
    case failed(Int32)
}

/// One nonblocking TCP socket on 127.0.0.1: a listener, or a connection it accepted. Reads, writes and
/// accepts that would block wait for a dispatch source instead of a thread. `close()` and `abort()` end
/// every wait at once; the descriptor itself is closed only once no call and no source uses it, so a
/// descriptor number the system hands out again never receives a late call.
final class LoopbackSocket: @unchecked Sendable {
    private enum Readiness { case readable, writable }

    private let fd: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Calls and sources using `fd` now.
    private var uses = 0
    private var closing = false
    private var released = false
    private var sources: [ObjectIdentifier: any DispatchSourceProtocol] = [:]

    private init(fd: Int32) {
        self.fd = fd
        queue = DispatchQueue(label: "dev.agentland.remote-access.socket")
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { if !released { Darwin.close(fd) } }

    /// A listener on 127.0.0.1 at a port the system picks.
    static func listen(backlog: Int32 = 32) throws -> (socket: LoopbackSocket, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoopbackSocketError.failed(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound, Darwin.listen(fd, backlog) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw LoopbackSocketError.failed(error)
        }
        return (LoopbackSocket(fd: fd), UInt16(bigEndian: address.sin_port))
    }

    /// A connection to 127.0.0.1 at `port` (tests; the bridge only accepts).
    static func connect(port: UInt16) async throws -> LoopbackSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoopbackSocketError.failed(errno) }
        let socket = LoopbackSocket(fd: fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                let error = errno
                socket.close()
                throw LoopbackSocketError.failed(error)
            }
            try await socket.wait(.writable)
            var pending: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length)
            guard pending == 0 else {
                socket.close()
                throw LoopbackSocketError.failed(pending)
            }
        }
        return socket
    }

    /// The next connection to this listener.
    func accept() async throws -> LoopbackSocket {
        while true {
            let (accepted, error) = try withDescriptor { fd -> (Int32, Int32) in
                let accepted = Darwin.accept(fd, nil, nil)
                return (accepted, errno)
            }
            if accepted >= 0 { return LoopbackSocket(fd: accepted) }
            switch error {
            case EAGAIN, EWOULDBLOCK: try await wait(.readable)
            case EINTR, ECONNABORTED: continue
            default: throw LoopbackSocketError.failed(error)
            }
        }
    }

    /// Up to `max` bytes; empty at the end of the stream (the peer's FIN).
    func read(max: Int) async throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let (count, error) = try withDescriptor { fd in
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, max, 0) }
                return (count, errno)
            }
            if count >= 0 { return Data(buffer[0..<count]) }
            switch error {
            case EAGAIN, EWOULDBLOCK: try await wait(.readable)
            case EINTR: continue
            default: throw LoopbackSocketError.failed(error)
            }
        }
    }

    /// Writes every byte of `data`.
    func write(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let (count, error) = try withDescriptor { fd in
                let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, data.count - offset, 0) }
                return (count, errno)
            }
            if count > 0 {
                offset += count
                continue
            }
            switch count < 0 ? error : EPIPE {
            case EAGAIN, EWOULDBLOCK: try await wait(.writable)
            case EINTR: continue
            case let failure: throw LoopbackSocketError.failed(failure)
            }
        }
    }

    /// `shutdown(SHUT_WR)`: the peer reads the end of the stream (a TCP FIN) after what was written.
    func shutdownOutput() {
        _ = try? withDescriptor { Darwin.shutdown($0, SHUT_WR) }
    }

    /// A TCP reset: `SO_LINGER` 0, then `close()`.
    func abort() {
        _ = try? withDescriptor { fd -> Int32 in
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            return setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        close()
    }

    /// Closes the socket: every wait ends with `.closed`, and the descriptor is closed once nothing
    /// uses it.
    func close() {
        let (waiting, now) = lock.withLock { () -> ([any DispatchSourceProtocol], Bool) in
            guard !closing else { return ([], false) }
            closing = true
            return (Array(sources.values), uses == 0 && !released)
        }
        waiting.forEach { $0.cancel() }
        if now { releaseDescriptor() }
    }

    var isClosed: Bool { lock.withLock { closing } }

    // MARK: The descriptor

    private func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try acquire()
        defer { release() }
        return try body(fd)
    }

    private func acquire() throws {
        try lock.withLock {
            guard !closing else { throw LoopbackSocketError.closed }
            uses += 1
        }
    }

    private func release() {
        let now = lock.withLock { () -> Bool in
            uses -= 1
            return closing && uses == 0 && !released
        }
        if now { releaseDescriptor() }
    }

    private func releaseDescriptor() {
        let close = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if close { Darwin.close(fd) }
    }

    /// Waits until the socket is readable or writable, or closed.
    private func wait(_ readiness: Readiness) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            let source: any DispatchSourceProtocol = switch readiness {
            case .readable: DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            case .writable: DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            }
            let id = ObjectIdentifier(source)
            let admitted = lock.withLock { () -> Bool in
                guard !closing else { return false }
                uses += 1
                sources[id] = source
                return true
            }
            guard admitted else {
                once.resume(throwing: LoopbackSocketError.closed)
                return
            }
            source.setEventHandler {
                once.resume()
                source.cancel()
            }
            source.setCancelHandler { [self] in
                once.resume(throwing: LoopbackSocketError.closed)
                lock.withLock { _ = sources.removeValue(forKey: id) }
                release()
            }
            source.resume()
        }
    }
}

/// Resumes a continuation once, whichever of its callers comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }

    func resume(throwing error: (any Error)? = nil) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
