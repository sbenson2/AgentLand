import CloudKit
import Foundation
import XCTest
import AgentLandCore
import AgentLandNotifications
import AgentLandNotificationsTesting
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The app side: settings, the entitlement gate, the relay's lifetime with
/// the host, and the test notice.
@MainActor
final class NotificationRelayControllerTests: XCTestCase {
    private let fingerprint = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    private var hostID: String { NoticeHostID.make(certificateSHA256: fingerprint)! }
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults() -> UserDefaults {
        let suite = "dev.agentland.test.notifications.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func feed(_ host: FakeNoticeHost) -> HostNoticeFeed {
        HostNoticeFeed(baseURL: host.baseURL, token: "local-session-token", transport: FakeHostTransport())
    }

    private func notice(_ seq: Int64, clock: TestClock, age: TimeInterval = 5, title: String = "Fix the login") -> HostNotice {
        HostNotice(seq: seq, id: "ntc_\(seq)", kind: "chat.turn.finished", projectID: "workspace", projectName: "AgentLand",
                   sessionID: "ses_1", title: title, mayContainContent: true, createdAt: noticeTime(clock.now().addingTimeInterval(-age)))
    }

    func testWithoutTheICloudEntitlementNothingTouchesCloudKitOrTheHost() async throws {
        // This test process is not signed for iCloud, like an ad-hoc build.
        let controller = NotificationRelayController(preferences: defaults())
        XCTAssertEqual(controller.iCloud, .unavailable(.notSignedForICloud))
        XCTAssertFalse(controller.canUseICloud)
        XCTAssertEqual(controller.iCloudSummary, "Not available in this build")
        XCTAssertEqual(controller.iCloudDetail, "This copy of AgentLand isn't signed for iCloud, so it can't send notifications.")

        let host = FakeNoticeHost()
        host.issue { notice($0, clock: TestClock(Date())) }
        controller.hostStarted(hostID: hostID, feed: feed(host))
        controller.sendTestNotification(certificateSHA256: fingerprint, projectID: "workspace", projectName: "AgentLand")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(host.requests.isEmpty, "no relay runs")
        XCTAssertEqual(controller.testState, .idle)
        XCTAssertEqual(controller.relayStatus.phase, .stopped)

        // The app's own controller is built the same way.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-notices-\(UUID().uuidString)")
        let app = HostController(statePath: root.appendingPathComponent("host.json").path, runner: NoRunner(), secrets: NoSecrets(),
                                 preferences: defaults(), runtime: IdleRuntime())
        XCTAssertEqual(app.notifications.iCloud, .unavailable(.notSignedForICloud))

        let off = NotificationRelayController(preferences: defaults(), cloudKit: .unavailable(.turnedOff))
        XCTAssertEqual(off.iCloudSummary, "Turned off for this run")
        XCTAssertEqual(off.iCloudDetail, "Notifications are off because AGENTLAND_CLOUDKIT=0 is set.")
    }

    func testTheRelayRunsOnlyWhileTheHostRunsAndSendingIsOn() async {
        let clock = TestClock()
        let database = InMemoryNoticeDatabase(zoneExists: true)
        let preferences = defaults()
        let controller = NotificationRelayController(preferences: preferences, cloudKit: .available(database), clock: clock)
        XCTAssertTrue(controller.sendEnabled, "on by default")
        XCTAssertTrue(controller.includeTitles, "on by default")
        await eventually { controller.iCloud == .account(.available) }
        XCTAssertEqual(controller.iCloudSummary, "Available")

        let host = FakeNoticeHost()
        host.issue { notice($0, clock: clock) }
        controller.hostStarted(hostID: hostID, feed: feed(host))
        await eventually("the first notice relayed") { host.acknowledged == 1 && host.heldCount == 1 }
        await eventually { controller.relayStatus.written == 1 }

        // The host stops (Disconnect, a crash): the long-poll ends and nothing else is read.
        controller.hostStopped()
        await eventually("the long-poll cancelled") { host.cancelled == 1 }
        let polls = host.polls.count
        host.issue { notice($0, clock: clock) }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.polls.count, polls)

        // Running again, then sending turned off: the relay stops.
        controller.hostStarted(hostID: hostID, feed: feed(host))
        await eventually { host.acknowledged == 2 && host.heldCount == 1 }
        controller.sendEnabled = false
        await eventually { host.cancelled == 2 }

        // What happened while sending was off is not sent when it is turned on.
        host.issue { notice($0, clock: clock, age: 1) }
        controller.sendEnabled = true
        await eventually { host.acknowledged == 3 }
        let creations = await database.creations
        XCTAssertEqual(creations, ["\(hostID)-ntc_1", "\(hostID)-ntc_2"])

        // Quit: the relay stops within its bound.
        let started = Date()
        await controller.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        await eventually { host.cancelled == 3 }

        // Both settings persist in the app's preferences.
        let reloaded = NotificationRelayController(preferences: preferences, cloudKit: .unavailable(.turnedOff))
        XCTAssertTrue(reloaded.sendEnabled)
        controller.includeTitles = false
        controller.sendEnabled = false
        let again = NotificationRelayController(preferences: preferences, cloudKit: .unavailable(.turnedOff))
        XCTAssertFalse(again.sendEnabled)
        XCTAssertFalse(again.includeTitles)
    }

    func testIncludeChatTitlesReachesTheRunningRelay() async throws {
        let clock = TestClock()
        let database = InMemoryNoticeDatabase(zoneExists: true)
        let controller = NotificationRelayController(preferences: defaults(), cloudKit: .available(database), clock: clock)
        let host = FakeNoticeHost()
        controller.hostStarted(hostID: hostID, feed: feed(host))
        await eventually { host.heldCount == 1 }
        controller.includeTitles = false
        try await Task.sleep(for: .milliseconds(50))
        host.issue { notice($0, clock: clock, title: "Rotate the prod keys") }
        await eventually { host.acknowledged == 1 }
        await controller.shutdown()
        let record = await database.records["\(hostID)-ntc_1"]
        XCTAssertNil(record?.title)
        XCTAssertEqual(record?.alertBody, "AgentLand")
    }

    func testSendTestNotificationWritesOneTestNotice() async throws {
        let database = InMemoryNoticeDatabase()
        let controller = NotificationRelayController(preferences: defaults(), cloudKit: .available(database), clock: TestClock())
        controller.sendTestNotification(certificateSHA256: fingerprint, projectID: "workspace", projectName: "AgentLand")
        await eventually { controller.testState == .sent }
        XCTAssertEqual(controller.testMessage, "Sent. It appears on iPhone and iPad where AgentLand is allowed to send notifications.")
        let records = Array(await database.records.values)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.recordName.hasPrefix("\(hostID)-test-"))
        XCTAssertEqual(record.kind, .turnFinished)
        XCTAssertEqual(record.title, "Test from AgentLand")
        XCTAssertEqual(record.alertBody, "Test from AgentLand · AgentLand")
        XCTAssertEqual(record.projectID, "workspace")
        XCTAssertNil(record.sessionID)
        let zoneExists = await database.zoneExists
        XCTAssertTrue(zoneExists, "the test creates the zone when needed")

        controller.sendTestNotification(certificateSHA256: nil, projectID: "workspace", projectName: "AgentLand")
        XCTAssertEqual(controller.testState, .failed("Connect once so this Mac has its secure identity, then try again."))

        await database.setStatus(.noAccount)
        controller.sendTestNotification(certificateSHA256: fingerprint, projectID: "workspace", projectName: "AgentLand")
        await eventually { controller.testState == .failed("Sign in to iCloud in System Settings to send notifications.") }
        XCTAssertEqual(controller.iCloud, .account(.noAccount))
        XCTAssertEqual(controller.iCloudSummary, "No account")
        let count = await database.records.count
        XCTAssertEqual(count, 1)
    }

    func testDisconnectAndQuitStopTheRelay() async throws {
        let clock = TestClock()
        let database = InMemoryNoticeDatabase(zoneExists: true)
        let notifications = NotificationRelayController(preferences: defaults(), cloudKit: .available(database), clock: clock)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-notices-\(UUID().uuidString)")
        let app = HostController(statePath: root.appendingPathComponent("host.json").path, runner: NoRunner(), secrets: NoSecrets(),
                                 preferences: defaults(), runtime: IdleRuntime(), notifications: notifications)
        let host = FakeNoticeHost()

        notifications.hostStarted(hostID: hostID, feed: feed(host))
        await eventually { host.heldCount == 1 }
        app.stop() // Disconnect
        await app.waitForCurrentOperation()
        await eventually("Disconnect ends the relay") { host.cancelled == 1 }

        notifications.hostStarted(hostID: hostID, feed: feed(host))
        await eventually { host.heldCount == 1 }
        let started = Date()
        try await app.stopForApplicationTermination() // Quit
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await eventually("Quit ends the relay") { host.cancelled == 2 }
    }

    func testEveryAccountStateExplainsItself() {
        let states: [NotificationRelayController.ICloudState] = [
            .account(.available), .account(.noAccount), .account(.restricted), .account(.temporarilyUnavailable),
            .account(.couldNotDetermine), .checkFailed, .unavailable(.turnedOff), .unavailable(.notSignedForICloud)
        ]
        for state in states {
            XCTAssertNotNil(NotificationRelayController.detail(for: state), "\(state)")
        }
        XCTAssertNil(NotificationRelayController.detail(for: .checking))
        XCTAssertEqual(NotificationRelayController.describe(problem: .quotaExceeded), "Your iCloud storage is full, so notices can't be sent.")
    }
}

/// No host commands and no Keychain in these tests.
private struct NoRunner: HostCommandRunning {
    func run(_ command: HostCommand) throws -> CommandOutput { throw DesktopError.commandFailed("No commands in these tests.") }
}

private struct NoSecrets: SecretStoring {
    func save(_ secret: String, account: String) throws {}
    func load(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
}

private actor IdleRuntime: OpenCodeRuntimeRunning {
    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL {
        throw DesktopError.commandFailed("This runtime must not start in these tests.")
    }
    func stop() async throws {}
    func isRunning() -> Bool { false }
    func endpoint() -> URL? { nil }
}
