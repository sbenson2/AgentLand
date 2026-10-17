import AgentLandIroh
import Darwin
import Foundation
import IrohSendRecorder
import XCTest

/// AgentLand owns every router mapping, so iroh must send nothing to the
/// router: no SSDP (UPnP discovery, UDP 1900) and nothing to NAT-PMP or PCP
/// (UDP 5351, announcements on 5350). This iroh is built without its port
/// mapper (third_party/iroh-ffi patch 0001), so no option can turn one on; these
/// tests check that an endpoint whose options leave everything unset sends
/// nothing there.
///
/// `IrohSendRecorder` sees every connect/send the test bundle makes, which
/// includes the statically linked iroh library, before the system does. Each
/// test also watches a port iroh does connect to, so an empty record for the
/// router's ports means something.
///
/// Run the package tests under `Tests/router-ports-denied.sb` (see README.md),
/// which makes the system refuse those ports whatever a test does.
final class PortMapperTests: XCTestCase {
    private static let routerPorts: [UInt16] = [1900, 5350, 5351]

    override func setUp() async throws {
        let installed = iroh_send_recorder_install(".xctest/")
        XCTAssertGreaterThan(installed, 0, "the recorder found no connect/send imports in the test bundle")
        watch(Self.routerPorts)
        // The recorder sees a send from this bundle (under the profile the
        // system refuses it, so the probe reaches nothing).
        _ = Self.probeRouterPort()
        XCTAssertEqual(Self.recorded(), ["sendto 127.0.0.1:5351"])
        iroh_send_recorder_reset()
    }

    override func tearDown() async throws {
        iroh_send_recorder_reset()
    }

    /// No relay needed: the endpoint binds (when a port mapper would ask for
    /// its first mapping), its relay client connects to a listener that never
    /// answers, and it runs 3 s more.
    func testUnsetOptionsSendNothingToTheRouter() async throws {
        let listener = try SilentTCPListener()
        watch(Self.routerPorts + [listener.port])
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            relayMode: RelayMode.customFromUrls(urls: ["http://127.0.0.1:\(listener.port)"])
        ))
        try await Task.sleep(for: .seconds(3))
        try await endpoint.close()

        let entries = Self.recorded()
        XCTAssertTrue(
            entries.contains("connect 127.0.0.1:\(listener.port)"),
            "the recorder did not see iroh's own connect, so it proves nothing: \(entries)"
        )
        XCTAssertEqual(Self.routerEntries(entries), [], "iroh sent to the router's port-mapping ports")
    }

    /// With a working relay the endpoint gets online and runs its network
    /// reports (when a port mapper asks again), and still sends nothing there.
    func testUnsetOptionsWithARelaySendNothingToTheRouter() async throws {
        let relay = try TestRelay.startHTTP()
        defer { relay.stop() }
        let relayPort = try XCTUnwrap(URL(string: relay.url)?.port.flatMap { UInt16(exactly: $0) })
        watch(Self.routerPorts + [relayPort])
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            relayMode: RelayMode.customFromUrls(urls: [relay.url])
        ))
        try await within(10) { await endpoint.online() }
        try await Task.sleep(for: .seconds(3))
        XCTAssertNotNil(endpoint.addr().relayUrl())
        try await endpoint.close()

        let entries = Self.recorded()
        XCTAssertTrue(entries.contains("connect 127.0.0.1:\(relayPort)"), "\(entries)")
        XCTAssertEqual(Self.routerEntries(entries), [], "iroh sent to the router's port-mapping ports")
    }

    private func watch(_ ports: [UInt16]) {
        ports.withUnsafeBufferPointer {
            iroh_send_recorder_watch_ports($0.baseAddress, Int32($0.count))
        }
        iroh_send_recorder_reset()
    }

    /// Sends one byte to 127.0.0.1:5351 and returns errno (0 when it was sent).
    /// Under the profile the system refuses it with EPERM.
    private static func probeRouterPort() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var address = loopbackAddress(port: 5351)
        var byte: UInt8 = 0
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent < 0 ? errno : 0
    }

    private static func routerEntries(_ entries: [String]) -> [String] {
        entries.filter { entry in routerPorts.contains { entry.hasSuffix(":\($0)") } }
    }

    /// Every recorded attempt (the recorder keeps the first 64).
    private static func recorded() -> [String] {
        let count = Int(iroh_send_recorder_count())
        XCTAssertLessThanOrEqual(count, 64, "the recorder kept only the first 64 of \(count) attempts")
        return (0..<min(count, 64)).map { index in
            var buffer = [CChar](repeating: 0, count: 128)
            _ = iroh_send_recorder_entry(Int32(index), &buffer, buffer.count)
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
