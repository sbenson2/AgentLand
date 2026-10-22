import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// "On <device>" on the Workspace tab: the running terminals of the owner's other devices and of the Mac, grouped by
/// device, newest first; a tap opens one in its workspace or on its own; closing a shared tab only stops following it.
@MainActor final class OtherDevicesModelTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private let now = Date(timeIntervalSince1970: 1_791_978_063)
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    nonisolated private static let projects =
        #"{"projects":[{"id":"p1","name":"Alpha","directory":"/Users/me/Developer/Alpha"},{"id":"p2","name":"Beta","directory":"/Users/me/Developer/Beta"}]}"#

    /// A host whose terminals are shared (`shared` in `terminalFeatures`) unless `features` says otherwise.
    private func workspace(features: String = #"["title","resume","shared"]"#) async throws -> (WorkspaceModel, ScriptedHost) {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in
            (200, #"{"interactions":true,"terminal":true,"terminalPrograms":["shell","claude"],"terminalFeatures":\#(features),"#
                + #""projects":{"version":1,"features":["details","browse","add"]}}"#)
        }
        host.on("/v1/projects") { _ in (200, Self.projects) }
        host.on("/v1/terminal/output") { _ in (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","exitCode":0}"#) }
        host.on("/v1/terminal/input") { _ in (200, #"{"accepted":true}"#) }
        host.on("/v1/terminal/resize") { _ in (200, #"{"accepted":true}"#) }
        host.on("/v1/terminal/close") { _ in (200, #"{"accepted":true}"#) }
        host.on("/v1/terminals") { _ in (200, #"{"terminals":[]}"#) }
        let suite = "other-devices-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.hostName = "Mac mini"
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await workspace.refreshProjects()
        return (workspace, host)
    }

    /// Lifts the opening cover, as the app does once the workspace has shown, so typing is taken.
    private func uncover(_ workspace: WorkspaceModel) throws {
        let ticket = try XCTUnwrap(workspace.presentationTicket)
        workspace.resolvePresentationOffline()
        XCTAssertTrue(workspace.completePresentation(ticket))
        XCTAssertFalse(workspace.presentationPending)
    }

    private func iPadTerminal(id: String = "t7", projectID: String? = "p1", workspace: String? = "Alpha",
                              folder: String = "/Users/me/Developer/Alpha", displayFolder: String = "~/Developer/Alpha") -> SharedTerminal {
        SharedTerminal(id: id, deviceID: "ipad-1", deviceName: "Sam's iPad", program: "claude", title: "Claude Code",
                       folder: folder, displayFolder: displayFolder, programTitle: "✳ Fix login", projectID: projectID,
                       workspace: workspace, activity: .working, lastOutputAt: now, lastActiveAt: now)
    }

    private static func json(_ terminal: SharedTerminal) throws -> String {
        String(decoding: try JSONEncoder().encode(terminal), as: UTF8.self)
    }

    private static func programName(_ id: String) -> String { TerminalProgram.named(id, by: nil).displayName }

    // MARK: Sections

    func testSectionsGroupByDeviceNewestFirst() async throws {
        let older = SharedTerminal(id: "m2", deviceID: "local-mac", deviceName: "", program: "shell", title: "Terminal",
                                   displayFolder: "~/Notes", onMac: true, lastActiveAt: now.addingTimeInterval(-100))
        let newer = SharedTerminal(id: "m1", deviceID: "local-mac", deviceName: "", program: "claude", title: "Claude Code",
                                   displayFolder: "~/Developer/Alpha", onMac: true, routed: true, programTitle: "⠂ Thinking",
                                   projectID: "p1", workspace: "Alpha", activity: .working, lastActiveAt: now.addingTimeInterval(-10))
        let iPad = SharedTerminal(id: "i1", deviceID: "ipad-1", deviceName: "Sam's iPad", program: "shell", title: "Terminal",
                                  displayFolder: "~", lastActiveAt: now.addingTimeInterval(-50))
        let own = SharedTerminal(id: "o1", deviceID: "device-a", deviceName: "This iPhone", program: "shell", title: "Terminal",
                                 lastActiveAt: now)
        let sections = OtherDevicesModel.sections(from: [iPad, older, own, newer], hostName: "Mac mini", ownDeviceID: "device-a",
                                                  programName: Self.programName, now: now)
        XCTAssertEqual(sections.map(\.title), ["On Mac mini", "On Sam's iPad"])
        XCTAssertEqual(sections.map(\.glyph), ["desktopcomputer", "ipad"])
        XCTAssertEqual(sections.map(\.id), ["local-mac", "ipad-1"])
        XCTAssertEqual(sections.first?.rows.map(\.id), ["m1", "m2"], "Rows newest first")
        XCTAssertEqual(sections.first?.rows.first?.title, "Thinking")
        XCTAssertEqual(sections.first?.rows.first?.programID, "claude")
        XCTAssertFalse(sections.flatMap(\.rows).contains { $0.id == "o1" }, "This device's own terminals are not listed")
        XCTAssertTrue(OtherDevicesModel.sections(from: [], hostName: "Mac mini", ownDeviceID: nil, programName: Self.programName,
                                                 now: now).isEmpty)
        let phone = SharedTerminal(id: "x1", deviceID: "iphone-2", deviceName: "Ana’s iPhone", program: "shell", title: "Terminal")
        XCTAssertEqual(OtherDevicesModel.sections(from: [phone], hostName: "Mac mini", ownDeviceID: nil,
                                                  programName: Self.programName, now: now).first?.glyph, "iphone")

        // Read from the host: the host's name for the Mac's own, and this device's own left out.
        let (workspace, host) = try await workspace()
        let listed = try [newer, iPad, own].map(Self.json).joined(separator: ",")
        host.on("/v1/terminals/others") { _ in (200, #"{"terminals":[\#(listed)]}"#) }
        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/terminals/others").count, 1)
        XCTAssertEqual(workspace.others.sections.map(\.title), ["On Mac mini", "On Sam's iPad"])
        XCTAssertEqual(workspace.others.sections.first?.rows.first?.subtitle, "Claude Code · Alpha")
        XCTAssertEqual(workspace.others.sections.flatMap(\.rows).map(\.id), ["m1", "i1"])
    }

    /// A device with only the model's name (what iOS gives apps) is "another iPhone", never "On iPhone" on an iPhone.
    func testSectionTitleNamesAGenericDeviceAsAnother() {
        func title(_ name: String) -> String {
            OtherDevicesModel.sectionTitle(SharedTerminal(id: "t", deviceID: "d", deviceName: name, program: "shell", title: "Terminal"),
                                           hostName: "Mac mini")
        }
        XCTAssertEqual(title("iPhone"), "On another iPhone")
        XCTAssertEqual(title(" ipad "), "On another iPad")
        XCTAssertEqual(title(""), "On another device")
        XCTAssertEqual(title("Sam's iPhone"), "On Sam's iPhone")
        XCTAssertEqual(title("Test iPhone"), "On Test iPhone")
    }

    func testRowTitleFallsBack() {
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "✳ Fix login", contextTitle: nil, programName: "Claude Code"), "Fix login")
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "⠂ Thinking", contextTitle: nil, programName: "Claude Code"), "Thinking")
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "✻ ", contextTitle: "Tests", programName: "Claude Code"), "Tests")
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: nil, contextTitle: nil, programName: "Claude Code"), "Claude Code")
        // The task comes first, as in the tab's name (`RemoteTerminal.displayTitle`).
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "* · ✳️ Build", contextTitle: "Tests", programName: "Claude Code"), "Tests")
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "✳ Fix login", contextTitle: "Repair Safari login", programName: "Claude Code"),
                       "Repair Safari login")
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "* · ✳️ Build", contextTitle: " ", programName: "Claude Code"), "Build")
        XCTAssertEqual(OtherDevicesModel.rowTitle(programTitle: "", contextTitle: "", programName: "Shell"), "Shell")
    }

    func testStatusText() {
        func status(_ activity: SharedTerminal.Activity, _ output: TimeInterval?) -> String {
            OtherDevicesModel.statusText(SharedTerminal(id: "t", deviceID: "d", deviceName: "iPad", program: "shell", title: "Terminal",
                                                        activity: activity, lastOutputAt: output.map { now.addingTimeInterval(-$0) }),
                                         now: now)
        }
        XCTAssertEqual(status(.working, 1), "Working")
        XCTAssertEqual(status(.waiting, 400), "Waiting for you")
        XCTAssertEqual(status(.quiet, 30), "Quiet · <1m")
        XCTAssertEqual(status(.quiet, 300), "Quiet · 5m")
        XCTAssertEqual(status(.quiet, 2 * 3600 + 120), "Quiet · 2h")
        XCTAssertEqual(status(.quiet, 3 * 86_400 + 60), "Quiet · 3d")
        XCTAssertEqual(status(.quiet, nil), "Quiet")
        XCTAssertEqual(status(.quiet, -5), "Quiet · <1m", "A clock ahead of this device's is no time at all")
    }

    func testSubtitleNamesTheWorkspaceOrTheFolder() {
        let inWorkspace = iPadTerminal()
        let outside = SharedTerminal(id: "t8", deviceID: "ipad-1", deviceName: "Sam's iPad", program: "shell", title: "Terminal",
                                     folder: "/Users/me/Notes", displayFolder: "~/Notes", lastActiveAt: now.addingTimeInterval(-5))
        let rows = OtherDevicesModel.sections(from: [inWorkspace, outside], hostName: "Mac mini", ownDeviceID: nil,
                                              programName: Self.programName, now: now).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.subtitle), ["Claude Code · Alpha", "Shell · ~/Notes"])
        XCTAssertEqual(rows.map(\.title), ["Fix login", "Shell"])
        XCTAssertEqual(rows.map(\.status), ["Working", "Quiet"])
    }

    func testNoRequestWhenTheHostDoesNotShare() async throws {
        let (workspace, host) = try await workspace(features: #"["title","resume"]"#)
        host.on("/v1/terminals/others") { _ in (200, #"{"terminals":[]}"#) }
        await workspace.others.refresh()
        await workspace.workspaces.refresh()
        XCTAssertTrue(host.requests("/v1/terminals/others").isEmpty)
        XCTAssertTrue(workspace.others.sections.isEmpty)
    }

    /// The lock covers the workspace and the list stays mounted under it: nothing is read until it lifts, and the list
    /// keeps what it showed. An unreachable host is not asked either.
    func testNothingIsReadWhileLockedOrUnreachable() async throws {
        let (workspace, host) = try await workspace()
        let listed = try Self.json(iPadTerminal())
        host.on("/v1/terminals/others") { _ in (200, #"{"terminals":[\#(listed)]}"#) }
        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/terminals/others").count, 1)

        workspace.locked = true
        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/terminals/others").count, 1, "Nothing is read under the lock")
        XCTAssertEqual(workspace.others.sections.flatMap(\.rows).map(\.id), ["t7"], "The list keeps what it showed")
        workspace.locked = false
        workspace.reachable = false
        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/terminals/others").count, 1, "Nothing is asked of a host that doesn't answer")

        workspace.reachable = true
        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/terminals/others").count, 2, "The next read goes once both are back")
    }

    /// A read in flight when the host stops sharing its terminals answers too late: the emptied list stays empty.
    func testAReadInFlightWhenSharingStopsIsDropped() async throws {
        let (workspace, host) = try await workspace()
        let gate = Gate()
        let listed = try Self.json(iPadTerminal())
        host.on("/v1/terminals/others") { _ in
            await gate.wait()
            return (200, #"{"terminals":[\#(listed)]}"#)
        }
        let reading = Task { await workspace.others.refresh() }
        await waitUntil("the read on its way") { host.requests("/v1/terminals/others").count == 1 }

        host.on("/v1/capabilities") { _ in
            (200, #"{"interactions":true,"terminal":true,"terminalPrograms":["shell","claude"],"terminalFeatures":["title","resume"],"#
                + #""projects":{"version":1,"features":["details","browse","add"]}}"#)
        }
        await workspace.refreshCapabilities()
        await workspace.others.refresh()
        XCTAssertTrue(workspace.others.sections.isEmpty)

        await gate.open()
        await reading.value
        XCTAssertTrue(workspace.others.sections.isEmpty, "The older read's answer never puts the list back")
        XCTAssertEqual(host.requests("/v1/terminals/others").count, 1)
    }

    // MARK: Opening

    func testTapInAWorkspaceOpensItAsATab() async throws {
        let (workspace, _) = try await workspace()
        workspace.openWorkspace("p2", openFilesIfEmpty: false)
        let terminal = iPadTerminal()
        guard case let .tab(id) = workspace.openShared(terminal) else { return XCTFail("A terminal of a workspace opens as its tab") }
        XCTAssertEqual(workspace.selectedProjectID, "p1")
        XCTAssertEqual(workspace.selectedTabID, id)
        let tab = try XCTUnwrap(workspace.tab(id))
        XCTAssertEqual(tab.kind, .terminal)
        XCTAssertEqual(tab.projectID, "p1")
        XCTAssertEqual(tab.resourceID, "t7")
        XCTAssertEqual(tab.sharedFrom, SharedOrigin(deviceName: "Sam's iPad", onMac: false, routed: false))
        let count = workspace.tabs.count

        workspace.openWorkspace("p2", openFilesIfEmpty: false)
        XCTAssertEqual(workspace.openShared(terminal), .tab(id), "The open tab is selected, never a second one")
        XCTAssertEqual(workspace.tabs.count, count)
        XCTAssertEqual(workspace.selectedTabID, id)
        XCTAssertEqual(workspace.selectedProjectID, "p1")
    }

    /// A workspace added on another device since this device read the projects: the row names it, so the projects are
    /// read once (not on every 4 s read) and the tap opens the terminal in that workspace, not the standalone screen.
    func testARowNamingAnUnreadWorkspaceReadsTheProjectsOnce() async throws {
        let (workspace, host) = try await workspace()
        XCTAssertNil(workspace.projects.first { $0.id == "p3" })
        host.on("/v1/projects") { _ in
            (200, #"{"projects":[{"id":"p1","name":"Alpha","directory":"/a"},{"id":"p3","name":"Tower","directory":"/Users/me/Developer/tower"}]}"#)
        }
        let tower = iPadTerminal(id: "t9", projectID: "p3", workspace: "tower", folder: "/Users/me/Developer/tower", displayFolder: "~/Developer/tower")
        let towerBody = #"{"terminals":[\#(try Self.json(tower))]}"#
        host.on("/v1/terminals/others") { _ in (200, towerBody) }
        let before = host.requests("/v1/projects").count

        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/projects").count, before + 1, "The unknown workspace is read for")
        XCTAssertTrue(workspace.projects.contains { $0.id == "p3" })
        guard case .tab = workspace.openShared(tower) else { return XCTFail("It opens in its workspace") }

        // A workspace the host does not list stays unknown: asked once, not at every read.
        let ghost = iPadTerminal(id: "t10", projectID: "gone", workspace: "gone")
        let ghostBody = #"{"terminals":[\#(try Self.json(ghost))]}"#
        host.on("/v1/terminals/others") { _ in (200, ghostBody) }
        await workspace.others.refresh()
        let afterGhost = host.requests("/v1/projects").count
        await workspace.others.refresh()
        await workspace.others.refresh()
        XCTAssertEqual(host.requests("/v1/projects").count, afterGhost, "Once per unknown ID")
    }

    /// The rows, a shared tab and a standalone screen say the same name: each list read names the tab and the screen as
    /// it names the row (the task first), the screen's own program titles name it live, and a device's name stays over
    /// the program's later titles on both.
    func testSharedTabsAndStandaloneScreensFollowTheirRowsNames() async throws {
        let (workspace, host) = try await workspace()
        guard case let .tab(id) = workspace.openShared(iPadTerminal()) else { return XCTFail("Opens as a tab") }
        let outside = iPadTerminal(id: "t8", projectID: nil, workspace: nil, folder: "/Users/me/Notes", displayFolder: "~/Notes")
        guard case let .standalone(route) = workspace.openShared(outside) else { return XCTFail("Opens on its own") }
        let tab = try XCTUnwrap(workspace.tab(id))
        XCTAssertEqual(tab.title, "Fix login")
        let screen = workspace.terminalSession(for: route.tab)
        screen.programTitleChanged("✳ Tidy imports")
        XCTAssertEqual(screen.shownTitle, "Tidy imports", "The screen follows its program live")

        func named(_ terminal: SharedTerminal) -> SharedTerminal {
            SharedTerminal(id: terminal.id, deviceID: terminal.deviceID, deviceName: terminal.deviceName, program: terminal.program,
                           title: terminal.title, folder: terminal.folder, displayFolder: terminal.displayFolder,
                           programTitle: "✳ Deploying", contextTitle: "Repair Safari login", contextTitleSource: .device,
                           projectID: terminal.projectID, workspace: terminal.workspace, lastActiveAt: now)
        }
        let body = #"{"terminals":["# + (try [named(iPadTerminal()), named(outside)].map(Self.json).joined(separator: ",")) + "]}"
        host.on("/v1/terminals/others") { _ in (200, body) }
        await workspace.others.refresh()
        XCTAssertEqual(workspace.others.sections.first?.rows.map(\.title), ["Repair Safari login", "Repair Safari login"])
        XCTAssertEqual(workspace.tab(id)?.title, "Repair Safari login")
        XCTAssertEqual(screen.shownTitle, "Repair Safari login")

        workspace.terminalSession(for: tab).programTitleChanged("✳ Testing")
        screen.programTitleChanged("✳ Testing")
        XCTAssertEqual(workspace.tab(id)?.title, "Repair Safari login", "A device's name stays, as the host keeps it")
        XCTAssertEqual(screen.shownTitle, "Repair Safari login")
    }

    func testTapOutsideAWorkspaceIsStandalone() async throws {
        let (workspace, _) = try await workspace()
        let outside = iPadTerminal(id: "t8", projectID: nil, workspace: nil, folder: "/Users/me/Notes", displayFolder: "~/Notes")
        guard case let .standalone(route) = workspace.openShared(outside) else { return XCTFail("Outside any workspace it opens on its own") }
        XCTAssertEqual(route.tab.projectID, "")
        XCTAssertEqual(route.tab.kind, .terminal)
        XCTAssertEqual(route.tab.resourceID, "t8")
        XCTAssertEqual(route.tab.sharedFrom, SharedOrigin(deviceName: "Sam's iPad", onMac: false, routed: false))
        XCTAssertEqual(route.folder, "/Users/me/Notes")
        XCTAssertEqual(route.displayFolder, "~/Notes")
        XCTAssertFalse(workspace.tabs.contains { $0.resourceID == "t8" }, "A standalone terminal never joins the tabs")
        XCTAssertNil(workspace.selectedTabID)

        // A workspace this device does not know (removed since) is no workspace to open it in.
        let unknown = iPadTerminal(id: "t9", projectID: "p404", workspace: "Gone")
        guard case .standalone = workspace.openShared(unknown) else { return XCTFail("An unknown workspace opens it on its own") }
        XCTAssertFalse(workspace.tabs.contains { $0.resourceID == "t9" })
    }

    func testAddAsWorkspaceMovesTheTerminalIntoIt() async throws {
        let (workspace, host) = try await workspace()
        let added = #"{"id":"p9","name":"Notes","directory":"/Users/me/Notes"}"#
        host.on("/v1/projects") { request in
            if request.httpMethod == "POST" {
                host.on("/v1/projects") { _ in
                    (200, #"{"projects":[{"id":"p1","name":"Alpha","directory":"/Users/me/Developer/Alpha"},\#(added)]}"#)
                }
                return (201, added)
            }
            return (200, Self.projects)
        }
        let outside = iPadTerminal(id: "t8", projectID: nil, workspace: nil, folder: "/Users/me/Notes", displayFolder: "~/Notes")
        guard case let .standalone(route) = workspace.openShared(outside) else { return XCTFail("Opens on its own") }
        let session = workspace.terminalSession(for: route.tab)
        session.setViewActive(true, view: UUID())
        XCTAssertTrue(session.active)

        let result = await workspace.addAsWorkspace(route)
        XCTAssertEqual(result, .open("p9"))
        XCTAssertEqual(host.bodies("/v1/projects").last?["directory"] as? String, "/Users/me/Notes")
        XCTAssertEqual(workspace.selectedProjectID, "p9")
        let tab = try XCTUnwrap(workspace.currentTab)
        XCTAssertEqual(tab.kind, .terminal)
        XCTAssertEqual(tab.projectID, "p9")
        XCTAssertEqual(tab.resourceID, "t8")
        XCTAssertEqual(tab.sharedFrom, route.tab.sharedFrom)
        XCTAssertFalse(session.active, "The standalone session gave way to the tab's")
        XCTAssertTrue(workspace.terminalSession(for: route.tab) === session, "The screen, on its way out, makes no second session")
        workspace.endStandalone(route.tab.id)
        XCTAssertNil(workspace.sessions.existing(route.tab.id))
        XCTAssertTrue(host.requests("/v1/terminal/close").isEmpty)
    }

    /// A standalone route belongs to the host it was opened on: once the host changed (its screen's session is gone),
    /// Add as Workspace adds its folder to no host.
    func testAStaleStandaloneRouteAddsNothing() async throws {
        let (workspace, host) = try await workspace()
        let added = #"{"id":"p9","name":"Notes","directory":"/Users/me/Notes"}"#
        host.on("/v1/projects") { request in request.httpMethod == "POST" ? (201, added) : (200, Self.projects) }
        let outside = iPadTerminal(id: "t8", projectID: nil, workspace: nil, folder: "/Users/me/Notes", displayFolder: "~/Notes")
        guard case let .standalone(route) = workspace.openShared(outside) else { return XCTFail("Opens on its own") }

        workspace.attach(hostID: "https://other.local:9841|device-a",
                         identity: ConnectionIdentity(host: "https://other.local:9841", deviceID: "device-a"),
                         client: APIClient(address: try ServerAddress(validating: "https://other.local:9841"), token: "token", transport: host))
        await workspace.refreshProjects()
        XCTAssertTrue(workspace.workspaces.canAdd, "The other host adds folders too")

        let result = await workspace.addAsWorkspace(route)
        XCTAssertEqual(result, .dropped)
        XCTAssertTrue(host.requests("/v1/projects").filter { $0.httpMethod == "POST" }.isEmpty, "No folder goes to the other host")
        XCTAssertFalse(workspace.tabs.contains { $0.resourceID == "t8" })
    }

    // MARK: Closing and ending

    func testClosingASharedTabNeverEndsIt() async throws {
        let (workspace, host) = try await workspace()
        guard case let .tab(id) = workspace.openShared(iPadTerminal()) else { return XCTFail("Opens as a tab") }
        // iPhone's End Terminal ends a shared terminal too (owner, 2026-10-22); closing its tab still only stops following it.
        workspace.close(id, source: .header)
        XCTAssertNil(workspace.tab(id))
        XCTAssertTrue(host.requests("/v1/terminal/close").isEmpty)

        // Closing the workspace ends only this device's own terminals there, never one a shared tab follows.
        guard case let .tab(again) = workspace.openShared(iPadTerminal()) else { return XCTFail("Opens as a tab") }
        host.on("/v1/terminals") { _ in
            (200, #"{"terminals":[{"id":"t7","title":"Claude Code","projectId":"p1","status":"running"},"#
                + #"{"id":"t1","title":"Terminal","projectId":"p1","status":"running"}]}"#)
        }
        let alpha = try XCTUnwrap(workspace.projects.first { $0.id == "p1" })
        await workspace.workspaces.requestClose(alpha)
        let request = try XCTUnwrap(workspace.workspaces.pendingClose)
        XCTAssertEqual(request.terminals.map(\.id), ["t1"])
        await workspace.workspaces.close(request)
        XCTAssertNil(workspace.tab(again))
        XCTAssertEqual(host.bodies("/v1/terminal/close").compactMap { $0["terminalId"] as? String }, ["t1"])
    }

    func testEndConfirmationNamesWhereItRuns() {
        XCTAssertEqual(TerminalEndConfirmation.message(SharedOrigin(deviceName: "", onMac: true, routed: true), hostName: "Mac mini"),
                       "It's running in Terminal on Mac mini. Ending it stops the program.")
        XCTAssertEqual(TerminalEndConfirmation.message(SharedOrigin(deviceName: "", onMac: true, routed: false), hostName: "Mac mini"),
                       "It's running in AgentLand on Mac mini. Ending it stops the program.")
        XCTAssertEqual(TerminalEndConfirmation.message(SharedOrigin(deviceName: "Sam's iPad", onMac: false, routed: false), hostName: "Mac mini"),
                       "It's open on Sam's iPad. Ending it stops the program.")
        XCTAssertEqual(TerminalEndConfirmation.message(SharedOrigin(deviceName: "iPhone", onMac: false, routed: false), hostName: "Mac mini"),
                       "It's open on another iPhone. Ending it stops the program.")
        XCTAssertEqual(TerminalEndConfirmation.message(nil, hostName: "Mac mini"),
                       "This stops the terminal session on your Mac. Unsaved work may be lost.")
        var shared = WorkspaceTab.terminal(RemoteTerminal(id: "t7", title: "Claude Code", projectID: "p1", status: .running, exitCode: nil),
                                           projectID: "p1", sharedFrom: SharedOrigin(deviceName: "Sam's iPad", onMac: false, routed: false))
        shared.title = "Fix login"
        XCTAssertEqual(TerminalEndConfirmation.title(shared), "End “Fix login”?")
        shared.sharedFrom = nil
        XCTAssertEqual(TerminalEndConfirmation.title(shared), "End this terminal on the host?")
    }

    // MARK: Sessions

    func testStandaloneSessionReadsWithoutSelection() async throws {
        let (workspace, host) = try await workspace()
        try uncover(workspace)
        let outside = iPadTerminal(id: "t8", projectID: nil, workspace: nil, folder: "/Users/me/Notes", displayFolder: "~/Notes")
        guard case let .standalone(route) = workspace.openShared(outside) else { return XCTFail("Opens on its own") }
        XCTAssertNil(workspace.selectedTabID)
        let session = workspace.terminalSession(for: route.tab)
        let view = UUID()
        session.setViewActive(true, view: view)
        XCTAssertTrue(session.active, "Shown on its own, it is active with no tab selected")
        XCTAssertTrue(session.inputActive)

        session.enqueue(Data("ls\r".utf8))
        await waitUntil("the input") { !host.requests("/v1/terminal/input").isEmpty }
        let typed = try XCTUnwrap(host.bodies("/v1/terminal/input").first)
        XCTAssertEqual(typed["terminalId"] as? String, "t8")
        XCTAssertNil(typed["projectId"], "A terminal outside any workspace is typed into without one")

        await session.poll(view: view, viewActive: true)
        let read = try XCTUnwrap(host.requests("/v1/terminal/output").first)
        XCTAssertEqual(ScriptedHost.query(read)["terminalId"], "t8")
        XCTAssertNil(ScriptedHost.query(read)["projectId"], "A terminal outside any workspace is read without one")

        // Leaving the screen ends the session; the terminal keeps running on the host.
        workspace.endStandalone(route.tab.id)
        XCTAssertFalse(session.active)
        XCTAssertTrue(host.requests("/v1/terminal/close").isEmpty)
    }

    /// Resume opens a new Claude Code terminal in the ended one's workspace; a standalone terminal has none, so its
    /// ended state offers no Resume and asks nothing of the host. The same terminal as a workspace's tab still does.
    func testAnEndedStandaloneTerminalOffersNoResume() async throws {
        let (workspace, host) = try await workspace()
        host.on("/v1/terminal/output") { _ in
            (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","exitCode":0,"ended":{"reason":"programExited","#
                + #""at":"2026-10-14T11:41:03.000Z","exitCode":0,"program":"claude","conversationId":"0f8fad5b-d9cb-469f-a165-70867728950e"}}"#)
        }
        try uncover(workspace)
        let outside = iPadTerminal(id: "t8", projectID: nil, workspace: nil, folder: "/Users/me/Notes", displayFolder: "~/Notes")
        guard case let .standalone(route) = workspace.openShared(outside) else { return XCTFail("Opens on its own") }
        let standalone = workspace.terminalSession(for: route.tab)
        await standalone.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(standalone.terminalGone)
        XCTAssertNil(standalone.resumeTarget, "No workspace to resume it in: no Resume")
        await standalone.resume()
        XCTAssertTrue(host.requests("/v1/terminal/close").isEmpty, "Resume asks nothing of the host")
        XCTAssertTrue(host.requests("/v1/terminals").filter { $0.httpMethod == "POST" }.isEmpty)

        guard case let .tab(id) = workspace.openShared(iPadTerminal()) else { return XCTFail("Opens as a tab") }
        let tabbed = workspace.terminalSession(for: try XCTUnwrap(workspace.tab(id)))
        await tabbed.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(tabbed.terminalGone)
        XCTAssertEqual(tabbed.resumeTarget, .conversation("0f8fad5b-d9cb-469f-a165-70867728950e"), "A tab of its workspace resumes")
    }

    /// A routed agent released to its Terminal window still runs there: Resume would start a second Claude Code on
    /// its conversation, so neither a shared tab nor a standalone terminal offers it.
    func testAnAgentKeptInTerminalOffersNoResume() async throws {
        let (workspace, host) = try await workspace()
        host.on("/v1/terminal/output") { _ in
            (200, #"{"data":"","cursor":0,"reset":false,"status":"exited","ended":{"reason":"keptInTerminal","#
                + #""at":"2026-10-14T11:41:03.000Z","program":"claude","conversationId":"0f8fad5b-d9cb-469f-a165-70867728950e"}}"#)
        }
        try uncover(workspace)
        guard case let .tab(id) = workspace.openShared(iPadTerminal()) else { return XCTFail("Opens as a tab") }
        let tabbed = workspace.terminalSession(for: try XCTUnwrap(workspace.tab(id)))
        await tabbed.poll(view: UUID(), viewActive: true)
        XCTAssertTrue(tabbed.terminalGone)
        XCTAssertEqual(tabbed.howEnded?.reason, .keptInTerminal)
        XCTAssertNil(tabbed.resumeTarget, "It keeps running in Terminal: no second Claude Code on its conversation")
    }

    func testTheSizeGoesBeforeTheFirstKeystroke() async throws {
        let (workspace, host) = try await workspace()
        guard case let .tab(id) = workspace.openShared(iPadTerminal()) else { return XCTFail("Opens as a tab") }
        try uncover(workspace)
        let session = workspace.terminalSession(for: try XCTUnwrap(workspace.tab(id)))
        // The renderer laid out before the terminal was on screen: its size waits.
        session.resize(rows: 30, cols: 100)
        session.setViewActive(true, view: UUID())
        XCTAssertTrue(session.inputActive)
        XCTAssertTrue(host.requests("/v1/terminal/resize").isEmpty)

        session.enqueue(Data("a".utf8))
        session.enqueue(Data("b".utf8))
        await waitUntil("the first input") { !host.requests("/v1/terminal/input").isEmpty }
        func operations() -> [String] {
            host.paths().filter { $0 == "/v1/terminal/resize" || $0 == "/v1/terminal/input" }
                .map { $0 == "/v1/terminal/resize" ? "resize" : "input" }
        }
        XCTAssertEqual(operations(), ["resize", "input"], "The size goes first, once, before typing in a row")
        let size = try XCTUnwrap(host.bodies("/v1/terminal/resize").first)
        XCTAssertEqual(size["rows"] as? Int, 30)
        XCTAssertEqual(size["cols"] as? Int, 100)

        // After a second without typing here, another viewer may have sized it: this device's size goes again first.
        try await Task.sleep(for: .milliseconds(1_100))
        session.enqueue(Data("c".utf8))
        await waitUntil("the second input") { host.requests("/v1/terminal/input").count == 2 }
        XCTAssertEqual(operations(), ["resize", "input", "resize", "input"])
    }
}
