import Darwin
import Foundation
import Synchronization
import XCTest
import AgentLandCore
import AgentLandIroh
@testable import AgentLandDesktopCore

/// Remote access end to end on loopback: a real Go host serving its tunnel socket, the Mac's
/// `RemoteAccessService` with its iroh endpoint and bridge, and a phone-side dialer made of
/// AgentLandIroh and AgentLandCore that pairs with its node ID and speaks the host's pinned HTTPS
/// through the tunnel. The mapping goes to `FakeRouter` on loopback; no relay, no n0, no router.
///
/// Opt in with AGENTLAND_TEST_REMOTE_ACCESS=1 (it builds the host with Go), and run it under
/// shared/AgentLandIroh/Tests/router-ports-denied.sb.
final class RemoteAccessEndToEndTests: XCTestCase {
    private var cleanups: [() async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
    }

    func testAPairedPhoneReachesTheHostThroughTheTunnelAndAStrangerIsRefused() async throws {
        guard ProcessInfo.processInfo.environment["AGENTLAND_TEST_REMOTE_ACCESS"] == "1" else {
            throw XCTSkip("Opt in to a temporary host and iroh endpoints on loopback with AGENTLAND_TEST_REMOTE_ACCESS=1")
        }
        let host = try await TemporaryHost.start()
        cleanups.append { await host.stop() }

        // The phone pairs over the host's TCP listener with its node ID and a proof of its key.
        let phoneKey = SecretKey.generate()
        let phoneNode = try XCTUnwrap(IrohNodeID(publicKey: phoneKey.public().toBytes()))
        let code = try host.pairingCode()
        let signature = phoneKey.sign(message: IrohNodeProof.message(purpose: .pair, binding: code, nodeID: phoneNode)).toBytes()
        let claim = try XCTUnwrap(IrohNodeClaim(nodeID: phoneNode, signature: signature))
        let paired = try await host.client(token: "").pair(code: code, deviceName: "Remote Access Test Phone", node: claim)

        // The Mac: its endpoint on a free UDP port, the gate fed by the peers route (held at first), the
        // bridge to the tunnel socket, the mapping to a fake router.
        let router = try FakeRouter(mode: .pcp)
        cleanups.append { router.stop() }
        let records = host.directory.appendingPathComponent("mappings/port-mappings.json")
        let udpPort = try freePort(SOCK_DGRAM)
        let macKeys = InMemoryRemoteAccessKeyStore()
        let macNode = try macKeys.nodeID()
        let routerPort = router.port
        let dependencies = RemoteAccessService.Dependencies(
            port: udpPort, socketPath: host.tunnelSocket, keyStore: macKeys,
            makeMapping: { plan, onChange in
                RemoteAccessMapping(request: try! RemoteAccessPorts.endpointMapping(port: udpPort), gateway: { "192.168.1.1" },
                                    hardwareAddress: { _ in nil },
                                    makeMapper: { _ in
                                        var configuration = try PortMapper.Configuration(gateway: "127.0.0.1", recordsFile: records)
                                        configuration.serverPort = routerPort
                                        return PortMapper(configuration: configuration)
                                    }, plan: plan, onChange: onChange)
            },
            recordDatabase: FakeAddressDatabase())
        let status = Locked(RemoteAccessService.Status())
        let service = RemoteAccessService(settings: .init(), dependencies: dependencies, onStatus: { status.set($0) })
        cleanups.append { await service.shutdown() }
        let session = HeldPeersSession(APIClientRemoteAccessSession(host.client(token: host.sessionToken)))
        await service.activate()
        await service.hostStarted(session, hostID: "0123456789abcdef0123456789abcdef")
        await service.setEnabled(true)
        try await waitFor("the endpoint") { status.value.endpoint == .running }

        let phone = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), secretKey: phoneKey.toBytes(),
                                                                     relayMode: RelayMode.disabled()))
        cleanups.append { try? await phone.close() }
        let macAddress = EndpointAddr(id: try EndpointId.fromBytes(bytes: macNode.publicKey), relayUrl: nil,
                                      addresses: ["127.0.0.1:\(udpPort)"])

        // Until the gate has its first list it cannot tell a paired phone from a stranger: 503.
        let early = try await within(10) { try await phone.connect(addr: macAddress, alpn: RemoteAccessTunnel.alpn) }
        let earlyReason = try await within(10) { await early.closed() }
        XCTAssertTrue(earlyReason.contains("503"), earlyReason)

        session.release()
        try await waitFor("the first list") { session.answered >= 1 }

        // The report reached the host: devices see the switch on and the Mac's node ID.
        try await waitFor("the report") { status.value.reported?.enabled == true }
        let local = try await host.client(token: host.sessionToken).capabilities()
        XCTAssertEqual(local.remoteAccess?.enabled, true)
        XCTAssertEqual(local.remoteAccess?.nodeID, macNode)

        // The paired phone: HTTPS to the host through the tunnel, pinned and validated for the host's name.
        let connection = try await within(10) { try await phone.connect(addr: macAddress, alpn: RemoteAccessTunnel.alpn) }
        let forwarder = try LoopbackForwarder(connection: connection)
        cleanups.append { forwarder.stop() }
        let throughTunnel = host.client(token: paired.token, port: forwarder.port)
        let health = try await throughTunnel.health(timeout: 10)
        XCTAssertEqual(health.status, "ok")
        let capabilities = try await throughTunnel.capabilities()
        XCTAssertEqual(capabilities.remoteAccess?.deviceNodeID, phoneNode, "the host bound the tunnel connection to the phone")
        XCTAssertNil(capabilities.preview, "no preview through the tunnel")
        // Several requests over several streams.
        for _ in 0..<3 { _ = try await host.client(token: paired.token, port: forwarder.port).capabilities() }
        XCTAssertGreaterThanOrEqual(forwarder.streams, 2)

        // Through the tunnel the Mac's own session is never accepted.
        do {
            _ = try await host.client(token: host.sessionToken, port: forwarder.port).capabilities()
            XCTFail("the local session was accepted through the tunnel")
        } catch let error as ClientError {
            if case .server(let code, _) = error { XCTAssertEqual(code, "unauthorized") }
        }

        // A stranger's key: closed with 403 after its handshake, before any stream reaches the host.
        let stranger = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), relayMode: RelayMode.disabled()))
        cleanups.append { try? await stranger.close() }
        let refused = try await within(10) { try await stranger.connect(addr: macAddress, alpn: RemoteAccessTunnel.alpn) }
        let refusedReason = try await within(10) { await refused.closed() }
        XCTAssertTrue(refusedReason.contains("403"), refusedReason)
        XCTAssertFalse(host.audit().contains(strangerPrefix(stranger)), "the host never saw the stranger")
        XCTAssertTrue(host.audit().contains(String(phoneNode.hex.prefix(8))), "the host's audit names the phone's node ID prefix")

        // Turning the switch off reports it off and closes the endpoint.
        await service.setEnabled(false)
        try await waitFor("the off report") { status.value.reported?.enabled == false }
        let after = try await host.client(token: host.sessionToken).capabilities()
        XCTAssertEqual(after.remoteAccess?.enabled, false)
        XCTAssertEqual(router.mappings, [:])
    }

    private func strangerPrefix(_ endpoint: Endpoint) -> String {
        String(endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 15, _ condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(message)", file: file, line: line)
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct TimedOut: Error {}
}

/// Runs `operation`, or throws after `seconds` (an FFI call cannot be cancelled; a late one keeps
/// running and its result is dropped).
func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let settled = Mutex(false)
    let claim: @Sendable () -> Bool = { settled.withLock { done in defer { done = true }; return !done } }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        Task {
            do {
                let value = try await operation()
                if claim() { continuation.resume(returning: value) }
            } catch {
                if claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if claim() { continuation.resume(throwing: RemoteAccessEndToEndTests.TimedOut()) }
        }
    }
}

/// A port on 127.0.0.1 nothing holds right now.
func freePort(_ type: Int32) throws -> UInt16 {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    guard bound else { throw POSIXError(.EADDRINUSE) }
    return UInt16(bigEndian: address.sin_port)
}

/// The host's peers route, with the first answer held until `release()`.
final class HeldPeersSession: RemoteAccessHostSession, @unchecked Sendable {
    private let inner: any RemoteAccessHostSession
    private let state = Mutex<(released: Bool, waiting: [CheckedContinuation<Void, Never>], answered: Int)>((false, [], 0))

    init(_ inner: any RemoteAccessHostSession) { self.inner = inner }

    var answered: Int { state.withLock { $0.answered } }

    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func peers(after version: String?, wait: TimeInterval?) async throws -> RemoteAccessPeers {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.released { return true }
                state.waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        let answer = try await inner.peers(after: version, wait: wait)
        state.withLock { $0.answered += 1 }
        return answer
    }

    func report(_ report: RemoteAccessEndpointReport) async throws -> RemoteAccessCapabilities {
        try await inner.report(report)
    }
}

/// The phone's side of the tunnel for the test: each connection to 127.0.0.1:`port` is copied to a
/// new stream of the iroh connection and back (the phone app's bridge adds its CONNECT secret and
/// limits; here only the test connects).
final class LoopbackForwarder: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let connection: Connection
    private let count = Mutex(0)
    private let stopped = Mutex(false)

    var streams: Int { count.withLock { $0 } }

    init(connection: Connection) throws {
        self.connection = connection
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 && listen(fd, 16) == 0
            }
        }
        guard listening else { close(fd); throw POSIXError(.EADDRINUSE) }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    func stop() {
        stopped.withLock { $0 = true }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func acceptLoop() {
        while !stopped.withLock({ $0 }) {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let socket = TunnelSocket(descriptor: fd)
            Task { await self.forward(socket) }
        }
    }

    private func forward(_ socket: TunnelSocket) async {
        guard let stream = try? await connection.openBi() else {
            socket.abort()
            return
        }
        count.withLock { $0 += 1 }
        let send = stream.send(), receive = stream.recv()
        await withDiscardingTaskGroup { group in
            group.addTask {
                while true {
                    do {
                        guard let data = try await socket.read(maximum: 65536) else {
                            try? await send.finish()
                            return
                        }
                        try await send.writeAll(buf: data)
                    } catch {
                        try? await send.reset(errorCode: 1)
                        return
                    }
                }
            }
            group.addTask {
                while true {
                    do {
                        let data = try await receive.read(sizeLimit: 65536)
                        if data.isEmpty {
                            socket.shutdownOutput()
                            return
                        }
                        try await socket.write(data)
                    } catch {
                        socket.abort()
                        return
                    }
                }
            }
        }
        socket.abort()
    }
}

/// A host built from desktop/ with its own state, certificate and tunnel socket in a temporary folder,
/// listening on 127.0.0.1 only.
struct TemporaryHost: Sendable {
    let directory: URL
    let binary: URL
    let state: URL
    let tunnelSocket: String
    let hostname = "remote-access.test"
    let port: UInt16
    let fingerprint: String
    let sessionToken: String
    let process: Process
    let log: URL

    static func start() async throws -> TemporaryHost {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("al-ra-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("agentland-host")
        try run("/usr/bin/env", ["go", "-C", root.appendingPathComponent("desktop").path, "build", "-o", binary.path, "./cmd/agentland-host"],
                timeout: 600)
        let state = directory.appendingPathComponent("host.json")
        let tunnelSocket = try XCTUnwrap(HostCommandBuilder.tunnelSocketPath(statePath: state.path), "the temporary folder's path is too long")
        let certs = directory.appendingPathComponent("certs")
        let hostname = "remote-access.test"
        let generated = try HostOutputParser.generatedCertificate(
            run(binary.path, ["tls", "init", "--directory", certs.path, "--hosts", hostname]))
        _ = try run(binary.path, ["init", "--state", state.path, "--opencode-url", "http://127.0.0.1:4197",
                                  "--password-env", "AGENTLAND_TEST_ADAPTER_PASSWORD", "--project", "test=Test=\(directory.path)"])
        let port = try freePort(SOCK_STREAM)
        var tokenBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
        let sessionToken = tokenBytes.map { String(format: "%02x", $0) }.joined()
        let log = directory.appendingPathComponent("host.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", "--state", state.path, "--listen", "127.0.0.1:\(port)",
                             "--cert", generated.certificateFile, "--key", generated.keyFile,
                             "--local-session-env", "AGENTLAND_LOCAL_SESSION_TOKEN", "--tunnel-socket", tunnelSocket]
        process.environment = ["AGENTLAND_TEST_ADAPTER_PASSWORD": "disposable-test-secret",
                               "AGENTLAND_LOCAL_SESSION_TOKEN": sessionToken,
                               "PATH": "/usr/bin:/bin", "HOME": directory.path]
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let host = TemporaryHost(directory: directory, binary: binary, state: state, tunnelSocket: tunnelSocket, port: port,
                                 fingerprint: generated.fingerprint, sessionToken: sessionToken, process: process, log: log)
        let deadline = Date().addingTimeInterval(20)
        while true {
            if (try? await host.client(token: sessionToken).health(timeout: 2)) != nil { break }
            guard Date() < deadline, process.isRunning else {
                throw NSError(domain: "TemporaryHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "the host did not start: \(host.audit())"])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return host
    }

    /// A client of the host's pinned HTTPS, over its TCP listener or through `port` (the forwarder).
    func client(token: String, port: UInt16? = nil) -> APIClient {
        APIClient(address: try! ServerAddress(validating: "https://127.0.0.1:\(port ?? self.port)"), token: token,
                  transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint,
                                                 validatedCertificateHost: hostname))
    }

    func pairingCode() throws -> String {
        try Self.run(binary.path, ["pair", "--state", state.path, "--expires", "600s"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the host wrote to standard error (its tunnel audit lines among it).
    func audit() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    func stop() async {
        if process.isRunning {
            process.interrupt()
            for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        try ProcessCommandRunner(binaryURL: URL(fileURLWithPath: executable), timeout: timeout)
            .run(HostCommand(arguments: arguments)).standardOutput
    }
}
