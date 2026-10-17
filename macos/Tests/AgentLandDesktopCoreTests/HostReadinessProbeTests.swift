import Darwin
import XCTest
import Vision
import AgentLandPairing
import AgentLandDesktopCore
@testable import AgentLandDesktop

final class HostReadinessProbeTests: XCTestCase {
    @MainActor
    func testGoHostHealthRequiresTheActualCertificateAndPublishesBonjour() async throws {
        guard ProcessInfo.processInfo.environment["AGENTLAND_TEST_HOST_READINESS"] == "1" else {
            throw XCTSkip("Opt in to a temporary local HTTPS host with AGENTLAND_TEST_HOST_READINESS=1")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let binary = temporary.appendingPathComponent("agentland-host")
        try run("/usr/bin/env", ["go", "-C", root.appendingPathComponent("desktop").path,
                                  "build", "-o", binary.path, "./cmd/agentland-host"])
        let state = temporary.appendingPathComponent("host.json")
        let certs = temporary.appendingPathComponent("certs")
        let hostname = HostController.defaultAdvertisedHost()
        let loopbackOnlyHostname = "readiness-\(UUID().uuidString).invalid"
        let port = try unusedPort()
        try run(binary.path, ["tls", "init", "--directory", certs.path, "--hosts", "\(hostname),\(loopbackOnlyHostname)"])
        try run(binary.path, ["init", "--state", state.path, "--opencode-url", "http://127.0.0.1:4197",
                              "--password-env", "AGENTLAND_TEST_ADAPTER_PASSWORD", "--project", "test=Test=\(temporary.path)"])
        let certificate = certs.appendingPathComponent("server.crt")
        let serviceName = "AgentLand Test \(UUID().uuidString.prefix(8))"
        let listener = "0.0.0.0:\(port)"
        let plan = try HostAdvertisingConfiguration(name: serviceName, listenAddress: listener,
                                                    advertisedHost: loopbackOnlyHostname, certificatePath: certificate.path)
        var command = HostCommand(arguments: ["serve", "--state", state.path, "--listen", "0.0.0.0:\(port)",
                                              "--cert", certificate.path, "--key", certs.appendingPathComponent("server.key").path])
        command.environment["AGENTLAND_TEST_ADAPTER_PASSWORD"] = "disposable-test-secret"
        let lifecycle = HostLifecycle(processFactory: { ProcessHostProcess(command: $0, executableURL: binary) })
        try await lifecycle.start(command)
        do {
        var ready = false
        for _ in 0..<12 {
            if await HostReadinessProbe.isReady(plan.advertisement, localListener: listener) { ready = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(ready, "The temporary Go HTTPS host should pass the pinned health probe")
        let wrongPin = try HostAdvertisement(name: plan.advertisement.name, address: plan.advertisement.address,
                                             certificateSHA256: String(repeating: "0", count: 64))
        let wrongPinReady = await HostReadinessProbe.isReady(wrongPin, localListener: listener)
        XCTAssertFalse(wrongPinReady)
        let wrongCertificateHostname = try HostAdvertisement(name: serviceName,
            address: "https://mismatch.invalid:\(port)", certificateSHA256: plan.advertisement.certificateSHA256)
        let wrongCertificateHostnameReady = await HostReadinessProbe.isReady(wrongCertificateHostname, localListener: listener)
        XCTAssertFalse(wrongCertificateHostnameReady)
        let discoveredIP = localIPv4()
        XCTAssertNotNil(discoveredIP, "A non-loopback interface is needed for the wrong-hostname check")
        if let localIP = discoveredIP {
            let wrongHostname = try HostAdvertisement(name: serviceName,
                address: "https://\(localIP):\(port)", certificateSHA256: plan.advertisement.certificateSHA256)
            let wrongHostnameReady = await HostReadinessProbe.isReady(wrongHostname)
            XCTAssertFalse(wrongHostnameReady)
        }

        let observer = BonjourObservation(name: serviceName)
        let browser = NetServiceBrowser()
        browser.delegate = observer
        browser.searchForServices(ofType: HostAdvertisement.serviceType, inDomain: HostAdvertisement.serviceDomain)
        let publisher = HostDiscoveryPublisher()
        defer { publisher.stop(); browser.stop() }
        var confirmedPublication = false
        var failedPublication = false
        publisher.onPublicationChange = { available, failed in
            confirmedPublication = available
            failedPublication = failed
        }
        publisher.publish(plan.advertisement, port: port)
        for _ in 0..<30 where !observer.found {
            try await Task.sleep(for: .milliseconds(200))
        }
        for _ in 0..<30 where observer.resolvedAdvertisement == nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(confirmedPublication)
        XCTAssertFalse(failedPublication)
        XCTAssertTrue(observer.found, "The local Bonjour browser should see the published service")
        XCTAssertEqual(observer.resolvedAdvertisement, plan.advertisement)
        XCTAssertEqual(observer.txtKeys, Set(["v", "url", "fp"]))
        publisher.stop()
        for _ in 0..<30 where !observer.removed {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(observer.removed, "The local Bonjour browser should see the service withdrawn")
        browser.stop()
        try await lifecycle.stop()
        let afterStopReady = await HostReadinessProbe.isReady(plan.advertisement, localListener: listener)
        XCTAssertFalse(afterStopReady)
        } catch {
            try? await lifecycle.stop()
            throw error
        }
    }

    @MainActor
    func testQRImageDecodesToExactInvitation() throws {
        let advertisement = try HostAdvertisement(name: "Studio Mac", address: "https://studio-mac.local:9841",
                                                  certificateSHA256: String(repeating: "a", count: 64))
        let invitation = try PairingInvitation(advertisement: advertisement, code: "0123456789",
                                               expiresAt: Date().addingTimeInterval(600))
        let payload = try invitation.encoded()
        let image = try XCTUnwrap(QRCodeImage.renderedImage(value: payload))
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        XCTAssertEqual(request.results?.first?.payloadStringValue, payload)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        _ = try ProcessCommandRunner(binaryURL: URL(fileURLWithPath: executable), timeout: 30)
            .run(HostCommand(arguments: arguments))
    }

    private func unusedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(0))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard got == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func localIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        return nil
    }
}

@MainActor
private final class BonjourObservation: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    let name: String
    var found = false
    var removed = false
    var resolvedAdvertisement: HostAdvertisement?
    var txtKeys: Set<String> = []
    private var foundService: NetService?

    init(name: String) { self.name = name }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = service.name
        let delivered = SendableService(value: service)
        Task { @MainActor [weak self] in
            guard let self, name == self.name else { return }
            self.foundService = delivered.value
            delivered.value.delegate = self
            delivered.value.resolve(withTimeout: 3)
            self.found = true
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor [weak self] in
            guard let self, name == self.name else { return }
            self.foundService?.delegate = nil
            self.foundService = nil
            self.removed = true
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let record = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let advertisement = try? HostAdvertisement(name: name, txtRecord: record)
        Task { @MainActor [weak self] in
            guard let self, name == self.name else { return }
            self.resolvedAdvertisement = advertisement
            self.txtKeys = Set(record.keys)
        }
    }
}

private struct SendableService: @unchecked Sendable {
    let value: NetService
}
