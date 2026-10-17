import Foundation

// Workspaces (docs/HOST-API.md, "Workspaces"): the folders on the Mac the host works in, called
// projects in the host's routes. Hosts list what they serve in `capabilities.projects.features`; the
// client uses a route or field only when its feature is listed. Changes apply on the host at once.
// Nothing here retries: a change whose answer was lost is reported as not confirmed, and the caller
// reads the list again.

/// A workspace feature a host lists in `capabilities.projects.features`.
public enum ProjectFeature: String, Sendable, CaseIterable {
    /// `GET /v1/projects` adds each workspace's folder, Git badge and activity.
    case details
    /// `GET /v1/folders`: the folders inside the Mac user's home folder.
    case browse
    /// `POST /v1/projects`: a folder becomes a workspace.
    case add
    /// `POST /v1/projects/create`: a new folder, optionally a Git repository, becomes a workspace.
    case create
    /// `POST /v1/projects/rename`: a workspace's display name.
    case rename
    /// `POST /v1/projects/remove`: a workspace leaves the list; its files stay.
    case remove
}

/// `capabilities.projects`.
public struct ProjectCapabilities: Codable, Hashable, Sendable {
    public var version: Int
    /// `ProjectFeature` names.
    public var features: [String]

    public init(version: Int = 1, features: [String] = []) {
        self.version = version
        self.features = features
    }

    enum CodingKeys: String, CodingKey { case version, features }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        features = (try? container.decodeIfPresent([String].self, forKey: .features)).flatMap { $0 } ?? []
    }

    public func supports(_ feature: ProjectFeature) -> Bool { features.contains(feature.rawValue) }
}

public extension CapabilitiesResponse {
    /// A workspace feature. Hosts without `projects` claim none.
    func supportsProjects(_ feature: ProjectFeature) -> Bool { projects?.supports(feature) == true }
}

// MARK: Folders

/// A place a folder listing offers to start from: the home folder, its Developer, Desktop and
/// Documents folders, and the folders the workspaces are in.
public struct FolderRoot: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public var id: String { path }

    public init(name: String, path: String) { self.name = name; self.path = path }
}

/// A folder inside the listed one.
public struct FolderEntry: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    /// Absolute, on the Mac.
    public let path: String
    /// The workspace this folder already is.
    public let workspaceID: String?
    /// The folder holds a `.git` entry.
    public let gitRepository: Bool
    public var id: String { path }

    public init(name: String, path: String, workspaceID: String? = nil, gitRepository: Bool = false) {
        self.name = name; self.path = path; self.workspaceID = workspaceID; self.gitRepository = gitRepository
    }

    enum CodingKeys: String, CodingKey { case name, path, workspaceID = "workspaceId", gitRepository }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        workspaceID = (try? container.decodeIfPresent(String.self, forKey: .workspaceID)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        gitRepository = (try? container.decodeIfPresent(Bool.self, forKey: .gitRepository)).flatMap { $0 } ?? false
    }
}

/// `GET /v1/folders`: one folder's sub-folders (never files), sorted as the host sorts them.
public struct FolderListing: Codable, Hashable, Sendable {
    /// The listed folder, absolute.
    public let path: String
    /// `path` with the home folder shown as `~`.
    public let displayPath: String
    /// The folder above it, while that is inside the home folder.
    public let parent: String?
    public let roots: [FolderRoot]
    public let folders: [FolderEntry]
    /// The folder has more than 2,000 sub-folders; the rest are left out.
    public let truncated: Bool

    public init(path: String, displayPath: String, parent: String? = nil, roots: [FolderRoot] = [], folders: [FolderEntry] = [],
                truncated: Bool = false) {
        self.path = path; self.displayPath = displayPath; self.parent = parent; self.roots = roots; self.folders = folders
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey { case path, displayPath, parent, roots, folders, truncated }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        displayPath = try container.decodeIfPresent(String.self, forKey: .displayPath) ?? path
        parent = (try? container.decodeIfPresent(String.self, forKey: .parent)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        roots = (try? container.decodeIfPresent([FolderRoot].self, forKey: .roots)).flatMap { $0 } ?? []
        folders = try container.decodeIfPresent([FolderEntry].self, forKey: .folders) ?? []
        truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)).flatMap { $0 } ?? false
    }
}

// MARK: Outcomes

/// How adding, creating or renaming a workspace ended.
public enum ProjectChangeOutcome: Equatable, Sendable {
    /// The host made the change and answered with the workspace.
    case done(Project)
    /// Add: the folder already is a workspace (`projectID`, when the host named it).
    case alreadyWorkspace(projectID: String?)
    /// Create: a file or folder of that name is already in the chosen folder.
    case alreadyExists
    /// Create: the folder was made and added as the workspace `projectID` (when the host named it), but
    /// Git could not start a repository in it.
    case gitFailed(projectID: String?, message: String)
    /// The host refused, or the request provably never reached it.
    case failed(ClientError)
    /// The connection ended before an answer, or the answer was unreadable: the change may have been
    /// made. The caller reads the list again rather than sending it again.
    case uncertain
}

/// How removing a workspace ended.
public enum ProjectRemoveOutcome: Equatable, Sendable {
    case removed
    /// A chat turn runs in it, or terminals are live in it, on any device. Sending again with
    /// `endTerminals` ends the terminals first; a running chat turn still refuses.
    case busy(busyChats: Int, terminals: Int)
    /// The host keeps at least one workspace.
    case lastWorkspace
    case failed(ClientError)
    case uncertain
}

// MARK: Names

/// The names the host takes (docs/HOST-API.md, "Workspaces"): 1–100 characters after trimming, without
/// `=` or line breaks; a new folder's name is also a single path component that does not start with a
/// dot. The host checks again; these let a form say why before anything is sent.
public enum WorkspaceNaming {
    public static let maximumLength = 100

    /// The trimmed display name, or nil when the host would refuse it.
    public static func displayName(_ raw: String) -> String? {
        problem(name: raw) == nil ? trimmed(raw) : nil
    }

    /// The trimmed name of a new folder (also its workspace's name), or nil when the host would refuse it.
    public static func folderName(_ raw: String) -> String? {
        problem(folder: raw) == nil ? trimmed(raw) : nil
    }

    /// Why the host would refuse `raw` as a display name; nil when it takes it.
    public static func problem(name raw: String) -> String? {
        let name = trimmed(raw)
        if name.isEmpty { return "Enter a name." }
        // The host counts Unicode characters (code points).
        if name.unicodeScalars.count > maximumLength { return "Use at most \(maximumLength) characters." }
        if name.contains("=") { return "A name can’t contain “=”." }
        if name.contains(where: \.isNewline) { return "A name can’t contain line breaks." }
        return nil
    }

    /// Why the host would refuse `raw` as a new folder's name; nil when it takes it.
    public static func problem(folder raw: String) -> String? {
        if let problem = problem(name: raw) { return problem }
        let name = trimmed(raw)
        if name.contains("/") || name.contains("\0") { return "A folder name can’t contain “/”." }
        if name == "." || name == ".." || name.hasPrefix(".") { return "A folder name can’t start with a period." }
        return nil
    }

    private static func trimmed(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: Routes

extension APIClient {
    /// `GET /v1/folders`: the sub-folders of `path` (absolute; the home folder when nil). Dot folders
    /// only with `includeHidden`.
    public func folders(path: String? = nil, includeHidden: Bool = false) async throws -> FolderListing {
        var query: [URLQueryItem] = []
        if let path, !path.isEmpty { query.append(URLQueryItem(name: "path", value: path)) }
        if includeHidden { query.append(URLQueryItem(name: "hidden", value: "1")) }
        return try await get("/v1/folders", query: query)
    }

    /// `POST /v1/projects`: `directory` (absolute, inside the home folder) becomes a workspace, named
    /// after the folder unless `name` is given.
    public func addProject(directory: String, name: String? = nil) async -> ProjectChangeOutcome {
        await projectChange {
            try await self.postWithRefusal("/v1/projects", body: AddBody(directory: directory, name: name?.isEmpty == false ? name : nil),
                                           expected: 201)
        }
    }

    /// `POST /v1/projects/create`: makes `parentDirectory/name` and adds it; with `git` the host runs
    /// `git init -b main` in it first.
    public func createProject(parentDirectory: String, name: String, git: Bool) async -> ProjectChangeOutcome {
        await projectChange {
            try await self.postWithRefusal("/v1/projects/create",
                                           body: CreateBody(parentDirectory: parentDirectory, name: name, git: git ? true : nil),
                                           expected: 201)
        }
    }

    /// `POST /v1/projects/rename`: changes only the display name.
    public func renameProject(id: String, name: String) async -> ProjectChangeOutcome {
        await projectChange {
            try await self.postWithRefusal("/v1/projects/rename", body: RenameBody(id: id, name: name), expected: 200)
        }
    }

    /// `POST /v1/projects/remove`: the workspace leaves the list and its files stay. `endTerminals`
    /// (sent only when true) ends its live terminals first.
    public func removeProject(id: String, endTerminals: Bool = false) async -> ProjectRemoveOutcome {
        do {
            let receipt: RemovedReceipt = try await postWithRefusal("/v1/projects/remove",
                                                                    body: RemoveBody(id: id, endTerminals: endTerminals ? true : nil),
                                                                    expected: 200)
            return receipt.removed ? .removed : .uncertain
        } catch let refusal as HostRefusal {
            switch refusal.error.code {
            case "workspace_busy":
                return .busy(busyChats: max(0, refusal.error.busyChats ?? 0), terminals: max(0, refusal.error.terminals ?? 0))
            case "last_workspace":
                return .lastWorkspace
            default:
                return refusalOutcome(refusal).map(ProjectRemoveOutcome.failed) ?? .uncertain
            }
        } catch let error as ClientError {
            return failure(error).map(ProjectRemoveOutcome.failed) ?? .uncertain
        } catch is CancellationError {
            return .uncertain
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    private func projectChange(_ request: () async throws -> Project) async -> ProjectChangeOutcome {
        do { return .done(try await request()) }
        catch let refusal as HostRefusal {
            switch refusal.error.code {
            case "already_workspace":
                return .alreadyWorkspace(projectID: refusal.error.projectId?.isEmpty == false ? refusal.error.projectId : nil)
            case "already_exists":
                return .alreadyExists
            case "git_failed":
                return .gitFailed(projectID: refusal.error.projectId?.isEmpty == false ? refusal.error.projectId : nil,
                                  message: refusal.error.message)
            default:
                return refusalOutcome(refusal).map(ProjectChangeOutcome.failed) ?? .uncertain
            }
        } catch let error as ClientError {
            return failure(error).map(ProjectChangeOutcome.failed) ?? .uncertain
        } catch is CancellationError {
            return .uncertain
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    /// A refusal the host named is a failure, except a server error: a workspace change it could not
    /// finish may have made a folder or saved part of the state, so that is not confirmed either way. A
    /// full disk (507 `insufficient_storage`) made nothing.
    private func refusalOutcome(_ refusal: HostRefusal) -> ClientError? {
        guard refusal.status < 500 || refusal.error.code == "insufficient_storage" else { return nil }
        return failure(refusal.clientError)
    }

    /// The error of a change that certainly failed; nil when it may have been made.
    private func failure(_ error: ClientError) -> ClientError? {
        if case let .failed(error) = mutationOutcome(for: error) { return error }
        return nil
    }

    private struct AddBody: Encodable { let directory: String; let name: String? }
    private struct CreateBody: Encodable { let parentDirectory: String; let name: String; let git: Bool? }
    private struct RenameBody: Encodable { let id: String; let name: String }
    private struct RemoveBody: Encodable { let id: String; let endTerminals: Bool? }
    private struct RemovedReceipt: Decodable { let removed: Bool }
}
