import Foundation
import Security
import AgentLandCore

/// What the browser tab lets its web view do, decided without WebKit so it can be tested: https pages
/// only (plus the blank and inline documents frames use), no downloads, no credentials in addresses
/// or Authorization headers, never the host's own API routes. The host's preview origin is the only
/// origin whose certificate is checked against the paired pin; every other page gets the platform's
/// normal validation.
public struct BrowserNavigationPolicy: Hashable, Sendable {
    /// The host's preview listener, when it has one.
    public var previewOrigin: BrowserOrigin?
    /// The host's API origin and base path: its `/v1` routes never load in the web view.
    public var apiOrigin: BrowserOrigin?
    public var apiBasePath: String

    public init(previewOrigin: BrowserOrigin? = nil, apiOrigin: BrowserOrigin? = nil, apiBasePath: String = "") {
        self.previewOrigin = previewOrigin
        self.apiOrigin = apiOrigin
        self.apiBasePath = apiBasePath
    }

    /// The policy for a host at `address` whose preview listener is on `previewPort`, with the scheme
    /// the host advertises (`capabilities.preview.scheme`; the address's when it names none).
    public init(address: ServerAddress?, previewPort: Int?, previewScheme: String? = nil) {
        let apiURL = address?.url
        self.init(previewOrigin: previewPort.flatMap { port in address?.previewOrigin(port: port, scheme: previewScheme) }.flatMap(BrowserOrigin.init),
                  apiOrigin: apiURL.flatMap(BrowserOrigin.init),
                  apiBasePath: apiURL.map { $0.path(percentEncoded: true) } ?? "")
    }

    public enum Decision: Hashable, Sendable {
        case allow
        case refuse(BrowserRefusal)
    }

    /// A navigation the web view is about to make.
    public func decide(url: URL?, isMainFrame: Bool, carriesAuthorization: Bool, isDownload: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refuse(.notAnAddress) }
        if isDownload { return .refuse(.download) }
        if carriesAuthorization || url.user != nil || url.password != nil { return .refuse(.credentials) }
        switch scheme {
        case "https":
            if isHostAPI(url) { return .refuse(.hostAPI) }
            return .allow
        case "about":
            // about:blank and about:srcdoc hold frames' own documents.
            return .allow
        case "data", "blob":
            // Documents a page made itself, allowed in frames only; a whole page of one is a download.
            return isMainFrame ? .refuse(.unsupportedScheme(scheme)) : .allow
        case "http":
            return .refuse(.insecure)
        default:
            return .refuse(.unsupportedScheme(scheme))
        }
    }

    public enum ResponseDecision: Hashable, Sendable {
        case allow
        case refuse(BrowserRefusal)
        /// The preview proxy refused the request itself (its error header), with its code.
        case previewError(code: String, status: Int)
    }

    /// A response the web view is about to show.
    public func decide(response: URLResponse, isMainFrame: Bool, canShowMIMEType: Bool) -> ResponseDecision {
        let http = response as? HTTPURLResponse
        if let code = http?.value(forHTTPHeaderField: PreviewProxy.errorHeader), !code.isEmpty,
           let url = response.url, previewOrigin?.contains(url) == true {
            return isMainFrame ? .previewError(code: code, status: http?.statusCode ?? 0) : .allow
        }
        if !canShowMIMEType { return .refuse(.download) }
        if let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.trimmingCharacters(in: .whitespaces).lowercased(),
           disposition.hasPrefix("attachment") {
            return .refuse(.download)
        }
        return .allow
    }

    /// Whether a challenge is for the preview origin.
    public func isPreview(host: String, port: Int) -> Bool { previewOrigin?.matches(host: host, port: port) == true }

    /// A certificate or authentication challenge. For the preview origin, the paired pin decides (the
    /// listener presents the API's certificate); everywhere else the platform's validation does.
    public func respond(toChallengeFor host: String, port: Int, authenticationMethod: String, serverTrust: SecTrust?,
                        pinned: PinnedTrustEvaluator?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard isPreview(host: host, port: port) else { return (.performDefaultHandling, nil) }
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // The preview listener asks for nothing else; the proxy never forwards credentials.
            return (.cancelAuthenticationChallenge, nil)
        }
        guard let pinned else { return (.performDefaultHandling, nil) }
        return pinned.evaluate(authenticationMethod: authenticationMethod, host: host, serverTrust: serverTrust)
    }

    private func isHostAPI(_ url: URL) -> Bool {
        guard let apiOrigin, apiOrigin.contains(url) else { return false }
        let base = apiBasePath.hasSuffix("/") ? String(apiBasePath.dropLast()) : apiBasePath
        let path = url.path(percentEncoded: true)
        return path == base + "/v1" || path.hasPrefix(base + "/v1/")
    }
}
