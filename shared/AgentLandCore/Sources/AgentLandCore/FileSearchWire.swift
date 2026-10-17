import Foundation

// `GET /v1/files/search` (docs/HOST-API.md, "Files"): lines of a project's text files that
// contain the query. Hosts list `search` in `capabilities.files` when they answer it.

/// A file feature a host lists in `capabilities.files`.
public enum FileFeature: String, Sendable, CaseIterable {
    case move, mkdir, upload, trash, delete, search
}

public extension CapabilitiesResponse {
    /// A file feature. Hosts that list none claim none.
    func supportsFiles(_ feature: FileFeature) -> Bool { files.contains(feature.rawValue) }
}

/// One matching line: where it is and up to 240 bytes of it around the match.
public struct FileSearchMatch: Codable, Hashable, Sendable {
    public let line: Int
    public let column: Int
    public let preview: String

    public init(line: Int, column: Int, preview: String) { self.line = line; self.column = column; self.preview = preview }

    enum CodingKeys: String, CodingKey { case line, column, preview }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line = try container.decodeIfPresent(Int.self, forKey: .line) ?? 0
        column = try container.decodeIfPresent(Int.self, forKey: .column) ?? 0
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }
}

/// A file with matching lines; `truncated` when it had more than the host returns per file.
public struct FileSearchResult: Codable, Hashable, Identifiable, Sendable {
    public let path: String
    public let matches: [FileSearchMatch]
    public let truncated: Bool
    public var id: String { path }

    public init(path: String, matches: [FileSearchMatch], truncated: Bool = false) {
        self.path = path; self.matches = matches; self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey { case path, matches, truncated }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        matches = try container.decodeIfPresent([FileSearchMatch].self, forKey: .matches) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// The host's answer: one entry per file, and why it stopped early (`files`, `bytes`, `matches`
/// or `time`) when it did.
public struct FileSearchResponse: Codable, Hashable, Sendable {
    public let results: [FileSearchResult]
    public let truncatedReason: String?

    public init(results: [FileSearchResult], truncatedReason: String? = nil) {
        self.results = results; self.truncatedReason = truncatedReason
    }

    enum CodingKeys: String, CodingKey { case results, truncatedReason }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent([FileSearchResult].self, forKey: .results) ?? []
        truncatedReason = try container.decodeIfPresent(String.self, forKey: .truncatedReason)
    }
}

extension APIClient {
    /// Plain-text, case-insensitive search of a project's text files. A device runs one search at a
    /// time: a newer one ends the older with 409 `search_superseded`.
    public func searchFiles(projectID: String, query: String, path: String? = nil) async throws -> FileSearchResponse {
        var items = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "q", value: query)]
        if let path, !path.isEmpty { items.append(URLQueryItem(name: "path", value: path)) }
        return try await get("/v1/files/search", query: items, timeout: 15)
    }
}
