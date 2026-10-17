import Foundation
import XCTest
@testable import AgentLandCore

/// The workspace routes (docs/HOST-API.md, "Workspaces") through a real `URLSession` answered by the
/// stub protocol, so bodies, queries and headers are the ones production sends.
final class ProjectsClientTests: XCTestCase {
    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private static func refusal(_ code: String, _ message: String, extra: String = "") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"\#(extra)}}"#.utf8)
    }

    private static let project = #"{"id":"w2","name":"Notes","directory":"/Users/me/Developer/Notes","gitRepository":true,"activity":{"busyChats":0,"terminals":0}}"#

    // MARK: Capabilities and the list

    func testCapabilitiesListTheWorkspaceFeaturesAndOlderHostsClaimNone() throws {
        let body = #"{"interactions":true,"terminal":true,"projects":{"version":1,"features":["details","browse","add","create","rename","remove"]}}"#
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(body.utf8))
        XCTAssertTrue(ProjectFeature.allCases.allSatisfy(capabilities.supportsProjects))
        XCTAssertEqual(capabilities.projects?.version, 1)

        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":false}"#.utf8))
        XCTAssertNil(older.projects)
        XCTAssertFalse(ProjectFeature.allCases.contains(where: older.supportsProjects), "A host without the entry claims nothing")
        let unreadable = try ProtocolDecoder.decode(CapabilitiesResponse.self,
                                                    from: Data(#"{"interactions":true,"terminal":false,"projects":["details"]}"#.utf8))
        XCTAssertNil(unreadable.projects, "An entry this version cannot read offers nothing")
        let partial = try ProtocolDecoder.decode(CapabilitiesResponse.self,
                                                 from: Data(#"{"interactions":true,"terminal":false,"projects":{"version":1,"features":["details"]}}"#.utf8))
        XCTAssertTrue(partial.supportsProjects(.details))
        XCTAssertFalse(partial.supportsProjects(.remove))
    }

    func testTheListReadsDetailsWhenTheHostSendsThemAndPlainWorkspacesOtherwise() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/projects")
            XCTAssertNil(request.url?.query, "Details need no query: the host sends them when it lists the feature")
            return (200, Data(#"{"projects":[\#(Self.project),{"id":"plain","name":"Plain"},{"id":"odd","name":"Odd","directory":7,"activity":"busy"}]}"#.utf8))
        }
        let projects = try await (try client()).projects()
        XCTAssertEqual(projects[0], Project(id: "w2", name: "Notes", directory: "/Users/me/Developer/Notes", gitRepository: true,
                                            activity: ProjectActivity(busyChats: 0, terminals: 0)))
        XCTAssertEqual(projects[1], Project(id: "plain", name: "Plain"))
        XCTAssertNil(projects[1].directory)
        XCTAssertFalse(projects[1].gitRepository)
        XCTAssertEqual(projects[2], Project(id: "odd", name: "Odd"), "Details this version cannot read never cost the workspace")
    }

    // MARK: Folders

    func testFoldersAskForAPathAndHiddenFoldersOnlyWhenSet() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/folders")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
            return (200, Data(#"""
            {"path":"/Users/me","displayPath":"~","roots":[{"name":"Home","path":"/Users/me"},{"name":"Developer","path":"/Users/me/Developer"}],
             "folders":[{"name":"Developer","path":"/Users/me/Developer","gitRepository":false},
                        {"name":"Notes","path":"/Users/me/Notes","workspaceId":"w2","gitRepository":true}],"truncated":false}
            """#.utf8))
        }
        let home = try await api.folders()
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), [:], "The home folder is the default")
        XCTAssertEqual(home.path, "/Users/me")
        XCTAssertEqual(home.displayPath, "~")
        XCTAssertNil(home.parent)
        XCTAssertEqual(home.roots.map(\.name), ["Home", "Developer"])
        XCTAssertEqual(home.folders[1], FolderEntry(name: "Notes", path: "/Users/me/Notes", workspaceID: "w2", gitRepository: true))
        XCTAssertNil(home.folders[0].workspaceID)
        XCTAssertFalse(home.truncated)

        ArchiveStubProtocol.install { _, _ in
            (200, Data(#"{"path":"/Users/me/Developer","displayPath":"~/Developer","parent":"/Users/me","roots":[],"folders":[],"truncated":true}"#.utf8))
        }
        let developer = try await api.folders(path: "/Users/me/Developer", includeHidden: true)
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["path": "/Users/me/Developer", "hidden": "1"])
        XCTAssertEqual(developer.parent, "/Users/me")
        XCTAssertTrue(developer.truncated)

        ArchiveStubProtocol.install { _, _ in (404, Self.refusal("not_found", "Folder not found")) }
        do {
            _ = try await api.folders(path: "/private/etc")
            XCTFail("A folder outside the home folder is refused")
        } catch let error as ClientError {
            XCTAssertEqual(error, .server(code: "not_found", message: "Folder not found"))
        }
    }

    // MARK: Add and create

    func testAddSendsTheFolderAndANameOnlyWhenGiven() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/projects")
            XCTAssertEqual(request.httpMethod, "POST")
            return (201, Data(Self.project.utf8))
        }
        let added = await api.addProject(directory: "/Users/me/Developer/Notes")
        guard case let .done(project) = added else { return XCTFail("Expected the workspace, got \(added)") }
        XCTAssertEqual(project.id, "w2")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["directory": "/Users/me/Developer/Notes"])

        _ = await api.addProject(directory: "/Users/me/Notes", name: "Notebook")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["directory": "/Users/me/Notes", "name": "Notebook"])
    }

    func testAddingAFolderThatIsAlreadyAWorkspaceNamesTheWorkspace() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in
            (409, Self.refusal("already_workspace", "That folder is already a workspace", extra: #","projectId":"w2""#))
        }
        let outcome = await api.addProject(directory: "/Users/me/Developer/Notes")
        XCTAssertEqual(outcome, .alreadyWorkspace(projectID: "w2"))
        ArchiveStubProtocol.install { _, _ in (409, Self.refusal("already_workspace", "That folder is already a workspace")) }
        let unnamed = await api.addProject(directory: "/Users/me/Developer/Notes")
        XCTAssertEqual(unnamed, .alreadyWorkspace(projectID: nil))
    }

    func testCreateSendsGitOnlyWhenAskedAndReportsATakenNameAndAFailedGitInit() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/projects/create")
            return (201, Data(Self.project.utf8))
        }
        let made = await api.createProject(parentDirectory: "/Users/me/Developer", name: "Notes", git: true)
        guard case .done = made else { return XCTFail("Expected the workspace, got \(made)") }
        let sent = try json(ArchiveStubProtocol.requests.last?.body)
        XCTAssertEqual(sent["parentDirectory"] as? String, "/Users/me/Developer")
        XCTAssertEqual(sent["name"] as? String, "Notes")
        XCTAssertEqual(sent["git"] as? Bool, true)
        _ = await api.createProject(parentDirectory: "/Users/me/Developer", name: "Plain", git: false)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String],
                       ["parentDirectory": "/Users/me/Developer", "name": "Plain"], "No git member without Git")

        ArchiveStubProtocol.install { _, _ in (409, Self.refusal("already_exists", "A file or folder with that name already exists")) }
        let taken = await api.createProject(parentDirectory: "/Users/me/Developer", name: "Notes", git: false)
        XCTAssertEqual(taken, .alreadyExists)

        ArchiveStubProtocol.install { _, _ in
            (500, Self.refusal("git_failed", "git init failed; the folder was added", extra: #","projectId":"notes-3f9a2c""#))
        }
        let gitFailed = await api.createProject(parentDirectory: "/Users/me/Developer", name: "Notes", git: true)
        XCTAssertEqual(gitFailed, .gitFailed(projectID: "notes-3f9a2c", message: "git init failed; the folder was added"))

        ArchiveStubProtocol.install { _, _ in (500, Self.refusal("internal", "Internal error")) }
        let broken = await api.createProject(parentDirectory: "/Users/me/Developer", name: "Notes", git: false)
        XCTAssertEqual(broken, .uncertain, "A server error may have made the folder: not confirmed either way")

        ArchiveStubProtocol.install { _, _ in (507, Self.refusal("insufficient_storage", "The disk is full")) }
        let full = await api.createProject(parentDirectory: "/Users/me/Developer", name: "Notes", git: false)
        XCTAssertEqual(full, .failed(.server(code: "insufficient_storage", message: "The disk is full")), "A full disk made nothing")
    }

    // MARK: Rename and remove

    func testRenameSendsTheIdAndNameAndReportsARefusal() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/projects/rename")
            return (200, Data(#"{"id":"w2","name":"Renamed","directory":"/Users/me/Developer/Notes","gitRepository":true}"#.utf8))
        }
        let renamed = await api.renameProject(id: "w2", name: "Renamed")
        guard case let .done(project) = renamed else { return XCTFail("Expected the workspace, got \(renamed)") }
        XCTAssertEqual(project.name, "Renamed")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["id": "w2", "name": "Renamed"])

        ArchiveStubProtocol.install { _, _ in (400, Self.refusal("invalid_name", "Names can't contain =")) }
        let refused = await api.renameProject(id: "w2", name: "a=b")
        XCTAssertEqual(refused, .failed(.server(code: "invalid_name", message: "Names can't contain =")))
    }

    func testRemoveSendsEndTerminalsOnlyWhenAskedAndReadsBusyAndLastWorkspace() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/projects/remove")
            return (200, Data(#"{"removed":true}"#.utf8))
        }
        let removed = await api.removeProject(id: "w2")
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["id": "w2"])
        _ = await api.removeProject(id: "w2", endTerminals: true)
        let forced = try json(ArchiveStubProtocol.requests.last?.body)
        XCTAssertEqual(forced["id"] as? String, "w2")
        XCTAssertEqual(forced["endTerminals"] as? Bool, true)

        ArchiveStubProtocol.install { _, _ in
            (409, Self.refusal("workspace_busy", "The workspace is in use", extra: #","busyChats":1,"terminals":2"#))
        }
        let busy = await api.removeProject(id: "w2")
        XCTAssertEqual(busy, .busy(busyChats: 1, terminals: 2))
        ArchiveStubProtocol.install { _, _ in (409, Self.refusal("last_workspace", "The last workspace cannot be removed")) }
        let last = await api.removeProject(id: "w2")
        XCTAssertEqual(last, .lastWorkspace)
    }

    func testAChangeThatNeverReachedTheHostFailsAndALostAnswerIsNotConfirmed() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await api.removeProject(id: "w2")
        XCTAssertEqual(unreachable, .failed(.unreachable))
        let notAdded = await api.addProject(directory: "/Users/me/Notes")
        XCTAssertEqual(notAdded, .failed(.unreachable))

        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        let lostRemove = await api.removeProject(id: "w2")
        XCTAssertEqual(lostRemove, .uncertain)
        let lostRename = await api.renameProject(id: "w2", name: "Renamed")
        XCTAssertEqual(lostRename, .uncertain)

        ArchiveStubProtocol.install { _, _ in (201, Data("not json".utf8)) }
        let unreadable = await api.createProject(parentDirectory: "/Users/me", name: "New", git: false)
        XCTAssertEqual(unreadable, .uncertain, "An answer this version cannot read may still mean the folder was made")
    }

    // MARK: Names

    func testNamesFollowTheHostsRules() {
        XCTAssertEqual(WorkspaceNaming.displayName("  Notes \n"), "Notes")
        XCTAssertNil(WorkspaceNaming.displayName("   "))
        XCTAssertNil(WorkspaceNaming.displayName("a=b"))
        XCTAssertNil(WorkspaceNaming.displayName("two\nlines"))
        XCTAssertEqual(WorkspaceNaming.displayName(String(repeating: "x", count: 100))?.count, 100)
        XCTAssertNil(WorkspaceNaming.displayName(String(repeating: "x", count: 101)))
        XCTAssertEqual(WorkspaceNaming.problem(name: String(repeating: "x", count: 101)), "Use at most 100 characters.")

        XCTAssertEqual(WorkspaceNaming.folderName("New Project"), "New Project")
        XCTAssertNil(WorkspaceNaming.folderName("a/b"))
        XCTAssertNil(WorkspaceNaming.folderName("."))
        XCTAssertNil(WorkspaceNaming.folderName(".."))
        XCTAssertNil(WorkspaceNaming.folderName(".hidden"))
        XCTAssertNil(WorkspaceNaming.folderName("a=b"))
        XCTAssertEqual(WorkspaceNaming.problem(folder: ".config"), "A folder name can’t start with a period.")
        XCTAssertNil(WorkspaceNaming.problem(folder: "Notes"))
    }
}
