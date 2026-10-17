import CryptoKit
import Foundation

/// A stable, non-secret name for one Mac's host in notice records: 32
/// lowercase hex digits from the SHA-256 of its TLS certificate fingerprint.
///
/// The fingerprint is public (Bonjour and the pairing QR carry it), so the
/// name reveals nothing new and holds no credential. iPhone and iPad derive the
/// same name from the fingerprint they pinned when they paired, which is how a
/// tapped notice finds its host. A new certificate means a new pairing and a
/// new name.
public enum NoticeHostID {
    /// Returns nil unless `certificateSHA256` is 64 hex digits (either case;
    /// colons and spaces are ignored).
    public static func make(certificateSHA256: String) -> String? {
        let fingerprint = String(certificateSHA256.lowercased().filter { !$0.isWhitespace && $0 != ":" })
        guard fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let digest = SHA256.hash(data: Data("agentland.notice.host.v1:\(fingerprint)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `value` has the form `make` returns.
    public static func isValid(_ value: some StringProtocol) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
