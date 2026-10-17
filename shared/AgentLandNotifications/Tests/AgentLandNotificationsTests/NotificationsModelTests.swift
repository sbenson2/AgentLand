import CloudKit
import XCTest
@testable import AgentLandNotifications
import AgentLandNotificationsTesting

/// The system's permission and push registration, scripted.
@MainActor private final class FakeNoticeSystem: NoticeSystem {
    var permission: NoticePermission
    /// What the person answers when asked.
    var answer = true
    private(set) var requests = 0
    private(set) var registrations = 0

    init(permission: NoticePermission = .notDetermined) { self.permission = permission }

    func notificationPermission() async -> NoticePermission { permission }

    func requestNotificationPermission() async throws -> Bool {
        requests += 1
        if permission == .notDetermined { permission = answer ? .allowed : .denied }
        return permission == .allowed
    }

    func registerForRemoteNotifications() { registrations += 1 }
}

@MainActor final class NotificationsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var databasesMade = 0

    override func setUp() async throws {
        suite = "notifications-model-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        databasesMade = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(_ system: FakeNoticeSystem, _ database: InMemoryNoticeDatabase,
                       unavailability: NoticeCloudKit.Unavailable? = nil) -> NotificationsModel {
        NotificationsModel(defaults: defaults, system: system, unavailability: unavailability) { [unowned self] in
            databasesMade += 1
            return database
        }
    }

    private func ids(_ kinds: [NoticeKind]) -> [CKSubscription.ID] { kinds.map(NoticeSubscriptionPlan.subscriptionID(for:)) }
    /// What a save deletes: the kinds turned off, then the retired subscriptions.
    private func deleted(_ kinds: [NoticeKind]) -> [CKSubscription.ID] { ids(kinds) + NoticeSubscriptionPlan.retiredSubscriptionIDs }

    // MARK: Asking only in context

    func testNothingIsAskedOrReadFromICloudUntilNotificationsAreUsed() async {
        let system = FakeNoticeSystem()
        let database = InMemoryNoticeDatabase()
        let model = model(system, database)
        await model.sceneBecameActive()
        await model.sceneBecameActive()
        XCTAssertEqual(model.permission, .notDetermined)
        XCTAssertEqual(system.requests, 0, "never asked at launch")
        XCTAssertEqual(system.registrations, 0, "nothing to register for until permission is allowed")
        XCTAssertEqual(databasesMade, 0, "no CKContainer until notifications are used")
        XCTAssertEqual(model.account, .unknown)
        model.observeChatTurn(ChatTurnObservation(tabID: UUID(), working: true, startedAt: nil), at: Date())
        XCTAssertEqual(databasesMade, 0)
    }

    func testTurningAGroupOnAsksOnceRegistersCreatesTheZoneAndSavesThePlan() async throws {
        let system = FakeNoticeSystem()
        let database = InMemoryNoticeDatabase()
        let model = model(system, database)

        await model.setGroup(.replies, enabled: true)
        XCTAssertNil(model.problem)
        XCTAssertEqual(system.requests, 1)
        XCTAssertEqual(system.registrations, 1)
        XCTAssertEqual(model.permission, .allowed)
        XCTAssertEqual(model.account, .status(.available))
        var zone = await database.zoneExists
        XCTAssertTrue(zone, "the Notices zone is made before the subscriptions")
        var kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, [.turnFinished, .turnFailed])
        var changes = await database.subscriptionChanges
        XCTAssertEqual(changes, [.modifySubscriptions(saving: ids(NoticeGroup.replies.kinds),
                                                      deleting: deleted(NoticeKind.allCases.filter { NoticeGroup(kind: $0) != .replies }))])
        let saved = await database.subscriptions[NoticeSubscriptionPlan.subscriptionID(for: .turnFinished)]
        XCTAssertEqual(saved?.notificationInfo?.titleLocalizationKey, "notice.title.chat.turn.finished")
        XCTAssertEqual(saved?.zoneID?.zoneName, "Notices")
        XCTAssertEqual(model.enabledGroups, [.replies])
        XCTAssertTrue(model.groupsConfirmed)
        XCTAssertNil(model.pendingGroups)
        XCTAssertFalse(model.working)
        XCTAssertEqual(defaults.object(forKey: NotificationsModel.Key.version) as? Int, NoticeSubscriptionPlan.version)
        XCTAssertEqual(defaults.stringArray(forKey: NotificationsModel.Key.groups), ["replies"])

        await model.setGroup(.approvals, enabled: true)
        XCTAssertEqual(system.requests, 1, "asked once")
        kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeKind.allCases))
        changes = await database.subscriptionChanges
        XCTAssertEqual(changes.last, .modifySubscriptions(saving: ids(NoticeKind.allCases), deleting: deleted([])))

        await model.setGroup(.replies, enabled: false)
        kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeGroup.approvals.kinds))
        XCTAssertEqual(model.enabledGroups, [.approvals])
        XCTAssertEqual(model.displayedGroups, [.approvals])

        await model.setGroup(.approvals, enabled: false)
        kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, [])
        changes = await database.subscriptionChanges
        XCTAssertEqual(changes.last, .modifySubscriptions(saving: [], deleting: deleted(NoticeKind.allCases)))
        zone = await database.zoneExists
        XCTAssertTrue(zone)
    }

    // MARK: Sound

    func testTurningTheSoundOffSavesEverySubscriptionWithTheSilentSoundForTheWholeAccount() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase(zoneExists: true)
        await database.insert(NoticeSubscriptionPlan(enabledKinds: NoticeGroup.replies.kinds).subscriptions())
        let model = model(system, database)
        XCTAssertTrue(model.soundOn, "on by default: alerts keep the sound they always had")

        await model.setSound(false)
        XCTAssertNil(model.problem)
        XCTAssertFalse(model.soundOn)
        XCTAssertNil(model.pendingSound)
        XCTAssertEqual(system.requests, 0, "the sound needs no permission")
        let kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeGroup.replies.kinds), "the groups stay as they were")
        var sounds = await database.subscriptions.values.map { $0.notificationInfo?.soundName }
        XCTAssertEqual(Set(sounds), [NoticeSubscriptionPlan.silentSoundName])
        XCTAssertEqual(defaults.object(forKey: NotificationsModel.Key.sound) as? Bool, false)

        // A group turned on later keeps the account's sound.
        await model.setGroup(.approvals, enabled: true)
        sounds = await database.subscriptions.values.map { $0.notificationInfo?.soundName }
        XCTAssertEqual(sounds.count, NoticeKind.allCases.count)
        XCTAssertEqual(Set(sounds), [NoticeSubscriptionPlan.silentSoundName])

        await model.setSound(true)
        sounds = await database.subscriptions.values.map { $0.notificationInfo?.soundName }
        XCTAssertEqual(Set(sounds), ["default"])
        XCTAssertTrue(model.soundOn)
    }

    func testAnotherDevicesSoundIsReadAndASoundWithNothingSubscribedWaitsForAGroup() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase(zoneExists: true)
        await database.insert(NoticeSubscriptionPlan(enabledKinds: NoticeGroup.replies.kinds, sound: false).subscriptions())
        let model = model(system, database)
        await model.refresh()
        XCTAssertFalse(model.soundOn, "the account's subscriptions say the sound is off")
        XCTAssertEqual(model.enabledGroups, [.replies])

        let empty = InMemoryNoticeDatabase(zoneExists: true)
        let fresh = NotificationsModel(defaults: UserDefaults(suiteName: suite + "-fresh")!, system: system, unavailability: nil) { empty }
        await fresh.setSound(false)
        XCTAssertFalse(fresh.soundOn)
        let changes = await empty.subscriptionChanges
        XCTAssertEqual(changes, [], "nothing is subscribed: nothing to save yet")
        await fresh.setGroup(.approvals, enabled: true)
        let sounds = await empty.subscriptions.values.map { $0.notificationInfo?.soundName }
        XCTAssertEqual(Set(sounds), [NoticeSubscriptionPlan.silentSoundName], "the choice goes with the first group")
        UserDefaults().removePersistentDomain(forName: suite + "-fresh")
    }

    func testTheSoundCannotChangeWithoutCloudKit() async {
        let model = model(FakeNoticeSystem(permission: .allowed), InMemoryNoticeDatabase(), unavailability: .turnedOff)
        await model.setSound(false)
        XCTAssertEqual(model.problem, .unavailable(.turnedOff))
        XCTAssertTrue(model.soundOn)
        XCTAssertEqual(databasesMade, 0)
    }

    func testPermissionThatIsOffSavesNothingButTurningOffStillWorks() async {
        let system = FakeNoticeSystem()
        system.answer = false
        let database = InMemoryNoticeDatabase(zoneExists: true)
        await database.insert(NoticeSubscriptionPlan().subscriptions())
        let model = model(system, database)

        await model.setGroup(.replies, enabled: true)
        XCTAssertEqual(model.problem, .permissionDenied)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertEqual(system.registrations, 0)
        XCTAssertEqual(databasesMade, 0, "nothing reaches iCloud")
        XCTAssertEqual(model.displayedGroups, [], "the switch goes back")

        await model.setGroup(.replies, enabled: true)
        XCTAssertEqual(system.requests, 1, "a refusal is not asked again; Settings sends the person to the system")

        // Turning a group off needs no permission; it changes the account for every device.
        await model.setGroup(.approvals, enabled: false)
        XCTAssertNil(model.problem)
        let kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeGroup.replies.kinds))
        XCTAssertEqual(model.enabledGroups, [.replies])
    }

    func testAnotherDevicesChoicesAreReadAndKept() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase(zoneExists: true)
        // Another iPhone on the account turned on approvals; this one never saved anything.
        await database.insert(NoticeSubscriptionPlan(enabledKinds: NoticeGroup.approvals.kinds).subscriptions())
        let model = model(system, database)
        XCTAssertEqual(model.enabledGroups, [])

        await model.refresh()
        XCTAssertEqual(model.enabledGroups, [.approvals], "Settings shows the account's groups")
        XCTAssertTrue(model.groupsConfirmed)

        await model.setGroup(.replies, enabled: true)
        let kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeGroup.kinds(of: [.approvals, .replies])))

        // A partly subscribed group counts as on and is completed by the next save.
        await model.setGroup(.approvals, enabled: false)
        await database.insert(NoticeSubscriptionPlan(enabledKinds: [.questionNeeded]).subscriptions())
        await model.setGroup(.replies, enabled: false)
        let after = await database.subscribedKinds
        XCTAssertEqual(after, Set(NoticeGroup.approvals.kinds))
    }

    func testAccountStatesStopBeforeSaving() async {
        for status: NoticeAccountStatus in [.noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine] {
            let system = FakeNoticeSystem(permission: .allowed)
            let database = InMemoryNoticeDatabase(status: status)
            let model = model(system, database)
            await model.setGroup(.replies, enabled: true)
            XCTAssertEqual(model.problem, .account(status))
            XCTAssertEqual(model.account, .status(status))
            let changes = await database.subscriberEvents
            XCTAssertEqual(changes, [], "\(status): nothing saved")
            XCTAssertEqual(model.displayedGroups, [])

            await database.setStatus(.available)
            await model.accountChanged()
            XCTAssertEqual(model.account, .status(.available), "CKAccountChanged checks again")
            XCTAssertNil(defaults.object(forKey: NotificationsModel.Key.version))
        }

        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase()
        await database.failNext(.accountStatus, with: CKError(.networkUnavailable))
        let model = model(system, database)
        await model.setGroup(.approvals, enabled: true)
        XCTAssertEqual(model.problem, .accountCheckFailed)
        XCTAssertEqual(model.account, .checkFailed)
    }

    func testAccountChangesAreIgnoredUntilTheAccountWasLookedAt() async {
        let database = InMemoryNoticeDatabase()
        let model = model(FakeNoticeSystem(permission: .allowed), database)
        await model.accountChanged()
        XCTAssertEqual(databasesMade, 0)
        XCTAssertEqual(model.account, .unknown)
    }

    func testCloudKitOffLeavesICloudAndThePermissionAlone() async {
        let system = FakeNoticeSystem()
        let database = InMemoryNoticeDatabase()
        let model = model(system, database, unavailability: .turnedOff)
        XCTAssertEqual(model.account, .unavailable(.turnedOff))
        XCTAssertFalse(model.cloudKitAvailable)

        await model.setGroup(.replies, enabled: true)
        XCTAssertEqual(model.problem, .unavailable(.turnedOff))
        XCTAssertEqual(system.requests, 0, "no permission prompt for alerts that cannot arrive")
        await model.refresh()
        await model.sceneBecameActive()
        let completed = await model.completeLink(link(complete: false))
        XCTAssertNil(completed)
        XCTAssertEqual(databasesMade, 0)

        model.observeChatTurn(ChatTurnObservation(tabID: UUID(), working: true, startedAt: Date(timeIntervalSince1970: 0)),
                              at: Date(timeIntervalSince1970: 0))
        let tab = UUID()
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: Date(timeIntervalSince1970: 0)),
                              at: Date(timeIntervalSince1970: 0))
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: Date(timeIntervalSince1970: 60))
        XCTAssertFalse(model.tipVisible)
    }

    // MARK: Versions

    func testANewPlanVersionSavesTheAccountsSubscriptionsAgain() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase(zoneExists: true)
        let old = NoticeSubscriptionPlan(enabledKinds: NoticeGroup.replies.kinds).subscriptions()
        for subscription in old {
            let info = subscription.notificationInfo
            info?.soundName = nil
            subscription.notificationInfo = info
        }
        await database.insert(old)
        defaults.set(NoticeSubscriptionPlan.version - 1, forKey: NotificationsModel.Key.version)
        let model = model(system, database)

        await model.sceneBecameActive()
        XCTAssertEqual(system.registrations, 1, "an allowed device registers each time it comes forward")
        XCTAssertEqual(system.requests, 0)
        let changes = await database.subscriptionChanges
        XCTAssertEqual(changes, [.modifySubscriptions(saving: ids(NoticeGroup.replies.kinds),
                                                      deleting: deleted(NoticeKind.allCases.filter { NoticeGroup(kind: $0) != .replies }))])
        let replaced = await database.subscriptions[NoticeSubscriptionPlan.subscriptionID(for: .turnFailed)]
        XCTAssertEqual(replaced?.notificationInfo?.soundName, "default", "the subscription was replaced")
        XCTAssertEqual(defaults.object(forKey: NotificationsModel.Key.version) as? Int, NoticeSubscriptionPlan.version)

        await model.sceneBecameActive()
        let again = await database.subscriptionChanges
        XCTAssertEqual(again.count, 1, "the same version is not saved again")
        XCTAssertEqual(system.registrations, 2)
    }

    func testPlanTwoDeletesTheRetiredScheduledRunSubscriptions() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase(zoneExists: true)
        // Plan 1 saved replies and scheduled runs; schedules are gone, so their kinds and group no longer exist.
        await database.insert(NoticeSubscriptionPlan(enabledKinds: NoticeGroup.replies.kinds).subscriptions())
        await database.insert(NoticeSubscriptionPlan.retiredSubscriptionIDs.map { id in
            CKQuerySubscription(recordType: NoticeRecord.recordType, predicate: NSPredicate(value: true),
                                subscriptionID: id, options: [.firesOnRecordCreation])
        })
        defaults.set(1, forKey: NotificationsModel.Key.version)
        defaults.set(["replies", "scheduledRuns"], forKey: NotificationsModel.Key.groups)
        let model = model(system, database)
        XCTAssertEqual(model.enabledGroups, [.replies], "a saved group that no longer exists is left out")

        await model.sceneBecameActive()
        XCTAssertNil(model.problem)
        let changes = await database.subscriptionChanges
        XCTAssertEqual(changes, [.modifySubscriptions(saving: ids(NoticeGroup.replies.kinds),
                                                      deleting: deleted(NoticeGroup.approvals.kinds))])
        let left = await database.subscriptions
        XCTAssertEqual(Set(left.keys), Set(ids(NoticeGroup.replies.kinds)), "the retired subscriptions are deleted")
        XCTAssertEqual(defaults.object(forKey: NotificationsModel.Key.version) as? Int, 2)
        XCTAssertEqual(defaults.stringArray(forKey: NotificationsModel.Key.groups), ["replies"])
    }

    func testADeviceThatNeverSavedSubscriptionsDoesNotTouchICloudWhenItComesForward() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let model = model(system, InMemoryNoticeDatabase(zoneExists: true))
        await model.sceneBecameActive()
        XCTAssertEqual(system.registrations, 1)
        XCTAssertEqual(databasesMade, 0)
    }

    // MARK: Failures

    func testAMissingZoneIsCreatedAgainOnce() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase()
        await database.failNextSubscriptionChange(of: NoticeSubscriptionPlan.subscriptionID(for: .approvalNeeded),
                                                  with: CKError(.userDeletedZone))
        let model = model(system, database)
        await model.setGroup(.approvals, enabled: true)
        XCTAssertNil(model.problem)
        let changes = await database.subscriptionChanges
        XCTAssertEqual(changes.count, 2)
        let events = await database.events
        XCTAssertEqual(events.filter { $0 == .createZone }.count, 2)
        let kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeGroup.approvals.kinds))
    }

    func testARefusedSaveIsReportedAndTheAccountShown() async {
        let system = FakeNoticeSystem(permission: .allowed)
        let database = InMemoryNoticeDatabase()
        await database.failNext(.modifySubscriptions, with: CKError(.serverRejectedRequest))
        let model = model(system, database)
        await model.setGroup(.replies, enabled: true)
        guard case let .saveFailed(failure, _)? = model.problem else { return XCTFail("expected a save problem") }
        XCTAssertEqual(failure, .rejected)
        XCTAssertEqual(model.displayedGroups, [])
        XCTAssertNil(defaults.object(forKey: NotificationsModel.Key.version), "a failed save keeps the old version")

        // One subscription refused (a schema without the queryable `kind` index answers like this).
        await database.failNextSubscriptionChange(of: NoticeSubscriptionPlan.subscriptionID(for: .turnFinished),
                                                  with: CKError(.invalidArguments))
        await model.setGroup(.replies, enabled: true)
        guard case .saveFailed(.rejected, _)? = model.problem else { return XCTFail("expected a save problem") }
        XCTAssertEqual(model.enabledGroups, [.replies], "what the account holds: reply failures are subscribed")
        await model.setGroup(.replies, enabled: true)
        XCTAssertNil(model.problem)
        let kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, [.turnFinished, .turnFailed])
    }

    func testRequestPermissionRegistersButLeavesTheGroups() async {
        let system = FakeNoticeSystem()
        let database = InMemoryNoticeDatabase()
        let model = model(system, database)
        let allowed = await model.requestPermission()
        XCTAssertTrue(allowed)
        XCTAssertEqual(system.registrations, 1)
        XCTAssertEqual(databasesMade, 0)
        let events = await database.subscriberEvents
        XCTAssertEqual(events, [])

        let refusing = FakeNoticeSystem(permission: .denied)
        let other = self.model(refusing, database)
        let refused = await other.requestPermission()
        XCTAssertFalse(refused)
        XCTAssertEqual(refusing.requests, 0)
        XCTAssertEqual(other.problem, .permissionDenied)
    }

    // MARK: Tip

    func testALongTurnOffersTheTipOnce() async {
        let system = FakeNoticeSystem()
        let database = InMemoryNoticeDatabase()
        let model = model(system, database)
        await model.sceneBecameActive()
        let start = Date(timeIntervalSince1970: 1_000)
        let tab = UUID()

        // Short turns, and a turn whose chat was left, offer nothing.
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 29)
        XCTAssertFalse(model.tipVisible)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        model.observeChatTurn(ChatTurnObservation(tabID: UUID(), working: false, startedAt: nil), at: start + 5)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 60)
        XCTAssertFalse(model.tipVisible)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        model.observeChatTurn(nil, at: start + 10)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 60)
        XCTAssertFalse(model.tipVisible)

        // The send is seen before the host names the turn's start; the earlier time counts.
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: nil), at: start)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start + 2), at: start + 3)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 31)
        XCTAssertTrue(model.tipVisible)
        XCTAssertEqual(system.requests, 0, "the tip asks nothing by itself")
        model.dismissTip()
        XCTAssertFalse(model.tipVisible)

        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 90)
        XCTAssertFalse(model.tipVisible, "once")
        let relaunched = self.model(FakeNoticeSystem(), database)
        await relaunched.sceneBecameActive()
        relaunched.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        relaunched.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 90)
        XCTAssertFalse(relaunched.tipVisible, "once, across launches")
        XCTAssertEqual(databasesMade, 0)
    }

    func testTheTipIsOnlyForAPermissionNeverAskedAndItsActionTurnsEverythingOn() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let tab = UUID()
        let allowed = model(FakeNoticeSystem(permission: .allowed), InMemoryNoticeDatabase())
        await allowed.sceneBecameActive()
        allowed.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        allowed.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 45)
        XCTAssertFalse(allowed.tipVisible)
        defaults.removePersistentDomain(forName: suite)

        let system = FakeNoticeSystem()
        let database = InMemoryNoticeDatabase()
        let model = model(system, database)
        await model.sceneBecameActive()
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: true, startedAt: start), at: start)
        model.observeChatTurn(ChatTurnObservation(tabID: tab, working: false, startedAt: nil), at: start + 45)
        XCTAssertTrue(model.tipVisible)
        await model.acceptTip()
        XCTAssertFalse(model.tipVisible)
        XCTAssertEqual(system.requests, 1)
        XCTAssertEqual(model.enabledGroups, Set(NoticeGroup.allCases))
        let kinds = await database.subscribedKinds
        XCTAssertEqual(kinds, Set(NoticeKind.allCases))
    }

    // MARK: Tapped notices

    private let hostID = "e5ca42629ea6e9590c843786b42a5d8a"

    private func link(complete: Bool) -> NoticeDeepLink {
        var link = NoticeDeepLink(record: NoticeRecord(recordName: "\(hostID)-ntc_9", kind: .turnFailed, hostID: hostID,
                                                       projectID: "p", projectName: "P", createdAt: Date()))
        link.isComplete = complete
        link.projectID = nil
        return link
    }

    func testAnIncompletePushIsCompletedFromItsRecord() async {
        let database = InMemoryNoticeDatabase(zoneExists: true)
        let model = model(FakeNoticeSystem(), database)
        let missing = await model.completeLink(link(complete: false))
        XCTAssertNil(missing, "the record is gone: the push's values are all there is")

        let record = NoticeRecord(recordName: "\(hostID)-ntc_9", kind: .turnFailed, hostID: hostID, projectID: "workspace",
                                  projectName: "AgentLand", sessionID: "ses_1", title: "Nightly", createdAt: Date())
        await database.insert(record)
        let complete = await model.completeLink(link(complete: false))
        XCTAssertEqual(complete?.destination, .chat(sessionID: "ses_1"))
        XCTAssertEqual(complete?.projectID, "workspace")
        XCTAssertEqual(complete?.isComplete, true)

        await database.failNext(.record, with: CKError(.networkUnavailable))
        let failed = await model.completeLink(link(complete: false))
        XCTAssertNil(failed)
    }

    func testRegistrationOutcome() {
        let model = model(FakeNoticeSystem(), InMemoryNoticeDatabase())
        model.registrationFailed(CKError(.networkUnavailable))
        XCTAssertNotNil(model.registrationError)
        model.registrationSucceeded()
        XCTAssertNil(model.registrationError)
    }
}
