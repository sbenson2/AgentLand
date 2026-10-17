import Foundation

// Git changes (docs/HOST-API.md, "Git"): stage and unstage, commits with the identity the host
// reports, and diffs of the staged and the unstaged changes. Hosts list what they serve in
// `capabilities.git`; the client asks only for those. A change whose answer was lost, and a Git
// timeout, are reported as not confirmed and never sent again by the client.

/// A Git feature a host lists in `capabilities.git`.
public enum GitFeature: String, Sendable, CaseIterable {
    case stage, unstage, commit, stagedDiff, unstagedDiff, identity
    case branches, history, remotes, stashes, discard, untrackedFiles
}

public extension CapabilitiesResponse {
    /// A Git feature. Hosts that list none claim none.
    func supportsGit(_ feature: GitFeature) -> Bool { git.contains(feature.rawValue) }
}

/// Where a commit's name and email come from.
public enum GitIdentitySource: String, Sendable {
    /// Both from the repository's configuration.
    case repository
    /// The user's global configuration supplies one or both.
    case user
    /// One is missing: a commit would be refused.
    case none
}

/// The name and email a commit would use (`GET /v1/git/identity`).
public struct GitIdentity: Codable, Hashable, Sendable {
    public let name: String
    public let email: String
    public let source: GitIdentitySource

    public init(name: String, email: String, source: GitIdentitySource) {
        self.name = name; self.email = email; self.source = source
    }

    /// Both values are known, so a commit can use them.
    public var isComplete: Bool { source != .none && !name.isEmpty && !email.isEmpty }

    /// "Name <email>", as Git writes it.
    public var formatted: String { "\(name) <\(email)>" }

    enum CodingKeys: String, CodingKey { case name, email, source }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        // A source this version doesn't know counts as missing, so nothing is claimed.
        source = (try container.decodeIfPresent(String.self, forKey: .source)).flatMap(GitIdentitySource.init(rawValue:)) ?? .none
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(source.rawValue, forKey: .source)
    }
}

/// What a file's diff compares.
public enum GitDiffBase: String, Sendable, CaseIterable {
    /// The working tree against HEAD (every host).
    case head
    /// The index against HEAD: the staged changes (`staged=1`, hosts with `stagedDiff`).
    case staged
    /// The working tree against the index: the unstaged changes, untracked files as new files
    /// (`against=index`, hosts with `unstagedDiff`).
    case index
}

/// A refusal of a Git change, by its stable code.
public enum GitRefusal: Equatable, Sendable {
    /// Another Git change is running in the repository (the host waited 5 s).
    case busy
    /// `.git/index.lock` is left over.
    case indexLocked
    case nothingToCommit
    /// No name or email is configured.
    case identityMissing
    /// Unresolved merge conflicts.
    case conflict
    /// A file uses a Git filter such as Git LFS.
    case filterUnsupported
    /// The repository or the user's configuration sets `commit.gpgsign`.
    case signingRequired
    /// A path is missing from the repository or ignored.
    case pathInvalid
    /// Git failed for another reason.
    case failed
    /// Any other refusal, with the host's message.
    case other(code: String, message: String)

    init(code: String, message: String) {
        switch code {
        case "git_busy": self = .busy
        case "git_index_locked": self = .indexLocked
        case "git_nothing_to_commit": self = .nothingToCommit
        case "git_identity_missing": self = .identityMissing
        case "git_conflict": self = .conflict
        case "git_filter_unsupported": self = .filterUnsupported
        case "git_signing_required": self = .signingRequired
        case "git_path_invalid": self = .pathInvalid
        case "git_failed": self = .failed
        default: self = .other(code: code, message: message)
        }
    }
}

/// A commit the host made: the full hash, and that hooks did not run.
public struct GitCommitReceipt: Codable, Hashable, Sendable {
    public let commit: String
    public let hooksSkipped: Bool

    public init(commit: String, hooksSkipped: Bool) { self.commit = commit; self.hooksSkipped = hooksSkipped }

    /// The first seven characters, as Git shows a commit.
    public var shortHash: String { String(commit.prefix(7)) }

    enum CodingKeys: String, CodingKey { case commit, hooksSkipped }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commit = try container.decodeIfPresent(String.self, forKey: .commit) ?? ""
        hooksSkipped = try container.decodeIfPresent(Bool.self, forKey: .hooksSkipped) ?? false
    }
}

/// How a Git change ended.
public enum GitChangeOutcome<Value: Sendable & Equatable>: Equatable, Sendable {
    case done(Value)
    /// Git or the host refused; nothing changed.
    case refused(GitRefusal)
    /// The request failed before Git ran, or provably never reached the host.
    case failed(ClientError)
    /// The answer was lost, or Git timed out (`git_timeout`, outcome unknown): the change may have
    /// been made. It is never sent again by itself.
    case uncertain(timedOut: Bool)
}

extension APIClient {
    /// A file's diff against `base`. The query adds `staged=1` or `against=index`; `head` sends neither,
    /// as older hosts expect.
    public func gitDiff(projectID: String, repository: String, file: String, base: GitDiffBase) async throws -> GitDiffResponse {
        var query = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: repository),
                     URLQueryItem(name: "file", value: file)]
        switch base {
        case .head: break
        case .staged: query.append(URLQueryItem(name: "staged", value: "1"))
        case .index: query.append(URLQueryItem(name: "against", value: "index"))
        }
        return try await get("/v1/git/diff", query: query)
    }

    /// `GET /v1/git/identity`: who a commit in `repository` would be made as.
    public func gitIdentity(projectID: String, repository: String) async throws -> GitIdentity {
        try await get("/v1/git/identity", query: [URLQueryItem(name: "projectId", value: projectID),
                                                  URLQueryItem(name: "path", value: repository)])
    }

    /// `POST /v1/git/stage`: adds up to 500 repository paths (a folder as status shows it, with its
    /// trailing slash) to the index. Answers how many paths were staged.
    public func gitStage(projectID: String, repository: String, files: [String]) async -> GitChangeOutcome<Int> {
        await gitChange {
            let answer: StagedAnswer = try await self.postWithRefusal("/v1/git/stage", body: FilesBody(projectID: projectID, path: repository, files: files),
                                                                       expected: 200)
            return answer.staged
        }
    }

    /// `POST /v1/git/unstage`: takes up to 500 paths out of the index (a rename takes both its paths).
    public func gitUnstage(projectID: String, repository: String, files: [String]) async -> GitChangeOutcome<Int> {
        await gitChange {
            let answer: UnstagedAnswer = try await self.postWithRefusal("/v1/git/unstage", body: FilesBody(projectID: projectID, path: repository, files: files),
                                                                         expected: 200)
            return answer.unstaged
        }
    }

    /// `POST /v1/git/commit`: commits what is staged with `message` (at most 16 KiB). `author` goes out
    /// only when given: the identity the host reported, so the commit is made as the app showed.
    public func gitCommit(projectID: String, repository: String, message: String, author: GitIdentity? = nil) async -> GitChangeOutcome<GitCommitReceipt> {
        let body = CommitBody(projectID: projectID, path: repository, message: message,
                              author: author.map { CommitAuthor(name: $0.name, email: $0.email) })
        return await gitChange { try await self.postWithRefusal("/v1/git/commit", body: body, expected: 200) }
    }

    func gitChange<Value: Sendable & Equatable>(_ request: () async throws -> Value) async -> GitChangeOutcome<Value> {
        do { return .done(try await request()) }
        catch let refusal as HostRefusal {
            // A timeout's outcome is unknown: the change may have been made.
            if refusal.error.code == "git_timeout" { return .uncertain(timedOut: true) }
            if refusal.error.outcome == "unknown" { return .uncertain(timedOut: false) }
            if refusal.error.code.hasPrefix("git_") { return .refused(GitRefusal(code: refusal.error.code, message: refusal.error.message)) }
            switch mutationOutcome(for: refusal.clientError) {
            case .uncertain, .accepted: return .uncertain(timedOut: false)
            case let .failed(error): return .failed(error)
            }
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain(timedOut: false)
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain(timedOut: false) }
    }

    private struct FilesBody: Encodable {
        let projectID: String; let path: String; let files: [String]
        enum CodingKeys: String, CodingKey { case projectID = "projectId", path, files }
    }
    private struct CommitAuthor: Encodable { let name: String; let email: String }
    private struct CommitBody: Encodable {
        let projectID: String; let path: String; let message: String; let author: CommitAuthor?
        enum CodingKeys: String, CodingKey { case projectID = "projectId", path, message, author }
    }
    private struct StagedAnswer: Decodable { let staged: Int }
    private struct UnstagedAnswer: Decodable { let unstaged: Int }
}
