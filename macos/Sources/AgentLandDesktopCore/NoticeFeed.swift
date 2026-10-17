import Foundation
import AgentLandCore

/// One notice as `GET /v1/notices` returns it (docs/HOST-API.md, "Presence
/// and notices"). It never contains message text.
public struct HostNotice: Decodable, Equatable, Sendable {
    public let seq: Int64
    public let id: String
    public let kind: String
    public let projectID: String
    public let projectName: String
    public let sessionID: String?
    public let title: String
    /// True when the title may come from the chat's content.
    public let mayContainContent: Bool
    public let createdAt: String

    public init(seq: Int64, id: String, kind: String, projectID: String, projectName: String, sessionID: String? = nil,
                title: String = "", mayContainContent: Bool = true, createdAt: String) {
        self.seq = seq; self.id = id; self.kind = kind; self.projectID = projectID; self.projectName = projectName
        self.sessionID = sessionID; self.title = title; self.mayContainContent = mayContainContent; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case seq, id, kind, projectID = "projectId", projectName, sessionID = "sessionId", title, mayContainContent, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int64.self, forKey: .seq)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        // Without the flag, treat the title as content.
        mayContainContent = try container.decodeIfPresent(Bool.self, forKey: .mayContainContent) ?? true
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    /// `createdAt` as a date (RFC 3339, with or without milliseconds).
    public var createdDate: Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

/// One answer of `GET /v1/notices`.
public struct HostNoticePage: Decodable, Equatable, Sendable {
    public let notices: [HostNotice]
    /// Opaque; pass it back as `after`.
    public let cursor: String
    public let hasMore: Bool
    /// The host started over (a new epoch): these notices start at its oldest.
    public let resync: Bool

    public init(notices: [HostNotice], cursor: String, hasMore: Bool = false, resync: Bool = false) {
        self.notices = notices; self.cursor = cursor; self.hasMore = hasMore; self.resync = resync
    }

    enum CodingKeys: String, CodingKey { case notices, cursor, hasMore, resync }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notices = try container.decodeIfPresent([HostNotice].self, forKey: .notices) ?? []
        cursor = try container.decode(String.self, forKey: .cursor)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        resync = try container.decodeIfPresent(Bool.self, forKey: .resync) ?? false
    }
}

/// The host's local notice feed.
public protocol NoticeFeed: Sendable {
    /// Notices after `cursor` (after the acknowledged ones without it),
    /// waiting up to `waitMilliseconds` for one when there are none.
    func notices(after cursor: String?, waitMilliseconds: Int) async throws -> HostNoticePage
    /// Records that the app handled every notice through `seq`.
    func acknowledge(through seq: Int64) async throws
}

/// `NoticeFeed` over HTTPS with the Mac app's local session: the routes are
/// local-only, so only this Mac's own loopback session may read them.
public struct HostNoticeFeed: NoticeFeed {
    private let baseURL: URL
    private let token: String
    private let transport: any APITransport

    /// `transport` must pin the host's certificate (`URLSessionTransport`).
    public init(baseURL: URL, token: String, transport: any APITransport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    public func notices(after cursor: String?, waitMilliseconds: Int) async throws -> HostNoticePage {
        var components = URLComponents(url: baseURL.appending(path: "/v1/notices"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "wait", value: String(max(0, min(waitMilliseconds, 20_000))))]
        if let cursor { query.insert(URLQueryItem(name: "after", value: cursor), at: 0) }
        components.queryItems = query
        guard let url = components.url else { throw ClientError.invalidResponse }
        var request = request(url, method: "GET")
        // The host holds the request up to the wait; allow for it.
        request.timeoutInterval = TimeInterval(waitMilliseconds) / 1000 + 15
        let (data, response) = try await transport.execute(request)
        try Self.validate(response, data: data)
        do { return try JSONDecoder().decode(HostNoticePage.self, from: data) } catch { throw ClientError.decoding }
    }

    public func acknowledge(through seq: Int64) async throws {
        var request = request(baseURL.appending(path: "/v1/notices/ack"), method: "POST")
        request.httpBody = try JSONEncoder().encode(["through": seq])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.execute(request)
        try Self.validate(response, data: data)
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private struct ErrorEnvelope: Decodable { struct Body: Decodable { let code: String; let message: String }; let error: Body }

    private static func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard response.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw ClientError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw ClientError.unexpectedStatus(response.statusCode)
        }
    }
}
