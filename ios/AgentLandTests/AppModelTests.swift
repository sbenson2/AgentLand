import XCTest
import LocalAuthentication
import AgentLandArchive
import AgentLandCore
@testable import AgentLand
import AgentLandWorkspace

private final class PresenceTransport: APITransport, @unchecked Sendable {
    /// One heartbeat as the host got it.
    struct Beat: Equatable {
        let active: Bool
        let view: [String: String]?
    }
    private let lock = NSLock()
    private var beats: [Beat] = []
    var recordedBeats: [Beat] { lock.withLock { beats } }
    var recordedStates: [Bool] { recordedBeats.map(\.active) }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/v1/device/presence",
           let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any],
           let active = body["active"] as? Bool {
            lock.withLock { beats.append(Beat(active: active, view: body["view"] as? [String: String])) }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"accepted\":true}".utf8), response)
    }
}

/// The hosts whose device copy a forget deleted.
private actor RemovedCopies {
    private(set) var identities: [ConnectionIdentity] = []
    func add(_ identity: ConnectionIdentity) { identities.append(identity) }
}

@MainActor private final class ControlledAuthenticator: AppAuthenticating {
    private var continuation: CheckedContinuation<Bool, Error>?
    private(set) var invalidated = false
    var isWaiting: Bool { continuation != nil }

    func authenticate(reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func invalidate() { invalidated = true }

    func finish(with result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func fail(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<100 where !condition() {
        await Task.yield()
    }
    XCTAssertTrue(condition(), "Timed out waiting for asynchronous model state", file: file, line: line)
}

/// Scripted pulse streams for the connection monitor; other requests succeed.
private final class PulseTransport: APITransport, @unchecked Sendable {
    enum Step { case stream([String], hold: Bool), fail(URLError) }
    private let lock = NSLock()
    private var steps: [Step]
    private var opened = 0
    var pulses: Int { lock.withLock { opened } }
    init(_ steps: [Step]) { self.steps = steps }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.url?.path == "/v1/projects" ? "{\"projects\":[{\"id\":\"p\",\"name\":\"Project\"}]}" : "{\"accepted\":true}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let step: Step = lock.withLock {
            opened += 1
            return steps.isEmpty ? .stream([], hold: true) : steps.removeFirst()
        }
        switch step {
        case let .fail(error):
            throw error
        case let .stream(values, hold):
            let stream = AsyncThrowingStream<String, Error> { continuation in
                for value in values { continuation.yield(value) }
                if !hold { continuation.finish() }
            }
            return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Waits in real time for monitor loops that sleep between attempts.
@MainActor private func eventually(
    within seconds: Double = 6,
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "Timed out waiting for connection state", file: file, line: line)
}

@MainActor final class AppModelTests: XCTestCase {

    func testForegroundPresenceStopsOnBackground() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "presence-\(UUID())"))
        let model = AppModel(defaults: defaults)
        let transport = PresenceTransport()
        model.selectedHost = SavedHost(address: "https://test.example", deviceID: "device", name: "Test", mode: .direct, certificateSHA256: nil)
        model.client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: transport)

        model.handleScenePhase(.active)
        await waitUntil { transport.recordedStates.contains(true) }
        model.handleScenePhase(.background)
        await waitUntil { transport.recordedStates.contains(false) }
        XCTAssertEqual(transport.recordedStates.prefix(2), [true, false])
    }

    /// A model whose presence heartbeats go to `transport`, with the selected tab `tab` on a host whose
    /// capabilities are `capabilities`.
    private func presenceModel(_ transport: PresenceTransport, tab: WorkspaceTab, capabilities: CapabilitiesResponse,
                               authenticator: ControlledAuthenticator? = nil) throws -> AppModel {
        let suite = "presence-views-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = authenticator.map { authenticator in AppModel(defaults: defaults, authenticatorFactory: { authenticator }) }
            ?? AppModel(defaults: defaults)
        model.presenceCoalescing = .milliseconds(500)
        model.selectedHost = SavedHost(address: "https://test.example", deviceID: "device", name: "Test", mode: .direct, certificateSHA256: nil)
        model.client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: transport)
        model.workspace.capabilities = capabilities
        model.workspace.open(tab)
        return model
    }

    private static let views = CapabilitiesResponse(interactions: true, terminal: true, presence: ["views"])

    /// docs/HOST-API.md "Presence and notices": the heartbeat carries the chat on screen as `view`; a change
    /// of the chat, or leaving it, is reported at once rather than at the next 15 s beat, and a run of
    /// switches only once, with the chat left on screen.
    func testPresenceReportsTheChatOnScreenAndReportsItsChangesAtOnce() async throws {
        let transport = PresenceTransport()
        let chat = WorkspaceTab(kind: .chat, projectID: "p1", resourceID: "claude:s1", title: "Chat")
        let model = try presenceModel(transport, tab: chat, capabilities: Self.views)

        model.handleScenePhase(.active)
        await eventually { transport.recordedBeats.count == 1 }
        XCTAssertEqual(transport.recordedBeats.first, .init(active: true, view: ["projectId": "p1", "sessionId": "claude:s1"]))

        // Leaving the chat: a heartbeat without a view, long before the next 15 s beat.
        model.workspace.open(WorkspaceTab(kind: .files, projectID: "p1", title: "Files"))
        await eventually(within: 3) { transport.recordedBeats.count == 2 }
        XCTAssertEqual(transport.recordedBeats.dropFirst().first, .init(active: true, view: nil))

        // Several chats in a row: one heartbeat, naming the chat left on screen.
        for index in 1...5 {
            model.workspace.open(WorkspaceTab(kind: .chat, projectID: "p1", resourceID: "gemini:s\(index)", title: "Chat \(index)"))
            try await Task.sleep(for: .milliseconds(10))
        }
        await eventually(within: 3) { transport.recordedBeats.count == 3 }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(transport.recordedBeats.count, 3, "Coalesced into one heartbeat")
        XCTAssertEqual(transport.recordedBeats.last, .init(active: true, view: ["projectId": "p1", "sessionId": "gemini:s5"]))

        // The background ends it; nothing after carries a view.
        model.handleScenePhase(.background)
        await eventually { transport.recordedBeats.last == .init(active: false, view: nil) }
    }

    /// Only hosts that list `presence: ["views"]` get a view (the others refuse the member), none while the
    /// app is locked, and none for a chat whose IDs the host would refuse (it would drop the heartbeat).
    func testPresenceSendsAViewOnlyToHostsThatListViewsAndOnlyWhileUnlocked() async throws {
        let transport = PresenceTransport()
        let authenticator = ControlledAuthenticator()
        let chat = WorkspaceTab(kind: .chat, projectID: "p1", resourceID: "claude:s1", title: "Chat")
        let model = try presenceModel(transport, tab: chat, capabilities: CapabilitiesResponse(interactions: true, terminal: true),
                                      authenticator: authenticator)
        model.handleScenePhase(.active)
        await eventually { transport.recordedBeats.count == 1 }
        XCTAssertEqual(transport.recordedBeats.first, .init(active: true, view: nil), "A host without views gets none")

        // The host's capabilities list views: the chat on screen is reported at once.
        model.workspace.capabilities = Self.views
        await eventually(within: 3) { transport.recordedBeats.count == 2 }
        XCTAssertEqual(transport.recordedBeats.dropFirst().first, .init(active: true, view: ["projectId": "p1", "sessionId": "claude:s1"]))

        // Locked: the heartbeat stops with active false, which clears the view; unlocking reports it again. Turning
        // the lock on is confirmed in place; it locks on the next trip to the background.
        model.enableLock(true)
        await waitUntil { authenticator.isWaiting }
        authenticator.finish(with: true)
        await waitUntil { model.lockEnabled }
        XCTAssertFalse(model.locked)
        model.handleScenePhase(.background)
        await eventually { transport.recordedBeats.last == .init(active: false, view: nil) }
        let whileLocked = transport.recordedBeats.count
        model.handleScenePhase(.active)
        await waitUntil { authenticator.isWaiting }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.recordedBeats.count, whileLocked, "Nothing while locked")
        authenticator.finish(with: true)
        await eventually { transport.recordedBeats.count == whileLocked + 1 }
        XCTAssertEqual(transport.recordedBeats.last, .init(active: true, view: ["projectId": "p1", "sessionId": "claude:s1"]))

        // A chat ID longer than the host takes: no view rather than a heartbeat the host refuses.
        model.workspace.open(WorkspaceTab(kind: .chat, projectID: "p1", resourceID: String(repeating: "s", count: 257), title: "Odd"))
        await eventually(within: 3) { transport.recordedBeats.count == whileLocked + 2 }
        XCTAssertEqual(transport.recordedBeats.last, .init(active: true, view: nil))
        model.handleScenePhase(.background)
    }
    func testHostSelectionStartsOpeningBeforeAnyAsynchronousLoad() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let host = SavedHost(address: "https://test.example", deviceID: "opening", name: "Test", mode: .direct, certificateSHA256: nil)

        model.select(host)

        XCTAssertTrue(model.presentationPending, "The first render must already be covered, before a Task can begin loading")
        XCTAssertEqual(model.presentationTicket?.hostID, host.id)
    }

    /// The device archive's sync starts only once the opening cover has cleared, so it never competes with
    /// the selected surface's first read.
    func testArchiveSyncStartsOnlyOnceTheOpeningHasCleared() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let host = SavedHost(address: "https://test.example", deviceID: "sync", name: "Test", mode: .direct, certificateSHA256: nil)
        let client = APIClient(address: try ServerAddress(validating: host.address), token: "token", transport: PulseTransport([]))
        let archive = WorkspaceArchive(store: try ArchiveStore.inMemory(), terminalLogs: nil, attachments: nil, client: client)
        model.selectedHost = host
        model.workspace.attach(hostID: host.id, identity: ConnectionIdentity(host: host.address, deviceID: host.deviceID),
                               client: client, archive: archive)
        model.handleScenePhase(.active)
        await model.refreshProjects()
        XCTAssertTrue(model.presentationPending)
        try await Task.sleep(for: .milliseconds(100))
        let covered = await archive.engine.status.phase
        XCTAssertEqual(covered, .stopped, "No sync while the opening cover shows")

        model.completePresentation(try XCTUnwrap(model.presentationTicket))
        XCTAssertFalse(model.presentationPending)
        // This host lists no archive, so the started engine reports it unavailable.
        var phase = await archive.engine.status.phase
        let deadline = Date().addingTimeInterval(3)
        while phase == .stopped, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            phase = await archive.engine.status.phase
        }
        XCTAssertEqual(phase, .unavailable, "The sync engine starts once the opening has cleared")
        model.handleScenePhase(.background)
    }

    func testSelectedSurfaceWaitsForContentThenMatchingRenderedFrame() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        // Missing credentials resolve metadata to an actionable error. The
        // selected surface must still finish its own error/content layout.
        model.select(SavedHost(address: "https://test.example", deviceID: UUID().uuidString, name: "Test", mode: .direct, certificateSHA256: nil))
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        model.workspace.open(chat)
        model.handleScenePhase(.active)
        let ticket = try XCTUnwrap(model.presentationRequest(for: chat.id))
        XCTAssertFalse(model.loadingProjects)
        XCTAssertFalse(model.presentationReady)
        XCTAssertNil(model.presentationRequest(for: UUID()))

        model.completePresentation(ticket)
        XCTAssertTrue(model.presentationPending)
        model.reportPresentationReady(ticket)
        XCTAssertTrue(model.presentationReady)
        XCTAssertTrue(model.presentationPending, "Content completion alone must not uncover an unrendered surface")

        model.completePresentation(ticket)
        XCTAssertFalse(model.presentationPending)
    }

    func testSelectionAndReloadRejectPreviousSurfaceAcknowledgements() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.select(SavedHost(address: "https://test.example", deviceID: UUID().uuidString, name: "Test", mode: .direct, certificateSHA256: nil))
        model.handleScenePhase(.active)
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        model.workspace.open(chat)
        let chatTicket = try XCTUnwrap(model.presentationTicket)
        model.workspace.open(files)
        let filesTicket = try XCTUnwrap(model.presentationTicket)
        XCTAssertNotEqual(chatTicket, filesTicket)
        model.reportPresentationReady(chatTicket)
        model.completePresentation(chatTicket)
        XCTAssertFalse(model.presentationReady)
        XCTAssertTrue(model.presentationPending)

        model.reportPresentationReady(filesTicket)
        XCTAssertTrue(model.presentationReady)
        model.workspace.reloadTab(files.id)
        let reloadTicket = try XCTUnwrap(model.presentationTicket)
        XCTAssertNotEqual(reloadTicket, filesTicket)
        model.reportPresentationReady(filesTicket)
        model.completePresentation(filesTicket)
        XCTAssertFalse(model.presentationReady)
        model.reportPresentationReady(reloadTicket)
        model.completePresentation(reloadTicket)
        XCTAssertFalse(model.presentationPending)
    }

    func testRenderCompletionCannotBypassLockBackgroundOrConnectionWork() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Device unlock on from an earlier run: the app starts locked.
        defaults.set(true, forKey: "agentland.lock.enabled")
        let model = AppModel(defaults: defaults)
        model.select(SavedHost(address: "https://test.example", deviceID: UUID().uuidString, name: "Test", mode: .direct, certificateSHA256: nil))
        let ticket = try XCTUnwrap(model.presentationTicket)
        XCTAssertTrue(model.presentationReady, "Home needs only resolved metadata")
        XCTAssertTrue(model.locked)
        model.completePresentation(ticket)
        XCTAssertTrue(model.presentationPending)
        model.enableLock(false)
        model.completePresentation(ticket)
        XCTAssertTrue(model.presentationPending, "The scene is still inactive")
        model.handleScenePhase(.active)
        model.busy = true
        model.completePresentation(ticket)
        XCTAssertTrue(model.presentationPending)
        model.busy = false
        model.completePresentation(ticket)
        XCTAssertFalse(model.presentationPending)

        model.handleScenePhase(.background)
        let returnTicket = try XCTUnwrap(model.presentationTicket)
        XCTAssertNotEqual(returnTicket, ticket)
        model.completePresentation(returnTicket)
        XCTAssertTrue(model.presentationPending)
        model.handleScenePhase(.active)
        model.completePresentation(ticket)
        XCTAssertTrue(model.presentationPending, "An old frame cannot complete a new opening")
        model.completePresentation(returnTicket)
        XCTAssertFalse(model.presentationPending)
    }

    func testChangingHostOrDisconnectingRejectsOldOpeningCallbacks() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.handleScenePhase(.active)
        model.select(SavedHost(address: "https://test.example", deviceID: UUID().uuidString, name: "First", mode: .direct, certificateSHA256: nil))
        let oldTicket = try XCTUnwrap(model.presentationTicket)
        model.select(SavedHost(address: "https://test.example", deviceID: UUID().uuidString, name: "Second", mode: .direct, certificateSHA256: nil))
        let newTicket = try XCTUnwrap(model.presentationTicket)
        XCTAssertNotEqual(oldTicket.hostID, newTicket.hostID)
        model.reportPresentationReady(oldTicket)
        model.completePresentation(oldTicket)
        XCTAssertEqual(model.presentationTicket, newTicket)
        model.disconnect()
        model.reportPresentationReady(newTicket)
        model.completePresentation(newTicket)
        XCTAssertFalse(model.presentationPending)
        XCTAssertFalse(model.presentationReady)
    }

    func testOrdinaryTabChangesDoNotRestartCompletedOpening() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.select(SavedHost(address: "https://test.example", deviceID: UUID().uuidString, name: "Test", mode: .direct, certificateSHA256: nil))
        model.handleScenePhase(.active)
        model.completePresentation(try XCTUnwrap(model.presentationTicket))
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        model.workspace.open(chat)
        model.workspace.reloadTab(chat.id)
        model.workspace.close(chat.id)
        XCTAssertFalse(model.presentationPending)
    }

    func testActiveColdOpeningAuthenticatesAndUnlocks() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let authenticator = ControlledAuthenticator()
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticator })

        model.handleScenePhase(.active)
        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.isAuthenticating)

        await waitUntil { authenticator.isWaiting }
        authenticator.finish(with: true)
        await waitUntil { !model.isAuthenticating }

        XCTAssertFalse(model.locked)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertNil(model.authenticationMessage)
    }

    /// B-17: turning device unlock on is confirmed in place. The app is not locked meanwhile (Settings stays open),
    /// the prompt's inactive/active round trip starts no second prompt, and only a success turns it on.
    func testEnablingLockConfirmsInPlaceWithoutLocking() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authenticator = ControlledAuthenticator()
        var prompts = 0
        let model = AppModel(defaults: defaults, authenticatorFactory: { prompts += 1; return authenticator })
        model.handleScenePhase(.active)

        model.enableLock(true)
        XCTAssertFalse(model.locked, "the lock does not cover Settings")
        XCTAssertFalse(model.isAuthenticating, "no unlock prompt: a confirmation")
        XCTAssertTrue(model.confirmingLock)
        XCTAssertFalse(model.lockEnabled, "not on until confirmed")
        await waitUntil { authenticator.isWaiting }
        model.enableLock(true)
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)
        XCTAssertEqual(prompts, 1, "the prompt's inactive transition and a second tap start no second prompt")

        authenticator.finish(with: true)
        await waitUntil { !model.confirmingLock }
        XCTAssertTrue(model.lockEnabled)
        XCTAssertFalse(model.locked, "the person just confirmed: still unlocked")
        XCTAssertTrue(defaults.bool(forKey: "agentland.lock.enabled"))
        XCTAssertNil(model.lockSettingMessage)
        XCTAssertEqual(prompts, 1)

        // The next return from the background locks and asks.
        model.handleScenePhase(.background)
        XCTAssertTrue(model.locked)
    }

    func testACancelledOrFailedConfirmationLeavesDeviceUnlockOff() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authenticator = ControlledAuthenticator()
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticator })
        model.handleScenePhase(.active)

        model.enableLock(true)
        await waitUntil { authenticator.isWaiting }
        authenticator.fail(with: NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue))
        await waitUntil { !model.confirmingLock }
        XCTAssertFalse(model.lockEnabled)
        XCTAssertFalse(model.locked)
        XCTAssertNil(model.lockSettingMessage, "a cancel needs no explanation")

        model.enableLock(true)
        await waitUntil { authenticator.isWaiting }
        authenticator.finish(with: false)
        await waitUntil { !model.confirmingLock }
        XCTAssertFalse(model.lockEnabled)
        XCTAssertNotNil(model.lockSettingMessage, "a failure says it stays off")
        XCTAssertFalse(defaults.bool(forKey: "agentland.lock.enabled"))
    }

    func testTheBackgroundCancelsTheConfirmationAndItsLateResultIsDropped() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authenticator = ControlledAuthenticator()
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticator })
        model.handleScenePhase(.active)

        model.enableLock(true)
        await waitUntil { authenticator.isWaiting }
        model.handleScenePhase(.background)
        XCTAssertTrue(authenticator.invalidated)
        XCTAssertFalse(model.confirmingLock)
        authenticator.finish(with: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.lockEnabled, "a stale success never turns it on")
        XCTAssertFalse(model.locked)
    }

    func testAuthenticationPromptInactiveAndActiveTransitionsDoNotLaunchTwice() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let authenticator = ControlledAuthenticator()
        var factoryCalls = 0
        let model = AppModel(defaults: defaults, authenticatorFactory: {
            factoryCalls += 1
            return authenticator
        })

        model.handleScenePhase(.active)
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)

        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.isAuthenticating)
        XCTAssertEqual(factoryCalls, 1)
        await waitUntil { authenticator.isWaiting }
        authenticator.finish(with: true)
        await waitUntil { !model.isAuthenticating }
        XCTAssertFalse(model.locked)
    }

    func testCanceledAuthenticationRetriesOnlyAfterBackgroundAndForeground() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let first = ControlledAuthenticator()
        let second = ControlledAuthenticator()
        var authenticators = [first, second]
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticators.removeFirst() })

        model.handleScenePhase(.active)
        await waitUntil { first.isWaiting }
        first.fail(with: NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue))
        await waitUntil { !model.isAuthenticating }

        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertTrue(model.authenticationMessage?.contains("return to AgentLand") == true)
        model.handleScenePhase(.active)
        XCTAssertFalse(model.isAuthenticating)

        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        XCTAssertTrue(model.isAuthenticating)
        await waitUntil { second.isWaiting }
        second.finish(with: true)
        await waitUntil { !model.isAuthenticating }
        XCTAssertFalse(model.locked)
    }

    func testBackgroundIgnoresStaleSuccessWhileNewAuthenticationIsRunning() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let first = ControlledAuthenticator()
        let second = ControlledAuthenticator()
        var authenticators = [first, second]
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticators.removeFirst() })

        model.handleScenePhase(.active)
        await waitUntil { first.isWaiting }
        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        await waitUntil { second.isWaiting }
        first.finish(with: true)
        await Task.yield()

        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.isAuthenticating)
        second.finish(with: true)
        await waitUntil { !model.isAuthenticating }
        XCTAssertFalse(model.locked)
    }

    func testBackgroundIgnoresStaleErrorFromPreviousAuthentication() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let first = ControlledAuthenticator()
        let second = ControlledAuthenticator()
        var authenticators = [first, second]
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticators.removeFirst() })

        model.handleScenePhase(.active)
        await waitUntil { first.isWaiting }
        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        await waitUntil { second.isWaiting }
        first.fail(with: NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue))
        await Task.yield()

        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.isAuthenticating)
        XCTAssertNil(model.authenticationMessage)
        second.finish(with: true)
        await waitUntil { !model.isAuthenticating }
        XCTAssertFalse(model.locked)
    }

    func testDisablingLockCancelsAuthenticationAndIgnoresItsResult() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let authenticator = ControlledAuthenticator()
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticator })
        model.handleScenePhase(.active)
        await waitUntil { authenticator.isWaiting }

        model.enableLock(false)
        XCTAssertFalse(model.locked)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertTrue(authenticator.invalidated)

        authenticator.fail(with: NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue))
        await Task.yield()
        XCTAssertFalse(model.locked)
        XCTAssertNil(model.authenticationMessage)
    }

    func testFalseAuthenticationResultRemainsLockedWithoutPromptLoop() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let authenticator = ControlledAuthenticator()
        var factoryCalls = 0
        let model = AppModel(defaults: defaults, authenticatorFactory: {
            factoryCalls += 1
            return authenticator
        })

        model.handleScenePhase(.active)
        await waitUntil { authenticator.isWaiting }
        authenticator.finish(with: false)
        await waitUntil { !model.isAuthenticating }

        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertNotNil(model.authenticationMessage)
        model.handleScenePhase(.active)
        XCTAssertEqual(factoryCalls, 1)
    }

    func testDeniedAuthenticationRemainsLockedWithoutPromptLoop() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agentland.lock.enabled")
        let authenticator = ControlledAuthenticator()
        var factoryCalls = 0
        let model = AppModel(defaults: defaults, authenticatorFactory: {
            factoryCalls += 1
            return authenticator
        })

        model.handleScenePhase(.active)
        await waitUntil { authenticator.isWaiting }
        authenticator.fail(with: NSError(domain: LAError.errorDomain, code: LAError.Code.authenticationFailed.rawValue))
        await waitUntil { !model.isAuthenticating }

        XCTAssertTrue(model.locked)
        XCTAssertNotNil(model.authenticationMessage)
        model.handleScenePhase(.active)
        XCTAssertEqual(factoryCalls, 1)
    }

    func testExplicitCloseDraftAndLockRetainWorkspaceState() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = SavedHost(address: "https://test.example", deviceID: "device-a", name: "Test", mode: .direct, certificateSHA256: nil)
        defaults.set(try JSONEncoder().encode([host]), forKey: ProductIdentity.connectionsDefaultsKey)
        // Device unlock is on: the trip to the background below locks the app.
        defaults.set(true, forKey: "agentland.lock.enabled")
        let model = AppModel(defaults: defaults)
        model.select(host)
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Session")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "p", resourceID: "t", title: "Terminal")
        model.workspace.open(chat); model.workspace.open(terminal)
        model.workspace.updateDraft(chat.id, "Unsent text")
        model.handleScenePhase(.background)
        XCTAssertTrue(model.locked)
        XCTAssertEqual(model.workspace.tabs.count, 2)
        model.workspace.close(terminal.id)
        XCTAssertEqual(model.workspace.tabs.map(\.id), [chat.id])
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.workspace.tabs.first?.draft, "Unsent text")
        XCTAssertEqual(restored.workspace.tabs.map(\.id), [chat.id])
    }

    func testMalformedCertificateFingerprintNeverStartsPairing() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        await model.pair(address: "https://test.example", code: "code", name: "Test", mode: .direct, certificateSHA256: "not-a-fingerprint")
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(model.error?.contains("64-digit") == true)
    }

    func testNoWorkspaceIsAssumedAndAChoiceIsRememberedPerHost() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = SavedHost(address: "https://test.example", deviceID: "device-a", name: "Test", mode: .direct, certificateSHA256: nil)
        defaults.set(try JSONEncoder().encode([host]), forKey: ProductIdentity.connectionsDefaultsKey)
        let model = AppModel(defaults: defaults)
        model.select(host)
        model.client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: PulseTransport([]))
        await model.refreshProjects()
        XCTAssertEqual(model.workspace.projects.map(\.id), ["p"])
        XCTAssertNil(model.workspace.selectedProjectID, "The host's first project must not become the workspace by itself")
        XCTAssertNil(model.workspace.currentProject)

        model.workspace.selectProject("p")
        model.workspace.selectedTabID = nil
        XCTAssertEqual(model.workspace.selectedProjectID, "p")
        let restored = AppModel(defaults: defaults)
        XCTAssertNil(restored.workspace.selectedTabID)
        XCTAssertEqual(restored.workspace.selectedProjectID, "p", "An explicit choice survives relaunch for this host")

        restored.client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: PulseTransport([]))
        restored.workspace.selectProject("missing")
        XCTAssertEqual(restored.workspace.selectedProjectID, "p", "Only a workspace the host offers can be chosen")
        restored.forget(host)
        let other = SavedHost(address: "https://other.example", deviceID: "device-b", name: "Other", mode: .direct, certificateSHA256: nil)
        restored.select(other)
        XCTAssertNil(restored.workspace.selectedProjectID, "Another host starts with no workspace")
    }

    // MARK: Pairing again (docs/HOST-API.md, "Pairing again"; owner, 2026-10-17)

    /// The saved host a pairing pairs again: the same certificate fingerprint at the same address in any form, with
    /// a token on this device; the selected one among duplicates, else the one paired last.
    func testPairingAgainFindsTheSavedHostWithTheSameCertificateAndAddress() {
        let pin = String(repeating: "ab", count: 32)
        let saved = SavedHost(address: "https://Studio.local:9841", deviceID: "device-a", name: "Studio", mode: .direct, certificateSHA256: pin)
        let otherPort = SavedHost(address: "https://studio.local:9842", deviceID: "device-b", name: "Studio", mode: .direct, certificateSHA256: pin)
        let otherMac = SavedHost(address: "https://studio.local:9841", deviceID: "device-c", name: "Other", mode: .direct,
                                 certificateSHA256: String(repeating: "cd", count: 32))
        let unpinned = SavedHost(address: "https://studio.local:9841", deviceID: "device-d", name: "Studio", mode: .direct, certificateSHA256: nil)
        let hosts = [saved, otherPort, otherMac, unpinned]
        func previous(_ address: String, _ certificate: String? = pin, selected: String? = nil, in list: [SavedHost] = hosts,
                      hasToken: (SavedHost) -> Bool = { _ in true }) -> String? {
            AppModel.previousPairing(in: list, address: address, certificateSHA256: certificate, selectedID: selected, hasToken: hasToken)?.id
        }
        XCTAssertEqual(previous("https://studio.local.:9841/"), saved.id, "the same address in another form")
        XCTAssertEqual(previous("https://studio.local:9842"), otherPort.id)
        XCTAssertNil(previous("https://studio.local"), "another port is another address")
        XCTAssertNil(previous("https://studio.local:9841", String(repeating: "ef", count: 32)), "another certificate")
        XCTAssertNil(previous("https://studio.local:9841", nil), "a host paired without a fingerprint gets no token")
        XCTAssertNil(previous("https://studio.local:9841", hasToken: { _ in false }), "no token on this device")
        let duplicate = SavedHost(address: "https://studio.local:9841", deviceID: "device-e", name: "Studio", mode: .direct, certificateSHA256: pin)
        XCTAssertEqual(previous("https://studio.local:9841", in: [saved, duplicate]), duplicate.id, "the one paired last")
        XCTAssertEqual(previous("https://studio.local:9841", selected: saved.id, in: [saved, duplicate]), saved.id, "the selected one")
        XCTAssertEqual(previous("https://studio.local:9841", in: [saved, duplicate], hasToken: { $0.id == saved.id }), saved.id)
    }

    /// The host answered the saved row's device ID: that row takes the pairing in place, under the same ID, so its
    /// tabs come back. Another device ID (a host before pairing again) adds a row and leaves the old one as it was.
    func testPairingAgainKeepsTheSavedRowAndItsTabs() throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pin = String(repeating: "ab", count: 32)
        let old = SavedHost(address: "https://Studio.local:9841", deviceID: "device-a", name: "Studio", mode: .direct, certificateSHA256: pin,
                            tunnelRefused: true)
        let other = SavedHost(address: "https://other.example", deviceID: "device-b", name: "Other", mode: .direct, certificateSHA256: nil)
        defaults.set(try JSONEncoder().encode([old, other]), forKey: ProductIdentity.connectionsDefaultsKey)
        let model = AppModel(defaults: defaults)
        model.select(old)
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        model.workspace.open(chat)
        model.workspace.updateDraft(chat.id, "Unsent text")

        let route = try XCTUnwrap(HostRoute(kind: HostRoute.tailscale, host: "studio.tail1234.ts.net", port: 9841))
        let paired = SavedHost(address: "https://studio.local:9841", deviceID: "device-a", name: "Studio Mac", mode: .direct,
                               certificateSHA256: pin, routes: [route])
        let saved = AppModel.savingPairing(paired, previous: old, in: model.hosts)
        XCTAssertEqual(saved.host.id, old.id, "the same row: its address as saved, its device ID")
        XCTAssertEqual(saved.hosts.map(\.id), [old.id, other.id], "in its place, no second row")
        XCTAssertEqual(saved.host.name, "Studio Mac")
        XCTAssertEqual(saved.host.routes, [route])
        XCTAssertFalse(saved.host.tunnelRefused, "a pairing at home starts the tunnel afresh")
        model.hosts = saved.hosts
        model.select(other)
        model.select(saved.host)
        XCTAssertEqual(model.workspace.tabs.map(\.id), [chat.id], "the tabs saved under the row come back")
        XCTAssertEqual(model.workspace.tabs.first?.draft, "Unsent text")

        let older = AppModel.savingPairing(SavedHost(address: "https://studio.local:9841", deviceID: "device-new", name: "Studio",
                                                     mode: .direct, certificateSHA256: pin), previous: old, in: [old, other])
        XCTAssertEqual(older.hosts.map(\.id), [old.id, other.id, "https://studio.local:9841|device-new"])
        XCTAssertEqual(older.host.deviceID, "device-new")
        let first = AppModel.savingPairing(paired, previous: nil, in: [other])
        XCTAssertEqual(first.hosts.map(\.id), [other.id, paired.id])
    }

    // MARK: Settings

    /// Settings → Connection → Forget…: the credential, the saved host, its workspace and tabs, its plain chats' model
    /// and this device's copy of its chats go, after the copy closed; the selected host returns to pairing.
    func testForgettingTheSelectedHostRemovesWhatThisDeviceKeptAndReturnsToPairing() async throws {
        let suite = "agentland-ios-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = SavedHost(address: "https://test.example", deviceID: "device-a", name: "Test", mode: .direct, certificateSHA256: nil)
        let kept = SavedHost(address: "https://other.example", deviceID: "device-b", name: "Other", mode: .direct, certificateSHA256: nil)
        defaults.set(try JSONEncoder().encode([host, kept]), forKey: ProductIdentity.connectionsDefaultsKey)
        let removed = RemovedCopies()
        let model = AppModel(defaults: defaults, deviceCopyRemover: { identity in await removed.add(identity) })
        model.select(host)
        let identity = ConnectionIdentity(host: host.address, deviceID: host.deviceID)
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "s", title: "Chat")
        model.workspace.open(chat)
        model.workspace.updateDraft(chat.id, "Unsent text")
        model.workspace.setPlainChatDefaultModel("anthropic/claude-sonnet")

        model.forget(host)
        XCTAssertNil(model.selectedHost, "the selected host gone: the app shows pairing")
        XCTAssertEqual(model.hosts.map(\.id), [kept.id])
        XCTAssertTrue(WorkspacePersistence(defaults: defaults).load(for: identity).isEmpty, "its tabs and drafts go")
        XCTAssertNil(defaults.string(forKey: WorkspaceModel.plainChatModelKey + identity.storageKey))
        XCTAssertNil(defaults.string(forKey: ProductIdentity.selectedConnectionDefaultsKey))
        await model.forgetting?.value
        let copies = await removed.identities
        XCTAssertEqual(copies, [identity], "this device's copy of its chats and terminal logs goes too")
        let relaunched = AppModel(defaults: defaults, deviceCopyRemover: { _ in })
        XCTAssertEqual(relaunched.hosts.map(\.id), [kept.id])
        XCTAssertNil(relaunched.selectedHost)
    }

    /// One honest name for the route in use, from the route the address belongs to.
    func testTheRouteInUseIsNamedByItsRoute() throws {
        let local = try XCTUnwrap(HostRoute(kind: HostRoute.local, host: "studio.local", port: 9841))
        let tailnet = try XCTUnwrap(HostRoute(kind: HostRoute.tailscale, host: "studio.tail1234.ts.net", addresses: ["100.101.102.103"], port: 9841))
        let host = SavedHost(address: "https://studio.local:9841", deviceID: "d", name: "Studio", mode: .tailscale,
                             certificateSHA256: String(repeating: "ab", count: 32), routes: [local, tailnet])
        func name(_ endpoint: String, _ port: Int = 9841) throws -> String {
            AppModel.routeName(of: .address(try XCTUnwrap(HostEndpoint(host: endpoint, port: port))), host: host)
        }
        XCTAssertEqual(try name("studio.local"), "Local network", "not the pairing's mode (Tailscale HTTPS)")
        XCTAssertEqual(try name("100.101.102.103"), "Tailscale")
        XCTAssertEqual(AppModel.routeName(of: .tunnel, host: host), "Remote access (iroh)")
        let bare = SavedHost(address: "https://localhost:9841", deviceID: "d", name: "Dev", mode: .direct, certificateSHA256: nil)
        XCTAssertEqual(AppModel.routeName(of: .address(try XCTUnwrap(HostEndpoint(host: "localhost", port: 9841))), host: bare), "Paired address")
        XCTAssertEqual(AppModel.routeName(of: .address(try XCTUnwrap(HostEndpoint(host: "mac.local", port: 9841))), host: bare), "Local network")
        XCTAssertEqual(AppModel.routeName(of: .address(try XCTUnwrap(HostEndpoint(host: "100.64.0.9", port: 9841))), host: bare), "Tailscale")
        XCTAssertEqual(AppModel.routeName(of: .address(try XCTUnwrap(HostEndpoint(host: "100.200.0.9", port: 9841))), host: bare), "Paired address")
    }

    /// The status at the top of Settings: the host's state and, while it answers, the route.
    func testTheStatusSaysTheStateAndTheRoute() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "status-\(UUID())"))
        let model = AppModel(defaults: defaults)
        let host = SavedHost(address: "https://studio.local:9841", deviceID: "d", name: "Studio", mode: .direct, certificateSHA256: nil)
        model.selectedHost = host
        XCTAssertEqual(model.connectionStateName, "Connecting…")
        XCTAssertEqual(model.connectionSummary, "Connecting… · Local network", "a host known at one address goes there")
    }

    /// Hide content in the app switcher: the cover shows while the scene is not active, never during Face ID.
    func testThePrivacyCoverShowsOnlyWhileTheSceneIsNotActiveAndNoUnlockRuns() {
        XCTAssertFalse(PrivacyCover.settingDefault, "off unless asked")
        XCTAssertFalse(PrivacyCover.isVisible(enabled: false, phase: .inactive, authenticating: false))
        XCTAssertTrue(PrivacyCover.isVisible(enabled: true, phase: .inactive, authenticating: false))
        XCTAssertTrue(PrivacyCover.isVisible(enabled: true, phase: .background, authenticating: false))
        XCTAssertFalse(PrivacyCover.isVisible(enabled: true, phase: .active, authenticating: false))
        XCTAssertFalse(PrivacyCover.isVisible(enabled: true, phase: .inactive, authenticating: true),
                       "Face ID's prompt makes the scene inactive over the lock cover, which keeps its motion")
    }

    func testConnectionMonitorReportsStopsAndOutagesImmediatelyAndRecovers() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "connection-\(UUID())"))
        let model = AppModel(defaults: defaults)
        let transport = PulseTransport([
            .stream(["{\"type\":\"ready\",\"intervalMs\":1500}"], hold: false),
            .stream(["{\"type\":\"ready\",\"intervalMs\":1500}", "{\"type\":\"stopping\"}"], hold: true),
            .fail(URLError(.cannotConnectToHost)),
            .stream(["{\"type\":\"ready\",\"intervalMs\":1500}"], hold: true)
        ])
        model.selectedHost = SavedHost(address: "https://test.example", deviceID: "device", name: "Test", mode: .direct, certificateSHA256: nil)
        model.client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: transport)
        XCTAssertEqual(model.connection, .checking)
        XCTAssertTrue(model.hostReachable, "Nothing is reported offline before a failure is proven")

        model.handleScenePhase(.active)
        await eventually { model.connection == .offline(.hostStopped) }
        XCTAssertFalse(model.hostReachable)
        XCTAssertEqual(model.workspace.connectionEpoch, 0, "A stream that ends on schedule is not an outage")
        await eventually { transport.pulses >= 3 }
        XCTAssertEqual(model.connection, .offline(.hostStopped), "A refused retry after an announced stop keeps saying the Mac app stopped")
        await eventually { model.connection == .online }
        XCTAssertEqual(model.workspace.connectionEpoch, 1, "Recovery tells retained surfaces to resume")

        model.handleScenePhase(.background)
        let opened = transport.pulses
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(transport.pulses, opened, "No pulse runs in the background")
    }

    func testSilentOrRefusedHostWithoutAStopIsUnreachable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "unreachable-\(UUID())"))
        let model = AppModel(defaults: defaults)
        let transport = PulseTransport([.fail(URLError(.timedOut)), .fail(URLError(.cannotConnectToHost)),
                                        .stream(["{\"type\":\"ready\",\"intervalMs\":1500}"], hold: true)])
        model.selectedHost = SavedHost(address: "https://test.example", deviceID: "device", name: "Test", mode: .direct, certificateSHA256: nil)
        model.client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: transport)
        model.handleScenePhase(.active)
        await eventually { model.connection == .offline(.unreachable) }
        await eventually { model.connection == .online }
        XCTAssertEqual(model.workspace.connectionEpoch, 1)
        model.handleScenePhase(.background)
    }


}
