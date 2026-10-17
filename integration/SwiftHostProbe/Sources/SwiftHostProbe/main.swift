import Foundation
import CryptoKit
import AgentLandCore

enum ProbeError: Error { case failed(String) }

@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { throw ProbeError.failed("expected URL certificateDER pairingCode hostBinary statePath") }
        let certificateData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let fingerprint = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
        let transport = URLSessionTransport(expectedHost: "localhost", certificateSHA256: fingerprint)
        let address = try ServerAddress(validating: args[1])
        do {
            _ = try await APIClient(address: address, token: "").health()
            throw ProbeError.failed("production transport accepted an untrusted fixture certificate")
        } catch let error as URLError where [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(error.code) {}
        do {
            _ = try await APIClient(address: address, token: "", transport: URLSessionTransport(expectedHost: "localhost", certificateSHA256: String(repeating: "0", count: 64))).health()
            throw ProbeError.failed("incorrect certificate fingerprint accepted")
        } catch is URLError {}
        let wrongHost = try ServerAddress(validating: args[1].replacingOccurrences(of: "localhost", with: "127.0.0.1"))
        do {
            _ = try await APIClient(address: wrongHost, token: "", transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint)).health()
            throw ProbeError.failed("matching fingerprint bypassed certificate hostname validation")
        } catch is URLError {}
        guard let localToken = ProcessInfo.processInfo.environment["AGENTLAND_TEST_LOCAL_TOKEN"] else { throw ProbeError.failed("missing disposable local token") }
        let localTransport = URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint, validatedCertificateHost: "localhost")
        let localClient = APIClient(address: wrongHost, token: localToken, transport: localTransport)
        let localProjects = try await localClient.projects()
        guard localProjects.map(\.id) == ["fixture"] else { throw ProbeError.failed("loopback desktop session failed") }
        do {
            _ = try await APIClient(address: wrongHost, token: localToken,
                transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint,
                    validatedCertificateHost: "wrong.example")).projects()
            throw ProbeError.failed("desktop transport accepted wrong certificate hostname")
        } catch is URLError {}
        let anonymous = APIClient(address: address, token: "", transport: transport)
        let health = try await anonymous.health()
        guard health.status == "ok", health.protocolVersion == 1 else { throw ProbeError.failed("health mismatch") }
        do { _ = try await anonymous.projects(); throw ProbeError.failed("anonymous project access allowed") }
        catch ClientError.server(let code, _) where code == "unauthorized" {}
        let pair = try await anonymous.pair(code: args[3], deviceName: "AgentLand integration fixture")
        let client = APIClient(address: address, token: pair.token, transport: transport)
        let projects = try await client.projects()
        guard projects.count == 1, projects[0].id == "fixture", projects[0].name == "Fixture" else {
            throw ProbeError.failed("project contract mismatch")
        }
        let entries = try await client.files(projectID: "fixture")
        guard entries.contains(where: { $0.name == "hello.txt" }) else { throw ProbeError.failed("file listing mismatch") }
        let file = try await client.file(projectID: "fixture", path: "hello.txt")
        guard file.content == "Hello from the desktop\n" else { throw ProbeError.failed("file read mismatch") }
        switch await client.saveFile(projectID: "fixture", path: "hello.txt", content: "Edited on mobile\n", revision: file.revision) {
        case .success(let saved): guard saved.content == "Edited on mobile\n", saved.revision != file.revision else { throw ProbeError.failed("save contract mismatch") }
        case .failure: throw ProbeError.failed("file save failed")
        }
        switch await client.saveFile(projectID: "fixture", path: "hello.txt", content: "stale", revision: file.revision) {
        case .success: throw ProbeError.failed("stale file save accepted")
        case .failure: break
        }
        let unchanged = try await client.file(projectID: "fixture", path: "hello.txt")
        guard unchanged.content == "Edited on mobile\n" else { throw ProbeError.failed("conflict overwrote file") }
        do { _ = try await anonymous.pair(code: args[3], deviceName: "Duplicate"); throw ProbeError.failed("pairing code reused") }
        catch ClientError.server(let code, _) where code == "invalid_pairing_code" {}
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[4])
        process.arguments = ["revoke", "--state", args[5], "--device", pair.deviceID]
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProbeError.failed("revocation command failed") }
        do { _ = try await client.projects(); throw ProbeError.failed("revoked token accepted") }
        catch ClientError.server(let code, _) where code == "unauthorized" {}
        print("PASS: Swift TLS pinning, loopback desktop session with hostname validation, numeric PIN pairing, projects, files/edit/conflict, PIN reuse, revocation")
    }
}
