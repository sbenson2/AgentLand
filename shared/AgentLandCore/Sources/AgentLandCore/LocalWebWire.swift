import Foundation

/// Read-only export of the native Mac workspace. The original defaults remain intact.
public struct LocalWebLegacy: Encodable, Sendable {
    public let version = 1
    public let projectID: String?
    public let tabs: [WorkspaceTab]
    public let selectedTabID: UUID?

    public init(projectID: String?, workspace: WorkspaceState) {
        self.projectID = projectID
        tabs = workspace.tabs
        selectedTabID = workspace.selectedTabID
    }
}

extension APIClient {
    /// Available only to the companion's authenticated loopback session.
    /// Never log the returned URL: its fragment contains a short-lived launch grant.
    public func localWebLaunch() async throws -> URL {
        struct Empty: Encodable {}
        struct Reply: Decodable { let url: String }
        let reply: Reply = try await post("/v1/local-web/launch", body: Empty(), expected: 200)
        guard let components = URLComponents(string: reply.url),
              components.scheme == "http", components.host == "127.0.0.1",
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.path == "/", components.query == nil,
              let fragment = components.fragment, fragment.hasPrefix("launch="),
              (32...256).contains(fragment.dropFirst(7).count),
              fragment.dropFirst(7).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let url = components.url else { throw ClientError.invalidResponse }
        return url
    }

    /// The host imports at most once, preserving any newer browser state.
    public func importLocalWebLegacy(_ legacy: LocalWebLegacy) async throws {
        struct Body: Encodable { let legacy: LocalWebLegacy }
        struct Reply: Decodable { let imported: Bool }
        let _: Reply = try await post("/v1/local-web/import", body: Body(legacy: legacy), expected: 200)
    }
}
