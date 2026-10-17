import Foundation
import CryptoKit
import Security
import AgentLandPairing

public enum HostAdvertisingError: LocalizedError {
    case unreachableListener
    case unreadableCertificate
    case certificateDoesNotMatchHost

    public var errorDescription: String? {
        switch self {
        case .unreachableListener: "Use a non-loopback HTTPS listener and a reachable advertised hostname."
        case .unreadableCertificate: "The configured TLS certificate could not be read."
        case .certificateDoesNotMatchHost: "The TLS certificate is expired, invalid, or does not cover the advertised hostname."
        }
    }
}

public struct HostAdvertisingConfiguration: Sendable {
    public let advertisement: HostAdvertisement
    public let port: UInt16

    public init(name: String, listenAddress: String, advertisedHost: String, certificatePath: String) throws {
        guard let separator = listenAddress.lastIndex(of: ":"),
              let port = UInt16(listenAddress[listenAddress.index(after: separator)...]), port > 0 else {
            throw HostAdvertisingError.unreachableListener
        }
        let listener = String(listenAddress[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !listener.isEmpty, listener != "localhost", listener != "localhost.",
              !listener.hasPrefix("127."), listener != "::1", !listener.hasPrefix("::ffff:127.") else {
            throw HostAdvertisingError.unreachableListener
        }
        let host = advertisedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(":"), !host.contains("/"), !host.contains("?") else {
            throw HostAdvertisingError.unreachableListener
        }
        let address = "https://\(host):\(port)"
        let pem = try? String(contentsOfFile: certificatePath, encoding: .utf8)
        guard let pem,
              let start = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<pem.endIndex),
              let data = Data(base64Encoded: String(pem[start.upperBound..<end.lowerBound]).components(separatedBy: .whitespacesAndNewlines).joined()),
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw HostAdvertisingError.unreadableCertificate
        }
        var optionalTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &optionalTrust) == errSecSuccess,
              let trust = optionalTrust,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            throw HostAdvertisingError.certificateDoesNotMatchHost
        }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.advertisement = try HostAdvertisement(name: name, address: address, certificateSHA256: fingerprint)
        self.port = port
    }
}
