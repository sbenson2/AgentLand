import XCTest
import AgentLandCore
import AgentLandChat
import AgentLandBranding
@testable import AgentLandArchive
@testable import AgentLandWorkspace

/// The Settings that keep data on this device: the plain chats' default model per host, what forgetting a host
/// removes, clearing the device's copy of a host's chats and terminal logs, and the terminal's settings.
@MainActor final class SettingsDataTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let other = ConnectionIdentity(host: "https://other.local:9841", deviceID: "device-b")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "settings-data-\(name)-\(UUID())"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func host() -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, PlainChatsWorkspaceTests.plainCapabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"}]}"#) }
        host.on("/v1/sessions") { _ in (201, #"{"id":"claude:new","title":"Claude Code chat","projectId":"a","provider":"claude"}"#) }
        return host
    }

    private func attached(_ host: ScriptedHost, defaults: UserDefaults, identity: ConnectionIdentity? = nil) async throws -> WorkspaceModel {
        let model = WorkspaceModel(defaults: defaults)
        let identity = identity ?? self.identity
        model.attach(hostID: identity.storageKey, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: identity.host), token: "token", transport: host))
        await model.refreshProjects()
        return model
    }

    // MARK: The plain chats' model

    func testANewPlainChatStartsWithTheModelChosenForThisHost() async throws {
        let defaults = try defaults()
        let model = try await attached(host(), defaults: defaults)
        XCTAssertNil(model.plainChatDefaultModel, "the host's default, as before")
        model.selectProject("a")
        model.setPlainChatDefaultModel("anthropic/claude-sonnet")
        model.newPlainChat()
        await waitUntil("the new chat") { model.currentTab?.resourceID == "claude:new" }
        let tab = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(tab.chatModelID, "anthropic/claude-sonnet")
        XCTAssertEqual(model.chatStore(for: tab).selectedModelID, "anthropic/claude-sonnet", "the first message asks for it")
        model.chatStore(for: tab).shutdown()

        // Kept for this host and device, and only for it.
        let again = try await attached(host(), defaults: defaults)
        XCTAssertEqual(again.plainChatDefaultModel, "anthropic/claude-sonnet")
        let elsewhere = try await attached(host(), defaults: defaults, identity: other)
        XCTAssertNil(elsewhere.plainChatDefaultModel)

        // Another agent's chat in a workspace cannot be made.
        again.openWorkspace("a")
        again.create(.chat, projectID: "a", provider: .opencode)
        XCTAssertFalse(again.creating, "Only Claude Code and Codex chats can be created")
        XCTAssertEqual(again.currentTab?.resourceID, "claude:new", "Rejected creation leaves the resumed chat selected")

        again.setPlainChatDefaultModel(nil)
        XCTAssertNil(defaults.string(forKey: WorkspaceModel.plainChatModelKey + identity.storageKey))
    }

    // MARK: Forgetting a host

    func testForgettingAHostRemovesItsSavedChoicesAndNoOtherHosts() throws {
        let defaults = try defaults()
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "a", name: "App")]
        model.openWorkspace("a")
        model.selectProject("a")
        model.setPlainChatDefaultModel("anthropic/claude-sonnet")
        for key in ["agentland.phone.closedWorkspaces.", WorkspaceModel.plainChatModelKey] {
            defaults.set("x", forKey: key + other.storageKey)
        }
        defaults.set(["b"], forKey: "agentland.phone.closedWorkspaces." + identity.storageKey)
        model.detach()

        model.forgetSavedState(for: identity)
        for key in ["agentland.phone.closedWorkspaces.", WorkspaceModel.plainChatModelKey, WorkspaceStorageKeys.mobile.currentWorkspace,
                    WorkspaceStorageKeys.mobile.tabSelections, WorkspaceStorageKeys.mobile.lastUsed] {
            XCTAssertNil(defaults.object(forKey: key + identity.storageKey), key)
        }
        XCTAssertTrue(WorkspacePersistence(defaults: defaults).load(for: identity).isEmpty, "its tabs and drafts go")
        XCTAssertNotNil(defaults.object(forKey: WorkspaceModel.plainChatModelKey + other.storageKey), "another host's stay")
        XCTAssertNotNil(defaults.object(forKey: "agentland.phone.closedWorkspaces." + other.storageKey))
    }

    // MARK: Clearing the device's copy

    func testClearingTheCopyEmptiesItAndStartsItsSyncOverWhileTabsStay() async throws {
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        let chat = ArchiveChangeItem.chat(ArchiveChatRecord(id: "ses_1", projectID: "a", title: "Fix the loop",
                                                            createdAt: "2026-10-01T09:00:00.000Z", updatedAt: "2026-10-01T09:00:00.000Z"))
        try await store.apply(ArchiveChangesPage(epoch: "e1", changes: [ArchiveChange(seq: 1, item: chat)], cursor: "e1.1"))
        let archive = WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
        let model = WorkspaceModel(defaults: try defaults())
        model.attach(hostID: hostID, identity: identity, client: nil, archive: archive)
        let tab = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "ses_1", title: "Fix the loop")
        model.open(tab)
        model.updateDraft(tab.id, "Unsent text")
        archive.setRunning(true)

        try await model.clearDeviceCopy()
        let chats = try await store.chats()
        XCTAssertTrue(chats.isEmpty, "the copy is empty")
        let state = try await store.syncState()
        XCTAssertNil(state.cursor, "the sync starts over from the beginning")
        XCTAssertEqual(model.tabs.first?.draft, "Unsent text", "drafts are untouched")
        await archive.settle()
        archive.close()
    }

    func testDetachingWaitsForTheCopyToCloseBeforeItsFilesGo() async throws {
        let archive = WorkspaceArchive(store: try ArchiveStore.inMemory(hostKey: hostID), terminalLogs: nil, attachments: nil, client: nil)
        let model = WorkspaceModel(defaults: try defaults())
        model.attach(hostID: hostID, identity: identity, client: nil, archive: archive)
        archive.setRunning(true)
        model.detach()
        let closing = try XCTUnwrap(model.archiveClosing)
        await closing.value
        XCTAssertNil(model.archive)
    }

    // MARK: Terminal

    /// Settings → Apple Intelligence: on until turned off, and the model is used only while it is on; while the model
    /// can't run the page says why and that AgentLand's own quips and names stand in.
    func testAppleIntelligenceIsOnUntilTurnedOffAndSaysWhyItCantRun() throws {
        let suite = "apple-intelligence-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppleIntelligence.isOn(defaults), "A missing value is on")
        defaults.set(false, forKey: AppleIntelligence.settingKey)
        XCTAssertFalse(AppleIntelligence.isOn(defaults))
        XCTAssertFalse(AppleIntelligence.canUseModel(defaults))
        XCTAssertNil(AppleIntelligence.unavailableText(.available, device: "iPhone"))
        XCTAssertEqual(AppleIntelligence.unavailableText(.turnedOff, device: "iPhone")?.message,
                       "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri. Until then AgentLand writes its own quips and names.")
        XCTAssertEqual(AppleIntelligence.unavailableText(.turnedOff, device: "Mac")?.message.hasPrefix("Turn on Apple Intelligence in System Settings"), true)
        XCTAssertEqual(AppleIntelligence.unavailableText(.notEligible, device: "iPad")?.title, "Not available on this iPad")
        for availability in [AppleIntelligence.Availability.notEligible, .notReady, .unavailable] {
            XCTAssertEqual(AppleIntelligence.unavailableText(availability, device: "iPhone")?.message.contains("its own quips and names"), true)
        }
    }

    func testTheTerminalsTextSizeIsTheChosenOneOrTheAutomaticOne() {
        XCTAssertEqual(TerminalSettings.fontSize(chosen: TerminalSettings.automaticFontSize, automatic: 13), 13, "follows the text size by default")
        XCTAssertEqual(TerminalSettings.fontSize(chosen: 18, automatic: 13), 18)
        XCTAssertEqual(TerminalSettings.fontSize(chosen: 60, automatic: 13), 24, "kept within the sizes offered")
        XCTAssertEqual(TerminalSettings.fontSize(chosen: 3, automatic: 13), 9)
        XCTAssertTrue(TerminalSettings.keyBarDefault)
        XCTAssertFalse(TerminalSettings.bellHapticDefault)
    }

    func testTheBellPlaysAtMostOnceASecond() {
        var throttle = TerminalBellThrottle()
        let start = Date()
        XCTAssertTrue(throttle.allows(at: start))
        XCTAssertFalse(throttle.allows(at: start.addingTimeInterval(0.4)))
        XCTAssertFalse(throttle.allows(at: start.addingTimeInterval(0.99)))
        XCTAssertTrue(throttle.allows(at: start.addingTimeInterval(1.0)))
    }
}
