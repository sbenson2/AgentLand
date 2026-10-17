import Foundation
import XCTest

/// Throwaway certificates made with /usr/bin/openssl for one test run (P-256,
/// valid for two days, names 127.0.0.1 and localhost).
struct TestCertificates {
    let directory: URL
    /// A private CA and a relay certificate it issued.
    let caDER: Data
    let issuedCertificate: URL
    let issuedKey: URL
    /// Another CA that issued nothing the relays use.
    let otherCADER: Data
    /// A self-signed relay certificate (not a CA).
    let selfSignedDER: Data
    let selfSignedCertificate: URL
    let selfSignedKey: URL

    static func make() throws -> TestCertificates {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentland-iroh-certs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let openssl = "/usr/bin/openssl"
        func key(_ name: String) throws {
            // SEC1 ("EC PRIVATE KEY"): the relay's rustls/ring refuses LibreSSL's PKCS#8 EC keys.
            try run(openssl, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", name], in: directory)
        }
        func der(_ pem: String) throws -> Data {
            try run(openssl, ["x509", "-in", pem, "-outform", "DER", "-out", pem + ".der"], in: directory)
            return try Data(contentsOf: directory.appendingPathComponent(pem + ".der"))
        }
        let leafExtensions = [
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=serverAuth",
            "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"
        ]
        for ca in ["ca", "other-ca"] {
            try key("\(ca).key")
            try run(openssl, [
                "req", "-x509", "-new", "-key", "\(ca).key", "-sha256", "-days", "2",
                "-subj", "/CN=AgentLand test \(ca)",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-out", "\(ca).pem"
            ], in: directory)
        }
        try key("issued.key")
        try run(openssl, ["req", "-new", "-key", "issued.key", "-subj", "/CN=127.0.0.1", "-out", "issued.csr"], in: directory)
        try """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=serverAuth
        subjectAltName=IP:127.0.0.1,DNS:localhost

        """.write(to: directory.appendingPathComponent("issued.ext"), atomically: true, encoding: .utf8)
        try run(openssl, [
            "x509", "-req", "-in", "issued.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
            "-days", "2", "-sha256", "-extfile", "issued.ext", "-out", "issued.pem"
        ], in: directory)
        try key("self.key")
        try run(openssl, ["req", "-x509", "-new", "-key", "self.key", "-sha256", "-days", "2", "-subj", "/CN=127.0.0.1"]
            + leafExtensions + ["-out", "self.pem"], in: directory)

        return TestCertificates(
            directory: directory,
            caDER: try der("ca.pem"),
            issuedCertificate: directory.appendingPathComponent("issued.pem"),
            issuedKey: directory.appendingPathComponent("issued.key"),
            otherCADER: try der("other-ca.pem"),
            selfSignedDER: try der("self.pem"),
            selfSignedCertificate: directory.appendingPathComponent("self.pem"),
            selfSignedKey: directory.appendingPathComponent("self.key")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// An iroh-relay process on loopback (the pinned release binary that
/// scripts/build-iroh-ffi.sh puts in Frameworks/, or $AGENTLAND_IROH_RELAY).
/// Metrics and QUIC address discovery are off; it is stopped with SIGINT.
final class TestRelay {
    let url: String
    private let process: Process
    private let directory: URL
    /// Signalled by the process's termination handler. `Process.waitUntilExit()`
    /// waits on the calling thread's run loop, which nothing drives on a Swift
    /// concurrency thread: it hung a test run after the relay had exited.
    private let exited = DispatchSemaphore(value: 0)

    static var binary: URL? {
        if let path = ProcessInfo.processInfo.environment["AGENTLAND_IROH_RELAY"] {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundled = packageDirectory.appendingPathComponent("Frameworks/iroh-relay")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    /// The relay binary. Without one the calling test fails, so a run that
    /// lacks it cannot pass unnoticed; AGENTLAND_IROH_ALLOW_MISSING_RELAY=1 turns
    /// that into a skip, reported on stderr and in the test summary.
    static func requireBinary() throws -> URL {
        if let binary { return binary }
        let message = "no iroh-relay binary: run scripts/build-iroh-ffi.sh (without --skip-relay) or set AGENTLAND_IROH_RELAY"
        guard ProcessInfo.processInfo.environment["AGENTLAND_IROH_ALLOW_MISSING_RELAY"] == "1" else {
            throw MissingRelay(description: message + " (AGENTLAND_IROH_ALLOW_MISSING_RELAY=1 skips these tests instead)")
        }
        FileHandle.standardError.write(Data("warning: SKIPPED, \(message)\n".utf8))
        throw XCTSkip(message + " (skipped: AGENTLAND_IROH_ALLOW_MISSING_RELAY=1)")
    }

    struct MissingRelay: Error, CustomStringConvertible {
        let description: String
    }

    /// Plain HTTP relay (`http://127.0.0.1:<port>`).
    static func startHTTP() throws -> TestRelay {
        let port = try freePort(SOCK_STREAM)
        return try TestRelay(url: "http://127.0.0.1:\(port)", port: port, config: """
        enable_relay = true
        http_bind_addr = "127.0.0.1:\(port)"
        enable_quic_addr_discovery = false
        enable_metrics = false
        """)
    }

    /// HTTPS relay (`https://127.0.0.1:<port>`) with the given certificate and key.
    static func startHTTPS(certificate: URL, key: URL) throws -> TestRelay {
        let httpPort = try freePort(SOCK_STREAM)
        let httpsPort = try freePort(SOCK_STREAM)
        return try TestRelay(url: "https://127.0.0.1:\(httpsPort)", port: httpsPort, config: """
        enable_relay = true
        http_bind_addr = "127.0.0.1:\(httpPort)"
        enable_quic_addr_discovery = false
        enable_metrics = false

        [tls]
        https_bind_addr = "127.0.0.1:\(httpsPort)"
        cert_mode = "Manual"
        manual_cert_path = "\(certificate.path)"
        manual_key_path = "\(key.path)"
        """)
    }

    private init(url: String, port: UInt16, config: String) throws {
        let binary = try Self.requireBinary()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentland-iroh-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configFile = directory.appendingPathComponent("relay.toml")
        try config.write(to: configFile, atomically: true, encoding: .utf8)
        let log = directory.appendingPathComponent("relay.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        self.url = url
        process = Process()
        process.executableURL = binary
        process.arguments = ["--config-path", configFile.path]
        process.currentDirectoryURL = directory
        process.environment = ["RUST_LOG": "warn", "NO_COLOR": "1"]
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        while !Self.accepts(port: port) {
            guard process.isRunning, Date() < deadline else {
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                stop()
                throw NSError(domain: "TestRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "relay did not start: \(text)"])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    var log: String {
        (try? String(contentsOf: directory.appendingPathComponent("relay.log"), encoding: .utf8)) ?? ""
    }

    /// TLS handshakes a client ended because it did not trust the certificate
    /// (the relay logs the alert at error level).
    var unknownCAAlerts: Int {
        log.components(separatedBy: "received fatal alert: UnknownCA").count - 1
    }

    func stop() {
        if exited.wait(timeout: .now()) == .timedOut {
            process.interrupt()  // SIGINT: the relay's clean shutdown
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        exited.signal()  // a second stop() returns at once
        try? FileManager.default.removeItem(at: directory)
    }

    private static func accepts(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
