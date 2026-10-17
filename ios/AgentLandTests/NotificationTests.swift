import XCTest
import CloudKit
import SwiftUI
import UIKit
import UserNotifications
import AgentLandCore
import AgentLandNotifications
import AgentLandWorkspace
@testable import AgentLand

/// The system's permission and push registration, scripted.
@MainActor private final class ScriptedNoticeSystem: NoticeSystem {
    var permission: NoticePermission
    private(set) var requests = 0
    private(set) var registrations = 0
    init(permission: NoticePermission = .notDetermined) { self.permission = permission }
    func notificationPermission() async -> NoticePermission { permission }
    func requestNotificationPermission() async throws -> Bool {
        requests += 1
        if permission == .notDetermined { permission = .allowed }
        return permission == .allowed
    }
    func registerForRemoteNotifications() { registrations += 1 }
}

/// A notice database with a fixed account, subscriptions and records; it never touches CloudKit.
private actor ScriptedNoticeDatabase: NoticeDatabase {
    var status: NoticeAccountStatus = .available
    var subscriptions: Set<CKSubscription.ID> = []
    var records: [String: NoticeRecord] = [:]
    private(set) var reads: [String] = []

    init(subscribed kinds: [NoticeKind] = [], records: [NoticeRecord] = []) {
        subscriptions = Set(kinds.map(NoticeSubscriptionPlan.subscriptionID(for:)))
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.recordName, $0) })
    }

    func accountStatus() async throws -> NoticeAccountStatus { status }
    func createZone() async throws {}
    func save(_ records: [NoticeRecord]) async throws -> [String: Result<Void, any Error>] { [:] }
    func deleteRecords(hostID: String, createdBefore date: Date, limit: Int) async throws -> Int { 0 }
    func subscriptionIDs() async throws -> Set<CKSubscription.ID> { subscriptions }
    func modifySubscriptions(saving: [CKQuerySubscription], deleting ids: [CKSubscription.ID]) async throws -> [CKSubscription.ID: Result<Void, any Error>] {
        for subscription in saving { subscriptions.insert(subscription.subscriptionID) }
        for id in ids { subscriptions.remove(id) }
        return Dictionary(uniqueKeysWithValues: (saving.map(\.subscriptionID) + ids).map { ($0, Result<Void, any Error>.success(())) })
    }
    func record(named recordName: String) async throws -> NoticeRecord? {
        reads.append(recordName)
        return records[recordName]
    }
}

@MainActor private final class GateAuthenticator: AppAuthenticating {
    private var continuation: CheckedContinuation<Bool, Error>?
    var waiting: Bool { continuation != nil }
    func authenticate(reason: String) async throws -> Bool { try await withCheckedThrowingContinuation { continuation = $0 } }
    func invalidate() {}
    func finish() { continuation?.resume(returning: true); continuation = nil }
}

@MainActor private func eventually(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Timed out", file: file, line: line)
}

/// Push on iPhone and iPad: the alert text the app must carry, the tapped-notification route through
/// the app model, the foreground alert decision, CloudKit staying off in test runs, and the Settings pane.
@MainActor final class NotificationTests: XCTestCase {
    private let studioFingerprint = String(repeating: "ab", count: 32)
    private let homeFingerprint = String(repeating: "cd", count: 32)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "agentland-notification-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private var studio: SavedHost {
        SavedHost(address: "https://studio.example", deviceID: "device-studio", name: "Studio", mode: .direct, certificateSHA256: studioFingerprint)
    }
    private var home: SavedHost {
        SavedHost(address: "https://home.example", deviceID: "device-home", name: "Home Mac", mode: .direct, certificateSHA256: homeFingerprint)
    }

    private func save(_ hosts: [SavedHost], selected: SavedHost?) throws {
        defaults.set(try JSONEncoder().encode(hosts), forKey: ProductIdentity.connectionsDefaultsKey)
        if let selected { defaults.set(selected.id, forKey: ProductIdentity.selectedConnectionDefaultsKey) }
    }

    private func notifications(_ system: ScriptedNoticeSystem? = nil, database: ScriptedNoticeDatabase? = nil) -> NotificationsModel {
        NotificationsModel(defaults: defaults, system: system ?? ScriptedNoticeSystem(),
                           unavailability: database == nil ? .turnedOff : nil, makeDatabase: { database })
    }

    private func link(_ kind: NoticeKind, fingerprint: String, project: String? = "workspace", session: String? = "ses_1",
                      complete: Bool = true) -> NoticeDeepLink {
        let hostID = NoticeHostID.make(certificateSHA256: fingerprint)!
        var link = NoticeDeepLink(record: NoticeRecord(recordName: "\(hostID)-ntc_1", kind: kind, hostID: hostID,
                                                       projectID: project ?? "", projectName: "AgentLand",
                                                       sessionID: session, createdAt: Date()))
        link.projectID = project
        link.isComplete = complete
        return link
    }

    /// Opens the selected host and clears its opening cover.
    private func finishOpening(_ model: AppModel) throws {
        model.handleScenePhase(.active)
        model.completePresentation(try XCTUnwrap(model.presentationTicket))
        XCTAssertFalse(model.presentationPending)
    }

    // MARK: Alert text

    func testTheAppCarriesTheNoticeAlertText() {
        XCTAssertEqual(NoticeAlertText.keysMissingOrDifferent(in: .main), [],
                       "iOS resolves the subscriptions' localization keys in the app's own Localizable table")
        XCTAssertEqual(Bundle.main.localizedString(forKey: "notice.title.chat.turn.finished", value: nil, table: nil), "Reply ready")
    }

    // MARK: Activation

    /// On activation notifications read the permission and register for pushes once it is allowed (never
    /// asking). That waits while the opening cover shows, so nothing competes with the selected surface.
    func testTheActivationCheckWaitsForTheOpeningCover() async throws {
        try save([studio], selected: studio)
        let system = ScriptedNoticeSystem(permission: .allowed)
        let model = AppModel(defaults: defaults, notifications: notifications(system))
        model.handleScenePhase(.active)
        XCTAssertTrue(model.presentationPending)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(system.registrations, 0, "Nothing is read while the opening cover shows")

        model.completePresentation(try XCTUnwrap(model.presentationTicket))
        await eventually { system.registrations == 1 }
        XCTAssertEqual(model.notifications.permission, .allowed)
        XCTAssertEqual(system.requests, 0, "Activation never asks")

        // Without a host nothing covers the pairing screen: the check runs on activation.
        model.handleScenePhase(.background)
        model.disconnect()
        model.handleScenePhase(.active)
        await eventually { system.registrations == 2 }
    }

    // MARK: Tapped notifications

    func testATappedNoticeWaitsForUnlockAndTheOpeningThenOpensItsChat() async throws {
        try save([studio], selected: studio)
        defaults.set(true, forKey: "agentland.lock.enabled")
        let authenticator = GateAuthenticator()
        let model = AppModel(defaults: defaults, authenticatorFactory: { authenticator }, notifications: notifications())
        XCTAssertTrue(model.locked)

        model.openNotice(link(.approvalNeeded, fingerprint: studioFingerprint, session: "ses_approve"))
        model.handleScenePhase(.active)
        await eventually { authenticator.waiting }
        XCTAssertNil(model.workspace.currentTab, "held while locked")

        authenticator.finish()
        await eventually { !model.locked }
        XCTAssertTrue(model.presentationPending)
        XCTAssertNil(model.workspace.currentTab, "held while the opening cover shows")

        model.completePresentation(try XCTUnwrap(model.presentationTicket))
        let chat = try XCTUnwrap(model.workspace.currentTab)
        XCTAssertEqual(chat.kind, .chat)
        XCTAssertEqual(chat.resourceID, "ses_approve", "the approval shows at the end of its chat")
        XCTAssertEqual(chat.projectID, "workspace")
        XCTAssertEqual(model.workspace.selectedProjectID, "workspace")
        XCTAssertFalse(model.presentationPending)
        XCTAssertNil(model.pendingNotice)

        // The same chat again selects its tab instead of opening another.
        model.workspace.open(WorkspaceTab(kind: .files, projectID: "workspace", title: "Files"), replacingHome: nil)
        XCTAssertNotEqual(model.workspace.currentTab?.id, chat.id)
        model.openNotice(link(.turnFinished, fingerprint: studioFingerprint, session: "ses_approve"))
        XCTAssertEqual(model.workspace.currentTab?.id, chat.id)
        XCTAssertEqual(model.workspace.tabs.filter { $0.kind == .chat }.count, 1)
    }

    /// A plain chat's notice (`projectId` `chats`) opens the chat without a workspace: the host's projects never
    /// list the Chats space, and showing the chat leaves the workspace in use as it was.
    func testAPlainChatsNoticeOpensItWithoutAWorkspace() throws {
        try save([studio], selected: studio)
        let model = AppModel(defaults: defaults, notifications: notifications())
        try finishOpening(model)
        // As when the host answered its projects: the Chats space is not among them.
        model.workspace.projects = [Project(id: "workspace", name: "AgentLand")]
        model.workspace.hostIssue = nil
        XCTAssertEqual(model.noticeRouteState.projectIDs, ["workspace", "chats"])

        model.openNotice(link(.turnFinished, fingerprint: studioFingerprint, project: "chats", session: "ses_plain"))
        let chat = try XCTUnwrap(model.workspace.currentTab)
        XCTAssertEqual(chat.kind, .chat)
        XCTAssertEqual(chat.projectID, "chats")
        XCTAssertEqual(chat.resourceID, "ses_plain")
        XCTAssertNil(model.workspace.selectedProjectID, "No workspace is chosen for it")
        XCTAssertNil(model.appNotice, "Not a missing project")
        XCTAssertNil(model.pendingNotice)

        // A workspace in use stays in use.
        model.workspace.openWorkspace("workspace")
        model.openNotice(link(.approvalNeeded, fingerprint: studioFingerprint, project: "chats", session: "ses_plain_2"))
        XCTAssertEqual(model.workspace.currentTab?.resourceID, "ses_plain_2")
        XCTAssertEqual(model.workspace.selectedProjectID, "workspace")
    }

    func testANoticeOfAnotherSavedHostSwitchesHostThroughTheOpeningTicket() throws {
        try save([home, studio], selected: home)
        let model = AppModel(defaults: defaults, notifications: notifications())
        try finishOpening(model)
        XCTAssertEqual(model.selectedHost?.id, home.id)

        model.openNotice(link(.turnFailed, fingerprint: studioFingerprint, session: "ses_2"))
        XCTAssertEqual(model.selectedHost?.id, studio.id, "switched through the normal selection path")
        let chat = try XCTUnwrap(model.workspace.currentTab)
        XCTAssertEqual(chat.resourceID, "ses_2")
        XCTAssertTrue(model.presentationPending, "the new host's opening cover is up")
        let ticket = try XCTUnwrap(model.presentationTicket)
        XCTAssertEqual(ticket.hostID, studio.id)
        XCTAssertEqual(ticket.tabID, chat.id, "the cover clears only when the chat itself is ready")
        XCTAssertFalse(model.presentationReady)
    }

    func testANoticeFromAnUnpairedMacShowsANoticeAndChangesNothing() throws {
        try save([home], selected: home)
        let model = AppModel(defaults: defaults, notifications: notifications())
        try finishOpening(model)
        model.openNotice(link(.turnFinished, fingerprint: String(repeating: "ef", count: 32)))
        XCTAssertEqual(model.selectedHost?.id, home.id)
        XCTAssertNil(model.workspace.currentTab)
        XCTAssertTrue(model.appNotice?.text.contains("isn’t paired") == true, model.appNotice?.text ?? "no notice")
        XCTAssertNil(model.pendingNotice)
    }

    func testAPushThatLeftValuesOutReadsItsRecordFirst() async throws {
        try save([studio], selected: studio)
        let hostID = NoticeHostID.make(certificateSHA256: studioFingerprint)!
        let record = NoticeRecord(recordName: "\(hostID)-ntc_1", kind: .turnFailed, hostID: hostID, projectID: "workspace",
                                  projectName: "AgentLand", sessionID: "ses_run", createdAt: Date())
        let database = ScriptedNoticeDatabase(records: [record])
        let model = AppModel(defaults: defaults, notifications: notifications(database: database))
        try finishOpening(model)

        model.openNotice(link(.turnFailed, fingerprint: studioFingerprint, project: nil, session: nil, complete: false))
        await eventually { model.workspace.currentTab?.resourceID == "ses_run" }
        let reads = await database.reads
        XCTAssertEqual(reads, [record.recordName])
    }

    // MARK: Foreground alerts

    func testNoAlertForTheChatOnScreenOnly() throws {
        try save([studio], selected: studio)
        let model = AppModel(defaults: defaults, notifications: notifications())
        try finishOpening(model)
        let chat = WorkspaceTab(kind: .chat, projectID: "workspace", resourceID: "ses_1", title: "Chat")
        model.workspace.open(chat)

        let alert: UNNotificationPresentationOptions = [.banner, .list, .sound]
        XCTAssertEqual(model.presentationOptions(for: link(.turnFinished, fingerprint: studioFingerprint)), [])
        XCTAssertEqual(model.presentationOptions(for: link(.questionNeeded, fingerprint: studioFingerprint)), [])
        XCTAssertEqual(model.presentationOptions(for: link(.turnFinished, fingerprint: studioFingerprint, session: "ses_2")), alert)
        XCTAssertEqual(model.presentationOptions(for: link(.turnFinished, fingerprint: homeFingerprint)), alert,
                       "the same chat ID from another Mac")
        XCTAssertEqual(model.presentationOptions(for: nil), alert)
        XCTAssertEqual(model.selectedChatTurn, ChatTurnObservation(tabID: chat.id, working: false, startedAt: nil))

        model.handleScenePhase(.inactive)
        XCTAssertEqual(model.presentationOptions(for: link(.turnFinished, fingerprint: studioFingerprint)), alert,
                       "not on screen while the scene is inactive")
        model.handleScenePhase(.active)
        model.workspace.open(WorkspaceTab(kind: .files, projectID: "workspace", title: "Files"), replacingHome: nil)
        XCTAssertEqual(model.presentationOptions(for: link(.turnFinished, fingerprint: studioFingerprint)), alert)
        XCTAssertNil(model.selectedChatTurn)
    }

    /// Settings → Notifications → Sound off: an alert in front plays no sound either, and the silent sound the
    /// account's subscriptions name is in the app's bundle (without it iOS would play the default sound).
    func testWithTheSoundOffAnAlertInFrontIsSilentAndTheSilentSoundIsBundled() throws {
        try save([studio], selected: studio)
        defaults.set(false, forKey: NotificationsModel.Key.sound)
        let model = AppModel(defaults: defaults, notifications: notifications())
        try finishOpening(model)
        XCTAssertFalse(model.notifications.soundOn)
        XCTAssertEqual(model.presentationOptions(for: link(.turnFinished, fingerprint: homeFingerprint)), [.banner, .list])
        let name = NoticeSubscriptionPlan.silentSoundName as NSString
        XCTAssertNotNil(Bundle.main.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension))
    }

    // MARK: CloudKit stays off in test runs

    func testCloudKitIsOffForTestRuns() {
        XCTAssertEqual(AppModel.cloudKitEnvironment(arguments: ["AgentLand", "-AgentLandUITestsDisableAnimations"],
                                                    environment: [:])["AGENTLAND_CLOUDKIT"], "0")
        XCTAssertEqual(AppModel.cloudKitEnvironment(arguments: ["AgentLand"],
                                                    environment: ["XCTestConfigurationFilePath": "/x"])["AGENTLAND_CLOUDKIT"], "0")
        XCTAssertNil(AppModel.cloudKitEnvironment(arguments: ["AgentLand"], environment: [:])["AGENTLAND_CLOUDKIT"])
        XCTAssertEqual(NoticeCloudKit.unavailability(environment: AppModel.cloudKitEnvironment()), .turnedOff,
                       "this test host never makes a CKContainer")
        XCTAssertEqual(AppModel(defaults: defaults).notifications.unavailability, .turnedOff)
    }

    // MARK: Settings

    /// Renders the pane in the states a person meets. With `AGENTLAND_RENDER_DIR` set, the images are
    /// written there.
    func testTheSettingsPaneRenders() async throws {
        let allowed = notifications(ScriptedNoticeSystem(permission: .allowed),
                                    database: ScriptedNoticeDatabase(subscribed: NoticeGroup.kinds(of: [.replies, .approvals])))
        await allowed.refresh()
        XCTAssertEqual(allowed.enabledGroups, [.replies, .approvals])
        XCTAssertEqual(allowed.account, .status(.available))
        try await render(AppModel(defaults: defaults, notifications: allowed), name: "notifications-allowed", style: .light)
        try await render(AppModel(defaults: defaults, notifications: allowed), name: "notifications-allowed-dark", style: .dark)

        let noAccount = ScriptedNoticeDatabase()
        await noAccount.setStatus(.noAccount)
        let signedOut = notifications(ScriptedNoticeSystem(permission: .denied), database: noAccount)
        await signedOut.refresh()
        XCTAssertEqual(signedOut.account, .status(.noAccount))
        try await render(AppModel(defaults: defaults, notifications: signedOut), name: "notifications-no-account", style: .light)

        let off = notifications()
        try await render(AppModel(defaults: defaults, notifications: off), name: "notifications-off-for-run", style: .light)
    }

    /// The tip after a long turn, TipKit's (NO-2). The app's short notices are the system's alert now, from the app's
    /// root, so the overlay draws only the tip.
    func testTheTipRenders() async throws {
        let notifications = notifications(database: ScriptedNoticeDatabase())
        await notifications.sceneBecameActive()
        let tab = UUID(), start = Date()
        notifications.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        notifications.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 45)
        XCTAssertTrue(notifications.tipVisible)
        let model = AppModel(defaults: defaults, notifications: notifications)
        try await render(model, name: "notifications-tip", style: .light, content: NoticeOverlay())
        try await render(model, name: "notifications-tip-dark", style: .dark, content: NoticeOverlay())
    }

    private func render(_ model: AppModel, name: String, style: UIUserInterfaceStyle) async throws {
        try await render(model, name: name, style: style, content: NotificationsSettingsPane())
    }

    private func render(_ model: AppModel, name: String, style: UIUserInterfaceStyle, content: some View) async throws {
        let controller = UIHostingController(rootView: content.environment(model))
        controller.overrideUserInterfaceStyle = style
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 1100)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.height, 0)
        if let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"], let data = image.pngData() {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

private extension ScriptedNoticeDatabase {
    func setStatus(_ status: NoticeAccountStatus) { self.status = status }
}
