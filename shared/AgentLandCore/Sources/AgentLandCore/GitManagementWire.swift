import Foundation

public struct GitBranch: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let current: Bool
    public let remote: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public var id: String { (remote ? "remote|" : "local|") + name }
}

public struct GitHistoryCommit: Codable, Hashable, Identifiable, Sendable {
    public let hash: String
    public let subject: String
    public let author: String
    public let timestamp: Int64
    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(7)) }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

public struct GitHistoryPage: Codable, Hashable, Sendable {
    public let commits: [GitHistoryCommit]
    public let nextCursor: String?
}

public struct GitCommitFile: Codable, Hashable, Identifiable, Sendable {
    public let path: String
    public let status: String
    public var id: String { path }
    public init(path: String, status: String) { self.path = path; self.status = status }
}

public struct GitCommitFiles: Codable, Hashable, Sendable {
    public let hash: String
    public let files: [GitCommitFile]
    public let truncated: Bool
}

public struct GitRemote: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let url: String
    public let supported: Bool
    public var id: String { name }
}

public struct GitStash: Codable, Hashable, Identifiable, Sendable {
    public let hash: String
    public let message: String
    public let timestamp: Int64
    public var id: String { hash }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

public struct GitManagementReceipt: Codable, Hashable, Sendable {
    public let changed: Bool
    public init(changed: Bool) { self.changed = changed }
}

public enum GitBranchAction: String, Sendable { case create, `switch`, delete, track }
public enum GitRemoteAction: String, Sendable { case fetch, pull, push }
public enum GitStashAction: String, Sendable { case save, apply, drop }

extension APIClient {
    private func gitManagementQuery(_ projectID: String, _ repository: String) -> [URLQueryItem] {
        [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: repository)]
    }

    public func gitStatus(projectID: String, repository: String, allUntracked: Bool) async throws -> GitStatusResponse {
        var query = gitManagementQuery(projectID, repository)
        if allUntracked { query.append(URLQueryItem(name: "untracked", value: "all")) }
        return try await get("/v1/git/status", query: query)
    }

    public func gitBranches(projectID: String, repository: String) async throws -> [GitBranch] {
        let response: Branches = try await get("/v1/git/branches", query: gitManagementQuery(projectID, repository))
        return response.branches
    }

    public func gitHistory(projectID: String, repository: String, cursor: String? = nil) async throws -> GitHistoryPage {
        var query = gitManagementQuery(projectID, repository)
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("/v1/git/history", query: query)
    }

    public func gitCommitFiles(projectID: String, repository: String, commit: String, stash: Bool = false) async throws -> GitCommitFiles {
        var query = gitManagementQuery(projectID, repository) + [URLQueryItem(name: "commit", value: commit)]
        if stash { query.append(URLQueryItem(name: "stash", value: "1")) }
        return try await get("/v1/git/commit", query: query)
    }

    public func gitCommitDiff(projectID: String, repository: String, commit: String, file: String, stash: Bool = false) async throws -> GitDiffResponse {
        var query = gitManagementQuery(projectID, repository) + [URLQueryItem(name: "commit", value: commit), URLQueryItem(name: "file", value: file)]
        if stash { query.append(URLQueryItem(name: "stash", value: "1")) }
        return try await get("/v1/git/commit/diff", query: query)
    }

    public func gitRemotes(projectID: String, repository: String) async throws -> [GitRemote] {
        let response: Remotes = try await get("/v1/git/remotes", query: gitManagementQuery(projectID, repository))
        return response.remotes
    }

    public func gitStashes(projectID: String, repository: String) async throws -> [GitStash] {
        let response: Stashes = try await get("/v1/git/stashes", query: gitManagementQuery(projectID, repository))
        return response.stashes
    }

    public func gitBranch(projectID: String, repository: String, action: GitBranchAction, name: String, source: String? = nil) async -> GitChangeOutcome<GitManagementReceipt> {
        await gitManagementChange("branch", body: ManagementBody(projectId: projectID, path: repository, action: action.rawValue, name: name, source: source))
    }

    public func gitRemote(projectID: String, repository: String, action: GitRemoteAction, remote: String) async -> GitChangeOutcome<GitManagementReceipt> {
        await gitManagementChange("remote", body: ManagementBody(projectId: projectID, path: repository, action: action.rawValue, remote: remote))
    }

    public func gitStash(projectID: String, repository: String, action: GitStashAction, hash: String? = nil, message: String? = nil, includeUntracked: Bool = false) async -> GitChangeOutcome<GitManagementReceipt> {
        await gitManagementChange("stash", body: ManagementBody(projectId: projectID, path: repository, action: action.rawValue, hash: hash, message: message, includeUntracked: includeUntracked))
    }

    public func gitDiscard(projectID: String, repository: String, files: [String], confirmed: Bool) async -> GitChangeOutcome<GitManagementReceipt> {
        await gitManagementChange("discard", body: ManagementBody(projectId: projectID, path: repository, files: files, confirmed: confirmed))
    }

    private func gitManagementChange(_ route: String, body: ManagementBody) async -> GitChangeOutcome<GitManagementReceipt> {
        await gitChange { try await self.postWithRefusal("/v1/git/" + route, body: body, expected: 200) }
    }

    private struct Branches: Decodable { let branches: [GitBranch] }
    private struct Remotes: Decodable { let remotes: [GitRemote] }
    private struct Stashes: Decodable { let stashes: [GitStash] }
    private struct ManagementBody: Encodable {
        let projectId: String
        let path: String
        var action: String? = nil
        var name: String? = nil
        var source: String? = nil
        var remote: String? = nil
        var hash: String? = nil
        var message: String? = nil
        var includeUntracked: Bool? = nil
        var files: [String]? = nil
        var confirmed: Bool? = nil
    }
}
