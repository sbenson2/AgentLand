import Foundation

// Web previews (docs/HOST-API.md, "Preview (browser tab)"): a paired device
// opens a web server on one of the host computer's ports through the host's
// preview listener, a second HTTPS origin with the API's certificate. Each
// preview session's secret arrives once, in the answer that creates it; the
// device keeps it in memory, sets it as a cookie for the preview origin only
// and never puts it in a URL or a log.

/// What a host adds to the preview routes, listed in `preview.features`.
public enum PreviewFeature: String, Sendable, CaseIterable {
    /// `POST /v1/preview/sessions/revoke` takes `{all: true}`: every session of this device ends.
    case revokeAll
}

/// `capabilities.preview`: present only while the host's preview listener runs.
public struct PreviewCapabilities: Codable, Hashable, Sendable {
    /// The preview listener's port.
    public var port: Int
    /// The preview listener's scheme (`https`); nil from hosts before it, which serve https too.
    public var scheme: String?
    /// `PreviewFeature` names; hosts before them list none.
    public var features: [String]

    public init(port: Int, scheme: String? = nil, features: [String] = []) {
        self.port = port
        self.scheme = scheme
        self.features = features
    }

    enum CodingKeys: String, CodingKey { case port, scheme, features }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(Int.self, forKey: .port)
        let scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        self.scheme = scheme?.isEmpty == false ? scheme : nil
        features = try container.decodeIfPresent([String].self, forKey: .features) ?? []
    }

    public func supports(_ feature: PreviewFeature) -> Bool { features.contains(feature.rawValue) }
}

/// A port the host can preview: this user's TCP listener that the proxy can reach.
public struct PreviewPort: Decodable, Hashable, Identifiable, Sendable {
    public var port: Int
    /// `127.0.0.1`, `::1` or `*` (every address).
    public var address: String
    /// The listening program's executable name, when the host knows it.
    public var process: String?
    public var id: Int { port }

    public init(port: Int, address: String = "127.0.0.1", process: String? = nil) {
        self.port = port; self.address = address; self.process = process
    }

    enum CodingKeys: String, CodingKey { case port, address, process }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(Int.self, forKey: .port)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        let process = try container.decodeIfPresent(String.self, forKey: .process)
        self.process = process?.isEmpty == false ? process : nil
    }
}

/// The preview session's cookie. `value` is the secret: its description never shows it.
public struct PreviewCookie: Decodable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The name the host uses for every preview session.
    public static let standardName = "__Host-agentland-preview"

    public var name: String
    public var value: String
    public var maxAgeSeconds: Int

    public init(name: String = PreviewCookie.standardName, value: String, maxAgeSeconds: Int = 43_200) {
        self.name = name; self.value = value; self.maxAgeSeconds = maxAgeSeconds
    }

    enum CodingKeys: String, CodingKey { case name, value, maxAgeSeconds }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.standardName
        value = try container.decode(String.self, forKey: .value)
        maxAgeSeconds = try container.decodeIfPresent(Int.self, forKey: .maxAgeSeconds) ?? 43_200
    }

    public var description: String { "PreviewCookie(\(name), value hidden, \(maxAgeSeconds) s)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["name": name, "maxAgeSeconds": maxAgeSeconds]) }
}

/// `POST /v1/preview/sessions`' answer: one device's access to one port.
public struct PreviewSessionGrant: Decodable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var sessionID: String
    /// The preview listener's port, the same for every session.
    public var previewPort: Int
    public var cookie: PreviewCookie

    public init(sessionID: String, previewPort: Int, cookie: PreviewCookie) {
        self.sessionID = sessionID; self.previewPort = previewPort; self.cookie = cookie
    }

    enum CodingKeys: String, CodingKey { case sessionID = "sessionId", previewPort, cookie }

    public var description: String { "PreviewSessionGrant(\(sessionID), port \(previewPort), \(cookie))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["sessionID": sessionID, "previewPort": previewPort, "cookie": cookie]) }

    /// The cookie for `origin` only: Secure, HttpOnly, SameSite=Strict, `Path=/` and no Domain
    /// attribute (a host-only cookie), expiring with the session's 12-hour limit.
    public func httpCookie(for origin: URL, now: Date = .now) -> HTTPCookie? {
        guard origin.scheme?.lowercased() == "https", let host = origin.host(), !host.isEmpty else { return nil }
        return HTTPCookie(properties: [
            .name: cookie.name,
            .value: cookie.value,
            .domain: host.lowercased(),
            .path: "/",
            .secure: "TRUE",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
            .expires: now.addingTimeInterval(TimeInterval(max(cookie.maxAgeSeconds, 0))),
        ])
    }
}

/// One of this device's preview sessions, without its secret.
public struct PreviewSessionInfo: Decodable, Hashable, Identifiable, Sendable {
    public var sessionID: String
    public var port: Int
    public var createdAt: Date?
    public var lastUsedAt: Date?
    /// The 12-hour end.
    public var expiresAt: Date?
    public var id: String { sessionID }

    public init(sessionID: String, port: Int, createdAt: Date? = nil, lastUsedAt: Date? = nil, expiresAt: Date? = nil) {
        self.sessionID = sessionID; self.port = port; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case sessionID = "sessionId", port, createdAt, lastUsedAt, expiresAt }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        createdAt = ChatTime.date(try container.decodeIfPresent(String.self, forKey: .createdAt))
        lastUsedAt = ChatTime.date(try container.decodeIfPresent(String.self, forKey: .lastUsedAt))
        expiresAt = ChatTime.date(try container.decodeIfPresent(String.self, forKey: .expiresAt))
    }
}

public enum PreviewSessionOutcome: Equatable, Sendable {
    case created(PreviewSessionGrant)
    /// The request may have reached the host. Never retried automatically.
    case uncertain
    case failed(ClientError)
}

public enum PreviewRevokeOutcome: Equatable, Sendable {
    case revoked
    /// The request may have reached the host. Never retried automatically.
    case uncertain
    case failed(ClientError)
}

/// The header the preview proxy sets on its own refusals (a previewed server cannot send it), with
/// the error code as its value.
public enum PreviewProxy {
    public static let errorHeader = "X-AgentLand-Preview-Error"
}

public extension ServerAddress {
    /// The preview listener's origin: this address's scheme and host with `port`, and no path.
    func previewOrigin(port: Int) -> URL? {
        guard (1...65_535).contains(port), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.port = port
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The preview listener's origin as the host advertises it (`capabilities.preview`): its scheme
    /// and port with the host name this device connected to, and no path. Without a scheme (hosts
    /// before it), this address's. Nil for a scheme other than https: the app opens only secure
    /// origins.
    func previewOrigin(port: Int, scheme: String?) -> URL? {
        guard let scheme else { return previewOrigin(port: port) }
        guard scheme.lowercased() == "https", let origin = previewOrigin(port: port),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The origin of the preview listener `preview` describes.
    func previewOrigin(_ preview: PreviewCapabilities) -> URL? { previewOrigin(port: preview.port, scheme: preview.scheme) }
}

// MARK: Client

extension APIClient {
    /// The certificate check of this client's connections, when it uses the production transport.
    /// The preview listener presents the same certificate.
    /// A host reached over its routes checks previews at the address it was paired at.
    public var serverTrust: PinnedTrustEvaluator? {
        if let routing { return routing.serverTrust(for: routing.primary) }
        return (transport as? URLSessionTransport)?.serverTrust
    }

    /// `GET /v1/preview/ports`: the host's listening ports, sorted, with process names only.
    public func previewPorts() async throws -> [PreviewPort] {
        let response: PreviewPortsWire = try await get("/v1/preview/ports", timeout: 30)
        return response.ports
    }

    /// `POST /v1/preview/sessions`: access to one port. Nothing is retried.
    public func createPreviewSession(port: Int) async -> PreviewSessionOutcome {
        do {
            let grant: PreviewSessionGrant = try await post("/v1/preview/sessions", body: ["port": port], expected: 201)
            return .created(grant)
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    /// `GET /v1/preview/sessions`: this device's sessions, oldest first.
    public func previewSessions() async throws -> [PreviewSessionInfo] {
        let response: PreviewSessionsWire = try await get("/v1/preview/sessions")
        return response.sessions
    }

    /// `POST /v1/preview/sessions/revoke`.
    public func revokePreviewSession(id: String) async -> PreviewRevokeOutcome {
        await revokeOutcome(body: ["sessionId": id])
    }

    /// `POST /v1/preview/sessions/revoke {all: true}`: ends every preview session of this device,
    /// such as those the app opened before it restarted. Only hosts that list `revokeAll` take it;
    /// older ones refuse the member. Nothing is retried.
    public func revokeAllPreviewSessions() async -> PreviewRevokeOutcome {
        await revokeOutcome(body: ["all": true])
    }

    private func revokeOutcome<Body: Encodable>(body: Body) async -> PreviewRevokeOutcome {
        do {
            let response: PreviewRevokedWire = try await post("/v1/preview/sessions/revoke", body: body, expected: 200)
            return response.revoked ? .revoked : .failed(.unexpectedStatus(200))
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }
}

private struct PreviewPortsWire: Decodable {
    let ports: [PreviewPort]
    enum CodingKeys: String, CodingKey { case ports }
    init(from decoder: Decoder) throws {
        ports = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([PreviewPort].self, forKey: .ports) ?? []
    }
}

private struct PreviewSessionsWire: Decodable {
    let sessions: [PreviewSessionInfo]
    enum CodingKeys: String, CodingKey { case sessions }
    init(from decoder: Decoder) throws {
        sessions = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([PreviewSessionInfo].self, forKey: .sessions) ?? []
    }
}

private struct PreviewRevokedWire: Decodable { let revoked: Bool }
