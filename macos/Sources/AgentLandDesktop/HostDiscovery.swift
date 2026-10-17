import Foundation
import CryptoKit
import Security
import AgentLandPairing

@MainActor
final class HostDiscoveryPublisher: NSObject, NetServiceDelegate {
    private var service: NetService?
    var onPublicationChange: ((Bool, Bool) -> Void)?

    func publish(_ advertisement: HostAdvertisement, port: UInt16) {
        stop()
        let service = NetService(domain: HostAdvertisement.serviceDomain,
                                 type: HostAdvertisement.serviceType,
                                 name: advertisement.name, port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.txtRecord))
        self.service = service
        onPublicationChange?(false, false)
        service.publish()
    }

    func stop() {
        service?.delegate = nil
        service?.stop()
        service = nil
        onPublicationChange?(false, false)
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        let identity = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self, let service = self.service, ObjectIdentifier(service) == identity else { return }
            self.onPublicationChange?(true, false)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let identity = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self, let service = self.service, ObjectIdentifier(service) == identity else { return }
            service.delegate = nil
            service.stop()
            self.service = nil
            self.onPublicationChange?(false, true)
        }
    }
}

private final class PinnedHealthDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String
    let expectedHost: String

    init(fingerprint: String, expectedHost: String) {
        self.fingerprint = fingerprint
        self.expectedHost = expectedHost
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map({ String(format: "%02x", $0) }).joined() == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum HostReadinessProbe {
    static func isReady(_ advertisement: HostAdvertisement, localListener: String? = nil) async -> Bool {
        guard let origin = URL(string: advertisement.address),
              let expectedHost = origin.host else { return false }
        let requestOrigin = localOrigin(for: localListener, matching: origin) ?? origin
        guard let url = URL(string: "/v1/health", relativeTo: requestOrigin)?.absoluteURL else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config,
                                 delegate: PinnedHealthDelegate(fingerprint: advertisement.certificateSHA256, expectedHost: expectedHost),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if requestOrigin.host != expectedHost {
            request.setValue(hostHeader(for: origin), forHTTPHeaderField: "Host")
        }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["protocolVersion"] as? Int == 1 else { return false }
        return true
    }

    /// The companion owns this listener and has already selected its TLS identity.
    /// Probing a wildcard listener over loopback avoids relying on the app's own
    /// `.local` resolver before local-network discovery has completed.
    private static func localOrigin(for listener: String?, matching advertisedOrigin: URL) -> URL? {
        guard let listener,
              let split = listenerPort(listener),
              split.port == advertisedOrigin.port else { return nil }
        let host: String
        switch split.host {
        case "0.0.0.0": host = "127.0.0.1"
        case "::", "[::]": host = "::1"
        default: return nil
        }
        var components = URLComponents()
        components.scheme = advertisedOrigin.scheme
        components.host = host
        components.port = split.port
        return components.url
    }

    private static func listenerPort(_ listener: String) -> (host: String, port: Int)? {
        let value = listener.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[...close])
            let remaining = value[value.index(after: close)...]
            guard remaining.first == ":", let port = Int(remaining.dropFirst()), port > 0, port <= 65_535 else { return nil }
            return (host, port)
        }
        guard let separator = value.lastIndex(of: ":"),
              !value[..<separator].contains(":"),
              let port = Int(value[value.index(after: separator)...]), port > 0, port <= 65_535 else { return nil }
        return (String(value[..<separator]), port)
    }

    private static func hostHeader(for origin: URL) -> String {
        guard let host = origin.host else { return "" }
        guard let port = origin.port, port != 443 else { return host }
        return "\(host):\(port)"
    }
}
