import AgentLandCore
import CryptoKit
import Foundation
import Network
import Security
import Synchronization
import XCTest
@testable import AgentLandRemoteAccess

// MARK: A TLS server on loopback

/// An HTTPS server on 127.0.0.1 standing in for the host behind the tunnel: a throwaway P-256
/// certificate for `name` made with /usr/bin/openssl, its identity imported in memory only (never into
/// a keychain), and one answer, `GET /v1/health`. It listens on loopback only.
final class TLSTestServer: @unchecked Sendable {
    let port: UInt16
    let certificateSHA256: String
    private let listener: NWListener
    private let directory: URL
    private let requests = Locked<[String]>([])

    var paths: [String] { requests.withLock { $0 } }

    init(name: String) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let openssl = "/usr/bin/openssl"
        try run(openssl, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "server.key"], in: directory)
        try run(openssl, ["req", "-x509", "-new", "-key", "server.key", "-sha256", "-days", "2", "-subj", "/CN=\(name)",
                          "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "keyUsage=critical,digitalSignature",
                          "-addext", "extendedKeyUsage=serverAuth", "-addext", "subjectAltName=DNS:\(name)", "-out", "server.pem"], in: directory)
        try run(openssl, ["x509", "-in", "server.pem", "-outform", "DER", "-out", "server.der"], in: directory)
        try run(openssl, ["pkcs12", "-export", "-inkey", "server.key", "-in", "server.pem", "-passout", "pass:agentland",
                          "-out", "server.p12"], in: directory)
        let der = try Data(contentsOf: directory.appendingPathComponent("server.der"))
        certificateSHA256 = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "agentland", kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: directory.appendingPathComponent("server.p12")) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            throw TestFailure("could not import the test identity: \(status)")
        }
        let identity = identityValue as! SecIdentity
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let requests = self.requests
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.serve(connection, requests: requests)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Locked(false)
            listener.stateUpdateHandler = { state in
                let port = listener.port?.rawValue
                switch state {
                case .ready:
                    if once.withLock({ let first = !$0; $0 = true; return first }) { continuation.resume(returning: port ?? 0) }
                case let .failed(error):
                    if once.withLock({ let first = !$0; $0 = true; return first }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }

    /// One request per connection: its head, then the answer and the connection's end.
    private static func serve(_ connection: NWConnection, requests: Locked<[String]>, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { data, _, complete, error in
            var head = buffer
            if let data { head.append(data) }
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { serve(connection, requests: requests, buffer: head) }
                return
            }
            let line = String(decoding: head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            requests.withLock { $0.append(path) }
            let body = path == "/v1/health" ? #"{"status":"ok","protocolVersion":1}"# : #"{"error":{"code":"not_found","message":"Route not found"}}"#
            let status = path == "/v1/health" ? "200 OK" : "404 Not Found"
            let answer = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(answer.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// A value behind a lock that closures can share.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@discardableResult
func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw TestFailure("\(tool) \(arguments.joined(separator: " ")): \(text)") }
    return text
}

// MARK: Streams

/// A stream whose other end is a TCP connection on loopback (the TLS test server), standing in for the
/// Mac's bridge: finishing shuts the connection's sending side, a reset aborts it.
final class LoopbackStream: TunnelStream, @unchecked Sendable {
    let socket: LoopbackSocket

    init(port: UInt16) async throws { socket = try await LoopbackSocket.connect(port: port) }

    func write(_ data: Data) async throws { try await socket.write(data) }
    func finish() async { socket.shutdownOutput() }
    func reset(code: UInt64) async { socket.abort() }
    func stop(code: UInt64) async {}
    func stopped() async -> UInt64? { nil }
    func read(max: Int) async -> TunnelStreamRead {
        guard let data = try? await socket.read(max: max) else { return .lost }
        return data.isEmpty ? .end : .data(data)
    }
}

struct LoopbackOpener: TunnelStreamOpening {
    let port: UInt16
    let opened = Locked(0)
    func openStream() async throws -> any TunnelStream {
        opened.withLock { $0 += 1 }
        return try await LoopbackStream(port: port)
    }
}

/// A stream the test drives: what arrives from the Mac is scripted, and what the bridge does is recorded.
final class ScriptedStream: TunnelStream, @unchecked Sendable {
    enum Call: Equatable { case write(Data), finish, reset(UInt64), stop(UInt64) }

    private let lock = NSLock()
    private var log: [Call] = []
    private var failWrites = false
    private let incoming: AsyncStream<TunnelStreamRead>
    private let feed: AsyncStream<TunnelStreamRead>.Continuation
    private let stops: AsyncStream<UInt64?>
    private let stopFeed: AsyncStream<UInt64?>.Continuation
    private var iterator: AsyncStream<TunnelStreamRead>.AsyncIterator

    init() {
        (incoming, feed) = AsyncStream.makeStream()
        (stops, stopFeed) = AsyncStream.makeStream()
        iterator = incoming.makeAsyncIterator()
    }

    var calls: [Call] { lock.withLock { log } }
    var written: Data { calls.reduce(into: Data()) { if case let .write(data) = $1 { $0.append(data) } } }

    /// What the Mac sends next.
    func receive(_ read: TunnelStreamRead) { feed.yield(read) }
    /// The Mac stops the stream's sending side: writes fail from now on.
    func peerStops(code: UInt64) {
        lock.withLock { failWrites = true }
        stopFeed.yield(code)
    }

    func write(_ data: Data) async throws {
        let fails = lock.withLock { () -> Bool in
            if !failWrites { log.append(.write(data)) }
            return failWrites
        }
        if fails { throw TestFailure("stopped") }
    }
    func finish() async { lock.withLock { log.append(.finish) } }
    func reset(code: UInt64) async { lock.withLock { log.append(.reset(code)) } }
    func stop(code: UInt64) async { lock.withLock { log.append(.stop(code)) } }
    func stopped() async -> UInt64? {
        for await code in stops { return code }
        return nil
    }
    func read(max: Int) async -> TunnelStreamRead {
        var copy = lock.withLock { iterator }
        let next = await copy.next() ?? .lost
        lock.withLock { iterator = copy }
        return next
    }
}

final class ScriptedOpener: TunnelStreamOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [ScriptedStream] = []
    var fails = false

    var streams: [ScriptedStream] { lock.withLock { made } }

    func openStream() async throws -> any TunnelStream {
        try lock.withLock {
            if fails { throw TestFailure("the connection is closed") }
            let stream = ScriptedStream()
            made.append(stream)
            return stream
        }
    }
}

// MARK: A raw client of the bridge

/// A connection to the bridge that speaks its heads by hand, like another app on the phone would.
final class RawClient: @unchecked Sendable {
    let socket: LoopbackSocket

    init(port: UInt16) async throws { socket = try await LoopbackSocket.connect(port: port) }

    func send(_ text: String) async throws { try await socket.write(Data(text.utf8)) }

    enum Chunk: Sendable, Equatable { case data(Data), end, failed }

    /// One read, or nil when `seconds` pass first (the read then goes on; read no more after that).
    func next(max: Int = 65536, within seconds: Double) async -> Chunk? {
        let socket = self.socket
        return await IrohPhoneTunnel.race(.milliseconds(Int(seconds * 1000))) { () async -> Chunk? in
            do {
                let data = try await socket.read(max: max)
                return data.isEmpty ? .end : .data(data)
            } catch {
                return .failed
            }
        }
    }

    /// Reads until the bridge ends the connection (`closed`: FIN or reset) or `seconds` pass.
    func readAll(within seconds: Double = 2) async -> (data: Data, closed: Bool, reset: Bool) {
        var data = Data()
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            guard let chunk = await next(within: max(0.01, deadline.timeIntervalSinceNow)) else { return (data, false, false) }
            switch chunk {
            case let .data(bytes): data.append(bytes)
            case .end: return (data, true, false)
            case .failed: return (data, true, true)
            }
        }
    }

    /// Reads one answer head, a byte at a time so nothing after it is taken.
    func readHead(within seconds: Double = 2) async -> String? {
        var data = Data()
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let end = data.range(of: Data("\r\n\r\n".utf8)) { return String(decoding: data[..<end.upperBound], as: UTF8.self) }
            guard case let .data(byte)? = await next(max: 1, within: max(0.01, deadline.timeIntervalSinceNow)) else { return nil }
            data.append(byte)
        }
    }

    func close() { socket.close() }
}

func basic(_ secret: String) -> String {
    Data("agentland:\(secret)".utf8).base64EncodedString()
}

/// Polls `condition` every 10 ms until it holds or `seconds` pass.
func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
