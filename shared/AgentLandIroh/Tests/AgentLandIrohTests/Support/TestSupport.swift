import AgentLandIroh
import Darwin
import Foundation
import Synchronization
import XCTest

let tunnelALPN = Data("agentland/tunnel/1".utf8)

extension EndpointOptions {
    /// Loopback test endpoint: minimal preset (no n0 relays, DNS or publishing;
    /// also the default when the preset is left unset). This iroh has no port
    /// mapper, so no endpoint can ask the router for a mapping.
    static func test(
        alpns: [Data]? = nil,
        relayMode: RelayMode = RelayMode.disabled(),
        relayTlsRoots: RelayTlsRoots? = nil,
        bindPort: UInt16? = nil,
        externalAddrs: [String]? = nil
    ) -> EndpointOptions {
        EndpointOptions(
            preset: presetMinimal(),
            alpns: alpns,
            relayMode: relayMode,
            bindPort: bindPort,
            relayTlsRoots: relayTlsRoots,
            externalAddrs: externalAddrs
        )
    }
}

struct TimedOut: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "no result within \(seconds) s" }
}

/// Runs `operation` and returns its result, or throws `TimedOut` after
/// `seconds`. iroh's FFI calls cannot be cancelled, so a late operation keeps
/// running in the background and its result is dropped.
func within<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let settled = Mutex(false)
    let claim: @Sendable () -> Bool = {
        settled.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
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
            if claim() { continuation.resume(throwing: TimedOut(seconds: seconds)) }
        }
    }
}

/// Polls `condition` every 20 ms until it holds or `seconds` pass.
func eventually(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The endpoint's IPv4 socket as a loopback address, so tests dial over lo0.
func loopbackAddr(of endpoint: Endpoint) throws -> EndpointAddr {
    EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: ["127.0.0.1:\(try ipv4Port(of: endpoint))"])
}

/// The endpoint's IPv6 socket as a loopback address (::1): another source
/// than 127.0.0.1 for the gate's per-source limit.
func loopbackAddr6(of endpoint: Endpoint) throws -> EndpointAddr {
    let port = try XCTUnwrap(
        endpoint.boundSockets().first { $0.hasPrefix("[::]:") }?.split(separator: ":").last,
        "no IPv6 socket in \(endpoint.boundSockets())"
    )
    return EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: ["[::1]:\(port)"])
}

/// The port of the endpoint's IPv4 socket.
func ipv4Port(of endpoint: Endpoint) throws -> UInt16 {
    let port = try XCTUnwrap(
        endpoint.boundSockets().first { $0.hasPrefix("0.0.0.0:") }?.split(separator: ":").last,
        "no IPv4 socket in \(endpoint.boundSockets())"
    )
    return try XCTUnwrap(UInt16(port))
}

func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    return address
}

/// A socket bound to 127.0.0.1 on a port the kernel picks.
func boundLoopbackSocket(_ type: Int32) throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var address = loopbackAddress(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard bound else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        close(fd)
        throw error
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}

/// A TCP port on 127.0.0.1 that takes connections into its backlog and never
/// answers: something for iroh's relay client to connect to.
final class SilentTCPListener {
    let port: UInt16
    private let fd: Int32

    init() throws {
        (fd, port) = try boundLoopbackSocket(SOCK_STREAM)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit { close(fd) }
}

/// Forwards UDP between one client and `target` on loopback: every datagram
/// from the client, but only the first `serverDatagrams` from the target. With
/// 1 the server's QUIC retry reaches the client and its handshake reply does
/// not, so the server keeps a handshake in progress until it times out.
/// Call `stop()` when done: the forwarding thread holds the proxy until then.
final class StallingUDPProxy: @unchecked Sendable {
    let port: UInt16
    private let front: Int32
    private let back: Int32
    private let stopped = Mutex(false)
    private let finished = DispatchSemaphore(value: 0)

    init(target: UInt16, serverDatagrams: Int) throws {
        (front, port) = try boundLoopbackSocket(SOCK_DGRAM)
        do {
            (back, _) = try boundLoopbackSocket(SOCK_DGRAM)
        } catch {
            close(front)
            throw error
        }
        let (front, back) = (front, back)
        Thread.detachNewThread { [self] in
            var client = sockaddr_storage()
            var clientLength = socklen_t(0)
            var target = loopbackAddress(port: target)
            var forwarded = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var fds = [pollfd(fd: front, events: Int16(POLLIN), revents: 0), pollfd(fd: back, events: Int16(POLLIN), revents: 0)]
            while !self.stopped.withLock({ $0 }) {
                guard poll(&fds, 2, 50) > 0 else { continue }
                if fds[0].revents & Int16(POLLIN) != 0 {
                    clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    let count = withUnsafeMutablePointer(to: &client) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(front, &buffer, buffer.count, 0, $0, &clientLength)
                        }
                    }
                    if count > 0 {
                        _ = withUnsafePointer(to: &target) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(back, buffer, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
                if fds[1].revents & Int16(POLLIN) != 0 {
                    let count = recv(back, &buffer, buffer.count, 0)
                    if count > 0, forwarded < serverDatagrams, clientLength > 0 {
                        forwarded += 1
                        _ = withUnsafePointer(to: &client) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(front, buffer, count, 0, $0, clientLength)
                            }
                        }
                    }
                }
            }
            close(front)
            close(back)
            self.finished.signal()
        }
    }

    /// `endpoint`'s address through this proxy (127.0.0.1 and the proxy's port).
    func addr(of endpoint: Endpoint) -> EndpointAddr {
        EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: ["127.0.0.1:\(port)"])
    }

    func stop() {
        let alreadyStopped = stopped.withLock { done in
            defer { done = true }
            return done
        }
        if !alreadyStopped { finished.wait() }
    }
}

/// A port that was free a moment ago (the kernel picks it; then it is released).
func freePort(_ type: Int32) throws -> UInt16 {
    let (fd, port) = try boundLoopbackSocket(type)
    close(fd)
    return port
}

/// Runs a command line tool and fails with its output if it does not succeed.
@discardableResult
func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    // Not waitUntilExit(): it waits on this thread's run loop (see TestRelay).
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    exited.wait()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "run", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")): \(text)"
        ])
    }
    return text
}
