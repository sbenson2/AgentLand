import XCTest
import AgentLandCore
import AgentLandArchive
@testable import AgentLandWorkspace

/// The Workspaces screen's flows against a scripted host: Close ends only this device's terminals of
/// that workspace and leaves none in use, Remove asks again when work runs there, adding a folder that
/// already is a workspace opens that one, and answers for an earlier host or request are dropped.
@MainActor final class WorkspaceManagerTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated private static let capabilities =
        #"{"interactions":true,"terminal":true,"projects":{"version":1,"features":["details","browse","add","create","rename","remove"]}}"#
    nonisolated private static func project(_ id: String, _ name: String, busyChats: Int = 0, terminals: Int = 0, git: Bool = false) -> String {
        #"{"id":"\#(id)","name":"\#(name)","directory":"/Users/me/Developer/\#(name)","gitRepository":\#(git),"activity":{"busyChats":\#(busyChats),"terminals":\#(terminals)}}"#
    }
    nonisolated private static func projects(_ items: String...) -> String { #"{"projects":[\#(items.joined(separator: ","))]}"# }
    nonisolated private static func terminal(_ id: String, _ project: String, status: String = "running") -> String {
        #"{"id":"\#(id)","title":"Shell","projectId":"\#(project)","status":"\#(status)"}"#
    }
    nonisolated private static func refusal(_ code: String, _ message: String = "Refused", extra: String = "") -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"\#(extra)}}"#
    }

    private func client(_ host: ScriptedHost, address: String = "https://studio.local:9841") throws -> APIClient {
        APIClient(address: try ServerAddress(validating: address), token: "token", transport: host)
    }

    /// A workspace attached to `host`, its list and capabilities read from it.
    private func workspace(_ host: ScriptedHost, name: String = #function) async throws -> (WorkspaceModel, UserDefaults) {
        let suite = "workspace-manager-\(name)-\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = WorkspaceModel(defaults: defaults)
        workspace.attach(hostID: hostID, identity: identity, client: try client(host))
        await workspace.refreshProjects()
        XCTAssertNil(workspace.hostIssue)
        return (workspace, defaults)
    }

    private func scriptedHost(projects: String = projects(project("p1", "Alpha"), project("p2", "Beta"))) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, Self.capabilities) }
        host.on("/v1/projects") { _ in (200, projects) }
        host.on("/v1/folders") { _ in
            (200, #"{"path":"/Users/me","displayPath":"~","roots":[{"name":"Home","path":"/Users/me"},{"name":"Developer","path":"/Users/me/Developer"}],"folders":[],"truncated":false}"#)
        }
        return host
    }

    // MARK: Availability and rows

    func testTheScreenReplacesThePickerOnlyForHostsWithDetailsAndEachActionFollowsItsFeature() async throws {
        let host = scriptedHost()
        let (workspace, _) = try await workspace(host)
        let manager = workspace.workspaces
        XCTAssertTrue(manager.isAvailable)
        XCTAssertTrue(manager.canCreate && manager.canAdd && manager.canRename && manager.canRemove)

        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true,
                                                      projects: ProjectCapabilities(features: ["details", "rename"]))
        XCTAssertTrue(manager.isAvailable)
        XCTAssertFalse(manager.canCreate, "New Workspace needs create and browse")
        XCTAssertFalse(manager.canAdd)
        XCTAssertFalse(manager.canRemove)
        XCTAssertTrue(manager.canRename)

        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true)
        XCTAssertFalse(manager.isAvailable, "Hosts without the feature keep the plain picker")
    }

    func testRowsShowFoldersUnderHomeOpenWorkspacesFirstAndLastUseOnThisDevice() async throws {
        let host = scriptedHost(projects: Self.projects(Self.project("p1", "Alpha", busyChats: 2, terminals: 1, git: true),
                                                        Self.project("p2", "Beta"), Self.project("p3", "Gamma")))
        let (workspace, defaults) = try await workspace(host)
        let manager = workspace.workspaces
        XCTAssertEqual(manager.folderText("/Users/me/Developer/Alpha"), "~/Developer/Alpha", "Under /Users/<name> before a listing names home")
        XCTAssertEqual(manager.folderText("/Users/Shared/Stuff"), "/Users/Shared/Stuff")
        await manager.refresh()
        XCTAssertEqual(manager.homePath, "/Users/me", "The home listing names the home folder once")
        XCTAssertEqual(manager.folderText("/Users/me"), "~")
        XCTAssertEqual(manager.folderText("/Volumes/Work/Delta"), "/Volumes/Work/Delta")

        XCTAssertEqual(manager.all.map(\.project.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(manager.all[0].activity, "2 chats running · 1 terminal")
        XCTAssertNil(manager.all[1].activity, "Nothing runs: no activity line")
        XCTAssertTrue(manager.open.isEmpty, "Nothing is open on a fresh device")

        workspace.openWorkspace("p2")
        workspace.openWorkspace("p1")
        let open = manager.open
        XCTAssertEqual(open.map(\.id), ["p1", "p2"], "The workspace in use first, then by last use")
        XCTAssertTrue(open[0].isCurrent)
        XCTAssertEqual(open[1].openTabs, 1, "Opening a workspace opens its Files tab")
        XCTAssertNotNil(open[1].lastUsed)
        XCTAssertEqual(WorkspaceRowLabel.usage(open[0]), "In use · 1 tab open")

        // Last use is saved per host and device identity.
        let reopened = WorkspaceModel(defaults: defaults)
        reopened.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertNotNil(reopened.lastUsed["p2"])
        XCTAssertNotNil(reopened.lastUsed["p1"])
        XCTAssertNil(reopened.lastUsed["p3"])
    }

    // MARK: Close

    func testCloseEndsOnlyThisDevicesTerminalsOfThatWorkspaceAndLeavesNoneInUse() async throws {
        let host = scriptedHost()
        host.on("/v1/terminals") { request in
            // A device sees only its own terminals; p2's are not asked for.
            XCTAssertEqual(ScriptedHost.query(request)["projectId"], "p1")
            return (200, #"{"terminals":[\#(Self.terminal("t1", "p1")),\#(Self.terminal("t2", "p1")),\#(Self.terminal("t3", "p1", status: "exited"))]}"#)
        }
        host.on("/v1/terminal/close") { _ in (200, #"{"accepted":true}"#) }
        let (workspace, _) = try await workspace(host)
        let manager = workspace.workspaces
        let otherFiles = WorkspaceTab(kind: .files, projectID: "p2", title: "Files")
        workspace.open(otherFiles)
        workspace.openWorkspace("p1")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "p1", resourceID: "t1", title: "Shell")
        workspace.open(terminal)
        XCTAssertEqual(workspace.selectedProjectID, "p1")
        XCTAssertEqual(workspace.tabs(inWorkspace: "p1").count, 2)

        await manager.requestClose(try XCTUnwrap(workspace.projects.first { $0.id == "p1" }))
        let request = try XCTUnwrap(manager.pendingClose)
        XCTAssertEqual(request.title, "Close Alpha?")
        XCTAssertEqual(request.liveTerminals, 2, "An exited terminal doesn't count as running")
        XCTAssertEqual(request.message, "Its 2 tabs close on this device and its 2 terminals end.")

        await manager.close(request)
        XCTAssertTrue(workspace.tabs(inWorkspace: "p1").isEmpty, "Its tabs close on this device")
        XCTAssertEqual(workspace.tabs.map(\.id), [otherFiles.id], "Other workspaces' tabs stay")
        XCTAssertNil(workspace.selectedProjectID, "The workspace in use no longer is: Home offers the list")
        XCTAssertNil(workspace.selectedTabID)
        XCTAssertNil(workspace.currentProject)
        let closed = host.bodies("/v1/terminal/close")
        XCTAssertEqual(closed.compactMap { $0["terminalId"] as? String }, ["t1", "t2", "t3"])
        XCTAssertEqual(Set(closed.compactMap { $0["projectId"] as? String }), ["p1"], "Only that workspace's terminals end")
        XCTAssertNil(manager.notice)
        XCTAssertTrue(host.requests("/v1/projects/remove").isEmpty, "Closing never removes the workspace")
    }

    func testCloseMessagesCountTabsTerminalsAndUnsavedEdits() {
        let project = Project(id: "p", name: "Notes")
        XCTAssertEqual(WorkspaceCloseRequest(project: project, tabs: 1).message, "Its 1 tab closes on this device.")
        XCTAssertEqual(WorkspaceCloseRequest(project: project, tabs: 0, terminals: [RemoteTerminal(id: "t", title: "Shell", projectID: "p", status: .running, exitCode: nil)]).message,
                       "Its 1 terminal ends.")
        XCTAssertEqual(WorkspaceCloseRequest(project: project, tabs: 3, unsavedEditors: 1).message,
                       "Its 3 tabs close on this device. Unsaved changes in 1 file are discarded.")
        XCTAssertEqual(WorkspaceCloseRequest(project: project, tabs: 0).message, "This workspace closes on this device.")
    }

    func testClosedWorkspaceMenuStateSurvivesReattachAndOpeningRestoresIt() async throws {
        let host = scriptedHost()
        let (workspace, defaults) = try await workspace(host)
        workspace.openWorkspace("p1", openFilesIfEmpty: false)
        workspace.closeWorkspace("p1")
        XCTAssertTrue(workspace.closedWorkspaceIDs.contains("p1"))
        XCTAssertTrue(workspace.projects.contains { $0.id == "p1" }, "Closing does not remove the host's workspace")

        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: try client(host))
        await restored.refreshProjects()
        XCTAssertTrue(restored.closedWorkspaceIDs.contains("p1"))
        restored.openWorkspace("p1", openFilesIfEmpty: false)
        XCTAssertFalse(restored.closedWorkspaceIDs.contains("p1"))
        XCTAssertEqual(restored.selectedProjectID, "p1")

        restored.closeWorkspace("p1")
        // Reproduce an older save: last use remains, but explicit closed-menu state did not exist.
        for key in defaults.dictionaryRepresentation().keys where key.contains("closedInMenu.") {
            defaults.removeObject(forKey: key)
        }
        let migrated = WorkspaceModel(defaults: defaults)
        migrated.attach(hostID: hostID, identity: identity, client: try client(host))
        XCTAssertTrue(migrated.closedWorkspaceIDs.contains("p1"))
    }

    func testPhoneCloseCountExcludesDrawerPagesButClosingStillRemovesThem() async throws {
        let host = scriptedHost()
        host.on("/v1/terminals") { _ in (200, #"{"terminals":[]}"#) }
        let (workspace, _) = try await workspace(host)
        let project = try XCTUnwrap(workspace.projects.first { $0.id == "p1" })
        workspace.open(WorkspaceTab(kind: .files, projectID: "p1", title: "Files"))
        workspace.open(WorkspaceTab(kind: .git, projectID: "p1", title: "Git"))
        let manager = workspace.workspaces
        XCTAssertEqual(manager.summary(project).openTabs, 2, "On iPad and Mac these are tabs")

        workspace.phoneNavigation.drawerHoldsBrowsers = true
        XCTAssertEqual(manager.summary(project).openTabs, 0)
        await manager.requestClose(project)
        XCTAssertEqual(try XCTUnwrap(manager.pendingClose).tabs, 0)

        workspace.open(WorkspaceTab(kind: .terminal, projectID: "p1", resourceID: "t1", title: "Shell"))
        XCTAssertEqual(manager.summary(project).openTabs, 1)
        await manager.requestClose(project)
        let request = try XCTUnwrap(manager.pendingClose)
        XCTAssertEqual(request.tabs, 1)
        await manager.close(request)
        XCTAssertTrue(workspace.tabs(inWorkspace: "p1").isEmpty, "Closing also releases the hidden drawer pages")
    }

    // MARK: Remove

    func testABusyWorkspaceAsksAgainAndEndTerminalsAndRemoveSendsTheForce() async throws {
        let host = scriptedHost()
        host.on("/v1/projects/remove") { request in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            if body["endTerminals"] as? Bool == true {
                host.on("/v1/projects") { _ in (200, Self.projects(Self.project("p2", "Beta"))) }
                return (200, #"{"removed":true}"#)
            }
            return (409, Self.refusal("workspace_busy", "The workspace is in use", extra: #","busyChats":0,"terminals":2"#))
        }
        let (workspace, _) = try await workspace(host)
        let manager = workspace.workspaces
        workspace.openWorkspace("p1")
        let alpha = try XCTUnwrap(workspace.projects.first { $0.id == "p1" })

        manager.requestRemoval(alpha)
        XCTAssertEqual(manager.pendingRemoval, alpha)
        await manager.remove(alpha)
        let busy = try XCTUnwrap(manager.busyRemoval, "The host's refusal becomes the second question")
        XCTAssertEqual(busy.terminals, 2)
        XCTAssertTrue(busy.canEndTerminals)
        XCTAssertEqual(workspace.selectedProjectID, "p1", "Nothing changes on this device while the host refuses")
        XCTAssertEqual(host.bodies("/v1/projects/remove").first?["endTerminals"] as? Bool, nil, "The first ask never forces")

        await manager.remove(busy.project, endTerminals: true)
        XCTAssertEqual(host.bodies("/v1/projects/remove").last?["endTerminals"] as? Bool, true)
        XCTAssertNil(manager.busyRemoval)
        XCTAssertEqual(workspace.projects.map(\.id), ["p2"])
        XCTAssertTrue(workspace.tabs(inWorkspace: "p1").isEmpty, "A removed workspace's tabs close here")
        XCTAssertNil(workspace.selectedProjectID)
        XCTAssertNil(workspace.lastUsed["p1"])
        XCTAssertEqual(manager.notice?.title, "Removed Alpha")
        XCTAssertEqual(manager.notice?.tone, .success)
    }

    func testARunningChatCannotBeForcedAndTheLastWorkspaceIsExplained() async throws {
        let host = scriptedHost()
        host.on("/v1/projects/remove") { _ in
            (409, Self.refusal("workspace_busy", "The workspace is in use", extra: #","busyChats":1,"terminals":0"#))
        }
        let (workspace, _) = try await workspace(host)
        let manager = workspace.workspaces
        let alpha = try XCTUnwrap(workspace.projects.first)
        await manager.remove(alpha)
        XCTAssertEqual(manager.busyRemoval?.canEndTerminals, false, "A running chat turn still refuses: nothing to force")

        host.on("/v1/projects/remove") { _ in (409, Self.refusal("last_workspace", "The last workspace cannot be removed")) }
        await manager.remove(alpha)
        XCTAssertNil(manager.busyRemoval)
        XCTAssertEqual(manager.notice?.title, "Alpha is the only workspace")
        XCTAssertEqual(workspace.projects.count, 2, "Nothing is forgotten on a refusal")
    }

    func testChangesAreRefusedOfflineWithoutSendingAnything() async throws {
        let host = scriptedHost()
        let (workspace, _) = try await workspace(host)
        let manager = workspace.workspaces
        workspace.reachable = false
        await manager.remove(try XCTUnwrap(workspace.projects.first))
        await manager.rename(try XCTUnwrap(workspace.projects.first), to: "Renamed")
        XCTAssertTrue(host.requests("/v1/projects/remove").isEmpty)
        XCTAssertTrue(host.requests("/v1/projects/rename").isEmpty)
        XCTAssertEqual(manager.notice?.tone, .warning)
        let added = await manager.add(directory: "/Users/me/Notes")
        guard case .problem = added else { return XCTFail("Adding offline is refused, got \(added)") }
        XCTAssertTrue(host.requests("/v1/projects").allSatisfy { $0.httpMethod == "GET" })
    }

    // MARK: Add and create

    func testAddingAFolderThatIsAlreadyAWorkspaceSelectsThatWorkspace() async throws {
        let host = scriptedHost()
        let (workspace, _) = try await workspace(host)
        host.on("/v1/projects") { request in
            if request.httpMethod == "POST" {
                return (409, Self.refusal("already_workspace", "That folder is already a workspace", extra: #","projectId":"p2""#))
            }
            return (200, Self.projects(Self.project("p1", "Alpha"), Self.project("p2", "Beta")))
        }
        let result = await workspace.workspaces.add(directory: "/Users/me/Developer/Beta")
        XCTAssertEqual(result, .open("p2"), "The existing workspace opens")
        XCTAssertEqual(workspace.projects.count, 2, "No second workspace for the same folder")
        // The shell opens what the screen hands it.
        workspace.openWorkspace("p2")
        XCTAssertEqual(workspace.selectedProjectID, "p2")
    }

    func testANewWorkspaceIsListedAndOpenedAndATakenNameKeepsTheSheet() async throws {
        let host = scriptedHost()
        let (workspace, _) = try await workspace(host)
        let made = Self.project("p9", "Fresh", git: true)
        host.on("/v1/projects/create") { request in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            if body["name"] as? String == "Taken" { return (409, Self.refusal("already_exists", "Exists")) }
            host.on("/v1/projects") { _ in (200, Self.projects(Self.project("p1", "Alpha"), Self.project("p2", "Beta"), made)) }
            return (201, made)
        }
        let manager = workspace.workspaces
        let taken = await manager.create(parentDirectory: "/Users/me/Developer", name: "Taken", git: false)
        XCTAssertEqual(taken, .problem("“Taken” is already in ~/Developer. Choose another name."))
        let invalid = await manager.create(parentDirectory: "/Users/me/Developer", name: ".secret", git: false)
        XCTAssertEqual(invalid, .problem("A folder name can’t start with a period."))
        XCTAssertEqual(host.requests("/v1/projects/create").count, 1, "An invalid name is never sent")

        let result = await manager.create(parentDirectory: "/Users/me/Developer", name: " Fresh ", git: true)
        XCTAssertEqual(result, .open("p9"))
        let sent = try XCTUnwrap(host.bodies("/v1/projects/create").last)
        XCTAssertEqual(sent["name"] as? String, "Fresh", "The name goes trimmed")
        XCTAssertEqual(sent["git"] as? Bool, true)
        XCTAssertTrue(workspace.projects.contains { $0.id == "p9" && $0.gitRepository })
    }

    func testAnUnconfirmedAddOpensTheWorkspaceWhenTheListShowsIt() async throws {
        let host = scriptedHost()
        let (workspace, _) = try await workspace(host)
        host.on("/v1/projects") { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, Self.projects(Self.project("p1", "Alpha"), Self.project("p2", "Beta"), Self.project("p7", "Notes")))
        }
        let result = await workspace.workspaces.add(directory: "/Users/me/Developer/Notes")
        XCTAssertEqual(result, .open("p7"), "Read again, the list shows the folder was added")
        XCTAssertEqual(host.requests("/v1/projects").filter { $0.httpMethod == "POST" }.count, 1, "Never sent again")
    }

    // MARK: Changes from other devices

    /// A host's change feed: one page in the first epoch, then (another device removed a workspace) a
    /// resync page in the next, then nothing new.
    private actor EpochFeed: ArchiveChangeFeed {
        private var calls = 0
        func archiveChanges(after cursor: String?, limit: Int, wait: Duration?) async throws -> ArchiveChangesPage {
            calls += 1
            switch calls {
            case 1: return ArchiveChangesPage(epoch: "e1", changes: [], cursor: "e1.0")
            case 2: return ArchiveChangesPage(epoch: "e2", resync: true, changes: [], cursor: "e2.0")
            default: return ArchiveChangesPage(epoch: "e2", changes: [], cursor: "e2.0")
            }
        }
    }

    func testAnotherEpochOnTheHostsFeedReadsTheWorkspacesAgain() async throws {
        let host = scriptedHost()
        let (workspace, _) = try await workspace(host)
        XCTAssertEqual(workspace.projects.map(\.id), ["p1", "p2"])
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, archive: ArchiveCapabilities(features: ["sync"]))
        let engine = SyncEngine(store: store, feed: EpochFeed(), capabilities: capabilities, followInterval: .milliseconds(20))
        let archive = WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil, engine: engine)
        workspace.openArchive({ archive })
        await waitUntil("the copy to attach") { workspace.archive === archive }
        // Another device removes Beta: the host's list changes and its feed moves to another epoch.
        host.on("/v1/projects") { _ in (200, Self.projects(Self.project("p1", "Alpha"))) }
        archive.setRunning(true)
        await waitUntil("the list read again", timeout: 5) { workspace.projects.map(\.id) == ["p1"] }
        XCTAssertEqual(workspace.capabilities?.supportsProjects(.remove), true)
        archive.close()
    }

    // MARK: Stale answers

    func testAnAnswerForAnEarlierHostIsDropped() async throws {
        let host = scriptedHost()
        let gate = Gate()
        let arrived = Gate()
        host.on("/v1/projects/rename") { _ in
            await arrived.open()
            await gate.wait()
            return (200, Self.project("p1", "Renamed"))
        }
        let (workspace, _) = try await workspace(host)
        let manager = workspace.workspaces
        let alpha = try XCTUnwrap(workspace.projects.first)
        let rename = Task { await manager.rename(alpha, to: "Renamed") }
        await arrive(at: arrived, "the rename")
        XCTAssertTrue(manager.changing.contains("p1"))

        // Another host is attached while the answer is on its way.
        let other = scriptedHost(projects: Self.projects(Self.project("p1", "Other Alpha")))
        workspace.attach(hostID: "https://other.local|device-a", identity: ConnectionIdentity(host: "https://other.local", deviceID: "device-a"),
                         client: try client(other, address: "https://other.local"))
        await workspace.refreshProjects()
        await gate.open()
        await rename.value
        XCTAssertEqual(workspace.projects.map(\.name), ["Other Alpha"], "The earlier host's answer changes nothing here")
        XCTAssertNil(manager.notice)
        XCTAssertTrue(manager.changing.isEmpty)
    }

    func testAnEarlierFolderListingNeverReplacesANewerOne() async throws {
        let host = scriptedHost()
        let gate = Gate()
        let arrived = Gate()
        host.on("/v1/folders") { request in
            let path = ScriptedHost.query(request)["path"] ?? ""
            if path == "/Users/me/Slow" {
                await arrived.open()
                await gate.wait()
            }
            let display = path.replacingOccurrences(of: "/Users/me", with: "~")
            return (200, #"{"path":"\#(path)","displayPath":"\#(display)","parent":"/Users/me","roots":[],"folders":[],"truncated":false}"#)
        }
        let (workspace, _) = try await workspace(host)
        let browser = FolderBrowserModel(workspaces: workspace.workspaces)
        let slow = Task { await browser.open("/Users/me/Slow") }
        await arrive(at: arrived, "the slow listing")
        await browser.open("/Users/me/Developer")
        XCTAssertEqual(browser.listing?.path, "/Users/me/Developer")
        await gate.open()
        await slow.value
        XCTAssertEqual(browser.listing?.path, "/Users/me/Developer", "The earlier answer is dropped")
        XCTAssertEqual(browser.breadcrumb.map(\.name), ["~", "Developer"])
        XCTAssertEqual(browser.breadcrumb.map(\.path), ["/Users/me", "/Users/me/Developer"])
        XCTAssertEqual(workspace.workspaces.homePath, "/Users/me", "A listing under ~ names the home folder")
    }
}
