import XCTest
import CryptoKit
import Security
@testable import AgentLandDesktopCore

final class HostAdvertisingConfigurationTests: XCTestCase {
    func testReachableTLSHostAdvertisesActualCertificateAndCapturedPort() throws {
        let certificate = try makeCertificate(host: "studio-mac.local")
        defer { try? FileManager.default.removeItem(at: certificate.deletingLastPathComponent()) }
        let plan = try HostAdvertisingConfiguration(
            name: "Studio Mac", listenAddress: "0.0.0.0:9841",
            advertisedHost: "studio-mac.local", certificatePath: certificate.path
        )

        XCTAssertEqual(plan.advertisement.address, "https://studio-mac.local:9841")
        XCTAssertEqual(plan.port, 9841)
        let pem = try String(contentsOf: certificate, encoding: .utf8)
        let body = pem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        let expectedFingerprint = SHA256.hash(data: Data(base64Encoded: body)!).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(plan.advertisement.certificateSHA256, expectedFingerprint)
    }

    func testInvalidNameAndLoopbackListenerCannotAdvertise() throws {
        let certificate = try makeCertificate(host: "studio-mac.local")
        defer { try? FileManager.default.removeItem(at: certificate.deletingLastPathComponent()) }
        XCTAssertThrowsError(try HostAdvertisingConfiguration(name: "Studio Mac", listenAddress: "127.0.0.1:9841", advertisedHost: "studio-mac.local", certificatePath: certificate.path))
        XCTAssertThrowsError(try HostAdvertisingConfiguration(name: "Studio Mac", listenAddress: "127.0.0.2:9841", advertisedHost: "studio-mac.local", certificatePath: certificate.path))
        XCTAssertThrowsError(try HostAdvertisingConfiguration(name: "Studio Mac", listenAddress: "0.0.0.0:9841", advertisedHost: "localhost", certificatePath: certificate.path))
    }

    func testCertificateMustCoverAdvertisedHostname() throws {
        let certificate = try makeCertificate(host: "another-mac.local")
        defer { try? FileManager.default.removeItem(at: certificate.deletingLastPathComponent()) }
        XCTAssertThrowsError(try HostAdvertisingConfiguration(name: "Studio Mac", listenAddress: "0.0.0.0:9841", advertisedHost: "studio-mac.local", certificatePath: certificate.path))
    }

    private func makeCertificate(host: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificate = directory.appendingPathComponent("server.crt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                             "-subj", "/CN=\(host)", "-addext", "subjectAltName=DNS:\(host)",
                             "-addext", "basicConstraints=critical,CA:TRUE",
                             "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                             "-addext", "extendedKeyUsage=serverAuth",
                             "-keyout", directory.appendingPathComponent("server.key").path, "-out", certificate.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return certificate
    }
}
