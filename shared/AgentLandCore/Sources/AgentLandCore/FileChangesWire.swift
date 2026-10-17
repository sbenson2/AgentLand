import Foundation

// Project file changes (docs/HOST-API.md, "Files"): move and rename, new folders, uploads and
// deletes. Hosts list what they serve in `capabilities.files`; the client asks only for those.
// Nothing here retries: a change whose answer was lost is reported as not confirmed.

/// How a file change ended.
public enum FileChangeOutcome<Value: Sendable & Equatable>: Equatable, Sendable {
    /// The host made the change and answered with the new item.
    case done(Value)
    /// The name is taken. The host never replaces anything; `suggestedName` is a free name in the same
    /// folder ("name 2.txt"), or nil when it found none.
    case nameTaken(suggestedName: String?)
    /// The host refused, or the request provably never reached it.
    case failed(ClientError)
    /// The connection ended before an answer, or the answer was unreadable: the change may have been
    /// made. The caller re-reads the folder rather than sending it again.
    case uncertain
}

/// How a delete ended.
public enum FileDeleteOutcome: Equatable, Sendable {
    /// Moved to the host's Trash under `trashName` (a taken name becomes "name 2").
    case trashed(trashName: String?)
    /// Removed for good after the explicit confirmation.
    case deleted
    /// The item can't go to the Trash (another volume, or a host without one). When
    /// `permanentDeleteAllowed`, it can be deleted for good with `confirmPath` set to its path.
    case trashUnavailable(permanentDeleteAllowed: Bool)
    case failed(ClientError)
    case uncertain
}

/// Options of a content search (docs/HOST-API.md, "Files"): `q` is 1–512 bytes on one line; regular
/// expressions are Go RE2; `include` takes up to 16 comma-separated globs in 256 bytes.
public struct FileSearchOptions: Equatable, Sendable {
    public static let maximumQueryBytes = 512
    public static let maximumIncludePatterns = 16
    public static let maximumIncludeBytes = 256

    public var query: String
    /// The folder to search in, relative to the project; empty for the whole project.
    public var path: String
    public var regex: Bool
    public var caseSensitive: Bool
    public var include: [String]

    public init(query: String, path: String = "", regex: Bool = false, caseSensitive: Bool = false, include: [String] = []) {
        self.query = query; self.path = path; self.regex = regex; self.caseSensitive = caseSensitive; self.include = include
    }

    /// Whether the host takes this query: 1–512 bytes without a line break, and at most 16 include
    /// patterns in 256 bytes.
    public var isValid: Bool {
        let bytes = query.utf8.count
        guard bytes >= 1, bytes <= Self.maximumQueryBytes, !query.contains(where: \.isNewline) else { return false }
        let patterns = include.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return patterns.count <= Self.maximumIncludePatterns && patterns.joined(separator: ",").utf8.count <= Self.maximumIncludeBytes
    }
}

/// Why a content search stopped early.
public enum FileSearchLimit: String, Sendable {
    case files, bytes, matches, time

    /// A sentence for under the results.
    public var explanation: String {
        switch self {
        case .files: "The search stopped after 20,000 files. Search a smaller folder to see the rest."
        case .bytes: "The search stopped after reading 64 MB. Search a smaller folder to see the rest."
        case .matches: "Showing the first 500 matching lines. Refine the search to see others."
        case .time: "The search stopped after 5 seconds. Search a smaller folder to see the rest."
        }
    }
}

public extension FileSearchResponse {
    var limit: FileSearchLimit? { truncatedReason.flatMap(FileSearchLimit.init(rawValue:)) }
}

extension APIClient {
    /// Content search with the contract's options. `regex`, `caseSensitive` and `include` go out only
    /// when set, so a plain search reads the same as before.
    public func searchFiles(projectID: String, options: FileSearchOptions) async throws -> FileSearchResponse {
        var items = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "q", value: options.query)]
        if !options.path.isEmpty { items.append(URLQueryItem(name: "path", value: options.path)) }
        if options.regex { items.append(URLQueryItem(name: "regex", value: "true")) }
        if options.caseSensitive { items.append(URLQueryItem(name: "caseSensitive", value: "true")) }
        let patterns = options.include.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !patterns.isEmpty { items.append(URLQueryItem(name: "include", value: patterns.joined(separator: ","))) }
        return try await get("/v1/files/search", query: items, timeout: 15)
    }

    /// `POST /v1/files/move`: moves or renames `from` to `to` (both relative to the project). It
    /// never replaces an item that is already there.
    public func moveFile(projectID: String, from: String, to: String) async -> FileChangeOutcome<FileEntry> {
        await fileChange { try await self.postWithRefusal("/v1/files/move", body: MoveBody(projectID: projectID, from: from, to: to), expected: 200) }
    }

    /// `POST /v1/files/mkdir`: a new, empty folder at `path`.
    public func makeFolder(projectID: String, path: String) async -> FileChangeOutcome<FileEntry> {
        await fileChange { try await self.postWithRefusal("/v1/files/mkdir", body: PathBody(projectID: projectID, path: path), expected: 201) }
    }

    /// `POST /v1/files/upload`: the file at `file` becomes a new file at `path`, sent with its length.
    /// `progress` hears the bytes sent so far and the total. It never replaces an existing file.
    public func uploadFile(projectID: String, path: String, from file: URL,
                           progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void = { _, _ in }) async -> FileChangeOutcome<FileEntry> {
        await fileChange {
            try Task.checkCancellation()
            var request = try self.makeRequest(path: "/v1/files/upload", method: "POST", query: [
                URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: path)
            ])
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // The time without progress, not the whole upload: the host allows 2 minutes plus a
            // second per 256 KiB.
            request.timeoutInterval = 120
            let (data, response) = try await self.transport.upload(request, fromFile: file, progress: progress)
            try self.validateWithRefusal(response, data: data, expected: 201)
            do { return try ProtocolDecoder.decode(FileEntry.self, from: data) } catch { throw ClientError.decoding }
        }
    }

    /// `POST /v1/files/delete`: moves `path` to the host's Trash, or with `permanent` removes it for
    /// good. A permanent delete carries `confirmPath`, which must repeat the path exactly.
    public func deleteFile(projectID: String, path: String, permanent: Bool = false) async -> FileDeleteOutcome {
        let body = DeleteBody(projectID: projectID, path: path, permanent: permanent ? true : nil, confirmPath: permanent ? path : nil)
        do {
            let receipt: DeleteReceipt = try await postWithRefusal("/v1/files/delete", body: body, expected: 200)
            return receipt.trashed ? .trashed(trashName: receipt.trashName) : .deleted
        } catch let refusal as HostRefusal {
            if refusal.error.code == "trash_unavailable" {
                return .trashUnavailable(permanentDeleteAllowed: refusal.error.permanentDeleteAllowed ?? false)
            }
            switch mutationOutcome(for: refusal.clientError) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    private func fileChange(_ request: () async throws -> FileEntry) async -> FileChangeOutcome<FileEntry> {
        do { return .done(try await request()) }
        catch let refusal as HostRefusal {
            if refusal.error.code == "file_exists" {
                return .nameTaken(suggestedName: refusal.error.suggestedName?.isEmpty == false ? refusal.error.suggestedName : nil)
            }
            switch mutationOutcome(for: refusal.clientError) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch is CancellationError {
            return .uncertain
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    private struct MoveBody: Encodable {
        let projectID: String; let from: String; let to: String
        enum CodingKeys: String, CodingKey { case projectID = "projectId", from, to }
    }
    private struct PathBody: Encodable {
        let projectID: String; let path: String
        enum CodingKeys: String, CodingKey { case projectID = "projectId", path }
    }
    private struct DeleteBody: Encodable {
        let projectID: String; let path: String; let permanent: Bool?; let confirmPath: String?
        enum CodingKeys: String, CodingKey { case projectID = "projectId", path, permanent, confirmPath }
    }
    private struct DeleteReceipt: Decodable { let path: String?; let trashed: Bool; let trashName: String? }
}

// MARK: Refusals with extra members

/// The error envelope's members beyond `code` and `message` that file, Git and workspace changes read
/// (docs/HOST-API.md: `suggestedName`, `permanentDeleteAllowed`, `outcome`; `projectId`, `busyChats`,
/// `terminals`).
struct DetailedAPIError: Decodable, Sendable {
    let code: String
    let message: String
    let suggestedName: String?
    let permanentDeleteAllowed: Bool?
    let outcome: String?
    let projectId: String?
    let busyChats: Int?
    let terminals: Int?
}

/// A host refusal read with its extra members.
struct HostRefusal: Error, Sendable {
    let status: Int
    let error: DetailedAPIError
    var clientError: ClientError { .server(code: error.code, message: error.message) }
}

extension APIClient {
    /// Like `validate`, but a refusal keeps the envelope's extra members.
    func validateWithRefusal(_ response: HTTPURLResponse, data: Data, expected: Int) throws {
        guard response.statusCode == expected else {
            struct Envelope: Decodable { let error: DetailedAPIError }
            if let envelope = try? ProtocolDecoder.decode(Envelope.self, from: data) {
                throw HostRefusal(status: response.statusCode, error: envelope.error)
            }
            throw ClientError.unexpectedStatus(response.statusCode)
        }
    }

    func postWithRefusal<T: Decodable, Body: Encodable>(_ path: String, body: Body, expected: Int) async throws -> T {
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.execute(request)
        try validateWithRefusal(response, data: data, expected: expected)
        do { return try ProtocolDecoder.decode(T.self, from: data) } catch { throw ClientError.decoding }
    }
}
