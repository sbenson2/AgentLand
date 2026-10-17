import AgentLandCore
import Foundation

/// The phone's bridge (docs/HOST-API.md "The phone's bridge"): an HTTP CONNECT proxy on 127.0.0.1 that
/// opens one stream to the Mac for each connection of `APIClient`'s tunnel transport and copies bytes
/// both ways.
///
/// Every app on the phone can reach 127.0.0.1, so a connection gets a stream only when it proves it is
/// `APIClient`'s: its `CONNECT` names the paired address and, after the bridge's 407, carries the
/// credential `agentland:<secret>`, where the secret is made for each start and kept in memory. Each
/// head must be at most 4 KiB and come within 250 ms; anything else closes the connection before
/// anything reaches the Mac. At most 16 connections wait for a head at once, and one that arrives while
/// 16 wait takes the place of the one that has waited longest. At most 8 streams are open at once and 30
/// open in any minute (half the host's limits for one device); above them the bridge answers 503. How
/// each stream and its socket end follows `RemoteAccessTunnel.StreamEnds`.
public final class TunnelBridge: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maximumStreams = RemoteAccessTunnel.Bridge.maximumStreams
        public var maximumStreamsPerMinute = RemoteAccessTunnel.Bridge.maximumStreamsPerMinute
        public var maximumWaiting = RemoteAccessTunnel.Bridge.maximumWaiting
        public var maximumHeadBytes = RemoteAccessTunnel.Bridge.maximumHeadBytes
        public var headTimeout = RemoteAccessTunnel.Bridge.headTimeout
        /// The window of `maximumStreamsPerMinute` (tests shorten it).
        public var minute: Duration = .seconds(60)

        public init() {}
        public static let standard = Limits()
    }

    /// The address `CONNECT` must name: the paired host and port.
    public let target: HostEndpoint
    public let secret: String
    private let limits: Limits
    private let opener: any TunnelStreamOpening
    private let onHostRefused: @Sendable () -> Void
    private let lock = NSLock()
    private var listener: LoopbackSocket?
    private var stopped = false
    private var waiting: RemoteAccessTunnel.Bridge.WaitingRoom<ObjectIdentifier>
    private var sockets: [ObjectIdentifier: LoopbackSocket] = [:]
    private var openStreams = 0
    private var openedAt: [ContinuousClock.Instant] = []
    private var opened = 0

    /// `onHostRefused` hears of a stream the host refused (a reset with code 2) while `APIClient` still
    /// used its connection.
    public init(target: HostEndpoint, opener: any TunnelStreamOpening, limits: Limits = .standard,
                secret: String = RemoteAccessTunnel.Bridge.makeSecret(), onHostRefused: @escaping @Sendable () -> Void = {}) {
        self.target = target
        self.opener = opener
        self.limits = limits
        self.secret = secret
        self.onHostRefused = onHostRefused
        waiting = RemoteAccessTunnel.Bridge.WaitingRoom(capacity: limits.maximumWaiting)
    }

    deinit { stop() }

    /// Starts listening on 127.0.0.1 at a port the system picks.
    public func start() throws -> RemoteAccessBridgeAddress {
        let (socket, port) = try LoopbackSocket.listen()
        let refused = lock.withLock { () -> Bool in
            guard !stopped, listener == nil else { return true }
            listener = socket
            return false
        }
        guard !refused else {
            socket.close()
            throw LoopbackSocketError.closed
        }
        Task.detached { [weak self] in
            while let connection = try? await socket.accept() {
                guard let self else {
                    connection.close()
                    return
                }
                Task.detached { await self.serve(connection) }
            }
        }
        return RemoteAccessBridgeAddress(port: port, secret: secret)
    }

    /// Stops listening and aborts every connection; their streams end with them.
    public func stop() {
        let (listener, open) = lock.withLock { () -> (LoopbackSocket?, [LoopbackSocket]) in
            stopped = true
            defer { self.listener = nil }
            return (self.listener, Array(sockets.values))
        }
        listener?.close()
        open.forEach { $0.abort() }
    }

    /// Streams opened since the start (tests).
    public var streamsOpened: Int { lock.withLock { opened } }
    /// Connections waiting for their head now (tests).
    var waitingCount: Int { lock.withLock { waiting.waiting.count } }

    // MARK: One connection

    private func serve(_ socket: LoopbackSocket) async {
        let id = ObjectIdentifier(socket)
        let (admitted, evicted) = lock.withLock { () -> (Bool, LoopbackSocket?) in
            guard !stopped else { return (false, nil) }
            sockets[id] = socket
            return (true, waiting.arrive(id).flatMap { sockets[$0] })
        }
        evicted?.close()
        defer {
            lock.withLock {
                waiting.leave(id)
                sockets[id] = nil
            }
            socket.close()
        }
        guard admitted else { return }

        let reader = HeadReader(socket: socket, limit: limits.maximumHeadBytes, timeout: limits.headTimeout)
        guard let first = await reader.next() else { return }
        var verdict = Self.verdict(of: first, target: target, secret: secret)
        if verdict == .noCredential {
            guard (try? await socket.write(Self.proxyAuthenticationRequired)) != nil, let second = await reader.next() else { return }
            verdict = Self.verdict(of: second, target: target, secret: secret)
        }
        guard verdict == .authorized else { return }
        lock.withLock { waiting.leave(id) }

        guard admitStream() else {
            try? await socket.write(Self.serviceUnavailable)
            return
        }
        defer { lock.withLock { openStreams -= 1 } }
        guard let stream = try? await opener.openStream() else {
            try? await socket.write(Self.serviceUnavailable)
            return
        }
        guard (try? await socket.write(Self.connectionEstablished)) != nil else {
            await stream.reset(code: RemoteAccessTunnel.StreamCode.aborted.rawValue)
            await stream.stop(code: RemoteAccessTunnel.StreamCode.aborted.rawValue)
            return
        }
        await BridgedConnection(socket: socket, stream: stream, onHostRefused: onHostRefused).run(leftover: reader.remainder)
    }

    private func admitStream() -> Bool {
        lock.withLock {
            let now = ContinuousClock.now
            openedAt.removeAll { now - $0 >= limits.minute }
            guard !stopped, openStreams < limits.maximumStreams, openedAt.count < limits.maximumStreamsPerMinute else { return false }
            openStreams += 1
            opened += 1
            openedAt.append(now)
            return true
        }
    }

    // MARK: Heads

    static let proxyAuthenticationRequired = Data(
        "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"agentland\"\r\nContent-Length: 0\r\n\r\n".utf8)
    static let connectionEstablished = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    static let serviceUnavailable = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    enum Verdict: Equatable {
        /// `CONNECT` to the paired address with the bridge's credential.
        case authorized
        /// `CONNECT` to the paired address without a credential: the first head, answered with 407.
        case noCredential
        /// Anything else.
        case refused
    }

    /// What the bridge does with one request head (up to and including its blank line).
    static func verdict(of head: Data, target: HostEndpoint, secret: String) -> Verdict {
        // Bytes, not characters: "\r\n" is one Character in Swift.
        guard head.allSatisfy({ (32...126).contains($0) || $0 == 13 || $0 == 10 || $0 == 9 }), head.count > 4,
              head.suffix(4).elementsEqual([13, 10, 13, 10]) else { return .refused }
        let lines = String(decoding: head.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "CONNECT", request[2] == "HTTP/1.1", authority(String(request[1])) == target else {
            return .refused
        }
        var credential: Substring?
        for line in lines.dropFirst() {
            guard !line.contains("\r"), !line.contains("\n"), let colon = line.firstIndex(of: ":") else { return .refused }
            guard line[..<colon].lowercased() == "proxy-authorization" else { continue }
            guard credential == nil else { return .refused }
            credential = line[line.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
        }
        guard let credential else { return .noCredential }
        let parts = credential.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)) else { return .refused }
        return constantTimeEqual(decoded, Data((RemoteAccessTunnel.Bridge.username + ":" + secret).utf8)) ? .authorized : .refused
    }

    /// `host:port` as `CONNECT` names it, an IPv6 address in brackets.
    static func authority(_ value: String) -> HostEndpoint? {
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
              value[value.index(after: colon)...].allSatisfy(\.isNumber) else { return nil }
        let host = value[..<colon]
        if host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")) { return nil }
        return HostEndpoint(host: String(host), port: port)
    }

    /// Compares every byte whatever differs first.
    static func constantTimeEqual(_ first: Data, _ second: Data) -> Bool {
        let a = [UInt8](first), b = [UInt8](second)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

/// Reads request heads from one connection, each ending with a blank line, within the bridge's size and
/// time limits. A late head closes the connection.
private final class HeadReader: @unchecked Sendable {
    let socket: LoopbackSocket
    let limit: Int
    let timeout: Duration
    /// Bytes read after the last head (the start of the next one, or of the TLS inside).
    private(set) var remainder = Data()

    init(socket: LoopbackSocket, limit: Int, timeout: Duration) {
        self.socket = socket; self.limit = limit; self.timeout = timeout
    }

    func next() async -> Data? {
        let socket = self.socket, timeout = self.timeout
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { socket.close() }
        }
        defer { deadline.cancel() }
        let blank = Data("\r\n\r\n".utf8)
        while true {
            if let end = remainder.range(of: blank) {
                guard end.upperBound - remainder.startIndex <= limit else { return nil }
                let head = Data(remainder[remainder.startIndex..<end.upperBound])
                remainder = Data(remainder[end.upperBound...])
                return head
            }
            guard remainder.count < limit, let more = try? await socket.read(max: limit - remainder.count), !more.isEmpty else { return nil }
            remainder.append(more)
        }
    }
}

/// One connection the bridge let through and its stream, until both directions have ended.
private final class BridgedConnection: @unchecked Sendable {
    let socket: LoopbackSocket
    let stream: any TunnelStream
    let ends: EndsState

    init(socket: LoopbackSocket, stream: any TunnelStream, onHostRefused: @escaping @Sendable () -> Void) {
        self.socket = socket
        self.stream = stream
        ends = EndsState(socket: socket, stream: stream, onHostRefused: onHostRefused)
    }

    func run(leftover: Data) async {
        let stream = self.stream, ends = self.ends
        let watcher = Task {
            if let code = await stream.stopped() { await ends.handle(.streamStopped(code: code)) }
        }
        async let up: Void = sending(leftover: leftover)
        async let down: Void = receiving()
        _ = await (up, down)
        watcher.cancel()
    }

    /// The socket's reads into the stream's sending side.
    private func sending(leftover: Data) async {
        if !leftover.isEmpty, (try? await stream.write(leftover)) == nil {
            await ends.handle(.streamStopped(code: 0))
        }
        while true {
            let data: Data
            do {
                data = try await socket.read(max: RemoteAccessTunnel.Bridge.chunkBytes)
            } catch {
                await ends.handle(.socketReadFailed)
                return
            }
            if data.isEmpty {
                await ends.handle(.socketEnded)
                return
            }
            if await ends.dropping { continue }
            if (try? await stream.write(data)) == nil {
                await ends.handle(.streamStopped(code: 0))
            }
        }
    }

    /// The stream's receiving side into the socket's writes.
    private func receiving() async {
        while true {
            switch await stream.read(max: RemoteAccessTunnel.Bridge.chunkBytes) {
            case let .data(data):
                if (try? await socket.write(data)) == nil {
                    await ends.handle(.socketWriteFailed)
                    return
                }
            case .end:
                await ends.handle(.streamEnded)
                return
            case let .reset(code):
                await ends.handle(.streamReset(code: code))
                return
            case .lost:
                await ends.handle(.streamReset(code: RemoteAccessTunnel.StreamCode.aborted.rawValue))
                return
            }
        }
    }
}

/// `StreamEnds` and its actions for one connection. Stream calls run on their own: iroh holds a stream
/// half's lock through a pending read or write, so a stop or reset waits for it, and the other direction
/// must go on meanwhile.
private actor EndsState {
    private var ends = RemoteAccessTunnel.StreamEnds()
    private(set) var dropping = false
    private var reportedRefusal = false
    private let socket: LoopbackSocket
    private let stream: any TunnelStream
    private let onHostRefused: @Sendable () -> Void

    init(socket: LoopbackSocket, stream: any TunnelStream, onHostRefused: @escaping @Sendable () -> Void) {
        self.socket = socket; self.stream = stream; self.onHostRefused = onHostRefused
    }

    func handle(_ event: RemoteAccessTunnel.StreamEnds.Event) {
        let actions = ends.handle(event)
        if ends.refusedByHost, !reportedRefusal {
            reportedRefusal = true
            onHostRefused()
        }
        let stream = self.stream
        for action in actions {
            switch action {
            case .finishStream: Task { await stream.finish() }
            case let .resetStream(code): Task { await stream.reset(code: code.rawValue) }
            case let .stopStream(code): Task { await stream.stop(code: code.rawValue) }
            case .dropSocketInput: dropping = true
            case .shutdownSocketOutput: socket.shutdownOutput()
            case .abortSocket: socket.abort()
            case .close: socket.close()
            }
        }
    }
}
