import AppKit
import Combine
import Foundation
import XCTest
import AgentLandCore
import AgentLandDesign
import AgentLandWorkspace
@testable import AgentLandDesktop

/// A local host: its projects, capabilities, a file, and a health check that can stop answering.
private final class LocalHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var healthy = true
    private var healthChecks = 0

    var answersHealth: Bool {
        get { lock.withLock { healthy } }
        set { lock.withLock { healthy = newValue } }
    }
    var healthCheckCount: Int { lock.withLock { healthChecks } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        if path == "/v1/health" {
            let answering = lock.withLock { () -> Bool in healthChecks += 1; return healthy }
            guard answering else { throw URLError(.cannotConnectToHost) }
        }
        let body: String
        switch path {
        case "/v1/projects": body = #"{"projects":[{"id":"fixture","name":"Fixture"}]}"#
        case "/v1/capabilities": body = #"{"interactions":false,"terminal":true}"#
        case "/v1/file": body = #"{"path":"hello.txt","content":"hello\n","revision":"r1"}"#
        case "/v1/health": body = #"{"status":"ok","protocolVersion":1}"#
        default: body = #"{"accepted":true}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A local host with a pulse the test drives, whose capabilities list plain chats when it says so.
private final class PulsingHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listsPlainChats = false
    private var reads = 0
    private var opened = 0
    private var current: AsyncThrowingStream<String, Error>.Continuation?

    var plainChats: Bool {
        get { lock.withLock { listsPlainChats } }
        set { lock.withLock { listsPlainChats = newValue } }
    }
    var capabilityReads: Int { lock.withLock { reads } }
    var pulses: Int { lock.withLock { opened } }

    func push(_ line: String) { _ = lock.withLock { current }?.yield(line) }
    func endPulse() { lock.withLock { current }?.finish() }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url?.path ?? "" {
        case "/v1/projects": body = #"{"projects":[{"id":"fixture","name":"Fixture"}]}"#
        case "/v1/capabilities":
            body = lock.withLock { () -> String in
                reads += 1
                // Chat (Claude Code and Codex in the workspaces, `workspaceChats`) comes and goes with the Chats space here.
                return listsPlainChats ? #"{"interactions":false,"terminal":true,"plainChats":{"projectId":"chats","tools":["memory"]},"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[]}]}}"#
                    : #"{"interactions":false,"terminal":true}"#
            }
        case "/v1/health": body = #"{"status":"ok","protocolVersion":1}"#
        default: body = #"{"accepted":true}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        guard request.url?.path == "/v1/pulse" else { throw URLError(.unsupportedURL) }
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        lock.withLock {
            opened += 1
            current = continuation
        }
        continuation.yield(#"{"type":"ready","intervalMs":1500}"#)
        return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private func eventually(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return XCTFail("Timed out waiting for \(message)", file: file, line: line) }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The Mac's workspace follows the host's local session, not a window: starting the host attaches it,
/// stopping pauses it with everything kept, and starting again attaches it afresh.
@MainActor final class DesktopWorkspaceTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "session-test.local", deviceID: "local-mac")
    private var suite = ""
    private var defaults: UserDefaults!
    private var clients: CurrentValueSubject<APIClient?, Never>!

    override func setUp() async throws {
        suite = "dev.agentland.desktop-workspace-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        clients = CurrentValueSubject(nil)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeWorkspace() -> DesktopWorkspace {
        DesktopWorkspace(model: WorkspaceModel(defaults: defaults, keys: .desktop), clients: clients.eraseToAnyPublisher(),
                         hostName: { "session-test.local" }, archiveOpener: { _, _ in nil })
    }

    private func client(_ host: any APITransport) throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://127.0.0.1:9841"), token: "session", transport: host)
    }

    func testLaunchWithTheHostStoppedShowsTheSavedTabsPausedAndOpen() async throws {
        let files = WorkspaceTab(kind: .files, projectID: "fixture", title: "Files")
        WorkspacePersistence(defaults: defaults).save([files], selectedTabID: files.id, for: identity)
        defaults.set("fixture", forKey: WorkspaceStorageKeys.desktop.currentWorkspace + identity.storageKey)

        let workspace = makeWorkspace()
        let model = workspace.model

        XCTAssertEqual(model.hostID, identity.storageKey, "saved under the Mac's own identity")
        XCTAssertEqual(model.tabs.map(\.id), [files.id])
        XCTAssertEqual(model.selectedTabID, files.id)
        XCTAssertEqual(model.selectedProjectID, "fixture", "the workspace the Mac opened before")
        XCTAssertNil(model.client)
        XCTAssertFalse(model.reachable)
        // No cover on the Mac: the window takes input at once.
        await eventually("the opening to complete") { !model.presentationPending }
    }

    func testStartingStoppingAndStartingAgainFollowTheHostsSession() async throws {
        let workspace = makeWorkspace()
        let model = workspace.model
        let first = try client(LocalHost())

        clients.send(first)
        XCTAssertTrue(model.client === first)
        XCTAssertTrue(model.reachable)
        await eventually("the host's projects") { model.projects.map(\.id) == ["fixture"] }
        await eventually("the opening to complete") { !model.presentationPending }
        XCTAssertEqual(model.capabilities?.terminal, true)

        model.selectProject("fixture")
        model.open(WorkspaceTab(kind: .terminal, projectID: "fixture", resourceID: "t1", title: "Terminal"))
        let terminalTab = try XCTUnwrap(model.currentTab)
        let terminal = model.terminalSession(for: terminalTab)
        XCTAssertEqual(model.sessions.count, 1)

        // Disconnect: the workspace pauses; nothing it shows is dropped.
        clients.send(nil)
        XCTAssertNil(model.client)
        XCTAssertFalse(model.reachable)
        XCTAssertEqual(model.tabs.map(\.id), [terminalTab.id])
        XCTAssertEqual(model.projects.map(\.id), ["fixture"])
        XCTAssertTrue(model.sessions.existing(terminalTab.id) === terminal, "a paused tab keeps its session")

        // Connect again: a new host process with a new session; each tab starts afresh.
        let second = try client(LocalHost())
        clients.send(second)
        XCTAssertTrue(model.client === second)
        XCTAssertTrue(model.reachable)
        XCTAssertEqual(model.sessions.count, 0, "the restarted host has none of the old terminals")
        XCTAssertEqual(model.tabs.map(\.id), [terminalTab.id], "the saved tabs come back")
        XCTAssertEqual(model.selectedTabID, terminalTab.id)
        await eventually("the opening to complete") { !model.presentationPending }
        XCTAssertTrue(model.terminalSession(for: terminalTab) !== terminal)
    }

    func testANewHostnameAttachesItsOwnSavedTabs() async throws {
        var hostname = "session-test.local"
        let renamed = ConnectionIdentity(host: "renamed.local", deviceID: "local-mac")
        let saved = WorkspaceTab(kind: .files, projectID: "fixture", title: "Files")
        WorkspacePersistence(defaults: defaults).save([saved], selectedTabID: saved.id, for: renamed)
        let workspace = DesktopWorkspace(model: WorkspaceModel(defaults: defaults, keys: .desktop), clients: clients.eraseToAnyPublisher(),
                                         hostName: { hostname }, archiveOpener: { _, _ in nil })
        let model = workspace.model
        clients.send(try client(LocalHost()))
        XCTAssertEqual(model.hostID, identity.storageKey)
        XCTAssertTrue(model.tabs.isEmpty)

        // Advanced ▸ Hostname changed and saved: the host restarts under the other name.
        hostname = "renamed.local"
        clients.send(nil)
        clients.send(try client(LocalHost()))
        XCTAssertEqual(model.hostID, renamed.storageKey)
        XCTAssertEqual(model.tabs.map(\.id), [saved.id])
    }

    func testAnEditorsDraftSurvivesTheHostRestarting() async throws {
        let workspace = makeWorkspace()
        let model = workspace.model
        clients.send(try client(LocalHost()))
        await eventually("the host's projects") { !model.projects.isEmpty }
        model.selectProject("fixture")
        model.openFile(projectID: "fixture", path: "hello.txt")
        let tab = try XCTUnwrap(model.currentTab)
        let editor = model.editorSession(for: tab)
        await editor.load()
        // Typed, and saved only in the editor's debounce so far.
        editor.content = "hello, edited\n"
        editor.scheduleDraftSave(editor.content)

        clients.send(nil)
        clients.send(try client(LocalHost()))

        let restored = try XCTUnwrap(model.tab(tab.id))
        XCTAssertEqual(restored.draft, "hello, edited\n")
        XCTAssertTrue(restored.editorDirty)
        XCTAssertEqual(restored.editorBaseRevision, "r1", "the draft keeps the revision it was based on")
    }

    func testAFailedReadChecksTheHostAndResumesWithANewEpoch() async throws {
        let workspace = makeWorkspace()
        let model = workspace.model
        let host = LocalHost()
        clients.send(try client(host))
        await eventually("the host's projects") { !model.projects.isEmpty }
        let epoch = model.connectionEpoch

        host.answersHealth = false
        model.noteConnectionFailure()
        await eventually("the workspace to go offline") { !model.reachable }

        host.answersHealth = true
        await eventually("the workspace to come back", timeout: 8) { model.reachable }
        XCTAssertEqual(model.connectionEpoch, epoch + 1, "surfaces resume from their cursors")
        XCTAssertTrue(model.client != nil)
    }

    func testAStoppedHostIsNotCheckedForAnswers() async throws {
        let workspace = makeWorkspace()
        let model = workspace.model
        let host = LocalHost()
        clients.send(try client(host))
        await eventually("the host's projects") { !model.projects.isEmpty }
        clients.send(nil)
        let checks = host.healthCheckCount

        model.noteConnectionFailure()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.healthCheckCount, checks)
        XCTAssertFalse(model.reachable)
    }

    func testTheHostsListReachesTheSavedDefaultWorkspaceOnlyWhileItsSessionRuns() async throws {
        var followed: [[String]] = []
        let workspace = DesktopWorkspace(model: WorkspaceModel(defaults: defaults, keys: .desktop), clients: clients.eraseToAnyPublisher(),
                                         hostName: { "session-test.local" }, archiveOpener: { _, _ in nil },
                                         followProjects: { projects, _ in followed.append(projects.map(\.id)) })
        let model = workspace.model
        clients.send(try client(LocalHost()))
        await eventually("the host's list to be followed") { followed.last == ["fixture"] }
        let count = followed.count
        // A stopped host keeps its list on screen; that is not an answer to follow.
        clients.send(nil)
        model.projects = [Project(id: "stale", name: "Stale")]
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(followed.count, count)
    }

    func testTheBannerSaysWhatTheHostIsDoing() {
        XCTAssertEqual(DesktopWorkspace.connectionStatus(host: .running, reachable: true), .online)
        XCTAssertTrue(DesktopWorkspace.connectionStatus(host: .running, reachable: false).isOffline)
        XCTAssertTrue(DesktopWorkspace.connectionStatus(host: .starting, reachable: true).isOffline)
        guard case let .offline(title, _, _) = DesktopWorkspace.connectionStatus(host: .stopped, reachable: false) else {
            return XCTFail("A stopped host is offline")
        }
        XCTAssertEqual(title, "Disconnected")
    }

    /// The host lists plain chats once OpenCode's `chat` agent answers, which can be after the Mac's session
    /// read its capabilities: the pulse names the plain chats revision after `ready` and on every change, and
    /// the workspace reads the capabilities again for another revision (docs/HOST-API.md "Plain chats").
    func testThePulsesPlainChatsRevisionReadsTheCapabilitiesAgain() async throws {
        let host = PulsingHost()
        let workspace = makeWorkspace()
        workspace.pulseRetryDelays = [.milliseconds(20)]
        let model = workspace.model
        clients.send(try client(host))
        await eventually("the first capabilities") { model.capabilities != nil }
        XCTAssertFalse(model.offersPlainChats)

        // OpenCode's `chat` agent answers: the host lists plain chats and names a revision.
        host.plainChats = true
        host.push(#"{"type":"plainChats","revision":"pc-1"}"#)
        await eventually("plain chats offered") { model.offersPlainChats }
        let reads = host.capabilityReads
        host.push(#"{"type":"beat"}"#)
        host.push(#"{"type":"plainChats","revision":"pc-1"}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.capabilityReads, reads, "The same revision is not read again")

        // A pulse the host ended opens again; its first line names the revision as it is.
        host.plainChats = false
        host.endPulse()
        await eventually("the pulse opened again") { host.pulses >= 2 }
        host.push(#"{"type":"plainChats","revision":"pc-2"}"#)
        await eventually("plain chats gone") { !model.offersPlainChats }

        // A stopped host is not followed.
        clients.send(nil)
        let pulses = host.pulses
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.pulses, pulses)
    }

    /// Chat naming's foreground on the Mac is the app being active: it begins when the app becomes active
    /// and ends when it resigns.
    func testChatNamingFollowsTheAppsActivation() async throws {
        let workspace = makeWorkspace()
        let naming = workspace.model.naming
        XCTAssertFalse(naming.inForeground)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await eventually("the foreground") { naming.inForeground }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        await eventually("the background") { !naming.inForeground }
    }
}
