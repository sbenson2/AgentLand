import Foundation
import AgentLandCore

/// Where a browser tab points: nothing yet, a web server on one of the host computer's ports (opened
/// through the host's preview listener), or a public https page.
public enum BrowserLocation: Hashable, Sendable {
    /// The start page: the host's ports and the address field.
    case blank
    /// A port on the host computer. `path` starts with "/" and may carry a query and fragment.
    case preview(port: Int, path: String)
    /// A public https page.
    case web(URL)

    /// A location in its saved form: "", "preview:5173", "preview:5173/docs?x=1" or an https URL.
    public init?(saved: String) {
        if saved.isEmpty {
            self = .blank
        } else if saved.hasPrefix("preview:") {
            let rest = saved.dropFirst("preview:".count)
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard let port = Int(digits), (1...65_535).contains(port) else { return nil }
            let path = String(rest.dropFirst(digits.count))
            guard path.isEmpty || path.hasPrefix("/") else { return nil }
            self = .preview(port: port, path: path.isEmpty ? "/" : path)
        } else if let url = URL(string: saved), BrowserOrigin(url) != nil {
            self = .web(url)
        } else {
            return nil
        }
    }

    /// The saved form, whole. A tab's `resourceID` holds the location it was opened for.
    public var saved: String {
        switch self {
        case .blank: ""
        case let .preview(port, path): path == "/" ? "preview:\(port)" : "preview:\(port)\(path)"
        case let .web(url): url.absoluteString
        }
    }

    /// What the tab remembers across launches: the saved form without a query or fragment, which
    /// can carry tokens (a notebook server's `?token=`, a sign-in code).
    public var remembered: String {
        switch self {
        case .blank: return ""
        case let .preview(port, path):
            let bare = String(path.prefix { $0 != "?" && $0 != "#" })
            return BrowserLocation.preview(port: port, path: bare.isEmpty ? "/" : bare).saved
        case let .web(url):
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
            components.query = nil
            components.fragment = nil
            return components.url?.absoluteString ?? ""
        }
    }

    /// The address field's text while the person is not typing: "localhost:5173/docs" or
    /// "example.com/news".
    public var displayText: String {
        switch self {
        case .blank: return ""
        case let .preview(port, path): return "localhost:\(port)" + (path == "/" ? "" : path)
        case let .web(url):
            let host = url.host() ?? ""
            let path = url.path(percentEncoded: false)
            return host + (path == "/" ? "" : path)
        }
    }

    /// What typing starts from: the whole address.
    public var editableText: String {
        switch self {
        case .blank: ""
        case let .preview(port, path): "localhost:\(port)" + (path == "/" ? "" : path)
        case let .web(url): url.absoluteString
        }
    }

    /// The tab's title until the page names itself.
    public var fallbackTitle: String {
        switch self {
        case .blank: "Browser"
        case let .preview(port, _): "localhost:\(port)"
        case let .web(url): url.host() ?? "Browser"
        }
    }

    public var previewPort: Int? {
        if case let .preview(port, _) = self { return port }
        return nil
    }

    /// A public page, which Safari can open too.
    public var publicURL: URL? {
        if case let .web(url) = self { return url }
        return nil
    }
}

/// An https origin: a host (lowercased, without IPv6 brackets) and a port.
public struct BrowserOrigin: Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = BrowserOrigin.normalized(host)
        self.port = port
    }

    /// The origin of an https URL with a host; nil for anything else.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return nil }
        self.init(host: host, port: url.port ?? 443)
    }

    /// Whether `url` is an https URL of this origin.
    public func contains(_ url: URL) -> Bool { BrowserOrigin(url) == self }

    /// Whether a challenge's protection space names this origin.
    public func matches(host: String, port: Int) -> Bool { BrowserOrigin.normalized(host) == self.host && port == self.port }

    static func normalized(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }
}

/// Why the browser tab will not open something. Each has a message to show.
public enum BrowserRefusal: Error, Hashable, Sendable {
    /// Plain http outside the host's own ports.
    case insecure
    case unsupportedScheme(String)
    /// An address with a user name or password, or a request carrying an Authorization header.
    case credentials
    case download
    /// The host's own API routes.
    case hostAPI
    case notAnAddress
    /// A port on the host, on a host without web previews.
    case previewUnavailable
    case badPort

    public var message: String {
        switch self {
        case .insecure:
            "AgentLand opens only secure (https) pages. To open a web server running on the host, choose its port."
        case let .unsupportedScheme(scheme):
            "AgentLand can’t open “\(scheme):” links in the browser tab."
        case .credentials:
            "AgentLand doesn’t open addresses or requests that carry passwords or tokens."
        case .download:
            "The browser tab doesn’t download files."
        case .hostAPI:
            "That is the host’s own API. It doesn’t open in the browser tab."
        case .notAnAddress:
            "Enter a web address such as example.com, or a port on the host such as 5173."
        case .previewUnavailable:
            "Web previews are off on this host, so its ports can’t be opened here."
        case .badPort:
            "Choose a port between 1 and 65535."
        }
    }
}

/// Reads what the person typed into the address field.
public enum BrowserAddress {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
    private static let schemesWithoutSlashes: Set<String> = ["mailto", "tel", "sms", "javascript", "data", "file", "about", "blob", "ftp", "facetime", "maps"]

    /// A location for `text`: a bare port ("5173", ":5173"), a loopback address with a port
    /// ("localhost:5173/docs", "http://127.0.0.1:8000"), `hostNames` with a port (the host's own name),
    /// or a public https address (the scheme may be left out). Other schemes, plain http elsewhere and
    /// addresses with credentials are refused.
    public static func parse(_ text: String, hostNames: [String] = []) -> Result<BrowserLocation, BrowserRefusal> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.notAnAddress) }
        let portText = text.hasPrefix(":") ? String(text.dropFirst()) : text
        if !portText.isEmpty, portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let port = Int(portText), (1...65_535).contains(port) else { return .failure(.badPort) }
            return .success(.preview(port: port, path: "/"))
        }
        guard !text.contains(where: \.isWhitespace) else { return .failure(.notAnAddress) }

        let scheme = self.scheme(of: text)
        let withScheme = scheme == nil ? "https://" + text : text
        guard let components = URLComponents(string: withScheme), let parsedScheme = components.scheme?.lowercased() else {
            return .failure(.notAnAddress)
        }
        guard parsedScheme == "http" || parsedScheme == "https" else { return .failure(.unsupportedScheme(parsedScheme)) }
        guard components.user == nil, components.password == nil else { return .failure(.credentials) }
        guard let rawHost = components.host, !rawHost.isEmpty else { return .failure(.notAnAddress) }
        let host = BrowserOrigin.normalized(rawHost)

        let names = Set(hostNames.map(BrowserOrigin.normalized))
        if loopbackHosts.contains(host) || (names.contains(host) && components.port != nil) {
            let port = components.port ?? (parsedScheme == "https" && scheme != nil ? 443 : 80)
            guard (1...65_535).contains(port) else { return .failure(.badPort) }
            return .success(.preview(port: port, path: pathAndRest(components)))
        }
        guard parsedScheme == "https" else { return .failure(.insecure) }
        // Without a scheme, a single word is not an address: "localhost" was handled above.
        if scheme == nil, !host.contains("."), !host.contains(":") { return .failure(.notAnAddress) }
        var secure = components
        secure.scheme = "https"
        if !rawHost.hasPrefix("[") { secure.host = rawHost.lowercased() }
        guard let url = secure.url else { return .failure(.notAnAddress) }
        return .success(.web(url))
    }

    /// The scheme `text` starts with, if it names one: "https://…", "mailto:…". "localhost:5173" has none.
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon]
        guard let first = name.first, first.isLetter,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return name.lowercased() }
        return schemesWithoutSlashes.contains(name.lowercased()) ? name.lowercased() : nil
    }

    private static func pathAndRest(_ components: URLComponents) -> String {
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let query = components.percentEncodedQuery { path += "?" + query }
        if let fragment = components.percentEncodedFragment { path += "#" + fragment }
        return path
    }
}
