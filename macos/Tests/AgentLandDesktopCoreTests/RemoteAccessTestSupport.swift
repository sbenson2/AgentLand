import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization
import XCTest
import AgentLandCore
import AgentLandNotifications
@testable import AgentLandDesktopCore

// MARK: - A fake tunnel socket host

/// A Unix socket in a temporary folder standing in for the host's tunnel socket: it accepts
/// connections and lets a test read, write, half-close and close each one with blocking calls (run
/// off the main thread).
final class FakeSocketHost: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let listener: Int32
    private let accepted = Mutex<[FakeSocketConnection]>([])

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("al-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("t.sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit {
        close(listener)
        for connection in accepted.withLock({ $0 }) { connection.close() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The next connection, within `timeout` seconds.
    func accept(timeout: TimeInterval = 5) async throws -> FakeSocketConnection {
        let listener = listener
        let fd = try await blocking {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { throw TimedOut() }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }
        let connection = FakeSocketConnection(fd: fd)
        accepted.withLock { $0.append(connection) }
        return connection
    }

    struct TimedOut: Error {}
}

/// One accepted connection of `FakeSocketHost`.
final class FakeSocketConnection: @unchecked Sendable {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }

    /// Exactly `count` bytes (fewer when the peer ends first).
    func read(_ count: Int, timeout: TimeInterval = 5) async throws -> Data {
        let fd = fd
        return try await blocking {
            var data = Data()
            while data.count < count {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { throw FakeSocketHost.TimedOut() }
                var buffer = [UInt8](repeating: 0, count: count - data.count)
                let got = Darwin.read(fd, &buffer, buffer.count)
                if got <= 0 { break }
                data.append(contentsOf: buffer.prefix(got))
            }
            return data
        }
    }

    /// Everything until the peer's end of file.
    func readToEnd(timeout: TimeInterval = 5) async throws -> Data {
        let fd = fd
        return try await blocking {
            var data = Data()
            while true {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { throw FakeSocketHost.TimedOut() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                let got = Darwin.read(fd, &buffer, buffer.count)
                if got <= 0 { return data }
                data.append(contentsOf: buffer.prefix(got))
            }
        }
    }

    /// Writes all of `data`; false when the peer is gone (`EPIPE`).
    @discardableResult
    func write(_ data: Data) async -> Bool {
        let fd = fd
        return (try? await blocking { () -> Bool in
            var offset = 0
            while offset < data.count {
                let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
                if wrote < 0 { return false }
                offset += wrote
            }
            return true
        }) ?? false
    }

    private let closed = Mutex(false)

    func shutdownOutput() { Darwin.shutdown(fd, SHUT_WR) }
    /// Closes the descriptor (once).
    func close() {
        let first = closed.withLock { done in defer { done = true }; return !done }
        if first { Darwin.close(fd) }
    }
}

/// Runs a blocking call on a thread of its own.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

// MARK: - Fake stream sides

/// A stream's sending side that records what the bridge does with it.
final class FakeSendSide: TunnelStreamSending, @unchecked Sendable {
    enum Call: Equatable { case write(Int), finish, reset(UInt64) }
    private let state = Mutex<(calls: [Call], data: Data, stopped: Bool)>(([], Data(), false))

    var calls: [Call] { state.withLock { $0.calls } }
    var data: Data { state.withLock { $0.data } }
    var ended: Call? { calls.last { if case .write = $0 { return false } else { return true } } }

    /// The peer stopped this side: every write from now on fails.
    func stop() { state.withLock { $0.stopped = true } }

    func write(_ data: Data) async throws {
        try state.withLock { state in
            guard !state.stopped else { throw StreamFailure.stopped }
            state.calls.append(.write(data.count))
            state.data.append(data)
        }
    }
    func finish() async throws { state.withLock { $0.calls.append(.finish) } }
    func reset(code: UInt64) async throws { state.withLock { $0.calls.append(.reset(code)) } }
}

/// A stream's receiving side the test feeds: chunks, then its end or a reset. A stop makes a pending
/// read fail, as iroh's does.
final class FakeReceiveSide: TunnelStreamReceiving, @unchecked Sendable {
    enum Item { case data(Data), end, reset, stopped }
    private struct State {
        var items: [Item] = []
        var reader: CheckedContinuation<Item, Never>?
        var stops: [UInt64] = []
    }
    private let state = Mutex(State())

    var stopCodes: [UInt64] { state.withLock { $0.stops } }

    func send(_ data: Data) { deliver(.data(data)) }
    func end() { deliver(.end) }
    func reset() { deliver(.reset) }

    private func deliver(_ item: Item) {
        let reader = state.withLock { state -> CheckedContinuation<Item, Never>? in
            guard let reader = state.reader else {
                state.items.append(item)
                return nil
            }
            state.reader = nil
            return reader
        }
        reader?.resume(returning: item)
    }

    func read(maximum: Int) async throws -> Data {
        let item = await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Item? in
                if !state.items.isEmpty { return state.items.removeFirst() }
                state.reader = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch item {
        case let .data(data): return data
        case .end: return Data()
        case .reset: throw StreamFailure.reset
        case .stopped: throw StreamFailure.stopped
        }
    }

    func stop(code: UInt64) async throws {
        state.withLock { $0.stops.append(code) }
        deliver(.stopped)
    }
}

enum StreamFailure: Error { case stopped, reset }

// MARK: - Fakes for the service

/// An endpoint that records what the service asks of it.
final class FakeEndpoint: RemoteAccessEndpointRunning, @unchecked Sendable {
    let nodeID: IrohNodeID
    let configuration: RemoteAccessEndpointConfiguration
    let events: @Sendable (RemoteAccessEndpointEvent) -> Void
    private let closes: CloseGate?
    private let state = Mutex<(allowed: [Set<Data>], external: [[String]], closed: Bool)>(([], [], false))

    init(nodeID: IrohNodeID, configuration: RemoteAccessEndpointConfiguration, closes: CloseGate? = nil,
         events: @escaping @Sendable (RemoteAccessEndpointEvent) -> Void) {
        self.nodeID = nodeID
        self.configuration = configuration
        self.closes = closes
        self.events = events
    }

    var allowedLists: [Set<Data>] { state.withLock { $0.allowed } }
    var externalAddresses: [String] { state.withLock { $0.external.last ?? [] } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func setAllowed(_ keys: Set<Data>) async { state.withLock { $0.allowed.append(keys) } }
    func setExternalAddresses(_ addresses: [String]) async { state.withLock { $0.external.append(addresses) } }
    func close() async {
        await closes?.pass()
        state.withLock { $0.closed = true }
    }
}

/// Holds endpoint closes while told to, as a close that takes a while (iroh's graceful close) does:
/// the operation that closes waits, and the service's queue with it.
final class CloseGate: @unchecked Sendable {
    private let state = Mutex<(holding: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    /// Closes from now on wait until `release()`.
    func hold() { state.withLock { $0.holding = true } }
    /// How many closes wait.
    var waiting: Int { state.withLock { $0.waiting.count } }
    /// Lets the closes that wait go on, and the later ones pass.
    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holding = false
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }
    /// Lets the close that waited longest go on; later ones still wait.
    func releaseOne() {
        let first = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.waiting.isEmpty ? nil : state.waiting.removeFirst()
        }
        first?.resume()
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let held = state.withLock { state -> Bool in
                guard state.holding else { return false }
                state.waiting.append(continuation)
                return true
            }
            if !held { continuation.resume() }
        }
    }
}

/// A key in memory that can be made unreadable, as the Keychain is when macOS asks again for access
/// (an ad-hoc build's new signature) and the owner denies it; it counts the reads.
final class SwitchableKeyStore: RemoteAccessKeyStoring, @unchecked Sendable {
    private let stored = InMemoryRemoteAccessKeyStore()
    private let state = Mutex((failing: false, reads: 0))

    func fail(_ on: Bool) { state.withLock { $0.failing = on } }
    /// How many times the key was asked for.
    var reads: Int { state.withLock { $0.reads } }
    /// The key's node ID, without asking for the key.
    var node: IrohNodeID { try! stored.nodeID() }

    func secretKey() throws -> Data {
        let failing = state.withLock { state -> Bool in
            state.reads += 1
            return state.failing
        }
        if failing { throw RemoteAccessKeyError.keychain(errSecAuthFailed) }
        return try stored.secretKey()
    }
}

/// Binds `FakeEndpoint`s with the key the service gives, or fails as told.
final class FakeBinder: @unchecked Sendable {
    private let state = Mutex<(bound: [FakeEndpoint], failure: (any Error)?)>(([], nil))
    /// Every endpoint's close passes it.
    let closes = CloseGate()

    var endpoints: [FakeEndpoint] { state.withLock { $0.bound } }
    var current: FakeEndpoint? { endpoints.last }
    var relays: [RemoteAccessRelayChoice] { endpoints.map(\.configuration.relay) }
    func fail(with error: (any Error)?) { state.withLock { $0.failure = error } }

    var binder: RemoteAccessEndpointBinder {
        { [self] configuration, events in
            if let failure = state.withLock({ $0.failure }) { throw failure }
            let endpoint = FakeEndpoint(nodeID: try IrohNodeID(secretKey: configuration.secretKey), configuration: configuration,
                                        closes: closes, events: events)
            state.withLock { $0.bound.append(endpoint) }
            return endpoint
        }
    }
}

/// The host's two remote access routes, answering like the host (`desktop/remote_access.go`) as far
/// as the service needs: reports are numbered, the peers route answers at once without `after` and
/// holds a request with the current version until the list changes.
final class FakeHostSession: RemoteAccessHostSession, @unchecked Sendable {
    private struct State {
        var reports: [RemoteAccessEndpointReport] = []
        var peerRequests: [(after: String?, wait: TimeInterval?)] = []
        var peers: [IrohNodeID] = []
        var version = 1
        var sequence: Int64 = 0
        var lastSeen: RemoteAccessEndpointReport?
        var waiters: [CheckedContinuation<Void, Never>] = []
        var failReports = 0
    }
    private let state = Mutex(State())

    var reports: [RemoteAccessEndpointReport] { state.withLock { $0.reports } }
    var peerRequests: [(after: String?, wait: TimeInterval?)] { state.withLock { $0.peerRequests } }
    func failNextReports(_ count: Int) { state.withLock { $0.failReports = count } }

    /// Replaces the list and wakes waiting requests.
    func setPeers(_ nodeIDs: [IrohNodeID]) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.peers = nodeIDs
            state.version += 1
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func peers(after version: String?, wait: TimeInterval?) async throws -> RemoteAccessPeers {
        let current = state.withLock { state -> String in
            state.peerRequests.append((version, wait))
            return "v\(state.version)"
        }
        if version == current, (wait ?? 0) > 0 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state -> Bool in
                        guard "v\(state.version)" == current else { return true }
                        state.waiters.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let waiters = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    defer { state.waiters.removeAll() }
                    return state.waiters
                }
                waiters.forEach { $0.resume() }
            }
            try Task.checkCancellation()
        }
        return try state.withLock { state in
            let json: [String: Any] = ["version": "v\(state.version)",
                                       "peers": state.peers.enumerated().map { ["deviceId": "device-\($0.offset)", "nodeId": $0.element.hex] }]
            return try JSONDecoder().decode(RemoteAccessPeers.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    func report(_ report: RemoteAccessEndpointReport) async throws -> RemoteAccessCapabilities {
        try state.withLock { state in
            state.reports.append(report)
            if state.failReports > 0 {
                state.failReports -= 1
                throw ClientError.unexpectedStatus(503)
            }
            // Devices see every member but udpPort.
            var seen = report
            seen.udpPort = nil
            if seen != state.lastSeen {
                state.sequence += 1
                state.lastSeen = seen
            }
            return RemoteAccessCapabilities(revision: "r\(state.sequence)", enabled: report.enabled, nodeID: report.nodeID,
                                            directAddresses: report.enabled ? report.directAddresses : [],
                                            fallbackRelay: report.enabled && report.fallbackRelay,
                                            relayURL: report.enabled && report.fallbackRelay ? report.relayURL : nil,
                                            sequence: state.sequence)
        }
    }
}

/// The address record's CloudKit calls in memory, with failures and a held call on request.
final class FakeAddressDatabase: RemoteAccessAddressDatabase, @unchecked Sendable {
    enum Call: Equatable { case save(RemoteAccessAddressRecordContents), delete(String) }
    private struct State {
        var calls: [Call] = []
        var records: [String: RemoteAccessAddressRecordContents] = [:]
        var failures: [any Error] = []
        var account: NoticeAccountStatus = .available
        var hold: CheckedContinuation<Void, Never>?
        var holdNext = false
        var holding = false
    }
    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var records: [String: RemoteAccessAddressRecordContents] { state.withLock { $0.records } }
    var isHolding: Bool { state.withLock { $0.holding } }
    func failNext(_ errors: [any Error]) { state.withLock { $0.failures = errors } }
    func setAccount(_ status: NoticeAccountStatus) { state.withLock { $0.account = status } }
    /// The next save or delete waits until `release()`.
    func holdNext() { state.withLock { $0.holdNext = true } }
    func release() {
        let hold = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.hold = nil; state.holding = false }
            return state.hold
        }
        hold?.resume()
    }

    func accountStatus() async throws -> NoticeAccountStatus { state.withLock { $0.account } }
    func createZone() async throws {}

    func save(_ contents: RemoteAccessAddressRecordContents) async throws {
        try await perform(.save(contents)) { $0.records[contents.hostID] = contents }
    }

    func delete(hostID: String) async throws {
        try await perform(.delete(hostID)) { $0.records[hostID] = nil }
    }

    private func perform(_ call: Call, apply: (inout State) -> Void) async throws {
        let hold = state.withLock { state -> Bool in
            state.calls.append(call)
            defer { state.holdNext = false }
            return state.holdNext
        }
        if hold {
            await withCheckedContinuation { continuation in
                state.withLock { $0.hold = continuation; $0.holding = true }
            }
        }
        try state.withLock { state in
            if !state.failures.isEmpty { throw state.failures.removeFirst() }
            apply(&state)
        }
    }
}

extension IrohNodeID {
    /// A node ID of a fresh key.
    static func random() -> IrohNodeID {
        IrohNodeID(publicKey: SecretKeyBytes.publicKey())!
    }
}

/// Ed25519 public keys from CryptoKit, for node IDs in tests that need no iroh endpoint.
enum SecretKeyBytes {
    static func publicKey() -> Data { Curve25519.Signing.PrivateKey().publicKey.rawRepresentation }
}

/// A clock whose sleeps last until cancelled or released, so a test can act while something waits
/// for its retry.
final class HeldClock: NoticeRelayClock, @unchecked Sendable {
    private struct State {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var sleeps: [TimeInterval] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }
    func now() -> Date { state.withLock { $0.now } }

    /// Ends every sleep in progress.
    func releaseAll() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        state.withLock { $0.sleeps.append(seconds) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if cancelled { continuation.resume() }
            }
        } onCancel: {
            releaseAll()
        }
        try Task.checkCancellation()
        state.withLock { $0.now = $0.now.addingTimeInterval(seconds) }
    }
}

/// A value behind a lock that closures can share (a `Mutex` cannot be captured by copy).
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
