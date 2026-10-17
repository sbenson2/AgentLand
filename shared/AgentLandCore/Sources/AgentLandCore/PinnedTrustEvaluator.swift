import Foundation
import Security
import CryptoKit

/// Decides server-trust challenges for a connection paired to one certificate.
///
/// Without a paired fingerprint every challenge gets the platform's normal
/// handling. With one, only a server-trust challenge for the expected host
/// passes, and only when the server's leaf certificate has exactly that
/// SHA-256 fingerprint and, trusted as its own sole anchor, is currently valid
/// for `validatedCertificateHost`. Everything else is cancelled.
public struct PinnedTrustEvaluator: Sendable {
    private let expectedHost: String?
    private let validatedCertificateHost: String?
    private let fingerprint: String?

    /// `certificateSHA256` may use either case and separators such as colons.
    /// `validatedCertificateHost` defaults to `expectedHost`; the Mac sets it
    /// when it reaches its own host over loopback.
    public init(expectedHost: String?, certificateSHA256: String?, validatedCertificateHost: String? = nil) {
        self.expectedHost = expectedHost
        self.validatedCertificateHost = validatedCertificateHost ?? expectedHost
        fingerprint = certificateSHA256?.lowercased().filter { $0.isHexDigit }
    }

    public func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(authenticationMethod: challenge.protectionSpace.authenticationMethod,
                 host: challenge.protectionSpace.host,
                 serverTrust: challenge.protectionSpace.serverTrust)
    }

    public func evaluate(authenticationMethod: String, host: String, serverTrust: SecTrust?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let fingerprint else { return (.performDefaultHandling, nil) }
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let expectedHost, Self.sameHost(host, expectedHost),
              let trust = serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0)
        else { return (.cancelAuthenticationChallenge, nil) }
        let der = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else { return (.cancelAuthenticationChallenge, nil) }
        guard let validatedCertificateHost,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, validatedCertificateHost as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return (.cancelAuthenticationChallenge, nil) }
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// The same host whatever its case, an IPv6 address's brackets or a name's trailing dot.
    static func sameHost(_ first: String, _ second: String) -> Bool {
        func plain(_ value: String) -> String {
            var host = value.lowercased()
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if host.hasSuffix(".") { host.removeLast() }
            return host
        }
        return !first.isEmpty && plain(first) == plain(second)
    }
}
